/// The live-server browse and probe helpers, behind a compile-time seam.
///
/// Both talk to an OPC UA session through `package:open62541`, which is
/// `dart:ffi` and which dart2js cannot compile at all. They are reached from
/// the key-mapping editor, which every HMI asset's configure form uses — so
/// this one dialog kept the whole page editor off the web.
///
/// The seam is narrower than the dialog on purpose: the caller wants a
/// [NodeId] and nothing else, and [NodeId] is in the FFI-free barrel.
/// Returning the browse result itself would have put an FFI type in the
/// signature and defeated the split.
///
/// `umas_browse.dart` is deliberately *not* here. It reaches its Modbus
/// adapter through `StateMan.deviceClients`, which is on the interface, so it
/// compiles for the web unchanged and simply finds no adapter.
library;

export 'live_browse_io.dart'
    if (dart.library.js_interop) 'live_browse_web.dart';
