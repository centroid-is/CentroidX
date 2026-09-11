@TestOn('vm')
@Tags(['ws'])

/// SEC-04: how many days are left on the gateway's certificate, as an ordinary
/// subscribable key.
///
/// **Health is a key, not a method**, and that is a recorded ruling in three
/// places (`state_man_api.dart:45-49`, `tfc_stateman_contract.dart:52-57`,
/// `api_surface_test.dart:48-51`): "There is no health method. `PIPE.*` keys
/// are subscribable like any plant tag … `listen('PIPE.connected')` is the
/// health API." So the thing under test here is a *producer*, not an endpoint,
/// and every case asks the gateway the way a mimic would.
///
/// ## What breaks in the plant without this file
///
/// The gateway's leaf is a one-year certificate (06-CONTEXT decision 3). On
/// the morning it lapses, every panel in the plant stops connecting at once —
/// `tls_test.dart`'s expired arm is what that looks like from the panel's
/// side, and it is deliberately loud. Loud on the day of the expiry is a
/// Saturday outage; loud thirty days earlier is a Tuesday ticket. This file is
/// what makes the second one possible. The threshold is AlarmMan's rather than
/// ours: the gateway ships the number.
///
/// ## Three answers, and two of them are not numbers
///
///  * A **good** certificate reads whole days, `notAfter - now`, truncated.
///  * An **expired** one reads a negative number, which is meaningful.
///  * An **unreadable** one reads [Quality.errorConfig] and **never 0** — a 0
///    reads as "expires today" and would send somebody to re-issue a
///    certificate that is fine, because a path was misspelled.
///
/// Certificates are minted at test time through `test/support/certs.dart` and
/// never committed: a committed leaf rots on a schedule nobody watches, and
/// the near-expiry one this file needs is a `notAfter:` argument against the
/// cached keypair (~15 ms), not a second keygen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/health/cert_health_state_man.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/tls/tls_config.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;
import 'package:web_socket_channel/io.dart';

import 'support/certs.dart';
import 'support/permissive_resolver.dart';

/// The ceiling on any dial (trap 17: an unreachable address takes 75 s to fail
/// on macOS, and one such case on its own blows the three-minute lane budget
/// `handler_table_test.dart` owns).
const _dialBudget = Duration(seconds: 10);

/// A plant tag, so "the certificate key" can be told apart from "every key".
const _speedKey = 'ST101.CN01.MOT01.speed';

