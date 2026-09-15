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
///
/// ## Following the HMI theme
///
/// A Grafana dashboard drawn light on a dark HMI is a white slab on the wall.
/// [WebViewAssetConfig.themeParam] names a query parameter (`theme`, for
/// Grafana) that the loaded address carries, set to a dark or light value for
/// the brightness the HMI is rendering with. A theme flip re-navigates the
/// browser; nothing else does. Off unless configured, so an existing tile
/// loads exactly what it always loaded.
///
/// Every engine, the reload tick included, loads [effectiveWebViewUrl] rather
/// than the raw [WebViewAssetConfig.url]. The editor-canvas placeholder shows
/// only the host, which the parameter never changes. There is no web build to
/// apply it to (see above); an `<iframe>` would take its `src` from the same
/// function.
///
/// ## Warm browsers
///
/// A tile is a widget on a page, and a page is torn down when the operator
/// navigates away. Tearing the browser down with it meant every return to
/// the page paid the full price again — starting an engine, then fetching
/// and rendering a dashboard — which on the plant was three seconds of cover
/// for a page the operator had been looking at a moment ago.
///
/// So a tile that leaves the screen no longer disposes its browser: it parks
/// it in [WebViewSurfacePool], keyed by the address it is on, and the next
/// tile started for that address takes the parked browser over as it is,
/// page and all, without navigating. The page is on screen the same frame
/// the tile is. A parked browser keeps running — a dashboard keeps polling —
/// which is exactly what makes it current when it comes back; the pool is
/// bounded (see [kWebViewWarmBrowsers]) so that cost cannot grow with the
/// number of pages visited, and the oldest parked browser is disposed for
/// real to make room.
///
/// Each engine survives its widget leaving the tree differently. WKWebView
/// lives in its controller and is re-wrapped by a new platform view. CEF's
/// browser is closed only by an explicit `dispose`, and its texture is
/// re-shown — but re-showing it is not enough on its own, because off-screen
/// rendering is damage-driven and a browser is parked precisely because its
/// page has settled. It paints nothing while parked and nothing on return, so
/// the tile would show the frame it had when it left the screen, for ever.
/// A browser taken back is therefore asked for one; see
/// [WebViewSurfaceRepaint]. WebView2's Flutter widget disposes the native view
/// with itself unless it was created with a keep-alive handle, so the Windows
/// surface holds one; see [_WebView2Surface].
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        defaultTargetPlatform,
        kIsWeb,
        TargetPlatform,
        ValueListenable,
        visibleForTesting;
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

  /// Name of a query parameter that tells the site which theme to draw, e.g.
  /// `theme` for Grafana. Null or empty turns the feature off, which is the
  /// default — the configured URL is then loaded exactly as typed.
  ///
  /// When set, the loaded address carries `<themeParam>=<value>` for the
  /// brightness the HMI is actually rendering, and the page is re-navigated
  /// when the operator flips the HMI theme. See [effectiveUrl].
  ///
  /// Grafana honours `?theme=dark|light` on public dashboards
  /// (`/public-dashboards/<token>`) as well as on normal ones. There is no
  /// parameter for an arbitrary colour, so this follows brightness only.
  ///
  /// This and the two values below are omitted from the JSON while null, so a
  /// tile that never used the feature saves exactly what it saved before.
  @JsonKey(includeIfNull: false)
  String? themeParam;

  /// Value sent in [themeParam] while the HMI is dark. Null means `dark`.
  @JsonKey(includeIfNull: false)
  String? themeDarkValue;

  /// Value sent in [themeParam] while the HMI is light. Null means `light`.
  @JsonKey(includeIfNull: false)
  String? themeLightValue;

  WebViewAssetConfig({
    this.url = '',
    this.reloadSeconds = 0,
    this.interactive = false,
    this.themeParam,
    this.themeDarkValue,
    this.themeLightValue,
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

  /// The address to actually load while the HMI renders with [brightness]:
  /// [url] with the theme parameter applied, or null when [url] is not
  /// browsable. Identical to `parseWebViewUrl(url)` while [themeParam] is
  /// unset.
  Uri? effectiveUrl(Brightness brightness) => effectiveWebViewUrl(
        url,
        brightness: brightness,
        themeParam: themeParam,
        darkValue: themeDarkValue,
        lightValue: themeLightValue,
      );

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

/// Value sent for a dark HMI when the config leaves it unset.
const String kWebViewThemeDarkDefault = 'dark';

/// Value sent for a light HMI when the config leaves it unset.
const String kWebViewThemeLightDefault = 'light';

/// [raw] as a browsable URL with the theme query parameter applied for
/// [brightness], or null when [raw] is not browsable (see [parseWebViewUrl]).
///
/// [themeParam] null or blank leaves the URL untouched. [darkValue] and
/// [lightValue] null or blank fall back to `dark` and `light`.
///
/// The one place a configured address becomes the address a browser is
/// pointed at — every engine, and anything added later (an `<iframe>` on a
/// web build would take its `src` from here), goes through it so none of them
/// can disagree about which theme a page was asked for.
Uri? effectiveWebViewUrl(
  String raw, {
  required Brightness brightness,
  String? themeParam,
  String? darkValue,
  String? lightValue,
}) {
  final uri = parseWebViewUrl(raw);
  if (uri == null) return null;
  final name = themeParam?.trim() ?? '';
  if (name.isEmpty) return uri;
  String pick(String? configured, String fallback) {
    final v = configured?.trim() ?? '';
    return v.isEmpty ? fallback : v;
  }

  final value = brightness == Brightness.dark
      ? pick(darkValue, kWebViewThemeDarkDefault)
      : pick(lightValue, kWebViewThemeLightDefault);
  return withQueryParameter(uri, name, value);
}

/// [uri] with query parameter [name] set to [value].
///
/// The first existing occurrence of [name] is replaced where it stands and any
/// further occurrences are dropped; when there is none the pair is appended.
/// Every other parameter is kept *verbatim* — same order, same encoding — and
/// so is the fragment. That is why this edits the raw query string rather than
/// round-tripping through `queryParameters`, which would re-encode (`%20`
/// becoming `+`), and merge repeated keys like Grafana's `var-host=a&var-host=b`.
Uri withQueryParameter(Uri uri, String name, String value) {
  final pair =
      '${Uri.encodeQueryComponent(name)}=${Uri.encodeQueryComponent(value)}';
  final pieces = uri.query.isEmpty ? const <String>[] : uri.query.split('&');
  final out = <String>[];
  var placed = false;
  for (final piece in pieces) {
    final eq = piece.indexOf('=');
    final rawKey = eq < 0 ? piece : piece.substring(0, eq);
    String key;
    try {
      key = Uri.decodeQueryComponent(rawKey);
    } catch (_) {
      // A malformed escape (ArgumentError or FormatException, depending on
      // the SDK) cannot be the parameter we are looking for — its name
      // decodes cleanly — so keep it as it came.
      key = rawKey;
    }
    if (key != name) {
      out.add(piece);
    } else if (!placed) {
      out.add(pair);
      placed = true;
    }
  }
  if (!placed) out.add(pair);
  return uri.replace(query: out.join('&'));
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
  ///
  /// May instead complete with a [WebViewUnavailable] when the engine is
  /// installed but the tile has something more specific to tell the operator
  /// than "not available", e.g. CEF that never finished starting.
  Future<bool> get isAvailable;
}

/// Why a tile whose engine is installed still cannot show a page, in words
/// that make sense on the tile itself.
///
/// Thrown from [WebViewSurfaceAvailability.isAvailable] rather than returned,
/// so the WebView2 surface and every test fake keep their plain `bool`.
class WebViewUnavailable implements Exception {
  const WebViewUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'WebViewUnavailable: $reason';
}

/// How far a surface has got with the page it was last asked for.
enum WebViewLoadPhase {
  /// Navigating, with nothing worth showing painted yet.
  loading,

  /// Something truthful is painted: the page, or the engine's own error page.
  shown,

  /// The navigation failed and the engine painted nothing in its place.
  failed,
}

/// One reading of a surface's progress, for [WebViewSurfaceLoading.load].
@immutable
class WebViewLoad {
  const WebViewLoad.loading([this.progress]) : phase = WebViewLoadPhase.loading;
  const WebViewLoad.shown()
      : phase = WebViewLoadPhase.shown,
        progress = null;
  const WebViewLoad.failed()
      : phase = WebViewLoadPhase.failed,
        progress = null;

  final WebViewLoadPhase phase;

  /// 0..1 while loading, where the engine reports it. Null draws the bar
  /// indeterminate.
  final double? progress;

  @override
  bool operator ==(Object other) =>
      other is WebViewLoad && other.phase == phase && other.progress == progress;

  @override
  int get hashCode => Object.hash(phase, progress);
}

/// Implemented *in addition to* [WebViewSurface] by a surface that can say
/// when its page has painted. The same opt-in shape as
/// [WebViewSurfaceAvailability], for the same reason.
///
/// Without it the tile goes straight from nothing to the raw browser, and
/// every engine paints blank white until the page commits: a white box
/// popping onto a dark HMI with nothing on it to say it is working. With it,
/// [WebViewAssetView] holds a themed cover naming the site over the browser —
/// which is laid out underneath and loading all the while — until [load]
/// says [WebViewLoadPhase.shown], then fades it off.
///
/// The contract: [load] starts at `loading`; any navigation may report
/// `loading` again; `shown` means the engine has something truthful on
/// screen, its own error page included; `failed` only when it painted nothing
/// at all.
abstract class WebViewSurfaceLoading {
  ValueListenable<WebViewLoad> get load;
}

/// Implemented *in addition to* [WebViewSurface] by a surface whose engine
/// can be given a size before any widget shows it. Same opt-in shape as
/// [WebViewSurfaceAvailability], for the same reason.
///
/// A browser started ahead of its tile (see [WebViewSurfacePool.prewarm])
/// otherwise lays its page out at whatever default the engine has, and a
/// dashboard that lazy-loads panels outside its viewport does that loading on
/// first show — measured at 0.8 s of a 1.2 s first visit on a station. Sized
/// to the window, it has loaded every panel the tile could show, and the
/// tile's own size on take-back is at most a shrink.
abstract class WebViewSurfacePresizing {
  /// Lays the page out for [size] logical pixels at [devicePixelRatio].
  /// Effective only before the surface's widget mounts; the widget's own
  /// size wins from then on.
  void presize(Size size, double devicePixelRatio);
}

/// Implemented *in addition to* [WebViewSurface] by a surface whose picture
/// can go stale while no widget is drawing it. Same opt-in shape as
/// [WebViewSurfaceAvailability], for the same reason.
///
/// Off-screen engines paint on *damage*: CEF calls `OnPaint` when the page has
/// something new to show, and the Flutter texture behind the tile is only
/// repopulated when such a frame arrives — the engine caches the last resolved
/// image until it is told a new one exists. A browser created and navigated by
/// the tile that shows it is never a problem, because a loading page damages
/// constantly. A browser handed over by [WebViewSurfacePool] is: its page has
/// long since settled, it produces no frames, and the tile therefore shows the
/// frame it was painting when it last left the screen — for ever, since every
/// later take-back is just as quiet. That is the freeze this exists to break.
///
/// WKWebView and WebView2 are real platform views that redraw themselves, so
/// neither implements this; it is CEF's texture that needs asking.
abstract class WebViewSurfaceRepaint {
  /// Asks the engine for a frame now, whether or not the page changed.
  ///
  /// Cheap, and safe to call at any time: an implementation that knows
  /// frames are already coming — the page is still loading, the renderer is
  /// being recovered — may decline, and a redundant ask costs one texture
  /// upload at most.
  void repaint();
}

/// How long a page may stay covered while it is still loading.
///
/// Heavy dashboards — Grafana is the one on the plant — paint long before the
/// engine calls the load finished, and covering them until then would hide a
/// page that is already readable. After this the cover lifts on its own; a
/// failure with nothing ever shown puts it back.
const Duration kWebViewRevealTimeout = Duration(seconds: 8);

/// How many browsers stay warm after their tiles have left the screen.
///
/// Each one is a live page — a Grafana tab is a couple of hundred megabytes
/// and polls its data source — so this is the trade between a page that
/// comes back at once and an HMI that grows a browser for every page ever
/// visited. Three covers an operator switching between a couple of
/// dashboards and the mimic; the fourth address visited costs the oldest its
/// browser. See the library doc, "Warm browsers".
const int kWebViewWarmBrowsers = 3;

/// Browsers parked by tiles that left the screen, waiting for the same
/// address to be asked for again. See the library doc, "Warm browsers".
///
/// Keyed by the address the browser is on, so a tile only ever takes over a
/// browser showing the page it wants — including the theme parameter, which
/// is part of the effective URL. Two tiles on the same address park two
/// browsers, and each takes the most recently parked one back.
///
/// Process-wide by design: the tile that parks a browser is gone by the time
/// the one that wants it exists, so nothing shorter-lived could hand it over.
/// [instance] is replaceable so tests can start from an empty lot.
class WebViewSurfacePool {
  WebViewSurfacePool({this.capacity = kWebViewWarmBrowsers});

  /// The lot every [WebViewAssetView] parks in and takes from.
  static WebViewSurfacePool instance = WebViewSurfacePool();

  /// Browsers kept at once. Zero parks nothing: every browser handed to
  /// [park] is disposed on the spot.
  final int capacity;

  /// Oldest first.
  final List<_ParkedSurface> _parked = [];

  /// How many tiles are showing each address right now. Kept so [prewarm]
  /// does not start a second browser for a page that is already on screen.
  final Map<String, int> _active = {};

  int get size => _parked.length;

  /// The addresses parked, oldest first.
  Iterable<String> get urls => _parked.map((p) => p.url);

  /// A tile started showing [url]; see [release].
  void claim(String url) => _active[url] = (_active[url] ?? 0) + 1;

  /// A tile stopped showing [url].
  void release(String url) {
    final n = (_active[url] ?? 0) - 1;
    if (n <= 0) {
      _active.remove(url);
    } else {
      _active[url] = n;
    }
  }

  /// Whether a browser on [url] exists, parked or on screen.
  bool isKnown(String url) =>
      _active.containsKey(url) || _parked.any((p) => p.url == url);

  /// Starts a browser for each of [configs] now and parks it, so the first
  /// visit to its page is a take-back rather than an engine start and a page
  /// load. Returns how many were started.
  ///
  /// The cold open on a station was measured at 3.8 s, a return at 0.45 s,
  /// and nothing about the cold path itself can be made much faster: it is
  /// the engine coming up and a dashboard's own scripts running. Starting
  /// it before anyone asks is the only way to make the first visit quick.
  ///
  /// Addresses already parked or on screen are skipped, and so is anything
  /// past [capacity], so a page config with more web tiles than the lot holds
  /// warms the first few and leaves the rest cold rather than churning. A
  /// browser that then reports its engine absent, or whose first navigation
  /// throws, is forgotten again, so the tile that would have taken it over
  /// starts fresh and reaches the "not available" placeholder as before.
  ///
  /// WebView2 needs its widget in the tree before the native view exists,
  /// so on Windows this starts nothing; the first visit there stays cold.
  ///
  /// [viewport] is the window's logical size, handed to every surface that
  /// can be sized before it is shown (see [WebViewSurfacePresizing]); null
  /// leaves each engine at its default.
  int prewarm(
    Iterable<WebViewAssetConfig> configs, {
    required Brightness brightness,
    Size? viewport,
    double devicePixelRatio = 1.0,
  }) {
    if (WebViewAvailability.usesWebView2()) return 0;
    final factory = WebViewAssetView.debugSurfaceFactory ?? _defaultFactory;
    final seen = <String>{};
    var started = 0;
    for (final config in configs) {
      if (_parked.length >= capacity) break;
      final uri = config.effectiveUrl(brightness);
      if (uri == null) continue;
      final url = uri.toString();
      if (!seen.add(url) || isKnown(url)) continue;
      final surface = factory(config);
      // No browser on this platform: none of the rest will fare better.
      if (surface == null) break;
      if (viewport != null && surface is WebViewSurfacePresizing) {
        (surface as WebViewSurfacePresizing).presize(viewport, devicePixelRatio);
      }
      park(url, surface);
      started++;
      unawaited(surface.navigate(uri).then((_) {}, onError: (Object _) {
        forget(surface);
      }));
      if (surface is WebViewSurfaceAvailability) {
        unawaited((surface as WebViewSurfaceAvailability).isAvailable.then(
          (ok) {
            if (!ok) forget(surface);
          },
          onError: (Object _) => forget(surface),
        ));
      }
    }
    return started;
  }

  /// Drops [surface] from the lot, if it is there, and disposes it.
  void forget(WebViewSurface surface) {
    final before = _parked.length;
    _parked.removeWhere((p) => identical(p.surface, surface));
    if (_parked.length != before) _drop(surface);
  }

  /// Keeps [surface], which is showing [url], for a later [take].
  ///
  /// Over [capacity], the browser parked longest ago is disposed for real.
  void park(String url, WebViewSurface surface) {
    if (capacity <= 0) {
      _drop(surface);
      return;
    }
    _parked.add(_ParkedSurface(url, surface));
    while (_parked.length > capacity) {
      _drop(_parked.removeAt(0).surface);
    }
  }

  /// The browser most recently parked on [url], removed from the lot, or
  /// null when none is.
  ///
  /// A surface whose picture can go stale while parked (see
  /// [WebViewSurfaceRepaint]) is asked for a frame here, once the frame that
  /// shows it has been laid out. The ask lives in the hand-over itself rather
  /// than in the taker, because it compensates for what parking did — the
  /// page settled, stopped damaging, and stopped painting — and every future
  /// consumer of a parked browser would otherwise have to independently
  /// remember to ask, or ship the same frozen-tile bug the pool exists to
  /// avoid.
  ///
  /// Deferred to after the frame because a take-back happens while the taker
  /// is still building: the ask is a channel call and wants the browser
  /// actually on screen. It does not need to be ordered against the taker's
  /// size report, which lands from another post-frame callback — a size that
  /// really changed damages the page and paints anyway, and a size that did
  /// not is exactly the case the ask exists for. A surface that got re-parked
  /// or dropped between the frames guards inside [WebViewSurfaceRepaint.repaint]
  /// itself; a redundant ask costs one texture upload at most.
  WebViewSurface? take(String url) {
    for (var i = _parked.length - 1; i >= 0; i--) {
      if (_parked[i].url != url) continue;
      final surface = _parked.removeAt(i).surface;
      if (surface is WebViewSurfaceRepaint) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          (surface as WebViewSurfaceRepaint).repaint();
        });
      }
      return surface;
    }
    return null;
  }

  /// Disposes every parked browser.
  Future<void> clear() async {
    final parked = List.of(_parked);
    _parked.clear();
    for (final p in parked) {
      await p.surface.dispose().catchError((Object _) {});
    }
  }

  static void _drop(WebViewSurface surface) =>
      unawaited(surface.dispose().catchError((Object _) {}));
}

