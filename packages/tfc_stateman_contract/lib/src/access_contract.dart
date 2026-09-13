/// The shared judgement of the four access families, on any `StateManApi`, on
/// any leg.
///
/// This is the fifth instance of a pattern this repository has run four times —
/// `runSubscribeContract`, `runWriteContract`, `runBrowseContract`,
/// `runDataServicesContract` — and it registers the same way, merges into the
/// same `allContractChecks`, and is swept for deadlines by the same
/// `suite_integrity_test.dart`. What is different is what it judges. A
/// data-service check asks *did the right rows come back*. An access check asks
/// *was the wrong thing refused* — and a refusal is the easiest assertion there
/// is to satisfy by accident:
///
///  * a gate that throws **after** touching the store refuses just as visibly as
///    one that throws before;
///  * an implementation that refuses **everything** passes every refusal arm;
///  * an arm asserting "this was refused" passes vacuously if the method was
///    never reachable at all.
///
/// So every negative check here is **paired, structurally**, and the pairing is
/// a rule of the file rather than a habit:
///
///  1. one arm asserts the refusal (`... refuses ...`),
///  2. one asserts a permitted neighbour still succeeds,
///  3. where a store is involved, a recording fake asserts the store was **not
///     touched** by the refusal — [StateManAccessHarness.accessStoreWrites], the
///     `_RecordingPreferences` lever (`policy_test.dart:355`) generalised.
///
/// `access_contract_meta_test.dart` enforces (1)-and-(2) mechanically: it walks
/// the check names and fails if any name matching a refusal pattern has no
/// permission twin.
///
/// ## The session lever, and why the signature is not `Function(AccessSession)`
///
/// The point of the access surface is that the **same implementation answers
/// differently to different sessions**. In production a session is fixed per
/// connection (a role change closes it, D-08). A contract check cannot fix the
/// session at construction, though: it receives one `StateManApi` from the
/// kit's `StateManApi Function()` factory — the shape every other runner takes,
/// the shape `suite_integrity_test.dart` and `harness_parity_test.dart` sweep,
/// the shape merged into `allContractChecks`. So the session is swapped through
/// a **test-only lever**, [StateManAccessHarness.actAs], in exactly the lane
/// `setValue` and `failNextWrite` travel: off the wire, ordered, applied before
/// the request that follows it. A single check then exercises a refusal under
/// one session and its permitted twin under another, on one live instance —
/// which is the property, stated as a lever rather than as a constructor
/// argument. The kit's `Check<StateManApi>` shape is preserved, and with it
/// every accounting and anti-hang guarantee the other seven families already
/// have.
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';

// -----------------------------------------------------------------------------
// The test-only control surface
// -----------------------------------------------------------------------------

/// The lever the access contract drives, exactly as `StateManWriteHarness` is
/// the one the write contract drives.
///
/// Two members, and both are off the wire for the reason `harness.dart` gives
/// about every lever: a method that exists on `StateManApi` is a thing any
/// connected client may invoke, so a session-swap or a store-touch readout on
/// the wire surface would be an access-control decision, not a testing
/// convenience.
abstract interface class StateManAccessHarness {
  /// Swaps the session the four access families consult from now on.
  void actAs(AccessSession session);

  /// Every store mutation the access families have performed, in order, by name.
  ///
  /// The recording lever: a refusal must leave this unchanged, which is what
  /// turns "the write was refused" from a claim into a pre-effect one.
  List<String> get accessStoreWrites;

  /// The password stored for [subject], for the control that a permitted
  /// `setUserPassword` really happened. Never a wire member — the wire has none.
  String? storedPasswordFor(String subject);
}

/// The [StateManAccessHarness] side of [api], or a failure naming what is
/// missing — the same bargain `harnessOf` and `dataHarnessOf` strike.
StateManAccessHarness accessHarnessOf(StateManApi api) {
  if (api is StateManAccessHarness) return api as StateManAccessHarness;
  fail('${api.runtimeType} does not implement StateManAccessHarness, so no '
      'access case can put a session in front of it. An implementation under '
      'test must expose the test-only session lever (actAs) and the recording '
      'readout (accessStoreWrites) declared in package:tfc_stateman_contract — '
      'the session is swapped through a lever, off the wire, because a client '
      'that could name its own session could name a session it does not hold.');
}

