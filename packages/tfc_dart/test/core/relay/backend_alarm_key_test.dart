/// `ALARM.active` at the backend's two wiring sites: declared, and never
/// badged stale.
///
/// **Nothing here pokes a private map.** The plant tag arrives by putting a
/// frame on a fake worker's stream, the same `_applyFrame` path a real
/// acquisition isolate's drain tick crosses. `ALARM.active` arrives by
/// `pipe.store.applyBatch`, which is exactly how the alarm engine (14-05) will
/// publish it and exactly how `BackendLiveValues._seedHealth` already publishes
/// `PIPE.connected` — a synthetic key with no worker behind it.
///
/// **The waits are real.** These arms run the shipping watchdog on the wall
/// clock at a deliberately short declared deadline, never a fake clock: a
/// source that never runs its sweep passes every fake-clock case and shows a
/// frozen-fresh page in the plant.
///
/// **Absence is always paired with presence.** Every arm that asserts the alarm
/// key was left alone also asserts, in the same run, that an ordinary plant tag
/// went `badStale`. An unpaired absence arm passes against an implementation
/// that does nothing at all.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

// ---------------------------------------------------------------- the fixture

/// A motor speed on the pre-freezer conveyor line: the ordinary plant tag, and
/// the control in every arm below. If it does not go stale, the arm proves
/// nothing about the alarm key beside it.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second plant tag, so "one tag stopped" and "everything stopped" stay
/// distinguishable.
const _otherKey = 'ST201.CN04.MOT01.speed';

Logger _quiet() => Logger(level: Level.off);

relay.DynamicValue _good(Object? value) =>
    relay.DynamicValue(value: value, quality: relay.Quality.good);

/// What the engine will publish: a list of entries, one per active alarm.
/// Shape only — the field names are 14-05's (CD-1), and nothing here reads
/// them.
relay.DynamicValue _activeSet() => _good(<Object?>[
      <String, Object?>{'uid': 'ST101.CN01.MOT01.overtemp', 'level': 'alarm'},
    ]);

/// Port delivery is asynchronous even inside one isolate (12-05).
Future<void> _settle() => pumpEventQueue(times: 10);

KeyMappings _mappings({bool alarmKeyMappedToo = false}) => KeyMappings(
      nodes: <String, KeyMappingEntry>{
        for (final key in <String>[
          _speedKey,
          _otherKey,
          // The perverse case: an operator who named a plant tag into the
          // reserved namespace. The backend has no ingest refusal yet (T-14-08
          // — that is 14-05's, at engine start), so the least this class can do
          // is not offer the same name to the picker twice.
          if (alarmKeyMappedToo) relay.AlarmKeys.active,
        ])
          key: KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key),
          ),
      },
    );

