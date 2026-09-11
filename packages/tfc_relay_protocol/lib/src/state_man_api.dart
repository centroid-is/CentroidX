/// The one interface the wire may expose.
///
/// This file is the whole of what a client can ask the gateway to do
/// (relay-comm-design.md §1a). Capability here is defined by surface: a method
/// that exists is a thing any connected client may invoke, so adding one is an
/// access-control decision, not a convenience. That is why
/// `packages/tfc_stateman_contract/test/api_surface_test.dart` writes the
/// method table down as explicit literals and fails when this file grows or
/// shrinks — a new wire method must be a deliberate edit to a test that
/// explains the cost, never a quiet addition.
///
/// The package this lives in has no Flutter and no runtime dependencies, so
/// the gateway implements it on the plain Dart VM and the app implements it
/// behind a socket. That is also what makes the surface test possible:
/// `dart:mirrors` is available under `dart test` and not under
/// `flutter test`.
///
/// ## Decisions frozen here
///
/// Each of these was a real option; each is recorded so a later reader sees
/// the reasoning rather than an apparent oversight.
///
///  * **Substitution methods stay off the interface.** `setSubstitution` /
///    `substitutions` / `substitutionsChanged` / `resolveKey`
///    (`packages/tfc_dart/lib/core/state_man.dart:1268-1284`) are a
///    client-local key rewrite: the client resolves the key and subscribes to
///    the resolved one. Adding methods to a wire later is cheap; removing
///    them once a deployed client depends on them is not.
///  * **[StateManApi.readMany] stays on the interface.** The diagnostics page
///    already uses it, and N round trips over a slow link is precisely what
///    this project exists to avoid.
///  * **`isKeyDisabled` is not mirrored.** A key the server will not serve
///    surfaces as a per-key subscribe rejection and `Quality.errorConfig` on
///    the value, not as a second query path a caller must remember to consult.
///  * **Timeseries keeps `tableName`.** The four signatures come verbatim from
///    working code (`packages/tfc_dart/lib/core/database.dart:1305,1338,1463,
///    1620` — re-measured at 10-11; the signatures did not move, only the
///    line numbers, and the file has grown since Phase 1 recorded 722, 755,
///    837 and 1035).
///    Whether the wire speaks key space or table space is a Phase 10 question;
///    renaming a parameter now would silently change a signature that is being
///    frozen.
///  * **Data services are grouped behind sub-interfaces** ([BrowseApi],
///    [TimeseriesApi], [HistoryViewApi], [PreferencesApi]) rather than
///    flattened into ~43 members on one class. The surface test walks all five
///    types, so closure is asserted over the union — grouping costs nothing in
///    enforcement and makes the read path legible.
///  * **The four access families are grouped the same way** ([AccessTemplateApi],
///    [AccessAdminApi], [AuditApi], [BackendConfigApi], declared in
///    `access_api.dart`). Phase 17 adds twenty-eight methods and four getters
///    (twenty-nine were declared; `accessTemplates.template` was cut on the
///    2026-09-07 surface audit — no caller anywhere, including its own store),
///    which is the largest single growth this interface has had, and it is why
///    they are declared in one file a reviewer can read end to end rather than
///    discovered a handler at a time. **No member of any of them takes a
///    caller-supplied identity** — the client has no field to name somebody
///    else in, which is the structural half of ACCESS-06.
///  * **There is no health method.** `PIPE.*` keys are subscribable like any
///    plant tag (design §4.7, HLTH-01/02/03): `listen('PIPE.connected')` is
///    the health API, and it goes through the same store, the same quality
///    codes and the same widgets as a temperature. Its absence here is the
///    decision, not an omission.
library;

import 'access_api.dart';
import 'browse.dart';
import 'dynamic_value.dart';
import 'history_view.dart';
import 'hold_handle.dart';
import 'preferences_api.dart';
import 'timeseries.dart';
import 'value_listenable.dart';
import 'write_result.dart';

/// Everything a client may ask of a state source, local or remote.
///
/// The idiom is `DeviceClient`'s (`state_man.dart:855-891`): an abstract
/// interface, one doc comment per member, and a synchronous [read] that
/// returns null when the value is not known yet. Implementations are judged
/// by `package:tfc_stateman_contract`, not by their type.
abstract interface class StateManApi {
  /// The primary read path: a handle whose value changes in place.
  ///
  /// Returns immediately, for any key, whether or not the value is known yet
  /// — the handle is the subscription, and its value fills in when the first
  /// batch arrives. Listeners are notified only on a genuine change, so the
  /// page with 1500 keys on it costs k rebuilds per batch instead of 1500.
  /// This is the reason the value store exists and the reason this method,
  /// not [subscribe], is the one widgets should use.
  ValueListenable<DynamicValue> listen(String key);

