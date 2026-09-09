/// Building the *direct* transport — the panel's own OPC UA, Modbus and M2400
/// sessions, plus the collector that historises them.
///
/// **Why it is behind a seam.** Direct mode is a panel holding sessions to the
/// plant itself. That needs `package:open62541`, which is `dart:ffi`, and a
/// browser has neither. It is not a feature a web build is missing — it is a
/// thing a browser cannot be: the whole premise of gateway mode is that one
/// process holds the plant and everything else is a client of it, and a
/// browser is only ever the second kind.
///
/// So the direct branch of `stateManProvider` lives in `direct_transport_io.dart`
/// and the web arm refuses by name. Nothing is stubbed: a web build does not
/// contain an OPC UA client at all, which is what makes it build.
library;

export 'direct_transport_io.dart'
    if (dart.library.js_interop) 'direct_transport_web.dart';
