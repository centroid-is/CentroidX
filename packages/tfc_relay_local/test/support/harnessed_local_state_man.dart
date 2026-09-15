/// The test-only control surface `LocalStateMan` is judged through, and the
/// one-fake-link subject the fourth contract leg runs over.
///
/// ## The levers are here and never on the production class
///
/// `StateManHarness` is `setValue`, `setValues`, `setQuality`, `dropKey`,
/// `disconnectUpstream` and `reconnectUpstream` — six ways to make a value
/// appear or a link fall over. On a class a connected session can reach, those
/// six are an unauthenticated write path into every operator's screen
/// (T-08-42): `setValue('ST101.CN01.MOT01.speed', 0, quality: Quality.good)` is
/// a stopped conveyor that reads as running, minted by the gateway itself and
/// indistinguishable from a real sample. 08-RESEARCH and 08-PATTERNS both say
/// the levers live on a test-only type, and it is worth repeating here because
/// **the shortest path to green is to put them on `LocalStateMan` and it is the
/// wrong one** — the class is `final`, a wrapper is four dozen lines of
/// forwarding, and a member added to the real class would be one line. The
/// `freeze_test.dart` sweep added by 08-11 is what makes that shortcut fail
/// rather than merely be discouraged.
///
/// ## Why a wrapper and not a subclass
///
/// `LocalStateMan` is a `final class`. That is not an obstacle to work around;
/// it is the reason this file forwards every member by hand, which is the same
/// explicit-delegation rule `local_state_man.dart` follows and for the same
/// reason: a member added to `StateManApi` in a later phase becomes a compile
/// error here instead of silently arriving unpoliced through a
/// `noSuchMethod`.
///
/// ## ONE fake upstream link, and the conflict that forces it
///
/// Two freshness checks disagree about what `disconnectUpstream()` may do, and
/// both are right about the property they defend:
///
///  * `checkUpstreamLossDegradesAffectedKeys` calls it **once** and requires
///    *both* `ST101.CN01.MOT01.speed` and `ST201.CN04.MOT01.speed` to degrade
///    — a mimic with half its boxes greyed reads as a plant fault and sends
///    somebody to the wrong end of the building.
///  * `checkUpstreamLossAnnouncesOnce` calls the same lever and requires
///    **exactly one** announcement — Sparkplug sends one NDEATH for a whole
///    node because 1500 status events for one event is a denial of service
///    against the operator's own screen.
///
/// `StateManHarness.disconnectUpstream()` takes no alias. With the two fixture
/// keys on two real links, honouring SRV-08's per-alias degradation makes the
/// second check read two announcements and fail — for doing the right thing.
/// 08-CONTEXT ruling 8 settles it: **the contract leg runs over one fake
/// upstream link with a keymapping routing both fixture keys to that single
/// alias**, so the suite measures what it was written to measure. The
/// multi-link property is not thereby unjudged — `link_loss_test.dart` (08-09)
/// carries it, with a real per-alias degradation and a real per-alias
/// announcement. **Both. Neither substitutes for the other.**
///
/// ## The second link, and why it does not break ruling 8
///
/// There is a second `FakeUpstreamLink` here and it carries exactly one key:
/// the designated read-only one. It exists so
/// `checkReadOnlyKeyIsRejectedNotThrown` earns a **genuine** refusal —
/// `supportsWrites: false` on the link, which is what an M2400 weigher is by
/// protocol — rather than a staged outcome that would pass whatever the write
/// path did. It never disconnects: [StateManHarness.disconnectUpstream]
/// forwards to the plant link alone, so the announce-once arithmetic is
/// untouched and the "one fake upstream link" ruling 8 is about is the one
/// link the loss cases can see.
///
/// The M2400 is the natural device-level read-only and this leg models it with
/// a fake rather than with `M2400StubServer`, because a contract leg must not
/// depend on a stub server's port: fifty checks each standing a listener up is
/// fifty chances for a parallel worktree to lose a race that has nothing to do
/// with the property being judged.
///
/// ## The levers are synchronous, and the store is reached synchronously
///
/// 08-07 recorded that `UpstreamLinkDriver`'s levers are synchronous while the
/// link's own delivery is a broadcast stream, and left the fix to whoever first
/// needed it. This is that plan. The fix is small and it is here: each lever
/// forwards to the fake link **and** applies the same values through
/// `LocalStateMan.applyUpstreamBatch`, the production ingest seam `readMany`
/// already uses. Two reasons, and the first is not convenience:
///
///  1. The fake publishes into a per-key broadcast controller that only exists
///     once something has subscribed. A contract case that seeds fifty keys and
///     *then* listens would seed into nothing — `arrived()` would time out and
///     the failure would name a property nobody broke.
///  2. `StateManHarness.setValue` returns `void`. An async lever is not
///     available to be written, so "settle" has to happen inside the lever.
library;

