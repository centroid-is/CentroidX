/// What transport a client uses when nothing has told it otherwise.
///
/// On a station this is [TransportMode.direct] and always has been: a panel
/// that has never been configured runs exactly as it does today, and an absent
/// or corrupt preferences row must not silently re-point it at a gateway it was
/// never pointed at.
///
/// In a browser that default is not merely wrong, it is impossible. A page
/// cannot open an OPC UA session, a Modbus socket or a Postgres pool, so
/// `direct` is the one mode a web build can never satisfy —
/// `direct_transport_web.dart` exists to say so out loud. A fresh tab has no
/// preferences row, so without this seam every web client booted into the one
/// configuration it cannot have and threw before any screen could ask for a
/// different one.
library;

export 'gateway_default_io.dart'
    if (dart.library.js_interop) 'gateway_default_web.dart';
