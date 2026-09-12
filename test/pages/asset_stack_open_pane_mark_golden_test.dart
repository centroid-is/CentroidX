/// Goldens of the mark the plant view puts on the asset whose pane is open.
///
/// The mark is traced from the asset's own hit test rather than drawn as its
/// box, so these images are also a picture of where each asset actually takes
/// a tap — which is the thing worth reviewing. A straight belt is a band down
/// the middle of a taller box; a turned belt is an arc across a box it barely
/// fills; a gate is a glyph in a square; a button is the whole square. If any
/// of those outlines stops matching the glyph inside it, that asset's hit area
/// has come adrift and the picture says so.
///
/// The per-asset frames capture the canvas alone (the pane is docked in the
/// app's overlay, outside `AssetStack`) so the outline is big enough to judge.
/// `open_pane_mark_with_pane` is the whole screen, for what an operator
/// actually sees.
///
/// To update: flutter test test/pages/asset_stack_open_pane_mark_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart'
    show DynamicValue, EnumField, LocalizedText, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/analog_box.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/painter/beckhoff/io8.dart' show IO8Widget;
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/page_creator/assets/section_button.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/golden_tolerance.dart';
import '../helpers/golden_platform.dart';

/// Real letterforms and glyphs; the test font draws every label as a box,
/// which for an image about how loud a mark is would be misleading.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  // Both names: Material's default family, and the one the app's theme asks
  // for — a themed golden that only registers 'Roboto' draws every label as a
  // test-font block.
  for (final family in ['Roboto', 'roboto-mono']) {
    await load(family, 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await load('MaterialIcons', candidate);
      break;
    }
  }
}

ConveyorGateConfig _gate(String label, {required double x, double? angle}) =>
    ConveyorGateConfig(
      gateVariant: GateVariant.pneumatic,
      stateKey: 'gate/state',
      forceOpenKey: 'gate/force_open',
      forceCloseKey: 'gate/force_close',
      forceOpenFeedbackKey: 'gate/fo_fb',
      forceCloseFeedbackKey: 'gate/fc_fb',
    )
      ..text = label
      ..textPos = TextPos.below
      // Small enough that the label under it stays a label: `AssetStack`
      // scales label text with the asset's box, and a gate half the height of
      // the page comes with lettering to match.
      ..coordinates = Coordinates(x: x, y: 0.4, angle: angle)
      ..size = const RelativeSize(width: 0.06, height: 0.09);

ConveyorConfig _conveyor({
  List<ConveyorTurnEntry> turns = const [],
  double? angle,
  double? beltWidthRelative,
  RelativeSize size = const RelativeSize(width: 0.6, height: 0.3),
}) =>
    ConveyorConfig(key: 'cn/drive', turns: turns)
      ..beltWidthRelative = beltWidthRelative
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle)
      ..size = size;

