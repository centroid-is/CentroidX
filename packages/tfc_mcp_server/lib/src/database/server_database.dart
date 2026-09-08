import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:tfc_dart/tfc_dart_core.dart' show McpDatabase;

import 'server_database_config.dart';

part 'server_database.g.dart';

// ---------------------------------------------------------------------------
// Table definitions mirroring tfc_dart schema (read-only for MCP server).
// These are independent Drift table classes -- not re-exports of tfc_dart's
// classes -- to avoid transitive FFI dependencies from alarm.dart.
// ---------------------------------------------------------------------------

/// Alarm configuration table (mirrors tfc_dart's Alarm table).
class ServerAlarm extends Table {
  @override
  String get tableName => 'alarm';

  @override
  Set<Column> get primaryKey => {uid};

  TextColumn get uid => text()();
  TextColumn get key => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text()();
  TextColumn get rules => text()(); // JSON string of List<AlarmRule>
}

/// Alarm history table (mirrors tfc_dart's AlarmHistory table).
class ServerAlarmHistory extends Table {
  @override
  String get tableName => 'alarm_history';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get alarmUid => text().references(ServerAlarm, #uid)();
  TextColumn get alarmTitle => text()();
  TextColumn get alarmDescription => text()();
  TextColumn get alarmLevel => text()();
  TextColumn get expression => text().nullable()();
  BoolColumn get active => boolean()();
  BoolColumn get pendingAck => boolean()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get deactivatedAt => dateTime().nullable()();
  DateTimeColumn get acknowledgedAt => dateTime().nullable()();
}

/// Audit log table for recording all AI tool invocations.
///
/// This table is new to the MCP server (not in tfc_dart). It stores the
/// pre-log/post-log audit trail required by SAFE-03 and SAFE-04.
///
/// NOTE: An identical table class exists in tfc_dart/core/mcp_tables.dart.
/// Both define the same physical table. Drift code gen requires table classes
/// to be local to the package, so we keep this definition here for
/// ServerDatabase while tfc_dart has its own for AppDatabase.
class AuditLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get operatorId => text()();
  TextColumn get tool => text()();
  TextColumn get arguments => text()(); // JSON-encoded tool arguments
  TextColumn get reasoning => text().nullable()(); // AI reasoning/rationale
  TextColumn get status => text()(); // pending, success, failed, declined
  TextColumn get error => text().nullable()(); // Error message if failed
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
}

// ---------------------------------------------------------------------------
// PLC Code Index tables.
//
// NOTE: Identical table classes exist in tfc_dart/core/mcp_tables.dart.
// Drift code gen requires table classes to be local to the package.
// ---------------------------------------------------------------------------

/// PLC code blocks indexed from TwinCAT project uploads.
class PlcCodeBlockTable extends Table {
  @override
  String get tableName => 'plc_code_block';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get assetKey => text()();
  TextColumn get blockName => text()();
  TextColumn get blockType => text()(); // FunctionBlock, Program, GVL, Function, Method, Action, Property, Transition
  TextColumn get filePath => text()();
  TextColumn get declaration => text()();
  TextColumn get implementation => text().nullable()();
  TextColumn get fullSource => text()();
  IntColumn get parentBlockId => integer().nullable()(); // For child blocks (methods, actions, etc.)
  DateTimeColumn get indexedAt => dateTime()();

  /// PLC vendor type: "twincat", "schneider_control_expert",
  /// "schneider_machine_expert". Null defaults to "twincat" for
  /// backward compatibility with existing data.
  TextColumn get vendorType => text().nullable()();

  /// StateMan server alias linking PLC code to OPC UA server scope.
  /// Replaces direct Beckhoff asset key linkage with server-scoped
  /// correlation chain: server alias -> key mappings -> OPC UA identifiers
  /// -> PLC qualified names -> code blocks.
  TextColumn get serverAlias => text().nullable()();
}

