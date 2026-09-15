/// One upstream subscription per key, however many clients are watching it,
/// released when the last one goes.
///
/// ## Where the counter lives, and why not on the node
///
/// The mechanism is half-built already. `ValueStore.node(key)` returns the
/// *same* `ValueStoreNode` for the same key
/// (`packages/tfc_relay_protocol/lib/src/value_store.dart:186-187`) and
/// `ValueStoreNode.listenerCount` is public (`:118`), so the count of who is
/// watching a key is a fact the store could answer. But **there is no
/// `onListen`/`onCancel` hook on a node**: `addListener` is
/// `_listeners.add(listener)` and nothing more (`:66`), so nothing there can
/// fire at the transitions that matter.
///
/// 08-RESEARCH §B.2 weighs both repairs and recommends this one:
///
///  * *(a)* add the two hooks to `ValueStoreNode` — a change in
///    `tfc_relay_protocol`, which is the frozen wire package the client, the
///    server and this gateway all agree through. A subscription lifecycle is
///    not a wire shape, and putting one there makes every future consumer of
///    the store inherit a callback it did not ask for.
///  * *(b)* hold the count **here**, in a map keyed by key, incremented and
///    decremented on a handle the subscribe path returns. The wire package
///    stays untouched and the release point is explicit rather than emergent —
///    it is a line of code with a name, not a side effect of somebody's
///    `removeListener`.
///
/// (b) it is.
///
/// ## Release at zero, not on a ten-minute idle timer
///
/// The incumbent `AutoDisposingStream` releases its upstream subscription on an
/// **idle timer defaulting to ten minutes** after the last listener goes
/// (`packages/tfc_dart/lib/core/state_man.dart:2674-2676`, `:2770-2785`).
/// SRV-07 says released when the last subscriber unsubscribes, and it is right:
/// a page close should stop costing the PLC a monitored item, not keep costing
/// it for ten minutes while the operator is somewhere else.
///
/// Two of the incumbent's shapes are explicitly **not** inherited:
///
///  * **The spent-entry semantics** (`:2691`, `:2731-2751`). It closes its
///    subject when the raw stream ends and hands a new listener the replay
///    buffer followed by `done`, which to a widget is indistinguishable from a
///    key that simply stopped updating. Here the end of an upstream stream is
///    reported through [FanIn.onUpstreamEnded] as a *quality*, and the store
///    node stays alive.
///  * **The by-key eviction race**, which the incumbent's own comment names
///    (`:2736-2739`): its idle timer removes **by key**, so a timer surviving
///    into the next subscription for that key evicts the live entry that
///    replaced it. Here a new [FanIn.attach] cancels the armed timer, and the
///    timer's callback additionally refuses to act on an entry that is no
///    longer the one the map holds or that has picked up a subscriber. Two
///    guards, because the sabotage that removes one must fail.
///
/// ## Epochs
///
/// A key is resolved **once per epoch**, at the moment its refcount leaves
/// zero, and the [UpstreamRef] the link minted is held for the life of the
/// subscription. Nothing here re-resolves inside an epoch — the handle is
/// already epoch-stamped and the link refuses a superseded one itself
/// (`upstream_link.dart`, SRV-07). Re-resolution belongs *after* an
/// `epochStream` event, and **08-08 owns that wiring**: it is a subscription
/// this class does not take out, deliberately, so that the re-subscribe policy
/// is written once with the epoch tests that judge it rather than twice.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'key_router.dart';

/// Told that [route] can never be served, so the composer can record the
/// refusal as a value rather than leaving the key eternally not-yet-known.
typedef OnRefusedRoute = void Function(RefusedRoute route);

/// One key's shared upstream subscription and the count of who wants it.
final class _FanInEntry {
  _FanInEntry(this.key);

  final String key;

  /// Clients currently watching this key, through `listen` or `subscribe`.
  int listeners = 0;

  /// The one upstream subscription serving all of them. Null when the route
  /// had nothing upstream to open.
  StreamSubscription<DynamicValue>? sub;

  /// Whether [FanIn._open] has been run for this entry, so a key with nothing
  /// upstream is not re-routed on every attach.
  bool opened = false;

