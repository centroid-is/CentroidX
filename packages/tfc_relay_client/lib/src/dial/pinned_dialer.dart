/// Opening the socket — the one thing in this package that a browser and a
/// panel genuinely cannot do the same way.
///
/// Everything else here is platform-free: the backoff, the deadlines, the
/// clock offset, the freshness watchdog, the resync discipline, hold-to-run,
/// the failure taxonomy. Only the dial needs `dart:io`, and only for two
/// reasons — a `SecurityContext` carrying the plant's private CA, and
/// `IOWebSocketChannel.connect`'s `customClient:` to hand it over. Both are
/// meaningless in a browser, which owns its own trust store and offers no API
/// to add a root to it.
///
/// So the dial lives behind this seam and the rest of the package does not
/// know which side it is on. The web arm is not a stub: it opens a real
/// WebSocket. What it cannot do is *pin*, and it says so rather than
/// pretending — see `pinned_dialer_web.dart`.
library;

export 'pinned_dialer_io.dart'
    if (dart.library.js_interop) 'pinned_dialer_web.dart';
