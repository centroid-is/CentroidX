/// A gateway in its own process, so a SIGTERM and an `exit(0)` are real.
///
/// `drain_close_test.dart` spawns this. It exists because the property under
/// test is **what reaches the wire before the process is gone**, and no
/// in-process fixture can measure that: a test cannot call `exit(0)`, and a
/// server that is merely closed politely delivers its close frame every time.
/// The rig measured the opposite (13-RIG-PROBE-EVIDENCE.md, probe P9): a
/// `docker stop` on `centroidx-backend` disconnected every panel with **1006
/// and an empty reason**, so a panel could not tell a deliberate restart from a
/// broken network.
///
/// The three modes are the three candidate shutdowns, and each one is a
/// measurement rather than a fixture detail:
///
///  * `bare` — `exit(0)` on the signal. What `bin/main.dart` did when the rig
///    was probed. The control: it must produce 1006.
///  * `sync` — close every socket with 4002 and `exit(0)` in the same turn of
///    the event loop. The "best-effort synchronous close" that looks like it
///    should work. It must ALSO produce 1006: `sink.close` hands the frame to
///    a `StreamController` the socket consumer drains on a later turn, so a
///    process that exits first never puts a byte of it on the wire.
///  * `oneturn` — `announceDraining()` and then `exit(0)` on the *next* turn.
///    What 13-13 shipped. It delivers 4002 over plaintext and 1006 over TLS,
///    which is exactly the rig's second run: the fix ran, the log said so, and
///    every panel still saw a broken network.
///  * `announce` — `announceDraining()` and then `RelayServer.settleDrain()`
///    before `exit(0)`: a bounded count of event-loop turns, no clock. The
///    shipped shape, and the only one of the four that delivers 4002 over the
///    scheme the plant actually dials.
///
/// Every mode kills first and announces second, mirroring `bin/main.dart`:
/// Phase 12's law is that the acquisition workers die synchronously on the
/// signal and nothing awaits a graceful teardown.
library;

import 'dart:async';
import 'dart:io';

import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/tls/tls_config.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'permissive_resolver.dart';

/// args: `<mode> [chainPath keyPath]` — mode is one of `bare`, `sync`,
/// `announce`.
///
/// The optional certificate pair is what makes this fixture able to answer the
/// question the rig asked. With it the gateway binds `wss://` and the close
/// frame has to travel through `SecureSocket`, which is the only configuration
/// the defect reproduces in: a plaintext loopback socket accepts the frame in
/// the same round it is written, and a TLS one does not.
Future<void> main(List<String> args) async {
  final mode = args.first;
  final tls = args.length > 1
      ? TlsConfig(chainPath: args[1], keyPath: args[2])
      : null;

  final served = FakeStateMan();
  final server = RelayServer(
    api: served,
    resolver: const PermissiveSeriesResolver(),
    config: ServerConfig(tick: ServerConfig.minTick, port: 0, tls: tls),
    onError: (_, __, ___) {},
  );

  ProcessSignal.sigterm.watch().listen((_) {
    switch (mode) {
      case 'bare':
        exit(0);
      case 'sync':
        server.announceDraining();
        exit(0);
      case 'oneturn':
        server.announceDraining();
        // The shape that shipped from 13-13 and lost on the rig. Kept as a
        // mode so the defect stays measurable: over plaintext it delivers,
        // over TLS it does not.
        Timer(Duration.zero, () => exit(0));
      case 'announce':
        server.announceDraining();
        // The turn budget, not a clock. See `RelayServer.drainTurns`.
        unawaited(RelayServer.settleDrain().then((_) => exit(0)));
    }
  });

  await server.start();
  // The handshake the parent waits on. Flushed by the newline; nothing else is
  // ever written to stdout, so a parent matching on this line cannot match a
  // log message instead.
  stdout.writeln('listening ${server.port}');
}
