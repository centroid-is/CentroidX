/// The plant side of a hold-to-run deadman: where a counter arrives.
///
/// A hold has two halves. The engage and the release are ordinary writes and
/// live on `StateManApi`, where they get a three-state outcome and everything
/// else the write path already provides. The **feed** is the other half, and
/// it has no outcome by construction — so it needs a seam, and this is it.
///
/// The seam is a test-only harness rather than an interface member for the
/// reason `harness.dart:16-25` gives about every other observable here, and
/// one more that is specific to a deadman: a method on `StateManApi` is a
/// thing any connected client may invoke against any key, and a bare
/// `applyHoldTick(key, n)` is a write primitive with no engage in front of it
/// (T-05-11).
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The plant-side seam a hold-to-run counter arrives through.
abstract interface class StateManHoldHarness {
  /// Puts [counter] on [key], the way the plant would see it.
  ///
  /// Goes through the same seam an ordinary value arrives by — never through
  /// the write bookkeeping. Ten ticks a second through a write path would
  /// mint ten command ids a second and inflate the upstream-attempt count
  /// that "a write is never auto-retried" is measured with, so the counter
  /// WRT-03 rests on would be counting fingers rather than writes.
  ///
  /// It deliberately does **not** check that a hold was ever engaged for
  /// [key]. The authorization boundary for a tick is the gateway's
  /// per-session hold map (05-05), because only there is there a session to
  /// scope it to; in-process the caller already holds the handle, and a check
  /// here would be an imitation of a boundary rather than the boundary. That
  /// property is proven by a gateway-side test, not by a contract check.
  void applyHoldTick(String key, int counter);
}

/// The [StateManHoldHarness] side of [api], or a failure saying what is
/// missing.
///
/// Reported through `fail` rather than a cast error for the same reason
/// [writeHarnessOf] does it: an implementation that arrives without the seam
/// gets a message telling its author what to add, instead of a `_CastError`
/// naming a line in this package.
StateManHoldHarness holdHarnessOf(StateManApi api) {
  if (api is StateManHoldHarness) return api as StateManHoldHarness;
  fail('${api.runtimeType} does not implement StateManHoldHarness, so no hold '
      'case can feed a deadman for it. An implementation under test must '
      'expose the test-only applyHoldTick(key, counter) seam declared in '
      'package:tfc_stateman_contract — the counter is what the PLC watches, '
      'and a hold nothing can feed is a hold nothing can prove stops.');
}
