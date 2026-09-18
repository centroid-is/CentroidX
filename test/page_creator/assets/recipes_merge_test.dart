// Sending one recipe to several lines that do NOT share a struct shape.
//
// A plant's lines are not obliged to be identical, and in practice they are
// not: one may drive two belts where its neighbours drive three. So "one
// recipe for every line" cannot be a whole-struct copy — writing a
// three-belt recipe onto a two-belt line either fails outright or is
// accepted with a silently different meaning.
//
// The contract these tests hold the merge to:
//
//   * the value written is the TARGET's shape, never the recipe's;
//   * a member the target does not have is skipped, never added;
//   * an array keeps the target's length, never the recipe's;
//   * a leaf is written only when both sides are the same kind of value,
//     and lands in the target's own type;
//   * what did not land is reported, per line, in words.

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/recipes.dart';

/// A scalar.
DynamicValue d(dynamic value) => DynamicValue(value: value);

/// A struct, in declaration order.
DynamicValue obj(Map<String, DynamicValue> members) {
  final v = DynamicValue();
  members.forEach((name, member) => v[name] = member);
  return v;
}

/// An array.
DynamicValue arr(List<DynamicValue> items) {
  final v = DynamicValue()..value = <DynamicValue>[];
  for (var i = 0; i < items.length; i++) {
    v[i] = items[i];
  }
  return v;
}

/// A belt sub-struct, the nested half of the shape under test.
DynamicValue belt({
  double stopDistance = 200.0,
  double overrun = 1000.0,
  bool bypassGate = false,
}) =>
    obj({
      'stopDistance': d(stopDistance),
      'overrun': d(overrun),
      'bypassGate': d(bypassGate),
    });

/// A line recipe with [belts] belts.
DynamicValue line({
  double gapLength = 2000.0,
  double runLength = 1200.0,
  bool bypassTrim = false,
  int belts = 3,
}) =>
    obj({
      'gapLength': d(gapLength),
      'runLength': d(runLength),
      'bypassTrim': d(bypassTrim),
      'belts': arr([for (var i = 0; i < belts; i++) belt()]),
    });

