/// The four data-service sub-APIs, forwarded over the pipe.
///
/// Browse, timeseries, history views and preferences: thirty-four methods that
/// are, with two exceptions, pure translation. Each class holds one function —
/// this package's deadline-wrapped request — and every method is one message
/// out and one back. There is deliberately no shared `call(method, args)` entry
/// point and no dispatch on a caller-supplied string: the set of things
/// reachable across this boundary has to stay a list a person can read
/// (T-02-22), because a method that exists is a thing any connected client may
/// invoke, which makes adding one an access-control decision.
///
/// The structure is `tfc_stateman_contract`'s `channel_sub_apis.dart`, ported
/// method for method. What changed is the transport underneath (a peer that is
/// swapped on every reconnect, reached through a deadline) and the method
/// names, which lose the `harness.` prefix because these are the names the
/// gateway will answer.
///
/// **Phase 10 landed all thirty-four handlers**, so every method here now
/// reaches a gateway that answers it.
///
/// ## The two things that are not translation
///
/// **`TimeseriesData.fromJson` takes a value parser, and the wrong one is
/// silently lossy.** Its default coercion is driven by the type argument: with
/// no argument at all the samples come back as whatever `jsonDecode` produced,
/// so an integral double lands as an `int` and a chart's arithmetic changes
/// underneath it. Everything here decodes as [TimeseriesData]`<num>`, the widest
/// type the JSON number grammar carries losslessly. A series whose elements are
/// not numbers cannot cross this lever, and the day a source needs one the
/// parser has to be agreed at both ends rather than defaulted at one.
///
/// **A preference change is one notification, fanned out locally.**
/// [ClientPreferencesApi] holds a single broadcast controller and every local
/// listener reads from it. A subscription per listener would make the number of
/// messages on the wire depend on how many widgets happen to be open, which is
/// the shape of thing that works in a test and falls over on a panel with
/// thirty of them.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The wire names of the data services.
///
/// Phase 10 moved them to `tfc_relay_protocol`'s `methods.dart`, where the
/// gateway can reach them too; re-exported here so call sites that took them
/// from this file still find them.
export 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show DataServiceMethods;

/// The JSON-RPC error code a stored value of the wrong type comes back under.
///
/// The gateway's `ServerErrorCodes.typeMismatch` (`error_codes.dart:94-100`).
///
/// Declared here rather than imported for the reason `connection_supervisor`
/// gives about the version-mismatch code: the number is the contract, and a
/// production file may not reach into a package this one depends on only for
/// its tests.
///
/// **It read `-32001` until Phase 10, and that was a real bug rather than a
/// near miss.** `-32001` is the *contract harness*'s type-mismatch code
/// (`rpc_names.dart:53`), borrowed from the kit's own peer when these classes
/// were ported from it; on this wire it is `ServerErrorCodes.helloRequired`.
/// So the check fired on exactly the wrong things in both directions:
/// `PreferencesApi`'s promised `TypeError` never surfaced for a mismatch, and
/// a call that arrived before the handshake was re-raised to a settings page
/// as a type error about a value nobody had read.
const int _typeMismatch = -32010;

/// One request over the pipe: a method name, its parameters, its answer.
///
/// A function rather than the peer itself, so these four classes cannot reach
/// anything the value path has not already decided to expose — and so a test can
/// drive one of them without a socket at all. It is the client's own
/// deadline-wrapped request, so a gateway that stops answering costs one call
/// rather than a page that waits forever.
typedef RemoteCall = Future<Object?> Function(
    String method, Map<String, Object?> params);

/// A type mismatch that happened on the far side, re-raised as the type the
/// interface promises.
///
/// `PreferencesApi`'s typed getters "throw a `TypeError` when the stored value
/// is of another type" (`preferences_api.dart:30-36`), and that is part of the
/// interface being mirrored: a settings page catching `TypeError` around a
/// `getInt` is porting code that already does. The cast necessarily happens
/// where the value is stored, so what crosses the pipe is a JSON-RPC error;
/// this is what it becomes on the way out, so a caller sees the same type from
/// the same call it would have seen in process.
final class RemoteTypeError extends TypeError {
  RemoteTypeError(this.message);

