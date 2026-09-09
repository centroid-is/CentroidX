/// Serving a `StateManApi` — and its test-only levers — over a message channel.
///
/// This is the source side of the harness: a `json_rpc_2.Peer` that answers the
/// value path from a real implementation and pushes that implementation's
/// changes outward as [Methods.update] notifications. Phase 3's session layer
/// will do the same job for real, over a socket, with authentication and
/// per-key subscription accounting in front of it. This is not that. It is the
/// channel the wire will run on, built now so that the contract suite can be
/// pointed across a message boundary a phase before there is a server to point
/// it at — and so that the boundary is proven to be load-bearing before
/// anything depends on it.
///
/// ## Three decisions worth the words
///
/// **The payload is `DynamicValue.toJson()`, not the slim `WireValue` form.**
/// The slim encoding drops quality, source time and metadata — it is the hot
/// path, and Phase 3's session will use it, because on a 1500-key page the
/// metadata rides once in the subscribe result rather than on every push. Here
/// the lossless form is required by what the suite measures: the store
/// contract's unchanged-value case is decided by `==` on `DynamicValue`, and
/// `dynamic_value.dart:687` documents `fromJson(toJson())` as equal to the
/// original. A slim payload would make every re-delivery of an unchanged value
/// compare unequal on the client, and the k-of-n rebuild property would fail
/// against a source that was behaving perfectly.
///
/// **Levers arrive as notifications, not as requests.** Every member of
/// `StateManHarness` that this forwards returns `void`, so there is nothing for
/// a client to await and a request-shaped lever would invent an
/// acknowledgement the interface does not have. What makes a lever-then-request
/// sequence correct is instead the ordering guarantee of a single channel:
/// messages are delivered in the order they were sent, so a `setValue` posted
/// before a `readFresh` is applied before that read is answered. That is a
/// property of the transport, and it is the same property a WebSocket has, so
/// the sequence transfers to Phase 4 unchanged.
///
/// **Change detection is a listener per key, plus a re-scan.** A listener
/// attached to `api.listen(key)` catches every change to a key that already
/// exists — including the ones no lever caused, which is the point: the
/// freshness watchdog degrading a value to `badStale` is a change the client
/// must see, and nothing on the inbound path would ever tell it. A key that a
/// lever *creates* has no listener at the moment its first value lands, so
/// every inbound lever is followed by a re-scan of `api.keys` that adopts the
/// newcomers and marks them changed. The two mechanisms together are what makes
/// "every value the client holds arrived over this channel" true rather than
/// approximately true.
///
/// Coalescing is by microtask: changes accumulate in a set and one notification
/// carries all of them. A lever applies its whole batch synchronously, so the
/// batch is still one batch when the flush runs — which is what the
/// notification-count promise (`lib/src/harness.dart:56-61`) is made about.
library;

import 'dart:async';

import 'package:json_rpc_2/error_code.dart' as error_code;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../data_services_contract.dart';
import '../harness.dart';
import '../hold_harness.dart';
import '../write_contract.dart';
import 'rpc_names.dart';

/// Serves [api] over [channel] and starts listening immediately.
///
/// [api] must implement `StateManHarness` — a source with no control surface
/// cannot be driven by a contract case, and [harnessOf] says so by name rather
/// than through a cast error.
ServedStateMan serveStateMan(StateManApi api, StreamChannel<String> channel) =>
    ServedStateMan._(api, harnessOf(api), rpc.Peer(channel)).._start();

/// One served source: the peer, the registrations, and the outbound push.
final class ServedStateMan {
  ServedStateMan._(this.api, this.plant, this.peer);

  /// The implementation being served. Real, not a mock — the whole harness is
  /// worthless if the thing on the far end is a stand-in.
  final StateManApi api;

  /// Its test-only control surface.
  final StateManHarness plant;

  /// Its *write*-side control surface, resolved on first use.
  ///
  /// Lazily rather than in the constructor, because a source with no write
  /// levers is a legitimate thing to serve — an M2400 weigher adapter takes no
  /// writes at all — and the read, subscribe, store and freshness sub-suites
  /// judge it perfectly well without one. Resolving eagerly would refuse to
  /// serve it. Resolving here means the failure arrives when a case first
  /// pulls a write lever, naming what to add, which is the same bargain
  /// [writeHarnessOf] already strikes.
  late final StateManWriteHarness writePlant = writeHarnessOf(api);

  /// The hold seam, resolved on first use for the same bargain: a source that
  /// serves no deadman is a legitimate thing to serve, and the failure should
  /// arrive when a case first feeds one, naming what to add.
  late final StateManHoldHarness holdPlant = holdHarnessOf(api);

  /// The JSON-RPC endpoint. Exposed so a test can assert on its state; nothing
  /// in the ordinary path needs it.
  final rpc.Peer peer;

  /// One listener per key being watched, kept so [close] can detach them.
  ///
  /// A listener left attached to a store the peer no longer serves keeps
  /// pushing into a closed channel, which is a leak that surfaces as an
  /// inexplicable failure in whichever case runs next.
  final _watchers = <String, void Function()>{};

  /// Keys changed since the last flush.
  final _pending = <String>{};

  var _flushScheduled = false;
  var _closed = false;

  /// Whether this peer has stopped serving, for whatever reason.
  bool get isClosed => _closed || peer.isClosed;

  /// Completes when the peer is done — because [close] was called, or because
  /// the channel went away underneath it.
  Future<void> get closed => _done.future;
  final _done = Completer<void>();

  /// Every name [_on] has registered, in registration order.
  ///
  /// Kept so the method table can be asserted against the handlers in *both*
  /// directions (`test/channel/channel_sub_apis_test.dart`): a declared name
  /// with no handler answers METHOD_NOT_FOUND from a table claiming to carry
  /// it, and a handler with no declared name is surface nobody counted, which
  /// is the half of T-02-22 a one-directional check would miss.
  Set<String> get registeredMethods => Set.unmodifiable(_registered);
  final _registered = <String>{};

