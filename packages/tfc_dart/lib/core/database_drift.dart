// ============================================================================
// ========================  DRIFT / DATABASE LAYER  ==========================
// ============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'sqlite_executor.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:drift/isolate.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart' as pg;
import 'package:logger/logger.dart';
// kSeedRoles is the single source of the seeded role names and group sets;
// tfc_dart -> tfc_access, never the reverse.
import 'package:tfc_access/tfc_access.dart'
    show
        kAnonymousPasswordSentinel,
        kAnonymousSaltSentinel,
        kAnonymousUsername,
        kOperatorRoleName,
        kSeedRoles;

import 'alarm.dart';
import 'database.dart';
import 'database_batch_insert.dart';
import 'database_connections.dart';
// Imported, not re-exported: a consumer that wants the payload vocabulary
// should not have to take this file's `dart:io` with it. See that file's
// header.
import 'database_notification.dart';
import 'config/config_item_table.dart'
    show ConfigChangeTable, ConfigItemTable;
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
  /// Measured, not asserted: `test/integration/alarm_schema_v8_test.dart`
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
  /// `alarm_schema_v8_test.dart`. So the "one open row per alarm-rule"
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

  /// The page-visibility whitelist (schema v7): a JSON array of page paths,
  /// or SQL NULL for "this role sees every page".
  ///
  /// Written by `encodeAllowedPagesColumn` and read by
  /// `decodeAllowedPagesColumn`. **NULL and `'[]'` are different claims** —
  /// NULL is no whitelist, `'[]'` is a whitelist naming nothing, i.e. block
  /// all — so this column is nullable rather than defaulting to an empty
  /// array. Every row carried over from v6 gets NULL and therefore behaves
  /// exactly as it did before the column existed.
  ///
  /// Authorization data, which is why it lives here rather than beside the
  /// pages in `page_editor_data`: that preference is classified `configure`,
  /// and anybody who can edit a page must not be able to re-scope who sees
  /// which pages. See `docs/page-visibility-whitelist-design.md` §1a.
  ///
  /// Keep it small, for the same reason [groups] says so: the backend config
  /// watcher fires on preference writes and `pg_notify` has an 8000-byte cap.
  TextColumn get allowedPages => text().nullable()();

  /// Where this role sits in the Access screen's list, lowest first, or NULL
  /// for a role nobody has placed — every role until the first reorder, and
  /// any role created after it.
  ///
  /// **Display order only.** Nothing that decides what a session may do reads
  /// it. Added on open by `_ensureSortOrderColumns` rather than by a schema
  /// arm, so it takes no version number; `AccessRepository.roles` supplies the
  /// fallback order for the NULLs.
  IntColumn get sortOrder => integer().nullable()();
}

/// A user: a name, a password hash, and one or more roles.
///
/// One role was the v6 ruling, on the grounds that multi-role adds union
/// semantics and an "effective permissions" inspector. Schema v9 reverses it:
/// the union turned out to be a set union over `AccessGroup` and nothing more
/// (roles were always bundles, never rungs on a ladder), while the single role
/// forced sites to mint a combinatorial role for every real person who was
/// two things at once. See `role_set.dart` for the composition rules.
class AppUser extends Table {
  @override
  Set<Column> get primaryKey => {username};

  TextColumn get username => text()();

