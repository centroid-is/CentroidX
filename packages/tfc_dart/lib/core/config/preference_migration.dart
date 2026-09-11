/// The one-shot copy of what is left in `flutter_preferences` into
/// `config_item` rows — the last of the three migrations, and the one whose
/// input has an inventory nobody in this repository can enumerate.
///
/// ## Why this one is not `blob_migration.dart`
///
/// The other two copy **one row** holding one blob whose parser is known. This
/// one copies **every remaining row**, of families that map to two different
/// kinds, from a table whose actual contents are a property of the plant. So
/// the lock, the transaction, the dialect refusal and the pool refusal are
/// borrowed from that module verbatim — a second implementation of the lock
/// would be a second chance to get it wrong — and what is new here is the
/// classification and what it does with a key it does not recognise.
///
/// ## The rule that governs everything below: `flutter_preferences` is the
/// authority
///
/// A station booting on this branch against a reachable Postgres writes rows
/// from its **boot defaults** before any operator has touched anything (D-7).
/// So an existing `config_item` row is not evidence that a key has been
/// migrated — it is very often evidence of the opposite: an empty default
/// sitting on top of the operator's real value, which is still in
/// `flutter_preferences` and is what this migration must preserve.
///
/// **Therefore no key is ever skipped because a row already exists.** Every
/// key this migration recognises is written from the old table, over whatever
/// is there. The idempotency that stops it running twice is the *marker*, and
/// only the marker. Getting this backwards is the one mistake here that loses
/// plant configuration, and it would look like a successful migration.
///
/// A row whose stored content already equals the migrated value is left alone
/// — not skipped as a key, but written as nothing, because writing identical
/// bytes would produce a change row saying something happened when nothing
/// did. That is the same rule `ConfigStore.writeItems` applies.
///
/// ## What is not migrated, and why that is a list rather than a default
///
/// Three dispositions, and the third is the important one:
///
///  * **migrated** — the eight known families, below.
///  * **abandoned** — named, one at a time, each with a reason. A key is on
///    this list because somebody decided it does not belong in shared rows,
///    not because the migration could not read it.
///  * **unknown** — everything else. Left **untouched** in the old table and
///    returned in [PreferenceMigrationResult.unknown]. The authoritative
///    inventory of that table is the production dump and not this repository
///    (C-2), so a key nobody here has heard of is a key nobody here may
///    classify. 04-12's drop tool refuses while any unknown remains, which is
///    what turns this list into a gate rather than a note.
///
/// ## `update_channel` is deliberately not promoted
///
/// It is `administer` in the policy and it looks like a shared family, and it
/// is not one: `update_channel.dart` builds device-local preferences on
/// purpose, so a development box moved onto a prerelease channel does not drag
/// every HMI in the plant with it. Promoting it to a shared row would make
/// that a plant-wide setting silently. It is abandoned by name with that
/// reason.
///
/// ## Images go onto `page_image` rows, never `preference` rows
///
/// 04-09 removed the `page_editor_image:` id-prefix exemption when it moved
/// images onto their own kind, so a plant's existing images routed onto
/// `preference` rows would no longer be history-exempt — and each one would
/// write both sides of a multi-megabyte base64 payload into a table nothing
/// ever prunes. That is C-3, the storage bomb 04-05 defused, rebuilt by
/// accident.
///
/// **The row is keyed by the suffix exactly as stored, and the bytes are never
/// re-hashed.** The suffix is what the assets on every page reference in their
/// `image_id` field; deriving a fresh id from the bytes would produce rows no
/// asset points at and mimics with holes in them, even if the hash agreed —
/// and there is no guarantee the old prefix length matches what
/// `PageImageStore.imageIdFor` computes today.
///
/// ## The marker is part of the action, and that is what makes the values safe
///
/// Every row this migration writes — the values **and** the marker — shares
/// one `action_id`. `config_undo.dart` refuses to undo any action containing an
/// underscore-prefixed preference, all-or-nothing, so the whole migration is
/// unundoable as a unit.
///
/// This is a deliberate divergence from `blob_migration.dart`, which writes
/// its marker with **no** change row and says a logged marker "would invite an
/// undo that re-armed the migration". That was correct when nothing refused
/// such an undo. Now something does, and the marker's change row is precisely
/// what the refusal keys on: without it the action contains only values, and
/// one `administer` click would delete every migrated row while leaving the
/// marker behind — after 04-12 has dropped the old table, with the change rows
/// as the only remaining copy.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:tfc_access/tfc_access.dart' show newActionId;

