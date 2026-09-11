/// A Grafana panel on the page, rendered server-side to a PNG.
///
/// Grafana is not embedded — it is photographed. The asset asks Grafana's
/// `/render/d-solo/…` endpoint for a picture of one panel and paints the
/// bytes, then asks again on a timer. Nothing about it is a browser.
///
/// That is a trade, not a limitation of the platform. An earlier version of
/// this comment claimed flutter-elinux has no platform views; it does.
/// `plugins/platform_views_plugin.cc` serves the `flutter/platform_views`
/// channel (create / dispose / resize / touch / offset) and
/// `public/flutter_platform_views.h` exposes
/// `FlutterDesktopRegisterPlatformViewFactory`, whose views are
/// texture-backed — `SetTextureId` plus `Touch(device_id, type, x, y)`. So a
/// webview on a station clips, transforms and z-orders like any other
/// widget. What was missing was a browser plugin, and `webview_cef` now
/// declares `elinux` alongside macOS, Windows and Linux.
///
/// The reasons to photograph rather than embed are therefore about cost, not
/// possibility:
///
///   * Rendering is still a software copy either way — flutter-elinux gives
///     plugins no EGL context, the wall `package:media_kit_video_elinux`
///     already hit.
///   * A browser is 200–500 MB on the station image and a thing to keep
///     patched on the plant floor.
///   * No single engine covers the fleet: WKWebView on macOS, WebView2 on
///     Windows, CEF or WPE on eLinux, an iframe on web — four engines
///     drawing the same dashboard four slightly different ways.
///
/// A PNG needs no native code and renders identically everywhere, which is
/// why it is the default path. A webview asset, if one is ever written,
/// should be opt-in beside this rather than a replacement for it.
///
/// The cost is that the panel is a picture: no hover, no zoom, no
/// drag-to-select a time range. For a wall-mounted station that is usually
/// nothing.
///
/// ## What the Grafana server needs
///
/// The `grafana-image-renderer` plugin must be installed there — it is what
/// serves `/render`. Without it Grafana answers 500 "Rendering plugin not
/// found", which [describeGrafanaFailure] turns into that sentence rather
/// than a bare status code. The headless Chromium the plugin runs lives on
/// the Grafana host, not on the station.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:json_annotation/json_annotation.dart';

import 'common.dart';

part 'grafana_panel.g.dart';

/// Which Grafana theme to render in. [auto] follows the HMI's own theme, so a
/// station switched to dark mode does not keep a white rectangle on the wall.
enum GrafanaPanelTheme { auto, light, dark }

@JsonSerializable(explicitToJson: true)
class GrafanaPanelConfig extends BaseAsset {
  @override
  String get displayName => 'Grafana panel';
  @override
  String get category => 'Visualization';
  @override
  List<String> get searchKeywords => const [
        'grafana',
        'dashboard',
        'trend',
        'metrics',
        'chart',
        'graph',
        'plot',
        'panel',
      ];

  /// Grafana's root URL, e.g. `http://10.104.60.81:3000`. A path is kept, so
  /// a Grafana behind a reverse proxy at `https://plant/grafana` works.
  @JsonKey(name: 'base_url')
  String baseUrl;

  /// Dashboard UID — the `abc123` in `/d/abc123/my-dashboard`.
  @JsonKey(name: 'dashboard_uid')
  String dashboardUid;

  /// The slug after the UID. Cosmetic: Grafana resolves the dashboard by UID
  /// alone, so an empty slug renders the same panel.
  @JsonKey(name: 'dashboard_slug')
  String dashboardSlug;

  /// Which panel of the dashboard. Null means not configured yet.
  @JsonKey(name: 'panel_id')
  int? panelId;

  @JsonKey(name: 'org_id')
  int orgId;

  /// Grafana time-range expressions, the same strings the browser URL carries
  /// (`now-6h`, `now`, or an epoch-millis number).
  String from;
  String to;

  /// IANA zone the panel's axis is labelled in, e.g. `Atlantic/Reykjavik`.
  /// Empty leaves it to the Grafana server — whose clock is not necessarily
  /// the plant's.
  String timezone;

  /// Dashboard template variables, without the `var-` prefix
  /// (`{'machine': 'BER01'}` renders `&var-machine=BER01`).
  Map<String, String> variables;

