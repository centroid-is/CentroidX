import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:drift/drift.dart'
    show
        BooleanExpressionOperators,
        ComparableExpr,
        GenerationContext,
        OrderingMode,
        OrderingTerm,
        Precedence,
        SqlDialect,
        Variable;
// Prefixed: drift's `Expression` collides with this package's own.
import 'package:drift/drift.dart' as drift show Constant, Expression;

import 'alarm_stamp.dart';
import 'database_drift.dart' show $AlarmHistoryTable;
import 'preferences.dart';
import 'state_man.dart';
import 'ring_buffer.dart';
import 'boolean_expression.dart';
import 'fuzzy_match.dart';

// A self-import, with a prefix, for exactly one reason: `AlarmMan` declares a
// `filterAlarms` member, and inside the class body that name shadows the
// top-level `filterAlarms` it has to delegate to. This is how the one-line
// delegation reaches the shared function instead of calling itself.
import 'alarm.dart' as shared;

part 'alarm.g.dart';

@JsonEnum()
enum AlarmLevel {
  info,
  warning,
  error,
}

@JsonSerializable()
class AlarmRule {
  final AlarmLevel level;
  final ExpressionConfig expression;
  final bool acknowledgeRequired;

  AlarmRule({
    required this.level,
    required this.expression,
    required this.acknowledgeRequired,
  });

  @override
  String toString() {
    return 'AlarmRule(level: $level, expression: $expression, acknowledgeRequired: $acknowledgeRequired)';
  }

  factory AlarmRule.fromJson(Map<String, dynamic> json) =>
      _$AlarmRuleFromJson(json);
  Map<String, dynamic> toJson() => _$AlarmRuleToJson(this);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AlarmRule &&
        level == other.level &&
        expression == other.expression &&
        acknowledgeRequired == other.acknowledgeRequired;
  }

  @override
  int get hashCode => Object.hash(level, expression, acknowledgeRequired);

  static AlarmRule from(AlarmRule copy) {
    return AlarmRule(
      level: copy.level,
      expression: ExpressionConfig.from(copy.expression),
      acknowledgeRequired: copy.acknowledgeRequired,
    );
  }
}

@JsonSerializable()
class AlarmConfig {
  final String uid;
  // todo I would like this to fetch title and description from opcua alarm
  final String? key;
  final String title;
  final String description;
  final List<AlarmRule> rules;

  /// The group this alarm belongs to, read outermost first — the way a
  /// package name is read. `['Line 3', 'Multivac']` means the alarm sits in
  /// Multivac, which sits in Line 3. Empty puts it at the root.
  ///
  /// The grouping belongs here rather than on any one screen because it is a
  /// property of the plant, not of a page: the stop timeline, and anything
  /// else that rolls alarms up, read the same groups, and configuring an
  /// alarm stays the single place its home is decided.
  ///
  /// Contrast [AlarmVisibilityConfig.announceInNavigation], which is on the
  /// beacon asset because *where* an alarm announces genuinely is a per-page
  /// presentation choice.
  @JsonKey(defaultValue: <String>[])
  final List<String> group;

  /// True when this alarm *is* the group named by [group], rather than one
  /// alarm inside it.
  ///
  /// This is the coarse "the machine stopped" signal for equipment that has
  /// no finer alarms yet. A group may have a bound alarm and members at the
  /// same time, in which case the bound one accounts for whatever the
  /// diagnoses inside it do not explain — so adding a diagnosis later is a
  /// new alarm definition, not a restructuring.
  @JsonKey(defaultValue: false)
  final bool bindToGroup;

  /// Whether an activation of this alarm counts as a stop.
  ///
  /// The stop analysis reads the same alarm definitions the alarm system
  /// runs on, and by default every activation is downtime. An advisory
  /// alarm — a door open, a level warning that never halts the line — is
  /// excluded here, at the definition, so every stop view agrees; which is
  /// also why the flag is not on any one screen (see [group] for the same
  /// argument).
  @JsonKey(defaultValue: true)
  final bool countsAsStop;

  // Navigation announcement lives on the Alarm beacon asset
  // (`AlarmVisibilityConfig.announceInNavigation`), not here: an alarm is a
  // plant-wide fact, where it announces is a per-page presentation choice,
  // and the beacon *is* that choice. There briefly was a
  // `navigation_indicator` flag on this class (#247); stored copies of it in
  // `alarm_man_config` are ignored on load and dropped on the next save.

