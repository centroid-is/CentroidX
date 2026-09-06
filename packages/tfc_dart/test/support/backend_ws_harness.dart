/// The backend adapter, served over a real WebSocket — two legs and one rule.
///
/// [backendWsServed] is the **contract** leg: a `ServedStateMan` and a
/// `ChannelStateMan` on either end of a real WebSocket, with **no relay session
/// between them**. It exists to prove the transport, which is what makes
/// running the shared suite over WS (13-11) mean anything. A relay session
/// would refuse all 43 checks before `hello`, so the gate belongs on the other
/// leg and not on this one.
///
/// [backendRelayFixture] is the **production** leg: the real [RelayServer] that
/// [composeBackendRelay] built, bound on an OS-chosen port, with a raw client
/// socket in front of it. Nothing in the contract suite uses it. It exists so
/// that the rig runbook's protocol probes (criterion 3, deferred and
/// human-attended) have a local reproduction of the production path, and so a
/// later phase does not have to invent one.
///
/// ## The thing being served is the composition the binary builds
///
/// The one deliberate difference from `tfc_relay_server`'s `ws_harness.dart`,
/// which serves a `FakeStateMan`: this file serves the `BackendStateMan` that
/// [composeBackendRelay] assembles — the same function `bin/main.dart` calls,
/// with the same real `Database`, the same real `Preferences`, the same
/// `KeyMappingSeriesResolver` and the same [backendRelayPolicy]. Serving a
/// hand-assembled graph would make this leg evidence about a fixture, and
/// criterion 4 (13-10) exists because the graph nothing assembled was the only
/// one that shipped.
///
/// The consequence worth naming: the pipe, the fake worker and every lever are
/// on the **server** side of the socket. A case that calls `setValue` on the
/// client is putting a notification on the wire, which `ServedStateMan` applies
/// to a real `PipeMainEndpoint`, whose frame travels back as an update. A
/// harness that shortcut a lever to the client end would be testing the client.
///
/// ## Defaults are imported, never re-spelled
///
/// `staleAfter` is [kBackendStaleAfter] — the production number, and the same
/// object the in-memory leg runs at, because it comes from the same constant
/// rather than from a second literal. A defaults difference between two legs
/// reads as a *transport* difference and sends someone looking for a bug in the
/// socket layer that is really a `staleAfter` of 300 ms against one of 500
/// (`socket_harness.dart:137-145` is the recorded instance of that costing
/// time). The key list, the key mappings, the read-only key, the declared
/// method key and the first snapshot all come from
/// `harnessed_backend_state_man.dart` for the same reason — and so does
/// [HarnessedBackendStateMan] itself, so "the levers are the in-memory leg's
/// levers" is a fact about a shared class rather than a claim about two copies.
///
/// ## Nothing here throws out of the wiring
///
/// A failure while binding, serving or connecting is delivered to the thing the
/// case is awaiting — the client's channel on the contract leg, the `ready`
/// future on the production one. The reason is `ws_harness.dart`'s and it is
/// worth repeating: an exception raised from a listener callback lands in the
/// ambient isolate and `package:test` attributes it to whichever case happens
/// to be running when it arrives, so a wiring bug is reported against an
/// innocent check and diagnosed once per project, painfully.
///
/// ## Known transport bugs this file does not trip
///
/// - `closeCode` is null after a self-initiated close (dart-lang/http#1698):
///   nothing here asserts on a close code, and the production leg reports the
///   code the **client** observed if a later case wants one.
/// - `sink.add(List<int>)` sends a text frame on legacy web (#1648): every
///   frame on both legs is a `String`, which is what `StreamChannel<String>`
///   means, so there is no binary path to get wrong.
/// - `readyState` lies after OS sleep: never read.
///
/// ## The shared store
///
/// [composeBackendRelay] takes a non-nullable `Database` and `Preferences`, so
/// this leg needs both before its first case. [installBackendWsStore] registers
/// the `setUpAll`/`tearDownAll` that create them once per FILE — a real on-disk
/// SQLite `AppDatabase`, which is the production class over a different drift
/// executor and runs on a machine with no Docker daemon (13-09 Finding 1,
/// 13-10's fixture). Once per file rather than once per case because 43 cases
/// each creating a temp directory and a database is a minute of wall clock
/// bought for nothing: this leg declares `supportsDataServices: false`, so
/// nothing any case does reaches the store at all.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart' show kBackendStaleAfter;
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
// Reaching into `tfc_relay_server/lib/src/` on purpose. `wsChannel` is the
// harness-side adapter that turns a `WebSocketChannel` into the
// `StreamChannel<String>` both ends of the contract kit speak, and it carries
// two expensive lessons in it: cast the STREAM and build the sink by hand (a
// `channel.cast<String>()` binds the sink with `addStream` for the life of the
// connection and every later writer gets `Bad state: Cannot add event while
// adding stream`), and republish MUTED so a closed `Peer` does not hand the
// socket's next error to the ambient isolate. Copying it here would give this
// package a second copy free to drift from the one `ws_harness.dart` uses —
// and then the two WS legs would no longer be running the same transport,
// which is the only thing this leg's parity claim rests on.
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'harnessed_backend_state_man.dart';

