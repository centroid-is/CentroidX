/// The accept path for `access_account` and `access_role` proposals.
///
/// An agent proposes; a person approves. This file is about the approval,
/// because every promise the MCP tools make about it is one they cannot keep
/// themselves:
///
///  * the change goes through the **same** `users`-gated `AccessAdminStore`
///    the access screen's own controls use, so an approver without `users`
///    is refused and the refusal is recorded,
///  * the row carries `origin: 'mcp'`,
///  * the row's `who` is the approving human from the live session — the
///    proposals here carry a conflicting `operator_id` on purpose,
///  * the repository's refusals — a held role, the last `users` holder — are
///    decided at the accept and leave **that** proposal pending,
///  * the two credential-bearing operations ask for the password **at the
///    panel**, and a proposal never carries one.
///
/// The store, repository and database are real; every claim about what
/// happened is read back from the tables or the audit sink.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/pages/access_admin_proposals.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;

import '../helpers/test_helpers.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

class _RecordingProposals extends ProposalStateNotifier {
  final List<int> accepted = [];
  final List<int> rejected = [];

  @override
  Future<void> acceptProposal(int id) async {
    accepted.add(id);
    await super.acceptProposal(id);
  }

  @override
  Future<void> rejectProposal(int id) async {
    rejected.add(id);
    await super.rejectProposal(id);
  }
}

/// The device-local store the session controller watches. In memory, so no
/// platform channel is asked for anything.
class _MemoryPrefs extends Fake implements PreferencesApi {
  final Map<String, Object> _store = {};

