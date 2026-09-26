/// N real panels on one gateway, a gateway that can be restarted underneath
/// them, and the counters that prove the numbers above are being measured
/// rather than assumed.
///
/// **Why this is a second fixture and not a parameter on the first.**
/// `fault_fixture.dart` builds exactly one client, and its teardown order is
/// load-bearing prose: plant, gateway, proxy and panel are released in an order
/// that is argued in that file's library doc and nowhere else. Adding an `n:`
/// to it would make that order an *inherited* property — a reader of a herd
/// case would have to open the other file to find out what is torn down when,
/// and a change to either lifetime would silently change the other's. The two
/// fixtures have genuinely different lifetimes (that one's gateway is built
/// once and never replaced; this one's is closed and rebound mid-case), so the
/// wiring is **copied with its reasons restated** rather than shared. That is
/// 07-RESEARCH trap 16's instruction, and the cost — two places that must not
/// drift — is the price of the order staying readable in one place.
///
/// **Teardown order, and why it is registered backwards.** `addTearDown` runs
/// last-registered-first, so the registrations below read backwards from the
/// order they execute in: plant, then proxies, then gateway, then every client
/// — executing as **all clients, then the gateway, then the proxies, then the
/// plant**. That is `ws_harness.dart:359-384`'s order, which
/// `client_harness.dart:330-340` restates: the client goes first because it
/// owns the socket and both its timers and because it is the only participant
/// that *reconnects* (a gateway closed under a live panel leaves that panel
/// dialling a dead port for the rest of the run, and the attempts land as
/// noise on whichever case is unlucky enough to be running then); the proxy
/// cannot go first because shutting it down destroys both halves of every pair
/// it carries; and the plant goes last because its freshness watchdog must
/// outlive anything still draining through it.
///
/// With N clients the rule is unchanged and the *whole* client group goes
/// first, which is why each client registers its own teardown in the loop that
/// builds it rather than one teardown closing the list — a single closure would
/// still be one registration, and one registration cannot be reordered against
/// the gateway's if a later reader adds something between them.
///
/// **The listen port is fixed from the first bind, not chosen by us.**
/// `FaultProxy.targetPort` is `final` (`fault_proxy.dart:149`), a Phase 2
/// artifact guarded by `proxy_core_test.dart` and `mode_integrity_test.dart`,
/// so a gateway that is restarted behind a proxy must come back on the port it
/// left. 07-RESEARCH §A.3 argues at length that making `targetPort` mutable is
/// the strictly worse route, and Phase 6 landed the field this needs:
/// `ServerConfig.port`, defaulting to `0`.
///
/// So the first gateway binds `port: 0` — the OS picks — and every replacement
/// binds `ServerConfig(port: <that number>)`. The port is fixed for the
/// fixture's whole life, which is all the proxy requires, and it is a port the
/// kernel has just confirmed is free rather than a number this file guessed
/// and another process might own. See [GateFixture.restartGateway] for the
/// rebind and its retry.
///
/// **TLS is opt-in, it reuses 06-07's support rather than a second one of its
/// own, and what it changes is the dial rather than the proxy.** Pass a
/// [FaultTls] — `fault_fixture.dart`'s own record type, imported, not
/// re-declared — and every gateway this fixture binds serves `wss` from the
/// mounted chain, every panel dials `wss://127.0.0.1:<proxy port>` pinning the
/// mounted root, and the proxy is untouched. It does not have to change:
/// `FaultProxy` is a loopback *byte* relay (`fault_proxy.dart:141-190`) that
/// forwards through a `DelayLine` and never inspects a frame, so it shapes
/// ciphertext without knowing that is what it is doing. The default is off, so
/// every existing herd and slow-link case is byte-identical.
///
/// **Why this parameter exists at all when `faultFixture` already had one.**
/// 06-07 built the wss leg on the *one-panel* fixture, and that is still where
/// every single-panel TLS case belongs — `tls_gate_test.dart`'s F15 arms use it
/// directly. What that shape does not extend to is N panels on one gateway and
/// a `serverConfig` builder, which is what a full-page smoke row over `wss` and
/// an auth-refusal contrast need. So the *mount type, the client config helper
/// and the pinning discipline are shared* and only the N-panel wiring is here.
/// Two ways to mint a certificate in one package would be how the next reader
/// picks the wrong one; two ways to stand up a herd would be worse.
///
/// **A TLS leg has no [FrameSeam], by construction** — the same rule
/// `fault_fixture.dart` states and for the same reason. The seam is installed by
/// passing `dial:` to `RemoteStateMan`, and a fixture that passes `dial:`
/// bypasses the panel's own pinned `HttpClient`, which is the thing a TLS leg
/// exists to exercise. So [GateClient.seam] throws on a TLS panel rather than
/// handing back a lens nobody installed, and [GateClient.observedClose] reports
/// nothing for the same reason: it is read off the attempt the `dial:` wrapper
/// kept. [GateClient.attempts] is unaffected — it counts `LinkState.connecting`
/// transitions off the panel's own stream — and it is the dial counter a TLS
/// case wants anyway (see its doc).
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
// `CloseCodes`, for the eviction set: the codes that mean a panel was thrown
// off, told apart from the 4002 the gateway sends on its own way out.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