import '../database.dart';
import '../database_connections.dart';
import '../database_drift.dart';
import 'blob_migration.dart' show kConfigLockNamespace;
import 'config_change.dart';
import 'config_history_policy.dart';
import 'config_item.dart';
import 'config_store.dart'
    show kPagesMigratedMarkerId, kPreferencesMigratedMarkerId;
import 'key_mapping_migration.dart' show kKeyMappingsMigratedMarkerId;
import 'preference_payload.dart';

/// This migration's lock id within [kConfigLockNamespace].
///
/// 1 is the key mappings and 2 is the pages; take the next free number rather
/// than reusing either, so two different migrations can never block each other.
const int kPreferenceMigrationLock = 3;

/// `updated_by` and `who` on every row this writes. Not a username: no human
/// pressed anything.
const String _migrationActor = 'migration';

/// `role_name` on the change rows. A migration runs under no session.
const String _migrationRole = 'system';

/// The prefix an image key carries in the old table.
const String kLegacyImageKeyPrefix = 'page_editor_image:';

/// The suffix a recipe bucket's key carries.
const String kLegacyRecipesKeySuffix = '.recipes';

/// The prefix of the chat assistant's rows: `chat.history`,
/// `chat.conversations`, `chat.active_conversation` and one
/// `chat.conversation.<id>` per thread (`lib/providers/chat.dart`).
const String kLegacyChatKeyPrefix = 'chat.';

/// The prefix of the LLM provider settings: `llm.selected_provider` and the
/// per-provider base URLs (`lib/llm/llm_provider.dart`).
const String kLegacyLlmKeyPrefix = 'llm.';

final Logger _logger = Logger();

/// What one call to [migratePreferencesIntoRows] did.
///
/// Every arm is a normal outcome. This is called unconditionally, from every
/// station, on every boot, so it has to be able to say "not mine to do" as
/// often as it says "done".
enum PreferenceMigrationOutcome {
  /// Rows were written. See [PreferenceMigrationResult] for what.
  migrated,

  /// The marker was already there; nothing was written.
  alreadyDone,

  /// Another station holds the lock and is doing it right now.
  heldByAnother,

  /// `flutter_preferences` is gone — 04-12 has dropped it. Every boot after
  /// the drop reaches this, so it is an outcome and not an error.
  noTable,

  /// The database is not Postgres — a local mirror, or a test.
  notPostgres,

  /// The process pools more than one connection, which makes the transaction
  /// this needs non-atomic.
  unsafePool,

  /// The key-mappings or pages migration has not run. **A skip, never a
  /// throw** — see [migratePreferencesIntoRows].
  siblingsNotMigrated,
}

/// What a key becomes.
enum PreferenceDisposition {
  /// Copied into a row.
  migrate,

  /// Deliberately left behind, for a reason this build can name.
  abandon,

  /// Not recognised. Left untouched and reported.
  unknown,
}

/// One key's fate, decided without touching a database.
///
/// A value rather than a branch inside the copy loop, so the whole
/// classification is testable as a pure function — which matters more here
/// than usual, because the input is a production table this repository cannot
/// enumerate and the tests are the only place the rules are stated twice.
@immutable
class PreferenceClassification {
  const PreferenceClassification.migrate({
    required this.family,
    required this.kind,
    required this.id,
  })  : disposition = PreferenceDisposition.migrate,
        reason = null;

  const PreferenceClassification.abandon(this.reason, {required this.family})
      : disposition = PreferenceDisposition.abandon,
        kind = null,
        id = null;

  const PreferenceClassification.unknown()
      : disposition = PreferenceDisposition.unknown,
        family = 'unknown',
        kind = null,
        id = null,
        reason = null;

