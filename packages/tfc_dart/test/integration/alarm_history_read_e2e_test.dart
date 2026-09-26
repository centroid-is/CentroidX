/// The alarm-history read, measured end to end against a real TimescaleDB.
///
/// ## Why this file is in the Docker lane
///
/// The window this read is bounded by is a **datetime comparison**, and a
/// datetime comparison is the one thing in this codebase that has been measured
/// to pass on SQLite and fail on the plant's server. Drift rewrites
/// `column <= value` on a `DateTimeColumn` into `JULIANDAY(...)`, which Postgres
/// does not have; `alarmHistoryOverlaps` (`alarm.dart:301`) exists to spell the
/// comparison so it survives both, and `_DateTimeBound`'s own doc records that
/// without the `::timestamp` casts the comparison silently degrades into a
/// lexicographic `text <= text`. Neither failure is visible from a SQLite suite,
/// so `backend_alarm_history_source_test.dart` — which is green on SQLite —
/// is not evidence about the plant.
///
/// This file therefore runs the **shipping composition** over a real server:
/// the rows are written by `AlarmHistoryWriter`, which is the only thing that
/// writes them in production, and they are read back by a panel over a real
/// socket through the gateway `bin/main.dart` builds.
///
/// **Port 15432 is hardcoded in `docker_compose.dart` and a parallel worktree
/// run collides** (project memory `tfc-dart-integration-port-collision`). Run
/// this file ALONE, or with `--concurrency=1` alongside the other db-tagged
/// files.
@TestOn('vm')
@Tags(['db', 'ws'])
@Timeout(Duration(minutes: 10))
library;

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart' show Database;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../support/backend_ws_harness.dart';
import 'docker_compose.dart';

/// A secure store that refuses, so this process never reaches a keychain.
///
/// `Preferences.create` asks `SecureStorage.getInstance()` unconditionally, and
/// the default instance on macOS prompts for the login keychain on every fresh
/// binary (project memory `macos-debug-keychain-prompts`). Nothing in this file
/// wants secret material. Restated rather than shared because every db-lane
/// file in this directory carries its own copy for the same reason.
final class RefusingSecureStorage implements MySecureStorage {
  const RefusingSecureStorage();

  static Never _refuse(String op) => throw StateError(
      'the alarm history read lane handles no secret material: $op was asked '
      'of the refusing secure store');

  @override
  Future<String?> read({required String key}) async => _refuse('read');

  @override
  Future<void> write({required String key, required String value}) async =>
      _refuse('write');

  @override
  Future<void> delete({required String key}) async => _refuse('delete');
}

/// The shift every window arm is judged against: 08:00–16:00 on one day.
final _day = DateTime.utc(2026, 8, 29);

DateTime _at(int hour) => _day.add(Duration(hours: hour));

const _uid = 'ST101.CN01.MOT01.overtemp';

/// The definitions the engine runs, so `group` and `acknowledgeRequired` have
/// somewhere to be resolved from.
AlarmManConfig _alarmConfig() => AlarmManConfig(alarms: [
      AlarmConfig(
        uid: _uid,
        title: 'Motor overtemperature',
        description: 'The pre-freezer conveyor motor is over its limit',
        group: const ['Line 3', 'Pre-freezer'],
        rules: [
          AlarmRule(
            level: AlarmLevel.error,
            expression:
                ExpressionConfig(value: Expression(formula: '{x} > 40')),
            acknowledgeRequired: true,
          ),
        ],
      ),
    ]);