// -----------------------------------------------------------------------------
// The sessions every check speaks in
// -----------------------------------------------------------------------------

/// A session holding exactly [groups].
AccessSession _sessionOf(Set<AccessGroup> groups) =>
    AccessSession(groups: groups);

/// Holds `users`: may administer templates and roles. Also holds `operate` so
/// it is never mistaken for an all-or-nothing session.
final AccessSession usersSession =
    _sessionOf({AccessGroup.users, AccessGroup.operate});

/// Holds `administer`: may edit the backend's config. Deliberately NOT `users`,
/// so it is refused templates and roles.
final AccessSession administerSession = _sessionOf({AccessGroup.administer});

/// Holds `configure` only: may do none of the four families. The neighbour that
/// proves a refusal is about the group and not about the session being empty.
final AccessSession configureSession = _sessionOf({AccessGroup.configure});

/// Every group. Against this, nothing gated refuses — the anti-vacuity control
/// for the whole suite (arm 4 of the meta test).
final AccessSession everyGroupSession =
    _sessionOf(AccessGroup.values.toSet());

// -----------------------------------------------------------------------------
// Fixtures the checks build and read back
// -----------------------------------------------------------------------------

AccessTemplate _template(String name) => AccessTemplate(
    name: name, rules: const {kWholeKeyMember: AccessGroup.setpoints});

AccessRole _role(String name, Set<AccessGroup> groups) =>
    AccessRole(name: name, groups: groups);

/// Runs [body] and returns whatever it threw, or null when it did not throw.
Future<Object?> _thrown(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (error) {
    return error;
  }
}

/// Awaits a setup step under a deadline, so a check hangs on **nothing**.
///
/// Every await against the implementation goes through [within] — the actions
/// under test through `_refusedThenPermitted` and `_expectNoThrow`, the seeding
/// steps through this. Against a source that answers nothing
/// (`NeverResponds`), an unbounded seed would hang the whole check and the
/// no-hang sweep in `suite_integrity_test.dart` exists to forbid exactly that.
Future<T> _seed<T>(Future<T> Function() f, String what) =>
    within(f(), 'seeding $what');

/// Asserts [action] is refused for [denied] and permitted for [permitted], with
/// the store untouched by the refusal and changed by the permission.
///
/// The one shape every gated write-check takes, so the three-part rule is
/// written once and every check that uses it inherits all three halves: the
/// refusal is an [AccessDenied], the store did not move under it, and the
/// permitted twin both succeeds and moves the store.
Future<void> _refusedThenPermitted(
  StateManApi api, {
  required AccessSession denied,
  required AccessSession permitted,
  required String what,
  required Future<void> Function() action,
}) async {
  final h = accessHarnessOf(api);

  h.actAs(denied);
  final before = h.accessStoreWrites.length;
  final refusal = await within(_thrown(action), '$what being refused');
  expect(refusal, isA<AccessDenied>(),
      reason: '$what was performed by a session that lacks the group it '
          'requires, and the refusal came back as ${refusal.runtimeType} '
          'instead of AccessDenied: $refusal');
  expect(h.accessStoreWrites.length, before,
      reason: '$what was refused but the store grew from $before to '
          '${h.accessStoreWrites.length} entries. A gate that throws AFTER '
          'touching the store refuses just as visibly as one that throws '
          'before, and only this half can tell them apart — the write reached '
          'the plant and the operator was told it did not');

  h.actAs(permitted);
  final beforePermit = h.accessStoreWrites.length;
  final permitError = await within(_thrown(action), '$what being permitted');
  expect(permitError, isNull,
      reason: '$what was refused for a session holding the required group: '
          '$permitError. If the permitted twin cannot succeed, the refusal '
          'above proves nothing — an implementation that refused everyone would '
          'pass it');
  expect(h.accessStoreWrites.length, greaterThan(beforePermit),
      reason: '$what was permitted but the store did not move, so the '
          '"permitted" arm is satisfied by a no-op and the refusal it is '
          'paired with is judging nothing');
}

// -----------------------------------------------------------------------------
// Templates (AccessGroup.users)
// -----------------------------------------------------------------------------

