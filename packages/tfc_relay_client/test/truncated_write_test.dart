/// CR-01, end to end: a write whose result is truncated on the wire resolves
/// as `WriteUnknown` inside the deadline instead of never settling.
///
/// **This is the polarity flip.** `packages/tfc_stateman_contract/test/channel/
/// truncated_write_test.dart` pinned the failure down first, and pinned it down
/// as silence: `json_rpc_2.Peer` does not fail the pending request on a
/// malformed response. It replies `-32700` to the sender, stays open, keeps
/// answering everything else, and leaves the write's future pending forever
/// (02-RESEARCH Finding 15). On a plant that is an operator pressing start,
/// getting no outcome at all — not applied, not failed, not unknown — and
/// pressing it again on a machine that may already have moved. This file is
/// that same corruption against the client that has a per-request deadline, and
/// it asserts the opposite outcome: the write comes back, as unknown, in time
/// for the operator to be told something true.
///
/// **Why the flipped arm lives here and not where 04-CONTEXT put it.**
/// 04-CONTEXT says the contract package's first arm "becomes" the
/// resolves-unknown assertion. Doing that literally would make
/// `tfc_relay_client` a dev dependency of `tfc_stateman_contract` — the judge
/// depending on the defendant, which is the edge
/// `tfc_relay_server/test/handler_table_test.dart:253-266` protects for the
/// gateway:
///
/// > tfc_stateman_contract is the thing the gateway is judged against; a
/// > reference back to the gateway makes the judge depend on the defendant.
///
/// That sweep does not currently name the client, so the edge would have been
/// added without anything failing — which is precisely how an invariant stops
/// being one. 04-PATTERNS put the choice to the planner ("either the flipped
/// arm moves into `tfc_relay_client/test/`, or the sweep grows a client arm and
/// the edge is argued for. Moving it is the cheaper and more consistent
/// answer") and 04-11 made it: it moved. Same assertion, same polarity, same
/// corruption lever, same key, against `RemoteStateMan`. The contract package's
/// file keeps its own polarity — a client with no deadline still hangs, by
/// construction — and now says so plainly, naming this file.
///
/// **The assertion mechanism is copied unchanged** (contract file, lines
/// 26-31): await into a plain bool through `onTimeout`, then assert on the
/// bool. A completes-matcher or a throws-matcher would let the deadline escape
/// as a raw `TimeoutException` — the undiagnosable failure that idiom exists to
/// forbid — and the runner would report this file's name rather than the write
/// an operator lost. Both are grep-enforced and therefore not named in prose.
///
/// **The corruption is the same one, for the same reason.** `"outcome"` is
/// `WriteResult.toJson`'s discriminator and appears in no other message the
/// gateway sends, so it lands on the write's answer and leaves the ticks and
/// value notifications around it intact. One surgical change, so what follows
/// is attributable to it.
@TestOn('vm')
@Tags(['faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';

import 'support/fault_fixture.dart';

/// The key the write lands on. The contract file's, character for character, so
/// the two halves of the pair are comparable line by line.
const _setpointKey = 'ST101.CN01.MOT01.setpoint';

/// The deadline injected into the client under test.
///
/// This is the number the flip is about. `ClientConfig.deadlineFloor` is a
/// named parameter precisely so a test can lower it here — the flip is only
/// meaningful if the deadline can fire inside the case's own budget, and a hard
/// floor would make an untestable safety property out of the one property this
/// phase exists to deliver (`client_config.dart:24-31`).
const _writeDeadline = Duration(milliseconds: 300);

/// How long a write is given before it is called unsettled.
///
/// Comfortably above [_writeDeadline] plus a tick-quantised round trip
/// (04-RESEARCH Finding 8: 50 ms mean, quantised to the gateway's fan-out), so
/// a pass means *the deadline* ended the wait. Raise [_writeDeadline] above
/// this and the first case fails, which is how the arm was proven to bite.
const _budget = Duration(seconds: 2);

/// The window the answer must land in, over and above the deadline itself.
///
/// A window, never an instant: a scheduler on a loaded CI box is not a
/// stopwatch (STATE's Phase 2 handoff — assert windows).
const _band = Duration(milliseconds: 1200);

/// Bounds the whole file, so a regression that turns a budgeted assertion back
/// into a runner-timeout hang is itself caught.
const _fileBudget = Duration(seconds: 40);

/// Damages the write result and nothing else.
MessageCorruption _truncateTheWriteResult() =>
    onFirstMatching((message) => message.contains('"outcome"'), truncate(0.9));

void main() {
  final wall = Stopwatch()..start();

  test('a truncated write result resolves as WriteUnknown inside the deadline',
      () async {
    final fixture = await faultFixture(
      keys: const {_setpointKey},
      config: faultClientConfig(write: _writeDeadline),
      corrupt: _truncateTheWriteResult(),
      seed: (plant) => plant.setValue(_setpointKey, 1200),
    );
    await until('the link', () => fixture.client.isReady);

    final started = DateTime.now();
    final attempt = await _attemptWrite(fixture, 1500);
    final took = DateTime.now().difference(started);

    expect(
      attempt.settled,
      isTrue,
      reason: 'the write did NOT settle, which is the Phase 2 behaviour this '
          'phase exists to end: json_rpc_2 answers a truncated frame with '
          '-32700, stays open, and leaves the request pending forever '
          '(Finding 15). The per-request deadline in `deadline.dart` is what '
          'turns that silence into an answer, so a hang here means the write '
          'path stopped going through `callWithDeadline` — the operator is '
          'told nothing and re-sends a command the plant may already have '
          'taken',
    );
    expect(
      attempt.failure,
      isNull,
      reason: 'the write threw ${attempt.failure} instead of resolving. A '
          'write reports its outcome as a value and never as an exception '
          '(`remote_state_man.dart:368-372`): a call site that has to catch to '
          'find out what the machine did is a call site that will forget to',
    );
    expect(
      attempt.outcome,
      isA<WriteUnknown>(),
      reason: 'the write resolved ${attempt.outcome}. Nobody knows whether the '
          'setpoint reached the device — the answer was cut in half on the way '
          'back — and any other verdict states something this client cannot '
          'know. Reporting it applied puts a number on the mimic that may not '
          'be in the machine; reporting it rejected tells an operator the '
          'machine definitely did not move',
    );
    expect(
      (attempt.outcome! as WriteUnknown).reason.kind,
      FailureKind.deadlineExpired,
      reason: 'the unknown must name the deadline as its cause. A different '
          'kind here means something other than the deadline settled this '
          'write, and the flip would be measuring that instead',
    );
    expect(
      took,
      lessThan(_writeDeadline + _band),
      reason: 'the answer arrived ${took.inMilliseconds} ms after the write '
          'was issued, against a ${_writeDeadline.inMilliseconds} ms deadline. '
          'A deadline that fires late is a spinner the operator watches; the '
          'band above it is for the scheduler, not for the mechanism',
    );
    expect(
      fixture.client.debugUnresolvedCmds,
      contains(attempt.outcome!.cmd),
      reason: 'an unknown is the one verdict that stays open, because it is '
          'the only one `writeStatus` can still resolve. A command dropped '
          'from the unresolved set here is a command the next reconnect will '
          'never ask about',
    );
  });

  test('the session survives it: a following write resolves normally',
      () async {
    // What makes the failure quiet instead of loud, and the half that does not
    // change with the polarity. A truncated frame does not take the link down:
    // the page stays live, every other value keeps updating, and exactly one
    // command was lost — which before the deadline meant lost in silence, and
    // now means lost with an answer.
    final fixture = await faultFixture(
      keys: const {_setpointKey},
      config: faultClientConfig(write: _writeDeadline),
      corrupt: _truncateTheWriteResult(),
      seed: (plant) => plant.setValue(_setpointKey, 1200),
    );
    await until('the link', () => fixture.client.isReady);

    final swallowed = await _attemptWrite(fixture, 1500);
    expect(swallowed.outcome, isA<WriteUnknown>(),
        reason: 'the arm did not arm: the corruption did not land on the first '
            'write, so what follows is not a statement about surviving one');

    final second = await _attemptWrite(fixture, 1600);
    expect(
      second.settled,
      isTrue,
      reason: 'the second write did not settle either, so the corruption is '
          'not one-shot and this case would be proving that a dead link '
          'answers nothing — a fact about the injector, not about the peer',
    );
    expect(
      second.outcome,
      isA<WriteApplied>(),
      reason: 'the second write came back ${second.outcome}. The link was '
          'never closed by either end, so the gateway is still there and the '
          'plant still takes writes: anything but applied here means the '
          'client damaged its own session recovering from the first one',
    );
  });

  test('the control arm: without the corruption the same write resolves',
      () async {
    // Without this, a harness broken for some unrelated reason would make the
    // case above pass for the wrong reason — an unknown is exactly what a
    // client with no gateway behind it reports.
    final fixture = await faultFixture(
      keys: const {_setpointKey},
      config: faultClientConfig(write: _writeDeadline),
      seed: (plant) => plant.setValue(_setpointKey, 1200),
    );
    await until('the link', () => fixture.client.isReady);

    final attempt = await _attemptWrite(fixture, 1500);

    expect(attempt.settled, isTrue,
        reason: 'an uncorrupted write did not come back inside $_budget, so '
            'the unknown above is a property of the harness rather than of '
            'the truncation');
    expect(
      attempt.outcome,
      isA<WriteApplied>(),
      reason: 'the control write came back as ${attempt.outcome}. Every arm of '
          'WriteResult is terminal, but this one should apply — a rejected or '
          'unknown control means the gateway is not in the state the flipped '
          'case assumes, and the deadline is being credited with a failure it '
          'did not cause',
    );
  });

  test('the whole case costs less than its budget', () {
    print('the truncated-write flip ran in ${wall.elapsed.inMilliseconds} ms '
        '(budget ${_fileBudget.inSeconds} s)');
    expect(
      wall.elapsed,
      lessThan(_fileBudget),
      reason: 'a write that cannot be established must be reported by its own '
          'deadline. If this file starts costing tens of seconds, the '
          'assertion has stopped bounding its await and the runner is failing '
          'it instead — which names a file rather than the command an operator '
          'lost',
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
/// The idiom is the contract file's, unchanged: the deadline is caught here and
/// turned into data, so the caller asserts on a bool and gets a `TestFailure`
/// carrying its reason. An error is captured rather than allowed to escape,
/// both because a throw is a distinct outcome worth asserting the absence of
/// and because a peer closed at teardown completes its pending requests with
/// one — which, unhandled, would surface as an unrelated async failure long
/// after the case that caused it.
Future<_Attempt> _attemptWrite(FaultFixture fixture, Object? value) async {
  var settled = true;
  WriteResult? outcome;
  Object? failure;

  await fixture.client.write(_setpointKey, value).then<WriteResult?>(
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
