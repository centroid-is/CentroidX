@TestOn('vm')

/// SEC-03's authorization clause: who may see a tag, and who may actuate one.
///
/// **Source: 06-CONTEXT decision 2**, the user's framing recorded verbatim —
/// *"What if it should be hidden. Let's think about the future even though we
/// don't implement all at once"* — and 06-RESEARCH §E. The seam ships now; the
/// policy data does not. So the shipped rule is trivial (everything visible,
/// `operate` may write) and the *enforcement* is structural: one object per
/// session that every key-touching surface reaches the source through.
///
/// ## What breaks in the plant without this file
///
/// Two different things, and they are worth separating because they fail
/// differently.
///
/// Without the write gate a wall display in the canteen — a `view` station,
/// bolted up precisely because nobody should be actuating a machine from it —
/// can start a conveyor. That is one missing comparison away at all times, and
/// the failure is loud only if somebody is standing next to the belt.
///
/// Without the **hiding rule** the failure is quiet, which is why CONTEXT locks
/// it as architecture rather than as a feature. A refusal that says *forbidden*
/// tells the asker that the tag exists. Ask about a thousand names, keep the
/// ones answered *forbidden* rather than *unknown*, and the gateway has just
/// enumerated the plant's address space for a station that may not read a byte
/// of it. So a hidden key must be **indistinguishable from a key that does not
/// exist** — the same answer on `read`, `readFresh`, `readMany`, `subscribe`
/// and `write`, and absent from `keys`.
///
/// ## Why this check is here and not in the contract kit
///
/// Trap 19 / §E.4. `tfc_stateman_contract`'s `suite_integrity_test.dart` has
/// three gates (`:102-109`, `:133-141`, `:143+`) that force any check written
/// in that package into `allContractChecks`, and three drivers assert against
/// that length for their **full** leg — including the fake leg, which under
/// 06-CONTEXT amendment 3 has no policy at all and could therefore only pass
/// such a check *vacuously*, by comparing a nonexistent key with a nonexistent
/// key. `suite_integrity_test.dart:104-108` names that outcome: "a property
/// nobody is testing that reads like coverage is worse than an absent one".
///
/// A server-side seam has exactly one implementation by construction, so a
/// cross-implementation contract check was never buying anything here. What
/// this file keeps is all the teeth: the production policy object, the
/// production gateway, the production transport, the production error shapes.
/// `allContractChecks.length` does not move.
@Tags(['ws'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';

import 'package:json_rpc_2/error_code.dart' as rpc_error;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/health/session_health_state_man.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/permissive_resolver.dart';
import 'support/scripted_policy.dart';

/// A tag in the plant's own naming convention, so the cases read like the
/// thing they model rather than like synthetic strings.
const _key = 'CN01.MOT01.speed';

/// The tag the test policy hides. A second real tag on a real machine — the
/// point being that it is every bit as servable as [_key] and is concealed
/// only because the policy says so.
const _hidden = 'CN02.MOT01.speed';

/// A tag no fixture ever seeds and no policy ever mentions: the control the
/// hidden one is compared against. `nonexistent_key_test.dart`'s `_ghost`, in
/// the same spelling, because the property under test is that the two answers
/// are the same one.
const _ghost = 'CN01.MOT01.speeed';

/// The folder the hidden tag lives under, named as if it were a key.
///
/// One case hides *this* — a folder id, not a tag — to pin the rule that
/// browse asks `canSee` about variables and nothing else. See
/// `a folder is never asked about`.
const _hiddenParent = 'CN02.MOT01';

// ---------------------------------------------------------------------------
// The address space, whose leaf ids are plant keys.
// ---------------------------------------------------------------------------

/// The visible tag, as a browse node.
const _visibleNode = BrowseNode(
    id: _key,
    displayName: 'speed',
    type: BrowseNodeType.variable,
    dataType: 'Float');

/// The hidden tag, as a browse node. Every field but the id matches
/// [_visibleNode] and [_probeNodeFor], which is what lets the detail answers
/// be compared rather than described.
const _hiddenNode = BrowseNode(
    id: _hidden,
    displayName: 'speed',
    type: BrowseNodeType.variable,
    dataType: 'Float');

/// The node a case hands to `fetchDetail`, for any id.
///
/// A client already holds these fields — they came off a browse list, or it
/// made them up — so echoing them back discloses nothing. The *id* is the only
/// thing that varies, and it is the only thing `fetchDetail` could answer
/// differently about.
BrowseNode _probeNodeFor(String id) => BrowseNode(
    id: id,
    displayName: 'speed',
    type: BrowseNodeType.variable,
    dataType: 'Float');

/// A tree whose **leaf ids are plant keys**, so a permissive resolver's
/// identity mapping is the real thing rather than a stand-in.
///
/// `FakeBrowse`'s default tree uses OPC-UA-shaped ids (`ST101.CN01…`) that
/// map to no key this file's policy has ever heard of, which would make every
/// browse case here pass by hiding nothing. The reading on [_hidden] is
/// seeded so the anti-vacuity arm can show what the hiding actually removed.
FakeBrowse _browseTree() => FakeBrowse(
      roots: const [
        BrowseNode(
            id: 'CN01', displayName: 'CN01', type: BrowseNodeType.folder),
        BrowseNode(
            id: 'CN02', displayName: 'CN02', type: BrowseNodeType.folder),
      ],
      children: const {
        'CN01': [
          BrowseNode(
              id: 'CN01.MOT01',
              displayName: 'MOT01',
              type: BrowseNodeType.folder),
        ],
        'CN01.MOT01': [_visibleNode],
        'CN02': [
          BrowseNode(
              id: _hiddenParent,
              displayName: 'MOT01',
              type: BrowseNodeType.folder),
        ],
        _hiddenParent: [_hiddenNode],
      },
      details: {
        _hidden: BrowseNodeDetail(
            dataType: 'Float', value: DynamicValue(value: 900)),
      },
    );

// ---------------------------------------------------------------------------
// Recorded history, for the timeseries surface (10-03).
// ---------------------------------------------------------------------------

/// The instant the seeded series starts at. Fixed and UTC.
final _tsBase = DateTime.utc(2026, 8, 13, 6);

/// A series name the fixtures' resolver maps to **no** key at all.
///
/// The third thing a station can ask about, alongside "hidden" and "never
/// existed": a name that is well formed, that the gateway has no mapping for,
/// and that must therefore be answered as a series that does not exist — while
/// still being *counted*, because 10-CONTEXT amendment 6 requires an unmappable
/// table to be visible rather than merely refused.
const _unmapped = 'CN09.MOT01.speed';

int _ms(DateTime at) => at.millisecondsSinceEpoch;

/// Both real tags have history, so no timeseries case can pass by asking about
/// a series that was never recorded in the first place.
///
/// **The member addresses are seeded as their own series**, which is how a
/// string-keyed fake models a projection: it has no columns to select from, so
/// `CN01.MOT01.speed:speed` is simply another name it holds rows under. That
/// the *real* reader turns the same address into a one-column SELECT is
/// `tfc_relay_local/test/composed_seam_test.dart`'s subject, and it has to be —
/// a fake accepts whatever it is handed, which is exactly why nothing here
/// could see CR-01 (10-REVIEW, answer to question 1).
_RecordingTimeseries _seededHistory() => _RecordingTimeseries()
  ..seed(_key, [
    for (var i = 0; i < 5; i++)
      TimeseriesData<num>(1200 + i, _tsBase.add(Duration(minutes: i))),
  ])
  ..seed(_hidden, [
    for (var i = 0; i < 5; i++)
      TimeseriesData<num>(900 + i, _tsBase.add(Duration(minutes: i))),
  ])
  ..seed('$_key:speed', [
    for (var i = 0; i < 5; i++)
      TimeseriesData<num>(1200 + i, _tsBase.add(Duration(minutes: i))),
  ])
  ..seed('$_hidden:speed', [
    for (var i = 0; i < 5; i++)
      TimeseriesData<num>(900 + i, _tsBase.add(Duration(minutes: i))),
  ]);

/// A [FakeTimeseries] that writes down **the series name it was handed**.
///
/// The lever 10-REVIEW CR-01 says the suite was missing. "The chart got rows"
/// is satisfied by a decorator that rewrites the name into anything the fake
/// happens to hold; what a real reader needs is that the string the caller
/// spelled is the string the layer below receives, member and all. That is a
/// claim about the *argument*, and only a recorder can make it.
final class _RecordingTimeseries extends FakeTimeseries {
  /// Every series name the source was asked about, in call order, across all
  /// four methods.
  final asked = <String>[];

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) {
    asked.add(tableName);
    return super
        .queryTimeseriesData(tableName, to, orderBy: orderBy, from: from);
  }

  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) {
    asked.addAll(tableNames);
    return super.queryTimeseriesDataMultiple(tableNames, to,
        orderBy: orderBy, from: from);
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) {
    asked.add(tableName);
    return super.queryTimeseriesDataDownsampled(tableName, from, to,
        maxPoints: maxPoints);
  }
}

/// A resolver that maps the two real tags and refuses everything else — **to a
/// table that is not the series**.
///
/// `PermissiveSeriesResolver` maps every name to itself, which is honest for
/// this file's browse tree but cannot express "no mapping" — and "no mapping"
/// is the whole of what the unmappable cases are about.
///
/// ## The prefix is load-bearing (10-REVIEW CR-01)
///
/// This class used to answer `table: address.series`, and so did every other
/// resolver in the suite. That is what hid CR-01 for a whole phase: with
/// `table == series` a *double* resolution is idempotent, so a decorator
/// resolving the name and handing the **table** down looked identical to one
/// handing the **name** down, and the fake reader underneath never looked at
/// the member either way. Against the deployed resolver, whose table is
/// `tablePrefix + name` with `'gw_'` as the default
/// (`collection_config.dart:148`), the second lookup missed and every
/// timeseries request answered `UnknownSeries`.
///
/// So the fixture prefixes. Nothing below depends on the table string — the
/// seeded [FakeTimeseries] is keyed by the wire name, which is what the
/// decorator now hands it — and that independence is the property: a decorator
/// that rewrote the name would ask for `gw_CN01.MOT01.speed`, find no seed, and
/// fail the "and the visible series is still answered" arm.
///
/// The composed-stack judgement, against the *real* reader rather than a fake
/// one, is `tfc_relay_local/test/composed_seam_test.dart`.
final class _MapsTheRealTags implements SeriesResolver {
  const _MapsTheRealTags();

  static const _mapped = {_key, _hidden, _ghost};

  /// 8b's convention for "the gateway collected this", and the default.
  static const _prefix = 'gw_';

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    if (!_mapped.contains(address.series)) return null;
    return ResolvedSeries(
        table: '$_prefix${address.series}',
        member: address.member,
        plantKey: address.series);
  }

  @override
  String? keyForTable(String table) {
    if (!table.startsWith(_prefix)) return null;
    final key = table.substring(_prefix.length);
    return _mapped.contains(key) ? key : null;
  }

  @override
  String? keyForNode(String nodeId) => nodeId;
}

/// A panel next to a machine, a display on a wall, and the engineer's station
/// that holds every group the master system has.
///
/// Group sets rather than a two-valued role: 17-04b deleted `Role` and
/// `Identity`, and what a station may do is now whatever the groups behind its
/// resolver-verified user's role say. `_panel` holds the tag-write floor and
/// nothing else, so an arm it passes is about `operate` and not about some
/// wider grant riding along; `_display` holds nothing at all, which is the
/// honest spelling of "may not actuate"; `_engineer` exists for the
/// anti-vacuity arms, whose subject is "the store really records" rather than
/// any particular grading.
final _panel = stationHolding(const {AccessGroup.operate});
final _display = stationHolding(const <AccessGroup>{});
final _engineer = stationHolding(AccessGroup.values.toSet());

// ---------------------------------------------------------------------------
// The levers.
//
// The hiding double is `ScriptedPolicy` (test/support/scripted_policy.dart).
// Its predecessor — `_HidesTags`, declared right here at :332 — had a
// `canWrite` that ignored `hidden` entirely, so every write-refusal arm it
// drove was satisfiable by `canSee` making the key absent (17-CONTEXT D-12).
// `ScriptedPolicy.hiding` hides and does nothing else: under it a refused
// write on a hidden key can only have been refused by the existence check,
// which is the claim the arms below actually make.
// ---------------------------------------------------------------------------

