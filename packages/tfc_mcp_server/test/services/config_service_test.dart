import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import '../helpers/config_rows.dart';
import '../helpers/test_database.dart';

void main() {
  group('ConfigService', () {
    late ServerDatabase db;
    late ConfigService service;

    /// Three pages, as the rows store them: keyed by the page's stable id,
    /// with the path the pages map keys on living inside `menu_item`.
    ///
    /// The old blob fixture keyed these 'overview' / 'conveyor' / 'mixer'.
    /// The real `page_editor_data` never did -- `PageManager.pagesFromJson`
    /// keys by `menu_item.path` -- so the paths below are what a plant
    /// actually holds, and the `key` field each page carries is what keeps
    /// [ConfigService.listPages]'s output byte-identical to the blob era.
    final pageRows = {
      'page-overview': {
        'title': 'Overview',
        'key': 'overview',
        'menu_item': {'label': 'Overview', 'path': '/overview'},
        'widgets': [
          {'type': 'gauge', 'key': 'pump3.speed'},
        ],
      },
      'page-conveyor': {
        'title': 'Conveyor Control',
        'key': 'conveyor',
        'menu_item': {'label': 'Conveyor', 'path': '/conveyor'},
        'widgets': [
          {'type': 'display', 'key': 'conveyor.speed'},
        ],
      },
      'page-mixer': {
        'title': 'Mixer Station',
        'key': 'mixer',
        'menu_item': {'label': 'Mixer', 'path': '/mixer'},
        'widgets': [],
      },
    };

    /// Sample key mappings with OPC UA entries.
    ///
    /// Every value here has to be one the codec accepts. Reading the blob was
    /// a bare `jsonDecode` and validated nothing, so the fixture carried a
    /// truncated `collect` entry and a `record_type` of `BATCH` that no
    /// enum has; reading the rows goes through `KeyMappingEntry.fromJson`,
    /// which is the free validation the codec was adopted for.
    final keyMappings = {
      'nodes': {
        'pump3.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Speed'},
        },
        'pump3.current': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Current'},
        },
        'conveyor.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Conv.Speed'},
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
            'record_type': 'recBatch',
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

    /// `config_item` the way a real database gets it.
    ///
    /// It is created by tfc_dart's migration and is deliberately not part of
    /// `ServerDatabase`'s drift schema -- one physical table, two Dart
    /// schemas over it, which is the whole reason the readers in
    /// `page_rows.dart` take a `GeneratedDatabase` and attach the table to
    /// it. Tests that want the un-migrated database simply do not call this.
    Future<void> createConfigItemTable() => db.customStatement(
        'CREATE TABLE IF NOT EXISTS config_item (kind TEXT NOT NULL, '
        'id TEXT NOT NULL, scope TEXT NOT NULL, parent_id TEXT, '
        'sort_index INTEGER, payload TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL, '
        'updated_by TEXT NOT NULL, PRIMARY KEY (kind, id, scope))');

    Future<void> insertRow({
      required String kind,
      required String id,
      required Map<String, dynamic> payload,
      String scope = 'shared',
      String? parentId,
      int? sortIndex,
    }) =>
        db.customStatement(
          'INSERT INTO config_item (kind, id, scope, parent_id, sort_index, '
          'payload, rev, updated_at, updated_by) '
          'VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)',
          [
            kind,
            id,
            scope,
            parentId,
            sortIndex,
            jsonEncode(payload),
            '2026-09-07T00:00:00Z',
            'tester',
          ],
        );

    /// One page and its top-level assets, split the way `page_codec.dart`
    /// splits them: the page's own JSON in the page row, one asset row per
    /// entry of its `assets` list carrying the page's id and its position.
    Future<void> insertPage(String id, Map<String, dynamic> page) async {
      final assets = (page['assets'] as List?) ?? const [];
      await insertRow(
        kind: 'page',
        id: id,
        payload: {...page}..remove('assets'),
      );
      for (var index = 0; index < assets.length; index++) {
        await insertRow(
          kind: 'asset',
          id: '$id/asset-$index',
          parentId: id,
          sortIndex: index,
          payload: assets[index] as Map<String, dynamic>,
        );
      }
    }

    /// A blob-shaped `{'nodes': {...}}` fixture as the rows that replaced it:
    /// one `key_mapping` row per key, the entry as its payload.
    Future<void> insertMappings(Map<String, dynamic> blob) async {
      await createConfigItemTable();
      final nodes = blob['nodes'] as Map<String, dynamic>;
      for (final entry in nodes.entries) {
        await insertRow(
          kind: 'key_mapping',
          id: entry.key,
          payload: entry.value as Map<String, dynamic>,
        );
      }
    }

    /// Every page of [pages], into a database that has the table.
    Future<void> insertPages(Map<String, Map<String, dynamic>> pages) async {
      await createConfigItemTable();
      for (final entry in pages.entries) {
        await insertPage(entry.key, entry.value);
      }
    }

    tearDown(() async {
      await db.close();
    });

    /// Seeds the retired blob, into a table this package no longer has a
    /// drift schema for -- so the DDL comes from the helper, the way a plant
    /// that has not yet run the drop tool still has it.
    Future<void> insertPreference(String key, dynamic value) =>
        insertFlutterPreferenceRow(db, key: key, value: value);

    /// Seeds the alarm definitions the way the app really stores them.
    ///
    /// AlarmMan keeps its whole config in the `alarm_man_config` preference
    /// and never writes the `alarm` table, so a test that seeds the table
    /// proves nothing about the alarms an operator can actually see.
    Future<void> insertAlarms(List<Map<String, dynamic>> alarms) async {
      await createConfigItemTable();
      // The envelope production writes, never the bare document — see
      // `seedPreferenceRow` in helpers/config_rows.dart for why.
      await insertRow(
        kind: 'preference',
        id: 'alarm_man_config',
        payload: {
          'type': 'String',
          'value': jsonEncode({'alarms': alarms}),
        },
      );
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
      test('returns page key+title summaries from the page rows', () async {
        await insertPages(pageRows);

        final pages = await service.listPages();

        expect(pages, hasLength(3));
        // Should contain key and title for each page
        final keys = pages.map((p) => p['key']).toSet();
        expect(keys, containsAll(['overview', 'conveyor', 'mixer']));
        final titles = pages.map((p) => p['title']).toSet();
        expect(titles, containsAll(
            ['Overview', 'Conveyor Control', 'Mixer Station']));
      });

      test('returns empty list when there are no page rows', () async {
        await createConfigItemTable();
        final pages = await service.listPages();
        expect(pages, isEmpty);
      });

      test('returns empty list when config_item does not exist at all',
          () async {
        // A ServerDatabase opened against a database tfc_dart has not
        // migrated yet. Failing here would take out `list_pages` in order to
        // report a table that is about to exist.
        final pages = await service.listPages();
        expect(pages, isEmpty);
      });

      test('does not answer from the blob once the blob is all there is',
          () async {
        // The fallback this plan deleted. `page_editor_data` is a frozen copy
        // after the cutover, and an operator reading a layout that stopped
        // being updated cannot tell that is what happened -- so the honest
        // answer to "no rows" is nothing, not the blob.
        await insertPreference('page_editor_data', {
          'stale': {'key': 'stale', 'title': 'From the blob'},
        });

        expect(await service.listPages(), isEmpty);
        expect(await service.listAssets(), isEmpty);
        expect(await service.getAssetDetail('stale'), isNull);
        expect(await service.findAlarmReferences('alarm-1'), isEmpty);
      });

      test('respects limit parameter', () async {
        await insertPages(pageRows);

        final pages = await service.listPages(limit: 2);
        expect(pages, hasLength(2));
      });
    });

    group('listAssets', () {
      test('returns asset summaries from the page rows', () async {
        await insertPages(pageRows);

        final assets = await service.listAssets();

        expect(assets, hasLength(3));
        final keys = assets.map((a) => a['key']).toSet();
        expect(keys, containsAll(['overview', 'conveyor', 'mixer']));
      });

      test('returns empty list when no data exists', () async {
        await createConfigItemTable();
        final assets = await service.listAssets();
        expect(assets, isEmpty);
      });
    });

    group('getAssetDetail', () {
      test('returns full page config for given page key', () async {
        await insertPages(pageRows);

        final detail = await service.getAssetDetail('/overview');

        expect(detail, isNotNull);
        expect(detail!['key'], equals('overview'));
        expect(detail['title'], equals('Overview'));
        // The payload is passed through untouched: a field the rows know
        // nothing about survives the round trip, which is what makes the wire
        // shape the blob's and not the row schema's.
        expect(detail['widgets'], isList);
        expect((detail['widgets'] as List), hasLength(1));
      });

      test('reassembles a page\'s assets, in paint order', () async {
        // The row shape's whole point: the assets are separate rows, and
        // get_asset_detail has to put them back where they were.
        await insertPages({
          'page-line1': {
            'title': 'Line 1',
            'menu_item': {'label': 'Line 1', 'path': '/line1'},
            'assets': [
              {'asset_name': 'ButtonConfig', 'text': 'first'},
              {'asset_name': 'ButtonConfig', 'text': 'second'},
            ],
          },
        });

        final detail = await service.getAssetDetail('/line1');

        final assets = detail!['assets'] as List;
        expect([for (final a in assets) (a as Map)['text']],
            ['first', 'second']);
      });

      test('a page with no assets reads back with an empty list', () async {
        await insertPages(pageRows);

        final detail = await service.getAssetDetail('/mixer');
        expect(detail!['assets'], isEmpty);
      });

      test('returns null for nonexistent page key', () async {
        await insertPages(pageRows);

        final detail = await service.getAssetDetail('nonexistent');
        expect(detail, isNull);
      });
    });

    group('listKeyMappings', () {
      test('returns OPC UA key-to-node pairs from the key_mapping rows',
          () async {
        await insertMappings(keyMappings);

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

      test('returns empty list when no key_mapping rows exist', () async {
        await createConfigItemTable();
        final mappings = await service.listKeyMappings();
        expect(mappings, isEmpty);
      });

      test('respects limit parameter', () async {
        await insertMappings(keyMappings);

        final mappings = await service.listKeyMappings(limit: 2);
        expect(mappings, hasLength(2));
      });

      test('supports fuzzy filter', () async {
        await insertMappings(keyMappings);

        final mappings = await service.listKeyMappings(filter: 'pump');
        expect(mappings, hasLength(2));
        for (final m in mappings) {
          expect((m['key'] as String).toLowerCase(), contains('pump'));
        }
      });

      test('returns modbus mappings with register info', () async {
        await insertMappings(mixedKeyMappings);

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
        await insertMappings(mixedKeyMappings);

        final mappings = await service.listKeyMappings(filter: 'weigher');
        expect(mappings, hasLength(1));
        final m = mappings.first;
        expect(m['key'], equals('weigher.batch'));
        expect(m['protocol'], equals('m2400'));
        expect(m['record_type'], equals('recBatch'));
        expect(m['field'], equals('weight'));
        expect(m['server_alias'], equals('jbtm1'));
      });

      test('returns multiple mappings for dual-protocol keys', () async {
        await insertMappings(mixedKeyMappings);

        final mappings = await service.listKeyMappings(filter: 'pump3.dual');
        expect(mappings, hasLength(2));
        final protocols = mappings.map((m) => m['protocol']).toSet();
        expect(protocols, containsAll(['opcua', 'modbus']));
      });

      test('returns all protocols in mixed key_mappings', () async {
        await insertMappings(mixedKeyMappings);

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
      Future<void> insertMappingRow(
        String id,
        Map<String, dynamic> payload, {
        String scope = 'shared',
        String kind = 'key_mapping',
      }) =>
          insertRow(kind: kind, id: id, payload: payload, scope: scope);

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

      test('answers nothing, not the blob, while the migration has not run',
          () async {
        // The read-side fallback this plan deleted. It was right while the
        // blob was still being written; after the cutover the blob is a
        // frozen copy, and an access template written against a key set that
        // stopped being updated is a rule that does not cover the wiring it
        // was meant to cover. Empty is the answer an operator can act on.
        await createConfigItemTable();
        await insertPreference('key_mappings', keyMappings);

        expect(await service.listKeyMappings(), isEmpty);
      });

      test('answers nothing when config_item does not exist at all', () async {
        // A ServerDatabase opened against a database tfc_dart has not
        // migrated yet. Empty rather than a thrown error: failing here would
        // take out `list_key_mappings` and every access template tool built
        // on it, to report a table that is about to be created.
        await insertPreference('key_mappings', keyMappings);

        expect(await service.listKeyMappings(), isEmpty);
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
        await createConfigItemTable();
        expect(await service.listAlarmDefinitions(), isEmpty);
      });

      test('returns nothing against an unmigrated database', () async {
        // 04-11 migrates the preferences. Until it has, `alarm_man_config`
        // has no row and this is the same answer a missing key always gave --
        // which is what makes a caller that reads null as "not configured"
        // right on both sides of the cutover.
        expect(await service.listAlarmDefinitions(), isEmpty);
        expect(await service.getAlarmConfig('alarm-1'), isNull);
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
        'page-home': {
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
        'page-line2': {
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
        await insertPages(pagesWithBeacons);

        final refs = await service.findAlarmReferences('alarm-1');
        expect(refs, hasLength(2));
        expect(refs.every((r) => r['page'] == '/'), isTrue,
            reason: 'the page is named by the path in its payload, which is '
                'what the blob keyed on too');
        expect(refs.map((r) => r['label']), contains('Line 1 beacon'));
      });

      test('reports the page each reference sits on', () async {
        await insertPages(pagesWithBeacons);

        final refs = await service.findAlarmReferences('alarm-2');
        expect(refs.map((r) => r['page']).toSet(), {'/', '/line2'});
      });

      test('an unreferenced uid comes back empty', () async {
        await insertPages(pagesWithBeacons);

        expect(await service.findAlarmReferences('alarm-99'), isEmpty);
      });

      test('a beacon watching every alarm is not a reference', () async {
        // An empty alarm_uids list means "all alarms" -- it names no uid, so
        // deleting one does not leave it bound to nothing.
        await insertPages({
          'page-home': {
            'menu_item': {'label': 'Home', 'path': '/'},
            'assets': [
              {'asset_name': 'AlarmVisibilityConfig', 'alarm_uids': <String>[]},
            ],
          },
        });

        expect(await service.findAlarmReferences('alarm-1'), isEmpty);
      });

      test('no page rows at all is not an error', () async {
        await createConfigItemTable();
        expect(await service.findAlarmReferences('alarm-1'), isEmpty);
      });

      test('an unmigrated database is not an error either', () async {
        expect(await service.findAlarmReferences('alarm-1'), isEmpty);
      });
    });
  });

  group('ConfigService.checkConsistency', () {
    // The service half of the production arm: what the MCP tool calls. The
    // check's own semantics are proven in tfc_dart
    // (`test/core/config/config_consistency_test.dart` plants one violation
    // per invariant, including the position-only divergence a payload
    // comparison cannot see); what matters here is that it reaches the
    // database this service was handed, and that an unreadable database is an
    // error rather than an empty list.
    late ServerDatabase db;
    late ConfigService service;

    setUp(() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');
      service = ConfigService(db);
    });

    tearDown(() => db.close());

    test('answers with the violations it finds', () async {
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      await insertConfigRow(db,
          kind: 'asset',
          id: 'a1',
          parentId: 'page-gone',
          sortIndex: 2,
          payload: {'asset_name': 'lamp'});
      await insertConfigChangeRow(db,
          kind: 'asset',
          id: 'a1',
          newValue: entityOf({'asset_name': 'lamp'},
              parentId: 'page-gone', sortIndex: 0));

      final found = await service.checkConsistency();

      // The orphan, and the position the log disagrees about — the payload is
      // identical on both sides.
      expect(found.map((v) => v.invariant.wireName),
          ['orphaned_parent', 'entity_disagrees']);
    });

    test('is silent on a consistent database', () async {
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      await insertConfigRow(db,
          kind: 'key_mapping', id: 'CN01.RUN', payload: {'ns': 4});
      await insertConfigChangeRow(db,
          kind: 'key_mapping', id: 'CN01.RUN', newValue: entityOf({'ns': 4}));

      expect(await service.checkConsistency(), isEmpty);
    });

    test('throws on an unmigrated database rather than reporting it clean',
        () async {
      // Every other read in this class swallows this. A check must not: the
      // caller has to be able to tell "nothing is wrong" from "I read
      // nothing".
      expect(service.checkConsistency(), throwsA(anything));
    });
  });
}
