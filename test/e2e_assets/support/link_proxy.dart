/// A loopback TCP proxy with one lever: stop forwarding, keep the connection.
///
/// **Why this is not `FaultProxy`.** `tfc_stateman_contract` has the real
/// thing — twelve levers, a fault-mode registry, a measured byte budget — and
/// this lane wanted to import it. It cannot: that package carries
/// `package:test` as a real dependency, and `test` pins a `matcher` and a
/// `test_api` that the `flutter_test` SDK pin refuses. `flutter pub get` said
/// so in one line on 2026-09-20 ("flutter_test from sdk is incompatible with
/// tfc_stateman_contract from path"), and the contract package's own pubspec
/// predicts it ("putting test there would drag analyzer into the app's
/// version solve — which has blocked this repo twice in twelve months").
///
/// So this is `FaultProxy.blackhole()` and nothing else, written to the same
/// contract that lever documents (`fault_proxy.dart:560-597`):
///
///  * **Read the bytes and drop them, in both directions.** Not a paused read
///    subscription — that stalls the sender inside one socket buffer, which is
///    backpressure, a different fault with different client-side code paths.
///    The client keeps writing happily into nothing, which is what a half-open
///    link through a sleeping NAT looks like and what the rig produced with an
///    iptables DROP.
///  * **Dropped bytes are lost, not replayed.** Recovery that flushed what had
///    been swallowed would deliver a value from before the outage to a panel
///    that had just recovered, with nothing marking its age — the one outcome
///    the core value forbids.
///  * **The connection survives.** A half-open that required a reconnect to
///    end would not be one. Pairs accepted while the lever is down are
///    swallowed too, so a client that gives up and redials meets the same
///    silence until the lever is lifted.
library;

import 'dart:async';
import 'dart:io';

/// Forwards loopback TCP to [targetPort] until told to swallow it.
final class LinkProxy {
  LinkProxy({required this.targetPort});

  /// The gateway's port, on loopback.
  final int targetPort;

  ServerSocket? _server;
  final List<_Pair> _pairs = <_Pair>[];
  bool _blackholed = false;
  bool _shutDown = false;

  /// The port a panel dials. OS-assigned — a literal collides with the
  /// neighbouring worktree the moment two of these run at once.
  int get port {
    final server = _server;
    if (server == null) {
      throw StateError('the proxy has no port until start() has completed');
    }
    return server.port;
  }

  /// Whether bytes are currently being swallowed.
  bool get isBlackholed => _blackholed;

  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((client) async {
      final Socket upstream;
      try {
        upstream =
            await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
      } on Object {
        // The gateway is gone. A refused dial is the honest answer to the
        // panel, and it is the same answer it would get without a proxy.
        client.destroy();
        return;
      }
      if (_shutDown) {
        client.destroy();
        upstream.destroy();
        return;
      }
      final pair = _Pair(client, upstream, () => _blackholed);
      _pairs.add(pair);
      unawaited(pair.done.then((_) => _pairs.remove(pair)));
    });
  }

  /// Swallows every byte in both directions while [enabled], on every open
  /// pair and every pair accepted afterwards. `blackhole(enabled: false)` is
  /// the recovery, so the on and off states cannot drift apart.
  void blackhole({bool enabled = true}) {
    _blackholed = enabled;
  }

  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    await _server?.close();
    for (final pair in List<_Pair>.of(_pairs)) {
      pair.close();
    }
  }
}

/// One accepted connection and its upstream twin.
class _Pair {
  _Pair(this._client, this._upstream, this._swallowing) {
    _pipe(_client, _upstream);
    _pipe(_upstream, _client);
  }

  final Socket _client;
  final Socket _upstream;
  final bool Function() _swallowing;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  Future<void> get done => _done.future;

  void _pipe(Socket from, Socket to) {
    from.listen(
      (bytes) {
        // Consumed, so the sender's write completes and its buffer drains —
        // and then dropped on the floor. See the library doc for why that and
        // not a pause.
        if (_swallowing()) return;
        if (_closed) return;
        to.add(bytes);
      },
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.destroy();
    _upstream.destroy();
    _done.complete();
  }
}
