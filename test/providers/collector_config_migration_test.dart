// Spec §6's second bypass: `collectorProvider` constructing its own
// `SharedPreferencesAsync()` and writing plant configuration through a store
// nothing guards.
//
// The reroute is one line. The risk is the other one: `collector_config` lives
// in the **device file** today, and `preferencesProvider` is the shared,
// database-backed store whose in-memory cache is seeded from Postgres. Moving
// the read without moving the value would have every station read `null`,
// write a default, and lose its collector configuration — a plant regression
// dressed as a refactor.
//
// So the first group here proves the premise before anything is changed, and
// the rest pin the carry-over that follows from it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/access_routes.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';

import '../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    // The real backend on macOS and Linux is the OS keychain, which outlives
    // the process and is shared by every test in the run.
    SecureStorage.setInstance(FakeSecureStorage());
  });

  // ---------------------------------------------------------------------------
  // The premise, proven rather than asserted by the plan.
  // ---------------------------------------------------------------------------

  group('the premise: the two stores are not the same store', () {
    test('a collector_config that exists only on the device reads as absent '
        'through the shared store', () async {
      final s = _stores();
      await s.device
          .setString(Collector.configLocation, jsonEncode({'collect': true}));

      // This is the whole reason the carry-over exists. `Preferences.create`
      // with a live database calls `loadFromPostgres()` and then
      // `syncToLocalCache()` — it never calls `_loadFromLocalCache()`, so the
      // memory cache holds Postgres rows and nothing else. `_stores()`
      // constructs that state directly.
      expect(await s.shared.getString(Collector.configLocation), isNull,
          reason: 'if this ever passes the other way, the carry-over is dead '
              'code and should be deleted');
      expect(await s.device.getString(Collector.configLocation), isNotNull);
    });

    test('it does surface when there is no database, which is the one case '
        'the collector never reaches', () async {
      // The other branch of `Preferences.create`: with `db == null` it falls
      // back to `_loadFromLocalCache()`, so the device file IS the shared
      // store. Recorded so the premise above is understood as conditional on
      // the database being up — and `collectorProvider` returns null before
      // it reads a preference when the database is down, so the one case
      // where the two stores agree is the one case this path never runs in.
      final device = InMemoryPreferences();
      await device
          .setString(Collector.configLocation, jsonEncode({'collect': true}));

      final offline = await Preferences.create(db: null, localCache: device);

      expect(await offline.getString(Collector.configLocation), isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // The carry-over itself.
  // ---------------------------------------------------------------------------

  group('resolveCollectorConfig', () {
    test('a station that already has a shared config keeps it and writes '
        'nothing', () async {
      final s = _stores();
      await s.shared.setString(
          Collector.configLocation, jsonEncode({'collect': true}));
      s.sink.rows.clear();

      final config = await _resolve(s);

      expect(config.collect, isTrue);
      expect(s.sink.rows, isEmpty,
          reason: 'reading an existing config must write nothing at all');
      expect(s.denials, isEmpty);
    });

    test('a station whose config is only on the device keeps its existing '
        'configuration, field for field', () async {
      final s = _stores();
      // The value that must survive the move. `collect: true` is the
      // collector station; a silent reset to the `CollectorConfig()` default
      // turns that station into one that records nothing.
      final existing = CollectorConfig(collect: true);
      await s.device.setString(
          Collector.configLocation, jsonEncode(existing.toJson()));

      final config = await _resolve(s);

      expect(config.collect, existing.collect);
      expect(jsonEncode(config.toJson()), jsonEncode(existing.toJson()),
          reason: 'the carried config must be the same config, not merely a '
              'config');
      expect(await s.shared.getString(Collector.configLocation),
          jsonEncode(existing.toJson()),
          reason: 'and it must now live in the shared store, so the next boot '
              'finds it there');
    });

    test('the carry-over is written through the system path, audited as '
        'origin: system', () async {
      final s = _stores();
      await s.device.setString(
          Collector.configLocation, jsonEncode(CollectorConfig(collect: true).toJson()));

      await _resolve(s);

      final rows =
          s.sink.rows.where((r) => r.itemKey == Collector.configLocation);
      expect(rows, hasLength(1));
      expect(rows.single.origin, 'system',
          reason: 'systemWrites skips the denial, not the audit');
      expect(rows.single.allowed, isTrue);
      expect(s.denials, isEmpty,
          reason: 'nobody is signed in at boot; the carry-over must not be '
              'refused');
    });

    test('a station with neither writes one default, through the same system '
        'path', () async {
      final s = _stores();

      final config = await _resolve(s);

      expect(config.collect, CollectorConfig().collect);
      expect(await s.shared.getString(Collector.configLocation), isNotNull);
      final rows =
          s.sink.rows.where((r) => r.itemKey == Collector.configLocation);
      expect(rows, hasLength(1));
      expect(rows.single.origin, 'system');
      expect(s.denials, isEmpty);
    });

    test('it is idempotent: resolving twice writes once', () async {
      final s = _stores();
      await s.device.setString(
          Collector.configLocation, jsonEncode(CollectorConfig(collect: true).toJson()));

      await _resolve(s);
      final second = await _resolve(s);

      expect(second.collect, isTrue);
      expect(
          s.sink.rows.where((r) => r.itemKey == Collector.configLocation),
          hasLength(1),
          reason: 'the second pass must find the shared store already seeded');
    });

    test('a corrupt device blob falls back to the default rather than '
        'throwing', () async {
      final s = _stores();
      await s.device.setString(Collector.configLocation, 'not json at all');

      final config = await _resolve(s);

      expect(config.collect, CollectorConfig().collect);
      expect(s.denials, isEmpty);
    });

    test('an anonymous session would be refused the same write through the '
        'ordinary path', () async {
      // The control: the escape is what makes the boot write land, not the
      // key being unguarded. If this ever stops throwing, `collector_config`
      // has fallen out of `kPrefAccessRules` and the system path is doing
      // nothing.
      final s = _stores();

      await expectLater(
        s.guarded.setString(Collector.configLocation, '{}'),
        throwsA(isA<AccessDenied>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Through the provider.
  // ---------------------------------------------------------------------------

  group('collectorProvider', () {
    test('constructs no preferences store of its own', () {
      // Bypass 2, stated as a test as well as a CI grep: the file must not
      // reach `SharedPreferencesAsync` at all.
      final code = _sourceOf('lib/providers/collector.dart');
      expect(code, isNot(contains('SharedPreferencesAsync')));
      expect(code, contains('preferencesProvider'));
    });

    test('brings an existing device-local config into the shared store on '
        'first build', () async {
      final s = _stores();
      final existing = CollectorConfig(collect: true);
      await s.device.setString(
          Collector.configLocation, jsonEncode(existing.toJson()));

      final container = _container(s, withDatabase: true);
      final collector = await container.read(collectorProvider.future);
      addTearDown(() async => collector?.close());

      expect(collector, isNotNull);
      expect(await s.shared.getString(Collector.configLocation),
          jsonEncode(existing.toJson()));
      expect(s.denials, isEmpty);
      // The main isolate never collects, whatever the stored config says.
      expect(collector!.config.collect, isFalse);
    });

    test('a station with no database still answers null, and touches no '
        'preference doing it', () async {
      final s = _stores();
      final container = _container(s, withDatabase: false);

      expect(await container.read(collectorProvider.future), isNull);
      expect(await s.shared.getString(Collector.configLocation), isNull,
          reason: 'the collector must not start depending on Postgres being '
              'up, and must not seed a config it will not use');
      expect(s.sink.rows, isEmpty);
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures.
// -----------------------------------------------------------------------------

const String _kStation = 'test-panel';

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

class _Stores {
  _Stores({
    required this.shared,
    required this.guarded,
    required this.device,
    required this.sink,
    required this.denials,
  });

  final Preferences shared;
  final GuardedPreferences guarded;
  final InMemoryPreferences device;
  final _RecordingSink sink;
  final List<AccessDenied> denials;
}

/// A shared store in the state a live database leaves it in, plus the device
/// store it mirrors into — the same physical file in production, which is why
/// `mcp_config_local_test.dart` models it the same way.
_Stores _stores() {
  final device = InMemoryPreferences();
  final shared = Preferences(
    database: null,
    secureStorage: FakeSecureStorage(),
    localCache: device,
  );
  final sink = _RecordingSink();
  final denials = <AccessDenied>[];
  final guarded = GuardedPreferences(
    inner: shared,
    policy: const AccessPolicy(routes: kRaisedRoutes),
    // The real boot session: anonymous, holding the seeded Operator groups.
    session: () => kSessionWhileLoading,
    audit: sink,
    station: _kStation,
    onDenied: denials.add,
  );
  return _Stores(
    shared: shared,
    guarded: guarded,
    device: device,
    sink: sink,
    denials: denials,
  );
}

Future<CollectorConfig> _resolve(_Stores s) => resolveCollectorConfig(
      shared: s.guarded,
      systemWrites: s.guarded.systemWrites,
      local: s.device,
    );

ProviderContainer _container(_Stores s, {required bool withDatabase}) {
  Database? db;
  if (withDatabase) {
    final appDb = AppDatabase.inMemoryForTest();
    db = Database(appDb);
    addTearDown(appDb.close);
  }

  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) async => s.guarded),
    localPreferencesProvider.overrideWithValue(s.device),
    databaseProvider.overrideWith((ref) async => db),
    stateManProvider.overrideWith((ref) async {
      final stateMan = await OpcUaStateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {}),
      );
      addTearDown(() => stateMan
          .close()
          .timeout(const Duration(seconds: 5), onTimeout: () {}));
      return stateMan;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

String _sourceOf(String path) => File(path).readAsStringSync();
