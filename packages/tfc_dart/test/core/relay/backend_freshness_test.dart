/// `BackendFreshnessSweep`: the clock that notices silence on main.
///
/// **Nothing here pokes a map.** Values arrive by putting a frame on a fake
/// worker's stream, which crosses the same `_applyFrame` path a real
/// acquisition isolate's drain tick does. A sweep that answered from somewhere
/// other than the pipe's cache would go red here.
///
/// **The waits are real.** These arms run the real watchdog on the real wall
/// clock at a deliberately short declared deadline, never a fake clock: a
/// source that never runs its sweep passes every fake-clock case and shows a
/// frozen-fresh page in the plant (`harness.dart:80-96`). The unit arms declare
/// 200 ms so the file stays quick; the contract leg at the bottom declares the
/// production [kBackendStaleAfter] and pays the ten seconds, because that is
/// the number the plant will actually run on.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_state_man.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show StateManApi;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show StateManHarness, runFreshnessContract;

// ---------------------------------------------------------------- the fixture

/// A motor speed on the pre-freezer conveyor line: the ordinary key.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key, so "the link dropped" and "one tag stopped" stay
/// distinguishable.
const _otherKey = 'ST201.CN04.MOT01.speed';

/// The fifty tags one station's mimic is covered in — the contract's own
/// `_stationKeys`, respelled here because that constant is private to the kit.
List<String> _stationKeys() => <String>[
      for (var i = 1; i <= 50; i++)
        'ST301.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in <String>[_speedKey, _otherKey, ..._stationKeys()])
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key),
        ),
    });

Logger _quiet() => Logger(level: Level.off);

relay.DynamicValue _good(Object? value) =>
    relay.DynamicValue(value: value, quality: relay.Quality.good);

/// Port delivery is asynchronous even inside one isolate (12-05).
Future<void> _settle() => pumpEventQueue(times: 10);

/// A worker main can talk to, with no isolate behind it.
///
/// A *plant* as much as a link: it remembers the last reading per key and
/// answers a [PipeResnapshot] from that memory in one frame.
class _FakePlantLink implements PipeWorkerLink {
  _FakePlantLink(this.name) {
    _port.listen(_onControl);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  final List<Object?> received = <Object?>[];
  final Map<String, relay.DynamicValue> last = <String, relay.DynamicValue>{};

  bool down = false;

  @override
  SendPort? get controlPort => down ? null : _port.sendPort;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() {}

  void emit(Object? message) {
    if (_out.isClosed) return;
    _out.add(message);
  }

  /// Delivers a batch as ONE worker frame — the unit conflation works in.
  void deliverAll(Map<String, relay.DynamicValue> values) {
    last.addAll(values);
    emit(PipeFrame(
        const <Object?>[], Map<String, relay.DynamicValue>.of(values)));
  }

  void deliver(String key, relay.DynamicValue value) =>
      deliverAll(<String, relay.DynamicValue>{key: value});

  void _onControl(Object? message) {
    received.add(message);
    if (message is! PipeResnapshot) return;
    emit(PipeFrame(const <Object?>[], <String, relay.DynamicValue>{
      for (final key in message.keys)
        if (last[key] != null) key: last[key]!,
    }));
  }

  void dispose() {
    _port.close();
    if (!_out.isClosed) _out.close();
  }
}

/// One assembled subject: one worker, one pipe, one adapter, one sweep.
/// The deadline the unit arms declare.
///
/// Short so the file stays quick, and real: these arms run the shipping
/// watchdog on the wall clock, and the only thing 200 ms changes is how long
/// the arm waits. The contract leg below runs at the production ten seconds.
const _unitStaleAfter = Duration(milliseconds: 200);

class _Fixture {
  _Fixture() {
    alpha = _FakePlantLink('alpha');
    pipe = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 150),
      logger: _quiet(),
    );
    pipe.addWorker(alpha, <String>[_speedKey, _otherKey, ..._stationKeys()]);
    values = BackendLiveValues(
      pipe: pipe,
      keyMappings: _mappings(),
      staleAfter: staleAfter,
      logger: _quiet(),
    );
    sweep = BackendFreshnessSweep(
      values: values,
      staleAfter: staleAfter,
      logger: _quiet(),
    );
  }

  final Duration staleAfter = _unitStaleAfter;

  late final _FakePlantLink alpha;
  late final PipeMainEndpoint pipe;
  late final BackendLiveValues values;
  late final BackendFreshnessSweep sweep;

  /// Long enough that the deadline has demonstrably passed and the sweep has
  /// had several turns at it — never a bare [staleAfter], which is the
  /// boundary itself.
  Future<void> pastDeadline() =>
      Future<void>.delayed(staleAfter + sweep.interval * 4);

  /// Several sweeps, comfortably INSIDE the deadline. The "quality never
  /// improves" arm needs this half: a sweep that heals is at its most
  /// plausible while the value is still fresh.
  Future<void> insideDeadline() => Future<void>.delayed(sweep.interval * 2);

  /// Attaches a listener and hands back the handle.
  ///
  /// A handle nobody listens to costs no monitored item and is invisible to
  /// the sweep — that is the whole listener gate — so an arm that wants a key
  /// watched has to say so.
  relay.ValueListenable<relay.DynamicValue> watch(String key) {
    final node = sweep.listen(key);
    void noop() {}
    node.addListener(noop);
    addTearDown(() => node.removeListener(noop));
    return node;
  }

  Future<void> tearDown() async {
    await sweep.dispose();
    pipe.dispose();
    alpha.dispose();
  }
}

