/// `/advanced/alarm-editor` — `configure` — over the relay.
///
/// Alarm rules are one shared preference, `alarm_man_config`. On a gateway
/// panel the editor lists them through `RelayAlarmSource` (which reads the
/// key over `preferences.getString`) and saves through
/// `preferences.setString` — the same wire the preferences page uses, and the
/// same live gap: the backend refuses the write. What this file adds to that
/// finding is the editor's own behaviour on top of it: `RelayAlarmSource.
/// updateAlarm` mutates its in-memory copy and fires the save without
/// awaiting it, so the page says "Alarm updated!" over a write the backend
/// threw away.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';

import '../support/backend_bench.dart';
import '../support/panel.dart';

const String _route = '/advanced/alarm-editor';
const String _title = 'Alarm Editor';
const String _alarmKey = 'alarm_man_config';
const String _editedTitle = 'Rate above five (edited)';

void alarmEditorCases(BackendBench Function() bench) {
  group('the alarm editor', () {
    testWidgets(
        'opens for an engineer and lists the rule the backend holds',
        (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const AlarmEditorPage()));
      // The seeded rule, by title — read over the wire from the row the
      // bench wrote. An editor over an empty or unreadable config renders
      // the add button and the search bar and no rows.
      await untilFound(tester, find.text(kSeededAlarmTitle),
          describe: 'the seeded alarm "$kSeededAlarmTitle" in the list');
      expect(find.byKey(const ValueKey('alarm-editor-add')), findsOneWidget);
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets(
        'a title edited in the form lands in the backend\'s '
        'alarm_man_config row', (tester) async {
      // Green since `BackendConfigWriter`. The write still goes out
      // fire-and-forget — `RelayAlarmSource`'s header names that gap and it
      // is unchanged — so what this case proves is that the row changes,
      // not that the editor would have been told if it had not.
      await useDesktopSurface(tester, size: const Size(1400, 1800));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      final before = await live(tester, () => bench().sharedPreference(_alarmKey));
      expect('$before', isNot(contains(_editedTitle)));

      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const AlarmEditorPage()));
      await untilFound(tester, find.text(kSeededAlarmTitle));

      // The tile's edit button opens the form in the right-hand pane.
      final tile = find.ancestor(
          of: find.text(kSeededAlarmTitle), matching: find.byType(ListTile));
      await tester.tap(find.descendant(
          of: tile,
          matching: find.byWidgetPredicate(
              (w) => w is IconButton && (w.icon as Icon).icon == Icons.edit)));
      await untilFound(
          tester, find.widgetWithText(TextFormField, 'Title'),
          describe: 'the edit form');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'), _editedTitle);
      await settleFrames(tester);
      await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Submit'));
      await settleFrames(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Submit'));
      // The page's own verdict, before the backend's: it announces success
      // the moment the in-memory copy changes, because `_saveConfig` is
      // fired and not awaited. Asserted so the red below is precisely "the
      // page said updated and the backend holds the old title".
      await untilFound(tester, find.text('Alarm updated!'),
          within: const Duration(seconds: 10),
          describe: 'the editor\'s own "Alarm updated!" snackbar');

      await untilTrueWhilePumping(tester, () async {
        final row = await bench().sharedPreference(_alarmKey);
        final decoded = jsonDecode('$row') as Map<String, dynamic>;
        return (decoded['alarms'] as List)
            .any((a) => a['title'] == _editedTitle);
      },
          within: const Duration(seconds: 15),
          describe: 'the backend\'s alarm_man_config to hold the new title');
      await dismount(tester);
    });

    testWidgets('the page locks for a verified operator', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1400));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kOperator, kOperatorPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const AlarmEditorPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.text(kSeededAlarmTitle), findsNothing);
      await dismount(tester);
    });
  });
}
