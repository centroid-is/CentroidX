/// The last migration: what each key becomes, and what the copy writes.
///
/// Everything here runs against in-memory SQLite. The advisory lock and the
/// interrupted-transaction property need a server and live in
/// `test/integration/preference_migration_test.dart`; what is provable without
/// one is the classification, the overwrite rule, the exemption split, the
/// marker, and the two skips every post-cutover boot takes.
///
/// **The rule these tests exist to protect:** `flutter_preferences` is the
/// authority for every key the migration touches. A station booting on this
/// branch writes rows from its boot defaults (D-7), so an existing row is
/// often an *empty default sitting on top of the operator's real value*. A
/// migration that skipped a key because a row existed would look successful
/// and lose plant configuration.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_consistency.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_undo.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart';
import 'package:tfc_dart/core/config/key_mapping_rows.dart';
import 'package:tfc_dart/core/config/preference_migration.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database_drift.dart';

late AppDatabase db;

/// One row of the old table, in the encoding `Preferences._upsertToPostgres`
/// really wrote: everything as text, scalars through `toString()`, a string
/// list through `join(',')`.
Future<void> seedLegacy(String key, String? value, {String type = 'String'}) =>
    db.into(db.flutterPreferences).insert(FlutterPreferencesCompanion.insert(
          key: key,
          value: Value(value),
          type: type,
        ));

/// A marker row, as its migration writes one.
Future<void> seedMarker(String id) =>
    db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: ConfigKind.preference.wireName,
          id: id,
          scope: ConfigScope.shared.wireName,
          payload: ConfigItem.of(
            kind: ConfigKind.preference,
            id: id,
            value: preferencePayload(kPrefStringType, '2026-09-01'),
          ).payload,
          rev: const Value(1),
          updatedAt: DateTime.utc(2026, 9, 1),
          updatedBy: 'migration',
        ));

/// Both siblings, so the pre-check passes.
Future<void> seedSiblingMarkers() async {
  await seedMarker(kKeyMappingsMigratedMarkerId);
  await seedMarker(kPagesMigratedMarkerId);
}

/// An existing `config_item` row — a boot default, or a station's own write.
Future<void> seedRow(ConfigItem item, {int rev = 1}) =>
    db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: item.kind.wireName,
          id: item.id,
          scope: item.scope.wireName,
          payload: item.payload,
          rev: Value(rev),
          updatedAt: DateTime.utc(2026, 9, 1),
          updatedBy: 'boot-default',
        ));

Future<List<ConfigItemRow>> itemRows() =>
    (db.select(db.configItemTable)..orderBy([(t) => OrderingTerm(expression: t.id)]))
        .get();

Future<List<ConfigChangeRow>> changeRows() =>
    (db.select(db.configChangeTable)
          ..orderBy([(t) => OrderingTerm(expression: t.id)]))
        .get();

