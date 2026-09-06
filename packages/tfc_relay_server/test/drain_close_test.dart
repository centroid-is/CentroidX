/// The close code a deliberate shutdown leaves behind (rig probe P9).
///
/// **1006 is what a panel sees when the network breaks.** If a planned restart
/// also produces 1006, then the one event an operator's screen should describe
/// as "back in a moment" is indistinguishable from the one it should describe
/// as "the plant link is down" — and the reconnect logic has no way to tell
/// them apart either. 4002 is the code this project reserves for it
/// (`CloseCodes.serverDraining`; 4000–4999 is the only range `dart-lang/http`
/// #1690 leaves usable), and `RelayServer.close()` has sent it since 03-11.
///
/// The backend does not call `close()` and must not: `bin/main.dart`'s shutdown
/// kills the acquisition workers and calls `exit(0)` without awaiting anything,
/// because an awaited OPC UA teardown has been measured at 5.76 s and a
/// container that slow gets SIGKILLed mid-write. So the question this file
/// answers is narrow and empirical: **what can be put on the wire by a process
/// that is about to exit, without awaiting a teardown?**
///
/// Two of the three arms are subprocess arms, and they are the point. A test
/// cannot call `exit(0)`, so the race between "the close frame is queued" and
/// "the process is gone" only exists in a real second process — which is
/// exactly the race the rig lost.
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/certs.dart';
import 'support/ws_harness.dart';

/// How the client's socket ended, after a gateway in its own process was
/// SIGTERMed in [mode].
final class _DrainRun {
  const _DrainRun(this.closeCode, this.closeReason, this.exitCode);

  final int? closeCode;
  final String? closeReason;
  final int exitCode;

  @override
  String toString() =>
      '_DrainRun($closeCode, "$closeReason", exit $exitCode)';
}

/// Spawns `support/drain_fixture.dart` in [mode], connects one client, SIGTERMs
/// it, and reports what the client's socket observed.
///
/// [tls] is the whole of rig probe P9's second run. The plant dials `wss://`
/// and nothing else does; a fixture that only ever measured `ws://` on loopback
/// is what let a fix that delivers 1006 in every real deployment go green in
/// CI. Set it and the child binds a real `SecurityContext` from minted PEMs and
/// the client dials through a pinned `HttpClient`, so the close frame has to
/// survive `SecureSocket`'s write path — which is the discriminator the rig
/// isolated (TLS off -> 4002, TLS on -> 1006, same image, same fix).
Future<_DrainRun> _run(String mode, {bool tls = false}) async {
  final certArgs = <String>[];
  String? rootPem;
  if (tls) {
    final ca = mintCa();
    final mounted = writeCertFixture(
      chainPem: mintLeaf(ca: ca),
      keyPem: leafKeyPem(),
      rootPem: ca.certPem,
    );
    certArgs.addAll(<String>[mounted.chainPath, mounted.keyPath]);
    rootPem = ca.certPem;
  }
  final child = await Process.start(
    Platform.resolvedExecutable,
    <String>['run', 'test/support/drain_fixture.dart', mode, ...certArgs],
  );
  addTearDown(() => child.kill(ProcessSignal.sigkill));

  final listening = Completer<int>();
  child.stdout.transform(const SystemEncoding().decoder).listen((chunk) {
    final match = RegExp(r'listening (\d+)').firstMatch(chunk);
    if (match != null && !listening.isCompleted) {
      listening.complete(int.parse(match.group(1)!));
    }
  });
  // Kept, not discarded: a fixture that fails to compile writes here, and a
  // silent timeout thirty seconds later would name the wrong thing.
  final errors = StringBuffer();
  child.stderr.transform(const SystemEncoding().decoder).listen(errors.write);

  final port = await listening.future.timeout(
    const Duration(seconds: 90),
    onTimeout: () => fail('the drain fixture never bound a port. stderr:\n'
        '$errors'),
  );

  final WebSocketChannel ws;
  if (rootPem != null) {
    // The panel's posture: the private root and nothing else. `localhost`
    // rather than the literal because the minted leaf carries both SANs and a
    // named dial is what the plant's panels do.
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(rootPem.codeUnits);
    final client = HttpClient(context: context);
    addTearDown(() => client.close(force: true));
    ws = IOWebSocketChannel.connect(Uri.parse('wss://localhost:$port/'),
        customClient: client, connectTimeout: const Duration(seconds: 10));
  } else {
    ws = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/'));
  }
  await ws.ready;
  final done = Completer<void>();
  ws.stream.listen((_) {}, onError: (Object _) {}, onDone: () {
    if (!done.isCompleted) done.complete();
  });

  child.kill(ProcessSignal.sigterm);
  await done.future.timeout(const Duration(seconds: 10),
      onTimeout: () => fail('the client socket never ended after SIGTERM'));
  final exitCode = await child.exitCode.timeout(const Duration(seconds: 10),
      onTimeout: () => fail('the fixture never exited after SIGTERM'));

  return _DrainRun(ws.closeCode, ws.closeReason, exitCode);
}

