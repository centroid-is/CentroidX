/// The F16 harness fails rather than hangs.
///
/// **Why this is a case and not a comment.** `suspend_harness.dart` is driven
/// only from `test/gate/`, and every arm there asserts something about a panel
/// that came up. Nothing asserted anything about a panel that *did not* — so
/// the one path with no observer on it was the one where `spawn` waited for a
/// message nobody was left to send, and a case hit by it failed as a
/// suite-level timeout naming no file, no case and no cause (07-REVIEW WR-08).
///
/// It lives outside `test/gate/` deliberately: it injects no fault, gates no
/// catalogue row, and a case in that directory that does neither has to be
/// argued into `_supportingCases` before the manifest will accept it. This is a
/// statement about the instrument, so it belongs beside the other instrument
/// cases rather than among the rows.
library;

import 'package:test/test.dart';

import 'support/suspend_harness.dart';

void main() {
  test('a panel isolate that dies before it comes up fails the case', () async {
    // `wss` with no pinned root is refused by `ClientConfig.checkDialable` in
    // `RemoteStateMan`'s constructor — a real refusal, chosen because it
    // happens *before* the isolate can send anything, which is exactly the
    // shape (a bad URI, a config that fails validation, a missing native
    // asset) that used to hang. `errorsAreFatal: false` swallowed it and
    // `up.future` stayed uncompleted for the life of the run.
    await expectLater(
      SuspendedPanel.spawn(uri: Uri.parse('wss://127.0.0.1:1')),
      throwsA(isA<StateError>().having((error) => error.message, 'message',
          contains('died before it came up'))),
      reason: 'a panel isolate that threw in its own construction did not '
          'fail this case. The harness states the doctrine for `ask` — "fails '
          'naming the command rather than hanging" — and the handshake that '
          'precedes every `ask` did not follow it',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
