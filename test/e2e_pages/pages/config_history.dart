/// `/advanced/config-history` — `configure` — over the relay.
///
/// The history IS `config_change`. It used to be read by
/// `configChangeStoreProvider` straight from `databaseProvider`, which a
/// gateway panel answers null, and there was no `configHistory.*` on the
/// wire — so every relayed panel on the plant saw a configuration nobody had
/// ever changed. The page was at least honest about it ("the history is not
/// reachable over the relay", never "no changes"), and honest about a hole is
/// still a hole.
///
/// **Closed 2026-09-20.** Three reads — `configHistory.changesPage`,
/// `.changesByAction`, `.changeCountsByAction` — serve the same
/// `ConfigChangeStore` the panel calls in direct mode, graded `configure` by
/// `_PolicyConfigHistory` because that is the group
/// `kRaisedRoutes[kConfigHistoryRoute]` already demands. What this file pins
/// is that a relayed panel now sees the backend's rows, that the grading is
/// the gateway's rather than the panel's, and that the page's unavailable
/// screen has stopped being what a relayed engineer meets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/config_history.dart';
import 'package:tfc/pages/audit_trail.dart'
    show AuditTrailPage, AuditTrailScope;
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show AccessMethods, ConfigHistoryQueryParams;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/config-history';

/// The action the bench's key-mapping seed writes under
/// (`_seedSharedRows`). Named here so a renamed seed fails this file rather
/// than quietly making its assertions vacuous.
const String _seedAction = 'e2e-seed-keys';

