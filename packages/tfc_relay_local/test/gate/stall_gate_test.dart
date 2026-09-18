/// F22 — Gateway stall: a synchronized false disconnect on every client.
///
/// Catalogue §7.9, verbatim on one line each so a `grep -F` finds the same
/// bytes in the registry and here:
///
///   Injection:  SIGSTOP gateway 45 s; 5 clients, 3 upstreams
///   Expect:     every value returns to good quality unaided (Ignition's bug:
///               stuck until hand-toggled); historian marks the gap; clients
///               shown "gateway stalled", not "you disconnected"
///
/// **What this file delivers.** This file gates the whole row: the
/// announcement (F22a), the operator sentence (F22b), staleness-that-clears-
/// unaided (F22c), the reaper clause (F22d, 09-08) — the row's headline
/// "synchronized false disconnect on every client", reproduced by our own
/// reaper rather than by the freeze if `tickOnce`'s wake-up sweep blames the
/// panels for the gateway's own silence — and, since 09-09, the historian
/// clause (F22e): the freeze is a hole in the history, never a flat line,
/// asserted by one SQL query over a window spanning the freeze against a real
/// TimescaleDB. F22e is `db`-tagged PER CASE (the rest of the file stays in
/// the pure-Dart lane) and rides 8b-03's env-addressed `timescale_fixture` —
/// 09-CONTEXT ruling 2's arm, taken rather than its fallback.
///
/// **The arm letters are delivery order, not clause order.** The plan named
/// these arms a/b/d, reserving c for the reaper clause. The frozen manifest's
/// arm-letter sweep (`gate_b_manifest_test.dart`, "arm letters are unique and
/// gapless") requires the delivered arms to run a, b, c with no gap, so the
/// staleness arm the plan calls F22d is lettered F22c here; the reaper and
/// historian take the next free letters when 09-08 and 09-09 land. The clause
/// identity is preserved in each case's doc and in the outstanding entry.
///
/// **The honest lever, and the two things it decides** (the plan's `<house_
/// rules>`, restated). Whatever is being frozen cannot be the thing observing:
/// `stall_harness.dart` puts the gateway, its three upstreams and a
/// self-driving plant in one isolate this file can `Isolate.pause`, and the
/// panels stay in the test isolate. The capability probe below re-measures on
/// THIS platform what a paused isolate that owns a listening socket does —
/// assumption A3 — because the in-repo pause number (07-RESEARCH §A.4) was
/// taken on a client isolate with no socket.
///
/// **The measured client fact that shapes every arm.** A `RemoteStateMan`'s
/// `viewIsStale` and its reconnect fire on ONE timer
/// (`freshness_watchdog.dart:392` — `_linkWentQuiet` sets `_viewIsStale` and
/// then calls `onQuiet`). So a panel whose `freshnessDeadline` is shorter than
/// the freeze goes stale AND tears its socket down, and on resume it reconnects
/// fresh — it never sees the `gateway_stalled` resync, which the gateway pushes
/// to the session it still holds. A panel whose deadline outlasts the freeze
/// stays connected and receives the announcement but never reports
/// `viewIsStale`. Measured on this harness: a 3 s-deadline panel over a ~10 s
/// pause went `viewIsStale`/`down`/`connecting` at 3 s and recovered unaided on
/// resume with zero complaints; a 30 s-deadline panel stayed `ready` through
/// the pause and recorded the resync. The two are mutually exclusive per
/// panel, so **F22b (the sentence, on connected panels) and F22c (staleness,
/// on short-deadline panels) are different cases**, not one — the plan's "assert
/// them together" is unrepresentable in this client, and the SUMMARY records
/// the measurement. They are still the pair the row is about: stale-and-
/// recovering is the honest state, and it is a different state from being told
/// the gateway stalled — which is itself different from a link-down banner.
///
/// **`PIPE.*` health-key homes** (08-09's F22 exemption). The per-link keys
/// (`PipeKeys.upstreamConnected`/`upstreamState`) are the LOCAL package's,
/// minted by `LocalStateMan` inside the frozen isolate; the per-session keys
/// are the server's. This file reads plant keys and the per-link keys, both of
/// which live in the frozen isolate — so during the freeze they too stop
/// advancing, which is the point. No case here reads a per-session health key.
@TestOn('vm')
@Tags(['gate'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/gate_b_fixture.dart' show gateBPage, until, within;
import '../support/stall_harness.dart';
import '../support/timescale_fixture.dart';

/// The `reason` a stalled gateway announces itself under — one of
/// `ResyncParams`' documented vocabulary (`messages.dart:455-464`). Spelled
/// here as the wire literal rather than imported: `tfc_relay_server`'s
/// `gatewayStalled` constant is not exported, and the client branches on this
/// exact string.
const gatewayStalled = 'gateway_stalled';

/// The three upstreams F22's row names, and the page each carries.
const _aliases = <String>['ST101', 'ST201', 'ST301'];
const _keysPerAlias = 20;

/// One key every arm watches — a real plant name, first motor of the first
/// device on the first PLC.
const _watch = 'ST101.CN01.MOT01.setpoint';

/// The whole page a panel subscribes to: every plant key across the three
/// upstreams.
Set<String> _page() => <String>{
      for (final alias in _aliases) ...gateBPage(alias, _keysPerAlias),
    };

/// How long the gateway is frozen in the default lane.
///
/// Five seconds: comfortably past the 300 ms `stallThreshold` so the
/// `LagMonitor` announces, past a short panel `freshnessDeadline` so F22c's
/// panels go stale, and short enough that the whole file stays inside the gate
/// budget. The catalogue's 45 s runs behind `RELAY_SOAK` — F22's registry
/// deviation ("SIGSTOP gateway 45 s", 09-CONTEXT ruling 6) records the
/// shortening. Exceeding the gateway's *heartbeatDeadline* is 09-08's reaper
/// concern; these arms set that deadline generously so no reap competes with
/// the announcement they measure.
Duration _freeze() =>
    (Platform.environment['RELAY_SOAK']?.isNotEmpty ?? false)
        ? const Duration(seconds: 45)
        : const Duration(seconds: 5);

/// A raw observing socket: it says hello, subscribes, and records every frame
/// the gateway pushes — so a case can read the `gateway_stalled` resync off the
/// wire, whole, **before** the client fix teaches `RemoteStateMan` to surface
/// it. This is F22a's instrument and its anti-vacuity: the wire carries the
/// fact whether or not any panel decodes it (the pub/sub survey's shape).
final class _WireObserver {
  _WireObserver._(this._socket, this.frames);

  final WebSocket _socket;

  /// Every text frame the gateway sent, in order.
  final List<String> frames;

  final _pending = <int, Completer<Map<String, Object?>>>{};

  /// The close frame this observer received, if the gateway ever closed it.
  ///
  /// F22d's whole verdict rides on these two fields: `RemoteStateMan` cannot
  /// see a close code (`web_socket_channel` #1698 — its supervisor reports
  /// only "the transport ended"), so the raw socket is the one place a `4003`
  /// and its `"no heartbeat for N ms"` sentence are readable at all. Null
  /// until the socket's stream is done; `dart:io` populates `closeCode` and
  /// `closeReason` for a close the FAR end initiated, which a reap is.
  int? closeCode;
  String? closeReason;

  /// Whether the gateway's stream has ended, whatever the code.
  bool get closed => _done;
  var _done = false;

  Timer? _beat;

  /// Stands one up over a raw `dart:io` WebSocket — no `web_socket_channel`,
  /// no `json_rpc_2`, because all this instrument does is send two requests and
  /// record every notification the gateway pushes. Dials [port], says hello,
  /// subscribes [keys] under [sub], and returns once the snapshot has landed.
  ///
  /// [beatEvery] makes this observer a *panel* in the reaper's eyes: a `ping`
  /// notification on that period, so its session's `_lastSeen` keeps moving
  /// whenever the gateway is actually reading — and its bytes queue in the
  /// kernel, exactly like every real panel's, whenever it is not. F22d needs
  /// that: an observer that never beat would be reaped legitimately and its
  /// close would prove nothing about the freeze.
  static Future<_WireObserver> connect(int port, String sub, Set<String> keys,
      {Duration? beatEvery}) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port');
    final frames = <String>[];
    final observer = _WireObserver._(socket, frames);
    socket.listen(
      (Object? data) {
        final frame = '$data';
        frames.add(frame);
        final decoded = jsonDecode(frame);
        if (decoded is Map && decoded['id'] is int) {
          observer._pending
              .remove(decoded['id'])
              ?.complete(decoded.cast<String, Object?>());
        }
      },
      onError: (Object _) {},
      onDone: () {
        observer._done = true;
        observer.closeCode = socket.closeCode;
        observer.closeReason = socket.closeReason;
        observer._beat?.cancel();
      },
      cancelOnError: true,
    );
    addTearDown(() {
      observer._beat?.cancel();
      return socket.close().catchError((Object _) => null);
    });

    await observer._request(1, Methods.hello,
        HelloParams(
          protocol: protocolVersion,
          supported: const [protocolVersion],
          client: const PeerInfo('wire-observer', '0.0.1'),
        ).toJson());
    await observer._request(2, Methods.subscribe,
        SubscribeParams(sub: sub, keys: keys.toList()).toJson());
    if (beatEvery != null) {
      // A notification, not a request: the beat is evidence of life on the
      // READ side (any post-hello frame touches `_lastSeen`), and an answer
      // would only be response bookkeeping this instrument does not need.
      observer._beat = Timer.periodic(beatEvery, (_) {
        if (observer._done) return;
        socket.add(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': Methods.ping,
          'params': <String, Object?>{},
        }));
      });
    }
    return observer;
  }

  Future<Map<String, Object?>> _request(
      int id, String method, Map<String, Object?> params) {
    final answer = Completer<Map<String, Object?>>();
    _pending[id] = answer;
    _socket.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return answer.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
            'the wire observer got no answer to "$method" within 10 s'));
  }

  /// Every `gateway_stalled` resync this observer has seen, decoded.
  List<ResyncParams> get gatewayStalls => [
        for (final frame in frames)
          if (_resyncOf(frame) case final ResyncParams r)
            if (r.reason == gatewayStalled) r,
      ];

  static ResyncParams? _resyncOf(String frame) {
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return null;
    if (decoded['method'] != Methods.resync) return null;
    final params = decoded['params'];
    if (params is! Map) return null;
    return ResyncParams.fromJson(params.cast<String, Object?>());
  }
}

