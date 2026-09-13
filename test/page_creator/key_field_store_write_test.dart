// C-10, pinned.
//
// `KeyField._openKeyMappingDialog` used to do this:
//
//     final keyMappings = (await ref.read(stateManProvider.future)).keyMappings;
//     keyMappings.nodes[key] = entry;
//     await prefs.setString('key_mappings', jsonEncode(keyMappings.toJson()));
//
// The first line reads StateMan's **own live map**, and the second writes into
// it. That map is also the baseline a save is diffed against, so by the time
// the write happened the "before" already contained the new key: the diff came
// back empty, the save reported success, and nothing was stored. No error, no
// symptom until somebody reloaded the page and the key was gone.
//
// The fix is a fresh map built from the store's own read, saved through the
// guarded store. This file holds it to that in both ways it can be held: the
// write reaches the store and names exactly the one key (behaviour), and the
// dialog handler contains no assignment into a map it read (source).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';

import '../helpers/test_helpers.dart';

KeyMappings _existing() => KeyMappings(nodes: {
      'existing_key': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'E'),
      ),
    });

Future<List<ConfigChangeRow>> _changes(AppDatabase remote) =>
    (remote.select(remote.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

/// `common.dart`'s `_openKeyMappingDialog` body, comments stripped.
List<String> _dialogHandlerLines() {
  const path = 'lib/page_creator/assets/common.dart';
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: 'Run this suite from the repository root. Without $path the '
          'source assertion below would pass vacuously.');
  final lines = file.readAsLinesSync();
  final start = lines.indexWhere((l) => l.contains('void _openKeyMappingDialog'));
  expect(start, isNonNegative,
      reason: 'the handler was renamed; this assertion has to follow it');
  final end = lines.indexWhere(
      (l) => l.contains('void _showSaveFailure'), start);
  expect(end, greaterThan(start));
  return lines
      .sublist(start, end)
      .where((l) => !l.trimLeft().startsWith('//'))
      .toList();
}

void main() {
  testWidgets('the dialog save reaches the store and names exactly one key',
      (tester) async {
    late AppDatabase remote;
    final store = await createTestConfigStore(
      keyMappings: _existing(),
      session: kConfiguringTestSession,
      onRemote: (db) => remote = db,
    );
    final seeded = (await _changes(remote)).length;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        preferencesProvider.overrideWith((ref) => createTestPreferences()),
        databaseProvider.overrideWith((ref) async => null),
        configStoreProvider.overrideWith((ref) async => store),
        // The field's own build watches this; a throw leaves it with no key
        // list to autocomplete from, which is all it uses StateMan for.
        stateManProvider
            .overrideWith((ref) => throw StateError('No StateMan in tests')),
      ],
      child: const MaterialApp(home: Scaffold(body: KeyField(label: 'Target key'))),
    ));
    await tester.pumpAndSettle();

    // The `+` button opens KeyMappingEntryDialog.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Key'), 'brand_new');
    await tester.pumpAndSettle();
    // The dialog defaults to OPC UA and refuses to submit without an
    // identifier, so give it one — this is an operator adding a real mapping.
    await tester.enterText(
        find.widgetWithText(TextField, 'Identifier'), 'NewNode');
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // One added key, and the existing one untouched — the diff was NOT empty,
    // which is the whole of C-10.
    final written = (await _changes(remote)).skip(seeded).toList();
    expect(written, hasLength(1),
        reason: 'an empty diff here is exactly the bug: a save that reports '
            'success and writes nothing');
    expect(written.single.entityId, 'brand_new');
    expect(written.single.op, 'insert');
    expect(store.inner.keyMappings.nodes.keys,
        containsAll(<String>['existing_key', 'brand_new']));
  });

  test('the handler assigns into no map it read', () {
    final body = _dialogHandlerLines().join('\n');

    expect(body, contains('configStoreProvider'),
        reason: 'the baseline has to be the store, not StateMan');
    expect(body, contains('saveKeyMappings'));
    expect(body, isNot(contains('.nodes[')),
        reason: 'C-10: an assignment into a map read from StateMan or the '
            'store empties the very diff the save is measured by');
    expect(body, isNot(contains("setString('key_mappings'")),
        reason: 'the blob is not a write path any more');
  });
}
