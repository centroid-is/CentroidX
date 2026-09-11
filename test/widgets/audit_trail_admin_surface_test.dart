/// Phase 6's `admin` surface, through Phase 5's viewer, with Phase 5 unchanged.
///
/// ## What this file is
///
/// A **cross-phase contract test**, owned by Phase 6, asserting a claim Phase 6
/// made about somebody else's code. Plan 06-01 gave every admin row
/// `groupRequired: 'users'` and kept `admin` as a private surface literal
/// specifically so that Phase 5's viewer would need no change; that is a claim
/// about files this phase does not own, made across a phase boundary, and a
/// paragraph in a plan is not evidence for it. This is the evidence.
///
/// The arc under test is the whole contract in one line: **written by Phase 6,
/// selected by Phase 5, with nobody's test double in between.** Every test here
/// drives a real `AccessAdminStore` over a real in-memory database through the
/// real `DriftAuditSink`, and reads the row back through the real
/// [AuditTrailStore]. A hand-built `AuditRecord` would prove that a
/// hand-written row renders, which is a different and much weaker claim than
/// the one 06-01 made.
///
/// ## The two halves
///
/// **The positive half** is that an admin row survives the default filters, is
/// excluded when the `users` chip is deselected, does not ride in on the auth
/// leg, and renders through the generic write shape.
///
/// **The negative half** is that this works because Phase 5's viewer is
/// generic, not because somebody added a branch to it. The three viewer files
/// carry no `'admin'` literal and no Phase 6 commit has touched them.
///
/// ## What to do if this file goes red
///
/// **Do not patch Phase 5.** A failure here means the vocabulary or the viewer
/// moved and the two phases need reconciling, which is a conversation and not a
/// quiet edit to another phase's committed contract. Read
/// `.planning/phases/05-the-audit-trail-page/deferred-items.md`, the section
/// "For Phase 6", which is where Phase 5 wrote the contract down, and then say
/// which of the two phases moved. Editing `lib/widgets/audit_trail_row.dart`,
/// `lib/widgets/audit_trail_filters.dart` or `lib/core/audit_trail_store.dart`
/// to make this green would delete the finding and keep the defect.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/core/audit_trail_grouping.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/audit_trail_row.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database_drift.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The station every row below is written from.
const String _station = 'SVN-NES-OT-CL02';

/// The administrator who holds `users`, so the gate passes and the rows are
/// allowed writes rather than refusals.
///
/// The refusal path has its own coverage in `access_admin_store_test.dart`;
/// what this file needs is the ordinary row an operator will actually read.
const AccessSession _administrator = AccessSession(
  user: AuthenticatedUser(username: 'admin', roleName: 'Engineering'),
  groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
);

/// The role before the edit, and after it.
///
/// Two group sets rather than one, because the claim the widget test makes is
/// about the **transition**: a role's group set changing *is* the value, and
/// Phase 5's row widget renders `oldValue` to `newValue` without ever learning
/// what a `role.` key means.
const AccessRole _lineLeadBefore = AccessRole(
  name: 'Line Lead',
  groups: {AccessGroup.operate},
);
const AccessRole _lineLeadAfter = AccessRole(
  name: 'Line Lead',
  groups: {AccessGroup.operate, AccessGroup.setpoints},
);

/// Phase 5's three viewer files — the ones this phase claims it did not need
/// to touch.
///
/// The third moved in Phase 17 (plan 17-02), into `tfc_dart`, so the backend
/// serves the same class the panel calls. Re-pathed rather than left alone:
/// `lib/core/audit_trail_store.dart` is now a fourteen-line `export`, and both
/// arms below are absences — "not empty" and "does not contain `'admin'`" —
/// which that stand-in satisfies for the same reason an empty file would. The
/// arms would have gone on passing and stopped meaning anything, which is the
/// silent failure this file exists to make loud.
const List<String> _kViewerFiles = <String>[
  'lib/widgets/audit_trail_row.dart',
  'lib/widgets/audit_trail_filters.dart',
  'packages/tfc_dart/lib/core/access/audit_trail_store.dart',
];

