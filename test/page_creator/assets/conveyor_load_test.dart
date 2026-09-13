import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';

/// The load a conveyor carries — [ConveyorLoad] — is a per-belt setting that
/// only shows up in paint, so everything here is either serialisation or a
/// recording of the ops the painter emits. The goldens
/// (`conveyor_load_golden_test.dart`) are what say it looks right; these say
/// it is wired up at all, and they run on every platform rather than only
/// where goldens render.
void main() {
  group('ConveyorLoad configuration', () {
    test('a page saved before the setting existed still draws boxes', () {
      // The whole back-compat claim: a page whose JSON has no `load` key,
      // built by removing it from a saved conveyor rather than by hand, so
      // the rest of the document stays whatever the schema actually is.
      final saved = ConveyorConfig(key: 'CN01').toJson()..remove('load');
      expect(saved.containsKey('load'), isFalse);
      final config = ConveyorConfig.fromJson(saved);
      expect(config.load, isNull);
      expect(config.effectiveLoad, ConveyorLoad.box);
    });

    test('the chosen load survives a save/load round trip', () {
      for (final load in ConveyorLoad.values) {
        final restored = ConveyorConfig.fromJson(
            ConveyorConfig(key: 'CN01', load: load).toJson());
        expect(restored.load, load);
        expect(restored.effectiveLoad, load);
      }
    });

    test('a roller conveyor carries the same loads', () {
      final restored = RollerConveyorConfig.fromJson(
          RollerConveyorConfig(key: 'CN02', load: ConveyorLoad.euroPallet)
              .toJson());
      expect(restored.effectiveLoad, ConveyorLoad.euroPallet);
      // The band style stays the asset type's own — picking a load must not
      // quietly turn a roller bed back into a solid one.
      expect(restored.style, ConveyorStyle.roller);
    });

    test('changing the load repaints', () {
      ConveyorPainter painter(ConveyorLoad load) => ConveyorPainter(
            color: Colors.green,
            batches: const {},
            angle: 0,
            load: load,
          );
      expect(
          painter(ConveyorLoad.euroPallet)
              .shouldRepaint(painter(ConveyorLoad.box)),
          isTrue);
      expect(
          painter(ConveyorLoad.box).shouldRepaint(painter(ConveyorLoad.box)),
          isFalse);
    });
  });

  group('Euro pallet painting', () {
    ConveyorPainter painter({
      required ConveyorLoad load,
      required Map<String, Batch> batches,
      ConveyorPathGeometry? geometry,
    }) =>
        ConveyorPainter(
          color: Colors.green,
          batches: batches,
          angle: 0,
          load: load,
          geometry: geometry,
        );

    const beltSize = Size(300, 40);

    test('a box load draws one flat rectangle, a pallet draws timber', () {
      final box = _RecordingCanvas();
      painter(load: ConveyorLoad.box, batches: {'0': Batch(start: 0.3, end: 0.6)})
          .paint(box, beltSize);
      // Nothing about the plain box changed: no clip, no gradients.
      expect(box.ops.whereType<_Clip>(), isEmpty);
      expect(box.ops.whereType<_Draw>().where((d) => d.shaded), isEmpty);

      final pallet = _RecordingCanvas();
      painter(
              load: ConveyorLoad.euroPallet,
              batches: {'0': Batch(start: 0.3, end: 0.6)})
          .paint(pallet, beltSize);
      final deck = pallet.clipped();
      // Five planed deck boards over three cross boards is what makes it a
      // EUR pallet rather than a brown rectangle.
      expect(deck.whereType<_Draw>().where((d) => d.shaded && d.rounded).length,
          5);
      expect(deck.whereType<_Draw>().where((d) => d.shaded && !d.rounded).length,
          3);
    });

    test('the pallet is drawn in wood, in every theme', () {
      final canvas = _RecordingCanvas();
      painter(
              load: ConveyorLoad.euroPallet,
              batches: {'0': Batch(start: 0.3, end: 0.6)})
          .paint(canvas, beltSize);
      final solids = canvas
          .clipped()
          .whereType<_Draw>()
          .where((d) => !d.shaded && d.color.a == 1.0);
      expect(solids, isNotEmpty);
      for (final draw in solids) {
        // Brown is warm and unsaturated-toward-blue: more red than green,
        // more green than blue. The load is a physical object, so it does
        // not take a state colour and does not follow the theme — this is
        // the assertion that says so without pinning exact swatches.
        expect(draw.color.r, greaterThan(draw.color.g),
            reason: '${draw.color} is not a brown');
        expect(draw.color.g, greaterThan(draw.color.b),
            reason: '${draw.color} is not a brown');
      }
    });

    test('a pallet sliding onto the belt keeps its full length', () {
      final canvas = _RecordingCanvas();
      // A third on, two thirds still upstream.
      painter(
              load: ConveyorLoad.euroPallet,
              batches: {'0': Batch(start: -0.2, end: 0.1)})
          .paint(canvas, beltSize);
      final deck = canvas.clipped().whereType<_Draw>().toList();
      expect(deck, isNotEmpty, reason: 'the pallet must be drawn at all');
      // Rigid: drawn at 0.3 of the belt long and trimmed by the clip, not
      // squashed into the 0.1 that is on the belt.
      final width = deck
          .map((d) => d.rect.width)
          .reduce((a, b) => a > b ? a : b);
      expect(width, closeTo(beltSize.width * 0.3, 0.5));
      expect(deck.first.rect.left, lessThan(0),
          reason: 'the part still upstream hangs off the belt and is clipped');
    });

    test('a pallet in a bend stays rigid instead of bending with the belt',
        () {
      const turnSize = Size(220, 150);
      final geometry = ConveyorPathGeometry.build(
        [ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5)],
        turnSize,
        thicknessFactor: 0.3,
      );

      final box = _RecordingCanvas();
      painter(
        load: ConveyorLoad.box,
        batches: {'0': Batch(start: 0.45, end: 0.65)},
        geometry: geometry,
      ).paint(box, turnSize);

      final pallet = _RecordingCanvas();
      painter(
        load: ConveyorLoad.euroPallet,
        batches: {'0': Batch(start: 0.45, end: 0.65)},
        geometry: geometry,
      ).paint(pallet, turnSize);

      // A box batch is a band bent along the centerline — a path. A pallet
      // is a rectangle laid on the belt at the angle it has reached, so it
      // arrives under a rotate and as rects.
      expect(box.ops.whereType<_Rotate>(), isEmpty);
      expect(pallet.ops.whereType<_Rotate>(), isNotEmpty);
      expect(pallet.clipped().whereType<_Draw>(), isNotEmpty);
    });
  });
}

