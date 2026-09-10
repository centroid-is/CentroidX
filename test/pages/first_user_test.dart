import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/first_user.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart' show AccessSignInOpener;
import 'package:tfc_dart/core/access/access_repository.dart';

import '../helpers/test_helpers.dart';

/// An [AccessRepository] that never touches a database.
///
/// The page calls exactly one method on it, so `implements` plus a throwing
/// [noSuchMethod] is both the smallest fake that works and a tripwire: any
/// other repository call this page starts making fails loudly rather than
/// silently returning null.
class _FakeAccessRepository implements AccessRepository {
  _FakeAccessRepository({this.onCreate});

  /// Replaces the body of [createFirstUser] — throw from here to exercise the
  /// race and error paths.
  final Future<void> Function(String username, String password)? onCreate;

  /// Every `createFirstUser` call, in order. A test that asserts the button
  /// did *not* submit asserts this is empty.
  final List<({String username, String password})> calls = [];

  @override
  Future<void> createFirstUser({
    required String username,
    required String password,
  }) async {
    calls.add((username: username, password: password));
    final hook = onCreate;
    if (hook != null) await hook(username, password);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'The first-user page called AccessRepository.'
        '${invocation.memberName}, which this fake does not implement.',
      );
}

/// Pumps [FirstUserBody] under a bare [MaterialApp].
///
/// Deliberately **not** [FirstUserPage]: that renders `BaseScaffold`, which
/// calls `context.currentBeamLocation` and cannot be pumped without a Beamer
/// ancestor. The split between the two widgets exists precisely so this
/// harness can stay four lines long.
Widget _buildBody({
  required Future<bool> Function() windowOpen,
  required Future<AccessRepository?> Function() repository,
  AccessSignInOpener? openSignIn,
}) {
  return ProviderScope(
    overrides: [
      accessRepositoryProvider.overrideWith((ref) => repository()),
      firstUserWindowOpenProvider.overrideWith((ref) => windowOpen()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: openSignIn == null
            ? const FirstUserBody()
            : FirstUserBody(openSignIn: openSignIn),
      ),
    ),
  );
}

/// The open-window case with a working repository.
Widget _openWindow(
  _FakeAccessRepository repo, {
  bool Function()? isOpen,
  AccessSignInOpener? openSignIn,
}) =>
    _buildBody(
      windowOpen: () async => isOpen?.call() ?? true,
      repository: () async => repo,
      openSignIn: openSignIn,
    );

Finder _usernameField() => find.widgetWithText(TextField, 'Username');
Finder _passwordField() => find.widgetWithText(TextField, 'Password');
Finder _confirmField() => find.widgetWithText(TextField, 'Confirm password');
Finder _createButton() => find.widgetWithText(ElevatedButton, 'Create account');

/// True when no [Text] widget anywhere in the tree contains [secret].
///
/// `find.text` also matches `EditableText`, so it cannot distinguish "the
/// obscured field holds it" from "a label leaked it". This predicate looks at
/// rendered copy only.
Finder _textContaining(String needle) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains(needle),
    );

Future<void> _fillForm(
  WidgetTester tester, {
  String username = 'commissioner',
  String password = 'correct horse',
  String? confirm,
}) async {
  await tester.enterText(_usernameField(), username);
  await tester.enterText(_passwordField(), password);
  await tester.enterText(_confirmField(), confirm ?? password);
  await settle(tester);
}