void main() {
  group('a deliberate shutdown says so on the wire', () {
    test('the shipped shape: the panel is told 4002 "server draining"',
        () async {
      final run = await _run('announce');

      expect(run.closeCode, CloseCodes.serverDraining,
          reason: 'this is rig probe P9. A restart that closes 1006 is a '
              'restart the panel reports as a broken network, and the '
              'operator is told the plant link is down when nothing is wrong '
              'with it');
      expect(run.closeReason, 'server draining',
          reason: 'the reason is what an engineer reads in a panel log at '
              'three in the morning; an empty one makes the code a number to '
              'go and look up');
      expect(run.exitCode, 0,
          reason: 'the drain must not change how the process ends');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the control: exiting on the signal is the 1006 the rig measured',
        () async {
      final run = await _run('bare');

      expect(run.closeCode, 1006,
          reason: 'if this ever stops being 1006 the arm above proves '
              'nothing — it would be passing because everything passes');
      expect(run.closeReason, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        'a synchronous close followed by exit(0) in the SAME turn delivers '
        'nothing: measured, and it is why the shipped shape yields a turn',
        () async {
      final run = await _run('sync');

      expect(run.closeCode, 1006,
          reason: 'THE measurement behind the design. `sink.close(4002, …)` '
              'looks synchronous and is not: the frame is handed to a '
              'controller the socket consumer drains on a later turn of the '
              'event loop, so a process that exits in the same turn puts no '
              'byte of it on the wire. A "best-effort synchronous close" here '
              'would be indistinguishable from doing nothing at all. '
              'If this arm ever goes red with 4002, dart:io started flushing '
              'and the Timer in `bin/main.dart`\'s shutdown can be deleted');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('over wss, which is the only scheme the plant dials', () {
    test('the panel is told 4002 "server draining" over TLS too', () async {
      final run = await _run('announce', tls: true);

      expect(run.closeCode, CloseCodes.serverDraining,
          reason: 'rig probe P9, second run. The `announce` arm above passes '
              'over plaintext loopback and the SAME image delivered 1006 over '
              'wss on the rig — the container even logged that it had told the '
              'panels 4002. TLS is the discriminator: the frame has to get '
              'through SecureSocket\'s write path, and a deferral that is '
              'enough for a plain socket is not enough for that. Every panel '
              'in the plant is on wss, so a green suite without this arm is a '
              'suite that cannot see the defect at all');
      expect(run.closeReason, 'server draining');
      expect(run.exitCode, 0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the control: exiting on the signal is 1006 over TLS as well',
        () async {
      final run = await _run('bare', tls: true);

      expect(run.closeCode, 1006,
          reason: 'anti-vacuity for the arm above. If a TLS teardown produced '
              '4002 on its own — a close_notify the client reported as a '
              'protocol close, say — then the arm above would pass without the '
              'gateway sending anything');
      expect(run.closeReason, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('announceDraining, in process', () {
    test('is synchronous and the close frame is on the wire one turn later',
        () async {
      final f = relayFixture();
      await f.ready;

      // No `await`, and the call returns nothing to await: a shutdown path
      // that had to wait for this would be the 5.76 s stall wearing a new
      // name.
      f.server.announceDraining();

      final closed = await f.awaitClose('the drained client socket');
      expect(closed.closeCode, CloseCodes.serverDraining);
      expect(closed.closeReason, 'server draining');
    });

    test('a connection accepted while draining gets the same code, not a '
        'session', () async {
      final f = relayFixture();
      await f.ready;
      f.server.announceDraining();

      final late = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${f.server.port}/'));
      await late.ready;
      final ended = Completer<void>();
      late.stream.listen((_) {}, onError: (Object _) {}, onDone: () {
        if (!ended.isCompleted) ended.complete();
      });
      await ended.future.timeout(const Duration(seconds: 5));

      expect(late.closeCode, CloseCodes.serverDraining,
          reason: 'from the panel\'s side a connection refused during the '
              'drain is the same event as one dropped by it: this gateway is '
              'going away, reconnect rather than alarm');
    });

    test('it does not stand in for close(): the listener and the sessions are '
        'still the server\'s to release', () async {
      final f = relayFixture();
      await f.ready;

      f.server.announceDraining();
      await f.awaitClose('the drained client socket');
      // The real teardown still has to work afterwards — the fixture calls it,
      // and every socket case in this package would leak a port if a drain
      // short-circuited it.
      await f.server.close();

      expect(f.server.sessions.sessionCount, 0);
    });
  });
}
