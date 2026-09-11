/// **The phase's demonstration.** One process, a real PLC, a real socket, a
/// real panel.
///
/// Every other file in this package proves one layer against a stub of its
/// neighbour. This one proves the layers agree: an in-process open62541 server
/// publishes a value, `OpcUaUpstreamLink` samples it, `LocalStateMan` stores it,
/// `RelayServer` fans it out, a WebSocket carries it, and `RemoteStateMan`
/// renders it — with the quality and the source instant the PLC gave it still
/// attached at the far end.
///
/// **A verifier should be able to check Phase 8 off by reading this file.**
/// Each case's doc comment names the ROADMAP criterion it proves, in the
/// criterion's own words, and every arm prints the numbers it measured so the
/// SUMMARY can quote them rather than restate them.
///
/// **Six legs and no more.** This is expensive machinery — a native OPC UA
/// build, a listening port, a socket and two event loops per case — and the
/// value of an end-to-end test is that it proves the layers agree, not that it
/// re-proves each layer. Anything that can be asserted one layer down belongs
/// one layer down, where it costs milliseconds.
///
/// `@TestOn('!windows')` for `opcua_link_test.dart:1`'s reason: the CI matrix
/// includes `windows-latest` and an in-process open62541 `Server` is not run
/// there.
@TestOn('!windows')
@Tags(['opcua', 'contract'])
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/state_man.dart' show KeyMappings, KeyMappingEntry;
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:test/test.dart';

import 'opcua_link_test.dart' show alias, mappingFor, speedKey;
import 'support/opcua_server_fixture.dart';
import 'support/permissive_resolver.dart';

/// Four more plant keys behind the one link.
///
/// The announce-once arm needs the key count to be **larger than the
/// announcement count** or it cannot tell "one event" from "one per key": with
/// one key on the link, one announcement is both answers at once.
const List<String> extraKeys = <String>[
  'ST101.CN01.MOT01.setpoint',
  'ST101.CN02.MOT01.speed',
  'ST101.CN03.MOT01.speed',
  'ST101.CN04.MOT01.speed',
];

/// Every plant key this file puts behind the link.
List<String> get plantKeys => <String>[speedKey, ...extraKeys];

