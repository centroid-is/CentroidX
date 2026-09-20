/// `/advanced/page-editor` — `configure` — over the relay.
///
/// Pages and their assets are `config_item` rows of kind `page` and `asset`.
/// The editor reads them through `pageManagerProvider`, which on a station
/// build is the device-local mirror (`page_manager.dart:48-70`), and saves
/// through the same mirror (`page_editor.dart` `_saveToPrefs`). The wire has
/// `configItems.items` for a browser to READ pages by, and no method to write
/// one. So on a gateway station the editor is a full editor over a copy the
/// backend never sees — which is what the two KNOWN RED cases below measure,
/// against a page row seeded at the backend and a save made in the editor.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart' show AssetPage;
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show AccessMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/page-editor';
const String _title = 'Page Editor';

/// The page seeded at the backend: the label is what a page list renders.
const String _seededPageId = 'e2e-seeded-page';
const String _seededPageLabel = 'E2E Seeded Hall';

Finder _saveFab() => find.byWidgetPredicate(
    (w) => w is FloatingActionButton && w.heroTag == 'save');

void pageEditorCases(BackendBench Function() bench) {
  group('the page editor', () {
    testWidgets('opens for an engineer with its canvas and its save control',
        (tester) async {
      await useDesktopSurface(tester, size: const Size(1600, 1200));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, PageEditor(proposalData: null)));
      await untilFound(tester, _saveFab(), describe: 'the editor\'s save FAB');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED (found here): the editor lists a page that exists at the '
        'backend', (tester) async {
      await useDesktopSurface(tester, size: const Size(1600, 1200));
      await live(tester, () => bench().seedPage(
            _seededPageId,
            AssetPage(
              menuItem: const MenuItem(
                  label: _seededPageLabel,
                  path: '/e2e-seeded',
                  icon: Icons.factory),
              assets: const [],
              mirroringDisabled: false,
            ).toJson(),
          ));
      final rows = await live(tester, bench().pageRows);
      expect(rows.map((r) => r.id), contains(_seededPageId),
          reason: 'the backend holds the row before the editor is opened');

      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, PageEditor(proposalData: null)));
      await untilFound(tester, _saveFab());
      await untilFound(tester, find.textContaining(_seededPageLabel),
          within: const Duration(seconds: 15),
          describe: 'the backend\'s page "$_seededPageLabel" in the editor');
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED (found here): a save made in the editor lands in the '
        'backend\'s page rows', (tester) async {
      // The editor holds the built-in layout the mirror seeded itself with;
      // the backend holds one seeded row. A save that reached the backend
      // would put the editor's pages beside it.
      await useDesktopSurface(tester, size: const Size(1600, 1200));
      final before = await live(tester, bench().pageRows);
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, PageEditor(proposalData: null)));
      await untilFound(tester, _saveFab());
      await tester.tap(_saveFab());
      await settleFrames(tester, frames: 10);
      await live(tester, () => untilTrue(() async {
            final rows = await bench().pageRows();
            return rows.length > before.length;
          },
          within: const Duration(seconds: 10),
          describe: 'the backend\'s page rows to grow by the editor\'s save '
              '(${before.length} before)'));
      await dismount(tester);
    });

    testWidgets(
        'the gateway serves configItems.items(page) to the engineer and '
        'refuses it to a session holding no group', (tester) async {
      final port = bench().port;
      await live(tester, () async {
        final eng = await WireProbe.signedIn(port,
            username: kEngineer, password: kEngineerPassword);
        final items =
            await eng.call(AccessMethods.configItemsItems, {'kind': 'page'});
        expect(items.isError, isFalse, reason: '$items');
        expect((items.result as List).map((r) => (r as Map)['id']),
            contains(_seededPageId));
        await eng.close();

        await bench().revokeAnonymous();
        try {
          final nothing = await WireProbe.anonymous(port);
          final refused = await nothing
              .call(AccessMethods.configItemsItems, {'kind': 'page'});
          expect(refused.errorCode, WireErrors.forbidden, reason: '$refused');
          await nothing.close();
        } finally {
          await bench().restoreAnonymous();
        }
      });
    });

    testWidgets('the page locks for a verified operator', (tester) async {
      await useDesktopSurface(tester, size: const Size(1600, 1200));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kOperator, kOperatorPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, PageEditor(proposalData: null)));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(_saveFab(), findsNothing);
      await dismount(tester);
    });
  });
}
