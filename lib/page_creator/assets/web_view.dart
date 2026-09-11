/// A live web page on the HMI canvas.
///
/// This is the real thing — a browser rendering the page, not a screenshot of
/// it — which is why it exists on some of our platforms and not others.
///
/// ## Where it works, and why
///
/// Two engines, chosen on one principle: **use the browser the operating
/// system already ships and patches, never one we bundle.**
///
///   * **macOS** — WKWebView, via `webview_flutter`'s
///     `webview_flutter_wkwebview`.
///   * **Windows** — WebView2, via `flutter_inappwebview_windows`. The Edge
///     runtime is a Windows component, serviced by Windows Update, so again
///     there is nothing of ours to keep current.
///
/// Windows goes through the *federated implementation package directly*
/// rather than the `flutter_inappwebview` umbrella. The umbrella endorses
/// Android, iOS, macOS and web as well, so depending on it would add native
/// plugins to every platform's build; `flutter_inappwebview_windows` declares
/// `windows` alone and is invisible to the others. Note also that this file
/// imports only `flutter_inappwebview_platform_interface` — the Windows
/// package is a pure dependency whose `dartPluginClass` registers itself, so
/// no import here is platform-conditional.
///
/// The Linux side has no such browser to borrow, so it breaks the principle
/// deliberately rather than going without:
///
///   * **Linux desktop and flutter-elinux** — CEF, via the vendored
///     `packages/webview_cef`. Both report `TargetPlatform.linux`; the plugin
///     registrant picks the matching port at build time.
///
/// That is a browser engine *we* ship and therefore have to keep patched —
/// a few hundred megabytes, downloaded at build time, with security updates
/// tracked by bumping `CEF_VERSION` ourselves. It is the cost of the eLinux
/// stations having no system webview at all, and it is why the dependency is
/// vendored down to the Linux and eLinux ports: upstream declares macOS and
/// Windows too, and depending on it unmodified would drag CEF into the two
/// builds that already have a browser for free. WPE WebKit would be the
/// lighter long-term answer — it is in Debian, so apt-tracked — but no
/// Flutter plugin exists for it. See `packages/webview_cef/README.md`.
///
/// Still without an implementation:
///
///   * **Web** — an `<iframe>` would be trivial, but there is no web target.
///
/// ## WebView2 and CEF can be absent
///
/// WKWebView is part of macOS and cannot be missing. WebView2 is a separate
/// runtime, and although it ships with Windows 11 and current Windows 10, a
/// stripped or offline-imaged box can lack it. CEF can be absent in two more
/// ways: missing from the image, or present but with `initCEFProcesses()`
/// never called in the runner's `main()`. Asking costs a channel call,
/// so [WebViewSurface.isAvailable] is a `Future` and the tile may flip to the
/// unavailable placeholder shortly *after* it started — which is still far
/// better than the blank white rectangle a dead engine would otherwise leave.
///
/// So: where a webview exists, show one; everywhere else say so plainly and
/// keep the tile findable. That is [WebViewAvailability] and the placeholder
/// in [WebViewAssetView], and it is why this asset is *not* a replacement for
/// the server-rendered Grafana panel — that one works everywhere.
///
/// ## Why it is a picture by default
///
/// [WebViewAssetConfig.interactive] is off unless someone turns it on. A
/// wall-mounted station has no keyboard and no back button: an operator who
/// brushes a link has navigated the tile somewhere else permanently, and
/// nobody on the floor can bring it back. Non-interactive is the safe shape
/// for a dashboard on a wall; interaction is for a desk.
///
/// A reload (see [WebViewAssetConfig.reloadSeconds]) navigates to the
/// configured URL afresh rather than calling `reload()`, so a tile that *did*
/// wander — because it is interactive, or because the page redirected itself —
/// comes home on the next tick without anyone touching it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:webview_cef/webview_cef.dart' as cef;
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/feature_flags.dart';
import 'common.dart';

part 'web_view.g.dart';

@JsonSerializable(explicitToJson: true)
class WebViewAssetConfig extends BaseAsset {
  @override
  String get displayName => 'Web page';
  @override
  String get category => 'Visualization';
  @override
  List<String> get searchKeywords => const [
        'web',
        'webview',
        'browser',
        'iframe',
        'url',
        'site',
        'page',
        'dashboard',
      ];

