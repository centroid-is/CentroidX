/// The hold-to-run half of the contract: what an operator is owed while their
/// finger is on a jog button, and what must happen the instant it is not.
///
/// A hold-to-run deadman is the one control on a plant where the safety
/// property is stated backwards. Everything else in this suite promises that
/// something *happens*: a value arrives, a write lands, a refusal carries a
/// reason. Here the promise is that something **stops** — the counter on the
/// tag stops advancing, the PLC notices inside its deadman window (~1 s, the
/// user's decision at the 05-CONTEXT discuss gate, ~10 missed ticks at 10 Hz),
/// and the machine coasts to a halt. `hold_handle.dart:1-24` is where that
/// inversion is argued; this file is where it is judged.
///
/// Five properties, in the order an operator meets them:
///
///  * **Engaging is a real write, with a real outcome.** The button lighting up
///    is not evidence of anything. A refused engage must leave nothing held and
///    nothing feedable — a handle for a hold the plant never took is a UI that
///    says a machine is under the operator's control when it is not.
///  * **The counter advances on the tag while the hold is fed.** Monotonic, by
///    one, and visible on the key the PLC is watching.
///  * **Releasing stops it, and says so as a write.** The counter stopping is
///    what stops the machine; the zero on the tag and its three-state outcome
///    are what let the screen agree with the plant.
///  * **Nothing but a tick advances the counter.** A source that helpfully kept
///    a deadman fed — a retry, a cached last value re-sent, a timer somebody
///    added to "smooth" the feed — is a machine running with nobody holding it.
///    This is the contract-level half of the orchestrator's A5 condition; the
///    gateway-level half is `hold_gateway_test.dart` (05-05).
///  * **A source going away releases the hold.** A disposed page that leaves a
///    counter advancing is the same machine, unattended, with the window that
///    was watching it already closed.
///
/// **The observable is the tag value**, `api.listen(key).value.asInt`, and
/// never a harness counter. That is 05-04's decision and it is load-bearing:
/// the counter on the tag is what the PLC compares against its deadman window
/// and what the operator sees on the mimic, so judging a bookkeeping variable
/// beside it would be judging the one number that cannot hurt anybody.
/// `StateManHoldHarness.applyHoldTick` (`hold_harness.dart:19-36`) is the seam
/// a counter *arrives* through and is deliberately not read here.
///
/// Shape follows `write_contract.dart`: no implementation is imported, every
/// case is a named top-level function so the sabotage suite can run it against
/// a damaged implementation, and every await is wrapped in [within] so silence
/// fails by name instead of hanging to the runner's timeout.
///
/// **No timers anywhere in this file.** Ticks are called by hand, one at a
/// time, and every wait is a future somebody awaits. A check that started a
/// tick loop would leak its last failure into the zone after its own case had
/// ended, and `suite_integrity_test.dart:158-169` would attribute it to
/// whichever case happened to be running — which is the nastiest kind of red
/// build, and the one this phase is most exposed to.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';
import 'write_contract.dart';

/// The tag a hold is taken on: a motor command tag on the pre-freezer line.
///
/// The same key the write cases drive, and deliberately not a new name. Every
/// leg that runs this suite behind a gateway declares its page up front — a
/// key outside that vocabulary is classified as a typo at subscribe time and
/// silently never delivered (`client_harness.dart:87-116`) — so a hold check
/// that invented `…MOT01.deadman` would fail on the socket legs for a harness
/// reason and pass in process. One fresh instance per case means nothing
/// collides with the write cases.
const _holdKey = 'ST101.CN01.MOT01.setpoint';

/// A sensor reading: the natural key for a device that refuses writes, and so
/// the natural key for an engage that must not take.
const _refusedKey = 'ST301.CN07.SEN01.temp';

/// How long an engage, a release or a teardown may take to answer.
///
/// Four times [within]'s default, because every one of them is a real write:
/// behind a gateway it crosses a socket, a session and a handle table, and the
/// measured floor for that round trip is already 50–100 ms (04-RESEARCH
/// Finding 8). Still far inside `suite_integrity_test.dart`'s two-second
/// per-check budget, so a source that never answers an engage fails by name
/// here rather than being reported as a hang.
const _engageBudget = Duration(milliseconds: 800);

/// How long the tag has to show a counter value the plant has been given.
///
/// The tick's whole path: a notification out, the plant, the subscription push
/// back. Longer than [within]'s default for the same transport reason, and the
/// only budget in this file a *correct* implementation is measured against on
/// every leg.
const _tagBudget = Duration(milliseconds: 500);

