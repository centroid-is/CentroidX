import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:tfc/widgets/browse_panel.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/resizable_overlay_frame.dart';

// ---------------------------------------------------------------------------
// Fake BrowseDataSource
// ---------------------------------------------------------------------------

class FakeBrowseDataSource implements BrowseDataSource {
  final Map<String, List<BrowseNode>> _children;
  final Map<String, BrowseNodeDetail> _details;
  final Map<String, List<BrowseNode>> _resolveChains;
  int fetchRootsCallCount = 0;
  int fetchChildrenCallCount = 0;
  int fetchDetailCallCount = 0;
  int resolvePathCallCount = 0;

  /// When non-null, fetchRoots() will await this completer instead of
  /// returning immediately. Call [rootsCompleter]!.complete() from the test
  /// to unblock it.
  Completer<void>? rootsCompleter;

  FakeBrowseDataSource({
    required List<BrowseNode> roots,
    Map<String, List<BrowseNode>>? children,
    Map<String, BrowseNodeDetail>? details,
    Map<String, List<BrowseNode>>? resolveChains,
    this.rootsCompleter,
  })  : _children = {
          '__roots__': roots,
          ...?children,
        },
        _details = details ?? {},
        _resolveChains = resolveChains ?? const {};

  @override
  Future<List<BrowseNode>> fetchRoots() async {
    fetchRootsCallCount++;
    if (rootsCompleter != null) await rootsCompleter!.future;
    return _children['__roots__'] ?? [];
  }

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async {
    fetchChildrenCallCount++;
    return _children[parent.id] ?? [];
  }

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    fetchDetailCallCount++;
    return _details[node.id] ?? const BrowseNodeDetail();
  }

  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    resolvePathCallCount++;
    return _resolveChains[targetId];
  }
}

class FailingBrowseDataSource implements BrowseDataSource {
  @override
  Future<List<BrowseNode>> fetchRoots() async {
    throw Exception('Connection refused');
  }

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async {
    throw Exception('Connection refused');
  }

  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    throw Exception('Connection refused');
  }

  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async => null;
}

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

const _plcFolder = BrowseNode(
  id: 'plc',
  displayName: 'PLC',
  type: BrowseNodeType.folder,
);

const _systemFolder = BrowseNode(
  id: 'system',
  displayName: 'System',
  type: BrowseNodeType.folder,
);

const _tempVar = BrowseNode(
  id: 'plc.temp',
  displayName: 'Temperature',
  type: BrowseNodeType.variable,
  dataType: 'REAL',
);

