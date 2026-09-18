/// How a contract case drives an implementation, and how it observes one.
///
/// A contract check is handed a `StateManApi` and nothing else, but every
/// interesting property of a state source is about what happens *when a value
/// arrives* — and no method on the wire surface makes a value arrive. On a real
/// source a PLC does that; under test something has to stand in for the PLC.
/// [StateManHarness] is that something: the small control surface an
/// implementation exposes **for testing only**, declared here rather than in
/// the implementation so this package keeps its defining property — it imports
/// no implementation, and the factory passed to a `run…Contract` function is
/// the only coupling to one.
///
/// The lever names are deliberately the ones CONTEXT lists for the fake and,
/// where they overlap, the ones Phase 2's fault proxy will pull. A case written
/// against this interface transfers to the fault legs unchanged.
///
/// The surface also carries the two *observables* the wire interface
/// deliberately does not expose — [StateManHarness.roundTrips] and
/// [StateManHarness.statusNotifications] — and the freshness deadline the
/// implementation declares ([StateManHarness.staleAfter]). They live here for
/// the same reason the levers do: "fifty keys cost one round trip" and "a mass
/// degradation is announced once" are promises about a *count*, and a count
/// nothing can read is not a promise at all. Putting them on `StateManApi`
/// instead would make them things a connected client may invoke, which is an
/// access-control decision and not a testing convenience.
///
/// [Notifications] is the other half: rebuild counting. Most of what this phase
/// promises operators is a *count* — k changed keys cost k rebuilds, an
/// unchanged value costs none, a disposed source costs none ever again — and a
/// count is only meaningful next to a deadline, so the wait for the next
/// notification is a future that [within] can turn into a named failure.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';

/// The test-only control surface: what stands in for the plant.
///
/// An implementation under test implements this alongside `StateManApi`. It is
/// not part of the wire surface and must never be: `api_surface_test.dart`
/// exists precisely to keep methods like these off the interface a connected
/// client can invoke.
abstract interface class StateManHarness {
  /// Delivers [value] for [key], as one upstream update.
  ///
  /// [sourceTime] defaults to null rather than to "now" on purpose: a source
  /// that stamps every arriving sample with its receive time makes two
  /// identical readings unequal, and the unchanged-value guard — the whole
  /// k-of-n rebuild property — silently stops working. That failure has its
  /// own sabotage variant.
  void setValue(String key, Object? value,
      {Quality quality = Quality.good, DateTime? sourceTime});

  /// Delivers many keys as exactly **one** batch.
  ///
  /// Separate from repeated [setValue] calls because the batch is the unit the
  /// notification-count promise is made about: 1500 keys arriving together must
  /// cost one pass and k notifications, not 1500 of each.
  void setValues(Map<String, Object?> values);

  /// Re-delivers the current value for [key] under a different [quality].
  ///
  /// Simulates the value going stale, the upstream link dropping, or a write
  /// going pending — the states an operator must be able to see without the
  /// number itself changing.
  void setQuality(String key, Quality quality);

  /// The tag is gone upstream: [key] reports [Quality.errorConfig] and never
  /// updates again.
  ///
  /// A renamed or deleted PLC tag, which is a configuration fault rather than a
  /// transient — waiting does not fix it, so the value must not keep rendering
  /// as a plausible last-known number.
  void dropKey(String key);

  /// The freshness deadline this implementation declares: how long a value may
  /// go unheard-of before it must stop claiming to be current.
  ///
  /// A case cannot assert "a value nobody has heard about recently is visibly
  /// stale" without knowing when that becomes true, and the answer is a
  /// property of the implementation, not of the suite — a gateway polling a
  /// slow serial line and an in-memory fake do not owe the operator the same
  /// number. Every freshness case reads its budget from here, so one
  /// implementation can be judged at 100 ms and another at 5 s by the same
  /// unmodified check.
  ///
  /// Deliberately a declared deadline rather than an injectable clock. CONTEXT
  /// restricts injected clocks to pure state-machine unit tests, and the
  /// freshness watchdog is exactly the machinery an injected clock would stop
  /// testing: a source that never runs its sweep passes every fake-clock case
  /// and shows a frozen-fresh page in the plant.
  Duration get staleAfter;

  /// The upstream device link is down.
  ///
  /// Every key this source serves from that link must degrade to
  /// [Quality.badCommFault] and the loss must be announced **once** — see
  /// [statusNotifications]. Corresponds to Phase 2's `flap(down)` proxy mode,
  /// so a case written against this lever transfers to the fault legs
  /// unchanged.
  void disconnectUpstream();

  /// The upstream link is back, and a snapshot with it.
  ///
  /// Recovery is always a snapshot and never a delta replay, so keys that have
  /// values come back at their real quality rather than staying degraded until
  /// they next happen to change. Corresponds to `flap(up)`.
  void reconnectUpstream();