  AlarmConfig({
    required this.uid,
    this.key,
    required this.title,
    required this.description,
    required this.rules,
    this.group = const [],
    this.bindToGroup = false,
    this.countsAsStop = true,
  });

  @override
  String toString() {
    return 'AlarmConfig(uid: $uid, key: $key, title: $title, description: $description, group: $group, bindToGroup: $bindToGroup, countsAsStop: $countsAsStop, rules: $rules)';
  }

  /// Drift row constructor for the `Alarm` table — alarm configuration is
  /// persisted as the `alarm_man_config` preference JSON, not as rows.
  factory AlarmConfig.fromDb({
    required String uid,
    String? key,
    required String title,
    required String description,
    required String rules,
  }) {
    return AlarmConfig(
        uid: uid,
        key: key,
        title: title,
        description: description,
        rules: jsonDecode(rules).map((e) => AlarmRule.fromJson(e)).toList());
  }

  factory AlarmConfig.fromJson(Map<String, dynamic> json) =>
      _$AlarmConfigFromJson(json);
  Map<String, dynamic> toJson() => _$AlarmConfigToJson(this);

  static AlarmConfig from(AlarmConfig copy) {
    return AlarmConfig(
      uid: copy.uid,
      key: copy.key,
      title: copy.title,
      description: copy.description,
      group: List<String>.from(copy.group),
      bindToGroup: copy.bindToGroup,
      countsAsStop: copy.countsAsStop,
      rules: copy.rules.map((e) => AlarmRule.from(e)).toList(),
    );
  }
}

@JsonSerializable()
class AlarmManConfig {
  final List<AlarmConfig> alarms;

  AlarmManConfig({required this.alarms});

  factory AlarmManConfig.fromJson(Map<String, dynamic> json) =>
      _$AlarmManConfigFromJson(json);
  Map<String, dynamic> toJson() => _$AlarmManConfigToJson(this);
}

/// Where a panel gets its alarms from.
///
/// One surface, two implementations. [AlarmMan] evaluates the rules itself
/// against a local `StateMan` — the direct-mode station, wired straight to the
/// PLCs. A gateway-mode station is *told* the active set by the backend over
/// the pipe and evaluates nothing. The widgets must not know which they have,
/// or "which alarms does the operator see" becomes two answers that can
/// disagree on the same screen.
///
/// This is the set of members the app actually calls, and no more.
abstract interface class AlarmSource {
  /// The configured alarms, as loaded.
  AlarmManConfig get config;

  /// One [Alarm] per entry of [config].
  Set<Alarm> get alarms;

  /// The alarms standing right now, re-emitted on every change.
  Stream<Set<AlarmActive>> activeAlarms();

  /// Recently cleared alarms, newest last, as a rolling buffer.
  Stream<List<AlarmActive?>> history();

  /// Closed and open activations from `alarm_history`, newest first.
  Future<List<AlarmActive>> getRecentAlarms({
    int limit,
    DateTime? from,
    DateTime? to,
  });

  /// The operator's view of [alarms]: one row per alarm, worst rule first.
  ///
  /// Delegates to the top-level [filterAlarms] — see there for why the
  /// behaviour is not allowed to be per-implementation.
  List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String searchQuery);

  /// Acknowledges [alarm].
  ///
  /// `Future<void>`, not `void`, and that is the one signature on this
  /// interface that is not the shape [AlarmMan] had before. A gateway-mode
  /// implementation has to cross a wire to acknowledge (`Methods.ackAlarm`),
  /// and a `void` member would oblige it to fire and forget — which is the
  /// silent-loss failure this project exists to prevent. In direct mode the
  /// panel owns the active set and the local removal *is* the effect, so
  /// [AlarmMan] completes immediately.
  Future<void> ackAlarm(AlarmActive alarm);

  void addAlarm(AlarmConfig alarm);
  void removeAlarm(AlarmConfig alarm);
  void updateAlarm(AlarmConfig alarm);
}

