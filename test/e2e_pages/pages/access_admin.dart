/// `/advanced/access` — `users` — over the relay.
///
/// The accounts page is `app_user` and `app_role`, read and written through
/// `accessAdmin.*` (`lib/core/relayed_access_stores.dart`
/// `RelayedAccessAdminStore` → `BackendAccessAdmin` over the backend's
/// database). The round trip creates an account in the dialog and proves it
/// exists the only way an account can be proven to exist: by signing in as it,
/// on the wire, verified by the gateway.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/pages/access_users_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup, kAnonymousUsername;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show AccessMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/access';

/// The account the dialog creates. Distinct from every seeded name, so the
/// list before the edit cannot already hold it.
const String _newUser = 'shift-b';
const String _newPassword = 'shift-b-tractor-beam-9';

void accessAdminCases(BackendBench Function() bench) {
  group('the accounts page', () {
    testWidgets(
        'opens for an engineer and lists the accounts and roles that live in '
        'the backend\'s database', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 2600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(
          panel, _route, kAccessAdminTitle, const AccessAdminPage()));

      // Rows, by content: the two seeded accounts and the reserved anonymous
      // row, as `accessAdmin.listUsers` served them. The "no database" and
      // "could not be read" notes are the two holes this page can render
      // in place of data; neither may be there.
      await untilFound(tester, find.byKey(kAccessUsersSectionKey),
          describe: 'the accounts section');
      await untilFound(tester, find.text(kEngineer),
          describe: 'the engineer\'s row');
      expect(find.text(kOperator), findsOneWidget);
      expect(find.text(kAccessUserAnonymousTag), findsOneWidget,
          reason: 'the reserved anonymous account is listed as the '
              'logged-out panels\' row');
      expect(find.byKey(kAccessUsersNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessUsersUnavailableKey), findsNothing);
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      // The roles the database seeded, as `accessAdmin.roles` served them.
      expect(find.text('Engineering'), findsWidgets);
      expect(find.text('Maintenance'), findsWidgets);
      await dismount(tester);
    });

    testWidgets(
        'an account created in the dialog exists at the backend, is audited, '
        'lists on a second panel, and can sign in on the wire',
        (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 2600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        final users = await bench().accounts.listUsers();
        expect(users.map((u) => u.username), isNot(contains(_newUser)),
            reason: 'anti-vacuity: the account must not exist yet');
        return p;
      });
      await tester.pumpWidget(hostRoute(
          panel, _route, kAccessAdminTitle, const AccessAdminPage()));
      await untilFound(tester, find.text(kEngineer));
      // The dialog's role picker defaults to the first role it was handed;
      // opened before `accessAdmin.roles` has answered it has none, and the
      // confirm throws `No element` (`access_users_section.dart:2377`) —
      // measured on the first run of this lane. So: roles first.
      await untilFound(tester, find.text('Shift Leader'),
          describe: 'the roles section, so the dialog has a role to grant');

      // The dialog, the way test/pages/access_users_section_test.dart drives
      // it — against the real store this time.
      await tester.ensureVisible(find.byKey(kAccessUsersCreateKey));
      await settleFrames(tester);
      await tester.tap(find.byKey(kAccessUsersCreateKey));
      await untilFound(tester, find.byKey(kAccessUserUsernameFieldKey),
          describe: 'the create dialog');
      await tester.enterText(
          find.byKey(kAccessUserUsernameFieldKey), _newUser);
      await tester.enterText(
          find.byKey(kAccessUserPasswordFieldKey), _newPassword);
      await tester.enterText(
          find.byKey(kAccessUserConfirmFieldKey), _newPassword);
      await settleFrames(tester);
      await tester.tap(find.byKey(kAccessUserCreateConfirmKey));

      // At the backend, in `app_user`.
      await live(tester, () => untilTrue(() async {
            final users = await bench().accounts.listUsers();
            return users.any((u) => u.username == _newUser);
          }, describe: 'the new account to reach app_user'));

      // Audited against the engineer who made it, at the backend.
      await live(tester, () => untilTrue(() async {
            final rows = await bench().decisionRows();
            return rows.any((r) =>
                r.who == kEngineer &&
                r.allowed &&
                ('${r.itemKey} ${r.newValue} ${r.member}').contains(_newUser));
          },
          within: const Duration(seconds: 10),
          describe: 'an allowed audit row naming the account that was '
              'created'));

      // The page re-reads it: the dialog closes and the row appears.
      await untilFound(tester, find.text(_newUser),
          describe: 'the new account\'s row on the page that created it');

      // A second panel lists it too — the list is the backend's.
      await dismount(tester);
      final second = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(
          second, _route, kAccessAdminTitle, const AccessAdminPage()));
      await untilFound(tester, find.text(_newUser),
          describe: 'the new account on a second panel');

      // And it is an account: the gateway verifies its credential. Not
      // instantly — the verifier resolves roles against the backend's
      // account cache, which the revocation poll refreshes on its tick
      // (`backend_bench.dart`'s `_revocationPoll`, the binary's
      // `bin/main.dart:517-540`); before the tick the answer is
      // `user_source_unavailable`. The dialog's default role is the first
      // listed one; whichever that is, the session it resolves holds at
      // least `operate`.
      await live(tester, () => untilTrue(() async {
            try {
              final probe = await WireProbe.signedIn(bench().port,
                  username: _newUser, password: _newPassword);
              await probe.close();
              return true;
            } on StateError {
              return false;
            }
          },
          within: const Duration(seconds: 10),
          describe: 'the created account to sign in once the backend\'s '
              'account cache has ticked'));
      await dismount(tester);
    });

    testWidgets(
        'the gateway refuses accessAdmin.listUsers and .createUser to a '
        'verified operator and to nobody, and serves .roles to the operator '
        'because §10 says it does', (tester) async {
      final port = bench().port;
      final usersBefore =
          await live(tester, () => bench().accounts.listUsers());

      await live(tester, () async {
        final op = await WireProbe.signedIn(port,
            username: kOperator, password: kOperatorPassword);
        final list = await op.call(AccessMethods.adminListUsers, const {});
        expect(list.errorCode, WireErrors.forbidden, reason: '$list');
        expect(list.errorMessage, contains('users'));
        // Role names and their groups are not the secret; the account list
        // is. §10: "templates and accessAdmin.roles accept users" beside the
        // operate floor — so the operator reads them. Asserted so a
        // tightening here is a deliberate edit, not drift.
        final roles = await op.call(AccessMethods.adminRoles, const {});
        expect(roles.isError, isFalse, reason: '$roles');
        final create = await op.call(AccessMethods.adminCreateUser, {
          'subject': 'intruder',
          'password': 'intruder-pw',
          'grantedRole': 'Engineering',
        });
        expect(create.errorCode, WireErrors.forbidden, reason: '$create');
        await op.close();

        final nobody = await WireProbe.anonymous(port);
        final anonList =
            await nobody.call(AccessMethods.adminListUsers, const {});
        expect(anonList.errorCode, WireErrors.forbidden, reason: '$anonList');
        final anonCreate = await nobody.call(AccessMethods.adminCreateUser, {
          'subject': 'intruder',
          'password': 'intruder-pw',
          'grantedRole': 'Engineering',
        });
        expect(anonCreate.errorCode, WireErrors.forbidden,
            reason: '$anonCreate');
        await nobody.close();

        // The control.
        final eng = await WireProbe.signedIn(port,
            username: kEngineer, password: kEngineerPassword);
        final engList = await eng.call(AccessMethods.adminListUsers, const {});
        expect(engList.isError, isFalse, reason: '$engList');
        await eng.close();
      });

      final usersAfter =
          await live(tester, () => bench().accounts.listUsers());
      expect(usersAfter.length, usersBefore.length,
          reason: 'no refused createUser may have added a row');
      expect(usersAfter.map((u) => u.username), isNot(contains('intruder')));
      expect(usersAfter.map((u) => u.username), contains(kAnonymousUsername));
    });

    testWidgets('the page locks for a verified operator', (tester) async {
      await useDesktopSurface(tester, size: const Size(1400, 1400));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kOperator, kOperatorPassword),
            AccessSignInResult.ok);
        expect((await p.session()).can(AccessGroup.users), isFalse);
        return p;
      });
      await tester.pumpWidget(hostRoute(
          panel, _route, kAccessAdminTitle, const AccessAdminPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.byKey(kAccessUsersSectionKey), findsNothing);
      expect(find.text(kEngineer), findsNothing,
          reason: 'a locked page renders no account names');
      await dismount(tester);
    });
  });
}
