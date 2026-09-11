/// The process-level collection decision: on/off, namespace, sole-writer,
/// endpoint, pool, caps.
///
/// Pure data, in `GatewayConfig`'s style: nothing here reads a file, opens a
/// socket or starts a clock. The one thing the constructor does is **refuse**
/// — three refusals, in the style of the duplicate-alias refusal
/// (`gateway_config.dart`), each a message that names the field and the fix.
library;

import 'package:tfc_dart/tfc_dart.dart'
    show kMaxQueuedRowsPerTable, kMaxQueuedRowsTotal;

/// Where the gateway's historian writes: host, port, database, credentials.
///
/// Deliberately this package's own value type rather than `pg.Endpoint`: this
/// plan is pure code that needs no database to test, and the one file allowed
/// to import the database layer is 8b-02's sink adapter (freeze:
/// `freeze_test.dart`'s seam sweep). The adapter translates this into a
/// `DatabaseConfig` at the seam, once.
final class CollectionEndpoint {
  CollectionEndpoint({
    required this.host,
    this.port = 5432,
    this.database = 'hmi',
    this.username,
    this.password,
  }) {
    if (host.trim().isEmpty) {
      throw ArgumentError.value(host, 'host',
          'a collection endpoint with no host reaches the socket layer as a '
              'hostname lookup for the empty string, so the gateway fails '
              'with a DNS message instead of a configuration one');
    }
  }

  factory CollectionEndpoint.fromJson(Map<String, dynamic> json) =>
      CollectionEndpoint(
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 5432,
        database: json['database'] as String? ?? 'hmi',
        username: json['username'] as String?,
        password: json['password'] as String?,
      );

  final String host;
  final int port;
  final String database;
  final String? username;
  final String? password;

  /// [includeSecrets] carries `password` back out and **defaults to false**
  /// — `UpstreamLinkConfig.toJson`'s argument (08-REVIEW IN-05), applied to
  /// the one credential in this block that opens the plant's historian.
  Map<String, dynamic> toJson({bool includeSecrets = false}) =>
      <String, dynamic>{
        'host': host,
        'port': port,
        'database': database,
        if (username != null) 'username': username,
        if (password != null && includeSecrets) 'password': password,
      };

  @override
  bool operator ==(Object other) =>
      other is CollectionEndpoint &&
      other.host == host &&
      other.port == port &&
      other.database == database &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(host, port, database, username, password);
}

/// The SSL modes the sink adapter knows how to ask the driver for. A closed
/// list for the same reason `string_encoding.dart`'s is: a typo that silently
/// became `disable` would be a plant credential on the wire in clear, decided
/// by a misspelling.
const Set<String> collectionSslModes = <String>{
  'disable',
  'require',
  'verifyFull',
};

/// Whether the gateway historises at all, and under whose ownership.
///
/// ## The side-by-side argument, with the evidence
///
/// **The next person will want to delete the prefix. Read this first.**
/// ROADMAP Phase 8b requires the gateway's collection to be side-by-side safe
/// with the app's collector while both run, and that is a design problem
/// rather than a flag, on four facts:
///
///  1. The app's collector derives its table name from `entry.name ??
///     entry.key` (`collector.dart:215`, and `CollectEntry`'s constructor
///     sets `name ??= key` at `:50`) out of the **same** `collect` blocks
///     this gateway reads — so an unprefixed gateway picks byte-identical
///     table names.
///  2. The tables carry **no primary key and no unique index** —
///     `createTable` emits a plain `CREATE TABLE IF NOT EXISTS`
///     (`database_drift.dart:677-691`) and `create_hypertable(…, 'time')`
///     (`:907`) — so Postgres accepts a second writer without a murmur and
///     the row count simply doubles. Every count a panel shows doubles with
///     it, and nothing anywhere reports an error.
///  3. Retention is an **active fight**, not a passive one:
///     `registerRetentionPolicy` compares the stored policy and, on any
///     difference, calls `updateRetentionPolicy`, which runs
///     `remove_retention_policy` then `add_retention_policy`
///     (`database.dart:847-864`, `database_drift.dart:895-931`) — so two
///     collectors whose configs differ by one minute uninstall each other's
///     policy at every start.
///  4. Schema evolution types a column from whichever writer reaches it
///     first (`database.dart:1042-1082`), so two writers with two ideas of a
///     struct's shape fight over the table's columns and the loser's rows
///     are poisoned or coerced.
///
/// The `gw_` prefix keeps the two writers in two disjoint table namespaces,
/// which dissolves all four at once. An **empty** prefix is therefore refused
/// at construction unless [soleWriter] is also set — the only way for gateway
/// rows to reach the app's tables is a deliberate, two-field act.
///
/// ## The limit, honestly
///
/// The prefix protects against **the app's collector**, which cannot be asked
/// to cooperate: 08-CONTEXT ruling 3 keeps it running unchanged until app
/// integration cuts over. The advisory lock 8b-02 adds protects against a
/// **second gateway**, which can. Neither covers a third-party writer, and
/// nothing in this design pretends to.
///
/// ## The cutover procedure
///
///  1. Stop the app's collector on the collector station.
///  2. Set `soleWriter: true` in this block.
///  3. Set `tablePrefix: ''`.
///  4. Restart the gateway.
///
/// Migrating the `gw_`-prefixed history into the unprefixed tables is a
/// one-shot `INSERT INTO … SELECT` that belongs to the cutover, not to this
/// phase.
final class CollectionConfig {
  /// The one spelling of the default namespace prefix (8b-REVIEW IN-03).
  /// The constructor default and `fromJson`'s missing-field default were
  /// two independent literals; the freeze sweep counts files, not
  /// occurrences, so editing one and not the other would have passed it —
  /// and this default drifting means gateway rows in the app's tables with
  /// no error anywhere.
  static const String defaultTablePrefix = 'gw_';

