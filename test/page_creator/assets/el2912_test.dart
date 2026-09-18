import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/el2912.dart';
import 'package:tfc/painter/beckhoff/io8.dart'
    show IO8Widget, IOState, twinSafeBodyColor;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// The EL2912 is the terminal this repo can say the least about, and these
/// tests are mostly about keeping it that way.
///
/// Its two fail-safe outputs are driven over FSoE by the TwinSAFE Logic
/// inside the terminal; the standard PLC never sees them. What the EtherCAT
/// GVL does link out is two loose BOOLs off `Module 3 (DEVICEIO)` —
/// `Fieldvoltage Underrange` and `Fieldvoltage Overrange` — and that is the
/// whole of what an operator can be told here.
///
/// So the tests below pin two things: that the field voltage is read
/// correctly, and that nothing else on the face pretends to know anything.

const _underKey = 'ST301.ECT.ST301_A1_09_Fieldvoltage_Underrange';
const _overKey = 'ST301.ECT.ST301_A1_09_Fieldvoltage_Overrange';
const _descriptionKey = 'ST301.ECT.ST301_A1_09.Description';

void main() {
  group('El2912Status', () {
    test('neither bit set is in range', () {
      const status = El2912Status(underrange: false, overrange: false);

      expect(status.fieldVoltage, El2912FieldVoltage.inRange);
      expect(status.outOfRange, isFalse);
      expect(status.isUnknown, isFalse);
    });

    test('underrange and overrange each take the state out of range', () {
      expect(
        const El2912Status(underrange: true, overrange: false).fieldVoltage,
        El2912FieldVoltage.underrange,
      );
      expect(
        const El2912Status(underrange: false, overrange: true).fieldVoltage,
        El2912FieldVoltage.overrange,
      );
    });

    test('overrange wins when the terminal somehow reports both', () {
      // Not a state the hardware should reach, but a decode that silently
      // preferred one bit without saying so would be a decode nobody could
      // predict. Over is the more damaging of the two, so it leads.
      const status = El2912Status(underrange: true, overrange: true);

      expect(status.fieldVoltage, El2912FieldVoltage.overrange);
      expect(status.outOfRange, isTrue);
    });

    test('unpublished bits stay unknown rather than collapsing to healthy',
        () {
      // The failure this guards: a terminal whose keys were never configured
      // reading as "field voltage fine", which is the most reassuring thing
      // the asset can say and the one it has no basis for.
      const status = El2912Status.unknown();

      expect(status.isUnknown, isTrue);
      expect(status.fieldVoltage, El2912FieldVoltage.unknown);
      expect(status.outOfRange, isFalse);
    });

    test('one bit published is enough to leave the unknown state', () {
      const status = El2912Status(underrange: false, overrange: null);

      expect(status.isUnknown, isFalse);
      expect(status.fieldVoltage, El2912FieldVoltage.inRange);
    });
  });

  group('el2912FaceLeds', () {
    test('in range lights the top lamp and nothing else', () {
      final leds = el2912FaceLeds(
        const El2912Status(underrange: false, overrange: false),
      );

      expect(leds, hasLength(6));
      expect(leds.first, IOState.high);
      expect(leds.sublist(1), everyElement(IOState.low));
    });

    test('out of range lights the bottom lamp red and drops the top one', () {
      final leds = el2912FaceLeds(
        const El2912Status(underrange: true, overrange: false),
      );

      expect(leds.first, IOState.low);
      expect(leds.last, IOState.error);
    });

    test('the four output lamps are never lit', () {
      // They are the terminal's own Output/Error LEDs and nothing publishes
      // them. If a future change starts driving them it has to come through
      // here and say what it is driving them from.
      for (final status in [
        const El2912Status(underrange: false, overrange: false),
        const El2912Status(underrange: true, overrange: false),
        const El2912Status(underrange: false, overrange: true),
        const El2912Status.unknown(),
      ]) {
        expect(
          el2912FaceLeds(status).sublist(1, 5),
          everyElement(IOState.low),
          reason: 'field voltage ${status.fieldVoltage} lit an output lamp',
        );
      }
    });
  });

  group('BeckhoffEL2912Config', () {
    test('round-trips through JSON with both diagnostic keys', () {
      final config = BeckhoffEL2912Config(
        nameOrId: 'ST301.A1.09',
        underrangeKey: _underKey,
        overrangeKey: _overKey,
        descriptionKey: _descriptionKey,
      );

      final restored = BeckhoffEL2912Config.fromJson(config.toJson());

      expect(restored.nameOrId, 'ST301.A1.09');
      expect(restored.underrangeKey, _underKey);
      expect(restored.overrangeKey, _overKey);
      expect(restored.descriptionKey, _descriptionKey);
    });

    test('allKeys carries both bits so resubscribe covers them', () {
      final config = BeckhoffEL2912Config(
        nameOrId: '1',
        underrangeKey: _underKey,
        overrangeKey: _overKey,
      );

      expect(config.allKeys, containsAll([_underKey, _overKey]));
    });
  });

  group('the face, live', () {
    Future<IO8Widget> pump(
      WidgetTester tester, {
      required Map<String, bool> bits,
      String? underrangeKey = _underKey,
      String? overrangeKey = _overKey,
    }) async {
      final config = BeckhoffEL2912Config(
        nameOrId: 'ST301.A1.09',
        underrangeKey: underrangeKey,
        overrangeKey: overrangeKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _El2912StateMan(bits)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 400,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      return tester.widget<IO8Widget>(find.byType(IO8Widget));
    }

    testWidgets('wears the TwinSAFE yellow, not the cream of a standard '
        'terminal', (tester) async {
      final face = await pump(tester, bits: {_underKey: false, _overKey: false});

      expect(face.housingColor, twinSafeBodyColor);
    });

    testWidgets('a healthy field voltage lights the top lamp', (tester) async {
      final face = await pump(tester, bits: {_underKey: false, _overKey: false});

      expect(face.ledStates.first, IOState.high);
      expect(face.disconnected, isFalse);
    });

    testWidgets('an underrange field voltage shows red', (tester) async {
      final face = await pump(tester, bits: {_underKey: true, _overKey: false});

      expect(face.ledStates.last, IOState.error);
    });

    testWidgets('no keys configured marks the terminal as saying nothing',
        (tester) async {
      // The "!" rather than six dark lamps: dark is also what a healthy
      // terminal looks like, so an unconfigured one must not read as healthy.
      final face = await pump(
        tester,
        bits: const {},
        underrangeKey: null,
        overrangeKey: null,
      );

      expect(face.disconnected, isTrue);
      expect(face.ledStates, everyElement(IOState.low));
    });

    testWidgets('a configured key that never publishes also reads as silent',
        (tester) async {
      final face = await pump(tester, bits: const {});

      expect(face.disconnected, isTrue);
    });
  });

  group('the pane', () {
    Future<void> open(WidgetTester tester, Map<String, bool> bits) async {
      final config = BeckhoffEL2912Config(
        nameOrId: 'ST301.A1.09',
        underrangeKey: _underKey,
        overrangeKey: _overKey,
        descriptionKey: _descriptionKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith(
            (ref) async => _El2912StateMan(
              bits,
              description: 'Guard circuit, packing hall',
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 400,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();
    }

    tearDown(closeSidePane);

    testWidgets('opens on a tap and names the circuit rather than the key',
        (tester) async {
      await open(tester, {_underKey: false, _overKey: false});

      expect(find.text('ST301.A1.09'), findsOneWidget);
      expect(find.text('Guard circuit, packing hall'), findsOneWidget);
      // No raw OPC UA key anywhere on the operator surface.
      expect(find.textContaining('Fieldvoltage'), findsNothing);
    });

    testWidgets('says out loud that the safety outputs are not visible here',
        (tester) async {
      // The pane's job when it cannot answer is to say so. Somebody looking
      // for "is output 1 on" must be sent to the TwinSAFE project, not left
      // reading an unlit lamp as an answer.
      await open(tester, {_underKey: false, _overKey: false});

      expect(find.textContaining('TwinSAFE Logic'), findsOneWidget);
    });

    testWidgets('a field voltage fault opens its explanation unprompted',
        (tester) async {
      await open(tester, {_underKey: true, _overKey: false});

      expect(find.text('Field V low'), findsWidgets);
      expect(find.textContaining('tripped breaker upstream'), findsOneWidget);
    });
  });
}

/// Serves the EL2912's two field-voltage bits, and nothing else — which is
/// all the PLC serves for one.
class _El2912StateMan extends Fake implements StateMan {
  _El2912StateMan(this.bits, {this.description});

  /// Keyed by OPC UA key. A key absent here never publishes.
  final Map<String, bool> bits;

  final String? description;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (bits.containsKey(key)) {
      return Stream<DynamicValue>.value(DynamicValue(value: bits[key]));
    }
    if (key == _descriptionKey && description != null) {
      return Stream<DynamicValue>.value(DynamicValue(value: description));
    }
    return const Stream<DynamicValue>.empty();
  }
}
