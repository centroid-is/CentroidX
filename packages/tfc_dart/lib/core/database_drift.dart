// ============================================================================
// ========================  DRIFT / DATABASE LAYER  ==========================
// ============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:drift/isolate.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart' as pg;
import 'package:logger/logger.dart';
// kSeedRoles is the single source of the seeded role names and group sets;
// tfc_dart -> tfc_access, never the reverse.
import 'package:tfc_access/tfc_access.dart' show kSeedRoles;

import 'alarm.dart';
import 'database.dart';
import 'database_batch_insert.dart';
import 'database_connections.dart';
// Imported, not re-exported: a consumer that wants the payload vocabulary
// should not have to take this file's `dart:io` with it. See that file's
// header.
import 'database_notification.dart';
import 'mcp_tables.dart';
import 'mcp_database.dart';

part 'database_drift.g.dart';

/// File-level logger. These diagnostics used to go to stderr, which in a
/// windowed MSIX build with no console is discarded outright.
final Logger _log = Logger();

@UseRowClass(AlarmConfig, constructor: 'fromDb')
class Alarm extends Table {
  @override
  Set<Column> get primaryKey => {uid};

  TextColumn get uid => text()();
  TextColumn get key => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text()();
  TextColumn get rules =>
      text()(); // JSON string representation of List<AlarmRule>
}

class AlarmHistory extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The alarm definition this activation belongs to.
  ///
  /// **Deliberately NOT `.references(Alarm, #uid)`** (schema v7). Alarm
  /// definitions live in the `alarm_man_config` preference JSON, not as rows:
  /// nothing anywhere in this codebase has ever inserted into the [Alarm]
  /// table. On Postgres, where foreign keys are always enforced, that made
  /// **every** `alarm_history` insert a guaranteed SQLSTATE 23503, and it
  /// never fired only because SVN has zero alarms configured and no alarm has
  /// ever cleared. Dropping the constraint is what makes writing history
  /// possible at all; backing definitions with the dead table instead is
  /// recorded as a refused alternative (14-CONTEXT DI-5).
  ///
  /// Measured, not asserted: `test/integration/alarm_schema_v7_test.dart`
  /// arms 1 and 2, against a real Postgres. A SQLite test cannot see this —
  /// drift never issues `PRAGMA foreign_keys = ON`, so the constraint is inert
  /// there and a green unit suite proves nothing about the plant.
  TextColumn get alarmUid => text()();
  TextColumn get alarmTitle => text()();
  TextColumn get alarmDescription => text()();
  TextColumn get alarmLevel => text()();
  TextColumn get expression => text().nullable()();
  BoolColumn get active => boolean()();
  BoolColumn get pendingAck => boolean()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get deactivatedAt => dateTime().nullable()();
  DateTimeColumn get acknowledgedAt => dateTime().nullable()();

  /// Which rule of the alarm produced this activation.
  ///
  /// An alarm may carry several rules and, before v7, the table could not tell
  /// them apart. `(alarm_uid, rule_index)` with `deactivated_at IS NULL` is the
  /// identity of an **open** row (14-CONTEXT D-4), enforced by
  /// [_alarmHistoryOpenRowIndexStatement].
  ///
  /// **Nullable, and that has a consequence every writer must honour: NULLs are
  /// DISTINCT in a unique index.** Two open rows for the same `alarm_uid` with
  /// a NULL `rule_index` both insert — measured, arm 5 of
  /// `alarm_schema_v7_test.dart`. So the "one open row per alarm-rule"
  /// guarantee holds only for rows written WITH a rule index, and every writer
  /// added by Phase 14 must supply one. It is nullable only because rows
  /// written before v7 have no rule to point at; do not "fix" the index into
  /// `COALESCE(rule_index, -1)` to close the gap, because that starts refusing
  /// legacy rows the database is already holding.
  IntColumn get ruleIndex => integer().nullable()();

  /// Where [createdAt] / [deactivatedAt] came from: `plant` when every value
  /// contributing to the evaluation carried a `sourceTime`, `backend_receipt`
  /// when at least one did not and the backend's own receipt instant was used
  /// instead (14-CONTEXT D-2).
  ///
  /// Nullable: rows written before v7 have no provenance to record, and a
  /// missing label is honest about that where a defaulted one would not be.
  TextColumn get tsSource => text().nullable()();

  /// Why the row was closed: `cleared`, `acknowledged`, `inferred_restart` or
  /// `inferred_config_change` (14-CONTEXT D-4).
  ///
  /// The two `inferred_*` values are the point of the column — they let a stop
  /// analysis tell a measured clear from one reconstructed after a backend
  /// restart, rather than reading both as the same fact.
  TextColumn get deactivatedReason => text().nullable()();
}

class FlutterPreferences extends Table {
  @override
  Set<Column> get primaryKey => {key};

  TextColumn get key => text()();
  TextColumn get value => text().nullable()();
  TextColumn get type => text()();
}

// ---------------------------------------------------------------------------
// Access control tables (schema v6). See docs/access-control-spec.md §2.
// ---------------------------------------------------------------------------

/// A role: a name and the set of groups it grants.
///
/// [name] is the primary key rather than a surrogate integer **on purpose**:
/// when OIDC lands, an incoming group claim of `"Shift Leader"` matches the
/// role by name with no mapping table, exactly as Ignition and SIMATIC Logon
/// do it. Do not replace it with an integer id.
///
/// The four rows written by the v6 seed migration are ordinary rows
/// afterwards — editable and deletable — with `Operator` the sole exception,
/// and that guard lives in the repository layer, not here.
class AppRole extends Table {
  @override
  Set<Column> get primaryKey => {name};

  TextColumn get name => text()();

  /// JSON array of `AccessGroup` enum names, written by
  /// `AccessRole.encodeGroups()` and read back by `AccessRole.decodeGroups()`.
  ///
  /// Keep it small: the backend config watcher fires on preference writes and
  /// `pg_notify` has an 8000-byte cap, which errors the firing statement
  /// rather than truncating it.
  TextColumn get groups => text()();

  /// True for the rows the v6 migration seeded. Informational only.
  BoolColumn get seeded => boolean().withDefault(const Constant(false))();
}

/// A user: a name, a password hash, and exactly one role.
///
/// One role per user, not many — multi-role adds union semantics and an
/// "effective permissions" inspector, and is not worth it at this size.
class AppUser extends Table {
  @override
  Set<Column> get primaryKey => {username};

  TextColumn get username => text()();

  /// Matched to [AppRole.name] by name, never by id — see [AppRole].
  TextColumn get roleName => text().references(AppRole, #name)();

  /// Argon2id over the password with [salt], stored self-describing: the value
  /// carries its own algorithm tag and cost parameters.
  ///
  /// This column and [salt] are the **only** place a credential is stored.
  /// Never in `Preferences` or the `flutter_preferences` table: those are
  /// synced between stations and read by the backend config watcher.
  TextColumn get passwordHash => text()();

  /// Per-user random salt, stored base64. See [passwordHash].
  TextColumn get salt => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastLoginAt => dateTime().nullable()();

  /// A station account's sessions never expire.
  ///
  /// The panel-PC flag — the freezer display signs in once as its area
  /// account and lives signed in. On the USER rather than the station so a
  /// human signing in on the same panel keeps the inactivity window. The
  /// default is false: every account is a person until somebody says
  /// otherwise, which is also what an account carried over from v5 gets.
  BoolColumn get stationAccount =>
      boolean().withDefault(const Constant(false))();
}

/// The human-action audit trail: append-only, never pruned.
///
/// **This is not [AuditLog].** `AuditLog` (`mcp_tables.dart`) records MCP tool
/// invocations by the AI layer; `AuditEntry` records human writes and auth
/// events. The two coexist and neither replaces the other.
///
/// Denials are recorded as well as successes ([allowed]) — a denied write is
/// the more interesting audit line, and it is how a role configured too
/// tightly gets found. One human action gets one [actionId] with N member rows
/// beneath it, so a recipe apply reads as one action rather than N unrelated
/// ones.
class AuditEntry extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get at => dateTime()();

  /// Username, or `'anonymous'`.
  TextColumn get who => text()();

  /// Hostname of the station the action was made from.
  TextColumn get station => text()();

  TextColumn get roleName => text()();

  /// `'tag' | 'pref' | 'route' | 'auth'`.
  TextColumn get surface => text()();

  TextColumn get itemKey => text()();

  /// Dotted path within a struct write, e.g. `p_cfg.Freq`. Null for scalars.
  TextColumn get member => text().nullable()();

  TextColumn get oldValue => text().nullable()();
  TextColumn get newValue => text().nullable()();
  TextColumn get groupRequired => text()();

  /// False rows are denials, and they are kept.
  BoolColumn get allowed => boolean()();

  /// Defaults to hand-made **on purpose**.
  ///
  /// Today every external caller of `stateMan.write` is a widget, but that
  /// holds by accident rather than by construction. Defaulting to `'operator'`
  /// means an unmarked future machine caller lands *in* the trail loudly
  /// rather than escaping it silently; an absent audit row is the one defect
  /// nobody ever notices.
  TextColumn get origin => text().withDefault(const Constant('operator'))();

  /// Correlation id: one human action, N rows.
  TextColumn get actionId => text()();

  /// Free-text justification, prompted for on the `configure` and `administer`
  /// surfaces only. The column exists for every row.
  TextColumn get reason => text().nullable()();
}

// ---------------------------------------------------------------------------
// Access template tables (schema v6). See docs/access-control-spec.md §7b.
// ---------------------------------------------------------------------------

/// A named set of rules mapping a struct member — or the whole key — to an
/// `AccessGroup`. Drift stores it as `access_template`.
///
/// Rules rather than one group per key, because one conveyor key carries both
/// `p_cmd_JogFwd` and `p_cfg_ManualFreq` through a single
/// `stateMan.write(key, wholeStruct)`: a group per *asset* cannot separate
/// jogging from changing drive frequency, and a group per *member* can.
///
/// The repo ships **no** rows. The user creates the templates, and only four
/// assets write structs at all — `conveyor`, `schneider`, `sensor`, `recipes`.
class AccessTemplateTable extends Table {
  /// Spelled out rather than derived. Drift does **not** strip a trailing
  /// `Table` from the class name — `PlcCodeBlockTable` reads
  /// `plc_code_block` because `mcp_tables.dart:40` overrides this getter, and
  /// without the override the generated name here would be
  /// `access_template_table`, which is not what the Postgres DDL below
  /// creates. The `Table` suffix on the class stays: `AccessTemplate` is
  /// `tfc_access`'s value type and this file imports that package.
  @override
  String get tableName => 'access_template';

  @override
  Set<Column> get primaryKey => {name};

  /// The user-facing template name, and the value an
  /// [AccessKeyBindingTable] row points at.
  ///
  /// The name is the primary key rather than a surrogate id for the same
  /// reason [AppRole]'s is: it is what a person types into the key repository
  /// and what the binding carries, so a rename is a visible operation rather
  /// than an invisible one.
  TextColumn get name => text()();

