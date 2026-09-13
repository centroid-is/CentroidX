// The knowledge base's write guards — the fifth bypass class the write-path
// sweep found (`docs/access-control-write-path-sweep.md` §3.1), closed at the
// controls.
//
// Three raw-Drift index classes built for the MCP server are wired into the
// Flutter app through providers, and their write methods are called from app
// code with nothing in front of them. These tests cover the three decorators
// that stand in front of them: eleven writes gated on `configure` and recorded,
// and every read passing straight through with no row at all.
//
// The reads matter as much as the writes here. Four of them feed the PLC detail
// panel through providers that used to type-test for the concrete
// `DriftPlcCodeIndex`, and a decorator that fails those type tests turns the
// panel blank with no error anywhere. `PlcCodeIndexExtras` is what keeps them
// alive, and the "reads pass straight through" group is what says so.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/guarded_knowledge_stores.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// One call a guard made, or did not make, on the index it wraps.
typedef _Call = ({String method, List<Object?> args});

/// Records every [TechDocIndex] member and performs none of them.
///
/// `extends Fake` rather than an in-memory index: the assertion that matters on
/// the deny path is that the inner method was **never reached**, and a fake
/// that answers `noSuchMethod` by throwing makes any unforwarded member fail
/// loudly instead of quietly working.
class _RecordingTechDocs extends Fake implements TechDocIndex {
  final List<_Call> calls = [];

  int nextId = 41;

  static const _searchResult = TechDocSearchResult(
    docId: 3,
    docName: 'ATV320 Installation Manual',
    sectionId: 9,
    sectionTitle: '3.2 Wiring',
    pageStart: 12,
    pageEnd: 14,
    level: 2,
    matchSnippet: 'terminal R1A',
  );

  static const _section = TechDocSection(
    id: 9,
    docId: 3,
    title: '3.2 Wiring',
    content: 'terminal R1A',
    pageStart: 12,
    pageEnd: 14,
    level: 2,
    sortOrder: 4,
  );

  static final _summary = TechDocSummary(
    id: 3,
    name: 'ATV320 Installation Manual',
    pageCount: 300,
    sectionCount: 40,
    uploadedAt: DateTime.utc(2026, 8, 30),
  );

  static const _link = TechDocLink(assetKey: 'CN01', assetTitle: 'Conveyor 1');

  static final _pdf = Uint8List.fromList([37, 80, 68, 70]);

  @override
  Future<List<TechDocSearchResult>> search(String query, {int limit = 20}) async {
    calls.add((method: 'search', args: [query, limit]));
    return const [_searchResult];
  }

  @override
  Future<TechDocSection?> getSection(int sectionId) async {
    calls.add((method: 'getSection', args: [sectionId]));
    return _section;
  }

  @override
  Future<List<TechDocSummary>> getSummary() async {
    calls.add((method: 'getSummary', args: []));
    return [_summary];
  }

  @override
  Future<bool> get isEmpty async {
    calls.add((method: 'isEmpty', args: []));
    return false;
  }

  @override
  Future<Uint8List?> getPdfBytes(int docId) async {
    calls.add((method: 'getPdfBytes', args: [docId]));
    return _pdf;
  }

  @override
  Future<List<TechDocSection>> getSectionsForDoc(int docId) async {
    calls.add((method: 'getSectionsForDoc', args: [docId]));
    return const [_section];
  }

  @override
  Future<List<TechDocLink>> getLinkedAssets(int docId) async {
    calls.add((method: 'getLinkedAssets', args: [docId]));
    return const [_link];
  }

  @override
  Future<int> storeDocument({
    required String name,
    required Uint8List pdfBytes,
    required List<ParsedSection> sections,
    int? pageCount,
  }) async {
    calls.add((
      method: 'storeDocument',
      args: [name, pdfBytes.length, sections.length, pageCount]
    ));
    return nextId;
  }

