/// The window a panel asks alarm history for, and the row it gets back.
///
/// ## Why this is on the wire at all
///
/// `RelayAlarmSource.getRecentAlarms` read the panel's own database, under a
/// ruling (D-11) whose premise was that a gateway-mode panel *has* one:
/// *"the panel holds its own Postgres connection in gateway mode —
/// `preferencesProvider` builds it unconditionally"*. That stopped being true.
/// `lib/providers/preferences.dart:60` now branches on the transport before it
/// reads the config row, so in gateway mode `Preferences` is built with
/// `db: null` and the guard `if (preferences.database == null) return []` is
/// the only branch that ever runs. The symptom on a plant is not an error: it
/// is a history page that looks like a factory which has never had an alarm.
///
/// The backend is the process that has `alarm_history`, so history is routed
/// the way every other read on this pipe is routed.
///
/// ## Why it is an RPC and not a key
///
/// `alarm_keys.dart`'s D-9 made the *active set* a value key, and that argument
/// is untouched: an active set is state, and the value path's conflation,
/// fan-out and snapshot-on-reconnect are the right semantics for state. History
/// is not state. It is a **query with arguments** — a limit and a window — and
/// a conflated value key cannot carry arguments, cannot answer two panels
/// asking about two different windows, and has no way to say "that window is
/// not answerable". This is `methods.dart`'s own argument for [Methods.ackAlarm]
/// arriving at the same place from the other direction: keys are for state,
/// RPCs are for things that need an addressee and an answer.
///
/// ## The row is self-sufficient, exactly as an active entry is
///
/// [AlarmHistoryEntry] carries `level`, `title`, `description`, `group` and
/// `acknowledgeRequired` as **copies of the configuration the backend
/// evaluated**, for `alarm_active_entry.dart`'s reason and one sharper one.
///
/// `AlarmMan.getRecentAlarms` resolves each row against the *local* alarm
/// configuration and returns `null` — silently dropped by `whereType` — for any
/// row whose `alarm_uid` it cannot find. In direct mode the two are one file on
/// one machine. In gateway mode they are a backend that evaluated the rules and
/// a panel holding a device-local mirror of a preference, and the moment those
/// disagree the panel drops rows: an alarm renamed last week erases its own
/// history, with no error anywhere. Copying the configuration onto the row is
/// what makes the join unnecessary, and therefore makes the divergence
/// unrepresentable.
///
/// ## Absence is spelled by absence
///
/// `userSummaryToJson`'s convention: epoch milliseconds UTC under `…Ms` keys,
/// **omitted** when null rather than sent as an explicit null (17-06 measured
/// what a present null costs on this wire). Three fields here are legitimately
/// absent and they say three different things — no `deactivatedAtMs` is *still
/// standing*, no `ruleIndex` is a pre-v7 row that names no rule, no `tsSource`
/// is a row written before anybody recorded provenance — and not one of them
/// may be read as a zero.
///
/// This is the one place this package's two habits diverge, so it is worth
/// saying which was chosen and why. [AlarmActiveEntry.toJson] emits every key
/// including its nulls, on the argument that a person reading a frame off the
/// wire while a line is down should see the field. That argument is about a
/// payload streamed continuously under one key. This is a request/response
/// pair, which is where the present-null cost was actually measured, so this
/// DTO follows `UserSummary` in `access_api.dart`.
///
/// ## An unreadable answer is refused, never decoded as empty
///
/// [AlarmActiveEntry.decodeList] is tolerant on purpose — a payload it cannot
/// read leaves the previous active set standing, and the banner does not go
/// blank. History has no previous set to stand on. A tolerant decode here would
/// put an empty page on screen and present it as the plant's history, which is
/// the identical silence this file exists to remove. So
/// [AlarmHistoryEntry.decodeList] throws, and one unreadable row refuses the
/// whole answer rather than quietly shortening it.
library;

import 'alarm_active_entry.dart';
import 'methods.dart';

/// The window and the ceiling a panel asks history under.
///
/// Sent as the params of [Methods.alarmHistory].
final class AlarmHistoryParams {
  /// The wire key of the row ceiling.
  static const String kLimit = 'limit';

  /// The wire key of the window's start, epoch milliseconds UTC.
  static const String kFromMs = 'fromMs';

  /// The wire key of the window's end, epoch milliseconds UTC.
  static const String kToMs = 'toMs';

