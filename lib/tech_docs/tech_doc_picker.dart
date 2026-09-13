/// The tech-document picker, behind a compile-time seam.
///
/// The real picker reads the document index out of `tfc_mcp_server`, which
/// imports `mcp_dart` and `drift/native.dart` — neither compiles for the
/// browser. The knowledge base is not part of the web client's scope
/// (`docs/web-client-scope.md`), so the web arm renders a disabled field that
/// says so rather than an empty dropdown that looks like a plant with no
/// drawings in it.
library;

export 'tech_doc_picker_io.dart'
    if (dart.library.js_interop) 'tech_doc_picker_web.dart';
