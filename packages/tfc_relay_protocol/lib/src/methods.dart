/// Protocol version negotiated in `hello` (MCP-style: date-stamped, client
/// sends the newest it supports, server echoes or counter-offers).
const protocolVersion = '2026-08-13';

/// JSON-RPC method names.
///
/// Requests (carry an id, expect a result): [hello], [subscribe],
/// [unsubscribe], [write], [writeStatus], [ackAlarm], [read], [readFresh],
/// [readMany], [ping], plus the timeseries / history / preferences methods
/// added in later steps.
///
/// Notifications (no id, never acknowledged): [update], [tick], [resync],
/// [status], [bye] server→client, and [holdTick] client→server — the only
/// name a client sends without expecting an answer. Nothing that needs an
/// outcome may ever be sent as a notification, and a hold tick has none: the
/// engage and the release are ordinary [write] calls with three-state
/// outcomes, and the feed in between is liveness, whose whole safety property
/// is that it STOPS.
abstract final class Methods {
  static const hello = 'hello';
  static const subscribe = 'subscribe';
  static const unsubscribe = 'unsubscribe';
  static const write = 'write';
  static const writeStatus = 'writeStatus';

  /// An operator acknowledging one active alarm, carrying [AckAlarmParams].
  ///
  /// Spelled in full rather than shortened the way [update] and [holdTick]
  /// are. Those two are hot paths — one frame per value per tick, one frame
  /// per tick per held button — and an acknowledge is one frame per operator
  /// gesture, so there is no byte budget to buy and a readable name is worth
  /// more than four saved characters in a log.
  ///
  /// **Why it is an RPC when D-9 made the active set a value key.** They are
  /// not the same direction. `AlarmKeys.active` is *state*, and the pipe's
  /// conflation, fan-out and snapshot-on-reconnect are the correct semantics
  /// for state — that is the whole of D-9's argument and it is unchanged. An
  /// acknowledge is an *operator action*, and an action needs an addressee, an
  /// authorization decision and an answer: the three things a conflated value
  /// key structurally cannot give it. `pipe_keys.dart`'s *"these are keys, not
  /// an API"* cuts **for** this method, not against it.
  ///
  /// **It carries no `cmd`, deliberately.** A write mints a ULID because a
  /// re-send has to be distinguishable from a second actuation — pressing
  /// Start twice is two starts. An acknowledge is idempotent by construction:
  /// acknowledging an already-acknowledged `(alarmUid, ruleIndex)` is a no-op,
  /// and the second ack of the same alarm is the same intent as the first. So
  /// there is nothing for an idempotency key to protect, and there is no
  /// `ackStatus` to reconcile one against. A field nothing consumes is a name
  /// pretending to be a rule.
  ///
  /// **The confirmation is the readback, not the return.** The operator learns
  /// the ack took effect when the alarm leaves `AlarmKeys.active` — PROJECT.md's
  /// *"readback is the only confirmation"* applied here without an exception.
  /// This request's own answer says one thing only: the gateway accepted the
  /// instruction and handed it to an alarm engine. It does not say the row
  /// moved.
  static const ackAlarm = 'ackAlarm';

  /// The cached read — no round trip, answered from what the gateway last
  /// heard. `StateManApi.read`'s name, because it is the same concept.
  static const read = 'read';

  /// The forced round trip for one key — `StateManApi.readFresh`.
  static const readFresh = 'readFresh';

  /// One round trip for many keys — `StateManApi.readMany`.
  static const readMany = 'readMany';

  static const ping = 'ping';

  /// Interactive sign-in on an already-helloed session — the method that
  /// ends the awaiting-sign-in state (`SessionLoginParams` in,
  /// `SessionLoginResult` out). Post-hello **by construction**: the
  /// handshake gate refuses it before `hello` like every other name, and the
  /// Argon2id verification it triggers runs off the hello path, where
  /// `TokenValidator.validate`'s no-event-loop-await constraint does not
  /// bind. Spelled `family.method` like the access names, because "login"
  /// bare would read as a tenth session verb and this is an *authentication*
  /// act, not a value operation.
  static const sessionLogin = 'session.login';

