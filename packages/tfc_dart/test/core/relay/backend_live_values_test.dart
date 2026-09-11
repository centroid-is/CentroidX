/// `BackendLiveValues`: the live half of the backend's `StateManApi`, judged
/// through a real [PipeMainEndpoint] over a fake worker link.
///
/// **Nothing here pokes a map.** Every lever — `setValue`, `setValues`,
/// `setQuality`, `dropKey`, `disconnectUpstream` — puts a frame on the fake
/// worker's stream, which crosses the same `_applyFrame` path a real
/// acquisition isolate's drain tick does. That is what makes these arms
/// evidence about the pipe rather than about a stub: an adapter that answered
/// from somewhere other than the pipe's cache would go red here.
///
/// **Absence is always paired with presence.** Every arm that asserts nothing
/// happened — no second control message, no round trip on a cached read, no
/// notification after dispose — also asserts the thing that *should* happen in
/// the same arm. 12-06's mutation H is the record of what an unpaired absence
/// arm is worth: it passes against an implementation that does nothing at all.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show runReadContract, runStoreContract, runSubscribeContract;

import '../../support/harnessed_backend_state_man.dart';

// ---------------------------------------------------------------- the fixture

/// A motor speed on the pre-freezer conveyor line: the ordinary key.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key on the same worker, used as a barrier.
const _otherKey = 'ST201.CN04.MOT01.speed';

/// A key on the *second* worker, so fan-out is observable.
const _farKey = 'ST301.CN02.MOT01.speed';

/// A key that exists and is then retired — the tag deleted in the PLC.
const _deletedKey = 'ST301.CN18.VLV01.stat';

/// A key no source here ever serves, and which is in no key mapping.
const _missingKey = 'ST301.CN17.VLV02.stat';

/// The keys worker 0 owns.
const _alphaKeys = <String>[_speedKey, _otherKey];

/// The keys worker 1 owns.
const _betaKeys = <String>[_farKey, _deletedKey];

/// Fifty tags of the kind a diagnostics page opens with, all on worker 0.
List<String> _diagnosticsKeys() => <String>[
      for (var i = 1; i <= 50; i++)
        'ST201.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

/// Key mappings covering everything either worker owns — and deliberately NOT
/// [_missingKey], because the store contract requires `keys` to omit a key the
/// source cannot serve.
KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in <String>[
        ..._alphaKeys,
        ..._betaKeys,
        ..._diagnosticsKeys(),
        ..._batchKeys(),
      ])
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key),
        ),
    });

/// The hundred-key batch the store contract applies.
List<String> _batchKeys() => <String>[
      for (var i = 0; i < 100; i++)
        'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

/// Quiet: these arms assert on control traffic, not on log lines.
Logger _quiet() => Logger(level: Level.off);

/// Port delivery is asynchronous even inside one isolate (12-05).
Future<void> _settle() => pumpEventQueue(times: 10);

/// A worker main can talk to, with no isolate behind it.
///
/// It is a *plant* as much as a link: it remembers the last reading per key,
/// answers a [PipeResnapshot] from that memory in one frame, and records every
/// control message main sent.
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

  List<PipeSubscribe> get subscribes =>
      received.whereType<PipeSubscribe>().toList();

  List<PipeUnsubscribe> get unsubscribes =>
      received.whereType<PipeUnsubscribe>().toList();

  List<PipeResnapshot> get resnapshots =>
      received.whereType<PipeResnapshot>().toList();

  void emit(Object? message) {
    if (_out.isClosed) return;
    _out.add(message);
  }

  /// Delivers a batch as ONE worker frame — the unit conflation works in.
  void deliverAll(Map<String, relay.DynamicValue> values) {
    last.addAll(values);
    emit(PipeFrame(const <Object?>[], Map<String, relay.DynamicValue>.of(values)));
  }

  void deliver(String key, relay.DynamicValue value) =>
      deliverAll(<String, relay.DynamicValue>{key: value});

  /// The tag is gone upstream, in the worker's own vocabulary.
  void retire(String key) {
    last.remove(key);
    emit(PipeFrame(
        <Object?>[PipeKeyRetired(key)], const <String, relay.DynamicValue>{}));
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

/// One assembled subject: two workers, one pipe, one adapter.
class _Fixture {
  _Fixture() {
    alpha = _FakePlantLink('alpha');
    beta = _FakePlantLink('beta');
    pipe = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 150),
      logger: _quiet(),
    );
    pipe.addWorker(alpha, <String>[
      ..._alphaKeys,
      ..._diagnosticsKeys(),
      ..._batchKeys(),
    ]);
    pipe.addWorker(beta, _betaKeys);
    values = BackendLiveValues(
      pipe: pipe,
      keyMappings: _mappings(),
      logger: _quiet(),
    );
  }

  late final _FakePlantLink alpha;
  late final _FakePlantLink beta;
  late final PipeMainEndpoint pipe;
  late final BackendLiveValues values;

  Future<void> tearDown() async {
    await values.dispose();
    pipe.dispose();
    alpha.dispose();
    beta.dispose();
  }
}

