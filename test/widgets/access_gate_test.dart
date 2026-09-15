/// The route gate: the decision table, the locked page, and the three renders.
///
/// The decision half is a pure function, so most of this file needs no
/// `WidgetTester` at all. That is deliberate — the no-authority rule is the
/// part of this phase that took three review rounds to get right, and a truth
/// table is the only way to keep it honest as the phase grows. The gateway rows
/// are the 2026-09 addition: a panel whose repository is absent BY DESIGN and
/// whose credential is verified over the socket.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_authority.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/access_status_action.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart';

/// The five routes that stay locked when the station can authenticate nobody,
/// in group terms: page editor / alarm editor / key repository are `configure`,
/// IP settings and preferences are `administer`.
const List<AccessGroup> _lockedRouteGroups = [
  AccessGroup.configure,
  AccessGroup.administer,
];

/// Every group except `operate`, which short-circuits before any of this.
const List<AccessGroup> _raisableGroups = [
  AccessGroup.setpoints,
  AccessGroup.device,
  AccessGroup.force,
  AccessGroup.configure,
  AccessGroup.administer,
  AccessGroup.users,
];

AsyncValue<AccessAuthority> _local() =>
    const AsyncValue<AccessAuthority>.data(AccessAuthority.local);
AsyncValue<AccessAuthority> _relay() =>
    const AsyncValue<AccessAuthority>.data(AccessAuthority.relay);
AsyncValue<AccessAuthority> _none() =>
    const AsyncValue<AccessAuthority>.data(AccessAuthority.none);
AsyncValue<AccessAuthority> _authorityLoading() =>
    const AsyncValue<AccessAuthority>.loading();
AsyncValue<AccessAuthority> _authorityError() =>
    AsyncValue<AccessAuthority>.error(
      StateError('postgres will not answer'),
      StackTrace.empty,
    );

/// The two ways a station ends up able to authenticate nobody. The whole point
/// of the ruling is that these two are indistinguishable to the gate, so every
/// no-authority test runs over both.
Map<String, AsyncValue<AccessAuthority>> get _unauthenticatedStations => {
      'resolved none (never configured, or configured and unreachable)':
          _none(),
      'AsyncError (the authority could not even be determined)':
          _authorityError(),
    };

AsyncValue<AccessSession> _anonymous() =>
    AsyncValue.data(AccessSession.anonymous(const {AccessGroup.operate}));

AsyncValue<AccessSession> _elevated(Set<AccessGroup> groups) =>
    AsyncValue.data(AccessSession(
      user: const AuthenticatedUser(
        username: 'jon',
        roleName: 'Engineering',
        displayName: 'Jon B',
      ),
      groups: groups,
      expiresAt: DateTime.utc(2026, 8, 29, 12),
    ));

AsyncValue<AccessSession> _sessionLoading() =>
    const AsyncValue<AccessSession>.loading();

AsyncValue<AccessSession> _sessionError() => AsyncValue<AccessSession>.error(
      StateError('session could not be resolved'),
      StackTrace.empty,
    );

