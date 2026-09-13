/// What a shared write does when it cannot reach Postgres, and what it does
/// when reaching Postgres would not be safe.
///
/// Today the same situation is a *green snackbar*: `_upsertToPostgres` returns
/// false when the database is null, every caller ignores the return value, and
/// `key_repository.dart:878-882` reports "Key mappings saved successfully!"
/// over a write that reached nothing. An operator then believes the plant's
/// wiring is saved. These tests are the proof that it now refuses instead, and
/// that the refusal says what was not saved.
///
/// The refusal is decided from the write itself — no remote, or a failure the
/// connection-error classifier recognises — and never from
/// `Database.connectionState`. With the default pool of one the health
/// monitor's `SELECT 1` borrows the same connection between drift's
/// statements, so a transaction of ours sitting aborted fails that beat and
/// flips the whole app to "database disconnected" over our own bad statement.
/// Reading that state back to decide whether we are offline would strand an
/// operator who is online.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'config_store_test.dart' show blobOf, mappingsOf;

const String kStation = 'test-station';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

late AppDatabase local;
late ConfigStore store;

/// A remote whose every transaction dies the way a severed TCP connection
/// does. Subclassing is the only way in: [AppDatabase]'s ordinary constructor
/// is private, and a real backend cannot be made to fail on demand.
class _SeveredRemote extends AppDatabase {
  _SeveredRemote() : super.forTest(DatabaseConfig(), NativeDatabase.memory());

  @override
  Future<T> transaction<T>(Future<T> Function() action,
          {bool requireNew = false}) =>
      Future.error(const SocketException('Connection reset by peer'));
}

/// A remote that fails for a reason that has nothing to do with the network.
class _BrokenRemote extends AppDatabase {
  _BrokenRemote() : super.forTest(DatabaseConfig(), NativeDatabase.memory());

  @override
  Future<T> transaction<T>(Future<T> Function() action,
          {bool requireNew = false}) =>
      Future.error(StateError('column "payload" does not exist'));
}

/// Every row in the local file — what "byte-identical after" is measured on.
Future<List<String>> localFingerprint() async {
  final items = await local.select(local.configItemTable).get();
  final changes = await local.select(local.configChangeTable).get();
  return [
    for (final r in items) '${r.kind}|${r.id}|${r.scope}|${r.rev}|${r.payload}',
    for (final c in changes) '${c.actionId}|${c.op}|${c.entityId}',
  ]..sort();
}