// `FaultTls` is imported rather than re-declared: one record type for the
// mount means a case can hand the same paths to either fixture, and a second
// declaration would be the first place the two legs drifted.
import 'fault_fixture.dart' show FaultTls, faultClientConfig, until;
import 'frame_seam.dart';
import 'permissive_resolver.dart';

/// A page of [n] keys in the plant's own `AREAnn.DEVnn.SUBnn` shape.
///
/// **Why this is here and not in the file that first needed it.** The slow-link
/// rows are a family — F19 carries the page a link has headroom for, F20 the
/// same page on a link that cannot carry it, F21 the same page again across a
/// recovery — and the whole point of the comparison is that it is the *same*
/// page. Two builders, one per wave, would drift by a key or by a name shape
/// within a plan, and the F19-versus-F20 contrast would quietly become a
/// contrast between two pages as well as between two rates. 07-10 writes it;
/// 07-11 imports it.
///
/// **Realistic width, because width is the payload.** 07-RESEARCH assumption A1
/// puts a slim delta key at about 22 bytes on the wire, which is a number about
/// *this* naming scheme: `ST101.CN01.MOT01.setpoint` is 25 characters, and
/// `key0`…`key199` would be less than half of it. A page built out of short
/// names would put the 200-key frame at well under the size the rate arithmetic
/// in F19's doc is computed from, and the row would be measuring a link with
/// twice the headroom it claims to have. It is also `resync_gate_test.dart:97-104`'s
/// rule: a page should read like a page.
///
/// The scheme is two areas of twenty devices carrying five motors each, so 200
/// keys are unique without repeating a segment pattern, and the areas are the
/// plant's own (`ST101`, `ST201`; `ST301` is the third and this builder stops
/// before inventing a fourth).
List<String> plantPage(int n) {
  if (n <= 0 || n > 300) {
    throw ArgumentError('a page of $n keys is outside 1-300. The scheme below '
        'lays 100 keys into each of the plant\'s areas and the plant has three '
        '(ST101, ST201, ST301), so a larger page would name an area that does '
        'not exist — a key the gateway classifies as a typo and never serves '
        '(`session_handlers.dart:154-164`), which reads in a case as a page '
        'that never fills');
  }
  return [
    for (var i = 0; i < n; i++)
      'ST${101 + (i ~/ 100) * 100}'
      '.CN${(i % 100 ~/ 5 + 1).toString().padLeft(2, '0')}'
      '.MOT${(i % 5 + 1).toString().padLeft(2, '0')}.setpoint',
  ];
}

/// A plant that moves every key of a page on a period, and counts what it did.
///
/// The counter is the reason this is a class rather than a bare [Timer]. A
/// slow-link row's first question is always "was the plant actually busy?" —
/// a link throttled below the rate of nothing is not throttled, and a cadence
/// measured on a quiet page is measuring the freshness follow-up rather than
/// the page. [sweeps] and [writes] are what that arm reads, and [latest] is
/// what a conflation arm compares the last delivered value against.
final class PlantDriver {
  PlantDriver._(this._plant, this.keys, this.period, this.from);

  final FakeStateMan _plant;

  /// The page being moved.
  final List<String> keys;

  /// How often every key on [keys] is given a new value.
  final Duration period;

  /// The value the first sweep writes.
  final int from;

  Timer? _timer;
  int _sweeps = 0;

  /// How many times the whole page has been moved.
  int get sweeps => _sweeps;

  /// How many key-writes that is — the number an "is the plant busy" arm bands.
  int get writes => _sweeps * keys.length;

  /// The value the last sweep wrote, or null before the first one.
  ///
  /// Monotonic by construction, so a case can assert that what a panel was
  /// shown last is what the plant holds now without reading the plant twice
  /// and racing itself.
  int? get latest => _sweeps == 0 ? null : from + _sweeps - 1;

  void _sweep() {
    final value = from + _sweeps;
    _sweeps++;
    _plant.setValues({for (final key in keys) key: value});
  }

