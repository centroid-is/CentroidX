// The first reader of `config_change`, and the three things it must not do:
// write, intersect its kind filter with the sync set, or let an empty result
// mean "nothing happened".
//
// Every window assertion is written against a fixed
// `DateTime.utc(2026, 8, 30, 12)`, the same instant
// `test/core/audit_trail_store_test.dart` uses, so the two suites read alike
// and neither computes an expectation from the clock it is testing.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/core/config_change_store.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_history_policy.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart' show kSharedConfigKinds;
import 'package:tfc_dart/core/database_drift.dart';

/// The instant every window assertion is written against.
final DateTime _now = DateTime.utc(2026, 8, 30, 12);

/// An `encodeEntity()`-shaped side: `{parent_id, sort_index, payload}`.
///
/// Spelled out rather than built from a `ConfigItem` in the places where the
/// test is about the *string*, so a reader can see that a move changes the
/// row's sides while the payload stays put.
String _entity({String? parentId, int? sortIndex, Map<String, Object?>? payload}) =>
    jsonEncode({
      'parent_id': parentId,
      'sort_index': sortIndex,
      'payload': payload ?? const {'name': 'MOT01'},
    });

/// Insert one `config_change` row directly, so the reader is tested against
/// rows it did not write. Returns the row id.
Future<int> _seed(
  AppDatabase db, {
  required String actionId,
  DateTime? at,
  String who = 'olafur',
  String station = 'ST101',
  String roleName = 'engineer',
  String kind = 'asset',
  String entityId = 'CN04.MOT01',
  String scope = 'shared',
  String op = 'update',
  String? oldValue,
  String? newValue,
  String? reason,
}) async {
  final statement = db.into(db.configChangeTable).insertReturning(
    ConfigChangeTableCompanion.insert(
      at: at ?? _now,
      actionId: actionId,
      who: who,
      station: station,
      roleName: roleName,
      kind: kind,
      entityId: entityId,
      scope: scope,
      op: op,
      oldValue: Value(oldValue ?? _entity(parentId: '/roe', sortIndex: 1)),
      newValue: Value(newValue ?? _entity(parentId: '/roe', sortIndex: 2)),
      reason: Value(reason),
    ),
  );
  return (await statement).id;
}

