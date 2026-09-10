/// The gateway-mode access stores: the same surfaces the screens already
/// call, served over the pipe, and a protocol error becoming a domain
/// exception again (17-12).
///
/// ## Why these `implements` the concrete stores
///
/// `AccessTemplateStore`, `AccessAdminStore` and `AuditTrailStore` are
/// concrete classes in `tfc_dart` with no extracted interface, and Phase 17's
/// sibling plans hold that package while this one lands — so the "extract an
/// interface beside the class" route the plan preferred is not takeable here.
/// The next-best shape achieves the same property: every public member of the
/// three stores is a plain method (all their state is private), so a class in
/// this package may `implements` them, which makes the concrete store itself
/// the common supertype. Direct mode keeps returning the exact classes it
/// returns today; gateway mode returns these; every screen compiles against
/// the store type and cannot tell which route answered. If `tfc_dart` later
/// grows the interfaces, these adapters implement them instead and nothing
/// else moves.
///
/// ## The error mapping (criterion: a domain error keeps its type)
///
/// The domain exceptions live in `tfc_dart`, which `tfc_relay_client` may not
/// import, so a domain refusal crosses the wire as a typed protocol error —
/// an `RpcException` whose `data` carries `{code: 'template_in_use',
/// templateName: ..., boundKeys: [...]}` (the shape 17-08's arm 6 pinned;
/// there is deliberately no second spelling of it in `access_api.dart` yet —
/// a declared DTO there is 17-08's queued follow-up F-2). **This file is where
/// the payload becomes a type again**, because the app has both packages. An
/// unrecognised code becomes a named [RelayedAccessException] carrying the
/// raw code — never a silent swallow, because an unmapped code is a bug in
/// [kAccessDomainErrorFactories] and must be visible as one.
///
/// A `forbidden`, by contrast, was already re-raised by the client as the
/// direct path's `AccessDenied` (17-08's `withAccessErrors`); it is **not**
/// mapped twice here — it passes through, and the adapters only add the
/// `onDenied` callback the direct stores fire so the shared denial prompt
/// appears on either transport.
///
/// ## The audit sink ([ServerAuditedSink])
///
/// The wire has **no** audit-record method, and never may (D-05/D-11): a
/// method a client could write an arbitrary row through would be a forgery
/// surface, and the row's `who`/`station`/`origin` must come from the
/// identity the *server* verified at `hello`. So in gateway mode the audit
/// row for every relayed operation is written server-side by the policy
/// decorator, and the panel's own sink records nothing — but it must not be
/// `NullAuditSink`, whose meaning is "knowingly running without a trail".
/// [ServerAuditedSink] is the third case, named: the trail exists, it lives
/// at the far end, and this type is how a test or a screen tells the three
/// cases apart.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_admin_store.dart';
import 'package:tfc_dart/core/access/access_template_store.dart';
import 'package:tfc_dart/core/access/audit_trail_store.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppUserData;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    hide PreferencesApi;

// -----------------------------------------------------------------------------
// The protocol-error to domain-exception mapping
// -----------------------------------------------------------------------------

/// What the wire could not say, before 17-08's F-1 closed the gap.
///
/// `AccessAdminApi.listUsers` used to answer `AuthenticatedUser` — a *session
/// identity*, four fields, no timestamps — so a gateway-mode `AppUserData` had
/// nowhere honest to get `createdAt` from and every account on the users screen
/// rendered as 1970-01-01. It now answers [UserSummary], which carries both
/// timestamps, and the sentinel is no longer reached against a backend of this
/// build.
///
/// It is kept, and still means "not a date any account was created at",
/// because `AppUserData.createdAt` is non-nullable and [UserSummary.createdAt]
/// is: a panel on this build talking to a backend that predates the DTO gets a
/// null, and epoch zero is how that absence stays visible instead of being
/// filled in with a plausible recent date. `lastLoginAt` needs no sentinel —
/// it is nullable all the way down, and the screen already renders null as
/// "never".
final DateTime kUnknownOverTheWire =
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// A domain error whose code this build does not recognise.
///
/// Named and thrown rather than swallowed or flattened: an unmapped code
/// means [kAccessDomainErrorFactories] is stale against the gateway, and the
/// screen saying so — with the raw code — is what gets it fixed. Deliberately
/// not an [AccessDenied]: an unknown domain rule is not an authorisation
/// verdict.
final class RelayedAccessException implements Exception {
  const RelayedAccessException(this.code, this.message);