  /// Idempotent, so a case may stop the plant early and the teardown still
  /// runs without knowing whether it did.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Starts moving every key of [keys] on [period], and stops at teardown.
///
/// **The first sweep is synchronous.** `Timer.periodic` fires after one period,
/// so a driver started immediately before a measurement window would leave the
/// first tick of that window carrying whatever the seed left behind — which for
/// a 100 ms period and a 100 ms tick is a whole frame of the measurement, and
/// for a case that samples the write count it is an off-by-one that reads as
/// the plant running slow.
PlantDriver drivePage(
  FakeStateMan plant,
  List<String> keys, {
  Duration period = const Duration(milliseconds: 100),
  int from = 1000,
}) {
  final driver = PlantDriver._(plant, keys, period, from);
  driver._sweep();
  driver._timer = Timer.periodic(period, (_) => driver._sweep());
  addTearDown(driver.cancel);
  return driver;
}

/// How many panels a herd holds unless a case says otherwise.
///
/// **Twenty, and deliberately not fifty.** 07-RESEARCH §C.2: twenty real
/// panels cost about eighty descriptors in this process — panel socket, the
/// proxy's accepted socket, the proxy's upstream socket, the gateway's accepted
/// socket, per client — against a 256+ default on macOS and 1024 on Linux, and
/// the gate lane runs at `concurrency: 1` so no neighbouring suite is competing
/// for them. Fifty buys no additional evidence about the property (the
/// mechanism that spreads a herd is per-client jitter, which twenty samples
/// measure as well as fifty) and costs two and a half times the descriptors and
/// the wall clock, which is where flakes come from.
///
/// [herdSize] reads `RELAY_HERD_N` so a larger arm can be run by hand without
/// the default moving. It is the `FAULT_LANE_BUDGET` shape 07-CONTEXT ruling 2
/// established: short in every CI run, long behind an environment flag.
const int defaultHerdSize = 20;

/// The environment variable that overrides [defaultHerdSize].
const String herdSizeEnvVar = 'RELAY_HERD_N';

/// How many panels this run's herd holds.
int get herdSize {
  final override = Platform.environment[herdSizeEnvVar];
  if (override == null || override.isEmpty) return defaultHerdSize;
  final parsed = int.tryParse(override);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError('$herdSizeEnvVar is "$override", which is not a '
        'positive integer. A herd size that failed to parse would silently '
        'become the default and the run would report a number nobody asked '
        'for');
  }
  return parsed;
}

/// The close a *client* observed.
///
/// The naming rule is `ws_harness.dart:73-90`'s and `client_harness.dart`
/// copies it for the same reason: a client observation says `closeCode`, the
/// gateway's own record says `sentCloseCode`, and that one character's case is
/// what lets the phase's text sweep tell intention from observation. Both
/// fields are null while the socket is open, which is the ordinary reading for
/// a panel that was never evicted.
typedef ObservedClose = ({int? closeCode, String? closeReason});

/// A mutable holder for the gateway, so the teardown closure registered before
/// the fixture object exists still closes whichever gateway is current.
///
/// A restart replaces the `RelayServer`, and the teardown has to release the
/// replacement rather than the one it was registered against — otherwise every
/// case that restarts leaks a listener and its tick engine into the rest of the
/// run, which is the shape a leak counter would then report against the *next*
/// case.
final class _GatewaySlot {
  _GatewaySlot(this.server);

  RelayServer server;
}

/// One panel of the herd: its client, its lens, its proxy, and what it saw.
final class GateClient {
  GateClient._(this.index, this.client, this._seam, this.proxy);

  /// Its position in the herd, for the messages a herd case has to print.
  final int index;

  /// The implementation under test.
  final RemoteStateMan client;

  final FrameSeam? _seam;

  /// The lens on this panel's inbound frames.
  ///
  /// **One seam per client, and it cannot be otherwise.** A `FrameSeam` holds
  /// the dial's `_dials` counter and the `_toClient` controller for the socket
  /// it is currently serving (`frame_seam.dart:96-99`), so a seam shared by two
  /// panels would count both panels' dials as one number and would deliver an
  /// injection to whichever of them dialled last.
  ///
  /// **Throws on a TLS panel**, the way `FaultFixture.seam` does and for the
  /// identical reason: a wss leg installs no `dial:` override, because that
  /// override is exactly what would bypass the panel's own pinned `HttpClient`.
  /// Handing back an empty seam would turn every `inbound` reading and every
  /// `dials` count into a vacuous pass on the one leg where the dial is the
  /// subject.
  FrameSeam get seam {
    final seam = _seam;
    if (seam == null) {
      throw StateError('panel $index is on a TLS leg and has no frame seam: a '
          'wss panel dials through its own pinned client, which is exactly '
          'what a `dial:` override would bypass. Count dials with `attempts` '
          '(LinkState.connecting transitions, which is the better counter on '
          'any leg where the handshake fails), or reach for the proxy');
    }
    return seam;
  }

  /// The fault proxy this panel dials through.
  ///
  /// Shared with the rest of the herd unless the fixture was built
  /// `proxyPerClient: true`, which is what F12 needs — see [gateFixture].
  final FaultProxy proxy;

  /// Every link state this panel has published since the fixture was built.
  ///
  /// **This is the herd's attempt counter, and `FrameSeam.dials` is not.** The
  /// seam increments only after `ws.ready` completes
  /// (`frame_seam.dart:107-124`), so a dial into a gateway that is not
  /// listening — which is every attempt made during a restart — is invisible to
  /// it. `LinkState.connecting` is the storm observable 07-04 named, and
  /// counting transitions into it is how a case sees the difference between a
  /// herd that backed off and a herd that hammered.
  ///
  /// The recorder is attached immediately after the panel is constructed, so
  /// it may miss the very first transition of the very first dial. Every herd
  /// measurement is a delta across a window, so that does not matter — but a
  /// case asserting on the absolute count of the first establishment would be
  /// wrong, and this is where it would go wrong.
  ///
  /// **On a TLS leg this is the only dial counter there is**, and it is also
  /// the only correct one. There is no seam at all (see [seam]), and even if
  /// there were, a handshake that never completes leaves `seam.dials` at zero
  /// for ever: it increments after `ws.ready` resolves. A row about a panel
  /// hammering a gateway whose certificate it refuses is a row about attempts
  /// that produce no socket, so the counter has to be upstream of the socket.
  final List<LinkState> states = <LinkState>[];

