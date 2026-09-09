import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/system_clock.dart';
import 'package:tfc/widgets/system_clock_section.dart';

/// A [TimeDateApi] that answers from memory and records what was asked of it.
class FakeTimeDate implements TimeDateApi {
  SystemClockStatus status;
  Object? readError;
  Object? writeError;

  final List<bool> ntpCalls = [];
  final List<String> timezoneCalls = [];
  final List<DateTime> timeCalls = [];
  List<String> zones = const ['UTC', 'Atlantic/Reykjavik', 'Europe/Oslo'];

  FakeTimeDate({SystemClockStatus? status})
      : status = status ?? synchronizedStatus();

  static SystemClockStatus synchronizedStatus({
    bool ntpEnabled = true,
    bool ntpSynchronized = true,
    bool canNtp = true,
    DateTime? rtcTime,
  }) =>
      SystemClockStatus(
        time: DateTime(2026, 9, 1, 15, 32, 31),
        rtcTime: rtcTime,
        timezone: 'Atlantic/Reykjavik',
        localRtc: false,
        ntpEnabled: ntpEnabled,
        ntpSynchronized: ntpSynchronized,
        canNtp: canNtp,
      );

  @override
  Future<SystemClockStatus> readStatus() async {
    final error = readError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<void> setNtp(bool enabled) async {
    ntpCalls.add(enabled);
    final error = writeError;
    if (error != null) throw error;
    status = SystemClockStatus(
      time: status.time,
      rtcTime: status.rtcTime,
      timezone: status.timezone,
      localRtc: status.localRtc,
      ntpEnabled: enabled,
      ntpSynchronized: status.ntpSynchronized,
      canNtp: status.canNtp,
    );
  }

  @override
  Future<void> setTimezone(String timezone) async {
    timezoneCalls.add(timezone);
    final error = writeError;
    if (error != null) throw error;
  }

  @override
  Future<void> setLocalRtc(bool localRtc, {bool fixSystem = true}) async {}

  @override
  Future<void> setTime(DateTime time) async {
    timeCalls.add(time);
    final error = writeError;
    if (error != null) throw error;
  }

  @override
  Future<List<String>> listTimezones() async => zones;
}

class FakeTimeSync implements TimeSyncApi {
  TimeSyncStatus? status;
  final List<List<String>> pushes = [];
  Object? writeError;

  FakeTimeSync({this.status});

  @override
  Future<TimeSyncStatus?> readStatus() async => status;