  /// JSON object of member name -> `AccessGroup` name, written by
  /// `AccessTemplate.encodeRules()` and read back by
  /// `AccessTemplate.decodeRules()`. The member name `'*'` (`kWholeKeyMember`)
  /// means the whole key — deliberately not a legal IEC 61131-3 identifier, so
  /// it cannot collide with a real member.
  ///
  /// A member no rule mentions is **unrestricted** — tags fail open, which is
  /// why the key repository has to make unbound keys findable at a glance:
  /// visibility is what replaces enforcement here.
  TextColumn get rules => text()();

  DateTimeColumn get updatedAt => dateTime()();
}

/// One key bound to one template. Drift stores it as `access_key_binding`.
///
/// **This is deliberately not a field on `KeyMappingEntry`** (ruled
/// 2026-08-30, reversing the shape spec §7b implies). `key_mappings` is
/// classified `configure` by `kPrefAccessRules`, so a binding living in that
/// blob would be authorization data behind a `configure` gate: anybody able to
/// edit a page could re-scope who may write what, through the key repository's
/// import card or the raw preferences editor. Templates are behind `users`
/// precisely to prevent that, and the binding is the other half of the same
/// decision — its own table makes the gate true of the data and not only of
/// the button.
///
/// §7b's synchronous-resolution requirement survives the move: the prompt has
/// to appear when a control is *tapped*, with no await, so these rows are
/// loaded into the same in-memory snapshot the templates are.
class AccessKeyBindingTable extends Table {
  /// See [AccessTemplateTable.tableName]: explicit, because drift would
  /// otherwise generate `access_key_binding_table`.
  @override
  String get tableName => 'access_key_binding';

  @override
  Set<Column> get primaryKey => {keyName};

  /// The `keyMappings` key this binding is for, and the primary key — so a
  /// key **cannot be bound twice**. "Explicit, per key, always" made
  /// structural rather than left to a caller to uphold.
  TextColumn get keyName => text()();

  /// The [AccessTemplateTable.name] this key resolves through, matched by name
  /// and carrying **no foreign key**.
  ///
  /// That is deliberate. The resolver treats a binding naming a missing
  /// template as *unbound* and the key repository surfaces it, whereas a
  /// database-level constraint would make a template delete fail with a driver
  /// error rather than with `TemplateInUseException`'s named list of the keys
  /// still bound — and on Postgres it would make the delete's outcome depend
  /// on which station happened to run the migration.
  TextColumn get templateName => text()();

  DateTimeColumn get updatedAt => dateTime()();
}

/// Saved History Views (name + keys)
class HistoryView extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class HistoryViewKey extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get viewId =>
      integer().references(HistoryView, #id, onDelete: KeyAction.cascade)();
  TextColumn get key => text()();
  TextColumn get alias => text().nullable()(); // Add alias column
  BoolColumn get useSecondYAxis =>
      boolean().withDefault(const Constant(false))(); // Add Y-axis choice
  IntColumn get graphIndex =>
      integer().withDefault(const Constant(0))(); // Add graph index
}

/// Graph-level configuration (name, Y-axis units)
class HistoryViewGraph extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get viewId =>
      integer().references(HistoryView, #id, onDelete: KeyAction.cascade)();
  IntColumn get graphIndex => integer()();
  TextColumn get name => text().nullable()();
  TextColumn get yAxisUnit => text().nullable()();
  TextColumn get yAxis2Unit => text().nullable()();
}

/// NEW: Saved Periods per History View
class HistoryViewPeriod extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get viewId =>
      integer().references(HistoryView, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  DateTimeColumn get startAt => dateTime()();
  DateTimeColumn get endAt => dateTime()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
}

// Register all tables here
@DriftDatabase(tables: [
  Alarm,
  AlarmHistory,
  FlutterPreferences,
  HistoryView,
  HistoryViewKey,
  HistoryViewGraph,
  HistoryViewPeriod,
  // MCP-owned tables (Phase 16 consolidation):
  AuditLog,
  PlcCodeBlockTable,
  PlcVariableTable,
  DrawingTable,
  DrawingComponentTable,
  TechDocTable,
  TechDocSectionTable,
  McpProposalTable,
  PlcVarRefTable,
  PlcFbInstanceTable,
  PlcBlockCallTable,
  // Access control tables (schema v6):
  AppRole,
  AppUser,
  AuditEntry,
  // Access template tables (schema v6):
  AccessTemplateTable,
  AccessKeyBindingTable,
])
class AppDatabase extends _$AppDatabase implements McpDatabase {
  final DatabaseConfig config;
  AppDatabase._(this.config, QueryExecutor executor) : super(executor);

  /// Creates an in-memory SQLite [AppDatabase] for testing.
  @visibleForTesting
  factory AppDatabase.inMemoryForTest() => AppDatabase._(
        DatabaseConfig(),
        NativeDatabase.memory(logStatements: false),
      );

  /// A generative constructor so a test can *subclass* [AppDatabase] and
  /// override [tableExists] / [tableInsertBatch].
  ///
  /// [AppDatabase._] is private, which means the only backend a test outside
  /// this library can give [Database] is a real one. That is why the write
  /// path's outage handling — the retry queue, its overflow trimming and the
  /// rows it discards — had no tests at all: reaching it requires a database
  /// that fails on demand and then recovers, and sqlite cannot be made to do
  /// either ([tableExists] queries `information_schema`, which sqlite does not
  /// have, so an in-memory backend is permanently "down" and can never come
  /// back up).
  @visibleForTesting
  AppDatabase.forTest(this.config, QueryExecutor executor) : super(executor);

  final logger = Logger();

  /// The one LISTEN/NOTIFY connection, held as the in-flight future rather
  /// than the connection itself.
  ///
  /// `conn ??= await open()` looks like it shares, and does not: the null
  /// check runs, the await suspends, and only then does the assignment land.
  /// Every subscriber that arrives inside that window sees null and opens its
  /// own. Twelve checkweigher series subscribing at startup left a
  /// workstation holding twelve connections, eleven of them orphaned but open
  /// with a LISTEN registered on each.
  ///
  /// Assigning the future before any await closes the window — later callers
  /// join the one already in flight. A session can hold any number of
  /// channels, and the driver's `channels` map demultiplexes them by name, so
  /// one connection is all this ever needed.
  Future<pg.Connection?>? _notificationConnection;

  /// Every open [listenToChannel] stream riding on [_notificationConnection],
  /// so that a connection found dead can end them all.
  final Set<StreamController<String>> _notificationSubscribers = {};

  /// Polls the LISTEN/NOTIFY connection for having died; see
  /// [_ensureNotificationWatchdog].
  Timer? _notificationWatchdog;

  /// The connection future [_notificationWatchdog] was started for, so a
  /// watchdog left over from a replaced connection is not mistaken for the
  /// current one's.
  Future<pg.Connection?>? _notificationWatchdogFor;

  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  /// The DriftIsolate backing this database (null when using create() or sqlite).
  DriftIsolate? _driftIsolate;

  /// The pool backing this database, when it lives in *this* isolate.
  ///
  /// Only [create] sets it. [spawn] builds its pool inside the DriftIsolate,
  /// out of reach from here, and [close] disposes of it by killing the isolate
  /// instead. Null for sqlite, which has no pool.
  pg.Pool? _pool;

  /// The pool [close] has to release, for tests that need to watch it.
  @visibleForTesting
  pg.Pool? get poolForTest => _pool;

  /// The health monitor standing in [_pool], when it is ours to stop.
  ///
  /// Same split as [_pool]: only [create] has one, because [spawn]'s monitor
  /// runs inside the DriftIsolate and dies with it.
  _HealthMonitor? _healthMonitor;

  /// Set on the first [close] so repeat and concurrent calls share one
  /// teardown rather than racing each other through it.
  Future<void>? _closed;

  /// Port for receiving connection health events from the Pool inside the DriftIsolate.
  ReceivePort? _healthPort;
  Stream<bool>? _connectionHealthBroadcast;

  /// Inject a custom health stream for testing (bypasses ReceivePort).
  @visibleForTesting
  set connectionHealthBroadcastForTest(Stream<bool>? stream) {
    _connectionHealthBroadcast = stream;
  }

  /// Connection health stream driven by TCP keepalive inside the DriftIsolate.
  /// Broadcast stream — safe for multiple listeners (e.g. multiple StreamBuilders).
  Stream<bool>? get connectionHealth {
    if (_connectionHealthBroadcast == null && _healthPort != null) {
      _connectionHealthBroadcast =
          _healthPort!.cast<bool>().asBroadcastStream();
    }
    return _connectionHealthBroadcast;
  }

  @override
  int get schemaVersion => 7;

  /// The `audit_entry` indexes, created outside Drift because Drift's
  /// `@TableIndex` cannot express `DESC` and every one of these is a
  /// newest-first read.
  ///
  /// `IF NOT EXISTS` on both backends (SQLite 3.8+, Postgres 9.5+) for the
  /// same reason the Postgres table DDL uses it: several SVN stations share
  /// one database and each of them opens it.
  ///
  /// The `(item_key, at DESC)` index is the one that pays for itself: the
  /// `AREAnn.DEVnn.SUBnn` key convention means a prefix filter on `item_key`
  /// gives "everything on CN04" for free. Without these three the Phase 5
  /// trail viewer degrades to a table scan, and a trail nobody can read is a
  /// trail nobody reads.
  static const List<String> _auditIndexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_audit_entry_at ON audit_entry (at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_audit_entry_item_key_at '
        'ON audit_entry (item_key, at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_audit_entry_who_at '
        'ON audit_entry (who, at DESC)',
  ];

  /// Create the [_auditIndexStatements] indexes.
  ///
  /// Called from both `onCreate` and the `from < 6` upgrade branch, and from
  /// both the SQLite and the Postgres path of that branch — the statements are
  /// identical on both backends, so they live in one place rather than being
  /// copied into each arm.
  Future<void> _createAuditIndexes(Migrator m) async {
    for (final stmt in _auditIndexStatements) {
      await m.database.customStatement(stmt);
    }
  }

  /// The partial unique index that makes "two open rows for one alarm-rule"
  /// unrepresentable (schema v7, 14-CONTEXT D-4).
  ///
  /// `alarmHistoryOverlaps` and `StopIntervalSource` both read a row as ONE
  /// interval with a nullable end, so a second open row for the same
  /// alarm-rule double-counts every stop. Application-level discipline cannot
  /// give that guarantee: it does not survive a crash between the SELECT and
  /// the INSERT. The database can.
  ///
  /// **Partial on purpose.** Without `WHERE deactivated_at IS NULL` the index
  /// would allow an alarm rule exactly one activation ever. Do not remove the
  /// predicate, and do not wrap `rule_index` in `COALESCE` — see
  /// [AlarmHistory.ruleIndex] for why NULLs staying distinct is the measured,
  /// wanted behaviour.
  ///
  /// `IF NOT EXISTS` on both backends (SQLite 3.8+, Postgres 9.5+), for the
  /// same reason [_auditIndexStatements] uses it: several SVN stations share
  /// one database and every one of them runs the migration when it opens.
  static const String _alarmHistoryOpenRowIndexStatement =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_alarm_history_open '
      'ON alarm_history (alarm_uid, rule_index) '
      'WHERE deactivated_at IS NULL';

