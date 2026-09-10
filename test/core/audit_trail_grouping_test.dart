// One human action is one group, wherever its rows landed in the window.
//
// This is a pure-function suite and must stay one. There is no database handle,
// no Drift connection and no `AppDatabase` in this file: `groupAuditRows` takes
// a list and returns a list, so a test that needed a database would be testing
// something other than the function.
//
// Every row is built by the local `row(...)` helper against fixed
// `DateTime.utc(...)` instants. Nothing here reads the clock — an assertion
// computed from `DateTime.now()` cannot fail when the rule it is about changes.

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/audit_trail_grouping.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// The instant the rows in this file are dated from.
final DateTime _at = DateTime.utc(2026, 8, 30, 12);

/// One audit row, with only the fields a grouping assertion cares about
/// spelled at the call site.
///
/// This used to auto-assign an ascending `id` so that two rows built with the
/// same arguments stayed distinguishable. `AuditRecord` carries no id — it is a
/// database identity and the store stopped handing one out — and `AuditRecord`
/// compares by value, so two calls with identical arguments now produce equal
/// rows. Every assertion in this file distinguishes rows by `actionId` or
/// `member`, which is what `groupAuditRows` actually reads; if a future case
/// needs two otherwise-identical rows told apart, vary one of those rather than
/// reaching for a surrogate.
AuditRecord row({
  required String actionId,
  DateTime? at,
  String itemKey = 'CN04.MOT01.Speed',
  String? member,
  String groupRequired = 'setpoints',
  bool allowed = true,
  String surface = 'tag',
  String who = 'olafur',
}) =>
    AuditRecord(
      at: at ?? _at,
      who: who,
      station: 'ST101',
      roleName: 'engineer',
      surface: surface,
      itemKey: itemKey,
      member: member,
      oldValue: '1',
      newValue: '2',
      groupRequired: groupRequired,
      allowed: allowed,
      origin: 'operator',
      actionId: actionId,
    );