  /// The far side's own description of the mismatch, kept because the message
  /// is the useful half — `type 'String' is not a subtype of type 'int'` names
  /// the key's actual contents.
  final String message;

  @override
  String toString() => message;
}

/// Runs [send], turning the far side's type mismatch back into a [TypeError].
Future<Object?> withTypedErrors(Future<Object?> Function() send) async {
  try {
    return await send();
  } on rpc.RpcException catch (error) {
    if (error.code != _typeMismatch) rethrow;
    throw RemoteTypeError(error.message);
  }
}

/// Narrows a decoded JSON value to an object, or says what arrived instead.
Map<String, Object?> jsonObject(Object? raw) => raw is Map
    ? {for (final entry in raw.entries) '${entry.key}': entry.value}
    : throw FormatException('expected a JSON object, got ${raw.runtimeType}');

/// Narrows a decoded JSON value to an array.
List<Object?> jsonArray(Object? raw) => raw is List
    ? raw
    : throw FormatException('expected a JSON array, got ${raw.runtimeType}');

/// Epoch milliseconds, UTC — the wire's one timestamp convention.
///
/// Milliseconds and not microseconds because that is the precision every record
/// in `history_view.dart` and `timeseries.dart` already encodes at, and a second
/// convention would make two timestamps that are `==` in Dart compare unequal
/// after a round trip.
int msOf(DateTime time) => time.millisecondsSinceEpoch;

/// The inverse of [msOf], always UTC.
DateTime timeOf(Object? raw) =>
    DateTime.fromMillisecondsSinceEpoch((raw as num).toInt(), isUtc: true);

// ------------------------------------------------------------------- browse

/// [BrowseApi] over the pipe.
///
/// `fetchChildren` and `fetchDetail` send the whole node rather than its id,
/// which is not redundancy: an OPC UA source addressing a node needs its
/// namespace — carried in `metadata` — as well as its identifier. Sending the id
/// alone would work against the reference implementation and fail against the
/// first real one.
final class ClientBrowseApi implements BrowseApi {
  ClientBrowseApi(this._call);

  final RemoteCall _call;

  @override
  Future<List<BrowseNode>> fetchRoots() async =>
      _nodes(await _call(DataServiceMethods.browseFetchRoots, const {}));

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async => _nodes(
      await _call(
          DataServiceMethods.browseFetchChildren, {'parent': parent.toJson()}));

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async =>
      BrowseNodeDetail.fromJson(jsonObject(await _call(
          DataServiceMethods.browseFetchDetail, {'node': node.toJson()})));

  /// Null stays null, and never becomes an empty list.
  ///
  /// The two are different facts: null is "this source cannot resolve that
  /// target", which is what a page saved against a since-renamed tag hits, and
  /// an empty list would be "the chain to it is zero nodes long". The panel
  /// opens unpositioned on the first and asserts on the second.
  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    final raw = await _call(
        DataServiceMethods.browseResolvePath, {'targetId': targetId});
    return raw == null ? null : _nodes(raw);
  }

  static List<BrowseNode> _nodes(Object? raw) => [
        for (final node in jsonArray(raw)) BrowseNode.fromJson(jsonObject(node)),
      ];
}

// --------------------------------------------------------------- timeseries

/// [TimeseriesApi] over the pipe.
final class ClientTimeseriesApi implements TimeseriesApi {
  ClientTimeseriesApi(this._call);