  @override
  Future<void> updateSections(int docId, List<ParsedSection> sections,
      {int? pageCount}) async {
    calls.add((
      method: 'updateSections',
      args: [docId, sections.length, pageCount]
    ));
  }

  @override
  Future<void> renameDocument(int docId, String newName) async {
    calls.add((method: 'renameDocument', args: [docId, newName]));
  }

  @override
  Future<void> deleteDocument(int docId) async {
    calls.add((method: 'deleteDocument', args: [docId]));
  }

  @override
  Future<void> updatePdfBytes(int docId, Uint8List pdfBytes) async {
    calls.add((method: 'updatePdfBytes', args: [docId, pdfBytes.length]));
  }
}

/// Records every member the app uses on [DriftPlcCodeIndex] — the eight the
/// [PlcCodeIndex] interface declares and the five it does not.
///
/// Typed as the **concrete** class because [GuardedPlcCodeIndex]'s constructor
/// is: the five extras exist only there.
class _RecordingPlcCode extends Fake implements DriftPlcCodeIndex {
  final List<_Call> calls = [];

  int reindexedBlocks = 12;

  static const _searchResult = PlcCodeSearchResult(
    blockId: 5,
    blockName: 'FB_Conveyor',
    blockType: 'FunctionBlock',
    assetKey: 'CN01',
  );

  static final _block = PlcCodeBlock(
    id: 5,
    assetKey: 'CN01',
    blockName: 'FB_Conveyor',
    blockType: 'FunctionBlock',
    filePath: 'POUs/FB_Conveyor.TcPOU',
    declaration: 'VAR_INPUT',
    fullSource: 'VAR_INPUT',
    indexedAt: DateTime.utc(2026, 8, 30),
    variables: const [],
  );

  static final _assetSummary = PlcAssetSummary(
    assetKey: 'CN01',
    blockCount: 12,
    variableCount: 90,
    lastIndexedAt: DateTime.utc(2026, 8, 30),
    blockTypeCounts: const {'FunctionBlock': 12},
  );

  static final varRefs = <PlcVarRefTableData>[];
  static final fbInstances = <PlcFbInstanceTableData>[];
  static final blockCalls = <PlcBlockCallTableData>[];

  @override
  Future<List<PlcCodeSearchResult>> search(
    String query, {
    String mode = 'text',
    String? assetFilter,
    String? serverAlias,
    int limit = 20,
  }) async {
    calls.add((
      method: 'search',
      args: [query, mode, assetFilter, serverAlias, limit]
    ));
    return const [_searchResult];
  }

  @override
  Future<PlcCodeBlock?> getBlock(int blockId) async {
    calls.add((method: 'getBlock', args: [blockId]));
    return _block;
  }

  @override
  Future<List<PlcAssetSummary>> getIndexSummary() async {
    calls.add((method: 'getIndexSummary', args: []));
    return [_assetSummary];
  }

  @override
  bool get isEmpty {
    calls.add((method: 'isEmpty', args: []));
    return false;
  }

  @override
  Future<List<PlcCodeBlock>> getBlocksForAsset(String assetKey) async {
    calls.add((method: 'getBlocksForAsset', args: [assetKey]));
    return [_block];
  }

  @override
  Future<List<PlcVarRefTableData>> getVarRefs(String variablePath) async {
    calls.add((method: 'getVarRefs', args: [variablePath]));
    return varRefs;
  }

  @override
  Future<List<PlcVarRefTableData>> getVarRefsForBlock(int blockId) async {
    calls.add((method: 'getVarRefsForBlock', args: [blockId]));
    return varRefs;
  }

  @override
  Future<List<PlcFbInstanceTableData>> getFbInstances({
    String? fbTypeName,
    String? instanceName,
  }) async {
    calls.add((method: 'getFbInstances', args: [fbTypeName, instanceName]));
    return fbInstances;
  }

  @override
  Future<List<PlcBlockCallTableData>> getBlockCalls(int blockId) async {
    calls.add((method: 'getBlockCalls', args: [blockId]));
    return blockCalls;
  }

