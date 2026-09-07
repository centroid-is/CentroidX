// What the v7 migration's Postgres arm is *not* covered by, and what the
// binding's move out of `key_mappings` is pinned by.
//
// Two kinds of assertion live here, and neither of them opens a database
// unless it says so:
//
// 1. **Column parity** between each raw `CREATE TABLE IF NOT EXISTS` literal
//    in the `from < 7` Postgres arm and the drift table it is supposed to
//    mirror. This catches a column added on one side and not the other. It
//    does **not** execute the DDL — see the arm's own comment in
//    `database_drift.dart` and the header of
//    `access_template_table_test.dart`.
// 2. **The blob, unchanged.** `KeyMappingEntry` gained no binding field and
//    `key_mappings` gained no JSON key, asserted from source rather than left
//    true by accident.
//
// Run from `packages/tfc_dart` — the source-derived tests read `lib/` by
// relative path and say so rather than passing vacuously.

import 'dart:io';

// `isNull` and `isNotNull` are matchers here, not drift's SQL expressions of
// the same names.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;
import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry;

// ---------------------------------------------------------------------------
// Source reading
// ---------------------------------------------------------------------------

/// [path]'s lines with every whole-line comment dropped.
///
/// Whole-line only, which is all that is needed and all that is honest: a
/// trailing `// ...` cannot fabricate a declaration or a DDL literal, and a
/// commented-out statement must not be able to satisfy a test that the live
/// one is missing.
List<String> _sourceLinesWithoutComments(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: 'Run this suite from packages/tfc_dart. Without $path the '
          'source assertions below would pass vacuously.');
  return file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .toList();
}

/// The body of `class [name]` in [lines], from the head to its closing brace.
List<String> _classBody(List<String> lines, String name) {
  final start = lines.indexWhere((l) => l.trimRight() == 'class $name {');
  expect(start, isNonNegative,
      reason: 'could not find the head of class $name; the derivation below '
          'would silently read nothing');
  final end = lines.indexWhere((l) => l == '}', start + 1);
  expect(end, isNonNegative, reason: 'class $name has no closing brace');
  return lines.sublist(start + 1, end);
}

/// A method or setter declaration at two-space indent.
final RegExp _methodDecl =
    RegExp(r'^  (?! )(?:static\s+)?[\w$<>?,\[\] ]+\s+([a-zA-Z_$][\w$]*)\s*\(');

/// A getter declaration at two-space indent.
final RegExp _getterDecl =
    RegExp(r'^  (?! ).*\bget\s+([a-zA-Z_$][\w$]*)\s*(?:=>|\{|;)');

/// A field declaration at two-space indent. `=[^>]` keeps it from swallowing
/// a `=>` getter.
final RegExp _fieldDecl = RegExp(
    r'^  (?! )(?:late\s+)?(?:final\s+|const\s+|static\s+)*(?:[\w$<>?,\[\] ]+\s+)?'
    r'([a-zA-Z_$][\w$]*)\s*(?:=[^>]|;)');

