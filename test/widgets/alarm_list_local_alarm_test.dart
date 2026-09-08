/// The Alarm View's active list with the panel's own gateway alarm in it.
///
/// The local alarm rides ABOVE the list's filters and outside its history:
/// while the gateway is down every plant row on this page may be stale, so
/// the row that says so must not be searchable away — and history is the
/// persisted record, which this alarm is deliberately not part of (it never
/// touches TimescaleDB; see `lib/core/local_gateway_alarm.dart`).
library;

import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/core/local_gateway_alarm.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/alarm.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

import 'alarm_fixture.dart';

final Uri _url = Uri.parse('wss://10.50.10.11:9444');
final DateTime _raisedAt = DateTime(2026, 9, 8, 7, 5, 0);

GatewayLinkReport _unreachable() => describeGatewayLink(
      state: LinkState.down,
      url: _url,
      elapsed: const Duration(minutes: 10),
      lastDownReason: 'the transport ended by remote close',
    );

const _listKey = Key('alarm_list_local_alarm_golden');

Widget _list({
  required AlarmFixture alarms,
  required GatewayLinkReport? report,
  bool dark = false,
  bool sourceNeverResolves = false,
}) {
  final (light, darkTheme) = solarized();
  return ProviderScope(
    overrides: [
      if (sourceNeverResolves)
        // A future that never completes: gateway mode with the transport
        // gone can leave the panel without any alarm source at all. The
        // list must not answer that with a spinner forever while the one
        // alarm that explains it sits unrendered.
        alarmManProvider.overrideWith((ref) => Completer<AlarmMan>().future)
      else
        alarmManProvider.overrideWith((ref) async => alarms),
      gatewayLinkProvider.overrideWith((ref) => Stream.value(report)),
      gatewayLinkClockProvider.overrideWithValue(() => _raisedAt),
    ],
    child: MaterialApp(
      theme: dark ? darkTheme : light,
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _listKey,
            child: SizedBox(
              width: 520,
              height: 600,
              child: const ListActiveAlarms(),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required GatewayLinkReport? report,
  AlarmFixture? alarms,
  bool dark = false,
  bool sourceNeverResolves = false,
}) async {
  await tester.pumpWidget(_list(
    alarms: alarms ?? AlarmFixture(),
    report: report,
    dark: dark,
    sourceNeverResolves: sourceNeverResolves,
  ));
  await tester.pumpAndSettle();
}

AlarmFixture _plant() => AlarmFixture(active: {
      alarm('CN07 færiband',
          level: AlarmLevel.warning,
          at: DateTime(2026, 9, 8, 7, 10, 2),
          description: 'Mótor í yfirálagi'),
    });

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

  testWidgets('direct mode: the list is exactly the plant\'s', (tester) async {
    await _pump(tester, report: null, alarms: _plant());
    expect(find.text('CN07 færiband'), findsOneWidget);
    expect(find.textContaining('Gateway'), findsNothing,
        reason: 'no gateway, no gateway alarm — the direct-mode silence '
            'this feature must never lose');
  });

  testWidgets('gateway down: the local alarm tops the active list',
      (tester) async {
    await _pump(tester, report: _unreachable(), alarms: _plant());
    final localY = tester.getTopLeft(find.text('Gateway unreachable')).dy;
    final plantY = tester.getTopLeft(find.text('CN07 færiband')).dy;
    expect(localY, lessThan(plantY),
        reason: 'while the gateway is down every plant row here may be '
            'stale; the row that says so goes first');
  });

  testWidgets('it rides above the search filter', (tester) async {
    await _pump(tester, report: _unreachable(), alarms: _plant());
    await tester.enterText(find.byType(TextField), 'færiband');
    await tester.pumpAndSettle();
    expect(find.text('Gateway unreachable'), findsOneWidget,
        reason: 'a search must not be able to hide the reason the search '
            'results themselves may be stale');
  });

  testWidgets('it is counted — a red card beside an "Error 0" chip would '
      'read as a broken counter', (tester) async {
    await _pump(tester, report: _unreachable(), alarms: _plant());
    expect(
        find.byWidgetPredicate((w) =>
            w is FilterChip &&
            w.label is Text &&
            (w.label as Text).data == 'Error 1'),
        findsOneWidget);
  });

  testWidgets('but no level filter can hide it', (tester) async {
    await _pump(tester, report: _unreachable(), alarms: _plant());
    await tapLevelChip(tester, AlarmLevel.warning);
    expect(find.text('Gateway unreachable'), findsOneWidget,
        reason: 'the operator narrowed to warnings; the row that says the '
            'warnings themselves may be stale stays');
    expect(find.text('CN07 færiband'), findsOneWidget,
        reason: 'control — the warning filter did apply');
  });

  testWidgets('it is NOT in history — nothing about it is a record',
      (tester) async {
    await _pump(tester, report: _unreachable(), alarms: _plant());
    await showHistory(tester);
    expect(find.text('Gateway unreachable'), findsNothing,
        reason: 'history is the persisted record read back from the '
            'database; this alarm is deliberately not part of it');
  });

  testWidgets('no alarm source at all: the local alarm still renders, not a '
      'spinner', (tester) async {
    await tester.pumpWidget(_list(
      alarms: AlarmFixture(),
      report: _unreachable(),
      sourceNeverResolves: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Gateway unreachable'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the one condition that takes the alarm source away is the '
            'condition this alarm reports — a spinner here is the silence '
            'this feature exists to end');
  });

  testWidgets('spinner control: with no local alarm and no source, the '
      'spinner is still the honest answer', (tester) async {
    await tester.pumpWidget(_list(
      alarms: AlarmFixture(),
      report: null,
      sourceNeverResolves: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: 'live control for the arm above — the spinner branch must '
            'still exist, or that arm passes vacuously');
  });

  testWidgets('the detail card offers no acknowledge and no expression',
      (tester) async {
    final local = _localAlarmFromProvider();
    await tester.pumpWidget(MaterialApp(
      theme: solarized().$1,
      home: Scaffold(
        body: ProviderScope(child: ViewActiveAlarm(alarm: local)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Acknowledge'), findsNothing,
        reason: 'an acknowledge would cross the (dead) wire or ask for a '
            'receipt row — the alarm clears itself instead');
    expect(find.textContaining('Expression:'), findsNothing,
        reason: 'nothing evaluated this alarm; a formula line would be an '
            'invented fact');
    expect(find.textContaining('Panel misconfigured'), findsOneWidget);
    expect(find.textContaining('/etc/centroid/ca.pem'), findsOneWidget,
        reason: 'the operator action for a misconfigured panel is the file '
            'at that exact path');
  });

  group('goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('local alarm atop the plant list', (tester) async {
      await _pump(tester, report: _unreachable(), alarms: _plant());
      await expectLater(find.byKey(_listKey),
          matchesGoldenFile('goldens/alarm_list_local_gateway.png'));
    });

    testWidgets('local alarm atop the plant list, dark', (tester) async {
      await _pump(tester,
          report: _unreachable(), alarms: _plant(), dark: true);
      await expectLater(find.byKey(_listKey),
          matchesGoldenFile('goldens/alarm_list_local_gateway_dark.png'));
    });
  });
}

/// The misconfigured-panel alarm exactly as the surfaces receive it — built
/// through the real mapper, so this test cannot drift from production (the
/// provider test pins that the provider publishes the mapper's output
/// verbatim).
AlarmActive _localAlarmFromProvider() {
  final report = describeGatewayLinkFailure(
    url: _url,
    failure: const GatewayLinkBuildFailure(
      raw: 'PathNotFoundException: /etc/centroid/ca.pem',
      path: '/etc/centroid/ca.pem',
    ),
  );
  return localGatewayAlarm(report, raisedAt: _raisedAt)!;
}
