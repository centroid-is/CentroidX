/// The bodies of the four access families' methods: templates, roles and
/// accounts, the audit trail, and the backend's own configuration — the
/// twenty-eight names `AccessMethods.all` declares (17-09).
///
/// Same first rule as `data_handlers.dart`, for the same reason: **nothing in
/// here registers anything.** Every handler is handed to `RelaySession._on`,
/// the one seam where a method enters the table, which is where the handshake
/// gate and the error armor are applied. A handler that registered itself
/// would arrive ungated, and an ungated `accessAdmin.createRole` is a peer
/// that never authenticated editing who may do what to the plant.
///
/// ## No check lives here, and the absence is load-bearing
///
/// This object holds the session's *decorated* view of the source — the
/// per-session gate `relay_session.dart` builds — and consults nothing else.
/// Every question of the form "may this station do X" is asked and answered
/// one layer down, by the decorator these calls pass through, against the one
/// master system (`tfc_access`). `access_handlers_test.dart` greps this file,
/// comments stripped, for the vocabulary of a check and requires zero hits;
/// 17-06's sabotage (g) is the standing demonstration that a **correct**
/// check in the wrong place still fails the phase — the misplaced gate
/// starves the audit trail even while the plant stays safe.
///
/// **The one deliberate exception elsewhere is not a precedent for here.**
/// `AlarmHandlers.acknowledge` (`alarm_handlers.dart`) asks its injected
/// `canWriteKey` at the handler, because an ack is not a `StateManApi` member
/// and there is no decorator surface for it to be gated on. The four access
/// families **are** `StateManApi` members — `accessTemplates`, `accessAdmin`,
/// `audit`, `backendConfig` — so they take the decorator route and need no
/// such exception. Copying the alarm pattern into this file would be a second
/// rule beside the master's, which is exactly what Phase 17 exists to delete.
///
/// ## The wire shapes, written down once
///
/// 17-08's client proxies and the contract kit's served half must agree with
/// these handlers about parameter names, so the convention is stated here
/// rather than discovered by diffing:
///
///  * A member taking scalars takes them as named params spelled exactly as
///    the interface spells them (`{'from': …, 'to': …}`, `{'keyName': …}`),
///    plus an optional `reason`.
///  * A member taking one DTO carries it under a single **envelope key** whose
///    name is the interface parameter: `accessTemplates.create`/`update` take
///    `{'value': {name, rules}, 'reason'?}`, `accessAdmin.createRole`/
///    `updateRole` take `{'role': {name, groups, seeded}, 'reason'?}`, and
///    `audit.entries` takes `{'query': AuditQueryParams.toJson}`. The envelope
///    keeps the DTO's field set from colliding with the sibling `reason`, and
///    it is the shape the contract kit's channel served side
///    (`served_state_man.dart`) and 17-08's client proxies
///    (`client_sub_apis.dart`) both already speak — this file was reconciled to
///    that reference in 17-14 (F-3), because a decoder that read the flat map
///    could not decode a single template, role or filtered query any client
///    actually sends.
///  * The two credential-carrying members are the exception, and deliberately:
///    `accessAdmin.createUser` takes `NewUserParams.toJson` and
///    `accessAdmin.setUserPassword` takes `SetUserPasswordParams.toJson`
///    **as** the params object, with no envelope — their DTOs already carry a
///    `reason`-free withholding shape, and both the kit and the client send
///    them whole.
///  * Answers are the `access_api.dart` codecs' output — lists of
///    `toJson`/codec maps, or `null` for a void write.
///
/// There is no identity parameter anywhere in these shapes, and that is
/// D-11 rather than an omission: attribution is to the identity the server
/// verified at `hello`, and a wire field a hand-rolled client could name
/// somebody else through must not exist.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The handler bodies for one session's access methods.
///
/// Holds no state of its own: every answer is the source's, encoded. The
/// gate is **not** applied here — it lives one layer down, in the decorated
/// [source] this object is handed, so a handler added by a later plan cannot
/// forget it (the T-06-38 property, unchanged since Phase 6).
final class AccessHandlers {
  AccessHandlers({required this.source});