  /// The linger. A named field so it is reachable and cancellable, which is
  /// what `freeze_test.dart`'s timer sweep is checking for.
  Timer? _timer;
}

/// The refcount, the shared subscription, and the release.
final class FanIn {
  FanIn({
    required this.router,
    required void Function(String key, DynamicValue value) onValue,
    required void Function(String key) onUpstreamEnded,
    required void Function(String key, Object error) onUpstreamError,
    required OnRefusedRoute onRefusedRoute,
    this.linger = Duration.zero,
    void Function()? onFirstWatcher,
    void Function()? onLastWatcher,
  })  : _onRefusedRoute = onRefusedRoute,
        _onValue = onValue,
        _onUpstreamEnded = onUpstreamEnded,
        _onUpstreamError = onUpstreamError,
        _onFirstWatcher = onFirstWatcher,
        _onLastWatcher = onLastWatcher;

  /// How long a released subscription is kept alive in case somebody comes
  /// back for it.
  ///
  /// **Zero by default, and immediate release is the correct gateway
  /// behaviour.** The knob exists for one measured situation: an operator
  /// flipping between two pages that share a key would otherwise churn a PLC
  /// subscription twice a second, and on OPC UA that churn is four monitored
  /// items created and four deleted per flip. A deployment that sees it can set
  /// a second or two without a code change — and a deployment that does not
  /// pays nothing, because at [Duration.zero] no timer is created at all.
  final Duration linger;

  /// Which link owns a key. **The route is taken here and nowhere else**, which
  /// is what makes "one upstream subscription per key, however many clients"
  /// a property of one file rather than an arrangement between two.
  final KeyRouter router;

  final OnRefusedRoute _onRefusedRoute;
  final void Function(String key, DynamicValue value) _onValue;
  final void Function(String key) _onUpstreamEnded;
  final void Function(String key, Object error) _onUpstreamError;
  final void Function()? _onFirstWatcher;
  final void Function()? _onLastWatcher;

  final Map<String, _FanInEntry> _entries = <String, _FanInEntry>{};

  int _watchers = 0;
  bool _disposed = false;

  /// Clients watching [key] right now.
  int listenerCount(String key) => _entries[key]?.listeners ?? 0;

  /// Clients watching anything at all.
  ///
  /// The gate the freshness sweep's clock runs behind: with nobody watching
  /// there is nobody to tell, and an always-on periodic timer leaks past every
  /// test that builds a source without draining it.
  int get watchers => _watchers;

  /// Keys with a live upstream subscription.
  ///
  /// **This is the release assertion**, and it is deliberately a fact about
  /// this gateway's own bookkeeping rather than about the link's counters. The
  /// link exposes creates and no deletes on purpose
  /// (`upstream_link.dart`, `state_man.dart:848-861`), so "did we release" can
  /// only be answered here, and "did we avoid creating" can only be answered
  /// there. Two witnesses, and a leak has to fool both.
  int get openUpstreamSubscriptions =>
      _entries.values.where((entry) => entry.sub != null).length;

  /// Linger timers armed right now.
  int get liveLingerTimers =>
      _entries.values.where((entry) => entry._timer != null).length;

  /// One more client wants [key].
  ///
  /// Opens the upstream subscription on the transition from zero, and cancels
  /// any linger armed for this entry — the subscription that timer was about to
  /// release is the one this subscriber is about to reuse.
  void attach(String key) {
    if (_disposed) return;
    final entry = _entries.putIfAbsent(key, () => _FanInEntry(key));

    entry._timer?.cancel();
    entry._timer = null;

    final wasUnwatched = _watchers == 0;
    entry.listeners++;
    _watchers++;
    if (wasUnwatched) _onFirstWatcher?.call();

    if (entry.opened) return;
    entry.opened = true;
    final stream = _openUpstream(key);
    if (stream == null) return;
    entry.sub = stream.listen(
      (value) => _onValue(key, value),
      onError: (Object error, StackTrace stack) => _onUpstreamError(key, error),
      // The stream ending is news about the link, not the end of the key. The
      // node stays alive and the composer marks the quality; see the library
      // doc on the spent-entry semantics that are not inherited.
      onDone: () => _onUpstreamEnded(key),
      cancelOnError: false,
    );
  }

