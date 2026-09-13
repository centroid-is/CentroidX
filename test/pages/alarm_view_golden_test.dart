/// Goldens of the alarm page in both of its readings: the alarm lists with
/// the page's own Alarms/Downtime header row, and the stop analysis rendered
/// where the operator actually finds it. The header control is deliberately
/// NOT part of the list's search bar — it switches what the page shows, not
/// which list — and these images are the review of that placement.
///
/// To update:
///   flutter test test/pages/alarm_view_golden_test.dart \
///     --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/alarm_view.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

import '../helpers/golden_tolerance.dart';
import '../helpers/golden_platform.dart';

/// Fixed clock, so the live edge of the timeline is reproducible.
final now = DateTime(2026, 8, 29, 14, 22);
DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

AlarmConfig _config(
  String title, {
  List<String> group = const [],
  bool bindToGroup = false,
  AlarmLevel level = AlarmLevel.error,
}) =>
    AlarmConfig(
      uid: title.toLowerCase().replaceAll(' ', '-'),
      title: title,
      description: title,
      group: group,
      bindToGroup: bindToGroup,
      rules: [
        AlarmRule(
          level: level,
          expression: ExpressionConfig(value: Expression(formula: 'a')),
          acknowledgeRequired: false,
        )
      ],
    );

/// The packing-hall shape the stop timeline's own goldens use: groups with
/// bound alarms, diagnoses, and an infrastructure corner.
final _alarms = [
  _config('Multivac stopped',
      group: ['Line 3', 'Multivac'], bindToGroup: true),
  _config('Film reel empty', group: ['Line 3', 'Multivac']),
  _config('Film tracking error',
      group: ['Line 3', 'Multivac'], level: AlarmLevel.warning),
  _config('Blank magazine empty', group: ['Line 3', 'Box erector BER01']),
  _config('Strapper stopped',
      group: ['Line 3', 'Afak SL-15-3'], bindToGroup: true),
  _config('Link error', group: ['Infrastructure'], level: AlarmLevel.warning),
];

AlarmActive _activation(String uid, DateTime at, {DateTime? ended}) {
  final config = _alarms.firstWhere((a) => a.uid == uid);
  return AlarmActive(
    alarm: Alarm(config: config),
    notification: AlarmNotification(
      uid: uid,
      active: ended == null,
      expression: 'a',
      rule: config.rules.first,
      timestamp: at,
    ),
    deactivated: ended,
  );
}

/// A shift's worth of history plus one alarm still standing, so the stops
/// view has closed bars, an open bar running to the live edge, and the
/// alarm list has rows.
final _standing = _activation('film-reel-empty', ago(9));
final _history = [
  _activation('multivac-stopped', ago(140), ended: ago(133)),
  _activation('film-reel-empty', ago(160), ended: ago(148)),
  _activation('film-tracking-error', ago(120), ended: ago(118)),
  _activation('blank-magazine-empty', ago(175), ended: ago(164)),
  _activation('strapper-stopped', ago(110), ended: ago(101)),
  _activation('strapper-stopped', ago(22), ended: ago(16)),
  _activation('link-error', ago(88), ended: ago(86)),
];

class _FakeAlarmMan implements AlarmMan {
  @override
  final AlarmManConfig config = AlarmManConfig(alarms: _alarms);

  @override
  Stream<Set<AlarmActive>> activeAlarms() => Stream.value({_standing});

  @override
  Stream<List<AlarmActive?>> history() => Stream.value(_history);

  @override
  List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String query) =>
      alarms;

  @override
  Future<List<AlarmActive>> getRecentAlarms({
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) async =>
      _history;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Real glyphs — without this every label captures as a solid box.
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

Future<void> _pumpPage(WidgetTester tester, {required bool dark}) async {
  await _loadFonts();
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => BeamPage(
            key: const ValueKey('/'),
            title: 'Alarm View',
            child: AlarmViewPage(debugClock: now),
          ),
    }).call,
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [alarmManProvider.overrideWith((ref) async => _FakeAlarmMan())],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: dark ? muted().$2 : muted().$1,
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// The page body only: the app bar carries a live clock that would churn
/// every capture.
final _body = find.byKey(const ValueKey('alarm-view-body'));

void main() {
  useTolerantGoldenComparator();

  setUp(() {
    // BaseScaffold's navigation bar asserts on at least two destinations.
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm));
  });
  tearDown(() => RouteRegistry().menuItems.clear());

  group('alarm page goldens',
      skip: goldenSkip, () {
    testWidgets('the lists, with the Alarms/Downtime header row — light',
        (tester) async {
      await _pumpPage(tester, dark: false);
      await expectLater(
          _body, matchesGoldenFile('goldens/alarm_view_alarms_light.png'));
    });

    testWidgets('the lists, with the Alarms/Downtime header row — dark',
        (tester) async {
      await _pumpPage(tester, dark: true);
      await expectLater(
          _body, matchesGoldenFile('goldens/alarm_view_alarms_dark.png'));
    });

    testWidgets('the stop analysis where the operator finds it — light',
        (tester) async {
      await _pumpPage(tester, dark: false);
      await tester.tap(find.text('Downtime'));
      await tester.pumpAndSettle();
      await expectLater(
          _body, matchesGoldenFile('goldens/alarm_view_stops_light.png'));
    });

    testWidgets('the stop analysis where the operator finds it — dark',
        (tester) async {
      await _pumpPage(tester, dark: true);
      await tester.tap(find.text('Downtime'));
      await tester.pumpAndSettle();
      await expectLater(
          _body, matchesGoldenFile('goldens/alarm_view_stops_dark.png'));
    });
  });
}
