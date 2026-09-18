import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show TechDocIndex, TechDocSection, TechDocSummary, TechDocSearchResult, TechDocLink, ParsedSection,
         DrawingIndex, DrawingSearchResult, DrawingSummary, DrawingPageText;
import 'package:tfc_mcp_server/src/services/plc_context_service.dart'
    show PlcContext, ResolvedKey, UnresolvedKey;
import 'package:tfc_mcp_server/src/compiler/call_graph_builder.dart'
    show VariableReference, ReferenceKind;

import 'package:tfc/chat/asset_context_menu.dart';
import 'package:tfc/chat/chat_overlay.dart' show ChatContextType;
import 'package:tfc/page_creator/assets/common.dart';

/// Minimal test asset that implements [Asset] with configurable fields.
class _TestAsset extends BaseAsset {
  final String _key;
  final String? _textOverride;
  final String _displayNameOverride;

  _TestAsset({
    String key = '',
    String? text,
    String displayName = 'TestAsset',
    int? techDocIdOverride,
  })  : _key = key,
        _textOverride = text,
        _displayNameOverride = displayName {
    techDocId = techDocIdOverride;
  }

  @override
  String get displayName => _displayNameOverride;

  @override
  String? get text => _textOverride;

  @override
  String get category => 'Test';

  @override
  Widget build(BuildContext context) => const SizedBox();

  @override
  Widget configure(BuildContext context) => const SizedBox();

  @override
  Map<String, dynamic> toJson() => {
        'key': _key.isEmpty ? null : _key,
        'asset_name': 'TestAsset',
      };
}

/// In-memory [TechDocIndex] for testing.
class _FakeTechDocIndex implements TechDocIndex {
  final List<TechDocSummary> _summaries;
  final Map<int, List<TechDocSection>> _sections;
  bool throwOnAccess = false;

  _FakeTechDocIndex({
    List<TechDocSummary>? summaries,
    Map<int, List<TechDocSection>>? sections,
  })  : _summaries = summaries ?? [],
        _sections = sections ?? {};

  @override
  Future<List<TechDocSummary>> getSummary() async {
    if (throwOnAccess) throw Exception('DB error');
    return _summaries;
  }

  @override
  Future<List<TechDocSection>> getSectionsForDoc(int docId) async {
    if (throwOnAccess) throw Exception('DB error');
    return _sections[docId] ?? [];
  }

  // -- Unused stubs below --
  @override
  Future<bool> get isEmpty async => _summaries.isEmpty;
  @override
  Future<List<TechDocSearchResult>> search(String query, {int limit = 20}) async => [];
  @override
  Future<TechDocSection?> getSection(int sectionId) async => null;
  @override
  Future<int> storeDocument({required String name, required Uint8List pdfBytes, required List<ParsedSection> sections, int? pageCount}) async => 0;
  @override
  Future<void> updateSections(int docId, List<ParsedSection> sections, {int? pageCount}) async {}
  @override
  Future<void> renameDocument(int docId, String newName) async {}
  @override
  Future<void> deleteDocument(int docId) async {}
  @override
  Future<Uint8List?> getPdfBytes(int docId) async => null;
  @override
  Future<void> updatePdfBytes(int docId, Uint8List pdfBytes) async {}
  @override
  Future<List<TechDocLink>> getLinkedAssets(int docId) async => [];
}

/// In-memory [DrawingIndex] for testing drawing context integration.
class _FakeDrawingIndex implements DrawingIndex {
  final List<DrawingSearchResult> _results;
  bool throwOnAccess = false;

  _FakeDrawingIndex({List<DrawingSearchResult>? results})
      : _results = results ?? [];

  @override
  Future<List<DrawingSearchResult>> search(String query, {String? assetFilter}) async {
    if (throwOnAccess) throw Exception('DB error');
    return _results
        .where((r) =>
            r.componentName.toLowerCase().contains(query.toLowerCase()) ||
            r.drawingName.toLowerCase().contains(query.toLowerCase()) ||
            r.assetKey.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }

  @override
  Future<bool> get isEmpty async => _results.isEmpty;

  @override
  Future<void> storeDrawing({
    required String assetKey,
    required String drawingName,
    required String filePath,
    required List<DrawingPageText> pageTexts,
  }) async {}

  @override
  Future<void> deleteDrawing(String drawingName) async {}

  @override
  Future<List<DrawingSummary>> getDrawingSummary() async => [];
}

void main() {
  // Resolve the project root directory. Tests run from centroid-hmi/, so
  // source files at lib/ are actually at ../lib/ relative to cwd.
  final cwd = Directory.current.path;
  final projectRoot =
      cwd.endsWith('centroid-hmi') ? Directory.current.parent.path : cwd;

  String projectFile(String relativePath) => '$projectRoot/$relativePath';

  group('Source assertion: useRootNavigator fix', () {
    test('showMenu in asset_context_menu.dart uses useRootNavigator: true', () {
      final source = File(projectFile('lib/chat/asset_context_menu.dart'))
          .readAsStringSync();
      expect(source, contains('useRootNavigator: true'));
    });
  });

  group('extractAssetIdentifier', () {
    test('returns key when present in toJson()', () {
      final asset = _TestAsset(key: 'pump3.speed');
      expect(extractAssetIdentifier(asset), 'pump3.speed');
    });

    test('returns text label when key is empty', () {
      final asset = _TestAsset(key: '', text: 'Pump 3 Speed');
      expect(extractAssetIdentifier(asset), 'Pump 3 Speed');
    });

    test('returns text label when key is null', () {
      final asset = _TestAsset(text: 'Motor Status');
      expect(extractAssetIdentifier(asset), 'Motor Status');
    });

    test('returns displayName when key and text are both null/empty', () {
      final asset = _TestAsset(displayName: 'LED Indicator');
      expect(extractAssetIdentifier(asset), 'LED Indicator');
    });
  });

  group('buildAssetContextBlock', () {
    test('includes type and key', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final block = buildAssetContextBlock(asset);
      expect(block, contains('[ASSET CONTEXT'));
      expect(block, contains('Key: pump3.speed'));
      expect(block, contains('Type: Number'));
      expect(block, contains('[END ASSET CONTEXT]'));
    });

    test('includes label when key is absent', () {
      final asset = _TestAsset(text: 'Motor Label', displayName: 'LED');
      final block = buildAssetContextBlock(asset);
      expect(block, contains('Label: Motor Label'));
    });

    test('tells LLM not to re-fetch', () {
      final asset = _TestAsset(key: 'x');
      final block = buildAssetContextBlock(asset);
      expect(block, contains('do NOT re-fetch'));
    });
  });

