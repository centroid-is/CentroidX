/// The `config_item` and `config_change` tables, declared where a process
/// without a GPU, a PLC stack or a Flutter binding can still read them.
///
/// ## Why this file exists rather than the table living in `database_drift.dart`
///
/// `database_drift.dart` imports `alarm.dart`, which imports `state_man.dart`,
/// which links open62541. Any file that needs `$ConfigItemTableTable` from
/// there therefore links a native library — which is exactly the defect D-3
/// records against the MCP server's config path, and re-running it for the
/// pages read would have put open62541 into `tfc_dart_core.dart` itself, the
/// barrel whose whole purpose is to not have it.
///
/// So the [Table] subclasses live here, in a library whose only import is
/// drift's pure-Dart core. [ConfigChangeTable] joined [ConfigItemTable] for
/// the same reason one step later: `config_consistency.dart` compares an item
/// against the newest change for it, which is a read of both tables at once,
/// and it is exported from `tfc_dart_core.dart`. `AppDatabase` imports the class from this file and
/// generates its own accessor exactly as before, so the app's schema, its
/// migrations and its row class are unchanged; this file's own
/// [ConfigItemSchema] generates a second accessor over the *same declaration*
/// for the readers that must stay FFI-free.
///
/// Two generated accessors, one declaration. That is the arrangement
/// `mcp_tables.dart` already has with `ServerDatabase` — a table declared once
/// and generated per database — and it is what keeps "the shape of a
/// `config_item` row" a single fact rather than two that can drift apart.
///
/// ## [ConfigItemSchema] is never opened
///
/// It exists because drift only generates a table accessor for a table some
/// `@DriftDatabase` names. Nothing constructs it, nothing migrates it, and it
/// owns no file: the accessor it generates is attached to whatever
/// [GeneratedDatabase] a caller hands over — see `page_rows.dart`.
library;

import 'package:drift/drift.dart';

part 'config_item_table.g.dart';


/// One configuration entity, whatever kind it is. Drift stores it as
/// `config_item`.
///
/// The columns mirror `ConfigItem` in `core/config/config_item.dart`, which is
/// the source of truth for the list — this table is its storage, not a second
/// definition of the shape. `updatedAt` and `updatedBy` are nullable *there*
/// because a `ConfigItem` that has not been stored yet has neither; a row, by
/// definition, has been stored, so both are `NOT NULL` here.
///
/// The payload stays JSON. One generic table rather than a table per kind is
/// the settled design decision (`docs/relational-config-research.md` §3.1):
/// the reads this store serves are all "everything of kind K at scope S", and
/// a column per kind's fields would buy nothing for them while costing a
/// migration per new kind.
@DataClassName('ConfigItemRow')
class ConfigItemTable extends Table {
  /// See [AccessTemplateTable.tableName] for why this is spelled out: drift
  /// does not strip a trailing `Table`, and the `Table` suffix on the class
  /// has to stay because `ConfigItem` is the value type in `core/config/`.
  @override
  String get tableName => 'config_item';

  /// `(kind, id, scope)`, so the same entity can exist once per scope: a
  /// station-scoped override and the shared row it overrides are two rows,
  /// not a conflict.
  @override
  Set<Column> get primaryKey => {kind, id, scope};

  /// `ConfigKind.wireName` — the entity's type.
  TextColumn get kind => text()();

  /// The entity's own id, unique within its kind and scope.
  TextColumn get id => text()();

  /// `'shared'` or `'station:<hostname>'`, and the column that carries
  /// ownership: shared rows are Postgres-owned, station rows never leave the
  /// machine that wrote them. On Postgres a `CHECK` makes that structural —
  /// see the `from < 7` arm. Here it deliberately does not, because station
  /// rows are the only rows a local SQLite file will ever hold.
  TextColumn get scope => text()();

  /// The entity this one belongs to — an asset's page id — or null when the
  /// kind has no parent. **No `REFERENCES`**, deliberately: see
  /// `ConfigItem.parentId`'s doc. An asset outlives its page during a move,
  /// and a constraint would turn a reorder into a delete and re-insert that
  /// the change log would report as a destroy and recreate.
  TextColumn get parentId => text().nullable()();

