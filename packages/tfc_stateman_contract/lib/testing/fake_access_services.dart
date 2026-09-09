/// In-memory reference implementations of the four access families — and one
/// deliberately damaged variant beside them.
///
/// [FakeAccessServices] is a **reference implementation, not a mock**, the same
/// argument `fake_data_services.dart` makes about the data services one file
/// over: creating a template really stores one, deleting a bound template
/// really throws, moving the last `users`-holding role away really refuses, and
/// the audit list really grows a row per decision — because the access contract
/// asserts all four. Nothing here opens a connection; nothing here answers with
/// an empty stand-in.
///
/// It differs from the data-service fakes in one structural way, and the
/// difference is the whole point of the access suite: **it asks a session.**
/// The four families consult a mutable [AccessSession] before every gated write,
/// throwing [AccessDenied] *before* the store is touched when the session lacks
/// the group the master policy requires (`AccessPolicy.groupForTemplate`,
/// `groupForAdmin`, `groupForBackendConfig`). "The write was refused" is the
/// easiest assertion in the file to satisfy by accident — a gate that throws
/// *after* writing refuses just as visibly as one that throws before — so this
/// fake **records every store touch** in [writes], the `_RecordingPreferences`
/// lever (`policy_test.dart:355`) generalised, and the contract's negative arms
/// assert that list did not grow.
///
/// The session is swapped by [actAs] rather than fixed at construction. In
/// production a session is fixed per connection (a role change closes the
/// session, D-08); [actAs] is a **test-only lever**, off the wire, in exactly
/// the lane `setValue` and `failNextWrite` travel — because the property the
/// suite judges is "the same implementation answers differently to different
/// sessions", and swapping the session on one live instance is how a single
/// [Check] exercises both a refusal and its permitted twin.
///
/// [BrokenAccessServices] is the standing proof the suite can fail, in
/// `broken_browse.dart`'s style: correct in every respect except one, selectable
/// by a constructor flag, kept in the tree so `test/sabotage_access_test.dart`
/// re-runs the proof in CI rather than leaving it in a SUMMARY.
library;

import 'dart:convert';

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Thrown by [FakeAccessServices.delete] when a template still has keys bound
/// to it.
///
/// A **domain** rule, not a permission one — it fires for a `users` session
/// exactly as for any other, because destroying a template that keys still point
/// at would silently un-scope those keys. Deliberately **not** an [AccessDenied]:
/// the contract's arm asserts the two are distinguishable, so a handler that
/// conflated "you may not" with "you cannot yet" is caught.
///
/// The kit's own type rather than `tfc_dart`'s `TemplateInUseException`, which
/// lives behind drift and cannot be imported here; the contract matches on the
/// property (it is not an [AccessDenied], and it names the bound keys) rather
/// than on the type.
class TemplateInUseException implements Exception {
  const TemplateInUseException(this.templateName, this.boundKeys);

  final String templateName;
  final List<String> boundKeys;

  @override
  String toString() => 'TemplateInUseException: "$templateName" is still bound '
      'to ${boundKeys.length} key(s): ${boundKeys.join(', ')}';
}

/// Thrown when a role edit would leave no role granting [AccessGroup.users].
///
/// The invariant that must not be lost in transit: a plant with nobody able to
/// administer roles can never get one back. A domain rule, refused for a `users`
/// session too, and never an [AccessDenied].
class LastUsersHolderException implements Exception {
  const LastUsersHolderException(this.roleName);

  final String roleName;

  @override
  String toString() => 'LastUsersHolderException: "$roleName" is the last role '
      'granting the users group; removing it would leave nobody able to '
      'administer roles';
}

/// Thrown by [FakeAccessServices.write] when the submitted configuration does
/// not parse, or edits a read-only section.
///
/// A validation rule (D-10), not a permission one: it fires for an `administer`
/// session, before anything is persisted, and it is never an [AccessDenied].
class ConfigRejected implements Exception {
  const ConfigRejected(this.problems);

  final List<String> problems;

