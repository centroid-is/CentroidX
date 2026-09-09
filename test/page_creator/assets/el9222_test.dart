import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/el9222.dart';
import 'package:tfc/painter/beckhoff/io8.dart' show IOState, IO8Widget;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// The EL9222 asset used to be a drawing: six lamps hardcoded to
/// `IOState.low`, no subscription, no tap target. A tripped breaker looked
/// exactly like a healthy one and there was no way to reset it from the HMI.
///
/// These tests pin the two things that fixes, against the struct the PLC
/// actually publishes (`SVNCoreComponents/ECT/ST_EL9222_5500.TcDUT`): the
/// face says which channel is out, and the pane resets it with the RISING
/// EDGE the terminal wants — a pulse, because no PLC code ever clears
/// `p_cmd_Reset`.

/// Builds an `ST_EL9222_5500` with every member present and the named ones
/// overridden. Omitting a member from [absent] models a server that does not
/// publish it.
DynamicValue _struct({
  Map<String, bool> bits = const {},
  Set<String> absent = const {},
}) {
  final dv = DynamicValue();
  for (final flag in El9222Flag.values) {
    for (final channel in [1, 2]) {
      final member = flag.member(channel);
      if (absent.contains(member)) continue;
      dv[member] = bits[member] ?? false;
    }
  }
  dv['p_cmd_Reset'] = false;
  dv['p_cmd_Switch'] = true;
  dv['p_cmd_Reset_2'] = false;
  dv['p_cmd_Switch_2'] = true;
  return dv;
}