  @override
  Future<void> indexAsset(
    String assetKey,
    List<ParsedCodeBlock> blocks, {
    String? vendorType,
    String? serverAlias,
  }) async {
    calls.add((
      method: 'indexAsset',
      args: [assetKey, blocks.length, vendorType, serverAlias]
    ));
  }

  @override
  Future<void> deleteAssetIndex(String assetKey) async {
    calls.add((method: 'deleteAssetIndex', args: [assetKey]));
  }

  @override
  Future<void> renameAsset(String oldAssetKey, String newAssetKey) async {
    calls.add((method: 'renameAsset', args: [oldAssetKey, newAssetKey]));
  }

  @override
  Future<int> reindexAsset(String assetKey) async {
    calls.add((method: 'reindexAsset', args: [assetKey]));
    return reindexedBlocks;
  }
}

/// Records every [DrawingIndex] member and performs none of them.
class _RecordingDrawings extends Fake implements DrawingIndex {
  final List<_Call> calls = [];

  static const _searchResult = DrawingSearchResult(
    drawingName: 'Panel-A Main Wiring',
    pageNumber: 2,
    assetKey: 'panel-A',
    componentName: 'relay K3',
  );

  static final _summary = DrawingSummary(
    drawingName: 'Panel-A Main Wiring',
    assetKey: 'panel-A',
    filePath: '/drawings/panel-a.pdf',
    pageCount: 8,
    uploadedAt: DateTime.utc(2026, 8, 30),
  );

  @override
  Future<List<DrawingSearchResult>> search(String query,
      {String? assetFilter}) async {
    calls.add((method: 'search', args: [query, assetFilter]));
    return const [_searchResult];
  }

  @override
  Future<bool> get isEmpty async {
    calls.add((method: 'isEmpty', args: []));
    return false;
  }

  @override
  Future<List<DrawingSummary>> getDrawingSummary() async {
    calls.add((method: 'getDrawingSummary', args: []));
    return [_summary];
  }

  @override
  Future<void> storeDrawing({
    required String assetKey,
    required String drawingName,
    required String filePath,
    required List<DrawingPageText> pageTexts,
  }) async {
    calls.add((
      method: 'storeDrawing',
      args: [assetKey, drawingName, filePath, pageTexts.length]
    ));
  }

  @override
  Future<void> deleteDrawing(String drawingName) async {
    calls.add((method: 'deleteDrawing', args: [drawingName]));
  }
}


class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A sink that fails the way an unreachable database does — and one whose
/// failure must reach no caller.
class _ThrowingSink implements AuditSink {
  int calls = 0;