/// A window long enough that a tick which should not exist would have arrived.
///
/// Derived from the implementation's own declared band rather than guessed at
/// by the suite, exactly as `freshness_contract.dart:84` derives its budget:
/// how long an unfed deadman may be watched before "nothing happened" is a
/// fact is a property of the source's own timing, and a suite-level constant
/// would either be too short to catch a slow leak or too long to run.
///
/// Nothing in this file asserts the value goes *stale* over this window. It
/// may — that is the freshness contract's business, and the reading itself
/// survives going stale (`freshness_contract.dart:127-130`).
Duration _quietWindow(StateManHarness plant) => plant.staleAfter;

/// Waits until [key] reads exactly [expected], or fails saying it never did.
///
/// A listener rather than a poll, and a single future rather than a loop: the
/// counter must pass through every value on its way up, so a check that woke
/// on any notification and re-read would happily accept a source that jumped
/// from 1 to 4. It must also work on a source that already holds the value —
/// an in-process implementation applies a tick synchronously inside
/// [HoldHandle.tick], so by the time this is awaited the event it is waiting
/// for is in the past.
Future<void> _tagReaches(
  StateManApi api,
  String key,
  int expected,
  String what, {
  Duration budget = _tagBudget,
}) async {
  final node = api.listen(key);
  final reached = Completer<void>();
  void settle() {
    if (!reached.isCompleted && node.value.asInt == expected) {
      reached.complete();
    }
  }

  node.addListener(settle);
  try {
    settle();
    await within(reached.future, what, budget: budget);
  } finally {
    node.removeListener(settle);
  }
}

/// Asserts [key] still reads [expected] after a whole [window] of nothing.
///
/// The one shape a poll cannot establish: the absence of an event. [reason]
/// says what a moved counter would mean on a plant, because "expected 2, got
/// 7" reads like an off-by-one and gets the assertion relaxed.
Future<void> _tagStaysAt(
  StateManApi api,
  String key,
  int expected,
  Duration window, {
  required String reason,
}) async {
  final node = api.listen(key);
  await Future<void>.delayed(window);
  expect(node.value.asInt, expected, reason: reason);
}

/// Engaging is a three-state write, and a refused engage holds nothing.
///
/// The first half is the ordinary path: the engage lands, the handle says it
/// is held, and the tag carries the 1 the PLC reads as "the operator has the
/// button". The second half is the one that matters more. A source that hands
/// back a live-looking handle for an engage the device refused has told the
/// operator they have control of a machine they do not — and every tick after
/// that is a UI keeping a deadman fed for a hold that never existed. The
/// shipped version of this bug is a button that lights on the local click.
///
/// `onReleased` must have *already* completed with [HoldEnded.refused]: a
/// caller awaits it to know when to put the button back up, and a refused hold
/// whose future never completes leaves the button lit forever.
Future<void> checkEngageIsThreeStateAndARefusalHoldsNothing(
    StateManApi api) async {
  final plant = writeHarnessOf(api);
  plant.setValue(_holdKey, 0);
  // The seed has to be in before the engage, or the wait below wakes on the
  // seed's own notification instead of on the value the engage wrote
  // (`harness.dart:208-229`).
  await arrived(api, _holdKey);

  final hold = await within(api.holdToRun(_holdKey),
      'engaging a hold on $_holdKey answering at all',
      budget: _engageBudget);

  expect(hold.engagement, isA<WriteApplied>(),
      reason: 'the engage resolved as ${hold.engagement.runtimeType} on a key '
          'nothing objected to; taking a hold is an ordinary write and the '
          'operator is owed the same three-state answer for it as for any '
          'other — this one decides whether a machine is about to move');
  expect(hold.isHeld, isTrue,
      reason: 'the engage was applied and the handle reports the hold is not '
          'held, so nothing can feed it and the jog button does nothing');
  await _tagReaches(api, _holdKey, 1,
      'the deadman tag reading 1 after the engage was applied',
      budget: _engageBudget);

  // The refusal arm, on a second key rather than a second source: a check is
  // handed one instance and cannot make another, and a device that refuses
  // writes is a property of the key anyway.
  plant.setValue(_refusedKey, 0);
  plant.setReadOnly(_refusedKey, true);

  final refused = await within(api.holdToRun(_refusedKey),
      'engaging a hold on a key the device refuses answering at all',
      budget: _engageBudget);

  expect(refused.engagement, isA<WriteRejected>(),
      reason: 'the device refuses writes to $_refusedKey and the engage came '
          'back as ${refused.engagement.runtimeType}; a refusal is a '
          'successful call carrying bad news, and an engage that threw or '
          'reported applied would light the button on a machine that never '
          'agreed to move');
  expect((refused.engagement as WriteRejected).reason.kind, isNotEmpty,
      reason: 'the refused engage arrived with no reason kind, so the panel '
          'can say only "hold failed" — where "this device does not take '
          'writes" is the sentence that stops the operator pressing harder');
  expect(refused.isHeld, isFalse,
      reason: 'the engage was refused and the handle still reports the hold as '
          'held; the operator is looking at a lit button for a machine that '
          'was never given permission to move');
  final ended = await within(refused.onReleased,
      'a refused hold reporting, without being asked, that it already ended',
      budget: _engageBudget);
  expect(ended, HoldEnded.refused,
      reason: 'a hold that was never taken ended as $ended; the reason is what '
          'tells the UI to say "the device refused" rather than "you let go", '
          'and those are different sentences to an operator holding a button '
          'that is doing nothing');

  // A hold that was never taken must not be feedable.
  //
  // **The value asserted is the one the tag must still hold, not one it must
  // avoid** (05-REVIEW WR-04). This was `isNot(1)`, and a leaked tick does not
  // put 1 on the tag: the handle's counter starts at 1 and [HoldHandle.tick]
  // pre-increments, so the first advance writes **2** — which `isNot(1)`
  // accepts. The assertion passed in exactly the scenario its own reason
  // described. The tag was seeded 0 and the engage was rejected, so 0 is the
  // only value that means nothing is being fed, and every other value is the
  // failure.
  //
  // Over a window rather than at an instant, for the same reason the release
  // check waits: on the socket legs the read is synchronous and a tick's path
  // to the tag is not, so an immediate re-read is answered before a leaked
  // tick could have arrived.
  refused.tick();
  await _tagStaysAt(api, _refusedKey, 0, _quietWindow(plant),
      reason: 'the deadman tag moved off 0 after a tick on a hold the device '
          'refused. The engage was rejected and nothing was ever seeded, so a '
          'counter advancing there is a UI feeding a deadman for a hold that '
          'does not exist — and `applyHoldTick` goes through `applyChanges`, '
          'which does not consult the read-only refusal that stopped the '
          'engage, so a leaked tick genuinely reaches the plant');
}

