/// The self-service change-password form: the three local checks, the inline
/// notes, the in-flight guard, and what it does and does not throw away on a
/// refusal.
///
/// Everything here drives a fake `AccessSessionController`, so no test reaches
/// a database, a preference store, a timer or a real Argon2id derivation. The
/// same shape as `access_sign_in_dialog_test.dart`, which is the sibling form.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_change_password_dialog.dart';
import 'package:tfc_access/tfc_access.dart';

/// Answers each `changeOwnPassword` with the next scripted result, records what
/// it was asked, and can be held mid-flight by [gate].
class _FakeSessionController extends AccessSessionController {
  _FakeSessionController({List<AccessPasswordChangeResult>? results})
      : _results = results ?? const [];

  final List<AccessPasswordChangeResult> _results;

  /// Every (current, new) pair the dialog submitted.
  final List<({String current, String next})> attempts = [];

  /// When set, `changeOwnPassword` waits on it before answering — a submission
  /// in flight.
  Completer<void>? gate;

  @override
  Future<AccessSession> build() async => AccessSession(
        user: const AuthenticatedUser(
          username: 'jon',
          roleName: 'Engineering',
        ),
        groups: const {},
      );

  @override
  Future<AccessPasswordChangeResult> changeOwnPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    attempts.add((current: currentPassword, next: newPassword));
    final g = gate;
    if (g != null) await g.future;
    final index = attempts.length - 1;
    return index < _results.length
        ? _results[index]
        : AccessPasswordChangeResult.ok;
  }
}

/// Opens the real dialog from a button, so the tests exercise
/// [showAccessChangePasswordDialog] and get a Navigator that can actually pop
/// and a `ScaffoldMessenger` the snackbar can land on.
Widget _host({required _FakeSessionController controller}) {
  return ProviderScope(
    overrides: [accessSessionProvider.overrideWith(() => controller)],
    child: MaterialApp(
      home: Consumer(
        builder: (context, ref, _) {
          // Listened from the first frame, as `BaseScaffold` does in the real
          // app — the same reason `access_sign_in_dialog_test.dart` gives.
          ref.watch(accessSessionProvider);
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAccessChangePasswordDialog(context, ref),
                child: const Text('open'),
              ),
            ),
          );
        },
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String current = 'hunter2',
  String next = 'letmein',
  String? confirm,
}) async {
  await tester.enterText(find.byKey(kAccessChangePasswordCurrentKey), current);
  await tester.enterText(find.byKey(kAccessChangePasswordNewKey), next);
  await tester.enterText(
      find.byKey(kAccessChangePasswordConfirmKey), confirm ?? next);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(kAccessChangePasswordSubmitKey));
  await tester.pumpAndSettle();
}

