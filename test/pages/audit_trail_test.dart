/// The audit trail page: three ways to have nothing to show, and three
/// different screens.
///
/// Phase 2 ruled that **unavailable** and **empty** must be distinguishable. An
/// empty list drawn over an unreachable database claims nothing was ever
/// written on this station, which is the one lie an audit trail cannot tell. A
/// third state — still loading — is neither, and must not be mistaken for
/// either: a frame that renders "No entries match these filters" before the
/// query returns is a page that lies for one frame, and 05-08's goldens would
/// bake that frame in.
///
/// ## Why these tests override the *store* and not the entries family
///
/// The plan asked for `auditTrailEntriesProvider` to be overridden with a
/// recording implementation. Riverpod 2's generated families expose
/// `overrideWith` only on a *resolved* provider — `auditTrailEntriesProvider(q)`
/// — and the generated `AuditTrailEntriesFamily` carries no family-level
/// `overrideWith` at all (`lib/providers/audit_trail.g.dart:125-218`; the
/// `_FamilyMixin.overrideWithProvider` that would supply one is not mixed in).
/// Overriding by resolved query would mean the test had to know the query
/// before the page issued it, which is precisely the thing under test.
///
/// So the seam is one level lower: `auditTrailStoreProvider` is overridden with
/// a `Fake` store that records every [AuditQuery] that reaches it. That is
/// **stronger** than the family override, not weaker — the real
/// `auditTrailEntries` provider runs, so the grouping, the companion count, the
/// `reachedLimit` arithmetic and the `oldestAt` cursor are all the production
/// ones, and the recorded query is the one the page actually caused to be
/// executed rather than merely the one it named.
///
/// `test/providers/audit_trail_test.dart` uses the same `extends Fake implements
/// AuditTrailStore` shape for its `_CountingStore`.
library;

import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/audit_trail_filters.dart';
import 'package:tfc/widgets/audit_trail_row.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_access/tfc_access.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The instant every window assertion is written against, matching
/// `test/providers/audit_trail_test.dart` so the two suites read alike.
final DateTime _now = DateTime.utc(2026, 8, 30, 12);

/// One audit row, with every column defaulted to the ordinary case so a test
/// names only the column it is about.
AuditRecord _row({
  int id = 1,
  DateTime? at,
  String who = 'jon',
  String itemKey = 'ST101.CN04.p_cfg',
  String groupRequired = 'setpoints',
  bool allowed = true,
  String surface = 'tag',
  String? actionId,
}) =>
    AuditRecord(
      at: at ?? _now.subtract(Duration(minutes: id)),
      who: who,
      station: 'ST101',
      roleName: 'engineer',
      surface: surface,
      itemKey: itemKey,
      member: null,
      oldValue: '20',
      newValue: '35',
      groupRequired: groupRequired,
      allowed: allowed,
      origin: 'operator',
      actionId: actionId ?? 'action-$id',
      reason: null,
    );

/// [count] rows, newest first, each its own action — so one row is one tile.
List<AuditRecord> _rows(int count, {int from = 1}) =>
    [for (var i = 0; i < count; i++) _row(id: from + i)];

/// A store that records every query and answers from a callback.
///
/// `extends Fake` rather than a real [AuditTrailStore]: the real one needs an
/// `AppDatabase`, and a widget test that stands up Drift to answer "did the
/// page ask for the whole table" is testing two things and reporting one.
class _FakeStore extends Fake implements AuditTrailStore {
  _FakeStore({
    List<AuditRecord> Function(AuditQuery query)? answer,
    this.whoOptions = const <String>[],
  }) : _answer = answer ?? ((_) => const <AuditRecord>[]);

  final List<AuditRecord> Function(AuditQuery query) _answer;

  /// What `distinctWho` answers — the `who` dropdown's options.
  final List<String> whoOptions;

  /// Every query that reached the database, in order. The whole point of the
  /// fake: the page's promises are about the statement it issues, and the
  /// resolved value cannot distinguish "asked over seven days" from "asked over
  /// the whole table" when the fixture matches both.
  final List<AuditQuery> recorded = <AuditQuery>[];

