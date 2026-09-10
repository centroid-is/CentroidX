/// Finding the live session for a configured server, behind a compile-time
/// seam.
///
/// The Server Config page shows a status chip per configured server, which
/// means reaching the OPC UA session or M2400 adapter this process holds for
/// it. Those are `dart:ffi` and a socket respectively, and neither exists in a
/// browser — nor on a station in gateway mode, where the gateway holds them
/// all. The card already renders "unknown" for a null, so the web arm simply
/// always returns one.
library;

export 'live_session_status_types.dart';
export 'live_session_status_io.dart'
    if (dart.library.js_interop) 'live_session_status_web.dart';