  /// This account's **primary** role, matched to [AppRole.name] by name, never
  /// by id — see [AppRole].
  ///
  /// The one with the foreign key on it, and the whole answer for any account
  /// that holds exactly one role, which is every account carried over from v8.
  /// It is identity rather than precedence: what the account may do is the
  /// union of this and [additionalRoles].
  TextColumn get roleName => text().references(AppRole, #name)();

  /// The roles this account holds **beyond** [roleName] (schema v9): a JSON
  /// array of `app_role.name` values, or SQL NULL when it holds only its
  /// primary role.
  ///
  /// Written by `encodeAdditionalRoles` and read by `decodeAdditionalRoles`.
  /// NULL and an empty array mean the same thing here — unlike
  /// [allowedPages], where the distinction is the feature — so the codec
  /// writes NULL for both and every account carried over from v8 lands on NULL
  /// and behaves exactly as it did.
  ///
  /// **No foreign key, and it could not have one:** a JSON array cannot
  /// reference a column. That is handled where it matters instead —
  /// `AccessRepository.deleteRole` refuses a role anybody holds *either* way
  /// and `renameRole` rewrites both — and a name in here that matches no role
  /// row simply grants nothing, which is the fail-closed direction.
  ///
  /// Keep it small, for the reason [AppRole.groups] gives: the backend config
  /// watcher fires on preference writes and `pg_notify` has an 8000-byte cap.
  TextColumn get additionalRoles => text().nullable()();

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

  /// This account's personal page whitelist (schema v7), or NULL to follow
  /// whatever [AppRole.allowedPages] says.
  ///
  /// Three states, and the null one is the subtle one: **NULL means inherit
  /// the role**, not "sees every page". Every account carried over from v6
  /// lands on NULL, and if that meant unrestricted then the upgrade would mint
  /// a personal exemption for every existing account — the first role
  /// whitelist anybody configured would govern nobody who already existed.
  /// `effectiveAllowedPages` is where that rule is written down.
  ///
  /// A non-null value **replaces** the role's whitelist rather than
  /// intersecting or unioning with it, so both directions of exception are
  /// expressible. It can widen what this account *sees*; it can never widen
  /// what this account may *do*, because the group gate is ANDed on top.
  TextColumn get allowedPages => text().nullable()();

  /// How many idle minutes end this account's sessions (schema v8), or NULL
  /// for the default.
  ///
  /// Per account rather than per station: the account knows who walked away
  /// with what power, the panel does not. **NULL means "no value of its own"**,
  /// never "never expires" — sessions that must not expire are
  /// [stationAccount]'s, and only that flag produces one. Every account
  /// carried over from v7 lands on NULL and keeps the fifteen minutes it had.
  ///
  /// The range is enforced by `AccessRepository.setInactivityTimeout` and a
  /// value outside it is clamped on read by `resolveInactivityTimeout`, so a
  /// `psql` edit cannot end sessions instantly or never.
  IntColumn get inactivityTimeoutMinutes => integer().nullable()();

  /// Where this account sits in the Access screen's list, lowest first, or
  /// NULL for an account nobody has placed, which lists after the placed ones
  /// by username. The reserved anonymous account never gets one.
  ///
  /// Display order only, added on open with no schema version — see
  /// [AppRole.sortOrder].
  IntColumn get sortOrder => integer().nullable()();

  /// The page this account's sessions open on, as a route path such as
  /// `/pages/packing`, or NULL for Home (`/`).
  ///
  /// Per account rather than per station: the page somebody works from is
  /// theirs wherever they sign in. The reserved anonymous account's value is
  /// where every logged-out panel opens, and a station account's is where
  /// that panel opens — which is how two panels fronting different equipment
  /// still open on different pages.
  ///
  /// Never validated against the pages here. A path that names no routable
  /// page — renamed, deleted, unpublished, or not synced to this station yet —
  /// falls back to Home where it is read (`resolveHomePath`), so a stale value
  /// costs a landing page, never a boot.
  ///
  /// Added on open by `_ensureHomePageColumn` rather than by a schema arm, for
  /// the reason [sortOrder] gives: every existing row is correct as NULL.
  TextColumn get homePage => text().nullable()();

  /// Whether a raising alarm takes this account's screen to the page its
  /// Alarm beacon is on.
  ///
  /// Per account rather than plant-wide: being pulled between screens suits
  /// the person watching a line and ruins the afternoon of somebody working
  /// through a report on the same panel. It replaced the single
  /// `auto_navigate` switch in `alarm_man_config`, which was never carried
  /// over — every account starts off, and an administrator opts accounts in
  /// on the access page. The reserved anonymous account's value is what a
  /// logged-out panel does, and a station account's is what that panel does.
  ///
  /// Added on open by `_ensureAlarmAutoNavigateColumn` rather than by a schema
  /// arm, for the reason [sortOrder] gives: every existing row is correct as
  /// the default.
  BoolColumn get alarmAutoNavigate =>
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

/// **Do not regenerate `database_drift.g.dart` on this branch without checking
/// the drift version.** `pubspec.yaml` pins `sqlite3: ^2.9.0` — deliberately,
/// so `sqlite_loader.dart`'s `DynamicLibrary` path keeps working on the eLinux
/// stations — and that pin caps drift at 2.31.0. The committed generated file
/// was produced by drift_dev 2.34.x, and 2.31.0 emits neither the
/// `constraintIsAlways('REFERENCES ...')` column constraints nor the
/// `*References` classes: a regeneration under the pin silently drops every
/// foreign key from the schema `createAll` builds for a fresh database.
/// `test/core/access_schema_test.dart` is what catches it — `app_user.role_name
/// is a declared foreign key to app_role` fails — so if that test goes red
/// after a codegen run, the generated file is the suspect, not the schema.
///
/// `config_item` and `config_change` are declared in
/// `config/config_item_table.dart`, not here.
///
/// They are the tables this database shares with readers that must not link
/// open62541 — this library does, through `alarm.dart`. The declarations moved
/// there so those readers get a generated accessor without it; `AppDatabase`
/// names the same classes below and generates its own exactly as before, so
/// nothing about the schema, the migrations or [ConfigItemRow] changed.
/// `config_change` followed `config_item` when the consistency check
/// (`config/config_consistency.dart`) had to read the log beside the items
/// from inside the FFI-free barrel. See that file's header for the full
/// argument (D-3).

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
  // Relational configuration tables (schema v10; the NOTIFY trigger is v11
  // and the paging index v12):
  ConfigItemTable,
  ConfigChangeTable,
])
class AppDatabase extends _$AppDatabase implements McpDatabase {
  final DatabaseConfig config;
  AppDatabase._(this.config, QueryExecutor executor) : super(executor);

  /// Creates an in-memory SQLite [AppDatabase] for testing.
  @visibleForTesting
  factory AppDatabase.inMemoryForTest() => AppDatabase._(
        DatabaseConfig(),
        sqliteInMemory(logStatements: false),
      );

