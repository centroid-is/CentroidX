/// A `BackendValueSource` with a plant-shaped hole where the plant would be.
///
/// **One fake, two suites.** Written for `alarm_rule_watcher_test.dart` in
/// 14-04 as a library-private `_FakeValues`, and lifted here the moment
/// 14-05's engine needed the same seam. That SUMMARY's own note is the reason:
/// *"two fakes of one seam are two things that can disagree about it"* — and
/// the disagreement would not be a failing test, it would be two suites each
/// proving a different `BackendValueSource` behaves correctly.
///
/// Records `subscribe` per key and how many of those subscriptions are still
/// live, because "the engine holds its subscription after the last panel left"
/// (D-7) is a claim about the refcount and nothing else can observe it here.
///
/// Everything off the path under test **refuses** rather than pretending. A
/// permissive stub is how a test starts passing for the wrong reason.
library;

import 'dart:async';

import 'package:test/test.dart' show pumpEventQueue;
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// A fixed instant to hang arms off, so nothing reads a real clock.
final DateTime t0 = DateTime.utc(2026, 9, 6, 12, 0, 0);

/// A good value, optionally carrying a plant instant.
relay.DynamicValue good(Object? value, {DateTime? at}) =>
    relay.DynamicValue(value: value, sourceTime: at);

/// A value that arrived with nothing in it but a bad badge — the shape the rig
/// measured for a first-ever subscriber (13-RIG-PROBE-EVIDENCE FIND-2).
relay.DynamicValue bad(relay.Quality quality, {DateTime? at}) =>
    relay.DynamicValue(value: null, quality: quality, sourceTime: at);

/// Lets the microtask queue drain so a `CombineLatestStream` emission lands.
Future<void> settle() => pumpEventQueue(times: 5);

/// A clock that never advances by itself and counts every read.
///
/// `DateTime.now()` does not appear in this file, nor in any suite that uses
/// it. The composition root supplies the real one in 14-08 and nowhere else
/// (D-2).
final class CountingClock {
  CountingClock(this.at);

  DateTime at;
  int reads = 0;

  DateTime call() {
    reads++;
    return at;
  }
}

/// See the library doc.
final class FakeBackendValueSource implements BackendValueSource {
  final Map<String, List<StreamController<relay.DynamicValue>>> _controllers =
      {};
  final Map<String, List<StreamController<StampedValue>>> _stampedControllers =
      {};
  final Map<String, relay.DynamicValue> _last = {};

  /// Where the instant on each key's latest value came from.
  ///
  /// Defaults to [AlarmTsSource.plant] for a value pushed through [push], so
  /// every arm written before the provenance existed keeps meaning what it
  /// meant: `good(x, at: t0)` is a plant-stamped reading. [pushStamped] is how
  /// an arm says otherwise.
  final Map<String, AlarmTsSource> _provenance = {};

  /// Keys this source claims to serve that have never carried a value.
  ///
  /// [keys] is what `AlarmEngine.start` reads to defend the reserved `ALARM.`
  /// namespace (T-14-08), and an operator-authored key mapping is *declared*
  /// long before it ever produces a reading — so a fake that could only
  /// declare a key by pushing a value to it could not express the case at all.
  final List<String> declaredKeys = [];

  /// How many times `subscribe` was called for each key.
  final Map<String, int> subscribeCalls = {};

  /// How many of those subscriptions are still listening.
  final Map<String, int> liveListeners = {};

  @override
  Stream<relay.DynamicValue> subscribe(String key) {
    subscribeCalls[key] = (subscribeCalls[key] ?? 0) + 1;
    late final StreamController<relay.DynamicValue> controller;
    controller = StreamController<relay.DynamicValue>(
      onListen: () {
        liveListeners[key] = (liveListeners[key] ?? 0) + 1;
        final seed = _last[key];
        if (seed != null) controller.add(seed);
      },
      onCancel: () {
        liveListeners[key] = (liveListeners[key] ?? 1) - 1;
        _controllers[key]?.remove(controller);
      },
    );
    (_controllers[key] ??= []).add(controller);
    return controller.stream;
  }

  @override
  Stream<StampedValue> subscribeStamped(String key) {
    subscribeCalls[key] = (subscribeCalls[key] ?? 0) + 1;
    late final StreamController<StampedValue> controller;
    controller = StreamController<StampedValue>(
      onListen: () {
        liveListeners[key] = (liveListeners[key] ?? 0) + 1;
        final seed = _last[key];
        if (seed != null) {
          controller.add(StampedValue(seed, _provenanceOf(key)));
        }
      },
      onCancel: () {
        liveListeners[key] = (liveListeners[key] ?? 1) - 1;
        _stampedControllers[key]?.remove(controller);
      },
    );
    (_stampedControllers[key] ??= []).add(controller);
    return controller.stream;
  }

  AlarmTsSource _provenanceOf(String key) =>
      _provenance[key] ?? AlarmTsSource.plant;

  /// Delivers [value] on [key] to every live subscription, as a plant-stamped
  /// reading.
  void push(String key, relay.DynamicValue value) =>
      pushStamped(key, value, AlarmTsSource.plant);

  /// The same, saying where the instant on [value] came from.
  ///
  /// The pair is built here, at the push, for the same reason
  /// `BackendLiveValues` builds it inside the store's notification: a fake that
  /// let the two be joined later could not fail the way the real thing would.
  void pushStamped(
      String key, relay.DynamicValue value, AlarmTsSource stampSource) {
    _last[key] = value;
    _provenance[key] = stampSource;
    for (final controller in [...?_controllers[key]]) {
      if (!controller.isClosed) controller.add(value);
    }
    for (final controller in [...?_stampedControllers[key]]) {
      if (!controller.isClosed) controller.add(StampedValue(value, stampSource));
    }
  }

  @override
  relay.DynamicValue? read(String key) => _last[key];

  @override
  List<String> get keys => <String>{..._last.keys, ...declaredKeys}.toList();

  @override
  Duration get staleAfter => const Duration(seconds: 10);

  @override
  Future<void> dispose() async {
    for (final list in _controllers.values) {
      for (final controller in [...list]) {
        await controller.close();
      }
    }
    _controllers.clear();
    for (final list in _stampedControllers.values) {
      for (final controller in [...list]) {
        await controller.close();
      }
    }
    _stampedControllers.clear();
  }

  Never _unused(String member) => throw UnimplementedError(
      'FakeBackendValueSource.$member is not on the path under test');

  @override
  void applyReadback(String key, relay.DynamicValue value) =>
      _unused('applyReadback');

  @override
  void announceLinkLoss(String reason) => _unused('announceLinkLoss');

  @override
  void announceLinkUp() => _unused('announceLinkUp');

  @override
  void clearPending(String key) => _unused('clearPending');

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      _unused('listen');

  @override
  void markPending(String key) => _unused('markPending');

  @override
  void markStale(Iterable<String> keys) => _unused('markStale');

  @override
  Future<relay.DynamicValue> readFresh(String key) => _unused('readFresh');

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) =>
      _unused('readMany');

  @override
  int get roundTrips => _unused('roundTrips');

  @override
  int get statusNotifications => _unused('statusNotifications');
}