/// How long the served end has to appear after the client's connect returns.
///
/// `ws_harness.dart`'s `_acceptBudget`, same value and same argument: generous,
/// because it is a *wiring* budget and not a measurement. What it protects
/// against is a harness that hangs forever when the accept never happens — the
/// denial-of-service shape of a wiring bug (T-13-11-c).
const _acceptBudget = Duration(seconds: 5);

// ---------------------------------------------------------------------------
// The shared store.
// ---------------------------------------------------------------------------

Directory? _storeDir;
Database? _database;
Preferences? _prefs;

/// The real on-disk store both legs compose over. Null until [installBackendWsStore].
Database get backendWsDatabase =>
    _database ??
    (throw StateError('no Database yet: call installBackendWsStore() at the '
        'top of main() before runStateManContract, or the first case will '
        'compose against nothing'));

/// The real preference store both legs compose over.
Preferences get backendWsPreferences =>
    _prefs ??
    (throw StateError('no Preferences yet: call installBackendWsStore() at '
        'the top of main() before runStateManContract'));

/// Registers the `setUpAll`/`tearDownAll` that own the shared store.
///
/// Call once, at the top of `main()`, **before** `runStateManContract`. A
/// top-level `setUpAll` runs before every group in the file, and the contract
/// umbrella's factory is invoked inside a case, so the ordering holds without
/// either side knowing about the other.
void installBackendWsStore() {
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('backend-ws-contract');
    _storeDir = dir;
    // The production class over a real on-disk database — the same fixture
    // `backend_composition_test.dart` uses, and for the same reason: SQLite is
    // the production code path with a different executor behind drift, and it
    // runs on a machine with no Docker daemon.
    final database = Database(await AppDatabase.create(
      DatabaseConfig(applicationName: 'backend-ws-contract'),
      sqliteFolder: dir,
    ));
    _database = database;
    _prefs = await Preferences.create(db: database);
  });

  tearDownAll(() async {
    await _database?.close();
    _database = null;
    _prefs = null;
    final dir = _storeDir;
    _storeDir = null;
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
  });
}

/// The `relay` section an operator would write, with the port left to the OS.
///
/// `port: 0` and no credentials: this is a loopback fixture, and a token file
/// would be a second thing to get wrong in a leg whose subject is framing.
/// `RelayServer`'s own credential arms live in `tfc_relay_server`.
Map<String, dynamic> _relaySection({int port = 0}) => <String, dynamic>{
      'relay': <String, dynamic>{
        'port': port,
        'credentials': <String, dynamic>{'source': 'none'},
      },
    };

/// The graph, plus the fake plant behind it and the levers that drive it.
///
/// Everything on the server side of the socket, in one object, so a teardown
/// can release it in one place.
final class ComposedBackendUnderTest {
  ComposedBackendUnderTest._(this.composition, this.harness, this.pipe);

  /// What [composeBackendRelay] built — the shipping graph, unstarted.
  final BackendRelayComposition composition;

  /// The same lever-carrying wrapper the in-memory leg is judged through.
  final HarnessedBackendStateMan harness;

  /// The real pipe every lever's frame crosses.
  final PipeMainEndpoint pipe;
}