/// A preference store that writes down every mutation it is asked to make.
///
/// The lever the pre-effect property needs. "The write was refused" is cheap to
/// assert and easy to satisfy by accident — a gate that throws *after* calling
/// the store refuses just as visibly — so what the arms below actually assert
/// is that the store was never touched, and that needs a store that counts.
///
/// Extends [FakePreferences] rather than reimplementing [PreferencesApi]: the
/// reads have to be real for the read arms to mean anything, and
/// `FakeStateMan` takes the concrete type.
final class _RecordingPreferences extends FakePreferences {
  /// The mutators called on this store, in order, by name.
  final writes = <String>[];

  @override
  Future<void> setBool(String key, bool value) {
    writes.add('setBool');
    return super.setBool(key, value);
  }

  @override
  Future<void> setInt(String key, int value) {
    writes.add('setInt');
    return super.setInt(key, value);
  }

  @override
  Future<void> setDouble(String key, double value) {
    writes.add('setDouble');
    return super.setDouble(key, value);
  }

  @override
  Future<void> setString(String key, String value) {
    writes.add('setString');
    return super.setString(key, value);
  }

  @override
  Future<void> setStringList(String key, List<String> value) {
    writes.add('setStringList');
    return super.setStringList(key, value);
  }

  @override
  Future<void> remove(String key) {
    writes.add('remove');
    return super.remove(key);
  }

  @override
  Future<void> clear({Set<String>? allowList}) {
    writes.add('clear');
    return super.clear(allowList: allowList);
  }
}

/// A validator that hands every session one fixed identity.
///
/// Cheaper than a token file for cases whose subject is the *policy* rather
/// than the credential — `auth_test.dart` owns the file-shaped cases, and a
/// second copy of its temp-directory machinery here would be a second place
/// the token format is written down.
final class _AlwaysStation implements TokenValidator {
  const _AlwaysStation(this.identity);

  final StationIdentity identity;

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      TokenAccepted(identity);
}

// ---------------------------------------------------------------------------
// A gateway with a policy on it, and real sockets in front.
// ---------------------------------------------------------------------------

/// One real [RelayServer] carrying a policy, with the plant behind it.
///
/// Local rather than `ws_harness.dart`'s `relayFixture`, which takes no
/// `policy:` argument and owns exactly one socket. Both matter here: the
/// policy *is* the subject, and the dispose case needs two stations on one
/// gateway so that "closing one leaves the other reading" is a property rather
/// than a single-session tautology.
final class _Gateway {
  _Gateway._(this.plant, this.server, this.history);

  /// The reference implementation the gateway serves, driveable directly.
  final FakeStateMan plant;
  final RelayServer server;

  /// The seeded history, as the recorder that also remembers what the policy
  /// handed it. See [_RecordingTimeseries].
  final _RecordingTimeseries history;

  /// The sessions this gateway is holding, in connection order.
  List<RelaySession> get sessions => server.sessions.sessions;

  /// The **production** decorator the first session is serving through.
  ///
  /// Read off the live session rather than rebuilt here, which is the whole
  /// difference between checking the object under test and checking a
  /// second one built the same way.
  PolicyStateMan get served => sessions.first.api;

  static Future<_Gateway> start({
    KeyPolicy policy = const AccessPolicyKeyPolicy(),
    StationIdentity? identity,
    SeriesResolver resolver = const PermissiveSeriesResolver(),
  }) async {
    final history = _seededHistory();
    final plant = FakeStateMan(browse: _browseTree(), timeseries: history);
    final server = RelayServer(
      // Identity mapping by default: this file's tree names its leaves after
      // the plant keys they are, so `keyForNode` returning its argument is the
      // honest answer rather than a fixture's shortcut.
      // `permissive_resolver.dart` carries the sentence about what it would
      // mean in production. The timeseries cases override it with
      // `_MapsTheRealTags`, which is the same mapping plus the one thing a
      // permissive resolver cannot express: a name it will not map.
      resolver: resolver,
      api: plant,
      config: ServerConfig(tick: ServerConfig.minTick),
      validator: _AlwaysStation(identity ?? _panel),
      policy: policy,
      // A collector that discards: several cases here provoke refusals on
      // purpose, and a suite printing a stack trace per provoked refusal
      // trains everyone to scroll past them (`ws_harness.dart:231-235`).
      onError: (_, __, ___) {},
    );
    await server.start();
    addTearDown(() async {
      await server.close();
      await plant.dispose();
    });
    return _Gateway._(plant, server, history);
  }

  /// A station on this gateway, connected and past the handshake.
  Future<_Station> station() async {
    final opened = server.sessions.opened.first;
    final ws =
        IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    await ws.ready;
    final finished = Completer<void>();
    final base = wsChannel(ws);
    final tapped = base.stream.transform(
        StreamTransformer<String, String>.fromHandlers(handleDone: (sink) {
      if (!finished.isCompleted) finished.complete();
      sink.close();
    }));
    final peer = rpc.Client(StreamChannel<String>(tapped, base.sink));
    unawaited(peer.listen().catchError((Object _) => null));
    addTearDown(() async {
      await peer.close();
      await ws.sink.close().catchError((Object _) {});
    });
    // Awaited before the hello so a case reading `sessions` cannot race the
    // accept — `ws_harness.dart:315` makes the same argument for the same
    // reason.
    await opened.timeout(const Duration(seconds: 5));
    final station = _Station._(ws, peer, finished.future);
    await station.hello();
    return station;
  }
}

/// One connected client, past the handshake.
final class _Station {
  _Station._(this._ws, this._peer, this.done);

  final WebSocketChannel _ws;
  final rpc.Client _peer;

  /// Completes when this station's socket has finished, however it finished.
  final Future<void> done;

  bool get isOpen => _ws.closeCode == null;

  Future<void> hello() => request(Methods.hello,
      params: HelloParams(
        protocol: protocolVersion,
        supported: const [protocolVersion],
        client: const PeerInfo('panel-under-test', '0.1.0'),
      ).toJson(),
      what: 'the hello result over a real socket');

  Future<Object?> request(String method,
          {Object? params,
          String? what,
          Duration budget = const Duration(seconds: 2)}) =>
      within(_peer.sendRequest(method, params),
          what ?? 'a $method response over a real socket',
          budget: budget);

  /// Sends [method] expecting a refusal, and hands back the refusal.
  ///
  /// A method that is *answered* fails here rather than at a downstream
  /// matcher, so the report names the property rather than the assertion that
  /// tripped over it (`ws_harness.dart:153-168`).
  Future<rpc.RpcException> refusal(String method,
      {Object? params, required String what}) async {
    try {
      await request(method, params: params, what: what);
    } on rpc.RpcException catch (error) {
      return error;
    }
    fail('$what was answered instead of refused');
  }
}

