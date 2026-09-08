/// Arms about the access suite *itself*, and about the honest fake it is
/// measured against.
///
/// Every other access file judges an implementation. This one judges the suite:
/// that its check count is declared and reconciled, that every refusal arm has a
/// permission twin, and that the reference fake stores what it is told and hides
/// nothing on its own. A leg that silently ran half the suite, or a fake that
/// quietly dropped writes or refused by accident, would make every negative arm
/// in `access_contract.dart` pass against an implementation with no gate at all —
/// the exact defect this milestone has shipped twice (17-CONTEXT D-12).
@TestOn('vm')
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/testing/fake_access_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The number of checks the access family declares.
///
/// A literal, reconciled against the registry below, so a check added or lost
/// without updating this number fails here rather than drifting. The number is
/// the count nobody can read off a test-runner API from inside the file that
/// registers it.
///
/// Still 27 after the access audit cut `accessTemplates.template` from the
/// wire: the cut removed a *read* inside `checkTemplateReadsAreUngated` (four
/// ungated reads became three), not a check. Written down here so the next
/// reader knows the non-shift was a decision, not an oversight.
const _declaredAccessCheckCount = 27;

/// Tokens that mark a check name as asserting a refusal, and the tokens that
/// mark its permission twin. Exactly 17-CONTEXT D-12's pairing rule, mechanised.
const _refusalTokens = ['refuses', 'denies', 'hides', 'rejects'];
const _permissionTokens = [
  'permits',
  'permitted',
  'allows',
  'succeeds',
  'ungated',
];

