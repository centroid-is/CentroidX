/// The saved history views of a gateway-mode panel: served over the pipe.
///
/// ## The gap this closes
///
/// `savedViewsProvider` was `if (dbWrap == null) return []`, over a
/// `databaseProvider` that answers **null by design** on a gateway panel. So a
/// panel whose backend held a dozen curated views showed an empty picker —
/// every time, silently, with no error, no badge and no line on stderr. It is
/// character for character the `getRecentAlarms` defect
/// `lib/core/relay_alarm_source.dart` documents at length, on the next surface
/// along, and it is the failure class this milestone exists to remove: **an
/// empty answer presented as a fact.**
///
/// The wire has carried all eleven history-view methods since Phase 10 plan 04
/// (`DataServiceMethods.historyViewMethods`). Nothing in the app called them.
///
/// ## Why the seam is `HistoryViewApi` and not `HistoryViewStore`
///
/// The page makes five writes and six reads. Until now the writes went through
/// `HistoryViewStore` (the local guard, `lib/core/guarded_history_views.dart`)
/// and the reads went straight to Drift through `dbWrap.db`, which is exactly
/// why a grep for one never found the other and why the reads were still
/// database-shaped when the writes had been fixed.
///
/// `tfc_relay_protocol`'s `HistoryViewApi` already declares all eleven, with
/// the working code's names and semantics, in types that cross a socket. Both
/// transports implement it, the page holds one, and neither the page nor a
/// future reader can route half the surface one way and half the other.
///
/// ## Server-side gating, and where the check is
///
/// **Direct mode**: [GuardedDatabaseHistoryViews] delegates its five writes to
/// [HistoryViewStore], which asks `AccessPolicy.groupForHistoryView` and writes
/// the audit row. Unchanged, deliberately.
///
/// **Gateway mode**: [RelayedHistoryViews] performs **no check at all**. The
/// gateway's `PolicyStateMan._PolicyHistoryViews` asks the same
/// `AccessPolicy.groupForHistoryView` — the one master policy, which
/// `packages/tfc_relay_server` reaches through `tfc_access` — refuses with
/// `forbidden`, and writes the deny row before it throws
/// (`policy_state_man.dart:928`, pinned by that package's `policy_test.dart`).
/// Authorisation is enforced server-side; a second check here would be a second
/// policy, which `test/core/no_second_policy_test.dart` exists to refuse.
///
/// ## The one thing this file adds: the refusal becomes a type again
///
/// `RemoteStateMan`'s data-service calls do **not** go through the client's
/// `withAccessErrors` — that wrapper is applied inside the four *access*
/// proxies only (`client_sub_apis.dart`), and `_dataServiceCall` is a plain
/// request. So a `forbidden` on a history-view write arrives as a bare
/// `RpcException`, which falls straight through the page's five
/// `on AccessDenied` catches — and the page then carries on to `setState`,
/// invalidate the picker and toast "Deleted" for a delete that did not happen.
///
/// [RelayedHistoryViews] is where that payload becomes a type again, the way
/// `relayed_access_stores.dart` does it for the access families. See
/// [_denialFor] for where the group in the exception comes from and why
/// reading it out of the policy is not a second check.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart' as drift;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' hide PreferencesApi;

import 'guarded_history_views.dart';

/// The gateway's `ServerErrorCodes.forbidden` (`error_codes.dart`).
///
/// Declared here rather than imported, for `client_sub_apis.dart`'s reason: the
/// number is the contract, and the app may not reach into the server package.
/// `test/providers/gateway_data_route_test.dart` drives it verbatim from the
/// far side of the same boundary.
const int kGatewayForbidden = -32005;

/// The policy every group answer in this file comes from — the same `const`
/// instance and the same method `guarded_history_views.dart` asks.
const AccessPolicy _policy = AccessPolicy();

/// An [AccessDenied] the **gateway** decided, re-raised with its own sentence.
///
/// The type is the contract, so `on AccessDenied` at the page's five writes
/// catches a relayed refusal exactly as it catches a direct one. The message is
/// the operator's half: the gateway's `forbidden` says the call definitively
/// had no effect and must not be retried, and a re-raise that rebuilt the
/// sentence from `itemKey` + `required` alone would drop that wording on
/// exactly the transport where a retry is most tempting. The same
/// narrowing-without-loss shape as the client's own `RemoteAccessDenied`,
/// which is not exported from its barrel.
final class RelayedHistoryViewDenied extends AccessDenied {
  const RelayedHistoryViewDenied(super.itemKey, super.required, this.message);

  /// The gateway's own words, carried because they are the useful half.
  final String message;

  @override
  String toString() => message;
}

