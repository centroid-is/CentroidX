/// Golden images of the Date & Time section, for design review and PR
/// descriptions.
///
/// Frames: a healthy synchronised station, the two unhealthy states an
/// operator has to be able to tell apart at a glance (enabled but never
/// synchronised, and switched off entirely), a station running on the
/// built-in fallback pool, a polkit refusal, and the NTP server editor.
///
/// To update: flutter test test/widgets/system_clock_section_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/system_clock.dart';
import 'package:tfc/widgets/system_clock_section.dart';

import '../helpers/golden_fonts.dart';
import '../helpers/test_helpers.dart';
import 'system_clock_section_test.dart';

/// Tall enough for the clock card, the settings rows and the sync detail
/// without scrolling.
const Size _viewport = Size(640, 900);

Widget _build({
  required FakeTimeDate timeDate,
  FakeTimeSync? timeSync,
  List<String> storedServers = const [],
  bool settingsAllowed = true,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SystemClockSection(
          timeDate: timeDate,
          timeSync: timeSync,
          storedServers: storedServers,
          onServersChanged: (_) async {},
          settingsAllowed: settingsAllowed,
          onBeforeChange: () async => settingsAllowed,
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeTimeDate timeDate,
  FakeTimeSync? timeSync,
  List<String> storedServers = const [],
  bool settingsAllowed = true,
}) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these are for reading, not pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await pumpAndLoad(
    tester,
    _build(
      timeDate: timeDate,
      timeSync: timeSync,
      storedServers: storedServers,
      settingsAllowed: settingsAllowed,
    ),
  );
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('synchronized station', (tester) async {
    await _pump(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(
        status: syncStatus(
          // The server actually in use has to be one of the configured ones,
          // or the star marking it would sit on nothing.
          serverName: '10.104.29.1',
          serverAddress: '10.104.29.1',
          runtime: ['10.104.29.1', '10.104.29.2'],
          message: healthyMessage(),
        ),
      ),
      storedServers: const ['10.104.29.1', '10.104.29.2'],
    );
    await _expectGolden(tester, 'system_clock_synchronized.png');
  });

  testWidgets('enabled but never synchronized', (tester) async {
    // Where a wrong server address leaves a station: NTP on, no packet ever
    // received. It must not look healthy.
    await _pump(
      tester,
      timeDate: FakeTimeDate(
          status: FakeTimeDate.synchronizedStatus(ntpSynchronized: false)),
      timeSync: FakeTimeSync(
          status: syncStatus(
              serverName: 'ntp.plant.local',
              serverAddress: null,
              runtime: ['ntp.plant.local'],
              message: null)),
      storedServers: const ['ntp.plant.local'],
    );
    await _expectGolden(tester, 'system_clock_not_synchronized.png');
  });

  testWidgets('network time switched off', (tester) async {
    await _pump(
      tester,
      timeDate: FakeTimeDate(
          status: FakeTimeDate.synchronizedStatus(ntpEnabled: false)),
      timeSync: FakeTimeSync(status: syncStatus(message: healthyMessage())),
    );
    await _expectGolden(tester, 'system_clock_ntp_off.png');
  });

  testWidgets('running on the built-in fallback pool', (tester) async {
    await _pump(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(status: syncStatus(message: healthyMessage())),
    );
    await _expectGolden(tester, 'system_clock_fallback_pool.png');
  });

  testWidgets('polkit refused the change', (tester) async {
    final timeDate = FakeTimeDate()
      ..writeError = DBusMethodResponseException(DBusMethodErrorResponse(
          'org.freedesktop.DBus.Error.InteractiveAuthorizationRequired'));
    await _pump(
      tester,
      timeDate: timeDate,
      timeSync: FakeTimeSync(status: syncStatus(message: healthyMessage())),
    );

    await tester.tap(find.byType(Switch));
    await settle(tester);

    await _expectGolden(tester, 'system_clock_not_authorized.png');
  });

  testWidgets('NTP server editor', (tester) async {
    await _pump(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(
          status: syncStatus(
              serverName: '10.104.29.1',
              serverAddress: '10.104.29.1',
              runtime: ['10.104.29.1', '10.104.29.2'],
              message: healthyMessage())),
      storedServers: const ['10.104.29.1', '10.104.29.2'],
    );

    await tester.tap(find.text('Edit'));
    await settle(tester);

    await _expectGolden(tester, 'system_clock_server_editor.png');
  });

  testWidgets('hardware clock drifting', (tester) async {
    await _pump(
      tester,
      timeDate: FakeTimeDate(
        status: FakeTimeDate.synchronizedStatus(
            rtcTime: DateTime(2026, 9, 1, 15, 36, 11)),
      ),
      timeSync: FakeTimeSync(status: syncStatus(message: healthyMessage())),
    );
    await _expectGolden(tester, 'system_clock_rtc_drift.png');
  });

  testWidgets('locked for a session without administer', (tester) async {
    // What an anonymous operator at the panel sees: the whole status half —
    // the time, the timezone, the sync verdict, the servers — and a lock on
    // each of the three things that would change the host. The route is not
    // gated, and this frame is the argument for that.
    await _pump(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(
        status: syncStatus(
          runtime: const ['10.104.29.1', '0.debian.pool.ntp.org'],
          message: healthyMessage(),
        ),
      ),
      storedServers: const ['10.104.29.1', '0.debian.pool.ntp.org'],
      settingsAllowed: false,
    );
    await _expectGolden(tester, 'system_clock_locked.png');
  });
}