  /// How many times this panel has entered [LinkState.connecting].
  int get attempts =>
      states.where((state) => state == LinkState.connecting).length;

  /// The close this panel's socket has observed, both fields null while it is
  /// open — and null for ever on a TLS leg, which installs no `dial:` wrapper
  /// to keep the attempt (see the library doc).
  ///
  /// Read off the most recent attempt the dial produced, which is the only
  /// close worth asserting on for a close the gateway initiated
  /// (`web_socket_channel` #1698: `closeCode` is null after a self-initiated
  /// close on every platform).
  ObservedClose get observedClose =>
      (closeCode: _last?.closeCode, closeReason: _last?.closeReason);

  ConnectAttempt? _last;
}

/// Everything a herd case drives.
final class GateFixture {
  GateFixture._(
    this.served,
    this._slot,
    this.port,
    this.proxies,
    this.clients,
    this._keys,
    this.gatewayComplaints,
    this._retired,
    this._config,
    this._gatewayConfig,
    this._tls,
    this._accounts,
  );

  /// The plant behind the gateway. Levers go straight here, never over the
  /// wire: `rpc_names.dart` keeps them off any method table a connected client
  /// can reach, and putting them on it would be an access-control change
  /// wearing a testing convenience (T-04-30).
  final FakeStateMan served;

  final _GatewaySlot _slot;

  /// The gateway under test's peer, right now.
  ///
  /// A getter and not a field: [restartGateway] replaces the object, and a case
  /// that captured the old one would be reading a closed gateway's registry
  /// and finding it reassuringly empty.
  RelayServer get server => _slot.server;

  /// The port the gateway binds, fixed for this fixture's whole life.
  ///
  /// Chosen by the kernel at the first bind and then pinned through
  /// `ServerConfig.port` on every replacement — see the library doc.
  final int port;

  /// The proxies in front of the gateway: one, or one per client.
  final List<FaultProxy> proxies;

  /// The panels, in the order they were built.
  final List<GateClient> clients;

  final Set<String> _keys;

  /// Everything the gateway complained about, across every restart.
  ///
  /// `RelayServer`'s default handler discards (`fault_fixture.dart:259-263`'s
  /// reason: every case here provokes an error on purpose). A herd is exactly
  /// the shape that escapes one — twenty panels reconnecting at once, each
  /// with a socket dying under a handler — so this fixture always collects
  /// rather than discarding, and a case asserts the list is empty. Discarding
  /// them would make "no escaped async errors" a claim nothing could refute.
  final List<String> gatewayComplaints;

  /// The close ledgers of every gateway this fixture has retired.
  ///
  /// A restart throws the old `RelayServer` away and its ledger with it, so a
  /// case that asked the live gateway "was anybody evicted?" would be asking
  /// the one object that cannot have seen it. Captured at restart time and
  /// prepended to the live ledger by [evictions].
  final List<ConnectionClose> _retired;

  final ClientConfig _config;

  /// What every gateway this fixture builds is configured with, replacement
  /// included — see [GatewayConfig].
  final GatewayConfig? _gatewayConfig;

  /// The certificate material every gateway this fixture builds serves from,
  /// and the root every panel pins. Null on a plaintext leg.
  ///
  /// Held so [restartGateway] re-binds `wss` rather than dropping to plaintext
  /// under panels that are still pinning — which would read as a gateway that
  /// never came back, rather than as a fixture that changed protocol.
  final FaultTls? _tls;

  /// 17-04b's user-resolver seam, forwarded to every gateway this fixture
  /// builds. Only a case whose [GatewayConfig] names a token file needs one —
  /// `RelayServer.start()` refuses that combination without it.
  final UserResolver? _accounts;

  /// Whether this fixture's panels dial `wss`.
  bool get isTls => _tls != null;

  /// The one proxy the whole herd shares.
  ///
  /// Throws rather than answering the first of several, the way
  /// `fault_fixture.dart:164-171` throws for a fixture built without one: a
  /// case that pulled a lever on `proxies.first` believing it was pulling it on
  /// the link would be throttling one panel and asserting about all of them,
  /// which is the exact confusion F12's doc has to rule out.
  FaultProxy get proxy {
    if (proxies.length != 1) {
      throw StateError('this fixture was built with ${proxies.length} proxies '
          '(one per client), so there is no single link to pull a lever on. '
          'Reach for `clients[i].proxy` and say in the case which panel is '
          'being shaped');
    }
    return proxies.single;
  }

  /// How many panels the gateway is holding.
  int get sessionCount => server.sessions.sessionCount;

  /// How many sessions the gateway holds that have connected but **not** yet
  /// completed `hello`.
  ///
  /// A slot held between accept and handshake is a resource nobody has
  /// authenticated for (06-RESEARCH §H.4). `RelaySession.sessionId` is minted
  /// by the `hello` handler and is null until then
  /// (`relay_session.dart:430-431`), which is the same predicate
  /// `RelayServer.reloadTokens`' sweep uses to skip a pre-hello session, so
  /// this counts what the gateway itself calls unauthenticated.
  ///
  /// **Reported, never enforced.** 07-CONTEXT orchestrator ruling 4: Phase 7
  /// measures the emergent bound and `maxSessions` is a later decision.
  int get unauthenticatedSlots =>
      server.sessions.sessions.where((s) => s.sessionId == null).length;