  final RemoteCall _call;

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      points(await _call(DataServiceMethods.timeseriesQuery, {
        'table': tableName,
        'to': msOf(to),
        // Always present, even when null: null is a legitimate value here — it
        // means "no ordering asked for" — and an absent key would be
        // indistinguishable from it on the far side.
        'orderBy': orderBy,
        'from': from == null ? null : msOf(from),
      }));

  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    final raw =
        jsonObject(await _call(DataServiceMethods.timeseriesQueryMultiple, {
      'tables': tableNames,
      'to': msOf(to),
      'orderBy': orderBy,
      'from': from == null ? null : msOf(from),
    }));
    return {
      for (final entry in raw.entries) entry.key: points(entry.value),
    };
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
          String tableName, DateTime from, DateTime to,
          {int maxPoints = 1000}) async =>
      points(await _call(DataServiceMethods.timeseriesQueryDownsampled, {
        'table': tableName,
        'from': msOf(from),
        'to': msOf(to),
        'maxPoints': maxPoints,
      }));

  /// Samples decoded as `num`, which is the parser question the library doc is
  /// about.
  static List<TimeseriesData> points(Object? raw) => [
        for (final point in jsonArray(raw))
          TimeseriesData<num>.fromJson(jsonObject(point)),
      ];
}

// ------------------------------------------------------------ history views

/// [HistoryViewApi] over the pipe.
///
/// The optional positional configuration maps stay optional and positional,
/// matching the call sites being ported. Absent and empty are kept apart on the
/// wire — `null` means "do not change what is configured", `{}` means "there is
/// none" — because `updateHistoryView` is the method a caller uses for both.
final class ClientHistoryViewApi implements HistoryViewApi {
  ClientHistoryViewApi(this._call);

  final RemoteCall _call;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) async =>
      (await _call(DataServiceMethods.historyCreateView, {
        'name': name,
        'keys': keys,
        'keyConfigs': _keyConfigs(keyConfigs),
        'graphConfigs':
            graphConfigs == null ? null : historyViewGraphsToJson(graphConfigs),
      }) as num)
          .toInt();

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) async =>
      await _call(DataServiceMethods.historyUpdateView, {
        'id': id,
        'name': name,
        'keys': keys,
        'keyConfigs': _keyConfigs(keyConfigs),
        'graphConfigs':
            graphConfigs == null ? null : historyViewGraphsToJson(graphConfigs),
      });

  @override
  Future<void> deleteHistoryView(int id) async =>
      await _call(DataServiceMethods.historyDeleteView, {'id': id});

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() async => [
        for (final view in jsonArray(
            await _call(DataServiceMethods.historySelectViews, const {})))
          HistoryViewRecord.fromJson(jsonObject(view)),
      ];

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(
      int viewId) async {
    final raw = jsonObject(
        await _call(DataServiceMethods.historyGetKeys, {'viewId': viewId}));
    return {
      for (final entry in raw.entries)
        entry.key: HistoryViewKeyRecord.fromJson(jsonObject(entry.value)),
    };
  }

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(
          int viewId) async =>
      historyViewGraphsFromJson(await _call(
          DataServiceMethods.historyGetGraphs, {'viewId': viewId}));

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async => [
        for (final name in jsonArray(await _call(
            DataServiceMethods.historyGetKeyNames, {'viewId': viewId})))
          '$name',
      ];

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) async =>
      (await _call(DataServiceMethods.historyAddPeriod, {
        'viewId': viewId,
        'name': name,
        'start': msOf(start),
        'end': msOf(end),
      }) as num)
          .toInt();

  @override
  Future<void> deleteHistoryViewPeriod(int id) async =>
      await _call(DataServiceMethods.historyDeletePeriod, {'id': id});

  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(
          int viewId) async =>
      [
        for (final period in jsonArray(await _call(
            DataServiceMethods.historyListPeriods, {'viewId': viewId})))
          HistoryViewPeriodRecord.fromJson(jsonObject(period)),
      ];

  /// Null survives as null.
  ///
  /// "Nothing has been discarded yet" and "everything since the epoch is gone"
  /// are opposite answers, and a chart scrolling past the horizon has to tell an
  /// operator which of them it is looking at.
  @override
  Future<DateTime?> getGlobalRetentionHorizon() async {
    final raw =
        await _call(DataServiceMethods.historyRetentionHorizon, const {});
    return raw == null ? null : timeOf(raw);
  }

  static Map<String, Object?>? _keyConfigs(
          Map<String, HistoryViewKeyRecord>? configs) =>
      configs == null
          ? null
          : {
              for (final entry in configs.entries)
                entry.key: entry.value.toJson(),
            };
}

