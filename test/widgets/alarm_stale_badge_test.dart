/// The hold badge: an alarm whose rule D-3 has suspended says so, names the
/// dead input, and dates the hold.
///
/// The rig defect this closes (2026-09-08, SVN): "Cooler temperature" was
/// held true on a stale `cooler.temp.avg` from boot onwards. The engine's
/// hold was correct; the panel showed an ordinary warning that could never
/// clear, with nothing anywhere saying why. An operator can act on "check
/// this sensor"; they cannot act on a warning that ignores acknowledgement of
/// the plant's actual state.
///
/// Behavioural arms only — the visual is `alarm_list_golden_test.dart`'s,
/// which renders the same fixture in both themes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

import 'alarm_fixture.dart';

void main() {
  final held = alarm(
    'Cooler temperature',
    level: AlarmLevel.warning,
    at: DateTime(2026, 9, 8, 19, 18, 4),
    staleInputs: const ['cooler.temp.avg'],
    staleSince: DateTime(2026, 9, 8, 19, 18, 16),
  );
  final live = alarm(
    'Motor overload',
    level: AlarmLevel.error,
    at: DateTime(2026, 9, 8, 8, 15),
  );

  testWidgets('a held alarm names its dead input and dates the hold; a live '
      'one carries no badge', (tester) async {
    await pumpAlarmList(tester, AlarmFixture(active: {held, live}));

    expect(
      find.textContaining('Input stale since'),
      findsOneWidget,
      reason: 'exactly the held alarm — a badge on the live one too would '
          'teach operators the badge means nothing',
    );
    expect(find.textContaining('cooler.temp.avg'), findsOneWidget,
        reason: 'the operator\'s next act is to check this sensor by name');
    expect(find.textContaining('19:18:16'), findsOneWidget,
        reason: 'since WHEN is the difference between "glitch just now" and '
            '"dead since the morning"');
  });

  testWidgets('the detail card says the alarm is frozen until the input '
      'returns', (tester) async {
    await pumpAlarmDetail(tester, held);

    expect(find.textContaining('cooler.temp.avg'), findsOneWidget);
    expect(find.textContaining('cannot change state'), findsOneWidget,
        reason: 'the mirror hazard, stated where the operator reads: a held '
            'alarm can neither clear nor re-fire, so waiting for it to clear '
            'on its own is waiting for nothing');
  });

  testWidgets('the detail card of a live alarm says nothing about staleness',
      (tester) async {
    await pumpAlarmDetail(tester, live);

    expect(find.textContaining('Input stale'), findsNothing);
    expect(find.textContaining('cannot change state'), findsNothing);
  });

  testWidgets('the local gateway alarm and a held plant alarm share the list, '
      'and only the plant alarm carries the badge', (tester) async {
    // The two are different kinds of thing: the local alarm is this panel's
    // own report about its wire (never in any AlarmSource, never persisted),
    // while the badge is the backend's report about a PLANT input. A badge on
    // the local alarm would send an operator hunting for a sensor named
    // nowhere; the local alarm vanishing under the badge work would silence
    // the one report a dead gateway leaves.
    await pumpAlarmList(
      tester,
      AlarmFixture(active: {held}),
      extraOverrides: [
        gatewayLinkProvider.overrideWith(
          (ref) => Stream.value(describeGatewayLink(
            state: LinkState.down,
            url: Uri.parse('wss://10.50.10.11:9444'),
            elapsed: const Duration(minutes: 10),
            lastDownReason: 'the transport ended by remote close',
          )),
        ),
        gatewayLinkClockProvider
            .overrideWithValue(() => DateTime(2026, 9, 8, 20, 0)),
      ],
    );

    expect(find.text('Gateway unreachable'), findsOneWidget,
        reason: 'the local alarm still rides the list');
    expect(find.text('Cooler temperature'), findsOneWidget,
        reason: 'and the plant alarm is not displaced by it');
    expect(find.textContaining('Input stale since'), findsOneWidget,
        reason: 'exactly one badge — on the plant alarm, whose input it '
            'names, and never on the panel\'s own link report');
  });
}