void main() {
  late TestCa ca;

  setUp(() {
    // Deliberately not a `setUpAll` in `support/certs.dart` (06-01 note 1):
    // `certKeyPairs()` is a lazy top-level cache, so the RSA is paid once for
    // the process and every `mintCa` after it is ~18 ms.
    ca = mintCa();
  });

  /// A gateway serving [plant], torn down whatever happens to it.
  ///
  /// `close()` is registered at acquisition rather than after a successful
  /// `start()` — 06-03's discipline, and what lets a case fail an assertion
  /// without leaking a listener or a socket.
  RelayServer buildServer({
    required FakeStateMan plant,
    TlsConfig? tls,
    int Function()? now,
  }) {
    final server = RelayServer(
      resolver: const PermissiveSeriesResolver(),
      api: plant,
      config: ServerConfig(tick: ServerConfig.minTick, tls: tls),
      now: now,
      // Several cases here provoke refusals on purpose, and a suite that
      // printed a stack trace per provoked refusal trains everyone to scroll
      // past them (`ws_harness.dart:231-235`).
      onError: (_, __, ___) {},
    );
    addTearDown(() async {
      await server.close();
      await plant.dispose();
    });
    return server;
  }

  /// A gateway holding a leaf that expires [days] from now.
  ///
  /// Negative [days] mints an already-lapsed leaf; `notBefore` is moved back
  /// with it, because a `notBefore` later than `notAfter` is not a
  /// certificate.
  ({RelayServer server, FakeStateMan plant, CertFixture mounted}) gatewayFor(
      {int days = 365, int Function()? now}) {
    final plant = FakeStateMan();
    final at = DateTime.now().toUtc();
    final mounted = writeCertFixture(
      chainPem: mintLeaf(
        ca: ca,
        notBefore: at.subtract(const Duration(days: 400)),
        notAfter: at.add(Duration(days: days)),
      ),
      keyPem: leafKeyPem(),
      rootPem: ca.certPem,
    );
    final server = buildServer(
      plant: plant,
      tls: TlsConfig(chainPath: mounted.chainPath, keyPath: mounted.keyPath),
      now: now,
    );
    return (server: server, plant: plant, mounted: mounted);
  }

  /// A client pinning [rootPem] and nothing else — the panel's posture.
  HttpClient pinnedClient(String rootPem) {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(rootPem.codeUnits);
    final client = HttpClient(context: context);
    addTearDown(() => client.close(force: true));
    return client;
  }

  /// A connected station on [server], past the handshake.
  ///
  /// [root] pins the gateway's CA and selects `wss`; omitted, the dial is
  /// plaintext `ws`, which is what the plaintext arm wants.
  Future<_Station> station(RelayServer server, {String? root}) async {
    final opened = server.sessions.opened.first;
    final ws = IOWebSocketChannel.connect(
      Uri.parse('${root == null ? 'ws' : 'wss'}://localhost:${server.port}'),
      customClient: root == null ? null : pinnedClient(root),
      connectTimeout: _dialBudget,
    );
    await ws.ready.timeout(_dialBudget);
    final base = wsChannel(ws);
    // One broadcast view, shared: the RPC client consumes it for answers and
    // `_Station.pushFor` taps the same frames for the `u` notifications.
    // `rpc.Client` does not dispatch server-sent notifications at all — only
    // `rpc.Peer` does — so a case that wants to see a push has to read the
    // wire, which is also the honest thing to be asserting about a push.
    final frames = base.stream.asBroadcastStream();
    final peer = rpc.Client(StreamChannel<String>(frames, base.sink));
    final connected = _Station._(peer, frames);
    unawaited(peer.listen().catchError((Object _) => null));
    addTearDown(() async {
      await peer.close().catchError((Object _) {});
      await ws.sink.close().catchError((Object _) {});
    });
    // Awaited before the hello so a case reading `sessions` cannot race the
    // accept — `ws_harness.dart:315` makes the same argument.
    await opened.timeout(const Duration(seconds: 5));
    await connected.hello();
    return connected;
  }

  group('the gateway\'s own certificate is a key', () {
    test('a TLS gateway serves its certificate\'s days to expiry as a key',
        () async {
      final gateway = gatewayFor();
      gateway.plant.setValue(_speedKey, 1450);
      await gateway.server.start();
      final panel = await station(gateway.server, root: ca.certPem);

      // The chain, read off the live session rather than rebuilt beside it:
      // **policy over health over source**. The policy decorator is per
      // session because identity is; the certificate belongs to the *server*,
      // so its overlay sits underneath and is shared — which is also what
      // lets Phase 8 delete this overlay without touching the policy.
      final session = gateway.server.sessions.sessions.single;
      expect(session.api.source, isA<CertHealthStateMan>(),
          reason: 'the health overlay has to sit under the per-session policy '
              'decorator. Chained the other way, `canSee` would filter a key '
              'list that does not yet contain the health key, and a future '
              'hiding policy could never reach it');
      expect((session.api.source as CertHealthStateMan).source,
          same(gateway.plant),
          reason: 'one overlay over the one shared source — a second source '
              'here would be a second place plant state lives');

      expect(session.api.keys, contains(certDaysToExpiryKey),
          reason: 'AlarmMan alarms on keys. A number the gateway knows and '
              'does not publish is a number nobody can alarm on, and the '
              'yearly re-issue goes back to being a Saturday outage');
      expect(session.api.keys, contains(_speedKey),
          reason: 'the key list is a union, not a replacement: a gateway that '
              'served its own health key *instead of* the plant would be a '
              'blank screen with a healthy badge on it');

      final answer = _asMap(
          await panel.request(Methods.read, {'key': certDaysToExpiryKey}));
      final wire = WireValue.fromJson(_asMap(answer['value']));
      expect(wire.q, Quality.good);
      expect(wire.v, isA<int>(),
          reason: 'whole days, so an alarm threshold is an integer comparison '
              'and not a duration somebody has to parse on the way in');
    });

    test('a plaintext gateway carries no certificate key', () async {
      // The property that keeps this plan safe against every existing suite:
      // ten bind/dial fixture sites construct a config with no TLS, and not
      // one of them may grow a sixth health key.
      final plant = FakeStateMan();
      plant.setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server);

      final session = server.sessions.sessions.single;
      // **Amended by 08-12, and this is the one line of this file that
      // moved.** Through Phase 6 the assertion here was `same(plant)`: the
      // overlay in the chain slot existed only to report on a certificate, so
      // a gateway with none installed nothing at all. Phase 8 put a
      // *per-session* overlay in that slot, and its other six keys —
      // `link_degraded`, `effective_hz`, `egress_kbps`, `pending_keys`,
      // `dropped_hold_ticks`, `event_loop_lag_ms` — are facts about a socket,
      // which a plaintext socket also is. So the overlay is present here and
      // the property that survived is the one that mattered: **one** overlay,
      // over the **one** shared source, contributing no certificate key.
      expect((session.api.source as CertHealthStateMan).source, same(plant),
          reason: 'one overlay over the one shared source — a second source '
              'here would be a second place plant state lives');
      expect(session.api.keys, isNot(contains(certDaysToExpiryKey)),
          reason: 'a health key reading errorConfig forever on a gateway that '
              'was never given a certificate is a permanent false alarm, '
              'which is how an operator learns to ignore the indicator');
      expect(server.certHealth, isNull,
          reason: '`tls == null` is the whole condition: no overlay, no '
              'store, no file read, nothing to release');

      // And it is absent over the wire too, answered as a tag this gateway
      // does not serve rather than as an empty reading.
      final answer = _asMap(
          await panel.request(Methods.read, {'key': certDaysToExpiryKey}));
      expect(answer['rejected'], isNotNull,
          reason: 'absent means absent: a key present in the list but empty '
              'is a badge that renders and says nothing');
    });

    test('the certificate value is there before anything subscribes',
        () async {
      // The same argument `fake_state_man.dart:93-107` makes for the other
      // five health keys: seeded at construction "so a client can read them
      // before anything has happened — a health indicator that reads unknown
      // until the first fault is no indicator at all".
      final gateway = gatewayFor();
      await gateway.server.start();

      expect(gateway.server.sessions.sessionCount, 0,
          reason: 'the whole point of this case is that nothing has connected '
              'yet');
      final overlay = gateway.server.certHealth;
      expect(overlay, isNotNull);
      final value = overlay!.read(certDaysToExpiryKey);
      expect(value, isNotNull,
          reason: 'the first panel to subscribe must find a number in its '
              'snapshot, not a hole that fills in an hour');
      expect(value!.quality, Quality.good);
    });
  });

  group('the three answers', () {
    test('a seventeen-day certificate reads under thirty days and still '
        'connects', () async {
      final gateway = gatewayFor(days: 17);
      await gateway.server.start();

      // The point of the criterion, and the reason it is one case rather than
      // two: near-expiry is a *health* signal, not a connectivity failure. An
      // operator has to be able to see the warning while the plant is still
      // running — a warning that arrives at the same moment as the outage
      // buys nothing. So the panel completes a pinned handshake and a hello
      // on this very certificate before the number is read.
      final panel = await station(gateway.server, root: ca.certPem);
      final answer = _asMap(
          await panel.request(Methods.read, {'key': certDaysToExpiryKey}));
      final wire = WireValue.fromJson(_asMap(answer['value']));
      expect(wire.q, Quality.good);
      final days = wire.v! as int;

      // The band, not the integer. `inDays` truncates, so a 17-day leaf reads
      // 16; asserting 16 exactly would flake on a suite that crossed a
      // midnight boundary or on a machine a few hundred milliseconds slower.
      expect(days, lessThan(30),
          reason: 'thirty days is the threshold 06-CONTEXT decision 3 fixes. '
              'A near-expiry certificate that read 30 or more would leave the '
              'alarm silent right up to the outage it exists to prevent');
      expect(days, greaterThan(0),
          reason: 'this certificate has not expired. A 0 or a negative here '
              'means the arithmetic ran off the wrong end of the validity '
              'window, and every freshly-issued gateway in the plant would '
              'alarm on the day it was commissioned');
      printOnFailure('a 17-day leaf read back $days days');
    });

    test('an already-expired certificate reads a negative number', () async {
      // Read off the gateway rather than over a socket: an expired leaf
      // cannot complete a handshake at all (`tls_test.dart` pins that, and
      // trap 16 says every TLS rejection looks identical), so there is no
      // panel to ask. The **sign** is the assertion, not the magnitude.
      final gateway = gatewayFor(days: -3);
      await gateway.server.start();

      final value = gateway.server.certHealth!.read(certDaysToExpiryKey)!;
      expect(value.quality, Quality.good,
          reason: 'the file parsed. "Expired" is a reading, not a fault — '
              'clamping it to bad quality would throw away the one number '
              'that says how far past the deadline this gateway is, which is '
              'exactly what somebody staring at a plant full of panels that '
              'will not connect needs to see');
      expect(value.value! as int, lessThan(0),
          reason: 'an expired leaf has to read negative so "renew it this '
              'month" and "this is why nothing is connecting" are '
              'distinguishable at a glance');
      printOnFailure('a 3-day-expired leaf read back ${value.value}');
    });

    test('an unreadable certificate reads bad quality, not zero', () async {
      // **The arrangement, and why it is this one.** `RelayServer.start()`
      // refuses an unloadable chain (06-03 task 1, and deliberately: a
      // gateway that downgraded to plaintext because a path was misspelled is
      // discovered by a packet capture months later). So pointing a
      // `TlsConfig` at garbage exercises the *start* path, not the overlay's.
      // Replacing the file **after** the bind is what reaches the overlay's
      // own parse — and it is a real deployment shape rather than a
      // contrivance: a bind-mounted PEM swapped under a running gateway is
      // precisely what the yearly re-issue does.
      final gateway = gatewayFor();
      await gateway.server.start();
      final overlay = gateway.server.certHealth!;
      expect(overlay.read(certDaysToExpiryKey)!.quality, Quality.good,
          reason: 'the control this case rests on: the file has to have been '
              'readable first, or "unreadable" is established about nothing');

      File(gateway.mounted.chainPath)
          .writeAsStringSync('this is not a certificate\n');
      overlay.refresh();

      final value = overlay.read(certDaysToExpiryKey)!;
      expect(value.quality, Quality.errorConfig,
          reason: 'the gateway looked and cannot say how many days are left. '
              'Saying so is the whole of the honest answer');
      expect(value.value, isNot(0),
          reason: 'a 0 reads as "expires today" and fires the thirty-day '
              'alarm for a typo in a path. Somebody is sent out to re-issue a '
              'certificate that is perfectly fine, and the next real expiry '
              'warning is the one they have learned to dismiss');
      expect(value.value, isNull,
          reason: 'no number is knowable, so no number is published — the '
              'quality carries the entire answer');
    });

    test('a leaf rotated under a running gateway keeps counting the one being '
        'served', () async {
      // The operational sequence this file exists for, run to the end: the
      // leaf is a month from lapsing, the alarm has fired, somebody mounts
      // the new one — and defers the restart, because restarting the gateway
      // takes the plant off its screens. `useCertificateChain` read the PEM
      // once inside `start()`; every panel keeps validating that leaf until
      // the process is replaced.
      final gateway = gatewayFor(days: 29);
      await gateway.server.start();
      final overlay = gateway.server.certHealth!;
      final before = overlay.read(certDaysToExpiryKey)!.value as int;
      expect(before, lessThan(30),
          reason: 'the control: the alarm is up before the rotation');

      final at = DateTime.now().toUtc();
      File(gateway.mounted.chainPath).writeAsStringSync(mintLeaf(
        ca: ca,
        notBefore: at.subtract(const Duration(days: 1)),
        notAfter: at.add(const Duration(days: 365)),
      ));
      overlay.refresh();

      final after = overlay.read(certDaysToExpiryKey)!;
      expect(after.quality, Quality.good);
      expect(after.value, lessThan(30),
          reason: 'a value that jumped to 365 here would clear the alarm and '
              'close the ticket while every panel in the plant is still '
              'validating the old leaf and still counting down to its '
              'original notAfter. The plant would then stop on the original '
              'expiry date with no warning at all — which is the Saturday '
              'outage this file was written to prevent, reached through the '
              'one operational sequence it was built for');
      expect(after.value, before,
          reason: 'nothing about the certificate being served changed, so '
              'nothing about the number should have');
    });

    test('a rotation that shortens the certificate is reported at once',
        () async {
      // The other direction. The served leaf and the mounted one are both
      // read, and the sooner of the two is the honest answer: a leaf mounted
      // with a nearer notAfter is a deadline the gateway will meet the moment
      // it is restarted, and a number that ignored it would be optimistic
      // about the one thing this key exists to be pessimistic about.
      final gateway = gatewayFor(days: 365);
      await gateway.server.start();
      final overlay = gateway.server.certHealth!;
      expect(overlay.read(certDaysToExpiryKey)!.value, greaterThan(300));

      final at = DateTime.now().toUtc();
      File(gateway.mounted.chainPath).writeAsStringSync(mintLeaf(
        ca: ca,
        notBefore: at.subtract(const Duration(days: 1)),
        notAfter: at.add(const Duration(days: 10)),
      ));
      overlay.refresh();

      expect(overlay.read(certDaysToExpiryKey)!.value, lessThan(30));
    });

    test('a missing certificate file reads bad quality too', () async {
      // The other half of "missing or unparseable": a mount that went away.
      // Same answer, because it is the same statement to an operator.
      final gateway = gatewayFor();
      await gateway.server.start();
      final overlay = gateway.server.certHealth!;

      File(gateway.mounted.chainPath).deleteSync();
      overlay.refresh();

      final value = overlay.read(certDaysToExpiryKey)!;
      expect(value.quality, Quality.errorConfig);
      expect(value.value, isNull,
          reason: 'a vanished mount is the same class of answer as an '
              'unparseable one: unknown, and never zero');
    });
  });

  group('the certificate key behaves like any other tag', () {
    test('the certificate key is subscribable, and a recompute pushes',
        () async {
      // "Subscribable like any plant tag" is the whole ruling, so this case
      // takes the path a mimic takes: subscribe, find the value in the
      // snapshot, then make the number move and wait for the push.
      var wall = DateTime.now().millisecondsSinceEpoch;
      final gateway = gatewayFor(days: 17, now: () => wall);
      await gateway.server.start();
      final panel = await station(gateway.server, root: ca.certPem);

      final answer = SubscribeResult.fromJson(
          _asMap(await panel.request(Methods.subscribe, {
        'sub': 'cert-health',
        'keys': [certDaysToExpiryKey],
      })));
      expect(answer.rejected, isEmpty,
          reason: 'the gateway serves this key; a rejection here means it is '
              'in the key list and nowhere else');
      final handle = answer.handles[certDaysToExpiryKey];
      expect(handle, isNotNull,
          reason: 'no handle means no push is even addressable — the badge '
              'would render once and then never change again');
      final first = answer.snapshot[handle]!.v! as int;
      expect(answer.snapshot[handle]!.q, Quality.good,
          reason: 'a health key absent from — or bad in — the snapshot is an '
              'indicator that stays blank until the value happens to change, '
              'which for a days-to-expiry key is once a day');

      // Two days of wall clock, driven through the gateway's injected clock
      // rather than slept: the recompute is what the case is about, and the
      // wait is not.
      final pushed = panel.pushFor(handle!);
      wall += const Duration(days: 2).inMilliseconds;
      gateway.server.certHealth!.refresh();

      expect(
          await within(pushed, 'the certificate key\'s push',
              budget: const Duration(seconds: 5)),
          first - 2,
          reason: 'the number moved and the panel was not told. An expiry '
              'indicator that only re-evaluates when a panel reconnects is an '
              'indicator that updates after the outage');
    });

    test('a heartbeat is a deadline check, which is what a night shift sends',
        () async {
      // The residual the no-timer argument admits to is "a gateway with
      // literally no traffic". It was wider than that: four of the nine
      // registered methods never read `api.keys` — `hello`, `ping`,
      // `unsubscribe` and `writeStatus` — and those four are exactly what an
      // established, otherwise-idle panel produces. Several connected panels
      // holding subscriptions and doing nothing else is not an untrafficked
      // gateway, it is a night shift.
      var wall = DateTime.now().millisecondsSinceEpoch;
      final gateway = gatewayFor(days: 365, now: () => wall);
      await gateway.server.start();
      final panel = await station(gateway.server, root: ca.certPem);
      final overlay = gateway.server.certHealth!;
      final first = overlay.value!.value as int;

      wall += const Duration(days: 2).inMilliseconds;
      await panel.request(Methods.ping, const <String, Object?>{});

      expect(overlay.value!.value, first - 2,
          reason: 'the heartbeat is the one request guaranteed to keep '
              'arriving, so it is the one that has to carry the deadline '
              'check. Without it the number a panel reads is as old as the '
              'last time somebody touched a plant tag');
    });

    test('the certificate key is excluded from its own freshness accounting',
        () async {
      // HLTH-02, asserted directly rather than assumed.
      // `freshness_contract.dart:309`'s
      // `checkHealthKeysExcludedFromOwnFreshness` is the check that would
      // normally own this property, and it does **not** run against this
      // overlay: the overlay is on no contract leg, deliberately, because a
      // sixth entry in `FakeStateMan.healthKeys` would put this key on every
      // leg including the ones with no certificate.
      //
      // A days-to-expiry key is the live trap that check was written for. It
      // changes once a day, so a source that applied a freshness deadline to
      // it would grey out the one indicator that says whether to trust the
      // rest — permanently, and precisely while everything is fine, which is
      // how an operator learns to ignore an indicator.
      final plant = FakeStateMan(staleAfter: const Duration(milliseconds: 80));
      final mounted = writeCertFixture(
        chainPem: mintLeaf(ca: ca),
        keyPem: leafKeyPem(),
      );
      final server = buildServer(
        plant: plant,
        tls: TlsConfig(chainPath: mounted.chainPath, keyPath: mounted.keyPath),
      );
      await server.start();
      final overlay = server.certHealth!;

      // The barrier, borrowed from the contract check itself: when a *plant*
      // key has gone stale the deadline has demonstrably passed, and the
      // certificate key has been sitting untouched at least as long. No
      // sleep, and no guess about how long the sweep takes.
      plant.setValue(_speedKey, 1450);
      final speed = overlay.listen(_speedKey);
      final stale = Completer<void>();
      void watch() {
        if (speed.value.quality == Quality.badStale && !stale.isCompleted) {
          stale.complete();
        }
      }

      speed.addListener(watch);
      addTearDown(() => speed.removeListener(watch));
      await within(
          stale.future,
          'a plant key going stale, which is this case\'s proof that the '
          'deadline has passed',
          budget: const Duration(seconds: 5));

      expect(overlay.read(certDaysToExpiryKey)!.quality, Quality.good,
          reason: 'the gateway accused its own certificate indicator of being '
              'stale. It changes once a day by construction, so a freshness '
              'deadline applied to it greys it out on a perfectly healthy '
              'gateway — and an indicator that is grey when nothing is wrong '
              'is one nobody reads when something is');
    });

    test('a write to the certificate key is refused the way a read-only tag '
        'is', () async {
      // It is a reading of the world, not a setpoint. The refusal reuses the
      // device's own not-writable shape rather than inventing a code, so
      // nothing on the panel side needs a special case for a health key.
      final gateway = gatewayFor();
      await gateway.server.start();
      final overlay = gateway.server.certHealth!;
      final before = overlay.read(certDaysToExpiryKey)!.value;

      final result =
          await overlay.write(certDaysToExpiryKey, 400, cmd: 'cmd-01');
      expect(result, isA<WriteRejected>());
      expect(result.cmd, 'cmd-01',
          reason: 'the caller\'s id comes back on the refusal, or writeStatus '
              'could never match it after a reconnect');
      expect((result as WriteRejected).reason.kind, 'not_writable',
          reason: 'the same kind a read-only device gives '
              '(`fake_state_man.dart:835-842`), so a panel renders it with a '
              'sentence it already has');
      expect(overlay.read(certDaysToExpiryKey)!.value, before,
          reason: 'a refused write that still moved the value would let '
              'somebody silence the expiry alarm by typing a number into it');
    });
  });

  group('the contract kit did not grow a key', () {
    test('the reference implementation still declares five health keys', () {
      // Deliberately *not* a sixth entry in `FakeStateMan.healthKeys`:
      // `freshness_contract.dart:60-64` reads the reserved prefix from there
      // and three drivers run the resulting checks, including legs that have
      // no certificate at all. The gateway is this key's producer; the
      // contract kit does not move.
      expect(FakeStateMan.healthKeys, hasLength(5),
          reason: 'a sixth entry would put $certDaysToExpiryKey on every '
              'contract leg in the repository, including the in-memory ones '
              'where there is no certificate to report on');
      expect(FakeStateMan.healthKeys, isNot(contains(certDaysToExpiryKey)));
    });

    test('the key is spelled the way every deployment spells it', () {
      // The one place the literal appears in this file, deliberately: every
      // other case names the constant, so a rename would compile and every
      // case would keep passing while every AlarmMan configuration in the
      // plant quietly stopped matching anything. The key name is a
      // deployment contract — it is in alarm configs, it will be on Phase 8's
      // HLTH-03 reserved list — and it is not ours to change silently.
      expect(certDaysToExpiryKey, 'PIPE.cert.days_to_expiry',
          reason: 'renaming this key does not break a build anywhere; it '
              'breaks the alarm, in the field, and the first symptom is a '
              'certificate expiring with nobody warned');
    });

    test('the key lives in the reserved PIPE namespace', () {
      // Phase 8's HLTH-03 will reject a plant keymapping claiming a name
      // inside `PIPE.` (`freshness_contract.dart:60-64`), so this key has to
      // be on that reserved list from the start — and the name is what puts
      // it there.
      expect(certDaysToExpiryKey, startsWith(FakeStateMan.healthPrefix),
          reason: 'a health key outside the reserved namespace is a name a '
              'plant keymapping may legally claim, and the collision would '
              'surface as an alarm reading a conveyor speed in days');
    });
  });
}