void main() {
  late AppDatabase db;
  late ConfigChangeStore store;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    // Force the schema before the first read, so an empty result is a real
    // empty table rather than a missing one.
    await db.customSelect('SELECT 1').getSingle();
    store = ConfigChangeStore(db: db);
  });

  tearDown(() => db.close());

  // -------------------------------------------------------------------------
  // changesByAction — the join the whole view is built on
  // -------------------------------------------------------------------------

  group('changesByAction', () {
    test('returns one action\'s rows, ordered by id', () async {
      for (var i = 0; i < 3; i++) {
        await _seed(db, actionId: 'A', entityId: 'asset-$i');
      }
      await _seed(db, actionId: 'B', entityId: 'other');

      final byAction = await store.changesByAction(['A']);

      expect(byAction.keys, ['A']);
      expect(byAction['A']!.map((r) => r.change.entityId),
          ['asset-0', 'asset-1', 'asset-2']);
      expect(byAction['A']!.map((r) => r.id).toList(),
          [byAction['A']![0].id, byAction['A']![1].id, byAction['A']![2].id]);
      final ids = byAction['A']!.map((r) => r.id).toList();
      expect(ids, orderedEquals([...ids]..sort()),
          reason: 'id ascending is the order the rows were written in, which '
              'is the order an undo would have to reverse.');
    });

    test('groups several actions in one statement', () async {
      await _seed(db, actionId: 'A');
      await _seed(db, actionId: 'B');
      await _seed(db, actionId: 'B');

      final byAction = await store.changesByAction(['A', 'B']);

      expect(byAction['A'], hasLength(1));
      expect(byAction['B'], hasLength(2));
    });

    test('an empty id list issues no statement and returns an empty map',
        () async {
      expect(await store.changesByAction(const []), isEmpty);
    });

    test('an unknown action is absent from the map, not present with an empty '
        'list', () async {
      final byAction = await store.changesByAction(['nobody-wrote-this']);
      expect(byAction.containsKey('nobody-wrote-this'), isFalse,
          reason: 'an empty list would be a claim about the action rather '
              'than the absence of one.');
    });

    test('decodes both sides as encodeEntity, so a move is a change',
        () async {
      const payload = {'name': 'MOT01'};
      await _seed(
        db,
        actionId: 'A',
        oldValue: _entity(parentId: '/roe', sortIndex: 1, payload: payload),
        newValue: _entity(parentId: '/baader', sortIndex: 1, payload: payload),
      );

      final row = (await store.changesByAction(['A']))['A']!.single;

      expect(row.change.oldValue, isNot(row.change.newValue),
          reason: 'the sides are encodeEntity(), so a move to another page '
              'differs even though nothing inside the payload moved. A reader '
              'that compared payloads would report "no change" here.');
      expect(row.change.oldItem!.parentId, '/roe');
      expect(row.change.newItem!.parentId, '/baader');
    });

    test('a row whose kind this build has never heard of is skipped, not fatal',
        () async {
      await _seed(db, actionId: 'A', kind: 'from_a_newer_build');
      await _seed(db, actionId: 'A', kind: 'asset');

      final rows = (await store.changesByAction(['A']))['A']!;

      expect(rows, hasLength(1),
          reason: 'ConfigKind.byWireName answers null for a wire name a newer '
              'station wrote, and both enums document that as skippable '
              'rather than fatal to the whole read.');
      expect(rows.single.change.kind, ConfigKind.asset);
    });

    test('a skipped row is still counted, so it surfaces as a hidden sibling',
        () async {
      await _seed(db, actionId: 'A', kind: 'from_a_newer_build');
      await _seed(db, actionId: 'A', kind: 'asset');

      final rows = (await store.changesByAction(['A']))['A']!;
      final counts = await store.changeCountsByAction(['A']);

      expect(rows, hasLength(1));
      expect(counts['A'], 2,
          reason: 'the count is over the table, not over what decoded. An '
              'undecodable row must read as "1 of 2 hidden", never vanish.');
    });

    test('a malformed scope is skipped the same way', () async {
      await _seed(db, actionId: 'A', scope: 'station:');
      expect((await store.changesByAction(['A']))['A'], isNull);
    });

    test('an unknown op is skipped the same way', () async {
      await _seed(db, actionId: 'A', op: 'upsert');
      expect((await store.changesByAction(['A']))['A'], isNull);
    });
  });

  // -------------------------------------------------------------------------
  // changeCountsByAction — the honest hidden count
  // -------------------------------------------------------------------------

  group('changeCountsByAction', () {
    test('counts the whole table, not the loaded page', () async {
      for (var i = 0; i < 9; i++) {
        await _seed(db, actionId: 'A', entityId: 'asset-$i');
      }

      final loaded = await store.changes(ConfigChangeQuery(
        entityPrefix: 'asset-1',
        limit: 500,
      ));
      final counts = await store.changeCountsByAction(['A']);

      expect(loaded, hasLength(1));
      expect(counts['A'], 9,
          reason: 'the filters excluded eight rows in SQL, so they are not in '
              'the result set and cannot be counted from it. "1 of 9" has to '
              'come from a statement issued outside the predicate.');
    });

    test('an empty id list returns an empty map', () async {
      expect(await store.changeCountsByAction(const []), isEmpty);
    });

    test('an unknown id is absent rather than zero', () async {
      expect((await store.changeCountsByAction(['X'])).containsKey('X'),
          isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The windowed read
  // -------------------------------------------------------------------------

  group('changes', () {
    test('is newest first, ties broken by id descending', () async {
      await _seed(db, actionId: 'A', at: _now.subtract(const Duration(days: 1)));
      final second = await _seed(db, actionId: 'B', at: _now);
      final third = await _seed(db, actionId: 'C', at: _now);

      final rows = await store.changes(ConfigChangeQuery());

      expect(rows.map((r) => r.id).take(2), [third, second],
          reason: 'a page save writes N rows at one instant; without the id '
              'tiebreak two runs of the same query could return them in '
              'different orders and the page would reshuffle.');
    });

    test('honours a closed window on both ends', () async {
      await _seed(db, actionId: 'old', at: DateTime.utc(2026, 8, 1));
      await _seed(db, actionId: 'in', at: DateTime.utc(2026, 8, 29));
      await _seed(db, actionId: 'new', at: DateTime.utc(2026, 9, 5));

      final rows = await store.changes(ConfigChangeQuery(
        window: AuditWindow(
          start: DateTime.utc(2026, 8, 20),
          end: DateTime.utc(2026, 8, 31),
        ),
      ));

      expect(rows.map((r) => r.change.actionId), ['in'],
          reason: 'drift wraps two Expression<DateTime> in JULIANDAY(), which '
              'Postgres does not have. The comparison must be on the stored '
              'text or this clause dies on every real station while every '
              'test passes.');
    });

    test('before is a cursor that composes with the window', () async {
      await _seed(db, actionId: 'A', at: DateTime.utc(2026, 8, 29));
      await _seed(db, actionId: 'B', at: DateTime.utc(2026, 8, 30, 6));

      final rows = await store.changes(ConfigChangeQuery(
        window: AuditWindow(start: DateTime.utc(2026, 8, 28), end: _now),
        before: DateTime.utc(2026, 8, 30),
      ));

      expect(rows.map((r) => r.change.actionId), ['A']);
    });

    test('the entity prefix is a LIKE that only ever widens', () async {
      await _seed(db, actionId: 'A', entityId: 'CN04.MOT01');
      await _seed(db, actionId: 'B', entityId: 'CN05.MOT01');

      expect(
        (await store.changes(ConfigChangeQuery(entityPrefix: 'CN04')))
            .map((r) => r.change.entityId),
        ['CN04.MOT01'],
      );
      expect(
        await store.changes(ConfigChangeQuery(entityPrefix: "x' OR 1=1 --")),
        isEmpty,
        reason: 'every value is a bound variable, so a quote in the search '
            'field returns rows or no rows and never changes the statement.',
      );
    });

    test('an operator-typed wildcard widens and cannot reach a filtered-out '
        'row', () async {
      await _seed(db, actionId: 'A', entityId: 'CN04.MOT01', who: 'olafur');
      await _seed(db, actionId: 'B', entityId: 'CN05.MOT01', who: 'jon');

      final rows = await store.changes(
          ConfigChangeQuery(entityPrefix: 'CN0%', who: 'olafur'));

      expect(rows.map((r) => r.change.entityId), ['CN04.MOT01'],
          reason: 'the prefix clause is ANDed with every other one, so a '
              'wildcard can never reach a row another filter excluded.');
    });

    test('who is an exact match', () async {
      await _seed(db, actionId: 'A', who: 'olafur');
      await _seed(db, actionId: 'B', who: 'olafursson');

      final rows = await store.changes(ConfigChangeQuery(who: 'olafur'));
      expect(rows, hasLength(1));
    });

    test('an empty kind selection is no constraint at all', () async {
      await _seed(db, actionId: 'A', kind: 'asset');
      await _seed(db, actionId: 'B', kind: 'preference');

      final rows = await store.changes(ConfigChangeQuery());

      expect(rows, hasLength(2),
          reason: 'deselecting every chip shows everything, exactly as '
              'AlarmLevelFilterChips behaves. It reads backwards on first '
              'encounter, which is why it is asserted rather than assumed.');
    });

    test('a named kind selection constrains to those kinds', () async {
      await _seed(db, actionId: 'A', kind: 'asset');
      await _seed(db, actionId: 'B', kind: 'preference');

      final rows = await store.changes(
          ConfigChangeQuery(kinds: const [ConfigKind.preference]));

      expect(rows.map((r) => r.change.kind), [ConfigKind.preference]);
    });

    test('preference is readable, because nothing here intersects with '
        'kSharedConfigKinds', () async {
      await _seed(db, actionId: 'A', kind: 'preference', scope: 'shared');
      await _seed(db, actionId: 'B', kind: 'preference', scope: 'station:ST101');

      final all = await store.changes(ConfigChangeQuery());
      final named = await store.changes(
          ConfigChangeQuery(kinds: const [ConfigKind.preference]));

      expect(all, hasLength(2));
      expect(named, hasLength(2),
          reason: 'ConfigKind.preference is deliberately NOT in '
              'kSharedConfigKinds — that set says what the sync propagates, '
              'not what the history holds. A read scoped by intersecting the '
              'two would silently return nothing for every preference change '
              'anybody ever made.');
      expect(kSharedConfigKinds.contains(ConfigKind.preference), isFalse,
          reason: 'if this ever becomes true the paragraph above needs '
              'rewriting, not deleting.');
    });

    test('scope filtering names station scopes by their wire form', () async {
      await _seed(db, actionId: 'A', scope: 'shared');
      await _seed(db, actionId: 'B', scope: 'station:ST101');

      final rows = await store.changes(
          ConfigChangeQuery(scopeWireNames: const ['station:ST101']));

      expect(rows.map((r) => r.change.scope.station), ['ST101']);
    });

    test('the limit applies after every clause', () async {
      for (var i = 0; i < 5; i++) {
        await _seed(db, actionId: 'A', entityId: 'asset-$i');
      }
      final rows = await store.changes(ConfigChangeQuery(limit: 2));
      expect(rows, hasLength(2));
    });
  });

  // -------------------------------------------------------------------------
  // The two-mode window rule, inherited from AuditTrailFilters
  // -------------------------------------------------------------------------

  group('ConfigHistoryFilters.toQuery', () {
    test('defaults to the seven-day window', () {
      final query = const ConfigHistoryFilters().toQuery(now: _now);
      expect(query.window!.end, _now);
      expect(query.window!.start, _now.subtract(kAuditTrailDefaultWindow));
    });

    test('a search drops the time bound entirely', () {
      final query =
          const ConfigHistoryFilters(entityPrefix: 'CN04').toQuery(now: _now);
      expect(query.window, isNull,
          reason: 'searching must answer "has anyone ever changed this asset", '
              'not "did anyone this week".');
    });

    test('an explicit range wins over the search escape', () {
      final range = AuditWindow(
          start: DateTime.utc(2026, 8, 1), end: DateTime.utc(2026, 8, 2));
      final query = ConfigHistoryFilters(entityPrefix: 'CN04', range: range)
          .toQuery(now: _now);
      expect(query.window, range);
    });

    test('a whitespace-only prefix does not drop the bound', () {
      final query =
          const ConfigHistoryFilters(entityPrefix: '   ').toQuery(now: _now);
      expect(query.window, isNotNull);
    });

    test('the cursor is carried through untouched', () {
      final before = DateTime.utc(2026, 8, 25);
      final query = const ConfigHistoryFilters().toQuery(now: _now, before: before);
      expect(query.before, before);
      expect(query.window, isNotNull,
          reason: 'paging narrows an existing window rather than replacing the '
              'rule that produced it.');
    });

    test('queries with the same fields are equal, so a family does not '
        're-query on every rebuild', () {
      expect(const ConfigHistoryFilters().toQuery(now: _now),
          const ConfigHistoryFilters().toQuery(now: _now));
      expect(const ConfigHistoryFilters().toQuery(now: _now).hashCode,
          const ConfigHistoryFilters().toQuery(now: _now).hashCode);
    });

    test('kind order at the call site does not change the query', () {
      expect(
        ConfigChangeQuery(
            kinds: const [ConfigKind.asset, ConfigKind.page]),
        ConfigChangeQuery(
            kinds: const [ConfigKind.page, ConfigKind.asset]),
      );
    });
  });

  // -------------------------------------------------------------------------
  // "no history" is not "nothing happened"
  // -------------------------------------------------------------------------

  group('entityHistory', () {
    test('an entity with rows returns them newest first', () async {
      await _seed(db,
          actionId: 'A', entityId: 'CN04.MOT01', at: DateTime.utc(2026, 8, 20));
      await _seed(db,
          actionId: 'B', entityId: 'CN04.MOT01', at: DateTime.utc(2026, 8, 25));

      final history = await store.entityHistory(
          kind: ConfigKind.asset,
          entityId: 'CN04.MOT01',
          scope: ConfigScope.shared);

      expect(history.historyKept, isTrue);
      expect(history.isSilent, isFalse);
      expect(history.rows.map((r) => r.change.actionId), ['B', 'A']);
    });

    test('an entity nothing ever touched is empty and history-kept', () async {
      final history = await store.entityHistory(
          kind: ConfigKind.asset,
          entityId: 'never-touched',
          scope: ConfigScope.shared);

      expect(history.rows, isEmpty);
      expect(history.historyKept, isTrue);
      expect(history.isSilent, isFalse,
          reason: 'nothing happened to this entity — which is a different '
              'answer from "this kind keeps no history", and the view has to '
              'be able to tell them apart.');
    });

    test('a history-exempt kind reports silence, not absence', () async {
      final history = await store.entityHistory(
          kind: ConfigKind.pageImage,
          entityId: 'sha256-abc',
          scope: ConfigScope.shared);

      expect(history.rows, isEmpty);
      expect(history.historyKept, isFalse);
      expect(history.isSilent, isTrue,
          reason: 'page images write no config_change rows at all. Rendering '
              'that as "no changes" would tell an operator the image has '
              'never been replaced, which the log simply does not know.');
    });

    test('the exempt preference id reports silence too', () async {
      final history = await store.entityHistory(
          kind: ConfigKind.preference,
          entityId: 'server_config_envelope',
          scope: ConfigScope.shared);

      expect(history.isSilent, isTrue);
      expect(history.historyKept, isFalse);
    });

    test('a scope is part of the identity, so two stations are two histories',
        () async {
      await _seed(db,
          actionId: 'A', entityId: 'theme', kind: 'preference', scope: 'shared');
      await _seed(db,
          actionId: 'B',
          entityId: 'theme',
          kind: 'preference',
          scope: 'station:ST101');

      final shared = await store.entityHistory(
          kind: ConfigKind.preference,
          entityId: 'theme',
          scope: ConfigScope.shared);

      expect(shared.rows.map((r) => r.change.actionId), ['A']);
    });
  });

  // -------------------------------------------------------------------------
  // The store reads and never writes
  // -------------------------------------------------------------------------

  group('the store is read-only by construction', () {
    // Asserted against the source text, the same pin AuditTrailStore carries:
    // an enumeration of members would report a write rather than stop one, and
    // reading the file is the assertion that actually bites.
    late String source;

    setUpAll(() {
      final file = File('lib/core/config_change_store.dart');
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

    test('contains no into, update or delete', () {
      final offender = RegExp(r'\.(into|update|delete)\(').firstMatch(source);
      expect(offender?.group(0), null,
          reason: 'config_change is append-only because there is nowhere to '
              'write it from. Reading the history must not become a way to '
              'edit it — and this table is exempt from retention, so a bad '
              'row written here is never swept.');
    });

    test('holds no sink and cannot record', () {
      expect(source, isNot(contains('AuditSink')),
          reason: 'reading the history does not appear in the history.');
    });

    test('holds no session and cannot deny', () {
      expect(source, isNot(contains('AccessDenied')));
      expect(source, isNot(contains('AccessSession')),
          reason: 'the enforcement is the route gate, as it is for the audit '
              'trail. A store-level guard mistaken for it would be a second, '
              'weaker boundary.');
    });

    test('the constructor takes only a database and a logger', () {
      expect(
          source,
          contains(
              'ConfigChangeStore({required AppDatabase db, Logger? logger})'),
          reason: 'no session, no sink, no station and no onDenied.');
    });

    test('issues no raw SQL', () {
      expect(source, isNot(contains('customSelect')),
          reason: r'the $1-placeholder form is Postgres-only, so a raw-SQL '
              'method here would be untestable against the in-memory SQLite '
              'handle these tests use.');
      expect(source, isNot(contains('customStatement')));
    });

    test('never intersects a kind filter with the sync set', () {
      expect(source, isNot(contains('kSharedConfigKinds')),
          reason: 'kSharedConfigKinds says what the sync propagates. '
              'ConfigKind.preference is not in it, so a read scoped by it '
              'would return nothing for every preference change ever made.');
    });
  });
}