void main() {
  group('first-user window, open', () {
    testWidgets('shows the three fields and the create action', (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(_usernameField(), findsOneWidget);
      expect(_passwordField(), findsOneWidget);
      expect(_confirmField(), findsOneWidget);
      expect(_createButton(), findsOneWidget);
    });

    testWidgets('names the Engineering role it is about to create',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(
        _textContaining(
          'Roles are seeded; users are not. This creates the first '
          'Engineering account.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('says the window closes permanently, with no default password',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(
        _textContaining(
          'This window is open only while no users exist. Once this account '
          'is created it closes permanently — there is no default password '
          'and no bootstrap flag.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('says a fresh station is claimable and to do this at '
        'commissioning', (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(
        _textContaining(
          'A freshly deployed station is claimable by whoever reaches it '
          'first. Do this at commissioning.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('carries the honesty line — a guardrail, not a boundary',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(
        _textContaining(
          'Signing in records who changed what. It is a guardrail, not a '
          'security boundary.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('offers no role picker', (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      // createFirstUser takes no role parameter, so a picker would imply a
      // choice that does not exist.
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      // A field labelled exactly 'Role'. Not textContaining: the intro copy
      // legitimately says "Roles are seeded; users are not".
      expect(find.text('Role'), findsNothing);
      expect(find.text('Role:'), findsNothing);
    });

    testWidgets('offers no skip or later affordance', (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(find.textContaining('Skip'), findsNothing);
      expect(find.textContaining('Later'), findsNothing);
      expect(find.textContaining('Not now'), findsNothing);
    });
  });

  group('first-user window, loading', () {
    testWidgets('shows a progress indicator, not an empty box',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(
        tester,
        _buildBody(
          windowOpen: () => Completer<bool>().future,
          repository: () async => repo,
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_usernameField(), findsNothing);
    });

    testWidgets('waits on the repository too, rather than flashing the '
        'no-database message', (tester) async {
      await pumpAndLoad(
        tester,
        _buildBody(
          windowOpen: () async => true,
          repository: () => Completer<AccessRepository?>().future,
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_textContaining('database'), findsNothing);
    });
  });

  group('first-user window, closed', () {
    testWidgets('shows the closed message and no form', (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(
        tester,
        _buildBody(windowOpen: () async => false, repository: () async => repo),
      );

      expect(
        _textContaining(
          'An account already exists, so this window is closed. Recovery is '
          'a deployment task — see docs/access-control-deployment.md.',
        ),
        findsOneWidget,
      );
      expect(_usernameField(), findsNothing);
      expect(_passwordField(), findsNothing);
      expect(_createButton(), findsNothing);
    });
  });

  group('no database', () {
    testWidgets('names the database as the missing piece, and shows no form',
        (tester) async {
      await pumpAndLoad(
        tester,
        _buildBody(
          // The provider itself answers false with no repository; the page
          // must not mistake that for "somebody already claimed this station".
          windowOpen: () async => false,
          repository: () async => null,
        ),
      );

      expect(_textContaining('database'), findsOneWidget);
      expect(_usernameField(), findsNothing);
      expect(_createButton(), findsNothing);
      expect(_textContaining('An account already exists'), findsNothing);
    });
  });

  group('validation', () {
    testWidgets('a password mismatch shows an inline error and does not submit',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester, password: 'alpha one', confirm: 'alpha two');
      await tester.tap(_createButton());
      await settle(tester);

      expect(_textContaining('The passwords do not match.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('an empty username shows an inline error and does not submit',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester, username: '   ');
      await tester.tap(_createButton());
      await settle(tester);

      expect(_textContaining('Enter a username.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('an empty password shows an inline error and does not submit',
        (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester, password: '', confirm: '');
      await tester.tap(_createButton());
      await settle(tester);

      expect(_textContaining('Enter a password.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });
  });

  group('submission', () {
    /// A repository whose `createFirstUser` closes the window the way the real
    /// one does — by making the next window question answer false.
    ({_FakeAccessRepository repo, Widget host}) successHost({
      AccessSignInOpener? openSignIn,
    }) {
      var open = true;
      final repo = _FakeAccessRepository(onCreate: (_, __) async {
        // The real repository closes the window by inserting the row; the
        // fake closes it by flipping what the provider answers next.
        open = false;
      });
      return (
        repo: repo,
        host: _openWindow(repo, isOpen: () => open, openSignIn: openSignIn),
      );
    }

    testWidgets('a successful creation confirms the account and closes the '
        'form, without a restart', (tester) async {
      final (:repo, :host) = successHost();
      await pumpAndLoad(tester, host);

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);

      expect(repo.calls, hasLength(1));
      expect(repo.calls.single.username, 'commissioner');
      expect(_textContaining('Account created'), findsOneWidget);
      expect(_textContaining('commissioner'), findsOneWidget);
      expect(_usernameField(), findsNothing);
    });

    testWidgets('a successful creation never shows the already-exists message',
        (tester) async {
      // The regression this whole group exists for. The window IS shut once
      // the row lands, so every closed branch in build() goes true at once —
      // and telling the engineer who just claimed the station that somebody
      // else claimed it reads as a failure of the thing that succeeded.
      final (:repo, :host) = successHost();
      await pumpAndLoad(tester, host);

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);

      // Anchored on the call, not only on absent copy: every other assertion
      // here is findsNothing, so a tap that missed the button would leave the
      // form on screen and pass the lot.
      expect(repo.calls, hasLength(1));
      expect(_textContaining('An account already exists'), findsNothing);
      expect(_textContaining('Recovery is a deployment task'), findsNothing);
    });

    testWidgets('the confirmation survives the window provider erroring after '
        'the account is created', (tester) async {
      // The window question failing is not evidence the account went away.
      // build() answers a windowAsync error with _kClosed — correct while the
      // form is up, and the wrong story once this screen has committed a row.
      var thrower = false;
      final repo = _FakeAccessRepository(onCreate: (_, __) async {
        thrower = true;
      });
      await pumpAndLoad(
        tester,
        _buildBody(
          windowOpen: () async {
            if (thrower) throw StateError('cannot count app_user');
            return true;
          },
          repository: () async => repo,
        ),
      );

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);

      expect(repo.calls, hasLength(1));
      expect(_textContaining('Account created'), findsOneWidget);
      expect(_textContaining('An account already exists'), findsNothing);
    });

    testWidgets('the confirmation survives the database going away after the '
        'account is created', (tester) async {
      // The finding from the review: accessRepositoryProvider follows
      // databaseProvider, so a Server Config edit or a dropped connection
      // re-emits null — and _kNoDatabase claims the first account "cannot be
      // created yet", moments after it was.
      final repo = _FakeAccessRepository();
      var present = true;

      // A container the test holds, rather than `_buildBody`'s scope: the page
      // never invalidates `accessRepositoryProvider` itself, so re-emitting it
      // is something only the owner of the container can do — and a rebuild
      // that reads the same cached value would prove nothing.
      final container = ProviderContainer(
        overrides: [
          accessRepositoryProvider
              .overrideWith((ref) async => present ? repo : null),
          firstUserWindowOpenProvider.overrideWith((ref) async => true),
        ],
      );
      addTearDown(container.dispose);

      await pumpAndLoad(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: FirstUserBody())),
        ),
      );

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);
      expect(_textContaining('Account created'), findsOneWidget);

      // The database drops out from under the confirmation.
      present = false;
      container.invalidate(accessRepositoryProvider);
      await settle(tester);

      expect(_textContaining('Account created'), findsOneWidget);
      expect(_textContaining('no reachable database'), findsNothing);
    });

    testWidgets('the success state offers sign-in, and the action opens it',
        (tester) async {
      var opened = 0;
      final (:repo, :host) = successHost(
        openSignIn: (context, ref) async => opened++,
      );
      await pumpAndLoad(tester, host);

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);

      expect(find.byKey(kFirstUserSignInKey), findsOneWidget);

      // Injected rather than real: `showAccessSignInDialog` beams on the value
      // the dialog pops with, and this harness has no Beamer ancestor.
      await tester.tap(find.byKey(kFirstUserSignInKey));
      await settle(tester);
      expect(opened, 1);
    });

    // There is deliberately no test that the password controllers are cleared
    // on success. The fields leave the tree either way, so every assertion
    // available from out here passes with or without the `clear()` calls — a
    // test that cannot fail is worse than the comment in `_submit` that says
    // why they are there.

    testWidgets('a FirstUserWindowClosedError shows the closed message, not a '
        'crash', (tester) async {
      final repo = _FakeAccessRepository(
        // Somebody else claimed the station between the window check and this
        // submit. The repository's transaction is what made that correct; the
        // page's job is only to say so.
        onCreate: (_, __) async => throw FirstUserWindowClosedError(),
      );
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(
        _textContaining('An account already exists, so this window is closed.'),
        findsOneWidget,
      );
      // The mirror of the success case: losing the race created nothing, so
      // the confirmation must not appear either.
      expect(_textContaining('Account created'), findsNothing);
      expect(_usernameField(), findsNothing);
    });

    testWidgets('the create action is disabled while a submission is in flight',
        (tester) async {
      final gate = Completer<void>();
      final repo = _FakeAccessRepository(onCreate: (_, __) => gate.future);
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester);
      await tester.tap(_createButton());
      await tester.pump();

      expect(
        tester.widget<ElevatedButton>(_createButton()).onPressed,
        isNull,
        reason: 'a second tap would race two createFirstUser calls',
      );

      gate.complete();
      await settle(tester);
    });

    testWidgets('an unexpected repository failure shows an error and re-enables '
        'the action', (tester) async {
      final repo = _FakeAccessRepository(
        onCreate: (_, __) async => throw StateError('connection reset'),
      );
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester);
      await tester.tap(_createButton());
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(_createButton(), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(_createButton()).onPressed,
        isNotNull,
      );
      expect(
        _textContaining('The account could not be created'),
        findsOneWidget,
      );
    });
  });

  group('the password', () {
    testWidgets('is obscured in both fields', (tester) async {
      final repo = _FakeAccessRepository();
      await pumpAndLoad(tester, _openWindow(repo));

      expect(tester.widget<TextField>(_passwordField()).obscureText, isTrue);
      expect(tester.widget<TextField>(_confirmField()).obscureText, isTrue);
    });

    testWidgets('appears in no rendered copy, including error messages',
        (tester) async {
      const secret = 'hunter2-battery-staple';
      final repo = _FakeAccessRepository(
        onCreate: (_, __) async => throw StateError('boom $secret'),
      );
      await pumpAndLoad(tester, _openWindow(repo));

      await _fillForm(tester, password: secret);
      await tester.tap(_createButton());
      await settle(tester);

      // Not find.text: that matches EditableText too, and the obscured field
      // legitimately holds the secret. Only rendered copy is in scope.
      expect(_textContaining(secret), findsNothing);
      expect(_textContaining('hunter2'), findsNothing);
    });
  });
}
