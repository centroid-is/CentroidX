// What an operator actually sees while the link is down.
//
// `test/providers/visible_staleness_test.dart` pins the transport half against
// a real socket: a link that goes quiet must stop the panel presenting values
// it cannot vouch for. This file pins the other half — that the withheld value
// arrives at a *rendered asset* as the vocabulary an operator has already been
// taught to read, rather than as a blank, a zero, or an exception dialog.
//
// **The vocabulary is not invented here.** `number.dart` already renders `---`
// when it has no value, `led.dart` already paints `!` on a lamp with no state,
// and the rig photographed both in the `notBuilt` frame and recorded them as
// correct and legible across a room (15-RIG-ATTENDED-20260907, state 4). The
// change under test routes a stale link onto that same rendering; it adds no
// colour, so no `HmiStateColors` member is read here and no golden frame can
// move because of it.
//
// **Why the assets and not a bespoke widget.** Twenty-odd asset widgets render
// values and every one of them reads `keyStreamProvider`. Asserting on two of
// them — one text readout, one lamp, chosen because they show a value in the
// two different ways the library has — is asserting on the funnel they share.

@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart' show BehaviorSubject;
import 'package:tfc/core/value_freshness.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/number.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/providers/value_freshness.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// A StateMan that holds one value per key and replays it to whoever listens.
///
/// Seeded rather than pushed: the provider awaits `subscribe` before it
/// listens, so a value pushed in between would be dropped by a plain broadcast
/// stream and the arm would measure its own harness racing itself.
class _ValueStateMan extends Fake implements StateMan {
  _ValueStateMan(this.value);

  final Object? value;
  final Map<String, BehaviorSubject<DynamicValue>> subjects = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      subjects
          .putIfAbsent(
              key,
              () => BehaviorSubject<DynamicValue>.seeded(
                  DynamicValue(value: value)))
          .stream;
}

Widget _host({
  required StateMan stateMan,
  required ValueFreshness freshness,
  required Widget child,
}) =>
    ProviderScope(
      overrides: [
        stateManProvider.overrideWith((ref) async => stateMan),
        valueFreshnessProvider.overrideWithValue(freshness),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 240, height: 90, child: child),
          ),
        ),
      ),
    );

/// The lamp's colour, or null when it has no state and paints its `!`.
Color? _lampColour(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(find.descendant(
    of: find.byType(LedRaw),
    matching: find.byType(CustomPaint),
  ));
  return (paint.painter! as LEDPainter).color;
}

void main() {
  final config = NumberConfig(key: 'CN01.Temp', units: '°C', decimalPlaces: 1);

  group('a readout', () {
    testWidgets('shows its figure while the panel can vouch for it',
        (tester) async {
      // The live control. Every stale assertion below is worthless without it:
      // "the readout shows ---" is also true of a readout that never showed
      // anything.
      final freshness = ValueFreshness.fresh();
      addTearDown(freshness.dispose);

      await tester.pumpWidget(_host(
        stateMan: _ValueStateMan(4.2),
        freshness: freshness,
        child: NumberWidget(config: config),
      ));
      await tester.pumpAndSettle();

      expect(find.text('4.2 °C'), findsOneWidget);
    });

    testWidgets('shows --- while the link is down', (tester) async {
      // THE RIG DEFECT, at the pixel it was photographed at: at +65 s after a
      // hard cut the home page still read `0.0 °C`.
      final freshness = ValueFreshness.watching(
        stale: true,
        transitions: const Stream<bool>.empty(),
      );
      addTearDown(freshness.dispose);

      await tester.pumpWidget(_host(
        stateMan: _ValueStateMan(4.2),
        freshness: freshness,
        child: NumberWidget(config: config),
      ));
      await tester.pumpAndSettle();

      expect(find.text('--- °C'), findsOneWidget,
          reason: 'the panel has not heard from the gateway, and is still '
              'showing the figure it received before the link went down as '
              'though it were current');
      expect(find.text('4.2 °C'), findsNothing);
    });
  });

  group('a lamp', () {
    testWidgets('is lit while the panel can vouch for it', (tester) async {
      final freshness = ValueFreshness.fresh();
      addTearDown(freshness.dispose);

      await tester.pumpWidget(_host(
        stateMan: _ValueStateMan(true),
        freshness: freshness,
        child: Led(LEDConfig(key: 'CN01.Running')),
      ));
      await tester.pumpAndSettle();

      expect(_lampColour(tester), isNotNull);
    });

    testWidgets('loses its state, and paints its !, while the link is down',
        (tester) async {
      final freshness = ValueFreshness.watching(
        stale: true,
        transitions: const Stream<bool>.empty(),
      );
      addTearDown(freshness.dispose);

      await tester.pumpWidget(_host(
        stateMan: _ValueStateMan(true),
        freshness: freshness,
        child: Led(LEDConfig(key: 'CN01.Running')),
      ));
      await tester.pumpAndSettle();

      expect(_lampColour(tester), isNull,
          reason: 'a lamp painted green over a dead link tells an operator the '
              'motor is running; LEDPainter paints ! for exactly this case');
    });
  });

  group('the rig sequence, in a widget', () {
    testWidgets('a readout goes uncertain when the link drops and definite '
        'again when it returns', (tester) async {
      // Both directions, on one mounted asset that is never rebuilt from
      // scratch — which is the thing a panel does and a fresh pump does not.
      final transitions = StreamController<bool>.broadcast();
      addTearDown(transitions.close);
      final freshness = ValueFreshness.watching(
        stale: false,
        transitions: transitions.stream,
      );
      addTearDown(freshness.dispose);

      await tester.pumpWidget(_host(
        stateMan: _ValueStateMan(4.2),
        freshness: freshness,
        child: NumberWidget(config: config),
      ));
      await tester.pumpAndSettle();
      expect(find.text('4.2 °C'), findsOneWidget);

      transitions.add(true);
      await tester.pumpAndSettle();

      expect(find.text('--- °C'), findsOneWidget,
          reason: 'the link went quiet under a mounted asset and the figure '
              'did not move');

      transitions.add(false);
      await tester.pumpAndSettle();

      expect(find.text('4.2 °C'), findsOneWidget,
          reason: 'a panel that greys out and stays grey through a recovered '
              'link is a panel whose grey nobody reads');
    });
  });
}
