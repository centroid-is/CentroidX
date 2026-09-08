import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc/core/update_channel.dart';
import 'package:tfc_dart/core/config/shared_row_preferences.dart';
import 'package:tfc_dart/core/preferences.dart';

import '../helpers/test_helpers.dart';

void main() {
  // The channel helpers take a `PreferencesApi` rather than the concrete store
  // type, so that the only expression constructing a device-local store lives
  // in `lib/providers/preferences.dart` (spec §6, enforced by
  // `scripts/check-preferences-construction.sh`). That is what lets this
  // fixture be an `InMemoryPreferences`: the `shared_preferences` wrapper it
  // used to be left with milestone v1.2 plan 01-06, and nothing here needs a
  // platform channel to answer a typed map.
  late PreferencesApi prefs;

  setUp(() {
    prefs = InMemoryPreferences();
  });

  test('defaults to stable when nothing is stored', () async {
    expect(await readUpdateChannel(prefs: prefs), updateChannelStable);
  });

  test('round-trips the latest channel', () async {
    await writeUpdateChannel(updateChannelLatest, prefs: prefs);
    expect(await readUpdateChannel(prefs: prefs), updateChannelLatest);

    await writeUpdateChannel(updateChannelStable, prefs: prefs);
    expect(await readUpdateChannel(prefs: prefs), updateChannelStable);
  });

  test('unknown stored value reads as stable', () async {
    await prefs.setString(updateChannelPrefsKey, 'nightly');
    expect(await readUpdateChannel(prefs: prefs), updateChannelStable);
  });

  test('unknown value is normalised to stable on write', () async {
    await writeUpdateChannel('nightly', prefs: prefs);
    expect(await prefs.getString(updateChannelPrefsKey), updateChannelStable);
  });

  // The shared store, once it stopped being `flutter_preferences` (04-05) —
  // proved rather than assumed (04-09 Task 3). The helpers above take a
  // `PreferencesApi` and did not change; what changed underneath them is that
  // a value is now a `kind='preference'` row written through the one guard.
  //
  // Note what production actually does: `readUpdateChannel` and
  // `writeUpdateChannel` default to `createDeviceLocalPreferences()`, so on a
  // station the channel is a *station-scoped* row — deliberately, per the
  // key's own doc ("a dev box on the latest channel must not drag every HMI
  // with it"). This group proves the key also works when it is handed the
  // shared store, which is what the access policy classifies it as and what
  // the preferences editor at `/advanced/preferences` writes it through.
  group('over the shared row store', () {
    late SharedRowPreferences shared;

    setUp(() async {
      final guarded = await createTestConfigStore(
        session: const AccessSession(
          user: AuthenticatedUser(username: 'jon', roleName: 'Engineering'),
          groups: {
            AccessGroup.operate,
            AccessGroup.configure,
            AccessGroup.administer,
          },
        ),
      );
      shared = SharedRowPreferences(
          store: guarded, secureStorage: FakeSecureStorage());
      addTearDown(shared.close);
    });

    test('an unwritten channel reads as stable, not as an error', () async {
      expect(await readUpdateChannel(prefs: shared), updateChannelStable);
    });

    test('round-trips through a row', () async {
      await writeUpdateChannel(updateChannelLatest, prefs: shared);
      expect(await readUpdateChannel(prefs: shared), updateChannelLatest);

      await writeUpdateChannel(updateChannelStable, prefs: shared);
      expect(await readUpdateChannel(prefs: shared), updateChannelStable);
    });

    test('an operator who may not administer is refused', () async {
      final guarded = await createTestConfigStore();
      final asOperator = SharedRowPreferences(
          store: guarded, secureStorage: FakeSecureStorage());
      addTearDown(asOperator.close);

      await expectLater(
        writeUpdateChannel(updateChannelLatest, prefs: asOperator),
        throwsA(isA<AccessDenied>()),
      );
      expect(await readUpdateChannel(prefs: asOperator), updateChannelStable);
    });
  });
}
