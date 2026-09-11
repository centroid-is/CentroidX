/// Roadmap criterion 4: open and tear down 100 proxied connections, and the
/// open-socket count comes back to where it started.
///
/// This criterion has already caught a real leak. RESEARCH Finding 11 ran it
/// against the first version of the proxy and measured deltas of 10, 60 and
/// 160 over 10, 50 and 100 cycles — exactly one descriptor per cycle. The
/// culprit was the upstream-accepted socket: when its peer went away the
/// stream ended, and nothing destroyed the socket. Resolution is therefore one
/// fd, which is precisely the bug class this exists for, and the fix is a
/// single line in `fault_proxy.dart` that this file is here to keep.
///
/// **The control arm is not decoration.** `expect(delta, 0)` passes vacuously
/// whenever the counter is broken, and the obvious counter *is* broken: `lsof`
/// exits 1 when no rows match, so an `exitCode != 0` check reports failure
/// exactly when the honest answer is zero (RESEARCH Pitfall 2). The 20-held
/// arm below makes a silent counter fail loudly instead.
///
/// **The checkpoints are a rate, not a number.** Reporting +10, +50 and +100
/// separately is what turns "we leak" into "we leak one per cycle", which is
/// the sentence that names the missing `destroy()`. A single assertion at the
/// end says only that something, somewhere, over a hundred cycles, went wrong.
///
/// **TIME_WAIT needs no handling and no `SO_REUSEADDR` gymnastics.** RESEARCH
/// measured 1245 system-wide TIME_WAIT entries accumulating during the
/// 100-cycle run without moving the count, because a TIME_WAIT socket holds a
/// kernel table entry and not a file descriptor. Anyone tempted to add
/// address-reuse options to make this test stable should know it was already
/// stable without them.
@Tags(['faults'])
@OnPlatform({
  'windows': Skip('open-fd counting needs /proc/self/fd or lsof; Windows has '
      'neither, so proxy fd hygiene goes unjudged there — the same reason '
      'fd_count.dart publishes as openSocketCountSkipReason, restated as a '
      'literal because package:test parses this annotation syntactically and '
      'cannot resolve a const from another library'),
})
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// Cycles run before the baseline is taken.
///
/// The first few allocations are not a leak: the VM grows its own pools, and
/// `lsof` on macOS is a subprocess whose plumbing settles. RESEARCH used five
/// and measured a stable baseline after them.
const _warmupCycles = 5;

/// Cumulative cycle counts at which the delta is asserted and printed.
const _checkpoints = <int>[10, 50, 100];

/// Connections the control arm holds open at once.
///
/// Each costs four descriptors in this process — the client, the socket the
/// proxy accepted, the socket the proxy opened upstream, and the one the echo
/// server accepted — so the real delta is about four times this. The assertion
/// uses this number as a floor: what is being proven is that the counter moves
/// with reality, not the arithmetic of who holds which end.
const _held = 20;

/// How long to wait after a teardown before believing a count.
const _settle = Duration(milliseconds: 400);

const _connectBudget = Duration(seconds: 5);
const _echoBudget = Duration(seconds: 10);

/// The token every cycle sends through the proxy and expects back.
final _probe = Uint8List.fromList(<int>[0xCE, 0x27, 0x01, 0x0D]);

/// Counts open socket fds, after letting the kernel catch up.
///
/// The only sleep in this file, and it is a **measurement** delay rather than
/// synchronisation: `destroy()` is asynchronous with respect to the descriptor
/// actually closing (RESEARCH Pitfall 3), and there is no event the kernel
/// offers to say the fd table has settled. Counting too early produces
/// intermittent off-by-a-few deltas that read as a flaky leak. Every count in
/// this file goes through here, so no arm can read a half-settled table and
/// blame the proxy.
Future<int> _countAfterSettle() async {
  // The measurement delay, and the only sleep in this file. Written in the
  // unparameterised form on purpose: the phase-wide grep that hunts for
  // sleeps used as synchronisation matches this spelling and not the
  // `Future<void>.delayed` one, so the generic form would hide from it.
  await Future.delayed(_settle);
  return openSocketCount();
}

