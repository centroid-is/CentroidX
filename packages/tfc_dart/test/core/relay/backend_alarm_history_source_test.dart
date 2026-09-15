/// The alarm-history read, from the rig symptom back to the query.
///
/// ## The symptom this file starts from
///
/// A gateway panel on the SVN rig asked the backend for alarm history and got
///
/// ```text
/// JSON-RPC error -32011: this gateway serves no alarm history, so there is
/// nothing to read. alarmHistory is registered on every session...
/// ```
///
/// which is `AlarmHandlers.recent`'s **correct** refusal for a gateway that was
/// composed without a reader — and the wrong answer for this one, which has an
/// alarm engine, a `Database` and an `alarm_history` table full of rows. The
/// protocol, the server handler, the relay client and the app side all shipped;
/// `composeBackendRelay` never passed `alarmHistory:`, so the null branch was
/// the only branch a plant ever reached.
///
/// Arm 1 is that symptom, driven over a real socket through the graph
/// `bin/main.dart` builds. It is first because it is the only arm that fails
/// for the reason the plant failed: every other arm here would pass against a
/// perfectly good source that nothing had wired up.
///
/// ## Why the overlap arm is called out separately
///
/// `AlarmHistorySource`'s contract bounds the window by **overlap**, not by
/// start: an alarm that went off before `from` and only cleared inside the
/// window is part of that window's stop. A query that dropped it reports the
/// stop as shorter than it was, in the direction nobody audits — the number
/// `alarmHistoryOverlaps` (`alarm.dart:301`) exists to get right. It is the
/// property most likely to be got wrong by writing the obvious
/// `created_at BETWEEN from AND to`, and the least likely to be noticed
/// afterwards, so it has its own arm at both levels: through the socket, and
/// against the source directly.
///
/// ## Why rows whose uid is not configured are still returned
///
/// `AlarmMan.getRecentAlarms` resolves each row against the local configuration
/// and drops — via `whereType`, silently — every row it cannot find. In direct
/// mode the configuration and the rows are one file on one machine. Across this
/// wire they are a backend that evaluated the rules and a panel holding a
/// device-local mirror of a preference, so that join is exactly what
/// `alarm_history.dart` says must not happen. The row carries its own title,
/// description and level, so an alarm deleted last week still draws its own
/// history.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history_source.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart' show AlarmDefinitions;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../../support/backend_ws_harness.dart';

// ---------------------------------------------------------------- the fixture

/// The shift every window arm is judged against: 08:00–16:00 on one day.
final _day = DateTime.utc(2026, 8, 29);

DateTime _at(int hour, [int minute = 0]) =>
    _day.add(Duration(hours: hour, minutes: minute));

/// An alarm the backend's configuration knows about.
const _configuredUid = 'ST101.CN01.MOT01.overtemp';

/// One the configuration does not — a definition deleted after its rows were
/// written. Direct mode drops it; this wire must not.
const _forgottenUid = 'ST301.CN21.MOT04.retired';

/// The alarm definitions the engine runs, so `group` and `acknowledgeRequired`
/// have somewhere to be resolved from.
AlarmManConfig _alarmConfig() => AlarmManConfig(alarms: [
      AlarmConfig(
        uid: _configuredUid,
        title: 'Motor overtemperature',
        description: 'The pre-freezer conveyor motor is over its limit',
        group: const ['Line 3', 'Pre-freezer'],
        rules: [
          AlarmRule(
            level: AlarmLevel.error,
            expression: ExpressionConfig(
              value: Expression(formula: '{x} > 40'),
            ),
            acknowledgeRequired: true,
          ),
        ],
      ),
    ]);

