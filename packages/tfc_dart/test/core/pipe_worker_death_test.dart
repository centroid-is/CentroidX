/// Death is an event, not decay.
///
/// The `null` the VM puts on a worker's data port is a fact main must act on
/// the instant it arrives: every key that worker was piping goes bad, and every
/// write waiting on it resolves unknown. The alternative — letting a freshness
/// sweep notice, seconds later, that nothing has arrived — shows the operator a
/// plausible reading for a link that is already gone, and leaves a write in
/// flight until its own deadline for an answer that can never come.
///
/// The respawn's replay is a SNAPSHOT of main's current intent, never a delta,
/// and it carries no writes with it: a write that was in flight when the worker
/// died is unknown, and re-sending it would be a second movement of a machine
/// nobody asked for.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// A worker whose generations main can replace by hand.
///
/// [respawn] mints a fresh control port, exactly as a real supervisor does: the
/// handle survives, the isolate behind it does not. Messages sent to the dead
/// generation land in [buried] and are asserted to be nothing.
class _FakeLink implements PipeWorkerLink {
  _FakeLink(this.name) {
    _port.listen(received.add);
  }

  @override
  final String name;

  ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();
  final List<ReceivePort> _retired = <ReceivePort>[];

  /// What the CURRENT generation was sent.
  List<Object?> received = <Object?>[];

  /// What every previous generation was sent, flattened.
  final List<Object?> buried = <Object?>[];

  bool alive = true;
  int kills = 0;

  @override
  SendPort? get controlPort => alive ? _port.sendPort : null;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() => kills++;

  void emit(Object? message) => _out.add(message);

  /// The isolate died: the VM's `null` sentinel on the data port.
  void die() {
    alive = false;
    emit(null);
  }

  /// A new generation announced itself with a fresh control port.
  void respawn() {
    _retired.add(_port);
    buried.addAll(received);
    received = <Object?>[];
    _port = ReceivePort();
    _port.listen(received.add);
    alive = true;
    emit(_port.sendPort);
  }

  void dispose() {
    _port.close();
    for (final port in _retired) {
      port.close();
    }
    if (!_out.isClosed) _out.close();
  }
}

Future<void> _settle() => pumpEventQueue(times: 10);

relay.DynamicValue _good(Object? v) =>
    relay.DynamicValue(value: v, sourceTime: DateTime.utc(2026, 1, 1));