/// The name declared on [line], or null when it declares nothing.
String? _declaredName(String line) {
  for (final pattern in [_methodDecl, _getterDecl, _fieldDecl]) {
    final match = pattern.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// The lines of `class KeyMappingEntry`, comments stripped. `@JsonKey(...)`
/// annotation lines are kept: a JSON name is exactly the kind of binding
/// smuggling this file exists to catch.
List<String> _keyMappingEntryBody() => _classBody(
    _sourceLinesWithoutComments('lib/core/state_man.dart'), 'KeyMappingEntry');

/// Every member `KeyMappingEntry` declares, derived from its source.
Set<String> _keyMappingEntryMembers() => {
      for (final line in _keyMappingEntryBody())
        if (_declaredName(line) case final name?) name,
    };

// ---------------------------------------------------------------------------
// DDL parsing
// ---------------------------------------------------------------------------

/// The body of the raw `CREATE TABLE IF NOT EXISTS [table]` literal in
/// `database_drift.dart` — the text between the statement's outer parens,
/// still carrying the Dart source's backslash escapes.
///
/// The literal is found in the source rather than exported from the library on
/// purpose: what ships to a station is the string in that file, so that is
/// what has to be compared.
String _ddlBody(String table) {
  final source = _sourceLinesWithoutComments('lib/core/database_drift.dart')
      .join('\n');
  final match =
      RegExp("CREATE TABLE IF NOT EXISTS $table \\((.+)\\)'").firstMatch(source);
  expect(match, isNotNull,
      reason: 'no live `CREATE TABLE IF NOT EXISTS $table` statement in '
          'database_drift.dart. Either the Postgres arm lost it or it was '
          'commented out — comment lines are stripped before this runs, so a '
          'commented statement cannot satisfy this test.');
  return match!.group(1)!;
}

/// [table]'s literal as Postgres will receive it, with the Dart escapes undone.
///
/// A single quote inside the single-quoted Dart string the statement lives in
/// has to be written `\'`, and `CHECK (scope = 'shared')` is the first
/// statement in this file's reach to contain one. Undoing the escape here is
/// what lets an assertion be written in the SQL a reader would expect rather
/// than in Dart source spelling.
String _ddlSql(String table) =>
    'CREATE TABLE IF NOT EXISTS $table (${_ddlBody(table).replaceAll(r"\'", "'")})';

/// The words that open a *table-level constraint* rather than a column.
///
/// `PRIMARY KEY (kind, id, scope)` and `CONSTRAINT config_item_shared_only
/// CHECK (...)` sit in the same comma-separated list as the column
/// definitions, so taking the first token of every part — which is all a
/// column name ever is — would read them as columns named `PRIMARY` and
/// `CONSTRAINT` and fail parity against drift. The pre-v7 tables carried no
/// table-level constraints, so this never came up before.
const _tableConstraintKeywords = {
  'PRIMARY',
  'CONSTRAINT',
  'UNIQUE',
  'CHECK',
  'FOREIGN',
};

/// The column names in the raw `CREATE TABLE IF NOT EXISTS [table]` literal in
/// `database_drift.dart`.
Set<String> _ddlColumns(String table) {
  final body = _ddlBody(table);
  // Split on top-level commas. The depth counter is what keeps
  // `PRIMARY KEY (kind, id, scope)` — and a future `NUMERIC(10,2)` — from
  // being read as several parts.
  final parts = <String>[];
  var depth = 0;
  var current = StringBuffer();
  for (final rune in body.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(current.toString());
      current = StringBuffer();
    } else {
      current.write(ch);
    }
  }
  parts.add(current.toString());

  final columns = <String>{};
  for (final part in parts) {
    final first = part.trim().split(RegExp(r'\s+')).first;
    if (_tableConstraintKeywords.contains(first.toUpperCase())) continue;
    columns.add(first);
  }
  return columns;
}

/// The column names drift declares for [table].
Set<String> _driftColumns(TableInfo<Table, dynamic> table) =>
    table.$columns.map((c) => c.name).toSet();

/// Asserts the DDL literal for [tableName] and the drift table agree, in both
/// directions.
void _expectColumnParity(String tableName, TableInfo<Table, dynamic> table) {
  const disclaimer =
      'This test compares a string literal against a class. It does not open '
      'Postgres, it does not execute the DDL, and it would not notice a wrong '
      'type, a missing NOT NULL or a statement that fails at runtime. No test '
      'in this package runs the from < 7 Postgres arm — nor the from < 6 one, '
      'open since 2026-08-28. All this proves is that the column *names* on '
      'the two sides match.';

  final ddl = _ddlColumns(tableName);
  final drift = _driftColumns(table);

  expect(ddl.difference(drift), isEmpty,
      reason: 'the $tableName Postgres DDL declares a column drift does not. '
          '$disclaimer');
  expect(drift.difference(ddl), isEmpty,
      reason: 'drift declares a $tableName column the Postgres DDL does not, '
          'so a station on Postgres would fail on the first query naming it. '
          '$disclaimer');
}

void main() {
  group('Postgres DDL column parity', () {
    // One test per raw statement, so a failure names the table rather than
    // the pair.
    test('access_template: the DDL and the drift table declare the same '
        'columns', () {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      _expectColumnParity('access_template', db.accessTemplateTable);
    });

    test('access_key_binding: the DDL and the drift table declare the same '
        'columns', () {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      _expectColumnParity('access_key_binding', db.accessKeyBindingTable);
    });

    test('config_item: the DDL and the drift table declare the same columns',
        () {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      _expectColumnParity('config_item', db.configItemTable);
    });

    test('config_change: the DDL and the drift table declare the same columns',
        () {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      _expectColumnParity('config_change', db.configChangeTable);
    });

    test('the DDL spells the column names the drift tables are stored under',
        () {
      // Guards the parity tests above against reading the wrong table: drift
      // does not strip a trailing `Table` from a class name, so without the
      // `tableName` overrides these would be `access_template_table` and
      // `access_key_binding_table` and the DDL would create tables nothing
      // queries.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      expect(db.accessTemplateTable.actualTableName, 'access_template');
      expect(db.accessKeyBindingTable.actualTableName, 'access_key_binding');
      expect(db.configItemTable.actualTableName, 'config_item');
      expect(db.configChangeTable.actualTableName, 'config_change');
    });
  });

  group("CHECK (scope = 'shared') is on Postgres and nowhere else", () {
    // The one structural guarantee in the v7 schema, asserted from both
    // sides. `station:<hostname>` rows are a station's own local state — the
    // reason they must not reach the shared database is that nothing else
    // stops them: repository code declining to write them there is a promise
    // that lasts until somebody writes a second repository.
    //
    // The first two assertions are source-derived and carry the usual
    // disclaimer: nothing here executes the Postgres DDL. The third is the
    // one that actually runs, and it is the one that would catch the mistake
    // most likely to be made — putting the constraint on the drift table,
    // where it would land on both backends and reject every row this
    // milestone writes.
    const theCheck = "CHECK (scope = 'shared')";

    test('the config_item Postgres literal carries it', () {
      expect(_ddlSql('config_item'), contains(theCheck));
    });

    test('the config_change Postgres literal carries it', () {
      expect(_ddlSql('config_change'), contains(theCheck));
    });

    test('the SQLite tables carry no CHECK at all', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());

      for (final table in ['config_item', 'config_change']) {
        final rows = await db.customSelect(
          "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
          variables: [Variable<String>(table)],
        ).get();
        expect(rows, hasLength(1), reason: 'no `$table` table on a fresh '
            'SQLite database, so the assertion below would pass vacuously');
        expect(rows.first.read<String>('sql').toUpperCase(), isNot(contains('CHECK')),
            reason: 'the local database is where station-scoped rows live. A '
                "CHECK (scope = 'shared') on the drift table would go on both "
                'backends and reject every row this milestone writes. It '
                'belongs in the Postgres string literals only.');
      }
    });
  });

  group('the binding is not in the key_mappings blob', () {
    // The ruling, pinned. Read the reason strings before adding the field.
    const theRuling =
        'Do not add a template binding to KeyMappingEntry. Spec §7b still '
        'reads as though the binding is a field on this class, and on '
        '2026-08-30 that was reversed: `key_mappings` is classified '
        '`configure` by kPrefAccessRules, so a binding in that blob is '
        'authorization data behind a `configure` gate — anybody who can edit '
        'a page could re-scope who may write what, through the key '
        "repository's import card or the raw preferences editor. The binding "
        'lives in the `access_key_binding` table, gated `users`, so the gate '
        'is true of the data and not only of the button. If you need the '
        'binding at tap time with no await, load that table into the same '
        'in-memory snapshot the templates are loaded into — that is what '
        "§7b's synchronous-resolution requirement actually asks for.";

    test('the member derivation is not vacuous', () {
      // Without this, a regex that matches nothing would make every assertion
      // below pass.
      final members = _keyMappingEntryMembers();
      expect(members, contains('opcuaNode'));
      expect(members, contains('variableName'));
      expect(members, contains('copyWith'));
    });

    test('KeyMappingEntry declares no member naming a template binding', () {
      final offenders = _keyMappingEntryMembers()
          .where((m) => m.toLowerCase().contains('template'))
          .toList();
      expect(offenders, isEmpty,
          reason: 'no `accessTemplate` member, and no other spelling of a '
              'template binding either. $theRuling');
    });

    test('the KeyMappingEntry source mentions no template binding at all', () {
      // Broader than the member derivation and deliberately so: it catches a
      // declaration shaped in a way the three regexes above miss, and a
      // `@JsonKey(name: 'access_template')` on an innocently-named field.
      final body = _keyMappingEntryBody().join('\n');
      expect(body.toLowerCase().contains('accesstemplate'), isFalse,
          reason: theRuling);
      expect(body.contains('access_template'), isFalse, reason: theRuling);
    });

    test('the JSON key set is exactly the pre-existing one', () {
      // Byte-for-byte the same blob format as before this phase, so a
      // `key_mappings` written by this build loads on an older one and an
      // older one loads here. Listed rather than derived: a derived expected
      // set would move with the class it is meant to pin.
      final json = KeyMappingEntry().toJson();
      expect(json.keys.toSet(), {
        'opcua_node',
        'm2400_node',
        'modbus_node',
        'io',
        'collect',
        'bit_mask',
        'bit_shift',
        'variable_name',
      }, reason: theRuling);
    });

    test('a round trip preserves the key set', () {
      final entry = KeyMappingEntry(variableName: 'M_Elevator.i_isAuto')
        ..io = true;
      final round = KeyMappingEntry.fromJson(entry.toJson());
      expect(round.toJson().keys.toSet(), entry.toJson().keys.toSet());
      expect(round.variableName, 'M_Elevator.i_isAuto');
      expect(round.io, isTrue);
    });

    test('state_man.g.dart contains no access_template', () {
      // The generated code is evidence too: a field added and regenerated
      // would show up here even if somebody edited the hand-written class
      // back out.
      final generated =
          File('lib/core/state_man.g.dart').readAsStringSync().toLowerCase();
      expect(generated.contains('access_template'), isFalse,
          reason: theRuling);
      expect(generated.contains('accesstemplate'), isFalse, reason: theRuling);
    });
  });
}
