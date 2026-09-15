/// A slow OPC UA server must not stall another server's data collection.
///
/// ## What "slow" means here, mechanically
///
/// `Client.runIterate(t)` is a blocking FFI call whose argument is how long
/// open62541's `select()` may *wait* — not a work budget (open62541_dart
/// PR #116 pinned this from `eventloop_posix.c:326`). Against a healthy
/// server the socket has traffic and the call returns quickly; against a
/// silent one it blocks the full timeout, on whatever isolate made the call.
/// So the slow-server stub is a [FaultProxy] blackhole: the server stays
/// healthy, the wire goes quiet, and the client's `runIterate` becomes a
/// genuine `select()` sleep — the exact production failure, without a
/// deliberately wedged server (which would stub a *different* fault: a slow
/// server still produces TCP bytes; a blackhole is the worst case where the
/// client has nothing to read at all).
///
/// ## Topology
///
/// Three isolates, each with one job:
///
///  * **main** — the asserter. Also hosts both server fixtures and the
///    proxy: their 10 ms crank never competes with the isolate under
///    measurement, and the blackhole lever stays reachable even when the
///    collection isolate is wedged (which the hazard arm makes it).
///  * **collection** (spawned) — two [OpcUaUpstreamLink]s and the probes.
///    The fast link always runs `useIsolate: false`, so its sample stream
///    doubles as an in-isolate cadence sensor; a 5 ms metronome measures the
///    isolate's own event-loop health, PR #116's instrument.
///  * **the slow link's client isolate** — only in the production arm
///    (`useIsolate: true`), spawned by the link itself. Its blocking is the
///    thing being confined.
///
/// ## The two arms disagree, which is what makes either mean anything
///
/// The production arm (slow link isolated) asserts the fast link's cadence
/// and the metronome survive the blackhole. The hazard arm (slow link
/// sharing the collection isolate, iterate timeout widened to 300 ms)
/// asserts the same probes *collapse* — proving both that `runIterate`
/// really blocks and that the instrument can tell. A two-term predicate
/// needs the terms to disagree, or the case is decoration.
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:isolate';

import 'package:async/async.dart' show StreamQueue;
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:test/test.dart';

import 'support/opcua_server_fixture.dart';

/// Server-side publishing: the fixture's value pump writes this often.
const Duration valuePumpPeriod = Duration(milliseconds: 50);

/// The collection isolate's event-loop metronome.
const Duration metronomePeriod = Duration(milliseconds: 5);

/// How long each measured window runs.
const Duration window = Duration(seconds: 5);

/// The hazard arm's iterate timeout — long enough that one blocked call is
/// unmistakable against a 5 ms metronome, short enough to keep the arm quick.
const Duration hazardIterate = Duration(milliseconds: 300);

KeyMappingEntry _entryFor(String key, String alias) {
  final node = OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
    ..serverAlias = alias;
  return KeyMappingEntry()..opcuaNode = node;
}

/// One measured window, as the collection isolate reports it.
final class WindowStats {
  final int samples;
  final int maxGapMs;
  final int metronomeTicks;
  final int windowMs;
  WindowStats(this.samples, this.maxGapMs, this.metronomeTicks, this.windowMs);

  factory WindowStats.fromList(List<Object?> raw) => WindowStats(
      raw[0]! as int, raw[1]! as int, raw[2]! as int, raw[3]! as int);

  int get expectedMetronomeTicks =>
      windowMs ~/ metronomePeriod.inMilliseconds;

  @override
  String toString() => 'WindowStats(samples: $samples, maxGap: ${maxGapMs}ms, '
      'metronome: $metronomeTicks/$expectedMetronomeTicks over ${windowMs}ms)';
}

/// What main sends the collection isolate to stand itself up.
final class _CollectorConfig {
  final SendPort toMain;
  final String fastEndpoint;
  final String slowEndpoint;
  final String fastKey;
  final String slowKey;
  final bool slowUseIsolate;
  final int slowIterateMs;
  _CollectorConfig(this.toMain, this.fastEndpoint, this.slowEndpoint,
      this.fastKey, this.slowKey,
      {required this.slowUseIsolate, required this.slowIterateMs});
}

