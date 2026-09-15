/// The one harness every backend contract leg builds on.
///
/// Waves 2 and 3 each grew a local copy — `_HarnessedLiveValues` (13-03),
/// `_HarnessedFreshBackend` (13-07), `_HarnessedWriteBackend` and
/// `_HarnessedHoldBackend` (13-08) — because a shared helper edited by two
/// plans in one wave is a merge conflict in the one file every contract leg
/// depends on. Each of those files said, in as many words, that 13-09 would
/// consolidate them. This is that file.
///
/// ## Every lever is a frame crossing the real pipe
///
/// Nothing here pokes a map the adapter reads. `setValue` and `setValues` put
/// a `PipeFrame` on a fake worker's stream, `setQuality` re-sends the cached
/// reading under a new quality, `dropKey` sends a `PipeKeyRetired`, and the
/// write levers are answered by the fake plant on the priority lane the way an
/// acquisition isolate answers. A lever that assigned into the adapter's own
/// store would turn fifty-one contract checks into a test of a stub — which is
/// T-13-09-c, and the reason `harnessed_local_state_man.dart` is the
/// precedent this file follows rather than inventing its own shortcut.
///
/// ## disconnectUpstream is the ANNOUNCEMENT, not an isolate death
///
/// 13-07's Finding 1, carried forward verbatim: `PipeMainEndpoint._markBad`
/// writes `badCommFault` with a **null** payload (12-08 asserts it, mutation
/// C), while `checkUpstreamLossDegradesAffectedKeys` requires the opposite —
/// *"the last known reading must survive the link loss, so the operator can
/// see what the plant was doing when contact was lost"*. Both promises are
/// deliberate and they genuinely disagree; neither is this plan's to overrule.
/// So [HarnessedBackendStateMan.disconnectUpstream] drives
/// `BackendValueSource.announceLinkLoss`, the surface the seam declares for
/// exactly this, and the isolate-death path keeps its own arms in
/// `backend_freshness_test.dart`. The write contract reaches the death path
/// anyway through the explicit `dropLinkWithWritesInFlight` hook, which is
/// [HarnessedBackendStateMan.killUpstreamWorker].
///
/// ## The composition is the shipping one
///
/// `BackendStateMan` over `BackendLiveValues` wrapped in `BackendFreshnessSweep`,
/// with `BackendWrites` (which carries the deadman) and `BackendBrowse` — at
/// the PRODUCTION `kBackendStaleAfter`, so the freshness and hold cases are
/// judged against the deadline the plant gets rather than a convenient one.
/// The three data services are parameters: null on the offline lane, real
/// objects over a real `Database` on the `db` lane. That split is the rule
/// `contract_db_test.dart:32-38` states and this package inherits —
/// **`dart test --exclude-tags db` must not need a database.**
library;

import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_browse.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_state_man.dart';
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show StateManApi;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show
        StateManDataHarness,
        StateManHarness,
        StateManHoldHarness,
        StateManWriteHarness;

// ---------------------------------------------------------------- the keys
//
// Spelled exactly as the kit spells them. A key outside the kit's vocabulary
// is a key the pipe leaves unrouted, and an unrouted key reads `errorConfig`
// with a null payload — the right answer to a mistyped tag and the wrong
// answer to a case that is asking about something else entirely.

/// A motor speed on the pre-freezer conveyor line: the ordinary live key.
const String contractSpeedKey = 'ST101.CN01.MOT01.speed';

/// The ordinary writable, and the deadman's tag.
const String contractSetpointKey = 'ST101.CN01.MOT01.setpoint';

/// The sensor `write_contract.dart` and `hold_contract.dart` both name as the
/// key a device refuses.
const String contractSensorKey = 'ST301.CN07.SEN01.temp';

/// A key that exists and is then retired — the tag deleted in the PLC.
const String contractDeletedKey = 'ST301.CN18.VLV01.stat';