void main() {
  group('the check count is declared and reconciled', () {
    test('accessChecks holds exactly the declared number', () {
      expect(accessChecks, hasLength(_declaredAccessCheckCount),
          reason: 'accessChecks holds ${accessChecks.length} checks but this '
              'file declares $_declaredAccessCheckCount. A leg that silently '
              'runs half the suite is the failure this whole kit exists to '
              'prevent; update the number here deliberately when you add a '
              'check, so the change is a decision and not a drift');
    });

    test('the access family is registered in the kit-wide accounting', () {
      // The gap list stays meaningful only if the family joins allContractChecks
      // rather than running beside it. This is arm 1 of the plan: a family the
      // umbrella forgets to count is a family that can silently skip.
      expect(contractRegistries.keys, contains('access'),
          reason: 'runAccessContract exists but contractRegistries has no '
              '"access" entry, so its checks are absent from allContractChecks '
              '— neither swept for deadlines by suite_integrity_test nor '
              'counted by the umbrella. suite_integrity_test also asserts '
              'contractRegistries.length equals the number of run…Contract '
              'functions, so this must be wired');
      expect(contractRegistries['access'], same(accessChecks),
          reason: 'the registry entry is not the accessChecks map itself, so '
              'the two can drift');
    });

    test('every access check is present in allContractChecks', () {
      for (final name in accessChecks.keys) {
        expect(allContractChecks.keys, contains(name),
            reason: '"$name" is an access check that did not survive the merge '
                'into allContractChecks — a name collision with another family '
                'silently kept only one of them');
      }
    });
  });

  group('every refusal check has a permission twin', () {
    test('no refusal-token check name lacks a permission token', () {
      final unpaired = <String>[];
      for (final name in accessChecks.keys) {
        final lower = name.toLowerCase();
        final isRefusal = _refusalTokens.any(lower.contains);
        if (!isRefusal) continue;
        final hasPermission = _permissionTokens.any(lower.contains);
        if (!hasPermission) unpaired.add(name);
      }
      expect(unpaired, isEmpty,
          reason: 'these checks assert a refusal with no permission twin, so '
              'each is satisfied vacuously by an implementation that refuses '
              'everything (D-12\'s blank-page defect):\n  ${unpaired.join('\n  ')}');
    });

    test('at least one permission-asserting check exists', () {
      // The other direction: a suite of pure refusals would pass the arm above
      // (nothing to pair) while judging nothing. There must be permission arms.
      final permitting = accessChecks.keys.where((name) =>
          _permissionTokens.any(name.toLowerCase().contains));
      expect(permitting, isNotEmpty,
          reason: 'no check asserts a permitted case; every negative arm in the '
              'suite would then be vacuous');
    });
  });

  group('the honest fake stores what it is told', () {
    late FakeAccessServices fake;
    setUp(() => fake = FakeAccessServices(session: usersSession));

    test('a created template is stored and read back', () async {
      final tpl = AccessTemplate(
          name: 't1', rules: const {kWholeKeyMember: AccessGroup.setpoints});
      await fake.create(tpl);
      // Read back the way a remote must since the access audit cut
      // `template(name)` from the wire: derive the one row from list().
      final back =
          (await fake.list()).where((t) => t.name == 't1').firstOrNull;
      expect(back?.name, 't1',
          reason: 'the template was created and does not read back');
    });

    test('a binding is stored and read back', () async {
      await fake.bind('ST101.CN01.MOT01', 't1');
      expect(await fake.bindings(), containsPair('ST101.CN01.MOT01', 't1'));
      expect(await fake.keysBoundTo('t1'), contains('ST101.CN01.MOT01'));
    });

    test('a created role is stored and read back', () async {
      await fake.createRole(
          AccessRole(name: 'R1', groups: {AccessGroup.operate}));
      expect((await fake.roles()).map((r) => r.name), contains('R1'));
    });

    test('a created user is stored, and its password is retained', () async {
      await fake.createUser(const NewUserParams(
          subject: 'u1', password: 'pw-1', grantedRole: 'Operator'));
      expect((await fake.listUsers()).map((u) => u.username), contains('u1'));
      expect(fake.storedPasswordFor('u1'), 'pw-1',
          reason: 'a fake that dropped the password would make the '
              'setUserPassword arms judge nothing');
    });

    test('a role move and a password reset are stored', () async {
      await fake.createUser(const NewUserParams(
          subject: 'u2', password: 'first', grantedRole: 'Operator'));
      await fake.setUserRole('u2', 'Supervisor');
      expect(
          (await fake.listUsers()).firstWhere((u) => u.username == 'u2').roleName,
          'Supervisor');
      await fake.setUserPassword(
          const SetUserPasswordParams(subject: 'u2', password: 'second'));
      expect(fake.storedPasswordFor('u2'), 'second');
    });

    test('a backend config write is stored and read back', () async {
      // Config is graded administer; the shared setUp session holds users, so
      // this arm speaks as a session that holds everything.
      fake.actAs(AccessSession(groups: AccessGroup.values.toSet()));
      final live = await fake.read();
      final edited = live.configJson
          .replaceFirst(RegExp(r'"sources":\{[^}]*\}'), '"sources":{"X":"y"}');
      await fake.write(edited);
      expect((await fake.read()).configJson, edited);
    });

    test('every store touch is recorded', () async {
      final before = fake.writes.length;
      await fake.create(AccessTemplate(
          name: 'rec', rules: const {kWholeKeyMember: AccessGroup.setpoints}));
      expect(fake.writes.length, greaterThan(before),
          reason: 'the recording lever is the whole basis of the pre-effect '
              'arms; if it does not grow on a real write, "the store was not '
              'touched" means nothing');
    });
  });

  group('the honest fake hides nothing on its own', () {
    test('with every group, no gated member refuses', () async {
      final fake = FakeAccessServices(
          session: AccessSession(groups: AccessGroup.values.toSet()));

      // Every gated mutator, run under a session holding everything. A fake
      // that refused by accident would make the suite's negative arms pass
      // against an implementation that has no gate at all — the defect
      // `_HidesTags` had one layer up.
      await fake.create(AccessTemplate(
          name: 'h', rules: const {kWholeKeyMember: AccessGroup.setpoints}));
      await fake.update(AccessTemplate(
          name: 'h', rules: const {kWholeKeyMember: AccessGroup.device}));
      await fake.bind('k1', 'h');
      await fake.rename('h', 'h2');
      await fake.unbind('k1');
      await fake.createRole(AccessRole(name: 'HR', groups: {AccessGroup.operate}));
      await fake.updateRole(
          AccessRole(name: 'HR', groups: {AccessGroup.operate, AccessGroup.setpoints}));
      await fake.renameRole('HR', 'HR2');
      await fake.deleteRole('HR2');
      await fake.createUser(const NewUserParams(
          subject: 'hu', password: 'p', grantedRole: 'Operator'));
      await fake.setUserRole('hu', 'Supervisor');
      await fake.setUserStationAccount('hu', true);
      await fake.setUserPassword(
          const SetUserPasswordParams(subject: 'hu', password: 'p2'));
      await fake.deleteUser('hu');

      final live = await fake.read();
      final edited = live.configJson
          .replaceFirst(RegExp(r'"sources":\{[^}]*\}'), '"sources":{"a":"b"}');
      await fake.write(edited);
      await fake.previous();
      await fake.restorePrevious();

      // No expectation of a throw anywhere above; reaching here is the assertion.
      expect(true, isTrue);
    });

    test('the audit trail really grows a row per decision', () async {
      final fake = FakeAccessServices(
          session: AccessSession(groups: AccessGroup.values.toSet()));
      final before = (await fake.entries(const AuditQueryParams())).length;
      await fake.create(AccessTemplate(
          name: 'a', rules: const {kWholeKeyMember: AccessGroup.setpoints}));
      final after = (await fake.entries(const AuditQueryParams())).length;
      expect(after, greaterThan(before),
          reason: 'a decision was made and the trail did not grow, so the '
              'audit arms judge nothing');
    });
  });

  // The in-memory leg: the whole access contract, run against a FakeStateMan
  // whose four families are the reference implementation. Task 3 adds the
  // channel leg; harness_parity_test.dart then proves the two agree.
  runAccessContract(FakeStateMan.new, supportsAccessControl: true);
}
