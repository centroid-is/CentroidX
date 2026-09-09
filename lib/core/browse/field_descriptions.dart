/// Human-readable names and descriptions for the members of a structured key,
/// read off the OPC UA server by browsing it.
///
/// This is *enrichment*: the Schneider parameter pane renders the same struct
/// with or without it, and only the labels change. That is exactly why it is
/// behind a seam. Browsing needs a live OPC UA session, and there is no
/// session on a station in gateway mode and none at all in a browser — so on
/// those the honest answer is "no extra labels", not a crash and not an empty
/// pane.
///
/// The implementation is chosen at compile time: `field_descriptions_io.dart`
/// browses, `field_descriptions_web.dart` returns nothing. A web build must
/// never even see the OPC UA one — it names `ClientWrapper`, which is
/// `dart:ffi`.
library;

export 'field_descriptions_io.dart'
    if (dart.library.js_interop) 'field_descriptions_web.dart';