/// The counter advances on the tag while the hold is fed.
///
/// Monotonic and by one, read off the key the PLC is watching. A transport
/// that drops ticks under load and reports nothing leaves the operator holding
/// a button while the machine refuses to jog, which on a plant is answered by
/// holding it harder and then by calling somebody.
///
/// Every value is waited for individually rather than waiting for the last:
/// the counter must pass *through* 2 and 3 on its way to 4, and a check that
/// only looked at the end would accept a source that jumped.
Future<void> checkTheCounterAdvancesWhileTheHoldIsFed(StateManApi api) async {
  final plant = writeHarnessOf(api);
  plant.setValue(_holdKey, 0);
  await arrived(api, _holdKey);

  final hold = await within(api.holdToRun(_holdKey),
      'engaging the hold this case then feeds',
      budget: _engageBudget);
  expect(hold.isHeld, isTrue,
      reason: 'this case needs a live hold to feed and the engage came back as '
          '${hold.engagement.runtimeType}');
  await _tagReaches(api, _holdKey, 1, 'the tag reading 1 after the engage',
      budget: _engageBudget);

  for (final expected in const [2, 3, 4]) {
    hold.tick();
    await _tagReaches(api, _holdKey, expected,
        'the deadman counter reaching $expected on the tag after a tick');
    expect(hold.counter, expected,
        reason: 'the tag reached $expected and the handle says the counter is '
            '${hold.counter}; the two disagreeing means the number the PLC '
            'compares and the number the panel believes are different, and '
            'only one of them stops the machine');
  }
}

