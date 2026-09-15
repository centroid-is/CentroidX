/// The two seams `BackendStateMan` delegates its live half to.
///
/// `BackendStateMan` (`backend_state_man.dart`) owns the *shape* of
/// `StateManApi` and nothing else: it holds collaborators, forwards to them,
/// and refuses by name when one is absent. Everything that actually knows a
/// value — the pipe's cache, the refcounted subscribe, the write router — sits
/// behind one of the two interfaces declared here.
///
/// That split is the reason this phase can run its plans in parallel. A plan
/// that adds a capability adds a file that implements one of these seams and a
/// constructor argument at the composition root; it never edits the composer.
/// So wave 2 (the value side) and wave 3 (the write side) touch disjoint files
/// and cannot conflict, and the members plans 13-07 and 13-08 will need are
/// declared **here, now**, precisely so that neither of those plans has to go
/// back and edit 13-03's implementation file to add them.
///
/// **Neither seam has an implementation in this plan, and neither has a
/// default.** Not even a permissive one that answers "nothing known yet" for
/// every key. A permissive default is a production hole with a test's name on
/// it: it ships, something binds to it because it is the only one available,
/// and the honest-refusal rule this phase is built on becomes advice.
/// `tfc_relay_protocol`'s `SeriesResolver` (`series_address.dart:150-158`) says
/// this in so many words about its own missing default; the same rule applies
/// to both interfaces below. The only way to get a value source is to supply
/// one.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`
/// (`pipe_main_endpoint.dart`, `opcua_value_translation.dart`): there are two
/// classes named `DynamicValue` in this solve — the protocol's, which carries a
/// quality and a source time, and open62541's, which is C-coupled — and a bare
/// import here would let a reader believe the wrong one.
library;

import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// Everything `BackendStateMan` needs in order to answer a read honestly.
///
/// One implementation is expected: the one over `PipeMainEndpoint`'s
/// `ValueStore` (plan 13-03). Reads are served from that cache and are
/// synchronous by construction — never a reach across the isolate port that
/// could park the caller, which is the whole point of Phase 12.
/// A reading and where the instant on it came from, as one object.
///
/// **The pairing exists so it cannot be un-paired.** `relay.DynamicValue`
/// carries a `sourceTime` that is non-null whether the source stamped it or the
/// backend substituted its own arrival instant, and the two are
/// indistinguishable by inspection — that is the whole defect ALRM-03 closes.
/// The provenance therefore travels *with* the value from the pipe to the alarm
/// writer, rather than being looked up per key at the far end where the answer
/// could belong to a newer reading than the one in hand.
final class StampedValue {
  const StampedValue(this.value, this.stampSource);

  /// The reading, exactly as every other consumer sees it.
  final relay.DynamicValue value;

  /// Whether [relay.DynamicValue.sourceTime] on [value] is the source's own
  /// instant or one this backend put there.
  final AlarmTsSource stampSource;

  /// The instant to hand [resolveAlarmStamp], or **null** when there is no
  /// source instant to offer.
  ///
  /// This is the one place the flag is turned back into D-2's existing
  /// mechanism: a null in the bound set poisons it and the row is stamped from
  /// the backend's own clock, labelled honestly. Written here rather than at
  /// the call site so that "a substitute is not a source time" is stated once.
  DateTime? get sourceTimeIfSourced =>
      stampSource == AlarmTsSource.plant ? value.sourceTime : null;

  @override
  String toString() => 'StampedValue(${value.value}, ${stampSource.wireName})';
}

abstract interface class BackendValueSource {
  /// A handle for [key] whose value changes in place.
  ///
  /// Returns immediately for any key, known or not; the handle *is* the
  /// subscription. Mirrors `StateManApi.listen`.
  relay.ValueListenable<relay.DynamicValue> listen(String key);

  /// The same store as a stream, for stream-consuming callers.
  ///
  /// Listening is what makes a key cost a monitored item upstream, and
  /// cancelling is what releases it — the refcount lives behind this seam, not
  /// in the composer.
  Stream<relay.DynamicValue> subscribe(String key);

  /// The same stream, each emission paired with the provenance of its instant.
  ///
  /// For the alarm engine, which is the only consumer that must not confuse a
  /// substituted instant with a plant one. Everything else keeps using
  /// [subscribe]: a mimic box renders the same number either way, and widening
  /// the type every widget sees to carry a fact only one consumer acts on would
  /// be worse than the duplication.
  ///
  /// The pair must be built at EMISSION — inside the store's synchronous
  /// notification — not read back by the consumer. See [StampedValue].
  Stream<StampedValue> subscribeStamped(String key);

