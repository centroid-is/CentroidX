/// The one implementation of what `StateManApi.subscribe` owes a listener.
///
/// Six implementations of the interface each hand-rolled a stream over a
/// store node, and five of them got the same thing wrong the same way: a
/// broadcast controller whose `onListen` attached a node listener and pushed
/// only when the node notified. A key that ticks renders; a constant — a
/// setpoint, a range limit, a permit true all shift — has its one value in the
/// store already, notifies never again, and the widget sits on its placeholder
/// for ever. That shipped, on a plant (PR #463: every setpoint on
/// `/baader/sensors` read `---` while every measured value rendered).
///
/// The rule, decided once and stated on `StateManApi.subscribe`:
///
///  * **A value already known is the stream's first event**, for every
///    listener, delivered on a microtask after `listen` (never synchronously
///    inside it — that is re-entrancy into whatever was building the widget).
///    "Snapshot, never replay" on the wire means the snapshot IS the current
///    value, and a listener that has to wait for a change never sees a
///    constant.
///  * **A key nothing has arrived for opens with no event.** The
///    not-yet-known placeholder is readable — `listen(key).value` carries it,
///    `read(key)` answers null — and it is never pushed, for the reason the
///    subscribe contract already gives on the listenable path: an unknown key
///    invents no traffic. Every stream consumer shows its own "no value yet",
///    and an event carrying null would replace that with a rendered nothing
///    for one round trip on every key of every page.
///  * **Every later change is forwarded verbatim**, including the store
///    reverting a key to not-yet-known on a clear — that is a real change in
///    what the source knows, and the stream is a view of the source.
///  * **A stream taken from a source that has since been disposed completes
///    at once** for whoever listens to it, rather than hanging on a node that
///    will never notify.
///
/// `Stream.multi` rather than a broadcast controller, for the reason
/// `LocalStateMan` already wrote down: a broadcast controller runs `onListen`
/// for the first subscriber only, and the second widget bound to a key is the
/// ordinary case. `Stream.multi` gives each listener its own controller, so
/// each one gets the opening value and its own place in [HandedOutStreams.open].
library;

import 'dart:async';

import 'dynamic_value.dart';
import 'quality.dart';
import 'value_listenable.dart';

/// The registry of live `subscribe()` streams one source has handed out, and
/// the factory that mints them.
///
/// One per implementation, closed by that implementation's `dispose` through
/// [closeAll]. A closer is registered when a listener attaches and removed
/// when it cancels, so [open] counts streams that still need closing rather
/// than every stream ever handed out — a long-lived source that has served a
/// thousand page visits holds nothing for the pages that left.
final class HandedOutStreams {
  final _closers = <Future<void> Function()>{};
  bool _closed = false;

  /// How many handed-out streams still have a listener.
  ///
  /// The only thing about a cancelled stream that is observable from outside,
  /// which is what makes a registry that only ever grows testable as a leak.
  int get open => _closers.length;

  /// Whether [closeAll] has run. A stream listened to afterwards completes at
  /// once.
  bool get isClosed => _closed;

  /// A stream over [node] that keeps the rule in the library doc.
  ///
  /// [isKnown] decides whether the value [node] holds at the moment of
  /// delivery is a real one — by default, anything but
  /// [Quality.uncertainNotYetKnown], which is what a store node reads as
  /// before its first batch and again after a clear. A refused key
  /// ([Quality.errorConfig]) counts as known: that verdict is a fact the page
  /// should render immediately, not wait for.
  ///
  /// [onListen] and [onCancel] run once per listener, after the node listener
  /// is attached and before it is removed respectively — the hooks an
  /// implementation with an upstream refcount needs, so a stream listener
  /// costs the plant exactly what a `listen()` listener does.
  Stream<DynamicValue> over(
    ValueListenable<DynamicValue> node, {
    bool Function(DynamicValue value)? isKnown,
    void Function()? onListen,
    void Function()? onCancel,
  }) {
    final known = isKnown ?? _defaultIsKnown;
    return Stream<DynamicValue>.multi((controller) {
      if (_closed) {
        // Listened to after the source went away: done, not silence. A
        // widget that outlived its source must be told, or `isEmpty`,
        // `first` and every await on this stream hangs for ever.
        unawaited(controller.close());
        return;
      }

      // The stream's events begin at the first value the source actually
      // knows. Before that it is silent even when the node NOTIFIES — which
      // it does over a socket, where `subscribe` round-trips and the snapshot
      // answers "nothing for this key yet" as a real batch. Forwarding that
      // would put a rendered null on every widget for one round trip, which is
      // the placeholder-as-traffic this rule exists to stop; measured on the
      // ws leg of `parity_test.dart`, where the in-memory leg never notifies
      // for a key it has nothing for and so could not see it.
      //
      // Afterwards everything is forwarded verbatim, a clear back to
      // not-yet-known included: once a value HAS been seen, the source
      // forgetting it is a real change and an operator must watch it go.
      var delivered = false;
      var started = false;
      void push() {
        if (controller.isClosed) return;
        if (!started && !known(node.value)) return;
        started = true;
        delivered = true;
        controller.add(node.value);
      }

      late final Future<void> Function() close;
      var detached = false;
      void detach() {
        if (detached) return;
        detached = true;
        node.removeListener(push);
        _closers.remove(close);
        onCancel?.call();
      }

      close = () async {
        detach();
        if (!controller.isClosed) await controller.close();
      };

      node.addListener(push);
      _closers.add(close);
      onListen?.call();
      controller.onCancel = detach;

      // The opening value goes out on a microtask, not synchronously inside
      // the listen, and it is the value the node holds when the microtask
      // RUNS rather than when `listen` was called: `subscribe()` immediately
      // followed by an arriving batch is the ordinary startup order, and a
      // synchronous push there would hand the listener the placeholder and
      // call it the first value. If the batch beat the microtask, `push` has
      // already run and the opening event is not sent twice.
      scheduleMicrotask(() {
        if (delivered || controller.isClosed) return;
        push();
      });
    });
  }

  /// Closes every stream still open and marks the registry closed, so a
  /// stream listened to from now on completes at once. Idempotent; safe to
  /// await from a `dispose` that may run twice.
  Future<void> closeAll() async {
    _closed = true;
    // A snapshot: each closer deregisters itself as it runs.
    for (final close in List.of(_closers)) {
      await close();
    }
    _closers.clear();
  }

  static bool _defaultIsKnown(DynamicValue value) =>
      value.quality != Quality.uncertainNotYetKnown;
}
