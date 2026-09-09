import 'package:shared_preferences/shared_preferences.dart';
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../core/gateway_config.dart';
import '../core/preferences.dart';
import '../core/relayed_preferences.dart';
import '../core/startup_url.dart';
import 'access.dart';
import 'access_policy.dart';
import 'database.dart';
import 'gateway.dart';
import 'relay_client.dart';

part 'preferences.g.dart';

/// The one place a device-local preferences store is constructed.
///
/// Spec §6 asks for this: a feature that news up its own store writes past
/// both guards and the type system will not object.
/// `scripts/check-preferences-construction.sh` fails the build for a
/// construction anywhere else. Where a `ref` is available, read
/// [localPreferencesProvider] instead of calling this — the two answer the
/// same physical store, but the provider is overridable in a test and this is
/// not.
///
/// Returns a fresh wrapper each call. That is safe because the wrapper holds
/// no state of its own; the values live on the platform channel behind it.
PreferencesApi createDeviceLocalPreferences() =>
    SharedPreferencesWrapper(SharedPreferencesAsync());

/// The shared configuration store, **guarded**.
///
/// Every caller in the app already reads this provider, so wrapping the value
/// here is what puts a check and an audit row on every configuration write in
/// the app without changing a single call site.
@Riverpod(keepAlive: true)
Future<PreferencesApi> preferences(Ref ref) async {
  // The transport branch, and it must sit HERE, not merely inside
  // `databaseProvider`: this provider is `keepAlive` and watched by
  // everything, so a watch on `databaseProvider` is what used to pull the
  // station's Postgres pool up at boot in gateway mode with no screen asking.
  // In gateway mode the dependency does not exist — not "exists but answers
  // null" — which is what `database_transport_test.dart` pins by overriding
  // `databaseProvider` to throw and building this provider anyway (17-12's
  // technique). The shared store then runs on the device-local mirror the
  // sync path already maintains.
  //
  // `ref.read` on the transport for the reason `database.dart` gives at its
  // own branch: restart-to-apply, and a save on the server-config page
  // invalidates `gatewayConfigProvider` without meaning to rebuild the world.
  // The catch is `readGatewayConfig`'s own policy — direct in every direction.
  GatewayConfig gateway;
  try {
    gateway = await ref.read(gatewayConfigProvider.future);
  } catch (_) {
    gateway = GatewayConfig.defaults;
  }

  // Gateway mode: the shared store IS the gateway's, read and written over the
  // same socket the values come down. Not a local mirror of it — the mirror is
  // only ever filled by a direct-mode run, so a station that has only ever run
  // in gateway mode (and every browser, every time) would boot with no key
  // mappings and no pages.
  //
  // Nothing is guarded on this side. `GuardedPreferences` puts a check and an
  // audit row in front of every write on a direct station because that station
  // is talking to its own database and nothing else would. Over the relay the
  // gateway does it — it refuses on the far side and writes the audit row
  // against the station's verified account — and a second check here would be
  // a client asking itself for permission.
  if (gateway.isGateway) {
    final client = await ref.watch(relayClientProvider.future);
    if (client == null) {
      throw StateError('Gateway mode is selected but no relay client was '
          'built. relayClientProvider answers null only outside gateway mode, '
          'so this is a wiring fault and not a configuration one.');
    }
    return RelayedPreferences(client.preferences);
  }

  final db = await ref.watch(databaseProvider.future);
  final localCache = createDeviceLocalPreferences();

  final inner = await Preferences.create(db: db, localCache: localCache);

  final guarded = GuardedPreferences(
    inner: inner,
    policy: ref.watch(accessPolicyProvider),
    // A callback, and never a watch on the session provider: a watch would
    // rebuild this provider — and every provider downstream of it, including
    // the plant connection — on every sign-in, sign-out and inactivity
    // timeout. Pinned by `guard_wiring_test.dart`'s "the session is a
    // callback, not a watch" group, which greps this file for that mistake.
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.watch(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );

  // A startup_url row in the shared database would overwrite every station's
  // local choice on each sync; delete it the moment it is seen. Runs on every
  // (re)connect because this provider is rebuilt then — idempotent.
  //
  // Through `systemWrites`, not the checked path: this is the app deleting a
  // row on its own behalf at boot, with nobody signed in, so a session check
  // would refuse it and the per-station startup page would silently stop
  // working again — the exact bug #354 fixed. It still produces one audit row,
  // marked `origin: 'system'`, which is how the mcp.config migration is
  // recorded too.
  await migrateStartupUrlToDeviceLocal(
    shared: guarded.systemWrites,
    local: localCache,
  );

  return guarded;
}

/// The unchecked write path, for the defaults the app writes for itself.
///
/// **This is not "writes we want to allow".** It is "writes the app makes on
/// its own behalf when nobody has acted" — a config default written because
/// storage is empty. A Save button never qualifies, however inconvenient its
/// denial is; the fix for a legitimate operator write being refused is a rule
/// in `kPrefAccessRules`, not a call to this provider.
///
/// Every write through it still produces one audit row, marked `origin:
/// 'system'`. The set of files that may read this provider is capped by
/// [kSystemWriteCallSites] and by a test that compares that constant against
/// the source in both directions.
///
/// Falls back to the guarded object when `preferencesProvider` has been
/// overridden with something that is not a [GuardedPreferences], which is what
/// a test that overrides the store gets. A cast would turn that into a crash
/// in every such test for no gain.
@Riverpod(keepAlive: true)
Future<PreferencesApi> systemPreferences(Ref ref) async {
  final prefs = await ref.watch(preferencesProvider.future);
  return prefs is GuardedPreferences ? prefs.systemWrites : prefs;
}

/// Device-local preferences that never touch the shared database.
///
/// Use this for per-station settings (e.g. the MCP server config) that
/// must not be shared between HMI instances pointed at the same Postgres.
///
/// **Deliberately unguarded, and it must stay that way.** The session itself
/// is stored through here (`access.dart`'s `_persist`), so putting a check in
/// front of it would need a session to read the session.
/// Built from [createDeviceLocalPreferences] rather than constructing its own,
/// so the provider and the factory cannot answer different stores.
final localPreferencesProvider = Provider<PreferencesApi>(
  (ref) => createDeviceLocalPreferences(),
);
