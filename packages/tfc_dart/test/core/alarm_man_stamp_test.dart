@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:open62541/open62541.dart'
    show ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart';
// `show`, not a bare import: `database_drift.dart` also declares an `Alarm`
// (the drift row class), and this file means `core/alarm.dart`'s.
import 'package:tfc_dart/core/database_drift.dart'
    show AlarmHistoryCompanion, AppDatabase;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A direct-mode panel stamps alarm transitions from the plant, not from its
/// own wristwatch — and it no longer contains anything that could write a row.
///
/// Three claims, all of them things a second panel standing next to the first
/// would otherwise disagree with it about:
///
/// 1. **Both edges carry the plant's instant.** An activation and a
///    deactivation are stamped by `resolveAlarmStamp` over the source
///    timestamps of the values the evaluation bound, with the provenance
///    travelling alongside as [AlarmTsSource]. Before 14-02 the clearing edge
///    could not do this at all: the false branch threw its bindings away.
/// 2. **The clock is injected.** `DateTime.now()` appears nowhere in
///    `alarm.dart`; the composition root supplies the reading, and the
///    fallback path says so on the record (`backend_receipt`).
/// 3. **There is no write path.** `historyToDb`, `AlarmManLocalConfig` and
///    `_addToDb` are gone. A class that contains no insert cannot be
///    configured into writing one beside the backend (D-6).
///
/// The clock below reads hours away from every plant instant on purpose. An
/// assertion that a row carries the plant's time is worth nothing if the two
/// agree by accident.

// --------------------------------------------------------------------------
// fixtures

/// The instant the plant says things happened at.
final plantOnset = DateTime.utc(2026, 9, 6, 12, 0, 0);
final plantClear = DateTime.utc(2026, 9, 6, 13, 30, 0);

/// What the panel's own clock reads throughout — deliberately nowhere near
/// either plant instant.
final receipt = DateTime.utc(2026, 9, 6, 23, 45, 12);

/// A clock that is a value, and that counts how often it was asked.
///
/// `DateTime.now()` is not spelled anywhere in this file: the whole point of
/// the change under test is that the instant comes from outside.
class _FixedClock {
  _FixedClock(this.at);

  DateTime at;
  int reads = 0;

  DateTime read() {
    reads++;
    return at;
  }
}

/// A [ClientApi] whose monitored items are driven by the test.
///
/// The shape is repeated from `evaluator_hot_path_test.dart` rather than
/// imported: `_FakeClientApi` is library-private there, and lifting it into
/// `test/support/` would touch a file this plan does not own.
class _FakeClientApi implements ClientApi {
  final Map<NodeId, StreamController<DynamicValue>> _controllers = {};

  void emit(NodeId node, DynamicValue value) => _controllers[node]?.add(value);

  bool isMonitored(NodeId node) => _controllers.containsKey(node);

  @override
  Future<void> awaitConnect() async {}

  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async =>
      1;

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) {
    late StreamController<DynamicValue> controller;
    // StateMan._monitor waits for a first value before it calls the subscribe
    // successful. 0.0 does not satisfy `a > 5`, so the rule starts false.
    controller = StreamController<DynamicValue>(
      onListen: () => controller.add(DynamicValue(value: 0.0)),
    );
    _controllers[nodeId] = controller;
    return controller.stream;
  }

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final _nodeA = NodeId.fromString(4, 'plant.a');

KeyMappings _mappings() => KeyMappings(nodes: {
      'a': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'plant.a')
          ..serverAlias = 'st101',
      ),
    });

/// A secure store that refuses: nothing here handles secret material, and the
/// default instance prompts for the macOS login keychain
/// (project memory `macos-debug-keychain-prompts`).
final class _RefusingSecureStorage implements MySecureStorage {
  const _RefusingSecureStorage();

  static Never _refuse(String op) => throw StateError(
      'the alarm stamping lane handles no secret material: $op was asked of '
      'the refusing secure store');

  @override
  Future<String?> read({required String key}) async => _refuse('read');

  @override
  Future<void> write({required String key, required String value}) async =>
      _refuse('write');

  @override
  Future<void> delete({required String key}) async => _refuse('delete');
}

AlarmRule _rule({
  String formula = 'a > 5',
  AlarmLevel level = AlarmLevel.error,
  bool acknowledgeRequired = false,
}) =>
    AlarmRule(
      level: level,
      expression: ExpressionConfig(value: Expression(formula: formula)),
      acknowledgeRequired: acknowledgeRequired,
    );

