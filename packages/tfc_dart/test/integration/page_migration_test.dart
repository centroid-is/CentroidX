// The pages blob→rows migration against a real Postgres: the advisory lock,
// the idempotency gate, and the round trip through actual rows.
//
// These are the four things the cheap lane cannot prove, because sqlite has no
// advisory locks, cannot lose a race, and does not have an int4 `sort_index`:
//
//   1. a second station running the migration at the same moment writes
//      nothing and does not wait;
//   2. the transaction-scoped lock is released by drift's emulated COMMIT and
//      ROLLBACK, so the loser's next attempt succeeds (research assumption A2);
//   3. a copy interrupted mid-transaction leaves no rows and no marker, and the
//      re-run is clean — what a station losing power mid-boot does;
//   4. every page, asset, parent id and ordering key comes back out through the
//      real TEXT and INTEGER columns — including keys at the 90112 scale a page
//      of ninety assets produces, which is C-7's only executable check.
//
// THE FIXTURE, AND WHY IT IS NOT ASSEMBLED HERE: page payloads are what the
// page codec emits, and the codec needs `AssetPage`, which needs Flutter, which
// this package deliberately does not have. A payload written by hand here would
// be structurally different from the model's encoding (explicit nulls for unset
// optionals) and would prove the opposite of what property 4 claims. So
// `fixtures/page_blob_fixture.json` is *generated* by the app-side test
// `test/core/config/page_migration_test.dart`, which fails the moment it stops
// matching what the codec produces today, with the regeneration command in the
// failure message:
//
//     CENTROIDX_REGEN_FIXTURES=1 flutter test test/core/config/page_migration_test.dart
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Two checkouts running integration
// suites at once bind the same ports and each `setUpAll` tears the other's
// database down mid-run — the symptom is connection resets that read exactly
// like a resilience regression. Run integration tests in one worktree at a
// time.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/blob_migration.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show kPagesMigratedMarkerId;
import 'package:tfc_dart/core/config/sort_keys.dart';
import 'package:tfc_dart/core/database.dart';

import 'docker_compose.dart';

/// `PageManager.storageKey`, which lives in the app for the same reason the
/// codec does. Named here rather than imported; the app-side test seeds the
/// same constant, and a change to it fails that test's own seeding first.
const String _pagePrefKey = 'page_editor_data';

/// Thrown inside the copy to stand in for the station losing power.
class _PowerCut implements Exception {}

/// The generated fixture: the blob a station would hold, and the items the
/// codec makes of it.
class _Fixture {
  _Fixture(File file) : this._(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);

  _Fixture._(Map<String, dynamic> json)
      : blob = json['blob'] as String,
        items = [
          for (final raw in json['items'] as List<dynamic>)
            ConfigItem(
              kind: ConfigKind.byWireName((raw as Map)['kind'] as String)!,
              id: raw['id'] as String,
              scope: ConfigScope.byWireName(raw['scope'] as String)!,
              parentId: raw['parent_id'] as String?,
              sortIndex: (raw['sort_index'] as num?)?.toInt(),
              payload: raw['payload'] as String,
            )
        ];

  final String blob;
  final List<ConfigItem> items;
}