/// Releasing stops the counter, and the release is itself a three-state write.
///
/// The operator let go. What stops the machine is the counter stopping — the
/// PLC's deadman window does the rest — so the release write's *outcome* is
/// informational and this case must not demand `applied`: on a link that has
/// just gone, `unknown` is the honest answer and a hold that refused to end
/// until the plant confirmed would be a hold that cannot end on the one path
/// where ending matters most.
///
/// What is demanded: the counter stops, `onReleased` completes with
/// [HoldEnded.operatorLetGo], the tag returns to 0, and further ticks do
/// nothing. A controller whose cancellation is asynchronous and whose timer
/// fires once more is the shipped version of the bug this catches, and it is
/// the one that keeps a machine moving after the finger came off.
Future<void> checkReleasingStopsTheCounter(StateManApi api) async {
  final plant = writeHarnessOf(api);
  plant.setValue(_holdKey, 0);
  await arrived(api, _holdKey);

  final hold = await within(api.holdToRun(_holdKey),
      'engaging the hold this case then releases',
      budget: _engageBudget);
  expect(hold.isHeld, isTrue,
      reason: 'this case needs a live hold to release and the engage came back '
          'as ${hold.engagement.runtimeType}');
  // Anti-vacuity: the hold has to have been genuinely feeding before "it
  // stopped" means anything.
  hold.tick();
  await _tagReaches(api, _holdKey, 2,
      'the counter reaching 2, so this case is releasing a hold that was '
      'actually running');

  final result = await within(
      hold.release(), 'the release write resolving rather than hanging',
      budget: _engageBudget);

  // The tripwire, in the shape `write_contract.dart:300-305` uses: every arm
  // named, so a fifth outcome does not compile until somebody has written down
  // what it means for an operator standing at a jog button.
  final outcome = switch (result) {
    WriteApplied() => 'applied — the plant confirmed the zero',
    WriteRejected() => 'rejected — the device would not take the zero',
    WriteUnknown() => 'unknown — the counter stopped anyway',
    WriteNotReceived() => 'not received — the counter stopped anyway',
  };
  expect(outcome, isNotEmpty,
      reason: 'the release must resolve with a three-state outcome carrying an '
          'id, like any other write; whatever the plant said, the counter has '
          'already stopped');
  expect(result.cmd, isNotEmpty,
      reason: 'the release came back with no cmd, so the one write an operator '
          'is most likely to ask about afterwards — "did the stop land?" — '
          'cannot be looked up');

  expect(hold.isHeld, isFalse,
      reason: 'the hold was released and still reports itself held; a panel '
          'reading that draws a live jog button over a stopped machine');
  final ended = await within(
      hold.onReleased, 'the hold reporting why it ended',
      budget: _engageBudget);
  expect(ended, HoldEnded.operatorLetGo,
      reason: 'the operator let go and the hold ended as $ended; the reason is '
          'what the UI says next, and "you let go" and "the link dropped" call '
          'for different sentences');
  await _tagReaches(api, _holdKey, 0,
      'the deadman tag returning to 0 when the operator let go',
      budget: _engageBudget);

  hold.tick();
  hold.tick();
  await _tagStaysAt(api, _holdKey, 0, _quietWindow(plant),
      reason: 'the counter advanced again after the hold was released, so the '
          'operator has taken their finger off the button and the machine is '
          'still being told somebody is holding it. This is the failure the '
          'whole deadman exists to prevent');
}

/// Nothing advances the counter but a tick.
///
/// The A5 condition, at the contract level: an engaged hold that nobody is
/// feeding must sit exactly where it was left. A source that helpfully keeps a
/// deadman fed — a timer added to smooth the cadence, a retry of the last
/// value, a resend on reconnect — is a machine running unattended, and every
/// other case in this file passes against it.
///
/// The tick to 2 in the middle is the anti-vacuity arm and it matters more here
/// than anywhere else in the suite: an assertion that nothing happened passes
/// trivially against an implementation where nothing works.
Future<void> checkOnlyATickAdvancesTheCounter(StateManApi api) async {
  final plant = writeHarnessOf(api);
  plant.setValue(_holdKey, 0);
  await arrived(api, _holdKey);

  final hold = await within(api.holdToRun(_holdKey),
      'engaging the hold this case then leaves alone',
      budget: _engageBudget);
  expect(hold.isHeld, isTrue,
      reason: 'this case needs a live hold to leave unfed and the engage came '
          'back as ${hold.engagement.runtimeType}');

  hold.tick();
  await _tagReaches(api, _holdKey, 2,
      'the counter reaching 2, which is what proves this hold works at all '
      'before the case asserts that it stopped');

  await _tagStaysAt(api, _holdKey, 2, _quietWindow(plant),
      reason: 'the counter advanced across a whole window with nobody feeding '
          'it, so something other than an operator\'s finger is keeping this '
          'deadman alive. A hold nothing has to hold is a machine running '
          'unattended, and it would pass every other case in this file');
}

