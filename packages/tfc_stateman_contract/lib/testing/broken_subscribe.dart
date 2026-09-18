/// Implementations that are wrong in one specific, realistic way.
///
/// A contract suite is worth exactly what it catches, and "these checks would
/// catch a bad implementation" is a claim like any other — it has to be tested.
/// Each class here is [FakeStateMan] with a single behavior replaced, so
/// `test/sabotage_subscribe_test.dart` can assert two things about the suite:
/// that the targeted case fails against the variant, and that the *other* cases
/// still pass. The second half is what makes a sabotage evidence rather than
/// noise: a variant that failed everything would prove only that it was broken,
/// not that any particular check was doing its job.
///
/// The first two variants override [FakeStateMan.applyChanges] and nothing
/// else — the one seam every lever applies through. The last two override
/// [FakeStateMan.subscribe] and nothing else, because the properties they
/// violate are specific to the stream adapter. None is a plausible bug in
/// *this* package; all four are bugs that have shipped in real state layers —
/// [ForwardsChangesOnly] in this repository's own relay client, on a plant —
/// which is why the checks that catch them are worth their runtime forever.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'fake_state_man.dart';

/// Delivers the first value for a key and then goes silent.
///
/// Imitates an upstream subscription that dies while the link stays up: the
/// socket is connected, the gateway is answering pings, the page is showing
/// numbers — and none of those numbers has moved since the subscription
/// lapsed. This is the failure operators cannot see and cannot be expected to
/// see, which is why it is the first thing the suite is required to catch.
class DropsSubscriptions extends FakeStateMan {
  /// Forwarded so a sabotage suite can run this variant against a shortened
  /// freshness deadline, the way every variant in `broken_freshness.dart` and
  /// `broken_write.dart` can (IN-07).
  DropsSubscriptions({super.staleAfter});

  final _delivered = <String>{};

  @override
  void applyChanges(Map<String, DynamicValue> changes) {
    // `Set.add` reports whether the key was new, so the first update for each
    // key gets through and every later one is discarded in silence — no error,
    // no quality change, nothing an unsuspecting client could notice.
    final firstEver = <String, DynamicValue>{
      for (final entry in changes.entries)
        if (_delivered.add(entry.key)) entry.key: entry.value,
    };
    if (firstEver.isEmpty) return;
    super.applyChanges(firstEver);
  }
}

/// Notifies listeners even when the value did not change.
///
/// Imitates a store that stamps every arriving sample with its own receive time
/// and then compares whole values, stamp included. The equality guard is still
/// there, still executes, and never fires — so a poll cycle that re-sends 1500
/// unchanged readings rebuilds all 1500 widgets, and the page turns into a
/// slideshow on the slow link it was measured for. Correct values, ruinous
/// cost: the reason the store contract asserts a notification *count* and not
/// just the values delivered.
class NotifiesOnUnchanged extends FakeStateMan {
  /// See [DropsSubscriptions] — same reason (IN-07).
  NotifiesOnUnchanged({super.staleAfter});

  var _receivedAt = 0;

  @override
  void applyChanges(Map<String, DynamicValue> changes) {
    // A counter rather than a real clock: the sabotage has to be deterministic,
    // and DateTime.now() at millisecond resolution would occasionally produce
    // the same stamp twice and accidentally behave correctly.
    super.applyChanges({
      for (final entry in changes.entries)
        entry.key: entry.value.copyWith(
          sourceTime:
              DateTime.fromMillisecondsSinceEpoch(_receivedAt++, isUtc: true),
        ),
    });
  }
}

/// Opens every `subscribe()` stream with nothing and forwards only changes.
///
/// The defect the browser shipped with: a broadcast controller whose
/// `onListen` attaches a node listener and pushes only when the node
/// notifies. A key that ticks renders; a constant — a setpoint, a range limit,
/// a permit that has been true all shift — has its one value in the store
/// already, notifies never again, and the widget sits on its placeholder for
/// ever. `listen()` is untouched, so [checkListenDeliversValueSetBeforeListening]
/// still passes: the property is specific to the stream adapter, which is why
/// it needed a check of its own.
class ForwardsChangesOnly extends FakeStateMan {
  ForwardsChangesOnly({super.staleAfter});

  final _open = <StreamController<DynamicValue>>[];

  @override
  Stream<DynamicValue> subscribe(String key) {
    final node = listen(key);
    late final StreamController<DynamicValue> controller;
    void push() => controller.add(node.value);
    controller = StreamController<DynamicValue>.broadcast(
      onListen: () => node.addListener(push),
      onCancel: () => node.removeListener(push),
    );
    _open.add(controller);
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    for (final controller in _open) {
      if (!controller.isClosed) await controller.close();
    }
    await super.dispose();
  }
}

/// Opens every `subscribe()` stream with whatever the node holds — including
/// the not-yet-known placeholder for a key nothing has arrived for.
///
/// The over-correction of [ForwardsChangesOnly]: pushing `node.value`
/// unconditionally on listen does deliver a constant, and it also delivers a
/// null-payload placeholder for every key whose first batch is still in
/// flight, which on a slow link is every key on the page for a round trip.
/// The listenable path already forbids that traffic
/// ([checkUnknownKeyReportsConfigErrorNotThrow] counts zero notifications);
/// this variant exists so the stream check that forbids it is shown to bite.
class OpensWithPlaceholder extends FakeStateMan {
  OpensWithPlaceholder({super.staleAfter});

  @override
  Stream<DynamicValue> subscribe(String key) {
    final node = listen(key);
    return Stream<DynamicValue>.multi((controller) {
      void push() {
        if (!controller.isClosed) controller.add(node.value);
      }

      node.addListener(push);
      controller.onCancel = () => node.removeListener(push);
      scheduleMicrotask(push);
    });
  }
}