  /// The way back down: returns a signed-in session to the awaiting-sign-in
  /// sentinel — never to a direct-mode-shaped anonymous, which is a concept
  /// this wire does not have. Idempotent on a session that is already
  /// nobody, because the panel that calls it cannot know whether a reconnect
  /// already reset the far end.
  static const sessionLogout = 'session.logout';

  /// The hold-to-run deadman feed — client→server, one frame per tick period
  /// while a button is held, carrying [HoldTickParams] and no id.
  ///
  /// One character for the same reason [update] is: this is a hot path, and
  /// the wire spelling is a literal in the server's surface test either way.
  /// It is registered as a handler so json_rpc_2 dispatches it, but it is not
  /// one of the nine names a client may *call* — nothing is ever sent back.
  static const holdTick = 'h';

  static const update = 'u'; // hot path — one character on purpose
  static const tick = 'tick';
  static const resync = 'resync';
  static const status = 'status';
  static const bye = 'bye';
}

/// The wire names of the four data services, and their per-family sets.
///
/// A **sibling** of [Methods] rather than more names inside it, and the
/// argument is readability under a reviewer's eye: [Methods] is the session
/// and value vocabulary somebody reads top to bottom to learn what this pipe
/// does, and forty-seven names in one class stops being that. The split also
/// buys the shape the tests want — the per-family sets are what a closure test
/// *iterates* instead of restating, which is exactly what
/// `rpc_names.dart:378-381` asks for one layer up.
///
/// These names lived in `tfc_relay_client`'s `client_sub_apis.dart` until
/// Phase 10, where the client was the only end that had them. The gateway
/// could not reach them: the server's production `lib/` may not name the
/// contract kit (`handler_table_test.dart:264-296`) and it does not depend on
/// the client at all, so registering handlers meant a second copy of
/// thirty-four strings and a drift nobody would notice until a method came
/// back `-32601` in the plant. This package is the one both ends already
/// import.
///
/// Every name is `family.methodName`: the family segment is the `StateManApi`
/// getter, the method segment is the interface member verbatim, and
/// `data_service_methods_test.dart` compares each family against its interface
/// in both directions so neither half can move without the other.
abstract final class DataServiceMethods {
  static const browseFetchRoots = 'browse.fetchRoots';
  static const browseFetchChildren = 'browse.fetchChildren';
  static const browseFetchDetail = 'browse.fetchDetail';
  static const browseResolvePath = 'browse.resolvePath';

  /// Every `BrowseApi` method, as data.
  static const browseMethods = <String>{
    browseFetchRoots,
    browseFetchChildren,
    browseFetchDetail,
    browseResolvePath,
  };

  static const timeseriesQuery = 'timeseries.queryTimeseriesData';
  static const timeseriesQueryMultiple =
      'timeseries.queryTimeseriesDataMultiple';
  static const timeseriesQueryDownsampled =
      'timeseries.queryTimeseriesDataDownsampled';

  /// Every `TimeseriesApi` method, as data.
  static const timeseriesMethods = <String>{
    timeseriesQuery,
    timeseriesQueryMultiple,
    timeseriesQueryDownsampled,
  };

  static const historyCreateView = 'historyViews.createHistoryView';
  static const historyUpdateView = 'historyViews.updateHistoryView';
  static const historyDeleteView = 'historyViews.deleteHistoryView';
  static const historySelectViews = 'historyViews.selectHistoryViews';
  static const historyGetKeys = 'historyViews.getHistoryViewKeys';
  static const historyGetGraphs = 'historyViews.getHistoryViewGraphs';
  static const historyGetKeyNames = 'historyViews.getHistoryViewKeyNames';
  static const historyAddPeriod = 'historyViews.addHistoryViewPeriod';
  static const historyDeletePeriod = 'historyViews.deleteHistoryViewPeriod';
  static const historyListPeriods = 'historyViews.listHistoryViewPeriods';
  static const historyRetentionHorizon = 'historyViews.getGlobalRetentionHorizon';

  /// Every `HistoryViewApi` method, as data.
  static const historyViewMethods = <String>{
    historyCreateView,
    historyUpdateView,
    historyDeleteView,
    historySelectViews,
    historyGetKeys,
    historyGetGraphs,
    historyGetKeyNames,
    historyAddPeriod,
    historyDeletePeriod,
    historyListPeriods,
    historyRetentionHorizon,
  };

