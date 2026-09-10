/// What the page editor needs from the chat stack, behind a compile-time seam.
///
/// `kChatEnabled` already gates chat at runtime, but a `bool.fromEnvironment`
/// cannot help here: dart2js still has to *compile* every imported library
/// before it can drop the dead branch, and `providers/chat.dart` reaches
/// `mcp_dart`, which has no web implementation at all. So the choice has to be
/// made at import time.
///
/// The web arm is deliberately inert rather than absent — the editor's call
/// sites stay as they are, and the menus simply have nothing in them. See
/// `docs/web-client-scope.md`: MCP is off in the browser, and chat with it.
library;

export 'editor_ai_io.dart'
    if (dart.library.js_interop) 'editor_ai_web.dart';
