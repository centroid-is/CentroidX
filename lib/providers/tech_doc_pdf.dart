/// The one tech-document provider an HMI asset needs, behind a compile-time
/// seam.
///
/// `drawing_viewer.dart` is in the asset registry, so every page that can hold
/// a drawing reaches it — and through `providers/tech_doc.dart` it reached the
/// whole knowledge base, which is `tfc_mcp_server` and so `mcp_dart` and
/// `drift/native.dart`. One provider out of a file of twenty was the entire
/// dependency.
library;

export 'tech_doc_pdf_io.dart'
    if (dart.library.js_interop) 'tech_doc_pdf_web.dart';