/// The operator's view of [alarms]: one row per alarm, worst rule first.
///
/// A top-level function rather than a method, because both [AlarmSource]
/// implementations have to answer the same question and two implementations of
/// "which alarms does the operator see" is two lists that can disagree on the
/// same screen. Nothing here reads instance state — the collapse, the sort and
/// the fuzzy filter are all pure over their arguments.
///
/// Alarms are grouped by [AlarmConfig.uid] and only the highest-priority rule
/// of each survives: an operator wants one row per thing that is wrong, not
/// one per rule that noticed. The survivors sort by level and then by recency,
/// and [searchQuery] fuzzy-matches title and description.
List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String searchQuery) {
  // Group alarms by uid and keep only the highest priority one for each
  final Map<String, AlarmActive> highestPriorityAlarms = {};
  for (final alarm in alarms) {
    final existing = highestPriorityAlarms[alarm.alarm.config.uid];
    if (existing == null ||
        alarm.notification.rule.level.index >
            existing.notification.rule.level.index) {
      highestPriorityAlarms[alarm.alarm.config.uid] = alarm;
    }
  }

  var filteredAlarms = highestPriorityAlarms.values.toList()
    ..sort((a, b) {
      // First sort by priority (error > warning > info)
      final priorityCompare = b.notification.rule.level.index
          .compareTo(a.notification.rule.level.index);
      if (priorityCompare != 0) return priorityCompare;

      // If same priority, sort by most recent timestamp
      return b.notification.timestamp.compareTo(a.notification.timestamp);
    });

  return fuzzyFilter(filteredAlarms, searchQuery, [
    (a) => a.alarm.config.title,
    (a) => a.alarm.config.description,
  ]);
}

/// Whether an `alarm_history` row overlaps the window [from]..[to].
///
/// Overlap, not started-inside: an alarm that went off before [from] and only
/// cleared inside the window is part of that window's downtime, and a query
/// that dropped it would report the stop as shorter than it was — the one
/// number a stop analysis exists to get right. A row with no deactivation time
/// never closed, so it overlaps every window it started before.
drift.Expression<bool> alarmHistoryOverlaps(
  $AlarmHistoryTable t, {
  DateTime? from,
  DateTime? to,
}) {
  final started = to == null
      ? const drift.Constant(true)
      : _DateTimeBound(t.createdAt, '<=', to);
  if (from == null) return started;
  return started &
      (t.deactivatedAt.isNull() | _DateTimeBound(t.deactivatedAt, '>=', from));
}

/// `column <op> value` on a datetime column, spelled so it survives both
/// backends.
///
/// This database stores datetimes as text (`storeDateTimeAsText`), and drift
/// then rewrites *every* comparison between two datetime expressions into
/// `JULIANDAY(a) <op> JULIANDAY(b)`. That is right for sqlite — the stored
/// text carries a UTC offset, so comparing it lexicographically would order
/// `…+02:00` against `…Z` wrong — and fatal on Postgres, which has no
/// `julianday()` at all:
///
/// ```
/// ERROR: function julianday(text) does not exist
/// ```
///
/// Only the Downtime view hit it, because it is the only caller that passes a
/// window; every other read of `alarm_history` is unbounded and never builds a
/// comparison.
///
/// Postgres therefore gets a plain comparison, with both sides cast to
/// `timestamp` the way `AlarmHistoryWriter`'s statements cast what they write
/// (`core/relay/backend_alarm_history.dart`).
/// Both casts are needed: storing datetimes as text makes drift declare these
/// columns `text` on Postgres too, and drift_postgres types a mapped `String`
/// variable as `Type.text`, so without the casts neither side is a timestamp
/// and the comparison is `text <= text` — lexicographic, and wrong the moment
/// two rows were written in different formats. `alarm_history` holds both:
/// the writer inserts through a `::timestamp` cast, which Postgres
/// writes back out as `2026-08-29 10:00:00`, while drift's own insert stores
/// ISO-8601. `::timestamp` parses either. On a database whose columns really
/// are `timestamp` the cast is a no-op.
class _DateTimeBound extends drift.Expression<bool> {
  _DateTimeBound(this.column, this.op, this.value);

  final drift.Expression<DateTime> column;

  /// `<=` or `>=`.
  final String op;

  final DateTime value;

  @override
  Precedence get precedence => Precedence.comparison;

  @override
  void writeInto(GenerationContext context) {
    if (context.dialect != SqlDialect.postgres) {
      // Let drift do its julianday rewrite; on sqlite it is the correct one.
      final drifted = op == '<='
          ? column.isSmallerOrEqualValue(value)
          : column.isBiggerOrEqualValue(value);
      drifted.writeInto(context);
      return;
    }

    writeInner(context, column);
    context.buffer.write('::timestamp $op ');
    writeInner(context, Variable<DateTime>(value));
    context.buffer.write('::timestamp');
  }
}

