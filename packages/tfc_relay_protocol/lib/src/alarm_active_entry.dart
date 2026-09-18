/// One active alarm as it travels under [AlarmKeys.active], and the shape of
/// the list it travels in.
///
/// ## Why the shape lives in the protocol package
///
/// `AlarmKeys` reserves the *name*; this file fixes the *payload*. Both ends
/// need it: the producer is the backend's alarm engine in `tfc_dart`, and the
/// consumers are every panel that draws a banner, a list or a stop timeline.
/// A field spelled twice is a field that can be spelled differently, and the
/// symptom is not a failing test — it is a banner that renders an alarm with
/// no title on the station that has not been updated yet. So the names are
/// `static const` here and nowhere else, and `alarm_active_entry_test.dart`
/// pins each one against a literal.
///
/// ## The eleven fields, and why the entry is self-sufficient
///
/// `uid` and `ruleIndex` are the identity — the same `(alarm_uid, rule_index)`
/// pair `AckAlarmParams` already carries and D-4 persists. Everything else is
/// either the transition (`activeAtMs`, `tsSource`, `expression`,
/// `pendingAck`, `historyId`) or a **copy of the configuration**: `level`,
/// `title`, `description`, `group`.
///
/// Copying the configuration is deliberate. The alternative is a panel joining
/// this entry against its own copy of `alarm_man_config`, and those two copies
/// are not the same age: preferences are re-read on a restart, so a panel that
/// has been up since before the last configuration change would draw a live
/// alarm it cannot name. An alarm nobody can name is an alarm nobody acts on.
/// The cost is a few hundred bytes per active entry, bounded by the engine's
/// own cap.
///
/// ## `activeAtMs` is epoch milliseconds, and it is DATA (P-7)
///
/// Not `DynamicValue.sourceTime`. The panel converts relay values through
/// `toUaValue` (`tfc_dart/lib/core/gateway_state_man.dart:311`), which rebuilds
/// structs and arrays member by member into a type that has no per-member
/// timestamp at all — so even where a source time survives for the value
/// itself, a *per-entry* instant inside a list has nowhere to live. It would
/// be dropped silently, somewhere no test is looking, and the banner would
/// read the instant it was drawn.
///
/// Milliseconds since the Unix epoch, **UTC**, is also what the wire already
/// carries for `DynamicValue`'s own `t`. [activeAt] decodes it back as a UTC
/// `DateTime`; a local-time round trip is the bug that makes two panels in
/// two time zones disagree about when the line stopped.
///
/// ## `tsSource` is two literals, re-declared on purpose
///
/// This package must not import `tfc_dart`, where `AlarmTsSource.wireName`
/// declares the same two strings. So they are declared again here and the two
/// rosters are kept honest by a test on the `tfc_dart` side that compares them
/// — the mechanism `pipe_keys.dart`'s own doc describes for exactly this
/// situation. An unknown third value is **refused by name** on decode rather
/// than defaulted: defaulting to `plant` would relabel a backend's guess as
/// the plant's word, in the one field a stop analysis exists to be audited on.
library;

import 'alarm_keys.dart';

/// The result of decoding an `ALARM.active` payload.
typedef AlarmActiveList = ({
  List<AlarmActiveEntry> entries,
  bool truncated,
  int omitted,
});

/// One active alarm-rule instance.
final class AlarmActiveEntry {
  // ------------------------------------------------------------ wire names
  //
  // camelCase, matching the habit every other payload in this package already
  // has. Spelled once; `alarm_active_entry_test.dart` asserts each against a
  // literal because these cross between two independently deployed halves.

  static const String kUid = 'uid';
  static const String kRuleIndex = 'ruleIndex';
  static const String kLevel = 'level';
  static const String kTitle = 'title';
  static const String kDescription = 'description';
  static const String kGroup = 'group';
  static const String kExpression = 'expression';
  static const String kActiveAtMs = 'activeAtMs';
  static const String kTsSource = 'tsSource';
  static const String kPendingAck = 'pendingAck';
  static const String kHistoryId = 'historyId';
  static const String kStaleInputs = 'staleInputs';
  static const String kStaleSinceMs = 'staleSinceMs';

