/// A real gateway, a real socket, optionally a fault proxy and optionally a
/// lens on the frames — one call, torn down in the right order.
///
/// The wiring is `remote_state_man_test.dart:85-128`'s, lifted into `support/`
/// because three fault legs now need it and a fourth copy of it would be a
/// fourth place for the teardown order to be got wrong. Its argument is
/// unchanged and worth repeating: the server package's own `relayFixture` is
/// not reachable from here, because another package's `test/` directory is not
/// addressable by any `package:` URI, so the wiring is copied rather than
/// imported.
///
/// **What this is not.** `client_harness.dart`'s `relayFixture` is the
/// *contract-leg* fixture: it builds the whole 314-key page, wears the
/// contract's control surfaces, and is handed to `runStateManContract`. This
/// one is for a case that drives the client by hand — it takes the keys the
/// case names, hands back the plant and the proxy directly, and adds the one
/// thing the contract fixture has no business owning: a [FrameSeam] on the
/// dial.
///
/// **Teardown order, and why it is not `addTearDown` in declaration order.**
/// `addTearDown` runs last-registered-first, so the registrations below read
/// backwards from the order they execute in: plant, then proxy, then server,
/// then client — executing as client, server, proxy, plant. That is
/// `ws_harness.dart:359-384`'s order read from the inside out. The client goes
/// first because it owns the socket and both its timers and because it is the
/// only participant that *reconnects*: a server closed under a live client
/// leaves the client dialling a dead port for the rest of the run, and the
/// reconnect attempts land as noise on whichever case is unlucky enough to be
/// running then.
///
/// **TLS is opt-in, and what it changes is the dial rather than the proxy.**
/// Pass [FaultTls] to [faultFixture] and the gateway binds `wss` from the
/// mounted chain, the panel dials `wss://127.0.0.1:<proxy port>` pinning the
/// mounted root, and the proxy is left exactly as it was. It does not have to
/// change: `FaultProxy` is a loopback *byte* relay (`fault_proxy.dart:141-190`)
/// that forwards through a `DelayLine` and never inspects a frame, so it shapes
/// ciphertext with no idea that is what it is doing. The default is off, so
/// every existing fault case is byte-identical — the rule amendment 6 imposed
/// on the server's fixtures, kept here.
///
/// **Which modes still mean what they meant, stated as a property rather than
/// as a list to maintain.** The proxy moves bytes, so anything that *shapes* or
/// *withholds* bytes — `latency`, `throttle`, `flap`, `blackhole`, `killOnce`,
/// `reject`, `bufferServerToClient` — is unchanged under TLS: the peer's
/// observable is the same because the bytes it is waiting for are late,
/// missing, or gone either way. Anything that counts bytes and means them as
/// *application* bytes is not. There is exactly one of those: `cutMidFrame(n)`
/// counts wire bytes (`delay_line.dart:297,476,554`), and under TLS a cut after
/// n bytes lands inside a TLS record, so the record is discarded whole and the
/// WebSocket layer never sees half an application frame. `cutMidFrame`'s intent
/// — deliver half a JSON frame to the decoder — is **unreachable through a TLS
/// proxy**, and `tls_fault_test.dart`'s last group measures that rather than
/// pretending otherwise. Do not "fix" it, and do not grow this proxy a
/// byte-corruption lever to compensate: `ws_fault_test.dart:32-34` says why not.
/// The instrument that still reaches the decoder is [FrameSeam], one layer up.
///
/// **A TLS leg has no [FrameSeam], and that is the price of testing the real
/// dial.** The seam is installed by passing `dial:` to `RemoteStateMan`, and a
/// fixture that passes `dial:` bypasses the panel's own pinned `HttpClient`
/// (06-05) — which is the thing a TLS leg exists to exercise. So the TLS mode
/// omits `dial:`, [seam] throws rather than handing back a lens that is not in
/// the path, and `corrupt:` is refused at construction rather than ignored.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
// `RelayErrorHandler` is not on the server package's public surface — the
// barrel exports the configuration types and not the reporter — so it is
// reached through `src/`, the way `error_reporter_test.dart:21` reaches it.
import 'package:tfc_relay_server/src/error_reporter.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart'
    show budgetScale, useRunnerBudgets;

import 'frame_seam.dart';
import 'permissive_resolver.dart';

/// The client's timing knobs for a fault leg, with the deadline floor lowered
/// deliberately.
///
/// Lowering it is explicit and greppable for the reason `client_config.dart`
/// gives — nobody lowers it in production by accident. Here it buys deadlines
/// short enough that a link which stops answering fails a case inside that
/// case's own budget instead of stalling it, which is the whole mechanism the
/// truncated-write flip depends on.
///
/// [tls] and [connectTimeout] are the TLS leg's two additions. Both default to
/// exactly what `ClientConfig` itself defaults to, so a plaintext caller gets
/// the config it always got.
ClientConfig faultClientConfig({
  Duration? write,
  Duration? control,
  Duration? freshness,
  ClientTlsConfig? tls,
  Duration? connectTimeout,
}) =>
    ClientConfig(
      controlDeadline: control ?? const Duration(milliseconds: 600),
      writeDeadline: write ?? const Duration(milliseconds: 600),
      freshnessDeadline: freshness ?? const Duration(seconds: 3),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
      connectTimeout: connectTimeout ?? const Duration(seconds: 10),
      tls: tls,
    );

