import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:open62541/open62541.dart'
    show
        AttributeId,
        BrowseResultItem,
        BrowseResultMask,
        BrowseTreeItem,
        ClientApi,
        ClientState,
        DataValue,
        DynamicValue,
        MonitoringMode,
        NodeClass,
        NodeId,
        UA_STATUSCODE_GOOD;

import 'package:tfc/widgets/browse_panel.dart';
import 'package:tfc/widgets/opcua_browse.dart';

// ---------------------------------------------------------------------------
// Fake ClientApi
// ---------------------------------------------------------------------------

class FakeClientApi implements ClientApi {
  final Map<NodeId, List<BrowseResultItem>> browseResults;
  final Map<NodeId, DynamicValue> readResults;
  int browseCallCount = 0;
  int readCallCount = 0;
  Duration browseDelay;

  FakeClientApi({
    this.browseResults = const {},
    this.readResults = const {},
    this.browseDelay = Duration.zero,
  });

  @override
  Future<List<BrowseResultItem>> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) async {
    browseCallCount++;
    if (browseDelay > Duration.zero) {
      await Future.delayed(browseDelay);
    }
    return browseResults[nodeId] ?? [];
  }

  @override
  Future<DynamicValue> read(NodeId nodeId) async {
    readCallCount++;
    return readResults[nodeId] ?? DynamicValue();
  }

  @override
  Future<DataValue> readValue(NodeId nodeId) async {
    readCallCount++;
    return DataValue(
      value: readResults[nodeId] ?? DynamicValue(),
      statusCode: UA_STATUSCODE_GOOD,
    );
  }

  // -- Unused stubs --
  @override
  Future<void> awaitConnect() async {}
  @override
  Future<void> connect(String url) async {}
  @override
  Future<void> delete() async {}
  @override
  Future<void> write(NodeId nodeId, DynamicValue value) async {}
  @override
  Stream<ClientState> get stateStream => const Stream.empty();
  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async =>
      0;
  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) =>
      const Stream.empty();
  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    Map<NodeId, List<AttributeId>> nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) =>
      const Stream.empty();
  @override
  Stream<BrowseTreeItem> browseTree(
    NodeId root, {
    int maxDepth = 100,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<NodeClass> recurseInto = const {
      NodeClass.UA_NODECLASS_OBJECT,
      NodeClass.UA_NODECLASS_VIEW,
    },
  }) =>
      const Stream.empty();
  @override
  Future<List<DynamicValue>> call(
          NodeId objectId, NodeId methodId, Iterable<DynamicValue> args) async =>
      [];
  @override
  Future<Map<NodeId, DynamicValue>> readAttribute(
          Map<NodeId, List<dynamic>> nodes) async =>
      {};
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

NodeId _nodeId(int ns, String s) => NodeId.fromString(ns, s);

BrowseResultItem _object(String name, {int ns = 2, String? id}) =>
    BrowseResultItem(
      referenceTypeId: NodeId.fromNumeric(0, 0),
      isForward: true,
      nodeId: _nodeId(ns, id ?? name),
      browseName: name,
      displayName: name,
      nodeClass: NodeClass.UA_NODECLASS_OBJECT,
    );

BrowseResultItem _variable(String name, {int ns = 2, String? id}) =>
    BrowseResultItem(
      referenceTypeId: NodeId.fromNumeric(0, 0),
      isForward: true,
      nodeId: _nodeId(ns, id ?? name),
      browseName: name,
      displayName: name,
      nodeClass: NodeClass.UA_NODECLASS_VARIABLE,
    );

BrowseResultItem _method(String name, {int ns = 2, String? id}) =>
    BrowseResultItem(
      referenceTypeId: NodeId.fromNumeric(0, 0),
      isForward: true,
      nodeId: _nodeId(ns, id ?? name),
      browseName: name,
      displayName: name,
      nodeClass: NodeClass.UA_NODECLASS_METHOD,
    );