// ------------------------------------------------------------- preferences

/// [PreferencesApi] over the pipe, change stream included.
///
/// The typed getters cast on **this** side, on a value that has been through
/// JSON, and that placement is deliberate. It catches both mismatches with one
/// mechanism: a store holding the wrong type (the far side raises, and
/// [withTypedErrors] re-raises it here as the `TypeError` the interface
/// promises) and a wire that drifted (`getInt` handed a JSON string arrives as a
/// `TypeError` too, rather than as an `int?` that is secretly a `String` waiting
/// to fail somewhere with no context).
final class ClientPreferencesApi implements PreferencesApi {
  ClientPreferencesApi(this._call);

  final RemoteCall _call;

  /// Broadcast, because a settings page and a chart legend both want to hear the
  /// same edit. One controller for however many listeners: the fan-out is local,
  /// and the wire carries one notification per change regardless.
  final _changes = StreamController<String>.broadcast();

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  /// Feeds one inbound change to every local listener.
  ///
  /// Called from the notification handler and nowhere else, which is what keeps
  /// "every change this reports arrived over the pipe" true rather than
  /// approximately true.
  ///
  /// One key at a time on purpose, even though the frame carries a list since
  /// Phase 10: the handler fans the list out and calls this once per key, so
  /// `onPreferencesChanged` stays a `Stream<String>` and contract check 13 is
  /// untouched. **Do not add a buffer here.** Coalescing a burst into one
  /// frame is the gateway's job (10-05 task 2); doing it again on this side
  /// would delay an edit an operator is waiting to see and save nothing,
  /// because the frames are already across.
  void announce(String key) {
    if (_changes.isClosed) return;
    _changes.add(key);
  }

  /// Closes the change stream. Idempotent.
  Future<void> dispose() async {
    if (_changes.isClosed) return;
    await _changes.close();
  }

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async => {
        for (final key in jsonArray(await _call(
            DataServiceMethods.prefGetKeys, {'allowList': allowList?.toList()})))
          '$key',
      };

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      jsonObject(await _call(
          DataServiceMethods.prefGetAll, {'allowList': allowList?.toList()}));

  @override
  Future<bool?> getBool(String key) async =>
      await _get(DataServiceMethods.prefGetBool, key) as bool?;

  @override
  Future<int?> getInt(String key) async =>
      await _get(DataServiceMethods.prefGetInt, key) as int?;

  @override
  Future<double?> getDouble(String key) async =>
      await _get(DataServiceMethods.prefGetDouble, key) as double?;

  @override
  Future<String?> getString(String key) async =>
      await _get(DataServiceMethods.prefGetString, key) as String?;

  /// A fresh `List<String>`, element by element.
  ///
  /// `jsonDecode` produces a `List<dynamic>`, so a plain cast would succeed and
  /// hand back a list that throws on its first read; `List<String>.from` casts
  /// each element now, where the failure can still say which call it came from.
  @override
  Future<List<String>?> getStringList(String key) async {
    final raw = await _get(DataServiceMethods.prefGetStringList, key);
    return raw == null ? null : List<String>.from(raw as List);
  }

  @override
  Future<bool> containsKey(String key) async =>
      await _call(DataServiceMethods.prefContainsKey, {'key': key}) as bool;

  @override
  Future<void> setBool(String key, bool value) async =>
      await _set(DataServiceMethods.prefSetBool, key, value);

  @override
  Future<void> setInt(String key, int value) async =>
      await _set(DataServiceMethods.prefSetInt, key, value);

  @override
  Future<void> setDouble(String key, double value) async =>
      await _set(DataServiceMethods.prefSetDouble, key, value);

  @override
  Future<void> setString(String key, String value) async =>
      await _set(DataServiceMethods.prefSetString, key, value);