  /// The source being served, already seen through this session's gate.
  ///
  /// **Named `source`, and it must not be renamed to `api`** —
  /// `data_handlers.dart:77-86` records the pin: the client's no-retry sweep
  /// counts `api.write(` and `api.holdToRun(` over this package's `lib/` at
  /// exactly one occurrence each, and a delegate field called `api` would
  /// trip it with a failure message about retries on a file that never
  /// actuates anything.
  final StateManApi source;

  // ------------------------------------------------------------- decoding

  static Map<String, Object?> _map(rpc.Parameters params) =>
      params.asMap.cast<String, Object?>();

  /// The operator's justification, when the frame carries one. It says
  /// *why*, never *who* — see `access_api.dart`'s library doc.
  ///
  /// **Present-but-null is treated as absent (17-14).** Every client proxy
  /// sends `{'reason': reason}` with `reason` frequently null
  /// (`client_sub_apis.dart`), so `"reason":null` arrives on the wire on the
  /// common path. `params['reason'].exists` is `true` for a present-null value
  /// and `.asString` then throws `-32602 "must be a string, but was null"` —
  /// which would refuse every create/update/delete/bind that carries no
  /// justification, i.e. almost all of them. `valueOr(null)` is what the data
  /// handlers use for exactly this reason.
  static String? _reason(rpc.Parameters params) {
    final reason = params['reason'].valueOr(null);
    return reason is String ? reason : null;
  }

  /// A page whitelist parameter, decoded fail-closed.
  ///
  /// `valueOr(null)` for the same reason [_reason] uses it: the client sends
  /// `{'pages': pages}` with `pages` null on the common path — clearing a
  /// whitelist — and `.asList` on a present-null throws `-32602`.
  ///
  /// The null and the empty list are **different writes** and both are legal,
  /// so this must not collapse them: null clears the whitelist, `[]` is a
  /// whitelist naming nothing. `pagesFromJson` is the one place that decision
  /// is written down, and it denies on anything unreadable.
  static Set<String>? _pages(rpc.Parameters params) =>
      pagesFromJson(params['pages'].valueOr(null));

  // ------------------------------------------------- templates (nine names)

  Future<Object?> templateList(rpc.Parameters _) async => [
        for (final template in await source.accessTemplates.list())
          accessTemplateToJson(template),
      ];

  Future<Object?> templateBindings(rpc.Parameters _) =>
      source.accessTemplates.bindings();

  Future<Object?> templateKeysBoundTo(rpc.Parameters params) =>
      source.accessTemplates.keysBoundTo(params['templateName'].asString);

  Future<Object?> templateCreate(rpc.Parameters params) async {
    await source.accessTemplates.create(
        accessTemplateFromJson(params['value'].asMap.cast<String, Object?>()),
        reason: _reason(params));
    return null;
  }

  Future<Object?> templateUpdate(rpc.Parameters params) async {
    await source.accessTemplates.update(
        accessTemplateFromJson(params['value'].asMap.cast<String, Object?>()),
        reason: _reason(params));
    return null;
  }

  Future<Object?> templateRename(rpc.Parameters params) async {
    await source.accessTemplates.rename(
        params['from'].asString, params['to'].asString,
        reason: _reason(params));
    return null;
  }

  Future<Object?> templateDelete(rpc.Parameters params) async {
    await source.accessTemplates
        .delete(params['name'].asString, reason: _reason(params));
    return null;
  }

  Future<Object?> templateBind(rpc.Parameters params) async {
    await source.accessTemplates.bind(
        params['keyName'].asString, params['templateName'].asString,
        reason: _reason(params));
    return null;
  }

  Future<Object?> templateUnbind(rpc.Parameters params) async {
    await source.accessTemplates
        .unbind(params['keyName'].asString, reason: _reason(params));
    return null;
  }

  // ---------------------------------------------------- admin (eleven names)

  Future<Object?> adminRoles(rpc.Parameters _) async => [
        for (final role in await source.accessAdmin.roles())
          accessRoleToJson(role),
      ];

  Future<Object?> adminListUsers(rpc.Parameters _) async => [
        for (final user in await source.accessAdmin.listUsers())
          userSummaryToJson(user),
      ];

