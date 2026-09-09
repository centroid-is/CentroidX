/// F15: a gateway the panel will not believe, and the loop that must not
/// hammer it.
///
/// **F15 — TLS handshake failure.** Injection: proxy to a plain-TCP port /
/// wrong cert. Expect: clear terminal error, no reconnect-forever at full speed
/// against a misconfigured endpoint.
///
/// **The row's operational teeth are F15d, and they are not about TLS at all.**
/// Four of the six arms below assert that a handshake fails and that the panel
/// says so, which Phase 6 already pinned directly. What no file in this
/// repository stated before this one is the clause an operator actually feels:
/// a panel pointed at a gateway whose certificate is wrong must **back off**,
/// not spin. That is a property of `connection_supervisor.dart`'s schedule, and
/// F15d measures it against a bound computed from the backoff schedule.
///
/// **Assert the union, never the discrimination.** 06-RESEARCH §A.3 measured
/// that a foreign CA, an expired leaf, a SAN that does not cover the address
/// and a private leaf against the system roots all produce a byte-identical
/// `WebSocketChannelException` wrapping `HandshakeException` with
/// `CERTIFICATE_VERIFY_FAILED: application verification failure`, `closeCode`
/// null, in one to twenty-two milliseconds. A case asserting three different
/// messages would be asserting a fiction. One expected shape, three bindings —
/// and that *is* the finding, printed by the arms below rather than only
/// claimed here.
///
/// **06-07 measured a fifth shape that collapses into the first, and this file
/// inherits it.** `dart:io` raises `HandshakeException` for a link that dies
/// *inside* a handshake as well as for a leaf it refuses to verify, and
/// `_refusalReason` (`connection_supervisor.dart:384-406`) branches on the
/// class alone — so a cut cable and an impostor read identically on the health
/// line. The discriminator is in the text (`Connection terminated during
/// handshake` versus `CERTIFICATE_VERIFY_FAILED`) and nothing here asserts on
/// it: narrowing that branch changes a sentence an operator acts on, which is a
/// decision and not a typo. F15e therefore asserts the **union** of
/// `HandshakeException` and `SocketException`, and the gap is in the deviations
/// registry against F15's `clear terminal error`.
///
/// **What Phase 6 already asserts, cited rather than repeated.** The gate's job
/// is the pipe, not the handshake:
///
///  - `test/tls_client_test.dart` — the pinned dial, the system-roots refusal,
///    and the `CERTIFICATE_VERIFY_FAILED` text itself.
///  - `test/tls_fault_test.dart` — the same four shapes through the fault
///    proxy, each with a recovery driven by a value the plant changed during
///    the outage, plus the `cutMidFrame`-under-TLS boundary.
///  - `tfc_relay_server/test/tls_test.dart` — the `wss` bind and the
///    `assertServesTls` anti-vacuity pattern.
///
/// This file asserts only the half those cannot: what the *panel* does over
/// time when the handshake keeps failing.
///
/// **No arm asserts a `FailureKind.tlsRejected`, and none may be added.**
/// 06-PLAN-INDEX records the constant as deliberately not built:
/// `classifyFailure` sorts *call* failures and never sees a `ConnectAttempt`,
/// so the member would have no producer, and `grep -c tlsRejected` returning 0
/// is one of 06-05's own acceptance criteria. What Phase 6 shipped instead is
/// the link-state reason string, and that is what the arms below read.
///
/// **One `wss` smoke row, not a second lane.** 06-RESEARCH §C.4 measured
/// `latency`, `throttle`, `flap`, `blackhole`, `killOnce` and `reject` as
/// unchanged under TLS — the proxy is a byte relay and shapes ciphertext
/// without knowing it — so running all twenty-seven rows over `wss` would
/// double an eight-minute lane to re-prove a property already measured.
/// 07-CONTEXT orchestrator ruling 3 settles it: one smoke row proving the
/// fixture carries a full subscribe and resync, plus this family. The decision
/// to leave the other rows plaintext is in the deviations registry with that
/// measurement as its reason, because a scope decision nobody wrote down is
/// indistinguishable from an oversight.
///
/// **Two cases here are deliberately not F-rows**, and both are declared in
/// `gate_manifest_test.dart`'s supporting-case exemption with a written reason.
/// The smoke row proves the fixture; naming it `F1c` would claim a second F1
/// and break the 1:1 row mapping the whole manifest exists to hold. The auth
/// contrast is ROADMAP criterion 4's second clause and the *other side* of the
/// supervisor branch F15d sits on — it belongs beside F15 and belongs to no row.
///
/// Without this file the phase ships a gate that has never seen a TLS
/// handshake, and the plant-side property nobody measured is the one that
/// matters: a panel whose gateway certificate is wrong keeps trying, at a rate
/// that lets the gateway come back.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart' show AuthenticatedUser;
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_client/src/dial/pinned_dialer_io.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';
import '../support/gate_fixture.dart';
import '../support/permissive_resolver.dart';

/// How many keys the smoke row's page carries.
///
/// A page rather than a key: the row exists to prove the wss fixture carries a
/// whole subscribe and a whole resync, and a one-key snapshot would prove that
/// a handshake completed and nothing else. Fifty rather than `plantPage`'s
/// two hundred because the property is "the page came back", not "the page came
/// back at a rate" — this row is not a slow-link row and paying four times the
/// snapshot for the same claim would spend lane budget on nothing.
const int _pageKeys = 50;

/// What the plant holds before the drop.
const int _before = 1200;

/// What the plant is changed to *while the panel is down*.
///
/// The whole force of the smoke row: a panel that reconnected and re-rendered
/// the value it already had would look identical without it.
const int _after = 1500;

/// The budget for "the panel got where it was going" over `wss`.
const Duration _recovery = Duration(seconds: 15);

/// The ceiling on a direct probe dial (07-RESEARCH trap 19).
///
/// Generous against a handshake measured at tens of milliseconds, small against
/// the 75 s macOS would otherwise spend on an address that answers nothing. A
/// hang guard, never a measurement.
const Duration _dialBudget = Duration(seconds: 10);

