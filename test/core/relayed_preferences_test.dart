@TestOn('vm')

/// [RelayedPreferences] in isolation: the routing table, the secret
/// isolation, the one bootstrap carve-out, and the park/fill/fail contract
/// that keeps a call on an empty slot from being either a silent local write
/// or a panel that will not boot.
///
/// The **inner** store is a real [Preferences] on `db: null`, not a fake. The
/// whole question this class answers is "which of two real stores did that
/// call land in", and a fake inner would let the local half drift from the
/// one the app actually holds. The wire half is a typed fake, because there
/// is no socket in a unit test — the transport itself is proven over a real
/// one elsewhere.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/relayed_preferences.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

// -----------------------------------------------------------------------------
// Fakes
// -----------------------------------------------------------------------------

/// The backend store, as the wire sees it. Records every call so an arm can
/// assert not just what the far end holds but that it was *asked* — "no wire
/// call happened" is the whole claim of the secret arms.
final class _FakeWire implements rp.PreferencesApi {
  final Map<String, Object?> store = {};
  final List<String> calls = [];
  final _changes = StreamController<String>.broadcast();

  /// When set, every member throws this — the downed link.
  Object? failWith;

  T _call<T>(String call, T Function() body) {
    calls.add(call);
    final failure = failWith;
    if (failure != null) throw failure;
    return body();
  }

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async =>
      _call('getKeys', () => allowList == null
          ? store.keys.toSet()
          : store.keys.where(allowList.contains).toSet());

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      _call('getAll', () => allowList == null
          ? Map<String, Object?>.from(store)
          : {
              for (final e in store.entries)
                if (allowList.contains(e.key)) e.key: e.value,
            });

  @override
  Future<bool?> getBool(String key) async =>
      _call('getBool($key)', () => store[key] as bool?);
  @override
  Future<int?> getInt(String key) async =>
      _call('getInt($key)', () => store[key] as int?);
  @override
  Future<double?> getDouble(String key) async =>
      _call('getDouble($key)', () => store[key] as double?);
  @override
  Future<String?> getString(String key) async =>
      _call('getString($key)', () => store[key] as String?);
  @override
  Future<List<String>?> getStringList(String key) async =>
      _call('getStringList($key)', () => store[key] as List<String>?);
  @override
  Future<bool> containsKey(String key) async =>
      _call('containsKey($key)', () => store.containsKey(key));

  @override
  Future<void> setBool(String key, bool value) async =>
      _call('setBool($key)', () => store[key] = value);
  @override
  Future<void> setInt(String key, int value) async =>
      _call('setInt($key)', () => store[key] = value);
  @override
  Future<void> setDouble(String key, double value) async =>
      _call('setDouble($key)', () => store[key] = value);
  @override
  Future<void> setString(String key, String value) async =>
      _call('setString($key)', () => store[key] = value);
  @override
  Future<void> setStringList(String key, List<String> value) async =>
      _call('setStringList($key)', () => store[key] = value);
  @override
  Future<void> remove(String key) async =>
      _call('remove($key)', () => store.remove(key));
  @override
  Future<void> clear({Set<String>? allowList}) async =>
      _call('clear(allowList: $allowList)', () {
        if (allowList == null) {
          store.clear();
        } else {
          store.removeWhere((k, _) => allowList.contains(k));
        }
      });

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  void announce(String key) => _changes.add(key);
  Future<void> dispose() => _changes.close();
}

final class _FakeSecrets implements MySecureStorage {
  final Map<String, String> store = {};
  @override
  Future<void> delete({required String key}) async => store.remove(key);
  @override
  Future<String?> read({required String key}) async => store[key];
  @override
  Future<void> write({required String key, required String value}) async =>
      store[key] = value;
}

// -----------------------------------------------------------------------------
// Harness
// -----------------------------------------------------------------------------

final class _Fixture {
  /// [reconcile] is off unless an arm is about it. It issues a wire read of
  /// its own on first fill, and an arm whose claim is "this call made no wire
  /// call at all" cannot make that claim with a second caller in the room.
  _Fixture({bool reconcile = false}) {
    // The secret cache is process-wide and static, so a value cached by an
    // earlier test would answer here and the secret arms would pass without
    // touching this fixture's storage at all.
    Preferences.clearSecretCache();
    mirror = InMemoryPreferences();
    secrets = _FakeSecrets();
    inner = Preferences(
      database: null,
      secureStorage: secrets,
      localCache: mirror,
    );
    wire = _FakeWire();
    slot = GatewayPreferencesSlot();
    prefs = RelayedPreferences(
        inner: inner, slot: slot, reconcileOnFill: reconcile);
  }

