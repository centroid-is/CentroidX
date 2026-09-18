// Groups of recipes: one recipe per line, sent together.
//
// The lines on a plant are separate PLCs and do not share a struct shape —
// one drives two conveyors where its neighbours drive three. So a group is
// not one recipe stretched across the lines; it is one COMPLETE recipe per
// line, each captured from and kept for its own line, so it always fits it.
//
// The contract these tests hold it to:
//
//   * a recipe knows its line by KEY, never by position, so reordering the
//     keys in the settings cannot send it to a different PLC;
//   * a group holds at most one recipe per line — with two, which one a line
//     gets would be a guess;
//   * recipes saved before any of this still load, are offered on every
//     line, and keep working on a station still running an older build;
//   * the "Line 2 - Standard" presets a station already has are filed into
//     groups only when asked, and nothing is sent to a line when they are;
//   * "running" is derived from the live value every time.

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/recipes.dart';

DynamicValue d(dynamic value) => DynamicValue(value: value);

DynamicValue obj(Map<String, DynamicValue> members) {
  final v = DynamicValue();
  members.forEach((name, member) => v[name] = member);
  return v;
}

DynamicValue arr(List<DynamicValue> items) {
  final v = DynamicValue()..value = <DynamicValue>[];
  for (var i = 0; i < items.length; i++) {
    v[i] = items[i];
  }
  return v;
}

/// The shape these lines really have, shortened.
DynamicValue line(
        {double space = 2500, bool curl = false, int conveyors = 3}) =>
    obj({
      'gapLength': d(space),
      'bypassTrim': d(curl),
      'belts': arr([
        for (var i = 0; i < conveyors; i++) obj({'overrun': d(1000.0)}),
      ]),
    });

const l1 = 'line_a.recipe';
const l2 = 'line_b.recipe';
const l3 = 'line_c.recipe';
const lineIds = [l1, l2, l3];

Recipe inGroup(String group, String lineKey, {double space = 2500}) => Recipe(
      name: 'x',
      value: line(space: space),
      line: lineKey,
      group: group,
    );

