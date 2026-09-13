// The web tiles' browsers are started at boot so the first visit to a
// dashboard page is a take-back from the pool rather than a cold engine start
// and page load. This covers the provider that does the starting: which tiles
// it finds, which brightness it warms for, and that it waits for boot to
// settle.

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tfc/core/feature_flags.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/web_view.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/theme.dart';
import 'package:tfc/providers/web_view_prewarm.dart';
import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;

class _FakeSurface implements WebViewSurface, WebViewSurfacePresizing {
  final navigations = <Uri>[];
  Size? presized;
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  Future<void> navigate(Uri uri) async => navigations.add(uri);
  @override
  Future<void> dispose() async {}
  @override
  void presize(Size size, double devicePixelRatio) => presized = size;
}

AssetPage _page(String path, List<Asset> assets) => AssetPage(
      menuItem: MenuItem(label: path, path: path, icon: Icons.web),
      assets: assets,
      mirroringDisabled: false,
    );

ProviderContainer _container({
  required Map<String, AssetPage> pages,
  ThemeMode mode = ThemeMode.light,
}) {
  final container = ProviderContainer(overrides: [
    pageManagerProvider.overrideWith(
        (ref) async =>
            PageManager(pages: pages, prefs: FakeEditorPreferences())),
    themeNotifierProvider.overrideWith(() => _FixedTheme(mode)),
  ]);
  addTearDown(container.dispose);
  return container;
}

class _FixedTheme extends ThemeNotifier {
  _FixedTheme(this.mode);
  final ThemeMode mode;
  @override
  Future<ThemeMode> build() async => mode;
}

void main() {
  tearDown(() async {
    WebViewAssetView.debugSurfaceFactory = null;
    await WebViewSurfacePool.instance.clear();
    WebViewSurfacePool.instance = WebViewSurfacePool();
    debugDefaultTargetPlatformOverride = null;
  });

  group('webViewTilesIn', () {
    test('finds every web tile across pages and ignores other assets', () {
      final a = WebViewAssetConfig(url: 'https://grafana.plant/d/a');
      final b = WebViewAssetConfig(url: 'https://grafana.plant/d/b');
      final pages = {
        '/one': _page('/one', [ButtonConfig.preview(), a]),
        '/two': _page('/two', [b]),
        '/three': _page('/three', [ButtonConfig.preview()]),
      };
      expect(webViewTilesIn(pages), [a, b]);
    });
  });

  group('brightnessFor', () {
    test('light and dark are themselves; system follows the platform', () {
      expect(brightnessFor(ThemeMode.light, platform: Brightness.dark),
          Brightness.light);
      expect(brightnessFor(ThemeMode.dark, platform: Brightness.light),
          Brightness.dark);
      expect(brightnessFor(ThemeMode.system, platform: Brightness.dark),
          Brightness.dark);
    });
  });

  group('webViewPrewarmProvider', () {
    testWidgets('warms the page config\'s tiles once boot has settled',
        (tester) async {
      if (!kWebViewEnabled) return;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final surfaces = <_FakeSurface>[];
      WebViewAssetView.debugSurfaceFactory = (_) {
        final s = _FakeSurface();
        surfaces.add(s);
        return s;
      };
      final container = _container(
        pages: {
          '/dash': _page('/dash', [
            WebViewAssetConfig(
                url: 'https://grafana.plant/d/abc/line-1', themeParam: 'theme'),
          ]),
        },
        mode: ThemeMode.dark,
      );

      expect(container.read(webViewPrewarmProvider), 0);
      await tester.pump();
      expect(surfaces, isEmpty, reason: 'boot is busy; the pool waits');

      await tester.pump(kWebViewPrewarmDelay);
      await tester.pump();

      expect(container.read(webViewPrewarmProvider), 1);
      expect(surfaces.single.navigations.single.toString(),
          'https://grafana.plant/d/abc/line-1?theme=dark');
      expect(WebViewSurfacePool.instance.urls,
          ['https://grafana.plant/d/abc/line-1?theme=dark']);
      // The test binding's window is 800 x 600 logical; the browser is laid
      // out for it before the tile exists.
      expect(surfaces.single.presized, const Size(800, 600));
      // The widget binding checks foundation debug variables before tearDown
      // runs, so a widget test resets this itself.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a page config with no web tiles starts nothing',
        (tester) async {
      if (!kWebViewEnabled) return;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var built = 0;
      WebViewAssetView.debugSurfaceFactory = (_) {
        built++;
        return _FakeSurface();
      };
      final container = _container(
        pages: {'/home': _page('/home', [ButtonConfig.preview()])},
      );

      container.read(webViewPrewarmProvider);
      await tester.pump(kWebViewPrewarmDelay);
      await tester.pump();

      expect(built, 0);
      expect(container.read(webViewPrewarmProvider), 0);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