  /// Registers [handler] under [method] and records that it happened.
  void _on(String method, Function handler) {
    _registered.add(method);
    peer.registerMethod(method, handler);
  }

  void _start() {
    _on(HarnessMethods.readFresh, _readFresh);
    _on(HarnessMethods.readMany, _readMany);
    _on(HarnessMethods.keys, (rpc.Parameters _) => api.keys);
    _on(HarnessMethods.write, _write);
    _on(HarnessMethods.writeStatus, _writeStatus);
    _on(HarnessMethods.holdTick, _holdTick);
    _on(HarnessMethods.setValue, _setValue);
    _on(HarnessMethods.setValues, _setValues);
    _on(HarnessMethods.setQuality, _setQuality);
    _on(HarnessMethods.dropKey, _dropKey);
    _on(HarnessMethods.disconnectUpstream, _disconnectUpstream);
    _on(HarnessMethods.reconnectUpstream, _reconnectUpstream);
    _on(HarnessMethods.failNextWrite, _failNextWrite);
    _on(HarnessMethods.clampNextWrite, _clampNextWrite);
    _on(HarnessMethods.stallWrites, _stallWrites);
    _on(HarnessMethods.releaseWrites, _releaseWrites);
    _on(HarnessMethods.setReadOnly, _setReadOnly);
    _registerDataServices();

    // Swallowed on purpose. A channel that fails must fail the check that named
    // the property it broke; an unhandled zone error would instead be
    // attributed to whichever test happened to be running when it landed, which
    // is exactly the misattribution `test/suite_integrity_test.dart:78-85`
    // collects zone errors to avoid.
    unawaited(peer.listen().catchError((Object _) => null).whenComplete(() {
      _closed = true;
      if (!_done.isCompleted) _done.complete();
    }));

    // The opening snapshot: recovery — and connection — is always a snapshot
    // and never a delta replay (CLI-03), so a client that attaches to a source
    // which already holds values learns them at once rather than waiting until
    // each next happens to change.
    _adoptNewKeys();
  }

  // ------------------------------------------------------------- value path

  Future<Object?> _readFresh(rpc.Parameters params) async =>
      _answering((await api.readFresh(params['key'].asString)).toJson());

  Future<Object?> _readMany(rpc.Parameters params) async {
    final keys = [for (final key in params['keys'].asList) '$key'];
    final values = await api.readMany(keys);
    return _answering({
      for (final entry in values.entries) entry.key: entry.value.toJson(),
    });
  }

  Future<Object?> _write(rpc.Parameters params) async {
    final key = params['key'].asString;
    final value = params['value'].valueOr(null);
    // Absent and null are the same thing here, deliberately: the reference
    // implementation's compare-and-set is itself keyed on `expected != null`
    // (`fake_state_man.dart:676`), so a wire that distinguished them would be
    // carrying a distinction the source cannot act on.
    final expected = params['expect'].valueOr(null);

    // The same refusal `WriteParams` makes (`messages.dart:373-401`), made
    // here because this harness does not carry a `WriteParams` — the `cmd` is
    // minted by the served implementation, not by the caller, so there is no
    // client-minted id to build one around.
    //
    // Reachable only from a raw frame, and reachable nonetheless: `jsonEncode`
    // refuses to *emit* a non-finite, but `1e999` silently *decodes* to
    // Infinity, so the decoder is where poison enters from outside. Both
    // losses it prevents are silent — a nulled value actuates the device with
    // something nobody chose, and a nulled `expect` is this path's encoding of
    // "no compare-and-set guard", which turns a guarded write into an
    // unconditional one.
    //
    // An error answer rather than a silent one: on a write, a JSON-RPC error
    // means "definitively no effect", which is the one outcome it is safe to
    // re-send — and, more immediately, it means the caller's request settles.
    // There is no per-request deadline on this path (Phase 4 owns that), so
    // anything that does not answer hangs forever (RESEARCH Finding 15).
    //
    // An [rpc.RpcException] carrying its own `data.request`, rather than the
    // plain `FormatException` this obviously wants to be, and the reason is
    // the trap that makes this whole guard nearly self-defeating:
    // `RpcException.serialize` copies the offending **request** into the error
    // it sends back unless `data` already has a `request` key
    // (`json_rpc_2-4.1.0/lib/src/exception.dart:46-57`). A request carrying
    // Infinity therefore produces an error response carrying Infinity, which
    // `jsonEncode` refuses on the way out — so the refusal is thrown away
    // inside the peer and the caller waits forever. The failure the guard
    // exists to prevent is exactly the failure the guard would have caused.
    // The substitute string is what keeps the answer encodable.
    if (sanitize(value).hadNonFinite || sanitize(expected).hadNonFinite) {
      throw rpc.RpcException(
        error_code.INVALID_PARAMS,
        'write params carry a non-finite number: nulling a value would '
            'actuate the device with something the operator did not choose, '
            'and nulling an expect would turn a guarded write into an '
            'unconditional one',
        data: {
          'key': key,
          'request': 'omitted: it carries a non-finite number, and echoing it '
              'here is what makes the error itself unencodable',
        },
      );
    }

    final result = await api.write(key, value, expect: expected);
    return _answering(result.toJson());
  }

  /// Re-asks the source what became of a list of commands.
  ///
  /// Request-shaped, unlike the levers below, because it has an answer and
  /// the answer is the whole point: it is positionally aligned with the
  /// question, and a caller reconciling a reconnect reads element *i* as the
  /// verdict on `cmds[i]`.
  Future<Object?> _writeStatus(rpc.Parameters params) async {
    final cmds = [for (final cmd in params['cmds'].asList) '$cmd'];
    final results = await api.writeStatus(cmds);
    return _answering(
        {'results': [for (final result in results) result.toJson()]});
  }