AlarmConfig _config({List<AlarmRule>? rules}) => AlarmConfig(
      uid: 'CN04.MOT01',
      title: 'Motor overload',
      description: 'the drive tripped',
      rules: rules ?? [_rule()],
    );

Future<void> _waitFor(
  bool Function() test, {
  Duration budget = const Duration(seconds: 6),
}) async {
  var waited = Duration.zero;
  const step = Duration(milliseconds: 10);
  while (!test() && waited < budget) {
    await Future<void>.delayed(step);
    waited += step;
  }
}

/// `lib/core/alarm.dart` with `//` and `///` lines removed.
///
/// A source scan is the only way to assert the *absence* of a member that no
/// longer exists: an arm that named `historyToDb` would not compile, and one
/// that did not name it would not notice its return.
String _alarmSourceWithoutComments() {
  final file = File('lib/core/alarm.dart');
  expect(file.existsSync(), isTrue,
      reason: 'run this suite from packages/tfc_dart');
  return file
      .readAsLinesSync()
      .where((l) => !RegExp(r'^\s*//').hasMatch(l))
      .join('\n');
}

void main() {
  group('AlarmMan stamps both edges from the plant', () {
    late _FakeClientApi fake;
    late OpcUaStateMan stateMan;
    late Preferences preferences;
    late _FixedClock clock;

    setUp(() async {
      Preferences.clearSecretCache();
      clock = _FixedClock(receipt);
      fake = _FakeClientApi();
      stateMan = await OpcUaStateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: _mappings(),
        deviceClients: const [],
      );
      stateMan.clients
          .add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'st101'));
      preferences = Preferences(
        database: null,
        secureStorage: const _RefusingSecureStorage(),
      );
    });

    tearDown(() async {
      await stateMan
          .close()
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    });

    Future<AlarmMan> boot({List<AlarmRule>? rules}) async {
      await preferences.setString(
        'alarm_man_config',
        '{"alarms":[${_configJson(rules)}]}',
        saveToDb: false,
      );
      final man = await AlarmMan.create(
        preferences,
        stateMan,
        clock: clock.read,
      );
      return man;
    }

    test('an activation is stamped from the plant', () async {
      final man = await boot();
      final seen = <Set<AlarmActive>>[];
      final sub = man.activeAlarms().listen(seen.add);
      await _waitFor(() => fake.isMonitored(_nodeA));

      fake.emit(_nodeA, DynamicValue(value: 10.0)..sourceTimestamp = plantOnset);
      await _waitFor(() => seen.any((s) => s.isNotEmpty));

      final active = seen.last.single;
      expect(active.notification.timestamp, plantOnset,
          reason: 'the onset is the newest bound source timestamp, not the '
              'panel clock ($receipt)');
      expect(active.notification.tsSource, AlarmTsSource.plant);
      expect(active.notification.ruleIndex, 0);

      await sub.cancel();
    });

    test('a deactivation is stamped from the plant', () async {
      // The arm that could not exist before 14-02: on the false branch there
      // were no bindings to stamp from, so every clear took the machine clock.
      final man = await boot();
      final active = <Set<AlarmActive>>[];
      final history = <List<AlarmActive?>>[];
      final subA = man.activeAlarms().listen(active.add);
      final subH = man.history().listen(history.add);
      await _waitFor(() => fake.isMonitored(_nodeA));

      fake.emit(_nodeA, DynamicValue(value: 10.0)..sourceTimestamp = plantOnset);
      await _waitFor(() => active.any((s) => s.isNotEmpty));

      fake.emit(_nodeA, DynamicValue(value: 1.0)..sourceTimestamp = plantClear);
      // Wait for a CLOSED entry, not merely a non-empty history event: the
      // history stream carries `RingBuffer.buffer`, a fixed 1000-slot list of
      // nulls, so `isNotEmpty` is true from the first event onwards.
      await _waitFor(() => history.last
          .whereType<AlarmActive>()
          .any((e) => e.deactivated != null));

      expect(active.last, isEmpty, reason: 'the alarm cleared');
      final closed = history.last.whereType<AlarmActive>().single;
      expect(closed.deactivated, plantClear,
          reason: 'the clearing evaluation carried a plant instant and it is '
              'the one recorded');
      expect(closed.notification.timestamp, plantOnset,
          reason: 'the onset is untouched by the clear');

      await subA.cancel();
      await subH.cancel();
    });

    test('null sourceTimestamp falls back to the clock, labelled', () async {
      final man = await boot();
      final seen = <Set<AlarmActive>>[];
      final sub = man.activeAlarms().listen(seen.add);
      await _waitFor(() => fake.isMonitored(_nodeA));

      // No sourceTimestamp at all: an unlabelled guess is the thing D-2
      // forbids, so the stamp is the clock's and it says so.
      fake.emit(_nodeA, DynamicValue(value: 10.0));
      await _waitFor(() => seen.any((s) => s.isNotEmpty));

      final active = seen.last.single;
      expect(active.notification.timestamp, receipt);
      expect(active.notification.tsSource, AlarmTsSource.backendReceipt);
      expect(clock.reads, greaterThan(0),
          reason: 'the fallback instant came from the injected clock');

      await sub.cancel();
    });

    test('a still-true rule whose values move emits once', () async {
      // P-3: the old dedupe compared `formatWithValues(...)`, which embeds the
      // VALUES, so a standing alarm re-notified on every tag update.
      final alarm = Alarm(config: _config());
      final seen = <AlarmNotification>[];
      final sub =
          alarm.onChange(stateMan, clock: clock.read).listen(seen.add);
      await _waitFor(() => fake.isMonitored(_nodeA));

      for (var i = 0; i < 10; i++) {
        fake.emit(
            _nodeA,
            DynamicValue(value: 10.0 + i)
              ..sourceTimestamp = plantOnset.add(Duration(seconds: i)));
      }
      await _waitFor(() => seen.isNotEmpty);
      // Bounded wait for the wrong thing: if a second notification is coming,
      // this is where it arrives.
      await _waitFor(() => seen.length > 1,
          budget: const Duration(milliseconds: 400));

      expect(seen, hasLength(1),
          reason: 'ten value updates across one standing alarm are one '
              'transition, not ten notifications');
      expect(seen.single.active, isTrue);

      await sub.cancel();
    });

    test('AlarmMan is an AlarmSource, and the whole interface is callable',
        () async {
      final man = await boot();
      expect(man, isA<AlarmSource>());

      final AlarmSource source = man;
      expect(source.config.alarms, hasLength(1));
      expect(source.alarms, hasLength(1));
      expect(source.activeAlarms(), isA<Stream<Set<AlarmActive>>>());
      expect(source.history(), isA<Stream<List<AlarmActive?>>>());
      expect(await source.getRecentAlarms(), isEmpty);
      expect(source.filterAlarms(const [], ''), isEmpty);

      // ackAlarm must be awaitable: 14-09's gateway implementation crosses a
      // wire to acknowledge, and a `void` member would oblige it to fire and
      // forget — the silent-loss failure this project exists to prevent.
      final ack = source.ackAlarm(AlarmActive(
        alarm: Alarm(config: _config()),
        notification: AlarmNotification(
          uid: 'CN04.MOT01',
          active: true,
          expression: null,
          rule: _rule(),
          timestamp: plantOnset,
        ),
      ));
      expect(ack, isA<Future<void>>());
      await ack;

      final extra = AlarmConfig(
          uid: 'CN05.MOT01', title: 't', description: 'd', rules: [_rule()]);
      source.addAlarm(extra);
      expect(source.config.alarms, hasLength(2));
      source.updateAlarm(AlarmConfig(
          uid: 'CN05.MOT01', title: 't2', description: 'd', rules: [_rule()]));
      expect(source.config.alarms.map((e) => e.title), contains('t2'));
      source.removeAlarm(extra);
      expect(source.config.alarms, hasLength(1));
    });
  });

  group('the write path is gone by construction', () {
    test('historyToDb is gone as a concept', () {
      final source = _alarmSourceWithoutComments();
      expect(source, isNot(contains('historyToDb')),
          reason: 'D-6: a flag that decides whether an object writes to a '
              'database is a flag somebody sets wrong');
      expect(source, isNot(contains('AlarmManLocalConfig')));
      expect(source, isNot(contains('_addToDb')));
      expect(source, isNot(contains('customInsert')),
          reason: 'AlarmMan contains no insert statement at all');
      expect(source, isNot(contains('INSERT INTO')));
      expect(source, isNot(contains('Variable.withString(')),
          reason: 'the write-side binds went with _addToDb — including the '
              "expression column's `?? ''`, which 14-06 left for this plan");
    });

    test("the one surviving `?? ''` is a read, not a bind", () {
      // 14-06 recorded two remaining empty-string defaults, at :486 and :549,
      // and expected both to leave with `_addToDb`. Only :486 did. :549 is
      // `Expression(formula: row.expression ?? '')` in `getRecentAlarms` — a
      // READ, giving a non-nullable constructor a neutral value for a row
      // whose expression column is null. It is not a SQL bind, it cannot
      // reach a database, and it does not live in the deleted method. This
      // arm pins that reading so the discrepancy is not rediscovered as a
      // defect.
      final lines = _alarmSourceWithoutComments()
          .split('\n')
          .where((l) => l.contains("?? ''"))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('Expression(formula:'));
    });

    test('the clock is injected, not read', () {
      expect(_alarmSourceWithoutComments(), isNot(contains('DateTime.now(')),
          reason: 'D-2: both alarm.dart:444 and :595 are gone; the '
              'composition root supplies the reading');
    });
  });

  group('getRecentAlarms reads what the row says', () {
    late AppDatabase appDb;
    late Database database;
    late Preferences preferences;

    setUp(() async {
      Preferences.clearSecretCache();
      appDb = _MemoryDb();
      database = Database(appDb);
      preferences = Preferences(
        database: database,
        secureStorage: const _RefusingSecureStorage(),
      );
    });

    tearDown(() async {
      await database.dispose();
      await appDb.close();
    });

    Future<int> seed({
      required int? ruleIndex,
      String? tsSource,
    }) =>
        appDb.into(appDb.alarmHistory).insert(
              AlarmHistoryCompanion.insert(
                alarmUid: 'CN04.MOT01',
                alarmTitle: 'Motor overload',
                alarmDescription: 'the drive tripped',
                alarmLevel: 'error',
                expression: const Value('a{10.0} > 5'),
                active: false,
                pendingAck: false,
                createdAt: plantOnset,
                deactivatedAt: Value(plantClear),
                ruleIndex: Value(ruleIndex),
                tsSource: Value(tsSource),
              ),
            );

    test('a row with a rule_index resolves the real rule', () async {
      // Rule 1 is the acknowledge-required one. `getRecentAlarms` used to
      // hardcode `acknowledgeRequired: false` with the comment "we don't
      // store this in history" — but the rule index IS stored now, and the
      // configuration is right here.
      await preferences.setString(
        'alarm_man_config',
        '{"alarms":[${_configJson([
              _rule(acknowledgeRequired: false),
              _rule(level: AlarmLevel.warning, acknowledgeRequired: true),
            ])}]}',
        saveToDb: false,
      );
      await seed(ruleIndex: 1, tsSource: 'plant');

      final man = await AlarmMan.create(preferences, _UnusedStateMan(),
          clock: _FixedClock(receipt).read);
      final rows = await man.getRecentAlarms();

      expect(rows, hasLength(1));
      expect(rows.single.notification.ruleIndex, 1);
      expect(rows.single.notification.tsSource, AlarmTsSource.plant);
      expect(rows.single.notification.rule.acknowledgeRequired, isTrue,
          reason: 'the row names rule 1, and rule 1 requires an acknowledge');
    });

    test('a legacy row with no rule_index still maps, saying nothing',
        () async {
      await preferences.setString(
        'alarm_man_config',
        '{"alarms":[${_configJson([_rule(acknowledgeRequired: true)])}]}',
        saveToDb: false,
      );
      await seed(ruleIndex: null, tsSource: null);

      final man = await AlarmMan.create(preferences, _UnusedStateMan(),
          clock: _FixedClock(receipt).read);
      final rows = await man.getRecentAlarms();

      expect(rows, hasLength(1));
      expect(rows.single.notification.ruleIndex, isNull);
      expect(rows.single.notification.tsSource, isNull,
          reason: 'a pre-v7 row states no provenance, and null is the honest '
              'reading of that — not a guessed backend_receipt');
      expect(rows.single.notification.rule.acknowledgeRequired, isFalse,
          reason: 'no index means no rule to resolve; a guess dressed as a '
              'fact is the one thing D-4 forbids');
    });
  });
}

/// A `StateMan` that refuses everything by name.
///
/// `getRecentAlarms` is a database read and must not need a plant connection;
/// a permissive stub would let the arm pass for the wrong reason.
final class _UnusedStateMan implements StateMan {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'getRecentAlarms reached the StateMan (${invocation.memberName})');
}

class _MemoryDb extends AppDatabase {
  _MemoryDb() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

String _configJson(List<AlarmRule>? rules) {
  final list = rules ?? [_rule()];
  final ruleJson = list
      .map((r) => '{"level":"${r.level.name}",'
          '"expression":{"value":{"formula":"${r.expression.value.formula}"}},'
          '"acknowledgeRequired":${r.acknowledgeRequired}}')
      .join(',');
  return '{"uid":"CN04.MOT01","title":"Motor overload",'
      '"description":"the drive tripped","rules":[$ruleJson]}';
}
