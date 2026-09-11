/// The proxy before any fault: it must be invisible.
///
/// Every mode in this phase is stated as a difference from ordinary
/// forwarding — `cutMidFrame(137)` means 137 bytes arrive and then the
/// connection ends, `throttle` means the same bytes arrive more slowly. None
/// of those sentences can be judged against a transport that reorders,
/// truncates or stalls on its own. So this file asserts the boring half
/// first: a client that connects through the proxy reaches the server, in
/// both directions, with a payload large enough to cross the delay line's
/// high-water mark and come back intact.
///
/// It also asserts the two things that make the *unfinished* proxy honest.
/// Every one of the eight modes named in `faultModes` has its lever declared
/// today, and setting one whose behaviour has not landed throws by name.
/// A lever that silently did nothing would let a mode test pass against a
/// proxy that never injected the fault — the failure that makes a mode look
/// tested, and the one 02-14's integrity sweep exists to catch phase-wide.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// A payload as large as the delay line's whole 1 MiB high-water.
///
/// Not a round number chosen for looks: a payload smaller than the mark can be
/// carried entirely by one chunk-sized hop, so it exercises neither the
/// queue's ordering across many chunks nor — on a slow reader — its
/// pause/resume path. Whether backpressure actually engages depends on how
/// fast the echo server drains, which is why this arm asserts *order and
/// completeness* rather than a pause: the mode plans assert the pause, and
/// they can only do so on a transport already known not to reorder.
const _largePayloadBytes = 1024 * 1024;

const _chunkBytes = 64 * 1024;
const _connectBudget = Duration(seconds: 5);
const _arrivalBudget = Duration(seconds: 30);

/// Every mode name, paired with the lever a caller would reach for.
///
/// Keyed by the entries of `faultModes`, and the test below asserts the two
/// sets match — a lever nobody can name is a mode nobody will implement, and
/// a name with no lever is a mode that reads as delivered.
/// The modes whose behaviour has landed, each pointing at the file that proves
/// it bites.
///
/// A mode is allowed to be in exactly one of two states, and this map is the
/// boundary between them: either the lever refuses the setting and names the
/// plan it lands in, or the mode is implemented and a named test file measures
/// it. What must never exist is the third state — a lever that accepts a
/// setting and does nothing — which is why a name is only allowed to leave the
/// group below by arriving here with a test file beside it.
/// With `flap` below, the group is empty for the first time since the proxy
/// was scaffolded — every declared mode has a test file beside it. The group
/// is not deleted for that: it is conditional on being non-empty, so a ninth
/// mode declared in `faultModes` before it lands brings it straight back,
/// which is the state the declare-before-implement rule was written for.
const _landedModes = <String, String>{
  'flap': 'test/faults/flap_test.dart',
  'latency': 'test/faults/latency_test.dart',
  'throttle': 'test/faults/throttle_test.dart',
  'cutMidFrame': 'test/faults/cut_mid_frame_test.dart',
  'killOnce': 'test/faults/kill_once_test.dart',
  'blackhole': 'test/faults/blackhole_test.dart',
  'bufferServerToClient': 'test/faults/buffer_test.dart',
  'reject': 'test/faults/reject_test.dart',
};

final _levers = <String, void Function(FaultProxy)>{
  'flap': (p) => p.flap(const Duration(seconds: 1), const Duration(seconds: 1)),
  'latency': (p) => p.latency = const Duration(milliseconds: 50),
  'throttle': (p) => p.throttleBytesPerSec = 64 * 1024,
  'blackhole': (p) => p.blackhole(),
  'cutMidFrame': (p) => p.cutMidFrame(137),
  'killOnce': (p) => p.killOnce(),
  'reject': (p) => p.reject(),
  'bufferServerToClient': (p) => p.bufferServerToClient = true,
};

