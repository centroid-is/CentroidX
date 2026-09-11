/// The five ways a hold-to-run implementation lets a machine run without
/// somebody holding it.
///
/// `broken_write.dart` covers implementations that lie about a write that has
/// already happened. These are the same family and, on a jog button, the worse
/// half of it: a write that lies is wrong about one movement of the plant, and
/// a deadman that lies is wrong about *whether the movement is still under
/// anybody's control*. The safety property here is stated backwards from every
/// other one in the suite — what must happen is that a counter **stops** — so
/// every bug in this file looks, from the API surface, exactly like a system
/// working.
///
/// All five have shipped, in this shape, in real control software:
///
///  * a UI that lights the hold button on the local click, because the press
///    is the event the widget already had;
///  * a transport that drops notifications under load and reports nothing,
///    because a lost tick is "just" a lost tick;
///  * a controller whose cancellation is asynchronous and whose timer fires
///    once more, because `cancel()` returned and the author stopped reading;
///  * a source that feeds the counter itself to "smooth" a jittery cadence,
///    which is the single most reasonable-sounding line of code in this file;
///  * a teardown with nothing to release, because the registry was never
///    written to.
///
/// Each class replaces exactly one behaviour of [FakeStateMan] and inherits the
/// rest, so `test/sabotage_hold_test.dart` can assert both halves of a
/// sabotage — the targeted check fails, and a named neighbour still passes. A
/// variant that failed everything would prove nothing about any individual
/// check.
///
/// Two of the five are broad by construction and say so at their own class: a
/// source with no feed at all takes down every case that ticks once as its
/// anti-vacuity arm. Their surgical arm is the engage check, which is the one
/// case that never ticks.
///
/// These are **not** exported from `tfc_stateman_contract.dart`. The fakes live
/// under their own import path so nothing can acquire a deliberately broken
/// implementation by depending on the contract
/// (`tfc_stateman_contract.dart:59-63`).
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'fake_state_man.dart';

/// Reports the engage as applied without the write ever reaching the plant.
///
/// The shipped version is a UI that lights the button on the local click: the
/// press is the event the widget already has, the handle is built from it, and
/// the operator is looking at a live hold on a machine that was never asked.
/// Everything downstream then works perfectly — the ticks go out, the counter
/// advances, the release writes its zero — which is why nothing but the tag
/// itself catches this.
///
/// It also never registers the hold, because a hold the source never took is
/// not a hold it can release; that makes the disposal case fail too, and the
/// surgical arm names the case that still passes.
class EngagesWithoutActuating extends FakeStateMan {
  EngagesWithoutActuating({super.staleAfter});

  @override
  Future<HoldHandle> holdToRun(String key) async => HoldHandle(
        key: key,
        // Minted locally and applied to nothing. The id even looks right,
        // which is what makes the result survive an eyeball.
        engagement: WriteApplied(newUlid(),
            readback: 1, at: DateTime.now().millisecondsSinceEpoch),
        onTick: (counter) => applyHoldTick(key, counter),
        onRelease: (counter) async => WriteApplied(newUlid(),
            readback: counter, at: DateTime.now().millisecondsSinceEpoch),
      );
}

/// Honours no tick at all.
///
/// A transport that drops notifications under load, and says nothing, because
/// a tick is fire-and-forget by design and there is no outcome to lose. On a
/// plant this is the nastiest of the five: the machine simply refuses to jog,
/// the operator holds the button harder, and every screen involved reports a
/// healthy hold.
///
/// Broad by construction. Every hold case but the engage one ticks at least
/// once — as the property under test or as its anti-vacuity arm — so all of
/// them go red here. That is the honest consequence of removing the feed, and
/// the surgical case pins it by naming the one check that still passes.
class NeverAdvancesTheCounter extends FakeStateMan {
  NeverAdvancesTheCounter({super.staleAfter});

  @override
  void applyHoldTick(String key, int counter) {
    // Swallowed, exactly the way a dropped notification is swallowed: no
    // error, no counter, no complaint.
  }
}

/// Lets one more counter value reach the plant after the release.
///
/// A controller whose cancellation is asynchronous: `release()` returns, the
/// zero lands on the tag, and the timer that was already scheduled fires once
/// behind it. The counter is now non-zero again, the PLC's deadman window
/// restarts, and the machine keeps moving after the finger came off — which is
/// the one failure the whole deadman exists to prevent.
///
/// The straggler is a real short timer rather than a microtask on purpose: a
/// microtask would land before the release even returned, which is a different
/// (and much more visible) bug. This one arrives in the gap where nobody is
/// looking, and it is cancelled in [dispose] so it cannot outlive its case.
class KeepsFeedingAfterRelease extends FakeStateMan {
  KeepsFeedingAfterRelease({super.staleAfter});

  /// The last counter this source put on a tag, so the straggler carries the
  /// value the cancelled timer would have sent next.
  int _lastCounter = 1;

  Timer? _straggler;

  @override
  void applyHoldTick(String key, int counter) {
    _lastCounter = counter;
    super.applyHoldTick(key, counter);
  }

  @override
  Future<HoldHandle> holdToRun(String key) async {
    final engagement = await write(key, 1);
    final hold = HoldHandle(
      key: key,
      engagement: engagement,
      onTick: (counter) => applyHoldTick(key, counter),
      onRelease: (counter) {
        // Scheduled before the zero is even written, which is what an
        // already-queued timer amounts to.
        _straggler = Timer(const Duration(milliseconds: 5),
            () => applyHoldTick(key, _lastCounter + 1));
        return write(key, counter);
      },
    );
    if (hold.isHeld) {
      _liveHolds.add(hold);
      unawaited(hold.onReleased.then((_) => _liveHolds.remove(hold)));
    }
    return hold;
  }