/// Individual variable declarations within PLC code blocks.
class PlcVariableTable extends Table {
  @override
  String get tableName => 'plc_variable';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get blockId => integer().references(PlcCodeBlockTable, #id)();
  TextColumn get variableName => text()();
  TextColumn get variableType => text()();
  TextColumn get section => text()(); // VAR, VAR_INPUT, VAR_OUTPUT, VAR_IN_OUT, VAR_GLOBAL, etc.
  TextColumn get qualifiedName => text()(); // e.g. GVL_Main.pump3_speed
  TextColumn get comment => text().nullable()();
}

// ---------------------------------------------------------------------------
// Pre-computed call graph tables.
//
// NOTE: Identical table classes exist in tfc_dart/core/mcp_tables.dart.
// Drift code gen requires table classes to be local to the package.
// ---------------------------------------------------------------------------

/// Variable reference edges from call graph analysis.
class PlcVarRefTable extends Table {
  @override
  String get tableName => 'plc_var_ref';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get blockId => integer().references(PlcCodeBlockTable, #id)();
  TextColumn get variablePath => text()(); // e.g. "GVL_Main.pump3_speed"
  TextColumn get kind => text()(); // "read", "write", or "call"
  IntColumn get lineNumber => integer().nullable()();
  TextColumn get sourceLine => text().nullable()();
}

/// Function block instance declarations.
class PlcFbInstanceTable extends Table {
  @override
  String get tableName => 'plc_fb_instance';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get declaringBlockId =>
      integer().references(PlcCodeBlockTable, #id)();
  TextColumn get instanceName => text()(); // e.g. "pump3"
  TextColumn get fbTypeName => text()(); // e.g. "FB_PumpControl"
}

/// Block-to-block call edges.
class PlcBlockCallTable extends Table {
  @override
  String get tableName => 'plc_block_call';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get callerBlockId =>
      integer().references(PlcCodeBlockTable, #id)();
  TextColumn get calleeBlockName =>
      text()(); // e.g. "FB_PumpControl", "TON"
  IntColumn get lineNumber => integer().nullable()();
}

// ---------------------------------------------------------------------------
// Drawing Index tables.
// ---------------------------------------------------------------------------

/// Electrical drawing metadata indexed from PDF uploads.
class DrawingTable extends Table {
  @override
  String get tableName => 'drawing';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get assetKey => text()();
  TextColumn get drawingName => text()();
  TextColumn get filePath => text()();
  IntColumn get pageCount => integer()();
  DateTimeColumn get uploadedAt => dateTime()();

  /// Optional PDF blob storage for drawings (added in schema v7).
  /// Nullable because existing drawings use filesystem path only.
  BlobColumn get pdfBytes => blob().nullable()();
}

/// Full-text content of individual pages within a drawing PDF.
class DrawingComponentTable extends Table {
  @override
  String get tableName => 'drawing_component';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get drawingId => integer().references(DrawingTable, #id)();
  IntColumn get pageNumber => integer()();
  TextColumn get fullPageText => text()();
}

// ---------------------------------------------------------------------------
// Technical Documentation tables.
// ---------------------------------------------------------------------------

/// Technical document metadata and PDF blob storage.
class TechDocTable extends Table {
  @override
  String get tableName => 'tech_doc';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  BlobColumn get pdfBytes => blob()();
  IntColumn get pageCount => integer()();
  IntColumn get sectionCount => integer()();
  DateTimeColumn get uploadedAt => dateTime()();
}

/// Sections extracted from technical documents.
class TechDocSectionTable extends Table {
  @override
  String get tableName => 'tech_doc_section';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get docId => integer().references(TechDocTable, #id)();
  IntColumn get parentId => integer().nullable()();
  TextColumn get title => text()();
  TextColumn get content => text()();
  IntColumn get pageStart => integer()();
  IntColumn get pageEnd => integer()();
  IntColumn get level => integer()();
  IntColumn get sortOrder => integer()();
}

// ---------------------------------------------------------------------------
// MCP Proposal notification table
// ---------------------------------------------------------------------------

/// Proposals generated by MCP write tools (alarm, page, asset, key mapping).
///
/// When Claude Desktop or in-app chat generates a proposal, it is recorded
/// here so the Flutter HMI can show a notification to the operator — even
/// when the MCP server runs as a separate process (SSE mode).
///
/// NOTE: An identical table class exists in tfc_dart/core/mcp_tables.dart.
/// Drift code gen requires table classes to be local to the package.
class ServerMcpProposalTable extends Table {
  @override
  String get tableName => 'mcp_proposal';

  IntColumn get id => integer().autoIncrement()();

