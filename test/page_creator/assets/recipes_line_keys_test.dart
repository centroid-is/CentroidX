// One recipes button, one key per line.
//
// The asset was written against a legacy shape: a single node holding an
// ARRAY of line recipes, which is why the line pills are numbered by array
// position and why "Send values" wrote the whole array back. Current PLCs
// publish a separate recipe struct per station, so one key cannot reach them
// all -- and writing an array would rewrite every other line.

import 'dart:convert';

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

  group('what the dialog calls a line and a group', () {
    // Both words are the page's, not the code's: "Product" is right for one
    // plant and wrong for the next, and "add an s" is not a rule most
    // languages keep, so each has a plural of its own.
    test('defaults to Line and Product', () {
      final c = RecipesConfig(key: '', label: 'Line');
      expect(c.lineNoun, 'Line');
      expect(c.lineNounPlural, 'Lines');
      expect(c.groupNoun, 'Product');
      expect(c.groupNounPlural, 'Products');
    });

    test('an empty plural adds an s to the singular', () {
      final c = RecipesConfig(key: '', label: 'Belt', groupLabel: 'Batch');
      expect(c.lineNounPlural, 'Belts');
      expect(c.groupNounPlural, 'Batchs',
          reason: 'wrong English, which is exactly why the plural is a field '
              'of its own and not a rule');
    });

    test('a plural that is set is used as it stands', () {
      final c = RecipesConfig(
        key: '',
        label: 'Lína',
        labelPlural: 'Línur',
        groupLabel: 'Vara',
        groupLabelPlural: 'Vörur',
      );
      expect(c.lineNounPlural, 'Línur');
      expect(c.groupNounPlural, 'Vörur');
    });

    test('a blank word falls back rather than printing nothing', () {
      final c = RecipesConfig(key: '', label: '  ', groupLabel: '');
      expect(c.lineNoun, 'Line');
      expect(c.groupNoun, 'Product');
    });

    test('a config written before the names existed still loads', () {
      final back = RecipesConfig.fromJson(<String, dynamic>{
        'asset_name': 'RecipesConfig',
        'coordinates': {'x': 0.1, 'y': 0.1},
        'size': {'width': 0.055, 'height': 0.05},
        'label': 'Line',
        'key': '',
        'keys': ['line_a.recipe', 'line_b.recipe'],
      });
      expect(back.groupNoun, 'Product');
      expect(back.lineNounPlural, 'Lines');
    });

    test('a config saved with the short-lived one-recipe flag still loads', () {
      // `unifiedRecipe` lived on an unmerged branch for a day; a page saved
      // from that build must not fail to open now it is gone.
      final back = RecipesConfig.fromJson(<String, dynamic>{
        'asset_name': 'RecipesConfig',
        'coordinates': {'x': 0.1, 'y': 0.1},
        'size': {'width': 0.055, 'height': 0.05},
        'label': 'Line',
        'key': '',
        'keys': ['line_a.recipe'],
        'unifiedRecipe': true,
      });
      expect(back.lineKeys, ['line_a.recipe']);
    });

    test('round-trips', () {
      final c = RecipesConfig(
        key: '',
        label: 'Lína',
        labelPlural: 'Línur',
        groupLabel: 'Vara',
        groupLabelPlural: 'Vörur',
      );
      final back = RecipesConfig.fromJson(
          jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(back.groupNounPlural, 'Vörur');
      expect(back.lineNounPlural, 'Línur');
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
