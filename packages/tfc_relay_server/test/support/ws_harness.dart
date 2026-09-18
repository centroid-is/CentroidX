/// Two legs over a real WebSocket, and one rule they share.
///
/// [relayFixture] is the **production** leg: the real [RelayServer], a raw
/// client socket, and a `FakeStateMan` behind the server so a case can drive
/// the plant and watch what a client sees. Every case in this phase that needs
/// a port is built on it.
///
/// [wsServedFake] is the **contract** leg: a `ServedStateMan` and a
/// `ChannelStateMan` on either end of a real WebSocket, with no relay session
/// between them. It exists to prove the transport — which is what makes
/// running the shared 44-check suite over WS (03-06) mean anything — and its
/// defaults are copied from `channelServedFake` and `socketServedFake`
/// verbatim. That copying is deliberate and is called out at each argument:
/// the parity sweep runs one registry through all three legs, so a defaults
/// difference between them reads as a *transport* difference and sends someone
/// looking for a bug in the socket layer that is really a `staleAfter` of
/// 300 ms against one of 500 (`socket_harness.dart:137-145`).
///
/// **Nothing here throws out of the wiring.** A failure while binding,
/// proxying or connecting is delivered to the thing the case is awaiting — the
/// client's channel for the contract leg, the `ready` future for the
/// production one — because an exception raised from a listener callback lands
/// in the ambient isolate and `package:test` attributes it to whichever case
/// is running when it arrives.
library;

import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart'
    show AuditSink, AuthProvider, NullAuditSink;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart'
    show UserResolver;
import 'package:tfc_relay_server/src/error_reporter.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/relay_session.dart'
    show AccessScopeFactory;
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'permissive_resolver.dart';

/// How long the served end has to appear after the client's connect returns.
///
/// `socket_harness.dart`'s `_acceptBudget`, same value: generous, because it
/// is a *wiring* budget and not a measurement. What it protects against is a
/// harness that hangs forever when the accept never happens.
const _acceptBudget = Duration(seconds: 5);

/// The config every fixture runs on unless a case says otherwise.
///
/// The tick is the fastest the band allows (`ServerConfig.minTick`, 50 ms)
/// because in this wave the tick is also the *response* pump: an RPC answer
/// sits in the send buffer until the next drain, so a slower tick would make
/// every request budget in every WS case a measurement of the tick. 03-07
/// keeps the same pacing for telemetry; nothing here depends on the value
/// beyond it being small.
ServerConfig fixtureConfig() => ServerConfig(tick: ServerConfig.minTick);

/// The `hello` params a case sends when it does not care about the details.
Map<String, Object?> helloParams({List<String>? supported}) => HelloParams(
      protocol: supported?.first ?? protocolVersion,
      supported: supported ?? const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
    ).toJson();

/// The close a *client* observed, which is the only close worth asserting on
/// for a close the server initiated (`web_socket_channel` #1698).
/// Named for the fields it carries rather than for their shorter forms, so a
/// case that asserts on one says `closeCode` in the source — which is what the
/// phase's own grep for "does this file assert a close code, and whose?" reads.
final class ClientClose {
  const ClientClose(this.closeCode, this.closeReason);

  /// The code the client's socket observed. Null while the socket is open.
  final int? closeCode;

  /// The reason the client's socket observed.
  final String? closeReason;

  @override
  String toString() =>
      'ClientClose($closeCode, ${closeReason ?? '<no reason>'})';
}

// ---------------------------------------------------------------------------
// The production leg.
// ---------------------------------------------------------------------------

/// A real [RelayServer], a raw client socket, and the plant behind the server.
final class RelayFixture {
  RelayFixture._(this.served, this.server, this._wiring, this.ready);

  /// The reference implementation the server is serving. Driveable directly,
  /// which is what lets a case apply a lever the client cannot see the result
  /// of.
  final FakeStateMan served;

  /// The server under test.
  final RelayServer server;

  final _RelayWiring _wiring;

  /// Completes when the client is connected *and* the server has registered
  /// its session — not merely when the socket opened.
  ///
  /// The distinction matters: a case that asserted `sessionCount` after only
  /// the connect would be racing the accept, and a case that tore down there
  /// would orphan a session the server was still building.
  final Future<void> ready;

  /// The raw client socket. Available once [ready] has completed.
  WebSocketChannel get client => _wiring.client;

  /// The fault proxy in front of the server, when one was asked for.
  FaultProxy get proxy => _wiring.requireProxy();

