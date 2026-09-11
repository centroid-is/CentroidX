// The Riverpod layer between `AuditTrailStore` and the audit trail page.
//
// Phase 2 ruled that **unavailable** and **empty** must be distinguishable, and
// the whole of that distinction is carried by this file's providers.
// `databaseProvider` answers null both when Postgres was never configured and
// when the connection threw, and both mean "the trail is unavailable". An empty
// list in either case would claim nothing had ever happened on the station,
// which is the one failure mode an audit trail cannot have.
//
// So the three answers the page must be able to tell apart each get their own
// named test here: a resolved **null**, a thrown **error**, and a non-null
// result whose `actions` happen to be empty.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tfc/core/audit_trail_grouping.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;

/// The instant every window assertion is written against, matching
/// `test/core/audit_trail_store_test.dart` so the two suites read alike.
final DateTime _now = DateTime.utc(2026, 8, 30, 12);

/// The `Database` wrapper `databaseProvider` yields, over an in-memory Drift
/// database. Only `db` is reached by anything under test.
class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;
}

/// A store that counts what reached the database, and can be made to throw.
///
/// The counts are the only way to tell "the family answered from cache" from
/// "the family issued a second identical statement" — both look the same from
/// the resolved value, and only one of them is a filter chip tap costing two
/// round trips.
class _CountingStore extends Fake implements AuditTrailStore {
  _CountingStore(this.inner);

  final AuditTrailStore inner;

  int entriesCalls = 0;
  int totalsCalls = 0;
  bool throwing = false;

  @override
  Future<List<AuditRecord>> entries(AuditQuery query) {
    entriesCalls++;
    if (throwing) throw StateError('the audit database blinked');
    return inner.entries(query);
  }

  @override
  Future<Map<String, int>> memberCountsByAction(Iterable<String> actionIds) {
    totalsCalls++;
    return inner.memberCountsByAction(actionIds);
  }