void main() {
  group('a group', () {
    test('lists the groups in the order the list has them', () {
      final recipes = [
        inGroup('Standard', l1),
        Recipe(name: 'loose', value: line()),
        inGroup('Large', l1),
        inGroup('Standard', l2),
      ];

      expect(recipeGroups(recipes), ['Standard', 'Large']);
    });

    test('finds the recipe it holds for a line', () {
      final two = inGroup('Standard', l2);
      final recipes = [inGroup('Standard', l1), two];

      expect(recipeInGroup(recipes, 'Standard', l2), same(two));
      expect(recipeInGroup(recipes, 'Standard', l3), isNull);
    });

    test('holds one recipe per line, never two', () {
      final held = inGroup('Standard', l2);
      final other = Recipe(name: 'other', value: line(), line: l2);
      final recipes = [held, other];

      expect(canJoinGroup(recipes, other, 'Standard'), isFalse,
          reason: 'with two, which one Line 2 gets would be a guess');
      expect(canJoinGroup(recipes, held, 'Standard'), isTrue,
          reason: 'the recipe already there is not in its own way');
    });

    test('a recipe with no line cannot join one until it is given a line', () {
      final legacy = Recipe(name: 'old', value: line());

      expect(canJoinGroup([legacy], legacy, 'Standard'), isFalse);
    });

    test('moves as one block when reordered', () {
      final a1 = inGroup('A', l1);
      final a2 = inGroup('A', l2);
      final b1 = inGroup('B', l1);
      final loose = Recipe(name: 'loose', value: line());
      final recipes = [a1, a2, loose, b1];

      moveRecipeGroup(recipes, 'B', 0);

      expect(recipeGroups(recipes), ['B', 'A']);
      expect(recipes.indexOf(a2), recipes.indexOf(a1) + 1,
          reason: "a group's recipes stay together");
      expect(recipes, contains(loose));
    });

    test('moved to the end sits after the last group', () {
      final a1 = inGroup('A', l1);
      final b1 = inGroup('B', l1);
      final c1 = inGroup('C', l1);
      final recipes = [a1, b1, c1];

      moveRecipeGroup(recipes, 'A', 2);

      expect(recipeGroups(recipes), ['B', 'C', 'A']);
    });
  });

  group('a line', () {
    test('is offered its own recipes and the ones saved before lines', () {
      final mine = Recipe(name: 'mine', value: line(), line: l2);
      final theirs = Recipe(name: 'theirs', value: line(), line: l3);
      final legacy = Recipe(name: 'legacy', value: line());

      expect(recipesOnLine([mine, theirs, legacy], l2), [mine, legacy],
          reason: 'a recipe saved before recipes knew their line has always '
              'been offered everywhere, and still is');
    });
  });

  group('where a line stands against its recipe', () {
    test('a line the group has no recipe for', () {
      expect(lineRecipeStatus(null, line()).state, LineRecipeState.noRecipe);
    });

    test('a line that has not reported', () {
      final recipe = inGroup('Standard', l1);

      expect(lineRecipeStatus(recipe, null).state, LineRecipeState.waiting);
    });

    test('a line already running it', () {
      final recipe = inGroup('Standard', l1);

      final status = lineRecipeStatus(recipe, line());

      expect(status.state, LineRecipeState.running);
      expect(status.changes, 0);
    });

    test('a line that differs says by how many values', () {
      final recipe = inGroup('Standard', l1);

      final status = lineRecipeStatus(recipe, line(space: 2000, curl: true));

      expect(status.state, LineRecipeState.differs);
      expect(status.changes, 2);
    });

    test('counts only what a send would change on THIS line', () {
      // A three-conveyor recipe on a two-conveyor line: the third conveyor
      // does not exist here, so it is not a change here.
      final recipe =
          Recipe(name: 'x', value: line(conveyors: 3), line: l1, group: 'G');

      final status = lineRecipeStatus(recipe, line(conveyors: 2));

      expect(status.state, LineRecipeState.running);
    });

    test('a recipe none of which lands on the line', () {
      final recipe = Recipe(
          name: 'x', value: obj({'nothing': d(1)}), line: l1, group: 'G');

      expect(
          lineRecipeStatus(recipe, line()).state, LineRecipeState.doesNotFit);
    });

    test('a value turned by hand takes "running" away', () {
      final recipe = inGroup('Standard', l1);

      expect(lineRecipeStatus(recipe, line()).state, LineRecipeState.running);
      expect(lineRecipeStatus(recipe, line(space: 2600)).state,
          LineRecipeState.differs,
          reason: 'derived from the live value every time, so it goes stale '
              'the moment the line stops matching');
    });
  });

  group('the presets a station already has', () {
    test('a name that says its line is read back out', () {
      expect(parseLineRecipeName('Line 2 - Standard', 'Line'),
          (number: 2, group: 'Standard'));
    });

    test('spacing, punctuation and case do not matter', () {
      expect(parseLineRecipeName('line 1: trial', 'Line'),
          (number: 1, group: 'trial'));
      expect(parseLineRecipeName('Line3 large', 'Line'),
          (number: 3, group: 'large'));
    });

    test('a name that only starts with the same letters is not a line', () {
      expect(parseLineRecipeName('Linear belts', 'Line'), isNull);
    });

    test('"Line 12" is line twelve, not line one', () {
      expect(parseLineRecipeName('Line 12 - trial', 'Line')?.number, 12);
    });

    test('a line with nothing after it names no group', () {
      expect(parseLineRecipeName('Line 2', 'Line'), isNull);
    });

    test("the asset's own word for a line is what is looked for", () {
      expect(parseLineRecipeName('Lína 2 - trial', 'Lína'),
          (number: 2, group: 'trial'));
      expect(parseLineRecipeName('Lína 2 - trial', 'Line'), isNull);
    });

    test('are proposed as groups by the name after the line', () {
      final r1 = Recipe(name: 'Line 1 - Standard', value: line());
      final r2 = Recipe(name: 'Line 2 - Standard', value: line());
      final r3 = Recipe(name: 'Line 1 - Large', value: line());
      final loose = Recipe(name: 'Trial', value: line());

      final proposal =
          proposeRecipeGrouping([r1, r2, r3, loose], 'Line', lineIds);

      expect([
        for (final p in proposal) (p.recipe.name, p.line, p.group)
      ], [
        ('Line 1 - Standard', l1, 'Standard'),
        ('Line 2 - Standard', l2, 'Standard'),
        ('Line 1 - Large', l1, 'Large'),
      ]);
    });

    test('one product spelled two ways is one group', () {
      final r1 = Recipe(name: 'Line 1 - Standard', value: line());
      final r2 = Recipe(name: 'Line 2 - standard', value: line());

      final proposal = proposeRecipeGrouping([r1, r2], 'Line', lineIds);

      expect(proposal.map((p) => p.group).toSet(), {'Standard'});
    });

    test('a line number past the configured lines is left alone', () {
      final r = Recipe(name: 'Line 4 - Standard', value: line());

      expect(proposeRecipeGrouping([r], 'Line', lineIds), isEmpty);
    });

    test('a second recipe for a line already in the group is not guessed at',
        () {
      final first = Recipe(name: 'Line 2 - Standard', value: line());
      final second = Recipe(name: 'Line 2 - Standard', value: line());

      final proposal = proposeRecipeGrouping([first, second], 'Line', lineIds);

      expect(proposal.map((p) => p.recipe), [first]);
    });

    test('a recipe already filed is not proposed again', () {
      final filed = Recipe(
          name: 'Line 2 - Standard', value: line(), line: l2, group: 'X');

      expect(proposeRecipeGrouping([filed], 'Line', lineIds), isEmpty);
    });

    test('applying the proposal files each recipe, and touches nothing else',
        () {
      final r = Recipe(name: 'Line 2 - Standard', value: line(space: 1));

      applyRecipeGrouping(proposeRecipeGrouping([r], 'Line', lineIds));

      expect(r.line, l2);
      expect(r.group, 'Standard');
      expect(r.name, 'Line 2 - Standard',
          reason: 'an older build on another station still shows this name');
      expect(r.value['gapLength'].asDouble, 1);
    });
  });

  group('storage', () {
    test('a recipe saved before lines and groups existed still loads', () {
      // What is in the station's preferences today.
      final json = Recipe(name: 'Line 2 - Standard', value: line()).toJson()
        ..remove('line')
        ..remove('group');

      final recipe = Recipe.fromJson(json);

      expect(recipe.line, isNull);
      expect(recipe.group, isNull);
      expect(recipe.value['gapLength'].asDouble, 2500);
    });

    test('line and group survive a round trip', () {
      final recipe = inGroup('Standard', l2);

      final back = Recipe.fromJson(recipe.toJson());

      expect(back.line, l2);
      expect(back.group, 'Standard');
    });

    test('the fields an older build reads are unchanged', () {
      // A station still on an older build reads this same list, knows nothing
      // of lines or groups, and must go on reading its name and value.
      final json = inGroup('Standard', l2).toJson();

      expect(json['name'], isA<String>());
      expect(json['value'], isA<Map<String, dynamic>>());
    });
  });
}