  @override
  String toString() => 'ConfigRejected: ${problems.join('; ')}';
}

/// An in-memory implementation of all four access families over three maps,
/// two lists and a session.
class FakeAccessServices
    implements
        AccessTemplateApi,
        AccessAdminApi,
        AuditApi,
        BackendConfigApi {
  FakeAccessServices({
    AccessSession? session,
    String backendConfigJson = _defaultConfigJson,
  })  : _session = session ?? AccessSession(groups: AccessGroup.values.toSet()),
        _configJson = backendConfigJson;

  /// The default backend configuration the fake starts holding.
  ///
  /// A `relay` section is present so the read-only-section rule has something to
  /// protect, and a non-relay section so an accepted edit has somewhere to land.
  static const _defaultConfigJson =
      '{"relay":{"port":8443},"sources":{"ST101":"opc.tcp://10.0.0.1"}}';

  // ------------------------------------------------------------- the session

  AccessSession _session;

  /// Swaps the session the gated families consult. Test-only lever.
  void actAs(AccessSession session) => _session = session;

  /// The session currently in force — read by the anti-vacuity controls.
  AccessSession get session => _session;

  // --------------------------------------------------------- the store touches

  final _writes = <String>[];

  /// Every store mutation this fake has performed, in order, by name.
  ///
  /// The `_RecordingPreferences` lever generalised: a refusal must leave this
  /// list unchanged, which is what turns "the write was refused" from a claim
  /// into a *pre-effect* one. Unmodifiable so a check cannot alter the record
  /// it is judging.
  List<String> get writes => List.unmodifiable(_writes);

  // --------------------------------------------------------------- the stores

  final _templates = <String, AccessTemplate>{};
  final _bindings = <String, String>{}; // key -> templateName
  final _roles = <String, AccessRole>{};
  final _users = <String, UserSummary>{};

  /// The instant [createUser] stamps onto the next account it makes.
  ///
  /// A fixed base plus a per-account step, never `DateTime.now()`: this fake
  /// backs golden tests and contract runs that compare rendered output, and a
  /// wall clock in here would make two runs of the same test disagree. The step
  /// keeps successive accounts distinguishable, which is what a test asserting
  /// an ordering or a rendered date needs.
  static final DateTime _createdEpoch = DateTime.utc(2026, 1, 1, 9);
  int _createdStep = 0;
  DateTime _nextCreatedAt() =>
      _createdEpoch.add(Duration(minutes: _createdStep++));
  final _passwords = <String, String>{}; // username -> password, never exposed
  final _audit = <AuditRecord>[];
  String _configJson;
  String? _previousConfigJson;

  /// The one gate. Throws [AccessDenied] before any store touch when the current
  /// session lacks [required]; records the decision either way.
  ///
  /// Overridable so [BrokenAccessServices] can damage exactly this seam and
  /// nothing else — the pre-effect ordering, the session consultation, the audit
  /// row — each on its own.
  void requireGroup(AccessGroup required, String itemKey, String member) {
    final allowed = _consultSession(required);
    _recordDecision(itemKey, member, required, allowed);
    if (!allowed) throw AccessDenied(itemKey, required);
  }

  /// Whether the current session grants [required]. Its own method so a
  /// sabotage can stop consulting the session without touching the recording.
  bool _consultSession(AccessGroup required) => _session.can(required);

  /// Appends one audit row for a decision. Its own method so a sabotage can stop
  /// recording without touching the gate.
  void _recordDecision(
      String itemKey, String member, AccessGroup required, bool allowed) {
    _audit.add(AuditRecord(
      at: DateTime.now().toUtc(),
      who: _session.user?.username ?? 'anonymous',
      station: 'contract',
      roleName: _session.roleName,
      surface: 'access',
      itemKey: itemKey,
      member: member,
      groupRequired: required.name,
      allowed: allowed,
      origin: 'relay',
      actionId: '$member:$itemKey',
    ));
  }

  void _touch(String label) => _writes.add(label);

  // ============================================================ templates

  @override
  Future<List<AccessTemplate>> list() async => _templates.values.toList();

  // No `template(name)` member: the access audit cut it from the wire (no
  // caller anywhere, including its own store). A caller that wants one
  // template derives it from [list] — as the meta test now does.

  @override
  Future<Map<String, String>> bindings() async => Map.of(_bindings);

  @override
  Future<List<String>> keysBoundTo(String templateName) async => [
        for (final entry in _bindings.entries)
          if (entry.value == templateName) entry.key,
      ];

  @override
  Future<void> create(AccessTemplate value, {String? reason}) async {
    requireGroup(AccessGroup.users, value.name, 'template.create');
    _templates[value.name] = value;
    _touch('template.create:${value.name}');
  }

  @override
  Future<void> update(AccessTemplate value, {String? reason}) async {
    requireGroup(AccessGroup.users, value.name, 'template.update');
    _templates[value.name] = value;
    _touch('template.update:${value.name}');
  }

  @override
  Future<void> rename(String from, String to, {String? reason}) async {
    requireGroup(AccessGroup.users, from, 'template.rename');
    final existing = _templates.remove(from);
    if (existing != null) {
      _templates[to] = AccessTemplate(name: to, rules: existing.rules);
      for (final key in _bindings.keys.toList()) {
        if (_bindings[key] == from) _bindings[key] = to;
      }
    }
    _touch('template.rename:$from->$to');
  }

  @override
  Future<void> delete(String name, {String? reason}) async {
    requireGroup(AccessGroup.users, name, 'template.delete');
    // The domain rule fires AFTER the permission check and is a different fact:
    // a bound template cannot be deleted by anyone, `users` included, because it
    // would un-scope every key pointing at it.
    final bound = [
      for (final entry in _bindings.entries)
        if (entry.value == name) entry.key,
    ]..sort();
    if (bound.isNotEmpty) throw TemplateInUseException(name, bound);
    _templates.remove(name);
    _touch('template.delete:$name');
  }

  @override
  Future<void> bind(String keyName, String templateName,
      {String? reason}) async {
    requireGroup(AccessGroup.users, keyName, 'template.bind');
    _bindings[keyName] = templateName;
    _touch('template.bind:$keyName->$templateName');
  }

  @override
  Future<void> unbind(String keyName, {String? reason}) async {
    requireGroup(AccessGroup.users, keyName, 'template.unbind');
    _bindings.remove(keyName);
    _touch('template.unbind:$keyName');
  }

  // ============================================================ roles & users

  @override
  Future<List<AccessRole>> roles() async => _roles.values.toList();

  @override
  Future<List<UserSummary>> listUsers() async =>
      _users.values.toList()..sort((a, b) => a.username.compareTo(b.username));

  @override
  Future<void> createRole(AccessRole role, {String? reason}) async {
    requireGroup(AccessGroup.users, role.name, 'admin.createRole');
    _roles[role.name] = role;
    _touch('admin.createRole:${role.name}');
  }

  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async {
    requireGroup(AccessGroup.users, role.name, 'admin.updateRole');
    _roles[role.name] = role;
    _touch('admin.updateRole:${role.name}');
  }

  @override
  Future<void> deleteRole(String name, {String? reason}) async {
    requireGroup(AccessGroup.users, name, 'admin.deleteRole');
    // The last-users-holder invariant: refuse — for anyone — a delete that would
    // leave no role granting `users`.
    final existing = _roles[name];
    if (existing != null && existing.groups.contains(AccessGroup.users)) {
      final otherHolders = _roles.values.where((r) =>
          r.name != name && r.groups.contains(AccessGroup.users));
      if (otherHolders.isEmpty) throw LastUsersHolderException(name);
    }
    _roles.remove(name);
    _touch('admin.deleteRole:$name');
  }

  @override
  Future<void> renameRole(String from, String to, {String? reason}) async {
    requireGroup(AccessGroup.users, from, 'admin.renameRole');
    final existing = _roles.remove(from);
    if (existing != null) {
      _roles[to] = AccessRole(
          name: to, groups: existing.groups, seeded: existing.seeded);
    }
    _touch('admin.renameRole:$from->$to');
  }

  @override
  Future<void> createUser(NewUserParams params) async {
    requireGroup(AccessGroup.users, params.subject, 'admin.createUser');
    _users[params.subject] = UserSummary(
        username: params.subject,
        roleName: params.grantedRole,
        hasPassword: params.password.isNotEmpty,
        createdAt: _nextCreatedAt());
    _passwords[params.subject] = params.password;
    _touch('admin.createUser:${params.subject}');
  }

  @override
  Future<void> deleteUser(String subject, {String? reason}) async {
    requireGroup(AccessGroup.users, subject, 'admin.deleteUser');
    _users.remove(subject);
    _passwords.remove(subject);
    _touch('admin.deleteUser:$subject');
  }

  @override
  Future<void> setUserRole(String subject, String newRole,
      {String? reason}) async {
    requireGroup(AccessGroup.users, subject, 'admin.setUserRole');
    final existing = _users[subject];
    if (existing != null) {
      _users[subject] = UserSummary(
          username: subject,
          roleName: newRole,
          displayName: existing.displayName,
          stationAccount: existing.stationAccount,
          hasPassword: existing.hasPassword,
          createdAt: existing.createdAt,
          lastLoginAt: existing.lastLoginAt);
    }
    _touch('admin.setUserRole:$subject->$newRole');
  }

  @override
  Future<void> setUserStationAccount(String subject, bool value,
      {String? reason}) async {
    requireGroup(AccessGroup.users, subject, 'admin.setUserStationAccount');
    final existing = _users[subject];
    if (existing != null) {
      _users[subject] = UserSummary(
          username: subject,
          roleName: existing.roleName,
          displayName: existing.displayName,
          stationAccount: value,
          hasPassword: existing.hasPassword,
          createdAt: existing.createdAt,
          lastLoginAt: existing.lastLoginAt);
    }
    _touch('admin.setUserStationAccount:$subject=$value');
  }

  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async {
    requireGroup(AccessGroup.users, params.subject, 'admin.setUserPassword');
    // The password is stored and NEVER returned or echoed. There is no code path
    // here that puts it in a message, a result or a thrown error.
    _passwords[params.subject] = params.password;
    // An empty password removes it, the same as the repository: the roster
    // then reports the account as one that signs in on its username alone.
    final existing = _users[params.subject];
    if (existing != null) {
      _users[params.subject] = UserSummary(
          username: existing.username,
          roleName: existing.roleName,
          displayName: existing.displayName,
          stationAccount: existing.stationAccount,
          hasPassword: params.password.isNotEmpty,
          createdAt: existing.createdAt,
          lastLoginAt: existing.lastLoginAt);
    }
    _touch('admin.setUserPassword:${params.subject}');
  }

  /// Test-only readback of a stored password, for the contract's control that
  /// the write really happened. Not on any wire — the wire has no such member.
  String? storedPasswordFor(String subject) => _passwords[subject];

  // ============================================================ audit

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) async {
    // Ungated (spec §11 read deferral). A filter honest enough to prove the
    // trail grows: newest first, honouring the allowed/who filters the contract
    // exercises.
    return [
      for (final row in _audit.reversed)
        if ((query.who == null || row.who == query.who) &&
            (query.allowed == null || row.allowed == query.allowed))
          row,
    ];
  }

  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) async {
    final counts = <String, int>{for (final id in actionIds) id: 0};
    for (final row in _audit) {
      if (counts.containsKey(row.actionId)) {
        counts[row.actionId] = counts[row.actionId]! + 1;
      }
    }
    return counts;
  }

  @override
  Future<List<String>> distinctWho() async =>
      {for (final row in _audit) row.who}.toList()..sort();

  // ============================================================ backend config

  @override
  Future<BackendConfigDocument> read() async {
    requireGroup(AccessGroup.administer, 'state_man_config', 'config.read');
    return BackendConfigDocument(
      configJson: _configJson,
      readOnlySections: const ['relay'],
      hasPrevious: _previousConfigJson != null,
    );
  }

  @override
  Future<ConfigValidation> validate(String configJson) async {
    requireGroup(AccessGroup.administer, 'state_man_config', 'config.validate');
    final problems = _problemsWith(configJson);
    return ConfigValidation(ok: problems.isEmpty, problems: problems);
  }

  @override
  Future<void> write(String configJson, {String? reason}) async {
    requireGroup(AccessGroup.administer, 'state_man_config', 'config.write');
    // Validation before persistence (D-10's first hazard): a config that does
    // not parse, or that edits the relay section, is refused and NOTHING is
    // written. These throws are not AccessDenied — the session was allowed; the
    // payload was not.
    final problems = _problemsWith(configJson);
    if (problems.isNotEmpty) throw ConfigRejected(problems);
    _previousConfigJson = _configJson;
    _configJson = configJson;
    _touch('config.write');
  }

  @override
  Future<BackendConfigDocument?> previous() async {
    requireGroup(AccessGroup.administer, 'state_man_config', 'config.previous');
    final prev = _previousConfigJson;
    return prev == null
        ? null
        : BackendConfigDocument(
            configJson: prev, readOnlySections: const ['relay']);
  }

  @override
  Future<void> restorePrevious({String? reason}) async {
    requireGroup(
        AccessGroup.administer, 'state_man_config', 'config.restorePrevious');
    final prev = _previousConfigJson;
    if (prev == null) {
      throw const ConfigRejected(['there is nothing to restore']);
    }
    _previousConfigJson = _configJson;
    _configJson = prev;
    _touch('config.restorePrevious');
  }

  /// What is wrong with [configJson], or an empty list when it would be written.
  ///
  /// Two hazards, each its own overridable seam so a sabotage can reopen exactly
  /// one: it must parse as a JSON object ([parseProblems], D-10 first hazard),
  /// and its `relay` section must equal the live one ([relayProblems] — the
  /// socket the edit arrives on is not editable over that socket, D-10 second
  /// hazard).
  List<String> _problemsWith(String configJson) =>
      [...parseProblems(configJson), ...relayProblems(configJson)];

  /// The parse hazard, as its own seam. `BrokenAccessServices` overrides this to
  /// reopen D-10's first hazard.
  List<String> parseProblems(String configJson) {
    final Object? parsed;
    try {
      parsed = _decode(configJson);
    } on FormatException catch (e) {
      return ['the configuration does not parse: $e'];
    }
    if (parsed is! Map) {
      return ['the configuration is not a JSON object'];
    }
    return const [];
  }

  /// The relay-section hazard, as its own seam. `BrokenAccessServices` overrides
  /// this to reopen D-10's second hazard. Returns nothing when the payload does
  /// not parse — the parse seam owns that failure.
  List<String> relayProblems(String configJson) {
    final Object? parsed;
    try {
      parsed = _decode(configJson);
    } on FormatException {
      return const [];
    }
    if (parsed is! Map) return const [];
    final liveRelay = (_decode(_configJson) as Map)['relay'];
    if (!_deepEquals(parsed['relay'], liveRelay)) {
      return [
        'the relay section is read-only over the wire: it configures the '
            'socket this edit arrives on'
      ];
    }
    return const [];
  }

  static Object? _decode(String json) => jsonDecode(json);

  /// Order-insensitive equality by re-encoding both sides with sorted keys, so
  /// a `relay` section that only reordered its keys is not read as an edit.
  static bool _deepEquals(Object? a, Object? b) =>
      _canonical(a) == _canonical(b);

  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return '{${[for (final k in keys) '"$k":${_canonical(value[k])}'].join(',')}}';
    }
    if (value is List) {
      return '[${[for (final e in value) _canonical(e)].join(',')}]';
    }
    return jsonEncode(value);
  }
}