/// How long an arm waits for the panel's first refusal to reach the health line.
///
/// A handshake refusal is 1-22 ms (06-RESEARCH §A.3); everything else in this
/// number is the panel's own construction and one backoff draw off a 40 ms base.
const Duration _refusalBudget = Duration(seconds: 5);

/// The backoff schedule F15d's ceiling is computed from, **restated rather
/// than read off the config the fixture builds**.
///
/// 07-04's lesson, restated by `connect_failure_gate_test.dart:66-76`, and it
/// is the whole value of the bound: a ceiling that recomputed itself from
/// whatever the client was actually handed would rise to meet a client that had
/// been made to hammer, which is the one failure it exists to catch. These two
/// must move together with `faultClientConfig`, and a reader who changes one is
/// meant to be stopped by this comment.
const Duration _backoffBase = Duration(milliseconds: 40);
const Duration _backoffCap = Duration(seconds: 2);

/// How long F15d and the auth contrast watch a panel cycling.
///
/// Four seconds is two full backoff ceilings plus the whole of the geometric
/// walk up to them, so the schedule is observed in both of its regimes — the
/// doubling and the cap. Shorter and the count is all walk; longer and the lane
/// pays for a number that stops changing shape.
const Duration _dialWindow = Duration(seconds: 4);

/// The connect bound F15f sets deliberately.
///
/// Small on purpose and validated by `_positive` rather than `_atLeastFloor`
/// (06-05), so it can sit far below the deadline floor: what it bounds is the
/// dial, not a call.
const Duration _shortDial = Duration(milliseconds: 400);

/// The key every arm watches, character-identical to the other gate files'.
///
/// One key rather than a page: these arms are about the transport underneath
/// the subscription, and a fifty-key snapshot would only make each recovery
/// slower to judge. The smoke row above is where the page is the point.
const String _key = scenarioKey;

// ---------------------------------------------------------------------------
// Certificates. `tfc_relay_server/test/support/certs.dart`'s wiring, over the
// same minter, copied for the reason 06-05 records and 06-07 restates: another
// package's `test/` directory is not addressable by any `package:` URI, and the
// minter itself is on the barrel.
//
// Minted lazily and reused for the isolate: one RSA keygen (~364 ms, 06-01) for
// the whole file, after which every certificate below is 3-18 ms. Every arm
// varies only the *binding* — who signed the leaf, when it expires, or whether
// the listener speaks TLS at all — which is what makes "the same shape" a claim
// about the shape rather than about the fixture.
// ---------------------------------------------------------------------------

/// A certificate authority a case can sign leaves under.
typedef _Ca = ({
  String certPem,
  String keyPem,
  Map<String, String> dn,
  RelayKeyPair keys,
});

({RelayKeyPair ca, RelayKeyPair leaf})? _pairs;

({RelayKeyPair ca, RelayKeyPair leaf}) _keyPairs() =>
    _pairs ??= (ca: generateKeyPair(), leaf: generateKeyPair());

