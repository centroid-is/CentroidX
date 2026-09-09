/// The macOS fault lane's failure, amplified until it is reproducible, and
/// asked the one question `livePairs` cannot answer.
///
/// `composition_test.dart`'s arm gets ONE reset per run — the flap's first
/// down-edge at t≈8 s — and fails roughly twice in fifteen macOS runs. Nobody
/// could reproduce it because reproducing it needs thousands of resets. This
/// file sets the SAME three modes and flaps at 400 ms / 150 ms with a pool of
/// reconnecting clients: ~2 resets a second instead of one per nine.
///
/// **What it is looking for.** The CI failure is the triple *flap fired, no
/// pairs held, client still connected* — and `livePairs`, read seconds later,
/// cannot distinguish "the pair was dropped and the client never saw the
/// reset" from "the pair left `_pairs` without a reset being sent at all".
/// Those have opposite fixes. `FaultProxy.pairsRetiredWithLiveClient` answers
/// exactly that, and this file is what drives it hard enough to speak.
///
/// **Not run by default and never in CI.** It is a soak: minutes of wall clock,
/// thousands of sockets, and its verdict is a measurement rather than a
/// threshold. Run it deliberately:
///
/// ```
/// STORM_PROBE=60 dart test test/faults/storm_probe_test.dart
/// ```
///
/// with the value in seconds. Without the variable the arm skips, which is why
/// it can live beside the suite instead of in a scratch package that is deleted
/// after every investigation — the next person to see this failure should find
/// the instrument, not a description of one.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

/// The composition arm's three modes, verbatim — the point is that these are
/// not a new configuration but the shipping one, run more often.
const _latency = Duration(milliseconds: 50);
const _rate = 12500;

/// Where the amplification lives, and the ONLY departure from the arm under
/// investigation. 400 ms of up-window at [_rate] is 5000 bytes, which is what
/// both observed misses had read when they stopped hearing anything — a
/// complete, healthy window and then silence.
const _up = Duration(milliseconds: 400);
const _down = Duration(milliseconds: 150);

/// How long a client waits for its link to end before it counts as a miss.
/// Generous on purpose: the CI arm allows 16 s and this is not measuring the
/// budget, it is measuring whether the end ever arrives at all.
const _endBudget = Duration(seconds: 6);

const _workers = 40;
const _firehose = 0xf0;
const _blockBytes = 1024;

void main() {
  final seconds = int.tryParse(Platform.environment['STORM_PROBE'] ?? '');

  test('a reset reaches every client, or says which ones it did not reach',
      () async {
    final rig = await _Rig.open();
    rig.proxy.latency = _latency;
    rig.proxy.throttleBytesPerSec = _rate;
    rig.proxy.flap(_up, _down);

    final deadline = Stopwatch()..start();
    final misses = <String>[];
    var attempts = 0, connected = 0, ends = 0;

    Future<void> worker() async {
      while (deadline.elapsed.inSeconds < seconds!) {
        attempts++;
        Socket socket;
        try {
          socket = await Socket.connect(
              InternetAddress.loopbackIPv4, rig.proxy.port,
              timeout: const Duration(seconds: 5));
        } on Object {
          // A refused connect during a down-window is the mode working.
          continue;
        }
        connected++;
        var read = 0;
        final ended = Completer<void>();
        void end() {
          if (!ended.isCompleted) ended.complete();
        }

        socket.listen((chunk) => read += chunk.length,
            onError: (Object _) => end(), onDone: end, cancelOnError: true);
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        try {
          socket.add(Uint8List.fromList(<int>[_firehose]));
          await socket.flush();
        } on Object {
          socket.destroy();
          continue;
        }
        try {
          await ended.future.timeout(_endBudget);
          ends++;
        } on TimeoutException {
          // The stream said nothing. Ask the socket directly: on a peer that
          // has really gone, a write must fail. If it succeeds, the connection
          // is alive and the reset never landed; if it throws, the connection
          // is dead and only the *notification* was lost — which is a
          // different defect, in a different component, with a different fix.
          String probe;
          try {
            socket.add(Uint8List.fromList(<int>[0]));
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            probe = ended.isCompleted
                ? 'WRITE-THEN-END (the write woke the notification)'
                : 'WRITE OK, still silent (peer alive?)';
          } on Object catch (e) {
            probe = 'WRITE FAILED: ${e.runtimeType} '
                '(peer gone; only the notification was lost)';
          }
          misses.add('at ${deadline.elapsed.inMilliseconds} ms: no end in '
              '${_endBudget.inSeconds} s with $read bytes read; '
              'transitions=${rig.proxy.flapTransitions} '
              'livePairs=${rig.proxy.livePairs} '
              'retiredWithLiveClient=${rig.proxy.pairsRetiredWithLiveClient} '
              '| $probe');
        }
        socket.destroy();
      }
    }

    await Future.wait<void>([for (var i = 0; i < _workers; i++) worker()]);
    rig.proxy.flap(_up, _down, enabled: false);

    // ignore: avoid_print
    print('storm: ${deadline.elapsed.inSeconds} s, $attempts attempts, '
        '$connected connected, $ends ends, ${misses.length} misses, '
        '${rig.proxy.flapTransitions} transitions\n'
        'RETIRED WITH LIVE CLIENT: ${rig.proxy.pairsRetiredWithLiveClient}\n'
        '${misses.join('\n')}');

    // The verdict, and the reason this file exists. A miss on its own is
    // ambiguous; a miss with a nonzero counter is not.
    expect(rig.proxy.pairsRetiredWithLiveClient, 0,
        reason: 'a pair left the proxy without its client socket ever being '
            'ended — the client is still connected to nothing and no reset is '
            'coming. This is the macOS lane failure, and it is the proxy that '
            'produced it, not the runner and not the budget');
  },
      timeout: Timeout(Duration(seconds: (seconds ?? 0) + 120)),
      skip: seconds == null
          ? 'soak: set STORM_PROBE=<seconds> to run (see the library doc)'
          : null);
}

final class _Rig {
  _Rig._(this.proxy);

  final FaultProxy proxy;

  static Future<_Rig> open() async {
    final upstream = await _upstreamServer();
    final proxy = FaultProxy(targetPort: upstream.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
    return _Rig._(proxy);
  }
}

/// Firehoses on command, and stops when told — `throttle_test.dart`'s shape,
/// copied for its stated reason: a firehose whose only stop condition is a
/// throwing write starves the event loop once the proxy is gone, and the
/// runner hangs with no failing test.
Future<ServerSocket> _upstreamServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final block = Uint8List(_blockBytes)
    ..setAll(0, List<int>.generate(_blockBytes, (i) => i & 0xff));
  var stopped = false;
  addTearDown(() => stopped = true);
  final accepted = <Socket>[];
  addTearDown(() {
    for (final socket in accepted) {
      socket.destroy();
    }
  });
  server.listen((socket) {
    accepted.add(socket);
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    socket.listen((chunk) async {
      if (!chunk.contains(_firehose)) {
        try {
          socket.add(chunk);
        } on Object {
          // The proxy cut this direction; nothing to send it to.
        }
        return;
      }
      while (!stopped) {
        try {
          socket.add(block);
          await socket.flush();
        } on Object {
          return;
        }
      }
    }, onError: (Object _) {}, cancelOnError: true);
  }, onError: (Object _) {});
  return server;
}