  /// The raw wire code nothing here could map.
  final String code;

  /// The gateway's own sentence, carried because it is all the app knows.
  final String message;

  @override
  String toString() =>
      'RelayedAccessException(unmapped code "$code"): $message';
}

String _field(Map<Object?, Object?> data, String key) =>
    (data[key] ?? data['name'] ?? '').toString();

List<String> _keys(Map<Object?, Object?> data) => [
      for (final key in (data['boundKeys'] as List<Object?>?) ?? const [])
        '$key',
    ];

/// Every domain error code the wire convention carries, as data — the test
/// iterates this registry rather than a hand-kept list, so a code added here
/// without a type (or vice versa) reddens an arm instead of going stale.
///
/// The value rebuilds the same exception type the direct store throws, from
/// the payload fields 17-08's arm 6 pinned by example (`templateName`,
/// `boundKeys`, `keyName`). `forbidden` is deliberately absent: it is not a
/// domain code, it is an authorisation verdict, and the client already
/// re-raised it as `AccessDenied` before this table is consulted.
final Map<String, Exception Function(Map<Object?, Object?> data)>
    kAccessDomainErrorFactories = Map.unmodifiable({
  'template_in_use': (Map<Object?, Object?> data) =>
      TemplateInUseException(_field(data, 'templateName'), _keys(data)),
  'template_not_found': (Map<Object?, Object?> data) =>
      TemplateNotFoundException(_field(data, 'templateName')),
  'template_exists': (Map<Object?, Object?> data) =>
      TemplateExistsException(_field(data, 'templateName')),
  'invalid_template_name': (Map<Object?, Object?> data) =>
      InvalidTemplateNameException(_field(data, 'templateName')),
  'binding_not_found': (Map<Object?, Object?> data) =>
      BindingNotFoundException(_field(data, 'keyName')),
});

/// The domain exception [error]'s payload encodes, or null when the error is
/// not a domain payload at all (no `data` map, or no string `code` in it) —
/// those are infrastructure failures and must propagate as what they are,
/// "you cannot yet" staying distinguishable from "the data refused".
Exception? domainExceptionFor(rpc.RpcException error) {
  final data = error.data;
  if (data is! Map) return null;
  final code = data['code'];
  if (code is! String) return null;
  final factory = kAccessDomainErrorFactories[code];
  if (factory != null) return factory(data.cast<Object?, Object?>());
  return RelayedAccessException(code, error.message);
}

/// Runs [send], re-raising a domain-coded protocol error as the concrete
/// exception the direct store throws. Everything else — `AccessDenied` from
/// the client's own `forbidden` mapping, a `helloRequired`, a plain
/// `handlerFailed` with no payload — propagates untouched.
Future<T> relayedAccessErrors<T>(Future<T> Function() send) async {
  try {
    return await send();
  } on rpc.RpcException catch (error) {
    final domain = domainExceptionFor(error);
    if (domain != null) throw domain;
    rethrow;
  }
}

// -----------------------------------------------------------------------------
// The adapters
// -----------------------------------------------------------------------------

/// [AccessTemplateStore]'s surface over the pipe.
///
/// The check, the audit row and every invariant live at the far end, above
/// the one real store the backend holds — which is the whole of "one master
/// access-control system". What this adds is the wire, the error mapping,
/// and the [onDenied] callback the direct store also fires so the shared
/// denial prompt appears on either transport.
///
/// The `origin` parameters the store signatures carry are accepted and
/// deliberately **not sent**: the wire has no origin field (D-11 — the column
/// that says a row came from the relay must not be client-writable), and the
/// gateway stamps `'relay'` on the rows it writes.
final class RelayedAccessTemplateStore implements AccessTemplateStore {
  RelayedAccessTemplateStore({
    required AccessTemplateApi api,
    void Function(AccessDenied denial)? onDenied,
  })  : _api = api,
        _onDenied = onDenied;

  final AccessTemplateApi _api;
  final void Function(AccessDenied denial)? _onDenied;

