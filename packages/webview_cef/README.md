# webview_cef (vendored)

CEF-backed webview for the **Linux desktop and eLinux** builds only, behind
the `Web page` page asset (`lib/page_creator/assets/web_view.dart`).

Vendored from [hlwhl/webview_cef](https://github.com/hlwhl/webview_cef) at
**v0.6.2** (CEF 149 / Chromium 149). Not a fork on GitHub — a copy, because
what we need is a *subset* of the package, and the subset is the whole point.

## Why vendored rather than a dependency

Upstream ships **one** package declaring `macos`, `windows`, `linux` and
`elinux`. Flutter registers a plugin on every platform its own pubspec
declares, and the consumer cannot narrow that. Depending on it would put CEF
into the macOS and Windows builds, where the asset already has WKWebView and
WebView2 respectively — and CEF is not a small passenger: the macOS podspec's
`prepare_command` and the Windows/Linux `third/download.cmake` each fetch a
~600 MB CEF distribution at build time.

So this copy keeps `linux` and `elinux` and drops the rest.

## What was removed

* `macos/`, `windows/` — the ports we do not want registered.
* `example/`, `test/`, the READMEs, `CHANGELOG.md`.
* `macos:` and `windows:` from `pubspec.yaml`'s `flutter.plugin.platforms`.

`common/`, `lib/`, `linux/`, `elinux/` and `third/` are byte-for-byte upstream
except for the changes below.

## What was changed

**`lib/src/webview.dart` — `WebViewController.resize`.** A public wrapper
over the private `_setSize`, so a browser started ahead of its widget (the
HMI pre-starts dashboards at boot, see "Warm browsers" in
`lib/page_creator/assets/web_view.dart`) can be laid out for the window
instead of the handler's 1 x 1 default. Upstream sizes only from the widget,
so a pre-started page did all its layout, and a dashboard's lazy panel
loading, on first show. Marked `// CentroidX:`.

**`lib/src/webview.dart`, `common/` — `WebViewController.invalidate`.**
Off-screen rendering is damage-driven: CEF calls `OnPaint` when the page has
something new to show, and the Flutter texture is only repopulated when such a
frame arrives. Upstream never needs to force one, because a browser is only
ever shown by the widget that just created and navigated it — and a loading
page damages constantly. The HMI hands browsers between tiles, so it shows
browsers whose page settled long ago, which paint nothing at all; the tile then
displays the frame it had when it last left the screen, indefinitely. This adds
a `CefBrowserHost::Invalidate(PET_VIEW)` behind an `invalidate` channel method.
Marked `// CentroidX:`.

**`common/`, `lib/src/webview_manager.dart`,
`lib/src/webview_events_listener.dart` —
`CefRequestHandler::OnRenderProcessTerminated`.** Upstream's handler
implements every CEF handler interface but this one, so a render process
dying is completely silent: the browser object survives, no load event fires,
`OnPaint` simply never comes again, and the tile keeps its last frame with
nothing in the log to say why. The handler now implements
`CefRequestHandler`, logs the termination to stderr, and reports it to Dart as
`renderProcessGone` — carried by a new `onRenderProcessGone` callback on
`WebviewEventsListener`, and queued by `WebviewManager` when the death lands
before `create` has returned and registered the browser id — so the host can
navigate the browser and get a fresh render process. Marked `// CentroidX:`.

**`common/webview_app.cc` — the display backend.** Chromium's Linux display
backend ("ozone") defaults to X11. An eLinux station is Wayland-only, so CEF
logged "Missing X server or $DISPLAY" and its UI thread exited, and every Web
page tile stayed blank. The browser is windowless (it paints into a CPU buffer
that becomes a Flutter texture), so it needs no display at all. Where no
`DISPLAY` is set, the browser process now gets `--ozone-platform=headless`.
`CENTROIDX_CEF_OZONE_PLATFORM` overrides that from a station's environment,
because the flutter-elinux runner rejects unknown command-line flags.

**`elinux/CMakeLists.txt` — the C++ client wrapper.** Upstream hardcoded

    ../example/elinux/flutter/ephemeral/cpp_client_wrapper

for its include directories and compiled `standard_codec.cc`,
`plugin_registrar.cc` and `engine_method_result.cc` out of it by hand. That
directory only exists inside webview_cef's *own example app* after a build; it
is not in the published archive, so the eLinux port as shipped cannot compile
in a consuming app at all.

Replaced with the `flutter` and `flutter_wrapper_plugin` targets that
flutter-elinux provides, which is how `packages/media_kit_video_elinux` — a
working eLinux plugin in this repo — consumes the same things.

**`elinux/CMakeLists.txt` — shipping `locales/`.** Upstream installed CEF's
`locales/` with a plain `install(DIRECTORY)` plus a POST_BUILD copy. The
flutter-elinux app template requires CMake 3.15, so under CMP0082 a plugin's
install rules run *before* the template's `file(REMOVE_RECURSE bundle/)`, and
the wipe deletes them. The image shipped with no locales at all, and the first
Web page tile crashed the whole HMI (Chromium's locale `CHECK`, SIGTRAP in
`libcef.so`). The install is now deferred with `cmake_language(DEFER)` to run
after the wipe. `docker/frontend/Dockerfile` fails the build if
`lib/locales/en-US.pak` is missing.

## Updating

Re-download the published archive, copy `common/ lib/ linux/ elinux/ third/`
over, and re-apply the two pubspec deletions and both eLinux CMake fixes above.
Check upstream first: if the `../example/...` paths are gone, the first fix is
no longer needed.

## Cost to be aware of

CEF is downloaded at build time from `cef-builds.spotifycdn.com` (pinned by
`CEF_VERSION` in `third/download.cmake`) and adds a few hundred megabytes to
the Linux and eLinux images. Security updates are ours to track — bump
`CEF_VERSION` deliberately. WPE WebKit, which is in Debian and therefore
apt-tracked, is the lighter long-term alternative; no Flutter plugin exists
for it, which is why this is here instead.