  /// One feed of a hold-to-run deadman, applied to the plant.
  ///
  /// Notification-shaped and `void`, matching the real wire: a tick has no
  /// outcome to correlate, and json_rpc_2 sends nothing back for a
  /// notification anyway.
  ///
  /// **It must never throw.** A notification handler that throws does not
  /// answer the caller — the error goes to `onUnhandledError` (measured,
  /// 05-RESEARCH §B.1 #2) — so at ten frames a second a malformed or
  /// unrecognised tick would become a log flood that tells nobody anything.
  /// A tick for a hold this side does not know about is an ordinary,
  /// expected condition: the operator let go a moment ago, or the engage was
  /// refused. Drop it.
  void _holdTick(rpc.Parameters params) {
    final HoldTickParams tick;
    try {
      tick = HoldTickParams.fromJson({
        'k': params['k'].valueOr(null),
        'n': params['n'].valueOr(null),
      });
    } on FormatException {
      // Deliberately swallowed — see above. The machine's safety does not
      // depend on this frame arriving; it depends on the counter stopping.
      return;
    }
    _afterLever(() => holdPlant.applyHoldTick(tick.key, tick.counter));
  }

  // ----------------------------------------------------------------- levers

  void _setValue(rpc.Parameters params) => _afterLever(() => plant.setValue(
        params['key'].asString,
        params['value'].valueOr(null),
        quality: Quality.fromWire(params['q'].valueOr(null)),
        sourceTime: _timeOf(params['t'].valueOr(null)),
      ));

  void _setValues(rpc.Parameters params) => _afterLever(() {
        final raw = params['values'].asMap;
        plant.setValues({
          for (final entry in raw.entries) '${entry.key}': entry.value,
        });
      });

  void _setQuality(rpc.Parameters params) => _afterLever(() => plant.setQuality(
        params['key'].asString,
        Quality.fromWire(params['q'].valueOr(null)),
      ));

  void _dropKey(rpc.Parameters params) =>
      _afterLever(() => plant.dropKey(params['key'].asString));

  void _disconnectUpstream(rpc.Parameters _) =>
      _afterLever(plant.disconnectUpstream);

  void _reconnectUpstream(rpc.Parameters _) =>
      _afterLever(plant.reconnectUpstream);

  // ----------------------------------------------------------- write levers

  /// The write levers, in the same one-way lane as the value levers.
  ///
  /// All five are `void` on `StateManWriteHarness`, so there is nothing for a
  /// caller to await and a request-shaped lever would invent an
  /// acknowledgement the interface does not have. What makes
  /// `stallWrites()` → `write(…)` correct across the channel is instead the
  /// ordering guarantee: the notification was posted first, so it is applied
  /// before the request that follows it is answered. That is a property of the
  /// transport rather than of this file, and a WebSocket has it too, which is
  /// why the sequence transfers to Phase 4 unchanged.
  void _failNextWrite(rpc.Parameters params) => _afterLever(() {
        final raw = params['reason'].asMap;
        writePlant.failNextWrite(
          WriteReason.fromJson({
            for (final entry in raw.entries) '${entry.key}': entry.value,
          }),
          unknown: params['unknown'].asBoolOr(false),
        );
      });

  void _clampNextWrite(rpc.Parameters params) =>
      _afterLever(() => writePlant.clampNextWrite(params['readback'].valueOr(null)));

  void _stallWrites(rpc.Parameters _) => _afterLever(writePlant.stallWrites);

  void _releaseWrites(rpc.Parameters params) => _afterLever(
      () => writePlant.releaseWrites(applied: params['applied'].asBoolOr(true)));

  void _setReadOnly(rpc.Parameters params) => _afterLever(() => writePlant
      .setReadOnly(params['key'].asString, params['readOnly'].asBoolOr(true)));

  // ------------------------------------------------------- the data services

  /// The recorder's control surface, resolved on first use.
  ///
  /// Lazily for the same reason [writePlant] is: a source with no historian
  /// behind it is a legitimate thing to serve, and the four sub-suites that
  /// need no samples judge it perfectly well. The failure then arrives when a
  /// case first seeds, naming what to add.
  late final StateManDataHarness dataPlant = dataHarnessOf(api);

  /// The one subscription behind every client's change stream.
  StreamSubscription<String>? _preferenceChanges;