  /// The close codes that mean the gateway threw a panel off.
  ///
  /// **`serverDraining` (4002) is deliberately not here.** It is what
  /// `RelayServer.close` sends every live session on its way out, so it is the
  /// signature of the restart *itself* — F10's whole injection — and of the
  /// fixture's own teardown. Counting it as an eviction would make every herd
  /// row red for having done the thing it was asked to do. What is left is the
  /// set an operator would call being thrown off: a credential that stopped
  /// being valid, a heartbeat the gateway gave up on, and a send buffer the
  /// gateway refused to keep growing.
  static const Set<int> evictionCodes = <int>{
    CloseCodes.authExpired,
    CloseCodes.heartbeatTimeout,
    CloseCodes.backpressureOverrun,
  };

  /// Every close the gateway *initiated* that was an eviction, across every
  /// gateway this fixture has run.
  ///
  /// This is the eviction question, and it is asked of the gateway rather than
  /// of the panels on purpose. A panel whose socket the proxy reset observes
  /// 1002 or 1006 — a fault the case injected — while a panel the gateway threw
  /// off observes a code the gateway chose. Only the second is an eviction, and
  /// only the gateway's ledger can tell them apart: from the panel's side a
  /// flap and an eviction are the same dead socket.
  ///
  /// Read it **before** teardown for the live gateway's half, because
  /// `RelayServer.close` is about to drain every remaining session.
  List<ConnectionClose> get evictions => [
        for (final close in [..._retired, ...server.closeLedger])
          if (evictionCodes.contains(close.serverCloseCode)) close,
      ];

  /// Panels the gateway threw off **for being slow** — `backpressureOverrun`.
  ///
  /// The one eviction a slow-link row is actually about, and since 07-08b it
  /// is a *narrowing* rather than a workaround.
  ///
  /// It was introduced because of 07-08's finding: with no client heartbeat,
  /// every panel was reaped once a deadline for reasons that had nothing to do
  /// with the fault under test, so a row that asserted `evictions` empty over
  /// a long window was red about the background. **07-08b built the pump and
  /// that is no longer true** — F12 asserts `evictions` empty outright again.
  /// What this getter is still for is saying *which* eviction a row is about:
  /// "was anybody thrown off for being slow" is the question a backpressure
  /// row wants, and it stays the more precise one even now that the general
  /// question has a right answer.
  List<ConnectionClose> get evictedForBackpressure => [
        for (final close in [..._retired, ...server.closeLedger])
          if (close.serverCloseCode == CloseCodes.backpressureOverrun) close,
      ];

  /// Panels the gateway reaped for silence — `heartbeatTimeout`.
  ///
  /// **This is now an assertable zero for a healthy panel, and it was not when
  /// it was written.** 07-08 measured the defect through this getter: with no
  /// periodic client-to-gateway frame, `RelaySession`'s `_lastSeen` advanced
  /// only on inbound *application* frames and `RemoteStateMan` sent none on a
  /// timer, so a panel watching a page was closed with 4003 one
  /// `heartbeatDeadline` after its handshake, every time — sessions 1, 0, 1,
  /// 1, 1 and evictions 0, 1, 1, 1, 2 at three-second intervals, a reap and a
  /// redial about every six seconds for ever, at a full page resync per cycle
  /// per panel.
  ///
  /// **07-08b built `HeartbeatPump`** (client lib) and taught the gateway to
  /// advertise `heartbeatDeadlineMs` at `hello`, so the panel beats a `ping`
  /// at a third of that deadline while its link is ready. The same idle window
  /// now reads zero reaps and zero redials —
  /// `herd_gate_test.dart`'s idle-liveness case is that measurement inverted
  /// and it is the row that would go red if the pump ever stopped.
  ///
  /// So a row **may** assert this empty, and F12 and G2 both do: it is the
  /// cheapest available regression arm on the pump, on the two links in this
  /// suite where getting a frame out is hardest.
  List<ConnectionClose> get heartbeatReaps => [
        for (final close in [..._retired, ...server.closeLedger])
          if (close.serverCloseCode == CloseCodes.heartbeatTimeout) close,
      ];

  /// Every panel's observed close, in herd order.
  List<ObservedClose> get observedCloses =>
      [for (final one in clients) one.observedClose];

