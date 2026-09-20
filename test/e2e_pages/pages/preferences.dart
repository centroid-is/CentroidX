/// `/advanced/preferences` — `administer` — over the relay.
///
/// The page lists every shared preference through `preferences.getAll` and
/// writes one back through `preferences.setString` — `RelayedPreferences`
/// over `GatewayPreferencesSlot` on the panel, `BackendPreferences` over
/// `BackendSharedPreferences` at the backend. The read half is real. The
/// write half is the one live gap this lane found that the backend's own
/// source names: `backend_shared_preferences.dart` refuses every shared write
/// by design ("gateway panels could write shared preferences through this
/// route before the merge, and cannot now"), so the round trip is KNOWN RED
/// and says so.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/preferences.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show DataServiceMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/preferences';
const String _title = 'Preferences';

/// The seeded alarm row, which is the one shared preference of known content.
const String _alarmKey = 'alarm_man_config';

/// What the edit writes into the alarm's description.
const String _editedDescription = 'edited on the preferences page';

void preferencesCases(BackendBench Function() bench) {
  group('the preferences page', () {
    testWidgets(
        'opens for an engineer and lists the shared preferences the backend '
        'holds, by key', (tester) async {
      await useDesktopSurface(tester, size: const Size(1200, 2600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const PreferencesPage()));

      // The keys card, populated from `preferences.getAll` over the wire.
      // "No preferences found." is the hole; the seeded alarm row is the
      // content.
      await untilFound(tester, find.text('Preferences Keys'),
          describe: 'the keys card');
      // The tile's title carries its origin as a prefix — "(DB)
      // alarm_man_config" — so the match is by containment.
      await untilFound(tester, find.textContaining(_alarmKey),
          describe: 'the seeded $_alarmKey row, served by the backend');
      expect(find.text('No preferences found.'), findsNothing);
      expect(find.textContaining('Error:'), findsNothing);
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED (live gap): a value saved in the JSON editor lands in the '
        'backend\'s shared row', (tester) async {
      // `BackendSharedPreferences.setString` throws `UnsupportedError`; the
      // relay carries it as handlerFailed; the page shows "Not saved". The
      // correct behaviour — the one the page's Save button promises — is the
      // row changing. Closing the gap "means a backend-side writer that
      // shares the relay's action_id with its audit row — a design, not a
      // merge fix" (backend_shared_preferences.dart's header).
      await useDesktopSurface(tester, size: const Size(1200, 2600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      final before = await live(tester, () => bench().sharedPreference(_alarmKey));
      expect('$before', isNot(contains(_editedDescription)),
          reason: 'anti-vacuity: the row must not already hold the edit');

      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const PreferencesPage()));
      await untilFound(tester, find.textContaining(_alarmKey));

      // Expand the row: the JSON editor is one of its children.
      await tester.ensureVisible(find.textContaining(_alarmKey).first);
      await settleFrames(tester);
      await tester.tap(find.textContaining(_alarmKey).first);
      await untilFound(tester, find.text('Format JSON'),
          describe: 'the JSON editor for $_alarmKey');
      final editor = find.byWidgetPredicate((w) =>
          w is TextField &&
          (w.controller?.text.contains('"alarms"') ?? false));
      await untilFound(tester, editor, describe: 'the editor\'s text field');
      final current = tester.widget<TextField>(editor).controller!.text;
      final decoded = jsonDecode(current) as Map<String, dynamic>;
      (decoded['alarms'] as List).first['description'] = _editedDescription;
      await tester.enterText(editor, jsonEncode(decoded));
      await settleFrames(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save').first);
      await settleFrames(tester, frames: 10);

      await live(tester, () => untilTrue(() async {
            final row = await bench().sharedPreference(_alarmKey);
            return '$row'.contains(_editedDescription);
          },
          within: const Duration(seconds: 10),
          describe: 'the backend\'s $_alarmKey row to hold the edit'));
      await dismount(tester);
    });

    testWidgets(
        'the gateway refuses preferences.setString to a verified operator '
        'and to nobody, and preferences.getAll to nobody once the anonymous '
        'account grants nothing', (tester) async {
      final port = bench().port;
      final before = await live(tester, () => bench().sharedPreference(_alarmKey));
      await live(tester, () async {
        final op = await WireProbe.signedIn(port,
            username: kOperator, password: kOperatorPassword);
        final write = await op.call(DataServiceMethods.prefSetString,
            {'key': _alarmKey, 'value': '{"alarms":[]}'});
        expect(write.errorCode, WireErrors.forbidden, reason: '$write');
        expect(write.errorMessage, contains('configure'),
            reason: 'alarm rules are configuration; the refusal names the '
                'group');
        // The read floor is `operate`, which the operator holds: reads are
        // the control that the refusal above is about the WRITE.
        final read = await op.call(DataServiceMethods.prefGetString,
            {'key': _alarmKey});
        expect(read.isError, isFalse, reason: '$read');
        expect('${read.result}', contains(kSeededAlarmTitle));
        await op.close();

        final nobody = await WireProbe.anonymous(port);
        final anonWrite = await nobody.call(DataServiceMethods.prefSetString,
            {'key': _alarmKey, 'value': '{"alarms":[]}'});
        expect(anonWrite.errorCode, WireErrors.forbidden,
            reason: '$anonWrite');
        await nobody.close();

        // The deployment's other choice: an anonymous row granting nothing.
        // Then a socket nobody signed in on may not even read.
        await bench().revokeAnonymous();
        try {
          final nothing = await WireProbe.anonymous(port);
          final anonRead =
              await nothing.call(DataServiceMethods.prefGetAll, const {});
          expect(anonRead.errorCode, WireErrors.forbidden,
              reason: '$anonRead');
          expect(anonRead.errorMessage, contains('awaiting_sign_in'),
              reason: '§10: nobody signed in carries the marker the client '
                  'keys its sign-in screen off');
          await nothing.close();
        } finally {
          await bench().restoreAnonymous();
        }
      });
      final after = await live(tester, () => bench().sharedPreference(_alarmKey));
      expect(after, before, reason: 'no refused write may have changed the row');
    });

    testWidgets('the page locks for a verified operator', (tester) async {
      await useDesktopSurface(tester, size: const Size(1200, 1400));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kOperator, kOperatorPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const PreferencesPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.text('Preferences Keys'), findsNothing);
      expect(find.textContaining(_alarmKey), findsNothing);
      await dismount(tester);
    });
  });
}
