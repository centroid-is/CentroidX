@TestOn('vm')
@Tags(['ws'])

/// The gateway over TLS, judged by what a panel's socket does with it.
///
/// SEC-02's server half. Every case here varies **exactly one thing** against
/// the same fixture — the leaf, the root the client pins, or the scheme — and
/// asserts the exception *class* rather than its message, because 06-RESEARCH
/// §A.3 measured all three TLS rejections producing byte-identical text
/// (`CERTIFICATE_VERIFY_FAILED: application verification failure`) with a null
/// close code (trap 16). What names the cause is how the arm is built, not
/// what the error says.
///
/// Two arms are distinguishable and both are here for the same reason 06-05's
/// failure classification will need them: a plaintext `ws://` dial against a
/// wss listener surfaces an `HttpException`, not a `HandshakeException`, and a
/// gateway whose PEM path is misspelled **fails to start** rather than quietly
/// serving `ws://`. A silent downgrade is the worst outcome available here —
/// the plant would carry on working, in cleartext, and nobody would know until
/// somebody ran a packet capture.
///
/// Every dial passes `connectTimeout:`. An unreachable address takes 75 s to
/// fail on macOS (trap 17), and one such case on its own blows the three
/// minute lane budget `handler_table_test.dart` owns.
///
/// Certificates are minted through `test/support/certs.dart`, never by hand:
/// the first `certKeyPairs()` call in a suite costs ~364 ms of RSA and every
/// certificate after it is 3–18 ms, and a hand-rolled leaf is how the IP-SAN
/// defect (trap 12) gets back in through a hostname-only dial.
///
/// Without this file the gateway can ship speaking cleartext on the plant LAN
/// and every panel would still work.
library;

import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/tls/tls_config.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/certs.dart';
import 'support/permissive_resolver.dart';

/// The ceiling on any dial in this file (trap 17).
///
/// Generous against a cold RSA handshake (42 ms measured) and small against
/// the 75 s the operating system would otherwise spend on a dial that cannot
/// complete. It is a hang guard, not a measurement.
const _dialBudget = Duration(seconds: 10);

/// The ceiling on a hello over an established socket.
///
/// The tick is the response pump at 50 ms, so this is forty ticks of slack.
const _requestBudget = Duration(seconds: 5);

