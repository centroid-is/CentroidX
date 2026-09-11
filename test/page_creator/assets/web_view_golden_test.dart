import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/web_view.dart';
import 'package:tfc/theme.dart' show solarized;

const _stripKey = Key('web_view_golden');

/// A stand-in for a rendered page, so the "live" tile shows something
/// page-shaped without a browser: a pale sheet with a header bar and a couple
/// of text rules on it.
class _GoldenSurface implements WebViewSurface {
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xFFF6F6F4),
        child: Padding(
          padding: EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 14,
                child: ColoredBox(color: Color(0xFF4A78B5), child: SizedBox.expand()),
              ),
              SizedBox(height: 10),
              SizedBox(
                height: 6,
                width: 120,
                child: ColoredBox(color: Color(0xFFBFBFBA), child: SizedBox.expand()),
              ),
              SizedBox(height: 6),
              SizedBox(
                height: 6,
                width: 90,
                child: ColoredBox(color: Color(0xFFBFBFBA), child: SizedBox.expand()),
              ),
            ],
          ),
        ),
      );

  @override
  Future<void> navigate(Uri uri) async {}

  @override
  Future<void> dispose() async {}
}

/// The four states an operator or a page author can meet, side by side at
/// tile size: unconfigured, the editor-canvas placeholder, a platform with no
/// browser, and a live page.
Widget buildFilmstrip({bool dark = false}) {
  final (light, darkTheme) = solarized();
  final theme = dark ? darkTheme : light;

  Widget tile(Widget child, String caption) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 220, height: 150, child: child),
          const SizedBox(height: 6),
          Text(caption, style: theme.textTheme.bodySmall),
        ],
      );

  WebViewAssetConfig at(String url) => WebViewAssetConfig(url: url);

  return MaterialApp(
    theme: theme,
    home: Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: RepaintBoundary(
          key: _stripKey,
          child: Container(
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                tile(WebViewAssetView(config: WebViewAssetConfig()),
                    'no address'),
                const SizedBox(width: 12),
                tile(
                  AssetEditModeScope(
                    child: WebViewAssetView(config: at('https://grafana.plant/d/a/b')),
                  ),
                  'editor canvas',
                ),
                const SizedBox(width: 12),
                tile(WebViewAssetView(config: at('https://unsupported.plant/x')),
                    'no browser here'),
                const SizedBox(width: 12),
                tile(WebViewAssetView(config: at('https://live.plant/x')),
                    'live page'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Same font dance as rtsp_camera_golden_test — without it the captions and
/// icons render as placeholder blocks.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

void main() {
  setUpAll(_loadFonts);

  tearDown(() => WebViewAssetView.debugSurfaceFactory = null);

  group('web view golden tests',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    Future<void> capture(WidgetTester tester, String name,
        {bool dark = false}) async {
      // One outcome per host, so the strip shows every state at once.
      WebViewAssetView.debugSurfaceFactory = (config) =>
          config.url.contains('unsupported') ? null : _GoldenSurface();
      await tester.pumpWidget(buildFilmstrip(dark: dark));
      await tester.pump();
      await expectLater(
        find.byKey(_stripKey),
        matchesGoldenFile('goldens/$name.png'),
      );
    }

    testWidgets('state filmstrip (light)', (tester) async {
      tester.view.physicalSize = const Size(980, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await capture(tester, 'web_view_states');
    });

    // Dark is not decoration here: the tile border and both glyph captions are
    // drawn from onSurface with an alpha, because neither of our schemes sets
    // colorScheme.outline and the Material fallback vanishes on dark.
    testWidgets('state filmstrip (dark)', (tester) async {
      tester.view.physicalSize = const Size(980, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await capture(tester, 'web_view_states_dark', dark: true);
    });

    testWidgets('config editor form', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (light, _) = solarized();
      final config = WebViewAssetConfig(
        url: 'https://grafana.plant/d/abc123/line-1',
        reloadSeconds: 300,
      )..text = 'Line 1 dashboard';
      await tester.pumpWidget(MaterialApp(
        theme: light,
        home: Scaffold(
          backgroundColor: light.colorScheme.surface,
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));
      await tester.pump();
      await expectLater(
        find.byType(SingleChildScrollView).first,
        matchesGoldenFile('goldens/web_view_config_editor.png'),
      );
    });

    testWidgets('config editor rejects a non-http address', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (light, _) = solarized();
      final config = WebViewAssetConfig(url: 'file:///etc/passwd');
      await tester.pumpWidget(MaterialApp(
        theme: light,
        home: Scaffold(
          backgroundColor: light.colorScheme.surface,
          body: Builder(builder: (context) => config.configure(context)),
        ),
      ));
      await tester.pump();
      await expectLater(
        find.byType(SingleChildScrollView).first,
        matchesGoldenFile('goldens/web_view_config_editor_invalid.png'),
      );
    });
  });
}
