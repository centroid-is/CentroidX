// A chart window has to show something the moment it is asked for.
//
// Tapping a readout for its trend used to buy one of three waits, each as
// long as the slowest history query behind it:
//
//   - the accept/reject window did not open at all until both keys' history
//     had come back (five hours of raw rows on the plant's checkweighers), so
//     the tap looked like it had missed;
//   - the BPM window opened on a spinner that stood in for everything,
//     summary cards included, until a 20-hour query landed;
//   - a trend of several lines asked for them one after another.
//
// The readout that was tapped already holds the recent past of the very same
// rows in its shared tracker. The windows now open on that and let the deep
// query fill in behind it, and a trend asks for all of its lines at once.

import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/bpm.dart';
import 'package:tfc/page_creator/assets/graph.dart';
import 'package:tfc/page_creator/assets/ratio_number.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/graph.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';
import '../../helpers/golden_platform.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// LISTEN/NOTIFY stand-in: hands out a channel per table and never emits.
class _FakeAppDatabase extends Fake implements AppDatabase {
  @override
  Future<String> enableNotificationChannel(String tableName) async =>
      '${tableName}_notify';

  @override
  Stream<String> listenToChannel(String channelName) => const Stream.empty();
}

/// Answers a shallow query -- the readout's tracker filling its window -- at
/// once, and holds every query reaching back further than [shallow] until
/// [release]. That is the window between "the operator tapped" and "the deep
/// history came back", which is the one this file is about.
class _GatedDatabase extends Fake implements Database {
  _GatedDatabase({required this.shallow, required this.rows});

  final Duration shallow;

  /// Every row each table holds, oldest first.
  final Map<String, List<DateTime>> rows;

  final _gate = Completer<void>();
  int deepStarted = 0;
  int deepAnswered = 0;

  void release() => _gate.complete();

  @override
  final AppDatabase db = _FakeAppDatabase();

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    // Callers pass the far end of the window positionally when there is no
    // `from`, and a closed range when there is.
    final start = from ?? to;
    final end = from == null ? null : to;
    if (DateTime.now().difference(start) > shallow) {
      deepStarted++;
      await _gate.future;
      deepAnswered++;
    }
    final hits = [
      for (final t in rows[tableName] ?? const <DateTime>[])
        if (t.isAfter(start) && (end == null || !t.isAfter(end)))
          TimeseriesData<dynamic>(1, t),
    ];
    return orderBy == 'time DESC' ? hits.reversed.toList() : hits;
  }
}

class _FakeStateMan extends Fake implements StateMan {
  final _subs = StreamController<Map<String, String>>.broadcast();

  @override
  String resolveKey(String key) => key;

  @override
  String? getSubstitution(String key) => null;

  @override
  Stream<Map<String, String>> get substitutionsChanged => _subs.stream;
}

/// One row every [every], back [span] from now, the newest [offset] ago.
List<DateTime> _rowsEvery(Duration every, Duration span,
    {Duration offset = const Duration(seconds: 15)}) {
  final now = DateTime.now();
  return [
    for (var t = now.subtract(offset);
        now.difference(t) <= span;
        t = t.subtract(every))
      t,
  ].reversed.toList();
}

Widget _harness(Database database, Widget child) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => database),
      stateManProvider.overrideWith((ref) async => _FakeStateMan()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, height: 120, child: child)),
      ),
    ),
  );
}

