/// The sync engine's cheap lane: attach, reconcile, the watermark pull, the
/// rev sweep and detach — everything about the Postgres half that does not
/// need Postgres.
///
/// The one thing that cannot be here is LISTEN/NOTIFY itself, which needs a
/// real server; `test/integration/config_store_integration_test.dart` is where
/// the transport is proven. What is provable here is everything the
/// notification is only a *trigger* for: which rows get re-read, what the
/// snapshot becomes, what the mirror ends up holding, and what the store
/// emits. That split is deliberate — the pull is idempotent and does not care
/// how it was woken, so waking it by hand is a faithful test of it.
///
/// Every payload below is built through the codec. `KeyMappingEntry.toJson()`
/// emits all eight of its fields including the seven nulls, so a hand-written
/// `{"opcua_node": …}` is structurally a *different* payload and
/// `diffConfigItems` is right to call it a change. A fixture that hand-writes
/// one makes a reconcile test pass while every real reconcile reports the
/// whole plant rewired.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart'
    show kKeyMappingsMigratedMarkerId;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

const String kStation = 'test-station';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

late AppDatabase local;
late AppDatabase remote;
late ConfigStore store;
late List<ConfigDiff> emitted;

/// A store whose sweep never fires on its own unless a test asks for a short
/// interval. Five minutes is the production value and no unit test waits it
/// out; the tests that are about the timer set their own.
ConfigStore newStore({Duration? sweepInterval}) => ConfigStore(
      local: local,
      stationScope: kStationScope,
      station: kStation,
      sweepInterval: sweepInterval ?? const Duration(minutes: 5),
    );

/// The mappings a save hands over.
KeyMappings mappingsOf(Map<String, String> keysToIdentifiers) =>
    KeyMappings.fromJson(
        jsonDecode(blobOf(keysToIdentifiers)) as Map<String, dynamic>);

String blobOf(Map<String, String> keysToIdentifiers) => jsonEncode({
      'nodes': {
        for (final entry in keysToIdentifiers.entries)
          entry.key: {
            'opcua_node': {
              'namespace': 4,
              'identifier': entry.value,
            },
          },
      },
    });

/// The payload a station would store for one key — through the codec, never
/// by hand. See the library doc.
String payloadOf(String key, String identifier) =>
    keyMappingItems(mappingsOf({key: identifier})).single.payload;

/// Writes a shared `key_mapping` row directly, as the sync engine or the
/// migration leaves one. Into [local] unless [db] says otherwise.
Future<void> seedRow(String key, String identifier,
        {int rev = 1, AppDatabase? db}) =>
    (db ?? local).into((db ?? local).configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: ConfigKind.keyMapping.wireName,
            id: key,
            scope: ConfigScope.shared.wireName,
            payload: payloadOf(key, identifier),
            rev: Value(rev),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'somebody',
          ),
        );

/// The same row on both sides — the ordinary state after a boot that reached
/// Postgres and reconciled.
Future<void> seedBothSides(String key, String identifier, {int rev = 1}) async {
  await seedRow(key, identifier, rev: rev);
  await seedRow(key, identifier, rev: rev, db: remote);
}

/// Moves a row on the remote behind the store's back — another station's save,
/// or a `psql` session. [withChangeRow] false is the SERIAL gap's unit-level
/// stand-in: the row moved and the change log does not say so.
Future<void> remoteEdit(String key, String identifier,
    {required int rev, bool withChangeRow = true}) async {
  await (remote.update(remote.configItemTable)
        ..where((t) =>
            t.kind.equals(ConfigKind.keyMapping.wireName) &
            t.id.equals(key) &
            t.scope.equals(ConfigScope.shared.wireName)))
      .write(ConfigItemTableCompanion(
    payload: Value(payloadOf(key, identifier)),
    rev: Value(rev),
    updatedAt: Value(DateTime.utc(2026, 2, 2)),
    updatedBy: const Value('the-other-station'),
  ));
  if (withChangeRow) await seedChangeRow(key);
}

Future<void> remoteDelete(String key, {bool withChangeRow = true}) async {
  await (remote.delete(remote.configItemTable)
        ..where((t) =>
            t.kind.equals(ConfigKind.keyMapping.wireName) &
            t.id.equals(key) &
            t.scope.equals(ConfigScope.shared.wireName)))
      .go();
  if (withChangeRow) await seedChangeRow(key, op: 'delete');
}