  static const prefGetKeys = 'preferences.getKeys';
  static const prefGetAll = 'preferences.getAll';
  static const prefGetBool = 'preferences.getBool';
  static const prefGetInt = 'preferences.getInt';
  static const prefGetDouble = 'preferences.getDouble';
  static const prefGetString = 'preferences.getString';
  static const prefGetStringList = 'preferences.getStringList';
  static const prefContainsKey = 'preferences.containsKey';
  static const prefSetBool = 'preferences.setBool';
  static const prefSetInt = 'preferences.setInt';
  static const prefSetDouble = 'preferences.setDouble';
  static const prefSetString = 'preferences.setString';
  static const prefSetStringList = 'preferences.setStringList';
  static const prefRemove = 'preferences.remove';
  static const prefClear = 'preferences.clear';

  /// Every `PreferencesApi` *method*, as data.
  ///
  /// [preferencesChanged] is deliberately absent for the reason given at its
  /// own declaration.
  static const preferencesMethods = <String>{
    prefGetKeys,
    prefGetAll,
    prefGetBool,
    prefGetInt,
    prefGetDouble,
    prefGetString,
    prefGetStringList,
    prefContainsKey,
    prefSetBool,
    prefSetInt,
    prefSetDouble,
    prefSetString,
    prefSetStringList,
    prefRemove,
    prefClear,
  };

  /// Every data-service **request** name: thirty-four, and the whole wire
  /// surface Phase 10 adds to the gateway.
  ///
  /// Spelled from the four sets above rather than as a second copy of the
  /// strings, so a name can only be in one place.
  static const all = <String>{
    ...browseMethods,
    ...timeseriesMethods,
    ...historyViewMethods,
    ...preferencesMethods,
  };

  /// The gateway's notification that a preference changed somewhere else.
  ///
  /// In this class but in **none** of the sets above, including [all]. It is a
  /// server→client notification: it belongs in the session's
  /// `expectedNotifications` and never in the handler table, and a set that
  /// carried it would make the method-table-closure test demand a handler for
  /// a frame that must never have one. `PreferencesApi.onPreferencesChanged`
  /// is the receiving half, and it is a getter — so the reflection that counts
  /// the family sets against the interface excludes it from the other
  /// direction too.
  static const preferencesChanged = 'preferences.changed';
}

/// The wire names of the four access families, and their per-family sets.
///
/// A **third sibling** beside [Methods] and [DataServiceMethods], not more
/// names inside either. The readability argument is [DataServiceMethods]' own —
/// a class somebody reads top to bottom stops being one at forty-seven names —
/// and there is a sharper one here: **these are the names an access review
/// reads.** Somebody auditing what a station may do to roles, templates, the
/// audit trail and the backend's own configuration should be able to read one
/// class and know they have seen all of it, rather than filtering twenty-eight
/// names out of sixty-two.
///
/// Same shape as [DataServiceMethods] in every respect, because the tests that
/// hold it are the same tests: every name is `family.methodName`, the family
/// segment is the `StateManApi` getter and the method segment is the interface
/// member verbatim; the per-family sets are what a closure test iterates rather
/// than restates; and [all] is spelled from the four sets so a name can only
/// exist in one place. `access_api_test.dart` compares each family against its
/// interface in both directions.
///
/// There is no notification here. [DataServiceMethods.preferencesChanged] has
/// no counterpart: nothing on these four families is pushed. A role change
/// takes effect through the credential sweep (D-08), which closes the session
/// rather than telling it something.
abstract final class AccessMethods {
  static const templateList = 'accessTemplates.list';
  static const templateBindings = 'accessTemplates.bindings';
  static const templateKeysBoundTo = 'accessTemplates.keysBoundTo';
  static const templateCreate = 'accessTemplates.create';
  static const templateUpdate = 'accessTemplates.update';
  static const templateRename = 'accessTemplates.rename';
  static const templateDelete = 'accessTemplates.delete';
  static const templateBind = 'accessTemplates.bind';
  static const templateUnbind = 'accessTemplates.unbind';

  /// Every `AccessTemplateApi` method, as data.
  static const templateMethods = <String>{
    templateList,
    templateBindings,
    templateKeysBoundTo,
    templateCreate,
    templateUpdate,
    templateRename,
    templateDelete,
    templateBind,
    templateUnbind,
  };