/// The floor each viewer file must clear, so `isNotEmpty` cannot be satisfied
/// by a re-export left behind at an old path. The smallest of the three is
/// over 200 lines.
const int _kMinimumViewerLines = 200;

/// A commit subject scoped to a Phase 6 plan, as this repo spells them:
/// `feat(06-03): ...`, `test(06-06): ...`.
final RegExp _kPhase6Scope = RegExp(r'\(06-\d\d\)');

/// Pumps [child] under the muted light theme at a width a 1080p panel would
/// give it.
///
/// `muted()` rather than a bare `MaterialApp`, for the reason
/// `audit_trail_row_test.dart` states at its head: `HmiStateColors.of` falls
/// back to `solarizedLight` when the theme carries no extension, so a row
/// rendered under a bare app is a row rendered in a palette this build never
/// ships.
Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: muted().$1,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 760, child: child),
        ),
      ),
    ),
  );
}

/// Every string this subtree actually puts on screen.
Iterable<String> _textsOnScreen(WidgetTester tester) sync* {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data;
    if (data != null) yield data;
  }
}

void main() {
  late AppDatabase db;
  late AccessAdminStore store;
  late AuditTrailStore trail;

  setUp(() async {
    // PBKDF2 at production iteration counts costs the better part of a second
    // per account, and the user test below creates one.
    Pbkdf2Kdf.iterationsForTest = 10;
    db = AppDatabase.inMemoryForTest();
    // Force the schema — and with it the four seeded roles — to exist before
    // the first store call.
    await db.customSelect('SELECT 1').getSingle();
    store = AccessAdminStore(
      repository: AccessRepository(db),
      session: () => _administrator,
      audit: DriftAuditSink(db),
      station: _station,
    );
    trail = AuditTrailStore(db: db);
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  /// The real write path: create a role, then widen it.
  ///
  /// Two writes on purpose. `updateRole` reads the existing row for its
  /// `oldGroups`, so an update against a role that was never created would
  /// carry an empty old value and the transition under test would be half a
  /// transition.
  Future<void> widenLineLead() async {
    await store.createRole(_lineLeadBefore);
    await store.updateRole(_lineLeadAfter);
  }

  /// What Phase 5's store returns for [filters], right now.
  Future<List<AuditRecord>> read(AuditTrailFilters filters) =>
      trail.entries(filters.toQuery(now: DateTime.now()));

  /// The one `role.update` row, as the trail returned it.
  AuditRecord roleUpdate(List<AuditRecord> rows) =>
      rows.singleWhere((row) => row.itemKey == 'role.update');

  // -------------------------------------------------------------------------
  // The store half: written by Phase 6, selected by Phase 5
  // -------------------------------------------------------------------------

  group('an admin row, written by Phase 6 and selected by Phase 5', () {
    test('is returned under the default filters, with no chip touched',
        () async {
      await widenLineLead();

      final rows = await read(const AuditTrailFilters());
      final update = roleUpdate(rows);

      expect(update.surface, 'admin');
      expect(
        update.groupRequired,
        AccessGroup.users.name,
        reason: 'this is why no viewer change was needed. 06-01 gave every '
            'admin row `groupRequired: users`, and '
            '`kAuditTrailDefaultGroupNames` is every group except `operate` — '
            'so the chip that selects this row is already on when the page '
            'opens. Change either end and the trail stops showing role and '
            'user administration by default, which is the one category of '
            'write the milestone least wants invisible.',
      );
      expect(
        kAuditTrailDefaultGroupNames,
        contains(AccessGroup.users.name),
        reason: 'the other end of the same claim, asserted here so a failure '
            'says which half moved',
      );
    });

    test('is excluded once the `users` chip is deselected', () async {
      await widenLineLead();

      final withoutUsers = const AuditTrailFilters().copyWith(
        groupNames: kAuditTrailDefaultGroupNames
            .where((name) => name != AccessGroup.users.name)
            .toList(),
      );

      expect(
        (await read(withoutUsers)).where((row) => row.surface == 'admin'),
        isEmpty,
        reason: 'without this the test above would pass on a query that '
            'ignored the group filter entirely, which is the same green for a '
            'completely different reason',
      );
      expect(
        (await read(const AuditTrailFilters()))
            .where((row) => row.surface == 'admin'),
        isNotEmpty,
        reason: 'the same rows, the same store, one chip apart — so the '
            'exclusion above is the filter doing the selecting',
      );
    });

    test(
        'is returned with `includeAuth` false — admin rows do not ride in on '
        'the auth leg', () async {
      await widenLineLead();

      final rows = await read(const AuditTrailFilters(includeAuth: false));

      expect(
        rows.where((row) => row.surface == 'admin'),
        isNotEmpty,
        reason: 'the group predicate ORs a `surface = auth` leg for sign-ins, '
            'which carry an empty `group_required`. An admin row must be '
            'selected by the group leg on its own merits; if it needed the '
            'auth leg, turning the auth chip off would silently hide every '
            'role edit on the station.',
      );
    });

    test('`isAuthEntry` answers false for it, so it takes the write path',
        () async {
      await widenLineLead();

      final update = roleUpdate(await read(const AuditTrailFilters()));

      expect(
        isAuthEntry(update),
        isFalse,
        reason: '`isAuthEntry` is the only surface predicate in Phase 5 and '
            'the only branch in `AuditEntryLine`. False here is what puts an '
            'admin row on the generic write shape — with its value transition '
            'rendered — rather than on the auth shape, which withholds the '
            'value columns.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // The widget half: rendered by Phase 5's row widget, unmodified
  // -------------------------------------------------------------------------

  group("an admin row through Phase 5's row widget", () {
    testWidgets('a role.update renders the generic write shape',
        (tester) async {
      await widenLineLead();
      final update = roleUpdate(await read(const AuditTrailFilters()));
      final actions = groupAuditRows([update]);
      expect(actions, hasLength(1));

      await _pump(tester, AuditActionTile(action: actions.single));

      expect(tester.takeException(), isNull);
      expect(
        find.byType(AuditEntryLine),
        findsOneWidget,
        reason: 'a single-row action renders flat, with no expander — '
            "CONTEXT's locked rule, and the shape every admin write takes",
      );

      // The itemKey and the member — the role that was edited — on the one key
      // line, exactly as a struct member row reads.
      expect(
        find.text('role.update.${_lineLeadAfter.name}'),
        findsOneWidget,
        reason: 'the key column is `itemKey` for a scalar write and '
            '`itemKey.member` for a member row; 06-01 puts the role name in '
            '`member`, so the line names both the action and its subject',
      );

      // Both encoded group sets, as the old-to-new transition. This is the
      // obligation Phase 5 put on Phase 6's *writer*: the viewer renders
      // whatever is in the two value columns and must never learn what a
      // `role.` key means, so a null pair here would record that something
      // happened to a role without recording what.
      final transition = '${_lineLeadBefore.encodeGroups()} '
          '$kAuditTransitionArrow ${_lineLeadAfter.encodeGroups()}';
      expect(
        find.text(transition),
        findsOneWidget,
        reason: 'expected "$transition" on screen; the row widget renders the '
            'old value, the transition arrow and the new value, and 06-01 '
            'fills both columns with `AccessRole.encodeGroups()` output',
      );
      expect(update.oldValue, _lineLeadBefore.encodeGroups());
      expect(update.newValue, _lineLeadAfter.encodeGroups());
    });

    testWidgets(
        'a user.password row renders no value, only the missing-value mark, '
        'and throws on neither null', (tester) async {
      await store.createUser(
        username: 'kari',
        password: 'the-first-one',
        roleName: 'Shift Leader',
      );
      await store.setUserPassword('kari', 'the-second-one');

      final rows = await read(const AuditTrailFilters());
      final reset = rows.singleWhere((row) => row.itemKey == 'user.password');

      expect(reset.oldValue, isNull);
      expect(reset.newValue, isNull);

      await _pump(
        tester,
        AuditActionTile(action: groupAuditRows([reset]).single),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('user.password.kari'), findsOneWidget);

      // Phase 5's documented behaviour for a null pair, in its own words: "the
      // same em-dash rule when either is null". So the value slot holds the
      // missing-value mark on both sides and no value of any kind — which is
      // what a password reset row must say and the whole of what it may say.
      expect(
        find.text(
            '$kAuditValueMissing $kAuditTransitionArrow $kAuditValueMissing'),
        findsOneWidget,
        reason: 'the row widget applies the missing-value mark to each null '
            'side. This asserts the placeholder rather than a value, because '
            'the placeholder is what the viewer draws and a value in that slot '
            'would be the disclosure.',
      );

      for (final text in _textsOnScreen(tester)) {
        expect(
          text,
          isNot(contains('the-first-one')),
          reason: 'a credential reached the screen through the audit trail: '
              '"$text"',
        );
        expect(
          text,
          isNot(contains('the-second-one')),
          reason: 'a credential reached the screen through the audit trail: '
              '"$text"',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // The negative half: Phase 5 was not edited to accommodate this
  // -------------------------------------------------------------------------

  group('the viewer works because it is generic, not because of a branch', () {
    test("none of Phase 5's three viewer files carries an `admin` literal", () {
      for (final path in _kViewerFiles) {
        final file = File(path);
        final source = file.readAsStringSync();
        expect(source, isNotEmpty, reason: '$path is missing or empty');
        expect(file.readAsLinesSync().length,
            greaterThan(_kMinimumViewerLines),
            reason: '$path must be the real viewer file, not a re-export left '
                'behind at an old path. The assertion below is an absence, and '
                'a stand-in satisfies it without proving anything.');
        expect(
          source.contains("'admin'"),
          isFalse,
          reason: '$path names the surface as a Dart literal. That is a '
              'branch on `surface`, and the open-vocabulary contract is that '
              'there is exactly one — `isAuthEntry`. A viewer that knows about '
              '`admin` is a viewer that will not draw the sixth surface. The '
              'mentions in the doc comments are in backticks and are prose '
              'about the contract, which is why this greps for the quoted '
              'literal.',
        );
      }
    });

    test('no Phase 6 commit has touched any of the three', () {
      // A history assertion rather than a stated intention: the three files
      // belong to Phase 5 and Phase 6 executes in the same worktree, so "we
      // did not edit them" is checkable and therefore should be checked.
      //
      // Tolerant of an environment with no repository — a shallow CI checkout
      // narrows what `git log` can see rather than making it lie — but never
      // vacuous: when git cannot answer, the source-content property above is
      // re-asserted here so this test still fails on a viewer that learned
      // about `admin`.
      for (final path in _kViewerFiles) {
        final result =
            Process.runSync('git', ['log', '--format=%s', '--', path]);
        if (result.exitCode != 0) {
          expect(
            File(path).readAsStringSync().contains("'admin'"),
            isFalse,
            reason: 'git could not answer for $path; falling back to the '
                'source-content half of the same claim',
          );
          continue;
        }

        final subjects = (result.stdout as String)
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList();
        expect(
          subjects,
          isNotEmpty,
          reason: '$path has no commit history at all — this search found '
              'nothing to search, which is a vacuous pass',
        );

        expect(
          subjects.where(_kPhase6Scope.hasMatch),
          isEmpty,
          reason: 'a Phase 6 commit touched $path. Phase 5 owns it, its '
              'open-vocabulary contract is what makes the `admin` surface '
              'work, and 06-06 exists to prove that contract rather than to '
              'bend it. If the viewer genuinely needs a change, that is a '
              'conversation between the two phases and not a quiet edit.',
        );
      }
    });
  });
}