import 'dart:async';

import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_local/src/data/preference_store.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'package:tfc_dart/core/state_man.dart' show KeyMappings, KeyMappingEntry;

import 'fake_upstream_link.dart';
import 'keymap_fixtures.dart';

// ------------------------------------------------------------------ the plant

/// The plant link's alias.
///
/// Spelled `ST101` because [gatewayBrowseFixture]'s `rootId` is, and the roots
/// of `LocalBrowse` are the aliases: a browse fixture naming a root no link
/// answers to would fail six checks with messages about a tree rather than
/// about the one decision that caused it.
const String contractPlantAlias = 'ST101';

/// The read-only link's alias — a weigher, by protocol and by name.
const String contractWeigherAlias = 'weigher1v';

/// The designated read-only key.
///
/// **Identical to the other three legs by necessity, not tidiness.**
/// `channel_full_contract_test.dart`, `socket_contract_test.dart` and
/// `ws_contract_test.dart` all name this exact string; a leg that judged a
/// different set of cases would make the parity sweep meaningless, and a leg
/// that named none at all would silently drop
/// `checkReadOnlyKeyIsRejectedNotThrown` and report the drop as a capability
/// switched off — correctly, because it would be one.
const String contractReadOnlyKey = 'ST301.CN21.SEN01.temp';

/// The gateway's own browse fixture.
///
/// `runStateManContract`'s doc says the parameter exists for exactly this:
/// *"a gateway browsing a real ST101 over OPC UA passes its own"*. It differs
/// from `defaultBrowseFixture` in one field — `otherFolderId` is
/// `ST101.CN04.MOT01` rather than `ST201.CN04.MOT01` — and the reason is ruling
/// 8 again: with one link there is one root, so the second folder has to live
/// under it. The property the field defends is unchanged, because the two
/// folders still have genuinely different children and a source that returned
/// one canned level for every parent still fails.
const BrowseFixture gatewayBrowseFixture = BrowseFixture(
  rootId: contractPlantAlias,
  folderId: 'ST101.CN01.MOT01',
  folderChildIds: <String>[
    'ST101.CN01.MOT01.setpoint',
    'ST101.CN01.MOT01.running',
    'ST101.CN01.MOT01.reset',
  ],
  otherFolderId: 'ST101.CN04.MOT01',
  variableId: 'ST101.CN01.MOT01.setpoint',
  methodId: 'ST101.CN01.MOT01.reset',
  unknownId: 'ST999.CN99.MOT99.setpoint',
);