Future<ConfigItemRow?> rowFor(ConfigKind kind, String id) =>
    (db.select(db.configItemTable)
          ..where((t) => t.kind.equals(kind.wireName) & t.id.equals(id)))
        .getSingleOrNull();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => db = AppDatabase.inMemoryForTest());
  tearDown(() => db.close());

  group('classification decides every key without a database', () {
    test('the five exact families become preference rows', () {
      for (final key in kMigratedPreferenceKeys) {
        final c = classifyPreferenceKey(key);
        expect(c.disposition, PreferenceDisposition.migrate, reason: key);
        expect(c.kind, ConfigKind.preference, reason: key);
        expect(c.id, key, reason: key);
      }
    });

    test('an image becomes a page_image row keyed by the suffix, verbatim',
        () {
      final c = classifyPreferenceKey('page_editor_image:9f86d081884c');

      expect(c.disposition, PreferenceDisposition.migrate);
      expect(c.kind, ConfigKind.pageImage,
          reason: 'a preference row would lose the history exemption and put '
              'both sides of a multi-megabyte payload into a table nothing '
              'prunes');
      expect(c.id, '9f86d081884c',
          reason: 'every asset references this exact string in image_id; a '
              'freshly derived hash would orphan the row');
    });

    test('a recipe bucket becomes one preference row per bucket', () {
      final c = classifyPreferenceKey('line1.recipes');
      expect(c.disposition, PreferenceDisposition.migrate);
      expect(c.kind, ConfigKind.preference);
      expect(c.id, 'line1.recipes');
      // The suffix alone is not a bucket.
      expect(classifyPreferenceKey('.recipes').disposition,
          PreferenceDisposition.unknown);
    });

    test('every abandoned key is abandoned with a reason', () {
      for (final entry in kAbandonedPreferenceKeys.entries) {
        final c = classifyPreferenceKey(entry.key);
        expect(c.disposition, PreferenceDisposition.abandon,
            reason: entry.key);
        expect(c.reason, isNotNull, reason: entry.key);
      }
    });

    test('state_man_config is abandoned: the keychain is its only reader', () {
      final c = classifyPreferenceKey('state_man_config');
      expect(c.disposition, PreferenceDisposition.abandon,
          reason: 'StateManConfig reads and writes it secret: true. A shared '
              'row of it is the plant\'s PLC endpoints and credentials copied '
              'into a replicated table and a permanent log, for no reader');
      expect(kMigratedPreferenceKeys, isNot(contains('state_man_config')));
    });

    test('the chat assistant\'s rows and the LLM settings migrate by prefix',
        () {
      for (final key in [
        'chat.history',
        'chat.conversations',
        'chat.active_conversation',
        'chat.conversation.7f3a',
      ]) {
        final c = classifyPreferenceKey(key);
        expect(c.disposition, PreferenceDisposition.migrate, reason: key);
        expect(c.family, 'chat', reason: key);
        expect(c.kind, ConfigKind.preference, reason: key);
        expect(c.id, key, reason: key);
      }
      for (final key in ['llm.selected_provider', 'llm.claude.base_url']) {
        final c = classifyPreferenceKey(key);
        expect(c.disposition, PreferenceDisposition.migrate, reason: key);
        expect(c.family, 'llm', reason: key);
        expect(c.id, key, reason: key);
      }
      // The bare prefix names nothing.
      expect(classifyPreferenceKey('chat.').disposition,
          PreferenceDisposition.unknown);
      expect(classifyPreferenceKey('llm.').disposition,
          PreferenceDisposition.unknown);
    });

    test('update_channel is abandoned, never promoted to a shared row', () {
      final c = classifyPreferenceKey('update_channel');

      expect(c.disposition, PreferenceDisposition.abandon);
      expect(c.reason, contains('device-local'),
          reason: 'update_channel.dart builds device-local preferences on '
              'purpose: a dev box on a prerelease must not move every HMI in '
              'the plant onto it');
    });

    test('mcp.config is abandoned, because nothing reads the shared row', () {
      // **This verdict has flipped twice, and only ever on a consumer grep.**
      // It was abandoned first on owner-reasoning (device-local for the app,
      // the shared row is the stale copy `mcpConfigMigrationProvider`
      // deletes) — right by luck, wrong by argument, because
      // `tfc_mcp_server.dart`'s `_readTogglesFromDb` read that shared row at
      // every server start and defaulted a missing key to **enabled**. So it
      // was corrected to migrate.
      //
      // That reader no longer exists. `d47f7633` deleted `_readTogglesFromDb`
      // — the binary now takes its toggles from the spawner, which is the
      // deciding device handing the decision down — and `b1b60726` deleted
      // the drift table class it read through. The remaining two mentions of
      // the key are the app's `mcpConfigProvider`, which reads
      // `localPreferencesProvider`, and `migrateMcpConfigToDeviceLocal`,
      // which does not read the shared row as a setting: it copies it down
      // once and deletes it.
      //
      // Migrating it now would be worse than useless. The raw preferences
      // editor merges shared keys OVER device-local ones, so the row would
      // mask this station's real value and offer an `administer`-gated edit
      // that changes nothing anywhere.
      final c = classifyPreferenceKey('mcp.config');

      expect(c.disposition, PreferenceDisposition.abandon);
      expect(kMigratedPreferenceKeys, isNot(contains('mcp.config')),
          reason: 'a migrated row with no consumer is an editable setting '
              'that does nothing');
      expect(kAbandonedPreferenceKeys['mcp.config'], isNotNull,
          reason: 'abandoning a key waves the drop through, so the entry has '
              'to carry the reason it may be');
      // The entry must name its readers, not its owner — the rule the doc on
      // `kAbandonedPreferenceKeys` states. Both deletions are cited by hash
      // so the claim stays checkable against the history rather than being
      // taken on trust.
      final reason = kAbandonedPreferenceKeys['mcp.config']!;
      expect(reason, contains('d47f7633'));
      expect(reason, contains('b1b60726'));
    });

    test('the legacy MCP toggle keys still land in unknown, and that is what '
        'protects the older plant', () {
      // The asymmetry worth knowing about: a plant still carrying the
      // per-tool keys is protected by the drop gate refusing on unknowns,
      // while a plant on the consolidated blob alone would have sailed
      // through. The gates protect the older plant better than the newer one,
      // which is the opposite of what a reader assumes.
      expect(classifyPreferenceKey('mcp_tools_write_enabled').disposition,
          PreferenceDisposition.unknown);
    });

    test('a marker is bookkeeping, whatever else it is called', () {
      expect(classifyPreferenceKey('_migrated.key_mappings').disposition,
          PreferenceDisposition.abandon);
      expect(classifyPreferenceKey('_imported.preferences').disposition,
          PreferenceDisposition.abandon);
    });

    test('anything else is unknown — never guessed at', () {
      expect(classifyPreferenceKey('some.plant.key.nobody.here.knows')
          .disposition, PreferenceDisposition.unknown);
      expect(classifyPreferenceKey('alarm_man_configX').disposition,
          PreferenceDisposition.unknown,
          reason: 'matching is exact; a near-miss is not a family');
    });
  });

  group('the legacy value decoding is the old table\'s own', () {
    test('each type tag round-trips as the type it names', () {
      expect(decodeLegacyPreferenceValue(kPrefBoolType, 'true'), isTrue);
      expect(decodeLegacyPreferenceValue(kPrefBoolType, 'false'), isFalse);
      expect(decodeLegacyPreferenceValue(kPrefIntType, '7'), 7);
      expect(decodeLegacyPreferenceValue(kPrefDoubleType, '0.5'), 0.5);
      expect(decodeLegacyPreferenceValue(kPrefStringType, 'hello'), 'hello');
      expect(decodeLegacyPreferenceValue(kPrefStringListType, 'a,b'),
          ['a', 'b']);
      expect(decodeLegacyPreferenceValue(kPrefStringListType, ''),
          isEmpty);
    });

    test('a tag this build does not know reads as absent, not as a throw', () {
      // `Preferences.loadFromPostgres` throws here, which is right for a load
      // that must not serve half a configuration. A migration that threw
      // would abandon every other key over one bad row.
      expect(decodeLegacyPreferenceValue('Duration', '5'), isNull);
      expect(decodeLegacyPreferenceValue(kPrefIntType, 'not-a-number'),
          isNull);
    });
  });

  group('the copy', () {
    test('migrates the families, types intact', () async {
      await seedSiblingMarkers();
      await seedLegacy('alarm_man_config', '{"alarms":[]}');
      await seedLegacy('collector_config', '42', type: kPrefIntType);
      await seedLegacy('page_editor_top_level_order', 'a,b',
          type: kPrefStringListType);

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.outcome, PreferenceMigrationOutcome.migrated);
      expect(result.migratedCount, 3);

      final alarms = await rowFor(ConfigKind.preference, 'alarm_man_config');
      expect(decodePreferencePayload(alarms!.payload), '{"alarms":[]}');
      final collector =
          await rowFor(ConfigKind.preference, 'collector_config');
      expect(decodePreferencePayload(collector!.payload), 42,
          reason: 'the type tag travels with the value, so an int stays an '
              'int rather than becoming the string "42"');
      final order =
          await rowFor(ConfigKind.preference, 'page_editor_top_level_order');
      expect(decodePreferencePayload(order!.payload), ['a', 'b']);
    });

    test('an image lands on a page_image row with no change row', () async {
      await seedSiblingMarkers();
      await seedLegacy('page_editor_image:abc123', 'aGVsbG8=');

      await copyPreferencesIntoRowsLocked(db);

      final image = await rowFor(ConfigKind.pageImage, 'abc123');
      expect(image, isNotNull);
      expect(image!.payload, contains('aGVsbG8='));
      expect(
          (await changeRows()).where((r) => r.entityId == 'abc123'), isEmpty,
          reason: 'page_image is history-exempt; a change row would put both '
              'sides of the payload into a table nothing prunes');
    });

    test('the envelope migrates and keeps its exemption', () async {
      await seedSiblingMarkers();
      await seedLegacy('server_config_envelope', 'ciphertext');

      await copyPreferencesIntoRowsLocked(db);

      expect(await rowFor(ConfigKind.preference, 'server_config_envelope'),
          isNotNull);
      expect(
          (await changeRows())
              .where((r) => r.entityId == 'server_config_envelope'),
          isEmpty,
          reason: 'exempting it keeps a superseded ciphertext\'s lifetime what '
              'it is today rather than granting it retention-forever');
    });

    test('an unknown key is left untouched and reported', () async {
      await seedSiblingMarkers();
      await seedLegacy('some.plant.key', 'value');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.unknown, ['some.plant.key']);
      expect(await rowFor(ConfigKind.preference, 'some.plant.key'), isNull);
      // Still in the old table: the migration reads, it never deletes.
      final legacy = await db.select(db.flutterPreferences).get();
      expect(legacy.map((r) => r.key), contains('some.plant.key'));
    });

    test('a known key whose value cannot be read joins the unknowns', () async {
      await seedSiblingMarkers();
      await seedLegacy('collector_config', '5', type: 'Duration');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.unknown, ['collector_config'],
          reason: 'reported rather than guessed at, so the drop tool refuses '
              'while it is there');
      expect(await rowFor(ConfigKind.preference, 'collector_config'), isNull);
    });
  });

  group('flutter_preferences is the authority (D-7)', () {
    test('a boot-default row is overwritten, not treated as done', () async {
      await seedSiblingMarkers();
      // The state D-7 produces: a station booted, wrote an empty default into
      // the shared store, and the operator's real value is still in the old
      // table.
      await seedRow(ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'alarm_man_config',
        value: preferencePayload(kPrefStringType, '{}'),
      ));
      await seedLegacy('alarm_man_config', '{"alarms":[{"key":"CN04"}]}');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.migratedCount, 1);
      final row = await rowFor(ConfigKind.preference, 'alarm_man_config');
      expect(decodePreferencePayload(row!.payload),
          '{"alarms":[{"key":"CN04"}]}',
          reason: 'skipping this key because a row existed would discard the '
              "operator's real configuration and look like success");
      expect(row.rev, 2,
          reason: 'the revision carries forward and bumps, so a station '
              'holding rev 1 loses its next compare-and-swap rather than '
              'matching a number that now means something else');
    });

    test('the overwrite is recorded as an update, not an insert', () async {
      await seedSiblingMarkers();
      await seedRow(ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'alarm_man_config',
        value: preferencePayload(kPrefStringType, '{}'),
      ));
      await seedLegacy('alarm_man_config', '{"alarms":[]}');

      await copyPreferencesIntoRowsLocked(db);

      final change = (await changeRows())
          .firstWhere((r) => r.entityId == 'alarm_man_config');
      expect(change.op, ConfigChangeOp.update.wireName);
      expect(change.oldValue, isNotNull,
          reason: 'the old side is what makes the boot default restorable, '
              'and an insert row would contradict the row it describes');
    });

    test('a row that already holds the value is written as nothing', () async {
      await seedSiblingMarkers();
      final same = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'alarm_man_config',
        value: preferencePayload(kPrefStringType, '{"alarms":[]}'),
      );
      await seedRow(same);
      await seedLegacy('alarm_man_config', '{"alarms":[]}');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.migratedCount, 1,
          reason: 'the key is in rows, which is what the count means');
      expect(
          (await changeRows()).where((r) => r.entityId == 'alarm_man_config'),
          isEmpty,
          reason: 'writing identical bytes would log an edit nobody made');
      expect((await rowFor(ConfigKind.preference, 'alarm_man_config'))!.rev, 1);
    });
  });

  group('the marker, and what it makes safe', () {
    test('the marker is written last and shares the values\' action',
        () async {
      await seedSiblingMarkers();
      await seedLegacy('alarm_man_config', '{}');

      final result = await copyPreferencesIntoRowsLocked(db);

      final marker =
          await rowFor(ConfigKind.preference, kPreferencesMigratedMarkerId);
      expect(marker, isNotNull);
      final rows = await changeRows();
      expect(rows.map((r) => r.actionId).toSet(), {result.actionId});
      expect(rows.last.entityId, kPreferencesMigratedMarkerId,
          reason: 'last, so a process killed mid-copy rolls back rows and '
              'marker together');
    });

    test('the whole migration cannot be undone, because the marker is in it',
        () async {
      // The property constraint 1 is for, end to end rather than asserted
      // about the design: one action id over marker and values means
      // config_undo refuses the action whole, so the values cannot be
      // deleted on their own — and after 04-12 the change rows are the only
      // copy of them.
      await seedSiblingMarkers();
      await seedLegacy('alarm_man_config', '{}');
      await seedLegacy('collector_config', '{}');

      final result = await copyPreferencesIntoRowsLocked(db);
      final plan = await planUndo(db, result.actionId!);

      expect(plan.isReady, isFalse);
      expect(plan.blockers.map((b) => b.reason),
          contains(UndoBlockReason.internalRow));
      expect(plan.blockers.single.entityId, kPreferencesMigratedMarkerId,
          reason: 'all-or-nothing: one blocked entity refuses the action, so '
              'the migrated values are unreachable too');
    });

    test('a second run is a no-op', () async {
      await seedSiblingMarkers();
      await seedLegacy('alarm_man_config', '{}');
      await copyPreferencesIntoRowsLocked(db);
      final before = await changeRows();

      final second = await copyPreferencesIntoRowsLocked(db);

      expect(second.outcome, PreferenceMigrationOutcome.alreadyDone);
      expect((await changeRows()).length, before.length);
    });

    test('the migration leaves the store consistent with its own log',
        () async {
      await seedSiblingMarkers();
      await seedLegacy('alarm_man_config', '{}');
      await seedLegacy('page_editor_image:abc123', 'aGVsbG8=');
      await seedRow(ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'collector_config',
        value: preferencePayload(kPrefStringType, 'old'),
      ));
      await seedLegacy('collector_config', 'new');

      await copyPreferencesIntoRowsLocked(db);

      // The migration must not be the first writer that skips the log.
      //
      // The two findings that remain are **not** this migration's, and they
      // are worth stating rather than filtering away: `seedMarker` writes the
      // sibling markers exactly as `blob_migration.dart` really writes them —
      // the row, and no change row — so every plant migrated by Phases 2 and 3
      // carries two rows that `checkConfigConsistency` calls
      // `missing_history`. This migration's own marker does not, because it
      // logs one under the values' action id, which is what makes the whole
      // action unundoable.
      final found = await checkConfigConsistency(db);
      expect(found.map((f) => f.entityId).toSet(),
          {kKeyMappingsMigratedMarkerId, kPagesMigratedMarkerId});
      expect(found.every((f) => f.invariant == ConfigInvariant.missingHistory),
          isTrue);
      expect(
          found.map((f) => f.entityId),
          isNot(contains(kPreferencesMigratedMarkerId)),
          reason: 'this migration logs its own marker, so it is consistent '
              'with its history where its two siblings are not');
    });
  });

  group('the two skips every post-cutover boot takes', () {
    test('a missing sibling marker is a loud skip, never a throw', () async {
      // Ordering at the attach site is registration order plus this
      // pre-check. If it ever regresses on a fresh database a throw would
      // take the attach down with it — every sibling migration queued behind
      // this one, and the store never handed to the sync engine. A station
      // that does not come up is worse than a migration that did not run.
      await seedMarker(kKeyMappingsMigratedMarkerId);
      // No pages marker — and a pages blob that migration has yet to move.
      await seedLegacy('page_editor_data', '{}');
      await seedLegacy('alarm_man_config', '{}');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.outcome, PreferenceMigrationOutcome.siblingsNotMigrated);
      expect(await itemRows(), hasLength(1), reason: 'nothing was written');
      expect(await changeRows(), isEmpty);
    });

    test('a sibling with no blob to move is not waited for', () async {
      // A plant that never customised its pages: no `page_editor_data` row,
      // so the pages migration (on an older build of it) wrote no marker.
      // Waiting for a marker that will never come would skip this migration
      // on every boot, forever, and the plant would come up with no alarms.
      await seedMarker(kKeyMappingsMigratedMarkerId);
      await seedLegacy('alarm_man_config', '{"alarms":[]}');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.outcome, PreferenceMigrationOutcome.migrated);
      expect(result.migratedByFamily, {'alarm_man_config': 1});
      expect((await itemRows()).map((r) => r.id),
          contains(kPreferencesMigratedMarkerId));
    });

    test('an already-dropped table is an outcome, not an error', () async {
      // Every boot after 04-12 reaches this.
      await seedSiblingMarkers();
      await db.customStatement('DROP TABLE flutter_preferences');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.outcome, PreferenceMigrationOutcome.noTable);
      expect(await changeRows(), isEmpty);
    });

    test('an already-migrated database writes nothing', () async {
      await seedSiblingMarkers();
      await seedMarker(kPreferencesMigratedMarkerId);
      await seedLegacy('alarm_man_config', '{}');

      final result = await copyPreferencesIntoRowsLocked(db);

      expect(result.outcome, PreferenceMigrationOutcome.alreadyDone);
      expect(await changeRows(), isEmpty);
    });
  });

  group('the fingerprint the backend restarts on', () {
    /// One shared row of [kind], at [rev].
    Future<void> row(ConfigKind kind, String id, {int rev = 1}) =>
        db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
              kind: kind.wireName,
              id: id,
              scope: ConfigScope.shared.wireName,
              payload: '{"v":1}',
              rev: Value(rev),
              updatedAt: DateTime.utc(2026, 9, 1),
              updatedBy: 'tester',
            ));

    const watched = {ConfigKind.keyMapping, ConfigKind.preference};

    test('a preference row change moves it — the alarm restart path',
        () async {
      await row(ConfigKind.keyMapping, 'CN04.Belt.Speed');
      final before = await readSharedConfigFingerprint(db, watched);

      // An HMI station edits the alarms. Before 04-11 this was a
      // `flutter_preferences` blob watched by a digest; now it is a row, and
      // the backend has to notice or its isolates keep yesterday's alarms.
      await row(ConfigKind.preference, 'alarm_man_config');

      expect(await readSharedConfigFingerprint(db, watched),
          isNot(before));
    });

    test('an edit to an existing row moves it too', () async {
      await row(ConfigKind.preference, 'alarm_man_config');
      final before = await readSharedConfigFingerprint(db, watched);

      await (db.update(db.configItemTable)
            ..where((t) => t.id.equals('alarm_man_config')))
          .write(const ConfigItemTableCompanion(rev: Value(2)));

      expect(await readSharedConfigFingerprint(db, watched), isNot(before),
          reason: 'count stays where it was, so revSum is what has to move');
    });

    test('an exempt page_image row does not move it', () async {
      await row(ConfigKind.preference, 'alarm_man_config');
      final before = await readSharedConfigFingerprint(db, watched);

      await row(ConfigKind.pageImage, 'abc123');

      expect(await readSharedConfigFingerprint(db, watched), before,
          reason: 'an operator pasting a picture must not bounce the plant\'s '
              'data acquisition');
    });

    test('a page row does not move it either', () async {
      await row(ConfigKind.preference, 'alarm_man_config');
      final before = await readSharedConfigFingerprint(db, watched);

      await row(ConfigKind.page, '/roe');

      expect(await readSharedConfigFingerprint(db, watched), before,
          reason: 'the backend would restart to boot into exactly the state '
              'it was already in');
    });

    test('the old name still answers for key mappings alone', () async {
      await row(ConfigKind.keyMapping, 'CN04.Belt.Speed');
      await row(ConfigKind.preference, 'alarm_man_config');

      expect(await readSharedKeyMappingFingerprint(db),
          await readSharedConfigFingerprint(
              db, const {ConfigKind.keyMapping}),
          reason: 'the wrapper is one line and must stay one line');
    });

    test('watching no kinds watches nothing, not everything', () async {
      await row(ConfigKind.preference, 'alarm_man_config');

      expect(await readSharedConfigFingerprint(db, const {}),
          const KeyMappingFingerprint(count: 0, revSum: 0),
          reason: 'a caller that computed an empty kind set must not silently '
              'start watching the whole table');
    });
  });

  group('the evidence line the runbook greps for', () {
    test('carries the counts, the families and the unknown names', () async {
      await seedSiblingMarkers();
      await seedLegacy('alarm_man_config', '{}');
      await seedLegacy('page_editor_image:abc', 'aGk=');
      await seedLegacy('line1.recipes', '[]');
      await seedLegacy('update_channel', 'stable');
      await seedLegacy('mystery.key', 'x');

      final result = await copyPreferencesIntoRowsLocked(db);

      final line = result.evidenceLine;
      expect(line, startsWith('Preference migration: 3 migrated'));
      expect(line, contains('alarm_man_config: 1'));
      expect(line, contains('images: 1'));
      expect(line, contains('recipes: 1'));
      expect(line, contains('1 abandoned'));
      expect(line, contains('1 unknown [mystery.key]'),
          reason: 'the names, not just the count: 04-12 refuses while any '
              'unknown remains and an operator has to know which');
    });
  });
}
