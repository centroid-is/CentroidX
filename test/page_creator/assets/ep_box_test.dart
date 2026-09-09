import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/ep_box.dart';
import 'package:tfc/painter/beckhoff/ep_box.dart'
    show EPBoxWidget, epBoxBodyColor, epBoxSocketCount;
import 'package:tfc/painter/beckhoff/io8.dart'
    show IOState, twinSafeBodyColor;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// One asset, two boxes, and the difference that matters is not the label.
///
/// An EP2338 publishes an `ST_EP2338_0002` and its eight channels can be lit
/// from it. An EP1918 is TwinSAFE and publishes nothing at all — its safe
/// inputs are consumed by TwinSAFE logic and no station's EtherCAT GVL so
/// much as names one.
///
/// The other thing pinned here is the plug arithmetic: an M12 carries two
/// channels, A on pin 4 and B on pin 2, so eight channels live on four
/// plugs. A pane that numbered them 'Socket 1' to 'Socket 8' would send an
/// electrician looking for four plugs that are not on the box.
///
/// So these tests are largely about the EP1918 not borrowing the EP2338's
/// confidence: no state key offered, no "!" claiming a healthy box is
/// broken, and a pane that says why it is empty instead of showing eight
/// lamps that mean nothing.

const _stateKey = 'ST301.ECT.ST301_RM05';
const _descriptionsKey = 'ST301.ECT.ST301_RM05.Sockets';

/// Builds an `ST_EP2338_0002` — `I0..I7` and `O0..O7`, all present unless
/// named in [absent].
DynamicValue _struct({
  Set<int> inputsHigh = const {},
  Set<int> outputsHigh = const {},
  Set<String> absent = const {},
}) {
  final dv = DynamicValue();
  for (int i = 0; i < 8; i++) {
    if (!absent.contains('I$i')) dv['I$i'] = inputsHigh.contains(i);
    if (!absent.contains('O$i')) dv['O$i'] = outputsHigh.contains(i);
  }
  return dv;
}

