// The recipes dialog: what it shows, and what Send writes.
//
// Two views over one list. The GROUPS view — "Products" unless the page calls
// them something else — is where the dialog opens: a group is one complete
// recipe per line, sent together. The LINES view is the advanced one: one
// line at a time, every value editable against what the line holds now.
//
// What these tests hold it to:
//
//   * each line in a group is sent its OWN recipe, merged into its own shape
//     — the lines do not share a struct, and a group never asks them to;
//   * sending a group writes only the lines that would change, and says what
//     it did with every other line;
//   * the presets a station already has ("Line 2 - Standard") are grouped
//     only when asked, and nothing is sent to a PLC when they are;
//   * a line tab re-points the live values (the bug that started this);
//   * a value typed and left — no Enter — is saved.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/recipes.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AccessSession, TagBindingResolver;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/test_helpers.dart';

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

DynamicValue belt({double overrun = 1000.0}) =>
    obj({'stopDistance': d(200.0), 'overrun': d(overrun)});

DynamicValue lineValue({double gapLength = 2000.0, int belts = 3}) => obj({
      'gapLength': d(gapLength),
      'belts': arr([for (var i = 0; i < belts; i++) belt()]),
    });

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<({String key, DynamicValue value})> writes = [];

  /// Keys whose read fails, for the dead-line case.
  final Set<String> unreadable = {};

  void push(String key, DynamicValue value) {
    _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).add(value);
  }

  DynamicValue? last(String key) => _streams[key]?.valueOrNull;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<DynamicValue> read(String key) async {
    if (unreadable.contains(key)) throw StateError('no value for $key');
    final value = _streams[key]?.valueOrNull;
    if (value == null) throw StateError('no value for $key');
    return value;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add((key: key, value: value));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
      );
}