  /// Every frame the client has received, in order. For a case that wants to
  /// assert on notifications rather than on answers.
  List<String> get inbound => List.unmodifiable(_wiring.inbound);

  /// The close the client has observed so far — both fields null while the
  /// socket is open.
  ClientClose get observedClose =>
      ClientClose(_wiring.client.closeCode, _wiring.client.closeReason);

  /// Sends [method] and returns its result inside a named budget.
  Future<Object?> request(String method,
          {Object? params,
          String? what,
          Duration budget = const Duration(seconds: 1)}) =>
      within(_wiring.peer.sendRequest(method, params),
          what ?? 'a $method response over a real socket',
          budget: budget);

  /// Says hello and returns the negotiated result.
  Future<HelloResult> hello(
      {List<String>? supported,
      Duration budget = const Duration(seconds: 1)}) async {
    final raw = await request(Methods.hello,
        params: helloParams(supported: supported),
        what: 'the hello result over a real socket',
        budget: budget);
    return HelloResult.fromJson((raw as Map).cast<String, Object?>());
  }

  /// Sends [method] expecting a refusal, and hands back the refusal.
  ///
  /// A method that is *answered* fails the case here rather than at a
  /// downstream matcher, so the report names the property instead of the
  /// assertion that tripped over it (`session_hello_test.dart:85-94`).
  Future<rpc.RpcException> refusal(String method,
      {Object? params,
      required String what,
      Duration budget = const Duration(seconds: 1)}) async {
    try {
      await request(method, params: params, what: what, budget: budget);
    } on rpc.RpcException catch (error) {
      return error;
    }
    fail('$what was answered instead of refused');
  }

  /// Completes when the client's socket has finished, then reports the close
  /// it observed.
  Future<ClientClose> awaitClose(String what,
      {Duration budget = const Duration(seconds: 1)}) async {
    await within(_wiring.socketDone, what, budget: budget);
    // `closeCode` is populated by the same event that ends the stream, but
    // that ordering is the socket implementation's business rather than a
    // documented contract. One turn of the event queue costs nothing and
    // removes the only way this helper could report a null it did not mean.
    if (_wiring.client.closeCode == null) await pumpEventQueue(times: 1);
    return observedClose;
  }

  /// Completes when the server is holding no sessions.
  ///
  /// Event-driven rather than polled: a poll loop here would be a timing
  /// assertion wearing a helper's clothes.
  Future<void> untilNoSessions() async {
    if (server.sessions.sessionCount == 0) return;
    await server.sessions.gone
        .firstWhere((_) => server.sessions.sessionCount == 0);
  }

  /// Releases everything this fixture opened. Idempotent, and safe on a
  /// half-built harness.
  Future<void> teardown() => _wiring.teardown(ready);
}

/// Stands up a server, a client and a plant over one real WebSocket.
///
/// The `FakeStateMan` arguments are the same ones `channelServedFake` and
/// `socketServedFake` take, with the same defaults, for the reason in this
/// library's doc.
RelayFixture relayFixture({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
  ServerConfig? config,
  TokenValidator validator = const PermissiveTokenValidator(),
  List<String> serverSupported = const [protocolVersion],
  bool withProxy = false,
  RelayErrorHandler? onError,
  // 17-09's three pass-throughs, defaulted to the server's own defaults so
  // every existing fixture composition is byte-identical.
  UserResolver? accounts,
  AuditSink? audit,
  AccessScopeFactory? accessFor,
  // Increment B: the sign-in seam, null for every fixture that predates it.
  AuthProvider? loginVerifier,
}) {
  final served = FakeStateMan(
    staleAfter: staleAfter,
    readOnlyKeys: readOnlyKeys,
    writeLatency: writeLatency,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
  );
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: config ?? fixtureConfig(),
    validator: validator,
    serverSupported: serverSupported,
    accounts: accounts,
    audit: audit ?? const NullAuditSink(),
    accessFor: accessFor,
    loginVerifier: loginVerifier,
    // Defaults to a collector that discards rather than to `reportToStderr`:
    // several cases in this phase provoke errors on purpose, and a suite that
    // printed a stack trace per provoked error would train everyone to
    // scroll past them. A case that cares supplies its own.
    onError: onError ?? (_, __, ___) {},
  );
  final wiring = _RelayWiring(served, server, withProxy: withProxy);
  final ready = wiring.connect();
  // Registered at acquisition, so a case that returns early — or fails an
  // assertion before its own teardown line — still releases the descriptors.
  // Idempotent, so a case that also registers its own is not a problem.
  final fixture = RelayFixture._(served, server, wiring, ready);
  addTearDown(fixture.teardown);
  return fixture;
}

