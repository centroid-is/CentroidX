// The history view's write guard — spec §6's fourth bypass, closed at the
// controls rather than at the route.
//
// Two of the five writes are destructive and ask for `configure`; the other
// three are things an operator doing their job does and stay open. All five
// leave a row, so the choice above is reviewable from the trail rather than
// only from a comment.
//
// The route is deliberately *not* raised — `/advanced/history-view` is a read
// surface and spec §11 defers read permissions. That is asserted here too, so
// "the page stays readable" is a checked property of this plan rather than a
// thing that happened to be true when it was written.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/guarded_history_views.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// One call the store made, or did not make, on the database.
typedef _DbCall = ({String method, List<Object?> args});

/// Records the five history-view writes and performs none of them.
///
/// `extends Fake` rather than a real in-memory `AppDatabase`: the assertion
/// that matters on the deny path is that the Drift method was **never
/// reached**, and a fake that answers `noSuchMethod` by throwing makes any
/// other member this store touches fail loudly instead of silently working.
class _RecordingDb extends Fake implements AppDatabase {
  final List<_DbCall> calls = [];

  /// The id `createHistoryView` and `addHistoryViewPeriod` hand back, so the
  /// return-value passthrough can be asserted.
  int nextId = 7;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]) async {
    calls.add((
      method: 'createHistoryView',
      args: [name, keys, keyConfigs, graphConfigs]
    ));
    return nextId;
  }

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]) async {
    calls.add((
      method: 'updateHistoryView',
      args: [id, name, keys, keyConfigs, graphConfigs]
    ));
  }

  @override
  Future<void> deleteHistoryView(int id) async {
    calls.add((method: 'deleteHistoryView', args: [id]));
  }

  @override
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end) async {
    calls.add((
      method: 'addHistoryViewPeriod',
      args: [viewId, name, start, end]
    ));
    return nextId;
  }

  @override
  Future<void> deleteHistoryViewPeriod(int id) async {
    calls.add((method: 'deleteHistoryViewPeriod', args: [id]));
  }
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A sink that fails the way an unreachable database does — and one whose
/// failure must reach no caller.
class _ThrowingSink implements AuditSink {
  int calls = 0;

  @override
  Future<void> record(AuditRecord entry) async {
    calls++;
    throw StateError('audit sink down');
  }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Nobody signed in, holding the seeded Operator groups. This is the session
/// on a panel on the floor.
final AccessSession _anonymous = AccessSession.anonymous(
  {...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups},
);

AccessSession _signedIn(Set<AccessGroup> groups, {String username = 'jon'}) =>
    AccessSession(
      user: AuthenticatedUser(username: username, roleName: 'Engineer'),
      groups: groups,
    );

// ---------------------------------------------------------------------------

void main() {
  late _RecordingDb db;
  late _RecordingSink audit;
  late List<AccessDenied> denials;
  late AccessSession session;

  HistoryViewStore storeWith({AuditSink? sink}) => HistoryViewStore(
        db: db,
        session: () => session,
        audit: sink ?? audit,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  setUp(() {
    db = _RecordingDb();
    audit = _RecordingSink();
    denials = [];
    session = _anonymous;
  });

  group('the two deletes require configure', () {
    test('an anonymous session is refused deleteHistoryView', () async {
      final store = storeWith();

      await expectLater(
        store.deleteHistoryView(3),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'history_view.3')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );

      expect(db.calls, isEmpty,
          reason: 'the Drift delete must never be reached on a refusal');
      expect(audit.rows, hasLength(1));
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.groupRequired, 'configure');
      expect(denials, hasLength(1));
    });

    test('an anonymous session is refused deleteHistoryViewPeriod', () async {
      final store = storeWith();

      await expectLater(
        store.deleteHistoryViewPeriod(11),
        throwsA(isA<AccessDenied>().having(
            (d) => d.itemKey, 'itemKey', 'history_view_period.11')),
      );

      expect(db.calls, isEmpty,
          reason: 'the Drift delete must never be reached on a refusal');
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.groupRequired, 'configure');
      expect(denials.single.required, AccessGroup.configure);
    });

    test('a session holding configure deletes a view, and one row says so',
        () async {
      session = _signedIn({AccessGroup.operate, AccessGroup.configure});
      final store = storeWith();

      await store.deleteHistoryView(3);

      expect(db.calls.single.method, 'deleteHistoryView');
      expect(db.calls.single.args, [3]);
      expect(audit.rows, hasLength(1));
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.who, 'jon');
      expect(audit.rows.single.groupRequired, 'configure');
      expect(denials, isEmpty);
    });