  CollectionConfig({
    this.enabled = false,
    this.tablePrefix = defaultTablePrefix,
    this.soleWriter = false,
    this.endpoint,
    this.sslMode = 'disable',
    this.maxPoolConnections,
    this.connectTimeout = const Duration(seconds: 5),
    this.queryTimeout = const Duration(seconds: 30),
    this.maxQueuedRowsPerTable = kMaxQueuedRowsPerTable,
    this.maxQueuedRowsTotal = kMaxQueuedRowsTotal,
  }) {
    if (tablePrefix.isEmpty && !soleWriter) {
      throw ArgumentError(
          'tablePrefix is empty and soleWriter is not set. An empty prefix '
          'aims the gateway at the very tables the app\'s collector writes — '
          'same names, no primary key, so the row count doubles silently. '
          'Stop the app\'s collector on the collector station first, then set '
          'soleWriter: true alongside tablePrefix: "" to declare this gateway '
          'the sole writer');
    }
    if (_unsafePrefix(tablePrefix)) {
      throw ArgumentError.value(tablePrefix, 'tablePrefix',
          'reaches SQL by interpolation with the table identifier unescaped '
              '(database_drift.dart:687), so a quote, semicolon, backslash, '
              'control character or leading whitespace in it is a statement '
              'boundary, not a table name. Use letters, digits and '
              'underscores');
    }
    if (enabled && endpoint == null) {
      throw ArgumentError(
          'enabled is true but no endpoint is configured. A gateway told to '
          'collect with nowhere to write must not start and quietly not '
          'collect — name the Postgres endpoint in this block, or set '
          'enabled: false until there is one');
    }
    if (!collectionSslModes.contains(sslMode)) {
      throw ArgumentError.value(sslMode, 'sslMode',
          'unknown SSL mode. Known: ${collectionSslModes.join(', ')} — a '
              'typo that silently became disable would put the historian '
              'credential on the wire in clear');
    }
  }

  factory CollectionConfig.fromJson(Map<String, dynamic> json) {
    final endpoint = (json['endpoint'] as Map?)?.cast<String, dynamic>();
    return CollectionConfig(
      enabled: json['enabled'] as bool? ?? false,
      tablePrefix: json['table_prefix'] as String? ?? defaultTablePrefix,
      soleWriter: json['sole_writer'] as bool? ?? false,
      endpoint:
          endpoint == null ? null : CollectionEndpoint.fromJson(endpoint),
      sslMode: json['ssl_mode'] as String? ?? 'disable',
      maxPoolConnections: json['max_pool_connections'] as int?,
      connectTimeout:
          Duration(milliseconds: json['connect_timeout_ms'] as int? ?? 5000),
      queryTimeout:
          Duration(milliseconds: json['query_timeout_ms'] as int? ?? 30000),
      maxQueuedRowsPerTable: json['max_queued_rows_per_table'] as int? ??
          kMaxQueuedRowsPerTable,
      maxQueuedRowsTotal:
          json['max_queued_rows_total'] as int? ?? kMaxQueuedRowsTotal,
    );
  }