/// One row of the shared change log. Its `id` is what the watermark counts.
Future<void> seedChangeRow(String entityId,
        {String op = 'update',
        String kind = 'key_mapping',
        AppDatabase? db}) =>
    (db ?? remote).into((db ?? remote).configChangeTable).insert(
          ConfigChangeTableCompanion.insert(
            at: DateTime.utc(2026, 2, 2),
            actionId: 'action-$entityId-$op',
            who: 'somebody',
            station: 'other-station',
            roleName: 'Engineering',
            kind: kind,
            entityId: entityId,
            scope: ConfigScope.shared.wireName,
            op: op,
          ),
        );

/// The marker 02-03's migration writes last. Its presence is what makes "no
/// shared key_mapping rows" mean "no mappings" rather than "not migrated yet".
Future<void> seedMigrationMarker({AppDatabase? db}) =>
    (db ?? remote).into((db ?? remote).configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: kKeyMappingsMigratedMarkerId,
            scope: ConfigScope.shared.wireName,
            payload: jsonEncode({'type': 'String', 'value': '2026-09-07'}),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'migration',
          ),
        );

/// Any row at all, of any kind and any scope — the neighbours a sweep of the
/// shared key mappings must leave alone.
Future<void> seedItemRow({
  required ConfigKind kind,
  required String id,
  required ConfigScope scope,
  String? payload,
  AppDatabase? db,
}) =>
    (db ?? local).into((db ?? local).configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: kind.wireName,
            id: id,
            scope: scope.wireName,
            payload: payload ?? jsonEncode({'anything': id}),
            rev: const Value(1),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'somebody',
          ),
        );

/// Every row in the local file, as `kind|scope|id`.
Future<List<String>> localRowKeys() async {
  final rows = await local.select(local.configItemTable).get();
  return [for (final r in rows) '${r.kind}|${r.scope}|${r.id}']..sort();
}

