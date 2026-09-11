@TestOn('vm')
@Tags(['ws'])

/// SEC-02 from the panel's end: one pinned root, and everything else refused.
///
/// The gateway's half is `tfc_relay_server/test/tls_test.dart`. This file is
/// the same property seen from the machine on the plant floor — the one that
/// decides whether the thing answering is the gateway — driven through the
/// production dial rather than a hand-built socket, so what is proven is the
/// panel's own wiring: `ClientConfig.tls` → one
/// `SecurityContext(withTrustedRoots: true)` → one `HttpClient` →
/// `IOWebSocketChannel.connect(customClient:)`.
///
/// **Every rejection arm varies exactly one thing, and none of them assert
/// why.** 06-RESEARCH §A.3 measured the wrong CA, the expired leaf and the
/// system trust store producing byte-identical text
/// (`CERTIFICATE_VERIFY_FAILED: application verification failure`) with a null
/// close code (trap 16). A case that matched the message and claimed "expired"
/// would pass just as happily when the CA was wrong, so what names the cause
/// here is how the arm is *built*: the same fixture, one input changed, said
/// in the case name.
///
/// **A refusal is not evidence unless the listener speaks TLS.** Dialling
/// `wss://` at a *plaintext* listener also raises a `HandshakeException`, so
/// an arm whose server never bound wss would pass for the wrong reason.
/// [_assertServesTls] is the control the server package's `tls_test.dart`
/// established (06-03, "measured facts" §4) and it is copied here with its
/// argument: a `ws://` dial that comes back `HttpException` proves the
/// listener is TLS. The system-roots arm needs none — it shares its `setUp`
/// server with the hostname arm, which completes a pinned handshake against
/// it.
///
/// **Every dial carries a bound.** An unreachable address takes 75 s to fail
/// on macOS (06-RESEARCH §C.4, trap 17). Direct dials pass `connectTimeout:`
/// and every panel here is built on a `ClientConfig` whose `connectTimeout` is
/// set, which is what bounds the dials the supervisor makes for itself.
///
/// **Certificates are minted at test time, never committed.** The client
/// package cannot import another package's `test/` directory, so the wiring of
/// `tfc_relay_server/test/support/certs.dart` is reproduced here over the
/// barrel-exported `mintCertificate` — the same minter the CLI uses, so these
/// fixtures prove the tool rather than resembling it. One RSA keypair costs
/// ~364 ms and every certificate signed from it costs 3–18 ms (06-01), so the
/// pairs are cached for the isolate and the certificates are free.
///
/// Without this file the panel can ship dialling `wss://` on the machine's own
/// trust store — connecting to nothing at all in the plant, or worse, to
/// whatever a rogue root installed on that station is willing to vouch for.
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/permissive_resolver.dart';

/// A key `FakeStateMan` seeds at construction, so a subscribe against a real
/// gateway answers with a real snapshot and no plant has to be simulated.
const String _seededKey = 'PIPE.connected';

/// The ceiling on any dial here (trap 17).
///
/// Generous against a cold RSA handshake — 42 ms measured — and small against
/// the 75 s the operating system would otherwise spend on a dial that cannot
/// complete. A hang guard, never a measurement.
const Duration _dialBudget = Duration(seconds: 10);

/// The budget for "the panel got where it was going": a capped backoff draw, a
/// dial, a handshake, a hello and a snapshot. A liveness budget, not a latency
/// measurement.
const Duration _recovery = Duration(seconds: 5);

/// The panel's knobs, with the deadline floor lowered deliberately.
///
/// Lowering it is explicit and greppable for the reason `client_config.dart`
/// gives — nobody lowers it in production by accident. The small backoff is
/// what lets the reconnect arm force four connections inside one case.
ClientConfig _config({ClientTlsConfig? tls}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
      connectTimeout: _dialBudget,
      tls: tls,
    );

// ---------------------------------------------------------------------------
// Certificates. `test/support/certs.dart`'s wiring, over the same minter.
// ---------------------------------------------------------------------------

