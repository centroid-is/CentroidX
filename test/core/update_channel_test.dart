import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/update_channel.dart';
import 'package:tfc_dart/core/preferences.dart';

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
}