/// Every key the fifty checks name, generated families included.
///
/// The generated ones are not decoration: `store_contract.dart` seeds a
/// hundred-key batch, `read_contract.dart` reads fifty at once and
/// `freshness_contract.dart` mass-degrades fifty. A key the keymapping does not
/// carry is a key the router refuses, and a refusal is `Quality.errorConfig`
/// with a null payload — which is the right answer to a mistyped tag and the
/// wrong answer to a case that is asking about something else entirely.
List<String> contractPlantKeys() => <String>[
      'ST101.CN01.MOT01.speed',
      'ST101.CN01.MOT01.setpoint',
      'ST101.CN01.MOT01.running',
      'ST101.CN01.MOT01.reset',
      'ST201.CN04.MOT01.speed',
      'ST201.CN04.MOT01.setpoint',
      'ST301.CN07.SEN01.temp',
      // `ST301.CN17.VLV02.stat` is DELIBERATELY ABSENT. It is the kit's
      // designated missing key — `subscribe_contract.dart:46` and
      // `read_contract.dart:43` both name it, one to assert that an unmapped
      // key reports a configuration error instead of throwing and the other to
      // assert that `keys` lists what the source can serve **and nothing
      // else**. Mapping it would make both cases judge a key that exists.
      'ST301.CN18.VLV01.stat',
      // store_contract's hundred-key batch.
      for (var i = 0; i < 100; i++)
        'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
      // read_contract's fifty-tag diagnostics page.
      for (var i = 1; i <= 50; i++)
        'ST201.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
      // freshness_contract's fifty-key mass degradation.
      for (var i = 1; i <= 50; i++)
        'ST301.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

/// The keymapping the leg routes through: every plant key on one alias, the
/// read-only key on the link that refuses writes.
KeyMappings contractLegKeyMappings() {
  final mappings = <String, KeyMappingEntry>{
    for (final key in contractPlantKeys())
      key: opcUaEntry(alias: contractPlantAlias, identifier: key),
    contractReadOnlyKey:
        opcUaEntry(alias: contractWeigherAlias, identifier: contractReadOnlyKey),
  };
  return KeyMappings(nodes: mappings);
}

/// The live address space the browse checks navigate.
///
/// Scripted rather than served by an in-process OPC UA server, for the same
/// reason the read-only link is a fake: fifty checks each standing a server up
/// would put a native-asset build and a port race in front of a suite whose
/// subject is `LocalStateMan`, not open62541. `browse_test.dart` is where the
/// real address space is walked.
UpstreamAddressSpace contractBrowseSpace() =>
    _ScriptedAddressSpace(contractPlantAlias, <String?, List<String>>{
      null: <String>['ST101.CN01', 'ST101.CN04'],
      'ST101.CN01': <String>['ST101.CN01.MOT01'],
      'ST101.CN04': <String>['ST101.CN04.MOT01'],
      'ST101.CN01.MOT01': <String>[
        'ST101.CN01.MOT01.setpoint',
        'ST101.CN01.MOT01.running',
        'ST101.CN01.MOT01.reset',
      ],
      'ST101.CN04.MOT01': <String>[
        'ST101.CN04.MOT01.setpoint',
        'ST101.CN04.MOT01.running',
      ],
    });

final class _ScriptedAddressSpace implements UpstreamAddressSpace {
  _ScriptedAddressSpace(this.alias, this.levels);

  final String alias;
  final Map<String?, List<String>> levels;

  @override
  Future<List<BrowseNode>> childrenOf(BrowseNode? parent) async =>
      <BrowseNode>[
        for (final id in levels[parent?.id] ?? const <String>[]) _node(id),
      ];

  @override
  Future<BrowseNodeDetail?> detailOf(BrowseNode node) async =>
      node.type == BrowseNodeType.method
          ? const BrowseNodeDetail(description: 'a callable on the server')
          : BrowseNodeDetail(
              description: node.id,
              dataType: 'Float',
              value: DynamicValue(value: 1.0, quality: Quality.good),
            );

  BrowseNode _node(String id) => BrowseNode(
        id: id,
        displayName: id.split('.').last,
        type: id.endsWith('.reset')
            ? BrowseNodeType.method
            : levels.containsKey(id)
                ? BrowseNodeType.folder
                : BrowseNodeType.variable,
        metadata: <String, String>{browseAliasKey: alias},
      );
}

// ------------------------------------------------------------- the subject

/// Builds one `LocalStateMan` under the harness, connected and ready.
///
/// One fresh instance per case; the suite disposes each through
/// `addTearDown`. The links connect eagerly here rather than in a `setUp`
/// because `runStateManContract` takes a synchronous factory and a case that
/// had to remember to `await start()` would be a case that could forget.
StateManApi makeHarnessedLocalStateMan() => buildHarnessedLocalStateMan();

/// The same subject, optionally with the three data services behind it.
///
/// Two legs share this body and differ in exactly one thing: whether a
/// database was composed in. `contract_test.dart` passes nothing and stays in
/// the pure lane; `contract_db_test.dart` passes a `TimescaleReader`, a
/// `HistoryViewStore` and a `PreferenceStore` over a real TimescaleDB and a
/// [recorder] that puts rows in front of the reader.
///
/// [recorder] is the async half of [StateManDataHarness.seedTimeseries]. The
/// kit's lever returns `void` — it was written for an in-memory fake, where
/// recording a sample is a map assignment — and a real recorder is a database
/// round trip. See [HarnessedLocalStateMan.seedTimeseries] for how the two are
/// reconciled without the case having to know.
StateManApi buildHarnessedLocalStateMan({
  TimeseriesApi? timeseries,
  HistoryViewApi? historyViews,
  PreferenceStore? preferences,
  Future<void> Function(String tableName, List<TimeseriesData> points)?
      recorder,
}) {
  final plant = FakeUpstreamLink(
    alias: contractPlantAlias,
    keys: contractPlantKeys(),
  );
  final weigher = FakeUpstreamLink(
    alias: contractWeigherAlias,
    keys: const <String>[contractReadOnlyKey],
    // A device-level refusal, not a configured one: the write path has to
    // produce `Bad_NotWritable` because the link cannot write, which is what
    // an M2400 is.
    supportsWrites: false,
  );
  final counted = <BatchCountingLink>[
    BatchCountingLink(plant),
    BatchCountingLink(weigher),
  ];
  final man = LocalStateMan(
    links: counted,
    router: KeyRouter.overLinks(counted, mappings: contractLegKeyMappings()),
    browseSpaces: <String, UpstreamAddressSpace>{
      contractPlantAlias: contractBrowseSpace(),
    },
    // Long enough that a loaded runner does not stale a value between two
    // statements of the same case, short enough that the freshness cases do
    // not dominate the leg's runtime. Every freshness check reads its budget
    // from `StateManHarness.staleAfter`, so this one number judges them all.
    staleAfter: const Duration(milliseconds: 400),
    // Null for the pure lane and real for the `db` leg. Passed here rather
    // than built here for the reason `gateway_config.dart:617-630` gives at
    // the only other composition site: all three borrow one `Database`, and
    // whoever owns that connection owns opening and closing it.
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
  );
  // Connected BEFORE the composer exists, and this is not a shortcut.
  // `LocalStateMan.start()` subscribes to each link's state stream and then
  // connects it, so a link that comes up *after* the composer is watching
  // costs one status announcement — and `checkUpstreamLossAnnouncesOnce` reads
  // the counter across a window that would then contain the second link's
  // birth as well as the first link's death, and report two announcements for
  // one loss. Connecting first makes `start()`'s own `connect` a no-op on an
  // already-connected link (`FakeUpstreamLink.connect` returns immediately),
  // so the only announcements in the window are the ones the case caused.
  unawaited(plant.connect(deadline: const Duration(seconds: 1)));
  unawaited(weigher.connect(deadline: const Duration(seconds: 1)));
  unawaited(man.start());
  return HarnessedLocalStateMan(man,
      plant: plant, links: counted, recorder: recorder);
}

/// `LocalStateMan` plus the test-only control surface, and nothing else.
final class HarnessedLocalStateMan
    implements
        StateManApi,
        StateManHarness,
        StateManWriteHarness,
        StateManDataHarness {
  HarnessedLocalStateMan(
    this._man, {
    required FakeUpstreamLink plant,
    required List<BatchCountingLink> links,
    Future<void> Function(String tableName, List<TimeseriesData> points)?
        recorder,
  })  : _plant = plant,
        _links = links,
        _recorder = recorder;

  final LocalStateMan _man;

  /// The link the loss levers act on — the one ruling 8 is about.
  final FakeUpstreamLink _plant;

  final List<BatchCountingLink> _links;

  /// Where a seeded sample actually goes, or null on a leg with no recorder.
  final Future<void> Function(String tableName, List<TimeseriesData> points)?
      _recorder;

  /// Everything [seedTimeseries] has been asked for, in order, as one future.
  Future<void> _seeded = Future<void>.value();

  // ------------------------------------------------------ the nine kit levers

  @override
  void setValue(String key, Object? value,
      {Quality quality = Quality.good, DateTime? sourceTime}) {
    _plant.setValue(key, value, quality: quality, sourceTime: sourceTime);
    _man.applyUpstreamBatch(<String, DynamicValue>{
      key: DynamicValue(value: value, quality: quality, sourceTime: sourceTime),
    });
  }

  @override
  void setValues(Map<String, Object?> values) {
    _plant.setValues(values);
    // ONE batch, not a loop of single applies: the batch is the unit the
    // notification-count promise is made about, and a loop here would turn a
    // 1500-key arrival into 1500 passes over the store — the very shape the
    // check is watching for.
    _man.applyUpstreamBatch(<String, DynamicValue>{
      for (final entry in values.entries)
        entry.key: DynamicValue(value: entry.value),
    });
  }

  @override
  void setQuality(String key, Quality quality) {
    _plant.setQuality(key, quality);
    final cached = _man.read(key);
    _man.applyUpstreamBatch(<String, DynamicValue>{
      key: cached == null
          ? DynamicValue(value: null, quality: quality)
          : cached.copyWith(quality: quality),
    });
  }

  @override
  void dropKey(String key) {
    _plant.dropKey(key);
    // errorConfig with a null payload: the tag is gone upstream, waiting will
    // not bring it back, and the last plausible number must stop rendering.
    _man.applyUpstreamBatch(<String, DynamicValue>{
      key: DynamicValue(value: null, quality: Quality.errorConfig),
    });
  }

  /// The plant link goes down — and only the plant link.
  ///
  /// See the library doc: the weigher stays up so the announce-once arithmetic
  /// measures one link's loss, which is what the check was written against.
  @override
  void disconnectUpstream() {
    // A write that was out when the link died is the single most important
    // outcome in the write path, and it is `WriteUnknown` — the PLC may have
    // applied it, and only an outcome nobody knows stops an operator
    // re-sending a command the machine already took. A real adapter settles
    // its in-flight writes that way when the channel goes; the decorator does
    // the same, and it has to happen BEFORE the link's own state change so the
    // parked futures are already resolving when the degradation lands.
    for (final link in _links) {
      link.abortParkedWritesOnLinkLoss();
    }
    _plant.disconnectUpstream();
  }

  @override
  void reconnectUpstream() => _plant.reconnectUpstream();

  @override
  Duration get staleAfter => _man.staleAfter;

  /// Round trips as **this** source counts them: batches, not per-key reads.
  ///
  /// `readMany` issues its reads concurrently and awaits them together, so
  /// fifty keys cost one round-trip *time* — which is the entire property
  /// `checkReadManyCostsOneRoundTripForManyKeys` defends, in its own words:
  /// *"on a link with 200 ms of latency the difference between one and fifty
  /// is ten seconds of a diagnostics page that appears to have hung."* The
  /// underlying `FakeUpstreamLink.roundTrips` counts calls, which for a
  /// gateway that fans one batch out over a link is the wrong unit — and the
  /// harness surface exists precisely so an implementation whose plant-side
  /// accounting differs can declare its own. [BatchCountingLink] is where the
  /// counting happens, and it counts a burst issued in one event-loop turn as
  /// one.
  @override
  int get roundTrips {
    var total = 0;
    for (final link in _links) {
      total += link.batches;
    }
    return total;
  }

  /// **08-09's binding:** the gateway's own announcement count, not the fake's.
  ///
  /// The fake counts what the *link* announced; the promise is about what this
  /// source announced to its clients, and the two differ the moment a second
  /// link exists. Reading the fake's would make the check pass on a gateway
  /// that fanned a link's one event out per key.
  @override
  int get statusNotifications => _man.statusNotifications;

  // ------------------------------------------------ the write harness levers
  //
  // Every one of these lives on [BatchCountingLink], the decorator wrapped
  // around each fake link — NOT on `LocalStateMan`, and not on the fake
  // either. The fake has a one-shot `setNextWriteOutcome` that takes a whole
  // `WriteResult`, cmd included, and the cmd is minted by `LocalStateMan` per
  // write: a staged outcome would come back under somebody else's id, which is
  // the one property `writeStatus` cannot survive being wrong about. The
  // decorator sees the real cmd on the way past and answers under it.

  @override
  void failNextWrite(WriteReason reason, {bool unknown = false}) {
    for (final link in _links) {
      link.failNextWrite(reason, unknown: unknown);
    }
  }

  @override
  void clampNextWrite(Object? readback) {
    for (final link in _links) {
      link.clampNextWrite(readback);
    }
  }

  @override
  void stallWrites() {
    for (final link in _links) {
      link.stallWrites();
    }
  }

  @override
  void releaseWrites({bool applied = true}) {
    for (final link in _links) {
      link.releaseWrites(applied: applied);
    }
  }

  @override
  void setReadOnly(String key, bool readOnly) {
    for (final link in _links) {
      link.setReadOnly(key, readOnly);
    }
  }

  /// Attempts for [cmd], summed across the links.
  ///
  /// Counted at the seam a write actually crosses, which is the only place
  /// that can tell a re-issue from a re-try: `LocalStateMan._crossIntoThePlant`
  /// is one call site and `freeze_test.dart` pins it at one, but a pin counts
  /// call sites in source and this counts crossings at runtime.
  // -------------------------------------------------- the data-harness lever

  /// Records [points] against [tableName] — really, in the database.
  ///
  /// ## The lever is `void` and a database is not
  ///
  /// `StateManDataHarness.seedTimeseries` returns nothing, because it was
  /// declared for an in-memory fake where recording a sample is a map
  /// assignment. Here it is a round trip, and the case that calls it does
  /// this:
  ///
  /// ```dart
  /// seed(api, _table, _minutely(base, 7));
  /// final got = await within(api.timeseries.queryTimeseriesData(...), '…');
  /// ```
  ///
  /// — no await between the two, and none available to be written. So the
  /// settling happens where the *reader* is, not where the writer is: the
  /// work is queued here and [timeseries] waits for it before it answers.
  /// Every query this leg makes is therefore behind every seed this leg was
  /// asked for, in the order it was asked, which is the property the case is
  /// relying on when it writes those two lines.
  ///
  /// Chained rather than collected, because two seeds against one table must
  /// not interleave their inserts: `Database` buffers per table and flushes
  /// on a count, so two concurrent seeders would each flush the other's rows
  /// and neither would know when its own were on disk.
  ///
  /// The failure is deliberately *not* swallowed into `_seeded` alone: an
  /// error there would surface at the next query as an unrelated-looking
  /// exception, so it is left on the chain and re-thrown by the gate, which
  /// is the call the case is awaiting.
  @override
  void seedTimeseries(String tableName, List<TimeseriesData> points) {
    final recorder = _recorder;
    if (recorder == null) {
      throw UnsupportedError(
          'this leg was composed with no recorder, so it cannot put a sample '
          'in front of the reader. Only the `db` leg passes one: a leg with '
          'no database must declare `supportsDataServices: false` rather than '
          'seed into nothing — see contract_test.dart\'s call site');
    }
    _seeded = _seeded.then((_) => recorder(tableName, points));
  }

  /// Waits for every queued seed, and lets its failure out here.
  Future<void> _settleSeeds() async {
    final queued = _seeded;
    // Reset first: a failed seed must fail the query that needed it and then
    // stop failing every later one, or one broken case reports as seven.
    _seeded = Future<void>.value();
    await queued;
  }

  @override
  int upstreamWriteAttempts(String cmd) {
    var total = 0;
    for (final link in _links) {
      total += link.attemptsFor(cmd);
    }
    return total;
  }

  @override
  List<String> get mintedCmds => <String>[
        for (final link in _links) ...link.seenCmds,
      ];

  // ------------------------------------------------- StateManApi, by hand
  //
  // Every member written out. A `noSuchMethod` forwarder here would absorb a
  // member added to `StateManApi` in a later phase and this leg would judge it
  // without anybody deciding to.

  @override
  ValueListenable<DynamicValue> listen(String key) => _man.listen(key);

  @override
  Stream<DynamicValue> subscribe(String key) => _man.subscribe(key);

  @override
  DynamicValue? read(String key) => _man.read(key);

  @override
  Future<DynamicValue> readFresh(String key) => _man.readFresh(key);

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) =>
      _man.readMany(keys);

  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _man.write(key, value, expect: expect, cmd: cmd);

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) =>
      _man.writeStatus(cmds);

  @override
  Future<HoldHandle> holdToRun(String key) => _man.holdToRun(key);

  @override
  List<String> get keys => _man.keys;

  @override
  BrowseApi get browse => _man.browse;

  /// The gateway's reader, behind the seed gate.
  ///
  /// Undecorated when there is no recorder: the pure lane must reach
  /// `LocalStateMan.timeseries`' refusal by name, and a wrapper would put a
  /// harness frame in front of the message that tells a reader what is
  /// missing.
  @override
  TimeseriesApi get timeseries => _recorder == null
      ? _man.timeseries
      : _SeedGatedTimeseries(_man.timeseries, _settleSeeds);

  @override
  HistoryViewApi get historyViews => _man.historyViews;

  @override
  PreferencesApi get preferences => _man.preferences;

  // Undecorated, for the reason given above `timeseries`: a case must reach
  // `LocalStateMan`'s refusal by name, and a harness frame in front of the
  // message would hide what is actually missing.
  @override
  AccessTemplateApi get accessTemplates => _man.accessTemplates;

  @override
  AccessAdminApi get accessAdmin => _man.accessAdmin;

  @override
  AuditApi get audit => _man.audit;

  @override
  BackendConfigApi get backendConfig => _man.backendConfig;

  @override
  Future<void> dispose() => _man.dispose();
}