/// The designated read-only key.
///
/// **Identical to the other four legs by necessity, not tidiness.**
/// `ws_contract_test.dart:64` and `harnessed_local_state_man.dart:122` name
/// this exact string; a leg that judged a different set of cases would make a
/// parity sweep across legs meaningless, and a leg that named none at all
/// would silently drop `checkReadOnlyKeyIsRejectedNotThrown` and report the
/// drop as a capability switched off — correctly, because it would be one.
const String contractReadOnlyKey = 'ST301.CN21.SEN01.temp';

/// The one key this harness declares to be a callable.
///
/// **13-04 Finding 1, and it is load-bearing.** `KeyMappingEntry` has no
/// callable concept, so a mapping-backed tree cannot type a node `method` from
/// the mapping alone however it is written. `BackendBrowse` therefore takes a
/// declared set, production passes NONE (a true statement about SVN's address
/// space), and the harness passes one so
/// `checkBrowseNodeTypesDistinguishFoldersFromVariables` runs against a real
/// code path instead of going red with no bug behind it. That asymmetry is
/// deliberate and recorded; do not "fix" it by teaching the mapping about
/// methods.
const Set<String> contractMethodKeys = <String>{'ST101.CN01.MOT01.reset'};

/// Every key the fifty-one checks name, generated families included.
///
/// The generated ones are not decoration: `store_contract.dart` seeds a
/// hundred-key batch, `read_contract.dart` reads fifty at once and
/// `freshness_contract.dart` mass-degrades fifty.
///
/// `ST301.CN17.VLV02.stat` is DELIBERATELY ABSENT. It is the kit's designated
/// missing key — `subscribe_contract.dart:46`, `read_contract.dart:43` and
/// `store_contract.dart:37` all name it, to assert that an unmapped key
/// reports as unknown rather than throwing and that `keys` lists what the
/// source can serve **and nothing else**. Mapping it would make three cases
/// judge a key that exists.
///
/// **13-03 Finding 1 lives here too.** The contract, not a plan's prose, is the
/// judge: a key nothing has arrived for is `uncertainNotYetKnown` and absent
/// from `keys`; only a RETIRED key is `errorConfig`. Adding the missing key to
/// this list to make it "report a configuration error" turns five checks red
/// for no reason.
List<String> contractPlantKeys() => <String>{
      contractSpeedKey,
      contractSetpointKey,
      'ST101.CN01.MOT01.running',
      'ST101.CN01.MOT01.reset',
      'ST201.CN04.MOT01.speed',
      'ST201.CN04.MOT01.setpoint',
      'ST201.CN04.MOT01.running',
      contractSensorKey,
      contractDeletedKey,
      contractReadOnlyKey,
      // store_contract's hundred-key batch.
      for (var i = 0; i < 100; i++)
        'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
      // read_contract's fifty-tag diagnostics page.
      for (var i = 1; i <= 50; i++)
        'ST201.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
      // freshness_contract's fifty-key mass degradation.
      for (var i = 1; i <= 50; i++)
        'ST301.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    }.toList();

/// The key mapping the leg routes through.
///
/// One entry per routed key, and no entry for anything else: `keys` is derived
/// from this map, and the store contract holds it to listing exactly what the
/// source can serve.
KeyMappings contractKeyMappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in contractPlantKeys())
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key)
            ..serverAlias = key.split('.').first,
        ),
    });

/// The snapshot the plant has already published when a case starts.
///
/// **Why anything is pre-delivered at all.**
/// `checkFetchDetailDescribesTheNode` asserts that the detail of
/// `defaultBrowseFixture.variableId` carries a data type *and a current
/// reading* — "the reading is how an engineer confirms they are looking at the
/// tag they meant before they bind a button to it". `BackendBrowse` derives
/// both from the pipe's cache through its `readValue` seam, so a leg whose
/// plant had never said anything would fail that check with a message about a
/// detail pane when the fact is that nothing had been heard from the PLC.
///
/// A real backend is never in that state for long: a worker subscribes and the
/// first publishing interval delivers a snapshot. This is that snapshot, sent
/// as an ordinary frame down the ordinary path — not a map handed to the
/// adapter.
///
/// Deliberately short. It covers the browse fixture's two motors and nothing
/// else: `ST101.CN01.MOT01.speed` and the fifty/hundred-key families are left
/// unheard-of because `checkSyncReadIsNullBeforeFirstValue` and the store's
/// batch cases are about exactly that state.
Map<String, relay.DynamicValue> contractInitialSnapshot() =>
    <String, relay.DynamicValue>{
      contractSetpointKey: relay.DynamicValue(value: 1200.0),
      'ST101.CN01.MOT01.running': relay.DynamicValue(value: true),
      'ST101.CN01.MOT01.reset': relay.DynamicValue(value: false),
      'ST201.CN04.MOT01.setpoint': relay.DynamicValue(value: 17.0),
      'ST201.CN04.MOT01.running': relay.DynamicValue(value: false),
    };