/// A certificate authority a case can sign leaves under.
typedef _Ca = ({
  String certPem,
  String keyPem,
  Map<String, String> dn,
  RelayKeyPair keys,
});

/// The paths [_mount] wrote.
typedef _Mounted = ({String chainPath, String keyPath, String rootPath});

({RelayKeyPair ca, RelayKeyPair leaf})? _pairs;

/// The one CA keypair and the one leaf keypair this isolate uses.
///
/// Generated on first call. A lazy top-level rather than a `setUpAll` for the
/// reason 06-01 gives: the cost is RSA, and paying it once per process is the
/// difference between a suite that mints freely and one nobody wants to run.
({RelayKeyPair ca, RelayKeyPair leaf}) _keyPairs() =>
    _pairs ??= (ca: generateKeyPair(), leaf: generateKeyPair());

/// A ten-year private root, the way the plant's is provisioned.
_Ca _mintCa() {
  final keys = _keyPairs().ca;
  final dn = {'CN': 'Relay Test CA', 'O': 'Centroid'};
  final now = DateTime.now().toUtc();
  return (
    certPem: mintCertificate(
      signingKey: keys.privateKey,
      issuer: dn,
      subject: dn,
      subjectPublicKey: keys.publicKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 3650)),
      ca: true,
    ),
    keyPem: privateKeyToPem(keys.privateKey),
    dn: dn,
    keys: keys,
  );
}

/// A root the panel does *not* carry — what makes a CA foreign.
///
/// It signs with the leaf keypair rather than generating a third, exactly as
/// `mintForeignCa` does upstream: the property is that the panel has no copy
/// of this root, not that the key is a particular one.
_Ca _mintForeignCa() {
  final keys = _keyPairs().leaf;
  final dn = {'CN': 'Someone Else Entirely', 'O': 'Not Centroid'};
  final now = DateTime.now().toUtc();
  return (
    certPem: mintCertificate(
      signingKey: keys.privateKey,
      issuer: dn,
      subject: dn,
      subjectPublicKey: keys.publicKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 3650)),
      ca: true,
    ),
    keyPem: privateKeyToPem(keys.privateKey),
    dn: dn,
    keys: keys,
  );
}

/// A gateway leaf signed by [ca].
///
/// The IP subject-alternative name is not decoration: the plant dials
/// addresses, the reconnect arm below dials the fault proxy at `127.0.0.1`,
/// and a leaf whose IP SAN was written as a DNS string (the defect 06-01's
/// `0x87` fix exists for) passes the hostname arm and fails only those.
///
/// [notBefore] and [notAfter] are how a case asks for an expired leaf: one
/// argument on the same keypair, not a second keygen.
String _mintLeaf({
  required _Ca ca,
  List<String> sans = const ['localhost', '127.0.0.1'],
  DateTime? notBefore,
  DateTime? notAfter,
}) {
  final now = DateTime.now().toUtc();
  return mintCertificate(
    signingKey: ca.keys.privateKey,
    issuer: ca.dn,
    subject: {'CN': 'relay-gateway', 'O': 'Centroid'},
    subjectPublicKey: _keyPairs().leaf.publicKey,
    sans: sans,
    notBefore: notBefore ?? now.subtract(const Duration(days: 1)),
    notAfter: notAfter ?? now.add(const Duration(days: 365)),
  );
}

