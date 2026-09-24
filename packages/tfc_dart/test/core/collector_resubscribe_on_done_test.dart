// A collected stream that completes must be subscribed again, not mourned.
//
// The collector subscribes to every collected key once, at startup, and holds
// that stream for the life of the backend. When an OPC UA server drops its
// SecureChannel and the subscriptions on it are lost, StateMan's raw stream
// for some keys reports done; AutoDisposingStream then closes the subject and
// retires the entry, and the collector's listener sees done. Its onDone used
// to cancel the sample timer and log "no more data will be collected" -- and
// that was exactly what happened, until somebody restarted the backend. On a
// production station eight collected series had been silent for a day this
// way while the panels, which re-subscribe on every navigation, showed the
// same keys perfectly alive.
//
// Everything here runs under FakeAsync: the retry ladder is 1s, 10s, 60s and
// then 600s per rung, and a test must be able to walk all of it.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A StateMan that hands out one fresh stream per subscribe() call and keeps
/// the controllers, so a test can complete any of them and see which one the
/// collector is listening to.
class _FakeStateMan implements StateMan {
  final List<StreamController<DynamicValue>> subscriptions = [];

  /// When set, subscribe() parks on this until the test completes it -- the
  /// shape of a server that is still away when the retry fires.
  Completer<void>? gate;