/// The certificate material a TLS fault leg binds and pins.
///
/// Paths, never bytes, and never a `SecurityContext`: that is the shape
/// `TlsConfig` and `ClientTlsConfig` both take, so a fixture built out of paths
/// proves the same thing SEC-01's "no key material outside mounted files" sweep
/// does rather than resembling it (06-01, `writeCertFixture`).
///
/// [chainPath] and [keyPath] are the gateway's; [rootPath] is the panel's, and
/// on a rejection arm it is deliberately *not* the root that signed the chain.
typedef FaultTls = ({String chainPath, String keyPath, String rootPath});

/// Everything one fault case drives, and the two things it reaches past the
/// client to pull.
final class FaultFixture {
  FaultFixture._(this.served, this.server, this._proxy, this._seam, this.client);

  /// The plant behind the gateway. Levers go straight here, never over the
  /// wire: `rpc_names.dart` keeps them off any method table a connected client
  /// can reach, and putting them on it would be an access-control change
  /// wearing a testing convenience (T-04-30).
  final FakeStateMan served;

  /// The gateway under test's peer. A real one — nothing here is scripted.
  final RelayServer server;

  final FaultProxy? _proxy;

  final FrameSeam? _seam;

  /// The implementation under test.
  final RemoteStateMan client;

  /// The lens on the inbound frames, and the injector F18 needs.
  ///
  /// Throws on a TLS leg rather than answering a lens nobody installed. See the
  /// library doc: a TLS fixture must not pass `dial:`, because that is the seam
  /// the panel's own pinned `HttpClient` arrives through, so there is no
  /// [FrameSeam] in the path at all. Silently handing back an empty one would
  /// turn every `inject` and every `dials` reading into a vacuous pass.
  FrameSeam get seam {
    final seam = _seam;
    if (seam == null) {
      throw StateError('this fixture is a TLS leg and has no frame seam: a '
          'TLS panel dials through its own pinned client, which is exactly '
          'what a `dial:` override would bypass. Corrupt or inject on a '
          'plaintext leg, or reach for the proxy instead');
    }
    return seam;
  }

  /// The proxy in front of the gateway, when one was asked for.
  ///
  /// Throws rather than answering null, the way `ws_harness.dart:284-291` does:
  /// a case that forgot `withProxy: true` should be told that, not shown a
  /// null-check failure on a line that looks like a lever.
  FaultProxy get proxy {
    final proxy = _proxy;
    if (proxy == null) {
      throw StateError('this fixture was built without a proxy; pass '
          '`withProxy: true` to faultFixture before pulling a lever');
    }
    return proxy;
  }
}