/// Writes a chain, its key and the root into a fresh temp directory.
///
/// Under `Directory.systemTemp` and never inside the checkout, with the
/// recursive delete registered at acquisition: a case that fails an assertion
/// before its own cleanup line still takes the private key off the machine,
/// and no run can leave a `.pem` somewhere `git add` would find it.
_Mounted _mount({required String chainPem, required String rootPem}) {
  final dir = Directory.systemTemp.createTempSync('relay-client-certs-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final sep = Platform.pathSeparator;
  final chainPath = '${dir.path}${sep}chain.pem';
  final keyPath = '${dir.path}${sep}chain-key.pem';
  final rootPath = '${dir.path}${sep}root.pem';
  File(chainPath).writeAsStringSync(chainPem);
  File(keyPath).writeAsStringSync(privateKeyToPem(_keyPairs().leaf.privateKey));
  File(rootPath).writeAsStringSync(rootPem);
  return (chainPath: chainPath, keyPath: keyPath, rootPath: rootPath);
}

// ---------------------------------------------------------------------------
// The gateway, the panel, and the two ways to dial one.
// ---------------------------------------------------------------------------

/// A real gateway on an ephemeral port, optionally behind a fault proxy.
///
/// `close()` is registered at acquisition rather than after a successful
/// `start()`, the discipline `ws_harness.dart:239-244` states: a server that
/// never bound must still release its registry.
Future<({FakeStateMan served, RelayServer server, FaultProxy? proxy, int port})>
    _gateway({
  required _Mounted mounted,
  bool withProxy = false,
  List<String> allowedOrigins = const [],
}) async {
  final served = FakeStateMan();
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: ServerConfig(
      tick: ServerConfig.minTick,
      tls: TlsConfig(chainPath: mounted.chainPath, keyPath: mounted.keyPath),
      allowedOrigins: allowedOrigins,
    ),
    // Several arms here provoke errors on purpose; a collector that printed a
    // stack per provoked error would train everyone to scroll past them.
    onError: (_, __, ___) {},
  );
  addTearDown(server.close);
  addTearDown(served.dispose);
  await server.start();

  FaultProxy? proxy;
  if (withProxy) {
    proxy = FaultProxy(targetPort: server.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
  }
  return (
    served: served,
    server: server,
    proxy: proxy,
    port: proxy?.port ?? server.port,
  );
}

/// A panel pointed at [uri], trusting [rootPath] and nothing else.
///
/// No `dial:` override: these cases exist to prove the production dial hands
/// the pinned client to the socket, and a harness dial would be a test of the
/// harness.
RemoteStateMan _panel(String uri, {String? rootPath}) {
  final client = RemoteStateMan(
    uri: Uri.parse(uri),
    config: _config(
      tls: rootPath == null ? null : ClientTlsConfig(rootCertPath: rootPath),
    ),
    keys: const {_seededKey},
  );
  addTearDown(client.dispose);
  return client;
}

/// An `HttpClient` pinning [rootPath] and nothing else — the panel's posture,
/// for the arms that dial without building a whole panel.
HttpClient _pinnedClient(String rootPath) {
  final client = HttpClient(
    context: SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(rootPath),
  );
  addTearDown(() => client.close(force: true));
  return client;
}

/// Dials [url] once through the production transport and requires a refusal.
///
/// `connect` is the code under test, not a convenience: it is what drains the
/// second copy of the exception off the stream, and an arm that hand-rolled
/// the dial would be measuring a socket this client never opens.
Future<ConnectFailed> _refused(String url, {HttpClient? client}) async {
  final attempt = await connect(
    Uri.parse(url),
    client: client,
    connectTimeout: _dialBudget,
  );
  return switch (attempt) {
    ConnectFailed() => attempt,
    ConnectSucceeded() =>
      fail('$url completed a handshake it had no business completing'),
  };
}

/// Anti-vacuity: proves the listener on [port] is genuinely speaking TLS.
///
/// See the library doc. Without it, "the pinned dial was refused" is equally
/// consistent with "there was no TLS listener there at all".
Future<void> _assertServesTls(int port) async {
  final attempt = await _refused('ws://localhost:$port');
  expect((attempt.error as WebSocketChannelException).inner,
      isA<HttpException>(),
      reason: 'this has to be a wss listener before its refusal of a pinned '
          'panel means anything');
}

/// Counts dials by wrapping the real one, never by replacing it.
///
/// The `dial:` seam's own doc insists an override stay "one attempt in, one
/// `ConnectAttempt` out, same as the real one", so this delegates to [connect]
/// rather than fabricating an outcome: a counter that also decided what a dial
/// returned would be measuring a schedule it had itself invented.
final class _Dials {
  _Dials(this._client);

  final HttpClient? _client;
  int count = 0;

  Future<ConnectAttempt> call(Uri uri) {
    count++;
    return connect(uri, client: _client, connectTimeout: _dialBudget);
  }
}

/// A dial that sends a browser's `Origin` header.
///
/// This is the one thing [connect] cannot express, and deliberately: a panel
/// is not a browser and sends no `Origin` at all, so the production transport
/// has no parameter for one. The body below is `connect`'s failure path
/// verbatim — including the drain of the second copy off the stream — with the
/// header added, because what the case needs is the *supervisor's* reading of
/// a 403, and that requires the failure to arrive in the shape the real dial
/// would hand it.
Future<ConnectAttempt> _dialAsBrowser(
  Uri uri,
  String origin, {
  required HttpClient client,
}) async {
  final ws = IOWebSocketChannel.connect(
    uri,
    headers: {'Origin': origin},
    customClient: client,
    connectTimeout: _dialBudget,
  );
  try {
    await ws.ready;
  } catch (error, stack) {
    ws.stream.listen(null, onError: (Object _) {}, cancelOnError: true);
    unawaited(ws.sink.done.catchError((Object _) => null));
    return ConnectFailed(ws, error, stack);
  }
  return ConnectSucceeded(ws, wsChannel(ws));
}

/// A supervisor dialling [uri] through [dial], with one subscription
/// registered.
///
/// One rather than none, for `reconnect_test.dart:128-137`'s reason: with an
/// empty registry a resync completes without a call reaching the wire. Built
/// directly rather than through `RemoteStateMan` because what these cases read
/// — `stopped`, `debugScheduledWaits` — is the schedule itself, and the panel
/// deliberately does not re-export it.
ConnectionSupervisor _supervisor(
  Uri uri,
  Future<ConnectAttempt> Function(Uri uri) dial,
) {
  final stores = <String, ValueStore>{};
  final supervisor = ConnectionSupervisor(
    uri: uri,
    config: _config(),
    backoff: Backoff(
      base: const Duration(milliseconds: 40),
      cap: const Duration(milliseconds: 200),
    ),
    barrier: ReadinessBarrier(),
    watchdog:
        FreshnessWatchdog(config: _config(), onViewFreshnessChanged: (_) {}),
    subscriptions: <String, SubscriptionState>{
      's1': SubscriptionState(subId: 's1', keys: {_seededKey}),
    },
    storeFor: (id) => stores.putIfAbsent(id, ValueStore.new),
    dial: dial,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  return supervisor;
}

/// Polls [done] until it holds or [budget] runs out, and fails naming [what].
///
/// A poll rather than a stream wait because these cases assert a *state* the
/// panel reached; the transition that got it there is `reconnect_test.dart`'s
/// business. `remote_state_man_test.dart:135-144`'s helper and its reason.
Future<void> _until(String what, bool Function() done,
    {Duration budget = _recovery}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('a pinned panel reaches the gateway', () {
    late _Ca ca;
    late _Mounted mounted;
    late int port;

    setUp(() async {
      ca = _mintCa();
      mounted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
      port = (await _gateway(mounted: mounted)).port;
    });

    test('a pinned panel connects to the gateway by hostname', () async {
      final panel = _panel('wss://localhost:$port', rootPath: mounted.rootPath);

      await _until('the pinned link to reach ready', () => panel.isReady);

      expect(panel.read(_seededKey), isNotNull,
          reason: 'a socket that opened but carries no snapshot is a TLS '
              'listener with no gateway behind it — the operator sees a panel '
              'that connects and then shows nothing. The whole stack has to '
              'come up over TLS: handshake, hello, subscribe, snapshot');
    });

    test('a pinned panel connects to the gateway by IP literal', () async {
      // The arm 06-01's `0x87` fix exists for, and the one the plant depends
      // on: ST101/ST201/ST301 are addresses, not names. A leaf whose IP SAN
      // was encoded as a DNS string passes the hostname arm above and fails
      // only here.
      final panel = _panel('wss://127.0.0.1:$port', rootPath: mounted.rootPath);

      await _until('the pinned link to reach ready', () => panel.isReady);

      expect(panel.read(_seededKey), isNotNull,
          reason: 'panels are configured with the gateway\'s address; a '
              'gateway reachable only by hostname is a gateway no panel on '
              'the plant floor can reach');
    });

    test('the gateway\'s own leaf is refused by a panel on the system roots',
        () async {
      // Same server, same leaf, same address — only the trust store changes.
      // Non-vacuous without a control of its own: the hostname arm shares this
      // `setUp`'s server and proves it completes a pinned handshake, so a
      // refusal here can only be the trust store. A null customClient is not
      // an omission — it is `WebSocket.connect` building its own default
      // client, which is exactly what a panel with no pinned root does.
      final attempt = await _refused('wss://localhost:$port');

      expect(attempt.error, isA<WebSocketChannelException>());
      expect((attempt.error as WebSocketChannelException).inner,
          isA<HandshakeException>(),
          reason: 'the private root is provisioned to plant machines on '
              'purpose. If the public web roots were enough to reach this '
              'gateway, the pin would be decoration — and a rogue root '
              'installed on the station would be enough to impersonate it '
              '(T-06-20)');
      expect(attempt.closeCode, isNull,
          reason: 'the refusal happens before the upgrade, so there is no '
              'WebSocket and never will be a code; anything reading one here '
              'would report a clean disconnect');
    });
  });

  group('a leaf the panel cannot verify is refused, whatever is wrong with it',
      () {
    late _Ca ca;
    late _Mounted trusted;

    setUp(() {
      ca = _mintCa();
      trusted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
    });

    test('a leaf from a different CA is refused', () async {
      // One thing differs from the connecting arms: who signed the leaf.
      final elsewhere = _mount(
        chainPem: _mintLeaf(ca: _mintForeignCa()),
        rootPem: ca.certPem,
      );
      final impostor = await _gateway(mounted: elsewhere);
      await _assertServesTls(impostor.port);

      final attempt = await _refused('wss://localhost:${impostor.port}',
          client: _pinnedClient(trusted.rootPath));

      expect(attempt.error, isA<WebSocketChannelException>(),
          reason: 'a man in the middle presenting a certificate some other '
              'authority signed must not reach the panel at all');
      expect((attempt.error as WebSocketChannelException).inner,
          isA<HandshakeException>(),
          reason: 'the refusal has to happen in the handshake, before the '
              'upgrade — anything the impostor could answer after that point '
              'is already trusted');
      expect(attempt.closeCode, isNull);
    });

    test('an expired leaf from the trusted CA is refused', () async {
      // One thing differs from the connecting arms: the validity window. The
      // CA is the same CA and the panel carries its root, which is why this
      // case cannot be told from the one above by anything the panel sees —
      // and why neither of them asserts a message.
      final now = DateTime.now().toUtc();
      final lapsed = _mount(
        chainPem: _mintLeaf(
          ca: ca,
          notBefore: now.subtract(const Duration(days: 400)),
          notAfter: now.subtract(const Duration(days: 1)),
        ),
        rootPem: ca.certPem,
      );
      final stale = await _gateway(mounted: lapsed);
      await _assertServesTls(stale.port);

      final attempt = await _refused('wss://localhost:${stale.port}',
          client: _pinnedClient(trusted.rootPath));

      expect((attempt.error as WebSocketChannelException).inner,
          isA<HandshakeException>(),
          reason: 'the yearly re-issue is a Tuesday ticket only because a '
              'lapsed leaf stops the panels loudly; one that still connected '
              'would make the expiry alarm advisory');
      expect(attempt.closeCode, isNull);
    });

    test('the second copy of the handshake error is drained', () async {
      // Measured still required under TLS (06-RESEARCH §A.3 consequence 3):
      // the same exception arrives twice, once from `ready` and once queued on
      // the stream. The copy nobody reads lands on the isolate's ambient
      // handler with no frame of this package in its trace, and package:test
      // attributes it to whichever case runs next — the flake class that is
      // diagnosed once per project, painfully.
      final elsewhere = _mount(
        chainPem: _mintLeaf(ca: _mintForeignCa()),
        rootPem: ca.certPem,
      );
      final impostor = await _gateway(mounted: elsewhere);
      final zoneErrors = <Object>[];

      final attempt = await runZonedGuarded<Future<ConnectFailed>>(
        () => _refused('wss://localhost:${impostor.port}',
            client: _pinnedClient(trusted.rootPath)),
        (Object error, StackTrace stack) => zoneErrors.add(error),
      )!;
      await pumpEventQueue();

      expect(attempt.error, isA<WebSocketChannelException>());
      expect(zoneErrors, isEmpty,
          reason: 'a handshake failure escaping to the isolate handler kills '
              'the reconnect loop on the attempt that found the problem, and '
              'a panel whose certificate is wrong is exactly the panel that '
              'has to keep trying while somebody fixes the file');
    });
  });

  group('the pinned client is built once and released', () {
    test('a panel builds its pinned client once, not once per attempt',
        () async {
      // Counted by construction, not by sockets: the root PEM is **removed
      // from disk** after the panel is built, so a `SecurityContext` built
      // inside the dial would re-read a file that is no longer there and every
      // reconnect below would fail. A panel on a flapping link redials all
      // shift; a context per attempt re-parses the root and leaks a connection
      // pool each time, on the one code path that only runs when something is
      // already wrong (T-06-22).
      final ca = _mintCa();
      final mounted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
      final gateway = await _gateway(mounted: mounted, withProxy: true);
      final proxy = gateway.proxy!;

      final panel =
          _panel('wss://127.0.0.1:${gateway.port}', rootPath: mounted.rootPath);
      // Attached in the same turn as the construction: a transition can happen
      // in the event-loop turn the connect completes in, and `ready` is what
      // this case counts.
      var readys = 0;
      final states = panel.linkStates.listen((state) {
        if (state == LinkState.ready) readys++;
      });
      addTearDown(states.cancel);

      await _until('the first pinned connection', () => readys >= 1);
      File(mounted.rootPath).deleteSync();

      for (var connection = 2; connection <= 4; connection++) {
        proxy.killOnce();
        await _until(
            'reconnect $connection with the root PEM gone from disk', () {
          return readys >= connection;
        });
      }

      expect(readys, greaterThanOrEqualTo(4),
          reason: 'three cut links and three recoveries, all of them after '
              'the mounted root was deleted: the SecurityContext the panel '
              'verifies with was parsed once, at construction, and every '
              'later attempt reused it');
      expect(File(mounted.rootPath).existsSync(), isFalse,
          reason: 'the whole force of this case is that the file was gone '
              'while those reconnects happened; if something restored it, the '
              'case proved nothing');
    });

    test('the pinned client bounds the connect it owns', () {
      // A text pin, for the same reason as the two beside it: what this line
      // buys has no offline observable. `IOWebSocketChannel.connect` applies
      // `connectTimeout` as a `Future.timeout` (io.dart:50-53), which
      // **abandons** the connect rather than cancelling it — 06-07 measured
      // the residue at fds 36→64 and eight live proxy pairs over six seconds
      // of redials. The backoff does not bound that: at the 30 s cap a panel
      // pointed at a gateway that swallows handshakes accumulates for the
      // whole duration of the fault, which on a night shift crosses the
      // default descriptor limit and then fails for a reason that has nothing
      // to do with the network. `HttpClient.connectionTimeout` is the second
      // bound underneath, and it *cancels*.
      final code = File('lib/src/remote_state_man.dart').readAsStringSync();
      expect(code, contains('SecurityContext(withTrustedRoots: false)'),
          reason: 'anti-vacuity: this pin reads the same construction the '
              'case below reads, and both are wrong if that moved');
      expect(code, contains('connectionTimeout = config.connectTimeout'),
          reason: 'the pinned HttpClient was built with a context and nothing '
              'else — no connectionTimeout, no idleTimeout — so there was no '
              'bound underneath the abandoned one at all');
    });

    test('the panel\'s context never consults the machine\'s own trust store',
        () {
      // A text pin, and the reason it has to be one is a measurement: flipping
      // this file's `withTrustedRoots` to `true` while keeping the pinned root
      // loaded leaves **every case in this file green**. It cannot be
      // otherwise — proving the flip matters needs a leaf signed by a root the
      // machine already trusts, and no test can talk a public CA into issuing
      // one for `localhost`. What the flip actually costs is a panel that
      // would also accept a certificate any of the ~150 roots in the OS store
      // can be talked into signing, or that a rogue root installed on that
      // station signs outright (T-06-20) — a property whose only honest
      // offline observable is the declaration itself.
      final source = File('lib/src/remote_state_man.dart');
      expect(source.existsSync(), isTrue,
          reason: 'this case reads the implementation as text, so it must run '
              'with the package root as the working directory');

      final code = source.readAsStringSync();
      expect(code, contains('SecurityContext(withTrustedRoots: false)'),
          reason: 'the panel builds its verifying context here and nowhere '
              'else; if that constructor changed shape this pin is looking at '
              'the wrong thing and the arms above cannot tell');
      expect(code, isNot(contains('withTrustedRoots: true')),
          reason: 'the plant\'s root is provisioned to plant machines exactly '
              'so the public web roots are not in the decision. A panel that '
              'consulted the machine\'s own store could be pointed at an '
              'impostor by anybody who can add a root to that store, which on '
              'a shared factory PC is anybody with an installer');
    });

    test('a disposed panel closes the client it opened, after the link', () {
      // A text pin, deliberately, and the reason is worth stating: an
      // `HttpClient` whose WebSocket has been detached holds no socket and no
      // port, so "was it closed" has no behavioural observable from outside
      // the class — and the seam that would give it one is a getter on
      // `RemoteStateMan` returning the client, which is a hole in exactly the
      // object this phase is hardening. What the pin catches is the two ways
      // this actually breaks: the close being dropped in an edit, and the
      // close being moved *above* the supervisor, where it would close the
      // client out from under a dial still in flight and report the resulting
      // failure as a certificate problem.
      final source = File('lib/src/remote_state_man.dart');
      expect(source.existsSync(), isTrue,
          reason: 'this case reads the implementation as text, so it must run '
              'with the package root as the working directory');

      final code = source.readAsStringSync();
      final closesClient = code.indexOf('_pinned?.close(force: true);');
      final disposesSupervisor = code.indexOf('await _supervisor.dispose();');

      expect(closesClient, isNot(-1),
          reason: 'dispose no longer closes the pinned client. A panel is '
              'disposed on every page teardown in a long-running app, and an '
              'HttpClient left open keeps its connection pool and its idle '
              'timer alive');
      expect(disposesSupervisor, isNot(-1),
          reason: 'the anchor this ordering is measured against is gone, so '
              'the ordering assertion below is meaningless');
      expect(closesClient, greaterThan(disposesSupervisor),
          reason: 'the client must be closed after the supervisor, never '
              'before: until the supervisor is disposed a dial may still be '
              'in flight, and closing the client under it fails that attempt '
              'with something an operator would read as a certificate '
              'problem');
    });
  });

  group('a certificate problem is named, and is deliberately still retried',
      () {
    late _Ca ca;
    late _Mounted trusted;

    setUp(() {
      ca = _mintCa();
      trusted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
    });

    /// A gateway the panel cannot verify, and a supervisor pointed at it.
    ///
    /// The foreign CA is the arm's one variable; everything else — the pinned
    /// root, the address, the schedule — is what the connecting arms use.
    Future<({ConnectionSupervisor supervisor, _Dials dials})>
        untrustedGateway() async {
      final elsewhere = _mount(
        chainPem: _mintLeaf(ca: _mintForeignCa()),
        rootPem: ca.certPem,
      );
      final impostor = await _gateway(mounted: elsewhere);
      await _assertServesTls(impostor.port);

      final dials = _Dials(_pinnedClient(trusted.rootPath));
      return (
        supervisor: _supervisor(
            Uri.parse('wss://localhost:${impostor.port}'), dials.call),
        dials: dials,
      );
    }

    test('a certificate rejection says the certificate was not trusted',
        () async {
      final panel = (await untrustedGateway()).supervisor;

      await _until('the first refusal to be recorded',
          () => panel.lastDownReason != null);

      expect(panel.lastDownReason, contains('certificate'),
          reason: '"the gateway did not answer" is actively wrong here: the '
              'gateway answered, at length, and the panel refused to believe '
              'it. An integrator reading that sentence checks the cable, the '
              'switch and the service before anybody thinks of the leaf that '
              'expired on Sunday');
      expect(panel.lastDownReason, isNot(contains('did not answer')),
          reason: 'the two readings are mutually exclusive, and a line that '
              'said both would send the engineer to the wrong end of the '
              'plant first anyway');
      expect(panel.lastDownReason, contains('CERTIFICATE_VERIFY_FAILED'),
          reason: 'the original OS error text has to survive into the '
              'message: it is what an integrator pastes into a ticket, and it '
              'is the only part of this a support engineer can act on '
              'remotely');
    });

    test('a certificate rejection keeps the panel retrying', () async {
      final gateway = await untrustedGateway();

      await _until('the first refusal to be recorded',
          () => gateway.supervisor.lastDownReason != null);
      await _until('a second attempt to go out', () => gateway.dials.count >= 2);

      expect(gateway.supervisor.stopped, isFalse,
          reason: 'a certificate problem is fixed by replacing a file on the '
              'SERVER, so a panel that keeps trying comes back by itself the '
              'moment somebody does. This is deliberately the opposite of the '
              'auth arm in auth_refusal_test.dart, where a refused credential '
              'is a fact about this panel\'s own secret that retrying cannot '
              'change — and the difference is the whole reason both arms '
              'exist');
      expect(gateway.supervisor.debugScheduledWaits, isNotEmpty,
          reason: 'the retry has to be on the ordinary backoff schedule, not '
              'a bespoke path: the same jitter, the same ceiling and the same '
              'health line every other kind of drop uses');
    });

    test('an origin refusal reads differently from a certificate rejection',
        () async {
      // One thing differs from the arm above: the leaf is the trusted one and
      // the *request* is wrong. Both dials are refused before the upgrade,
      // both carry a null close code, and an operator has to be able to tell
      // them apart — the fix for one is a list in a config file and the fix
      // for the other is a certificate on the gateway.
      final gateway = await _gateway(
        mounted: trusted,
        allowedOrigins: const ['https://hmi.svn.local'],
      );
      final pinned = _pinnedClient(trusted.rootPath);
      final panel = _supervisor(
        Uri.parse('wss://localhost:${gateway.port}'),
        // The pinned root, so the *only* thing wrong with this dial is who it
        // says it comes from. Without it the handshake would fail first and
        // the case would measure the arm above all over again.
        (uri) => _dialAsBrowser(uri, 'https://evil.example', client: pinned),
      );

      await _until('the refusal to be recorded',
          () => panel.lastDownReason != null);

      expect(panel.lastDownReason, contains('403'),
          reason: 'the status is the only thing in this failure that names '
              'what is wrong, and 06-03 measured it surviving into the '
              'message');
      expect(panel.lastDownReason, isNot(contains('certificate')),
          reason: 'a wrong origin is not a trust problem. Reporting it as one '
              'sends somebody to re-provision a root on a station whose root '
              'is fine');

      // Anti-vacuity: the same gateway, the same pinned root, no Origin
      // header — a panel gets through. Without this the case above would pass
      // against a gateway that refused everything for some other reason.
      final panelWithoutOrigin = _supervisor(
        Uri.parse('wss://localhost:${gateway.port}'),
        _Dials(pinned).call,
      );
      await _until('a panel with no Origin header to reach ready',
          () => panelWithoutOrigin.state == LinkState.ready);
    });
  });
}