class _ParkedSurface {
  const _ParkedSurface(this.url, this.surface);
  final String url;
  final WebViewSurface surface;
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

  /// What the placeholder says when [_unavailable]. Null means this platform
  /// has no browser at all, the common case.
  String? _unavailableReason;

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

  /// The brightness the HMI is rendering with, which picks the theme query
  /// parameter's value (see [WebViewAssetConfig.themeParam]).
  ///
  /// Kept in a field because it can only be read from [didChangeDependencies]
  /// — which is also exactly where a theme flip arrives — while [_start],
  /// [didUpdateWidget] and the reload timer all need it.
  Brightness _brightness = Brightness.light;

  /// The latest reading from a [WebViewSurfaceLoading] surface. Null for a
  /// surface that reports none, which is shown straight away as it always was.
  WebViewLoad? _load;

  /// Whether this start's page has been shown. Never unset by a reload tick
  /// or a theme flip: those navigate in place, and the old page stays painted
  /// until the new one commits, so covering it again would only hide
  /// something readable. A restart — a new address — clears it.
  bool _shown = false;

  /// [kWebViewRevealTimeout] has run out since the start.
  bool _capElapsed = false;
  Timer? _capTimer;

  /// Whether the cover is in the tree, fading or not. Dropped once it has
  /// faded out, so an interactive tile's taps meet the page and nothing else.
  bool _veilMounted = false;