Future<void> checkTemplateCreateRefusesConfigurePermitsUsers(
        StateManApi api) async =>
    _refusedThenPermitted(api,
        denied: configureSession,
        permitted: usersSession,
        what: 'creating an access template',
        action: () => api.accessTemplates.create(_template('conveyor-1')));

Future<void> checkTemplateUpdateRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.create(_template('conveyor-2')), 'conveyor-2');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'updating an access template',
      action: () => api.accessTemplates.update(_template('conveyor-2')));
}

Future<void> checkTemplateRenameRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.create(_template('conveyor-3')), 'conveyor-3');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'renaming an access template',
      action: () =>
          api.accessTemplates.rename('conveyor-3', 'conveyor-3-renamed'));
}

Future<void> checkTemplateDeleteRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.create(_template('conveyor-4')), 'conveyor-4');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'deleting an access template',
      action: () => api.accessTemplates.delete('conveyor-4'));
}

Future<void> checkTemplateBindRefusesConfigurePermitsUsers(
        StateManApi api) async =>
    _refusedThenPermitted(api,
        denied: configureSession,
        permitted: usersSession,
        what: 'binding a key to a template',
        action: () =>
            api.accessTemplates.bind('ST101.CN01.MOT01', 'conveyor-1'));

Future<void> checkTemplateUnbindRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.bind('ST101.CN02.MOT01', 'conveyor-1'), 'a bound key');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'unbinding a key from a template',
      action: () => api.accessTemplates.unbind('ST101.CN02.MOT01'));
}

/// The three template reads are ungated (spec §11) — they succeed for a session
/// holding nothing about templates, and the check SAYS so rather than leaving a
/// reader to infer it from an absence.
///
/// There were four: `template(name)` was cut from the wire by the access audit
/// (no caller anywhere, including its own store). A remote that wants one
/// template derives it from `list()` — the capability's shape survives as a
/// derivation, not as a wire member, so there is nothing here to judge.
Future<void> checkTemplateReadsAreUngated(StateManApi api) async {
  final h = accessHarnessOf(api);
  // Seed one template with a users session so the reads have something to find.
  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.create(_template('conveyor-r')), 'conveyor-r');
  await _seed(() => api.accessTemplates.bind('ST101.CN01.SEN01', 'conveyor-r'), 'a bound key');

  for (final reader in <AccessSession>[configureSession, usersSession]) {
    h.actAs(reader);
    await within(_expectNoThrow(() => api.accessTemplates.list()),
        'list() for ${reader.roleName}');
    await within(_expectNoThrow(() => api.accessTemplates.bindings()),
        'bindings() for ${reader.roleName}');
    await within(
        _expectNoThrow(() => api.accessTemplates.keysBoundTo('conveyor-r')),
        'keysBoundTo() for ${reader.roleName}');
  }
  final keys = await within(api.accessTemplates.keysBoundTo('conveyor-r'), 'keysBoundTo');
  expect(keys, contains('ST101.CN01.SEN01'),
      reason: 'the reads are ungated, but they must still ANSWER: keysBoundTo '
          'came back $keys, so the "ungated" arm was passing against a reader '
          'that returns nothing for everyone');
}

/// A bound template's delete throws a domain error BEFORE the permission check
/// is relevant — asserted with a `users` session so the domain rule and the
/// permission rule are not conflated. Its anti-vacuity half deletes an
/// **unbound** template successfully with the same session.
Future<void> checkBoundTemplateDeleteIsADomainRefusalNotAPermissionOne(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.create(_template('bound-tpl')), 'bound-tpl');
  await _seed(() => api.accessTemplates.bind('ST201.CN04.MOT01', 'bound-tpl'), 'a bound key');

  final refusal = await within(
      _thrown(() => api.accessTemplates.delete('bound-tpl')),
      'deleting a bound template');
  expect(refusal, isNotNull,
      reason: 'a bound template was deleted with no complaint; the keys that '
          'pointed at it are now unscoped');
  expect(refusal, isNot(isA<AccessDenied>()),
      reason: 'a bound template deleted by a users session came back as '
          'AccessDenied ($refusal). That conflates "you may not" with "you '
          'cannot yet": the session WAS allowed, the domain rule refused. A '
          'reader of the trail cannot tell a permission failure from a data '
          'one if they arrive as the same type');

  // Anti-vacuity: the same session deletes an UNBOUND template fine, so the
  // refusal above is about the binding and not about delete being broken.
  await _seed(() => api.accessTemplates.create(_template('unbound-tpl')), 'unbound-tpl');
  await within(_expectNoThrow(() => api.accessTemplates.delete('unbound-tpl')),
      'deleting an unbound template');
}

