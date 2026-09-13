// The pages read the MCP server answers from, and the pin that keeps it
// answerable from a `dart compile exe` binary.
//
// Two kinds of assertion live here.
//
// The first opens an in-memory database and runs the readers against real
// rows. It opens [ConfigItemSchema] rather than `AppDatabase` on purpose:
// `AppDatabase` lives in `database_drift.dart`, which reaches open62541, and a
// suite that could only be written against it would not have proved the thing
// this file exists to prove. One test at the end does use `AppDatabase`, to
// show the same accessor attaches to a database whose schema was generated
// somewhere else — that is the arrangement production runs in.
//
// The second walks the import graph out of `page_rows.dart` and out of the
// barrel and fails if either can reach `dart:ffi`, Flutter, open62541 or jbtm.
// It is a walk and not a list of expected imports because deferred defect D-3
// arrived one import deep — `config_service.dart` imported
// `key_mapping_codec.dart`, which imports `state_man.dart`, which links
// open62541 — and nothing that only looked at the first file's own import
// block would have seen it. `key_mapping_codec.dart` is used below as the
// positive control: the walk must still report it, or the walk is measuring
// nothing.
//
// Run from `packages/tfc_dart`; the graph walk reads `lib/` by relative path
// and says so rather than passing vacuously.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_item_table.dart';
import 'package:tfc_dart/core/config/page_rows.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;

/// A database that declares `config_item` and nothing else.
///
/// [ConfigItemSchema] is never opened in production — see its own header — but
/// opening it here is what lets every read below run without `AppDatabase`,
/// and therefore without the FFI this file is pinning against.
GeneratedDatabase _schemaDb() => ConfigItemSchema(NativeDatabase.memory());

Future<void> _insert(
  GeneratedDatabase db, {
  required ConfigKind kind,
  required String id,
  ConfigScope scope = ConfigScope.shared,
  String? parentId,
  int? sortIndex,
  Map<String, dynamic> payload = const {},
  String? rawPayload,
  int rev = 0,
}) {
  final table = $ConfigItemTableTable(db);
  return db.into(table).insert(ConfigItemTableCompanion.insert(
        kind: kind.wireName,
        id: id,
        scope: scope.wireName,
        parentId: Value(parentId),
        sortIndex: Value(sortIndex),
        payload: rawPayload ?? jsonEncode(payload),
        rev: Value(rev),
        updatedAt: DateTime.utc(2026, 9, 7),
        updatedBy: 'tester',
      ));
}

/// A page payload shaped the way `pageFieldsOf` produces one.
Map<String, dynamic> _page(String path, {String title = 'A page'}) => {
      'title': title,
      'menu_item': {'path': path, 'label': title},
    };

Map<String, dynamic> _asset(String text) => {'asset_name': 'lamp', 'text': text};

