/// The gated drop of `flutter_preferences` — the one irreversible statement
/// this milestone contains.
///
/// ## Why this is a tool and not a migration arm
///
/// An `onUpgrade` arm would execute the drop on **every station at deploy**,
/// unattended, at whatever moment each panel happened to restart. The locked
/// decision forbids exactly that: the table is rollback insurance for the
/// whole cutover, and it stops being insurance the instant a schema bump can
/// take it. So this is a standalone `dart run` invoked once, by a person, from
/// the runbook, against a plant whose migration has already been verified.
///
/// **This branch never runs it against the plant.** It is written, gated and
/// proved against the throwaway Postgres; the plant run is 04-13's step,
/// behind Jón's fresh-dump gate.
///
/// ## The four gates
///
/// All four are evaluated **every run, and all failures are reported
/// together**. That is deliberate rather than fail-fast: the operator running
/// this is in a maintenance window at an hour they would rather not be, and
/// four sequential refusals separated by four re-runs is how somebody reaches
/// for a flag that skips them. One list, once.
///
/// It also means that **without the confirmation variable this is a dry run**
/// — every read-only check is performed and reported, and nothing is written.
/// That is the intended way to rehearse the drop.
///
///   1. **The three migration markers exist.** `_migrated.key_mappings`
///      (Phase 2), `_migrated.pages` (Phase 3) and `_migrated.preferences`
///      (04-11). Absent means that migration has not run on this database,
///      and dropping would destroy the only copy of what it was going to
///      move.
///   2. **The consistency check is clean**, bar two named exceptions — see
///      [kExpectedMissingHistoryMarkers], which is the whole of the tolerance
///      and is an allow-list of two ids, not a relaxed rule.
///   3. **No unknown keys remain.** Every surviving key classifies as migrated
///      or deliberately abandoned through `classifyPreferenceKey` — 04-11's
///      classifier, called rather than re-derived, because two implementations
///      of one rule is how the two answers drift apart and how a mutation test
///      passes while proving nothing.
///   4. **`CENTROIDX_CONFIRM_DROP=flutter_preferences` is set.** Not a
///      `--force`: the value names the table, so it cannot be set once in a
///      shell profile and forgotten, and it cannot be confused with
///      confirmation of some other destructive step.
///
/// Two further refusals are correctness preconditions rather than gates, and
/// are reported the same way: the database must be Postgres (SQLite has no
/// such table and no such trigger), and the pool must be one connection, for
/// the reason `preference_migration.dart` states — the transaction this needs
/// is atomic only at a pool of one.
library;

import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators, SqlDialect;
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/config/config_consistency.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show kPagesMigratedMarkerId, kPreferencesMigratedMarkerId;
import 'package:tfc_dart/core/config/key_mapping_migration.dart'
    show kKeyMappingsMigratedMarkerId;
import 'package:tfc_dart/core/config/preference_migration.dart'
    show PreferenceDisposition, classifyPreferenceKey;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_connections.dart'
    show kMaxPoolConnectionsEnv, resolvePoolSize;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/log_config.dart';

/// The environment variable that confirms the drop, and the only value it
/// accepts.
const String kConfirmDropEnvVar = 'CENTROIDX_CONFIRM_DROP';
const String kConfirmDropValue = 'flutter_preferences';

/// The table this drops, and the notify function that outlives it.
///
/// `DROP TABLE` takes the table's triggers with it but **not** the function
/// they call: `enableKeyedNotificationChannel` created
/// `notify_flutter_preferences_key_change()` as a standalone `plpgsql`
/// function (`database_drift.dart`), and a dropped table leaves it behind as
/// an orphan that the next engineer reading `\df` cannot account for.
const String kDroppedTable = 'flutter_preferences';
const String kDroppedFunction = 'notify_flutter_preferences_key_change';

/// The markers whose absence from `config_change` is expected, not corruption.
///
/// `blob_migration.dart` writes its two markers with **no change row at all**,
/// so `checkConfigConsistency` reports them as `missing_history` on every
/// plant Phases 2 and 3 migrated. The rows are real and their values are
/// correct; their history simply was never written, and it cannot be written
/// retroactively without inventing an author and a time.
///
/// **This is an allow-list of two ids, not a tolerance for the category.** A
/// third marker appearing, or either of these two developing a *different*
/// violation, still refuses — which is the property
/// `drop_flutter_preferences_test.dart` proves by planting one. Without the
/// list the gate would be unsatisfiable on any plant we would actually run it
/// against, and an unsatisfiable gate is not a strict gate: it is a gate
/// somebody reinterprets at 02:00, or works around.
///
/// `_migrated.preferences` is deliberately **not** here. 04-11 writes its
/// marker through the ordinary path, with its change row, so it has history
/// like anything else; if it ever appears in this list something has
/// regressed in that migration.
const Map<String, String> kExpectedMissingHistoryMarkers = <String, String>{
  kKeyMappingsMigratedMarkerId:
      'written by blob_migration.dart with no change row, Phase 2 (commit '
          '2acdf8dc guarded the change-row writers; the marker write never '
          'had one)',
  kPagesMigratedMarkerId:
      'written by blob_migration.dart with no change row, Phase 3 — same '
          'writer, same omission',
};