/// The descriptors one production fixture owns, and the order to release them.
final class _RelayWiring {
  _RelayWiring(this.served, this.server, {required this.withProxy});

  final FakeStateMan served;
  final RelayServer server;
  final bool withProxy;

  final inbound = <String>[];
  final _socketDone = Completer<void>();

  FaultProxy? _proxy;
  WebSocketChannel? _client;
  rpc.Client? _peer;
  var _torn = false;

  /// Completes when the client's socket has finished, however it finished.
  Future<void> get socketDone => _socketDone.future;

  WebSocketChannel get client {
    final client = _client;
    if (client == null) {
      throw StateError('the fixture has no client until `ready` has '
          'completed; await it before reaching for the socket');
    }
    return client;
  }

  rpc.Client get peer {
    final peer = _peer;
    if (peer == null) {
      throw StateError('the fixture has no client peer until `ready` has '
          'completed; await it before sending a request');
    }
    return peer;
  }

  FaultProxy requireProxy() {
    final proxy = _proxy;
    if (proxy == null) {
      throw StateError('this fixture was built without a proxy; pass '
          '`withProxy: true` to relayFixture before pulling a lever');
    }
    return proxy;
  }

  /// Binds, proxies, connects, and waits for the session to be registered.
  ///
  /// Deliberately without early exits: a half-built harness is harder to
  /// release than a fully built one, so the sequence runs to completion and
  /// [teardown] waits for it (`socket_harness.dart:191-196`).
  Future<void> connect() async {
    final ready = _connect();
    // The error is *handled* here so that a fixture nobody awaited cannot
    // surface as an unhandled async error in an unrelated case — and it is
    // still delivered to whoever does await `ready`, because `catchError`
    // returns a new future and leaves this one alone.
    unawaited(ready.catchError((Object _) {}));
    return ready;
  }

  Future<void> _connect() async {
    await server.start();

    // Subscribed *before* the client connects: the session can be registered
    // in the same event-loop turn the connect completes in, and a listener
    // attached afterwards would wait for a second connection that never
    // comes.
    final opened = server.sessions.opened.first;

    if (withProxy) {
      final proxy = FaultProxy(targetPort: server.port);
      _proxy = proxy;
      await proxy.start();
    }

    final port = _proxy?.port ?? server.port;
    final ws = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
    _client = ws;
    await ws.ready;

    _peer = rpc.Client(_tap(ws));
    // Swallowed on purpose, `channel_state_man.dart:99-102`'s argument: a
    // channel failure must fail the check that named the property, not arrive
    // as an unhandled zone error attributed to an unrelated test.
    unawaited(peer.listen().catchError((Object _) => null));

    await opened.timeout(_acceptBudget);
  }

  /// The client's channel, with the two taps a socket case needs on it.
  ///
  /// Built on `wsChannel` rather than beside it, so the client end of every
  /// fixture inherits the same subscription discipline the server end has —
  /// the muted republish that keeps a cancelled `Peer` from handing the
  /// socket's next error to the ambient isolate (`ws_channel.dart:47-62`).
  StreamChannel<String> _tap(WebSocketChannel ws) {
    final base = wsChannel(ws);
    final tapped = base.stream
        .map((frame) {
          inbound.add(frame);
          return frame;
        })
        .transform(StreamTransformer<String, String>.fromHandlers(
          handleDone: (sink) {
            if (!_socketDone.isCompleted) _socketDone.complete();
            sink.close();
          },
        ));
    return StreamChannel<String>(tapped, base.sink);
  }

  /// Releases every descriptor, innermost first, and only once.
  ///
  /// The order is the one `socket_harness.dart:234-266` argues for, read from
  /// the inside out: the client's peer (which owns nothing but its
  /// subscription), then the server (whose `close` drains its sessions with a
  /// code and then stops its listener), then the proxy — shutting it down
  /// destroys both halves of every pair it carries, so it cannot go first —
  /// then whatever is left of the client socket, then the fake, whose
  /// freshness watchdog must outlive anything still draining through it.
  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;

    // A half-built harness is still a harness: wait for the sequence to
    // finish before releasing what it managed to open, and do not let its
    // failure stop the release.
    await ready.catchError((Object _) {});

    await _peer?.close();
    await server.close();
    await _proxy?.shutdown();
    await _client?.sink.close().catchError((Object _) {});
    await served.dispose();

    if (!_socketDone.isCompleted) _socketDone.complete();
  }
}

// ---------------------------------------------------------------------------
// The contract leg.
// ---------------------------------------------------------------------------

