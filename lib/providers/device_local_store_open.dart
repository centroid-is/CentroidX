/// Opening this machine's own configuration store — the platform half of
/// `initDeviceLocalPreferences()`.
///
/// ## Why it is behind a seam
///
/// On a station the device-local store is `config.sqlite`: a drift database
/// in the application-support directory, opened through
/// `package:drift/native` and imported once from the `shared_preferences`
/// file that preceded it. A browser has none of that — no directory, no file,
/// no SQLite — and `sqlite_executor_web.dart` refuses every executor by name.
///
/// Before this seam existed the web entrypoint did not open a store at all.
/// Every `localPreferencesProvider` read then threw the `StateError` that
/// `createDeviceLocalPreferences` reserves for "init has not run"; every
/// provider downstream of it — the transport row, the session, the plant
/// pages — held that throw as an `AsyncError`; the home route rendered the
/// blank it renders when there are no pages; and nothing reached the console,
/// because Riverpod holds a provider's error rather than reporting it. A
/// white screen with an empty console, and no socket ever dialled, because the
/// transport row could not be read.
///
/// So the web arm opens the browser's own per-origin store instead
/// (`shared_preferences` on `localStorage`) — what `docs/web-client-scope.md`
/// already relied on for sign-in — and the station arm is the SQLite open it
/// always was. Both answer the same [DeviceLocalStoreHandle]. The difference
/// between them is [kHasDeviceLocalMirror]: whether a `ConfigStore`, the
/// mirror of the plant's `config_item` rows, can exist on this platform. It
/// is a drift database, so it cannot in a browser, and `stateManProvider` and
/// `pageManagerProvider` branch on the constant rather than on a throw.
///
/// In `lib/providers/` rather than `lib/core/` on purpose:
/// `scripts/check-preferences-construction.sh` allows a preferences store to
/// be constructed in this directory and nowhere else, and both arms construct
/// one.
library;

export 'device_local_store_open_io.dart'
    if (dart.library.js_interop) 'device_local_store_open_web.dart';
