@TestOn('vm')
/// The kernel's ageing path is scanned for the wall clock — and this arm exists
/// because 18-03's own move hollowed out the arm that used to do it.
///
/// ## The hole, and how it was made
///
/// `tfc_dart`'s `backend_freshness_test.dart` carries an arm named *"the ageing
/// anchor is monotonic: no DateTime.now on the ageing path"*. It is a **source
/// scan**: it opens `lib/core/relay/backend_freshness.dart`, strips the
/// comments, and asserts `Stopwatch` is present while `DateTime.now` and
/// `DateTime.timestamp` are absent. It is written that way deliberately, and
/// the reasoning in it is right — a Dart test cannot step the machine's wall
/// clock, and there is no injectable clock seam to hand in because a seam that
/// accepts a steppable clock is a seam somebody steps.
///
/// **But it names a path, and 18-03 moved half of what it was guarding out of
/// that path.** The subtraction `nowMs - lastHeardMs < staleAfter` now lives in
/// `tfc_relay_protocol/lib/src/freshness.dart`, which that arm does not read
/// and cannot see. Put `DateTime.now()` inside `isStaleNow` — have it ignore
/// the `nowMs` it was handed and read the clock itself — and the arm in
/// `tfc_dart` stays **green**, because the file it scans still holds its
/// `Stopwatch` and still holds no `DateTime`. Verified by mutation, not
/// assumed.
///
/// That is the general failure: *a pin that reads a path goes vacuous when the
/// content moves, silently, staying green.* This file is the other half of that
/// pin, scanning the file the content moved into, so the two together cover the
/// whole ageing path again. It is separate from `freshness_test.dart` because
/// that file is deliberately free of `dart:io` and runs under `dart2js` as well
/// as on the VM; this one cannot.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the shared ageing path reads no wall clock', () {
    final source = File('lib/src/freshness.dart');
    expect(source.existsSync(), isTrue,
        reason: 'the scan cannot judge a file it cannot find; this arm runs '
            'from the package root');

    final code = source
        .readAsLinesSync()
        .where((line) {
          final t = line.trimLeft();
          return !t.startsWith('//') && !t.startsWith('///');
        })
        .join('\n');

    expect(code, contains('nowMs - lastHeardMs'),
        reason: 'the live control. Without it this arm would pass against a '
            'file that had stopped doing the subtraction at all, which is the '
            'exact way a source scan becomes a gate that cannot bite');

    expect(code, isNot(contains('DateTime.now')),
        reason: 'freshness ages on an elapsed counter handed in by the caller, '
            'never on the RTC: a backwards NTP step larger than the deadline '
            'made the old subtraction negative for every key at once and the '
            'whole plant read fresh from PLCs nobody had heard from '
            '(08-REVIEW CR-02)');
    expect(code, isNot(contains('DateTime.timestamp')),
        reason: 'the same wall clock under a different name');
    expect(code, isNot(contains('Stopwatch')),
        reason: 'and not its own anchor either — two sweeps measuring against '
            'two different origins would disagree about the same key, which '
            'is why each caller owns one anchor and hands in readings from it');
  });

  test('the kernel takes no clock argument, so none can be handed in', () {
    // The structural half of the same property. `isStaleNow`'s parameter list
    // is the whole surface a caller can reach, and it carries two `int`
    // readings and no function. A seam that accepted a `DateTime Function()`
    // would be a seam somebody eventually passes `DateTime.now` to.
    final code = File('lib/src/freshness.dart').readAsStringSync();
    final signature = code.substring(
        code.indexOf('bool isStaleNow({'), code.indexOf('}) {'));

    expect(signature, contains('required int? lastHeardMs'));
    expect(signature, contains('required int nowMs'));
    expect(signature, isNot(contains('Function')),
        reason: 'no clock seam, deliberately');
    expect(signature, isNot(contains('DateTime')),
        reason: 'the anchor is elapsed milliseconds and nothing else');
    expect(signature, contains('required bool skipAlarmKeys'),
        reason: 'required and undefaulted: the one behavioural difference '
            'between the two sweeps must be visible at both call sites, and a '
            'default is what made it invisible in the first place');
  });
}
