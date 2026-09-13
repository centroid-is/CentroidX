import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;

import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/database.dart';

import '../helpers/test_helpers.dart';

void main() {
  // ==================== Group 1: Page Rendering ====================
  group('Page rendering', () {
    testWidgets('renders page title "Key Mappings"', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(find.text('Key Mappings'), findsOneWidget);
    });

    testWidgets('shows empty state when no keys exist', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(find.text('No keys configured'), findsOneWidget);
      expect(find.text('Add your first key mapping to get started'),
          findsOneWidget);
    });

    testWidgets('shows key cards when keys exist', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleKeyMappings(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('temperature_sensor'), findsOneWidget);
      expect(find.text('pressure_valve'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNWidgets(2));
    });

    testWidgets('renders import/export section', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(find.text('Import / Export'), findsOneWidget);
    });
  });

  // ==================== Group 2: Add Key ====================
  group('Add key', () {
    testWidgets('tapping Add Key button creates a new key entry',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      // Should start with empty state
      expect(find.text('No keys configured'), findsOneWidget);

      // Tap Add Key
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      // Empty state should be gone, new key card should appear (expanded, so title + text field)
      expect(find.text('No keys configured'), findsNothing);
      expect(find.text('new_key'), findsAtLeastNWidgets(1));
    });

    testWidgets(
        'new key appears at the top within a few frames '
        'even with thousands of keys', (tester) async {
      // Regression: the new key used to be appended at the *end* and revealed
      // by jumping to maxScrollExtent. A lazy list has no real extent for
      // unbuilt cards, so the sliver re-estimated every frame, building one
      // more card each time — ~10 s of frame churn on a repository with
      // thousands of keys. New keys now insert at the top, which is O(1) to
      // reveal, so a handful of frames must suffice.
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          for (var i = 0; i < 3000; i++)
            'AREA${i ~/ 100}.DEV${i % 100}.SUB$i': KeyMappingEntry(
              opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Ident$i'),
            ),
        }),
      ));
      await tester.pumpAndSettle();

      // Scroll away from the top so the reveal actually has to jump back.
      await tester.drag(keyListScrollable, const Offset(0, -2000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Key'));
      // Bounded pumping, deliberately not pumpAndSettle: the old behavior
      // needed thousands of frames to settle and this must fail in that case.
      await settle(tester);

      expect(find.text('new_key'), findsAtLeastNWidgets(1),
          reason: 'new key card must be on screen a few frames after Add Key');

      // And it sits above the pre-existing first key. The new card is
      // expanded and may fill the whole viewport, leaving the old first card
      // unbuilt — that also proves the new key is at the top.
      final firstOld = find.text('AREA0.DEV0.SUB0');
      if (firstOld.evaluate().isNotEmpty) {
        expect(tester.getTopLeft(find.text('new_key').first).dy,
            lessThan(tester.getTopLeft(firstOld.first).dy),
            reason: 'new key must be inserted at the top of the list');
      }
    });

    testWidgets('multiple Add Key taps create unique keys', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      // The Add Key button lives in the key section's own pinned header. On a
      // window too short for the whole column — which the 800x600 test surface
      // became once the access-templates section was mounted — the page itself
      // scrolls (KeyRepositoryContent.minContentHeight), and focusing the new
      // card's name field scrolls the header off the top. Bring it back before
      // pressing it; the assertion below is unchanged.
      await tester.ensureVisible(find.text('Add Key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      // Verify both keys exist: new_key and new_key_1. The list is lazy, so
      // walk down from the top revealing each in turn.
      await scrollKeyListToTop(tester);
      for (final name in ['new_key', 'new_key_1']) {
        await revealKeyCard(tester, name);
      }
    });
  });

  // ==================== Group: Copy Key ====================
  group('Copy key', () {
    testWidgets('tapping copy button duplicates the key', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'original_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MyNode')
              ..serverAlias = 'main_server',
          ),
        }),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Tap the copy button
      final copyButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.copy.data);
      expect(copyButtons, findsOneWidget);
      await tester.tap(copyButtons.first);
      await tester.pumpAndSettle();

      // The copy is expanded and scrolled into view, so go back to the top —
      // the list is lazy, off-screen cards aren't built.
      await scrollKeyListToTop(tester);

      // Should now have 2 key cards
      expect(find.text('original_key'), findsOneWidget);
      expect(find.text('original_key_copy'), findsAtLeastNWidgets(1));
    });

    testWidgets('copied key is placed right after the original', (tester) async {
      final store = await createTestConfigStore(
        keyMappings: KeyMappings(nodes: {
                  'first_key': KeyMappingEntry(
                    opcuaNode:
                        OpcUANodeConfig(namespace: 1, identifier: 'A'),
                  ),
                  'second_key': KeyMappingEntry(
                    opcuaNode:
                        OpcUANodeConfig(namespace: 2, identifier: 'B'),
                  ),
                  'third_key': KeyMappingEntry(
                    opcuaNode:
                        OpcUANodeConfig(namespace: 3, identifier: 'C'),
                  ),
                }),
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Copy the second key
      final copyButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.copy.data);
      // second_key is the 2nd card, so its copy button is at index 1
      await tester.tap(copyButtons.at(1));
      await tester.pumpAndSettle();

      // Save to inspect the order
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      final saved = store.inner.keyMappings;
      final keys = saved.nodes.keys.toList();
      expect(keys, [
        'first_key',
        'second_key',
        'second_key_copy',
        'third_key',
      ]);
    });

    testWidgets('copied key preserves OPC UA config', (tester) async {
      final store = await createTestConfigStore(
        keyMappings: KeyMappings(nodes: {
                  'src_key': KeyMappingEntry(
                    opcuaNode:
                        OpcUANodeConfig(namespace: 5, identifier: 'SrcNode')
                          ..serverAlias = 'main_server',
                  ),
                }),
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        stateManConfig: sampleStateManConfig(),
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Copy the key
      final copyButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.copy.data);
      await tester.tap(copyButtons.first);
      await tester.pumpAndSettle();

      // Save
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // Verify the copy has the same OPC UA config
      final saved = store.inner.keyMappings;
      expect(saved.nodes.containsKey('src_key_copy'), isTrue);
      final copy = saved.nodes['src_key_copy']!;
      expect(copy.opcuaNode?.namespace, 5);
      expect(copy.opcuaNode?.identifier, 'SrcNode');
      expect(copy.opcuaNode?.serverAlias, 'main_server');
    });

    testWidgets('renaming a copied key and saving persists the new name',
        (tester) async {
      final store = await createTestConfigStore(
        keyMappings: KeyMappings(nodes: {
                  'original': KeyMappingEntry(
                    opcuaNode:
                        OpcUANodeConfig(namespace: 1, identifier: 'Node1'),
                  ),
                }),
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Copy the key (creates 'original_copy', auto-expanded)
      final copyButton = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.copy.data);
      await tester.tap(copyButton.first);
      await tester.pumpAndSettle();

      // Rename the copied key without pressing Enter
      final keyNameField =
          find.widgetWithText(TextField, 'original_copy');
      expect(keyNameField, findsOneWidget);
      await tester.enterText(keyNameField, 'my_renamed_copy');
      await tester.pumpAndSettle();

      // Save
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // Verify the renamed key is saved, not 'original_copy'
      final saved = store.inner.keyMappings;
      expect(saved.nodes.containsKey('my_renamed_copy'), isTrue,
          reason: 'Copied key should be saved with renamed name');
      expect(saved.nodes.containsKey('original_copy'), isFalse,
          reason: 'Old copy name should no longer exist');
      expect(saved.nodes.containsKey('original'), isTrue,
          reason: 'Original key should still exist');
    });

    testWidgets('copying multiple times creates unique names', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'my_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'X'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Copy twice — scroll back to the original's copy button each time.
      // The list is lazy, so going back to the top is what makes the
      // original the first built card again.
      for (var i = 0; i < 2; i++) {
        await scrollKeyListToTop(tester);
        final copyButtons = find.byWidgetPredicate(
            (w) => w is FaIcon && w.icon == FontAwesomeIcons.copy.data);
        await tester.ensureVisible(copyButtons.first);
        await tester.pumpAndSettle();
        await tester.tap(copyButtons.first);
        await tester.pumpAndSettle();
      }

      // Should have 3 keys: my_key, my_key_copy, my_key_copy_1. The list is
      // lazy, so walk down from the top revealing each in turn.
      await scrollKeyListToTop(tester);
      for (final name in ['my_key', 'my_key_copy', 'my_key_copy_1']) {
        await revealKeyCard(tester, name);
      }
    });
  });

  // ==================== Group 3: Delete Key ====================
  group('Delete key', () {
    testWidgets('tapping delete button shows confirmation dialog',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleKeyMappings(),
      ));
      await tester.pumpAndSettle();

      // Tap the first delete button (trash icon)
      final trashButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.trash.data);
      await tester.tap(trashButtons.first);
      await tester.pumpAndSettle();

      expect(find.text('Remove key'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('confirming delete removes the key card', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'to_delete': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'x'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      expect(find.text('to_delete'), findsOneWidget);

      // Tap delete
      final trashButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.trash.data);
      await tester.tap(trashButtons.first);
      await tester.pumpAndSettle();

      // Confirm
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('to_delete'), findsNothing);
    });

    testWidgets('cancelling delete keeps the key card', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'to_keep': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'x'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Tap delete
      final trashButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.trash.data);
      await tester.tap(trashButtons.first);
      await tester.pumpAndSettle();

      // Cancel
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('to_keep'), findsOneWidget);
    });
  });

  // ==================== Group 4: Edit Key Fields ====================
  group('Edit key fields', () {
    testWidgets('can edit key name via expansion', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'old_name': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'test'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('old_name'));
      await tester.pumpAndSettle();

      // Find the Key Name text field and update it
      final keyNameField = find.widgetWithText(TextField, 'old_name');
      expect(keyNameField, findsOneWidget);

      await tester.enterText(keyNameField, 'new_name');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('new_name'), findsWidgets);
    });

    testWidgets('key name updates immediately as user types', (tester) async {
      final store = await createTestConfigStore(
        keyMappings: KeyMappings(nodes: {
                  'original': KeyMappingEntry(
                    opcuaNode:
                        OpcUANodeConfig(namespace: 1, identifier: 'Node1'),
                  ),
                }),
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('original'));
      await tester.pumpAndSettle();

      // Type a new key name (no Enter, no blur)
      final keyNameField = find.widgetWithText(TextField, 'original');
      await tester.enterText(keyNameField, 'renamed');
      await tester.pumpAndSettle();

      // The underlying data should already reflect the rename
      // Verify by saving without any focus changes
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      final saved = store.inner.keyMappings;
      expect(saved.nodes.containsKey('renamed'), isTrue,
          reason: 'Key name should update as user types');
      expect(saved.nodes.containsKey('original'), isFalse,
          reason: 'Old key name should be gone');
    });

    testWidgets('can set OPC UA namespace and identifier', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'test_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 0, identifier: ''),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand card
      await tester.tap(find.text('test_key'));
      await tester.pumpAndSettle();

      // Find and fill namespace field
      final nsField = find.widgetWithText(TextField, 'Namespace');
      expect(nsField, findsOneWidget);

      // Find and fill identifier field
      final idField = find.widgetWithText(TextField, 'Identifier');
      expect(idField, findsOneWidget);

      await tester.enterText(nsField, '42');
      await tester.enterText(idField, 'MyNode');
      await tester.pumpAndSettle();

      // Verify the subtitle updates (it shows ns=X; id=Y)
      // The namespace and identifier should be reflected in the OPC UA config section
    });

    testWidgets('can set array index', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'array_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'ArrayNode'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand card
      await tester.tap(find.text('array_key'));
      await tester.pumpAndSettle();

      // The array index field is now an OpcUaArrayIndexField.
      // Without a live server, it shows an InputDecorator labelled 'Array Index'
      // with a 'Detect' button to probe the node's array size.
      expect(find.text('Array Index'), findsOneWidget);
      expect(find.text('Detect'), findsOneWidget);
    });

    testWidgets('can select server alias from dropdown', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'alias_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'X'),
          ),
        }),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Expand card
      await tester.tap(find.text('alias_key'));
      await tester.pumpAndSettle();

      // Find dropdown and tap it
      final dropdown = find.byType(DropdownButtonFormField<String>);
      expect(dropdown, findsOneWidget);

      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      // Select 'main_server' from dropdown
      expect(find.text('main_server').last, findsOneWidget);
      await tester.tap(find.text('main_server').last);
      await tester.pumpAndSettle();
    });

    // Regression: editing an expanded key's name used to collapse the
    // card on every keystroke because the card's widget identity was
    // `ValueKey(entry.key)` — i.e. tied to the mutable name. Renaming
    // changed the key, Flutter saw a brand-new widget, threw away the
    // ExpansionTile's expanded state. With a stable GlobalKey
    // (migrated old→new inside `_renameKey`), the same State sticks
    // around through the rename so the card stays expanded.
    testWidgets(
        'editing the key name in an expanded card keeps the card expanded',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'before_rename': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'OldNode'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand the card.
      await tester.tap(find.text('before_rename'));
      await tester.pumpAndSettle();

      // Sanity: the expanded section is showing the OPC UA fields.
      expect(find.widgetWithText(TextField, 'before_rename'), findsOneWidget,
          reason:
              'The expanded card should expose the Key Name TextField with the current name.');
      expect(find.widgetWithText(TextField, 'OldNode'), findsOneWidget,
          reason:
              'Identifier field belongs to the expanded section — pre-rename baseline.');

      // Rename without pressing Enter; the bug fires per keystroke.
      final keyNameField =
          find.widgetWithText(TextField, 'before_rename');
      await tester.enterText(keyNameField, 'after_rename');
      await tester.pumpAndSettle();

      // The TextField label changes (it now matches the new name), but
      // the expanded section must still be visible — the Identifier
      // field is the canary that proves expansion state survived.
      expect(find.widgetWithText(TextField, 'after_rename'), findsOneWidget,
          reason: 'Renamed key name should reflect in the title/field.');
      expect(find.widgetWithText(TextField, 'OldNode'), findsOneWidget,
          reason:
              'Card must still be expanded after rename — Identifier field is only visible while expanded.');
    });
  });

  // ==================== Group 5: Collection Configuration ====================
  group('Collection configuration', () {
    testWidgets('collection toggle enables collection fields', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'collect_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'X'),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand card
      await tester.tap(find.text('collect_key'));
      await tester.pumpAndSettle();

      // Collection fields should not be visible yet
      expect(
          find.widgetWithText(TextField, 'Sample Interval'),
          findsNothing);

      // Scroll down to make the Switch visible
      await tester.scrollUntilVisible(
        find.byType(Switch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // Toggle collection on
      final switchWidget = find.byType(Switch);
      expect(switchWidget, findsOneWidget);
      await tester.tap(switchWidget);
      await tester.pumpAndSettle();

      // Collection fields should now be visible
      expect(
          find.widgetWithText(TextField, 'Sample Interval'),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'Retention (days)'),
          findsOneWidget);
    });

    testWidgets('can set sample interval', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'sample_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'X'),
            collect: CollectEntry(
              key: 'sample_key',
              retention: const RetentionPolicy(
                  dropAfter: Duration(days: 365), scheduleInterval: null),
            ),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand card
      await tester.tap(find.text('sample_key'));
      await tester.pumpAndSettle();

      final sampleField =
          find.widgetWithText(TextField, 'Sample Interval');
      expect(sampleField, findsOneWidget);

      await tester.enterText(sampleField, '1000000');
      await tester.pumpAndSettle();
    });

    testWidgets('can set retention days', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'retain_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'X'),
            collect: CollectEntry(
              key: 'retain_key',
              retention: const RetentionPolicy(
                  dropAfter: Duration(days: 365), scheduleInterval: null),
            ),
          ),
        }),
      ));
      await tester.pumpAndSettle();

      // Expand card
      await tester.tap(find.text('retain_key'));
      await tester.pumpAndSettle();

      final retentionField =
          find.widgetWithText(TextField, 'Retention (days)');
      expect(retentionField, findsOneWidget);

      await tester.enterText(retentionField, '90');
      await tester.pumpAndSettle();
    });
  });

  // ==================== Group 6: Unsaved Changes Tracking ====================
  group('Unsaved changes tracking', () {
    testWidgets('shows "Unsaved" badge after adding a key', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      // No badge initially
      expect(find.text('Unsaved'), findsNothing);
      expect(find.text('Unsaved Changes'), findsNothing);

      // Add a key
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      // Badge should appear (text depends on layout width)
      expect(
        find.textContaining('Unsaved'),
        findsOneWidget,
      );
    });

    testWidgets('"Unsaved" badge disappears after save', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      // Add a key to trigger unsaved state
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Unsaved'), findsOneWidget);

      // Tap Save (scroll into view first since Browse button may push it off-screen)
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // Badge should be gone
      expect(find.textContaining('Unsaved'), findsNothing);
    });
  });

  // ==================== Group 7: Search/Filter ====================
  group('Search/filter', () {
    testWidgets('search field filters keys by name', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleKeyMappings(),
      ));
      await tester.pumpAndSettle();

      // Both keys visible
      expect(find.text('temperature_sensor'), findsOneWidget);
      expect(find.text('pressure_valve'), findsOneWidget);

      // Type in search field
      final searchField = find.widgetWithText(TextField, 'Search keys...');
      await tester.enterText(searchField, 'temp');
      await tester.pumpAndSettle();

      // Only temperature_sensor should be visible
      expect(find.text('temperature_sensor'), findsOneWidget);
      expect(find.text('pressure_valve'), findsNothing);
    });

    testWidgets('search field filters keys by OPC UA identifier',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleKeyMappings(),
      ));
      await tester.pumpAndSettle();

      // Search by identifier 'PressureValve'
      final searchField = find.widgetWithText(TextField, 'Search keys...');
      await tester.enterText(searchField, 'PressureValve');
      await tester.pumpAndSettle();

      expect(find.text('pressure_valve'), findsOneWidget);
      expect(find.text('temperature_sensor'), findsNothing);
    });

    testWidgets('clearing search shows all keys', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleKeyMappings(),
      ));
      await tester.pumpAndSettle();

      // Search for temp
      final searchField = find.widgetWithText(TextField, 'Search keys...');
      await tester.enterText(searchField, 'temp');
      await tester.pumpAndSettle();

      expect(find.text('pressure_valve'), findsNothing);

      // Clear search
      await tester.enterText(searchField, '');
      await tester.pumpAndSettle();

      // Both keys visible again
      expect(find.text('temperature_sensor'), findsOneWidget);
      expect(find.text('pressure_valve'), findsOneWidget);
    });

    testWidgets('search results are ordered by match quality', (tester) async {
      // Inserted weakest match first: an exact hit must rank above a
      // word-boundary substring hit, which ranks above a subsequence hit.
      KeyMappingEntry entry(String identifier) => KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: identifier)
              ..serverAlias = 'main_server',
          );
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'thermal_probe': entry('ThermalProbe'),
          'motor_temp': entry('MotorTemp'),
          'temp': entry('Temp'),
        }),
      ));
      await tester.pumpAndSettle();

      final searchField = find.widgetWithText(TextField, 'Search keys...');
      await tester.enterText(searchField, 'temp');
      await tester.pumpAndSettle();

      // The search field's EditableText also holds 'temp'; match only the
      // card title Texts.
      final yOf = (String name) => tester
          .getTopLeft(
              find.byWidgetPredicate((w) => w is Text && w.data == name))
          .dy;
      expect(yOf('temp'), lessThan(yOf('motor_temp')));
      expect(yOf('motor_temp'), lessThan(yOf('thermal_probe')));
    });
  });

  // ==================== Group 8: Save and Load ====================
  group('Save and load', () {
    testWidgets('save button persists key mappings to preferences',
        (tester) async {
      final store = await createTestConfigStore(
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Add a key
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      // Save (scroll into view first since Browse button may push it off-screen)
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // Verify prefs were updated
      final savedKeyMappings = store.inner.keyMappings;
      expect(savedKeyMappings.nodes.containsKey('new_key'), isTrue);
    });

    testWidgets('renaming key name and saving persists the new name',
        (tester) async {
      final store = await createTestConfigStore(
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Add a key (creates 'new_key', auto-expanded)
      await tester.tap(find.text('Add Key'));
      await tester.pumpAndSettle();

      // Change the key name without pressing Enter
      final keyNameField = find.widgetWithText(TextField, 'new_key');
      expect(keyNameField, findsOneWidget);
      await tester.enterText(keyNameField, 'my_sensor');
      await tester.pumpAndSettle();

      // Tap Save (this moves focus away from text field)
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // Verify prefs contain the renamed key, not 'new_key'
      final savedKeyMappings = store.inner.keyMappings;
      expect(savedKeyMappings.nodes.containsKey('my_sensor'), isTrue,
          reason: 'Key should be saved with renamed name "my_sensor"');
      expect(savedKeyMappings.nodes.containsKey('new_key'), isFalse,
          reason: 'Old name "new_key" should no longer exist');
    });

    testWidgets('page loads existing key mappings from preferences',
        (tester) async {
      final km = KeyMappings(nodes: {
        'loaded_key': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 99, identifier: 'LoadedNode'),
        ),
      });

      await tester.pumpWidget(buildTestableKeyRepository(keyMappings: km));
      await tester.pumpAndSettle();

      expect(find.text('loaded_key'), findsOneWidget);
    });
  });

  // ==================== Group 9: Import/Export ====================
  group('Import/Export', () {
    testWidgets('export button is rendered', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(find.text('Export'), findsOneWidget);
    });

    testWidgets('import button is rendered', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(find.text('Import'), findsOneWidget);
    });
  });

  // ==================== Group 10: Database Status ====================
  group('Database status', () {
    testWidgets('shows database disconnected banner when database is null',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Database not connected'),
        findsOneWidget,
      );
    });
  });

  // ==================== Group 11: Modbus Protocol Configuration ====================
  group('Modbus protocol configuration', () {
    testWidgets('Modbus ChoiceChip appears when modbusServerAliases is non-empty',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleModbusKeyMappings(),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Expand the first card
      await tester.tap(find.text('modbus_temp'));
      await tester.pumpAndSettle();

      // Verify Modbus ChoiceChip exists alongside OPC UA
      expect(find.text('Modbus'), findsOneWidget);
      expect(find.text('OPC UA'), findsOneWidget);
    });

    testWidgets('tapping Modbus chip switches protocol and shows config section',
        (tester) async {
      // Start with an OPC UA key and Modbus servers configured
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'test_key': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 0, identifier: ''),
          ),
        }),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('test_key'));
      await tester.pumpAndSettle();

      // Tap the Modbus chip
      await tester.tap(find.text('Modbus'));
      await tester.pumpAndSettle();

      // Verify Modbus config section appears
      expect(find.text('Modbus Key Configuration'), findsOneWidget);

      // Verify all 5 fields are visible
      expect(find.text('Server Alias'), findsOneWidget);
      expect(find.text('Register Type'), findsOneWidget);
      expect(find.text('Address'), findsOneWidget);
      // Data type field exists (may be 'Data Type' or 'Data Type (auto)')
      expect(find.textContaining('Data Type'), findsOneWidget);
      expect(find.text('Poll Group'), findsOneWidget);
    });

    testWidgets('data type auto-locks to bit for coil register type',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'coil_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'plc_1',
              registerType: ModbusRegisterType.coil,
              address: 0,
              dataType: ModbusDataType.bit,
              pollGroup: 'default',
            ),
          ),
        }),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('coil_key'));
      await tester.pumpAndSettle();

      // Data type should show 'bit'
      expect(find.text('bit'), findsOneWidget);
      // Data type dropdown should be auto-locked (label shows 'Data Type (auto)')
      expect(find.text('Data Type (auto)'), findsOneWidget);
    });

    testWidgets('switching from coil to holdingRegister resets data type to uint16',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'coil_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'plc_1',
              registerType: ModbusRegisterType.coil,
              address: 0,
              dataType: ModbusDataType.bit,
              pollGroup: 'default',
            ),
          ),
        }),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('coil_key'));
      await tester.pumpAndSettle();

      // Tap register type dropdown and select holdingRegister
      final regTypeDropdown =
          find.byType(DropdownButtonFormField<ModbusRegisterType>);
      expect(regTypeDropdown, findsOneWidget);
      await tester.ensureVisible(regTypeDropdown);
      await tester.pumpAndSettle();
      await tester.tap(regTypeDropdown);
      await tester.pumpAndSettle();

      // Select holdingRegister from the dropdown menu
      await tester.tap(find.text('holdingRegister').last);
      await tester.pumpAndSettle();

      // Data type should now show uint16 (reset from bit)
      expect(find.text('uint16'), findsOneWidget);
      // Data type label should be 'Data Type' (not auto)
      expect(find.text('Data Type'), findsOneWidget);
    });

    testWidgets('poll group dropdown populated from selected server config',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'modbus_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'plc_1',
              registerType: ModbusRegisterType.holdingRegister,
              address: 100,
              dataType: ModbusDataType.uint16,
              pollGroup: 'default',
            ),
          ),
        }),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('modbus_key'));
      await tester.pumpAndSettle();

      // Scroll to make poll group dropdown visible.
      //
      // Named rather than taken as "the first Scrollable": since the
      // access-templates section was mounted, a short window puts a page-level
      // scroll view above the key list (KeyRepositoryContent.minContentHeight),
      // and `.first` picked that one — which scrolls the card being inspected
      // off the top instead of scrolling within it.
      await tester.scrollUntilVisible(
        find.text('Poll Group'),
        200,
        scrollable: keyListScrollable,
      );
      await tester.pumpAndSettle();

      // The selected value 'default (1000ms)' should be visible in the dropdown
      expect(find.text('default (1000ms)'), findsOneWidget);

      // Tap the poll group dropdown to open it and see all items
      // Use ancestor to find specifically the poll group dropdown
      final pollGroupDropdown = find.ancestor(
        of: find.text('Poll Group'),
        matching: find.byType(DropdownButtonFormField<String>),
      );
      expect(pollGroupDropdown, findsOneWidget);
      // Built is not the same as on screen: expanding the card scrolled it
      // within the key list, and on a short window the page scrolled too.
      await tester.ensureVisible(pollGroupDropdown);
      await tester.pumpAndSettle();
      await tester.tap(pollGroupDropdown);
      await tester.pumpAndSettle();

      // Both poll groups should be available in the menu
      expect(find.text('default (1000ms)'), findsAtLeastNWidgets(1));
      expect(find.text('fast (100ms)'), findsAtLeastNWidgets(1));
    });

    testWidgets('Modbus key subtitle shows compact format',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleModbusKeyMappings(),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Verify subtitle text for modbus_temp key contains compact format
      // Both keys have @ plc_1, so check the full subtitle pattern
      expect(find.textContaining('holdingRegister[100]'), findsOneWidget);
      expect(find.textContaining('float32'), findsOneWidget);
      // Both modbus_temp and modbus_coil have @ plc_1
      expect(find.textContaining('@ plc_1'), findsNWidgets(2));
    });

    testWidgets('search filter matches Modbus server alias',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleModbusKeyMappings(),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Both Modbus keys should be visible initially
      expect(find.text('modbus_temp'), findsOneWidget);
      expect(find.text('modbus_coil'), findsOneWidget);

      // Type 'plc_1' in the search field
      final searchField = find.widgetWithText(TextField, 'Search keys...');
      await tester.enterText(searchField, 'plc_1');
      await tester.pumpAndSettle();

      // Both Modbus keys should still be visible (they both use plc_1)
      expect(find.text('modbus_temp'), findsOneWidget);
      expect(find.text('modbus_coil'), findsOneWidget);
    });

    testWidgets('toggling collection on Modbus key preserves modbusNode config',
        (tester) async {
      final store = await createTestConfigStore(
        keyMappings: sampleModbusKeyMappings(),
        session: kConfiguringTestSession,
      );

      await tester.pumpWidget(buildTestableKeyRepository(
        stateManConfig: sampleStateManConfigWithModbus(),
        configStore: store,
      ));
      await tester.pumpAndSettle();

      // Expand 'modbus_temp' card
      await tester.tap(find.text('modbus_temp'));
      await tester.pumpAndSettle();

      // Scroll down to make the Switch visible
      await tester.scrollUntilVisible(
        find.byType(Switch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // Toggle collection on
      final switchWidget = find.byType(Switch);
      expect(switchWidget, findsOneWidget);
      await tester.tap(switchWidget);
      await tester.pumpAndSettle();

      // Save
      await tester.ensureVisible(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // Verify modbusNode config is preserved
      final saved = store.inner.keyMappings;
      final entry = saved.nodes['modbus_temp']!;
      expect(entry.modbusNode, isNotNull,
          reason: 'modbusNode should be preserved after toggling collection');
      expect(entry.modbusNode!.registerType, ModbusRegisterType.holdingRegister);
      expect(entry.modbusNode!.address, 100);
      expect(entry.modbusNode!.dataType, ModbusDataType.float32);
      expect(entry.collect, isNotNull,
          reason: 'Collection should be enabled');
    });
  });

  // ==================== Group 11b: UMAS variable name in subtitle ====================
  group('UMAS variable name in subtitle', () {
    testWidgets(
        'subtitle shows variableName instead of holdingRegister[N] when set',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'umas_named_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'schneider_plc',
              registerType: ModbusRegisterType.holdingRegister,
              address: 0,
              dataType: ModbusDataType.uint16,
              pollGroup: 'default',
            ),
            variableName: 'Elevator.q_xUp',
          ),
        }),
        stateManConfig: sampleStateManConfigWithUmas(),
      ));
      await tester.pumpAndSettle();

      // Subtitle should show the variable name, not the Modbus address.
      expect(find.textContaining('Elevator.q_xUp'), findsOneWidget);
      expect(find.textContaining('@ schneider_plc'), findsOneWidget);
      expect(find.textContaining('holdingRegister'), findsNothing,
          reason:
              'variableName-bound keys should not show holdingRegister[N]');
    });

    testWidgets(
        'subtitle falls back to holdingRegister[N] when variableName is null',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleModbusKeyMappings(),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // No variableName on these keys → existing subtitle format.
      expect(find.textContaining('holdingRegister[100]'), findsOneWidget);
      expect(find.textContaining('float32'), findsOneWidget);
      expect(find.textContaining('@ plc_1'), findsNWidgets(2));
    });

    testWidgets(
        'subtitle without serverAlias renders just the variable name',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'orphan_named_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: null,
              registerType: ModbusRegisterType.holdingRegister,
              address: 0,
              dataType: ModbusDataType.uint16,
              pollGroup: 'default',
            ),
            variableName: 'M_Pump.i_isAuto',
          ),
        }),
        stateManConfig: sampleStateManConfigWithUmas(),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('M_Pump.i_isAuto'), findsOneWidget);
      expect(find.textContaining('holdingRegister'), findsNothing);
      // No trailing '@ <alias>' when alias is absent.
      expect(find.textContaining('@'), findsNothing);
    });
  });

  // ==================== Group 12: UMAS Browse Button ====================
  group('UMAS browse button', () {
    testWidgets('Browse button visible when UMAS enabled on selected server',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'umas_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'schneider_plc',
              registerType: ModbusRegisterType.holdingRegister,
              address: 100,
              dataType: ModbusDataType.uint16,
              pollGroup: 'default',
            ),
          ),
        }),
        stateManConfig: sampleStateManConfigWithUmas(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('umas_key'));
      await tester.pumpAndSettle();

      // The Browse button should be visible in the Modbus config section
      expect(find.text('Browse'), findsOneWidget);
    });

    testWidgets('Browse button hidden when UMAS disabled on selected server',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'modbus_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'plc_1',
              registerType: ModbusRegisterType.holdingRegister,
              address: 100,
              dataType: ModbusDataType.uint16,
              pollGroup: 'default',
            ),
          ),
        }),
        stateManConfig: sampleStateManConfigWithModbus(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('modbus_key'));
      await tester.pumpAndSettle();

      // The Browse button should NOT be visible
      // (we need to check specifically within the Modbus config section)
      // Since there's no OPC UA Browse button either, just check there's none
      final browseButtons = find.text('Browse');
      expect(browseButtons, findsNothing);
    });

    testWidgets('Browse button hidden when no server alias selected',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'no_alias_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: null,
              registerType: ModbusRegisterType.holdingRegister,
              address: 0,
              dataType: ModbusDataType.uint16,
              pollGroup: 'default',
            ),
          ),
        }),
        stateManConfig: sampleStateManConfigWithUmas(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('no_alias_key'));
      await tester.pumpAndSettle();

      // No Browse button when no server alias selected
      expect(find.text('Browse'), findsNothing);
    });
  });

  // ==================== Bit Mask Section ====================
  group('Bit mask section', () {
    testWidgets('shows Bit Mask section for Modbus holding register key', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'status_word': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'plc_1',
              registerType: ModbusRegisterType.holdingRegister,
              address: 100,
              dataType: ModbusDataType.uint16,
            ),
          ),
        }),
        stateManConfig: sampleModbusStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('status_word'));
      await tester.pumpAndSettle();

      // Should show Bit Mask expansion tile
      expect(find.text('Bit Mask (optional)'), findsOneWidget);
    });

    testWidgets('hides Bit Mask section for coil keys', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: KeyMappings(nodes: {
          'coil_key': KeyMappingEntry(
            modbusNode: ModbusNodeConfig(
              serverAlias: 'plc_1',
              registerType: ModbusRegisterType.coil,
              address: 0,
              dataType: ModbusDataType.bit,
            ),
          ),
        }),
        stateManConfig: sampleModbusStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Expand the card
      await tester.tap(find.text('coil_key'));
      await tester.pumpAndSettle();

      // Should NOT show Bit Mask section for coil type
      expect(find.text('Bit Mask (optional)'), findsNothing);
    });

    testWidgets('shows Bit Mask section for OPC UA key', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: sampleKeyMappings(),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Expand the first card
      await tester.tap(find.text('temperature_sensor'));
      await tester.pumpAndSettle();

      // Should show Bit Mask section for OPC UA
      expect(find.text('Bit Mask (optional)'), findsOneWidget);
    });
  });

  // ==================== Group: Reorder keys ====================
  group('Reorder keys', () {
    /// Returns the rendered title order by walking the ExpansionTile widgets
    /// in the visual tree (which equals the iteration order of the underlying
    /// nodes map, since `_searchQuery` is empty by default).
    List<String> titleOrder(WidgetTester tester) {
      final titles = <String>[];
      // Use `find.descendant` per ExpansionTile to grab its `title` Text.
      final tiles = find.byType(ExpansionTile);
      for (var i = 0; i < tiles.evaluate().length; i++) {
        final tileTitle = find.descendant(
          of: tiles.at(i),
          matching: find.byType(Text),
        );
        // The first Text descendant is the title (the bold key name).
        // The next is the subtitle (server config string). Take the first.
        final text = tester.widget<Text>(tileTitle.first);
        titles.add(text.data ?? '');
      }
      return titles;
    }

    KeyMappings threeKeys() {
      return KeyMappings(nodes: {
        'alpha': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 1, identifier: 'A'),
        ),
        'bravo': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'B'),
        ),
        'charlie': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 3, identifier: 'C'),
        ),
      });
    }

    testWidgets('renders drag handles for each card when no search filter',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: threeKeys(),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Exactly one drag handle per card.
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));
      // Uses a ReorderableListView (not plain ListView) when no filter.
      expect(find.byType(ReorderableListView), findsOneWidget);
    });

    testWidgets('renders initial order alpha → bravo → charlie',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: threeKeys(),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      expect(titleOrder(tester), ['alpha', 'bravo', 'charlie']);
    });

    testWidgets(
        'invoking onReorder moves first card to last position; the keys are '
        'stored, the arrangement is not (D-5)', (tester) async {
      final store = await createTestConfigStore(
        keyMappings: threeKeys(),
        session: kConfiguringTestSession,
      );
      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Sanity check: starting order.
      expect(titleOrder(tester), ['alpha', 'bravo', 'charlie']);

      // Find the ReorderableListView and invoke its onReorder callback,
      // simulating a drag of index 0 to the end-of-list slot (index 3).
      // ReorderableListView convention: newIndex equals length when moving
      // to the very end; the widget's internal logic and our _reorderKey
      // both subtract 1 in that case.
      final reorderable =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      reorderable.onReorder!(0, 3);
      await tester.pumpAndSettle();

      // Visual order updated: alpha is now last. This half is unchanged and
      // is what the operator sees for the rest of the session.
      expect(titleOrder(tester), ['bravo', 'charlie', 'alpha']);

      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      // What is stored. `config_item` rows carry no order for key mappings —
      // the codec sorts by key on the way in and the store sorts again on the
      // way out — so the arrangement does not survive the save. Asserted
      // rather than left implicit, because until this phase it did survive:
      // the blob was a JSON object and `nodes` is a LinkedHashMap.
      // docs/relational-config-deferred-defects.md D-5.
      final saved = store.inner.keyMappings;
      expect(saved.nodes.keys.toSet(), {'alpha', 'bravo', 'charlie'},
          reason: 'every key is stored; only the arrangement is lost');
      expect(saved.nodes.keys.toList(), ['alpha', 'bravo', 'charlie'],
          reason: 'sorted by key, not in the order the operator arranged — '
              'D-5, and a change here means somebody taught the rows an '
              'order and should say so');
    });

    testWidgets(
        'reorder moves last card to first position; the round trip keeps the '
        'keys, not the arrangement (D-5)', (tester) async {
      final store = await createTestConfigStore(
        keyMappings: threeKeys(),
        session: kConfiguringTestSession,
      );
      await tester.pumpWidget(buildTestableKeyRepository(
        configStore: store,
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      final reorderable =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      // Drag last (index 2) to before-first (index 0).
      reorderable.onReorder!(2, 0);
      await tester.pumpAndSettle();

      expect(titleOrder(tester), ['charlie', 'alpha', 'bravo']);

      // The round trip preserves the keys, not their arrangement — D-5, as
      // above. The visual order is the page's own map and stays correct until
      // the next load.
      await tester.tap(find.text('Save Key Mappings'));
      await tester.pumpAndSettle();

      final saved = store.inner.keyMappings;
      expect(saved.nodes.keys.toList(), ['alpha', 'bravo', 'charlie']);
    });

    testWidgets('search filter disables reordering (no ReorderableListView)',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: threeKeys(),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Locate the search field by its hintText.
      final searchField = find.byWidgetPredicate((w) {
        if (w is! TextField) return false;
        final decoration = w.decoration;
        if (decoration == null) return false;
        return decoration.hintText == 'Search keys...';
      });
      expect(searchField, findsOneWidget);
      await tester.enterText(searchField, 'alpha');
      await tester.pumpAndSettle();

      // Plain ListView is now used; no ReorderableListView visible.
      expect(find.byType(ReorderableListView), findsNothing);
      // Drag handles hidden because cards don't get a reorderIndex.
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });
  });

  // ==================== Group: Large repositories ====================
  //
  // The page used to render every key card up front (a shrink-wrapped list
  // inside a page-level scroll view), which made a few thousand keys
  // unusable — seconds per keystroke in the search box.
  group('Large repositories', () {
    KeyMappings manyKeys(int count) => KeyMappings(nodes: {
          for (var i = 0; i < count; i++)
            'area${i % 4}_dev${i}_temperature': KeyMappingEntry(
              opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Node$i')
                ..serverAlias = 'main_server',
            ),
        });

    testWidgets('builds only the cards on screen, not all of them',
        (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: manyKeys(500),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      final built = find.byType(ExpansionTile).evaluate().length;
      expect(built, lessThan(30),
          reason: 'the key list must build lazily; got $built cards for 500 '
              'keys');
      expect(built, greaterThan(0));
    });

    testWidgets('searching still builds only a screenful', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: manyKeys(500),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // 'area1' matches a quarter of the keys.
      await tester.enterText(
          find.widgetWithText(TextField, 'Search keys...'), 'area1');
      await tester.pumpAndSettle();

      expect(find.byType(ReorderableListView), findsNothing);
      final built = find.byType(ExpansionTile).evaluate().length;
      expect(built, lessThan(30),
          reason: 'filtered results must build lazily too; got $built');
      // The filter did narrow the list: 'area3_...' keys can't fuzzy-match
      // 'area1' (no '1' left to consume after 'area'... in a 'dev3' key).
      expect(find.textContaining('area3_dev3_'), findsNothing);
    });

    testWidgets('an expanded card is still expanded after scrolling away '
        'and back', (tester) async {
      await tester.pumpWidget(buildTestableKeyRepository(
        keyMappings: manyKeys(100),
        stateManConfig: sampleStateManConfig(),
      ));
      await tester.pumpAndSettle();

      // Expand the first card.
      const first = 'area0_dev0_temperature';
      await tester.tap(find.text(first));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Key Name'), findsOneWidget);

      // Scroll far past it so the lazy list destroys the card, then back.
      await tester.drag(keyListScrollable, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(find.text(first), findsNothing,
          reason: 'card should have been disposed while off screen');
      await scrollKeyListToTop(tester);

      // Still expanded: the name field is showing again.
      expect(find.widgetWithText(TextField, 'Key Name'), findsOneWidget);
    });
  });
}