  VoidCallback? _stopWatchingLoad;

  WebViewAssetConfig get config => widget.config;

  bool get _covered {
    final load = _load;
    if (load == null || _shown) return false;
    return load.phase == WebViewLoadPhase.failed || !_capElapsed;
  }

  /// What the browser should be showing right now.
  Uri? get _effectiveUrl => config.effectiveUrl(_brightness);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editing = AssetEditModeScope.isEditing(context);
    _brightness = Theme.of(context).brightness;
    if (_editing) {
      _stop();
    } else if (_surface == null && !_unavailable) {
      _start();
    } else {
      _followTheme();
    }
    // No setState in here or in _start/_stop: both run immediately before a
    // build (didChangeDependencies and didUpdateWidget are each followed by
    // one), so the fields they set are picked up without asking for another.
  }

  @override
  void didUpdateWidget(WebViewAssetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_editing) return;
    final wanted = _effectiveUrl?.toString();
    if (wanted != _loadedUrl) {
      _restart();
    } else if (config.reloadSeconds != _armedInterval) {
      _armTimer();
    }
  }

  /// Re-navigates the running browser when a theme flip changed the address
  /// it should be on.
  ///
  /// Runs on every dependency change, but only navigates when the effective
  /// URL actually moved — so an unrelated inherited change (a colour tweak
  /// within the same brightness, a MediaQuery update) costs one string
  /// comparison and no reload, and a tile with no theme parameter never
  /// reloads on a theme flip at all, its effective URL being the same in
  /// both. Navigates the existing browser in place rather than restarting
  /// it: nothing about the engine changed, only the address.
  void _followTheme() {
    final surface = _surface;
    final uri = _effectiveUrl;
    if (surface == null || uri == null) return;
    final wanted = uri.toString();
    if (wanted == _loadedUrl) return;
    final pool = WebViewSurfacePool.instance;
    if (_loadedUrl != null) pool.release(_loadedUrl!);
    _loadedUrl = wanted;
    pool.claim(wanted);
    unawaited(surface.navigate(uri).catchError((Object _) {}));
  }

  void _restart() {
    _stop();
    _start();
  }

  /// Parks the browser and forgets what was loaded, so a later [_start]
  /// starts afresh — taking the parked browser back if it is on the same
  /// address, navigating a new one otherwise.
  void _stop() {
    _teardown(keep: true);
    _surface = null;
    _unavailable = false;
    _unavailableReason = null;
    _loadedUrl = null;
    _armedInterval = null;
  }

  void _start() {
    final uri = _effectiveUrl;
    if (uri == null) return;
    _loadedUrl = uri.toString();
    // A browser already on this page beats starting one: it is taken over as
    // it stands, and not navigated, so the page is up the same frame the tile
    // is. It proved its engine present when it first ran, so the availability
    // probe — a channel round trip — is not repeated either.
    final pool = WebViewSurfacePool.instance;
    final parked = pool.take(_loadedUrl!);
    if (parked != null) {
      _surface = parked;
      pool.claim(_loadedUrl!);
      _watchLoad(parked);
      _armTimer();
      return;
    }
    final factory = WebViewAssetView.debugSurfaceFactory ?? _defaultFactory;
    final surface = factory(config);
    if (surface == null) {
      _unavailable = true;
      return;
    }
    _surface = surface;
    pool.claim(_loadedUrl!);
    _probeAvailability(surface);
    _watchLoad(surface);
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
      //
      // The loading cover (see [WebViewSurfaceLoading]) keeps to the same
      // split. WebView2 and CEF lift it onto their own error pages; only
      // WKWebView reports `failed`, which is what finally puts "Can't reach"
      // on that blank tile.
    }));
    _armTimer();
  }

  /// Follows a surface that reports its loading, to cover the tile until its
  /// first page is up. See [WebViewSurfaceLoading].
  ///
  /// Fields are set directly, without setState, for the same reason as the
  /// rest of [_start]; the listener and the cap timer run later, from the
  /// engine and the clock, and do call it.
  void _watchLoad(WebViewSurface surface) {
    if (surface is! WebViewSurfaceLoading) return;
    final load = (surface as WebViewSurfaceLoading).load;
    _load = load.value;
    _shown = load.value.phase == WebViewLoadPhase.shown;
    _veilMounted = _covered;

    void onLoad() {
      // `_surface != surface`: a restart overtook this browser; its news is
      // about a page nobody is looking at any more.
      if (!mounted || _surface != surface) return;
      setState(() {
        _load = load.value;
        if (load.value.phase == WebViewLoadPhase.shown) _shown = true;
        if (_covered) _veilMounted = true;
      });
    }

    load.addListener(onLoad);
    _stopWatchingLoad = () => load.removeListener(onLoad);
    _capTimer = Timer(kWebViewRevealTimeout, () {
      if (!mounted || _surface != surface) return;
      setState(() => _capElapsed = true);
    });
  }

  /// Asks an absent-able engine whether it is really there, and flips the
  /// tile to the placeholder if it is not.
  ///
  /// Only WebView2 and CEF answer this; see [WebViewSurfaceAvailability]. It
  /// runs after the surface is already built and navigating, because the
  /// check is a channel round trip — so a Windows box with no runtime shows
  /// the browser tile for an instant and then the honest placeholder, rather
  /// than a white rectangle for ever.
  ///
  /// A [WebViewUnavailable] puts its reason on the placeholder. Any other
  /// error leaves the tile alone: a probe that could not answer is not proof
  /// that the browser is missing.
  void _probeAvailability(WebViewSurface surface) {
    if (surface is! WebViewSurfaceAvailability) return;
    unawaited(
      (surface as WebViewSurfaceAvailability).isAvailable.then((ok) {
        if (!ok) _giveUp(surface, null);
      }).catchError((Object e) {
        if (e is WebViewUnavailable) _giveUp(surface, e.reason);
      }),
    );
  }

  void _giveUp(WebViewSurface surface, String? reason) {
    // `_surface != surface` means a restart overtook this probe and the
    // answer is about a browser nobody is looking at any more.
    if (!mounted || _surface != surface) return;
    setState(() {
      // A browser that cannot render is nothing to keep warm.
      _teardown(keep: false);
      _unavailable = true;
      _unavailableReason = reason;
      _loadedUrl = null;
      _armedInterval = null;
    });
  }

  void _armTimer() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    final seconds = config.reloadSeconds;
    _armedInterval = seconds;
    if (seconds <= 0) return;
    _reloadTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      final surface = _surface;
      // The effective address, so a reload keeps the theme the page is
      // currently being asked for.
      final uri = _effectiveUrl;
      if (surface == null || uri == null) return;
      unawaited(surface.navigate(uri).catchError((Object _) {}));
    });
  }

  /// Lets go of the browser: parked for the next tile on this address when
  /// [keep] is set, disposed otherwise.
  ///
  /// A browser whose page never came up is disposed either way — parking it
  /// would hand the next tile a "Can't reach" that nothing retries until a
  /// reload tick, where a fresh browser at least tries again on the spot.
  void _teardown({required bool keep}) {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
    _stopWatchingLoad?.call();
    _stopWatchingLoad = null;
    _load = null;
    _shown = false;
    _capElapsed = false;
    _veilMounted = false;
    final surface = _surface;
    final url = _loadedUrl;
    _surface = null;
    if (surface == null) return;
    final pool = WebViewSurfacePool.instance;
    if (url != null) pool.release(url);
    final failed = surface is WebViewSurfaceLoading &&
        (surface as WebViewSurfaceLoading).load.value.phase ==
            WebViewLoadPhase.failed;
    if (keep && url != null && !failed) {
      pool.park(url, surface);
      return;
    }
    // No .timeout() here: this runs from dispose, where a pending timeout
    // timer would outlive the element it belongs to.
    unawaited(surface.dispose().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _teardown(keep: true);
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
      return _Glyph(
        icon: Icons.public_off,
        caption:
            _unavailableReason ?? 'Web view is not available on this platform',
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
    final covered = _covered;
    // Always a Stack, cover or not: the browser keeps the same place in the
    // tree when the cover comes and goes, so its platform view is never torn
    // down and rebuilt under it. `passthrough` hands the browser exactly the
    // constraints it had before there was a Stack here.
    return Stack(fit: StackFit.passthrough, children: [
      _browser(surface),
      if (_veilMounted)
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !covered,
            child: AnimatedOpacity(
              opacity: covered ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              onEnd: () {
                if (mounted && !_covered) {
                  setState(() => _veilMounted = false);
                }
              },
              child: _LoadingVeil(
                host: parseWebViewUrl(config.url)?.host,
                load: _load ?? const WebViewLoad.loading(),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _browser(WebViewSurface surface) {
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

class _PlatformWebViewSurface
    implements WebViewSurface, WebViewSurfaceLoading {
  final WebViewController _controller;
  final ValueNotifier<WebViewLoad> _load =
      ValueNotifier(const WebViewLoad.loading());
  bool _disposed = false;

  _PlatformWebViewSurface(WebViewAssetConfig config)
      : _controller = WebViewController() {
    _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    // WKWebView says nothing between "started" and "finished" — progress is
    // KVO on its estimatedProgress — and a failed provisional navigation
    // paints nothing at all: the blank white tile the note in `_start`
    // describes. So this is the one engine that reports `failed`.
    unawaited(_controller.setNavigationDelegate(NavigationDelegate(
      onProgress: (percent) => _set(WebViewLoad.loading(percent / 100)),
      onPageFinished: (_) => _set(const WebViewLoad.shown()),
      onWebResourceError: (error) {
        // -999 is NSURLErrorCancelled: this navigation was overtaken by the
        // next one — a theme flip mid-load — which is not a failure.
        if (error.errorCode == -999 || error.isForMainFrame == false) return;
        _set(const WebViewLoad.failed());
      },
    )));
  }

  // Parking the page on about:blank in [dispose] fires one last
  // onPageFinished; nobody is listening by then, and nothing may be told.
  void _set(WebViewLoad value) {
    if (!_disposed) _load.value = value;
  }

  @override
  ValueListenable<WebViewLoad> get load => _load;

  @override
  Widget build(BuildContext context) =>
      WebViewWidget(controller: _controller);

  @override
  Future<void> navigate(Uri uri) => _controller.loadRequest(uri);

  @override
  Future<void> dispose() async {
    _disposed = true;
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
/// exists, and normally — which is what [_wanted] and [_applied] are for.
///
/// ## Surviving the widget
///
/// The plugin's widget owns its native view: the Flutter element disposing
/// disposes the WebView2 with it, which would make a parked surface (see the
/// library doc, "Warm browsers") an empty shell. Unless it was created with a
/// keep-alive handle — then the native side moves the WebView2 into a
/// keep-alive table when the widget goes, and a later widget created with
/// the same handle takes it back, page and all, in place of starting one. So
/// every surface holds a handle for its lifetime, and [build] after a park
/// is just the plugin widget built again. The handle is what [dispose] has
/// to release, or the native view outlives everything.
///
/// Taking the view back replays `onWebViewCreated` with a fresh controller.
/// The address it should be on is whatever was last handed to the engine —
/// [_applied], which a theme flip's in-place navigation moves on from the
/// `initialUrlRequest` — so the replay compares against that and does not
/// reload a page that is already there.
class _WebView2Surface
    implements WebViewSurface, WebViewSurfaceAvailability, WebViewSurfaceLoading {
  _WebView2Surface(WebViewAssetConfig config);

  /// Keeps the native WebView2 alive while no widget shows it.
  final InAppWebViewKeepAlive _keepAlive = InAppWebViewKeepAlive();

  final ValueNotifier<WebViewLoad> _load =
      ValueNotifier(const WebViewLoad.loading());

  @override
  ValueListenable<WebViewLoad> get load => _load;

  void _set(WebViewLoad value) {
    if (!_disposed) _load.value = value;
  }

  /// What the Windows plugin reports, read off its native side
  /// (`in_app_webview.cpp`, flutter_inappwebview_windows 0.6.0): progress 0
  /// when navigation starts, 33 when content starts loading — the commit,
  /// the old page gone — 66 at DOMContentLoaded, and 100 on completion,
  /// followed by onLoadStop, or onReceivedError, or for a TLS failure
  /// nothing at all. Nothing marks "first paint", so 66 is the reveal: the
  /// document is there and paints straight after. Never `failed`: Edge
  /// paints its own error page, and the note in `_start` says why that is
  /// the thing to show.
  void _onProgress(int progress) => _set(progress >= 66
      ? const WebViewLoad.shown()
      : WebViewLoad.loading(progress / 100));

  PlatformInAppWebViewWidget? _widget;
  PlatformInAppWebViewController? _controller;

  /// The most recent [navigate] target, whether or not it has been applied.
  Uri? _wanted;

  /// The address last handed to the engine — `initialUrlRequest`, or the
  /// last `loadUrl` — so [_onCreated] can tell an address that is already
  /// loading from one that arrived while we had no controller.
  String? _applied;

  bool _disposed = false;

  @override
  Future<void> navigate(Uri uri) async {
    _wanted = uri;
    final controller = _controller;
    // No controller yet: [build] will bake this in, or [_onCreated] will
    // apply it. Either way it is not lost, and it is not an error.
    if (controller == null || _disposed) return;
    _applied = uri.toString();
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
  }

  // Typed `dynamic` because that is what the platform interface declares:
  // the callback is handed `controllerFromPlatform?.call(c) ?? c`, and we
  // pass no `controllerFromPlatform`, so what arrives is the raw controller.
  //
  // Runs once per widget the engine is shown through: on first creation, and
  // again each time a parked view is taken back (see the class doc).
  void _onCreated(dynamic raw) {
    if (raw is! PlatformInAppWebViewController) return;
    final controller = raw;
    _controller = controller;
    final wanted = _wanted?.toString();
    // Only if the address moved on while the browser was starting — otherwise
    // the engine is already on it and a second load would be a visible
    // double-fetch, or on a taken-back view a reload of a page already up.
    if (_disposed || wanted == null || wanted == _applied) return;
    _applied = wanted;
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
            : URLRequest(url: WebUri((_applied = _wanted.toString()))),
        keepAlive: _keepAlive,
        onWebViewCreated: _onCreated,
        onProgressChanged: (_, progress) => _onProgress(progress),
        // Belt and braces for the progress reveal above.
        onLoadStop: (_, __) => _set(const WebViewLoad.shown()),
        onReceivedError: (_, __, ___) => _set(const WebViewLoad.shown()),
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
    // The widget's dispose leaves a kept-alive native view in the plugin's
    // table on purpose; this is what actually frees it.
    try {
      await InAppWebViewPlatform.instance
          ?.createPlatformInAppWebViewControllerStatic()
          .disposeKeepAlive(_keepAlive);
    } catch (_) {
      // A plugin that cannot reach its native side has nothing to free.
    }
  }
}


/// The pace a browser whose render process keeps dying is re-navigated at:
/// zero for the first death — a one-off crash should cost one page load, not
/// a wait — then 4 s doubling to a minute, so a page that kills its renderer
/// every time never reloads in a tight loop. Top-level only so tests can pin
/// it; the sole caller is [_CefSurface].
@visibleForTesting
Duration cefRendererRecoveryDelay(int consecutiveCrashes) {
  if (consecutiveCrashes <= 1) return Duration.zero;
  final seconds = 1 << consecutiveCrashes.clamp(0, 6);
  return Duration(seconds: seconds.clamp(0, 60).toInt());
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
///
/// And a third, which looks nothing like the other two: CEF present and
/// initialised, but its browser never coming up. See [startTimeout].
class _CefSurface
    implements
        WebViewSurface,
        WebViewSurfaceAvailability,
        WebViewSurfaceLoading,
        WebViewSurfacePresizing,
        WebViewSurfaceRepaint {
  _CefSurface(WebViewAssetConfig config) {
    // Nobody may be listening when a failed `create` lands (a tile that
    // already gave up via [_browserFailed]); that must not surface as an
    // unhandled error. Other listeners still receive it.
    _created.future.ignore();
    // CEF reports no progress, so the bar runs indeterminate. It does report
    // the end of every load — per frame, the main one included — and a load
    // that errors ends on CEF's own error page, so an end is always
    // something truthful on screen and never a `failed`. Should the event be
    // lost (it can land before the browser's id is registered), the reveal
    // timeout lifts the cover anyway.
    _controller.setWebviewListener(cef.WebviewEventsListener(
      onLoadEnd: (_, __) {
        if (_disposed) return;
        _load.value = const WebViewLoad.shown();
        // A load ending is a renderer alive and painting, so a recovery that
        // got this far worked: the next death starts the backoff over.
        _rendererCrashes = 0;
      },
      // The render process died. CEF keeps the browser object and reports no
      // load event, but nothing will paint again until it is navigated, so
      // the browser is worthless until then — and worse than worthless in
      // the pool, where it would be handed on as a warm one. Re-navigating
      // makes CEF start a fresh render process; see
      // [_scheduleRendererRecovery] for the pace.
      onRenderProcessGone: (_) {
        if (_disposed) return;
        _rendererGone = true;
        // The frame on screen is the dead renderer's last — plant data from
        // whenever it died, which must not read as the live page. Reporting
        // `loading` puts the cover back on any tile showing this browser,
        // and on one that takes it back mid-recovery.
        _load.value = const WebViewLoad.loading();
        _scheduleRendererRecovery();
      },
    ));
  }

  /// Whether this browser's render process has died without a navigation
  /// since. Suppresses [repaint] — asking a dead renderer for a frame
  /// achieves nothing — and is cleared by [navigate] once the load has
  /// actually been sent, because the load is what brings a fresh render
  /// process up: clearing it any earlier would mark a browser whose recovery
  /// *failed* as healthy, and the pool would hand the corpse on as warm.
  bool _rendererGone = false;

  /// The address this browser was last asked for, so a renderer that died can
  /// be sent back to it.
  Uri? _lastUri;

  /// Renderer deaths since a load last finished. Paces the recovery.
  int _rendererCrashes = 0;

  /// The pending recovery, so repeated deaths coalesce and dispose can stop
  /// a browser being brought back from the dead.
  Timer? _recoveryTimer;

  /// Re-navigates a browser whose render process died, at a pace that backs
  /// off while the deaths keep coming.
  ///
  /// The first death is recovered immediately: a one-off crash should cost
  /// one page load, not a wait. But recovery *is* a full page load, and a
  /// page that reliably kills its renderer — a heavy dashboard OOM-killing
  /// on a memory-constrained station is the realistic case — would otherwise
  /// reload in a tight zero-delay loop, churning CPU and memory against the
  /// HMI's own work, including from browsers parked invisibly in the pool.
  /// So repeated deaths back off exponentially; see
  /// [cefRendererRecoveryDelay]. There is deliberately no give-up: nobody
  /// stands at a plant wall to click "retry", and a page that stops crashing
  /// (the dashboard was fixed, the station's memory pressure passed) should
  /// come back on its own.
  void _scheduleRendererRecovery() {
    final uri = _lastUri;
    if (uri == null) return;
    _rendererCrashes++;
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(cefRendererRecoveryDelay(_rendererCrashes), () {
      if (_disposed) return;
      unawaited(_recoverRenderer(uri));
    });
  }

  Future<void> _recoverRenderer(Uri uri) async {
    try {
      // The death can land while the browser is still being created — a
      // prewarmed browser's first page can kill its fresh render process —
      // and the recovery load needs the browser to exist first. `navigate`
      // alone would not wait: its re-load path sends straight away.
      await _created.future;
      await navigate(uri);
    } on Object {
      // The load could not even be sent: this browser is a corpse. `failed`
      // is what stops [_WebViewAssetViewState._teardown] parking it as warm
      // — the exact freeze recovery exists to prevent — and what lets a tile
      // showing it say so instead of presenting the dead frame as live. A
      // corpse already parked has no tile left to notice, so it is dropped
      // from the pool here (a no-op while a tile still holds it).
      if (!_disposed) {
        _load.value = const WebViewLoad.failed();
        WebViewSurfacePool.instance.forget(this);
      }
    }
  }

  final ValueNotifier<WebViewLoad> _load =
      ValueNotifier(const WebViewLoad.loading());
  bool _disposed = false;

  @override
  ValueListenable<WebViewLoad> get load => _load;

  /// How long a browser gets to come up before the tile gives up and says so.
  ///
  /// `init` answering does not mean CEF is up. CEF initialises its platform
  /// layer afterwards, on its own UI thread. When that failed on a
  /// Wayland-only station on 2026-09-11 ("Missing X server or $DISPLAY"), the
  /// thread exited and `create` was never answered. The tile sat blank for
  /// ever, with nothing on it to say why. Creating a browser (not loading its
  /// page) takes well under a second on a station, so this is generous.
  static const Duration startTimeout = Duration(seconds: 20);

  /// Set once any tile's browser failed to come up. CEF does not recover
  /// within a process, so later tiles say so at once instead of each waiting
  /// out [startTimeout].
  static bool _browserFailed = false;

  static const String _didNotStart =
      'The web browser did not start. See the HMI log for the reason.';

  /// Completes once this tile's browser exists, which is later than `init`.
  final Completer<void> _created = Completer<void>();

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
  Future<bool> get isAvailable async {
    if (!await _startManager()) return false;
    if (_browserFailed) throw const WebViewUnavailable(_didNotStart);
    try {
      await _created.future.timeout(startTimeout);
    } on Object {
      // Timed out, or `create` itself failed. Either way CEF will not give
      // this process a browser.
      _browserFailed = true;
      throw const WebViewUnavailable(_didNotStart);
    }
    return true;
  }

  @override
  Future<void> navigate(Uri uri) async {
    _lastUri = uri;
    if (!await _startManager()) {
      throw StateError('CEF is not available on this machine');
    }
    if (_started) {
      await _controller.loadUrl(uri.toString());
      // Only once the load was actually sent: it is what starts the fresh
      // render process, and a send that threw must leave the browser marked
      // dead.
      _rendererGone = false;
      return;
    }
    _started = true;
    try {
      await _controller.initialize(uri.toString());
      if (!_created.isCompleted) _created.complete();
    } catch (e) {
      if (!_created.isCompleted) _created.completeError(e);
      rethrow;
    }
    _rendererGone = false;
    // After `initialize`: the browser id the size is sent for exists only
    // then. The page is already loading at the default size; CEF re-lays it
    // out on the resize, well before the widget would have asked.
    final presized = _presized;
    if (presized != null && !_disposed) {
      await _controller.resize(presized.$2, presized.$1);
    }
  }

  /// Size and device pixel ratio to lay the page out for before any widget
  /// shows it; see [WebViewSurfacePresizing].
  (Size, double)? _presized;

  @override
  void presize(Size size, double devicePixelRatio) {
    _presized = (size, devicePixelRatio);
  }

  @override
  void repaint() {
    // Before the browser exists there is nothing to ask — and that is the
    // controller's `value`, not `_started`, which [navigate] sets before the
    // create round trip has even begun. After the renderer died there is
    // nothing to answer; the recovery started in `onRenderProcessGone` is
    // what brings that one back.
    if (_disposed || !_controller.value || _rendererGone) return;
    // A page still loading damages constantly and paints on its own; forcing
    // a full-frame raster on top of that stream, on the station's weakest
    // hardware at exactly the moment the load competes for it, buys nothing.
    // The forced frame is for a settled page — the only kind that is quiet.
    if (_load.value.phase != WebViewLoadPhase.shown) return;
    unawaited(_controller.invalidate().catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _controller,
        // False until the browser has a texture to paint. The empty box is
        // deliberate rather than a spinner: WebViewAssetView keeps its
        // loading cover over the tile until [load] says the page is up.
        builder: (context, ready, _) =>
            ready ? _controller.webviewWidget : const SizedBox.expand(),
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _recoveryTimer?.cancel();
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

/// What covers a page that is still coming: the tile's own surface, the site
/// being fetched, and a hairline of progress along the top — the same hairline
/// the chart windows fill in with. A failure swaps the site for "Can't
/// reach", and drops the bar: nothing is coming.
class _LoadingVeil extends StatelessWidget {
  const _LoadingVeil({required this.host, required this.load});

  final String? host;
  final WebViewLoad load;

  @override
  Widget build(BuildContext context) {
    final failed = load.phase == WebViewLoadPhase.failed;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Stack(children: [
        Positioned.fill(
          child: failed
              ? _Glyph(
                  icon: Icons.public_off,
                  caption: host == null ? "Can't reach the page" : "Can't reach $host",
                )
              : _Glyph(icon: Icons.public, caption: host),
        ),
        if (!failed)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2, value: load.progress),
          ),
      ]),
    );
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

/// Trimmed [value], or null when there is nothing left — so clearing a field
/// puts the config back to "unset" and the key back out of the saved JSON.
String? _nullIfBlank(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
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
          const SizedBox(height: 8),
          // Keyed: the value fields below come and go with this one, and
          // without keys a TextFormField further down could be handed the
          // wrong element (and so the wrong text) when they appear.
          TextFormField(
            key: const ValueKey('web-view-theme-param'),
            initialValue: config.themeParam ?? '',
            decoration: const InputDecoration(
              labelText: 'Theme URL parameter',
              hintText: 'theme',
              // Short enough for two lines in the side pane: a longer one
              // was cut at "…" and lost the "empty = off" half.
              helperText: 'For sites like Grafana: sent as dark/light to '
                  'follow the HMI theme. Empty = off.',
              helperMaxLines: 3,
            ),
            onChanged: (value) =>
                setState(() => config.themeParam = _nullIfBlank(value)),
          ),
          if ((config.themeParam ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: const ValueKey('web-view-theme-dark'),
                    initialValue: config.themeDarkValue ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Dark value',
                      hintText: kWebViewThemeDarkDefault,
                    ),
                    onChanged: (value) => setState(
                        () => config.themeDarkValue = _nullIfBlank(value)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    key: const ValueKey('web-view-theme-light'),
                    initialValue: config.themeLightValue ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Light value',
                      hintText: kWebViewThemeLightDefault,
                    ),
                    onChanged: (value) => setState(
                        () => config.themeLightValue = _nullIfBlank(value)),
                  ),
                ),
              ],
            ),
          ],
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