_Ca _mintCa({
  required RelayKeyPair keys,
  required Map<String, String> dn,
}) {
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

/// The root the plant provisions to its panels.
_Ca _trustedCa() =>
    _mintCa(keys: _keyPairs().ca, dn: {'CN': 'Relay Gate CA', 'O': 'Centroid'});

/// A gateway leaf signed by [ca].
///
/// The IP SAN is load-bearing in this file in a way it is nowhere else: every
/// dial goes to the *proxy*, at `127.0.0.1:<proxy port>`. A leaf whose IP SAN
/// was written as a DNS string — the defect 06-01's `0x87` branch exists for —
/// would fail every case here and pass every hostname case elsewhere, which is
/// a fixture fault wearing a product fault's clothes.
///
/// [notAfter] in the past is how an arm asks for an expired leaf: one argument
/// on the same keypair, never a second keygen and never a second code path.
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
/// recursive delete registered at acquisition: a case that fails an assertion
/// before its own cleanup line still takes the private key off the machine, and
/// no run can leave a `.pem` where `git add` would find it. `find packages -name
/// '*.pem'` is 0 and 06-01, 06-09 and this file all depend on it staying 0.
FaultTls _mount({required String chainPem, required String rootPem}) {
  final dir = Directory.systemTemp.createTempSync('relay-tls-gate-');
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

/// The mount a panel pins [root] against while the gateway serves [chain].
///
/// The two halves are independent paths, which is what lets one record express
/// "the gateway's leaf is fine" and "the gateway's leaf was signed by somebody
/// else" without any other difference between the two fixtures.
FaultTls _mountOf(_Ca root, String chain) =>
    _mount(chainPem: chain, rootPem: root.certPem);

/// A root the panel does *not* carry — which is the whole of what makes a CA
/// foreign.
///
/// Signs with the leaf keypair rather than generating a third, exactly as
/// `mintForeignCa` does upstream: the property is that the panel has no copy of
/// this root, not that the key is a particular one.
_Ca _foreignCa() => _mintCa(
    keys: _keyPairs().leaf, dn: {'CN': 'Someone Else Entirely', 'O': 'Not Us'});

// ---------------------------------------------------------------------------
// Probes.
// ---------------------------------------------------------------------------

/// Dials [url] once through the production transport and requires a refusal.
///
/// [connect] is the code under test rather than a convenience: it is what
/// drains the second copy of the exception off the stream, and a probe that
/// hand-rolled the dial would be measuring a socket this client never opens.
///
/// [client] null is deliberately the **system trust store** posture:
/// `IOWebSocketChannel.connect` builds a default client of its own. That is the
/// arm that proves the pin is load-bearing.
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

/// An `HttpClient` pinning [rootPath] and nothing else — the panel's own
/// posture, for a probe that reads a refusal without standing up a panel.
HttpClient _pinnedClient(String rootPath) {
  final client = HttpClient(
    context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(rootPath),
  );
  addTearDown(() => client.close(force: true));
  return client;
}

/// A TLS gateway behind a fault proxy with **no panel**, and the proxy port.
///
/// For a binding that only a probe has to meet. F15b compares three bindings'
/// refusal messages and needs three listeners; standing up three whole fixtures
/// would also stand up three panels, each redialling its own backoff schedule
/// for the rest of the case against a gateway that will never answer — noise on
/// a shared event loop, in a file that measures dial rates two cases later.
Future<int> _listener(FaultTls mount) async {
  final plant = FakeStateMan();
  addTearDown(plant.dispose);
  plant.setValue(_key, _before);
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: plant,
    config: ServerConfig(
      tick: ServerConfig.minTick,
      tls: TlsConfig(chainPath: mount.chainPath, keyPath: mount.keyPath),
    ),
    onError: (_, __, ___) {},
  );
  await server.start();
  addTearDown(server.close);
  final proxy = FaultProxy(targetPort: server.port);
  await proxy.start();
  addTearDown(proxy.shutdown);
  return proxy.port;
}

/// The exception shape every certificate refusal arrives in, asserted without
/// ever asking *why*.
///
/// Trap 16, and the objective's instruction in one function: wrong CA, expired
/// leaf, SAN mismatch and system-roots-against-a-private-leaf are byte-identical
/// on this platform, so a helper that took a "cause" argument would be offering
/// a discrimination that does not exist. Returns the inner exception's text, so
/// the caller can compare bindings against each other — which is the only
/// honest thing to say about the difference between them.
String _expectCertificateRefusal(ConnectFailed attempt, {required String arm}) {
  expect(attempt.error, isA<WebSocketChannelException>(), reason: arm);
  final inner = (attempt.error as WebSocketChannelException).inner;
  expect(inner, isA<HandshakeException>(), reason: arm);
  expect(attempt.closeCode, isNull,
      reason: 'the refusal happens before the upgrade, so there is no '
          'WebSocket and never will be a code; anything reading one here would '
          'report a clean disconnect to an operator whose panel never '
          'connected ($arm)');
  return '$inner';
}

/// Replaces the gateway's certificate the way the plant does: new files, same
/// address, gateway restarted — and nobody touches the panel.
///
/// 06-07's `_reissue`, restated here because that file is a sibling and not an
/// import. The port is reused deliberately: a certificate problem is fixed on
/// the *server*, which is precisely why 06-05's `_refusalReason` keeps the panel
/// retrying instead of stopping it, and re-binding the same port is what keeps
/// the proxy (whose `targetPort` is fixed at construction) pointed at the
/// replacement.
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

/// How many dials a window of [_dialWindow] can hold under this schedule.
///
/// Full jitter draws uniformly from `[0, min(cap, base * 2^n))`, so attempt *n*
/// waits half that window on average, and the schedule only resets on entry to
/// `ready` — which never happens on a misconfigured endpoint, so the walk runs
/// to the cap and stays there. A refused handshake itself costs 1-22 ms
/// (06-RESEARCH §A.3), which is inside the noise of a 40 ms first draw and is
/// deliberately not modelled: leaving it out makes the bound *tighter*, which
/// is the safe direction for a bound whose job is to catch a client that spins.
///
/// The walk, at base 40 ms and cap 2 s over 4 s: 20, 40, 80, 160, 320, 640,
/// 1000, 1000, 1000 — nine attempts to cover the window.
int _dialCeiling() {
  var elapsed = 0;
  var attempts = 0;
  var window = _backoffBase.inMilliseconds;
  while (elapsed < _dialWindow.inMilliseconds) {
    attempts++;
    elapsed += window ~/ 2;
    final doubled = window * 2;
    window =
        doubled > _backoffCap.inMilliseconds ? _backoffCap.inMilliseconds : doubled;
  }
  // Times three, the safety factor `connect_failure_gate_test.dart:96-101`
  // argues for and for the same reason: a full-jitter schedule has no hard
  // ceiling — every draw can come back near zero — so the only honest bound is
  // the expectation with a margin. Three is comfortably above the variance of a
  // four-second window and two orders of magnitude below a client that spins,
  // which at a 1-22 ms handshake would make thousands of attempts.
  return attempts * 3;
}

/// Every `LinkState.connecting` this panel has entered since [states] began.
///
/// **The dial counter on a TLS leg, and the only correct one.** `seam.dials`
/// is what the plaintext rows count, and it is wrong here twice over: a TLS leg
/// installs no seam at all (`fault_fixture.dart:148-157`), and even with one
/// `FrameSeam` increments only after `ws.ready` resolves — so a handshake that
/// never completes would leave `seam.dials` at zero for ever, and a row about a
/// panel hammering a gateway it refuses would read as a panel that never
/// dialled.
int _dials(List<LinkState> states) =>
    states.where((state) => state == LinkState.connecting).length;

/// Records every link state [panel] publishes from now on.
///
/// Attached immediately after construction, so it may miss the very first
/// transition of the very first dial. Every count below is compared against a
/// *ceiling* or against another panel observed the same way, so a systematic
/// off-by-one in the safe direction changes nothing — and the anti-vacuity arm
/// asks for more than one, which one missed transition can only make harder.
List<LinkState> _watch(RemoteStateMan panel) {
  final states = <LinkState>[];
  final subscription = panel.linkStates.listen(states.add);
  addTearDown(subscription.cancel);
  return states;
}

/// The credential the gateway's token file actually holds.
///
/// Long enough to clear `FileTokenValidator.minTokenLength` (24) and visibly
/// not a word anybody would type by accident.
const String _provisionedToken = 'ST101-PANEL-7fd2a9c4e1b6083napkin';

/// The credential the refused panel presents — the commissioning typo.
///
/// Same shape, same length, one station that is not in the map. A short or
/// plausible token would be refused for the wrong reason (the length floor, or
/// a collision with ordinary prose) and the arm would measure the loader rather
/// than the decision.
const String _mistypedToken = 'ST101-PANEL-7fd2a9c4e1b6083NAPKIN';

/// A token file this case owns, locked to the owner.
///
/// `0600` is the only mode `FileTokenValidator` accepts on POSIX, and it
/// refuses to load one any other account can read — which is the same rule the
/// plant machine's mount follows, so a fixture written any other way would fail
/// to start the gateway and read as a broken case.
String _writeTokenFile(Map<String, Object?> contents) {
  final dir = Directory.systemTemp.createTempSync('relay-gate-tokens-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}${Platform.pathSeparator}tokens.json');
  file.writeAsStringSync(jsonEncode(contents));
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['600', file.path]);
  }
  return file.path;
}