/// Composes the shipping graph over a fake worker and the shared store.
///
/// The only thing that is not production here is the *worker*: a
/// [FakePlantLink] instead of an acquisition isolate, which is what lets a case
/// say "the plant published 1200" without a PLC. Everything between that link
/// and the socket — the pipe, the live values, the sweep, the write router,
/// the browse tree, the resolver, the policy, the server — is what
/// `bin/main.dart` constructs.
ComposedBackendUnderTest composeBackendUnderTest({int port = 0}) {
  final plant = FakePlantLink('contract-ws');
  final pipe = PipeMainEndpoint(
    // The same short write deadline the in-memory leg runs at
    // (`harnessed_backend_state_man.dart`): the write cases are about the
    // three-state outcome, not about how long a plant is given to answer.
    writeDeadline: const Duration(milliseconds: 400),
    logger: Logger(level: Level.off),
  );
  pipe.addWorker(plant, contractPlantKeys());

  final composition = composeBackendRelay(
    config: RelayConfig.fromJson(_relaySection(port: port),
        source: 'backend_ws_harness')!,
    pipe: pipe,
    keyMappings: contractKeyMappings(),
    database: backendWsDatabase,
    prefs: backendWsPreferences,
    // 13-04 Finding 1, and the identical asymmetry the in-memory leg declares.
    // Production passes NONE — a true statement about SVN's address space,
    // because `KeyMappingEntry` has no callable concept — and both contract
    // legs declare exactly one, so
    // `checkBrowseNodeTypesDistinguishFoldersFromVariables` runs against a real
    // code path rather than going red with no bug behind it. Do not "fix" this
    // by teaching the mapping about methods.
    methodKeys: contractMethodKeys,
    // Imported, never re-spelled. See this library's doc.
    staleAfter: kBackendStaleAfter,
    log: Logger(level: Level.off),
  );

  final writes = composition.api.writes;
  if (writes is! BackendWrites) {
    throw StateError('composeBackendRelay handed back a '
        '${writes.runtimeType} where BackendWrites was expected. The write '
        'harness levers read `upstreamAttempts` and `mintedCmds` off that '
        'class; a different one means the composition changed and this '
        'harness is now driving something else');
  }

  final harness = HarnessedBackendStateMan(
    composition.api,
    pipe: pipe,
    plant: plant,
    values: composition.freshness,
    writes: writes,
  );

  // The plant's first publishing interval, as an ordinary frame down the
  // ordinary path — `checkFetchDetailDescribesTheNode` wants a current reading
  // on the browse fixture's variable, and a real worker's first publish is
  // where one comes from. Same snapshot as the in-memory leg's.
  plant.deliverAll(contractInitialSnapshot());

  return ComposedBackendUnderTest._(composition, harness, pipe);
}

// ---------------------------------------------------------------------------
// The contract leg.
// ---------------------------------------------------------------------------

/// Both halves of one WS-served backend, for a test that needs to reach past
/// the client. Ordinary drivers want [backendWsServed] and never see this.
final class BackendWsServed {
  BackendWsServed._(this.backend, this.api, this._wiring, this.ready);

  /// The composition and its levers, on the far side of the socket.
  final ComposedBackendUnderTest backend;

  /// The implementation under test, on this side: everything it can answer
  /// arrived over the wire.
  final ChannelStateMan api;

  final _BackendWsWiring _wiring;

  /// Completes once the served end exists.
  final Future<void> ready;

  /// The served peer, for a test that wants to close one end explicitly.
  ServedStateMan get session => _wiring.requireSession();

  Future<void> teardown() => _wiring.teardown(ready);
}

/// The backend adapter served over a real WebSocket, both ends wired.
BackendWsServed serveBackendOverWs() {
  final backend = composeBackendUnderTest();
  final completer = StreamChannelCompleter<String>();
  final wiring = _BackendWsWiring(backend);
  final ready = wiring.connect(completer);

  final api = ChannelStateMan(
    channel: completer.channel,
    // `staleAfter`, `roundTrips` and `statusNotifications` are read straight
    // off the served instance and never mirrored onto the wire — they are
    // promises about a count, and a count a connected client could query would
    // be an access-control decision (`harness.dart:16-25`).
    observables: backend.harness,
    closeServed: () => wiring.teardown(ready),
  );

  return BackendWsServed._(backend, api, wiring, ready);
}

