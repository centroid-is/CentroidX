/// The eleven history-view methods against a **real TimescaleDB** — the second
/// `db`-tagged leg.
///
/// 8b's `db` lane, not a third one: the same tag, the same env-addressed
/// fixture, the same CI step, exactly as `timeseries_read_test.dart` joined it.
///
/// ## Why these cases need a real server and cannot be faked
///
/// Every one of the four mismatches this file exists to pin is a property of
/// what the *database* does with a value, not of what the store does with a
/// row:
///
///  * a `DateTime` written as `timestamp with time zone` and read back — the
///    microseconds and the `isUtc` flag are the database driver's answer, and
///    a fake would answer whatever the fake's author expected;
///  * `ON DELETE CASCADE` on three foreign keys, which is why upstream's
///    four-statement delete has not yet left a half-deleted view behind;
///  * `timescaledb_information.jobs`, which only exists where TimescaleDB does
///    and is the whole subject of the retention horizon;
///  * a `text` column that is NULL versus one holding the empty string, which
///    is a distinction only the server can be asked about.
///
/// ## Cleanup, and why it is by id rather than by table
///
/// The timeseries leg gives every *table* a per-run suffix. It cannot be done
/// here: the four history tables are named by drift's schema, shared with the
/// application's own HMI and with any 8b case that runs against the same
/// server. So every view this file creates is remembered and deleted in
/// `tearDownAll`, and the delete cascades to its keys, graphs and periods.
/// Nothing here touches a row it did not write.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_relay_local/src/data/history_view_store.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show HistoryViewGraphRecord, HistoryViewKeyRecord;

import 'support/timescale_fixture.dart';

late TimescaleFixture fx;
late pg.Connection admin;
late Database writer;
late HistoryViewStore store;

/// Everything written through [store], deleted in `tearDownAll`.
final Set<int> createdViews = <int>{};

/// Every message the store logged, in order. Cleared per case.
final List<String> notices = <String>[];

DatabaseConfig dbConfig() => DatabaseConfig(
      postgres: pg.Endpoint(
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
      ),
      sslMode: pg.SslMode.disable,
      connectTimeout: const Duration(seconds: 5),
      queryTimeout: const Duration(seconds: 5),
      applicationName: 'relay-history-test',
    );

Future<Database> openWriter() async {
  final db = Database(await AppDatabase.create(dbConfig()));
  await db.open();
  return db;
}

/// Creates a view through the store and remembers it for teardown.
Future<int> newView(String name, List<String> keys,
    [Map<String, HistoryViewKeyRecord>? keyConfigs,
    Map<int, HistoryViewGraphRecord>? graphConfigs]) async {
  final id = await store.createHistoryView(name, keys, keyConfigs, graphConfigs);
  createdViews.add(id);
  return id;
}

Future<int> countRows(String table, String column, int value) async {
  final result = await admin
      .execute(pg.Sql.named('SELECT count(*) FROM "$table" WHERE "$column" = @v'),
          parameters: {'v': value});
  return (result.first.first! as int);
}