  /// Collecting is something an operator turns ON. A block that names an
  /// endpoint but does not say `enabled: true` collects nothing.
  final bool enabled;

  /// The namespace that keeps gateway rows out of the app's tables. `'gw_'`
  /// by default; the literal has exactly one spelling in this package and the
  /// freeze test pins it here.
  final String tablePrefix;

  /// The operator's declaration that the app's collector has been stopped and
  /// this gateway owns the tables alone. The only thing that makes an empty
  /// [tablePrefix] constructible.
  final bool soleWriter;

  /// Where to write, or null. Null with [enabled] true is refused.
  final CollectionEndpoint? endpoint;

  /// One of [collectionSslModes].
  final String sslMode;

  /// Connections the sink may pool, or null for one —
  /// `DatabaseConfig.maxPoolConnections`' meaning, unchanged.
  final int? maxPoolConnections;

  final Duration connectTimeout;
  final Duration queryTimeout;

  /// The two queue caps the sink passes through. Defaults are tfc_dart's own
  /// [kMaxQueuedRowsPerTable] / [kMaxQueuedRowsTotal], imported rather than
  /// re-spelled: both carry a sizing argument (`database.dart:242-277`) and a
  /// copy here would drift the day that argument changes them.
  final int maxQueuedRowsPerTable;
  final int maxQueuedRowsTotal;

  /// What this process calls itself in `pg_stat_activity.application_name`.
  ///
  /// Not free-form: `SELECT application_name, count(*) FROM pg_stat_activity
  /// GROUP BY 1` is how an engineer names the writer, the app's collector
  /// shows up as `tfc_dart` (`database.dart:109-121`), and this is how the
  /// gateway shows up as itself. Suffixed with the gateway's `publisherId`
  /// when one is configured, so two gateways on one plant LAN are
  /// distinguishable — the same reason `publisherId` exists on the wire
  /// (08-02).
  String applicationNameFor(String? publisherId) => publisherId == null
      ? 'centroidx-gateway-collector'
      : 'centroidx-gateway-collector-$publisherId';

  /// [includeSecrets] is threaded to the endpoint's rendering and defaults to
  /// false. See [CollectionEndpoint.toJson].
  Map<String, dynamic> toJson({bool includeSecrets = false}) =>
      <String, dynamic>{
        'enabled': enabled,
        'table_prefix': tablePrefix,
        'sole_writer': soleWriter,
        if (endpoint != null)
          'endpoint': endpoint!.toJson(includeSecrets: includeSecrets),
        'ssl_mode': sslMode,
        if (maxPoolConnections != null)
          'max_pool_connections': maxPoolConnections,
        'connect_timeout_ms': connectTimeout.inMilliseconds,
        'query_timeout_ms': queryTimeout.inMilliseconds,
        'max_queued_rows_per_table': maxQueuedRowsPerTable,
        'max_queued_rows_total': maxQueuedRowsTotal,
      };

  @override
  bool operator ==(Object other) =>
      other is CollectionConfig &&
      other.enabled == enabled &&
      other.tablePrefix == tablePrefix &&
      other.soleWriter == soleWriter &&
      other.endpoint == endpoint &&
      other.sslMode == sslMode &&
      other.maxPoolConnections == maxPoolConnections &&
      other.connectTimeout == connectTimeout &&
      other.queryTimeout == queryTimeout &&
      other.maxQueuedRowsPerTable == maxQueuedRowsPerTable &&
      other.maxQueuedRowsTotal == maxQueuedRowsTotal;

  @override
  int get hashCode => Object.hash(
      enabled,
      tablePrefix,
      soleWriter,
      endpoint,
      sslMode,
      maxPoolConnections,
      connectTimeout,
      queryTimeout,
      maxQueuedRowsPerTable,
      maxQueuedRowsTotal);
}

/// A quote, a semicolon, a backslash, a control character or leading
/// whitespace — anything that could carry meaning through the unescaped
/// interpolation at `database_drift.dart:687` / `:907`.
bool _unsafePrefix(String prefix) {
  if (prefix.trimLeft() != prefix) return true;
  for (final unit in prefix.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return true;
    if (unit == 0x22 || unit == 0x27 || unit == 0x3b || unit == 0x5c) {
      // " ' ; \
      return true;
    }
  }
  return false;
}