void main() {
  // -------------------------------------------------------------------------
  // groupAuditRows
  // -------------------------------------------------------------------------

  group('groupAuditRows', () {
    test('an empty row list yields an empty action list', () {
      expect(groupAuditRows(const []), isEmpty);
    });

    test('groups appear in the order their first row appears in the input', () {
      final actions = groupAuditRows([
        row(actionId: 'c', at: DateTime.utc(2026, 8, 30, 12)),
        row(actionId: 'b', at: DateTime.utc(2026, 8, 30, 11)),
        row(actionId: 'a', at: DateTime.utc(2026, 8, 30, 10)),
      ]);

      expect(actions.map((action) => action.actionId), ['c', 'b', 'a'],
          reason: 'the store returns rows newest-first, so first-appearance '
              'order is newest-action-first. Sorting here would be a second '
              'ordering rule to keep in step with the SQL one.');
    });

    test('interleaved actions are grouped by actionId, not by adjacency', () {
      // A, B, A, B, A - an adjacency implementation produces five groups here,
      // which is exactly the defect this test exists to catch. Another SVN
      // station writing into the same database between two members of a local
      // struct write produces precisely this shape.
      final actions = groupAuditRows([
        row(actionId: 'A', member: 'p_cfg.Freq'),
        row(actionId: 'B', itemKey: 'CN09.MOT01.Speed'),
        row(actionId: 'A', member: 'p_cfg.Ramp'),
        row(actionId: 'B', itemKey: 'CN09.MOT01.Speed', member: 'p_cfg.Freq'),
        row(actionId: 'A', member: 'p_cfg.Accel'),
      ]);

      expect(actions.length, 2,
          reason: 'two actionIds means two actions however far apart another '
              'station pushed their rows');
      expect(actions.map((action) => action.actionId), ['A', 'B']);
      expect(actions.map((action) => action.rows.length), [3, 2]);
    });

    test('rows within a group keep their input order', () {
      final actions = groupAuditRows([
        row(actionId: 'A', member: 'p_cfg.Freq'),
        row(actionId: 'B'),
        row(actionId: 'A', member: 'p_cfg.Ramp'),
        row(actionId: 'A', member: 'p_cfg.Accel'),
      ]);

      expect(actions.first.rows.map((r) => r.member),
          ['p_cfg.Freq', 'p_cfg.Ramp', 'p_cfg.Accel']);
    });

    test('lead is the first row of the group', () {
      final first = row(actionId: 'A', member: 'p_cfg.Freq');
      final actions = groupAuditRows([
        first,
        row(actionId: 'A', member: 'p_cfg.Ramp'),
      ]);

      expect(actions.single.lead, same(first));
    });

    test('totalRowCount comes from totalsByActionId when the id is present',
        () {
      final actions = groupAuditRows(
        [row(actionId: 'A'), row(actionId: 'A')],
        totalsByActionId: const {'A': 9},
      );

      expect(actions.single.totalRowCount, 9);
    });

    test('an absent total falls back to rows.length - "we did not ask"', () {
      final actions = groupAuditRows([row(actionId: 'A'), row(actionId: 'A')]);

      expect(actions.single.totalRowCount, 2,
          reason: 'a caller that skipped the companion count query must '
              'degrade to a flat honest list, not to a claim that six '
              'siblings are missing');
      expect(actions.single.hiddenCount, 0);
      expect(actions.single.isPartial, isFalse);
    });

    test('three visible rows of a nine-row action report six hidden', () {
      final actions = groupAuditRows(
        [row(actionId: 'A'), row(actionId: 'A'), row(actionId: 'A')],
        totalsByActionId: const {'A': 9},
      );

      expect(actions.single.hiddenCount, 6);
      expect(actions.single.isPartial, isTrue);
      expect(actions.single.isMulti, isTrue);
    });

    test('a total smaller than rows.length clamps to zero, never negative', () {
      final actions = groupAuditRows(
        [row(actionId: 'A'), row(actionId: 'A'), row(actionId: 'A')],
        totalsByActionId: const {'A': 1},
      );

      expect(actions.single.hiddenCount, 0,
          reason: 'a stale or wrong total is a bad count, and "-2 members '
              'hidden" on the parent row would be worse than one');
      expect(actions.single.isPartial, isFalse);
    });

    test('a single visible row with hidden siblings is still multi', () {
      final actions = groupAuditRows(
        [row(actionId: 'A')],
        totalsByActionId: const {'A': 9},
      );

      expect(actions.single.isMulti, isTrue,
          reason: 'without an expander the "8 of 9 members hidden by filters" '
              'line has nowhere to live');
      expect(actions.single.hiddenCount, 8);
    });

    test('a single-row action with no total renders flat', () {
      final actions = groupAuditRows([row(actionId: 'A')]);

      expect(actions.single.isMulti, isFalse,
          reason: 'most rows are single writes and an expander on every one is '
              'noise');
      expect(actions.single.isPartial, isFalse);
      expect(actions.single.hiddenCount, 0);
    });

    test('no group is ever empty, so lead is always safe to call', () {
      final actions = groupAuditRows([
        row(actionId: 'A'),
        row(actionId: 'B'),
        row(actionId: 'A'),
      ]);

      expect(actions.every((action) => action.rows.isNotEmpty), isTrue);
      for (final action in actions) {
        expect(action.lead, same(action.rows.first));
      }
    });

    test('totals for actionIds not in the input are ignored', () {
      final actions = groupAuditRows(
        [row(actionId: 'A')],
        totalsByActionId: const {'A': 2, 'ZZ': 400},
      );

      expect(actions.map((action) => action.actionId), ['A'],
          reason: 'the totals map is a lookup, never a source of actions - a '
              'group with no visible rows has nothing to render');
    });
  });

  // -------------------------------------------------------------------------
  // strictestGroupName
  // -------------------------------------------------------------------------

  group('strictestGroupName', () {
    test(
        'returns the largest AccessGroup index, not the first or the '
        'alphabetical one', () {
      expect(strictestGroupName(['configure', 'users', 'operate']), 'users',
          reason: 'users is last in the enum and therefore the strictest; '
              'configure is first in the list and operate is first '
              'alphabetically, so both wrong answers are available');
    });

    test('a single recognised name is its own strictest', () {
      expect(strictestGroupName(['operate']), 'operate');
    });

    test('no names at all is the empty string', () {
      expect(strictestGroupName(const []), '');
    });

    test('all-empty names stay empty rather than defaulting to operate', () {
      expect(strictestGroupName(['', '']), '',
          reason: 'auth rows carry an empty group_required. Reporting operate '
              'for an all-auth action would be an invention - the action '
              'required no group at all');
    });

    test('every pair of AccessGroup values ranks by declaration index', () {
      // Driven from the enum rather than a hand-typed table: a table here would
      // be a second ranking to keep in step, which is the exact defect
      // guarded_state_man.dart's _strictest comment warns about.
      for (final a in AccessGroup.values) {
        for (final b in AccessGroup.values) {
          final expected = a.index > b.index ? a.name : b.name;
          expect(strictestGroupName([a.name, b.name]), expected,
              reason: 'strictest of ${a.name} and ${b.name} is the one with '
                  'the larger index, and AccessGroup is declared in '
                  'increasing privilege');
        }
      }
    });

    test('an unknown group name loses to a known one but is not a crash', () {
      expect(strictestGroupName(['device', 'quantum']), 'device',
          reason: 'group_required is stored text and a station on a newer '
              'build may have written a name this one has never heard of. '
              'AccessGroup.byName answers null for it, and an unrankable name '
              'must not outrank a rankable one');
    });

    test('an all-unknown action is reported verbatim, never dropped', () {
      expect(strictestGroupName(['quantum']), 'quantum',
          reason: 'the operator sees the string the database actually holds. '
              'Substituting operate here would default an unrecognised '
              'permission downward, which is what byName returning null '
              'exists to prevent');
    });
  });

  // -------------------------------------------------------------------------
  // AuditAction.requiredGroupLabel
  // -------------------------------------------------------------------------

  group('AuditAction.requiredGroupLabel', () {
    test("is the strictest across the children, not the lead row's value", () {
      // One human action may span more than one call - dynamic_value_diff.dart
      // says so in as many words about a recipe apply - so the children's
      // group_required strings can genuinely differ.
      final actions = groupAuditRows([
        row(actionId: 'A', groupRequired: 'operate'),
        row(actionId: 'A', groupRequired: 'administer'),
        row(actionId: 'A', groupRequired: 'setpoints'),
      ]);

      expect(actions.single.requiredGroupLabel, 'administer',
          reason: 'reading it off rows.first would report operate and the '
              'parent would under-state what the action needed');
    });

    test('an all-auth action requires nothing', () {
      final actions = groupAuditRows([
        row(
            actionId: 'A',
            surface: 'auth',
            itemKey: 'login',
            groupRequired: ''),
        row(
            actionId: 'A',
            surface: 'auth',
            itemKey: 'logout',
            groupRequired: ''),
      ]);

      expect(actions.single.requiredGroupLabel, '',
          reason: 'not operate. The row widget renders no permission for it');
    });

    test('an unknown child group name reaches the parent unchanged', () {
      final actions = groupAuditRows([
        row(actionId: 'A', groupRequired: 'quantum'),
      ]);

      expect(actions.single.requiredGroupLabel, 'quantum');
    });
  });

  // -------------------------------------------------------------------------
  // isAuthEntry
  // -------------------------------------------------------------------------

  group('isAuthEntry', () {
    test(
        'is true for the auth surface and false for an empty group_required '
        'on another surface', () {
      expect(
          isAuthEntry(row(
              actionId: 'A',
              surface: 'auth',
              itemKey: 'login',
              groupRequired: '')),
          isTrue);
      expect(
          isAuthEntry(row(
              actionId: 'B',
              surface: 'pref',
              itemKey: 'mcp.enabled',
              groupRequired: '')),
          isFalse,
          reason: "05-01's store selects the auth leg with surface = 'auth' "
              'and this predicate reads the same column with the same value. '
              'An earlier draft keyed the store on an empty group_required and '
              'this on surface; they agree on every row that exists today, so '
              'nothing would have caught them diverging. An unbound tag write '
              'also carries an empty group_required, which is the row that '
              'would have broken first');
    });

    test('a write row on the tag surface is not an auth row', () {
      expect(isAuthEntry(row(actionId: 'A')), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The known-surface change detector
  // -------------------------------------------------------------------------

  group('kKnownAuditSurfaces', () {
    test('names exactly the five surfaces this build knows about', () {
      expect(kKnownAuditSurfaces, {'tag', 'pref', 'route', 'auth', 'admin'},
          reason: 'This is the one written record of the audit surface '
              'vocabulary, and it is a change-detector rather than a '
              'whitelist. If you are reading this failure you have added a '
              'surface. Add it to kKnownAuditSurfaces in '
              'lib/core/audit_trail_grouping.dart, then re-check that '
              "AuditEntryLine's default branch still renders a row carrying "
              'it sanely. Nothing filters on this set, so an unlisted surface '
              'is displayed rather than dropped - which is why this assertion '
              'is the only place the change has to surface.');
    });

    test('an unlisted surface flows through grouping untouched', () {
      // A surface no build has ever declared, standing in for the row a
      // station running a newer build writes into the same database. It is
      // deliberately not 'admin' any more: 'admin' is listed now, and a
      // change-detector's companion test has to use a value that is genuinely
      // absent from the set or it stops proving anything.
      final actions = groupAuditRows([
        row(
            actionId: 'A',
            surface: 'from-a-newer-build',
            itemKey: 'role.create',
            groupRequired: 'users'),
        row(
            actionId: 'A',
            surface: 'from-a-newer-build',
            itemKey: 'role.update',
            groupRequired: 'users'),
      ]);

      expect(actions.single.rows.length, 2,
          reason: 'nothing in this file gates on surface membership, so a row '
              'from a station running a newer build still renders');
      expect(actions.single.requiredGroupLabel, 'users');
      expect(isAuthEntry(actions.single.lead), isFalse);
    });
  });
}