void main() {
  test('carries a conversation through to the upstream server and back',
      () async {
    final proxy = await _proxyToEcho();
    final client = await _connect(proxy.port);

    final reply = await _roundTrip(client, _pattern(64),
        what: 'the echo came back through the proxy');

    expect(reply.length, 64,
        reason: 'the proxy dropped bytes on an ordinary 64-byte exchange, so '
            'nothing built on it can distinguish an injected fault from the '
            'transport itself');
    expect(_firstDifference(reply, _pattern(64)), -1,
        reason: 'the bytes that came back are not the bytes that went out');
  });

  test('round-trips a megabyte in order, complete to the last byte', () async {
    final proxy = await _proxyToEcho();
    final client = await _connect(proxy.port);
    final payload = _pattern(_largePayloadBytes);

    final reply = await _roundTrip(client, payload,
        what: 'all $_largePayloadBytes bytes came back through the proxy');

    expect(reply.length, payload.length,
        reason: 'the proxy delivered ${reply.length} of ${payload.length} '
            'bytes. A proxy that truncates under load makes every mode test '
            'unfalsifiable: cutMidFrame(137) cannot be judged against a '
            'transport that cuts on its own');
    final firstDifference = _firstDifference(reply, payload);
    expect(firstDifference, -1,
        reason: 'byte $firstDifference differs, so the proxy reordered or '
            'corrupted a megabyte-scale stream. A proxy that reorders under '
            'load makes every mode test unfalsifiable — the assertion that '
            'fails names the mode, and the bug is in the transport under it');
  });

  test('reports the port the OS assigned when it was bound on port 0',
      () async {
    final proxy = await _proxyToEcho();
    expect(proxy.port, greaterThan(0),
        reason: 'tests bind on port 0 to avoid colliding with each other and '
            'with whatever else is running on a CI box; a proxy that cannot '
            'report the assigned port forces every test back onto a fixed '
            'port and back into those collisions');
  });

  test('shuts down twice without complaining', () async {
    final proxy = await _proxyToEcho();
    await _connect(proxy.port);

    await within(proxy.shutdown(), 'the first shutdown completed',
        budget: const Duration(seconds: 5));
    await within(proxy.shutdown(), 'the second shutdown completed',
        budget: const Duration(seconds: 5));

    expect(proxy.isRunning, isFalse,
        reason: 'every test in this phase registers shutdown as a teardown '
            'and several call it in the body as well; a second call that '
            'threw would turn an ordinary teardown into a failure attributed '
            'to whichever mode the test was actually about');
  });

  group('a lever whose mode has landed accepts the setting', () {
    for (final entry in _landedModes.entries) {
      test(entry.key, () async {
        final proxy = await _proxyToEcho();
        final lever = _levers[entry.key];
        expect(lever, isNotNull,
            reason: '${entry.key} is listed as landed with no lever in this '
                'test, so nothing proves a caller can even reach it');

        expect(
          () => lever!(proxy),
          returnsNormally,
          reason: '${entry.key} is implemented, so its lever must stop '
              'throwing — a mode still refusing its own setting cannot be '
              'used by the scenarios it was built for. What proves it does '
              'something rather than merely returning is ${entry.value}, '
              'which measures the effect on a live connection',
        );
      });
    }
  });

  final notLanded =
      faultModes.where((m) => !_landedModes.containsKey(m)).toList();

  test('every declared mode has a test file that proves it bites', () {
    // The other half of the boundary `_landedModes` documents. The group below
    // holds the un-landed names to a loud failure; this holds the landed ones
    // to an existing file, so a name cannot leave that group by being written
    // here beside a path nobody wrote — which is the cheapest way to make a
    // mode read as delivered.
    for (final entry in _landedModes.entries) {
      expect(File(entry.value).existsSync(), isTrue,
          reason: '${entry.key} is recorded as landed with its proof in '
              '${entry.value}, and that file does not exist. The record is '
              'what exempts the mode from the throws-by-name group, so a '
              'wrong path here is a mode with neither a failing lever nor a '
              'test');
    }
  });

  // Conditional, because a group whose loop body never runs declares no cases
  // and reads on CI as a group that was deliberately emptied. With all eight
  // modes landed this is currently skipped entirely; a ninth declared name
  // brings it back with no edit here.
  if (notLanded.isNotEmpty) {
    group('a lever whose mode has not landed throws by name', () {
      for (final mode in notLanded) {
        test(mode, () async {
          final proxy = await _proxyToEcho();
          final lever = _levers[mode];
          expect(lever, isNotNull,
              reason: '$mode is in faultModes with no lever in this test, so '
                  'nothing proves a caller can even reach it');

          expect(
            () => lever!(proxy),
            throwsA(isA<UnimplementedError>()
                .having((e) => e.message, 'message', contains(mode))
                .having((e) => e.message, 'message', contains('02-'))),
            reason: 'setting $mode must fail loudly naming the plan it lands '
                'in. A lever that accepts the setting and does nothing lets a '
                'mode test pass against a proxy that never injected the '
                'fault, which reads on CI as coverage of exactly the property '
                'that is missing',
          );
        });
      }
    });
  }

  test('names its eight modes as data', () {
    expect(faultModes, hasLength(8),
        reason: 'the eight modes CONTEXT names are flap, latency, throttle, '
            'blackhole, cutMidFrame, killOnce, reject and '
            'bufferServerToClient; this list is the single place that knows '
            'how many there are, and 02-14 sweeps it in both directions');
    expect(faultModes.toSet(), _levers.keys.toSet(),
        reason: 'a mode named with no lever reads as delivered, and a lever '
            'with no name escapes the integrity sweep entirely');
    expect(faultModes.toSet(), hasLength(faultModes.length),
        reason: 'a duplicated name makes the sweep count a mode twice and '
            'declare a missing one covered');
    expect(_landedModes.keys, everyElement(isIn(faultModes)),
        reason: 'a landed name that is not a mode exempts nothing from the '
            'throws-by-name group while looking like it did; a misspelling '
            'here would leave a real mode in the group and read as though it '
            'had been implemented');
  });
}

