/// The method names this harness speaks — and why they are not the wire's.
///
/// There are two method tables in this repository and there have to be.
/// `packages/tfc_relay_protocol/lib/src/methods.dart` is the real one: the
/// names on it are, by construction, things any connected client may invoke,
/// which is why `test/api_surface_test.dart` writes the surface down as
/// literals and fails when it grows. This table is the other one, and every
/// name below that is not reused from the real table exists only so a test can
/// make a value arrive.
///
/// That distinction is the whole reason for the file. Half the names here —
/// [setValue], [dropKey], [disconnectUpstream] — are levers that stand in for
/// the plant. `lib/src/harness.dart:39-44` already makes the argument from the
/// other side: those levers are kept off `StateManApi` because "a method that
/// exists is a thing any connected client may invoke, so adding one is an
/// access-control decision, not a convenience". A harness that declared them in
/// `Methods` would hand that decision to whoever next copies a constant, and a
/// gateway registering the harness table by accident would let a connected
/// client tell the plant what the plant is reading. So they live here, in a
/// `publish_to: none` test-kit package that no server imports, under a
/// [prefix] that makes the boundary greppable.
///
/// Three names *are* reused from the real table, because the real table already
/// names the concept and inventing a second spelling would make the harness
/// prove a property against a name that does not ship: `Methods.write` and
/// `Methods.update` are used verbatim.
///
/// `Methods.subscribe` is deliberately **not** reused, and its absence is a
/// decision rather than an oversight. This harness carries the served source's
/// whole store: there is one session, it opens with a snapshot and every later
/// change is pushed. Per-key subscription accounting — handles, unsubscribe,
/// which client asked for what — is Phase 3's session layer, and borrowing the
/// wire's name for something that does not do that would make a later reader
/// believe subscription semantics had already been proven over this channel.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The error codes this harness mints, in JSON-RPC's implementation-defined
/// range (-32099…-32000).
///
/// Two, and both exist so an exception keeps its *type* across the boundary.
/// A JSON-RPC error carries a number, a sentence and a data bag; what it cannot
/// carry is a Dart class, so a caller catching `on TypeError` in ported code
/// would catch nothing at all unless the number says which class to rebuild.
abstract final class HarnessErrorCodes {
  /// The far side's typed accessor was handed a value of another type.
  ///
  /// `PreferencesApi`'s getters are documented to throw a `TypeError` for this
  /// (`preferences_api.dart:30-36`) — it is the behavior of the interface being
  /// mirrored, kept so ported call sites read the same, and therefore something
  /// the channel has to preserve rather than flatten into a generic failure.
  static const typeMismatch = -32001;

  /// A sub-API method failed on the far side for any other reason.
  static const subApiFailed = -32002;

  /// An access family refused a write: the session lacked the group it needs.
  ///
  /// Its own code, and the one the channel maps back into an [AccessDenied] on
  /// the client, so a refusal is the **same type** on both legs — the property
  /// D-09 requires ("one exception type, so a screen cannot tell which
  /// transport refused it"). The harness mints its own number rather than
  /// importing the gateway's `forbidden` code: this kit may not depend on the
  /// gateway package (`handler_table_test` requires this name to appear zero
  /// times in its production lib, and the reverse edge is equally forbidden),
  /// and the number only has to be stable across this one channel. The
  /// **domain** refusals — a bound template, the last
  /// users-holder, a bad config — travel as [subApiFailed] instead, because
  /// they are deliberately NOT authorisation verdicts and the contract asserts
  /// they arrive as something other than an AccessDenied.
  static const accessForbidden = -32003;
}

/// Every method name the channel harness registers or sends.
abstract final class HarnessMethods {
  /// What marks a name as belonging to the harness rather than to the wire.
  ///
  /// A grep for this string finds every test-only method in one pass, and a
  /// name carrying it can never collide with a real one: nothing in
  /// [Methods] contains a dot.
  static const prefix = 'harness.';

  // --------------------------------------------------------- the value path

  /// A forced round trip for one key — `StateManApi.readFresh`.
  static const readFresh = '${prefix}readFresh';