/// One connected client, past the handshake.
final class _Station {
  _Station._(this._peer, this._frames);

  final rpc.Client _peer;
  final Stream<String> _frames;

  /// The next value pushed for [handle] over a `u` notification.
  ///
  /// Taken **before** whatever is going to cause the push, so the wait cannot
  /// lose a race with a tick — the same discipline every socket case in this
  /// package uses for `sessions.opened`.
  Future<Object?> pushFor(int handle) {
    final next = Completer<Object?>();
    final subscription = _frames.listen((frame) {
      if (next.isCompleted) return;
      final decoded = _asMap(jsonDecode(frame));
      if (decoded['method'] != Methods.update) return;
      final update = UpdateParams.fromJson(_asMap(decoded['params']));
      final changed = update.changes[handle];
      if (changed != null) next.complete(changed.v);
    });
    unawaited(next.future.whenComplete(subscription.cancel));
    return next.future;
  }

  Future<void> hello() => request(
      Methods.hello,
      HelloParams(
        protocol: protocolVersion,
        supported: const [protocolVersion],
        client: const PeerInfo('panel-under-test', '0.1.0'),
      ).toJson());

  Future<Object?> request(String method, Object? params,
          {Duration budget = const Duration(seconds: 5)}) =>
      within(_peer.sendRequest(method, params),
          'a $method response over a real socket',
          budget: budget);
}

/// One decoded JSON object, cast where the wire hands back `Object?`.
Map<String, Object?> _asMap(Object? raw) =>
    (raw! as Map).cast<String, Object?>();