  static const adminRoles = 'accessAdmin.roles';
  static const adminListUsers = 'accessAdmin.listUsers';
  static const adminCreateRole = 'accessAdmin.createRole';
  static const adminUpdateRole = 'accessAdmin.updateRole';
  static const adminDeleteRole = 'accessAdmin.deleteRole';
  static const adminRenameRole = 'accessAdmin.renameRole';
  static const adminCreateUser = 'accessAdmin.createUser';
  static const adminDeleteUser = 'accessAdmin.deleteUser';
  static const adminSetUserRole = 'accessAdmin.setUserRole';
  static const adminSetUserStationAccount = 'accessAdmin.setUserStationAccount';
  static const adminSetUserPassword = 'accessAdmin.setUserPassword';

  /// Every `AccessAdminApi` method, as data.
  static const adminMethods = <String>{
    adminRoles,
    adminListUsers,
    adminCreateRole,
    adminUpdateRole,
    adminDeleteRole,
    adminRenameRole,
    adminCreateUser,
    adminDeleteUser,
    adminSetUserRole,
    adminSetUserStationAccount,
    adminSetUserPassword,
  };

  static const auditEntries = 'audit.entries';
  static const auditMemberCountsByAction = 'audit.memberCountsByAction';
  static const auditDistinctWho = 'audit.distinctWho';

  /// Every `AuditApi` method, as data — three reads, and there is no fourth.
  ///
  /// A `record` name would be the client writing its own audit rows. It is
  /// absent from this set for the reason it is absent from the interface, and
  /// `access_api_test.dart` reddens on the set/interface mismatch either way
  /// round.
  static const auditMethods = <String>{
    auditEntries,
    auditMemberCountsByAction,
    auditDistinctWho,
  };

  static const configRead = 'backendConfig.read';
  static const configValidate = 'backendConfig.validate';
  static const configWrite = 'backendConfig.write';
  static const configPrevious = 'backendConfig.previous';
  static const configRestorePrevious = 'backendConfig.restorePrevious';

  /// Every `BackendConfigApi` method, as data.
  ///
  /// The family segment is what keeps `backendConfig.read` and
  /// `backendConfig.write` from colliding with the session vocabulary's bare
  /// `read` and `write`. They are different operations that happen to share a
  /// verb, and the dot is the whole of what tells them apart on the wire.
  static const configMethods = <String>{
    configRead,
    configValidate,
    configWrite,
    configPrevious,
    configRestorePrevious,
  };

  /// Every access **request** name: twenty-eight, and the whole wire surface
  /// Phase 17 adds to the gateway. (Twenty-nine originally; the access audit
  /// cut `accessTemplates.template` — no caller anywhere, including its own
  /// store; remote implementations derive it from `list()`.)
  ///
  /// Spelled from the four sets above rather than as a second copy of the
  /// strings, so a name can only be in one place.
  static const all = <String>{
    ...templateMethods,
    ...adminMethods,
    ...auditMethods,
    ...configMethods,
  };
}

/// Application close codes (WebSocket 4000–4999 private range).
///
/// Standard codes other than 1000 throw in web_socket_channel (#1690), and
/// `closeCode` is unreliable for self-initiated closes (#1698) — both ends
/// track the codes they send themselves.
abstract final class CloseCodes {
  static const authExpired = 4001;
  static const serverDraining = 4002;
  static const heartbeatTimeout = 4003;
  static const backpressureOverrun = 4004;
  static const protocolMismatch = 4005;

  /// The peer completed the upgrade and never said `hello` inside
  /// `ServerConfig.preHelloDeadline`.
  ///
  /// Reconnect and complete the handshake: the credential was never the
  /// problem, because it was never presented. Not [heartbeatTimeout], because
  /// `ConnectionClose` — the gateway's own close ledger — records codes, not
  /// sentences, and 4003 would send an engineer looking at a heartbeat that
  /// was never due.
  static const preHelloTimeout = 4006;

  /// The gateway was already holding `ServerConfig.maxUnhelloedSessions`
  /// connections that had not said `hello`.
  ///
  /// Reconnect with backoff. This is transient and it is about the gateway's
  /// load, not about this peer's credential — which is exactly what
  /// [authExpired] would have said instead, sending a panel to re-authenticate
  /// a token that is perfectly good.
  static const unhelloedBudget = 4007;
}
