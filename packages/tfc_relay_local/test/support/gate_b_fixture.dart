/// A whole pipe in one setUp: N fake PLC links into a `LocalStateMan`, a real
/// `RelayServer` on an ephemeral port, and N real `RemoteStateMan` panels over
/// real sockets — with the counters that let gate B's seven rows measure
/// rather than assume.
///
/// **The shape is copied from `tfc_relay_client/test/support/gate_fixture.dart`
/// with its reasons restated, not imported** — no `package:` URI reaches
/// another package's `test/` directory, which is the same reason that file and
/// `fault_fixture.dart` are already copies of each other's ideas rather than
/// one import. Where this file diverges, the divergence is the point: gate A's
/// plant is a `FakeStateMan`; this plant is the real `LocalStateMan` composed
/// over per-alias `FakeUpstreamLink`s, because gate B's rows are about the
/// upstream boundary — a PLC reprogramming, a poisoned poll cycle — and a
/// fixture whose plant has no upstream has no boundary to poison.
///
/// **Teardown order, and why it is registered backwards** (gate A's argument,
/// `gate_fixture.dart:18-36`, restated). `addTearDown` runs
/// last-registered-first, so registrations read backwards from execution:
/// plant, then proxies, then the gateway, then every panel — executing as
/// **all panels, then the gateway, then the proxies, then the plant (which
/// owns and disposes the links)**. The panel goes first because it is the only
/// participant that *reconnects*: a gateway closed under a live panel leaves
/// that panel dialling a dead port for the rest of the run, and the attempts
/// land as noise on whichever case is unlucky enough to be running then. The
/// proxies cannot go first because shutting one down destroys both halves of
/// every pair it carries. The plant goes last because its freshness sweep and
/// its links must outlive anything still draining through them —
/// `LocalStateMan.dispose` disposes the links itself
/// (`local_state_man.dart:386-388`), so the links need no registration of
/// their own and giving them one would only be a second lifetime for the same
/// objects.
///
/// **The composition is `buildGateway`'s, restated.** `buildGateway` builds
/// its links from config and cannot take these fakes, so this file composes
/// the same three pieces in the same order — `LocalStateMan` under
/// `RelayServer` with `wireStatusNotifications` between them — that
/// `gateway_config.dart:573-617` composes, status wiring included, because a
/// pipe whose panels never hear a status notification is the exact
/// half-composition 08-13 deviation 1 records shipping once already.
///
/// **Port 0, always.** 08-03's ninth freeze: no literal port anywhere under
/// `test/`, so two worktrees can run this suite at once. The OS picks the
/// port; the panels dial what it picked.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AuthenticatedUser;
import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart'
    show FaultProxy, openSocketCount;

import 'fake_upstream_link.dart';
import 'keymap_fixtures.dart';
import 'permissive_resolver.dart';

// `within(future, what, {budget})` — the one future-bounder in the tree,
// re-exported so a gate case gets both window helpers from this one import.
// Imported rather than copied because it lives in the contract package's LIB
// (`src/check.dart`), which a dev dependency reaches fine — the copy rule
// above is about another package's test/, and `until` below is the copy.
export 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