Logger _quiet() => Logger(level: Level.off);

relay.DynamicValue _good(Object? value) =>
    relay.DynamicValue(value: value, quality: relay.Quality.good);

/// One write the fake plant has taken but not yet answered.
typedef _Parked = ({int id, String key, relay.DynamicValue value});

/// What the plant will say to the next write, once.
typedef _NextAnswer = ({relay.WriteReason reason, bool unknown});

/// A worker main can talk to, with no isolate behind it — and a plant that has
/// opinions about writes.
///
/// Lifted from `backend_writes_test.dart`, which is the richest of the four
/// wave-2/3 copies. It remembers the last reading per key (so a
/// [PipeResnapshot] can be answered), and it answers a [PipeWriteRequest] on
/// the priority lane the way an acquisition worker does: applied with a
/// readback, refused with a named reason, or lost.
final class FakePlantLink implements PipeWorkerLink {
  FakePlantLink(this.name) {
    _port.listen(_onControl);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  final List<Object?> received = <Object?>[];
  final List<PipeWriteRequest> writes = <PipeWriteRequest>[];
  final Map<String, relay.DynamicValue> last = <String, relay.DynamicValue>{};
  final Set<String> readOnly = <String>{};
  final List<_Parked> parked = <_Parked>[];

  bool down = false;
  bool stalled = false;
  _NextAnswer? _failNext;
  bool _hasClamp = false;
  Object? _clamp;

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

  void deliverAll(Map<String, relay.DynamicValue> values) {
    last.addAll(values);
    final copy = Map<String, relay.DynamicValue>.of(values);
    emit(PipeFrame(const <Object?>[], copy, _substitutedIn(copy)));
  }

  /// The claim the real worker makes per sample, made here per frame.
  ///
  /// `PipeFrame.substitutedStamps == null` means "this frame states nothing",
  /// which main reads — by pinned design (`stamp_substitution_flag_test.dart`,
  /// "a frame that states nothing is read as substituted") — as every value
  /// substituted. A fake plant that stamps a `sourceTime` and then states
  /// nothing therefore demotes its own stamp to `backendReceipt`, which is how
  /// `alarm_ack_e2e_test.dart` arms 2/4/5 came to read the injected clock
  /// where the plant instant belonged.
  ///
  /// Deriving the claim from `sourceTime` is honest in THIS class and nowhere
  /// else: the real worker cannot (`translateOpcUaSample` substitutes a real,
  /// non-null `arrivedAt`, so it tracks the fact separately in
  /// `PipeWorkerEndpoint._lastSubstituted`), but nothing on the fake's path
  /// substitutes anything — a null stays null — so here "carries an instant"
  /// and "the source stamped it" are the same fact.
  static Set<String> _substitutedIn(Map<String, relay.DynamicValue> values) =>
      <String>{
        for (final entry in values.entries)
          if (entry.value.sourceTime == null) entry.key,
      };

  void deliver(String key, relay.DynamicValue value) =>
      deliverAll(<String, relay.DynamicValue>{key: value});

  /// The device says no to the next write only.
  void failNext(relay.WriteReason reason, {bool unknown = false}) =>
      _failNext = (reason: reason, unknown: unknown);

  /// The next write is taken, but the device ends up holding [readback].
  void clampNext(Object? readback) {
    _hasClamp = true;
    _clamp = readback;
  }

  /// Writes go upstream and no answer comes back. The in-flight window.
  void stall() => stalled = true;

  /// Ends the stall and settles everything parked by it.
  void release({bool applied = true}) {
    stalled = false;
    final pending = List<_Parked>.of(parked);
    parked.clear();
    for (final write in pending) {
      if (applied) {
        _answer(write.id, write.key, write.value);
      } else {
        emit(PipeFrame(<Object?>[
          PipeWriteOutcome(
              write.id,
              relay.WriteUnknown(
                  '${write.id}',
                  const relay.WriteReason('plc_timeout',
                      message: 'the plant never said'))),
        ], const <String, relay.DynamicValue>{}));
      }
    }
  }

  /// The isolate is gone: `null` on the data port, and no control port.
  void die() {
    down = true;
    emit(null);
  }

  void respawn() {
    down = false;
    emit(_port.sendPort);
  }

  void _onControl(Object? message) {
    received.add(message);
    switch (message) {
      case PipeResnapshot(keys: final keys):
        // The claim rides the replay too, or every reconnect would demote a
        // genuine plant stamp — `PipeWorkerEndpoint._lastSubstituted` exists
        // for exactly this on the real path.
        final replay = <String, relay.DynamicValue>{
          for (final key in keys)
            if (last[key] != null) key: last[key]!,
        };
        emit(PipeFrame(const <Object?>[], replay, _substitutedIn(replay)));
      case PipeWriteRequest(id: final id, key: final key, value: final value):
        writes.add(message);
        if (stalled) {
          parked.add((id: id, key: key, value: value));
          return;
        }
        _answer(id, key, value);
      default:
        break;
    }
  }

  void _answer(int id, String key, relay.DynamicValue value) {
    final result = _decide('$id', key, value);
    if (result is relay.WriteApplied) {
      last[key] = _good(result.readback);
    }
    emit(PipeFrame(<Object?>[PipeWriteOutcome(id, result)],
        const <String, relay.DynamicValue>{}));
  }

  relay.WriteResult _decide(String cmd, String key, relay.DynamicValue value) {
    if (readOnly.contains(key)) {
      return relay.WriteRejected(
          cmd,
          const relay.WriteReason('not_writable',
              message: 'this device does not accept writes',
              status: 'Bad_NotWritable'),
          at: DateTime.now().millisecondsSinceEpoch);
    }
    final failure = _failNext;
    _failNext = null;
    if (failure != null) {
      return failure.unknown
          ? relay.WriteUnknown(cmd, failure.reason)
          : relay.WriteRejected(cmd, failure.reason,
              at: DateTime.now().millisecondsSinceEpoch);
    }
    final clamped = _hasClamp;
    final clamp = _clamp;
    _hasClamp = false;
    _clamp = null;
    return relay.WriteApplied(cmd,
        readback: clamped ? clamp : value.value,
        at: DateTime.now().millisecondsSinceEpoch);
  }

  void dispose() {
    _port.close();
    if (!_out.isClosed) _out.close();
  }
}

// ------------------------------------------------------------- the subject

/// A fresh subject for one contract case, on the offline lane.
///
/// The fixture's teardown is registered here rather than folded into
/// [HarnessedBackendStateMan.dispose], because `checkDisposeStopsNotifications`
/// and `checkDisposingTheSourceReleasesTheHold` both dispose the API **inside**
/// the case and then pull a plant lever: if disposing the adapter also tore the
/// fake worker down, that lever would be a no-op and the case would pass for
/// the wrong reason.
StateManApi makeHarnessedBackendStateMan() {
  final subject = buildHarnessedBackendStateMan();
  addTearDown(subject.shutdownFixture);
  return subject;
}

/// The same subject, optionally with the three data services behind it.
///
/// Two legs share this body and differ in exactly one thing: whether a
/// database was composed in. `backend_contract_test.dart` passes nothing and
/// stays in the offline lane; `backend_contract_db_test.dart` passes 13-05's
/// three classes over a real TimescaleDB and a [recorder] that puts rows in
/// front of the reader.
///
/// [recorder] is the async half of `StateManDataHarness.seedTimeseries`. The
/// kit's lever returns `void` — it was written for an in-memory fake, where
/// recording a sample is a map assignment — and a real recorder is a database
/// round trip. See [HarnessedBackendStateMan.seedTimeseries] for how the two
/// are reconciled without the case having to know.
HarnessedBackendStateMan buildHarnessedBackendStateMan({
  relay.TimeseriesApi? timeseries,
  relay.HistoryViewApi? historyViews,
  relay.PreferencesApi? preferences,
  Future<void> Function(String tableName, List<relay.TimeseriesData> points)?
      recorder,
}) {
  final plant = FakePlantLink('contract');
  // One link, not two, mirroring 13-03's and 13-07's harnesses for the
  // identical reason: `StateManHarness.disconnectUpstream()` takes no alias,
  // and two links would make "a mass degradation is announced once" and "a
  // mass degradation degrades every affected key" contradict each other. The
  // multi-worker fan-out keeps its own arms in `backend_live_values_test.dart`
  // and `backend_freshness_test.dart`, with real second workers.
  final pipe = PipeMainEndpoint(
    writeDeadline: const Duration(milliseconds: 400),
    logger: _quiet(),
  );
  pipe.addWorker(plant, contractPlantKeys());

  final values = BackendLiveValues(
    pipe: pipe,
    keyMappings: contractKeyMappings(),
    logger: _quiet(),
  );
  // The PRODUCTION deadline. `kBackendStaleAfter` is chosen from above
  // D-12-08-a's measured ~9 s blackhole window (13-03), and lowering it here
  // to make the leg faster would judge the sweep at a deadline the plant never
  // sees.
  final sweep = BackendFreshnessSweep(
    values: values,
    staleAfter: values.staleAfter,
    pipe: pipe,
    logger: _quiet(),
  );
  // The sweep, not the raw values: the write path's `markPending`,
  // `clearPending` and `applyReadback` have to land on the object the API
  // hands out handles from, or a pending badge would be invisible to the
  // listener that is watching for it.
  // Derived from the contract's own mappings, exactly as the composition root
  // derives it from the plant's: none of the contract's keys is an array
  // element or a bit field, so the set is empty here — and it is DERIVED
  // rather than spelled `{}`, so a contract mapping that grows one is guarded
  // without anybody remembering to come back here.
  final writes = BackendWrites(
    pipe: pipe,
    values: sweep,
    readModifyWriteKeys: readModifyWriteKeysOf(contractKeyMappings()),
    logger: _quiet(),
  );
  final browse = BackendBrowse(
    keyMappings: contractKeyMappings(),
    readValue: sweep.read,
    methodKeys: contractMethodKeys,
  );

  final api = BackendStateMan(
    values: sweep,
    writes: writes,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
  );

  // The plant's first publishing interval, as an ordinary frame.
  plant.deliverAll(contractInitialSnapshot());

  return HarnessedBackendStateMan(
    api,
    pipe: pipe,
    plant: plant,
    values: sweep,
    writes: writes,
    recorder: recorder,
  );
}

/// `BackendStateMan` plus the test-only control surface, and nothing else.
///
/// Every member of `StateManApi` is forwarded by hand rather than through a
/// `noSuchMethod`: a member added to the interface in a later phase becomes a
/// compile error here instead of silently arriving unpoliced.
final class HarnessedBackendStateMan
    implements
        StateManApi,
        StateManHarness,
        StateManWriteHarness,
        StateManDataHarness,
        StateManHoldHarness {
  HarnessedBackendStateMan(
    this._api, {
    required this.pipe,
    required this.plant,
    required this.values,
    required this.writes,
    Future<void> Function(String tableName, List<relay.TimeseriesData> points)?
        recorder,
  }) : _recorder = recorder;

  final BackendStateMan _api;

  /// The real pipe every lever's frame crosses.
  final PipeMainEndpoint pipe;

  /// The fake worker on the other side of it.
  final FakePlantLink plant;

  /// The value source the API hands handles out from — the sweep.
  final BackendFreshnessSweep values;

  /// The write router, for the upstream-attempt observable.
  final BackendWrites writes;

  /// Where a seeded sample actually goes, or null on a leg with no recorder.
  final Future<void> Function(
      String tableName, List<relay.TimeseriesData> points)? _recorder;

  /// Everything [seedTimeseries] has been asked for, in order, as one future.
  Future<void> _seeded = Future<void>.value();

  /// Tears the *fixture* down — never called by a case, only by `addTearDown`.
  void shutdownFixture() {
    pipe.dispose();
    plant.dispose();
  }

  // ------------------------------------------------------ the nine kit levers

  @override
  void setValue(String key, Object? value,
      {relay.Quality quality = relay.Quality.good, DateTime? sourceTime}) {
    plant.deliver(
        key,
        relay.DynamicValue(
            value: value, quality: quality, sourceTime: sourceTime));
  }

  @override
  void setValues(Map<String, Object?> values) {
    // ONE frame, not a loop of single delivers: the batch is the unit the
    // notification-count promise is made about, and a loop here would turn a
    // hundred-key arrival into a hundred passes over the store — the very
    // shape `checkBatchNotifiesOncePerChangedKey` is watching for.
    plant.deliverAll(<String, relay.DynamicValue>{
      for (final entry in values.entries)
        entry.key: relay.DynamicValue(value: entry.value),
    });
  }

  @override
  void setQuality(String key, relay.Quality quality) {
    final cached = pipe.store.peek(key);
    plant.deliver(
        key,
        relay.DynamicValue(
          value: cached?.value,
          quality: quality,
          sourceTime: cached?.sourceTime,
        ));
  }

  @override
  void dropKey(String key) => plant.emit(PipeFrame(
      <Object?>[PipeKeyRetired(key)], const <String, relay.DynamicValue>{}));

  /// The announcement, not an isolate death — 13-07's Finding 1.
  ///
  /// See this library's doc. The pipe's death path drops the payload and the
  /// contract requires the last reading to survive; the disagreement is
  /// recorded rather than smoothed over, and the lever drives the surface the
  /// seam declares for exactly this. [killUpstreamWorker] is the other half.
  @override
  void disconnectUpstream() =>
      values.announceLinkLoss('the contract harness pulled the upstream link');

  @override
  void reconnectUpstream() => values.announceLinkUp();

  /// The worker isolate actually dies — the write contract's link-loss lever.
  ///
  /// Passed to `runStateManContract` as `dropLinkWithWritesInFlight`, because
  /// `checkLostLinkYieldsUnknownNeverFailure` is about what happens to a
  /// command that was out when the channel went, and an announcement does not
  /// settle a parked write.
  void killUpstreamWorker() => plant.die();

  @override
  Duration get staleAfter => values.staleAfter;

  @override
  int get roundTrips => values.roundTrips;

  @override
  int get statusNotifications => values.statusNotifications;

  // ------------------------------------------------ the write harness levers

  @override
  void failNextWrite(relay.WriteReason reason, {bool unknown = false}) =>
      plant.failNext(reason, unknown: unknown);

  @override
  void clampNextWrite(Object? readback) => plant.clampNext(readback);

  @override
  void stallWrites() => plant.stall();

  @override
  void releaseWrites({bool applied = true}) => plant.release(applied: applied);

  @override
  void setReadOnly(String key, bool readOnly) {
    if (readOnly) {
      plant.readOnly.add(key);
    } else {
      plant.readOnly.remove(key);
    }
  }

  @override
  int upstreamWriteAttempts(String cmd) => writes.upstreamAttempts(cmd);

  @override
  List<String> get mintedCmds => writes.mintedCmds;

  // -------------------------------------------------- the hold harness lever

  /// The deadman counter arriving on the tag, the way the plant would see it.
  ///
  /// **Found by the WebSocket leg (13-11), and invisible to the in-memory one.**
  /// In process, a case feeds a deadman by calling `tick()` on the handle
  /// `BackendHoldRegistry` returned, and that handle writes the counter down
  /// the pipe itself — this seam is never consulted, which is why five hold
  /// checks were green for two plans against a harness that did not implement
  /// it. Across a channel the tick cannot travel as a handle: `ChannelStateMan`
  /// mints the counter on the client and posts a `holdTick` notification, and
  /// `ServedStateMan._holdTick` applies it through **this** method. Without it,
  /// `holdHarnessOf` fails inside a notification handler, the failure goes to
  /// `onUnhandledError` and is swallowed by design, and every tick is silently
  /// dropped — the tag sits at 1 while the client's handle counts up, which is
  /// precisely the "silence, not success" shape the milestone exists to refuse.
  ///
  /// A plant frame and **never** the write path, as `hold_harness.dart:23-30`
  /// requires: ten ticks a second through `write` would mint ten command ids a
  /// second and inflate the upstream-attempt count that "a write is never
  /// auto-retried" is measured with.
  @override
  void applyHoldTick(String key, int counter) =>
      plant.deliver(key, _good(counter));

  // ------------------------------------------------- the data harness lever

  /// Queues a recording, and lets [timeseries] wait for it.
  ///
  /// The kit's lever returns `void` and the case that calls it does this:
  ///
  /// ```dart
  /// seed(api, _table, _minutely(base, 7));
  /// final got = await within(api.timeseries.queryTimeseriesData(...), '…');
  /// ```
  ///
  /// — no await between the two, and none available to be written. So the
  /// settling happens where the *reader* is: the work is queued here and
  /// [timeseries] waits for it before it answers. Chained rather than
  /// collected, because `Database` buffers per table and flushes on a count,
  /// so two concurrent seeders would each flush the other's rows and neither
  /// would know when its own were on disk.
  @override
  void seedTimeseries(String tableName, List<relay.TimeseriesData> points) {
    final recorder = _recorder;
    if (recorder == null) {
      throw UnsupportedError(
          'this leg was composed with no recorder, so it cannot put a sample '
          'in front of the reader. Only the `db` leg passes one: a leg with '
          'no database must declare `supportsDataServices: false` rather than '
          'seed into nothing — see backend_contract_test.dart\'s call site');
    }
    _seeded = _seeded.then((_) => recorder(tableName, points));
  }

  /// Waits for every queued seed, and lets its failure out here.
  Future<void> _settleSeeds() async {
    final queued = _seeded;
    // Reset first: a failed seed must fail the query that needed it and then
    // stop failing every later one, or one broken case reports as three.
    _seeded = Future<void>.value();
    await queued;
  }

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
  relay.TimeseriesApi get timeseries => _recorder == null
      ? _api.timeseries
      : _SeedGatedTimeseries(_api.timeseries, _settleSeeds);

  @override
  relay.HistoryViewApi get historyViews => _api.historyViews;

  @override
  relay.PreferencesApi get preferences => _api.preferences;

  // The four access families are forwarded like everything else, so what a
  // case sees is whatever `BackendStateMan` decided — a refusal today. A
  // refusal minted here instead would hide which object actually has nothing
  // behind it, and would have to be un-minted when 17-06 composes them.
  @override
  relay.AccessTemplateApi get accessTemplates => _api.accessTemplates;

  @override
  relay.AccessAdminApi get accessAdmin => _api.accessAdmin;

  @override
  relay.AuditApi get audit => _api.audit;

  @override
  relay.BackendConfigApi get backendConfig => _api.backendConfig;

  @override
  Future<void> dispose() => _api.dispose();
}

/// The reader, with every queued seed settled before it answers.
///
/// Four methods and no judgement in any of them: this decorator exists to
/// order two things the kit's `void` lever cannot order itself, and a
/// decorator that also filtered, capped or reshaped an answer would be a leg
/// marking its own homework.
final class _SeedGatedTimeseries implements relay.TimeseriesApi {
  _SeedGatedTimeseries(this._inner, this._settle);

  final relay.TimeseriesApi _inner;
  final Future<void> Function() _settle;

  @override
  Future<List<relay.TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    await _settle();
    return _inner.queryTimeseriesData(tableName, to,
        orderBy: orderBy, from: from);
  }

  @override
  Future<Map<String, List<relay.TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    await _settle();
    return _inner.queryTimeseriesDataMultiple(tableNames, to,
        orderBy: orderBy, from: from);
  }

  @override
  Future<List<relay.TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    await _settle();
    return _inner.queryTimeseriesDataDownsampled(tableName, from, to,
        maxPoints: maxPoints);
  }
}