void main() {
  group('mergeRecipeInto, same shape on both sides', () {
    test('every leaf lands and the result is the target with new values', () {
      final target = line(gapLength: 2000, belts: 3);
      final recipe = line(gapLength: 2500, bypassTrim: true, belts: 3);

      final result = mergeRecipeInto(target, recipe);

      expect(result.skipped, isEmpty);
      expect(result.untouched, isEmpty);
      expect(result.written, hasLength(result.offered));
      expect(result.merged['gapLength'].asDouble, 2500);
      expect(result.merged['bypassTrim'].asBool, isTrue);
      expect(result.merged['belts'].asArray, hasLength(3));
    });

    test('the target itself is not mutated', () {
      final target = line(gapLength: 2000);
      mergeRecipeInto(target, line(gapLength: 2500));
      expect(target['gapLength'].asDouble, 2000);
    });
  });

  group('members the target does not have', () {
    test('are skipped rather than added', () {
      final target = obj({'gapLength': d(2000.0)});
      final recipe = obj({'gapLength': d(2500.0), 'runLength': d(1200.0)});

      final result = mergeRecipeInto(target, recipe);

      expect(result.merged.contains('runLength'), isFalse,
          reason: 'the write must never grow the target');
      expect(result.merged.asObject.keys, ['gapLength']);
      expect(result.written, ['gapLength']);
      expect(result.skipped,
          [const RecipeSkip('runLength', RecipeSkipReason.notPresent)]);
    });

    test('a whole absent sub-struct counts every leaf it would have set', () {
      final target = obj({'gapLength': d(2000.0)});
      final recipe = obj({'gapLength': d(2500.0), 'belts': arr([belt()])});

      final result = mergeRecipeInto(target, recipe);

      expect(result.written, ['gapLength']);
      expect(
          result.skipped.map((s) => s.path),
          containsAll(<String>[
            'belts[0].stopDistance',
            'belts[0].overrun',
            'belts[0].bypassGate',
          ]));
      expect(result.offered, 4);
    });
  });

  group('arrays keep the target length', () {
    test('a longer recipe does not lengthen a shorter line', () {
      final target = line(belts: 2);
      final recipe = line(belts: 3);

      final result = mergeRecipeInto(target, recipe);

      expect(result.merged['belts'].asArray, hasLength(2));
      expect(result.skipped.map((s) => s.path),
          containsAll(<String>['belts[2].stopDistance', 'belts[2].overrun']));
      expect(
          result.skipped
              .where((s) => s.reason == RecipeSkipReason.notPresent)
              .map((s) => s.path),
          everyElement(startsWith('belts[2]')));
    });

    test('a shorter recipe does not shorten a longer line, and says so', () {
      final target = line(belts: 3);
      final recipe = line(belts: 2);

      final result = mergeRecipeInto(target, recipe);

      expect(result.merged['belts'].asArray, hasLength(3));
      expect(result.untouched, contains('belts[2]'));
      expect(result.skipped, isEmpty);
    });

    test('the elements that do line up are written', () {
      final target = line(belts: 2);
      final recipe = line(belts: 3);
      recipe['belts'][0]['overrun'] = DynamicValue(value: 400.0);

      final result = mergeRecipeInto(target, recipe);

      expect(result.merged['belts'][0]['overrun'].asDouble, 400);
      expect(result.merged['belts'][1]['overrun'].asDouble, 1000);
    });
  });

  group('leaves are written in the target type', () {
    test('an integer preset lands in a real member as a real', () {
      // A preset that round-tripped through JSON can come back as an int
      // where the PLC member is a REAL. Coercing to the target's type is what
      // keeps such a recipe usable instead of silently skipped.
      final target = obj({'gapLength': d(2000.0)});
      final result = mergeRecipeInto(target, obj({'gapLength': d(2500)}));

      expect(result.written, ['gapLength']);
      expect(result.merged['gapLength'].value, isA<double>());
      expect(result.merged['gapLength'].asDouble, 2500);
    });

    test('a real preset lands in an integer member as an integer', () {
      final target = obj({'count': d(2)});
      final result = mergeRecipeInto(target, obj({'count': d(5.0)}));

      expect(result.merged['count'].value, isA<int>());
      expect(result.merged['count'].asInt, 5);
    });

    test('a boolean is not written over a number', () {
      final target = obj({'gapLength': d(2000.0)});
      final result = mergeRecipeInto(target, obj({'gapLength': d(true)}));

      expect(result.written, isEmpty);
      expect(result.merged['gapLength'].asDouble, 2000);
      expect(result.skipped,
          [const RecipeSkip('gapLength', RecipeSkipReason.shapeDiffers)]);
    });

    test('a scalar is not written over a struct', () {
      final target = obj({'belts': arr([belt()])});
      final result = mergeRecipeInto(target, obj({'belts': d(3)}));

      expect(result.merged['belts'].isArray, isTrue);
      expect(result.skipped,
          [const RecipeSkip('belts', RecipeSkipReason.shapeDiffers)]);
    });

    test('an empty recipe member sets nothing', () {
      final target = obj({'gapLength': d(2000.0)});
      final result = mergeRecipeInto(target, obj({'gapLength': DynamicValue()}));

      expect(result.merged['gapLength'].asDouble, 2000);
      expect(result.skipped,
          [const RecipeSkip('gapLength', RecipeSkipReason.noValue)]);
    });

    test('a member the line has never carried a value in takes the recipe',
        () {
      final target = obj({'gapLength': DynamicValue()});
      final result = mergeRecipeInto(target, obj({'gapLength': d(2500.0)}));

      expect(result.written, ['gapLength']);
      expect(result.merged['gapLength'].asDouble, 2500);
    });
  });

  group('describeMerge', () {
    test('says so plainly when everything landed', () {
      final result = mergeRecipeInto(line(belts: 3), line(belts: 3));
      expect(describeMerge(result), startsWith('all 12 values written'));
    });

    test('counts what landed and names what did not', () {
      final result = mergeRecipeInto(line(belts: 2), line(belts: 3));
      final text = describeMerge(result);
      expect(text, startsWith('9 of 12 values written'));
      expect(text, contains('not present'));
      expect(text, contains('belts[2]'));
    });

    test('names what it left alone on a longer line', () {
      final result = mergeRecipeInto(line(belts: 3), line(belts: 2));
      expect(describeMerge(result), contains('belts[2] left unchanged'));
    });

    test('a long list of paths is summarised rather than spilled', () {
      final target = obj({'a': d(1)});
      final recipe = obj({
        'a': d(2),
        for (var i = 0; i < 6; i++) 'missing$i': d(i),
      });
      final text = describeMerge(mergeRecipeInto(target, recipe));
      expect(text, contains('and 3 more'));
    });
  });

  group('flattenRecipeShape', () {
    test('indents a nested struct instead of nesting a second scroll', () {
      final rows = flattenRecipeShape([line(belts: 1)]);
      final labels = rows.map((r) => '${' ' * r.depth}${r.label}').toList();

      expect(labels, [
        'Gap Length',
        'Run Length',
        'Bypass Trim',
        'Belts',
        ' Item 1',
        '  Stop Distance',
        '  Overrun',
        '  Bypass Gate',
      ]);
    });

    test('a group row is marked as one so its cells do not read as values',
        () {
      final rows = flattenRecipeShape([line(belts: 1)]);
      expect(rows.firstWhere((r) => r.label == 'Belts').kind,
          RecipeRowKind.array);
      expect(rows.firstWhere((r) => r.label == 'Item 1').kind,
          RecipeRowKind.object);
      expect(rows.firstWhere((r) => r.label == 'Gap Length').isLeaf, isTrue);
    });

    test('the rows are the union of every source, longest array included', () {
      // The two-belt line must still get a row for the third belt, or the
      // difference between the lines is invisible in the table.
      final rows = flattenRecipeShape([line(belts: 2), line(belts: 3)]);
      expect(rows.where((r) => r.label == 'Item 3'), hasLength(1));
    });

    test('a member only one source has still gets a row', () {
      final rows = flattenRecipeShape([
        obj({'a': d(1)}),
        obj({'b': d(2)}),
      ]);
      expect(rows.map((r) => r.label), ['A', 'B']);
    });

    test('nulls — a line that has not reported — contribute no rows', () {
      final rows = flattenRecipeShape([null, obj({'a': d(1)}), null]);
      expect(rows.map((r) => r.label), ['A']);
    });

    test('nothing at all flattens to nothing', () {
      expect(flattenRecipeShape([null, null]), isEmpty);
      expect(flattenRecipeShape(const []), isEmpty);
    });
  });

  group('valueAtPath', () {
    test('finds a nested leaf', () {
      final value = valueAtPath(line(belts: 2), ['belts', 1, 'overrun']);
      expect(value?.asDouble, 1000);
    });

    test('answers null for a member this line does not have', () {
      // The cell renders this as "not present" — never as a blank and never
      // as a zero, both of which read as a setpoint.
      expect(valueAtPath(line(belts: 2), ['belts', 2, 'overrun']), isNull);
      expect(valueAtPath(line(), ['nope']), isNull);
      expect(valueAtPath(null, ['gapLength']), isNull);
    });
  });

  group('setAtPath', () {
    test('replaces a nested leaf in a copy', () {
      final root = line(belts: 2);
      final updated = setAtPath(root, ['belts', 0, 'overrun'], d(400.0));

      expect(updated['belts'][0]['overrun'].asDouble, 400);
      expect(root['belts'][0]['overrun'].asDouble, 1000,
          reason: 'the original must not move under the editor');
    });

    test('a path that is not there changes nothing', () {
      final root = line(belts: 1);
      final updated = setAtPath(root, ['belts', 5, 'overrun'], d(400.0));
      expect(updated['belts'].asArray, hasLength(1));
    });
  });

  group('formatRecipeValue', () {
    test('reads as an operator expects', () {
      expect(formatRecipeValue(d(true)), 'Yes');
      expect(formatRecipeValue(d(false)), 'No');
      expect(formatRecipeValue(DynamicValue()), 'empty');
      expect(formatRecipeValue(arr([belt(), belt()])), '2 items');
      expect(formatRecipeValue(arr([belt()])), '1 item');
      expect(formatRecipeValue(d('Program A')), 'Program A');
    });
  });

  group('recipePathLabel', () {
    test('names members and indices the way the report does', () {
      expect(recipePathLabel(['belts', 2, 'overrun']), 'belts[2].overrun');
      expect(recipePathLabel(const []), 'value');
    });
  });
}
