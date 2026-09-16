/// The page a session opens on.
///
/// Every account has one — `app_user.home_page`, set on the access page — and
/// the reserved anonymous account's is where a logged-out panel opens. It
/// replaced the per-station `startup_url` preference: the page somebody works
/// from belongs to them, not to whichever panel they are standing at. A panel
/// that must open somewhere of its own does it through its station account,
/// whose home page is the panel's.
library;

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/preferences.dart';

import '../models/menu_item.dart';

/// Where a session opens when its account names no page, or names one that
/// cannot be routed.
const String homePageDefault = '/';

/// The device-local key the retired per-station startup page lived under.
///
/// Named only so [dropRetiredStartupUrl] can remove it, and say what it held.
const String kRetiredStartupUrlPrefKey = 'startup_url';

/// The path a session should actually open — [stored] when the menu can
/// still route it, [homePageDefault] otherwise.
///
/// One validation for every caller: boot, sign-in and the sign-out return. A
/// home page deleted, renamed or unpublished since it was chosen — or not yet
/// synced to this station — must fall back identically everywhere, or signing
/// out would land somewhere booting does not.
String resolveHomePath(String? stored, {required List<MenuItem> menuItems}) {
  if (stored == null || stored.isEmpty || stored == homePageDefault) {
    return homePageDefault;
  }
  return _menuHasRoutablePath(menuItems, stored) ? stored : homePageDefault;
}

bool _menuHasRoutablePath(List<MenuItem> items, String path) {
  for (final item in items) {
    if (item.path == path && !item.isNavigationSection) return true;
    if (_menuHasRoutablePath(item.children, path)) return true;
  }
  return false;
}

/// Removes the retired per-station `startup_url` from [local], logging what
/// it held so a station that relied on it can be moved onto an account.
///
/// Never throws: a key that cannot be removed costs a stale entry, not a boot.
Future<void> dropRetiredStartupUrl(PreferencesApi local, {Logger? logger}) async {
  final log = logger ?? Logger();
  try {
    final value = await local.getString(kRetiredStartupUrlPrefKey);
    if (value == null) return;
    await local.remove(kRetiredStartupUrlPrefKey);
    if (value.isEmpty || value == homePageDefault) return;
    log.w(
      'Removed the retired per-station startup page "$value". Home pages are '
      'per account now (Advanced > Access): set it on the anonymous account '
      'for logged-out panels, or on this panel\'s station account.',
    );
  } on Object catch (e) {
    log.w('Could not remove the retired setting '
        '"$kRetiredStartupUrlPrefKey": $e');
  }
}