void main() {
  group('resolveAccessGate — operate', () {
    test('operate is allowed even while every provider is loading', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.operate,
          authority: _authorityLoading(),
          session: _sessionLoading(),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.allowed,
      );
    });

    test('operate is allowed with no repository and no session', () {
      for (final authority in _unauthenticatedStations.values) {
        expect(
          resolveAccessGate(
            group: AccessGroup.operate,
            authority: authority,
            session: _sessionError(),
            allowWhenNobodyCanSignIn: false,
          ),
          AccessGateState.allowed,
        );
      }
    });
  });

  group('resolveAccessGate — the authority, before the session', () {
    test('authority loading is waiting, never allowed', () {
      for (final flag in [true, false]) {
        for (final group in _raisableGroups) {
          expect(
            resolveAccessGate(
              group: group,
              authority: _authorityLoading(),
              session: _anonymous(),
              allowWhenNobodyCanSignIn: flag,
            ),
            AccessGateState.waiting,
            reason: 'a slow connection must not be read as a missing one '
                '($group, flag $flag)',
          );
        }
      }
    });

    test('authority loading is waiting even for a session holding the group',
        () {
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _authorityLoading(),
          session: _elevated(const {AccessGroup.operate, AccessGroup.configure}),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.waiting,
      );
    });

    test(
        'no authority with allowWhenNobodyCanSignIn: true is '
        'allowed, in both causes, for every group', () {
      _unauthenticatedStations.forEach((cause, authority) {
        for (final group in _raisableGroups) {
          expect(
            resolveAccessGate(
              group: group,
              authority: authority,
              session: _anonymous(),
              allowWhenNobodyCanSignIn: true,
            ),
            AccessGateState.allowed,
            reason: '$group, $cause',
          );
        }
      });
    });

    test(
        'no authority with allowWhenNobodyCanSignIn: false is '
        'denied, in both causes, for every group including administer', () {
      _unauthenticatedStations.forEach((cause, authority) {
        for (final group in _raisableGroups) {
          expect(
            resolveAccessGate(
              group: group,
              authority: authority,
              session: _anonymous(),
              allowWhenNobodyCanSignIn: false,
            ),
            AccessGateState.denied,
            reason: '$group, $cause',
          );
        }
      });
    });

    test(
        'no authority denies even a session that claims the group',
        () {
      // A stale in-memory session must not carry authority the database is no
      // longer there to back. The authority check runs first for exactly this.
      _unauthenticatedStations.forEach((cause, authority) {
        expect(
          resolveAccessGate(
            group: AccessGroup.configure,
            authority: authority,
            session:
                _elevated(const {AccessGroup.operate, AccessGroup.configure}),
            allowWhenNobodyCanSignIn: false,
          ),
          AccessGateState.denied,
          reason: cause,
        );
      });
    });

    test('AsyncError behaves exactly as a resolved none, for both flag values',
        () {
      for (final flag in [true, false]) {
        for (final group in _raisableGroups) {
          expect(
            resolveAccessGate(
              group: group,
              authority: _authorityError(),
              session: _anonymous(),
              allowWhenNobodyCanSignIn: flag,
            ),
            resolveAccessGate(
              group: group,
              authority: _none(),
              session: _anonymous(),
              allowWhenNobodyCanSignIn: flag,
            ),
            reason: 'the rule does not care why the station can authenticate '
                'nobody ($group, flag $flag)',
          );
        }
      }
    });

    test(
        'the amendment: Server Config opens in BOTH unavailable states and the '
        'other five stay locked in both', () {
      _unauthenticatedStations.forEach((cause, authority) {
        // Server Config is the one route that passes the exemption true.
        expect(
          resolveAccessGate(
            group: AccessGroup.administer,
            authority: authority,
            session: _anonymous(),
            allowWhenNobodyCanSignIn: true,
          ),
          AccessGateState.allowed,
          reason: 'server config must open — $cause',
        );

        // Page editor, alarm editor, key repository (configure) and IP
        // settings, preferences (administer) pass it false.
        for (final group in _lockedRouteGroups) {
          expect(
            resolveAccessGate(
              group: group,
              authority: authority,
              session: _anonymous(),
              allowWhenNobodyCanSignIn: false,
            ),
            AccessGateState.denied,
            reason: 'the other five must stay locked — $group, $cause',
          );
        }
      });
    });
  });

  group('resolveAccessGate — the session, once an authority exists', () {
    test('a local authority and a loading session is waiting', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _local(),
          session: _sessionLoading(),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.waiting,
      );
    });

    test('a local authority and a session in error is denied', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _local(),
          session: _sessionError(),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.denied,
      );
    });

    test('a local authority and a session holding the group is allowed', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _local(),
          session:
              _elevated(const {AccessGroup.operate, AccessGroup.configure}),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.allowed,
      );
    });

    test('a local authority and a session lacking the group is denied', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.administer,
          authority: _local(),
          session:
              _elevated(const {AccessGroup.operate, AccessGroup.configure}),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.denied,
      );
    });

    test(
        'the exemption goes inert the moment a local repository exists: '
        'allowWhenNobodyCanSignIn: true with an anonymous session is '
        'denied', () {
      for (final group in _raisableGroups) {
        expect(
          resolveAccessGate(
            group: group,
            authority: _local(),
            session: _anonymous(),
            allowWhenNobodyCanSignIn: true,
          ),
          AccessGateState.denied,
          reason: 'server config is gated like everything else once the '
              'database answers ($group)',
        );
      }
    });

    test('an elevated session lacking the group is denied like an anonymous one',
        () {
      final elevated = resolveAccessGate(
        group: AccessGroup.administer,
        authority: _local(),
        session: _elevated(const {AccessGroup.operate}),
        allowWhenNobodyCanSignIn: false,
      );
      final anonymous = resolveAccessGate(
        group: AccessGroup.administer,
        authority: _local(),
        session: _anonymous(),
        allowWhenNobodyCanSignIn: false,
      );
      expect(elevated, AccessGateState.denied);
      expect(elevated, anonymous,
          reason: 'being signed in is not the question; holding the group is');
    });
  });

  // The rows the rig failed on. A gateway panel has no repository and never
  // will: `databaseProvider` returns null the moment the transport is gateway,
  // and the credential is verified by the backend over the socket. Read as
  // "nobody can authenticate here", that denied every raised route to a signed
  // in engineer and — because the navigation menu hides what this function
  // denies — took the whole `/advanced` section off the panel.
  group('resolveAccessGate — a relay authority', () {
    test('a session holding the group opens the route', () {
      for (final group in _raisableGroups) {
        expect(
          resolveAccessGate(
            group: group,
            authority: _relay(),
            session: _elevated({AccessGroup.operate, group}),
            allowWhenNobodyCanSignIn: false,
          ),
          AccessGateState.allowed,
          reason: 'the gateway verified this session server-side ($group)',
        );
      }
    });

    test('a relay authority is not a no-authority station', () {
      // The two answers differed for exactly one reason before the fix: the
      // function could not tell a station with nothing behind it from one whose
      // authority is at the other end of a socket.
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _relay(),
          session: _elevated(const {AccessGroup.operate, AccessGroup.configure}),
          allowWhenNobodyCanSignIn: false,
        ),
        isNot(resolveAccessGate(
          group: AccessGroup.configure,
          authority: _none(),
          session: _elevated(const {AccessGroup.operate, AccessGroup.configure}),
          allowWhenNobodyCanSignIn: false,
        )),
      );
    });

    test('an anonymous session is denied, exactly as with a local repository',
        () {
      for (final group in _raisableGroups) {
        expect(
          resolveAccessGate(
            group: group,
            authority: _relay(),
            session: _anonymous(),
            allowWhenNobodyCanSignIn: false,
          ),
          AccessGateState.denied,
          reason: 'signing in is what opens these, on any transport ($group)',
        );
      }
    });

    test('a session lacking the group is denied', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.administer,
          authority: _relay(),
          session: _elevated(const {AccessGroup.operate, AccessGroup.configure}),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.denied,
      );
    });

    test('a loading session is waiting, and an errored one is denied', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _relay(),
          session: _sessionLoading(),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.waiting,
      );
      expect(
        resolveAccessGate(
          group: AccessGroup.configure,
          authority: _relay(),
          session: _sessionError(),
          allowWhenNobodyCanSignIn: false,
        ),
        AccessGateState.denied,
      );
    });

    test(
        'Server Config is GATED on a reachable gateway panel — the exemption '
        'is for a station nobody can sign in at, and this is not one', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.administer,
          authority: _relay(),
          session: _anonymous(),
          allowWhenNobodyCanSignIn: true,
          relayCanAuthenticate: true,
        ),
        AccessGateState.denied,
        reason: 'a gateway panel has no repository by design and permanently, '
            'so an exemption keyed on that was an open Server Config on every '
            'gateway panel, for its whole life',
      );
    });

    test(
        'Server Config opens on a reachable gateway panel for a session that '
        'actually holds administer', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.administer,
          authority: _relay(),
          session: _elevated(
            const {AccessGroup.operate, AccessGroup.administer},
          ),
          allowWhenNobodyCanSignIn: true,
          relayCanAuthenticate: true,
        ),
        AccessGateState.allowed,
        reason: 'the exemption is inert; the relayed session decides, exactly '
            'as it does for every other raised route',
      );
    });

    test(
        'Server Config stays open when the gateway link cannot carry a '
        'sign-in — the mistyped-URL recovery, on the honest condition', () {
      for (final session in [
        _anonymous(),
        _elevated(const {AccessGroup.operate, AccessGroup.configure}),
        _sessionLoading(),
        _sessionError(),
      ]) {
        expect(
          resolveAccessGate(
            group: AccessGroup.administer,
            authority: _relay(),
            session: session,
            allowWhenNobodyCanSignIn: true,
            relayCanAuthenticate: false,
          ),
          AccessGateState.allowed,
          reason: 'nobody can sign in over a link that will not come up, so '
              'the page that fixes the URL must stay reachable',
        );
      }
    });

    test(
        'an unreachable gateway link opens Server Config and nothing else — '
        'the recovery does not widen into the other raised routes', () {
      for (final group in [
        AccessGroup.configure,
        AccessGroup.administer,
        AccessGroup.users,
      ]) {
        expect(
          resolveAccessGate(
            group: group,
            authority: _relay(),
            session: _anonymous(),
            allowWhenNobodyCanSignIn: false,
            relayCanAuthenticate: false,
          ),
          AccessGateState.denied,
        );
      }
    });

    test('relayCanAuthenticate defaults to true, the closed answer', () {
      expect(
        resolveAccessGate(
          group: AccessGroup.administer,
          authority: _relay(),
          session: _anonymous(),
          allowWhenNobodyCanSignIn: true,
        ),
        AccessGateState.denied,
        reason: 'a call site that forgets the parameter must gate, not open',
      );
    });
  });

  group('resolveAccessGate — relayCanAuthenticate touches only relay', () {
    test('no authority is exempt whatever the link says', () {
      for (final linkUsable in [true, false]) {
        expect(
          resolveAccessGate(
            group: AccessGroup.administer,
            authority: _none(),
            session: _anonymous(),
            allowWhenNobodyCanSignIn: true,
            relayCanAuthenticate: linkUsable,
          ),
          AccessGateState.allowed,
          reason: 'a direct station with no reachable Postgres has no link to '
              'ask about; the outage exemption this was always for still fires',
        );
      }
    });

    test('a local authority is gated whatever the link says — direct mode is '
        'untouched by this change', () {
      for (final linkUsable in [true, false]) {
        expect(
          resolveAccessGate(
            group: AccessGroup.administer,
            authority: _local(),
            session: _anonymous(),
            allowWhenNobodyCanSignIn: true,
            relayCanAuthenticate: linkUsable,
          ),
          AccessGateState.denied,
        );
        expect(
          resolveAccessGate(
            group: AccessGroup.administer,
            authority: _local(),
            session: _elevated(
              const {AccessGroup.operate, AccessGroup.administer},
            ),
            allowWhenNobodyCanSignIn: true,
            relayCanAuthenticate: linkUsable,
          ),
          AccessGateState.allowed,
        );
      }
    });
  });

  group('AccessLockedBody', () {
    testWidgets('names the missing group by its AccessGroup name',
        (tester) async {
      await tester.pumpWidget(_lockedBodyHost(group: AccessGroup.administer));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessLockedBodyKey), findsOneWidget);
      expect(find.text(kAccessLockedGroupNote(AccessGroup.administer)),
          findsOneWidget);
      expect(kAccessLockedGroupNote(AccessGroup.administer),
          contains(AccessGroup.administer.name));
    });

    testWidgets('anonymous: says a sign-in is needed and offers one',
        (tester) async {
      await tester.pumpWidget(_lockedBodyHost(group: AccessGroup.configure));
      await tester.pumpAndSettle();

      expect(find.text(kAccessLockedHeadline), findsOneWidget);
      expect(find.byKey(kAccessLockedSignInKey), findsOneWidget);
      // Nobody is signed in, so there is no role to talk about.
      expect(find.textContaining('You are signed in as'), findsNothing);
    });

    testWidgets(
        'elevated but insufficient: names who and their role, and still '
        'offers a sign-in', (tester) async {
      await tester.pumpWidget(_lockedBodyHost(
        group: AccessGroup.administer,
        session: _elevatedSession(const {AccessGroup.operate}),
      ));
      await tester.pumpAndSettle();

      final note = kAccessLockedRoleNote(
          'Jon B', 'Engineering', AccessGroup.administer);
      expect(find.text(note), findsOneWidget);
      expect(note, contains('Jon B'));
      expect(note, contains('Engineering'));
      expect(note, contains(AccessGroup.administer.name));

      // Signing in as somebody else is still on offer.
      expect(find.byKey(kAccessLockedSignInKey), findsOneWidget);
    });

    testWidgets('an unavailable repository adds the no-database line, in both '
        'causes', (tester) async {
      for (final authority in [_noAuthority, _throwingAuthority]) {
        await tester.pumpWidget(_lockedBodyHost(
          group: AccessGroup.configure,
          authority: authority,
        ));
        await tester.pumpAndSettle();

        expect(find.byKey(kAccessLockedNoDatabaseKey), findsOneWidget);
        expect(find.text(kAccessLockedNoDatabaseNote), findsOneWidget);
      }
    });

    testWidgets('the no-database line is absent when a repository is present',
        (tester) async {
      await tester.pumpWidget(_lockedBodyHost(group: AccessGroup.configure));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessLockedNoDatabaseKey), findsNothing);
      expect(find.text(kAccessLockedNoDatabaseNote), findsNothing);
    });

    testWidgets('a gateway panel is never told to go and fix its database',
        (tester) async {
      // It has none and wants none. The sentence would send the operator to
      // Server Config's Postgres fields over a sign-in that works.
      await tester.pumpWidget(_lockedBodyHost(
        group: AccessGroup.configure,
        authority: _relayAuthority,
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessLockedNoDatabaseKey), findsNothing);
      expect(find.byKey(kAccessLockedSignInKey), findsOneWidget);
    });

    testWidgets('the no-database line wraps rather than ellipsising',
        (tester) async {
      await tester.pumpWidget(_lockedBodyHost(
        group: AccessGroup.configure,
        authority: _noAuthority,
      ));
      await tester.pumpAndSettle();

      _expectWrapsLegibly(tester, kAccessLockedNoDatabaseKey,
          kAccessLockedNoDatabaseNote);
    });

    test('the no-database line states the consequence and the next step, '
        'never a cause', () {
      // Never configured and configured-but-down lead to the same next step
      // now that Server Config opens in both, and a line that guessed wrong
      // would send a commissioner and an operator hunting different wrong
      // problems — the mistake `lib/pages/first_user.dart:55-64` documents.
      expect(kAccessLockedNoDatabaseNote, isNot(contains('configured')));
      expect(kAccessLockedNoDatabaseNote, isNot(contains('unreachable')));
      expect(kAccessLockedNoDatabaseNote, contains('Server Config'));
    });

    testWidgets('carries the honesty line verbatim, wrapping rather than '
        'ellipsising', (tester) async {
      await tester.pumpWidget(_lockedBodyHost(group: AccessGroup.configure));
      await tester.pumpAndSettle();

      expect(find.text(kAccessSignInHonestyNote), findsOneWidget);
      _expectWrapsLegibly(
          tester, kAccessLockedHonestyKey, kAccessSignInHonestyNote);
    });

    testWidgets('the Sign in action calls the injected opener once per tap',
        (tester) async {
      final opener = _CountingOpener();
      await tester.pumpWidget(_lockedBodyHost(
        group: AccessGroup.configure,
        openSignIn: opener.call,
      ));
      await tester.pumpAndSettle();

      expect(opener.calls, 0, reason: 'a render must not open the dialog');
      await tester.tap(find.byKey(kAccessLockedSignInKey));
      await tester.pumpAndSettle();
      expect(opener.calls, 1);
      await tester.tap(find.byKey(kAccessLockedSignInKey));
      await tester.pumpAndSettle();
      expect(opener.calls, 2);
    });

    testWidgets('renders no error styling, in either repository state',
        (tester) async {
      for (final authority in [_localAuthority, _noAuthority]) {
        await tester.pumpWidget(_lockedBodyHost(
          group: AccessGroup.configure,
          authority: authority,
        ));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.error), findsNothing);
        expect(find.byIcon(Icons.error_outline), findsNothing);
        expect(find.byIcon(Icons.warning), findsNothing);
        expect(find.byIcon(Icons.warning_amber), findsNothing);
        expect(find.textContaining('Exception'), findsNothing);
        expect(find.textContaining('Error'), findsNothing);

        final scheme = Theme.of(
          tester.element(find.byKey(kAccessLockedBodyKey)),
        ).colorScheme;
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          expect(text.style?.color, isNot(scheme.error),
              reason: 'a lock is not a fault: "${text.data}"');
        }
        for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
          expect(icon.color, isNot(scheme.error));
        }
      }
    });

    testWidgets('offers no go-back, retry or request-access affordance',
        (tester) async {
      await tester.pumpWidget(_lockedBodyHost(
        group: AccessGroup.configure,
        authority: _noAuthority,
      ));
      await tester.pumpAndSettle();

      // Leaving is the app bar's and the navigation bar's job, and there is
      // nobody in this build to request access from.
      expect(find.textContaining('Back'), findsNothing);
      expect(find.textContaining('Retry'), findsNothing);
      expect(find.textContaining('Try again'), findsNothing);
      expect(find.textContaining('Request'), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('nothing it renders is disabled, including with no repository',
        (tester) async {
      for (final authority in [
        _localAuthority,
        _noAuthority,
        _throwingAuthority,
      ]) {
        await tester.pumpWidget(_lockedBodyHost(
          group: AccessGroup.configure,
          authority: authority,
        ));
        await tester.pumpAndSettle();

        final buttons = tester.widgetList<ButtonStyleButton>(
          find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(buttons, isNotEmpty);
        for (final button in buttons) {
          expect(button.onPressed, isNotNull,
              reason: 'a greyed control is the one thing the UI rules forbid');
        }
        for (final button in tester.widgetList<IconButton>(
          find.byType(IconButton),
        )) {
          expect(button.onPressed, isNotNull);
        }
      }
    });
  });

  group('AccessGate', () {
    setUp(() {
      _childInits = 0;
      _registerAppMenu();
    });
    tearDown(() => RouteRegistry().menuItems.clear());

    test('allowWhenNobodyCanSignIn defaults to false', () {
      // A caller that forgets the flag gets the strict behaviour. The
      // permissive direction has to be asked for, at the one route that needs
      // it.
      const gate = AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        child: SizedBox.shrink(),
      );
      expect(gate.allowWhenNobodyCanSignIn, isFalse);
    });

    test('group is required and has no default', () {
      // Enforced by the compiler — `AccessGate(title: ..., child: ...)` does
      // not analyse — because a gate that could be built without a group would
      // fail open by omission. What a runtime test can add is that nothing
      // substitutes a default behind the caller's back.
      const gate = AccessGate(
        group: AccessGroup.administer,
        title: 'Server Config',
        child: SizedBox.shrink(),
      );
      expect(gate.group, AccessGroup.administer);
    });

    testWidgets('allowed renders the child, and no scaffold of its own',
        (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            _elevatedSession(const {AccessGroup.operate, AccessGroup.configure})),
        authority: _localAuthority,
      ));
      await tester.pumpAndSettle();

      expect(find.text(_kGatedChildText), findsOneWidget);
      expect(find.byType(AccessLockedBody), findsNothing);
      expect(find.byKey(kAccessGateWaitingKey), findsNothing);
      // Exactly one — the page's own. The gate adds no chrome and no frame.
      expect(find.byType(BaseScaffold), findsOneWidget);
      expect(find.text('Page Editor'), findsNothing);
    });

    testWidgets(
        'denied renders the locked body in a scaffold, so the operator can '
        'leave', (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _localAuthority,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessLockedBody), findsOneWidget);
      expect(find.text(_kGatedChildText), findsNothing);
      // The way out: the app bar with its own sign-in affordance, and the
      // navigation bar.
      expect(find.byType(BaseScaffold), findsOneWidget);
      expect(find.byType(AccessStatusAction), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('waiting renders a progress indicator, not the child and not '
        'the lock', (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _hangingAuthority,
      ));
      await tester.pump();

      expect(find.byKey(kAccessGateWaitingKey), findsOneWidget);
      expect(find.text(_kGatedChildText), findsNothing);
      expect(find.byType(AccessLockedBody), findsNothing);
      expect(find.byType(BaseScaffold), findsOneWidget);
    });

    testWidgets('the gate never opens the sign-in dialog by itself',
        (tester) async {
      final opener = _CountingOpener();
      final router = buildAccessGateRouter(AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        openSignIn: opener.call,
        child: const _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _localAuthority,
      ));
      await tester.pumpAndSettle();

      // A rebuild must not ambush the operator with a modal.
      expect(find.byType(AccessLockedBody), findsOneWidget);
      expect(opener.calls, 0);
    });

    testWidgets('the child is not built while denied', (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _localAuthority,
      ));
      await tester.pumpAndSettle();

      // A page that ran its initState, its queries and its subscriptions
      // behind a lock would leak exactly what the lock is for.
      expect(_childInits, 0);
    });

    testWidgets('gaining the group reveals the child, with no navigation',
        (tester) async {
      final session = _MutableSession(
          AccessSession.anonymous(const {AccessGroup.operate}));
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.configure,
        title: 'Page Editor',
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: session,
        authority: _localAuthority,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessLockedBody), findsOneWidget);
      final before = _currentPath(router);

      session.become(
          _elevatedSession(const {AccessGroup.operate, AccessGroup.configure}));
      await tester.pumpAndSettle();

      expect(find.text(_kGatedChildText), findsOneWidget);
      expect(find.byType(AccessLockedBody), findsNothing);
      expect(_childInits, 1, reason: 'the page runs once, on reveal');
      // No beam, no push, no pop: the gate re-ran `build` and the child
      // appeared where the operator already was.
      expect(_currentPath(router), before);
      expect(_currentPath(router), '/gated');
    });

    testWidgets('a gate on operate renders the child immediately, with no '
        'waiting frame', (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.operate,
        title: 'Home',
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _HangingSession(),
        authority: _hangingAuthority,
      ));
      await tester.pump();

      // Neither provider has resolved and neither ever will in this test: an
      // unraised route must not cost a frame.
      expect(find.text(_kGatedChildText), findsOneWidget);
      expect(find.byKey(kAccessGateWaitingKey), findsNothing);
      expect(find.byType(AccessLockedBody), findsNothing);
    });

    testWidgets(
        'allowWhenNobodyCanSignIn: true renders the child with no '
        'repository', (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.administer,
        title: 'Server Config',
        allowWhenNobodyCanSignIn: true,
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _noAuthority,
      ));
      await tester.pumpAndSettle();

      expect(find.text(_kGatedChildText), findsOneWidget);
      expect(find.byType(AccessLockedBody), findsNothing);
    });

    testWidgets(
        'allowWhenNobodyCanSignIn: true renders the lock once a '
        'repository exists', (tester) async {
      // The exemption is inert the moment a repository answers — a second
      // `pumpWidget` in the test above would tear the Beamer delegate down
      // mid-flight, so this is its own case.
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.administer,
        title: 'Server Config',
        allowWhenNobodyCanSignIn: true,
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _localAuthority,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessLockedBody), findsOneWidget);
      expect(find.text(_kGatedChildText), findsNothing);
      expect(_childInits, 0);
    });

    testWidgets(
        'the gate reads relayCanAuthenticateProvider: a healthy gateway panel '
        'locks Server Config with nobody signed in', (tester) async {
      // The wiring, not the rule. `resolveAccessGate` can be exactly right and
      // the page still open if the widget never asks the provider — which is
      // how the original defect reached a rig.
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.administer,
        title: 'Server Config',
        allowWhenNobodyCanSignIn: true,
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _relayAuthority,
        relayCanAuthenticate: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessLockedBody), findsOneWidget);
      expect(find.text(_kGatedChildText), findsNothing);
      expect(_childInits, 0);
    });

    testWidgets(
        'a gateway panel whose link cannot carry a sign-in still opens Server '
        'Config — the mistyped-URL recovery, end to end', (tester) async {
      final router = buildAccessGateRouter(const AccessGate(
        group: AccessGroup.administer,
        title: 'Server Config',
        allowWhenNobodyCanSignIn: true,
        child: _GatedPage(),
      ));
      await tester.pumpWidget(buildAccessGateShell(
        router: router,
        session: _FixedSession(
            AccessSession.anonymous(const {AccessGroup.operate})),
        authority: _relayAuthority,
        relayCanAuthenticate: false,
      ));
      await tester.pumpAndSettle();

      expect(find.text(_kGatedChildText), findsOneWidget);
      expect(find.byType(AccessLockedBody), findsNothing);
    });
  });
}

