/// The modal sign-in form: the inline error, the in-flight guard, and the
/// commissioning-window link.
///
/// Everything here drives a fake `AccessSessionController`, so no test reaches
/// a database, a preference store or a timer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/routes.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc_access/tfc_access.dart';

/// Answers each `signIn` with the next scripted result, records what it was
/// asked, and can be held mid-flight by [gate].
class _FakeSessionController extends AccessSessionController {
  _FakeSessionController({List<AccessSignInResult>? results})
      : _results = results ?? const [];

  final List<AccessSignInResult> _results;

  final List<List<String>> attempts = <List<String>>[];

  /// When set, `signIn` waits on it before answering — a submission in flight.
  Completer<void>? gate;

  /// Who a successful `signIn` publishes. Null leaves the session anonymous,
  /// which is what the tests that predate the panel commitment want.
  AuthenticatedUser? signsInAs;

  /// What `panelAccount()` answers — the account this panel is already
  /// committed to, if any.
  String? committedTo;

  /// Usernames passed to `commitPanelAccount`, so a test can assert the
  /// commitment happened rather than inferring it.
  final List<String> commits = <String>[];

  @override
  Future<AccessSession> build() async => AccessSession.anonymous(const {});

  @override
  Future<AccessSignInResult> signIn(String username, String password) async {
    attempts.add(<String>[username, password]);
    final g = gate;
    if (g != null) await g.future;
    final index = attempts.length - 1;
    final result = index < _results.length
        ? _results[index]
        : AccessSignInResult.badCredentials;

    final user = signsInAs;
    if (result == AccessSignInResult.ok && user != null) {
      state = AsyncData(AccessSession(user: user, groups: const {}));
    }
    return result;
  }

  @override
  Future<String?> panelAccount() async => committedTo;

  @override
  Future<bool> commitPanelAccount() async {
    final user = state.valueOrNull?.user;
    if (user == null || !user.stationAccount) return false;
    commits.add(user.username);
    committedTo = user.username;
    return true;
  }
}