/// The direct-mode alarm engine: it subscribes to the plant itself, evaluates
/// every configured rule, and publishes what is standing right now.
///
/// **This class has no write path, and that is deliberate (D-6).** It used to
/// carry an `AlarmManLocalConfig` with a `historyToDb` boolean and an
/// `_addToDb` insert behind it, which `bin/main.dart` turned on. Persistence
/// now belongs to the backend's `AlarmEngine`/`AlarmHistoryWriter`
/// (`core/relay/backend_alarm_history.dart`), which always writes, and the row
/// exists for as long as the alarm does rather than appearing only once it
/// clears.
///
/// The flag is not merely unused here — it is *gone*, along with the statement
/// it guarded. A configuration switch that decides whether an object writes to
/// a shared database is a switch somebody eventually sets wrong, and the cost
/// of that mistake is two processes writing the same plant's history into the
/// same table with no way to tell the copies apart. A class that contains no
/// insert cannot be configured into performing one. If you are here looking for
/// where the insert went: it is `AlarmHistoryWriter`, and it should not come
/// back.
class AlarmMan implements AlarmSource {
  @override
  final AlarmManConfig config;
  final Preferences preferences;
  final StateMan stateMan;
  @override
  final Set<Alarm> alarms;

  /// The wall clock, injected.
  ///
  /// Never `DateTime.now()` in this file: an alarm instant is a fact two
  /// panels have to agree on, so it comes from the plant where the plant said
  /// so and from a clock the composition root supplied where it did not. See
  /// [resolveAlarmStamp].
  final DateTime Function() _clock;

  /// How far a plant instant may sit from this station's own clock before the
  /// disagreement is reported (CD-3). Reported, never clamped.
  final Duration _skewWarnAfter;

  final Set<AlarmActive> _activeAlarms;
  final StreamController<Set<AlarmActive>> _activeAlarmsController;
  final RingBuffer<AlarmActive> _history;
  final StreamController<List<AlarmActive?>> _historyController;
  AlarmMan._(
      {required this.config,
      required this.preferences,
      required this.stateMan,
      required DateTime Function() clock,
      Duration skewWarnAfter = kAlarmSkewWarnAfter})
      : _clock = clock,
        _skewWarnAfter = skewWarnAfter,
        alarms = config.alarms.map((e) => Alarm(config: e)).toSet(),
        _activeAlarms = {},
        _activeAlarmsController = BehaviorSubject<Set<AlarmActive>>.seeded({}),
        _history = RingBuffer<AlarmActive>(1000),
        _historyController = BehaviorSubject<List<AlarmActive?>>.seeded([]) {
    _activeAlarmsController.onListen = () async {
      for (final alarm in alarms) {
        final stream = alarm.onChange(stateMan,
            clock: _clock, skewWarnAfter: _skewWarnAfter);
        stream.listen((alarmNotification) {
          final existing = _activeAlarms.firstWhereOrNull((e) =>
              // the uid must match, we are in correct closure
              e.alarm.config.uid == alarm.config.uid &&
              // the rule must match
              e.notification.rule == alarmNotification.rule);

          // The instant this notification says the transition happened at,
          // with the provenance it was resolved under. Whatever this
          // notification closes, closes at the same instant it opened its
          // successor -- there is no second reading of anything.
          final stamp = alarmNotification.stamp;

          if (alarmNotification.active) {
            if (existing != null) {
              _removeActiveAlarm(existing, stamp);
            }
            _activeAlarms.add(
                AlarmActive(alarm: alarm, notification: alarmNotification));
          } else if (!alarmNotification.rule.acknowledgeRequired) {
            if (existing != null) {
              _removeActiveAlarm(existing, stamp);
            } else {
              stderr.writeln(
                  'Did not find existing active alarm for alarmNotification: $alarmNotification');
            }
          } else {
            for (final e in _activeAlarms) {
              if (e.alarm.config.uid == alarm.config.uid &&
                  e.notification.rule == alarmNotification.rule) {
                e.pendingAck = true;
                e.notification.active = false;
                // The condition cleared when the PLANT says it cleared, and
                // the ack — whenever it comes — is paperwork. Recording the
                // clear time here is what lets the downtime analysis end the
                // stop when the machine restarted rather than when somebody
                // got around to pressing OK.
                //
                // `stamp.at`, never `DateTime.now()`. The stamp is resolved
                // once above, from the reading's own `sourceTimestamp` where
                // there is one, and it carries the provenance it was resolved
                // under. Reading this machine's clock here would replace a
                // fact about the plant with a fact about this station — and
                // it would disagree with the two sibling edges a dozen lines
                // up, which both hand the same `stamp` to
                // [_removeActiveAlarm]. That is D-2, and it is the reason
                // `alarm_structure_test.dart` arm 6 permits exactly one
                // `DateTime.now` on this path, at the composition root.
                e.deactivated = stamp.at;
                break;
              }
            }
          }
          _activeAlarmsController.add(_activeAlarms);
        }, onError: (error, stack) {
          stderr.writeln('Alarm stream error: $error');
        });
      }
    };
    _activeAlarmsController.onCancel = () async {};
  }