/// Both halves of one WS-served source, for a test that needs to reach past
/// the client. Ordinary drivers want [wsServedFake] and never see this.
final class WsServedFake {
  WsServedFake._(this.served, this.api, this._wiring, this.ready);

  /// The reference implementation, on the far side.
  final FakeStateMan served;

  /// The implementation under test, on this side.
  final ChannelStateMan api;

  final _WsFakeWiring _wiring;

  /// Completes once the served end exists.
  final Future<void> ready;

  /// The served peer, for a test that wants to close one end explicitly.
  /// Available once [ready] has completed.
  ServedStateMan get session => _wiring.requireSession();

  /// The fault proxy in front of the served socket, when one was asked for.
  FaultProxy get proxy => _wiring.requireProxy();

  Future<void> teardown() => _wiring.teardown(ready);
}

/// A `FakeStateMan` served over a real WebSocket, both ends wired.
///
/// No relay session is involved: this leg is the transport under the contract,
/// and the gateway's own gate would refuse all 44 checks before hello.
WsServedFake serveFakeOverWs({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
  bool withProxy = false,
}) {
  final served = FakeStateMan(
    staleAfter: staleAfter,
    readOnlyKeys: readOnlyKeys,
    writeLatency: writeLatency,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
  );

  final completer = StreamChannelCompleter<String>();
  final wiring = _WsFakeWiring(served, withProxy: withProxy);
  final ready = wiring.connect(completer);

  final api = ChannelStateMan(
    channel: completer.channel,
    observables: served,
    closeServed: () => wiring.teardown(ready),
  );

  return WsServedFake._(served, api, wiring, ready);
}

/// The driver-facing factory: one WS-served `StateManApi`, per case.
///
/// ```dart
/// void main() => runStateManContract(wsServedFake);
/// ```
///
/// The same shape and the same defaults as `channelServedFake`
/// (`channel_harness.dart:97-105`) and `socketServedFake`
/// (`socket_harness.dart:146-153`).
StateManApi wsServedFake({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
}) =>
    serveFakeOverWs(
      staleAfter: staleAfter,
      readOnlyKeys: readOnlyKeys,
      writeLatency: writeLatency,
      browse: browse,
      timeseries: timeseries,
      historyViews: historyViews,
      preferences: preferences,
    ).api;

/// The descriptors one contract-leg harness owns.
final class _WsFakeWiring {
  _WsFakeWiring(this.served, {required this.withProxy});

  final FakeStateMan served;
  final bool withProxy;

  HttpServer? _http;
  FaultProxy? _proxy;
  WebSocketChannel? _client;
  final _sessions = <ServedStateMan>[];
  var _torn = false;

  ServedStateMan requireSession() {
    if (_sessions.isEmpty) {
      throw StateError('the harness has no served session until `ready` has '
          'completed; await it before reaching for one');
    }
    return _sessions.first;
  }

  FaultProxy requireProxy() {
    final proxy = _proxy;
    if (proxy == null) {
      throw StateError('this harness was built without a proxy; pass '
          '`withProxy: true` before pulling a lever');
    }
    return proxy;
  }

  /// Binds, serves, proxies and connects — then hands the client its channel.
  ///
  /// Never throws: a failure anywhere is delivered to the channel, so the
  /// client's `Peer` sees a broken transport and every contract check fails on
  /// its own deadline naming its own property.
  Future<void> connect(StreamChannelCompleter<String> completer) async {
    try {
      final accepted = Completer<void>();
      _http = await shelf_io.serve(
        webSocketHandler((WebSocketChannel ws, String? _) {
          _sessions.add(serveStateMan(served, wsChannel(ws)));
          if (!accepted.isCompleted) accepted.complete();
        }),
        InternetAddress.loopbackIPv4,
        0,
      );

      if (withProxy) {
        final proxy = FaultProxy(targetPort: _http!.port);
        _proxy = proxy;
        await proxy.start();
      }

      final port = _proxy?.port ?? _http!.port;
      final ws = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
      _client = ws;
      await ws.ready;
      await accepted.future.timeout(_acceptBudget);
      completer.setChannel(wsChannel(ws));
    } catch (error, stack) {
      completer.setError(error, stack);
    }
  }

  /// Releases every descriptor, innermost first, and only once.
  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;

    await ready;

    for (final session in _sessions) {
      await session.close();
    }
    _sessions.clear();

    await _proxy?.shutdown();
    await _http?.close(force: true);
    await _client?.sink.close().catchError((Object _) {});
    await served.dispose();
  }
}
