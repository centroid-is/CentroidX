@TestOn('vm')
@Tags(['ws', 'faults'])

/// The four TLS failure paths, driven through the fault proxy the rest of this
/// package already uses — so Phase 7's F1–F21 gate inherits them built rather
/// than discovering them under a deadline.
///
/// **Nothing in the proxy had to change, and that is the finding.** `FaultProxy`
/// is a loopback *byte* relay (`fault_proxy.dart:141-190`): it forwards through
/// a `DelayLine` and never looks at a frame, so ciphertext passes through
/// opaquely and `latency`, `throttle`, `flap`, `blackhole`, `killOnce` and
/// `reject` keep their meanings exactly (06-RESEARCH §C.4's mode table). The
/// only requirement is on the certificate: the panel dials
/// `wss://127.0.0.1:<proxy port>`, so the leaf's SAN has to cover `127.0.0.1`
/// as an `iPAddress` — which is what 06-01's `0x87` fix makes possible and what
/// `mintLeaf`'s default SANs already carry.
///
/// **One mode does change meaning, and the last group here measures it rather
/// than fixing it.** `cutMidFrame(n)` counts wire bytes
/// (`delay_line.dart:297,476,554`); under TLS those are ciphertext bytes, so a
/// cut lands inside a TLS record and the WebSocket layer never sees half an
/// application frame. See that group's own doc, and `fault_fixture.dart`'s
/// paragraph on which modes survive the change of layer.
///
/// **Every dial here is bounded.** An unreachable address costs 75 s on macOS
/// (06-RESEARCH §C.4, trap 17), and a blackholed *handshake* costs longer than
/// that — it never resolves at all, because the TCP connect succeeded and it is
/// the TLS handshake that is being swallowed. The direct probes pass
/// `connectTimeout:` to [connect]; every panel is built on a `ClientConfig`
/// whose `connectTimeout` is set, which is what bounds the dials the supervisor
/// makes for itself.
///
/// **No arm asserts *why* a handshake failed.** Trap 16: wrong CA, expired leaf
/// and wrong hostname produce byte-identical text. What names the cause is how
/// the arm is built — one input changed against a fixture that otherwise
/// connects — and the case name says which input.
///
/// **Every failure arm ends in a recovery.** A failure path that cannot be
/// recovered from is half a test, and recovery is what Phase 7's gate actually
/// asserts: the value the plant changed *during* the outage has to arrive after
/// it, which is the difference between a panel that reconnected and a panel
/// that re-rendered what it already had.
///
/// Without this file, Phase 7 discovers on the day of the gate that a TLS leg
/// through the proxy either does not stand up or stalls the lane for 75 s a
/// case — and the plant-side property nobody would then have measured is the
/// one that matters: a panel whose gateway certificate is wrong must keep
/// trying and must come back by itself the moment somebody replaces the file.
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fault_fixture.dart';
import 'support/permissive_resolver.dart';

/// The key every arm watches, character-identical to `fault_contract_test`'s.
///
/// One key rather than a page: these cases are about the transport underneath
/// the subscription, and a 314-key snapshot would only make each handshake
/// slower to judge.
const _key = 'ST101.CN01.MOT01.setpoint';

/// What the plant holds before the fault.
const _before = 1200;

/// What the plant is changed to *during* the outage.
///
/// The whole force of every recovery assertion: a client that reconnected and
/// re-delivered the value it already had would look identical without it.
const _after = 1500;

/// The ceiling on a direct probe dial (trap 17).
///
/// Generous against a handshake measured at tens of milliseconds, small against
/// the 75 s the operating system would otherwise spend. A hang guard, never a
/// measurement.
const Duration _dialBudget = Duration(seconds: 10);

/// The budget for "the panel got where it was going": a capped backoff draw, a
/// dial, a handshake, a hello and a snapshot.
///
/// Wider than `fault_contract_test`'s because two of these recoveries also
/// re-bind a gateway on the port the proxy is pointed at.
const Duration _recovery = Duration(seconds: 8);

/// The connect bound the blackhole arm sets deliberately.
///
/// Small on purpose and validated by `_positive` rather than `_atLeastFloor`
/// (06-05), so it can sit far below the deadline floor: what it bounds is the
/// dial, not a call.
const Duration _shortDial = Duration(milliseconds: 400);