void main() {
  late _FakeStateMan stateMan;
  late Preferences prefs;

  setUp(() {
    stateMan = _FakeStateMan();
  });

  tearDown(() {
    for (final id in FloatingDialogs.openIds.toList()) {
      closeFloatingDialog(id);
    }
  });

  /// Seeds the preference bucket the dialog reads its presets out of.
  Future<void> seedRecipes(String bucket, List<Recipe> recipes) async {
    await prefs.setString(
        '$bucket.recipes', jsonEncode([for (final r in recipes) r.toJson()]));
  }

  Future<void> pumpDialog(
    WidgetTester tester,
    RecipesConfig config, {
    List<Recipe> recipes = const [],
  }) async {
    // Bigger than the 1120x720 the dialog opens at: the shell clamps a
    // window to the screen when it is created, so the binding's default
    // 800x600 would give every test a small-window layout.
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(1400, 900);
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);

    useInMemoryDeviceLocalPreferences();
    prefs = await createTestPreferences();
    await seedRecipes(config.recipesBucket, recipes);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        preferencesProvider.overrideWith((ref) async => prefs),
        databaseProvider.overrideWith((ref) async => null),
        stateManProvider.overrideWith((ref) async => stateMan),
        // The tap-time guard asks this and nothing else. A session that may
        // set setpoints is what a recipe send needs; the guard's own wiring
        // has its own tests.
        tagAccessProvider.overrideWithValue(TagAccess(
          resolver: TagBindingResolver(),
          session: AccessSession(groups: const {
            AccessGroup.operate,
            AccessGroup.setpoints,
          }),
        )),
      ],
      child: MaterialApp(
        home: Scaffold(body: Center(child: Recipes(config: config))),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recipes').first);
    await tester.pumpAndSettle();
  }

  // Three lines, the shape the plant has: line 1 differs from its recipe,
  // line 2 is running its recipe, and line 3 has none in the group.
  final threeLines = RecipesConfig(
      key: '', label: 'Line', keys: const ['line_a', 'line_b', 'line_c']);

  List<Recipe> standardGroup() => [
        Recipe(
            name: 'Line 1 - Standard',
            value: lineValue(gapLength: 2500, belts: 1),
            line: 'line_a',
            group: 'Standard'),
        Recipe(
            name: 'Line 2 - Standard',
            value: lineValue(gapLength: 2500, belts: 1),
            line: 'line_b',
            group: 'Standard'),
      ];

  void pushThreeLines() {
    stateMan.push('line_a', lineValue(gapLength: 2000, belts: 1));
    stateMan.push('line_b', lineValue(gapLength: 2500, belts: 1));
    stateMan.push('line_c', lineValue(gapLength: 2500, belts: 1));
  }

  Future<List<dynamic>> saved(RecipesConfig config) async =>
      jsonDecode((await prefs.getString('${config.recipesBucket}.recipes'))!)
          as List;

  group("the dialog speaks the asset's own words", () {
    testWidgets('Products | Lines unless the page says otherwise',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines);

      expect(find.text('Products'), findsWidgets);
      expect(find.text('Lines'), findsOneWidget);
      expect(find.text('New product'), findsOneWidget);
    });

    testWidgets('and whatever the page calls them when it does',
        (tester) async {
      pushThreeLines();
      await pumpDialog(
        tester,
        RecipesConfig(
          key: '',
          label: 'Lína',
          labelPlural: 'Línur',
          groupLabel: 'Vara',
          groupLabelPlural: 'Vörur',
          keys: const ['line_a', 'line_b', 'line_c'],
        ),
      );

      expect(find.text('Vörur'), findsWidgets);
      expect(find.text('Línur'), findsOneWidget);
      expect(find.text('New vara'), findsOneWidget);
      expect(find.text('Products'), findsNothing,
          reason: 'nothing in the dialog is hard-coded to "Product"');
    });
  });

  group('a group is one recipe per line, sent together', () {
    testWidgets('each line says where it stands against its recipe',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      expect(find.text('1 value differs'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('No recipe'), findsOneWidget);
    });

    testWidgets('sending the group writes only the line that would change',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      await tester.tap(find.text('Send to all 2 lines'));
      await tester.pumpAndSettle();

      expect(stateMan.writes.map((w) => w.key), ['line_a'],
          reason: 'line 2 already runs it, and line 3 has no recipe here');
      expect(find.textContaining('already running it'), findsOneWidget);
      expect(find.textContaining('no recipe in Standard'), findsOneWidget);
    });

    testWidgets('each line is sent its own recipe, in its own shape',
        (tester) async {
      stateMan.push('line_a', lineValue(gapLength: 2000, belts: 1));
      stateMan.push('line_b', lineValue(gapLength: 2000, belts: 3));
      stateMan.push('line_c', lineValue(gapLength: 2000, belts: 3));
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(
            name: 'Line 1 - Standard',
            value: lineValue(gapLength: 2500, belts: 1),
            line: 'line_a',
            group: 'Standard'),
        Recipe(
            name: 'Line 2 - Standard',
            value: lineValue(gapLength: 2600, belts: 3),
            line: 'line_b',
            group: 'Standard'),
      ]);

      await tester.tap(find.text('Send to all 2 lines'));
      await tester.pumpAndSettle();

      final byKey = {for (final w in stateMan.writes) w.key: w.value};
      expect(byKey['line_a']!['gapLength'].asDouble, 2500);
      expect(byKey['line_a']!['belts'].asArray.length, 1);
      expect(byKey['line_b']!['gapLength'].asDouble, 2600,
          reason: "line 2 gets its own value, not line 1's");
      expect(byKey['line_b']!['belts'].asArray.length, 3);
    });

    testWidgets('a card sends its own line and no other', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      await tester.tap(find.text('Send to Line 1'));
      await tester.pumpAndSettle();

      expect(stateMan.writes.map((w) => w.key), ['line_a']);
    });

    testWidgets('a line with no recipe is filled from what it runs now',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      await tester.tap(find.text('Copy from Line 3 now'));
      await tester.pumpAndSettle();

      final third =
          (await saved(threeLines)).singleWhere((r) => r['line'] == 'line_c');
      expect(third['group'], 'Standard');
      expect(stateMan.writes, isEmpty,
          reason: 'copying FROM a line writes nothing TO it');
      expect(find.text('No recipe'), findsNothing);
    });
  });

  group('a new group starts from what every line runs now', () {
    testWidgets('one recipe per ticked line, captured from that line',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines);

      await tester.tap(find.text('New product'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('recipes.newGroupName')), 'Standard');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create product'));
      await tester.pumpAndSettle();

      final all = await saved(threeLines);
      expect([for (final r in all) r['line']], ['line_a', 'line_b', 'line_c']);
      expect({for (final r in all) r['group']}, {'Standard'});
      expect(find.text('Running'), findsNWidgets(3),
          reason: 'captured from the lines, so every line is running it');
    });
  });

  group('the presets a station already has', () {
    testWidgets('are grouped by their names when asked, and nothing is sent',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(name: 'Line 1 - Standard', value: lineValue(belts: 1)),
        Recipe(name: 'Line 2 - Standard', value: lineValue(belts: 1)),
        Recipe(name: 'Trial', value: lineValue(belts: 1)),
      ]);

      expect(find.textContaining('2 saved recipes can be grouped'),
          findsOneWidget);
      await tester.tap(find.text('Group into products'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group into 1 product'));
      await tester.pumpAndSettle();

      final all = await saved(threeLines);
      expect([
        for (final r in all) (r['line'], r['group'])
      ], [
        ('line_a', 'Standard'),
        ('line_b', 'Standard'),
        (null, null),
      ]);
      expect(stateMan.writes, isEmpty);
      expect(find.textContaining('can be grouped'), findsNothing,
          reason: 'nothing left to offer');
    });

    testWidgets('"Not now" leaves them exactly as they were', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(name: 'Line 1 - Standard', value: lineValue(belts: 1)),
      ]);

      await tester.tap(find.text('Group into products'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect((await saved(threeLines)).single['group'], isNull);
    });
  });

  group('groups are arranged by dragging', () {
    testWidgets('the new order is the stored order', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(
            name: 'A', value: lineValue(belts: 1), line: 'line_a', group: 'A'),
        Recipe(
            name: 'B', value: lineValue(belts: 1), line: 'line_a', group: 'B'),
      ]);

      // Past the top: a drag beyond the first slot is clamped to it, so
      // overshooting says "to the top" without pinning the test to a height.
      await tester.drag(
          find.byIcon(Icons.drag_indicator).last, const Offset(0, -400));
      await tester.pumpAndSettle();

      expect([for (final r in await saved(threeLines)) r['group']], ['B', 'A']);
    });
  });

  group('the lines view', () {
    Future<void> openLines(WidgetTester tester) async {
      await tester.tap(find.text('Lines'));
      await tester.pumpAndSettle();
    }

    testWidgets('a tab re-points the live values', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines);
      await openLines(tester);

      expect(find.text('2000.0'), findsOneWidget);

      await tester.tap(find.text('Line 2'));
      await tester.pumpAndSettle();

      expect(find.text('2500.0'), findsOneWidget,
          reason: 'the regression this whole rebuild started from: the tab '
              'moved and the values stayed on the first line');
      expect(find.text('2000.0'), findsNothing);
    });

    testWidgets(
        'a line is offered its own recipes and the ones saved before lines',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(name: 'Mine', value: lineValue(belts: 1), line: 'line_a'),
        Recipe(name: 'Theirs', value: lineValue(belts: 1), line: 'line_b'),
        Recipe(name: 'Old', value: lineValue(belts: 1)),
      ]);
      await openLines(tester);

      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Old'), findsOneWidget);
      expect(find.text('Theirs'), findsNothing);
    });

    testWidgets(
        'a value typed and left, without Enter, is kept — and stored '
        'only on Save', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(
            name: 'Mine', value: obj({'gapLength': d(2000.0)}), line: 'line_a'),
      ]);
      await openLines(tester);
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      // The value cell, not the rail's "New recipe" box.
      await tester.enterText(
          find
              .descendant(
                  of: find.byType(Table), matching: find.byType(TextField))
              .first,
          '2750');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(jsonEncode(await saved(threeLines)), isNot(contains('2750')),
          reason: 'kept in the draft, not stored');

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(jsonEncode(await saved(threeLines)), contains('2750'));
    });

    testWidgets('Send writes that line, in its own shape', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(
            name: 'Wide',
            value: lineValue(gapLength: 2700, belts: 3),
            line: 'line_a'),
      ]);
      await openLines(tester);
      await tester.tap(find.text('Wide'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to Line 1'));
      await tester.pumpAndSettle();

      final write = stateMan.writes.single;
      expect(write.key, 'line_a');
      expect(write.value['gapLength'].asDouble, 2700);
      expect(write.value['belts'].asArray.length, 1,
          reason: 'a line is never lengthened to fit a recipe');
    });

    testWidgets('a line that cannot be read is not written blind',
        (tester) async {
      pushThreeLines();
      stateMan.unreadable.add('line_a');
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(name: 'Mine', value: lineValue(belts: 1), line: 'line_a'),
      ]);
      await openLines(tester);
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to Line 1'));
      await tester.pumpAndSettle();

      expect(stateMan.writes, isEmpty);
      expect(find.textContaining('could not be read'), findsOneWidget);
    });
  });

  group('the dialog owns its own space', () {
    testWidgets('the body is not wrapped in a scroll view of its own',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines);

      final dialog = tester.widget<StandardDialog>(find.byType(StandardDialog));
      expect(dialog.scrollable, isFalse,
          reason: 'the content fills the window itself, so dragging the '
              'window bigger grows it');
    });

    testWidgets('the values are one scroll region, not two side by side',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(name: 'Mine', value: lineValue(belts: 1), line: 'line_a'),
      ]);
      await tester.tap(find.text('Lines'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();

      final vertical = tester
          .widgetList<SingleChildScrollView>(find.descendant(
            of: find.byType(StandardDialog),
            matching: find.byType(SingleChildScrollView),
          ))
          .where((s) => s.scrollDirection == Axis.vertical);
      expect(vertical, hasLength(1));
    });
  });

  group('the legacy single-key array', () {
    testWidgets('sends one element and writes the rest back as read',
        (tester) async {
      final config = RecipesConfig(key: 'all_lines', label: 'Line');
      stateMan.push(
          'all_lines',
          arr([
            lineValue(gapLength: 2000, belts: 1),
            lineValue(gapLength: 2000, belts: 1),
          ]));
      await pumpDialog(tester, config, recipes: [
        Recipe(
            name: 'Line 2 - G',
            value: lineValue(gapLength: 2500, belts: 1),
            line: 'all_lines[1]',
            group: 'G'),
      ]);

      await tester.tap(find.text('Send to Line 2'));
      await tester.pumpAndSettle();

      final write = stateMan.writes.single;
      expect(write.key, 'all_lines');
      expect(write.value[0]['gapLength'].asDouble, 2000,
          reason: 'the other line is written back exactly as it was read');
      expect(write.value[1]['gapLength'].asDouble, 2500);
    });
  });

  group('a product points at a recipe the line already has', () {
    testWidgets('each card names the recipe it sends', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      expect(find.text('Line 1 - Standard'), findsOneWidget);
      expect(find.text('Line 2 - Standard'), findsOneWidget);
      expect(find.text('No recipe'), findsWidgets);
    });

    testWidgets(
        'Change picks one of the line\'s own recipes, and keeps the '
        'one it replaces', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        ...standardGroup(),
        Recipe(
            name: 'Line 1 own',
            value: lineValue(gapLength: 2000, belts: 1),
            line: 'line_a'),
      ]);

      await tester.tap(find.text('Change').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 1 own'));
      await tester.pumpAndSettle();

      final all = await saved(threeLines);
      final own = all.singleWhere((r) => r['name'] == 'Line 1 own');
      final old = all.singleWhere((r) => r['name'] == 'Line 1 - Standard');
      expect(own['group'], 'Standard');
      expect(old['group'], isNull, reason: 'replaced, not deleted');
      expect(find.text('Running'), findsNWidgets(2),
          reason: "line 1's own recipe is what it runs, so it is running now");
    });
  });

  group('products are renamed and deleted with buttons, not a menu', () {
    // A ⋮ menu is a route, and a route opened from inside the floating window
    // lands underneath it. These were a menu once and opened nothing.
    testWidgets('rename', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      await tester.tap(find.byTooltip('Rename product'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byType(StandardDialog),
              matching: find.byType(TextField)),
          'Renamed');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(
          {for (final r in await saved(threeLines)) r['group']}, {'Renamed'});
    });

    testWidgets('delete', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());

      await tester.tap(find.byTooltip('Delete product'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(await saved(threeLines), isEmpty);
      expect(stateMan.writes, isEmpty);
    });
  });

  group('the lines view, by recipe name', () {
    Future<void> openLines(WidgetTester tester) async {
      await tester.tap(find.text('Lines'));
      await tester.pumpAndSettle();
    }

    testWidgets('a recipe is put into a product with a chip', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(
            name: 'A', value: lineValue(belts: 1), line: 'line_b', group: 'P'),
        Recipe(name: 'Mine', value: lineValue(belts: 1), line: 'line_a'),
      ]);
      await openLines(tester);
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'P'));
      await tester.pumpAndSettle();

      final mine =
          (await saved(threeLines)).singleWhere((r) => r['name'] == 'Mine');
      expect(mine['group'], 'P');
    });

    testWidgets('renaming a recipe renames that recipe and nothing else',
        (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: standardGroup());
      await openLines(tester);
      await tester.tap(find.text('Line 1 - Standard'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Rename recipe'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('recipes.renameField')), 'Standard');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final all = await saved(threeLines);
      expect(
          [for (final r in all) r['name']], ['Standard', 'Line 2 - Standard']);
      expect({for (final r in all) r['group']}, {'Standard'},
          reason: 'the product is renamed in the products view, not here');
    });

    testWidgets('loose recipes are arranged by dragging', (tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(name: 'First', value: lineValue(belts: 1), line: 'line_a'),
        Recipe(name: 'Other line', value: lineValue(belts: 1), line: 'line_b'),
        Recipe(name: 'Second', value: lineValue(belts: 1), line: 'line_a'),
      ]);
      await openLines(tester);

      await tester.drag(
          find.byIcon(Icons.drag_indicator).last, const Offset(0, -400));
      await tester.pumpAndSettle();

      expect([
        for (final r in await saved(threeLines)) r['name']
      ], [
        'Second',
        'Other line',
        'First'
      ], reason: "line 2's recipe keeps its slot");
    });
  });

  group('nothing is stored until Save', () {
    Future<void> openMine(WidgetTester tester) async {
      pushThreeLines();
      await pumpDialog(tester, threeLines, recipes: [
        Recipe(
            name: 'Mine', value: obj({'gapLength': d(2000.0)}), line: 'line_a'),
        Recipe(
            name: 'Other', value: obj({'gapLength': d(1.0)}), line: 'line_a'),
      ]);
      await tester.tap(find.text('Lines'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
    }

    Future<void> editTo(WidgetTester tester, String value) async {
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find
              .descendant(
                  of: find.byType(Table), matching: find.byType(TextField))
              .first,
          value);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    }

    testWidgets('values are read-only until Edit', (tester) async {
      await openMine(tester);

      expect(
          find.descendant(
              of: find.byType(Table), matching: find.byType(TextField)),
          findsNothing,
          reason: 'a stray tap on a panel changes nothing');
    });

    testWidgets('Cancel puts every value back', (tester) async {
      await openMine(tester);
      await editTo(tester, '2750');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('2000.0'), findsWidgets);
      expect(jsonEncode(await saved(threeLines)), isNot(contains('2750')));
    });

    testWidgets('Send while editing tries the values without storing them',
        (tester) async {
      await openMine(tester);
      await editTo(tester, '2750');

      await tester.tap(find.text('Send without saving'));
      await tester.pumpAndSettle();

      expect(stateMan.writes.single.value['gapLength'].asDouble, 2750,
          reason: 'what is on screen is what is sent');
      expect(jsonEncode(await saved(threeLines)), isNot(contains('2750')),
          reason: 'trying a value on the line is not keeping it');
      expect(find.textContaining('not saved as the recipe'), findsOneWidget);
    });

    testWidgets('leaving for another recipe with unsaved edits asks first',
        (tester) async {
      await openMine(tester);
      await editTo(tester, '2750');

      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Unsaved changes to Mine'), findsOneWidget);

      await tester.tap(find.text('Save and continue'));
      await tester.pumpAndSettle();

      expect(jsonEncode(await saved(threeLines)), contains('2750'));
      expect(find.text('Other on Line 1'), findsOneWidget,
          reason: 'and then it goes where it was asked to');
    });

    testWidgets('closing with unsaved edits asks, in the window, first',
        (tester) async {
      await openMine(tester);
      await editTo(tester, '2750');

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(FloatingDialogs.openIds, isNotEmpty,
          reason: 'the window stays until the question is answered');
      expect(find.textContaining('Unsaved changes to Mine'), findsOneWidget);

      await tester.tap(find.text('Discard and close'));
      await tester.pumpAndSettle();

      expect(FloatingDialogs.openIds, isEmpty);
      expect(jsonEncode(await saved(threeLines)), isNot(contains('2750')));
    });

    testWidgets('closing with nothing unsaved just closes', (tester) async {
      await openMine(tester);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(FloatingDialogs.openIds, isEmpty);
    });

    testWidgets('delete asks before it deletes', (tester) async {
      await openMine(tester);

      await tester.tap(find.byTooltip('Delete Mine'));
      await tester.pumpAndSettle();
      expect((await saved(threeLines)).length, 2,
          reason: 'one tap asks; a brushed bin must not take a recipe');

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect([for (final r in await saved(threeLines)) r['name']], ['Other']);
    });
  });
}