  /// Loads the configuration and builds the engine.
  ///
  /// [clock] is required and has no default *here*. Composition roots supply
  /// `DateTime.now` — `bin/main.dart` for the backend, the app's alarm
  /// provider for a panel — and this file spells the literal nowhere, which is
  /// the mechanism that keeps a second, hidden reading of the machine clock
  /// from creeping back onto an alarm instant (D-2).
  static Future<AlarmMan> create(
    Preferences preferences,
    StateMan stateMan, {
    required DateTime Function() clock,
    Duration skewWarnAfter = kAlarmSkewWarnAfter,
  }) async {
    var configJson = await preferences.getString('alarm_man_config');
    if (configJson == null) {
      configJson = await preferences.getString('alarm_man_config');
      if (configJson == null) {
        await preferences.setString(
            'alarm_man_config', jsonEncode(AlarmManConfig(alarms: [])));
        configJson = await preferences.getString('alarm_man_config');
      }
    }
    final config = AlarmManConfig.fromJson(jsonDecode(configJson!));
    final alarmMan = AlarmMan._(
        config: config,
        preferences: preferences,
        stateMan: stateMan,
        clock: clock,
        skewWarnAfter: skewWarnAfter);
    try {
      alarmMan._history.addAll(await alarmMan.getRecentAlarms());
      alarmMan._historyController.add(alarmMan._history.buffer);
    } catch (e) {
      stderr.writeln('Error loading history: $e');
    }
    return alarmMan;
  }

  @override
  Stream<Set<AlarmActive>> activeAlarms() {
    return _activeAlarmsController.stream;
  }

  @override
  Stream<List<AlarmActive?>> history() {
    return _historyController.stream;
  }

  /// Acknowledges [alarm] and takes it out of the active set.
  ///
  /// `async` for [AlarmSource]'s sake, not for its own: in direct mode the
  /// panel owns the active set and the local removal is the whole effect, so
  /// there is nothing to await. A gateway-mode implementation sends an RPC,
  /// and the caller must be able to await *that*.
  ///
  /// The deactivation instant is this station's own clock, resolved through
  /// [resolveAlarmStamp] over an empty set of source times so it comes out
  /// labelled [AlarmTsSource.backendReceipt]. That is the truthful provenance:
  /// an acknowledgement is an act of the panel, not something the plant
  /// reported, and no value in the plant carries the instant it happened at.
  @override
  Future<void> ackAlarm(AlarmActive alarm) async {
    // Guarded (#467): an instance that already left the active set (double-tap
    // on the ack button, a stale reference from the history list) must not be
    // pushed into the history a second time.
    if (!_activeAlarms.contains(alarm)) return;
    _removeActiveAlarm(
      alarm,
      resolveAlarmStamp(sourceTimes: const [], clock: _clock),
    );
    _activeAlarmsController.add(_activeAlarms);
  }

  @override
  void addAlarm(AlarmConfig alarm) {
    config.alarms.add(alarm);
    _saveConfig();
    alarms.add(Alarm(config: alarm));
  }

  @override
  void removeAlarm(AlarmConfig alarm) {
    config.alarms.removeWhere((e) => e.uid == alarm.uid);
    _saveConfig();
    alarms.removeWhere((e) => e.config.uid == alarm.uid);
  }