Future<List<ConfigItemRow>> mirrorRows({AppDatabase? db}) =>
    ((db ?? local).select((db ?? local).configItemTable)
          ..where((t) =>
              t.kind.equals(ConfigKind.keyMapping.wireName) &
              t.scope.equals(ConfigScope.shared.wireName))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

/// The identifier a snapshot entry points at — the one field these fixtures
/// vary, so an assertion on it is an assertion on which payload arrived.
String? identifierOf(String key) =>
    store.keyMappings.nodes[key]?.opcuaNode?.identifier;

/// Lets the broadcast stream deliver. The applies themselves are awaited
/// through [ConfigStore.syncSettled]; this is only about the listener.
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> settled() async {
  await store.syncSettled;
  await pump();
}

void main() {
  // Two AppDatabase instances is the design here, not the race drift's warning
  // is about: the local mirror and the remote are two separate executors,
  // which is the shape a station runs in.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    local = AppDatabase.inMemoryForTest();
    remote = AppDatabase.inMemoryForTest();
    store = newStore();
    emitted = [];
  });

  tearDown(() async {
    // Settle before closing: a reconcile still reading when the database under
    // it disappears logs a failure that is the teardown's fault and nothing
    // else's, and reading it in a failure report costs somebody an hour.
    await store.syncSettled;
    await store.close();
    await local.close();
    await remote.close();
  });

  void watch() => store.keyMappingChanges.listen(emitted.add);

  group('attaching reconciles what this station missed', () {
    test('the remote\'s rows win, the mirror follows, and one diff is emitted',
        () async {
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed', rev: 1);
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 7, db: remote);
      await seedRow('CN07.Belt.Speed', 'GVL.Conveyors[7].Speed',
          rev: 2, db: remote);
      await store.open();
      watch();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].SpeedActual');
      expect(identifierOf('CN07.Belt.Speed'), 'GVL.Conveyors[7].Speed');

      // The revision travels with it. Without that the next save's
      // compare-and-swap guards on a revision the server left behind long ago
      // and loses to a conflict nobody caused.
      final items = {for (final i in store.keyMappingItems) i.id: i};
      expect(items['CN04.Belt.Speed']!.rev, 7);
      expect(items['CN07.Belt.Speed']!.rev, 2);

      final mirror = await mirrorRows();
      expect(mirror.map((r) => r.id), ['CN04.Belt.Speed', 'CN07.Belt.Speed']);
      expect(mirror.first.rev, 7);
      expect(mirror.first.payload,
          payloadOf('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual'));

      expect(emitted, hasLength(1));
      expect(emitted.single.changed.map((i) => i.id), ['CN04.Belt.Speed']);
      expect(emitted.single.added.map((i) => i.id), ['CN07.Belt.Speed']);
      expect(emitted.single.removed, isEmpty);
    });

    test('a key deleted on the remote is removed here, and the diff says so',
        () async {
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedBothSides('CN07.Belt.Speed', 'GVL.Conveyors[7].Speed');
      await store.open();
      watch();
      await remoteDelete('CN07.Belt.Speed', withChangeRow: false);

      store.attachRemoteDatabase(remote);
      await settled();

      expect(store.keyMappings.nodes.keys, ['CN04.Belt.Speed']);
      expect((await mirrorRows()).map((r) => r.id), ['CN04.Belt.Speed']);
      expect(emitted.single.removed.map((i) => i.id), ['CN07.Belt.Speed']);
    });

    test('a reconcile that finds nothing new emits nothing at all', () async {
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await store.open();
      watch();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(emitted, isEmpty,
          reason: 'every listener re-points subscriptions on an event; a boot '
              'that changed nothing must not make the plant do that');
    });

    test('the watermark is persisted, so the next boot resumes from it',
        () async {
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedChangeRow('CN04.Belt.Speed');
      await seedChangeRow('CN04.Belt.Speed');
      await seedChangeRow('CN99.Other.Kind', kind: 'page');
      await store.open();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(store.watermark, 3,
          reason: 'the sweep has just read the whole state, so every change '
              'row that existed when it started is consumed — including the '
              'ones that were not key mappings');

      final next = newStore();
      addTearDown(next.close);
      await next.open();
      expect(next.watermark, 3);
    });

    test('an empty remote is an un-migrated plant, not a plant with no keys',
        () async {
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedRow('CN07.Belt.Speed', 'GVL.Conveyors[7].Speed');
      await store.open();
      watch();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(store.keyMappings.nodes, hasLength(2),
          reason: 'the cutover boot reaches Postgres before any station has '
              'run the migration; reading that as "every key was deleted" '
              'blanks every mimic on the floor');
      expect(await mirrorRows(), hasLength(2));
      expect(emitted, isEmpty);
    });

    test('with the migration marker, an empty remote really is empty',
        () async {
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedMigrationMarker();
      await store.open();
      watch();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(store.keyMappings.nodes, isEmpty);
      expect(await mirrorRows(), isEmpty);
      expect(emitted.single.removed.map((i) => i.id), ['CN04.Belt.Speed']);
    });

    test('the remote wins outright, and only over shared key mappings',
        () async {
      // THE PROPERTY, stated as a test because Phase 3 builds on it: for the
      // kinds under sync the remote's row set **replaces** this station's, so
      // a row the remote has never heard of is deleted rather than left
      // alone. A sweep that merged instead would leave that row surviving
      // every future sweep — a legitimate-looking id nobody ever wrote, which
      // nothing downstream can tell from real configuration.
      //
      // And the other half of it: "absent from a shared remote" says nothing
      // whatever about a `station:` row or about another kind. Those are
      // different row sets, and deleting them here would wipe per-station
      // settings and, from Phase 3, pages.
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedItemRow(
          kind: ConfigKind.keyMapping,
          id: 'CN04.Belt.Speed',
          scope: kStationScope);
      await seedItemRow(
          kind: ConfigKind.page, id: '/roe', scope: ConfigScope.shared);
      await seedItemRow(
          kind: ConfigKind.preference,
          id: kKeyMappingsWatermarkId,
          scope: kStationScope,
          payload: jsonEncode({'type': 'int', 'value': 12}));
      // The marker, so the empty remote is believed rather than read as an
      // un-migrated plant.
      await seedMigrationMarker();
      await store.open();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(await localRowKeys(), [
        'key_mapping|${kStationScope.wireName}|CN04.Belt.Speed',
        'page|shared|/roe',
        // The remote's migration marker, mirrored down: `preference` came
        // under sync in 04-05, so a SHARED preference row now replicates like
        // any other. The station-scoped watermark below is the same kind and
        // does not, which is the scope filter doing the work the kind set was
        // once wrongly credited with.
        'preference|shared|$kKeyMappingsMigratedMarkerId',
        'preference|${kStationScope.wireName}|$kKeyMappingsWatermarkId',
      ]);
    });
  });

  group('the watermark pull', () {
    setUp(() async {
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedBothSides('CN07.Belt.Speed', 'GVL.Conveyors[7].Speed');
      await store.open();
    });

    test('only the entities the change log names are re-read', () async {
      // Both rows moved on the remote; only one of them is in the log. A pull
      // that re-read everything would pick up both and this would pass by
      // accident, so the assertion is on the row the log does *not* name.
      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2);
      await remoteEdit('CN07.Belt.Speed', 'GVL.Conveyors[7].SpeedActual',
          rev: 2, withChangeRow: false);
      store.attachRemoteDatabase(remote, startSync: false);
      watch();

      await store.pullChanges();
      await pump();

      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].SpeedActual');
      expect(identifierOf('CN07.Belt.Speed'), 'GVL.Conveyors[7].Speed');
      expect(emitted.single.changed.map((i) => i.id), ['CN04.Belt.Speed']);
      expect(store.watermark, 1);
    });

    test('a second pull over the same log applies nothing and emits nothing',
        () async {
      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2);
      store.attachRemoteDatabase(remote, startSync: false);
      watch();

      await store.pullChanges();
      await store.pullChanges();
      await pump();

      expect(emitted, hasLength(1));
    });

    test('a delete recorded in the log removes the row here', () async {
      await remoteDelete('CN07.Belt.Speed');
      store.attachRemoteDatabase(remote, startSync: false);
      watch();

      await store.pullChanges();
      await pump();

      expect(store.keyMappings.nodes.keys, ['CN04.Belt.Speed']);
      expect((await mirrorRows()).map((r) => r.id), ['CN04.Belt.Speed']);
      expect(emitted.single.removed.map((i) => i.id), ['CN07.Belt.Speed']);
    });

    test('the sweep catches a row the change log never mentioned', () async {
      // The unit-level stand-in for the SERIAL gap: a row that moved with no
      // consumable log entry behind it. The integration suite proves the gap
      // is real with two out-of-order transactions; this proves the net that
      // closes it is wired to the same apply path.
      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2, withChangeRow: false);
      store.attachRemoteDatabase(remote, startSync: false);
      watch();

      await store.pullChanges();
      await pump();
      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].Speed',
          reason: 'nothing in the change log names it, so the fast path is '
              'blind to it — which is exactly C-6');
      expect(emitted, isEmpty);

      await store.reconcile();
      await pump();

      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].SpeedActual');
      expect(emitted.single.changed.map((i) => i.id), ['CN04.Belt.Speed']);
    });

    test('two pulls in flight serialise: the second sees the first\'s work',
        () async {
      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2);
      store.attachRemoteDatabase(remote, startSync: false);
      watch();

      final first = store.pullChanges();
      final second = store.pullChanges();
      await Future.wait([first, second]);
      await pump();

      expect(emitted, hasLength(1),
          reason: 'interleaved swaps would both diff against the pre-pull '
              'snapshot and both report the same edit');
      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].SpeedActual');
    });
  });

  group('detach stops everything attach started', () {
    test('the sweep timer runs only while a remote is attached', () async {
      store = newStore(sweepInterval: const Duration(milliseconds: 30));
      await store.open();
      expect(store.sweepTimerActive, isFalse,
          reason: 'a store with no remote must leak no timer into a widget '
              'test that never asked for one');

      store.attachRemoteDatabase(remote);
      expect(store.sweepTimerActive, isTrue);

      store.detachRemote();
      expect(store.sweepTimerActive, isFalse);
    });

    test('the periodic sweep picks up an edit nothing else would', () async {
      store = newStore(sweepInterval: const Duration(milliseconds: 30));
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await store.open();
      store.attachRemoteDatabase(remote);
      await settled();

      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2, withChangeRow: false);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (identifierOf('CN04.Belt.Speed') != 'GVL.Conveyors[4].SpeedActual') {
        if (DateTime.now().isAfter(deadline)) {
          fail('the periodic sweep never ran');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    test('nothing is applied after a detach', () async {
      store = newStore(sweepInterval: const Duration(milliseconds: 30));
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await store.open();
      store.attachRemoteDatabase(remote);
      await settled();
      watch();

      store.detachRemote();
      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].Speed');
      expect(emitted, isEmpty);
    });

    test('attaching again reconciles from scratch', () async {
      await seedBothSides('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await store.open();
      store.attachRemoteDatabase(remote);
      await settled();

      store.detachRemote();
      // The gap. Notifications sent now are gone forever, which is why the
      // re-attach cannot be a pull.
      await remoteEdit('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 2, withChangeRow: false);
      watch();

      store.attachRemoteDatabase(remote);
      await settled();

      expect(identifierOf('CN04.Belt.Speed'), 'GVL.Conveyors[4].SpeedActual');
      expect(emitted.single.changed.map((i) => i.id), ['CN04.Belt.Speed']);
    });

    test('attaching the same handle twice reconciles once', () async {
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 4, db: remote);
      await store.open();
      watch();

      store.attachRemoteDatabase(remote);
      store.attachRemoteDatabase(remote);
      await settled();

      expect(emitted, hasLength(1));
    });

    test('a SQLite remote never opens a notification channel', () async {
      await store.open();

      store.attachRemoteDatabase(remote);

      expect(store.notificationsActive, isFalse,
          reason: 'listenToChannel on a non-Postgres executor logs and closes '
              'the stream, which the re-listen would answer with a timer '
              'every five seconds for the life of the process');
    });
  });
}
