// The web tile's loading cover.
//
// Every engine paints blank white until a page commits, so the tile used to go
// from nothing to a white box -- on a dark HMI, the loudest thing on the
// screen -- with nothing on it to say it was working, and on macOS an
// unreachable host left it white for good. A surface that can say when its
// page is up now gets a themed cover naming the site, with a hairline of
// progress, until it is.

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/web_view.dart';
import 'package:tfc/theme.dart' show solarized;
import '../../helpers/golden_platform.dart';

/// A browser that reports its loading, with the report in the test's hands.
class _LoadingSurface implements WebViewSurface, WebViewSurfaceLoading {
  _LoadingSurface([WebViewLoad initial = const WebViewLoad.loading()])
      : report = ValueNotifier(initial);

  final ValueNotifier<WebViewLoad> report;
  final navigations = <Uri>[];
  bool disposed = false;

  @override
  ValueListenable<WebViewLoad> get load => report;

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-web'));

  @override
  Future<void> navigate(Uri uri) async => navigations.add(uri);

  @override
  Future<void> dispose() async => disposed = true;
}

/// The plain shape: reports nothing about its loading.
class _SilentSurface implements WebViewSurface {
  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-web'));

  @override
  Future<void> navigate(Uri uri) async {}

  @override
  Future<void> dispose() async {}
}

Widget _host(WebViewAssetConfig config) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 240,
            child: WebViewAssetView(config: config),
          ),
        ),
      ),
    );

WebViewAssetConfig _config({int reloadSeconds = 0}) => WebViewAssetConfig(
      url: 'https://grafana.plant/d/abc/line-1',
      reloadSeconds: reloadSeconds,
    );

final _cover = find.text('grafana.plant');
final _cantReach = find.text("Can't reach grafana.plant");
final _bar = find.byType(LinearProgressIndicator);

