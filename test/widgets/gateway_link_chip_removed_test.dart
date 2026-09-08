/// The gateway-link chip is GONE, asserted at the source level.
///
/// Why source-level: the four `appbar_clock_*.png` goldens are structurally
/// blind to this — the app bar's right cluster is `Align(centerRight)`, so
/// removing the chip can move NO pixel in a frame where it rendered
/// `SizedBox.shrink()`. Plan 15-06's own sabotage discovered that blindness
/// in one direction; this file is the guard against repeating it in reverse
/// (a passing golden is not proof the chip is gone, and neither would it be
/// proof the chip came back). The rendered-absence half lives in
/// `base_scaffold_gateway_alarm_test.dart`, which pins that a healthy
/// gateway link puts NO text on the bar; this half pins that the widget
/// cannot come back quietly, because its file and every reference to it are
/// grepped for.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every Dart file under lib/, recursively.
Iterable<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('lib/widgets/gateway_link_chip.dart does not exist', () {
    expect(File('lib/widgets/gateway_link_chip.dart').existsSync(), isFalse,
        reason: 'the chip was replaced by the local gateway alarm '
            '(lib/core/local_gateway_alarm.dart); resurrecting the file '
            'means two surfaces reporting the same link');
  });

  test('nothing in lib/ references the chip', () {
    // Live control first: the scan must be able to see anything at all —
    // a wrong working directory would make the arm below pass vacuously.
    final sources = _libSources().toList();
    expect(
        sources.any(
            (f) => f.readAsStringSync().contains('class BaseScaffold')),
        isTrue,
        reason: 'control — the scan found no BaseScaffold, so it is not '
            'reading the sources this test thinks it is');

    final offenders = <String>[];
    for (final file in sources) {
      final text = file.readAsStringSync();
      if (text.contains('GatewayLinkChip') ||
          text.contains('gateway_link_chip')) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'the chip is deleted; these files still name it: '
            '$offenders');
  });

  test('nothing under test/ still drives the chip widget', () {
    final offenders = Directory('test')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.dart') &&
            !f.path.endsWith('gateway_link_chip_removed_test.dart') &&
            f.readAsStringSync().contains('GatewayLinkChip'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty,
        reason: 'a test that still imports or names the chip is a test '
            'that fails to compile the day this suite is trusted: '
            '$offenders');
  });
}
