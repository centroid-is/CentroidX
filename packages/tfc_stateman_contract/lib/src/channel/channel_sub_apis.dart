/// The four data-service sub-APIs, forwarded over the channel.
///
/// Browse, timeseries, history views and preferences: thirty-four methods that
/// are, with two exceptions, pure translation. Each class holds one function —
/// the caller's `sendRequest`, already bound to a peer — and every method is
/// one message out and one back. There is deliberately no shared `call(method,
/// args)` entry point and no dispatch on a caller-supplied string: the set of
/// things reachable across this boundary has to stay a list a person can read
/// (T-02-22), which is what `HarnessMethods.dataServices` is and what
/// `test/channel/channel_sub_apis_test.dart` counts against the interfaces
/// themselves.
///
/// ## The two things that are not translation
///
/// **`TimeseriesData.fromJson` takes a value parser, and the wrong one is
/// silently lossy.** Its default coercion is driven by the type argument: with
/// no argument at all the samples come back as whatever `jsonDecode` produced,
/// so an integral double lands as an `int` and a chart's arithmetic changes
/// underneath it. Everything here decodes as [TimeseriesData]`<num>`, which is
/// the element type the contract seeds
/// (`data_services_contract.dart:112-115`) and the widest one the JSON number
/// grammar can carry losslessly. A series whose elements are not numbers —
/// packed structures, byte strings — cannot cross this lever, and that is
/// recorded rather than papered over: `TimeseriesData.fromJson` takes a
/// `decode` callback for exactly that case, and the day a source needs one,
/// the parser has to be agreed at both ends rather than defaulted at one.
///
/// **A preference change is one notification, fanned out locally.** The served
/// side subscribes to `onPreferencesChanged` once and pushes each key outward;
/// [ChannelPreferencesApi] holds a single broadcast controller and every local
/// listener reads from it. The contract's case takes *two* listeners
/// (`data_services_contract.dart:467-516`) because DB-03 is about a settings
/// page and a chart legend both hearing the same edit, and a subscription per
/// listener would make the number of messages on the wire depend on how many
/// widgets happen to be open — which is the shape of thing that works in a test
/// and falls over on a panel with thirty of them.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'rpc_names.dart';

/// One request over the channel: a method name, its parameters, its answer.
///
/// A function rather than the peer itself, so these four classes cannot reach
/// anything on it the value path has not already decided to expose — and so a
/// test can drive one of them without a channel at all.
typedef ChannelCall = Future<Object?> Function(
    String method, Map<String, Object?> params);

/// A type mismatch that happened on the far side, re-raised as the type the
/// interface promises.
///
/// `PreferencesApi`'s typed getters "throw a `TypeError` when the stored value
/// is of another type" (`preferences_api.dart:30-36`), and that is part of the
/// interface being mirrored rather than an incident: a settings page catching
/// `TypeError` around a `getInt` is porting code that already does. The cast
/// itself necessarily happens where the value is stored, so what crosses the
/// channel is a JSON-RPC error; this is what it becomes on the way out, so a
/// caller sees the same type from the same call it would have seen in process.
///
/// A subclass rather than a provoked cast failure, because the message is the
/// useful half — `type 'String' is not a subtype of type 'int'` names the key's
/// actual contents, and a synthetic cast would replace it with a sentence about
/// this file.
final class ChannelTypeError extends TypeError {
  ChannelTypeError(this.message);

  /// The far side's own description of the mismatch.
  final String message;

  @override
  String toString() => message;
}

