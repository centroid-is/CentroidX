// One recipes button, one key per line.
//
// The asset was written against a legacy shape: a single node holding an
// ARRAY of line recipes, which is why the line pills are numbered by array
// position and why "Send values" wrote the whole array back. Current PLCs
// publish a separate recipe struct per station, so one key cannot reach them
// all -- and writing an array would rewrite every other line.

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/recipes.dart';

void main() {
  group('lineKeys', () {
    test('uses the per-line keys when they are set', () {
      final c = RecipesConfig(key: '', label: 'Line', keys: const [
        'line_a.recipe',
        'line_b.recipe',
        'line_c.recipe',
      ]);
      expect(c.lineKeys, ['line_a.recipe', 'line_b.recipe', 'line_c.recipe']);
      expect(c.perLineKeys, isTrue);
    });

    test('falls back to the legacy single key', () {
      final c = RecipesConfig(key: 'LineRecipes', label: 'Line');
      expect(c.lineKeys, ['LineRecipes']);
      expect(c.perLineKeys, isFalse);
    });

    test('per-line keys win over a leftover single key', () {
      final c = RecipesConfig(
          key: 'LineRecipes', label: 'Line', keys: const ['line_a.recipe']);
      expect(c.lineKeys, ['line_a.recipe']);
      expect(c.perLineKeys, isTrue);
    });

    test('an unconfigured asset has no lines', () {
      expect(RecipesConfig(key: '', label: 'Line').lineKeys, isEmpty);
      expect(RecipesConfig.preview().lineKeys, isEmpty);
    });
  });

  group('recipesBucket', () {
    // Saved presets are keyed by this. It must not move when an asset is
    // migrated from the single key to per-line keys, or the recipes defined
    // beforehand are orphaned.
    test('stays on the legacy key when one is present', () {
      final c = RecipesConfig(
          key: 'LineRecipes', label: 'Line', keys: const ['line_a.recipe']);
      expect(c.recipesBucket, 'LineRecipes');
    });

    test('uses the first line key when there is no legacy key', () {
      final c = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a.recipe', 'line_b.recipe']);
      expect(c.recipesBucket, 'line_a.recipe');
    });

    test('is empty when nothing is configured', () {
      expect(RecipesConfig(key: '', label: 'Line').recipesBucket, '');
    });
  });

  group('serialisation', () {
    // toJson/fromJson are exercised in each direction rather than round-trip:
    // BaseAsset.toJson leaves `coordinates` as an object, so feeding its
    // output straight back into fromJson fails for every asset type, not just
    // this one.
    Map<String, dynamic> asJson(Map<String, dynamic> extra) => <String, dynamic>{
          'asset_name': 'RecipesConfig',
          'coordinates': {'x': 0.1, 'y': 0.1},
          'size': {'width': 0.055, 'height': 0.05},
          'label': 'Line',
          ...extra,
        };

    test('writes the key list', () {
      final c = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a.recipe', 'line_b.recipe']);
      expect(c.toJson()['keys'], ['line_a.recipe', 'line_b.recipe']);
    });

    test('reads the key list', () {
      final back = RecipesConfig.fromJson(
          asJson({'key': '', 'keys': ['line_a.recipe', 'line_b.recipe']}));
      expect(back.keys, ['line_a.recipe', 'line_b.recipe']);
      expect(back.perLineKeys, isTrue);
    });

    test('a config written before keys existed still loads', () {
      final back = RecipesConfig.fromJson(asJson({'key': 'LineRecipes'}));
      expect(back.keys, isEmpty);
      expect(back.lineKeys, ['LineRecipes']);
      expect(back.perLineKeys, isFalse);
    });

    test('the decoded key list is growable, so the editor can add a line', () {
      final back =
          RecipesConfig.fromJson(asJson({'key': '', 'keys': <String>[]}));
      expect(() => back.keys = [...back.keys, 'line_a.recipe'], returnsNormally);
      expect(back.lineKeys, ['line_a.recipe']);
    });
  });

  group('unifiedRecipe', () {
    // Additive and off by default: a page saved before the flag existed has
    // to deserialize into exactly the behaviour it had.
    test('is off unless a config says otherwise', () {
      expect(RecipesConfig(key: '', label: 'Line').unifiedRecipe, isFalse);
      expect(RecipesConfig.preview().unifiedRecipe, isFalse);
    });

    test('a config written before the flag existed still loads, and is off',
        () {
      final back = RecipesConfig.fromJson(<String, dynamic>{
        'asset_name': 'RecipesConfig',
        'coordinates': {'x': 0.1, 'y': 0.1},
        'size': {'width': 0.055, 'height': 0.05},
        'label': 'Line',
        'key': '',
        'keys': ['line_a.recipe', 'line_b.recipe'],
      });
      expect(back.unifiedRecipe, isFalse);
      expect(back.unified, isFalse);
    });

    test('round-trips when it is on', () {
      final c = RecipesConfig(
          key: '',
          label: 'Line',
          keys: const ['line_a.recipe'],
          unifiedRecipe: true);
      expect(c.toJson()['unifiedRecipe'], isTrue);
    });

    // It says "one recipe for every line", so without one node per line there
    // is nothing for it to mean.
    test('has no effect on the legacy single key', () {
      final c = RecipesConfig(
          key: 'LineRecipes', label: 'Line', unifiedRecipe: true);
      expect(c.perLineKeys, isFalse);
      expect(c.unified, isFalse);
    });

    test('is in force with per-line keys', () {
      final c = RecipesConfig(
          key: '',
          label: 'Line',
          keys: const ['line_a.recipe', 'line_b.recipe'],
          unifiedRecipe: true);
      expect(c.unified, isTrue);
    });

    // Presets were always one shared bucket. Turning the flag on must show
    // the recipes that are already there, not orphan them.
    test('does not move the recipe bucket', () {
      final off = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a.recipe', 'line_b.recipe']);
      final on = RecipesConfig(
          key: '',
          label: 'Line',
          keys: const ['line_a.recipe', 'line_b.recipe'],
          unifiedRecipe: true);
      expect(on.recipesBucket, off.recipesBucket);
    });
  });

  group('allKeys', () {
    // Whatever asks which keys a page depends on -- unused-key cleanup among
    // them -- reads allKeys. A list-valued key field must not be invisible to
    // it, or its keys look free to delete.
    test('reports every per-line key', () {
      final c = RecipesConfig(key: '', label: 'Line', keys: const [
        'line_a.recipe',
        'line_b.recipe',
        'line_c.recipe',
      ]);
      expect(c.allKeys, containsAll(<String>[
        'line_a.recipe',
        'line_b.recipe',
        'line_c.recipe',
      ]));
    });

    test('still reports the legacy single key', () {
      expect(RecipesConfig(key: 'LineRecipes', label: 'Line').allKeys,
          contains('LineRecipes'));
    });

    test('an empty entry in the list is not reported', () {
      final c = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a.recipe', '']);
      expect(c.allKeys, ['line_a.recipe']);
    });
  });
}
