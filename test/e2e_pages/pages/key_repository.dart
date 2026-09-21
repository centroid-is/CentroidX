/// `/advanced/key-repository` — `configure` — over the relay.
///
/// The key repository is the plant's `key_mapping` rows. On a browser they
/// arrive through `configItems.items('key_mapping')`; on a station with a
/// device-local mirror (`kHasDeviceLocalMirror`, which is every VM build and
/// therefore this lane) the page reads `configStoreProvider` — the SQLite
/// mirror — and saves through it (`key_repository.dart:1151-1240`). In
/// gateway mode `databaseProvider` is null, so that mirror never attaches to
/// the plant's database. What the page shows and where its save goes is
/// therefore the first question this file asks, and it asks it of the real
/// thing rather than assuming either answer.
///
/// The server-side half is `configItems.*`, which §10 records as taking
/// `operate` alone — and which the peer review named as a defect, because the
/// key mappings are the plant's routing and `key_mappings` as a preference
/// takes `configure` to write and accepts `configure` to read. Both cases
/// are here: the one the wire enforces today, and the one it should.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show AccessMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/key-repository';
const String _title = 'Key Repository';

/// The key the edit adds. Spelled like the plant's, so it is a plausible row
/// and not a marker string.
const String _newKey = 'HALL1.CN02.speed_hz';

void keyRepositoryCases(BackendBench Function() bench) {
  group('the key repository', () {
    testWidgets(
        'opens for an engineer and lists the plant\'s key mappings — the '
        'rows the backend routes by', (tester) async {
      // On a station build the page reads the device-local mirror, and in
      // gateway mode nothing fills that mirror from the backend: the relayed
      // bootstrap copy of `key_mappings` lands in the local PREFERENCE cache
      // (`relayed_preferences.dart`), not in the mirror's key_mapping rows,
      // and `configStoreProvider` attaches its remote only when
      // `databaseProvider` answers a database — which in gateway mode it
      // never does. The page then renders the plant's routing as empty.
      await useDesktopSurface(tester, size: const Size(1400, 2000));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, KeyRepositoryPage()));
      await untilFound(tester, find.text('Add Key'),
          describe: 'the repository\'s toolbar');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await untilFound(tester, find.text(plantKey('CN01.speed_hz')),
          within: const Duration(seconds: 15),
          describe: 'the plant\'s "${plantKey('CN01.speed_hz')}" row, which '
              'the backend holds and routes by');
      await dismount(tester);
    });

    testWidgets(
        'a key added in the widget and saved lands in the backend\'s '
        'key_mapping rows', (tester) async {
      // The save goes to the mirror (`store.saveKeyMappings`), and the mirror
      // has no remote in gateway mode. The page reports "saved"; the plant's
      // routing is unchanged. There is no relay method a station could use
      // instead: `configItems.*` is read-only on the wire.
      await useDesktopSurface(tester, size: const Size(1400, 2000));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        final rows = await bench().keyMappingRows();
        expect(rows.map((r) => r.id), isNot(contains(_newKey)),
            reason: 'anti-vacuity: the row must not exist yet');
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, KeyRepositoryPage()));
      await untilFound(tester, find.text('Add Key'));
      await tester.tap(find.text('Add Key').first);
      await untilFound(tester, find.widgetWithText(TextField, 'Key Name'),
          describe: 'the new key\'s card, expanded at the top');
      await tester.enterText(
          find.widgetWithText(TextField, 'Key Name').first, _newKey);
      await settleFrames(tester);
      await untilFound(tester, find.text('Save Key Mappings'),
          describe: 'the save button armed by the edit');
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.tap(find.text('Save Key Mappings'));
      await settleFrames(tester, frames: 10);

      await untilTrueWhilePumping(tester, () async {
        final rows = await bench().keyMappingRows();
        return rows.any((r) => r.id == _newKey);
      },
          within: const Duration(seconds: 20),
          describe: 'the backend\'s key_mapping rows to hold "$_newKey"');
      await dismount(tester);
    });

    testWidgets(
        'the gateway serves configItems.items(key_mapping) to the engineer '
        'and refuses it to a session holding no group', (tester) async {
      final port = bench().port;
      await live(tester, () async {
        final eng = await WireProbe.signedIn(port,
            username: kEngineer, password: kEngineerPassword);
        final items = await eng.call(
            AccessMethods.configItemsItems, {'kind': 'key_mapping'});
        expect(items.isError, isFalse, reason: '$items');
        final ids = (items.result as List)
            .map((r) => (r as Map)['id'])
            .toList();
        expect(ids, contains(plantKey('CN01.speed_hz')),
            reason: 'the rows the bench seeded are what the backend serves');
        await eng.close();

        await bench().revokeAnonymous();
        try {
          final nothing = await WireProbe.anonymous(port);
          final refused = await nothing.call(
              AccessMethods.configItemsItems, {'kind': 'key_mapping'});
          expect(refused.errorCode, WireErrors.forbidden, reason: '$refused');
          await nothing.close();
        } finally {
          await bench().restoreAnonymous();
        }
      });
    });

    testWidgets(
        'configItems.items(key_mapping) is SERVED to a verified operator, and '
        'that is the design', (tester) async {
      // This was written as a KNOWN RED on a mis-briefing of mine: I passed
      // on "configItems.* takes operate alone" as a finding when the review
      // that produced it had listed the surface under SOUND. Correcting it
      // here rather than leaving a red that asserts a rule nobody made.
      //
      // Why operate is right for the READ (§10, and the review's reasoning):
      //
      //  * A panel cannot boot without it. Building the client means reading
      //    `key_mappings`, so a gateway that refused the read to anything
      //    below `configure` could not serve a walk-up station at all — the
      //    "boot ring" §10 names.
      //  * The rows carry no secrets. `state_man_config` is keychain-only and
      //    never in these rows; `server_config_envelope` is AES-GCM
      //    ciphertext; unknown kinds are refused by name rather than served.
      //  * The WRITE is graded where it belongs: `key_mappings` as a
      //    preference takes `configure` (D-03, 2026-09-07), and the page's
      //    own edit affordance is locked for an operator — which the next
      //    case asserts.
      //
      // So the grade differs by operation, not by accident, and the pair of
      // cases is what says so.
      final port = bench().port;
      await live(tester, () async {
        final op = await WireProbe.signedIn(port,
            username: kOperator, password: kOperatorPassword);
        final items = await op.call(
            AccessMethods.configItemsItems, {'kind': 'key_mapping'});
        expect(items.errorCode, isNull,
            reason: 'an operator must be able to read the plant\'s routing, '
                'or no panel can build its client; got $items');
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
          hostRoute(panel, _route, _title, KeyRepositoryPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.text('Add Key'), findsNothing);
      await dismount(tester);
    });
  });
}
