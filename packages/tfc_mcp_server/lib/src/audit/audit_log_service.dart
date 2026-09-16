import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:tfc_dart/tfc_dart_core.dart' show McpDatabase;
import 'package:tfc_mcp_server/src/database/server_database.dart'
    show $AuditLogTable, AuditLogCompanion;
import 'package:tfc_mcp_server/src/safety/proposal_declined_exception.dart';

/// Status of an audit log entry.
enum AuditStatus { pending, success, failed, declined }

/// The value written to `operator_id` on an audit row raised by an MCP tool
/// call.
///
/// **This column is provenance, not attribution.** It records that a machine
/// ran a tool; it is not a claim that a person authorized one, and it never
/// was. MCP cannot write — every write-shaped tool in this package returns a
/// *proposal* (`lib/src/tools/access_template_tools.dart:28`: "they return a
/// proposal"), so at the moment this row is written there is no person to
/// name. The human's name lands on the **approval** row instead:
/// `lib/core/access_template_store.dart:609` — an accepted proposal's row
/// "still names the human who approved it rather than the agent that suggested
/// it".
///
/// The value is the same provenance token the rest of the system already uses
/// for machine-originated changes: it is what the HMI's access-audit trail
/// maps to `MCP` for its **origin** column (`auditOriginLabel`,
/// `lib/widgets/audit_trail_row.dart:208`). Note what that sentence does and
/// does not say. That is a different column in a different database from this
/// one, and `audit_trail_row.dart`'s own doc records that the origin is
/// *planned* and nothing writes it yet. The token is shared; the field is not.
/// Nothing renders this table — there is no UI reader of the MCP server's
/// `AuditLog` anywhere in the app — so no display gaps either way.
///
/// It is a constant rather than a literal at the call site so the assertions
/// that pin it cannot drift from the value actually written, and so that the
/// root suite can name it across the package boundary through the barrel.
///
/// Do not read the absence of an operator name here as something lost. There
/// is exactly one kind of identity in this system, the access session's
/// signed-in user, and it is asserted where a change is applied. Inventing a
/// second mechanism to fill this column is the thing that was deliberately
/// removed.
const kMcpAuditOperator = 'mcp';

/// Service for recording audit trails of MCP tool invocations.
///
/// Implements the pre-log/post-log pattern: every tool call creates a
/// "pending" record before execution, then updates to success/failed/declined
/// after completion. This ensures that if a tool handler crashes, the pending
/// record survives in the database as evidence of the attempt.
///
/// Accepts [McpDatabase] (not ServerDatabase) so it works with both
/// AppDatabase (Flutter in-process) and ServerDatabase (standalone binary).
/// Creates table references directly from the generated [$AuditLogTable] class
/// since McpDatabase is a marker interface without typed table accessors.
class AuditLogService {
  /// Creates an [AuditLogService] backed by the given [McpDatabase].
  AuditLogService(this._db) : _auditLog = $AuditLogTable(_db);

  final McpDatabase _db;
  final $AuditLogTable _auditLog;

  /// Records an intent to invoke a tool. Creates a "pending" audit record.
  ///
  /// The [arguments] map is JSON-encoded before storage. If [timestamp] is
  /// not provided, the current UTC time is used.
  ///
  /// Returns the auto-increment ID of the new audit record, or -1 if the
  /// DB write failed (e.g., connection temporarily down). Audit logging is
  /// best-effort — failures here should not prevent tool execution.
  Future<int> logIntent({
    required String operatorId,
    required String tool,
    required Map<String, dynamic> arguments,
    String? reasoning,
    DateTime? timestamp,
  }) async {
    try {
      final now = timestamp ?? DateTime.now().toUtc();
      final id = await _db.into(_auditLog).insert(
            AuditLogCompanion.insert(
              operatorId: operatorId,
              tool: tool,
              arguments: jsonEncode(arguments),
              reasoning: reasoning != null
                  ? Value(reasoning)
                  : const Value.absent(),
              status: AuditStatus.pending.name,
              createdAt: now,
            ),
          );
      return id;
    } catch (_) {
      // Best-effort: DB may be temporarily unreachable.
      return -1;
    }
  }

  /// Updates an existing audit record with the outcome of the tool invocation.
  ///
  /// Sets the [status] and [completedAt] timestamp. If [error] is provided
  /// (typically for [AuditStatus.failed]), it is stored on the record.
  ///
  /// Best-effort: silently swallows DB errors so audit failures don't
  /// propagate to tool callers.
  Future<void> updateOutcome(
    int auditId,
    AuditStatus status, {
    String? error,
  }) async {
    if (auditId < 0) return; // No audit record was created (DB was down).
    try {
      final companion = AuditLogCompanion(
        status: Value(status.name),
        completedAt: Value(DateTime.now().toUtc()),
        error: error != null ? Value(error) : const Value.absent(),
      );
      await (_db.update(_auditLog)..where((t) => t.id.equals(auditId)))
          .write(companion);
    } catch (_) {
      // Best-effort: DB may be temporarily unreachable.
    }
  }

  /// Convenience wrapper that logs intent, runs handler, and updates outcome.
  ///
  /// On success: updates to [AuditStatus.success] and returns the handler result.
  /// On failure: updates to [AuditStatus.failed] with the error message, then
  /// rethrows the exception so the caller can handle it.
  ///
  /// The failure branch catches [Object], not [Exception]. An `Error` thrown
  /// by a tool handler -- a failed cast, a null check -- used to slip past it
  /// and leave the row `pending` forever, which is the one state that means
  /// "the process died mid-call" and so the one state that must not be
  /// reachable while the process is still answering. On a build with no
  /// stderr sink this row is the only durable record that the call was made.
  ///
  /// Audit logging is best-effort — if the DB is temporarily down, the tool
  /// handler still executes. The pg pool's built-in keepalive will restore
  /// the connection for subsequent calls.
  Future<T> executeWithAudit<T>({
    required String operatorId,
    required String tool,
    required Map<String, dynamic> arguments,
    String? reasoning,
    required Future<T> Function() handler,
  }) async {
    final auditId = await logIntent(
      operatorId: operatorId,
      tool: tool,
      arguments: arguments,
      reasoning: reasoning,
    );
    try {
      final result = await handler();
      await updateOutcome(auditId, AuditStatus.success);
      return result;
    } on ProposalDeclinedException catch (e) {
      await updateOutcome(auditId, AuditStatus.declined, error: e.message);
      rethrow;
    } catch (e) {
      await updateOutcome(auditId, AuditStatus.failed, error: e.toString());
      rethrow;
    }
  }
}