/// Closes the window and drops the scope, so the trackers and the chart
/// windows' timers go with it; flutter_test fails a test that leaves one.
Future<void> _tearDown(WidgetTester tester) async {
  closeAllFloatingDialogs();
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets(
      'the accept/reject window opens on the tap, drawn from the readout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = _GatedDatabase(
      // The readout reaches back its widest preset, 240 minutes; the window
      // at 30 x 10 wants five hours.
      shallow: const Duration(minutes: 250),
      rows: {
        'accepted': _rowsEvery(const Duration(minutes: 1), const Duration(hours: 6)),
        'rejected':
            _rowsEvery(const Duration(minutes: 10), const Duration(hours: 6)),
      },
    );
    final config = RatioNumberConfig(
      key1: 'accepted',
      key2: 'rejected',
      key1Label: 'accepted',
      key2Label: 'rejected',
      sinceMinutes: const Duration(minutes: 30),
      intervalPresets: const [1, 5, 10, 30, 60, 240],
    );

    await tester.pumpWidget(
        _harness(database, RatioNumberWidget(config: config)));
    // The readout's tracker fills its four hours.
    await tester.pumpAndSettle();
    expect(database.deepStarted, 0);

    await tester.tap(find.byType(RatioNumberWidget));
    await tester.pump();
    expect(FloatingDialogs.openIds, hasLength(1),
        reason: 'the window waited for the database before opening');

    await tester.pump(const Duration(milliseconds: 200));
    final seeded = tester.widget<RatioBarChart>(find.byType(RatioBarChart));
    expect(database.deepStarted, greaterThan(0));
    expect(database.deepAnswered, 0, reason: 'still waiting on the deep query');
    expect(seeded.key1Queue, isNotEmpty,
        reason: 'the window opened empty although the readout held the rows');
    expect(seeded.key2Queue, isNotEmpty);
    // Four hours held, five wanted: the oldest buckets wait for the fetch
    // instead of drawing short.
    expect(seeded.coverageStart, isNotNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget,
        reason: 'nothing says the rest is still coming');

    database.release();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final filled = tester.widget<RatioBarChart>(find.byType(RatioBarChart));
    expect(filled.coverageStart, isNull);
    expect(filled.key1Queue.length, greaterThan(seeded.key1Queue.length),
        reason: 'the deep history never replaced the seed');
    // Replaced, not merged: a row the seed and the fetch both hold is in the
    // queue once, or its bucket would count it twice.
    final times = filled.key1Queue.map((d) => d.time.millisecondsSinceEpoch);
    expect(times.toSet(), hasLength(filled.key1Queue.length));

    await _tearDown(tester);
  });

  testWidgets('the BPM window opens on its rate cards, not a spinner',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = _GatedDatabase(
      // The readout holds an hour; the window asks for 20.
      shallow: const Duration(minutes: 70),
      rows: {
        'line/packs':
            _rowsEvery(const Duration(seconds: 30), const Duration(hours: 3)),
      },
    );

    await tester.pumpWidget(
        _harness(database, BpmWidget(config: BpmConfig(key: 'line/packs'))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BpmWidget));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(database.deepAnswered, 0, reason: 'still waiting on the deep query');

    // Two packs a minute over every preset from 1 to 60 minutes -- all of
    // which the readout's hour covers, so all five cards are real figures.
    final rateCards =
        find.descendant(of: find.byType(Card), matching: find.text('2'));
    expect(rateCards, findsNWidgets(5),
        reason: 'the cards waited for the 20-hour query');
    expect(find.text('–'), findsNothing);

    database.release();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(rateCards, findsNWidgets(5));

    await _tearDown(tester);
  });

  testWidgets('the BPM window shows dashes, not zeros, before it knows',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Nothing in the readout's hour, so nothing to seed from: "no batches"
    // and "not fetched yet" look the same from here, and a row of zeros on
    // a running line would be the wrong one of the two.
    final database = _GatedDatabase(
      shallow: const Duration(minutes: 70),
      rows: {'line/packs': const []},
    );

    await tester.pumpWidget(
        _harness(database, BpmWidget(config: BpmConfig(key: 'line/packs'))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BpmWidget));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.descendant(of: find.byType(Card), matching: find.text('–')),
        findsNWidgets(5));

    database.release();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.descendant(of: find.byType(Card), matching: find.text('0')),
        findsNWidgets(5),
        reason: 'once the database has answered, zero is the answer');

    await _tearDown(tester);
  });

  testWidgets('a trend asks for all of its lines at once', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Every query is deep, so every one is held: what matters is how many
    // are in flight before the first is answered.
    final database = _GatedDatabase(shallow: Duration.zero, rows: const {});
    final config = GraphAssetConfig(
      primarySeries: [
        for (final line in ['Line1', 'Line2', 'Line3'])
          GraphSeriesConfig(key: '$line.rate', label: line),
      ],
      timeWindowMinutes: const Duration(minutes: 60),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => database),
        stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 900, height: 600, child: GraphAsset(config)),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(database.deepStarted, 3,
        reason: 'the lines were asked for one after another');
    expect(database.deepAnswered, 0);

    database.release();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(database.deepAnswered, 3);

    await _tearDown(tester);
  });

  // The frame a chart draws before it has data: faint gridlines where the
  // plot will be, a hairline of progress along its top, and the button row
  // already in its place. It replaces a spinner in the middle of the window.
  for (final brightness in Brightness.values) {
    testWidgets('loading chart golden — ${brightness.name}', (tester) async {
      final font = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
          .readAsBytesSync()
          .buffer
          .asByteData();
      await (FontLoader('Roboto')..addFont(Future.value(font))).load();
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final iconFont = File('$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf');
      if (flutterRoot != null && iconFont.existsSync()) {
        await (FontLoader('MaterialIcons')
              ..addFont(
                  Future.value(iconFont.readAsBytesSync().buffer.asByteData())))
            .load();
      }

      tester.view.physicalSize = const Size(640, 340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final graph = Graph(
        config: GraphConfig(
          type: GraphType.timeseries,
          xAxis: const GraphAxisConfig(unit: ''),
          yAxis: const GraphAxisConfig(unit: 'Batches/min'),
          xSpan: const Duration(minutes: 60),
        ),
        data: [],
        redraw: () {},
      );

      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: RepaintBoundary(
            key: const Key('loading_chart'),
            // The boundary captures only what is painted inside it. Without a
            // ground of its own the dark variant came out as dark gridlines on
            // a transparent -- white -- background, which no screen shows.
            child: Builder(
              builder: (context) => ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Builder(builder: graph.build),
                ),
              ),
            ),
          ),
        ),
      ));
      // The progress bar is indeterminate and never settles; one fixed step
      // into it keeps the capture repeatable.
      await tester.pump(const Duration(milliseconds: 300));

      await expectLater(
        find.byKey(const Key('loading_chart')),
        matchesGoldenFile('goldens/chart_loading_${brightness.name}.png'),
      );
    }, tags: ['golden'], skip: goldenSkipFlag);
  }
}