  final PreferenceDisposition disposition;

  /// What to count this under in the evidence line.
  final String family;

  /// The kind of row it becomes. Null unless [disposition] is
  /// [PreferenceDisposition.migrate].
  final ConfigKind? kind;

  /// The row id it becomes.
  final String? id;

  /// Why it is being left behind.
  final String? reason;
}

/// What one migration run did, in the terms the runbook and 04-12 need.
@immutable
class PreferenceMigrationResult {
  const PreferenceMigrationResult({
    required this.outcome,
    this.migratedByFamily = const {},
    this.abandoned = const [],
    this.unknown = const [],
    this.actionId,
  });

  final PreferenceMigrationOutcome outcome;

  /// How many rows each family produced. Absent families wrote nothing.
  final Map<String, int> migratedByFamily;

  /// The keys deliberately left behind, sorted.
  final List<String> abandoned;

  /// The keys this build does not recognise, sorted. **04-12 refuses to drop
  /// the table while this is non-empty.**
  final List<String> unknown;

  /// The `action_id` every row of this run shares, or null when nothing was
  /// written.
  final String? actionId;

  int get migratedCount =>
      migratedByFamily.values.fold(0, (sum, n) => sum + n);

  /// The one line the cutover runbook's step 4 greps for.
  ///
  /// Exactly one line, whatever happened, with the counts in it: an operator
  /// reading a boot log needs to be able to say "the migration ran and moved
  /// this much" without reading anything else, and 04-12's precondition is
  /// that this line exists and reports no unknowns.
  String get evidenceLine {
    final families = migratedByFamily.entries.map((e) => '${e.key}: ${e.value}')
        .join(', ');
    // The names in brackets only when there are any: `0 unknown []` reads as
    // a list that failed to render rather than as an absence.
    final names = unknown.isEmpty ? '' : ' [${unknown.join(', ')}]';
    return 'Preference migration: $migratedCount migrated '
        '($families), ${abandoned.length} abandoned, '
        '${unknown.length} unknown$names';
  }
}