  /// This variant's own registry, because building the handle here puts these
  /// holds outside the superclass's. Kept honest on purpose: a teardown that
  /// also forgot to release would break a second check, and then neither
  /// failure would pin anything.
  final _liveHolds = <HoldHandle>{};

  /// Releases like the honest source does, and only then cancels the timer the
  /// release just scheduled. A pending timer left behind here is the zone leak
  /// `suite_integrity_test.dart:158-169` hunts, and a sabotage that leaked one
  /// would fail an unrelated case rather than its own.
  @override
  Future<void> dispose() async {
    for (final hold in List<HoldHandle>.of(_liveHolds)) {
      unawaited(hold
          .release(reason: HoldEnded.disposed)
          .then((_) {}, onError: (Object _) {}));
    }
    _liveHolds.clear();
    await super.dispose();
    _straggler?.cancel();
  }
}

/// Advances the counter on a timer of its own, with no tick arriving.
///
/// The sabotage assumption A5 exists for, and the most reasonable-sounding
/// line of code in this file: a pump in the source that keeps the cadence
/// smooth over a jittery link. It passes every case that asserts something
/// happens. What it produces on a plant is a machine that keeps running with
/// nobody holding the button, because the thing the PLC is watching for —
/// silence — is exactly what this source refuses to produce.
///
/// The pump stops when the hold is released, which is what keeps the sabotage
/// surgical: this variant is wrong about *unattended* holds only.
class FeedsTheCounterOnATimer extends FakeStateMan {
  FeedsTheCounterOnATimer({super.staleAfter});

  /// 20 ms: fast enough that a whole quiet window is unmistakable, slow enough
  /// that the hand-called tick every case makes right after its engage still
  /// lands first.
  static const _cadence = Duration(milliseconds: 20);

  Timer? _pump;
  int _counter = 1;

  @override
  void applyHoldTick(String key, int counter) {
    _counter = counter;
    super.applyHoldTick(key, counter);
  }

  @override
  Future<HoldHandle> holdToRun(String key) async {
    final hold = await super.holdToRun(key);
    if (hold.isHeld) {
      _counter = hold.counter;
      _pump = Timer.periodic(_cadence, (_) => applyHoldTick(key, ++_counter));
      // Stopping on release is what keeps this surgical: the variant is wrong
      // about *unattended* holds and about nothing else.
      unawaited(hold.onReleased.then((_) => _pump?.cancel()));
    }
    return hold;
  }

  @override
  Future<void> dispose() async {
    _pump?.cancel();
    await super.dispose();
    // Again after the superclass, because its teardown releases the hold and
    // this variant's own release path runs through the callback above.
    _pump?.cancel();
  }
}

/// Feeds a hold the device refused.
///
/// Everything visible about the engage is honest: the write was rejected, the
/// handle is inert, `isHeld` is false, and `onReleased` has already completed
/// with [HoldEnded.refused]. A UI reading this handle would draw the button
/// correctly. What is wrong is one `if` away from the smoothing pump above —
/// the feed starts when the button goes down, without looking at whether the
/// device agreed — and on a plant that is a deadman counter advancing for a
/// hold that does not exist, on a key whose whole reason for refusing writes
/// is that it is not a thing anybody should be commanding.
///
/// It reaches the tag because `applyHoldTick` goes through `applyChanges`,
/// which is how a value *arrives* from a device and therefore does not consult
/// the read-only refusal that stopped the engage.
///
/// **The value it lands on is 2, and that is the point of the variant**
/// (05-REVIEW WR-04). The engage write never reached the tag, so the tag still
/// reads 0, and the first advance of a counter that starts at 1 writes 2. An
/// assertion spelled "the tag must not read 1" is satisfied by 2, and this
/// source walks straight through it.
///
/// Surgical: it acts only when the engage was *not* applied, so every case
/// that engages the writable key sees an ordinary source.
class FeedsAHoldTheDeviceRefused extends FakeStateMan {
  FeedsAHoldTheDeviceRefused({super.staleAfter});

  @override
  Future<HoldHandle> holdToRun(String key) async {
    final hold = await super.holdToRun(key);
    // `hold.counter + 1` rather than a literal: it is the value
    // [HoldHandle.tick] would mint, written by a source that started feeding
    // before it read the outcome.
    if (!hold.isHeld) applyHoldTick(key, hold.counter + 1);
    return hold;
  }
}

/// Hands out a hold it does not track, so its teardown has nothing to release.
///
/// The registry was never written to. Releasing by hand works perfectly and
/// every other case passes, which is what makes this one survive review: the
/// only moment it is visible is the moment the page closes with the button
/// still down, and by then nothing is watching the counter it left advancing.
class LeavesHoldsRunningOnDispose extends FakeStateMan {
  LeavesHoldsRunningOnDispose({super.staleAfter});

  /// The honest source's [holdToRun] with the two registry lines missing, and
  /// nothing else changed. That is what the bug looks like in a diff, which is
  /// why it survives review.
  @override
  Future<HoldHandle> holdToRun(String key) async {
    final engagement = await write(key, 1);
    return HoldHandle(
      key: key,
      engagement: engagement,
      onTick: (counter) => applyHoldTick(key, counter),
      onRelease: (counter) => write(key, counter),
    );
  }
}