  Future<T> _guarded<T>(Future<T> Function() send) async {
    try {
      return await relayedAccessErrors(send);
    } on AccessDenied catch (denial) {
      // Before the rethrow, exactly as the direct store fires it before the
      // throw, so the prompt appears even at a call site that swallows.
      _onDenied?.call(denial);
      rethrow;
    }
  }

  @override
  Future<List<AccessTemplate>> list() => _guarded(_api.list);

  /// Derived from [list] — the wire deliberately has no single-row read (the
  /// access audit found no caller anywhere). Same snapshot semantics.
  @override
  Future<AccessTemplate?> template(String name) async {
    final templates = await list();
    for (final template in templates) {
      if (template.name == name) return template;
    }
    return null;
  }

  @override
  Future<Map<String, String>> bindings() => _guarded(_api.bindings);

  @override
  Future<List<String>> keysBoundTo(String templateName) =>
      _guarded(() => _api.keysBoundTo(templateName));

  @override
  Future<void> create(AccessTemplate value,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.create(value, reason: reason));

  @override
  Future<void> update(AccessTemplate value,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.update(value, reason: reason));

  @override
  Future<void> rename(String from, String to,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.rename(from, to, reason: reason));

  @override
  Future<void> delete(String name,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.delete(name, reason: reason));

  @override
  Future<void> bind(String keyName, String templateName,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.bind(keyName, templateName, reason: reason));

  @override
  Future<void> unbind(String keyName,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.unbind(keyName, reason: reason));
}

/// [AccessAdminStore]'s surface over the pipe. See
/// [RelayedAccessTemplateStore] for the shared reasoning; what differs here
/// is [listUsers], which must answer the drift row class the users section
/// renders from a wire type that carries four fields and no timestamps —
/// see [kUnknownOverTheWire] for how the gap is surfaced rather than
/// invented.
final class RelayedAccessAdminStore implements AccessAdminStore {
  RelayedAccessAdminStore({
    required AccessAdminApi api,
    void Function(AccessDenied denial)? onDenied,
  })  : _api = api,
        _onDenied = onDenied;

  final AccessAdminApi _api;
  final void Function(AccessDenied denial)? _onDenied;

  Future<T> _guarded<T>(Future<T> Function() send) async {
    try {
      return await relayedAccessErrors(send);
    } on AccessDenied catch (denial) {
      _onDenied?.call(denial);
      rethrow;
    }
  }

  @override
  Future<List<AccessRole>> roles() => _guarded(_api.roles);

  @override
  Future<List<AppUserData>> listUsers() => _guarded(() async => [
        for (final user in await _api.listUsers())
          AppUserData(
            username: user.username,
            roleName: user.roleName,
            // No credential crosses this wire in either direction —
            // `UserSummary` has nowhere to put one — and an empty digest can
            // never verify. Nothing renders these two columns *as values*;
            // what the screen does read is whether the account is open, so
            // the column carries the one bit the wire sent: the marker when
            // there is no password, and an empty string, which is not a hash
            // of anything, when there is one that stayed on the backend.
            passwordHash: user.hasPassword ? '' : kNoPasswordMarker,
            salt: '',
            // Both real since 17-08's F-1. The fallback is for a backend older
            // than the DTO, which sends no timestamp at all; see
            // [kUnknownOverTheWire] for why that stays visible as 1970 rather
            // than being filled in.
            createdAt: user.createdAt ?? kUnknownOverTheWire,
            lastLoginAt: user.lastLoginAt,
            stationAccount: user.stationAccount,
          ),
      ]);

  @override
  Future<void> createRole(AccessRole role,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.createRole(role, reason: reason));

  @override
  Future<void> updateRole(AccessRole role,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.updateRole(role, reason: reason));

  @override
  Future<void> deleteRole(String name,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.deleteRole(name, reason: reason));

  @override
  Future<void> renameRole(String from, String to,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.renameRole(from, to, reason: reason));

  @override
  Future<void> createUser({
    required String username,
    required String password,
    required String roleName,
    String origin = 'operator',
    String? reason,
  }) =>
      // The wire spells the administered account `subject` and the granted
      // role `grantedRole` (17-03's vocabulary ruling: `who`/`roleName` are
      // reserved for the server-side actor). The password crosses inside the
      // frame to be hashed server-side; the params class withholds it from
      // toString.
      _guarded(() => _api.createUser(NewUserParams(
            subject: username,
            password: password,
            grantedRole: roleName,
            reason: reason,
          )));