// -----------------------------------------------------------------------------
// Roles and users (AccessGroup.users)
// -----------------------------------------------------------------------------

Future<void> checkCreateRoleRefusesConfigurePermitsUsers(
        StateManApi api) async =>
    _refusedThenPermitted(api,
        denied: configureSession,
        permitted: usersSession,
        what: 'creating a role',
        action: () =>
            api.accessAdmin.createRole(_role('Line Lead', {AccessGroup.operate})));

Future<void> checkUpdateRoleRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createRole(_role('Shift Lead', {AccessGroup.operate})), 'Shift Lead');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'updating a role',
      action: () => api.accessAdmin
          .updateRole(_role('Shift Lead', {AccessGroup.operate, AccessGroup.setpoints})));
}

Future<void> checkDeleteRoleRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createRole(_role('Temp Role', {AccessGroup.operate})), 'Temp Role');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'deleting a role',
      action: () => api.accessAdmin.deleteRole('Temp Role'));
}

Future<void> checkRenameRoleRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createRole(_role('Old Name', {AccessGroup.operate})), 'Old Name');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'renaming a role',
      action: () => api.accessAdmin.renameRole('Old Name', 'New Name'));
}

Future<void> checkCreateUserRefusesConfigurePermitsUsers(
        StateManApi api) async =>
    _refusedThenPermitted(api,
        denied: configureSession,
        permitted: usersSession,
        what: 'creating a user',
        action: () => api.accessAdmin.createUser(const NewUserParams(
            subject: 'stjornandi', password: 'hunang-123', grantedRole: 'Operator')));

Future<void> checkDeleteUserRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createUser(const NewUserParams(
      subject: 'til-eydingar', password: 'x-9', grantedRole: 'Operator')), 'til-eydingar');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'deleting a user',
      action: () => api.accessAdmin.deleteUser('til-eydingar'));
}

Future<void> checkSetUserRoleRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createUser(const NewUserParams(
      subject: 'faerslu', password: 'x-9', grantedRole: 'Operator')), 'faerslu');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'moving a user onto a role',
      action: () => api.accessAdmin.setUserRole('faerslu', 'Supervisor'));
}

Future<void> checkSetUserStationAccountRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createUser(const NewUserParams(
      subject: 'stodvar', password: 'x-9', grantedRole: 'Operator')), 'stodvar');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'flipping a station-account flag',
      action: () => api.accessAdmin.setUserStationAccount('stodvar', true));
}

/// The page whitelist is `users`, not `configure` — the whole reason it lives
/// on the admin surface.
///
/// A whitelist behind the page editor's gate would let anybody who can author
/// a page re-scope who sees which pages, including widening their own view.
/// These two checks are what stop a leg from grading it `configure` quietly.
Future<void> checkSetRolePagesRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(
      () => api.accessAdmin.createRole(
          const AccessRole(name: 'Sidur', groups: {AccessGroup.operate})),
      'Sidur');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'setting a role page whitelist',
      action: () => api.accessAdmin.setRolePages('Sidur', {'/fillet'}));
}

/// And the account level, whose null clears the override rather than granting
/// every page — so this check deliberately passes a non-null set and leaves
/// the null-versus-empty distinction to the codec's own tests.
Future<void> checkSetUserPagesRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(
      () => api.accessAdmin.createUser(const NewUserParams(
          subject: 'sidumadur', password: 'x-9', grantedRole: 'Operator')),
      'sidumadur');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'setting an account page whitelist',
      action: () => api.accessAdmin.setUserPages('sidumadur', {'/fillet'}));
}

Future<void> checkSetUserPasswordRefusesConfigurePermitsUsers(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createUser(const NewUserParams(
      subject: 'lykilord', password: 'first-pass', grantedRole: 'Operator')), 'lykilord');
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: usersSession,
      what: 'resetting a password',
      action: () => api.accessAdmin.setUserPassword(
          const SetUserPasswordParams(subject: 'lykilord', password: 'second-pass')));
}

