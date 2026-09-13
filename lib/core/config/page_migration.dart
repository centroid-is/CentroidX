/// The one-shot copy of `flutter_preferences.page_editor_data` into
/// `config_item` rows: every page one row, every top-level asset one row.
///
/// ## Why this half is in the app
///
/// The transaction, `pg_try_advisory_xact_lock` as its first statement, the
/// idempotency gate read inside that lock, the sort keys and the marker
/// written last are all `tfc_dart`'s `blob_migration.dart`, shared with the
/// key-mappings migration Phase 2 landed. What cannot live there is the
/// *parse*: `pageItemsFromBlob` needs `AssetPage`, which needs Flutter, and
/// `tfc_dart` deliberately has none so that the backend, the collector and
/// the MCP `dart compile exe` binary can depend on it.
///
/// So this file is the parser and the four constants that name this
/// migration, and nothing else. There is no lock here, no transaction and no
/// insert; adding one would be a second write path to the shared rows with
/// none of the protection the first one has.
///
/// ## What it deliberately does not do
///
/// It does not delete or rewrite `flutter_preferences.page_editor_data`. That
/// row is the rollback insurance for the cutover — and the thing
/// `tools/svn_mirror_page.py` and `bin/page_geometry.dart` still read — and
/// dropping it is Phase 4's, after the fresh-dump round-trip gate.
library;

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/config/blob_migration.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show kPagesMigratedMarkerId;
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'page_codec.dart';

/// What every log line of this migration is prefixed with, and what the
/// cutover runbook greps for.
const String _label = 'pages';

final Logger _logger = Logger();

/// The kinds one page blob becomes.
///
/// Both, always, and in one transaction: they come out of one blob, and
/// "pages migrated, assets did not" is a state
/// [kPagesMigratedMarkerId]'s single marker makes unreachable by design —
/// `kMigrationMarkerIds` maps both kinds to it.
const Set<ConfigKind> _pageKinds = {ConfigKind.page, ConfigKind.asset};

/// Copies `flutter_preferences.page_editor_data` into page and asset rows,
/// once, on whichever station gets the lock first.
///
/// Safe to call unconditionally and from every station: idempotent, refuses
/// anything that is not a single-connection Postgres, and never blocks on the
/// lock. [remote] must be the *shared* database — the local SQLite mirror
/// returns [MigrationOutcome.notPostgres] and is untouched.
///
/// Throws [FormatException] if the stored blob cannot be parsed, and the
/// transaction unwinds with it: a migration that turned an unrecognisable
/// blob into an empty layout would leave every station on the hardcoded
/// default page and a log line saying the migration was fine.
Future<MigrationOutcome> migratePageBlobToRows(Database remote) =>
    copyBlobIntoRows(
      remote.db,
      prefKey: kPageEditorPrefKey,
      markerId: kPagesMigratedMarkerId,
      lockId: kPageMigrationLock,
      kinds: _pageKinds,
      parse: parsePageBlob,
      label: _label,
    );

/// The copy itself, with the lock already held and a transaction already open.
///
/// Kept as a named seam, exactly as `copyKeyMappingsIntoRows` is, so that the
/// ordering this migration depends on — gate, then read, then parse, then
/// rows, then the marker **last** — is provable against an in-memory database
/// without a server. It is not a second entry point: called without the lock
/// it is the race [migratePageBlobToRows] exists to prevent.
Future<MigrationOutcome> copyPageBlobIntoRows(AppDatabase db) =>
    copyBlobIntoRowsLocked(
      db,
      prefKey: kPageEditorPrefKey,
      markerId: kPagesMigratedMarkerId,
      kinds: _pageKinds,
      parse: parsePageBlob,
      label: _label,
    );

/// The blob read as items, with the count logged before anything is written.
///
/// `pageItemsFromBlob` derives the ids — that is its default and this is the
/// one call site where deriving is correct, because the migration is the one
/// moment at which two stations reading the same blob *must* reach the same
/// rows. Every other caller mints random ids, so that two editors adding an
/// asset at the same index of the same page get two rows rather than one.
///
/// The counts are read back out of the items through `pagesOf` rather than
/// counted off the list: it is the reassembly every station will do at boot,
/// so a layout that cannot be read back fails here, inside the transaction,
/// with the rows still unwritten — rather than on nine screens afterwards.
/// "9 pages, 196 assets" is the line an engineer reads before agreeing to a
/// cutover.
List<ConfigItem> parsePageBlob(String blob) {
  final items = pageItemsFromBlob(blob);
  final pages = pagesOf(items);
  _logger.i('$_label migration: ${pages.length} pages, '
      '${topLevelAssets(pages).length} assets read from $kPageEditorPrefKey');
  return items;
}
