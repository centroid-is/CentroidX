// ---------------------------------------------------------------------------
// TDD tests for PLC server alias linking in PlcCodeService.
//
// Validates that:
// - Upload with serverAlias stores it in DB records
// - Search by key uses serverAlias to narrow key mapping lookups
// - Null serverAlias still works (backwards compatibility)
// - serverAlias persists across getBlock, getIndexSummary, search calls
// - Multiple assets with different serverAliases coexist correctly
// - Two PLCs with same variable: search scoped by serverAlias returns correct one
// - Keys with no PLC code (Modbus, M2400, numeric OPC-UA): return empty, no error
// - ConfigService includes server_alias for OPC-UA entries
// ---------------------------------------------------------------------------

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/interfaces/plc_code_index.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import 'package:tfc_mcp_server/src/services/drift_plc_code_index.dart';
import 'package:tfc_mcp_server/src/services/plc_code_service.dart';

import '../helpers/config_rows.dart';
import '../helpers/mock_plc_code_index.dart';
import '../helpers/sample_twincat_files.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a zip archive from a list of {path, content} entries.
Uint8List _buildZip(List<Map<String, String>> files) {
  final archive = Archive();
  for (final file in files) {
    final bytes = utf8.encode(file['content']!);
    archive.addFile(ArchiveFile.bytes(file['path']!, bytes));
  }
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

/// Stub [KeyMappingLookup] that returns canned mappings, optionally
/// filtered by serverAlias to simulate production behavior.
///
/// In the production system, key mappings belong to a server alias
/// (a StateMan OPC UA server). When serverAlias is set on PLC code,
/// the search should be scoped to key mappings from the same server.
class _ServerAwareKeyMappingLookup implements KeyMappingLookup {
  _ServerAwareKeyMappingLookup(this._mappings);

  final List<Map<String, dynamic>> _mappings;

  @override
  Future<List<Map<String, dynamic>>> listKeyMappings({
    String? filter,
    int limit = 50,
  }) async {
    var results = _mappings;
    if (filter != null && filter.isNotEmpty) {
      final q = filter.toLowerCase();
      results = results
          .where((m) => (m['key'] as String).toLowerCase().contains(q))
          .toList();
    }
    return results.take(limit).toList();
  }
}

/// Extend [MockPlcCodeIndex] to record every serverAlias per asset.
class _TrackingPlcCodeIndex extends MockPlcCodeIndex {
  final Map<String, String?> serverAliasByAsset = {};

  @override
  Future<void> indexAsset(
    String assetKey,
    List<ParsedCodeBlock> blocks, {
    String? vendorType,
    String? serverAlias,
  }) async {
    serverAliasByAsset[assetKey] = serverAlias;
    await super.indexAsset(
      assetKey,
      blocks,
      vendorType: vendorType,
      serverAlias: serverAlias,
    );
  }
}

void main() {
  // =========================================================================
  // Group 1: serverAlias storage with in-memory mock index
  // =========================================================================

  group('server alias - storage via MockPlcCodeIndex', () {
    late _TrackingPlcCodeIndex index;
    late _ServerAwareKeyMappingLookup keyLookup;
    late PlcCodeService service;

    setUp(() {
      index = _TrackingPlcCodeIndex();
      keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);
    });

    test('upload with serverAlias stores it in DB', () async {
      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload(
        'pump-station-1',
        zip,
        serverAlias: 'PLC_ATV320',
      );

      expect(index.serverAliasByAsset['pump-station-1'], equals('PLC_ATV320'));
    });

    test('null serverAlias still works (backwards compat)', () async {
      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload('pump-station-2', zip);

      expect(index.serverAliasByAsset['pump-station-2'], isNull);

      // Index should still have the data
      expect(index.isEmpty, isFalse);
      final summary = await index.getIndexSummary();
      expect(summary, hasLength(1));
      expect(summary.first.assetKey, equals('pump-station-2'));
    });

    test('multiple assets with different serverAliases coexist', () async {
      final zip1 = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);
      final zip2 = _buildZip([
        {'path': 'POUs/FB_TestBlock.TcPOU', 'content': sampleTcPouXml},
      ]);

      await service.processUpload(
        'asset-a',
        zip1,
        serverAlias: 'PLC_SERVER_A',
      );
      await service.processUpload(
        'asset-b',
        zip2,
        serverAlias: 'PLC_SERVER_B',
      );

      expect(index.serverAliasByAsset['asset-a'], equals('PLC_SERVER_A'));
      expect(index.serverAliasByAsset['asset-b'], equals('PLC_SERVER_B'));

      final summary = await index.getIndexSummary();
      expect(summary, hasLength(2));
    });

    test('re-upload same asset with different alias replaces previous',
        () async {
      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload(
        'asset-reup',
        zip,
        serverAlias: 'OLD_ALIAS',
      );
      expect(index.serverAliasByAsset['asset-reup'], equals('OLD_ALIAS'));

      await service.processUpload(
        'asset-reup',
        zip,
        serverAlias: 'NEW_ALIAS',
      );
      expect(index.serverAliasByAsset['asset-reup'], equals('NEW_ALIAS'));

      // Only one asset entry, not two
      final summary = await index.getIndexSummary();
      expect(summary, hasLength(1));
    });

    test('getBlock returns stored serverAlias', () async {
      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload(
        'asset-getblock',
        zip,
        serverAlias: 'MY_SERVER',
      );

      final block = await service.getBlock(1);
      expect(block, isNotNull);
      expect(block!.serverAlias, equals('MY_SERVER'));
    });

    test('getBlock returns null serverAlias when not set', () async {
      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload('asset-no-alias', zip);

      final block = await service.getBlock(1);
      expect(block, isNotNull);
      expect(block!.serverAlias, isNull);
    });
  });

  // =========================================================================
  // Group 2: serverAlias and key mapping correlation
  // =========================================================================

  group('server alias - key mapping correlation', () {
    late _TrackingPlcCodeIndex index;
    late PlcCodeService service;

    test('searchByKey finds variable when key mapping exists', () async {
      index = _TrackingPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'pump3.speed',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.pump3_speed',
          'serverAlias': 'PLC_ATV320',
        },
      ]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);
      await service.processUpload(
        'pump-station',
        zip,
        serverAlias: 'PLC_ATV320',
      );

      final results = await service.searchByKey('pump3.speed');
      expect(results, isNotEmpty);
      expect(results.any((r) => r.variableName == 'pump3_speed'), isTrue);
    });

    test(
        'searchByKey returns results even with null serverAlias (backwards compat)',
        () async {
      index = _TrackingPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'pump3.speed',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.pump3_speed',
        },
      ]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);
      // No serverAlias -- backwards compatibility
      await service.processUpload('pump-station', zip);

      final results = await service.searchByKey('pump3.speed');
      expect(results, isNotEmpty);
      expect(results.any((r) => r.variableName == 'pump3_speed'), isTrue);
    });

    test('search still works across assets with different serverAliases',
        () async {
      index = _TrackingPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip1 = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);
      final zip2 = _buildZip([
        {'path': 'POUs/FB_TestBlock.TcPOU', 'content': sampleTcPouXml},
      ]);

      await service.processUpload(
        'station-a',
        zip1,
        serverAlias: 'SERVER_A',
      );
      await service.processUpload(
        'station-b',
        zip2,
        serverAlias: 'SERVER_B',
      );

      // Variable search across all assets
      final results = await service.search('pump3', mode: 'variable');
      expect(results, isNotEmpty);

      // Text search across all assets
      final textResults = await service.search('speed', mode: 'text');
      expect(textResults, isNotEmpty);
    });

    test('search with assetFilter narrows to one serverAlias context',
        () async {
      index = _TrackingPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip1 = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);
      final zip2 = _buildZip([
        {'path': 'POUs/FB_TestBlock.TcPOU', 'content': sampleTcPouXml},
      ]);

      await service.processUpload(
        'station-a',
        zip1,
        serverAlias: 'SERVER_A',
      );
      await service.processUpload(
        'station-b',
        zip2,
        serverAlias: 'SERVER_B',
      );

      // Filter to station-a only
      final results = await service.search(
        'speed',
        mode: 'text',
        assetFilter: 'station-a',
      );
      expect(results, isNotEmpty);
      for (final r in results) {
        expect(r.assetKey, equals('station-a'));
      }
    });
  });

  // =========================================================================
  // Group 3: serverAlias with Drift DB (integration-level)
  // =========================================================================

  group('server alias - DriftPlcCodeIndex integration', () {
    late ServerDatabase db;
    late DriftPlcCodeIndex index;
    late PlcCodeService service;

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');
      index = DriftPlcCodeIndex(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('indexAsset stores serverAlias in database', () async {
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload(
        'db-asset',
        zip,
        serverAlias: 'DB_SERVER',
      );

      // Retrieve via getBlock and verify serverAlias
      final results = await index.search('pump3_speed', mode: 'variable');
      expect(results, isNotEmpty);

      final block = await index.getBlock(results.first.blockId);
      expect(block, isNotNull);
      expect(block!.serverAlias, equals('DB_SERVER'));
    });

    test('indexAsset stores null serverAlias when not provided', () async {
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload('db-asset-null', zip);

      final results = await index.search('pump3_speed', mode: 'variable');
      expect(results, isNotEmpty);

      final block = await index.getBlock(results.first.blockId);
      expect(block, isNotNull);
      expect(block!.serverAlias, isNull);
    });

    test('indexAsset stores vendorType in database', () async {
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload(
        'db-asset-vt',
        zip,
        vendor: PlcVendor.twincat,
        serverAlias: 'VENDOR_TEST',
      );

      final results = await index.search('pump3_speed', mode: 'variable');
      expect(results, isNotEmpty);

      final block = await index.getBlock(results.first.blockId);
      expect(block, isNotNull);
      expect(block!.vendorType, equals('twincat'));
      expect(block.serverAlias, equals('VENDOR_TEST'));
    });

    test('deleteAssetIndex removes serverAlias-tagged blocks', () async {
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      await service.processUpload(
        'db-delete',
        zip,
        serverAlias: 'TO_DELETE',
      );
      expect(index.isEmpty, isFalse);

      await index.deleteAssetIndex('db-delete');
      expect(index.isEmpty, isTrue);

      final results = await index.search('pump3_speed', mode: 'variable');
      expect(results, isEmpty);
    });

    test('multiple assets with different serverAliases in database', () async {
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip1 = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);
      final zip2 = _buildZip([
        {'path': 'POUs/FB_TestBlock.TcPOU', 'content': sampleTcPouXml},
      ]);

      await service.processUpload(
        'db-asset-a',
        zip1,
        serverAlias: 'SERVER_ALPHA',
      );
      await service.processUpload(
        'db-asset-b',
        zip2,
        serverAlias: 'SERVER_BETA',
      );

      final summary = await index.getIndexSummary();
      expect(summary, hasLength(2));

      // Verify each asset's blocks have the correct serverAlias
      final searchA = await index.search(
        'pump3_speed',
        mode: 'variable',
        assetFilter: 'db-asset-a',
      );
      expect(searchA, isNotEmpty);
      final blockA = await index.getBlock(searchA.first.blockId);
      expect(blockA!.serverAlias, equals('SERVER_ALPHA'));

      final searchB = await index.search(
        'bStartTest',
        mode: 'variable',
        assetFilter: 'db-asset-b',
      );
      expect(searchB, isNotEmpty);
      final blockB = await index.getBlock(searchB.first.blockId);
      expect(blockB!.serverAlias, equals('SERVER_BETA'));
    });

    test('re-indexing same asset replaces serverAlias in database', () async {
      final keyLookup = _ServerAwareKeyMappingLookup([]);
      service = PlcCodeService(index, keyLookup);

      final zip = _buildZip([
        {'path': 'GVLs/GVL_Main.TcGVL', 'content': sampleTcGvlXml},
      ]);

      // First upload with alias A
      await service.processUpload(
        'db-replace',
        zip,
        serverAlias: 'ALIAS_A',
      );

      var results = await index.search('pump3_speed', mode: 'variable');
      var block = await index.getBlock(results.first.blockId);
      expect(block!.serverAlias, equals('ALIAS_A'));

      // Re-upload with alias B
      await service.processUpload(
        'db-replace',
        zip,
        serverAlias: 'ALIAS_B',
      );

      results = await index.search('pump3_speed', mode: 'variable');
      block = await index.getBlock(results.first.blockId);
      expect(block!.serverAlias, equals('ALIAS_B'));

      // Only one asset in summary
      final summary = await index.getIndexSummary();
      expect(summary, hasLength(1));
    });
  });

  // =========================================================================
  // Group 4: OPC UA identifier extraction (serverAlias context)
  // =========================================================================

  group('server alias - extractPlcVariablePath', () {
    test('extracts variable path from s= identifier', () {
      final path =
          PlcCodeService.extractPlcVariablePath('ns=4;s=GVL_Main.pump3_speed');
      expect(path, equals('GVL_Main.pump3_speed'));
    });

    test('extracts variable path from s= without namespace prefix', () {
      final path =
          PlcCodeService.extractPlcVariablePath('s=GVL_Main.pump3_speed');
      expect(path, equals('GVL_Main.pump3_speed'));
    });

    test('returns null for numeric identifier', () {
      final path = PlcCodeService.extractPlcVariablePath('ns=2;i=847');
      expect(path, isNull);
    });

    test('handles complex namespace path with dots', () {
      final path = PlcCodeService.extractPlcVariablePath(
          'ns=4;s=Application.GVL_Process.pump3_speed');
      expect(path, equals('Application.GVL_Process.pump3_speed'));
    });
  });

  // =========================================================================
  // Group 5: getCorrelatedKeys with serverAlias context
  // =========================================================================

  group('server alias - getCorrelatedKeys', () {
    test('finds correlated keys regardless of serverAlias', () async {
      final index = _TrackingPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'pump3.speed',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.pump3_speed',
          'serverAlias': 'PLC_SERVER_1',
        },
        {
          'key': 'tank.level',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.tank_level',
          'serverAlias': 'PLC_SERVER_1',
        },
        {
          'key': 'other.tag',
          'namespace': 4,
          'identifier': 'ns=4;s=FB_Other.value',
          'serverAlias': 'PLC_SERVER_2',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final keys = await service.getCorrelatedKeys('GVL_Main.pump3_speed');
      expect(keys, hasLength(1));
      expect(keys.first['key'], equals('pump3.speed'));
      expect(keys.first['serverAlias'], equals('PLC_SERVER_1'));
    });

    test('returns empty when no keys match variable path', () async {
      final index = _TrackingPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'pump3.speed',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.pump3_speed',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final keys = await service.getCorrelatedKeys('FB_Unknown.someVar');
      expect(keys, isEmpty);
    });
  });

  // =========================================================================
  // Group 6: Server alias scoping in search — two PLCs with same variable
  // =========================================================================

  group('server alias - search scoping by server alias', () {
    test(
        'two PLCs with same variable name, search scoped by serverAlias returns only correct one',
        () async {
      final index = MockPlcCodeIndex();

      // Both PLCs have GVL_Main with pump3_speed
      await index.indexAsset(
          'plc-alpha',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_ALPHA');

      await index.indexAsset(
          'plc-beta',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_BETA');

      // Search without serverAlias returns both
      final allResults = await index.search(
        'pump3_speed',
        mode: 'variable',
      );
      expect(allResults, hasLength(2));

      // Search scoped to PLC_ALPHA returns only plc-alpha
      final alphaResults = await index.search(
        'pump3_speed',
        mode: 'variable',
        serverAlias: 'PLC_ALPHA',
      );
      expect(alphaResults, hasLength(1));
      expect(alphaResults.first.assetKey, equals('plc-alpha'));

      // Search scoped to PLC_BETA returns only plc-beta
      final betaResults = await index.search(
        'pump3_speed',
        mode: 'variable',
        serverAlias: 'PLC_BETA',
      );
      expect(betaResults, hasLength(1));
      expect(betaResults.first.assetKey, equals('plc-beta'));
    });

    test('key mode search scoped by serverAlias returns correct PLC', () async {
      final index = MockPlcCodeIndex();

      // Both PLCs have same variable qualified name
      await index.indexAsset(
          'plc-1',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'SERVER_1');

      await index.indexAsset(
          'plc-2',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'SERVER_2');

      // Key mode search scoped to SERVER_1
      final results = await index.search(
        'GVL_Main.pump3_speed',
        mode: 'key',
        serverAlias: 'SERVER_1',
      );
      expect(results, hasLength(1));
      expect(results.first.assetKey, equals('plc-1'));
    });

    test('text mode search scoped by serverAlias', () async {
      final index = MockPlcCodeIndex();

      await index.indexAsset(
          'plc-a',
          [
            const ParsedCodeBlock(
              name: 'FB_Pump',
              type: 'FunctionBlock',
              declaration: 'VAR\n  speed : REAL;\nEND_VAR',
              implementation: 'speed := 100.0;',
              fullSource: 'VAR\n  speed : REAL;\nEND_VAR\nspeed := 100.0;',
              filePath: 'POUs/FB_Pump.TcPOU',
              variables: [
                ParsedVariable(name: 'speed', type: 'REAL', section: 'VAR'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'SRV_A');

      await index.indexAsset(
          'plc-b',
          [
            const ParsedCodeBlock(
              name: 'FB_Pump',
              type: 'FunctionBlock',
              declaration: 'VAR\n  speed : REAL;\nEND_VAR',
              implementation: 'speed := 200.0;',
              fullSource: 'VAR\n  speed : REAL;\nEND_VAR\nspeed := 200.0;',
              filePath: 'POUs/FB_Pump.TcPOU',
              variables: [
                ParsedVariable(name: 'speed', type: 'REAL', section: 'VAR'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'SRV_B');

      final results = await index.search(
        'speed',
        mode: 'text',
        serverAlias: 'SRV_A',
      );
      expect(results, hasLength(1));
      expect(results.first.assetKey, equals('plc-a'));
    });

    test('null serverAlias filter returns all results (backwards compat)',
        () async {
      final index = MockPlcCodeIndex();

      await index.indexAsset(
          'plc-1',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_1');

      await index.indexAsset(
          'plc-2',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_2');

      // null serverAlias = no scoping
      final results = await index.search('speed', mode: 'variable');
      expect(results, hasLength(2));
    });
  });

  // =========================================================================
  // Group 7: searchByKey with server alias scoping
  // =========================================================================

  group('server alias - searchByKey scoped by server_alias from key mapping',
      () {
    test('searchByKey uses server_alias from key mapping to scope search',
        () async {
      final index = MockPlcCodeIndex();

      // Two PLCs, same variable GVL_Main.pump3_speed
      await index.indexAsset(
          'plc-1',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_SERVER_1');

      await index.indexAsset(
          'plc-2',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_SERVER_2');

      // Key mapping has server_alias pointing to PLC_SERVER_1
      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'pump3.speed',
          'protocol': 'opcua',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.pump3_speed',
          'server_alias': 'PLC_SERVER_1',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final results = await service.searchByKey('pump3.speed');
      // Should return only PLC_SERVER_1 result, not PLC_SERVER_2
      expect(results, hasLength(1));
      expect(results.first.assetKey, equals('plc-1'));
    });

    test('searchByKey with no server_alias in mapping returns all matches',
        () async {
      final index = MockPlcCodeIndex();

      await index.indexAsset(
          'plc-1',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_SERVER_1');

      await index.indexAsset(
          'plc-2',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  pump3_speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'pump3_speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'PLC_SERVER_2');

      // Key mapping has NO server_alias
      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'pump3.speed',
          'protocol': 'opcua',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.pump3_speed',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final results = await service.searchByKey('pump3.speed');
      // No server_alias filter => returns both
      expect(results, hasLength(2));
    });
  });

  // =========================================================================
  // Group 8: Missing PLC code — graceful handling
  // =========================================================================

  group('server alias - missing PLC code graceful handling', () {
    test('Modbus key with no PLC code returns empty, no error', () async {
      final index = MockPlcCodeIndex();
      // No PLC code indexed at all

      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'modbus.sensor1',
          'protocol': 'modbus',
          'register_type': 'holdingRegister',
          'address': 100,
          'data_type': 'int16',
          'server_alias': 'MODBUS_GATEWAY',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      // searchByKey for a Modbus key — no identifier field
      final results = await service.searchByKey('modbus.sensor1');
      expect(results, isEmpty);
    });

    test('M2400 key with no PLC code returns empty, no error', () async {
      final index = MockPlcCodeIndex();

      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'weigh.belt1',
          'protocol': 'm2400',
          'record_type': 'FLOW',
          'field': 'rate',
          'server_alias': 'M2400_WEIGH',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final results = await service.searchByKey('weigh.belt1');
      expect(results, isEmpty);
    });

    test('OPC-UA key with numeric identifier returns empty, no error',
        () async {
      final index = MockPlcCodeIndex();

      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'numeric.tag',
          'protocol': 'opcua',
          'namespace': 2,
          'identifier': 'ns=2;i=847',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final results = await service.searchByKey('numeric.tag');
      expect(results, isEmpty);
    });

    test(
        'OPC-UA key with valid identifier but no indexed PLC code returns empty',
        () async {
      final index = MockPlcCodeIndex();
      // No PLC code indexed

      final keyLookup = _ServerAwareKeyMappingLookup([
        {
          'key': 'plc.tag',
          'protocol': 'opcua',
          'namespace': 4,
          'identifier': 'ns=4;s=GVL_Main.some_var',
          'server_alias': 'PLC_NOT_UPLOADED',
        },
      ]);
      final service = PlcCodeService(index, keyLookup);

      final results = await service.searchByKey('plc.tag');
      expect(results, isEmpty);
    });

    test('key with no mappings at all returns empty', () async {
      final index = MockPlcCodeIndex();
      final keyLookup = _ServerAwareKeyMappingLookup([]); // empty
      final service = PlcCodeService(index, keyLookup);

      final results = await service.searchByKey('nonexistent.key');
      expect(results, isEmpty);
    });
  });

  // =========================================================================
  // Group 9: DriftPlcCodeIndex - serverAlias filter in search
  // =========================================================================

  group('server alias - DriftPlcCodeIndex search with serverAlias filter', () {
    late ServerDatabase db;
    late DriftPlcCodeIndex index;

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');
      index = DriftPlcCodeIndex(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('search with serverAlias filter narrows results in DB', () async {
      // Index same variable under two different server aliases
      await index.indexAsset(
          'plc-alpha',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'ALPHA');

      await index.indexAsset(
          'plc-beta',
          [
            const ParsedCodeBlock(
              name: 'GVL_Main',
              type: 'GVL',
              declaration: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              implementation: null,
              fullSource: 'VAR_GLOBAL\n  speed : REAL;\nEND_VAR',
              filePath: 'GVLs/GVL_Main.TcGVL',
              variables: [
                ParsedVariable(
                    name: 'speed', type: 'REAL', section: 'VAR_GLOBAL'),
              ],
              children: [],
            ),
          ],
          serverAlias: 'BETA');

      // Without serverAlias filter
      final allResults = await index.search('speed', mode: 'variable');
      expect(allResults, hasLength(2));

      // With serverAlias filter
      final alphaResults = await index.search(
        'speed',
        mode: 'variable',
        serverAlias: 'ALPHA',
      );
      expect(alphaResults, hasLength(1));
      expect(alphaResults.first.assetKey, equals('plc-alpha'));

      // Key mode with serverAlias filter
      final keyResults = await index.search(
        'GVL_Main.speed',
        mode: 'key',
        serverAlias: 'BETA',
      );
      expect(keyResults, hasLength(1));
      expect(keyResults.first.assetKey, equals('plc-beta'));

      // Text mode with serverAlias filter
      final textResults = await index.search(
        'speed',
        mode: 'text',
        serverAlias: 'ALPHA',
      );
      expect(textResults, hasLength(1));
      expect(textResults.first.assetKey, equals('plc-alpha'));
    });
  });

  // =========================================================================
  // Group 10: ConfigService returns server_alias for OPC-UA entries
  // =========================================================================

  group('server alias - ConfigService includes server_alias for OPC-UA', () {
    late ServerDatabase db;
    late ConfigService configService;

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');
      configService = ConfigService(db);

      // Insert key_mappings with OPC-UA entry that has server_alias
      final keyMappingsJson = jsonEncode({
        'nodes': {
          'pump3.speed': {
            'opcua_node': {
              'namespace': 4,
              'identifier': 'GVL_Main.pump3_speed',
              'server_alias': 'PLC_MAIN',
            },
          },
          'modbus.sensor': {
            'modbus_node': {
              'register_type': 'holdingRegister',
              'address': 100,
              'data_type': 'int16',
              'server_alias': 'MODBUS_GW',
            },
          },
          'opcua.no_alias': {
            'opcua_node': {
              'namespace': 4,
              'identifier': 'GVL_Other.temp',
            },
          },
        },
      });

      // Rows, not the blob: `ConfigService` stopped reading
      // `flutter_preferences.key_mappings` when the cutover deleted the
      // fallback, and a fixture that seeded it would test nothing.
      await seedKeyMappings(
          db, jsonDecode(keyMappingsJson) as Map<String, dynamic>);
    });

    tearDown(() async {
      await db.close();
    });

    test('OPC-UA entries include server_alias when present', () async {
      final mappings = await configService.listKeyMappings(
        filter: 'pump3.speed',
      );
      expect(mappings, hasLength(1));
      expect(mappings.first['key'], equals('pump3.speed'));
      expect(mappings.first['protocol'], equals('opcua'));
      expect(mappings.first['server_alias'], equals('PLC_MAIN'));
    });

    test('OPC-UA entries without server_alias omit the field', () async {
      final mappings = await configService.listKeyMappings(
        filter: 'opcua.no_alias',
      );
      expect(mappings, hasLength(1));
      expect(mappings.first['key'], equals('opcua.no_alias'));
      expect(mappings.first['protocol'], equals('opcua'));
      expect(mappings.first.containsKey('server_alias'), isFalse);
    });
  });
}