/// The two admin reads are ungated and must ANSWER.
Future<void> checkAdminReadsAreUngated(StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createRole(_role('Read Probe', {AccessGroup.operate})), 'Read Probe');
  await _seed(() => api.accessAdmin.createUser(const NewUserParams(
      subject: 'read-probe-user', password: 'x-9', grantedRole: 'Read Probe')), 'read-probe-user');

  for (final reader in <AccessSession>[configureSession, usersSession]) {
    h.actAs(reader);
    await within(_expectNoThrow(() => api.accessAdmin.roles()),
        'roles() for ${reader.roleName}');
    await within(_expectNoThrow(() => api.accessAdmin.listUsers()),
        'listUsers() for ${reader.roleName}');
  }
  final roles = await within(api.accessAdmin.roles(), 'roles()');
  expect(roles.map((r) => r.name), contains('Read Probe'),
      reason: 'roles() is ungated but must still answer: it came back without '
          'the role just created, so the "ungated" arm was passing against a '
          'reader that returns nothing');
}

/// Deleting the last role holding `users` is refused for a `users` session — a
/// domain invariant, not a permission. The anti-vacuity half deletes a
/// non-last `users`-holder successfully.
Future<void> checkLastUsersHolderDeleteIsRefusedAsADomainRule(
    StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  await _seed(() => api.accessAdmin.createRole(_role('Sole Admin', {AccessGroup.users})), 'Sole Admin');

  final refusal = await within(
      _thrown(() => api.accessAdmin.deleteRole('Sole Admin')),
      'deleting the last users-holding role');
  expect(refusal, isNotNull,
      reason: 'the last role granting users was deleted; nobody can administer '
          'roles now and nobody can grant that back');
  expect(refusal, isNot(isA<AccessDenied>()),
      reason: 'the last-users-holder refusal came back as AccessDenied '
          '($refusal), which reads as "this session may not" rather than as '
          '"no session may": the session held users');

  // Anti-vacuity: with a SECOND users-holder present, deleting one succeeds.
  await _seed(() => api.accessAdmin.createRole(_role('Second Admin', {AccessGroup.users})), 'Second Admin');
  await within(_expectNoThrow(() => api.accessAdmin.deleteRole('Second Admin')),
      'deleting a non-last users-holder');
}

/// `setUserPassword` never returns the password and never echoes it in an error
/// message. One check, no twin: it is an absence assertion, and its anti-vacuity
/// half is that the call **succeeded** — so the absence is not the absence of a
/// result.
Future<void> checkSetUserPasswordDoesNotEchoTheSecret(StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(usersSession);
  const secret = 'super-secret-value-7Z';
  await _seed(() => api.accessAdmin.createUser(const NewUserParams(
      subject: 'echo-probe', password: 'initial', grantedRole: 'Operator')), 'echo-probe');

  // The anti-vacuity half: the call succeeds, so the absence below is the
  // absence of an echo, not the absence of an effect.
  final error = await within(
      _thrown(() => api.accessAdmin.setUserPassword(
          const SetUserPasswordParams(subject: 'echo-probe', password: secret))),
      'resetting a password');
  expect(error, isNull,
      reason: 'setUserPassword threw for a users session ($error); the '
          'no-echo arm below would then be vacuous, satisfied by a call that '
          'never ran');

  expect(h.storedPasswordFor('echo-probe'), secret,
      reason: 'the password did not reach the store, so this check is judging '
          'a write that did not happen');

  // Now provoke a failure and assert the secret is nowhere in its text.
  h.actAs(configureSession);
  final refusal = await within(
      _thrown(() => api.accessAdmin.setUserPassword(
          const SetUserPasswordParams(subject: 'echo-probe', password: secret))),
      'a refused password reset');
  expect('$refusal', isNot(contains(secret)),
      reason: 'the password appeared in the refusal message: "$refusal". A '
          'toString that reaches a log file is a credential that outlives the '
          'database it was set in');
}

// -----------------------------------------------------------------------------
// Audit (read-only, ungated)
// -----------------------------------------------------------------------------