void main() {
  // ------------------------------------------------------- capability probe
  //
  // The file's first case, a SUPPORTING case that gates no row (registered in
  // gate_b_manifest_test.dart's _supportingCases). It measures on THIS
  // platform that pausing an isolate that OWNS A LISTENING SOCKET stops it
  // serving that socket — assumption A3 — by proving the plant freezes and a
  // command to the gateway times out while paused, then recovers on resume.
  // Re-measured here rather than trusted from F16's client-isolate number
  // (07-RESEARCH §A.4's instruction), and printed so the SUMMARY can paste it
  // per platform.
  test('the stall capability probe (supporting case, gates no row)', () async {
    final gw = await StalledGateway.spawn(
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
    );

    // A panel with a long deadline, so the probe's own numbers are about the
    // pause and not about the panel's reconnect timer.
    final panel = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${gw.port}'),
      config: ClientConfig(freshnessDeadline: const Duration(seconds: 30)),
      keys: _page(),
    );
    addTearDown(panel.dispose);
    await until('the probe panel to hold a value',
        () => panel.isReady && panel.read(_watch)?.value != null);

    // Running: the plant advances and the panel sees it move.
    final beforeSweeps = gw.reportsSeen;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final runningSweeps = gw.reportsSeen - beforeSweeps;
    final runningValue = panel.read(_watch)!.value as int;
    await until('the panel to see the plant advance',
        () => (panel.read(_watch)!.value as int) > runningValue);

    gw.pause();
    final atPause = gw.reportsSeen;
    final frozenValue = panel.read(_watch)!.value as int;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final duringPause = gw.reportsSeen - atPause;

    // Asked while frozen, expected to fail by name — the strongest available
    // statement that the isolate's event loop is not turning.
    Object? refusal;
    try {
      await gw.ask('sweeps', budget: const Duration(milliseconds: 400));
    } on Object catch (error) {
      refusal = error;
    }

    // The panel saw nothing new during the pause: its value did not move past
    // where it froze.
    final valueDuringPause = panel.read(_watch)!.value as int;

    gw.resume();
    await until('the plant to advance again after resume',
        () => (panel.read(_watch)!.value as int) > frozenValue);

    print('F22 probe: Isolate.pause of a socket-owning gateway — '
        '$runningSweeps plant sweeps in 400 ms running, $duringPause across '
        '600 ms of pause; ask() while paused: ${refusal.runtimeType}; '
        'panel value frozen at $frozenValue, read $valueDuringPause mid-pause');

    expect(runningSweeps, greaterThan(0),
        reason: 'the plant produced no sweeps even while running, so a frozen '
            'count below would prove nothing');
    expect(duringPause, 0,
        reason: '$duringPause plant sweeps arrived from a paused isolate. '
            'Isolate.pause is F22\'s injection; if the event loop keeps turning '
            'on this platform the freeze injects nothing');
    expect(refusal, isA<TimeoutException>(),
        reason: 'a paused gateway answered a command: $refusal. The command '
            'loop is the event loop, so an isolate that can still reply is not '
            'stopped, and neither is its socket');
    expect(valueDuringPause, frozenValue,
        reason: 'the panel saw a new value ($valueDuringPause, was '
            '$frozenValue) while the gateway was paused — the pause did not '
            'block the socket on this platform, so bytes did not queue in the '
            'kernel as they do under SIGSTOP');
  }, timeout: const Timeout(Duration(minutes: 2)));

  // --------------------------------------------------------------- F22a
  //
  // The announcement arrives and is attributed. Five never-frozen panels watch
  // a gateway freeze; on resume, one gateway_stalled resync per live
  // subscription reaches the wire, carrying an ABSOLUTE stalledMs inside a band
  // around the real pause. Read off a raw observer, so this is GREEN before the
  // client fix: the wire carries the fact even while RemoteStateMan drops it.
  test('F22a: a frozen gateway announces itself — gateway_stalled with an '
      'absolute stalledMs reaches every live subscription', () async {
    final freeze = _freeze();
    final gw = await StalledGateway.spawn(
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
      // No reap competes with the announcement: the reaper is 09-08's row, and
      // a deadline shorter than the freeze would close these sessions before
      // the resume that announces to them.
      heartbeatDeadline: const Duration(seconds: 15),
    );

    // Five panels that stay connected through the freeze (deadline > freeze),
    // so the announcement has live subscriptions to reach.
    final panels = <RemoteStateMan>[];
    for (var i = 0; i < 5; i++) {
      final client = RemoteStateMan(
        uri: Uri.parse('ws://127.0.0.1:${gw.port}'),
        config: ClientConfig(
            freshnessDeadline: freeze + const Duration(seconds: 20)),
        keys: _page(),
      );
      panels.add(client);
      addTearDown(client.dispose);
    }
    // The wire observer, one subscription, the instrument F22a reads.
    final observer = await _WireObserver.connect(gw.port, 'observer', _page());

    // Anti-vacuity: every panel ready and holding an advancing value before the
    // freeze.
    await until(
        'all five panels and the observer to hold an advancing value',
        () => panels.every((c) => c.isReady && c.read(_watch)?.value != null));
    final before = panels.first.read(_watch)!.value as int;
    await until('the plant to advance before the freeze',
        () => (panels.first.read(_watch)!.value as int) > before);

    gw.pause();
    await Future<void>.delayed(freeze);
    gw.resume();

    // The announcement lands on the wire after resume.
    await within(
        Future(() async {
          while (observer.gatewayStalls.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }),
        'a gateway_stalled resync to reach the observer after the freeze',
        budget: const Duration(seconds: 10));

    final stalls = observer.gatewayStalls;
    final stalledMs = stalls.first.stalledMs;
    print('F22a: freeze ${freeze.inMilliseconds} ms, announced stalledMs='
        '$stalledMs, band [${freeze.inMilliseconds - 1500}, '
        '${freeze.inMilliseconds + 4000}], resyncs for observer='
        '${stalls.length}');

    expect(stalls, hasLength(1),
        reason: 'the observer holds one subscription and heard '
            '${stalls.length} gateway_stalled resyncs. One freeze is one '
            'announcement per subscription — Finding 10 measured no catch-up '
            'burst, so a debounce here would guard a storm measured not to '
            'happen');
    expect(stalledMs, isNotNull,
        reason: 'a gateway_stalled resync carried no stalledMs — the number is '
            'the whole content of the operator sentence F22b builds');
    expect(stalledMs, greaterThan(freeze.inMilliseconds - 1500),
        reason: 'the announced stalledMs $stalledMs is far below the '
            '${freeze.inMilliseconds} ms freeze: it must be the ABSOLUTE gap, '
            'not the excess over the tick period, because a panel renders it '
            'as "the plant view was frozen for N ms"');
    expect(stalledMs, lessThan(freeze.inMilliseconds + 4000),
        reason: 'the announced stalledMs $stalledMs is implausibly far above '
            'the ${freeze.inMilliseconds} ms freeze; the band tolerates '
            'scheduling slack on a loaded runner but not a wrong number');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --------------------------------------------------------------- F22b
  //
  // The panel says stalled, not disconnected. Same freeze as F22a, on connected
  // panels — but read off RemoteStateMan's own surface, the one an operator
  // sentence is built from, never off a log line. THIS ARM IS THE RED: before
  // the client fix `RemoteStateMan` has no stallReason/stalledMs surface at
  // all, so this case does not compile — the RED names the missing surface.
  // 09-07 task 3 adds the getters; this file is byte-identical between the RED
  // and the GREEN, which is task 3's own acceptance criterion.
  //
  // Paired with F22c by argument, not by structure (see the library doc): the
  // sentence here and the staleness there are the two halves of "stale-and-
  // explained, not link-down", and they need opposite freshnessDeadlines, so
  // they cannot share a panel.
  test('F22b: clients shown "gateway stalled", not "you disconnected" — the '
      'reason and duration are readable from an operator surface', () async {
    final freeze = _freeze();
    final gw = await StalledGateway.spawn(
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
      heartbeatDeadline: const Duration(seconds: 15),
    );

    final panels = <RemoteStateMan>[];
    for (var i = 0; i < 5; i++) {
      final client = RemoteStateMan(
        uri: Uri.parse('ws://127.0.0.1:${gw.port}'),
        config: ClientConfig(
            freshnessDeadline: freeze + const Duration(seconds: 20)),
        keys: _page(),
      );
      panels.add(client);
      addTearDown(client.dispose);
    }

    await until('all five panels to hold an advancing value',
        () => panels.every((c) => c.isReady && c.read(_watch)?.value != null));
    final before = panels.first.read(_watch)!.value as int;
    await until('the plant to advance before the freeze',
        () => (panels.first.read(_watch)!.value as int) > before);

    gw.pause();
    await Future<void>.delayed(freeze);
    gw.resume();

    // Every panel can say WHY it went quiet, in a sentence, from a surface a
    // widget binds to — not from a link-down banner and not from a log.
    await within(
        Future(() async {
          while (!panels.every((c) => c.stallReason == gatewayStalled)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }),
        'every panel to surface reason gateway_stalled after the freeze',
        budget: const Duration(seconds: 10));

    for (final panel in panels) {
      expect(panel.stallReason, gatewayStalled,
          reason: 'a panel could not say the gateway stalled; that is the '
              'defect Ruling 5a permits fixing — the wire carried the reason '
              'and connection_supervisor decoded and dropped it');
      expect(panel.stalledMs, isNotNull,
          reason: 'the panel has a stall reason but no duration, so it can say '
              '"stalled" but not "for how long" — half the sentence');
      expect(panel.stalledMs, greaterThan(freeze.inMilliseconds - 1500),
          reason: 'the surfaced stalledMs ${panel.stalledMs} is not the '
              'absolute gap the gateway sent; a client that recomputed it from '
              'its own clock would drift');
      // stale-and-explained is not link-down: the connection is up.
      expect(panel.linkState, LinkState.ready, // window-exempt: the within() above waited for every panel to surface gateway_stalled while still connected — this re-asserts the link stayed up through that completed event
          reason: 'the panel that was told the gateway stalled also shows the '
              'link down — the two states F22b keeps apart have collapsed '
              'into one');
    }
    print('F22b: five panels surface reason=gateway_stalled, stalledMs='
        '${[for (final p in panels) p.stalledMs]}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --------------------------------------------------------------- F22c
  //
  // Staleness is honest, and it clears unaided (the plan's F22d clause; see the
  // library doc on the letter). During the freeze the short-deadline panels
  // receive nothing, so they go stale — viewIsStale true, per-subscription
  // staleness set — and after the resume every value returns to good quality
  // with NOBODY TOUCHING ANYTHING: no operator toggle, no manual resubscribe,
  // no reconnect initiated by the test. This is the anti-Ignition clause
  // (their bug: stuck until hand-toggled). GREEN before task 3 — no product
  // change is needed for staleness to be honest.
  test('F22c: every value returns to good quality unaided — the panels go '
      'honestly stale during the freeze and recover on their own', () async {
    final freeze = _freeze();
    final gw = await StalledGateway.spawn(
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
    );

    // Short deadline, so the panels detect the silence and go stale during the
    // freeze — the whole subject of this clause.
    final panels = <RemoteStateMan>[];
    for (var i = 0; i < 5; i++) {
      final client = RemoteStateMan(
        uri: Uri.parse('ws://127.0.0.1:${gw.port}'),
        config: ClientConfig(freshnessDeadline: const Duration(seconds: 2)),
        keys: _page(),
      );
      panels.add(client);
      addTearDown(client.dispose);
    }

    await until('all five panels to hold an advancing value',
        () => panels.every((c) => c.isReady && c.read(_watch)?.value != null));
    final before = panels.first.read(_watch)!.value as int;
    await until('the plant to advance before the freeze',
        () => (panels.first.read(_watch)!.value as int) > before);
    final frozenValues = [for (final c in panels) c.read(_watch)!.value as int];

    gw.pause();

    // Every panel goes stale during the freeze — read inside a window, never at
    // an instant (the freeze is longer than the deadline, so this is a state
    // the panels reach, not a scheduler race).
    final toStale = Stopwatch()..start();
    await within(
        Future(() async {
          while (!panels.every((c) => c.viewIsStale)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }),
        'every panel to go viewIsStale during the freeze',
        budget: const Duration(seconds: 8));
    toStale.stop();
    // The per-subscription verdict is set too: this is the plant's silence, not
    // just the socket's.
    for (final panel in panels) {
      expect(panel.staleSubscriptions, isNotEmpty, // window-exempt: the within() above waited for every panel to reach viewIsStale during the freeze — this re-asserts the per-subscription verdict of that same completed event
          reason: 'a panel is viewIsStale but names no stale subscription, so '
              'it cannot tell the operator WHICH page stopped');
    }

    await Future<void>.delayed(freeze);
    gw.resume();

    // Recovery is unaided: the test does nothing. Every value comes back good,
    // past where it froze, and the staleness clears.
    final toClear = Stopwatch()..start();
    await within(
        Future(() async {
          while (!panels.every((c) =>
              !c.viewIsStale &&
              c.isReady &&
              (c.read(_watch)?.value as int? ?? -1) > frozenValues.first)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }),
        'every panel to return to good quality with no operator action',
        budget: const Duration(seconds: 15));
    toClear.stop();

    print('F22c: freeze ${freeze.inMilliseconds} ms, panels went stale in '
        '${toStale.elapsedMilliseconds} ms, cleared unaided in '
        '${toClear.elapsedMilliseconds} ms after resume; froze at '
        '$frozenValues, now advancing');

    for (final panel in panels) {
      expect(panel.viewIsStale, isFalse, // window-exempt: the within() above waited for every panel to clear staleness and advance past the freeze value — this re-asserts consistency with that completed recovery event
          reason: 'a panel stayed stale after the gateway came back and kept '
              'delivering — Ignition\'s exact bug, stuck until hand-toggled, '
              'reproduced here');
      expect(panel.read(_watch)!.value as int,
          greaterThan(frozenValues.first),
          reason: 'the value did not advance past where it froze, so the plant '
              'view has not actually recovered');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --------------------------------------------------------------- F22d
  //
  // The reaper clause — the row's headline, "synchronized false disconnect on
  // every client", reproduced by our own reaper rather than by the freeze.
  // `RelaySession.silentForMs()` reads a wall clock and `_lastSeen` advances
  // only when a frame is PROCESSED, so after a freeze every session looks as
  // silent as the freeze was long, whether or not its panel kept beating —
  // its bytes are in the kernel buffer, unread. `tickOnce` announces the
  // stall (`_tickSession`) and then reaps (`reap`) in the SAME synchronous
  // callback, so if the overdue timer wins the race against the queued socket
  // events on resume, the gateway both says "I was frozen" and closes every
  // panel with 4003 claiming THEY went silent. Whether the timer wins that
  // race is assumption A1 — unverified, platform-dependent — so this arm
  // asserts the OBSERVABLE (no close, no reap, no redial), never the
  // ordering, and prints the measurement whichever way it goes.
  //
  // The instrument: five real panels whose pumps beat throughout, plus one
  // raw beating socket — because a close code is readable only off a raw
  // socket (`web_socket_channel` #1698; the supervisor reports "the transport
  // ended" and swallows the code), and the reaper's "no heartbeat for N ms"
  // sentence is the only place a session's silentForMs ever crosses the wire.
  test('F22d: a woken gateway does not blame its panels — no 4003, no reap '
      'and no redial for silence the gateway itself caused', () async {
    final freeze = _freeze();
    // The reaper's own row needs the freeze to EXCEED the deadline — the
    // other arms set 15 s precisely so no reap competed with what they
    // measure. 3 s is `ServerConfig.defaultMinHeartbeatDeadline`, the
    // shortest deadline this gateway will accept, and the 5 s lane freeze
    // (45 s behind RELAY_SOAK) is comfortably past it. The panels learn the
    // number from hello and beat on a schedule derived from it.
    const deadline = Duration(seconds: 3);
    final gw = await StalledGateway.spawn(
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
      heartbeatDeadline: deadline,
    );

    // Five panels that beat throughout: the pump is wired by default and
    // derives its period from the deadline hello advertised. The freshness
    // deadline outlasts the freeze so no panel tears itself down — a
    // client-initiated reconnect would be F22c's subject, not the reaper's.
    final panels = <RemoteStateMan>[];
    for (var i = 0; i < 5; i++) {
      final client = RemoteStateMan(
        uri: Uri.parse('ws://127.0.0.1:${gw.port}'),
        config: ClientConfig(
            freshnessDeadline: freeze + const Duration(seconds: 20)),
        keys: _page(),
      );
      panels.add(client);
      addTearDown(client.dispose);
    }
    // The raw beating socket: a quarter of the deadline, the same order as
    // the pump's own deadline-derived period.
    final observer = await _WireObserver.connect(gw.port, 'observer', _page(),
        beatEvery: const Duration(milliseconds: 750));

    await until('all five panels to hold an advancing value',
        () => panels.every((c) => c.isReady && c.read(_watch)?.value != null));
    final before = panels.first.read(_watch)!.value as int;
    await until('the plant to advance before the freeze',
        () => (panels.first.read(_watch)!.value as int) > before);
    final sessionsBefore = await gw.ask('sessionCount') as int;

    gw.pause();
    await Future<void>.delayed(freeze);
    gw.resume();

    // The first tick after resume runs the announcement and the sweep in one
    // callback, so either a gateway_stalled resync or a close on the
    // observer's wire is proof the sweep has already decided.
    await within(
        Future(() async {
          while (observer.gatewayStalls.isEmpty && !observer.closed) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }),
        'the first post-resume tick to reach the observer '
        '(a gateway_stalled resync, or the close a reap would send)',
        budget: const Duration(seconds: 10));
    // One settle window before sampling, so a reap's unawaited closes cannot
    // hide in the sampling instant — post-event consistency, not a race.
    await Future<void>.delayed(const Duration(seconds: 1));

    final sessionsAfter = await gw.ask('sessionCount') as int;
    final downReasons = [for (final p in panels) p.lastDownReason];
    final reapFired = observer.closeCode != null ||
        downReasons.any((reason) => reason != null) ||
        sessionsAfter < sessionsBefore;
    final announced = observer.gatewayStalls.isNotEmpty
        ? observer.gatewayStalls.first.stalledMs
        : panels.first.stalledMs;

    // The measurement, whichever way the race went — the deliverable of this
    // arm even when it is green. silentForMs crosses the wire only inside a
    // reap's close reason, so "none" in that column IS the good outcome.
    print('F22d: freeze ${freeze.inMilliseconds} ms over a '
        '${deadline.inMilliseconds} ms deadline — reap fired: $reapFired; '
        'sessions $sessionsBefore -> $sessionsAfter; observer close: '
        '${observer.closeCode ?? 'none'} '
        '(${observer.closeReason?.isNotEmpty ?? false ? observer.closeReason : 'no reason'}); '
        'panel downs: $downReasons; announced stalledMs=$announced');

    expect(observer.closeCode, isNull,
        reason: 'the gateway closed a panel that beat through its whole '
            'freeze — code ${observer.closeCode}, reason '
            '"${observer.closeReason}". Its bytes were in the kernel buffer, '
            'unread; a reap here is the gateway blaming the panel for '
            'silence the gateway itself caused, which is the row\'s '
            '"synchronized false disconnect" reproduced by our own reaper');
    for (final panel in panels) {
      // lastDownReason is set by every _down, and a redial exists only after
      // a _down — so null here is both "never told it disconnected" and
      // "dial count unchanged across the stall" in one field.
      expect(panel.lastDownReason, isNull,
          reason: 'a beating panel went down across the gateway\'s own stall '
              '("${panel.lastDownReason}") — it was told it disconnected '
              'when the truth is the gateway froze, and it redialled for it');
      expect(panel.linkState, LinkState.ready, // window-exempt: the within() above waited for the post-resume tick and the settle window completed — this re-asserts the link never left ready across that completed event
          reason: 'a panel is not ready after the resume; the reaper (or a '
              'teardown it caused) took a session the panel never stopped '
              'earning');
    }
    expect(sessionsAfter, sessionsBefore,
        reason: 'the gateway holds $sessionsAfter sessions where it held '
            '$sessionsBefore before its own freeze: a session was reaped for '
            'the gateway\'s silence, and if it has already been re-dialled '
            'the panel paid a full resync for a freeze it did not cause');

    // And the link is genuinely live afterwards, not merely un-closed.
    final atResume = panels.first.read(_watch)!.value as int;
    await until('the plant to advance again after the resume',
        () => (panels.first.read(_watch)!.value as int) > atResume);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // --------------------------------------------------------------- F22e
  //
  // The historian clause — "historian marks the gap". Collection runs against
  // a REAL hypertable (8b-03's env-addressed fixture, brought up inside this
  // case only — the rest of the file stays in the pure-Dart lane) while the
  // gateway that owns the sink, the runner and its sample timers is frozen by
  // Isolate.pause. The sink runs `useIsolate: false` inside the frozen isolate
  // ON PURPOSE: a sink on its own isolate would keep writing through a freeze
  // this arm exists to see. After the resume, ONE query over a window spanning
  // the freeze asserts the gap: rows on both sides, zero inside. A flat line
  // of repeated last-known values through that window is the failure — it is
  // what makes the night the backup froze the gateway unexplainable afterwards
  // (Ignition's Veeam-snapshot incident, the row's own citation).
  //
  // The second half of the assertion is the counter: the freeze degrades the
  // held values (the sweep's elapsed clock keeps running while the isolate
  // does not), so the first post-resume ticks DECLINE on quality and count —
  // `PIPE.collect.rows_dropped` moves. There is no `rows_skipped_quality` key
  // and none is minted: quality skips ride the dropped counter (8b ruling; the
  // six-key roster is pinned by the protocol suite).
  //
  // The plant driver is quiesced for exactly the window being judged: stopped
  // one command before the pause, restarted one command after the counter is
  // read. Without that, the wake-up race between the overdue driver (50 ms)
  // and the overdue freshness sweep decides whether a fresh publish repaints
  // the key good before any tick can decline — the drop assertion would
  // measure the scheduler. With it, the post-resume window holds exactly what
  // a real PLC's first publishing interval holds: nothing yet, and a held
  // value the freeze made stale. The gap itself needs no quiesce — a paused
  // isolate runs no sample timer, which is the whole clause.
  test('F22e: historian marks the gap — a frozen gateway leaves a hole in '
      'the history, quality-coded and counted, never a flat line', () async {
    final freeze = _freeze();
    // Values the freeze left behind must DEGRADE before the driver refreshes
    // them, so staleAfter sits well under the freeze; the sweep runs every
    // staleAfter/4 (500 ms), so the first post-resume decline lands within
    // ~600 ms of the resume.
    const staleAfter = Duration(seconds: 2);
    const sampleInterval = Duration(milliseconds: 100);

    // 8b-03's fixture: Compose where Docker exists, TIMESCALEDB_EXTERNAL
    // where it does not — host and port from the environment, never literals.
    final fx = await TimescaleFixture.start();
    addTearDown(fx.stop);
    final admin = await fx.connect(applicationName: 'f22e-admin');
    addTearDown(admin.close);
    final base =
        'f22e_gap_${Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    addTearDown(() async {
      await admin.execute('DROP TABLE IF EXISTS "gw_$base" CASCADE');
      await admin.execute('DROP TABLE IF EXISTS "$base" CASCADE');
    });
    Future<int> rowsBetween(DateTime? from, DateTime? to) async {
      final where = <String>[
        if (from != null) '"time" > \'${from.toIso8601String()}\'',
        if (to != null) '"time" < \'${to.toIso8601String()}\'',
      ].join(' AND ');
      try {
        final rows = await admin.execute(
            'SELECT count(*) FROM "gw_$base"${where.isEmpty ? '' : ' WHERE $where'}');
        return rows.first.first! as int;
      } on Object catch (error) {
        if (error.toString().contains('42P01')) return 0; // not created yet
        rethrow;
      }
    }

    final gw = await StalledGateway.spawn(
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
      heartbeatDeadline: const Duration(seconds: 15),
      staleAfter: staleAfter,
      collect: (
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
        table: base,
        key: _watch,
        sampleInterval: sampleInterval,
      ),
    );
    expect(gw.collectFailures, isEmpty,
        reason: 'the collection chain did not stand up inside the gateway '
            'isolate — every assertion below would judge a historian that '
            'never wrote: ${gw.collectFailures}');

    // Anti-vacuity: the same count query, over a window with NO freeze in it,
    // returns a dense series — without this the gap below is also what a
    // collector that wrote nothing at all produces.
    final trendStart = DateTime.now().toUtc();
    await within(
        Future(() async {
          while (await rowsBetween(trendStart, null) < 6) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }),
        'the trend to run dense before the freeze '
        '(6 rows at a ${sampleInterval.inMilliseconds} ms interval)',
        budget: const Duration(seconds: 30));
    final dropsBefore = await gw.ask('drops') as int;

    // Quiesce, then freeze. The 300 ms settle after pause() lets any tick
    // already queued in the gateway's event loop land BEFORE the window
    // opens, so every row stamped inside [gapStart, gapEnd] would be a row
    // written for the frozen interval — which is exactly what must not exist.
    await gw.ask('quiesce');
    gw.pause();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final gapStart = DateTime.now().toUtc();
    await Future<void>.delayed(freeze);
    gw.resume();

    // The counter moves when the sweep degrades the held value and a tick
    // declines it. Bounded poll, deliberately NOT a failing window: under the
    // write-through sabotage the counter never moves, and the case must reach
    // the gap assertion below so the flat line is caught by the query, not by
    // a timeout here.
    var dropsAfter = dropsBefore;
    final declineBudget = Stopwatch()..start();
    while (dropsAfter <= dropsBefore &&
        declineBudget.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      dropsAfter = await gw.ask('drops') as int;
    }
    final gapEnd = DateTime.now().toUtc();
    await gw.ask('drive');

    // Rows resume on the far side of the window once the plant publishes
    // fresh values again.
    await within(
        Future(() async {
          while (await rowsBetween(gapEnd, null) < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }),
        'the trend to resume after the resume',
        budget: const Duration(seconds: 30));

    // ONE query over the window spanning the freeze, and the two flanks.
    final inGap = await rowsBetween(gapStart, gapEnd);
    final before = await rowsBetween(trendStart, gapStart);
    final after = await rowsBetween(gapEnd, null);
    print('F22e: freeze ${freeze.inMilliseconds} ms inside a '
        '${gapEnd.difference(gapStart).inMilliseconds} ms window '
        '${gapStart.toIso8601String()} .. ${gapEnd.toIso8601String()}; '
        'rows before/inside/after = $before / $inGap / $after; '
        'PIPE.collect.rows_dropped $dropsBefore -> $dropsAfter');

    expect(inGap, 0,
        reason: '$inGap rows carry timestamps inside the frozen window. A '
            'value written through the gateway\'s own freeze is a flat, '
            'plausible trend somebody later reads as "the line was running '
            'steady" — the historian marking the gap is the difference '
            'between an incident that can be explained and one that cannot');
    expect(dropsAfter, greaterThan(dropsBefore),
        reason: 'the gap is not COUNTED: PIPE.collect.rows_dropped never '
            'moved, so an operator asking "why is there no data across the '
            'freeze" has a hole with no number beside it. Quality skips ride '
            'the dropped counter — there is no separate skipped-quality key');
    expect(before, greaterThanOrEqualTo(6),
        reason: 'only $before rows landed in the no-freeze window, so the '
            'series was never dense and the empty gap above is also what a '
            'dead collector produces — the arm is vacuous');
    expect(after, greaterThanOrEqualTo(2),
        reason: 'rows never resumed after the resume: the freeze did not '
            'leave a gap, it killed collection outright, which is a different '
            'failure than the one this arm certifies');
  },
      tags: 'db',
      timeout: const Timeout(Duration(minutes: 5)));
}