  /// The largest [limit] this wire will carry.
  ///
  /// **Refused above it, never clamped.** Clamping would answer 5000 rows to a
  /// caller that asked for 50 000 and say nothing about the difference — a
  /// short list presented as the whole history, which is precisely the
  /// truncation `result_too_large.dart` refuses for a chart and for the same
  /// reason: *"a truncated series is not a smaller answer to the same question;
  /// it is a confident answer to a different one, and the operator cannot
  /// tell."*
  ///
  /// Five thousand and not a rounder number lower down, because the panel's own
  /// reads have to fit under it: `AlarmSource.getRecentAlarms` defaults to
  /// 1000 and `stop_timeline.dart:129` asks for 2000. A cap under either would
  /// turn this guard into a refusal of the app's ordinary behaviour, which is
  /// how a guard gets deleted. Above it, a request is better answered with a
  /// narrower window than with a bigger frame.
  static const int maxLimit = 5000;

  /// Builds a window, refusing one that could only ever answer empty.
  ///
  /// [ArgumentError] here and [FormatException] in [fromJson], the split
  /// `AlarmActiveEntry` uses: local code composing a request is programmer
  /// error, a peer sending one is a malformed frame.
  factory AlarmHistoryParams({
    required int limit,
    DateTime? from,
    DateTime? to,
  }) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit',
          'a history query for no rows answers an empty list, which is '
          'indistinguishable on screen from a plant that has never had an '
          'alarm');
    }
    if (limit > maxLimit) {
      throw ArgumentError.value(limit, 'limit',
          'is above the $maxLimit-row ceiling this wire carries. Refused '
          'rather than clamped: a clamped answer is a short history presented '
          'as the whole one. Ask for a narrower window instead');
    }
    if (from != null && to != null && from.isAfter(to)) {
      throw ArgumentError.value('$from..$to', 'from..to',
          'a window that ends before it starts overlaps no row, so it answers '
          'an empty list — an empty answer to an impossible question is the '
          'same silence by a longer route');
    }
    return AlarmHistoryParams._(limit, from?.toUtc(), to?.toUtc());
  }

  const AlarmHistoryParams._(this.limit, this.from, this.to);

  /// How many rows at most, newest first. Never zero; see [maxLimit].
  final int limit;

  /// The window's start, or null for unbounded.
  ///
  /// The bounds are an **overlap** test, not a start test:
  /// `AlarmMan.getRecentAlarms` documents why, and the reason is a measurement
  /// about downtime — an alarm that went off before [from] and only cleared
  /// inside the window is part of that window's stop, and a query that dropped
  /// it would report the stop as shorter than it was.
  final DateTime? from;

  /// The window's end, or null for unbounded.
  final DateTime? to;

  /// The bounds omitted when absent, per `userSummaryToJson`'s convention.
  Map<String, Object?> toJson() => <String, Object?>{
        kLimit: limit,
        if (from != null) kFromMs: from!.toUtc().millisecondsSinceEpoch,
        if (to != null) kToMs: to!.toUtc().millisecondsSinceEpoch,
      };

  /// The inverse, refusing every window that could only answer empty.
  ///
  /// An unknown extra field is **ignored**, not refused:
  /// `AckAlarmParams.fromJson`'s rule, because forward compatibility runs both
  /// ways and a newer panel adding a field must not make an older gateway
  /// refuse to answer history at all.
  factory AlarmHistoryParams.fromJson(Map<String, Object?> json) {
    final limit = _wholeOrNull(json[kLimit], kLimit);
    if (limit == null) {
      throw FormatException(
          'a history query states no "$kLimit". It is not defaulted here: a '
          'guessed ceiling is a page of rows nobody asked for, or a short one '
          'presented as the whole history. $json');
    }
    final from = _wholeOrNull(json[kFromMs], kFromMs);
    final to = _wholeOrNull(json[kToMs], kToMs);
    try {
      return AlarmHistoryParams(
        limit: limit,
        from: from == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(from, isUtc: true),
        to: to == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(to, isUtc: true),
      );
    } on ArgumentError catch (error) {
      // The constructor's own sentence, which says which value was wrong and
      // why an empty answer would have been worse than this refusal.
      throw FormatException('history query refused: ${error.message} '
          '(${error.name} = ${error.invalidValue})');
    }
  }

  /// A whole, finite integer under [name], or null when the key is absent.
  ///
  /// `1e999` decodes to `Infinity` without complaint and `Infinity.toInt()`
  /// throws an `UnsupportedError` that nothing at this boundary catches —
  /// `AckAlarmParams.fromJson`'s measured arm, restated because these numbers
  /// arrive off the same wire through the same decoder.
  static int? _wholeOrNull(Object? raw, String name) {
    if (raw == null) return null;
    if (raw is! num) {
      throw FormatException(
          'history query field "$name" is not a number: $raw');
    }
    if (raw is double) {
      if (!raw.isFinite) {
        throw FormatException('history query field "$name" is not finite: '
            '1e999 decodes to Infinity, and there is no window that names');
      }
      if (raw != raw.truncateToDouble()) {
        throw FormatException(
            'history query field "$name" is not a whole number: $raw');
      }
    }
    return raw.toInt();
  }

  @override
  String toString() => 'AlarmHistoryParams(limit: $limit, '
      'from: ${from?.toIso8601String() ?? 'unbounded'}, '
      'to: ${to?.toIso8601String() ?? 'unbounded'})';
}