  @override
  Future<void> setRuntimeNtpServers(List<String> servers) async {
    pushes.add(servers);
    final error = writeError;
    if (error != null) throw error;
  }
}

TimeSyncStatus syncStatus({
  String serverName = '0.debian.pool.ntp.org',
  String? serverAddress = '93.95.229.195',
  List<String> link = const [],
  List<String> system = const [],
  List<String> runtime = const [],
  List<String> fallback = const ['0.debian.pool.ntp.org'],
  NtpMessage? message,
}) =>
    TimeSyncStatus(
      serverName: serverName,
      serverAddress: serverAddress,
      linkServers: link,
      systemServers: system,
      runtimeServers: runtime,
      fallbackServers: fallback,
      pollInterval: const Duration(seconds: 2048),
      pollIntervalMin: const Duration(seconds: 32),
      pollIntervalMax: const Duration(seconds: 2048),
      rootDistanceMax: const Duration(seconds: 5),
      lastMessage: message,
    );

NtpMessage healthyMessage() {
  final origin = DateTime(2026, 9, 1, 15, 22, 37);
  return NtpMessage(
    leap: 0,
    version: 4,
    mode: 4,
    stratum: 2,
    precision: -25,
    rootDelay: const Duration(microseconds: 625),
    rootDispersion: const Duration(microseconds: 183),
    referenceId: 'C1043A4D',
    originateTime: origin,
    receiveTime: origin.add(const Duration(microseconds: 1013)),
    transmitTime: origin.add(const Duration(microseconds: 1129)),
    destinationTime: origin.add(const Duration(microseconds: 2195)),
    ignored: false,
    packetCount: 6013,
    jitter: const Duration(microseconds: 184),
  );
}

Future<void> pumpSection(
  WidgetTester tester, {
  required FakeTimeDate timeDate,
  FakeTimeSync? timeSync,
  List<String> storedServers = const [],
  Future<void> Function(List<String>)? onServersChanged,
  bool settingsAllowed = true,
  Future<bool> Function()? onBeforeChange,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SystemClockSection(
          timeDate: timeDate,
          timeSync: timeSync,
          storedServers: storedServers,
          onServersChanged: onServersChanged ?? (_) async {},
          settingsAllowed: settingsAllowed,
          onBeforeChange: onBeforeChange,
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('shows the host clock and timezone without any login',
      (tester) async {
    // The whole reason this lives outside the dbus login gate: reading
    // timedate1 needs no authorisation.
    await pumpSection(tester, timeDate: FakeTimeDate());

    expect(find.text('15:32:31'), findsOneWidget);
    expect(find.textContaining('Atlantic/Reykjavik'), findsWidgets);
  });

  testWidgets('shows enabled-but-not-syncing as its own state',
      (tester) async {
    // Distinct from "switched off": the clock is being managed and is still
    // wrong, which is the case worth chasing.
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(
          status: FakeTimeDate.synchronizedStatus(ntpSynchronized: false)),
    );
    expect(find.text('Not synchronized'), findsOneWidget);
  });

  testWidgets('shows network time off as its own state', (tester) async {
    await pumpSection(
      tester,
      timeDate:
          FakeTimeDate(status: FakeTimeDate.synchronizedStatus(ntpEnabled: false)),
    );
    expect(find.text('Network time off'), findsOneWidget);
  });

  testWidgets('reports a healthy sync', (tester) async {
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(status: syncStatus(message: healthyMessage())),
    );

    expect(find.text('Synchronized'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'stratum');
    expect(find.text('6013'), findsOneWidget, reason: 'packet count');
    expect(find.text('184us'), findsOneWidget, reason: 'jitter');
    expect(find.textContaining('93.95.229.195'), findsOneWidget);
  });

  testWidgets('says so when no NTP packet has arrived yet', (tester) async {
    // The state a wrong server address leaves timesyncd in — it must not read
    // as working.
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(
          status: FakeTimeDate.synchronizedStatus(ntpSynchronized: false)),
      timeSync: FakeTimeSync(status: syncStatus(message: null)),
    );

    expect(find.textContaining('No NTP packet has been received'),
        findsOneWidget);
  });

  testWidgets('flags a station running on the built-in fallback pool',
      (tester) async {
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(status: syncStatus(message: healthyMessage())),
    );

    expect(find.textContaining('Built-in fallback servers'), findsOneWidget);
  });

