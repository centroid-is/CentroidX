/// `/advanced/report-editor` — `configure` — over the relay.
///
/// Report and shift configuration live in rows the MCP server shares, read by
/// `reportStoreProvider` over `mcpDatabaseProvider` → `databaseProvider`
/// (`report.dart:13-25`) — null on a gateway panel, and no wire method
/// carries them. The page renders "Database is not connected." — true, and
/// the operator can act on it — and the RED half is that the backend's report
/// definitions cannot be edited from a relayed panel at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/report_editor.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_dart/core/report.dart' show ReportConfig, ReportManConfig;
import 'package:tfc_dart/core/report_store.dart' show ReportStore;

import '../support/backend_bench.dart';
import '../support/panel.dart';

const String _route = '/advanced/report-editor';
const String _title = 'Report Editor';
const String _seededReport = 'E2E shift report';

void reportEditorCases(BackendBench Function() bench) {
  group('the report editor', () {
    testWidgets(
        'opens for an engineer and says the database is not connected, '
        'rather than showing an empty report list', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1800));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ReportEditorPage()));
      await untilFound(tester, find.text('Database is not connected.'),
          describe: 'the honest no-store sentence');
      expect(find.text('Add report'), findsNothing,
          reason: 'no editing controls over a store that is not there');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED (found here): a report definition the backend holds is '
        'listed on a relayed panel', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1800));
      await live(tester, () async {
        final store = ReportStore(bench().database.db, isPostgres: true);
        await store.saveReports(ReportManConfig(reports: [
          ReportConfig(id: 'e2e-shift', name: _seededReport),
        ]));
        final back = await store.loadReports();
        expect(back.reports.map((r) => r.name), contains(_seededReport),
            reason: 'the backend holds the row before the page opens');
      });
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
          within: const Duration(seconds: 10),
          describe: 'the backend\'s report "$_seededReport" in the editor');
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
          hostRoute(panel, _route, _title, const ReportEditorPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.text('Database is not connected.'), findsNothing);
      await dismount(tester);
    });
  });
}