  /// Free-form query parameters appended to the render URL verbatim, for the
  /// corners of Grafana this asset does not model: `kiosk`, `fullPageImage`,
  /// a longer renderer `timeout`, a `refresh`, anything a future Grafana
  /// adds.
  ///
  /// These are applied **last and win**, so a parameter the asset already
  /// computes can be overridden by naming it here — including `width`,
  /// `height`, `theme` and `panelId`. That is the point of the escape hatch,
  /// and also the way to break it: an `extra_params` entry that shadows one
  /// of those is on the person who typed it.
  @JsonKey(name: 'extra_params')
  Map<String, String> extraParams;

  /// Seconds between refreshes; 0 renders once and leaves it.
  @JsonKey(name: 'refresh_seconds')
  int refreshSeconds;

  GrafanaPanelTheme theme;

  /// Service-account token for Grafana, sent as a bearer token. Leave empty
  /// where the Grafana allows anonymous viewing.
  ///
  /// This is stored in the page config in clear, exactly like the credentials
  /// in an RTSP camera's stream URL — page JSON is not a secret store. Use a
  /// service account with Viewer permission and nothing more.
  @JsonKey(name: 'api_token')
  String apiToken;

  GrafanaPanelConfig({
    this.baseUrl = '',
    this.dashboardUid = '',
    this.dashboardSlug = '',
    this.panelId,
    this.orgId = 1,
    this.from = 'now-6h',
    this.to = 'now',
    this.timezone = '',
    Map<String, String>? variables,
    Map<String, String>? extraParams,
    this.refreshSeconds = 60,
    this.theme = GrafanaPanelTheme.auto,
    this.apiToken = '',
  })  : variables = variables ?? <String, String>{},
        extraParams = extraParams ?? <String, String>{} {
    size = const RelativeSize(width: 0.3, height: 0.22);
  }

  GrafanaPanelConfig.preview()
      : baseUrl = '',
        dashboardUid = '',
        dashboardSlug = '',
        panelId = null,
        orgId = 1,
        from = 'now-6h',
        to = 'now',
        timezone = '',
        variables = <String, String>{},
        extraParams = <String, String>{},
        refreshSeconds = 60,
        theme = GrafanaPanelTheme.auto,
        apiToken = '' {
    size = const RelativeSize(width: 0.3, height: 0.22);
  }

  factory GrafanaPanelConfig.fromJson(Map<String, dynamic> json) =>
      _$GrafanaPanelConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$GrafanaPanelConfigToJson(this);

  /// Enough of a Grafana URL to render something.
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      dashboardUid.trim().isNotEmpty &&
      panelId != null;

  /// Copies everything a pasted browser URL carried onto this config.
  void applyLink(GrafanaPanelLink link) {
    baseUrl = link.baseUrl;
    dashboardUid = link.dashboardUid;
    dashboardSlug = link.dashboardSlug;
    if (link.panelId != null) panelId = link.panelId;
    if (link.orgId != null) orgId = link.orgId!;
    if (link.from != null) from = link.from!;
    if (link.to != null) to = link.to!;
    if (link.timezone != null) timezone = link.timezone!;
    if (link.variables.isNotEmpty) {
      variables = Map<String, String>.from(link.variables);
    }
  }

  @override
  Widget build(BuildContext context) => GrafanaPanelView(config: this);

  @override
  Widget configure(BuildContext context) =>
      _GrafanaPanelConfigEditor(config: this);
}

/// What a Grafana browser URL told us.
///
/// Nobody types a dashboard UID. The config pane takes the URL out of the
/// address bar — or Grafana's own "Share > Link" — and this pulls it apart.
class GrafanaPanelLink {
  final String baseUrl;
  final String dashboardUid;
  final String dashboardSlug;
  final int? panelId;
  final int? orgId;
  final String? from;
  final String? to;
  final String? timezone;
  final Map<String, String> variables;

  const GrafanaPanelLink({
    required this.baseUrl,
    required this.dashboardUid,
    this.dashboardSlug = '',
    this.panelId,
    this.orgId,
    this.from,
    this.to,
    this.timezone,
    this.variables = const {},
  });
}