/// [HistoryViewApi] over the relay.
///
/// A translation and nothing more. No cache, no retry, and **no fallback to a
/// database** — a route that exists will be taken, and the local one must not
/// exist here.
final class RelayedHistoryViews implements HistoryViewApi {
  RelayedHistoryViews({
    required HistoryViewApi api,
    void Function(AccessDenied denial)? onDenied,
  })  : _api = api,
        _onDenied = onDenied;

  final HistoryViewApi _api;

  /// Fired **before** the [AccessDenied] is thrown, exactly as
  /// [HistoryViewStore] fires it, so the shared prompt
  /// (`lib/widgets/access_denied_prompt.dart`) appears on either transport —
  /// including at the page's five call sites, every one of which swallows the
  /// exception and returns.
  final void Function(AccessDenied denial)? _onDenied;

  /// Runs [send], turning a gateway `forbidden` into the exception the page
  /// already catches. Everything else propagates untouched: a `handlerFailed`
  /// is "the backend could not", which is not an authorisation verdict and must
  /// stay distinguishable from one.
  Future<T> _guarded<T>(String member, Object itemId,
      Future<T> Function() send) async {
    try {
      return await send();
    } on rpc.RpcException catch (error) {
      if (error.code != kGatewayForbidden) rethrow;
      final denial = _denialFor(member, itemId, error.message);
      _onDenied?.call(denial);
      throw denial;
    }
  }

  /// The refusal, as a type.
  ///
  /// **The verdict is the gateway's; only the vocabulary is local.** The wire's
  /// refusal payload is `{method, request}` (`substitutedRequest`) — it carries
  /// no `itemKey` and no group, deliberately, because echoing a request that
  /// may hold a non-finite number is what makes the error itself unencodable.
  /// So the two fields `AccessDenied` needs are rebuilt here from what this
  /// side already knows: which member was called, and what
  /// `AccessPolicy.groupForHistoryView` says that member needs.
  ///
  /// Asking the policy here is **not** a second check. Nothing branches on the
  /// answer — the call has already been refused, at the far end, by the same
  /// method — and this is the label the prompt puts in front of the operator.
  /// A hard-coded group here would be the second policy; a lookup in the one
  /// policy is the same answer, spelled once.
  ///
  /// The `?? AccessGroup.configure` fallback is for a member the gateway
  /// refused that this build's policy calls open — a backend graded stricter
  /// than the panel. Naming a group the operator can go and obtain beats
  /// crashing on a null, and `configure` is what the two destructive members
  /// already require.
  static AccessDenied _denialFor(
          String member, Object itemId, String message) =>
      RelayedHistoryViewDenied(
        '$member:$itemId',
        _policy.groupForHistoryView(member) ?? AccessGroup.configure,
        message,
      );

  @override
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) =>
      _guarded(AccessPolicy.historyViewCreate, name,
          () => _api.createHistoryView(name, keys, keyConfigs, graphConfigs));

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) =>
      _guarded(
          AccessPolicy.historyViewUpdate,
          id,
          () =>
              _api.updateHistoryView(id, name, keys, keyConfigs, graphConfigs));

  @override
  Future<void> deleteHistoryView(int id) => _guarded(
      AccessPolicy.historyViewDelete, id, () => _api.deleteHistoryView(id));

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) =>
      _guarded(AccessPolicy.historyViewAddPeriod, viewId,
          () => _api.addHistoryViewPeriod(viewId, name, start, end));

  @override
  Future<void> deleteHistoryViewPeriod(int id) => _guarded(
      AccessPolicy.historyViewDeletePeriod,
      id,
      () => _api.deleteHistoryViewPeriod(id));

  // The six reads. Ungated on both transports — spec §11 defers read
  // permissions on trends and history, and reading last night's shift is
  // operate-level work. They are **not** wrapped: there is no `forbidden` to
  // translate on a read, and wrapping one would invite a future edit to
  // swallow a `handlerFailed` alongside it. A failed read throws, and the
  // provider above lets it.

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() =>
      _api.selectHistoryViews();

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(int viewId) =>
      _api.getHistoryViewKeys(viewId);

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(int viewId) =>
      _api.getHistoryViewGraphs(viewId);

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) =>
      _api.getHistoryViewKeyNames(viewId);

  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(int viewId) =>
      _api.listHistoryViewPeriods(viewId);

  @override
  Future<DateTime?> getGlobalRetentionHorizon() =>
      _api.getGlobalRetentionHorizon();
}