/// A session that resolves immediately to whatever the test needs.
///
/// Overriding [build] is what keeps the frame chosen rather than raced: none of
/// the real leaf providers — database, preferences, audit sink, inactivity
/// monitor — is ever constructed, so there is no I/O to settle against and no
/// timer to leak. Copied from `test/widgets/access_golden_test.dart`.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// The authority states a widget test can be in. The gate's own decision is
/// tested against `AsyncValue`s directly; these are for the widgets, which read
/// the provider themselves.
Future<AccessAuthority> _localAuthority() async => AccessAuthority.local;
Future<AccessAuthority> _relayAuthority() async => AccessAuthority.relay;
Future<AccessAuthority> _noAuthority() async => AccessAuthority.none;
Future<AccessAuthority> _throwingAuthority() async =>
    throw StateError('postgres will not answer');

AccessSession _elevatedSession(Set<AccessGroup> groups) => AccessSession(
      user: const AuthenticatedUser(
        username: 'jon',
        roleName: 'Engineering',
        displayName: 'Jon B',
      ),
      groups: groups,
      expiresAt: DateTime.utc(2026, 8, 29, 12),
    );

/// Counts the taps without standing up a dialog route.
class _CountingOpener {
  int calls = 0;

  Future<void> call(BuildContext context, WidgetRef ref) async {
    calls++;
  }
}