  /// Closes the gateway and starts a replacement on the **same port**, behind
  /// the same proxies, and returns how many rebinds it took.
  ///
  /// **The retry is named, and it is named because the probe only covered one
  /// platform.** 07-RESEARCH §A.3 executed the same-port rebind with twenty
  /// connections in `TIME_WAIT` and measured **0 ms on macOS** — `shelf`'s
  /// `serve` sets `SO_REUSEADDR`, and a listening socket in `TIME_WAIT` does
  /// not hold the port against it. Linux behaves the same way. **Windows was
  /// not measured**, and Windows is the platform where `SO_REUSEADDR` means
  /// something else entirely, so the bind is retried with a short backoff and
  /// the failure message says how many times it tried and on which port —
  /// a fixture that failed here with a bare `SocketException` would send the
  /// next reader looking for a bug in the gateway.
  ///
  /// [downtime] is spent between the close and the first rebind. Zero is the
  /// fastest restart the process can do and it is what F10 wants; a herd wants
  /// a number, because a gateway that is back before anybody's first retry
  /// never asks the backoff to spread anything and the row would measure an
  /// empty mechanism.
  ///
  /// The returned count is expected to be **0** on macOS and Linux. A case that
  /// prints it is recording the platform's answer rather than trusting this
  /// paragraph.
  Future<int> restartGateway({
    Duration downtime = Duration.zero,
    int attempts = 5,
  }) async {
    await _slot.server.close();
    // After the close, because the drain is what writes the outgoing
    // gateway's last ledger entries, and before the replacement exists,
    // because from here on `server` names a different object.
    _retired.addAll(_slot.server.closeLedger);
    if (downtime > Duration.zero) await Future<void>.delayed(downtime);

    var retries = 0;
    while (true) {
      final replacement = _buildGateway(served, port,
          complaints: gatewayComplaints,
          config: _gatewayConfig,
          tls: _tls,
          accounts: _accounts);
      try {
        await replacement.start();
        _slot.server = replacement;
        return retries;
      } on SocketException catch (error) {
        // Nothing to close: `RelayServer.start` binds first and only builds the
        // tick engine afterwards (`relay_server.dart:396-408`), so a bind that
        // threw leaves no listener and no timer behind.
        retries++;
        if (retries >= attempts) {
          fail('the replacement gateway could not bind port $port after '
              '$retries retries with a backoff between them: $error. The '
              'rebind was measured at 0 retries on macOS with twenty '
              'connections in TIME_WAIT (07-RESEARCH §A.3) and Windows was '
              'never measured, so this is the platform difference that probe '
              'left open — not a fault in the gateway');
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * retries));
      }
    }
  }

  /// Builds one more panel on a link that is already running, and appends it
  /// to [clients].
  ///
  /// **This is G2's whole injection and it has to happen while the link is
  /// bad.** The row is about a panel that joins a plant whose link is already
  /// throttled and flapping, so the panel cannot be one the fixture stood up
  /// during the quiet period and then woke — it has to dial for the first time
  /// into the conditions the case has already established. It is built by
  /// exactly the same code path as the herd (see `_buildPanel`), so nothing
  /// about it is a second kind of client.
  ///
  /// It does **not** wait for readiness: measuring how long that takes is the
  /// row's content, and a fixture that waited would have spent the measurement
  /// before handing the panel back.
  GateClient joinLate({FaultProxy? through, Set<String>? keys}) {
    final one = _buildPanel(
      index: clients.length,
      proxy: through ?? proxy,
      config: _config,
      keys: keys ?? _keys,
      tls: _tls,
    );
    clients.add(one);
    return one;
  }

  /// Waits until every panel in the herd reads [expected] for [key].
  ///
  /// **One budget for the whole herd, not one per panel.** A per-panel wait
  /// would let a straggler be averaged away: nineteen panels back in 200 ms and
  /// one back in nine seconds is exactly the starvation F11 forbids, and a loop
  /// of per-panel `until()` calls reports it as twenty passes. One window over
  /// the whole list fails naming the panels that did not make it.
  ///
  /// Returns each panel's convergence instant, in milliseconds from the call,
  /// in herd order — which is the fairness measurement F11 bands.
  Future<List<int>> untilAllRead(
    String key,
    Object? expected, {
    Duration budget = const Duration(seconds: 20),
  }) async {
    final started = Stopwatch()..start();
    final at = List<int?>.filled(clients.length, null);
    await until(
      'all ${clients.length} panels to read $expected for $key',
      () {
        for (var i = 0; i < clients.length; i++) {
          if (at[i] != null) continue;
          if (clients[i].client.read(key)?.value == expected) {
            at[i] = started.elapsedMilliseconds;
          }
        }
        return at.every((instant) => instant != null);
      },
      budget: budget,
    );
    return [for (final instant in at) instant!];
  }

  /// The keys this fixture's panels subscribed to.
  Set<String> get keys => _keys;
}

/// How a case says what gateway it wants, given the port the fixture pinned.
///
/// A builder rather than a bag of named knobs, because the knobs a slow-link
/// row needs are not the ones a herd row needs and the list would only grow:
/// F19 needs `tick: 100ms` at the band's edge, G5 needs a soft ceiling low
/// enough that a page can be held above it, and 07-11's rows will want their
/// own. A builder keeps the *whole* config visible at the case that depends on
/// it, which is where a reader looks when a row's numbers stop adding up.
typedef GatewayConfig = ServerConfig Function(int port);