  /// How many round trips this source has made upstream since it was created.
  ///
  /// The observable behind the cheapness half of the read contract: `read` is
  /// documented as never a round trip and `readMany` as one round trip for
  /// many keys, and neither promise is enforceable without a counter. It is on
  /// the *test-only* surface precisely because it is not something a connected
  /// client may ask for.
  int get roundTrips;

  /// How many times this source has announced a change in the link's state.
  ///
  /// One per mass-degradation, never one per key. At 1500 keys on one page a
  /// per-key fan-out is 1500 events for one event, delivered in the instant
  /// the client is trying to redraw — a denial of service against the
  /// operator's own screen. Sparkplug sends one NDEATH for a whole node for
  /// this reason.
  int get statusNotifications;
}

/// The [StateManHarness] side of [api], or a failure saying what is missing.
///
/// Reported through `fail` rather than a cast error so an implementation that
/// arrives without a control surface gets a message telling its author what to
/// add, instead of a `_CastError` naming a line in this package.
StateManHarness harnessOf(StateManApi api) {
  // An explicit cast, not a promotion: `StateManHarness` is not a subtype of
  // `StateManApi`, and Dart promotes only towards subtypes. The `is` test above
  // it is what makes the cast safe, and what turns the failure into the message
  // below instead of a `_CastError`.
  if (api is StateManHarness) return api as StateManHarness;
  fail('${api.runtimeType} does not implement StateManHarness, so no contract '
      'case can make a value arrive for it. An implementation under test must '
      'expose the test-only control surface (setValue/setValues/setQuality/'
      'dropKey) declared in package:tfc_stateman_contract.');
}

/// Counts notifications from one node, and lets a case wait for the next one.
///
/// Created by [observe]. Counting is the point: `expect(seen.count, 0)` is how
/// "re-delivering an identical value rebuilds nothing" is stated, and it is a
/// statement about the absence of an event, which can only be made after a
/// barrier that would have carried the event if there were one.
final class Notifications {
  final ValueListenable<DynamicValue> _node;
  late final VoidCallback _listener;

  int _count = 0;
  int _unconsumed = 0;
  Completer<void>? _waiting;

  Notifications._(this._node) {
    _listener = _onNotify;
    _node.addListener(_listener);
  }

  /// How many notifications this node has fired since [observe] was called.
  int get count => _count;

  /// Completes on the next notification — or immediately if one has already
  /// arrived and not yet been awaited.
  ///
  /// The already-arrived case is not an optimisation: an in-process
  /// implementation notifies **synchronously** inside `setValue`, so by the
  /// time a case awaits, the event it is waiting for is in the past. Without
  /// this, every check would hang against a correct local implementation and
  /// pass only against a slow remote one.
  Future<void> get next {
    if (_unconsumed > 0) {
      _unconsumed--;
      return Future<void>.value();
    }
    return (_waiting ??= Completer<void>()).future;
  }

  /// Stops counting. Removing a listener that was never added is a no-op, so
  /// this is safe after the source has been disposed.
  void stop() => _node.removeListener(_listener);

  void _onNotify() {
    _count++;
    final waiting = _waiting;
    if (waiting == null) {
      _unconsumed++;
    } else {
      _waiting = null;
      waiting.complete();
    }
  }
}

/// Starts counting notifications from [node].
Notifications observe(ValueListenable<DynamicValue> node) =>
    Notifications._(node);

/// How long the *link* gets to come up, before any property's budget opens.
///
/// Not a tolerance on anything this suite judges. No case asserts how fast a
/// source connects, and [linkUp] is not the place to start: this number exists
/// only so an implementation whose link never comes up fails by name instead of
/// hanging until the runner's timeout — the same job [within] does everywhere
/// else, one level further out.
///
/// So it is deliberately generous, and generous is the *point*. The failure
/// being fixed here was a tight bound applied to a transport coming up, and a
/// tight bound here would be the identical mistake one line higher. Two seconds
/// is the control deadline every socket leg configures for a wire call
/// (`client_harness.dart`'s `contractClientConfig`): a link that is still not up
/// after it has elapsed is one the implementation's own calls have already
/// given up on, so nothing is being excused by waiting that long, and it is 20×
/// the 105 ms this barrier measured on an idle machine.
const Duration _linkUpBudget = Duration(seconds: 2);

