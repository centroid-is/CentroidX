/// A `StateManApi` whose values only ever arrive over a channel.
///
/// This is the implementation the contract suite is pointed at, and its
/// defining property is negative: it holds no source. Every value it can return
/// got into its [ValueStore] by way of an inbound [Methods.update]
/// notification, and there is no other path — which is exactly the claim
/// `test/channel/channel_bite_test.dart` exists to make honest, by cutting the
/// channel and showing the same named checks fail rather than pass from a
/// local object nobody noticed was there.
///
/// It is a rehearsal for Phase 4's `RemoteStateMan`, deliberately: same store,
/// same synchronous-answers-from-cache shape, same `subscribe` adapter over the
/// same node. What it is missing is everything a socket forces — reconnect,
/// resync, sequence gaps, per-request deadlines — and the missing pieces are
/// listed rather than stubbed, so nothing here can be mistaken for a client
/// that has already solved them.
///
/// ## Where each member gets its answer
///
/// **From the local store, synchronously:** [listen], [read], [keys],
/// [subscribe]. That is the interface's own design (`state_man_api.dart:90-96`:
/// `read` is "synchronous and never a round trip"), and it is what makes the
/// bite-proof meaningful — a store fed by nothing answers nothing.
///
/// **Over the channel, as a request:** [readFresh], [readMany], [write]. Each
/// is one message out and one back, which is what makes the served source's
/// round-trip counter a measurement of *this* object's wire behaviour.
///
/// **Over the channel, as a notification:** every `StateManHarness` lever. They
/// are `void` on the interface, so there is nothing to await; what makes a
/// lever-then-request sequence correct is the channel's ordering, not an
/// acknowledgement.
///
/// **Not over the channel at all:** [staleAfter], [roundTrips] and
/// [statusNotifications], which are read straight off the served instance.
/// `lib/src/harness.dart:16-25` explains why they exist and why they are not on
/// `StateManApi`: they are promises about a *count*, and putting them on the
/// wire surface would make them things a connected client may invoke, which is
/// an access-control decision rather than a testing convenience. There is
/// therefore nothing for a channel to carry, and mirroring them would be
/// inventing wire traffic to move a number that is already correct.
///
/// The last of those is worth stating as a property rather than an excuse.
/// Because the *served* source increments `roundTrips` once per answer it
/// gives, a client that wrongly issued one request per key instead of one
/// [readMany] still shows up as N. The counter lives on the server and measures
/// the client, which is the only arrangement that survives Phase 4, where the
/// counter genuinely will be on another host.
///
/// **The four data-service sub-APIs, over the channel too.** Browse,
/// timeseries, history views and preferences are thirty-four requests and one
/// outbound notification, forwarded by `channel_sub_apis.dart`. They were
/// stubs that threw until plan 02-08, deliberately — a getter returning an
/// empty implementation would have let `runDataServicesContract` run against a
/// channel carrying nothing and report a colour — and what replaced them is
/// forwarding, not a second store: the only thing on this side that holds
/// data-service state is the preference change stream's fan-out, and every key
/// it reports arrived over the channel.
///
/// ## What is not implemented, and why it is not stubbed
///
/// Reconnect, resync, sequence gaps and per-request deadlines. All four are
/// what a socket forces and a `StreamChannelController` does not, and each is
/// listed here rather than approximated so that nothing in this file can be
/// mistaken for a client that has already solved them.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../access_contract.dart';
import '../data_services_contract.dart';
import '../harness.dart';
import '../write_contract.dart';
import 'channel_sub_apis.dart';
import 'rpc_names.dart';