/// [config]'s answer for [port], or the fixture's default, checked.
///
/// The check is not ceremony. The port is pinned at the first bind and every
/// replacement has to come back on it (see the library doc), so a builder that
/// forgot to pass `port:` would bind a fresh kernel-chosen port on the first
/// restart and every panel would spend the rest of the case dialling a port
/// nobody is listening on — which reads as a client that cannot reconnect
/// rather than as a fixture that moved the gateway.
ServerConfig _configFor(GatewayConfig? config, int port, FaultTls? tls) {
  if (config == null) {
    return ServerConfig(
      tick: ServerConfig.minTick,
      port: port,
      // Null on a plaintext leg, which is the default every other case in this
      // directory depends on.
      tls: tls == null
          ? null
          : TlsConfig(chainPath: tls.chainPath, keyPath: tls.keyPath),
    );
  }
  final built = config(port);
  if (built.port != port) {
    throw ArgumentError('this fixture pinned port $port and the serverConfig '
        'builder returned a config for port ${built.port}. The builder is '
        'handed the port precisely so it can pass it through: a gateway that '
        'came back on a different port would be behind nobody\'s proxy, and '
        'the panels would read as unable to reconnect');
  }
  if (tls != null && built.tls == null) {
    throw ArgumentError('this fixture was given a TLS mount and a serverConfig '
        'builder that returned no TlsConfig, so the gateway would listen in '
        'plaintext while every panel dialled wss and was refused — a whole '
        'case red for a reason that is in neither the case nor the gateway. A '
        'builder that wants the mount passes '
        'TlsConfig(chainPath: tls.chainPath, keyPath: tls.keyPath) through '
        'itself; the fixture cannot splice it in without silently overriding '
        'whatever else the builder decided');
  }
  return built;
}

/// Builds a gateway on [port] against [plant], with this package's fault-leg
/// settings unless [config] names its own.
///
/// One function so the first gateway and every replacement are built the same
/// way. A replacement that differed from the original in any respect would make
/// "the restarted gateway behaves like the original" a claim about this file.
RelayServer _buildGateway(
  FakeStateMan plant,
  int port, {
  required List<String> complaints,
  GatewayConfig? config,
  FaultTls? tls,
  UserResolver? accounts,
}) =>
    RelayServer(
      resolver: const PermissiveSeriesResolver(),
      accounts: accounts,
      api: plant,
      config: _configFor(config, port, tls),
      // Collected rather than printed, and collected rather than discarded.
      // `fault_fixture.dart:259-263` discards because every case there provokes
      // an error on purpose and a stack per provoked error trains everyone to
      // scroll past them — that argument holds for the printing and not for the
      // dropping. A herd is the shape that escapes an async error, so the
      // errors are kept where a case can assert over them and nothing is
      // written to stderr.
      onError: (error, _, where) => complaints.add('$where: $error'),
    );

/// Stands up a plant, a gateway on a fixed port, one or N proxies, and N real
/// panels — and wires the teardown so the whole herd is released in the order
/// the library doc argues for.
///
/// [seed] runs against the plant **before** the gateway starts, which is not a
/// convenience: the gateway classifies every key on a subscribe against
/// `api.keys` (`session_handlers.dart:154-164`) and `FakeStateMan.keys` does
/// not name a tag until a value has been set on it, so a key seeded after a
/// panel subscribed is rejected as a typo and is invisible for the rest of the
/// case no matter what the plant does with it.
///
/// [proxyPerClient] gives every panel its own proxy in front of the one
/// gateway. **F12 cannot be expressed without it.** `throttleBytesPerSec` is a
/// property of the proxy and reaches every pair it carries
/// (`fault_proxy.dart:513-517`), so "throttle one of two panels sharing a
/// proxy" is not a thing this instrument can do — a case that thought it had
/// done that would be throttling both and then asserting that neither was
/// affected, which is a green that measures nothing. One proxy per panel is the
/// honest arrangement and it changes nothing else: all of them target the same
/// gateway port, so the panels are still on one gateway.
///
/// [serverConfig] names the gateway this case wants, and is applied to the
/// replacement as well as to the first bind — see [GatewayConfig]. Absent, the
/// gateway runs at `ServerConfig.minTick` with every ceiling at its default,
/// which is what the herd rows were written against.
///
/// [waitForReady] leaves every panel subscribed and holding a value for every
/// key before this returns. Off is for a case that wants to watch the
/// establishment itself — and it is mandatory for a leg whose handshake is
/// meant to fail, which would otherwise burn [readyBudget] before the case
/// began.
///
/// [tls] switches the whole fixture to wss — see the library doc for what that
/// changes and, more importantly, for what it does not.
Future<GateFixture> gateFixture({
  int? clients,
  Set<String> keys = const <String>{},
  void Function(FakeStateMan plant)? seed,
  bool proxyPerClient = false,
  ClientConfig? config,
  GatewayConfig? serverConfig,
  bool waitForReady = true,
  Duration readyBudget = const Duration(seconds: 20),
  FaultTls? tls,
  UserResolver? accounts,
}) async {
  final n = clients ?? herdSize;
  if (n <= 0) {
    throw ArgumentError('a herd of $n panels is not a herd; pass a positive '
        'count or leave it to default to $defaultHerdSize');
  }
  final clientConfig = config ??
      faultClientConfig(
        tls: tls == null ? null : ClientTlsConfig(rootCertPath: tls.rootPath),
      );
  if (tls != null && clientConfig.tls == null) {
    throw ArgumentError('this fixture was given a TLS mount and a `config:` '
        'carrying no ClientTlsConfig, so every panel would dial wss with the '
        'machine\'s own trust store and be refused by its own gateway — which '
        'is a green anti-vacuity arm and a red everything else. Build the '
        'config with faultClientConfig(tls: ...), or with ClientTlsConfig('
        'rootCertPath: tls.rootPath) if the case also needs a token');
  }

  final served = FakeStateMan();
  addTearDown(served.dispose);
  seed?.call(served);

  final gatewayComplaints = <String>[];
  final retired = <ConnectionClose>[];

  // Port 0: the kernel picks, and the number it picks is what every
  // replacement binds. See the library doc on why the port is fixed from the
  // first bind rather than chosen here.
  final first = _buildGateway(served, 0,
      complaints: gatewayComplaints,
      config: serverConfig,
      tls: tls,
      accounts: accounts);
  await first.start();
  final slot = _GatewaySlot(first);
  final port = first.port;

  final proxies = <FaultProxy>[];
  for (var i = 0; i < (proxyPerClient ? n : 1); i++) {
    final proxy = FaultProxy(targetPort: port);
    await proxy.start();
    proxies.add(proxy);
  }
  addTearDown(() => slot.server.close());
  for (final proxy in proxies) {
    addTearDown(proxy.shutdown);
  }

  final herd = <GateClient>[];
  for (var i = 0; i < n; i++) {
    herd.add(_buildPanel(
      index: i,
      proxy: proxyPerClient ? proxies[i] : proxies.single,
      config: clientConfig,
      keys: keys,
      tls: tls,
    ));
  }

  final fixture = GateFixture._(served, slot, port, proxies, herd, keys,
      gatewayComplaints, retired, clientConfig, serverConfig, tls, accounts);

  if (waitForReady) {
    await until(
      'all $n panels to establish and hold a value for every one of '
      '${keys.length} keys',
      () => herd.every((one) =>
          one.client.isReady &&
          keys.every((key) => one.client.read(key) != null)),
      budget: readyBudget,
    );
  }
  return fixture;
}