  @override
  Future<int?> getInt(String key) async => _store[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => _store[key] = value;

  @override
  Future<bool?> getBool(String key) async => _store[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async => _store[key] = value;

  @override
  Future<String?> getString(String key) async => _store[key] as String?;

  @override
  Future<void> setString(String key, String value) async => _store[key] = value;
}

class _FakeAuthProvider implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(String username, String password) async =>
      null;
}

// ---------------------------------------------------------------------------
// Sessions and fixtures — invented names, no site in them
// ---------------------------------------------------------------------------

const String _kStation = 'station-1';

/// The approver: a person at the panel holding `users`.
AccessSession _approver() => const AccessSession(
      user: AuthenticatedUser(username: 'gudrun', roleName: 'Engineering'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

/// The engineer the gate exists for.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {AccessGroup.operate, AccessGroup.configure},
    );

/// The name the proposal claims made it. Never the name that reaches a row.
const String _kAgent = 'sweeper-agent';

PendingProposal _proposal(
  int id,
  String type,
  String op,
  Map<String, dynamic> body,
) =>
    PendingProposal(
      id: id,
      proposalType: type,
      title: body['title'] as String? ?? 'proposal',
      proposalJson: jsonEncode({
        ...body,
        'operator_id': _kAgent,
        'who': _kAgent,
        '_proposal_type': type,
        '_op': op,
      }),
      operatorId: _kAgent,
      createdAt: DateTime(2026, 9, 1),
    );

class _Staged {
  _Staged(this.container, this.proposals, this.sink);

  final ProviderContainer container;
  final _RecordingProposals proposals;
  final _RecordingSink sink;

  Future<void> Function()? get commit =>
      container.read(proposalCommitProvider);
  Future<void> Function()? get discard =>
      container.read(proposalDiscardProvider);
  List<AuditRecord> get rows => sink.rows;
}

void main() {
  late AppDatabase db;
  late AccessRepository repository;
  late _RecordingSink sink;
  late AccessSession session;

  setUp(() async {
    DatabaseConfig.clearPrefsCache();
    Pbkdf2Kdf.iterationsForTest = 10;

    db = AppDatabase.inMemoryForTest();
    // Force the migration: the four seeded roles and the anonymous row.
    await db.customSelect('SELECT 1').getSingle();
    repository = AccessRepository(db);
    // Closes the first-user window, so the proposals land on a commissioned
    // station and `gudrun` is the one `users` holder.
    await repository.createFirstUser(username: 'gudrun', password: 'pw1');
    sink = _RecordingSink();
    session = _approver();
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  Future<_Staged> stage(
    WidgetTester tester,
    List<PendingProposal> pending, {
    bool noDatabase = false,
  }) async {
    final proposals = _RecordingProposals();
    for (final p in pending) {
      proposals.addProposal(p);
    }
    final container = ProviderContainer(overrides: [
      accessRepositoryProvider.overrideWith((ref) async => repository),
      authProviderProvider.overrideWith((ref) async => _FakeAuthProvider()),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
      localPreferencesProvider.overrideWithValue(_MemoryPrefs()),
      accessAdminStoreProvider.overrideWith((ref) async {
        if (noDatabase) return null;
        return AccessAdminStore(
          repository: repository,
          session: () => session,
          audit: sink,
          station: _kStation,
          onDenied: (denial) => reportAccessDenial(ref, denial),
        );
      }),
      proposalStateProvider.overrideWith((ref) => proposals),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const PromptedApp(
        home: Scaffold(
          body: AccessAdminProposalsSection(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return _Staged(container, proposals, sink);
  }

  Future<List<String>> roleNames() async =>
      (await repository.roles()).map((r) => r.name).toList()..sort();

  Future<AppUserData?> user(String name) => repository.user(name);

  // -------------------------------------------------------------------------
  group('the routing table knows both types', () {
    test('both route to the access screen', () {
      expect(proposalRoutes['access_account'], '/advanced/access');
      expect(proposalRoutes['access_role'], '/advanced/access');
    });

    test('editorLabel names the access screen', () {
      final p = _proposal(-1, 'access_account', 'create', {'username': 'x'});
      expect(p.editorLabel, 'Access');
      expect(p.editorRoute, '/advanced/access');
    });

    test('_op says what accepting does, rename included', () {
      expect(_proposal(-1, 'access_role', 'create', {}).action,
          ProposalOp.create);
      expect(_proposal(-2, 'access_role', 'rename', {}).action,
          ProposalOp.update);
      expect(_proposal(-3, 'access_account', 'delete', {}).action,
          ProposalOp.delete);
    });

    test('the feedback sentence names the thing acted on', () {
      final account = _proposal(
          -1, 'access_account', 'create', {'title': 'Account "x"'});
      final role = _proposal(-2, 'access_role', 'delete', {'title': 'Role "r"'});
      expect(describeProposalFeedback('accepted', [account]),
          'Accepted the account proposal "Account "x"".');
      expect(describeProposalFeedback('rejected', [role]),
          'Rejected the role proposal "Role "r"".');
    });
  });

  // -------------------------------------------------------------------------
  group('an accepted proposal is applied through the users-gated store', () {
    testWidgets('a role create lands, with origin mcp and who = the approver',
        (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_role', 'create', {
          'title': 'Role "Cleaning"',
          'name': 'Cleaning',
          'groups': ['operate', 'setpoints'],
          'reason': 'night crew',
        }),
      ]);
      expect(find.byKey(kAccessAdminProposalsKey), findsOneWidget);
      expect(find.textContaining('Create role "Cleaning"'), findsOneWidget);
      expect(staged.commit, isNotNull);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await roleNames(), contains('Cleaning'));
      final created = await repository.role('Cleaning');
      expect(created!.groups, {AccessGroup.operate, AccessGroup.setpoints});

      expect(staged.rows, hasLength(1));
      final row = staged.rows.single;
      expect(row.itemKey, 'role.create');
      expect(row.origin, 'mcp');
      expect(row.who, 'gudrun');
      expect(row.who, isNot(_kAgent));
      expect(row.allowed, isTrue);
      expect(row.groupRequired, AccessGroup.users.name);
      expect(row.reason, 'night crew');
      expect(staged.proposals.accepted, [-1]);
      expect(staged.commit, isNull,
          reason: 'the batch is done, so the banner stops offering Accept');
      expect(find.byKey(kAccessAdminProposalsKey), findsNothing);
    });

    testWidgets('an account roles update, a station flag, a role update, a '
        'rename and a delete all land as one batch', (tester) async {
      await repository.createUser(
          username: 'kari', password: 'pw2', roleName: 'Shift Leader');
      await repository.upsertRole(
          const AccessRole(name: 'Unused', groups: {AccessGroup.operate}));

      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'update', {
          'username': 'kari',
          'field': 'roles',
          'roles': ['Maintenance', 'Shift Leader'],
        }),
        _proposal(-2, 'access_account', 'update', {
          'username': 'kari',
          'field': 'station_account',
          'station_account': true,
        }),
        _proposal(-3, 'access_role', 'update', {
          'name': 'Shift Leader',
          'field': 'groups',
          'groups': ['operate'],
        }),
        _proposal(-4, 'access_role', 'rename', {
          'name': 'Maintenance',
          'new_name': 'Fitters',
        }),
        _proposal(-5, 'access_role', 'delete', {'name': 'Unused'}),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      final kari = (await user('kari'))!;
      expect(AccessRepository.rolesOf(kari), ['Fitters', 'Shift Leader'],
          reason: 'the roles landed, then the rename carried kari across');
      expect(kari.stationAccount, isTrue);
      expect((await repository.role('Shift Leader'))!.groups,
          {AccessGroup.operate});
      expect(await roleNames(), isNot(contains('Unused')));
      expect(await roleNames(), isNot(contains('Maintenance')));
      expect(staged.rows.map((r) => r.itemKey), [
        'user.role',
        'user.station_account',
        'role.update',
        'role.rename',
        'role.delete',
      ]);
      expect(staged.rows.every((r) => r.origin == 'mcp'), isTrue);
      expect(staged.rows.every((r) => r.who == 'gudrun'), isTrue);
      expect(staged.proposals.accepted, [-1, -2, -3, -4, -5]);
    });

    testWidgets('a delete account lands and the trail keeps its rows',
        (tester) async {
      await repository.createUser(
          username: 'kari', password: 'pw2', roleName: 'Shift Leader');
      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'delete', {'username': 'kari'}),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await user('kari'), isNull);
      expect(staged.rows.single.itemKey, 'user.delete');
      expect(staged.rows.single.member, 'kari');
    });
  });

  // -------------------------------------------------------------------------
  group('the password is typed at the panel', () {
    testWidgets('a create account opens the dialog, and the account exists '
        'only after a password is typed', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'create', {
          'username': 'bjarni',
          'roles': ['Shift Leader', 'Maintenance'],
          'station_account': true,
          'reason': 'new shift',
        }),
      ]);
      expect(find.textContaining('You will be asked to type its password'),
          findsOneWidget);

      final commit = staged.commit!();
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessAdminProposalPasswordFieldKey), findsOneWidget);
      expect(await user('bjarni'), isNull,
          reason: 'nothing is written until the password is typed');

      // A mismatch is refused in place, in a fixed sentence.
      await tester.enterText(
          find.byKey(kAccessAdminProposalPasswordFieldKey), 'secret one');
      await tester.enterText(
          find.byKey(kAccessAdminProposalConfirmFieldKey), 'secret two');
      await tester.tap(find.byKey(kAccessAdminProposalSubmitKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessAdminProposalProblemKey), findsOneWidget);
      expect(await user('bjarni'), isNull);

      await tester.enterText(
          find.byKey(kAccessAdminProposalConfirmFieldKey), 'secret one');
      await tester.tap(find.byKey(kAccessAdminProposalSubmitKey));
      await tester.pumpAndSettle();
      await commit;
      await tester.pumpAndSettle();

      final bjarni = (await user('bjarni'))!;
      expect(AccessRepository.rolesOf(bjarni), ['Shift Leader', 'Maintenance']);
      expect(bjarni.stationAccount, isTrue);
      expect(bjarni.passwordHash, isNot(contains('secret')),
          reason: 'stored derived, never in the clear');

      expect(staged.rows.map((r) => r.itemKey),
          ['user.create', 'user.station_account']);
      expect(staged.rows.first.origin, 'mcp');
      expect(staged.rows.first.who, 'gudrun');
      expect(staged.rows.first.reason, 'new shift');
      for (final row in staged.rows) {
        expect('$row', isNot(contains('secret')));
        expect(row.oldValue ?? '', isNot(contains('secret')));
        expect(row.newValue ?? '', isNot(contains('secret')));
      }
      expect(staged.proposals.accepted, [-1]);
      expect(find.byKey(kAccessAdminProposalPasswordFieldKey), findsNothing);
    });

    testWidgets('cancelling the dialog leaves the proposal pending and writes '
        'nothing', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'create', {
          'username': 'bjarni',
          'roles': ['Operator'],
        }),
      ]);

      final commit = staged.commit!();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessAdminProposalCancelKey));
      await tester.pumpAndSettle();
      await commit;
      await tester.pumpAndSettle();

      expect(await user('bjarni'), isNull);
      expect(staged.rows, isEmpty);
      expect(staged.proposals.accepted, isEmpty);
      expect(staged.commit, isNotNull,
          reason: 'still pending, so Accept is still on offer');
      expect(find.byKey(kAccessAdminProposalsKey), findsOneWidget);
    });

    testWidgets('a password reset opens the dialog and rewrites the hash',
        (tester) async {
      await repository.createUser(
          username: 'kari', password: 'pw2', roleName: 'Shift Leader');
      final before = (await user('kari'))!.passwordHash;
      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'update', {
          'username': 'kari',
          'field': 'password',
        }),
      ]);

      final commit = staged.commit!();
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(kAccessAdminProposalPasswordFieldKey), 'fresh pass');
      await tester.enterText(
          find.byKey(kAccessAdminProposalConfirmFieldKey), 'fresh pass');
      await tester.tap(find.byKey(kAccessAdminProposalSubmitKey));
      await tester.pumpAndSettle();
      await commit;
      await tester.pumpAndSettle();

      final after = (await user('kari'))!.passwordHash;
      expect(after, isNot(before));
      expect(after, isNot(contains('fresh')));
      expect(staged.rows.single.itemKey, 'user.password');
      expect(staged.rows.single.oldValue, isNull);
      expect(staged.rows.single.newValue, isNull);
      expect(staged.rows.single.origin, 'mcp');
      expect(staged.proposals.accepted, [-1]);
    });
  });

  // -------------------------------------------------------------------------
  group('the refusals are decided at the accept', () {
    testWidgets('a held role is not deleted, and the rest of the batch lands',
        (tester) async {
      await repository.createUser(
          username: 'kari', password: 'pw2', roleName: 'Shift Leader');
      final staged = await stage(tester, [
        _proposal(-1, 'access_role', 'delete', {'name': 'Shift Leader'}),
        _proposal(-2, 'access_role', 'create', {
          'name': 'Cleaning',
          'groups': ['operate'],
        }),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await roleNames(), contains('Shift Leader'));
      expect(await roleNames(), contains('Cleaning'));
      expect(find.textContaining('RoleInUseException'), findsOneWidget,
          reason: 'the refusal names the holders, on screen');
      expect(find.textContaining('kari'), findsWidgets);
      expect(staged.proposals.accepted, [-2]);
      expect(staged.commit, isNotNull,
          reason: 'the blocked one is still pending');
      expect(staged.rows.map((r) => r.itemKey), ['role.create'],
          reason: 'a refused delete writes no row claiming it happened');
    });

    testWidgets('the last users holder cannot be deleted', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'delete', {'username': 'gudrun'}),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await user('gudrun'), isNotNull);
      expect(find.textContaining('LastUsersHolderException'), findsOneWidget);
      expect(staged.proposals.accepted, isEmpty);
      expect(staged.rows, isEmpty);
    });

    testWidgets('an approver without users is refused, and the refusal is '
        'recorded as theirs', (tester) async {
      session = _configureOnly();
      final staged = await stage(tester, [
        _proposal(-1, 'access_role', 'create', {
          'name': 'Cleaning',
          'groups': ['operate'],
        }),
      ]);

      await staged.commit!();
      await tester.pumpAndSettle();

      expect(await roleNames(), isNot(contains('Cleaning')));
      expect(staged.rows, hasLength(1));
      expect(staged.rows.single.allowed, isFalse);
      expect(staged.rows.single.who, 'engineer');
      expect(staged.rows.single.origin, 'mcp');
      expect(staged.proposals.accepted, isEmpty);
      expect(find.byType(AccessDeniedPrompt), findsOneWidget);
    });

    testWidgets('with no database nothing is staged', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_role', 'create', {
          'name': 'Cleaning',
          'groups': ['operate'],
        }),
      ], noDatabase: true);

      expect(staged.commit, isNull);
      expect(find.byKey(kAccessAdminProposalsKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('the rest of the section', () {
    testWidgets('reject drops the batch and writes nothing', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_role', 'create', {
          'name': 'Cleaning',
          'groups': ['operate'],
        }),
        _proposal(-2, 'access_account', 'delete', {'username': 'gudrun'}),
      ]);

      await staged.discard!();
      await tester.pumpAndSettle();

      expect(staged.proposals.rejected, [-1, -2]);
      expect(await roleNames(), isNot(contains('Cleaning')));
      expect(await user('gudrun'), isNotNull);
      expect(staged.rows, isEmpty);
      expect(staged.commit, isNull);
    });

    testWidgets('the card says what Accept will do, warnings included',
        (tester) async {
      await stage(tester, [
        _proposal(-1, 'access_role', 'delete', {
          'name': 'Engineering',
          'warnings': ['REFUSED AT THE ACCEPT: this would leave nobody'],
        }),
        _proposal(-2, 'access_account', 'update', {
          'username': kAnonymousUsername,
          'field': 'roles',
          'roles': ['Shift Leader'],
        }),
      ]);

      expect(find.text('Delete role "Engineering".'), findsOneWidget);
      expect(find.textContaining('REFUSED AT THE ACCEPT'), findsOneWidget);
      expect(find.textContaining('this is every logged-out panel'),
          findsOneWidget);
    });

    testWidgets('a malformed proposal is ignored, not staged', (tester) async {
      final staged = await stage(tester, [
        _proposal(-1, 'access_account', 'update', {
          'username': 'gudrun',
          'field': 'nonsense',
        }),
        _proposal(-2, 'access_role', 'create', {'name': 'NoGroups'}),
      ]);

      expect(staged.commit, isNull);
      expect(find.byKey(kAccessAdminProposalsKey), findsNothing);
    });
  });
}
