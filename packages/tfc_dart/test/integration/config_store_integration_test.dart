// The ConfigStore and its sync engine against a real Postgres: the two
// compare-and-swap races, the once-per-transaction notification, the watermark
// pull end to end, the sequence gap the pull cannot see, and the classifier
// that turns a dead connection into a sentence an operator can act on.
//
// These are the six things the cheap lane cannot prove, because SQLite has no
// LISTEN/NOTIFY, no SERIAL visible-at-commit semantics, and no way to lose a
// race:
//
//   1. SC-5a — two stations saving different keys through one database both
//      keep their work;
//   2. SC-5b — two stations saving the *same* key: the second loses on `rev`,
//      and its rollback leaves the shared connection usable (C-5);
//   3. SC-6a — five keys written in one transaction are one delivered
//      notification, not five (C-7 / research assumption A1);
//   4. SC-6b — an edit made on another connection reaches a listening store's
//      snapshot with no restart and no poll;
//   5. C-6 — a change row whose SERIAL id was taken first and committed last
//      is invisible to the watermark forever, and the rev sweep finds it;
//   6. the offline classifier, against a connection that really dies.
//
// The schema is created through the real migration path, which means this file
// is also the first thing that has ever executed 02-02's v9 arm — the
// `notify_config_change` function and its statement-level trigger — against a
// server. Nothing here installs them by hand.
//
// ORDER MATTERS at the end: the outage test kills the shared connection for
// everything after it and is deliberately last.
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Two checkouts running integration
// suites at once bind the same ports and each `setUpAll` tears the other's
// database down mid-run — the symptom is connection resets that read exactly
// like a resilience regression. Run integration tests in one worktree at a
// time.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'docker_compose.dart';

/// The mappings an editor hands over.
KeyMappings mappingsOf(Map<String, String> keysToIdentifiers) =>
    KeyMappings.fromJson(jsonDecode(jsonEncode({
      'nodes': {
        for (final entry in keysToIdentifiers.entries)
          entry.key: {
            'opcua_node': {'namespace': 4, 'identifier': entry.value},
          },
      },
    })) as Map<String, dynamic>);

/// The payload a station stores for one key — **through the codec**.
///
/// `KeyMappingEntry.toJson()` emits all eight of its fields including the
/// seven nulls, so a payload assembled any other way is structurally a
/// different item and every reconcile that meets it reports a change nobody
/// made. That is not a test-only concern: it is why the migration, the write
/// path and the sync engine all go through this one function.
String payloadOf(String key, String identifier) =>
    keyMappingItems(mappingsOf({key: identifier})).single.payload;

