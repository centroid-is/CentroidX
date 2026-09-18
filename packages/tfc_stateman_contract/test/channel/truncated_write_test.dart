/// CR-01, end to end: a write whose result is truncated on the wire never
/// settles for a client that carries no deadline of its own.
///
/// The Phase 1 review cycle queued this case as "a truncated write result must
/// surface as an unknown outcome, never a throw". The measured failure is worse
/// than that and much quieter: `json_rpc_2.Peer` does not fail the pending
/// request at all. It replies `-32700` to the sender, stays open, keeps
/// answering everything else, and leaves `ChannelStateMan.write`'s future
/// pending forever (RESEARCH Finding 15). So there is no throw to convert into
/// an unknown, and no event anywhere for a caller to notice.
///
/// What that is, on a plant: an operator presses start, the outcome never
/// arrives, and the write box sits there. Nothing has failed — nothing has been
/// reported at all — so the operator presses it again, on a machine that may
/// already have moved. That is the write-safety property in `CLAUDE.md` losing
/// to silence rather than to a retry.
///
/// **The fix exists now, and it is not this client's.** Phase 4 landed the
/// per-request deadline in `RemoteStateMan`, and the flipped assertion — the
/// same corruption on the same key, resolving as an honest `WriteUnknown`
/// inside that deadline — lives in
/// `packages/tfc_relay_client/test/truncated_write_test.dart`. It is there
/// rather than here on purpose: asserting it in this package would make the
/// client a dev dependency of the suite that judges it, and a judge that
/// depends on a defendant is the edge this project keeps grep-checkable
/// elsewhere. The two files are a pair and each names the other by path, so
/// they cannot drift apart unnoticed.
///
/// So this file's polarity does **not** flip, and the reason is the honest one
/// rather than an oversight: `ChannelStateMan` has no deadline and is not going
/// to get one. The deadline deliberately does not live there
/// (`channel_state_man.dart:193-206` says so at the call site) — inventing one
/// would hide the thing this file exists to show, which is what the envelope
/// alone does with a truncated answer. What changed is what the assertions
/// below *claim*: they are no longer a bug report waiting for a fix, they are
/// the measured behaviour of a client that carries no deadline of its own, and
/// the price of not carrying one.
///
/// Assertion mechanism, from `lib/src/meta.dart:60-79` with the polarity
/// inverted: await into a plain bool through `onTimeout`, then assert on the
/// bool. A completes-matcher or a throws-matcher would let the deadline escape
/// as a raw `TimeoutException` — the undiagnosable failure that idiom exists to
/// forbid — and the runner would report this file's name rather than the write
/// an operator lost. Both are grep-enforced and therefore not named in prose.
@Tags(['meta'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';

const _setpointKey = 'ST101.CN01.MOT01.setpoint';

/// How long a write is given before it is called unsettled.
///
/// Short on purpose. The hang is infinite, so any budget proves it; what a
/// short one additionally proves is that the assertion — not the runner — is
/// what ends the case.
const _budget = Duration(milliseconds: 400);

/// Bounds the whole file, so a regression that turns a budgeted assertion back
/// into a runner-timeout hang is itself caught.
const _fileBudget = Duration(seconds: 5);

/// Damages the write result and nothing else.
///
/// `"outcome"` is `WriteResult.toJson`'s discriminator
/// (`write_result.dart:112-152`) and appears in no other message the served
/// source sends, so this lands on the write's answer and leaves the value
/// notifications around it intact. One surgical change, so what follows is
/// attributable to it.
MessageCorruption _truncateTheWriteResult() =>
    onFirstMatching((message) => message.contains('"outcome"'), truncate(0.9));

void main() {
  final wall = Stopwatch()..start();

  test('a client with no deadline of its own never settles a truncated write '
      'result', () async {
    final harness = serveFakeOverChannel(
      corruptServerToClient: _truncateTheWriteResult(),
    );
    addTearDown(harness.api.dispose);
    harness.served.setValue(_setpointKey, 1200);

    final attempt = await _attemptWrite(harness.api, 1500);

    expect(
      attempt.settled,
      isFalse,
      reason: 'the write SETTLED, and this test is the reason to care which '
          'way. A truncated result was measured to leave the future pending '
          'forever (Finding 15): the operator is told nothing — not applied, '
          'not failed, not unknown — so the write box stays as it was and the '
          'operator will re-send a command the plant may already have taken. '
          'If it settles now, something in this path grew a deadline. That is '
          'good news in the wrong place: the settling belongs to a client that '
          'owns one, and Phase 4 put that assertion in '
          'packages/tfc_relay_client/test/truncated_write_test.dart where it '
          'is judged against a real socket. Find what added the timeout here, '
          'because this file can no longer show what the envelope alone does. '
          'Resolved with ${attempt.outcome}, failed with ${attempt.failure}',
    );
    expect(
      attempt.failure,
      isNull,
      reason: 'the write failed with ${attempt.failure}. A throw would be the '
          'good outcome and it is not what happens — a caller can catch a '
          'throw and tell the operator the result is unknown. Silence is what '
          'this file exists to pin down',
    );
  });

  test('the session survives it: a following write resolves normally',
      () async {
    // What makes the hang quiet instead of loud. If a truncated frame took the
    // link down, the operator would see a disconnected page; instead the page
    // stays live, every other value keeps updating, and exactly one command
    // has disappeared.
    final harness = serveFakeOverChannel(
      corruptServerToClient: _truncateTheWriteResult(),
    );
    addTearDown(harness.api.dispose);
    harness.served.setValue(_setpointKey, 1200);

    final swallowed = await _attemptWrite(harness.api, 1500);
    expect(swallowed.settled, isFalse, reason: 'the arm did not arm');

    final second = await _attemptWrite(harness.api, 1600);
    expect(
      second.settled,
      isTrue,
      reason: 'the second write did not settle either, so the corruption is '
          'not one-shot and this file would be proving that a dead channel '
          'answers nothing — a fact about the injector, not about the peer',
    );
    expect(second.outcome, isA<WriteResult>(),
        reason: 'the second write settled with ${second.failure}');
  });

  test('the control arm: without the corruption the same write resolves',
      () async {
    // Without this, a harness broken for some unrelated reason would make the
    // hang assertion above pass for the wrong reason.
    final harness = serveFakeOverChannel();
    addTearDown(harness.api.dispose);
    harness.served.setValue(_setpointKey, 1200);

    final attempt = await _attemptWrite(harness.api, 1500);

    expect(attempt.settled, isTrue,
        reason: 'an uncorrupted write did not come back inside $_budget, so '
            'the hang above is a property of the harness rather than of the '
            'truncation');
    expect(
      attempt.outcome,
      isA<WriteApplied>(),
      reason: 'the control write came back as ${attempt.outcome}. Every arm '
          'of WriteResult is terminal, but this one should apply — a rejected '
          'or unknown control means the source is not in the state the hang '
          'case assumes',
    );
  });

  test('the whole case costs less than its budget', () {
    print('the truncated-write proof ran in ${wall.elapsed.inMilliseconds} ms '
        '(budget ${_fileBudget.inSeconds} s)');
    expect(
      wall.elapsed,
      lessThan(_fileBudget),
      reason: 'an unsettled write must be reported by its own deadline. If '
          'this file starts costing tens of seconds, the assertion has '
          'stopped bounding its await and the runner is failing it instead — '
          'which names a file rather than the command an operator lost',
    );
  });
}

/// One write, and what became of it inside [_budget].
final class _Attempt {
  _Attempt(this.settled, this.outcome, this.failure);

  final bool settled;
  final WriteResult? outcome;
  final Object? failure;
}

/// Issues one write and converts a missing answer into a bool.
///
/// The idiom is `meta.dart:60-79`'s, inverted: the deadline is caught here and
/// turned into data, so the caller asserts on a bool and gets a `TestFailure`
/// carrying its reason. An error is captured rather than allowed to escape,
/// both because a throw is a distinct outcome worth asserting the absence of
/// and because a peer closed at teardown completes its pending requests with
/// one — which, unhandled, would surface as an unrelated async failure long
/// after the case that caused it.
Future<_Attempt> _attemptWrite(StateManApi api, Object? value) async {
  var settled = true;
  WriteResult? outcome;
  Object? failure;

  await api.write(_setpointKey, value).then<WriteResult?>(
    (result) {
      outcome = result;
      return result;
    },
    onError: (Object error) {
      failure = error;
      return null;
    },
  ).timeout(_budget, onTimeout: () {
    settled = false;
    return null;
  });

  return _Attempt(settled, outcome, failure);
}