  /// Address to show. Empty means not configured yet and renders a
  /// placeholder rather than an error — a fresh asset dropped on the canvas is
  /// not a fault.
  String url;

  /// Seconds between reloads; 0 means never.
  ///
  /// A dashboard on a wall wants to refresh itself. See the library doc for
  /// why a reload re-navigates rather than reloading in place.
  int reloadSeconds;

  /// Whether operators can click and scroll inside the page.
  ///
  /// Off by default. See the library doc — on a wall-mounted station an
  /// accidental tap on a link is unrecoverable from the floor.
  bool interactive;

  WebViewAssetConfig({
    this.url = '',
    this.reloadSeconds = 0,
    this.interactive = false,
  }) {
    size = const RelativeSize(width: 0.25, height: 0.2);
  }

  WebViewAssetConfig.preview()
      : url = '',
        reloadSeconds = 0,
        interactive = false {
    size = const RelativeSize(width: 0.25, height: 0.2);
  }

  factory WebViewAssetConfig.fromJson(Map<String, dynamic> json) =>
      _$WebViewAssetConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$WebViewAssetConfigToJson(this);

  /// True when [url] is something a browser could actually open.
  ///
  /// Only `http` and `https` count. A `file:` or `javascript:` URL in a page
  /// config is either a mistake or someone being clever, and neither belongs
  /// on a plant screen.
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool get isConfigured => parseWebViewUrl(url) != null;

  // Gated like DrawingViewerConfig: a flag-off build still deserializes a
  // saved page carrying this asset, it just renders the unavailable
  // placeholder instead of a browser. Keeping WebViewAssetView unreachable
  // is what lets the webview_flutter Dart code tree-shake out.
  @override
  Widget build(BuildContext context) => kWebViewEnabled
      ? WebViewAssetView(config: this)
      : const _UnavailableTile();

  @override
  Widget configure(BuildContext context) => kWebViewEnabled
      ? _WebViewAssetConfigEditor(config: this)
      : const _UnavailableTile();
}

/// Parses [raw] into a browsable http(s) URL, or null.
///
/// Kept separate from the widget so the rule is testable without a browser,
/// and so the editor and the runtime cannot disagree about what counts.
Uri? parseWebViewUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}

/// The platforms a webview is implemented for, and which engine serves them.
///
/// Pure and parameterised so every branch is testable from any machine:
/// `defaultTargetPlatform` on a dev box says "supported", so without the
/// parameters the unsupported branch could only ever run in production — and
/// the Windows branch could only ever be checked on Windows.
@visibleForTesting
class WebViewAvailability {
  const WebViewAvailability._();

  static const Set<TargetPlatform> supportedPlatforms = {
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  };

  /// Platforms served by CEF rather than by an OS-provided browser.
  ///
  /// Both the Linux desktop build and the eLinux stations report
  /// `TargetPlatform.linux` — Dart cannot tell them apart, and here it does
  /// not need to: `packages/webview_cef` carries a port for each, and the
  /// plugin registrant picks the right one at build time.
  ///
  /// Unlike WKWebView and WebView2, CEF is not on the machine at all unless
  /// we put it there, and it additionally needs `initCEFProcesses()` to have
  /// run in the runner's `main()`. Both absences look the same from Dart, and
  /// both are caught by [WebViewSurfaceAvailability].
  static const Set<TargetPlatform> cefPlatforms = {
    TargetPlatform.linux,
  };

  /// Whether [platform] is served by CEF.
  static bool usesCef({bool? isWeb, TargetPlatform? platform}) {
    if (isWeb ?? kIsWeb) return false;
    return cefPlatforms.contains(platform ?? defaultTargetPlatform);
  }

  /// Platforms served by WebView2 rather than by `webview_flutter`.
  ///
  /// Separate from [supportedPlatforms] because the two engines have
  /// different absence modes: WKWebView is part of the OS, WebView2 is a
  /// runtime that can be missing. See [WebViewSurface.isAvailable].
  static const Set<TargetPlatform> webView2Platforms = {
    TargetPlatform.windows,
  };