  /// Replaces the alarm carrying [alarm]'s uid, leaving it where it was.
  ///
  /// In place, not remove-then-append. Nothing sorts the alarm editor's list:
  /// it is `config.alarms` in stored order, and `alarms` -- a LinkedHashSet,
  /// so insertion order -- behind it. Appending moved every alarm the
  /// operator edited to the bottom of the list, and because [_saveConfig]
  /// rewrites the whole `alarm_man_config` blob the move was persisted, so it
  /// survived the reload the editor does right after saving.
  ///
  /// An alarm whose uid is not here yet is appended, which is how the
  /// proposal flow creates one: the editor routes both create and update
  /// through this method.
  @override
  void updateAlarm(AlarmConfig alarm) {
    final index = config.alarms.indexWhere((e) => e.uid == alarm.uid);
    if (index == -1) {
      config.alarms.add(alarm);
    } else {
      config.alarms[index] = alarm;
    }
    _saveConfig();
    _replaceLiveAlarm(alarm);
  }

  /// Swaps the live [Alarm] for one rebuilt from [alarm], at the position it
  /// already held in [alarms].
  ///
  /// A Set has no index to assign through, so the order is restored by
  /// rebuilding it. [Alarm] has no `==`, so identity applies and the
  /// replacement never collides with the entry it replaces.
  void _replaceLiveAlarm(AlarmConfig alarm) {
    final replacement = Alarm(config: alarm);
    if (!alarms.any((e) => e.config.uid == alarm.uid)) {
      alarms.add(replacement);
      return;
    }
    final rebuilt = alarms
        .map((e) => e.config.uid == alarm.uid ? replacement : e)
        .toList();
    alarms
      ..clear()
      ..addAll(rebuilt);
  }

  /// See the top-level [filterAlarms] — the behaviour lives there so a
  /// gateway-mode panel cannot answer the same question differently.
  @override
  List<AlarmActive> filterAlarms(
          List<AlarmActive> alarms, String searchQuery) =>
      shared.filterAlarms(alarms, searchQuery);

  void _saveConfig() async {
    await preferences.setString(
        'alarm_man_config', jsonEncode(config.toJson()));
  }

  /// Closes [alarm] at [stamp] and moves it into the history buffer.
  ///
  /// The parameter is a whole [AlarmStamp] rather than a bare [DateTime] on
  /// purpose: this method used to invent the instant with `DateTime.now()`,
  /// and taking the resolved stamp means a caller cannot reach here without
  /// having decided *where the instant came from*. The clearing notification
  /// carries one for a measured clear; [ackAlarm] resolves a receipt stamp for
  /// an acknowledgement.
  void _removeActiveAlarm(AlarmActive alarm, AlarmStamp stamp) {
    alarm.notification.active = false;
    // `??=` (#467): an ack-required alarm already carries its clear time from
    // the moment the condition dropped; stamping again here would silently
    // turn "cleared at 03:12, acked at 07:40" into four and a half hours of
    // invented downtime. The value when it IS unset stays this station's
    // resolved stamp rather than a bare `DateTime.now()`, so the provenance
    // the relay work introduced survives the fix.
    alarm.deactivated ??= stamp.at;
    // Leaving the set means there is nothing left to acknowledge. Clearing
    // the flag (before the row is written) is what keeps a restored history
    // row from ever growing an ack button again.
    alarm.pendingAck = false;
    _history.add(alarm);
    _activeAlarms.remove(alarm);
    _historyController.add(_history.buffer);
  }

