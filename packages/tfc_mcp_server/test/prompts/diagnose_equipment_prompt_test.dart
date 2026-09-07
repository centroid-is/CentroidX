import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:mcp_dart/mcp_dart.dart' show McpError;
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/interfaces/tech_doc_index.dart';
import 'package:tfc_mcp_server/src/server.dart';
import '../helpers/mock_alarm_reader.dart';
import '../helpers/mock_mcp_client.dart';
import '../helpers/mock_state_reader.dart';
import '../helpers/mock_tech_doc_index.dart';
import '../helpers/config_rows.dart';

void main() {
  group('diagnose_equipment prompt', () {
    late ServerDatabase db;
    late MockStateReader stateReader;
    late MockAlarmReader alarmReader;
    late TfcMcpServer server;
    late MockMcpClient client;

    final now = DateTime.now().toUtc();
    final oneHourAgo = now.subtract(const Duration(hours: 1));
    final twoHoursAgo = now.subtract(const Duration(hours: 2));

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      stateReader = MockStateReader();
      alarmReader = MockAlarmReader();

      // Seed alarm configs with key fields for prefix correlation
      alarmReader.addAlarmConfig({
        'uid': 'alarm-1',
        'key': 'pump3.overcurrent',
        'title': 'Pump 3 Overcurrent',
        'description': 'Current exceeds 15A threshold',
        'rules': [
          {'type': 'threshold', 'value': 15.0, 'operator': '>'}
        ],
      });

      alarmReader.addAlarmConfig({
        'uid': 'alarm-2',
        'key': 'pump3.overtemp',
        'title': 'Pump 3 Over Temperature',
        'description': 'Temperature exceeds 90C',
        'rules': [],
      });

      // Seed tags with pump3 prefix
      stateReader.setValue('pump3.overcurrent', true);
      stateReader.setValue('pump3.speed', 1450.0);
      stateReader.setValue('pump3.temperature', 82.5);
      stateReader.setValue('conveyor.speed', 3.2);

      // Definitions the prompt reads, from the row AlarmMan's config lives in.
      await seedPreferenceRow(db, 'alarm_man_config', {
        'alarms': [
          {
            'uid': 'alarm-1',
            'title': 'Pump 3 Overcurrent',
            'description': 'Current exceeds 15A threshold',
            'rules': [],
          },
          {
            'uid': 'alarm-2',
            'title': 'Pump 3 Over Temperature',
            'description': 'Temperature exceeds 90C',
            'rules': [],
          },
        ],
      });

      // The same alarms as table rows: alarm_history has a foreign key onto
      // alarm(uid), so the history seeded below will not insert without them.
      await db.into(db.serverAlarm).insert(ServerAlarmCompanion.insert(
            uid: 'alarm-1',
            title: 'Pump 3 Overcurrent',
            description: 'Current exceeds 15A threshold',
            rules: '[]',
          ));
      await db.into(db.serverAlarm).insert(ServerAlarmCompanion.insert(
            uid: 'alarm-2',
            title: 'Pump 3 Over Temperature',
            description: 'Temperature exceeds 90C',
            rules: '[]',
          ));

      // Seed alarm history records
      await db.into(db.serverAlarmHistory).insert(
            ServerAlarmHistoryCompanion.insert(
              alarmUid: 'alarm-1',
              alarmTitle: 'Pump 3 Overcurrent',
              alarmDescription: 'Current exceeds 15A threshold',
              alarmLevel: 'critical',
              active: true,
              pendingAck: true,
              createdAt: oneHourAgo,
            ),
          );

      await db.into(db.serverAlarmHistory).insert(
            ServerAlarmHistoryCompanion.insert(
              alarmUid: 'alarm-1',
              alarmTitle: 'Pump 3 Overcurrent',
              alarmDescription: 'Current exceeds 15A threshold',
              alarmLevel: 'critical',
              active: false,
              pendingAck: false,
              createdAt: twoHoursAgo,
              deactivatedAt: Value(oneHourAgo),
            ),
          );

      // The page row the asset lookup answers from. The pages map is keyed
      // by the path in the payload, so the path here is what the prompt looks
      // the panel up by.
      await seedPages(db, {
        'page-pump3': {
          'key': 'pump3',
          'title': 'Pump 3 Control Panel',
          'description': 'Main circulation pump',
          'menu_item': {'label': 'Pump 3', 'path': 'pump3'},
        },
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

    test('diagnose_equipment appears in listPrompts with description',
        () async {
      final result = await client.listPrompts();
      final prompt = result.prompts.where(
        (p) => p.name == 'diagnose_equipment',
      );
      expect(prompt, hasLength(1));
      expect(prompt.first.description, isNotEmpty);
    });

    test('getPrompt with valid asset_key returns non-empty messages',
        () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      expect(result.messages, isNotEmpty);
    });

    test('prompt text contains asset configuration detail', () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      expect(text, contains('Pump 3 Control Panel'));
      expect(text, contains('pump3'));
    });

    test('prompt text contains correlated tag values for the asset', () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      // Should contain tags for pump3 prefix
      expect(text, contains('pump3.speed'));
      expect(text, contains('pump3.temperature'));
      // Should NOT contain tags from other prefixes
      expect(text, isNot(contains('conveyor.speed')));
    });

    test('prompt text contains alarm history section for the asset', () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      expect(text, contains('Alarm History'));
      expect(text, contains('Pump 3 Overcurrent'));
    });

    test('prompt text contains trend context section', () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      // Trend section should exist even if no trend data available
      expect(text, contains('Trend Data'));
    });

    test('prompt text contains structured troubleshooting instructions',
        () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      expect(text, contains('troubleshooting'));
      expect(text, contains('Diagnose'));
    });

    test('prompt text contains AI-generated labeling instruction', () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      expect(text, contains('AI-generated'));
    });

    test('prompt text contains drawing references section when drawings exist',
        () async {
      // Seed a drawing for pump3 using the correct tables
      final drawingId = await db.into(db.drawingTable).insert(
            DrawingTableCompanion.insert(
              assetKey: 'pump3',
              drawingName: 'MainPanel.pdf',
              filePath: '/drawings/MainPanel.pdf',
              pageCount: 5,
              uploadedAt: now,
            ),
          );
      await db.into(db.drawingComponentTable).insert(
            DrawingComponentTableCompanion.insert(
              drawingId: drawingId,
              pageNumber: 3,
              fullPageText: 'pump3 VFD wiring diagram',
            ),
          );

      // Rebuild server to pick up the drawing
      await client.close();

      server = TfcMcpServer(
        database: db,
        stateReader: stateReader,
        alarmReader: alarmReader,
      );

      client = await MockMcpClient.connect(server.mcpServer);

      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'pump3'},
      );
      final text = _extractText(result);

      expect(text, contains('Electrical Drawing'));
      expect(text, contains('MainPanel.pdf'));
    });

    test('getPrompt without asset_key argument returns MCP error', () async {
      // mcp_dart validates required arguments at the protocol level
      expect(
        () => client.getPrompt('diagnose_equipment'),
        throwsA(isA<McpError>()),
      );
    });

    test('getPrompt with nonexistent asset_key returns not-found message',
        () async {
      final result = await client.getPrompt(
        'diagnose_equipment',
        arguments: {'asset_key': 'nonexistent_asset'},
      );
      final text = _extractText(result);

      expect(text.toLowerCase(), contains('not found'));
    });

    group('tech doc integration', () {
      late MockTechDocIndex techDocIndex;
      late TfcMcpServer techDocServer;
      late MockMcpClient techDocClient;

      setUp(() async {
        techDocIndex = MockTechDocIndex();

        // Store a sample document with pump3-related sections
        await techDocIndex.storeDocument(
          name: 'ATV320 Installation Manual',
          pdfBytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
          sections: [
            ParsedSection(
              title: 'Chapter 3: Wiring for pump3',
              content: 'Wiring specifications for pump3 VFD connection',
              pageStart: 10,
              pageEnd: 15,
              level: 1,
              sortOrder: 1,
            ),
            ParsedSection(
              title: 'Troubleshooting pump3 faults',
              content: 'Common fault codes and resolution steps for pump3',
              pageStart: 42,
              pageEnd: 48,
              level: 1,
              sortOrder: 2,
            ),
          ],
        );

        techDocServer = TfcMcpServer(
          database: db,
          stateReader: stateReader,
          alarmReader: alarmReader,
          techDocIndex: techDocIndex,
        );

        techDocClient = await MockMcpClient.connect(techDocServer.mcpServer);
      });

      tearDown(() async {
        await techDocClient.close();
      });

      test(
          'prompt includes Knowledge Base section when techDocService returns results',
          () async {
        final result = await techDocClient.getPrompt(
          'diagnose_equipment',
          arguments: {'asset_key': 'pump3'},
        );
        final text = _extractText(result);

        expect(text, contains('Knowledge Base'));
      });

      test('tech doc section includes doc names and section titles with pages',
          () async {
        final result = await techDocClient.getPrompt(
          'diagnose_equipment',
          arguments: {'asset_key': 'pump3'},
        );
        final text = _extractText(result);

        expect(text, contains('ATV320 Installation Manual'));
        expect(text, contains('Wiring'));
        expect(text, contains('Troubleshooting'));
      });

      test(
          'prompt instructs LLM to use get_tech_doc_section for relevant specs',
          () async {
        final result = await techDocClient.getPrompt(
          'diagnose_equipment',
          arguments: {'asset_key': 'pump3'},
        );
        final text = _extractText(result);

        expect(text, contains('get_tech_doc_section'));
      });

      test(
          'prompt includes tech doc reference rule in RULES section',
          () async {
        final result = await techDocClient.getPrompt(
          'diagnose_equipment',
          arguments: {'asset_key': 'pump3'},
        );
        final text = _extractText(result);

        expect(text, contains('technical documentation'));
      });
    });

    group('tech doc graceful degradation', () {
      test('prompt works without tech doc section when techDocService is null',
          () async {
        // The default setUp creates a server without techDocIndex,
        // so techDocService is null
        final result = await client.getPrompt(
          'diagnose_equipment',
          arguments: {'asset_key': 'pump3'},
        );
        final text = _extractText(result);

        // Should still work fine without tech docs
        expect(text, contains('Pump 3 Control Panel'));
        expect(text, isNot(contains('Knowledge Base')));
      });

      test('prompt omits tech doc section when search returns empty', () async {
        // Create server with empty tech doc index
        final emptyIndex = MockTechDocIndex();

        final emptyServer = TfcMcpServer(
          database: db,
          stateReader: stateReader,
          alarmReader: alarmReader,
          techDocIndex: emptyIndex,
        );

        final emptyClient =
            await MockMcpClient.connect(emptyServer.mcpServer);

        try {
          final result = await emptyClient.getPrompt(
            'diagnose_equipment',
            arguments: {'asset_key': 'pump3'},
          );
          final text = _extractText(result);

          // Should not include tech doc section when empty
          expect(text, contains('Pump 3 Control Panel'));
          expect(text, isNot(contains('Knowledge Base')));
        } finally {
          await emptyClient.close();
        }
      });
    });
  });
}

/// Extracts all text content from a [GetPromptResult].
String _extractText(dynamic result) {
  final messages = result.messages as List<dynamic>;
  final buffer = StringBuffer();
  for (final msg in messages) {
    final content = msg.content;
    final text = content.text as String?;
    if (text != null) {
      buffer.writeln(text);
    }
  }
  return buffer.toString();
}
