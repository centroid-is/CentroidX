/// The one-shot copy of `flutter_preferences.key_mappings` into `config_item`
/// rows, run once against the database several stations share.
///
/// ## Where the machinery went
///
/// Everything this module used to do itself — the dialect refusal, the
/// pool-of-one refusal, the transaction, `pg_try_advisory_xact_lock` as its
/// first statement, the idempotency gate read inside that lock, the sort-key
/// assignment, and the marker written last — is now
/// `blob_migration.dart`'s [copyBlobIntoRows], because the pages migration is
/// the same copy over a different blob and a second implementation of it would
/// be a second chance to get the lock wrong.
///
/// The reason it could not simply be shared as-is is worth stating: the pages
/// parser needs Flutter and this package has none, so the parse is a
/// callback. This module is that callback's first caller, and its own test
/// suite — the one proved against the real 430-node plant blob — is the
/// regression proof that the hoist changed nothing.
///
/// What stays here is what is *about key mappings*: which preference key holds
/// the blob, which lock id and marker id this migration owns, and which
/// parser reads it.
///
/// ## What it deliberately does not do
///
/// It does not delete or rewrite `flutter_preferences.key_mappings`. That row
/// is the rollback insurance for the cutover and it is Phase 4's to drop.
library;

import 'package:meta/meta.dart';

import '../database.dart';
import '../database_drift.dart';
import 'blob_migration.dart';
import 'config_item.dart';
import 'key_mapping_codec.dart';

export 'blob_migration.dart' show MigrationOutcome, kConfigLockNamespace;

/// The key-mappings migration's lock id within [kConfigLockNamespace].
///
/// `2` is `kPageMigrationLock`, reserved for the pages and assets migration;
/// take the next free number rather than reusing either, so two different
/// migrations can never block each other.
const int kKeyMappingMigrationLock = 1;

/// The id of the shared row that records that this migration has run.
///
/// `kind='preference'`, `scope='shared'`, and underscore-prefixed so that it
/// is bookkeeping rather than a preference: `SqlitePreferences` already filters
/// underscore-prefixed ids out of `getKeys`, `getAll` and `clear`, so no
/// preferences surface will ever list it.
///
/// It exists because "are there any key mapping rows?" is not a complete
/// answer on its own. A plant that legitimately has zero mappings — or one
/// whose mappings were all deleted after the migration — would re-run the copy
/// on every boot forever, and each re-run would resurrect keys an operator had
/// deleted on purpose. The flag has to be about the migration, not about the
/// keys.
const String kKeyMappingsMigratedMarkerId = '_migrated.key_mappings';

/// What every log line of this migration is prefixed with, and what the
/// cutover runbook greps for.
const String _label = 'key_mappings';

/// Copies `flutter_preferences.key_mappings` into one `config_item` row per
/// key, once, on whichever station gets the lock first.
///
/// Safe to call unconditionally and from every station: it is idempotent, it
/// refuses anything that is not a single-connection Postgres, and it never
/// blocks on the lock. [remote] must be the *shared* database — the local
/// SQLite mirror returns [MigrationOutcome.notPostgres] and is untouched.
///
/// Throws [FormatException] if the stored blob cannot be parsed. That is
/// deliberate and is the one case that is not an outcome: a migration that
/// turned an unrecognisable blob into an empty configuration would look
/// exactly like a successful one. `keyMappingItemsFromBlob` is the only parser
/// of this blob in the codebase and the one the round-trip test proves against
/// the real plant value.
Future<MigrationOutcome> migrateKeyMappingsBlobToRows(Database remote) =>
    copyBlobIntoRows(
      remote.db,
      prefKey: kKeyMappingsPrefKey,
      markerId: kKeyMappingsMigratedMarkerId,
      lockId: kKeyMappingMigrationLock,
      kinds: const {ConfigKind.keyMapping},
      parse: keyMappingItemsFromBlob,
      label: _label,
      itemNoun: 'keys',
    );

/// The copy itself, with the lock already held and a transaction already open.
///
/// Kept as a named seam rather than inlined at its call sites so that the
/// ordering this migration depends on — gate, then read, then rows, then the
/// marker **last** — is provable against an in-memory database without a
/// server, and so that the integration suite can abandon a transaction
/// mid-copy the way a station losing power does. It is not a second entry
/// point: called without the lock it is exactly the race
/// [migrateKeyMappingsBlobToRows] exists to prevent.
@visibleForTesting
Future<MigrationOutcome> copyKeyMappingsIntoRows(AppDatabase db) =>
    copyBlobIntoRowsLocked(
      db,
      prefKey: kKeyMappingsPrefKey,
      markerId: kKeyMappingsMigratedMarkerId,
      kinds: const {ConfigKind.keyMapping},
      parse: keyMappingItemsFromBlob,
      label: _label,
      itemNoun: 'keys',
    );
