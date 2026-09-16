/// The one-shot adoption of hostname-scoped rows into `ConfigScope.local`.
///
/// The device-local store used to be scoped `station:<hostname>`, and in a
/// container the hostname is the container id — so an image update opened the
/// same file under a new, empty scope. These tests model exactly that: rows
/// under two made-up container ids, a store at the fixed scope, and the rules
/// that decide what the station comes up with.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';

/// Spelled out rather than imported, as in the import suite: a change to
/// either id changes whether every station adopts or imports again.
const String kAdoptionMarker = '_adopt.station_scopes_v1';
const String kImportMarker = '_import.shared_preferences_v1';

/// Two made-up container ids: the one commissioning ran under, and the one
/// the image update replaced it with.
final ConfigScope kOldContainer = ConfigScope.forStation('0a1b2c3d4e5f');
final ConfigScope kNewContainer = ConfigScope.forStation('f5e4d3c2b1a0');

final DateTime kCommissioned = DateTime.utc(2026, 9, 1, 8);
final DateTime kUpdated = DateTime.utc(2026, 9, 14, 12);

late AppDatabase db;
late SqlitePreferences prefs;

Future<void> seed(
  String id,
  Object value, {
  required ConfigScope scope,
  required DateTime at,
  int rev = 1,
  String kind = 'preference',
}) {
  final type = switch (value) {
    bool() => 'bool',
    int() => 'int',
    double() => 'double',
    String() => 'String',
    _ => throw ArgumentError(value),
  };
  return db.into(db.configItemTable).insert(
        ConfigItemTableCompanion.insert(
          kind: kind,
          id: id,
          scope: scope.wireName,
          payload: ConfigItem.of(
            kind: ConfigKind.preference,
            id: id,
            value: {'type': type, 'value': value},
          ).payload,
          rev: Value(rev),
          updatedAt: at,
          updatedBy: 'anonymous',
        ),
      );
}

Future<List<ConfigItemRow>> itemsAt(ConfigScope scope) =>
    (db.select(db.configItemTable)
          ..where((t) => t.scope.equals(scope.wireName)))
        .get();

Future<List<ConfigItemRow>> allItems() => db.select(db.configItemTable).get();

Future<List<ConfigChangeRow>> changes() =>
    db.select(db.configChangeTable).get();

/// What the station's first boot on the old build left behind, then what the
/// first boot after the update added under the new container id.
Future<void> seedTwoContainers() async {
  await seed('theme_mode', 'dark', scope: kOldContainer, at: kCommissioned);
  await seed('startup_url', '/line1', scope: kOldContainer, at: kCommissioned);
  await seed(kImportMarker, '2026-09-01T08:00:00.000',
      scope: kOldContainer, at: kCommissioned);
  await seed('last_route', '/overview',
      scope: kOldContainer, at: kCommissioned, rev: 7);
  await seed('_sync.key_mappings.watermark', 120,
      scope: kOldContainer, at: kCommissioned, rev: 40);

  // The new container found an empty scope, imported again, and was used.
  await seed(kImportMarker, '2026-09-14T12:00:00.000',
      scope: kNewContainer, at: kUpdated);
  await seed('last_route', '/alarms', scope: kNewContainer, at: kUpdated);
  await seed('access.session', '{"user":"operator"}',
      scope: kNewContainer, at: kUpdated);
  await seed('_sync.key_mappings.watermark', 131,
      scope: kNewContainer, at: kUpdated, rev: 3);
}