/// The driver-facing factory: one WS-served backend adapter, per case.
///
/// ```dart
/// runStateManContract(backendWsServed, ...);
/// ```
///
/// The same shape as `wsServedFake` (`ws_harness.dart:466`) and
/// `makeHarnessedBackendStateMan` (`harnessed_backend_state_man.dart:374`),
/// and it takes no capability arguments for the same reason the latter does
/// not: what this leg can do is decided by the composition, not by the caller.
relay.StateManApi backendWsServed() {
  final served = serveBackendOverWs();
  // Registered at acquisition, so a case that fails an assertion before its own
  // teardown line still releases the descriptors. Idempotent, so the
  // sub-suites' own `addTearDown(api.dispose)` — which also closes the served
  // end — is not a problem.
  addTearDown(served.teardown);
  return served.api;
}

/// The descriptors one contract-leg harness owns, and the order to release them.
final class _BackendWsWiring {
  _BackendWsWiring(this.backend);

  final ComposedBackendUnderTest backend;

  HttpServer? _http;
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

  /// Binds, serves and connects — then hands the client its channel.
  ///
  /// **Never throws.** A failure anywhere is delivered to the channel, so the
  /// client's `Peer` sees a broken transport and every contract check fails on
  /// its own deadline naming its own property, instead of one wiring
  /// exception being attributed to whichever case was running.
  Future<void> connect(StreamChannelCompleter<String> completer) async {
    try {
      final accepted = Completer<void>();
      _http = await shelf_io.serve(
        webSocketHandler((WebSocketChannel ws, String? _) {
          _sessions.add(serveStateMan(backend.harness, wsChannel(ws)));
          if (!accepted.isCompleted) accepted.complete();
        }),
        // A numeric loopback address, never 'localhost': the name resolves to
        // two families on this machine and a bind on one with a connect to the
        // other is a hang that reads as a protocol failure.
        InternetAddress.loopbackIPv4,
        0,
      );

      final ws =
          IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${_http!.port}'));
      _client = ws;
      await ws.ready;
      await accepted.future.timeout(_acceptBudget);
      completer.setChannel(wsChannel(ws));
    } catch (error, stack) {
      completer.setError(error, stack);
    }
  }

  /// Releases every descriptor, innermost first, and only once.
  ///
  /// Inside out: the served sessions (which own only their peers), then the
  /// HTTP server, then whatever is left of the client socket, then the
  /// composition — whose `dispose` closes the unstarted `RelayServer` and the
  /// adapter but deliberately not the borrowed `Database` — and last the
  /// fixture's own pipe and fake worker, which have to outlive anything still
  /// draining through them.
  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;

    // A half-built harness is still a harness: wait for the sequence to finish
    // before releasing what it managed to open, and do not let its failure
    // stop the release.
    await ready.catchError((Object _) {});

    for (final session in _sessions) {
      await session.close();
    }
    _sessions.clear();

    await _http?.close(force: true);
    await _client?.sink.close().catchError((Object _) {});
    await backend.composition.dispose();
    backend.harness.shutdownFixture();
  }
}

// ---------------------------------------------------------------------------
// The production leg.
// ---------------------------------------------------------------------------

/// The real [RelayServer] the binary builds, bound, with a raw client socket.
///
/// **Nothing in the contract suite uses this.** It is here so the rig runbook's
/// protocol probes have a local reproduction of the production path — the
/// session gate, `hello`, the policy layer and the resolver all in front of the
/// same adapter — and so the phase that finally runs those probes does not have
/// to invent a fixture under time pressure on a plant test rig.
final class BackendRelayFixture {
  BackendRelayFixture._(this.backend, this._wiring, this.ready);

  /// The composition, its levers, and the plant behind them.
  final ComposedBackendUnderTest backend;

  final _BackendRelayWiring _wiring;

  /// Completes when the server is bound and the client socket is open.
  final Future<void> ready;

  /// The bound port. Available once [ready] has completed.
  int get port => backend.composition.server.port;