/// The one thing [BrokenAccessServices] gets wrong, selected by its constructor.
///
/// Each mode is correct in every respect except one, in `broken_browse.dart`'s
/// style, so `sabotage_access_test.dart` can assert the targeted checks fail and
/// their neighbours still pass. A mode that broke everything would prove nothing
/// about any individual check.
enum AccessDamage {
  /// (a) The gate throws, but only after the store has been touched — the
  /// pre-effect property broken. The refusal checks stay green (it does refuse);
  /// the `writes`-empty halves go red.
  checksAfterWriting,

  /// (b) Every gated member throws regardless of session — D-12's blank-page
  /// defect. Every permitted twin goes red.
  refusesEverything,

  /// (c) The gate is never consulted; every session is allowed. Every refusal
  /// check goes red.
  ignoresSession,

  /// (d) Decisions are made correctly and no audit row is recorded. The audit
  /// trail check goes red.
  auditWritesNothing,

  /// (e) D-10's second hazard reopened: a relay-section edit is accepted.
  acceptsRelaySectionEdit,

  /// (f) D-10's first hazard reopened: an unparseable payload is written.
  writesWithoutValidating,

  /// (g) `setUserPassword`'s refusal echoes the value. The no-echo check goes
  /// red; its anti-vacuity half (the permitted call succeeds) stays green.
  leaksPassword,
}