void main() {
  setUp(() {
    db = AppDatabase.inMemoryForTest();
    prefs = SqlitePreferences(db, scope: ConfigScope.local, station: 'host-a');
  });

  tearDown(() => db.close());

  group('rows under two container ids', () {
    setUp(seedTwoContainers);

    test('are all readable at the fixed scope afterwards', () async {
      final adoption =
          await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      expect(adoption, isNotNull);
      expect(await prefs.getString('theme_mode'), 'dark',
          reason: 'commissioned under the old container, never touched since');
      expect(await prefs.getString('startup_url'), '/line1');
      expect(await prefs.getString('access.session'), '{"user":"operator"}',
          reason: 'only ever written under the new container');
    });

    test('the newest updated_at wins where both have the key', () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      expect(await prefs.getString('last_route'), '/alarms',
          reason: 'the new container wrote it last, although the old copy '
              'had the higher rev');
    });

    test('the winner keeps its timestamps and the highest rev of any copy',
        () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      final route = (await itemsAt(ConfigScope.local))
          .singleWhere((r) => r.id == 'last_route');
      expect(route.updatedAt, kUpdated);
      expect(route.rev, 7, reason: 'a rev never goes backwards');
    });

    test('the sync watermark is the newest one, not the largest', () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      final watermark = (await itemsAt(ConfigScope.local))
          .singleWhere((r) => r.id == '_sync.key_mappings.watermark');
      expect(watermark.payload, contains('131'));
      expect(watermark.rev, 40);
    });

    test('nothing is left under either container id', () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      expect(await itemsAt(kOldContainer), isEmpty);
      expect(await itemsAt(kNewContainer), isEmpty);
      expect(
        (await itemsAt(ConfigScope.local)).map((r) => r.id).toSet(),
        {
          'theme_mode',
          'startup_url',
          'last_route',
          'access.session',
          kImportMarker,
          '_sync.key_mappings.watermark',
          kAdoptionMarker,
        },
      );
    });

    test('it reports what came from where', () async {
      final adoption =
          (await prefs.adoptStationScopes(markerId: kAdoptionMarker))!;

      expect(adoption.rowsFrom, {
        kOldContainer.wireName: 5,
        kNewContainer.wireName: 4,
      });
      expect(adoption.adopted, 6, reason: 'six distinct ids');
      expect(adoption.superseded, 3,
          reason: 'import marker, last_route and watermark each had a loser');
      expect(adoption.toString(), contains(kOldContainer.wireName));
    });

    test('the legacy import does not run again afterwards', () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      final imported = await prefs.importAll(
        {'theme_mode': 'light', 'startup_url': '/stale'},
        markerId: kImportMarker,
      );

      expect(imported, isFalse);
      expect(await prefs.getString('theme_mode'), 'dark');
    });

    test('it writes no change rows', () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      expect(await changes(), isEmpty,
          reason: 'moving a row between scopes is not an edit');
    });

    test('a second run is a no-op', () async {
      await prefs.adoptStationScopes(markerId: kAdoptionMarker);
      final before = await allItems();

      final again = await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      expect(again, isNull);
      expect(await allItems(), before);
    });
  });

  group('the rows already at the fixed scope', () {
    test('keep a value newer than any hostname copy', () async {
      await seed('startup_url', '/old',
          scope: kOldContainer, at: kCommissioned);
      await seed('startup_url', '/current',
          scope: ConfigScope.local, at: kUpdated);

      final adoption =
          (await prefs.adoptStationScopes(markerId: kAdoptionMarker))!;

      expect(await prefs.getString('startup_url'), '/current');
      expect(adoption.adopted, 0);
      expect(adoption.superseded, 1);
      expect(await itemsAt(kOldContainer), isEmpty);
    });

    test('lose to a newer hostname copy', () async {
      await seed('startup_url', '/older',
          scope: ConfigScope.local, at: kCommissioned, rev: 2);
      await seed('startup_url', '/newer', scope: kOldContainer, at: kUpdated);

      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      final rows = await itemsAt(ConfigScope.local);
      final url = rows.singleWhere((r) => r.id == 'startup_url');
      expect(await prefs.getString('startup_url'), '/newer');
      expect(url.rev, 2);
    });

    test('win a tie', () async {
      await seed('startup_url', '/here',
          scope: ConfigScope.local, at: kUpdated);
      await seed('startup_url', '/there',
          scope: kOldContainer, at: kUpdated, rev: 9);

      await prefs.adoptStationScopes(markerId: kAdoptionMarker);

      expect(await prefs.getString('startup_url'), '/here');
    });
  });

  group('what is not adopted', () {
    test('shared rows and other kinds stay where they are', () async {
      await seed('alarm_man_config', '{}',
          scope: ConfigScope.shared, at: kCommissioned);
      await seed('conveyor_a', 'x',
          scope: kOldContainer, at: kCommissioned, kind: 'asset');

      final adoption =
          (await prefs.adoptStationScopes(markerId: kAdoptionMarker))!;

      expect(adoption.rowsTaken, 0);
      expect(await itemsAt(ConfigScope.shared), hasLength(1));
      expect(await itemsAt(kOldContainer), hasLength(1));
    });
  });

  group('a fresh database', () {
    test('adopts nothing, writes the marker, and still imports', () async {
      final adoption =
          (await prefs.adoptStationScopes(markerId: kAdoptionMarker))!;

      expect(adoption.rowsTaken, 0);
      expect((await allItems()).single.id, kAdoptionMarker);
      expect(await prefs.getKeys(), isEmpty,
          reason: 'the marker is bookkeeping, not a preference');

      final imported = await prefs
          .importAll({'theme_mode': 'dark'}, markerId: kImportMarker);
      expect(imported, isTrue);
      expect(await prefs.getString('theme_mode'), 'dark');
    });
  });

  group('the station name', () {
    test('stamps change rows and plays no part in which rows are read',
        () async {
      await prefs.setString('theme_mode', 'dark');

      final renamed =
          SqlitePreferences(db, scope: ConfigScope.local, station: 'host-b');
      expect(await renamed.getString('theme_mode'), 'dark');

      await renamed.setString('theme_mode', 'light');
      expect((await changes()).map((c) => c.station).toList(),
          ['host-a', 'host-b']);
    });

    test('defaults to the scope name when none is given', () async {
      final plain = SqlitePreferences(db, scope: kOldContainer);
      await plain.setBool('flag', true);

      expect((await changes()).single.station, '0a1b2c3d4e5f');
    });
  });
}
