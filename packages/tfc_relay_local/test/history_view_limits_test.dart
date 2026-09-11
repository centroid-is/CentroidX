/// The row ceiling on the five history-view reads (10-REVIEW WR-05).
///
/// ## Why these five needed one and the default lane can judge it
///
/// A history-view answer goes into the session's **priority lane**, which is
/// un-conflated, and `_Connection.flushPriority` writes the whole lane to the
/// socket *before* the 4004 on the way to a close. So an unbounded answer here
/// is not a slow chart: it is an eviction, reported to the panel as
/// backpressure when what happened is that it asked for too much.
///
/// What made that reachable rather than theoretical is that these row counts
/// are **caller-grown** — `historyCreateView` and `historyAddPeriod` are row
/// factories in a table shared with the plant's own HMI, and until CR-03 they
/// took no role at all.
///
/// The subject is the ceiling, not Postgres, so this runs in the ordinary lane
/// over drift's own schema on an in-memory database. What a real server does
/// with these rows is `history_view_read_test.dart`'s, and it stays there.
@TestOn('vm')
library;

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_relay_local/src/data/history_view_store.dart';
import 'package:tfc_relay_local/src/data/read_limits.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show DataServiceMethods, ResultSizeUnit, ResultTooLarge;

/// Two rows, so three is over and two is not. The production default is 5 000;
/// what is under test is the ceiling's behaviour at its own boundary, and a
/// case that had to write five thousand views to reach it would be a case
/// nobody runs.
const int ceiling = 2;

final DateTime _start = DateTime.utc(2026, 9, 3, 6);

void main() {
  late Database db;
  late HistoryViewStore store;
  late HistoryViewStore unbounded;

  setUp(() async {
    db = Database(AppDatabase.forTest(
        DatabaseConfig(), NativeDatabase.memory(logStatements: false)));
    addTearDown(db.close);
    store = HistoryViewStore(
        database: () => db,
        limits: ReadLimits(maxHistoryViewRows: ceiling));
    // The same rows through a store with the production default, so every
    // "refused" arm below has a companion proving the rows are really there
    // and the refusal is the ceiling rather than an empty table.
    unbounded = HistoryViewStore(database: () => db);
  });

  group('the picker', () {
    test('answers at the ceiling', () async {
      for (var i = 0; i < ceiling; i++) {
        await store.createHistoryView('Vaktir $i', const <String>['CN01.a']);
      }

      expect(await store.selectHistoryViews(), hasLength(ceiling),
          reason: 'the boundary in the direction that matters: a check '
              'written >= would refuse the largest legitimate picker there is');
    });

    test('refuses one row over it, naming the count and the way out',
        () async {
      for (var i = 0; i <= ceiling; i++) {
        await store.createHistoryView('Vaktir $i', const <String>['CN01.a']);
      }

      expect(await unbounded.selectHistoryViews(), hasLength(ceiling + 1),
          reason: 'the rows are really there — the refusal below is a ceiling '
              'and not an empty table');

      ResultTooLarge? caught;
      try {
        await store.selectHistoryViews();
      } on ResultTooLarge catch (error) {
        caught = error;
      }

      expect(caught, isNotNull,
          reason: 'unbounded, this answer reaches the un-conflated priority '
              'lane and the panel is evicted with 4004 — told it disconnected '
              'when it asked for too much. That misreport is the whole reason '
              'ResultTooLarge exists');
      expect(caught!.unit, ResultSizeUnit.rows);
      expect(caught.limit, ceiling);
      expect(caught.measured, ceiling + 1);
      expect(caught.atLeast, isFalse,
          reason: 'exact, and deliberately unlike the reader\'s row refusals: '
              'those detect with LIMIT n+1 and can only report a floor, while '
              'this one counted rows it already holds. Claiming "at least" '
              'here would be hedging a number that is not in doubt');
      expect(caught.message, contains(DataServiceMethods.historyDeleteView),
          reason: 'a picker has no downsampled form, so the honest suggestion '
              'is the delete that makes the answer small again');
      expect(caught.message, contains('created by clients'),
          reason: 'and the sentence has to say that the count is one somebody '
              'grew, or an engineer goes looking for a plant that produced it');
    });
  });

  group('a view\'s own rows', () {
    test('keys, key names, graphs and periods each take the ceiling',
        () async {
      final id = await store.createHistoryView(
          'Vaktir', <String>[for (var i = 0; i <= ceiling; i++) 'CN0$i.a']);
      for (var i = 0; i <= ceiling; i++) {
        await store.addHistoryViewPeriod(id, 'Vakt $i', _start,
            _start.add(Duration(hours: i + 1)));
      }

      // The anti-vacuity companion for all four: the rows exist, so each
      // refusal below is the ceiling firing.
      expect(await unbounded.getHistoryViewKeyNames(id),
          hasLength(ceiling + 1));
      expect(await unbounded.listHistoryViewPeriods(id),
          hasLength(ceiling + 1));

      await expectLater(store.getHistoryViewKeys(id),
          throwsA(isA<ResultTooLarge>()),
          reason: 'a view\'s key list is as caller-grown as the picker is');
      await expectLater(store.getHistoryViewKeyNames(id),
          throwsA(isA<ResultTooLarge>()),
          reason: 'the two key accessors read the same rows, and a bound '
              'fitted to one and forgotten on the other is the same answer '
              'through the other door');
      await expectLater(store.listHistoryViewPeriods(id),
          throwsA(isA<ResultTooLarge>()));
    });

    test('a view inside the ceiling still answers on all four', () async {
      final id = await store
          .createHistoryView('Vaktir', const <String>['CN01.a', 'CN02.a']);
      await store.addHistoryViewPeriod(
          id, 'Vakt 1', _start, _start.add(const Duration(hours: 8)));

      expect(await store.getHistoryViewKeys(id), hasLength(2));
      expect(await store.getHistoryViewKeyNames(id), hasLength(2));
      expect(await store.getHistoryViewGraphs(id), isEmpty);
      expect(await store.listHistoryViewPeriods(id), hasLength(1));
    });
  });

  test('the ceiling is refused at construction if it is not positive', () {
    expect(() => ReadLimits(maxHistoryViewRows: 0), throwsArgumentError,
        reason: 'a zero ceiling refuses every read, and a gateway that '
            'refuses every read presents to an operator as "you have saved '
            'nothing" — which is a picker they save their view into a second '
            'time');
  });
}