  /// Create [_alarmHistoryOpenRowIndexStatement].
  ///
  /// Called from `onCreate` **and** from the v7 upgrade branch, on both
  /// backends. Both, not just the upgrade: a database created from scratch by
  /// a new station would otherwise carry no index at all, and the guarantee
  /// would hold only on databases that happened to have been upgraded.
  Future<void> _createAlarmHistoryOpenRowIndex(Migrator m) async {
    await m.database.customStatement(_alarmHistoryOpenRowIndexStatement);
  }

  /// Drop every FOREIGN KEY on `alarm_history` that references `alarm`
  /// (schema v7, Postgres only).
  ///
  /// **The name is discovered, not assumed** (14-CONTEXT CD-4). Drift's
  /// default would be `alarm_history_alarm_uid_fkey`, but a database
  /// provisioned by some other route may have named it differently, and a
  /// `DROP CONSTRAINT` against a guessed name either fails or silently drops
  /// nothing. `information_schema` knows.
  ///
  /// **Zero hits is a normal outcome, not an error** (A2): a database that
  /// never carried the constraint is already in the state v7 wants. It is
  /// logged and the migration carries on — throwing here would abort the whole
  /// upgrade for a database that has nothing wrong with it.
  ///
  /// The constraint name is interpolated because a DDL identifier cannot be a
  /// bind parameter. It comes from the server's own catalogue, never from a
  /// row of alarm data, so T-14-01's "every value stays a `Variable`" is not
  /// weakened here.
  Future<void> _dropAlarmHistoryForeignKeys(Migrator m) async {
    final found = await m.database.customSelect(
      "SELECT tc.constraint_name AS name "
      "FROM information_schema.table_constraints tc "
      "JOIN information_schema.constraint_column_usage ccu "
      "  ON ccu.constraint_name = tc.constraint_name "
      " AND ccu.constraint_schema = tc.constraint_schema "
      "WHERE tc.table_name = 'alarm_history' "
      "  AND tc.constraint_type = 'FOREIGN KEY' "
      "  AND ccu.table_name = 'alarm'",
    ).get();

    if (found.isEmpty) {
      logger.i('Schema v7: no alarm_history -> alarm foreign key present; '
          'nothing to drop');
      return;
    }
    for (final row in found) {
      final name = row.read<String>('name');
      logger.i('Schema v7: dropping alarm_history foreign key "$name"');
      await m.database.customStatement(
          'ALTER TABLE alarm_history DROP CONSTRAINT IF EXISTS "$name"');
    }
  }