/// One panel: its seam, its client, its recorder, and the three teardowns they
/// need registered in the right order.
///
/// Extracted so [gateFixture] and [GateFixture.joinLate] build a panel the same
/// way. A late joiner that differed from the herd in any respect would make
/// G2's "a client subscribing while the link is bad" a claim about the second
/// construction path rather than about the client.
GateClient _buildPanel({
  required int index,
  required FaultProxy proxy,
  required ClientConfig config,
  required Set<String> keys,
  FaultTls? tls,
}) {
  // No seam on a TLS leg, and no `dial:` either: the panel's own dial is what
  // carries the pinned client, and an override would test this file instead.
  // `fault_fixture.dart:276-285` states the same rule for the one-panel leg.
  final seam =
      tls == null ? FrameSeam(connectTimeout: config.connectTimeout) : null;
  late final GateClient one;
  final client = RemoteStateMan(
    uri: Uri.parse(
        '${tls == null ? 'ws' : 'wss'}://127.0.0.1:${proxy.port}'),
    config: config,
    keys: keys,
    // The seam's dial, with the attempt kept so the panel can be asked what
    // close it observed. `FrameSeam` does not retain it — it has no reason to,
    // and giving it one would put a second lifetime in a file five other waves
    // already depend on.
    dial: seam == null
        ? null
        : (uri) async {
            final attempt = await seam.dial(uri);
            one._last = attempt;
            return attempt;
          },
  );
  one = GateClient._(index, client, seam, proxy);
  addTearDown(client.dispose);
  // Registered after the dispose, so it runs *before* it: a subscription still
  // open while the panel tears its supervisor down is the shape that delivers a
  // transition into a closed recorder.
  final states = client.linkStates.listen(one.states.add);
  addTearDown(states.cancel);
  return one;
}

/// Long enough for the kernel to have caught up with a close before a
/// descriptor count is believed.
///
/// `tfc_stateman_contract/test/faults/fd_count_test.dart:50-60`'s number and
/// its reason, restated because that file is not importable from here: there is
/// no event for "the fd table has settled" — the kernel does not announce it —
/// so a count taken immediately after a teardown reads a half-settled table and
/// blames the code under test.
const Duration fdSettle = Duration(milliseconds: 400);

/// Polls [openSocketCount] until it is back within [tolerance] of [baseline],
/// or [budget] runs out, and returns the last reading.
///
/// A window rather than one reading after a sleep, for the same reason every
/// other wall-clock property in this directory is a window: `destroy()` returns
/// before the descriptor closes, and how long "before" is depends on the
/// runner.
Future<int> untilSocketsSettle(
  int baseline, {
  int tolerance = 0,
  Duration budget = const Duration(seconds: 10),
}) async {
  await Future<void>.delayed(fdSettle);
  final deadline = DateTime.now().add(budget);
  var last = openSocketCount();
  while (last > baseline + tolerance && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    last = openSocketCount();
  }
  return last;
}