  @override
  Future<void> deleteUser(String username,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.deleteUser(username, reason: reason));

  @override
  Future<void> setUserRole(String username, String roleName,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.setUserRole(username, roleName, reason: reason));

  @override
  Future<void> setUserStationAccount(String username, bool value,
          {String origin = 'operator', String? reason}) =>
      _guarded(
          () => _api.setUserStationAccount(username, value, reason: reason));

  @override
  Future<void> setUserPassword(String username, String password,
          {String origin = 'operator', String? reason}) =>
      _guarded(() => _api.setUserPassword(SetUserPasswordParams(
            subject: username,
            password: password,
            reason: reason,
          )));
}

/// The allowed/denied filter as the wire's nullable bool — the two spellings
/// of three states, written down once.
bool? wireAllowedFor(AuditOutcomeFilter outcome) => switch (outcome) {
      AuditOutcomeFilter.any => null,
      AuditOutcomeFilter.allowedOnly => true,
      AuditOutcomeFilter.deniedOnly => false,
    };

/// An [AuditQuery] as its protocol shape, field for field. The window
/// survives as both bounds or neither (null window == the whole table, the
/// search escape), instants travel as epoch milliseconds UTC.
AuditQueryParams auditQueryParamsFor(AuditQuery query) => AuditQueryParams(
      startMs: query.window?.start.toUtc().millisecondsSinceEpoch,
      endMs: query.window?.end.toUtc().millisecondsSinceEpoch,
      beforeMs: query.before?.toUtc().millisecondsSinceEpoch,
      keyPrefix: query.keyPrefix,
      who: query.who,
      groupNames: query.groupNames,
      includeAuth: query.includeAuth,
      allowed: wireAllowedFor(query.outcome),
      limit: query.limit,
    );

/// [AuditTrailStore]'s surface over the pipe — read-only at both ends, like
/// the store and like the wire family (no `record` member exists anywhere on
/// this route, deliberately).
final class RelayedAuditTrailStore implements AuditTrailStore {
  RelayedAuditTrailStore({required AuditApi api}) : _api = api;

  final AuditApi _api;

  @override
  Future<List<AuditRecord>> entries(AuditQuery query) =>
      // A pass-through. The wire already carries `AuditRecord` — `tfc_access`'s
      // own declaration — and so does the store this implements, so there is
      // nothing left to convert.
      //
      // What used to be here was a reconstruction into drift's `AuditEntryData`
      // with `id: index`: a local ordinal invented to satisfy a class this
      // panel has no database for. Deleting it is the point of the change, not
      // a side effect of it — a gateway station now hands the page the same
      // objects the backend read out of the table.
      relayedAccessErrors(() => _api.entries(auditQueryParamsFor(query)));

  @override
  Future<Map<String, int>> memberCountsByAction(Iterable<String> actionIds) =>
      relayedAccessErrors(
          () => _api.memberCountsByAction(actionIds.toList()));

  @override
  Future<List<String>> distinctWho() =>
      relayedAccessErrors(_api.distinctWho);
}

// -----------------------------------------------------------------------------
// The gateway-mode audit sink
// -----------------------------------------------------------------------------

/// The audit sink a gateway panel holds: the trail lives at the far end.
///
/// Every relayed operation is audited **server-side** by the backend's policy
/// decorator, attributed to the identity the server verified at `hello` and
/// stamped `origin: 'relay'` (D-05, D-11) — and the wire deliberately has no
/// method a client could write a row through, because a client-supplied row
/// is a forgery surface. So this sink records nothing, and that is not a gap
/// in the trail: the action that would have produced the row travelled the
/// pipe and was recorded where the authority is.
///
/// It is a distinct type from [NullAuditSink] on purpose. That type's
/// documented meaning is "knowingly running without a trail" (the boot
/// window; a station commissioned with no Postgres), and a gateway panel is
/// neither — a test or a screen that finds this type knows the trail exists
/// and where. [Future.value] rather than any await: a sink must never be able
/// to stall the plant write it is recording.
final class ServerAuditedSink implements AuditSink {
  const ServerAuditedSink();

  @override
  Future<void> record(AuditRecord entry) => Future.value();
}
