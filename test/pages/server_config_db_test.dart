import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:drift/drift.dart' show Value;
import 'package:postgres/postgres.dart' as pg;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/config/shared_row_preferences.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/core/server_config_db.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';

import '../helpers/test_helpers.dart';

/// Wraps [ImportExportCard] alone — the store/load-database flows never touch
/// the server sections, and the full [ServerConfigBody] just slows the test.
/// [prefs] is shared with the test body so it can assert what got persisted.
Widget _buildCard({
  Database? database,
  Preferences? prefs,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider
          .overrideWith((ref) async => prefs ?? await createTestPreferences()),
      databaseProvider.overrideWith((ref) async => database),
      stateManProvider
          .overrideWith((ref) => throw StateError('No StateMan in tests')),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ImportExportCard())),
    ),
  );
}

Future<StoredServerConfig?> _storedRow(AppDatabase db) =>
    ServerConfigDb.fetch(db);

/// The shared configuration store the page gets from `preferencesProvider`,
/// wired so its rows land in [db].
///
/// `publish` takes a [PreferencesApi], and since 04-05 that store writes
/// `kind='preference'` rows rather than `flutter_preferences` rows. A test
/// that wants the row to be there for `fetch` to find has to hand it a store
/// wired to the very database `fetch` selects out of — which is what
/// `remoteDatabase` is for.
Future<Preferences> _rowPrefs(
  AppDatabase db, {
  AccessSession? session,
  AccessSession Function()? sessionOf,
  AuditSink? audit,
  StateManConfig? stateManConfig,
}) async {
  // Both caches are process-wide, so a stale entry from an earlier test would
  // shadow this one's fresh storage. Same reasoning as `createTestPreferences`.
  Preferences.clearSecretCache();
  DatabaseConfig.clearPrefsCache();
  final secureStorage = FakeSecureStorage();
  final guarded = await createTestConfigStore(
    remoteDatabase: db,
    session: session ?? _administer(),
    sessionOf: sessionOf,
    audit: audit,
  );
  final prefs =
      SharedRowPreferences(store: guarded, secureStorage: secureStorage);
  addTearDown(prefs.close);
  if (stateManConfig != null) {
    // `StateManConfig.fromPrefs` reads with `secret: true`, so this goes to
    // the keychain stand-in and never to a row.
    await secureStorage.write(
      key: StateManConfig.configKey,
      value: jsonEncode(stateManConfig.toJson()),
    );
  }
  return prefs;
}

/// The envelope row as another station left it — straight into [db], with no
/// store of ours involved. This is what [ServerConfigDb.fetch] has to find.
Future<void> _seedRow(AppDatabase db, StoredServerConfig config) =>
    db.into(db.configItemTable).insertOnConflictUpdate(
          ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: ServerConfigDb.prefsKey,
            scope: ConfigScope.shared.wireName,
            payload: ConfigItem.of(
              kind: ConfigKind.preference,
              id: ServerConfigDb.prefsKey,
              value: preferencePayload(
                  kPrefStringType, jsonEncode(config.toJson())),
            ).payload,
            rev: const Value(1),
            updatedAt: DateTime.now(),
            updatedBy: 'other-station',
          ),
        );

/// The same, for a [Database] wrapper.
Future<void> _seed(Database db, StoredServerConfig config) =>
    _seedRow(db.db, config);

/// The `config_change` rows on [db], serialised. The envelope is
/// history-exempt, so this list must not grow across a publish — and an
/// absence is only provable by comparing the whole table.
Future<List<String>> _changeLog(AppDatabase db) async => [
      for (final row in await db.select(db.configChangeTable).get())
        row.toString(),
    ];

/// Anonymous is the Operator role by construction. Handing it an empty group
/// set would make the denials below pass for the wrong reason.
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

AccessSession _administer() => const AccessSession(
      user: AuthenticatedUser(username: 'jon', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.configure,
        AccessGroup.administer,
      },
    );