/// The reader, with every queued seed settled before it answers.
///
/// Four methods and no judgement in any of them: this decorator exists to
/// order two things the kit's `void` lever cannot order itself
/// ([HarnessedLocalStateMan.seedTimeseries] argues why), and a decorator that
/// also filtered, capped or reshaped an answer would be a leg marking its own
/// homework.
final class _SeedGatedTimeseries implements TimeseriesApi {
  _SeedGatedTimeseries(this._inner, this._settle);

  final TimeseriesApi _inner;
  final Future<void> Function() _settle;

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    await _settle();
    return _inner.queryTimeseriesData(tableName, to,
        orderBy: orderBy, from: from);
  }

  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    await _settle();
    return _inner.queryTimeseriesDataMultiple(tableNames, to,
        orderBy: orderBy, from: from);
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    await _settle();
    return _inner.queryTimeseriesDataDownsampled(tableName, from, to,
        maxPoints: maxPoints);
  }
}

/// A link that counts **bursts** of upstream reads rather than reads.
///
/// Everything else is forwarded untouched. The rule is one increment per
/// event-loop turn in which at least one read was issued: `readMany` builds its
/// fifty futures in a single synchronous pass and then awaits them together, so
/// the fifty land in one turn and cost one. Two reads a hundred milliseconds
/// apart land in different turns and cost two, which is the failure the check
/// exists to catch.
final class BatchCountingLink implements UpstreamLink {
  BatchCountingLink(this._inner);