  /// The one place an upstream subscription is created.
  ///
  /// The key is routed **once**, at the moment its refcount leaves zero, and
  /// the epoch-stamped [UpstreamRef] the link minted rides inside the
  /// [ClaimedRoute] for the life of the subscription. Nothing re-resolves
  /// inside an epoch: the handle already carries one and the link refuses a
  /// superseded handle itself (SRV-07). Re-resolution belongs after an
  /// `epochStream` event and is 08-08's, for the reason in the library doc.
  ///
  /// The `switch` is exhaustive over the sealed [KeyRoute] on purpose. A sixth
  /// refusal reason or a fourth arm added later is a compile error here rather
  /// than a case falling quietly to a default, so **do not soften it**.
  Stream<DynamicValue>? _openUpstream(String key) {
    final route = router.route(key);
    switch (route) {
      case ClaimedRoute(link: final link, ref: final ref):
        return link.subscribe(ref);
      case PipeKeyRoute():
        // The gateway's own namespace. No link is ever consulted for one of
        // these — 08-09's producer owns the whole prefix, and that is what
        // makes a keymapping unable to shadow a health key.
        return null;
      case RefusedRoute():
        _onRefusedRoute(route);
        return null;
    }
  }

  /// One fewer client wants [key].
  ///
  /// At zero the subscription is released — immediately when [linger] is
  /// [Duration.zero], which is the default and the gateway-correct behaviour,
  /// and otherwise after the linger.
  void detach(String key) {
    if (_disposed) return;
    final entry = _entries[key];
    // Detaching something that was never attached is a no-op, so teardown
    // paths need no bookkeeping — `ValueStoreNode.removeListener`'s convention.
    if (entry == null || entry.listeners == 0) return;

    entry.listeners--;
    _watchers--;
    if (_watchers == 0) _onLastWatcher?.call();

    if (entry.listeners > 0) return;

    if (linger == Duration.zero) {
      // Synchronous, so "released when the last subscriber unsubscribes" is
      // literally true rather than true one event-loop turn later. A
      // zero-duration timer would still be a timer to leak.
      _releaseIfIdle(key, entry);
      return;
    }
    entry._timer = Timer(linger, () => _releaseIfIdle(key, entry));
  }

  /// Releases [entry]'s upstream subscription, unless something changed.
  ///
  /// **Two guards, and both are load-bearing.** The identity check refuses to
  /// act on an entry the map no longer holds, and the listener check refuses to
  /// act on one that picked up a subscriber. Together they are what the
  /// incumbent's own comment says its idle path lacks: it removes by key, so a
  /// timer surviving into the next subscription evicts the live entry that
  /// replaced it and the subscriber after *that* asks the PLC for four more
  /// monitored items while the displaced entry keeps streaming
  /// (`state_man.dart:2736-2739`).
  void _releaseIfIdle(String key, _FanInEntry entry) {
    entry._timer?.cancel();
    entry._timer = null;
    if (!identical(_entries[key], entry)) return;
    if (entry.listeners > 0) return;

    _entries.remove(key);
    _cancel(key, entry);
  }

  void _cancel(String key, _FanInEntry entry) {
    final sub = entry.sub;
    entry.sub = null;
    entry.opened = false;
    if (sub == null) return;
    // `unawaited()` attaches no handler (project memory), and a cancel that
    // fails must not become an unhandled error that takes down the isolate
    // serving every other key. `StateMan._monitor` at :2369 does this right and
    // this is the same discipline: a real handler, not a bare unawaited.
    unawaited(sub.cancel().then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) =>
              _onUpstreamError(key, error),
        ));
  }

  /// Drops every subscription and every armed timer.
  ///
  /// No `.timeout` anywhere: a dispose that gives up half way leaves the thing
  /// it was disposing in a state nobody owns.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values.toList()) {
      entry._timer?.cancel();
      entry._timer = null;
      final sub = entry.sub;
      entry.sub = null;
      if (sub != null) await sub.cancel();
    }
    _entries.clear();
    _watchers = 0;
  }
}