  @override
  Future<void> setStringList(String key, List<String> value) async =>
      await _set(DataServiceMethods.prefSetStringList, key, value);

  @override
  Future<void> remove(String key) async =>
      await _call(DataServiceMethods.prefRemove, {'key': key});

  @override
  Future<void> clear({Set<String>? allowList}) async => await _call(
      DataServiceMethods.prefClear, {'allowList': allowList?.toList()});

  Future<Object?> _get(String method, String key) =>
      withTypedErrors(() => _call(method, {'key': key}));

  Future<void> _set(String method, String key, Object? value) async =>
      await _call(method, {'key': key, 'value': value});
}

// -----------------------------------------------------------------------------
// The four access families (Phase 17)
// -----------------------------------------------------------------------------
//
// Templates, roles-and-users, the audit trail and the backend's config, in the
// history-view proxies' exact shape: one `sendRequest`, one decode, no state,
// no retry, no queue. **The far end is the enforcement.** A client-side method
// call cannot write what the gateway's policy refuses — the check sits above
// the store on the gateway, and what these proxies add is only the wire to
// reach it. The refusal comes back as something the caller must handle: the
// same [AccessDenied] a direct-mode refusal throws, so no screen can tell
// which transport refused it (D-09).
//
// **The sentence that is new in this phase: the client sends no identity.**
// No encoded payload here carries a `who`, a `username`, a `station` or any
// other name for the caller — the gateway attributes every write to the
// identity it verified at `hello`, and a client that could name the user
// could forge one (ACCESS-06). 17-03 made an identity parameter
// unrepresentable in the interface; the payload pin in
// `test/access_proxies_test.dart` is what keeps the *encoded frames* true to
// that, because a proxy is free to invent a field the interface never
// mentioned.
//
// **The domain exceptions do not cross as types, and that is not forgotten.**
// `TemplateInUseException`, `TemplateNotFoundException` and their siblings
// live in `tfc_dart`, which this package may not import — so a domain refusal
// (a bound template, the last users-holder, a bad config) travels as a typed
// protocol error: an [rpc.RpcException] under a non-`forbidden` code whose
// `data` carries an error-code string plus the fields the message needs (the
// template name, the bound key list). These proxies pass it through with the
// payload intact, and the APP maps it back to the concrete exception type in
// 17-12, where `tfc_dart` is available.

/// The JSON-RPC error code a gateway policy refusal comes back under.
///
/// The gateway's `ServerErrorCodes.forbidden` (`error_codes.dart:88`).
/// Declared here rather than imported, for [_typeMismatch]'s reason: the
/// number is the contract, and a production file may not reach into a package
/// this one depends on only for its tests. `access_proxies_test.dart` drives
/// it verbatim from the far side of the same boundary.
const int _forbidden = -32005;

/// An [AccessDenied] that was refused on the far side, re-raised with the
/// gateway's own sentence intact.
///
/// **The type is the contract** ([AccessDenied], so `on AccessDenied` in
/// ported screens catches a gateway refusal exactly as it catches a direct
/// one), and **the message is the operator's half**: the gateway's `forbidden`
/// says the call definitively had no effect and must not be retried, and a
/// re-raise that rebuilt the sentence from `itemKey` + `required` alone would
/// drop that wording on exactly the transport where a retry is most tempting.
/// The same narrowing-without-loss shape as [RemoteTypeError] and
/// `AlarmAckUnsupported`: a caller that only knows the supertype keeps
/// working; nothing is flattened.
final class RemoteAccessDenied extends AccessDenied {
  const RemoteAccessDenied(super.itemKey, super.required, this.message);

  /// The gateway's own words, carried because they are the useful half — they
  /// name what was refused and say the call had no effect.
  final String message;

  @override
  String toString() => message;
}