/// One `alarm_history` row, carrying everything a panel needs to draw it.
final class AlarmHistoryEntry {
  // ------------------------------------------------------------ wire names
  //
  // camelCase, `alarm_active_entry.dart`'s habit, spelled once each because
  // these cross between two independently deployed halves.

  static const String kUid = 'uid';
  static const String kRuleIndex = 'ruleIndex';
  static const String kLevel = 'level';
  static const String kTitle = 'title';
  static const String kDescription = 'description';
  static const String kGroup = 'group';
  static const String kExpression = 'expression';
  static const String kAcknowledgeRequired = 'acknowledgeRequired';
  static const String kActive = 'active';
  static const String kPendingAck = 'pendingAck';
  static const String kCreatedAtMs = 'createdAtMs';
  static const String kDeactivatedAtMs = 'deactivatedAtMs';
  static const String kTsSource = 'tsSource';

  /// The key the list of rows travels under in the answer.
  ///
  /// A map at the top level rather than a bare list, so an answer that is not
  /// this answer — an older gateway's, a different method's — is *legible as
  /// not this answer* instead of decoding as zero rows.
  static const String kEntries = 'entries';

  /// Builds a row, refusing what cannot be interpreted.
  factory AlarmHistoryEntry({
    required String uid,
    int? ruleIndex,
    required String level,
    required String title,
    required String description,
    List<String> group = const [],
    String? expression,
    bool acknowledgeRequired = false,
    bool active = false,
    bool pendingAck = false,
    required DateTime createdAt,
    DateTime? deactivatedAt,
    String? tsSource,
  }) {
    if (uid.isEmpty) {
      throw ArgumentError.value(
          uid, 'uid', 'a history row must name the alarm it is a row of');
    }
    if (ruleIndex != null && ruleIndex < 0) {
      throw ArgumentError.value(ruleIndex, 'ruleIndex',
          'a rule index is a position in a list; a negative one names no rule. '
          'Null is the way to say a row states none');
    }
    // The same roster and the same refusal `AlarmActiveEntry` applies, for its
    // reason: defaulting an unknown provenance to `plant` relabels a backend
    // guess as the plant's word in the one field a stop analysis is audited on.
    // Null is different and is allowed — a pre-v7 row recorded nothing.
    if (tsSource != null && !AlarmActiveEntry.tsSources.contains(tsSource)) {
      throw ArgumentError.value(tsSource, 'tsSource',
          'not a known alarm timestamp provenance; expected one of '
          '${AlarmActiveEntry.tsSources.join(' or ')}, or null for a row that '
          'recorded none');
    }
    return AlarmHistoryEntry._(
      uid: uid,
      ruleIndex: ruleIndex,
      level: level,
      title: title,
      description: description,
      group: List<String>.unmodifiable(group),
      expression: expression,
      acknowledgeRequired: acknowledgeRequired,
      active: active,
      pendingAck: pendingAck,
      createdAt: createdAt.toUtc(),
      deactivatedAt: deactivatedAt?.toUtc(),
      tsSource: tsSource,
    );
  }

  const AlarmHistoryEntry._({
    required this.uid,
    required this.ruleIndex,
    required this.level,
    required this.title,
    required this.description,
    required this.group,
    required this.expression,
    required this.acknowledgeRequired,
    required this.active,
    required this.pendingAck,
    required this.createdAt,
    required this.deactivatedAt,
    required this.tsSource,
  });

  /// The alarm definition's uid — `alarm_history.alarm_uid`.
  final String uid;