  /// One round trip for many keys — `StateManApi.readMany`.
  ///
  /// Distinct from N [readFresh] calls on purpose: the served source counts one
  /// round trip per answer, so a client that fanned this out into N requests
  /// would be visible as N in `StateManHarness.roundTrips` even though the
  /// counter lives on the far side of the channel.
  static const readMany = '${prefix}readMany';

  /// The keys the served source can serve — `StateManApi.keys`.
  ///
  /// The client answers `keys` from its own store and never sends this in the
  /// ordinary path; it is registered so a test can ask the *source* what it
  /// holds and compare, and so a round trip exists that changes nothing (the
  /// barrier the batch-count case uses).
  static const keys = '${prefix}keys';

  /// A write — the real wire's name, because this is the real concept.
  static const write = Methods.write;

  /// Re-asking what became of a list of commands — the real wire's name, for
  /// the same reason [write] uses it.
  static const writeStatus = Methods.writeStatus;

  /// A batch of changed values, pushed source → client. The real wire's name,
  /// one character long, for the same reason it is one character there.
  static const update = Methods.update;

  // ------------------------------------------------------- the hold feed

  /// One feed of a hold-to-run deadman, client → source. The real wire's
  /// name, because it is the real concept.
  ///
  /// In its own block and deliberately **not** in [levers]. A lever is a name
  /// that must never appear on a wire a connected client can reach, and this
  /// one does appear there: the gateway registers `Methods.holdTick` and a
  /// panel sends it ten times a second while a button is held. It is a
  /// notification in both places for the same reason — a tick has no outcome
  /// to correlate, and the safety property is that the counter STOPS.
  static const holdTick = Methods.holdTick;

  // ----------------------------------------------------------------- levers

  /// `StateManHarness.setValue`.
  static const setValue = '${prefix}setValue';

  /// `StateManHarness.setValues` — one batch, which is the unit the
  /// notification-count promise is made about.
  static const setValues = '${prefix}setValues';

  /// `StateManHarness.setQuality`.
  static const setQuality = '${prefix}setQuality';

  /// `StateManHarness.dropKey`.
  static const dropKey = '${prefix}dropKey';

  /// `StateManHarness.disconnectUpstream`.
  static const disconnectUpstream = '${prefix}disconnectUpstream';

  /// `StateManHarness.reconnectUpstream`.
  static const reconnectUpstream = '${prefix}reconnectUpstream';

  // ----------------------------------------------------- the write levers

  /// `StateManWriteHarness.failNextWrite`.
  static const failNextWrite = '${prefix}failNextWrite';

  /// `StateManWriteHarness.clampNextWrite`.
  static const clampNextWrite = '${prefix}clampNextWrite';

  /// `StateManWriteHarness.stallWrites` — Phase 2's `blackhole`, aimed at the
  /// write path.
  static const stallWrites = '${prefix}stallWrites';

  /// `StateManWriteHarness.releaseWrites`.
  static const releaseWrites = '${prefix}releaseWrites';

  /// `StateManWriteHarness.setReadOnly`.
  static const setReadOnly = '${prefix}setReadOnly';

  /// `StateManDataHarness.seedTimeseries` — the one data-service lever.
  ///
  /// A lever and not an API method, and the distinction is the reason the
  /// contract declares it separately from `TimeseriesApi`
  /// (`data_services_contract.dart:78-81`): a client that could insert samples
  /// could forge history, and a chart is evidence. Recording is the gateway's
  /// job, upstream of anything a socket can reach — so this name belongs in
  /// [levers], where a Phase 10 test asserting the real method table is closed
  /// will find it.
  static const seedTimeseries = '${prefix}seedTimeseries';