void main() {
  late _FakeLink alpha;
  late _FakeLink beta;
  late PipeMainEndpoint endpoint;

  setUp(() {
    alpha = _FakeLink('alpha');
    beta = _FakeLink('beta');
    endpoint = PipeMainEndpoint(writeDeadline: const Duration(seconds: 30));
    endpoint.addWorker(alpha, const ['a.one', 'a.two']);
    endpoint.addWorker(beta, const ['b.one']);
  });

  tearDown(() {
    endpoint.dispose();
    alpha.dispose();
    beta.dispose();
  });

  group('the null sentinel is an event', () {
    test('every key that worker was piping is marked bad immediately',
        () async {
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.two');
      await _settle();
      alpha.emit(PipeFrame(const [], {'a.one': _good(7), 'a.two': _good(8)}));
      await _settle();
      expect(endpoint.read('a.one').value, 7);

      alpha.die();
      await _settle();

      for (final key in const ['a.one', 'a.two']) {
        expect(endpoint.read(key).quality, relay.Quality.badCommFault,
            reason: '$key was piped by the worker that just died');
        expect(endpoint.read(key).value, isNull,
            reason: 'a reading nobody measured must not survive the link');
      }
    });

    test('the marking is un-conflated — it does not wait for a drain tick',
        () async {
      endpoint.subscribe('a.one');
      await _settle();
      alpha.emit(PipeFrame(const [], {'a.one': _good(7)}));
      await _settle();

      var rebuilds = 0;
      endpoint.listen('a.one').addListener(() => rebuilds++);
      alpha.die();
      await _settle();

      // No frame carried this, and no timer produced it: the sentinel itself
      // did, on the turn it arrived.
      expect(rebuilds, 1);
      expect(endpoint.read('a.one').quality, relay.Quality.badCommFault);
    });

    test('another worker is untouched by its neighbour dying', () async {
      endpoint.subscribe('b.one');
      await _settle();
      beta.emit(PipeFrame(const [], {'b.one': _good(3)}));
      await _settle();

      alpha.die();
      await _settle();

      expect(endpoint.read('b.one').value, 3);
      expect(endpoint.read('b.one').quality, relay.Quality.good);
    });

    test('a key that worker owns but nobody subscribed to is left alone',
        () async {
      endpoint.subscribe('a.one');
      await _settle();

      alpha.die();
      await _settle();

      expect(endpoint.read('a.two').quality, relay.Quality.uncertainNotYetKnown,
          reason: 'never piped, never known — not a comm failure');
    });

    test('every pending write for that worker resolves unknown at once',
        () async {
      final first = endpoint.write('a.one', _good(1));
      final second = endpoint.write('a.two', _good(2));
      await _settle();
      expect(endpoint.pendingWriteCount(0), 2);

      alpha.die();

      // The endpoint's own deadline is 30s in this suite; if these settle it
      // is because the death resolved them and for no other reason.
      for (final result in await Future.wait([first, second])) {
        expect(result, isA<relay.WriteUnknown>());
        expect((result as relay.WriteUnknown).reason.kind, 'worker_died');
      }
      expect(endpoint.pendingWriteCount(0), 0);
    });

    test('a neighbour worker keeps its pending write', () async {
      final mine = endpoint.write('b.one', _good(3));
      await _settle();

      alpha.die();
      await _settle();

      expect(endpoint.pendingWriteCount(1), 1);
      final id = beta.received.whereType<PipeWriteRequest>().single.id;
      beta.emit(PipeFrame([
        PipeWriteOutcome(id, relay.WriteApplied('$id', readback: 3, at: 1)),
      ], const {}));
      expect(await mine, isA<relay.WriteApplied>());
    });
  });

  group('the respawn replays a snapshot', () {
    test('the new generation is sent the full current subscription set',
        () async {
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.two');
      await _settle();
      alpha.die();
      await _settle();
      alpha.respawn();
      await _settle();

      final replayed = alpha.received
          .whereType<PipeSubscribe>()
          .map((s) => s.key)
          .toSet();
      expect(replayed, {'a.one', 'a.two'});
    });

    test('the replay is a snapshot, not a delta — a key released while the '
        'worker was dead is not replayed', () async {
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.two');
      await _settle();
      alpha.die();
      await _settle();

      endpoint.unsubscribe('a.two');
      endpoint.subscribe('a.one'); // a second watcher, still one key
      await _settle();

      alpha.respawn();
      await _settle();

      final replayed = alpha.received
          .whereType<PipeSubscribe>()
          .map((s) => s.key)
          .toList();
      expect(replayed, ['a.one'],
          reason: 'a.two has no watcher left; a.one is sent once, not twice');
      expect(alpha.received.whereType<PipeUnsubscribe>(), isEmpty,
          reason: 'a fresh worker is piping nothing — a delta would be a lie');
    });

    test('the first generation replays nothing', () async {
      alpha.respawn();
      await _settle();

      expect(alpha.received, isEmpty);
    });

    test('a write in flight across the death is unknown and never re-sent',
        () async {
      // Subscribed first, deliberately: the replay path only runs for a worker
      // with a non-empty snapshot, so without this the arm would be asserting
      // that a code path which never executed sent no writes.
      endpoint.subscribe('a.one');
      await _settle();
      final pending = endpoint.write('a.one', _good(1));
      await _settle();
      expect(alpha.received.whereType<PipeWriteRequest>(), hasLength(1));

      alpha.die();
      final result = await pending;
      expect(result, isA<relay.WriteUnknown>());

      alpha.respawn();
      await _settle();

      expect(alpha.received.whereType<PipeWriteRequest>(), isEmpty,
          reason: 'the pipe never re-sends a write; that is the operator\'s '
              'decision and nobody else\'s');
    });

    test('the respawned worker serves values again', () async {
      endpoint.subscribe('a.one');
      await _settle();
      alpha.die();
      await _settle();
      alpha.respawn();
      await _settle();

      alpha.emit(PipeFrame(const [], {'a.one': _good(11)}));
      await _settle();

      expect(endpoint.read('a.one').value, 11);
      expect(endpoint.read('a.one').quality, relay.Quality.good);
    });

    test('a write minted while the worker is dead is answered, not queued',
        () async {
      endpoint.subscribe('a.one'); // so the respawn has a snapshot to replay
      await _settle();
      alpha.die();
      await _settle();

      final result = await endpoint.write('a.one', _good(1));
      expect(result, isA<relay.WriteUnknown>());

      alpha.respawn();
      await _settle();
      expect(alpha.received.whereType<PipeWriteRequest>(), isEmpty);
    });
  });
}
