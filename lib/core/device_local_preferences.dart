/// Which preference keys belong to **this station** and must never be read
/// from or written to the shared backend store.
///
/// ## Why this file exists now
///
/// Before gateway mode relayed its preferences, the boundary did not have to
/// be written down: a gateway panel's "shared" store *was* its device-local
/// mirror, so every key was device-local whether it meant to be or not. That
/// was the bug — an alarm rule edited on one panel never reached the plant.
/// Fixing it points the shared store at the backend, and the moment it is
/// pointed there, a key that is per-station **on purpose** becomes a key one
/// station can use to re-point every other station. So the boundary that used
/// to be implicit has to become a list, and the list has to be enforced.
///
/// ## The rule, and why the default is "shared"
///
/// A key is device-local **only by being named here**. Everything else is
/// shared. That direction is deliberate and it is the opposite of the usual
/// fail-closed instinct: the failure this file guards is a *shared* key going
/// device-local, which is the silent-divergence bug being fixed, and a
/// forgotten entry here is loud (a station's own setting starts travelling and
/// somebody notices immediately) where a forgotten entry the other way is
/// silent forever.
///
/// ## Why it is a list and not `localPreferencesProvider`'s call sites
///
/// Every key below is *already* reached through `localPreferencesProvider` (or
/// through raw `SharedPreferences`, for the three that predate it) rather than
/// through the shared store, so in normal operation nothing here is ever asked
/// of `RelayedPreferences` at all. This list is the second line: it makes the
/// property hold for a caller that reaches for the wrong store — the raw
/// preferences editor in `lib/widgets/preferences.dart` being the one that can
/// reach *any* key by name — instead of holding only for as long as every
/// call site stays correct.
///
/// ## Not here, because it was never a preference
///
/// `database_config` is per-station too — stations reach Postgres at different
/// IPs and syncing that has broken stations before — but it lives in OS secure
/// storage (`packages/tfc_dart/lib/core/database.dart:138`), not in
/// `flutter_preferences`, so no routing decision can reach it. Secrets in
/// general are the same case: they go to the keychain, the wire has no
/// `secret` parameter at all (SEC-01), and `RelayedPreferences` sends them to
/// the local keychain path before it ever consults this file.
library;

import 'gateway_config.dart';
import 'startup_url.dart';
import 'system_clock.dart';
import 'update_channel.dart';

/// Key *prefixes* that are device-local, for the two families whose members
/// are not a fixed list.
///
/// A prefix rather than the individual keys because both families grow: an
/// `access.` setting added next month is per-station for the same reason the
/// three current ones are, and the MCP toggles are generated per tool name.
/// Kept disjoint from [kDeviceLocalPreferenceKeys] — a key covered twice is
/// one of the two places nobody remembers to update — which the test pins.
final Set<String> kDeviceLocalPreferencePrefixes = Set.unmodifiable({
  // `access.session` holds the signed-in session itself, and the two
  // inactivity settings sit beside it. A shared session row would be one
  // station holding another station's sign-in — and the session must be
  // readable *without* a session, which the backend route cannot promise.
  'access.',
  // The MCP server runs on this machine and binds this machine's port.
  // `mcp.config` is the current spelling; `mcp_` catches the legacy
  // `mcp_server_enabled` / `mcp_server_port` / `mcp_tools_*_enabled` keys,
  // which `migrateMcpConfigToDeviceLocal` still folds in.
  'mcp.',
  'mcp_',
});

/// The individually-named device-local keys, each with the reason it is one.
///
/// Spelled from the constants where a constant exists, so that renaming a key
/// moves this set with it rather than leaving a stale literal behind.
final Set<String> kDeviceLocalPreferenceKeys = Set.unmodifiable({
  // The transport config itself, and the one entry that is *structurally*
  // required rather than merely correct: a panel reads this to find out which
  // backend to ask, so it cannot be a thing the backend answers.
  GatewayConfig.prefsKey,
  // A shared `startup_url` row overwrites every station's own choice on each
  // sync — the bug #354 fixed, and `preferences.dart` still deletes such a row
  // on sight in direct mode.
  startupUrlPrefsKey,
  // Stations are moved to a prerelease build one at a time, on purpose; a
  // shared value would move the whole plant at once.
  updateChannelPrefsKey,
  // Applied at boot, before any gateway link exists — a station that could
  // only learn its time source from the backend could not set its clock while
  // the backend was unreachable.
  ntpServersPrefsKey,
  // The look of one screen. A panel in a wet room and an office desktop do not
  // share a theme, and these are written through raw `SharedPreferences`
  // (`lib/providers/theme.dart`) rather than either store, so a caller that
  // routed them to the backend would be creating a second, disagreeing home
  // for a value the theme provider will never read.
  'theme_mode',
  'color_scheme',
  // Which asset stack this screen has open, and this screen's recent colour
  // swatches: per-screen working state, read through `localPreferencesProvider`
  // at `lib/pages/page_view.dart` and `lib/widgets/panes/color_picker_dialog.dart`.
  'asset_stack_config',
  'color_picker_recent_colors',
  // The dbus login fields (`lib/pages/dbus_login.dart`): they name a host this
  // particular machine logs into. The names are generic enough to collide with
  // a future shared key — if one is ever added, it must be renamed rather than
  // removed from here, because these five are what the login page reads.
  'connectionType',
  'host',
  'username',
  'autoLogin',
  'sshPrivateKeyPath',
});

/// True when [key] is this station's own setting and must not travel.
///
/// The one predicate; `RelayedPreferences` consults it on every member, and
/// nothing else in the app should need to — a caller that already knows a key
/// is per-station should be reading `localPreferencesProvider` by name.
bool isDeviceLocalPreferenceKey(String key) {
  if (kDeviceLocalPreferenceKeys.contains(key)) return true;
  for (final prefix in kDeviceLocalPreferencePrefixes) {
    if (key.startsWith(prefix)) return true;
  }
  return false;
}
