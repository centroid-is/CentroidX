// The key repository's write path, after v1.2 phase 2 plan 06 moved it onto
// the guarded configuration store.
//
// Three failures, three messages (C-11 and SC-4/SC-5): a save that reached
// nothing must not be reported as a save, and a key another station moved
// under this one must be named. Plus the trail SC-1 and SC-2 are about — one
// row per key that actually changed, one bounded audit row over the lot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// An audit sink that keeps what it was handed.
class _RecordingAuditSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

KeyMappings _oneKey(String name, {int namespace = 1}) => KeyMappings(nodes: {
      name: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: namespace, identifier: 'N'),
      ),
    });

/// The `config_change` rows on the stand-in remote, oldest first.
Future<List<ConfigChangeRow>> _changes(AppDatabase remote) =>
    (remote.select(remote.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save Key Mappings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save Key Mappings'));
  await tester.pumpAndSettle();
}

void main() {
  group('a save that lands', () {
    testWidgets('writes one change row and one bounded audit row on the same '
        'action id', (tester) async {
      final audit = _RecordingAuditSink();
      late AppDatabase remote;
      final store = await createTestConfigStore(
        keyMappings: _oneKey('alpha'),
        session: kConfiguringTestSession,
        audit: audit,
        onRemote: (db) => remote = db,
      );
      final seeded = (await _changes(remote)).length;

      await tester.pumpWidget(buildTestableKeyRepository(configStore: store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();
      await _tapSave(tester);

      expect(find.text('Key mappings saved successfully!'), findsOneWidget);
      expect(store.inner.keyMappings.nodes.keys, contains('new_key'));

      // SC-1: one row for the one key that moved, not a rewrite of the set.
      final written = (await _changes(remote)).skip(seeded).toList();
      expect(written, hasLength(1));
      expect(written.single.entityId, 'new_key');

      // SC-2: one audit row, and it names the key rather than carrying the
      // half-megabyte blob the old write did.
      expect(audit.rows, hasLength(1));
      final row = audit.rows.single;
      expect(row.itemKey, 'key_mappings');
      expect(row.allowed, isTrue);
      expect(row.newValue, contains('new_key'));
      expect(row.newValue!.length, lessThan(1024));
      // The correlation the trail is read through.
      expect(row.actionId, written.single.actionId);
    });
  });

  group('import', () {
    testWidgets('a replace produces a removal row for the key it dropped',
        (tester) async {
      // The import path hands the whole file to the same
      // `saveKeyMappings` the Save button calls, so what is asserted here is
      // the accounting the diff does for it — the first import in this app's
      // history that is legible in a change log rather than a rewritten blob.
      late AppDatabase remote;
      final store = await createTestConfigStore(
        keyMappings: KeyMappings(nodes: {
          ..._oneKey('alpha').nodes,
          ..._oneKey('bravo', namespace: 2).nodes,
        }),
        session: kConfiguringTestSession,
        onRemote: (db) => remote = db,
      );
      final seeded = (await _changes(remote)).length;

      await store.saveKeyMappings(_oneKey('alpha'));

      final written = (await _changes(remote)).skip(seeded).toList();
      expect(written, hasLength(1));
      expect(written.single.entityId, 'bravo');
      expect(written.single.op, 'delete');
      expect(store.inner.keyMappings.nodes.keys, ['alpha']);
    });
  });

  group('a save that does not land', () {
    testWidgets('offline: the message names what was not written, and there '
        'is no green snackbar', (tester) async {
      final store = await createTestConfigStore(
        session: kConfiguringTestSession,
        withRemote: false,
      );

      await tester.pumpWidget(buildTestableKeyRepository(configStore: store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();
      await _tapSave(tester);

      expect(find.text('Key mappings saved successfully!'), findsNothing,
          reason: 'C-11: the bug this closes is a success message over a '
              'write that reached nothing');
      expect(
        find.textContaining('Not saved — the database is unreachable.'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing was written:'), findsOneWidget,
          reason: 'the refusal has to name the work the operator must redo');
      expect(store.inner.keyMappings.nodes, isEmpty);
    });

    testWidgets('conflict: the message names the key and offers Reload',
        (tester) async {
      late AppDatabase remote;
      final store = await createTestConfigStore(
        keyMappings: _oneKey('alpha'),
        session: kConfiguringTestSession,
        onRemote: (db) => remote = db,
      );

      await tester.pumpWidget(buildTestableKeyRepository(configStore: store));
      await tester.pumpAndSettle();

      // Edit the key, so the save has something to compare-and-swap on.
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Namespace'), '42');
      await tester.pumpAndSettle();

      // Another station gets there first: the row moves on, this page's
      // snapshot does not.
      await remote.customStatement(
          "UPDATE config_item SET rev = rev + 1 WHERE kind = 'key_mapping' "
          "AND id = 'alpha'");

      await _tapSave(tester);

      expect(find.text('Key mappings saved successfully!'), findsNothing);
      expect(find.textContaining('"alpha" was changed on another station.'),
          findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget,
          reason: 'SC-5: the conflict is per key and the operator is given '
              'the way out rather than left to find it');
    });
  });
}