  /// Thirty-four handlers, one per sub-API method, plus the seeding lever and
  /// the outbound change notification.
  ///
  /// Named individually rather than dispatched from a table of closures keyed
  /// by string: the registration *is* the access-control decision (T-02-22),
  /// and a loop over a map would move the list of what this peer answers out of
  /// the place a reviewer reads and into a place a caller supplies.
  void _registerDataServices() {
    _on(HarnessMethods.browseFetchRoots, _browseFetchRoots);
    _on(HarnessMethods.browseFetchChildren, _browseFetchChildren);
    _on(HarnessMethods.browseFetchDetail, _browseFetchDetail);
    _on(HarnessMethods.browseResolvePath, _browseResolvePath);

    _on(HarnessMethods.timeseriesQuery, _timeseriesQuery);
    _on(HarnessMethods.timeseriesQueryMultiple, _timeseriesQueryMultiple);
    _on(HarnessMethods.timeseriesQueryDownsampled, _timeseriesQueryDownsampled);

    _on(HarnessMethods.historyCreateView, _historyCreateView);
    _on(HarnessMethods.historyUpdateView, _historyUpdateView);
    _on(HarnessMethods.historyDeleteView, _historyDeleteView);
    _on(HarnessMethods.historySelectViews, _historySelectViews);
    _on(HarnessMethods.historyGetKeys, _historyGetKeys);
    _on(HarnessMethods.historyGetGraphs, _historyGetGraphs);
    _on(HarnessMethods.historyGetKeyNames, _historyGetKeyNames);
    _on(HarnessMethods.historyAddPeriod, _historyAddPeriod);
    _on(HarnessMethods.historyDeletePeriod, _historyDeletePeriod);
    _on(HarnessMethods.historyListPeriods, _historyListPeriods);
    _on(HarnessMethods.historyRetentionHorizon, _historyRetentionHorizon);

    _on(HarnessMethods.prefGetKeys, _prefGetKeys);
    _on(HarnessMethods.prefGetAll, _prefGetAll);
    _on(HarnessMethods.prefGetBool, _prefGetBool);
    _on(HarnessMethods.prefGetInt, _prefGetInt);
    _on(HarnessMethods.prefGetDouble, _prefGetDouble);
    _on(HarnessMethods.prefGetString, _prefGetString);
    _on(HarnessMethods.prefGetStringList, _prefGetStringList);
    _on(HarnessMethods.prefContainsKey, _prefContainsKey);
    _on(HarnessMethods.prefSetBool, _prefSetBool);
    _on(HarnessMethods.prefSetInt, _prefSetInt);
    _on(HarnessMethods.prefSetDouble, _prefSetDouble);
    _on(HarnessMethods.prefSetString, _prefSetString);
    _on(HarnessMethods.prefSetStringList, _prefSetStringList);
    _on(HarnessMethods.prefRemove, _prefRemove);
    _on(HarnessMethods.prefClear, _prefClear);

    _on(HarnessMethods.seedTimeseries, _seedTimeseries);

    _registerAccess();

    _watchPreferences();
  }

  // ------------------------------------------------------- the access families
  //
  // Twenty-eight handlers, one per method on the four access interfaces
  // (twenty-nine until the access audit cut `accessTemplates.template`), named
  // individually for the same reason the data services are (T-02-22): the
  // registration IS the access-control decision, and a loop over a table of
  // closures would move the list of what this peer answers out of the place a
  // reviewer reads. The session lever and the recording readout are NOT here —
  // they are read straight off the served instance by `ChannelStateMan`, the
  // way `roundTrips` is, because the session is test scaffolding and not wire
  // traffic.

  void _registerAccess() {
    _on(HarnessMethods.accessTemplatesList, _tplList);
    _on(HarnessMethods.accessTemplatesBindings, _tplBindings);
    _on(HarnessMethods.accessTemplatesKeysBoundTo, _tplKeysBoundTo);
    _on(HarnessMethods.accessTemplatesCreate, _tplCreate);
    _on(HarnessMethods.accessTemplatesUpdate, _tplUpdate);
    _on(HarnessMethods.accessTemplatesRename, _tplRename);
    _on(HarnessMethods.accessTemplatesDelete, _tplDelete);
    _on(HarnessMethods.accessTemplatesBind, _tplBind);
    _on(HarnessMethods.accessTemplatesUnbind, _tplUnbind);

    _on(HarnessMethods.accessAdminRoles, _admRoles);
    _on(HarnessMethods.accessAdminListUsers, _admListUsers);
    _on(HarnessMethods.accessAdminCreateRole, _admCreateRole);
    _on(HarnessMethods.accessAdminUpdateRole, _admUpdateRole);
    _on(HarnessMethods.accessAdminDeleteRole, _admDeleteRole);
    _on(HarnessMethods.accessAdminRenameRole, _admRenameRole);
    _on(HarnessMethods.accessAdminCreateUser, _admCreateUser);
    _on(HarnessMethods.accessAdminDeleteUser, _admDeleteUser);
    _on(HarnessMethods.accessAdminSetUserRole, _admSetUserRole);
    _on(HarnessMethods.accessAdminSetUserStationAccount, _admSetStationAccount);
    _on(HarnessMethods.accessAdminSetUserPassword, _admSetUserPassword);

    _on(HarnessMethods.auditEntries, _audEntries);
    _on(HarnessMethods.auditMemberCounts, _audMemberCounts);
    _on(HarnessMethods.auditDistinctWho, _audDistinctWho);

    _on(HarnessMethods.configRead, _cfgRead);
    _on(HarnessMethods.configValidate, _cfgValidate);
    _on(HarnessMethods.configWrite, _cfgWrite);
    _on(HarnessMethods.configPrevious, _cfgPrevious);
    _on(HarnessMethods.configRestorePrevious, _cfgRestorePrevious);
  }

  /// Answers an access method, mapping the refusal shapes as D-09 requires.
  ///
  /// An [AccessDenied] — an authorisation verdict — becomes
  /// [HarnessErrorCodes.accessForbidden] carrying the item key and the required
  /// group, so the client can re-raise the SAME AccessDenied and a refusal is
  /// one exception type on both legs. Every other failure — the domain rules
  /// (a bound template, the last users-holder, a bad config), a decode fault —
  /// goes through [_answer] to [HarnessErrorCodes.subApiFailed], deliberately a
  /// different code, so the contract can tell "you may not" from "you cannot
  /// yet". The harness mints no refusal of its own.
  Future<Object?> _answerAccess(
      String method, Future<Object?> Function() work) async {
    try {
      return await work();
    } on AccessDenied catch (denial) {
      throw rpc.RpcException(
        HarnessErrorCodes.accessForbidden,
        '$denial',
        data: {'itemKey': denial.itemKey, 'group': denial.required.name},
      );
    }
    // Anything else falls to _answer's mapping via the caller's second layer.
  }

