import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/ep_box.dart'
    show EPBoxVariant, epBoxChannelsOf;
import 'package:tfc/painter/beckhoff/ep_box.dart' show EPBoxWidget;
import 'package:tfc/painter/beckhoff/io8.dart' show IO8Widget, IOState;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/widgets/panes/side_pane.dart' show SidePane, closeSidePane;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// The PLC GVL generator publishes each digital terminal as a struct, and
/// that struct is the canonical contract: `ST_EL1008` with BOOL members
/// `I1..I8`, `ST_EL2008` with `O1..O8` (live as `ECT.ST101_A1_03` and
/// friends), and `ST_EP2338_0002` with `I0..I7` *and* `O0..O7` in one
/// instance — the field boxes number from zero, and each of their M8 ports
/// is one physical point carrying both directions.
///
/// The EL widgets used to decode only the packed byte the PLC published
/// before, so a struct-published terminal rendered all channels dark. These
/// tests pin [beckhoffStructChannels] / [beckhoffChannelStates], the decode
/// both terminal faces and their channel grids now share: the struct is the
/// primary shape in both numbering bases, the byte stays as a silent
/// fallback, and a value in neither shape reads as unknown, not as eight
/// healthy lows.
///
/// They also pin the per-channel descriptions an asset can now carry itself:
/// configured beats key-delivered beats the default label.

const _rawKey = 'ST101.ECT.ST101_A1_03';
const _descriptionsKey = 'ST101.ECT.ST101_A1_03_Descriptions';

/// A struct value the way the GVL generator publishes one: BOOL members
/// `<prefix><base>..<prefix><base+7>`, [high] naming the members (by their
/// number as generated) that are on.
DynamicValue structValue(String prefix, Set<int> high, {int base = 1}) {
  final v = DynamicValue();
  for (var n = base; n < base + 8; n++) {
    v['$prefix$n'] = high.contains(n);
  }
  return v;
}