/// Which keys are deliberately left in the old table, and why.
///
/// Named one at a time rather than matched by a pattern: every entry here is a
/// decision somebody made, and a pattern would silently adopt the next key
/// that happened to look like one of them.
///
/// ## Abandoning a key removes a safety net, so check its consumers
///
/// **A key may be classified abandoned only when every *consumer* has been
/// checked — never when its *owner* has.** Grep for readers; do not reason
/// from the key's provenance.
///
/// This is written here because the list got it wrong once, and the shape of
/// the mistake is worth more than the entry that caused it. `mcp.config` was
/// abandoned on the grounds that it is device-local for the app and the shared
/// row is a stale copy — both true, and both about the key's *owner*. At the
/// time, `tfc_mcp_server.dart` read that shared row at every server start and
/// read nothing else, and its documented default was that missing keys mean
/// **enabled**: after 04-12 dropped the table an operator's deliberately
/// disabled tools would have switched themselves back on, on a surface that
/// reaches the plant.
///
/// **The verdict has since flipped twice, and only ever on a consumer grep.**
/// That reader is gone — `d47f7633` deleted `_readTogglesFromDb`, `b1b60726`
/// deleted the table class under it — so the key is abandoned again, for a
/// reason that names the readers rather than the owner (see its entry below).
/// Nothing about the rule changed across either flip: the first verdict was
/// right by luck and wrong by argument, and what settled it both times was
/// enumerating who reads the row, not reasoning about whose key it is.
///
/// The reason a bad entry would not be caught is the part to remember. An
/// **unknown** key blocks 04-12's drop by design and forces somebody to
/// resolve it. An **abandoned** key waves the drop through. So this list is
/// not bookkeeping — every entry asserts *nothing will miss this*, and being
/// wrong here disarms the gate that exists to catch being wrong. The gate
/// still runs, and still passes.
const Map<String, String> kAbandonedPreferenceKeys = <String, String>{
  'key_mappings':
      'migrated to key_mapping rows by Phase 2; the blob is rollback '
          'insurance until 04-12 drops the table',
  'page_editor_data':
      'migrated to page and asset rows by Phase 3; the blob is rollback '
          'insurance until 04-12 drops the table',
  'startup_url':
      'device-local: which page a panel starts on is that panel\'s own, and '
          'Phase 1 SC-2 already imported it',
  'access.session':
      'device-local: a session belongs to the machine somebody signed in on',
  // Enumerated, not inferred — the rule above is what this entry is held to.
  // Every reader of this key, as of 04-12:
  //   * `tfc_mcp_server.dart`'s `_readTogglesFromDb`, which read the shared
  //     row at every server start: DELETED in `d47f7633`, and the drift table
  //     class it read through in `b1b60726`. It was the only consumer of the
  //     shared copy, and its replacement takes the toggles from the spawner
  //     (`CENTROIDX_MCP_TOGGLES`), which is the deciding device handing the
  //     decision down.
  //   * `lib/providers/mcp_bridge.dart`'s `mcpConfigProvider`, which reads
  //     `localPreferencesProvider` — device-local, per research C-1: whether
  //     this station runs an MCP server is that station's own.
  //   * `migrateMcpConfigToDeviceLocal`, which does not read the shared row
  //     as a setting; it copies it down once and DELETES it.
  // So migrating it would be worse than useless. The raw preferences editor
  // merges the shared keys OVER the device-local ones
  // (`widgets/preferences.dart`, `_loadData`), so a migrated row would mask
  // this station's real value in the list and offer an operator an
  // `administer`-gated edit that changes nothing anywhere — a write that
  // quietly does nothing, arriving through the front door.
  'mcp.config':
      'device-local per research C-1, and since 04-12 nothing reads the shared '
          'copy at all: the MCP binary\'s _readTogglesFromDb went in d47f7633 '
          'and its table class in b1b60726, the app reads '
          'localPreferencesProvider, and migrateMcpConfigToDeviceLocal only '
          'deletes this row. Migrating it would put an editable shared row in '
          'front of an operator that no consumer would ever read',
  'update_channel':
      'device-local by design (update_channel.dart builds device-local '
          'preferences) so a development box on a prerelease channel does not '
          'move every HMI in the plant onto it',
  // Consumers, enumerated: `StateManConfig.fromPrefs` and `toPrefs`
  // (`state_man.dart`) read and write it with `secret: true`, which is the
  // OS keychain and never a row; the backend takes its copy from a file
  // (`CENTROID_STATEMAN_FILE_PATH`). Nothing reads a shared row of this
  // name. A row of it would be the plant's PLC endpoints — and whatever
  // credentials a plant put in them — copied into a table every station
  // mirrors, and its change row copied into a log nothing prunes, for no
  // reader at all.
  'state_man_config':
      'the PLC connection settings, read and written through the OS '
          'keychain only (secret: true); no consumer reads a shared row of '
          'it, and a plaintext copy in a replicated table would be a leak '
          'with no purpose',
};