  /// Compatibility adapter over the same store, for stream-consuming code.
  ///
  /// A plain `Stream`, deliberately not the `Future<Stream<DynamicValue>>`
  /// that `state_man.dart:1600` returns today: a future-of-stream forces
  /// every call site to await before it can even listen, which is how a
  /// widget ends up missing the first values of its own subscription.
  Stream<DynamicValue> subscribe(String key);

  /// The last known value for [key], or null if none is known yet.
  ///
  /// Synchronous and never a round trip — the `DeviceClient.read`
  /// convention (`state_man.dart:873`). Null means "not known yet", which is
  /// a different thing from a known-bad value; a known-bad value arrives as a
  /// [DynamicValue] carrying a bad `Quality`.
  DynamicValue? read(String key);

  /// Forces a round trip and resolves with a freshly-read value.
  ///
  /// For diagnostics and readback checks, where "what the cache says" is
  /// exactly the thing under suspicion. Everything else should use [listen].
  Future<DynamicValue> readFresh(String key);

  /// One round trip for many keys.
  ///
  /// Kept on the interface deliberately: the diagnostics page reads dozens of
  /// keys at once, and doing that as N calls over a link with 200 ms of
  /// latency is the failure mode this whole project exists to remove.
  Future<Map<String, DynamicValue>> readMany(List<String> keys);

