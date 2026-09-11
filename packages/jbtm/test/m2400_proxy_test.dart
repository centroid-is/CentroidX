import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:jbtm/jbtm.dart';
import 'package:test/test.dart';

/// Number of socket descriptors this process holds whose **local** port is
/// [port] — i.e. the proxy's listen socket plus every downstream client it has
/// accepted, and nothing else.
///
/// Scoping to a port is the whole point. The first version of this test
/// counted every descriptor in the process and compared against a baseline,
/// which is not attributable to the proxy for two independent reasons:
///
///  1. `dart test` runs VM suites as isolates inside a **single process**, so
///     `/proc/self/fd` and `lsof -p $pid` also see the sockets of every other
///     suite running concurrently — `msocket_test`, `m2400_integration_test`
///     and `connection_resilience_test` are all socket-heavy and all overlap
///     with this one. (Verified: two suites report the same `pid`.)
///  2. Even alone in the process, a raw count includes handles that are not
///     sockets at all — epoll/eventfd/timerfd the VM opens lazily, the
///     descriptor `Directory.listSync` holds for the directory it is reading
///     (which takes the lowest free number, so it lands somewhere different in
///     every sample), and on macOS the pipes `Process.runSync` needs to read
///     lsof's own output.
///
/// Either one moves a whole-process count by a descriptor or two with nothing
/// leaked. That is how the original assertion failed on Linux, intermittently
/// and by exactly one — while passing on macOS, where it was written, and
/// Linux is the platform this proxy actually runs on.
///
/// Counting the proxy's own sockets is *stricter* than the process-wide
/// version, not looser: it needs no baseline and no slack, so the assertions
/// below state absolute figures — 1 while listening, 0 once shut down.
///
/// Matching is on the local port only. A downstream client's socket has the
/// proxy's port as its *remote* port, and those descriptors belong to the
/// test, not the proxy.
///
/// POSIX only — `fdLeakSkip` guards the call sites, so this is never reached
/// on Windows.
int socketsOnLocalPort(int port) {
  if (Platform.isLinux) {
    // inode -> local port, from the kernel's own socket tables.
    final localPortOf = <String, int>{};
    for (final table in const ['/proc/net/tcp', '/proc/net/tcp6']) {
      final file = File(table);
      if (!file.existsSync()) continue;
      for (final line in file.readAsLinesSync().skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 10) continue;
        final colon = fields[1].lastIndexOf(':');
        if (colon < 0) continue;
        final localPort = int.tryParse(fields[1].substring(colon + 1), radix: 16);
        if (localPort != null) localPortOf[fields[9]] = localPort;
      }
    }
    var count = 0;
    for (final entry in _fdEntries()) {
      try {
        // A socket descriptor's /proc link target is literally
        // "socket:[inode]"; everything else is a file, pipe or anon_inode.
        final target = Link(entry.path).targetSync();
        if (!target.startsWith('socket:[')) continue;
        final inode = target.substring(8, target.length - 1);
        if (localPortOf[inode] == port) count++;
      } on FileSystemException {
        // The descriptor went away between readdir and readlink — including
        // the listing's own directory descriptor. Not a socket either way.
      }
    }
    return count;
  }
  // macOS has no /proc, and listing /dev/fd races against the listing's own
  // descriptor. lsof is part of the base system and is present on the GitHub
  // macos runners. Column 4 is TYPE; the NAME column is either
  // "127.0.0.1:PORT (LISTEN)" or "127.0.0.1:LOCAL->127.0.0.1:REMOTE (STATE)".
  final result = Process.runSync('lsof', ['-nP', '-p', '$pid']);
  if (result.exitCode != 0) {
    throw StateError('lsof failed: ${result.stderr}');
  }
  return (result.stdout as String).split('\n').where((line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 9) return false;
    if (!const {'IPv4', 'IPv6'}.contains(fields[4])) return false;
    final local = fields[8].split('->').first;
    final colon = local.lastIndexOf(':');
    return colon >= 0 && int.tryParse(local.substring(colon + 1)) == port;
  }).length;
}

