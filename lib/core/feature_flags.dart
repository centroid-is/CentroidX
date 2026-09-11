/// Compile-time feature flags.
///
/// Each flag is a `const` read from a `--dart-define`, so a disabled
/// feature's code is tree-shaken out of the built binary entirely. Defaults
/// are `true` so development builds and the test suite exercise every
/// feature; deployment builds opt out explicitly, e.g.:
///
///     flutter build linux --dart-define=CENTROIDX_CHAT=false
library;

/// Whether the in-app AI chat is compiled into the app: the chat overlay
/// and FAB, the LLM providers (Claude/OpenAI/Gemini), the AI context menus,
/// and the in-process MCP client that serves them.
///
/// The MCP SSE server and the proposal review UI are deliberately NOT gated
/// by this flag — external MCP agents and operator proposal approval keep
/// working when chat is off.
const bool kChatEnabled = bool.fromEnvironment('CENTROIDX_CHAT', defaultValue: true);

/// Whether the knowledge features are compiled into the app: the Knowledge
/// Base page (tech-doc library + PLC code browsing), the drawings overlay,
/// the DrawingViewer page asset's palette entry, and the tech-doc picker in
/// the page editor.
///
/// Deliberately NOT gated: the `DrawingViewerConfig` JSON deserializer (a
/// flag-off build must round-trip saved pages without silently dropping the
/// asset), the `techDocId`/`plcAssetKey` fields on `BaseAsset` (stable
/// serialization contract in both build modes), and the database schema and
/// MCP-side indexes, which other MCP tools keep using. Note that `pdfrx` is
/// a native plugin registered from the pubspec, so its native library still
/// ships in flag-off builds — only the Dart code is tree-shaken.
const bool kKnowledgeEnabled =
    bool.fromEnvironment('CENTROIDX_KNOWLEDGE', defaultValue: true);

/// Whether the Web page asset is compiled into the app: [WebViewAssetView],
/// its WKWebView surface, and its entry in the page-editor palette.
///
/// Off in deployment builds. The asset only works where `webview_flutter`
/// has an implementation — macOS — so on the eLinux stations, Linux desktop
/// and Windows it can never be more than a placeholder, and an asset nobody
/// can use does not belong in the palette on those builds.
///
/// Deliberately NOT gated: the `WebViewAssetConfig` JSON deserializer. A
/// flag-off build must round-trip a saved page without silently dropping the
/// asset — the same contract `kKnowledgeEnabled` keeps for
/// `DrawingViewerConfig`.
///
/// **This does not make the build faster.** `webview_flutter_wkwebview` is a
/// native plugin registered from the pubspec, so its pod is still compiled
/// and its framework still ships in flag-off builds — only the Dart code is
/// tree-shaken. Exactly the caveat noted for `pdfrx` above. Cutting the
/// native build cost would mean removing the dependency from the pubspec,
/// not setting a define.
const bool kWebViewEnabled =
    bool.fromEnvironment('CENTROIDX_WEBVIEW', defaultValue: true);