  final UpstreamLink _inner;

  int _batches = 0;
  bool _burstOpen = false;

  WriteReason? _nextFailure;
  bool _nextFailureUnknown = false;
  bool _hasClamp = false;
  Object? _clamp;
  bool _stalling = false;
  final List<Completer<WriteResult>> _parked = <Completer<WriteResult>>[];
  final Set<String> _readOnlyKeys = <String>{};
  final Map<String, int> _attempts = <String, int>{};
  final List<String> _seenCmds = <String>[];

  /// Bursts of upstream reads since this link was built.
  int get batches => _batches;

  /// Every cmd that crossed this link, in order.
  List<String> get seenCmds => List<String>.unmodifiable(_seenCmds);

  /// How many times [cmd] crossed this link. One, forever.
  int attemptsFor(String cmd) => _attempts[cmd] ?? 0;

  void failNextWrite(WriteReason reason, {bool unknown = false}) {
    _nextFailure = reason;
    _nextFailureUnknown = unknown;
  }

  void clampNextWrite(Object? readback) {
    _hasClamp = true;
    _clamp = readback;
  }

  void stallWrites() => _stalling = true;

  void releaseWrites({bool applied = true}) {
    _stalling = false;
    final parked = List<Completer<WriteResult>>.of(_parked);
    _parked.clear();
    for (final completer in parked) {
      if (completer.isCompleted) continue;
      completer.complete(applied
          ? WriteApplied(_cmdOf(completer),
              readback: _parkedValues[completer]?.value,
              at: DateTime.now().millisecondsSinceEpoch)
          : WriteUnknown(
              _cmdOf(completer),
              const WriteReason('plc_timeout',
                  message: 'the stall ended with the request still out')));
    }
    _parkedCmds.clear();
    _parkedValues.clear();
  }

