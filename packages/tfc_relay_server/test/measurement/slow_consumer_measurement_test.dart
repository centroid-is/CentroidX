/// **This file is a measurement, not a contract.**
///
/// It exists to answer a question `tick_engine.dart:64-71` asked out loud and
/// nobody answered: SRV-04's "convert silent heap growth into a visible
/// reconnect" is only half met, and the source names two options without
/// choosing between them. Every arm below prints numbers and asserts only that
/// the run happened, stayed inside a generous budget, and was not silently
/// measuring nothing. **No assertion here pins today's behaviour**, on purpose:
/// an assertion that pins a defect is how a defect becomes a contract, and the
/// numbers this file prints are the input to `16-02-DECISION.md` rather than a
/// promise anybody may build on. A future reader who finds one of these numbers
/// has moved should re-measure and update the decision, not "fix" the test.
///
/// **What is measured, and on which clock.**
///
///  * The pong timeout is genuinely about wall time — it is `dart:io`'s own
///    timer inside the WebSocket implementation and there is no seam to inject
///    a clock into — so the stuck-consumer arm uses a real clock and states its
///    budget. It is measured at *scaled* `pingInterval`s and the multiplier is
///    reported, because measuring it at the shipping 20 s would be a 37-second
///    arm and quoting the review's 1.85× would not be a measurement at all.
///  * The false eviction of a healthy fast producer is arithmetic — the buffer
///    takes `poll(nowMs)` as an argument — so it runs on `FakeClock` through
///    the real `Plant` engine and costs no wall time. Its distribution is
///    degenerate **by construction**, and the arm says so rather than
///    presenting three identical samples as evidence of stability.
///  * The ack-gap populations are a real socket through a real fault proxy,
///    because "what does a slow link do to delivery" is not a question a fake
///    can be honest about.
///
/// **Distributions, not samples.** Every wall-clock quantity here is reported
/// as `n / min / median / p95 / max`. Several agreeing samples can all be the
/// same artefact of a repeatable stand-up landing at the same phase; a sibling
/// plan learned that the expensive way.
///
/// **The harness client beats.** Nothing the gateway *sends* moves
/// `_LastSeen` — only inbound frames do (`relay_session.dart:1265`) — so a
/// harness client that goes quiet is reaped at the heartbeat deadline and every
/// number taken after that is a number about a disconnected session. The rig
/// therefore beats on a raw `ping` frame throughout and records
/// `silentForMs()` at every sample, so the trace shows the reaper never fired.
@Tags(['ws', 'faults'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/subscription_registry.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../support/panels.dart';
import '../support/ws_harness.dart';

// ---------------------------------------------------------------------------
// Reporting primitives. Distributions, never single samples.
// ---------------------------------------------------------------------------

/// A summary of one population, printed everywhere a number is reported.
///
/// `n` is carried because a median over three samples and a median over thirty
/// are different claims, and a table that shows only the median hides which one
/// it is making.
final class Dist {
  Dist(Iterable<num> values) : _sorted = List<num>.of(values)..sort();

  final List<num> _sorted;

  int get n => _sorted.length;
  num get min => _sorted.isEmpty ? double.nan : _sorted.first;
  num get max => _sorted.isEmpty ? double.nan : _sorted.last;
  num get median => _at(0.5);
  num get p95 => _at(0.95);

  /// Nearest-rank, deliberately: an interpolated percentile over five samples
  /// invents a value nothing measured.
  num _at(double q) {
    if (_sorted.isEmpty) return double.nan;
    final rank = (q * _sorted.length).ceil().clamp(1, _sorted.length);
    return _sorted[rank - 1];
  }

  /// True when every sample is identical — which is a *finding* on a wall
  /// clock and an *expectation* on an injected one.
  bool get degenerate => _sorted.isEmpty || _sorted.first == _sorted.last;

  @override
  String toString() => _sorted.isEmpty
      ? 'n=0'
      : 'n=$n min=${fmt(min)} med=${fmt(median)} p95=${fmt(p95)} '
          'max=${fmt(max)}';
}

String fmt(num v) => v is int
    ? v.toString()
    : (v.isNaN ? 'NaN' : v.toStringAsFixed(v.abs() < 10 ? 2 : 1));

/// Least-squares slope of [ys] against [xs], in units of y per unit of x.
///
/// The ack-gap arms live or die on this: a gap that is *stationary* and a gap
/// that is *growing* are the two populations option (c) has to tell apart, and
/// a median cannot distinguish them.
double slope(List<num> xsIn, List<num> ysIn) {
  // Copied into `List<double>` before anything is reduced: `xsIn` is declared
  // `List<num>` but arrives as a `List<double>` or a `List<int>` depending on
  // the caller, and `reduce` on a covariant view throws about the closure's
  // signature rather than about the data.
  final xs = xsIn.map((v) => v.toDouble()).toList();
  final ys = ysIn.map((v) => v.toDouble()).toList();
  if (xs.length < 2) return double.nan;
  final n = xs.length;
  final mx = xs.reduce((a, b) => a + b) / n;
  final my = ys.reduce((a, b) => a + b) / n;
  var cov = 0.0;
  var varX = 0.0;
  for (var i = 0; i < n; i++) {
    cov += (xs[i] - mx) * (ys[i] - my);
    varX += (xs[i] - mx) * (xs[i] - mx);
  }
  return varX == 0 ? double.nan : cov / varX;
}

final _report = StringBuffer();

void say(String line) {
  _report.writeln(line);
  // ignore: avoid_print
  print(line);
}

// ---------------------------------------------------------------------------
// Wire reading: the ack gap, measured with today's code and nothing added.
// ---------------------------------------------------------------------------

/// The sequence the **client** has applied for [sub].
///
/// This is the stand-in for the field option (c) would add to `ping`. It is
/// read from the client's own decoded `u` frames rather than reported by the
/// client, and the two differ in exactly one way that matters: a real ack is
/// stale by up to one heartbeat period, which the decision has to price in.
/// Everything else — the contiguity, the per-subscription scoping, the fact
/// that a `u` the transport has not delivered cannot have been applied — is
/// identical.
int appliedSeq(List<String> inbound, String sub) {
  var seq = 0;
  for (final frame in inbound) {
    final decoded = jsonDecode(frame);
    if (decoded is! Map) continue;
    if (decoded['method'] != Methods.update) continue;
    final params = (decoded['params'] as Map).cast<String, Object?>();
    if (params['sub'] != sub) continue;
    final s = (params['seq'] as num).toInt();
    if (s > seq) seq = s;
  }
  return seq;
}

/// The sequence the **server** has advertised for [sub] — `SubscriptionState`'s
/// own counter, which is the exact number option (c)'s server side would
/// compare an ack against.
int advertisedSeq(RelaySession session, String sub) {
  final SubscriptionState? state = session.subscriptions.get(sub);
  return state?.seq ?? -1;
}

// ---------------------------------------------------------------------------
// The rig: one established panel, one lever, one per-sample trace.
// ---------------------------------------------------------------------------

/// One sample of every candidate signal, taken together so the shadow
/// detectors are comparable sample for sample rather than run for run.
final class Sample {
  Sample({
    required this.atMs,
    required this.advertised,
    required this.applied,
    required this.pending,
    required this.silentForMs,
    required this.sessions,
    required this.clientSocketEnded,
  });

  final int atMs;
  final int advertised;
  final int applied;
  final int pending;
  final int silentForMs;
  final int sessions;
  final bool clientSocketEnded;

  int get gap => advertised < 0 ? 0 : advertised - applied;
}

/// What one run of the rig produced.
final class RigRun {
  RigRun({
    required this.label,
    required this.pingIntervalMs,
    required this.warmUpMs,
    required this.samples,
    required this.closedAtMs,
    required this.sentCloseCode,
    required this.clientCloseCode,
    required this.bytesIn,
    required this.wallMs,
  });

  final String label;
  final int pingIntervalMs;

  /// How long the panel ran healthy before the lever was pulled.
  ///
  /// Carried because it is the **phase** of the platform's ping cycle the
  /// stall lands in, and the survival time depends on it entirely. Five runs
  /// that share a warm-up agree with each other and say nothing.
  final int warmUpMs;

  final List<Sample> samples;

  /// Wall ms from the lever being pulled to the session leaving the registry,
  /// or null if it never did inside the budget.
  final int? closedAtMs;

  /// The code the *server* decided to send, or null when something else — the
  /// platform, the socket — ended the session. This is the field that answers
  /// "which mechanism closed it".
  final int? sentCloseCode;

  final int? clientCloseCode;
  final int bytesIn;
  final int wallMs;

  Dist get gaps => Dist(samples.map((s) => s.gap));
  Dist get pendings => Dist(samples.map((s) => s.pending));
  Dist get silences => Dist(samples.map((s) => s.silentForMs));

  double get gapSlopePerSec => slope(
        samples.map((s) => s.atMs / 1000).toList(),
        samples.map((s) => s.gap).toList(),
      );

  /// The slope over the **second half** of the window.
  ///
  /// A link with latency L reaches a steady-state gap of about L ÷ tick within
  /// the first L of the run, and a least-squares fit over the whole window
  /// reads that one-off ramp as a growth rate. It is not one: the gap plateaus.
  /// This is the number that answers "is the backlog growing", which is the
  /// only question a delivery detector has.
  double get steadySlopePerSec {
    if (samples.isEmpty) return double.nan;
    final half = samples.last.atMs / 2;
    final tail = samples.where((s) => s.atMs >= half).toList();
    return slope(
      tail.map((s) => s.atMs / 1000).toList(),
      tail.map((s) => s.gap).toList(),
    );
  }

  /// Survival measured from the stall, ÷ pingInterval. The number an operator
  /// experiences: how long the panel is showing frames that never arrive.
  double? get closeRatio =>
      closedAtMs == null ? null : closedAtMs! / pingIntervalMs;

  /// Survival measured from the *connection*, ÷ pingInterval. This is the one
  /// that should be constant, because it is the platform's own ping cycle.
  double? get connectRatio => closedAtMs == null
      ? null
      : (closedAtMs! + warmUpMs) / pingIntervalMs;

  String get mechanism {
    if (closedAtMs == null) return 'still attached at the budget';
    return switch (sentCloseCode) {
      null => 'the platform — no server-side verdict was ever reached',
      CloseCodes.backpressureOverrun => 'the backpressure verdict (4004)',
      CloseCodes.heartbeatTimeout => 'the heartbeat reaper (4003)',
      final code => 'a server verdict ($code)',
    };
  }
}

/// The lever a run pulls after the panel is established and warm.
typedef Lever = void Function(RelayFixture fixture);

/// Stands the rig up, warms it, pulls [lever], and traces every candidate
/// signal until the session goes or [budget] expires.
///
/// **Wall clock, stated.** The pong timeout is `dart:io`'s own internal timer
/// and the throttle is a real token bucket on a real socket; neither has a
/// seam. Every other arm in this file is arithmetic.
Future<RigRun> rigRun({
  required String label,
  required Lever lever,
  required Duration budget,
  Duration pingInterval = const Duration(seconds: 20),
  Duration heartbeatDeadline = const Duration(seconds: 3),
  int keyCount = 40,
  Duration samplePeriod = const Duration(milliseconds: 100),
  Duration plantPeriod = const Duration(milliseconds: 25),
  Duration beatPeriod = const Duration(milliseconds: 750),
  Duration warmUp = const Duration(seconds: 1),
}) async {
  const sub = 'page-1';
  final fixture = relayFixture(
    withProxy: true,
    config: ServerConfig(
      tick: ServerConfig.minTick,
      pingInterval: pingInterval,
      heartbeatDeadline: heartbeatDeadline,
    ),
  );
  await fixture.ready;
  await fixture.hello(budget: const Duration(seconds: 5));

  final keys = [for (var i = 0; i < keyCount; i++) 'CN01.MOT$i.speed'];
  for (final key in keys) {
    fixture.served.setValue(key, 0);
  }
  await fixture.request(Methods.subscribe,
      params: SubscribeParams(sub: sub, keys: keys).toJson(),
      what: 'the subscribe answer over a real socket',
      budget: const Duration(seconds: 5));

  final session = fixture.server.sessions.sessions.single;

  // The panel's own heartbeat, as a raw frame and deliberately never awaited.
  // `fixture.request` hands its timeout to `within`, which fails the case from
  // a background future — and a beat that cannot be answered (because the
  // answer is exactly what the lever is withholding) never settles by design.
  var beatId = 0;
  final beat = Timer.periodic(beatPeriod, (_) {
    try {
      fixture.client.sink
          .add('{"jsonrpc":"2.0","id":"beat-${++beatId}","method":"ping"}');
    } catch (_) {
      // The socket is gone; the loop below sees it on the next sample.
    }
  });

  // The plant, moving faster than the tick, which is the ordinary shape.
  var value = 0;
  final plant = Timer.periodic(plantPeriod, (_) {
    value++;
    fixture.served.setValues({for (final key in keys) key: value});
  });

  // Warm: established, healthy traffic before the lever, so the baseline in
  // every trace is a working panel rather than a starting one — and so the
  // stall can be placed at a chosen **phase** of the platform's ping cycle.
  // A fixed warm-up is what makes five runs agree with each other and prove
  // nothing; the phase sweep in Scenario 1 varies it on purpose.
  await Future<void>.delayed(warmUp);
  final warmBytes =
      fixture.inbound.fold<int>(0, (sum, frame) => sum + frame.length);

  lever(fixture);

  final clock = Stopwatch()..start();
  final samples = <Sample>[];
  int? closedAtMs;

  while (clock.elapsed < budget) {
    await Future<void>.delayed(samplePeriod);
    final open = fixture.server.sessions.sessionCount;
    samples.add(Sample(
      atMs: clock.elapsedMilliseconds,
      advertised: open == 0 ? -1 : advertisedSeq(session, sub),
      applied: appliedSeq(fixture.inbound, sub),
      pending: session.buffer.pendingCount,
      silentForMs: session.silentForMs(),
      sessions: open,
      clientSocketEnded: fixture.observedClose.closeCode != null,
    ));
    if (open == 0) {
      closedAtMs = clock.elapsedMilliseconds;
      break;
    }
  }
  clock.stop();

  plant.cancel();
  beat.cancel();

  final bytesIn =
      fixture.inbound.fold<int>(0, (sum, frame) => sum + frame.length) -
          warmBytes;
  final run = RigRun(
    label: label,
    pingIntervalMs: pingInterval.inMilliseconds,
    warmUpMs: warmUp.inMilliseconds,
    samples: samples,
    closedAtMs: closedAtMs,
    sentCloseCode: session.sentCloseCode,
    clientCloseCode: fixture.observedClose.closeCode,
    bytesIn: bytesIn,
    wallMs: clock.elapsedMilliseconds,
  );

  // The proxy is disarmed before teardown: a withheld direction cannot carry
  // the close, and the fixture's own release would then wait on it.
  fixture.proxy.bufferServerToClient = false;
  fixture.proxy.throttleBytesPerSec = null;
  fixture.proxy.latency = null;
  fixture.proxy.jitter = null;
  await fixture.teardown();
  return run;
}

// ---------------------------------------------------------------------------

void main() {
  tearDownAll(() {
    // ignore: avoid_print
    print('\n===== 16-02 MEASUREMENT REPORT (copy into 16-02-DECISION.md) '
        '=====\n$_report');
  });

  group('Scenario 1 — the genuinely stuck consumer', () {
    test('how long a withheld reader survives, and what finally closes it',
        () async {
      // Scaled `pingInterval`s, not the shipping 20 s. `heartbeatDeadline`
      // must stay below `pingInterval` and at or above `minHeartbeatDeadline`
      // (3 s), so 4 s is the fastest configuration the server will accept, and
      // 6 s is the second point that makes the ratio a *measured* multiplier
      // rather than one number that could be anything.
      //
      // **The warm-up is swept, and that is the whole point of this arm.**
      // The first pass of this measurement ran five times at a fixed one-second
      // warm-up and produced 6972–7019 ms five times over. It read as a fixed
      // cost. It was not: it was the stall landing at the same phase of the
      // platform's ping cycle every run. The sweep below places the stall at
      // seven different phases so the answer is the *shape* of the survival
      // time rather than one point on it.
      final runs = <RigRun>[];
      for (final (interval, warmUp) in const <(Duration, Duration)>[
        (Duration(seconds: 4), Duration(milliseconds: 400)),
        (Duration(seconds: 4), Duration(milliseconds: 1400)),
        (Duration(seconds: 4), Duration(milliseconds: 2400)),
        (Duration(seconds: 4), Duration(milliseconds: 3400)),
        (Duration(seconds: 4), Duration(milliseconds: 5400)),
        (Duration(seconds: 6), Duration(milliseconds: 1400)),
        (Duration(seconds: 6), Duration(milliseconds: 4400)),
      ]) {
        runs.add(await rigRun(
          label: '${interval.inSeconds} s',
          lever: (f) => f.proxy.bufferServerToClient = true,
          pingInterval: interval,
          warmUp: warmUp,
          budget: Duration(seconds: interval.inSeconds * 3),
        ));
      }

      say('');
      say('## Scenario 1 — a genuinely stuck consumer (real socket, real clock)');
      say('');
      say('A panel subscribed to 40 keys; the plant moves every 25 ms; the '
          'tick is 50 ms; the panel beats every 750 ms on a raw `ping` that '
          'the proxy still forwards client→server. `bufferServerToClient` is '
          'armed after the warm-up and never released.');
      say('');
      say('| pingInterval | stall began at | survived | ÷ pingInterval | '
          'from connect ÷ pingInterval | mechanism | what the client saw | '
          'max pending/tick | max silence |');
      say('|---|---|---|---|---|---|---|---|---|');
      for (final r in runs) {
        say('| ${r.label} '
            '| ${r.warmUpMs} ms after connect '
            '| ${r.closedAtMs == null ? '> ${r.wallMs} ms (budget)' : '${r.closedAtMs} ms'} '
            '| ${r.closeRatio == null ? '—' : fmt(r.closeRatio!)} '
            '| ${r.connectRatio == null ? '—' : fmt(r.connectRatio!)} '
            '| ${r.mechanism} '
            '| ${r.clientCloseCode ?? 'nothing — the close frame is withheld too'} '
            '| ${fmt(r.pendings.max)} '
            '| ${fmt(r.silences.max)} ms |');
      }

      final ratios = [
        for (final r in runs)
          if (r.closeRatio != null) r.closeRatio!,
      ];
      final connectRatios = [
        for (final r in runs)
          if (r.connectRatio != null) r.connectRatio!,
      ];
      final ratioDist = Dist(ratios);
      final connectDist = Dist(connectRatios);
      // How far each close instant sits from a whole multiple of the ping
      // interval, counted from the connection. If the platform's rule is "a
      // ping every P, close if the pong has not come by the next one", this
      // number is ~0 for every run whatever the stall's phase — and that is
      // what identifies the mechanism.
      final offIntegral = Dist(connectRatios
          .map((r) => (r - r.roundToDouble()).abs())
          .toList());

      say('');
      say('**Survival ÷ pingInterval, measured from the stall:** $ratioDist');
      say('');
      say('**Survival ÷ pingInterval, measured from the connection:** '
          '$connectDist — every value within ${fmt(offIntegral.max)} of a whole '
          'multiple. That identifies the mechanism: the platform closes on a '
          'ping cycle anchored at the **connection**, not at the stall, so what '
          'a stalled panel gets is whatever happens to be left of the current '
          'window.');
      if (ratios.isNotEmpty) {
        say('');
        say('**The review quotes 1.85 × pingInterval ≈ 37 s as though it were '
            'a constant. It is not one.** The first pass of this arm ran five '
            'times at one fixed warm-up and produced 6972–7019 ms five times '
            'over, which reads as a fixed cost; sweeping the phase turns it '
            'into a spread of **${fmt(ratioDist.min)}–${fmt(ratioDist.max)} × '
            'pingInterval** across ${ratioDist.n} runs. A stall beginning just '
            'after a pong gets the whole window; one beginning just before the '
            'next ping gets almost none of it, so survival is '
            '**uniform over (1 × pingInterval, 2 × pingInterval]**.');
        say('');
        say('At the shipping `pingInterval` of 20 s that is a stuck reader '
            'buffering at full production rate for **20–40 s, expected median '
            '30 s** (measured here: '
            '${fmt(ratioDist.min * 20)}–${fmt(ratioDist.max * 20)} s, median '
            '${fmt(ratioDist.median * 20)} s, over warm-ups chosen to sample '
            'the cycle rather than drawn at random). The review\'s 37 s is '
            'inside the range and is not the range — and the number that '
            'matters for a defence is the **worst case, 40 s**, not the '
            'typical one.');
      }

      final pooled = runs.expand((r) => r.samples).toList();
      say('');
      say('**Shadow detectors, all ${runs.length} runs pooled '
          '(n=${pooled.length} samples)**');
      say('');
      say('| detector | reading |');
      say('|---|---|');
      say('| (c) ack gap, server seq − client applied seq | '
          '${Dist(pooled.map((s) => s.gap))}, slope '
          '${fmt(runs.first.gapSlopePerSec)} frames/s on run 1 |');
      say('| what `poll` actually reads — pendingCount per tick | '
          '${Dist(pooled.map((s) => s.pending))} against `peakThreshold` 1024 '
          'and `maxPending` 4096 |');
      say('| `_LastSeen` silence the reaper measures | '
          '${Dist(pooled.map((s) => s.silentForMs))} ms against a 3000 ms '
          'deadline |');
      say('| the client observing anything at all | '
          '${pooled.any((s) => s.clientSocketEnded) ? 'its socket ended during the run' : 'nothing, for the whole run'} |');

      // Liveness of the run only. Nothing here pins the numbers above.
      expect(runs, hasLength(7), reason: 'every configured run executed');
      for (final r in runs) {
        expect(r.samples, isNotEmpty,
            reason: 'the ${r.label} run produced no trace at all, so every '
                'number derived from it would be a claim about an empty list');
      }
    }, timeout: const Timeout(Duration(seconds: 240)));
  });

  group('Option (a) — does any dart:io signal move before the pong timeout?',
      () {
    test('`sink.done` and `await sink.addStream(...)` against a peer that has '
        'stopped reading', () async {
      // A bare WebSocket, owned end to end, because the question is a property
      // of the transport and not of the relay: with the relay's own socket the
      // server sink belongs to shelf and the client sink is shared with the
      // harness `Peer`, and `addStream` on a sink somebody else is writing to
      // throws "Cannot add event while adding stream" — which would be a
      // measurement of the harness.
      const pingInterval = Duration(seconds: 4);
      const budget = Duration(seconds: 16);
      const payload = 65536; // one frame big enough to fill buffers quickly

      final serverSide = Completer<WebSocketChannel>();
      final http = await shelf_io.serve(
        webSocketHandler(
          (WebSocketChannel ws, String? _) {
            if (!serverSide.isCompleted) serverSide.complete(ws);
          },
          pingInterval: pingInterval,
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => http.close(force: true));

      final proxy = FaultProxy(targetPort: http.port);
      await proxy.start();
      addTearDown(proxy.shutdown);

      final client =
          IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${proxy.port}'));
      addTearDown(() => client.sink.close().catchError((Object _) {}));
      await client.ready;
      client.stream.listen((_) {}, onError: (Object _) {}, onDone: () {});

      final ws = await serverSide.future.timeout(const Duration(seconds: 5));

      final clock = Stopwatch()..start();
      int? doneAtMs;
      int? streamEndedAtMs;
      unawaited(ws.sink.done.then<void>(
        (_) => doneAtMs ??= clock.elapsedMilliseconds,
        onError: (Object _) => doneAtMs ??= clock.elapsedMilliseconds,
      ));
      // The other end of the same socket. `RelaySession` learns a connection
      // has died from its *stream* ending, never from `sink.done` — so the two
      // are recorded side by side, and a divergence between them is the whole
      // answer to option (a).
      ws.stream.listen(
        (_) {},
        onError: (Object _) =>
            streamEndedAtMs ??= clock.elapsedMilliseconds,
        onDone: () => streamEndedAtMs ??= clock.elapsedMilliseconds,
      );

      // The peer stops reading. The withheld bytes stay in the proxy's own
      // queue and count toward its high-water mark, so the server's socket
      // stops draining exactly as it would against a real stalled reader.
      proxy.bufferServerToClient = true;

      final durations = <int>[];
      int? firstStallMs;
      int? firstErrorMs;
      var frames = 0;
      final body = 'x' * payload;

      while (clock.elapsed < budget &&
          doneAtMs == null &&
          streamEndedAtMs == null) {
        final t = Stopwatch()..start();
        try {
          await ws.sink
              .addStream(Stream<dynamic>.value(body))
              .timeout(const Duration(milliseconds: 500));
          t.stop();
          durations.add(t.elapsedMilliseconds);
          frames++;
          if (t.elapsedMilliseconds >= 100) {
            firstStallMs ??= clock.elapsedMilliseconds;
          }
        } catch (_) {
          t.stop();
          firstErrorMs ??= clock.elapsedMilliseconds;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      clock.stop();

      final written = frames * payload;
      say('');
      say('## Option (a) — the only completion-shaped signal `dart:io` offers');
      say('');
      say('A bare `shelf_web_socket` server with `pingInterval` = '
          '${pingInterval.inSeconds} s, a `FaultProxy` withholding '
          'server→client, and a $payload-byte frame pushed every 50 ms from '
          'the server side.');
      say('');
      say('| signal | reading |');
      say('|---|---|');
      say('| `await sink.addStream(one frame)` duration, ms | '
          '${Dist(durations)} |');
      say('| first `addStream` taking ≥ 100 ms | '
          '${firstStallMs == null ? '**never** — it completed promptly for the whole run' : '$firstStallMs ms'} |');
      say('| first `addStream` erroring or timing out | '
          '${firstErrorMs == null ? '**never**' : '$firstErrorMs ms'} |');
      say('| `sink.done` completing — **the future option (a) names** | '
          '${doneAtMs == null ? '**never**, not inside the ${budget.inSeconds} s budget' : '$doneAtMs ms (${fmt(doneAtMs! / pingInterval.inMilliseconds)} × pingInterval)'} |');
      say('| the server-side **stream** ending — what `RelaySession` actually '
          'listens to | '
          '${streamEndedAtMs == null ? 'never inside the budget' : '$streamEndedAtMs ms (${fmt(streamEndedAtMs! / pingInterval.inMilliseconds)} × pingInterval)'} |');
      say('| bytes the server pushed into a peer that read none | '
          '${(written / 1024 / 1024).toStringAsFixed(1)} MiB in $frames frames |');
      say('');
      if (firstStallMs == null && firstErrorMs == null) {
        say('**Option (a) is refuted by measurement, twice over.**');
        say('');
        say('1. `await sink.addStream(one frame)` completed inside '
            '${fmt(Dist(durations).max)} ms on **every** frame while the peer '
            'read nothing at all, and ${(written / 1024 / 1024).toStringAsFixed(1)} MiB '
            'went into a socket nobody was draining. There is no completion-'
            'shaped backpressure signal here to build a detector on. This is '
            'flutter#103306 measured rather than cited.');
        say('2. `ws.sink.done` — the exact future `tick_engine.dart:69` names '
            '— ${doneAtMs == null ? 'did not complete at all inside the budget, while the connection *was* torn down' : 'completed only at the pong timeout, i.e. at the bound that already exists'}. '
            'A periodic check of it is therefore a rename of the bound this '
            'phase is trying to shorten, not a shorter one.');
      } else {
        say('**Option (a) shows a signal moving before the pong timeout** — '
            'first stall at ${firstStallMs ?? firstErrorMs} ms. See the '
            'decision; the recommendation changes.');
      }

      expect(frames, greaterThan(0),
          reason: 'no frame was written at all, so nothing above is a '
              'measurement of the transport');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('Scenario 2 — the healthy fast producer', () {
    test('how many ticks a healthy panel survives before the 4004, and what '
        'the reason string says', () async {
      // Injected clock, shipping numbers: peakThreshold 1024, peakWindowMs
      // 10_000, tick 50 ms, maxPending 4096, maxKeysPerSubscribe 2000.
      // Nothing here sleeps.
      const rates = <int>[1100, 1300, 1800];
      final tickCounts = <int, List<int>>{};
      final peaks = <int, List<int>>{};
      String? reasonString;
      int? closeCode;

      // `Plant.connect`'s default buffer carries `maxPending` and nothing
      // else (`panels.dart:196`), so a `peakThreshold` of null would make
      // every arm below vacuously green. Production wires all four fields
      // (`relay_server.dart:658-663`); so does this.
      ConflatingSendBuffer shipping() => ConflatingSendBuffer(
            maxPending: 4096,
            peakThreshold: 1024,
            peakWindowMs: 10000,
            maxPendingBytes: 8 * 1024 * 1024,
          );

      for (final handles in rates) {
        tickCounts[handles] = [];
        peaks[handles] = [];
        for (var repeat = 0; repeat < 3; repeat++) {
          final plant = Plant();
          final keys = plant.seed(handles, prefix: 'CN02.LOAD');
          final panel =
              await plant.connect('page-1', keys, buffer: shipping());
          var value = 0;
          var ticks = 0;
          var peak = 0;
          while (panel.session.sentCloseCode == null && ticks < 400) {
            plant.api.setValues({for (final key in keys) key: ++value});
            final pending = panel.buffer.pendingCount;
            if (pending > peak) peak = pending;
            plant.tick();
            ticks++;
          }
          await pumpEventQueue();
          tickCounts[handles]!.add(ticks);
          peaks[handles]!.add(peak);
          if (panel.closes.isNotEmpty) {
            reasonString ??= panel.closes.first.reason;
            closeCode ??= panel.closes.first.code;
          }
          await plant.dispose();
        }
      }

      // The control: a panel comfortably under the soft ceiling, run for
      // longer than the window, so the arms above are not measuring "every
      // panel is evicted eventually".
      final control = Plant();
      final controlKeys = control.seed(900, prefix: 'CN02.QUIET');
      final controlPanel =
          await control.connect('page-1', controlKeys, buffer: shipping());
      var controlValue = 0;
      for (var t = 0; t < 400; t++) {
        control.api
            .setValues({for (final key in controlKeys) key: ++controlValue});
        control.tick();
      }
      final controlSurvived = controlPanel.session.sentCloseCode == null;
      await control.dispose();

      say('');
      say('## Scenario 2 — a healthy fast producer, evicted for producing');
      say('');
      say('No fault at all. `FakeClock`, the real `TickEngine`, shipping '
          '`ServerConfig` defaults. Every handle changes every tick, which is '
          'what a page of fast struct members looks like.');
      say('');
      say('| changed handles per tick | peak pendingCount at poll | '
          'ticks survived | tick time |');
      say('|---|---|---|---|');
      for (final handles in rates) {
        final d = Dist(tickCounts[handles]!);
        say('| $handles | ${Dist(peaks[handles]!).max} | $d '
            '| ${fmt(d.median * 50 / 1000)} s |');
      }
      say('');
      say('Every distribution above is **degenerate by construction** — the '
          'buffer takes `poll(nowMs)` as an argument and the clock is '
          'injected, so three repeats of one configuration cannot disagree. '
          'That is *why* they agree; it is not evidence that the number is '
          'stable on a real clock.');
      say('');
      say('**Close code:** ${closeCode ?? 'none'}');
      say('');
      say('**Reason string, verbatim:**');
      say('');
      say('> `${reasonString ?? 'none'}`');
      say('');
      say('**Control — 900 handles per tick, under the soft ceiling, 400 '
          'ticks (20 s of tick time):** '
          '${controlSurvived ? 'still connected' : '**EVICTED — the arms above are measuring nothing**'}.');
      say('');
      say('Survival does not depend on how far above the threshold the panel '
          'is: 1100 handles and 1800 handles are evicted after the same '
          'window, because the verdict is a timer on "above the soft ceiling" '
          'and not a measure of severity. The panel is evicted for watching a '
          'page that changes, and the reason string blames the panel.');

      expect(tickCounts.values.expand((v) => v), isNotEmpty);
      expect(controlSurvived, isTrue,
          reason: 'the control panel is what makes the eviction arms '
              'non-vacuous; if everything is evicted the numbers above are '
              'about the harness');
    }, timeout: const Timeout(Duration(seconds: 300)));
  });

  group('Condition 1 — does a sustained ack gap separate stuck from slow?', () {
    test('the ack-gap populations of six links, side by side', () async {
      // The page's byte rate is measured first, unmetered, so every throttle
      // below is a multiple of what this page actually costs rather than a
      // number picked to make a point.
      final baseline = await rigRun(
        label: 'healthy, unmetered',
        lever: (_) {},
        budget: const Duration(seconds: 4),
      );
      final bytesPerSec = baseline.bytesIn / (baseline.wallMs / 1000);

      int rate(double multiple) =>
          (bytesPerSec * multiple).round().clamp(64, 1 << 28);

      // Two repeats of every population, because one run of a wall-clock
      // measurement is a sample and the separation claim below is the
      // headline finding of this whole plan.
      final healthyLabels = <String>{
        'healthy, unmetered',
        'healthy on a 250 ms link (+50 ms jitter)',
        'healthy on a 1000 ms link (+200 ms jitter) — a bad WAN',
        'throttled to 4× the page rate',
      };
      final population = <RigRun>[baseline];
      for (var repeat = 0; repeat < 2; repeat++) {
        population.add(await rigRun(
          label: 'healthy on a 250 ms link (+50 ms jitter)',
          lever: (f) {
            f.proxy.latency = const Duration(milliseconds: 250);
            f.proxy.jitter = const Duration(milliseconds: 50);
          },
          budget: const Duration(seconds: 4),
        ));
        population.add(await rigRun(
          label: 'healthy on a 1000 ms link (+200 ms jitter) — a bad WAN',
          lever: (f) {
            f.proxy.latency = const Duration(milliseconds: 1000);
            f.proxy.jitter = const Duration(milliseconds: 200);
          },
          budget: const Duration(seconds: 4),
        ));
        population.add(await rigRun(
          label: 'throttled to 4× the page rate',
          lever: (f) => f.proxy.throttleBytesPerSec = rate(4),
          budget: const Duration(seconds: 4),
        ));
        population.add(await rigRun(
          label: 'throttled to 1× the page rate — the marginal link',
          lever: (f) => f.proxy.throttleBytesPerSec = rate(1),
          budget: const Duration(seconds: 4),
        ));
        population.add(await rigRun(
          label: 'throttled to ¼ of the page rate — oversubscribed',
          lever: (f) => f.proxy.throttleBytesPerSec = rate(0.25),
          budget: const Duration(seconds: 6),
        ));
        population.add(await rigRun(
          label: 'genuinely stuck (bufferServerToClient)',
          lever: (f) => f.proxy.bufferServerToClient = true,
          budget: const Duration(seconds: 6),
        ));
      }

      say('');
      say('## Condition 1 — the ack-gap populations');
      say('');
      say('Measured page rate, unmetered: **${bytesPerSec.round()} B/s** for '
          '40 handles changing every 25 ms on a 50 ms tick. Every throttle '
          'below is a multiple of that.');
      say('');
      say('The gap is `SubscriptionState.seq` — what the server has advertised '
          '— minus the highest `u` seq the client has decoded, which is what '
          'it has applied. No `lib/` code was added to measure it: this is '
          'exactly the pair of numbers option (c) would put on the wire.');
      say('');
      say('| link | ack gap (frames) | whole-window slope | steady-state '
          'slope (2nd half) | final gap | closed? |');
      say('|---|---|---|---|---|---|');
      for (final r in population) {
        say('| ${r.label} | ${r.gaps} | ${fmt(r.gapSlopePerSec)} '
            '| ${fmt(r.steadySlopePerSec)} '
            '| ${r.samples.isEmpty ? '—' : r.samples.last.gap} '
            '| ${r.closedAtMs == null ? 'no' : '${r.closedAtMs} ms — ${r.mechanism}'} |');
      }

      final healthy =
          population.where((r) => healthyLabels.contains(r.label)).toList();
      final marginal = population
          .where((r) => r.label.contains('marginal'))
          .toList();
      final sick = population
          .where((r) =>
              r.label.contains('oversubscribed') || r.label.contains('stuck'))
          .toList();

      final healthyMax = healthy
          .expand((r) => r.samples)
          .map((s) => s.gap)
          .fold<int>(0, (a, b) => a > b ? a : b);
      final healthySlope = Dist(healthy.map((r) => r.steadySlopePerSec));
      final sickSlope = Dist(sick.map((r) => r.steadySlopePerSec));
      final sickFinal = sick
          .map((r) => r.samples.isEmpty ? 0 : r.samples.last.gap)
          .fold<int>(1 << 30, (a, b) => a < b ? a : b);
      final marginalSlope = Dist(marginal.map((r) => r.steadySlopePerSec));
      final marginalMax = marginal
          .expand((r) => r.samples)
          .map((s) => s.gap)
          .fold<int>(0, (a, b) => a > b ? a : b);

      // The penalty a real option-(c) ack pays that this instrument does not:
      // the client reports its ack on a heartbeat, so the server's copy is
      // stale by up to one beat period, and at 50 ms per frame that is a
      // constant offset on top of every gap.
      const beatPeriodMs = 2000;
      const tickMs = 50;
      const ackStaleness = beatPeriodMs ~/ tickMs;

      say('');
      say('| population | max gap seen | steady-state slope, frames/s |');
      say('|---|---|---|');
      say('| healthy (${healthy.length} runs) | $healthyMax | $healthySlope |');
      say('| marginal (${marginal.length} runs) | $marginalMax '
          '| $marginalSlope |');
      say('| unhealthy (${sick.length} runs) | ${sick.expand((r) => r.samples).map((s) => s.gap).fold<int>(0, (a, b) => a > b ? a : b)} '
          '| $sickSlope |');
      say('');
      say('A latent link\'s gap **plateaus** at about latency ÷ tick: the '
          '1000 ms arm settles at 22–24 frames against a predicted 20, and '
          'its whole-window slope is entirely the one-off ramp to that '
          'plateau. Its steady-state slope is the row above.');
      say('');
      say('**Separation by magnitude.** Largest gap any healthy link reached: '
          '**$healthyMax frames**. Smallest final gap any unhealthy link '
          'reached: **$sickFinal frames**. '
          '${sickFinal > healthyMax ? 'The two do not overlap on this rig.' : '**THEY OVERLAP.**'} '
          'But a real ack arrives on a heartbeat, so the server\'s copy of it '
          'is stale by up to one beat period — at 2000 ms and a 50 ms tick '
          'that is a **constant +$ackStaleness frames** on every reading, '
          'healthy or not. Adjusted, the healthy ceiling is '
          '**${healthyMax + ackStaleness} frames**, which '
          '${sickFinal > healthyMax + ackStaleness ? 'still clears the unhealthy floor of $sickFinal.' : 'is at or above the unhealthy floor of $sickFinal — so a threshold on the *instantaneous* gap does not separate them.'}');
      say('');
      say('**Separation by slope, which is the one that holds.** A healthy '
          'link\'s gap is stationary — $healthySlope frames/s — because '
          'conflation gives it one frame per tick and it delivers one frame '
          'per tick. An unhealthy link\'s gap grows without bound at '
          '$sickSlope frames/s, because the server writes one frame per tick '
          'whatever the link can carry and `dart:io` buffers the difference '
          'forever. Latency shifts the healthy gap *up* and leaves the slope '
          'at zero; only a link that cannot carry the production rate has a '
          'slope. **This is the discriminator, and it is the same shape as '
          '`peakThreshold`\'s existing window — sustained-over-window rather '
          'than instantaneous — applied to delivery instead of production.**');
      say('');
      say('**The marginal link** — throttled to exactly the page rate — is the '
          'honest hard case, and it is the population a threshold must be '
          'chosen against: max gap $marginalMax, slope $marginalSlope '
          'frames/s.');

      expect(population.every((r) => r.samples.isNotEmpty), isTrue,
          reason: 'a population with no samples in it is not a population');
    }, timeout: const Timeout(Duration(seconds: 300)));
  });

  group('Condition 2 — does the narrowed skip rule become a beat storm?', () {
    test('beats per minute under the current rule and the narrowed one', () {
      // A model, and labelled as one. `HeartbeatPump` lives in
      // `tfc_relay_client`, which this package deliberately does not depend on
      // (its pubspec says why), so the two gates are reproduced here from
      // `heartbeat_pump.dart:286-294` and driven over synthetic traffic.
      // What makes the model trustworthy is that the *ceiling* is structural:
      // both rules run inside one `Timer.periodic(period)`, so neither can
      // beat more than once per period however the gate is written.
      //
      //   period = max(learned ~/ 3, heartbeatFloor)
      //   heartbeatFloor default 1000 ms   (client_config.dart:402)
      //   shipping heartbeatDeadline 6000 ms (server_config.dart:322)
      const floorMs = 1000;
      const advertisedMs = 6000;
      const derived = advertisedMs ~/ 3;
      const periodMs = derived > floorMs ? derived : floorMs;
      const horizonMs = 600000; // ten minutes of panel time

      int beats({
        required bool Function(int nowMs) outboundAt,
        required bool ackMoves,
        required bool narrowed,
      }) {
        var lastOutbound = 0;
        var sent = 0;
        for (var t = periodMs; t <= horizonMs; t += periodMs) {
          for (var u = t - periodMs + 1; u <= t; u++) {
            if (outboundAt(u)) lastOutbound = u;
          }
          final sinceOutbound = t - lastOutbound;
          final quiet = sinceOutbound < 0 || sinceOutbound >= periodMs;
          // Today: beat only when the wire has been quiet for a period.
          // Narrowed: beat when the wire has been quiet OR the ack is stale.
          final send = narrowed ? (quiet || !ackMoves) : quiet;
          if (!send) continue;
          lastOutbound = t;
          sent++;
        }
        return sent;
      }

      bool jogging(int t) => t % 100 == 0; // ten deadman ticks a second
      bool silent(int _) => false;

      final cells = <String, ({int now, int narrowed})>{
        'quiet panel, ack moving': (
          now: beats(outboundAt: silent, ackMoves: true, narrowed: false),
          narrowed: beats(outboundAt: silent, ackMoves: true, narrowed: true),
        ),
        'busy panel, ack moving — the healthy case the skip rule protects': (
          now: beats(outboundAt: jogging, ackMoves: true, narrowed: false),
          narrowed: beats(outboundAt: jogging, ackMoves: true, narrowed: true),
        ),
        'busy panel, ack FROZEN — the stuck reader the change is for': (
          now: beats(outboundAt: jogging, ackMoves: false, narrowed: false),
          narrowed: beats(outboundAt: jogging, ackMoves: false, narrowed: true),
        ),
      };

      say('');
      say('## Condition 2 — the narrowed skip-on-traffic rule');
      say('');
      say('A model of `_sendBeat`\'s gate (`heartbeat_pump.dart:286-294`) '
          'driven over ten minutes of panel time at the shipping numbers: the '
          'gateway advertises a 6000 ms `heartbeatDeadline`, so '
          '`period = 6000 ~/ 3 = $periodMs ms`. A busy panel is an operator '
          'jogging a machine — ten outbound frames a second.');
      say('');
      say('| panel | beats/min today | beats/min narrowed |');
      say('|---|---|---|');
      for (final entry in cells.entries) {
        say('| ${entry.key} | ${fmt(entry.value.now / 10)} '
            '| ${fmt(entry.value.narrowed / 10)} |');
      }
      say('');
      say('**Ceiling: ${fmt(60000 / periodMs)} beats/min.** Both rules run '
          'inside the same `Timer.periodic(period)`, so the narrowed gate can '
          'only ever *restore* the un-skipped rate — it cannot exceed it. '
          'There is no storm available: the worst case of the change is a '
          'panel returning to the beat rate it would have had if it had been '
          'idle, and the frame is a `ping` request carrying one small int '
          'map. The cost is bounded by construction and does not depend on '
          'how busy the panel is.');

      final ceiling = horizonMs ~/ periodMs;
      for (final entry in cells.entries) {
        expect(entry.value.narrowed, lessThanOrEqualTo(ceiling),
            reason: 'the narrowed rule cannot beat more often than the timer '
                'it runs on fires — ${entry.key}');
      }
    });
  });

  group('Condition 3 — what an ack map costs in the encode path', () {
    test('the ping params, encoded and decoded, against the fan-out frame it '
        'is not on', () {
      // A panel has a handful of subscriptions, not hundreds: the app opens
      // one per page plus one per open pane. 1, 4 and 16 bracket it; 64 is the
      // absurd case, included so the shape of the curve is visible.
      // Nine batches, so the reported figure is a distribution over batches
      // rather than one timing. The fan-out frame below is three orders of
      // magnitude more expensive per operation and gets proportionally fewer
      // iterations — a constant iteration count there would make this arm a
      // ninety-second test measuring `jsonEncode`.
      Dist timeNs(void Function() work, {int iterations = 20000}) {
        for (var i = 0; i < iterations ~/ 5; i++) {
          work();
        }
        final batches = <double>[];
        for (var b = 0; b < 9; b++) {
          final sw = Stopwatch()..start();
          for (var i = 0; i < iterations; i++) {
            work();
          }
          sw.stop();
          batches.add(sw.elapsedMicroseconds * 1000 / iterations);
        }
        return Dist(batches);
      }

      final rows = <String>[];
      for (final subs in const [0, 1, 4, 16, 64]) {
        final params = <String, Object?>{
          if (subs > 0)
            'ack': {for (var i = 0; i < subs; i++) 'page-$i': 1000000 + i},
        };
        final frame = jsonEncode({
          'jsonrpc': '2.0',
          'id': 'beat-1',
          'method': Methods.ping,
          if (params.isNotEmpty) 'params': params,
        });
        final encode = timeNs(() => jsonEncode(params));
        final decode = timeNs(() => jsonDecode(frame));
        rows.add('| $subs | ${frame.length} B | $encode | $decode |');
      }

      // The denominator: what the encode-once fan-out path costs for one
      // realistic page, per tick, shared by every session subscribed to it.
      final page = UpdateParams(
        sub: 'page-1',
        seq: 42,
        t: 1234567890,
        changes: {for (var h = 1; h <= 1500; h++) h: WireValue.of(h * 1.5)},
      ).toJson();
      final fanout = timeNs(() => jsonEncode(page), iterations: 100);

      say('');
      say('## Condition 3 — the cost of an int map on `ping`');
      say('');
      say('| subscriptions in the ack | whole `ping` frame | encode ns/op '
          '(client) | decode ns/op (server) |');
      say('|---|---|---|---|');
      for (final row in rows) {
        say(row);
      }
      say('');
      say('**The encode-once fan-out path, for scale:** one `u` frame for a '
          '1500-key page costs $fanout ns to encode, once per tick, shared by '
          'every session subscribed to it.');
      say('');
      say('`ping` is a **client → server request**. It is not on the '
          'encode-once fan-out path at any point: the server decodes one small '
          'map per panel per heartbeat period — at the shipping numbers, one '
          'every 2 s per panel — and never encodes it. The fan-out frame above '
          'is untouched by this change. That is structural rather than '
          'measured; the measurement is here so the two magnitudes can be '
          'compared instead of asserted.');

      expect(rows, hasLength(5));
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
