// The recipes dialog as pixels.
//
// Two views over one list, and the panels that make and file groups:
//
//   * the GROUPS view — where the dialog opens — with one card per line: a
//     line that differs from its recipe, one already running it, and one the
//     group has no recipe for, each saying so in words;
//   * the LINES view, one line at a time, with the recipe's values editable
//     beside what the line holds now and the rows a send would change tinted;
//   * the new-group panel, every line that has reported ticked;
//   * the first-open panel that files "Line N - X" presets into groups.
//
// Each lives in the pane rather than in a dialog of its own: a modal opened
// from a floating window lands underneath it.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';

import 'package:tfc/page_creator/assets/recipes.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/test_helpers.dart'
    show createTestPreferences, useInMemoryDeviceLocalPreferences;

DynamicValue _d(dynamic value) => DynamicValue(value: value);

DynamicValue _obj(Map<String, DynamicValue> members) {
  final v = DynamicValue();
  members.forEach((name, member) => v[name] = member);
  return v;
}

DynamicValue _arr(List<DynamicValue> items) {
  final v = DynamicValue()..value = <DynamicValue>[];
  for (var i = 0; i < items.length; i++) {
    v[i] = items[i];
  }
  return v;
}

DynamicValue _belt({double overrun = 1000.0}) => _obj({
      'stopDistance': _d(200.0),
      'overrun': _d(overrun),
    });

DynamicValue _line({
  double gapLength = 2000.0,
  bool bypassTrim = false,
  int belts = 3,
}) =>
    _obj({
      'gapLength': _d(gapLength),
      'bypassTrim': _d(bypassTrim),
      'belts': _arr([for (var i = 0; i < belts; i++) _belt()]),
    });

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(String key, DynamicValue value) {
    _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).add(value);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<DynamicValue> read(String key) async =>
      _streams[key]!.valueOrNull ?? DynamicValue();

  @override
  Future<void> write(String key, DynamicValue value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> _pump(
  WidgetTester tester,
  RecipesConfig config,
  _FakeStateMan stateMan, {
  List<Recipe> recipes = const [],
  Future<void> Function(WidgetTester tester)? then,
}) async {
  // The window opens at 1180x760, and only gets that if the screen it thinks
  // it is on is bigger: the shell clamps a window to the screen when it is
  // created. At the test binding's default 800x600 every frame here would be
  // a small-window frame.
  final view =
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
  view.devicePixelRatio = 1.0;
  view.physicalSize = const Size(1300, 900);
  addTearDown(view.resetPhysicalSize);
  addTearDown(view.resetDevicePixelRatio);

  useInMemoryDeviceLocalPreferences();
  final prefs = await createTestPreferences();
  await prefs.setString('${config.recipesBucket}.recipes',
      jsonEncode([for (final r in recipes) r.toJson()]));

  await tester.pumpWidget(ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((ref) async => prefs),
      databaseProvider.overrideWith((ref) async => null),
      stateManProvider.overrideWith((ref) async => stateMan),
    ],
    child: MaterialApp(
      theme: solarized().$1,
      home: Scaffold(body: Center(child: Recipes(config: config))),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Recipes').first);
  await tester.pumpAndSettle();
  if (then != null) {
    await then(tester);
    await tester.pumpAndSettle();
  }
}

final _threeLines = RecipesConfig(
    key: '', label: 'Line', keys: const ['line_a', 'line_b', 'line_c']);

/// Line 1 two belts and off its recipe; lines 2 and 3 three belts, line 2 on
/// its recipe. Line 3 has no recipe in the group.
_FakeStateMan _plant() => _FakeStateMan()
  ..push('line_a', _line(gapLength: 2000, bypassTrim: true, belts: 2))
  ..push('line_b', _line(gapLength: 2500, belts: 3))
  ..push('line_c', _line(gapLength: 2500, belts: 3));

List<Recipe> _grouped() => [
      Recipe(
          name: 'Line 1 - Standard',
          value: _line(gapLength: 2500, belts: 2),
          line: 'line_a',
          group: 'Standard'),
      Recipe(
          name: 'Line 2 - Standard',
          value: _line(gapLength: 2500, belts: 3),
          line: 'line_b',
          group: 'Standard'),
      Recipe(
          name: 'Line 1 - Large',
          value: _line(gapLength: 1800, belts: 2),
          line: 'line_a',
          group: 'Large'),
    ];

void main() {
  tearDown(() {
    for (final id in FloatingDialogs.openIds.toList()) {
      closeFloatingDialog(id);
    }
  });

  group('recipes dialog goldens', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    testWidgets('the groups view: one card per line, each in its own words',
        (tester) async {
      await _pump(tester, _threeLines, _plant(), recipes: _grouped());

      await expectLater(
        find.byType(StandardDialog),
        matchesGoldenFile('goldens/recipes_groups_view.png'),
      );
    });

    testWidgets('the lines view: one line, its recipe beside what it runs',
        (tester) async {
      await _pump(tester, _threeLines, _plant(), recipes: _grouped(),
          then: (tester) async {
        await tester.tap(find.text('Lines'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Standard'));
      });

      await expectLater(
        find.byType(StandardDialog),
        matchesGoldenFile('goldens/recipes_lines_view.png'),
      );
    });

    testWidgets('a new group, every reporting line ticked', (tester) async {
      await _pump(tester, _threeLines, _plant(), recipes: _grouped(),
          then: (tester) async {
        await tester.tap(find.text('New product'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('recipes.newGroupName')), 'Large');
      });

      await expectLater(
        find.byType(StandardDialog),
        matchesGoldenFile('goldens/recipes_new_group_panel.png'),
      );
    });

    testWidgets('first open: the "Line N - X" presets, filed into groups',
        (tester) async {
      await _pump(tester, _threeLines, _plant(), recipes: [
        Recipe(name: 'Line 1 - Standard', value: _line(belts: 2)),
        Recipe(name: 'Line 2 - Standard', value: _line(belts: 3)),
        Recipe(name: 'Line 3 - Standard', value: _line(belts: 3)),
        Recipe(name: 'Line 1 - Large', value: _line(belts: 2)),
        Recipe(name: 'Trial settings', value: _line(belts: 3)),
      ], then: (tester) async {
        await tester.tap(find.text('Group into products'));
      });

      await expectLater(
        find.byType(StandardDialog),
        matchesGoldenFile('goldens/recipes_grouping_panel.png'),
      );
    });
  });
}