  final Map<Completer<WriteResult>, String> _parkedCmds =
      <Completer<WriteResult>, String>{};

  /// What each parked write was carrying, so a release can answer with the
  /// readback the device would have echoed rather than with a null the case
  /// would read as "the PLC took the write and forgot the number".
  final Map<Completer<WriteResult>, DynamicValue> _parkedValues =
      <Completer<WriteResult>, DynamicValue>{};

  String _cmdOf(Completer<WriteResult> completer) => _parkedCmds[completer]!;

  /// Settles everything parked as an outcome nobody knows.
  void abortParkedWritesOnLinkLoss() {
    if (_parked.isEmpty) return;
    releaseWrites(applied: false);
    // The stall stays ON: the link being down is not the case letting go of
    // the in-flight window, and a write issued after the drop must not
    // silently succeed.
    _stalling = true;
  }

  void setReadOnly(String key, bool readOnly) {
    if (readOnly) {
      _readOnlyKeys.add(key);
    } else {
      _readOnlyKeys.remove(key);
    }
  }

  @override
  Future<DynamicValue> read(UpstreamRef ref, {required Duration deadline}) {
    if (!_burstOpen) {
      _batches++;
      _burstOpen = true;
      // `Timer.run` and not `scheduleMicrotask`: a microtask can run between
      // two awaits inside the same logical batch, which would split one burst
      // into two and fail the check for a reason that is not about the source.
      Timer.run(() => _burstOpen = false);
    }
    return _inner.read(ref, deadline: deadline);
  }