  /// Closed activations from `alarm_history`, newest first.
  ///
  /// [from] and [to] bound the window by **overlap**, not by start: an alarm
  /// that went off before [from] and only cleared inside the window is part of
  /// that window's downtime, and a query that dropped it would report a stop
  /// as shorter than it was. One still standing has no deactivation time and
  /// so overlaps every window it started before.
  @override
  Future<List<AlarmActive>> getRecentAlarms({
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) async {
    if (preferences.database == null) return [];

    final db = preferences.database!.db;

    final query = db.select(db.alarmHistory);
    if (from != null || to != null) {
      query.where((t) => alarmHistoryOverlaps(t, from: from, to: to));
    }
    final result = await (query
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)
          ])
          ..limit(limit))
        .get();

    return result
        .map((row) {
          // Find the corresponding alarm config from our current alarms
          final alarmConfig = alarms.firstWhereOrNull(
            (a) => a.config.uid == row.alarmUid,
          );

          // Skip this alarm if config is not found
          if (alarmConfig == null) {
            return null;
          }

          // The row names which rule fired (schema v7), so the real rule can
          // be resolved out of the current configuration rather than
          // reconstructed with a guess. This used to hardcode
          // `acknowledgeRequired: false` with the comment "we don't store
          // this in history" — which made every historical alarm look like
          // one nobody had to acknowledge.
          final ruleIndex = row.ruleIndex;
          final configuredRule = ruleIndex != null &&
                  ruleIndex >= 0 &&
                  ruleIndex < alarmConfig.config.rules.length
              ? alarmConfig.config.rules[ruleIndex]
              : null;

          final rule = AlarmRule(
            level: AlarmLevel.values.firstWhere(
              (l) => l.name == row.alarmLevel,
            ),
            expression: ExpressionConfig(
              value: Expression(formula: row.expression ?? ''),
            ),
            // A pre-v7 row states no rule index, and a row whose index no
            // longer exists in the configuration names a rule that has been
            // deleted. Neither can be resolved, and matching such a row to
            // rule 0 would be a guess dressed as a fact — so it keeps the old
            // `false` and says nothing it cannot support.
            acknowledgeRequired: configuredRule?.acknowledgeRequired ?? false,
          );

          final notification = AlarmNotification(
            uid: row.alarmUid,
            active: row.active,
            expression: row.expression,
            rule: rule,
            timestamp: row.createdAt,
            ruleIndex: ruleIndex,
            tsSource: _tsSourceOf(row.tsSource),
          );

          // Create and return AlarmActive
          return AlarmActive(
            alarm: alarmConfig,
            notification: notification,
            pendingAck: row.pendingAck,
            deactivated: row.deactivatedAt,
          );
        })
        .whereType<AlarmActive>()
        .toList();
  }

  /// What a stored `ts_source` means, or null when the row states nothing.
  ///
  /// Null is not the same as [AlarmTsSource.backendReceipt] on a row: a pre-v7
  /// row predates the column entirely and nobody recorded anything, which is
  /// worth being able to tell apart from a row that positively says the
  /// backend guessed.
  static AlarmTsSource? _tsSourceOf(String? stored) {
    if (stored == null) return null;
    return stored == AlarmTsSource.plant.wireName
        ? AlarmTsSource.plant
        : AlarmTsSource.backendReceipt;
  }
}

class Alarm {
  final AlarmConfig config;

  /// Whether each rule was satisfied at its last evaluation.
  ///
  /// A **bool**, not the formatted expression string. Comparing the formatted
  /// string meant comparing something that embeds the bound VALUES, so a rule
  /// that stayed true while its inputs moved emitted a fresh notification on
  /// every tag update — which in `AlarmMan` closes the standing activation and
  /// opens a new one each time (P-3). An alarm changes when its verdict
  /// changes; the text is a description of the verdict, not the verdict.
  ///
  /// Seeded `false`, which is what the old `null` meant: a first evaluation
  /// that is unsatisfied is not a transition and emits nothing.
  final List<bool> _lastEvaluations;

  Alarm({required this.config})
      : _lastEvaluations = List.filled(config.rules.length, false);

