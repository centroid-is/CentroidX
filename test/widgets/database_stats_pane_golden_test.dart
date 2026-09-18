/// Golden images of the database connection census pane.
///
/// Two cases, because the pane exists to answer one question — is this normal?
/// A calm server where every client holds about what it should, and one at the
/// edge of its limit, where the status chip and the numbers turn.
///
/// Every address, application name and count here is invented. This repository
/// is public; the plant's own addresses do not go in it.
///
/// To update: flutter test test/widgets/database_stats_pane_golden_test.dart
///            --update-goldens --run-skipped
///
/// These were generated on Windows. The rest of the repo's goldens were
/// authored on macOS, so a reviewer on another platform may need to regenerate
/// them there.
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/database_stats_pane.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/database_connections.dart';

/// Tall enough for the whole pane, wide enough for the default pane strip
/// plus a little of the page it docks against.
const Size _surface = Size(560, 760);

/// A healthy plant: one connection per UI client, a handful for the collector.
const _calm = ConnectionCensus(
  total: 9,
  max: 200,
  peers: [
    PeerConnections(peer: '10.0.0.1', app: 'collector', count: 6),
    PeerConnections(peer: '10.0.0.2', app: 'hmi', count: 1),
    PeerConnections(peer: '10.0.0.3', app: 'hmi', count: 1),
    PeerConnections(peer: 'local', app: '-', count: 1),
  ],
);

/// The shape of the fault: one client holding almost everything.
const _alarming = ConnectionCensus(
  total: 178,
  max: 200,
  peers: [
    PeerConnections(peer: '10.0.0.1', app: 'collector', count: 140),
    PeerConnections(peer: '10.0.0.2', app: 'hmi', count: 20),
    PeerConnections(peer: '10.0.0.3', app: 'hmi', count: 17),
    PeerConnections(peer: 'local', app: '-', count: 1),
  ],
);

/// An outage that cost data, plus a counter that has outgrown its column.
///
/// The numbers are the ones that were actually measured: 300 samples across a
/// thirty-second outage left 100, so 200 rows were discarded oldest-first.
/// Tag names are invented, like the addresses above.
const _lossy = <String, dynamic>{
  'total_writes': 4821,
  'dropped_rows': 200,
  'dropped_rows_by_table': {'cn01.motor.speed': 200},
  'poisoned_rows': 12,
  'poisoned_rows_by_table': {'cn03.infeed.counter': 12},
  'queued_rows': 340,
  'queued_rows_by_table': {'cn01.motor.speed': 340},
  'max_queued_rows_per_table': 10000,
  'max_queued_rows_total': 200000,
};

/// Nothing lost, nothing waiting.
const _clean = <String, dynamic>{
  'total_writes': 4821,
  'dropped_rows': 0,
  'dropped_rows_by_table': <String, int>{},
  'poisoned_rows': 0,
  'poisoned_rows_by_table': <String, int>{},
  'queued_rows': 0,
  'queued_rows_by_table': <String, int>{},
  'max_queued_rows_per_table': 10000,
  'max_queued_rows_total': 200000,
};

/// The write-queue section docked the same way the census is.
Widget _writeQueueApp(ThemeData theme, Map<String, dynamic> stats,
    {required bool collectsHere}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: SizedBox.shrink()),
          SizedBox(
            width: 380,
            child: Material(
              color: theme.colorScheme.surface,
              elevation: 8,
              child: SidePane(
                title: 'DB connections',
                subtitle: 'Refreshed every 10 s',
                icon: Icons.storage,
                status: const PaneStatus.unknown(),
                onClose: () {},
                child: DatabaseWriteQueueView(
                  stats: stats,
                  collectsHere: collectsHere,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The pane docked against a page, the way an operator sees it.
Widget _paneApp(ThemeData theme, ConnectionCensus census) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: SizedBox.shrink()),
          SizedBox(
            width: 380,
            child: Material(
              color: theme.colorScheme.surface,
              elevation: 8,
              child: SidePane(
                title: 'DB connections',
                subtitle: 'Refreshed every 10 s',
                icon: Icons.storage,
                status: censusPaneStatus(census),
                onClose: () {},
                child: DatabaseCensusView(census: census),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget app) async {
  await tester.binding.setSurfaceSize(_surface);
  // 1:1 pixels — these goldens are for reading in a review, not for pixel
  // archaeology, and a 3x capture would be needlessly large.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  final (_, dark) = solarized();

  // `flutter_test_config.dart` registers the text font as 'Roboto'. The app
  // theme asks for 'dejavu-sans' by name and the pane header carries Material
  // icons, so both have to be registered or the goldens come out as boxes.
  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
          .load();
    }

    await loadFont(
        'dejavu-sans', 'lib/fonts/dejavu-sans/DejaVuSans.ttf');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  group('database stats pane goldens', () {
    testWidgets('a server holding what it should', (tester) async {
      await _pump(tester, _paneApp(dark, _calm));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/database_stats_pane_calm_dark.png'),
      );
    });

    testWidgets('a server nearly out of connections', (tester) async {
      await _pump(tester, _paneApp(dark, _alarming));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/database_stats_pane_alarming_dark.png'),
      );
    });
  });

  group('rows never stored goldens', () {
    testWidgets('an outage that cost data', (tester) async {
      await _pump(tester, _writeQueueApp(dark, _lossy, collectsHere: true));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/database_write_queue_lossy_dark.png'),
      );
    });

    testWidgets('a station that does not collect', (tester) async {
      await _pump(tester, _writeQueueApp(dark, _clean, collectsHere: false));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/database_write_queue_notcollecting_dark.png'),
      );
    });
  });

  group('census reading', () {
    test('the biggest holder is listed first', () {
      expect(_alarming.peersByShare.first.app, 'collector');
    });

    test('a healthy server does not read as a warning', () {
      expect(censusIsAlarming(_calm), isFalse);
      expect(censusPaneStatus(_calm).label, 'Healthy');
    });

    test('a nearly full server reads as a warning', () {
      expect(censusIsAlarming(_alarming), isTrue);
      expect(censusPaneStatus(_alarming).label, 'Nearly full');
    });
  });
}