  testWidgets('says the HMI re-applies runtime servers it has stored',
      (tester) async {
    // systemd forgets runtime servers on reboot; the operator needs to know
    // what is keeping them there.
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(
          status: syncStatus(runtime: ['10.104.29.1'], message: healthyMessage())),
      storedServers: const ['10.104.29.1'],
    );

    expect(find.textContaining('re-applies the list when it starts'),
        findsOneWidget);
  });

  testWidgets('admits when runtime servers came from somewhere else',
      (tester) async {
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(
          status: syncStatus(runtime: ['10.104.29.1'], message: healthyMessage())),
      storedServers: const [],
    );

    expect(find.textContaining('no stored list to re-apply'), findsOneWidget);
  });

  testWidgets('says DHCP servers take precedence', (tester) async {
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(
          status: syncStatus(
              link: ['dhcp.example'],
              runtime: ['10.104.29.1'],
              message: healthyMessage())),
    );

    expect(find.textContaining('Supplied by DHCP'), findsOneWidget);
    expect(find.text('dhcp.example'), findsOneWidget);
  });

  testWidgets('toggling network time calls SetNTP', (tester) async {
    final timeDate = FakeTimeDate();
    await pumpSection(tester, timeDate: timeDate);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(timeDate.ntpCalls, [false]);
  });

  testWidgets('a polkit refusal names the missing station rule',
      (tester) async {
    // On a station without the rule this is the expected outcome, and no
    // amount of clicking in the HMI fixes it — so the message must point at
    // the host, not read like a transient fault.
    final timeDate = FakeTimeDate()
      ..writeError = DBusMethodResponseException(DBusMethodErrorResponse(
          'org.freedesktop.DBus.Error.AccessDenied'));
    await pumpSection(tester, timeDate: timeDate);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.textContaining('polkit'), findsOneWidget);
    expect(find.textContaining('49-centroid-clock.rules'), findsOneWidget);
  });

  testWidgets('the NTP switch is disabled when the host has no NTP client',
      (tester) async {
    await pumpSection(
      tester,
      timeDate:
          FakeTimeDate(status: FakeTimeDate.synchronizedStatus(canNtp: false)),
    );

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('hides manual clock setting while NTP is on', (tester) async {
    // Setting the clock by hand under NTP is pointless: timesyncd steps it
    // straight back.
    await pumpSection(tester, timeDate: FakeTimeDate());
    expect(find.text('Set clock manually'), findsNothing);
  });

  testWidgets('offers manual clock setting when NTP is off', (tester) async {
    await pumpSection(
      tester,
      timeDate:
          FakeTimeDate(status: FakeTimeDate.synchronizedStatus(ntpEnabled: false)),
    );
    expect(find.text('Set clock manually'), findsOneWidget);
  });

  testWidgets('warns about a drifting hardware clock', (tester) async {
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(
        status: FakeTimeDate.synchronizedStatus(
            rtcTime: DateTime(2026, 9, 1, 15, 34, 31)),
      ),
    );

    expect(find.textContaining('RTC battery may be failing'), findsOneWidget);
  });

  testWidgets('does not nag about a hardware clock that is merely close',
      (tester) async {
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(
        status: FakeTimeDate.synchronizedStatus(
            rtcTime: DateTime(2026, 9, 1, 15, 32, 33)),
      ),
    );

    expect(find.textContaining('RTC battery'), findsNothing);
  });

  testWidgets('editing servers pushes them and stores them', (tester) async {
    final timeSync = FakeTimeSync(status: syncStatus(message: healthyMessage()));
    final stored = <List<String>>[];

    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: timeSync,
      onServersChanged: (servers) async => stored.add(servers),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '10.104.29.1');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(timeSync.pushes, [
      ['10.104.29.1']
    ]);
    expect(stored, [
      ['10.104.29.1']
    ], reason: 'stored so it survives the reboot systemd will not');
  });

  testWidgets('rejects a malformed server before pushing anything',
      (tester) async {
    final timeSync = FakeTimeSync(status: syncStatus(message: healthyMessage()));
    await pumpSection(
        tester, timeDate: FakeTimeDate(), timeSync: timeSync);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'not a host');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Not a valid hostname or IP address'), findsOneWidget);
    expect(timeSync.pushes, isEmpty);
  });

  testWidgets('renders the clock half when timesyncd is absent',
      (tester) async {
    // A station on chrony, or none at all: the clock still reads.
    await pumpSection(tester, timeDate: FakeTimeDate(), timeSync: null);

    expect(find.text('15:32:31'), findsOneWidget);
    expect(find.textContaining('systemd-timesyncd is not running'),
        findsOneWidget);
  });

  testWidgets('surfaces a failure to read the clock at all', (tester) async {
    final timeDate = FakeTimeDate()..readError = Exception('no bus');
    await pumpSection(tester, timeDate: timeDate);

    expect(find.textContaining('Could not read the system clock'),
        findsOneWidget);
  });

  testWidgets('picking a timezone calls SetTimezone', (tester) async {
    final timeDate = FakeTimeDate();
    await pumpSection(tester, timeDate: timeDate);

    await tester.tap(find.text('Time zone'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Europe/Oslo'));
    await tester.pumpAndSettle();

    expect(timeDate.timezoneCalls, ['Europe/Oslo']);
  });

  testWidgets('the timezone list is searchable', (tester) async {
    // ListTimezones returns ~600 entries on a real host.
    final timeDate = FakeTimeDate()
      ..zones = const ['UTC', 'Atlantic/Reykjavik', 'Europe/Oslo'];
    await pumpSection(tester, timeDate: timeDate);

    await tester.tap(find.text('Time zone'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'oslo');
    await tester.pumpAndSettle();

    expect(find.text('Europe/Oslo'), findsOneWidget);
    expect(find.text('UTC'), findsNothing);
  });

  testWidgets('reordering servers keeps the operator order', (tester) async {
    // timesyncd tries servers in order, so the list is a preference ranking,
    // not a set. Also guards the index adjustment onReorder needs and
    // onReorderItem does not -- we are on onReorder because the ivi image
    // builds on a Flutter that predates the newer callback.
    final timeSync = FakeTimeSync(status: syncStatus(message: healthyMessage()));
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: timeSync,
      storedServers: const ['first.example', 'second.example'],
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // Drag the first entry below the second. ReorderableListView needs the
    // gesture fed in steps: a single tester.drag() completes before the
    // reorder machinery has taken the pointer.
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(timeSync.pushes, [
      ['second.example', 'first.example']
    ]);
  });

  group('access gate', () {
    testWidgets('the status half renders for a session that may change nothing',
        (tester) async {
      // The point of gating the controls instead of the route: an operator
      // with no permissions still gets to see whether the clock is right.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SystemClockSection(
              timeDate: FakeTimeDate(),
              timeSync: FakeTimeSync(status: syncStatus()),
              settingsAllowed: false,
              onBeforeChange: () async => false,
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('15:32:31'), findsOneWidget);
      expect(find.text('Synchronized'), findsOneWidget);
      expect(find.textContaining('Atlantic/Reykjavik'), findsWidgets);
    });

    testWidgets('locked controls draw a lock and stay tappable',
        (tester) async {
      await pumpSection(
        tester,
        timeDate: FakeTimeDate(),
        timeSync: FakeTimeSync(status: syncStatus()),
        settingsAllowed: false,
        onBeforeChange: () async => false,
      );

      // Time zone, NTP switch and the server Edit button. A greyed control
      // would teach the operator the panel is broken; the lock says which
      // permission is missing and the refusal offers the way through.
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(3));
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'Time zone')).onTap,
        isNotNull,
      );
    });

    testWidgets('a refused timezone change never opens the picker',
        (tester) async {
      // Guarding at the write instead would list six hundred timezones, let
      // the operator search them, take their choice and only then refuse.
      final timeDate = FakeTimeDate();
      var asked = 0;
      await pumpSection(
        tester,
        timeDate: timeDate,
        settingsAllowed: false,
        onBeforeChange: () async {
          asked++;
          return false;
        },
      );

      await tester.tap(find.text('Time zone'));
      await tester.pumpAndSettle();

      expect(asked, 1);
      expect(find.text('Search'), findsNothing);
      expect(timeDate.timezoneCalls, isEmpty);
    });

    testWidgets('a refused NTP toggle never reaches the host', (tester) async {
      final timeDate = FakeTimeDate();
      await pumpSection(
        tester,
        timeDate: timeDate,
        settingsAllowed: false,
        onBeforeChange: () async => false,
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(timeDate.ntpCalls, isEmpty);
      // And the switch is back where it was, because nothing moved.
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
    });

    testWidgets('a refused server edit neither pushes nor stores the list',
        (tester) async {
      // The bug this pins: the stored list used to be committed after the
      // write regardless of whether the write happened.
      final timeSync = FakeTimeSync(status: syncStatus());
      final stored = <List<String>>[];
      await pumpSection(
        tester,
        timeDate: FakeTimeDate(),
        timeSync: timeSync,
        storedServers: const ['first.example'],
        onServersChanged: (servers) async => stored.add(servers),
        settingsAllowed: false,
        onBeforeChange: () async => false,
      );

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Add server'), findsNothing);
      expect(timeSync.pushes, isEmpty);
      expect(stored, isEmpty);
    });

    testWidgets('an allowed session is asked once and then proceeds',
        (tester) async {
      // The guard must not become a second confirmation an engineer clicks
      // through on every change.
      final timeDate = FakeTimeDate();
      var asked = 0;
      await pumpSection(
        tester,
        timeDate: timeDate,
        onBeforeChange: () async {
          asked++;
          return true;
        },
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(asked, 1);
      expect(timeDate.ntpCalls, [false]);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });
  });

  testWidgets('the NTP pill names the file that outlives the HMI',
      (tester) async {
    // The runtime list this page edits dies with timesyncd; the pill is the
    // only place in the UI that says where the persistent one lives.
    await pumpSection(
      tester,
      timeDate: FakeTimeDate(),
      timeSync: FakeTimeSync(status: syncStatus()),
    );

    expect(find.textContaining('/etc/systemd/timesyncd.conf'), findsWidgets);
    expect(find.textContaining('ssh'), findsOneWidget);
  });
}