void configHistoryCases(BackendBench Function() bench) {
  group('the configuration history', () {
    testWidgets(
        'opens for an engineer and lists the BACKEND\'s configuration '
        'changes, not an unavailable screen', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1600));
      // The anti-vacuity check, and it has to come first: the rows this case
      // is about have to exist at the backend before the page is asked for
      // them, or "the list rendered" would be a statement about an empty
      // list.
      final seeded = await live(tester, () => bench().configChangeRows());
      expect(seeded, isNotEmpty,
          reason: 'the bench seeds key mappings through a station-shaped '
              'store, so config_change holds rows before any panel dials');
      expect(seeded.map((r) => r.change.actionId), contains(_seedAction));

      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(
          panel, _route, kConfigHistoryTitle, const AuditTrailPage(scope: AuditTrailScope.configuration)));

      await untilFound(tester, find.byKey(kConfigHistoryListKey),
          within: const Duration(seconds: 15),
          describe: 'the history list, with the backend\'s changes');
      // By content, not just by key: the engineer who made the seeded change
      // is named on a row. A list that rendered with nothing in it would
      // satisfy the key alone.
      await untilFound(tester, find.textContaining(kEngineer),
          within: const Duration(seconds: 10),
          describe: 'a row attributed to the account that made the change');
      expect(find.byKey(kConfigHistoryUnavailableKey), findsNothing,
          reason: 'the unavailable screen is what a relayed panel used to '
              'meet, and the whole of what this family closed');
      expect(find.byKey(kConfigHistoryEmptyKey), findsNothing,
          reason: '"no changes match" would be a lie about a table that '
              'holds the seed\'s rows');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets(
        'the gateway serves configHistory.* to an engineer and refuses it to '
        'a verified operator and to nobody — the page\'s gate is the '
        'affordance, the refusal is the property', (tester) async {
      final port = bench().port;
      await live(tester, () async {
        // The control first: the same frames succeed for a session holding
        // `configure`, so the refusals below are about the group and not
        // about the frames.
        final eng = await WireProbe.signedIn(port,
            username: kEngineer, password: kEngineerPassword);
        final page = await eng.call(AccessMethods.configHistoryChangesPage,
            {'query': const ConfigHistoryQueryParams().toJson()});
        expect(page.isError, isFalse, reason: '$page');
        final rows = ((page.result as Map)['rows'] as List);
        expect(rows, isNotEmpty,
            reason: 'the control reads the seed\'s real rows');
        // `rawCount` is the raw read and not the decoded list — the number
        // the page judges "reached the cap" by. A wire that dropped it would
        // hide the Load-more control behind one unreadable row.
        expect((page.result as Map)['rawCount'], isA<int>());

        final counts = await eng.call(
            AccessMethods.configHistoryCountsByAction,
            {'actionIds': const [_seedAction]});
        expect(counts.isError, isFalse, reason: '$counts');
        expect((counts.result as Map)[_seedAction], isA<int>(),
            reason: 'the unfiltered total the "N of M hidden" line is built '
                'from');

        final byAction = await eng.call(
            AccessMethods.configHistoryChangesByAction,
            {'actionIds': const [_seedAction, 'no-such-action']});
        expect(byAction.isError, isFalse, reason: '$byAction');
        final map = byAction.result as Map;
        expect(map[_seedAction], isA<List>());
        expect(map.containsKey('no-such-action'), isFalse,
            reason: 'an action nobody wrote is ABSENT, not present with an '
                'empty list — an empty list would be a claim about the '
                'action rather than the absence of one');
        await eng.close();

        // A verified operator: the credential is real, the role is real, the
        // group is not there.
        final op = await WireProbe.signedIn(port,
            username: kOperator, password: kOperatorPassword);
        final refused = await op.call(AccessMethods.configHistoryChangesPage,
            {'query': const ConfigHistoryQueryParams().toJson()});
        expect(refused.errorCode, WireErrors.forbidden, reason: '$refused');
        expect(refused.errorMessage, contains('configure'),
            reason: 'the refusal names the group the route already demands');
        final refusedCounts = await op.call(
            AccessMethods.configHistoryCountsByAction,
            {'actionIds': const [_seedAction]});
        expect(refusedCounts.errorCode, WireErrors.forbidden,
            reason: 'every member of the family is graded, not just the one '
                'a page happens to call first: $refusedCounts');
        await op.close();

        final nobody = await WireProbe.anonymous(port);
        final anon = await nobody.call(AccessMethods.configHistoryChangesPage,
            {'query': const ConfigHistoryQueryParams().toJson()});
        expect(anon.errorCode, WireErrors.forbidden, reason: '$anon');
        await nobody.close();
      });
    });

    testWidgets(
        'Load more walks BACKWARDS through the log — the cursor is not the '
        'same page forever', (tester) async {
      // The case that would have caught the worst defect in this family.
      //
      // `ConfigChangeStore` compares `at` as TEXT (drift compares two
      // `Expression<DateTime>` through SQLite's `julianday()`, which Postgres
      // does not have), and its `(at, id)` cursor has an EQUALITY half: rows
      // AT the cursor's instant with a smaller id, because one `writeItems`
      // stamps every row of an action with one `at` and a strict comparison
      // can never land inside such a group.
      //
      // Two things broke that over the wire, and neither shows up in a
      // single-page test. The bound was built `isUtc: true` while the rows
      // are written local, so drift rendered `…Z` against `… +00:00` and the
      // two do not sort against each other. And the cursor travelled in
      // MILLISECONDS while `at` is stamped in microseconds, so the equality
      // half could never match the row it came from.
      //
      // The symptom was not an error. Page two came back identical to page
      // one, forever — an engineer scrolling a plant's configuration history
      // reading the same two rows and concluding that was all there was.
      await live(tester, () async {
        final probe = await WireProbe.signedIn(bench().port,
            username: kEngineer, password: kEngineerPassword);

        Future<(List<int> ids, int? cursorUs, int? cursorId)> page(
            {int? beforeUs, int? beforeId}) async {
          final answer = await probe.call(
              AccessMethods.configHistoryChangesPage, {
            'query': ConfigHistoryQueryParams(
              limit: 2,
              beforeUs: beforeUs,
              beforeId: beforeId,
            ).toJson(),
          });
          expect(answer.isError, isFalse, reason: '$answer');
          final result = answer.result as Map;
          final rows = (result['rows'] as List).cast<Map>();
          return (
            [for (final row in rows) row['id'] as int],
            result['oldestAtUs'] as int?,
            result['oldestId'] as int?,
          );
        }

        // Every row, in one page, as the set paging must reproduce.
        final whole = await probe.call(
            AccessMethods.configHistoryChangesPage,
            {'query': const ConfigHistoryQueryParams(limit: 500).toJson()});
        expect(whole.isError, isFalse, reason: '$whole');
        final allIds = [
          for (final row in ((whole.result as Map)['rows'] as List).cast<Map>())
            row['id'] as int,
        ];
        expect(allIds.length, greaterThan(2),
            reason: 'the seed writes more than two change rows, so a page of '
                'two is a page and not the whole log');

        // **The assertion is that paging loses nothing**, not merely that the
        // cursor moves. The first version of this case checked that page two
        // differed from page one, and a millisecond-truncated cursor passed
        // it: one `writeItems` stamps every row of an action with ONE `at`,
        // so a cursor that cannot match its own row falls back to the strict
        // comparison and silently skips the rest of that action — page two
        // is then full of older rows from a different action, different from
        // page one and missing everything in between.
        final seen = <int>[];
        int? beforeUs;
        int? beforeId;
        for (var guard = 0; guard < 20; guard++) {
          final next = await page(beforeUs: beforeUs, beforeId: beforeId);
          if (next.$1.isEmpty) break;
          expect(next.$1.toSet().intersection(seen.toSet()), isEmpty,
              reason: 'a page repeated rows already walked — the cursor is '
                  'not moving. seen $seen, got ${next.$1}');
          seen.addAll(next.$1);
          beforeUs = next.$2;
          beforeId = next.$3;
        }
        expect(seen.toSet(), allIds.toSet(),
            reason: 'paging two at a time must reach every row the one-page '
                'read returns. Missing '
                '${allIds.toSet().difference(seen.toSet())}');

        await probe.close();
      });
    });

    testWidgets(
        'a kind this gateway does not know is refused, not silently dropped',
        (tester) async {
      // An empty kind list means "every kind", so dropping an unknown name
      // does not narrow the filter — it removes it, and the panel gets the
      // whole log under a chip it believes is selective. A panel one build
      // ahead of its gateway is the ordinary case during a rollout.
      await live(tester, () async {
        final probe = await WireProbe.signedIn(bench().port,
            username: kEngineer, password: kEngineerPassword);
        final refused = await probe.call(
            AccessMethods.configHistoryChangesPage, {
          'query': const ConfigHistoryQueryParams(
              kindWireNames: ['kind-from-a-newer-build']).toJson(),
        });
        expect(refused.isError, isTrue,
            reason: 'an answer here is indistinguishable from a real one: '
                '$refused');

        // The control: a kind it DOES know still filters, so the refusal is
        // about the unknown name and not about the parameter.
        final known = await probe.call(
            AccessMethods.configHistoryChangesPage, {
          'query': const ConfigHistoryQueryParams(
              kindWireNames: ['key_mapping']).toJson(),
        });
        expect(known.isError, isFalse, reason: '$known');
        await probe.close();
      });
    });

    testWidgets(
        'a refused read leaves a deny row attributed to who was refused',
        (tester) async {
      // D-05: the refusal is the only thing a refused frame leaves behind,
      // and a guard that leaves no trace is the one kind nobody can audit.
      await live(tester, () async {
        final op = await WireProbe.signedIn(bench().port,
            username: kOperator, password: kOperatorPassword);
        final refused = await op.call(AccessMethods.configHistoryChangesPage,
            {'query': const ConfigHistoryQueryParams().toJson()});
        expect(refused.errorCode, WireErrors.forbidden);
        await op.close();
        await untilTrue(() async {
          final rows = await bench().decisionRows(keyPrefix: 'changesPage');
          return rows.any((r) => !r.allowed && r.who == kOperator);
        },
            within: const Duration(seconds: 10),
            describe: 'a deny row for the operator\'s refused history read');
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
      await tester.pumpWidget(hostRoute(
          panel, _route, kConfigHistoryTitle, const AuditTrailPage(scope: AuditTrailScope.configuration)));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.byKey(kConfigHistoryListKey), findsNothing);
      expect(find.byKey(kConfigHistoryUnavailableKey), findsNothing);
      await dismount(tester);
    });
  });
}
