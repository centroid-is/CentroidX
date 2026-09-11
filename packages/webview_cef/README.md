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
except for the one fix below.

## What was changed

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

## Updating

Re-download the published archive, copy `common/ lib/ linux/ elinux/ third/`
over, and re-apply the two pubspec deletions and the eLinux CMake fix above.
Check upstream first: if the `../example/...` paths are gone, that fix is no
longer needed.

## Cost to be aware of

CEF is downloaded at build time from `cef-builds.spotifycdn.com` (pinned by
`CEF_VERSION` in `third/download.cmake`) and adds a few hundred megabytes to
the Linux and eLinux images. Security updates are ours to track — bump
`CEF_VERSION` deliberately. WPE WebKit, which is in Debian and therefore
apt-tracked, is the lighter long-term alternative; no Flutter plugin exists
for it, which is why this is here instead.
