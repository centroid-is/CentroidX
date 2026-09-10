/// Contract for the value a floating dialog hands back.
///
/// `showFloatingDialog` used to be fire-and-forget, which is fine for a trend
/// but not for a picker: the browse dialog is awaited by the form field it
/// fills in. Making it `Future<T?>` means the completer has to be answered on
/// EVERY way the window can go, not just the tidy one — the header's close
/// button, Escape, navigation's `closeAll`, and the overlay being torn down
/// underneath it. A path that forgets to complete does not throw; it leaves
/// the caller's `await` hanging for the rest of the session, which is why
/// each one gets a test here rather than a shared happy-path check.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        }),
      ),
    ));
    return ctx;
  }

  tearDown(() {
    for (final id in FloatingDialogs.openIds) {
      closeFloatingDialog(id);
    }
  });

  testWidgets('completes with the result handed to closeFloatingDialog',
      (t) async {
    final ctx = await pumpHost(t);
    final future = showFloatingDialog<String>(
      context: ctx,
      id: 'picker',
      title: 'Pick',
      builder: (_) => const Text('body'),
    );
    await t.pumpAndSettle();

    closeFloatingDialog('picker', result: 'chosen');
    await t.pumpAndSettle();

    expect(await future, 'chosen');
  });

  testWidgets('completes null when closed without a result', (t) async {
    final ctx = await pumpHost(t);
    final future = showFloatingDialog<String>(
      context: ctx,
      id: 'picker',
      title: 'Pick',
      builder: (_) => const Text('body'),
    );
    await t.pumpAndSettle();

    // What the header's close button does.
    closeFloatingDialog('picker');
    await t.pumpAndSettle();

    expect(await future, isNull);
  });

  testWidgets('the header close button completes the future', (t) async {
    final ctx = await pumpHost(t);
    final future = showFloatingDialog<String>(
      context: ctx,
      id: 'picker',
      title: 'Pick',
      builder: (_) => const Text('body'),
    );
    await t.pumpAndSettle();

    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();

    expect(await future, isNull);
    expect(FloatingDialogs.isEmpty, isTrue);
  });

  testWidgets('closeAll on navigation completes every open future', (t) async {
    final ctx = await pumpHost(t);
    final a = showFloatingDialog<String>(
      context: ctx,
      id: 'a',
      title: 'A',
      builder: (_) => const Text('a'),
    );
    final b = showFloatingDialog<String>(
      context: ctx,
      id: 'b',
      title: 'B',
      builder: (_) => const Text('b'),
    );
    await t.pumpAndSettle();

    closeAllFloatingDialogs();
    await t.pumpAndSettle();

    expect(await a, isNull);
    expect(await b, isNull);
  });

  testWidgets('an overlay torn down underneath it still completes', (t) async {
    // The `_forget` path. It reads like bookkeeping — nobody called close, the
    // overlay simply went away — but an awaiting caller is still parked on the
    // future, and this is the one route to it that has no explicit close.
    final ctx = await pumpHost(t);
    final future = showFloatingDialog<String>(
      context: ctx,
      id: 'picker',
      title: 'Pick',
      builder: (_) => const Text('body'),
    );
    await t.pumpAndSettle();

    // Watched rather than awaited: the failure this guards against is a future
    // that NEVER completes, and awaiting it directly turns a regression into a
    // ten-minute CI hang instead of a failed expectation.
    var completed = false;
    Object? result = #unset;
    unawaited(future.then((value) {
      completed = true;
      result = value;
    }));

    // Replacing one MaterialApp with another would reuse the element, and with
    // it the Navigator and root overlay — the dialog would still be mounted
    // and this would test nothing. Swap the root for a different widget type
    // so the overlay is genuinely destroyed.
    await t.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.expand(),
    ));
    await t.pumpAndSettle();

    expect(completed, isTrue,
        reason: 'a dialog whose overlay disappeared must not leave its '
            'opener awaiting forever');
    expect(result, isNull);
    expect(FloatingDialogs.isEmpty, isTrue);
  });

  testWidgets('re-opening an id already showing completes null immediately',
      (t) async {
    final ctx = await pumpHost(t);
    final first = showFloatingDialog<String>(
      context: ctx,
      id: 'picker',
      title: 'First',
      builder: (_) => const Text('first'),
    );
    await t.pumpAndSettle();

    final second = showFloatingDialog<String>(
      context: ctx,
      id: 'picker',
      title: 'Second',
      builder: (_) => const Text('second'),
    );
    await t.pumpAndSettle();

    expect(await second, isNull,
        reason: 'the window on screen answers to whoever opened it; a second '
            'requester must not be parked on a future that would resolve '
            'with somebody else\'s pick');
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);

    closeFloatingDialog('picker', result: 'mine');
    await t.pumpAndSettle();
    expect(await first, 'mine');
  });

  group('actionsListenable', () {
    testWidgets('re-enables an action without rebuilding the body', (t) async {
      // The reason this exists instead of a setState: the body is built once
      // and captured. Rebuilding the dialog to re-enable a button would take
      // the content's State with it — for the browse dialog that is the
      // loaded tree and, on UMAS, a re-walked symbol cache on every tap.
      var bodyBuilds = 0;
      final actions = ValueNotifier<List<PaneAction>>(
        const [PaneAction.primary(label: 'Select')],
      );
      addTearDown(actions.dispose);

      final ctx = await pumpHost(t);
      showFloatingDialog<String>(
        context: ctx,
        id: 'picker',
        title: 'Pick',
        actionsListenable: actions,
        builder: (_) {
          bodyBuilds++;
          return const Text('body');
        },
      );
      await t.pumpAndSettle();

      expect(bodyBuilds, 1);
      expect(
        t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Select')).onPressed,
        isNull,
      );

      actions.value = [
        PaneAction.primary(label: 'Select', onPressed: () {}),
      ];
      await t.pumpAndSettle();

      expect(
        t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Select')).onPressed,
        isNotNull,
      );
      expect(bodyBuilds, 1,
          reason: 'only the action bar may rebuild when the actions change');
    });

    testWidgets('an empty list hides the bar', (t) async {
      final actions = ValueNotifier<List<PaneAction>>(const []);
      addTearDown(actions.dispose);

      final ctx = await pumpHost(t);
      showFloatingDialog<String>(
        context: ctx,
        id: 'picker',
        title: 'Pick',
        actionsListenable: actions,
        builder: (_) => const Text('body'),
      );
      await t.pumpAndSettle();

      expect(find.byType(PaneActionBar), findsNothing);

      actions.value = const [PaneAction(label: 'Later')];
      await t.pumpAndSettle();

      expect(find.byType(PaneActionBar), findsOneWidget);
    });
  });
}