  /// Writes [value] to [key] and reports what became of it.
  ///
  /// Returns a sealed [WriteResult] and **never throws to report an
  /// outcome**. A throw collapses "unknown" into "failed" — the exact
  /// anti-pattern [WriteResult] exists to kill, and the reason
  /// `Future<void> write` (`state_man.dart:1544`) is not mirrored. A write to
  /// a read-only key is a [WriteRejected], not an `UnsupportedError`
  /// (`state_man.dart:929-931` is what not to copy). Throwing is reserved for
  /// programmer error, such as calling this after [dispose].
  ///
  /// The `cmd` ULID that identifies this operator action is minted **inside
  /// the implementation, at call time**, because the call is the operator
  /// action: a re-send of the same action carries the same id, and
  /// [WriteResult.cmd] carries it back so a write can be reconciled later.
  /// Ordinary callers do not pass an id in and cannot make two actions share
  /// one — leave [cmd] null and the implementation mints.
  ///
  /// **[cmd] is for a relay, and a relay only.** A gateway serving a remote
  /// client is not originating the operator action, it is forwarding one that
  /// was already minted at the operator's keyboard (design §4.6), and the id
  /// minted there is the idempotency correlation everything downstream is keyed
  /// by: the client's `writeStatus` re-query after a reconnect asks about *that*
  /// id, and the outcome log has to answer under it. An implementation in the
  /// middle that mints a second id for the same operator action has created a
  /// write it can no longer reconcile — the client asks about the id it holds,
  /// the plant knows the write under another, and the honest answer collapses to
  /// "never received" for a command that may well have actuated a machine. So a
  /// relay passes the id it was given, and does not mint.
  ///
  /// Passing a [cmd] does not make a write idempotent by itself; it makes the
  /// *outcome* attributable, which is what lets the three-state answer survive a
  /// reconnect.
  ///
  /// While the write is in flight the value's quality carries
  /// `Quality.goodWritePending`, so a pending badge is a property of the
  /// value the widget is already watching — there is no handle object to hold
  /// and no second thing to keep in sync.
  ///
  /// Pass [expect] for compare-and-set: the write applies only if the current
  /// value still equals it, otherwise the result is a [WriteRejected].
  Future<WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd});

  /// Re-asks what became of commands whose outcome this side never learned.
  ///
  /// The answer is per-cmd and **positionally aligned with [cmds]** — element
  /// *i* answers `cmds[i]` — so a caller reconciling a reconnect does not have
  /// to trust a map key round trip to know which command it is being told
  /// about.
  ///
  /// [WriteNotReceived] is the only re-send-safe answer
  /// ([WriteResult.isSafeToResend]) and it requires positive evidence: the id
  /// is datable, was minted after the answering source started, is not in the
  /// future, and is still inside the dedup window. An implementation that
  /// cannot establish all four says [WriteUnknown], because "I have no record
  /// of it" and "it never happened" are the same sentence to a lookup table
  /// and very different sentences to a machine.
  ///
  /// On the interface rather than inside one client because the alternative
  /// leaves write recovery judged by nothing: the wire already exposes this
  /// call, so it is the *less* exposed of the two, and a contract suite that
  /// cannot ask a source about a cmd cannot check what it answers.
  Future<List<WriteResult>> writeStatus(List<String> cmds);

  /// Engages a hold-to-run deadman on [key] and returns the live hold.
  ///
  /// There is exactly one key and it is the one passed in: the tag *is* the
  /// deadman counter. A convention that derived a sibling tag name in Dart
  /// would have to be matched by hand in every PLC program, so the mapping
  /// stays where the integrator can see it.
  ///
  /// The engage is a real write and its outcome is three-state — a hold can
  /// be interlocked out exactly like any other command, and
  /// [HoldHandle.engagement] carries that answer. A handle whose engage did
  /// not apply is inert and already released with [HoldEnded.refused].
  ///
  /// The counter is client-minted and monotonic: **1** on engage, **+1** per
  /// tick, **0** on release, wrapping to 1 rather than going negative. Server
  /// stamping would make the gateway a source of the liveness the operator's
  /// finger is supposed to be.
  ///
  /// Ticks are fire-and-forget and are sent by calling [HoldHandle.tick] at a
  /// cadence the caller chooses (100 ms against a ~1 s PLC deadman). They are
  /// not a member of this interface, and must never become one: a method here
  /// is a thing any connected client may invoke against any key, and a bare
  /// `tick(key, n)` is a write primitive with no engage in front of it.
  ///
  /// The PLC-side counterpart — the deadman block that drops the output when
  /// the counter stops changing — is `relay-comm-design.md` §4.6a.
  Future<HoldHandle> holdToRun(String key);

  /// Every key this source can serve, for pickers and diagnostics.
  List<String> get keys;

  /// Navigating the upstream address space (the page editor's key picker).
  BrowseApi get browse;

  /// Historical samples for charts.
  TimeseriesApi get timeseries;

  /// Saved history views: their keys, graphs and time windows.
  HistoryViewApi get historyViews;

  /// Stored user and site preferences.
  ///
  /// Mirrors the preferences *interface* only — see [PreferencesApi] for why
  /// no method here can request secret material.
  PreferencesApi get preferences;

  /// Access templates and the key bindings that point at them.
  ///
  /// Every write behind this getter requires `AccessGroup.users` and the check
  /// happens at the far end. Nothing on the interface carries a permission or
  /// an answer about one — see [AccessTemplateApi].
  AccessTemplateApi get accessTemplates;

  /// Roles and accounts.
  ///
  /// The one family that can hand somebody `force` on a running line, which is
  /// why `AccessAdminApi.updateRole` is the most consequential hand-made write
  /// in the product and why the `admin` audit surface exists for it.
  AccessAdminApi get accessAdmin;

  /// Reads of the audit trail.
  ///
  /// Read-only by construction: [AuditApi] has no member that writes one. The
  /// relay records its own rows server-side, through the injected `AuditSink`.
  AuditApi get audit;

  /// The backend's own configuration (ACCESS-04).
  ///
  /// Editable except for the section that carries the edit: the `relay`
  /// section is readable and refused on write, because a config screen that
  /// can cut itself off is a trap.
  BackendConfigApi get backendConfig;

  /// Releases the subscription, the store and the transport.
  ///
  /// Asynchronous because a remote implementation has a socket to close.
  /// Contract cases register this with `addTearDown`, so an implementation
  /// that leaks after dispose fails the suite rather than the next test.
  Future<void> dispose();
}

/// Navigating the upstream address space.
///
/// Mirrors `BrowseDataSource` (`lib/widgets/browse_panel.dart:62-80`) so the
/// existing OPC UA and UMAS browse panels bind to a remote source without a
/// widget change. Children of a node are fetched one level at a time — the
/// page editor expands nodes on demand and an eager tree of a real PLC
/// address space is not something to put on a slow link.
abstract interface class BrowseApi {
  /// The top-level nodes of the address space.
  Future<List<BrowseNode>> fetchRoots();