  // -------------------------------------------------------- the sub-APIs
  //
  // Thirty-four names, one per method on the four data-service interfaces, and
  // not one generic `call(method, args)` among them. That is T-02-22: a
  // pass-through that dispatched on a caller-supplied string would let whatever
  // is on the far side be asked for anything it happens to implement, and the
  // set of things reachable over the channel would stop being a list anybody
  // can read. `test/channel/channel_sub_apis_test.dart` counts the abstract
  // methods on each interface and fails when a constant or a handler is
  // missing, in both directions, so the list cannot fall behind the interface
  // it mirrors either.
  //
  // These are *not* levers. Browse, history and preferences are things a real
  // client legitimately asks a gateway for; they carry the [prefix] only
  // because the real table (`methods.dart`) has not named them yet, and Phase 3
  // is where they get their wire spelling. Putting them in [levers] would say
  // the opposite — that they must never be reachable — which would be wrong in
  // a way that a later reader would take as settled.

  /// `BrowseApi.fetchRoots`.
  static const browseFetchRoots = '${prefix}browse.fetchRoots';

  /// `BrowseApi.fetchChildren`.
  static const browseFetchChildren = '${prefix}browse.fetchChildren';

  /// `BrowseApi.fetchDetail`.
  static const browseFetchDetail = '${prefix}browse.fetchDetail';

  /// `BrowseApi.resolvePath`.
  static const browseResolvePath = '${prefix}browse.resolvePath';

  /// Every [BrowseApi] method, as data.
  static const browseMethods = <String>{
    browseFetchRoots,
    browseFetchChildren,
    browseFetchDetail,
    browseResolvePath,
  };

  /// `TimeseriesApi.queryTimeseriesData`.
  static const timeseriesQuery = '${prefix}timeseries.queryTimeseriesData';

  /// `TimeseriesApi.queryTimeseriesDataMultiple`.
  static const timeseriesQueryMultiple =
      '${prefix}timeseries.queryTimeseriesDataMultiple';

  /// `TimeseriesApi.queryTimeseriesDataDownsampled`.
  static const timeseriesQueryDownsampled =
      '${prefix}timeseries.queryTimeseriesDataDownsampled';

  /// Every [TimeseriesApi] method, as data.
  static const timeseriesMethods = <String>{
    timeseriesQuery,
    timeseriesQueryMultiple,
    timeseriesQueryDownsampled,
  };

  /// `HistoryViewApi.createHistoryView`.
  static const historyCreateView = '${prefix}historyViews.createHistoryView';

  /// `HistoryViewApi.updateHistoryView`.
  static const historyUpdateView = '${prefix}historyViews.updateHistoryView';

  /// `HistoryViewApi.deleteHistoryView`.
  static const historyDeleteView = '${prefix}historyViews.deleteHistoryView';

  /// `HistoryViewApi.selectHistoryViews`.
  static const historySelectViews = '${prefix}historyViews.selectHistoryViews';

  /// `HistoryViewApi.getHistoryViewKeys`.
  static const historyGetKeys = '${prefix}historyViews.getHistoryViewKeys';

  /// `HistoryViewApi.getHistoryViewGraphs`.
  static const historyGetGraphs = '${prefix}historyViews.getHistoryViewGraphs';

  /// `HistoryViewApi.getHistoryViewKeyNames`.
  static const historyGetKeyNames =
      '${prefix}historyViews.getHistoryViewKeyNames';

  /// `HistoryViewApi.addHistoryViewPeriod`.
  static const historyAddPeriod = '${prefix}historyViews.addHistoryViewPeriod';

  /// `HistoryViewApi.deleteHistoryViewPeriod`.
  static const historyDeletePeriod =
      '${prefix}historyViews.deleteHistoryViewPeriod';

  /// `HistoryViewApi.listHistoryViewPeriods`.
  static const historyListPeriods =
      '${prefix}historyViews.listHistoryViewPeriods';

  /// `HistoryViewApi.getGlobalRetentionHorizon`.
  static const historyRetentionHorizon =
      '${prefix}historyViews.getGlobalRetentionHorizon';

  /// Every [HistoryViewApi] method, as data.
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

  /// `PreferencesApi.getKeys`.
  static const prefGetKeys = '${prefix}preferences.getKeys';

  /// `PreferencesApi.getAll`.
  static const prefGetAll = '${prefix}preferences.getAll';

