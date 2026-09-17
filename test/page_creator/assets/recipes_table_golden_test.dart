// The recipes dialog as pixels.
//
// The dialog used to be four scroll areas inside a box capped at 1000x700 —
// so it could not grow with the window, and a member's saved value and its
// live value sat in two trees that scrolled independently of each other and
// could not be brought level on screen at all.
//
// What these frames pin down:
//
//   * one member-aligned table, with the recipe and every line on the same
//     row, in ONE scroll region;
//   * the nesting rendered as indented rows rather than a second tree;
//   * "not present" written out in the column of a line that does not have
//     the member, never a blank and never a zero;
//   * a line that has not reported waiting in its own column while the
//     others render.

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
  String? selectRecipe,
}) async {
  // The window the dialog opens at is 1120x720, and it only gets that if the
  // screen it thinks it is on is bigger: the shell clamps a window to the
  // screen at creation and keeps the clamped size afterwards. At the test
  // binding's default 800x600 every one of these frames would be a
  // small-window frame.
  final view =
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
  view.devicePixelRatio = 1.0;
  view.physicalSize = const Size(1300, 860);
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
  if (selectRecipe != null) {
    await tester.tap(find.text(selectRecipe));
    await tester.pumpAndSettle();
  }
}

void main() {
  tearDown(() {
    for (final id in FloatingDialogs.openIds.toList()) {
      closeFloatingDialog(id);
    }
  });

  group('recipes dialog goldens', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    testWidgets('one recipe for every line, lines of different shapes',
        (tester) async {
      final stateMan = _FakeStateMan()
        ..push('line_a', _line(gapLength: 2000, belts: 2))
        ..push('line_b', _line(gapLength: 2500, belts: 3));
      // The third line never reports, so its column waits while the others
      // render — the CombineLatest trap, as pixels.

      await _pump(
        tester,
        RecipesConfig(
          key: '',
          label: 'Line',
          keys: const ['line_a', 'line_b', 'line_c'],
          unifiedRecipe: true,
        ),
        stateMan,
        recipes: [
          Recipe(name: 'Preset A', value: _line(gapLength: 2500, belts: 3)),
          Recipe(name: 'Preset B', value: _line(gapLength: 1800, belts: 2)),
        ],
        selectRecipe: 'Preset A',
      );

      await expectLater(
        find.byType(StandardDialog),
        matchesGoldenFile('goldens/recipes_unified_table.png'),
      );
    });

    testWidgets('one line at a time, with the pills that pick it',
        (tester) async {
      final stateMan = _FakeStateMan()
        ..push('line_a', _line(gapLength: 2000, belts: 2))
        ..push('line_b', _line(gapLength: 2500, belts: 3));

      await _pump(
        tester,
        RecipesConfig(
            key: '', label: 'Line', keys: const ['line_a', 'line_b']),
        stateMan,
        recipes: [
          Recipe(name: 'Preset A', value: _line(gapLength: 2500, belts: 3)),
        ],
        selectRecipe: 'Preset A',
      );

      await expectLater(
        find.byType(StandardDialog),
        matchesGoldenFile('goldens/recipes_line_table.png'),
      );
    });
  });
}