  /// The last known value for [key], or null when none is known yet.
  ///
  /// Null here means "not known yet" and nothing else; a known-bad value
  /// arrives as a [relay.DynamicValue] carrying a bad quality. Note that the
  /// composer does NOT pass a null through when it has no value source at all —
  /// see `BackendStateMan.read`.
  relay.DynamicValue? read(String key);

  /// Resolves with a value for [key] that is fresh as of the call.
  Future<relay.DynamicValue> readFresh(String key);

  /// One resolution for many keys, so a diagnostics page is one wait.
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys);

  /// Every key this source can serve.
  List<String> get keys;

  /// How long a value may go unrefreshed before it is no longer trustworthy.
  ///
  /// Read by the staleness sweep (13-07). It is a property of the source
  /// because the answer depends on what is behind it — an OPC UA subscription
  /// with a publishing interval and a weigher that speaks when it feels like
  /// it do not share a number.
  Duration get staleAfter;

  /// How many round trips this source has made upstream.
  ///
  /// **An observable, never a wire member.** `StateManApi` deliberately has no
  /// health method — "there is no health method" in `state_man_api.dart`'s
  /// frozen-decisions block, because `PIPE.*` keys are subscribable like any
  /// plant tag and go through the same store, qualities and widgets as a
  /// temperature. This counter exists for `StateManHarness`, which needs to
  /// assert that a cache read did NOT go upstream; putting it on the wire
  /// interface would make an internal cost a thing every connected client may
  /// interrogate.
  int get roundTrips;

  /// How many status notifications this source has emitted.
  ///
  /// The second observable `StateManHarness` requires, and an observable for
  /// exactly the same reason as [roundTrips]: it belongs to the test's view of
  /// the source, not to the surface a client may call.
  int get statusNotifications;

  /// Marks [keys] as no longer fresh, badging each value accordingly.
  ///
  /// Owner: plan 13-07 (staleness). Declared here so 13-07 adds no member to
  /// 13-03's file.
  void markStale(Iterable<String> keys);

  /// Badges [key] as having a write in flight (`Quality.goodWritePending`).
  ///
  /// Owner: plan 13-08 (write readback). The pending state is a property of the
  /// value the widget is already watching, so there is no second object to keep
  /// in sync.
  void markPending(String key);

  /// Clears the in-flight badge on [key] without asserting an outcome.
  ///
  /// Owner: plan 13-08. Called when a write's outcome is `unknown`: the badge
  /// must not persist forever, and clearing it is not the same act as applying
  /// a readback.
  void clearPending(String key);

  /// Records [value] as the confirmed post-write reading of [key].
  ///
  /// Owner: plan 13-08. Readback is the only confirmation a write ever gets.
  void applyReadback(String key, relay.DynamicValue value);

  /// Announces that the upstream link is gone, for [reason].
  ///
  /// Owner: plan 13-07. Death is an event, not a decay: every key this source
  /// serves is badged bad on the spot rather than aging out of freshness.
  void announceLinkLoss(String reason);

  /// Announces that the upstream link is serving again.
  ///
  /// Owner: plan 13-07. Recovery is a resync — a snapshot, never a delta
  /// replay.
  void announceLinkUp();

  /// Releases the subscriptions and the store behind this source.
  Future<void> dispose();
}

/// Everything `BackendStateMan` needs in order to send an operator's command.
///
/// One implementation is expected: the one over `PipeMainEndpoint.write` (plan
/// 13-04). Writes are safety-relevant, so the seam mirrors the protocol's
/// three-state discipline exactly — a [relay.WriteResult] is returned, an
/// outcome is never reported by throwing, and nothing behind this interface may
/// re-send anything on its own.
abstract interface class BackendWriteSource {
  /// Sends [value] to [key] and reports what became of it.
  ///
  /// [cmd] is the operator action's id. A relay forwards the id it was given
  /// and does not mint a second one: minting in the middle produces a write the
  /// gateway can no longer reconcile when the client re-asks about the id it
  /// holds.
  Future<relay.WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd});

  /// Re-asks what became of [cmds], positionally aligned with the argument.
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds);

  /// Engages the hold-to-run deadman on [key].
  ///
  /// Write-shaped: the engage is a real write on the same no-retry, three-state
  /// discipline, and a handle whose engage did not apply comes back inert.
  Future<relay.HoldHandle> holdToRun(String key);

  /// Releases whatever this source holds open.
  Future<void> dispose();
}