/// A worker main can talk to, with no isolate behind it. Trimmed from the
/// sibling files' `_FakePlantLink` to what these arms lever.
class _FakePlantLink implements PipeWorkerLink {
  _FakePlantLink(this.name) {
    _port.listen(_onControl);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();
  final Map<String, relay.DynamicValue> last = <String, relay.DynamicValue>{};

  @override
  SendPort? get controlPort => _port.sendPort;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() {}

  void emit(Object? message) {
    if (_out.isClosed) return;
    _out.add(message);
  }

  void deliver(String key, relay.DynamicValue value) {
    last[key] = value;
    emit(PipeFrame(const <Object?>[], <String, relay.DynamicValue>{key: value}));
  }

  void _onControl(Object? message) {
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

/// Short so the file stays quick, and real: these arms run the shipping
/// watchdog on the wall clock, and the only thing 200 ms changes is how long
/// the arm waits.
const _unitStaleAfter = Duration(milliseconds: 200);

class _Fixture {
  _Fixture({bool alarmKeyMappedToo = false}) {
    alpha = _FakePlantLink('alpha');
    pipe = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 150),
      logger: _quiet(),
    );
    pipe.addWorker(alpha, <String>[_speedKey, _otherKey]);
    values = BackendLiveValues(
      pipe: pipe,
      keyMappings: _mappings(alarmKeyMappedToo: alarmKeyMappedToo),
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

  final Duration staleAfter = _unitStaleAfter;

  late final _FakePlantLink alpha;
  late final PipeMainEndpoint pipe;
  late final BackendLiveValues values;
  late final BackendFreshnessSweep sweep;

  /// The engine's publish, done the way the engine will do it: straight into
  /// the pipe's own store, which is where `PIPE.connected` already lives.
  void publishActiveSet([relay.DynamicValue? value]) =>
      pipe.store.applyBatch(<String, relay.DynamicValue>{
        relay.AlarmKeys.active: value ?? _activeSet(),
      });

  /// Long enough that the deadline has demonstrably passed and the sweep has
  /// had several turns at it — never a bare [staleAfter], which is the
  /// boundary itself.
  Future<void> pastDeadline() =>
      Future<void>.delayed(staleAfter + sweep.interval * 4);

  /// Attaches a listener and hands back the handle. A handle nobody listens to
  /// costs no monitored item and is invisible to the sweep — that is the whole
  /// listener gate — so an arm that wants a key watched has to say so.
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

void main() {
  // ------------------------------------------------------------- site 1: keys

  group('the declared key list', () {
    test('ALARM.active is a key this source says it can serve', () {
      final f = _Fixture();
      addTearDown(f.tearDown);

      // This arm stands in for the rig's FIND-3 measurement. A key absent
      // from this list is answered `unknownKey` by the relay server, which is
      // exactly what happened to `PIPE.upstream.*`: the producer existed, the
      // value existed, and every panel that subscribed was refused.
      expect(f.values.keys, contains(relay.AlarmKeys.active),
          reason: 'undeclared, every panel subscribing to the alarm banner is '
              'answered unknownKey and the banner never draws');

      // Paired presence: the list is not simply everything.
      expect(f.values.keys, contains(_speedKey));
      expect(f.values.keys, isNot(contains('ST999.CN99.MOT99.speed')),
          reason: 'listing an unserved key sends whoever draws the next page '
              'to bind a tag that will never produce a value');
    });

    test('the reason it is declared is not the reason PIPE.connected is', () {
      final f = _Fixture();
      addTearDown(f.tearDown);

      // Two different reasons must not share one list. `healthKeys` exists
      // because this class IS the producer of `PIPE.connected` — it seeds it
      // true at construction. This class is NOT the producer of
      // `ALARM.active`; it declares it only so the server will serve a
      // subscription for it, and the engine publishes into it later.
      expect(BackendLiveValues.healthKeys,
          isNot(contains(relay.AlarmKeys.active)),
          reason: 'on the health list, a future reader would seed it here — '
              'and a seeded empty set is a claim that no alarm is active, '
              'made by an object that has never evaluated a rule');
      expect(BackendLiveValues.alarmKeys, contains(relay.AlarmKeys.active));

      // The producer/declarer split, measured: the health key it produces has
      // a value at construction, the alarm key it merely declares does not.
      expect(f.values.read(relay.PipeKeys.connected)?.asBool, isTrue);
      expect(f.values.read(relay.AlarmKeys.active), isNull,
          reason: 'a key with no producer yet reads "not heard from", which '
              'is the honest answer; seeding is the engine\'s job (14-05)');
    });

    test('declared exactly once, even when a key mapping is named the same',
        () {
      final f = _Fixture(alarmKeyMappedToo: true);
      addTearDown(f.tearDown);

      final occurrences =
          f.values.keys.where((k) => k == relay.AlarmKeys.active).length;
      expect(occurrences, 1,
          reason: 'the key appeared $occurrences times. A duplicate reaches '
              'the browse surface as two identical entries an operator cannot '
              'tell apart, and reaches subscribe accounting as two '
              'registrations for one monitored item');
    });
  });

  // ------------------------------------------------- site 2: the sweep

  group('the freshness sweep', () {
    test('leaves ALARM.active alone while staling a plant tag that went quiet',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final alarmNode = f.watch(relay.AlarmKeys.active);
      final speedNode = f.watch(_speedKey);

      f.alpha.deliver(_speedKey, _good(1450));
      f.publishActiveSet();
      await _settle();
      expect(speedNode.value.quality, relay.Quality.good,
          reason: 'the arm needs a fresh plant value to age; it never arrived');
      expect(alarmNode.value.quality, relay.Quality.good,
          reason: 'the arm needs a published active set to leave alone');

      await f.pastDeadline();
      f.sweep.sweep();

      // The sweep-side observable, and the arm that goes red on its own. The
      // quality assertion below cannot distinguish "the sweep skipped it" from
      // "markStale skipped it": `degraded` can, and it is what the sweep
      // itself writes.
      expect(f.sweep.degraded, isNot(contains(relay.AlarmKeys.active)),
          reason: 'the sweep staged the alarm key for degradation. On a '
              'healthy, quiet plant the alarm banner then greys out ten '
              'seconds after the last transition, which teaches operators '
              'that grey means nothing — the one thing they must never learn '
              '(P-6)');
      expect(alarmNode.value.quality, relay.Quality.good);
      expect(f.sweep.read(relay.AlarmKeys.active)!.quality, relay.Quality.good,
          reason: 'listen() and read() must not disagree about whether the '
              'alarm banner can be trusted');

      // Paired presence: the exclusion is a prefix test, not an accidental
      // "skip everything". Same run, same sweep, same deadline.
      expect(f.sweep.degraded, contains(_speedKey));
      expect(speedNode.value.quality, relay.Quality.badStale,
          reason: 'the plant tag has been silent past the deadline and still '
              'reads ${speedNode.value.quality.code}; if this passes only '
              'because the sweep degrades nothing at all, the arm above is '
              'worthless');
    });

    test('the alarm key survives even when the whole watched set is swept',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final alarmNode = f.watch(relay.AlarmKeys.active);
      f.watch(_speedKey);
      f.watch(_otherKey);

      f.alpha.deliver(_speedKey, _good(1450));
      f.alpha.deliver(_otherKey, _good(980));
      f.publishActiveSet();
      await _settle();

      await f.pastDeadline();
      f.sweep.sweep();

      expect(f.sweep.degraded, <String>{_speedKey, _otherKey},
          reason: 'exactly the plant tags, and nothing else. A set carrying '
              'the alarm key means the exclusion is not being consulted; a '
              'set missing a plant tag means the sweep stopped working');
      expect(alarmNode.value.asArray, isNotEmpty,
          reason: 'stale or not, the payload must survive — an empty alarm '
              'banner is the claim that nothing is wrong');
      expect(alarmNode.value.quality, relay.Quality.good);
    });
  });

  // -------------------------------------------- site 2b: the other route

  group('markStale, the other route to the same damage', () {
    test('refuses ALARM.active by prefix while degrading a plant tag', () {
      final f = _Fixture();
      addTearDown(f.tearDown);

      f.pipe.store.applyBatch(<String, relay.DynamicValue>{
        _speedKey: _good(1450),
      });
      f.publishActiveSet();

      // Called directly, the way a link-loss batch would call it. The sweep is
      // not involved: this is the second route, and it needs its own
      // exclusion or the first one is a screen door.
      f.values.markStale(<String>[_speedKey, relay.AlarmKeys.active]);

      expect(f.values.read(relay.AlarmKeys.active)!.quality,
          relay.Quality.good,
          reason: 'markStale degraded the alarm key. A batch arriving by any '
              'route other than the sweep would then grey the banner, and the '
              'sweep exclusion would look like it was working');
      expect(f.values.read(_speedKey)!.quality, relay.Quality.badStale,
          reason: 'paired presence: markStale must still do its job in the '
              'same call, or the arm above passes against a no-op');
    });

    test('a key merely inside the namespace is refused too, by rule', () {
      final f = _Fixture();
      addTearDown(f.tearDown);

      // A prefix test, never a roster lookup: a key invented in a later phase
      // is excluded on the day it is invented, with no edit to either backend
      // file. `ALARM.shelved` is in no list anywhere in the workspace.
      const invented = 'ALARM.shelved';
      f.pipe.store.applyBatch(<String, relay.DynamicValue>{
        invented: _good(<Object?>[]),
        _speedKey: _good(1450),
      });

      f.values.markStale(<String>[invented, _speedKey]);

      expect(f.values.read(invented)!.quality, relay.Quality.good);
      expect(f.values.read(_speedKey)!.quality, relay.Quality.badStale);
    });

    test('the PIPE. exclusion was extended, not replaced', () {
      final f = _Fixture();
      addTearDown(f.tearDown);

      f.pipe.store.applyBatch(<String, relay.DynamicValue>{
        _speedKey: _good(1450),
      });
      f.values.markStale(
          <String>[relay.PipeKeys.connected, relay.AlarmKeys.active, _speedKey]);

      expect(f.values.read(relay.PipeKeys.connected)!.quality,
          relay.Quality.good,
          reason: 'HLTH-02 predates this plan: staling PIPE.connected greys '
              'out the one indicator an operator uses to decide whether to '
              'believe the rest of the screen');
      expect(f.values.read(_speedKey)!.quality, relay.Quality.badStale);
    });
  });
}
