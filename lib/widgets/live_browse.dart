/// The live-server browse and probe dialogs, behind a compile-time seam.
///
/// These dialogs talk to a live session — OPC UA through `package:open62541`,
/// which is `dart:ffi`, and UMAS through a Modbus adapter that names the OPC UA
/// StateMan. Neither can be compiled by dart2js at all. It is reached from
/// the key-mapping editor, which every HMI asset's configure form uses — so
/// this one dialog kept the whole page editor off the web.
///
/// The seam is narrower than the dialog: the caller wants a [NodeId] and
/// nothing else, and [NodeId] is in the FFI-free barrel. Returning the browse
/// result itself would have put an FFI type in the signature and defeated the
/// split.
library;

export 'live_browse_io.dart'
    if (dart.library.js_interop) 'live_browse_web.dart';
