/// A live web page on the HMI canvas.
///
/// This is the real thing — a browser rendering the page, not a screenshot of
/// it — which is why it exists on exactly one of our platforms.
///
/// ## Why macOS only
///
/// `webview_flutter` is a platform-view API, and it ships implementations for
/// Android, iOS and macOS. On macOS that is `webview_flutter_wkwebview`, i.e.
/// WKWebView: the system's browser, out-of-process, patched by the OS. There
/// is nothing to bundle and nothing for us to keep up to date.
///
/// The platforms we actually run on the plant floor have no implementation:
///
///   * **flutter-elinux** — the stations. The embedder *does* have platform
///     views (`FlutterDesktopRegisterPlatformViewFactory`, texture-backed), so
///     a webview is possible here; what is missing is a browser plugin. The
///     candidates are `webview_cef` (which already carries an eLinux port) and
///     WPE WebKit (in Debian, so apt-tracked). Both mean shipping a browser
///     engine on boxes we have to keep patched — a few hundred megabytes and a
///     standing obligation. Not a decision this asset makes.
///   * **Linux desktop / Windows** — possible via WebView2 or CEF, same
///     trade-off, no implementation wired up here.
///   * **Web** — an `<iframe>` would be trivial, but there is no web target.
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

/// The platforms `webview_flutter` has an implementation for.
///
/// Pure and parameterised so the placeholder path is testable on a Mac, where
/// `defaultTargetPlatform` would otherwise always say "supported" and the
/// unsupported branch could only ever be exercised in production.
@visibleForTesting
class WebViewAvailability {
  const WebViewAvailability._();

  static const Set<TargetPlatform> supportedPlatforms = {
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  };

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
    unawaited(surface.navigate(uri).catchError((Object _) {
      // A failed navigation leaves whatever the browser is showing, and
      // re-navigating on the next reload tick is the recovery.
      //
      // Observed on macOS 2026-09-11: an unreachable host leaves the tile
      // *blank white*, not on a browser error page — WKWebView paints nothing
      // for a provisional navigation that never commits. On a wall that reads
      // as a broken tile rather than an unreachable one. Surfacing it
      // properly means the NavigationDelegate (onWebResourceError), not this
      // catch, which only ever sees the channel call failing.
    }));
    _armTimer();
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

/// The real browser: WKWebView on macOS, via `webview_flutter`.
WebViewSurface? _defaultFactory(WebViewAssetConfig config) {
  if (!WebViewAvailability.check()) return null;
  try {
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