/// Pumps a [BrowsePanel] with an [OpcUaBrowseDataSource] inside a dialog.
Future<void> _showPanel(
  WidgetTester tester,
  FakeClientApi client, {
  String alias = 'TestServer',
}) async {
  final dataSource = OpcUaBrowseDataSource(client);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showBrowseDialog(
                context: context,
                dataSource: dataSource,
                serverAlias: alias,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('OpcUaBrowseDataSource via BrowsePanel', () {
    testWidgets('shows loading indicator then root nodes', (tester) async {
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [
            _object('Server'),
            _object('MyDevice'),
          ],
        },
      );

      await _showPanel(tester, client);

      expect(find.text('Server'), findsOneWidget);
      expect(find.text('MyDevice'), findsOneWidget);
    });

    testWidgets('shows server alias in header', (tester) async {
      final client = FakeClientApi(
        browseResults: {NodeId.objectsFolder: []},
      );

      await _showPanel(tester, client, alias: 'opc.tcp://plc1:4840');

      expect(find.text('Browse'), findsOneWidget);
      expect(find.text('opc.tcp://plc1:4840'), findsOneWidget);
    });

    testWidgets('shows "No nodes found" for empty server', (tester) async {
      final client = FakeClientApi(
        browseResults: {NodeId.objectsFolder: []},
      );

      await _showPanel(tester, client);

      expect(find.text('No nodes found'), findsOneWidget);
    });

    testWidgets('shows error when browse fails', (tester) async {
      final client = _FailingBrowseClient();

      await _showPanel(tester, client);

      expect(find.textContaining('Connection refused'), findsOneWidget);
    });

    testWidgets('expanding an object node loads and shows children',
        (tester) async {
      final deviceId = _nodeId(2, 'MyDevice');
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_object('MyDevice', id: 'MyDevice')],
          deviceId: [
            _variable('Temperature', id: 'Temp'),
            _variable('Pressure', id: 'Press'),
          ],
        },
      );

      await _showPanel(tester, client);

      expect(find.text('MyDevice'), findsOneWidget);
      expect(find.text('Temperature'), findsNothing);

      await tester.tap(find.text('MyDevice'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.text('Temperature'), findsOneWidget);
      expect(find.text('Pressure'), findsOneWidget);
    });

    testWidgets('collapsing an expanded node hides children', (tester) async {
      final deviceId = _nodeId(2, 'MyDevice');
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_object('MyDevice', id: 'MyDevice')],
          deviceId: [_variable('Temperature', id: 'Temp')],
        },
      );

      await _showPanel(tester, client);

      await tester.tap(find.text('MyDevice'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('Temperature'), findsOneWidget);

      await tester.tap(find.text('MyDevice'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('Temperature'), findsNothing);
    });

    testWidgets('tapping a variable node selects it', (tester) async {
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_variable('SomeVar')],
        },
        readResults: {
          _nodeId(2, 'SomeVar'): DynamicValue()..value = 42,
        },
      );

      await _showPanel(tester, client);

      await tester.tap(find.text('SomeVar'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      final selectButton =
          tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Select'));
      expect(selectButton.onPressed, isNotNull);
    });

    testWidgets('tapping Select with selected variable dismisses dialog',
        (tester) async {
      final varItem = _variable('MyVar');
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [varItem],
        },
        readResults: {
          varItem.nodeId: DynamicValue()..value = 99,
        },
      );

      await _showPanel(tester, client);

      await tester.tap(find.text('MyVar'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();

      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('double-tapping a variable dismisses dialog', (tester) async {
      final varItem = _variable('DblTapVar');
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [varItem],
        },
        readResults: {
          varItem.nodeId: DynamicValue()..value = 1,
        },
      );

      await _showPanel(tester, client);

      // First tap selects the variable
      await tester.tap(find.text('DblTapVar'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Second tap on the already-selected variable confirms (dismisses).
      // After selection, the breadcrumb also shows 'DblTapVar', so tap
      // the BrowseNodeTile directly to avoid ambiguity.
      await tester.tap(find.byType(BrowseNodeTile));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('header close button dismisses dialog', (tester) async {
      final client = FakeClientApi(
        browseResults: {NodeId.objectsFolder: []},
      );

      await _showPanel(tester, client);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('Select button is disabled when no variable selected',
        (tester) async {
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_object('Folder')],
        },
      );

      await _showPanel(tester, client);

      final selectButton =
          tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Select'));
      expect(selectButton.onPressed, isNull);
    });

    testWidgets('detail strip shows when variable selected', (tester) async {
      final varItem = _variable('DetailVar');
      final dv = DynamicValue()..value = 3.14;
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [varItem],
        },
        readResults: {
          varItem.nodeId: dv,
        },
      );

      await _showPanel(tester, client);

      expect(find.byType(VariableDetailStrip), findsNothing);

      await tester.tap(find.text('DetailVar'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(VariableDetailStrip), findsOneWidget);
      expect(find.text('3.14'), findsOneWidget);
    });

    testWidgets('detail strip shows error when read fails', (tester) async {
      final varItem = _variable('FailVar');
      final client = _FailingReadClient(
        browseResults: {
          NodeId.objectsFolder: [varItem],
        },
      );

      await _showPanel(tester, client);

      await tester.tap(find.text('FailVar'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.textContaining('Error:'), findsOneWidget);
    });

    testWidgets('shows object, variable, and method icons', (tester) async {
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [
            _object('Folder1'),
            _variable('Var1'),
            _method('Method1'),
          ],
        },
      );

      await _showPanel(tester, client);

      // Standard Icon widgets
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      // FaIcon uses RichText, not Icon, so find.byIcon won't work
      expect(
        find.byWidgetPredicate(
            (w) => w is FaIcon && w.icon == FontAwesomeIcons.tag.data),
        findsOneWidget,
      );
    });

    testWidgets('breadcrumb shows Root by default', (tester) async {
      final client = FakeClientApi(
        browseResults: {NodeId.objectsFolder: [_variable('X')]},
      );

      await _showPanel(tester, client);

      expect(find.text('Root'), findsOneWidget);
    });

    testWidgets('tapping already-selected variable confirms selection',
        (tester) async {
      final varItem = _variable('ConfirmVar');
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [varItem],
        },
        readResults: {
          varItem.nodeId: DynamicValue()..value = 1,
        },
      );

      await _showPanel(tester, client);

      // First tap: select
      await tester.tap(find.text('ConfirmVar'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.byType(BrowsePanel), findsOneWidget);

      // Second tap: confirm (dismiss). After selection, the breadcrumb also
      // shows 'ConfirmVar', so tap the BrowseNodeTile directly.
      await tester.tap(find.byType(BrowseNodeTile));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('method nodes are not selectable', (tester) async {
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_method('MyMethod')],
        },
      );

      await _showPanel(tester, client);

      await tester.tap(find.text('MyMethod'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      final selectButton =
          tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Select'));
      expect(selectButton.onPressed, isNull);
    });

    testWidgets('nested expansion works multiple levels', (tester) async {
      final deviceId = _nodeId(2, 'Device');
      final sensorsId = _nodeId(2, 'Sensors');
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_object('Device', id: 'Device')],
          deviceId: [_object('Sensors', id: 'Sensors')],
          sensorsId: [_variable('TempSensor', id: 'TempSensor')],
        },
      );

      await _showPanel(tester, client);

      await tester.tap(find.text('Device'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('Sensors'), findsOneWidget);

      await tester.tap(find.text('Sensors'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('TempSensor'), findsOneWidget);
    });

    testWidgets(
        'struct variable synthesizes children from DynamicValue fields',
        (tester) async {
      final structVar =
          _variable('hmi', ns: 4, id: 'GVL.roe_2.hmi');
      final structValue = DynamicValue()
        ..value = {
          'descriptions': DynamicValue()..value = 'desc',
          'min_values': DynamicValue()..value = 0.0,
          'max_values': DynamicValue()..value = 100.0,
        };

      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [structVar],
          // Browse of the variable returns empty -- server doesn't
          // expose struct fields as child nodes.
        },
        readResults: {
          structVar.nodeId: structValue,
        },
      );

      await _showPanel(tester, client);

      // Tap to select the struct variable -- it auto-expands
      await tester.tap(find.text('hmi'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Sub-fields should be visible immediately (auto-expanded)
      expect(find.text('descriptions'), findsOneWidget);
      expect(find.text('min_values'), findsOneWidget);
      expect(find.text('max_values'), findsOneWidget);

      // Sub-fields should be selectable
      await tester.tap(find.text('min_values'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      final selectButton = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Select'));
      expect(selectButton.onPressed, isNotNull);
    });
  });

  group('OpcUaBrowseDataSource.parseNodeId', () {
    test('parses numeric NodeId', () {
      final nodeId = OpcUaBrowseDataSource.parseNodeId('ns=0;i=2258');
      expect(nodeId.namespace, 0);
      expect(nodeId.isNumeric(), true);
      expect(nodeId.numeric, 2258);
    });

    test('parses string NodeId', () {
      final nodeId = OpcUaBrowseDataSource.parseNodeId('ns=2;s=MyVar');
      expect(nodeId.namespace, 2);
      expect(nodeId.isString(), true);
      expect(nodeId.string, 'MyVar');
    });

    test('parses string NodeId with dots', () {
      final nodeId = OpcUaBrowseDataSource.parseNodeId('ns=4;s=GVL.roe.hmi');
      expect(nodeId.namespace, 4);
      expect(nodeId.isString(), true);
      expect(nodeId.string, 'GVL.roe.hmi');
    });

    test('throws on invalid format', () {
      expect(
        () => OpcUaBrowseDataSource.parseNodeId('invalid'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('OpcUaBrowseDataSource.formatDynamicValue', () {
    test('formats null value', () {
      expect(OpcUaBrowseDataSource.formatDynamicValue(DynamicValue()), 'null');
    });

    test('formats simple value', () {
      final dv = DynamicValue()..value = 42;
      expect(OpcUaBrowseDataSource.formatDynamicValue(dv), '42');
    });

    test('formats string value', () {
      final dv = DynamicValue()..value = 'hello';
      expect(OpcUaBrowseDataSource.formatDynamicValue(dv), 'hello');
    });

    test('truncates long string', () {
      final dv = DynamicValue()..value = 'x' * 200;
      final result = OpcUaBrowseDataSource.formatDynamicValue(dv);
      expect(result.length, 120);
      expect(result.endsWith('...'), true);
    });
  });

  // -----------------------------------------------------------------
  // resolvePath — pre-selection support for OPC-UA. Walks the address
  // space looking for the chain to the target NodeId, using prefix
  // matching under the dotted `ns=X;s=A.B.C` convention.
  // -----------------------------------------------------------------
  group('OpcUaBrowseDataSource.resolvePath', () {
    test('returns root→leaf chain via dotted prefix walking', () async {
      // Tree: Objects → ns=2;s=GVL → ns=2;s=GVL.Motor → ns=2;s=GVL.Motor.speed
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_object('GVL', id: 'GVL')],
          _nodeId(2, 'GVL'): [_object('Motor', id: 'GVL.Motor')],
          _nodeId(2, 'GVL.Motor'): [
            _variable('speed', id: 'GVL.Motor.speed'),
          ],
        },
      );
      final ds = OpcUaBrowseDataSource(client);

      final chain = await ds.resolvePath('ns=2;s=GVL.Motor.speed');

      expect(chain, isNotNull);
      expect(chain!.map((n) => n.id).toList(), [
        'ns=2;s=GVL',
        'ns=2;s=GVL.Motor',
        'ns=2;s=GVL.Motor.speed',
      ]);
      expect(chain.last.type, BrowseNodeType.variable);
    });

    test('returns null when target is unknown', () async {
      final client = FakeClientApi(
        browseResults: {
          NodeId.objectsFolder: [_object('OnlyThis', id: 'OnlyThis')],
          _nodeId(2, 'OnlyThis'): const [],
        },
      );
      final ds = OpcUaBrowseDataSource(client);

      final chain = await ds.resolvePath('ns=2;s=Missing.Path');

      expect(chain, isNull,
          reason:
              'unresolvable target surfaces as null — caller falls back '
              'to empty-selection state');
    });

    test('returns null for empty input without browsing', () async {
      final client = FakeClientApi();
      final ds = OpcUaBrowseDataSource(client);

      expect(await ds.resolvePath(''), isNull);
      expect(client.browseCallCount, 0,
          reason: 'empty target short-circuits before hitting the wire');
    });
  });
}

// ---------------------------------------------------------------------------
// Specialized fakes
// ---------------------------------------------------------------------------

class _FailingBrowseClient extends FakeClientApi {
  @override
  Future<List<BrowseResultItem>> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) async {
    throw Exception('Connection refused');
  }
}

class _FailingReadClient extends FakeClientApi {
  _FailingReadClient({super.browseResults});

  @override
  Future<DynamicValue> read(NodeId nodeId) async {
    throw Exception('buildSchema failed');
  }

  @override
  Future<DataValue> readValue(NodeId nodeId) async {
    throw Exception('buildSchema failed');
  }
}
