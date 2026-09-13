/// Starts the browsers behind the page config's web tiles at boot, so the
/// first visit to a dashboard page is a take-back from [WebViewSurfacePool]
/// rather than a cold engine start and page load.
///
/// Measured on a station on 2026-09-13: a cold open of a Grafana tile took
/// 3.8 s, a return to a parked browser 0.45 s. The cold path is the engine
/// coming up and the dashboard's own scripts running, and neither can be
/// hurried; the only way to make the first visit quick is to have already
/// made it. See "Warm browsers" in `web_view.dart`.
///
/// Read once from [BaseScaffold] — the first scaffold to mount is what starts
/// it, and keep-alive means it runs once per app, not once per page. The
/// pool skips addresses that already have a browser, so a station whose
/// startup page *is* the dashboard page, and every later rebuild of the page
/// config, cost nothing extra.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Brightness, Size, ThemeMode;
import 'package:flutter/scheduler.dart';
import 'package:riverpod/riverpod.dart';

import '../core/feature_flags.dart';
import '../page_creator/assets/web_view.dart';
import '../page_creator/page.dart';
import 'page_manager.dart';
import 'theme.dart';

/// How long after the page config is known to wait before starting browsers.
///
/// Boot is busy — OPC UA clients coming up, the first page building — and a
/// browser engine starting on top of it would slow the screen the operator is
/// actually looking at. A couple of seconds later the page has settled, and
/// nobody reaches a dashboard page that fast anyway. It also lets a startup
/// page that carries the tile claim its address first, so this skips it.
const Duration kWebViewPrewarmDelay = Duration(seconds: 2);

/// Every web tile in [pages], in page order.
///
/// Draft pages are included: a page being built over several shifts still
/// wants its dashboard quick when it is published, and one browser is a small
/// price. Pages past the pool's capacity are left cold by the pool itself.
List<WebViewAssetConfig> webViewTilesIn(Map<String, AssetPage> pages) => [
      for (final page in pages.values)
        for (final asset in page.assets)
          if (asset is WebViewAssetConfig) asset,
    ];

/// The brightness a tile would render with under [mode]: the theme it will
/// build its effective URL from, and so the address the parked browser must
/// be on for the take-back to match.
Brightness brightnessFor(ThemeMode mode, {Brightness? platform}) {
  switch (mode) {
    case ThemeMode.light:
      return Brightness.light;
    case ThemeMode.dark:
      return Brightness.dark;
    case ThemeMode.system:
      return platform ??
          SchedulerBinding.instance.platformDispatcher.platformBrightness;
  }
}

/// The number of browsers started so far. Zero until the page config and the
/// theme are known and [kWebViewPrewarmDelay] has passed.
///
/// A plain provider rather than a generated one, like
/// [bootstrapPageManagerProvider]: it has one job and no parameters.
final webViewPrewarmProvider = Provider<int>((ref) {
  if (!kWebViewEnabled) return 0;
  final pagesFuture = ref.watch(pageManagerProvider.future);
  final themeFuture = ref.watch(themeNotifierProvider.future);

  var disposed = false;
  ref.onDispose(() => disposed = true);

  var started = 0;
  () async {
    final PageManager pageManager;
    final ThemeMode mode;
    try {
      pageManager = await pagesFuture;
      mode = await themeFuture;
    } catch (_) {
      // No page config means no tiles to warm; a theme that failed to load
      // would guess the wrong address anyway. Either way the first visit is
      // simply cold, as it always was.
      return;
    }
    await Future<void>.delayed(kWebViewPrewarmDelay);
    if (disposed) return;
    final window = windowViewport();
    started = WebViewSurfacePool.instance.prewarm(
      webViewTilesIn(pageManager.pages),
      brightness: brightnessFor(mode),
      viewport: window?.$1,
      devicePixelRatio: window?.$2 ?? 1.0,
    );
    ref.state = started;
  }();
  return started;
});

/// The main window's logical size and device pixel ratio, or null when there
/// is no window yet. A pre-started browser is laid out for this, so it has
/// loaded every panel a tile could show before the tile exists; see
/// [WebViewSurfacePresizing].
(Size, double)? windowViewport() {
  final views = SchedulerBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return null;
  final view = views.first;
  final ratio = view.devicePixelRatio;
  if (ratio <= 0 || view.physicalSize.isEmpty) return null;
  return (view.physicalSize / ratio, ratio);
}