/// Runs [send], turning the far side's type mismatch back into a [TypeError].
Future<Object?> withTypedErrors(Future<Object?> Function() send) async {
  try {
    return await send();
  } on rpc.RpcException catch (error) {
    if (error.code != HarnessErrorCodes.typeMismatch) rethrow;
    throw ChannelTypeError(error.message);
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
/// Milliseconds and not microseconds because that is the precision every
/// record in `history_view.dart` and `timeseries.dart` already encodes at, and
/// a second convention would make two timestamps that are `==` in Dart compare
/// unequal after a round trip.
int msOf(DateTime time) => time.millisecondsSinceEpoch;

/// The inverse of [msOf], always UTC.
DateTime timeOf(Object? raw) =>
    DateTime.fromMillisecondsSinceEpoch((raw as num).toInt(), isUtc: true);

// ------------------------------------------------------------------- browse

/// [BrowseApi] over the channel.
///
/// `fetchChildren` and `fetchDetail` send the whole node rather than its id,
/// which is not redundancy: the interface takes a `BrowseNode`, and an OPC UA
/// source addressing a node needs its namespace — carried in `metadata` — as
/// well as its identifier. Sending the id alone would work against the
/// reference implementation and fail against the first real one.
final class ChannelBrowseApi implements BrowseApi {
  ChannelBrowseApi(this._call);

  final ChannelCall _call;

  @override
  Future<List<BrowseNode>> fetchRoots() async => _nodes(
      await _call(HarnessMethods.browseFetchRoots, const {}));

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async => _nodes(
      await _call(
          HarnessMethods.browseFetchChildren, {'parent': parent.toJson()}));

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async =>
      BrowseNodeDetail.fromJson(jsonObject(await _call(
          HarnessMethods.browseFetchDetail, {'node': node.toJson()})));

  /// Null stays null, and never becomes an empty list.
  ///
  /// The two are different facts: null is "this source cannot resolve that
  /// target", which is what a page saved against a since-renamed tag hits, and
  /// an empty list would be "the chain to it is zero nodes long". The panel
  /// opens unpositioned on the first and asserts on the second.
  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    final raw =
        await _call(HarnessMethods.browseResolvePath, {'targetId': targetId});
    return raw == null ? null : _nodes(raw);
  }

  static List<BrowseNode> _nodes(Object? raw) => [
        for (final node in jsonArray(raw)) BrowseNode.fromJson(jsonObject(node)),
      ];
}

// --------------------------------------------------------------- timeseries

/// [TimeseriesApi] over the channel.
final class ChannelTimeseriesApi implements TimeseriesApi {
  ChannelTimeseriesApi(this._call);

  final ChannelCall _call;

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      points(await _call(HarnessMethods.timeseriesQuery, {
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
    final raw = jsonObject(await _call(HarnessMethods.timeseriesQueryMultiple, {
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
      points(await _call(HarnessMethods.timeseriesQueryDownsampled, {
        'table': tableName,
        'from': msOf(from),
        'to': msOf(to),
        'maxPoints': maxPoints,
      }));

  /// Samples decoded as `num`, which is the parser question this file's
  /// header is about.
  static List<TimeseriesData> points(Object? raw) => [
        for (final point in jsonArray(raw))
          TimeseriesData<num>.fromJson(jsonObject(point)),
      ];
}

// ------------------------------------------------------------ history views

/// [HistoryViewApi] over the channel.
///
/// The optional positional configuration maps stay optional and positional,
/// matching the call sites being ported. Absent and empty are kept apart on the
/// wire — `null` means "do not change what is configured", `{}` means "there is
/// none" — because `updateHistoryView` is the method a caller uses for both.
final class ChannelHistoryViewApi implements HistoryViewApi {
  ChannelHistoryViewApi(this._call);

  final ChannelCall _call;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) async =>
      (await _call(HarnessMethods.historyCreateView, {
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
      await _call(HarnessMethods.historyUpdateView, {
        'id': id,
        'name': name,
        'keys': keys,
        'keyConfigs': _keyConfigs(keyConfigs),
        'graphConfigs':
            graphConfigs == null ? null : historyViewGraphsToJson(graphConfigs),
      });

  @override
  Future<void> deleteHistoryView(int id) async =>
      await _call(HarnessMethods.historyDeleteView, {'id': id});

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() async => [
        for (final view
            in jsonArray(await _call(HarnessMethods.historySelectViews, const {})))
          HistoryViewRecord.fromJson(jsonObject(view)),
      ];

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(
      int viewId) async {
    final raw = jsonObject(
        await _call(HarnessMethods.historyGetKeys, {'viewId': viewId}));
    return {
      for (final entry in raw.entries)
        entry.key: HistoryViewKeyRecord.fromJson(jsonObject(entry.value)),
    };
  }

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(
          int viewId) async =>
      historyViewGraphsFromJson(
          await _call(HarnessMethods.historyGetGraphs, {'viewId': viewId}));

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async => [
        for (final name in jsonArray(
            await _call(HarnessMethods.historyGetKeyNames, {'viewId': viewId})))
          '$name',
      ];

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) async =>
      (await _call(HarnessMethods.historyAddPeriod, {
        'viewId': viewId,
        'name': name,
        'start': msOf(start),
        'end': msOf(end),
      }) as num)
          .toInt();

  @override
  Future<void> deleteHistoryViewPeriod(int id) async =>
      await _call(HarnessMethods.historyDeletePeriod, {'id': id});

  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(
          int viewId) async =>
      [
        for (final period in jsonArray(await _call(
            HarnessMethods.historyListPeriods, {'viewId': viewId})))
          HistoryViewPeriodRecord.fromJson(jsonObject(period)),
      ];

  /// Null survives as null.
  ///
  /// "Nothing has been discarded yet" and "everything since the epoch is gone"
  /// are opposite answers, and a chart scrolling past the horizon has to tell
  /// an operator which of them it is looking at.
  @override
  Future<DateTime?> getGlobalRetentionHorizon() async {
    final raw = await _call(HarnessMethods.historyRetentionHorizon, const {});
    return raw == null ? null : timeOf(raw);
  }

  static Map<String, Object?>? _keyConfigs(
          Map<String, HistoryViewKeyRecord>? configs) =>
      configs == null
          ? null
          : {
              for (final entry in configs.entries) entry.key: entry.value.toJson(),
            };
}

// ------------------------------------------------------------- preferences

/// [PreferencesApi] over the channel, change stream included.
///
/// The typed getters cast on **this** side, on a value that has been through
/// JSON, and that placement is deliberate. It catches both mismatches with one
/// mechanism: a store holding the wrong type (the far side raises, and
/// [withTypedErrors] re-raises it here as the `TypeError` the interface
/// promises) and a wire that drifted (`getInt` handed a JSON string arrives as
/// a `TypeError` too, rather than as an `int?` that is secretly a `String`
/// waiting to fail somewhere with no context).
final class ChannelPreferencesApi implements PreferencesApi {
  ChannelPreferencesApi(this._call);

  final ChannelCall _call;

  /// Broadcast, because the contract's case has two listeners and DB-03's
  /// reason for existing is that a settings page and a chart legend both want
  /// this. One controller for however many listeners: the fan-out is local, and
  /// the wire carries one notification per change regardless.
  final _changes = StreamController<String>.broadcast();

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  /// Feeds one inbound change to every local listener.
  ///
  /// Called by `ChannelStateMan` from the notification handler; nothing else
  /// may add to this stream, which is what keeps "every change this reports
  /// arrived over the channel" true rather than approximately true.
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
            HarnessMethods.prefGetKeys, {'allowList': allowList?.toList()})))
          '$key',
      };

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async =>
      jsonObject(await _call(
          HarnessMethods.prefGetAll, {'allowList': allowList?.toList()}));

  @override
  Future<bool?> getBool(String key) async =>
      await _get(HarnessMethods.prefGetBool, key) as bool?;

  @override
  Future<int?> getInt(String key) async =>
      await _get(HarnessMethods.prefGetInt, key) as int?;

  @override
  Future<double?> getDouble(String key) async =>
      await _get(HarnessMethods.prefGetDouble, key) as double?;

  @override
  Future<String?> getString(String key) async =>
      await _get(HarnessMethods.prefGetString, key) as String?;

  /// A fresh `List<String>`, element by element.
  ///
  /// `jsonDecode` produces a `List<dynamic>`, so a plain cast would succeed and
  /// hand back a list that throws on its first read; `List<String>.from` casts
  /// each element now, where the failure can still say which call it came from.
  @override
  Future<List<String>?> getStringList(String key) async {
    final raw = await _get(HarnessMethods.prefGetStringList, key);
    return raw == null ? null : List<String>.from(raw as List);
  }

  @override
  Future<bool> containsKey(String key) async =>
      await _call(HarnessMethods.prefContainsKey, {'key': key}) as bool;

  @override
  Future<void> setBool(String key, bool value) async =>
      await _set(HarnessMethods.prefSetBool, key, value);

  @override
  Future<void> setInt(String key, int value) async =>
      await _set(HarnessMethods.prefSetInt, key, value);

  @override
  Future<void> setDouble(String key, double value) async =>
      await _set(HarnessMethods.prefSetDouble, key, value);

  @override
  Future<void> setString(String key, String value) async =>
      await _set(HarnessMethods.prefSetString, key, value);

  @override
  Future<void> setStringList(String key, List<String> value) async =>
      await _set(HarnessMethods.prefSetStringList, key, value);

  @override
  Future<void> remove(String key) async =>
      await _call(HarnessMethods.prefRemove, {'key': key});

  @override
  Future<void> clear({Set<String>? allowList}) async =>
      await _call(HarnessMethods.prefClear, {'allowList': allowList?.toList()});

  Future<Object?> _get(String method, String key) =>
      withTypedErrors(() => _call(method, {'key': key}));

  Future<void> _set(String method, String key, Object? value) async =>
      await _call(method, {'key': key, 'value': value});
}

// -----------------------------------------------------------------------------
// The four access families, over the channel
// -----------------------------------------------------------------------------
//
// A deliberate, method-for-method copy of the client half — the same
// duplication `data_handlers.dart`'s library doc defends: the gateway may not
// import this kit at runtime (`handler_table_test.dart` requires this package's
// name to appear zero times in the server's production lib/), so the channel
// forwards rather than shares. The copy is the control.
//
// One thing is NOT ported: the refusal shape. The harness peer forwards
// whatever the underlying implementation throws — it does not mint its own
// `forbidden`. A refusal that was refused server-side comes back as
// [HarnessErrorCodes.accessForbidden] and is re-raised HERE as the same
// [AccessDenied] the in-memory leg throws, carrying the same item key and
// required group — so a refusal is one exception type on both legs (D-09). If
// the peer minted its own refusal, the channel leg would pass the suite's
// negative arms against an implementation with no gate at all;
// `test/channel/channel_access_test.dart` asserts the shape is the same on both
// legs.

/// Re-raises an [AccessDenied] that was refused on the far side, so a refusal is
/// the same type over the channel as in memory. Every other RpcException — the
/// domain refusals travelling as [HarnessErrorCodes.subApiFailed] — propagates
/// unchanged, which is what keeps them distinguishable from an authorisation
/// verdict.
Future<Object?> _withAccessErrors(Future<Object?> Function() send) async {
  try {
    return await send();
  } on rpc.RpcException catch (error) {
    if (error.code != HarnessErrorCodes.accessForbidden) rethrow;
    final data = error.data;
    final itemKey =
        (data is Map ? data['itemKey'] : null)?.toString() ?? 'unknown';
    final groupName = data is Map ? data['group']?.toString() : null;
    final group = (groupName == null ? null : AccessGroup.byName(groupName)) ??
        AccessGroup.users;
    throw AccessDenied(itemKey, group);
  }
}

/// [AccessTemplateApi] over the channel.
final class ChannelAccessTemplateApi implements AccessTemplateApi {
  ChannelAccessTemplateApi(this._call);

  final ChannelCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      _withAccessErrors(() => _call(method, params));

  @override
  Future<List<AccessTemplate>> list() async => [
        for (final row in jsonArray(
            await _send(HarnessMethods.accessTemplatesList, const {})))
          accessTemplateFromJson(jsonObject(row)),
      ];

  // No `template(name)` forwarder: the access audit cut the member from the
  // wire. A remote that wants one template derives it from [list] — same
  // snapshot semantics, zero wire names.

  @override
  Future<Map<String, String>> bindings() async {
    final raw = jsonObject(
        await _send(HarnessMethods.accessTemplatesBindings, const {}));
    return {for (final e in raw.entries) e.key: '${e.value}'};
  }

  @override
  Future<List<String>> keysBoundTo(String templateName) async => [
        for (final k in jsonArray(await _send(
            HarnessMethods.accessTemplatesKeysBoundTo,
            {'templateName': templateName})))
          '$k',
      ];

  @override
  Future<void> create(AccessTemplate value, {String? reason}) async =>
      await _send(HarnessMethods.accessTemplatesCreate,
          {'value': accessTemplateToJson(value), 'reason': reason});

  @override
  Future<void> update(AccessTemplate value, {String? reason}) async =>
      await _send(HarnessMethods.accessTemplatesUpdate,
          {'value': accessTemplateToJson(value), 'reason': reason});

  @override
  Future<void> rename(String from, String to, {String? reason}) async =>
      await _send(HarnessMethods.accessTemplatesRename,
          {'from': from, 'to': to, 'reason': reason});

  @override
  Future<void> delete(String name, {String? reason}) async => await _send(
      HarnessMethods.accessTemplatesDelete, {'name': name, 'reason': reason});

  @override
  Future<void> bind(String keyName, String templateName,
          {String? reason}) async =>
      await _send(HarnessMethods.accessTemplatesBind, {
        'keyName': keyName,
        'templateName': templateName,
        'reason': reason,
      });

  @override
  Future<void> unbind(String keyName, {String? reason}) async =>
      await _send(HarnessMethods.accessTemplatesUnbind,
          {'keyName': keyName, 'reason': reason});
}

/// [AccessAdminApi] over the channel.
final class ChannelAccessAdminApi implements AccessAdminApi {
  ChannelAccessAdminApi(this._call);

  final ChannelCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      _withAccessErrors(() => _call(method, params));

  @override
  Future<List<AccessRole>> roles() async => [
        for (final row
            in jsonArray(await _send(HarnessMethods.accessAdminRoles, const {})))
          accessRoleFromJson(jsonObject(row)),
      ];

  @override
  Future<List<UserSummary>> listUsers() async => [
        for (final row in jsonArray(
            await _send(HarnessMethods.accessAdminListUsers, const {})))
          userSummaryFromJson(jsonObject(row)),
      ];

  @override
  Future<void> createRole(AccessRole role, {String? reason}) async =>
      await _send(HarnessMethods.accessAdminCreateRole,
          {'role': accessRoleToJson(role), 'reason': reason});

  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async =>
      await _send(HarnessMethods.accessAdminUpdateRole,
          {'role': accessRoleToJson(role), 'reason': reason});

  @override
  Future<void> deleteRole(String name, {String? reason}) async => await _send(
      HarnessMethods.accessAdminDeleteRole, {'name': name, 'reason': reason});

  @override
  Future<void> renameRole(String from, String to, {String? reason}) async =>
      await _send(HarnessMethods.accessAdminRenameRole,
          {'from': from, 'to': to, 'reason': reason});

  @override
  Future<void> createUser(NewUserParams params) async =>
      await _send(HarnessMethods.accessAdminCreateUser, params.toJson());

  @override
  Future<void> deleteUser(String subject, {String? reason}) async =>
      await _send(HarnessMethods.accessAdminDeleteUser,
          {'subject': subject, 'reason': reason});

  @override
  Future<void> setUserRole(String subject, String newRole,
          {String? reason}) async =>
      await _send(HarnessMethods.accessAdminSetUserRole,
          {'subject': subject, 'newRole': newRole, 'reason': reason});

  @override
  Future<void> setUserStationAccount(String subject, bool value,
          {String? reason}) async =>
      await _send(HarnessMethods.accessAdminSetUserStationAccount,
          {'subject': subject, 'value': value, 'reason': reason});

  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async =>
      await _send(HarnessMethods.accessAdminSetUserPassword, params.toJson());
}

/// [AuditApi] over the channel — read-only, like the interface.
final class ChannelAuditApi implements AuditApi {
  ChannelAuditApi(this._call);

  final ChannelCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      _withAccessErrors(() => _call(method, params));

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) async => [
        for (final row in jsonArray(
            await _send(HarnessMethods.auditEntries, {'query': query.toJson()})))
          auditRecordFromJson(jsonObject(row)),
      ];

  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) async {
    final raw = jsonObject(await _send(
        HarnessMethods.auditMemberCounts, {'actionIds': actionIds}));
    return {for (final e in raw.entries) e.key: (e.value as num).toInt()};
  }

  @override
  Future<List<String>> distinctWho() async => [
        for (final w
            in jsonArray(await _send(HarnessMethods.auditDistinctWho, const {})))
          '$w',
      ];
}

/// [BackendConfigApi] over the channel.
final class ChannelBackendConfigApi implements BackendConfigApi {
  ChannelBackendConfigApi(this._call);

  final ChannelCall _call;

  Future<Object?> _send(String method, Map<String, Object?> params) =>
      _withAccessErrors(() => _call(method, params));

  @override
  Future<BackendConfigDocument> read() async => BackendConfigDocument.fromJson(
      jsonObject(await _send(HarnessMethods.configRead, const {})));

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      ConfigValidation.fromJson(jsonObject(await _send(
          HarnessMethods.configValidate, {'configJson': configJson})));

  @override
  Future<void> write(String configJson, {String? reason}) async =>
      await _send(HarnessMethods.configWrite,
          {'configJson': configJson, 'reason': reason});

  @override
  Future<BackendConfigDocument?> previous() async {
    final raw = await _send(HarnessMethods.configPrevious, const {});
    return raw == null ? null : BackendConfigDocument.fromJson(jsonObject(raw));
  }

  @override
  Future<void> restorePrevious({String? reason}) async =>
      await _send(HarnessMethods.configRestorePrevious, {'reason': reason});
}