/// The entries of `/proc/self/fd`, as [FileSystemEntity]s that are never
/// followed.
///
/// `Directory.listSync()` does not merely hand back names. With the default
/// `followLinks: true` it resolves each entry to decide whether to return a
/// `File`, a `Directory` or a `Link` — a `stat` *through* the symlink — and
/// every name in this directory is a symlink. A descriptor closed between the
/// kernel's `readdir` and that `stat` therefore makes **the listing itself**
/// throw, not the per-entry read:
///
/// ```
/// PathNotFoundException: Directory listing failed, path = '/proc/self/fd/14'
///   test/m2400_proxy_test.dart 60:52  socketsOnLocalPort
/// ```
///
/// which is a `for`-loop header, outside the `try` in [socketsOnLocalPort]
/// that was written for exactly this race and could not see it. The window is
/// wide open here by construction: `dart test` runs every VM suite as an
/// isolate in one process, so the socket-heavy suites this file's own doc
/// comment names are opening and closing descriptors in the same table while
/// this scan walks it.
///
/// `followLinks: false` returns `Link`s without walking them, which closes the
/// race for the reported case. The retry covers the narrower one underneath
/// it — the entry vanishing before even the `lstat` that types it — and
/// rethrows rather than reporting a short count, because a scan that silently
/// returned fewer descriptors would turn a real leak into a pass.
List<FileSystemEntity> _fdEntries() {
  for (var attempt = 0;; attempt++) {
    try {
      return Directory('/proc/self/fd').listSync(followLinks: false);
    } on FileSystemException {
      if (attempt >= 4) rethrow;
    }
  }
}

/// Opens and closes descriptors as fast as it can, for as long as it is left
/// alive. Runs in its own isolate — see the test that spawns it.
///
/// Top-level and one-argument because that is what [Isolate.spawn] takes.
void _churnDescriptors(String dirPath) {
  var i = 0;
  while (true) {
    final handle =
        File('$dirPath/churn${i++ % 32}').openSync(mode: FileMode.write);
    handle.closeSync();
  }
}

/// Skip reason for descriptor-counting tests, or null when they can run.
final String? fdLeakSkip =
    Platform.isWindows ? 'no POSIX file-descriptor table on Windows' : null;

