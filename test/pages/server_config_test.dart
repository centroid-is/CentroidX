import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/test_helpers.dart';

void main() {
  // Initialize mock SharedPreferences for DatabaseConfigWidget and OPC UA sections
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });
  // ==================== Group 1: Modbus Section Rendering ====================
  group('Modbus section rendering', () {
    testWidgets('renders "Modbus TCP Servers" section header', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());

      // Scroll to find Modbus section (it's the 4th section on the page)
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Modbus TCP Servers'), findsOneWidget);
    });

    testWidgets('renders networkWired icon in section header', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());

      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Find the networkWired icon within the Modbus section
      final networkWiredIcons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.networkWired.data);
      expect(networkWiredIcons, findsAtLeastNWidgets(1));
    });

    testWidgets('shows empty state when config.modbus is empty',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());

      await tester.scrollUntilVisible(
        find.text('No Modbus servers configured'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('No Modbus servers configured'), findsOneWidget);
      expect(find.text('Add your first Modbus TCP server to get started'),
          findsOneWidget);
    });
  });

  // ==================== Group 2: Add Modbus Server ====================
  group('Add Modbus server', () {
    testWidgets(
        'tapping "Add Server" creates a card with defaults (localhost, 502, unit ID 1)',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());

      // Scroll to Modbus section and find its Add Server button.
      // There may be multiple "Add Server" buttons (OPC UA, JBTM, Modbus).
      // Scroll to the Modbus section first.
      await tester.scrollUntilVisible(
        find.text('No Modbus servers configured'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Find Add Server buttons -- the Modbus one is the last one
      final addButtons = find.text('Add Server');
      // Tap the last Add Server button (belongs to Modbus section)
      await tester.tap(addButtons.last);
      await settle(tester);

      // Empty state should be gone
      expect(find.text('No Modbus servers configured'), findsNothing);

      // Card should show default host:port:unitId in subtitle
      expect(find.text('localhost:502 (Unit 1)'), findsOneWidget);
    });
  });

  // ==================== Group 3: Edit Modbus Server ====================
  group('Edit Modbus server', () {
    testWidgets(
        'editing host field updates the server config and arms the save button',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Find and expand the server card by tapping its title
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to make the host field visible
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, 'Host'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Change the host field
      final hostField = find.widgetWithText(TextField, 'Host');
      await tester.enterText(hostField, '10.0.0.1');
      await settle(tester);

      // The save button is the page's ONE unsaved indicator: it arms to
      // "Save Configuration" (the orange pill is gone — phase 2 of
      // quick/20260908-unify-config-ui).
      await tester.scrollUntilVisible(
        find.text('Save Configuration'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Save Configuration'), findsOneWidget);
    });
  });

  // ==================== Group 4: Remove Modbus Server ====================
  group('Remove Modbus server', () {
    testWidgets('tapping delete button shows confirmation dialog',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Find trash icon buttons in the Modbus section area.
      // Tap the last trash button (belongs to Modbus card).
      final trashButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.trash.data);
      await tester.tap(trashButtons.last);
      await settle(tester);

      expect(find.text('Remove server'), findsOneWidget);
      expect(
          find.text('Are you sure you want to remove this Modbus server?'),
          findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('confirming removal removes the server card', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Server card should be visible
      expect(find.text('plc_1'), findsOneWidget);

      // Tap delete (last trash button)
      final trashButtons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.trash.data);
      await tester.tap(trashButtons.last);
      await settle(tester);

      // Confirm removal
      await tester.tap(find.text('Remove'));
      await settle(tester);

      // Server card should be gone, empty state should show
      expect(find.text('plc_1'), findsNothing);
      expect(find.text('No Modbus servers configured'), findsOneWidget);
    });
  });

  // ==================== Group 5: Connection Status ====================
  group('Connection status', () {
    testWidgets('shows grey dot with "Not active" when no StateMan',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // The connection status chip should show "Not active" (grey)
      // since stateManProvider is not overridden with a real StateMan
      expect(find.text('Not active'), findsAtLeastNWidgets(1));
    });
  });

  // ==================== Group 6: Poll Group Configuration ====================
  group('Poll group configuration', () {
    testWidgets('shows Poll Groups header with count', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusWithTwoPollGroups(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand the server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to see poll groups header
      await tester.scrollUntilVisible(
        find.text('Poll Groups (2)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Poll Groups (2)'), findsOneWidget);
    });

    testWidgets('expanding poll groups shows name and interval fields',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusWithTwoPollGroups(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to poll groups and expand
      await tester.scrollUntilVisible(
        find.text('Poll Groups (2)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      await tester.tap(find.text('Poll Groups (2)'));
      await settle(tester);

      // Should show name fields with 'default' and 'fast' values
      expect(find.widgetWithText(TextField, 'Name'), findsAtLeastNWidgets(1));
      expect(
          find.widgetWithText(TextField, 'Interval'), findsAtLeastNWidgets(1));
    });

    testWidgets('add poll group creates new row', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to and expand poll groups
      await tester.scrollUntilVisible(
        find.text('Poll Groups (1)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      await tester.tap(find.text('Poll Groups (1)'));
      await settle(tester);

      // Scroll to Add Poll Group button
      await tester.scrollUntilVisible(
        find.text('Add Poll Group'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Tap add
      await tester.tap(find.text('Add Poll Group'));
      await settle(tester);

      // Count should increase to 2
      expect(find.text('Poll Groups (2)'), findsOneWidget);
    });

    testWidgets('delete poll group removes row', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusWithTwoPollGroups(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to and expand poll groups
      await tester.scrollUntilVisible(
        find.text('Poll Groups (2)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      await tester.tap(find.text('Poll Groups (2)'));
      await settle(tester);

      // Find trash icons within poll group rows -- the small ones (size 14)
      // The server card trash is size 16, poll group trash is size 14
      final pollGroupTrashIcons = find.byWidgetPredicate(
          (w) => w is FaIcon && w.icon == FontAwesomeIcons.trash.data && w.size == 14);
      expect(pollGroupTrashIcons, findsAtLeastNWidgets(1));

      // Tap first poll group trash icon
      await tester.tap(pollGroupTrashIcons.first);
      await settle(tester);

      // Count should decrease to 1
      expect(find.text('Poll Groups (1)'), findsOneWidget);
    });

    testWidgets('editing poll group triggers unsaved changes', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to and expand poll groups
      await tester.scrollUntilVisible(
        find.text('Poll Groups (1)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      await tester.tap(find.text('Poll Groups (1)'));
      await settle(tester);

      // Scroll to interval field
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, 'Interval'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Change interval
      final intervalField = find.widgetWithText(TextField, 'Interval');
      await tester.enterText(intervalField.first, '500');
      await settle(tester);

      // The armed save button is the one unsaved indicator.
      await tester.scrollUntilVisible(
        find.text('Save Configuration'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Save Configuration'), findsOneWidget);
    });
  });

  // ==================== Group 7: Save Button ====================
  group('Save button', () {
    testWidgets('Save button disabled when no changes', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus save button area
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Find "All Changes Saved" text (indicates save button is disabled)
      // Need to scroll further to find it
      await tester.scrollUntilVisible(
        find.text('All Changes Saved').last,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // The last "All Changes Saved" belongs to Modbus section
      expect(find.text('All Changes Saved'), findsAtLeastNWidgets(1));
    });

    testWidgets('Save button text changes to "Save Configuration" when unsaved',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand the server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Edit host to create unsaved changes
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, 'Host'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      final hostField = find.widgetWithText(TextField, 'Host');
      await tester.enterText(hostField, '10.0.0.1');
      await settle(tester);

      // Scroll to Save button area
      await tester.scrollUntilVisible(
        find.text('Save Configuration'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Save Configuration'), findsAtLeastNWidgets(1));
    });
  });

  // ==================== Group 8: UMAS Checkbox ====================
  group('UMAS checkbox', () {
    testWidgets('UMAS checkbox appears in Modbus server config card',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand the server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to UMAS checkbox
      await tester.scrollUntilVisible(
        find.text('Schneider UMAS'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Schneider UMAS'), findsOneWidget);
      expect(find.text('Variable browsing via FC90 (M340/M580 only)'), findsOneWidget);
    });

    testWidgets('toggling UMAS checkbox triggers unsaved changes',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig(stateManConfig: sampleModbusStateManConfig(),));

      // Scroll to Modbus section
      await tester.scrollUntilVisible(
        find.text('Modbus TCP Servers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Expand the server card
      await tester.tap(find.text('plc_1'));
      await settle(tester);

      // Scroll to UMAS checkbox
      await tester.scrollUntilVisible(
        find.text('Schneider UMAS'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      // Tap the checkbox
      await tester.tap(find.text('Schneider UMAS'));
      await settle(tester);

      // The armed save button is the one unsaved indicator.
      await tester.scrollUntilVisible(
        find.text('Save Configuration'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);

      expect(find.text('Save Configuration'), findsOneWidget);
    });
  });
}