  /// Proposal type: alarm, page, asset, key_mapping.
  TextColumn get proposalType => text()();

  /// Human-readable title for the notification (e.g. "Pump Overcurrent").
  TextColumn get title => text()();

  /// Full proposal JSON for routing to the editor.
  TextColumn get proposalJson => text()();

  /// Operator who triggered the proposal.
  TextColumn get operatorId => text()();

  /// pending → notified → viewed → accepted / rejected / dismissed.
  TextColumn get status =>
      text().withDefault(const Constant('pending'))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
}

// ---------------------------------------------------------------------------
// Database class
// ---------------------------------------------------------------------------

@DriftDatabase(tables: [
  ServerAlarm,
  ServerAlarmHistory,
  AuditLog,
  PlcCodeBlockTable,
  PlcVariableTable,
  DrawingTable,
  DrawingComponentTable,
  TechDocTable,
  TechDocSectionTable,
  ServerMcpProposalTable,
  PlcVarRefTable,
  PlcFbInstanceTable,
  PlcBlockCallTable,
])
class ServerDatabase extends _$ServerDatabase implements McpDatabase {
  ServerDatabase._(super.executor);

  /// Create an in-memory SQLite database for testing.
  factory ServerDatabase.inMemory() {
    return ServerDatabase._(NativeDatabase.memory());
  }

  /// Create a PostgreSQL-backed database for production.
  factory ServerDatabase.postgres(pg.Endpoint endpoint,
      {pg.SslMode? sslMode}) {
    final pool = pg.Pool.withEndpoints(
      [endpoint],
      settings: pg.PoolSettings(
        maxConnectionCount: 5,
        sslMode: sslMode ?? pg.SslMode.disable,
      ),
    );
    return ServerDatabase._(PgDatabase.opened(pool));
  }

  /// Create a PostgreSQL-backed database from a [ServerDatabaseConfig].
  ///
  /// This is the preferred factory for production use. It accepts an
  /// injectable config object rather than raw env vars, enabling the
  /// Flutter app to provide credentials from secure storage.
  factory ServerDatabase.fromConfig(ServerDatabaseConfig config) {
    return ServerDatabase.postgres(
      config.endpoint,
      sslMode: config.sslMode,
    );
  }

  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // The MCP server only reads shared tables (alarm, alarm_history)
          // which are managed by tfc_dart's migrations. The audit_log table
          // is created by onCreate above.
          //
          // `flutter_preferences` was on that list until this server stopped
          // reading it. Its table class is gone with the read: a schema this
          // package does not need is a schema that invites the read back.
          //
          // Future schema migrations for shared tables should be handled
          // by tfc_dart; the MCP server just needs to stay compatible.

          // Schema v4: Add audit_log table.
          if (from < 4) {
            await m.createTable(auditLog);
          }

          // Schema v5: Add PLC code index tables (owned by MCP server).
          if (from < 5) {
            await m.createTable(plcCodeBlockTable);
            await m.createTable(plcVariableTable);
          }

          // Schema v6: Add drawing index tables (owned by MCP server).
          if (from < 6) {
            await m.createTable(drawingTable);
            await m.createTable(drawingComponentTable);
          }

          // Schema v7: Add technical documentation tables and drawing blob column.
          if (from < 7) {
            await m.createTable(techDocTable);
            await m.createTable(techDocSectionTable);
            // Add nullable pdfBytes blob column to existing drawing table.
            await customStatement(
                'ALTER TABLE drawing ADD COLUMN pdf_bytes BLOB');
          }

          // Schema v8: Add MCP proposal notification table.
          if (from < 8) {
            await m.createTable(serverMcpProposalTable);
          }

          // Schema v9: Add vendorType and serverAlias columns to plc_code_block.
          if (from < 9) {
            await customStatement(
                'ALTER TABLE plc_code_block ADD COLUMN vendor_type TEXT');
            await customStatement(
                'ALTER TABLE plc_code_block ADD COLUMN server_alias TEXT');
          }

          // Schema v10: Add pre-computed call graph tables.
          if (from < 10) {
            await m.createTable(plcVarRefTable);
            await m.createTable(plcFbInstanceTable);
            await m.createTable(plcBlockCallTable);
          }
        },
      );
}
