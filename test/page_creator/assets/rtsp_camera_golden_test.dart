import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/rtsp_camera.dart';
import 'package:tfc/theme.dart' show solarized;
import '../../helpers/golden_platform.dart';

const _stripKey = Key('rtsp_camera_golden');

/// A stand-in video frame so the "live" tile shows something camera-like
/// without a real decoder: a dusky gradient under the LIVE badge.
class _GoldenPlayback implements RtspCameraPlayback {
  _GoldenPlayback(this.fixedStatus);
  final RtspCameraStatus fixedStatus;

  @override
  ValueListenable<RtspCameraStatus> get status => ValueNotifier(fixedStatus);

  @override
  Widget buildVideo(BuildContext context, BoxFit fit) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A4750), Color(0xFF17191C)],
          ),
        ),
      );

  @override
  Future<void> dispose() async {}
}

/// The five states an operator can meet, side by side at tile size:
/// unconfigured, connecting, live, no signal, and unavailable — the last one
/// being the platform having no video output at all, not the camera being
/// down.
Widget buildFilmstrip({bool dark = false}) {
  final (light, darkTheme) = solarized();
  final theme = dark ? darkTheme : light;

  Widget tile(RtspCameraConfig config, String caption) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 220,
            height: 150,
            child: RtspCameraView(config: config),
          ),
          const SizedBox(height: 6),
          Text(caption, style: theme.textTheme.bodySmall),
        ],
      );

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
                tile(RtspCameraConfig(), 'unconfigured'),
                const SizedBox(width: 12),
                tile(RtspCameraConfig(url: 'rtsp://c/1'), 'connecting'),
                const SizedBox(width: 12),
                tile(RtspCameraConfig(url: 'rtsp://c/2'), 'live'),
                const SizedBox(width: 12),
                tile(RtspCameraConfig(url: 'rtsp://c/3'), 'no signal'),
                const SizedBox(width: 12),
                tile(RtspCameraConfig(url: 'rtsp://c/4'), 'unavailable'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Same font dance as alarm_visibility_golden_test — without it the captions
/// and icons render as placeholder blocks.
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

  tearDown(() => RtspCameraView.debugPlaybackFactory = null);

  group('RTSP camera golden tests',
      skip: goldenSkip, () {
    Future<void> capture(WidgetTester tester, String name,
        {bool dark = false}) async {
      // One backend per url so the strip shows every state at once.
      RtspCameraView.debugPlaybackFactory = (config) => _GoldenPlayback(
            switch (config.url) {
              'rtsp://c/1' => RtspCameraStatus.connecting,
              'rtsp://c/2' => RtspCameraStatus.live,
              'rtsp://c/4' => RtspCameraStatus.unavailable,
              _ => RtspCameraStatus.noSignal,
            },
          );
      await tester.pumpWidget(buildFilmstrip(dark: dark));
      // A fixed pump, not pumpAndSettle: the connecting tile's spinner never
      // settles. 300ms is an arbitrary but deterministic pose of it.
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byKey(_stripKey),
        matchesGoldenFile('goldens/$name.png'),
      );
    }

    testWidgets('state filmstrip (light)', (tester) async {
      tester.view.physicalSize = const Size(1180, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await capture(tester, 'rtsp_camera_states');
    });

    testWidgets('state filmstrip (dark)', (tester) async {
      tester.view.physicalSize = const Size(1180, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await capture(tester, 'rtsp_camera_states_dark', dark: true);
    });

    testWidgets('config editor form', (tester) async {
      tester.view.physicalSize = const Size(420, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (light, _) = solarized();
      final config = RtspCameraConfig(
        url: 'rtsp://10.104.29.90:554/stream1',
      )..text = 'Packing hall';
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
        matchesGoldenFile('goldens/rtsp_camera_config_editor.png'),
      );
    });
  });
}