  late final InMemoryPreferences mirror;
  late final _FakeSecrets secrets;
  late final Preferences inner;
  late final _FakeWire wire;
  late final GatewayPreferencesSlot slot;
  late final RelayedPreferences prefs;

  void connect() => slot.fill(wire);

  Future<void> dispose() async {
    slot.clear();
    await wire.dispose();
  }
}

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.dispose());

  // ---------------------------------------------------------------------------
  group('a shared key goes to the backend and nowhere else', () {
    test('setString reaches the wire, and leaves no row in the local store',
        () async {
      f.connect();
      await f.prefs.setString('alarm_man_config', '{"alarms":[]}');

      expect(f.wire.store['alarm_man_config'], '{"alarms":[]}');
      // The consequence the whole change exists for: the panel's own store
      // must NOT quietly hold a second, disagreeing copy.
      expect(await f.mirror.getString('alarm_man_config'), isNull);
      expect(f.wire.calls, contains('setString(alarm_man_config)'));
    });

    test('getString reads the backend, not a stale local mirror', () async {
      // The station's earlier direct-mode life left a row behind. It must not
      // be what the screen renders.
      await f.mirror.setString('alarm_man_config', 'STALE');
      f.wire.store['alarm_man_config'] = 'FRESH';
      f.connect();

      expect(await f.prefs.getString('alarm_man_config'), 'FRESH');
    });

    test('every typed member routes to the wire', () async {
      f.connect();
      await f.prefs.setBool('a', true);
      await f.prefs.setInt('b', 1);
      await f.prefs.setDouble('c', 1.5);
      await f.prefs.setStringList('d', ['x']);
      await f.prefs.remove('a');

      expect(await f.prefs.getInt('b'), 1);
      expect(await f.prefs.getDouble('c'), 1.5);
      expect(await f.prefs.getStringList('d'), ['x']);
      expect(await f.prefs.containsKey('b'), isTrue);
      expect(await f.prefs.containsKey('a'), isFalse);
      expect(await f.mirror.getAll(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  group('a device-local key never travels', () {
    test('a write of a device-local key stays local and makes no wire call',
        () async {
      f.connect();
      await f.prefs.setString('startup_url', '/lines/1');

      expect(f.wire.store, isEmpty);
      expect(f.wire.calls, isEmpty);
      expect(await f.mirror.getString('startup_url'), '/lines/1');
    });

    test('a read of a device-local key answers this station, even when the '
        'backend holds a different value', () async {
      f.wire.store['startup_url'] = '/somebody-elses-page';
      await f.prefs.setString('startup_url', '/mine');
      f.connect();

      expect(await f.prefs.getString('startup_url'), '/mine');
    });

    test('the transport config itself never goes over the transport', () async {
      f.connect();
      await f.prefs.setString('gateway_transport', '{"kind":"gateway"}');
      expect(f.wire.calls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  group('a secret never crosses the wire', () {
    test('a secret write goes to the keychain and makes no wire call',
        () async {
      f.connect();
      await f.prefs.setString('state_man_config', 'CREDENTIALS', secret: true);

      expect(f.secrets.store['state_man_config'], 'CREDENTIALS');
      expect(f.wire.calls, isEmpty);
      expect(f.wire.store, isEmpty);
    });

    test('a secret read comes from the keychain and makes no wire call',
        () async {
      f.secrets.store['state_man_config'] = 'CREDENTIALS';
      f.connect();

      expect(await f.prefs.getString('state_man_config', secret: true),
          'CREDENTIALS');
      expect(f.wire.calls, isEmpty);
    });

    test('a secret is isolated even on a key that is otherwise shared',
        () async {
      f.connect();
      await f.prefs.setString('alarm_man_config', 's', secret: true);
      expect(f.wire.calls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  group('the park / fill / fail contract on an empty slot', () {
    test('a read parks until the client exists, then answers from the backend',
        () async {
      f.wire.store['alarm_man_config'] = 'FRESH';
      var settled = false;
      final pending = f.prefs.getString('alarm_man_config')
        ..whenComplete(() => settled = true);

      await pumpEventQueue();
      // It must not have fallen back to the (empty) local store and answered
      // null — that is the silent failure this class exists to remove.
      expect(settled, isFalse);

      f.connect();
      expect(await pending, 'FRESH');
    });

    test('a write parks and then lands on the backend', () async {
      final pending = f.prefs.setString('alarm_man_config', 'v');
      await pumpEventQueue();
      expect(f.wire.store, isEmpty);

      f.connect();
      await pending;
      expect(f.wire.store['alarm_man_config'], 'v');
      expect(await f.mirror.getString('alarm_man_config'), isNull);
    });

    test('a parked caller is released with the boot error when the gateway '
        'never comes up — it does not hang forever', () async {
      final pending = f.prefs.getString('alarm_man_config');
      await pumpEventQueue();

      f.slot.fail(StateError('gateway is selected but cannot be dialled'));
      await expectLater(pending, throwsA(isA<StateError>()));
    });

    test('a call made after the failure fails immediately rather than parking',
        () async {
      f.slot.fail(StateError('boom'));
      await expectLater(
          f.prefs.getString('alarm_man_config'), throwsA(isA<StateError>()));
    });

    test('a failure is cleared by a later fill — a panel that reconnects is '
        'not poisoned by the boot it failed', () async {
      f.slot.fail(StateError('boom'));
      f.wire.store['alarm_man_config'] = 'FRESH';
      f.connect();
      expect(await f.prefs.getString('alarm_man_config'), 'FRESH');
    });

    test('a downed link surfaces as the error the client threw, never as a '
        'local answer', () async {
      f.connect();
      f.wire.failWith = StateError('LinkDown');
      await expectLater(
          f.prefs.getString('alarm_man_config'), throwsA(isA<StateError>()));
    });
  });

  // ---------------------------------------------------------------------------
  group('the key_mappings bootstrap carve-out', () {
    test('read with an empty slot answers the local mirror — the panel has '
        'to build its client before it has a client to ask', () async {
      await f.mirror.setString('key_mappings', 'MIRROR');
      // The mirror is what a fresh Preferences would have loaded into memory.
      await f.inner.setString('key_mappings', 'MIRROR');

      expect(await f.prefs.getString('key_mappings'), 'MIRROR');
      expect(f.wire.calls, isEmpty);
    });

    test('write with an empty slot stays local — the boot seed of a default '
        "must never become the plant's routing config", () async {
      await f.prefs.setString('key_mappings', 'SEED');
      expect(f.wire.calls, isEmpty);
      expect(await f.mirror.getString('key_mappings'), 'SEED');
    });

    test('read with a filled slot comes from the backend AND is written '
        'through to the mirror, so the next boot starts fresh', () async {
      f.wire.store['key_mappings'] = 'BACKEND';
      f.connect();

      expect(await f.prefs.getString('key_mappings'), 'BACKEND');
      expect(await f.mirror.getString('key_mappings'), 'BACKEND');
    });

    test('write with a filled slot goes to the backend and mirrors', () async {
      f.connect();
      await f.prefs.setString('key_mappings', 'EDITED');

      expect(f.wire.store['key_mappings'], 'EDITED');
      expect(await f.mirror.getString('key_mappings'), 'EDITED');
    });

    test('a backend value of null clears the mirror rather than leaving the '
        'old one to be read as truth at the next boot', () async {
      await f.mirror.setString('key_mappings', 'OLD');
      f.connect();

      expect(await f.prefs.getString('key_mappings'), isNull);
      expect(await f.mirror.getString('key_mappings'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('reconcile on first fill', () {
    setUp(() => f = _Fixture(reconcile: true));

    test('a mirror that went stale while the panel was off is refreshed and '
        'announced, so the existing key_mappings listener reloads', () async {
      await f.mirror.setString('key_mappings', 'OLD');
      await f.inner.setString('key_mappings', 'OLD');
      f.wire.store['key_mappings'] = 'NEW';
      // Seeding the inner store announces the key, and stream delivery is
      // asynchronous — without draining it first, that announcement would
      // arrive after the listener below and this arm would pass on the
      // fixture's own noise rather than on the reconcile.
      await pumpEventQueue();

      final announced = <String>[];
      final sub = f.prefs.onPreferencesChanged.listen(announced.add);
      f.connect();
      await pumpEventQueue();

      expect(await f.mirror.getString('key_mappings'), 'NEW');
      expect(announced, contains('key_mappings'));
      await sub.cancel();
    });

    test('a mirror that already agrees is not announced — a provisioned panel '
        'does not reload every boot', () async {
      await f.mirror.setString('key_mappings', 'SAME');
      await f.inner.setString('key_mappings', 'SAME');
      f.wire.store['key_mappings'] = 'SAME';
      await pumpEventQueue();

      final announced = <String>[];
      final sub = f.prefs.onPreferencesChanged.listen(announced.add);
      f.connect();
      await pumpEventQueue();

      expect(announced, isNot(contains('key_mappings')));
      await sub.cancel();
    });
  });

  // ---------------------------------------------------------------------------
  group('enumeration is the backend, never a union', () {
    test('getAll answers the backend and does not resurrect a stale mirror row',
        () async {
      await f.mirror.setString('alarm_man_config', 'STALE');
      await f.mirror.setString('startup_url', '/mine');
      f.wire.store['alarm_man_config'] = 'FRESH';
      f.connect();

      final all = await f.prefs.getAll();
      expect(all['alarm_man_config'], 'FRESH');
      // A device-local key is not part of the shared surface and must not be
      // enumerated into it — `localPreferencesProvider` owns that store.
      expect(all.containsKey('startup_url'), isFalse);
    });

    test('getKeys is the backend key set', () async {
      await f.mirror.setString('startup_url', '/mine');
      f.wire.store['a'] = 1;
      f.connect();

      expect(await f.prefs.getKeys(), {'a'});
    });

    test('clear forwards to the backend and never touches the local store — '
        'clearing the shared surface must not eat this station\'s settings',
        () async {
      await f.mirror.setString('startup_url', '/mine');
      f.wire.store['a'] = 1;
      f.connect();

      await f.prefs.clear(allowList: {'a'});
      expect(f.wire.calls, contains('clear(allowList: {a})'));
      expect(await f.mirror.getString('startup_url'), '/mine');
    });
  });

  // ---------------------------------------------------------------------------
  group('the members with no honest wire answer', () {
    test('a non-secret saveToDb:false write is refused by name rather than '
        'written somewhere it cannot be read back from', () async {
      f.connect();
      await expectLater(
        f.prefs.setString('alarm_man_config', 'v', saveToDb: false),
        throwsUnsupportedError,
      );
    });

    test('a secret saveToDb:false write is fine — it is the only combination '
        'that occurs, and it goes to the keychain', () async {
      f.connect();
      await f.prefs.setString('state_man_config', 'v',
          saveToDb: false, secret: true);
      expect(f.secrets.store['state_man_config'], 'v');
      expect(f.wire.calls, isEmpty);
    });

    test('isKeyInDatabase asks the backend — the raw preferences editor picks '
        'which store to write from this answer', () async {
      f.wire.store['alarm_man_config'] = 'v';
      f.connect();

      expect(await f.prefs.isKeyInDatabase('alarm_man_config'), isTrue);
      expect(await f.prefs.isKeyInDatabase('nope'), isFalse);
      // A device-local key is not in the backend, which is what routes the
      // editor's write for it to the local store.
      expect(await f.prefs.isKeyInDatabase('startup_url'), isFalse);
    });

    test('database stays null — a gateway panel has no Postgres pool, and a '
        'caller reaching for one must not find one', () {
      expect(f.prefs.database, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('the change stream', () {
    test("carries the backend's notifications", () async {
      f.connect();
      final seen = <String>[];
      final sub = f.prefs.onPreferencesChanged.listen(seen.add);
      await pumpEventQueue();

      f.wire.announce('alarm_man_config');
      await pumpEventQueue();

      expect(seen, contains('alarm_man_config'));
      await sub.cancel();
    });

    test('carries a device-local change too — the same store answers both '
        'halves and a listener cannot be asked to subscribe twice', () async {
      f.connect();
      final seen = <String>[];
      final sub = f.prefs.onPreferencesChanged.listen(seen.add);
      await pumpEventQueue();

      await f.prefs.setString('startup_url', '/mine');
      await pumpEventQueue();

      expect(seen, contains('startup_url'));
      await sub.cancel();
    });

    test('survives the client being replaced — a listener taken before a '
        'reconnect still hears the one taken after', () async {
      f.connect();
      final seen = <String>[];
      final sub = f.prefs.onPreferencesChanged.listen(seen.add);
      await pumpEventQueue();

      f.slot.clear();
      final second = _FakeWire();
      f.slot.fill(second);
      await pumpEventQueue();

      second.announce('alarm_man_config');
      await pumpEventQueue();

      expect(seen, contains('alarm_man_config'));
      await sub.cancel();
      await second.dispose();
    });
  });
}