/// Waits for [predicate], polling, and returns how long it took.
///
/// **Every state read in this file is inside one of these.** A window and never
/// an instant: there are four asynchronous boundaries between a PLC and a panel
/// here (the OPC UA publishing interval, the gateway's ingest, the server's
/// tick, the socket) and an instant read after any of them is a race that
/// passes on a fast machine and fails in CI.
Future<Duration> until(
  bool Function() predicate, {
  Duration within = const Duration(seconds: 45),
  String? describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > within) {
      fail('${describe ?? 'condition'} never became true within '
          '${within.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  stopwatch.stop();
  return stopwatch.elapsed;
}

/// One gateway process and the panels dialled into it.
final class E2E {
  E2E._(this.fixture, this.gateway, this.panels, this.statuses);

  /// The PLC.
  final OpcUaServerFixture fixture;

  /// The process: `LocalStateMan` under `RelayServer`, composed by the same
  /// `buildGateway` the `bin/` entry point calls. Nothing in this file builds
  /// the composition by hand — a test that wired its own would be asserting
  /// against an arrangement no deployment has.
  final Gateway gateway;

  /// The panels, in the order they were asked for.
  final List<RemoteStateMan> panels;

  /// Every status notification each panel received, in order.
  ///
  /// Read off `RemoteStateMan`'s `onStatus`, which is fed by
  /// `StatusParams.fromJson` — so an entry here is proof the DTO crossed the
  /// wire *whole* and parsed at a conforming client, which is the half of
  /// SRV-08 that 03-REVIEW WR-06 records as having been got wrong once.
  final List<List<StatusParams>> statuses;

  RemoteStateMan get panel => panels.first;

  /// The fault seam in front of the PLC, when the fixture was built with one.
  dynamic get proxy => fixture.proxy!;
}

/// Stands the whole chain up and waits until a plant value has crossed it.
///
/// The single setup for all six legs, because the thing under test is the
/// composition: a leg that stood up a different arrangement would be proving
/// something about that arrangement.
Future<E2E> standUp({
  int panels = 1,
  bool viaFaultProxy = false,
  Duration staleAfter = const Duration(seconds: 10),
  Map<String, KeyMappingEntry> extraMappings = const <String, KeyMappingEntry>{},
  Set<String> extraPanelKeys = const <String>{},
  void Function(RemoteStateMan panel)? watch,
}) async {
  final fixture = await OpcUaServerFixture.start(
      valueKeys: plantKeys, viaFaultProxy: viaFaultProxy);
  addTearDown(fixture.dispose);

  final mappings = KeyMappings(nodes: <String, KeyMappingEntry>{
    for (final key in plantKeys) key: mappingFor(key),
    ...extraMappings,
  });

  final config = GatewayConfig(
    // Port zero: the fixture's own rule, applied to the front end. A literal
    // port here would collide with the neighbour worktree the moment two of
    // these run at once, and the failure reads as a bug in the code under test.
    server: ServerConfig(port: 0, tick: ServerConfig.minTick),
    links: <UpstreamLinkConfig>[
      UpstreamLinkConfig(
        alias: alias,
        protocol: UpstreamProtocol.opcUa,
        endpoint: fixture.endpoint,
        // In-process, as every OPC UA leg in this package does it: the isolate
        // is what production wants and what a test cannot easily reach into.
        useIsolate: false,
      ),
    ],
    // Empty, because this file hands `buildGateway` the mappings directly. The
    // path is `main`'s business and `gateway_config_test.dart` judges it.
    keyMappingsPath: '',
    staleAfter: staleAfter,
  );

  final gateway = await buildGateway(
    resolver: const PermissiveSeriesResolver(),
    config,
    mappings: mappings,
    log: Logger(level: Level.off),
    // Discarded rather than printed: two legs provoke upstream faults on
    // purpose, and a suite that printed a stack per provoked error trains
    // everyone to scroll past the one that matters.
    onError: (_, __, ___) {},
  );
  addTearDown(gateway.stop);

  await gateway.plant.start();
  await gateway.server.start();

  final keys = <String>{
    ...plantKeys,
    // Both flavours of health key, in the same set as a motor speed. That they
    // travel in one `subscribe` is the point of criterion 4.
    PipeKeys.upstreamConnected(alias),
    PipeKeys.upstreamState(alias),
    PipeKeys.connected,
    PipeKeys.linkDegraded,
    PipeKeys.pendingKeys,
    ...extraPanelKeys,
  };

  final statuses = <List<StatusParams>>[];
  final dialled = <RemoteStateMan>[];
  for (var i = 0; i < panels; i++) {
    final mine = <StatusParams>[];
    statuses.add(mine);
    final client = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${gateway.server.port}'),
      config: ClientConfig(),
      keys: keys,
      onStatus: mine.add,
    );
    addTearDown(client.dispose);
    // **Before the first snapshot, deliberately.** `RemoteStateMan.subscribe`
    // is a view over a node and pushes on change, so a stream taken after the
    // subscribe snapshot has already landed sees nothing until the next value —
    // which for a health key that only moves on a link event is never. A leg
    // that asserted on such a stream would be asserting that health keys are
    // quiet, not that they arrive.
    watch?.call(client);
    dialled.add(client);
  }

  for (final client in dialled) {
    await until(() => client.linkState == LinkState.ready,
        describe: 'the panel reaching ready over a real socket');
    await until(() => client.read(speedKey) != null,
        describe: 'the first plant value crossing PLC -> panel');
  }

  return E2E._(fixture, gateway, dialled, statuses);
}

void main() {
  /// **ROADMAP criterion 5, second half**: *"a value crosses the whole way
  /// carrying the quality and source time the PLC gave it"*.
  ///
  /// The one assertion in this phase that no single layer can make. The value
  /// is stamped by a real OPC UA server, held on the wire for a second and a
  /// half, and then read on a panel three process boundaries away — and the
  /// instant it reports must still be the server's.
  ///
  /// **How the offset is made, and why not the obvious way.** 08-07 measured it:
  /// the pinned binding gives no control over `sourceTimestamp` on either node
  /// kind, and a value written early and subscribed late comes back restamped
  /// at sampling time (measured: 66 ms). So the offset is made by *delaying
  /// delivery* rather than by back-dating a stamp — the sample is stamped at T0
  /// and held in the fault proxy — which means the instant asserted on is the
  /// real server's own clock rather than a number this test made up.
  group('criterion 5: a plant value crosses whole', () {
    test(
        'a value stamped by the PLC and held on the wire for a second and a '
        'half reaches the panel reporting the PLC\'s instant, not the panel\'s',
        () async {
      final e2e = await standUp(viaFaultProxy: true);
      final proxy = e2e.fixture.proxy!;

      // Withhold the PLC -> gateway direction. The gateway keeps sending
      // PublishRequests; only the answers are held.
      proxy.bufferServerToClient = true;
      e2e.fixture.setValue(speedKey, 1477);
      final stampedAround = DateTime.now().toUtc();

      const held = Duration(milliseconds: 1500);
      await Future<void>.delayed(held);
      // Phase 2's documented trap, named rather than worked around: `flush()`
      // is a no-op while withhold is OFF, so the order is load-bearing —
      // release while still buffering, then stop buffering.
      proxy.flush();
      proxy.bufferServerToClient = false;

      await until(() => e2e.panel.read(speedKey)?.value == 1477,
          describe: 'the held sample arriving on the panel');
      final arrivedAt = DateTime.now().toUtc();
      final onGlass = e2e.panel.read(speedKey)!;
      final sourceTime = onGlass.sourceTime!.toUtc();
      final offset = arrivedAt.difference(sourceTime);
      final onPlant = e2e.gateway.plant.read(speedKey)!;

      print('CHAIN plant-side sourceTime = '
          '${onPlant.sourceTime?.toUtc().toIso8601String()}');
      print('CHAIN panel-side sourceTime = ${sourceTime.toIso8601String()}');
      print('CHAIN panel arrival instant = ${arrivedAt.toIso8601String()}');
      print('CHAIN offset                = ${offset.inMilliseconds} ms');
      print('CHAIN quality on the glass  = ${onGlass.quality}');

      expect(onGlass.quality, Quality.good,
          reason: 'the PLC answered good and the panel must say so');
      expect(offset.inMilliseconds, greaterThan(1000),
          reason: 'the value was stamped by the PLC before it was held on the '
              'wire for ${held.inMilliseconds} ms. Any layer between here and '
              'there that restamps — the adapter, LocalStateMan\'s ingest, the '
              'fan-out, the wire encoding, the client store — collapses this '
              'offset to milliseconds, and "fresh" comes to mean "we heard '
              'about it just now" rather than "the plant measured it just now"');
      expect(sourceTime.isBefore(stampedAround.add(const Duration(seconds: 1))),
          isTrue,
          reason: 'and it must be the instant around the write, not some other '
              'past instant — a layer reporting a constant would pass the '
              'offset check above too');
      expect(onPlant.sourceTime?.toUtc().millisecondsSinceEpoch,
          sourceTime.millisecondsSinceEpoch,
          reason: 'the instant on the panel is the instant on the plant, to '
              'the millisecond the wire carries. A difference here is the '
              'socket leg restamping, which is the one leg 08-07 could not see');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  /// **ROADMAP criterion 4**: client-side `PIPE.*` keys and server-side
  /// per-client keys *"subscribable through the ordinary value path"*.
  ///
  /// Two producers, two homes, one `subscribe` call. The per-plant key comes
  /// from `LocalStateMan` and the per-session key from the server's health
  /// overlay, and a panel cannot tell them apart — which is the property: there
  /// is no health method on the wire and its absence is a recorded decision
  /// (design §4.7, HLTH-01).
  group('criterion 4: both kinds of health key are ordinary keys', () {
    test(
        'a per-plant key and a per-session key arrive in the same subscribe '
        'snapshot as a motor speed, through the same subscribe call', () async {
      final perPlant = PipeKeys.upstreamConnected(alias);
      const perSession = PipeKeys.linkDegraded;

      // Taken as streams, exactly as a widget would take a motor speed, and
      // taken before the panel has been served anything at all — so what these
      // record is the subscribe SNAPSHOT arriving, which is the half of
      // criterion 4 that a `read` after the fact cannot distinguish from a
      // value that was there all along.
      final seen = <String, List<Object?>>{
        perPlant: <Object?>[],
        perSession: <Object?>[],
        speedKey: <Object?>[],
      };
      final subs = <StreamSubscription<DynamicValue>>[];
      final e2e = await standUp(watch: (panel) {
        for (final key in seen.keys) {
          subs.add(panel.subscribe(key).listen((v) => seen[key]!.add(v.value)));
        }
      });
      addTearDown(() => Future.wait(subs.map((s) => s.cancel())));

      await until(
          () =>
              e2e.panel.read(perPlant) != null &&
              e2e.panel.read(perSession) != null,
          describe: 'both flavours of health key arriving on the panel');

      print('HEALTH $perPlant  = ${e2e.panel.read(perPlant)!.value}');
      print('HEALTH $perSession = ${e2e.panel.read(perSession)!.value}');
      print('HEALTH panel key count = ${e2e.panel.keys.length}');

      expect(e2e.panel.keys, contains(perPlant),
          reason: 'the per-plant health key is missing from the panel\'s key '
              'list; the diagnostics page and the page editor\'s picker find '
              'keys that way, so an indicator nobody can discover is one '
              'nobody will put on a page');
      expect(e2e.panel.keys, contains(perSession),
          reason: 'and the per-session key must be discoverable the same way, '
              'from the overlay the server chains over the plant');
      // Inside a window, like everything else here, and for a reason worth
      // naming: the snapshot legitimately carries `false`. `LocalStateMan.start`
      // publishes the health keys the instant it has asked a link to connect,
      // and `OpcUaUpstreamLink` does not report `connected` until the wrapper's
      // heartbeat has proved the data plane works — so a panel that dials
      // during that gap is told the truth twice, and the second answer is the
      // one this asserts on.
      await until(() => e2e.panel.read(perPlant)!.asBool == true,
          describe: '$perPlant reaching true once the link is proven up');
      print('HEALTH $perPlant settled = ${e2e.panel.read(perPlant)!.value}');
      expect(e2e.panel.read(perPlant)!.asBool, isTrue,
          reason: 'the link is up and its own health key says it is not');
      expect(e2e.panel.read(perSession)!.value, isFalse,
          reason: 'a quiet panel\'s send buffer is not shedding');

      await until(
          () => seen[perPlant]!.isNotEmpty && seen[perSession]!.isNotEmpty,
          describe: 'both health keys arriving in the subscribe snapshot');
      print('HEALTH snapshot pushes: $perPlant=${seen[perPlant]!.length} '
          '$perSession=${seen[perSession]!.length} '
          '$speedKey=${seen[speedKey]!.length}');
      expect(seen[speedKey], isNotEmpty,
          reason: 'and the motor speed came down the identical path — if it '
              'did not, this case is comparing health keys against nothing');
    }, timeout: const Timeout(Duration(minutes: 3)));

    /// **The arm that catches the two producers colliding.**
    ///
    /// `PIPE.connected` has a plant-side producer (08-11) and the session
    /// overlay deliberately does not claim it (08-12's handoff note 2), so the
    /// composition is this plan's decision and this is where it is asserted:
    /// the two rosters are disjoint, and the bit a panel reads is the plant's.
    test(
        'the per-session roster and the per-plant roster are disjoint, so no '
        'PIPE. name is served by two producers', () async {
      final e2e = await standUp();

      // The plant's `PIPE.` roster is derived from what it has actually
      // produced, so it grows during startup — read inside a window like every
      // other state in this file, or the disjointness below is asserted against
      // a roster that is still filling.
      await until(
          () => e2e.gateway.plant.keys.contains(PipeKeys.connected),
          describe: 'the plant publishing its own PIPE. roster');

      final overlay = SessionHealthStateMan.perSessionKeys.toSet();
      final plantSide = e2e.gateway.plant.keys
          .where(PipeKeys.isPipeKey)
          .toSet();
      final collisions = overlay.intersection(plantSide);

      print('DISJOINT per-session roster = ${overlay.length} keys');
      print('DISJOINT plant-side PIPE.   = ${plantSide.length} keys');
      print('DISJOINT collisions         = $collisions');

      expect(collisions, isEmpty,
          reason: 'a name served by both the shared plant and the per-session '
              'overlay is a number that is right for whichever of them the '
              'chain happens to ask first — and the chain asks the overlay, so '
              'the plant\'s answer would be silently shadowed');
      expect(plantSide, contains(PipeKeys.connected),
          reason: 'PIPE.connected is the plant bit here (08-11) and the '
              'overlay leaves it alone on purpose; if the plant stopped '
              'producing it the panel would read an indicator nobody writes');
      expect(overlay, isNot(contains(PipeKeys.connected)),
          reason: 'and the overlay must keep leaving it alone: the socket half '
              'and the plant half are different facts and composing them is a '
              'decision, not a default');

      // A window, for the reason the previous case names: the plant bit is
      // published as soon as a link has been ASKED to connect and only turns
      // true once every configured link has proved itself.
      await until(() => e2e.panel.read(PipeKeys.connected)?.asBool == true,
          describe: 'the composed PIPE.connected reaching the panel as true');
      print('DISJOINT PIPE.connected on the panel = '
          '${e2e.panel.read(PipeKeys.connected)!.value}');
      expect(e2e.panel.read(PipeKeys.connected)!.asBool, isTrue,
          reason: 'every configured link is up, so the plant bit is true and '
              'that is what crossed');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  /// **ROADMAP criterion 3**: *"killing the upstream while a panel watches
  /// greys out that PLC's keys on the panel and announces once"*.
  group('criterion 3: link loss reaches the glass', () {
    test(
        'the PLC\'s keys go bad on the panel, the connected key flips, and the '
        'loss is announced once per link event rather than once per key',
        () async {
      // **Thirty seconds, and the number is load-bearing.** The measured
      // detection floor for a blackholed OPC UA session is open62541's
      // keep-alive at ~8.7 s (08-07). A `staleAfter` under that would let the
      // freshness sweep grey every key before the link loss did, and the
      // degrade-then-announce assertion below would pass for the wrong reason —
      // measured at `staleAfter: 2s`, where all five keys were already bad
      // before the kill.
      final e2e = await standUp(
          viaFaultProxy: true, staleAfter: const Duration(seconds: 30));
      final perPlant = PipeKeys.upstreamConnected(alias);

      await until(() => e2e.panel.read(perPlant)?.asBool == true,
          describe: 'the link reading connected before it is killed');
      for (final key in plantKeys) {
        await until(() => e2e.gateway.plant.read(key)?.quality.isGood ?? false,
            describe: '$key reading good on the plant before the kill');
      }

      // The startup announcement is a real announcement and the panel was right
      // to get it; this arm is about the LOSS, so the ledger starts here.
      print('LOSS  announcements before the kill = '
          '${e2e.statuses.first.map((s) => s.state).toList()}');
      e2e.statuses.first.clear();

      // The kill: every byte in both directions is dropped, the TCP connection
      // stays formally open. This is the frozen-session failure and it is the
      // one a purely event-driven status never notices at all.
      e2e.fixture.proxy!.blackhole();

      final toFirstAnnouncement = await until(
          () => e2e.statuses.first.isNotEmpty,
          describe: 'the loss reaching the panel as a status notification');

      // **Degrade, then announce** — asserted at the instant of the first
      // announcement, which is the only instant at which the ordering is
      // falsifiable. A panel that learns the link is down and then reads a key
      // which has not yet degraded sees a good value under a dead link.
      final announcements = e2e.statuses.first.length;
      final stillGood = <String>[
        for (final key in plantKeys)
          if (e2e.gateway.plant.read(key)?.quality.isGood ?? false) key,
      ];

      print('LOSS  detected in            = ${toFirstAnnouncement.inMilliseconds} ms');
      print('LOSS  announcements at that instant = $announcements');
      print('LOSS  keys behind the link   = ${plantKeys.length}');
      print('LOSS  first announcement     = ${e2e.statuses.first.first.alias} '
          '/ ${e2e.statuses.first.first.state}');
      print('LOSS  still good on the plant = $stillGood');

      expect(announcements, 1,
          reason: 'the first thing the panel heard about a ${plantKeys.length}-'
              'key link going down must be ONE notification. The same shape at '
              'fifteen hundred keys is fifteen hundred events for one event, '
              'delivered in the instant the panel is redrawing every box they '
              'are all about');
      expect(stillGood, isEmpty,
          reason: 'the announcement went out while these keys still read good '
              'quality, so a panel acting on it reads a confident number from '
              'a PLC this process has already lost');
      expect(e2e.statuses.first.first.alias, alias,
          reason: 'and the notification names which PLC, or a four-PLC plant '
              'has learned only that something somewhere is wrong');
      expect(e2e.statuses.first.first.state,
          isNot(UpstreamLinkState.connected.wireName),
          reason: 'the announcement being counted must be the loss and not the '
              'startup "connected" one — an arm that counted the wrong event '
              'would pass before the link was even killed');

      await until(() => e2e.panel.read(perPlant)?.asBool == false,
          describe: '$perPlant flipping on the panel');
      for (final key in plantKeys) {
        await until(() => !e2e.panel.read(key)!.quality.isGood,
            describe: '$key going bad-quality on the panel');
      }
      print('LOSS  panel $perPlant = ${e2e.panel.read(perPlant)!.value}');
      print('LOSS  panel $speedKey quality = '
          '${e2e.panel.read(speedKey)!.quality}');

      expect(e2e.panel.read(perPlant)!.quality, Quality.good,
          reason: 'the health key itself is never greyed by the loss it '
              'reports (HLTH-02) — a light that goes out when the thing it '
              'monitors fails is not an indicator');
    }, timeout: const Timeout(Duration(minutes: 3)));

    /// One shared plant, two private sessions.
    test(
        'a second panel sees the same upstream loss but reads its own '
        'per-session numbers', () async {
      final e2e = await standUp(
          panels: 2, viaFaultProxy: true, staleAfter: const Duration(seconds: 2));
      final perPlant = PipeKeys.upstreamConnected(alias);
      final [first, second] = e2e.panels;

      await until(
          () =>
              first.read(PipeKeys.linkDegraded) != null &&
              second.read(PipeKeys.linkDegraded) != null,
          describe: 'both panels reading their own link_degraded');

      final sessions = e2e.gateway.server.sessions.sessions;
      print('TWO   sessions on the gateway = ${sessions.length}');
      print('TWO   panel A link_degraded = ${first.read(PipeKeys.linkDegraded)!.value}');
      print('TWO   panel B link_degraded = ${second.read(PipeKeys.linkDegraded)!.value}');

      expect(sessions, hasLength(2));
      expect(identical(sessions[0].api.source, sessions[1].api.source), isFalse,
          reason: 'one overlay serving two panels answers every per-session '
              'question with whichever session it happened to be bound to '
              '(T-08-45), so the quiet panel is told the busy panel\'s '
              'condition');
      expect(
          identical(
              (sessions[0].api.source as CertHealthStateMan).source,
              (sessions[1].api.source as CertHealthStateMan).source),
          isTrue,
          reason: 'and the plant underneath them is ONE instance — two '
              'LocalStateMen would mean two subscriptions to every PLC tag, '
              'which is the single-plant-owner promise broken at the last hop');
      expect(identical(sessions[0].api.source, e2e.gateway.plant), isFalse,
          reason: 'the overlay is in the chain slot, not bypassed');

      e2e.fixture.proxy!.blackhole();

      await until(
          () =>
              first.read(perPlant)?.asBool == false &&
              second.read(perPlant)?.asBool == false,
          describe: 'both panels seeing the same upstream loss');
      print('TWO   panel A $perPlant = ${first.read(perPlant)!.value}');
      print('TWO   panel B $perPlant = ${second.read(perPlant)!.value}');
      print('TWO   panel A link_degraded after loss = '
          '${first.read(PipeKeys.linkDegraded)!.value}');
      print('TWO   panel B link_degraded after loss = '
          '${second.read(PipeKeys.linkDegraded)!.value}');

      expect(first.read(PipeKeys.linkDegraded)!.value, isFalse,
          reason: 'the PLC is gone; neither panel\'s SOCKET is degraded, and '
              'conflating the two would put a plant fault on the pipe\'s own '
              'health line');
      expect(second.read(PipeKeys.linkDegraded)!.value, isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  /// **HLTH-03, end to end.** A keymapping entry claiming a name inside the
  /// reserved `PIPE.` prefix is refused at boot, per key, and the name is
  /// absent from everything a panel can browse or read — while every other
  /// entry on the same file is served.
  group('HLTH-03: a squatted PIPE. name never reaches a panel', () {
    test(
        'the reserved name is refused at boot, the gateway starts anyway, and '
        'the panel cannot read it', () async {
      const squatted = 'PIPE.motor_speed';
      final e2e = await standUp(
        extraMappings: <String, KeyMappingEntry>{
          squatted: mappingFor(speedKey),
        },
        extraPanelKeys: <String>{squatted},
      );

      print('HLTH3 refused at boot = ${e2e.gateway.refusedKeys}');
      print('HLTH3 on the plant    = '
          '${e2e.gateway.plant.keys.contains(squatted)}');
      print('HLTH3 on the panel    = ${e2e.panel.keys.contains(squatted)}');

      expect(e2e.gateway.refusedKeys, contains(squatted),
          reason: 'a keymapping entry that claims the gateway\'s own namespace '
              'must be named at boot — the operator who wrote it is the only '
              'person who can fix it and the log is where they will look');
      expect(e2e.gateway.plant.keys, isNot(contains(squatted)),
          reason: 'offering a refused name back to the key picker would '
              'launder a squatted name into an apparently valid binding');
      expect(e2e.panel.keys, isNot(contains(squatted)));
      expect(e2e.panel.read(squatted), isNull,
          reason: 'and no value for it ever crossed');

      final read = await e2e.panel.readMany(<String>[squatted, speedKey]);
      print('HLTH3 readMany quality = ${read[squatted]?.quality}');
      expect(read[squatted]?.quality, Quality.errorConfig,
          reason: 'a refused key comes back as a value that RENDERS rather '
              'than as an absence that does not — a missing map entry is '
              'indistinguishable from a key nobody asked for, so a diagnostics '
              'page writes a blank cell exactly where it needed a fault');

      // The other half of T-08-51, and the reason the refusal is per key: the
      // plant is not down because one mapping entry is wrong.
      expect(read[speedKey]?.quality, Quality.good,
          reason: 'every other entry on the same keymapping file is served; a '
              'gateway that refused to boot over one bad line would be a plant '
              'that is dark over one bad line');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