  /// Set to make the read fail. An error and a resolved null are both
  /// "unavailable" to the page and must be tested as two separate causes.
  Object? error;

  /// Set to make the read never answer, so a test can hold the page in its
  /// loading frame and photograph it.
  bool hang = false;

  @override
  Future<List<AuditRecord>> entries(AuditQuery query) {
    recorded.add(query);
    if (hang) return Completer<List<AuditRecord>>().future;
    final err = error;
    if (err != null) return Future<List<AuditRecord>>.error(err);
    return Future<List<AuditRecord>>.value(_answer(query));
  }

  @override
  Future<Map<String, int>> memberCountsByAction(Iterable<String> actionIds) async {
    // Every action's true row count equals its visible row count here, so no
    // group is partial and no "N of M hidden" line appears. The hidden-member
    // arithmetic belongs to 05-02 and 05-04 and is tested there.
    final ids = actionIds.toList();
    return {for (final id in ids) id: ids.where((other) => other == id).length};
  }

  @override
  Future<List<String>> distinctWho() async => whoOptions;
}


/// A store that answers a **full** first page and a short second one.
///
/// `Load more` only appears when the first result reached the cap, so a paging
/// fixture has to hand back exactly [kAuditTrailRowLimit] rows for the opening
/// query and fewer for the page that follows it — which is also what ends the
/// sequence.
_FakeStore _pagingStore({int second = 4}) => _FakeStore(
      answer: (query) => query.before == null
          ? _rows(kAuditTrailRowLimit)
          : _rows(second, from: kAuditTrailRowLimit + 1),
    );

/// How many action tiles the list has actually built.
///
/// The list is virtualised, so this is *not* the number of actions the page
/// holds. It is the right number to compare against itself across a rebuild —
/// which is what the double-append guard needs — and the wrong one to compare
/// against a page size.
int _builtTiles(WidgetTester tester) => tester
    .widgetList<AuditActionTile>(
      find.byType(AuditActionTile, skipOffstage: false),
    )
    .length;

/// Where the list is scrolled to.
///
/// Read off the `Scrollable`'s own position rather than off a
/// `ScrollController`: this page deliberately owns no controller — a controller
/// is the thing a pre-fetching scroll listener would need, and the
/// comment-stripped grep forbids one.
double _listOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(kAuditTrailListKey),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

/// A host whose `setState` rebuilds [AuditTrailBody] without replacing its
/// `State`.
///
/// A bare `tester.pump()` does not rebuild a widget whose own state has not
/// changed, so a stability test written that way passes identically under the
/// correct and the defective design. This host makes the rebuild happen for
/// real.
class _RebuildHost extends StatefulWidget {
  const _RebuildHost();

  @override
  State<_RebuildHost> createState() => _RebuildHostState();
}

class _RebuildHostState extends State<_RebuildHost> {
  /// Forces one more `AuditTrailBody.build`.
  void bump() => setState(() {});

  @override
  Widget build(BuildContext context) {
    // Deliberately not `const`, and deliberately unkeyed. Flutter short-circuits
    // a child's rebuild when the new widget is `identical` to the old one, so a
    // const instance would make this host inert; a *changing* key would go the
    // other way and replace the `State` outright, which would legitimately
    // issue a second query and hide the defect behind a false positive.
    // ignore: prefer_const_constructors
    return AuditTrailBody();
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Pumps [AuditTrailBody] over [store].
///
/// **No `withClock` anywhere in this file, and that is not an oversight.**
/// `testWidgets` runs its body inside `package:fake_async`, which installs its
/// own `package:clock` — so the clock is already frozen for the whole test and
/// advances only when a pump is given a duration. Freezing it a second time
/// around the first pump only would be actively harmful: `initState` would
/// resolve its query against the pinned instant while a later refresh resolved
/// its own against fake_async's, and the page would look as though it had
/// issued a query it never issued.
///
/// `muted()` rather than a bare `MaterialApp`, for the reason
/// `audit_trail_row_test.dart` states: `HmiStateColors.of` falls back to
/// `solarizedLight` under a theme carrying no extension, so anything drawn from
/// the theme extension under a bare app is drawn from a palette this build does
/// not ship.
Future<void> _pumpBody(
  WidgetTester tester, {
  required AuditTrailStore? store,
  Widget child = const AuditTrailBody(),
}) async {
  final (light, _) = muted();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        auditTrailStoreProvider.overrideWith((ref) async => store),
      ],
      child: MaterialApp(
        theme: light,
        home: Scaffold(body: child),
      ),
    ),
  );
  // Two more frames for the store future and the entries future to resolve.
  await tester.pump();
  await tester.pump();
}