void main() {
  group('EPBoxVariant', () {
    test('only the EP2338 has anything to subscribe to', () {
      expect(EPBoxVariant.ep2338.isLive, isTrue);
      expect(EPBoxVariant.ep1918.isLive, isFalse);
    });

    test('the TwinSAFE box is yellow and the combi box is anthracite', () {
      expect(EPBoxVariant.ep1918.housingColor, twinSafeBodyColor);
      // Not the EL terminals' light grey: an EtherCAT Box is a die-cast IP67
      // part and wears its own colour, so a page carrying both does not read
      // as one family of hardware.
      expect(EPBoxVariant.ep2338.housingColor, epBoxBodyColor);
    });
  });

  group('EpBoxChannel.read', () {
    test('channel n reads I(n-1) and O(n-1)', () {
      // The struct indexes from zero and the channels are numbered from one;
      // an off-by-one here would light the wrong lamp on the mimic, which is
      // exactly the sort of wrong an operator trusts.
      final dv = _struct(inputsHigh: {0}, outputsHigh: {7});

      expect(EpBoxChannel.read(dv, 1).input, isTrue);
      expect(EpBoxChannel.read(dv, 2).input, isFalse);
      expect(EpBoxChannel.read(dv, 8).output, isTrue);
      expect(EpBoxChannel.read(dv, 7).output, isFalse);
    });

    test('a missing member stays null rather than collapsing to false', () {
      final channel = EpBoxChannel.read(_struct(absent: {'O0'}), 1);

      expect(channel.output, isNull);
      expect(channel.input, isFalse);
      expect(channel.isUnknown, isFalse);
    });

    test('a null struct leaves the channel unknown', () {
      final channel = EpBoxChannel.read(null, 1);

      expect(channel.isUnknown, isTrue);
      expect(channel.active, isFalse);
    });

    test('a channel is active whichever way it is wired', () {
      expect(EpBoxChannel.read(_struct(inputsHigh: {2}), 3).active, isTrue);
      expect(EpBoxChannel.read(_struct(outputsHigh: {2}), 3).active, isTrue);
      expect(EpBoxChannel.read(_struct(), 3).active, isFalse);
    });
  });

  group('epBoxChannelLabel', () {
    test('names the eight points the way the PLC struct does', () {
      // `ST_EP2338_0002` numbers its members from zero, so channel 1 is I0.
      // This page is read beside a variable list, not beside the box, and
      // the caption has to be a string that can be found in that list.
      expect(epBoxChannelLabel(1), 'I0');
      expect(epBoxChannelLabel(2), 'I1');
      expect(epBoxChannelLabel(3), 'I2');
      expect(epBoxChannelLabel(8), 'I7');
    });

    test('never names a member the struct does not carry', () {
      for (int channel = 1; channel <= 8; channel++) {
        final label = epBoxChannelLabel(channel);
        expect(label, matches(RegExp(r'^I[0-7]$')));
      }
    });
  });

  group('epBoxFaceLeds', () {
    test('lights one lamp per active channel, in channel order', () {
      final leds = epBoxFaceLeds(
        epBoxChannelsOf(_struct(inputsHigh: {0}, outputsHigh: {4})),
      );

      expect(leds, hasLength(8));
      expect(leds[0], IOState.high);
      expect(leds[4], IOState.high);
      expect(
        [leds[1], leds[2], leds[3], leds[5], leds[6], leds[7]],
        everyElement(IOState.low),
      );
    });
  });

  group('epBoxPaneStatus', () {
    test('an EP1918 says it has no process data, not that it is broken', () {
      expect(
        epBoxPaneStatus(EPBoxVariant.ep1918, epBoxUnknownChannels()).label,
        'No process data',
      );
    });

    test('an EP2338 counts what is on', () {
      expect(
        epBoxPaneStatus(
          EPBoxVariant.ep2338,
          epBoxChannelsOf(_struct(inputsHigh: {0, 3})),
        ).label,
        '2 of 8 on',
      );
    });

    test('an EP2338 with nothing arriving is distinct from one all quiet', () {
      expect(
        epBoxPaneStatus(EPBoxVariant.ep2338, epBoxUnknownChannels()).label,
        'No data',
      );
      expect(
        epBoxPaneStatus(EPBoxVariant.ep2338, epBoxChannelsOf(_struct())).label,
        'All quiet',
      );
    });
  });

  group('BeckhoffEPBoxConfig', () {
    test('round-trips the variant through JSON', () {
      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep1918,
        nameOrId: 'ST301.EM01',
      );

      final restored = BeckhoffEPBoxConfig.fromJson(config.toJson());

      expect(restored.variantModel, EPBoxVariant.ep1918);
      expect(restored.nameOrId, 'ST301.EM01');
    });

    test('the display name follows the picked variant', () {
      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep2338,
        nameOrId: 'RM05',
      );

      expect(config.displayName, 'Beckhoff EP2338');
      config.variantModel = EPBoxVariant.ep1918;
      expect(config.displayName, 'Beckhoff EP1918');
    });

    test('allKeys carries the state key so resubscribe covers it', () {
      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep2338,
        nameOrId: 'RM05',
        stateKey: _stateKey,
      );

      expect(config.allKeys, contains(_stateKey));
    });
  });

  group('the face, live', () {
    Future<EPBoxWidget> pump(
      WidgetTester tester, {
      required EPBoxVariant variant,
      DynamicValue? struct,
      String? stateKey = _stateKey,
    }) async {
      final config = BeckhoffEPBoxConfig(
        variantModel: variant,
        nameOrId: 'RM05',
        stateKey: stateKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _EpBoxStateMan(struct)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 460,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      return tester.widget<EPBoxWidget>(find.byType(EPBoxWidget));
    }

    testWidgets('an EP2338 lights the channels its struct says are on',
        (tester) async {
      final face = await pump(
        tester,
        variant: EPBoxVariant.ep2338,
        struct: _struct(inputsHigh: {0}, outputsHigh: {4}),
      );

      expect(face.model, 'EP2338');
      expect(face.channels[0], IOState.high);
      expect(face.channels[4], IOState.high);
      expect(face.disconnected, isFalse);
    });

    testWidgets('an EP2338 that should be talking and is not gets the mark',
        (tester) async {
      final face = await pump(tester, variant: EPBoxVariant.ep2338);

      expect(face.disconnected, isTrue);
    });

    testWidgets('an EP1918 is never marked disconnected', (tester) async {
      // It has nothing to say by design. Marking it broken would send
      // somebody to look at a healthy box.
      final face = await pump(
        tester,
        variant: EPBoxVariant.ep1918,
        stateKey: null,
      );

      expect(face.model, 'EP1918');
      expect(face.disconnected, isFalse);
      expect(face.housingColor, twinSafeBodyColor);
      expect(face.channels, everyElement(IOState.low));
    });
  });

  group('the configure form', () {
    Future<void> pumpForm(WidgetTester tester, BeckhoffEPBoxConfig config) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => config.configure(context)),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('offers a state key for the EP2338', (tester) async {
      await pumpForm(
        tester,
        BeckhoffEPBoxConfig(
          variantModel: EPBoxVariant.ep2338,
          nameOrId: 'RM05',
        ),
      );

      expect(find.text('State Key'), findsOneWidget);
    });

    testWidgets('hides the state key on an EP1918 and says why',
        (tester) async {
      // A field that silently does nothing is worse than no field: somebody
      // fills it in, sees no lamps, and goes looking for a broken link.
      await pumpForm(
        tester,
        BeckhoffEPBoxConfig(
          variantModel: EPBoxVariant.ep1918,
          nameOrId: 'EM01',
        ),
      );

      expect(find.text('State Key'), findsNothing);
      expect(find.textContaining('no process data'), findsOneWidget);
    });

    testWidgets('switching the picker to EP1918 takes the key field away',
        (tester) async {
      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep2338,
        nameOrId: 'RM05',
      );
      await pumpForm(tester, config);

      await tester.tap(find.byKey(const ValueKey('ep-box-variant')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('EP1918').last);
      await tester.pumpAndSettle();

      expect(config.variantModel, EPBoxVariant.ep1918);
      expect(find.text('State Key'), findsNothing);
    });
  });

  group('the pane', () {
    Future<void> open(
      WidgetTester tester, {
      required EPBoxVariant variant,
      DynamicValue? struct,
      List<String> descriptions = const [],
    }) async {
      final config = BeckhoffEPBoxConfig(
        variantModel: variant,
        nameOrId: 'ST301.RM05',
        stateKey: variant.isLive ? _stateKey : null,
        descriptionsKey: descriptions.isEmpty ? null : _descriptionsKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith(
            (ref) async => _EpBoxStateMan(struct, descriptions: descriptions),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 460,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(EPBoxWidget));
      await tester.pumpAndSettle();
    }

    tearDown(closeSidePane);

    testWidgets('names channels rather than numbering them, when the page '
        'says', (tester) async {
      await open(
        tester,
        variant: EPBoxVariant.ep2338,
        struct: _struct(inputsHigh: {0}),
        descriptions: const ['Erector jam photocell', 'Erector ready'],
      );

      expect(find.text('Erector jam photocell'), findsOneWidget);
      expect(find.text('Erector ready'), findsOneWidget);
      // Every point keeps its PLC name in the gutter, named or not — the
      // description is a second column beside it, not a replacement for it.
      expect(find.text('I0'), findsOneWidget);
      expect(find.text('I2'), findsOneWidget);
      expect(find.text('I7'), findsOneWidget);
      expect(find.textContaining('Socket'), findsNothing);
      expect(find.textContaining('Plug 1 A'), findsNothing);
    });

    testWidgets('an EP1918 pane explains itself instead of showing lamps',
        (tester) async {
      await open(tester, variant: EPBoxVariant.ep1918);

      expect(find.textContaining('TwinSAFE logic'), findsOneWidget);
      expect(find.textContaining('Plug'), findsNothing);
    });
  });
}

/// Serves one `ST_EP2338_0002`. A null struct never publishes.
class _EpBoxStateMan extends Fake implements StateMan {
  _EpBoxStateMan(this.struct, {this.descriptions = const []});

  final DynamicValue? struct;
  final List<String> descriptions;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key == _stateKey && struct != null) {
      return Stream<DynamicValue>.value(struct!);
    }
    if (key == _descriptionsKey && descriptions.isNotEmpty) {
      return Stream<DynamicValue>.value(DynamicValue.fromList(descriptions));
    }
    return const Stream<DynamicValue>.empty();
  }

  @override
  Future<DynamicValue> read(String key) async => struct ?? DynamicValue();
}