void main() {
  group('readSharedPageItems', () {
    test('returns the shared page rows, ordered by id', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      // Inserted out of order: the order has to come from the query, not from
      // whichever station happened to write which page first.
      await _insert(db, kind: ConfigKind.page, id: 'p2', payload: _page('/b'));
      await _insert(db, kind: ConfigKind.page, id: 'p1', payload: _page('/a'));

      final items = await readSharedPageItems(db);

      expect(items.map((i) => i.id), ['p1', 'p2']);
      expect(items.every((i) => i.kind == ConfigKind.page), isTrue);
      expect(items.every((i) => i.scope == ConfigScope.shared), isTrue);
    });

    test('ignores rows of another kind or another scope', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db, kind: ConfigKind.page, id: 'p1', payload: _page('/a'));
      await _insert(db,
          kind: ConfigKind.page,
          id: 'p2',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'),
          payload: _page('/local'));
      await _insert(db,
          kind: ConfigKind.asset, id: 'a1', payload: _asset('not a page'));

      expect((await readSharedPageItems(db)).map((i) => i.id), ['p1']);
    });

    test('is empty, not an error, before the migration has run', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      expect(await readSharedPageItems(db), isEmpty);
      expect(await readSharedPageLayout(db), isEmpty);
    });
  });

  group('readSharedAssetItems', () {
    test('carries parent_id and sort_index off the columns', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db,
          kind: ConfigKind.asset,
          id: 'a1',
          parentId: 'p1',
          sortIndex: 3,
          payload: _asset('lamp'));

      final item = (await readSharedAssetItems(db)).single;

      expect(item.parentId, 'p1');
      expect(item.sortIndex, 3);
      // The payload is byte-for-byte what was stored: position lives in the
      // columns and must not leak into the entity's own JSON.
      expect(item.decode(), _asset('lamp'));
    });

    test('narrows to one page when given a parentId', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db,
          kind: ConfigKind.asset, id: 'a1', parentId: 'p1', sortIndex: 0);
      await _insert(db,
          kind: ConfigKind.asset, id: 'a2', parentId: 'p2', sortIndex: 0);

      expect((await readSharedAssetItems(db, parentId: 'p1')).map((i) => i.id),
          ['a1']);
      expect((await readSharedAssetItems(db)).map((i) => i.id), ['a1', 'a2']);
    });
  });

  group('readSharedPageLayout', () {
    test('returns the pages and every page\'s assets', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db, kind: ConfigKind.page, id: 'p1', payload: _page('/a'));
      await _insert(db,
          kind: ConfigKind.asset, id: 'a1', parentId: 'p1', sortIndex: 0);
      await _insert(db, kind: ConfigKind.keyMapping, id: 'CN04.MOT01.Run');

      final items = await readSharedPageLayout(db);

      expect(items.map((i) => i.kind).toSet(),
          {ConfigKind.page, ConfigKind.asset});
      expect(items.map((i) => i.id), ['p1', 'a1']);
    });
  });

  group('pagesJsonOf', () {
    test('keys by the path in the payload and puts the assets back', () {
      final pages = pagesJsonOf([
        ConfigItem(
            kind: ConfigKind.page, id: 'p1', payload: jsonEncode(_page('/roe'))),
        ConfigItem(
            kind: ConfigKind.asset,
            id: 'a2',
            parentId: 'p1',
            sortIndex: 1,
            payload: jsonEncode(_asset('second'))),
        ConfigItem(
            kind: ConfigKind.asset,
            id: 'a1',
            parentId: 'p1',
            sortIndex: 0,
            payload: jsonEncode(_asset('first'))),
      ]);

      expect(pages.keys, ['/roe']);
      final assets = pages['/roe']!['assets'] as List;
      expect([for (final a in assets) (a as Map)['text']], ['first', 'second'],
          reason: 'paint order is sort_index, and it decides what is drawn on '
              'top of what');
      expect(pages['/roe']!['title'], 'A page');
    });

    test('gives a page with no assets an empty list, not null', () {
      final pages = pagesJsonOf([
        ConfigItem(
            kind: ConfigKind.page,
            id: 'p1',
            payload: jsonEncode(_page('/baader'))),
      ]);

      expect(pages['/baader']!['assets'], isEmpty);
      expect(pages['/baader']!.containsKey('assets'), isTrue);
    });

    test('drops an asset whose parent is not among the items', () {
      final pages = pagesJsonOf([
        ConfigItem(
            kind: ConfigKind.page, id: 'p1', payload: jsonEncode(_page('/a'))),
        ConfigItem(
            kind: ConfigKind.asset,
            id: 'orphan',
            parentId: 'gone',
            sortIndex: 0,
            payload: jsonEncode(_asset('orphan'))),
      ]);

      expect(pages.keys, ['/a']);
      expect(pages['/a']!['assets'], isEmpty);
    });

    test('ignores an asset with no parent at all', () {
      final pages = pagesJsonOf([
        ConfigItem(
            kind: ConfigKind.page, id: 'p1', payload: jsonEncode(_page('/a'))),
        ConfigItem(
            kind: ConfigKind.asset,
            id: 'loose',
            payload: jsonEncode(_asset('loose'))),
      ]);

      expect(pages['/a']!['assets'], isEmpty);
    });

    test('ignores kinds that are not pages or assets', () {
      final pages = pagesJsonOf([
        ConfigItem(
            kind: ConfigKind.page, id: 'p1', payload: jsonEncode(_page('/a'))),
        ConfigItem(kind: ConfigKind.keyMapping, id: 'k', payload: '{}'),
        ConfigItem(kind: ConfigKind.preference, id: 'theme_mode', payload: '{}'),
        ConfigItem(kind: ConfigKind.pageImage, id: 'sha', payload: '{}'),
      ]);

      expect(pages.keys, ['/a']);
    });

    test('slugs a path-less page and writes the path back into its menu item',
        () {
      // Two path-less pages would both land on '' and one would silently
      // overwrite the other.
      final pages = pagesJsonOf([
        ConfigItem(
            kind: ConfigKind.page,
            id: 'Roe Line',
            payload: jsonEncode({
              'title': 'Roe',
              'menu_item': {'path': '', 'label': 'Roe'},
            })),
        ConfigItem(
            kind: ConfigKind.page,
            id: 'Freezer Line',
            payload: jsonEncode({'title': 'Freezer'})),
      ]);

      expect(pages.keys.toSet(), {'/roe-line', '/freezer-line'});
      expect((pages['/roe-line']!['menu_item'] as Map)['path'], '/roe-line',
          reason: 'the page has to agree with the map about where it lives, '
              'or the next save keys it somewhere else again');
      expect((pages['/roe-line']!['menu_item'] as Map)['label'], 'Roe',
          reason: 'the repair adds a path, it does not replace the menu item');
      expect((pages['/freezer-line']!['menu_item'] as Map)['path'],
          '/freezer-line');
    });

    test('fallbackPagePathFor matches the app slug', () {
      expect(fallbackPagePathFor('Roe Line'), '/roe-line');
      expect(fallbackPagePathFor('Baader, 1st'), '/baader-1st');
    });
  });

  group('bySortIndexThenId', () {
    test('nulls sort last and ties break on the id', () {
      ConfigItem at(String id, int? index) => ConfigItem(
          kind: ConfigKind.asset, id: id, sortIndex: index, payload: '{}');

      final items = [at('c', null), at('b', 0), at('a', 0), at('d', 1)]
        ..sort(bySortIndexThenId);

      expect(items.map((i) => i.id), ['a', 'b', 'd', 'c']);
    });
  });

  group('readSharedPreferencePayload', () {
    test('unwraps the {type, value} envelope every preference row carries',
        () async {
      // The shape `SharedRowPreferences` and the migration both write. Read
      // as the document itself, `['alarms']` was null and the MCP server
      // reported a plant with no alarms.
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db,
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          payload: {
            'type': 'String',
            'value': jsonEncode({
              'alarms': [
                {'uid': 'a1'},
                {'uid': 'a2'},
              ]
            }),
          });

      final value = await readSharedPreferencePayload(db, 'alarm_man_config');
      expect((value!['alarms'] as List), hasLength(2));
      expect(value.containsKey('type'), isFalse);
    });

    test('decodes an object payload', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db,
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          payload: {
            'alarms': [
              {'uid': 'a1'}
            ]
          });

      final value = await readSharedPreferencePayload(db, 'alarm_man_config');
      expect((value!['alarms'] as List), hasLength(1));
    });

    test('decodes a payload that is a JSON document held as a string', () async {
      // `flutter_preferences` stores the document as a string in a text
      // column; whether the migration keeps that string or lifts the document
      // is 04-11's decision, so both read.
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db,
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          rawPayload: jsonEncode(jsonEncode({'alarms': []})));

      expect(await readSharedPreferencePayload(db, 'alarm_man_config'),
          {'alarms': []});
    });

    test('is null for a missing row, a scalar and a malformed payload',
        () async {
      final db = _schemaDb();
      addTearDown(db.close);

      expect(await readSharedPreferencePayload(db, 'absent'), isNull);

      await _insert(db,
          kind: ConfigKind.preference, id: 'scalar', rawPayload: '42');
      await _insert(db,
          kind: ConfigKind.preference, id: 'junk', rawPayload: 'not json');

      expect(await readSharedPreferencePayload(db, 'scalar'), isNull);
      expect(await readSharedPreferencePayload(db, 'junk'), isNull);
    });

    test('ignores a station-scoped row of the same name', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insert(db,
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'),
          payload: {'alarms': []});

      expect(await readSharedPreferencePayload(db, 'alarm_man_config'), isNull);
    });
  });

  group('attached to a foreign schema', () {
    test('reads AppDatabase rows through the same accessor', () async {
      // Production's shape: the reader holds a GeneratedDatabase whose schema
      // was generated somewhere else entirely, and the table attaches to it.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(db.close);
      await db.customSelect('SELECT 1').getSingle();

      await _insert(db, kind: ConfigKind.page, id: 'p1', payload: _page('/a'));
      await _insert(db,
          kind: ConfigKind.asset,
          id: 'a1',
          parentId: 'p1',
          sortIndex: 0,
          payload: _asset('lamp'));

      final pages = pagesJsonOf(await readSharedPageLayout(db));

      expect(pages.keys, ['/a']);
      expect(pages['/a']!['assets'], hasLength(1));
    });
  });

  group('FFI-free import graph', () {
    test('page_rows.dart reaches nothing native', () {
      final walk = _walk('lib/core/config/page_rows.dart');

      expect(walk.violations, isEmpty,
          reason: 'page_rows.dart is exported from tfc_dart_core.dart, the '
              'barrel that exists so `dart compile exe` does not link '
              'open62541. ${walk.report}');
      expect(walk.files.length, greaterThan(1),
          reason: 'a walk that resolved only the entry point proves nothing');
    });

    test('the whole barrel reaches nothing native', () {
      final walk = _walk('lib/tfc_dart_core.dart');

      expect(walk.violations, isEmpty,
          reason: 'the barrel header promises every export is FFI-free; a new '
              'export has to keep that true. ${walk.report}');
      expect(walk.files.length, greaterThan(5));
      // Named rather than left to the count: every file added to the barrel is
      // a file this walk now has to police, and a walk that silently stopped
      // reaching one would keep passing. `config_consistency.dart` (04-08) is
      // the newest, and it pulled `config_change.dart`,
      // `config_history_policy.dart` and the change table's declaration into
      // the barrel's graph behind it.
      expect(
          walk.files.map((f) => p.basename(f)),
          containsAll([
            'page_rows.dart',
            'config_consistency.dart',
            'config_history_policy.dart',
            'config_item_table.dart',
          ]));
    });

    test('the walk still catches the pull D-3 arrived through', () {
      // The positive control. `config_service.dart` imports
      // `key_mapping_codec.dart` -> `state_man.dart` -> open62541, one import
      // deep, and that is exactly the shape a source-text check on the entry
      // file alone would miss. If this ever comes back empty the two tests
      // above are measuring nothing.
      final walk = _walk('lib/core/config/key_mapping_codec.dart');

      expect(walk.violations, isNotEmpty);
      expect(walk.violations.map((v) => v.uri).toSet(),
          contains(startsWith('package:open62541/')));
      expect(
          walk.violations.any((v) =>
              v.reachedThrough('core/state_man.dart') &&
              v.startedAt('key_mapping_codec.dart')),
          isTrue,
          reason: 'the violation has to be reported with the chain that '
              'reaches it, or nobody can act on it. ${walk.report}');
    });

    test('the chain matches on a Windows trail, from a POSIX machine', () {
      // The bug this pins cannot be reproduced on macOS or Linux, so the
      // Windows shape is constructed instead of discovered. `tfc-dart-test
      // (windows-latest)` failed the test above with `Expected: true / Actual:
      // <false>` while its own failure message printed the correct chain —
      // the walk had found the violation and the assertion could not see it,
      // because the trail holds native separators and the suffix is written
      // with `/`.
      //
      // A backslash trail must match exactly as a forward-slash one does. The
      // negative half is here too: a suffix that is genuinely not on the chain
      // must still not match, or this would pass by matching everything.
      final windows = _Violation('package:open62541/open62541.dart', [
        r'C:\src\packages\tfc_dart\lib\core\config\key_mapping_codec.dart',
        r'C:\src\packages\tfc_dart\lib\core\state_man.dart',
      ]);

      expect(windows.reachedThrough('core/state_man.dart'), isTrue);
      expect(windows.startedAt('key_mapping_codec.dart'), isTrue);
      expect(windows.reachedThrough('core/page_rows.dart'), isFalse,
          reason: 'normalising separators must not make every suffix match');
      expect(windows.startedAt('core/state_man.dart'), isFalse,
          reason: 'startedAt is about the first file, not any file');

      // And the POSIX trail the same assertions were written for still works.
      final posix = _Violation('package:open62541/open62541.dart', [
        '/src/packages/tfc_dart/lib/core/config/key_mapping_codec.dart',
        '/src/packages/tfc_dart/lib/core/state_man.dart',
      ]);
      expect(posix.reachedThrough('core/state_man.dart'), isTrue);
      expect(posix.startedAt('key_mapping_codec.dart'), isTrue);
    });

    test('the barrel exports page_rows.dart', () {
      final barrel = File('lib/tfc_dart_core.dart').readAsStringSync();
      expect(barrel, contains("export 'core/config/page_rows.dart';"));
    });
  });
}