  /// Whether [platform] is served by WebView2.
  static bool usesWebView2({bool? isWeb, TargetPlatform? platform}) {
    if (isWeb ?? kIsWeb) return false;
    return webView2Platforms.contains(platform ?? defaultTargetPlatform);
  }

  /// Whether a webview can be built here. Defaults to the ambient platform.
  static bool check({bool? isWeb, TargetPlatform? platform}) {
    // Flutter web would need an <iframe> via HtmlElementView, which is a
    // different implementation entirely and not wired up.
    if (isWeb ?? kIsWeb) return false;
    return supportedPlatforms.contains(platform ?? defaultTargetPlatform);
  }
}

/// What [WebViewAssetView] needs from a browser.
///
/// Abstracted for the same reason `RtspCameraPlayback` is: so widget tests
/// never construct a real WKWebView, and so "this platform has no browser" is
/// representable as a null factory result rather than a thrown exception the
/// caller has to classify.
abstract class WebViewSurface {
  /// The widget that paints the page.
  Widget build(BuildContext context);

  /// Navigate to [uri]. Called on first build and on every reload tick.
  Future<void> navigate(Uri uri);

  Future<void> dispose();
}

/// Implemented *in addition to* [WebViewSurface] by a surface whose engine
/// can be missing from a machine we otherwise support.
///
/// A separate interface rather than a member with a default, because Dart's
/// `implements` inherits no concrete members: putting it on [WebViewSurface]
/// would force the engine that cannot be absent — and every fake in every
/// test — to grow a member none of them care about. An absent-able engine
/// opts in; [WebViewAssetView] asks only those that do.
abstract class WebViewSurfaceAvailability {
  /// False when the engine is not installed on this machine.
  Future<bool> get isAvailable;
}

/// Builds the browser for [config], or null where this platform has none.
typedef WebViewSurfaceFactory = WebViewSurface? Function(
    WebViewAssetConfig config);

class WebViewAssetView extends StatefulWidget {
  final WebViewAssetConfig config;
  const WebViewAssetView({super.key, required this.config});

  /// Replaces the browser in tests. Null restores the real one.
  @visibleForTesting
  static WebViewSurfaceFactory? debugSurfaceFactory;

  @override
  State<WebViewAssetView> createState() => _WebViewAssetViewState();
}

class _WebViewAssetViewState extends State<WebViewAssetView> {
  WebViewSurface? _surface;
  Timer? _reloadTimer;

  /// Distinguishes "no browser on this platform" from "not configured", which
  /// look different to an operator.
  bool _unavailable = false;

  /// The URL currently loaded, and the interval currently armed.
  ///
  /// State, not a comparison against `oldWidget` — the page editor mutates the
  /// *same* [WebViewAssetConfig] instance in place (see the config pane's
  /// `setState(() => config.url = …)`), so `oldWidget.config` and
  /// `widget.config` are one object and every field comparison between them is
  /// trivially equal. Diffing against what we actually loaded is the only way
  /// to notice an edit.
  String? _loadedUrl;
  int? _armedInterval;

  /// Whether this tile is sitting on the page-editor canvas.
  ///
  /// Read in [didChangeDependencies] rather than [initState]: the scope is an
  /// inherited widget, so it is not readable until dependencies are resolved.
  /// That ordering is the whole reason the browser is not started from
  /// `initState` — doing so would build a browser for every tile on the editor
  /// canvas and merely decline to paint it.
  bool _editing = false;

