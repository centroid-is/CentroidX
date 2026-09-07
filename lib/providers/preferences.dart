import 'dart:io' show Platform;

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../core/device_local_store.dart';
import '../core/startup_url.dart';
import 'access.dart';
import 'access_policy.dart';
import 'database.dart';

part 'preferences.g.dart';

/// Only ever used off the happy path: the boot open and its fallback.
final Logger _logger = Logger();

/// The one device-local database handle, and the store over it.
///
/// Module-private and process-wide. [initDeviceLocalPreferences] assigns both;
/// nothing else may. `_deviceLocalDb` is null when the fallback store is in
/// force, which is also why the two are separate fields rather than one.
AppDatabase? _deviceLocalDb;
PreferencesApi? _deviceLocalStore;

/// Opens this station's device-local configuration store and, once ever,
/// imports whatever `shared_preferences` still holds into it.
///
/// **Call this from `main()` before anything reads a preference.** The earliest
/// read is `PageManager.load()` in `centroid-hmi/lib/main.dart`, before
/// `runApp`; a station that gets there with an unopened or unimported store
/// comes up on the built-in default pages with its own pages gone — and then
/// persists that as its page set.
///
/// Idempotent: a second call is a no-op, so a test that inits twice and a
/// future second entrypoint both behave.
///
/// **It never throws.** A corrupt `config.sqlite`, a read-only data directory
/// or an import that dies halfway is caught here, logged at error level with
/// the directory and the exception named, and answered with an
/// [InMemoryPreferences] singleton. That station comes up on default pages,
/// signed out, and forgets its settings when it closes — which is worse than
/// working and far better than a panel in a fish factory that does not start.
/// The log line is the difference between "degraded" and "haunted": it is the
/// only place the operator's missing pages are explained. Threat T-01-14.
Future<void> initDeviceLocalPreferences() async {
  if (_deviceLocalStore != null) return;

  var directory = '<unresolved>';
  try {
    final dir = await deviceLocalStoreDirectory();
    directory = dir.path;
    final db = AppDatabase.createLocal(dir);
    final store = SqlitePreferences(
      db,
      scope: ConfigScope.forStation(_localHostname()),
    );
    // One shot, marked by a row inside the same transaction as the values it
    // describes. A station that has already imported does no work here.
    final imported = await store.importAll(
      normalizeLegacyKeys(
        await readLegacySharedPreferences(dir, logger: _logger),
        logger: _logger,
      ),
      markerId: sharedPreferencesImportMarkerId,
    );
    if (imported) {
      _logger.i('Imported the legacy shared_preferences store into '
          '${dir.path}/config.sqlite. This happens once per station.');
    }
    _deviceLocalDb = db;
    _deviceLocalStore = store;
  } catch (e, stack) {
    _logger.e(
      'Could not open the device-local configuration store in $directory. '
      'This station is starting with an IN-MEMORY store: it will show the '
      'built-in default pages, nobody is signed in, and nothing it changes '
      'will survive a restart. Fix the store rather than the symptoms.',
      error: e,
      stackTrace: stack,
    );
    _deviceLocalStore = InMemoryPreferences();
  }
}

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
/// Returns **the one store** [initDeviceLocalPreferences] opened, not a fresh
/// one. It used to hand back a new wrapper each call, which was free because
/// the wrapper held no state and the values lived on a platform channel behind
/// it. Behind the wrapper there is now an `AppDatabase`, and a fresh one of
/// those is a background isolate and a file handle — per colour pick, at
/// `color_picker_dialog.dart:46,70`. The wrapper is still free; the handle is
/// not, so there is exactly one.
///
/// Throws a [StateError] when init has not run. Not a lazy open — that would
/// need this to be async, and every caller reaches it from a synchronous
/// context — and not a silent empty store, which is precisely the failure
/// ("the station lost its pages") the boot ordering exists to prevent.
PreferencesApi createDeviceLocalPreferences() {
  final store = _deviceLocalStore;
  if (store == null) {
    throw StateError(
      'initDeviceLocalPreferences() must run before '
      'createDeviceLocalPreferences(). In the app it is awaited in main() '
      'before runApp; in a test, call setDeviceLocalPreferencesForTest() in '
      'setUp (and resetDeviceLocalPreferencesForTest() in tearDown).',
    );
  }
  return store;
}

/// This station's hostname, for the scope every row is written at.
///
/// `'unknown'` rather than a throw if the platform will not say, matching
/// `stationNameProvider`: a nameless station still has preferences, and a
/// store under a vague scope beats no store at all.
String _localHostname() {
  try {
    return Platform.localHostname;
  } on Object catch (e) {
    _logger.w('Could not read the local hostname for the config scope: $e');
    return 'unknown';
  }
}

/// Seeds the process-wide store without opening a database.
///
/// For tests that build widgets reaching [createDeviceLocalPreferences] — a
/// colour picker, the tech-doc library section — without running boot. Pass
/// null to clear.
@visibleForTesting
void setDeviceLocalPreferencesForTest(PreferencesApi? store) {
  _deviceLocalStore = store;
}

/// Closes the handle, if there is one, and clears the singleton.
///
/// Production never calls this: a process-wide store has no natural owner to
/// close it and lives as long as the app. Tests do, so that a suite does not
/// leak one drift background isolate per test file.
@visibleForTesting
Future<void> resetDeviceLocalPreferencesForTest() async {
  final db = _deviceLocalDb;
  _deviceLocalDb = null;
  _deviceLocalStore = null;
  await db?.close();
}

/// The shared configuration store, **guarded**.
///
/// Every caller in the app already reads this provider, so wrapping the value
/// here is what puts a check and an audit row on every configuration write in
/// the app without changing a single call site.
@Riverpod(keepAlive: true)
Future<Preferences> preferences(Ref ref) async {
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
Future<Preferences> systemPreferences(Ref ref) async {
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