/// Opens the real dialog from a button, so the tests exercise
/// [showAccessSignInDialog] and get a Navigator that can actually pop.
Widget _host({
  required _FakeSessionController controller,
  bool firstUserWindowOpen = false,
}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => controller),
      firstUserWindowOpenProvider.overrideWith((ref) async => firstUserWindowOpen),
    ],
    child: MaterialApp(
      home: Consumer(
        builder: (context, ref, _) {
          // Listened from the first frame, as `BaseScaffold` does in the real
          // app. Without it the notifier is not created until `_submit` reads
          // it, and a `state` written by `signIn` is then clobbered by the
          // still-pending `build()` completing behind it — which is a fact
          // about the test host, not about the dialog.
          ref.watch(accessSessionProvider);
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAccessSignInDialog(context, ref),
                child: const Text('open'),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Pushes [AccessSignInDialog] directly so the test can read the value it pops
/// with — which is how the first-account link names its destination.
Widget _routeCapturingHost({
  required _FakeSessionController controller,
  required List<String?> popped,
  bool firstUserWindowOpen = false,
}) {
  return ProviderScope(
    overrides: [
      accessSessionProvider.overrideWith(() => controller),
      firstUserWindowOpenProvider.overrideWith((ref) async => firstUserWindowOpen),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                popped.add(await showDialog<String>(
                  context: context,
                  builder: (_) => const AccessSignInDialog(),
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fillIn(
  WidgetTester tester, {
  String username = 'anna',
  String password = 'hunter2',
}) async {
  await tester.enterText(find.byKey(kAccessSignInUsernameKey), username);
  await tester.enterText(find.byKey(kAccessSignInPasswordKey), password);
  await tester.pump();
}

void main() {
  group('AccessSignInDialog', () {
    testWidgets('shows a username field, a password field, Sign in and Cancel',
        (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      expect(find.byKey(kAccessSignInUsernameKey), findsOneWidget);
      expect(find.byKey(kAccessSignInPasswordKey), findsOneWidget);
      expect(find.byKey(kAccessSignInSubmitKey), findsOneWidget);
      expect(find.byKey(kAccessSignInCancelKey), findsOneWidget);
    });

    testWidgets('carries the honesty line: signing in is not a boundary',
        (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      expect(find.text(kAccessSignInHonestyNote), findsOneWidget);
      expect(kAccessSignInHonestyNote, contains('not a security boundary'));
    });

    testWidgets('the honesty line wraps rather than ellipsising',
        (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      // `find.text` above passes whether or not a single character of the
      // sentence is legible: a `Text` widget carries its full `data` even when
      // the painter clips it to "…not a security bo…". That is exactly what
      // the header subtitle did — `PaneHeader` renders one line with
      // `TextOverflow.ellipsis` — and only the golden showed it. Spec §8's
      // honesty requirement is about what the operator can read, so pin the
      // properties that decide it.
      final note = tester.widget<Text>(find.byKey(kAccessSignInHonestyKey));
      expect(note.data, kAccessSignInHonestyNote);
      expect(note.maxLines, isNull);
      expect(note.overflow, isNot(TextOverflow.ellipsis));

      // And it is genuinely painted on more than one line at the dialog's real
      // width, which is the observation the golden makes.
      final rendered = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(kAccessSignInHonestyKey),
          matching: find.byType(RichText),
        ),
      );
      expect(rendered.size.height, greaterThan(rendered.preferredLineHeight));
    });

    testWidgets('valid credentials close the dialog', (tester) async {
      final controller =
          _FakeSessionController(results: [AccessSignInResult.ok]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);

      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();

      expect(controller.attempts, [
        ['anna', 'hunter2']
      ]);
      expect(find.byKey(kAccessSignInUsernameKey), findsNothing);
    });

    testWidgets('wrong credentials keep the dialog open with an inline error',
        (tester) async {
      final controller = _FakeSessionController(
          results: [AccessSignInResult.badCredentials]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);

      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessSignInUsernameKey), findsOneWidget);
      expect(find.text(kAccessSignInBadCredentialsMessage), findsOneWidget);
      expect(kAccessSignInBadCredentialsMessage,
          'Username or password not recognised');
    });

    testWidgets('the error clears as soon as the username is edited',
        (tester) async {
      final controller = _FakeSessionController(
          results: [AccessSignInResult.badCredentials]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);
      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();
      expect(find.text(kAccessSignInBadCredentialsMessage), findsOneWidget);

      await tester.enterText(find.byKey(kAccessSignInUsernameKey), 'annb');
      await tester.pump();

      expect(find.text(kAccessSignInBadCredentialsMessage), findsNothing);
    });

    testWidgets('the error clears as soon as the password is edited',
        (tester) async {
      final controller = _FakeSessionController(
          results: [AccessSignInResult.badCredentials]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);
      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();
      expect(find.text(kAccessSignInBadCredentialsMessage), findsOneWidget);

      await tester.enterText(find.byKey(kAccessSignInPasswordKey), 'hunter3');
      await tester.pump();

      expect(find.text(kAccessSignInBadCredentialsMessage), findsNothing);
    });

    testWidgets('an outage names the database, not the credentials',
        (tester) async {
      final controller =
          _FakeSessionController(results: [AccessSignInResult.unavailable]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);

      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();

      expect(find.text(kAccessSignInUnavailableMessage), findsOneWidget);
      expect(find.text(kAccessSignInBadCredentialsMessage), findsNothing);
      expect(kAccessSignInUnavailableMessage,
          isNot(kAccessSignInBadCredentialsMessage));
      expect(kAccessSignInUnavailableMessage.toLowerCase(),
          contains('database'));
    });

    testWidgets('the password is obscured and rendered nowhere else',
        (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);
      await _fillIn(tester, password: 'sup3rsecret');

      final password = tester.widget<TextField>(
        find.byKey(kAccessSignInPasswordKey),
      );
      expect(password.obscureText, isTrue);

      // The only widget carrying the text is the field itself.
      expect(find.widgetWithText(Text, 'sup3rsecret'), findsNothing);
      expect(find.text('sup3rsecret'), findsOneWidget);
    });

    testWidgets('pressing Enter in the password field submits', (tester) async {
      final controller =
          _FakeSessionController(results: [AccessSignInResult.ok]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);

      await tester.showKeyboard(find.byKey(kAccessSignInPasswordKey));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(controller.attempts, [
        ['anna', 'hunter2']
      ]);
    });

    testWidgets('Sign in is disabled while a submission is in flight',
        (tester) async {
      final controller =
          _FakeSessionController(results: [AccessSignInResult.ok])
            ..gate = Completer<void>();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);

      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pump();

      final button =
          tester.widget<FilledButton>(find.byKey(kAccessSignInSubmitKey));
      expect(button.onPressed, isNull);

      controller.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a double tap cannot produce two attempts', (tester) async {
      final controller = _FakeSessionController(
        results: [AccessSignInResult.ok, AccessSignInResult.ok],
      )..gate = Completer<void>();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fillIn(tester);

      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pump();
      await tester.tap(find.byKey(kAccessSignInSubmitKey),
          warnIfMissed: false);
      await tester.pump();

      expect(controller.attempts, hasLength(1));

      controller.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('the first-account link shows while the window is open',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(),
        firstUserWindowOpen: true,
      ));
      await _open(tester);

      expect(find.byKey(kAccessSignInFirstUserKey), findsOneWidget);
    });

    testWidgets('the first-account link is absent once the window has closed',
        (tester) async {
      await tester.pumpWidget(_host(
        controller: _FakeSessionController(),
        firstUserWindowOpen: false,
      ));
      await _open(tester);

      expect(find.byKey(kAccessSignInFirstUserKey), findsNothing);
    });

    testWidgets('the first-account link pops with the first-user route',
        (tester) async {
      final popped = <String?>[];
      await tester.pumpWidget(_routeCapturingHost(
        controller: _FakeSessionController(),
        popped: popped,
        firstUserWindowOpen: true,
      ));
      await _open(tester);

      await tester.tap(find.byKey(kAccessSignInFirstUserKey));
      await tester.pumpAndSettle();

      expect(popped, [AppRoutes.firstUser]);
      expect(find.byKey(kAccessSignInUsernameKey), findsNothing);
    });

    testWidgets('Cancel closes the dialog without an attempt', (tester) async {
      final controller = _FakeSessionController();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);

      await tester.tap(find.byKey(kAccessSignInCancelKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessSignInUsernameKey), findsNothing);
      expect(controller.attempts, isEmpty);
    });

    testWidgets('there is no forgot-password affordance', (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      expect(
        find.textContaining('orgot', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining('eset password'), findsNothing);
    });

    testWidgets('says Sign in, never Login', (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      expect(find.textContaining('Login'), findsNothing);
      expect(find.textContaining('Log in'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Committing the panel
  // -------------------------------------------------------------------------

  /// The prompt that turns a station-account sign-in into a commissioned panel.
  ///
  /// It is deliberately a *second* dialog rather than a checkbox on the form:
  /// whether an account is a station account is a database fact, unknown until
  /// the credential has been accepted.
  group('the panel commitment prompt', () {
    const freezer = AuthenticatedUser(
      username: 'freezer',
      roleName: kOperatorRoleName,
      stationAccount: true,
    );
    const person = AuthenticatedUser(
      username: 'jon',
      roleName: 'Engineering',
    );

    Future<_FakeSessionController> signInAs(
      WidgetTester tester,
      AuthenticatedUser user, {
      String? committedTo,
    }) async {
      final controller =
          _FakeSessionController(results: const [AccessSignInResult.ok])
            ..signsInAs = user
            ..committedTo = committedTo;
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await tester.enterText(
          find.byKey(kAccessSignInUsernameKey), user.username);
      await tester.enterText(find.byKey(kAccessSignInPasswordKey), 'pw');
      await tester.tap(find.byKey(kAccessSignInSubmitKey));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('is offered when a station account signs in', (tester) async {
      await signInAs(tester, freezer);

      expect(find.text(kAccessSignInCommitTitle('freezer')), findsOneWidget);
      expect(find.text(kAccessSignInCommitConfirm), findsOneWidget);
    });

    testWidgets('names the account and states both promises', (tester) async {
      await signInAs(tester, freezer);

      final message = kAccessSignInCommitMessage('freezer');
      expect(find.text(message), findsOneWidget);
      // The obvious promise.
      expect(message, contains('across restarts'));
      // The surprising one, which is the whole reason the copy is long: an
      // administrator who only reads the first half would discover on their
      // own that a panel they thought they had locked comes back by itself.
      expect(message, contains('sign in over it'));
      expect(message, contains('returns to freezer'));
      // And the way out, so the prompt is not a one-way door — which is no
      // longer a sign-out, so the prompt must not promise one.
      expect(message, contains('cannot be signed out'));
      expect(message, contains('Advanced > Access'));
    });

    testWidgets('confirming commits the panel', (tester) async {
      final controller = await signInAs(tester, freezer);

      await tester.tap(find.text(kAccessSignInCommitConfirm));
      await tester.pumpAndSettle();

      expect(controller.commits, ['freezer']);
      expect(find.byKey(kAccessSignInUsernameKey), findsNothing,
          reason: 'the sign-in dialog closes once the question is answered');
    });

    testWidgets('declining leaves the panel uncommitted and the session up',
        (tester) async {
      final controller = await signInAs(tester, freezer);

      await tester.tap(find.text(kAccessSignInCommitCancel));
      await tester.pumpAndSettle();

      expect(controller.commits, isEmpty);
      expect(controller.committedTo, isNull);
      expect(controller.state.valueOrNull?.isElevated, isTrue,
          reason: 'declining is an answer about the panel, not about the '
              'sign-in — which is what makes it safe to sign in as a station '
              'account on a workstation to check something');
      expect(find.byKey(kAccessSignInUsernameKey), findsNothing);
    });

    testWidgets('is not offered to a person', (tester) async {
      await signInAs(tester, person);

      expect(find.text(kAccessSignInCommitTitle('jon')), findsNothing);
      expect(find.byKey(kAccessSignInUsernameKey), findsNothing,
          reason: 'a person sees exactly the dialog they saw before this '
              'feature existed');
    });

    testWidgets('is not offered when the panel already holds this account',
        (tester) async {
      final controller =
          await signInAs(tester, freezer, committedTo: 'freezer');

      expect(find.text(kAccessSignInCommitTitle('freezer')), findsNothing);
      expect(controller.commits, isEmpty);
    });

    testWidgets('is offered when the panel holds a different account',
        (tester) async {
      await signInAs(tester, freezer, committedTo: 'chiller');

      expect(find.text(kAccessSignInCommitTitle('freezer')), findsOneWidget);
    });
  });
}
