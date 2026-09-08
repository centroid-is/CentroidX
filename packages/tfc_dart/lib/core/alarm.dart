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

import 'database_drift.dart' show $AlarmHistoryTable;
import 'preferences.dart';
import 'state_man.dart';
import 'ring_buffer.dart';
import 'boolean_expression.dart';
import 'fuzzy_match.dart';

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

@JsonSerializable()
class AlarmManLocalConfig {
  final bool historyToDb;

  AlarmManLocalConfig({required this.historyToDb});

  factory AlarmManLocalConfig.fromJson(Map<String, dynamic> json) =>
      _$AlarmManLocalConfigFromJson(json);
  Map<String, dynamic> toJson() => _$AlarmManLocalConfigToJson(this);
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
/// `timestamp` the way `AlarmMan._addToDb`'s insert casts what it writes.
/// Both casts are needed: storing datetimes as text makes drift declare these
/// columns `text` on Postgres too, and drift_postgres types a mapped `String`
/// variable as `Type.text`, so without the casts neither side is a timestamp
/// and the comparison is `text <= text` — lexicographic, and wrong the moment
/// two rows were written in different formats. `alarm_history` holds both:
/// `_addToDb` inserts through a `::timestamp` cast, which Postgres
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

class AlarmMan {
  final AlarmManConfig config;
  final AlarmManLocalConfig localConfig;
  final Preferences preferences;
  final StateMan stateMan;
  final Set<Alarm> alarms;
  final Set<AlarmActive> _activeAlarms;
  final StreamController<Set<AlarmActive>> _activeAlarmsController;
  final RingBuffer<AlarmActive> _history;
  final StreamController<List<AlarmActive?>> _historyController;
  AlarmMan._(
      {required this.config,
      required this.preferences,
      required this.stateMan,
      required this.localConfig})
      : alarms = config.alarms.map((e) => Alarm(config: e)).toSet(),
        _activeAlarms = {},
        _activeAlarmsController = BehaviorSubject<Set<AlarmActive>>.seeded({}),
        _history = RingBuffer<AlarmActive>(1000),
        _historyController = BehaviorSubject<List<AlarmActive?>>.seeded([]) {
    _activeAlarmsController.onListen = () async {
      for (final alarm in alarms) {
        final stream = alarm.onChange(stateMan);
        stream.listen((alarmNotification) {
          final existing = _activeAlarms.firstWhereOrNull((e) =>
              // the uid must match, we are in correct closure
              e.alarm.config.uid == alarm.config.uid &&
              // the rule must match
              e.notification.rule == alarmNotification.rule);

          if (alarmNotification.active) {
            if (existing != null) {
              _removeActiveAlarm(existing);
            }
            _activeAlarms.add(
                AlarmActive(alarm: alarm, notification: alarmNotification));
          } else if (!alarmNotification.rule.acknowledgeRequired) {
            if (existing != null) {
              _removeActiveAlarm(existing);
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

  static Future<AlarmMan> create(Preferences preferences, StateMan stateMan,
      {historyToDb = false}) async {
    final localConfig = AlarmManLocalConfig(historyToDb: historyToDb);

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
        localConfig: localConfig);
    try {
      alarmMan._history.addAll(await alarmMan.getRecentAlarms());
      alarmMan._historyController.add(alarmMan._history.buffer);
    } catch (e) {
      stderr.writeln('Error loading history: $e');
    }
    return alarmMan;
  }

  Stream<Set<AlarmActive>> activeAlarms() {
    return _activeAlarmsController.stream;
  }

  Stream<List<AlarmActive?>> history() {
    return _historyController.stream;
  }

  void ackAlarm(AlarmActive alarm) {
    _removeActiveAlarm(alarm);
    _activeAlarmsController.add(_activeAlarms);
  }

  void addAlarm(AlarmConfig alarm) {
    config.alarms.add(alarm);
    _saveConfig();
    alarms.add(Alarm(config: alarm));
  }

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

  void _saveConfig() async {
    await preferences.setString(
        'alarm_man_config', jsonEncode(config.toJson()));
  }

  void _removeActiveAlarm(AlarmActive alarm) {
    alarm.notification.active = false;
    alarm.deactivated = DateTime.now();
    _history.add(alarm);
    _activeAlarms.remove(alarm);
    _historyController.add(_history.buffer);
    if (localConfig.historyToDb) {
      _addToDb(alarm);
    }
  }

  Future<void> _addToDb(AlarmActive alarm) async {
    // todo this should work but timestamp does not propagate correctly through drift
    // see the casting below
    // await db.into(db.alarmHistory).insert(AlarmHistoryCompanion.insert(
    //   alarmUid: alarm.alarm.config.uid,
    //   alarmTitle: alarm.alarm.config.title,
    //   alarmDescription: alarm.alarm.config.description,
    //   alarmLevel: alarm.notification.rule.level.name,
    //   expression: alarm.notification.expression != null
    //       ? Value(alarm.notification.expression!)
    //       : const Value.absent(),
    //   active: alarm.notification.active,
    //   pendingAck: alarm.pendingAck,
    //   createdAt: alarm.notification.timestamp,
    //   deactivatedAt: alarm.deactivated != null
    //       ? Value(alarm.deactivated!)
    //       : const Value.absent(),
    // ));

    if (preferences.database == null) return;
    final db = preferences.database!.db;

    // Use custom SQL with proper timestamp casting for PostgreSQL
    await db.customInsert(r'''
      INSERT INTO alarm_history (
        alarm_uid, alarm_title, alarm_description, alarm_level, 
        expression, active, pending_ack, created_at, deactivated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::timestamp, $9::timestamp)
    ''', variables: [
      Variable.withString(alarm.alarm.config.uid),
      Variable.withString(alarm.alarm.config.title),
      Variable.withString(alarm.alarm.config.description),
      Variable.withString(alarm.notification.rule.level.name),
      Variable.withString(alarm.notification.expression ?? ''),
      Variable.withBool(alarm.notification.active),
      Variable.withBool(alarm.pendingAck),
      Variable.withString(alarm.notification.timestamp.toIso8601String()),
      Variable.withString(alarm.deactivated?.toIso8601String() ?? ''),
    ]);
  }

  /// Closed activations from `alarm_history`, newest first.
  ///
  /// [from] and [to] bound the window by **overlap**, not by start: an alarm
  /// that went off before [from] and only cleared inside the window is part of
  /// that window's downtime, and a query that dropped it would report a stop
  /// as shorter than it was. One still standing has no deactivation time and
  /// so overlaps every window it started before.
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

          // Create AlarmRule from stored data
          final rule = AlarmRule(
            level: AlarmLevel.values.firstWhere(
              (l) => l.name == row.alarmLevel,
            ),
            expression: ExpressionConfig(
              value: Expression(formula: row.expression ?? ''),
            ),
            acknowledgeRequired: false, // We don't store this in history
          );

          // Create AlarmNotification
          final notification = AlarmNotification(
            uid: row.alarmUid,
            active: row.active,
            expression: row.expression,
            rule: rule,
            timestamp: row.createdAt,
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
}

class Alarm {
  final AlarmConfig config;
  final List<String?> _lastEvaluations;

  Alarm({required this.config})
      : _lastEvaluations = List.filled(config.rules.length, null);

  Stream<AlarmNotification> onChange(StateMan stateMan) {
    final streamController = StreamController<AlarmNotification>.broadcast();
    final evaluators = <Evaluator>[];

    streamController.onListen = () async {
      for (var i = 0; i < config.rules.length; i++) {
        final rule = config.rules[i];
        final evaluator =
            Evaluator(stateMan: stateMan, expression: rule.expression);
        evaluators.add(evaluator);
        evaluator.state().listen((state) {
          // Only emit if state has changed for this rule
          if (state != _lastEvaluations[i]) {
            _lastEvaluations[i] = state;
            // If this rule is true, the alarm is active
            final alarmState = state != null;
            streamController.add(AlarmNotification(
                uid: config.uid,
                active: alarmState,
                expression: _lastEvaluations[i],
                rule: rule,
                timestamp: DateTime.now()));
          }
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

  AlarmNotification(
      {required this.uid,
      required this.active,
      required this.expression,
      required this.rule,
      required this.timestamp});

  @override
  String toString() {
    return 'AlarmNotification(uid: $uid, active: $active, expression: $expression, rule: $rule, timestamp: $timestamp)';
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