/// Waits until the source's link is up, before a case's own budget opens.
///
/// **What this fixes is a measurement, not a tolerance.** Every case gets one
/// fresh implementation from `make()` — synchronously, because the factory
/// signature has no async hook (04-RESEARCH Finding 6) — and then starts
/// asserting. On an in-process source that is exact: the store is there, the
/// levers land synchronously, and the first `within` bounds the property it
/// names. Behind a socket the same line bounds something else entirely. The
/// first await in the case is where the TCP connect, the WebSocket handshake,
/// the subscribe of a three-hundred-key page and the gateway's first tick all
/// come due, and the property the case is named for is whatever is left of the
/// budget afterwards.
///
/// Measured on the `RemoteStateMan` leg on an idle Apple Silicon machine:
/// `PIPE.connected` goes true at **105 ms** and the first plant value lands
/// **0.3 ms** later. Of a 200 ms budget, 99.6 % was being spent on the
/// transport coming up and 0.4 % on the property. Raising the budget would have
/// bought green while leaving that ratio exactly as wrong; this moves the start
/// of the window instead, and the property keeps the 200 ms it always had.
///
/// **Late and never are different failures, and this is what tells them apart.**
/// A single timeout around both cannot: a slow runner and a source that has
/// stopped delivering produce the same red. Split in two, a link that never
/// comes up fails here saying so, and a value that never arrives over a link
/// that *is* up fails in the case naming the property an operator lost.
///
/// The condition is [PipeKeys.connected], which is contract vocabulary rather
/// than a new lever: HLTH-01 makes the health keys ordinary subscribable
/// values, `checkHealthKeysAreSubscribableLikeAnyTag` holds every leg to
/// serving them, and the reference implementation seeds them true at
/// construction. So this is free on a source that is already up — a synchronous
/// [StateManApi.read] and nothing attached — exactly as [arrived] is, and a real
/// wait only where a link is a real thing.
Future<void> linkUp(
  StateManApi api, {
  Duration budget = _linkUpBudget,
}) async {
  if (api.read(PipeKeys.connected)?.asBool == true) return;

  final node = api.listen(PipeKeys.connected);
  final up = Completer<void>();
  void settle() {
    if (!up.isCompleted && node.value.asBool == true) up.complete();
  }

  node.addListener(settle);
  try {
    // Re-checked after the listener goes on: the link may come up between the
    // read above and the attach, and a barrier that missed that edge would wait
    // for a notification that has already happened.
    settle();
    await within(up.future, 'the link coming up', budget: budget);
  } finally {
    node.removeListener(settle);
  }
}

/// Waits until a value has genuinely arrived for [key], if one has not already.
///
/// The barrier a case needs *before* it starts counting. Every case that seeds
/// a value and then asserts something about the notifications that follow has
/// to know when the seed landed, and there are only two possible answers: it
/// landed synchronously inside the lever, or it is still in flight.
/// [Notifications.count] cannot tell them apart, and a case that guesses gets
/// the seed's own notification folded into the count it is making a promise
/// about.
///
/// That is not hypothetical. Phase 2's channel harness — the same
/// `Check<StateManApi>` functions, run against a source whose values cross a
/// message boundary — reported 103 notifications for a 100-key batch carrying
/// three real changes, and blamed the implementation for the case's impatience.
/// The implementation was correct. Three cases were not, and the same three
/// would have failed against `RemoteStateMan` in Phase 4, where the boundary is
/// a socket and there is no version of the case that could be written without
/// this.
///
/// Free on a source that delivers in-process: the fast path is a synchronous
/// [StateManApi.read], and nothing is attached or awaited. Re-checked after the
/// listener goes on, because the value may land between the two.
///
/// **The fast path asks whether a reading has been heard, not whether there is
/// an entry**, and the difference is the whole barrier. A gateway accepts a key
/// the source *declares* and snapshots it [Quality.uncertainNotYetKnown] —
/// "not known yet is a value state, not a rejection", which the gateway's own
/// `subscribe_test.dart` holds it to — so on a socket leg every key on the page
/// has a non-null entry from the moment the subscribe lands, before any plant
/// value has been delivered for it. A `read(key) != null` test would then
/// return instantly from the fast path, the barrier would guard nothing, and
/// the *next* notification the case saw would be the seed's own — exactly the
/// failure this helper's own doc describes, arriving through the helper meant
/// to prevent it.
///
/// It is the same shape as the previous round's capability probe: a question
/// that is cheap to ask and is not the one the callers need. Callers need "the
/// plant has been heard from about this key"; a placeholder is the source
/// saying the opposite in as many words.
Future<void> arrived(
  StateManApi api,
  String key, {
  Duration budget = const Duration(milliseconds: 200),
}) async {
  if (_heard(api, key)) return;
  final seen = observe(api.listen(key));
  try {
    if (_heard(api, key)) return;
    await within(seen.next, 'the seeded value for $key arriving',
        budget: budget);
  } finally {
    seen.stop();
  }
}

/// Whether anything has actually been heard about [key] yet.
///
/// A subscribed-but-never-delivered key reads as a real [DynamicValue] carrying
/// [Quality.uncertainNotYetKnown] on any source that snapshots its page; that is
/// the source saying "nothing yet", and it must not satisfy a barrier waiting
/// for something.
bool _heard(StateManApi api, String key) {
  final value = api.read(key);
  return value != null && value.quality != Quality.uncertainNotYetKnown;
}