  /// Every frame the client has received, in order.
  List<String> get inbound => List.unmodifiable(_wiring.inbound);

  /// The close code the CLIENT observed — the only one worth asserting on for
  /// a close the server initiated (`web_socket_channel` #1698).
  int? get observedCloseCode => _wiring.client.closeCode;

  /// Sends [method] and returns its result inside a named budget.
  Future<Object?> request(String method,
          {Object? params,
          String? what,
          Duration budget = const Duration(seconds: 5)}) =>
      _wiring.request(method,
          params: params,
          what: what ?? 'a $method response over a real socket',
          budget: budget);

  /// Says hello and hands back the negotiated result.
  Future<relay.HelloResult> hello({Duration budget = const Duration(seconds: 5)}) async {
    final raw = await request(
      relay.Methods.hello,
      params: relay.HelloParams(
        protocol: relay.protocolVersion,
        supported: const [relay.protocolVersion],
        client: const relay.PeerInfo('backend-ws-harness', '0.1.0'),
      ).toJson(),
      what: 'the hello result over a real socket',
      budget: budget,
    );
    return relay.HelloResult.fromJson((raw as Map).cast<String, Object?>());
  }

  Future<void> teardown() => _wiring.teardown(ready);
}

/// Stands the shipping composition up on a real port, with a client in front.
BackendRelayFixture backendRelayFixture() {
  final backend = composeBackendUnderTest();
  final wiring = _BackendRelayWiring(backend);
  final ready = wiring.connect();
  final fixture = BackendRelayFixture._(backend, wiring, ready);
  addTearDown(fixture.teardown);
  return fixture;
}

/// The descriptors one production fixture owns.
///
/// The JSON-RPC client here is hand-rolled over `dart:convert` rather than
/// `json_rpc_2`. Two reasons, and the second is the one that matters: this
/// plan adds four dev dependencies and a fifth for a fixture the contract suite
/// does not use would be a dependency nobody could point at a test for — and a
/// probe fixture whose *client* is the same library the server uses proves less
/// about the wire than one that spells the envelope out.
final class _BackendRelayWiring {
  _BackendRelayWiring(this.backend);

  final ComposedBackendUnderTest backend;

  final inbound = <String>[];
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 1;

  WebSocketChannel? _clientOrNull;
  var _torn = false;

  WebSocketChannel get client {
    final client = _clientOrNull;
    if (client == null) {
      throw StateError('the fixture has no client until `ready` has '
          'completed; await it before reaching for the socket');
    }
    return client;
  }

  /// Binds and connects. The error is handled here as well as delivered, so a
  /// fixture nobody awaited cannot surface as an unhandled async error in an
  /// unrelated case.
  Future<void> connect() {
    final ready = _connect();
    unawaited(ready.catchError((Object _) {}));
    return ready;
  }

  Future<void> _connect() async {
    await backend.composition.server.start();
    final ws = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${backend.composition.server.port}'));
    _clientOrNull = ws;
    await ws.ready;
    ws.stream.listen(
      _onFrame,
      // Delivered to whoever is awaiting, never rethrown into the ambient
      // isolate: an error raised from a listener callback is attributed to
      // whichever case is running when it arrives.
      onError: _failAllPending,
      onDone: () => _failAllPending(
          StateError('the socket closed with ${_pending.length} request(s) '
              'still outstanding')),
      cancelOnError: false,
    );
  }

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    inbound.add(frame);
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id is! int) return; // a notification, not an answer
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final error = decoded['error'];
    if (error != null) {
      completer.completeError(StateError('the server refused: $error'));
    } else {
      completer.complete(decoded['result']);
    }
  }

  void _failAllPending(Object error, [StackTrace? stack]) {
    final waiting = List.of(_pending.values);
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }
  }

  Future<Object?> request(String method,
      {Object? params, required String what, required Duration budget}) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    client.sink.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future.timeout(budget, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('$what did not arrive within $budget', budget);
    });
  }

  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;
    await ready.catchError((Object _) {});
    _failAllPending(StateError('the fixture was torn down'));
    await backend.composition.dispose();
    await _clientOrNull?.sink.close().catchError((Object _) {});
    backend.harness.shutdownFixture();
  }
}
