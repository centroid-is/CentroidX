/// Main's end of the acquisition pipe: the cache, the write router and the
/// refcounted subscribe surface.
///
/// Every arm that asserts on `SendPort` traffic drains the event queue first
/// (`_settle`). One-isolate `SendPort` delivery is NOT synchronous — 12-05 lost
/// three arms to that and the fix is written down in its summary.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// A worker main can talk to, with no isolate behind it.
///
/// The control port is a REAL [ReceivePort], because that is the thing whose
/// delivery semantics the endpoint has to live with; the message stream is a
/// plain controller standing in for [DataAcquisitionWorker.messages], which is
/// single-subscription for the same reason.
class _FakeLink implements PipeWorkerLink {
  _FakeLink(this.name) {
    _port.listen(received.add);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  /// Everything main sent down the control channel, in order.
  final List<Object?> received = <Object?>[];

  int kills = 0;
  bool down = false;

  @override
  SendPort? get controlPort => down ? null : _port.sendPort;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() => kills++;

  /// One message from the worker to main.
  void emit(Object? message) => _out.add(message);

  List<PipeWriteRequest> get writes => received.whereType<PipeWriteRequest>().toList();

  void dispose() {
    _port.close();
    if (!_out.isClosed) _out.close();
  }
}

/// Port delivery is asynchronous even inside one isolate. See the library doc.
Future<void> _settle() => pumpEventQueue(times: 10);

relay.DynamicValue _good(Object? v, {DateTime? at, String? sourceTypeId}) =>
    relay.DynamicValue(
      value: v,
      sourceTime: at ?? DateTime.utc(2026, 1, 1),
      sourceTypeId: sourceTypeId,
    );

void main() {
  late _FakeLink alpha;
  late _FakeLink beta;
  late PipeMainEndpoint endpoint;

  setUp(() {
    alpha = _FakeLink('alpha');
    beta = _FakeLink('beta');
    endpoint = PipeMainEndpoint(writeDeadline: const Duration(milliseconds: 80));
    endpoint.addWorker(alpha, const ['a.one', 'a.two']);
    endpoint.addWorker(beta, const ['b.one']);
  });

  tearDown(() {
    endpoint.dispose();
    alpha.dispose();
    beta.dispose();
  });

  group('the cache', () {
    test('a drained worker frame lands in the value store', () async {
      alpha.emit(PipeFrame(const [], {'a.one': _good(7)}));
      await _settle();

      expect(endpoint.read('a.one').value, 7);
      expect(endpoint.read('a.one').quality, relay.Quality.good);
    });

    test('a key no frame has carried reads notYetKnown', () {
      expect(endpoint.read('a.two').quality, relay.Quality.uncertainNotYetKnown);
      expect(endpoint.read('a.two').value, isNull);
      expect(endpoint.store.peek('a.two'), isNull);
    });

    test('an unchanged key does not notify a second time', () async {
      var rebuilds = 0;
      endpoint.listen('a.one').addListener(() => rebuilds++);

      final at = DateTime.utc(2026, 5, 5);
      alpha.emit(PipeFrame(const [], {'a.one': _good(7, at: at)}));
      await _settle();
      alpha.emit(PipeFrame(const [], {'a.one': _good(7, at: at)}));
      await _settle();

      expect(rebuilds, 1);
    });

    test('a key fault on the priority lane marks the key bad in the cache',
        () async {
      alpha.emit(PipeFrame(const [], {'a.one': _good(7)}));
      await _settle();
      alpha.emit(PipeFrame(
        [const PipeKeyError('a.one', relay.Quality.badCommFault, 'boom')],
        const {},
      ));
      await _settle();

      expect(endpoint.read('a.one').quality, relay.Quality.badCommFault);
      expect(endpoint.read('a.one').value, isNull);
    });

    test('a retirement is errorConfig, not silence', () async {
      alpha.emit(PipeFrame(const [], {'a.one': _good(7)}));
      await _settle();
      alpha.emit(PipeFrame(const [PipeKeyRetired('a.one')], const {}));
      await _settle();

      expect(endpoint.read('a.one').quality, relay.Quality.errorConfig);
    });
  });

  group('the write router', () {
    test('a write reaches exactly the worker that owns the key', () async {
      unawaited(endpoint.write('b.one', _good(3)));
      await _settle();

      expect(beta.writes.map((w) => w.key), ['b.one']);
      expect(alpha.writes, isEmpty);
    });

    test('keyToWorker is disjoint — one key, one owner', () {
      expect(endpoint.workerOf('a.one'), isNotNull);
      expect(endpoint.workerOf('b.one'), isNotNull);
      expect(endpoint.workerOf('a.one'), isNot(endpoint.workerOf('b.one')));
      expect(endpoint.workerOf('nobody.owns.me'), isNull);
    });

    test('a key a later worker also claims stays with its first owner', () {
      final gamma = _FakeLink('gamma');
      addTearDown(gamma.dispose);
      // The spawn already happened with the first partition; re-pointing the
      // key here would mean a write could reach a worker that was never given
      // the mapping for it.
      final index = endpoint.addWorker(gamma, const ['a.one', 'g.one']);

      expect(endpoint.workerOf('a.one'), isNot(index));
      expect(endpoint.workerOf('g.one'), index);
    });

    test('a key no worker owns is refused without touching any worker',
        () async {
      final result = await endpoint.write('nobody.owns.me', _good(1));
      await _settle();

      expect(result, isA<relay.WriteRejected>());
      expect((result as relay.WriteRejected).reason.kind, 'unrouted');
      expect(alpha.received, isEmpty);
      expect(beta.received, isEmpty);
    });

    test('correlation ids are per-worker and monotonic', () async {
      unawaited(endpoint.write('a.one', _good(1)));
      unawaited(endpoint.write('a.two', _good(2)));
      unawaited(endpoint.write('b.one', _good(3)));
      await _settle();

      expect(alpha.writes.map((w) => w.id), [1, 2]);
      expect(beta.writes.map((w) => w.id), [1]);
    });

    test('an applied echo resolves the matching write applied', () async {
      final pending = endpoint.write('a.one', _good(1));
      await _settle();
      final id = alpha.writes.single.id;

      alpha.emit(PipeFrame([
        PipeWriteOutcome(id, relay.WriteApplied('$id', readback: 1, at: 5)),
      ], const {}));

      expect(await pending, isA<relay.WriteApplied>());
    });

    test('a rejected echo resolves the matching write rejected', () async {
      final pending = endpoint.write('a.one', _good(1));
      await _settle();
      final id = alpha.writes.single.id;

      alpha.emit(PipeFrame([
        PipeWriteOutcome(
          id,
          relay.WriteRejected('$id', const relay.WriteReason('interlocked')),
        ),
      ], const {}));

      final result = await pending;
      expect(result, isA<relay.WriteRejected>());
      expect((result as relay.WriteRejected).reason.kind, 'interlocked');
    });

    test('an unknown echo resolves the matching write unknown', () async {
      final pending = endpoint.write('a.one', _good(1));
      await _settle();
      final id = alpha.writes.single.id;

      alpha.emit(PipeFrame([
        PipeWriteOutcome(
          id,
          relay.WriteUnknown('$id', const relay.WriteReason('plc_timeout')),
        ),
      ], const {}));

      final result = await pending;
      expect(result, isA<relay.WriteUnknown>());
      expect((result as relay.WriteUnknown).reason.kind, 'plc_timeout');
    });

    test('two writes in flight resolve independently, by id', () async {
      final first = endpoint.write('a.one', _good(1));
      final second = endpoint.write('a.two', _good(2));
      await _settle();
      final ids = alpha.writes.map((w) => w.id).toList();

      alpha.emit(PipeFrame([
        PipeWriteOutcome(
          ids[1],
          relay.WriteApplied('${ids[1]}', readback: 2, at: 5),
        ),
      ], const {}));
      expect(await second, isA<relay.WriteApplied>());

      alpha.emit(PipeFrame([
        PipeWriteOutcome(
          ids[0],
          relay.WriteRejected('${ids[0]}', const relay.WriteReason('range')),
        ),
      ], const {}));
      expect(await first, isA<relay.WriteRejected>());
    });

    test('a worker that never answers resolves pipe_timeout, never hangs',
        () async {
      final result = await endpoint.write('a.one', _good(1));

      expect(result, isA<relay.WriteUnknown>());
      expect((result as relay.WriteUnknown).reason.kind, 'pipe_timeout');
    });

    test('an expired write is never re-sent, and a late echo is harmless',
        () async {
      final result = await endpoint.write('a.one', _good(1));
      expect(result, isA<relay.WriteUnknown>());
      final id = alpha.writes.single.id;

      alpha.emit(PipeFrame([
        PipeWriteOutcome(id, relay.WriteApplied('$id', readback: 1, at: 5)),
      ], const {}));
      await _settle();

      expect(alpha.writes, hasLength(1));
    });

    test('a worker with no live control port answers without pretending',
        () async {
      alpha.down = true;
      final result = await endpoint.write('a.one', _good(1));

      expect(result, isA<relay.WriteUnknown>());
      expect((result as relay.WriteUnknown).reason.kind, 'worker_down');
      expect(alpha.received, isEmpty);
    });

    test('the payload carries the type id the cache observed', () async {
      alpha.emit(PipeFrame(
        const [],
        {'a.one': _good(7, sourceTypeId: 'ns=0;i=4')},
      ));
      await _settle();

      unawaited(endpoint.write('a.one', _good(9)));
      await _settle();

      expect(alpha.writes.single.value.sourceTypeId, 'ns=0;i=4');
    });

    test('dispose settles the writes still in flight instead of dropping them',
        () async {
      final pending = endpoint.write('a.one', _good(1));
      await _settle();
      expect(alpha.writes, hasLength(1));

      // `write` promises the future ALWAYS settles. Cancelling the deadline
      // timer and clearing the table takes the completer with it, so the
      // caller waits forever on a promise this class makes in its own doc —
      // and a graceful-reload path or a test awaiting across a dispose is all
      // it takes to reach it.
      endpoint.dispose();

      final result = await pending.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('dispose dropped a pending write instead of '
            'resolving it — the future never settled'),
      );
      expect(result, isA<relay.WriteUnknown>(),
          reason: 'this side cannot tell whether the worker applied it, and '
              'unknown is the one honest answer');
      expect((result as relay.WriteUnknown).reason.kind, 'endpoint_disposed');
      expect(endpoint.pendingWriteCount(endpoint.workerOf('a.one')!), 0);
    });

    test('a caller that supplies its own type id keeps it', () async {
      alpha.emit(PipeFrame(
        const [],
        {'a.one': _good(7, sourceTypeId: 'ns=0;i=4')},
      ));
      await _settle();

      unawaited(endpoint.write('a.one', _good(9, sourceTypeId: 'ns=0;i=6')));
      await _settle();

      expect(alpha.writes.single.value.sourceTypeId, 'ns=0;i=6');
    });
  });