void main() {
  group('the form', () {
    testWidgets('has three obscured fields and no username field',
        (tester) async {
      // The username is whoever is signed in. A field for it would make this
      // the admin dialog, which is a different screen behind a different gate.
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      expect(find.byKey(kAccessChangePasswordCurrentKey), findsOneWidget);
      expect(find.byKey(kAccessChangePasswordNewKey), findsOneWidget);
      expect(find.byKey(kAccessChangePasswordConfirmKey), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));

      for (final key in [
        kAccessChangePasswordCurrentKey,
        kAccessChangePasswordNewKey,
        kAccessChangePasswordConfirmKey,
      ]) {
        expect(tester.widget<TextField>(find.byKey(key)).obscureText, isTrue,
            reason: 'every field on this form holds a password');
      }
    });

    testWidgets('says the change does not sign you out', (tester) async {
      // The surprising half. Somebody expecting the web-application behaviour
      // otherwise spends the next minute wondering whether it took.
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);

      expect(find.text(kAccessChangePasswordExplainer), findsOneWidget);
    });
  });

  group('the three local checks', () {
    testWidgets('a blank current password is refused before any attempt',
        (tester) async {
      final controller = _FakeSessionController();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester, current: '');
      await _submit(tester);

      expect(find.text(kAccessChangePasswordBlankCurrentNote), findsOneWidget);
      expect(controller.attempts, isEmpty,
          reason: 'a local refusal must not cost a derivation or an audit row');
    });

    testWidgets('a blank new password is refused', (tester) async {
      final controller = _FakeSessionController();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester, next: '', confirm: '');
      await _submit(tester);

      expect(find.text(kAccessChangePasswordBlankNewNote), findsOneWidget);
      expect(controller.attempts, isEmpty);
    });

    testWidgets('two disagreeing new passwords are refused', (tester) async {
      final controller = _FakeSessionController();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester, next: 'letmein', confirm: 'letmeout');
      await _submit(tester);

      expect(find.text(kAccessChangePasswordMismatchNote), findsOneWidget);
      expect(controller.attempts, isEmpty);
    });

    testWidgets('the note clears as soon as a field is edited', (tester) async {
      await tester.pumpWidget(_host(controller: _FakeSessionController()));
      await _open(tester);
      await _fill(tester, current: '');
      await _submit(tester);
      expect(find.byKey(kAccessChangePasswordNoteKey), findsOneWidget);

      await tester.enterText(
          find.byKey(kAccessChangePasswordCurrentKey), 'hunter2');
      await tester.pump();

      expect(find.byKey(kAccessChangePasswordNoteKey), findsNothing,
          reason: 'a stale complaint about a value already corrected is noise');
    });

    testWidgets('no length floor and no difference requirement',
        (tester) async {
      // The repo has no password policy, stated where accounts are created. A
      // one-character password identical to the current one goes through.
      final controller = _FakeSessionController();
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester, current: 'a', next: 'a');
      await _submit(tester);

      expect(controller.attempts.single.current, 'a');
      expect(controller.attempts.single.next, 'a');
    });
  });

  group('what comes back', () {
    testWidgets('success closes the dialog and says so', (tester) async {
      final controller = _FakeSessionController(
          results: const [AccessPasswordChangeResult.ok]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester);
      await _submit(tester);

      expect(find.byType(AccessChangePasswordDialog), findsNothing);
      expect(find.text(kAccessChangePasswordDoneMessage), findsOneWidget);
    });

    testWidgets('a wrong current password keeps the dialog and the new fields',
        (tester) async {
      // Throwing away a new password somebody typed twice, to punish a typo in
      // a different field, is how a form makes somebody give up.
      final controller = _FakeSessionController(
          results: const [AccessPasswordChangeResult.wrongCurrentPassword]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester, next: 'battery staple');
      await _submit(tester);

      expect(find.byType(AccessChangePasswordDialog), findsOneWidget);
      expect(find.text(kAccessChangePasswordWrongCurrentNote), findsOneWidget);

      expect(
        tester
            .widget<TextField>(find.byKey(kAccessChangePasswordNewKey))
            .controller!
            .text,
        'battery staple',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(kAccessChangePasswordCurrentKey))
            .controller!
            .text,
        isEmpty,
        reason: 'the field that was wrong is the one worth retyping',
      );
    });

    testWidgets('an expired session gets its own sentence', (tester) async {
      // The one failure with an obvious next step. Sending somebody to read a
      // log because their session timed out is a wild goose chase.
      final controller = _FakeSessionController(
          results: const [AccessPasswordChangeResult.notSignedIn]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester);
      await _submit(tester);

      expect(find.text(kAccessChangePasswordNotSignedInNote), findsOneWidget);
      expect(find.byType(AccessChangePasswordDialog), findsOneWidget);
    });

    testWidgets('everything else points at the log', (tester) async {
      final controller = _FakeSessionController(
          results: const [AccessPasswordChangeResult.unavailable]);
      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester);
      await _submit(tester);

      expect(find.text(kAccessChangePasswordFailedNote), findsOneWidget);
    });

    testWidgets('no failure renders an exception object', (tester) async {
      // The rule `access_users_section.dart` states for every screen where a
      // password is in hand: an ArgumentError can carry the credential in its
      // message, and from a dialog it goes into a screenshot. Every branch must
      // show one of the fixed sentences and nothing else.
      for (final result in [
        AccessPasswordChangeResult.wrongCurrentPassword,
        AccessPasswordChangeResult.notSignedIn,
        AccessPasswordChangeResult.unavailable,
      ]) {
        await tester.pumpWidget(
            _host(controller: _FakeSessionController(results: [result])));
        await _open(tester);
        await _fill(tester, current: 'hunter2', next: 'battery staple');
        await _submit(tester);

        final shown = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join('\n');

        expect(shown, isNot(contains('Exception')));
        expect(shown, isNot(contains('Error')));
        expect(shown, isNot(contains('hunter2')),
            reason: 'the password must not reach the screen it was typed on');
        expect(shown, isNot(contains('battery staple')));
      }
    });
  });

  group('the in-flight guard', () {
    testWidgets('a second tap cannot fire a second attempt', (tester) async {
      // Two Argon2id derivations run behind this — a verify and a hash — so on
      // a panel a second tap is a real possibility, and two attempts would
      // write two audit rows for one human action.
      final controller = _FakeSessionController(
          results: const [AccessPasswordChangeResult.ok]);
      controller.gate = Completer<void>();

      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester);

      await tester.tap(find.byKey(kAccessChangePasswordSubmitKey));
      await tester.pump();
      await tester.tap(find.byKey(kAccessChangePasswordSubmitKey));
      await tester.pump();

      expect(controller.attempts, hasLength(1));

      controller.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('cancel is disabled mid-flight', (tester) async {
      // Popping the route while the write is in flight would leave the change
      // to land with nothing to report its outcome to.
      final controller = _FakeSessionController(
          results: const [AccessPasswordChangeResult.ok]);
      controller.gate = Completer<void>();

      await tester.pumpWidget(_host(controller: controller));
      await _open(tester);
      await _fill(tester);
      await tester.tap(find.byKey(kAccessChangePasswordSubmitKey));
      await tester.pump();

      expect(
        tester
            .widget<ButtonStyleButton>(
                find.byKey(kAccessChangePasswordCancelKey))
            .onPressed,
        isNull,
      );

      controller.gate!.complete();
      await tester.pumpAndSettle();
    });
  });

  testWidgets('cancel submits nothing', (tester) async {
    final controller = _FakeSessionController();
    await tester.pumpWidget(_host(controller: controller));
    await _open(tester);
    await _fill(tester);
    await tester.tap(find.byKey(kAccessChangePasswordCancelKey));
    await tester.pumpAndSettle();

    expect(controller.attempts, isEmpty);
    expect(find.byType(AccessChangePasswordDialog), findsNothing);
  });
}