relay.DynamicValue _good(Object? v, {DateTime? at}) =>
    relay.DynamicValue(value: v, sourceTime: at);

void main() {
  late _Fixture f;

  setUp(() => f = _Fixture());
  tearDown(() => f.tearDown());

  group('listen and the refcount', () {
    test('a handle is returned for ANY key, and costs nothing until watched',
        () async {
      final handle = f.values.listen(_missingKey);
      final known = f.values.listen(_speedKey);
      await _settle();

      expect(handle.value.value, isNull);
      expect(known.value.quality, relay.Quality.uncertainNotYetKnown);
      expect(f.alpha.subscribes, isEmpty,
          reason: 'a handle nobody is listening to must cost no monitored '
              'item — listen() is not the subscription, the listener is');
      expect(f.pipe.refcountOf(_speedKey), 0);
    });

    test('the first listener subscribes and a second mints no second message',
        () async {
      final handle = f.values.listen(_speedKey);
      handle.addListener(() {});
      await _settle();
      expect(f.alpha.subscribes.map((m) => m.key), <String>[_speedKey],
          reason: 'the presence half: the FIRST watcher must subscribe');

      handle.addListener(() {});
      // A different key in the same breath: the barrier that proves the
      // absence below is a real absence and not a dead implementation.
      f.values.listen(_otherKey).addListener(() {});
      await _settle();

      expect(f.alpha.subscribes.map((m) => m.key), <String>[_speedKey, _otherKey],
          reason: 'a second watcher of one key must mint no second control '
              'message; the PLC is charged once per key, not once per panel');
      expect(f.pipe.refcountOf(_speedKey), 1);
    });

    test('the LAST watcher releases it, and only the last', () async {
      final handle = f.values.listen(_speedKey);
      void first() {}
      void second() {}
      handle.addListener(first);
      handle.addListener(second);
      await _settle();

      handle.removeListener(first);
      await _settle();
      expect(f.alpha.unsubscribes, isEmpty,
          reason: 'one of two watchers leaving must release nothing');
      expect(f.pipe.refcountOf(_speedKey), 1);

      handle.removeListener(second);
      await _settle();
      expect(f.alpha.unsubscribes.map((m) => m.key), <String>[_speedKey],
          reason: 'the last watcher going must release the monitored item at '
              'that instant, not ten minutes later on an idle timer');
      expect(f.pipe.refcountOf(_speedKey), 0);
    });

    test('two callers of listen() share one handle', () {
      expect(identical(f.values.listen(_speedKey), f.values.listen(_speedKey)),
          isTrue);
    });

    test('a watched key carries its value and every later change', () async {
      final handle = f.values.listen(_speedKey);
      var rebuilds = 0;
      handle.addListener(() => rebuilds++);
      await _settle();

      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      expect(handle.value.asInt, 1450);
      expect(handle.value.quality.isGood, isTrue);

      f.alpha.deliver(_speedKey, _good(1600));
      await _settle();
      expect(handle.value.asInt, 1600);
      expect(rebuilds, 2);
    });
  });

  group('subscribe()', () {
    test('the stream mirrors listen() and serves every listener', () async {
      final node = f.values.listen(_speedKey);
      final stream = f.values.subscribe(_speedKey);
      final takers = <Future<List<relay.DynamicValue>>>[
        stream.take(1).toList(),
        stream.take(1).toList(),
      ];
      await _settle();

      f.alpha.deliver(_speedKey, _good(1450));
      final first = await takers[0];
      final second = await takers[1];

      expect(first.single.asInt, 1450);
      expect(second.single, first.single,
          reason: 'a compat adapter that serves only the first listener '
              'silently freezes every widget after it');
      expect(node.value, first.single,
          reason: 'the stream path and the listenable path are two views of '
              'one store; two numbers for one tag is the worst thing this '
              'API can do');
    });

    test('a stream listener drives the same refcount as a handle listener',
        () async {
      final subscription = f.values.subscribe(_speedKey).listen((_) {});
      await _settle();
      expect(f.alpha.subscribes.map((m) => m.key), <String>[_speedKey]);

      await subscription.cancel();
      await _settle();
      expect(f.alpha.unsubscribes.map((m) => m.key), <String>[_speedKey]);
    });
  });

  group('read', () {
    test('null until the plant has actually been heard from, then the value',
        () async {
      expect(f.values.read(_speedKey), isNull,
          reason: 'the pipe answers an un-arrived key uncertainNotYetKnown, '
              'which is a real DynamicValue; passing that through as a read '
              'tells a widget a reading exists when none does');

      f.alpha.deliver(_speedKey, _good(0));
      await _settle();

      final cached = f.values.read(_speedKey);
      expect(cached, isNotNull,
          reason: 'the presence half: a genuine zero must survive the cache');
      expect(cached!.asInt, 0);
    });

    test('a key delivered as uncertainNotYetKnown is still not a reading',
        () async {
      f.alpha.deliver(_speedKey,
          relay.DynamicValue(value: null, quality: relay.Quality.uncertainNotYetKnown));
      await _settle();
      expect(f.values.read(_speedKey), isNull);

      f.alpha.deliver(_speedKey,
          relay.DynamicValue(value: null, quality: relay.Quality.badCommFault));
      await _settle();
      expect(f.values.read(_speedKey), isNotNull,
          reason: 'known-to-be-bad is knowledge and must not read as absence');
    });

    test('ten reads cost no round trip, and readFresh costs exactly one',
        () async {
      f.alpha.deliver(_speedKey, _good(1450, at: DateTime.utc(2026, 8, 13)));
      await _settle();

      final before = f.values.roundTrips;
      for (var i = 0; i < 10; i++) {
        f.values.read(_speedKey);
      }
      await _settle();
      expect(f.values.roundTrips, before,
          reason: 'a widget rebuild reads every key it is bound to; a read '
              'that touches the link turns one frame into a traffic burst');

      final fresh = await f.values.readFresh(_speedKey);
      expect(f.values.roundTrips, before + 1,
          reason: 'the presence half: a forced read must actually go and ask, '
              'or it is the cache it exists to bypass');
      expect(fresh.asInt, 1450);
      expect(fresh.sourceTime, isNotNull);
    });
  });

  group('readMany', () {
    test('fifty keys on one worker cost ONE round trip', () async {
      final keys = _diagnosticsKeys();
      f.alpha.deliverAll(<String, relay.DynamicValue>{
        for (var i = 0; i < keys.length; i++) keys[i]: _good(1000 + i),
      });
      await _settle();

      final before = f.values.roundTrips;
      final values = await f.values.readMany(keys);

      expect(f.values.roundTrips, before + 1,
          reason: 'N round trips for N keys is precisely the failure this '
              'project exists to remove');
      expect(values, hasLength(50));
      expect(values[keys.first]!.asInt, 1000);
    });

    test('every requested key comes back, including the empty ones', () async {
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      final values = await f.values.readMany(<String>[_speedKey, _missingKey]);

      expect(values.keys, containsAll(<String>[_speedKey, _missingKey]),
          reason: 'an omitted key is indistinguishable from an unasked one, '
              'so the diagnostics page shows a blank cell for a tag in '
              'trouble');
      expect(values[_speedKey]!.asInt, 1450);
      expect(values[_missingKey]!.quality.isGood, isFalse);
      expect(values[_missingKey]!.quality, relay.Quality.uncertainNotYetKnown);
    });

    test('keys spanning two workers really are two round trips', () async {
      f.alpha.deliver(_speedKey, _good(1));
      f.beta.deliver(_farKey, _good(2));
      await _settle();

      final before = f.values.roundTrips;
      await f.values.readMany(<String>[_speedKey, _farKey]);

      expect(f.values.roundTrips, before + 2,
          reason: 'the fan-out is real and the counter must say so rather '
              'than flatter the caller');
    });
  });

  group('keys', () {
    test('lists the key mappings plus the PIPE roster, and nothing else', () {
      expect(f.values.keys, contains(_speedKey));
      expect(f.values.keys, contains(relay.PipeKeys.connected));
      expect(f.values.keys, isNot(contains(_missingKey)),
          reason: 'offering a key the source has never served sends whoever '
              'draws the next page to bind a permanently empty box');
    });
  });

  group('the unknown key and the retired key read differently', () {
    test('an unknown key is uncertain, never errorConfig, and throws nothing',
        () async {
      Object? thrown;
      relay.ValueListenable<relay.DynamicValue>? handle;
      try {
        handle = f.values.listen(_missingKey);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNull);

      var rebuilds = 0;
      handle!.addListener(() => rebuilds++);
      await _settle();

      expect(handle.value.value, isNull);
      expect(handle.value.quality.isGood, isFalse);
      expect(handle.value.quality, isNot(relay.Quality.errorConfig),
          reason: 'a key whose first batch has not arrived must not read as a '
              'deleted tag. One heals by itself and the other never will, and '
              'they call for opposite actions from the operator');
      expect(rebuilds, 0);
    });

    test('a retired key IS errorConfig', () async {
      final handle = f.values.listen(_deletedKey);
      handle.addListener(() {});
      f.beta.deliver(_deletedKey, _good(1));
      await _settle();

      f.beta.retire(_deletedKey);
      await _settle();

      expect(handle.value.quality, relay.Quality.errorConfig,
          reason: 'waiting will never fix a renamed tag; the operator needs '
              'to be told to fix the page');
      expect(f.values.read(_deletedKey)!.quality, relay.Quality.errorConfig);
    });
  });

  group('IN-02: retirement retracts the subscription', () {
    test('a retired key is unsubscribed by the adapter, so the drain timer '
        'disarms', () async {
      f.values.listen(_deletedKey).addListener(() {});
      f.values.listen(_farKey).addListener(() {});
      await _settle();
      expect(f.beta.subscribes.map((m) => m.key),
          <String>[_deletedKey, _farKey],
          reason: 'fixture precondition');

      f.beta.retire(_deletedKey);
      await _settle();

      expect(f.beta.unsubscribes.map((m) => m.key), <String>[_deletedKey],
          reason: 'IN-02: the worker leaves a retired key in its own '
              '_subscribed set and only _unsubscribe runs _disarmTickIfIdle, '
              'so without this PipeUnsubscribe the 50ms drain timer stays '
              'armed for the life of the process');
      expect(f.pipe.refcountOf(_deletedKey), 0);
      expect(f.pipe.refcountOf(_farKey), 1,
          reason: 'the sibling key on the same worker is untouched');
    });

    test('a retired key is not silently re-subscribed by a later watcher',
        () async {
      final handle = f.values.listen(_deletedKey);
      void watcher() {}
      handle.addListener(watcher);
      await _settle();
      f.beta.retire(_deletedKey);
      await _settle();
      handle.removeListener(watcher);
      f.beta.received.clear();

      handle.addListener(() {});
      await _settle();

      expect(f.beta.subscribes, isEmpty,
          reason: 'the tag is gone; re-creating a monitored item for it puts '
              'the drain timer straight back where IN-02 found it');
      expect(handle.value.quality, relay.Quality.errorConfig,
          reason: 'and the handle keeps saying so — the operator must go on '
              'seeing that the tag was deleted');
    });
  });

  group('the PIPE health keys', () {
    test('connected is seeded true at construction and read synchronously', () {
      final connected = f.values.read(relay.PipeKeys.connected);
      expect(connected, isNotNull,
          reason: 'a health indicator that reads "unknown" until the first '
              'fault tells an operator nothing at the moment they most need '
              'telling');
      expect(connected!.asBool, isTrue);
    });

    test('a health key is subscribable exactly like a plant tag, and costs no '
        'monitored item', () async {
      final handle = f.values.listen(relay.PipeKeys.connected);
      var rebuilds = 0;
      handle.addListener(() => rebuilds++);
      await _settle();

      expect(f.alpha.subscribes, isEmpty);
      expect(f.beta.subscribes, isEmpty,
          reason: 'no worker owns a PIPE key, so nothing may be asked of one');

      f.values.announceLinkLoss('the plant link went away');
      expect(handle.value.asBool, isFalse);
      expect(rebuilds, 1,
          reason: 'the presence half: the same handle, the same store, the '
              'same notification arithmetic as a temperature');
    });

    test('no PIPE. literal is spelled in the implementation', () {
      // Guarded here as well as in the acceptance grep: `pipe_keys.dart`'s
      // whole argument is that a second spelling compiles, keeps every suite
      // green and quietly stops matching every AlarmMan deployment.
      expect(relay.PipeKeys.isPipeKey(relay.PipeKeys.connected), isTrue);
      expect(BackendLiveValues.healthKeys.every(relay.PipeKeys.isPipeKey),
          isTrue);
    });
  });

  group('link loss and recovery', () {
    test('a mass degradation is announced ONCE, not once per key', () async {
      f.alpha.deliverAll(<String, relay.DynamicValue>{
        _speedKey: _good(1),
        _otherKey: _good(2),
      });
      await _settle();
      final before = f.values.statusNotifications;

      f.values.announceLinkLoss('link down');

      expect(f.values.statusNotifications, before + 1,
          reason: 'Sparkplug sends one NDEATH for a whole node: 1500 status '
              'events for one event is a denial of service against the '
              'operator\'s own screen');
      expect(f.values.read(_speedKey)!.quality, relay.Quality.badCommFault);
      expect(f.values.read(_otherKey)!.quality, relay.Quality.badCommFault,
          reason: 'the presence half: a mimic with half its boxes greyed '
              'sends somebody to the wrong end of the building');
    });

    test('a key nothing was ever heard about stays not-yet-known', () async {
      f.values.announceLinkLoss('link down');
      expect(f.values.read(_farKey), isNull,
          reason: 'a key that has never been known cannot be degraded; '
              'notYetKnown remains the honest answer for it');
    });

    test('recovery is a snapshot, and it is announced once', () async {
      f.alpha.deliver(_speedKey, _good(1));
      f.values.listen(_speedKey).addListener(() {});
      await _settle();
      f.values.announceLinkLoss('link down');
      final before = f.values.statusNotifications;

      f.values.announceLinkUp();
      await _settle();

      expect(f.values.statusNotifications, before + 1);
      expect(f.values.read(relay.PipeKeys.connected)!.asBool, isTrue);
      expect(f.values.read(_speedKey)!.quality, relay.Quality.good,
          reason: 'the resync re-delivers the real reading rather than '
              'leaving the key degraded until it next happens to move');
    });
  });

  group('the 13-07 / 13-08 mutation surface', () {
    test('markStale badges the last known reading without losing it',
        () async {
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      f.values.markStale(<String>[_speedKey, _missingKey]);

      // badStale, not uncertainLastKnown: the two are named in `quality.dart`
      // as the pair that must stay distinct, and markStale is only ever called
      // once the freshness deadline has demonstrably passed. 13-07 corrected
      // this against the freshness contract, which asserts the code by name.
      expect(f.values.read(_speedKey)!.quality, relay.Quality.badStale);
      expect(f.values.read(_speedKey)!.asInt, 1450,
          reason: 'stale means "this number is old", not "there is no number"');
      expect(f.values.read(_missingKey), isNull,
          reason: 'a key nothing arrived for cannot go stale');
    });

    test('markStale never improves a key that already carries worse news',
        () async {
      f.alpha.deliver(
          _speedKey,
          relay.DynamicValue(
              value: 1450, quality: relay.Quality.badCommFault));
      await _settle();

      f.values.markStale(<String>[_speedKey]);

      expect(f.values.read(_speedKey)!.quality, relay.Quality.badCommFault,
          reason: 'rewriting badCommFault to badStale swaps "the link is '
              'sick, waiting may fix it" for a weaker and less actionable '
              'claim, and quality never improves on its own');
    });

    test('markStale never touches a health key', () async {
      f.values.markStale(<String>[relay.PipeKeys.connected]);
      expect(f.values.read(relay.PipeKeys.connected)!.quality,
          relay.Quality.good,
          reason: 'HLTH-02: a health key changes on events, so it is always '
              'older than any freshness deadline and is exempt by prefix');
    });

    test('markPending badges, clearPending drops the badge without asserting '
        'an outcome', () async {
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      f.values.markPending(_speedKey);
      expect(f.values.read(_speedKey)!.quality, relay.Quality.goodWritePending);
      expect(f.values.read(_speedKey)!.asInt, 1450);

      f.values.clearPending(_speedKey);
      expect(f.values.read(_speedKey)!.quality, relay.Quality.uncertainLastKnown,
          reason: 'the write\'s fate is unknown, so what is on screen is the '
              'last known reading and nothing stronger');
    });

    test('applyReadback records the confirmed post-write reading', () async {
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();

      f.values.applyReadback(_speedKey, _good(1600));

      expect(f.values.read(_speedKey)!.asInt, 1600);
      expect(f.values.read(_speedKey)!.quality, relay.Quality.good);
    });
  });

  group('staleAfter', () {
    test('is declared, positive, and long enough for a real pipe tick', () {
      expect(f.values.staleAfter, greaterThan(kPipeDrainInterval * 10),
          reason: 'a deadline a healthy pipe cannot meet badges a working '
              'plant stale, which teaches operators that grey means nothing');
      expect(f.values.staleAfter, kBackendStaleAfter);
    });
  });

  group('dispose', () {
    test('releases every refcount and notifies nobody afterwards', () async {
      final handle = f.values.listen(_speedKey);
      var rebuilds = 0;
      handle.addListener(() => rebuilds++);
      await _settle();
      f.alpha.deliver(_speedKey, _good(1450));
      await _settle();
      expect(rebuilds, 1, reason: 'the presence half');

      await f.values.dispose();
      await _settle();

      expect(f.alpha.unsubscribes.map((m) => m.key), <String>[_speedKey],
          reason: 'every monitored item this adapter was paying for must be '
              'released; a client going away must not leave the PLC billing');
      expect(f.pipe.refcountOf(_speedKey), 0);

      f.alpha.deliver(_speedKey, _good(1600));
      await _settle();
      expect(rebuilds, 1,
          reason: 'a disposed source that still fires keeps a closed page '
              'alive and rebuilding for the rest of the session');
    });

    test('does NOT shut the pipe down, and is idempotent', () async {
      await f.values.dispose();
      await f.values.dispose();
      await _settle();

      // The pipe still works: it is not this adapter's to kill.
      f.alpha.deliver(_otherKey, _good(9));
      await _settle();
      expect(f.pipe.read(_otherKey).asInt, 9,
          reason: 'killing the plant\'s acquisition isolates because a relay '
              'client went away is not this class\'s decision');
    });

    test('drops the pipe\'s retirement hook so a later retirement is not '
        'routed into a dead adapter', () async {
      await f.values.dispose();
      expect(f.pipe.onKeyRetired, isNull);
    });
  });

  // ------------------------------------------------------ the contract, early
  //
  // The 13 checks a source whose only working half is the value path already
  // owes. The kit exports each sub-suite separately for exactly this: "a source
  // with only the value path working can run runSubscribeContract alone on day
  // one." The kit's umbrella suite is deliberately NOT called here — that is
  // 13-09's, and calling it now would register write, browse, data-services
  // and hold cases against collaborators that do not exist yet, and pollute
  // `contractCasesRegistered`. Its name is not even spelled in this file, so
  // the pin that says so is a grep.
  //
  // **Why `linkUp` is free here.** The barrier reads `PipeKeys.connected` and
  // returns the instant it is true. `BackendLiveValues` seeds it true at
  // construction, so the barrier is a synchronous read with nothing attached
  // and nothing awaited. If one of these cases ever hangs on the link coming
  // up, the health seeding is the bug — not the barrier.
  runSubscribeContract(makeHarnessedBackendStateMan);
  runStoreContract(makeHarnessedBackendStateMan);
  runReadContract(makeHarnessedBackendStateMan);
}

// ------------------------------------------------------------ the harness leg
//
// **13-09 consolidated it.** The four wave-2/3 copies of this class
// (`_HarnessedLiveValues` here, `_HarnessedFreshBackend`,
// `_HarnessedWriteBackend`, `_HarnessedHoldBackend`) are now one file,
// `test/support/harnessed_backend_state_man.dart`, and the three sub-suites
// above run against it. The shared subject composes MORE than this plan built
// — the sweep, the write router and the mapping-backed browse — which is
// strictly stronger for these thirteen checks: a value-path property that only
// holds when nothing else is wired is not a property.