  /// `PreferencesApi.getBool`.
  static const prefGetBool = '${prefix}preferences.getBool';

  /// `PreferencesApi.getInt`.
  static const prefGetInt = '${prefix}preferences.getInt';

  /// `PreferencesApi.getDouble`.
  static const prefGetDouble = '${prefix}preferences.getDouble';

  /// `PreferencesApi.getString`.
  static const prefGetString = '${prefix}preferences.getString';

  /// `PreferencesApi.getStringList`.
  static const prefGetStringList = '${prefix}preferences.getStringList';

  /// `PreferencesApi.containsKey`.
  static const prefContainsKey = '${prefix}preferences.containsKey';

  /// `PreferencesApi.setBool`.
  static const prefSetBool = '${prefix}preferences.setBool';

  /// `PreferencesApi.setInt`.
  static const prefSetInt = '${prefix}preferences.setInt';

  /// `PreferencesApi.setDouble`.
  static const prefSetDouble = '${prefix}preferences.setDouble';

  /// `PreferencesApi.setString`.
  static const prefSetString = '${prefix}preferences.setString';

  /// `PreferencesApi.setStringList`.
  static const prefSetStringList = '${prefix}preferences.setStringList';

  /// `PreferencesApi.remove`.
  static const prefRemove = '${prefix}preferences.remove';

  /// `PreferencesApi.clear`.
  static const prefClear = '${prefix}preferences.clear';

