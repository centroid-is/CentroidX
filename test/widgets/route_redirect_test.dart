/// RouteRedirect — the widget behind refused navigation: a deleted Home's
/// `/`, or an unpublished page's path. It must actually land the router on
/// its target, replacing the refused location in history — and it must do so
/// **every** time it is shown, not only the first.
///
/// The second half is the plant-floor fault this file now pins. Beamer stacks
/// every sub-matching route, so the `/` stub stays mounted under every page on
/// a station whose Home page was deleted. Beaming back to `/` reveals that
/// same `State`, `initState` does not run again, and the one-shot version left
/// the panel on an empty `Scaffold`: white, no app bar, no navigation bar.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/route_redirect.dart';

/// A router shaped like the app's: `/` is the redirect stub (the Home page was
/// deleted) and sub-matches everything, so it is mounted beneath every page.
BeamerDelegate _delegate({String initialPath = '/'}) => BeamerDelegate(
      initialPath: initialPath,
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              child: RouteRedirect(from: '/', target: '/real'),
            ),
        '/real': (context, state, data) => const BeamPage(
              key: ValueKey('/real'),
              child: Scaffold(body: Text('the real page')),
            ),
        '/other': (context, state, data) => const BeamPage(
              key: ValueKey('/other'),
              child: Scaffold(body: Text('another page')),
            ),
      }).call,
    );

Future<void> _pump(WidgetTester tester, BeamerDelegate delegate) async {
  await tester.pumpWidget(MaterialApp.router(
    routerDelegate: delegate,
    routeInformationParser: BeamerParser(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('navigating to a redirect route lands on its target',
      (tester) async {
    final delegate = BeamerDelegate(
      initialPath: '/refused',
      locationBuilder: RoutesLocationBuilder(routes: {
        '/refused': (context, state, data) => const BeamPage(
              key: ValueKey('/refused'),
              child: RouteRedirect(from: '/refused', target: '/real'),
            ),
        '/real': (context, state, data) => const BeamPage(
              key: ValueKey('/real'),
              child: Scaffold(body: Text('the real page')),
            ),
      }).call,
    );

    await _pump(tester, delegate);

    expect(find.text('the real page'), findsOneWidget);
    expect(delegate.configuration.uri.path, '/real');
  });

  testWidgets('coming back to the stub redirects again — it is not one-shot',
      (tester) async {
    final delegate = _delegate();
    await _pump(tester, delegate);
    expect(delegate.configuration.uri.path, '/real');

    // The sign-out return: BaseScaffold beams to the resolved startup path,
    // which is '/' on a station with nothing stored. Before the re-arm this
    // left the app on an empty Scaffold for good.
    delegate.beamToNamed('/');
    await tester.pumpAndSettle();

    expect(delegate.configuration.uri.path, '/real');
    expect(find.text('the real page'), findsOneWidget);
  });

  testWidgets('the buried stub does not drag the operator off another page',
      (tester) async {
    final delegate = _delegate();
    await _pump(tester, delegate);

    delegate.beamToNamed('/other');
    await tester.pumpAndSettle();

    // '/' sub-matches '/other', so the stub is mounted underneath it and is
    // rebuilt with it. It must stay put.
    expect(delegate.configuration.uri.path, '/other');
    expect(find.text('another page'), findsOneWidget);
  });

  testWidgets('the stub is never a blank page', (tester) async {
    // Pumped without a router that can carry the beam anywhere, so the page
    // stays on screen and can be read: this is the state an operator meets if
    // a redirect is ever wedged again.
    await tester.pumpWidget(const MaterialApp(
      home: RouteRedirect(from: '/', target: '/real'),
    ));
    await tester.pump();

    expect(find.byKey(kRouteRedirectBodyKey), findsOneWidget);
    expect(find.text(kRouteRedirectNote('/real')), findsOneWidget);
    expect(find.byKey(kRouteRedirectGoKey), findsOneWidget);
  });
}
