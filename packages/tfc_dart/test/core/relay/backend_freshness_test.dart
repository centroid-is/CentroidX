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
import 'package:tfc_dart/core/relay/backend_seams.dart' show StampedValue;
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show runFreshnessContract;

import 'package:tfc_stateman_contract/testing/runner_budget.dart'
    show budgetScale, useRunnerBudgets;

import '../../support/harnessed_backend_state_man.dart';

// ---------------------------------------------------------------- the fixture

/// A motor speed on the pre-freezer conveyor line: the ordinary key.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key, so "the link dropped" and "one tag stopped" stay
/// distinguishable.
const _otherKey = 'ST201.CN04.MOT01.speed';

/// A key on the *second* worker, so one worker's blast radius is observable.
const _farKey = 'ST301.CN02.VLV01.stat';

/// The fifty tags one station's mimic is covered in — the contract's own
/// `_stationKeys`, respelled here because that constant is private to the kit.
List<String> _stationKeys() => <String>[
      for (var i = 1; i <= 50; i++)
        'ST301.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

/// The fifteen keys the link-loss arm kills in one go.
List<String> _fifteenKeys() => _stationKeys().take(15).toList();

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in <String>[
        _speedKey,
        _otherKey,
        _farKey,
        ..._stationKeys()
      ])
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

  /// The plant moved while nobody could hear it.
  ///
  /// Updates what this worker would answer a resnapshot with, and delivers
  /// nothing. It is the only lever that can tell a snapshot recovery from a
  /// delta replay: after this, the plant's number and the last number anybody
  /// on main saw are different, and exactly one of them is the truth.
  void moveWhileDark(String key, relay.DynamicValue value) => last[key] = value;

  /// The isolate is gone: `null` on the data port, and no control port. This
  /// is literally what the VM and the supervisor do.
  void die() {
    down = true;
    emit(null);
  }

  /// A new generation announced itself with its control port.
  void respawn() {
    down = false;
    emit(_port.sendPort);
  }

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

/// The deadline the unit arms declare.
///
/// Short so the file stays quick, and real: these arms run the shipping
/// watchdog on the wall clock, and the only thing 200 ms changes is how long
/// the arm waits. The contract leg below runs at the production ten seconds.
/// The unit fixture's freshness deadline.
///
/// **Scaled on a hosted runner, and every derived duration with it.** The
/// sweep interval is a quarter of this and `insideDeadline` waits two
/// intervals, so at 200 ms the case waits 100 ms and needs the value to still
/// be fresh at 200 ms — a 2x margin against a `Future.delayed` that a loaded
/// agent can overshoot by more than that. `tfc-dart-test (macos-latest)` did
/// exactly that and reported it as "the arrival did not reset the ageing
/// anchor", which is a claim about the code and was not true of it.
///
/// Scaling the deadline scales the interval and both waits together, so every
/// ratio this file asserts is unchanged; only the absolute room for timer
/// jitter grows. That is the difference between this and widening a tolerance:
/// nothing here is permitted that was not permitted before.
final Duration _unitStaleAfter =
    const Duration(milliseconds: 200) * budgetScale;

