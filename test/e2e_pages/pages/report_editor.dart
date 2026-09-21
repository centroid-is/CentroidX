/// `/advanced/report-editor` — `configure` — over the relay.
///
/// Report and shift configuration live in three shared `config_item`
/// preference rows — `report_config`, `shift_config`, `alarm_man_config` —
/// which `ReportStore` used to reach only through `mcpDatabaseProvider` →
/// `databaseProvider`, null on a gateway panel. The page then said *"Database
/// is not connected."*, which was true about the PANEL and false about the
/// plant: the backend was holding the reports the whole time.
///
/// **Closed 2026-09-20, and with no new wire family.** The three documents
/// are shared preferences and the relay already carries those, so the store
/// got the read seam that mirrors its existing write seam and the gateway
/// branch binds both to `preferencesProvider` — which is `RelayedPreferences`
/// on this transport. Every save therefore lands on the same rows the MCP
/// server writes, graded by `KeyPolicy.canWritePreference` and audited at the
/// gateway, rather than through a second family that would be a second way to
/// write three rows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/report_editor.dart'
    show ReportEditorPage, kReportEditorSaveKey;
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_dart/core/report.dart' show ReportConfig, ReportManConfig;
import 'package:tfc_dart/core/report_store.dart' show ReportStore;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show DataServiceMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/report-editor';
const String _title = 'Report Editor';
const String _seededReport = 'E2E shift report';

void reportEditorCases(BackendBench Function() bench) {
  group('the report editor', () {
    /// Writes the backend's report definition the way a station does: through
    /// the store over the shared rows, never through the wire this lane is
    /// testing.
    Future<void> seed(WidgetTester tester) => live(tester, () async {
          final store = ReportStore(bench().database.db, isPostgres: true);
          await store.saveReports(ReportManConfig(reports: [
            ReportConfig(id: 'e2e-shift', name: _seededReport),
          ]));
          final back = await store.loadReports();
          expect(back.reports.map((r) => r.name), contains(_seededReport),
              reason: 'the anti-vacuity check: the backend holds the row '
                  'before any panel dials, so "the editor listed it" is a '
                  'statement about the relay and not about an empty list');
        });

    testWidgets(
        'opens for an engineer and lists the report definition the BACKEND '
        'holds', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1800));
      await seed(tester);
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ReportEditorPage()));
      await untilFound(tester, find.text(_seededReport),
          within: const Duration(seconds: 15),
          describe: 'the backend\'s report "$_seededReport" in the editor');
      expect(find.text('Database is not connected.'), findsNothing,
          reason: 'that sentence was true about the panel and false about '
              'the plant — the whole of what this closed');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets(
        'an edit made in the widget lands in the BACKEND\'s shared rows',
        (tester) async {
      // Red for ONE reason, and it was not this page's:
      // `BackendSharedPreferences.setString` refused every shared preference
      // write by name — "a live gap, not a resolved one", in its own header's
      // words, with the fix it needed named there: a backend-side writer
      // sharing the relay's `action_id` with its audit row. That writer is
      // `BackendConfigWriter`, and landing it turned this case, the
      // preferences JSON editor and the alarm editor green together, which is
      // why all three were pinned rather than worked around.
      // The strongest claim this page can make, and the one a read-only fix
      // would fail: the bytes at the far end change. The save goes through
      // `GuardedReportStore` and out over `preferences.setString`, so what is
      // being proven is the whole door — grade, audit, compare-and-swap and
      // the row — and not just that a list rendered.
      const renamed = 'E2E shift report (edited over the relay)';
      await useDesktopSurface(tester, size: const Size(1400, 1800));
      await seed(tester);
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ReportEditorPage()));
      await untilFound(tester, find.text(_seededReport),
          within: const Duration(seconds: 15));

      await tester.tap(find.text(_seededReport));
      await settleFrames(tester, frames: 8);
      final nameField = find.byKey(const ValueKey('report-name-e2e-shift'));
      expect(nameField, findsOneWidget,
          reason: 'the editor opens the report it was asked to edit');
      await tester.enterText(nameField, renamed);
      await settleFrames(tester, frames: 8);

      // The save control has to be ENABLED before it is tapped. A disabled
      // button swallows the tap silently, and the read-back below would then
      // time out saying the backend never got the edit — which is true, and
      // blames the wire for something the widget never attempted.
      final save = tester.widget<FilledButton>(
          find.byKey(kReportEditorSaveKey));
      expect(save.onPressed, isNotNull,
          reason: 'the editor has an unsaved change and is not mid-save, so '
              'Save must be live');
      await tester.tap(find.byKey(kReportEditorSaveKey));
      await settleFrames(tester, frames: 12);

      await live(tester, () => untilTrue(() async {
            final store =
                ReportStore(bench().database.db, isPostgres: true);
            final back = await store.loadReports();
            return back.reports.any((r) => r.name == renamed);
          },
          within: const Duration(seconds: 15),
          describe: 'the backend\'s report_config row to hold the edit'));
      await dismount(tester);
    });

    testWidgets(
        'the gateway takes a report_config write from an engineer over '
        'preferences.setString', (tester) async {
      // The door the editor's save goes through, tested on its own — and the
      // case that says exactly where the gap is, so a failure of the one
      // above cannot be mistaken for a widget that never issued the write.
      //
      // What it gets today:
      //
      //   error -32011: preferences.setString failed: Unsupported operation:
      //   BackendSharedPreferences.setString: the backend does not write the
      //   plant's shared configuration.
      //
      // That refusal is correct about what the backend is today and wrong
      // about what a gateway has to be: the plant's configuration is edited
      // from panels, and on this transport every panel is relayed.
      const probeJson = '{"reports":[{"id":"probe","name":"probe report"}]}';
      await live(tester, () async {
        final eng = await WireProbe.signedIn(bench().port,
            username: kEngineer, password: kEngineerPassword);
        final wrote = await eng.call(DataServiceMethods.prefSetString,
            {'key': 'report_config', 'value': probeJson});
        expect(wrote.isError, isFalse,
            reason: 'report_config is classified `configure` in '
                'kPrefAccessRules and the engineer holds it: $wrote');
        final read = await eng.call(
            DataServiceMethods.prefGetString, {'key': 'report_config'});
        expect(read.result, probeJson,
            reason: 'the write landed on the backend\'s shared row and is '
                'what the next read answers: $read');
        await eng.close();

        final op = await WireProbe.signedIn(bench().port,
            username: kOperator, password: kOperatorPassword);
        final refused = await op.call(DataServiceMethods.prefSetString,
            {'key': 'report_config', 'value': probeJson});
        expect(refused.isError, isTrue,
            reason: 'an operator may open no report editor and may write no '
                'report definition: $refused');
        await op.close();
      });
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
          hostRoute(panel, _route, _title, const ReportEditorPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.text(_seededReport), findsNothing,
          reason: 'a locked page renders none of the backend\'s documents');
      await dismount(tester);
    });
  });
}
