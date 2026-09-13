import 'package:drift/drift.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';

import 'test_database.dart';

void main() {
  group('createTestDatabase', () {
    late ServerDatabase db;

    setUp(() {
      db = createTestDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    test('returns a working ServerDatabase backed by in-memory SQLite', () async {
      // The database should be open and responsive
      final result = await db.customSelect('SELECT 1 AS val').getSingle();
      expect(result.read<int>('val'), equals(1));
    });

    test('can insert and query an alarm row', () async {
      // Insert an alarm
      await db.into(db.serverAlarm).insert(ServerAlarmCompanion.insert(
        uid: 'alarm-001',
        title: 'Pump Overcurrent',
        description: 'Motor current exceeds 15A',
        rules: '[]',
      ));

      // Query it back
      final alarms = await db.select(db.serverAlarm).get();
      expect(alarms, hasLength(1));
      expect(alarms.first.uid, equals('alarm-001'));
      expect(alarms.first.title, equals('Pump Overcurrent'));
      expect(alarms.first.description, equals('Motor current exceeds 15A'));
    });
  });
}
