/// What `preferencesProvider` serves after the cutover, and what the swap was
/// not allowed to lose.
///
/// The store behind it changed — `flutter_preferences` blobs became
/// `kind='preference'` rows — and the whole point of 04-05 is that no caller
/// noticed. So the assertions here are about the *provider*: that a write and
/// a read still round-trip through it, that a refusal still fails closed and
/// still reaches `onDenied`, and that the app's own boot defaults still land
/// with nobody signed in.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/config/shared_row_preferences.dart';
import 'package:tfc_dart/core/preferences.dart'
    show InMemoryPreferences, Preferences;

import '../helpers/test_helpers.dart';

const String _kStation = 'test-panel';

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingSink sink;
  late List<AccessDenied> denials;
  late InMemoryPreferences deviceStore;

  setUp(() {
    sink = _RecordingSink();
    denials = [];
    deviceStore = InMemoryPreferences();
    // The provider calls `createDeviceLocalPreferences()` for the startup_url
    // clean-up; seeding the singleton is cheaper than opening a file.
    setDeviceLocalPreferencesForTest(deviceStore);
    // And it builds its `Preferences` with `SecureStorage.getInstance()`,
    // which is the machine's keychain unless somebody says otherwise. Every
    // test here reaches that, secret or not.
    useFakeSecureStorage();
  });

  tearDown(() async {
    await resetDeviceLocalPreferencesForTest();
  });

  /// A container whose `preferencesProvider` is the real one, over a
  /// configuration store backed by two in-memory databases.
  ProviderContainer containerFor(AccessSession session) {
    final container = ProviderContainer(overrides: [
      // No Postgres of its own: the shared rows live on the store's stand-in
      // remote, which is where they live in production too.
      databaseProvider.overrideWith((ref) async => null),
      stationNameProvider.overrideWithValue(_kStation),
      configStoreProvider.overrideWith((ref) => createTestConfigStore(
            station: _kStation,
            session: session,
            audit: sink,
            onDenied: denials.add,
          )),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  AccessSession administer() => const AccessSession(
        user: AuthenticatedUser(username: 'jon', roleName: 'Engineer'),
        groups: {
          AccessGroup.operate,
          AccessGroup.configure,
          AccessGroup.setpoints,
          AccessGroup.administer,
        },
      );

  test('the provider serves the row-backed store, not the blob one', () async {
    final container = containerFor(administer());
    final prefs = await container.read(preferencesProvider.future);

    expect(prefs, isA<SharedRowPreferences>());
    // And it is still a `Preferences`, which is the whole reason no caller
    // changed: `secret:`, `saveToDb:`, `onPreferencesChanged` and
    // `isKeyInDatabase` are all still there.
    expect(prefs, isA<Preferences>());
  });

  test('a preference written through the provider reads back through it',
      () async {
    final container = containerFor(administer());
    final prefs = await container.read(preferencesProvider.future);

    await prefs.setString('update_channel', 'beta');
    await prefs.setStringList('kjolur.recipes', ['one', 'two']);

    expect(await prefs.getString('update_channel'), 'beta');
    expect(await prefs.getStringList('kjolur.recipes'), ['one', 'two']);
    expect(await prefs.getKeys(), {'update_channel', 'kjolur.recipes'});
    // One audit row per write, each naming the key that moved.
    expect(sink.rows.map((r) => r.itemKey),
        ['update_channel', 'kjolur.recipes']);
  });

  test('a write the session may not make is refused closed', () async {
    // Operator only. `collector_config` is an `administer` key, so this is the
    // deny path `guarded_preferences.dart:47-51` established, and it has to
    // survive the swap: reads open, writes checked, and the refusal recorded
    // before it is thrown.
    final container =
        containerFor(AccessSession.anonymous(const {AccessGroup.operate}));
    final prefs = await container.read(preferencesProvider.future);

    await expectLater(
      prefs.setString('collector_config', '{}'),
      throwsA(isA<AccessDenied>()),
    );

    expect(await prefs.getString('collector_config'), isNull,
        reason: 'a refused write must leave nothing behind');
    expect(sink.rows.single.allowed, isFalse);
    expect(sink.rows.single.itemKey, 'collector_config');
    expect(denials.single.required, AccessGroup.administer);
  });

  test('a key no rule names requires administer rather than falling open',
      () async {
    final container = containerFor(const AccessSession(
      user: AuthenticatedUser(username: 'sigga', roleName: 'Shift Leader'),
      groups: {AccessGroup.operate, AccessGroup.configure},
    ));
    final prefs = await container.read(preferencesProvider.future);

    await expectLater(
      prefs.setString('a_key_nobody_has_ever_heard_of', 'x'),
      throwsA(isA<AccessDenied>()),
    );
    expect(denials.single.required, AccessGroup.administer);
  });

  test('systemPreferencesProvider still writes with nobody signed in',
      () async {
    // The boot defaults — `alarm_man_config` above all — are written by the
    // app for itself before anybody has signed in. Losing the unchecked arm in
    // the swap would have refused them and brought the station up without its
    // alarm configuration.
    final container =
        containerFor(AccessSession.anonymous(const {AccessGroup.operate}));
    final system = await container.read(systemPreferencesProvider.future);

    await system.setString('alarm_man_config', '{"alarms":[]}');

    final prefs = await container.read(preferencesProvider.future);
    expect(await prefs.getString('alarm_man_config'), '{"alarms":[]}');
    expect(sink.rows.single.origin, 'system');
    expect(sink.rows.single.allowed, isTrue);
    expect(denials, isEmpty);
  });

  test('the unchecked arm is a different object from the checked one',
      () async {
    final container = containerFor(administer());
    final prefs = await container.read(preferencesProvider.future);
    final system = await container.read(systemPreferencesProvider.future);

    expect(identical(prefs, system), isFalse,
        reason: 'if these were one object every write would be unchecked');
  });

  test('a secret is checked and recorded, and still never reaches a row',
      () async {
    final container = containerFor(administer());
    final prefs = await container.read(preferencesProvider.future);

    await prefs.setString('a_secret', 'hunter2', secret: true);

    expect(await prefs.getKeys(), isEmpty);
    expect(await prefs.isKeyInDatabase('a_secret'), isFalse);
    // It is still checked and still recorded — `GuardedPreferences` did both
    // for secrets, and the write that stores a credential is the one that must
    // never fall out of the trail. Neither side of the value is in the row:
    // reading the old one is the single edit that would copy a credential into
    // a permanent, replicated table.
    expect(sink.rows.single.itemKey, 'a_secret');
    expect(sink.rows.single.allowed, isTrue);
    expect(sink.rows.single.oldValue, isNull);
    expect(sink.rows.single.newValue, isNull);
  });
}