// ── Canvas recording ─────────────────────────────────────────────────────
//
// Only the calls these tests reason about are recorded; `noSuchMethod`
// swallows the rest.

sealed class _Op {}

class _Clip implements _Op {}

class _Rotate implements _Op {}

class _Restore implements _Op {}

class _Draw implements _Op {
  final Rect rect;
  final bool rounded;
  final bool shaded;
  final Color color;
  _Draw(this.rect, this.rounded, Paint paint)
      : shaded = paint.shader != null,
        color = paint.color;
}

class _RecordingCanvas implements Canvas {
  final ops = <_Op>[];

  /// The ops the pallet emits: everything between the clip that trims it to
  /// the belt and the restore that lifts that clip. The belt band itself is
  /// painted before any clip, so this is exactly the load.
  Iterable<_Op> clipped() {
    final start = ops.indexWhere((op) => op is _Clip);
    if (start < 0) return const [];
    final end = ops.indexWhere((op) => op is _Restore, start);
    return ops.sublist(start + 1, end < 0 ? ops.length : end);
  }

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) => ops.add(_Clip());

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) => ops.add(_Clip());

  @override
  void rotate(double radians) => ops.add(_Rotate());

  @override
  void restore() => ops.add(_Restore());

  @override
  void drawRRect(RRect rrect, Paint paint) =>
      ops.add(_Draw(rrect.outerRect, true, paint));

  @override
  void drawRect(Rect rect, Paint paint) => ops.add(_Draw(rect, false, paint));

  @override
  void noSuchMethod(Invocation invocation) {}
}