  group('buildDebugAssetMessage', () {
    test('contains the asset identifier and context block', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('pump3.speed'));
      expect(message, contains('[ASSET CONTEXT'));
      expect(message, contains('[END ASSET CONTEXT]'));
    });

    test('contains LLM tool instruction keywords for runtime data', () {
      final asset = _TestAsset(key: 'pump3.speed');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('get_tag_value'));
      expect(message, contains('query_alarm_history'));
      expect(message, contains('search_drawings'));
      expect(message, contains('search_plc_code'));
      expect(message, contains('diagnostic summary'));
    });

    test('contains search_tech_docs as knowledge source', () {
      final asset = _TestAsset(key: 'pump3.speed');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('search_tech_docs'));
    });

    test('instructs progressive discovery with get_tech_doc_section', () {
      final asset = _TestAsset(key: 'pump3.speed');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('get_tech_doc_section'));
    });

    test('tells LLM not to re-fetch already provided config', () {
      final asset = _TestAsset(key: 'pump3.speed');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('already provided'));
      expect(message, contains('do NOT re-fetch'));
    });
  });

  group('showAssetContextMenu', () {
    testWidgets('displays popup with "Debug this asset" item', (tester) async {
      bool debugCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                // Trigger the menu display after frame
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  showAssetContextMenu(
                    context,
                    const Offset(100, 100),
                    () => debugCalled = true,
                  );
                });
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      // Let the post-frame callback run and the menu appear
      await tester.pumpAndSettle();

      // Verify the menu item exists
      expect(find.text('Debug this asset'), findsOneWidget);
      expect(find.byIcon(Icons.bug_report), findsOneWidget);

      // Tap the menu item
      await tester.tap(find.text('Debug this asset'));
      await tester.pumpAndSettle();

      expect(debugCalled, isTrue);
    });
  });

  group('buildConfigureAssetPrompt', () {
    test('contains the asset identifier', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final prompt = buildConfigureAssetPrompt(asset);
      expect(prompt, contains('pump3.speed'));
    });

    test('is a short user-friendly prompt without context block', () {
      final asset = _TestAsset(key: 'pump3.speed');
      final prompt = buildConfigureAssetPrompt(asset);
      expect(prompt, isNot(contains('[ASSET CONTEXT')));
      // Should be reasonably short
      expect(prompt.length, lessThan(200));
    });
  });

  group('buildExplainAssetPrompt', () {
    test('contains the asset identifier and type', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final prompt = buildExplainAssetPrompt(asset);
      expect(prompt, contains('pump3.speed'));
      expect(prompt, contains('LED'));
    });

    test('is a short user-friendly prompt without context block', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final prompt = buildExplainAssetPrompt(asset);
      expect(prompt, isNot(contains('[ASSET CONTEXT')));
      expect(prompt.length, lessThan(200));
    });
  });

  group('buildEditorAssetMenuItems', () {
    test('returns two menu items', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final items = buildEditorAssetMenuItems(asset);
      expect(items.length, 2);
    });

    test('first item is Configure with AI without sendImmediately', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final items = buildEditorAssetMenuItems(asset);
      expect(items[0].label, 'Configure with AI');
      expect(items[0].icon, Icons.settings_suggest);
      expect(items[0].sendImmediately, isFalse);
      expect(items[0].prefillText, contains('pump3.speed'));
    });

    test('second item is Explain asset type without sendImmediately', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final items = buildEditorAssetMenuItems(asset);
      expect(items[1].label, 'Explain asset type');
      expect(items[1].icon, Icons.help_outline);
      expect(items[1].sendImmediately, isFalse);
      expect(items[1].prefillText, contains('pump3.speed'));
      expect(items[1].prefillText, contains('LED'));
    });

    test('items have context blocks in contextBlock field (not prefillText)',
        () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final items = buildEditorAssetMenuItems(asset);
      // Context block should be in the contextBlock field, NOT in prefillText
      expect(items[0].prefillText, isNot(contains('[ASSET CONTEXT')));
      expect(items[1].prefillText, isNot(contains('[ASSET CONTEXT')));
      expect(items[0].contextBlock, contains('[ASSET CONTEXT'));
      expect(items[1].contextBlock, contains('[ASSET CONTEXT'));
    });

    test('items have contextLabel and contextType set', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'LED');
      final items = buildEditorAssetMenuItems(asset);
      expect(items[0].contextLabel, 'pump3.speed');
      expect(items[0].contextType, ChatContextType.asset);
      expect(items[1].contextLabel, 'pump3.speed');
      expect(items[1].contextType, ChatContextType.asset);
    });
  });

  group('buildAlarmContextBlock', () {
    test('includes UID, title, description, and rules', () {
      final alarm = AlarmConfig(
        uid: 'abc-123',
        key: 'pump3.speed.high',
        title: 'Pump 3 Over-Speed',
        description: 'Triggers when pump 3 speed exceeds limit',
        rules: [
          AlarmRule(
            level: AlarmLevel.warning,
            expression: ExpressionConfig(
              value: Expression(formula: 'pump3.speed > 50'),
            ),
            acknowledgeRequired: true,
          ),
          AlarmRule(
            level: AlarmLevel.error,
            expression: ExpressionConfig(
              value: Expression(formula: 'pump3.speed > 80'),
            ),
            acknowledgeRequired: true,
            onDelay: const Duration(seconds: 15),
          ),
        ],
      );

      final block = buildAlarmContextBlock(alarm);
      expect(block, contains('[ALARM CONTEXT'));
      expect(block, contains('UID: abc-123'));
      expect(block, contains('Key: pump3.speed.high'));
      expect(block, contains('Title: Pump 3 Over-Speed'));
      expect(block, contains('Description: Triggers when pump 3 speed exceeds limit'));
      expect(block, contains('Rules (2):'));
      expect(block, contains('Level: warning'));
      expect(block, contains('Expression: pump3.speed > 50'));
      expect(block, contains('Level: error'));
      expect(block, contains('Expression: pump3.speed > 80'));
      expect(block, contains('Acknowledge required: true'));
      expect('Active after'.allMatches(block), hasLength(1),
          reason: 'only the delayed rule says so');
      expect(block, contains('Active after: 15.0 s held'));
      expect(block, contains('[END ALARM CONTEXT]'));
    });

    test('tells LLM not to re-fetch', () {
      final alarm = AlarmConfig(
        uid: 'x',
        title: 'Test',
        description: 'Test',
        rules: [],
      );
      final block = buildAlarmContextBlock(alarm);
      expect(block, contains('do NOT re-fetch'));
      expect(block, contains('get_alarm_detail'));
      expect(block, contains('list_alarm_definitions'));
    });

    test('omits key when null', () {
      final alarm = AlarmConfig(
        uid: 'x',
        title: 'Test',
        description: 'Test',
        rules: [],
      );
      final block = buildAlarmContextBlock(alarm);
      expect(block, isNot(contains('Key:')));
    });
  });

  group('debugAsset', () {
    test('debugAsset delegates to AiContextAction.openChat (prefill, not send)', () {
      // debugAsset now delegates to AiContextAction.openChat with a context
      // block (not openChatAndSend). The user sees "Diagnose this asset" in
      // the input field and can edit/add text before manually hitting send.
      // This is tested in ai_context_action_test.dart. Here we verify the
      // function signature is correct and callable.
      expect(debugAsset, isA<Function>());
    });
  });

  group('buildDebugAssetMessageWithTechDoc', () {
    test('falls back to sync version when techDocIndex is null', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 1);
      final message = await buildDebugAssetMessageWithTechDoc(asset, null);
      // Should contain the fallback search_tech_docs instruction
      expect(message, contains('search_tech_docs'));
      expect(message, contains('get_tech_doc_section'));
      expect(message, isNot(contains('[TECHNICAL REFERENCE')));
    });

    test('falls back to sync version when asset has no techDocId', () async {
      final asset = _TestAsset(key: 'pump3.speed');
      final index = _FakeTechDocIndex();
      final message = await buildDebugAssetMessageWithTechDoc(asset, index);
      expect(message, contains('search_tech_docs'));
      expect(message, isNot(contains('[TECHNICAL REFERENCE')));
    });

    test('falls back to sync version when sections are empty', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 42);
      final index = _FakeTechDocIndex(
        summaries: [
          TechDocSummary(id: 42, name: 'Empty Manual', pageCount: 10, sectionCount: 0, uploadedAt: DateTime.now()),
        ],
        sections: {42: []},
      );
      final message = await buildDebugAssetMessageWithTechDoc(asset, index);
      expect(message, contains('search_tech_docs'));
      expect(message, isNot(contains('[TECHNICAL REFERENCE')));
    });

    test('includes tech doc sections when techDocId is set and sections exist', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 7);
      final index = _FakeTechDocIndex(
        summaries: [
          TechDocSummary(id: 7, name: 'ATV320 Installation Manual', pageCount: 100, sectionCount: 3, uploadedAt: DateTime.now()),
        ],
        sections: {
          7: [
            const TechDocSection(id: 1, docId: 7, title: 'Chapter 1: Overview', content: 'This is the overview.', pageStart: 1, pageEnd: 5, level: 1, sortOrder: 0),
            const TechDocSection(id: 2, docId: 7, parentId: 1, title: '1.1 Safety Precautions', content: 'Always disconnect power.', pageStart: 2, pageEnd: 3, level: 2, sortOrder: 1),
            const TechDocSection(id: 3, docId: 7, title: 'Chapter 2: Wiring', content: 'Follow the wiring diagram.', pageStart: 6, pageEnd: 10, level: 1, sortOrder: 2),
          ],
        },
      );
      final message = await buildDebugAssetMessageWithTechDoc(asset, index);

      // Should contain TECHNICAL REFERENCE block
      expect(message, contains('[TECHNICAL REFERENCE'));
      expect(message, contains('[END TECHNICAL REFERENCE]'));
      expect(message, contains('ATV320 Installation Manual'));
      expect(message, contains('Chapter 1: Overview'));
      expect(message, contains('1.1 Safety Precautions'));
      expect(message, contains('Chapter 2: Wiring'));
      expect(message, contains('This is the overview.'));
      expect(message, contains('Always disconnect power.'));
      expect(message, contains('Follow the wiring diagram.'));

      // Should tell LLM NOT to search for tech docs
      expect(message, contains('do NOT call search_tech_docs'));
      expect(message, isNot(contains('search_tech_docs, then get_tech_doc_section')));

      // Should still tell LLM to gather other runtime data
      expect(message, contains('get_tag_value'));
      expect(message, contains('query_alarm_history'));
      expect(message, contains('search_drawings'));
      expect(message, contains('search_plc_code'));
    });

    test('falls back gracefully on DB error', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 7);
      final index = _FakeTechDocIndex()..throwOnAccess = true;
      final message = await buildDebugAssetMessageWithTechDoc(asset, index);
      // Should fall back to sync version
      expect(message, contains('search_tech_docs'));
      expect(message, isNot(contains('[TECHNICAL REFERENCE')));
    });

    test('uses fallback doc name when summary not found for docId', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 99);
      final index = _FakeTechDocIndex(
        summaries: [], // No matching summary for docId=99
        sections: {
          99: [
            const TechDocSection(id: 1, docId: 99, title: 'Section A', content: 'Content A', pageStart: 1, pageEnd: 2, level: 1, sortOrder: 0),
          ],
        },
      );
      final message = await buildDebugAssetMessageWithTechDoc(asset, index);
      expect(message, contains('[TECHNICAL REFERENCE'));
      expect(message, contains('Tech Doc #99'));
    });
  });

  group('buildDebugAssetMessageWithTechDoc - PlcContext integration', () {
    test('includes PLC context section when plcContextService resolves keys', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'TwinCAT_PLC1',
            plcVariablePath: 'GVL_Main.pump3_speed',
            declaringBlock: 'GVL_Main',
            declaringBlockType: 'GVL',
            variableType: 'REAL',
            readers: [
              VariableReference(
                variablePath: 'GVL_Main.pump3_speed',
                kind: ReferenceKind.read,
                blockName: 'FB_PumpControl',
                blockType: 'FunctionBlock',
              ),
            ],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
      );
      expect(message, contains('[PLC CONTEXT'));
      expect(message, contains('pump3.speed'));
      expect(message, contains('GVL_Main.pump3_speed'));
      expect(message, contains('TwinCAT_PLC1'));
      // Should NOT tell LLM to search for PLC code since it's already provided
      expect(message, isNot(contains('search_plc_code')));
    });

    test('omits PLC context section when plcContext is null', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: null,
      );
      expect(message, isNot(contains('[PLC CONTEXT')));
      // Should tell LLM to search PLC code
      expect(message, contains('search_plc_code'));
    });

    test('omits PLC context section when plcContext is empty', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final emptyContext = const PlcContext(resolvedKeys: [], unresolvedKeys: []);
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: emptyContext,
      );
      expect(message, isNot(contains('[PLC CONTEXT')));
      expect(message, contains('search_plc_code'));
    });

    test('includes both PLC context and tech docs when both available', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 7);
      final index = _FakeTechDocIndex(
        summaries: [
          TechDocSummary(id: 7, name: 'Manual', pageCount: 10, sectionCount: 1, uploadedAt: DateTime.now()),
        ],
        sections: {
          7: [
            const TechDocSection(id: 1, docId: 7, title: 'Ch1', content: 'Content', pageStart: 1, pageEnd: 5, level: 1, sortOrder: 0),
          ],
        },
      );
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        index,
        plcContext: plcContext,
      );
      expect(message, contains('[TECHNICAL REFERENCE'));
      expect(message, contains('[PLC CONTEXT'));
      // Neither PLC code nor tech docs should be in the "still need" list
      expect(message, isNot(contains('search_plc_code')));
      expect(message, isNot(contains('search_tech_docs, then get_tech_doc_section')));
    });

    test('includes unresolved keys in PLC context output', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [],
        unresolvedKeys: [
          const UnresolvedKey(
            hmiKey: 'pump3.speed',
            protocol: 'modbus',
            reason: 'Modbus device (no PLC code available)',
          ),
        ],
      );
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
      );
      // Unresolved keys section should appear
      expect(message, contains('[NON-PLC KEYS]'));
      expect(message, contains('Modbus'));
    });

    test('PLC context replaces old PlcCodeIndex-based code section', () async {
      // When plcContext is provided, the old _fetchPlcCodeForAsset path
      // should be superseded and the PLC context section used instead.
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.x',
            variableType: 'BOOL',
            readers: [],
            writers: [
              VariableReference(
                variablePath: 'GVL.x',
                kind: ReferenceKind.write,
                blockName: 'MAIN',
                blockType: 'Program',
              ),
            ],
          ),
        ],
        unresolvedKeys: [],
      );
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
      );
      // Should have PLC CONTEXT block (new style), not PLC CODE block (old style)
      expect(message, contains('[PLC CONTEXT'));
      expect(message, isNot(contains('[PLC CODE -')));
    });
  });

  group('buildAlarmDefinitionsSection', () {
    test('returns empty string when no alarm definitions', () {
      final section = buildAlarmDefinitionsSection([], []);
      expect(section, isEmpty);
    });

    test('formats matching alarm definitions with rules', () {
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'alarm-1',
          'key': 'pump3.speed',
          'title': 'Pump3 Overspeed',
          'description': 'Speed exceeds limit',
          'rules': [
            {'level': 'warning', 'expression': 'pump3.speed > 1500'},
          ],
        },
        {
          'uid': 'alarm-2',
          'key': 'pump3.fault',
          'title': 'Pump3 Fault',
          'description': 'Pump fault detected',
          'rules': [
            {'level': 'error', 'expression': 'pump3.fault = TRUE'},
          ],
        },
      ];
      final section = buildAlarmDefinitionsSection(alarmConfigs, []);
      expect(section, contains('[ALARM CONTEXT'));
      expect(section, contains('Pump3 Overspeed'));
      expect(section, contains('pump3.speed > 1500'));
      expect(section, contains('Pump3 Fault'));
      expect(section, contains('[END ALARM CONTEXT]'));
    });

    test('includes recent alarm history when provided', () {
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'alarm-1',
          'key': 'pump3.speed',
          'title': 'Pump3 Overspeed',
          'description': 'Speed exceeds limit',
          'rules': [],
        },
      ];
      final history = <Map<String, dynamic>>[
        {
          'alarmUid': 'alarm-1',
          'alarmTitle': 'Pump3 Overspeed',
          'alarmLevel': 'warning',
          'active': true,
          'createdAt': '2026-03-15T08:23:15Z',
          'expression': 'pump3.speed > 1500',
        },
        {
          'alarmUid': 'alarm-1',
          'alarmTitle': 'Pump3 Overspeed',
          'alarmLevel': 'warning',
          'active': false,
          'createdAt': '2026-03-15T08:25:02Z',
          'expression': 'pump3.speed > 1500',
        },
      ];
      final section = buildAlarmDefinitionsSection(alarmConfigs, history);
      expect(section, contains('Recent alarm history'));
      expect(section, contains('ACTIVATED'));
      expect(section, contains('DEACTIVATED'));
      expect(section, contains('08:23:15'));
    });

    test('shows no recent triggers for alarms without history', () {
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'alarm-1',
          'key': 'pump3.fault',
          'title': 'Pump3 Fault',
          'description': 'Fault detected',
          'rules': [],
        },
      ];
      final section = buildAlarmDefinitionsSection(alarmConfigs, []);
      expect(section, contains('no recent triggers'));
    });

    test('caps history at 20 entries', () {
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'alarm-1',
          'key': 'pump3.speed',
          'title': 'Pump3 Overspeed',
          'description': 'Speed exceeds limit',
          'rules': [],
        },
      ];
      final history = List.generate(
        30,
        (i) => <String, dynamic>{
          'alarmUid': 'alarm-1',
          'alarmTitle': 'Pump3 Overspeed',
          'alarmLevel': 'warning',
          'active': i.isEven,
          'createdAt': '2026-03-15T08:${i.toString().padLeft(2, "0")}:00Z',
        },
      );
      final section = buildAlarmDefinitionsSection(alarmConfigs, history);
      final activationLines =
          RegExp(r'(ACTIVATED|DEACTIVATED)').allMatches(section).length;
      expect(activationLines, lessThanOrEqualTo(20));
    });

    test('tells LLM not to re-fetch alarm data', () {
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'a1',
          'key': 'x',
          'title': 'Test',
          'description': '',
          'rules': [],
        },
      ];
      final section = buildAlarmDefinitionsSection(alarmConfigs, []);
      expect(section, contains('do NOT'));
      expect(section, contains('query_alarm_history'));
    });
  });

  group('filterAlarmConfigsByKeys', () {
    test('returns empty when no alarm configs match asset keys', () {
      final configs = <Map<String, dynamic>>[
        {'uid': 'a1', 'key': 'motor1.speed', 'title': 'Motor1'},
      ];
      final result = filterAlarmConfigsByKeys(configs, ['pump3.speed']);
      expect(result, isEmpty);
    });

    test('returns matching alarm configs by exact key match', () {
      final configs = <Map<String, dynamic>>[
        {'uid': 'a1', 'key': 'pump3.speed', 'title': 'Pump3 Speed'},
        {'uid': 'a2', 'key': 'motor1.speed', 'title': 'Motor1 Speed'},
      ];
      final result = filterAlarmConfigsByKeys(configs, ['pump3.speed']);
      expect(result.length, 1);
      expect(result.first['uid'], 'a1');
    });

    test('handles alarm configs without key field', () {
      final configs = <Map<String, dynamic>>[
        {'uid': 'a1', 'title': 'No Key Alarm'},
        {'uid': 'a2', 'key': 'pump3.speed', 'title': 'Pump3'},
      ];
      final result = filterAlarmConfigsByKeys(configs, ['pump3.speed']);
      expect(result.length, 1);
      expect(result.first['uid'], 'a2');
    });

    test('matches alarm key as prefix of asset key', () {
      final configs = <Map<String, dynamic>>[
        {'uid': 'a1', 'key': 'pump3', 'title': 'Pump3 Group Alarm'},
      ];
      final result = filterAlarmConfigsByKeys(
        configs,
        ['pump3.speed', 'pump3.fault'],
      );
      expect(result.length, 1);
    });

    test('matches asset key as prefix of alarm key', () {
      final configs = <Map<String, dynamic>>[
        {'uid': 'a1', 'key': 'pump3.speed.high', 'title': 'Speed High'},
      ];
      final result = filterAlarmConfigsByKeys(configs, ['pump3.speed']);
      expect(result.length, 1);
    });
  });

  group('buildDebugAssetMessageWithTechDoc - alarm context', () {
    test('includes alarm section when alarmConfigs are provided', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'alarm-1',
          'key': 'pump3.speed',
          'title': 'Pump3 Overspeed',
          'description': 'Speed exceeds limit',
          'rules': [
            {'level': 'warning', 'expression': 'pump3.speed > 1500'},
          ],
        },
      ];
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        alarmConfigs: alarmConfigs,
      );
      expect(message, contains('[ALARM CONTEXT'));
      expect(message, contains('Pump3 Overspeed'));
      expect(message, contains('[END ALARM CONTEXT]'));
    });

    test('omits alarm section when alarmConfigs is null', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
      );
      expect(message, isNot(contains('[ALARM CONTEXT')));
    });

    test('omits alarm section when alarmConfigs is empty', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        alarmConfigs: [],
      );
      expect(message, isNot(contains('[ALARM CONTEXT')));
    });

    test('removes query_alarm_history from todo when alarms provided', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'a1',
          'key': 'pump3.speed',
          'title': 'Speed Alarm',
          'description': '',
          'rules': [],
        },
      ];
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
        alarmConfigs: alarmConfigs,
      );
      expect(message, isNot(contains('(use query_alarm_history)')));
    });

    test('keeps query_alarm_history in todo when no alarms provided', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
      );
      expect(message, contains('query_alarm_history'));
    });

    test('alarm context listed in already-provided items', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'a1',
          'key': 'pump3.speed',
          'title': 'Speed Alarm',
          'description': '',
          'rules': [],
        },
      ];
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
        alarmConfigs: alarmConfigs,
      );
      expect(message, contains('alarm'));
      expect(message, contains('already provided'));
    });

    test('alarm context combined with all other sections', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 7);
      final index = _FakeTechDocIndex(
        summaries: [
          TechDocSummary(id: 7, name: 'Manual', pageCount: 10, sectionCount: 1, uploadedAt: DateTime.now()),
        ],
        sections: {
          7: [
            const TechDocSection(id: 1, docId: 7, title: 'Ch1', content: 'Content', pageStart: 1, pageEnd: 5, level: 1, sortOrder: 0),
          ],
        },
      );
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final alarmConfigs = <Map<String, dynamic>>[
        {
          'uid': 'a1',
          'key': 'pump3.speed',
          'title': 'Speed High',
          'description': '',
          'rules': [],
        },
      ];
      final alarmHistory = <Map<String, dynamic>>[
        {
          'alarmUid': 'a1',
          'alarmTitle': 'Speed High',
          'alarmLevel': 'warning',
          'active': true,
          'createdAt': '2026-03-15T08:23:15Z',
        },
      ];
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        index,
        plcContext: plcContext,
        alarmConfigs: alarmConfigs,
        alarmHistory: alarmHistory,
      );
      expect(message, contains('[TECHNICAL REFERENCE'));
      expect(message, contains('[PLC CONTEXT'));
      expect(message, contains('[ALARM CONTEXT'));
      expect(message, isNot(contains('(use query_alarm_history)')));
    });
  });

  group('buildDebugAssetMessageWithTechDoc - live tag values', () {
    test('includes LIVE VALUES section when liveValues map is provided', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final liveValues = <String, String>{
        'pump3.speed': '1247.5',
        'pump3.running': 'TRUE',
        'pump3.fault': 'FALSE',
      };
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        liveValues: liveValues,
      );
      expect(message, contains('[LIVE VALUES'));
      expect(message, contains('pump3.speed = 1247.5'));
      expect(message, contains('pump3.running = TRUE'));
      expect(message, contains('pump3.fault = FALSE'));
      expect(message, contains('[END LIVE VALUES]'));
    });

    test('omits get_tag_value from todo list when live values are provided', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final liveValues = <String, String>{
        'pump3.speed': '1247.5',
      };
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        liveValues: liveValues,
      );
      expect(message, isNot(contains('get_tag_value')));
    });

    test('includes get_tag_value in todo list when liveValues is null', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        liveValues: null,
      );
      expect(message, contains('get_tag_value'));
    });

    test('includes get_tag_value in todo list when liveValues is empty', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        liveValues: {},
      );
      expect(message, contains('get_tag_value'));
    });

    test('live values section is listed in already-provided items', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final liveValues = <String, String>{
        'pump3.speed': '1247.5',
      };
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        plcContext: plcContext,
        liveValues: liveValues,
      );
      expect(message, contains('live tag values'));
      expect(message, contains('[LIVE VALUES'));
    });

    test('buildDebugAssetMessage (sync fallback) does NOT include live values', () {
      // The sync fallback version always asks for get_tag_value
      final asset = _TestAsset(key: 'pump3.speed');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('get_tag_value'));
      expect(message, isNot(contains('[LIVE VALUES')));
    });

    test('live values combined with tech docs and PLC context', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 7);
      final index = _FakeTechDocIndex(
        summaries: [
          TechDocSummary(id: 7, name: 'Manual', pageCount: 10, sectionCount: 1, uploadedAt: DateTime.now()),
        ],
        sections: {
          7: [
            const TechDocSection(id: 1, docId: 7, title: 'Ch1', content: 'Content', pageStart: 1, pageEnd: 5, level: 1, sortOrder: 0),
          ],
        },
      );
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final liveValues = <String, String>{
        'pump3.speed': '1247.5',
      };
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        index,
        plcContext: plcContext,
        liveValues: liveValues,
      );
      // All three sections present
      expect(message, contains('[TECHNICAL REFERENCE'));
      expect(message, contains('[PLC CONTEXT'));
      expect(message, contains('[LIVE VALUES'));
      // None of the pre-fetched items in the todo list
      expect(message, isNot(contains('get_tag_value')));
      expect(message, isNot(contains('search_plc_code')));
      expect(message, isNot(contains('search_tech_docs, then get_tech_doc_section')));
    });
  });

  group(r'$variable substitution in allKeys', () {
    test('resolveVariableKeys replaces \$var patterns with substitution values', () {
      final keys = [r'$machine.speed', r'$machine.fault', 'static.key'];
      final substitutions = {'machine': 'Baader9'};
      final resolved = resolveVariableKeys(keys, substitutions);
      expect(resolved, ['Baader9.speed', 'Baader9.fault', 'static.key']);
    });

    test('resolveVariableKeys keeps literal key when substitution not found', () {
      final keys = [r'$unknown.speed', 'static.key'];
      final substitutions = <String, String>{};
      final resolved = resolveVariableKeys(keys, substitutions);
      expect(resolved, [r'$unknown.speed', 'static.key']);
    });

    test('resolveVariableKeys handles multiple variables in one key', () {
      final keys = [r'$prefix.$suffix'];
      final substitutions = {'prefix': 'GVL', 'suffix': 'speed'};
      final resolved = resolveVariableKeys(keys, substitutions);
      expect(resolved, ['GVL.speed']);
    });

    test('resolveVariableKeys returns empty list for empty input', () {
      final resolved = resolveVariableKeys([], {});
      expect(resolved, isEmpty);
    });

    test('resolveVariableKeys does not modify keys without \$ prefix', () {
      final keys = ['pump3.speed', 'pump3.fault'];
      final substitutions = {'pump3': 'Baader9'};
      final resolved = resolveVariableKeys(keys, substitutions);
      expect(resolved, ['pump3.speed', 'pump3.fault']);
    });
  });

  group('bitMask/bitShift in PlcContext output', () {
    test('ResolvedKey includes bitMask and bitShift fields', () {
      final key = ResolvedKey(
        hmiKey: 'pump3.fault',
        serverAlias: 'PLC1',
        plcVariablePath: 'GVL.statusWord',
        variableType: 'WORD',
        bitMask: 4,
        bitShift: 2,
        readers: [],
        writers: [],
      );
      expect(key.bitMask, 4);
      expect(key.bitShift, 2);
    });

    test('formatPlcContext includes bit info annotation for masked keys', () {
      final context = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.fault',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.statusWord',
            variableType: 'WORD',
            bitMask: 4,
            bitShift: 2,
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final output = buildPlcContextSection(context);
      expect(output, contains('pump3.fault'));
      expect(output, contains('GVL.statusWord'));
      expect(output, contains('[bit 2, mask 0x04]'));
    });

    test('formatPlcContext omits bit info when bitMask is null', () {
      final context = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            variableType: 'REAL',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final output = buildPlcContextSection(context);
      expect(output, contains('pump3.speed'));
      expect(output, isNot(contains('[bit')));
      expect(output, isNot(contains('mask')));
    });

    test('formatPlcContext shows multi-bit mask info', () {
      final context = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.mode',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.statusWord',
            variableType: 'WORD',
            bitMask: 0x30,
            bitShift: 4,
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final output = buildPlcContextSection(context);
      expect(output, contains('[bits 4-5, mask 0x30]'));
    });
  });


  // Drawing context tests — now implemented.
  group('buildDrawingContextSection', () {
    test('returns empty string when results list is empty', () {
      final section = buildDrawingContextSection([]);
      expect(section, isEmpty);
    });

    test('formats single drawing result correctly', () {
      final results = [
        const DrawingSearchResult(
          drawingName: 'Main Electrical Panel',
          pageNumber: 12,
          assetKey: 'panel-A',
          componentName: 'pump3 VFD wiring',
        ),
      ];
      final section = buildDrawingContextSection(results);
      expect(section, contains('[ELECTRICAL DRAWINGS'));
      expect(section, contains('Main Electrical Panel'));
      expect(section, contains('page 12'));
      expect(section, contains('pump3 VFD wiring'));
      expect(section, contains('[END ELECTRICAL DRAWINGS]'));
      expect(section, contains('get_drawing_page'));
    });

    test('deduplicates same drawing page across multiple keys', () {
      final results = [
        const DrawingSearchResult(
          drawingName: 'Panel-A Wiring',
          pageNumber: 5,
          assetKey: 'panel-A',
          componentName: 'pump3.speed sensor',
        ),
        const DrawingSearchResult(
          drawingName: 'Panel-A Wiring',
          pageNumber: 5,
          assetKey: 'panel-A',
          componentName: 'pump3.fault relay',
        ),
      ];
      final section = buildDrawingContextSection(results);
      expect(section, contains('pump3.speed sensor'));
      expect(section, contains('pump3.fault relay'));
      final page5Lines = section.split('\n').where((l) => l.contains('page 5')).toList();
      expect(page5Lines.length, 1, reason: 'Same drawing+page should be deduplicated into one line');
    });

    test('caps at 10 drawing references', () {
      final results = List.generate(
        15,
        (i) => DrawingSearchResult(
          drawingName: 'Drawing $i',
          pageNumber: i + 1,
          assetKey: 'asset-$i',
          componentName: 'component $i',
        ),
      );
      final section = buildDrawingContextSection(results);
      final bulletLines = section.split('\n').where((l) => l.trimLeft().startsWith('- ')).toList();
      expect(bulletLines.length, lessThanOrEqualTo(10));
    });

    test('tells LLM not to re-fetch and suggests get_drawing_page', () {
      final results = [
        const DrawingSearchResult(
          drawingName: 'Panel Wiring',
          pageNumber: 1,
          assetKey: 'pump3',
          componentName: 'relay K3',
        ),
      ];
      final section = buildDrawingContextSection(results);
      expect(section, contains('do NOT call search_drawings'));
      expect(section, contains('get_drawing_page'));
    });
  });

  group('fetchDrawingsForAsset', () {
    test('returns empty list when drawingIndex is null', () async {
      final results = await fetchDrawingsForAsset(['pump3.speed'], null);
      expect(results, isEmpty);
    });

    test('returns empty list when keys list is empty', () async {
      final index = _FakeDrawingIndex(results: [
        const DrawingSearchResult(
          drawingName: 'Panel',
          pageNumber: 1,
          assetKey: 'pump3',
          componentName: 'relay',
        ),
      ]);
      final results = await fetchDrawingsForAsset([], index);
      expect(results, isEmpty);
    });

    test('searches for each key and returns combined results', () async {
      final index = _FakeDrawingIndex(results: [
        const DrawingSearchResult(
          drawingName: 'Panel-A Wiring',
          pageNumber: 5,
          assetKey: 'panel-A',
          componentName: 'pump3.speed sensor',
        ),
        const DrawingSearchResult(
          drawingName: 'I/O Cabinet 2',
          pageNumber: 3,
          assetKey: 'cabinet-2',
          componentName: 'pump3.fault relay',
        ),
      ]);
      final results = await fetchDrawingsForAsset(
        ['pump3.speed', 'pump3.fault'],
        index,
      );
      expect(results.length, greaterThanOrEqualTo(1));
    });

    test('handles errors gracefully and returns empty list', () async {
      final index = _FakeDrawingIndex()..throwOnAccess = true;
      final results = await fetchDrawingsForAsset(['pump3.speed'], index);
      expect(results, isEmpty);
    });
  });

  group('buildDebugAssetMessageWithTechDoc - drawing context integration', () {
    test('includes ELECTRICAL DRAWINGS section when drawings are found', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final drawingIndex = _FakeDrawingIndex(results: [
        const DrawingSearchResult(
          drawingName: 'Main Electrical Panel',
          pageNumber: 12,
          assetKey: 'panel-A',
          componentName: 'pump3.speed VFD wiring',
        ),
      ]);
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        drawingIndex: drawingIndex,
      );
      expect(message, contains('[ELECTRICAL DRAWINGS'));
      expect(message, contains('Main Electrical Panel'));
      expect(message, contains('page 12'));
      expect(message, contains('[END ELECTRICAL DRAWINGS]'));
    });

    test('omits ELECTRICAL DRAWINGS section when no matches', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final drawingIndex = _FakeDrawingIndex(results: []);
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        drawingIndex: drawingIndex,
      );
      expect(message, isNot(contains('[ELECTRICAL DRAWINGS')));
    });

    test('omits search_drawings from todo list when drawings are provided', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final drawingIndex = _FakeDrawingIndex(results: [
        const DrawingSearchResult(
          drawingName: 'Panel',
          pageNumber: 1,
          assetKey: 'x',
          componentName: 'pump3.speed',
        ),
      ]);
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        drawingIndex: drawingIndex,
      );
      // The todo list should not contain the search_drawings instruction
      expect(message, isNot(contains('(use search_drawings)')));
    });

    test('includes search_drawings in todo list when drawingIndex is null', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        drawingIndex: null,
      );
      expect(message, contains('search_drawings'));
    });

    test('gracefully handles drawing index errors', () async {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final drawingIndex = _FakeDrawingIndex()..throwOnAccess = true;
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        null,
        drawingIndex: drawingIndex,
      );
      expect(message, isNot(contains('[ELECTRICAL DRAWINGS')));
      expect(message, contains('search_drawings'));
    });

    test('all four context sections can appear together', () async {
      final asset = _TestAsset(key: 'pump3.speed', techDocIdOverride: 7);
      final techDocIndex = _FakeTechDocIndex(
        summaries: [
          TechDocSummary(id: 7, name: 'Manual', pageCount: 10, sectionCount: 1, uploadedAt: DateTime.now()),
        ],
        sections: {
          7: [
            const TechDocSection(id: 1, docId: 7, title: 'Ch1', content: 'Content', pageStart: 1, pageEnd: 5, level: 1, sortOrder: 0),
          ],
        },
      );
      final plcContext = PlcContext(
        resolvedKeys: [
          ResolvedKey(
            hmiKey: 'pump3.speed',
            serverAlias: 'PLC1',
            plcVariablePath: 'GVL.speed',
            readers: [],
            writers: [],
          ),
        ],
        unresolvedKeys: [],
      );
      final drawingIndex = _FakeDrawingIndex(results: [
        const DrawingSearchResult(
          drawingName: 'Panel Wiring',
          pageNumber: 3,
          assetKey: 'pump3',
          componentName: 'pump3.speed VFD',
        ),
      ]);
      final liveValues = <String, String>{'pump3.speed': '1247.5'};
      final message = await buildDebugAssetMessageWithTechDoc(
        asset,
        techDocIndex,
        plcContext: plcContext,
        drawingIndex: drawingIndex,
        liveValues: liveValues,
      );
      expect(message, contains('[TECHNICAL REFERENCE'));
      expect(message, contains('[PLC CONTEXT'));
      expect(message, contains('[ELECTRICAL DRAWINGS'));
      expect(message, contains('[LIVE VALUES'));
      expect(message, isNot(contains('(use search_drawings)')));
      expect(message, isNot(contains('get_tag_value')));
      expect(message, isNot(contains('search_plc_code')));
      expect(message, isNot(contains('search_tech_docs, then get_tech_doc_section')));
      expect(message, contains('electrical drawings'));
    });
  });

  group('extractExpressionTags', () {
    test('returns empty for JSON with no formulas', () {
      final json = <String, dynamic>{
        'key': 'pump3.speed',
        'asset_name': 'NumberConfig',
      };
      expect(extractExpressionTags(json), isEmpty);
    });

    test('extracts tags from a top-level expression formula', () {
      final json = <String, dynamic>{
        'asset_name': 'LEDConfig',
        'expression': {
          'value': {'formula': 'pump3.running == TRUE'},
        },
      };
      final tags = extractExpressionTags(json);
      expect(tags, contains('pump3.running'));
    });

    test('extracts tags from conditional_states expression formulas', () {
      final json = <String, dynamic>{
        'asset_name': 'IconConfig',
        'conditional_states': [
          {
            'expression': {
              'value': {'formula': 'pump3.fault == TRUE'},
            },
          },
          {
            'expression': {
              'value': {'formula': 'pump3.running == TRUE'},
            },
          },
        ],
      };
      final tags = extractExpressionTags(json);
      expect(tags, containsAll(['pump3.fault', 'pump3.running']));
    });

    test('returns empty for conditional_states with empty formulas', () {
      final json = <String, dynamic>{
        'asset_name': 'IconConfig',
        'conditional_states': [
          {
            'expression': {
              'value': {'formula': ''},
            },
          },
        ],
      };
      expect(extractExpressionTags(json), isEmpty);
    });

    test('extracts tags from live Expression objects (real IconConfig.toJson())', () {
      final json = <String, dynamic>{
        'asset_name': 'IconConfig',
        'conditional_states': [
          {
            'expression': {
              'value': Expression(formula: 'pump3.fault == TRUE'),
            },
          },
          {
            'expression': {
              'value': Expression(formula: 'pump3.running == TRUE'),
            },
          },
        ],
      };
      final tags = extractExpressionTags(json);
      expect(tags, containsAll(['pump3.fault', 'pump3.running']));
    });

    test('deduplicates tags across multiple formulas', () {
      final json = <String, dynamic>{
        'conditional_states': [
          {
            'expression': {
              'value': {'formula': 'pump3.running == TRUE'},
            },
          },
          {
            'expression': {
              'value': {'formula': 'pump3.running == FALSE'},
            },
          },
        ],
      };
      final tags = extractExpressionTags(json);
      // pump3.running should appear only once
      expect(tags.where((t) => t == 'pump3.running').length, 1);
    });
  });

  group('buildAssetContextBlock - visual properties', () {
    test('includes coordinates when present', () {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'coordinates': {'x': 0.5, 'y': 0.3},
        },
      );
      final block = buildAssetContextBlock(asset);
      expect(block, contains('Position: x=0.5, y=0.3'));
    });

    test('includes size when present', () {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'size': {'width': 0.04, 'height': 0.04},
        },
      );
      final block = buildAssetContextBlock(asset);
      expect(block, contains('Size: 0.04x0.04'));
    });

    test('includes icon data when present', () {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'iconData': 'e88a',
        },
      );
      final block = buildAssetContextBlock(asset);
      expect(block, contains('Icon: e88a'));
    });

    test('includes conditional states with expression formulas', () {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'conditional_states': [
            {
              'expression': {
                'value': {'formula': 'pump3.fault == TRUE'},
              },
            },
          ],
        },
      );
      final block = buildAssetContextBlock(asset);
      expect(block, contains('Conditional states (1)'));
      expect(block, contains('pump3.fault == TRUE'));
    });

    test('includes conditional states with live Expression objects (real IconConfig.toJson())', () {
      // IconConfig.toJson() produces Expression objects, not nested Maps,
      // because ExpressionConfig is generated without explicitToJson: true.
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'conditional_states': [
            {
              'expression': {
                'value': Expression(formula: 'pump3.fault == TRUE'),
              },
            },
            {
              'expression': {
                'value': Expression(formula: 'pump3.running == TRUE'),
              },
            },
            {
              'expression': {
                'value': Expression(formula: 'pump3.speed > 50'),
              },
            },
          ],
        },
      );
      final block = buildAssetContextBlock(asset);
      expect(block, contains('Conditional states (3)'));
      expect(block, contains('State 1: expression=pump3.fault == TRUE'));
      expect(block, contains('State 2: expression=pump3.running == TRUE'));
      expect(block, contains('State 3: expression=pump3.speed > 50'));
      // Must NOT say "(no expression)" for any state
      expect(block, isNot(contains('(no expression)')));
    });
  });

  group('buildDebugAssetMessage - keyless assets', () {
    test('produces display-only message for keyless asset without expressions', () {
      final asset = _TestKeylessAsset(displayName: 'Arrow');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('display-only'));
      expect(message, contains('no PLC tag mappings'));
      // Should NOT tell the LLM to call any tools
      expect(message, isNot(contains('get_tag_value')));
      expect(message, isNot(contains('query_alarm_history')));
      expect(message, isNot(contains('search_drawings')));
      expect(message, isNot(contains('search_plc_code')));
      expect(message, isNot(contains('search_tech_docs')));
    });

    test('produces expression-aware message for keyless asset WITH expressions', () {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'conditional_states': [
            {
              'expression': {
                'value': {'formula': 'pump3.running == TRUE'},
              },
            },
          ],
        },
      );
      final message = buildDebugAssetMessage(asset);
      // Should mention the expression tags
      expect(message, contains('pump3.running'));
      // Should tell LLM to investigate those tags
      expect(message, contains('get_tag_value'));
      // Should NOT say display-only
      expect(message, isNot(contains('display-only')));
    });

    test('produces expression-aware message for keyless asset with live Expression objects', () {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'conditional_states': [
            {
              'expression': {
                'value': Expression(formula: 'pump3.running == TRUE'),
              },
            },
            {
              'expression': {
                'value': Expression(formula: 'pump3.fault == TRUE'),
              },
            },
          ],
        },
      );
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('pump3.running'));
      expect(message, contains('pump3.fault'));
      expect(message, contains('get_tag_value'));
      expect(message, isNot(contains('display-only')));
    });

    test('still produces full tool list for keyed assets', () {
      final asset = _TestAsset(key: 'pump3.speed', displayName: 'Number');
      final message = buildDebugAssetMessage(asset);
      expect(message, contains('get_tag_value'));
      expect(message, contains('query_alarm_history'));
      expect(message, contains('search_drawings'));
      expect(message, contains('search_plc_code'));
    });
  });

  group('buildDebugAssetMessageWithTechDoc - keyless fallback', () {
    test('falls back to display-only message for keyless asset with no enrichment', () async {
      final asset = _TestKeylessAsset(displayName: 'Arrow');
      final message = await buildDebugAssetMessageWithTechDoc(asset, null);
      expect(message, contains('display-only'));
      expect(message, isNot(contains('get_tag_value')));
    });

    test('falls back to expression-aware message for keyless asset with expressions but no enrichment', () async {
      final asset = _TestKeylessAsset(
        displayName: 'Icon',
        extraJson: {
          'conditional_states': [
            {
              'expression': {
                'value': {'formula': 'pump3.fault == TRUE'},
              },
            },
          ],
        },
      );
      final message = await buildDebugAssetMessageWithTechDoc(asset, null);
      expect(message, contains('pump3.fault'));
      expect(message, contains('get_tag_value'));
    });
  });
}

/// Test asset with no key field and configurable extra JSON properties.
///
/// Simulates keyless assets like IconConfig, ArrowConfig, DrawnBoxConfig.
class _TestKeylessAsset extends BaseAsset {
  final String _displayNameOverride;
  final String? _textOverride;
  final Map<String, dynamic> _extraJson;

  _TestKeylessAsset({
    String displayName = 'TestKeyless',
    String? text,
    Map<String, dynamic>? extraJson,
  })  : _displayNameOverride = displayName,
        _textOverride = text,
        _extraJson = extraJson ?? {};

  @override
  String get displayName => _displayNameOverride;

  @override
  String? get text => _textOverride;

  @override
  String get category => 'Test';

  @override
  Widget build(BuildContext context) => const SizedBox();

  @override
  Widget configure(BuildContext context) => const SizedBox();

  @override
  Map<String, dynamic> toJson() => {
        'asset_name': assetName,
        ..._extraJson,
      };
}
