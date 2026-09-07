// The rows-read the backend boots from, and the source assertions on the boot
// itself.
//
// Two kinds of assertion live here. The first opens an in-memory database and
// runs the reader against real rows. The second reads `bin/main.dart` as text,
// the way `test/boot_ordering_test.dart` reads `main.dart`: the boot sequence
// is one function body that no unit test can execute — it connects to
// Postgres, spawns isolates and then waits forever — so the only way to say
// "the rows are read before the blob" is to say it about the source. Comment
// lines are stripped first, so the comment explaining a rule cannot be what
// satisfies the test enforcing it.
//
// Run from `packages/tfc_dart`; the source assertions read `bin/` by relative
// path and say so rather than passing vacuously.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/key_mapping_rows.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// A key-mapping payload the codec would accept, so a test that goes on to
/// reassemble these rows is reassembling something real.
String _payload(String identifier) => jsonEncode({
      'opcua_node': {'namespace': 2, 'identifier': identifier},
    });

Future<void> _insert(
  AppDatabase db, {
  required ConfigKind kind,
  required String id,
  required ConfigScope scope,
  String? payload,
  int rev = 0,
}) =>
    db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: kind.wireName,
          id: id,
          scope: scope.wireName,
          payload: payload ?? _payload(id),
          rev: Value(rev),
          updatedAt: DateTime.utc(2026, 9, 7),
          updatedBy: 'tester',
        ));

/// `bin/main.dart` with every whole-line comment removed.
List<String> _mainLinesWithoutComments() {
  const path = 'bin/main.dart';
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: 'Run this suite from packages/tfc_dart. Without $path the '
          'source assertions below would pass vacuously.');
  return file
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'))
      .toList();
}

