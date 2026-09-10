/// Drift's generated types stop at the repository, and the app tree never
/// names one.
///
/// ## The rule
///
/// A drift-generated type — a row class (`AppUserData`), a companion
/// (`AuditEntryCompanion`) or a table implementation (`$AlarmHistoryTable`) —
/// may be named only inside `packages/tfc_dart`, and there only by the code
/// that is the persistence or wire-mapping layer itself. **Anything a store
/// exposes on its public API is hand-written**: `AccessRole`, `UserSummary`,
/// `AuditRecord`, all declared in `tfc_access` and imported by both the direct
/// path and the protocol.
///
/// ## Why it needs a gate rather than a convention
///
/// The coupling this replaced was not written on purpose. `listUsers` answered
/// a row because the row was there and had the right columns, and the cost
/// arrived one layer at a time: the roster type reached the widget, the widget
/// read `passwordHash` off it, and then a gateway panel — which has no database
/// and never sees a hash — had to *mint* a credential column so the widget's
/// question could be asked. Nobody decided that; each step was locally
/// reasonable. A convention would not have stopped it, because at no point did
/// anybody feel they were breaking one.
///
/// ## Derived, not enumerated
///
/// The forbidden names are read out of `database_drift.g.dart` rather than
/// listed here. A hand-kept list is complete for today's schema and silently
/// wrong the moment a thirteenth table is added — the new row class would be
/// free to leak precisely because it is new. Deriving them means the gate grows
/// with the schema.
///
/// ## The anti-vacuity halves
///
/// Two, because this suite's whole claim is an absence and an absence is what a
/// broken scan reports:
///
///  1. the derivation must have found a substantial set of names — a regex that
///     matches nothing forbids nothing;
///  2. the sweep must have visited a substantial number of files — a walk that
///     finds no files agrees with every claim made about them.
///
/// Comments are stripped before matching. That is not tidiness: the files that
/// were *fixed* are exactly the ones whose comments now explain what used to be
/// there and name the old type while doing it, so an unfiltered grep would fail
/// on the prose describing the fix.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/path_separators.dart';

/// Where drift's generated half lives.
const String _kGeneratedPath =
    'packages/tfc_dart/lib/core/database_drift.g.dart';

/// The app tree, which is what this gate is about.
const String _kAppRoot = 'lib';

/// Below this many derived names, the derivation is broken rather than the
/// schema tiny. The generated file declares upwards of sixty.
const int _kMinimumNamesDerived = 50;

/// Below this many visited files, the walk is broken rather than the app small.
const int _kMinimumFilesVisited = 300;

/// The leaks that exist today, named one file and one type at a time.
///
/// **This is a ratchet, not an amnesty.** The access and audit seams were the
/// ones worth fixing first, because they were the ones costing something: a
/// gateway panel was minting a synthetic credential column to satisfy a row
/// type a widget wanted. This gate was written to hold that fixed — and the
/// first time it ran it found a second family nobody had inventoried, the PLC
/// code index, leaking three MCP row classes through
/// `guarded_knowledge_stores.dart`'s interface into two providers.
///
/// They are the same defect and they are not fixed here. Fixing them means
/// designing domain types for PLC cross-references — what a variable reference
/// or a block call *is* to a screen — which is a question about the knowledge
/// subsystem, not about access control, and it deserves its own thinking rather
/// than being swept along by a refactor that happened to walk past.
///
/// What the exemption buys is that the boundary cannot get worse while that is
/// pending. It is keyed on the exact pair, so these two files are forgiven for
/// exactly these three names and nothing else: a fourth generated type in
/// `plc.dart` fails, and so does `AppUserData` reappearing in either of them.
///
/// The arm below refuses a stale entry, so the list cannot outlive the leak it
/// describes. Remove a pair when the type stops being named; do not add one
/// without deciding, out loud, that the leak is worth keeping for now.
const Map<String, Set<String>> _kKnownLeaks = <String, Set<String>>{
  'lib/core/guarded_knowledge_stores.dart': {
    'PlcVarRefTableData',
    'PlcFbInstanceTableData',
    'PlcBlockCallTableData',
  },
  'lib/providers/plc.dart': {
    'PlcVarRefTableData',
    'PlcFbInstanceTableData',
    'PlcBlockCallTableData',
  },
};

/// Every generated type name declared in [_kGeneratedPath].
///
/// Matches `class Foo`, `class $FooTable` and `class FooCompanion` at the head
/// of a line, which is how the generator emits every one of them.
Set<String> _generatedTypeNames() {
  final file = File(_kGeneratedPath);
  // A plain throw rather than `expect`: this runs at load time, outside any
  // test, where `expect` raises OutsideTestException and buries the cause.
  if (!file.existsSync()) {
    throw StateError('Run this suite from the repository root. Without '
        '$_kGeneratedPath there are no names to forbid and every assertion '
        'below would pass by forbidding nothing.');
  }

  final names = <String>{};
  for (final match in RegExp(r'^class (\$?[A-Za-z0-9_]+)', multiLine: true)
      .allMatches(file.readAsStringSync())) {
    final name = match.group(1)!;
    // The three shapes the generator emits. `_$AppDatabase` is deliberately
    // absent: it is the database's own base class, it is named only by the
    // database, and adding it would forbid nothing the app tree could do.
    if (name.startsWith(r'$') ||
        name.endsWith('Data') ||
        name.endsWith('Companion')) {
      names.add(name);
    }
  }
  return names;
}

