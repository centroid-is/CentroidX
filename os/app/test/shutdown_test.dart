import 'dart:async';
import 'dart:io';

import 'package:centroidx_setup/system.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reported from a panel: the install finished, the operator pressed Reboot,
/// and the machine sat there. The button greyed out and stayed grey.
///
/// Two separate faults, and these tests pin both. `reboot()` asked systemd once
/// and believed the answer -- so any refusal, and any acceptance that did not
/// actually take the machine down, ended the story. And the one place it said
/// so was a line appended to a 300px log already scrolled to its end, i.e.
/// below the fold (see progress_step_test.dart).
void main() {
  late List<List<String>> calls;
  final defaultRunProcess = runProcess;
  final defaultGrace = shutdownGrace;
  final defaultTimeout = shutdownCallTimeout;

  setUp(() => calls = []);

  tearDown(() {
    runProcess = defaultRunProcess;
    shutdownGrace = defaultGrace;
    shutdownCallTimeout = defaultTimeout;
  });

  /// Records the argv and answers with whatever [reply] decides.
  void answerWith(Future<ProcessResult> Function(List<String> args) reply) {
    runProcess = (exe, args) {
      calls.add([exe, ...args]);
      return reply(args);
    };
  }

  ProcessResult refused(String stderr) => ProcessResult(0, 1, '', stderr);

  group('the shutdown ladder', () {
    test('climbs all three rungs when the first is refused', () {
      fakeAsync((async) {
        answerWith((_) async =>
            refused('Failed to connect to bus: No such file or directory'));

        late String err;
        unawaited(reboot().then((v) => err = v));
        async.elapse(const Duration(minutes: 1));

        expect(calls, [
          ['systemctl', 'reboot'],
          ['systemctl', '--force', 'reboot'],
          ['systemctl', '--force', '--force', 'reboot'],
        ]);
        // Rung 3 is the one that cannot be refused by anything but the kernel:
        // sync() and reboot(2), no init system, no D-Bus, no logind.
        expect(err, contains('systemctl reboot: Failed to connect to bus'));
        expect(err, contains('systemctl --force --force reboot:'));
      });
    });

    test('does not sit through the grace period for a refusal', () {
      fakeAsync((async) {
        answerWith((_) async => refused('nope'));

        late String err;
        unawaited(reboot().then((v) => err = v));
        // No elapsed time at all: a refusal is an answer already, and three
        // rungs of waiting 10s each for one is 30 seconds of a panel doing
        // nothing visible.
        async.flushMicrotasks();

        expect(calls.length, 3);
        expect(err, contains('systemctl --force --force reboot'));
      });
    });

    test('gives an ACCEPTED rung the grace period before escalating past it',
        () {
      fakeAsync((async) {
        // The case a bare exit code cannot see: systemd took the job and the
        // machine is still here a breath later. `systemctl reboot` exiting 0
        // is a claim about the request, not about the machine.
        answerWith((_) async => ProcessResult(0, 0, '', ''));

        late String err;
        unawaited(reboot().then((v) => err = v));

        async.elapse(shutdownGrace - const Duration(milliseconds: 1));
        expect(calls.length, 1, reason: 'escalated before the grace was up');

        async.elapse(const Duration(milliseconds: 2));
        expect(calls.length, 2);

        async.elapse(const Duration(minutes: 1));
        expect(calls.length, 3);
        expect(err, contains('accepted, then nothing'));
      });
    });

    test('times a hung systemctl out instead of hanging with it', () {
      fakeAsync((async) {
        // A stop job that never finishes takes systemctl with it, and the
        // operator is left holding a disabled button for as long as the
        // machine cares to wait.
        answerWith((_) => Completer<ProcessResult>().future);

        late String err;
        unawaited(reboot().then((v) => err = v));
        async.elapse(const Duration(minutes: 5));

        expect(calls.length, 3);
        expect(err, contains('no answer in ${shutdownCallTimeout.inSeconds}s'));
      });
    });

    test('survives systemctl not being there at all', () {
      fakeAsync((async) {
        answerWith((args) async =>
            throw ProcessException('systemctl', args, 'No such file', 2));

        late String err;
        unawaited(reboot().then((v) => err = v));
        async.elapse(const Duration(minutes: 1));

        expect(calls.length, 3);
        expect(err, contains('No such file'));
      });
    });

    test('powerOff climbs the same ladder, with the poweroff verb', () {
      fakeAsync((async) {
        answerWith((_) async => refused('nope'));

        unawaited(powerOff());
        async.elapse(const Duration(minutes: 1));

        expect(calls, [
          ['systemctl', 'poweroff'],
          ['systemctl', '--force', 'poweroff'],
          ['systemctl', '--force', '--force', 'poweroff'],
        ]);
      });
    });
  });
}