void main() {
  // TestTcpServer acts as the fake upstream M2400 device.
  late TestTcpServer upstream;

  // The proxy under test.
  late M2400Proxy proxy;

  // Track downstream sockets for cleanup.
  final downstreamSockets = <Socket>[];

  setUp(() async {
    upstream = TestTcpServer();
    await upstream.start();

    proxy = M2400Proxy(
      upstreamHost: 'localhost',
      upstreamPort: upstream.port,
      listenPort: 0, // OS-assigned
      listenAddress: InternetAddress.loopbackIPv4,
    );
  });

  tearDown(() async {
    for (final s in downstreamSockets) {
      s.destroy();
    }
    downstreamSockets.clear();
    await proxy.shutdown();
    await upstream.shutdown();
  });

  /// Connect a raw downstream client to the proxy.
  Future<Socket> connectClient(int port) async {
    final socket = await Socket.connect('localhost', port);
    downstreamSockets.add(socket);
    return socket;
  }

  /// Collect all data from a socket into a list of byte chunks.
  List<Uint8List> collectData(Socket socket) {
    final chunks = <Uint8List>[];
    socket.listen(
      (data) => chunks.add(Uint8List.fromList(data)),
      onError: (_) {},
    );
    return chunks;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------
  group('lifecycle', () {
    test('start() binds listen port and connects upstream', () async {
      await proxy.start();

      // Upstream should see the proxy connect
      await upstream.waitForClient();
      expect(upstream.clientCount, equals(1));
    });

    test('shutdown() closes all downstream clients', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(1));

      final disconnected = Completer<void>();
      client.listen((_) {}, onDone: () {
        if (!disconnected.isCompleted) disconnected.complete();
      }, onError: (_) {
        if (!disconnected.isCompleted) disconnected.complete();
      });

      await proxy.shutdown();
      await disconnected.future.timeout(const Duration(seconds: 2));
    });

    test('shutdown() is safe to call multiple times', () async {
      await proxy.start();
      await proxy.shutdown();
      await proxy.shutdown(); // should not throw
    });
  });

  // ---------------------------------------------------------------------------
  // Fan-out
  // ---------------------------------------------------------------------------
  group('fan-out', () {
    test('upstream data reaches a single downstream client', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));

      final chunks = collectData(client);
      final payload = [1, 2, 3, 4, 5];
      upstream.sendToAll(payload);

      await Future.delayed(const Duration(milliseconds: 100));
      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, equals(payload));
    });

    test('upstream data reaches multiple clients simultaneously', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client1 = await connectClient(proxy.listenPort);
      final client2 = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));

      final chunks1 = collectData(client1);
      final chunks2 = collectData(client2);

      final payload = [10, 20, 30];
      upstream.sendToAll(payload);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(chunks1.expand((c) => c).toList(), equals(payload));
      expect(chunks2.expand((c) => c).toList(), equals(payload));
    });

    test('new client receives only data sent after connection (no replay)',
        () async {
      await proxy.start();
      await upstream.waitForClient();

      // Send data before any client connects
      upstream.sendToAll([1, 2, 3]);
      await Future.delayed(const Duration(milliseconds: 50));

      // Now connect a client
      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      final chunks = collectData(client);

      // Send new data
      upstream.sendToAll([4, 5, 6]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Client should only see [4, 5, 6], not [1, 2, 3]
      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, equals([4, 5, 6]));
    });
  });

  // ---------------------------------------------------------------------------
  // Client management
  // ---------------------------------------------------------------------------
  group('client management', () {
    test('clientCount tracks connections accurately', () async {
      await proxy.start();
      await upstream.waitForClient();
      expect(proxy.clientCount, equals(0));

      await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(1));

      await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(2));
    });

    test('handles client disconnect gracefully', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client1 = await connectClient(proxy.listenPort);
      final client2 = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(2));

      // Disconnect client1
      client1.destroy();
      downstreamSockets.remove(client1);
      // Wait for the server-side done handler to fire
      await Future.delayed(const Duration(milliseconds: 300));
      expect(proxy.clientCount, equals(1));

      // client2 should still receive data
      final chunks = collectData(client2);
      upstream.sendToAll([7, 8, 9]);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(chunks.expand((c) => c).toList(), equals([7, 8, 9]));
    });
  });

  // ---------------------------------------------------------------------------
  // Network loss — upstream
  // ---------------------------------------------------------------------------
  group('upstream network loss', () {
    test('downstream clients stay connected when upstream disconnects',
        () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));

      // Simulate upstream device reboot
      upstream.disconnectAll();
      await Future.delayed(const Duration(milliseconds: 200));

      // Client should still be connected (proxy doesn't drop clients on
      // upstream loss)
      expect(proxy.clientCount, equals(1));

      // Verify client socket is still writable (not errored)
      expect(() => client.add([0]), returnsNormally);
    });

    test('data resumes flowing after upstream reconnects', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      final chunks = collectData(client);

      // Send initial data
      upstream.sendToAll([1, 2, 3]);
      await Future.delayed(const Duration(milliseconds: 50));

      // Disconnect upstream
      upstream.disconnectAll();
      await Future.delayed(const Duration(milliseconds: 200));

      // MSocket will auto-reconnect — wait for it
      await upstream.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Send data on the new upstream connection
      upstream.sendToAll([4, 5, 6]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Client should have received both payloads
      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, containsAllInOrder([1, 2, 3]));
      expect(allBytes, containsAllInOrder([4, 5, 6]));
    });

    test('proxy stays up when upstream never connects', () async {
      // Create proxy pointing at a port nothing is listening on
      final nowhereProxy = M2400Proxy(
        upstreamHost: 'localhost',
        upstreamPort: 59999, // nothing here
        listenPort: 0,
        listenAddress: InternetAddress.loopbackIPv4,
      );

      await nowhereProxy.start();

      // Clients can still connect to the proxy
      final client =
          await Socket.connect('localhost', nowhereProxy.listenPort);
      downstreamSockets.add(client);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(nowhereProxy.clientCount, equals(1));

      await nowhereProxy.shutdown();
    });
  });

  // ---------------------------------------------------------------------------
  // Network loss — downstream
  // ---------------------------------------------------------------------------
  group('downstream network loss', () {
    test('abrupt client disconnect handled without error', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(1));

      // Abrupt disconnect
      client.destroy();
      downstreamSockets.remove(client);

      // Send data — proxy should handle the dead client without crashing
      upstream.sendToAll([1, 2, 3]);
      await Future.delayed(const Duration(milliseconds: 100));

      // No crash, clientCount updated
      expect(proxy.clientCount, equals(0));
    });

    test('all clients disconnect, proxy continues', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client1 = await connectClient(proxy.listenPort);
      final client2 = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));

      client1.destroy();
      client2.destroy();
      downstreamSockets.clear();
      // Wait for the server-side done handlers to fire
      await Future.delayed(const Duration(milliseconds: 300));

      expect(proxy.clientCount, equals(0));

      // New client can still connect
      await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(1));
    });

    test('client connects during upstream disconnect, receives data on recovery',
        () async {
      await proxy.start();
      await upstream.waitForClient();

      // Disconnect upstream
      upstream.disconnectAll();
      await Future.delayed(const Duration(milliseconds: 100));

      // Client connects while upstream is down
      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      final chunks = collectData(client);

      expect(proxy.clientCount, equals(1));

      // Wait for upstream to reconnect
      await upstream.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Send data on the new upstream connection
      upstream.sendToAll([10, 20, 30]);
      await Future.delayed(const Duration(milliseconds: 100));

      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, equals([10, 20, 30]));
    });
  });

  // ---------------------------------------------------------------------------
  // Packet fragmentation / chunking
  // ---------------------------------------------------------------------------
  group('packet handling', () {
    test('large payload forwarded correctly', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      final chunks = collectData(client);

      // Send a large payload (64KB)
      final bigPayload = List<int>.generate(65536, (i) => i % 256);
      upstream.sendToAll(bigPayload);

      // Wait enough for all data to arrive
      await Future.delayed(const Duration(milliseconds: 500));

      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, equals(bigPayload));
    });

    test('rapid burst of small packets all forwarded', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      final chunks = collectData(client);

      // Send 100 tiny packets rapidly
      for (var i = 0; i < 100; i++) {
        upstream.sendToAll([i]);
      }

      await Future.delayed(const Duration(milliseconds: 500));

      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, hasLength(100));
      for (var i = 0; i < 100; i++) {
        expect(allBytes[i], equals(i));
      }
    });

    test('partial M2400 frames forwarded transparently', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      final chunks = collectData(client);

      // Send a partial frame (STX but no ETX) — proxy shouldn't care
      final partialFrame = [0x02, 0x41, 0x42, 0x43]; // STX + "ABC"
      upstream.sendToAll(partialFrame);

      await Future.delayed(const Duration(milliseconds: 100));

      // Then send the rest
      final rest = [0x44, 0x45, 0x03]; // "DE" + ETX
      upstream.sendToAll(rest);

      await Future.delayed(const Duration(milliseconds: 100));

      final allBytes = chunks.expand((c) => c).toList();
      expect(allBytes, equals([...partialFrame, ...rest]));
    });
  });

  // ---------------------------------------------------------------------------
  // Stress / edge cases
  // ---------------------------------------------------------------------------
  group('edge cases', () {
    test('client connects and immediately disconnects', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      client.destroy();
      downstreamSockets.remove(client);

      // Send data — should not crash
      await Future.delayed(const Duration(milliseconds: 100));
      upstream.sendToAll([1, 2, 3]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Proxy still operational
      expect(proxy.clientCount, equals(0));
    });

    test('multiple clients connect simultaneously', () async {
      await proxy.start();
      await upstream.waitForClient();

      // Connect 10 clients at once
      final futures = List.generate(
        10,
        (_) => connectClient(proxy.listenPort),
      );
      await Future.wait(futures);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(proxy.clientCount, equals(10));

      // All should receive data
      final allChunks = <List<Uint8List>>[];
      for (final client in downstreamSockets) {
        allChunks.add(collectData(client));
      }

      upstream.sendToAll([42]);
      await Future.delayed(const Duration(milliseconds: 100));

      for (final chunks in allChunks) {
        final bytes = chunks.expand((c) => c).toList();
        expect(bytes, equals([42]));
      }
    });

    test('shutdown during active data flow', () async {
      await proxy.start();
      await upstream.waitForClient();

      await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));

      // Start sending data and immediately shutdown — should not crash
      upstream.sendToAll([1, 2, 3]);
      await proxy.shutdown();
      // If we get here without exception, the test passes
    });
  });

  // ---------------------------------------------------------------------------
  // Descriptor lifetime
  //
  // Every other downstream-disconnect test above uses `client.destroy()` — an
  // abrupt RST, which self-cleans. The *graceful* path (peer sends FIN, i.e.
  // `close()`) is what the docker healthcheck in docker/weigher-proxy does
  // every 30s, and it closes only the read half. dart:io frees the descriptor
  // when both halves are shut, and Socket carries no NativeFinalizer, so an
  // unreachable Socket the proxy simply dropped from `_clients` keeps its
  // descriptor for the life of the process.
  // ---------------------------------------------------------------------------
  group('descriptor lifetime', () {
    test('graceful client close makes the proxy close its half too', () async {
      await proxy.start();
      await upstream.waitForClient();

      final client = await connectClient(proxy.listenPort);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(proxy.clientCount, equals(1));

      // The proxy closing its side surfaces on this client as either a FIN
      // (done) or an RST (error) depending on timing; both mean the peer
      // descriptor is gone.
      final peerClosed = Completer<void>();
      void signal() {
        if (!peerClosed.isCompleted) peerClosed.complete();
      }

      client.listen((_) {}, onDone: signal, onError: (_) => signal());

      // Half-close: shut the write side only, exactly like
      // `exec 3<>/dev/tcp/host/port` returning in the healthcheck.
      unawaited(client.close());

      await peerClosed.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail(
          'proxy never closed its half of a gracefully-closed client — '
          'the accepted socket (and its descriptor) is leaked',
        ),
      );
      expect(proxy.clientCount, equals(0));
    });

    test('repeated graceful connect/close cycles return fds to baseline',
        () async {
      await proxy.start();
      await upstream.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      const cycles = 60;
      final listenPort = proxy.listenPort;
      // Just the listen socket: no client is connected yet.
      expect(socketsOnLocalPort(listenPort), equals(1));

      for (var i = 0; i < cycles; i++) {
        final client = await Socket.connect(
          InternetAddress.loopbackIPv4,
          proxy.listenPort,
        );
        client.listen((_) {}, onError: (_) {});
        // Graceful close, then release this side entirely so the only
        // descriptor a growing count can be attributed to is the proxy's.
        unawaited(client.close());
        client.destroy();
        await Future.delayed(const Duration(milliseconds: 2));
      }

      await Future.delayed(const Duration(milliseconds: 300));

      expect(proxy.clientCount, equals(0));

      // No baseline, no slack: the proxy is listening and has no clients, so
      // it must hold exactly the one listen socket — the same figure as
      // before the churn. Every peer it accepted has to be gone. (A socket in
      // TIME_WAIT is a kernel table entry, not a descriptor, so it does not
      // appear here.) The leak this test was written for is 1:1 with the
      // cycle count, but an off-by-one leak is just as real, and scoping the
      // count to the proxy's own port is what makes it safe to say so.
      final after = socketsOnLocalPort(listenPort);
      expect(
        after,
        equals(1),
        reason: 'the proxy holds $after sockets on its listen port after '
            '$cycles graceful connect/close cycles; it should hold only the '
            'listen socket, so ${after - 1} accepted peers were leaked',
      );
    }, skip: fdLeakSkip);

    test('shutdown() leaves no descriptors behind after graceful churn',
        () async {
      await proxy.start();
      await upstream.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      final listenPort = proxy.listenPort;
      expect(socketsOnLocalPort(listenPort), equals(1));

      for (var i = 0; i < 30; i++) {
        final client = await Socket.connect(
          InternetAddress.loopbackIPv4,
          proxy.listenPort,
        );
        client.listen((_) {}, onError: (_) {});
        unawaited(client.close());
        client.destroy();
        await Future.delayed(const Duration(milliseconds: 2));
      }

      await proxy.shutdown();
      await Future.delayed(const Duration(milliseconds: 300));

      // shutdown() only walks `_clients`; anything already dropped from that
      // list is unreachable and cannot be reclaimed here. So every peer the
      // churn accepted has to have been released as it disconnected, and
      // shutdown must then close the listen socket itself: zero, exactly.
      //
      // Naming that figure, rather than asserting a slack-carrying "no worse
      // than before", is the point — "no worse" still passes with the listen
      // socket left open.
      final after = socketsOnLocalPort(listenPort);
      expect(
        after,
        isZero,
        reason: 'shutdown() left $after sockets open on the proxy listen '
            'port; it must close the listen socket and every peer the churn '
            'accepted',
      );
    }, skip: fdLeakSkip);

    test('the descriptor scan survives descriptors closing underneath it',
        () async {
      // The scan is the measuring instrument for the two tests above, and it
      // used to be able to throw instead of measuring — `dart test` runs every
      // VM suite as an isolate in one process, so the socket-heavy suites are
      // churning this descriptor table while the scan walks it, and an entry
      // that vanished between readdir and the stat took the whole listing
      // down. It failed CI on '/proc/self/fd/14'.
      //
      // Reproduced here by doing the churning deliberately: a burst of files
      // opened and closed on every iteration, while the scan runs against a
      // port nothing is listening on. The assertion is only "it did not
      // throw" — the count is not the subject.
      await proxy.start();
      final listenPort = proxy.listenPort;

      // The churn has to come from **another isolate**, not a future in this
      // one. `socketsOnLocalPort` is synchronous from listing to last
      // readlink, so nothing scheduled on this isolate's event loop can run
      // part-way through it — a first attempt at this test closed its
      // descriptors from an unawaited `Future` and raced nothing at all,
      // because every round completed before the future was allowed to start.
      // Isolates get their own thread and share the process descriptor table,
      // which is exactly the arrangement that produces the failure in CI.
      final scratch =
          Directory.systemTemp.createTempSync('jbtm_fd_scan_race_test');
      addTearDown(() => scratch.deleteSync(recursive: true));

      final churn = await Isolate.spawn(_churnDescriptors, scratch.path);
      addTearDown(() => churn.kill(priority: Isolate.immediate));

      var scans = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        // The count is not the subject — surviving the walk is. Anything the
        // scan reports is fine; throwing is not.
        expect(socketsOnLocalPort(listenPort), isNonNegative);
        scans++;
      }

      // Guards the guard: a scan that had somehow become a no-op would sail
      // through the loop above without ever walking the table.
      expect(scans, greaterThan(20),
          reason: 'only $scans scans completed in 2s — too few to have raced '
              'the churning isolate');
      // Linux only, not `fdLeakSkip`. The race being guarded is specific to
      // walking `/proc/self/fd`; the macOS branch shells out to `lsof`, which
      // reports a snapshot taken in another process and cannot trip over a
      // descriptor closing here. Running it there would spawn `lsof` for two
      // solid seconds and then judge the result on how many spawns fitted.
    }, skip: Platform.isLinux ? null : 'the /proc descriptor scan is Linux-only');
  });
}