/// One assembled subject: one or two workers, one pipe, one adapter, one sweep.
class _Fixture {
  _Fixture({this.twoWorkers = false}) {
    alpha = _FakePlantLink('alpha');
    pipe = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 150),
      logger: _quiet(),
    );
    pipe.addWorker(alpha, <String>[_speedKey, _otherKey, ..._stationKeys()]);
    if (twoWorkers) {
      beta = _FakePlantLink('beta');
      pipe.addWorker(beta!, <String>[_farKey]);
    }
    values = BackendLiveValues(
      pipe: pipe,
      keyMappings: _mappings(),
      staleAfter: staleAfter,
      logger: _quiet(),
    );
    sweep = BackendFreshnessSweep(
      values: values,
      staleAfter: staleAfter,
      pipe: pipe,
      logger: _quiet(),
    );
  }

  final bool twoWorkers;
  final Duration staleAfter = _unitStaleAfter;

  late final _FakePlantLink alpha;
  _FakePlantLink? beta;
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
    beta?.dispose();
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
  useRunnerBudgets();

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

    test(
        'a key watched ONLY through subscribeStamped is aged like any other — '
        'the alarm engine is a watcher too', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      // The alarm engine's road in since ALRM-03: `AlarmRuleWatcher` subscribes
      // through the STAMPED stream and touches no plain handle at all. If that
      // road does not register with the sweep, an alarm input the plant stopped
      // sending stays `good` forever, D-3's quality gate never suspends the
      // rule, and the rule keeps evaluating a number nobody is producing — the
      // exact lie this sweep exists to catch. `alarm_two_panels_test.dart`
      // arm 7 found it end to end; this is the fast-lane pin.
      final seen = <StampedValue>[];
      final sub = f.sweep.subscribeStamped(_speedKey).listen(seen.add);
      addTearDown(sub.cancel);

      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      await f.pastDeadline();

      expect(f.sweep.read(_speedKey)!.quality, relay.Quality.badStale,
          reason: 'the stamped subscription never registered its key with the '
              'sweep, so the sweep is ageing nothing on the alarm engine\'s '
              'behalf');
      expect(seen.last.value.quality, relay.Quality.badStale,
          reason: 'and the degradation must arrive ON the stamped stream '
              'itself — the watcher\'s quality gate (D-3) can only suspend on '
              'a badge it is actually handed');

      // The listener gate is a refcount, not a latch: the engine letting go
      // must release the key, or a page's worth of retired alarm rules keeps
      // the sweep grinding forever.
      await sub.cancel();
      f.alpha.deliver(_speedKey, _good(1500));
      await _settle();
      await f.pastDeadline();
      expect(f.sweep.read(_speedKey)!.quality, relay.Quality.good,
          reason: 'the key was still being aged after the last stamped '
              'listener cancelled');
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

  // --------------------------------------------- the link, lost and regained

  group('link loss', () {
    test('a worker death degrades every key it served and costs exactly ONE '
        'announcement', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final keys = _fifteenKeys();
      final nodes = <String, relay.ValueListenable<relay.DynamicValue>>{
        for (final key in keys) key: f.watch(key),
      };
      f.alpha.deliverAll(<String, relay.DynamicValue>{
        for (var i = 0; i < keys.length; i++) keys[i]: _good(1000 + i),
      });
      await _settle();
      expect(nodes[keys.first]!.value.quality, relay.Quality.good,
          reason: 'the arm needs fifteen live keys to lose');

      final before = f.sweep.statusNotifications;
      f.alpha.die();
      await _settle();

      for (final key in keys) {
        expect(nodes[key]!.value.quality, relay.Quality.badCommFault,
            reason: '$key survived its own worker\'s death; a mimic with half '
                'its boxes greyed reads as a plant fault and sends someone to '
                'the wrong end of the building');
      }
      expect(f.sweep.statusNotifications - before, 1,
          reason: 'losing one link cost '
              '${f.sweep.statusNotifications - before} announcements for '
              '${keys.length} keys; the same shape at 1500 keys is 1500 '
              'events for one event, delivered in the instant the client is '
              'trying to redraw the page they are all about');
      expect(f.sweep.read(relay.PipeKeys.connected)!.asBool, isFalse,
          reason: 'the indicator an operator checks before trusting the rest '
              'of the screen would be the last thing on it to be wrong');
    });

    test('the pipe\'s death path drops the payload — recorded here, not '
        'endorsed', () async {
      // A finding rather than a promise. `_onWorkerDied` → `_markBad` writes
      // badCommFault with a NULL value, and 12-08 asserts that explicitly
      // (mutation C, "no payload under a bad badge").
      // `checkUpstreamLossDegradesAffectedKeys` requires the opposite: "the
      // last known reading must survive the link loss, so the operator can
      // see what the plant was doing when contact was lost". The two genuinely
      // disagree, neither is 13-07's to overrule, and an arm that pins today's
      // behaviour is how the disagreement stops being invisible: whoever
      // resolves it (Phase 16) will see this go red and read this comment.
      final f = _Fixture();
      addTearDown(f.tearDown);

      final node = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      f.alpha.die();
      await _settle();

      expect(node.value.quality, relay.Quality.badCommFault);
      expect(node.value.value, isNull,
          reason: 'if this is now 1450, the pipe has been taught to keep the '
              'last reading under a bad badge and the contract and the pipe '
              'finally agree — delete this arm and say so');
    });

    test('a second death with no intervening recovery does not double-announce',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      final before = f.sweep.statusNotifications;
      f.alpha.die();
      await _settle();
      expect(f.sweep.statusNotifications - before, 1,
          reason: 'the first death must announce, or this arm proves nothing');

      f.alpha.die();
      await _settle();
      expect(f.sweep.statusNotifications - before, 1,
          reason: 'the link was already down; a second death is not a second '
              'transition');
    });

    test('the announcement is not re-emitted on every sweep tick while the '
        'link is down', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      final before = f.sweep.statusNotifications;
      f.alpha.die();
      await _settle();
      final ticksBefore = f.sweep.sweeps;

      await f.pastDeadline();

      expect(f.sweep.sweeps, greaterThan(ticksBefore),
          reason: 'the clock stopped, so this arm establishes nothing about '
              'what a running clock would have announced');
      expect(f.sweep.statusNotifications - before, 1,
          reason: 'the outage is one event; re-announcing it four times a '
              'deadline for as long as the PLC is down is the same denial of '
              'service as a per-key fan-out, arrived at slowly');
    });

    test('recovery is announced once and restores from the respawn SNAPSHOT, '
        'never a remembered delta', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final node = f.watch(_speedKey);
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      f.alpha.die();
      await _settle();
      expect(node.value.quality, relay.Quality.badCommFault,
          reason: 'this arm needs a real outage to recover from');

      // The plant moved while nobody on main could hear it. 1450 is what main
      // last saw; 1600 is what is true.
      f.alpha.moveWhileDark(_speedKey, _good(1600));

      final before = f.sweep.statusNotifications;
      f.alpha.respawn();
      await _settle();
      await _settle();

      // The snapshot-vs-delta assertion goes FIRST, deliberately. A recovery
      // built on a remembered delta typically also gets the announcement
      // count wrong, and if the count were asserted first, the one failure
      // that names *this* property would never be the one printed.
      expect(node.value.asInt, 1600,
          reason: 'the value main remembered was replayed instead of the one '
              'the plant actually holds. A remembered number put back on '
              'recovery is a number nobody measured, presented as a '
              'measurement, at the exact moment an operator is looking to see '
              'what changed while they were blind');
      expect(node.value.quality.isGood, isTrue,
          reason: 'the keys came back from the outage still degraded');
      expect(f.sweep.statusNotifications - before, 1,
          reason: 'the recovery announcement is as single as the loss');
      expect(f.sweep.read(relay.PipeKeys.connected)!.asBool, isTrue);

      // And a second generation announcement adds nothing: there is no outage
      // left to recover from.
      f.alpha.respawn();
      await _settle();
      expect(f.sweep.statusNotifications - before, 1);
    });

    test('one worker of two dying degrades only its own keys and announces '
        'nothing; the second death announces once', () async {
      final f = _Fixture(twoWorkers: true);
      addTearDown(f.tearDown);

      final near = f.watch(_speedKey);
      final far = f.watch(_farKey);
      f.alpha.deliver(_speedKey, _good(1450));
      f.beta!.deliver(_farKey, _good(7));
      await _settle();

      final before = f.sweep.statusNotifications;
      f.alpha.die();
      await _settle();

      expect(near.value.quality, relay.Quality.badCommFault);
      expect(far.value.quality, relay.Quality.good,
          reason: 'one dark PLC starves only its own isolate — 12-08 measured '
              'that blast radius, and announcing a whole-of-upstream loss '
              'because one of two workers exited would grey out a plant that '
              'is running perfectly well');
      expect(f.sweep.statusNotifications, before,
          reason: 'announceLinkLoss is a statement about the upstream, not '
              'about one isolate: it degrades every key the source has heard '
              'about and drops PIPE.connected');
      expect(f.sweep.read(relay.PipeKeys.connected)!.asBool, isTrue,
          reason: 'the pipe is still serving one of its two PLCs');

      f.beta!.die();
      await _settle();

      expect(far.value.quality, relay.Quality.badCommFault);
      expect(f.sweep.statusNotifications - before, 1,
          reason: 'the upstream as a whole is now gone: one transition, one '
              'announcement');
      expect(f.sweep.read(relay.PipeKeys.connected)!.asBool, isFalse);
    });

    test('dispose gives the pipe\'s link hooks back', () async {
      final f = _Fixture();
      expect(f.pipe.onWorkerDied, isNotNull);
      expect(f.pipe.onWorkerReady, isNotNull);

      await f.sweep.dispose();

      expect(f.pipe.onWorkerDied, isNull,
          reason: 'a disposed sweep left wired to the pipe announces an '
              'outage through a source that is already torn down');
      expect(f.pipe.onWorkerReady, isNull);

      f.pipe.dispose();
      f.alpha.dispose();
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
    runFreshnessContract(makeHarnessedBackendStateMan);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

// ------------------------------------------------------------ the harness leg
//
// **13-09 consolidated it.** `_HarnessedFreshBackend` and its three siblings
// are now one file, `test/support/harnessed_backend_state_man.dart`. Its
// `disconnectUpstream` still drives `announceLinkLoss` rather than killing the
// worker, for Finding 1's reason — the pipe's death path drops the payload and
// `checkUpstreamLossDegradesAffectedKeys` requires the last reading to survive
// — and the isolate-death path keeps its own arms above, where it belongs.
