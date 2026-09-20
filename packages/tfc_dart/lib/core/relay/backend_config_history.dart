/// `ConfigHistoryApi` over [ConfigChangeStore] — the same reader the panel
/// calls in direct mode, serving the same rows over the socket.
///
/// ## Why this is a thin file
///
/// Every judgement the configuration history makes — the two-mode window, the
/// `(at, id)` cursor, the text datetime comparison Postgres needs, which rows
/// are decodable, what `rawCount` counts — lives in [ConfigChangeStore] and
/// stays there. This file maps the wire's query onto the store's and the
/// store's rows onto the wire's, and does nothing else. A second set of those
/// rules for the relayed transport is exactly the kind of drift that makes
/// two transports disagree about a page an engineer is reading in an outage.
///
/// That is also why the store had to move into this package first: the reader
/// used to live in the app, above the gateway, and the only ways to serve it
/// were to move it or to write it twice.
///
/// ## What is deliberately absent
///
/// **No write member.** The log is written by whoever changed the
/// configuration, through `ConfigStore`, and a client-supplied history row
/// would be the forgery surface the audit family refuses one for. Undo is not
/// an exception: it writes new configuration and the rows follow from that
/// write.
library;

import 'package:logger/logger.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../access/audit_trail_store.dart' show AuditWindow;
import '../config/config_change_store.dart';
import '../config/config_item.dart';
import '../database_drift.dart';

/// The refusal a backend composed without a database mints.
///
/// Never an empty page: "no configuration has ever been changed" and "nobody
/// wired a database" are indistinguishable from the screen, and the first is
/// a claim about the plant.
Never _missingDatabase(String member) => throw UnsupportedError(
    'BackendConfigHistory.$member is not available: this family was composed '
    'without the backend\'s AppDatabase, so there is no config_change to '
    'read — and an empty history is indistinguishable from a plant nobody '
    'has ever configured, which is the one wrong answer a read-only family '
    'can give. Hand the database to the relay composition.');

final class BackendConfigHistory implements relay.ConfigHistoryApi {
  BackendConfigHistory({required AppDatabase? database, Logger? logger})
      : _store = database == null
            ? null
            : ConfigChangeStore(db: database, logger: logger);

  final ConfigChangeStore? _store;

  ConfigChangeStore _require(String member) =>
      _store ?? _missingDatabase(member);

  /// `async` is load-bearing on every member here, not decoration.
  ///
  /// [_require] throws, and each member owes that refusal as a **rejected
  /// future** rather than a synchronous throw: a synchronous throw escapes
  /// `expectLater`'s matcher entirely, which is how the sibling family's
  /// refusal arm went quietly green once already.
  @override
  Future<relay.ConfigHistoryPageResult> changesPage(
      relay.ConfigHistoryQueryParams query) async {
    final page = await _require('changesPage').changesPage(_toQuery(query));
    return relay.ConfigHistoryPageResult(
      rows: [for (final row in page.rows) _toWire(row)],
      rawCount: page.rawCount,
      oldestAtMs: page.oldestAt?.toUtc().millisecondsSinceEpoch,
      oldestId: page.oldestId,
      hasMore: page.hasMore,
    );
  }

  @override
  Future<Map<String, List<relay.ConfigHistoryRow>>> changesByAction(
      List<String> actionIds) async {
    final byAction = await _require('changesByAction').changesByAction(actionIds);
    return <String, List<relay.ConfigHistoryRow>>{
      // An action nobody wrote stays ABSENT rather than becoming an empty
      // list — the store's own rule, and the difference between "this action
      // changed nothing" and "there is no such action".
      for (final entry in byAction.entries)
        entry.key: [for (final row in entry.value) _toWire(row)],
    };
  }

  @override
  Future<Map<String, int>> changeCountsByAction(List<String> actionIds) async =>
      _require('changeCountsByAction').changeCountsByAction(actionIds);

  /// The wire's query onto the store's.
  ///
  /// **A kind this build does not know is dropped, and that is the honest
  /// answer.** `ConfigChangeQuery.kinds` is typed on the enum, so an unknown
  /// name has nowhere to go. Dropping it narrows the filter to the kinds this
  /// backend can name, which shows the client MORE rows than it asked to see
  /// rather than fewer — the safe direction for a filter, and the one where
  /// the client can still tell what it got. Widening a filter cannot hide a
  /// row; narrowing one silently can.
  static ConfigChangeQuery _toQuery(relay.ConfigHistoryQueryParams params) {
    final startMs = params.startMs;
    final endMs = params.endMs;
    final beforeMs = params.beforeMs;
    return ConfigChangeQuery(
      window: startMs == null || endMs == null
          ? null
          : AuditWindow(
              start: DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true),
              end: DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true),
            ),
      before: beforeMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(beforeMs, isUtc: true),
      beforeId: params.beforeId,
      entityPrefix: params.entityPrefix,
      who: params.who,
      kinds: [
        for (final name in params.kindWireNames)
          if (ConfigKind.byWireName(name) case final kind?) kind,
      ],
      scopeWireNames: params.scopeWireNames,
      limit: params.limit,
    );
  }

  /// The store's decoded record onto the wire's flat row.
  ///
  /// The enums go back out as the `wireName` they were stored as, so the
  /// round trip is the column and not a translation of it.
  static relay.ConfigHistoryRow _toWire(ConfigChangeRecord record) {
    final change = record.change;
    return relay.ConfigHistoryRow(
      id: record.id,
      atMs: change.at.toUtc().millisecondsSinceEpoch,
      actionId: change.actionId,
      who: change.who,
      station: change.station,
      roleName: change.roleName,
      kind: change.kind.wireName,
      entityId: change.entityId,
      scope: change.scope.wireName,
      op: change.op.wireName,
      oldValue: change.oldValue,
      newValue: change.newValue,
      reason: change.reason,
    );
  }
}
