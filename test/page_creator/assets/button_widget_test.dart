import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/color_converter.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Widget tests for the disabled-key gating in ButtonConfig.
///
/// These tests exercise the public `_buildButton` render path through the
/// `Button` widget by feeding fake key streams via a `_FakeStateMan` /
/// `stateManProvider` override.
///
/// The contract under test:
///   - `disabledKey == null`                              → always interactive
///   - stream=true  + polarity=disableWhenTrue            → DISABLED
///   - stream=false + polarity=disableWhenTrue            → interactive
///   - stream=true  + polarity=disableWhenFalse           → interactive
///   - stream=false + polarity=disableWhenFalse           → DISABLED
///
/// "DISABLED" means: the InkWell rendered by Button has no tap callbacks
/// AND the button face paints in `disabledColor`.
void main() {
  Widget wrap({
    required Widget child,
    List<Override> overrides = const [],
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  /// Finds the button's interactive `InkWell` — the one that holds the
  /// onTapDown/Up/Cancel callbacks. There is exactly one inside `Button`.
  Finder buttonInkWell() => find.descendant(
        of: find.byType(Button),
        matching: find.byType(InkWell),
      );

  /// Reads the rendered face color via the `ButtonPainter` painter.
  Color paintedColor(WidgetTester tester) {
    final cp = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(Button),
        matching: find.byType(CustomPaint),
      ),
    );
    return (cp.painter as ButtonPainter).color;
  }

  group('disabledKey == null → always interactive', () {
    testWidgets('preview button with no disabledKey has tap callbacks',
        (tester) async {
      final config = ButtonConfig.preview();
      await tester.pumpWidget(wrap(
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      // Allow the stateManProvider future to settle (preview path falls
      // through to outwardColor on error).
      await tester.pump();

      final inkwell = tester.widget<InkWell>(buttonInkWell());
      expect(inkwell.onTapDown, isNotNull,
          reason:
              'preview button without disabledKey must remain interactive');
      expect(inkwell.onTapUp, isNotNull);
      expect(inkwell.onTapCancel, isNotNull);
    });
  });

  group('disabledKey set + stream true', () {
    testWidgets('polarity=disableWhenTrue + stream=true → disabled + tinted',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('lock/key', true);

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: AssetColor.literal(Colors.green),
        inwardColor: AssetColor.literal(Colors.grey),
        buttonType: ButtonType.circle,
      )
        ..disabledKey = 'lock/key'
        ..disabledPolarity = DisabledPolarity.disableWhenTrue
        ..disabledColor = const Color(0xFFAABBCC);

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      // Let async chain (stateMan future + subscribe stream) settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final inkwell = tester.widget<InkWell>(buttonInkWell());
      expect(inkwell.onTapDown, isNull,
          reason: 'disableWhenTrue + stream=true must clear onTapDown');
      expect(inkwell.onTapUp, isNull);
      expect(inkwell.onTapCancel, isNull);
      expect(paintedColor(tester), const Color(0xFFAABBCC),
          reason: 'disabled state must render in disabledColor');
    });

    testWidgets('polarity=disableWhenFalse + stream=true → interactive',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('lock/key', true);

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: AssetColor.literal(Colors.green),
        inwardColor: AssetColor.literal(Colors.grey),
        buttonType: ButtonType.circle,
      )
        ..disabledKey = 'lock/key'
        ..disabledPolarity = DisabledPolarity.disableWhenFalse
        ..disabledColor = const Color(0xFFAABBCC);

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final inkwell = tester.widget<InkWell>(buttonInkWell());
      expect(inkwell.onTapDown, isNotNull,
          reason:
              'disableWhenFalse + stream=true must leave button interactive');
      expect(inkwell.onTapUp, isNotNull);
      expect(inkwell.onTapCancel, isNotNull);
    });
  });

  group('disabledKey set + stream false', () {
    testWidgets('polarity=disableWhenTrue + stream=false → interactive',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('lock/key', false);

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: AssetColor.literal(Colors.green),
        inwardColor: AssetColor.literal(Colors.grey),
        buttonType: ButtonType.circle,
      )
        ..disabledKey = 'lock/key'
        ..disabledPolarity = DisabledPolarity.disableWhenTrue;

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final inkwell = tester.widget<InkWell>(buttonInkWell());
      expect(inkwell.onTapDown, isNotNull);
      expect(inkwell.onTapUp, isNotNull);
      expect(inkwell.onTapCancel, isNotNull);
    });

    testWidgets('polarity=disableWhenFalse + stream=false → disabled + tinted',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('lock/key', false);

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: AssetColor.literal(Colors.green),
        inwardColor: AssetColor.literal(Colors.grey),
        buttonType: ButtonType.circle,
      )
        ..disabledKey = 'lock/key'
        ..disabledPolarity = DisabledPolarity.disableWhenFalse
        ..disabledColor = const Color(0xFF112233);

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final inkwell = tester.widget<InkWell>(buttonInkWell());
      expect(inkwell.onTapDown, isNull);
      expect(inkwell.onTapUp, isNull);
      expect(inkwell.onTapCancel, isNull);
      expect(paintedColor(tester), const Color(0xFF112233));
    });
  });

  // ----- feedback color follows live PLC bit, not local press state -----
  //
  // The Button asset's `FeedbackConfig` binds a PLC bool key. The visual
  // contract:
  //
  //   * feedback key value == true    → button face = feedback!.color,
  //                                     REGARDLESS of whether the operator
  //                                     is currently touching the button.
  //                                     This is the bug the user reported:
  //                                     releasing the touch must NOT flip
  //                                     the color back to outwardColor while
  //                                     the PLC has the feedback bit latched.
  //   * feedback key value == false   → button paints in inward/outward
  //                                     based purely on local press state
  //                                     (current behaviour predating this
  //                                     contract).
  //   * `disabled` still trumps feedback (highest priority).
  //
  // These tests pump a feedback BOOL value into a fake StateMan and then
  // simulate a press-and-release gesture. The painted color is read via
  // `paintedColor(tester)`.
  group('feedback color follows live PLC bit, not local press state', () {
    testWidgets('feedback==true + tap down + tap up → stays feedbackColor',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/key', true); // PLC has latched feedback on

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: const AssetColor.literal(Color(0xFFFF0000)), // red
        inwardColor: const AssetColor.literal(Color(0xFF800000)), // dark red
        buttonType: ButtonType.square,
      )..feedback = (FeedbackConfig()
        ..key = 'fb/key'
        ..color = const AssetColor.literal(Color(0xFF00FF00)) /* green */);

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Sanity: idle paint while feedback==true must already be green —
      // press has not happened yet.
      expect(paintedColor(tester), const Color(0xFF00FF00),
          reason: 'idle + feedback=true must paint feedbackColor');

      // Press the button.
      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(Button)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // While pressed AND feedback bit still true → must still be green.
      expect(paintedColor(tester), const Color(0xFF00FF00),
          reason:
              'pressed + feedback=true must paint feedbackColor (feedback '
              'wins over local press state)');

      // Release the gesture. Feedback bit is still latched true on the PLC.
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The bug: after release, color flips back to outwardColor even
      // though the PLC feedback bit is still true. Correct behaviour:
      // color must remain feedbackColor until the PLC's feedback bit
      // itself goes false.
      expect(paintedColor(tester), const Color(0xFF00FF00),
          reason:
              'released + feedback=true must STILL paint feedbackColor '
              '(the PLC has not cleared its feedback bit yet)');
    });

    testWidgets('feedback==false + tap down → inwardColor (press visible)',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/key', false); // PLC has NOT latched feedback

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: const AssetColor.literal(Color(0xFFFF0000)),
        inwardColor: const AssetColor.literal(Color(0xFF800000)),
        buttonType: ButtonType.square,
      )..feedback = (FeedbackConfig()
        ..key = 'fb/key'
        ..color = const AssetColor.literal(Color(0xFF00FF00)));

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Idle + feedback=false → outwardColor.
      expect(paintedColor(tester), const Color(0xFFFF0000),
          reason: 'idle + feedback=false must paint outwardColor');

      // Press. Feedback still false. The local press should show through.
      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(Button)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(paintedColor(tester), const Color(0xFF800000),
          reason:
              'pressed + feedback=false must paint inwardColor — the PLC '
              'has not asserted feedback, so the operator still gets a '
              'momentary tactile press visual');

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Release + still false → outwardColor.
      expect(paintedColor(tester), const Color(0xFFFF0000),
          reason: 'released + feedback=false must paint outwardColor');
    });

    testWidgets('feedback flips true→false mid-hold → color flips back',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/key', true);

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: const AssetColor.literal(Color(0xFFFF0000)),
        inwardColor: const AssetColor.literal(Color(0xFF800000)),
        buttonType: ButtonType.square,
      )..feedback = (FeedbackConfig()
        ..key = 'fb/key'
        ..color = const AssetColor.literal(Color(0xFF00FF00)));

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(width: 80, height: 80, child: Button(config)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(Button)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(paintedColor(tester), const Color(0xFF00FF00));

      // PLC clears the feedback bit while operator is still holding.
      fake.push('fb/key', false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Color should now follow the live bit → inwardColor (still
      // pressed, but feedback is gone).
      expect(paintedColor(tester), const Color(0xFF800000),
          reason:
              'feedback flipping to false mid-hold must surface the press '
              'visual (inwardColor)');

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    });
  });

  // ----- textColor (optional label color override) editor tests -----
  //
  // The editor mirrors the `disabledColor` pattern but adds an explicit
  // "Default" / "Custom" SegmentedButton so the operator can return to the
  // theme default (textColor=null) at any time. The toggle's state is
  // *derived* from `textColor == null` — there is no separate
  // `useDefaultTextColor` JSON field.
  group('ButtonConfig editor — textColor toggle', () {
    // The asset's `configure(context)` builds the editor inside a
    // ProviderScope-free MaterialApp. It uses providers for KeyField, so
    // we override `stateManProvider` with a _FakeStateMan to prevent
    // network/native code from running during the test.
    Future<void> pumpEditor(
      WidgetTester tester,
      ButtonConfig config,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stateManProvider.overrideWith((_) async => _FakeStateMan()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => config.configure(ctx),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('editor renders the Default/Custom toggle', (tester) async {
      final config = ButtonConfig.preview();
      await pumpEditor(tester, config);

      // The toggle is identified by an exported key so external tests can
      // probe it without depending on private types.
      expect(find.byKey(const ValueKey('text-color-mode')), findsOneWidget,
          reason:
              'editor must expose a segmented toggle keyed "text-color-mode"');
      expect(find.text('Default'), findsWidgets);
      expect(find.text('Custom'), findsWidgets);
    });

    testWidgets(
        'toggling Custom -> Default clears textColor to null',
        (tester) async {
      final config = ButtonConfig.preview()..textColor = const Color(0xFFAB12CD);
      await pumpEditor(tester, config);

      // The editor lives in a SingleChildScrollView; the toggle is part
      // of the way down the form, so make sure it's visible before
      // tapping. Find by key first (unique), then by segment label.
      await tester.ensureVisible(find.byKey(const ValueKey('text-color-mode')));
      await tester.pumpAndSettle();

      // The "Default" segment label sits inside the segmented button.
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('text-color-mode')),
        matching: find.text('Default'),
      ));
      await tester.pumpAndSettle();

      expect(config.textColor, isNull,
          reason: 'switching to Default must null out the configured color');
    });

    testWidgets(
        'toggling Default -> Custom assigns a non-null textColor',
        (tester) async {
      final config = ButtonConfig.preview();
      expect(config.textColor, isNull);

      await pumpEditor(tester, config);

      await tester.ensureVisible(find.byKey(const ValueKey('text-color-mode')));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('text-color-mode')),
        matching: find.text('Custom'),
      ));
      await tester.pumpAndSettle();

      expect(config.textColor, isNotNull,
          reason:
              'switching to Custom must set a non-null seed color so the '
              'picker has something to render');
    });
  });
}

/// Minimal stand-in for [StateMan] that lets tests push synchronous values
/// for a given key. Only the methods used by Button (`subscribe`, `write`)
/// are implemented; everything else throws so accidental usage is loud.
class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  /// Record of every `write(key, value)` Button has made. Tests can assert
  /// against this when the press path needs to be verified.
  final List<(String, bool)> writes = <(String, bool)>[];

  void push(String key, bool value) {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    s.add(DynamicValue(value: value, typeId: NodeId.boolean));
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    return s.stream;
  }

  /// Records the write so the press-path doesn't crash on noSuchMethod when
  /// the production button writes to its command key on tap-down/up/cancel.
  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add((key, value.asBool));
  }

  // KeyField (used by the editor's KeyField widgets) reads `keys` to
  // populate its search dialog. Return an empty list so tests don't
  // crash building the editor.
  @override
  List<String> get keys => const <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}
