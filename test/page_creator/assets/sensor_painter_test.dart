
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/page_creator/assets/sensor_painter.dart';
import '../../helpers/golden_platform.dart';

/// Tests for the three sensor `CustomPainter` subclasses defined in
/// `lib/page_creator/assets/sensor_painter.dart` and the `Asset.text` routing
/// on [SensorConfig] (the painters no longer draw the label themselves —
/// `AssetStack` paints it outside the rotated subtree via `Asset.text`).
///
/// Test groups:
///   - `shouldRepaint contract` — pure unit tests covering the cross-kind
///     guard (Pitfall 3) plus per-field equality. No goldens, no canvas.
///   - `Golden matrix` — the 8-state colour matrix from UI-SPEC §Test
///     Coverage Contract plus a 9th stale-state golden.
///   - `SensorConfig.text routes through to tag` — locks the new contract
///     that supersedes the in-painter label machinery.
void main() {
  group('shouldRepaint contract', () {
    // ── Cross-kind safety (Pitfall 3) ────────────────────────────────────
    // A painter swap across kinds (e.g. SensorKind.redLight →
    // SensorKind.opticField) must trigger a repaint, otherwise the canvas
    // keeps drawing the old kind's geometry. The runtimeType guard inside
    // shouldRepaint is what enforces this.

    test(
        'RedLightBeamPainter.shouldRepaint(OpticFieldPainter) returns true (cross-runtimeType — Pitfall 3)',
        () {
      // Single-line cross-kind expectations for grep matching.
      expect(RedLightBeamPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey).shouldRepaint(OpticFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey)), isTrue);
      expect(OpticFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey).shouldRepaint(RedLightBeamPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey)), isTrue);
    });

    test(
        'InductiveFieldPainter.shouldRepaint(RedLightBeamPainter) returns true (cross-runtimeType — Pitfall 3)',
        () {
      expect(InductiveFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey).shouldRepaint(RedLightBeamPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey)), isTrue);
      expect(RedLightBeamPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey).shouldRepaint(InductiveFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey)), isTrue);
    });

    test(
        'OpticFieldPainter.shouldRepaint(InductiveFieldPainter) returns true (cross-runtimeType — Pitfall 3)',
        () {
      expect(OpticFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey).shouldRepaint(InductiveFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey)), isTrue);
      expect(InductiveFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey).shouldRepaint(OpticFieldPainter(isActive: true, activeColor: Colors.green, inactiveColor: Colors.grey)), isTrue);
    });

    // ── Per-field equality: RedLightBeamPainter ──────────────────────────

    test('RedLightBeamPainter shouldRepaint TRUE when isActive flips', () {
      final a = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = RedLightBeamPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('RedLightBeamPainter shouldRepaint TRUE when activeColor changes',
        () {
      final a = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.red,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('RedLightBeamPainter shouldRepaint TRUE when inactiveColor changes',
        () {
      final a = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.black);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('RedLightBeamPainter shouldRepaint TRUE when isStale changes', () {
      final a = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey,
          isStale: true);
      expect(a.shouldRepaint(b), isTrue);
    });

    test(
        'RedLightBeamPainter shouldRepaint FALSE when all inputs identical (deterministic)',
        () {
      final a = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = RedLightBeamPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isFalse);
    });

    // ── Per-field equality: OpticFieldPainter ────────────────────────────

    test('OpticFieldPainter shouldRepaint TRUE when isActive flips', () {
      final a = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = OpticFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('OpticFieldPainter shouldRepaint TRUE when activeColor changes', () {
      final a = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.red,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('OpticFieldPainter shouldRepaint TRUE when inactiveColor changes',
        () {
      final a = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.black);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('OpticFieldPainter shouldRepaint TRUE when isStale changes', () {
      final a = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey,
          isStale: true);
      expect(a.shouldRepaint(b), isTrue);
    });

    test(
        'OpticFieldPainter shouldRepaint FALSE when all inputs identical (deterministic)',
        () {
      final a = OpticFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = OpticFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isFalse);
    });

    // ── Per-field equality: InductiveFieldPainter ────────────────────────

    test('InductiveFieldPainter shouldRepaint TRUE when isActive flips', () {
      final a = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = InductiveFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('InductiveFieldPainter shouldRepaint TRUE when activeColor changes',
        () {
      final a = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.red,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isTrue);
    });

    test(
        'InductiveFieldPainter shouldRepaint TRUE when inactiveColor changes',
        () {
      final a = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.black);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('InductiveFieldPainter shouldRepaint TRUE when isStale changes', () {
      final a = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = InductiveFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey,
          isStale: true);
      expect(a.shouldRepaint(b), isTrue);
    });

    test(
        'InductiveFieldPainter shouldRepaint FALSE when all inputs identical (deterministic)',
        () {
      final a = InductiveFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      final b = InductiveFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey);
      expect(a.shouldRepaint(b), isFalse);
    });
  });

  // ── Optic housing fill ──────────────────────────────────────────────────
  // The housing rectangle carries the output bit as well as the cone does:
  // idle light grey while the sensor is clear, the active colour while it
  // reports detection. Asserted on the recorded paint colour rather than on a
  // golden so the rule is readable when the golden churns for other reasons.

  group('OpticFieldPainter housing fill follows the output', () {
    Color housingFillOf(OpticFieldPainter painter) {
      final canvas = _RectColorRecorder();
      painter.paint(canvas, const Size(256, 128));
      // Fill first, border second — see OpticFieldPainter.paint.
      return canvas.rectColors.first;
    }

    test('clear paints the idle light grey', () {
      expect(
        housingFillOf(OpticFieldPainter(
          isActive: false,
          activeColor: Colors.green,
          inactiveColor: Colors.grey.shade400,
        )),
        isSameColorAs(Colors.grey.shade300),
      );
    });

    test('detected paints the active colour', () {
      expect(
        housingFillOf(OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey.shade400,
        )),
        isSameColorAs(Colors.green),
      );
    });

    test('stale outranks the output bit', () {
      expect(
        housingFillOf(OpticFieldPainter(
          isActive: true,
          activeColor: Colors.green,
          inactiveColor: Colors.grey.shade400,
          isStale: true,
        )),
        isSameColorAs(Colors.grey),
      );
    });
  });

  // ── Golden matrix ───────────────────────────────────────────────────────
  // The 8-state colour matrix from `01-UI-SPEC.md` §Test Coverage Contract,
  // plus a 9th stale-state golden (which sits outside the matrix per the
  // spec but lives here for proximity).
  //
  // Canvas: 256×128 — 2:1 ratio matches the red-light pair geometry and
  // gives the optic-field cone enough horizontal room to fan out.
  //
  // Locked colour values across every test (matches `SensorConfig` defaults):
  //   activeColor   = Colors.green
  //   inactiveColor = Colors.grey.shade400
  //
  // Polarity (tests #3, #4) is a pure pre-painter inversion — visually these
  // are identical to tests #1 and #2 respectively, but each has its own
  // golden file so the matrix file-name set is explicit and complete.
  //
  // Skipped on non-macOS to match the existing project convention in
  // `conveyor_gate_golden_test.dart` (goldenSkip guard) — Pitfall 6
  // determinism: goldens are captured on macOS only.
  //
  // Each test inlines its own `SizedBox(width: 256, height: 128)` and a
  // `RepaintBoundary` wrapper so the matched widget is the painter's own
  // pixels (not the surrounding Material chrome). The repeated shape is
  // intentional — it's what the plan calls for ("apply uniformly so future
  // maintainers see one shape").
  const goldenKey = Key('sensor_golden');

  group('Golden matrix',
      skip: goldenSkip, () {
    // 1. Red light — clear (isActive=false, normal polarity)
    testWidgets('red_light_clear', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: RedLightBeamPainter(
                    isActive: false,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/red_light_clear.png'),
      );
    });

    // 2. Red light — broken (isActive=true, normal polarity)
    testWidgets('red_light_broken', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: RedLightBeamPainter(
                    isActive: true,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/red_light_broken.png'),
      );
    });

    // 3. Red light — clear with polarity inverted (visually identical to #1).
    //    Polarity inversion happens before the painter — `isActive` is the
    //    already-inverted bool. The duplicate golden file exists to lock
    //    the file-name set per the UI-SPEC matrix.
    testWidgets('red_light_clear_inverted', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: RedLightBeamPainter(
                    isActive: false,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/red_light_clear_inverted.png'),
      );
    });

    // 4. Red light — broken with polarity inverted (visually identical to #2)
    testWidgets('red_light_broken_inverted', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: RedLightBeamPainter(
                    isActive: true,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/red_light_broken_inverted.png'),
      );
    });

    // 5. Optic field — inactive
    testWidgets('optic_field_inactive', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: OpticFieldPainter(
                    isActive: false,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/optic_field_inactive.png'),
      );
    });

    // 6. Optic field — active (filled α=0.40 with outline visible)
    testWidgets('optic_field_active', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: OpticFieldPainter(
                    isActive: true,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/optic_field_active.png'),
      );
    });

    // 7. Inductive field — inactive
    testWidgets('inductive_field_inactive', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: InductiveFieldPainter(
                    isActive: false,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/inductive_field_inactive.png'),
      );
    });

    // 8. Inductive field — active (filled α=0.40)
    testWidgets('inductive_field_active', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: InductiveFieldPainter(
                    isActive: true,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/inductive_field_active.png'),
      );
    });

    // 9. Stale — entire glyph rendered grey. Kind irrelevant per UI-SPEC §9;
    //    redLight chosen. `isActive=true` is intentional: proves the stale
    //    flag overrides the active-colour mapping.
    testWidgets('stale', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: goldenKey,
              child: SizedBox(
                width: 256,
                height: 128,
                child: CustomPaint(
                  painter: RedLightBeamPainter(
                    isActive: true,
                    activeColor: Colors.green,
                    inactiveColor: Colors.grey.shade400,
                    isStale: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/sensor/stale.png'),
      );
    });

  });

  // ---------------------------------------------------------------------------
  // SensorConfig routes its tag through Asset.text so AssetStack paints the
  // label outside the rotated subtree (the same path Button uses). Without
  // this routing, the sensor painter would have to draw the label itself
  // inside the rotated geometry — and at angle 180° the label would be
  // painted at the screen-top with upside-down glyphs (the bug this contract
  // supersedes the obsolete `counterRotateLabel` hack for).
  //
  // The contract here is purely on the SensorConfig model: `text` is an
  // alias of `tag`. AssetStack reads `asset.text` and `asset.labelColor` —
  // see `lib/pages/page_view.dart` (label rendering block around line 420).
  // ---------------------------------------------------------------------------
  group('SensorConfig.text routes through to tag (label-via-AssetStack contract)', () {
    test('Asset.text returns the tag value (so AssetStack paints it)', () {
      // showTag gates the alias: the canvas label is opt-in (off by
      // default), while the side pane reads `tag` directly.
      final config = SensorConfig(tag: 'PE-101A', showTag: true);
      expect(config.text, 'PE-101A',
          reason: 'SensorConfig.text must expose `tag` so the page-view '
              'AssetStack picks it up via the Asset.text contract — same '
              'path Button uses for its caption.');
    });

    test('Setting Asset.text writes through to tag (load-path tolerance)', () {
      final config = SensorConfig(tag: 'PE-101A');
      config.text = 'NEW-TAG';
      expect(config.tag, 'NEW-TAG',
          reason: 'Setting `text` must update `tag` so JSON deserialization '
              'paths (which call `..text = json[\'text\']`) keep working.');
    });

    test('Default SensorConfig.text is null when no tag is set', () {
      final config = SensorConfig();
      expect(config.text, isNull,
          reason: 'An unconfigured tag must yield a null text — AssetStack '
              'short-circuits the label render block on null/empty text.');
    });
  });
}

/// A canvas that keeps the colour of every `drawRect` and ignores the rest, so
/// a painter's fill choice can be asserted directly instead of read off a
/// rasterised golden.
class _RectColorRecorder implements Canvas {
  final List<Color> rectColors = <Color>[];

  @override
  void drawRect(Rect rect, Paint paint) => rectColors.add(paint.color);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