/// The collection isolate. Builds both links, connects, subscribes, then
/// answers `mark` commands with the stats of the window since the last mark.
Future<void> _collectorMain(_CollectorConfig config) async {
  final commands = ReceivePort();
  config.toMain.send(commands.sendPort);

  final fast = OpcUaUpstreamLink(
    alias: 'FAST',
    endpoint: config.fastEndpoint,
    // The cadence sensor: in-isolate on purpose, so a wedged event loop
    // shows up as sample gaps here.
    useIsolate: false,
  );
  final slow = OpcUaUpstreamLink(
    alias: 'SLOW',
    endpoint: config.slowEndpoint,
    useIsolate: config.slowUseIsolate,
    iteratePeriod: Duration(milliseconds: config.slowIterateMs),
  );

  await fast.connect(deadline: const Duration(seconds: 20));
  await slow.connect(deadline: const Duration(seconds: 20));

  final watch = Stopwatch()..start();
  // 'ready' is sent only after both subscriptions below are live — see the
  // end of setup. Marks arriving before it would measure a zero-width
  // window of nothing.

  // Probe 1: the fast link's sample stream.
  var samples = 0;
  var maxGapMs = 0;
  var lastSampleMs = -1;
  final fastRef =
      fast.resolve(config.fastKey, _entryFor(config.fastKey, 'FAST'))!;
  final fastSub = fast.subscribe(fastRef).listen((_) {
    final now = watch.elapsedMilliseconds;
    if (lastSampleMs >= 0 && now - lastSampleMs > maxGapMs) {
      maxGapMs = now - lastSampleMs;
    }
    lastSampleMs = now;
    samples++;
  });

  // The slow link must hold a live upstream subscription too — an idle
  // client's runIterate is cheap in any design; a subscribed one is the
  // realistic load.
  final slowRef =
      slow.resolve(config.slowKey, _entryFor(config.slowKey, 'SLOW'))!;
  final slowSub = slow.subscribe(slowRef).listen((_) {});

  // Probe 2: the isolate's own event loop.
  var metronomeTicks = 0;
  final metronome = Timer.periodic(metronomePeriod, (_) => metronomeTicks++);

  var windowStartMs = watch.elapsedMilliseconds;
  var windowSamples = 0;
  var windowTicks = 0;
  config.toMain.send('ready');

  commands.listen((message) async {
    switch (message as String) {
      case 'mark':
        final now = watch.elapsedMilliseconds;
        config.toMain.send([
          samples - windowSamples,
          maxGapMs,
          metronomeTicks - windowTicks,
          now - windowStartMs,
        ]);
        windowStartMs = now;
        windowSamples = samples;
        windowTicks = metronomeTicks;
        maxGapMs = 0;
        // A gap that spans a mark belongs to the window it ends in.
        lastSampleMs = now;
      case 'stop':
        metronome.cancel();
        await fastSub.cancel();
        await slowSub.cancel();
        await fast.dispose();
        await slow.dispose();
        commands.close();
        config.toMain.send('stopped');
    }
  });
}

final class _Rig {
  final OpcUaServerFixture fastServer;
  final OpcUaServerFixture slowServer;
  final Timer pump;
  final Isolate isolate;
  final ReceivePort fromCollector;
  final StreamQueue<Object?> events;
  final SendPort toCollector;
  _Rig(this.fastServer, this.slowServer, this.pump, this.isolate,
      this.fromCollector, this.events, this.toCollector);

  Future<WindowStats> mark() async {
    toCollector.send('mark');
    return WindowStats.fromList(await events.next as List<Object?>);
  }

  Future<void> dispose() async {
    toCollector.send('stop');
    // The hazard arm's collector is wedged by design; give it a moment, then
    // kill rather than hang teardown on the very defect the arm proves.
    await events.next.timeout(const Duration(seconds: 15), onTimeout: () {
      isolate.kill(priority: Isolate.immediate);
      return 'killed';
    });
    fromCollector.close();
    pump.cancel();
    await fastServer.dispose();
    await slowServer.dispose();
  }
}