/// A state source on the far side of a message channel.
final class ChannelStateMan
    implements
        StateManApi,
        StateManWriteHarness,
        StateManDataHarness,
        StateManAccessHarness {
  /// Wraps the client end of a channel whose other end is a served source.
  ///
  /// [observables] is the served instance's control surface, read directly for
  /// the three counters the wire deliberately does not carry. [closeServed]
  /// releases whatever is on the other end; [dispose] calls it, so a driver
  /// that registers `api.dispose` with `addTearDown` — which every sub-suite
  /// does — tears down both halves without knowing there are two.
  ChannelStateMan({
    required StreamChannel<String> channel,
    required StateManHarness observables,
    required Future<void> Function() closeServed,
  })  : _observables = observables,
        _closeServed = closeServed,
        _peer = rpc.Peer(channel) {
    _peer.registerMethod(HarnessMethods.update, _applyUpdate);
    _peer.registerMethod(HarnessMethods.preferencesChanged, _preferenceChanged);
    // Swallowed deliberately — see served_state_man.dart for the argument: a
    // channel failure must fail the check that named the property, not arrive
    // as an unhandled zone error attributed to an unrelated test.
    unawaited(_peer.listen().catchError((Object _) => null));
  }

  final StateManHarness _observables;
  final Future<void> Function() _closeServed;
  final rpc.Peer _peer;

  /// The client-side cache — the same [ValueStore] the real client will use, so
  /// the k-of-n rebuild property is satisfied here by production code rather
  /// than by harness scaffolding.
  final _store = ValueStore();

  /// Closers for the streams [subscribe] handed out that are still open.
  ///
  /// The shape is `FakeStateMan`'s (`fake_state_man.dart:119-130`), including
  /// the self-deregistering closer: a registry that only grows is a leak, and
  /// this object is built once per contract case.
  final _closeHandedOutStreams = <Future<void> Function()>{};

  var _disposed = false;

  // ------------------------------------------------- answers from the store

  @override
  ValueListenable<DynamicValue> listen(String key) => _store.node(key);

  @override
  DynamicValue? read(String key) => _store.peek(key);

  /// The keys an update has actually arrived for.
  ///
  /// Filtered on a value having arrived, exactly as the reference
  /// implementation filters (`fake_state_man.dart:267-277`): `listen` creates a
  /// node for any key asked of it, including one mistyped into a page config,
  /// and offering that back to the picker would launder a typo into a valid
  /// binding.
  @override
  List<String> get keys => [
        for (final key in _store.keys)
          if (_store.peek(key) != null) key,
      ];

  /// A broadcast view of the same node, for stream-consuming code.
  ///
  /// A view and never a second source of truth. Returned synchronously so
  /// taking the stream and listening to it happen in one turn, which is what
  /// stops a widget missing the first values of its own subscription.
  @override
  Stream<DynamicValue> subscribe(String key) {
    final node = _store.node(key);
    late final StreamController<DynamicValue> controller;
    void push() => controller.add(node.value);
    late final Future<void> Function() close;
    close = () async {
      _closeHandedOutStreams.remove(close);
      await controller.close();
    };
    controller = StreamController<DynamicValue>.broadcast(
      onListen: () {
        node.addListener(push);
        _closeHandedOutStreams.add(close);
      },
      onCancel: () {
        node.removeListener(push);
        _closeHandedOutStreams.remove(close);
      },
    );
    _closeHandedOutStreams.add(close);
    return controller.stream;
  }

  // --------------------------------------------------- answers over the wire

  @override
  Future<DynamicValue> readFresh(String key) async {
    final raw = await _peer.sendRequest(HarnessMethods.readFresh, {'key': key});
    return DynamicValue.fromJson(_asJson(raw));
  }

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    // One request for however many keys, which is the promise the interface
    // makes (`state_man_api.dart:104-109`) and the thing the served source's
    // round-trip counter is watching for.
    final raw = await _peer.sendRequest(HarnessMethods.readMany, {'keys': keys});
    return {
      for (final entry in _asJson(raw).entries)
        entry.key: DynamicValue.fromJson(_asJson(entry.value)),
    };
  }

  /// One request out, one outcome back — and no retry, no queue, no deadline.
  ///
  /// The absence of all three is the property, not an omission
  /// (`CLAUDE.md`: no queue / no retry = the write-safety property). A retry
  /// here would be invisible from the API surface — same call, same result
  /// type, slightly later — and on a plant it is a second actuation of
  /// machinery an operator commanded once. The counter that catches one lives
  /// on the served side, where the attempts happen, which is what makes
  /// [upstreamWriteAttempts] able to judge this method at all. The missing
  /// deadline is the other half: a response that never comes leaves this
  /// future pending forever (RESEARCH Finding 15). Plan 02-10 proves that hang
  /// exists; the per-request deadline that fixes it belongs to Phase 4's
  /// `RemoteStateMan`, and inventing one here would hide the thing 02-10 is
  /// being written to show.
  ///
  /// The non-finite handling is the one place this method does more than
  /// forward, and it is the client's job for a reason nothing on the far side
  /// can help with: `jsonEncode` throws on NaN and ±Infinity rather than
  /// emitting null, so the number cannot cross this channel at all and this
  /// side is the only side that ever sees it. **Both halves are refused**, with
  /// an `ArgumentError`, before anything is sent:
  ///
  ///  * a non-finite **value** would go on the wire as `null`, which is a write
  ///    of null to a live tag: the device is actuated with something nobody
  ///    chose and the operator is told the write applied. This method used to
  ///    do exactly that and stamp [Quality.badNonFinite] on the local key
  ///    afterwards — a badge visible on the one panel that issued the write,
  ///    while the plant kept the null and every other screen read it as an
  ///    ordinary value.
  ///  * a non-finite **expect** would go on the wire as `null`, which is this
  ///    path's encoding of "no compare-and-set guard": the operator's "only if
  ///    it still reads 1200" becomes "whatever it reads".
  ///
  /// Nothing upstream of a write box can legitimately produce a NaN, so either
  /// one is programmer error — a divide-by-zero in a rate calculation is the
  /// ordinary source — and an error is the one thing the write path is allowed
  /// to do about it. `WriteParams` (`messages.dart:569-599`),
  /// `ServedStateMan.write`, `value_handlers.write` and `RemoteStateMan._write`
  /// all make the same refusal.
  ///
  /// Phase 1 handed Phase 4 an asymmetric split here — sanitize the value,
  /// refuse the expect — recorded in STATE.md before either end of it existed.
  /// Jón ruled it out on 2026-09-06 ("refuse everywhere") once it was clear the
  /// two layers held opposite policies on one safety question and the dangerous
  /// one won in production.
  @override
  Future<WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) async {
    if (cmd != null) {
      // Refused rather than ignored. `HarnessMethods.write` carries no cmd
      // field, so the served side would mint its own and this call would
      // return an outcome under an id the caller has never seen — the exact
      // unreconcilable write `state_man_api.dart` describes. A relay that
      // needs this leg must widen the harness protocol first; until then,
      // failing loudly beats losing the correlation quietly.
      throw UnsupportedError(
          'ChannelStateMan cannot relay a caller-minted cmd ("$cmd"): the '
          'harness write protocol has no field to carry it, so the outcome '
          'would come back under an id nothing could reconcile against. This '
          'implementation originates writes; it does not forward them');
    }
    // Both walks run before either refusal so that a non-finite buried in a
    // nested structure is caught too, not just a bare double.
    final sanitizedValue = sanitize(value);
    final sanitizedExpect = sanitize(expect);
    if (sanitizedValue.hadNonFinite) {
      throw ArgumentError.value(
          value,
          'value',
          'a write cannot carry a non-finite number: it encodes to null, and '
              'a write of null actuates the device with a value nobody chose '
              'while the operator is told the write applied');
    }
    if (sanitizedExpect.hadNonFinite) {
      throw ArgumentError.value(
          expect,
          'expect',
          'a write cannot carry a non-finite compare-and-set guard: nulling '
              'it is this path\'s encoding of "no guard at all", so a guarded '
              'write would silently become an unconditional one');
    }

    final raw = await _peer.sendRequest(HarnessMethods.write, {
      'key': key,
      'value': sanitizedValue.value,
      if (expect != null) 'expect': sanitizedExpect.value,
    });
    return WriteResult.fromJson(_asJson(raw));
  }

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) async {
    final raw = _asJson(
        await _peer.sendRequest(HarnessMethods.writeStatus, {'cmds': cmds}));
    final results = raw['results'];
    return [
      if (results is List)
        for (final entry in results)
          WriteResult.fromJson(_asJson(entry))
      else
        // An answer with no results list is an answer about nothing. Every
        // cmd asked about therefore stays unknown — the one thing that must
        // not happen is a truncated frame reading as "never received", which
        // is the only verdict that invites a second actuation.
        for (final cmd in cmds)
          WriteUnknown(
              cmd,
              const WriteReason('malformed_result:writeStatus',
                  message: 'the source answered without a results list, so '
                      'nothing about these commands can be ruled out')),
    ];
  }

  /// Engages a hold with an ordinary write of its own.
  ///
  /// No caller-minted cmd anywhere in this path, so the [UnsupportedError]
  /// above is never tripped: this implementation *originates* the engage and
  /// the release, and the harness write protocol has no field to carry
  /// somebody else's id.
  ///
  /// The feed goes out as a notification through the same one-way lane the
  /// levers use, for the same two reasons: a tick has no answer to wait for,
  /// and a `sendNotification` on a closed peer throws synchronously, so the
  /// gate in [_lever] is what keeps a disposed source from dying inside
  /// json_rpc_2 instead of quietly stopping.
  @override
  Future<HoldHandle> holdToRun(String key) async {
    final engagement = await write(key, 1);
    final hold = HoldHandle(
      key: key,
      engagement: engagement,
      onTick: (counter) =>
          _lever(HarnessMethods.holdTick, {'k': key, 'n': counter}),
      onRelease: (counter) => write(key, counter),
    );
    if (hold.isHeld) {
      _liveHolds.add(hold);
      unawaited(hold.onReleased.then((_) => _liveHolds.remove(hold)));
    }
    return hold;
  }

  /// Every hold this source is currently feeding.
  ///
  /// Kept for one reason and it is [dispose]'s: a source that goes away with a
  /// counter still advancing has left a machine running with the window that
  /// was watching it already closed. The same registry, for the same reason,
  /// as `fake_state_man.dart:764-765` and `remote_state_man.dart`'s.
  final _liveHolds = <HoldHandle>{};

  /// Ends every live hold, without waiting for the release writes.
  ///
  /// Not awaited, matching the reference implementation
  /// (`fake_state_man.dart:800-813`): the counter stops the instant the handle
  /// is released, which is the whole safety property, and a teardown that
  /// waited for the zero to be acknowledged would hang on exactly the dead
  /// link that caused it.
  void _releaseHolds(HoldEnded reason) {
    for (final hold in List<HoldHandle>.of(_liveHolds)) {
      unawaited(
          hold.release(reason: reason).then((_) {}, onError: (Object _) {}));
    }
    _liveHolds.clear();
  }

  // `_markNonFinite` lived here: it stamped [Quality.badNonFinite] on the local
  // key after a non-finite write's outcome came back, so the operator saw a
  // fault rather than the blank box the nulled value left. [write] now refuses
  // that value outright and nothing is sent, so there is no outcome to mark
  // after and no divergence between the two stores to explain. A non-finite
  // arriving *from* the wire is a different path and still marks: it is
  // sanitized by `DynamicValue`'s own constructor on decode
  // (`dynamic_value.dart:647`), which is where a `1e999` — the one non-finite
  // this side cannot refuse, because it enters as a legal JSON literal — picks
  // up its quality.
  //
  // Deleted rather than kept for a future caller: a private method nothing
  // calls is a decoy that reads as live policy.

  // ------------------------------------------------------- levers, one-way

  @override
  void setValue(String key, Object? value,
          {Quality quality = Quality.good, DateTime? sourceTime}) =>
      _lever(HarnessMethods.setValue, {
        'key': key,
        'value': value,
        'q': quality.code,
        if (sourceTime != null) 't': sourceTime.millisecondsSinceEpoch,
      });

  @override
  void setValues(Map<String, Object?> values) =>
      _lever(HarnessMethods.setValues, {'values': values});

  @override
  void setQuality(String key, Quality quality) => _lever(
      HarnessMethods.setQuality, {'key': key, 'q': quality.code});

  @override
  void dropKey(String key) => _lever(HarnessMethods.dropKey, {'key': key});

  @override
  void disconnectUpstream() =>
      _lever(HarnessMethods.disconnectUpstream, const {});

  @override
  void reconnectUpstream() =>
      _lever(HarnessMethods.reconnectUpstream, const {});

  @override
  void failNextWrite(WriteReason reason, {bool unknown = false}) => _lever(
      HarnessMethods.failNextWrite,
      {'reason': reason.toJson(), 'unknown': unknown});

  @override
  void clampNextWrite(Object? readback) =>
      _lever(HarnessMethods.clampNextWrite, {'readback': readback});

  @override
  void stallWrites() => _lever(HarnessMethods.stallWrites, const {});

  @override
  void releaseWrites({bool applied = true}) =>
      _lever(HarnessMethods.releaseWrites, {'applied': applied});

  @override
  void setReadOnly(String key, bool readOnly) =>
      _lever(HarnessMethods.setReadOnly, {'key': key, 'readOnly': readOnly});

  /// Posts one lever, unless this source is gone.
  ///
  /// The guard is not defensive tidiness. `checkDisposeStopsNotifications`
  /// disposes the source and *then* pulls a lever, which is the whole point of
  /// the case; over a channel that lever would otherwise be a
  /// `sendNotification` on a closed peer, and the case would die of a
  /// `StateError` from inside `json_rpc_2` instead of asserting the property.
  /// A disposed source cannot make a value arrive, so dropping the lever is
  /// also the honest behaviour.
  void _lever(String method, Map<String, Object?> params) {
    if (_disposed || _peer.isClosed) return;
    _peer.sendNotification(method, params);
  }

  // ------------------------------------------- observables, off the source

  @override
  Duration get staleAfter => _observables.staleAfter;

  @override
  int get roundTrips => _observables.roundTrips;

  @override
  int get statusNotifications => _observables.statusNotifications;

  /// How many upstream attempts [cmd] cost — read off the served source.
  ///
  /// This is the observable that makes the no-auto-retry property judgeable
  /// across a channel at all, and it works *because* the counter lives where
  /// the attempts happen. A client-side copy would count what this object
  /// sent, which is exactly the place a retry would not be: the retry the
  /// contract is hunting for is the one a transport adds beneath the call, and
  /// a source that quietly re-sent every unanswered write would show 1 on
  /// every counter it owned itself. Reading the server's number is also the
  /// only arrangement that survives Phase 4, where the counter genuinely is on
  /// another host.
  @override
  int upstreamWriteAttempts(String cmd) =>
      _writeObservables.upstreamWriteAttempts(cmd);

  @override
  List<String> get mintedCmds => _writeObservables.mintedCmds;

  /// The served source's write control surface, or a failure naming what is
  /// missing.
  ///
  /// [_observables] is typed as the read-side harness so that a source with no
  /// write levers can still be served and judged by the four sub-suites that
  /// do not need any. Asking for a write observable from one is the point at
  /// which that stops being true, and it fails here rather than returning a
  /// zero — a zero would read as "no retry happened", which is the answer the
  /// no-auto-retry case is looking for and the one thing it must not be
  /// handed for free.
  StateManWriteHarness get _writeObservables {
    final observables = _observables;
    if (observables is StateManWriteHarness) return observables;
    throw UnsupportedError(
        'the served source (${observables.runtimeType}) exposes no '
        'StateManWriteHarness, so the upstream attempt count and the minted '
        'ids this harness would report are not measurements of anything. '
        'Serve a source that implements it, or declare supportsWrites: false '
        'where the contract is registered so the write group is skipped on '
        'the record instead of passing vacuously.');
  }

  // ------------------------------------------------------------- the inbound

  /// The only way a value gets into this object.
  ///
  /// Applied with no sequence number: numbering, gap detection and the resync
  /// that follows one are Phase 3's session and Phase 4's client, and a harness
  /// that invented a sequence here would be asserting a property nothing has
  /// implemented yet. [ValueStore.applyBatch] treats an unnumbered batch as
  /// out-of-band and leaves the bookkeeping alone, which is the correct meaning
  /// of "this harness does not speak sequences".
  void _applyUpdate(rpc.Parameters params) {
    if (_disposed) return;
    final raw = params['changes'].asMap;
    final changes = <String, DynamicValue>{
      for (final entry in raw.entries)
        '${entry.key}': DynamicValue.fromJson(_asJson(entry.value)),
    };
    if (changes.isEmpty) return;
    _store.applyBatch(changes);
  }

  // ---------------------------------------------------------------- teardown

  /// Drops every listener, closes every handed-out stream, closes the channel,
  /// and releases the served source. Idempotent.
  ///
  /// Both halves, because the driver only knows about one: every sub-suite
  /// registers `api.dispose` with `addTearDown` and nothing else, so a served
  /// source left running here is a freshness watchdog ticking for the rest of
  /// the session against a store nobody is watching.
  ///
  /// Holds are released **before** the flag, for the same two reasons
  /// `fake_state_man.dart:307-313` gives: the release is a write and [write]
  /// refuses to run on a disposed source, and a source that tore itself down
  /// leaving a counter advancing is a machine nobody is holding.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _releaseHolds(HoldEnded.disposed);
    _disposed = true;
    _store.dispose();
    for (final close in List.of(_closeHandedOutStreams)) {
      await close();
    }
    _closeHandedOutStreams.clear();
    await preferences.dispose();
    await _peer.close();
    await _closeServed();
  }

  // -------------------------------------------------------- the sub-APIs

  /// Browse, timeseries, history views and preferences — all four over the
  /// same peer, none of them holding a source of their own.
  ///
  /// Built once and kept, rather than minted per access, for one reason that
  /// only applies to the last of them: [preferences] owns the broadcast
  /// controller every local listener reads from, and a fresh instance per
  /// getter call would hand the contract's *second* listener a stream nothing
  /// ever pushes to. The other three are stateless and are kept alongside it
  /// for symmetry.
  @override
  late final BrowseApi browse = ChannelBrowseApi(_request);

  @override
  late final TimeseriesApi timeseries = ChannelTimeseriesApi(_request);

  @override
  late final HistoryViewApi historyViews = ChannelHistoryViewApi(_request);

  @override
  late final ChannelPreferencesApi preferences = ChannelPreferencesApi(_request);

  // -------------------------------------------------- the access families
  //
  // Four forwarders now, added by plan 17-05. Each sends one request and awaits
  // one answer over the same peer the data services use; a refusal comes back as
  // `HarnessErrorCodes.accessForbidden` and `channel_sub_apis.dart` re-raises it
  // as the same [AccessDenied] the in-memory leg throws, so a refusal is one
  // exception type on both legs (D-09). Built once and kept, like the data
  // services, though these four hold no state of their own.

  @override
  late final AccessTemplateApi accessTemplates =
      ChannelAccessTemplateApi(_request);

  @override
  late final AccessAdminApi accessAdmin = ChannelAccessAdminApi(_request);

  @override
  late final AuditApi audit = ChannelAuditApi(_request);

  @override
  late final BackendConfigApi backendConfig =
      ChannelBackendConfigApi(_request);

  // ------------------------------------------------ the access control lever
  //
  // The session lever, the recording readout and the stored-password probe are
  // read straight off the served instance through [_accessObservables], not
  // over the channel — the same arrangement `roundTrips`, `upstreamWriteAttempts`
  // and `mintedCmds` use, and for the same reason `harness.dart` gives: these
  // are test scaffolding, not wire traffic, and putting them on the wire would
  // make them things a connected client may invoke. The session must take
  // effect on the served source's own access store, which [_observables] IS —
  // so swapping it there directly is both correct and race-free, where a lever
  // notification would depend on ordering the request that follows it.

  @override
  void actAs(AccessSession session) => _accessObservables.actAs(session);

  @override
  List<String> get accessStoreWrites => _accessObservables.accessStoreWrites;

  @override
  String? storedPasswordFor(String subject) =>
      _accessObservables.storedPasswordFor(subject);

  /// The served source's access control surface, or a failure naming what is
  /// missing — the same bargain [_writeObservables] strikes for the write side.
  StateManAccessHarness get _accessObservables {
    final observables = _observables;
    if (observables is StateManAccessHarness) {
      return observables as StateManAccessHarness;
    }
    throw UnsupportedError(
        'the served source (${observables.runtimeType}) exposes no '
        'StateManAccessHarness, so the session lever and the store-touch '
        'recording this harness would report are not measurements of anything. '
        'Serve a source that implements it, or declare supportsAccessControl: '
        'false where the contract is registered so the access group is skipped '
        'on the record instead of passing vacuously.');
  }

  /// Records samples on the far side — the one data-service lever.
  ///
  /// `void`, so it travels in the ordered notification lane like every other
  /// lever: what makes seed-then-query correct is the channel's ordering, not
  /// an acknowledgement. That is also why `runDataServicesContract` needs no
  /// `seedTimeseries` hook here — the default path reaches this method, which
  /// puts the samples on the wire, which is the thing worth testing.
  @override
  void seedTimeseries(String tableName, List<TimeseriesData> points) =>
      _lever(HarnessMethods.seedTimeseries, {
        'table': tableName,
        'points': [for (final point in points) point.toJson()],
      });

  /// One request out and one answer back, unless this source is gone.
  ///
  /// The disposed guard is the same one [_lever] makes and it matters more
  /// here: a `sendRequest` on a closed peer throws a `StateError` out of
  /// json_rpc_2, and a case that disposed its source and then asked it a
  /// question would report that instead of the property it names. A
  /// [StateError] of this file's own, saying which call arrived after the
  /// close, is the honest answer — there is no value to invent and no round
  /// trip left to make.
  Future<Object?> _request(String method, Map<String, Object?> params) {
    if (_disposed || _peer.isClosed) {
      throw StateError(
          'ChannelStateMan was asked for $method after it was disposed; the '
          'channel is closed, so there is no round trip left to make and no '
          'answer that would not be invented');
    }
    return _peer.sendRequest(method, params);
  }

  /// One inbound preference change, fanned out to every local listener.
  void _preferenceChanged(rpc.Parameters params) {
    if (_disposed) return;
    preferences.announce(params['key'].asString);
  }

  /// Narrows a decoded JSON value to the map shape the protocol decoders take.
  ///
  /// `json_rpc_2` hands back whatever `jsonDecode` produced, which is a
  /// `Map<String, dynamic>` for an object and anything at all for a peer that
  /// is lying. A `FormatException` here is the honest outcome — the decoders
  /// this feeds are documented to be tolerant of *fields*, not of being handed
  /// a list where an object belongs — and it is what plan 02-10's corruption
  /// catalogue will be aimed at.
  static Map<String, Object?> _asJson(Object? raw) => raw is Map
      ? {for (final entry in raw.entries) '${entry.key}': entry.value}
      : throw FormatException('expected a JSON object, got ${raw.runtimeType}');
}
