// The recipes dialog: what it reads, what it shows, and what Send writes.
//
// Three things here are regressions rather than features.
//
// 1. **The line pills used to change nothing but themselves.** The tag
//    subscription sat ABOVE the `StatefulBuilder` the selection was mutated
//    through, and the floating dialog builds its body once and carries it as
//    a captured child — so tapping a second line re-drew the pill and went on
//    showing the first line's node. The dialog body is now a stateful widget
//    that builds its own subscriptions, so a selection change re-points them.
//
// 2. **A member one line does not have must say so.** A blank cell reads as
//    "nothing set" and a zero reads as a setpoint; both are wrong about a
//    line that simply has no such member.
//
// 3. **Send is a member-wise merge, never a struct copy.** Lines are not
//    obliged to share a shape, and writing a three-belt recipe onto a
//    two-belt line must not lengthen it.

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

  group('the line pills re-point the live subscription', () {
    testWidgets('tapping a second line shows that line, not the first',
        (tester) async {
      final config = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a', 'line_b']);
      stateMan.push('line_a', lineValue(gapLength: 2000, belts: 1));
      stateMan.push('line_b', lineValue(gapLength: 2500, belts: 1));

      await pumpDialog(tester, config);

      expect(find.text('2000.0'), findsOneWidget);
      expect(find.text('2500.0'), findsNothing);

      await tester.tap(find.text('Line 2'));
      await tester.pumpAndSettle();

      expect(find.text('2500.0'), findsOneWidget,
          reason: 'the subscription must follow the selection');
      expect(find.text('2000.0'), findsNothing);
    });

    testWidgets('the column is headed Current when lines are picked one at a '
        'time', (tester) async {
      final config = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a', 'line_b']);
      stateMan.push('line_a', lineValue(belts: 1));

      await pumpDialog(tester, config);

      expect(find.text('Current'), findsOneWidget);
      expect(find.text('Line 1'), findsOneWidget); // the pill, not a column
    });
  });

  group('unified mode', () {
    testWidgets('gives every line its own column and no line pills',
        (tester) async {
      final config = RecipesConfig(
        key: '',
        label: 'Line',
        keys: const ['line_a', 'line_b', 'line_c'],
        unifiedRecipe: true,
      );
      stateMan.push('line_a', lineValue(belts: 2));
      stateMan.push('line_b', lineValue(belts: 3));
      stateMan.push('line_c', lineValue(belts: 3));

      await pumpDialog(tester, config);

      // Column headings, one per line — and the pills are gone, because in
      // unified mode there is no line to choose.
      expect(find.text('Line 1'), findsOneWidget);
      expect(find.text('Line 2'), findsOneWidget);
      expect(find.text('Line 3'), findsOneWidget);
      expect(find.text('Current'), findsNothing);
    });

    testWidgets('a member the short line does not have says so', (tester) async {
      final config = RecipesConfig(
        key: '',
        label: 'Line',
        keys: const ['line_a', 'line_b'],
        unifiedRecipe: true,
      );
      stateMan.push('line_a', lineValue(belts: 2));
      stateMan.push('line_b', lineValue(belts: 3));

      await pumpDialog(tester, config);

      // The third belt exists on one line only: its row is there, and the
      // line without it says "not present" rather than showing a blank or a
      // zero that reads as a setpoint.
      expect(find.text('Item 3'), findsOneWidget);
      expect(find.text('not present'), findsWidgets);
    });

    testWidgets('a line that has not reported waits in its own column only',
        (tester) async {
      final config = RecipesConfig(
        key: '',
        label: 'Line',
        keys: const ['line_a', 'line_b'],
        unifiedRecipe: true,
      );
      // Only one line ever speaks. CombineLatest would otherwise hold the
      // whole table back until every input had produced a value.
      stateMan.push('line_a', lineValue(belts: 1));

      await pumpDialog(tester, config);

      expect(find.text('Gap Length'), findsOneWidget);
      expect(find.text('waiting'), findsWidgets);
    });
  });

  group('the dialog owns its own space', () {
    testWidgets('the body is not wrapped in a scroll view of its own',
        (tester) async {
      final config = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a', 'line_b']);
      stateMan.push('line_a', lineValue(belts: 1));

      await pumpDialog(tester, config);

      final dialog = tester.widget<StandardDialog>(find.byType(StandardDialog));
      expect(dialog.scrollable, isFalse,
          reason: 'the content fills the window itself');
    });

    testWidgets('the values are one scroll region, not two side by side',
        (tester) async {
      final config = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a', 'line_b']);
      stateMan.push('line_a', lineValue(belts: 1));

      await pumpDialog(tester, config);

      expect(
        find.descendant(
          of: find.byType(StandardDialog),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
    });
  });

  group('Send merges rather than copies', () {
    testWidgets('writes every line, keeping each line its own shape',
        (tester) async {
      final config = RecipesConfig(
        key: '',
        label: 'Line',
        keys: const ['line_a', 'line_b'],
        unifiedRecipe: true,
      );
      stateMan.push('line_a', lineValue(gapLength: 2000, belts: 2));
      stateMan.push('line_b', lineValue(gapLength: 2000, belts: 3));

      await pumpDialog(
        tester,
        config,
        recipes: [
          Recipe(name: 'Preset A', value: lineValue(gapLength: 2500, belts: 3)),
        ],
      );

      await tester.tap(find.text('Preset A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Send to every'));
      await tester.pumpAndSettle();

      expect(stateMan.writes.map((w) => w.key), ['line_a', 'line_b']);

      final toShortLine = stateMan.writes.first.value;
      expect(toShortLine['gapLength'].asDouble, 2500);
      expect(toShortLine['belts'].asArray, hasLength(2),
          reason: 'a three-belt recipe must not lengthen a two-belt line');

      final toLongLine = stateMan.writes.last.value;
      expect(toLongLine['belts'].asArray, hasLength(3));
    });

    testWidgets('reports each line on its own, naming what did not land',
        (tester) async {
      final config = RecipesConfig(
        key: '',
        label: 'Line',
        keys: const ['line_a', 'line_b'],
        unifiedRecipe: true,
      );
      stateMan.push('line_a', lineValue(belts: 2));
      stateMan.push('line_b', lineValue(belts: 3));

      await pumpDialog(
        tester,
        config,
        recipes: [Recipe(name: 'Preset A', value: lineValue(belts: 3))],
      );

      await tester.tap(find.text('Preset A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Send to every'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Line 1: 5 of 7 values written'), findsOneWidget);
      expect(find.textContaining('Line 2: all 7 values written'), findsOneWidget);
      // Three separate controllers, so there is no atomicity to promise and
      // the wording does not pretend otherwise.
      expect(find.textContaining('written separately'), findsOneWidget);
    });

    testWidgets('a line that cannot be read is not written blind',
        (tester) async {
      final config = RecipesConfig(
        key: '',
        label: 'Line',
        keys: const ['line_a', 'line_b'],
        unifiedRecipe: true,
      );
      stateMan.push('line_a', lineValue(belts: 2));
      stateMan.push('line_b', lineValue(belts: 2));
      stateMan.unreadable.add('line_a');

      await pumpDialog(
        tester,
        config,
        recipes: [Recipe(name: 'Preset A', value: lineValue(belts: 2))],
      );

      await tester.tap(find.text('Preset A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Send to every'));
      await tester.pumpAndSettle();

      // Without the target's own shape the only thing left to write is the
      // recipe as it stands, which is the blind copy this path exists to
      // avoid. So that line is reported and skipped — and the other is still
      // attempted.
      expect(stateMan.writes.map((w) => w.key), ['line_b']);
      expect(find.textContaining('could not be read'), findsOneWidget);
    });

    testWidgets('per-line mode sends only the line that is selected',
        (tester) async {
      final config = RecipesConfig(
          key: '', label: 'Line', keys: const ['line_a', 'line_b']);
      stateMan.push('line_a', lineValue(belts: 2));
      stateMan.push('line_b', lineValue(belts: 2));

      await pumpDialog(
        tester,
        config,
        recipes: [Recipe(name: 'Preset A', value: lineValue(belts: 2))],
      );

      await tester.tap(find.text('Line 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preset A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send values'));
      await tester.pumpAndSettle();

      expect(stateMan.writes.map((w) => w.key), ['line_b']);
    });
  });
}