  /// The wire spelling of "every contributing value carried a plant instant,
  /// and this is the newest of them".
  ///
  /// Must equal `AlarmTsSource.plant.wireName` in `tfc_dart`; that equality is
  /// asserted by `backend_alarms_test.dart`, since this package cannot see the
  /// enum.
  static const String tsSourcePlant = 'plant';

  /// The wire spelling of "at least one contributing value carried no
  /// instant, so this is when the backend received the evaluation".
  static const String tsSourceBackendReceipt = 'backend_receipt';

  /// Every provenance a decoder will accept. Anything else is refused by name.
  static const List<String> tsSources = [
    tsSourcePlant,
    tsSourceBackendReceipt,
  ];

  // ------------------------------------------------------ truncation marker

  /// The key whose *presence* identifies the truncation marker in the list.
  ///
  /// The marker is an element of the same list rather than a wrapper object,
  /// so the payload stays a list at the top level and stays three deep. An
  /// entry never carries this key and the marker never carries [kUid], so the
  /// two are told apart by structure rather than by position.
  static const String kTruncated = 'truncated';

  /// How many entries the cap dropped, on the marker.
  static const String kOmitted = 'omitted';

  /// Builds an entry, refusing a [tsSource] nobody can interpret.
  ///
  /// [ArgumentError] rather than [FormatException]: the caller here is local
  /// code composing a payload, so an unknown provenance is programmer error.
  /// [fromJson] refuses the same value as a [FormatException], because there
  /// the caller is a peer.
  factory AlarmActiveEntry({
    required String uid,
    required int ruleIndex,
    required String level,
    required String title,
    required String description,
    List<String> group = const [],
    String? expression,
    required int activeAtMs,
    required String tsSource,
    bool pendingAck = false,
    String? historyId,
    List<String> staleInputs = const [],
    int? staleSinceMs,
  }) {
    if (!tsSources.contains(tsSource)) {
      throw ArgumentError.value(tsSource, 'tsSource',
          'not a known alarm timestamp provenance; expected one of '
          '${tsSources.join(' or ')}');
    }
    return AlarmActiveEntry._(
      uid: uid,
      ruleIndex: ruleIndex,
      level: level,
      title: title,
      description: description,
      group: List<String>.unmodifiable(group),
      expression: expression,
      activeAtMs: activeAtMs,
      tsSource: tsSource,
      pendingAck: pendingAck,
      historyId: historyId,
      staleInputs: List<String>.unmodifiable(staleInputs),
      staleSinceMs: staleSinceMs,
    );
  }

  const AlarmActiveEntry._({
    required this.uid,
    required this.ruleIndex,
    required this.level,
    required this.title,
    required this.description,
    required this.group,
    required this.expression,
    required this.activeAtMs,
    required this.tsSource,
    required this.pendingAck,
    required this.historyId,
    required this.staleInputs,
    required this.staleSinceMs,
  });

  /// The alarm definition's uid. Half of the identity `AckAlarmParams` uses.
  final String uid;

  /// Which rule of that alarm is active. The other half: one alarm with two
  /// rules that both hold is two entries, because they are two facts about the
  /// plant and an operator acknowledges them separately.
  final int ruleIndex;

  /// `info` / `warning` / `error`, as `AlarmLevel`'s JSON spells it.
  final String level;

  /// The configured title, copied so a panel one restart behind can name it.
  final String title;

  /// The configured description, copied for the same reason.
  final String description;

  /// The configured group, outermost first — `['Line 3', 'Multivac']` means
  /// the alarm sits in Multivac, which sits in Line 3. Empty is the root.
  final List<String> group;