  /// The `access_key_binding` index.
  ///
  /// `keysBoundTo` runs on every template delete — it is what produces the
  /// named key list a delete is blocked with — and again on every render of
  /// the key repository's bound-key counts, which is a per-template query on
  /// a page that lists every template. Without the index both are table scans.
  ///
  /// `IF NOT EXISTS` on both backends, for the same reason
  /// [_auditIndexStatements] uses it: several SVN stations share one database
  /// and each of them opens it.
  static const List<String> _accessBindingIndexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_access_key_binding_template_name '
        'ON access_key_binding (template_name)',
  ];

  /// Create the [_accessBindingIndexStatements] indexes.
  ///
  /// Called from `onCreate` and from the `from < 6` upgrade branch, on both
  /// backends — the statements are identical on each, so they live in one
  /// place rather than being copied into both arms.
  Future<void> _createAccessBindingIndexes(Migrator m) async {
    for (final stmt in _accessBindingIndexStatements) {
      await m.database.customStatement(stmt);
    }
  }

  /// Write the four roles from `kSeedRoles` into `app_role`.
  ///
  /// `onConflict: DoNothing()` emits `ON CONFLICT DO NOTHING`, which both
  /// SQLite and Postgres accept — that is what makes a second station opening
  /// the same database harmless, and what stops a re-run resetting an edited
  /// `Operator` row back to `{operate}`. Deliberately not
  /// `InsertMode.insertOrIgnore`, which is SQLite-only.
  ///
  /// These are ordinary rows once written: editable and deletable like any
  /// other. `Operator` is the one exception, and its immutability is enforced
  /// in the repository layer, not here — Postgres is reachable with `psql`, so
  /// a database-level guard would be a guarantee this deployment cannot
  /// actually make. It is an operational guard and it lives where operations
  /// go through.
  Future<void> _seedAccessRoles() async {
    for (final role in kSeedRoles) {
      await into(appRole).insert(
        AppRoleCompanion.insert(
          name: role.name,
          groups: role.encodeGroups(),
          seeded: const Value(true),
        ),
        onConflict: DoNothing(),
      );
    }
  }

  /// Re-run [_seedAccessRoles] from a test.
  ///
  /// Exists so the idempotency the shared-Postgres deployment depends on is
  /// actually asserted rather than assumed: a second station opening the same
  /// database runs the seed against rows that already exist. Drop
  /// `onConflict: DoNothing()` and this throws.
  @visibleForTesting
  Future<void> seedAccessRolesForTest() => _seedAccessRoles();

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createAuditIndexes(m);
          await _createAccessBindingIndexes(m);
          await _createAlarmHistoryOpenRowIndex(m);
          await _seedAccessRoles();
        },
        onUpgrade: (m, from, to) async {
          logger.i('Database onUpgrade: $from -> $to');
          if (from < 2) {
            await m.createTable(historyView);
            await m.createTable(historyViewKey);
            await m.createTable(historyViewGraph);
            await m.createTable(historyViewPeriod);
          }
          if (from < 3) {
            // Migrate datetime columns from integer (unix epoch) to text
            // (ISO 8601). Only needed for SQLite; Postgres already stores
            // datetimes as timestamptz text.
            if (native) {
              for (final stmt in [
                "UPDATE alarm_history SET created_at = strftime('%Y-%m-%dT%H:%M:%S', created_at, 'unixepoch') || 'Z' WHERE typeof(created_at) = 'integer'",
                "UPDATE alarm_history SET deactivated_at = strftime('%Y-%m-%dT%H:%M:%S', deactivated_at, 'unixepoch') || 'Z' WHERE typeof(deactivated_at) = 'integer'",
                "UPDATE alarm_history SET acknowledged_at = strftime('%Y-%m-%dT%H:%M:%S', acknowledged_at, 'unixepoch') || 'Z' WHERE typeof(acknowledged_at) = 'integer'",
                "UPDATE history_view SET created_at = strftime('%Y-%m-%dT%H:%M:%S', created_at, 'unixepoch') || 'Z' WHERE typeof(created_at) = 'integer'",
                "UPDATE history_view SET updated_at = strftime('%Y-%m-%dT%H:%M:%S', updated_at, 'unixepoch') || 'Z' WHERE typeof(updated_at) = 'integer'",
                "UPDATE history_view_period SET start_at = strftime('%Y-%m-%dT%H:%M:%S', start_at, 'unixepoch') || 'Z' WHERE typeof(start_at) = 'integer'",
                "UPDATE history_view_period SET end_at = strftime('%Y-%m-%dT%H:%M:%S', end_at, 'unixepoch') || 'Z' WHERE typeof(end_at) = 'integer'",
                "UPDATE history_view_period SET created_at = strftime('%Y-%m-%dT%H:%M:%S', created_at, 'unixepoch') || 'Z' WHERE typeof(created_at) = 'integer'",
              ]) {
                await m.database.customStatement(stmt);
              }
              logger.i('Migrated SQLite datetime columns from int to text');
            }
          }
          if (from < 4) {
            if (native) {
              await m.database.customStatement(
                'ALTER TABLE history_view_graph ADD COLUMN name TEXT',
              );
            } else {
              // Postgres: use IF NOT EXISTS to be idempotent
              await m.database.customStatement(
                'ALTER TABLE history_view_graph ADD COLUMN IF NOT EXISTS name TEXT',
              );
            }
          }
          // Schema v5: Add all MCP tables (consolidated from branch).
          if (from < 5) {
            if (native) {
              // SQLite: m.createTable uses current drift schema which
              // includes all columns (vendor_type, server_alias, etc.).
              await m.createTable(auditLog);
              await m.createTable(plcCodeBlockTable);
              await m.createTable(plcVariableTable);
              await m.createTable(drawingTable);
              await m.createTable(drawingComponentTable);
              await m.createTable(techDocTable);
              await m.createTable(techDocSectionTable);
              await m.createTable(mcpProposalTable);
              await m.createTable(plcVarRefTable);
              await m.createTable(plcFbInstanceTable);
              await m.createTable(plcBlockCallTable);
            } else {
              // PostgreSQL: IF NOT EXISTS for idempotency.
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS audit_log (id SERIAL PRIMARY KEY, operator_id TEXT NOT NULL, tool TEXT NOT NULL, arguments TEXT NOT NULL, reasoning TEXT, status TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL, completed_at TEXT)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS plc_code_block (id SERIAL PRIMARY KEY, asset_key TEXT NOT NULL, block_name TEXT NOT NULL, block_type TEXT NOT NULL, file_path TEXT NOT NULL, declaration TEXT NOT NULL, implementation TEXT, full_source TEXT NOT NULL, parent_block_id INTEGER, indexed_at TEXT NOT NULL, vendor_type TEXT, server_alias TEXT)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS plc_variable (id SERIAL PRIMARY KEY, block_id INTEGER NOT NULL REFERENCES plc_code_block(id), variable_name TEXT NOT NULL, variable_type TEXT NOT NULL, section TEXT NOT NULL, qualified_name TEXT NOT NULL, comment TEXT)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS drawing (id SERIAL PRIMARY KEY, asset_key TEXT NOT NULL, drawing_name TEXT NOT NULL, file_path TEXT NOT NULL, page_count INTEGER NOT NULL, uploaded_at TEXT NOT NULL, pdf_bytes BYTEA)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS drawing_component (id SERIAL PRIMARY KEY, drawing_id INTEGER NOT NULL REFERENCES drawing(id), page_number INTEGER NOT NULL, full_page_text TEXT NOT NULL)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS tech_doc (id SERIAL PRIMARY KEY, name TEXT NOT NULL, pdf_bytes BYTEA NOT NULL, page_count INTEGER NOT NULL, section_count INTEGER NOT NULL, uploaded_at TEXT NOT NULL)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS tech_doc_section (id SERIAL PRIMARY KEY, doc_id INTEGER NOT NULL REFERENCES tech_doc(id), parent_id INTEGER, title TEXT NOT NULL, content TEXT NOT NULL, page_start INTEGER NOT NULL, page_end INTEGER NOT NULL, level INTEGER NOT NULL, sort_order INTEGER NOT NULL)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS mcp_proposal (id SERIAL PRIMARY KEY, proposal_type TEXT NOT NULL, title TEXT NOT NULL, proposal_json TEXT NOT NULL, operator_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT \'pending\', created_at TEXT NOT NULL)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS plc_var_ref (id SERIAL PRIMARY KEY, block_id INTEGER NOT NULL REFERENCES plc_code_block(id), variable_path TEXT NOT NULL, kind TEXT NOT NULL, line_number INTEGER, source_line TEXT)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS plc_fb_instance (id SERIAL PRIMARY KEY, declaring_block_id INTEGER NOT NULL REFERENCES plc_code_block(id), instance_name TEXT NOT NULL, fb_type_name TEXT NOT NULL)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS plc_block_call (id SERIAL PRIMARY KEY, caller_block_id INTEGER NOT NULL REFERENCES plc_code_block(id), callee_block_name TEXT NOT NULL, line_number INTEGER)');
            }
          }
          // Schema v6: access control — roles, users, the audit trail, the
          // access templates and the bindings that point keys at them.
          //
          // **One arm for the whole milestone, on purpose.** It was developed
          // as v6, v7 and v8 and squash-merged as one commit, so no database
          // anywhere was ever left at 6 or 7: every station running a release
          // build is at v5 and arrives here once. Keeping the three arms would
          // have meant shipping two branches that can never execute, plus an
          // `ADD COLUMN` whose only job was to reach a shape `createTable`
          // already produces — which is exactly the duplicate-column abort
          // that guard existed to dodge. A station that ran a pre-release
          // build of this milestone is the one exception; see the note in the
          // PR, and `__schema`/`user_version` can simply be set to 6.
          //
          // The tables go up together because there is no state in which one
          // is useful without the others: a binding with no template table to
          // read resolves to nothing, and a template nothing can bind to is
          // inert.
          if (from < 6) {
            if (native) {
              await m.createTable(appRole);
              await m.createTable(appUser);
              await m.createTable(auditEntry);
              await m.createTable(accessTemplateTable);
              await m.createTable(accessKeyBindingTable);
            } else {
              // PostgreSQL: raw `IF NOT EXISTS` DDL rather than
              // `m.createTable`, following the v5 branch immediately above and
              // not the spec's simplification that `m.createTable` covers both
              // backends. Several SVN stations share one Postgres database and
              // every one of them runs this branch when it opens, so it has to
              // be safe to run twice — otherwise the second station aborts the
              // migration and leaves the database half-upgraded.
              //
              // **No test executes this arm.** Not one in `test/core/`, which
              // can only open SQLite, and none in `test/integration/` either.
              // Phase 1 recorded that on 2026-08-28 in
              // `.planning/phases/01-identity-and-audit/deferred-items.md` §1
              // and it is still open. What stands behind these statements is a
              // read against the drift tables and the source-derived
              // column-parity tests in `access_schema_test.dart` and
              // `access_key_binding_table_test.dart`, which compare these
              // string literals against the table definitions and nothing
              // more — they do not connect to Postgres and they cannot see a
              // wrong type or a statement that fails at runtime. The first
              // thing that will actually run this is a station.
              //
              // Datetimes are TEXT on both backends: this database sets
              // `DriftDatabaseOptions(storeDateTimeAsText: true)` (see the
              // `options` override) and the root `build.yaml` sets
              // `store_date_time_values_as_text: true`.
              //
              // `template_name` has no `REFERENCES access_template(name)`, and
              // that is the one place this DDL deliberately differs from what
              // a reader would expect: see [AccessKeyBindingTable.templateName]
              // for why a dangling binding has to be storable.
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS app_role (name TEXT PRIMARY KEY, groups TEXT NOT NULL, seeded BOOLEAN NOT NULL DEFAULT FALSE)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS app_user (username TEXT PRIMARY KEY, role_name TEXT NOT NULL REFERENCES app_role(name), password_hash TEXT NOT NULL, salt TEXT NOT NULL, created_at TEXT NOT NULL, last_login_at TEXT, station_account BOOLEAN NOT NULL DEFAULT FALSE)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS audit_entry (id SERIAL PRIMARY KEY, at TEXT NOT NULL, who TEXT NOT NULL, station TEXT NOT NULL, role_name TEXT NOT NULL, surface TEXT NOT NULL, item_key TEXT NOT NULL, member TEXT, old_value TEXT, new_value TEXT, group_required TEXT NOT NULL, allowed BOOLEAN NOT NULL, origin TEXT NOT NULL DEFAULT \'operator\', action_id TEXT NOT NULL, reason TEXT)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS access_template (name TEXT PRIMARY KEY, rules TEXT NOT NULL, updated_at TEXT NOT NULL)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS access_key_binding (key_name TEXT PRIMARY KEY, template_name TEXT NOT NULL, updated_at TEXT NOT NULL)');
            }
            await _createAuditIndexes(m);
            await _createAccessBindingIndexes(m);
            await _seedAccessRoles();
          }
          // Schema v7: `alarm_history` becomes writable, and an open
          // activation row becomes a thing the database can hold exactly one
          // of. See 14-CONTEXT D-5.
          //
          // **This is the first migration arm in this repository with an
          // executed Postgres test** — `test/integration/alarm_schema_v7_test
          // .dart`, twelve legs against a real server, half of them against a
          // v6 shape built by hand and lifted through this branch. The v6
          // comment above records that no test had ever run one. v7 does not
          // inherit that.
          if (from < 7) {
            if (native) {
              // SQLite has no `ADD COLUMN IF NOT EXISTS` and no
              // `DROP CONSTRAINT`. Neither matters here:
              //
              // * A SQLite database is per-process, so nothing else is racing
              //   this branch and plain `ADD COLUMN` is safe.
              // * The `alarm_uid -> alarm(uid)` foreign key is already inert.
              //   Drift never issues `PRAGMA foreign_keys = ON` and nothing in
              //   this package sets it in a `beforeOpen`, so SQLite has been
              //   accepting these inserts all along — which is exactly why the
              //   Postgres-only defect survived so long. Rebuilding the table
              //   to remove a constraint that is not enforced would be a
              //   copy-and-swap of the plant's history for no behavioural
              //   change; it is deliberately not done.
              for (final stmt in [
                'ALTER TABLE alarm_history ADD COLUMN rule_index INTEGER',
                'ALTER TABLE alarm_history ADD COLUMN ts_source TEXT',
                'ALTER TABLE alarm_history ADD COLUMN deactivated_reason TEXT',
              ]) {
                await m.database.customStatement(stmt);
              }
            } else {
              // PostgreSQL: idempotent, for the several-stations-share-one-
              // database reason the v6 branch records. Each of these has to be
              // safe to run twice or the second station through aborts the
              // migration and leaves the database half-upgraded.
              //
              // **`BIGINT`, not `INTEGER`.** Drift's Postgres dialect maps
              // `IntColumn` to `bigint`, so a station that CREATES this schema
              // gets `rule_index bigint` while `INTEGER` here would give an
              // upgraded station `int4` — two shapes for one column, from one
              // release. It is not cosmetic: drift reads the column as
              // `DriftSqlType.int` and a client binding an int8 parameter
              // against an int4 column gets SQLSTATE 08P01, "insufficient data
              // left in message", which reads like a driver bug rather than a
              // schema mismatch. Measured — `alarm_schema_v7_test.dart`'s
              // column-parity arm compares the created and upgraded shapes
              // column for column so the two paths cannot drift apart again.
              for (final stmt in [
                'ALTER TABLE alarm_history ADD COLUMN IF NOT EXISTS rule_index BIGINT',
                'ALTER TABLE alarm_history ADD COLUMN IF NOT EXISTS ts_source TEXT',
                'ALTER TABLE alarm_history ADD COLUMN IF NOT EXISTS deactivated_reason TEXT',
              ]) {
                await m.database.customStatement(stmt);
              }
              await _dropAlarmHistoryForeignKeys(m);
            }
            await _createAlarmHistoryOpenRowIndex(m);
          }
        },
      );

  bool get native => executor is NativeDatabase;
  bool get postgres => executor is PgDatabase;

  /// Check if the database is reachable by running a real query.
  /// Returns false if the query fails or times out.
  Future<bool> get isOpen async {
    try {
      await customSelect('SELECT 1').getSingle().timeout(
            const Duration(seconds: 3),
          );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> open() async {
    await executor.ensureOpen(this);
  }

  /// The one LISTEN/NOTIFY connection, opening it if nobody has yet.
  ///
  /// Caching the in-flight future is what makes concurrent subscribers share:
  /// it is assigned before any await, so the eleven that used to arrive during
  /// the open now join it instead of each starting one of their own.
  ///
  /// A future that *fails* is evicted rather than kept. Caching it would hand
  /// the same rejected future to every later subscriber, so a single moment of
  /// the database being unreachable would latch every channel shut for the
  /// life of the process -- and this code exists on the reconnect path, where
  /// the database being briefly unreachable is the normal case rather than the
  /// exceptional one. Dropping it costs nothing: the next subscriber opens a
  /// new one, which is what happened before the future was cached at all.
  ///
  /// A connection that has *died* since it was opened is evicted too, and a
  /// fresh one opened in its place. The socket dying does not clear the cache
  /// by itself -- nothing in the driver reports it -- so without this check a
  /// dead connection would be handed to every later subscriber for the life
  /// of the process, and each would wait on it forever.
  Future<(Future<pg.Connection?>, pg.Connection?)>
      _sharedNotificationConnection() async {
    // Two passes at most: the first may find the cached connection dead and
    // evict it, the second opens its replacement.
    for (var pass = 0;; pass++) {
      final pending =
          _notificationConnection ??= _createNotificationConnection();
      final pg.Connection? connection;
      try {
        connection = await pending;
      } catch (error) {
        // Only evict what we put there; a teardown may already have replaced
        // it.
        if (identical(_notificationConnection, pending)) {
          _notificationConnection = null;
        }
        rethrow;
      }
      if (connection == null || connection.isOpen || pass > 0) {
        return (pending, connection);
      }
      logger.w('LISTEN/NOTIFY connection is dead; opening a replacement');
      _notificationConnectionDied(pending, connection);
    }
  }

  /// Forgets a LISTEN/NOTIFY connection that has died, and ends every channel
  /// stream that was riding on it.
  ///
  /// The driver does not do this for us. When the socket under the
  /// connection breaks -- Postgres restarted, a firewall dropped the idle
  /// flow, the keepalive gave up -- `_close` tears the session down but never
  /// closes the `channels` listeners, and its `closed` future never completes
  /// for a socket it destroyed. So every subscriber sits on a stream that will
  /// never emit, error, or end, and each readout driven by it freezes on its
  /// last count while looking perfectly healthy. Ending the streams here is
  /// what tells subscribers to fetch again and re-subscribe.
  ///
  /// Only the current connection is evicted: a death reported late for one
  /// already replaced must not take its replacement down with it. Its
  /// subscribers were ended when it was replaced, so there is nothing left to
  /// do for it either.
  void _notificationConnectionDied(
      Future<pg.Connection?> pending, pg.Connection? connection) {
    if (!identical(_notificationConnection, pending)) return;
    _notificationConnection = null;
    _stopNotificationWatchdog();
    final orphaned = _notificationSubscribers.toList();
    _notificationSubscribers.clear();
    if (orphaned.isNotEmpty) {
      logger.w('LISTEN/NOTIFY connection died; ending ${orphaned.length} '
          'channel stream(s) so their subscribers re-subscribe');
    }
    for (final controller in orphaned) {
      if (!controller.isClosed) controller.close();
    }
    // Best effort. A broken socket has already been destroyed by the driver;
    // this is for the connection that is merely unusable.
    unawaited(connection?.close(force: true).catchError((_) {}));
  }

  /// Watches [connection] for having died, on behalf of its subscribers.
  ///
  /// `isOpen` is the one signal the driver does give: it flips the moment the
  /// socket is found broken. Polled rather than awaited because the
  /// alternative, `closed`, is the sink's `done` future, and that never
  /// completes for a destroyed socket. One timer per connection, not per
  /// subscriber; it stops with the last subscriber or the connection's death.
  void _ensureNotificationWatchdog(
      Future<pg.Connection?> pending, pg.Connection connection) {
    if (_notificationWatchdog != null &&
        identical(_notificationWatchdogFor, pending)) {
      return;
    }
    _stopNotificationWatchdog();
    _notificationWatchdogFor = pending;
    _notificationWatchdog =
        Timer.periodic(kNotificationWatchdogInterval, (timer) {
      if (!identical(_notificationConnection, pending)) {
        // Replaced under us; the replacement gets its own watchdog.
        timer.cancel();
        return;
      }
      if (connection.isOpen) return;
      _notificationConnectionDied(pending, connection);
    });
  }

  void _stopNotificationWatchdog() {
    _notificationWatchdog?.cancel();
    _notificationWatchdog = null;
    _notificationWatchdogFor = null;
  }

  /// Get or create the dedicated channel connection
  Future<pg.Connection?> _createNotificationConnection() async {
    if (config.postgres == null) {
      return null;
    }
    logger.i('Creating dedicated connection for LISTEN/NOTIFY channels');
    return await pg.Connection.open(
      config.postgres!,
      settings: pg.ConnectionSettings(
        sslMode: config.sslMode,
        applicationName: '${config.applicationName}:notify',
        // Same keepalive as the pool. This connection only ever receives, so
        // it is the one a stateful firewall sees as idle and drops, and the
        // driver's 30 s x 5 default left that undetected for minutes. With
        // this the OS notices in ~15 s, `isOpen` flips, and the watchdog ends
        // the channel streams.
        keepAliveInterval: const Duration(seconds: 5),
        keepAliveCount: 3,
      ),
    ).timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        logger.e('Timeout creating notification connection');
        throw TimeoutException(
            'Failed to create notification connection after 10 seconds');
      },
    );
  }

  /// Factory: creates an [AppDatabase], in the current isolate.
  /// sqlite: will be created in the background, if postgres is not provided
  static Future<AppDatabase> create(DatabaseConfig config,
      {Directory? sqliteFolder}) async {
    if (config.postgres != null) {
      final healthPort = ReceivePort();
      final pool = pg.Pool.withEndpoints([config.postgres!],
          settings: pg.PoolSettings(
            maxConnectionCount: poolConnectionCount(config.maxPoolConnections),
            sslMode: config.sslMode,
            applicationName: config.applicationName,
            connectTimeout: config.connectTimeout,
            keepAliveInterval: const Duration(seconds: 5),
            keepAliveCount: 3,
            queryTimeout: config.queryTimeout,
          ));

      final monitor = _startPoolHealthMonitor(pool, healthPort.sendPort);

      final db = AppDatabase._(
          config, PgDatabase.opened(pool, logStatements: config.debug));
      db._healthPort = healthPort;
      // `PgDatabase.opened` does not take ownership of what it is handed, so
      // nothing downstream of drift will ever close this pool. [close] has to.
      db._pool = pool;
      db._healthMonitor = monitor;
      return db;
    }
    if (sqliteFolder != null) {
      final dbFolder = sqliteFolder;
      final file = File(p.join(dbFolder.path, 'db.sqlite'));
      // Use a local NativeDatabase (or FlutterQueryExecutor).
      final executor = NativeDatabase.createInBackground(
        file,
        logStatements: config.debug,
      );
      return AppDatabase._(config, executor);
    }
    throw Exception("Unable to create database");
  }

  /// Factory: creates an [AppDatabase], spawning a DriftIsolate.
  static Future<AppDatabase> spawn(DatabaseConfig config,
      {Directory? sqliteFolder}) async {
    if (config.postgres != null) {
      // Create a ReceivePort for health events from the Pool inside the isolate.
      final healthPort = ReceivePort();
      final healthSendPort = healthPort.sendPort;

      // Spawn a DriftIsolate handling the Postgres connection off the main
      // isolate. We provide a custom `isolateSpawn` that wraps the entry point
      // in `runZonedGuarded` so that SocketExceptions (e.g. "Connection reset
      // by peer" from the pg package's _waitForResult) are caught by the zone
      // error handler instead of crashing the drift isolate.
      final isolate = await DriftIsolate.spawn(() {
        final pool = pg.Pool.withEndpoints([config.postgres!],
            settings: pg.PoolSettings(
              maxConnectionCount: poolConnectionCount(config.maxPoolConnections),
              sslMode: config.sslMode,
              applicationName: config.applicationName,
              connectTimeout: config.connectTimeout,
              keepAliveInterval: const Duration(seconds: 5),
              keepAliveCount: 3,
              queryTimeout: config.queryTimeout,
            ));

        // Health monitor: holds one pool connection and awaits its closed
        // future. TCP keepalive detects dead connections, firing closed.
        // On death, sends false and re-acquires a new connection.
        _startPoolHealthMonitor(pool, healthSendPort);

        return PgDatabase.opened(pool, logStatements: config.debug);
      }, isolateSpawn: _spawnGuardedIsolate);
      final executor = await isolate.connect();
      final db = AppDatabase._(config, executor);
      db._driftIsolate = isolate;
      db._healthPort = healthPort;
      return db;
    } else if (sqliteFolder != null) {
      final dbFolder = sqliteFolder;
      final file = File(p.join(dbFolder.path, 'db.sqlite'));
      // Use a local NativeDatabase (or FlutterQueryExecutor).
      final executor = NativeDatabase.createInBackground(
        file,
        logStatements: config.debug,
      );
      return AppDatabase._(config, executor);
    }
    throw Exception("Unable to create database from spawn");
  }

  // ----------------------------
  // Convenience API for History Views
  // ----------------------------

  // Update the convenience methods to handle both configs
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]) async {
    return transaction(() async {
      final id = await into(historyView).insert(HistoryViewCompanion.insert(
        name: name,
      ));

      // Save key configurations
      if (keys.isNotEmpty) {
        for (final key in keys) {
          final config = keyConfigs?[key];
          await into(historyViewKey).insert(HistoryViewKeyCompanion.insert(
            viewId: id,
            key: key,
            alias: Value(config?['alias'] ?? key),
            useSecondYAxis: Value(config?['useSecondYAxis'] ?? false),
            graphIndex: Value(config?['graphIndex'] ?? 0),
          ));
        }
      }

      // Save graph configurations
      if (graphConfigs != null) {
        for (final entry in graphConfigs.entries) {
          final graphIndex = int.tryParse(entry.key);
          if (graphIndex != null) {
            final config = entry.value;
            await into(historyViewGraph)
                .insert(HistoryViewGraphCompanion.insert(
              viewId: id,
              graphIndex: graphIndex,
              name: Value(config['name'] as String?),
              yAxisUnit: Value(config['yAxisUnit'] ?? ''),
              yAxis2Unit: Value(config['yAxis2Unit'] ?? ''),
            ));
          }
        }
      }

      return id;
    });
  }

  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]) async {
    await transaction(() async {
      await (update(historyView)..where((t) => t.id.equals(id))).write(
        HistoryViewCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await (delete(historyViewKey)..where((t) => t.viewId.equals(id))).go();
      if (keys.isNotEmpty) {
        for (final key in keys) {
          final config = keyConfigs?[key];
          await into(historyViewKey).insert(HistoryViewKeyCompanion.insert(
            viewId: id,
            key: key,
            alias: Value(config?['alias'] ?? key),
            useSecondYAxis: Value(config?['useSecondYAxis'] ?? false),
            graphIndex: Value(config?['graphIndex'] ?? 0),
          ));
        }
      }
      await (delete(historyViewGraph)..where((t) => t.viewId.equals(id))).go();
      if (graphConfigs != null) {
        for (final entry in graphConfigs.entries) {
          final graphIndex = int.tryParse(entry.key);
          if (graphIndex != null) {
            final config = entry.value;
            await into(historyViewGraph)
                .insert(HistoryViewGraphCompanion.insert(
              viewId: id,
              graphIndex: graphIndex,
              name: Value(config['name'] as String?),
              yAxisUnit: Value(config['yAxisUnit'] ?? ''),
              yAxis2Unit: Value(config['yAxis2Unit'] ?? ''),
            ));
          }
        }
      }
    });
  }

  Future<void> deleteHistoryView(int id) async {
    await (delete(historyView)..where((t) => t.id.equals(id))).go();
    // keys cascade due to FK
    await (delete(historyViewKey)..where((t) => t.viewId.equals(id))).go();
    await (delete(historyViewGraph)..where((t) => t.viewId.equals(id))).go();
    await (delete(historyViewPeriod)..where((t) => t.viewId.equals(id))).go();
  }

  Future<List<HistoryViewData>> selectHistoryViews() {
    return (select(historyView)).get();
  }

  // Return primitive data, let the UI layer convert to objects
  Future<Map<String, Map<String, dynamic>>> getHistoryViewKeys(
      int viewId) async {
    final rows = await (select(historyViewKey)
          ..where((t) => t.viewId.equals(viewId)))
        .get();

    final configs = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      configs[row.key] = {
        'key': row.key,
        'alias': row.alias ?? row.key,
        'useSecondYAxis': row.useSecondYAxis,
        'graphIndex': row.graphIndex,
      };
    }
    return configs;
  }

  // Add method to get graph configurations
  Future<Map<int, Map<String, dynamic>>> getHistoryViewGraphs(
      int viewId) async {
    final rows = await (select(historyViewGraph)
          ..where((t) => t.viewId.equals(viewId)))
        .get();

    final configs = <int, Map<String, dynamic>>{};
    for (final row in rows) {
      configs[row.graphIndex] = {
        'name': row.name ?? '',
        'yAxisUnit': row.yAxisUnit ?? '',
        'yAxis2Unit': row.yAxis2Unit ?? '',
      };
    }
    return configs;
  }

  // Add method to get just the keys (for backward compatibility)
  Future<List<String>> getHistoryViewKeyNames(int viewId) async {
    final rows = await (select(historyViewKey)
          ..where((t) => t.viewId.equals(viewId)))
        .get();
    return rows.map((r) => r.key).toList();
  }

  // ----------------------------
  // NEW: Saved Periods helpers
  // ----------------------------
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end) async {
    return into(historyViewPeriod).insert(HistoryViewPeriodCompanion.insert(
      viewId: viewId,
      name: name,
      startAt: start,
      endAt: end,
    ));
  }

  Future<void> deleteHistoryViewPeriod(int id) async {
    await (delete(historyViewPeriod)..where((t) => t.id.equals(id))).go();
  }

  Future<List<HistoryViewPeriodData>> listHistoryViewPeriods(int viewId) async {
    return (select(historyViewPeriod)..where((t) => t.viewId.equals(viewId)))
        .get();
  }

  /// A best-effort global retention horizon (now - max(drop_after) across jobs).
  /// Returns null if unknown/unavailable.
  Future<DateTime?> getGlobalRetentionHorizon() async {
    try {
      // TimescaleDB only: read from jobs
      final rows = await customSelect(
        r'''
        SELECT config ->> 'drop_after' AS drop_after
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention'
        ''',
      ).get();

      if (rows.isEmpty) return null;
      Duration? maxDur;
      for (final r in rows) {
        final s = r.data['drop_after'] as String?;
        final d = AppDatabase.parsePostgresInterval(s);
        if (d != null) {
          if (maxDur == null || d > maxDur) maxDur = d;
        }
      }
      if (maxDur == null) return null;
      return DateTime.now().subtract(maxDur);
    } catch (_) {
      // Not postgres/timescale or no permissions
      return null;
    }
  }

  // ----------------------------
  // (Your existing dynamic table helpers below unchanged)
  // ----------------------------

  Future<void> createTable(
      String tableName, Map<String, String> columns) async {
    // Quote column names: inserts and ALTERs quote them, so creation must
    // too — unquoted mixed-case names fold to lowercase and every insert
    // then fails with 42703 undefined column.
    final columnDefs = columns.entries
        .map((e) => '"${e.key.replaceAll('"', '""')}" ${e.value}')
        .join(', ');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS "$tableName" (
        $columnDefs
      )
    ''');
  }

  /// Check if a table exists
  Future<bool> tableExists(String tableName) async {
    final result = await customSelect(
      r'''
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name = $1
    ) AS "exists"
    ''',
      variables: [Variable.withString(tableName)],
    ).getSingle();

    return result.read<bool>('exists');
  }

  /// Insert data into a dynamic table
  Future<int> tableInsert(String tableName, Map<String, dynamic> data) async {
    final keys = data.keys.map((key) => '"$key"').join(', ');
    final placeholders = data.keys.map((key) {
      final value = data[key];
      final index = data.keys.toList().indexOf(key) + 1;

      if (key == 'time') {
        return '\$$index::timestamptz';
      } else if (value is List) {
        // Handle array types with proper casting
        if (value.isEmpty) {
          return '\$$index::text[]'; // Default to text array for empty lists
        }

        final first = value.first;
        if (first is int) {
          return '\$$index::integer[]';
        } else if (first is double) {
          return '\$$index::double precision[]';
        } else if (first is String) {
          return '\$$index::text[]';
        } else if (first is bool) {
          return '\$$index::boolean[]';
        } else {
          return '\$$index::jsonb[]';
        }
      }
      return '\$$index';
    }).join(', ');

    // Create variables with proper array formatting
    final variables = data.values.map((value) {
      if (value is List) {
        if (value.isEmpty) {
          return const Variable('{}');
        }

        final first = value.first;
        if (first is num) {
          // For numeric arrays, convert to PostgreSQL array format
          final arrayString = '{${value.join(',')}}';
          return Variable(arrayString);
        } else if (first is String) {
          // For string arrays, quote each element
          final arrayString = '{${value.map((e) => '"$e"').join(',')}}';
          return Variable(arrayString);
        } else if (first is bool) {
          // For boolean arrays
          final arrayString = '{${value.join(',')}}';
          return Variable(arrayString);
        } else {
          // For other types, convert to JSON array
          return Variable(jsonEncode(value));
        }
      }
      return Variable(value);
    }).toList();

    return await customInsert(
      'INSERT INTO "$tableName" ($keys) VALUES ($placeholders)',
      variables: variables,
    );
  }

  /// Batch insert multiple rows into a dynamic table.
  ///
  /// The statement is built by [buildBatchInsert], which is pure and covered
  /// by `database_batch_insert_test.dart` in CI on every platform. The bug
  /// this guards against — the column list, the placeholders and the bound
  /// variables disagreeing on ragged rows — is a construction bug, and
  /// pinning it needed a test that does not require a Postgres to run.
  Future<int> tableInsertBatch(
      String tableName, List<Map<String, dynamic>> dataList) async {
    final insert = buildBatchInsert(tableName, dataList);
    if (insert == null) return 0;
    return await customInsert(insert.sql, variables: insert.variables);
  }

  /// Query data from a dynamic table with detailed analysis
  Future<List<QueryRow>> tableQuery(
    String tableName, {
    List<String>? columns,
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
  }) async {
    final start = DateTime.now();

    final cols = columns?.join(', ') ?? '*';
    final whereClause = where != null ? ' WHERE $where' : '';
    final orderByClause = orderBy != null ? ' ORDER BY $orderBy' : '';

    final sql = 'SELECT $cols FROM "$tableName"$whereClause$orderByClause';

    final result = await customSelect(
      sql,
      variables:
          whereArgs != null ? [for (var arg in whereArgs) Variable(arg)] : [],
    ).get();

    final duration = DateTime.now().difference(start);
    logger.d('tableQuery: query execution took ${duration.inMilliseconds}ms');

    return result;
  }

  Future<List<QueryRow>> tableQueryMultiple(
    // table name -> columns
    Map<String, List<String>> tableNames, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
  }) async {
    if (tableNames.isEmpty) {
      return [];
    }
    //select coalesce("cooler.temp.1".time, "cooler.temp.2".time, "cooler.compressor.on".time) as time, "cooler.temp.1".value as value1, "cooler.temp.2".value as value2, "cooler.compressor.on".value as compOnBaby from "cooler.temp.2" full outer join "cooler.temp.1" on ( "cooler.temp.1".time = "cooler.temp.2".time ) full outer join "cooler.compressor.on" on ("cooler.compressor.on".time = "cooler.temp.1".time) where "cooler.compressor.on".value = true limit 100;
    String sql =
        'WITH data AS (select coalesce(${tableNames.keys.map((e) => '"$e".time').join(', ')}) as time, ';
    final columns = [];
    for (final table in tableNames.entries) {
      for (final column in table.value) {
        if (column == 'time') {
          continue;
        }
        if (column == 'value') {
          columns.add('"${table.key}".$column as "${table.key}"');
        } else {
          columns.add('"${table.key}".$column as "${table.key}.$column"');
        }
      }
    }
    sql += columns.join(', ');

    final master = tableNames.keys.first;
    if (where != null) {
      sql += ' from (select * from "$master" where $where) as "$master" ';
    } else {
      sql += ' from "$master" ';
    }
    for (final table in tableNames.entries.where((e) => e.key != master)) {
      if (where != null) {
        sql +=
            ' full outer join (select * from "${table.key}" where $where) as "${table.key}" using (time) ';
      } else {
        sql += ' full outer join "${table.key}" using (time) ';
      }
    }
    sql += ' ) SELECT * FROM data ';
    if (where != null) {
      sql += ' where $where ';
    }
    if (orderBy != null) {
      sql += ' order by $orderBy ';
    }
    final start = Stopwatch()..start();
    // Trace, and through the logger: this runs once per timeseries chart
    // query and the generated SQL is hundreds of characters wide. As a raw
    // `print` it was unfilterable -- every history view paid a full stdout
    // write for it, in release, with no way to turn it off.
    logger.t('tableQueryMultiple: SQL: $sql');
    final result = await customSelect(sql,
            variables: whereArgs != null
                ? [for (var arg in whereArgs) Variable(arg)]
                : [])
        .get();
    logger.d('tableQueryMultiple: query execution took '
        '${start.elapsedMilliseconds}ms');
    return result;
  }

  /// TODO: SQLITE
  ///
  /// Throws [DatabaseException] for a [RetentionPolicy] that is not
  /// [RetentionPolicy.isUsable], *before issuing any statement*. The order
  /// matters: this method's first act on the happy path is
  /// `remove_retention_policy`, so a refusal that came any later would already
  /// have taken away the policy the table had. Refusing here leaves the table
  /// exactly as it was and deletes nothing.
  ///
  /// This is the inner of the two guards. The outer one is in the UI, which
  /// clamps the retention field to 1..[kMaxRetentionDays] days. This one exists
  /// because the outer one cannot help a station whose config file already
  /// holds a bad value.
  Future<void> updateRetentionPolicy(
      String tableName, RetentionPolicy retention) async {
    if (!retention.isUsable) {
      throw DatabaseException(
          'Refusing to set a retention policy of ${retention.dropAfter} on '
          '"$tableName": anything under $kMinRetentionDuration would drop the '
          'table\'s history the next time the policy ran, not bound it. The '
          'stored value is almost certainly a unit mix-up rather than a '
          'decision. The table keeps whatever policy it already had.');
    }
    // Convert to hypertable
    await customStatement('''
      SELECT create_hypertable('"$tableName"', 'time', if_not_exists => TRUE, migrate_data => TRUE);
    ''');

    // Remove any existing retention policy first, then add new one
    final dropAfter = pg.Interval.duration(retention.dropAfter);

    await customStatement('''
      SELECT remove_retention_policy('"$tableName"', if_exists => TRUE);
    ''');
    try {
      if (retention.scheduleInterval != null) {
        final scheduleInterval =
            pg.Interval.duration(retention.scheduleInterval!);
        await customStatement('''
          SELECT add_retention_policy('"$tableName"', drop_after => INTERVAL '$dropAfter', schedule_interval => INTERVAL '$scheduleInterval');
        ''');
      } else {
        await customStatement('''
          SELECT add_retention_policy('"$tableName"', drop_after => INTERVAL '$dropAfter');
        ''');
      }
    } catch (e) {
      // Retention silently not applied means the disk fills instead.
      _log.e('Error updating retention policy for $tableName: $e');
    }
  }

  /// Get the retention duration for a hypertable
  Future<RetentionPolicy?> getRetentionPolicy(String tableName) async {
    final select = customSelect(r'''
      SELECT config ->> 'drop_after' AS drop_after, schedule_interval FROM timescaledb_information.jobs
      WHERE proc_name = 'policy_retention' AND hypertable_name = $1
    ''', variables: [Variable.withString(tableName)]);
    final QueryRow result;
    try {
      result = await select.getSingle();
    } catch (e) {
      // No retention policy exists for this table yet - this is normal
      return null;
    }

    final dropAfter = result.read<String>('drop_after');
    final scheduleInterval = result.read<String>('schedule_interval');

    return RetentionPolicy(
      dropAfter: parsePostgresInterval(dropAfter)!,
      scheduleInterval: parsePostgresInterval(scheduleInterval),
    );
  }

  /// Listen to table changes via PostgreSQL NOTIFY.
  ///
  /// The stream ends -- `onDone`, no error -- when the connection carrying it
  /// dies. Subscribers that need the notifications to keep coming must treat
  /// that as "fetch what you missed and subscribe again"; the next call opens
  /// a fresh connection.
  Stream<String> listenToChannel(String channelName) {
    late StreamController<String> controller;
    StreamSubscription? channelSubscription;
    Future<pg.Connection?>? pending;
    pg.Connection? connection;

    controller = StreamController<String>(
      onListen: () async {
        try {
          // Shared, and not latched shut by an open that failed or a
          // connection that died: see [_sharedNotificationConnection].
          final (lease, conn) = await _sharedNotificationConnection();

          if (conn == null) {
            logger.w('Cannot listen to channel: not using PostgreSQL');
            await controller.close();
            return;
          }
          if (!controller.hasListener) {
            // Cancelled while the connection was opening.
            return;
          }
          pending = lease;
          connection = conn;

          logger.i('Starting to listen on channel: $channelName');
          final channel = conn.channels[channelName];

          channelSubscription = channel.listen(
            (payload) {
              controller.add(payload);
            },
            onError: (error) {
              logger.w('Notification channel error: $error');
              controller.addError(error);
            },
            onDone: () {
              logger.i('Channel stream ended for: $channelName');
              controller.close();
            },
          );
          _notificationSubscribers.add(controller);
          _ensureNotificationWatchdog(lease, conn);
        } catch (e) {
          logger.w('Error setting up notification listener: $e');
          controller.addError(e);
          await controller.close();
        }
      },
      onCancel: () async {
        logger.i('Cancelling notification listener for: $channelName');
        _notificationSubscribers.remove(controller);
        if (_notificationSubscribers.isEmpty) _stopNotificationWatchdog();
        final conn = connection;
        if (conn == null) return;
        if (!conn.isOpen) {
          // Nothing to UNLISTEN on. Whoever next asks for the connection
          // finds it dead and replaces it.
          return;
        }
        try {
          await channelSubscription?.cancel();
        } catch (e) {
          // The UNLISTEN failed, so the connection is not usable. Drop it for
          // everyone: its other subscribers get their onDone and re-subscribe
          // on a fresh one, rather than staying parked on a connection that
          // only this subscriber knew was broken.
          logger.w('UNLISTEN failed; dropping the notify connection: $e');
          _notificationConnectionDied(pending!, conn);
        }
      },
    );

    return controller.stream;
  }

  /// Enable notifications for a table
  Future<String> enableNotificationChannel(String tableName) async {
    final channelName = 'table_${tableName}_changes';

    await customStatement('''
    CREATE OR REPLACE FUNCTION "notify_${tableName}_change"()
    RETURNS TRIGGER AS \$\$
    BEGIN
      PERFORM pg_notify(
        '$channelName',
        json_build_object(
          'action', TG_OP,
          'data', CASE
            WHEN TG_OP = 'DELETE' THEN row_to_json(OLD)
            ELSE row_to_json(NEW)
          END
        )::text
      );
      RETURN COALESCE(NEW, OLD);
    END;
    \$\$ LANGUAGE plpgsql;
  ''');

    await customStatement('''
  DROP TRIGGER IF EXISTS "${tableName}_notify" ON "$tableName";
  ''');

    try {
      await customStatement('''
  CREATE TRIGGER "${tableName}_notify"
  AFTER INSERT OR UPDATE OR DELETE ON "$tableName"
  FOR EACH ROW
  EXECUTE FUNCTION "notify_${tableName}_change"();
  ''');
    } catch (e) {
      // really dont care if the trigger already exists
      if (e.toString().contains('already exists')) {
        return channelName;
      }
      rethrow;
    }
    return channelName;
  }

  /// Like [enableNotificationChannel], but the payload carries only the value
  /// of [keyColumn] instead of the whole row.
  ///
  /// `pg_notify` payloads are capped at 8000 bytes, and the cap is enforced by
  /// *erroring the statement that fired the trigger*. A row-payload trigger on
  /// a table with large values — `flutter_preferences` holds the entire
  /// `key_mappings` JSON in one row — would therefore make every save of that
  /// row fail outright. This payload stays a few dozen bytes regardless of row
  /// size: `{"action": TG_OP, "key": <keyColumn>}`.
  Future<String> enableKeyedNotificationChannel(
      String tableName, String keyColumn) async {
    final channelName = 'table_${tableName}_key_changes';

    await customStatement('''
    CREATE OR REPLACE FUNCTION "notify_${tableName}_key_change"()
    RETURNS TRIGGER AS \$\$
    BEGIN
      PERFORM pg_notify(
        '$channelName',
        json_build_object(
          'action', TG_OP,
          'key', CASE WHEN TG_OP = 'DELETE' THEN OLD."$keyColumn" ELSE NEW."$keyColumn" END
        )::text
      );
      RETURN COALESCE(NEW, OLD);
    END;
    \$\$ LANGUAGE plpgsql;
  ''');

    await customStatement('''
  DROP TRIGGER IF EXISTS "${tableName}_key_notify" ON "$tableName";
  ''');

    try {
      await customStatement('''
  CREATE TRIGGER "${tableName}_key_notify"
  AFTER INSERT OR UPDATE OR DELETE ON "$tableName"
  FOR EACH ROW
  EXECUTE FUNCTION "notify_${tableName}_key_change"();
  ''');
    } catch (e) {
      // Two processes racing DROP+CREATE: losing the race is fine.
      if (e.toString().contains('already exists')) {
        return channelName;
      }
      rethrow;
    }
    return channelName;
  }

  static Duration? parsePostgresInterval(String? interval) {
    if (interval == null) return null;

    // TimescaleDB might return intervals in different formats

    final microsecondsMatch =
        RegExp(r'(\d+)\s*microseconds').firstMatch(interval);
    if (microsecondsMatch != null) {
      final microseconds = int.parse(microsecondsMatch.group(1)!);
      return Duration(microseconds: microseconds);
    }

    final millisecondsMatch =
        RegExp(r'(\d+)\s*milliseconds').firstMatch(interval);
    if (millisecondsMatch != null) {
      final milliseconds = int.parse(millisecondsMatch.group(1)!);
      return Duration(milliseconds: milliseconds);
    }

    final secondsMatch = RegExp(r'(\d+)\s*second').firstMatch(interval);
    if (secondsMatch != null) {
      final seconds = int.parse(secondsMatch.group(1)!);
      return Duration(seconds: seconds);
    }

    final minutesMatch = RegExp(r'(\d+)\s*minute').firstMatch(interval);
    if (minutesMatch != null) {
      final minutes = int.parse(minutesMatch.group(1)!);
      return Duration(minutes: minutes);
    }

    final hoursMatch = RegExp(r'(\d+)\s*hour').firstMatch(interval);
    if (hoursMatch != null) {
      final hours = int.parse(hoursMatch.group(1)!);
      return Duration(hours: hours);
    }

    final daysMatch = RegExp(r'(\d+)\s*day').firstMatch(interval);
    if (daysMatch != null) {
      final days = int.parse(daysMatch.group(1)!);
      return Duration(days: days);
    }

    final monthsMatch = RegExp(r'(\d+)\s*month').firstMatch(interval);
    if (monthsMatch != null) {
      final months = int.parse(monthsMatch.group(1)!);
      return Duration(days: months * 30); // approx
    }

    final yearsMatch = RegExp(r'(\d+)\s*year').firstMatch(interval);
    if (yearsMatch != null) {
      final years = int.parse(yearsMatch.group(1)!);
      return Duration(days: years * 365); // approx
    }

    // Format: "00:10:00" (HH:MM:SS)
    final timeMatch = RegExp(r'(\d+):(\d+):(\d+)').firstMatch(interval);
    if (timeMatch != null) {
      final hours = int.parse(timeMatch.group(1)!);
      final minutes = int.parse(timeMatch.group(2)!);
      final seconds = int.parse(timeMatch.group(3)!);
      return Duration(hours: hours, minutes: minutes, seconds: seconds);
    }

    throw FormatException('Unable to parse PostgreSQL interval: $interval');
  }

  /// Releases everything this database holds, including the pool.
  ///
  /// Idempotent: `connectWithRetry` closes attempts it is throwing away, and a
  /// second close arriving on top of the first must not start a second
  /// teardown or fail the caller.
  @override
  Future<void> close() => _closed ??= _close();

  Future<void> _close() async {
    _healthPort?.close();
    _stopNotificationWatchdog();
    for (final controller in _notificationSubscribers.toList()) {
      if (!controller.isClosed) controller.close();
    }
    _notificationSubscribers.clear();
    try {
      await (await _notificationConnection)?.close();
    } catch (_) {
      // Never opened, or already gone.
    }
    await super.close();
    // Order matters. `PgDatabase.opened` passes `closeUnderlyingWhenClosed:
    // false`, so `super.close()` leaves the pool open -- nothing in the repo
    // closed it at all, which is why the health monitor's standing connection
    // outlived every database that used one.
    //
    // Ask the monitor to let go before closing the pool, rather than closing
    // the pool out from under it. Both end up with the connection released,
    // but only this order releases it *politely*: a returned connection is
    // closed with a Terminate, and the backend exits on the spot. Forcing
    // destroys the socket instead and leaves the server to notice, which it
    // does at its own pace -- and a server that is slow to notice is exactly
    // the one already short of connection slots.
    //
    // How long to wait comes from the pool's own connect timeout: a monitor
    // caught mid-acquire cannot answer until that acquire lands, and giving up
    // first is what leaked. See [monitorStopTimeout].
    final monitor = _healthMonitor;
    if (monitor != null) {
      monitor.stop();
      var handedBack = true;
      await monitor.done
          .timeout(monitorStopTimeout(config.connectTimeout),
              onTimeout: () => handedBack = false)
          .catchError((Object _) {});
      if (!handedBack) {
        // Worth saying out loud. The force close below can only reach
        // connections the pool still knows about, so if the monitor is still
        // holding one -- or still opening one -- this is the moment a socket
        // gets orphaned, and it used to happen in silence.
        logger.w('Health monitor did not hand its connection back in time; '
            'closing the pool anyway, which may strand a connection');
      }
    }
    final pool = _pool;
    if (pool != null) {
      await releasePool(
        pool.close,
        onError: (e) => logger.w('Pool close did not go quietly: $e'),
      );
    }
    // The spawn path keeps its pool inside the isolate, where [_pool] cannot
    // reach it; killing the isolate takes the pool and its sockets with it.
    await _driftIsolate?.shutdownAll();
  }

  /// Get table statistics for performance analysis
  Future<void> analyzeTablePerformance(String tableName) async {
    print('📊 Analyzing table performance for $tableName');

    try {
      // Get table size
      final sizeResult = await customSelect('''
        SELECT 
          pg_size_pretty(pg_total_relation_size('"$tableName"')) as table_size,
          pg_size_pretty(pg_relation_size('"$tableName"')) as data_size,
          pg_size_pretty(pg_total_relation_size('"$tableName"') - pg_relation_size('"$tableName"')) as index_size
      ''').getSingle();

      print(
          ' Table size: ${sizeResult.data['table_size']} (data: ${sizeResult.data['data_size']}, indexes: ${sizeResult.data['index_size']})');

      // Get row count
      final countResult =
          await customSelect('SELECT COUNT(*) as row_count FROM "$tableName"')
              .getSingle();
      print(' Row count: ${countResult.data['row_count']}');

      // Get time range
      final timeRangeResult = await customSelect('''
        SELECT 
          MIN(time) as min_time,
          MAX(time) as max_time,
          MAX(time) - MIN(time) as time_span
        FROM "$tableName"
      ''').getSingle();

      print(
          '⏰ Time range: ${timeRangeResult.data['min_time']} to ${timeRangeResult.data['max_time']}');
      print('⏱️  Time span: ${timeRangeResult.data['time_span']}');

      // Check for indexes
      final indexResult = await customSelect('''
        SELECT indexname, indexdef 
        FROM pg_indexes 
        WHERE tablename = '$tableName'
      ''').get();

      print('🔍 Indexes:');
      for (final index in indexResult) {
        print('   ${index.data['indexname']}: ${index.data['indexdef']}');
      }
    } catch (e) {
      print('⚠️  Could not analyze table: $e');
    }
  }

  /// Check if time column has proper indexing
  Future<void> checkTimeIndex(String tableName) async {
    print('🔍 Checking time index for $tableName');

    try {
      final indexResult = await customSelect('''
        SELECT indexname 
        FROM pg_indexes 
        WHERE tablename = '$tableName' 
        AND indexdef LIKE '%time%'
      ''').get();

      if (indexResult.isEmpty) {
        print(
            '⚠️  WARNING: No time-based index found! This could be causing slow queries.');
        print(
            '💡 Consider creating an index: CREATE INDEX ON "$tableName" (time);');
      } else {
        print(
            '✅ Time index found: ${indexResult.map((r) => r.data['indexname']).join(', ')}');
      }
    } catch (e) {
      print('⚠️  Could not check indexes: $e');
    }
  }

  /// Test connection latency with detailed breakdown
  Future<void> testConnectionLatency() async {
    print(' Testing connection latency with detailed breakdown...');

    // Test 1: Simple connection test with timing
    final start1 = DateTime.now();
    final dbStart = DateTime.now();
    await customSelect('SELECT 1').getSingle();
    final dbDuration = DateTime.now().difference(dbStart);
    final totalDuration = DateTime.now().difference(start1);
    print('⏱️  Step 1: Database call took ${dbDuration.inMilliseconds}ms');
    print(
        '⏱️  Step 1: Total time including overhead: ${totalDuration.inMilliseconds}ms');

    // Test 2
    final start2 = DateTime.now();
    final dbStart2 = DateTime.now();
    await customSelect('SELECT NOW()').getSingle();
    final dbDuration2 = DateTime.now().difference(dbStart2);
    final totalDuration2 = DateTime.now().difference(start2);
    print('⏱️  Step 2: Database call took ${dbDuration2.inMilliseconds}ms');
    print(
        '⏱️  Step 2: Total time including overhead: ${totalDuration2.inMilliseconds}ms');
  }

  /// Test Drift isolate performance
  Future<void> testDriftIsolatePerformance() async {
    print('🔍 Testing Drift isolate performance...');

    final start1 = DateTime.now();
    await customSelect('SELECT 1').getSingle();
    final duration1 = DateTime.now().difference(start1);
    print('⏱️  Test 1 took: ${duration1.inMilliseconds}ms');

    final start2 = DateTime.now();
    for (int i = 0; i < 3; i++) {
      await customSelect('SELECT $i').getSingle();
    }
    final duration2 = DateTime.now().difference(start2);
    print(
        '⏱️  Test 2 took: ${duration2.inMilliseconds}ms (avg: ${duration2.inMilliseconds / 3}ms per operation)');

    final start3 = DateTime.now();
    await customSelect('SELECT 1').getSingle();
    final duration3 = DateTime.now().difference(start3);
    print('⏱️  Test 3 took: ${duration3.inMilliseconds}ms');
  }

  Future<void> testRawPostgresConnection() async {
    print('🔍 Testing raw PostgreSQL connection...');

    if (config.postgres == null) {
      print('❌ No PostgreSQL config available');
      return;
    }

    final start = DateTime.now();
    try {
      final connection = await pg.Connection.open(config.postgres!);
      final connectDuration = DateTime.now().difference(start);
      print(
          '⏱️  Raw connection creation took ${connectDuration.inMilliseconds}ms');

      final queryStart = DateTime.now();
      await connection.execute('SELECT 1');
      final queryDuration = DateTime.now().difference(queryStart);
      print('⏱️  Raw query execution took ${queryDuration.inMilliseconds}ms');

      await connection.close();
      print('✅ Raw connection test completed');
    } catch (e) {
      print('❌ Raw connection test failed: $e');
    }
  }
}

/// Custom isolate spawner that wraps the entry point in [runZonedGuarded].
///
/// Drift's default `DriftIsolate.spawn` uses `Isolate.spawn` directly, which
/// means the drift isolate's root zone has NO error handler. If the `pg`
/// package throws a [SocketException] (e.g. "Connection reset by peer" from
/// `_waitForResult`) that escapes drift's query try-catch — for example via
/// an orphaned Future or native socket callback — it becomes an unhandled
/// exception that kills the entire isolate:
///
/// ```
/// [ERROR:flutter/runtime/dart_isolate.cc(1402)] Unhandled exception:
/// SocketException: Connection reset by peer
/// ```
///
/// By wrapping the entry point in `runZonedGuarded`, we catch these stray
/// exceptions at the zone level, log them, and let the isolate continue.
/// The pool will evict the dead connection and provide a fresh one on the
/// next query.
Future<Isolate> _spawnGuardedIsolate<T>(void Function(T) entryPoint, T arg) {
  // Isolate.spawn within the same isolate group supports closures, so we
  // can capture `entryPoint` and `arg` directly. The `_` parameter is
  // unused — we just need a valid message to satisfy the Isolate.spawn API.
  return Isolate.spawn<void>((_) {
    final logger = Logger();
    runZonedGuarded(
      () => entryPoint(arg),
      (error, stack) {
        // Log but do NOT rethrow — this keeps the isolate alive.
        logger.w(
          'Drift isolate caught unhandled exception (isolate stays alive): '
          '$error',
        );
      },
    );
  }, null);
}

/// A running health monitor, so whoever started it can stop it again.
///
/// The monitor otherwise only ever exits by noticing the pool has closed, and
/// noticing takes until its next heartbeat. [stop] tells it to let go now, and
/// [done] completes once it actually has -- which is what lets the pool be
/// closed gracefully rather than yanked out from under it.
class _HealthMonitor {
  _HealthMonitor(this._stop, this.done);

  final Completer<void> _stop;

  /// Completes when the monitor has returned its connection and exited.
  final Future<void> done;

  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }
}

/// Holds one pool connection and awaits its [closed] future.
/// When TCP keepalive kills the connection, [closed] completes and we send
/// `false` via [port], then re-acquire a new connection from the pool.
/// This is running inside the drift spawned isolate.
///
/// Every wait is raced against the stop signal, so a shutdown does not have to
/// sit out a 15 second heartbeat or a 5 second retry delay before the monitor
/// hands its connection back.
///
/// Wrapped in [runZonedGuarded] so that any unhandled exception (e.g.
/// [SocketException] escaping the inner try-catch via native socket layer
/// or Future chaining) is caught by the zone handler instead of killing
/// the entire isolate.
_HealthMonitor _startPoolHealthMonitor(pg.Pool pool, SendPort port) {
  // Its own, because this also runs inside the drift isolate, where the
  // database's logger does not reach.
  final logger = Logger();
  final stop = Completer<void>();
  final done = Completer<void>();

  void finish() {
    if (!done.isCompleted) done.complete();
  }

  runZonedGuarded(() {
    Future<void> monitor() async {
      // Borrowed per beat and released, not held for the life of the pool.
      //
      // This used to wrap the whole heartbeat loop in a single
      // `withConnection`, so one connection stayed checked out for as long as
      // the process ran. With one Database per OPC UA server that is one
      // permanently-held connection each: the collector ran 8 databases and
      // held 16 connections, exactly two apiece -- one for this monitor, one
      // for the work. A pool sized to 1 could not have served both.
      //
      // What is lost by letting go between beats is the live signal:
      // `conn.closed` used to fire the instant the socket died, because the
      // monitor was sitting on it. Death is now noticed by the next beat
      // failing instead, so detection is polled rather than immediate --
      // which is why [kHealthBeatInterval] is sized against the 30 second
      // health timeout rather than left at the old 15.
      while (pool.isOpen && !stop.isCompleted) {
        try {
          await pool.withConnection((conn) async {
            await conn.execute('SELECT 1');
          });
          port.send(true);
        } catch (e) {
          // Continue rather than stop: the pool hands out a fresh connection
          // on the next beat, which is how this recovers from a drop.
          port.send(false);
          // A borrow that throws is the one case where we cannot say whether
          // the connection was ever handed out, let alone handed back. Say so:
          // an acquire that failed *after* opening its socket leaves that
          // socket with no owner, and the pool close that follows cannot reach
          // what the pool never recorded.
          logger.w('Health monitor borrow failed '
              '(stopping: ${stop.isCompleted}, pool open: ${pool.isOpen}): $e');
        }
        if (stop.isCompleted || !pool.isOpen) break;
        // Still raced against the stop signal. The beat itself is short now,
        // but this sleep is not, and a close that had to sit out a full beat
        // before the monitor noticed would be the slowest part of shutdown.
        await Future.any([
          Future<void>.delayed(kHealthBeatInterval),
          stop.future,
        ]);
      }
      finish();
    }

    unawaited(monitor());
  }, (error, stack) {
    // Last-resort handler — catches ANYTHING that escapes the try-catch
    // (e.g. SocketException from native layer, Future chain edge cases).
    // This prevents the isolate from being killed.
    //
    // Completing [done] here says "the monitor has let go", which is a claim
    // this handler is in no position to make: an error escaping asynchronously
    // does not mean the borrow came back. A close waiting on [done] takes it
    // at its word and closes the pool anyway, so if this fires during shutdown
    // it is a candidate for the connection that gets stranded. Loud on
    // purpose.
    logger.w('Health monitor died outside its own error handling; treating it '
        'as let go, which it may not be: $error');
    port.send(false);
    finish();
  });

  return _HealthMonitor(stop, done.future);
}

// `kNotificationWatchdogInterval`, `NotificationAction` and `NotificationData`
// used to close this file. They are hand-written and need only `dart:convert`,
// so they now live in `database_notification.dart` — imported above, and not
// re-exported. Reaching them no longer costs a reader `dart:io`,
// `dart:isolate` and `drift_postgres`.