/// Disposing the source releases the hold rather than leaving a machine fed.
///
/// The page closed, the panel was put to sleep, the client was torn down. A
/// source that goes away with a counter still advancing has left a machine
/// running with nothing watching it and nothing left to press stop with.
///
/// The tag is deliberately **not** asserted afterwards: a disposed source's
/// store is gone, so reading it is reading nothing, and an assertion there
/// would be judging the teardown rather than the hold.
Future<void> checkDisposingTheSourceReleasesTheHold(StateManApi api) async {
  final plant = writeHarnessOf(api);
  plant.setValue(_holdKey, 0);
  await arrived(api, _holdKey);

  final hold = await within(api.holdToRun(_holdKey),
      'engaging the hold this case then disposes underneath',
      budget: _engageBudget);
  expect(hold.isHeld, isTrue,
      reason: 'this case needs a live hold to tear down and the engage came '
          'back as ${hold.engagement.runtimeType}');
  // Anti-vacuity again: a hold that was never feeding proves nothing about a
  // teardown that stops one.
  hold.tick();
  await _tagReaches(api, _holdKey, 2,
      'the counter reaching 2 before the source is torn down under it');

  await within(api.dispose(), 'the source finishing its teardown',
      budget: _engageBudget);

  final ended = await within(hold.onReleased,
      'the hold reporting that the teardown ended it',
      budget: _engageBudget);
  expect(ended, HoldEnded.disposed,
      reason: 'the source was disposed under a live hold and the hold ended as '
          '$ended; a source that tears itself down and leaves the counter '
          'advancing has left a machine moving with the window that was '
          'watching it already closed');
  expect(hold.isHeld, isFalse,
      reason: 'the source is gone and the handle still reports the hold as '
          'held, so anything still holding this handle will keep feeding a '
          'deadman through a source that no longer exists');
}

/// The case names, declared once so a driver can reach one by name without the
/// sentence appearing twice.
const _engageCase =
    'engaging a hold is a three-state write, and a refused engage leaves '
    'nothing held';
const _advanceCase = 'the counter advances on the tag while the hold is fed';
const _releaseCase =
    'releasing stops the counter, and the release is itself a three-state '
    'write';
const _unfedCase =
    'nothing advances the counter but a tick — an unfed hold sits exactly '
    'where it was';
const _disposeCase =
    'disposing the source releases the hold rather than leaving a machine fed';

/// Every hold-to-run property, keyed by the sentence it asserts.
///
/// The key is the test name, so a failure in CI reads as the promise that was
/// broken rather than as a function identifier. Tear-offs of top-level
/// functions and never lambdas: `suite_integrity_test.dart:227-230` reads each
/// entry's declared name by reflection, and a lambda breaks the orphan sweep.
const holdChecks = <String, Check<StateManApi>>{
  _engageCase: checkEngageIsThreeStateAndARefusalHoldsNothing,
  _advanceCase: checkTheCounterAdvancesWhileTheHoldIsFed,
  _releaseCase: checkReleasingStopsTheCounter,
  _unfedCase: checkOnlyATickAdvancesTheCounter,
  _disposeCase: checkDisposingTheSourceReleasesTheHold,
};

/// Registers the hold-to-run contract against implementations from [make].
///
/// [supportsHoldToRun] `false` skips the whole group with a reason on the
/// record rather than omitting it, matching every other declined capability
/// (`write_contract.dart:664-682`): a case absent from the run report is a
/// capability nobody can see went unjudged. Nothing declares it false in Phase
/// 5 — every implementation has the member — and it exists for Phase 8, where
/// a device adapter over a read-only protocol (the M2400 weigher speaks one)
/// has no deadman to offer and must be able to say so on the record instead of
/// quietly failing five cases.
///
/// A separate flag from `supportsWrites` on purpose (05-RESEARCH §C.3): a
/// source can take writes and still have nothing to hold, and switching the
/// hold cases off with the write flag would take ten write properties down
/// with them.
///
/// One fresh instance per case, disposed by `addTearDown`, for the reason
/// every other sub-suite gives — and one more here: the disposal case tears
/// its own source down mid-hold, so a shared instance would carry a stopped
/// counter into whatever ran next.
void runHoldContract(
  StateManApi Function() make, {
  bool supportsHoldToRun = true,
}) {
  final cases = <String, Check<StateManApi>>{...holdChecks};

  group('hold', () {
    cases.forEach((property, check) {
      test(property, () async {
        final api = make();
        addTearDown(api.dispose);
        // The link, before the property. On an in-process source this is a
        // synchronous read and nothing more; behind a socket it is where the
        // connect, the handshake and the first subscribe come due, and leaving
        // them inside the case's own budget made the first check in this suite
        // a measurement of the transport (`harness.dart`'s [linkUp]).
        await linkUp(api);
        await check(api);
      });
    });
  },
      skip: supportsHoldToRun
          ? null
          : 'this implementation declares no hold-to-run support; the deadman '
              'contract is skipped rather than passed, so the capability is '
              'visible in the run report instead of absent from it');
}
