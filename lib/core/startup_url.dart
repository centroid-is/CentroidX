import 'package:tfc_dart/core/preferences_api.dart';

import '../models/menu_item.dart';

/// SharedPreferences key holding the URL the app opens on at startup. Local
/// to the machine on purpose — stations sharing one database front different
/// equipment, so each picks its own startup page (in the page editor's Pages
/// dialog) without dragging the others along.
const String startupUrlPrefsKey = 'startup_url';

/// Where the app starts when no startup URL has been chosen.
const String startupUrlDefault = '/';

/// Reads the persisted startup URL; absent or empty counts as
/// [startupUrlDefault].
Future<String> readStartupUrl(PreferencesApi prefs) async {
  final stored = await prefs.getString(startupUrlPrefsKey);
  if (stored == null || stored.isEmpty) return startupUrlDefault;
  return stored;
}

/// Persists the startup URL. The default clears the key instead of storing
/// it, so a reset station is indistinguishable from a fresh install.
Future<void> writeStartupUrl(PreferencesApi prefs, String url) async {
  if (url == startupUrlDefault) {
    await prefs.remove(startupUrlPrefsKey);
  } else {
    await prefs.setString(startupUrlPrefsKey, url);
  }
}

/// Deletes a stray `startup_url` row from the shared database-backed
/// preferences, keeping whatever the device-local store holds.
///
/// The startup URL is per-station and only ever written device-locally — but
/// the database sync copies every row it holds over the local store on every
/// boot and reconnect, so a row that lands in `flutter_preferences` by any
/// route (tooling writing prefs directly, a future code path using the wrong
/// provider) silently overwrites the station's choice from then on. Same
/// failure class, and same cure, as the MCP config's
/// `migrateMcpConfigToDeviceLocal`.
///
/// [shared] removes mirror into the same physical store as [local], so the
/// local value is captured first and re-written after. Idempotent — safe to
/// run on every database (re)connect.
Future<void> migrateStartupUrlToDeviceLocal({
  required PreferencesApi shared,
  required PreferencesApi local,
}) async {
  final sharedValue = await shared.getString(startupUrlPrefsKey);
  if (sharedValue == null) return;
  final localValue = await local.getString(startupUrlPrefsKey);
  await shared.remove(startupUrlPrefsKey);
  if (localValue != null) {
    await local.setString(startupUrlPrefsKey, localValue);
  }
}

/// The startup URL the app should actually open — [stored] when the menu can
/// still route it, [startupUrlDefault] otherwise.
///
/// One validation for both users of the answer: boot (`main.dart`) and the
/// sign-out return (`BaseScaffold`). A startup page deleted or unpublished
/// since it was picked must fall back identically in both places, or signing
/// out would land somewhere booting does not.
String resolveStartupPath(String stored, {required List<MenuItem> menuItems}) {
  if (stored == startupUrlDefault) return startupUrlDefault;
  return _menuHasRoutablePath(menuItems, stored) ? stored : startupUrlDefault;
}

bool _menuHasRoutablePath(List<MenuItem> items, String path) {
  for (final item in items) {
    if (item.path == path && !item.isNavigationSection) return true;
    if (_menuHasRoutablePath(item.children, path)) return true;
  }
  return false;
}