/// [HistoryViewApi] over this station's own database — direct mode.
///
/// The five writes go through [HistoryViewStore], which is where the check and
/// the audit row live and where they have lived since plan 03-10; nothing about
/// that changed. What this class adds is the six reads in the same object and
/// in the same vocabulary, so the page holds one thing instead of a guarded
/// store plus a raw `AppDatabase` handle.
///
/// **No ceiling.** `BackendHistoryViews` in `tfc_dart` does the same drift-row
/// mapping and would have been the shorter route, but it refuses a read past
/// `maxRows` — a gateway-side protection against a client growing rows in a
/// loop, and a behaviour change on a direct station, which must stay exactly as
/// it is.
final class GuardedDatabaseHistoryViews implements HistoryViewApi {
  const GuardedDatabaseHistoryViews({
    required drift.AppDatabase database,
    required HistoryViewStore store,
  })  : _db = database,
        _store = store;

  /// Reads only. The five writes are [_store]'s, and a read handle must not be
  /// able to borrow its way into one — `guarded_history_views.dart`'s rule.
  final drift.AppDatabase _db;

  final HistoryViewStore _store;

  // --------------------------------------------------------------- the writes

  @override
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) =>
      _store.createHistoryView(
          name, keys, _keyConfigRows(keyConfigs), _graphConfigRows(graphConfigs));

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
          [Map<String, HistoryViewKeyRecord>? keyConfigs,
          Map<int, HistoryViewGraphRecord>? graphConfigs]) =>
      _store.updateHistoryView(id, name, keys, _keyConfigRows(keyConfigs),
          _graphConfigRows(graphConfigs));

  @override
  Future<void> deleteHistoryView(int id) => _store.deleteHistoryView(id);

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) =>
      _store.addHistoryViewPeriod(viewId, name, start, end);

  @override
  Future<void> deleteHistoryViewPeriod(int id) =>
      _store.deleteHistoryViewPeriod(id);

  // ---------------------------------------------------------------- the reads

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() async => [
        for (final row in await _db.selectHistoryViews())
          HistoryViewRecord(
            id: row.id,
            name: row.name,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
          ),
      ];

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(
      int viewId) async {
    final rows = await _db.getHistoryViewKeys(viewId);
    return {
      for (final entry in rows.entries)
        entry.key: HistoryViewKeyRecord(
          key: entry.value['key'] as String? ?? entry.key,
          alias: entry.value['alias'] as String?,
          useSecondYAxis: entry.value['useSecondYAxis'] as bool? ?? false,
          graphIndex: (entry.value['graphIndex'] as num?)?.toInt() ?? 0,
        ),
    };
  }

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(
      int viewId) async {
    final rows = await _db.getHistoryViewGraphs(viewId);
    return {
      for (final entry in rows.entries)
        entry.key: HistoryViewGraphRecord(
          graphIndex: entry.key,
          name: entry.value['name'] as String? ?? '',
          yAxisUnit: entry.value['yAxisUnit'] as String? ?? '',
          yAxis2Unit: entry.value['yAxis2Unit'] as String? ?? '',
        ),
    };
  }

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) =>
      _db.getHistoryViewKeyNames(viewId);

  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(
          int viewId) async =>
      [
        for (final row in await _db.listHistoryViewPeriods(viewId))
          HistoryViewPeriodRecord(
            id: row.id,
            viewId: row.viewId,
            name: row.name,
            startAt: row.startAt,
            endAt: row.endAt,
            createdAt: row.createdAt,
          ),
      ];

  @override
  Future<DateTime?> getGlobalRetentionHorizon() =>
      _db.getGlobalRetentionHorizon();

  // --------------------------------------------------------- record → db row
  //
  // `AppDatabase`'s two write members take untyped `Map<String, dynamic>`
  // bags, and the graph one keys them by a **String** it parses with
  // `int.tryParse` — silently skipping an entry that will not parse
  // (`database_drift.dart:610`, and `:655` on the update path). A view that
  // saved four graphs would come back with three and nothing would say so.
  //
  // That drop is unreachable through here for the same reason it is
  // unreachable through the gateway: the typed record's `graphIndex` is an
  // `int`, so the key this writes always parses. Do not "simplify" these two
  // functions away by handing the page's raw maps straight down.

  static Map<String, Map<String, dynamic>>? _keyConfigRows(
          Map<String, HistoryViewKeyRecord>? configs) =>
      configs == null
          ? null
          : {
              for (final entry in configs.entries)
                entry.key: {
                  'alias': entry.value.alias,
                  'useSecondYAxis': entry.value.useSecondYAxis,
                  'graphIndex': entry.value.graphIndex,
                },
            };

  static Map<String, Map<String, dynamic>>? _graphConfigRows(
          Map<int, HistoryViewGraphRecord>? configs) =>
      configs == null
          ? null
          : {
              for (final entry in configs.entries)
                '${entry.key}': {
                  'name': entry.value.name,
                  'yAxisUnit': entry.value.yAxisUnit,
                  'yAxis2Unit': entry.value.yAxis2Unit,
                },
            };
}