/// Anything a `dart compile exe` binary must not end up linking, plus Flutter,
/// which such a binary cannot link at all.
///
/// Matched against the import URI as written. Third-party packages are not
/// descended into — resolving them needs the package config and would make the
/// walk a build step — so what is caught is a tfc_dart file naming one of
/// these. That is enough, because the native pull always enters the graph at
/// the file that imports the package, and every file on the way there is
/// tfc_dart's.
final List<RegExp> _banned = [
  RegExp(r'^dart:ffi$'),
  RegExp(r'^package:flutter/'),
  RegExp(r'^package:flutter_'),
  RegExp(r'^package:open62541/'),
  RegExp(r'^package:jbtm/'),
  RegExp(r'^package:amplify_'),
  // drift's core is pure Dart; `native.dart` is the one that opens sqlite3
  // through dart:ffi.
  RegExp(r'^package:drift/native\.dart$'),
];

/// `import`, `export` and `part` — a part carries its own imports and is the
/// obvious place to hide one.
final RegExp _directive =
    RegExp(r"^\s*(?:import|export|part)\s+'([^']+)'", multiLine: true);

/// [path] with whatever separator this platform uses rewritten to `/`.
///
/// The walk stores **absolute, native** paths, because it has to open the
/// files. On Windows a trail entry is therefore
/// `C:\\...\\lib\\core\\state_man.dart`, and an assertion asking
/// `endsWith('core/state_man.dart')` is false for a chain that is entirely
/// correct — a working guard reporting a failure that is really about string
/// comparison. Every path assertion in this file goes through here so the
/// next one cannot rediscover that.
///
/// A plain replace, and **deliberately not** `p.split(...).join('/')`.
/// `package:path` resolves its context from the host platform, so on macOS it
/// does not treat `\` as a separator at all — a helper built on it would be
/// correct only on the platform that cannot run the test that proves it. This
/// one behaves identically everywhere, which is what lets the Windows shape be
/// pinned from a POSIX machine below. The cost is a POSIX filename containing
/// a literal backslash, which no Dart source path in this repository has.
String _posix(String path) => path.replaceAll(r'\', '/');

/// One banned import, and the chain of files that reached it.
class _Violation {
  _Violation(this.uri, this.trail);

  final String uri;

  /// Absolute native paths, entry point first. Compare through
  /// [reachedThrough] and [startedAt] rather than directly.
  final List<String> trail;

  /// Whether any file on the chain ends in [suffix], written with `/`.
  bool reachedThrough(String suffix) =>
      trail.any((f) => _posix(f).endsWith(suffix));

  /// Whether the chain begins at a file ending in [suffix], written with `/`.
  bool startedAt(String suffix) =>
      trail.isNotEmpty && _posix(trail.first).endsWith(suffix);
}

/// The result of walking one entry point.
class _Walk {
  _Walk(this.files, this.violations);

  final Set<String> files;
  final List<_Violation> violations;

  String get report => violations.isEmpty
      ? '${files.length} files walked, none native.'
      : violations
          .map((v) => '${v.trail.map(p.basename).join(' -> ')} imports ${v.uri}')
          .join('; ');
}

/// Every tfc_dart file reachable from [entry], and every banned import found
/// on the way.
///
/// Whole-line comments are stripped first, so the comment explaining why a
/// file must not import open62541 cannot be what trips the check — and, more
/// to the point, a commented-out import cannot be what makes it pass.
_Walk _walk(String entry) {
  final root = Directory.current.path;
  expect(File(p.join(root, entry)).existsSync(), isTrue,
      reason: 'Run this suite from packages/tfc_dart. Without $entry the '
          'graph walk would pass vacuously.');

  final files = <String>{};
  final violations = <_Violation>[];

  void visit(String path, List<String> trail) {
    final norm = p.normalize(p.absolute(path));
    if (!files.add(norm)) return;
    if (!File(norm).existsSync()) {
      fail('$norm is imported by ${trail.isEmpty ? entry : trail.last} '
          'but does not exist');
    }
    final source = File(norm)
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final here = [...trail, norm];

    for (final match in _directive.allMatches(source)) {
      final uri = match.group(1)!;
      if (_banned.any((pattern) => pattern.hasMatch(uri))) {
        violations.add(_Violation(uri, here));
        continue;
      }
      final String next;
      if (uri.startsWith('package:tfc_dart/')) {
        next = p.join(root, 'lib', uri.substring('package:tfc_dart/'.length));
      } else if (!uri.contains(':')) {
        next = p.join(p.dirname(norm), uri);
      } else {
        continue; // dart: core, or another package — see [_banned].
      }
      visit(next, here);
    }
  }

  visit(p.join(root, entry), []);
  return _Walk(files, violations);
}