/// [AccessLockedBody] under a bare `MaterialApp` — no Beamer, no router.
///
/// Both access providers are overridden, always: an unoverridden
/// `accessAuthorityProvider` reaches `databaseProvider` and the keychain, and
/// the test becomes a race.
Widget _lockedBodyHost({
  required AccessGroup group,
  AccessSession? session,
  Future<AccessAuthority> Function() authority = _localAuthority,
  AccessSignInOpener? openSignIn,
}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => _FixedSession(
          session ?? AccessSession.anonymous(const {AccessGroup.operate}))),
      accessAuthorityProvider.overrideWith((ref) => authority()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: AccessLockedBody(
          group: group,
          openSignIn: openSignIn ?? _CountingOpener().call,
        ),
      ),
    ),
  );
}

/// A session that never resolves, for the frames the gate must not wait on.
class _HangingSession extends AccessSessionController {
  @override
  Future<AccessSession> build() => Completer<AccessSession>().future;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// A session a test can move from lacking the group to holding it, without
/// re-pumping the tree — which is the whole point of the no-replay rule.
class _MutableSession extends AccessSessionController {
  _MutableSession(this._initial);

  final AccessSession _initial;

  @override
  Future<AccessSession> build() async => _initial;

  void become(AccessSession next) => state = AsyncData(next);

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// An authority that never resolves — the "still connecting" station.
Future<AccessAuthority> _hangingAuthority() =>
    Completer<AccessAuthority>().future;

/// How many times the gated page's body has run `initState`. Reset per test;
/// the point of the counter is that a denied gate leaves it at zero.
int _childInits = 0;

const String _kGatedChildText = 'gated-child';

/// The page behind the gate. Brings its own [BaseScaffold], the way every real
/// page does, so a test can tell whether the gate added one of its own.
class _GatedPage extends StatelessWidget {
  const _GatedPage();