/// `faultClientConfig`'s knobs plus a credential, which that helper does not
/// take.
///
/// Written out rather than adding a `token:` to the shared helper: exactly one
/// case in this package needs a panel that presents one over a real gateway,
/// and a parameter on a helper five waves depend on would be a surface added
/// for a single caller. The four timing numbers are `faultClientConfig`'s,
/// restated, and the backoff pair is the one F15d's ceiling is computed from —
/// which is what makes the two sides of the contrast below comparable.
ClientConfig _pinnedConfig(String rootPath, {String? token}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: _backoffBase,
      backoffCap: _backoffCap,
      deadlineFloor: const Duration(milliseconds: 50),
      connectTimeout: const Duration(seconds: 10),
      tls: ClientTlsConfig(rootCertPath: rootPath),
      token: token,
    );

/// Waits for the panel to put its refusal on the health line, and hands it back.
///
/// A window and not an instant, because the panel dials from its constructor:
/// how far into the first attempt the case arrives is the scheduler's business.
Future<String> _healthLine(FaultFixture fixture) async {
  await until(
    'the panel to report the refused handshake on its health line',
    () => fixture.client.lastDownReason != null,
    budget: _refusalBudget,
  );
  return fixture.client.lastDownReason!;
}

/// Proves the listener [port] forwards to is genuinely TLS, and that reaching
/// it requires the pinned root.
///
/// **Both halves, because either alone is satisfied by the wrong thing.**
/// Dialling `wss` at a *plaintext* listener also raises a `HandshakeException`
/// (06-03 measured facts §4), so "a pinned panel connected" is on its own
/// equally consistent with "there was no TLS back there at all" and with "the
/// proxy forwarded nowhere". A `ws://` dial coming back `HttpException` rules
/// out both. And a `wss` dial on the *system* store being refused is what says
/// the panel's success came from the mounted root rather than from a machine
/// that happens to trust this leaf.
Future<void> _assertPinnedTls(int port) async {
  final plaintext = await _refused('ws://127.0.0.1:$port');
  expect(
    (plaintext.error as WebSocketChannelException).inner,
    isA<HttpException>(),
    reason: 'a plaintext dial at the proxy port did not meet a TLS listener, '
        'so the fixture may have fallen back to ws — under which every arm in '
        'this file passes while measuring nothing about TLS',
  );

  final unpinned = await _refused('wss://127.0.0.1:$port');
  expect(
    (unpinned.error as WebSocketChannelException).inner,
    isA<HandshakeException>(),
    reason: 'a client using the machine\'s own trust store reached this '
        'gateway. The panel\'s success would then say nothing about the pin: '
        'the point of SecurityContext(withTrustedRoots: false) is that a rogue '
        'root installed on the station cannot vouch for anything claiming to '
        'be the gateway (T-06-20)',
  );
}

