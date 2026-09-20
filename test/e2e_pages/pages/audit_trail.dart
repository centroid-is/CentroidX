/// `/advanced/audit-trail` — `users` — over the relay.
///
/// The trail is `audit_entry`, served through `audit.entries`
/// (`RelayedAuditTrailStore` → `BackendAudit`). The page has no write of its
/// own; what it must prove is that the rows the OTHER pages' writes leave —
/// and the rows the plant's own writes are supposed to leave — reach a screen
/// held by somebody with `users`, and nobody else.
///
/// Two of the known defects live here, because this page is where they would
/// be seen: a tag write and an alarm acknowledge leave no row (the access
/// spec's §2 requires every hand-made write recorded), and the `station`
/// column is whatever the client typed into `session.login`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/audit_trail_row.dart' show AuditActionTile;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show AccessMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/audit-trail';

/// The recording node: the plant counts writes to it, which is the
/// anti-vacuity instrument for the tag-write case.
const String _setpointNode = 'CN01.setpoint_kg';

void auditTrailCases(BackendBench Function() bench) {
  group('the audit trail page', () {
    testWidgets(
        'opens for an engineer and renders rows from the backend\'s '
        'audit_entry — including one made a moment ago', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 2600));
      // A row of known content, made on the wire by the engineer: the home
      // page of the operator's account. Audited by `BackendAccessAdmin`.
      const marker = '/e2e/audit-marker';
      await live(tester, () async {
        final eng = await WireProbe.signedIn(bench().port,
            username: kEngineer, password: kEngineerPassword);
        final set = await eng.call(AccessMethods.adminSetUserHomePage,
            {'subject': kOperator, 'path': marker});
        expect(set.isError, isFalse, reason: '$set');
        await eng.close();
        await untilTrue(() async {
          final rows = await bench().decisionRows();
          return rows.any((r) => r.newValue == marker);
        }, describe: 'the home-page row to reach audit_entry');
      });

      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, kAuditTrailTitle, const AuditTrailPage()));

      await untilFound(tester, find.byKey(kAuditTrailListKey),
          describe: 'the trail\'s list');
      await untilFound(tester, find.byType(AuditActionTile),
          describe: 'at least one audit row rendered');
      expect(find.byKey(kAuditTrailUnavailableKey), findsNothing,
          reason: '"the database is not reachable" is the hole this page '
              'renders in place of data');
      expect(find.byKey(kAuditTrailEmptyKey), findsNothing);
      // By content: the engineer's name on a row, and the item key the row
      // above carries (`AuditRecord.userHomePage` files it under
      // `user.home_page`; the tile renders `itemKey`, not the value).
      await untilFound(tester, find.textContaining('$kEngineer ('),
          describe: 'a row attributed to "$kEngineer (Engineering)"');
      await untilFound(tester, find.textContaining('user.home_page'),
          within: const Duration(seconds: 10),
          describe: 'the row written seconds ago over the same wire');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets(
        'the gateway refuses audit.entries and audit.distinctWho to a '
        'verified operator and to nobody', (tester) async {
      final port = bench().port;
      await live(tester, () async {
        final op = await WireProbe.signedIn(port,
            username: kOperator, password: kOperatorPassword);
        final entries = await op.call(AccessMethods.auditEntries,
            {'query': const <String, Object?>{}});
        expect(entries.errorCode, WireErrors.forbidden, reason: '$entries');
        expect(entries.errorMessage, contains('users'));
        final who = await op.call(AccessMethods.auditDistinctWho, const {});
        expect(who.errorCode, WireErrors.forbidden, reason: '$who');
        await op.close();

        final nobody = await WireProbe.anonymous(port);
        final anon = await nobody.call(AccessMethods.auditEntries,
            {'query': const <String, Object?>{}});
        expect(anon.errorCode, WireErrors.forbidden, reason: '$anon');
        await nobody.close();

        final eng = await WireProbe.signedIn(port,
            username: kEngineer, password: kEngineerPassword);
        final ok = await eng.call(AccessMethods.auditEntries,
            {'query': const <String, Object?>{}});
        expect(ok.isError, isFalse, reason: '$ok');
        expect(ok.result, isA<List>());
        expect((ok.result as List), isNotEmpty,
            reason: 'the control: eng reads real rows');
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
      await tester.pumpWidget(
          hostRoute(panel, _route, kAuditTrailTitle, const AuditTrailPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.byKey(kAuditTrailListKey), findsNothing);
      expect(find.byType(AuditActionTile), findsNothing);
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED: a tag write made from the panel leaves an audit row the '
        'trail can show', (tester) async {
      // The access spec's §2: every hand-made write recorded. The relay's
      // `write` handler grades the write through `PolicyStateMan` and never
      // records it, allowed or refused — so the trail, which is the only
      // record, cannot show that anybody moved a setpoint over the wire.
      // The write below is real: the plant counts it at the node.
      await useDesktopSurface(tester, size: const Size(1400, 2600));
      final key = plantKey(_setpointNode);
      final before = bench().actuations(_setpointNode);
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        final stateMan = await p.container.read(stateManProvider.future);
        await stateMan.write(key, DynamicValue(value: 13.5));
        await untilTrue(() => bench().actuations(_setpointNode) > before,
            describe: 'the plant to count the actuation — without this the '
                'audit claim below would be about a write that never '
                'happened');
        return p;
      });

      final rows =
          await live(tester, () => bench().decisionRows(keyPrefix: key));
      expect(rows.where((r) => r.who == kEngineer), isNotEmpty,
          reason: 'a write the plant executed must be in the trail, '
              'attributed to the account that made it');

      await tester.pumpWidget(
          hostRoute(panel, _route, kAuditTrailTitle, const AuditTrailPage()));
      await untilFound(tester, find.byKey(kAuditTrailListKey));
      await untilFound(tester, find.textContaining(key),
          within: const Duration(seconds: 10),
          describe: 'the setpoint write on the trail page');
      await dismount(tester);
    });

    knownRed(
        'KNOWN RED: an alarm acknowledge — refused, here — leaves an audit '
        'row', (tester) async {
      // A refused acknowledge is still a decision about a change, and D-05
      // says a refusal leaves a deny row. `ackAlarm` records neither outcome.
      // Decision rows only: the sign-in below adds an auth row by itself,
      // and counting that would make this case pass for the wrong reason.
      final before = await live(tester, () => bench().decisionRows());
      await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        final remote = await p.remote();
        try {
          await remote.ackAlarm('no-such-alarm', 0);
        } catch (_) {
          // Refused or not found; either way it was a hand-made attempt to
          // change the plant's alarm state.
        }
      });
      final after = await live(tester, () => bench().decisionRows());
      expect(after.length, greaterThan(before.length),
          reason: 'an acknowledge attempt must leave a row');
    });

    knownRed(
        'KNOWN RED: the station column is the gateway\'s knowledge of the '
        'socket, not a label the client typed into session.login',
        (tester) async {
      // `relay_session.dart`'s `_stationLabelOf` copies `SessionLoginParams.
      // station` into every audit row the session leaves. A laptop on the
      // plant LAN can therefore sign in claiming to be a panel and have its
      // writes attributed to that panel's station. The probe below is that
      // laptop.
      const claimed = 'ST101-PANEL-07';
      const marker = '/e2e/station-marker';
      await live(tester, () async {
        final laptop = await WireProbe.signedIn(bench().port,
            username: kEngineer,
            password: kEngineerPassword,
            station: claimed,
            client: 'laptop');
        final set = await laptop.call(AccessMethods.adminSetUserHomePage,
            {'subject': kOperator, 'path': marker});
        expect(set.isError, isFalse, reason: '$set');
        await laptop.close();
      });
      final rows = await live(tester, () => bench().decisionRows());
      final row = rows.firstWhere((r) => r.newValue == marker);
      expect(row.station, isNot(claimed),
          reason: 'the station a row is attributed to must not be the '
              'client\'s own claim');
    });
  });
}