/// The three audit reads succeed for a session holding nothing — read
/// permissions are deferred (spec §11) and the check says so.
Future<void> checkAuditReadsAreUngated(StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(_sessionOf(const {}));
  await within(
      _expectNoThrow(() => api.audit.entries(const AuditQueryParams())),
      'entries() for a session holding nothing');
  await within(
      _expectNoThrow(() => api.audit.memberCountsByAction(const [])),
      'memberCountsByAction() for a session holding nothing');
  await within(_expectNoThrow(() => api.audit.distinctWho()),
      'distinctWho() for a session holding nothing');
}

/// Every decision the access families make lands a row in the trail — the
/// property damage mode (d) reddens. A permitted create and a refused create are
/// both recorded; the check reads them back.
Future<void> checkAuditRecordsEveryDecision(StateManApi api) async {
  final h = accessHarnessOf(api);
  final before =
      (await within(api.audit.entries(const AuditQueryParams()), 'audit before')).length;

  h.actAs(usersSession);
  await _seed(() => api.accessTemplates.create(_template('audited-allow')), 'audited-allow');
  h.actAs(configureSession);
  await _thrown(() => api.accessTemplates.create(_template('audited-deny')));

  final after = await within(api.audit.entries(const AuditQueryParams()), 'audit after');
  expect(after.length, greaterThanOrEqualTo(before + 2),
      reason: 'two decisions were made — one allowed, one refused — and the '
          'trail grew by ${after.length - before}. A trail that stops '
          'recording is worse than no trail: it looks like nothing happened');

  final allowedRows =
      await within(api.audit.entries(const AuditQueryParams(allowed: true)), 'allowed rows');
  final refusedRows =
      await within(api.audit.entries(const AuditQueryParams(allowed: false)), 'refused rows');
  expect(allowedRows, isNotEmpty,
      reason: 'no allowed decision was recorded, so the trail cannot show that '
          'a permitted write ever happened');
  expect(refusedRows, isNotEmpty,
      reason: 'no REFUSED decision was recorded — the one kind of guard nobody '
          'can audit afterwards (AccessAdminStore\'s reasoning)');
}

// -----------------------------------------------------------------------------
// Backend config (AccessGroup.administer)
// -----------------------------------------------------------------------------

/// The current live config's `relay` section, unchanged, plus one edited
/// non-relay section — an acceptable payload for the write twin.
Future<String> _acceptableConfigEdit(StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(everyGroupSession);
  final live = await within(api.backendConfig.read(), 'reading live config');
  // Keep relay identical; append/replace a non-relay section. String surgery is
  // enough for the fake's canonical comparison, which only cares that relay is
  // untouched.
  final decoded = live.configJson;
  return decoded.replaceFirst(
      RegExp(r'"sources":\{[^}]*\}'), '"sources":{"ST101":"opc.tcp://changed"}');
}

Future<void> checkConfigReadRefusesConfigurePermitsAdminister(
    StateManApi api) async {
  final h = accessHarnessOf(api);

  h.actAs(configureSession);
  final refusal = await within(
      _thrown(() => api.backendConfig.read()), 'reading the backend config');
  expect(refusal, isA<AccessDenied>(),
      reason: 'config.read is graded administer and a configure session read '
          'it anyway ($refusal)');

  h.actAs(administerSession);
  await within(_expectNoThrow(() => api.backendConfig.read()),
      'reading the backend config as administer');
}

Future<void> checkConfigWriteRefusesConfigurePermitsAdminister(
    StateManApi api) async {
  final edit = await _acceptableConfigEdit(api);
  await _refusedThenPermitted(api,
      denied: configureSession,
      permitted: administerSession,
      what: 'writing the backend config',
      action: () => api.backendConfig.write(edit));
}