/// Stands up plant, gateway, optional proxy and client, and wires the teardown.
///
/// [seed] runs against the plant **before** the gateway starts, which is not a
/// convenience: the gateway classifies every key on a subscribe against
/// `api.keys` (`session_handlers.dart:154-164`) and `FakeStateMan.keys` does
/// not name a tag until a value has been set on it, so a key seeded after the
/// client subscribed is rejected as a typo and is invisible for the rest of the
/// case no matter what the plant does with it. That is the trap
/// `client_harness.dart`'s `_PlantAddressSpace` documents from the other side.
///
/// [tls] switches the whole leg to wss — see the library doc for what that
/// changes and, more importantly, for what it does not.
///
/// [armBeforeDial] is pulled after the proxy binds and **before** the client is
/// constructed, which is the one thing a case cannot do for itself: the client
/// dials from its own constructor, so a lever pulled on the line after
/// `faultFixture` returns is racing the first attempt. Two faults need to be in
/// place before anybody dials rather than after — a blackholed handshake and a
/// cut that lands inside one — and for those the race is the whole measurement.
///
/// [onError] replaces the gateway's discarding error handler, and exists for
/// exactly one clause of one row. F2 asserts that a storm is not *also* a log
/// flood — "no unbounded memory/log growth" — and the only way to count what
/// the gateway complained about over twenty flap cycles is to be handed the
/// complaints instead of dropping them. A case that passes this counts; every
/// case that does not is byte-identical to what it was.
///
/// The default stays discarding, with its reason intact: every case in this
/// directory provokes an error on purpose, and a suite that printed a stack per
/// provoked error would train everyone to scroll past them. Passing
/// `reportToStderr` here is therefore a deliberate act with a visible cost, not
/// a default anybody inherits.
Future<FaultFixture> faultFixture({
  Set<String> keys = const <String>{},
  ClientConfig? config,
  MessageCorruption? corrupt,
  bool withProxy = false,
  void Function(FakeStateMan plant)? seed,
  FaultTls? tls,
  void Function(FaultProxy proxy)? armBeforeDial,
  Duration? connectTimeout,
  RelayErrorHandler? onError,
}) async {
  // See `until` below: the runner scale arms itself rather than waiting for
  // a per-file call.
  useRunnerBudgets();
  if (tls != null && corrupt != null) {
    throw ArgumentError('a TLS leg has no frame seam, so `corrupt:` would be '
        'silently ignored: the panel dials through its own pinned client and '
        'nothing this fixture owns sits between the socket and the peer. '
        'Corrupt on a plaintext leg (that is where the decoder is tested), or '
        'shape bytes with the proxy');
  }
  if (config != null && connectTimeout != null) {
    throw ArgumentError('pass `connectTimeout:` or a whole `config:`, not '
        'both: this fixture would have to rebuild the config to honour the '
        'first, and silently dropping it is how a dial ends up unbounded');
  }
  if (armBeforeDial != null && !withProxy) {
    throw ArgumentError('`armBeforeDial` pulls a lever on the proxy, and this '
        'fixture was built without one; pass `withProxy: true`');
  }
  final clientConfig = config ??
      faultClientConfig(
        tls: tls == null ? null : ClientTlsConfig(rootCertPath: tls.rootPath),
        connectTimeout: connectTimeout,
      );
  if (tls != null && clientConfig.tls == null) {
    throw ArgumentError('this fixture was given a TLS mount and a `config:` '
        'carrying no ClientTlsConfig, so the panel would dial wss with the '
        'machine\'s own trust store and be refused by its own gateway. Build '
        'the config with faultClientConfig(tls: ...)');
  }

  final served = FakeStateMan();
  addTearDown(served.dispose);
  seed?.call(served);

  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: ServerConfig(
      tick: ServerConfig.minTick,
      // Null on a plaintext leg, which is the default every other case in this
      // package depends on (06-03 sabotage arm 2 measured it at 53 cases).
      tls: tls == null
          ? null
          : TlsConfig(chainPath: tls.chainPath, keyPath: tls.keyPath),
    ),
    // Discards rather than `reportToStderr`: every case here provokes an error
    // on purpose, and a suite that printed a stack per provoked error would
    // train everyone to scroll past them (`ws_harness.dart:231-235`). A case
    // that wants to *count* them passes its own handler; nothing else changes.
    onError: onError ?? (_, __, ___) {},
  );
  await server.start();
  addTearDown(server.close);

  FaultProxy? proxy;
  if (withProxy) {
    proxy = FaultProxy(targetPort: server.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
  }
  if (proxy != null) armBeforeDial?.call(proxy);

  // No seam on a TLS leg, and no `dial:` either: the panel's own dial is what
  // carries the pinned client, and an override would test this file instead.
  // `connectTimeout` is handed to the seam because the seam *is* the dial on a
  // plaintext leg: passing `dial:` replaces the path that would otherwise apply
  // `config.connectTimeout`, so a seam built without it silently un-bounds a
  // dial that production bounds. See `frame_seam.dart`'s field doc — F14b is
  // the row that could not be written until this line existed.
  final seam = tls == null
      ? FrameSeam(corrupt: corrupt, connectTimeout: clientConfig.connectTimeout)
      : null;
  final port = proxy?.port ?? server.port;
  final url = tls == null ? 'ws://127.0.0.1:$port' : 'wss://127.0.0.1:$port';
  final client = RemoteStateMan(
    uri: Uri.parse(url),
    config: clientConfig,
    keys: keys,
    dial: seam?.dial,
  );
  addTearDown(client.dispose);

  return FaultFixture._(served, server, proxy, seam, client);
}

/// Polls [done] until it holds or [budget] runs out, and fails naming [what].
///
/// A poll rather than a stream wait because these cases assert a *state* the
/// client reached, and the transition that got it there is the supervisor's
/// business, tested in `reconnect_test.dart`. Copied from
/// `remote_state_man_test.dart:135-144` with its reason, because a second
/// almost-identical waiter is how two files start disagreeing about what
/// "recovered" means.
/// [budget] is multiplied by `budgetScale`, for the reason `check.dart` gives
/// about `within`: this is a liveness bound and not a latency measurement, and
/// five seconds against a three-second freshness deadline is only 1.7x of
/// margin — enough on the machine it was written on, not enough on a loaded
/// Windows agent, where it failed for the runner's load and reported it as the
/// panel not noticing its own staleness.
Future<void> until(
  String what,
  bool Function() done, {
  Duration budget = const Duration(seconds: 5),
}) async {
  // **Self-arming, rather than relying on each file to call it.** The scale is
  // a property of the machine, not of the case, and wiring
  // `useRunnerBudgets()` into every `main()` means every new fault file is one
  // forgotten line away from running the unscaled numbers on a hosted agent.
  // That is not hypothetical: `half_open_gate_test` timed out at a bare 5000 ms
  // — no "x 4.0 for this runner" in the message — because it was never wired,
  // while its neighbours were. Idempotent, so calling it per wait costs
  // nothing.
  useRunnerBudgets();
  final allowed = budget * budgetScale;
  final deadline = DateTime.now().add(allowed);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${allowed.inMilliseconds} ms waiting for: $what'
          '${budgetScale == 1 ? '' : ' (${budget.inMilliseconds} ms x '
              '$budgetScale for this runner)'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