  WebViewAssetConfig get config => widget.config;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editing = AssetEditModeScope.isEditing(context);
    if (_editing) {
      _stop();
    } else if (_surface == null && !_unavailable) {
      _start();
    }
    // No setState in here or in _start/_stop: both run immediately before a
    // build (didChangeDependencies and didUpdateWidget are each followed by
    // one), so the fields they set are picked up without asking for another.
  }

  @override
  void didUpdateWidget(WebViewAssetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_editing) return;
    final wanted = parseWebViewUrl(config.url)?.toString();
    if (wanted != _loadedUrl) {
      _restart();
    } else if (config.reloadSeconds != _armedInterval) {
      _armTimer();
    }
  }

  void _restart() {
    _stop();
    _start();
  }

  /// Tears the browser down and forgets what was loaded, so a later [_start]
  /// navigates afresh.
  void _stop() {
    _teardown();
    _surface = null;
    _unavailable = false;
    _loadedUrl = null;
    _armedInterval = null;
  }

  void _start() {
    final uri = parseWebViewUrl(config.url);
    if (uri == null) return;
    _loadedUrl = uri.toString();
    final factory = WebViewAssetView.debugSurfaceFactory ?? _defaultFactory;
    final surface = factory(config);
    if (surface == null) {
      _unavailable = true;
      return;
    }
    _surface = surface;
    _probeAvailability(surface);
    unawaited(surface.navigate(uri).catchError((Object _) {
      // A failed navigation leaves whatever the browser is showing, and
      // re-navigating on the next reload tick is the recovery.
      //
      // The two engines disagree here, and the difference matters on a wall.
      //
      // macOS, observed 2026-09-11: an unreachable host leaves the tile
      // *blank white*, not on a browser error page — WKWebView paints nothing
      // for a provisional navigation that never commits. That reads as a
      // broken tile rather than an unreachable one. Surfacing it properly
      // means the NavigationDelegate (onWebResourceError), not this catch,
      // which only ever sees the channel call failing. Still a known gap.
      //
      // Windows, observed 2026-09-11 against WebView2 152.0.4191.66: the same
      // unreachable host paints Edge's own "Hmmm… can't reach this page" and
      // additionally fires onReceivedError. So the gap above is a macOS gap,
      // not a shared one — a Windows tile already says something truthful
      // without us doing anything. Worth knowing before someone "fixes" this
      // for both platforms and regresses Windows into a custom placeholder
      // that says less than Edge's page does.
    }));
    _armTimer();
  }

  /// Asks an absent-able engine whether it is really there, and flips the
  /// tile to the placeholder if it is not.
  ///
  /// Only WebView2 answers this; see [WebViewSurfaceAvailability]. It runs
  /// after the surface is already built and navigating, because the check is
  /// a channel round trip — so a Windows box with no runtime shows the
  /// browser tile for an instant and then the honest placeholder, rather than
  /// a white rectangle for ever.
  void _probeAvailability(WebViewSurface surface) {
    if (surface is! WebViewSurfaceAvailability) return;
    unawaited(
      (surface as WebViewSurfaceAvailability).isAvailable.then((ok) {
        // `_surface != surface` means a restart overtook this probe and the
        // answer is about a browser nobody is looking at any more.
        if (ok || !mounted || _surface != surface) return;
        setState(() {
          _teardown();
          _unavailable = true;
          _loadedUrl = null;
          _armedInterval = null;
        });
      }).catchError((Object _) {}),
    );
  }

  void _armTimer() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    final seconds = config.reloadSeconds;
    _armedInterval = seconds;
    if (seconds <= 0) return;
    _reloadTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      final surface = _surface;
      final uri = parseWebViewUrl(config.url);
      if (surface == null || uri == null) return;
      unawaited(surface.navigate(uri).catchError((Object _) {}));
    });
  }

  void _teardown() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    final surface = _surface;
    _surface = null;
    // No .timeout() here: this runs from dispose, where a pending timeout
    // timer would outlive the element it belongs to.
    unawaited(surface?.dispose().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        // Not colorScheme.outline: neither of our schemes sets it, so it
        // falls back to a Material default that disappears on the dark
        // theme.
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) {
    if (!config.isConfigured) {
      return const _Glyph(
        icon: Icons.public_off,
        caption: 'No address',
      );
    }
    // On the editor canvas, never run a browser: it would reload on every
    // nudge of the asset, and a page full of tiles would be a page full of
    // browsers. The placeholder keeps the asset selectable and shows which
    // site this tile is, which is what you need while laying out a page.
    if (AssetEditModeScope.isEditing(context)) {
      return _Glyph(
        icon: Icons.public,
        caption: parseWebViewUrl(config.url)?.host,
      );
    }
    if (_unavailable) {
      return const _Glyph(
        icon: Icons.public_off,
        caption: 'Web view is not available on this platform',
      );
    }
    final surface = _surface;
    if (surface == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final page = surface.build(context);
      // A browser expands to fill, which an unbounded constraint cannot
      // satisfy — and a layout exception on the canvas takes the whole page
      // down with it, not just this tile. Where the parent declines to bound
      // us, stand on a readable default.
      final bounded = constraints.hasBoundedWidth && constraints.hasBoundedHeight
          ? page
          : SizedBox(
              width: constraints.hasBoundedWidth ? null : 640,
              height: constraints.hasBoundedHeight ? null : 400,
              child: page,
            );
      // Non-interactive is the default; see the library doc. IgnorePointer
      // rather than AbsorbPointer so a tap still reaches the page's own
      // gesture layer underneath.
      return config.interactive ? bounded : IgnorePointer(child: bounded);
    });
  }
}