/// Runs [send], re-raising a gateway `forbidden` as the [AccessDenied] a
/// direct-mode refusal throws.
///
/// One code wide, like [withTypedErrors] beside it — the write path's
/// translation (`failure_taxonomy.dart`) answers a different question ("did
/// the machinery move?") in a different shape (a [WriteResult], never a
/// throw), so this seam extends the sub-API pattern rather than that one; see
/// `remote_state_man.dart`'s access block for the reasoning. Every other
/// [rpc.RpcException] — the domain refusals under other codes, a
/// `helloRequired`, a `handlerFailed` — propagates unchanged, which is what
/// keeps "you may not" distinguishable from "you cannot yet".
Future<Object?> withAccessErrors(Future<Object?> Function() send) async {
  try {
    return await send();
  } on rpc.RpcException catch (error) {
    if (error.code != _forbidden) rethrow;
    final data = error.data;
    final itemKey =
        (data is Map ? data['itemKey'] : null)?.toString() ?? 'unknown';
    final groupName = data is Map ? data['group']?.toString() : null;
    // The fallback mirrors the contract kit's channel re-raise
    // (`channel_sub_apis.dart:498-511`): a refusal whose group this build
    // cannot decode is still a refusal, and `users` is the group most of the
    // surface is graded at.
    final group = (groupName == null ? null : AccessGroup.byName(groupName)) ??
        AccessGroup.users;
    throw RemoteAccessDenied(itemKey, group, error.message);
  }
}

/// [AccessTemplateApi] over the pipe.
///
/// The store's `template(name)` single-row read is deliberately absent — the
/// access audit cut it from the wire (no caller anywhere). A caller that wants
/// one template derives it from [list]: same snapshot semantics, zero extra
/// wire names.
final class ClientAccessTemplateApi implements AccessTemplateApi {
  ClientAccessTemplateApi(this._call);

  final RemoteCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      withAccessErrors(() => _call(method, params));

  @override
  Future<List<AccessTemplate>> list() async => [
        for (final row
            in jsonArray(await _send(AccessMethods.templateList, const {})))
          accessTemplateFromJson(jsonObject(row)),
      ];

  @override
  Future<Map<String, String>> bindings() async {
    final raw =
        jsonObject(await _send(AccessMethods.templateBindings, const {}));
    return {for (final entry in raw.entries) entry.key: '${entry.value}'};
  }

  @override
  Future<List<String>> keysBoundTo(String templateName) async => [
        for (final key in jsonArray(await _send(
            AccessMethods.templateKeysBoundTo, {'templateName': templateName})))
          '$key',
      ];

  @override
  Future<void> create(AccessTemplate value, {String? reason}) async =>
      await _send(AccessMethods.templateCreate,
          {'value': accessTemplateToJson(value), 'reason': reason});

  @override
  Future<void> update(AccessTemplate value, {String? reason}) async =>
      await _send(AccessMethods.templateUpdate,
          {'value': accessTemplateToJson(value), 'reason': reason});

  @override
  Future<void> rename(String from, String to, {String? reason}) async =>
      await _send(AccessMethods.templateRename,
          {'from': from, 'to': to, 'reason': reason});

  @override
  Future<void> delete(String name, {String? reason}) async => await _send(
      AccessMethods.templateDelete, {'name': name, 'reason': reason});

  @override
  Future<void> bind(String keyName, String templateName,
          {String? reason}) async =>
      await _send(AccessMethods.templateBind, {
        'keyName': keyName,
        'templateName': templateName,
        'reason': reason,
      });

  @override
  Future<void> unbind(String keyName, {String? reason}) async => await _send(
      AccessMethods.templateUnbind, {'keyName': keyName, 'reason': reason});
}

/// [AccessAdminApi] over the pipe.
///
/// The two credential-carrying members ([createUser], [setUserPassword]) send
/// their params objects whole: the withholding `toString` lives on the params
/// class (17-03 F-B), and the value crosses inside the `wss://` frame to be
/// hashed server-side.
final class ClientAccessAdminApi implements AccessAdminApi {
  ClientAccessAdminApi(this._call);

  final RemoteCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      withAccessErrors(() => _call(method, params));