/// What [key] becomes. Pure; see [PreferenceClassification].
PreferenceClassification classifyPreferenceKey(String key) {
  // Bookkeeping first, and before the abandoned list, so a marker can never be
  // read as a preference whatever else it is called. These are the old table's
  // own account of its imports and migrations.
  if (key.startsWith('_')) {
    return const PreferenceClassification.abandon(
      'bookkeeping: a migration or import marker, not a setting anybody chose',
      family: 'bookkeeping',
    );
  }
  if (kAbandonedPreferenceKeys[key] case final reason?) {
    return PreferenceClassification.abandon(reason, family: 'abandoned');
  }
  // Images before the exact families: the prefix is what decides, and an image
  // must never fall through to a `preference` row. See the library doc.
  if (key.startsWith(kLegacyImageKeyPrefix)) {
    final id = key.substring(kLegacyImageKeyPrefix.length);
    // A prefix with nothing after it names no image. Unknown rather than
    // abandoned: this build cannot say what somebody meant by it.
    if (id.isEmpty) return const PreferenceClassification.unknown();
    return PreferenceClassification.migrate(
      family: 'images',
      kind: ConfigKind.pageImage,
      // The suffix verbatim. Never re-hashed — every asset's `image_id`
      // references this string.
      id: id,
    );
  }
  // The chat assistant's state and the LLM provider settings, both written
  // through the shared store on the build being replaced, so a plant that has
  // used the assistant carries them. Prefix families rather than exact names:
  // `chat.conversation.<id>` is one row per thread.
  if (key.startsWith(kLegacyChatKeyPrefix) &&
      key.length > kLegacyChatKeyPrefix.length) {
    return PreferenceClassification.migrate(
      family: 'chat',
      kind: ConfigKind.preference,
      id: key,
    );
  }
  if (key.startsWith(kLegacyLlmKeyPrefix) &&
      key.length > kLegacyLlmKeyPrefix.length) {
    return PreferenceClassification.migrate(
      family: 'llm',
      kind: ConfigKind.preference,
      id: key,
    );
  }
  if (key.endsWith(kLegacyRecipesKeySuffix) &&
      key.length > kLegacyRecipesKeySuffix.length) {
    return PreferenceClassification.migrate(
      family: 'recipes',
      kind: ConfigKind.preference,
      id: key,
    );
  }
  if (kMigratedPreferenceKeys.contains(key)) {
    return PreferenceClassification.migrate(
      family: key,
      kind: ConfigKind.preference,
      id: key,
    );
  }
  return const PreferenceClassification.unknown();
}

/// The exact-named keys that become shared `preference` rows.
///
/// `server_config_envelope` is here and is history-exempt, so it becomes a row
/// with no change row — `historyExempt` is asked at the insert, not here, for
/// the same reason the store asks it inside its writer.
const Set<String> kMigratedPreferenceKeys = <String>{
  'alarm_man_config',
  'collector_config',
  'page_editor_top_level_order',
  'server_config_envelope',
};

/// Copies every remaining known key out of `flutter_preferences` into rows,
/// once, on whichever station gets the lock first.
///
/// Safe to call unconditionally and from every station. [remote] must be the
/// *shared* database.
///
/// ## The sibling pre-check is a skip, never a throw
///
/// The key-mappings and pages migrations must have run first: this one is
/// ordered behind them at the attach site and their markers are the evidence.
/// If either marker is missing the run is **abandoned with a warning** and the
/// station comes up.
///
/// A throw here would be worse than the ordering problem it reports. The
/// attach path runs every migration in sequence and hands the store to the
/// sync engine afterwards; an exception out of this one would take the attach
/// down with it, and a sequencing slip on a fresh database would become a
/// station that does not come up at all. The runbook's evidence line is what
/// catches it operationally; this is what keeps the plant running while
/// somebody reads it.
Future<PreferenceMigrationResult> migratePreferencesIntoRows(
    Database remote) async {
  final db = remote.db;

  // The executor's dialect, never `db.postgres` — that getter is false on
  // every station, because the app builds its database through an isolate.
  if (db.executor.dialect != SqlDialect.postgres) {
    _logger.i('Preference migration: database is '
        '${db.executor.dialect.name}, not postgres; nothing to do');
    return const PreferenceMigrationResult(
        outcome: PreferenceMigrationOutcome.notPostgres);
  }

  final pool = resolvePoolSize(db.config.maxPoolConnections);
  if (pool > 1) {
    _logger.w('Preference migration: refusing to run with a pool of $pool '
        'connections — the transaction this needs is atomic only at a pool '
        'of one. Set $kMaxPoolConnectionsEnv to 1 (or leave it unset).');
    return const PreferenceMigrationResult(
        outcome: PreferenceMigrationOutcome.unsafePool);
  }

  return db.transaction(() async {
    // First statement in the transaction, always: a gate read outside the lock
    // is a race with the station that is mid-copy.
    final lock = await db.customSelect(
      // `::int4` on both, and not decoration: drift binds every Dart int as
      // `bigint` and the two-argument advisory-lock functions are declared
      // `(int4, int4)`. Without the casts Postgres answers 42883 at the first
      // statement of the transaction, on a station, where nothing else would
      // catch it.
      r'SELECT pg_try_advisory_xact_lock($1::int4, $2::int4) AS got',
      variables: [
        Variable.withInt(kConfigLockNamespace),
        Variable.withInt(kPreferenceMigrationLock),
      ],
    ).getSingle();
    if (!lock.read<bool>('got')) {
      _logger.i('Preference migration: another station holds the lock; '
          'skipping — this station picks the rows up at its next reconcile');
      return const PreferenceMigrationResult(
          outcome: PreferenceMigrationOutcome.heldByAnother);
    }
    return copyPreferencesIntoRowsLocked(db);
  });
}

