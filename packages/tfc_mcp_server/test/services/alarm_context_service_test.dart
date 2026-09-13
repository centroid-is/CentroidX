
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/services/alarm_context_service.dart';
import 'package:tfc_mcp_server/src/services/alarm_service.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import 'package:tfc_mcp_server/src/services/tag_service.dart';
import 'package:tfc_mcp_server/src/services/trend_service.dart';
import '../helpers/mock_alarm_reader.dart';
import '../helpers/mock_state_reader.dart';
import '../helpers/config_rows.dart';

void main() {
  group('AlarmContextService', () {
    late ServerDatabase db;
    late MockStateReader stateReader;
    late MockAlarmReader alarmReader;
    late AlarmService alarmService;
    late TagService tagService;
    late TrendService trendService;
    late ConfigService configService;
    late AlarmContextService contextService;

    // Use real "now" so test data falls within the 24-hour window that
    // AlarmContextService.buildContext computes from DateTime.now().
    final now = DateTime.now().toUtc();
    final oneHourAgo = now.subtract(const Duration(hours: 1));
    final twoHoursAgo = now.subtract(const Duration(hours: 2));
    final threeHoursAgo = now.subtract(const Duration(hours: 3));

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      stateReader = MockStateReader();
      alarmReader = MockAlarmReader();

      // Seed alarm configs with 'key' field for prefix correlation
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

      alarmReader.addAlarmConfig({
        'uid': 'alarm-3',
        'key': 'tank1.overflow',
        'title': 'Tank 1 Overflow',
        'description': 'Level exceeds 100%',
        'rules': [],
      });

      // Seed sibling tags by prefix "pump3"
      stateReader.setValue('pump3.overcurrent', true);
      stateReader.setValue('pump3.speed', 1450.0);
      stateReader.setValue('pump3.temperature', 82.5);
      stateReader.setValue('conveyor.speed', 3.2);

      // Definitions the context reads, from the preference AlarmMan uses.
      await seedPreferenceRow(db, 'alarm_man_config', {
        'alarms': [
          {
            'uid': 'alarm-1',
            'title': 'Pump 3 Overcurrent',
            'description': 'Current exceeds 15A threshold',
            'rules': [
              {'type': 'threshold', 'value': 15.0, 'operator': '>'},
            ],
          },
          {
            'uid': 'alarm-2',
            'title': 'Pump 3 Over Temperature',
            'description': 'Temperature exceeds 90C',
            'rules': [],
          },
          {
            'uid': 'alarm-3',
            'title': 'Tank 1 Overflow',
            'description': 'Level exceeds 100%',
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
            rules: '[{"type":"threshold","value":15.0,"operator":">"}]',
          ));
      await db.into(db.serverAlarm).insert(ServerAlarmCompanion.insert(
            uid: 'alarm-2',
            title: 'Pump 3 Over Temperature',
            description: 'Temperature exceeds 90C',
            rules: '[]',
          ));
      await db.into(db.serverAlarm).insert(ServerAlarmCompanion.insert(
            uid: 'alarm-3',
            title: 'Tank 1 Overflow',
            description: 'Level exceeds 100%',
            rules: '[]',
          ));

      // Seed alarm history for alarm-1 (the alarm we'll query)
      await db.into(db.serverAlarmHistory).insert(
            ServerAlarmHistoryCompanion.insert(
              alarmUid: 'alarm-1',
              alarmTitle: 'Pump 3 Overcurrent',
              alarmDescription: 'Current exceeds 15A threshold',
              alarmLevel: 'critical',
              expression: const Value('pump3.current > 15'),
              active: true,
              pendingAck: true,
              createdAt: oneHourAgo,
            ),
          );

      // Older deactivated record for alarm-1
      await db.into(db.serverAlarmHistory).insert(
            ServerAlarmHistoryCompanion.insert(
              alarmUid: 'alarm-1',
              alarmTitle: 'Pump 3 Overcurrent',
              alarmDescription: 'Current exceeds 15A threshold',
              alarmLevel: 'critical',
              expression: const Value('pump3.current > 15'),
              active: false,
              pendingAck: false,
              createdAt: threeHoursAgo,
              deactivatedAt: Value(twoHoursAgo),
            ),
          );

      // Sibling alarm history (same prefix pump3, different UID)
      await db.into(db.serverAlarmHistory).insert(
            ServerAlarmHistoryCompanion.insert(
              alarmUid: 'alarm-2',
              alarmTitle: 'Pump 3 Over Temperature',
              alarmDescription: 'Temperature exceeds 90C',
              alarmLevel: 'warning',
              expression: const Value('pump3.temp > 90'),
              active: true,
              pendingAck: true,
              createdAt: twoHoursAgo,
            ),
          );

      // Unrelated alarm history (different prefix)
      await db.into(db.serverAlarmHistory).insert(
            ServerAlarmHistoryCompanion.insert(
              alarmUid: 'alarm-3',
              alarmTitle: 'Tank 1 Overflow',
              alarmDescription: 'Level exceeds 100%',
              alarmLevel: 'critical',
              active: false,
              pendingAck: false,
              createdAt: threeHoursAgo,
              deactivatedAt: Value(twoHoursAgo),
            ),
          );

      alarmService = AlarmService(alarmReader: alarmReader, db: db);
      tagService = TagService(stateReader);
      trendService = TrendService(db, isPostgres: false);
      configService = ConfigService(db);

      contextService = AlarmContextService(
        alarmService: alarmService,
        tagService: tagService,
        trendService: trendService,
        configService: configService,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('buildContext with valid alarm UID returns non-null AlarmContext '
        'with non-empty causalEvents list', () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);
      expect(context!.causalEvents, isNotEmpty);
    });

    test('causalEvents are ordered chronologically (earliest first)', () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);

      final timestamps =
          context!.causalEvents.map((e) => e.timestamp).toList();
      for (var i = 1; i < timestamps.length; i++) {
        expect(
          timestamps[i].isAfter(timestamps[i - 1]) ||
              timestamps[i].isAtSameMomentAs(timestamps[i - 1]),
          isTrue,
          reason: 'Events should be in chronological order: '
              '${timestamps[i - 1]} should be <= ${timestamps[i]}',
        );
      }
    });

    test('causalEvents include alarm activation events from history '
        'with expression field', () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);

      final activationEvents = context!.causalEvents
          .where((e) =>
              e.eventType == 'alarm_activated' ||
              e.eventType == 'alarm_deactivated')
          .toList();
      expect(activationEvents, isNotEmpty,
          reason: 'Should have alarm activation/deactivation events');

      // At least one event should have expression evidence
      final withExpression =
          activationEvents.where((e) => e.evidence != null).toList();
      expect(withExpression, isNotEmpty,
          reason: 'Alarm events should include expression as evidence');
      expect(withExpression.first.evidence, contains('pump3.current'));
    });

    test('causalEvents include correlated sibling alarm events '
        '(same prefix, different UID)', () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);

      final siblingEvents = context!.causalEvents
          .where((e) => e.eventType == 'sibling_alarm')
          .toList();
      expect(siblingEvents, isNotEmpty,
          reason: 'Should include sibling alarm events from same prefix');

      // Should include alarm-2 (pump3.overtemp) but not alarm-3 (tank1.overflow)
      final descriptions = siblingEvents.map((e) => e.description).join(' ');
      expect(descriptions, contains('Pump 3 Over Temperature'));
    });

    test('AlarmContext includes correlatedTags (sibling tags by prefix)',
        () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);

      final tagKeys =
          context!.correlatedTags.map((t) => t['key'] as String).toList();
      expect(tagKeys, contains('pump3.speed'));
      expect(tagKeys, contains('pump3.temperature'));
      // conveyor.speed has a different prefix, should not appear
      expect(tagKeys, isNot(contains('conveyor.speed')));
    });

    test('AlarmContext.trendSummary is "No trend data available" '
        'when TrendService has no data', () async {
      // No trend tables exist in in-memory SQLite, so all trend queries
      // should return errors, producing the graceful fallback message
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);
      expect(context!.trendSummary, contains('No trend data available'));
    });

    test('buildContext with nonexistent alarm UID returns null', () async {
      final context = await contextService.buildContext('nonexistent-alarm');
      expect(context, isNull);
    });

    test('toText() produces structured output with sections: '
        'Alarm Detail, Causal Chain, Correlated Tags, Trend Context',
        () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);

      final text = context!.toText();
      expect(text, contains('## Alarm Detail'));
      expect(text, contains('## Causal Chain'));
      expect(text, contains('## Correlated Tag Values'));
      expect(text, contains('## Trend Context'));
      expect(text, contains('## Alarm Definitions'));
    });

    test('toText() includes alarm detail fields', () async {
      final context = await contextService.buildContext('alarm-1');
      final text = context!.toText();

      expect(text, contains('Pump 3 Overcurrent'));
      expect(text, contains('pump3.overcurrent'));
    });

    test('toText() includes causal chain entries with timestamps', () async {
      final context = await contextService.buildContext('alarm-1');
      final text = context!.toText();

      // Should contain formatted timestamps and event types
      expect(text, contains('alarm_activated'));
      expect(text, contains('Evidence:'));
    });

    test('AlarmContext includes alarmDefinitions from ConfigService', () async {
      final context = await contextService.buildContext('alarm-1');
      expect(context, isNotNull);
      expect(context!.alarmDefinitions, isNotEmpty);

      final uids =
          context.alarmDefinitions.map((d) => d['uid'] as String).toList();
      expect(uids, contains('alarm-1'));
    });
  });
}