void main() {
  final fixture = _Fixture(
      File('test/integration/fixtures/page_blob_fixture.json'));

  /// The parser the app injects, standing in: it asserts it was handed the
  /// blob that produced these items and then returns them, so what reaches the
  /// rows is codec output and nothing else.
  List<ConfigItem> parseFixture(String blob) {
    expect(blob, fixture.blob,
        reason: 'the migration read a different blob than the fixture was '
            'generated from');
    return fixture.items;
  }

  Future<MigrationOutcome> migrate(Database database,
          {BlobParser? parse}) =>
      copyBlobIntoRows(
        database.db,
        prefKey: _pagePrefKey,
        markerId: kPagesMigratedMarkerId,
        lockId: kPageMigrationLock,
        kinds: const {ConfigKind.page, ConfigKind.asset},
        parse: parse ?? parseFixture,
        label: 'pages',
      );

  group('pages migration against Postgres', () {
    late Database database;

    /// A second connection, standing in for another station: it seeds, it
    /// counts, and it holds the lock. Assertions must not ride the connection
    /// under test.
    late pg.Connection other;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      database = await connectToDatabase();
      other = await getTestConnection();
    });

    tearDownAll(() async {
      await other.close();
      await database.close();
      await stopDockerCompose();
    });

    Future<int> scalar(String sql) async {
      final result = await other.execute(sql);
      return (result.first.first! as num).toInt();
    }

    Future<int> itemCount({String? kind}) => scalar(
        'SELECT count(*) FROM config_item'
        "${kind == null ? '' : " WHERE kind = '$kind'"}");
    Future<int> changeCount() => scalar('SELECT count(*) FROM config_change');
    Future<int> maxRev() =>
        scalar('SELECT coalesce(max(rev), 0) FROM config_item');
    Future<int> markerCount() => scalar('SELECT count(*) FROM config_item '
        "WHERE kind = 'preference' AND id = '$kPagesMigratedMarkerId'");

    Future<void> seed(String value) async {
      await other.execute(
        pg.Sql.named('INSERT INTO flutter_preferences (key, value, type) '
            "VALUES (@key, @value, 'String') "
            'ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value'),
        parameters: {'key': _pagePrefKey, 'value': value},
      );
    }

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
      await other.execute(
          pg.Sql.named('DELETE FROM flutter_preferences WHERE key = @key'),
          parameters: {'key': _pagePrefKey});
      await seed(fixture.blob);
    });

    test('a station that loses the lock writes nothing, and does not wait',
        () async {
      // Another station, mid-copy. The session-level form is what a *test* may
      // hold across statements; the migration itself must never use it.
      await other.execute('SELECT pg_advisory_lock($kConfigLockNamespace, '
          '$kPageMigrationLock)');

      final start = DateTime.now();
      expect(await migrate(database), MigrationOutcome.heldByAnother);
      expect(DateTime.now().difference(start),
          lessThan(const Duration(seconds: 5)),
          reason: 'try-lock returns false immediately; a station that waited '
              'would stall its own boot behind another station');
      expect(await itemCount(), 0);
      expect(await changeCount(), 0);

      await other.execute('SELECT pg_advisory_unlock($kConfigLockNamespace, '
          '$kPageMigrationLock)');

      // A2: the loser's own xact lock from the failed attempt was released by
      // drift's COMMIT, so this attempt is not blocked by its own predecessor.
      expect(await migrate(database), MigrationOutcome.migrated);
      expect(await itemCount(kind: 'page'),
          fixture.items.where((i) => i.kind == ConfigKind.page).length);
      expect(await itemCount(kind: 'asset'),
          fixture.items.where((i) => i.kind == ConfigKind.asset).length);
      expect(await changeCount(), fixture.items.length);
      expect(await markerCount(), 1);
    });

    test('the key-mappings lock does not block the pages migration', () async {
      // Two lock ids under one namespace, and this is what they buy: a station
      // mid-way through the key-mappings migration does not make every other
      // station skip the pages one.
      await other.execute('SELECT pg_advisory_lock($kConfigLockNamespace, 1)');
      expect(await migrate(database), MigrationOutcome.migrated);
      await other
          .execute('SELECT pg_advisory_unlock($kConfigLockNamespace, 1)');
    });

    test('a second run reports alreadyDone, bumps no rev and logs nothing',
        () async {
      expect(await migrate(database), MigrationOutcome.migrated);
      final items = await itemCount();
      final changes = await changeCount();
      final rev = await maxRev();

      expect(await migrate(database), MigrationOutcome.alreadyDone);

      expect(await itemCount(), items);
      expect(await changeCount(), changes);
      expect(await maxRev(), rev,
          reason: 'a re-run that bumped a rev would make every other station '
              'believe the layout had changed and redraw every mimic');
    });

    test('the blob row survives the migration', () async {
      await migrate(database);

      final row = await other.execute(
        pg.Sql.named('SELECT value FROM flutter_preferences WHERE key = @key'),
        parameters: {'key': _pagePrefKey},
      );
      expect(row, hasLength(1),
          reason: 'the blob is the rollback insurance for the cutover, and '
              'what the svn tools still read; Phase 4 drops it, not this');
      expect(row.first.first, fixture.blob);
    });

    test('a copy interrupted mid-transaction leaves nothing behind, and the '
        'next run is clean', () async {
      // The copy runs to completion and the transaction is then abandoned —
      // which is what a station losing power mid-boot leaves the server with:
      // an implicit ROLLBACK, no rows, no marker.
      await expectLater(
        database.db.transaction(() async {
          await copyBlobIntoRowsLocked(
            database.db,
            prefKey: _pagePrefKey,
            markerId: kPagesMigratedMarkerId,
            kinds: const {ConfigKind.page, ConfigKind.asset},
            parse: parseFixture,
            label: 'pages',
          );
          throw _PowerCut();
        }),
        throwsA(isA<_PowerCut>()),
      );
      expect(await itemCount(), 0);
      expect(await changeCount(), 0);
      expect(await markerCount(), 0,
          reason: 'a marker that outlived its rows would leave the plant '
              'permanently unmigrated and believing otherwise');

      expect(await migrate(database), MigrationOutcome.migrated);
      expect(await itemCount(), fixture.items.length + 1);
    });

    test('a parse that throws is the same story, told by the blob', () async {
      await expectLater(
        migrate(database,
            parse: (_) => throw const FormatException('unreadable layout')),
        throwsA(isA<FormatException>()),
      );
      expect(await itemCount(), 0);
      expect(await markerCount(), 0);

      expect(await migrate(database), MigrationOutcome.migrated);
    });

    /// The migrated rows, read back as items the way a reconcile reads them.
    Future<List<ConfigItem>> storedItems() async {
      final rows = await other.execute(
          'SELECT kind, id, payload, parent_id, sort_index FROM config_item '
          "WHERE kind IN ('page', 'asset') AND scope = 'shared'");
      return [
        for (final row in rows)
          ConfigItem(
            kind: ConfigKind.byWireName(row[0]! as String)!,
            id: row[1]! as String,
            payload: row[2]! as String,
            parentId: row[3] as String?,
            sortIndex: (row[4] as num?)?.toInt(),
          )
      ];
    }

    test('every page and asset comes back out of the rows unchanged',
        () async {
      expect(await migrate(database), MigrationOutcome.migrated);

      final stored = {for (final i in await storedItems()) i.id: i};
      final expected = {
        for (final i in assignSortKeys(fixture.items, const {})) i.id: i
      };

      expect(stored.keys.toSet(), expected.keys.toSet());
      for (final id in expected.keys) {
        final got = stored[id]!, want = expected[id]!;
        expect(got.kind, want.kind, reason: id);
        expect(got.payload, want.payload,
            reason: 'the TEXT column changed the payload of $id — every '
                'station would diff this row as an edit nobody made');
        expect(got.parentId, want.parentId,
            reason: 'an asset whose parent did not survive is an asset that '
                'is not drawn on any page ($id)');
        expect(got.sortIndex, want.sortIndex, reason: id);
      }

      // Pages carry no ordinal, and a null key must come back null rather
      // than as a zero that would repaint the page in a new order.
      expect(
          stored.values
              .where((i) => i.kind == ConfigKind.page)
              .every((i) => i.sortIndex == null),
          isTrue);
    });

    test('ordering keys at the scale a real page reaches survive int4',
        () async {
      // C-7: `sort_index` is a literal `INTEGER` in the Postgres DDL, and the
      // busiest SVN page carries about ninety assets — key 92160 at gap 1024.
      // Payloads are the fixture's, verbatim: what varies is the id and the
      // ordinal, which is exactly what this property is about.
      final template =
          fixture.items.firstWhere((i) => i.kind == ConfigKind.asset);
      final page = fixture.items.firstWhere((i) => i.kind == ConfigKind.page);
      const count = 90;
      final many = <ConfigItem>[
        page,
        for (var i = 0; i < count; i++)
          ConfigItem(
            kind: ConfigKind.asset,
            id: 'asset-${i.toString().padLeft(3, '0')}',
            payload: template.payload,
            parentId: page.id,
            sortIndex: i,
          ),
      ];

      expect(await migrate(database, parse: (_) => many),
          MigrationOutcome.migrated);

      final keys = (await storedItems())
          .where((i) => i.kind == ConfigKind.asset)
          .map((i) => i.sortIndex!)
          .toList()
        ..sort();
      expect(keys, [for (var i = 0; i < count; i++) (i + 1) * kSortKeyGap]);
      expect(keys.last, count * kSortKeyGap);
      expect(keys.last, greaterThan(90000),
          reason: 'the scale C-7 is about: a five-digit ordering key stored '
              'in an int4 column, read back as the same integer');
    });
  });
}