/// [path]'s source with block and line comments removed.
String _uncommented(String path) => File(path)
    .readAsStringSync()
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//')) return '';
      return line;
    })
    .join('\n');

/// Every `.dart` file under [_kAppRoot], as repository-relative paths.
///
/// Generated files are included on purpose: a `.g.dart` under `lib/` naming a
/// drift row means a provider or a serialiser has the type in its signature,
/// which is the leak wearing a generated hat. `access_admin.g.dart` carried
/// exactly that until the roster changed type.
List<String> _appFiles() {
  final files = <String>[];
  final dir = Directory(_kAppRoot);
  if (!dir.existsSync()) return files;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    // Normalised where the string is minted — see [withForwardSlashes]. A
    // census that matches nothing passes.
    final path = withForwardSlashes(entity.path);
    if (!path.endsWith('.dart')) continue;
    files.add(path);
  }
  return files;
}

void main() {
  final forbidden = _generatedTypeNames();
  final files = _appFiles();

  group('the gate can see', () {
    test('the derivation found the generated type names', () {
      expect(forbidden.length, greaterThan(_kMinimumNamesDerived),
          reason: 'derived only ${forbidden.length} names from '
              '$_kGeneratedPath. The generator\'s output shape has changed and '
              'the pattern no longer matches it, so the sweep below forbids '
              'almost nothing while still passing.');
      // Named spot-checks, so a pattern that matched sixty irrelevant things
      // could not satisfy the count alone.
      expect(forbidden, containsAll(<String>{
        'AppUserData',
        'AuditEntryData',
        'AuditEntryCompanion',
        r'$AlarmHistoryTable',
      }));
    });

    test('the sweep visited the app tree', () {
      expect(files.length, greaterThan(_kMinimumFilesVisited),
          reason: 'visited only ${files.length} files under $_kAppRoot. A walk '
              'that finds nothing reports no violations for the same reason it '
              'would report no files.');
    });
  });

  group('no generated drift type is named under lib/', () {
    test('the app tree names none of them', () {
      final offenders = <String>[];
      for (final path in files) {
        final source = _uncommented(path);
        for (final name in forbidden) {
          // `$`-prefixed names cannot take a leading `\b` — `$` is not a word
          // character, so the boundary would never match.
          final pattern = name.startsWith(r'$')
              ? RegExp('\\${name}\\b')
              : RegExp('\\b$name\\b');
          if (!pattern.hasMatch(source)) continue;
          if (_kKnownLeaks[path]?.contains(name) ?? false) continue;
          offenders.add('$path names $name');
        }
      }

      expect(offenders, isEmpty,
          reason: 'a drift-generated type reached the app tree:\n'
              '  ${offenders.join('\n  ')}\n\n'
              'The store that answered it should answer a hand-written type '
              'instead — tfc_access declares AccessRole, UserSummary and '
              'AuditRecord, and the mapping belongs in the repository. See '
              'docs/drift-codegen-boundary.md.');
    });

    test('every known leak still exists, so the list cannot rot', () {
      final stale = <String>[];
      _kKnownLeaks.forEach((path, names) {
        if (!File(path).existsSync()) {
          stale.add('$path no longer exists');
          return;
        }
        final source = _uncommented(path);
        for (final name in names) {
          if (!RegExp('\\b$name\\b').hasMatch(source)) {
            stale.add('$path no longer names $name');
          }
        }
      });

      expect(stale, isEmpty,
          reason: 'an exemption outlived the leak it describes:\n'
              '  ${stale.join('\n  ')}\n\n'
              'Delete the entry. A list that keeps forgiving something already '
              'fixed is a list that will silently forgive its reintroduction, '
              'which is the failure mode this arm exists to prevent.');
    });

    test('the relayed access stores hold no drift import at all', () {
      // The sharpest single case. This file is the gateway-mode adapter: it
      // runs on a panel with no database, so a drift import here was never
      // about persistence — it was there to satisfy a type a screen wanted,
      // which is how the synthetic credential column came to be minted.
      const path = 'lib/core/relayed_access_stores.dart';
      expect(File(path).existsSync(), isTrue,
          reason: 'this arm names $path directly; if it moved, point the arm '
              'at its new home rather than deleting it.');

      expect(_uncommented(path), isNot(contains('database_drift')),
          reason: 'a panel in gateway mode has no database. Reaching for a '
              'drift type here means a wire value is being reshaped into a '
              'database row so that something downstream can read it back out '
              'again.');
    });
  });
}
