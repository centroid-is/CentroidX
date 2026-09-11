import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/tools/asset_type_catalog_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import 'package:tfc_mcp_server/src/services/asset_type_catalog.dart';
import '../helpers/mock_mcp_client.dart';

void main() {
  group('AssetTypeCatalog', () {
    test('contains at least 30 asset types', () {
      final catalog = AssetTypeCatalog.all;
      expect(catalog.length, greaterThanOrEqualTo(30));
    });

    test('every entry has required fields', () {
      for (final entry in AssetTypeCatalog.all) {
        expect(entry.assetName, isNotEmpty,
            reason: '${entry.displayName} must have an assetName');
        expect(entry.displayName, isNotEmpty,
            reason: '${entry.assetName} must have a displayName');
        expect(entry.category, isNotEmpty,
            reason: '${entry.assetName} must have a category');
        expect(entry.description, isNotEmpty,
            reason: '${entry.assetName} must have a description');
      }
    });

    test('every EtherCAT device type documents its ecSubDevice binding', () {
      final byName = {for (final t in AssetTypeCatalog.all) t.assetName: t};
      for (final name in AssetTypeCatalog.etherCatAssetTypes) {
        expect(byName, contains(name), reason: '$name is not in the catalog');
        expect(byName[name]!.properties.map((p) => p.name), contains('ecSubDevice'),
            reason: '$name must describe ecSubDevice');
      }
      expect(byName['BeckhoffCX5340Config']!.properties.map((p) => p.name),
          isNot(contains('ecSubDevice')),
          reason: 'a CX rack is the master, not a subdevice');
    });

    test('assetNames are unique', () {
      final names = AssetTypeCatalog.all.map((e) => e.assetName).toList();
      expect(names.toSet().length, equals(names.length),
          reason: 'Duplicate assetName found');
    });

    test('categories returns all distinct categories', () {
      final categories = AssetTypeCatalog.categories;
      expect(categories, isNotEmpty);
      // Should contain known categories
      expect(categories, contains('Basic Indicators'));
      expect(categories, contains('Interactive Controls'));
      expect(categories, contains('Visualization'));
      expect(categories, contains('Text & Numbers'));
    });

    test('byCategory filters correctly', () {
      final indicators = AssetTypeCatalog.byCategory('Basic Indicators');
      expect(indicators, isNotEmpty);
      for (final entry in indicators) {
        expect(entry.category, equals('Basic Indicators'));
      }
    });

    test('byCategory returns empty list for unknown category', () {
      final result = AssetTypeCatalog.byCategory('Nonexistent');
      expect(result, isEmpty);
    });

    test('toJson produces valid JSON for each entry', () {
      for (final entry in AssetTypeCatalog.all) {
        final json = entry.toJson();
        expect(json['assetName'], equals(entry.assetName));
        expect(json['displayName'], equals(entry.displayName));
        expect(json['category'], equals(entry.category));
        expect(json['description'], equals(entry.description));
        expect(json['properties'], isA<List>());
      }
    });

    test('known asset types are present', () {
      final names =
          AssetTypeCatalog.all.map((e) => e.assetName).toSet();
      // Spot-check several known types from the AssetRegistry
      expect(names, contains('LEDConfig'));
      expect(names, contains('ButtonConfig'));
      expect(names, contains('ConveyorConfig'));
      expect(names, contains('GraphAssetConfig'));
      expect(names, contains('NumberConfig'));
      expect(names, contains('BeckhoffCX5010Config'));
      expect(names, contains('SchneiderATV320Config'));
      expect(names, contains('TableAssetConfig'));
      expect(names, contains('DrawingViewerConfig'));
    });
  });

  group('list_asset_types tool integration', () {
    late ServerDatabase db;
    late McpServer mcpServer;
    late MockMcpClient client;

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      final auditService = AuditLogService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );

      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      registerAssetTypeCatalogTools(registry);

      client = await MockMcpClient.connect(mcpServer);
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    test('list_asset_types returns all types when no filter', () async {
      final result = await client.callTool('list_asset_types', {});

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;

      // Should contain the count header
      expect(text, contains('Asset Types'));
      // Should mention known types
      expect(text, contains('LED'));
      expect(text, contains('Button'));
      expect(text, contains('Conveyor'));
    });

    test('list_asset_types with category filter returns subset', () async {
      final result = await client.callTool('list_asset_types', {
        'category': 'Basic Indicators',
      });

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('LED'));
      expect(text, contains('Arrow'));
      // Should NOT contain types from other categories
      expect(text, isNot(contains('Button')));
      expect(text, isNot(contains('Graph')));
    });

    test('list_asset_types with unknown category returns empty message',
        () async {
      final result = await client.callTool('list_asset_types', {
        'category': 'Nonexistent Category',
      });

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('No asset types'));
    });

    test('list_asset_types with detail=true returns JSON', () async {
      final result = await client.callTool('list_asset_types', {
        'detail': true,
      });

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      // Should be parseable JSON
      final parsed = jsonDecode(text);
      expect(parsed, isA<List>());
      expect((parsed as List).length, greaterThanOrEqualTo(30));

      // Each entry should have required fields
      final first = parsed.first as Map<String, dynamic>;
      expect(first, containsPair('assetName', isA<String>()));
      expect(first, containsPair('displayName', isA<String>()));
      expect(first, containsPair('category', isA<String>()));
      expect(first, containsPair('description', isA<String>()));
      expect(first, containsPair('properties', isA<List>()));
    });

    test('list_asset_types with detail=true and category filter', () async {
      final result = await client.callTool('list_asset_types', {
        'detail': true,
        'category': 'Beckhoff Devices',
      });

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      final parsed = jsonDecode(text) as List;

      for (final entry in parsed) {
        final map = entry as Map<String, dynamic>;
        expect(map['category'], equals('Beckhoff Devices'));
      }
    });
  });
}
