// Regression test for "tapping a Button asset's label text does nothing".
//
// Bug being fixed: In `AssetStack`, the runtime-mode (`absorb=false`) label
// is wrapped in a `GestureDetector(onSecondaryTapUp: ...)` with NO
// `behavior:` override (defaults to `HitTestBehavior.deferToChild`). The
// label `Positioned`-child is added AFTER the asset visual in the
// children list, so it paints (and hit-tests) ABOVE the asset body. With
// `TextPos.inside` (or any time the label overlaps the asset), the label
// swallows primary taps before they reach the Button's `InkWell`.
//
// Editor mode (`absorb=true`) already wraps the label in `IgnorePointer`,
// so this only affects runtime mode — which is exactly the operator path.
//
// Contract under test (RED before fix):
//   - When a Button asset with `TextPos.inside` and a label is rendered
//     by `AssetStack(absorb: false)`, tapping on the label text MUST
//     trigger the Button's InkWell tap callbacks (i.e. the tap must reach
//     through the label and into the Button body).
//
// We assert at the gesture-recorder level: we wrap Button in a custom
// host widget that records whether `onTapDown` fired on the InkWell.
// Reading the InkWell's `onTapDown != null` is not enough — the existing
// `button_widget_test.dart` already covers that. The new contract is
// specifically that a `tester.tap(find.text('LBL'))` actually delivers
// the gesture to the InkWell underneath, despite the overlaying label.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/color_converter.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Minimal fake. Button.onTapDown writes a BOOL to the configured key;
/// we capture those writes to detect that the tap reached the InkWell.
class _FakeStateMan implements StateMan {
  final List<({String key, bool value})> writes = [];
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    return s.stream;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add((key: key, value: value.asBool));
  }

  @override
  List<String> get keys => const <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}

Widget _wrap({
  required List<Asset> assets,
  required _FakeStateMan fake,
}) {
  return ProviderScope(
    overrides: [
      stateManProvider.overrideWith((_) async => fake),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: LayoutBuilder(
              builder: (context, constraints) => AssetStack(
                assets: assets,
                constraints: constraints,
                selectedAssets: const {},
                mirroringDisabled: true,
                // Runtime mode. This is the path the bug lives in.
                absorb: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'tapping a Button label (TextPos.inside) delivers the tap to the InkWell',
    (tester) async {
      final fake = _FakeStateMan();

      final config = ButtonConfig(
        key: 'cmd/start',
        outwardColor: AssetColor.literal(Colors.green),
        inwardColor: AssetColor.literal(Colors.grey),
        // Square so the label sits squarely inside the face — the
        // exact UX the user reported as broken.
        buttonType: ButtonType.square,
      )
        ..text = 'GO'
        ..textPos = TextPos.inside
        // Center the button in the 400x400 viewport, ~40% of width/height.
        ..coordinates = Coordinates(x: 0.5, y: 0.5)
        ..size = const RelativeSize(width: 0.4, height: 0.4);

      await tester.pumpWidget(_wrap(assets: [config], fake: fake));
      // Let the stateMan future + initial stream settle so the InkWell
      // has live tap callbacks.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Sanity: the label is in the tree and the Button is too.
      expect(find.text('GO'), findsOneWidget);
      expect(find.byType(Button), findsOneWidget);

      // Tap directly on the label text. With the bug present, the label's
      // GestureDetector (or its Text child via deferToChild) absorbs the
      // tap; nothing reaches the InkWell, so no write is recorded.
      //
      // `warnIfMissed: false` because the FIX wraps the label Text in
      // IgnorePointer — `find.text('GO')` finds the Text widget but its
      // RenderParagraph is now non-hit-testing. That is exactly the
      // shape we want: the tap lands on the InkWell directly below the
      // label, which is what `fake.writes` will prove.
      await tester.tap(find.text('GO'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        fake.writes,
        isNotEmpty,
        reason:
            'Tapping the Button label must deliver the tap to the InkWell '
            'underneath. The overlay label widget in AssetStack must not '
            'absorb primary taps in runtime mode.',
      );
      expect(
        fake.writes.first.key,
        'cmd/start',
        reason: 'Tap must be delivered to the configured Button key.',
      );
      expect(
        fake.writes.first.value,
        isTrue,
        reason: 'onTapDown must write true to the Button key.',
      );
    },
  );
}