/// Drops the tile, which cancels its reveal timer; flutter_test fails a test
/// that leaves a timer running.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  tearDown(() => WebViewAssetView.debugSurfaceFactory = null);

  testWidgets('covers the tile with the site until the page is up',
      (tester) async {
    final surface = _LoadingSurface();
    WebViewAssetView.debugSurfaceFactory = (_) => surface;

    await tester.pumpWidget(_host(_config()));
    await tester.pump();

    // The browser is laid out underneath, loading, not held back.
    expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
    expect(surface.navigations, hasLength(1));
    expect(_cover, findsOneWidget);
    expect(_bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(_bar).value, isNull,
        reason: 'no progress reported yet: indeterminate');

    surface.report.value = const WebViewLoad.loading(0.4);
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(_bar).value, 0.4);

    surface.report.value = const WebViewLoad.shown();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_cover, findsNothing, reason: 'the cover outlived the page');
    expect(_bar, findsNothing);
    expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);

    await _dispose(tester);
  });

  testWidgets('a reload does not cover a page that is up', (tester) async {
    final surface = _LoadingSurface();
    WebViewAssetView.debugSurfaceFactory = (_) => surface;

    await tester.pumpWidget(_host(_config(reloadSeconds: 30)));
    await tester.pump();
    surface.report.value = const WebViewLoad.shown();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The tick navigates in place, and the engine reports loading again; the
    // old page stays painted until the new one commits, so it stays visible.
    await tester.pump(const Duration(seconds: 30));
    expect(surface.navigations, hasLength(2));
    surface.report.value = const WebViewLoad.loading(0.1);
    await tester.pump();
    expect(_cover, findsNothing);
    expect(_bar, findsNothing);

    await _dispose(tester);
  });

  testWidgets("a failure with nothing shown says it can't reach the site",
      (tester) async {
    final surface = _LoadingSurface();
    WebViewAssetView.debugSurfaceFactory = (_) => surface;

    await tester.pumpWidget(_host(_config()));
    await tester.pump();
    surface.report.value = const WebViewLoad.failed();
    await tester.pump();

    expect(_cantReach, findsOneWidget);
    expect(find.byIcon(Icons.public_off), findsOneWidget);
    expect(_bar, findsNothing, reason: 'nothing is coming; no progress');

    // A later attempt that gets through lifts it.
    surface.report.value = const WebViewLoad.shown();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_cantReach, findsNothing);

    await _dispose(tester);
  });

  testWidgets('a failure after the page was up is left to the page',
      (tester) async {
    final surface = _LoadingSurface();
    WebViewAssetView.debugSurfaceFactory = (_) => surface;

    await tester.pumpWidget(_host(_config()));
    await tester.pump();
    surface.report.value = const WebViewLoad.shown();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    surface.report.value = const WebViewLoad.failed();
    await tester.pump();
    expect(_cantReach, findsNothing,
        reason: 'the last good page is still painted; the next tick retries');

    await _dispose(tester);
  });

  testWidgets('a slow page is uncovered in time, and covered again on failure',
      (tester) async {
    final surface = _LoadingSurface();
    WebViewAssetView.debugSurfaceFactory = (_) => surface;

    await tester.pumpWidget(_host(_config()));
    await tester.pump();
    surface.report.value = const WebViewLoad.loading(0.6);
    await tester.pump();

    // A dashboard that paints long before the engine calls it finished.
    await tester.pump(kWebViewRevealTimeout);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_cover, findsNothing);

    // ...but a failure with nothing ever shown puts the cover back.
    surface.report.value = const WebViewLoad.failed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_cantReach, findsOneWidget);

    await _dispose(tester);
  });

  testWidgets('a browser that reports nothing is shown at once',
      (tester) async {
    WebViewAssetView.debugSurfaceFactory = (_) => _SilentSurface();

    await tester.pumpWidget(_host(_config()));
    await tester.pump();

    expect(find.byKey(const ValueKey('fake-web')), findsOneWidget);
    expect(_cover, findsNothing);
    expect(_bar, findsNothing);
  });

  testWidgets('a new address covers again; the old browser is not heard',
      (tester) async {
    final surfaces = <_LoadingSurface>[];
    WebViewAssetView.debugSurfaceFactory = (_) {
      final surface = _LoadingSurface();
      surfaces.add(surface);
      return surface;
    };

    final config = _config();
    await tester.pumpWidget(_host(config));
    await tester.pump();
    surfaces.first.report.value = const WebViewLoad.shown();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_cover, findsNothing);

    // The page editor edits the config in place.
    config.url = 'https://other.plant/x';
    await tester.pumpWidget(_host(config));
    await tester.pump();
    expect(surfaces, hasLength(2));
    expect(surfaces.first.disposed, isTrue);
    expect(find.text('other.plant'), findsOneWidget);

    surfaces.first.report.value = const WebViewLoad.shown();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('other.plant'), findsOneWidget,
        reason: "the replaced browser's news lifted the new one's cover");

    await _dispose(tester);
    // After the tile is gone, news is nobody's business and harms nothing.
    surfaces.last.report.value = const WebViewLoad.shown();
  });

  group('web view loading goldens',
      skip: goldenSkip, () {
    setUpAll(() async {
      Future<void> load(String family, String path) async {
        final file = File(path);
        if (!file.existsSync()) return;
        await (FontLoader(family)
              ..addFont(
                  Future.value(ByteData.view(file.readAsBytesSync().buffer))))
            .load();
      }

      await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
      await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot != null) {
        await load('MaterialIcons',
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      }
    });

    // The two faces of the cover side by side at tile size: a page on its way
    // (the bar at a fixed 40 %, so the capture is repeatable) and a host that
    // could not be reached.
    for (final dark in [false, true]) {
      testWidgets('loading cover filmstrip (${dark ? 'dark' : 'light'})',
          (tester) async {
        tester.view.physicalSize = const Size(500, 220);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        WebViewAssetView.debugSurfaceFactory = (config) => _LoadingSurface(
            config.url.contains('unreachable')
                ? const WebViewLoad.failed()
                : const WebViewLoad.loading(0.4));

        final (light, darkTheme) = solarized();
        final theme = dark ? darkTheme : light;
        Widget tile(String url, String caption) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 220,
                  height: 150,
                  child: WebViewAssetView(
                      config: WebViewAssetConfig(url: url)),
                ),
                const SizedBox(height: 6),
                Text(caption, style: theme.textTheme.bodySmall),
              ],
            );

        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            backgroundColor: theme.colorScheme.surface,
            body: Center(
              child: RepaintBoundary(
                key: const Key('web_view_loading'),
                child: Container(
                  color: theme.colorScheme.surface,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tile('https://grafana.plant/d/a/b', 'loading'),
                      const SizedBox(width: 12),
                      tile('https://unreachable.plant/x', "can't reach"),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pump();

        await expectLater(
          find.byKey(const Key('web_view_loading')),
          matchesGoldenFile(
              'goldens/web_view_loading${dark ? '_dark' : ''}.png'),
        );
        await _dispose(tester);
      });
    }
  });
}