  /// Position among siblings, for kinds where order is meaning — a page's
  /// asset list is paint order. Null for kinds that are a set.
  IntColumn get sortIndex => integer().nullable()();

  /// The entity's own JSON, canonically encoded.
  TextColumn get payload => text()();

  /// Monotonic write counter, zero for a row written by a migration that had
  /// no counter to carry.
  ///
  /// `integer()`, not `int64()`: drift's postgres dialect already maps
  /// `integer()` to `bigint`, whereas `BigIntColumn` would change the *Dart*
  /// type to `BigInt` and break every arithmetic use of a revision number.
  IntColumn get rev => integer().withDefault(const Constant(0))();

  /// When the row was last written. TEXT on both backends — this database
  /// sets `storeDateTimeAsText: true`; see the note on [AppDatabase.options].
  DateTimeColumn get updatedAt => dateTime()();

  /// Username of whoever last wrote it, or `'anonymous'`.
  TextColumn get updatedBy => text()();
}

/// One append-only entry in the configuration change log. Drift stores it as
/// `config_change`.
///
/// The columns mirror `ConfigChange` in `core/config/config_change.dart`.
///
/// **A station-scoped change gets a row here and nowhere else.** It does not
/// reach the central `audit_entry` table, and this is a decision rather than
/// an omission: forwarding one would need a store-and-forward queue for the
/// hours a station spends unable to reach Postgres, and this milestone
/// declines to build that. Said out loud here because "the same audit trail"
/// would otherwise read as a promise the design does not keep.
@DataClassName('ConfigChangeRow')
class ConfigChangeTable extends Table {
  /// See [AccessTemplateTable.tableName]; `ConfigChange` is likewise taken by
  /// the value type in `core/config/`.
  @override
  String get tableName => 'config_change';

  /// Surrogate, and per-database: the SQLite log and the Postgres log are two
  /// independent id spaces and are not reconciled. Nothing joins them.
  IntColumn get id => integer().autoIncrement()();

  /// When the change was made. TEXT on both backends, as [ConfigItemTable]'s
  /// `updatedAt` is.
  DateTimeColumn get at => dateTime()();

  /// Groups the rows written by one user action, so a save that touched nine
  /// assets reads as one operation rather than nine.
  TextColumn get actionId => text()();

  /// Username, or `'anonymous'`.
  TextColumn get who => text()();

  /// The hostname the change was made on.
  TextColumn get station => text()();

  /// The role that authorised it, as it was named at the time.
  TextColumn get roleName => text()();

  /// Free text from the operator, when the surface asked for one.
  TextColumn get reason => text().nullable()();

  /// `ConfigKind.wireName` of the entity that changed.
  TextColumn get kind => text()();

  /// The changed entity's id — `config_item.id`, matched by value and with no
  /// foreign key, because the log outlives the row it describes: a delete's
  /// own entry would be unstorable otherwise.
  TextColumn get entityId => text()();

  /// The changed entity's scope.
  TextColumn get scope => text()();

  /// `ConfigChangeOp.wireName` — create, update or delete.
  TextColumn get op => text()();

  /// The payload before, null on a create.
  TextColumn get oldValue => text().nullable()();

  /// The payload after, null on a delete.
  TextColumn get newValue => text().nullable()();
}

/// A schema-only database, declared so drift generates
/// [$ConfigItemTableTable] and [$ConfigChangeTableTable] in this FFI-free
/// library.
///
/// It is never instantiated and never opened **in production**. `AppDatabase`
/// remains the only thing that creates or migrates either table; this class
/// exists purely to give the generator a database to hang the accessors off,
/// and they are then pointed at a real [GeneratedDatabase] by the reads in
/// `page_rows.dart` and `config_consistency.dart`. Tests do open it, over an
/// in-memory SQLite, because opening it is what proves those reads run without
/// linking open62541.
@DriftDatabase(tables: [ConfigItemTable, ConfigChangeTable])
class ConfigItemSchema extends _$ConfigItemSchema {
  ConfigItemSchema(super.e);

  @override
  int get schemaVersion => 1;
}