  /// [_answerAccess] then [_answer]: the verdict mapping first, the generic
  /// substitution-and-subApiFailed mapping for everything else.
  Future<Object?> _access(String method, Future<Object?> Function() work) =>
      _answer(method, () => _answerAccess(method, work));

  // templates

  Future<Object?> _tplList(rpc.Parameters _) =>
      _access(HarnessMethods.accessTemplatesList, () async => [
            for (final t in await api.accessTemplates.list())
              accessTemplateToJson(t),
          ]);

  // No `template(name)` handler: the access audit cut the member from the
  // wire. A remote derives one template from `list()`.

  Future<Object?> _tplBindings(rpc.Parameters _) =>
      _access(HarnessMethods.accessTemplatesBindings,
          () async => await api.accessTemplates.bindings());

  Future<Object?> _tplKeysBoundTo(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesKeysBoundTo,
          () async => await api.accessTemplates
              .keysBoundTo(params['templateName'].asString));

  Future<Object?> _tplCreate(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesCreate, () async {
        await api.accessTemplates.create(
            accessTemplateFromJson(_object(params['value'].asMap)),
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _tplUpdate(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesUpdate, () async {
        await api.accessTemplates.update(
            accessTemplateFromJson(_object(params['value'].asMap)),
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _tplRename(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesRename, () async {
        await api.accessTemplates.rename(
            params['from'].asString, params['to'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _tplDelete(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesDelete, () async {
        await api.accessTemplates.delete(params['name'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _tplBind(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesBind, () async {
        await api.accessTemplates.bind(
            params['keyName'].asString, params['templateName'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _tplUnbind(rpc.Parameters params) =>
      _access(HarnessMethods.accessTemplatesUnbind, () async {
        await api.accessTemplates.unbind(params['keyName'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  // roles and users

  Future<Object?> _admRoles(rpc.Parameters _) =>
      _access(HarnessMethods.accessAdminRoles, () async => [
            for (final r in await api.accessAdmin.roles()) accessRoleToJson(r),
          ]);

  Future<Object?> _admListUsers(rpc.Parameters _) =>
      _access(HarnessMethods.accessAdminListUsers, () async => [
            for (final u in await api.accessAdmin.listUsers())
              userSummaryToJson(u),
          ]);

  Future<Object?> _admCreateRole(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminCreateRole, () async {
        await api.accessAdmin.createRole(
            accessRoleFromJson(_object(params['role'].asMap)),
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admUpdateRole(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminUpdateRole, () async {
        await api.accessAdmin.updateRole(
            accessRoleFromJson(_object(params['role'].asMap)),
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admDeleteRole(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminDeleteRole, () async {
        await api.accessAdmin.deleteRole(params['name'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admRenameRole(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminRenameRole, () async {
        await api.accessAdmin.renameRole(
            params['from'].asString, params['to'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admCreateUser(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminCreateUser, () async {
        await api.accessAdmin
            .createUser(NewUserParams.fromJson(_object(params.asMap)));
        return null;
      });

  Future<Object?> _admDeleteUser(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminDeleteUser, () async {
        await api.accessAdmin.deleteUser(params['subject'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admSetUserRole(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminSetUserRole, () async {
        await api.accessAdmin.setUserRole(
            params['subject'].asString, params['newRole'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admSetStationAccount(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminSetUserStationAccount, () async {
        await api.accessAdmin.setUserStationAccount(
            params['subject'].asString, params['value'].asBool,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _admSetUserPassword(rpc.Parameters params) =>
      _access(HarnessMethods.accessAdminSetUserPassword, () async {
        await api.accessAdmin
            .setUserPassword(SetUserPasswordParams.fromJson(_object(params.asMap)));
        return null;
      });

  // audit

  Future<Object?> _audEntries(rpc.Parameters params) =>
      _access(HarnessMethods.auditEntries, () async => [
            for (final row in await api.audit
                .entries(AuditQueryParams.fromJson(_object(params['query'].asMap))))
              auditRecordToJson(row),
          ]);

  Future<Object?> _audMemberCounts(rpc.Parameters params) =>
      _access(HarnessMethods.auditMemberCounts, () async {
        final ids = [for (final id in params['actionIds'].asList) '$id'];
        return await api.audit.memberCountsByAction(ids);
      });

  Future<Object?> _audDistinctWho(rpc.Parameters _) =>
      _access(HarnessMethods.auditDistinctWho,
          () async => await api.audit.distinctWho());

  // backend config

  Future<Object?> _cfgRead(rpc.Parameters _) => _access(
      HarnessMethods.configRead, () async => (await api.backendConfig.read()).toJson());

  Future<Object?> _cfgValidate(rpc.Parameters params) =>
      _access(HarnessMethods.configValidate, () async =>
          (await api.backendConfig.validate(params['configJson'].asString))
              .toJson());

  Future<Object?> _cfgWrite(rpc.Parameters params) =>
      _access(HarnessMethods.configWrite, () async {
        await api.backendConfig.write(params['configJson'].asString,
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  Future<Object?> _cfgPrevious(rpc.Parameters _) =>
      _access(HarnessMethods.configPrevious, () async {
        final doc = await api.backendConfig.previous();
        return doc?.toJson();
      });

  Future<Object?> _cfgRestorePrevious(rpc.Parameters params) =>
      _access(HarnessMethods.configRestorePrevious, () async {
        await api.backendConfig.restorePrevious(
            reason: params['reason'].valueOr(null) as String?);
        return null;
      });

  /// One subscription, however many clients are listening on the far side.
  ///
  /// Opened here rather than on demand because a change that happens before
  /// anybody asked is still a change a settings page must not miss — the same
  /// argument the opening snapshot makes for values. The fan-out to individual
  /// listeners is the client's job (`ChannelPreferencesApi`), so the wire
  /// carries one message per change no matter how many widgets are open.
  ///
  /// [UnsupportedError] is caught and not rethrown: a source with no preference
  /// store is legitimate — the data-services sub-suite is skipped for it, with
  /// a reason on the record — and refusing to serve it at all would turn a
  /// declared absence into a startup failure. Nothing else is caught, because
  /// nothing else here is a shape a correct source can have.
  void _watchPreferences() {
    try {
      _preferenceChanges = api.preferences.onPreferencesChanged.listen((key) {
        if (_closed || peer.isClosed) return;
        peer.sendNotification(HarnessMethods.preferencesChanged, {'key': key});
      });
    } on UnsupportedError {
      _preferenceChanges = null;
    }
  }

  /// Answers [method], with every failure turned into an encodable error.
  ///
  /// The wrapper exists for one reason, and it is the trap 02-05 documented on
  /// the write path: `RpcException.serialize` copies the offending **request**
  /// into the error response unless `data` already carries a `request` key
  /// (`json_rpc_2-4.1.0/lib/src/exception.dart:46-57`), and json_rpc_2's own
  /// wrapping of an uncaught error does the same. A request that `jsonEncode`
  /// cannot re-emit — one carrying an Infinity decoded from `1e999` — therefore
  /// produces an error response that cannot be sent, the refusal is thrown away
  /// inside the peer, and the caller waits forever on a path with no deadline
  /// (RESEARCH Finding 15). Substituting `request` here is what keeps the
  /// answer sendable, so a failure arrives as a failure.
  ///
  /// [TypeError] keeps its own code on the way out, because it is part of the
  /// interface being mirrored rather than an incident: `PreferencesApi`'s typed
  /// getters throw one when the stored value is of another type, and a client
  /// catching `on TypeError` in ported code has to catch the same thing here.
  Future<Object?> _answer(String method, Future<Object?> Function() work) async {
    try {
      return await work();
    } on rpc.RpcException {
      rethrow;
    } on TypeError catch (error) {
      throw rpc.RpcException(HarnessErrorCodes.typeMismatch, '$error',
          data: _substitute(method));
    } catch (error) {
      throw rpc.RpcException(
          HarnessErrorCodes.subApiFailed, '$method failed: $error',
          data: _substitute(method));
    }
  }

  static Map<String, Object?> _substitute(String method) => {
        'method': method,
        'request': 'omitted: echoing a request that may carry a non-finite '
            'number is what makes the error itself unencodable, and an '
            'unencodable error on a path with no deadline is a hang',
      };

  // browse

  Future<Object?> _browseFetchRoots(rpc.Parameters _) =>
      _answer(HarnessMethods.browseFetchRoots, () async =>
          [for (final node in await api.browse.fetchRoots()) node.toJson()]);

  Future<Object?> _browseFetchChildren(rpc.Parameters params) =>
      _answer(HarnessMethods.browseFetchChildren, () async {
        final parent = BrowseNode.fromJson(_object(params['parent'].asMap));
        return [
          for (final node in await api.browse.fetchChildren(parent))
            node.toJson(),
        ];
      });

  Future<Object?> _browseFetchDetail(rpc.Parameters params) =>
      _answer(HarnessMethods.browseFetchDetail, () async {
        final node = BrowseNode.fromJson(_object(params['node'].asMap));
        return (await api.browse.fetchDetail(node)).toJson();
      });

  Future<Object?> _browseResolvePath(rpc.Parameters params) =>
      _answer(HarnessMethods.browseResolvePath, () async {
        final chain = await api.browse.resolvePath(params['targetId'].asString);
        // Null and the empty list stay apart: null is a stale binding, and an
        // empty list would claim the target sits zero nodes from a root.
        return chain == null ? null : [for (final node in chain) node.toJson()];
      });

  // timeseries

  Future<Object?> _timeseriesQuery(rpc.Parameters params) =>
      _answer(HarnessMethods.timeseriesQuery, () async => _points(
          await api.timeseries.queryTimeseriesData(
              params['table'].asString, _at(params['to'].value)!,
              orderBy: params['orderBy'].valueOr(null) as String?,
              from: _at(params['from'].valueOr(null)))));

  Future<Object?> _timeseriesQueryMultiple(rpc.Parameters params) =>
      _answer(HarnessMethods.timeseriesQueryMultiple, () async {
        final tables = [for (final name in params['tables'].asList) '$name'];
        final answers = await api.timeseries.queryTimeseriesDataMultiple(
            tables, _at(params['to'].value)!,
            orderBy: params['orderBy'].valueOr(null) as String?,
            from: _at(params['from'].valueOr(null)));
        return {
          for (final entry in answers.entries) entry.key: _points(entry.value),
        };
      });

  Future<Object?> _timeseriesQueryDownsampled(rpc.Parameters params) =>
      _answer(HarnessMethods.timeseriesQueryDownsampled, () async => _points(
          await api.timeseries.queryTimeseriesDataDownsampled(
              params['table'].asString,
              _at(params['from'].value)!,
              _at(params['to'].value)!,
              maxPoints: params['maxPoints'].asInt)));

  // history views

  Future<Object?> _historyCreateView(rpc.Parameters params) =>
      _answer(HarnessMethods.historyCreateView, () async =>
          api.historyViews.createHistoryView(
            params['name'].asString,
            [for (final key in params['keys'].asList) '$key'],
            _keyConfigs(params['keyConfigs'].valueOr(null)),
            _graphConfigs(params['graphConfigs'].valueOr(null)),
          ));

  Future<Object?> _historyUpdateView(rpc.Parameters params) =>
      _answer(HarnessMethods.historyUpdateView, () async {
        await api.historyViews.updateHistoryView(
          params['id'].asInt,
          params['name'].asString,
          [for (final key in params['keys'].asList) '$key'],
          _keyConfigs(params['keyConfigs'].valueOr(null)),
          _graphConfigs(params['graphConfigs'].valueOr(null)),
        );
        return null;
      });

  Future<Object?> _historyDeleteView(rpc.Parameters params) =>
      _answer(HarnessMethods.historyDeleteView, () async {
        await api.historyViews.deleteHistoryView(params['id'].asInt);
        return null;
      });

  Future<Object?> _historySelectViews(rpc.Parameters _) =>
      _answer(HarnessMethods.historySelectViews, () async => [
            for (final view in await api.historyViews.selectHistoryViews())
              view.toJson(),
          ]);

  Future<Object?> _historyGetKeys(rpc.Parameters params) =>
      _answer(HarnessMethods.historyGetKeys, () async {
        final keys =
            await api.historyViews.getHistoryViewKeys(params['viewId'].asInt);
        return {
          for (final entry in keys.entries) entry.key: entry.value.toJson(),
        };
      });

  Future<Object?> _historyGetGraphs(rpc.Parameters params) =>
      _answer(HarnessMethods.historyGetGraphs, () async =>
          historyViewGraphsToJson(await api.historyViews
              .getHistoryViewGraphs(params['viewId'].asInt)));

  Future<Object?> _historyGetKeyNames(rpc.Parameters params) =>
      _answer(HarnessMethods.historyGetKeyNames, () async =>
          api.historyViews.getHistoryViewKeyNames(params['viewId'].asInt));

  Future<Object?> _historyAddPeriod(rpc.Parameters params) =>
      _answer(HarnessMethods.historyAddPeriod, () async =>
          api.historyViews.addHistoryViewPeriod(
            params['viewId'].asInt,
            params['name'].asString,
            _at(params['start'].value)!,
            _at(params['end'].value)!,
          ));

  Future<Object?> _historyDeletePeriod(rpc.Parameters params) =>
      _answer(HarnessMethods.historyDeletePeriod, () async {
        await api.historyViews.deleteHistoryViewPeriod(params['id'].asInt);
        return null;
      });

  Future<Object?> _historyListPeriods(rpc.Parameters params) =>
      _answer(HarnessMethods.historyListPeriods, () async => [
            for (final period in await api.historyViews
                .listHistoryViewPeriods(params['viewId'].asInt))
              period.toJson(),
          ]);

  Future<Object?> _historyRetentionHorizon(rpc.Parameters _) =>
      _answer(HarnessMethods.historyRetentionHorizon, () async =>
          (await api.historyViews.getGlobalRetentionHorizon())
              ?.millisecondsSinceEpoch);

  // preferences

  Future<Object?> _prefGetKeys(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetKeys, () async =>
          (await api.preferences.getKeys(allowList: _allowList(params)))
              .toList());

  Future<Object?> _prefGetAll(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetAll,
          () => api.preferences.getAll(allowList: _allowList(params)));

  Future<Object?> _prefGetBool(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetBool,
          () => api.preferences.getBool(params['key'].asString));

  Future<Object?> _prefGetInt(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetInt,
          () => api.preferences.getInt(params['key'].asString));

  Future<Object?> _prefGetDouble(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetDouble,
          () => api.preferences.getDouble(params['key'].asString));

  Future<Object?> _prefGetString(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetString,
          () => api.preferences.getString(params['key'].asString));

  Future<Object?> _prefGetStringList(rpc.Parameters params) =>
      _answer(HarnessMethods.prefGetStringList,
          () => api.preferences.getStringList(params['key'].asString));

  Future<Object?> _prefContainsKey(rpc.Parameters params) =>
      _answer(HarnessMethods.prefContainsKey,
          () => api.preferences.containsKey(params['key'].asString));

  Future<Object?> _prefSetBool(rpc.Parameters params) =>
      _answer(HarnessMethods.prefSetBool, () async {
        await api.preferences
            .setBool(params['key'].asString, params['value'].asBool);
        return null;
      });

  Future<Object?> _prefSetInt(rpc.Parameters params) =>
      _answer(HarnessMethods.prefSetInt, () async {
        await api.preferences
            .setInt(params['key'].asString, params['value'].asInt);
        return null;
      });

  Future<Object?> _prefSetDouble(rpc.Parameters params) =>
      _answer(HarnessMethods.prefSetDouble, () async {
        // Through `num` rather than `asNum.toDouble()` on a cast: an integral
        // double is emitted as `800.0` by Dart's encoder but a hand-written
        // client may well send `800`, and refusing that would be refusing a
        // value the type admits.
        await api.preferences
            .setDouble(params['key'].asString, params['value'].asNum.toDouble());
        return null;
      });

  Future<Object?> _prefSetString(rpc.Parameters params) =>
      _answer(HarnessMethods.prefSetString, () async {
        await api.preferences
            .setString(params['key'].asString, params['value'].asString);
        return null;
      });

  Future<Object?> _prefSetStringList(rpc.Parameters params) =>
      _answer(HarnessMethods.prefSetStringList, () async {
        await api.preferences.setStringList(params['key'].asString,
            [for (final entry in params['value'].asList) '$entry']);
        return null;
      });

  Future<Object?> _prefRemove(rpc.Parameters params) =>
      _answer(HarnessMethods.prefRemove, () async {
        await api.preferences.remove(params['key'].asString);
        return null;
      });

  Future<Object?> _prefClear(rpc.Parameters params) =>
      _answer(HarnessMethods.prefClear, () async {
        await api.preferences.clear(allowList: _allowList(params));
        return null;
      });

  /// The seeding lever, in the same one-way lane as the value levers.
  ///
  /// `seedTimeseries` is `void` on [StateManDataHarness], so there is nothing
  /// to await; what makes seed-then-query correct is the channel's ordering,
  /// which a socket has too.
  ///
  /// Decoded as [TimeseriesData]`<num>` — the same element type the contract
  /// seeds and the widest one JSON numbers carry losslessly. A series of
  /// anything else needs a `decode` callback agreed at both ends; see the
  /// header of `channel_sub_apis.dart`.
  void _seedTimeseries(rpc.Parameters params) {
    if (_closed) return;
    dataPlant.seedTimeseries(params['table'].asString, [
      for (final point in params['points'].asList)
        TimeseriesData<num>.fromJson(_object((point as Map))),
    ]);
  }

  Set<String>? _allowList(rpc.Parameters params) {
    final raw = params['allowList'].valueOr(null);
    return raw == null ? null : {for (final key in raw as List) '$key'};
  }

  static List<Object?> _points(List<TimeseriesData> points) =>
      [for (final point in points) point.toJson()];

  static Map<String, Object?> _object(Map<Object?, Object?> raw) =>
      {for (final entry in raw.entries) '${entry.key}': entry.value};

  static Map<String, HistoryViewKeyRecord>? _keyConfigs(Object? raw) => raw ==
          null
      ? null
      : {
          for (final entry in (raw as Map).entries)
            '${entry.key}': HistoryViewKeyRecord.fromJson(
                _object(entry.value as Map<Object?, Object?>)),
        };

  static Map<int, HistoryViewGraphRecord>? _graphConfigs(Object? raw) =>
      raw == null ? null : historyViewGraphsFromJson(raw);

  /// Epoch milliseconds to a UTC instant; null stays null.
  static DateTime? _at(Object? raw) => raw == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch((raw as num).toInt(), isUtc: true);

  /// Applies a lever, then adopts whatever keys it brought into existence.
  ///
  /// The re-scan is not an optimisation and cannot be dropped: `setValue` on a
  /// key nothing has been heard about creates that key, and the value lands
  /// before any listener could have been attached to it. Without this, the
  /// first value of every new key would be the one value that never crosses the
  /// channel — and the first value of a key is precisely what a page opening
  /// shows an operator.
  void _afterLever(void Function() lever) {
    if (_closed) return;
    lever();
    _adoptNewKeys();
  }

  void _adoptNewKeys() {
    for (final key in api.keys) {
      if (_watchers.containsKey(key)) continue;
      void watch() => _changed(key);
      _watchers[key] = watch;
      api.listen(key).addListener(watch);
      // A key adopted here has just acquired a value, by definition — `keys` is
      // filtered on one having arrived — so it is a change the client has not
      // seen.
      _pending.add(key);
    }
    if (_pending.isNotEmpty) _scheduleFlush();
  }

  void _changed(String key) {
    _pending.add(key);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled || _closed) return;
    _flushScheduled = true;
    scheduleMicrotask(_flush);
  }

  /// One notification per flush, however many keys moved.
  ///
  /// A microtask rather than a timer: a lever applies its whole batch
  /// synchronously, so by the time the microtask queue drains, every key that
  /// batch touched is in [_pending] and one message carries all of them. A
  /// timer would coalesce *across* levers too, which would make the count this
  /// promises depend on how fast the test ran.
  void _flush() {
    _flushScheduled = false;
    if (_closed || _pending.isEmpty) return;
    final changes = <String, Object?>{};
    for (final key in _pending) {
      final value = api.read(key);
      if (value == null) continue;
      changes[key] = value.toJson();
    }
    _pending.clear();
    if (changes.isEmpty) return;
    peer.sendNotification(HarnessMethods.update, {'changes': changes});
  }

  /// Puts every change made so far on the wire, then hands back [answer].
  ///
  /// **An answer must never overtake the state change it caused.** A request
  /// handler that alters a value and then returns leaves two facts travelling
  /// on one channel — "the write applied" and "the value is now 1500" — and the
  /// client's `await` resumes on the first of them. If the second is still
  /// sitting in a microtask, every caller that reads the value the instant its
  /// write resolves sees the number from before its own write, badged pending,
  /// and `checkWritePendingIsVisibleWhileInFlight` says exactly what that looks
  /// like on a panel: a permanent amber box the operator learns to ignore.
  ///
  /// Ordering here was previously left to the microtask queue, and it happened
  /// to come out right for `FakeStateMan` — which settles a write one `await`
  /// later than it applies it — and wrong for an implementation that settles in
  /// fewer hops. **13-11 measured both**: served over the same WebSocket, the
  /// reference implementation put the update on the sink before the response
  /// and `BackendStateMan` put it after, by ~100 µs. A property that depends on
  /// how many microtasks an implementation happens to use is not a property;
  /// this makes it one.
  ///
  /// Cheap and safe: it can only move a notification EARLIER, never later,
  /// never duplicate one (`_flush` clears `_pending` and a scheduled flush that
  /// finds it empty returns), and never split a lever's batch — a lever applies
  /// its whole batch synchronously and its flush microtask drains before the
  /// next inbound frame is read.
  T _answering<T>(T answer) {
    if (_pending.isNotEmpty) _flush();
    return answer;
  }

  /// Detaches every listener and closes the peer. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final entry in _watchers.entries) {
      api.listen(entry.key).removeListener(entry.value);
    }
    _watchers.clear();
    _pending.clear();
    // The preference subscription is a listener on the served store exactly as
    // the per-key watchers are, and leaving it attached keeps pushing into a
    // closed channel — the leak that surfaces as an inexplicable failure in
    // whichever case runs next.
    await _preferenceChanges?.cancel();
    _preferenceChanges = null;
    await peer.close();
    if (!_done.isCompleted) _done.complete();
  }

  static DateTime? _timeOf(Object? raw) => raw is num
      ? DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true)
      : null;
}