void main() {
  setUpAll(() async {
    fx = await TimescaleFixture.start();
    admin = await fx.connect();
    writer = await openWriter();
    store = HistoryViewStore(
      database: () => writer,
      log: notices.add,
    );
  });

  setUp(notices.clear);

  tearDownAll(() async {
    for (final id in createdViews) {
      await admin.execute(
          pg.Sql.named('DELETE FROM history_view WHERE id = @id'),
          parameters: {'id': id});
    }
    try {
      await writer.close();
    } catch (_) {
      // A writer a case already closed on purpose is not a failure here.
    }
    await admin.close();
    await fx.stop();
  });

  group('a created view', () {
    test('the view, its keys and its graphs are all readable afterwards',
        () async {
      final id = await newView(
        'Frystir — vakt 1',
        ['Line1.Motor1', 'Line1.Temp1'],
        {
          'Line1.Motor1': const HistoryViewKeyRecord(
              key: 'Line1.Motor1',
              alias: 'Færiband 1',
              useSecondYAxis: true,
              graphIndex: 1),
          'Line1.Temp1': const HistoryViewKeyRecord(key: 'Line1.Temp1'),
        },
        {
          1: const HistoryViewGraphRecord(
              graphIndex: 1, name: 'Hraði', yAxisUnit: 'rpm', yAxis2Unit: '°C'),
        },
      );

      expect(id, greaterThan(0),
          reason: 'the id is what every later call addresses the view by; a '
              'view without one cannot be opened, edited or deleted');

      final views = await store.selectHistoryViews();
      final saved = views.singleWhere((v) => v.id == id);
      expect(saved.name, 'Frystir — vakt 1',
          reason: 'the view came back under a different name than it was '
              'saved with');
      expect(saved.createdAt.isUtc, isTrue,
          reason: 'drift stamps createdAt with a clientDefault of '
              'DateTime.now() — a LOCAL instant. Every DateTime on this wire '
              'is UTC epoch milliseconds (state_man_api.dart:302), and a '
              'local-flagged instant is not == to the UTC one it decodes to');

      final keys = await store.getHistoryViewKeys(id);
      expect(keys.keys, containsAll(['Line1.Motor1', 'Line1.Temp1']));
      expect(keys['Line1.Motor1']!.alias, 'Færiband 1');
      expect(keys['Line1.Motor1']!.useSecondYAxis, isTrue);
      expect(keys['Line1.Motor1']!.graphIndex, 1);

      final graphs = await store.getHistoryViewGraphs(id);
      expect(graphs[1]!.name, 'Hraði');
      expect(graphs[1]!.yAxisUnit, 'rpm');
      expect(graphs[1]!.yAxis2Unit, '°C');
    });

    test('a graph map keyed {0, 7, 12} comes back with all three entries',
        () async {
      // Non-contiguous ON PURPOSE. An implementation that renumbered — or one
      // that iterated 0..n and stopped at the first gap — would pass a
      // {0, 1, 2} case and fail this one. And drift's own createHistoryView
      // reads the map's keys with int.tryParse and SILENTLY SKIPS whatever
      // fails, so a chart configured with four graphs would come back with
      // three and nothing anywhere would say which one went.
      final id = await newView('Þrjú línurit', const [], null, {
        0: const HistoryViewGraphRecord(graphIndex: 0, yAxisUnit: 'rpm'),
        7: const HistoryViewGraphRecord(graphIndex: 7, yAxisUnit: 'bar'),
        12: const HistoryViewGraphRecord(graphIndex: 12, yAxisUnit: '°C'),
      });

      final graphs = await store.getHistoryViewGraphs(id);
      expect(graphs.keys.toList()..sort(), [0, 7, 12],
          reason: 'a graph entry that vanished on the way down is a chart the '
              'operator configured and will not see again');
      expect(graphs[7]!.yAxisUnit, 'bar',
          reason: 'index 7 came back carrying another graph\'s units, which '
              'is a renumbering wearing a round trip');
    });
  });

  group('updateHistoryView', () {
    test('replaces the keys and the graphs, and none of the old set survives',
        () async {
      final id = await newView(
        'Fyrir',
        ['old.a', 'old.b'],
        {'old.a': const HistoryViewKeyRecord(key: 'old.a', alias: 'Gamalt')},
        {0: const HistoryViewGraphRecord(graphIndex: 0, name: 'Gamalt')},
      );

      await store.updateHistoryView(
        id,
        'Eftir',
        ['new.a'],
        {'new.a': const HistoryViewKeyRecord(key: 'new.a', alias: 'Nýtt')},
        {3: const HistoryViewGraphRecord(graphIndex: 3, name: 'Nýtt')},
      );

      final keys = await store.getHistoryViewKeys(id);
      expect(keys.keys, ['new.a'],
          reason: 'a key removed from a view in the editor and still plotted '
              'after a reload is the edit not having happened');
      expect(keys['new.a']!.alias, 'Nýtt');

      final graphs = await store.getHistoryViewGraphs(id);
      expect(graphs.keys, [3]);
      expect(graphs[0], isNull,
          reason: 'the replaced graph configuration outlived the replacement');

      final views = await store.selectHistoryViews();
      final saved = views.singleWhere((v) => v.id == id);
      expect(saved.name, 'Eftir');
      expect(saved.updatedAt, isNotNull,
          reason: 'updateHistoryView stamps updatedAt; null after an edit is '
              'a view that reads as never edited');
      expect(saved.updatedAt!.isUtc, isTrue,
          reason: 'drift writes DateTime.now() here too — a LOCAL instant');
    });
  });

  group('deleteHistoryView', () {
    test('takes the view, its keys, its graphs and its periods with it',
        () async {
      final id = await newView(
        'Til eyðingar',
        ['k1'],
        {'k1': const HistoryViewKeyRecord(key: 'k1')},
        {0: const HistoryViewGraphRecord(graphIndex: 0, name: 'G')},
      );
      await store.addHistoryViewPeriod(id, 'Vakt', DateTime.utc(2026, 8, 12, 6),
          DateTime.utc(2026, 8, 12, 14));

      // Seeded, and asserted seeded: a delete case that runs against an empty
      // view proves nothing at all.
      expect(await countRows('history_view_key', 'view_id', id), 1);
      expect(await countRows('history_view_graph', 'view_id', id), 1);
      expect(await countRows('history_view_period', 'view_id', id), 1);

      await store.deleteHistoryView(id);

      // Queried, not trusted. The FK cascade is what makes upstream's four
      // separate un-transacted deletes total on Postgres, and a cascade that
      // was not created — a schema built by a migration path that skipped it,
      // or a SQLite deployment with foreign_keys off — is invisible until a
      // deleted view comes back as a partial one after a restart.
      expect(await countRows('history_view', 'id', id), 0,
          reason: 'the deleted view is still in the picker');
      expect(await countRows('history_view_key', 'view_id', id), 0,
          reason: 'the view was deleted and its plotted keys outlived it');
      expect(await countRows('history_view_graph', 'view_id', id), 0,
          reason: 'the graph configuration outlived the view it configured');
      expect(await countRows('history_view_period', 'view_id', id), 0,
          reason: 'the saved shift windows outlived the view they were saved '
              'on, and nothing can reach them to delete them now');
    });
  });

  group('selectHistoryViews', () {
    test('lists every saved view, and says nothing about their keys', () async {
      final a = await newView('Picker A', ['k']);
      final b = await newView('Picker B', ['k']);

      final views = await store.selectHistoryViews();
      expect(views.map((v) => v.id), containsAll([a, b]));
      expect(views.singleWhere((v) => v.id == a).name, 'Picker A');
      expect(views.singleWhere((v) => v.id == b).updatedAt, isNull,
          reason: 'updatedAt is null until the view has been edited, and a '
              'never-edited view reading as edited-at-the-epoch is worse than '
              'a null the picker can render as a dash');
    });
  });

  group('the FK cascade upstream depends on', () {
    test('all three child tables really do declare ON DELETE CASCADE',
        () async {
      // A characterisation case, not a round trip: `deleteHistoryView`'s doc
      // comment argues that upstream's four un-transacted statements have not
      // yet left a half-deleted view behind BECAUSE the first statement
      // already cascades, and that the transaction added on this side is for
      // the deployments where it does not. That argument is only worth having
      // written down if it is true of this schema, so it is asked rather than
      // read off the table definitions. The day a migration drops one of
      // these, this case says so instead of the doc quietly becoming wrong.
      final rows = await admin.execute(
          'SELECT c.conrelid::regclass::text AS child, '
          // ::text on confdeltype because it is a Postgres "char" and the
          // driver hands an undecoded byte back for it.
          'c.confdeltype::text AS ondelete '
          'FROM pg_constraint c '
          "WHERE c.contype = 'f' "
          "AND c.confrelid = 'history_view'::regclass "
          'ORDER BY 1');
      final byChild = {
        for (final row in rows) row[0]! as String: row[1]! as String,
      };

      expect(byChild.keys, hasLength(3),
          reason: 'three tables hang off history_view and each needs its own '
              'foreign key; ${byChild.keys.toList()} were found');
      for (final child in byChild.keys) {
        expect(byChild[child], 'c',
            reason: '$child references history_view with confdeltype '
                '"${byChild[child]}" rather than "c" (CASCADE). Upstream '
                'deletes the parent first and its other three statements then '
                'match nothing, so without the cascade a delete leaves this '
                'table\'s rows behind — reachable by nothing and deletable by '
                'nothing');
      }
    });
  });

  group('getHistoryViewKeys and the alias default', () {
    late int id;

    setUp(() async {
      id = await newView(
        'Aliasar',
        ['explicit', 'absent', 'same'],
        {
          'explicit':
              const HistoryViewKeyRecord(key: 'explicit', alias: 'Skýrt'),
          // No alias at all: the record's constructor substitutes the key.
          'absent': const HistoryViewKeyRecord(key: 'absent'),
          // An alias that happens to equal the key — indistinguishable from
          // the row above once written, which is the finding rather than an
          // oversight.
          'same': const HistoryViewKeyRecord(key: 'same', alias: 'same'),
        },
      );
    });

    test('an explicit alias, an absent one and one equal to the key', () async {
      final keys = await store.getHistoryViewKeys(id);

      expect(keys['explicit']!.alias, 'Skýrt');
      expect(keys['absent']!.alias, 'absent',
          reason: 'a key saved with no alias needs something to render in the '
              'legend, and its own name is it — drift\'s `row.alias ?? '
              'row.key` and HistoryViewKeyRecord\'s constructor agree, and '
              'the store must implement neither of them a third time');
      expect(keys['same']!.alias, 'same');

      // The third arm is not about the values coming back — 'absent' and
      // 'same' are different keys and so are their aliases. It is about the
      // ROWS: a key saved with no alias and a key saved with an alias equal to
      // its own name are written identically, because the record's
      // constructor has already substituted the key before the store sees it.
      // Asked on disk, because that is the only place the two could still
      // have differed.
      final onDisk = await admin.execute(
          pg.Sql.named('SELECT key, alias FROM history_view_key '
              'WHERE view_id = @id ORDER BY key'),
          parameters: {'id': id});
      expect(
          {for (final row in onDisk) row[0] as String: row[1] as String?},
          {'absent': 'absent', 'explicit': 'Skýrt', 'same': 'same'},
          reason: 'the wire cannot express "this key has no alias", only '
              '"its alias equals its key" — so "absent" is not recoverable '
              'after the first save, and the row written for it is '
              'byte-identical to the one written for a deliberate alias of '
              'the same spelling');
    });

    test('the axis placement and graph index survive as themselves', () async {
      final other = await newView('Ásar', [
        'a'
      ], {
        'a': const HistoryViewKeyRecord(
            key: 'a', useSecondYAxis: true, graphIndex: 3),
      });

      final keys = await store.getHistoryViewKeys(other);
      expect(keys['a']!.useSecondYAxis, isTrue,
          reason: 'a temperature saved against the second Y axis and read '
              'back on the first is a flat line at the bottom of a motor '
              'speed\'s scale');
      expect(keys['a']!.graphIndex, 3);
    });
  });

  group('getHistoryViewGraphs and the name that is null in the database', () {
    test('an unnamed graph is NULL on disk and the empty string on the wire',
        () async {
      final id = await newView('Nafnlaust', const [], null, {
        0: const HistoryViewGraphRecord(graphIndex: 0, yAxisUnit: 'rpm'),
        1: const HistoryViewGraphRecord(
            graphIndex: 1, name: 'Hiti', yAxisUnit: '°C'),
      });

      final onDisk = await admin.execute(
          pg.Sql.named('SELECT graph_index, name FROM history_view_graph '
              'WHERE view_id = @id ORDER BY graph_index'),
          parameters: {'id': id});
      expect(onDisk.map((r) => r[1]).toList(), [null, 'Hiti'],
          reason: 'the decision is that the empty string is written as NULL, '
              'because the column is nullable and the application\'s own HMI '
              'reads these rows directly. Asserted on disk and not only '
              'through the round trip, because the round trip cannot tell the '
              'two apart');

      final graphs = await store.getHistoryViewGraphs(id);
      expect(graphs[0]!.name, '',
          reason: 'the record\'s name is a non-nullable String defaulting to '
              'the empty string, mirroring drift\'s own `row.name ?? \'\'`');
      expect(graphs[1]!.name, 'Hiti');
      expect(graphs[0]!.yAxisUnit, 'rpm');
      expect(graphs[0]!.yAxis2Unit, '',
          reason: 'an axis nobody labelled renders blank; it does not break '
              'the chart and it is not null');
    });
  });

  group('getHistoryViewKeyNames', () {
    test('agrees with the record accessor and does not move between calls',
        () async {
      final id = await newView('Nöfn', ['k.a', 'k.b', 'k.c']);

      final names = await store.getHistoryViewKeyNames(id);
      final records = await store.getHistoryViewKeys(id);

      expect(names.toSet(), {'k.a', 'k.b', 'k.c'},
          reason: 'the name-only accessor disagrees with the record accessor '
              'about what this view plots');
      expect(names.toSet(), records.keys.toSet());
      expect(await store.getHistoryViewKeyNames(id), names,
          reason: 'stable across calls. Neither drift query carries an ORDER '
              'BY, so the order is the database\'s and this asserts that it '
              'does not move under a caller rather than claiming it is '
              'sorted — a caller that needs a deterministic order must sort');
    });
  });

  group('a saved window', () {
    test('comes back equal to the microsecond, DST transition and all',
        () async {
      final id = await newView('Vaktir', ['k']);

      // Europe/London, 2026-03-29: the clocks go forward at 01:00 UTC, so the
      // local wall clock jumps 01:00 -> 02:00 and 01:30 local DOES NOT EXIST
      // that day. Anything that round-tripped this instant through a local
      // wall clock could not put it back.
      final start = DateTime.utc(2026, 3, 29, 1, 0, 0, 123, 456);
      // America/New_York, 2026-11-01: the clocks go back at 06:00 UTC, so
      // 01:30 local happens TWICE. The inverse hazard: a wall clock that
      // round-trips has two instants to choose from and no way to pick.
      final end = DateTime.utc(2026, 11, 1, 6, 30, 0, 789, 12);

      final periodId =
          await store.addHistoryViewPeriod(id, 'Vakt 1', start, end);
      expect(periodId, greaterThan(0),
          reason: 'without an id the window cannot be deleted again');

      final periods = await store.listHistoryViewPeriods(id);
      expect(periods, hasLength(1));
      final saved = periods.single;

      expect(saved.id, periodId,
          reason: 'the window came back under an id other than the one adding '
              'it returned, so deleting it would address something else');
      expect(saved.viewId, id);
      expect(saved.name, 'Vakt 1');
      expect(saved.startAt.isUtc, isTrue,
          reason: 'every DateTime on this wire is UTC, and DateTime == '
              'compares the flag as well as the instant');
      expect(saved.startAt, start,
          reason: 'EXACTLY, not within a tolerance — a tolerance is how an '
              'hour of drift hides. The instant is inside Europe/London\'s '
              '2026-03-29 spring-forward, where the local wall clock this '
              'would have gone through does not exist');
      expect(saved.endAt, end,
          reason: 'the instant is inside America/New_York\'s 2026-11-01 '
              'fall-back, where the local wall clock happens twice');
      expect(saved.startAt.microsecond, 456,
          reason: 'microseconds, spelled out: Postgres stores them and Dart '
              'carries them, so a store that truncated would be losing '
              'precision the database was willing to keep');
      expect(saved.endAt.microsecond, 12);
      expect(saved.createdAt.isUtc, isTrue,
          reason: 'stamped by drift with DateTime.now(), a LOCAL instant');
    });

    test('several windows come back oldest first', () async {
      final id = await newView('Röð', ['k']);
      final march = DateTime.utc(2026, 3, 1, 6);
      final august = DateTime.utc(2026, 8, 12, 6);
      final may = DateTime.utc(2026, 5, 4, 6);

      // Inserted newest, oldest, middle — so an implementation that returned
      // insertion order would pass a sorted-input case and fail this one.
      await store.addHistoryViewPeriod(
          id, 'Ágúst', august, august.add(const Duration(hours: 8)));
      await store.addHistoryViewPeriod(
          id, 'Mars', march, march.add(const Duration(hours: 8)));
      await store.addHistoryViewPeriod(
          id, 'Maí', may, may.add(const Duration(hours: 8)));

      final periods = await store.listHistoryViewPeriods(id);
      expect(periods.map((p) => p.name).toList(), ['Mars', 'Maí', 'Ágúst'],
          reason: 'HistoryViewApi.listHistoryViewPeriods says "oldest first" '
              '(state_man_api.dart:341) and neither drift query carries an '
              'ORDER BY, so the store owes the ordering the interface '
              'promises');
    });

    test('deleting one window leaves the others and the view alone', () async {
      final id = await newView('Eyðing', ['k']);
      final keep = await store.addHistoryViewPeriod(id, 'Geyma',
          DateTime.utc(2026, 1, 1), DateTime.utc(2026, 1, 2));
      final drop = await store.addHistoryViewPeriod(id, 'Eyða',
          DateTime.utc(2026, 2, 1), DateTime.utc(2026, 2, 2));

      await store.deleteHistoryViewPeriod(drop);

      final periods = await store.listHistoryViewPeriods(id);
      expect(periods.map((p) => p.id).toList(), [keep],
          reason: 'the deleted window is still listed, or it took its '
              'neighbour with it');
      expect(await countRows('history_view', 'id', id), 1,
          reason: 'deleting a saved window deleted the view it was saved on');
    });

    test('a window the application itself saved, in local time, comes back UTC',
        () async {
      // **This is why the read side converts and not only the write side.**
      // Measured, not assumed: these four columns are `text` in Postgres, not
      // `timestamptz` — drift writes `DateTime.toIso8601String()` into them
      // and the flag travels in the string. A UTC instant is stored as
      // "2026-03-29T01:00:00.123456Z" and parses back UTC; a LOCAL one is
      // stored as "2026-09-04T04:54:10.368039 +12:00" and parses back
      // local-flagged.
      //
      // The application's own HMI has always written these rows and writes
      // local instants, so rows like the one below are already on disk at SVN.
      // Written through drift DIRECTLY, bypassing this store's own write-side
      // normalisation, because that is exactly what "a row the desktop app
      // saved" means.
      final id = await newView('Frá HMI', ['k']);
      final local = DateTime(2026, 3, 29, 1, 0, 0, 123, 456);
      await writer.db
          .addHistoryViewPeriod(id, 'Vakt HMI', local, local.add(
              const Duration(hours: 8)));

      final saved = (await store.listHistoryViewPeriods(id)).single;
      expect(saved.startAt.isUtc, isTrue,
          reason: 'a window saved by the desktop app comes off disk carrying '
              'a local flag, and every DateTime on this wire is UTC');
      expect(saved.startAt, local.toUtc(),
          reason: 'the same instant, said in UTC — not a different one. The '
              'conversion must not move the moment, only the flag');
      expect(saved.startAt.microsecond, 456,
          reason: 'the text column carries microseconds and the conversion '
              'must not round them away');
    });
  });

  group('the retention horizon', () {
    final createdTables = <String>[];

    /// Every `policy_retention` job on this server, removed.
    ///
    /// The horizon is GLOBAL — it is the maximum `drop_after` across every
    /// job on the server — so the "no policy" arm is only meaningful against
    /// a server that genuinely has none, and a sibling case (or an 8b case
    /// sharing an external server) installing one would otherwise decide this
    /// arm's answer.
    Future<void> removeEveryRetentionJob() async {
      await admin.execute("SELECT delete_job(job_id) FROM "
          "timescaledb_information.jobs WHERE proc_name = 'policy_retention'");
    }

    tearDownAll(() async {
      for (final table in createdTables) {
        await admin.execute('DROP TABLE IF EXISTS "$table" CASCADE');
      }
    });

    test('with no retention policy installed, the horizon is null and silent',
        () async {
      await removeEveryRetentionJob();

      expect(await store.getGlobalRetentionHorizon(), isNull,
          reason: '"nothing has been discarded yet" is null, and it must not '
              'be defaulted to the epoch — 0 is a valid epoch millisecond and '
              'the OPPOSITE answer, "everything since the epoch is gone" '
              '(client_sub_apis.dart:398-408)');
      expect(notices, isEmpty,
          reason: 'a gateway that logged a line every time a chart asked '
              'about retention on a server that has no policy would log one '
              'per panel per open. Silence is the right answer for the '
              'ordinary case; the failure arm below is what must NOT be '
              'silent');
    });

    test('with a policy installed, the horizon is UTC and is now minus it',
        () async {
      final table = 'gw_retention_${DateTime.now().microsecondsSinceEpoch}';
      createdTables.add(table);
      const week = Duration(days: 7);

      await writer.registerRetentionPolicy(
          table, const RetentionPolicy(dropAfter: week));
      await writer.insertTimeseriesData(table, DateTime.now().toUtc(), 1);
      await writer.flush();
      await writer.registerRetentionPolicy(
          table, const RetentionPolicy(dropAfter: week));

      // Bracketed by the case's own clock, so the arithmetic is asserted
      // rather than approximated: the horizon is computed inside the call, so
      // it cannot be older than `before - 7d` nor newer than `after - 7d`.
      final before = DateTime.now().toUtc();
      final horizon = await store.getGlobalRetentionHorizon();
      final after = DateTime.now().toUtc();

      expect(horizon, isNotNull,
          reason: 'a retention policy is installed and the gateway says '
              'nothing has been discarded, so a chart scrolled past the '
              'horizon shows absence of DATA as absence of EVENTS');
      expect(horizon!.isUtc, isTrue,
          reason: 'drift builds this with DateTime.now().subtract(maxDur) — a '
              'LOCAL instant (database_drift.dart:774) — and the wire is UTC '
              'epoch milliseconds everywhere. A horizon an hour off says '
              'history exists that does not');
      expect(horizon.isAfter(before.subtract(week)) || horizon == before.subtract(week),
          isTrue,
          reason: 'the horizon $horizon is older than the case\'s own '
              '"now minus seven days" (${before.subtract(week)})');
      expect(horizon.isBefore(after.subtract(week)) || horizon == after.subtract(week),
          isTrue,
          reason: 'the horizon $horizon is newer than the case\'s own '
              '"now minus seven days" (${after.subtract(week)})');
    });

    test('when the query fails the answer is still null, and it is logged',
        () async {
      // A historian that went down between the panel opening and the chart
      // asking. Its own Database, closed on purpose, so no other case shares
      // the wreckage.
      final dead = await openWriter();
      final deadStore =
          HistoryViewStore(database: () => dead, log: notices.add);
      await dead.close();

      expect(await deadStore.getGlobalRetentionHorizon(), isNull,
          reason: 'the ANSWER stays null: this gateway does not widen '
              'upstream\'s catch, because a new exception type on the wire is '
              'a client-visible change and the compatible answer is the '
              'existing one');
      expect(notices, isNotEmpty,
          reason: 'THIS is the improvement. Upstream answers a permissions '
              'error, a non-Timescale database and "nothing has been '
              'discarded yet" with the same null and no trace '
              '(database_drift.dart:775-778). The answer stays compatible '
              'and the operator stops being lied to silently');
      expect(notices.join('\n'), contains('retention'),
          reason: 'a log line that does not name what was being asked is a '
              'line nobody can act on');
    });
  });
}