/// An [AccessDenied] whose message leaks a secret — mode (g)'s vehicle.
///
/// A subclass so it is still an [AccessDenied] (the paired password check's
/// refusal arm stays green — the refusal IS an authorisation verdict), while its
/// `toString` carries the password so only the no-echo check reddens.
class _LeakyDenied extends AccessDenied {
  const _LeakyDenied(super.itemKey, super.required, this.leaked);

  final String leaked;

  @override
  String toString() =>
      'AccessDenied: "$itemKey" requires the ${required.name} group '
      '(attempted value: "$leaked").';
}

/// [FakeAccessServices] with exactly one behaviour damaged, selected by
/// [damage]. Lives beside the honest fake, and stays in the tree, because — like
/// `broken_browse.dart` — it is the standing proof the access suite can fail,
/// re-run in CI by `test/sabotage_access_test.dart` rather than described in a
/// SUMMARY.
///
/// Every mode overrides a single seam of the honest fake and inherits the rest.
/// The overrides reach the honest fake's private seams because this class is in
/// the same library — the same arrangement that keeps the damage surgical.
class BrokenAccessServices extends FakeAccessServices {
  BrokenAccessServices(this.damage, {super.session, super.backendConfigJson});

  final AccessDamage damage;

  @override
  void requireGroup(AccessGroup required, String itemKey, String member) {
    switch (damage) {
      case AccessDamage.refusesEverything:
        // Throws for every session, allowed or not — the blank page.
        throw AccessDenied(itemKey, required);
      case AccessDamage.checksAfterWriting:
        // Touch the store first, THEN let the gate refuse: the pre-effect
        // property broken. On an allowed call this branch does nothing extra
        // and the real method touches as usual.
        if (!session.can(required)) _touch('leaked-write:$member');
        super.requireGroup(required, itemKey, member);
      default:
        super.requireGroup(required, itemKey, member);
    }
  }

  @override
  bool _consultSession(AccessGroup required) =>
      damage == AccessDamage.ignoresSession
          ? true
          : super._consultSession(required);

  @override
  void _recordDecision(
      String itemKey, String member, AccessGroup required, bool allowed) {
    if (damage == AccessDamage.auditWritesNothing) return;
    super._recordDecision(itemKey, member, required, allowed);
  }

  @override
  List<String> parseProblems(String configJson) =>
      damage == AccessDamage.writesWithoutValidating
          ? const []
          : super.parseProblems(configJson);

  @override
  List<String> relayProblems(String configJson) =>
      damage == AccessDamage.acceptsRelaySectionEdit
          ? const []
          : super.relayProblems(configJson);

  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async {
    if (damage == AccessDamage.leaksPassword &&
        !session.can(AccessGroup.users)) {
      throw _LeakyDenied(params.subject, AccessGroup.users, params.password);
    }
    return super.setUserPassword(params);
  }
}