/// The copy itself, with the lock held and a transaction open.
///
/// Split out so the ordering this depends on — gate, then siblings, then read,
/// then rows, then the marker **last, in the same transaction** — is provable
/// against an in-memory database, and so the integration suite can abandon a
/// transaction mid-copy the way a station losing power does. It is not a
/// second entry point: called without the lock it is the race
/// [migratePreferencesIntoRows] exists to prevent.
@visibleForTesting
Future<PreferenceMigrationResult> copyPreferencesIntoRowsLocked(
    AppDatabase db) async {
  if (await _hasMarker(db, kPreferencesMigratedMarkerId)) {
    _logger.i('Preference migration: already migrated; nothing to do');
    return const PreferenceMigrationResult(
        outcome: PreferenceMigrationOutcome.alreadyDone);
  }

  final legacy = await _readLegacyTable(db);
  if (legacy == null) {
    _logger.i('Preference migration: flutter_preferences is gone; nothing '
        'to copy. This is every boot after 04-12 drops it.');
    return const PreferenceMigrationResult(
        outcome: PreferenceMigrationOutcome.noTable);
  }

  final legacyKeys = {for (final row in legacy) row.key};
  for (final sibling in const {
    'key_mappings': (blob: 'key_mappings', marker: kKeyMappingsMigratedMarkerId),
    'pages': (blob: 'page_editor_data', marker: kPagesMigratedMarkerId),
  }.entries) {
    if (await _hasMarker(db, sibling.value.marker)) continue;
    // A sibling whose blob was never stored has nothing to write differently,
    // which is the whole of what this gate protects — so it is satisfied. The
    // blob migrations do write their marker on `noBlob` now, but a plant that
    // ran an earlier build of them, or one whose blob row was deleted by
    // hand, would otherwise be refused here on every boot, forever, and come
    // up without its alarms.
    if (!legacyKeys.contains(sibling.value.blob)) {
      _logger.i('Preference migration: no ${sibling.value.marker} row, but '
          'there is no ${sibling.value.blob} blob for that migration to '
          'move either; proceeding');
      continue;
    }
    // A skip, never a throw. See the function doc above.
    _logger.w('Preference migration: the ${sibling.key} migration has not '
        'run (no ${sibling.value.marker} row), so this one is skipping rather '
        'than writing rows that migration is about to write differently. The '
        'station comes up; re-check the attach ordering.');
    return const PreferenceMigrationResult(
        outcome: PreferenceMigrationOutcome.siblingsNotMigrated);
  }

  final at = DateTime.now();
  final actionId = newActionId();
  final station = Platform.localHostname;
  final migratedByFamily = <String, int>{};
  final abandoned = <String>[];
  final unknown = <String>[];

  for (final row in legacy) {
    final classified = classifyPreferenceKey(row.key);
    switch (classified.disposition) {
      case PreferenceDisposition.abandon:
        abandoned.add(row.key);
      case PreferenceDisposition.unknown:
        unknown.add(row.key);
      case PreferenceDisposition.migrate:
        final item = _itemFor(classified, row);
        if (item == null) {
          // A known key whose stored value this build cannot represent. Not
          // guessed at and not dropped silently: it joins the unknowns, so the
          // drop tool refuses while it is there.
          _logger.w('Preference migration: "${row.key}" is a known key whose '
              'stored value (type ${row.type}) could not be read; leaving it '
              'in place and reporting it.');
          unknown.add(row.key);
          continue;
        }
        // Counted whether or not a write was needed. The count means "this
        // key is in rows", which is what the runbook is checking and what
        // 04-12 gates on; a row that already held exactly this value is
        // migrated in every sense that matters, and writing it again would
        // produce a change row claiming an edit that did not happen.
        await _writeItem(db, item,
            at: at, actionId: actionId, station: station);
        migratedByFamily.update(
            classified.family, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  // Last, in the same transaction, and **with** a change row under the same
  // action id — see the library doc for why this differs from the blob
  // migrations.
  await _writeItem(
    db,
    ConfigItem.of(
      kind: ConfigKind.preference,
      id: kPreferencesMigratedMarkerId,
      value: preferencePayload(kPrefStringType, at.toIso8601String()),
    ),
    at: at,
    actionId: actionId,
    station: station,
  );

  final result = PreferenceMigrationResult(
    outcome: PreferenceMigrationOutcome.migrated,
    migratedByFamily: Map.unmodifiable(
        Map.fromEntries(migratedByFamily.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))),
    abandoned: List.unmodifiable(abandoned..sort()),
    unknown: List.unmodifiable(unknown..sort()),
    actionId: actionId,
  );
  _logger.i(result.evidenceLine);
  return result;
}

/// The item [row] becomes, or null when its stored value cannot be read.
ConfigItem? _itemFor(
    PreferenceClassification classified, FlutterPreference row) {
  final value = row.value;
  if (value == null) return null;

  if (classified.kind == ConfigKind.pageImage) {
    // The stored value is already base64 — it is what the old store held and
    // what `PageImageStore` reads back out of `b64`. Not decoded and not
    // re-encoded: a round trip through bytes could only change it.
    return ConfigItem.of(
      kind: ConfigKind.pageImage,
      id: classified.id!,
      value: {kPageImagePayloadField: value},
    );
  }

  final decoded = decodeLegacyPreferenceValue(row.type, value);
  if (decoded == null) return null;
  return ConfigItem.of(
    kind: ConfigKind.preference,
    id: classified.id!,
    value: preferencePayload(row.type, decoded),
  );
}

/// The field `PageImageStore` reads an image's bytes from.
///
/// A literal, because that store lives in the app (it needs Flutter) and this
/// package cannot import it. `preference_migration_test.dart` pins the two
/// together.
const String kPageImagePayloadField = 'b64';

/// The Dart value the legacy `(value, type)` pair holds, or null when this
/// build cannot represent it.
///
/// The old table stores everything as text, and the encoding is
/// `Preferences._upsertToPostgres`'s: `toString()` for the scalars and
/// `join(',')` for a string list. This is that decoding, with one deliberate
/// difference — it **returns null rather than throwing** on a type tag it does
/// not know. `Preferences.loadFromPostgres` throws there, which is right for a
/// load that must not serve half a configuration; a migration that threw would
/// abandon every other key over one bad row.
///
/// The `List<String>` round trip is lossy for an element containing a comma
/// and has always been: `join(',')` and `split(',')` are not inverses. That is
/// inherited from the table being replaced and is preserved exactly rather
/// than silently improved, because a migration that changed a value would be
/// harder to trust than one that carried a known flaw across.
Object? decodeLegacyPreferenceValue(String type, String value) {
  switch (type) {
    case kPrefBoolType:
      return value == 'true';
    case kPrefIntType:
      return int.tryParse(value);
    case kPrefDoubleType:
      return double.tryParse(value);
    case kPrefStringType:
      return value;
    case kPrefStringListType:
      return value.isEmpty ? const <String>[] : value.split(',');
    default:
      return null;
  }
}

/// Whether the shared store holds [markerId].
Future<bool> _hasMarker(AppDatabase db, String markerId) async {
  final t = db.configItemTable;
  final rows = await (db.selectOnly(t)
        ..addColumns([t.id])
        ..where(t.kind.equals(ConfigKind.preference.wireName) &
            t.id.equals(markerId) &
            t.scope.equals(ConfigScope.shared.wireName))
        ..limit(1))
      .get();
  return rows.isNotEmpty;
}

/// Every row of the old table, or null when the table is gone.
///
/// The absence is an outcome and not an error: every boot after 04-12's drop
/// runs this hook. Matched on the message rather than on a driver code so the
/// same arm serves Postgres's `42P01 relation ... does not exist` and
/// SQLite's `no such table`, which is what the unit lane raises.
Future<List<FlutterPreference>?> _readLegacyTable(AppDatabase db) async {
  try {
    return await db.select(db.flutterPreferences).get();
  } on Object catch (error) {
    final message = '$error'.toLowerCase();
    final missing = message.contains('does not exist') ||
        message.contains('no such table');
    if (missing && message.contains('flutter_preferences')) return null;
    rethrow;
  }
}

/// Writes [item] over whatever is stored, and its change row.
///
/// Returns whether anything was written. **Never skips because a row exists**
/// — see the library doc: a boot-default row is exactly what must be
/// overwritten. What it does skip is a row that already holds this content,
/// because writing identical bytes would produce a change row saying something
/// happened.
///
/// An existing row's `rev` is carried forward and bumped rather than reset, so
/// a station holding the old revision loses its next compare-and-swap instead
/// of matching a number that means something else now.
Future<bool> _writeItem(
  AppDatabase db,
  ConfigItem item, {
  required DateTime at,
  required String actionId,
  required String station,
}) async {
  final existing = await (db.select(db.configItemTable)
        ..where((t) =>
            t.kind.equals(item.kind.wireName) &
            t.id.equals(item.id) &
            t.scope.equals(item.scope.wireName)))
      .getSingleOrNull();

  final before = existing == null
      ? null
      : ConfigItem(
          kind: item.kind,
          id: item.id,
          scope: item.scope,
          parentId: existing.parentId,
          sortIndex: existing.sortIndex,
          payload: existing.payload,
          rev: existing.rev,
        );
  if (before != null && before.sameContentAs(item)) return false;

  final companion = ConfigItemTableCompanion.insert(
    kind: item.kind.wireName,
    id: item.id,
    scope: item.scope.wireName,
    parentId: Value(item.parentId),
    sortIndex: Value(item.sortIndex),
    payload: item.payload,
    rev: Value((existing?.rev ?? 0) + 1),
    updatedAt: at,
    updatedBy: _migrationActor,
  );
  if (existing == null) {
    await db.into(db.configItemTable).insert(companion);
  } else {
    await (db.update(db.configItemTable)
          ..where((t) =>
              t.kind.equals(item.kind.wireName) &
              t.id.equals(item.id) &
              t.scope.equals(item.scope.wireName)))
        .write(companion);
  }

  // Built through `ConfigChange.of` rather than by hand: it is what guarantees
  // each side is `encodeEntity()` and therefore restorable, and it is what
  // makes the row an `update` when a boot default was overwritten rather than
  // an `insert` that would contradict the row it describes.
  await _insertChange(
    db,
    ConfigChange.of(
      at: at,
      actionId: actionId,
      who: _migrationActor,
      station: station,
      roleName: _migrationRole,
      before: before,
      after: item,
    ),
  );
  return true;
}

/// One change row, unless the entity carries no history.
///
/// Asked here for the reason the store asks it inside its writer:
/// `config_change` is never pruned, so a kind exempted for the size or the
/// secrecy of its payload must be exempt on **every** path into the table,
/// including this one.
Future<void> _insertChange(AppDatabase db, ConfigChange change) =>
    historyExempt(change.kind, change.entityId)
        ? Future<void>.value()
        : db
            .into(db.configChangeTable)
            .insert(ConfigChangeTableCompanion.insert(
              at: change.at,
              actionId: change.actionId,
              who: change.who,
              station: change.station,
              roleName: change.roleName,
              kind: change.kind.wireName,
              entityId: change.entityId,
              scope: change.scope.wireName,
              op: change.op.wireName,
              oldValue: Value(change.oldValue),
              newValue: Value(change.newValue),
            ));