// ---------------------------------------------------------------------------
// Certificates. `tfc_relay_server/test/support/certs.dart`'s wiring, over the
// same minter, copied for the reason 06-05 records: another package's `test/`
// directory is not addressable by any `package:` URI, and the minter itself is
// on the barrel.
// ---------------------------------------------------------------------------

/// A certificate authority a case can sign leaves under.
typedef _Ca = ({
  String certPem,
  String keyPem,
  Map<String, String> dn,
  RelayKeyPair keys,
});

({RelayKeyPair ca, RelayKeyPair leaf})? _pairs;

/// The one CA keypair and the one leaf keypair this isolate uses.
///
/// Generated on first call: ~364 ms of RSA (06-01), paid once per process,
/// after which every certificate below costs 3–18 ms. A lazy top-level rather
/// than a `setUpAll` for the reason 06-01 gives.
({RelayKeyPair ca, RelayKeyPair leaf}) _keyPairs() =>
    _pairs ??= (ca: generateKeyPair(), leaf: generateKeyPair());

/// A ten-year private root, the way the plant's is provisioned.
_Ca _mintCa() {
  final keys = _keyPairs().ca;
  final dn = {'CN': 'Relay Fault CA', 'O': 'Centroid'};
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
/// Signs with the leaf keypair rather than generating a third, exactly as
/// `mintForeignCa` does upstream: the property is that the panel has no copy of
/// this root, not that the key is a particular one.
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
/// The default SANs are `mintLeaf`'s, and the IP one is load-bearing here in a
/// way it is nowhere else: every dial in this file goes to the *proxy*, at
/// `127.0.0.1:<proxy port>`. A leaf whose IP SAN was written as a DNS string —
/// the defect 06-01's `0x87` branch exists for — would fail every case below
/// and pass every hostname case elsewhere.
///
/// [notAfter] in the past is how a case asks for an expired leaf: one argument
/// on the same keypair, never a second keygen.
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

/// Writes a chain, its key and a root into a fresh temp directory.
///
/// Under `Directory.systemTemp` and never inside the checkout, with the
/// recursive delete registered at acquisition (`ws_harness.dart:239-244`): a
/// case that fails an assertion before its own cleanup line still takes the
/// private key off the machine, and no run can leave a `.pem` where `git add`
/// would find it.
FaultTls _mount({required String chainPem, required String rootPem}) {
  final dir = Directory.systemTemp.createTempSync('relay-tls-fault-');
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
// Probes. The panel is the subject of every case; these read the *shape* of a
// refusal, which a panel only ever hands out as a sentence.
// ---------------------------------------------------------------------------

/// An `HttpClient` pinning [rootPath] and nothing else — the panel's posture,
/// for a probe that dials without building a whole panel.
HttpClient _pinnedClient(String rootPath) {
  final client = HttpClient(
    context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(rootPath),
  );
  addTearDown(() => client.close(force: true));
  return client;
}

/// Dials [url] once through the production transport and requires a refusal.
///
/// [connect] is the code under test rather than a convenience: it is what
/// drains the second copy of the exception off the stream, and an arm that
/// hand-rolled the dial would be measuring a socket this client never opens.
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

/// Anti-vacuity: proves the listener [port] forwards to is genuinely TLS.
///
/// Dialling `wss://` at a *plaintext* listener also raises a
/// `HandshakeException` (06-03 "measured facts" §4), so "the pinned panel was
/// refused" is equally consistent with "there was no TLS gateway back there at
/// all" — and through a proxy it is also consistent with "the proxy forwarded
/// nowhere". A `ws://` dial coming back `HttpException` rules out both.
Future<void> _assertServesTls(int port) async {
  final attempt = await _refused('ws://127.0.0.1:$port');
  expect(
    (attempt.error as WebSocketChannelException).inner,
    isA<HttpException>(),
    reason: 'the proxy has to be forwarding to a wss listener before its '
        'refusal of a pinned panel means anything',
  );
}

/// The exception shape every TLS refusal arrives in, asserted without ever
/// asking *why* (trap 16).
void _expectHandshakeRefusal(ConnectFailed attempt, {required String reason}) {
  expect(attempt.error, isA<WebSocketChannelException>(), reason: reason);
  expect((attempt.error as WebSocketChannelException).inner,
      isA<HandshakeException>(),
      reason: reason);
  expect(attempt.closeCode, isNull,
      reason: 'the refusal happens before the upgrade, so there is no '
          'WebSocket and never will be a code; anything reading one here would '
          'report a clean disconnect to an operator whose panel never '
          'connected');
}

/// Replaces the gateway's certificate the way the plant does: new files, same
/// address, gateway restarted.
///
/// The port is reused deliberately. A certificate problem is fixed on the
/// *server* — 06-05's `_refusalReason` doc is explicit that this is why the
/// panel keeps retrying rather than stopping — so the recovery that matters is
/// the one where nobody touches the panel at all. Re-binding the same port is
/// what makes the proxy (whose `targetPort` is fixed at construction) still
/// point at the replacement.
Future<void> _reissue(FaultFixture fixture, FaultTls good) async {
  final port = fixture.server.port;
  await fixture.server.close();
  final replacement = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: fixture.served,
    config: ServerConfig(
      tick: ServerConfig.minTick,
      port: port,
      tls: TlsConfig(chainPath: good.chainPath, keyPath: good.keyPath),
    ),
    onError: (_, __, ___) {},
  );
  addTearDown(replacement.close);
  await replacement.start();
}

/// Watches the panel's link so a case can say "it went down, and it came back".
///
/// Every case that builds one attaches it while the panel is **already**
/// `ready`, so a transition to anything else is a genuine drop and is counted
/// as one. An earlier draft counted a drop only once it had seen a `ready` of
/// its own, which made `downs` silently zero for exactly those cases — the
/// vacuous reading a `downs, isZero` assertion cannot tell from the real one.
final class _Link {
  _Link(RemoteStateMan panel) {
    final states = panel.linkStates.listen((state) {
      if (state == LinkState.ready) {
        readys++;
      } else {
        downs++;
      }
    });
    addTearDown(states.cancel);
  }

  int readys = 0;
  int downs = 0;
}

void main() {
  group('a gateway the panel cannot verify, behind the fault proxy', () {
    late _Ca ca;

    setUp(() => ca = _mintCa());

    test('a wrong-CA gateway behind the proxy is refused', () async {
      // One thing differs from a fixture that connects: who signed the leaf.
      // The mount carries the impostor's chain and the panel's own root, which
      // is what makes this a MITM on the plant LAN rather than a
      // misconfiguration (T-06-34).
      final impostor = _mount(
        chainPem: _mintLeaf(ca: _mintForeignCa()),
        rootPem: ca.certPem,
      );
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: impostor,
        seed: (plant) => plant.setValue(_key, _before),
      );
      await _assertServesTls(fixture.proxy.port);

      // The shape, from a probe: a panel only ever hands out a sentence, and
      // Phase 7's gate needs the exception class it came from.
      _expectHandshakeRefusal(
        await _refused('wss://127.0.0.1:${fixture.proxy.port}',
            client: _pinnedClient(impostor.rootPath)),
        reason: 'a man in the middle presenting a certificate some other '
            'authority signed must not reach the panel at all, and a proxy in '
            'the path must not change that — it relays ciphertext, it does not '
            'get a vote',
      );

      // The panel's own reading of the same failure.
      await until('the panel to record the refusal',
          () => fixture.client.lastDownReason != null);
      expect(fixture.client.lastDownReason, contains('certificate'),
          reason: '"the gateway did not answer" is actively wrong here: the '
              'gateway answered, at length, and the panel refused to believe '
              'it. An integrator reading that sentence checks the cable, the '
              'switch and the service before anybody thinks of the leaf');
      expect(fixture.client.isReady, isFalse,
          reason: 'a panel that reached ready against an impostor would be '
              'rendering that impostor\'s numbers as the plant\'s');

      // Recovery: the file on the gateway is replaced and nobody touches the
      // panel. The value changes while it is down, so a client that merely
      // re-rendered what it had cannot pass this.
      fixture.served.setValue(_key, _after);
      await _reissue(
          fixture, _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem));

      await until(
          'the panel to come back by itself once the gateway was re-issued',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
      expect(fixture.client.isReady, isTrue,
          reason: 'the value arrived but the panel is not back at ready, so '
              'the next call an operator makes still waits on the barrier');
    });

    test('an expired leaf behind the proxy is refused', () async {
      // One thing differs from the arm above: the validity window, on a leaf
      // the panel's own CA signed. The two are indistinguishable to the panel
      // — which is exactly why neither of them asserts a message.
      final now = DateTime.now().toUtc();
      final lapsed = _mount(
        chainPem: _mintLeaf(
          ca: ca,
          notBefore: now.subtract(const Duration(days: 400)),
          notAfter: now.subtract(const Duration(days: 1)),
        ),
        rootPem: ca.certPem,
      );
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: lapsed,
        seed: (plant) => plant.setValue(_key, _before),
      );
      await _assertServesTls(fixture.proxy.port);

      _expectHandshakeRefusal(
        await _refused('wss://127.0.0.1:${fixture.proxy.port}',
            client: _pinnedClient(lapsed.rootPath)),
        reason: 'the yearly re-issue is a Tuesday ticket only because a lapsed '
            'leaf stops the panels loudly; one that still connected would make '
            'the expiry alarm advisory',
      );

      await until('the panel to record the refusal',
          () => fixture.client.lastDownReason != null);
      expect(fixture.client.lastDownReason, contains('certificate'),
          reason: 'the operator consequence is the same as the arm above and '
              'so is the fix\'s shape — a file on the gateway — which is why '
              'both readings have to name the certificate rather than the '
              'link');

      fixture.served.setValue(_key, _after);
      await _reissue(
          fixture, _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem));

      await until('the panel to come back once the leaf was re-issued',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
      expect(fixture.client.isReady, isTrue);
    });
  });

  group('a handshake the proxy will not let finish', () {
    late _Ca ca;
    late FaultTls mounted;

    setUp(() {
      ca = _mintCa();
      mounted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
    });

    // Named for what it measures, which is not what it was written to
    // measure: the arm was called "…and is not a trust problem" until the
    // panel said otherwise. See the finding below.
    test('a cut inside the handshake is refused, and reads as a certificate '
        'problem', () async {
      // `cutMidFrame(1)` armed before the first dial: one byte of the
      // gateway's answer arrives and the connection ends with a FIN, which
      // lands inside the ServerHello. Sticky, so every redial meets it too —
      // and the recovery below is what disarms it. Either a
      // `HandshakeException` or a `SocketException` is correct here and the
      // case pins neither: which one wins is a race between the TLS state
      // machine and the socket, and pinning it would be pinning the race.
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mounted,
        armBeforeDial: (proxy) => proxy.cutMidFrame(1),
        seed: (plant) => plant.setValue(_key, _before),
      );

      final attempt = await _refused('wss://127.0.0.1:${fixture.proxy.port}',
          client: _pinnedClient(mounted.rootPath));
      expect(attempt.error, isA<WebSocketChannelException>());
      expect(
          (attempt.error as WebSocketChannelException).inner,
          anyOf(isA<HandshakeException>(), isA<SocketException>(),
              isA<TlsException>()),
          reason: 'a link cut in the middle of a handshake has to fail the '
              'dial, whichever half of the stack notices first');
      expect(attempt.closeCode, isNull);

      await until('the panel to record the cut',
          () => fixture.client.lastDownReason != null);
      // **A finding, pinned as it stands rather than as it ought to read.**
      // Measured three times, byte-identical: `the gateway's certificate was
      // not trusted by this panel: WebSocketChannelException:
      // HandshakeException: Connection terminated during handshake`. dart:io
      // raises `HandshakeException` for a link that dies *inside* a handshake
      // as well as for a leaf it will not verify, and `_refusalReason`
      // (06-05) branches on the class alone — so a cut cable and a man in the
      // middle read identically on the operator's health line, and the
      // integrator is sent to re-provision a root on a station whose root is
      // fine while the actual fault is a switch. 06-05's handoff asks later
      // plans to keep the four readings distinguishable; this is a fifth
      // shape it had not measured, and it collapses into the first.
      //
      // Not fixed here, deliberately: `connection_supervisor.dart` is outside
      // this plan's files, and narrowing that branch changes a sentence an
      // operator acts on — a decision, not a typo. Pinned so that the day
      // somebody does narrow it, this case says a plan depended on the old
      // text and makes them look at why.
      expect(
          fixture.client.lastDownReason,
          allOf(contains('certificate'),
              contains('Connection terminated during handshake')),
          reason: 'the reading has to keep carrying the original OS text: it '
              'is the only part of this a support engineer can act on '
              'remotely, and here it is the ONLY part that distinguishes a '
              'cut link from an impostor');

      // Recovery, and the anti-vacuity control in one: the same listener, the
      // same pinned root, the cut disarmed — the panel connects, so the
      // refusals above were the cut and not a gateway that never worked.
      fixture.served.setValue(_key, _after);
      fixture.proxy.cutMidFrame(null);

      await until('the panel to reconnect once the link stopped being cut',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
      expect(fixture.client.isReady, isTrue);
    });

    test('a blackholed handshake is bounded by the connect timeout', () async {
      // The arm that proves the bound is wired, and the one case in this file
      // that would not merely be slow without it but would never resolve at
      // all: the TCP connect *succeeds* — the proxy accepts and dials upstream
      // — and it is the TLS handshake that is swallowed, in both directions,
      // for as long as the lever is held. `connectTimeout:` is the only thing
      // that ends it (trap 17, pitfall 6).
      final elapsed = Stopwatch()..start();
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mounted,
        armBeforeDial: (proxy) => proxy.blackhole(),
        connectTimeout: _shortDial,
        seed: (plant) => plant.setValue(_key, _before),
      );

      await until('the abandoned dial to be reported',
          () => fixture.client.lastDownReason != null,
          budget: const Duration(seconds: 5));
      elapsed.stop();

      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'a dial into a blackhole that is not bounded never comes '
              'back: the operator watches a panel that says nothing while the '
              'reconnect loop it is supposed to be running has not made its '
              'second attempt, and in the suite it costs the lane its whole '
              'budget');
      expect(fixture.client.isReady, isFalse);
      expect(fixture.client.lastDownReason, isNot(contains('certificate')),
          reason: 'a link that swallows the handshake is not a certificate '
              'problem, and the two have entirely different fixes');

      // Recovery: the lever is lifted and the panel's next scheduled attempt
      // gets through. Nothing about the panel changed.
      fixture.served.setValue(_key, _after);
      fixture.proxy.blackhole(enabled: false);

      await until('the panel to connect once the handshake was let through',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
      expect(fixture.client.isReady, isTrue);
    });
  });

  group('shaping ciphertext shapes the link, and nothing more', () {
    late _Ca ca;
    late FaultTls mounted;

    setUp(() {
      ca = _mintCa();
      mounted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
    });

    test('latency and a throttle under TLS leave the link up and the values '
        'flowing', () async {
      // §C.4's table says these three are unchanged under TLS because the
      // proxy shapes ciphertext and the observable at the peer is the same.
      // That is a claim worth one measurement rather than an assumption: it is
      // what lets Phase 7 reuse F13's numbers over wss without re-deriving
      // them.
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mounted,
        seed: (plant) => plant.setValue(_key, _before),
      );
      await until('the pinned link', () => fixture.client.isReady);
      // Anti-vacuity: an arm about shaping *ciphertext* proves nothing if the
      // link underneath it turned out to be plaintext.
      await _assertServesTls(fixture.proxy.port);
      final link = _Link(fixture.client);

      fixture.proxy.latency = const Duration(milliseconds: 15);
      fixture.proxy.throttleBytesPerSec = 4 * 1024 * 1024;
      fixture.served.setValue(_key, _after);

      await until('the shaped link to deliver the change',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);

      expect(link.downs, isZero,
          reason: 'a slow link is slow, not down (F13). A panel that dropped '
              'and resynced on 15 ms of added latency would spend a bad shift '
              'reconnecting, and every reconnect is a snapshot the gateway has '
              'to build for it');
      expect(fixture.client.isReady, isTrue);
    });

    test('a flapping TLS link comes back by itself', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mounted,
        seed: (plant) => plant.setValue(_key, _before),
      );
      await until('the pinned link', () => fixture.client.isReady);
      await _assertServesTls(fixture.proxy.port);
      final link = _Link(fixture.client);
      expect(fixture.client.read(_key)?.value, _before,
          reason: 'the page was not live before the flap, so nothing below is '
              'about a recovery');

      fixture.proxy.flap(
          const Duration(milliseconds: 120), const Duration(milliseconds: 80));
      await until('the flap to take the link down at least once',
          () => link.downs >= 1);

      fixture.proxy.flap(Duration.zero, Duration.zero, enabled: false);
      fixture.served.setValue(_key, _after);

      await until('the panel to resync after the link stopped flapping',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
      expect(link.readys, greaterThanOrEqualTo(1),
          reason: 'a TLS link that flaps has to reconnect on the ordinary '
              'backoff schedule like a plaintext one — the handshake is one '
              'more round trip inside the same attempt, not a different '
              'recovery path');
    });
  });

  // -------------------------------------------------------------------------
  // The one mode whose meaning TLS changes. Measured, not fixed.
  // -------------------------------------------------------------------------

  /// `cutMidFrame(n)` counts **wire** bytes (`delay_line.dart:297,476,554`),
  /// and on a TLS leg those are ciphertext. So `n` does not select a prefix of
  /// an application frame: it selects a prefix of a TLS *record*, and a record
  /// that never completed is discarded whole — the WebSocket layer, and
  /// therefore the JSON decoder, never sees any of it.
  ///
  /// That is TLS doing exactly its job. A record is authenticated as a unit;
  /// handing up half of one would mean handing up unauthenticated bytes, which
  /// is the property the whole phase is here to buy. The mode is not broken
  /// under TLS, it is **measuring a different layer** — and the intent it was
  /// written for (deliver half a JSON frame to the decoder, `plan 02-07`) is
  /// unreachable through a TLS proxy at any `n`.
  ///
  /// The instrument that still reaches the decoder is `FrameSeam`, one layer
  /// up, which is where `truncated_write_test.dart` and
  /// `malformed_contract_test.dart` drive their truncations from and where they
  /// must stay. Do not "fix" this by teaching the proxy to corrupt bytes:
  /// `ws_fault_test.dart:32-34` says why, and this group is the measurement
  /// that says the fix would be aimed at the wrong layer anyway.
  group('a cut lands in a TLS record, not in an application frame', () {
    test('a cut inside a TLS record delivers no application bytes at all',
        () async {
      final ca = _mintCa();
      final mounted = _mount(chainPem: _mintLeaf(ca: ca), rootPem: ca.certPem);
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mounted,
        seed: (plant) => plant.setValue(_key, _before),
      );
      await until('the pinned link', () => fixture.client.isReady);
      expect(fixture.client.read(_key)?.value, _before,
          reason: 'the page was not live before the cut, so nothing below is '
              'about what the cut did');
      final link = _Link(fixture.client);

      // 64 bytes: comfortably inside the record the update below will travel
      // in, and far more than a plaintext leg would need to put a recognisable
      // fragment of `{"method":"u",...}` into the decoder.
      fixture.proxy.cutMidFrame(64);
      fixture.served.setValue(_key, _after);

      await until('the cut to end the transport', () => link.downs >= 1);

      expect(fixture.client.read(_key)?.value, _before,
          reason: '64 bytes crossed the wire and ZERO reached the decoder. '
              'That is the whole finding: under TLS the cut lands inside a '
              'record, the record is discarded as a unit, and the panel is '
              'left holding the last value it was told rather than a '
              'half-parsed one. An operator seeing a stale number that is '
              'marked stale is the outcome this project is built for; an '
              'operator seeing half a number is the one it forbids');
      expect(fixture.client.complaints, isEmpty,
          reason: 'a truncated record must not surface as a page problem — '
              'nothing is wrong with the key list, the link died');
      expect(fixture.client.lastDownReason, isNot(contains('FormatException')),
          reason: 'if a partial frame had reached the JSON decoder this is '
              'where it would show, and it is the reading that would send '
              'somebody hunting an encoding bug instead of a cut cable');

      // Recovery, and the control that makes the assertion above mean
      // something: with the cut lifted the very same update crosses the very
      // same link and arrives whole. Whole record or nothing — never half.
      fixture.proxy.cutMidFrame(null);
      await until('the panel to resync once the link stopped being cut',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
      expect(fixture.client.isReady, isTrue);
    });
  });
}
