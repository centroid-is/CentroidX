# flutter_inappwebview_windows (vendored)

WebView2 for the **Windows** build, behind the `Web page` page asset
(`lib/page_creator/assets/web_view.dart`).

Vendored from
[pichillilorenzo/flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview/tree/master/flutter_inappwebview_windows)
at pub.dev **0.6.0** (published 2024-10-08, the latest stable at the time of
copying; `0.7.0-beta.3` carries the same defect). Not a fork on GitHub — a copy
with one native fix, the way `packages/webview_cef` is a copy with a subset.

## Why vendored rather than a dependency

The Web page asset keeps browsers warm across page changes (see "Warm
browsers" in `web_view.dart`): a tile that leaves the screen parks its browser
and the next tile on the same address takes it back, so a dashboard the
operator returns to is on screen at once instead of after a fresh engine start
and page load. On Windows that goes through this plugin's *keep-alive*
feature, because its widget otherwise disposes the native WebView2 with
itself.

Upstream's keep-alive take-back path has a leak: `createInAppWebView` calls
`CreateWindowEx` **before** checking whether it is handing back a kept-alive
view, and in that branch the new window is neither used, stored, nor
destroyed. The WebView2 already owns the window it was created against —
the one `InAppWebView::~InAppWebView` destroys — so every take-back leaked
one hidden window, a USER handle from the process's 10 000, for as long as
the HMI ran. An operator returning to a dashboard a hundred times a day
would have exhausted it in months. Fixed here; to be offered upstream.

## What was removed

* `example/`, `test/`, `windows/test/` — the plugin's own example app and
  its unit tests (only built when building the example).

## What was changed

**`windows/in_app_webview/in_app_webview_manager.cpp` —
`InAppWebViewManager::createInAppWebView`.** The keep-alive branch now runs
first and hands the new `CustomPlatformView` the window the WebView2 already
has (`ICoreWebView2Controller::get_ParentWindow`); `CreateWindowEx` runs
only for a genuinely new view. Marked `// CentroidX:` in the source.

Everything else is byte-for-byte upstream.

## Dropping this

When an upstream release moves the `CreateWindowEx` past the keep-alive
branch (or destroys the window it made), delete this directory and put
`flutter_inappwebview_windows: ^<that version>` back in the root
`pubspec.yaml`. Nothing in the app imports this package directly: it is a
pure dependency whose `dartPluginClass` registers itself, and `web_view.dart`
talks to it only through `flutter_inappwebview_platform_interface`.