void main() {
  /// A gateway with [tls] applied, torn down whatever happens to it.
  ///
  /// `close()` is registered at acquisition rather than after a successful
  /// `start()`: the misspelled-path case deliberately fails the start, and a
  /// server that never bound must still release its registry.
  RelayServer buildServer({TlsConfig? tls}) {
    final served = FakeStateMan();
    final server = RelayServer(
      resolver: const PermissiveSeriesResolver(),
      api: served,
      config: ServerConfig(tick: ServerConfig.minTick, tls: tls),
      // Provoked failures are the subject of this file; a collector that
      // printed each one would train everyone to scroll past them.
      onError: (_, __, ___) {},
    );
    addTearDown(() async {
      await server.close();
      await served.dispose();
    });
    return server;
  }

  /// A client pinning [rootPem] and nothing else — the panel's posture.
  ///
  /// `withTrustedRoots: false` is the whole of SEC-02 on this side: a client
  /// that also carried the public web roots would accept any certificate a
  /// public CA could be talked into issuing for the gateway's name.
  HttpClient pinnedClient(String rootPem) {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(rootPem.codeUnits);
    final client = HttpClient(context: context);
    addTearDown(() => client.close(force: true));
    return client;
  }

  /// Dials [url], with [customClient] when the case pins something.
  ///
  /// A null [customClient] is not an omission — it is the **system trust
  /// store** arm, because `WebSocket.connect` then builds its own default
  /// `HttpClient`.
  WebSocketChannel dial(String url, {HttpClient? customClient}) {
    final ws = IOWebSocketChannel.connect(
      Uri.parse(url),
      customClient: customClient,
      connectTimeout: _dialBudget,
    );
    addTearDown(() => ws.sink.close().catchError((Object _) {}));
    return ws;
  }

  /// The error a refused dial produced, with the stream copy drained.
  ///
  /// §A.3 measured the same exception arriving twice: once from `ready` and
  /// once queued on the stream. The second copy has to be consumed here or it
  /// lands in the ambient isolate and `package:test` attributes it to whatever
  /// case happens to be running when it arrives.
  Future<Object> refusedDial(String url, {HttpClient? customClient}) async {
    final ws = dial(url, customClient: customClient);
    ws.stream.listen(null, onError: (Object _) {}, cancelOnError: true);
    try {
      await ws.ready;
    } catch (error) {
      return error;
    }
    fail('$url completed a handshake it had no business completing');
  }

  /// Anti-vacuity: proves the listener on [port] is genuinely speaking TLS.
  ///
  /// A rejection arm whose server never bound wss at all would pass for the
  /// wrong reason — dialling `wss://` at a *plaintext* listener also raises a
  /// `HandshakeException`, so "refused" would be evidence about nothing. The
  /// arms whose server is not also the subject of a successful pinned dial
  /// call this first.
  Future<void> assertServesTls(int port) async {
    final error = await refusedDial('ws://localhost:$port');
    expect((error as WebSocketChannelException).inner, isA<HttpException>(),
        reason: 'this listener has to be a wss listener before its refusal of '
            'a pinned client means anything');
  }

  /// Says hello over [ws], which is how a case proves it reached the gateway
  /// rather than merely opening a socket to something.
  Future<HelloResult> helloOver(WebSocketChannel ws) async {
    final peer = rpc.Client(wsChannel(ws));
    addTearDown(() => peer.close().catchError((Object _) {}));
    unawaited(peer.listen().catchError((Object _) => null));
    final raw = await peer
        .sendRequest(
            Methods.hello,
            HelloParams(
              protocol: protocolVersion,
              supported: const [protocolVersion],
              client: const PeerInfo('panel-under-test', '0.1.0'),
            ).toJson())
        .timeout(_requestBudget);
    return HelloResult.fromJson((raw as Map).cast<String, Object?>());
  }

  group('the gateway binds wss from mounted files', () {
    late TestCa ca;
    late CertFixture mounted;
    late RelayServer server;

    setUp(() async {
      ca = mintCa();
      mounted = writeCertFixture(
        chainPem: mintLeaf(ca: ca),
        keyPem: leafKeyPem(),
        rootPem: ca.certPem,
      );
      server = buildServer(
          tls: TlsConfig(
              chainPath: mounted.chainPath, keyPath: mounted.keyPath));
      await server.start();
    });

    test('a pinned client connects to the gateway by hostname', () async {
      final ws = dial('wss://localhost:${server.port}',
          customClient: pinnedClient(ca.certPem));
      await ws.ready.timeout(_dialBudget);

      final hello = await helloOver(ws);
      expect(hello.protocol, protocolVersion,
          reason: 'a socket that opened but cannot answer hello is a TLS '
              'listener with no gateway behind it — the operator sees a panel '
              'that connects and then shows nothing');
    });

    test('a pinned client connects to the gateway by IP literal', () async {
      // The arm 06-01's 0x87 fix exists for. The plant dials
      // 10.104.29.71-style literals, and a leaf whose IP SAN was written as a
      // DNS string passes the hostname arm above and fails only here.
      final ws = dial('wss://127.0.0.1:${server.port}',
          customClient: pinnedClient(ca.certPem));
      await ws.ready.timeout(_dialBudget);

      final hello = await helloOver(ws);
      expect(hello.protocol, protocolVersion,
          reason: 'panels are configured with the gateway\'s address, not its '
              'name; a gateway reachable only by hostname is a gateway no '
              'panel on the plant floor can reach');
    });

    test('a leaf from a different CA is refused', () async {
      final foreign = mintForeignCa();
      final elsewhere = writeCertFixture(
        chainPem: mintLeaf(ca: foreign),
        keyPem: leafKeyPem(),
      );
      final impostor = buildServer(
          tls: TlsConfig(
              chainPath: elsewhere.chainPath, keyPath: elsewhere.keyPath));
      await impostor.start();
      await assertServesTls(impostor.port);

      final error = await refusedDial('wss://localhost:${impostor.port}',
          customClient: pinnedClient(ca.certPem));

      expect(error, isA<WebSocketChannelException>(),
          reason: 'a man in the middle presenting a certificate some other '
              'authority signed must not reach the panel at all');
      expect((error as WebSocketChannelException).inner,
          isA<HandshakeException>(),
          reason: 'the refusal must happen in the TLS handshake, before the '
              'upgrade — anything the impostor could answer after that point '
              'is already trusted');
    });

    test('an expired leaf from the trusted CA is refused', () async {
      final now = DateTime.now().toUtc();
      final stale = writeCertFixture(
        chainPem: mintLeaf(
          ca: ca,
          notBefore: now.subtract(const Duration(days: 400)),
          notAfter: now.subtract(const Duration(days: 1)),
        ),
        keyPem: leafKeyPem(),
      );
      final lapsed = buildServer(
          tls:
              TlsConfig(chainPath: stale.chainPath, keyPath: stale.keyPath));
      await lapsed.start();
      await assertServesTls(lapsed.port);

      final error = await refusedDial('wss://localhost:${lapsed.port}',
          customClient: pinnedClient(ca.certPem));

      expect(error, isA<WebSocketChannelException>());
      expect((error as WebSocketChannelException).inner,
          isA<HandshakeException>(),
          reason: 'the yearly re-issue is a Tuesday ticket only because a '
              'lapsed leaf stops the panels loudly; one that still connected '
              'would make the expiry alarm advisory');
    });

    test('the gateway\'s own leaf is refused by a client on the system roots',
        () async {
      // Same server, same leaf, same address — only the trust store changes.
      // Non-vacuous without a control dial of its own: the hostname arm above
      // shares this `setUp`'s server and proves it completes a pinned
      // handshake, so a refusal here can only be the trust store.
      final error = await refusedDial('wss://localhost:${server.port}');

      expect(error, isA<WebSocketChannelException>());
      expect((error as WebSocketChannelException).inner,
          isA<HandshakeException>(),
          reason: 'the private root is provisioned to plant machines on '
              'purpose; if the public web roots were enough to reach this '
              'gateway, the pinning would be decoration');
    });

    test('a plaintext ws dial against the wss listener fails as HTTP, not TLS',
        () async {
      final error = await refusedDial('ws://localhost:${server.port}');

      expect(error, isA<WebSocketChannelException>());
      final inner = (error as WebSocketChannelException).inner;
      expect(inner, isA<HttpException>(),
          reason: 'this is the one failure shape distinguishable from a '
              'certificate problem, and 06-05 needs it to tell "the panel is '
              'configured for the wrong scheme" from "the panel does not '
              'trust us"');
      expect(inner, isNot(isA<HandshakeException>()));
    });
  });

  group('the two ways TLS is absent are not the same thing', () {
    test('a misspelled certificate path fails the start, it does not serve ws',
        () async {
      final ca = mintCa();
      final mounted = writeCertFixture(
        chainPem: mintLeaf(ca: ca),
        keyPem: leafKeyPem(),
      );
      final server = buildServer(
        tls: TlsConfig(
          chainPath: '${mounted.chainPath}.typo',
          keyPath: mounted.keyPath,
        ),
      );

      await expectLater(
          server.start(),
          throwsA(isA<FileSystemException>()),
          reason: 'a gateway that answered a missing PEM by binding ws:// '
              'would carry the whole plant\'s traffic in cleartext and every '
              'panel would keep working — the mistake is only discovered by a '
              'packet capture, months later');
    });

    test('a gateway with no tls config still serves plaintext ws', () async {
      // Amendment 6, as a case: `tls == null` is the default, and it is what
      // keeps every existing bind/dial fixture in this package plaintext on
      // loopback with an ephemeral port.
      final server = buildServer();
      await server.start();

      final ws = dial('ws://127.0.0.1:${server.port}');
      await ws.ready.timeout(_dialBudget);

      final hello = await helloOver(ws);
      expect(hello.protocol, protocolVersion,
          reason: 'ten fixture sites construct a ServerConfig with no TLS '
              'argument; making TLS the default would rewrite all ten for no '
              'requirement, and a rewritten fixture is how a suite quietly '
              'stops testing what it used to');
    });

    test('the default config is plaintext, loopback and an ephemeral port',
        () async {
      final config = ServerConfig();

      expect(config.tls, isNull,
          reason: 'the default must be an explicit choice somebody makes in a '
              'config diff, never something a fixture inherits');
      expect(config.address, InternetAddress.loopbackIPv4,
          reason: 'exposing the gateway on a public interface is a deployment '
              'decision with a firewall attached to it (T-03-11)');
      expect(config.port, 0,
          reason: 'port 0 is why two servers can run in one test process '
              'without agreeing on a number');
    });
  });

  group('TlsConfig refuses what cannot be mounted', () {
    test('an empty chain path is refused at construction', () {
      expect(
          () => TlsConfig(chainPath: '', keyPath: '/tmp/key.pem'),
          throwsA(isA<ArgumentError>().having(
              (e) => e.toString(), 'message', contains('chainPath'))),
          reason: 'an empty path reaches SecurityContext as the current '
              'directory and fails with a message about a directory nobody '
              'configured');
    });

    test('an empty key path is refused at construction', () {
      expect(
          () => TlsConfig(chainPath: '/tmp/chain.pem', keyPath: ''),
          throwsA(isA<ArgumentError>()
              .having((e) => e.toString(), 'message', contains('keyPath'))),
          reason: 'a gateway with a chain and no key cannot complete a single '
              'handshake, and the failure arrives one panel at a time');
    });
  });
}