  @override
  Future<void> record(AuditRecord entry) async {
    calls++;
    throw StateError('audit sink down');
  }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Nobody signed in, holding the seeded Operator groups. This is the session at
/// the panel on the floor, and the one the sweep found could delete a manual.
final AccessSession _anonymous = AccessSession.anonymous(
  {...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups},
);

AccessSession _signedIn(Set<AccessGroup> groups, {String username = 'jon'}) =>
    AccessSession(
      user: AuthenticatedUser(username: username, roleName: 'Engineer'),
      groups: groups,
    );

final AccessSession _engineer =
    _signedIn({AccessGroup.operate, AccessGroup.configure});

// ---------------------------------------------------------------------------

void main() {
  late _RecordingTechDocs techDocs;
  late _RecordingPlcCode plcCode;
  late _RecordingDrawings drawings;
  late _RecordingSink audit;
  late List<AccessDenied> denials;
  late AccessSession session;

  GuardedTechDocIndex techDocGuard({AuditSink? sink}) => GuardedTechDocIndex(
        inner: techDocs,
        session: () => session,
        audit: sink ?? audit,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  GuardedPlcCodeIndex plcGuard({AuditSink? sink}) => GuardedPlcCodeIndex(
        inner: plcCode,
        session: () => session,
        audit: sink ?? audit,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  GuardedDrawingIndex drawingGuard({AuditSink? sink}) => GuardedDrawingIndex(
        inner: drawings,
        session: () => session,
        audit: sink ?? audit,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );


  setUp(() {
    techDocs = _RecordingTechDocs();
    plcCode = _RecordingPlcCode();
    drawings = _RecordingDrawings();
    audit = _RecordingSink();
    denials = [];
    session = _anonymous;
  });

  // -------------------------------------------------------------------------
  // The group
  // -------------------------------------------------------------------------

  group('kKnowledgeWriteGroup', () {
    test('is configure — the same group the page editor asks for', () {
      expect(kKnowledgeWriteGroup, AccessGroup.configure);
    });

    test('is a group an anonymous panel session does not hold', () {
      expect(_anonymous.can(kKnowledgeWriteGroup), isFalse,
          reason: 'if an anonymous session held it, nothing here is a gate');
    });
  });

  // -------------------------------------------------------------------------
  // Tech docs
  // -------------------------------------------------------------------------

  group('GuardedTechDocIndex refuses an anonymous session', () {
    test('storeDocument', () async {
      final guard = techDocGuard();

      await expectLater(
        guard.storeDocument(
          name: 'ATV320',
          pdfBytes: Uint8List.fromList([1, 2]),
          sections: const [],
        ),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'tech_doc.new')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      expect(techDocs.calls, isEmpty,
          reason: 'the inner index must never be reached on a refusal');
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.groupRequired, 'configure');
      expect(denials, hasLength(1));
    });

    test('updateSections', () async {
      final guard = techDocGuard();

      await expectLater(
        guard.updateSections(3, const []),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'tech_doc.3')),
      );

      expect(techDocs.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });

    test('renameDocument', () async {
      final guard = techDocGuard();

      await expectLater(
        guard.renameDocument(3, 'ATV320 v2'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'tech_doc.3')),
      );

      expect(techDocs.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.newValue, 'ATV320 v2');
      expect(denials, hasLength(1));
    });

    test('deleteDocument — the one the sweep found at the panel', () async {
      final guard = techDocGuard();

      await expectLater(
        guard.deleteDocument(3),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'tech_doc.3')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      expect(techDocs.calls, isEmpty,
          reason: 'an anonymous session must not delete a technical document');
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });

    test('updatePdfBytes', () async {
      final guard = techDocGuard();

      await expectLater(
        guard.updatePdfBytes(3, Uint8List.fromList([1])),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'tech_doc.3')),
      );

      expect(techDocs.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });
  });

  group('GuardedTechDocIndex permits a configure session, and records it', () {
    setUp(() => session = _engineer);

    test('storeDocument passes the arguments through and returns the id',
        () async {
      final guard = techDocGuard();

      final id = await guard.storeDocument(
        name: 'ATV320',
        pdfBytes: Uint8List.fromList([1, 2, 3]),
        sections: const [],
        pageCount: 300,
      );

      expect(id, 41);
      expect(techDocs.calls.single.method, 'storeDocument');
      expect(techDocs.calls.single.args, ['ATV320', 3, 0, 300]);
      expect(audit.rows, hasLength(1));
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.who, 'jon');
      expect(audit.rows.single.itemKey, 'tech_doc.new');
      expect(audit.rows.single.newValue, 'ATV320');
      expect(denials, isEmpty);
    });

    test('updateSections', () async {
      await techDocGuard().updateSections(3, const [], pageCount: 12);

      expect(techDocs.calls.single.method, 'updateSections');
      expect(techDocs.calls.single.args, [3, 0, 12]);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'tech_doc.3');
    });

    test('renameDocument', () async {
      await techDocGuard().renameDocument(3, 'ATV320 v2');

      expect(techDocs.calls.single.method, 'renameDocument');
      expect(techDocs.calls.single.args, [3, 'ATV320 v2']);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.newValue, 'ATV320 v2');
    });

    test('deleteDocument', () async {
      await techDocGuard().deleteDocument(3);

      expect(techDocs.calls.single.method, 'deleteDocument');
      expect(techDocs.calls.single.args, [3]);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'tech_doc.3');
    });

    test('updatePdfBytes', () async {
      await techDocGuard().updatePdfBytes(3, Uint8List.fromList([1, 2]));

      expect(techDocs.calls.single.method, 'updatePdfBytes');
      expect(techDocs.calls.single.args, [3, 2]);
      expect(audit.rows.single.allowed, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // PLC code
  // -------------------------------------------------------------------------

  group('GuardedPlcCodeIndex refuses an anonymous session', () {
    test('indexAsset', () async {
      final guard = plcGuard();

      await expectLater(
        guard.indexAsset('CN01', const []),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'plc_asset.CN01')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      expect(plcCode.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });

    test('deleteAssetIndex — the second thing the panel could destroy',
        () async {
      final guard = plcGuard();

      await expectLater(
        guard.deleteAssetIndex('CN01'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'plc_asset.CN01')),
      );

      expect(plcCode.calls, isEmpty,
          reason: "an anonymous session must not delete an asset's index");
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });

    test('renameAsset', () async {
      final guard = plcGuard();

      await expectLater(
        guard.renameAsset('CN01', 'CN21'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'plc_asset.CN01')),
      );

      expect(plcCode.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.newValue, 'CN21');
      expect(denials, hasLength(1));
    });

    test('reindexAsset — a write however the name reads', () async {
      final guard = plcGuard();

      await expectLater(
        guard.reindexAsset('CN01'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'plc_asset.CN01')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      expect(plcCode.calls, isEmpty,
          reason: 'reindexAsset rewrites the whole indexed source');
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });
  });

  group('GuardedPlcCodeIndex permits a configure session, and records it', () {
    setUp(() => session = _engineer);

    test('indexAsset', () async {
      await plcGuard().indexAsset('CN01', const [],
          vendorType: 'twincat', serverAlias: 'ST101');

      expect(plcCode.calls.single.method, 'indexAsset');
      expect(plcCode.calls.single.args, ['CN01', 0, 'twincat', 'ST101']);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'plc_asset.CN01');
    });

    test('deleteAssetIndex', () async {
      await plcGuard().deleteAssetIndex('CN01');

      expect(plcCode.calls.single.method, 'deleteAssetIndex');
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.who, 'jon');
    });

    test('renameAsset', () async {
      await plcGuard().renameAsset('CN01', 'CN21');

      expect(plcCode.calls.single.args, ['CN01', 'CN21']);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.newValue, 'CN21');
    });

    test('reindexAsset returns the block count the inner index answered',
        () async {
      final count = await plcGuard().reindexAsset('CN01');

      expect(count, 12);
      expect(plcCode.calls.single.method, 'reindexAsset');
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'plc_asset.CN01');
    });
  });

  // -------------------------------------------------------------------------
  // Drawings
  // -------------------------------------------------------------------------

  group('GuardedDrawingIndex refuses an anonymous session', () {
    test('storeDrawing', () async {
      final guard = drawingGuard();

      await expectLater(
        guard.storeDrawing(
          assetKey: 'panel-A',
          drawingName: 'Panel-A Main Wiring',
          filePath: '/tmp/a.pdf',
          pageTexts: const [],
        ),
        throwsA(isA<AccessDenied>().having(
            (d) => d.itemKey, 'itemKey', 'drawing.Panel-A Main Wiring')),
      );

      expect(drawings.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });

    test('deleteDrawing', () async {
      final guard = drawingGuard();

      await expectLater(
        guard.deleteDrawing('Panel-A Main Wiring'),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'drawing.Panel-A Main Wiring')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      expect(drawings.calls, isEmpty);
      expect(audit.rows.single.allowed, isFalse);
      expect(denials, hasLength(1));
    });
  });

  group('GuardedDrawingIndex permits a configure session, and records it', () {
    setUp(() => session = _engineer);

    test('storeDrawing', () async {
      await drawingGuard().storeDrawing(
        assetKey: 'panel-A',
        drawingName: 'Panel-A Main Wiring',
        filePath: '/tmp/a.pdf',
        pageTexts: const [DrawingPageText(pageNumber: 1, fullText: 'K3')],
      );

      expect(drawings.calls.single.method, 'storeDrawing');
      expect(drawings.calls.single.args,
          ['panel-A', 'Panel-A Main Wiring', '/tmp/a.pdf', 1]);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'drawing.Panel-A Main Wiring');
    });

    test('deleteDrawing', () async {
      await drawingGuard().deleteDrawing('Panel-A Main Wiring');

      expect(drawings.calls.single.method, 'deleteDrawing');
      expect(audit.rows.single.allowed, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // The page-layout cleanup a document delete runs
  // -------------------------------------------------------------------------
  //
  // Nothing here any more. `GuardedPrefsReader` wrapped the device-local
  // `page_editor_data` that `deleteAndCleanAssets` rewrote, and milestone v1.2
  // plan 03-05 moved that cleanup onto the shared configuration store — where
  // `GuardedConfigStore` is the guard and the check is the same
  // `page_editor_data` key. The behaviour these tests pinned now lives in
  // `test/providers/knowledge_guard_wiring_test.dart`, against a layout built
  // from real `AssetPage` objects rather than the map-shaped fixture that let
  // D-4 through.

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  group('reads pass straight through', () {
    // Anonymous on purpose: a read must not depend on the session at all.
    test('TechDocIndex.search', () async {
      final r = await techDocGuard().search('R1A', limit: 5);
      expect(r.single.docName, 'ATV320 Installation Manual');
      expect(techDocs.calls.single.args, ['R1A', 5],
          reason: 'the limit reaches the inner index unchanged');
    });

    test('TechDocIndex.getSection', () async {
      expect((await techDocGuard().getSection(9))?.title, '3.2 Wiring');
    });

    test('TechDocIndex.getSummary', () async {
      expect((await techDocGuard().getSummary()).single.id, 3);
    });

    test('TechDocIndex.isEmpty', () async {
      expect(await techDocGuard().isEmpty, isFalse);
    });

    test('TechDocIndex.getPdfBytes', () async {
      expect(await techDocGuard().getPdfBytes(3), _RecordingTechDocs._pdf);
    });

    test('TechDocIndex.getSectionsForDoc', () async {
      expect((await techDocGuard().getSectionsForDoc(3)).single.id, 9);
    });

    test('TechDocIndex.getLinkedAssets', () async {
      expect((await techDocGuard().getLinkedAssets(3)).single.assetKey, 'CN01');
    });

    test('PlcCodeIndex.search', () async {
      final r = await plcGuard().search('pump', mode: 'variable', limit: 3);
      expect(r.single.blockName, 'FB_Conveyor');
      expect(plcCode.calls.single.args, ['pump', 'variable', null, null, 3]);
    });

    test('PlcCodeIndex.getBlock', () async {
      expect((await plcGuard().getBlock(5))?.blockName, 'FB_Conveyor');
    });

    test('PlcCodeIndex.getIndexSummary', () async {
      expect((await plcGuard().getIndexSummary()).single.assetKey, 'CN01');
    });

    test('PlcCodeIndex.isEmpty is a plain bool, not a Future', () {
      final bool empty = plcGuard().isEmpty;
      expect(empty, isFalse);
    });

    test('PlcCodeIndex.getBlocksForAsset', () async {
      expect((await plcGuard().getBlocksForAsset('CN01')).single.id, 5);
    });

    test('PlcCodeIndexExtras.getVarRefsForBlock', () async {
      expect(await plcGuard().getVarRefsForBlock(5),
          same(_RecordingPlcCode.varRefs));
    });

    test('PlcCodeIndexExtras.getFbInstances', () async {
      expect(await plcGuard().getFbInstances(),
          same(_RecordingPlcCode.fbInstances));
    });

    test('PlcCodeIndexExtras.getBlockCalls', () async {
      expect(await plcGuard().getBlockCalls(5),
          same(_RecordingPlcCode.blockCalls));
    });

    test('PlcCodeIndexExtras.getVarRefs', () async {
      expect(await plcGuard().getVarRefs('GVL_Main.speed'),
          same(_RecordingPlcCode.varRefs));
    });

    test('DrawingIndex.search', () async {
      expect((await drawingGuard().search('K3')).single.componentName,
          'relay K3');
    });

    test('DrawingIndex.isEmpty', () async {
      expect(await drawingGuard().isEmpty, isFalse);
    });

    test('DrawingIndex.getDrawingSummary', () async {
      expect((await drawingGuard().getDrawingSummary()).single.pageCount, 8);
    });

    test('and not one of them wrote an audit row', () async {
      final td = techDocGuard();
      final plc = plcGuard();
      final dr = drawingGuard();

      await td.search('R1A');
      await td.getSection(9);
      await td.getSummary();
      await td.isEmpty;
      await td.getPdfBytes(3);
      await td.getSectionsForDoc(3);
      await td.getLinkedAssets(3);
      await plc.search('pump');
      await plc.getBlock(5);
      await plc.getIndexSummary();
      plc.isEmpty;
      await plc.getBlocksForAsset('CN01');
      await plc.getVarRefsForBlock(5);
      await plc.getFbInstances();
      await plc.getBlockCalls(5);
      await plc.getVarRefs('GVL_Main.speed');
      await dr.search('K3');
      await dr.isEmpty;
      await dr.getDrawingSummary();

      expect(audit.rows, isEmpty,
          reason: 'spec §11 defers read permissions; a read leaves no row');
      expect(denials, isEmpty);
      expect(techDocs.calls, hasLength(7));
      expect(plcCode.calls, hasLength(9));
      expect(drawings.calls, hasLength(3));
    });
  });

  // -------------------------------------------------------------------------
  // The shape of a row
  // -------------------------------------------------------------------------

  group('the rows', () {
    test('carry the pref surface by its wire name, not a literal', () async {
      session = _engineer;
      await techDocGuard().deleteDocument(3);
      await plcGuard().deleteAssetIndex('CN01');
      await drawingGuard().deleteDrawing('Panel-A Main Wiring');

      expect(audit.rows.map((r) => r.surface).toSet(),
          {AccessSurface.pref.wireName});
    });

    test('name the method in reason, so a delete row says what happened',
        () async {
      session = _engineer;
      await techDocGuard().deleteDocument(3);
      await plcGuard().reindexAsset('CN01');

      expect(audit.rows.map((r) => r.reason).toList(),
          ['deleteDocument', 'reindexAsset']);
    });

    test('carry the station and the role of the session that made them',
        () async {
      session = _engineer;
      await techDocGuard().deleteDocument(3);

      expect(audit.rows.single.station, 'SVN-NES-OT-CL02');
      expect(audit.rows.single.roleName, 'Engineer');
    });

    test('say "anonymous" when nobody is signed in', () async {
      await expectLater(
          techDocGuard().deleteDocument(3), throwsA(isA<AccessDenied>()));

      expect(audit.rows.single.who, 'anonymous');
    });

    test('carry one fresh actionId per call, never a shared one', () async {
      session = _engineer;
      final guard = techDocGuard();

      await guard.deleteDocument(3);
      await guard.deleteDocument(4);

      expect(audit.rows, hasLength(2));
      expect(audit.rows[0].actionId, isNotEmpty);
      expect(audit.rows[0].actionId, isNot(audit.rows[1].actionId));
    });
  });

  // -------------------------------------------------------------------------
  // The session is re-read, not captured
  // -------------------------------------------------------------------------

  group('the session is a callback, not a value', () {
    test('a guard built while signed in refuses after the session drops',
        () async {
      session = _engineer;
      final guard = techDocGuard();
      await guard.deleteDocument(3);
      expect(techDocs.calls, hasLength(1));

      // The inactivity monitor drops the operator back to anonymous. The same
      // guard object must stop granting.
      session = _anonymous;

      await expectLater(
          guard.deleteDocument(4), throwsA(isA<AccessDenied>()));
      expect(techDocs.calls, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // The sink-failure rule
  // -------------------------------------------------------------------------

  group('a throwing audit sink', () {
    test('neither fails a permitted write nor replaces AccessDenied', () async {
      final sink = _ThrowingSink();

      // Permitted path: the write still happens.
      session = _engineer;
      await techDocGuard(sink: sink).deleteDocument(3);
      expect(techDocs.calls.single.method, 'deleteDocument');

      // Deny path: the caller still sees AccessDenied, and onDenied still fires.
      session = _anonymous;
      await expectLater(
        techDocGuard(sink: sink).deleteDocument(4),
        throwsA(isA<AccessDenied>()),
      );
      expect(denials, hasLength(1));
      expect(sink.calls, 2, reason: 'both paths tried to record');
      expect(techDocs.calls, hasLength(1),
          reason: 'the refused delete never reached the index');
    });

  });

  // -------------------------------------------------------------------------
  // A throwing listener
  // -------------------------------------------------------------------------

  test('an onDenied listener that throws does not replace AccessDenied',
      () async {
    final guard = GuardedDrawingIndex(
      inner: drawings,
      session: () => session,
      audit: audit,
      station: 'SVN-NES-OT-CL02',
      onDenied: (_) => throw StateError('prompt is broken'),
    );

    await expectLater(
      guard.deleteDrawing('Panel-A Main Wiring'),
      throwsA(isA<AccessDenied>()),
    );
    expect(drawings.calls, isEmpty);
    expect(audit.rows.single.allowed, isFalse);
  });

  // -------------------------------------------------------------------------
  // The interface that keeps the four read providers alive
  // -------------------------------------------------------------------------

  group('PlcCodeIndexExtras', () {
    test('the guard is a PlcCodeIndexExtras — this is what the four call-graph '
        'providers type-test for', () {
      expect(plcGuard(), isA<PlcCodeIndexExtras>());
    });

    test('the guard is still a PlcCodeIndex', () {
      expect(plcGuard(), isA<PlcCodeIndex>());
    });

    test('the guard is not a DriftPlcCodeIndex — which is why the type tests '
        'had to move', () {
      expect(plcGuard(), isNot(isA<DriftPlcCodeIndex>()),
          reason: 'a provider returning the guard fails an "is DriftPlcCodeIndex" '
              'test, and four read providers would answer [] forever');
    });

    test('DriftPlcCodeIndex does not implement PlcCodeIndexExtras — Dart is '
        'nominal and the guard is the only implementer', () {
      // The recording fake is typed as the concrete Drift class, so this is
      // the same question asked of the real one.
      expect(plcCode, isNot(isA<PlcCodeIndexExtras>()));
    });
  });

  // -------------------------------------------------------------------------
  // The source itself
  // -------------------------------------------------------------------------

  test('the guards forward every member by hand — no catch-all dispatch', () {
    // A `noSuchMethod` decorator compiles with members missing and answers them
    // by throwing at runtime, on a plant, the first time somebody calls one.
    // Forwarding by hand makes the compiler the check instead, so this asserts
    // nobody quietly bought the shortcut back.
    final source =
        File('lib/core/guarded_knowledge_stores.dart').readAsStringSync();

    expect(source, isNot(contains('noSuchMethod')));
    expect(source, isNot(contains('// ignore:')),
        reason: 'a missing implementation must not be silenced with an ignore');
  });
}
