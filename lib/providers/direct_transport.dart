/// Building the panel's own plant sessions — OPC UA, Modbus/UMAS and M2400 —
/// plus the collector that historises them.
///
/// **Why it is behind a seam.** Holding those sessions needs
/// `package:open62541`, which is `dart:ffi`, and a browser has no equivalent.
/// It is not a feature a web build is merely missing: a page in a browser
/// cannot open a socket to a PLC, so "direct mode in a browser" is not a
/// configuration that could be made to work.
///
/// So the session-building branch of `stateManProvider` lives in
/// `direct_transport_io.dart` and the web arm refuses by name. Nothing is
/// stubbed: a web build does not contain an OPC UA client at all, which is
/// what makes it compile.
library;

export 'direct_transport_io.dart'
    if (dart.library.js_interop) 'direct_transport_web.dart';