/// Parses a Grafana dashboard or panel URL, or null if it is not one.
///
/// Handles the three shapes that turn up in practice:
///
///   * `…/d/<uid>/<slug>?viewPanel=3` — a panel opened full-screen
///   * `…/d/<uid>/<slug>?viewPanel=panel-3` — the same in Grafana 11's scenes
///   * `…/d-solo/<uid>/<slug>?panelId=3` — what "Share > Embed" hands out
///
/// Anything before the `/d/` segment is kept as the base URL, so a Grafana
/// proxied under a subpath survives the round trip.
GrafanaPanelLink? parseGrafanaPanelLink(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final marker = segments.indexWhere((s) => s == 'd' || s == 'd-solo');
  if (marker < 0 || marker + 1 >= segments.length) return null;

  final uid = segments[marker + 1];
  if (uid.isEmpty) return null;
  final slug = marker + 2 < segments.length ? segments[marker + 2] : '';

  // Everything left of the `/d/` marker is Grafana's own root. Built field by
  // field rather than with `Uri.replace`, whose null arguments mean "keep the
  // original" — the query and fragment have to go, not survive.
  final prefix = segments.take(marker).join('/');
  final base = Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: prefix.isEmpty ? '' : '/$prefix',
  );

  final query = uri.queryParameters;
  final variables = <String, String>{};
  for (final entry in query.entries) {
    if (!entry.key.startsWith('var-')) continue;
    final name = entry.key.substring(4);
    if (name.isEmpty || entry.value.isEmpty) continue;
    // Uri.queryParameters keeps the last value of a repeated key, so a
    // multi-value template variable arrives here as one of its values. That
    // is the honest limit of a Map<String, String> config; a panel that needs
    // several values for one variable has to be shared as a d-solo link with
    // them already applied.
    variables[name] = entry.value;
  }

  return GrafanaPanelLink(
    // `toString()` on a Uri with an empty path gives a bare origin.
    baseUrl: base.toString().replaceAll(RegExp(r'/+$'), ''),
    dashboardUid: uid,
    dashboardSlug: slug,
    panelId: parseGrafanaPanelId(query['viewPanel'] ?? query['panelId']),
    orgId: int.tryParse(query['orgId'] ?? ''),
    from: query['from'],
    to: query['to'],
    timezone: query['timezone'],
    variables: variables,
  );
}

/// Panel ids reach us as `3` or, since Grafana 11's scenes rewrite,
/// `panel-3`. The render endpoint wants the number either way.
int? parseGrafanaPanelId(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  final digits =
      trimmed.startsWith('panel-') ? trimmed.substring(6) : trimmed;
  return int.tryParse(digits);
}

/// Builds the `/render/d-solo` URL for one panel, or null when the config is
/// not complete enough to render anything.
///
/// [scale] is the renderer's device pixel ratio. It is omitted at 1.0 — which
/// is what the stations run at — so the common URL carries no parameter that
/// an older `grafana-image-renderer` might not know.
Uri? buildGrafanaRenderUri({
  required String baseUrl,
  required String dashboardUid,
  required int? panelId,
  String dashboardSlug = '',
  int orgId = 1,
  String from = 'now-6h',
  String to = 'now',
  String timezone = '',
  Map<String, String> variables = const {},
  Map<String, String> extraParams = const {},
  required int width,
  required int height,
  double scale = 1.0,
  required String theme,
}) {
  final uid = dashboardUid.trim();
  if (uid.isEmpty || panelId == null) return null;

  final base = Uri.tryParse(baseUrl.trim());
  if (base == null || base.host.isEmpty) return null;
  if (base.scheme != 'http' && base.scheme != 'https') return null;

  final slug = dashboardSlug.trim();
  final segments = <String>[
    ...base.pathSegments.where((s) => s.isNotEmpty),
    'render',
    'd-solo',
    uid,
    if (slug.isNotEmpty) slug,
  ];

  return base.removeFragment().replace(
    pathSegments: segments,
    queryParameters: <String, String>{
      'orgId': '$orgId',
      'panelId': '$panelId',
      'from': from,
      'to': to,
      'width': '$width',
      'height': '$height',
      'theme': theme,
      if (timezone.trim().isNotEmpty) 'timezone': timezone.trim(),
      if (scale > 1.0) 'scale': _trimScale(scale),
      for (final entry in variables.entries)
        if (entry.key.isNotEmpty) 'var-${entry.key}': entry.value,
      // Last, so a named parameter overrides the computed one — see
      // [GrafanaPanelConfig.extraParams].
      for (final entry in extraParams.entries)
        if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value,
    },
  );
}

