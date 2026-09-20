/// `/advanced/config-history` — `configure` — over the relay.
///
/// The history IS `config_change`, read by `configChangeStoreProvider`
/// straight from `databaseProvider` (`config_history.dart:20-23`), which a
/// gateway panel answers null. There is no `configHistory.*` on the wire.
/// So over the relay this page has nothing to show and — the good half —
/// says so with the sentence written for the case, rather than an empty list.
/// The RED half is that the backend's rows exist (the seed wrote them) and no
/// relayed panel can see them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/config_history.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/config-history';

void configHistoryCases(BackendBench Function() bench) {
  group('the configuration history', () {
    testWidgets(
        'opens for an engineer and tells the truth: the history is not '
        'reachable over the relay, not "no changes"', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(
          panel, _route, kConfigHistoryTitle, const ConfigHistoryPage()));
      await untilFound(tester, find.byKey(kConfigHistoryUnavailableKey),
          describe: 'the unavailable note');
      expect(find.text(kConfigHistoryUnavailable), findsOneWidget);
      expect(find.byKey(kConfigHistoryEmptyKey), findsNothing,
          reason: '"no changes match" would be a lie about a table that '
              'was never read');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED (found here): the backend\'s configuration changes are '
        'listed on a relayed panel', (tester) async {
      // The seed wrote key mappings and a page through a station-shaped
      // store, so `config_change` holds rows. No wire carries them.
      await useDesktopSurface(tester, size: const Size(1400, 1600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(
          panel, _route, kConfigHistoryTitle, const ConfigHistoryPage()));
      await untilFound(tester, find.byKey(kConfigHistoryListKey),
          within: const Duration(seconds: 10),
          describe: 'the history list, with the seed\'s changes');
      await dismount(tester);
    });

    testWidgets('there is no configuration-history method on the wire for '
        'anybody — the gateway answers method-not-found, not data',
        (tester) async {
      await live(tester, () async {
        final eng = await WireProbe.signedIn(bench().port,
            username: kEngineer, password: kEngineerPassword);
        final answer = await eng.call('configHistory.actions', const {});
        expect(answer.isError, isTrue, reason: '$answer');
        expect(answer.errorCode, -32601,
            reason: 'JSON-RPC method not found; a data answer here would be '
                'a route this file does not know about');
        await eng.close();
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
          panel, _route, kConfigHistoryTitle, const ConfigHistoryPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.byKey(kConfigHistoryUnavailableKey), findsNothing);
      await dismount(tester);
    });
  });
}