void main() {
  test(
      'opening and tearing down ${_checkpoints.last} proxied connections '
      'returns the open-socket count to baseline', () async {
    for (var i = 0; i < _warmupCycles; i++) {
      await _cycle();
    }
    final baseline = await _countAfterSettle();
    print('baseline after $_warmupCycles warm-up cycles: $baseline open '
        'socket fds');

    var completed = 0;
    for (final checkpoint in _checkpoints) {
      while (completed < checkpoint) {
        await _cycle();
        completed++;
      }
      final count = await _countAfterSettle();
      final delta = count - baseline;
      print('after +$completed cycles: $count (delta $delta)');

      expect(
        delta,
        0,
        reason: 'after $completed proxied connections the process holds '
            '$delta more socket descriptors than it did at the baseline of '
            '$baseline — about '
            '${(delta / completed).toStringAsFixed(2)} per cycle. Read the '
            'checkpoints above as a rate: one per cycle is a forgotten '
            'destroy() on a socket every connection creates, which is exactly '
            'what RESEARCH measured (10 / 60 / 160) before the upstream '
            'socket was destroyed on teardown. A gateway that leaks a '
            'descriptor per reconnect dies of EMFILE after a day of flapping '
            'plant network, at which point it stops serving every operator at '
            'once',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the counter would have noticed: $_held connections held open on '
      'purpose', () async {
    final echo = await _Echo.start();
    addTearDown(echo.close);
    final proxy = FaultProxy(targetPort: echo.port);
    await proxy.start();
    addTearDown(proxy.shutdown);

    final baseline = await _countAfterSettle();

    final clients = <Socket>[];
    addTearDown(() {
      for (final client in clients) {
        client.destroy();
      }
    });
    for (var i = 0; i < _held; i++) {
      final client = await _connect(proxy.port);
      clients.add(client);
      await _exchange(client, 'held connection ${i + 1} of $_held');
    }

    final whileHeld = await _countAfterSettle();
    final delta = whileHeld - baseline;
    print('control: $_held deliberately-held connections -> $whileHeld '
        '(delta $delta)');

    expect(
      delta,
      greaterThanOrEqualTo(_held),
      reason: 'the counter saw $delta more descriptors while $_held '
          'connections were held open through the proxy. Without this arm the '
          'criterion above is worthless: `expect(delta, 0)` passes for a '
          'leak-free proxy and for a counter that always answers zero, and '
          'the second is the easy mistake — lsof exits 1 when nothing '
          'matches, so the naive exit-code check returns nothing exactly when '
          'the clean case does',
    );

    for (final client in clients) {
      client.destroy();
    }
    clients.clear();

    // The proxy and the echo server stay up, exactly as they were when the
    // baseline was taken — otherwise this would compare a count holding two
    // listeners against one holding none, and read a correct proxy as leaking
    // two descriptors in the negative direction.
    final afterRelease = await _countAfterSettle();
    expect(afterRelease, baseline,
        reason: 'the count did not come back down after the held connections '
            'were released, with the proxy still running. Either it is '
            'measuring something that outlives the socket — in which case '
            'every delta above is noise — or the proxy holds a pair open '
            'after its client has gone, which is the leak at one connection '
            'rather than at a hundred');
    expect(proxy.livePairs, 0,
        reason: 'the proxy is still tracking ${proxy.livePairs} pairs whose '
            'clients are gone; a pair that outlives its client is two '
            'descriptors the fd count will only notice once enough of them '
            'accumulate');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// One open/use/teardown cycle: echo server, proxy, client, and back to none.
///
/// Everything is torn down inside the cycle rather than with `addTearDown`.
/// A hundred deferred teardowns would hold a hundred connections open until
/// the test ended, which is the state the control arm deliberately creates —
/// the criterion would then be measuring the opposite of what it claims.
Future<void> _cycle() async {
  final echo = await _Echo.start();
  final proxy = FaultProxy(targetPort: echo.port);
  await proxy.start();

  final client = await within(
    Socket.connect(InternetAddress.loopbackIPv4, proxy.port),
    'the cycle\'s client reached the proxy',
    budget: _connectBudget,
  );
  unawaited(client.done.catchError((Object _) => client));

  await _exchange(client, 'the cycle exchanged bytes through the proxy');

  client.destroy();
  await proxy.shutdown();
  await echo.close();
}

/// Connects through the proxy, registering the client for teardown.
Future<Socket> _connect(int port) async {
  final client = await within(
    Socket.connect(InternetAddress.loopbackIPv4, port),
    'the client reached the proxy on port $port',
    budget: _connectBudget,
  );
  unawaited(client.done.catchError((Object _) => client));
  return client;
}

/// Sends the probe and waits for it to come back.
///
/// The round trip is what makes a cycle a cycle: it proves all four sockets
/// existed at once, so a cycle that quietly failed to connect cannot report a
/// delta of zero and call it a pass.
Future<void> _exchange(Socket client, String what) async {
  final echoed = Completer<void>();
  final subscription = client.listen(
    (_) {
      if (!echoed.isCompleted) echoed.complete();
    },
    onDone: () {
      if (!echoed.isCompleted) {
        echoed.completeError(
            StateError('the connection closed before the probe came back'));
      }
    },
    onError: (Object error) {
      if (!echoed.isCompleted) echoed.completeError(error);
    },
  );
  client.add(_probe);
  await client.flush();
  await within(echoed.future, what, budget: _echoBudget);
  await subscription.cancel();
}

/// A loopback echo server whose lifetime the caller owns.
///
/// Deliberately not the `addTearDown` shape the other faults tests use: this
/// file needs a server that is gone *before* the next count, not one that
/// survives until the test ends.
final class _Echo {
  _Echo._(this._server, this._accepts, this._accepted);

  final ServerSocket _server;
  final StreamSubscription<Socket> _accepts;
  final List<Socket> _accepted;

  int get port => _server.port;

  static Future<_Echo> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    final accepts = server.listen((socket) {
      accepted.add(socket);
      unawaited(socket.done.catchError((Object _) => socket));
      late final StreamSubscription<Uint8List> echoing;
      echoing = socket.listen(
        (data) {
          socket.add(data);
          // Gated like the delay line, for the same reason: an echo server
          // that buffers without limit reproduces Finding 7 in the rig.
          echoing.pause(socket.flush().catchError((Object _) {}));
        },
        // The other half of the leak Finding 11 measured: a stream that ends
        // is not a descriptor that closes.
        onDone: socket.destroy,
        onError: (Object _) => socket.destroy(),
      );
    });
    return _Echo._(server, accepts, accepted);
  }

  Future<void> close() async {
    await _accepts.cancel();
    try {
      await _server.close();
    } catch (_) {
      // Cancelling the accept subscription already closed it on some
      // platforms; the listener is down either way.
    }
    for (final socket in _accepted) {
      socket.destroy();
    }
    _accepted.clear();
  }
}