  group('the subscribe surface (refcounted, control on the 0 <-> 1 transition)',
      () {
    /// Every subscribe/unsubscribe control message a worker was sent, in order.
    List<Object?> control(_FakeLink link) => link.received
        .where((m) => m is PipeSubscribe || m is PipeUnsubscribe)
        .toList();

    test('the first subscribe sends exactly one control message, to the owner',
        () async {
      endpoint.subscribe('a.one');
      await _settle();

      expect(control(alpha), hasLength(1));
      expect((control(alpha).single as PipeSubscribe).key, 'a.one');
      expect(control(beta), isEmpty);
    });

    test('a second subscriber for the same key mints no control message',
        () async {
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.one');
      await _settle();

      expect(control(alpha), hasLength(1));
      expect(endpoint.refcountOf('a.one'), 3);
    });

    test('the unsubscribe crosses only when the LAST watcher goes', () async {
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.one');
      await _settle();

      endpoint.unsubscribe('a.one');
      await _settle();
      expect(control(alpha).whereType<PipeUnsubscribe>(), isEmpty,
          reason: 'one watcher is still holding the key');

      endpoint.unsubscribe('a.one');
      await _settle();
      expect(control(alpha).whereType<PipeUnsubscribe>(), hasLength(1));
      expect(endpoint.refcountOf('a.one'), 0);
    });

    test('the per-worker subscribed set is exactly the keys with a refcount',
        () async {
      endpoint.subscribe('a.one');
      endpoint.subscribe('a.two');
      endpoint.subscribe('a.two');
      endpoint.subscribe('b.one');
      await _settle();

      expect(endpoint.subscribedKeys(0), {'a.one', 'a.two'});
      expect(endpoint.subscribedKeys(1), {'b.one'});

      endpoint.unsubscribe('a.one');
      endpoint.unsubscribe('a.two');
      await _settle();

      expect(endpoint.subscribedKeys(0), {'a.two'},
          reason: 'a.two still has one watcher; a.one has none');
    });

    test('a key no worker owns is a no-op refusal — no message, no refcount',
        () async {
      endpoint.subscribe('nobody.owns.me');
      endpoint.unsubscribe('nobody.owns.me');
      await _settle();

      expect(alpha.received, isEmpty);
      expect(beta.received, isEmpty);
      expect(endpoint.refcountOf('nobody.owns.me'), 0);
    });

    test('unsubscribing a key nobody subscribed to touches no worker',
        () async {
      endpoint.unsubscribe('a.one');
      await _settle();

      expect(alpha.received, isEmpty);
      expect(endpoint.refcountOf('a.one'), 0);
    });

    test('a re-subscribe after the release crosses again', () async {
      endpoint.subscribe('a.one');
      endpoint.unsubscribe('a.one');
      endpoint.subscribe('a.one');
      await _settle();

      expect(control(alpha).whereType<PipeSubscribe>(), hasLength(2));
      expect(control(alpha).whereType<PipeUnsubscribe>(), hasLength(1));
      expect(endpoint.subscribedKeys(0), {'a.one'});
    });

    test('the release is at zero, not on a timer', () async {
      endpoint.subscribe('a.one');
      await _settle();
      endpoint.unsubscribe('a.one');

      // No pump, no delay: the control message is on its way already.
      expect(endpoint.subscribedKeys(0), isEmpty);
      expect(endpoint.refcountOf('a.one'), 0);
    });
  });

  group('the deadline constant', () {
    test('kPipeWriteDeadline matches LocalStateMan.writeDeadline', () {
      expect(kPipeWriteDeadline, const Duration(seconds: 5));
    });

    test('it is strictly outside the worker deadline, so the worker answers '
        'first', () {
      expect(kPipeWriteDeadline, greaterThan(kPipeWorkerWriteDeadline));
    });
  });
}