void main() {
  group('El9222ChannelStatus.read', () {
    test('channel 2 reads the _2-suffixed members, not channel 1\'s', () {
      final dv = _struct(bits: {'p_stat_Tripped_2': true});

      expect(El9222ChannelStatus.read(dv, 1)[El9222Flag.tripped], isFalse);
      expect(El9222ChannelStatus.read(dv, 2)[El9222Flag.tripped], isTrue);
    });

    test('a missing member stays null rather than collapsing to false', () {
      // A bit the server never served is not the same thing as a bit that is
      // off; rendering it as a confident "off" is how an operator ends up
      // trusting a diode that means nothing.
      final dv = _struct(absent: {'p_stat_Cool_Down_Lock'});
      final ch1 = El9222ChannelStatus.read(dv, 1);

      expect(ch1[El9222Flag.coolDownLock], isNull);
      expect(ch1[El9222Flag.tripped], isFalse);
      expect(ch1.isUnknown, isFalse);
    });

    test('a null struct leaves every flag unknown', () {
      final ch1 = El9222ChannelStatus.read(null, 1);

      expect(ch1.isUnknown, isTrue);
      expect(ch1.state, El9222ChannelState.unknown);
      for (final flag in El9222Flag.values) {
        expect(ch1[flag], isNull, reason: '${flag.name} should be unknown');
      }
    });
  });

  group('El9222ChannelStatus.state', () {
    El9222ChannelState stateOf(Map<String, bool> bits) =>
        El9222ChannelStatus.read(_struct(bits: bits), 1).state;

    test('enabled and quiet is live', () {
      expect(stateOf({'p_stat_Enabled': true}), El9222ChannelState.live);
    });

    test('enabled with the prewarning is strained, not live', () {
      expect(
        stateOf({'p_stat_Enabled': true, 'p_stat_Current_Level_Warning': true}),
        El9222ChannelState.strained,
      );
    });

    test('tripped outranks the prewarning that preceded it', () {
      expect(
        stateOf({'p_stat_Tripped': true, 'p_stat_Current_Level_Warning': true}),
        El9222ChannelState.tripped,
      );
    });

    test('hardware protection outranks a plain trip', () {
      // Both bits are set on a short circuit. The harder reason is the one
      // worth telling an electrician about.
      expect(
        stateOf({'p_stat_Tripped': true, 'p_stat_Hardware_Protection': true}),
        El9222ChannelState.shorted,
      );
    });

    test('error without a trip is faulted', () {
      expect(stateOf({'p_stat_Error': true}), El9222ChannelState.faulted);
    });

    test('nothing set at all is off, not faulted', () {
      expect(stateOf({}), El9222ChannelState.off);
    });
  });

  group('El9222ChannelStatus — reset gating', () {
    El9222ChannelStatus channel(Map<String, bool> bits) =>
        El9222ChannelStatus.read(_struct(bits: bits), 1);

    test('out is the terminal cutting the output, not a commanded off', () {
      expect(channel({'p_stat_Tripped': true}).out, isTrue);
      expect(channel({'p_stat_Hardware_Protection': true}).out, isTrue);
      // Switched off on purpose: nothing tripped.
      expect(channel({}).out, isFalse);
    });

    test('cool-down lock blocks a reset', () {
      final ch = channel({'p_stat_Tripped': true, 'p_stat_Cool_Down_Lock': true});
      expect(ch.resettable, isTrue);
      expect(ch.resetBlocked, isTrue);
    });

    test('a healthy channel has nothing to reset', () {
      expect(channel({'p_stat_Enabled': true}).resettable, isFalse);
    });

    test('an error is resettable even without a trip', () {
      expect(channel({'p_stat_Error': true}).resettable, isTrue);
    });
  });

  group('el9222WorstOf', () {
    test('picks the more serious of the two channels', () {
      expect(
        el9222WorstOf(El9222ChannelState.live, El9222ChannelState.tripped),
        El9222ChannelState.tripped,
      );
      expect(
        el9222WorstOf(El9222ChannelState.tripped, El9222ChannelState.shorted),
        El9222ChannelState.shorted,
      );
      expect(
        el9222WorstOf(El9222ChannelState.off, El9222ChannelState.unknown),
        El9222ChannelState.off,
      );
    });
  });

  group('el9222FaceLeds', () {
    List<IOState> facesOf(Map<String, bool> bits) {
      final dv = _struct(bits: bits);
      return el9222FaceLeds(
        El9222ChannelStatus.read(dv, 1),
        El9222ChannelStatus.read(dv, 2),
      );
    }

    test('both channels supplying: two green lamps, no red', () {
      final leds = facesOf({'p_stat_Enabled': true, 'p_stat_Enabled_2': true});
      expect(leds, [
        IOState.high,
        IOState.low,
        IOState.low,
        IOState.low,
        IOState.low,
        IOState.high,
      ]);
    });

    test('a tripped channel 1 reds its own lamp and leaves channel 2 alone',
        () {
      final leds =
          facesOf({'p_stat_Tripped': true, 'p_stat_Enabled_2': true});
      expect(leds[0], IOState.low, reason: 'ch1 no longer supplying');
      expect(leds[1], IOState.error, reason: 'ch1 out');
      expect(leds[2], IOState.low, reason: 'ch1 has no error bit');
      expect(leds[3], IOState.low, reason: 'ch2 not out');
      expect(leds[5], IOState.high, reason: 'ch2 still supplying');
    });

    test('a short circuit on channel 2 lights channel 2\'s out lamp', () {
      final leds = facesOf({'p_stat_Hardware_Protection_2': true});
      expect(leds[3], IOState.error);
      expect(leds[1], IOState.low, reason: 'channel 1 is fine');
    });

    test('a prewarning stays off the face', () {
      // Red on a mimic is what sends an electrician across the plant. A load
      // merely approaching its limit has not stopped anything.
      final leds = facesOf({
        'p_stat_Enabled': true,
        'p_stat_Current_Level_Warning': true,
        'p_stat_Cool_Down_Lock': true,
      });
      expect(leds.where((s) => s == IOState.error), isEmpty);
      expect(leds[0], IOState.high);
    });

    test('always six lamps — the face is drawn by IO6LedBlockPainter', () {
      expect(facesOf({}).length, 6);
    });
  });

  group('el9222PaneStatus', () {
    test('a tripped channel is a fault, a prewarning only a warning', () {
      expect(el9222PaneStatus(El9222ChannelState.tripped).label, 'Tripped');
      expect(el9222PaneStatus(El9222ChannelState.tripped).color, Colors.red);
      expect(el9222PaneStatus(El9222ChannelState.strained).color, Colors.orange);
    });
  });

  group('BeckhoffEL9222Config — data shape', () {
    test('round-trips the state key', () {
      final config = BeckhoffEL9222Config(
        nameOrId: 'ST101.A1.02',
        stateKey: 'ST101.ECT.ST101_A1_02',
        descriptionsKey: 'ST101.ECT.ST101_A1_02.Loads',
      );
      final back = BeckhoffEL9222Config.fromJson(config.toJson());

      expect(back.nameOrId, 'ST101.A1.02');
      expect(back.stateKey, 'ST101.ECT.ST101_A1_02');
      expect(back.descriptionsKey, 'ST101.ECT.ST101_A1_02.Loads');
    });

    test('preview() leaves both keys null', () {
      final config = BeckhoffEL9222Config.preview();
      expect(config.stateKey, isNull);
      expect(config.descriptionsKey, isNull);
    });

    test('allKeys carries the state key so resubscribe covers it', () {
      final config = BeckhoffEL9222Config(
        nameOrId: '1',
        stateKey: 'ST101.ECT.ST101_A1_02',
      );
      expect(config.allKeys, contains('ST101.ECT.ST101_A1_02'));
    });
  });

  group('EL9222 face + pane — live', () {
    setUp(() {
      // A station panel, not the 800x600 default: the pane's reset buttons
      // otherwise sit past the bottom of the render tree and every tap on
      // them misses.
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(1200, 900);
    });

    tearDown(() {
      closeSidePane();
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    Future<_El9222StateMan> pump(
      WidgetTester tester, {
      Map<String, bool> bits = const {},
      List<String> loads = const [],
      String? stateKey = 'ST101.ECT.ST101_A1_02',
    }) async {
      final stateMan = _El9222StateMan(
        stateKey: 'ST101.ECT.ST101_A1_02',
        descriptionsKey: 'ST101.ECT.Loads',
        struct: _struct(bits: bits),
        loads: loads,
      );
      final config = BeckhoffEL9222Config(
        nameOrId: 'ST101.A1.02',
        stateKey: stateKey,
        descriptionsKey: loads.isEmpty ? null : 'ST101.ECT.Loads',
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => stateMan),
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
      return stateMan;
    }

    testWidgets('a tripped channel lights the face', (tester) async {
      await pump(tester, bits: {
        'p_stat_Tripped': true,
        'p_stat_Enabled_2': true,
      });

      final face = tester.widget<IO8Widget>(find.byType(IO8Widget));
      expect(face.ledStates[1], IOState.error);
      expect(face.ledStates[5], IOState.high);
      expect(face.disconnected, isFalse);
    });

    testWidgets('no state key configured shows the disconnected face',
        (tester) async {
      // Six dark lamps are also what a healthy switched-off terminal looks
      // like, so silence has to say so out loud.
      await pump(tester, stateKey: null);

      final face = tester.widget<IO8Widget>(find.byType(IO8Widget));
      expect(face.disconnected, isTrue);
    });

    testWidgets('tap opens the pane, headlined by the worse channel',
        (tester) async {
      await pump(tester, bits: {
        'p_stat_Enabled': true,
        'p_stat_Tripped_2': true,
      });

      expect(find.byType(SidePane), findsNothing);
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.text('ST101.A1.02'), findsOneWidget);
      // Channel 1 is on; the terminal still headlines the tripped channel 2.
      expect(
        find.descendant(
          of: find.byType(PaneStatusChip),
          matching: find.text('Tripped'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the pane names what each channel feeds', (tester) async {
      await pump(
        tester,
        bits: {'p_stat_Enabled': true, 'p_stat_Enabled_2': true},
        loads: const ['CN04 photocells', 'CN05 gate solenoids'],
      );
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();

      expect(find.text('CN04 photocells'), findsOneWidget);
      expect(find.text('CN05 gate solenoids'), findsOneWidget);
    });

    testWidgets('reset pulses p_cmd_Reset high then low', (tester) async {
      // The terminal acknowledges a trip on a rising edge and no PLC code
      // ever clears the bit, so both halves of the edge are the HMI's.
      final stateMan = await pump(tester, bits: {'p_stat_Tripped': true});
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const ValueKey('el9222-reset-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('el9222-reset-1')));
      // Two pumps, not one: the rise reads the struct back before writing it,
      // so it lands a microtask after the press rather than within it.
      await tester.pump();
      await tester.pump();

      expect(stateMan.resetWrites, [true],
          reason: 'the rise lands before the pulse has elapsed');

      await tester.pump(kEl9222ResetPulse);
      await tester.pumpAndSettle();

      expect(stateMan.resetWrites, [true, false]);
      // Channel 2 was never touched.
      expect(stateMan.reset2Writes, isEmpty);
    });

    testWidgets('reset is refused while the channel is cooling down',
        (tester) async {
      final stateMan = await pump(tester, bits: {
        'p_stat_Tripped': true,
        'p_stat_Cool_Down_Lock': true,
      });
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();

      final button = tester
          .widget<TextButton>(find.byKey(const ValueKey('el9222-reset-1')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('Cooling down'), findsWidgets);
      expect(stateMan.resetWrites, isEmpty);
    });

    testWidgets('a healthy channel offers nothing to reset', (tester) async {
      await pump(tester, bits: {
        'p_stat_Enabled': true,
        'p_stat_Enabled_2': true,
      });
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();

      final button = tester
          .widget<TextButton>(find.byKey(const ValueKey('el9222-reset-1')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('Nothing to reset'), findsWidgets);
    });
  });
}

/// Serves one `ST_EL9222_5500` and records the reset edges written to it.
class _El9222StateMan extends Fake implements StateMan {
  _El9222StateMan({
    required this.stateKey,
    required this.descriptionsKey,
    required this.struct,
    this.loads = const [],
  });

  final String stateKey;
  final String descriptionsKey;
  final DynamicValue struct;
  final List<String> loads;

  /// The levels written to `p_cmd_Reset`, in order — the edge under test.
  final List<bool> resetWrites = [];
  final List<bool> reset2Writes = [];

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key == stateKey) return Stream<DynamicValue>.value(struct);
    if (key == descriptionsKey && loads.isNotEmpty) {
      return Stream<DynamicValue>.value(DynamicValue.fromList(loads));
    }
    return const Stream<DynamicValue>.empty();
  }

  @override
  Future<DynamicValue> read(String key) async => struct;

  @override
  Future<void> write(String key, DynamicValue value) async {
    if (key != stateKey) return;
    if (value.contains('p_cmd_Reset')) {
      resetWrites.add(value['p_cmd_Reset'].asBool);
    }
    if (value.contains('p_cmd_Reset_2')) {
      final level = value['p_cmd_Reset_2'].asBool;
      if (level) reset2Writes.add(level);
    }
  }
}