void main() {
  group('readSharedKeyMappingItems', () {
    test('returns the shared key_mapping rows, ordered by id', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      // Inserted out of order on purpose: the order has to come from the
      // query, not from the insert sequence, or the backend's key set would
      // depend on which station wrote which key first.
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'CN04.MOT01.Run',
          scope: ConfigScope.shared);
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.MOT01.Run',
          scope: ConfigScope.shared);

      final items = await readSharedKeyMappingItems(db);

      expect(items.map((i) => i.id), ['CN01.MOT01.Run', 'CN04.MOT01.Run']);
      expect(items.every((i) => i.kind == ConfigKind.keyMapping), isTrue);
      expect(items.first.payload, _payload('CN01.MOT01.Run'));
    });

    test('excludes station-scoped rows and other kinds', () async {
      // The two ways this read can go wrong quietly. A station-scoped row is
      // one machine's local copy — Phase 1 wrote `key_mappings` at
      // `station:<hostname>` and this milestone re-homes it — so including
      // one would give the backend whichever station's copy happened to be in
      // its local file. A `preference` row is another key entirely.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.MOT01.Run',
          scope: ConfigScope.shared);
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'CN02.MOT01.Run',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'));
      await _insert(db,
          kind: ConfigKind.preference,
          id: 'theme_mode',
          scope: ConfigScope.shared,
          payload: '{"t":"s","v":"dark"}');

      final items = await readSharedKeyMappingItems(db);

      expect(items.map((i) => i.id), ['CN01.MOT01.Run']);
      expect(items.single.scope, ConfigScope.shared);
    });

    test('carries rev, so a caller can tell one read from the next', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.MOT01.Run',
          scope: ConfigScope.shared,
          rev: 7);

      final items = await readSharedKeyMappingItems(db);
      expect(items.single.rev, 7);
    });

    test('an empty database reads as no items, not as a failure', () async {
      // The pre-cutover state, and the reason the backend has a fallback at
      // all. Throwing here would turn "the migration has not run yet" into a
      // backend that will not boot.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      expect(await readSharedKeyMappingItems(db), isEmpty);
    });
  });

  group('readSharedKeyMappingFingerprint', () {
    test('is (0, 0) over an empty database', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      expect(await readSharedKeyMappingFingerprint(db),
          const KeyMappingFingerprint(count: 0, revSum: 0));
    });

    test('counts the shared rows and sums their revs', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'a',
          scope: ConfigScope.shared,
          rev: 3);
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'b',
          scope: ConfigScope.shared,
          rev: 4);
      // Neither of these belongs to the fingerprint: one is another kind, the
      // other another scope.
      await _insert(db,
          kind: ConfigKind.preference,
          id: 'theme_mode',
          scope: ConfigScope.shared,
          payload: '{"t":"s","v":"dark"}',
          rev: 99);
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'c',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'),
          rev: 99);

      expect(await readSharedKeyMappingFingerprint(db),
          const KeyMappingFingerprint(count: 2, revSum: 7));
    });

    test('an update changes it without changing the count', () async {
      // Why the pair and not a row count alone: an edit to an existing key
      // leaves the count where it was. And why not a `config_change.id`
      // watermark: that column is a SERIAL, and a transaction that took a
      // lower id but committed later is skipped forever by a reader that has
      // advanced past it. `rev` has no sequence semantics — it is a property
      // of the row, and every write moves it.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'a',
          scope: ConfigScope.shared,
          rev: 1);
      final before = await readSharedKeyMappingFingerprint(db);

      await db.customStatement(
          "UPDATE config_item SET rev = 2 WHERE kind = 'key_mapping' AND id = 'a'");

      final after = await readSharedKeyMappingFingerprint(db);
      expect(after, isNot(before));
      expect(after.count, before.count);
    });
  });

  group('the backend boot, read from source', () {
    test('reads the rows before it falls back to the blob', () {
      final lines = _mainLinesWithoutComments();

      final rowsRead =
          lines.indexWhere((l) => l.contains('readSharedKeyMappingItems'));
      final blobRead =
          lines.indexWhere((l) => l.contains('KeyMappings.fromPrefs'));

      expect(rowsRead, isNonNegative,
          reason: 'the backend must boot its mappings from config_item rows');
      expect(blobRead, isNonNegative,
          reason: 'the blob fallback has to stay until Phase 4 — the backend '
              'container can restart before any station has run the migration');
      expect(rowsRead, lessThan(blobRead),
          reason: 'rows first. The other order serves the blob forever, which '
              'after the cutover is a backend running configuration nobody '
              'is editing any more.');
    });

    test('key_mappings has left the watched preference set', () {
      // A digest over a row nobody writes never changes, so leaving
      // `key_mappings` in the set is worse than removing it: it reads as
      // coverage and provides none. `alarm_man_config` is still a blob until
      // Phase 4 and keeps the watcher exactly as it was.
      final lines = _mainLinesWithoutComments();
      final watched = lines.firstWhere(
        (l) => l.contains('keys: const {'),
        orElse: () => '',
      );

      expect(watched, isNotEmpty,
          reason: 'could not find the PreferencesWatcher key set');
      expect(watched, contains('alarm_man_config'));
      expect(watched.contains('key_mappings'), isFalse,
          reason: 'the key_mappings row stops being written at the cutover; '
              'its digest can only report that nothing changed');
    });

    test('subscribes to the config_change channel', () {
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      expect(source, contains("listenToChannel('config_change')"),
          reason: 'without it the backend hears about a mapping edit only on '
              'the poll, up to CENTROID_CONFIG_POLL_SECONDS late');
      expect(source, contains('readSharedKeyMappingFingerprint'),
          reason: 'the safety net for a notification missed while the '
              'connection was down');
    });

    test('both restart paths re-arm one timer', () {
      // One quiet period, not two. Two timers means a burst of saves that
      // arrives through both paths restarts the process twice — the second
      // time in the middle of the first restart.
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      expect('Timer? restartTimer'.allMatches(source), hasLength(1),
          reason: 'one restart timer, shared by the notification path and the '
              'poll');
      expect('restartTimer = Timer('.allMatches(source), hasLength(1),
          reason: 'one place arms it — every path calls the same closure, so '
              'a burst arriving through two of them is still one restart');
    });
  });
}