/// Polls [done] until it holds or [budget] runs out, and fails naming [what].
///
/// Copied from `tfc_relay_client/test/support/fault_fixture.dart:307-319` with
/// its reason: a poll rather than a stream wait because gate cases assert a
/// *state* the pipe reached, and the transition that got it there is the
/// layer-below's business. Copied, not imported — no `package:` URI reaches
/// another package's `test/`.
Future<void> until(
  String what,
  bool Function() done, {
  Duration budget = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A page of [n] keys under [alias], in the plant's own `AREAnn.DEVnn.SUBnn`
/// shape.
///
/// Realistic width, for `gate_fixture.dart:107-130`'s reason: the wire cost
/// arithmetic in the slow-link rows is computed from names like
/// `ST101.CN01.MOT01.setpoint` (25 characters), and `key0`…`key199` would be
/// less than half of it — a page built out of short names measures a link
/// with twice the headroom it claims. Twenty devices of five motors each puts
/// 100 keys under one area, so a 200-key page spans CN01–CN40 without
/// repeating a name.
List<String> gateBPage(String alias, int n) {
  if (n <= 0 || n > 300) {
    throw ArgumentError('a page of $n keys per alias is outside 1-300; the '
        'scheme below runs out of plausible device numbers past that, and a '
        'key shaped implausibly is a page that stops reading like a page');
  }
  return [
    for (var i = 0; i < n; i++)
      '$alias'
          '.CN${(i ~/ 5 + 1).toString().padLeft(2, '0')}'
          '.MOT${(i % 5 + 1).toString().padLeft(2, '0')}.setpoint',
  ];
}

/// One fake PLC, wrapped with the two behaviours gate B's rows need that the
/// plain [FakeUpstreamLink] deliberately does not carry.
///
/// **Why a wrapper and not a subclass.** `FakeUpstreamLink` is a `final
/// class`, so nothing outside its library can extend it; `UpstreamLink` is an
/// `abstract interface class`, so anything can implement it. The wrapper
/// delegates every `UpstreamLink` member to the inner fake and intercepts
/// exactly two things: the reprogram choreography and the per-alias string
/// decode. Levers a row pulls that need no interception — `emitRaw`,
/// `setValue`, `disconnectUpstream`, `statusNotifications` and the rest —
/// are reached through [inner], on purpose: a delegate for every lever would
/// be a second copy of the driver interface that drifts.
///
/// **The reprogram choreography mirrors 08-08's four-step bump order**
/// (`opcua_upstream_link.dart`, proven in `epoch_test.dart`'s BUMP ORDER
/// arm): degrade every key of this link in one pass, THEN announce
/// `reprogrammed` once, THEN mark every issued ref stale, and run exactly one
/// re-browse. The plain fake's `bumpEpoch` owns only the staleness half —
/// 08-03 built it for 08-08's unit arms, where the link under test was the
/// real adapter — so the announcement and the degrade live here, where a
/// two-alias pipe needs them. The re-browse is completed by [completeReBrowse]
/// under the *test's* control rather than on a timer, so "affected keys
/// bad-quality **until re-browse completes**" is a window the case opens and
/// closes deterministically instead of a race against the plant driver.
///
/// While the latch is up, [setValues] drops sweeps (counting them): a PLC
/// mid-download delivers no samples, and a sweep that landed during the
/// window would overwrite the degrade this choreography exists to prove.
final class GateBLink implements UpstreamLink {
  GateBLink({
    required String alias,
    required Iterable<String> keys,
    this.encoding = ServerStringEncoding.utf8,
  }) : inner = FakeUpstreamLink(alias: alias, keys: keys) {
    _pipe = inner.stateStream.listen(_states.add);
  }

  /// The plain fake underneath. Every lever the driver interface names is
  /// pulled here, before `start()`, never over the wire.
  final FakeUpstreamLink inner;

  /// The string encoding this alias is *configured* with — the same
  /// per-alias fact `StringEncodingConfig` carries for the real adapters
  /// (08-10 task 3), threaded to [emitPlantBytes] exactly as
  /// `buildUpstreamLink` threads `latin1DecoderFor` into the Modbus clients.
  final ServerStringEncoding encoding;

  final StreamController<UpstreamLinkState> _states =
      StreamController<UpstreamLinkState>.broadcast();
  late final StreamSubscription<UpstreamLinkState> _pipe;

  bool _reprogramming = false;
  int _reBrowses = 0;
  int _suppressedSweeps = 0;
  int _deadLinkSweeps = 0;

  /// How many re-browses have run. Exactly one per bump is F24's clause.
  int get reBrowses => _reBrowses;

  /// Sweeps [setValues] dropped while the reprogram latch was up.
  int get suppressedSweeps => _suppressedSweeps;

  /// Sweeps [setValues] dropped because the link was disconnected — F27's
  /// injection window, counted so a case can prove the plant stayed busy
  /// while the link stayed silent.
  int get deadLinkSweeps => _deadLinkSweeps;

  /// A PLC program download, as the panel would see one.
  ///
  /// The order is the property (08-08: degrade, announce, stale — in that
  /// order and once each). `LocalStateMan._onLinkState` hears the
  /// `reprogrammed` transition, degrades this alias's keys in the store in
  /// one batch BEFORE announcing (its own degrade-then-announce rule), and
  /// sends the panels exactly one status notification.
  void bumpEpoch() {
    if (_reprogramming) {
      throw StateError('bumpEpoch under a live reprogram latch: the previous '
          'bump has not completed its re-browse, and overlapping the two '
          'would make the re-browse count unreadable');
    }
    inner.applyLinkLoss(); // 1. every key on THIS link, one pass
    _reprogramming = true; // 2. the latch: `state` now reads reprogrammed
    inner.announceLinkState(); //    once, however many keys it cost
    _states.add(UpstreamLinkState.reprogrammed);
    inner.bumpEpoch(); // 3. every ref issued so far is now stale
  }

  /// The re-browse completing: keys come back `uncertainLastKnown` — the link
  /// being re-browsed is not evidence about any number — and go good again
  /// only as the plant re-delivers them.
  void completeReBrowse() {
    if (!_reprogramming) {
      throw StateError('completeReBrowse with no bump in flight: a re-browse '
          'that runs without a reprogram is a count that moved for nothing');
    }
    _reBrowses++; // 4. exactly one per bump
    _reprogramming = false;
    inner.applyLinkRestored();
    inner.announceLinkState();
    _states.add(UpstreamLinkState.connected);
  }

  /// One string sample arriving from the plant as **bytes**, decoded under
  /// this alias's configured [encoding] — `decodePlantString` is 08-10's real
  /// mechanism, not a re-implementation, and the quality it mints
  /// (`good` / `uncertainEncoding` 260) rides the value to the panel.
  void emitPlantBytes(String key, List<int> bytes) {
    final decoded = decodePlantString(bytes, encoding: encoding);
    inner.setValue(key, decoded.text, quality: decoded.quality);
  }

  /// The plant driver's entry: dropped, and counted, while a reprogram is in
  /// flight — a PLC mid-download delivers no samples.
  ///
  /// **A disconnected PLC delivers no samples either** (F27, 09-06). The
  /// plain fake publishes whatever a lever hands it regardless of its own
  /// `state` — a lever is the hand of god, on purpose — but the *driver's*
  /// sweep stands in for the PLC's own poll cycle, and a dead PLC does not
  /// poll. Without this drop, the sweep after `disconnectUpstream()` would
  /// republish fifty good values into a dead link and silently heal the very
  /// degrade the row injects, so the fixture would be lying about its own
  /// injection. Guarded on [UpstreamLink.birthCount] so the seed sweep —
  /// which runs before `plant.start()` connects anything — still lands.
  /// The raw seams ([GateBPlantDriver.overrideRaw], [emitPlantBytes]) are
  /// deliberately not gated: an override is a per-key hand of god, and F27a
  /// leans on its poison persisting across the outage.
  void setValues(Map<String, Object?> values) {
    if (_reprogramming) {
      _suppressedSweeps++;
      return;
    }
    if (inner.birthCount > 0 &&
        inner.state == UpstreamLinkState.disconnected) {
      _deadLinkSweeps++;
      return;
    }
    inner.setValues(values);
  }

  // ------------------------------------------------ UpstreamLink, delegated

  @override
  String get alias => inner.alias;

  @override
  UpstreamLinkState get state =>
      _reprogramming ? UpstreamLinkState.reprogrammed : inner.state;

  @override
  Stream<UpstreamLinkState> get stateStream => _states.stream;

  @override
  String? get lastError => inner.lastError;

  @override
  String get epoch => inner.epoch;

  @override
  Stream<String> get epochStream => inner.epochStream;

  @override
  int get birthCount => inner.birthCount;

  @override
  DateTime? get lastDeathAt => inner.lastDeathAt;

  @override
  bool get supportsWrites => inner.supportsWrites;

  @override
  bool get supportsBrowse => inner.supportsBrowse;

  @override
  int get upstreamSubscriptionsCreated => inner.upstreamSubscriptionsCreated;

  @override
  UpstreamRef? resolve(String key, Object mappingEntry) =>
      inner.resolve(key, mappingEntry);

  @override
  DynamicValue? peek(UpstreamRef ref) => inner.peek(ref);

  @override
  Future<DynamicValue> read(UpstreamRef ref, {required Duration deadline}) =>
      inner.read(ref, deadline: deadline);

  @override
  Future<WriteResult> write(
    UpstreamRef ref,
    DynamicValue value, {
    required String cmd,
    required Duration deadline,
    bool hasExpect = false,
  }) =>
      inner.write(ref, value,
          cmd: cmd, deadline: deadline, hasExpect: hasExpect);

  @override
  Stream<DynamicValue> subscribe(UpstreamRef ref) => inner.subscribe(ref);

  @override
  Future<void> connect({required Duration deadline}) =>
      inner.connect(deadline: deadline);

  @override
  Future<void> dispose() async {
    await _pipe.cancel();
    await _states.close();
    await inner.dispose();
  }
}

/// A plant that moves every key of every link on a period, and counts what it
/// did.
///
/// Copied from `gate_fixture.dart:156-219` with its reason: a gate row's
/// first question is always "was the plant actually busy?" — a pipe proven
/// against a quiet plant is measuring the freshness follow-up rather than the
/// pipe. [sweeps] and [writes] are what that arm reads; [latest] is what a
/// conflation arm compares the last delivered value against. **The first
/// sweep is synchronous**, so a driver started immediately before a
/// measurement window is not off by one frame.
final class GateBPlantDriver {
  GateBPlantDriver._(this.period, this.from);

  /// How often every key on every link is given a new value.
  final Duration period;

  /// The value the first sweep writes.
  final int from;

  Timer? _timer;
  int _sweeps = 0;
  int _pageSize = 0;

  final Map<GateBLink, Map<String, Object?>> _rawOverrides =
      <GateBLink, Map<String, Object?>>{};
  final Map<GateBLink, Map<String, List<int>>> _byteOverrides =
      <GateBLink, Map<String, List<int>>>{};

  /// From the next poll cycle on, [key] arrives from the plant as [raw] —
  /// every cycle, through `emitRaw`, exactly where the ingest guard lives.
  ///
  /// This is what an open-circuit 4–20 mA input or a divide-by-zero in a
  /// weigher rate calc actually looks like: the device does not poison one
  /// sample and recover, it keeps reporting the poison until somebody fixes
  /// the loop. A one-shot injection would also race the sweep — the pipe
  /// conflates, so a poison published between two sweeps can be superseded
  /// before a tick carries it, and the row would flake about the scheduler.
  void overrideRaw(GateBLink link, String key, Object? raw) {
    _rawOverrides.putIfAbsent(link, () => <String, Object?>{})[key] = raw;
  }

  /// From the next poll cycle on, [key] arrives from the plant as [bytes],
  /// decoded under the link's configured encoding — the 08-10 seam, every
  /// cycle, for the same persistence reason as [overrideRaw].
  void overrideBytes(GateBLink link, String key, List<int> bytes) {
    _byteOverrides.putIfAbsent(link, () => <String, List<int>>{})[key] = bytes;
  }

  /// How many times the whole plant has been moved.
  int get sweeps => _sweeps;

  /// How many key-writes that is — the number an "is the plant busy" arm
  /// bands.
  int get writes => _sweeps * _pageSize;

  /// The value the last sweep wrote, or null before the first one.
  /// Monotonic by construction.
  int? get latest => _sweeps == 0 ? null : from + _sweeps - 1;

  void _sweep(Map<GateBLink, List<String>> pages) {
    final value = from + _sweeps;
    _sweeps++;
    _pageSize = 0;
    for (final entry in pages.entries) {
      final link = entry.key;
      final raws = _rawOverrides[link] ?? const <String, Object?>{};
      final bytes = _byteOverrides[link] ?? const <String, List<int>>{};
      _pageSize += entry.value.length;
      // One poll cycle: the clean keys as one batch, then the overridden
      // keys through the raw seams — per key, which is the guard 08-05
      // pins ("one poisoned tag costs one tag, never a poll cycle").
      link.setValues({
        for (final key in entry.value)
          if (!raws.containsKey(key) && !bytes.containsKey(key)) key: value,
      });
      for (final poisoned in raws.entries) {
        link.inner.emitRaw(poisoned.key, poisoned.value);
      }
      for (final poisoned in bytes.entries) {
        link.emitPlantBytes(poisoned.key, poisoned.value);
      }
    }
  }

  /// Idempotent, so a case may stop the plant early and the teardown still
  /// runs without knowing whether it did.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// One panel of the pipe: its client, what it heard, and its private proxy if
/// it has one.
final class GateBPanel {
  GateBPanel._(this.index, this._client, this._proxy, this._token);

  /// Its position, for the messages a multi-panel case has to print.
  final int index;

  RemoteStateMan _client;

  /// The implementation under test — a real `RemoteStateMan` over a real
  /// socket, because a hand-rolled client would be this package asserting
  /// against its own idea of what a panel does (08-13's pubspec argument).
  ///
  /// **Not final, because of [GateBFixture.redial].** Phase 6 stops a panel's
  /// reconnect loop for good when its credential is refused — that is the
  /// design, not a bug — so restoring a revoked station means standing a new
  /// client up, exactly as the operator restarting the app would. Every gate-B
  /// row reads this once and never notices; the soak replaces it.
  RemoteStateMan get client => _client;

  /// The credential this panel dials with, or null on a gateway with no token
  /// file. Held so a redial presents the same one.
  final String? _token;

  /// Every status notification this panel received, in order — read off
  /// `onStatus`, so an entry here is proof the DTO crossed the wire whole and
  /// parsed at a conforming client.
  final List<StatusParams> statuses = <StatusParams>[];

  final FaultProxy? _proxy;

  /// The fault seam this panel dials through.
  ///
  /// **Throws** when the leg has no proxy, rather than answering null —
  /// `gate_fixture.dart:452-460`'s rule pointed the other way: a case that
  /// pulled a lever on a null-safe proxy would be shaping nothing and
  /// asserting about everything.
  FaultProxy get proxy {
    final proxy = _proxy;
    if (proxy == null) {
      throw StateError('panel $index dials the gateway directly: this fixture '
          'was built proxyPerPanel: false, so there is no fault seam on this '
          'leg. Build the fixture with proxyPerPanel: true and say in the '
          'case which panel is being shaped');
    }
    return proxy;
  }
}

/// Everything a gate-B row drives.
final class GateBFixture {
  GateBFixture._(
    this.links,
    this.plant,
    this._server,
    this.port,
    this.proxies,
    this.panels,
    this.keys,
    this.gatewayComplaints,
    this.driver,
    this._status,
    this.mappings,
    this._config,
  );

  /// One link per alias, in the order the aliases were given.
  final List<GateBLink> links;

  /// The real composer the server is a projection of. Levers go to the links,
  /// never here and never over the wire.
  final LocalStateMan plant;

  RelayServer _server;
  StreamSubscription<StatusParams> _status;

  /// The gateway's socket half.
  ///
  /// **Not final, because of [restartGateway].** `RelayServer.start()` refuses
  /// on a closed server by design (*"its sessions are gone and its registry is
  /// disposed. Build a new one"*), so a gateway restart is a new object on the
  /// same port rather than a stopped one resumed.
  RelayServer get server => _server;

  /// The routing table the plant was composed with, so a caller can re-ingest
  /// it through `plant.router.applyKeyMappings` without rebuilding it from the
  /// pages — the live-editable path 08-PATTERNS §2 describes.
  final KeyMappings mappings;

  final ServerConfig _config;

  /// The ephemeral port the OS picked at bind.
  ///
  /// Fixed for the life of the fixture: [restartGateway] rebinds this exact
  /// number, because the proxies in front of it were built pointing at it and
  /// a restart that moved the port would be a restart no panel could follow.
  final int port;

  /// The proxies, one per panel — or empty on a direct-dial fixture.
  final List<FaultProxy> proxies;

  /// The panels, in the order they were dialled.
  final List<GateBPanel> panels;

  /// Every plant key plus the health keys the panels subscribed to.
  final Set<String> keys;

  /// Everything the gateway complained about, collected through the
  /// `RelayErrorHandler` seam and **never printed** — a stack per provoked
  /// error trains everyone to scroll past them, and discarding would make
  /// "no escaped async errors" a claim nothing can refute
  /// (`gate_fixture.dart:410-418`'s argument, held whole).
  final List<String> gatewayComplaints;

  /// The plant driver, so every row can answer "was the plant actually busy?".
  final GateBPlantDriver driver;

  /// Clients [redial] replaced, kept so [dispose] can close their sockets too.
  final List<RemoteStateMan> _retired = <RemoteStateMan>[];

  /// Every client [redial] has replaced, oldest first.
  ///
  /// **The fixture's own record of its own event, and the reason it is exposed
  /// is that the alternatives are incidental.** A caller can recover the
  /// retired clients by diffing a set it accumulated itself against
  /// [panels] — but such a set is populated by whatever sampler happened to
  /// tick while a client was live, so it is true by cadence rather than by
  /// construction. This list is appended by [redial] unconditionally, before
  /// the old client is disposed.
  ///
  /// It matters because `dispose()` does **not** clear `RemoteStateMan`'s
  /// unresolved-write set: a retired client still answers
  /// `debugUnresolvedCmds` with whatever was in flight when it was replaced.
  /// So "which commands went down with a replaced client?" is an answerable
  /// question, and this is what answers it — see the identity-versus-magnitude
  /// note on `_LivePanelLogView` in `soak_driver.dart`.
  List<RemoteStateMan> get retiredClients =>
      List<RemoteStateMan>.unmodifiable(_retired);

  bool _disposed = false;

  /// The first panel, for the ordinary one-panel row.
  GateBPanel get panel => panels.first;

  /// The link for [alias], or a failure that names what was asked for.
  GateBLink linkFor(String alias) => links.firstWhere(
        (link) => link.alias == alias,
        orElse: () => throw StateError('no link with alias "$alias" in this '
            'fixture (have: ${[for (final link in links) link.alias]})'),
      );

  /// How many panels the gateway is holding.
  int get sessionCount => server.sessions.sessionCount;

  /// The close codes that mean the gateway threw a panel off.
  ///
  /// **`serverDraining` (4002) is deliberately not here** — it is what
  /// `RelayServer.close` sends every live session on its own way out, so it
  /// is the signature of a planned drain (a restart, or this fixture's
  /// teardown), not of an eviction. Counting it would make every row red for
  /// having done the thing it was asked to do (`gate_fixture.dart:480-494`).
  static const Set<int> evictionCodes = <int>{
    CloseCodes.authExpired,
    CloseCodes.heartbeatTimeout,
    CloseCodes.backpressureOverrun,
  };

  /// Every close the gateway initiated that was an eviction. Asked of the
  /// gateway's own ledger rather than of the panels, because from a panel's
  /// side a flap and an eviction are the same dead socket.
  List<ConnectionClose> get evictions => [
        for (final close in server.closeLedger)
          if (evictionCodes.contains(close.serverCloseCode)) close,
      ];

  /// Panels the gateway reaped for silence — the 07-08b pump's regression
  /// arm, assertable at zero for a healthy panel.
  List<ConnectionClose> get heartbeatReaps => [
        for (final close in server.closeLedger)
          if (close.serverCloseCode == CloseCodes.heartbeatTimeout) close,
      ];

  /// Per-link state announcements, by alias. One per mass-degradation, never
  /// one per key.
  int statusNotificationsOf(String alias) =>
      linkFor(alias).inner.statusNotifications;

  /// Upstream subscription creates, by alias. **Deltas of creates, never a
  /// balance** — there is deliberately no delete counter (freeze 7).
  int upstreamSubscriptionsCreatedOf(String alias) =>
      linkFor(alias).upstreamSubscriptionsCreated;

  /// Stands a fresh client up for [index], on the same leg and with the same
  /// credential, and retires the one it replaces.
  ///
  /// **The only way a stopped panel comes back.** `ConnectionSupervisor._stop`
  /// is terminal — a refused credential ends the reconnect loop and nothing
  /// resumes it, which is Phase 6's decision and the right one: a panel that
  /// retried a rejected token would hammer the gateway all shift. So restoring
  /// a station is what it is in the plant, an application restart, and this is
  /// that in one call.
  ///
  /// The old client is disposed but kept in [_retired] rather than dropped:
  /// `dispose` is idempotent, and a descriptor-count arm needs every socket
  /// this fixture ever opened to be closed by the time it counts.
  Future<void> redial(int index, {Duration? readyBudget}) async {
    final one = panels[index];
    final previous = one._client;
    _retired.add(previous);
    await previous.dispose();
    final proxy = one._proxy;
    one._client = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${proxy?.port ?? port}'),
      config: _clientConfig(one._token),
      keys: keys,
      onStatus: one.statuses.add,
    );
    if (readyBudget != null) {
      await until(
        'panel $index to come back after a redial',
        () => one._client.isReady,
        budget: readyBudget,
      );
    }
  }

  /// Stops the gateway and stands a new one up **on the same port**.
  ///
  /// `RelayServer.start()` refuses on a closed server, so this builds a second
  /// one over the same plant and rewires `wireStatusNotifications` — the same
  /// three pieces in the same order `buildGateway` composes, which is the
  /// composition this file's library doc says it restates.
  ///
  /// **The rebind is retried rather than assumed.** `close(force: true)`
  /// returns before the kernel has finished with the listening socket, and how
  /// long "before" is depends on the platform — the same fact
  /// [untilSocketsSettle] exists for. A bounded retry turns a platform timing
  /// detail into a slower restart instead of a dead pipe; exhausting it throws,
  /// because a gateway that never came back is a finding and not a wait.
  Future<void> restartGateway({
    Duration rebindBudget = const Duration(seconds: 10),
  }) async {
    await _status.cancel();
    await _server.close();

    final config = ServerConfig(
      tick: _config.tick,
      auth: _config.auth,
      port: port,
    );
    final deadline = Stopwatch()..start();
    Object? lastError;
    while (deadline.elapsed < rebindBudget) {
      final replacement = RelayServer(
        resolver: const PermissiveSeriesResolver(),
        // The restarted gateway must be built exactly like the original —
        // a replacement that could not resolve accounts would refuse to
        // start and read as "the port never came back".
        accounts: soakAccounts,
        api: plant,
        config: config,
        onError: (error, _, where) => gatewayComplaints.add('$where: $error'),
      );
      final status = wireStatusNotifications(plant, replacement,
          publisherId: config.publisherId);
      try {
        await replacement.start();
        _server = replacement;
        _status = status;
        return;
      } catch (error) {
        lastError = error;
        await status.cancel();
        await replacement.close();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError('the gateway did not rebind port $port within '
        '${rebindBudget.inSeconds}s of being closed; the last attempt failed '
        'with: $lastError');
  }

  ClientConfig _clientConfig(String? token) => token == null
      ? ClientConfig()
      // The plaintext gate is opened deliberately and only here: this fixture
      // dials `ws://` on loopback, and `ClientConfig` refuses to put a token
      // on an unencrypted dial unless it is told the deployment accepts it.
      // A production panel gets `wss://` and never reaches this branch.
      : ClientConfig(token: token, allowTokenOverPlaintext: true);

  /// Tears the pipe down in the argued order — panels, gateway, proxies,
  /// plant — so a case can watch the descriptor count settle back to its own
  /// baseline *inside* the case. Every step is idempotent, so the
  /// registrations `gateBFixture` made replay as no-ops afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    driver.cancel();
    for (final one in panels) {
      await one.client.dispose();
    }
    for (final retired in _retired) {
      await retired.dispose();
    }
    await _status.cancel();
    await _server.close();
    for (final proxy in proxies) {
      await proxy.shutdown();
    }
    await plant.dispose();
  }
}

/// Long enough for the kernel to have caught up with a close before a
/// descriptor count is believed. `gate_fixture.dart:927-935`'s number and its
/// reason, restated because that file is not importable from here: there is
/// no event for "the fd table has settled", so a count taken immediately
/// after a teardown reads a half-settled table and blames the code under
/// test.
const Duration fdSettle = Duration(milliseconds: 400);

/// Polls [openSocketCount] until it is back within [tolerance] of [baseline],
/// or [budget] runs out, and returns the last reading. A window rather than
/// one reading after a sleep: `destroy()` returns before the descriptor
/// closes, and how long "before" is depends on the runner
/// (`gate_fixture.dart:937-957`, copied with its reason).
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

/// Stands the whole pipe up — links seeded, gateway started, panels dialled,
/// in that order and no other — and registers the teardown the library doc
/// argues for.
///
/// [seed] runs against each link **before** the gateway starts. The house
/// rule's reason: `session_handlers.dart` classifies unknown keys as typos,
/// and while `LocalStateMan.keys` is derived from the router's mappings
/// rather than from seen values, a fixture that seeded late would still hand
/// the first tick a page of `uncertainNotYetKnown` — so the driver's first
/// sweep is synchronous and happens here, before anything is served.
///
/// [proxyPerPanel] gives every panel its own `FaultProxy` in front of the one
/// gateway; off, the panels dial the bound port directly and
/// [GateBPanel.proxy] throws.
///
/// [serverConfig], when given, must keep the port at zero — the
/// ephemeral-port rule is the fixture's, not the caller's to trade away.
///
/// [encodings] is the per-alias string-encoding table, `StringEncodingConfig`
/// itself so the fixture consumes 08-10's real configuration surface rather
/// than a parallel one.
///
/// [tokenFor] gives panel *i* its credential, for a [serverConfig] that names
/// an `AuthConfig`. Null — the default — is a gateway with no token file, and
/// every gate-B row stays on that path.
///
/// The soak's account source, standing in for the plant's `app_user` table.
///
/// 17-04b split the credential from the grant: the token file says which USER
/// a station authenticates as, and this answers what that user may do. The
/// soak's panels are all plain operators — it measures transport resilience,
/// not authorisation — so every soak panel resolves to the operate group and
/// **anything else resolves to null**, which is a refusal. A resolver that
/// answered for every name would be the permissive fallback
/// `RelayServer.start` explicitly refuses to have.
ResolvedUser? soakAccounts(String username) {
  if (!RegExp(r'^panel-\d+$').hasMatch(username)) return null;
  return ResolvedUser(
    user: AuthenticatedUser(
        username: username, roleName: 'Operator', stationAccount: true),
    groups: const {AccessGroup.operate},
  );
}

Future<GateBFixture> gateBFixture({
  int panels = 1,
  List<String> aliases = const <String>['ST101', 'ST201'],
  int keysPerAlias = 50,
  void Function(GateBLink link)? seed,
  bool proxyPerPanel = false,
  ServerConfig? serverConfig,
  bool waitForReady = true,
  Duration readyBudget = const Duration(seconds: 30),
  StringEncodingConfig encodings = const StringEncodingConfig(),
  Duration sweepPeriod = const Duration(milliseconds: 100),
  Duration staleAfter = const Duration(seconds: 30),
  String? Function(int index)? tokenFor,
}) async {
  if (panels <= 0) {
    throw ArgumentError('a pipe with $panels panels serves nobody');
  }
  if (aliases.isEmpty || aliases.toSet().length != aliases.length) {
    throw ArgumentError('aliases must be non-empty and distinct (got '
        '$aliases): two links claiming one alias is two producers for every '
        'one of its health keys');
  }
  // `ServerConfig.port` DEFAULTS to zero (Phase 6 landed the field for
  // exactly this), so the ephemeral bind is spelled by omission — no number
  // for the no-literal-port sweep to even squint at.
  final config = serverConfig ?? ServerConfig(tick: ServerConfig.minTick);
  if (config.port != 0) {
    throw ArgumentError('this fixture binds port 0 — the OS picks, so two '
        'worktrees can run this suite at once (08-03 freeze 9). A '
        'serverConfig naming its own port re-introduces exactly the '
        'collision that freeze exists to prevent');
  }

  // The links, one per alias, each claiming exactly its own page — an empty
  // key set on FakeUpstreamLink claims EVERYTHING, which a per-alias fixture
  // must never do.
  final pages = <GateBLink, List<String>>{};
  final links = <GateBLink>[];
  for (final alias in aliases) {
    final page = gateBPage(alias, keysPerAlias);
    final link = GateBLink(
      alias: alias,
      keys: page,
      encoding: encodings.encodingFor(alias),
    );
    links.add(link);
    pages[link] = page;
  }

  final mappings = KeyMappings(nodes: {
    for (final entry in pages.entries)
      for (final key in entry.value)
        key: opcUaEntry(alias: entry.key.alias, identifier: key),
  });

  final plant = LocalStateMan(
    links: links,
    router: KeyRouter.overLinks(links, mappings: mappings),
    staleAfter: staleAfter,
  );
  // Registered FIRST, so it executes LAST: the plant outlives everything
  // still draining through it, and it disposes the links itself.
  addTearDown(plant.dispose);

  // Seed, then the first synchronous sweep — both strictly before the
  // gateway exists, which is the lifecycle rule this file's doc names.
  for (final link in links) {
    seed?.call(link);
  }
  final driver = GateBPlantDriver._(sweepPeriod, 1000);
  driver._sweep(pages);
  driver._timer = Timer.periodic(sweepPeriod, (_) => driver._sweep(pages));
  addTearDown(driver.cancel);

  await plant.start();

  final gatewayComplaints = <String>[];
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    accounts: soakAccounts,
    api: plant,
    config: config,
    // Collected rather than printed, and collected rather than discarded —
    // see [GateBFixture.gatewayComplaints].
    onError: (error, _, where) => gatewayComplaints.add('$where: $error'),
  );
  // SRV-08's wiring, made here exactly as `buildGateway` makes it — a pipe
  // whose panels never hear a status notification is 08-13 deviation 1.
  final status = wireStatusNotifications(plant, server,
      publisherId: config.publisherId);
  await server.start();
  final port = server.port;

  final proxies = <FaultProxy>[];
  if (proxyPerPanel) {
    for (var i = 0; i < panels; i++) {
      final proxy = FaultProxy(targetPort: port);
      await proxy.start();
      proxies.add(proxy);
    }
  }
  // Proxies registered before the gateway's own teardown, so the gateway
  // closes BEFORE they do; both after the plant's, so both run before it.
  for (final proxy in proxies) {
    addTearDown(proxy.shutdown);
  }
  // Through the fixture rather than over the captured `server`, so that a
  // gateway [GateBFixture.restartGateway] replaced is the one that gets closed.
  // Closing the original a second time is a no-op and closing the replacement
  // never happens at all, which is a listening socket surviving the case that
  // opened it. Nullable rather than `late`, because a fixture that threw before
  // it was built must not turn its own failure into a LateInitializationError
  // in teardown.
  GateBFixture? built;
  addTearDown(() async {
    await (built?._status ?? status).cancel();
    await (built?._server ?? server).close();
  });

  final keys = <String>{
    for (final page in pages.values) ...page,
    for (final alias in aliases) PipeKeys.upstreamConnected(alias),
    for (final alias in aliases) PipeKeys.upstreamState(alias),
    PipeKeys.connected,
    PipeKeys.linkDegraded,
  };

  final dialled = <GateBPanel>[];
  for (var i = 0; i < panels; i++) {
    final proxy = proxyPerPanel ? proxies[i] : null;
    final token = tokenFor?.call(i);
    late final GateBPanel one;
    final client = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${proxy?.port ?? port}'),
      config: token == null
          ? ClientConfig()
          : ClientConfig(token: token, allowTokenOverPlaintext: true),
      keys: keys,
      onStatus: (params) => one.statuses.add(params),
    );
    one = GateBPanel._(i, client, proxy, token);
    dialled.add(one);
    // Each panel registers its own teardown in the loop that builds it, so
    // the whole panel group stays last-registered — one closure over the
    // list would be one registration, and one registration cannot be
    // reordered against the gateway's if a later reader adds something
    // between them (`gate_fixture.dart:32-36`).
    addTearDown(client.dispose);
  }

  final fixture = built = GateBFixture._(links, plant, server, port, proxies,
      dialled, keys, gatewayComplaints, driver, status, mappings, config);

  if (waitForReady) {
    await until(
      'all $panels panels to establish and hold a value for every one of '
      '${keys.length} keys',
      () => dialled.every((one) =>
          one.client.isReady &&
          keys.every((key) => one.client.read(key) != null)),
      budget: readyBudget,
    );
  }
  return fixture;
}
