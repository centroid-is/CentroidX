/// Finding the live session for a configured server, behind a compile-time
/// seam.
///
/// The Server Config page shows a status chip per configured server, which
/// means reaching the OPC UA session, M2400 socket or Modbus/UMAS socket this
/// process holds for it. The first of those is `dart:ffi`, and none of the
/// three exists in a browser. The card already renders "unknown" for a null,
/// so the web arm simply always returns one — the page stays editable, and
/// only the chip goes quiet.
library;

export 'live_session_status_types.dart';
export 'live_session_status_io.dart'
    if (dart.library.js_interop) 'live_session_status_web.dart';