  /// One notification per rule transition, stamped from the plant.
  ///
  /// [clock] is required and is only reached when an evaluation binds no
  /// source timestamp — see [resolveAlarmStamp]. It is injected rather than
  /// read so that two panels watching one plant cannot disagree about when a
  /// stop began, and so that this file spells `DateTime.now` nowhere.
  Stream<AlarmNotification> onChange(
    StateMan stateMan, {
    required DateTime Function() clock,
    Duration skewWarnAfter = kAlarmSkewWarnAfter,
  }) {
    final streamController = StreamController<AlarmNotification>.broadcast();
    final evaluators = <Evaluator>[];

    streamController.onListen = () async {
      for (var i = 0; i < config.rules.length; i++) {
        final rule = config.rules[i];
        final evaluator =
            Evaluator(stateMan: stateMan, expression: rule.expression);
        evaluators.add(evaluator);
        // evaluations(), not state(): the false branch carries its bindings
        // too (14-02), and without them a deactivation has no plant instant
        // to be stamped from and would silently take this machine's clock.
        evaluator.evaluations().listen((evaluation) {
          final satisfied = evaluation.satisfied;
          // Only emit on a transition of the VERDICT for this rule.
          if (satisfied == _lastEvaluations[i]) return;
          _lastEvaluations[i] = satisfied;

          final stamp = resolveAlarmStamp(
            sourceTimes:
                evaluation.bindings.values.map((v) => v.sourceTimestamp),
            clock: clock,
            skewWarnAfter: skewWarnAfter,
            onSkew: (skew, sourceTime) => stderr.writeln(
                'Alarm ${config.uid} rule $i: the plant instant $sourceTime is '
                '${skew.inSeconds}s from this station\'s clock. Recorded '
                'unchanged — clamping it would hide a clock fault.'),
          );

          streamController.add(AlarmNotification(
              uid: config.uid,
              active: satisfied,
              // Built on the satisfied branch only: formatting walks every
              // bound value's toString(), and the unsatisfied branch has no
              // text to show (T-14-07).
              expression: satisfied
                  ? rule.expression.value.formatWithValues(evaluation.bindings)
                  : null,
              rule: rule,
              timestamp: stamp.at,
              ruleIndex: i,
              tsSource: stamp.source));
        }, onError: (error, stack) {
          streamController.addError(error, stack);
        });
      }
    };

    streamController.onCancel = () async {
      for (final evaluator in evaluators) {
        evaluator.cancel();
      }
    };

    return streamController.stream;
  }
}

class AlarmNotification {
  final String uid;
  bool active;
  String? expression;
  final AlarmRule rule;
  final DateTime timestamp;

  /// Which rule of [AlarmConfig.rules] this is about, or null when nobody
  /// said.
  ///
  /// Optional with **no default**: this type is constructed at a dozen call
  /// sites, most of them test fixtures, and it is read back off pre-v7
  /// `alarm_history` rows that predate the `rule_index` column. Null therefore
  /// honestly means "not stated" — a default of 0 would quietly claim every
  /// one of them was the first rule.
  final int? ruleIndex;

  /// Whether [timestamp] came from the plant or from a clock, or null when
  /// nobody said. See [AlarmTsSource].
  final AlarmTsSource? tsSource;

  /// The keys whose bad quality is HOLDING this alarm's state, or empty.
  ///
  /// Filled only from the backend's `ALARM.active` payload
  /// (`AlarmActiveEntry.staleInputs`): a non-empty list means D-3's quality
  /// gate has suspended the rule, the boolean on screen is remembered rather
  /// than being re-earned, and it can neither clear nor re-fire until the
  /// named inputs return. Direct-mode notifications leave it empty — the old
  /// evaluator has no gate and therefore no hold to report.
  final List<String> staleInputs;

  /// When the hold began, UTC, or null when [staleInputs] is empty.
  final DateTime? staleSince;

  AlarmNotification(
      {required this.uid,
      required this.active,
      required this.expression,
      required this.rule,
      required this.timestamp,
      this.ruleIndex,
      this.tsSource,
      this.staleInputs = const [],
      this.staleSince});

  /// [timestamp] with its provenance, as one value.
  ///
  /// A notification produced by [Alarm.onChange] always states a [tsSource].
  /// One that does not — a fixture, or a row written before the column
  /// existed — reads as [AlarmTsSource.backendReceipt], because nobody
  /// recorded that the plant supplied the instant, and that is the same
  /// reading 14-06 gives an adopted pre-v7 row.
  AlarmStamp get stamp => AlarmStamp(
        at: timestamp,
        source: tsSource ?? AlarmTsSource.backendReceipt,
      );

  @override
  String toString() {
    return 'AlarmNotification(uid: $uid, active: $active, expression: $expression, rule: $rule, timestamp: $timestamp, ruleIndex: $ruleIndex, tsSource: $tsSource)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AlarmNotification &&
        uid == other.uid &&
        active == other.active &&
        expression == other.expression &&
        rule == other.rule;
  }

  @override
  int get hashCode => Object.hash(uid, active, expression, rule);
}

class AlarmActive {
  final Alarm alarm;
  final AlarmNotification notification;
  bool pendingAck;
  DateTime? deactivated;

  @override
  String toString() {
    return 'AlarmActive(alarm: $alarm, notification: $notification, deactivated: $deactivated)';
  }

  AlarmActive({
    required this.alarm,
    required this.notification,
    this.pendingAck = false,
    this.deactivated,
  });
}
