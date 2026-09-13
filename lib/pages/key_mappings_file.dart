/// Getting the key-mapping JSON out of and back into the app, behind a
/// compile-time seam.
///
/// The two halves of the Key Repository's export/import are the only parts of
/// that page that touch a filesystem, and they touch it in the one way a
/// browser cannot follow: `Platform.isWindows` *throws* under dart2js rather
/// than answering false, so the export button's first line was an
/// `UnsupportedError` on web. Everything else on the page — the mappings
/// themselves — is plant configuration that already travels over the socket.
///
/// The web arm is not a refusal. A browser has a perfectly good way to hand a
/// file to a person and to take one back; it is just not `dart:io`. So export
/// becomes a download and import becomes the file chooser the browser already
/// shows, and the page's two buttons keep meaning what they say.
library;

export 'key_mappings_file_io.dart'
    if (dart.library.js_interop) 'key_mappings_file_web.dart';