String _trimScale(double scale) {
  final text = scale.toStringAsFixed(2);
  return text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

/// True when [bytes] start with the PNG signature.
///
/// Worth checking because the most confusing failure answers 200: a Grafana
/// behind an SSO proxy hands back a login page, and without this the asset
/// would report "could not decode image" about a perfectly good HTML
/// document.
bool looksLikePng(List<int> bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

/// Turns a failed render into a sentence that names the fix.
///
/// The status code alone is not actionable — every one of these has a
/// different thing to go and do, and the operator seeing the tile is rarely
/// the person who knows Grafana.
String describeGrafanaFailure(int statusCode, String body) {
  final lower = body.toLowerCase();
  if (lower.contains('rendering plugin not found') ||
      lower.contains('image renderer plugin not found')) {
    return 'Grafana has no image renderer. Install the '
        'grafana-image-renderer plugin on the Grafana server.';
  }
  switch (statusCode) {
    case 401:
      return 'Grafana refused the request (401). Add a service-account '
          'token below, or allow anonymous viewing.';
    case 403:
      return 'Grafana refused the request (403). The token is valid but '
          'lacks Viewer access to this dashboard.';
    case 404:
      return 'No such dashboard or panel (404). Check the UID and panel id.';
    case 500:
      final detail = _firstLine(body);
      return detail.isEmpty
          ? 'Grafana failed to render the panel (500).'
          : 'Grafana failed to render the panel (500): $detail';
    default:
      return 'Grafana returned $statusCode.';
  }
}

String _firstLine(String body) {
  final line = body.trim().split('\n').first.trim();
  return line.length > 160 ? '${line.substring(0, 157)}…' : line;
}

/// Raised by a [GrafanaImageFetcher] that could not produce a picture. The
/// message is shown to the operator, so it is written for one.
class GrafanaRenderException implements Exception {
  final String message;
  const GrafanaRenderException(this.message);
  @override
  String toString() => message;
}

/// Fetches one rendered panel. Abstracted so tests never open a socket.
typedef GrafanaImageFetcher = Future<Uint8List> Function(
  Uri uri,
  Map<String, String> headers,
);

/// How long one render may take. Generous: Grafana's own renderer waits for
/// every query in the panel before it screenshots anything.
const Duration _renderTimeout = Duration(seconds: 30);

/// The real fetch: everything between "ask Grafana" and "here are the
/// bytes", including which failures become which sentence.
///
/// [client] exists so this is reachable from a test with a `MockClient`.
/// Without it the whole network path — the status mapping, the timeout, the
/// PNG check — would only ever run in production, since the widget tests all
/// replace the fetcher wholesale.
@visibleForTesting
Future<Uint8List> grafanaHttpFetch(
  Uri uri,
  Map<String, String> headers, {
  http.Client? client,
}) async {
  final owned = client == null;
  final http.Client transport = client ?? http.Client();
  http.Response response;
  try {
    response =
        await transport.get(uri, headers: headers).timeout(_renderTimeout);
  } on TimeoutException {
    throw GrafanaRenderException(
        'Grafana did not answer within ${_renderTimeout.inSeconds} s.');
  } on GrafanaRenderException {
    rethrow;
  } catch (e) {
    throw GrafanaRenderException('Cannot reach Grafana: $e');
  } finally {
    if (owned) transport.close();
  }
  if (response.statusCode != 200) {
    throw GrafanaRenderException(
        describeGrafanaFailure(response.statusCode, response.body));
  }
  final bytes = response.bodyBytes;
  if (!looksLikePng(bytes)) {
    throw const GrafanaRenderException(
        'Grafana returned a page instead of an image — the URL is probably '
        'being redirected to a login screen.');
  }
  return bytes;
}

/// Render requests are quantised to this many logical pixels, so nudging an
/// asset a pixel wide in the editor does not fire a render per frame.
const int _sizeQuantum = 32;

/// Falls back to [fallback] for an unbounded or degenerate constraint —
/// which is not the same as the clamp floor: a panel in an unbounded box
/// should ask for a readable picture, not the smallest legal one.
int _quantise(double value,
    {required int min, required int max, required int fallback}) {
  if (!value.isFinite || value <= 0) return fallback;
  final stepped = (value / _sizeQuantum).ceil() * _sizeQuantum;
  return stepped.clamp(min, max);
}

class GrafanaPanelView extends StatefulWidget {
  final GrafanaPanelConfig config;
  const GrafanaPanelView({super.key, required this.config});

  /// Test hook: replaces the HTTP fetch. Reset to null in tearDown.
  @visibleForTesting
  static GrafanaImageFetcher? debugFetcher;

  @override
  State<GrafanaPanelView> createState() => _GrafanaPanelViewState();
}

class _GrafanaPanelViewState extends State<GrafanaPanelView> {
  /// The last picture that arrived. Kept across a failed refresh: a panel
  /// that is showing real numbers should not go blank because one poll timed
  /// out — it goes stale, and says so.
  Uint8List? _bytes;
  String? _error;
  bool _loading = false;

  /// Guards against a refresh interval shorter than a render: a tick that
  /// lands while a fetch is in flight is dropped, not queued.
  bool _inFlight = false;

  Uri? _lastUri;
  Timer? _timer;

  @override
  void didUpdateWidget(GrafanaPanelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _restartTimer();
    // The token is sent in a header, not in the URL, so a corrected token
    // leaves [_requestRender] with nothing to notice — and a panel stuck on
    // "Grafana refused the request (401)" would stay stuck until the next
    // tick, or forever at refreshSeconds 0. Re-ask immediately instead.
    if (oldWidget.config.apiToken.trim() != widget.config.apiToken.trim()) {
      final uri = _lastUri;
      if (uri != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fetch(uri);
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    final seconds = widget.config.refreshSeconds;
    if (seconds <= 0) return;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      final uri = _lastUri;
      if (uri != null) _fetch(uri);
    });
  }

  /// Called from the layout pass, so the actual work is deferred to after the
  /// frame — [setState] during layout is not allowed.
  void _requestRender(Uri uri) {
    if (uri == _lastUri) return;
    _lastUri = uri;
    _restartTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fetch(uri);
    });
  }

  Future<void> _fetch(Uri uri) async {
    if (_inFlight) return;
    _inFlight = true;
    if (mounted) setState(() => _loading = true);
    final fetcher = GrafanaPanelView.debugFetcher ?? grafanaHttpFetch;
    final headers = <String, String>{
      'Accept': 'image/png',
      if (widget.config.apiToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${widget.config.apiToken.trim()}',
    };
    try {
      final bytes = await fetcher(uri, headers);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is GrafanaRenderException ? e.message : e.toString();
      });
    } finally {
      _inFlight = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  String _resolveTheme(BuildContext context) {
    switch (widget.config.theme) {
      case GrafanaPanelTheme.light:
        return 'light';
      case GrafanaPanelTheme.dark:
        return 'dark';
      case GrafanaPanelTheme.auto:
        return Theme.of(context).brightness == Brightness.dark
            ? 'dark'
            : 'light';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = widget.config;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: !config.isConfigured
          ? const _Glyph(
              icon: Icons.insert_chart_outlined,
              caption: 'No panel selected',
            )
          : LayoutBuilder(builder: (context, constraints) {
              final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
              final width =
                  _quantise(constraints.maxWidth, min: 128, max: 2000, fallback: 640);
              final height =
                  _quantise(constraints.maxHeight, min: 96, max: 2000, fallback: 400);
              final uri = buildGrafanaRenderUri(
                baseUrl: config.baseUrl,
                dashboardUid: config.dashboardUid,
                dashboardSlug: config.dashboardSlug,
                panelId: config.panelId,
                orgId: config.orgId,
                from: config.from,
                to: config.to,
                timezone: config.timezone,
                variables: config.variables,
                extraParams: config.extraParams,
                width: width,
                height: height,
                scale: dpr.clamp(1.0, 2.0),
                theme: _resolveTheme(context),
              );
              if (uri == null) {
                return const _Glyph(
                  icon: Icons.link_off,
                  caption: 'Grafana URL is not valid',
                );
              }
              _requestRender(uri);
              // `_content` expands to fill, which an unbounded constraint
              // cannot satisfy — a `Stack(fit: expand)` under an infinite
              // width throws during layout, and a layout exception on the
              // canvas takes the whole page with it. Where the parent
              // declines to bound us, stand on the size we just asked
              // Grafana to render.
              return SizedBox(
                width: constraints.hasBoundedWidth ? null : width.toDouble(),
                height:
                    constraints.hasBoundedHeight ? null : height.toDouble(),
                child: _content(context),
              );
            }),
    );
  }

  Widget _content(BuildContext context) {
    final bytes = _bytes;
    final error = _error;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          Opacity(
            // A stale picture is dimmed rather than hidden: the numbers on it
            // were true a minute ago, which beats an empty box, but nobody
            // should read it as live.
            opacity: error == null ? 1.0 : 0.45,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          )
        else if (error == null)
          const SizedBox.expand()
        else
          _Glyph(icon: Icons.error_outline, caption: error),
        if (error != null && bytes != null)
          const Positioned(top: 6, right: 6, child: _StaleBadge()),
        if (_loading && bytes == null)
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

/// Centred icon and caption, sized off the box like the image and camera
/// assets' placeholders — a glyph is a font glyph, so scaling it with a
/// `FittedBox` would resample it the way text resamples.
class _Glyph extends StatelessWidget {
  final IconData icon;
  final String? caption;
  const _Glyph({required this.icon, this.caption});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
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
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}

/// Marks a picture that is still on screen but no longer refreshing.
class _StaleBadge extends StatelessWidget {
  const _StaleBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'STALE',
        style: TextStyle(
          color: Colors.white70,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _GrafanaPanelConfigEditor extends StatefulWidget {
  final GrafanaPanelConfig config;
  const _GrafanaPanelConfigEditor({required this.config});

  @override
  State<_GrafanaPanelConfigEditor> createState() =>
      _GrafanaPanelConfigEditorState();
}

class _GrafanaPanelConfigEditorState extends State<_GrafanaPanelConfigEditor> {
  GrafanaPanelConfig get config => widget.config;

  final _pasteController = TextEditingController();

  /// Bumped whenever [applyLink] rewrites the fields, so the `TextFormField`s
  /// below rebuild from their new `initialValue` instead of keeping the text
  /// the operator can see is now wrong.
  int _revision = 0;

  String? _pasteError;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  void _applyPastedLink() {
    final link = parseGrafanaPanelLink(_pasteController.text);
    if (link == null) {
      setState(() => _pasteError =
          'Not a Grafana panel URL. Copy it from the browser address bar '
          'with the panel open.');
      return;
    }
    setState(() {
      config.applyLink(link);
      _pasteError = link.panelId == null
          ? 'Dashboard found, but the URL names no panel — open one panel '
              'full-screen first, then copy the URL.'
          : null;
      _pasteController.clear();
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _pasteController,
            decoration: InputDecoration(
              labelText: 'Paste a Grafana panel URL',
              hintText: 'http://grafana:3000/d/abc123/line-1?viewPanel=3',
              errorText: _pasteError,
              suffixIcon: IconButton(
                icon: const Icon(Icons.download_done),
                tooltip: 'Fill the fields below from this URL',
                onPressed: _applyPastedLink,
              ),
            ),
            onSubmitted: (_) => _applyPastedLink(),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: ValueKey('base-url-$_revision'),
            initialValue: config.baseUrl,
            decoration: const InputDecoration(
              labelText: 'Grafana URL',
              hintText: 'http://10.104.60.81:3000',
            ),
            onChanged: (value) => setState(() => config.baseUrl = value.trim()),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: ValueKey('uid-$_revision'),
                  initialValue: config.dashboardUid,
                  decoration: const InputDecoration(labelText: 'Dashboard UID'),
                  onChanged: (value) =>
                      setState(() => config.dashboardUid = value.trim()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  key: ValueKey('panel-$_revision'),
                  initialValue: config.panelId?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Panel id'),
                  onChanged: (value) => setState(
                      () => config.panelId = parseGrafanaPanelId(value)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Time range', style: theme.textTheme.titleMedium),
          DropdownButton<GrafanaQuickRange?>(
            value: matchGrafanaQuickRange(config.from, config.to),
            isExpanded: true,
            onChanged: (range) {
              if (range == null) return; // "Custom" is a label, not a choice
              setState(() {
                config.from = range.from;
                config.to = range.to;
                // The From/To fields below seed from `initialValue`, so they
                // need a new key to show what was just picked.
                _revision++;
              });
            },
            items: [
              // Only offered when it is what we have: picking "Custom" from
              // a list cannot mean anything until the fields say what it is.
              if (matchGrafanaQuickRange(config.from, config.to) == null)
                const DropdownMenuItem<GrafanaQuickRange?>(
                  value: null,
                  child: Text('Custom'),
                ),
              for (final range in grafanaQuickRanges)
                DropdownMenuItem<GrafanaQuickRange?>(
                  value: range,
                  child: Text(range.label),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('from-$_revision'),
                  initialValue: config.from,
                  decoration: const InputDecoration(
                      labelText: 'From', hintText: 'now-6h'),
                  onChanged: (value) =>
                      setState(() => config.from = value.trim()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  key: ValueKey('to-$_revision'),
                  initialValue: config.to,
                  decoration:
                      const InputDecoration(labelText: 'To', hintText: 'now'),
                  onChanged: (value) => setState(() => config.to = value.trim()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('timezone-$_revision'),
            initialValue: config.timezone,
            decoration: const InputDecoration(
              labelText: 'Timezone',
              hintText: 'Atlantic/Reykjavik — blank uses the Grafana server',
            ),
            onChanged: (value) => setState(() => config.timezone = value.trim()),
          ),
          const SizedBox(height: 16),
          Text('Refresh', style: theme.textTheme.titleMedium),
          DropdownButton<int>(
            value: _refreshChoices.contains(config.refreshSeconds)
                ? config.refreshSeconds
                : 60,
            isExpanded: true,
            onChanged: (value) =>
                setState(() => config.refreshSeconds = value ?? 60),
            items: _refreshChoices
                .map((s) => DropdownMenuItem<int>(
                    value: s, child: Text(_describeRefresh(s))))
                .toList(),
          ),
          const SizedBox(height: 8),
          Text('Theme', style: theme.textTheme.titleMedium),
          DropdownButton<GrafanaPanelTheme>(
            value: config.theme,
            isExpanded: true,
            onChanged: (value) =>
                setState(() => config.theme = value ?? GrafanaPanelTheme.auto),
            items: GrafanaPanelTheme.values
                .map((t) => DropdownMenuItem<GrafanaPanelTheme>(
                      value: t,
                      child: Text(t == GrafanaPanelTheme.auto
                          ? 'auto (follow the HMI)'
                          : t.name),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          _KeyValueRowsField(
            key: ValueKey('vars-$_revision'),
            title: 'Dashboard variables',
            subtitle: 'Sent as var-<name>. These are the dashboard\'s own '
                'template variables.',
            nameLabel: 'name',
            addLabel: 'Add variable',
            removeTooltip: 'Remove variable',
            entries: config.variables,
            onChanged: (next) => setState(() => config.variables = next),
          ),
          const SizedBox(height: 16),
          _KeyValueRowsField(
            key: ValueKey('params-$_revision'),
            title: 'Render parameters',
            subtitle: 'Appended to the render URL verbatim (kiosk, timeout, '
                'refresh, …). Applied last, so naming one the asset already '
                'sets overrides it.',
            nameLabel: 'parameter',
            addLabel: 'Add parameter',
            removeTooltip: 'Remove parameter',
            entries: config.extraParams,
            onChanged: (next) => setState(() => config.extraParams = next),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: ValueKey('token-$_revision'),
            initialValue: config.apiToken,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Service-account token',
              helperText: 'Stored in the page config in clear. Viewer only.',
              helperMaxLines: 2,
            ),
            onChanged: (value) =>
                setState(() => config.apiToken = value.trim()),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: ValueKey('label-$_revision'),
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

/// A named `from`/`to` pair, in Grafana's own relative vocabulary.
///
/// Relative and not absolute on purpose: a panel on a wall wants a window
/// that rolls forward with the shift, not a range frozen at the moment
/// somebody configured the page. `now-6h` re-evaluates on every render;
/// a pair of timestamps would age.
class GrafanaQuickRange {
  final String label;
  final String from;
  final String to;
  const GrafanaQuickRange(this.label, this.from, this.to);
}

/// The ranges the picker offers, in Grafana's order and wording so the two
/// screens agree. `/d` is Grafana's round-to-start-of-day, which is what
/// makes "Today" mean the day rather than the last 24 hours.
const List<GrafanaQuickRange> grafanaQuickRanges = [
  GrafanaQuickRange('Last 5 minutes', 'now-5m', 'now'),
  GrafanaQuickRange('Last 15 minutes', 'now-15m', 'now'),
  GrafanaQuickRange('Last 30 minutes', 'now-30m', 'now'),
  GrafanaQuickRange('Last 1 hour', 'now-1h', 'now'),
  GrafanaQuickRange('Last 3 hours', 'now-3h', 'now'),
  GrafanaQuickRange('Last 6 hours', 'now-6h', 'now'),
  GrafanaQuickRange('Last 12 hours', 'now-12h', 'now'),
  GrafanaQuickRange('Last 24 hours', 'now-24h', 'now'),
  GrafanaQuickRange('Last 2 days', 'now-2d', 'now'),
  GrafanaQuickRange('Last 7 days', 'now-7d', 'now'),
  GrafanaQuickRange('Last 30 days', 'now-30d', 'now'),
  GrafanaQuickRange('Today', 'now/d', 'now/d'),
  GrafanaQuickRange('Yesterday', 'now-1d/d', 'now-1d/d'),
  GrafanaQuickRange('This week', 'now/w', 'now/w'),
];

/// The quick range [from]/[to] name, or null when the pair is hand-written
/// — in which case the picker shows "Custom" and the raw fields carry it.
GrafanaQuickRange? matchGrafanaQuickRange(String from, String to) {
  final f = from.trim();
  final t = to.trim();
  for (final range in grafanaQuickRanges) {
    if (range.from == f && range.to == t) return range;
  }
  return null;
}

const List<int> _refreshChoices = [0, 10, 30, 60, 300, 900];

String _describeRefresh(int seconds) {
  if (seconds == 0) return 'never (render once)';
  if (seconds < 60) return 'every $seconds s';
  final minutes = seconds ~/ 60;
  return 'every $minutes min';
}

/// One editable row. Carries its own id so the `TextFormField`s can be keyed
/// by identity rather than by position: without that, removing the first of
/// two rows leaves the removed row's text sitting in the reused field, and
/// the pane shows values that are no longer in the map.
class _KeyValueRow {
  _KeyValueRow(this.id, this.name, this.value);
  final int id;
  String name;
  String value;
}

/// Editable `name = value` rows over a `Map<String, String>`.
///
/// Used twice: once for the dashboard's template variables (which reach the
/// URL with a `var-` prefix) and once for free-form render parameters (which
/// reach it verbatim).
class _KeyValueRowsField extends StatefulWidget {
  final Map<String, String> entries;
  final ValueChanged<Map<String, String>> onChanged;
  final String title;
  final String? subtitle;
  final String nameLabel;
  final String addLabel;
  final String removeTooltip;

  const _KeyValueRowsField({
    super.key,
    required this.entries,
    required this.onChanged,
    required this.title,
    required this.nameLabel,
    required this.addLabel,
    required this.removeTooltip,
    this.subtitle,
  });

  @override
  State<_KeyValueRowsField> createState() => _KeyValueRowsFieldState();
}

class _KeyValueRowsFieldState extends State<_KeyValueRowsField> {
  late final List<_KeyValueRow> _rows = [
    for (final entry in widget.entries.entries)
      _KeyValueRow(_nextId++, entry.key, entry.value),
  ];

  int _nextId = 0;

  void _publish() {
    final next = <String, String>{};
    for (final row in _rows) {
      final name = row.name.trim();
      if (name.isEmpty) continue;
      next[name] = row.value;
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.title, style: theme.textTheme.titleMedium),
        if (widget.subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child: Text(
              widget.subtitle!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        for (final row in _rows)
          Padding(
            key: ValueKey(row.id),
            padding: const EdgeInsets.only(top: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('name-${row.id}'),
                    initialValue: row.name,
                    decoration:
                        InputDecoration(labelText: widget.nameLabel),
                    onChanged: (value) {
                      row.name = value;
                      _publish();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('value-${row.id}'),
                    initialValue: row.value,
                    decoration: const InputDecoration(labelText: 'value'),
                    onChanged: (value) {
                      row.value = value;
                      _publish();
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: widget.removeTooltip,
                  onPressed: () {
                    setState(() => _rows.remove(row));
                    _publish();
                  },
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _rows.add(_KeyValueRow(_nextId++, '', ''))),
            icon: const Icon(Icons.add),
            label: Text(widget.addLabel),
          ),
        ),
      ],
    );
  }
}