/// The real browser: WebView2 on Windows, WKWebView on macOS.
WebViewSurface? _defaultFactory(WebViewAssetConfig config) {
  if (!WebViewAvailability.check()) return null;
  try {
    if (WebViewAvailability.usesWebView2()) {
      // Null when the Windows package did not register itself, which is what
      // a platform with no implementation looks like from here. Checked
      // rather than left to the factory's `assert`: asserts are compiled out
      // of a release build, where the same case would instead be a null-check
      // Error from `instance!`.
      if (InAppWebViewPlatform.instance == null) return null;
      return _WebView2Surface(config);
    }
    if (WebViewAvailability.usesCef()) return _CefSurface(config);
    return _PlatformWebViewSurface(config);
  } catch (_) {
    // Bare catch: a missing platform implementation surfaces as an
    // AssertionError from WebViewPlatform.instance, which is an Error and
    // would slip past `on Exception`. Either way the answer is the same
    // placeholder — there is no browser here.
    return null;
  }
}

class _PlatformWebViewSurface implements WebViewSurface {
  final WebViewController _controller;

  _PlatformWebViewSurface(WebViewAssetConfig config)
      : _controller = WebViewController() {
    _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  }

  @override
  Widget build(BuildContext context) =>
      WebViewWidget(controller: _controller);

  @override
  Future<void> navigate(Uri uri) => _controller.loadRequest(uri);

  @override
  Future<void> dispose() async {
    // WebViewController has no dispose(); the platform view is torn down with
    // the widget. Pointing it at a blank page first stops a video or a
    // polling dashboard from carrying on in a detached web process.
    await _controller.loadRequest(Uri.parse('about:blank'));
  }
}

/// WebView2 on Windows, through `flutter_inappwebview`'s platform interface.
///
/// Shaped differently from the WKWebView surface because the API is: the
/// widget is created with its first address baked in as `initialUrlRequest`,
/// and the controller that can navigate afterwards only arrives later, via
/// `onWebViewCreated`. [navigate] therefore has to work in three situations —
/// before the widget is built, after it is built but before the controller
/// exists, and normally — which is what [_wanted] and [_initialUrl] are for.
class _WebView2Surface implements WebViewSurface, WebViewSurfaceAvailability {
  _WebView2Surface(WebViewAssetConfig config);

  PlatformInAppWebViewWidget? _widget;
  PlatformInAppWebViewController? _controller;

  /// The most recent [navigate] target, whether or not it has been applied.
  Uri? _wanted;

  /// What went into `initialUrlRequest`, so [_onCreated] can tell an address
  /// that is already loading from one that arrived while we had no controller.
  String? _initialUrl;

  bool _disposed = false;

  @override
  Future<void> navigate(Uri uri) async {
    _wanted = uri;
    final controller = _controller;
    // No controller yet: [build] will bake this in, or [_onCreated] will
    // apply it. Either way it is not lost, and it is not an error.
    if (controller == null || _disposed) return;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
  }