/// The three markers that must exist before the table may go.
const Map<String, String> kRequiredMarkers = <String, String>{
  kKeyMappingsMigratedMarkerId: 'the Phase 2 key-mappings migration',
  kPagesMigratedMarkerId: 'the Phase 3 pages and assets migration',
  kPreferencesMigratedMarkerId: 'the 04-11 preference migration',
};

final Logger _logger = Logger();

/// What one run did.
enum DropOutcome {
  /// At least one gate refused. Nothing was written.
  refused,

  /// Every gate passed and the table and its function are gone.
  dropped,

  /// The table was already gone. Nothing to do, and not an error — the
  /// runbook's week-later step has to be safe to re-run.
  alreadyGone,
}

/// The result of one run, in the terms the runbook needs.
class DropResult {
  const DropResult({
    required this.outcome,
    this.refusals = const [],
    this.dropped = const [],
  });

  final DropOutcome outcome;

  /// Every gate that refused, one sentence each, in gate order. Empty unless
  /// [outcome] is [DropOutcome.refused].
  final List<String> refusals;

  /// What was actually dropped, named.
  final List<String> dropped;

  /// The process exit code this outcome deserves.
  int get exitCode => outcome == DropOutcome.refused ? 1 : 0;
}

/// Evaluates the gates against [db] and, if all pass, drops the table.
///
/// The whole of the tool's behaviour lives here rather than in [main], so the
/// integration test exercises the same code the runbook runs. [main] resolves
/// the environment, prints and exits; it makes no decisions of its own.
///
/// [environment] is passed rather than read so a test can drive gate 4 without
/// mutating the process it runs in.
Future<DropResult> dropFlutterPreferences(
  AppDatabase db, {
  required Map<String, String> environment,
}) async {
  // Before every gate: a table that is already gone is the re-run case, and
  // the gates below would misreport it — the unknown-key scan cannot read a
  // table that does not exist, and would refuse for the wrong reason.
  if (!await _tableExists(db)) {
    return const DropResult(outcome: DropOutcome.alreadyGone);
  }

  final refusals = <String>[];

  // The executor's dialect, never `db.postgres` — that getter is false on
  // every station because the app builds its database through an isolate
  // (D-1).
  if (db.executor.dialect != SqlDialect.postgres) {
    refusals.add('the database is ${db.executor.dialect.name}, not postgres; '
        'there is no $kDroppedTable table and no trigger to drop');
    // Nothing below can be evaluated meaningfully against the wrong dialect.
    return DropResult(outcome: DropOutcome.refused, refusals: refusals);
  }

  final poolSize = resolvePoolSize(db.config.maxPoolConnections);
  if (poolSize > 1) {
    refusals.add('the connection pool is $poolSize wide; the drop and its '
        'function removal are atomic only at a pool of one. Set '
        '$kMaxPoolConnectionsEnv to 1 (or leave it unset)');
  }

  // Gate 1 — the markers.
  final missingMarkers = <String>[];
  for (final entry in kRequiredMarkers.entries) {
    if (!await _markerExists(db, entry.key)) {
      missingMarkers.add('${entry.key} (${entry.value})');
    }
  }
  if (missingMarkers.isNotEmpty) {
    refusals.add('these migrations have not run on this database, so the '
        'table still holds the only copy of what they would move: '
        '${missingMarkers.join('; ')}');
  }

  // Gate 2 — consistency, bar the two named markers.
  final violations = await checkConfigConsistency(db);
  final blocking = violations.where(_isBlocking).toList(growable: false);
  if (blocking.isNotEmpty) {
    refusals.add('the configuration consistency check found '
        '${blocking.length} violation(s) that are not the two expected '
        'marker omissions: ${blocking.map(_describe).join('; ')}');
  }

  // Gate 3 — unknown keys.
  final unknown = await _unknownKeys(db);
  if (unknown.isNotEmpty) {
    refusals.add('${unknown.length} key(s) in $kDroppedTable are not '
        'classified as migrated or abandoned by this build, so dropping '
        'would destroy configuration nobody has accounted for: '
        '${unknown.join(', ')}');
  }

  // Gate 4 — the confirmation.
  final confirmation = environment[kConfirmDropEnvVar];
  if (confirmation != kConfirmDropValue) {
    refusals.add(confirmation == null
        ? '$kConfirmDropEnvVar is not set. This run was a rehearsal: every '
            'check above was performed and nothing was written. Set '
            '$kConfirmDropEnvVar=$kConfirmDropValue to perform the drop'
        : '$kConfirmDropEnvVar is set to "$confirmation", not '
            '"$kConfirmDropValue". The value names the table on purpose, so '
            'that a confirmation cannot be left in a shell profile or reused '
            'from some other destructive step');
  }

  if (refusals.isNotEmpty) {
    return DropResult(outcome: DropOutcome.refused, refusals: refusals);
  }

  // One transaction: a table dropped without its function leaves an orphan
  // nobody can account for, and a function dropped without its table leaves a
  // trigger pointing at nothing.
  await db.transaction(() async {
    await db.customStatement('DROP TABLE IF EXISTS "$kDroppedTable"');
    await db.customStatement('DROP FUNCTION IF EXISTS "$kDroppedFunction"()');
  });

  return DropResult(
    outcome: DropOutcome.dropped,
    dropped: [
      'table $kDroppedTable',
      'function $kDroppedFunction() (and, with the table, its '
          '${kDroppedTable}_key_notify trigger)',
    ],
  );
}