  /// An in-memory [AppDatabase] that outlives nothing — the relay gateway's
  /// configuration mirror.
  ///
  /// [ConfigStore] requires a local database because a station's mirror is
  /// how it serves the plant's configuration without a network round trip.
  /// The gateway has no such need and must not acquire one: it holds the
  /// authoritative Postgres connection already, and a second durable copy of
  /// the plant's configuration on the gateway is a second thing that can be
  /// stale. What it needs is somewhere for the store's post-commit mirror
  /// write to land, and this is it.
  ///
  /// Distinct from [AppDatabase.inMemoryForTest] on purpose, though the two
  /// are built the same way: that one is `@visibleForTesting` and means "no
  /// Postgres in this test", and a production caller reaching for it would
  /// be read as a test seam left switched on.
  ///
  /// **Constructing this dlopens libsqlite3**, which is why
  /// `docker/backend/Dockerfile` installs `libsqlite3-0` and why every caller
  /// here builds it inside a try/catch: on an image without the library the
  /// gateway must degrade to refusing configuration writes, never to failing
  /// to start.
  factory AppDatabase.ephemeral() => AppDatabase._(
        DatabaseConfig(),
        sqliteInMemory(logStatements: false),
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
  int get schemaVersion => 13;

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
    // The trail viewer's member count (`memberCountsByAction`) is
    // `WHERE action_id IN (<up to 500 ids>) GROUP BY action_id` on every page
    // open. Without this it is a whole-table scan of an append-only table that
    // retention never prunes — the bulk of the page's load time once the
    // table is large.
    'CREATE INDEX IF NOT EXISTS idx_audit_entry_action_id '
        'ON audit_entry (action_id)',
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
      logger.i('Schema v8: no alarm_history -> alarm foreign key present; '
          'nothing to drop');
      return;
    }
    for (final row in found) {
      final name = row.read<String>('name');
      logger.i('Schema v8: dropping alarm_history foreign key "$name"');
      await m.database.customStatement(
          'ALTER TABLE alarm_history DROP CONSTRAINT IF EXISTS "$name"');
    }
  }

  /// Re-assert the [_auditIndexStatements] indexes on every open.
  ///
  /// **Not a schema arm**, for the same reason [_seedAnonymousAccount] is not:
  /// every statement is `IF NOT EXISTS`, so an index added to the list after a
  /// database passed `from < 6` reaches it the first time a build that knows
  /// about the index opens it, with no version bump to collide with another
  /// branch's. On an already-indexed database each statement is a catalog
  /// lookup. The first open that does build one blocks audit inserts on that
  /// table for as long as the build takes, once.
  ///
  /// Never throws: a missing index makes the trail viewer slow, not wrong, and
  /// must not fail an open.
  Future<void> _ensureAuditIndexes() async {
    try {
      for (final stmt in _auditIndexStatements) {
        await customStatement(stmt);
      }
    } on Object catch (e) {
      logger.w('Could not ensure the audit_entry indexes: $e');
    }
  }

  /// Make sure `app_role` and `app_user` carry the nullable `sort_order`
  /// column the Access screen orders its two lists by.
  ///
  /// **Not a schema arm**, for the reason [_ensureAuditIndexes] is not: the
  /// column is display order only, every existing row is correct as NULL, and
  /// a version number would collide with another branch's arms. So it runs
  /// from `beforeOpen` on every open, on both backends, and the column arrives
  /// the first time a build that knows about it opens the database.
  ///
  /// Probed before it is added on both backends. SQLite has no
  /// `ADD COLUMN IF NOT EXISTS`, so the `PRAGMA table_info` check is what makes
  /// a second open harmless there. Postgres has it, and the
  /// `information_schema` probe in front of it keeps an already-migrated open
  /// from taking the `ALTER TABLE` lock at all — several stations share one
  /// database and each of them opens it. No test executes the Postgres half;
  /// `access_schema_test.dart` reads these literals out of the source.
  ///
  /// Never throws, and logs what it could not do: a missing display-order
  /// column must not fail an open. It does break every generated select over
  /// the two tables, which is why `beforeOpen` runs this before
  /// [_seedAnonymousAccount].
  Future<void> _ensureSortOrderColumns() async {
    for (final table in const ['app_role', 'app_user']) {
      try {
        if (await _hasSortOrderColumn(table)) continue;
        if (native) {
          await customStatement(table == 'app_role'
              ? 'ALTER TABLE app_role ADD COLUMN sort_order INTEGER'
              : 'ALTER TABLE app_user ADD COLUMN sort_order INTEGER');
        } else {
          await customStatement(table == 'app_role'
              ? 'ALTER TABLE app_role ADD COLUMN IF NOT EXISTS sort_order INTEGER'
              : 'ALTER TABLE app_user ADD COLUMN IF NOT EXISTS sort_order INTEGER');
        }
        logger.i('Added $table.sort_order');
      } on Object catch (e) {
        logger.w('Could not ensure $table.sort_order: $e');
      }
    }
  }

  /// Whether [table] already has `sort_order`.
  Future<bool> _hasSortOrderColumn(String table) =>
      _hasColumn(table, 'sort_order');

  /// Make sure `app_user` carries the nullable `home_page` column, the page an
  /// account's sessions open on.
  ///
  /// Not a schema arm, for every reason [_ensureSortOrderColumns] gives, and
  /// built the same way: probed first on both backends, never throws, logs
  /// what it could not do. `access_schema_test.dart` reads the Postgres
  /// literal out of the source.
  Future<void> _ensureHomePageColumn() async {
    try {
      if (await _hasColumn('app_user', 'home_page')) return;
      await customStatement(native
          ? 'ALTER TABLE app_user ADD COLUMN home_page TEXT'
          : 'ALTER TABLE app_user ADD COLUMN IF NOT EXISTS home_page TEXT');
      logger.i('Added app_user.home_page');
    } on Object catch (e) {
      logger.w('Could not ensure app_user.home_page: $e');
    }
  }

  /// Make sure `app_user` carries `alarm_auto_navigate`, whether a raising
  /// alarm takes the account's screen to its page. Built exactly like
  /// [_ensureHomePageColumn]. NOT NULL with a default, so every existing row
  /// lands off.
  Future<void> _ensureAlarmAutoNavigateColumn() async {
    try {
      if (await _hasColumn('app_user', 'alarm_auto_navigate')) return;
      await customStatement(native
          ? 'ALTER TABLE app_user ADD COLUMN alarm_auto_navigate INTEGER '
              'NOT NULL DEFAULT 0 CHECK (alarm_auto_navigate IN (0, 1))'
          : 'ALTER TABLE app_user ADD COLUMN IF NOT EXISTS alarm_auto_navigate BOOLEAN NOT NULL DEFAULT FALSE');
      logger.i('Added app_user.alarm_auto_navigate');
    } on Object catch (e) {
      logger.w('Could not ensure app_user.alarm_auto_navigate: $e');
    }
  }

  /// Whether [table] already has [column]. Both are literals from this file,
  /// never caller input, which is why they are interpolated.
  Future<bool> _hasColumn(String table, String column) async {
    if (native) {
      final cols = await customSelect("PRAGMA table_info('$table')").get();
      return cols.any((r) => r.read<String>('name') == column);
    }
    final rows = await customSelect(
      'SELECT 1 FROM information_schema.columns '
      "WHERE table_schema = current_schema() AND table_name = '$table' "
      "AND column_name = '$column'",
    ).get();
    return rows.isNotEmpty;
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

  /// The `config_item` and `config_change` indexes.
  ///
  /// `idx_config_item_scope_kind` is the one every read of this store goes
  /// through. The primary key leads with `kind`, so the actual query shape —
  /// `WHERE kind = ? AND scope = ?` — can only prefix-scan it; leading with
  /// `scope` is what makes "everything of kind K on this station" an index
  /// seek rather than a scan of every scope's rows.
  ///
  /// The two `config_change` indexes serve reads this phase does not yet
  /// perform (an entity's history, and the join back to an action). They go in
  /// now for the same reason the Postgres `CHECK` does: an index is cheapest
  /// to add before there is data to build it over.
  ///
  /// `IF NOT EXISTS` on both backends, for the same reason
  /// [_auditIndexStatements] uses it: several SVN stations share one database
  /// and each of them opens it.
  static const List<String> _configIndexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_config_item_scope_kind '
        'ON config_item (scope, kind)',
    'CREATE INDEX IF NOT EXISTS idx_config_change_entity '
        'ON config_change (kind, entity_id, scope, id)',
    'CREATE INDEX IF NOT EXISTS idx_config_change_action '
        'ON config_change (action_id)',
    // The history page's default read: `ORDER BY at DESC, id DESC LIMIT 500`
    // over a time window, on a table that is never pruned. Without this it is
    // a sequential scan plus a sort that grows for the life of the plant.
    'CREATE INDEX IF NOT EXISTS idx_config_change_at '
        'ON config_change (at DESC, id DESC)',
  ];

  /// Create the [_configIndexStatements] indexes.
  ///
  /// Called from `onCreate` and from the `from < 10` and `from < 12` upgrade
  /// branches, on both
  /// backends — the statements are identical on each, so they live in one
  /// place rather than being copied into both arms.
  /// The two config tables, as Postgres gets them: the raw literals with the
  /// `CHECK (scope = 'shared')`. Run by the v10 arm and by `onCreate`, so an
  /// upgraded plant and a freshly provisioned one carry the same constraint.
  Future<void> _createConfigTablesPostgres(Migrator m) async {
    await m.database.customStatement(
        'CREATE TABLE IF NOT EXISTS config_item (kind TEXT NOT NULL, id TEXT NOT NULL, scope TEXT NOT NULL, parent_id TEXT, sort_index INTEGER, payload TEXT NOT NULL, rev BIGINT NOT NULL DEFAULT 0, updated_at TEXT NOT NULL, updated_by TEXT NOT NULL, PRIMARY KEY (kind, id, scope), CONSTRAINT config_item_shared_only CHECK (scope = \'shared\'))');
    await m.database.customStatement(
        'CREATE TABLE IF NOT EXISTS config_change (id SERIAL PRIMARY KEY, at TEXT NOT NULL, action_id TEXT NOT NULL, who TEXT NOT NULL, station TEXT NOT NULL, role_name TEXT NOT NULL, reason TEXT, kind TEXT NOT NULL, entity_id TEXT NOT NULL, scope TEXT NOT NULL, op TEXT NOT NULL, old_value TEXT, new_value TEXT, CONSTRAINT config_change_shared_only CHECK (scope = \'shared\'))');
  }

  Future<void> _createConfigIndexes(Migrator m) async {
    for (final stmt in _configIndexStatements) {
      await m.database.customStatement(stmt);
    }
  }

  /// The `config_change` NOTIFY trigger — the server side of the change feed.
  ///
  /// **The payload is a constant empty string, and that is the whole design.**
  /// Postgres delivers one event per identical `(channel, payload)` pair
  /// signalled within a transaction, so a constant payload is exactly one
  /// notification per committed action however many rows that action wrote.
  /// It also makes the 8000-byte `pg_notify` cap structurally unreachable —
  /// and that cap does not truncate, it *errors the statement that fired the
  /// trigger*, which is to say it would fail the very save it is reporting.
  ///
  /// That is also why the key-carrying variant this class used to have — a
  /// trigger whose payload named the changed row — is gone rather than reused
  /// here. It made nine keys saved together into nine distinct payloads and
  /// nine deliveries, and this channel's receivers do not need to know which
  /// row moved: what follows an event is a `config_change.id` watermark pull
  /// that is the same read either way. Its one caller watched
  /// `flutter_preferences`; both retired in 04-12. The trigger and function it
  /// installed still exist on any plant it ever ran against, and
  /// `bin/drop_flutter_preferences.dart` is what removes them.
  ///
  /// `AFTER INSERT` only: `config_change` is append-only, so there is no
  /// UPDATE or DELETE to report. `FOR EACH STATEMENT` rather than
  /// `FOR EACH ROW`: with a constant payload the two are indistinguishable to
  /// a receiver, and the statement-level trigger fires once for a multi-row
  /// insert instead of once per row.
  ///
  /// `DROP TRIGGER IF EXISTS` followed by `CREATE`, not
  /// `CREATE OR REPLACE TRIGGER`, which needs PG14+ and buys nothing here.
  /// With `CREATE OR REPLACE FUNCTION` that makes the whole arm safe to run
  /// twice, which it has to be: several SVN stations share one database and
  /// each of them runs it when it opens.
  static const List<String> _configChangeNotifyStatements = [
    'CREATE OR REPLACE FUNCTION notify_config_change() RETURNS TRIGGER AS '
        '\$\$ BEGIN PERFORM pg_notify(\'config_change\', \'\'); RETURN NULL; END; \$\$ '
        'LANGUAGE plpgsql',
    'DROP TRIGGER IF EXISTS config_change_notify ON config_change',
    'CREATE TRIGGER config_change_notify AFTER INSERT ON config_change '
        'FOR EACH STATEMENT EXECUTE FUNCTION notify_config_change()',
  ];

  /// [_configChangeNotifyStatements] as the database would receive them.
  ///
  /// Exists because no test in this package can execute them — there is no
  /// Postgres in `test/core/` — so the only thing left to assert is their
  /// text, and asserting the *runtime* strings beats reading them back out of
  /// the source: the source carries Dart's escaping and an adjacent-literal
  /// concatenation, and a test that matched that text would be matching the
  /// spelling rather than the statement.
  @visibleForTesting
  static List<String> get configChangeNotifyStatementsForTest =>
      _configChangeNotifyStatements;

  /// Install [_configChangeNotifyStatements] — **on Postgres only**.
  ///
  /// Called from `onCreate` and from the `from < 11` upgrade branch, the way
  /// [_createConfigIndexes] is called from both, so a database that was
  /// created at v9 and one that was upgraded to it agree. Without the
  /// `onCreate` call a freshly created Postgres would simply never notify, and
  /// the symptom would be "one station's edits do not reach the others" with
  /// nothing in any log to say why.
  ///
  /// **The asymmetry is deliberate.** SQLite has no LISTEN/NOTIFY to install
  /// this on, and the local file has one writer — the station itself, which
  /// already knows what it wrote. There is nobody there to tell.
  ///
  /// The backend is read off `executor.dialect` rather than through [postgres]
  /// (`executor is PgDatabase`), which is **false on every station**: the app
  /// opens its database with [AppDatabase.spawn] and the main-isolate executor
  /// is a drift remote proxy, not a `PgDatabase`. A migration runs inside the
  /// isolate, where that getter would in fact work — the dialect check is used
  /// anyway so this codebase has one rule for reading the backend and not two.
  ///
  /// **No test executes the Postgres arm**, exactly as the `from < 6` and
  /// `from < 10` arms say of their own. The inherited gap is recorded in
  /// `.planning/phases/01-identity-and-audit/deferred-items.md` §1 and is
  /// still open. What stands behind these three statements is a read of the
  /// Postgres documentation and the `config_change` DDL directly above; the
  /// first thing that will run them is a station.
  Future<void> _createConfigChangeNotifyTrigger(Migrator m) async {
    if (m.database.executor.dialect != SqlDialect.postgres) return;
    for (final stmt in _configChangeNotifyStatements) {
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
  /// These are ordinary rows once written: editable, renamable and deletable
  /// like any other.
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

  /// Make sure the reserved anonymous account exists and cannot be signed in
  /// to.
  ///
  /// **Not a schema arm.** It runs from `onCreate` and from `beforeOpen`, which
  /// drift calls on every open after any upgrade, on both backends — so a
  /// database at any schema version gets the row the first time a build that
  /// knows about it opens it, and a row an older build deleted comes back on
  /// the next open.
  ///
  /// Three steps:
  ///
  ///  1. Without an `Operator` role there is nothing to seed onto — the
  ///     Postgres foreign key would refuse the insert — so log and stop.
  ///     `AccessRepository.anonymousAccount` covers a station in that state.
  ///  2. Insert the row on `Operator` with `ON CONFLICT DO NOTHING`, the same
  ///     idiom and for the same reason as [_seedAccessRoles]: several stations
  ///     open one Postgres, and an existing row's roles and pages are customer
  ///     data a re-run must not reset.
  ///  3. Re-assert the columns an older build's accounts screen could have
  ///     changed — the credential, the station flag, the timeout — and never
  ///     the roles or the whitelist. A person's account that happened to be
  ///     named `anonymous` before the name was reserved is adopted this way:
  ///     it keeps its roles, loses its password, and becomes the panel.
  ///
  /// Never throws: a failed seed must not fail an open.
  Future<void> _seedAnonymousAccount() async {
    try {
      final operator = await (select(appRole)
            ..where((t) => t.name.equals(kOperatorRoleName)))
          .getSingleOrNull();
      final existing = await (select(appUser)
            ..where((t) => t.username.equals(kAnonymousUsername)))
          .getSingleOrNull();
      if (existing == null) {
        if (operator == null) {
          logger.w('No "$kOperatorRoleName" role to seed the '
              '"$kAnonymousUsername" account onto — logged-out panels fall '
              'back to the seeded floor until one exists.');
          return;
        }
        await into(appUser).insert(
          AppUserCompanion.insert(
            username: kAnonymousUsername,
            roleName: kOperatorRoleName,
            passwordHash: kAnonymousPasswordSentinel,
            salt: kAnonymousSaltSentinel,
            createdAt: DateTime.now().toUtc(),
          ),
          onConflict: DoNothing(),
        );
        return;
      }
      final drifted = existing.passwordHash != kAnonymousPasswordSentinel ||
          existing.salt != kAnonymousSaltSentinel ||
          existing.stationAccount ||
          existing.inactivityTimeoutMinutes != null;
      if (!drifted) return;
      if (existing.passwordHash != kAnonymousPasswordSentinel) {
        logger.w('The "$kAnonymousUsername" account carried a password — '
            'removing it. That name is reserved for every logged-out panel and '
            'cannot be signed in to.');
      }
      await (update(appUser)
            ..where((t) => t.username.equals(kAnonymousUsername)))
          .write(const AppUserCompanion(
        passwordHash: Value(kAnonymousPasswordSentinel),
        salt: Value(kAnonymousSaltSentinel),
        stationAccount: Value(false),
        inactivityTimeoutMinutes: Value(null),
      ));
    } on Object catch (e) {
      logger.w('Could not seed the "$kAnonymousUsername" account: $e');
    }
  }

  /// Re-run [_seedAnonymousAccount] from a test.
  @visibleForTesting
  Future<void> seedAnonymousAccountForTest() => _seedAnonymousAccount();

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await _ensureAuditIndexes();
          // Before the seed, and the order is load-bearing: the seed selects
          // `app_user` through the generated mapping, which reads `sort_order`.
          // On a database that does not have the column yet that select
          // throws, the seed swallows it, and the anonymous account is not
          // put back.
          await _ensureSortOrderColumns();
          // Before the seed for the same reason: `home_page` is read by the
          // same generated mapping.
          await _ensureHomePageColumn();
          await _ensureAlarmAutoNavigateColumn();
          await _seedAnonymousAccount();
        },
        onCreate: (m) async {
          // On Postgres the two config tables go up from the raw literals
          // first, so that `createAll`'s `IF NOT EXISTS` finds them and a
          // freshly provisioned plant gets the `CHECK (scope = 'shared')` the
          // upgrade path installs. Built from the drift classes alone they
          // would lack it: the classes carry no CHECK on purpose, because the
          // same declaration is SQLite's, where station rows must be allowed.
          if (m.database.executor.dialect == SqlDialect.postgres) {
            await _createConfigTablesPostgres(m);
          }
          await m.createAll();
          await _createAuditIndexes(m);
          await _createAccessBindingIndexes(m);
          await _createAlarmHistoryOpenRowIndex(m);
          await _createConfigIndexes(m);
          await _createConfigChangeNotifyTrigger(m);
          await _seedAccessRoles();
          await _seedAnonymousAccount();
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
                  'CREATE TABLE IF NOT EXISTS app_role (name TEXT PRIMARY KEY, groups TEXT NOT NULL, seeded BOOLEAN NOT NULL DEFAULT FALSE, allowed_pages TEXT)');
              await m.database.customStatement(
                  'CREATE TABLE IF NOT EXISTS app_user (username TEXT PRIMARY KEY, role_name TEXT NOT NULL REFERENCES app_role(name), password_hash TEXT NOT NULL, salt TEXT NOT NULL, created_at TEXT NOT NULL, last_login_at TEXT, station_account BOOLEAN NOT NULL DEFAULT FALSE, allowed_pages TEXT)');
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

          // The page-visibility whitelist, at both levels. One nullable column
          // per identity table and nothing else: every existing row — the four
          // seeded roles included — upgrades to NULL, which is "no whitelist"
          // on a role and "follow the role" on a user, so a station that
          // upgrades behaves identically until somebody turns the mode on.
          // See `docs/page-visibility-whitelist-design.md` §2.
          //
          // A station that ran the v6 arm above in this same upgrade already
          // has both columns, because the CREATE TABLE literals there carry
          // them. `addColumn` on SQLite would then fail, and the Postgres
          // `IF NOT EXISTS` would be a no-op — so the SQLite side is guarded
          // by `from >= 6` rather than by hoping the order works out.
          // **Guarded by whether the column exists, and open until v10, not
          // `from < 7` with `from >= 6`.** A version comparison is only right
          // in the merge order it was written for, and this arm has already
          // been through the other one: a build of the relational-config
          // branch stamped `user_version` 7 and 8 for its own arms before
          // main took those numbers for this column and the next. A database
          // from such a build opens with `from == 8`, both those arms
          // skipped, and every `app_user` read failing on a column no later
          // upgrade would ever add. The v8 and v9 arms below were written
          // with the probe from the start, for exactly this reason; this one
          // now matches them, and all three run for anything below the first
          // version the merged line stamped (10).
          if (from < 10) {
            if (native) {
              for (final (table, column) in const [
                ('app_role', 'allowed_pages'),
                ('app_user', 'allowed_pages'),
              ]) {
                final cols = await m.database
                    .customSelect("PRAGMA table_info('$table')")
                    .get();
                if (cols.any((r) => r.read<String>('name') == column)) continue;
                if (table == 'app_role') {
                  await m.addColumn(appRole, appRole.allowedPages);
                } else {
                  await m.addColumn(appUser, appUser.allowedPages);
                }
              }
            } else {
              // Raw `IF NOT EXISTS` DDL, and the v6 arm's warning applies
              // unchanged: several SVN stations share one Postgres database
              // and each of them runs this branch when it opens, so it has to
              // be safe to run twice. No test executes this arm — what stands
              // behind these two strings is the source-derived column-parity
              // check in `access_schema_test.dart`.
              await m.database.customStatement(
                  'ALTER TABLE app_role ADD COLUMN IF NOT EXISTS allowed_pages TEXT');
              await m.database.customStatement(
                  'ALTER TABLE app_user ADD COLUMN IF NOT EXISTS allowed_pages TEXT');
            }
          }

          // The inactivity timeout, per account. One nullable column; every
          // existing account upgrades to NULL, which is the fifteen-minute
          // default it already had.
          //
          // Guarded by whether the column exists rather than by `from >= N`,
          // unlike the v7 arm above. Three things can already have put it
          // there: the v6 arm's `createTable` in this same upgrade (SQLite
          // builds it from the table definition, which carries the column), a
          // second station opening the shared Postgres, and a branch that
          // lands its own arms around this one and renumbers it. An existence
          // check is right in every merge order; a version comparison is only
          // right in the one it was written for.
          // `from < 10` rather than `< 8`, for the reason the arm above gives:
          // a database stamped 8 or 9 by a pre-merge build of the branch has
          // never run this arm, and the probe makes the wider window free.
          if (from < 10) {
            if (native) {
              final cols = await m.database
                  .customSelect("PRAGMA table_info('app_user')")
                  .get();
              final present = cols.any(
                  (r) => r.read<String>('name') == 'inactivity_timeout_minutes');
              if (!present) {
                await m.addColumn(appUser, appUser.inactivityTimeoutMinutes);
              }
            } else {
              // Not in the v6 CREATE TABLE literal on purpose: a v5 Postgres
              // station creates the table there and gets the column here, in
              // the same open. No test executes this arm — the parity check in
              // `access_schema_test.dart` is what stands behind the string.
              await m.database.customStatement(
                  'ALTER TABLE app_user ADD COLUMN IF NOT EXISTS inactivity_timeout_minutes INTEGER');
            }
          }

          // The extra roles an account holds beyond its primary one. One
          // nullable column; every existing account upgrades to NULL, which is
          // "holds only its primary role" — exactly the single-role account it
          // already was.
          //
          // Guarded by an existence check rather than by `from >= N`, for the
          // reason the v8 arm above gives at length: the v6 arm's
          // `createTable` in this same upgrade builds `app_user` from the table
          // definition, which carries this column, and a second station opening
          // the shared Postgres runs this branch too.
          if (from < 10) {
            if (native) {
              final cols = await m.database
                  .customSelect("PRAGMA table_info('app_user')")
                  .get();
              final present =
                  cols.any((r) => r.read<String>('name') == 'additional_roles');
              if (!present) {
                await m.addColumn(appUser, appUser.additionalRoles);
              }
            } else {
              // Not in the v6 CREATE TABLE literal on purpose, following v8: a
              // v5 Postgres station creates the table there and gets the column
              // here, in the same open. No test executes this arm — the parity
              // check in `access_schema_test.dart` is what stands behind the
              // string.
              await m.database.customStatement(
                  'ALTER TABLE app_user ADD COLUMN IF NOT EXISTS additional_roles TEXT');
            }
          }

          // Schema v10: the relational configuration store — `config_item`
          // holds every configuration entity as one row, `config_change` is
          // its append-only log.
          //
          // Both tables go up on **both** backends now, before either holds a
          // row. Phase 1 writes only station-scoped rows, into SQLite, and
          // touches no Postgres read or write path at all — but the `CHECK`
          // and the three indexes below are cheapest to add to an empty table,
          // and an empty table is exactly what a shared Postgres has today.
          //
          // **The `CHECK (scope = 'shared')` is Postgres-only, and that
          // asymmetry is the point.** The invariant it makes structural is
          // that a `station:<hostname>` row never leaves the machine that
          // wrote it — the rows at that scope are a station's own endpoints
          // and its own local state, and repository code declining to write
          // them centrally is a guarantee that lasts until somebody writes a
          // second repository. A constraint lasts longer. The SQLite side must
          // **not** carry it: station-scoped rows are the only rows a local
          // file will ever hold, so the same constraint there would reject
          // everything this phase writes.
          //
          // Datetimes are TEXT on both backends — `updated_at` and `at` are
          // declared `TEXT`, not `TIMESTAMPTZ`. This database sets
          // `DriftDatabaseOptions(storeDateTimeAsText: true)` (see the
          // `options` override) and the root `build.yaml` sets
          // `store_date_time_values_as_text: true`, so drift reads an ISO
          // string out of these columns and a `TIMESTAMPTZ` would fail on the
          // first row. Every existing Postgres arm above writes TEXT for the
          // same reason. `docs/relational-config-research.md` §3.1 sketches
          // `TIMESTAMPTZ`; that sketch is wrong for this database.
          //
          // `parent_id` carries no `REFERENCES`, deliberately — see
          // [ConfigItemTable.parentId].
          //
          // `rev` is `integer()` on the drift side and `BIGINT` here: drift's
          // postgres dialect maps `integer()` to `bigint` already, and
          // `int64()` would change the Dart type to `BigInt`.
          //
          // **No test executes the Postgres arm**, exactly as the `from < 6`
          // arm above says of its own. Phase 1 of the previous milestone
          // recorded that gap on 2026-08-28 in
          // `.planning/phases/01-identity-and-audit/deferred-items.md` §1 and
          // it is still open; this phase inherits it rather than closing it.
          // What stands behind these two statements is the source-derived
          // column-parity test in `access_key_binding_table_test.dart`, which
          // compares these string literals against the drift tables and
          // nothing more — it does not connect to Postgres and cannot see a
          // wrong type or a statement that fails at runtime. The first thing
          // that will actually run them is a station.
          // `from < 13` rather than `< 10`, and probed rather than
          // unconditional — the same widening this file has already applied
          // twice above, one merge further along. `10` was written when it was
          // the first version the merged line stamped. It is not any more:
          // pre-merge builds of the relay-pipe branch stamped `user_version`
          // 10 for *their* v10, which is the `alarm_history` arm at the bottom
          // of this method and has nothing to do with configuration. A
          // database from such a build opens at `from == 10`, skips this arm,
          // and every `config_item` read fails on a table no later upgrade
          // would ever create — the exact failure the two arms above widened
          // to avoid, with the branches swapped.
          //
          // Widening needs the probe: on SQLite `m.createTable` is a bare
          // `CREATE TABLE` and a station already carrying the tables would
          // abort the migration on it. Postgres needs nothing new — that path
          // has been `IF NOT EXISTS` since it was written.
          if (from < 13) {
            if (native) {
              final existing = await m.database
                  .customSelect(
                      "SELECT name FROM sqlite_master WHERE type = 'table'")
                  .get();
              final present = {
                for (final r in existing) r.read<String>('name'),
              };
              if (!present.contains(configItemTable.actualTableName)) {
                await m.createTable(configItemTable);
              }
              if (!present.contains(configChangeTable.actualTableName)) {
                await m.createTable(configChangeTable);
              }
            } else {
              // PostgreSQL: raw `IF NOT EXISTS` DDL rather than
              // `m.createTable`, following the two arms above. Several SVN
              // stations share one Postgres database and every one of them
              // runs this branch when it opens, so it has to be safe to run
              // twice — otherwise the second station aborts the migration and
              // leaves the database half-upgraded.
              await _createConfigTablesPostgres(m);
            }
            await _createConfigIndexes(m);
          }

          // Schema v11: the `config_change` NOTIFY trigger — the server half of
          // "another station's edit arrives without a restart". v10 gave the log
          // a place to live; this makes writing to it tell anyone listening.
          //
          // The arm is Postgres-only and the SQLite side is deliberately
          // nothing at all, which is why it is one call rather than an
          // `if (native)` pair like the two arms above: the asymmetry is the
          // whole content of the arm, so it is stated once, in
          // [_createConfigChangeNotifyTrigger], instead of being spread across
          // a branch here and a comment there.
          //
          // No table changed, so no codegen: v11 is DDL that lives outside the
          // drift schema entirely, the way the indexes above do.
          if (from < 11) {
            await _createConfigChangeNotifyTrigger(m);
          }

          // Schema v12: `idx_config_change_at`, the history page's paging
          // index, which joined `_configIndexStatements` after v11 had
          // already stamped databases. Re-running the (idempotent) index
          // creation inside an earlier arm reaches no database that has
          // passed it; a version of its own does.
          if (from < 12) {
            await _createConfigIndexes(m);
          }

          // **This arm has been renumbered three times and the number is not
          // the point.** It was v7 on this branch, became v8 when main's
          // page-visibility whitelist (#495) took 7, v10 when main also took 8
          // (per-account inactivity timeout, #505) and 9 (additional roles,
          // #512), and is v13 now that relational configuration (#465) has
          // taken 10, 11 and 12. Each time the rule was the same and it is
          // main's: whichever arm shipped first keeps its number, and this one
          // moves up. That is also the safe direction — a station that has run
          // the earlier arms gets this one on its next open, and one that has
          // run none of them gets them all in order.
          //
          // The existence guard below is what makes a fourth renumber free,
          // and this arm is now the case that reasoning was written for.
          //
          // Schema v13: `alarm_history` becomes writable, and an open
          // activation row becomes a thing the database can hold exactly one
          // of. See 14-CONTEXT D-5.
          //
          // **This is the first migration arm in this repository with an
          // executed Postgres test** — `test/integration/alarm_schema_v8_test
          // .dart` (named for the version it was written at), fourteen legs
          // against a real server, half of them against a v6 shape built by
          // hand and lifted through this branch. The v6 comment above records
          // that no test had ever run one. This arm does not inherit that.
          if (from < 13) {
            if (native) {
              // Guarded by whether the columns exist rather than by
              // `from >= N`, which is the convention main's v8 arm above sets
              // out and the reasoning holds here verbatim: an existence check
              // is right in every merge order, a version comparison only in
              // the one it was written for. This arm has now been renumbered
              // three times, which is the case that reasoning is about.
              //
              // SQLite has no `ADD COLUMN IF NOT EXISTS` and no
              // `DROP CONSTRAINT`. Neither matters here:
              //
              // * A SQLite database is per-process, so nothing else is racing
              //   this branch.
              // * The `alarm_uid -> alarm(uid)` foreign key is already inert.
              //   Drift never issues `PRAGMA foreign_keys = ON` and nothing in
              //   this package sets it in a `beforeOpen`, so SQLite has been
              //   accepting these inserts all along — which is exactly why the
              //   Postgres-only defect survived so long. Rebuilding the table
              //   to remove a constraint that is not enforced would be a
              //   copy-and-swap of the plant's history for no behavioural
              //   change; it is deliberately not done.
              final cols = await m.database
                  .customSelect("PRAGMA table_info('alarm_history')")
                  .get();
              final present = {
                for (final r in cols) r.read<String>('name'),
              };
              for (final (column, stmt) in const [
                ('rule_index',
                    'ALTER TABLE alarm_history ADD COLUMN rule_index INTEGER'),
                ('ts_source',
                    'ALTER TABLE alarm_history ADD COLUMN ts_source TEXT'),
                ('deactivated_reason',
                    'ALTER TABLE alarm_history ADD COLUMN deactivated_reason TEXT'),
              ]) {
                if (present.contains(column)) continue;
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
              // schema mismatch. Measured — `alarm_schema_v8_test.dart`'s
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

  // The web branch had these as `isSqliteExecutor(executor)` and
  // `executor is PgDatabase`. Main's dialect reads supersede both and are the
  // stricter answer on every platform: the type tests were the D-1 defect —
  // false on every station, because the app opens its database through a
  // DriftIsolate and holds a remote proxy — and `executor.dialect` is a
  // web-safe drift API that also takes the last `PgDatabase` reference out of
  // this file. `isSqliteExecutor` therefore has no caller left and goes with
  // it; the rest of `sqlite_executor.dart` stays, because keeping
  // `drift/native` out of the closure is what that seam is actually for.
  /// Whether this database is Postgres.
  ///
  /// Read off the executor's dialect, as [native] is, and for the same
  /// reason: `executor is PgDatabase` was false on every station, because the
  /// app opens its database through a DriftIsolate and the executor it holds
  /// is a remote proxy. See D-1 in `docs/relational-config-deferred-defects.md`
  /// for the one site that read the old value and what it did there.
  bool get postgres => executor.dialect == SqlDialect.postgres;

  /// Whether this database is SQLite — the local mirror, or a test.
  ///
  /// Read off the executor's dialect and **not** `executor is NativeDatabase`,
  /// which is what this was: [createLocal] opens the mirror through
  /// `NativeDatabase.createInBackground`, whose executor is a
  /// `DatabaseConnection` over a lazy delegate and never a `NativeDatabase`,
  /// so the old test was false for every `config.sqlite` the app opens. The
  /// migration arms branch on this, and the first upgrade of a local mirror
  /// would have run the Postgres DDL against SQLite — including a
  /// `CHECK (scope = 'shared')` that rejects every row a station owns. The
  /// same trap [postgres] documents against itself, one dialect over.
  bool get native => executor.dialect == SqlDialect.sqlite;

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
      // A local SQLite file, opened through the seam in
      // `sqlite_executor.dart` so this library does not import `dart:ffi`.
      final executor = sqliteInBackground(
        file,
        logStatements: config.debug,
      );
      return AppDatabase._(config, executor);
    }
    throw Exception("Unable to create database");
  }

  /// Factory: the device-local configuration store, `config.sqlite` in
  /// [folder].
  ///
  /// This is the one construction point for the local store. Four things
  /// about it are surprising enough to be worth stating here:
  ///
  /// **It is a second [AppDatabase], not a smaller purpose-built database.**
  /// This repo generates drift monolithically, so listing [ConfigItemTable] in
  /// a second `@DriftDatabase` would emit a second, distinct `ConfigItemRow`
  /// class — and the Phase 2 mirror, which wants to be a row copy between two
  /// instances of one schema, would become a field-by-field translation
  /// between two same-named incompatible types. The cost of the choice is the
  /// next paragraph.
  ///
  /// **A fresh local file runs the full `onCreate`**, so it gets ~30 tables
  /// the station will never read locally and four rows in a local `app_role`
  /// from `_seedAccessRoles`. That is harmless — the seed is
  /// `onConflict: DoNothing()` and nothing reads local `app_role` — but a
  /// reader finding those rows would reasonably conclude the access system
  /// keeps a local copy. It does not.
  ///
  /// **Never point the collector at this instance.** [tableExists] queries
  /// `information_schema`, which SQLite does not have, so it is permanently
  /// false here and the write path would treat the database as down forever.
  ///
  /// **Callers hold this [AppDatabase] directly**, not through the [Database]
  /// wrapper: the wrapper picks `spawn`/`create` on `config.postgres != null`
  /// and passes no `sqliteFolder`, so it throws for a SQLite config.
  static AppDatabase createLocal(Directory folder,
      {bool logStatements = false}) {
    // Through the seam, so this file names no FFI type. The two callbacks
    // that used to sit here — the sqlite3 library override and the WAL /
    // busy_timeout pragmas — moved with it; `setup` takes sqlite3's own
    // `Database`, which is FFI-bound and unnameable in a web build.
    final executor = sqliteLocalMirror(
      File(p.join(folder.path, 'config.sqlite')),
      logStatements: logStatements,
    );
    return AppDatabase._(DatabaseConfig(), executor);
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
      // `connect()` and never the deprecated synchronous `remote()`: the
      // remote executor reports the server's dialect only after the
      // isolate's handshake, which `connect()` awaits. `native` and
      // `postgres` read that dialect, and the migration arms branch on it —
      // a proxy that still answered "sqlite" here would run the SQLite DDL
      // against the plant's Postgres.
      final executor = await isolate.connect();
      final db = AppDatabase._(config, executor);
      db._driftIsolate = isolate;
      db._healthPort = healthPort;
      return db;
    } else if (sqliteFolder != null) {
      final dbFolder = sqliteFolder;
      final file = File(p.join(dbFolder.path, 'db.sqlite'));
      // A local SQLite file, opened through the seam in
      // `sqlite_executor.dart` so this library does not import `dart:ffi`.
      final executor = sqliteInBackground(
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

  /// Sends one notification on [channelName] — the writer's side of
  /// [listenToChannel].
  ///
  /// Exists for the one thing a trigger cannot do: announce a write that left
  /// no row for a trigger to fire on. `ConfigStore` uses it after a commit
  /// that touched a history-exempt item, because those write no `config_change`
  /// row and are therefore invisible to the `AFTER INSERT` trigger and to the
  /// `config_change.id` watermark both.
  ///
  /// The channel and the payload are **bound variables**, never interpolated:
  /// both are constructed in this tree today, and a `pg_notify` built by
  /// string concatenation is one refactor away from being an injection.
  ///
  /// A no-op off Postgres, gated on `executor.dialect` rather than
  /// [postgres] — that getter is false on every station, because the app opens
  /// its database through [AppDatabase.spawn] and the executor is a
  /// DriftIsolate remote. SQLite has no LISTEN/NOTIFY and the local file has
  /// one writer, so there is nobody there to tell.
  Future<void> notifyChannel(String channelName, String payload) async {
    if (executor.dialect != SqlDialect.postgres) return;
    await customStatement(
        r'SELECT pg_notify($1, $2)', [channelName, payload]);
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
  /// a table with large values — `config_item` holds a whole page, image and
  /// all, in one row — would therefore make every save of that row fail
  /// outright. This payload stays a few dozen bytes regardless of row size:
  /// `{"action": TG_OP, "key": <keyColumn>}`.
  ///
  /// **Not the same thing as `config_change_notify`**, and the two coexist on
  /// purpose. Main's trigger is on `config_change`, fires once per statement
  /// and carries an empty payload: "something changed, re-read". That is what
  /// a backend wanting to know whether to restart needs. This one is on the
  /// live table and names the key, which is what a per-key fan-out needs —
  /// `PreferenceChangeFeed` tells each relay client about the keys it asked
  /// for, and cannot do that from a signal that does not say which key moved.
  /// Different tables, different questions; neither replaces the other.
  ///
  /// It was deleted on main with `flutter_preferences`, the only table it was
  /// used on there. It comes back because the relay's feed still needs it, now
  /// pointed at `config_item`.
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