  /// The formula rendered with the values it fired on, or null.
  ///
  /// Null is normal: the render is computed only on the activation branch
  /// (T-14-07), and an alarm held from before a restart may have no render.
  final String? expression;

  /// When the rule became active: milliseconds since the Unix epoch, UTC.
  ///
  /// See the library doc for why this is data and not `sourceTime`.
  final int activeAtMs;

  /// Whether [activeAtMs] came from the plant or from the backend's clock.
  ///
  /// One of [tsSources]. "The plant said so" and "the backend guessed" are
  /// different facts, and a stop analysis that cannot tell them apart is one
  /// nobody can audit.
  final String tsSource;

  /// True when the rule has cleared but still requires an acknowledgement.
  ///
  /// An `acknowledgeRequired` rule stays in the active set after its condition
  /// goes false, so a fault that came and went between two glances at the
  /// screen is not a fault nobody ever saw.
  final bool pendingAck;

  /// The `alarm_history` row this activation was written as, or null.
  ///
  /// Null throughout 14-05, which does not persist; 14-06 fills it.
  final String? historyId;

  /// The keys this entry's rule reads that are NOT in the good band right now.
  ///
  /// Empty is the ordinary state: every input is good and the boolean on the
  /// banner was earned by an evaluation. Non-empty means D-3's quality gate has
  /// suspended the rule and is HOLDING the state shown — the alarm can neither
  /// clear nor re-fire until these inputs return, so the operator's next
  /// useful act is to check the named sensor, and the banner has to say which.
  /// Measured on the SVN rig, 2026-09-08: a warning latched true on a dead
  /// input, invisible, for as long as anyone watched.
  final List<String> staleInputs;

  /// When the hold began: milliseconds since the Unix epoch, UTC, or null when
  /// [staleInputs] is empty.
  ///
  /// The same shape as [activeAtMs], for the same P-7 reason: an instant
  /// inside a list payload has nowhere else to live, and a panel must render
  /// "input stale since 19:18" without consulting its own clock or time zone.
  final int? staleSinceMs;

  /// [activeAtMs] as a UTC `DateTime`.
  DateTime get activeAt =>
      DateTime.fromMillisecondsSinceEpoch(activeAtMs, isUtc: true);

  /// [staleSinceMs] as a UTC `DateTime`, or null when the entry is live.
  DateTime? get staleSince => staleSinceMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(staleSinceMs!, isUtc: true);

  /// Every field, always — including the nulls.
  ///
  /// No `if (x != null)` omissions. An absent key and a null one are the same
  /// thing to a tolerant decoder, but they are not the same thing to a person
  /// reading a frame off the wire while a line is down.
  Map<String, Object?> toJson() => <String, Object?>{
        kUid: uid,
        kRuleIndex: ruleIndex,
        kLevel: level,
        kTitle: title,
        kDescription: description,
        kGroup: List<String>.of(group),
        kExpression: expression,
        kActiveAtMs: activeAtMs,
        kTsSource: tsSource,
        kPendingAck: pendingAck,
        kHistoryId: historyId,
        kStaleInputs: List<String>.of(staleInputs),
        kStaleSinceMs: staleSinceMs,
      };

  /// Decodes one entry, refusing an uninterpretable [kTsSource] by name.
  factory AlarmActiveEntry.fromJson(Map<String, Object?> json) {
    final tsSource = json[kTsSource];
    if (tsSource is! String || !tsSources.contains(tsSource)) {
      throw FormatException(
          'AlarmActiveEntry.$kTsSource is "$tsSource", which is not a known '
          'alarm timestamp provenance: expected "$tsSourcePlant" or '
          '"$tsSourceBackendReceipt". Refused rather than defaulted — '
          'defaulting would relabel a backend guess as the plant\'s word.');
    }
    return AlarmActiveEntry(
      uid: json[kUid] as String? ?? '',
      ruleIndex: (json[kRuleIndex] as num?)?.toInt() ?? 0,
      level: json[kLevel] as String? ?? '',
      title: json[kTitle] as String? ?? '',
      description: json[kDescription] as String? ?? '',
      group: [
        for (final g in (json[kGroup] as List?) ?? const []) '$g',
      ],
      expression: json[kExpression] as String?,
      activeAtMs: (json[kActiveAtMs] as num?)?.toInt() ?? 0,
      tsSource: tsSource,
      pendingAck: json[kPendingAck] as bool? ?? false,
      historyId: json[kHistoryId] as String?,
      // Absent on a backend older than this field. Empty and null mean
      // "not stale", which is also the only thing an old backend could have
      // said — deployment skew must not invent a dead sensor.
      staleInputs: [
        for (final input in (json[kStaleInputs] as List?) ?? const []) '$input',
      ],
      staleSinceMs: (json[kStaleSinceMs] as num?)?.toInt(),
    );
  }