const _pressVar = BrowseNode(
  id: 'plc.press',
  displayName: 'Pressure',
  type: BrowseNodeType.variable,
  dataType: 'INT',
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<void> _showPanel(
  WidgetTester tester,
  BrowseDataSource dataSource, {
  String alias = 'TestServer',
}) async {
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
  group('BrowsePanel', () {
    testWidgets('Test 1: shows loading spinner while fetchRoots is pending',
        (tester) async {
      final completer = Completer<void>();
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder, _systemFolder],
        rootsCompleter: completer,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showBrowseDialog(
                    context: context,
                    dataSource: ds,
                    serverAlias: 'TestServer',
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump(); // Show dialog
      await tester.pump(); // Build the panel (roots still pending)

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Unblock and settle to avoid pending timers
      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('Test 2: renders root nodes from fetchRoots', (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder, _systemFolder],
      );

      await _showPanel(tester, ds);

      expect(find.text('PLC'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
    });

    testWidgets('Test 3: tapping a folder expands it and shows children',
        (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder],
        children: {
          'plc': [_tempVar, _pressVar],
        },
      );

      await _showPanel(tester, ds);

      expect(find.text('PLC'), findsOneWidget);
      expect(find.text('Temperature'), findsNothing);

      await tester.tap(find.text('PLC'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.text('Temperature'), findsOneWidget);
      expect(find.text('Pressure'), findsOneWidget);
    });

    testWidgets('Test 4: tapping an expanded folder collapses it',
        (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder],
        children: {
          'plc': [_tempVar],
        },
      );

      await _showPanel(tester, ds);

      // Expand
      await tester.tap(find.text('PLC'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('Temperature'), findsOneWidget);

      // Collapse
      await tester.tap(find.text('PLC'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('Temperature'), findsNothing);
    });

    testWidgets('Test 5: tapping a variable selects it and shows detail strip',
        (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_tempVar],
        details: {
          'plc.temp': const BrowseNodeDetail(
            value: '23.5',
            dataType: 'Float',
          ),
        },
      );

      await _showPanel(tester, ds);

      expect(find.byType(VariableDetailStrip), findsNothing);

      await tester.tap(find.text('Temperature'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(VariableDetailStrip), findsOneWidget);
      expect(find.text('23.5'), findsOneWidget);

      // Select button should be enabled
      final selectButton = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Select'));
      expect(selectButton.onPressed, isNotNull);
    });

    testWidgets(
        'Test 6: double-tapping a variable calls onSelected with the BrowseNode',
        (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_tempVar],
        details: {
          'plc.temp': const BrowseNodeDetail(value: '23.5'),
        },
      );

      await _showPanel(tester, ds);

      // First tap to select
      await tester.tap(find.text('Temperature'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.byType(BrowsePanel), findsOneWidget);

      // Second tap on already-selected variable triggers onSelected (dismiss).
      // BrowseNodeTile is the specific widget, avoids breadcrumb ambiguity.
      await tester.tap(find.byType(BrowseNodeTile));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('Test 7: Select button calls onSelected', (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_tempVar],
        details: {
          'plc.temp': const BrowseNodeDetail(value: '23.5'),
        },
      );

      await _showPanel(tester, ds);

      // Select the variable
      await tester.tap(find.text('Temperature'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Click the Select button
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();

      // Dialog should be dismissed
      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('Test 8: breadcrumb shows path from root to selected node',
        (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder],
        children: {
          'plc': [_tempVar],
        },
        details: {
          'plc.temp': const BrowseNodeDetail(value: '23.5'),
        },
      );

      await _showPanel(tester, ds);

      // Default breadcrumb
      expect(find.text('Root'), findsOneWidget);

      // Expand PLC
      await tester.tap(find.text('PLC'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Select Temperature
      await tester.tap(find.text('Temperature'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Breadcrumb should show: Root > PLC > Temperature
      expect(find.text('Root'), findsOneWidget);
      // PLC appears in both the tree and the breadcrumb
      expect(find.text('PLC'), findsAtLeast(1));
      // Temperature appears in both the tree and the breadcrumb
      expect(find.text('Temperature'), findsAtLeast(1));
    });

    testWidgets('Test 9: error from fetchRoots shows error message',
        (tester) async {
      final ds = FailingBrowseDataSource();

      await _showPanel(tester, ds);

      expect(find.textContaining('Connection refused'), findsOneWidget);
    });

    // Additional tests for completeness

    testWidgets('shows server alias in header', (tester) async {
      final ds = FakeBrowseDataSource(roots: []);

      await _showPanel(tester, ds, alias: 'opc.tcp://plc1:4840');

      expect(find.text('Browse'), findsOneWidget);
      expect(find.text('opc.tcp://plc1:4840'), findsOneWidget);
    });

    testWidgets('header close button dismisses dialog', (tester) async {
      final ds = FakeBrowseDataSource(roots: []);

      await _showPanel(tester, ds);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(BrowsePanel), findsNothing);
    });

    testWidgets('Select button is disabled when no variable selected',
        (tester) async {
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder],
      );

      await _showPanel(tester, ds);

      final selectButton = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Select'));
      expect(selectButton.onPressed, isNull);
    });

    testWidgets('shows folder, variable, and method icons', (tester) async {
      const method = BrowseNode(
        id: 'mymethod',
        displayName: 'MyMethod',
        type: BrowseNodeType.method,
      );
      final ds = FakeBrowseDataSource(
        roots: [_plcFolder, _tempVar, method],
      );

      await _showPanel(tester, ds);

      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(
        find.byWidgetPredicate(
            (w) => w is FaIcon && w.icon == FontAwesomeIcons.tag.data),
        findsOneWidget,
      );
    });
  });

  // -----------------------------------------------------------------
  // initialPath — pre-selection of an existing binding.
  //
  // Goal: when an operator re-opens Browse on a key that already has
  // a value bound, the dialog opens with that path SELECTED and the
  // tree EXPANDED so the leaf is visible — no manual re-navigation.
  // -----------------------------------------------------------------
  group('BrowsePanel initialPath', () {
    testWidgets('expands ancestors and selects leaf when chain resolves',
        (tester) async {
      const leaf2 = BrowseNode(
        id: 'Folder.A.Leaf2',
        displayName: 'Leaf2',
        type: BrowseNodeType.variable,
      );
      const leaf1 = BrowseNode(
        id: 'Folder.A.Leaf1',
        displayName: 'Leaf1',
        type: BrowseNodeType.variable,
      );
      const folderA = BrowseNode(
        id: 'Folder.A',
        displayName: 'A',
        type: BrowseNodeType.folder,
      );
      const folderB = BrowseNode(
        id: 'Folder.B',
        displayName: 'B',
        type: BrowseNodeType.folder,
      );
      const rootFolder = BrowseNode(
        id: 'Folder',
        displayName: 'Folder',
        type: BrowseNodeType.folder,
      );
      final ds = FakeBrowseDataSource(
        roots: [rootFolder],
        children: {
          'Folder': [folderA, folderB],
          'Folder.A': [leaf1, leaf2],
        },
        details: {
          'Folder.A.Leaf2': const BrowseNodeDetail(value: '99'),
        },
        resolveChains: {
          'Folder.A.Leaf2': const [rootFolder, folderA, leaf2],
        },
      );

      BrowseNode? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowsePanel(
              dataSource: ds,
              initialPath: 'Folder.A.Leaf2',
              onSelected: (_) {},
              onSelectionChanged: (node) => selection = node,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tree is expanded down to the leaf: Folder, A, and Leaf2 all
      // visible. (Names also appear in the breadcrumb post-selection,
      // so use findsAtLeast(1) for ancestors.)
      expect(find.text('Folder'), findsAtLeast(1));
      expect(find.text('A'), findsAtLeast(1));
      expect(find.text('Leaf2'), findsAtLeast(1));

      // Detail strip shows the leaf's value — confirms a detail fetch
      // was triggered post-resolve.
      expect(find.byType(VariableDetailStrip), findsOneWidget);
      expect(find.text('99'), findsOneWidget);

      // The selection reached the enclosing dialog's callback, which is
      // what enables its Select action.
      expect(selection?.id, 'Folder.A.Leaf2');

      // resolvePath was hit exactly once.
      expect(ds.resolvePathCallCount, 1);
    });

    testWidgets(
        'null initialPath leaves the tree collapsed and nothing selected',
        (tester) async {
      const folderA = BrowseNode(
        id: 'Folder.A',
        displayName: 'A',
        type: BrowseNodeType.folder,
      );
      const rootFolder = BrowseNode(
        id: 'Folder',
        displayName: 'Folder',
        type: BrowseNodeType.folder,
      );
      final ds = FakeBrowseDataSource(
        roots: [rootFolder],
        children: {
          'Folder': [folderA],
        },
      );

      BrowseNode? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowsePanel(
              dataSource: ds,
              onSelected: (_) {},
              onSelectionChanged: (node) => selection = node,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Root visible (the tree row), child folder NOT expanded.
      expect(find.text('Folder'), findsAtLeast(1));
      expect(find.text('A'), findsNothing);

      // No detail strip, no selection.
      expect(find.byType(VariableDetailStrip), findsNothing);
      expect(selection, isNull);

      // resolvePath was NOT called when initialPath is null.
      expect(ds.resolvePathCallCount, 0);
    });

    testWidgets(
        'unresolvable initialPath surfaces a stale-binding hint without '
        'crashing', (tester) async {
      const rootFolder = BrowseNode(
        id: 'Folder',
        displayName: 'Folder',
        type: BrowseNodeType.folder,
      );
      final ds = FakeBrowseDataSource(
        roots: [rootFolder],
        // No resolveChain registered for the requested path → returns null.
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowsePanel(
              dataSource: ds,
              initialPath: 'Nonexistent.Path',
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tree still renders, no crash, no selection.
      expect(find.text('Folder'), findsAtLeast(1));
      expect(find.byType(VariableDetailStrip), findsNothing);

      // Stale-binding hint surfaces the requested id.
      expect(find.textContaining('Nonexistent.Path'), findsOneWidget);

      // resolvePath was called exactly once.
      expect(ds.resolvePathCallCount, 1);
    });
  });

  group('BrowseNode', () {
    test('folder is expandable but not variable', () {
      expect(_plcFolder.isExpandable, true);
      expect(_plcFolder.isVariable, false);
      expect(_plcFolder.isFolder, true);
    });

    test('variable is expandable and is variable', () {
      expect(_tempVar.isExpandable, true);
      expect(_tempVar.isVariable, true);
      expect(_tempVar.isFolder, false);
    });

    test('method is neither expandable nor variable', () {
      const method = BrowseNode(
        id: 'meth',
        displayName: 'Meth',
        type: BrowseNodeType.method,
      );
      expect(method.isExpandable, false);
      expect(method.isVariable, false);
    });
  });

  // -------------------------------------------------------------------------
  // Floating window
  // -------------------------------------------------------------------------

  group('showBrowseDialog as a floating window', () {
    tearDown(closeAllFloatingDialogs);

    /// The future the caller of [showBrowseDialog] would be awaiting, set by
    /// [open].
    ///
    /// Handed over in a variable rather than returned, because an `async`
    /// helper that returned it would await it on the way out — and it does
    /// not complete until the window closes, so every test would deadlock on
    /// its own setup.
    late Future<BrowseNode?> pending;

    /// Pumps a bare host page and opens Browse over it.
    Future<void> open(
      WidgetTester tester,
      BrowseDataSource dataSource, {
      String alias = 'TestServer',
    }) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          }),
        ),
      ));
      pending = showBrowseDialog(
        context: ctx,
        dataSource: dataSource,
        serverAlias: alias,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('opens in the draggable, resizable chrome, not a modal',
        (tester) async {
      await open(tester, FakeBrowseDataSource(roots: [_tempVar]));

      expect(find.byType(ResizableOverlayFrame), findsOneWidget,
          reason: 'this is what makes the window resizable "and all"');
      expect(find.byType(Dialog), findsNothing,
          reason: 'a modal Dialog would put a barrier over the page the '
              'operator wants to keep reading while they browse');
      expect(FloatingDialogs.openIds, ['browse:TestServer']);

      closeAllFloatingDialogs();
      await tester.pumpAndSettle();
      await pending;
    });

    testWidgets('resolves with the picked node', (tester) async {
      await open(
        tester,
        FakeBrowseDataSource(
          roots: [_tempVar],
          details: {'plc.temp': const BrowseNodeDetail(value: '23.5')},
        ),
      );

      await tester.tap(find.text('Temperature'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();

      expect((await pending)?.id, 'plc.temp');
      expect(FloatingDialogs.isEmpty, isTrue);
    });

    testWidgets('resolves null when the operator closes it', (tester) async {
      await open(tester, FakeBrowseDataSource(roots: [_tempVar]));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(await pending, isNull);
    });

    testWidgets('selecting does not re-fetch the tree', (tester) async {
      // The Select action travels on a notifier precisely so picking a node
      // cannot rebuild BrowsePanel. On UMAS a rebuild costs a symbol-cache
      // re-walk per tap; see the umas-fb-freeze-loop note.
      final ds = FakeBrowseDataSource(
        roots: [_tempVar],
        details: {'plc.temp': const BrowseNodeDetail(value: '23.5')},
      );
      await open(tester, ds);
      expect(ds.fetchRootsCallCount, 1);

      await tester.tap(find.text('Temperature'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(ds.fetchRootsCallCount, 1,
          reason: 'the tree must survive the Select button enabling');

      closeAllFloatingDialogs();
      await tester.pumpAndSettle();
      await pending;
    });

    testWidgets('re-opening the same server replaces the window', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          }),
        ),
      ));

      final first = showBrowseDialog(
        context: ctx,
        dataSource: FakeBrowseDataSource(roots: [_tempVar]),
        serverAlias: 'TestServer',
      );
      await tester.pumpAndSettle();

      final second = showBrowseDialog(
        context: ctx,
        dataSource: FakeBrowseDataSource(roots: [_pressVar]),
        serverAlias: 'TestServer',
      );
      await tester.pumpAndSettle();

      expect(await first, isNull,
          reason: 'the superseded requester is told nothing was picked, so '
              'its field is left alone');
      expect(find.byType(BrowsePanel), findsOneWidget,
          reason: 'replaced, not stacked');
      expect(find.text('Pressure'), findsOneWidget,
          reason: 'the window on screen is the NEW one');

      closeAllFloatingDialogs();
      await tester.pumpAndSettle();
      await second;
    });

    testWidgets('two different servers can be browsed side by side',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          }),
        ),
      ));

      final a = showBrowseDialog(
        context: ctx,
        dataSource: FakeBrowseDataSource(roots: [_tempVar]),
        serverAlias: 'ServerA',
      );
      final b = showBrowseDialog(
        context: ctx,
        dataSource: FakeBrowseDataSource(roots: [_pressVar]),
        serverAlias: 'ServerB',
      );
      await tester.pumpAndSettle();

      expect(FloatingDialogs.openIds, ['browse:ServerA', 'browse:ServerB']);
      expect(find.byType(BrowsePanel), findsNWidgets(2));

      closeAllFloatingDialogs();
      await tester.pumpAndSettle();
      expect(await a, isNull);
      expect(await b, isNull);
    });
  });
}
