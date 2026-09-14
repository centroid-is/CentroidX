/// TD-004 (v1.1.x): widget-level coverage for [ConnectionStatusChip].
///
/// Pins the contract that when an [EffectiveDeviceStatus] is supplied:
///   - `connected`        → green "Connected"
///   - `connecting`       → orange "Connecting..."
///   - `disconnected`     → red "Disconnected"
///   - `umasUnhealthy`    → amber "UMAS error"  (TD-004 NEW)
///   - `opcuaUnhealthy`   → deep-orange "No data" (frozen-session fix)
///   - `opcuaUnmonitored` → amber "Unmonitored"
///
/// And when only the legacy TCP [ConnectionStatus] is supplied, the
/// chip falls back to its pre-TD-004 behavior (no regression for
/// OPC UA / JBTM / classic-Modbus cards).
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/connection_status_chip.dart';
import 'package:tfc_dart/core/state_man.dart'
    show ConnectionStatus, EffectiveDeviceStatus;

Future<void> _pump(WidgetTester tester, Widget chip) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: chip))),
  );
}

void main() {
  group('ConnectionStatusChip — TD-004 EffectiveDeviceStatus rendering', () {
    testWidgets('umasUnhealthy renders "UMAS error" amber pill', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connected,
          effectiveStatus: EffectiveDeviceStatus.umasUnhealthy,
        ),
      );
      expect(find.text('UMAS error'), findsOneWidget);
      // Diagnostic tooltip must explain WHY for the operator.
      final tooltip = t.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('Data Dictionary'));
      expect(tooltip.message, contains('reservation'));
    });

    testWidgets('opcuaUnhealthy renders "No data" pill with a frozen-values '
        'tooltip', (t) async {
      // The frozen-session shape: the event-driven status still says
      // connected, but the heartbeat went silent and effectiveStatus
      // dropped to opcuaUnhealthy. The chip must side with the data plane.
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connected,
          effectiveStatus: EffectiveDeviceStatus.opcuaUnhealthy,
        ),
      );
      expect(find.text('No data'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      // The tooltip must tell the operator the on-screen values are stale —
      // that is the whole point of the state.
      final tooltip = t.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('frozen'));
      expect(tooltip.message, contains('heartbeat'));
    });

    testWidgets('opcuaUnmonitored does NOT claim the data is missing',
        (t) async {
      // The incident this split exists for: a station delivering sub-second
      // values, with a chip reading "No data" beside it, because the client
      // could not create the subscription it watches itself with. Two
      // different facts; the second one was false.
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connected,
          effectiveStatus: EffectiveDeviceStatus.opcuaUnmonitored,
        ),
      );
      expect(find.text('Unmonitored'), findsOneWidget);
      expect(find.text('No data'), findsNothing);
      // Not green either — an unwatched client is not a healthy one.
      expect(find.text('Connected'), findsNothing);
      final tooltip = t.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('no health clock'));
      expect(tooltip.message, contains('may still be arriving'));
    });

    testWidgets('statusDetail carries the server\'s own reason into the '
        'tooltip', (t) async {
      // heartbeatUnavailable holds the refusal the server gave. It used to
      // live only in the log, which is not somewhere an operator looking at
      // a chip can reach.
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connected,
          effectiveStatus: EffectiveDeviceStatus.opcuaUnmonitored,
          statusDetail: 'No health clock: could not create a subscription '
              '(BadTooManySubscriptions).',
        ),
      );
      final tooltip = t.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('BadTooManySubscriptions'));
    });

    testWidgets('a statusDetail alone is enough to earn a tooltip', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connected,
          effectiveStatus: EffectiveDeviceStatus.connected,
          statusDetail: 'something worth saying',
        ),
      );
      final tooltip = t.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'something worth saying');
    });

    testWidgets('connected EffectiveDeviceStatus renders "Connected"',
        (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connected,
          effectiveStatus: EffectiveDeviceStatus.connected,
        ),
      );
      expect(find.text('Connected'), findsOneWidget);
      // No tooltip when status is healthy.
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('connecting EffectiveDeviceStatus renders "Connecting..."',
        (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.connecting,
          effectiveStatus: EffectiveDeviceStatus.connecting,
        ),
      );
      expect(find.text('Connecting...'), findsOneWidget);
    });

    testWidgets('disconnected EffectiveDeviceStatus renders "Disconnected"',
        (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(
          status: ConnectionStatus.disconnected,
          effectiveStatus: EffectiveDeviceStatus.disconnected,
        ),
      );
      expect(find.text('Disconnected'), findsOneWidget);
    });
  });

  group(
      'ConnectionStatusChip — fallback to pure TCP behavior when '
      'effectiveStatus is null',
      () {
    testWidgets('connected → "Connected"', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(status: ConnectionStatus.connected),
      );
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('connecting → "Connecting..."', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(status: ConnectionStatus.connecting),
      );
      expect(find.text('Connecting...'), findsOneWidget);
    });

    testWidgets('disconnected → "Disconnected"', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(status: ConnectionStatus.disconnected),
      );
      expect(find.text('Disconnected'), findsOneWidget);
    });

    testWidgets('null + stateManLoading=true → "Loading..."', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(status: null, stateManLoading: true),
      );
      expect(find.text('Loading...'), findsOneWidget);
    });

    testWidgets('null + stateManLoading=false → "Not active"', (t) async {
      await _pump(
        t,
        const ConnectionStatusChip(status: null),
      );
      expect(find.text('Not active'), findsOneWidget);
    });
  });
}
