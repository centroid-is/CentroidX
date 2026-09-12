import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart'
    show Coordinates, RelativeSize, TextPos;
import 'package:tfc/page_creator/assets/section_button.dart';
import 'package:tfc/pages/page_view.dart' show AssetStack;
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// Loads real fonts so the pane's labels render as letterforms and its icons
/// as glyphs instead of the test font's solid boxes — same arrangement as
/// `conveyor_gate_force_pane_golden_test`.
Future<void> loadRealFont() async {
  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }
}

/// The whole point of the button is that a hall full of sections reads as a
/// row of coloured lamps, and the whole point of the pane is that the three
/// commands are unambiguous. Both are things only an eye can check.
void main() {
  group('section button golden',
      skip: goldenSkip, () {
    setUpAll(loadRealFont);

    tearDown(() => closeSidePane(immediate: true));

    testWidgets('every state the disc can be in, side by side', (tester) async {
      final fake = _FakeStateMan()
        ..push('sec/run', enabled: true)
        ..push('sec/clean', cleaning: true)
        ..push('sec/stop')
        ..push('sec/blocked', permissive: false);
      // `sec/unknown` is deliberately never pushed — that is the state.

      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final keys in const [
                    ['sec/run'],
                    ['sec/clean'],
                    ['sec/stop'],
                    ['sec/blocked'],
                    ['sec/unknown'],
                    // Two sections that disagree: the slash is the whole
                    // point of this entry.
                    ['sec/run', 'sec/stop'],
                  ])
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: SectionButton(
                          config: SectionButtonConfig(
                            sections: [
                              for (final k in keys) SectionRef(key: k),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/section_button_states.png'),
      );
    });

    testWidgets('an exclusive pair beside the same two as peers',
        (tester) async {
      // The claim the whole feature rests on, and the only way to check it is
      // to look. Same two sections, same states — film in auto, vacuum held
      // off by the interlock — three times over:
      //
      //   1. declared as alternatives: ONE solid green disc, because the pair
      //      is one machine with a mode selector and the mode has the line.
      //   2. declared as peers (no tag): the diagonal split this asset has
      //      always drawn, which is what index 150 wore permanently.
      //   3. declared as alternatives but with the twin unreadable: still
      //      split, still wearing the `!` — a set that collapsed to the half
      //      it can read would be claiming a state it cannot see.
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      // `gone` is deliberately never pushed — that is the unreadable member.

      SectionButtonConfig cfg(List<SectionRef> refs) =>
          SectionButtonConfig(sections: refs);

      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final config in [
                    cfg([
                      SectionRef(key: 'film', exclusiveGroup: 'Line 2 packing'),
                      SectionRef(
                          key: 'vacuum', exclusiveGroup: 'Line 2 packing'),
                    ]),
                    cfg([
                      SectionRef(key: 'film'),
                      SectionRef(key: 'vacuum'),
                    ]),
                    cfg([
                      SectionRef(key: 'film', exclusiveGroup: 'Line 2 packing'),
                      SectionRef(key: 'gone', exclusiveGroup: 'Line 2 packing'),
                    ]),
                  ])
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: SectionButton(config: config),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/section_button_exclusive_face.png'),
      );
    });

    testWidgets('resting beside held down', (tester) async {
      // The disc now comes from `ButtonPainter`, the painter behind every
      // other button on a mimic — so it has the drop shadow, and under a
      // finger it shrinks and the shadow tightens with it. Before this, the
      // section button was a flat circle that did not move when pressed.
      final fake = _FakeStateMan()..push('sec/run', enabled: true);

      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 2; i++)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: SectionButton(
                          key: ValueKey(i),
                          config: SectionButtonConfig(
                            sections: [SectionRef(key: 'sec/run')],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);

      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey(1))));
      addTearDown(() => gesture.up());
      await _settle(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/section_button_pressed.png'),
      );
    });

    testWidgets('the same button named and unnamed, on a page',
        (tester) async {
      // The one thing the switch changes, and the only way to check it is to
      // look: two identical running sections laid out by `AssetStack`, one
      // captioned and one bare. Same disc, same place — the caption is the
      // whole difference.
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();

      final fake = _FakeStateMan()..push('sec/run', enabled: true);

      SectionButtonConfig button({required double x, required bool showName}) =>
          SectionButtonConfig(sections: [SectionRef(key: 'sec/run')])
            ..coordinates = Coordinates(x: x, y: 0.42)
            ..size = const RelativeSize(width: 0.09, height: 0.28)
            ..text = 'Before freezers'
            ..textPos = TextPos.below
            ..showName = showName;

      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 760,
                height: 260,
                child: LayoutBuilder(
                  builder: (context, constraints) => AssetStack(
                    assets: [
                      button(x: 0.3, showName: true),
                      button(x: 0.78, showName: false),
                    ],
                    constraints: constraints,
                    selectedAssets: const {},
                    mirroringDisabled: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/section_button_name_on_page.png'),
      );
    });

    group('pane', () {
      useTolerantGoldenComparator();

      Future<void> pumpPane(
        WidgetTester tester,
        String name, {
        bool enabled = false,
        bool cleaning = false,
        bool permissive = true,
        String? holdReason,
      }) async {
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fake = _FakeStateMan()
          ..push('sec/after',
              enabled: enabled, cleaning: cleaning, permissive: permissive);

        await tester.pumpWidget(ProviderScope(
          overrides: [stateManProvider.overrideWith((_) async => fake)],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 88,
                  height: 88,
                  child: SectionButton(
                    config: SectionButtonConfig(
                      sections: [
                        SectionRef(key: 'sec/after', holdReason: holdReason),
                      ],
                    )..text = name,
                  ),
                ),
              ),
            ),
          ),
        ));
        await _settle(tester);

        await tester.tap(find.byType(SectionButton));
        await _settle(tester);
      }

      testWidgets('running', (tester) async {
        await pumpPane(tester, 'After freezers', enabled: true);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_running.png'),
        );
      });

      testWidgets('cleaning', (tester) async {
        await pumpPane(tester, 'Before freezers', cleaning: true);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_cleaning.png'),
        );
      });

      testWidgets('a group whose sections disagree', (tester) async {
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fake = _FakeStateMan()
          ..push('sec/101', enabled: true)
          ..push('sec/201', enabled: true)
          ..push('sec/301');

        await tester.pumpWidget(ProviderScope(
          overrides: [stateManProvider.overrideWith((_) async => fake)],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 88,
                  height: 88,
                  child: SectionButton(
                    config: SectionButtonConfig(
                      sections: [
                        SectionRef(key: 'sec/101', label: 'ST101'),
                        SectionRef(key: 'sec/201', label: 'ST201'),
                        SectionRef(key: 'sec/301', label: 'ST301'),
                      ],
                    )..text = 'Before freezers',
                  ),
                ),
              ),
            ),
          ),
        ));
        await _settle(tester);
        await tester.tap(find.byType(SectionButton));
        await _settle(tester);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_group_mixed.png'),
        );
      });

      testWidgets('a group where one member is not allowed to start',
          (tester) async {
        // The state the summary row exists for. Two members running, the
        // third idle and held: the row reads `No for 1 of 3`, the held
        // member's own row reads `Can't start`, and the explanation names
        // which one it is and what to do about it.
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fake = _FakeStateMan()
          ..push('sec/101', enabled: true)
          ..push('sec/201', enabled: true)
          ..push('sec/301', permissive: false);

        await tester.pumpWidget(ProviderScope(
          overrides: [stateManProvider.overrideWith((_) async => fake)],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 88,
                  height: 88,
                  child: SectionButton(
                    config: SectionButtonConfig(
                      sections: [
                        SectionRef(key: 'sec/101', label: 'ST101'),
                        SectionRef(key: 'sec/201', label: 'ST201'),
                        SectionRef(
                          key: 'sec/301',
                          label: 'ST301',
                          holdReason: 'The washdown interlock on ST301 is '
                              'open. Close the guard and it is free.',
                        ),
                      ],
                    )..text = 'Before freezers',
                  ),
                ),
              ),
            ),
          ),
        ));
        await _settle(tester);
        await tester.tap(find.byType(SectionButton));
        await _settle(tester);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_group_held.png'),
        );
      });

      testWidgets('a choice between two alternatives', (tester) async {
        // The block this feature adds, and there is no substitute for looking
        // at it: the two members drawn together under the name of the choice
        // and stripped of their own `Run`, the mode with the line filled and
        // inert, the alternative live because the hand-over is switched on,
        // and — the point of the whole exercise — `Allowed to start` reading
        // `Yes` rather than the permanent `No for 1 of 2` the interlock used
        // to produce.
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fake = _FakeStateMan()
          ..push('st201/film', enabled: true)
          ..push('st201/vacuum', permissive: false);

        await tester.pumpWidget(ProviderScope(
          overrides: [stateManProvider.overrideWith((_) async => fake)],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 88,
                  height: 88,
                  child: SectionButton(
                    config: SectionButtonConfig(
                      allowModeSwitch: true,
                      sections: [
                        SectionRef(
                          key: 'st201/film',
                          label: 'Line 2 film',
                          exclusiveGroup: 'Line 2 packing',
                        ),
                        SectionRef(
                          key: 'st201/vacuum',
                          label: 'Line 2 vacuum',
                          exclusiveGroup: 'Line 2 packing',
                        ),
                      ],
                    )..text = 'Box packing',
                  ),
                ),
              ),
            ),
          ),
        ));
        await _settle(tester);
        await tester.tap(find.byType(SectionButton));
        await _settle(tester);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_exclusive_choice.png'),
        );
      });

      testWidgets('the wet-area button: peers and pairs in one list',
          (tester) async {
        // `/boxes/wet-area` index 150, the button this whole feature exists
        // for: three transport peers and two exclusive pairs. Five entries,
        // one shape each — the pairs are single rows carrying their own mode
        // buttons rather than two rows plus a separate choice section apiece,
        // which is what pushed the group commands below the fold.
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fake = _FakeStateMan()
          ..push('st101/t', enabled: true)
          ..push('st201/film', enabled: true)
          ..push('st201/vac', permissive: false)
          ..push('st201/t', enabled: true)
          ..push('st301/film')
          ..push('st301/vac')
          ..push('st301/t');

        await tester.pumpWidget(ProviderScope(
          overrides: [stateManProvider.overrideWith((_) async => fake)],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 88,
                  height: 88,
                  child: SectionButton(
                    config: SectionButtonConfig(
                      allowModeSwitch: true,
                      sections: [
                        SectionRef(key: 'st101/t', label: 'Line 1 transport'),
                        SectionRef(
                            key: 'st201/film',
                            label: 'Line 2 film',
                            exclusiveGroup: 'Line 2 packing'),
                        SectionRef(
                            key: 'st201/vac',
                            label: 'Line 2 vacuum',
                            exclusiveGroup: 'Line 2 packing'),
                        SectionRef(key: 'st201/t', label: 'Line 2 transport'),
                        SectionRef(
                            key: 'st301/film',
                            label: 'Line 3 film',
                            exclusiveGroup: 'Line 3 packing'),
                        SectionRef(
                            key: 'st301/vac',
                            label: 'Line 3 vacuum',
                            exclusiveGroup: 'Line 3 packing'),
                        SectionRef(key: 'st301/t', label: 'Line 3 transport'),
                      ],
                    )..text = 'Before freezers',
                  ),
                ),
              ),
            ),
          ),
        ));
        await _settle(tester);
        await tester.tap(find.byType(SectionButton));
        await _settle(tester);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_wet_area.png'),
        );
      });

      testWidgets("can't start, with a configured reason", (tester) async {
        // The per-section sentence is the point of this golden: the asset
        // ships only the generic line, and the page author supplies what
        // actually holds this one.
        await pumpPane(tester, 'Box packing film',
            permissive: false,
            holdReason: 'The vacuum mode has the line. Stop it and this one '
                'is free.');
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/section_pane_blocked.png'),
        );
      });
    });
  });
}

/// Pumps frames without `pumpAndSettle`, so the pane's opening glide is over
/// without depending on the whole tree reaching a quiet frame.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(
    String key, {
    bool enabled = false,
    bool cleaning = false,
    bool permissive = true,
  }) {
    final value = DynamicValue();
    for (final field in [
      kSectionCmdStart,
      kSectionCmdStartClean,
      kSectionCmdStop,
    ]) {
      value[field] = DynamicValue(value: false, typeId: NodeId.boolean);
    }
    value[kSectionStatEnabled] =
        DynamicValue(value: enabled, typeId: NodeId.boolean);
    value[kSectionStatCleanEnabled] =
        DynamicValue(value: cleaning, typeId: NodeId.boolean);
    value[kSectionStatPermissive] =
        DynamicValue(value: permissive, typeId: NodeId.boolean);
    _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).add(value);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<void> write(String key, DynamicValue value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
      );
}
