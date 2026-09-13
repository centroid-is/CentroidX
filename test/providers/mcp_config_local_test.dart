import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/mcp_bridge.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/preferences.dart'
    show InMemoryPreferences, Preferences;
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show McpConfig, McpToolToggles, writeMcpConfigToPreferences;

import '../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mirrors production: the database-backed Preferences uses the device's
  // SharedPreferences as its local cache — the same physical store the
  // device-local preferences read from.
  (Preferences, InMemoryPreferences) createStores() {
    final deviceStore = InMemoryPreferences();
    final shared = Preferences(
      database: null,
      secureStorage: FakeSecureStorage(),
      localCache: deviceStore,
    );
    return (shared, deviceStore);
  }

  ProviderContainer createContainer(
      Preferences shared, InMemoryPreferences deviceStore) {
    final container = ProviderContainer(overrides: [
      preferencesProvider.overrideWith((ref) async => shared),
      localPreferencesProvider.overrideWithValue(deviceStore),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  group('mcpConfigProvider (device-local)', () {
    test('migrates a shared config onto the device and cleans the shared '
        'store', () async {
      final (shared, deviceStore) = createStores();
      const config = McpConfig(
        serverEnabled: true,
        port: 9999,
        toggles: McpToolToggles(trendsEnabled: false),
      );
      // Simulates a pre-migration install: the config sits in the shared
      // (database) store and is mirrored into the device store.
      await shared.setString(McpConfig.kPrefKey, jsonEncode(config.toJson()));

      final container = createContainer(shared, deviceStore);
      final result = await container.read(mcpConfigProvider.future);

      expect(result, config);
      expect(await shared.getString(McpConfig.kPrefKey), isNull,
          reason: 'the shared store must no longer carry the MCP config');
      expect(await deviceStore.getString(McpConfig.kPrefKey), isNotNull,
          reason: 'the device store must keep the migrated config');
    });

    test('returns defaults on a fresh install', () async {
      final (shared, deviceStore) = createStores();
      final container = createContainer(shared, deviceStore);

      final result = await container.read(mcpConfigProvider.future);

      expect(result, McpConfig.defaults);
    });

    test('saving writes only to the device store', () async {
      final (shared, deviceStore) = createStores();
      final container = createContainer(shared, deviceStore);
      await container.read(mcpConfigProvider.future);

      const updated = McpConfig(serverEnabled: true, port: 4242);
      await writeMcpConfigToPreferences(
          container.read(localPreferencesProvider), updated);
      container.invalidate(mcpConfigProvider);

      expect(await container.read(mcpConfigProvider.future), updated);
      expect(await shared.getString(McpConfig.kPrefKey), isNull,
          reason: 'saving the MCP config must never touch the shared store');
    });

    test('migration re-runs when preferencesProvider is recreated '
        '(database reconnect after offline start)', () async {
      final (shared, deviceStore) = createStores();
      final container = createContainer(shared, deviceStore);
      await container.read(mcpConfigProvider.future);

      // Simulate a database coming online after startup: the recreated
      // Preferences now carries an mcp.config row that the first
      // migration pass could not delete.
      const staleDbConfig = McpConfig(serverEnabled: true, port: 1111);
      await shared.setString(
          McpConfig.kPrefKey, jsonEncode(staleDbConfig.toJson()));
      container.invalidate(preferencesProvider);

      expect(await container.read(mcpConfigProvider.future), staleDbConfig,
          reason: 'the re-run migration must adopt the synced value');
      expect(await shared.getString(McpConfig.kPrefKey), isNull,
          reason: 'the re-run migration must clean the shared store so the '
              'row cannot be re-synced over the device config again');
    });

    test('legacy database keys seed the device config and are removed',
        () async {
      final (shared, deviceStore) = createStores();
      await shared.setBool('mcp_server_enabled', true);
      await shared.setInt('mcp_server_port', 7777);

      final container = createContainer(shared, deviceStore);
      final result = await container.read(mcpConfigProvider.future);

      expect(result.serverEnabled, isTrue);
      expect(result.port, 7777);
      for (final key in McpConfig.legacyKeys) {
        expect(await shared.containsKey(key), isFalse,
            reason: 'legacy key $key must be removed from the shared store');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The boot migration under a fail-closed guard.
  //
  // `migrateMcpConfigToDeviceLocal` calls `shared.remove(...)` twelve times at
  // boot, with nobody signed in, against an `mcp.` prefix rule that requires
  // `administer`. Through the ordinary path every one of those is an
  // `AccessDenied` the provider's `catch` swallows: the stale shared row the
  // migration exists to delete would stay forever, behind a log line that
  // reads exactly like the database-unavailable case the catch was written
  // for.
  // ---------------------------------------------------------------------------

  group('the boot migration writes as the machine', () {
    test('completes with an anonymous session, and the stale shared row is '
        'gone afterwards', () async {
      final g = _guardedStores();
      const stale = McpConfig(serverEnabled: true, port: 1234);
      await g.shared.setString(McpConfig.kPrefKey, jsonEncode(stale.toJson()));

      final container = _guardedContainer(g);
      final result = await container.read(mcpConfigProvider.future);

      expect(result, stale,
          reason: 'the migration must have carried the shared config onto the '
              'device rather than been refused');
      expect(await g.shared.getString(McpConfig.kPrefKey), isNull,
          reason: 'the row the migration exists to delete must be gone');
      expect(g.denials, isEmpty,
          reason: 'a cold boot must produce no denial prompt');
    });

    test('every removed key lands in the trail as origin: system', () async {
      final g = _guardedStores();
      await g.shared.setString(
          McpConfig.kPrefKey, jsonEncode(McpConfig.defaults.toJson()));
      // Every legacy key present too, so each one has a removal to record.
      for (final key in McpConfig.legacyKeys) {
        if (key == 'mcp_server_port') {
          await g.shared.setInt(key, McpConfig.defaultPort);
        } else {
          await g.shared.setBool(key, true);
        }
      }
      g.sink.rows.clear();

      final container = _guardedContainer(g);
      await container.read(mcpConfigProvider.future);

      final removed = {
        for (final r in g.sink.rows)
          if (r.newValue == null) r.itemKey,
      };
      expect(removed, contains(McpConfig.kPrefKey));
      for (final key in McpConfig.legacyKeys) {
        expect(removed, contains(key),
            reason: 'the removal of $key must be recorded, not exempted');
      }
      // Skipping the denial is not skipping the trail.
      expect(g.sink.rows.every((r) => r.origin == 'system'), isTrue);
      expect(g.sink.rows.every((r) => r.allowed), isTrue);
    });

    test('a re-run with nothing left to migrate writes nothing to the trail',
        () async {
      // The migration re-runs on every database reconnect. Removing keys that
      // are already gone used to put one `— → —` row per MCP key into the
      // audit trail each time, for a state that never changed.
      final g = _guardedStores();
      await g.shared.setString(
          McpConfig.kPrefKey, jsonEncode(McpConfig.defaults.toJson()));

      await _guardedContainer(g).read(mcpConfigProvider.future);
      g.sink.rows.clear();

      await _guardedContainer(g).read(mcpConfigProvider.future);

      expect(g.sink.rows.map((r) => r.itemKey), isEmpty,
          reason: 'nothing was removed, so nothing may be recorded');
    });

    test('a refusal is logged as a policy defect, not as a database outage',
        () async {
      // The arm exists for the day somebody routes this back through the
      // checked path. Injected here rather than contrived in production: the
      // system path cannot deny, so the only way to reach the arm is a store
      // that refuses.
      final g = _guardedStores();
      final lines = await _captureStderr(() async {
        final container = _guardedContainer(
          g,
          systemWritesOverride: _RefusingPreferences(
              AccessDenied(McpConfig.kPrefKey, AccessGroup.administer)),
        );
        await container.read(mcpConfigProvider.future);
      });

      final line = lines.join('\n');
      expect(line, contains('REFUSED'),
          reason: 'a denial must not read like the outage case');
      expect(line, contains(AccessGroup.administer.name),
          reason: 'the message must name the group the migration needed');
      expect(line, contains(McpConfig.kPrefKey));
      expect(line, isNot(contains('MCP config migration skipped')),
          reason: 'the two failures must be distinguishable in a log a month '
              'later');
    });

    test('every other failure still logs the sentence it always did', () async {
      final g = _guardedStores();
      final lines = await _captureStderr(() async {
        final container = _guardedContainer(
          g,
          systemWritesOverride:
              _RefusingPreferences(StateError('connection closed')),
        );
        await container.read(mcpConfigProvider.future);
      });

      final line = lines.join('\n');
      expect(line, contains('MCP config migration skipped'));
      expect(line, isNot(contains('REFUSED')));
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures for the guarded group.
// -----------------------------------------------------------------------------

const String _kStation = 'test-panel';

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

class _GuardedStores {
  _GuardedStores({
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

_GuardedStores _guardedStores() {
  final device = InMemoryPreferences();
  final shared = Preferences(
    database: null,
    secureStorage: FakeSecureStorage(),
    localCache: device,
  );
  final sink = _RecordingSink();
  final denials = <AccessDenied>[];
  return _GuardedStores(
    shared: shared,
    device: device,
    sink: sink,
    denials: denials,
    guarded: GuardedPreferences(
      inner: shared,
      policy: const AccessPolicy(routes: kRaisedRoutes),
      // The real boot session: anonymous, holding the seeded Operator groups.
      session: () => kSessionWhileLoading,
      audit: sink,
      station: _kStation,
      onDenied: denials.add,
    ),
  );
}

ProviderContainer _guardedContainer(
  _GuardedStores g, {
  Preferences? systemWritesOverride,
}) {
  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) async => g.guarded),
    localPreferencesProvider.overrideWithValue(g.device),
    if (systemWritesOverride != null)
      systemPreferencesProvider
          .overrideWith((ref) async => systemWritesOverride),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// A store whose every write throws [_error].
///
/// Reads answer null, which is all the migration needs to get as far as its
/// first `remove`, and the first `remove` is what these tests are about.
class _RefusingPreferences implements Preferences {
  _RefusingPreferences(this._error);

  final Object _error;

  @override
  Future<String?> getString(String key, {bool secret = false}) async => null;

  @override
  Future<bool?> getBool(String key, {bool secret = false}) async => null;

  @override
  Future<int?> getInt(String key, {bool secret = false}) async => null;

  // Every key reads as present, so the migration reaches the write that
  // refuses rather than skipping it.
  @override
  Future<bool> containsKey(String key, {bool secret = false}) async => true;

  @override
  Future<void> remove(String key, {bool secret = false}) =>
      Future<void>.error(_error);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.error(_error);
}

/// Runs [body] with `dart:io`'s top-level `stderr` replaced, and answers every
/// line it wrote.
Future<List<String>> _captureStderr(Future<void> Function() body) async {
  final captured = <String>[];
  await IOOverrides.runZoned(
    body,
    stderr: () => _CapturingStdout(captured),
  );
  return captured;
}

class _CapturingStdout implements Stdout {
  _CapturingStdout(this.lines);

  final List<String> lines;

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
