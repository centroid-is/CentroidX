import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/vtug.dart';
import 'package:tfc/painter/festo/valve_symbol.dart';
import 'package:tfc/painter/festo/vtug.dart';
import 'package:tfc/theme.dart';
import '../../helpers/golden_platform.dart';

/// Goldens of the Festo VTUG-14 terminal and its pane.
///
/// The drawing is of a real part and no widget test can say whether it looks
/// like one: whether eight 14 mm slices and a CTEU-EC read as the assembly
/// bolted to ST303, whether the coil lamps land where the LEDs land on the
/// valve, whether a blanked position is visibly a gap in the row rather than
/// a valve that happens to be off. These images are how that gets checked.
///
/// They also pin the honest bits, which are the ones easiest to "fix" into a
/// lie:
///
///  * A **blank** position draws no lamps at all. A dark lamp there would
///    invent a coil the manifold does not have.
///  * A **dark** bus node draws every LED unknown, including ERROR. Drawing
///    ERROR dark because no error arrived reads a silence as an all-clear.
///  * A **held** valve wears an orange bar. Orange is forced everywhere in
///    this repo, and a hand-held valve that looked like an automatic one is
///    a valve somebody forgets to give back. The bar is drawn whether or not
///    the coil is energised — holding a monostable at port 2 means holding
///    its coil off, and that valve is just as taken as a lit one.
///  * A **5/3** and a **5/2 bistable** draw the same two lamps and the same
///    two coils, and only their schematics say that one of them has a
///    closed centre. `valve_symbols.png` is where that is checked.
Future<void> loadRealFont() async {
  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont(
      'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }
}

void main() {
  setUpAll(loadRealFont);

  /// The real station themes, not a hand-rolled one.
  ///
  /// A pane golden built on a bare `ThemeData` cannot catch the thing dark
  /// goldens exist to catch: neither Solarized scheme sets
  /// `colorScheme.outline`, so a widget that borrows it draws an edge that
  /// is invisible on base03 and perfectly fine in the light image.
  final (lightTheme, darkTheme) = solarized();

  Widget host(Widget child, {bool dark = false, Color? background}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: (dark ? darkTheme : lightTheme).copyWith(
          textTheme: (dark ? darkTheme : lightTheme)
              .textTheme
              .apply(fontFamily: 'roboto-mono'),
        ),
        home: Scaffold(
          backgroundColor: background ??
              (dark
                  ? const Color(0xFF002B36)
                  : const Color(0xFFEEE8D5)),
          body: Center(child: child),
        ),
      );

  /// The manifold as ordered unless a test says otherwise: five 5/2
  /// monostables then three 5/3 closed centres.
  List<VtugValveKind> kinds({
    Set<int> blanks = const {},
    Set<int> mono = const {1, 2, 3, 4, 5},
  }) =>
      [
        for (var i = 1; i <= vtugPositionCount; i++)
          blanks.contains(i)
              ? VtugValveKind.blank
              : mono.contains(i)
                  ? VtugValveKind.valve52Mono
                  : VtugValveKind.valve53Closed,
      ];

  DynamicValue struct({
    int coils = 0,
    int forceMask = 0,
    int forceValue = 0,
  }) {
    final dv = DynamicValue();
    dv['p_stat_Coils'] = coils;
    dv['p_stat_Forced'] = 0;
    dv['p_cmd_Force'] = forceMask;
    dv['p_cmd_Value'] = forceValue;
    return dv;
  }

  /// The drawing, built from a decoded terminal the same way the live widget
  /// builds it — so a change to how the asset maps valves onto slices shows
  /// up here rather than only on a running station.
  Widget drawing(VtugTerminal terminal, CteuLink link, {String name = ''}) =>
      Builder(
        builder: (context) => VtugWidget(
          height: 200,
          slices: [
            for (final valve in terminal.valves)
              VtugSliceView(
                coils: [
                  for (final coil in VtugCoil.values)
                    if (valve.hasCoil(coil)) valve.coilState(coil),
                ],
                held: valve.force != VtugForce.auto,
              ),
          ],
          leds: link.leds,
          litColor: HmiStateColors.of(context).yellow,
          name: name,
          disconnected: link == CteuLink.dark,
        ),
      );

  group('the drawing', () {
    testWidgets('the manifold as ordered, nothing energised', (tester) async {
      await tester.pumpWidget(host(drawing(
        VtugTerminal.read(struct(), kinds: kinds()),
        CteuLink.live,
        name: 'ST303.A1',
      )));
      await expectLater(
        find.byType(VtugWidget),
        matchesGoldenFile('goldens/festo/vtug_idle.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('coils energised across both bytes', (tester) async {
      // Position 1 coil 14 (bit 0), position 4 coil 12 (bit 7), position 5
      // coil 14 (bit 8), position 8 coil 12 (bit 15) — one lamp at each
      // corner of the map, so a transposed byte or a flipped coil is
      // visible rather than plausible.
      const coils = (1 << 0) | (1 << 7) | (1 << 8) | (1 << 15);
      await tester.pumpWidget(host(drawing(
        VtugTerminal.read(struct(coils: coils), kinds: kinds()),
        CteuLink.live,
        name: 'ST303.A1',
      )));
      await expectLater(
        find.byType(VtugWidget),
        matchesGoldenFile('goldens/festo/vtug_energised.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('a mixed manifold — two positions blanked', (tester) async {
      await tester.pumpWidget(host(drawing(
        VtugTerminal.read(
          struct(coils: 1 << 2),
          kinds: kinds(blanks: {7, 8}),
        ),
        CteuLink.live,
        name: 'ST303.A1',
      )));
      await expectLater(
        find.byType(VtugWidget),
        matchesGoldenFile('goldens/festo/vtug_mixed.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('two valves held by hand', (tester) async {
      // Position 2 held at port 4 — coil 14 lit. Position 5 held at port 2,
      // and because that position is a monostable, port 2 is coil 14 held
      // OFF: an unlit lamp under an orange bar. A held valve that is not
      // energised is exactly the case an operator would otherwise read as
      // idle, so it belongs in a golden.
      final open = vtugApplyForce(
        forceMask: 0,
        forceValue: 0,
        kind: VtugValveKind.valve53Closed,
        position: 2,
        force: VtugForce.port4,
      );
      final both = vtugApplyForce(
        forceMask: open.mask,
        forceValue: open.value,
        kind: VtugValveKind.valve53Closed,
        position: 5,
        force: VtugForce.port2,
      );
      await tester.pumpWidget(host(drawing(
        VtugTerminal.read(
          struct(
            coils: both.value,
            forceMask: both.mask,
            forceValue: both.value,
          ),
          kinds: kinds(),
        ),
        CteuLink.live,
        name: 'ST303.A1',
      )));
      await expectLater(
        find.byType(VtugWidget),
        matchesGoldenFile('goldens/festo/vtug_held.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('nothing arriving — every lamp unknown, node included',
        (tester) async {
      await tester.pumpWidget(host(drawing(
        VtugTerminal.read(null, kinds: kinds()),
        CteuLink.dark,
        name: 'ST303.A1',
      )));
      await expectLater(
        find.byType(VtugWidget),
        matchesGoldenFile('goldens/festo/vtug_dark.png'),
      );
    }, skip: goldenSkipFlag);
  });

  group('the pane', () {
    Widget pane(
      VtugTerminal terminal, {
      bool commandable = true,
      bool dark = false,
    }) =>
        host(
          SizedBox(
            width: 380,
            // Keyed and given the theme's own surface: the golden captures
            // this box, so the image carries the background a pane actually
            // sits on. Capturing the body alone put a dark-theme pane on
            // white, which is exactly the image a dark golden exists to
            // avoid.
            child: Builder(
              builder: (context) => ColoredBox(
                key: const Key('pane-golden'),
                color: Theme.of(context).colorScheme.surface,
                child: SingleChildScrollView(
                  child: Material(
                    color: Colors.transparent,
                    child: VtugPaneBody(
                      terminal: terminal,
                      link: terminal.isUnknown
                          ? CteuLink.dark
                          : CteuLink.live,
                      onForce: commandable ? (_, __) {} : null,
                      onPush: commandable ? (_, __, ___) {} : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          dark: dark,
        );

    VtugTerminal populated() => VtugTerminal.read(
          struct(coils: 0x5, forceMask: 0x3, forceValue: 0x1),
          kinds: kinds(),
          descriptions: const [
            'Gate 1 lift',
            'Gate 1 clamp',
            'Blow-off',
            'Pusher extend',
            'Pusher lift',
            'Reject flap',
            'Lane divert',
          ],
        );

    testWidgets('a named manifold with two valves held', (tester) async {
      await tester.pumpWidget(pane(populated()));
      await expectLater(
        find.byKey(const Key('pane-golden')),
        matchesGoldenFile('goldens/festo/vtug_pane.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('the same pane on a dark station', (tester) async {
      // The dark variant is not decoration. Every low-emphasis edge in this
      // pane — the push buttons' borders, the segmented button's divider —
      // is the kind of detail that vanishes on base03 while the light image
      // stays perfectly readable.
      await tester.pumpWidget(pane(populated(), dark: true));
      await expectLater(
        find.byKey(const Key('pane-golden')),
        matchesGoldenFile('goldens/festo/vtug_pane_dark.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('no command keys — the force section says so', (tester) async {
      await tester.pumpWidget(pane(
        VtugTerminal.read(struct(), kinds: kinds()),
        commandable: false,
      ));
      await expectLater(
        find.byKey(const Key('pane-golden')),
        matchesGoldenFile('goldens/festo/vtug_pane_read_only.png'),
      );
    }, skip: goldenSkipFlag);
  });

  group('the valve schematics', () {
    /// Every symbol in every position it can be in, captioned.
    ///
    /// This grid is the review surface for `ValveSymbolPainter`, and no
    /// widget test can replace it: whether the flow arrows point the way
    /// the air goes, whether a closed centre reads as blocked rather than
    /// as empty, whether a spring looks like a spring — all of it is
    /// judged by eye or not at all.
    Widget grid({bool dark = false}) {
      Widget cell(String caption, ValveSymbolKind kind, int? active) => Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValveSymbol(kind: kind, active: active, height: 88),
                const SizedBox(height: 4),
                Text(caption, style: const TextStyle(fontSize: 11)),
              ],
            ),
          );

      return host(
        SizedBox(
          width: 720,
          child: Builder(
            builder: (context) => ColoredBox(
              key: const Key('symbol-grid'),
              color: Theme.of(context).colorScheme.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      cell('5/2 mono · port 4', ValveSymbolKind.fiveTwoMono, 0),
                      cell('5/2 mono · spring', ValveSymbolKind.fiveTwoMono, 1),
                      cell('5/2 mono · unknown',
                          ValveSymbolKind.fiveTwoMono, null),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      cell('5/3 closed · port 4',
                          ValveSymbolKind.fiveThreeClosed, 0),
                      cell('5/3 closed · centre',
                          ValveSymbolKind.fiveThreeClosed, 1),
                      cell('5/3 closed · port 2',
                          ValveSymbolKind.fiveThreeClosed, 2),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      cell('5/2 bistable · port 4',
                          ValveSymbolKind.fiveTwoBistable, 0),
                      cell('5/2 bistable · port 2',
                          ValveSymbolKind.fiveTwoBistable, 1),
                      cell('5/2 bistable · unknown',
                          ValveSymbolKind.fiveTwoBistable, null),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        dark: dark,
      );
    }

    testWidgets('every symbol in every position', (tester) async {
      await tester.pumpWidget(grid());
      await expectLater(
        find.byKey(const Key('symbol-grid')),
        matchesGoldenFile('goldens/festo/valve_symbols.png'),
      );
    }, skip: goldenSkipFlag);

    testWidgets('the same grid on a dark station', (tester) async {
      await tester.pumpWidget(grid(dark: true));
      await expectLater(
        find.byKey(const Key('symbol-grid')),
        matchesGoldenFile('goldens/festo/valve_symbols_dark.png'),
      );
    }, skip: goldenSkipFlag);
  });

  group('the bus node section', () {
    testWidgets('live and dark', (tester) async {
      await tester.pumpWidget(host(
        SizedBox(
          width: 380,
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                CteuPaneSection(link: CteuLink.live),
                Divider(),
                CteuPaneSection(link: CteuLink.dark),
              ],
            ),
          ),
        ),
      ));
      await expectLater(
        find.byType(Column).first,
        matchesGoldenFile('goldens/festo/cteu_section.png'),
      );
    }, skip: goldenSkipFlag);
  });
}