    test('a session holding configure deletes a period, and one row says so',
        () async {
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.deleteHistoryViewPeriod(11);

      expect(db.calls.single.method, 'deleteHistoryViewPeriod');
      expect(db.calls.single.args, [11]);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'history_view_period.11');
    });

    test('administer alone does not carry configure — the group is exact',
        () async {
      session = _signedIn({AccessGroup.administer});
      final store = storeWith();

      await expectLater(
          store.deleteHistoryView(3), throwsA(isA<AccessDenied>()));
      expect(db.calls, isEmpty);
    });
  });

  group('creating, renaming and saving a period stays open', () {
    test('createHistoryView stays open to an anonymous session, and is '
        'still recorded', () async {
      final store = storeWith();

      final id = await store.createHistoryView(
          'Line 2 overnight', ['a', 'b'], {'a': {}}, {'0': {}});

      expect(id, 7, reason: 'the new row id is handed straight back');
      expect(db.calls.single.method, 'createHistoryView');
      expect(db.calls.single.args.first, 'Line 2 overnight');
      expect(audit.rows, hasLength(1));
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.who, 'anonymous');
      expect(audit.rows.single.groupRequired, '',
          reason: 'open by design carries an empty groupRequired');
      expect(denials, isEmpty);
    });

    test('updateHistoryView stays open to an anonymous session, and is '
        'still recorded', () async {
      final store = storeWith();

      await store.updateHistoryView(4, 'Renamed', ['a']);

      expect(db.calls.single.method, 'updateHistoryView');
      expect(db.calls.single.args.first, 4);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.itemKey, 'history_view.4');
      expect(audit.rows.single.groupRequired, '');
    });

    test('addHistoryViewPeriod stays open to an anonymous session, and is '
        'still recorded', () async {
      final store = storeWith();
      final start = DateTime.utc(2026, 8, 30, 6);
      final end = DateTime.utc(2026, 8, 30, 14);

      final id = await store.addHistoryViewPeriod(4, 'Morning', start, end);

      expect(id, 7);
      expect(db.calls.single.method, 'addHistoryViewPeriod');
      expect(db.calls.single.args, [4, 'Morning', start, end]);
      expect(audit.rows.single.allowed, isTrue);
      expect(audit.rows.single.groupRequired, '');
      expect(denials, isEmpty);
    });
  });

  group('the rows', () {
    test('every row carries the history_view surface by its wire name',
        () async {
      // Plan 17-01. These rows carried `pref` until the policy grew a real
      // history-view surface — a saved view is not a preference key, and the
      // only reason it borrowed that name was that the vocabulary had three
      // write surfaces and none of them fitted.
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.createHistoryView('a', const []);
      await store.updateHistoryView(4, 'a', const []);
      await store.deleteHistoryView(4);
      await store
          .addHistoryViewPeriod(4, 'p', DateTime.utc(2026), DateTime.utc(2027));
      await store.deleteHistoryViewPeriod(9);

      expect(audit.rows, hasLength(5));
      expect(audit.rows.map((r) => r.surface).toSet(),
          {AccessSurface.historyView.wireName});
      // The literal, not only the enum reference: this is stored data, and an
      // arm written only against `AccessSurface.historyView.wireName` would
      // follow a rename of the wire name and never notice that a year of rows
      // now means something else.
      expect(audit.rows.map((r) => r.surface).toSet(), {'history_view'});
      expect(audit.rows.map((r) => r.surface), isNot(contains('pref')),
          reason: 'the discontinuity is deliberate and documented at the call '
              'site; rows written before the deploy still read pref');
    });

    test('item keys are prefixed so the trail viewer can group them', () async {
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.createHistoryView('a', const []);
      await store.updateHistoryView(4, 'a', const []);
      await store.deleteHistoryView(4);
      await store
          .addHistoryViewPeriod(4, 'p', DateTime.utc(2026), DateTime.utc(2027));
      await store.deleteHistoryViewPeriod(9);

      expect(audit.rows.map((r) => r.itemKey).toList(), [
        'history_view.new',
        'history_view.4',
        'history_view.4',
        'history_view_period.new',
        'history_view_period.9',
      ]);
    });

    test('each row names which of the five writes it was', () async {
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.deleteHistoryView(4);

      expect(audit.rows.single.reason, 'deleteHistoryView');
    });

    test('one action id per call, and two calls never share one', () async {
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.deleteHistoryView(4);
      await store.deleteHistoryView(5);

      expect(audit.rows, hasLength(2));
      expect(audit.rows[0].actionId, isNotEmpty);
      expect(audit.rows[0].actionId, isNot(audit.rows[1].actionId));
    });

    test('the station and the role in force are on the row', () async {
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.deleteHistoryView(4);

      expect(audit.rows.single.station, 'SVN-NES-OT-CL02');
      expect(audit.rows.single.roleName, 'Engineer');
    });

    test('the session is read at write time, not captured at construction',
        () async {
      final store = storeWith();
      session = _signedIn({AccessGroup.configure});

      await store.deleteHistoryView(4);

      expect(db.calls, hasLength(1),
          reason: 'a session elevated after the store was built must count');
    });
  });

  group('a failing audit sink', () {
    test('does not prevent a permitted write', () async {
      session = _signedIn({AccessGroup.configure});
      final sink = _ThrowingSink();
      final store = storeWith(sink: sink);

      await store.deleteHistoryView(4);

      expect(sink.calls, 1);
      expect(db.calls.single.method, 'deleteHistoryView');
    });

    test('does not replace AccessDenied on the deny path', () async {
      final sink = _ThrowingSink();
      final store = storeWith(sink: sink);

      await expectLater(
          store.deleteHistoryView(4), throwsA(isA<AccessDenied>()));

      expect(sink.calls, 1);
      expect(denials, hasLength(1),
          reason: 'the denial callback must still fire');
      expect(db.calls, isEmpty);
    });

    test('a throwing onDenied listener does not replace AccessDenied',
        () async {
      final store = HistoryViewStore(
        db: db,
        session: () => session,
        audit: audit,
        station: 'SVN-NES-OT-CL02',
        onDenied: (_) => throw StateError('prompt is broken'),
      );

      await expectLater(
          store.deleteHistoryView(4), throwsA(isA<AccessDenied>()));
      expect(audit.rows.single.allowed, isFalse);
    });
  });

  group('the group choice is one answer, and it lives in tfc_access', () {
    test('the delete group is configure and the write group is open', () {
      // Unchanged in behaviour by plan 17-01, and that is the point: the
      // constants moved, the grading did not.
      expect(kHistoryViewDeleteGroup, AccessGroup.configure);
      expect(kHistoryViewWriteGroup, isNull,
          reason: 'null means open to any session; changing '
              'AccessPolicy.groupForHistoryView gates all five');
    });

    test('both names carry a doc comment saying what changing them does', () {
      final lines =
          File('lib/core/guarded_history_views.dart').readAsLinesSync();
      for (final name in ['kHistoryViewDeleteGroup', 'kHistoryViewWriteGroup']) {
        final at = lines.indexWhere((l) => l.contains('get $name =>'));
        expect(at, greaterThan(0),
            reason: '$name is a getter over the policy, not a declaration');

        final doc = <String>[];
        for (var i = at - 1; i >= 0 && lines[i].trimLeft().startsWith('///');
            i--) {
          doc.insert(0, lines[i]);
        }
        expect(doc, isNotEmpty, reason: '$name has a doc comment');
        expect(doc.join('\n').toLowerCase(), contains('chang'),
            reason: "$name's doc comment says what changing it does");
      }
    });

    test('the store consults AccessPolicy and declares no group of its own',
        () {
      // This arm asserted the exact opposite until plan 17-01, on the argument
      // that a second source for one answer would drift. The argument was
      // right and the conclusion was backwards: because the answer lived here,
      // packages/tfc_relay_server could not read it, invented
      // `role == operate`, and got a different answer in both directions
      // (sweep §3.12). The fix is not to declare it more carefully; it is to
      // declare it somewhere both processes can reach.
      final source =
          File('lib/core/guarded_history_views.dart').readAsStringSync();
      final code = source
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');

      expect(code, contains('groupForHistoryView'),
          reason: 'the group is looked up from the policy');
      expect(code, isNot(contains('const AccessGroup')),
          reason: 'and is not declared a second time here');
    });

    test('the five members ask the policy by name, not by a literal', () {
      // The live half: it is not enough that the file mentions the policy. If
      // a call site passed a string literal instead of the named constant, the
      // audit `reason` and the graded member could drift apart again — which
      // is the failure the member-name vocabulary exists to prevent.
      final code = File('lib/core/guarded_history_views.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      for (final member in [
        'historyViewCreate',
        'historyViewUpdate',
        'historyViewAddPeriod',
        'historyViewDelete',
        'historyViewDeletePeriod',
      ]) {
        expect(code, contains('AccessPolicy.$member'),
            reason: '$member is named, not re-typed as a string');
      }
      for (final literal in [
        "'createHistoryView'",
        "'deleteHistoryView'",
        "'deleteHistoryViewPeriod'",
      ]) {
        expect(code, isNot(contains(literal)),
            reason: 'the member name $literal is the policy vocabulary, not a '
                'literal repeated at the call site');
      }
    });

    test('the audit reason and the graded member are the same string',
        () async {
      // The behavioural half of the arm above, through the store rather than
      // through its source. A row's `reason` is the member the policy graded,
      // so a delete row cannot say `deleteHistoryView` while having been
      // graded as something open.
      session = _signedIn({AccessGroup.configure});
      final store = storeWith();

      await store.deleteHistoryView(4);
      await store.createHistoryView('a', const []);

      final deleteRow = audit.rows[0];
      expect(deleteRow.reason, AccessPolicy.historyViewDelete);
      expect(deleteRow.groupRequired,
          const AccessPolicy().groupForHistoryView(deleteRow.reason!)!.name);

      final createRow = audit.rows[1];
      expect(createRow.reason, AccessPolicy.historyViewCreate);
      expect(const AccessPolicy().groupForHistoryView(createRow.reason!), isNull,
          reason: 'and an open member records an empty groupRequired');
      expect(createRow.groupRequired, '');
    });
  });

  group('the page itself stays readable', () {
    test('/advanced/history-view is not in kRaisedRoutes', () {
      expect(kRaisedRoutes.keys, isNot(contains('/advanced/history-view')),
          reason: 'spec §11 defers read permissions on trends and history; '
              'gating this route would block reading history, which is '
              'operate-level work');
    });
  });
}