  /// Which rule of that alarm fired, or **null** on a row written before
  /// schema v7.
  ///
  /// Null is carried rather than resolved to 0 because the index is half the
  /// identity an acknowledge is sent under, and because
  /// `AlarmMan.getRecentAlarms` already refuses to guess here: a row that names
  /// no rule gets `acknowledgeRequired: false` and says nothing it cannot
  /// support.
  final int? ruleIndex;

  /// `info` / `warning` / `error`, as `AlarmLevel`'s JSON spells it — from
  /// `alarm_history.alarm_level`, which is what the rule was when it fired.
  final String level;

  /// The configured title, copied. See the library doc for why this is not a
  /// join.
  final String title;

  /// The configured description, copied for the same reason.
  final String description;

  /// The configured group, outermost first. Empty is the root.
  final List<String> group;

  /// The formula rendered with the values it fired on, or null.
  final String? expression;

  /// Whether the rule this row names requires an acknowledgement.
  ///
  /// Resolved by the backend against the configuration it holds, and **false**
  /// when the row names no rule or names one that no longer exists — the
  /// direct-mode rule verbatim: neither can be resolved, and matching such a
  /// row to rule 0 would be a guess dressed as a fact.
  final bool acknowledgeRequired;

  /// Whether the activation is still standing.
  final bool active;

  /// Whether it is waiting on an acknowledgement.
  final bool pendingAck;

  /// When the activation was recorded — `alarm_history.created_at`, UTC.
  final DateTime createdAt;

  /// When it cleared, or **null** while it is still standing.
  ///
  /// Null is what makes a row overlap every window it started before, which is
  /// the property `alarmHistoryOverlaps` and `StopIntervalSource` are both
  /// built on. A zero here would date every open alarm to 1970 and put it
  /// inside no window at all.
  final DateTime? deactivatedAt;

  /// `plant` or `backend_receipt`, or **null** on a row written before v7.
  ///
  /// Three states, not two. Null says nobody recorded a provenance;
  /// `backend_receipt` says the backend positively recorded that it guessed.
  final String? tsSource;

  /// Every field, with the three legitimately-absent ones omitted when null.
  Map<String, Object?> toJson() => <String, Object?>{
        kUid: uid,
        if (ruleIndex != null) kRuleIndex: ruleIndex,
        kLevel: level,
        kTitle: title,
        kDescription: description,
        kGroup: List<String>.of(group),
        kExpression: expression,
        kAcknowledgeRequired: acknowledgeRequired,
        kActive: active,
        kPendingAck: pendingAck,
        kCreatedAtMs: createdAt.toUtc().millisecondsSinceEpoch,
        if (deactivatedAt != null)
          kDeactivatedAtMs: deactivatedAt!.toUtc().millisecondsSinceEpoch,
        if (tsSource != null) kTsSource: tsSource,
      };