void main() {
  group('ConfigStore against Postgres', () {
    late Database remote;

    /// A second connection, standing in for another station or a `psql`
    /// session: it seeds, it counts, and it asserts. Assertions must not ride
    /// the connection under test.
    late pg.Connection other;

    var station = 0;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      remote = await connectToDatabase();
      other = await getTestConnection();
    });

    tearDownAll(() async {
      await other.close();
      await remote.close();
      await stopDockerCompose();
    });

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
    });

    /// A station: its own local SQLite file, its own store, one shared remote.
    ///
    /// [startSync] false attaches the write path and leaves the reconcile, the
    /// notification channel and the sweep switched off, so the test decides
    /// when anything is applied. The races below need that: with sync running,
    /// the window a compare-and-swap protects is closed by the notification
    /// before the test can use it — which is a property of the design, proven
    /// on purpose by the SC-6 tests, and not one a CAS test may lean on.
    ///
    /// [sweepInterval] is an hour by default for the reason the retired
    /// `preferences_watch_integration_test.dart` set one: a test that asserts
    /// on the notification path must not be able to pass because a poll
    /// rescued it.
    Future<ConfigStore> newStation({
      bool startSync = false,
      Duration sweepInterval = const Duration(hours: 1),
    }) async {
      final name = 'station-${station++}';
      final dir = await Directory.systemTemp.createTemp('config-store-$name-');
      final local = AppDatabase.createLocal(dir);
      final store = ConfigStore(
        local: local,
        stationScope: ConfigScope.forStation(name),
        station: name,
        sweepInterval: sweepInterval,
      );
      addTearDown(() async {
        await store.syncSettled;
        await store.close();
        await local.close();
        await dir.delete(recursive: true);
      });
      await store.open();
      if (startSync) {
        // The production path, wrapper and all.
        store.attachRemote(remote);
      } else {
        store.attachRemoteDatabase(remote.db, startSync: false);
      }
      await store.syncSettled;
      return store;
    }

    var action = 0;
    Future<ConfigWriteResult> save(
            ConfigStore store, Map<String, String> keys) =>
        store.writeKeyMappings(
          mappingsOf(keys),
          actionId: 'action-${action++}',
          who: 'tester',
          roleName: 'Engineering',
        );

    Future<List<pg.ResultRow>> sharedRows() => other.execute(
        "SELECT id, payload, rev FROM config_item WHERE kind = 'key_mapping' "
        "AND scope = 'shared' ORDER BY id");

    Future<int> changeCount() async {
      final result = await other.execute('SELECT count(*) FROM config_change');
      return (result.first.first! as num).toInt();
    }

    /// One `key_mapping` row and the change row that announces it, on [session]
    /// — another station's save, or an engineer in `psql`.
    Future<void> rawWrite(
      pg.Session session,
      String key,
      String identifier, {
      int rev = 1,
      String? newValue,
    }) async {
      final at = DateTime.now().toUtc().toIso8601String();
      await session.execute(
        pg.Sql.named(
            'INSERT INTO config_item (kind, id, scope, payload, rev, '
            "updated_at, updated_by) VALUES ('key_mapping', @id, 'shared', "
            "@payload, @rev, @at, 'other-station') "
            'ON CONFLICT (kind, id, scope) DO UPDATE SET '
            'payload = EXCLUDED.payload, rev = EXCLUDED.rev'),
        parameters: {
          'id': key,
          'payload': payloadOf(key, identifier),
          'rev': rev,
          'at': at,
        },
      );
      await session.execute(
        pg.Sql.named('INSERT INTO config_change (at, action_id, who, station, '
            'role_name, kind, entity_id, scope, op, new_value) VALUES '
            "(@at, @action, 'someone', 'other-station', 'Engineering', "
            "'key_mapping', @id, 'shared', 'update', @new)"),
        parameters: {
          'at': at,
          'action': 'raw-${action++}',
          'id': key,
          'new': newValue,
        },
      );
    }

    String? identifierOf(ConfigStore store, String key) =>
        store.keyMappings.nodes[key]?.opcuaNode?.identifier;

    test('SC-5a: two stations saving different keys both keep their work',
        () async {
      final a = await newStation();
      final b = await newStation();

      await save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'});
      await save(b, {'CN07.Belt.Speed': 'GVL.Conveyors[7].Speed'});

      final rows = await sharedRows();
      expect(rows.map((r) => r[0]), ['CN04.Belt.Speed', 'CN07.Belt.Speed']);
      expect(rows.map((r) => (r[2]! as num).toInt()), [1, 1],
          reason: 'each key was inserted once by the station that owns the '
              'edit; a rev of 2 would mean one station rewrote the other');
      expect(rows.first[1], payloadOf('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed'));
      expect(rows.last[1], payloadOf('CN07.Belt.Speed', 'GVL.Conveyors[7].Speed'));
      expect(await changeCount(), 2);
    });

    test('SC-5b: the same key twice — the second loses, and the connection '
        'is left clean', () async {
      final a = await newStation();
      await save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'});

      // B reads the plant as it stands: one key at rev 1.
      final b = await newStation();
      await b.reconcile();
      expect(b.keyMappingItems.single.rev, 1);

      // A saves first and takes the row to rev 2.
      await save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].SpeedActual'});

      await expectLater(
        save(b, {'CN04.Belt.Speed': 'GVL.Conveyors[4].SpeedSetpoint'}),
        throwsA(isA<ConfigConflict>()),
      );

      // Nothing of B's save survives, and A's is untouched.
      final rows = await sharedRows();
      expect(rows.single[1],
          payloadOf('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual'));
      expect((rows.single[2]! as num).toInt(), 2);
      expect(await changeCount(), 2,
          reason: 'the losing save wrote no history: it threw out of the '
              'transaction, so drift issued ROLLBACK');

      // C-5. The conflict threw from inside a transaction; if it had been
      // caught and the transaction left open and aborted, the *next* statement
      // on this connection would fail with "current transaction is aborted"
      // and the health monitor's SELECT 1 would report a database that is up
      // as down.
      await b.reconcile();
      await save(b, {'CN04.Belt.Speed': 'GVL.Conveyors[4].SpeedSetpoint'});
      final after = await sharedRows();
      expect((after.single[2]! as num).toInt(), 3);
    });

    test('SC-6a: five keys in one save are one delivered notification',
        () async {
      // WHAT A FAILURE HERE MEANS. This pins Postgres's documented collapse of
      // identical (channel, payload) notifications within one transaction —
      // research assumption A1, and the reason 02-02's trigger carries an
      // empty payload. If a server upgrade ever delivered five, what has moved
      // is SC-6's *wording* ("one NOTIFY per action"), not correctness: the
      // watermark pull is idempotent, so N deliveries converge on exactly the
      // same snapshot, at the cost of N-1 cheap queries.
      //
      // So the response to this test going red is to renegotiate SC-6's
      // wording with the people who wrote it — never to loosen the count to
      // `greaterThanOrEqualTo(1)`. A loosened assertion here would still pass
      // on the day a payload-carrying trigger is reintroduced and every save
      // of the plant's wiring starts erroring on the 8000-byte NOTIFY cap.
      final listener = await getTestConnection();
      addTearDown(listener.close);
      var delivered = 0;
      final subscription =
          listener.channels['config_change'].listen((_) => delivered++);
      addTearDown(subscription.cancel);

      final a = await newStation();

      // LISTEN registration is asynchronous. Prove the channel is live before
      // asserting on it, by saving until the first delivery lands.
      var warm = 0;
      final warmDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (delivered == 0) {
        if (DateTime.now().isAfter(warmDeadline)) {
          fail('LISTEN never became live: nothing after $warm warm-up saves');
        }
        await save(a, {'Warm.Up': 'warm-${warm++}'});
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      // Let the remaining warm-up deliveries trickle in.
      var quiet = delivered;
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (delivered == quiet) break;
        quiet = delivered;
      }

      final before = delivered;
      await save(a, {
        'Warm.Up': 'warm-${warm - 1}',
        'CN01.Belt.Speed': 'GVL.Conveyors[1].Speed',
        'CN02.Belt.Speed': 'GVL.Conveyors[2].Speed',
        'CN03.Belt.Speed': 'GVL.Conveyors[3].Speed',
        'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed',
        'CN05.Belt.Speed': 'GVL.Conveyors[5].Speed',
      });

      // Five inserts, five trigger firings, five pg_notify calls — and one
      // delivery. Waited out rather than polled: the failure this guards
      // against is *more* deliveries, which arrive after the first.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(delivered - before, 1);
      expect(await changeCount(), warm + 5,
          reason: 'the five keys really were five change rows in one '
              'transaction; one delivery for one row would prove nothing');
    });

    test('SC-6b: another connection\'s edit reaches a listening store',
        () async {
      final a = await newStation(startSync: true);
      await save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'});

      // The store's own subscription has to be live before the edit lands, or
      // there is nothing to notice it: the sweep is an hour away by
      // construction. Warm up the same way, with edits from the other
      // connection until one arrives.
      var warm = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (identifierOf(a, 'Warm.Up') == null) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the store never noticed anything: $warm warm-up edits');
        }
        await rawWrite(other, 'Warm.Up', 'warm-${warm++}', rev: warm);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      // The real one. `new_value` is deliberately a lie: the pull re-reads the
      // `config_item` row and never trusts the log's copy, because a value
      // read from a history is what somebody once wrote rather than what is
      // stored now.
      await rawWrite(other, 'CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual',
          rev: 9, newValue: '{"payload": {"opcua_node": {"identifier": "LIE"}}}');

      final arrival = DateTime.now().add(const Duration(seconds: 15));
      while (identifierOf(a, 'CN04.Belt.Speed') !=
          'GVL.Conveyors[4].SpeedActual') {
        if (DateTime.now().isAfter(arrival)) {
          fail('the edit never arrived: still '
              '${identifierOf(a, 'CN04.Belt.Speed')}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(a.keyMappingItems.firstWhere((i) => i.id == 'CN04.Belt.Speed').rev,
          9,
          reason: 'the revision travels with the row, or the next save '
              'compare-and-swaps against a number the server left behind');
      expect(a.watermark, greaterThan(0));
    });

    test('C-6: a change row committed out of sequence order is invisible to '
        'the watermark, and the rev sweep finds it', () async {
      // THE ARGUMENT, in one test. `config_change.id` is a SERIAL: the value
      // is handed out at INSERT and becomes visible at COMMIT. Two overlapping
      // transactions can therefore commit in the opposite order to their ids,
      // and a reader that has advanced its watermark past the higher id will
      // never see the lower one again — not on the next notification, not on
      // the next poll, not ever. That is why the net is a comparison of `rev`
      // over the current rows and not a second `id >` read: a second read of
      // the same predicate misses the same row the same way.
      final a = await newStation();

      final first = await getTestConnection();
      final second = await getTestConnection();
      addTearDown(() async {
        await first.close();
        await second.close();
      });

      // tx1 takes the lower id and does not commit.
      await first.execute('BEGIN');
      await rawWrite(first, 'CN01.Slow.Commit', 'GVL.Conveyors[1].Speed');

      // tx2 takes the higher id and commits.
      await second.execute('BEGIN');
      await rawWrite(second, 'CN02.Fast.Commit', 'GVL.Conveyors[2].Speed');
      await second.execute('COMMIT');

      // The station consumes the log as far as it can see, which is tx2 only.
      await a.pullChanges();
      expect(identifierOf(a, 'CN02.Fast.Commit'), 'GVL.Conveyors[2].Speed');
      final watermark = a.watermark;
      expect(watermark, greaterThan(0));

      // Now tx1 commits. Its change row is *behind* the watermark.
      await first.execute('COMMIT');
      final ids = await other.execute(
          'SELECT entity_id, id FROM config_change ORDER BY id');
      expect(ids.first[0], 'CN01.Slow.Commit',
          reason: 'the whole test rests on tx1 having taken the lower id');
      expect((ids.first[1]! as num).toInt(), lessThan(watermark));

      // Every fast path in the design, and none of them can see it.
      await a.pullChanges();
      expect(identifierOf(a, 'CN01.Slow.Commit'), isNull,
          reason: 'this is C-6 itself: the row is committed and visible in '
              'config_item, and no watermark read will ever name it');

      // The net.
      await a.reconcile();
      expect(identifierOf(a, 'CN01.Slow.Commit'), 'GVL.Conveyors[1].Speed');
      expect(identifierOf(a, 'CN02.Fast.Commit'), 'GVL.Conveyors[2].Speed');
    });

    // LAST: this one kills the shared connection for everything after it.
    test('a mid-session outage is reported as offline, not as a driver string',
        () async {
      final a = await newStation();
      await save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'});

      await stopTimescaleDb();
      try {
        await expectLater(
          save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].SpeedActual'}),
          throwsA(isA<ConfigStoreOfflineException>()
              .having((e) => e.cause, 'cause', isNotNull)
              .having((e) => e.toString(), 'message',
                  contains('CN04.Belt.Speed'))),
        );
      } finally {
        await startTimescaleDb();
      }

      // Recovery. The pool re-opens on demand, so the first write after the
      // proxy comes back may still meet a socket that died during the outage;
      // what must not happen is that the store stays offline.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        try {
          await save(a, {'CN04.Belt.Speed': 'GVL.Conveyors[4].SpeedActual'});
          break;
        } on ConfigStoreOfflineException {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      // A fresh connection for the assertion: `other` rode the same proxy and
      // was killed with everything else, and a raw `pg.Connection` does not
      // reconnect itself — only the pool behind the store does. Asserting on
      // it here would report the test harness's outage as the store's.
      final verifier = await getTestConnection();
      addTearDown(verifier.close);
      final rows = await verifier.execute(
          "SELECT id, payload, rev FROM config_item WHERE kind = 'key_mapping'");
      expect(rows.single[1],
          payloadOf('CN04.Belt.Speed', 'GVL.Conveyors[4].SpeedActual'));
      expect((rows.single[2]! as num).toInt(), 2);
    });
  },
      // The whole group shares one Docker Postgres and one connection; the
      // notification tests wait out real deadlines.
      timeout: const Timeout(Duration(minutes: 10)));
}