  // Typed `dynamic` because that is what the platform interface declares:
  // the callback is handed `controllerFromPlatform?.call(c) ?? c`, and we
  // pass no `controllerFromPlatform`, so what arrives is the raw controller.
  void _onCreated(dynamic raw) {
    if (raw is! PlatformInAppWebViewController) return;
    final controller = raw;
    _controller = controller;
    final wanted = _wanted?.toString();
    // Only if the address moved on while the browser was starting — otherwise
    // initialUrlRequest is already loading it and a second load would be a
    // visible double-fetch.
    if (_disposed || wanted == null || wanted == _initialUrl) return;
    unawaited(controller
        .loadUrl(urlRequest: URLRequest(url: WebUri(wanted)))
        .catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    // Created once and cached: constructing the platform widget again on a
    // later build would tear down the browser and start a new one on every
    // frame the parent happens to rebuild.
    final widget = _widget ??= PlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams(
        initialUrlRequest: _wanted == null
            ? null
            : URLRequest(url: WebUri((_initialUrl = _wanted.toString()))),
        onWebViewCreated: _onCreated,
      ),
    );
    return widget.build(context);
  }

  /// Asks WebView2 whether it is installed at all.
  ///
  /// `getAvailableVersion` answers null when the runtime is absent; the call
  /// itself throws if the plugin cannot reach the native side, which is the
  /// same answer for our purposes.
  @override
  Future<bool> get isAvailable async {
    try {
      final environment = InAppWebViewPlatform.instance
          ?.createPlatformWebViewEnvironment(
              const PlatformWebViewEnvironmentCreationParams());
      if (environment == null) return false;
      final version = await environment.getAvailableVersion();
      return version != null && version.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    final widget = _widget;
    _widget = null;
    // Same reason as the WKWebView surface: park the page so a video or a
    // polling dashboard stops running in a browser nobody can see any more.
    if (controller != null) {
      await controller
          .loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')))
          .catchError((Object _) {});
    }
    widget?.dispose();
  }
}


/// CEF on the Linux desktop build and the eLinux stations, through the
/// vendored `packages/webview_cef`.
///
/// Unlike WKWebView and WebView2 this engine is one we ship ourselves, and it
/// has two distinct ways of not being there: the CEF libraries missing from
/// the image, and `initCEFProcesses()` not having run in the runner's
/// `main()` — CEF re-executes the host binary as its own render and GPU
/// children, so without that call the first browser never comes up. Neither
/// is distinguishable from Dart and neither needs to be: both land on
/// [isAvailable] returning false and the tile showing the placeholder.
class _CefSurface implements WebViewSurface, WebViewSurfaceAvailability {
  _CefSurface(WebViewAssetConfig config);

  /// One process-wide CEF startup, shared by every tile on the page.
  ///
  /// `WebviewManager()` is a singleton and initialising it twice is not
  /// meaningful, so the future is cached — including its failure, so a
  /// machine without CEF pays one failed attempt rather than one per tile per
  /// reload tick.
  static Future<bool>? _managerReady;

  static Future<bool> _startManager() => _managerReady ??= cef.WebviewManager()
      .initialize()
      .then((_) => true)
      // Bare Object: a missing native side arrives as a PlatformException or
      // a MissingPluginException, and a broken one can arrive as an Error.
      .catchError((Object _) => false);

  final cef.WebViewController _controller = cef.WebviewManager().createWebView();

  /// Whether [_controller] has been initialised. Guards dispose: the
  /// controller awaits a `late` completer that only `initialize` assigns, so
  /// disposing one that never navigated throws a LateInitializationError
  /// instead of tearing down.
  bool _started = false;

  @override
  Future<bool> get isAvailable => _startManager();

  @override
  Future<void> navigate(Uri uri) async {
    if (!await _startManager()) {
      throw StateError('CEF is not available on this machine');
    }
    if (_started) {
      await _controller.loadUrl(uri.toString());
      return;
    }
    _started = true;
    await _controller.initialize(uri.toString());
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _controller,
        // False until the browser has a texture to paint. The empty box is
        // deliberate rather than a spinner: WebViewAssetView already shows one
        // while no surface has produced anything.
        builder: (context, ready, _) =>
            ready ? _controller.webviewWidget : const SizedBox.expand(),
      );

