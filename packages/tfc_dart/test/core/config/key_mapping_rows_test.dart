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
  _preferenceTests();
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

    test('a rename changes it, though neither the count nor the rev sum moves',
        () async {
      // Rename = delete one row at rev 1, insert another at rev 1. Two
      // integers over the rows cannot see it; the change log's high-water
      // mark is what does, and a backend keyed on the first two alone kept
      // subscribing under the old name forever.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'pump3.speed',
          scope: ConfigScope.shared,
          rev: 1);
      final before = await readSharedKeyMappingFingerprint(db);

      await db.customStatement(
          "DELETE FROM config_item WHERE kind = 'key_mapping' AND id = 'pump3.speed'");
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'pump3.velocity',
          scope: ConfigScope.shared,
          rev: 1);
      await db.into(db.configChangeTable).insert(
            ConfigChangeTableCompanion.insert(
              at: DateTime.utc(2026, 9, 1),
              actionId: 'rename',
              who: 'jon',
              station: 'st1',
              roleName: 'engineer',
              kind: ConfigKind.keyMapping.wireName,
              entityId: 'pump3.velocity',
              scope: ConfigScope.shared.wireName,
              op: 'insert',
            ),
          );

      final after = await readSharedKeyMappingFingerprint(db);
      expect(after.count, before.count);
      expect(after.revSum, before.revSum);
      expect(after, isNot(before),
          reason: 'the change log moved, so the fingerprint moved');
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
    test('boots its mappings from rows, and nothing else reads the blob', () {
      // Phase 4. `readSharedKeyMappingBlob` is deleted, not merely unused: it
      // was the last thing in this binary that named `flutter_preferences`,
      // and a fallback left in place is a fallback that runs on the night the
      // drop happens.
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      expect(source, contains('readSharedKeyMappingItems'),
          reason: 'the backend must boot its mappings from config_item rows');
      expect(source.contains('readSharedKeyMappingBlob'), isFalse,
          reason: 'the blob fallback retired with the table');
      expect(source.contains('flutter_preferences'), isFalse,
          reason: 'this binary must not name the dropped table at all — the '
              'SC-2 gate searches packages/*/bin for exactly this');
    });

    test('no rows is fatal and says which migration is missing', () {
      // The other half of deleting the fallback. Rows-or-nothing means the
      // empty case has to be loud: a backend that carried on would acquire
      // from a key set nobody is editing, silently, for as long as it ran.
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      final rowsRead =
          lines.indexWhere((l) => l.contains('readSharedKeyMappingItems'));
      final refusal = lines.indexWhere((l) => l.contains('mappingItems.isEmpty'));
      expect(rowsRead, isNonNegative);
      expect(refusal, greaterThan(rowsRead));
      expect(source, contains('StateError'),
          reason: 'empty rows must throw, not fall through to a default');
      expect(source, contains('migration'),
          reason: 'the throw has to name what is missing, or the operator '
              'reads it as a database outage');
    });

    test('reads alarm_man_config as a value and never writes a default', () {
      // Fable's 04-12 ruling. The backend has one boot read and no reconcile,
      // so it cannot tell "no alarms" from "not yet migrated" — and a process
      // that cannot tell must not write. The station writes that default
      // itself, through the checked path, with an audit row behind it.
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      expect(source, contains('readSharedPreferenceValue'),
          reason: 'one row read through the shared codec, not a store');
      expect(source, contains('AlarmMan.headless'),
          reason: 'the config goes in as a value; the headless constructor '
              'takes no store, so there is nothing here that could write');
      expect(source.contains('AlarmMan.create('), isFalse,
          reason: 'AlarmMan.create seeds the empty default when the row is '
              'absent — the write this plan removed');
      expect(source.contains('Preferences.create('), isFalse,
          reason: 'the backend built a whole preferences object for one key, '
              'and that object was a writer');
    });

    test('an absent alarm row is disambiguated by the migration marker', () {
      // Both arms run empty; the marker only decides which line is logged.
      // That is the point — a backend that refused to boot over alarm
      // configuration would trade the plant's data acquisition, which is its
      // actual job, for its annunciation.
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      expect(source, contains('kPreferencesMigratedMarkerId'),
          reason: 'the purpose-built answer to "empty, or not yet migrated?"');
      expect(source, contains('AlarmManConfig(alarms: [])'),
          reason: 'absent means run with zero alarms');
      expect(source.contains('alarm'), isTrue);
      // The refusal that must NOT be there.
      final alarmThrow = lines.indexWhere((l) =>
          l.contains('alarm_man_config') && l.contains('throw'));
      expect(alarmThrow, -1,
          reason: 'absent alarm configuration must never stop the boot');
    });

    test('the blob watcher is gone and one row watcher replaced it', () {
      // Phase 4 arrived. `alarm_man_config` was the last thing keeping
      // `PreferencesWatcher` alive here, and 04-11 moved it onto a
      // `preference` row — after which a digest over the old table could only
      // ever report that the row nobody writes any more had not changed.
      // That is the same argument that removed `key_mappings` from the set in
      // Phase 2, applied to the last key in it.
      final source = _mainLinesWithoutComments().join('\n');

      expect(source.contains('PreferencesWatcher'), isFalse,
          reason: 'a digest over a table nothing writes reads as coverage and '
              'provides none');
      expect(source, contains('watchedKinds'),
          reason: 'the successor: one fingerprint over the kinds this process '
              'bakes into its isolates');
    });

    test('the watched kinds are what the isolates bake in, and no more', () {
      final lines = _mainLinesWithoutComments();
      final watched = lines.firstWhere(
        (l) => l.contains('watchedKinds ='),
        orElse: () => '',
      );

      expect(watched, isNotEmpty, reason: 'could not find the watched kinds');
      expect(watched, contains('ConfigKind.keyMapping'));
      expect(watched, contains('ConfigKind.preference'),
          reason: 'alarm_man_config is a preference row since 04-11, and the '
              'isolates bake the alarms in');
      // The two that must not be there. A page or an image write would
      // restart an acquisition backend into exactly the state it was already
      // in — and for images that means an operator pasting a picture bounces
      // the plant's data acquisition.
      expect(watched.contains('ConfigKind.page'), isFalse);
      expect(watched.contains('ConfigKind.pageImage'), isFalse);
    });

    test('subscribes to the config_change channel', () {
      final lines = _mainLinesWithoutComments();
      final source = lines.join('\n');

      expect(source, contains("listenToChannel('config_change')"),
          reason: 'without it the backend hears about a mapping edit only on '
              'the poll, up to CENTROID_CONFIG_POLL_SECONDS late');
      expect(source, contains('readSharedConfigFingerprint'),
          reason: 'the safety net for a notification missed while the '
              'connection was down — kind-general since 04-11, because the '
              'backend now watches preferences as well');
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

// ---------------------------------------------------------------------------
// The one-key preference read, for the processes that have no store
// ---------------------------------------------------------------------------

/// A `preference` row written the way `SharedRowPreferences` writes one.
Future<void> _writePreference(
  AppDatabase db,
  String key,
  String type,
  Object value,
) =>
    _insert(db,
        kind: ConfigKind.preference,
        id: key,
        scope: ConfigScope.shared,
        payload: jsonEncode({'type': type, 'value': value}));

void _preferenceTests() {
  group('readSharedPreferenceValue', () {
    late AppDatabase db;

    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = AppDatabase.inMemoryForTest();
    });
    tearDown(() => db.close());

    test('answers the value the shared row holds, through the shared codec',
        () async {
      // The backend's one key. Written as the store writes it, read back as
      // the store would read it — that is what makes this the same answer
      // rather than a second one.
      final config = jsonEncode({'alarms': []});
      await _writePreference(db, 'alarm_man_config', 'String', config);

      expect(await readSharedPreferenceValue(db, 'alarm_man_config'), config);
    });

    test('carries the type tag, so an int is not a string', () async {
      await _writePreference(db, 'poll_seconds', 'int', 30);
      expect(await readSharedPreferenceValue(db, 'poll_seconds'), 30);
      await _writePreference(db, 'ratio', 'double', 1);
      // `1` on the wire under a `double` tag is still a double: whole-numbered
      // doubles are encoded without a fraction by every JSON encoder there is.
      expect(await readSharedPreferenceValue(db, 'ratio'), isA<double>());
    });

    test('answers null when there is no row', () async {
      expect(await readSharedPreferenceValue(db, 'alarm_man_config'), null);
    });

    test('answers null for a payload this build cannot read', () async {
      // A row somebody edited by hand, or one written by a newer build with a
      // tag this one does not know. Absent is the right reading: it costs the
      // caller a default, never the boot.
      await _insert(db,
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          scope: ConfigScope.shared,
          payload: '{"type":"Widget","value":3}');
      expect(await readSharedPreferenceValue(db, 'alarm_man_config'), null);
    });

    test('does not answer a station-scoped row of the same name', () async {
      // The one thing this read must not do. `preference` is the first kind
      // that legitimately exists at both scopes; a backend that picked up one
      // station's local row would run the plant on it.
      await _writePreference(db, 'alarm_man_config', 'String', 'shared');
      await _insert(db,
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'),
          payload: jsonEncode({'type': 'String', 'value': 'local'}));

      expect(await readSharedPreferenceValue(db, 'alarm_man_config'), 'shared');
    });

    test('does not answer a row of another kind with the same id', () async {
      await _insert(db,
          kind: ConfigKind.keyMapping,
          id: 'alarm_man_config',
          scope: ConfigScope.shared);
      expect(await readSharedPreferenceValue(db, 'alarm_man_config'), null);
    });
  });
}