void main() {
  group('beckhoffStructChannels — the canonical struct shape', () {
    test('ST_EL1008: member In is channel n (one-based)', () {
      final states = beckhoffStructChannels(structValue('I', {2, 7}), 'I');

      expect(states,
          [false, true, false, false, false, false, true, false]);
    });

    test('ST_EL2008: member On is channel n (one-based)', () {
      final states = beckhoffStructChannels(structValue('O', {1, 8}), 'O');

      expect(states,
          [true, false, false, false, false, false, false, true]);
    });

    test('ST_EP2338_0002: I0 is channel list index 0 (zero-based)', () {
      final states =
          beckhoffStructChannels(structValue('I', {0, 5}, base: 0), 'I');

      expect(states,
          [true, false, false, false, false, true, false, false]);
    });

    test('one EP2338 struct yields both directions as separate lists', () {
      // The combi box publishes I0..I7 and O0..O7 in the same instance —
      // port n is one physical pin whose input state and output drive both
      // live there. The decode must not collapse the two.
      final struct = DynamicValue();
      for (var n = 0; n < 8; n++) {
        struct['I$n'] = n == 1;
        struct['O$n'] = n == 6;
      }

      expect(beckhoffStructChannels(struct, 'I'),
          [false, true, false, false, false, false, false, false]);
      expect(beckhoffStructChannels(struct, 'O'),
          [false, false, false, false, false, false, true, false]);
    });

    test('the EP box pairs the two directions per port', () {
      // The asset's own decode ([epBoxChannelsOf]) reads the same struct
      // into per-port channels; this pins that its view and the shared
      // decoder's view of one struct agree.
      final struct = DynamicValue();
      for (var n = 0; n < 8; n++) {
        struct['I$n'] = n == 1;
        struct['O$n'] = n == 1 || n == 6;
      }

      final channels = epBoxChannelsOf(struct);
      expect(channels, hasLength(8));
      // Port 2 (I1/O1): both directions live on the one physical point.
      expect(channels[1].input, isTrue);
      expect(channels[1].output, isTrue);
      // Port 7 (I6/O6): output driven, input quiet.
      expect(channels[6].input, isFalse);
      expect(channels[6].output, isTrue);
      expect(channels[0].active, isFalse);
    });

    test('a member the struct does not carry reads low, not thrown', () {
      final v = DynamicValue();
      v['I1'] = true;
      v['I2'] = false;
      // I3..I8 never published.

      final states = beckhoffStructChannels(v, 'I');

      expect(states, isNotNull);
      expect(states!.first, isTrue);
      expect(states.sublist(1), everyElement(isFalse));
    });

    test('a struct without the asked-for prefix is null', () {
      expect(beckhoffStructChannels(structValue('O', {1}), 'I'), isNull);
      expect(beckhoffStructChannels(DynamicValue(value: 3), 'I'), isNull);
    });
  });

  group('beckhoffChannelStates — what the EL faces decode', () {
    test('takes the struct first, either prefix, either base', () {
      expect(beckhoffChannelStates(structValue('I', {3}))![2], isTrue);
      expect(beckhoffChannelStates(structValue('O', {3}))![2], isTrue);
      expect(
          beckhoffChannelStates(structValue('I', {2}, base: 0))![2], isTrue);
    });

    test('legacy packed byte still decodes — bit i is channel i + 1', () {
      // 0b10100101 — channels 1, 3, 6, 8. Stations not yet regenerated
      // still publish this, and the fallback costs nothing.
      final states = beckhoffChannelStates(DynamicValue(value: 0xA5));

      expect(states, [true, false, true, false, false, true, false, true]);
    });

    test('neither shape is unknown, never eight confident lows', () {
      expect(beckhoffChannelStates(null), isNull);
      expect(beckhoffChannelStates(DynamicValue(value: 'ST101.A1.03')),
          isNull);
      expect(
          beckhoffChannelStates(DynamicValue.fromList([true, false])), isNull);

      final foreign = DynamicValue();
      foreign['Fieldvoltage_Underrange'] = false;
      expect(beckhoffChannelStates(foreign), isNull);
    });
  });

  group('beckhoffChannelDescription — precedence', () {
    final fromKey = DynamicValue.fromList(['Key one', 'Key two', 'Key three']);

    test('a configured description wins over the key-delivered one', () {
      expect(
        beckhoffChannelDescription(['Configured one'], fromKey, 0),
        'Configured one',
      );
    });

    test('an empty configured entry falls through to the key', () {
      expect(beckhoffChannelDescription(['', '  '], fromKey, 1), 'Key two');
    });

    test('no configuration at all falls through to the key', () {
      expect(beckhoffChannelDescription(null, fromKey, 2), 'Key three');
    });

    test('nothing anywhere is null — the default channel label', () {
      expect(beckhoffChannelDescription(null, null, 0), isNull);
      expect(beckhoffChannelDescription(['a'], fromKey, 5), isNull);
      expect(
          beckhoffChannelDescription(null, DynamicValue(value: 'no array'), 0),
          isNull);
    });
  });

  group('channel descriptions — config round-trips', () {
    test('EL1008 carries channel_descriptions through JSON', () {
      final config = BeckhoffEL1008Config(
        nameOrId: 'ST101.A1.03',
        rawStateKey: _rawKey,
        channelDescriptions: ['Kettle high level', '', 'Belt 3 photocell'],
      );

      final json = config.toJson();
      expect(json['channel_descriptions'],
          ['Kettle high level', '', 'Belt 3 photocell']);

      final back = BeckhoffEL1008Config.fromJson(json);
      expect(back.channelDescriptions,
          ['Kettle high level', '', 'Belt 3 photocell']);
    });

    test('EL2008 carries channel_descriptions through JSON', () {
      final config = BeckhoffEL2008Config(
        nameOrId: '1',
        channelDescriptions: List.generate(8, (i) => 'Valve ${i + 1}'),
      );

      final back = BeckhoffEL2008Config.fromJson(config.toJson());
      expect(back.channelDescriptions, hasLength(8));
      expect(back.channelDescriptions!.first, 'Valve 1');
    });

    test('EP box carries one description per port through JSON', () {
      final config = BeckhoffEPBoxConfig.preview()
        ..channelDescriptions = List.generate(8, (i) => 'Port ${i + 1}');

      final back = BeckhoffEPBoxConfig.fromJson(config.toJson());
      expect(back.channelDescriptions, hasLength(8));
      expect(back.channelDescriptions!.last, 'Port 8');
    });

    test('absent stays absent', () {
      final back = BeckhoffEL1008Config.fromJson(
          BeckhoffEL1008Config(nameOrId: '1').toJson());
      expect(back.channelDescriptions, isNull);
    });
  });

  group('the EL1008 face, live', () {
    Future<IO8Widget> pump(WidgetTester tester, DynamicValue raw) async {
      final config = BeckhoffEL1008Config(
        nameOrId: 'ST101.A1.03',
        rawStateKey: _rawKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith(
              (ref) async => _StubStateMan({_rawKey: raw})),
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

    testWidgets('fed the generated ST_EL1008 struct, the right channels '
        'light', (tester) async {
      final face = await pump(tester, structValue('I', {2, 7}));

      expect(face.ledStates, [
        IOState.low,
        IOState.high,
        IOState.low,
        IOState.low,
        IOState.low,
        IOState.low,
        IOState.high,
        IOState.low,
      ]);
    });

    testWidgets('fed the legacy packed byte, the same channels light',
        (tester) async {
      // Channels 2 and 7: bits 1 and 6.
      final face = await pump(tester, DynamicValue(value: 0x42));

      expect(face.ledStates, [
        IOState.low,
        IOState.high,
        IOState.low,
        IOState.low,
        IOState.low,
        IOState.low,
        IOState.high,
        IOState.low,
      ]);
    });

    testWidgets('fed a value in neither shape, every channel stays dark',
        (tester) async {
      final face = await pump(tester, DynamicValue(value: 'not a state'));

      expect(face.ledStates, everyElement(IOState.low));
    });
  });

  group('the EL1008 channel grid — descriptions', () {
    tearDown(closeSidePane);

    Future<void> openGrid(
      WidgetTester tester, {
      List<String>? configured,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final config = BeckhoffEL1008Config(
        nameOrId: 'ST101.A1.03',
        rawStateKey: _rawKey,
        descriptionsKey: _descriptionsKey,
        channelDescriptions: configured,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _StubStateMan({
                _rawKey: structValue('I', {1}),
                _descriptionsKey: DynamicValue.fromList(
                    List.generate(8, (i) => 'Key ch${i + 1}')),
              })),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 400,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // One tap. The descriptions are in the pane itself now — the floating
      // channel grid they used to live behind is gone, along with the force
      // buttons that were the only reason it needed 900px.
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsOneWidget);
    }

    testWidgets('a configured description renders at its channel and beats '
        'the key-delivered one', (tester) async {
      await openGrid(
        tester,
        configured: ['', '', 'Belt 3 photocell'],
      );

      // Channel 3 wears the configured name, not the key's.
      expect(find.text('Belt 3 photocell'), findsOneWidget);
      expect(find.text('Key ch3'), findsNothing);
      // Channels the config leaves empty keep the key-delivered names.
      expect(find.text('Key ch1'), findsOneWidget);
      expect(find.text('Key ch8'), findsOneWidget);
      // And every channel still carries its own PLC name beside whatever it
      // is called, so a described channel is still findable as I3.
      expect(find.text('I3'), findsOneWidget);
      expect(find.text('I8'), findsOneWidget);
    });

    testWidgets('the pane offers no way to force a channel', (tester) async {
      await openGrid(tester, configured: null);

      // The PLC accepts no override, so the surface that offered one is
      // gone: no expand tile, no dialog, no Auto/Low/High.
      expect(find.text('Channel detail'), findsNothing);
      // 'Auto' was the segmented force control's neutral position; it has no
      // other home in this pane. ('High' does — it is the count tile.)
      expect(find.text('Auto'), findsNothing);
      expect(find.text('Force'), findsNothing);
    });

    testWidgets('with nothing configured, the key-delivered names stand',
        (tester) async {
      await openGrid(tester, configured: null);

      expect(find.text('Key ch3'), findsOneWidget);
    });
  });

  group('the EP box pane — configured port names', () {
    tearDown(closeSidePane);

    const stateKey = 'ST301.ECT.ST301_RM05';
    const descKey = 'ST301.ECT.ST301_RM05.Sockets';

    testWidgets('one description per port, configured beating the key',
        (tester) async {
      final struct = DynamicValue();
      for (var n = 0; n < 8; n++) {
        struct['I$n'] = false;
        struct['O$n'] = false;
      }

      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep2338,
        nameOrId: 'RM05',
        stateKey: stateKey,
        descriptionsKey: descKey,
        // Port 2 named on the asset; the rest left to the key.
        channelDescriptions: const ['', 'Erector ready (asset)'],
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _StubStateMan({
                stateKey: struct,
                descKey: DynamicValue.fromList(
                    const ['Erector jam photocell', 'Erector ready (key)']),
              })),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 300,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(EPBoxWidget));
      await tester.pumpAndSettle();

      expect(find.text('Erector ready (asset)'), findsOneWidget);
      expect(find.text('Erector ready (key)'), findsNothing);
      expect(find.text('Erector jam photocell'), findsOneWidget);
      // Ports nobody named show their PLC name alone; named ones show it too,
      // in the gutter beside the name the plant gave them.
      expect(find.text('I2'), findsOneWidget);
      expect(find.text('I1'), findsOneWidget);
    });
  });
}

/// Publishes a fixed value per key; a key absent here never publishes.
class _StubStateMan extends Fake implements StateMan {
  _StubStateMan(this.values);

  final Map<String, DynamicValue> values;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final value = values[key];
    if (value != null) {
      return Stream<DynamicValue>.value(value);
    }
    return const Stream<DynamicValue>.empty();
  }
}