  @override
  Widget build(BuildContext context) => const BaseScaffold(
        title: 'Gated page',
        body: _CountingChild(),
      );
}

class _CountingChild extends StatefulWidget {
  const _CountingChild();

  @override
  State<_CountingChild> createState() => _CountingChildState();
}

class _CountingChildState extends State<_CountingChild> {
  @override
  void initState() {
    super.initState();
    _childInits++;
  }

  @override
  Widget build(BuildContext context) => const Text(_kGatedChildText);
}

/// The top-level menu [BaseScaffold] renders its navigation bar from. Gated
/// routes live under Advanced, the way the seven real ones do.
void _registerAppMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(const MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(label: 'Gated', path: '/gated', icon: Icons.dns),
    ],
  ));
}

/// The router the gate shell needs: the gated route, plus a `/` to beam to, so
/// a test can tell a rebuild apart from a navigation.
BeamerDelegate buildAccessGateRouter(Widget gate) => BeamerDelegate(
      initialPath: '/gated',
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              title: 'Home',
              child: BaseScaffold(title: 'Home', body: Text('home-body')),
            ),
        '/gated': (context, state, data) => BeamPage(
              key: const ValueKey('/gated'),
              title: 'Gated',
              child: gate,
            ),
      }).call,
    );

/// The one-route Beamer shell every [AccessGate] widget test pumps.
///
/// A named top-level function rather than an inline closure because plan 02-05
/// builds its own copy for the shell golden — golden files in this repo own
/// their hosts — and this comment is what stops the copy drifting.
///
/// **Both access providers must be overridden, always:**
///
/// * `accessSessionProvider` — an unoverridden session runs the real controller
///   chain, and a frame captured before it settles is `AsyncLoading`, in which
///   `AccessStatusAction` renders `SizedBox.shrink()` and the app bar looks
///   empty. That trap cost Phase 1 a re-render of eighteen baselines
///   (01-08 summary, "The timing dependency").
/// * `accessAuthorityProvider` — an unoverridden authority reaches
///   `gatewayConfigProvider` and `databaseProvider`, which read the
///   device-local store, `DatabaseConfig.fromPrefs()` and the station keychain.
///   The test becomes a race against real I/O.
///
/// The Beamer wrapper is not optional either: [BaseScaffold] calls
/// `context.currentBeamLocation` (`base_scaffold.dart:40` and `:382`), so it
/// cannot be pumped without a router above it.
Widget buildAccessGateShell({
  required BeamerDelegate router,
  required AccessSessionController session,
  required Future<AccessAuthority> Function() authority,
  bool? relayCanAuthenticate,
}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => session),
      accessAuthorityProvider.overrideWith((ref) => authority()),
      // Left alone unless a test says otherwise: unoverridden it resolves to
      // true, the closed answer, which is what every direct-mode case here
      // wants and what a gateway panel with a healthy link reports.
      if (relayCanAuthenticate != null)
        relayCanAuthenticateProvider
            .overrideWith((ref) => relayCanAuthenticate),
    ],
    child: BeamerProvider(
      routerDelegate: router,
      child: MaterialApp.router(
        routerDelegate: router,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// The path Beamer is currently showing, so a test can assert that revealing
/// the child navigated nowhere.
String? _currentPath(BeamerDelegate router) {
  final state = router.currentBeamLocation.state;
  return state is BeamState ? state.uri.path : null;
}

/// The Phase 1 lesson, copied deliberately: `find.text` passes on a string the
/// painter has clipped to "…not a security bo…", which is how an ellipsised
/// honesty line shipped past a green assertion. Pin the properties that decide
/// legibility, then check the paragraph really is taller than one line at the
/// width the page renders it at.
void _expectWrapsLegibly(WidgetTester tester, Key key, String expected) {
  final text = tester.widget<Text>(find.byKey(key));
  expect(text.data, expected);
  expect(text.maxLines, isNull);
  expect(text.overflow, isNot(TextOverflow.ellipsis));

  final rendered = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.byKey(key), matching: find.byType(RichText)),
  );
  expect(rendered.size.height, greaterThan(rendered.preferredLineHeight));
}