void main() {
  // A full app surface with real text: the same cross-version antialiasing
  // drift the gate pane golden allows for applies here.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('open-pane mark golden',
      skip: goldenSkip, () {
    setUpAll(_loadFonts);

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    tearDown(() => closeSidePane(immediate: true));

    Future<void> pump(
      WidgetTester tester,
      List<Asset> assets, {
      Size surface = const Size(800, 600),
      bool dark = false,
      bool appBar = false,
    }) async {
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fake = _FakeStateMan()
        ..push('gate/state', true)
        ..pushValue('sec/a', _runningSection())
        // A belt with no reading yet renders grey and takes no taps at all
        // (`!snapshot.hasData` in `Conveyor`), so there would be nothing to
        // mark — and its pane reads the drive struct member by member, so a
        // bare bool would throw the moment the pane opened.
        ..pushValue('cn/drive', _runningDrive())
        // The rack slices: a couple of inputs high, nothing forced.
        ..pushValue('el/raw', DynamicValue(value: 0x16))
        ..pushValue('el/force', DynamicValue(value: 0));
      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark
              ? themesForScheme(AppColorScheme.muted).$2
              : themesForScheme(AppColorScheme.muted).$1,
          home: Scaffold(
            // The real app puts every mimic under `BaseScaffold`'s bar, which
            // makes the canvas shorter than the screen — the gap an asset
            // sizing itself off `MediaQuery` falls into. Off by default so
            // the existing frames keep their framing.
            appBar: appBar ? AppBar(title: const Text('Plant')) : null,
            body: LayoutBuilder(
              builder: (context, constraints) => AssetStack(
                assets: assets,
                constraints: constraints,
                selectedAssets: const {},
                mirroringDisabled: true,
                absorb: false,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }


    /// Carries the mark round to the top of its breath.
    ///
    /// The ring dims and brightens for as long as the pane is open, so where
    /// these pumps happen to land decides how dark the dashes come out. That
    /// makes the image an accident of the pump schedule — a golden nobody can
    /// read a change out of, because a fainter ring next time says nothing
    /// about whether anything moved. Wound forward to phase 0 instead, which
    /// is full presence and the one pose worth comparing against.
    Future<void> markAtFullBreath(WidgetTester tester) async {
      final paint =
          tester.widget<CustomPaint>(find.byKey(openPaneMarkKey));
      final phase = (paint.painter as HitBoundaryPainter).phase;
      final period = HitBoundaryStyle.selection.period.inMicroseconds;
      // Phase wraps, so the way to zero is always forwards.
      final remaining = ((1 - phase) % 1) * period;
      await tester.pump(Duration(microseconds: remaining.round()));
    }

    /// Taps the asset where it actually answers, and settles.
    ///
    /// The centre of a turned belt's box is not on the belt — that is the
    /// whole reason these goldens exist — so a fixed point is no good. Sweep
    /// the asset's rectangle and take the first point that opens a pane,
    /// which is the same question the mark itself asks.
    Future<void> tapGlyph(WidgetTester tester, Finder asset) async {
      final rect = tester.getRect(asset);
      for (var y = 0.1; y < 1 && !isSidePaneOpen(); y += 0.1) {
        for (var x = 0.05; x < 1; x += 0.05) {
          await tester.tapAt(Offset(
            rect.left + rect.width * x,
            rect.top + rect.height * y,
          ));
          await tester.pump();
          if (isSidePaneOpen()) break;
        }
      }
      expect(isSidePaneOpen(), isTrue,
          reason: 'nothing in the asset rectangle opened a pane');
      // Pumped by hand rather than settled: a running belt's pane animates
      // for as long as it is open, so there is no settled state to wait for.
      // One frame for the pane's own build, one for the post-frame trace of
      // the asset's hit test, then past the mark's 180ms fade.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      await markAtFullBreath(tester);
    }


    /// The canvas alone. The pane lives in the app's overlay, outside the
    /// stack, so this frames the mark rather than the sheet beside it.
    Future<void> expectCanvas(WidgetTester tester, String name) => expectLater(
          find.byType(AssetStack),
          matchesGoldenFile('goldens/$name.png'),
        );

    testWidgets('no pane open — the page carries no mark', (tester) async {
      await pump(tester, [
        _gate('CN-04', x: 0.1),
        _gate('CN-05', x: 0.25),
        _gate('CN-06', x: 0.4, angle: 35),
      ]);
      await expectCanvas(tester, 'open_pane_mark_none');
    });

    testWidgets('the whole screen: pane docked, its gate marked',
        (tester) async {
      await pump(tester, [
        _gate('CN-04', x: 0.1),
        _gate('CN-05', x: 0.25),
        _gate('CN-06', x: 0.4, angle: 35),
      ]);
      await tapGlyph(tester, find.byType(ConveyorGate).at(1));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/open_pane_mark_with_pane.png'),
      );
    });

    testWidgets('a fading ring carried through a relayout sits on its asset',
        (tester) async {
      // The close-time ghost. Closing a pane the page had stepped aside for
      // re-lays the canvas out in the same frame the ring starts its 180ms
      // fade, and the ring used to spend that fade at the old layout's
      // coordinates — off to the left of the gate it was about. This frame is
      // taken mid-fade, after the canvas has moved: the dimmed ring must sit
      // on the gate at its new place, standoff and all.
      await pump(tester, [
        _gate('CN-04', x: 0.1),
        _gate('CN-05', x: 0.25),
        _gate('CN-06', x: 0.4, angle: 35),
      ]);
      await tapGlyph(tester, find.byType(ConveyorGate).at(1));

      closeSidePane();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The relayout the inset release causes, reproduced as a surface
      // change: every asset lands somewhere new while the ring is mid-fade.
      await tester.binding.setSurfaceSize(const Size(600, 450));
      await tester.pump(const Duration(milliseconds: 16));

      await expectCanvas(tester, 'open_pane_mark_fading_relayout');
    });

    testWidgets('a diverter gate: its box, which the arm overhangs',
        (tester) async {
      // The gate takes taps on its whole box, so the box is what is marked.
      // Two things about the glyph are worth seeing here and neither is the
      // mark's doing: the pivot hub is drawn centred on the box's left edge,
      // so half of it is painted outside the box and is not tappable; and the
      // arm is anchored at that edge rather than centred, so a box taller
      // than the arm is mostly empty below it.
      await pump(
        tester,
        [
          (_gate('CN-05', x: 0.5)
            ..coordinates = Coordinates(x: 0.5, y: 0.45)
            ..size = const RelativeSize(width: 0.2, height: 0.4)),
        ],
        surface: const Size(600, 400),
      );
      await tapGlyph(tester, find.byType(ConveyorGate));
      await expectCanvas(tester, 'hit_boundary_gate');
    });

    testWidgets('a diverter gate in a box shaped like the arm',
        (tester) async {
      // The same gate in a box the shape the arm actually is — wide and
      // short, the way one sits across a belt. The overhanging hub is still
      // there; the empty space is not.
      await pump(
        tester,
        [
          (_gate('CN-05', x: 0.5)
            ..coordinates = Coordinates(x: 0.5, y: 0.45)
            ..size = const RelativeSize(width: 0.42, height: 0.22)),
        ],
        surface: const Size(600, 400),
      );
      await tapGlyph(tester, find.byType(ConveyorGate));
      await expectCanvas(tester, 'hit_boundary_gate_wide');
    });

    testWidgets('a pusher gate: the blade and its actuator', (tester) async {
      await pump(
        tester,
        [
          (ConveyorGateConfig(
            gateVariant: GateVariant.pusher,
            stateKey: 'gate/state',
            forceOpenKey: 'gate/force_open',
          )
            ..text = 'PU-02'
            ..textPos = TextPos.below
            ..coordinates = Coordinates(x: 0.5, y: 0.45)
            ..size = const RelativeSize(width: 0.34, height: 0.3)),
        ],
        surface: const Size(600, 400),
      );
      await tapGlyph(tester, find.byType(ConveyorGate));
      await expectCanvas(tester, 'hit_boundary_gate_pusher');
    });

    testWidgets('a straight belt: the band, not the box', (tester) async {
      // The belt is a fraction of its box's height, and taps on the rest of
      // the box fall through to whatever is behind. The mark says so.
      await pump(
        tester,
        // A third of the box's height: the belt an operator sees, inside a
        // box three times as tall.
        [_conveyor(beltWidthRelative: 0.1)],
        surface: const Size(800, 400),
      );
      await tapGlyph(tester, find.byType(Conveyor));
      await expectCanvas(tester, 'hit_boundary_conveyor_straight');
    });

    testWidgets('a turned belt: the arc, not the box', (tester) async {
      await pump(
        tester,
        [
          _conveyor(
            turns: [ConveyorTurnEntry(position: 0.45, angle: 70, radius: 1.4)],
          ),
        ],
        surface: const Size(800, 400),
      );
      await tapGlyph(tester, find.byType(Conveyor));
      await expectCanvas(tester, 'hit_boundary_conveyor_turn');
    });

    testWidgets('a turned belt, rotated: the mark turns with it',
        (tester) async {
      await pump(
        tester,
        [
          _conveyor(
            angle: 30,
            turns: [ConveyorTurnEntry(position: 0.5, angle: 60, radius: 1.4)],
            size: const RelativeSize(width: 0.5, height: 0.3),
          ),
        ],
        surface: const Size(800, 400),
      );
      await tapGlyph(tester, find.byType(Conveyor));
      await expectCanvas(tester, 'hit_boundary_conveyor_turn_rotated');
    });

    testWidgets('the same belt on the dark scheme: the ink swaps with it',
        (tester) async {
      // The pair the old halo was made of, spent as an either/or instead of
      // as a fringe. Held against `hit_boundary_conveyor_turn`, which is this
      // belt on the light page: same ring, opposite tone. Drawn in the light
      // page's near-black it would be 1.1:1 against this background — there,
      // and invisible.
      await pump(
        tester,
        [
          _conveyor(
            turns: [ConveyorTurnEntry(position: 0.45, angle: 70, radius: 1.4)],
          ),
        ],
        surface: const Size(800, 400),
        dark: true,
      );
      await tapGlyph(tester, find.byType(Conveyor));
      await expectCanvas(tester, 'hit_boundary_conveyor_turn_dark');
    });

    testWidgets('a sensor: the glyph, small', (tester) async {
      await pump(
        tester,
        [
          SensorConfig(kind: SensorKind.opticField, detectionKey: 'sensor/det')
            ..text = 'PE-11'
            ..coordinates = Coordinates(x: 0.5, y: 0.45)
            ..size = const RelativeSize(width: 0.16, height: 0.24),
        ],
        surface: const Size(600, 400),
      );
      await tapGlyph(tester, find.byType(Sensor));
      await expectCanvas(tester, 'hit_boundary_sensor');
    });

    testWidgets('an analog box: the whole face, which is the truth for it',
        (tester) async {
      // Not every asset has a shape worth tracing — a box takes taps across
      // its whole face, and the traced outline agrees. That tracing and the
      // old rectangle give the same answer here is the point: the mark only
      // differs from the box where the asset itself does.
      await pump(
        tester,
        [
          AnalogBoxConfig(analogKey: 'tank/level', units: '%')
            ..text = 'LT-21'
            ..textPos = TextPos.below
            ..coordinates = Coordinates(x: 0.5, y: 0.45)
            ..size = const RelativeSize(width: 0.22, height: 0.4),
        ],
        surface: const Size(600, 400),
      );
      await tapGlyph(tester, find.byType(AnalogBox));
      await expectCanvas(tester, 'hit_boundary_analog_box');
    });

    testWidgets('a section button: the disc, on a canvas short of the screen',
        (tester) async {
      // The button is a disc in its box and publishes that disc, so the ring
      // should sit on the rim with the label clear below it.
      //
      // Under an app bar, which is where every mimic in the app actually
      // lives: the canvas is shorter than the screen, and the button used to
      // derive its published shape from `MediaQuery` — a fraction of the
      // whole window rather than of the canvas it is drawn on. That put the
      // ring low and wide of the disc, over the label. If it ever creeps off
      // the rim again, this frame says so.
      await pump(
        tester,
        [
          SectionButtonConfig(
            sections: [SectionRef(key: 'sec/a')],
          )
            ..text = 'Before freezers'
            ..textPos = TextPos.below
            ..coordinates = Coordinates(x: 0.5, y: 0.45)
            ..size = const RelativeSize(width: 0.16, height: 0.24),
        ],
        surface: const Size(600, 400),
        appBar: true,
      );
      await tapGlyph(tester, find.byType(SectionButton));
      await expectCanvas(tester, 'hit_boundary_section_button');
    });

    testWidgets('a rack slice: the tapped terminal, not the whole block',
        (tester) async {
      // A CX5010 heading three terminals, tapped on the middle one. The rack
      // is one asset, but each slice is its own [SubdeviceSubject], so the
      // ring must frame that slice alone — the whole-block ring is the
      // regression this frame keeps out. The slices also wear their
      // configured name or id as a marker tag above the LED block, the way
      // the printed terminal markers sit on the real hardware.
      await pump(
        tester,
        [
          BeckhoffCX5010Config()
            ..coordinates = Coordinates(x: 0.42, y: 0.5)
            ..size = const RelativeSize(width: 0.6, height: 0.8)
            ..subdevices = [
              BeckhoffEL1008Config(
                nameOrId: 'K1',
                rawStateKey: 'el/raw',
                forceValuesKey: 'el/force',
              ),
              BeckhoffEL2008Config(
                nameOrId: 'K2',
                rawStateKey: 'el/raw',
                forceValuesKey: 'el/force',
              ),
              BeckhoffEL9222Config(nameOrId: 'K3'),
            ],
        ],
        surface: const Size(800, 500),
      );

      // Straight onto the middle slice — no sweep: every slice answers a
      // tap, and the point of the frame is which one was hit.
      await tester.tap(find.byType(IO8Widget).at(1));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      await markAtFullBreath(tester);

      await expectCanvas(tester, 'hit_boundary_rack_slice');
    });
  });
}

/// A section standing in auto with nothing holding it off — the state the
/// button paints green for, and the one the pane opens on.
DynamicValue _runningSection() {
  final section = DynamicValue();
  section[kSectionStatEnabled] =
      DynamicValue(value: true, typeId: NodeId.boolean);
  section[kSectionStatCleanEnabled] =
      DynamicValue(value: false, typeId: NodeId.boolean);
  section[kSectionStatPermissive] =
      DynamicValue(value: true, typeId: NodeId.boolean);
  return section;
}

/// An `FB_ATV320` HMI struct for a belt that is running in auto.
///
/// The mimic reads `p_stat_RunMode` by name to colour the belt, and the pane
/// reads the rest of the struct member by member — so this is the smallest
/// value that leaves a conveyor both green and tappable.
DynamicValue _runningDrive() {
  const modes = ['stopped', 'auto', 'manual', 'clean', 'fault'];
  final runMode = DynamicValue(value: modes.indexOf('auto'));
  runMode.enumFields = {
    for (var i = 0; i < modes.length; i++)
      i: EnumField(i, modes[i], LocalizedText(modes[i], 'en'),
          LocalizedText('', 'en')),
  };

  final drive = DynamicValue();
  drive['p_stat_State'] = 0;
  drive['p_stat_LastFault'] = 0;
  drive['p_stat_RunMode'] = runMode;
  drive['p_stat_Frequency'] = 42.0;
  drive['p_stat_Current'] = 3.2;
  drive['p_stat_RunMinutes'] = 128;
  drive['p_stat_JogFwd'] = false;
  drive['p_stat_JogBwd'] = false;
  drive['p_stat_ManualStopOnRelease'] = true;
  drive['p_cfg_ManualFreq'] = 20.0;
  drive['p_cfg_AutoFreq'] = 50.0;
  drive['p_cfg_CleaningFreq'] = 20.0;
  return drive;
}

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(String key, bool value) =>
      pushValue(key, DynamicValue(value: value, typeId: NodeId.boolean));

  void pushValue(String key, DynamicValue value) {
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(value);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<void> write(String key, DynamicValue value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}