void main() {
  // Two AppDatabase instances is the design here, not the race drift's warning
  // is about: the local mirror and the remote are two separate files with two
  // separate executors, which is exactly the shape a station runs in.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() {
    local = AppDatabase.inMemoryForTest();
    store = ConfigStore(
      local: local,
      stationScope: kStationScope,
      station: kStation,
    );
  });

  tearDown(() async {
    await store.close();
    await local.close();
  });

  group('a shared write with no remote is refused, not lost', () {
    test('it throws before any transaction and changes nothing', () async {
      await local.into(local.configItemTable).insert(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.keyMapping.wireName,
              id: 'CN04.Belt.Speed',
              scope: ConfigScope.shared.wireName,
              payload: canonicalJson({
                'opcua_node': {'namespace': 4, 'identifier': 'a'},
              }),
              rev: const Value(2),
              updatedAt: DateTime.utc(2026, 1, 1),
              updatedBy: 'somebody',
            ),
          );
      await store.open();
      final before = await localFingerprint();

      await expectLater(
        store.writeKeyMappings(mappingsOf({'CN04.Belt.Speed': 'b'}),
            actionId: 'action-1', who: 'jon', roleName: 'engineer'),
        throwsA(isA<ConfigStoreOfflineException>()),
      );

      expect(await localFingerprint(), before,
          reason: 'a refused write touches nothing, including the mirror');
    });

    test('the message names what the operator was trying to save', () async {
      await store.open();

      try {
        await store.writeKeyMappings(
            mappingsOf({'CN04.Belt.Speed': 'a', 'CN07.Belt.Speed': 'b'}),
            actionId: 'action-2',
            who: 'jon',
            roleName: 'engineer');
        fail('a shared write with no remote must not succeed');
      } on ConfigStoreOfflineException catch (e) {
        expect(e.attempted, contains('2 keys'));
        expect(e.attempted, contains('CN04.Belt.Speed'));
        expect(e.cause, isNull,
            reason: 'nothing failed — the write was refused before it could');
        expect(e.toString(), contains('Nothing was written'));
      }
    });

    test('the mappings are still served afterwards', () async {
      await store.open();

      await expectLater(
          store.writeKeyMappings(mappingsOf({'a': 'a'}),
              actionId: 'action-3', who: 'jon', roleName: 'engineer'),
          throwsA(isA<ConfigStoreOfflineException>()));

      expect(store.keyMappings.nodes, isEmpty,
          reason: 'the snapshot is unswapped, so the store still reports what '
              'is really stored');
    });

    test('detaching a remote restores the refusal', () async {
      final remote = AppDatabase.inMemoryForTest();
      addTearDown(remote.close);
      store.attachRemoteDatabase(remote);
      await store.open();
      expect(store.hasRemote, isTrue);

      store.detachRemote();

      await expectLater(
          store.writeKeyMappings(mappingsOf({'a': 'a'}),
              actionId: 'action-4', who: 'jon', roleName: 'engineer'),
          throwsA(isA<ConfigStoreOfflineException>()));
    });
  });

  group('a pool wider than one refuses rather than corrupts', () {
    test('ConfigStoreUnsafePoolException names the variable to change',
        () async {
      final remote = AppDatabase.forTest(
          DatabaseConfig(maxPoolConnections: 4), NativeDatabase.memory());
      addTearDown(remote.close);
      store.attachRemoteDatabase(remote);
      await store.open();

      try {
        await store.writeKeyMappings(mappingsOf({'a': 'a'}),
            actionId: 'action-5', who: 'jon', roleName: 'engineer');
        fail('a non-atomic transaction must not be used to save config');
      } on ConfigStoreUnsafePoolException catch (e) {
        expect(e.poolSize, 4);
        expect(e.toString(), contains('CENTROID_DB_MAX_POOL_CONNECTIONS'));
      }

      expect(await remote.select(remote.configItemTable).get(), isEmpty);
      expect(await remote.select(remote.configChangeTable).get(), isEmpty);
    });

    test('an unconfigured pool is one and is allowed', () async {
      final remote = AppDatabase.forTest(
          DatabaseConfig(), NativeDatabase.memory());
      addTearDown(remote.close);
      store.attachRemoteDatabase(remote);
      await store.open();

      await store.writeKeyMappings(mappingsOf({'a': 'a'}),
          actionId: 'action-6', who: 'jon', roleName: 'engineer');

      expect(await remote.select(remote.configItemTable).get(), hasLength(1));
    });
  });

  group('a connection that dies mid-write reads as offline', () {
    test('the driver error is classified and wrapped, cause preserved',
        () async {
      final remote = _SeveredRemote();
      addTearDown(remote.close);
      store.attachRemoteDatabase(remote);
      await store.open();

      try {
        await store.writeKeyMappings(mappingsOf({'a': 'a'}),
            actionId: 'action-7', who: 'jon', roleName: 'engineer');
        fail('a severed connection must not read as a successful save');
      } on ConfigStoreOfflineException catch (e) {
        expect(e.cause, isA<SocketException>(),
            reason: 'the message hides the driver string from the operator; '
                'the cause keeps it for the log');
        expect(e.attempted, contains('1 key'));
      }

      expect(store.keyMappings.nodes, isEmpty);
    });

    test('a failure that is not a connection failure is not disguised as one',
        () async {
      final remote = _BrokenRemote();
      addTearDown(remote.close);
      store.attachRemoteDatabase(remote);
      await store.open();

      await expectLater(
        store.writeKeyMappings(mappingsOf({'a': 'a'}),
            actionId: 'action-8', who: 'jon', roleName: 'engineer'),
        throwsA(isA<StateError>()),
        reason: 'telling an operator to wait for the database would be a lie, '
            'and the real error is the one an engineer needs',
      );
    });

    test('the classifier this leans on is the one the write path already had',
        () {
      expect(
          Database.isConnectionError(
              const SocketException('Connection reset by peer')),
          isTrue);
      expect(
          Database.isConnectionError(
              'DriftRemoteException: SocketException: Connection refused'),
          isTrue,
          reason: 'through the DriftIsolate every error arrives stringified, '
              'so a type check never fires on a station');
      expect(Database.isConnectionError(StateError('42703')), isFalse);
    });

    test('a socket that died between statements is an outage too', () {
      // Regression, and the integration lane is what found it: killing the
      // connection mid-suite and saving again produced "Bad state: StreamSink
      // is closed" — `dart:io`'s IOSink refusing a write to a socket whose
      // peer has gone, with nothing in the message to say it was ever a
      // socket. The operator was shown that sentence. Both arms below are the
      // shapes a station really meets; neither existed in the classifier.
      expect(
          Database.isConnectionError(
              'DriftRemoteException: Bad state: StreamSink is closed'),
          isTrue);
      expect(
          Database.isConnectionError(StateError('StreamSink is closed')),
          isTrue);
      expect(
          Database.isConnectionError('PgException: Attempting to execute '
              'query, but connection is not open.'),
          isTrue);
      // The message a statement already on the wire gets when the socket
      // dies under it — the *during* case, where the two above are the
      // *between* cases.
      expect(
          Database.isConnectionError('PgException: The underlying socket to '
              'Postgres has been closed unexpectedly.'),
          isTrue);
      expect(
          Database.isConnectionError(
              TimeoutException('statement', const Duration(seconds: 30))),
          isTrue,
          reason: 'a peer that hangs is not a different outage to the '
              'operator than one that resets');
      // Still not everything with a stack trace in it: a broken statement is
      // an engineer's problem and telling an operator to wait for the database
      // would be a lie.
      expect(
          Database.isConnectionError(
              StateError('column "payload" does not exist')),
          isFalse);
    });
  });

  group('the blob helper is shared with the boot suite', () {
    test('mappingsOf and blobOf agree', () {
      expect(blobOf({'a': 'x'}), contains('"identifier":"x"'));
      expect(mappingsOf({'a': 'x'}), isA<KeyMappings>());
    });
  });
}