  @override
  Future<void> dispose() async {
    if (!_started) return;
    await _controller.dispose();
  }
}

/// Centred icon and caption, sized off the box like the image, camera and
/// Grafana placeholders — a glyph is a font glyph, so scaling it with a
/// `FittedBox` would resample it the way text resamples.
class _Glyph extends StatelessWidget {
  final IconData icon;
  final String? caption;
  const _Glyph({required this.icon, this.caption});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    return LayoutBuilder(builder: (context, constraints) {
      final shortest = constraints.biggest.shortestSide;
      final side = shortest.isFinite && shortest > 0 ? shortest : 48.0;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: (side * 0.35).clamp(16.0, 64.0), color: color),
              if (caption != null && side >= 72) ...[
                const SizedBox(height: 6),
                Text(
                  caption!,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}

/// What a flag-off build shows in place of the asset: the same framed
/// placeholder an unsupported platform gets, so a page author sees a reason
/// rather than an empty rectangle.
class _UnavailableTile extends StatelessWidget {
  const _UnavailableTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border:
            Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const _Glyph(
        icon: Icons.public_off,
        caption: 'Web view is not available on this platform',
      ),
    );
  }
}

/// Reload intervals offered in the editor, in seconds. 0 is "never".
///
/// Coarse on purpose: a web page is a heavier thing to re-fetch than a tag,
/// and anything under half a minute on a wall dashboard is churn nobody reads.
const List<int> kWebViewReloadChoices = [0, 30, 60, 300, 900];

String webViewReloadLabel(int seconds) {
  if (seconds <= 0) return 'Never';
  if (seconds < 60) return '$seconds seconds';
  final minutes = seconds ~/ 60;
  return minutes == 1 ? '1 minute' : '$minutes minutes';
}

class _WebViewAssetConfigEditor extends StatefulWidget {
  final WebViewAssetConfig config;
  const _WebViewAssetConfigEditor({required this.config});

  @override
  State<_WebViewAssetConfigEditor> createState() =>
      _WebViewAssetConfigEditorState();
}

class _WebViewAssetConfigEditorState extends State<_WebViewAssetConfigEditor> {
  WebViewAssetConfig get config => widget.config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typed = config.url.trim();
    final invalid = typed.isNotEmpty && parseWebViewUrl(typed) == null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: config.url,
            decoration: InputDecoration(
              labelText: 'Address',
              hintText: 'https://grafana.plant/d/abc123/line-1',
              errorText: invalid ? 'Must be an http:// or https:// address' : null,
            ),
            onChanged: (value) => setState(() => config.url = value.trim()),
          ),
          const SizedBox(height: 16),
          Text('Reload', style: theme.textTheme.titleMedium),
          DropdownButton<int>(
            value: kWebViewReloadChoices.contains(config.reloadSeconds)
                ? config.reloadSeconds
                : 0,
            isExpanded: true,
            onChanged: (value) =>
                setState(() => config.reloadSeconds = value ?? 0),
            items: kWebViewReloadChoices
                .map((s) => DropdownMenuItem<int>(
                    value: s, child: Text(webViewReloadLabel(s))))
                .toList(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Interactive'),
            subtitle: const Text(
              'Lets operators click and scroll. Off for wall-mounted '
              'stations — a tap on a link cannot be undone from the floor.',
            ),
            value: config.interactive,
            onChanged: (value) => setState(() => config.interactive = value),
          ),
          const SizedBox(height: 8),
          Text(
            'Shows a live web page. Available on macOS only — the eLinux '
            'stations and Windows have no browser engine installed, and show '
            'a placeholder instead.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: config.text,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => setState(() => config.text = value),
          ),
          const SizedBox(height: 8),
          DropdownButton<TextPos>(
            value: config.textPos,
            hint: const Text('Label position'),
            isExpanded: true,
            onChanged: (value) => setState(() => config.textPos = value),
            items: TextPos.values
                .map((e) =>
                    DropdownMenuItem<TextPos>(value: e, child: Text(e.name)))
                .toList(),
          ),
          const SizedBox(height: 16),
          SizeField(
            initialValue: config.size,
            onChanged: (size) => setState(() => config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: config.coordinates,
            onChanged: (c) => setState(() => config.coordinates = c),
          ),
        ],
      ),
    );
  }
}