  /// When set, subscribe() rejects with it instead of returning a stream.
  Object? failWith;

  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});

  @override
  String resolveKey(String key) => key;

  @override
  bool isKeyDisabled(String key) => false;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final held = gate;
    if (held != null) await held.future;
    final fail = failWith;
    if (fail != null) throw fail;
    final controller = StreamController<DynamicValue>.broadcast();
    subscriptions.add(controller);
    return controller.stream;
  }

  @override
  Future<void> close() async {
    for (final c in subscriptions) {
      await c.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('StateMan.${invocation.memberName}');
}

class _RecordingDatabase implements Database {
  final List<dynamic> rows = [];

  @override
  Future<void> registerRetentionPolicy(String t, RetentionPolicy r) async {}

  @override
  Future<void> insertTimeseriesData(String t, DateTime time, dynamic v) async {
    rows.add(v);
  }

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Database.${invocation.memberName}');
}

typedef _Rig = ({
  Collector collector,
  _FakeStateMan stateMan,
  _RecordingDatabase database,
});

_Rig _rig() {
  final stateMan = _FakeStateMan();
  final database = _RecordingDatabase();
  final collector = Collector(
    config: CollectorConfig(collect: true),
    stateMan: stateMan,
    database: database,
  );
  return (collector: collector, stateMan: stateMan, database: database);
}

final _entry =
    CollectEntry(key: 'scale1/net_weight', name: 'scale1/net_weight');

/// Starts collecting [entry] on a fresh subscription and settles the async
/// plumbing, so the collector is listening to `stateMan.subscriptions.last`.
void _start(FakeAsync fake, _Rig rig, [CollectEntry? entry]) {
  unawaited(rig.collector.collectEntry(entry ?? _entry));
  fake.flushMicrotasks();
}

void main() {
  test('a completed stream is subscribed again and rows keep coming', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      expect(rig.stateMan.subscriptions, hasLength(1));

      // The first value of a subscription is skipped by design; prove the
      // stream is live with a second one.
      final first = rig.stateMan.subscriptions.single;
      first.add(DynamicValue(value: 1.0));
      first.add(DynamicValue(value: 2.0));
      fake.flushMicrotasks();
      expect(rig.database.rows, hasLength(1));

      // The server dropped the subscription: the stream completes.
      first.close();
      fake.flushMicrotasks();

      // Nothing yet -- the first rung of the ladder is a second.
      expect(rig.stateMan.subscriptions, hasLength(1));
      fake.elapse(const Duration(milliseconds: 999));
      expect(rig.stateMan.subscriptions, hasLength(1));

      fake.elapse(const Duration(milliseconds: 1));
      expect(rig.stateMan.subscriptions, hasLength(2),
          reason: 'after a done the collector must subscribe again; before '
              'this fix it logged "no more data will be collected" and '
              'meant it');

      // The value a fresh subscription replays is the node as it is now,
      // after a gap of unknown length: it goes in, unlike the startup one.
      final second = rig.stateMan.subscriptions.last;
      expect(second.hasListener, isTrue);
      second.add(DynamicValue(value: 3.0));
      fake.flushMicrotasks();
      expect(rig.database.rows, hasLength(2));
      second.add(DynamicValue(value: 4.0));
      fake.flushMicrotasks();
      expect(rig.database.rows, hasLength(3));
    });
  });

  test('a sampled entry gets its sample timer back', () {
    fakeAsync((fake) {
      final rig = _rig();
      final entry = CollectEntry(
        key: 'scale1/net_weight',
        name: 'scale1/net_weight',
        sampleInterval: const Duration(seconds: 5),
      );
      _start(fake, rig, entry);
      final first = rig.stateMan.subscriptions.single;
      first.add(DynamicValue(value: 1.0));
      fake.elapse(const Duration(seconds: 5));
      expect(rig.database.rows, hasLength(1), reason: 'sanity: sampling');

      first.close();
      fake.elapse(const Duration(seconds: 1));
      expect(rig.stateMan.subscriptions, hasLength(2));

      // The old timer is gone: no value has arrived on the new stream, so a
      // tick must not keep re-inserting the value the dead stream left.
      fake.elapse(const Duration(seconds: 10));
      expect(rig.database.rows, hasLength(1));

      rig.stateMan.subscriptions.last.add(DynamicValue(value: 2.0));
      fake.elapse(const Duration(seconds: 5));
      expect(rig.database.rows, hasLength(2),
          reason: 'the new subscription must be sampled on the same '
              'interval as the one it replaced');
      fake.elapse(const Duration(seconds: 5));
      expect(rig.database.rows, hasLength(3));
    });
  });

  test('repeated dones walk the backoff ladder; a value resets it', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);

      // Each new stream dies without ever delivering: 1s, 10s, 60s, 600s,
      // then 600s for as long as it takes.
      final expectedWaits = [1, 10, 60, 600, 600];
      for (final wait in expectedWaits) {
        final n = rig.stateMan.subscriptions.length;
        rig.stateMan.subscriptions.last.close();
        fake.flushMicrotasks();
        fake.elapse(Duration(seconds: wait - 1));
        expect(rig.stateMan.subscriptions, hasLength(n),
            reason: 'must wait the full ${wait}s rung');
        fake.elapse(const Duration(seconds: 1));
        expect(rig.stateMan.subscriptions, hasLength(n + 1),
            reason: 'must subscribe again after ${wait}s');
      }

      // A value on the live stream proves it healthy; the next done starts
      // over at the bottom rung.
      rig.stateMan.subscriptions.last.add(DynamicValue(value: 1.0));
      fake.flushMicrotasks();
      final n = rig.stateMan.subscriptions.length;
      rig.stateMan.subscriptions.last.close();
      fake.elapse(const Duration(seconds: 1));
      expect(rig.stateMan.subscriptions, hasLength(n + 1));
    });
  });

  test('a subscribe that throws is retried on the same ladder', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      rig.stateMan.failWith = StateManException('server "line1" is disabled');
      rig.stateMan.subscriptions.single.close();

      // 1s: the retry runs and fails. 10s later: again. Then the server
      // comes back and the third attempt, 60s on, gets a stream.
      fake.elapse(const Duration(seconds: 1));
      expect(rig.stateMan.subscriptions, hasLength(1));
      fake.elapse(const Duration(seconds: 10));
      expect(rig.stateMan.subscriptions, hasLength(1));
      rig.stateMan.failWith = null;
      fake.elapse(const Duration(seconds: 59));
      expect(rig.stateMan.subscriptions, hasLength(1));
      fake.elapse(const Duration(seconds: 1));
      expect(rig.stateMan.subscriptions, hasLength(2));
      expect(rig.stateMan.subscriptions.last.hasListener, isTrue);
    });
  });

  test('close() with a retry pending never subscribes again', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      rig.stateMan.subscriptions.single.close();
      fake.flushMicrotasks();

      rig.collector.close();
      fake.elapse(const Duration(hours: 1));
      expect(rig.stateMan.subscriptions, hasLength(1),
          reason: 'a closed collector must not own new subscriptions');
      expect(fake.pendingTimers, isEmpty,
          reason: 'no timer may outlive close()');
    });
  });

  test('close() while the retry is waiting on the server orphans nothing', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      rig.stateMan.subscriptions.single.close();

      // The retry fires and parks in subscribe(), as it would on a server
      // that is still away.
      rig.stateMan.gate = Completer<void>();
      fake.elapse(const Duration(seconds: 1));
      rig.collector.close();

      // The server answers after the collector is gone.
      rig.stateMan.gate!.complete();
      fake.flushMicrotasks();
      expect(rig.stateMan.subscriptions, hasLength(2),
          reason: 'sanity: the parked subscribe() did complete');
      expect(rig.stateMan.subscriptions.last.hasListener, isFalse,
          reason: 'the stream a closed collector was handed must be left '
              'alone -- listening to it would leak the subscription');
      expect(fake.pendingTimers, isEmpty);
    });
  });

  test('stopCollect() with a retry pending cancels it', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      rig.stateMan.subscriptions.single.close();
      fake.flushMicrotasks();

      rig.collector.stopCollect(_entry);
      fake.elapse(const Duration(hours: 1));
      expect(rig.stateMan.subscriptions, hasLength(1));
      expect(fake.pendingTimers, isEmpty);
    });
  });

  test('a re-collect while a retry is pending supersedes it', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      rig.stateMan.subscriptions.single.close();
      fake.flushMicrotasks();

      // A mapping edit re-collects the entry on a stream of its own before
      // the retry fires. That retry must not add a second subscription.
      final replacement = StreamController<DynamicValue>.broadcast();
      unawaited(rig.collector.collectEntryImpl(_entry, replacement.stream));
      fake.flushMicrotasks();
      fake.elapse(const Duration(hours: 1));
      expect(rig.stateMan.subscriptions, hasLength(1));
      expect(replacement.hasListener, isTrue);

      // The replacement delivers -- so the ladder is back at its first rung
      // -- and its own done is then recovered like any other.
      replacement.add(DynamicValue(value: 1.0));
      replacement.add(DynamicValue(value: 2.0));
      fake.flushMicrotasks();
      expect(rig.database.rows, hasLength(1));
      replacement.close();
      fake.elapse(const Duration(seconds: 1));
      expect(rig.stateMan.subscriptions, hasLength(2));
    });
  });

  test('a done from a superseded listener is ignored', () {
    fakeAsync((fake) {
      final rig = _rig();
      _start(fake, rig);
      final first = rig.stateMan.subscriptions.single;

      // Re-collected onto a new stream while the first is still open; the
      // first stream is abandoned, not cancelled, and completes later.
      final replacement = StreamController<DynamicValue>.broadcast();
      unawaited(rig.collector.collectEntryImpl(_entry, replacement.stream));
      fake.flushMicrotasks();
      first.close();
      fake.elapse(const Duration(hours: 1));
      expect(rig.stateMan.subscriptions, hasLength(1),
          reason: 'only the listener that currently owns the entry may '
              'trigger a resubscribe');
    });
  });
}