  /// Encodes [entries] as the [AlarmKeys.active] payload.
  ///
  /// A list, so the payload is three deep for a plain entry and four through
  /// [group] — well inside `DynamicValue`'s bound of 64, which it enforces on
  /// nesting but not on breadth. Breadth is the engine's cap, and when the cap
  /// bit, [truncated] appends one marker element carrying [omitted]. Spelled
  /// here so producer and consumer cannot disagree about what a short list
  /// means: a list that was cut is not the same fact as a plant with fewer
  /// alarms.
  static Object? encodeList(
    List<AlarmActiveEntry> entries, {
    bool truncated = false,
    int omitted = 0,
  }) =>
      <Object?>[
        for (final entry in entries) entry.toJson(),
        if (truncated) <String, Object?>{kTruncated: true, kOmitted: omitted},
      ];

  /// The inverse of [encodeList].
  ///
  /// Tolerant about what it is handed — a payload that is not a list at all
  /// decodes as empty rather than throwing, because a panel must not go blank
  /// on a frame it did not expect. It is **not** tolerant about [kTsSource];
  /// see [fromJson].
  static AlarmActiveList decodeList(Object? raw) {
    final entries = <AlarmActiveEntry>[];
    var truncated = false;
    var omitted = 0;
    if (raw is! List) return (entries: entries, truncated: false, omitted: 0);
    for (final element in raw) {
      if (element is! Map) continue;
      final map = element.map((k, v) => MapEntry('$k', v));
      if (map.containsKey(kTruncated)) {
        truncated = map[kTruncated] == true;
        omitted = (map[kOmitted] as num?)?.toInt() ?? 0;
        continue;
      }
      entries.add(AlarmActiveEntry.fromJson(map));
    }
    return (entries: entries, truncated: truncated, omitted: omitted);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AlarmActiveEntry) return false;
    if (other.group.length != group.length) return false;
    for (var i = 0; i < group.length; i++) {
      if (other.group[i] != group[i]) return false;
    }
    if (other.staleInputs.length != staleInputs.length) return false;
    for (var i = 0; i < staleInputs.length; i++) {
      if (other.staleInputs[i] != staleInputs[i]) return false;
    }
    return other.uid == uid &&
        other.staleSinceMs == staleSinceMs &&
        other.ruleIndex == ruleIndex &&
        other.level == level &&
        other.title == title &&
        other.description == description &&
        other.expression == expression &&
        other.activeAtMs == activeAtMs &&
        other.tsSource == tsSource &&
        other.pendingAck == pendingAck &&
        other.historyId == historyId;
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
        activeAtMs,
        tsSource,
        pendingAck,
        historyId,
        Object.hashAll(staleInputs),
        staleSinceMs,
      );

  @override
  String toString() => 'AlarmActiveEntry($uid#$ruleIndex, $level, '
      '${activeAt.toIso8601String()} $tsSource'
      '${pendingAck ? ', pendingAck' : ''}'
      '${staleInputs.isEmpty ? '' : ', HELD on stale ${staleInputs.join('+')}'
          ' since ${staleSince!.toIso8601String()}'})';
}