  /// Decodes one row.
  ///
  /// **Not tolerant.** A row missing its uid or its instant is refused rather
  /// than filled in with `''` and 1970 — see the library doc, and see
  /// [decodeList], which lets one such row refuse the whole answer instead of
  /// shortening it silently.
  factory AlarmHistoryEntry.fromJson(Map<String, Object?> json) {
    final uid = json[kUid];
    if (uid is! String || uid.isEmpty) {
      throw FormatException('a history row names no alarm: $json');
    }
    final createdAtMs = json[kCreatedAtMs];
    if (createdAtMs is! num || (createdAtMs is double && !createdAtMs.isFinite)) {
      throw FormatException(
          'history row "$uid" states no readable "$kCreatedAtMs" '
          '($createdAtMs). Refused rather than dated to 1970: the instant is '
          'what puts the row inside a window, and a wrong one moves a stop');
    }
    final ruleIndex = json[kRuleIndex];
    if (ruleIndex != null &&
        (ruleIndex is! num ||
            (ruleIndex is double && !ruleIndex.isFinite) ||
            ruleIndex < 0)) {
      throw FormatException(
          'history row "$uid" carries an unusable "$kRuleIndex" ($ruleIndex). '
          'A rule index is a position in a list; absence is how a row says it '
          'names none');
    }
    final tsSource = json[kTsSource];
    if (tsSource != null &&
        (tsSource is! String ||
            !AlarmActiveEntry.tsSources.contains(tsSource))) {
      throw FormatException(
          'history row "$uid" carries "$kTsSource" = "$tsSource", which is not '
          'a known alarm timestamp provenance: expected '
          '"${AlarmActiveEntry.tsSourcePlant}" or '
          '"${AlarmActiveEntry.tsSourceBackendReceipt}", or no key at all for '
          'a row that recorded none. Refused rather than defaulted.');
    }
    final deactivatedAtMs = json[kDeactivatedAtMs];
    if (deactivatedAtMs != null &&
        (deactivatedAtMs is! num ||
            (deactivatedAtMs is double && !deactivatedAtMs.isFinite))) {
      throw FormatException(
          'history row "$uid" carries an unusable "$kDeactivatedAtMs" '
          '($deactivatedAtMs). Absence is how a row says it is still standing');
    }
    return AlarmHistoryEntry(
      uid: uid,
      ruleIndex: (ruleIndex as num?)?.toInt(),
      level: json[kLevel] as String? ?? '',
      title: json[kTitle] as String? ?? '',
      description: json[kDescription] as String? ?? '',
      group: [
        for (final g in (json[kGroup] as List?) ?? const []) '$g',
      ],
      expression: json[kExpression] as String?,
      acknowledgeRequired: json[kAcknowledgeRequired] as bool? ?? false,
      active: json[kActive] as bool? ?? false,
      pendingAck: json[kPendingAck] as bool? ?? false,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(createdAtMs.toInt(), isUtc: true),
      deactivatedAt: deactivatedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (deactivatedAtMs as num).toInt(),
              isUtc: true),
      tsSource: tsSource as String?,
    );
  }

  /// The answer to [Methods.alarmHistory]: `{entries: [...]}`, newest first.
  static Map<String, Object?> encodeList(List<AlarmHistoryEntry> entries) =>
      <String, Object?>{
        kEntries: <Object?>[for (final entry in entries) entry.toJson()],
      };

  /// The inverse of [encodeList], **refusing** anything it cannot read.
  ///
  /// Every throw here is the alternative to returning `[]`, and the whole
  /// reason this file exists: an empty list is what a plant with no alarms
  /// looks like, so a decoder that answers `[]` for a frame it did not
  /// understand has told the operator a fact about the factory instead of a
  /// fact about the wire.
  static List<AlarmHistoryEntry> decodeList(Object? raw) {
    if (raw is! Map) {
      throw FormatException(
          'the gateway\'s ${Methods.alarmHistory} answer is not an object '
          '(${raw.runtimeType}), so nothing in it can be read as history. This '
          'is NOT an empty history: refused rather than shown as a plant with '
          'no alarms.');
    }
    final entries = raw[kEntries];
    if (entries is! List) {
      throw FormatException(
          'the gateway\'s ${Methods.alarmHistory} answer carries no "$kEntries" '
          'list (${entries.runtimeType}). Refused rather than shown as an '
          'empty history — an answer nobody can read is not an answer.');
    }
    return <AlarmHistoryEntry>[
      for (final element in entries)
        if (element is Map)
          AlarmHistoryEntry.fromJson(element.map((k, v) => MapEntry('$k', v)))
        else
          throw FormatException(
              'a ${Methods.alarmHistory} answer carries an entry that is not '
              'an object ($element). Refused whole rather than skipped: a '
              'history quietly missing rows is a stop analysis missing the '
              'interval nobody knows is missing.'),
    ];
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AlarmHistoryEntry) return false;
    if (other.group.length != group.length) return false;
    for (var i = 0; i < group.length; i++) {
      if (other.group[i] != group[i]) return false;
    }
    return other.uid == uid &&
        other.ruleIndex == ruleIndex &&
        other.level == level &&
        other.title == title &&
        other.description == description &&
        other.expression == expression &&
        other.acknowledgeRequired == acknowledgeRequired &&
        other.active == active &&
        other.pendingAck == pendingAck &&
        other.createdAt == createdAt &&
        other.deactivatedAt == deactivatedAt &&
        other.tsSource == tsSource;
  }

  @override
  int get hashCode => Object.hash(
        uid,
        ruleIndex,
        level,
        title,
        description,
        Object.hashAll(group),
        expression,
        acknowledgeRequired,
        active,
        pendingAck,
        createdAt,
        deactivatedAt,
        tsSource,
      );

  @override
  String toString() => 'AlarmHistoryEntry($uid'
      '${ruleIndex == null ? ' (no rule)' : '#$ruleIndex'}, $level, '
      '${createdAt.toIso8601String()}'
      '${deactivatedAt == null ? ' — standing' : ' .. '
          '${deactivatedAt!.toIso8601String()}'}'
      '${tsSource == null ? '' : ' $tsSource'})';
}