  Future<Object?> adminCreateRole(rpc.Parameters params) async {
    await source.accessAdmin.createRole(
        accessRoleFromJson(params['role'].asMap.cast<String, Object?>()),
        reason: _reason(params));
    return null;
  }

  Future<Object?> adminUpdateRole(rpc.Parameters params) async {
    await source.accessAdmin.updateRole(
        accessRoleFromJson(params['role'].asMap.cast<String, Object?>()),
        reason: _reason(params));
    return null;
  }

  Future<Object?> adminDeleteRole(rpc.Parameters params) async {
    await source.accessAdmin
        .deleteRole(params['name'].asString, reason: _reason(params));
    return null;
  }

  Future<Object?> adminRenameRole(rpc.Parameters params) async {
    await source.accessAdmin.renameRole(
        params['from'].asString, params['to'].asString,
        reason: _reason(params));
    return null;
  }

  /// The params object is [NewUserParams.toJson] — it carries a credential,
  /// which is why it travels as a withholding DTO rather than as bare
  /// arguments, and why nothing here logs, echoes or restates it. A failure
  /// on this path is armored by `RelaySession._answer`, whose substituted
  /// `request` is what keeps the frame out of every error message.
  Future<Object?> adminCreateUser(rpc.Parameters params) async {
    await source.accessAdmin.createUser(NewUserParams.fromJson(_map(params)));
    return null;
  }

  Future<Object?> adminDeleteUser(rpc.Parameters params) async {
    await source.accessAdmin
        .deleteUser(params['subject'].asString, reason: _reason(params));
    return null;
  }

  Future<Object?> adminSetUserRole(rpc.Parameters params) async {
    await source.accessAdmin.setUserRole(
        params['subject'].asString, params['newRole'].asString,
        reason: _reason(params));
    return null;
  }

  Future<Object?> adminSetUserStationAccount(rpc.Parameters params) async {
    await source.accessAdmin.setUserStationAccount(
        params['subject'].asString, params['value'].asBool,
        reason: _reason(params));
    return null;
  }

  Future<Object?> adminSetRolePages(rpc.Parameters params) async {
    await source.accessAdmin
        .setRolePages(params['subject'].asString, _pages(params),
            reason: _reason(params));
    return null;
  }

  Future<Object?> adminSetUserPages(rpc.Parameters params) async {
    await source.accessAdmin
        .setUserPages(params['subject'].asString, _pages(params),
            reason: _reason(params));
    return null;
  }

  /// [SetUserPasswordParams.toJson] as params — see [adminCreateUser].
  Future<Object?> adminSetUserPassword(rpc.Parameters params) async {
    await source.accessAdmin
        .setUserPassword(SetUserPasswordParams.fromJson(_map(params)));
    return null;
  }

  // ---------------------------------------------------- audit (three names)

  Future<Object?> auditEntries(rpc.Parameters params) async => [
        for (final row in await source.audit.entries(AuditQueryParams.fromJson(
            params['query'].asMap.cast<String, Object?>())))
          auditRecordToJson(row),
      ];

  Future<Object?> auditMemberCountsByAction(rpc.Parameters params) =>
      source.audit.memberCountsByAction([
        for (final id in params['actionIds'].asList) id as String,
      ]);

  Future<Object?> auditDistinctWho(rpc.Parameters _) =>
      source.audit.distinctWho();

  // ----------------------------------------------------- config (five names)

  Future<Object?> configRead(rpc.Parameters _) async =>
      (await source.backendConfig.read()).toJson();

  Future<Object?> configValidate(rpc.Parameters params) async =>
      (await source.backendConfig.validate(params['configJson'].asString))
          .toJson();

  Future<Object?> configWrite(rpc.Parameters params) async {
    await source.backendConfig
        .write(params['configJson'].asString, reason: _reason(params));
    return null;
  }

  Future<Object?> configPrevious(rpc.Parameters _) async =>
      (await source.backendConfig.previous())?.toJson();

  Future<Object?> configRestorePrevious(rpc.Parameters params) async {
    await source.backendConfig.restorePrevious(reason: _reason(params));
    return null;
  }
}