  /// Every [PreferencesApi] *method*, as data.
  ///
  /// `onPreferencesChanged` is deliberately absent: it is a getter returning a
  /// stream, not a request, and it crosses this channel as
  /// [preferencesChanged] going the other way.
  static const preferenceMethods = <String>{
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

  /// One key changed, pushed source → client.
  ///
  /// The stream half of [PreferencesApi], and the only sub-API traffic that
  /// travels outward. One notification per change, fanned out to every local
  /// listener by [ChannelPreferencesApi] rather than by opening a subscription
  /// per listener: DB-03's promise is that a second operator's edit reaches the
  /// first one's open form, and a per-listener subscription would make the
  /// number of messages on the wire depend on how many widgets happen to be
  /// watching.
  static const preferencesChanged = '${prefix}preferences.changed';

  /// Every request name belonging to the four data-service sub-APIs.
  ///
  /// The number the meta test counts. Excludes [seedTimeseries], which is a
  /// lever, and [preferencesChanged], which is a notification travelling the
  /// other way.
  static const dataServices = <String>{
    ...browseMethods,
    ...timeseriesMethods,
    ...historyViewMethods,
    ...preferenceMethods,
  };

  // -------------------------------------------------------- the access families
  //
  // Twenty-eight request names, one per method on the four access interfaces
  // (twenty-nine until the access audit cut `accessTemplates.template` — no
  // caller anywhere; a remote derives one template from `list()`),
  // and — like the data services — not one generic `call(method, args)` among
  // them (T-02-22). `test/channel/channel_sub_apis_test.dart` counts these
  // against the interfaces by mirrors, in both directions, so the table cannot
  // fall behind the interface it mirrors.
  //
  // The session lever `actAs`, the recording readout `accessStoreWrites` and
  // the stored-password probe are deliberately NOT here: they are observables
  // and levers, read straight off the served instance the way `roundTrips` is,
  // so nothing carries them and mirroring them would invent wire traffic to
  // move a value that is already correct (channel_state_man.dart's argument).

  // templates
  static const accessTemplatesList = '${prefix}access.templates.list';
  static const accessTemplatesBindings = '${prefix}access.templates.bindings';
  static const accessTemplatesKeysBoundTo =
      '${prefix}access.templates.keysBoundTo';
  static const accessTemplatesCreate = '${prefix}access.templates.create';
  static const accessTemplatesUpdate = '${prefix}access.templates.update';
  static const accessTemplatesRename = '${prefix}access.templates.rename';
  static const accessTemplatesDelete = '${prefix}access.templates.delete';
  static const accessTemplatesBind = '${prefix}access.templates.bind';
  static const accessTemplatesUnbind = '${prefix}access.templates.unbind';

  static const templateMethods = <String>{
    accessTemplatesList,
    accessTemplatesBindings,
    accessTemplatesKeysBoundTo,
    accessTemplatesCreate,
    accessTemplatesUpdate,
    accessTemplatesRename,
    accessTemplatesDelete,
    accessTemplatesBind,
    accessTemplatesUnbind,
  };

  // roles and users
  static const accessAdminRoles = '${prefix}access.admin.roles';
  static const accessAdminListUsers = '${prefix}access.admin.listUsers';
  static const accessAdminCreateRole = '${prefix}access.admin.createRole';
  static const accessAdminUpdateRole = '${prefix}access.admin.updateRole';
  static const accessAdminDeleteRole = '${prefix}access.admin.deleteRole';
  static const accessAdminRenameRole = '${prefix}access.admin.renameRole';
  static const accessAdminCreateUser = '${prefix}access.admin.createUser';
  static const accessAdminDeleteUser = '${prefix}access.admin.deleteUser';
  static const accessAdminSetUserRole = '${prefix}access.admin.setUserRole';
  static const accessAdminSetUserStationAccount =
      '${prefix}access.admin.setUserStationAccount';
  static const accessAdminSetUserPassword =
      '${prefix}access.admin.setUserPassword';

  static const adminMethods = <String>{
    accessAdminRoles,
    accessAdminListUsers,
    accessAdminCreateRole,
    accessAdminUpdateRole,
    accessAdminDeleteRole,
    accessAdminRenameRole,
    accessAdminCreateUser,
    accessAdminDeleteUser,
    accessAdminSetUserRole,
    accessAdminSetUserStationAccount,
    accessAdminSetUserPassword,
  };

  // audit (read-only)
  static const auditEntries = '${prefix}access.audit.entries';
  static const auditMemberCounts = '${prefix}access.audit.memberCountsByAction';
  static const auditDistinctWho = '${prefix}access.audit.distinctWho';

  static const auditMethods = <String>{
    auditEntries,
    auditMemberCounts,
    auditDistinctWho,
  };

  // backend config
  static const configRead = '${prefix}access.config.read';
  static const configValidate = '${prefix}access.config.validate';
  static const configWrite = '${prefix}access.config.write';
  static const configPrevious = '${prefix}access.config.previous';
  static const configRestorePrevious = '${prefix}access.config.restorePrevious';

  static const configMethods = <String>{
    configRead,
    configValidate,
    configWrite,
    configPrevious,
    configRestorePrevious,
  };

  /// Every request name belonging to the four access sub-APIs.
  static const accessMethods = <String>{
    ...templateMethods,
    ...adminMethods,
    ...auditMethods,
    ...configMethods,
  };

  // There is deliberately no name here for `upstreamWriteAttempts` or
  // `mintedCmds`. Both are synchronous on the interface, so neither could be
  // answered by a round trip without changing the interface — the same
  // argument `channel_state_man.dart` makes for `roundTrips`. It is worth
  // stating once more here because of what the attempt counter is *for*: it is
  // the only observable that makes "a write is never auto-retried" testable,
  // and it works precisely because it lives where the attempts happen. A
  // mirrored copy on the client would count the client's sends, which is the
  // one place a retry would not be.

  /// The names that must never appear on a wire a connected client can reach.
  ///
  /// As data rather than as eleven references, so a Phase 10 test asserting the
  /// real method table is closed can iterate it instead of restating it.
  static const levers = <String>{
    setValue,
    setValues,
    setQuality,
    dropKey,
    disconnectUpstream,
    reconnectUpstream,
    failNextWrite,
    clampNextWrite,
    stallWrites,
    releaseWrites,
    setReadOnly,
    seedTimeseries,
  };

  /// Every name this harness registers on the served side.
  static const served = <String>{
    readFresh,
    readMany,
    keys,
    write,
    writeStatus,
    holdTick,
    ...levers,
    ...dataServices,
    ...accessMethods,
  };
}