/// Whether the table is still there.
///
/// `to_regclass` rather than a `SELECT` that would throw: an absent table is
/// the expected re-run case, and reading it out of an exception message is how
/// a driver's wording becomes a control-flow dependency.
Future<bool> _tableExists(AppDatabase db) async {
  if (db.executor.dialect != SqlDialect.postgres) return false;
  final row = await db
      .customSelect("SELECT to_regclass('public.$kDroppedTable')::text AS name")
      .getSingle();
  return row.data['name'] != null;
}

/// Through the drift accessors and not raw SQL, for a reason worth stating:
/// `customSelect`'s `?` placeholders are not rewritten to Postgres' `$1` form,
/// so a hand-written parameterised statement here fails with a syntax error at
/// the second placeholder. The builder is also the only version that is
/// dialect-agnostic, which matters because the SQLite arm of this tool has to
/// reach its refusal rather than crash on the way to it.
Future<bool> _markerExists(AppDatabase db, String markerId) async {
  final row = await (db.select(db.configItemTable)
        ..where((t) =>
            t.kind.equals(ConfigKind.preference.wireName) &
            t.id.equals(markerId) &
            t.scope.equals(ConfigScope.shared.wireName))
        ..limit(1))
      .getSingleOrNull();
  return row != null;
}

/// Whether [violation] must stop the drop.
///
/// Everything does, except a `missing_history` finding against one of the two
/// shared preference marker rows named in [kExpectedMissingHistoryMarkers].
/// Every clause is load-bearing: the same id under a different invariant, a
/// different kind, or a station scope is a finding nobody has accounted for.
bool _isBlocking(ConfigInconsistency violation) =>
    !(violation.invariant == ConfigInvariant.missingHistory &&
        violation.kindName == ConfigKind.preference.wireName &&
        violation.scopeName == ConfigScope.shared.wireName &&
        kExpectedMissingHistoryMarkers.containsKey(violation.entityId));

String _describe(ConfigInconsistency violation) =>
    '${violation.invariant.wireName} on ${violation.kindName}:'
    '${violation.entityId}@${violation.scopeName}';

/// Every surviving key this build cannot account for.
///
/// Through 04-11's [classifyPreferenceKey], never a second copy of its tables:
/// the classifier is the one definition of "known", and a list re-derived here
/// would answer differently the moment somebody adds a family to one and not
/// the other.
Future<List<String>> _unknownKeys(AppDatabase db) async {
  final rows = await db.select(db.flutterPreferences).get();
  final unknown = <String>[
    for (final row in rows)
      if (classifyPreferenceKey(row.key).disposition ==
          PreferenceDisposition.unknown)
        row.key,
  ]..sort();
  return unknown;
}

Future<void> main(List<String> args) async {
  initLogConfig();

  final config = await DatabaseConfig.fromEnv();
  final database = await Database.connectWithRetry(config);
  try {
    final result = await dropFlutterPreferences(
      database.db,
      environment: Platform.environment,
    );

    switch (result.outcome) {
      case DropOutcome.alreadyGone:
        _logger.i('$kDroppedTable is already gone; nothing to do. This is the '
            'expected outcome of a re-run.');
      case DropOutcome.refused:
        _logger.e('REFUSED to drop $kDroppedTable. Nothing was written.\n'
            '${result.refusals.map((r) => '  - $r').join('\n')}');
      case DropOutcome.dropped:
        _logger.w('DROPPED, irreversibly:\n'
            '${result.dropped.map((d) => '  - $d').join('\n')}\n'
            'The plant\'s configuration now lives entirely in config_item '
            'rows. Restore from the pre-cutover dump if this was wrong.');
    }
    exitCode = result.exitCode;
  } finally {
    await database.close();
  }
}