/// A payload that does not parse is refused for an `administer` session and the
/// store is untouched — validation before persistence, D-10's first hazard. Not
/// an [AccessDenied]: the session was allowed, the payload was not.
Future<void> checkConfigWriteValidatesBeforePersisting(StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(administerSession);
  final before = h.accessStoreWrites.length;

  final refusal = await within(
      _thrown(() => api.backendConfig.write('{ this is not json')),
      'writing an unparseable config');
  expect(refusal, isNotNull,
      reason: 'an unparseable configuration was written with no complaint; the '
          'backend may not come back from it');
  expect(refusal, isNot(isA<AccessDenied>()),
      reason: 'a bad payload from an administer session came back as '
          'AccessDenied ($refusal); the session was allowed, so this is a '
          'validation refusal wearing a permission refusal\'s clothes');
  expect(h.accessStoreWrites.length, before,
      reason: 'the unparseable config was refused but the store moved from '
          '$before to ${h.accessStoreWrites.length}: it was validated AFTER '
          'being written, which is the backend already broken');

  // Anti-vacuity: a well-formed edit from the same session is accepted.
  final edit = await _acceptableConfigEdit(api);
  h.actAs(administerSession);
  await within(_expectNoThrow(() => api.backendConfig.write(edit)),
      'writing a valid config edit');
}

/// A payload whose `relay` section differs is refused for an `administer`
/// session, by name — D-10's second hazard. Store untouched; not an
/// [AccessDenied].
Future<void> checkConfigWriteRefusesRelaySectionEdit(StateManApi api) async {
  final h = accessHarnessOf(api);
  h.actAs(everyGroupSession);
  final doc = await within(api.backendConfig.read(), 'reading live config');
  h.actAs(administerSession);
  final live = doc.configJson;
  final relayEdited =
      live.replaceFirst(RegExp(r'"port":\d+'), '"port":9999');
  expect(relayEdited, isNot(live),
      reason: 'the relay-edit fixture did not actually change the relay '
          'section, so this check is about to prove nothing');

  final before = h.accessStoreWrites.length;
  final refusal = await within(
      _thrown(() => api.backendConfig.write(relayEdited)),
      'writing a relay-section edit');
  expect(refusal, isNotNull,
      reason: 'the relay section — the socket this edit arrives on — was '
          'rewritten over the wire with no complaint; the editor can cut '
          'itself off');
  expect(refusal, isNot(isA<AccessDenied>()),
      reason: 'the relay-lock refusal came back as AccessDenied ($refusal); '
          'the administer session was allowed, the section is what is locked');
  expect(h.accessStoreWrites.length, before,
      reason: 'the relay edit was refused but the store moved anyway');
}

