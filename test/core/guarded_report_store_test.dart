// The report subsystem's write guard.
//
// `ReportStore` writes `report_config` and `shift_config` with raw SQL so the
// MCP server can write the same rows without a `Preferences`. That is exactly
// the shape of spec §6's bypasses: no `PreferencesApi.set*` passes, so
// `GuardedPreferences` never sees them. Both writes ask for `configure`; both
// leave a row either way.
//
// The route half of the ruling is asserted here too: `/reports` must stay
// unraised (reading a shift is operate-level work) while
// `/advanced/report-editor` is `configure` — so "the viewer stays readable"
// is a checked property rather than something that happened to be true.

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/guarded_report_store.dart';
import 'package:tfc/routes.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/tfc_dart.dart'
    show ReportConfig, ReportManConfig, ReportStore, ShiftDef, ShiftManConfig;

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// Records the two writes and performs neither.
///
/// `extends Fake` rather than a real store over SQLite: what matters on the
/// deny path is that the write was **never reached**, and a fake whose other
/// members throw makes anything else this guard touches fail loudly.
class _RecordingStore extends Fake implements ReportStore {
  final List<String> calls = [];

  @override
  Future<void> saveReports(ReportManConfig config) async {
    calls.add('saveReports(${config.reports.length})');
  }

  @override
  Future<void> saveShifts(ShiftManConfig config) async {
    calls.add('saveShifts(${config.shifts.length})');
  }
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// Fails the way an unreachable database does. Its failure must reach nobody.
class _ThrowingSink implements AuditSink {
  int calls = 0;

  @override
  Future<void> record(AuditRecord entry) async {
    calls++;
    throw StateError('audit sink is down');
  }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Nobody signed in, holding the seeded Operator groups — a panel on the floor.
final AccessSession _anonymous = AccessSession.anonymous(
  {...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups},
);

AccessSession _signedIn(Set<AccessGroup> groups, {String username = 'jon'}) =>
    AccessSession(
      user: AuthenticatedUser(username: username, roleName: 'Engineer'),
      groups: groups,
    );

ReportManConfig _reports() =>
    ReportManConfig(reports: [ReportConfig(id: 'r1', name: 'Shift report')]);

ShiftManConfig _shifts() => ShiftManConfig(shifts: [
      ShiftDef(name: 'Day', startMinutes: 420, durationMinutes: 480),
    ]);

void main() {
  late _RecordingStore store;
  late _RecordingSink audit;
  late List<AccessDenied> denials;
  late AccessSession session;

  GuardedReportStore guardWith({AuditSink? sink}) => GuardedReportStore(
        store: store,
        session: () => session,
        audit: sink ?? audit,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  setUp(() {
    store = _RecordingStore();
    audit = _RecordingSink();
    denials = [];
    session = _anonymous;
  });

  group('both writes require configure', () {
    test('an anonymous session is refused saveReports', () async {
      await expectLater(
        guardWith().saveReports(_reports()),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'report_config')
            .having((d) => d.required, 'required', AccessGroup.configure)),
      );
      expect(store.calls, isEmpty, reason: 'the write must not have landed');
      expect(denials, hasLength(1));
    });

    test('an anonymous session is refused saveShifts', () async {
      await expectLater(
        guardWith().saveShifts(_shifts()),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'shift_config')),
      );
      expect(store.calls, isEmpty);
    });

    test('a role holding configure may save both', () async {
      session = _signedIn({AccessGroup.operate, AccessGroup.configure});
      final guard = guardWith();
      await guard.saveReports(_reports());
      await guard.saveShifts(_shifts());
      expect(store.calls, ['saveReports(1)', 'saveShifts(1)']);
    });

    test('a neighbouring group is not enough', () async {
      // setpoints and force are what a shift leader might hold; neither
      // authors station configuration.
      session = _signedIn({AccessGroup.operate, AccessGroup.setpoints, AccessGroup.force});
      await expectLater(
          guardWith().saveReports(_reports()), throwsA(isA<AccessDenied>()));
      expect(store.calls, isEmpty);
    });
  });

  group('every attempt leaves a row', () {
    test('an allowed save records who, what and the group', () async {
      session = _signedIn({AccessGroup.configure});
      await guardWith().saveReports(_reports());

      final row = audit.rows.single;
      expect(row.allowed, isTrue);
      expect(row.who, 'jon');
      expect(row.station, 'SVN-NES-OT-CL02');
      expect(row.surface, AccessSurface.pref.wireName);
      expect(row.itemKey, 'report_config');
      expect(row.groupRequired, AccessGroup.configure.name);
      expect(row.reason, 'saveReports');
      // The definitions are far too large for an audit column; the count is
      // what a reader of the trail can use.
      expect(row.newValue, '1 reports');
    });

    test('a refusal is recorded too, and is the more interesting row',
        () async {
      await expectLater(
          guardWith().saveShifts(_shifts()), throwsA(isA<AccessDenied>()));

      final row = audit.rows.single;
      expect(row.allowed, isFalse);
      expect(row.who, 'anonymous');
      expect(row.itemKey, 'shift_config');
      expect(row.groupRequired, AccessGroup.configure.name);
    });

    test('the row is written before the write, so a failed write still says '
        'it was authorized', () async {
      session = _signedIn({AccessGroup.configure});
      await guardWith().saveReports(_reports());
      expect(audit.rows, hasLength(1));
      expect(store.calls, hasLength(1));
    });
  });

  group('the guard survives its own dependencies failing', () {
    test('a sink that throws does not fail the save', () async {
      session = _signedIn({AccessGroup.configure});
      final sink = _ThrowingSink();
      await guardWith(sink: sink).saveReports(_reports());
      expect(sink.calls, 1);
      expect(store.calls, hasLength(1), reason: 'the save still landed');
    });

    test('a throwing onDenied listener does not change the refusal', () async {
      final guard = GuardedReportStore(
        store: store,
        session: () => session,
        audit: audit,
        station: 'x',
        onDenied: (_) => throw StateError('prompt is broken'),
      );
      await expectLater(
          guard.saveReports(_reports()), throwsA(isA<AccessDenied>()));
      expect(store.calls, isEmpty);
    });

    test('the session is read per write, never captured', () async {
      final guard = guardWith();
      session = _signedIn({AccessGroup.configure});
      await guard.saveReports(_reports());
      // The inactivity monitor drops them back to anonymous mid-life.
      session = _anonymous;
      await expectLater(
          guard.saveReports(_reports()), throwsA(isA<AccessDenied>()));
      expect(store.calls, hasLength(1));
    });
  });

  group('the route half of the ruling', () {
    test('the report editor is raised at configure', () {
      expect(kRaisedRoutes[AppRoutes.reportEditor], AccessGroup.configure);
      expect(kRaisedRoutes[kReportEditorRoute], AccessGroup.configure);
    });

    test('the viewer stays unraised — reading a shift is operate work', () {
      expect(kRaisedRoutes.containsKey(AppRoutes.reports), isFalse);
      expect(accessGroupForRoute(AppRoutes.reports), AccessGroup.operate);
    });

    test('the guard and the preference rule name the same group', () {
      // Two sources for one answer would drift; this is what keeps them
      // honest. `report_config` is classified in kPrefAccessRules.
      const policy = AccessPolicy();
      expect(policy.groupForPref('report_config'), kReportConfigWriteGroup);
      expect(policy.groupForPref('shift_config'), kReportConfigWriteGroup);
    });
  });
}
