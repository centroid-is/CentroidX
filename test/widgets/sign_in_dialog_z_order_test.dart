/// The sign-in dialog must sit above every floating window.
///
/// `showFloatingDialog` inserts straight into the root overlay
/// (`Overlay.of(context, rootOverlay: true)`), while `Navigator` inserts a
/// pushed route's entries only above the *previous route's* entries. A dialog
/// route opened after a floating window therefore lands **underneath** it —
/// the behaviour `showFloatingDialog`'s own documentation warns about: "a
/// route opened from inside a floating window lands underneath it".
///
/// For a trend window that is a quirk you work around. For sign-in it is a
/// fault: the panel asks an operator for credentials with a form they can
/// neither see nor reach, and the plant view they were looking at keeps
/// taking their taps as if nothing had been asked.
///
/// The assertion here is deliberately behavioural rather than structural. A
/// test that only looked for the dialog in the tree would pass while it was
/// buried; what "on top" means to the person standing at the panel is that
/// their next tap goes to the sign-in form and **not** to whatever window was
/// in front of it. So the floating window carries a button that records taps,
/// and the test aims a tap straight at it.
///
/// It also pins the thing a lazy fix would break: the floating windows stay
/// open. Closing them would put sign-in on top trivially and throw away the
/// trends somebody arranged, so `stillOpen` is part of the contract.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc_access/tfc_access.dart';

/// The least controller these tests can run on: anonymous, never asked to
/// sign anybody in. The form only has to be *reachable* here.
class _AnonymousSession extends AccessSessionController {
  @override
  Future<AccessSession> build() async => AccessSession.anonymous(const {});

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.badCredentials;

  @override
  Future<String?> panelAccount() async => null;

  @override
  Future<bool> commitPanelAccount() async => false;
}

void main() {
  tearDown(() {
    for (final id in FloatingDialogs.openIds) {
      closeFloatingDialog(id);
    }
  });

  /// Pumps a panel, hands back a context that can open both kinds of window.
  Future<({BuildContext context, WidgetRef ref})> pumpPanel(
      WidgetTester tester) async {
    late BuildContext ctx;
    late WidgetRef widgetRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accessSessionProvider.overrideWith(_AnonymousSession.new),
        firstUserWindowOpenProvider.overrideWith((ref) async => false),
      ],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          // Watched from the first frame, as BaseScaffold does.
          ref.watch(accessSessionProvider);
          ctx = context;
          widgetRef = ref;
          return const Scaffold(body: SizedBox.expand());
        }),
      ),
    ));
    await tester.pumpAndSettle();
    return (context: ctx, ref: widgetRef);
  }

  testWidgets(
      'a tap meant for a floating window does not reach it while '
      'sign-in is open', (tester) async {
    final host = await pumpPanel(tester);

    var tapsOnTheWindowBehind = 0;
    unawaited(showFloatingDialog<void>(
      context: host.context,
      id: 'trend:cn01',
      title: 'Trend',
      builder: (_) => Center(
        child: ElevatedButton(
          onPressed: () => tapsOnTheWindowBehind++,
          child: const Text('behind'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('behind'), findsOneWidget,
        reason: 'the floating window must be up before sign-in opens, or the '
            'test proves nothing about ordering');

    unawaited(showAccessSignInDialog(host.context, host.ref));
    await tester.pumpAndSettle();

    expect(find.byType(AccessSignInDialog), findsOneWidget,
        reason: 'sign-in was asked for; it must be in the tree');

    // The tap the operator would make next, aimed where the window behind is.
    await tester.tap(find.text('behind'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(tapsOnTheWindowBehind, 0,
        reason: 'the floating window took a tap while the sign-in form was '
            'open, so the form is underneath it — which is the defect');
  });

  testWidgets('the floating windows are still open afterwards', (tester) async {
    final host = await pumpPanel(tester);

    unawaited(showFloatingDialog<void>(
      context: host.context,
      id: 'trend:cn01',
      title: 'Trend',
      builder: (_) => const Text('behind'),
    ));
    await tester.pumpAndSettle();

    unawaited(showAccessSignInDialog(host.context, host.ref));
    await tester.pumpAndSettle();

    expect(FloatingDialogs.openIds, contains('trend:cn01'),
        reason: 'putting sign-in on top by closing the operator\'s windows '
            'would pass the first test and lose their arranged trends');
  });

  testWidgets(
      'sign-in opened first still stays on top when a floating window '
      'opens behind it', (tester) async {
    final host = await pumpPanel(tester);

    unawaited(showAccessSignInDialog(host.context, host.ref));
    await tester.pumpAndSettle();

    var tapsOnTheWindowBehind = 0;
    unawaited(showFloatingDialog<void>(
      context: host.context,
      id: 'trend:cn02',
      title: 'Trend',
      builder: (_) => Center(
        child: ElevatedButton(
          onPressed: () => tapsOnTheWindowBehind++,
          child: const Text('behind'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('behind'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(tapsOnTheWindowBehind, 0,
        reason: 'a window opened while sign-in is up must not come out in '
            'front of it either');
  });
}