void main() {
  group('the gate can stand up a TLS gateway, and a page survives a drop on it',
      () {
    test('a full page survives a drop and a resync over wss', () async {
      final trusted = _trustedCa();
      final mount = _mountOf(trusted, _mintLeaf(ca: trusted));
      final page = plantPage(_pageKeys);

      final fixture = await gateFixture(
        clients: 1,
        keys: page.toSet(),
        seed: (plant) =>
            plant.setValues({for (final key in page) key: _before}),
        tls: mount,
        readyBudget: _recovery,
      );
      final panel = fixture.clients.single;

      expect(panel.client.uri.scheme, 'wss',
          reason: 'the panel dialled ${panel.client.uri}. Everything below is '
              'about a page crossing a TLS link, and a ws dial would prove the '
              'page crosses the link it always crossed');
      await _assertPinnedTls(fixture.proxies.single.port);

      // The seam is not merely absent, it is refused — and that refusal is
      // itself the proof that the panel's own pinned HttpClient is what dialled
      // rather than a `dial:` override the fixture installed.
      expect(() => panel.seam, throwsStateError,
          reason: 'a TLS panel handed back a frame seam, which means a `dial:` '
              'override is in the path — and that override bypasses the pinned '
              'client this whole leg exists to exercise');

      expect(panel.client.read(page.first)?.value, _before,
          reason: 'the page did not arrive over the wss subscribe, so the drop '
              'below would be measuring an empty view coming back empty');

      fixture.proxies.single.killOnce();
      await until('the panel to notice the killed wss link',
          () => !panel.client.isReady,
          budget: _recovery);
      fixture.served.setValues({for (final key in page) key: _after});

      await fixture.untilAllRead(page.last, _after, budget: _recovery);
      expect(
        [for (final key in page) panel.client.read(key)?.value],
        everyElement(_after),
        reason: 'the resync after a drop over wss delivered a partial page. '
            'The value changed *while the panel was down*, so a client that '
            're-rendered its cache reads $_before here — this is F1\'s '
            'silent-permanent-staleness claim, asked once of the TLS fixture '
            'to prove the fixture carries it',
      );
      print('wss smoke: a ${page.length}-key page subscribed, dropped, '
          'resynced and converged on $_after over TLS; '
          '${panel.attempts} connect transitions');
    });
  });

  group('F15 — four ways to fail a handshake, and the shape they share', () {
    test('F15a: a leaf from a foreign CA is refused', () async {
      final trusted = _trustedCa();
      final foreign = _foreignCa();
      // One difference from a fixture that works: who signed the leaf. The
      // panel keeps the root it was provisioned with, which is what makes this
      // the impostor case rather than a misconfigured panel.
      final impostor = _mountOf(trusted, _mintLeaf(ca: foreign));

      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: impostor,
        seed: (plant) => plant.setValue(_key, _before),
      );
      final probe = await _refused(
          'wss://127.0.0.1:${fixture.proxy.port}',
          client: _pinnedClient(impostor.rootPath));
      final text = _expectCertificateRefusal(probe, arm: 'F15a foreign CA');
      final health = await _healthLine(fixture);
      print('F15a: ${probe.error.runtimeType} / $text');
      print('F15a health line: $health');

      expect(health, contains('certificate'),
          reason: 'the panel is not connected and the health line says '
              '"$health". "The gateway did not answer" sends an integrator to '
              'the cable, the switch and the service — three things that are '
              'all fine — before anybody thinks of the leaf');
      expect(fixture.client.isReady, isFalse, // window-exempt: _healthLine's until() returned, which required a completed failed dial, so this is a consistency check against that event rather than a wait for one
          reason: 'the panel reported ready over a gateway whose certificate '
              'it could not verify, which is the one thing an operator must '
              'never be shown');
      expect(fixture.client.stopReason, isNull,
          reason: 'a certificate refusal reached the _stop arm. Phase 6 chose '
              'the opposite deliberately: the fault is on the server, so a '
              'panel that keeps trying recovers the moment somebody replaces '
              'the file — which is the recovery asserted two lines down, and '
              'it is impossible for a panel that gave up');

      // Anti-vacuity, and it is the plant's real repair: same address, new
      // files, nobody touches the panel.
      final good = _mountOf(trusted, _mintLeaf(ca: trusted));
      await _reissue(fixture, good);
      fixture.served.setValue(_key, _after);
      await until('the panel to come back on the re-issued certificate',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
    });

    test('F15b: an expired leaf is refused, identically', () async {
      final trusted = _trustedCa();
      final now = DateTime.now().toUtc();

      // Three bindings of the same fixture, and the arm is that the panel
      // cannot tell them apart.
      //
      // **06-RESEARCH §A.3's "byte-identical" was a macOS measurement, and it
      // does not hold on Linux or Windows.** Measured on all three:
      //
      //   macOS   all three  CERTIFICATE_VERIFY_FAILED: application
      //                      verification failure(handshake.cc:298)
      //   ubuntu  expired    CERTIFICATE_VERIFY_FAILED: certificate has expired
      //           foreign    …: unable to get local issuer certificate
      //           SAN        …: IP address mismatch          (handshake.cc:320)
      //   windows the same three, at the same line
      //
      // Two different arms of BoringSSL: 298 is the *application* verification
      // callback failing with no reason to report, 320 is the built-in
      // verifier handing back `X509_verify_cert_error_string`. So openssl does
      // offer the discrimination on two of the three platforms this product
      // ships to, and a gate that asserted otherwise was asserting one
      // platform's silence as a universal fact.
      //
      // What is universal, and what this case now judges, is the panel's own
      // classification. `ConnectionSupervisor._refusalReason` branches on one
      // thing — whether the unwrapped error is a `HandshakeException` — and
      // emits one sentence for every certificate fault, keeping the OS text
      // whole after it because that is the part a support engineer pastes into
      // a ticket. Every arm below is asserted to be exactly that input, so the
      // sentence is identical by construction rather than by three
      // measurements of a string openssl is free to change.
      final expired = _mountOf(
          trusted,
          _mintLeaf(
              ca: trusted,
              notBefore: now.subtract(const Duration(days: 400)),
              notAfter: now.subtract(const Duration(days: 1))));
      final foreign = _mountOf(trusted, _mintLeaf(ca: _foreignCa()));
      // A leaf that is perfectly valid for a name nobody dials. Every dial in
      // this file goes to 127.0.0.1, so a hostname-only SAN is a real
      // misconfiguration and not a fixture accident.
      final wrongName =
          _mountOf(trusted, _mintLeaf(ca: trusted, sans: const ['gateway.invalid']));

      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: expired,
        seed: (plant) => plant.setValue(_key, _before),
      );
      final expiredText = _expectCertificateRefusal(
          await _refused('wss://127.0.0.1:${fixture.proxy.port}',
              client: _pinnedClient(expired.rootPath)),
          arm: 'F15b expired leaf');
      final foreignText = _expectCertificateRefusal(
          await _refused('wss://127.0.0.1:${await _listener(foreign)}',
              client: _pinnedClient(foreign.rootPath)),
          arm: 'F15b foreign CA');
      final wrongNameText = _expectCertificateRefusal(
          await _refused('wss://127.0.0.1:${await _listener(wrongName)}',
              client: _pinnedClient(wrongName.rootPath)),
          arm: 'F15b SAN mismatch');

      print('F15b expired leaf : $expiredText');
      print('F15b foreign CA   : $foreignText');
      print('F15b SAN mismatch : $wrongNameText');

      // Everything up to openssl's reason is one string on every platform, and
      // it is the whole of what the panel branches on. Only the tail after
      // `CERTIFICATE_VERIFY_FAILED:` varies, and it varies by platform rather
      // than by anything this product decides.
      String shape(String text) =>
          text.split('CERTIFICATE_VERIFY_FAILED:').first;
      expect([shape(foreignText), shape(wrongNameText)],
          everyElement(shape(expiredText)),
          reason: 'an expired leaf, a foreign CA and a SAN that does not cover '
              'the dialled address arrived at the panel in different shapes, '
              'not merely with different reasons inside one. The panel sorts '
              'certificate faults by the exception it unwraps and by nothing '
              'else, so a third shape here is a fault it would report as '
              '"the gateway did not answer" — the cable, the switch and the '
              'service, three things that are all fine, before anybody thinks '
              'of the leaf');

      // Which reason openssl volunteered, recorded rather than asserted: on
      // macOS it volunteers none and the three are byte-identical, on Linux
      // and Windows it names all three. Neither is a property of this product
      // and neither may become one — the moment a panel is allowed to read
      // this tail, it is guessing on one platform out of three.
      print('F15b reasons by platform (recorded, not asserted): '
          '${[expiredText, foreignText, wrongNameText].map((t) => t.split('CERTIFICATE_VERIFY_FAILED:').last.trim()).toSet()}');

      final health = await _healthLine(fixture);
      print('F15b health line: $health');
      expect(health, contains('certificate'),
          reason: 'a leaf that lapsed on Sunday reads as "$health" on the '
              'panel. It has to name the certificate for the same reason F15a '
              'does — and it is the same sentence, because the panel cannot '
              'tell the two apart either');
      // The half the string comparison above used to stand in for, asserted
      // where it actually lives. This is the sentence an operator reads, it is
      // the same one for all three faults because `_refusalReason` branches
      // only on the exception type every arm above was asserted to be, and it
      // says nothing about *which* certificate fault it is. A panel that
      // guessed would be wrong two thirds of the time and believed every time.
      expect(health,
          startsWith("the gateway's certificate was not trusted by this panel"),
          reason: 'the operator sentence for a certificate refusal is fixed '
              'text; this panel produced "$health" instead. If the sentence '
              'has started varying with the fault, the panel is reading '
              'openssl\'s reason — which exists on Linux and Windows, does not '
              'exist on macOS, and is not something a plant can be told');
      expect(fixture.client.stopReason, isNull,
          reason: 'an expired leaf is the most recoverable certificate fault '
              'there is: somebody renews it. A panel that stopped would need a '
              'visit to every station in the factory');

      final good = _mountOf(trusted, _mintLeaf(ca: trusted));
      await _reissue(fixture, good);
      fixture.served.setValue(_key, _after);
      await until('the panel to come back on the renewed certificate',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
    });

    test('F15c: a plaintext listener behind a wss dial', () async {
      // The catalogue's other injection — "proxy to a plain-TCP port". The
      // gateway behind this proxy is a perfectly good one and the fixture's own
      // panel is connected to it over ws, which is this arm's control: what
      // fails is the *wss* dial, not the listener.
      final trusted = _trustedCa();
      final mount = _mountOf(trusted, _mintLeaf(ca: trusted));
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        seed: (plant) => plant.setValue(_key, _before),
      );
      await until('the plaintext control panel to establish and hold the page',
          () => fixture.client.isReady &&
              fixture.client.read(_key)?.value == _before,
          budget: _recovery);

      final probe = await _refused('wss://127.0.0.1:${fixture.proxy.port}',
          client: _pinnedClient(mount.rootPath));
      final inner = (probe.error as WebSocketChannelException).inner;
      print('F15c: ${probe.error.runtimeType} / ${inner.runtimeType} / $inner');

      // **This one is distinguishable, and the reason is structural rather than
      // textual: the dial never reaches certificate verification at all.** A
      // plaintext HTTP listener answers a ClientHello with bytes that are not a
      // ServerHello, so the record layer gives up before any leaf is presented
      // — there is nothing to verify and no verification failure to report.
      expect('$inner', isNot(contains('CERTIFICATE_VERIFY_FAILED')),
          reason: 'a dial into a plaintext listener reported a certificate '
              'verification failure: "$inner". No certificate was ever offered, '
              'so that message would send an integrator to re-provision a root '
              'on a station whose root is fine, while the actual fault is a '
              'gateway that was started without its TlsConfig');
      expect(probe.closeCode, isNull,
          reason: 'the failure happens before the upgrade, so there is no '
              'WebSocket and never will be a code');

      // The panel-level half. Hand-built rather than taken off the fixture,
      // because this is the one arm where the gateway and the panel disagree
      // about the protocol — `faultFixture`'s `tls:` sets both ends at once,
      // which is exactly the misconfiguration that cannot happen here.
      final panel = RemoteStateMan(
        uri: Uri.parse('wss://127.0.0.1:${fixture.proxy.port}'),
        config: faultClientConfig(
            tls: ClientTlsConfig(rootCertPath: mount.rootPath)),
        keys: const {_key},
      );
      addTearDown(panel.dispose);
      await until('the wss panel to report the plaintext listener',
          () => panel.lastDownReason != null, budget: _refusalBudget);
      print('F15c health line: ${panel.lastDownReason}');

      // **And here the reading collapses again, one shape further than 06-07
      // measured.** That plan found a cut handshake reading as a certificate
      // problem; this is a *third* root cause — a gateway started without its
      // TlsConfig — arriving as the same sentence, because `_refusalReason`
      // branches on `HandshakeException` and dart:io raises it for a record
      // layer that gave up as well as for a leaf it refused. Pinned as it
      // stands and recorded against F15's `clear terminal error`: three faults
      // with three different people to call, one message.
      expect(panel.lastDownReason, contains('certificate'),
          reason: 'the panel now distinguishes a plaintext gateway from an '
              'untrusted leaf, which would be an improvement — and this pin is '
              'how the plan that made it finds out that 07-12 depended on the '
              'old text. Update it deliberately, and take F15\'s "clear '
              'terminal error" deviation with you');
      expect(panel.stopReason, isNull,
          reason: 'a gateway that came back up without its TlsConfig is a '
              'deployment mistake somebody fixes in a minute; the panel has to '
              'be there when they do');

      expect(fixture.client.isReady, isTrue, // window-exempt: the until() above waited for the plaintext panel to establish, so this asserts consistency with a completed event rather than waiting for one
          reason: 'the control is not connected, so the wss refusal above is '
              'equally consistent with "there is nothing behind this proxy at '
              'all" — which is a green arm measuring an empty port');
    });

    test('F15e: a cut mid-handshake', () async {
      final trusted = _trustedCa();
      final mount = _mountOf(trusted, _mintLeaf(ca: trusted));

      // `cutMidFrame(1)` and not `killOnce()`, which 06-07 deviation 2 argues
      // at length: killOnce fires once and disarms, so the panel's own redial
      // would consume the arm before the probe could meet it and a race would
      // decide what this case measured. A sticky cut means the panel and the
      // probe meet the same fault, and lifting it *is* the recovery.
      //
      // Armed before the dial, which is the one ordering a case cannot arrange
      // for itself: `RemoteStateMan` dials from its constructor.
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mount,
        seed: (plant) => plant.setValue(_key, _before),
        armBeforeDial: (proxy) => proxy.cutMidFrame(1),
      );

      final probe = await _refused('wss://127.0.0.1:${fixture.proxy.port}',
          client: _pinnedClient(mount.rootPath));
      final inner = (probe.error as WebSocketChannelException).inner;
      print('F15e: ${probe.error.runtimeType} / ${inner.runtimeType} / $inner');

      // **The union, because both are possible and asserting one is a case
      // that fails on the other machine** (06-RESEARCH §C.4). Whether the
      // handshake dies inside `dart:io`'s TLS state machine or at the socket
      // underneath it depends on where the cut landed relative to the record
      // boundary, which is a scheduling detail this file must not pin.
      expect(inner, anyOf(isA<HandshakeException>(), isA<SocketException>()),
          reason: 'a link cut inside the handshake produced ${inner.runtimeType}, '
              'which is neither of the two shapes dart:io raises for it. A '
              'third shape here means the dial failed for a reason this arm '
              'did not inject');
      expect(probe.closeCode, isNull);

      final health = await _healthLine(fixture);
      print('F15e health line: $health');
      // **06-07's finding, inherited and pinned as it stands.** A cut cable
      // and an impostor read identically, because `_refusalReason` branches on
      // the exception class and `dart:io` raises `HandshakeException` for
      // both. The discriminator is in the text — "Connection terminated during
      // handshake" against "CERTIFICATE_VERIFY_FAILED" — and narrowing that
      // branch changes a sentence an operator acts on, which is a decision and
      // not a typo. In the deviations registry against `clear terminal error`.
      expect(health, isNotEmpty,
          reason: 'the panel is down and said nothing about why, which is the '
              'grey screen with a "connecting" indicator that sends the first '
              'phone call to the network electrician');
      expect(fixture.client.stopReason, isNull,
          reason: 'a cut cable is the most transient fault in the catalogue. '
              'Stopping on it would mean a panel that never comes back from a '
              'switch reboot');

      // Anti-vacuity: lifting the lever is all it takes, so the fixture could
      // have connected all along and the refusal above is the cut.
      fixture.proxy.cutMidFrame(null);
      fixture.served.setValue(_key, _after);
      await until('the panel to establish once the cut was lifted',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
    });

    test('F15d: a misconfigured endpoint is not hammered', () async {
      // **The row's actual operational content.** Everything above says a
      // handshake fails and the panel says so, which Phase 6 already pinned
      // directly. The catalogue's clause is "no reconnect-forever at full speed
      // against a misconfigured endpoint", and that is a property of the
      // supervisor's schedule — not of TLS.
      final trusted = _trustedCa();
      final impostor = _mountOf(trusted, _mintLeaf(ca: _foreignCa()));

      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: impostor,
        seed: (plant) => plant.setValue(_key, _before),
      );
      final states = _watch(fixture.client);
      await Future<void>.delayed(_dialWindow);
      final dials = _dials(states);
      final ceiling = _dialCeiling();
      print('F15d: $dials dials in ${_dialWindow.inSeconds} s against a '
          'computed ceiling of $ceiling (base ${_backoffBase.inMilliseconds} ms, '
          'cap ${_backoffCap.inSeconds} s, full jitter)');

      expect(dials, greaterThan(1),
          reason: 'the panel made $dials dials in ${_dialWindow.inSeconds} s. '
              'One or none satisfies "bounded" trivially and is the *opposite* '
              'of the designed behaviour: Phase 6 chose deliberately that a '
              'certificate refusal keeps retrying, because the fault is on the '
              'server and a panel that keeps trying recovers by itself the '
              'moment somebody replaces the file. A panel that gave up needs a '
              'visit to the station');
      expect(dials, lessThan(ceiling),
          reason: 'the panel made $dials dials in ${_dialWindow.inSeconds} s '
              'against a ceiling of $ceiling computed from the backoff '
              'schedule. A handshake refusal costs 1-22 ms, so a client that '
              'redialled without waiting would make thousands — a self-'
              'inflicted denial of service against the one process serving '
              'every screen in the factory, at the exact moment somebody is '
              'trying to fix the certificate on it');
      expect(states, isNot(contains(LinkState.ready)),
          reason: 'the panel reported ready over a gateway whose leaf it never '
              'verified');
    });

    test('F15f: a handshake that is never answered is bounded by the client',
        () async {
      // The TCP connect *succeeds* and the TLS handshake is then swallowed, so
      // nothing about this dial fails on its own — it hangs until somebody
      // gives up. On macOS that somebody is the operating system, 75 seconds
      // later (07-RESEARCH trap 19), and a single case of that would eat a
      // sixth of the gate lane while measuring the OS rather than the panel.
      //
      // Armed before the dial, which is the one ordering a case cannot arrange
      // for itself, and the reason `armBeforeDial` exists (06-07 deviation 3).
      final trusted = _trustedCa();
      final mount = _mountOf(trusted, _mintLeaf(ca: trusted));

      final elapsed = Stopwatch()..start();
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: mount,
        seed: (plant) => plant.setValue(_key, _before),
        armBeforeDial: (proxy) => proxy.blackhole(),
        connectTimeout: _shortDial,
      );
      final health = await _healthLine(fixture);
      elapsed.stop();
      print('F15f: the abandoned dial was reported after '
          '${elapsed.elapsedMilliseconds} ms against a '
          '${_shortDial.inMilliseconds} ms connectTimeout (the operating '
          'system would have taken about 75 000 ms)');
      print('F15f health line: $health');

      // The band includes the fixture's own gateway bind, proxy bind and panel
      // construction, so it is not a measurement of `connectTimeout` — it is
      // the discriminator between the client's bound and the OS's, and those
      // two are three orders of magnitude apart. Anything in between would be
      // a third mechanism nobody has named.
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the first refusal took ${elapsed.elapsedMilliseconds} ms '
              'against a ${_shortDial.inMilliseconds} ms connect bound. If it '
              'is anywhere near 75 000 the knob is not being applied and the '
              'operating system is pacing this leg — which is 06-05\'s '
              'ClientConfig.connectTimeout earning its keep, measured at '
              '10 025 ms in 06-07 sabotage A2 with only the 10 s default in '
              'place');
      expect(health, isNotEmpty,
          reason: 'a dial the client abandoned produced no health line at all, '
              'so the panel is grey with nothing to say — which is the same '
              'screen a pulled cable produces and the reason the first phone '
              'call goes to the wrong person');
      expect(fixture.client.stopReason, isNull,
          reason: 'a swallowed handshake is a network condition, not a verdict '
              'about this panel');

      // Anti-vacuity: lifting the lever is all it takes, so the dial was
      // bounded *and* the fixture could have connected all along.
      fixture.proxy.blackhole(enabled: false);
      fixture.served.setValue(_key, _after);
      await until('the panel to establish once the blackhole was lifted',
          () => fixture.client.read(_key)?.value == _after,
          budget: _recovery);
    });
  });

  group('the two sides of one supervisor branch', () {
    // The name is one literal on one long line deliberately: discovery
    // (`gate_manifest_test.dart:952-953`) captures only the *first* string of
    // a `test(` call, so a name wrapped across two adjacent literals is read
    // as its first half — which for a supporting case means its exemption
    // entry stops matching and the manifest reports a hole. Same rule, same
    // reason, as the quote anchors having to sit unbroken (07-02 deviation 5).
    test('a refused credential stops the loop while a refused certificate does not', () async {
      // **One comparison, not two cases.** `connection_supervisor.dart` has a
      // `_stop` arm that ends the redial loop for good (a refused protocol
      // version at :479, a refused credential at :497) and a `_down` arm that
      // schedules another attempt. F15 sits on the `_down` side and the
      // catalogue says why: a certificate is fixed on the server, so a panel
      // that keeps trying recovers by itself. A credential is a fact about
      // *this* panel that retrying cannot change, and the gateway says so from
      // its end (`error_codes.dart:31-34`: "reconnecting with the same token
      // will be refused again, so a backoff loop around it is a busy loop").
      //
      // Asserted together because the claim is about the *pair*. Two separate
      // cases would each be satisfied by a supervisor that took the same branch
      // for both, as long as it took the branch that case expected — and only
      // one of the two behaviours can be right for either fault.
      final trusted = _trustedCa();
      final good = _mountOf(trusted, _mintLeaf(ca: trusted));
      final impostor = _mountOf(trusted, _mintLeaf(ca: _foreignCa()));

      // A real gateway with a real token file, not a scripted one: the -32003
      // has to come out of `FileTokenValidator` deciding about a credential,
      // or the arm is a claim about a fake.
      final tokens = _writeTokenFile({
        'tokens': {
          _provisionedToken: {'username': 'ST101-panel', 'station': 'ST101'},
        },
      });
      final refusing = await gateFixture(
        clients: 1,
        // 17-04b: the token names a user, and `start()` refuses a token file
        // whose usernames it cannot resolve to accounts. This case never
        // authenticates the provisioned token — the resolver exists so the
        // gateway comes up and can refuse the mistyped one.
        accounts: (username) => username == 'ST101-panel'
            ? const ResolvedUser(
                user: AuthenticatedUser(
                    username: 'ST101-panel',
                    roleName: 'Hall Display',
                    stationAccount: true),
                groups: {})
            : null,
        keys: const {_key},
        seed: (plant) => plant.setValue(_key, _before),
        tls: good,
        serverConfig: (port) => ServerConfig(
          tick: ServerConfig.minTick,
          port: port,
          tls: TlsConfig(chainPath: good.chainPath, keyPath: good.keyPath),
          auth: AuthConfig(tokenFilePath: tokens),
        ),
        // The credential an integrator mistypes on a commissioning weekend:
        // right shape, right length, not in the station map.
        config: _pinnedConfig(good.rootPath, token: _mistypedToken),
        waitForReady: false,
      );
      final authPanel = refusing.clients.single;

      final untrusted = await faultFixture(
        keys: const {_key},
        withProxy: true,
        tls: impostor,
        seed: (plant) => plant.setValue(_key, _before),
      );
      final tlsStates = _watch(untrusted.client);

      await Future<void>.delayed(_dialWindow);
      final authDials = _dials(authPanel.states);
      final tlsDials = _dials(tlsStates);
      print('auth vs TLS over ${_dialWindow.inSeconds} s: a refused credential '
          'dialled $authDials time(s) and stopped '
          '(${authPanel.client.stopReason}); a refused certificate dialled '
          '$tlsDials time(s) and is still going');

      // **Zero is the expected reading, and `stopReason` is what stops it
      // being vacuous.** The recorder is attached immediately after the panel
      // is constructed and the panel dials from its constructor, so the single
      // transition of the single attempt is routinely missed — a panel that
      // never dialled at all would read zero too. What tells them apart is the
      // sentence below: it is the *gateway's* message, so it cannot exist
      // unless a hello crossed the wire and was answered.
      expect(authDials, lessThanOrEqualTo(1),
          reason: 'the refused panel dialled $authDials times in '
              '${_dialWindow.inSeconds} s. The -32003 and the 4001 close that '
              'follows it are one event; a second dial means the close was '
              'treated as its own reason to come back, which is the busy loop '
              'the _stop arm exists to end');
      expect(tlsDials, greaterThan(authDials),
          reason: 'a refused credential produced $authDials dials and a '
              'refused certificate produced $tlsDials over the same '
              '${_dialWindow.inSeconds} s window. The two are supposed to take '
              'opposite branches: if the certificate side has stopped, a panel '
              'goes dark until somebody walks to it; if the credential side has '
              'not, one mistyped token is a rejected hello every backoff '
              'ceiling for ever against the single process serving every screen '
              'in the factory');
      expect(authPanel.client.stopReason, contains('credential'),
          reason: 'the panel stopped and said "${authPanel.client.stopReason}". '
              'It has to name the credential: "the handshake was refused" '
              'sends the integrator to the network, and the fault is in the '
              'token file');
      expect(untrusted.client.stopReason, isNull,
          reason: 'the certificate side reached the _stop arm, so the panel '
              'will not be there when the leaf is replaced. That is the '
              'asymmetry Phase 6 chose on purpose and this is the arm that '
              'holds it');
      expect(authPanel.states, isNot(contains(LinkState.ready)),
          reason: 'the refused panel reported ready, which would mean the '
              'gateway served a page to a credential it rejected');
    });
  });
}