/// How many `Clear filters` controls are on screen.
///
/// 05-05's bar renders one only while the filters are not default; this page's
/// empty body renders one only while they are. Exactly one, in every state,
/// never zero and never two.
int _clearFiltersCount(WidgetTester tester) =>
    tester.widgetList<Text>(find.text(kAuditTrailClearFiltersLabel)).length;

/// The page source with every whole-line comment stripped, for the greps that
/// stand behind the rules no type system can hold.
String _pageSourceWithoutComments() {
  final source = File('lib/pages/audit_trail.dart').readAsStringSync();
  return source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  // -------------------------------------------------------------------------
  // Task 1 — the Page/Body split and the three terminal states
  // -------------------------------------------------------------------------

  group('AuditTrailPage', () {
    test('is const-constructible, so the route map can register it', () {
      // Field-less on purpose: `createLocationBuilder` registers it as
      // `const AuditTrailPage()`. This is a compile-time assertion wearing a
      // test's clothes — if the page ever grows a required field, this line
      // stops compiling, which is the whole point.
      const page = AuditTrailPage();
      expect(page, isA<StatelessWidget>());
    });

    test('wraps AuditTrailBody in BaseScaffold and nothing else', () {
      final source = _pageSourceWithoutComments();
      expect(source, contains('BaseScaffold('));
      expect(source, contains('AuditTrailBody()'));
    });
  });

  group('AuditTrailBody — unavailable', () {
    testWidgets('a resolved null store renders the unavailable key and '
        'neither of the other two', (tester) async {
      await _pumpBody(tester, store: null);

      expect(find.byKey(kAuditTrailUnavailableKey), findsOneWidget);
      expect(
        find.byKey(kAuditTrailEmptyKey),
        findsNothing,
        reason: 'an unreachable database must never read as "nothing ever '
            'happened on this station"',
      );
      expect(find.byKey(kAuditTrailListKey), findsNothing);
    });

    testWidgets('a read that throws renders unavailable too, not empty',
        (tester) async {
      final store = _FakeStore()..error = StateError('the audit database blinked');
      await _pumpBody(tester, store: store);

      expect(find.byKey(kAuditTrailUnavailableKey), findsOneWidget);
      expect(
        find.byKey(kAuditTrailEmptyKey),
        findsNothing,
        reason: 'a failed read is not entitled to make a claim about the '
            'plant\'s history',
      );
      expect(find.byKey(kAuditTrailListKey), findsNothing);
    });

    testWidgets('states the unavailable copy', (tester) async {
      await _pumpBody(tester, store: null);
      expect(find.text(kAuditTrailUnavailable), findsOneWidget);
    });

    testWidgets('does not state the empty copy', (tester) async {
      await _pumpBody(tester, store: null);
      expect(find.text(kAuditTrailEmptyUnderFilters), findsNothing);
    });

    testWidgets('names no cause: neither "not configured" nor "connection"',
        (tester) async {
      await _pumpBody(tester, store: null);
      // `databaseProvider` answers null both for a station that was never
      // configured and for one whose Postgres will not answer, and the two are
      // indistinguishable by design. A line that guessed would send a
      // commissioning engineer hunting the wrong problem.
      expect(kAuditTrailUnavailable.toLowerCase(), isNot(contains('not configured')));
      expect(kAuditTrailUnavailable.toLowerCase(), isNot(contains('timed out')));
    });

    testWidgets('renders no filter bar — there is nothing to filter',
        (tester) async {
      await _pumpBody(tester, store: null);
      expect(find.byType(AuditTrailFilterBar), findsNothing);
    });
  });

  group('AuditTrailBody — empty under filters', () {
    testWidgets('a resolved empty result renders the empty key and neither of '
        'the other two', (tester) async {
      await _pumpBody(tester, store: _FakeStore());

      expect(find.byKey(kAuditTrailEmptyKey), findsOneWidget);
      expect(find.byKey(kAuditTrailUnavailableKey), findsNothing);
      expect(find.byKey(kAuditTrailListKey), findsNothing);
    });

    testWidgets('states the empty copy and not the unavailable one',
        (tester) async {
      await _pumpBody(tester, store: _FakeStore());
      expect(find.text(kAuditTrailEmptyUnderFilters), findsOneWidget);
      expect(find.text(kAuditTrailUnavailable), findsNothing);
    });

    testWidgets('is about the filters and never about the table', (tester) async {
      // CONTEXT's deferred list records a fourth state that would distinguish a
      // genuinely empty table. This phase does not ship it, so the wording must
      // claim nothing about what the table holds.
      expect(kAuditTrailEmptyUnderFilters.toLowerCase(), contains('filters'));
      expect(kAuditTrailEmptyUnderFilters.toLowerCase(), isNot(contains('nothing')));
      expect(kAuditTrailEmptyUnderFilters.toLowerCase(), isNot(contains('never')));
    });

    testWidgets('keeps the filter bar on screen, so the operator can see what '
        'excluded everything', (tester) async {
      await _pumpBody(tester, store: _FakeStore());
      expect(find.byType(AuditTrailFilterBar), findsOneWidget);
    });

    testWidgets('renders exactly one Clear filters under default filters',
        (tester) async {
      await _pumpBody(tester, store: _FakeStore());
      expect(
        _clearFiltersCount(tester),
        1,
        reason: '05-05\'s bar renders one only when the filters are not '
            'default; this body owns the default case, and never zero',
      );
    });

    testWidgets('renders exactly one Clear filters under a set key prefix',
        (tester) async {
      await _pumpBody(tester, store: _FakeStore());
      await tester.enterText(find.byType(TextField), 'CN04');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        _clearFiltersCount(tester),
        1,
        reason: 'the bar owns this case, so the body must stand down — never '
            'two',
      );
    });
  });

  group('AuditTrailBody — loading', () {
    testWidgets('renders none of the three keys while the query is still out',
        (tester) async {
      final store = _FakeStore()..hang = true;
      await _pumpBody(tester, store: store);

      expect(
        find.byKey(kAuditTrailUnavailableKey),
        findsNothing,
        reason: 'waiting is neither allowed nor denied and says nothing yet',
      );
      expect(
        find.byKey(kAuditTrailEmptyKey),
        findsNothing,
        reason: 'a frame that renders "No entries match" before the query '
            'returns is a page that lies for one frame, and a golden that '
            'catches that frame bakes the lie in',
      );
      expect(find.byKey(kAuditTrailListKey), findsNothing);
    });

    testWidgets('renders a progress indicator instead', (tester) async {
      final store = _FakeStore()..hang = true;
      await _pumpBody(tester, store: store);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('AuditTrailBody — a result', () {
    testWidgets('renders the list key and neither terminal state',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);

      expect(find.byKey(kAuditTrailListKey), findsOneWidget);
      expect(find.byKey(kAuditTrailEmptyKey), findsNothing);
      expect(find.byKey(kAuditTrailUnavailableKey), findsNothing);
    });

    testWidgets('renders one AuditActionTile per action', (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);
      expect(find.byType(AuditActionTile), findsNWidgets(3));
    });
  });

  group('AuditTrailBody — what this page is not', () {
    test('checks no permission and builds no denied state', () {
      // T-05-60. The route gate renders `AccessLockedBody` before this page is
      // reached; a second, weaker check here could diverge from the first, and
      // the divergence would be an open page.
      final source = _pageSourceWithoutComments();
      expect(source, isNot(contains('AccessGroup')));
      expect(source, isNot(contains('AccessLockedBody')));
    });

    test('reaches for no raw Material colour', () {
      // `lib/pages/key_repository.dart` predates the convention and is a known
      // violation; it is the wrong model for colour and the right model for the
      // three-way branch.
      final source = _pageSourceWithoutComments();
      expect(source, isNot(contains('Colors.')));
    });
  });

  // -------------------------------------------------------------------------
  // Task 2 — the list, the filter wiring, and the search that escapes the
  // window
  // -------------------------------------------------------------------------

  group('AuditTrailBody — the opening query', () {
    testWidgets('spans exactly seven days back from now and asks for 500 rows',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      // The instant `initState` will resolve the query against: fake_async
      // holds the clock still until a pump is given a duration, and no pump in
      // `_pumpBody` is.
      final openedAt = clock.now();
      await _pumpBody(tester, store: store);

      expect(store.recorded, hasLength(1));
      final window = store.recorded.single.window;
      expect(window, isNotNull);
      expect(
        window!.end.difference(window.start),
        const Duration(days: 7),
        reason: 'the default is the last seven days, capped at 500 rows — '
            'whichever bound is reached first',
      );
      expect(window.end, openedAt);
      expect(store.recorded.single.limit, kAuditTrailRowLimit);
    });

    testWidgets('is issued on arrival, without waiting for a filter change',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(1));
      await _pumpBody(tester, store: store);
      expect(store.recorded, isNotEmpty);
    });

    testWidgets('excludes operate and says so on screen', (tester) async {
      final store = _FakeStore(answer: (_) => _rows(1));
      await _pumpBody(tester, store: store);

      expect(store.recorded.single.groupNames, isNot(contains('operate')));
      expect(find.text(kAuditTrailOperateNote), findsOneWidget);
    });
  });

  group('AuditTrailBody — the search that reaches the whole table', () {
    testWidgets('a typed key prefix drops the time bound entirely',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(2));
      await _pumpBody(tester, store: store);

      await tester.enterText(find.byType(TextField), 'CN04');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      final issued = store.recorded.last;
      expect(issued.keyPrefix, 'CN04');
      expect(
        issued.window,
        isNull,
        reason: 'searching must answer "has anyone ever written this key", '
            'not "did anyone this week" — a search that silently covered only '
            'the default window would be a wrong answer that looks like a '
            'right one',
      );
      expect(
        issued.limit,
        kAuditTrailRowLimit,
        reason: 'the search escapes the time bound and never the row cap',
      );
    });

    testWidgets('a chosen who drops the time bound too', (tester) async {
      final store = _FakeStore(answer: (_) => _rows(2), whoOptions: ['jon']);
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailWhoDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('jon').last);
      await tester.pumpAndSettle();

      final issued = store.recorded.last;
      expect(issued.who, 'jon');
      expect(issued.window, isNull);
      expect(issued.limit, kAuditTrailRowLimit);
    });
  });

  group('AuditTrailBody — query stability', () {
    testWidgets('two rebuilds that change no filter issue one query, not three',
        (tester) async {
      // T-05-67, which is T-05-21 at the page layer. `clock.now()` called
      // inside `build` moves `window.end` forward on every frame, so
      // `AuditQuery ==` goes false, the autoDispose family swaps instances and
      // the page hits the database on every frame it paints.
      //
      // **The clock has to be made to move, and simply omitting `withClock` is
      // not enough.** `testWidgets` runs its body inside `package:fake_async`,
      // and `FakeAsync` installs its own `clock` — so inside a widget test the
      // "live" clock is frozen exactly as hard as a `Clock.fixed` one, and it
      // advances only when a pump is given a duration. A version of this test
      // that bumped and then called a bare `tester.pump()` passes with
      // `clock.now()` sitting in the middle of `build`, which was verified by
      // putting it there. Every rebuild below therefore elapses real fake-time,
      // which is what gives the defective design a distinct `now` to be caught
      // with.
      final store = _FakeStore(answer: (_) => _rows(2));
      await _pumpBody(
        tester,
        store: store,
        child: const _RebuildHost(),
      );

      final host = tester.state<_RebuildHostState>(find.byType(_RebuildHost));
      host.bump();
      await tester.pump(const Duration(seconds: 1));
      host.bump();
      await tester.pump(const Duration(seconds: 1));

      final body =
          tester.state<AuditTrailBodyState>(find.byType(AuditTrailBody));
      expect(
        body.buildCount,
        greaterThanOrEqualTo(3),
        reason: 'a stability test that failed to trigger any rebuild would '
            'pass vacuously',
      );
      expect(
        store.recorded,
        hasLength(1),
        reason: 'the resolved AuditQuery lives in State; a rebuild that '
            'changes no filter must watch the identical value and cost no '
            'round trip (T-05-67)',
      );
    });

    testWidgets('the window it opened with does not drift as time passes',
        (tester) async {
      // The sibling of the test above, stated as the operator sees it: the
      // seven days on screen are the seven days the page opened with, and they
      // do not slide out from under a row while it is being read.
      final store = _FakeStore(answer: (_) => _rows(2));
      await _pumpBody(
        tester,
        store: store,
        child: const _RebuildHost(),
      );
      final opened = store.recorded.single.window!.end;

      final host = tester.state<_RebuildHostState>(find.byType(_RebuildHost));
      host.bump();
      await tester.pump(const Duration(minutes: 5));

      expect(store.recorded.single.window!.end, opened);
    });
  });

  group('AuditTrailBody — the list', () {
    testWidgets('virtualises: a 500-action result builds far fewer tiles',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(kAuditTrailRowLimit));
      await _pumpBody(tester, store: store);

      final built = tester
          .widgetList<AuditActionTile>(
            find.byType(AuditActionTile, skipOffstage: false),
          )
          .length;
      expect(
        built,
        lessThan(50),
        reason: 'building 500 expandable tiles in one frame is T-05-64',
      );
      expect(built, greaterThan(0));
    });

    testWidgets('uses no itemExtent — the tiles expand', (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);

      final list = tester.widget<ListView>(find.byKey(kAuditTrailListKey));
      expect(list.itemExtent, isNull);
      expect(list.prototypeItem, isNull);
    });
  });

  group('AuditTrailBody — the result line', () {
    testWidgets('states the row count and the window it counted over',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);

      expect(
        find.text(auditTrailResultSummary(
          count: 3,
          filters: const AuditTrailFilters(),
        )),
        findsOneWidget,
        reason: 'a count without the window that produced it is a number '
            'somebody will quote',
      );
    });

    testWidgets('says All time once the query escaped the seven-day bound',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(2));
      await _pumpBody(tester, store: store);

      await tester.enterText(find.byType(TextField), 'CN04');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.textContaining(kAuditTrailWholeTableLabel), findsOneWidget);
    });
  });

  group('AuditTrailBody — the row cap', () {
    testWidgets('says it is showing the newest 500 when the cap was reached',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(kAuditTrailRowLimit));
      await _pumpBody(tester, store: store);
      expect(find.byKey(kAuditTrailLimitNoteKey), findsOneWidget);
      expect(find.text(kAuditTrailLimitNote), findsOneWidget);
    });

    testWidgets('says nothing of the sort on a short result', (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);
      expect(find.byKey(kAuditTrailLimitNoteKey), findsNothing);
    });
  });

  group('AuditTrailBody — nothing is filtered in memory', () {
    test('the page holds no client-side filter or sort', () {
      // Every filter is pushed into SQL and applied in `WHERE` before `LIMIT`.
      // Filtering the already-loaded rows would show three denials while the
      // table held three hundred.
      final source = _pageSourceWithoutComments();
      expect(source, isNot(contains('.where(')));
      expect(source, isNot(contains('.sort(')));
    });
  });

  // -------------------------------------------------------------------------
  // Task 3 — Load more and Refresh
  // -------------------------------------------------------------------------

  group('AuditTrailBody — Load more', () {
    testWidgets('is absent when the result did not reach the cap',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);
      expect(
        find.byKey(kAuditTrailLoadMoreKey),
        findsNothing,
        reason: 'a short result has nothing more to load',
      );
    });

    testWidgets('is present when the result reached the cap', (tester) async {
      await _pumpBody(tester, store: _pagingStore());
      expect(find.byKey(kAuditTrailLoadMoreKey), findsOneWidget);
    });

    testWidgets('asks for rows strictly older than the oldest one on screen',
        (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      final firstPageOldest = _rows(kAuditTrailRowLimit).last.at;
      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      expect(store.recorded, hasLength(2));
      expect(
        store.recorded.last.before,
        firstPageOldest,
        reason: 'the cursor is the oldest row the first page returned',
      );
    });

    testWidgets('keeps the window the first page was answered over',
        (tester) async {
      // Re-reading the clock here would move the window's *start* forward by
      // however long the page had been open, and the rows between the old
      // start and the new one are exactly the oldest ones — the ones Load more
      // was tapped to see.
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      expect(store.recorded.last.window, store.recorded.first.window);
    });

    testWidgets('changes neither the filters nor the search field',
        (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      expect(store.recorded.last.keyPrefix, store.recorded.first.keyPrefix);
      expect(store.recorded.last.who, store.recorded.first.who);
      expect(store.recorded.last.groupNames, store.recorded.first.groupNames);
      expect(store.recorded.last.outcome, store.recorded.first.outcome);
    });

    testWidgets('appends the older page beneath what is already on screen',
        (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      final summaryBefore = auditTrailResultSummary(
        count: kAuditTrailRowLimit,
        filters: const AuditTrailFilters(),
      );
      expect(find.text(summaryBefore), findsOneWidget);

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      expect(
        find.text(auditTrailResultSummary(
          count: kAuditTrailRowLimit + 4,
          filters: const AuditTrailFilters(),
        )),
        findsOneWidget,
        reason: 'the second page is added to the first, not shown instead of '
            'it — build watches a list of queries and concatenates their '
            'actions in order',
      );
    });

    testWidgets('does not scroll the list back to the top', (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      await tester.drag(find.byKey(kAuditTrailListKey), const Offset(0, -400));
      await tester.pump();
      final offsetBefore = _listOffset(tester);
      expect(
        offsetBefore,
        greaterThan(0),
        reason: 'a test that never left the top could not tell a preserved '
            'position from a reset one',
      );

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      expect(
        _listOffset(tester),
        offsetBefore,
        reason: 'the older page arrives beneath what is on screen; the list '
            'does not reset to the top and the earlier rows do not move',
      );
    });

    testWidgets('the column header stays put while the rows scroll under it',
        (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      expect(find.byKey(kAuditTrailHeaderKey), findsOneWidget);
      final headerBefore = tester.getTopLeft(find.byKey(kAuditTrailHeaderKey));

      await tester.drag(find.byKey(kAuditTrailListKey), const Offset(0, -400));
      await tester.pump();
      expect(
        _listOffset(tester),
        greaterThan(0),
        reason: 'a test that never scrolled could not tell a sticky header '
            'from one that simply had not moved yet',
      );

      expect(
        tester.getTopLeft(find.byKey(kAuditTrailHeaderKey)),
        headerBefore,
        reason: 'the header is a sibling of the list, not its first row, so '
            'scrolling the rows cannot carry it off the top',
      );
      expect(
        find.descendant(
          of: find.byKey(kAuditTrailListKey),
          matching: find.byKey(kAuditTrailHeaderKey),
        ),
        findsNothing,
        reason: 'inside the ListView it would scroll away — which is the one '
            'thing a column header must not do',
      );
    });

    testWidgets('a short second page ends the sequence', (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(kAuditTrailLoadMoreKey),
        findsNothing,
        reason: 'the page that came back short is the last one there is',
      );
    });

    testWidgets('a second Load more appends a third query', (tester) async {
      // Every page full, so the sequence never ends on its own — and every
      // page strictly older than the last, or the third query would carry the
      // same cursor as the second, compare equal to it, and be answered from
      // the family's cache rather than from the database.
      var page = 0;
      final store = _FakeStore(answer: (query) {
        page++;
        final anchor = query.before ?? _now;
        return [
          for (var i = 0; i < kAuditTrailRowLimit; i++)
            _row(
              id: page * kAuditTrailRowLimit + i,
              at: anchor.subtract(Duration(minutes: i + 1)),
            ),
        ];
      });
      await _pumpBody(tester, store: store);

      for (var tap = 0; tap < 2; tap++) {
        await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
        await tester.pump();
        await tester.pump();
      }

      expect(store.recorded, hasLength(3));
      expect(store.recorded[1].before, isNotNull);
      expect(store.recorded[2].before, isNotNull);
    });

    testWidgets('rebuilds after a Load more do not double the rows',
        (tester) async {
      // T-05-68. The accumulation is a list of *queries* held in State, not a
      // row buffer appended to from inside `build` — rows appended during
      // `build` would be appended again on every frame.
      final store = _pagingStore();
      await _pumpBody(
        tester,
        store: store,
        child: const _RebuildHost(),
      );

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();
      final builtAfterLoadMore = _builtTiles(tester);

      final host = tester.state<_RebuildHostState>(find.byType(_RebuildHost));
      host.bump();
      await tester.pump(const Duration(seconds: 1));
      host.bump();
      await tester.pump(const Duration(seconds: 1));

      expect(_builtTiles(tester), builtAfterLoadMore);
      expect(
        find.text(auditTrailResultSummary(
          count: kAuditTrailRowLimit + 4,
          filters: const AuditTrailFilters(),
        )),
        findsOneWidget,
        reason: 'two more rebuilds must not add the second page again',
      );
    });

    testWidgets('changing a filter afterwards resets the accumulation',
        (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'CN04');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump();

      final searched = const AuditTrailFilters(keyPrefix: 'CN04');
      expect(
        find.text(auditTrailResultSummary(
          count: kAuditTrailRowLimit,
          filters: searched,
        )),
        findsOneWidget,
        reason: 'a filter change that kept the old pages would show rows the '
            'new filter excludes',
      );
      expect(store.recorded.last.before, isNull);
    });
  });

  group('AuditTrailBody — Refresh', () {
    testWidgets('re-asks the database rather than answering from cache',
        (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);
      expect(store.recorded, hasLength(1));

      await tester.tap(find.byKey(kAuditTrailRefreshKey));
      await tester.pump();
      await tester.pump();

      expect(
        store.recorded,
        hasLength(2),
        reason: 'under a clock that has not moved the freshly resolved query '
            'equals the old one, so the invalidate is what makes the round '
            'trip happen',
      );
    });

    testWidgets('resets the accumulation to a single page', (tester) async {
      final store = _pagingStore();
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailLoadMoreKey));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(kAuditTrailRefreshKey));
      await tester.pump();
      await tester.pump();

      expect(
        find.text(auditTrailResultSummary(
          count: kAuditTrailRowLimit,
          filters: const AuditTrailFilters(),
        )),
        findsOneWidget,
        reason: 'a refresh that kept the old pages would show stale rows above '
            'fresh ones with no boundary between them',
      );
      expect(store.recorded.last.before, isNull);
    });

    testWidgets('changes no filter', (tester) async {
      final store = _FakeStore(answer: (_) => _rows(3));
      await _pumpBody(tester, store: store);

      await tester.tap(find.byKey(kAuditTrailRefreshKey));
      await tester.pump();
      await tester.pump();

      expect(store.recorded.last.keyPrefix, store.recorded.first.keyPrefix);
      expect(store.recorded.last.groupNames, store.recorded.first.groupNames);
    });
  });

  group('AuditTrailBody — nothing moves on its own', () {
    test('the page starts no timer, holds no scroll listener and subscribes '
        'to nothing', () {
      // T-05-66. CONTEXT's ruling: the page refreshes on open and on an
      // explicit control, and a self-scrolling audit list is unreadable. A
      // scroll-position listener that pre-fetched would be infinite scroll
      // wearing a button's clothes.
      final source = _pageSourceWithoutComments();
      expect(source, isNot(contains('Timer')));
      expect(source, isNot(contains('ScrollController')));
      expect(source, isNot(contains('.listen(')));
      expect(source, isNot(contains('addPostFrameCallback')));
    });
  });
}
