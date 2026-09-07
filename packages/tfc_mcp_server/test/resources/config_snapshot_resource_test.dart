import 'dart:convert';

import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/server.dart';
import '../helpers/mock_alarm_reader.dart';
import '../helpers/config_rows.dart';
import '../helpers/mock_mcp_client.dart';
import '../helpers/mock_state_reader.dart';

void main() {
  group('Config snapshot resource', () {
    late ServerDatabase db;
    late MockStateReader stateReader;
    late MockAlarmReader alarmReader;
    late TfcMcpServer server;
    late MockMcpClient client;

    /// Two pages, as the rows store them: keyed by the page's stable id, with
    /// the path the pages map keys on inside `menu_item`.
    final pageRows = {
      'page-overview': {
        'title': 'Overview',
        'key': 'overview',
        'menu_item': {'label': 'Overview', 'path': 'overview'},
        'widgets': [
          {'type': 'gauge', 'key': 'pump3.speed'},
        ],
      },
      'page-conveyor': {
        'title': 'Conveyor Control',
        'key': 'conveyor',
        'menu_item': {'label': 'Conveyor', 'path': 'conveyor'},
        'widgets': [
          {'type': 'display', 'key': 'conveyor.speed'},
        ],
      },
    };

    /// Sample key mappings. The `collect` entries these carried were
    /// `{'enabled': ...}`, a shape `CollectEntry` has no field for; the blob
    /// read let it through and the rows read does not.
    final keyMappings = {
      'nodes': {
        'pump3.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Speed'},
        },
        'conveyor.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Conv.Speed'},
        },
      },
    };

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      stateReader = MockStateReader();
      alarmReader = MockAlarmReader();

      // Seed the page rows
      await seedPages(db, pageRows);

      // Seed the key_mapping rows
      await seedKeyMappings(db, keyMappings);

      // Seed alarm definitions where AlarmMan keeps them -- the `alarm`
      // table is in the schema but nothing writes it.
      await seedPreferenceRow(db, 'alarm_man_config', {
        'alarms': [
          {
            'uid': 'alarm-1',
            'title': 'Pump 3 High Temp',
            'description': 'Temperature exceeds 80C',
            'rules': [],
          },
          {
            'uid': 'alarm-2',
            'title': 'Tank 1 Overflow',
            'description': 'Level exceeds 100%',
            'rules': [],
          },
        ],
      });

      server = TfcMcpServer(
        database: db,
        stateReader: stateReader,
        alarmReader: alarmReader,
      );

      client = await MockMcpClient.connect(server.mcpServer);
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    test('resource appears in listResources with correct name and URI',
        () async {
      final result = await client.listResources();
      final configResource = result.resources.where(
        (r) => r.uri == 'scada://config/snapshot',
      );
      expect(configResource, hasLength(1));
      expect(configResource.first.name, equals('System Configuration Snapshot'));
    });

    test(
        'readResource returns JSON with pages, assets, key_mappings, and alarm_definitions keys',
        () async {
      final result = await client.readResource('scada://config/snapshot');
      expect(result.contents, hasLength(1));

      final text = (result.contents.first as dynamic).text as String;
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(json, containsPair('pages', isA<List<dynamic>>()));
      expect(json, containsPair('assets', isA<List<dynamic>>()));
      expect(json, containsPair('key_mappings', isA<List<dynamic>>()));
      expect(json, containsPair('alarm_definitions', isA<List<dynamic>>()));
    });

    test('each section contains summary data (key+title), not full blobs',
        () async {
      final result = await client.readResource('scada://config/snapshot');
      final text = (result.contents.first as dynamic).text as String;
      final json = jsonDecode(text) as Map<String, dynamic>;

      // Pages should have key+title, not full widget configs
      final pages = json['pages'] as List;
      expect(pages, hasLength(2));
      final firstPage = pages.first as Map<String, dynamic>;
      expect(firstPage, containsPair('key', isA<String>()));
      expect(firstPage, containsPair('title', isA<String>()));
      // Should NOT contain raw widget data
      expect(firstPage.containsKey('widgets'), isFalse);

      // Key mappings should have key+namespace+identifier
      final mappings = json['key_mappings'] as List;
      expect(mappings, hasLength(2));
      final firstMapping = mappings.first as Map<String, dynamic>;
      expect(firstMapping, containsPair('key', isA<String>()));
      expect(firstMapping, containsPair('namespace', isA<int>()));
      expect(firstMapping, containsPair('identifier', isA<String>()));

      // Alarm definitions should have uid+title+description
      final alarms = json['alarm_definitions'] as List;
      expect(alarms, hasLength(2));
      final firstAlarm = alarms.first as Map<String, dynamic>;
      expect(firstAlarm, containsPair('uid', isA<String>()));
      expect(firstAlarm, containsPair('title', isA<String>()));
    });

    test('empty database returns valid JSON with empty arrays', () async {
      // Create a fresh empty database
      final emptyDb = ServerDatabase.inMemory();
      await emptyDb.customStatement('SELECT 1');

      final emptyServer = TfcMcpServer(
        database: emptyDb,
        stateReader: MockStateReader(),
        alarmReader: MockAlarmReader(),
      );

      final emptyClient =
          await MockMcpClient.connect(emptyServer.mcpServer);
      try {
        final result =
            await emptyClient.readResource('scada://config/snapshot');
        final text = (result.contents.first as dynamic).text as String;
        final json = jsonDecode(text) as Map<String, dynamic>;

        expect(json['pages'], isEmpty);
        expect(json['assets'], isEmpty);
        expect(json['key_mappings'], isEmpty);
        expect(json['alarm_definitions'], isEmpty);
      } finally {
        await emptyClient.close();
        await emptyDb.close();
      }
    });
  });
}
