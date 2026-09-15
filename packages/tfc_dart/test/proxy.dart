import 'dart:async';
import 'dart:io';

/// TCP proxy for testing network disruption scenarios.
///
/// Uses port 0 (OS-assigned) to avoid port conflicts between tests.
///
/// Features:
/// - [bufferServerToClient]: buffer server→client responses while still
///   forwarding client→server traffic (keeps the server-side connection alive).
/// - [reject]: destroy existing connections and reject new ones instantly.
///   The ServerSocket stays open so the client gets an immediate RST on all
///   platforms (unlike closing the socket, which causes a slow connect-timeout
///   on Windows instead of ECONNREFUSED).
class TcpProxy {
  final int listenPort;

  /// Where accepted connections are forwarded. Mutable because the database it
  /// points at is republished on a fresh host port every `docker compose up`,
  /// while this proxy's own listening socket must stay put: callers hold the
  /// listen port in a [DatabaseConfig] across restarts. Retargeting keeps one
  /// socket bound for the life of the process instead of rebinding it, which is
  /// what makes the listen port race-free (see [start]).
  int targetPort;

  ServerSocket? _server;
  final List<_Pair> _pairs = [];
  bool _rejecting = false;

  /// When true, server→client traffic is buffered (not forwarded).
  /// Client→server traffic is always forwarded (keeps the server-side
  /// subscription alive). Use [flush] to release buffered responses.
  bool bufferServerToClient = false;

  TcpProxy({this.listenPort = 0, required this.targetPort});

  /// The actual port after [start] (OS-assigned when [listenPort] is 0).
  int get port => _server!.port;

  /// Whether a listening socket is currently bound.
  bool get isBound => _server != null;

  /// Client/server socket pairs the proxy is still holding open.
  ///
  /// Every connection to Postgres in these tests is really the proxy's own
  /// upstream socket, so `pg_stat_activity` counts pairs, not client sockets.
  /// That makes this the difference between "the client never closed" and "the
  /// client closed and the proxy did not pass it on" -- two different bugs
  /// that look identical from the server.
  int get livePairs => _pairs.length;

  bool get isRunning => _server != null && !_rejecting;

  /// Binds the listening socket, once.
  ///
  /// With [listenPort] 0 this is **race-free, not merely unlikely to collide**:
  /// the kernel assigns a free port and hands back the socket already bound to
  /// it, and that same socket goes on to serve. There is no interval in which
  /// the port is known but unowned, which is the flaw in the usual
  /// bind-zero-read-close-rebind idiom -- there, anything on the machine may
  /// take the port between the close and the rebind.
  ///
  /// The early return on an existing socket is what preserves the property
  /// across a restart: repeated [start] calls never rebind, so the port a
  /// caller was given stays valid. Only [shutdown] releases it, and the fixture
  /// does that once, at process exit.
  Future<void> start() async {
    _rejecting = false;
    if (_server != null) return;
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, listenPort);
    _server!.listen(_handleConnection);
  }

  void _handleConnection(Socket clientSocket) async {
    if (_rejecting) {
      try {
        clientSocket.destroy();
      } catch (_) {}
      return;
    }
    try {
      final serverSocket = await Socket.connect(
          InternetAddress.loopbackIPv4, targetPort,
          timeout: Duration(seconds: 5));
      if (_rejecting) {
        try {
          clientSocket.destroy();
        } catch (_) {}
        try {
          serverSocket.destroy();
        } catch (_) {}
        return;
      }
      final pair = _Pair(clientSocket, serverSocket, this);
      _pairs.add(pair);
      pair.start(() => _pairs.remove(pair));
    } catch (e) {
      try {
        clientSocket.destroy();
      } catch (_) {}
    }
  }

  /// Flush all buffered server→client responses.
  void flush() {
    for (final p in _pairs) {
      p.flushBuffer();
    }
  }

  /// Reject mode: destroy existing connections and reject new ones instantly.
  /// The ServerSocket stays open so the client gets an immediate RST
  /// (not a slow connect-timeout on Windows).
  Future<void> reject() async {
    _rejecting = true;
    for (final conn in List.of(_pairs)) {
      conn.close();
    }
    _pairs.clear();
    await Future.delayed(Duration(milliseconds: 100));
    for (final conn in List.of(_pairs)) {
      conn.close();
    }
    _pairs.clear();
  }

  /// Fully shut down (for tearDown).
  Future<void> shutdown() async {
    _rejecting = true;
    final s = _server;
    _server = null;
    await s?.close();
    for (final conn in List.of(_pairs)) {
      conn.close();
    }
    _pairs.clear();
  }
}

class _Pair {
  final Socket client;
  final Socket server;
  final TcpProxy proxy;
  StreamSubscription? _clientSub;
  StreamSubscription? _serverSub;
  bool _closed = false;
  final List<List<int>> _serverBuffer = [];

  _Pair(this.client, this.server, this.proxy);

  void start(void Function() onClose) {
    client.done.catchError((_) {});
    server.done.catchError((_) {});
    _clientSub = client.listen(
      (data) {
        // Client→server always forwarded
        try {
          server.add(data);
        } catch (_) {}
      },
      onDone: () => _doClose(onClose),
      onError: (_) => _doClose(onClose),
    );
    _serverSub = server.listen(
      (data) {
        if (proxy.bufferServerToClient) {
          _serverBuffer.add(List.from(data));
        } else {
          try {
            client.add(data);
          } catch (_) {}
        }
      },
      onDone: () => _doClose(onClose),
      onError: (_) => _doClose(onClose),
    );
  }

  void flushBuffer() {
    if (_closed || _serverBuffer.isEmpty) return;
    for (final data in _serverBuffer) {
      try {
        client.add(data);
      } catch (_) {}
    }
    _serverBuffer.clear();
  }

  void _doClose(void Function() onClose) {
    if (_closed) return;
    close();
    onClose();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _clientSub?.cancel();
    _serverSub?.cancel();
    try {
      client.destroy();
    } catch (_) {}
    try {
      server.destroy();
    } catch (_) {}
  }
}