class _RecordingAuditSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    // The config cache is process-wide; a stale entry from a previous test
    // would leak through the fresh FakeSecureStorage.
    DatabaseConfig.clearPrefsCache();
    // Production-strength PBKDF2 takes tens of seconds per derivation in the
    // debug-mode test VM; the round-trip logic under test is unchanged.
    SecureEnvelope.kdfIterationsForTest = 10;
  });

  group('StoredServerConfig', () {
    test('serializes and parses metadata and envelope', () {
      final saved = StoredServerConfig(
        savedAt: DateTime(2026, 8, 18, 12, 30),
        savedBy: 'station-1',
        envelope: {'version': 1, 'ciphertext_b64': 'abc'},
      );
      final parsed = StoredServerConfig.fromJson(
          jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>);
      expect(parsed.savedAt, DateTime(2026, 8, 18, 12, 30));
      expect(parsed.savedBy, 'station-1');
      expect(parsed.envelope['ciphertext_b64'], 'abc');
    });

    test('tolerates missing metadata', () {
      final parsed = StoredServerConfig.fromJson({
        'envelope': {'version': 1},
      });
      expect(parsed.savedAt, isNull);
      expect(parsed.savedBy, isNull);
      expect(parsed.envelope['version'], 1);
    });
  });

  group('ServerConfigDb', () {
    late AppDatabase db;
    late Database wrapper;
    late Preferences prefs;

    setUp(() async {
      db = AppDatabase.inMemoryForTest();
      wrapper = Database(db);
      prefs = await _rowPrefs(db);
    });

    tearDown(() async {
      await wrapper.dispose();
      await db.close();
    });

    test('fetch returns null when nothing stored', () async {
      // A normal return, and it has to stay one: the import dialog turns this
      // into "No config stored in the database yet" and offers the operator a
      // way forward. C-4 is what happens when it stops being distinguishable
      // from a failure.
      expect(await ServerConfigDb.fetch(db), isNull);
    });

    test('publish/fetch round-trips, publish overwrites', () async {
      await ServerConfigDb.publish(
        prefs,
        StoredServerConfig(
          savedAt: DateTime(2026, 1, 1),
          savedBy: 'a',
          envelope: {'version': 1, 'ciphertext_b64': 'first'},
        ),
      );
      await ServerConfigDb.publish(
        prefs,
        StoredServerConfig(
          savedAt: DateTime(2026, 2, 2),
          savedBy: 'b',
          envelope: {'version': 1, 'ciphertext_b64': 'second'},
        ),
      );

      final stored = await ServerConfigDb.fetch(db);
      expect(stored, isNotNull);
      expect(stored!.savedBy, 'b');
      expect(stored.envelope['ciphertext_b64'], 'second');
    });

    test('remove deletes the stored config', () async {
      await ServerConfigDb.publish(
          prefs, StoredServerConfig(envelope: {'version': 1}));
      await ServerConfigDb.remove(prefs);
      expect(await ServerConfigDb.fetch(db), isNull);
    });

    test('publishing through the store writes the envelope row fetch reads',
        () async {
      final config = StoredServerConfig(
        savedAt: DateTime(2026, 3, 3),
        savedBy: 'station-7',
        envelope: {'version': 1, 'ciphertext_b64': 'abc'},
      );
      await ServerConfigDb.publish(prefs, config);

      // Not through `fetch` — straight at the table, so this asserts the two
      // halves land in the same row rather than asserting that one half of
      // the reroute agrees with the other.
      final row = await (db.select(db.configItemTable)
            ..where((t) => t.kind.equals(ConfigKind.preference.wireName))
            ..where((t) => t.id.equals(ServerConfigDb.prefsKey))
            ..where((t) => t.scope.equals(ConfigScope.shared.wireName)))
          .getSingle();
      expect(decodePreferencePayload(row.payload), jsonEncode(config.toJson()));
    });

    test('the envelope write leaves no config_change row behind', () async {
      // Seeded so the log is not empty: two empty lists comparing equal
      // proves nothing about a writer.
      await prefs.setString('update_channel', 'stable');
      final before = await _changeLog(db);
      expect(before, isNotEmpty);

      await ServerConfigDb.publish(
        prefs,
        StoredServerConfig(
            savedBy: 'station-7', envelope: {'ciphertext_b64': 'abc'}),
      );
      expect(await _changeLog(db), before,
          reason: 'C-4: a superseded ciphertext must not gain '
              'retention-forever as a side effect of a storage move');

      await ServerConfigDb.remove(prefs);
      expect(await _changeLog(db), before,
          reason: 'nor may deleting one');

      // And the writes did happen, or the two assertions above would pass on
      // a store that wrote nothing at all.
      expect(await ServerConfigDb.fetch(db), isNull);
      expect(await prefs.getString('update_channel'), 'stable');
    });

    test('fetch throws on a corrupt row instead of reporting nothing stored',
        () async {
      await db.into(db.configItemTable).insertOnConflictUpdate(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.preference.wireName,
              id: ServerConfigDb.prefsKey,
              scope: ConfigScope.shared.wireName,
              payload: ConfigItem.of(
                kind: ConfigKind.preference,
                id: ServerConfigDb.prefsKey,
                value: preferencePayload(kPrefStringType, 'not json at all'),
              ).payload,
              rev: const Value(1),
              updatedAt: DateTime.now(),
              updatedBy: 'other-station',
            ),
          );
      await expectLater(ServerConfigDb.fetch(db), throwsFormatException);
    });

    test('a row whose payload is not a preference at all throws too',
        () async {
      // Hand-edited, or written by something that does not know the codec.
      // The row exists, so this is not "nothing stored" and must not read as
      // it — the operator has something in the database that needs looking at.
      await db.into(db.configItemTable).insertOnConflictUpdate(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.preference.wireName,
              id: ServerConfigDb.prefsKey,
              scope: ConfigScope.shared.wireName,
              payload: '{"nothing":"the codec recognises"}',
              rev: const Value(1),
              updatedAt: DateTime.now(),
              updatedBy: 'other-station',
            ),
          );
      await expectLater(ServerConfigDb.fetch(db), throwsFormatException);
    });
  });

  group('fetch bypasses every cache, deliberately', () {
    late AppDatabase db;
    late Database wrapper;

    setUp(() {
      db = AppDatabase.inMemoryForTest();
      wrapper = Database(db);
    });

    tearDown(() async {
      await wrapper.dispose();
      await db.close();
    });

    test('finds what another station wrote, with no reconcile here', () async {
      // The store this station holds has never seen the row: no pull, no
      // sweep, nothing. Importing is precisely the case where the config
      // worth having is the one *another* client stored after this one
      // started, so the read must not be able to answer from a snapshot.
      final prefs = await _rowPrefs(db);
      expect(await prefs.getString(ServerConfigDb.prefsKey), isNull,
          reason: 'the snapshot really is empty, so the fetch below cannot '
              'be passing because of it');

      await _seedRow(
          db, StoredServerConfig(savedBy: 'other', envelope: {'version': 1}));

      final stored = await ServerConfigDb.fetch(db);
      expect(stored, isNotNull);
      expect(stored!.savedBy, 'other');
    });

    test('reports nothing stored once the row is gone, cache or no cache',
        () async {
      final prefs = await _rowPrefs(db);
      await ServerConfigDb.publish(
          prefs, StoredServerConfig(savedBy: 'us', envelope: {'version': 1}));
      expect(await ServerConfigDb.fetch(db), isNotNull);

      // Another station removed it. This station's snapshot still holds the
      // value it wrote — which is exactly the stale answer `fetch` must not
      // give.
      await (db.delete(db.configItemTable)
            ..where((t) => t.id.equals(ServerConfigDb.prefsKey)))
          .go();
      expect(await prefs.getString(ServerConfigDb.prefsKey), isNotNull,
          reason: 'the cache is stale, which is the point of the test');

      expect(await ServerConfigDb.fetch(db), isNull);
    });
  });

  group('ServerConfigDb through the guard', () {
    late AppDatabase db;
    late Database wrapper;
    late _RecordingAuditSink audit;
    late AccessSession session;

    setUp(() {
      db = AppDatabase.inMemoryForTest();
      wrapper = Database(db);
      audit = _RecordingAuditSink();
      session = _administer();
    });

    tearDown(() async {
      await wrapper.dispose();
      await db.close();
    });

    /// The store the page gets from `preferencesProvider`: the row-backed
    /// shared store, whose one guard resolves the group from the key.
    ///
    /// **One store per test, with the session read at each write** — the shape
    /// `configStoreProvider` uses. Two stores would be two stations with two
    /// snapshots, and a `remove` whose snapshot has never seen the row is a
    /// documented no-op that never reaches the guard at all
    /// (`shared_row_preferences.dart`), so the refusal below would pass for
    /// entirely the wrong reason.
    Future<Preferences> guardedPrefs() =>
        _rowPrefs(db, sessionOf: () => session, audit: audit);

    test('an anonymous session cannot publish the shared server config',
        () async {
      session = _anonymous();
      await expectLater(
        ServerConfigDb.publish(
            await guardedPrefs(), StoredServerConfig(envelope: {'version': 1})),
        throwsA(isA<AccessDenied>()),
      );

      expect(await ServerConfigDb.fetch(db), isNull,
          reason: 'a refused publish must leave the table untouched');
      final row = audit.rows.single;
      expect(row.allowed, isFalse);
      expect(row.surface, 'pref');
      expect(row.itemKey, ServerConfigDb.prefsKey);
      expect(row.groupRequired, 'administer');
    });

    test('an anonymous session cannot remove it either', () async {
      session = _administer();
      final prefs = await guardedPrefs();
      await ServerConfigDb.publish(
          prefs, StoredServerConfig(savedBy: 'a', envelope: {'version': 1}));
      audit.rows.clear();

      // Somebody signed out; the same store is asked to delete it.
      session = _anonymous();
      await expectLater(
        ServerConfigDb.remove(prefs),
        throwsA(isA<AccessDenied>()),
      );

      expect(await ServerConfigDb.fetch(db), isNotNull,
          reason: 'a refused remove must leave the stored config in place');
      final row = audit.rows.single;
      expect(row.allowed, isFalse);
      expect(row.itemKey, ServerConfigDb.prefsKey);
      expect(row.groupRequired, 'administer');
    });

    test('an administer session publishes, and the write is in the trail',
        () async {
      session = _administer();
      await ServerConfigDb.publish(
        await guardedPrefs(),
        StoredServerConfig(
          savedAt: DateTime(2026, 4, 4),
          savedBy: 'station-9',
          envelope: {'version': 1, 'ciphertext_b64': 'abc'},
        ),
      );

      final stored = await ServerConfigDb.fetch(db);
      expect(stored, isNotNull);
      expect(stored!.savedBy, 'station-9');

      final row = audit.rows.single;
      expect(row.allowed, isTrue);
      expect(row.surface, 'pref');
      expect(row.itemKey, 'server_config_envelope');
      expect(row.groupRequired, 'administer');
      expect(row.who, 'jon');
      expect(row.origin, 'operator');
      // Neither side of the ciphertext, in the audit row or anywhere else.
      expect(row.newValue ?? '', isNot(contains('abc')));
    });
  });

  group('SecureEnvelope with a user password', () {
    test('decrypts with the right password, rejects the wrong one', () async {
      final envelope = await SecureEnvelope.encrypt(
        jsonConfig: {
          'opcua': [
            {'endpoint': 'opc.tcp://10.0.0.1:4840', 'password': 'plc secret'}
          ],
        },
        compiledPrefix: 'prefix:',
        exportPostfix: 'hunter22',
      );

      // The database only ever sees the envelope — the secret must not
      // appear anywhere in its JSON.
      expect(jsonEncode(envelope), isNot(contains('plc secret')));

      final decrypted = await SecureEnvelope.decrypt(
        envelope: envelope,
        compiledPrefix: 'prefix:',
        postfix: 'hunter22',
      );
      expect(decrypted['opcua'][0]['password'], 'plc secret');

      await expectLater(
        SecureEnvelope.decrypt(
          envelope: envelope,
          compiledPrefix: 'prefix:',
          postfix: 'wrong-password',
        ),
        throwsA(anything),
      );
    });
  });

  group('ImportExportCard database buttons', () {
    testWidgets('renders store and load buttons', (tester) async {
      await pumpAndLoad(tester, _buildCard());
      expect(find.text('Store in Database'), findsOneWidget);
      expect(find.text('Load from Database'), findsOneWidget);
      expect(find.text('Import File'), findsOneWidget);
      expect(find.text('Export File'), findsOneWidget);
    });

    testWidgets('store without a database connection shows an error',
        (tester) async {
      await pumpAndLoad(tester, _buildCard());
      await tester.tap(find.text('Store in Database'));
      await settle(tester);
      expect(find.textContaining('No database connection'), findsOneWidget);
    });

    testWidgets('load with an empty database reports nothing stored',
        (tester) async {
      final appDb = AppDatabase.inMemoryForTest();
      final db = Database(appDb);
      addTearDown(() async => appDb.close());

      await pumpAndLoad(tester, _buildCard(database: db));
      await tester.tap(find.text('Load from Database'));
      await settle(tester);
      expect(find.textContaining('No config stored'), findsOneWidget);

      // Cancel the wrapper's periodic flush timer before the framework's
      // pending-timer check at the end of the test body.
      await db.dispose();
    });

    testWidgets('store flow validates the password dialog and stores a row',
        (tester) async {
      final appDb = AppDatabase.inMemoryForTest();
      final db = Database(appDb);
      addTearDown(() async => appDb.close());

      // The page publishes through this store now, so it has to be the one
      // wired to `appDb` — otherwise the row never reaches the table `fetch`
      // reads and the assertion below would be measuring the wrong thing.
      final prefs = await _rowPrefs(
        appDb,
        stateManConfig: StateManConfig(opcua: [
          OpcUAConfig()
            ..endpoint = 'opc.tcp://10.0.0.1:4840'
            ..serverAlias = 'plc1'
            ..username = 'operator'
            ..password = 'plc secret',
        ]),
      );

      await pumpAndLoad(tester, _buildCard(database: db, prefs: prefs));
      await tester.tap(find.text('Store in Database'));
      await settle(tester);
      expect(find.text('Store config in database'), findsOneWidget);

      // Too short.
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'abc');
      await tester.tap(find.text('Store'));
      await settle(tester);
      expect(
          find.text('Password must be at least 6 characters.'), findsOneWidget);

      // Mismatch.
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'hunter22');
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm password'), 'hunter23');
      await tester.tap(find.text('Store'));
      await settle(tester);
      expect(find.text('Passwords do not match.'), findsOneWidget);

      // Valid.
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm password'), 'hunter22');
      await tester.tap(find.text('Store'));
      await settle(tester);

      expect(find.text('Store config in database'), findsNothing);
      final stored = await _storedRow(appDb);
      expect(stored, isNotNull);
      expect(stored!.savedBy, isNotNull);
      // Ciphertext only — the PLC credential must not leak into the row.
      expect(jsonEncode(stored.envelope), isNot(contains('plc secret')));

      final decrypted = await SecureEnvelope.decrypt(
        envelope: stored.envelope,
        compiledPrefix: 'Flottur köttur:',
        postfix: 'hunter22',
      );
      expect(decrypted['opcua'][0]['password'], 'plc secret');

      await db.dispose();
    });

    testWidgets(
        'load flow rejects a wrong password, applies config on the right one',
        (tester) async {
      final appDb = AppDatabase.inMemoryForTest();
      final db = Database(appDb);
      addTearDown(() async => appDb.close());

      final envelope = await SecureEnvelope.encrypt(
        jsonConfig: {
          'opcua': [
            {
              'endpoint': 'opc.tcp://10.9.9.9:4840',
              'server_alias': 'imported_plc',
            }
          ],
        },
        compiledPrefix: 'Flottur köttur:',
        exportPostfix: 'hunter22',
      );
      await _seed(
        db,
        StoredServerConfig(
          savedAt: DateTime(2026, 8, 18),
          savedBy: 'station-2',
          envelope: envelope,
        ),
      );

      final prefs = await createTestPreferences();
      await pumpAndLoad(tester, _buildCard(database: db, prefs: prefs));
      await tester.tap(find.text('Load from Database'));
      await settle(tester);
      expect(find.text('Load config from database'), findsOneWidget);
      expect(find.textContaining('station-2'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'wrong-password');
      await tester.tap(find.text('Decrypt & import'));
      await settle(tester);
      // Wrong password keeps the dialog open for a retry.
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('Load config from database'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'hunter22');
      await tester.tap(find.text('Decrypt & import'));
      await settle(tester);

      expect(find.text('Load config from database'), findsNothing);
      expect(
          find.textContaining('Config imported from database'), findsOneWidget);

      // The imported config is now the saved one.
      final saved = await StateManConfig.fromPrefs(prefs);
      expect(saved.opcua.single.serverAlias, 'imported_plc');
      expect(saved.opcua.single.endpoint, 'opc.tcp://10.9.9.9:4840');

      await db.dispose();
    });

    testWidgets('load reuses this client\'s certificates for known servers',
        (tester) async {
      final appDb = AppDatabase.inMemoryForTest();
      final db = Database(appDb);
      addTearDown(() async => appDb.close());

      final placeholder = base64Encode(utf8.encode('todo'));
      String b64(String s) => base64Encode(utf8.encode(s));

      // This client already holds real certificates for plc1 and plc2.
      final prefs = await createTestPreferences(
        stateManConfig: StateManConfig.fromJson({
          'opcua': [
            {
              'endpoint': 'opc.tcp://10.0.0.1:4840',
              'server_alias': 'plc1',
              'ssl_cert': b64('real plc1 cert'),
              'ssl_key': b64('real plc1 key'),
            },
            {
              'endpoint': 'opc.tcp://10.0.0.2:4840',
              'server_alias': 'plc2',
              'ssl_cert': b64('real plc2 cert'),
              'ssl_key': b64('real plc2 key'),
            },
          ],
        }),
      );

      // Stored config: plc1 at the same endpoint, plc2 moved to a new
      // address (alias match), plc3 unknown here — certs scrubbed to the
      // placeholder by the export, as always.
      final envelope = await SecureEnvelope.encrypt(
        jsonConfig: {
          'opcua': [
            {
              'endpoint': 'opc.tcp://10.0.0.1:4840',
              'server_alias': 'plc1',
              'ssl_cert': placeholder,
              'ssl_key': placeholder,
            },
            {
              'endpoint': 'opc.tcp://10.0.0.99:4840',
              'server_alias': 'plc2',
              'ssl_cert': placeholder,
              'ssl_key': placeholder,
            },
            {
              'endpoint': 'opc.tcp://10.9.9.9:4840',
              'server_alias': 'plc3',
              'ssl_cert': placeholder,
              'ssl_key': placeholder,
            },
          ],
        },
        compiledPrefix: 'Flottur köttur:',
        exportPostfix: 'hunter22',
      );
      await _seed(db, StoredServerConfig(envelope: envelope));

      await pumpAndLoad(tester, _buildCard(database: db, prefs: prefs));
      await tester.tap(find.text('Load from Database'));
      await settle(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'hunter22');
      await tester.tap(find.text('Decrypt & import'));
      await settle(tester);

      // Only the server this client has never seen needs a certificate.
      expect(find.textContaining('generate new certificates for 1 server'),
          findsOneWidget);

      final saved = await StateManConfig.fromPrefs(prefs);
      final byAlias = {for (final s in saved.opcua) s.serverAlias: s};
      expect(utf8.decode(byAlias['plc1']!.sslCert!), 'real plc1 cert');
      expect(utf8.decode(byAlias['plc1']!.sslKey!), 'real plc1 key');
      // The alias match carries the certificate across an address change.
      expect(byAlias['plc2']!.endpoint, 'opc.tcp://10.0.0.99:4840');
      expect(utf8.decode(byAlias['plc2']!.sslCert!), 'real plc2 cert');
      expect(utf8.decode(byAlias['plc2']!.sslKey!), 'real plc2 key');
      // The unknown server keeps the placeholder — still needs generation.
      expect(utf8.decode(byAlias['plc3']!.sslCert!), 'todo');

      await db.dispose();
    });

    testWidgets('load keeps the local database connection settings',
        (tester) async {
      final appDb = AppDatabase.inMemoryForTest();
      final db = Database(appDb);
      addTearDown(() async => appDb.close());

      // The connection this client is actually using right now.
      await DatabaseConfig(
        postgres: pg.Endpoint(host: 'local-host', database: 'hmi'),
      ).toPrefs();

      // Another machine stored the config with its own connection details.
      final envelope = await SecureEnvelope.encrypt(
        jsonConfig: {
          'opcua': [],
          'database': DatabaseConfig(
            postgres: pg.Endpoint(host: 'other-host', database: 'hmi'),
          ).toJson(),
        },
        compiledPrefix: 'Flottur köttur:',
        exportPostfix: 'hunter22',
      );
      await _seed(db, StoredServerConfig(envelope: envelope));

      final prefs = await createTestPreferences();
      await pumpAndLoad(tester, _buildCard(database: db, prefs: prefs));
      await tester.tap(find.text('Load from Database'));
      await settle(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'hunter22');
      await tester.tap(find.text('Decrypt & import'));
      await settle(tester);

      expect(find.textContaining('Config imported from database'),
          findsOneWidget);
      final local = await DatabaseConfig.fromPrefs();
      expect(local.postgres?.host, 'local-host');

      await db.dispose();
    });
  });
}
