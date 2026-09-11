/// The package's one error seam, judged on how much it writes.
///
/// `reportToStderr` is what a deployed gateway gets by default, so what it
/// emits is a plant operations question and not a formatting preference: this
/// runs on a machine in a fish factory whose disk is not large and whose
/// stderr is where somebody looks when a line has stopped.
///
/// 05-REVIEW WR-03 is the reason there is a case here at all. A pre-`hello`
/// tick flood used to drive one exception and one full stack trace per frame
/// through this function, at whatever rate an unauthenticated peer felt like
/// sending — the trace being the larger half by an order of magnitude. The
/// session no longer throws for that condition, and this is the second belt:
/// a caller that passes [StackTrace.empty] is saying "this is a condition, the
/// message is the whole report", and anything with a real trace still gets it.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_server/src/error_reporter.dart';

/// A `Stdout` that keeps what was written to it.
///
/// `implements` plus `noSuchMethod`, because `Stdout` is a large interface and
/// this file cares about exactly one member of it.
final class _Captured implements Stdout {
  final lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

List<String> _report(Object error, StackTrace stack, String where) {
  final captured = _Captured();
  IOOverrides.runZoned(
    () => reportToStderr(error, stack, where),
    stderr: () => captured,
  );
  return captured.lines;
}

void main() {
  test('a real failure is reported with its trace', () {
    final lines =
        _report(StateError('the sink threw'), StackTrace.current, 'tick');

    expect(lines, hasLength(2),
        reason: 'a defect without its trace is a defect nobody can locate, '
            'and every one of these the Phase 3 review reproduced was found '
            'through the trace and not the message');
    expect(lines.first, contains('tick'));
    expect(lines.first, contains('the sink threw'));
    expect(lines.last, isNotEmpty);
  });

  test('a condition a peer can produce at will is one line', () {
    final lines = _report('a "h" notification arrived before hello',
        StackTrace.empty, 'notification gate');

    expect(lines, hasLength(1),
        reason: 'the trace is the larger half of the report and it points at '
            'the dispatcher, not at anything wrong. Written once per frame '
            'for a condition reachable by anyone who completes the WebSocket '
            'upgrade, it is the peer deciding how much of the gateway\'s disk '
            'to use: $lines');
    expect(lines.single, contains('notification gate'),
        reason: 'the seam is what tells a reader which of these it is');
    expect(lines.single, contains('before hello'));
  });
}
