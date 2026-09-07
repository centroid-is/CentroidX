/// The three access stores still carry their gates, from inside `tfc_dart`.
///
/// Plan 17-02 moved `AccessTemplateStore`, `AccessAdminStore` and
/// `AuditTrailStore` out of the app's `lib/core/` and into this package, so the
/// backend serves **the same class** the panel calls rather than a second
/// implementation of one policy. The app's own suites
/// (`test/core/access_template_store_test.dart` and its two siblings) still
/// cover the behaviour in full and are not duplicated here.
///
/// What this file adds is the one thing those cannot: it runs **in this
/// package**, with no Flutter anywhere in the process, which is the property
/// that makes the backend able to import these classes at all. It is the arm
/// 17-06 builds on.
///
/// ## Two refusals, not three
///
/// `AccessTemplateStore` and `AccessAdminStore` are gated on
/// `AccessGroup.users` and refuse a `configure`-only session with a deny row
/// written **before** the throw. `AuditTrailStore` is not gated and has no
/// refusal to assert: it takes no session, holds no `AuditSink`, and its
/// enforcement is the route gate `kRaisedRoutes['/advanced/audit-trail']`,
/// deliberately — a store-level guard there would write a row into the trail
/// every time somebody scrolled the trail. Asserting a refusal it does not
/// have would be a test of a guard that is not there, so its arm asserts what
/// is true instead: that it still reads, and that it still cannot refuse.
///
/// ## Anti-vacuity
///
/// Each refusal arm is paired with a `users`-holding session making the **same
/// call** and succeeding. A store that had lost its database, or that refused
/// everything, passes a refusal test and breaks the plant.
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_admin_store.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/access_template_store.dart';
import 'package:tfc_dart/core/access/audit_trail_store.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// Every row the store handed the trail, in order.
class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// The page editor who must not be able to decide who may do what.
///
/// `configure` is the highest group a page editor needs, and it holds neither
/// `administer` nor `users` — so the two spellings cannot be confused here by
/// accident.
const AccessSession _configureOnly = AccessSession(
  user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
  groups: {
    AccessGroup.operate,
    AccessGroup.setpoints,
    AccessGroup.device,
    AccessGroup.configure,
  },
);

/// The administrator who holds `users`.
const AccessSession _withUsers = AccessSession(
  user: AuthenticatedUser(username: 'admin', roleName: 'Administrator'),
  groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
);

final AccessTemplate _template = AccessTemplate(
  name: 'Line 1 setpoints',
  rules: {'CN01.*': AccessGroup.setpoints},
);

const AccessRole _shiftLead = AccessRole(
  name: 'Line Lead',
  groups: {AccessGroup.operate, AccessGroup.setpoints},
);