/// Runs [call] expecting a refusal, and hands the refusal back.
///
/// `_Station.refusal`'s argument, one layer in: a call that is *answered* fails
/// here rather than at a downstream matcher, so the report names the property
/// rather than the assertion that tripped over it.
Future<rpc.RpcException> _refused(
    Future<void> Function() call, String what) async {
  try {
    await call();
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

/// One decoded JSON object, cast where the wire hands back `Object?`.
Map<String, Object?> _asMap(Object? raw) =>
    (raw! as Map).cast<String, Object?>();

/// A production decorator over a fresh fake plant, as seen by [identity] —
/// for in-process arms whose subject is the gate rather than the transport.
PolicyStateMan seenByStation(StationIdentity? identity) {
  final plant = FakeStateMan();
  addTearDown(plant.dispose);
  return PolicyStateMan(
    source: plant,
    policy: const AccessPolicyKeyPolicy(),
    resolver: const PermissiveSeriesResolver(),
    tally: SeriesMappingTally(),
    identityOf: () => identity,
  );
}

// ---------------------------------------------------------------------------
// The six surfaces, as one comparable answer each.
// ---------------------------------------------------------------------------

/// One surface, and how to ask it about a tag.
///
/// A list rather than six hand-written comparisons, so that adding a surface
/// in Phase 10 — `browse` is the obvious next one — is one entry here and the
/// indistinguishability case covers it automatically. That is the "cannot rot"
/// half of the property: a new way to ask about a tag is a new way to leak
/// that it exists, and the check should not have to be remembered.
typedef _Surface = ({
  String name,
  Future<Object?> Function(_Gateway gateway, _Station station, String key) ask,
});

const List<_Surface> _surfaces = [
  (name: 'read', ask: _askRead),
  (name: 'readFresh', ask: _askReadFresh),
  (name: 'readMany', ask: _askReadMany),
  (name: 'subscribe', ask: _askSubscribe),
  (name: 'write', ask: _askWrite),
  (name: 'keys', ask: _askKeys),
  // 10-02. The doc above invited browse as the seventh, and it is one entry
  // exactly as promised. **What "indistinguishable" means here is different
  // from the six above, and the difference is worth a reader's attention.**
  // Those six answer a *value* or a *refusal*, so the comparison is between
  // two answers about one tag. Browse answers *lists*, and a hidden tag is
  // not refused out of one — it is **absent** from it, which is the same
  // thing a nonexistent tag is. So the comparable shape below is "was this id
  // anywhere in the tree, what did resolvePath say, and what did the detail
  // pane get", and hidden and nonexistent have to agree on all three.
  (name: 'browse', ask: _askBrowse),
  // 10-03. The eighth, and it fits the existing shape without reshaping the
  // loop: a timeseries method is keyed by a *series name*, this file's tree
  // and its resolver both name a series after the plant key it records, so
  // "ask this surface about a tag" is a well-formed request here in exactly
  // the way it is for the other seven. What it compares is all four
  // timeseries methods at once, for browse's reason: a filter fitted to the
  // single-series path and forgotten on the multi-series one would hide a
  // tag from one chart and hand its history to the next.
  (name: 'timeseries', ask: _askTimeseries),
];

/// Whatever the gateway said, refusal or answer, in one comparable shape.
///
/// Both outcomes are captured rather than one being allowed to throw, because
/// "one surface refused and the other answered" is precisely the difference
/// the case is hunting and it should be *reported* rather than thrown out of
/// the loop.
Future<Object?> _outcome(
    Future<Object?> Function() ask, String key) async {
  try {
    return _withoutKeyName({'answered': await ask()}, key);
  } on rpc.RpcException catch (error) {
    return _withoutKeyName({
      'refused': {
        'code': error.code,
        'message': error.message,
        'data': error.data,
      },
    }, key);
  }
}

Future<Object?> _askRead(_Gateway gateway, _Station station, String key) =>
    _outcome(() => station.request(Methods.read, params: {'key': key}), key);

Future<Object?> _askReadFresh(_Gateway gateway, _Station station, String key) =>
    _outcome(
        () => station.request(Methods.readFresh, params: {'key': key}), key);

Future<Object?> _askReadMany(_Gateway gateway, _Station station, String key) =>
    _outcome(
        () => station.request(Methods.readMany, params: {
              'keys': [key]
            }),
        key);

/// `subscribe`, minus the bookkeeping that is about the *subscription* rather
/// than about the tag.
///
/// `sub` is the name the caller chose, `epoch` and `seq` belong to the
/// session, and `generation` is a server-global counter that increments on
/// every establishment — so two subscribes can never agree on it and none of
/// the four is a statement about the key. What is left is exactly the part
/// that carries existence: a key the gateway serves appears in `handles`,
/// `meta` and `snapshot`; a key it does not appears in `rejected` and in none
/// of the other three.
Future<Object?> _askSubscribe(
        _Gateway gateway, _Station station, String key) =>
    _outcome(() async {
      final answer = _asMap(await station.request(Methods.subscribe, params: {
        'sub': 'probe-${DateTime.now().microsecondsSinceEpoch}',
        'keys': [key],
      }));
      return {
        'handles': answer['handles'],
        'meta': answer['meta'],
        'snapshot': answer['snapshot'],
        'rejected': answer['rejected'],
      };
    }, key);

Future<Object?> _askWrite(_Gateway gateway, _Station station, String key) =>
    _outcome(
        () => station.request(Methods.write,
            params: {'cmd': newUlid(), 'key': key, 'value': 1450}),
        key);

/// Every node id the address space will show this station, walked over the
/// wire the way a panel expands a tree.
///
/// Read through the socket rather than off `gateway.served.browse`, because
/// the property is about what a *client* can learn and the handler is part of
/// the path that decides it.
Future<Set<String>> _reachableNodeIds(_Station station) async {
  final seen = <String>{};

  Future<void> walk(List<Object?> level) async {
    for (final raw in level) {
      final node =
          BrowseNode.fromJson((raw! as Map).cast<String, Object?>());
      if (!seen.add(node.id)) continue;
      final children = await station.request(
          DataServiceMethods.browseFetchChildren,
          params: {'parent': node.toJson()},
          what: 'the children of ${node.id}');
      await walk(children! as List<Object?>);
    }
  }

  final roots = await station.request(DataServiceMethods.browseFetchRoots,
      params: const <String, Object?>{}, what: 'the roots');
  await walk(roots! as List<Object?>);
  return seen;
}

/// Browse, as one comparable answer: listed, resolvable, and what its detail
/// pane got.
///
/// All three, not one. A filter that dropped a node from `fetchChildren` and
/// left `resolvePath` answering a full chain would hide the tag from the tree
/// and hand it back to anyone who asked for a path to it — and the panel that
/// restores a saved selection asks for exactly that on every page load.
Future<Object?> _askBrowse(
        _Gateway gateway, _Station station, String key) =>
    _outcome(() async {
      final listed = (await _reachableNodeIds(station)).contains(key);
      final chain = await station.request(
          DataServiceMethods.browseResolvePath,
          params: {'targetId': key},
          what: 'a path to $key');
      final detail = await station.request(
          DataServiceMethods.browseFetchDetail,
          params: {'node': _probeNodeFor(key).toJson()},
          what: 'the detail of $key');
      return {'listed': listed, 'path': chain, 'detail': detail};
    }, key);

/// All three timeseries methods, as one comparable answer.
///
/// Three rather than one, and the reason is browse's: a filter fitted to
/// `queryTimeseriesData` and forgotten on `queryTimeseriesDataMultiple` hides
/// a series from one chart and hands its history to the next, and the
/// multi-series path is the one every real chart with more than one line
/// uses.
///
/// The window is wide enough to contain everything [_seededHistory] records,
/// so an empty answer here means the *filter* emptied it rather than the
/// window.
Future<Object?> _askTimeseries(
        _Gateway gateway, _Station station, String key) =>
    _outcome(() async {
      final to = _tsBase.add(const Duration(hours: 1));
      final one = await station.request(DataServiceMethods.timeseriesQuery,
          params: {'table': key, 'to': _ms(to), 'from': _ms(_tsBase)},
          what: 'the recorded series for $key');
      final many =
          await station.request(DataServiceMethods.timeseriesQueryMultiple,
              params: {
                'tables': [key],
                'to': _ms(to),
                'from': _ms(_tsBase),
              },
              what: 'the multi-series answer for $key');
      final downsampled = await station.request(
          DataServiceMethods.timeseriesQueryDownsampled,
          params: {
            'table': key,
            'from': _ms(_tsBase),
            'to': _ms(to),
            'maxPoints': 100,
          },
          what: 'the downsampled series for $key');
      return {
        'one': one,
        'many': many,
        'downsampled': downsampled,
      };
    }, key);

/// The key list, read off the production decorator.
///
/// Not on the wire — the handler table is nine names and none of them returns
/// a key list — so this one is asked of the object the gateway is actually
/// serving through rather than over the socket. It is in the loop because it
/// is the surface the other five inherit their answer from, and a
/// regression here would show up as five failures with no obvious cause.
Future<Object?> _askKeys(_Gateway gateway, _Station station, String key) async =>
    {'present': gateway.served.keys.contains(key)};

void main() {
  // The two groups that used to open this file — `AllVisibleOperatorWrites`'
  // semantics and the two-member `KeyPolicy` mirror pin — are gone with their
  // subjects: 17-04 replaced the shipped policy with `AccessPolicyKeyPolicy`
  // and grew the interface a third member, and `key_policy_test.dart` carries
  // the up-to-date copies of both (the three-member synchronous pin, the
  // package-uri pin, and the adapter's four properties). A second copy here
  // would be the drift D-12 is about.

  group('the operate vocabulary is gone from the decorator', () {
    /// The decorator's source, comment lines stripped, so a pin about code
    /// cannot be satisfied or tripped by prose. Same stripping rule the
    /// 17-04b parser pins use: whole-line comments only, because this file's
    /// house style never trails a comment on a code line.
    List<String> strippedSource() {
      final lines = File('lib/src/policy/policy_state_man.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .toList();
      // Anti-vacuity: a wrong path reads nothing and every "contains no X"
      // below would be true of an empty list.
      expect(lines.length, greaterThan(400),
          reason: 'the decorator is a long file; a source read this short '
              'means the path is wrong and the pins below are counting an '
              'empty list');
      return lines;
    }

    test('requireOperate exists nowhere', () {
      final offending = strippedSource()
          .where((line) => line.contains('requireOperate'))
          .toList();
      expect(offending, isEmpty,
          reason: 'the seven-times-one-question gate survived. Sweep §3.12 '
              'point 1: the relay graded by station role over the same rows '
              'the app grades by key, and `requireOperate` was that second '
              'rule\'s name. Every gate now takes the group the policy '
              'supplies for that key and that member — found: $offending');
    });

    test('no group literal in the file — the decorator asks, it does not know',
        () {
      final literal = RegExp(
          r'AccessGroup\.(operate|setpoints|device|force|configure|'
          r'administer|users)');
      final offending = strippedSource()
          .where((line) => literal.hasMatch(line))
          .toList();
      expect(offending, isEmpty,
          reason: 'a group literal in the decorator is a rule stated a second '
              'time — the exact duplication "one master system" deletes. The '
              'group in every gate and every audit row must be the one '
              'AccessPolicy answered, never one this file named — found: '
              '$offending');
    });
  });

  group('the decorator hides through the key list', () {
    test('a hidden key is absent from the key list', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      gateway.plant.setValue(_key, 1200);
      gateway.plant.setValue(_hidden, 900);
      await gateway.station();

      expect(gateway.plant.keys, contains(_hidden),
          reason: 'the anti-vacuity half, and it goes first: the source really '
              'does serve this tag. Without it the case below would pass '
              'against a policy that hides nothing, because the tag would be '
              'absent for the ordinary reason');
      expect(gateway.served.keys, isNot(contains(_hidden)),
          reason: '`keys` is the hiding primitive (06-RESEARCH §E.2). It is '
              'the one getter that read, readFresh, readMany, subscribe and '
              'write all already gate on, so filtering it is what makes a '
              'hidden tag take the nonexistent-tag path on every one of them '
              'with no edit to any of those surfaces. A decorator that hid '
              'per-surface instead would be five places to forget');
      expect(gateway.served.keys, contains(_key),
          reason: 'a filter that removed everything would pass the assertion '
              'above and break the plant. The visible tag is the control');
    });

    test('the decorator is transparent under the shipped policy', () async {
      final gateway = await _Gateway.start();
      gateway.plant.setValue(_key, 1200);
      gateway.plant.setValue(_hidden, 900);
      await gateway.station();

      expect(
          gateway.served.keys,
          equals([
            ...gateway.plant.keys,
            ...SessionHealthStateMan.perSessionKeys,
          ]),
          reason: 'under the shipped AccessPolicyKeyPolicy the decorator must '
              'be '
              'invisible — same list, same order. It sits in the path of '
              'every request the whole suite makes, so anything it changes '
              'here it changes for all of them, and a leak found later '
              'would be attributed to the policy instead of to the plumbing. '
              'The six trailing names are not the policy: they are the '
              'per-session health overlay underneath it (08-12), and naming '
              'them here rather than relaxing the matcher is what keeps this '
              'case able to see the policy add or drop one');
    });

    test('readFresh answers a hidden key the way it answers a nonexistent one',
        () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      gateway.plant.setValue(_hidden, 900);
      final station = await gateway.station();

      final forHidden =
          _asMap(await station.request(Methods.readFresh, params: {
        'key': _hidden,
      }));
      final forGhost = _asMap(await station.request(Methods.readFresh, params: {
        'key': _ghost,
      }));

      // Compared to each other with only the key name normalized, never
      // against literals: a later phase changing the nonexistent shape must
      // change both, which is exactly the property 06-04 established between
      // `read` and `readFresh` and this one inherits.
      expect(_withoutKeyName(forHidden, _hidden),
          equals(_withoutKeyName(forGhost, _ghost)),
          reason: 'readFresh gave a hidden tag a different answer from one '
              'that never existed. Any difference at all is an existence '
              'oracle: ask about a thousand names, keep the ones answered '
              'differently, and the plant\'s address space has been '
              'enumerated by a station that may not read a byte of it');
      expect(_asMap(forHidden['value'])['v'], isNull,
          reason: 'the reading itself must not come through. A hidden tag '
              'that answered 900 under a bad quality would be the value '
              'leaking behind the concealment');
    });

    test('the decorator\'s readFresh refuses a hidden key without asking the '
        'source', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      gateway.plant.setValue(_hidden, 900);
      await gateway.station();

      final before = gateway.plant.roundTrips;
      final answer = await gateway.served.readFresh(_hidden);

      expect(gateway.plant.roundTrips, before,
          reason: 'readFresh is an override and not a delegation, on purpose '
              '(§E.2 item 2). Forwarding would make the answer the source\'s '
              'to choose: FakeStateMan happens to answer q:258, and '
              'LocalStateMan over a real DeviceClient may throw — neither is '
              'the nonexistent shape this gateway promises, and a round trip '
              'to the plant for a tag the caller may not know exists is a '
              'side channel besides');
      expect(answer.quality, Quality.errorConfig,
          reason: 'the quality the gateway gives a tag its source does not '
              'serve (06-04): 770 is "the source affirmatively said the tag '
              'is gone", which is the sentence a hidden tag must also get. '
              '258 would say "wait, it is coming" about something that never '
              'will');
      expect(answer.value, isNull);
    });
  });

  group('the decorator owns nothing it could tear down', () {
    test('closing one session leaves another\'s reads working', () async {
      final gateway = await _Gateway.start();
      gateway.plant.setValue(_key, 1200);
      final first = await gateway.station();
      final second = await gateway.station();
      expect(gateway.sessions, hasLength(2));

      await gateway.sessions.first
          .close(CloseCodes.serverDraining, 'the first station is going away');
      await within(first.done, 'the first station\'s socket to finish',
          budget: const Duration(seconds: 3));

      final answer =
          _asMap(await second.request(Methods.read, params: {'key': _key}));

      expect(second.isOpen, isTrue,
          reason: 'the surviving station lost its socket when its neighbour '
              'closed. The decorator holds no resources of its own, so its '
              'dispose must delegate and nothing more — the source is one '
              'instance shared by every panel on this gateway '
              '(relay_server.dart:213-214, "One instance, shared"), and a '
              'per-session teardown that disposed it would take the whole '
              'plant down with one panel');
      expect(_asMap(answer['value'])['v'], 1200,
          reason: 'the surviving station can still read. An open socket over '
              'a disposed source is the quieter half of the same failure');
    });
  });

  group('a series the gateway cannot map is a series that does not exist', () {
    test('an unmapped series answers exactly as a hidden one does', () async {
      final gateway = await _Gateway.start(
          policy: ScriptedPolicy.hiding(const {_hidden}),
          resolver: const _MapsTheRealTags());
      final station = await gateway.station();

      final forUnmapped = await _askTimeseries(gateway, station, _unmapped);
      final forHidden = await _askTimeseries(gateway, station, _hidden);

      expect(_withoutKeyName(forUnmapped! as Map<String, Object?>, _unmapped),
          equals(_withoutKeyName(forHidden! as Map<String, Object?>, _hidden)),
          reason: 'a series with no mapping was told apart from one the '
              'station may not see. Both must be the answer a series that '
              'does not exist gets, and the reason they must agree is that '
              'the difference is an oracle: the first says "this gateway '
              'does not collect that", which is a fact about the collection '
              'plan, and the second says "there is history here you may not '
              'have", which is the enumeration the hiding rule closes. '
              'Compared structurally rather than restated as a literal, so a '
              'later phase changing the nonexistent shape has to change both');
    });

    test('an unmapped series answers exactly as a nonexistent one does',
        () async {
      final gateway = await _Gateway.start(resolver: const _MapsTheRealTags());
      final station = await gateway.station();

      final forUnmapped = await _askTimeseries(gateway, station, _unmapped);
      final forGhost = await _askTimeseries(gateway, station, _ghost);

      expect(_withoutKeyName(forUnmapped! as Map<String, Object?>, _unmapped),
          equals(_withoutKeyName(forGhost! as Map<String, Object?>, _ghost)),
          reason: 'under the *shipped* policy, which hides nothing, an '
              'unmappable series must still be indistinguishable from a '
              'mapped series with no samples. Otherwise a station learns '
              'which names the collection plan contains without ever being '
              'refused anything');
    });

    test('the multi-series path answers an empty entry, never an omission',
        () async {
      final gateway = await _Gateway.start(
          policy: ScriptedPolicy.hiding(const {_hidden}),
          resolver: const _MapsTheRealTags());
      final station = await gateway.station();

      final answered = _asMap(await station.request(
          DataServiceMethods.timeseriesQueryMultiple,
          params: {
            'tables': [_key, _hidden, _unmapped],
            'to': _ms(_tsBase.add(const Duration(hours: 1))),
            'from': _ms(_tsBase),
          },
          what: 'one visible, one hidden and one unmappable series'));

      expect(answered.keys, containsAll([_key, _hidden, _unmapped]),
          reason: 'check 8\'s rule holds for hidden and unmappable series '
              'too: an absent entry and an empty entry are different answers '
              'and only one of them is true. An omission would also be a '
              'perfect existence oracle — the chart would learn exactly which '
              'of the three names the gateway is willing to serve');
      expect(answered[_hidden], isEmpty);
      expect(answered[_unmapped], isEmpty);
      expect(answered[_key], isNotEmpty,
          reason: 'and the visible series is still answered, or the filter '
              'is emptying everything and the two assertions above are true '
              'for the wrong reason');
    });

    test('the unmappable count moves exactly once per unmappable query, and '
        'is readable without a debugger', () async {
      final gateway = await _Gateway.start(resolver: const _MapsTheRealTags());
      final station = await gateway.station();
      final tally = gateway.server.seriesTally;

      final before = tally.unmappableQueries;
      await station.request(DataServiceMethods.timeseriesQuery,
          params: {
            'table': _unmapped,
            'to': _ms(_tsBase.add(const Duration(hours: 1))),
          },
          what: 'one query for a series with no mapping');

      expect(tally.unmappableQueries, before + 1,
          reason: 'the wire answer for an unmappable series is deliberately '
              'silent, so this count is the only place the gap is visible. '
              '10-CONTEXT amendment 6 requires an unmappable table to be '
              '*visible*, not merely refused, and the refusal itself cannot '
              'name what it refused without breaking the hiding rule — so '
              'the gateway-side count is the reconciliation. A chart pointed '
              'at a pre-cutover table looks exactly like a database problem '
              'the first time it happens, and this is what makes it one '
              'query instead of one afternoon');
      expect(tally.unmappableNames, contains(_unmapped),
          reason: 'a bare count says something is wrong; the name says which '
              'series to add to the collection plan. This is read off the '
              'server, never sent');

      await station.request(DataServiceMethods.timeseriesQuery,
          params: {
            'table': _key,
            'to': _ms(_tsBase.add(const Duration(hours: 1))),
          },
          what: 'one query for a series that does map');

      expect(tally.unmappableQueries, before + 1,
          reason: 'a series that resolves must not be counted. A count that '
              'rose on every query would be a count nobody could read '
              'anything out of');
    });

    test('a member address is resolved once, and canSee is asked about the '
        'series', () async {
      final gateway = await _Gateway.start(
          policy: ScriptedPolicy.hiding(const {_hidden}),
          resolver: const _MapsTheRealTags());
      final station = await gateway.station();
      final tally = gateway.server.seriesTally;

      final visible = await station.request(
          DataServiceMethods.timeseriesQuery,
          params: {
            'table': '$_key:speed',
            'to': _ms(_tsBase.add(const Duration(hours: 1))),
            'from': _ms(_tsBase),
          },
          what: 'one member of a visible series');
      final hidden = await station.request(DataServiceMethods.timeseriesQuery,
          params: {
            'table': '$_hidden:speed',
            'to': _ms(_tsBase.add(const Duration(hours: 1))),
            'from': _ms(_tsBase),
          },
          what: 'one member of a hidden series');

      expect(visible, isNotEmpty,
          reason: '`<series>:<member>` is the addressing 10-CONTEXT ruling 2 '
              'settled on, and the decorator has to let one through — '
              'otherwise every struct chart in the plant reads as a series '
              'that does not exist. **This sentence used to say "the member '
              'is stripped before the table is resolved, so a member address '
              'reaches the same table the bare name does", which was the '
              'CR-01 defect written down as intent.** It was true of the '
              'subject underneath — a fake reader that never looks at a '
              'member — and false of every real one: against `TimescaleReader` '
              'a bare name for a struct table is `StructSeriesUnaddressed`. '
              'The address travels down whole now, and '
              '`tfc_relay_local/test/composed_seam_test.dart` is what judges '
              'that against the real reader');
      expect(hidden, isEmpty,
          reason: 'and canSee is asked about the *series* key, not about the '
              'member. A policy is written about tags; "CN02.MOT01.speed" is '
              'a tag and "CN02.MOT01.speed:speed" is a chart\'s way of '
              'selecting a column out of one. Asking about the second would '
              'answer true for every hidden struct in the plant');
      expect(tally.unmappableQueries, 0,
          reason: 'a member of a series that maps is not an unmappable '
              'series; counting it would fill the diagnostic with names that '
              'are fine');

      // **The assertion that would have caught CR-01**, and the one the rest
      // of this file structurally could not make: what the layer below was
      // HANDED, rather than what came back. Every other resolver in the suite
      // answers `table == series`, which makes "the name" and "the table"
      // indistinguishable; `_MapsTheRealTags` prefixes, so they are two
      // different strings and only one of them is right.
      expect(gateway.history.asked, equals(<String>['$_key:speed']),
          reason: 'the source must be handed the address the caller spelled — '
              'the wire name, with its member — and must be handed it once. '
              'Before the fix it was handed "gw_$_key", the PHYSICAL table '
              'with the member discarded, which a fake accepts and a real '
              'reader refuses twice over: it resolves its argument as a wire '
              'name (a miss on the prefix, so UnknownSeries) and, where the '
              'prefix is empty, it finds a struct with no member selected. '
              'The hidden series must not appear here at all — a hidden '
              'series may not cost a round trip, because the round trip is '
              'itself a side channel');
    });
  });

  // ---------------------------------------------------------------------
  // History views (10-04).
  //
  // **Deliberately a sibling group rather than a ninth `_surfaces` entry**,
  // and the reason is a property rather than a shape mismatch — so it is
  // written here rather than left for a reader to rediscover.
  //
  // The loop's premise is that asking a surface about a tag tells you whether
  // the *plant* has it, which is why "hidden" and "never existed" must answer
  // identically on all eight. A history view is not that kind of surface: its
  // key list is data the **client itself supplied**, so a view saved holding
  // `_ghost` comes back holding `_ghost` — the gateway stored a string, and
  // handing it back says nothing about the plant. A view saved holding
  // `_hidden` comes back without it. The two therefore differ *by design*, and
  // adding this to the loop would demand one of two changes, both worse than
  // the difference: keeping hidden keys (which is the leak the seam exists to
  // close), or dropping every key the gateway does not currently serve (which
  // would silently destroy an operator's saved view every time a tag is
  // renamed or a station is reconfigured).
  //
  // **What that leaves is a residual oracle, and it is recorded rather than
  // waved past.** A station that may write views can save one holding a
  // candidate key, read it back, and learn from the key's absence that the
  // key exists and is hidden. It is a much narrower channel than the ones
  // T-06-36 closes — it costs a write, it needs the `operate` role, and PR
  // #403's logging is on that path — and every alternative examined is worse
  // (see `_PolicyHistoryViews`'s own doc for the write-side argument). Under
  // the shipped `AllVisibleOperatorWrites` it does not exist at all. Whoever
  // ships per-key hiding for real inherits this paragraph.
  group('a view holding a hidden key comes back without it', () {
    /// Saves a view over the wire and answers its id.
    Future<int> saveView(_Station station, List<String> keys,
            {Map<String, Object?>? graphConfigs}) async =>
        (await station.request(DataServiceMethods.historyCreateView,
            params: {
              'name': 'Vaktir',
              'keys': keys,
              if (graphConfigs != null) 'graphConfigs': graphConfigs,
            },
            what: 'saving a view over $keys'))! as int;

    Future<List<Object?>> keyNames(_Station station, int id) async =>
        (await station.request(DataServiceMethods.historyGetKeyNames,
            params: {'viewId': id}, what: 'the key names of view $id'))!
            as List<Object?>;

    test('the shipped policy keeps every key a view was saved with', () async {
      // **The anti-vacuity companion, and it goes first**, on this file's
      // convention: every case below asserts a key is *absent*, and without
      // this one they would all pass against a gateway whose views came back
      // empty for everybody.
      final gateway = await _Gateway.start();
      final station = await gateway.station();

      final id = await saveView(station, [_key, _hidden]);

      expect(await keyNames(station, id), containsAll([_key, _hidden]),
          reason: 'under the shipped policy nothing is hidden, so a view '
              'holding two keys holds two keys. If this fails, every "the '
              'hidden key is gone" assertion below is true because views are '
              'broken rather than because a filter ran');
    });

    test('the view still comes back, without the key', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final id = await saveView(station, [_key, _hidden]);

      final listed = (await station.request(
          DataServiceMethods.historySelectViews,
          params: const <String, Object?>{},
          what: 'the view picker'))! as List<Object?>;
      expect(listed.map((view) => (view! as Map)['id']), contains(id),
          reason: 'the view itself is not hidden and must not be: a view that '
              'vanished would say a view exists — the operator saved it, the '
              'picker offered it a moment ago, and its disappearance is a '
              'louder statement about the hidden key than the key\'s own '
              'absence is (T-10-13)');

      expect(await keyNames(station, id), [_key],
          reason: 'the hidden key is dropped from the key list, not from the '
              'view');

      final keys = _asMap(await station.request(
          DataServiceMethods.historyGetKeys,
          params: {'viewId': id},
          what: 'the keys of view $id'));
      expect(keys.keys, [_key],
          reason: 'and the record accessor agrees with the name-only one. A '
              'filter fitted to one and forgotten on the other would hide the '
              'key from the legend and hand it back to the chart');
    });

    test('a view all of whose keys are hidden is a view with no keys, never '
        'no view', () async {
      // **The boundary case**, and the only one where "drop the key" and
      // "drop the view" produce different answers. Everything else in this
      // group passes under either rule.
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final id = await saveView(station, [_hidden]);

      final listed = (await station.request(
          DataServiceMethods.historySelectViews,
          params: const <String, Object?>{},
          what: 'the view picker'))! as List<Object?>;
      expect(listed, hasLength(1),
          reason: 'the view is still there. Dropping it would be the one '
              'thing the rule forbids: an operator opening the picker would '
              'see a view they saved simply gone, which is a statement about '
              'the key it held');
      expect((listed.single! as Map)['id'], id);
      expect((listed.single! as Map)['name'], 'Vaktir',
          reason: 'and it still carries its name — a view is more than its '
              'key list');

      expect(await keyNames(station, id), isEmpty,
          reason: 'with an empty key list, which is an honest answer: the '
              'chart draws no lines and the operator can see that it draws '
              'none');
    });

    // ------------------------------------------------------------------
    // The read side, against a store that really holds the hidden key.
    //
    // **The two cases above cannot prove it and must not be read as if they
    // did.** A view saved *through this gateway* never stores a hidden key —
    // the write side drops it on the way in — so the row those cases read back
    // has one key in it and the read filter has nothing to do. They are
    // write-side cases wearing read-side clothes, and the sabotage that
    // removes the read filter leaves both of them green.
    //
    // A store that genuinely holds a key this station may not see is not a
    // contrived state; it is the ordinary one. A view outlives the policy that
    // was in force when it was saved, another station with a different policy
    // saved it, or the application wrote it straight into the database. So
    // these two seed the view on the **unpoliced plant** and then ask over the
    // wire, which is the only arrangement in which the read filter is the
    // thing under test.
    // ------------------------------------------------------------------

    test('a view the store already holds gives up its hidden key on the way '
        'out', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final id = await gateway.plant.historyViews
          .createHistoryView('Vaktir', [_key, _hidden]);
      final station = await gateway.station();

      expect(
          (await gateway.plant.historyViews.getHistoryViewKeys(id)).keys,
          containsAll([_key, _hidden]),
          reason: 'the store really holds both keys, or this case is asking a '
              'filter to remove something that was never there');

      expect(await keyNames(station, id), [_key],
          reason: 'the read side drops the hidden key out of a row that '
              'genuinely contains it');
      expect(
          _asMap(await station.request(DataServiceMethods.historyGetKeys,
                  params: {'viewId': id}, what: 'the keys of view $id'))
              .keys,
          [_key],
          reason: 'and the record accessor agrees');
    });

    test('a stored view whose every key is hidden is still a view, with an '
        'empty key list', () async {
      // **The boundary case, in the only place it can bite.** This is where
      // "drop the key" and "drop the view" give different answers: under the
      // first the picker still offers the view, under the second the operator
      // watches a view they saved disappear.
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final id = await gateway.plant.historyViews
          .createHistoryView('Vaktir', [_hidden]);
      final station = await gateway.station();

      final listed = (await station.request(
          DataServiceMethods.historySelectViews,
          params: const <String, Object?>{},
          what: 'the view picker'))! as List<Object?>;

      expect(listed, hasLength(1),
          reason: 'a view that vanished would say a view exists. The operator '
              'saved it, the picker offered it a moment ago, and its '
              'disappearance is a louder statement about the key it held than '
              'the key\'s own absence is (T-10-13)');
      expect((listed.single! as Map)['id'], id);
      expect(await keyNames(station, id), isEmpty,
          reason: 'and it comes back with no keys, which is honest: the chart '
              'draws no lines and the operator can see that it draws none');
    });

    test('graphs are untouched by the filter', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final id = await saveView(station, [_hidden],
          graphConfigs: historyViewGraphsToJson(const {
            0: HistoryViewGraphRecord(graphIndex: 0, name: 'Hraði'),
            1: HistoryViewGraphRecord(
                graphIndex: 1, name: 'Hitastig', yAxisUnit: '°C'),
          }));

      final graphs = _asMap(await station.request(
          DataServiceMethods.historyGetGraphs,
          params: {'viewId': id},
          what: 'the graphs of a view whose every key is hidden'));

      expect(graphs.keys, hasLength(2),
          reason: 'a graph index is not a key and there is nothing to hide in '
              'a title or an axis unit. Filtering graphs alongside keys is '
              'the plausible over-reach here, and it would leave a view whose '
              'axes lost their labels for a reason nobody could find');
      expect(_asMap(graphs['1'])['yAxisUnit'], '°C');
    });

    test('a hidden key never reaches the store on the way in', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final id = await saveView(station, [_key, _hidden]);

      // Read off the **unpoliced** source, which is the only way to tell a
      // key that was dropped on the way in from one that is merely filtered
      // on the way out. The read-side filter would make both look identical
      // over the wire.
      final stored =
          await gateway.plant.historyViews.getHistoryViewKeys(id);
      expect(stored.keys, [_key],
          reason: 'the hidden key was dropped from the *input*, silently, so '
              'nothing about it was written down. Refusing the save would '
              'have named it — "this view holds a key you may not see" is the '
              'same disclosure a `forbidden` is — and storing it would leave '
              'the gateway holding a row whose only protection is that a '
              'filter remembers to run on every future read path');
    });

    test('an update drops a hidden key too', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final id = await saveView(station, [_key]);
      await station.request(DataServiceMethods.historyUpdateView,
          params: {
            'id': id,
            'name': 'Vaktir',
            'keys': [_key, _hidden],
          },
          what: 'an update adding a hidden key to a view');

      expect(await keyNames(station, id), [_key],
          reason: 'update is the other write-shaped door into the same rows, '
              'and a filter fitted to create and forgotten on update would '
              'let any station store any key by saving an empty view and then '
              'editing it');
      expect((await gateway.plant.historyViews.getHistoryViewKeys(id)).keys,
          [_key],
          reason: 'on the way in, as with create');
    });
  });

  // -----------------------------------------------------------------------
  // History views, graded by member — the app's split, in both directions
  // (17-CONTEXT D-04, ruled 2026-09-07).
  //
  // 10-REVIEW CR-03 put one gate — "the role a setpoint takes" — on the four
  // destructive members, and that was the relay grading by station role over
  // the same rows the panel grades by member (sweep §3.12). The panel's
  // split, which wins in BOTH directions: the two deletes need `configure`
  // (destroying work that was not yours), and create, update and addPeriod
  // are OPEN — matching `guarded_history_views.dart`'s
  // `kHistoryViewWriteGroup == null`, stated by the policy rather than by the
  // absence of a call. So `deleteHistoryView` tightens (operate no longer
  // suffices) while `updateHistoryView` and `addHistoryViewPeriod` loosen to
  // where the panel has always had them.
  //
  // Over a real socket, deliberately. The gate has to hold where a station
  // actually reaches it, and each identity here is minted by the same
  // validator seam a token file drives.
  // -----------------------------------------------------------------------
  group('a history-view member takes the group the panel\'s guard takes',
      () {
    /// The five mutators, as a name and a request against view [id].
    Map<String, ({String method, Map<String, Object?> params})> mutators(
            int id) =>
        <String, ({String method, Map<String, Object?> params})>{
          'createView': (
            method: DataServiceMethods.historyCreateView,
            params: <String, Object?>{'name': 'Vaktir', 'keys': <String>[_key]},
          ),
          'updateView': (
            method: DataServiceMethods.historyUpdateView,
            params: <String, Object?>{
              'id': id,
              'name': 'Endurskírt',
              'keys': <String>[_key],
            },
          ),
          'deleteView': (
            method: DataServiceMethods.historyDeleteView,
            params: <String, Object?>{'id': id},
          ),
          'addPeriod': (
            method: DataServiceMethods.historyAddPeriod,
            params: <String, Object?>{
              'viewId': id,
              'name': 'Vakt 1',
              'start': _ms(_tsBase),
              'end': _ms(_tsBase.add(const Duration(hours: 8))),
            },
          ),
          'deletePeriod': (
            method: DataServiceMethods.historyDeletePeriod,
            // Any int: `_viewId` deliberately does not bound it, which is
            // itself part of why the gate matters — enumeration of live ids by
            // delete was free.
            params: <String, Object?>{'id': 1},
          ),
        };

    /// The names of every view the **unpoliced** store holds.
    ///
    /// Read off the source rather than over the wire, because "the view is
    /// still there" is a claim about the rows and a read-side filter could
    /// make a deleted view and a hidden one look the same.
    Future<List<String>> storedViews(_Gateway gateway) async => [
          for (final view in await gateway.plant.historyViews
              .selectHistoryViews())
            view.name,
        ];

    test('a configure-holding station may do all five, and the store records '
        'them', () async {
      // **The anti-vacuity companion, and it goes first.** Every arm below
      // asserts a refusal; without this one they would all pass against a
      // gateway whose history views were broken for everybody, which is
      // exactly the failure a wall display would report as "the charts are
      // gone".
      final gateway = await _Gateway.start(
          identity: stationHolding(
              const {AccessGroup.operate, AccessGroup.configure}));
      final station = await gateway.station();

      final id = (await station.request(DataServiceMethods.historyCreateView,
          params: const {'name': 'Vaktir', 'keys': <String>[_key]},
          what: 'an operate station saving a view'))! as int;
      final periodId = (await station.request(
          DataServiceMethods.historyAddPeriod,
          params: {
            'viewId': id,
            'name': 'Vakt 1',
            'start': _ms(_tsBase),
            'end': _ms(_tsBase.add(const Duration(hours: 8))),
          },
          what: 'an operate station saving a window'))! as int;
      await station.request(DataServiceMethods.historyUpdateView,
          params: {'id': id, 'name': 'Endurskírt', 'keys': <String>[_key]},
          what: 'an operate station renaming its view');
      await station.request(DataServiceMethods.historyDeletePeriod,
          params: {'id': periodId},
          what: 'an operate station removing the window');
      await station.request(DataServiceMethods.historyDeleteView,
          params: {'id': id}, what: 'an operate station removing the view');

      expect(await storedViews(gateway), isEmpty,
          reason: 'all five reached the store. If this fails, every refusal '
              'below is passing because history views do not work rather than '
              'because a gate ran');
    });

    for (final name in const ['deleteView', 'deletePeriod']) {
      test('an operate station\'s $name is refused, pre-effect — the two '
          'destructive members take configure', () async {
        // D-04's behaviour change on the wire, carried by these two arms:
        // `operate` used to suffice for a delete here, and the panel's guard
        // has always demanded `configure`. `deletePeriod` is also the member
        // the relay gated and the panel graded *differently*, now agreeing.
        final gateway = await _Gateway.start(identity: _panel);
        // Seeded through the **unpoliced** source: this case is about a
        // station destroying work it did not do, so the work has to exist
        // before the station connects and must not itself be a gated call.
        final id = await gateway.plant.historyViews
            .createHistoryView('Vaktir', [_key]);
        await gateway.plant.historyViews
            .addHistoryViewPeriod(id, 'Vakt 1', _tsBase, _tsBase.add(
                const Duration(hours: 8)));
        final station = await gateway.station();

        final call = mutators(id)[name]!;
        final refusal = await station.refusal(call.method,
            params: call.params, what: '$name from an operate-only station');

        expect(refusal.code, ServerErrorCodes.forbidden,
            reason: 'the same code and the same argument as the preference '
                'gate: reads here are all-visible, so the station has already '
                'been told the view exists and there is no existence left to '
                'conceal. What it needs is a permission, and `forbidden` is '
                'the one answer it can act on');
        expect(refusal.message, contains('history.'),
            reason: 'a refusal that does not name the call it refused is one '
                'an engineer cannot act on');

        expect(await storedViews(gateway), ['Vaktir'],
            reason: 'pre-effect: the view is another engineer\'s work and it '
                'has to still be there. A gate that fired after the DELETE '
                'would be a report, not a gate — and unlike a preference '
                'there is nothing that can put this row back');
        expect(
            await gateway.plant.historyViews.listHistoryViewPeriods(id),
            hasLength(1),
            reason: 'and so does its saved window, which the cascade would '
                'have taken with the view');
      });
    }

    test('a station holding nothing may create, update and add a period — '
        'deliberate parity with kHistoryViewWriteGroup == null', () async {
      // NOT a hole. `guarded_history_views.dart` leaves the three creative
      // members open to any session, anonymous included — an operator saving
      // a view of the line they run is doing their job — and the app's split
      // wins in both directions (D-04). The relay used to gate `update` and
      // `addPeriod` at operate where the panel leaves them open; these arms
      // are that disagreement closing from the loosening side, and the two
      // delete arms above are it closing from the tightening side.
      final gateway = await _Gateway.start(identity: _display);
      final station = await gateway.station();

      final id = (await station.request(DataServiceMethods.historyCreateView,
          params: const {'name': 'Vaktir', 'keys': <String>[_key]},
          what: 'a station holding no groups saving a chart'))! as int;
      await station.request(DataServiceMethods.historyUpdateView,
          params: {'id': id, 'name': 'Endurskírt', 'keys': const <String>[_key]},
          what: 'a station holding no groups renaming its chart');
      await station.request(DataServiceMethods.historyAddPeriod,
          params: {
            'viewId': id,
            'name': 'Vakt 1',
            'start': _ms(_tsBase),
            'end': _ms(_tsBase.add(const Duration(hours: 8))),
          },
          what: 'a station holding no groups bookmarking a window');

      expect(await storedViews(gateway), ['Endurskírt'],
          reason: 'all three creative members reached the store for a session '
              'holding nothing at all, exactly as they do at a panel');
    });

    test('an operate-and-configure station deletes, and the store records it',
        () async {
      // The live control for the two refusal arms: the same member, one
      // group later, goes through. Without it a gate that refused every
      // delete for everybody would pass those arms.
      final gateway = await _Gateway.start(
          identity: stationHolding(
              const {AccessGroup.operate, AccessGroup.configure}));
      final id = await gateway.plant.historyViews
          .createHistoryView('Vaktir', [_key]);
      final station = await gateway.station();

      await station.request(DataServiceMethods.historyDeleteView,
          params: {'id': id}, what: 'a configure-holding station deleting');

      expect(await storedViews(gateway), isEmpty,
          reason: 'configure is the group the panel\'s guard demands for a '
              'delete, and holding it must be sufficient over the wire too — '
              'the same table, the same answer');
    });

    test('the reads stay open to a station holding nothing', () async {
      // The other half of the line: gating a read would leave a wall display
      // showing an empty picker, which is the failure the gate is supposed to
      // prevent arriving from the other side.
      final gateway = await _Gateway.start(identity: _display);
      final id = await gateway.plant.historyViews
          .createHistoryView('Vaktir', [_key]);
      final station = await gateway.station();

      final listed = (await station.request(
          DataServiceMethods.historySelectViews,
          params: const <String, Object?>{},
          what: 'the picker, on a wall display'))! as List<Object?>;
      expect(listed, hasLength(1));
      expect(
          await station.request(DataServiceMethods.historyGetKeyNames,
              params: {'viewId': id}, what: 'the keys of a view'),
          [_key]);
      await station.request(DataServiceMethods.historyListPeriods,
          params: {'viewId': id}, what: 'the windows of a view');
    });
  });

  // **Preferences: reads for everyone, writes graded BY KEY** — the same
  // `kPrefAccessRules` table the panel is graded by (17-CONTEXT D-03, ruled
  // 2026-09-07; sweep §3.12 point 1).
  //
  // A sibling group rather than a ninth `_surfaces` entry, and for a plainer
  // reason than the history-view group's: a preference key is not a plant key
  // at all. `svn.chart.maxPoints` names a row in the gateway's own settings
  // store, and asking the indistinguishability loop about it would be asking
  // whether the *plant* has a tag by that name.
  //
  // What this group asserts is the phase's centre: the relay used to ask ONE
  // question — "may this station actuate?" — about every preference key
  // alike, over the same rows in the same `flutter_preferences` table in the
  // same Postgres the app grades per key. So a station the gateway called
  // `operate` could `setString('key_mappings', …)` and re-point the plant's
  // tag map while an operator standing at a panel with the same grade could
  // not. One master table now answers both.
  //
  // These cases drive the decorator **in process** rather than over a socket,
  // and that is not a shortcut: the pre-effect property is "the store was not
  // touched", which needs a store that counts, and the no-identity arm needs a
  // session state the handshake gate makes unreachable from the wire. The
  // wire-level half — a refusal with -32005 over a real socket — is
  // `data_handlers_test.dart`'s and the contract legs'.
  group('a preference write is graded by key, by the app\'s own table', () {
    /// One recording store, and the decorator [identity] sees it through.
    ///
    /// Built by hand rather than read off a live session because
    /// `_Gateway.start` has no preference lever and because two of the arms
    /// below are about an identity a session cannot be in while it is
    /// answering: null, which is every session between `serve` and `hello`.
    ({_RecordingPreferences store, PolicyStateMan served}) seenBy(
        StationIdentity? identity) {
      final store = _RecordingPreferences();
      final plant = FakeStateMan(preferences: store);
      addTearDown(plant.dispose);
      return (
        store: store,
        served: PolicyStateMan(
          source: plant,
          // The shipped adapter over the shipped master policy, deliberately:
          // the grading under test is `kPrefAccessRules` itself, not a
          // scripted double's answer.
          policy: const AccessPolicyKeyPolicy(),
          resolver: const PermissiveSeriesResolver(),
          tally: SeriesMappingTally(),
          identityOf: () => identity,
        ),
      );
    }

    /// Every mutator, as a name and a call. Seven, and the count is asserted.
    final mutators = <String, Future<void> Function(PreferencesApi prefs)>{
      'setBool': (prefs) => prefs.setBool('svn.ui.dark', true),
      'setInt': (prefs) => prefs.setInt('svn.chart.maxPoints', 800),
      'setDouble': (prefs) => prefs.setDouble('svn.weigher.tolerance', 0.25),
      // The one this ruling is actually about.
      'setString': (prefs) => prefs.setString('key_mappings', '{"CN01":"x"}'),
      'setStringList': (prefs) =>
          prefs.setStringList('svn.page.recent', const ['frystir']),
      'remove': (prefs) => prefs.remove('svn.ui.dark'),
      // **Allow-listed**, because the unrestricted form is refused outright
      // for every role now (10-REVIEW CR-02) and would make this map's
      // `operate` arm assert the wrong thing. The role gate on `clear` is
      // still what these arms measure: it fires before the allow-list check,
      // so a `view` station is refused for the role and an `operate` station
      // gets through to the store. The unrestricted form has its own group
      // below.
      'clear': (prefs) => prefs.clear(allowList: const {'svn.ui.dark'}),
    };

    test('a station holding every group writes, and the store records it',
        () async {
      // **The anti-vacuity companion, and it goes first.** Every arm below
      // asserts a write was *refused* and that the store recorded nothing;
      // without this one they would all pass against a decorator that refused
      // everybody, and against a recorder that never recorded.
      final panel = seenBy(_engineer);

      for (final mutator in mutators.entries) {
        await mutator.value(panel.served.preferences);
      }

      expect(panel.store.writes, mutators.keys.toList(),
          reason: 'a station holding the full group set holds whatever group '
              'each of these keys grades to, so every mutator must reach the '
              'store. If this fails, every refusal arm below is passing '
              'because nothing writes rather than because the gate ran');
      expect(mutators, hasLength(7),
          reason: 'seven mutators is the surface being gated — five typed '
              'setters, remove and clear. A mutator added to PreferencesApi '
              'and not to this map is one nobody checked the grading on');
    });

    for (final mutator in mutators.entries) {
      test('a station holding nothing has its ${mutator.key} refused, '
          'pre-effect', () async {
        final display = seenBy(_display);

        final refusal = await _refused(
            () => mutator.value(display.served.preferences),
            '${mutator.key} from a station holding no groups');

        expect(refusal.code, ServerErrorCodes.forbidden,
            reason: '`forbidden` is the right refusal here and `unknownKey` '
                'would be wrong, which makes this the one place '
                'where naming the refusal is the correct answer. Preference '
                'reads are all-visible, so this station has already been told '
                'the key exists — there is no existence left to conceal, and '
                'the two facts a client acts on differently are "fix the key '
                'name" and "obtain the permission". This is the second');
        expect(refusal.message, contains(mutator.key),
            reason: 'a refusal that does not name the call it refused is one '
                'an engineer cannot act on');
        expect(display.store.writes, isEmpty,
            reason: 'the refusal must be **pre-effect**: the store recorded '
                '${display.store.writes} for a call that was refused. A gate '
                'that fires after the write has landed is not a gate, it is a '
                'report — and for `key_mappings` it would be a report that the '
                'plant\'s tag map has already been re-pointed');
      });
    }

    // -------------------------------------------------------------------
    // `alarm_man_config`, named on its own.
    //
    // It is covered by the `configure` rule the table below exercises through
    // `key_mappings`, so these two arms add no new *grading*. What they add is
    // the thing a reader of this file cannot otherwise check: that the panel
    // change which put the alarm editor's writes on this wire lands on a gate
    // that is **here**, on the server, above the one store the backend holds
    // — not on the panel deciding for itself whether to send the frame. An
    // alarm rule is a plant-wide safety rule; "the client did not ask" is not
    // an access control, and a panel is not entitled to be the thing that
    // enforces one.
    // -------------------------------------------------------------------
    test('an operator station is refused alarm_man_config by the server, '
        'pre-effect', () async {
      final panel = seenBy(_panel); // holds `operate`, and not `configure`

      final refusal = await _refused(
          () => panel.served.preferences
              .setString('alarm_man_config', '{"alarms":[]}'),
          'an alarm-config write from a station holding only operate');

      expect(refusal.code, ServerErrorCodes.forbidden);
      expect(panel.store.writes, isEmpty,
          reason: 'the alarm editor\'s write must be stopped before it '
              'reaches the store. A rule that lands and is then reported as '
              'refused is a rule the plant is already running');
    });

    test('a station holding configure writes alarm_man_config through',
        () async {
      // The anti-vacuity half: without it the arm above passes against a
      // decorator that refuses this key for everybody, which would break the
      // alarm editor rather than gate it.
      final engineer = seenBy(_engineer);
      await engineer.served.preferences
          .setString('alarm_man_config', '{"alarms":[]}');
      expect(engineer.store.writes, ['setString']);
    });

    // -------------------------------------------------------------------
    // Graded BY KEY: the table, thirty cells (D-03).
    //
    // Six sessions crossed with five keys, one per rule kind plus the
    // default, each asserting the outcome of `setString` — allowed iff the
    // session holds the group `kPrefAccessRules` answers for that key. The
    // interesting cells are called out where they are:
    //
    //  * `key_mappings` refused for {operate} and allowed for
    //    {operate, configure} is **D-03's behaviour change**, the one the
    //    ruling accepted the deployment cost of.
    //  * `theme_mode` allowed for {operate} is the loosening nobody should
    //    read as one: a panel writing what a panel writes about itself.
    //  * an unmatched key refused for {operate, configure} is the
    //    `administer` default failing closed.
    // -------------------------------------------------------------------
    group('graded by key: six sessions, five keys', () {
      final sessions = <String, Set<AccessGroup>>{
        'nothing': const <AccessGroup>{},
        'operate': const {AccessGroup.operate},
        'operate+setpoints': const {AccessGroup.operate, AccessGroup.setpoints},
        'operate+configure': const {AccessGroup.operate, AccessGroup.configure},
        'operate+administer': const {
          AccessGroup.operate,
          AccessGroup.administer,
        },
        'all seven': AccessGroup.values.toSet(),
      };

      /// One row per key: the group the app's table answers, read off the
      /// master policy rather than restated, so the expectation column cannot
      /// drift from the table it is about.
      const keys = <String>[
        'key_mappings', // exact -> configure: D-03's key
        'theme_mode', // exact -> operate: what a panel writes about itself
        'collector_config', // exact -> administer
        'svn.batch.recipes', // suffix -> setpoints: the one runtime-built key
        'svn.uncharted.key', // unmatched -> the administer default
      ];

      for (final session in sessions.entries) {
        for (final key in keys) {
          final groups = session.value;
          final required = const AccessPolicy().groupForPref(key);
          final allowed = groups.contains(required);

          test('{${session.key}} × $key → '
              '${allowed ? 'allowed' : 'refused pre-effect'}', () async {
            final seat = seenBy(stationHolding(groups));

            if (allowed) {
              await seat.served.preferences.setString(key, 'gildi');
              expect(seat.store.writes, ['setString'],
                  reason: 'the session holds ${required.name}, which is what '
                      'the app\'s table answers for "$key", so the write '
                      'must reach the store — the same table, the same '
                      'answer, over the wire');
            } else {
              final refusal = await _refused(
                  () => seat.served.preferences.setString(key, 'gildi'),
                  'setString("$key") from {${session.key}}');
              expect(refusal.code, ServerErrorCodes.forbidden,
                  reason: '"$key" grades to ${required.name} in '
                      'kPrefAccessRules and this session does not hold it');
              expect(seat.store.writes, isEmpty,
                  reason: 'pre-effect, every cell: "the write was refused" is '
                      'cheap to assert and easy to satisfy by accident — the '
                      'store must never have been touched');
            }
          });
        }
      }

      test('the table is the app\'s, not a copy of it', () {
        // The expectation column above is computed from the production
        // `AccessPolicy`, so this arm is what keeps the six interesting
        // answers from drifting: if any of these six moves in
        // kPrefAccessRules, this fails here rather than thirty cells lying
        // in unison.
        const master = AccessPolicy();
        expect(master.groupForPref('key_mappings'), AccessGroup.configure,
            reason: 'D-03: key_mappings grades as configure everywhere, and '
                'there is no per-key exception');
        expect(master.groupForPref('theme_mode'), AccessGroup.operate);
        expect(master.groupForPref('collector_config'), AccessGroup.administer);
        expect(master.groupForPref('svn.batch.recipes'), AccessGroup.setpoints,
            reason: 'the one suffix rule: a recipes bucket is built at '
                'runtime, so only the tail is knowable');
        expect(
            master.groupForPref('svn.uncharted.key'), AccessGroup.administer,
            reason: 'anything unmatched fails closed to administer');
      });
    });

    test('a session with no identity may not write either', () async {
      final anonymous = seenBy(null);

      final refusal = await _refused(
          () => anonymous.served.preferences.setString('key_mappings', '{}'),
          'a setString from a session that never said hello');

      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'null identity means "nothing", not "everything" — the same '
              'rule `canSee` and `canWrite` already answer by. The state is '
              'unreachable from the wire because the handshake gate refuses '
              'every method before hello, but "unreachable" is a property of '
              'today\'s gate rather than of this class');
      expect(anonymous.store.writes, isEmpty);
    });

    test('a view station reads every typed getter', () async {
      final display = seenBy(_display);
      // Seeded past the gate, on the store itself: a fixture written through
      // the wrapper would be a write, and this case is about reads.
      await display.store.setBool('svn.ui.dark', true);
      await display.store.setInt('svn.chart.maxPoints', 800);
      await display.store.setDouble('svn.weigher.tolerance', 0.25);
      await display.store.setString('svn.site.name', 'Sæból');
      await display.store.setStringList('svn.page.recent', const ['frystir']);
      display.store.writes.clear();

      final prefs = display.served.preferences;

      expect(await prefs.getBool('svn.ui.dark'), isTrue);
      expect(await prefs.getInt('svn.chart.maxPoints'), 800);
      expect(await prefs.getDouble('svn.weigher.tolerance'), 0.25);
      expect(await prefs.getString('svn.site.name'), 'Sæból');
      expect(await prefs.getStringList('svn.page.recent'), ['frystir']);
      expect(await prefs.containsKey('svn.ui.dark'), isTrue);
      expect(await prefs.containsKey('svn.never.set'), isFalse,
          reason: 'reads are all-visible, so a wall display renders a settings '
              'page with real values in it. Gating the reads too would leave '
              'every non-operate station showing a page of blanks and would '
              'fail the round-trip contract check outright');
    });

    test('a view station enumerates the store', () async {
      final display = seenBy(_display);
      await display.store.setString('svn.site.name', 'Sæból');
      await display.store.setInt('svn.chart.maxPoints', 800);

      final prefs = display.served.preferences;

      expect(await prefs.getKeys(),
          containsAll(['svn.site.name', 'svn.chart.maxPoints']));
      expect(await prefs.getAll(),
          containsPair('svn.chart.maxPoints', 800));
    });

    test('a view station hears a change an operate station made', () async {
      final display = seenBy(_display);
      final heard = display.served.preferences.onPreferencesChanged.first;

      // Through the store, which is where a second client's edit arrives from.
      await display.store.setString('svn.site.name', 'Sæból');

      expect(await within(heard, 'the change reaching a view station'),
          'svn.site.name',
          reason: 'the change stream is a read surface. A settings page open '
              'on a wall display shows what the plant\'s settings are, and a '
              'station that may not write is exactly the one that has no other '
              'way to learn an operator changed something');
    });

    test('secret material stays impossible by construction, not by this gate',
        () async {
      // Re-asserted **here**, because this is the plan a future reader will be
      // standing in when they consider adding the parameter back. The gate
      // above is about `key_mappings`; it is not about secrets, and conflating
      // the two is how `{bool secret = false}` gets "helpfully" restored.
      final declared = reflectClass(PreferencesApi)
          .declarations
          .values
          .whereType<MethodMirror>()
          .expand((member) => member.parameters)
          .map((parameter) => MirrorSystem.getName(parameter.simpleName))
          .toSet();

      expect(declared, isNotEmpty,
          reason: 'the mirror read nothing, so the assertion below is true of '
              'an empty set rather than of the wire interface');
      expect(declared, isNot(contains('secret')),
          reason: 'the concrete `Preferences` class routes a `secret: true` '
              'call to secure storage at twelve sites. The wire interface '
              'omits the parameter, so there is no route from this pipe to the '
              'secure store at all — one client-supplied boolean would '
              'otherwise be remote secret retrieval (SEC-01, T-10-18). '
              '`api_surface_test.dart` sweeps every wire interface for it; '
              'this arm is the one standing next to the gate');
    });

    // -------------------------------------------------------------------
    // 10-REVIEW CR-02: `clear()` with no allow list.
    //
    // The role gate above is the same predicate `setBool` uses, so before
    // this the permission needed to wipe `key_mappings` — the gateway's own
    // 518 KiB routing configuration — was the permission needed to set a
    // theme, and under the shipped `PermissiveTokenValidator` that is every
    // accepted station. What makes it worse than a wide delete is the delay:
    // `CollectionPlanResolver` is a construction-time snapshot, so the
    // RUNNING gateway keeps serving from a plan whose source row is gone and
    // the failure lands at the next restart.
    //
    // No contract check called `clear` at all when the review was written.
    // One does now — `checkPreferenceClearCarriesItsAllowList`, on five legs
    // — and it takes the allow-listed form, which is the form that still
    // works.
    // -------------------------------------------------------------------
    test('an unrestricted clear is refused, for a session holding everything',
        () async {
      // The volume control is not a permission and must not be graded away:
      // this station holds every group the master system has, and the
      // unbounded shape of the call is still refused (10-REVIEW CR-02).
      final panel = seenBy(_engineer);

      final refusal = await _refused(() => panel.served.preferences.clear(),
          'a clear with no allow list from a station holding every group');

      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'the grading is not the problem — this station holds every '
              'group and every other mutator goes through. What is refused is '
              'the unbounded shape of the call');
      expect(refusal.message, contains('key_mappings'),
          reason: 'the refusal has to say what would have been destroyed. '
              '"Forbidden" alone sends an engineer looking for a permission '
              'to grant, and there is no permission that makes this call safe');
      expect(refusal.message, contains('allowList'),
          reason: 'and it has to name the parameter that turns it into a call '
              'this gateway will make. A refusal whose remedy the caller has '
              'to guess is one they will retry unchanged');
      expect(panel.store.writes, isEmpty,
          reason: 'pre-effect, like every other refusal in this class: the '
              'store recorded ${panel.store.writes}. A gate that fired after '
              'the DELETE would be a report that the plant\'s routing '
              'configuration is already gone');
    });

    test('the allow-listed clear still works, and clears only what it names',
        () async {
      // The anti-vacuity companion for the arm above: a decorator that refused
      // every clear would satisfy it and would also break every settings page
      // that tidies up after itself. The session holds the groups of every
      // key in the list ('svn.site.name' is unmatched, so administer), which
      // is what an allow-listed clear now takes.
      final panel = seenBy(_engineer);
      await panel.store.setString('svn.site.name', 'Sæból');
      await panel.store.setString('key_mappings', '{"CN01":"x"}');
      panel.store.writes.clear();

      await panel.served.preferences
          .clear(allowList: const {'svn.site.name'});

      expect(panel.store.writes, ['clear'],
          reason: 'the allow-listed form must reach the store');
      expect(await panel.store.containsKey('svn.site.name'), isFalse);
      expect(await panel.store.containsKey('key_mappings'), isTrue,
          reason: 'and it must clear only what it named. A layer that dropped '
              'the allow list on the way down would turn every one of these '
              'into the call refused above');
    });

    test('the reserved set is one key and it is the one the gateway is built '
        'from', () {
      expect(reservedPreferenceKeys, contains('key_mappings'),
          reason: 'read off the production constant rather than restated, so '
              'a second reserved key added later is covered by the message '
              'assertions above without editing them');
    });
  });

  group('a refusal still says the call definitively had no effect', () {
    // The safety wording is semantics, not prose: it is what stops a client
    // retrying a refusal as though it were transient (T-17-07g). It must
    // survive the gate's rewrite verbatim, on every refusing family.
    void expectSafetyWording(rpc.RpcException refusal, String family) {
      expect(refusal.message, contains('definitively had no effect'),
          reason: 'the $family refusal no longer states that nothing '
              'happened. A client that cannot tell "refused before any '
              'effect" from "failed somewhere" has to treat the answer as '
              'unknown, and an unknown on a setpoint is what makes an '
              'operator press the button again');
      expect(refusal.message, contains('Do not retry'),
          reason: 'and it must say not to retry: a permission does not '
              'appear on the next attempt, and a retry loop against a '
              'refusal is load with no exit condition');
    }

    test('a refused preference write carries the wording', () async {
      final display = seenByStation(_display);
      final refusal = await _refused(
          () => display.preferences.setString('key_mappings', '{}'),
          'the wording probe on the preferences family');
      expectSafetyWording(refusal, 'preferences');
    });

    test('a refused history-view delete carries the wording', () async {
      final panel = seenByStation(_panel);
      final refusal = await _refused(
          () => panel.historyViews.deleteHistoryView(1),
          'the wording probe on the history-view family');
      expectSafetyWording(refusal, 'history-view');
    });
  });

  group('a hidden key is a key that does not exist', () {
    test('a hidden key is indistinguishable from a key that does not exist',
        () async {
      final gateway = await _Gateway.start(
          policy: ScriptedPolicy.hiding(const {_hidden}),
          resolver: const _MapsTheRealTags());
      gateway.plant.setValue(_key, 1200);
      gateway.plant.setValue(_hidden, 900);
      final station = await gateway.station();

      // Anti-vacuity: a loop over an empty list asserts nothing, and the
      // count is named so that *deleting* a surface is as visible as adding
      // one. Seven since 10-02 added browse, eight since 10-03 added
      // timeseries.
      expect(_surfaces, hasLength(8),
          reason: 'the loop below covers ${_surfaces.length} surfaces. Each '
              'one is a way to ask about a tag and therefore a way to learn '
              'that it exists; a surface missing from this list is one '
              'nobody is comparing');

      for (final surface in _surfaces) {
        final forHidden = await surface.ask(gateway, station, _hidden);
        final forGhost = await surface.ask(gateway, station, _ghost);

        expect(forHidden, equals(forGhost),
            reason: '${surface.name} told a station apart. "$_hidden" is a tag '
                'the policy hides and "$_ghost" is a tag that never existed, '
                'and this surface answered them differently — so a station '
                'that may not know the first one exists can find out by '
                'asking, and by asking a thousand more it has the plant\'s '
                'address space. That is the whole of what 06-CONTEXT decision '
                '2 locks: hiding means "does not exist for you", not '
                '"exists, but no". Compared structurally with only the tag '
                'name normalized, so a later phase changing the nonexistent '
                'shape has to change both answers rather than this literal');
      }
    });

    test('the test policy really hides something', () async {
      // **The anti-vacuity companion.** Without it the case above passes
      // against a policy that hides nothing at all — both answers would be
      // the nonexistent answer, because neither tag would be served. This is
      // the same gateway and the same tag under the *shipped* policy, and it
      // must be visible and readable there.
      final gateway = await _Gateway.start();
      gateway.plant.setValue(_hidden, 900);
      final station = await gateway.station();

      expect(gateway.served.keys, contains(_hidden),
          reason: 'the tag the hiding case conceals is not servable in the '
              'first place, so that case is comparing two nonexistent keys '
              'and asserting nothing');

      final answer =
          _asMap(await station.request(Methods.read, params: {'key': _hidden}));
      expect(_asMap(answer['value'])['v'], 900,
          reason: 'and it must be *readable* under the shipped policy, not '
              'merely listed. A tag present in keys but unreadable would let '
              'the hiding case pass for the wrong reason too');
      expect(answer.containsKey('rejected'), isFalse,
          reason: 'a served tag carries no rejection map — the state the '
              'hidden one is being compared against is a genuinely healthy '
              'read');
    });

    test('the seeded history is really there under the shipped policy',
        () async {
      // The timeseries surface's own anti-vacuity companion, and it is
      // separate from the `read` one above because it can fail on its own:
      // the loop would pass against a gateway whose history was empty for
      // *every* tag, and an empty historian is a plausible fixture bug.
      final gateway = await _Gateway.start(resolver: const _MapsTheRealTags());
      final station = await gateway.station();

      final answered = await station.request(
          DataServiceMethods.timeseriesQuery,
          params: {
            'table': _hidden,
            'to': _ms(_tsBase.add(const Duration(hours: 1))),
            'from': _ms(_tsBase),
          },
          what: 'the hidden tag\'s history, unhidden');

      expect(answered, hasLength(5),
          reason: 'the series the hiding case conceals has nothing recorded '
              'in the first place, so that case is comparing two empty '
              'answers and asserting nothing');
      expect(((answered! as List).first as Map)['v'], 900,
          reason: 'and the samples must be the ones seeded, so that "empty" '
              'under the hiding policy is a filter having run rather than a '
              'window that never contained anything');
    });

    test('a hidden key\'s write is not answered forbidden', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      gateway.plant.setValue(_hidden, 900);
      final station = await gateway.station();

      final error = await station.refusal(Methods.write,
          params: {'cmd': newUlid(), 'key': _hidden, 'value': 1450},
          what: 'a write naming a tag this station may not see');

      expect(error.code, isNot(ServerErrorCodes.forbidden),
          reason: 'the gateway answered -32005 forbidden for a hidden tag, '
              'and forbidden means "this exists and you may not touch it". '
              'That is the leak the whole hiding architecture exists to '
              'close: it distinguishes a concealed tag from a misspelled one '
              'in a single round trip. The two refusals must stay different '
              'facts — a typo to fix versus a permission to obtain '
              '(06-RESEARCH §E.7 rows 2 and 3)');
      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'and it must be the nonexistent-key refusal exactly, not '
              'merely something other than forbidden');
      expect(error.message, contains('does not serve'),
          reason: 'the sentence is _unknownKeyMessage\'s, read from the one '
              'place all four surfaces read it from (06-04). A hidden tag and '
              'a nonexistent one cannot be byte-identical if this refusal '
              'writes its own');
    });
  });

  group('browse hides by omission, never by refusal', () {
    test('the tree really carries the hidden tag under the shipped policy',
        () async {
      // **The anti-vacuity companion, and it goes first.** Every case below
      // asserts something is absent; without this one they would all pass
      // against a tree that never held it, which is the state
      // `FakeBrowse`'s *default* fixture is in for these keys.
      final gateway = await _Gateway.start();
      final station = await gateway.station();

      expect(await _reachableNodeIds(station), contains(_hidden),
          reason: 'the address space does not list "$_hidden" even with '
              'nothing hidden, so every absence asserted below is the '
              'ordinary kind');

      final detail = BrowseNodeDetail.fromJson(_asMap(await station.request(
          DataServiceMethods.browseFetchDetail,
          params: {'node': _probeNodeFor(_hidden).toJson()},
          what: 'the hidden tag\'s detail under the shipped policy')));
      expect(detail.value?.value, 900,
          reason: 'and its detail carries a reading, so the hidden answer '
              'below is provably missing something rather than matching a '
              'source that had nothing to give');
    });

    test('a hidden leaf is dropped from the level it belongs to', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final ids = await _reachableNodeIds(station);

      expect(ids, isNot(contains(_hidden)),
          reason: 'a node naming a tag this station may not see is dropped '
              'from the list. Refusing the call instead would name what it '
              'refused, which is the enumeration the hiding rule exists to '
              'prevent (T-06-36)');
      expect(ids, contains(_key),
          reason: 'a filter that emptied the tree would satisfy the '
              'assertion above and blind every panel. The visible tag is the '
              'control');
    });

    test('a folder is never asked about', () async {
      // The rule the plan states and the one a reader will not guess:
      // `canSee` takes a **plant key**, and a folder is not one. A resolver
      // that happens to answer for a folder id — this file's identity one
      // does — must not turn a policy entry into a pruned branch.
      final gateway =
          await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hiddenParent}));
      final station = await gateway.station();

      final ids = await _reachableNodeIds(station);

      expect(ids, contains(_hiddenParent),
          reason: 'the folder "$_hiddenParent" was dropped because the policy '
              'names it. Browse asks about *variables*: a folder, an '
              'intermediate struct or a method is not a tag and has no '
              'reading to conceal, and pruning one takes every tag under it '
              'off the tree — including tags the station may see');
      expect(ids, contains(_hidden),
          reason: 'and the leaf under it is still there, which is the half '
              'that makes the assertion above about the folder rather than '
              'about the walk stopping early');
    });

    test('a hidden node\'s detail answers exactly as a nonexistent one does',
        () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final forHidden = _asMap(await station.request(
          DataServiceMethods.browseFetchDetail,
          params: {'node': _probeNodeFor(_hidden).toJson()},
          what: 'the hidden node\'s detail'));
      final forGhost = _asMap(await station.request(
          DataServiceMethods.browseFetchDetail,
          params: {'node': _probeNodeFor(_ghost).toJson()},
          what: 'a nonexistent node\'s detail'));

      // Compared to each other, never against a literal: a later phase that
      // changes what a source answers for a node it has never heard of has to
      // change both, which is the property 06-04 established between `read`
      // and `readFresh` and this surface inherits.
      expect(forHidden, equals(forGhost),
          reason: 'the detail pane can tell a concealed tag from a misspelt '
              'one. -32005 forbidden would be the loudest way to do it and '
              'this is the quietest: any difference at all is an existence '
              'oracle');
      expect(forHidden.containsKey('value'), isFalse,
          reason: 'the reading itself must not come through. A hidden node '
              'whose detail carried 900 would be the value leaking behind '
              'the concealment');
    });

    test('a path to a hidden node is null, not a truncated chain', () async {
      final gateway = await _Gateway.start(policy: ScriptedPolicy.hiding(const {_hidden}));
      final station = await gateway.station();

      final chain = await station.request(
          DataServiceMethods.browseResolvePath,
          params: {'targetId': _hidden},
          what: 'a path to the hidden tag');

      expect(chain, isNull,
          reason: 'a chain that stopped at the last visible node would claim '
              'an edge that is not there, and would say "something is under '
              'here you may not see" as clearly as a refusal. Null is what a '
              'target that does not exist gets, and that is what a hidden one '
              'has to get');

      final visible = await station.request(
          DataServiceMethods.browseResolvePath,
          params: {'targetId': _key},
          what: 'a path to the visible tag');
      expect(visible, isA<List<Object?>>(),
          reason: 'a resolver that answered null for everything would pass '
              'the assertion above and break the picker for every tag');
    });
  });

  group('a station that may not actuate is refused before the plant', () {
    test('a view station\'s write is refused before the device layer',
        () async {
      final gateway = await _Gateway.start(identity: _display);
      gateway.plant.setValue(_key, 1200);
      final station = await gateway.station();

      final cmd = newUlid();
      final error = await station.refusal(Methods.write,
          params: {'cmd': cmd, 'key': _key, 'value': 1450},
          what: 'a write from a station whose role is view');

      expect(error.code, ServerErrorCodes.forbidden,
          reason: 'a visible tag this station may not actuate is -32005, and '
              'the code has to be its own: the client behaves differently '
              'about it than about anything else on this path. Do not retry, '
              'the session is fine, keep reading — this action needs a '
              'permission the station does not have. INVALID_PARAMS would say '
              '"fix the request", and there is nothing wrong with the request');

      // **Nothing was sent.**
      expect(gateway.plant.upstreamWriteAttempts(cmd), 0,
          reason: 'the refusal must be raised above api.write. A device '
              'consulted before the refusal makes the whole gate a report '
              'about a frame that already reached a contactor');
      expect(gateway.plant.read(_key)?.value, 1200,
          reason: 'and the tag still reads what it read before. This is the '
              'one assertion an operator would recognise');

      // **And nothing was remembered.** The gate sits above the in-flight
      // pre-record, so a freshly minted ULID inside the window earns
      // `not_received` — the only re-send-safe answer this gateway gives, and
      // the honest one about an action that provably never happened.
      final status = _asMap(await station
          .request(Methods.writeStatus, params: {'cmds': [cmd]}));
      expect(
          WriteResult.fromJson(_asMap((status['results']! as List).single)),
          isA<WriteNotReceived>(),
          reason: 'writeStatus found something logged for a write that was '
              'refused before the plant was touched, so the gate was placed '
              'below the in-flight pre-record. The panel\'s reconnect '
              're-query would then answer "unknown" about an action that '
              'never happened, and an unknown on a setpoint is what makes an '
              'operator press the button again');
    });

    test('a view station\'s hold-to-run engage is refused before the hold is '
        'taken', () async {
      final gateway = await _Gateway.start(identity: _display);
      gateway.plant.setValue(_key, 0);
      final station = await gateway.station();

      final error = await station.refusal(Methods.write,
          params: {'cmd': newUlid(), 'key': _key, 'value': 1, 'hold': true},
          what: 'an engage from a station whose role is view');

      expect(error.code, ServerErrorCodes.forbidden,
          reason: 'one canWrite gates both write and holdToRun (ruling OQ5), '
              'because the engage seam is reachable only through the write '
              'path. A station that may not set a setpoint certainly may not '
              'jog the machine by hand');
      expect(gateway.plant.mintedCmds, isEmpty,
          reason: 'the source was never asked for a handle: the gate is above '
              'api.holdToRun, which is where "no device was consulted" stops '
              'being a claim and becomes a fact');
      expect(gateway.plant.read(_key)?.value, 0,
          reason: 'nothing was put on the deadman tag');
    });

    test('an operate station\'s write is unchanged in every respect',
        () async {
      final gateway = await _Gateway.start();
      gateway.plant.setValue(_key, 1200);
      final station = await gateway.station();

      final cmd = newUlid();
      final answer = _asMap(await station.request(Methods.write,
          params: {'cmd': cmd, 'key': _key, 'value': 1450}));

      expect(WriteResult.fromJson(answer), isA<WriteApplied>(),
          reason: 'the gate must cost a view station and nothing else. A '
              'panel that stopped writing is a jog button that stopped '
              'working, and PermissiveTokenValidator grants operate precisely '
              'so every fixture in this workspace keeps writing through the '
              'new gate');
      expect(gateway.plant.upstreamWriteAttempts(cmd), 1,
          reason: 'one press, one movement of the machine — the gate adds no '
              'second attempt and swallows no first one');
      expect(gateway.plant.read(_key)?.value, 1450);
    });
  });
}

/// One answer with the tag name taken out of it, so two answers about
/// different tags can be compared for everything else.
///
/// The key is the one field that legitimately differs between "the tag you
/// hid" and "the tag that never was", and normalizing it is what lets the
/// rest be compared structurally instead of field by hand-written field.
Map<String, Object?> _withoutKeyName(Map<String, Object?> answer, String key) {
  String scrub(String text) => text.replaceAll(key, '<tag>');

  Object? walk(Object? node) {
    if (node is String) return scrub(node);
    if (node is List) return node.map(walk).toList();
    if (node is Map) {
      return {
        for (final entry in node.entries) scrub('${entry.key}'): walk(entry.value),
      };
    }
    return node;
  }

  return (walk(answer)! as Map).cast<String, Object?>();
}
