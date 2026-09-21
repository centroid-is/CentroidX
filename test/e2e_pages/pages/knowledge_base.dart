/// `/advanced/knowledge-base` — `configure` — over the relay.
///
/// The library reads `mcpDatabaseProvider` → `databaseProvider`
/// (`tech_doc.dart:35-36`), null on a gateway panel, and no wire method
/// carries documents. The page's empty state is "No resources found" —
/// which, over the relay, is not a fact about the library but about the
/// panel's lack of a route to it. That is the section-shaped hole this lane
/// exists to name, and the KNOWN RED case pins the honest sentence in its
/// place. Compiled in by default (`kKnowledgeEnabled`); a flag-off build
/// has no route to gate.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/feature_flags.dart' show kKnowledgeEnabled;
import 'package:tfc/pages/tech_doc_library.dart';
import 'package:tfc/tech_docs/tech_doc_library_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';

import '../support/backend_bench.dart';
import '../support/panel.dart';

const String _route = '/advanced/knowledge-base';
const String _title = 'Knowledge Base';

void knowledgeBaseCases(BackendBench Function() bench) {
  group('the knowledge base', () {
    testWidgets('opens for an engineer', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const TechDocLibraryPage()));
      // NOT `find.text('Knowledge Base')`. That string is the ExpansionTile
      // title the section renders only when `embedded: true`
      // (`tech_doc_library_section.dart:146,154`), and this page mounts it
      // with `embedded: false`, which returns the content directly. Nor is it
      // the app bar: `BaseScaffold.title` is accepted and never rendered. The
      // section itself, and one control an operator can see, is what "opened"
      // means here.
      await untilFound(tester, find.byType(TechDocLibrarySection),
          describe: 'the library section');
      await untilFound(tester, find.text('Upload PDF'),
          describe: 'the library\'s own controls');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets(
        'over the relay the library says it cannot be reached, not that it '
        'is empty', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const TechDocLibraryPage()));
      // No tap: `embedded: false` renders the list without an expander, so
      // the empty state is on screen as soon as the query answers.
      await untilFound(tester, find.byType(TechDocLibrarySection));
      await settleFrames(tester, frames: 10);
      await neverFound(tester, find.text('No resources found'),
          const Duration(seconds: 3),
          describe: '"No resources found" is a claim about the library, '
              'and this panel never read it');
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
          hostRoute(panel, _route, _title, const TechDocLibraryPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.byType(TechDocLibraryPage), findsNothing,
          reason: 'the gate renders the lock INSTEAD of the page');
      await dismount(tester);
    });
  }, skip: kKnowledgeEnabled ? null : 'CENTROIDX_KNOWLEDGE=false: no route');
}