void main() {
  group('alarmHistory over a real TimescaleDB', () {
    late AppDatabase appDatabase;
    late Database database;
    late Preferences preferences;
    late AlarmHistoryWriter writer;
    var fixtureUp = false;

    setUpAll(() async {
      SecureStorage.setInstance(const RefusingSecureStorage());
      await startDockerCompose();
      await waitForDatabaseReady();

      appDatabase = await AppDatabase.create(getTestConfig());
      await appDatabase.open();
      database = Database(appDatabase);
      preferences = await Preferences.create(db: database);
      writer = AlarmHistoryWriter(database, logger: Logger(level: Level.off));
      fixtureUp = true;
    });

    tearDownAll(() async {
      if (!fixtureUp) return;
      try {
        await database.close();
      } catch (_) {/* a closed connection is not a failure */}
      await stopDockerCompose();
    });

    setUp(() async {
      await appDatabase.customStatement('DELETE FROM alarm_history');
    });

    /// One activation, written by the class that writes them in production.
    ///
    /// Not a drift insert: the writer's statements go through `::timestamp`
    /// casts, so Postgres stores `2026-08-29 10:00:00` rather than ISO-8601 —
    /// and reading back what the OTHER spelling produced would make this file
    /// evidence about a fixture.
    Future<void> activation(String uid, DateTime start, DateTime? end) async {
      final id = await writer.openActivation(
        alarm: AlarmConfig(
          uid: uid,
          title: 'Motor overtemperature',
          description: 'The pre-freezer conveyor motor is over its limit',
          rules: _alarmConfig().alarms.first.rules,
        ),
        ruleIndex: 0,
        rule: _alarmConfig().alarms.first.rules.first,
        expression: '{x} > 40',
        stamp: AlarmStamp(at: start, source: AlarmTsSource.plant),
      );
      if (end != null) {
        await writer.closeActivation(
          id: id,
          stamp: AlarmStamp(at: end, source: AlarmTsSource.plant),
          reason: AlarmHistoryWriter.reasonCleared,
        );
      }
    }

    Future<List<relay.AlarmHistoryEntry>> readThrough(
      BackendRelayFixture fixture, {
      int limit = 1000,
      DateTime? from,
      DateTime? to,
    }) async {
      final answer = await fixture.client.request(
        relay.Methods.alarmHistory,
        params:
            relay.AlarmHistoryParams(limit: limit, from: from, to: to).toJson(),
        what: 'the alarm history a gateway panel asks for',
      );
      return relay.AlarmHistoryEntry.decodeList(answer);
    }

    Future<BackendRelayFixture> standUp() async {
      final fixture = backendRelayFixture(
        alarms: _alarmConfig(),
        clock: () => _at(12),
        // The real Postgres, NOT the harness's shared SQLite. The whole point
        // of this file.
        store: (database: database, preferences: preferences),
        alarmLogger: Logger(level: Level.off),
      );
      await fixture.ready;
      await fixture.client.hello();
      return fixture;
    }

    test('the window bounds by overlap, on the server that has no julianday',
        () async {
      // Each `(alarm_uid, rule_index)` may have only one OPEN row (the v7
      // partial unique index), so the standing one gets its own uid.
      await activation(_uid, _at(2), _at(4));
      await activation(_uid, _at(6), _at(9));
      await activation(_uid, _at(10), _at(11));
      await activation(_uid, _at(20), _at(22));
      await activation('$_uid.standing', _at(7), null);

      final fixture = await standUp();
      final entries = await readThrough(fixture, from: _at(8), to: _at(16));

      expect(
        [for (final e in entries) e.createdAt].toSet(),
        {_at(10), _at(7), _at(6)},
        reason: 'the alarm that went off at 06:00 and cleared at 09:00 is part '
            'of this shift\'s stop, and the one still standing since 07:00 '
            'overlaps every window it started before. Bounding by START drops '
            'both and reports the stop as shorter than it was. Before '
            '`alarmHistoryOverlaps` spelled the comparison with `::timestamp` '
            'casts this query did not merely mis-answer on this server — it '
            'threw `function julianday(text) does not exist`',
      );
      expect([for (final e in entries) e.createdAt], isNot(contains(_at(2))));
      expect([for (final e in entries) e.createdAt], isNot(contains(_at(20))));
    });

    test('a row written by the production writer round-trips whole', () async {
      await activation(_uid, _at(10), _at(11));

      final fixture = await standUp();
      final entry = (await readThrough(fixture)).single;

      expect(entry.uid, _uid);
      expect(entry.ruleIndex, 0);
      expect(entry.level, 'error');
      expect(entry.title, 'Motor overtemperature');
      expect(entry.group, ['Line 3', 'Pre-freezer'],
          reason: 'not a column — resolved server-side against the definitions '
              'the engine ran, because a gateway panel has no configuration to '
              'join against');
      expect(entry.acknowledgeRequired, isTrue);
      expect(entry.active, isFalse);
      expect(entry.createdAt, _at(10),
          reason: 'the writer stores through a `::timestamp` cast, so Postgres '
              'hands back `2026-08-29 10:00:00` with no zone at all. Reading '
              'that as local time is the bug that makes two panels disagree '
              'about when the line stopped');
      expect(entry.deactivatedAt, _at(11));
      expect(entry.tsSource, relay.AlarmActiveEntry.tsSourcePlant);
    });

    test('newest first, over rows the writer stored', () async {
      await activation('$_uid.a', _at(9), _at(10));
      await activation('$_uid.b', _at(13), _at(14));
      await activation('$_uid.c', _at(11), _at(12));

      final fixture = await standUp();

      expect([for (final e in await readThrough(fixture)) e.createdAt],
          [_at(13), _at(11), _at(9)],
          reason: 'created_at DESC, matching direct mode. Two transports that '
              'disagreed about which end of the list is newest is the '
              'divergence RelayAlarmSource exists to prevent');
    });
  });
}
