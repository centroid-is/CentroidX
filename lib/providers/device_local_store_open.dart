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

import 'device_local_store_open_io.dart'
    if (dart.library.js_interop) 'device_local_store_open_web.dart';

export 'device_local_store_open_io.dart'
    if (dart.library.js_interop) 'device_local_store_open_web.dart';

/// Whether the plant's `page`, `asset` and `key_mapping` rows reach this
/// client **over the relay** rather than out of a local mirror.
///
/// [kHasDeviceLocalMirror] answers a narrower question than the call sites
/// were using it for: whether a `ConfigStore` *can exist* on this platform.
/// That is a property of the build, and it is not the same question as where
/// the rows actually come from — because a **station** build can be pointed
/// at a gateway, and then it has a mirror that nothing fills.
///
/// `configStoreProvider` attaches no remote when `databaseProvider` answers
/// null, which it does by design on a relayed panel: a gateway client must
/// not hold a second connection to the plant's Postgres. So the mirror is
/// frozen at whatever it held when the panel was last direct — which on a
/// panel that has never been direct is nothing at all. Reading pages from it
/// shows the operator a plant that does not exist, and the key mappings the
/// client dials with come from the same stale place.
///
/// A relayed panel therefore reads the rows the way a browser does. That is
/// not a compromise: a relayed panel has no plant at all when the link is
/// down, so an offline mirror of the plant's pages buys nothing except a
/// stale one. What the mirror still owns on such a panel is this station's
/// own scope — the watermark and its device-local rows — which is why the
/// store is still built rather than skipped.
///
/// A plain function over the already-resolved config, not a provider: every
/// call site has the gateway config in hand, and a provider here would add a
/// rebuild edge to `stateManProvider`, which is the one place a rebuild costs
/// the plant its subscriptions.
bool configRowsComeOverTheWire({required bool isGateway}) =>
    !kHasDeviceLocalMirror || isGateway;