  /// The direct children of [parent], one level only.
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent);

  /// Description, current value, data type and struct members of [node].
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node);

  /// Resolves the full chain of nodes from root to the node identified by
  /// [targetId], for pre-selection when opening the browse panel with an
  /// already-bound value (e.g. an existing UMAS `variableName` or an OPC UA
  /// NodeId).
  ///
  /// The returned list MUST be ordered root → … → leaf, with the last entry
  /// being the target node itself. Returns null if the target cannot be
  /// resolved (stale binding) or if the source does not support
  /// pre-selection. The ordering is the implementation's guarantee: a decoder
  /// cannot reconstruct it, and without it the panel opens unpositioned and
  /// the operator re-navigates the tree by hand.
  Future<List<BrowseNode>?> resolvePath(String targetId);
}

/// Historical samples, for charts.
///
/// The three signatures are verbatim from `database.dart:1305` (Multiple),
/// `:1338` (the single-series read) and `:1463` (Downsampled) — measured at
/// 10-11, when the phase that implements them ran the gate. They are cited in
/// file order rather than in the order they are declared below. (A fourth,
/// `countTimeseriesDataMultiple`, was mirrored at 10-11 and deleted by the
/// 2026-09-07 dead-code audit: its one end caller had moved to
/// `tsCache.countSince`, leaving seven mirror layers with no reader.)
/// Including the parameter name `tableName`. There is no method that takes a
/// statement, an expression or a filter string: charts ask for a named series
/// over a time range, and every argument here is a value the gateway
/// validates. That is a deliberate limit on what a client can make the
/// database do.
abstract interface class TimeseriesApi {
  /// Samples for one series up to [to], optionally from [from].
  ///
  /// The element type is the raw [TimeseriesData], as in the code being
  /// mirrored: one table may hold ints, another doubles, and pinning a type
  /// argument here would force a cast at every existing chart call site.
  Future<List<TimeseriesData>> queryTimeseriesData(String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from});

  /// The same window for several series in one round trip, keyed by name.
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from});

  /// At most [maxPoints] samples spanning [from]…[to].
  ///
  /// Downsampling happens where the data is, not after it crosses the link:
  /// a month of one-second samples is millions of points and a chart has
  /// hundreds of pixels.
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to, {int maxPoints = 1000});
}

/// Saved history views: their keys, graphs and time windows.
///
/// The eleven method names and their semantics are mirrored verbatim from
/// `packages/tfc_dart/lib/core/database_drift.dart:585-779` (re-measured at
/// 10-11: `createHistoryView` at `:585` through `getGlobalRetentionHorizon`
/// ending at `:779`, the whole "Convenience API for History Views" block.
/// Phase 1 recorded 393-561, which is the same eleven methods before the file
/// grew); their return
/// types are not, because those are ORM row classes out of a generated file
/// that can neither live in a zero-dependency package nor cross a socket with
/// their field names intact. The plain records in `history_view.dart` are the
/// wire shapes, and the database layer maps its rows onto them.
///
/// Every `DateTime` here is an absolute instant and should be UTC; the
/// records carry it as epoch milliseconds.
abstract interface class HistoryViewApi {
  /// Creates a view and returns its id.
  ///
  /// [keyConfigs] and [graphConfigs] stay positional-optional, matching the
  /// call sites being ported.
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]);

  /// Replaces the name, keys and configuration of view [id].
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]);

  /// Deletes view [id] and everything recorded against it.
  Future<void> deleteHistoryView(int id);

  /// Every saved view, for the view picker.
  Future<List<HistoryViewRecord>> selectHistoryViews();

  /// The plotted keys of view [viewId], keyed by key name.
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(int viewId);

  /// The per-graph configuration of view [viewId], keyed by graph index.
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(int viewId);

  /// Just the key names of view [viewId], for callers that do not need the
  /// aliases and axis placement.
  Future<List<String>> getHistoryViewKeyNames(int viewId);

  /// Saves the window [start]…[end] on view [viewId] and returns its id.
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end);

  /// Deletes the saved window [id].
  Future<void> deleteHistoryViewPeriod(int id);

  /// Every saved window on view [viewId], oldest first.
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(int viewId);

  /// The oldest instant any series is still retained for, or null when
  /// nothing has been discarded yet.
  ///
  /// A chart that scrolls past this point is showing absence of data, not
  /// absence of events, and must say so.
  Future<DateTime?> getGlobalRetentionHorizon();
}
