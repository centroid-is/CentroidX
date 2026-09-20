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
      // Microseconds, and straight off the row: this value comes back as
      // the next page's cursor, and the store's `(at, id)` equality half
      // cannot match a rounded instant.
      oldestAtUs: page.oldestAt?.microsecondsSinceEpoch,
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
  /// **A kind this build does not know is REFUSED, not dropped.**
  ///
  /// The first version dropped it, on the reasoning that a narrowed filter
  /// shows the client more rows rather than fewer and that widening cannot
  /// hide anything. Both halves were wrong. `ConfigChangeQuery.kinds` is
  /// typed on the enum and an empty list means **no kind constraint at all**,
  /// so dropping the only selected name does not narrow the filter — it
  /// removes it, and the client gets the entire unfiltered log rendered under
  /// a chip it thinks is selective. Measured: a query for one unknown kind
  /// returned every row in the table, where the same query on a station would
  /// have returned that kind's rows or none. And the claim that "the client
  /// can still tell what it got" was false — nothing on the wire said the
  /// filter had been dropped.
  ///
  /// A panel one build ahead of its gateway is the ordinary case during a
  /// rollout, so this has to be a refusal the client can read rather than an
  /// answer it cannot distinguish from a real one.
  /// An instant off the wire, as a **local** `DateTime`.
  ///
  /// ## Why `.toLocal()`, and why it is not cosmetic
  ///
  /// `ConfigChangeStore.changesPage` compares `at` **as text**, because drift
  /// compares two `Expression<DateTime>` through `julianday()` — a SQLite
  /// function Postgres does not have — and the bound is rendered by the
  /// database's own type mapping so that it matches what was written byte for
  /// byte. That works only while both sides are rendered the same way, and
  /// drift renders a UTC `DateTime` as `…Z` and a local one as `… +hh:mm`.
  ///
  /// `config_change.at` is written by `DateTime.now()` — **local**. A bound
  /// built `isUtc: true` therefore compared `…Z` against `… +00:00`, and
  /// those do not sort against each other. Measured, on the real store: under
  /// a UTC clock the Load-more cursor returned the same page forever; under
  /// Europe/Copenhagen the second page came back empty and the default
  /// seven-day window answered **zero rows for changes made seconds earlier**
  /// — a relayed panel telling an engineer nothing had been changed all
  /// afternoon.
  ///
  /// The instant is unchanged by this; only its rendering is. The residual is
  /// the store's own, stated in its comment and not created here: the text
  /// comparison holds while every row carries the same offset, which is true
  /// of a plant whose stations share a timezone and would need `at`
  /// normalised to UTC on write to hold by construction.
  static DateTime _instant(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds).toLocal();

  static ConfigChangeQuery _toQuery(relay.ConfigHistoryQueryParams params) {
    final startMs = params.startMs;
    final endMs = params.endMs;
    final beforeUs = params.beforeUs;
    return ConfigChangeQuery(
      window: startMs == null || endMs == null
          ? null
          : AuditWindow(
              start: _instant(startMs * 1000),
              end: _instant(endMs * 1000),
            ),
      before: beforeUs == null ? null : _instant(beforeUs),
      beforeId: params.beforeId,
      entityPrefix: params.entityPrefix,
      who: params.who,
      kinds: _kinds(params.kindWireNames),
      scopeWireNames: params.scopeWireNames,
      // Clamped at both ends. A negative limit reached the store's `sublist`
      // and came back as an internal error; an unbounded one pulled the whole
      // table — and `config_change` is retention-exempt and carries the full
      // before/after payload of every page and asset, so one frame could be
      // the plant's entire configuration history. The cap is the store's own
      // row limit, which is what a station is held to.
      limit: params.limit.clamp(1, kConfigChangeRowLimit),
    );
  }

  /// The selected kinds, or a refusal naming the ones this build cannot.
  static List<ConfigKind> _kinds(List<String> wireNames) {
    final kinds = <ConfigKind>[];
    final unknown = <String>[];
    for (final name in wireNames) {
      final kind = ConfigKind.byWireName(name);
      if (kind == null) {
        unknown.add(name);
      } else {
        kinds.add(kind);
      }
    }
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(
          unknown.join(', '),
          'kindWireNames',
          'this gateway does not know these configuration kinds, and an '
              'unknown kind cannot be filtered on: an empty kind list means '
              '"every kind", so dropping them would answer the whole log '
              'under a chip the panel believes is selective. The panel is '
              'newer than the gateway — upgrade the gateway, or deselect '
              'the kind');
    }
    return kinds;
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