/// Records every value a handle notifies with.
void _record(relay.ValueListenable<relay.DynamicValue> node,
    List<relay.DynamicValue> into) {
  void onChange() => into.add(node.value);
  node.addListener(onChange);
  addTearDown(() => node.removeListener(onChange));
}

void main() {
  // ------------------------------------------------------ the monotonic sweep

  group('the monotonic sweep', () {
    test(
        'a watched value past the deadline reads badStale through read, listen '
        'AND subscribe — three read paths, three assertions', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final streamed = <relay.DynamicValue>[];
      final sub = f.sweep.subscribe(_speedKey).listen(streamed.add);
      addTearDown(sub.cancel);
      final node = f.watch(_speedKey);

      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      expect(f.sweep.read(_speedKey)!.quality, relay.Quality.good,
          reason: 'the arm needs a fresh value to age; it never arrived');

      await f.pastDeadline();

      expect(node.value.quality, relay.Quality.badStale,
          reason: 'nothing has been heard about this key since the deadline '
              'and listen() still reads ${node.value.quality.code}');
      expect(f.sweep.read(_speedKey)!.quality, relay.Quality.badStale,
          reason: 'listen() and read() disagreed about whether the number can '
              'be trusted — two answers to the one question the operator is '
              'asking');
      expect(streamed.last.quality, relay.Quality.badStale,
          reason: 'the stream path never carried the degradation, so a '
              'stream-consuming client keeps the confident number');
      expect(node.value.asInt, 1450,
          reason: 'stale means "this number is old", not "there is no number" '
              '— an empty box looks like an unbound tag');
    });

    test('the ageing anchor is monotonic: no DateTime.now on the ageing path',
        () async {
      // The strong arm — step the machine's wall clock and prove the ageing is
      // unchanged — is not available to a Dart test: the process cannot move
      // the system clock, and there is deliberately no injectable clock seam
      // to hand in (a seam that accepts a steppable clock is a seam somebody
      // steps, freshness_sweep.dart's fourth property). So this is the weaker
      // arm, and it is a scan of the shipping source with its comments
      // stripped: Stopwatch present, the RTC absent. A backwards NTP
      // correction larger than the deadline made the old subtraction negative
      // for every key in the store at once, and the whole plant read fresh
      // from PLCs nobody had heard from (08-REVIEW CR-02); a forward step did
      // the mirror image and greyed everything.
      final source = File('lib/core/relay/backend_freshness.dart');
      expect(source.existsSync(), isTrue,
          reason: 'the scan cannot judge a file it cannot find; this arm runs '
              'from the package root');
      final code = source
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      expect(code, contains('Stopwatch'),
          reason: 'the ageing anchor must be a monotonic elapsed counter');
      expect(code, isNot(contains('DateTime.now')),
          reason: 'freshness ages on a monotonic anchor, never on the RTC: a '
              'clock step must not make every value on every panel go stale '
              'at once, and a step backwards must not make a stale value look '
              'fresh again');
      expect(code, isNot(contains('DateTime.timestamp')),
          reason: 'the same wall clock under a different name');
    });

    test('going stale is itself a change listeners hear about — once',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final node = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      final seen = <relay.DynamicValue>[];
      _record(node, seen);

      await f.pastDeadline();

      expect(seen.length, 1,
          reason: 'going stale cost ${seen.length} notifications; it is one '
              'change and must cost one rebuild — a watchdog that '
              're-announces staleness on every sweep turns 1500 quiet keys '
              'into a permanent rebuild storm the moment the plant goes idle');
      expect(seen.single.quality, relay.Quality.badStale,
          reason: 'the listener fired but the value it carries still reads '
              '${seen.single.quality.code}');
    });

    test('a fresh reading clears the staleness', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final node = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      await f.pastDeadline();
      expect(node.value.quality, relay.Quality.badStale,
          reason: 'this arm needs a stale value to recover from');

      f.alpha.deliver(_speedKey, _good(1600));
      await _settle();

      expect(node.value.quality.isGood, isTrue,
          reason: 'a fresh reading arrived and the value still reads stale; '
              'the box stays grey while the plant runs, and an operator who '
              'sees that twice stops believing grey at all');
      expect(node.value.asInt, 1600);

      // And it stays cleared for a whole run of sweeps, rather than being
      // re-staled by an anchor the arrival never reset.
      await f.insideDeadline();
      expect(node.value.quality.isGood, isTrue,
          reason: 'the arrival did not reset the ageing anchor');
    });

    test('quality never improves on its own — inside the deadline or past it',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final node = f.watch(_speedKey);
      f.alpha.deliver(_speedKey,
          relay.DynamicValue(value: 1450, quality: relay.Quality.badCommFault));
      await _settle();

      await f.insideDeadline();
      expect(node.value.quality, relay.Quality.badCommFault,
          reason: 'a fresh key carrying a fault was healed by a sweep; an '
              'operator sees a fault clear itself while the fault is still '
              'happening, which is the same lie as a stale value arrived at '
              'from the other direction and harder to catch because it looks '
              'like recovery');

      await f.pastDeadline();
      expect(node.value.quality, relay.Quality.badCommFault,
          reason: 'the sweep restaged a key already carrying worse news; '
              'badStale would replace "the link is sick, waiting may fix it" '
              'with a weaker and less actionable claim');
    });

    test('a health key is never accused of being stale by its own accounting',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final connected = f.watch(relay.PipeKeys.connected);
      final speed = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      await f.pastDeadline();

      // Presence beside the absence: the same pass that left the health key
      // alone did degrade the plant key, so this is not an arm satisfied by a
      // sweep that does nothing at all.
      expect(speed.value.quality, relay.Quality.badStale,
          reason: 'the barrier this arm rests on did not happen');
      expect(f.sweep.degraded, contains(_speedKey));
      expect(f.sweep.degraded, isNot(contains(relay.PipeKeys.connected)),
          reason: 'the sweep ASKED about a health key. PIPE.connected changes '
              'only when the link changes, so on a healthy pipe it is always '
              'older than the deadline — staling it greys out the one '
              'indicator an operator uses to decide whether to believe the '
              'rest of the screen, and greys it out exactly when nothing is '
              'wrong (HLTH-02)');
      expect(connected.value.quality, relay.Quality.good);
    });

    test(
        'the exclusion is PipeKeys.isPipeKey, so a health key invented later is '
        'skipped on the day it is invented', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      // A reserved name no roster in this repository lists. A prefix test
      // covers it; an enumerated list would not, and the symptom of an
      // enumerated list is an indicator that reads stale precisely while
      // nothing is wrong.
      const invented = '${relay.PipeKeys.prefix}upstream.st404.connected';
      final node = f.watch(invented);
      f.values.applyReadback(invented, _good(true));
      final speed = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      await f.pastDeadline();

      expect(speed.value.quality, relay.Quality.badStale,
          reason: 'the barrier this arm rests on did not happen');
      expect(node.value.quality, relay.Quality.good);
      expect(f.sweep.degraded, isNot(contains(invented)));
    });

    test(
        'the timer is listener-gated: nothing armed until a key is watched, '
        'disarmed when the last watcher goes', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      expect(f.sweep.running, isFalse,
          reason: 'an always-on Timer.periodic in tfc_dart plumbing fails '
              'unrelated widget tests and burns CPU on an idle backend');
      expect(f.sweep.sweeps, 0);

      final node = f.sweep.listen(_speedKey);
      expect(f.sweep.running, isFalse,
          reason: 'a handle nobody listens to costs no monitored item, so it '
              'must cost no clock either');

      void first() {}
      void second() {}
      node.addListener(first);
      expect(f.sweep.running, isTrue);
      node.addListener(second);

      node.removeListener(first);
      expect(f.sweep.running, isTrue,
          reason: 'one of two watchers leaving must disarm nothing');

      node.removeListener(second);
      expect(f.sweep.running, isFalse,
          reason: 'the LAST watcher going must stop the clock');

      // Paired presence: it arms again for the next watcher, so this is not an
      // arm satisfied by a sweep that can only ever start once.
      node.addListener(first);
      expect(f.sweep.running, isTrue);
      node.removeListener(first);
    });

    test('a key nobody watches is never swept, and one that is watched is',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final watched = f.watch(_speedKey);
      // _otherKey arrives too, but nobody is watching it: it has no monitored
      // item upstream and no box on any screen, and this source cannot notice
      // silence about a key it never asked to hear from.
      f.alpha.deliverAll(<String, relay.DynamicValue>{
        _speedKey: _good(1450),
        _otherKey: _good(3),
      });
      await _settle();

      await f.pastDeadline();

      expect(watched.value.quality, relay.Quality.badStale);
      expect(f.sweep.read(_otherKey)!.quality, relay.Quality.good,
          reason: 'an unwatched key was aged; the sweep must only account for '
              'what it is actually watching, or every unbound tag in the key '
              'mappings goes grey on a healthy plant');
    });

    test('dispose cancels the timer and nothing sweeps afterwards', () async {
      final f = _Fixture();
      final node = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      expect(f.sweep.running, isTrue);

      await f.sweep.dispose();
      expect(f.sweep.running, isFalse);
      final before = f.sweep.sweeps;

      await f.pastDeadline();
      expect(f.sweep.sweeps, before,
          reason: 'a timer that outlives its source keeps the isolate alive '
              'and keeps sweeping a store nobody is watching, so a leak in '
              'one case surfaces as an inexplicable notification in the next');
      expect(node.value.quality, relay.Quality.good,
          reason: 'a disposed sweep degraded a value');

      f.pipe.dispose();
      f.alpha.dispose();
    });

    test('the interval is a stated quarter of the deadline, floored', () async {
      // Stated rather than assumed. The interval bounds how late a stale badge
      // can be — a quarter puts a value's badge inside 125 % of its deadline
      // instead of 200 % — and it is CPU the backend spends whether or not
      // anything is wrong.
      expect(BackendFreshnessSweep.intervalFor(const Duration(seconds: 10)),
          const Duration(milliseconds: 2500));
      expect(BackendFreshnessSweep.intervalFor(const Duration(milliseconds: 4)),
          BackendFreshnessSweep.minimumInterval,
          reason: 'an implausibly short deadline out of a configuration file '
              'must not turn the sweep into a busy loop on the one isolate '
              'serving every client');
      expect(kBackendStaleAfter, const Duration(seconds: 10),
          reason: 'the production deadline sits just ABOVE D-12-08-a\'s '
              'measured ~9 s blackhole window, so the sweep never beats the '
              'link\'s own badCommFault to the screen; lowering it would make '
              'a healthy constant tag decay, which is F3');
    });
  });

  // ------------------------------------------------------ the contract, early
  //
  // The eight freshness checks, against a `BackendStateMan` whose value source
  // is 13-03's `BackendLiveValues` wrapped in this plan's sweep. The umbrella
  // suite is deliberately NOT called here — that is 13-09's, and calling it
  // now would register write, browse and data-services cases against
  // collaborators this composition does not have.
  //
  // The group carries its own timeout because the cases are run at the
  // PRODUCTION deadline: `_deadlineBudget` is `staleAfter * 3` = 30 s, which is
  // exactly package:test's default per-case timeout, so a genuinely broken
  // sweep would report as a runner timeout naming this file instead of as the
  // named failure naming the promise. Two minutes moves that boundary out of
  // the way without loosening a single assertion.
  group('the freshness contract, at the production deadline', () {
    runFreshnessContract(_contractSubject);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

// ------------------------------------------------------------ the harness leg

/// The keys the contract leg's one worker owns.
///
/// **One link, not two**, mirroring 13-03's harness for the identical reason:
/// `StateManHarness.disconnectUpstream()` takes no alias, and two links would
/// make "a mass degradation is announced once" and "a mass degradation degrades
/// every affected key" contradict each other.
List<String> _contractKeys() =>
    <String>[_speedKey, _otherKey, ..._stationKeys()];

/// A fresh subject for one contract case.
StateManApi _contractSubject() {
  final subject = _HarnessedFreshBackend();
  addTearDown(subject.shutdownFixture);
  return subject;
}

/// `BackendStateMan` over 13-03's `BackendLiveValues` **wrapped in this plan's
/// sweep**, plus the levers.
///
/// **This is a copy of 13-03's `_HarnessedLiveValues`, and the duplication is
/// deliberately visible.** 13-09 consolidates both into
/// `test/support/harnessed_backend_state_man.dart`; until it does, a shared
/// helper edited by two plans in the same wave is a merge conflict in the one
/// file every contract leg depends on.
///
/// Every member of `StateManApi` is forwarded by hand rather than through a
/// `noSuchMethod`: a member added to the interface in a later phase becomes a
/// compile error here instead of silently arriving unpoliced.
final class _HarnessedFreshBackend implements StateManApi, StateManHarness {
  _HarnessedFreshBackend() {
    _plant = _FakePlantLink('contract');
    _pipe = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 150),
      logger: _quiet(),
    );
    _pipe.addWorker(_plant, _contractKeys());
    _values = BackendLiveValues(
      pipe: _pipe,
      keyMappings: _mappings(),
      logger: _quiet(),
    );
    _sweep = BackendFreshnessSweep(
      values: _values,
      staleAfter: _values.staleAfter,
      logger: _quiet(),
    );
    _api = BackendStateMan(values: _sweep);
  }

  late final _FakePlantLink _plant;
  late final PipeMainEndpoint _pipe;
  late final BackendLiveValues _values;
  late final BackendFreshnessSweep _sweep;
  late final BackendStateMan _api;

  /// Tears the *fixture* down — never called by a case, only by `addTearDown`.
  void shutdownFixture() {
    _pipe.dispose();
    _plant.dispose();
  }

  // --------------------------------------------------------------- the levers

  @override
  void setValue(String key, Object? value,
      {relay.Quality quality = relay.Quality.good, DateTime? sourceTime}) {
    _plant.deliver(
        key,
        relay.DynamicValue(
            value: value, quality: quality, sourceTime: sourceTime));
  }

  @override
  void setValues(Map<String, Object?> values) {
    _plant.deliverAll(<String, relay.DynamicValue>{
      for (final entry in values.entries)
        entry.key: relay.DynamicValue(value: entry.value),
    });
  }

  @override
  void setQuality(String key, relay.Quality quality) {
    final cached = _pipe.store.peek(key);
    _plant.deliver(
        key,
        relay.DynamicValue(
          value: cached?.value,
          quality: quality,
          sourceTime: cached?.sourceTime,
        ));
  }

  @override
  void dropKey(String key) => _plant.emit(PipeFrame(
      <Object?>[PipeKeyRetired(key)], const <String, relay.DynamicValue>{}));

  /// **The announcement, not an isolate death**, and the difference is a
  /// recorded finding rather than a convenience.
  ///
  /// The pipe's own death path (`_onWorkerDied` → `_markBad`) writes
  /// `badCommFault` with a **null payload** — 12-08 asserts that explicitly,
  /// mutation C. `checkUpstreamLossDegradesAffectedKeys` requires the opposite:
  /// "the last known reading must survive the link loss, so the operator can
  /// see what the plant was doing when contact was lost". The two promises
  /// genuinely disagree and neither is this plan's to overrule, so the lever
  /// drives the announcement surface the seam declares for it. The
  /// isolate-death path has its own arms in this file.
  @override
  void disconnectUpstream() => _sweep
      .announceLinkLoss('the contract harness pulled the upstream link');

  @override
  void reconnectUpstream() => _sweep.announceLinkUp();

  @override
  Duration get staleAfter => _sweep.staleAfter;

  @override
  int get roundTrips => _sweep.roundTrips;

  @override
  int get statusNotifications => _sweep.statusNotifications;

  // ---------------------------------------------------------- the wire surface

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      _api.listen(key);

  @override
  Stream<relay.DynamicValue> subscribe(String key) => _api.subscribe(key);

  @override
  relay.DynamicValue? read(String key) => _api.read(key);

  @override
  Future<relay.DynamicValue> readFresh(String key) => _api.readFresh(key);

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) =>
      _api.readMany(keys);

  @override
  List<String> get keys => _api.keys;

  @override
  Future<relay.WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _api.write(key, value, expect: expect, cmd: cmd);

  @override
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds) =>
      _api.writeStatus(cmds);

  @override
  Future<relay.HoldHandle> holdToRun(String key) => _api.holdToRun(key);

  @override
  relay.BrowseApi get browse => _api.browse;

  @override
  relay.TimeseriesApi get timeseries => _api.timeseries;

  @override
  relay.HistoryViewApi get historyViews => _api.historyViews;

  @override
  relay.PreferencesApi get preferences => _api.preferences;

  @override
  Future<void> dispose() => _api.dispose();
}