/// A proxy in front of a fresh echo server, torn down at the end of the test.
Future<FaultProxy> _proxyToEcho() async {
  final echo = await _echoServer();
  final proxy = FaultProxy(targetPort: echo.port);
  await proxy.start();
  addTearDown(proxy.shutdown);
  return proxy;
}

/// A loopback echo server that gates its own writes and destroys what it
/// accepted.
///
/// Both halves matter to the leak criterion this phase is heading for: an echo
/// server that leaks its accepted sockets would make `leak_test.dart` fail for
/// a reason that has nothing to do with the proxy.
Future<ServerSocket> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = <Socket>[];
  addTearDown(() {
    for (final socket in accepted) {
      socket.destroy();
    }
  });

  final accepts = server.listen((socket) {
    accepted.add(socket);
    unawaited(socket.done.catchError((Object _) => socket));
    late final StreamSubscription<Uint8List> echoing;
    echoing = socket.listen(
      (data) {
        socket.add(data);
        // The same gate the delay line uses, for the same reason: an echo
        // server that buffers without limit reproduces Finding 7 in the rig.
        echoing.pause(socket.flush().catchError((Object _) {}));
      },
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
    );
  });
  addTearDown(accepts.cancel);
  return server;
}

/// Connects to [port] on loopback, destroyed at the end of the test.
Future<Socket> _connect(int port) async {
  final socket = await within(
    Socket.connect(InternetAddress.loopbackIPv4, port),
    'the client reached the proxy on port $port',
    budget: _connectBudget,
  );
  addTearDown(socket.destroy);
  unawaited(socket.done.catchError((Object _) => socket));
  return socket;
}

/// Writes [payload] and returns the same number of bytes read back.
///
/// Gated on `flush()` chunk by chunk, so the rig applies pressure to the proxy
/// rather than buffering the whole payload in its own sink and measuring
/// `dart:io` instead.
Future<Uint8List> _roundTrip(Socket socket, Uint8List payload,
    {required String what}) async {
  final received = BytesBuilder(copy: false);
  final complete = Completer<Uint8List>();
  socket.listen(
    (data) {
      received.add(data);
      if (received.length >= payload.length && !complete.isCompleted) {
        complete.complete(received.takeBytes());
      }
    },
    onDone: () {
      if (!complete.isCompleted) {
        complete.completeError(StateError(
            'the connection closed after ${received.length} of '
            '${payload.length} bytes'));
      }
    },
    onError: (Object error) {
      if (!complete.isCompleted) complete.completeError(error);
    },
  );

  for (var offset = 0; offset < payload.length; offset += _chunkBytes) {
    final end = min(offset + _chunkBytes, payload.length);
    socket.add(Uint8List.sublistView(payload, offset, end));
    await socket.flush();
  }

  return within(complete.future, what, budget: _arrivalBudget);
}

/// A deterministic pattern whose shifts are visible.
Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}

/// The index of the first differing byte, or -1 when the prefixes match.
int _firstDifference(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : shared;
}
