/// The HMI's own animations run in real time whatever the platform asks.
///
/// See `lib/widgets/hmi_motion.dart` for why. Two halves: the sweep keeps a
/// new controller from quietly opting back in to Flutter's 5% scaling, and
/// the widget arm shows what the setting does to a controller under the
/// flag a browser in a Remote Desktop session raises.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/hmi_motion.dart';

/// Every `AnimationController(...)` call under `lib/`, as file:line and the
/// text of its argument list.
List<(String, String)> _controllers() {
  final found = <(String, String)>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
    final source = entity.readAsStringSync();
    var from = 0;
    while (true) {
      final at = source.indexOf('AnimationController(', from);
      if (at < 0) break;
      var depth = 0;
      var end = at + 'AnimationController'.length;
      for (; end < source.length; end++) {
        final c = source[end];
        if (c == '(') depth++;
        if (c == ')' && --depth == 0) break;
      }
      final line = '\n'.allMatches(source.substring(0, at)).length + 1;
      found.add(('$path:$line', source.substring(at, end + 1)));
      from = end;
    }
  }
  return found;
}

void main() {
  test('every AnimationController under lib/ runs in real time', () {
    final controllers = _controllers();
    expect(controllers, isNotEmpty,
        reason: 'a sweep that finds nothing proves nothing');
    final missing = [
      for (final (where, call) in controllers)
        if (!call.contains('kHmiAnimationBehavior')) where,
    ];
    expect(missing, isEmpty,
        reason: 'these controllers run at 5% of their duration in a browser '
            'whose OS has animation effects off, which every Remote Desktop '
            'session does by default. Pass '
            '`animationBehavior: kHmiAnimationBehavior`:\n'
            '${missing.join('\n')}');
  });

  testWidgets('under reduced motion, a controller keeps its full duration',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final hmi = AnimationController(
        vsync: const TestVSync(),
        animationBehavior: kHmiAnimationBehavior,
        duration: const Duration(milliseconds: 800));
    final stock = AnimationController(
        vsync: const TestVSync(), duration: const Duration(milliseconds: 800));
    addTearDown(hmi.dispose);
    addTearDown(stock.dispose);

    hmi.forward();
    stock.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(stock.value, 1.0,
        reason: 'the premise: Flutter finishes an 800 ms controller in 40 ms '
            'when the platform asks for reduced motion');
    expect(hmi.value, closeTo(0.5, 0.01),
        reason: 'half the stroke time in, half the stroke drawn');

    await tester.pump(const Duration(milliseconds: 500));
    expect(hmi.isCompleted, isTrue);
  });
}
