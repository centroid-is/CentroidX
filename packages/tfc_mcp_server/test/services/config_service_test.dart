import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import '../helpers/test_database.dart';

void main() {
  group('ConfigService', () {
    late ServerDatabase db;
    late ConfigService service;

    /// Sample page_editor_data JSON with 3 pages.
    final pageEditorData = {
      'overview': {
        'title': 'Overview',
        'key': 'overview',
        'widgets': [
          {'type': 'gauge', 'key': 'pump3.speed'},
        ],
      },
      'conveyor': {
        'title': 'Conveyor Control',
        'key': 'conveyor',
        'widgets': [
          {'type': 'display', 'key': 'conveyor.speed'},
        ],
      },
      'mixer': {
        'title': 'Mixer Station',
        'key': 'mixer',
        'widgets': [],
      },
    };

    /// Sample key_mappings JSON with OPC UA entries.
    final keyMappings = {
      'nodes': {
        'pump3.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Speed'},
          'collect': {'enabled': true},
        },
        'pump3.current': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Current'},
          'collect': {'enabled': true},
        },
        'conveyor.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Conv.Speed'},
          'collect': {'enabled': false},
        },
      },
    };

    /// Sample key_mappings JSON with mixed protocols.
    final mixedKeyMappings = {
      'nodes': {
        'pump3.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Speed'},
        },
        'tank.level': {
          'modbus_node': {
            'register_type': 'holdingRegister',
            'address': 100,
            'data_type': 'uint16',
            'poll_group': 'fast',
            'server_alias': 'plc1',
          },
        },
        'weigher.batch': {
          'm2400_node': {
            'record_type': 'BATCH',
            'field': 'weight',
            'server_alias': 'jbtm1',
          },
        },
        'pump3.dual': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Dual'},
          'modbus_node': {
            'register_type': 'inputRegister',
            'address': 200,
            'data_type': 'float32',
            'poll_group': 'default',
          },
        },
      },
    };

    setUp(() async {
      db = createTestDatabase();
      // Ensure tables are created
      await db.customStatement('SELECT 1');
      service = ConfigService(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> insertPreference(String key, dynamic value) async {
      await db.into(db.serverFlutterPreferences).insert(
            ServerFlutterPreferencesCompanion.insert(
              key: key,
              value: Value(jsonEncode(value)),
              type: 'String',
            ),
          );
    }

    /// Seeds the alarm definitions the way the app really stores them.
    ///
    /// AlarmMan keeps its whole config in the `alarm_man_config` preference
    /// and never writes the `alarm` table, so a test that seeds the table
    /// proves nothing about the alarms an operator can actually see.
    Future<void> insertAlarms(List<Map<String, dynamic>> alarms) async {
      await insertPreference('alarm_man_config', {'alarms': alarms});
    }

    Map<String, dynamic> alarmJson({
      required String uid,
      String? key,
      required String title,
      required String description,
      List<Map<String, dynamic>> rules = const [],
    }) =>
        {
          'uid': uid,
          if (key != null) 'key': key,
          'title': title,
          'description': description,
          'rules': rules,
        };

    group('listPages', () {
      test('returns page key+title summaries from page_editor_data', () async {
        await insertPreference('page_editor_data', pageEditorData);

        final pages = await service.listPages();

        expect(pages, hasLength(3));
        // Should contain key and title for each page
        final keys = pages.map((p) => p['key']).toSet();
        expect(keys, containsAll(['overview', 'conveyor', 'mixer']));
        final titles = pages.map((p) => p['title']).toSet();
        expect(titles, containsAll(
            ['Overview', 'Conveyor Control', 'Mixer Station']));
      });

      test('returns empty list when no page_editor_data exists', () async {
        final pages = await service.listPages();
        expect(pages, isEmpty);
      });

      test('respects limit parameter', () async {
        await insertPreference('page_editor_data', pageEditorData);

        final pages = await service.listPages(limit: 2);
        expect(pages, hasLength(2));
      });
    });

    group('listAssets', () {
      test('returns asset summaries from page_editor_data', () async {
        await insertPreference('page_editor_data', pageEditorData);

        final assets = await service.listAssets();

        expect(assets, hasLength(3));
        final keys = assets.map((a) => a['key']).toSet();
        expect(keys, containsAll(['overview', 'conveyor', 'mixer']));
      });

      test('returns empty list when no data exists', () async {
        final assets = await service.listAssets();
        expect(assets, isEmpty);
      });
    });

    group('getAssetDetail', () {
      test('returns full page config for given page key', () async {
        await insertPreference('page_editor_data', pageEditorData);

        final detail = await service.getAssetDetail('overview');

        expect(detail, isNotNull);
        expect(detail!['key'], equals('overview'));
        expect(detail['title'], equals('Overview'));
        expect(detail['widgets'], isList);
        expect((detail['widgets'] as List), hasLength(1));
      });

      test('returns null for nonexistent page key', () async {
        await insertPreference('page_editor_data', pageEditorData);

        final detail = await service.getAssetDetail('nonexistent');
        expect(detail, isNull);
      });
    });

    group('listKeyMappings', () {
      test('returns OPC UA key-to-node pairs from key_mappings', () async {
        await insertPreference('key_mappings', keyMappings);

        final mappings = await service.listKeyMappings();

        expect(mappings, hasLength(3));
        final keys = mappings.map((m) => m['key']).toSet();
        expect(keys,
            containsAll(['pump3.speed', 'pump3.current', 'conveyor.speed']));
        // Each mapping should have protocol, identifier, namespace
        for (final m in mappings) {
          expect(m['protocol'], equals('opcua'));
          expect(m['identifier'], isA<String>());
          expect(m['namespace'], isA<int>());
        }
      });

      test('returns empty list when no key_mappings exists', () async {
        final mappings = await service.listKeyMappings();
        expect(mappings, isEmpty);
      });

      test('respects limit parameter', () async {
        await insertPreference('key_mappings', keyMappings);

        final mappings = await service.listKeyMappings(limit: 2);
        expect(mappings, hasLength(2));
      });

      test('supports fuzzy filter', () async {
        await insertPreference('key_mappings', keyMappings);

        final mappings = await service.listKeyMappings(filter: 'pump');
        expect(mappings, hasLength(2));
        for (final m in mappings) {
          expect((m['key'] as String).toLowerCase(), contains('pump'));
        }
      });

      test('returns modbus mappings with register info', () async {
        await insertPreference('key_mappings', mixedKeyMappings);

        final mappings = await service.listKeyMappings(filter: 'tank');
        expect(mappings, hasLength(1));
        final m = mappings.first;
        expect(m['key'], equals('tank.level'));
        expect(m['protocol'], equals('modbus'));
        expect(m['register_type'], equals('holdingRegister'));
        expect(m['address'], equals(100));
        expect(m['data_type'], equals('uint16'));
        expect(m['poll_group'], equals('fast'));
        expect(m['server_alias'], equals('plc1'));
      });

      test('returns m2400 mappings with record info', () async {
        await insertPreference('key_mappings', mixedKeyMappings);

        final mappings = await service.listKeyMappings(filter: 'weigher');
        expect(mappings, hasLength(1));
        final m = mappings.first;
        expect(m['key'], equals('weigher.batch'));
        expect(m['protocol'], equals('m2400'));
        expect(m['record_type'], equals('BATCH'));
        expect(m['field'], equals('weight'));
        expect(m['server_alias'], equals('jbtm1'));
      });

      test('returns multiple mappings for dual-protocol keys', () async {
        await insertPreference('key_mappings', mixedKeyMappings);

        final mappings = await service.listKeyMappings(filter: 'pump3.dual');
        expect(mappings, hasLength(2));
        final protocols = mappings.map((m) => m['protocol']).toSet();
        expect(protocols, containsAll(['opcua', 'modbus']));
      });

      test('returns all protocols in mixed key_mappings', () async {
        await insertPreference('key_mappings', mixedKeyMappings);

        // 4 nodes but pump3.dual has 2 protocols = 5 entries
        final mappings = await service.listKeyMappings();
        expect(mappings, hasLength(5));
        final protocols = mappings.map((m) => m['protocol']).toSet();
        expect(protocols, containsAll(['opcua', 'modbus', 'm2400']));
      });
    });

    // `key_mappings` moved out of `flutter_preferences` and into one
    // `config_item` row per key. This service feeds `access_template_tools`
    // "the whole key universe", so serving the blob after the cutover is not
    // an inconvenience: an access template written against a key set that
    // stopped being updated is a rule that does not cover the wiring it was
    // meant to cover.
    //
    // `config_item` is created by tfc_dart's migration and is deliberately not
    // part of `ServerDatabase`'s drift schema -- the same arrangement
    // `flutter_preferences` has, one physical table read through raw SQL. So
    // these tests create it the way a real database gets it, with DDL.
    group('listKeyMappings over config_item rows', () {
      Future<void> createConfigItemTable() => db.customStatement(
          'CREATE TABLE IF NOT EXISTS config_item (kind TEXT NOT NULL, '
          'id TEXT NOT NULL, scope TEXT NOT NULL, parent_id TEXT, '
          'sort_index INTEGER, payload TEXT NOT NULL, '
          'rev INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL, '
          'updated_by TEXT NOT NULL, PRIMARY KEY (kind, id, scope))');

      Future<void> insertMappingRow(
        String id,
        Map<String, dynamic> payload, {
        String scope = 'shared',
        String kind = 'key_mapping',
      }) =>
          db.customStatement(
            'INSERT INTO config_item (kind, id, scope, payload, rev, '
            'updated_at, updated_by) VALUES (?, ?, ?, ?, 0, ?, ?)',
            [
              kind,
              id,
              scope,
              jsonEncode(payload),
              '2026-09-07T00:00:00Z',
              'tester',
            ],
          );

      Map<String, dynamic> opcua(String identifier) => {
            'opcua_node': {'namespace': 2, 'identifier': identifier},
          };

      test('serves the key universe from the rows when they exist', () async {
        // The blob and the rows deliberately share no key, so the assertion
        // cannot pass by accident on a service that reads both or the wrong
        // one.
        await insertPreference('key_mappings', keyMappings);
        await createConfigItemTable();
        await insertMappingRow('CN04.MOT01.Run', opcua('CN04.Run'));
        await insertMappingRow('CN04.MOT01.Stop', opcua('CN04.Stop'));

        final mappings = await service.listKeyMappings();

        final keys = mappings.map((m) => m['key']).toSet();
        expect(keys, containsAll(['CN04.MOT01.Run', 'CN04.MOT01.Stop']));
        expect(keys, isNot(contains('pump3.speed')),
            reason: 'once the rows exist the blob is a frozen copy; serving '
                'it is how an access template ends up written against wiring '
                'that no longer exists');
      });

      test('ignores rows of another scope or another kind', () async {
        await createConfigItemTable();
        await insertMappingRow('CN04.MOT01.Run', opcua('CN04.Run'));
        await insertMappingRow('CN09.MOT01.Run', opcua('CN09.Run'),
            scope: 'station:svn-nes-ot-cl02');
        await insertMappingRow('theme_mode', {'t': 's', 'v': 'dark'},
            kind: 'preference');

        final mappings = await service.listKeyMappings();

        expect(mappings.map((m) => m['key']), ['CN04.MOT01.Run']);
      });

      test('serves the blob while the migration has not run', () async {
        // The rollout window: the table is there, the rows are not. This is a
        // read-side fallback and not a dual-write -- it reads the same blob
        // this service has always read, and it retires itself the moment a
        // row exists.
        await createConfigItemTable();
        await insertPreference('key_mappings', keyMappings);

        final mappings = await service.listKeyMappings();

        expect(mappings.map((m) => m['key']),
            containsAll(['pump3.speed', 'conveyor.speed']));
      });

      test('serves the blob when config_item does not exist at all', () async {
        // A ServerDatabase opened against a database tfc_dart has not
        // migrated yet. Failing here would take out `list_key_mappings` and
        // every access template tool built on it, to report a table that is
        // about to be created.
        await insertPreference('key_mappings', keyMappings);

        final mappings = await service.listKeyMappings();

        expect(mappings.map((m) => m['key']), contains('pump3.speed'));
      });

      test('reads the rows once per cache TTL', () async {
        await createConfigItemTable();
        await insertMappingRow('CN04.MOT01.Run', opcua('CN04.Run'));

        expect((await service.listKeyMappings()).map((m) => m['key']),
            ['CN04.MOT01.Run']);

        await insertMappingRow('CN05.MOT01.Run', opcua('CN05.Run'));

        expect((await service.listKeyMappings()).map((m) => m['key']),
            ['CN04.MOT01.Run'],
            reason: 'the 5-minute TtlCache covers the rows read too; a row '
                'inserted inside the window is not visible until it expires '
                'or something calls invalidateCache()');

        service.invalidateCache();
        expect((await service.listKeyMappings()).map((m) => m['key']),
            ['CN04.MOT01.Run', 'CN05.MOT01.Run']);
      });
    });

    group('listAlarmDefinitions', () {
      test('returns alarm uid/title/description summaries', () async {
        await insertAlarms([
          alarmJson(
            uid: 'alarm-1',
            key: 'pump3.temp',
            title: 'Pump 3 High Temperature',
            description: 'Temperature exceeds 80C',
          ),
          alarmJson(
            uid: 'alarm-2',
            key: 'conveyor.speed',
            title: 'Conveyor Overspeed',
            description: 'Conveyor belt speed above limit',
          ),
        ]);

        final alarms = await service.listAlarmDefinitions();

        expect(alarms, hasLength(2));
        final uids = alarms.map((a) => a['uid']).toSet();
        expect(uids, containsAll(['alarm-1', 'alarm-2']));
        expect(alarms.first['title'], isA<String>());
        expect(alarms.first['description'], isA<String>());
      });

      test('respects limit parameter', () async {
        await insertAlarms([
          for (var i = 0; i < 10; i++)
            alarmJson(
              uid: 'alarm-$i',
              title: 'Alarm $i',
              description: 'Description $i',
            ),
        ]);

        final alarms = await service.listAlarmDefinitions(limit: 5);
        expect(alarms, hasLength(5));
      });

      test('supports fuzzy filter', () async {
        await insertAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Pump 3 High Temperature',
            description: 'Temperature exceeds 80C',
          ),
          alarmJson(
            uid: 'alarm-2',
            title: 'Conveyor Overspeed',
            description: 'Belt speed above limit',
          ),
        ]);

        final alarms = await service.listAlarmDefinitions(filter: 'pump');
        expect(alarms, hasLength(1));
        expect(alarms.first['title'], contains('Pump'));
      });

      test('an empty alarm table does not hide the configured alarms',
          () async {
        // The regression this pins: the lookup used to read the `alarm`
        // table, which nothing writes. list_alarm_definitions answered "No
        // alarm definitions configured" on a plant running 45 of them.
        await insertAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Only In Preferences',
            description: 'Never written to the alarm table',
          ),
        ]);

        expect(await db.select(db.serverAlarm).get(), isEmpty);
        final alarms = await service.listAlarmDefinitions();
        expect(alarms, hasLength(1));
        expect(alarms.first['uid'], 'alarm-1');
      });

      test('returns nothing when no alarms are configured', () async {
        expect(await service.listAlarmDefinitions(), isEmpty);
      });
    });

    group('getAlarmConfig', () {
      test('returns the full config, rules included', () async {
        await insertAlarms([
          alarmJson(
            uid: 'alarm-1',
            key: 'pump3.temp',
            title: 'Pump 3 High Temperature',
            description: 'Temperature exceeds 80C',
            rules: [
              {
                'level': 'error',
                'expression': {
                  'value': {'formula': 'pump3.temp > 80'}
                },
                'acknowledgeRequired': true,
              },
            ],
          ),
        ]);

        final config = await service.getAlarmConfig('alarm-1');
        expect(config, isNotNull);
        expect(config!['uid'], 'alarm-1');
        expect(config['key'], 'pump3.temp');
        expect(config['title'], 'Pump 3 High Temperature');
        expect(config['description'], 'Temperature exceeds 80C');
        final rules = config['rules'] as List;
        expect(rules, hasLength(1));
        expect(
            rules.first['expression']['value']['formula'], 'pump3.temp > 80');
      });

      test('returns null for an unknown uid', () async {
        await insertAlarms([
          alarmJson(uid: 'alarm-1', title: 'One', description: 'Only one'),
        ]);

        expect(await service.getAlarmConfig('nope'), isNull);
      });

      test('an alarm without a key reads back with a null key', () async {
        await insertAlarms([
          alarmJson(uid: 'alarm-1', title: 'No Key', description: 'Keyless'),
        ]);

        final config = await service.getAlarmConfig('alarm-1');
        expect(config!['key'], isNull);
      });
    });

    group('findAlarmReferences', () {
      /// A page whose beacons watch specific alarm uids.
      final pagesWithBeacons = {
        'Home': {
          'menu_item': {'label': 'Home', 'path': '/'},
          'assets': [
            {
              'asset_name': 'AlarmVisibilityConfig',
              'alarm_uids': ['alarm-1'],
              'text': 'Line 1 beacon',
            },
            {
              'asset_name': 'AlarmVisibilityConfig',
              'alarm_uids': ['alarm-2', 'alarm-1'],
              'text': 'Combined beacon',
            },
            {
              'asset_name': 'ButtonConfig',
              'key': 'line1.start',
            },
          ],
        },
        'Line 2': {
          'menu_item': {'label': 'Line 2', 'path': '/line2'},
          'assets': [
            {
              'asset_name': 'AlarmVisibilityConfig',
              'alarm_uids': ['alarm-2'],
            },
          ],
        },
      };

      test('finds every asset that names the uid', () async {
        await insertPreference('page_editor_data', pagesWithBeacons);

        final refs = await service.findAlarmReferences('alarm-1');
        expect(refs, hasLength(2));
        expect(refs.every((r) => r['page'] == 'Home'), isTrue);
        expect(refs.map((r) => r['label']), contains('Line 1 beacon'));
      });

      test('reports the page each reference sits on', () async {
        await insertPreference('page_editor_data', pagesWithBeacons);

        final refs = await service.findAlarmReferences('alarm-2');
        expect(refs.map((r) => r['page']).toSet(), {'Home', 'Line 2'});
      });

      test('an unreferenced uid comes back empty', () async {
        await insertPreference('page_editor_data', pagesWithBeacons);

        expect(await service.findAlarmReferences('alarm-99'), isEmpty);
      });

      test('a beacon watching every alarm is not a reference', () async {
        // An empty alarm_uids list means "all alarms" -- it names no uid, so
        // deleting one does not leave it bound to nothing.
        await insertPreference('page_editor_data', {
          'Home': {
            'assets': [
              {'asset_name': 'AlarmVisibilityConfig', 'alarm_uids': <String>[]},
            ],
          },
        });

        expect(await service.findAlarmReferences('alarm-1'), isEmpty);
      });

      test('no page config at all is not an error', () async {
        expect(await service.findAlarmReferences('alarm-1'), isEmpty);
      });
    });
  });
}