void main() {
  installBackendWsStore();

  group('the composed gateway answers alarmHistory', () {
    late BackendRelayFixture fixture;
    late AppDatabase db;

    setUp(() async {
      fixture = backendRelayFixture(
        alarms: _alarmConfig(),
        clock: () => _at(12),
        alarmLogger: Logger(level: Level.off),
      );
      await fixture.ready;
      await fixture.client.hello();
      db = fixture.backend.store.database.db;
      // The store is shared across the file (`installBackendWsStore`), so each
      // case starts from a table it wrote itself. A leftover row from the
      // previous case is a window arm that passes for somebody else's reason.
      await db.delete(db.alarmHistory).go();
    });

    Future<void> row(
      String uid,
      DateTime start,
      DateTime? end, {
      int? ruleIndex = 0,
      String level = 'error',
      String? tsSource = 'plant',
      bool active = false,
      bool pendingAck = false,
    }) =>
        db.into(db.alarmHistory).insert(AlarmHistoryCompanion.insert(
              alarmUid: uid,
              alarmTitle: 'stored title of $uid',
              alarmDescription: 'stored description of $uid',
              alarmLevel: level,
              expression: const Value('{x} > 40'),
              active: active,
              pendingAck: pendingAck,
              createdAt: start,
              deactivatedAt: Value(end),
              ruleIndex: Value(ruleIndex),
              tsSource: Value(tsSource),
            ));

    Future<List<relay.AlarmHistoryEntry>> read({
      int limit = 1000,
      DateTime? from,
      DateTime? to,
    }) async {
      final answer = await fixture.client.request(
        relay.Methods.alarmHistory,
        params: relay.AlarmHistoryParams(limit: limit, from: from, to: to)
            .toJson(),
        what: 'the alarm history a gateway panel asks for',
      );
      return relay.AlarmHistoryEntry.decodeList(answer);
    }

    test('arm 1: the rig symptom — a gateway with an engine serves history',
        () async {
      await row(_configuredUid, _at(10), _at(11));

      // Before the wiring existed this threw
      // `-32011 this gateway serves no alarm history`, on a backend holding
      // the row it was being asked for.
      final entries = await read();

      expect(entries, hasLength(1),
          reason: 'the gateway holds this row and an alarm engine; refusing '
              'by name here is the composition defect the rig met, and '
              'answering `{entries: []}` would be worse still — a factory that '
              'has never had an alarm');
      expect(entries.single.uid, _configuredUid);
    });

    test('arm 2: an alarm that opened before the window and cleared inside it '
        'is part of that window', () async {
      await row('$_configuredUid.before', _at(2), _at(4));
      await row('$_configuredUid.straddles-start', _at(6), _at(9));
      await row('$_configuredUid.inside', _at(10), _at(11));
      await row('$_configuredUid.after', _at(20), _at(22));
      await row('$_configuredUid.standing', _at(7), null);

      final uids = [
        for (final e in await read(from: _at(8), to: _at(16))) e.uid
      ]..sort();

      expect(
          uids,
          [
            '$_configuredUid.inside',
            '$_configuredUid.standing',
            '$_configuredUid.straddles-start',
          ],
          reason: 'the window bounds by OVERLAP, not by start. An alarm that '
              'went off at 06:00 and cleared at 09:00 is three of this '
              'shift\'s minutes of downtime; dropping it reports the stop as '
              'shorter than it was, which is the one number a stop analysis '
              'exists to get right. A row that never cleared overlaps every '
              'window it started before');
    });

    test('arm 3: rows come back created_at descending, as direct mode orders '
        'them', () async {
      await row('$_configuredUid.oldest', _at(9), _at(10));
      await row('$_configuredUid.newest', _at(14), _at(15));
      await row('$_configuredUid.middle', _at(11), _at(12));

      expect(
          [for (final e in await read()) e.uid],
          [
            '$_configuredUid.newest',
            '$_configuredUid.middle',
            '$_configuredUid.oldest',
          ],
          reason: 'AlarmMan.getRecentAlarms orders created_at DESC. Two '
              'transports that disagreed about which end of the list is newest '
              'is the divergence RelayAlarmSource exists to prevent');
    });

    test('arm 4: the row is self-sufficient — no join against the panel',
        () async {
      await row(_configuredUid, _at(10), _at(11));

      final entry = (await read()).single;

      expect(entry.title, 'stored title of $_configuredUid',
          reason: 'title, description and level are what the alarm WAS when it '
              'fired, and the row records all three');
      expect(entry.description, 'stored description of $_configuredUid');
      expect(entry.level, 'error');
      expect(entry.group, ['Line 3', 'Pre-freezer'],
          reason: 'group is not a column, so it is resolved server-side '
              'against the configuration the engine actually ran — a gateway '
              'panel has no configuration to join against');
      expect(entry.acknowledgeRequired, isTrue,
          reason: 'nor is acknowledgeRequired. Direct mode reads it off the '
              'rule the row names; so does this');
      expect(entry.ruleIndex, 0);
      expect(entry.tsSource, relay.AlarmActiveEntry.tsSourcePlant,
          reason: 'the stored provenance, never re-derived: relabelling a '
              'backend guess as the plant\'s word is the one field a stop '
              'analysis is audited on');
      expect(entry.createdAt, _at(10));
      expect(entry.deactivatedAt, _at(11));
    });

    test('arm 5: a row whose alarm is no longer configured is still returned',
        () async {
      await row(_configuredUid, _at(10), _at(11));
      await row(_forgottenUid, _at(12), _at(13), ruleIndex: null,
          tsSource: null);

      final entries = await read();

      expect([for (final e in entries) e.uid],
          [_forgottenUid, _configuredUid],
          reason: 'AlarmMan.getRecentAlarms drops a row whose uid is not in '
              'the current configuration, silently, via whereType. Across this '
              'wire that join makes an alarm renamed last week erase its own '
              'history with no error anywhere');
      final forgotten = entries.first;
      expect(forgotten.title, 'stored title of $_forgottenUid');
      expect(forgotten.group, isEmpty,
          reason: 'nothing configured says where it lives, and inventing a '
              'group would be a guess dressed as a fact');
      expect(forgotten.acknowledgeRequired, isFalse,
          reason: 'a row that names no rule cannot be matched to one, and '
              'direct mode keeps the same false rather than guessing rule 0');
      expect(forgotten.ruleIndex, isNull);
      expect(forgotten.tsSource, isNull,
          reason: 'a pre-v7 row recorded no provenance, which is a different '
              'fact from a row that positively says the backend guessed');
    });

    test('arm 6: limit is a ceiling on rows, newest kept', () async {
      await row('$_configuredUid.a', _at(9), _at(10));
      await row('$_configuredUid.b', _at(11), _at(12));
      await row('$_configuredUid.c', _at(13), _at(14));

      expect([for (final e in await read(limit: 2)) e.uid],
          ['$_configuredUid.c', '$_configuredUid.b'],
          reason: 'the ceiling applies after the DESC ordering, so a panel '
              'asking for the last two gets the last two');
    });

    test('arm 7: an empty answer means the window is empty, and says so',
        () async {
      await row(_configuredUid, _at(2), _at(4));

      expect(await read(from: _at(8), to: _at(16)), isEmpty,
          reason: 'completing with [] means, and may only mean, this window '
              'genuinely contains no rows');
    });

    test('arm 9: the reader is over THIS graph\'s database and THIS engine',
        () async {
      final source = fixture.backend.composition.server.alarmHistory;

      expect(source, isA<BackendAlarmHistorySource>(),
          reason: 'the seam is optional and defaults to null, so a '
              'composition that forgets it produces a gateway that refuses '
              'every history read by name — which is what shipped, and what '
              'no test noticed');
      final reader = source! as BackendAlarmHistorySource;
      expect(identical(reader.database, db), isTrue,
          reason: 'a second connection would be a pool nobody counted, and a '
              'reader over a different database would answer about rows the '
              'engine never wrote');
      expect(identical(reader.definitions, fixture.backend.engine), isTrue,
          reason: 'and the definitions must be THIS engine\'s: a row resolved '
              'against a second configuration is a group and an ack button '
              'that no alarm was ever evaluated under');
    });
  });

  group('the reader on its own', () {
    test('arm 10: a failed read throws — it is never an empty history',
        () async {
      final dir = Directory.systemTemp.createTempSync('alarm-history-source');
      addTearDown(() => dir.deleteSync(recursive: true));
      final database = await AppDatabase.create(
        DatabaseConfig(applicationName: 'alarm-history-source'),
        sqliteFolder: dir,
      );
      final source = BackendAlarmHistorySource(
        database: database,
        definitions: _NoDefinitions(),
      );
      await database.close();

      await expectLater(
        source.recentAlarms(limit: 10),
        throwsA(anything),
        reason: 'the gateway turns this into handlerFailed and the panel shows '
            'it. Answering {entries: []} because the database was unreachable '
            'would report a fact about the gateway as a fact about the '
            'factory, and nothing on the operator\'s screen would tell the two '
            'apart — the exact silence this seam exists to remove');
    });
  });

  group('a gateway with no alarm engine', () {
    test('arm 8: still refuses by name rather than answering an empty history',
        () async {
      final fixture = backendRelayFixture();
      await fixture.ready;

      expect(fixture.backend.composition.server.alarmHistory, isNull,
          reason: 'a gateway composed with no engine has no history to serve, '
              'and `AlarmHandlers.recent` must keep telling a panel that by '
              'name — "serves no alarm history" is a composition problem a '
              'reader can act on, where `{entries: []}` is a plant that has '
              'never had an alarm');

      await expectLater(
        fixture.client
            .hello()
            .then((_) => fixture.client.request(
                  relay.Methods.alarmHistory,
                  params: relay.AlarmHistoryParams(limit: 10).toJson(),
                )),
        throwsA(isA<Object>()),
      );
    });
  });
}

/// An engine that is running no configuration — a refused `alarm_man_config`,
/// or a fake that has none.
final class _NoDefinitions implements AlarmDefinitions {
  @override
  AlarmManConfig? get config => null;
}