/// `previous` and `restorePrevious` follow `write`'s gating.
Future<void> checkConfigPreviousAndRestoreFollowWriteGating(
    StateManApi api) async {
  final edit = await _acceptableConfigEdit(api);
  final h = accessHarnessOf(api);

  // Make a previous to exist.
  h.actAs(administerSession);
  await _seed(() => api.backendConfig.write(edit), 'a config write');

  h.actAs(configureSession);
  final prevRefusal = await within(
      _thrown(() => api.backendConfig.previous()), 'reading the previous config');
  expect(prevRefusal, isA<AccessDenied>(),
      reason: 'config.previous is graded administer and configure read it '
          '($prevRefusal)');
  final restoreRefusal = await within(
      _thrown(() => api.backendConfig.restorePrevious()),
      'restoring the previous config');
  expect(restoreRefusal, isA<AccessDenied>(),
      reason: 'config.restorePrevious is graded administer and configure ran '
          'it ($restoreRefusal)');

  // The permitted twins.
  h.actAs(administerSession);
  await within(_expectNoThrow(() => api.backendConfig.previous()),
      'reading the previous config as administer');
  await within(_expectNoThrow(() => api.backendConfig.restorePrevious()),
      'restoring the previous config as administer');
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Runs [body] under a deadline and fails if it throws — the positive half of a
/// pairing, written so the failure names the operation rather than surfacing a
/// raw error, and bounded so it fails rather than hangs against a dead source.
Future<void> _expectNoThrow(Future<void> Function() body) async {
  final error = await _thrown(() => within(body(), 'a permitted call'));
  expect(error, isNull, reason: 'expected success, got: $error');
}

// -----------------------------------------------------------------------------
// The registry and the runner
// -----------------------------------------------------------------------------

/// Every access check, keyed by the property it asserts.
///
/// A merge into `allContractChecks` (`tfc_stateman_contract.dart`), so a
/// sentence used twice would collapse two checks into one — the silent loss
/// `suite_integrity_test.dart` forbids.
const accessChecks = <String, Check<StateManApi>>{
  // templates
  'creating a template refuses a configure session and permits a users one':
      checkTemplateCreateRefusesConfigurePermitsUsers,
  'updating a template refuses configure and permits users':
      checkTemplateUpdateRefusesConfigurePermitsUsers,
  'renaming a template refuses configure and permits users':
      checkTemplateRenameRefusesConfigurePermitsUsers,
  'deleting a template refuses configure and permits users':
      checkTemplateDeleteRefusesConfigurePermitsUsers,
  'binding a key refuses configure and permits users':
      checkTemplateBindRefusesConfigurePermitsUsers,
  'unbinding a key refuses configure and permits users':
      checkTemplateUnbindRefusesConfigurePermitsUsers,
  'the template reads are ungated and still answer':
      checkTemplateReadsAreUngated,
  'a bound template delete is a domain refusal, not a permission one':
      checkBoundTemplateDeleteIsADomainRefusalNotAPermissionOne,
  // roles and users
  'creating a role refuses configure and permits users':
      checkCreateRoleRefusesConfigurePermitsUsers,
  'updating a role refuses configure and permits users':
      checkUpdateRoleRefusesConfigurePermitsUsers,
  'deleting a role refuses configure and permits users':
      checkDeleteRoleRefusesConfigurePermitsUsers,
  'renaming a role refuses configure and permits users':
      checkRenameRoleRefusesConfigurePermitsUsers,
  'creating a user refuses configure and permits users':
      checkCreateUserRefusesConfigurePermitsUsers,
  'deleting a user refuses configure and permits users':
      checkDeleteUserRefusesConfigurePermitsUsers,
  'moving a user onto a role refuses configure and permits users':
      checkSetUserRoleRefusesConfigurePermitsUsers,
  'flipping a station-account flag refuses configure and permits users':
      checkSetUserStationAccountRefusesConfigurePermitsUsers,
  'setting a role page whitelist refuses configure and permits users':
      checkSetRolePagesRefusesConfigurePermitsUsers,
  'setting an account page whitelist refuses configure and permits users':
      checkSetUserPagesRefusesConfigurePermitsUsers,
  'resetting a password refuses configure and permits users':
      checkSetUserPasswordRefusesConfigurePermitsUsers,
  'the admin reads are ungated and still answer': checkAdminReadsAreUngated,
  'deleting the last users-holding role is refused as a domain rule':
      checkLastUsersHolderDeleteIsRefusedAsADomainRule,
  'setUserPassword never echoes the secret and still succeeds':
      checkSetUserPasswordDoesNotEchoTheSecret,
  // audit
  'the audit reads are ungated': checkAuditReadsAreUngated,
  'the audit trail records every decision, allowed and refused':
      checkAuditRecordsEveryDecision,
  // backend config
  'reading the backend config refuses configure and permits administer':
      checkConfigReadRefusesConfigurePermitsAdminister,
  'writing the backend config refuses configure and permits administer':
      checkConfigWriteRefusesConfigurePermitsAdminister,
  'the backend config is validated before it is persisted':
      checkConfigWriteValidatesBeforePersisting,
  'a relay-section edit is refused by name': checkConfigWriteRefusesRelaySectionEdit,
  'previous and restorePrevious follow write\'s gating':
      checkConfigPreviousAndRestoreFollowWriteGating,
};

/// Registers the access contract against implementations from [make].
///
/// [supportsAccessControl] `false` skips the group with a reason on the record
/// rather than passing it vacuously — a source with no access surface behind it
/// is then visible in the run report instead of absent from it. It defaults
/// **false**: most implementations of `StateManApi` are not access-serving, so
/// the umbrella opts them out by default and an access-serving leg opts in,
/// exactly as `supportsDataServices` gates the historian.
void runAccessContract(
  StateManApi Function() make, {
  bool supportsAccessControl = false,
}) {
  group('access control', () {
    accessChecks.forEach((property, check) {
      test(property, () async {
        final api = make();
        addTearDown(api.dispose);
        await check(api);
      });
    });
  },
      skip: supportsAccessControl
          ? null
          : 'this implementation declares no access surface; the access '
              'contract is skipped rather than passed, so the capability is '
              'visible in the run report instead of absent from it');
}