  @override
  Future<List<String>> distinctWho() => inner.distinctWho();
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    // Force the schema before the first provider read, so an empty result is a
    // real empty table rather than a missing one.
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() => db.close());

  /// Appends one row through the trail's only writer.
  ///
  /// Going through [DriftAuditSink] rather than inserting a companion directly
  /// is what keeps this fixture honest about column mapping: a renamed column
  /// breaks the seed as well as the query.
  Future<void> seed({
    required DateTime at,
    String who = 'engineer',
    String itemKey = 'CN04.MOT01.p_cmd_Run',
    String? member,
    String groupRequired = 'configure',
    bool allowed = true,
    String surface = 'tag',
    String actionId = 'action-a',
  }) =>
      DriftAuditSink(db).record(AuditRecord(
        at: at,
        who: who,
        station: 'SVN-NES-OT-CL02',
        roleName: 'Engineering',
        surface: surface,
        itemKey: itemKey,
        member: member,
        oldValue: '0',
        newValue: '1',
        groupRequired: groupRequired,
        allowed: allowed,
        actionId: actionId,
      ));

  /// A container over the in-memory database — the ordinary station.
  ///
  /// The device-local store is overridden because 17-12 made the store
  /// provider consult the transport row (`gatewayConfigProvider`) before
  /// deciding its route; an empty in-memory row reads as direct mode, which
  /// is the station these arms are about.
  ProviderContainer wired() {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// A container with no database at all — the station commissioned without
  /// Postgres, and the boot window before the connection opens. The two are
  /// indistinguishable by design.
  ProviderContainer databaseless() {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => null),
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  // -------------------------------------------------------------------------
  // The store provider — the unavailable signal itself
  // -------------------------------------------------------------------------

  group('auditTrailStoreProvider', () {
    test('resolves to null when this station has no database', () async {
      final store = await databaseless().read(auditTrailStoreProvider.future);

      expect(store, isNull,
          reason: 'null is the unavailable signal. A store over nothing, or an '
              'empty result, would let the page claim nothing has ever '
              'happened on a station whose database is merely unreachable.');
    });

    test('resolves to a store when the database is there', () async {
      final store = await wired().read(auditTrailStoreProvider.future);

      expect(store, isA<AuditTrailStore>());
    });
  });

  // -------------------------------------------------------------------------
  // The `who` dropdown's options
  // -------------------------------------------------------------------------

  group('auditWhoOptionsProvider', () {
    test('answers an empty list without a database, and does not throw',
        () async {
      final who = await databaseless().read(auditWhoOptionsProvider.future);

      expect(who, isEmpty,
          reason: 'a who dropdown with no options on an unreachable database '
              'is correct; an exception here would take the whole filter bar '
              'down with it. The page says "unavailable" once, from the '
              'entries provider, and not twice.');
    });

    test('answers every distinct who in the table, sorted', () async {
      await seed(at: _now, who: 'operator');
      await seed(at: _now, who: 'engineer');
      await seed(at: _now, who: 'engineer');

      final who = await wired().read(auditWhoOptionsProvider.future);

      expect(who, ['engineer', 'operator']);
    });
  });

  // -------------------------------------------------------------------------
  // The query family
  // -------------------------------------------------------------------------

  /// A container whose store is [store], over the same in-memory database.
  ProviderContainer withStore(AuditTrailStore store) {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
      auditTrailStoreProvider.overrideWith((ref) async => store),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// The counting store over the real one, and a container reading it.
  ({_CountingStore store, ProviderContainer container}) counted() {
    final store = _CountingStore(AuditTrailStore(db: db));
    return (store: store, container: withStore(store));
  }

  AuditQuery defaultQuery() => const AuditTrailFilters().toQuery(now: _now);

  group('auditTrailEntriesProvider — unavailable, error and empty', () {
    test('resolves to null when this station has no database', () async {
      final result = await databaseless()
          .read(auditTrailEntriesProvider(defaultQuery()).future);

      expect(result, isNull,
          reason: 'Phase 2 ruled that unavailable and empty must be '
              'distinguishable. An empty AuditTrailResult here would let the '
              'page claim nothing has ever happened on a station whose '
              'database is merely unreachable.');
    });

    test('an empty match resolves to a result, not to null', () async {
      final result =
          await wired().read(auditTrailEntriesProvider(defaultQuery()).future);

      expect(result, isNotNull,
          reason: 'the other half of the same ruling: no rows matched is a '
              'value, and the page renders "No entries match these filters" '
              'for it rather than "the trail is unavailable".');
      expect(result!.actions, isEmpty);
      expect(result.rowCount, 0);
      expect(result.oldestAt, isNull);
    });

    test('a store failure propagates as an error, not as null or as empty',
        () async {
      final wiring = counted();
      wiring.store.throwing = true;

      await expectLater(
        wiring.container.read(auditTrailEntriesProvider(defaultQuery()).future),
        throwsA(isA<StateError>()),
        reason: 'the page treats an error as unavailable. Swallowing it here '
            'would hide a real fault behind "nothing matched".',
      );
    });
  });

  group('auditTrailEntriesProvider — the family key', () {
    test('two separately-constructed equal queries hit one provider instance',
        () async {
      final wiring = counted();
      final q1 = defaultQuery();
      final q2 = defaultQuery();

      expect(identical(q1, q2), isFalse,
          reason: 'the point of the test is two objects, not two names for '
              'one');
      expect(q1, q2);

      final subA = wiring.container
          .listen(auditTrailEntriesProvider(q1), (_, __) {});
      addTearDown(subA.close);
      final subB = wiring.container
          .listen(auditTrailEntriesProvider(q2), (_, __) {});
      addTearDown(subB.close);

      final f1 = wiring.container.read(auditTrailEntriesProvider(q1).future);
      final f2 = wiring.container.read(auditTrailEntriesProvider(q2).future);

      expect(identical(f1, f2), isTrue,
          reason: 'a family keyed on a broken == re-queries the database on '
              'every rebuild, and a filter chip tap would cost two round '
              'trips instead of one.');
      await f1;
      expect(wiring.store.entriesCalls, 1);
    });

    test('a different query issues a second query', () async {
      final wiring = counted();

      await wiring.container
          .read(auditTrailEntriesProvider(defaultQuery()).future);
      await wiring.container.read(auditTrailEntriesProvider(
              const AuditTrailFilters(keyPrefix: 'CN04').toQuery(now: _now))
          .future);

      expect(wiring.store.entriesCalls, 2,
          reason: 'changing a filter must issue a new query rather than '
              'filter what is already loaded — all filtering is pushed into '
              'SQL, applied in WHERE before LIMIT.');
    });

    test('leaving the page frees the result — the next visit re-queries',
        () async {
      final wiring = counted();
      final query = defaultQuery();

      final sub =
          wiring.container.listen(auditTrailEntriesProvider(query), (_, __) {});
      await wiring.container.read(auditTrailEntriesProvider(query).future);
      expect(wiring.store.entriesCalls, 1);

      sub.close();
      await Future<void>.delayed(Duration.zero);

      await wiring.container.read(auditTrailEntriesProvider(query).future);

      expect(wiring.store.entriesCalls, 2,
          reason: 'the query provider is autoDispose. A keepAlive one would '
              'answer from a cache nobody reads and hold a database handle on '
              'behalf of a page that is gone.');
    });
  });

  group('auditTrailEntriesProvider — grouped results', () {
    test('rows come back grouped by actionId, newest action first', () async {
      // Another station's row lands between the two members of `one`, which is
      // routine on a site where several stations share one database. The
      // grouping is map-based for exactly this: adjacency grouping would split
      // `one` in two and neither half would say so.
      await seed(
          at: _now.subtract(const Duration(hours: 1)),
          itemKey: 'a',
          actionId: 'one');
      await seed(
          at: _now.subtract(const Duration(hours: 2)),
          itemKey: 'b',
          actionId: 'two');
      await seed(
          at: _now.subtract(const Duration(hours: 3)),
          itemKey: 'c',
          actionId: 'one');

      final result =
          await wired().read(auditTrailEntriesProvider(defaultQuery()).future);

      final List<AuditAction> actions = result!.actions;
      expect(actions.map((a) => a.actionId), ['one', 'two']);
      expect(actions.first.rows, hasLength(2));
      expect(result.rowCount, 3,
          reason: 'rowCount is the pre-grouping row count — what the LIMIT '
              'applied to, not what the page draws.');
    });

    test('a nine-member action filtered to three reports six hidden', () async {
      for (var i = 0; i < 3; i++) {
        await seed(
          at: _now.subtract(Duration(minutes: i)),
          member: 'speed$i',
          groupRequired: 'device',
          actionId: 'recipe-apply',
        );
      }
      for (var i = 0; i < 6; i++) {
        await seed(
          at: _now.subtract(Duration(minutes: 10 + i)),
          member: 'setpoint$i',
          groupRequired: 'configure',
          actionId: 'recipe-apply',
        );
      }

      final result = await wired().read(auditTrailEntriesProvider(
        const AuditTrailFilters(groupNames: ['device']).toQuery(now: _now),
      ).future);

      final action = result!.actions.single;
      expect(action.rows, hasLength(3));
      expect(action.totalRowCount, 9);
      expect(action.hiddenCount, 6,
          reason: 'the store\'s companion count query and the grouping '
              'function have to be wired to each other, not merely each work '
              'alone: the six non-matching members are not in the result set '
              'at all, so "6 of 9 members hidden by filters" cannot be '
              'derived from the page.');
      expect(action.isPartial, isTrue);
    });

    test('oldestAt is the at of the last row — the load-more cursor', () async {
      final oldest = _now.subtract(const Duration(days: 2));
      await seed(at: _now.subtract(const Duration(hours: 1)), itemKey: 'new');
      await seed(at: oldest, itemKey: 'old');

      final result =
          await wired().read(auditTrailEntriesProvider(defaultQuery()).future);

      expect(result!.oldestAt!.toUtc(), oldest);
    });
  });

  group('auditTrailEntriesProvider — reachedLimit', () {
    test('is true when the row count equals the limit', () async {
      await seed(at: _now, itemKey: 'a');
      await seed(at: _now, itemKey: 'b');

      final result = await wired().read(auditTrailEntriesProvider(
        AuditQuery(
          window: AuditWindow(start: _now.subtract(const Duration(days: 7)), end: _now),
          limit: 2,
        ),
      ).future);

      expect(result!.rowCount, 2);
      expect(result.reachedLimit, isTrue,
          reason: 'the page shows the "Load more" affordance from this, and a '
              'window that filled its cap is the case where there may be '
              'older rows the operator has not seen.');
    });

    test('is false when fewer rows than the limit came back', () async {
      await seed(at: _now, itemKey: 'a');

      final result = await wired().read(auditTrailEntriesProvider(
        AuditQuery(
          window: AuditWindow(start: _now.subtract(const Duration(days: 7)), end: _now),
          limit: 2,
        ),
      ).future);

      expect(result!.reachedLimit, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // What this file may not contain
  // -------------------------------------------------------------------------

  group('the source of lib/providers/audit_trail.dart', () {
    late String source;

    setUpAll(() {
      final file = File('lib/providers/audit_trail.dart');
      expect(file.existsSync(), isTrue,
          reason: 'run this suite from the repository root. Without the file '
              'these source assertions would pass vacuously.');
      final withoutBlockComments = file
          .readAsStringSync()
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
      source = withoutBlockComments
          .split('\n')
          .map((line) {
            final idx = line.indexOf('//');
            return idx == -1 ? line : line.substring(0, idx);
          })
          .join('\n');
    });

    test('starts no timer', () {
      expect(source, isNot(contains('Timer')),
          reason: 'CONTEXT ruled this page has no timer. An always-on '
              'Timer.periodic in this repo\'s plumbing has broken unrelated '
              'widget tests, and a self-scrolling audit list is unreadable. '
              'Refresh is ref.invalidate. Any future live-update hook must be '
              'listener-gated — started in onListen, stopped in onCancel.');
    });

    test('holds no AuditSink and cannot record', () {
      expect(source, isNot(contains('AuditSink')),
          reason: 'reading the trail must not write to it. A row per render '
              'would bury the writes that matter under rows recording that '
              'somebody looked.');
    });

    test('performs no permission check', () {
      expect(source, isNot(contains('AccessDenied')),
          reason: 'the route gate is the enforcement. A check here would be '
              'mistaken for it, and a second gate that disagrees with the '
              'route is worse than one gate.');
    });
  });
}