  @override
  Future<List<AccessRole>> roles() async => [
        for (final row
            in jsonArray(await _send(AccessMethods.adminRoles, const {})))
          accessRoleFromJson(jsonObject(row)),
      ];

  @override
  Future<List<UserSummary>> listUsers() async => [
        for (final row
            in jsonArray(await _send(AccessMethods.adminListUsers, const {})))
          userSummaryFromJson(jsonObject(row)),
      ];

  @override
  Future<void> createRole(AccessRole role, {String? reason}) async =>
      await _send(AccessMethods.adminCreateRole,
          {'role': accessRoleToJson(role), 'reason': reason});

  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async =>
      await _send(AccessMethods.adminUpdateRole,
          {'role': accessRoleToJson(role), 'reason': reason});

  @override
  Future<void> deleteRole(String name, {String? reason}) async => await _send(
      AccessMethods.adminDeleteRole, {'name': name, 'reason': reason});

  @override
  Future<void> renameRole(String from, String to, {String? reason}) async =>
      await _send(AccessMethods.adminRenameRole,
          {'from': from, 'to': to, 'reason': reason});

  @override
  Future<void> createUser(NewUserParams params) async =>
      await _send(AccessMethods.adminCreateUser, params.toJson());

  @override
  Future<void> deleteUser(String subject, {String? reason}) async =>
      await _send(AccessMethods.adminDeleteUser,
          {'subject': subject, 'reason': reason});

  @override
  Future<void> setUserRole(String subject, String newRole,
          {String? reason}) async =>
      await _send(AccessMethods.adminSetUserRole,
          {'subject': subject, 'newRole': newRole, 'reason': reason});

  @override
  Future<void> setUserStationAccount(String subject, bool value,
          {String? reason}) async =>
      await _send(AccessMethods.adminSetUserStationAccount,
          {'subject': subject, 'value': value, 'reason': reason});

  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async =>
      await _send(AccessMethods.adminSetUserPassword, params.toJson());
}

/// [AuditApi] over the pipe — read-only, like the interface: there is no
/// `record` member here for the same reason there is none on the wire, and a
/// `who` in [entries]' query is a *filter*, never an attribution.
final class ClientAuditApi implements AuditApi {
  ClientAuditApi(this._call);

  final RemoteCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      withAccessErrors(() => _call(method, params));

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) async => [
        for (final row in jsonArray(await _send(
            AccessMethods.auditEntries, {'query': query.toJson()})))
          auditRecordFromJson(jsonObject(row)),
      ];

  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) async {
    final raw = jsonObject(await _send(
        AccessMethods.auditMemberCountsByAction, {'actionIds': actionIds}));
    return {for (final entry in raw.entries) entry.key: (entry.value as num).toInt()};
  }

  @override
  Future<List<String>> distinctWho() async => [
        for (final who
            in jsonArray(await _send(AccessMethods.auditDistinctWho, const {})))
          '$who',
      ];
}

/// [BackendConfigApi] over the pipe.
final class ClientBackendConfigApi implements BackendConfigApi {
  ClientBackendConfigApi(this._call);

  final RemoteCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      withAccessErrors(() => _call(method, params));

  @override
  Future<BackendConfigDocument> read() async => BackendConfigDocument.fromJson(
      jsonObject(await _send(AccessMethods.configRead, const {})));

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      ConfigValidation.fromJson(jsonObject(await _send(
          AccessMethods.configValidate, {'configJson': configJson})));

  @override
  Future<void> write(String configJson, {String? reason}) async =>
      await _send(AccessMethods.configWrite,
          {'configJson': configJson, 'reason': reason});

  /// Null survives as null: "nothing has been overwritten yet" is a different
  /// fact from an empty document, and the restore button greys on the first.
  @override
  Future<BackendConfigDocument?> previous() async {
    final raw = await _send(AccessMethods.configPrevious, const {});
    return raw == null ? null : BackendConfigDocument.fromJson(jsonObject(raw));
  }

  @override
  Future<void> restorePrevious({String? reason}) async =>
      await _send(AccessMethods.configRestorePrevious, {'reason': reason});
}