  @override
  String get alias => _inner.alias;
  @override
  UpstreamLinkState get state => _inner.state;
  @override
  Stream<UpstreamLinkState> get stateStream => _inner.stateStream;
  @override
  String? get lastError => _inner.lastError;
  @override
  String get epoch => _inner.epoch;
  @override
  Stream<String> get epochStream => _inner.epochStream;
  @override
  int get birthCount => _inner.birthCount;
  @override
  DateTime? get lastDeathAt => _inner.lastDeathAt;
  @override
  UpstreamRef? resolve(String key, Object mappingEntry) =>
      _inner.resolve(key, mappingEntry);
  @override
  Stream<DynamicValue> subscribe(UpstreamRef ref) => _inner.subscribe(ref);
  @override
  DynamicValue? peek(UpstreamRef ref) => _inner.peek(ref);
  @override
  Future<WriteResult> write(UpstreamRef ref, DynamicValue value,
      {required String cmd,
      required Duration deadline,
      bool hasExpect = false}) {
    // Counted BEFORE anything can short-circuit: a refusal is still an
    // attempt, and a counter that only saw the successes could not tell a
    // re-sent write from a slow one — which is the whole reason the observable
    // exists.
    _attempts[cmd] = (_attempts[cmd] ?? 0) + 1;
    _seenCmds.add(cmd);

    if (_readOnlyKeys.contains(ref.key)) {
      return Future<WriteResult>.value(WriteRejected(cmd, notWritableReason));
    }
    final failure = _nextFailure;
    if (failure != null) {
      _nextFailure = null;
      final unknown = _nextFailureUnknown;
      _nextFailureUnknown = false;
      return Future<WriteResult>.value(unknown
          ? WriteUnknown(cmd, failure)
          : WriteRejected(cmd, failure));
    }
    if (_hasClamp) {
      _hasClamp = false;
      final readback = _clamp;
      _clamp = null;
      return Future<WriteResult>.value(WriteApplied(cmd,
          readback: readback, at: DateTime.now().millisecondsSinceEpoch));
    }
    if (_stalling) {
      // Phase 2's `blackhole`: the request is out and no answer comes back.
      // Parked rather than delayed, so the in-flight window stays open exactly
      // as long as the case wants to look at it.
      final completer = Completer<WriteResult>();
      _parked.add(completer);
      _parkedCmds[completer] = cmd;
      _parkedValues[completer] = value;
      return completer.future;
    }
    return _inner.write(ref, value, cmd: cmd, deadline: deadline);
  }
  @override
  bool get supportsWrites => _inner.supportsWrites;
  @override
  bool get supportsBrowse => _inner.supportsBrowse;
  @override
  Future<void> connect({required Duration deadline}) =>
      _inner.connect(deadline: deadline);
  @override
  Future<void> dispose() => _inner.dispose();
  @override
  int get upstreamSubscriptionsCreated => _inner.upstreamSubscriptionsCreated;
}