Future<_Rig> _standUp({
  required bool slowUseIsolate,
  required Duration slowIterate,
}) async {
  const fastKey = 'fast.counter';
  const slowKey = 'slow.counter';

  final fastServer = await OpcUaServerFixture.start(valueKeys: [fastKey]);
  final slowServer =
      await OpcUaServerFixture.start(valueKeys: [slowKey], viaFaultProxy: true);

  var tick = 0;
  final pump = Timer.periodic(valuePumpPeriod, (_) {
    tick++;
    fastServer.setValue(fastKey, tick);
    slowServer.setValue(slowKey, tick);
  });

  final fromCollector = ReceivePort();
  final events = StreamQueue<Object?>(fromCollector);
  final isolate = await Isolate.spawn(
    _collectorMain,
    _CollectorConfig(
      fromCollector.sendPort,
      fastServer.endpoint,
      slowServer.endpoint,
      fastKey,
      slowKey,
      slowUseIsolate: slowUseIsolate,
      slowIterateMs: slowIterate.inMilliseconds,
    ),
  );
  final toCollector = await events.next as SendPort;
  final ready = await events.next;
  if (ready != 'ready') {
    throw StateError('collector sent $ready where ready was expected');
  }
  return _Rig(fastServer, slowServer, pump, isolate, fromCollector, events,
      toCollector);
}

void main() {
  test(
      'an isolated slow upstream leaves the other server\'s collection '
      'cadence intact', () async {
    final rig = await _standUp(
      slowUseIsolate: true,
      // The production figure: blocking confined to the client isolate.
      slowIterate: const Duration(milliseconds: 10),
    );
    addTearDown(rig.dispose);

    // Warm up until the fast stream is demonstrably live.
    await Future<void>.delayed(const Duration(seconds: 3));
    final baseline = await rig.mark();
    expect(baseline.samples, greaterThan(10),
        reason: 'no baseline stream, nothing below means anything: $baseline');

    rig.slowServer.proxy!.blackhole();
    await Future<void>.delayed(window);
    final fault = await rig.mark();

    expect(fault.samples, greaterThan(10),
        reason: 'the fast server kept publishing all through the blackhole; '
            'silence here is the slow link\'s blocking escaping its isolate: '
            '$fault');
    expect(fault.maxGapMs, lessThan(1000),
        reason: 'one 50 ms publisher should never gap a second unless the '
            'collection isolate stalled: $fault');
    // Against the BASELINE, not the ideal: the fast link's own in-isolate
    // 10 ms polling already costs most of the loop (measured ~36% of ideal
    // ticks while perfectly healthy), so the ideal is the wrong yardstick.
    // What the blackhole must not do is make it *worse*.
    final baselineRate = baseline.metronomeTicks / baseline.windowMs;
    final faultRate = fault.metronomeTicks / fault.windowMs;
    expect(faultRate, greaterThan(baselineRate * 0.5),
        reason: 'the collection isolate\'s event loop got more than twice as '
            'slow when the OTHER server went dark — blocking is escaping the '
            'slow client\'s isolate. baseline $baseline, fault: $fault');
  });

  test(
      'the hazard is real: the same slow upstream sharing the collection '
      'isolate wedges it', () async {
    final rig = await _standUp(
      slowUseIsolate: false,
      slowIterate: hazardIterate,
    );
    addTearDown(rig.dispose);

    await Future<void>.delayed(const Duration(seconds: 3));
    final baseline = await rig.mark();
    expect(baseline.samples, greaterThan(10),
        reason: 'both links healthy, in-isolate polling included — the '
            'hazard needs a working baseline to be a hazard: $baseline');

    rig.slowServer.proxy!.blackhole();
    await Future<void>.delayed(window);
    final fault = await rig.mark();

    // The blocked select() starves the whole isolate: every runIterate call
    // sleeps its full 300 ms timeout back-to-back. If this arm ever goes
    // green-shaped (no degradation), the production arm's pass is vacuous —
    // the probes stopped being able to see blocking at all.
    final baselineRate = baseline.metronomeTicks / baseline.windowMs;
    final faultRate = fault.metronomeTicks / fault.windowMs;
    final starved = faultRate < baselineRate * 0.5 || fault.maxGapMs >= 1000;
    expect(starved, isTrue,
        reason: 'a blackholed in-isolate client with a ${hazardIterate.inMilliseconds} ms '
            'iterate timeout must visibly starve the shared isolate; it did '
            'not, so either runIterate no longer blocks (see open62541_dart '
            '#116 — a good problem, revisit this test) or the probes are '
            'broken: $fault');
  });
}