void main() {
  late AppDatabase db;
  late _RecordingSink sink;
  late List<AccessDenied> denials;
  late AccessSession session;

  setUp(() async {
    // PBKDF2 at production iteration counts costs the better part of a second
    // per account, and the admin arms create one.
    Pbkdf2Kdf.iterationsForTest = 10;
    db = AppDatabase.inMemoryForTest();
    // Force the schema — and with it the seeded roles — to exist before the
    // first store call, so a row count read back on the deny path is reading a
    // real table rather than failing to find one.
    await db.customSelect('SELECT 1').getSingle();
    sink = _RecordingSink();
    denials = [];
    session = _configureOnly;
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  AccessTemplateStore templates() => AccessTemplateStore(
        db: db,
        session: () => session,
        audit: sink,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  AccessAdminStore admin() => AccessAdminStore(
        repository: AccessRepository(db),
        session: () => session,
        audit: sink,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  Future<int> countOf(String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.read<int>('c');
  }

  // ---------------------------------------------------------------------------
  // The gates the move had to carry with it
  // ---------------------------------------------------------------------------

  group('AccessTemplateStore, from inside tfc_dart', () {
    test('refuses a configure-only session, and records the refusal first',
        () async {
      final before = await countOf('access_template');

      await expectLater(
        templates().create(_template),
        throwsA(isA<AccessDenied>()),
      );

      expect(await countOf('access_template'), before,
          reason: 'the refusal is pre-effect: nothing reached the table');
      expect(denials, hasLength(1));
      expect(sink.rows, hasLength(1),
          reason: 'a refusal that leaves no trace is the one kind of guard '
              'nobody can audit afterwards, so the deny row is written before '
              'the AccessDenied is thrown');
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.groupRequired, AccessGroup.users.name);
    });

    test('the same call succeeds for a session holding users', () async {
      session = _withUsers;

      await templates().create(_template);

      expect(await countOf('access_template'), 1,
          reason: 'the anti-vacuity half. A store that had lost its database, '
              'or that refused everybody, would pass the arm above.');
      expect(denials, isEmpty);
      expect(sink.rows.single.allowed, isTrue);
    });

    test('names users as its gate', () {
      expect(kAccessTemplateGroup, AccessGroup.users);
    });
  });

  group('AccessAdminStore, from inside tfc_dart', () {
    test('refuses a configure-only session, and records the refusal first',
        () async {
      final before = await countOf('app_role');

      await expectLater(
        admin().createRole(_shiftLead),
        throwsA(isA<AccessDenied>()),
      );

      expect(await countOf('app_role'), before,
          reason: 'lowering this gate would let anybody who can edit a page '
              'grant themselves users, and from there everything');
      expect(denials, hasLength(1));
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.groupRequired, AccessGroup.users.name);
    });

    test('the same call succeeds for a session holding users', () async {
      session = _withUsers;
      final before = await countOf('app_role');

      await admin().createRole(_shiftLead);

      expect(await countOf('app_role'), before + 1);
      expect(denials, isEmpty);
      expect(sink.rows.single.allowed, isTrue);
    });

    test('names users as its gate', () {
      expect(kAccessAdminGroup, AccessGroup.users);
    });
  });

  // ---------------------------------------------------------------------------
  // The one that has no gate, and must not grow one
  // ---------------------------------------------------------------------------

  group('AuditTrailStore, from inside tfc_dart', () {
    test('reads the trail the other two stores wrote', () async {
      // `DriftAuditSink` rather than the recording double, so the rows land in
      // `audit_entry` and this arm becomes the three moved files agreeing on
      // one table: two writers, one reader, one database, all in tfc_dart now.
      final trail = DriftAuditSink(db);
      session = _withUsers;
      await AccessTemplateStore(
        db: db,
        session: () => session,
        audit: trail,
        station: 'SVN-NES-OT-CL02',
      ).create(_template);
      await AccessAdminStore(
        repository: AccessRepository(db),
        session: () => session,
        audit: trail,
        station: 'SVN-NES-OT-CL02',
      ).createRole(_shiftLead);

      final entries = await AuditTrailStore(db: db).entries(AuditQuery());

      expect(entries, hasLength(2),
          reason: 'the anti-vacuity half of the arm below: a store that read '
              'nothing would also refuse nobody, and both halves would pass');
      expect(entries.every((e) => e.who == 'admin'), isTrue);
    });

    test('takes no session and so cannot refuse anybody', () async {
      // Constructed with a database and nothing else — no session, no sink, no
      // station, no onDenied. The route gate is the enforcement and this is
      // that claim in executable form: there is no parameter through which a
      // caller could be identified, so there is nothing to refuse them on.
      final store = AuditTrailStore(db: db);

      await expectLater(store.entries(AuditQuery()), completes);
      expect(denials, isEmpty);
      expect(sink.rows, isEmpty,
          reason: 'reading the trail does not appear in the trail: a row per '
              'render would fill the page with people looking at it');
    });

    test('names users as the group its ROUTE requires', () {
      // Not a store gate. Declared beside the store so the route and the store
      // name one decision.
      expect(kAuditTrailGroup, AccessGroup.users);
    });
  });
}
