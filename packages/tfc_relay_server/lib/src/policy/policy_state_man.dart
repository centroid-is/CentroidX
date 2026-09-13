/// One session's view of the shared source, with the policy already applied.
///
/// **Source: 06-RESEARCH §E.2**, and orchestrator ruling OQ1 approving the
/// shape. Four placements were considered and three rejected: per-call-site
/// checks inside the handlers (six sites today, six *files* by Phase 10, and
/// the one somebody forgets is the unauthorized surface), `ServedStateMan` (a
/// test-kit peer, not production) and `LocalStateMan` (does not exist yet, and
/// is one instance shared by every panel while policy is per identity).
///
/// What is left is a decorator, and the argument for it is the one
/// `relay_session.dart:484-489` already makes about the handshake gate: the
/// check belongs at the seam every request comes through, because "a
/// per-handler check would be a rule every future plan has to remember, and
/// the one it forgot would be the method that serves plant data to a client
/// that never authenticated". `RelaySession` hands this object — never the
/// source it wraps — to both `SessionHandlers` and `ValueHandlers`, so a
/// handler added in Phase 10 cannot reach around the policy, because there is
/// no unwrapped source in scope to reach for (T-06-38).
///
/// ## What breaks in the plant without this file
///
/// Nothing today, and that is the honest answer: the shipped policy is
/// all-visible and `operate`-writes, so this object is transparent and the
/// whole suite is unchanged by it. What breaks is *later*. The first
/// deployment that needs one station not to see one tag would otherwise get
/// six hand-written checks across five files, and the hiding rule — hidden is
/// indistinguishable from nonexistent — cannot survive being spelled six
/// times. It survives being spelled once, in [keys].
///
/// ## `keys` is the hiding primitive
///
/// This is the whole design and it is worth stating plainly. Every surface
/// that can reveal a tag's existence already gates on `keys`:
///
///  * `value_handlers.dart:212` — `read`'s `api.keys.contains`.
///  * `value_handlers.dart:244` — `readFresh`'s, added by 06-04.
///  * `value_handlers.dart:276` — `readMany`'s `servable` set.
///  * `value_handlers.dart:387` — `write`'s, and with it `holdToRun`, which
///    is reachable only through the write path.
///  * `session_handlers.dart:184` + `:303-315` — `subscribe`'s `_classify`,
///    whose own doc says "Phase 6's per-key authorization attaches here: one
///    more arm, no change of shape". It turned out to need no arm at all.
///
/// So filtering one getter gives hiding on five surfaces **byte-identically to
/// a nonexistent tag**, with no edit to either handler file. That is not a
/// coincidence to be grateful for — it is why the answer for an unserved tag
/// was consolidated into one helper in 06-04 first, and it is what
/// `policy_test.dart`'s indistinguishability case exists to keep true.
///
/// ## The four sub-APIs, and all four now decide something
///
/// `browse`, `timeseries`, `historyViews` and `preferences` return wrappers.
/// They are wrapped rather than returned bare so the "no unwrapped source to
/// reach" property holds for them too: a handler that takes `api.browse` gets
/// something this session owns, not the shared object itself.
///
/// Through Phase 9 all four merely delegated, and the reason was that none of
/// their methods was on the wire — the handler table was nine names and the
/// contract legs enumerated thirteen unreachable checks, every one a sub-API
/// method. A policy call nothing can reach would read like coverage while
/// testing nothing, which `suite_integrity_test.dart:104-108` calls worse than
/// an absent one.
///
/// **10-02 registered the four `browse.*` handlers, so browse filters**;
/// **10-03 the four `timeseries.*` ones, so timeseries does too** — each with
/// cases that can see it, and each as an entry in the indistinguishability
/// loop (browse seventh, timeseries eighth). **10-04 filled in history views**,
/// which drops a hidden key from a view rather than the view from the picker,
/// and **10-05 preferences**, which is the one of the four that does not hide
/// anything: it *gates*, because a preference key is not a plant key and the
/// question it settles is who may write `key_mappings`. The rule stands
/// unchanged — a filter lands in the commit that makes the surface reachable,
/// never before it and never after.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../auth/identity.dart';
import '../error_codes.dart';
import '../error_reporter.dart';
import 'key_policy.dart';
import 'series_mapping_tally.dart';

/// Preference keys that are **gateway configuration** rather than a panel's own
/// settings, and are therefore never removed by an unrestricted clear.
///
/// Today that is one row, and it is the one the whole gateway is built from:
/// `key_mappings` is 518 KiB of routing that every panel on the site is served
/// through. See `_PolicyPreferences.clear` for what deleting it costs and why
/// the refusal is the whole answer rather than a filter.
///
/// Public and top-level so `policy_test.dart` can read the production constant
/// rather than restate the string: a second reserved key added later is then
/// covered by the existing assertions instead of silently outside them.
const Set<String> reservedPreferenceKeys = <String>{'key_mappings'};

/// Where every authorization verdict this file makes becomes a row.
///
/// D-05, and sweep §3.12 point 2 closing: a refusal at the gateway used to be
/// "the one kind of guard nobody can audit afterwards" — it left nothing
/// behind. Now a verdict writes an [AuditRecord] naming the station's
/// **resolver-verified** user (17-04b: the `who`, the `station` and the
/// `roleName` are what the server read out of the database after the digest
/// compare, never what a file claimed) and the group the master policy
/// answered.
///
/// ## The sink is fire-and-forget, and the `catchError` is not optional
///
/// The row is handed to the sink and **never awaited on the write path**, and
/// a failure lands on an attached handler rather than propagating — quoting
/// `lib/providers/access.dart`'s rule, which must hold identically here: *a
/// plant that stops because the audit database blinked is worse than a gap in
/// the trail*. `unawaited()` attaches no handler, so spelling this with
/// `unawaited(sink.record(row))` would convert a sink outage into an
/// isolate-killing unhandled error that detonates long after the write
/// already applied. The failure is logged loudly through [onError] instead,
/// because an absent audit row is the one defect nobody ever notices.
final class _DecisionLedger {
  const _DecisionLedger({
    required this.sink,
    required this.origin,
    required this.station,
    required this.onError,
  });

  final AuditSink sink;

  /// The `origin` column: `'relay'`, the value that says a row came over the
  /// wire rather than from a keyboard. A client cannot supply it — there is
  /// no wire field it could travel in (ACCESS-06, D-11).
  final String origin;

  /// The `station` column's fallback for a verdict made with no identity —
  /// a pre-hello session, unreachable from the wire today but fail-closed
  /// here rather than crashed on.
  final String station;

  /// Where a sink failure is reported. The package's one logging seam.
  final RelayErrorHandler onError;

  void record({
    required StationIdentity? identity,
    required String surface,
    required String itemKey,
    String? member,
    required AccessGroup group,
    required bool allowed,
    required String actionId,
  }) {
    final row = AuditRecord(
      at: DateTime.now(),
      who: identity?.user.username ?? 'anonymous',
      station: identity?.station ?? station,
      roleName: identity?.session.roleName ?? '',
      surface: surface,
      itemKey: itemKey,
      member: member,
      groupRequired: group.name,
      allowed: allowed,
      origin: origin,
      actionId: actionId,
    );
    try {
      // Fire-and-forget: the write path never waits for durability. The
      // handler is attached HERE, not via unawaited() — see the class doc.
      // ignore: unawaited_futures
      sink.record(row).catchError((Object error, StackTrace stack) {
        onError(error, stack, 'audit sink');
      });
    } on Object catch (error, stack) {
      // A sink that throws synchronously is the same outage one microtask
      // earlier, and gets the same answer: log it, change nothing.
      onError(error, stack, 'audit sink');
    }
  }
}

/// The group gate, shared by every sub-API that **refuses** rather than hides.
///
/// What replaced `requireOperate` — one question ("may this station
/// actuate?") asked seven times on preferences and four times on history
/// views, with the same answer every time. That shape was sweep §3.12's
/// finding: the relay graded by station role over the same rows in the same
/// `flutter_preferences` table in the same Postgres the app grades by key.
/// [_requireGroup] takes the group the policy supplies for *that* key and
/// *that* member; this mixin never knows a group's name, and the pin in
/// `policy_test.dart` keeps it that way.
///
/// **Gating, not hiding.** Everywhere else in this file a refusal that names
/// what it refused is the leak being closed. The refusing families invert it,
/// for the same reason in all of them: their reads are all-visible, so the
/// caller has already been told the thing exists and there is no existence
/// left to conceal. The two facts a client acts on differently are "fix the
/// name" (`unknownKey`) and "obtain the permission" (`forbidden`), and these
/// are the second.
mixin _GroupGate {
  /// Who is asking, read **late** — the identity is minted by `_hello`, long
  /// after this object is built.
  StationIdentity? Function() get identityOf;

  /// Where this family's verdicts become rows.
  _DecisionLedger get ledger;

  /// The `surface` column this family's rows carry — an [AccessSurface] wire
  /// name, so the surface a row is recorded under and the surface the policy
  /// is asked about are one string.
  String get gateSurface;

  /// Refuses [method] unless the asking station holds [group] — writing the
  /// deny row **before** the throw, because a refusal that leaves no trace is
  /// the one kind of guard nobody can audit afterwards.
  ///
  /// A **null [group] means open and returns immediately**: the same open
  /// answer the policy states (today, `groupForHistoryView`'s three creative
  /// members), now spoken by the policy instead of by the absence of a call.
  /// No row for an open member — nothing was decided.
  ///
  /// [may] overrides the holding check where the verdict has its own seam:
  /// the preferences door hands `KeyPolicy.canWritePreference` here, so the
  /// question still goes through the adapter every other key question goes
  /// through, while [group] — the master's answer for the row — is what a
  /// refusal names.
  ///
  /// [what] states what did *not* happen, in the caller's own vocabulary; it
  /// is what turns a refusal into something an operator can act on.
  ///
  /// Null identity is refused too, by the same `identity != null` rule
  /// [PolicyStateMan.canSee] and [PolicyStateMan.canWrite] answer by: a
  /// session between `serve` and `hello` has no station for the policy to
  /// answer about, and null means "nothing", not "everything". The state is
  /// unreachable from the wire — the handshake gate refuses every method
  /// before `hello` — but that is a property of today's gate rather than of
  /// this mixin.
  void _requireGroup(
    AccessGroup? group,
    String method,
    String what, {
    required String itemKey,
    String? member,
    bool Function(StationIdentity identity)? may,
  }) {
    if (group == null) return;
    final identity = identityOf();
    final can = may ?? ((StationIdentity id) => id.session.can(group));
    if (identity != null && can(identity)) return;
    // Deny-row-before-throw (D-05): the row is the only thing a refused
    // frame leaves behind, and it must exist even if the throw is the last
    // thing this handler does.
    ledger.record(
        identity: identity,
        surface: gateSurface,
        itemKey: itemKey,
        member: member,
        group: group,
        allowed: false,
        actionId: method);
    throw rpc.RpcException(
        ServerErrorCodes.forbidden,
        'a permission is missing, so "$method" was refused. '
        '$what: nothing was changed, so this call definitively had no effect. '
        'Do not retry — the session is fine and reading continues; what is '
        'missing is the "${group.name}" permission, and permissions change '
        'on this station\'s account in the access database rather than on '
        'the next attempt',
        data: substitutedRequest(method));
  }

  /// The allow row, recorded **after the delegation** has been initiated —
  /// the verdict was made either way, and the ordering keeps the row from
  /// ever standing in front of the write it describes.
  ///
  /// Only the write-shaped members call this. Reads record nothing on the
  /// allow path — a guard that wrote a row every time somebody read would
  /// bury the trail in itself, which is the defect `audit_trail_store.dart`
  /// refuses by design.
  void _recordAllowed(
    AccessGroup? group,
    String method, {
    required String itemKey,
    String? member,
  }) {
    if (group == null) return;
    ledger.record(
        identity: identityOf(),
        surface: gateSurface,
        itemKey: itemKey,
        member: member,
        group: group,
        allowed: true,
        actionId: method);
  }
}

/// A refusal's `data`, pre-substituted.
///
/// Copied from `value_handlers.dart` and `data_handlers.dart` rather than
/// shared across packages, for the reason those two carry:
/// `RpcException.serialize` fills an empty `data` with the offending
/// **request**, and one request carrying `1e999` then makes the error itself
/// unencodable — at which point the peer drops it and a caller with no deadline
/// waits forever.
Map<String, Object?> substitutedRequest(String method) => <String, Object?>{
      'method': method,
      'request': 'omitted: echoing a request that may carry a non-finite '
          'number is what makes the error itself unencodable, and an '
          'unencodable error on a path with no deadline is a hang',
    };

/// The shared source, seen through one session's policy.
///
/// Implements [StateManApi] and **adds no interface members**, which is how
/// 06-CONTEXT amendment 3 is satisfied by construction:
/// `api_surface_test.dart` walks the five interface *types* by mirrors and
/// never an implementation, so the 49 cannot move because of anything in this
/// file.
///
/// Written as explicit member-by-member delegation rather than with
/// `noSuchMethod` forwarding. A forwarder would silently absorb a member added
/// to `StateManApi` in a later phase — the new member would work, unpoliced,
/// and nothing would say so — which is the exact opposite of what the
/// hand-written 49 exists to make visible. Here a new member is a compile
/// error in this file, and the fix is a deliberate decision about whether it
/// needs the policy.
final class PolicyStateMan implements StateManApi {
  PolicyStateMan({
    required this.source,
    required this.policy,
    required this.resolver,
    required this.tally,
    required this.identityOf,
    this.master = const AccessPolicy(),
    this.sink = const NullAuditSink(),
    this.station = '',
    this.origin = 'relay',
    this.onAuditError = reportToStderr,
  });

  /// The shared source every session on this gateway is served from.
  ///
  /// **Named `source`, and it must not be renamed to `api`.**
  /// `tfc_relay_client/test/no_retry_test.dart:220-245` pins `api.write(` and
  /// `api.holdToRun(` at exactly one non-comment occurrence each under this
  /// package's `lib/`, because those are the gateway's only two crossings into
  /// the plant and a second one is a second actuation. A delegate field called
  /// `api` would add one of each and trip both pins — with a failure message
  /// about *retries*, on a file that has nothing to do with retrying, which is
  /// an afternoon nobody needs to spend.
  final StateManApi source;

  final KeyPolicy policy;

  /// The master system's own policy object, asked for the **group** a key or
  /// a member requires — `groupForPref`, `groupForHistoryView`,
  /// `groupForTemplate`, `groupForAdmin`, `groupForBackendConfig`.
  ///
  /// Beside [policy] rather than instead of it, and the split is deliberate:
  /// [policy] is the adapter seam every yes/no question goes through (a test
  /// scripts it; 17-11 injects a composed one), while [master] is where the
  /// *name* of a requirement comes from — the group a refusal states and an
  /// audit row's `groupRequired` column records. Under the shipped
  /// composition the two agree by construction: `AccessPolicyKeyPolicy` asks
  /// this same object. The default is the bare policy, which is not a
  /// fail-open — every surface it grades floors at a real group.
  final AccessPolicy master;

  /// Where this session's authorization verdicts become rows (D-05).
  ///
  /// [NullAuditSink] by default, so every existing composition in the
  /// workspace is unaffected: the trail is an account of decisions, never a
  /// precondition for making them. `RelayServer` grows the parameter in
  /// 17-09 and injects the real sink.
  final AuditSink sink;

  /// The `station` column's fallback for a verdict made before `hello`.
  final String station;

  /// The `origin` column: `'relay'` in production — the value that says a
  /// row came over the wire rather than from a keyboard.
  final String origin;

  /// Where a sink failure is logged. Loudly, and never propagated — see
  /// [_DecisionLedger].
  final RelayErrorHandler onAuditError;

  late final _DecisionLedger _ledger = _DecisionLedger(
      sink: sink, origin: origin, station: station, onError: onAuditError);

  /// How a node id and a table name become the plant key [canSee] is asked
  /// about.
  ///
  /// The browse and timeseries filters need it and nothing else in this class
  /// does: `keys` is already a list of plant keys, so the five surfaces that
  /// inherit hiding from it never had a translation problem. Browse walks the
  /// upstream address space, where every identifier belongs to the server that
  /// published it; timeseries is keyed by a series name, which has to become a
  /// table and a plant key before `canSee` can be asked anything. History
  /// views need no translation at all — a view is already a list of plant
  /// keys.
  ///
  /// Required, no default. See `relay_server.dart`'s `resolver` parameter.
  final SeriesResolver resolver;

  /// Where a series this gateway cannot map is recorded.
  ///
  /// **Gateway-wide, not per session**, and required for the same reason
  /// [resolver] is: a tally created here by default would reset every time a
  /// panel reconnected, which is exactly the number that has to accumulate.
  /// See [SeriesMappingTally] for why a count exists at all when the wire
  /// answer is deliberately silent.
  final SeriesMappingTally tally;

  /// Who is asking, read **late**.
  ///
  /// The `epochOf` / `ownerOf` idiom (`relay_session.dart:559`, `:576`) and
  /// for the identical reason: this object is built during the session's
  /// `_start`, and the identity is minted later, by `_hello`. A captured value
  /// would be null forever.
  ///
  /// **Nullable, and null means "nothing", not "everything".** A pre-hello
  /// session has no identity (`relay_session.dart:383-394`), so there is no
  /// station for the policy to answer about. That state is unreachable from
  /// the wire — the handshake gate refuses every key-touching method before
  /// `hello`, and `handler_table_test.dart`'s pre-hello sweep is what keeps it
  /// that way — but "unreachable" is a property of today's gate rather than of
  /// this class, and the two ways to spell an unreachable state are a `!` that
  /// crashes the session or an answer that is safe if it ever happens. This
  /// takes the second: no identity, no visibility, no writes. A gateway that
  /// showed the plant to a peer it could not name would be the failure worth
  /// preventing; a session that saw nothing before saying hello is one it
  /// could not have used anyway.
  final StationIdentity? Function() identityOf;

  /// Whether the asking station may know [key] exists.
  ///
  /// Public because it is the same question `RelaySession` needs for the
  /// write gate, and one object answering both is what "every surface
  /// consults one policy object" means. Not on [StateManApi] — see this
  /// class's doc.
  bool canSee(String key) {
    final identity = identityOf();
    return identity != null && policy.canSee(key, identity);
  }

  /// Whether the asking station may actuate [key].
  ///
  /// Consulted by `ValueHandlers` through the `canWriteKey` predicate
  /// `RelaySession` builds from it, after the existence check and before the
  /// fingerprint, the idempotency window and the outcome log.
  bool canWrite(String key) {
    final identity = identityOf();
    return identity != null && policy.canWrite(key, identity);
  }

  // -------------------------------------------------------------------------
  // StateManApi — the thirteen members plus dispose.
  // -------------------------------------------------------------------------

  /// **The hiding primitive.** See this library's doc.
  ///
  /// One `where`, and five surfaces inherit hiding from it.
  @override
  List<String> get keys => source.keys.where(canSee).toList();

  @override
  ValueListenable<DynamicValue> listen(String key) => source.listen(key);

  @override
  Stream<DynamicValue> subscribe(String key) => source.subscribe(key);

  @override
  DynamicValue? read(String key) => source.read(key);

  /// **An override, not a delegation** (§E.2 item 2).
  ///
  /// Every other read surface is answered by a handler that consults [keys]
  /// first, so a hidden tag never gets this far over the wire. This one is
  /// written out anyway because the alternative is letting the source choose
  /// the answer, and the sources disagree: `FakeStateMan` happens to answer
  /// `q:258` ("no reading yet, wait") for a tag it does not serve, while
  /// `LocalStateMan` over a real `DeviceClient` may throw. Neither is the
  /// nonexistent shape this gateway promises, and the round trip itself is a
  /// side channel — a caller who may not know the tag exists should not be
  /// able to make the plant be asked about it.
  ///
  /// `errorConfig` is the gateway's own answer for an unserved tag: 770 means
  /// "the source affirmatively said this tag is gone", which 06-04 settled as
  /// the quality `read` and `readFresh` both give it. The wire-level shape —
  /// the `rejected` map and the message — is `value_handlers.dart`'s
  /// `_unserved`, and it is reached before this method by the `keys` check
  /// there.
  @override
  Future<DynamicValue> readFresh(String key) async {
    if (!canSee(key)) {
      return DynamicValue.of(null, quality: Quality.errorConfig);
    }
    return source.readFresh(key);
  }

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) =>
      source.readMany(keys);

  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      source.write(key, value, expect: expect, cmd: cmd);

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) =>
      source.writeStatus(cmds);

  @override
  Future<HoldHandle> holdToRun(String key) => source.holdToRun(key);

  @override
  BrowseApi get browse => _PolicyBrowse(source.browse, resolver, canSee);

  @override
  TimeseriesApi get timeseries =>
      _PolicyTimeseries(source.timeseries, resolver, canSee, tally);

  @override
  HistoryViewApi get historyViews => _PolicyHistoryViews(
      source.historyViews, canSee, identityOf, _ledger,
      groupForMember: master.groupForHistoryView);

  @override
  PreferencesApi get preferences => _PolicyPreferences(
      source.preferences, identityOf, _ledger,
      groupForKey: master.groupForPref,
      mayWrite: policy.canWritePreference);

  // ------------------------------------------------------- the access families
  //
  // The four getters 17-03 added, gated as of this plan. Until now they threw
  // `UnsupportedError` — deliberately not a `forbidden`, because a `forbidden`
  // is an authorisation verdict and under D-05 every verdict writes an audit
  // row; with no gate yet, that row would have been FALSE, and a false deny
  // row is worse than a missing one because it is the kind a reviewer
  // believes. The gates exist now, so the verdicts are real and the rows are
  // true.
  //
  // Each decorator takes its source as a **thunk**, not a value, and the
  // thunk is evaluated only after the gate has passed. Two properties ride on
  // that: a refused caller may not cost a lookup (readFresh's side-channel
  // argument, §E.2 item 2), and on a composition whose source is unwired —
  // `FakeStateMan` still refuses these getters by name — the refusal a
  // wrongly-grouped caller gets is the VERDICT, never an `UnsupportedError`
  // standing in for one.

  @override
  AccessTemplateApi get accessTemplates => _PolicyAccessTemplates(
      () => source.accessTemplates, identityOf, _ledger,
      groupFor: master.groupForTemplate);

  @override
  AccessAdminApi get accessAdmin => _PolicyAccessAdmin(
      () => source.accessAdmin, identityOf, _ledger,
      groupFor: master.groupForAdmin);

  @override
  AuditApi get audit => _PolicyAudit(() => source.audit, identityOf, _ledger,
      groupFor: master.groupForAdmin);

  @override
  BackendConfigApi get backendConfig => _PolicyBackendConfig(
      () => source.backendConfig, identityOf, _ledger,
      groupFor: master.groupForBackendConfig);

  /// Delegates, and owns nothing of its own to release.
  ///
  /// The source is **one instance shared by every session** on this gateway
  /// (`relay_server.dart:213-214`: "One instance, shared" — two panels
  /// watching one motor must be served by one upstream subscription). Nothing
  /// in `RelaySession`'s teardown calls this, and nothing should: a
  /// per-session dispose of a shared source would take the whole plant off
  /// the air when one panel goes home. The delegation exists so an embedder
  /// that built one of these by hand can still release what it wrapped.
  @override
  Future<void> dispose() => source.dispose();
}

// ---------------------------------------------------------------------------
// The four sub-APIs. Browse filters as of 10-02, timeseries as of 10-03,
// history views as of 10-04, and preferences gates as of 10-05 — three that
// hide and one that refuses, and the difference is at each declaration. See
// the library doc for why each of those words is deliberate.
// ---------------------------------------------------------------------------

/// Navigating the address space, **with the hiding rule applied** (10-02).
///
/// Browse is the seventh way to ask whether a tag exists and the first that
/// does not inherit hiding from [PolicyStateMan.keys]: the other six all gate
/// on that one list of plant keys, and this one walks the *upstream* address
/// space, where a node id belongs to the server that published it rather than
/// to the plant's key namespace. So it needs a translation, and that is what
/// [SeriesResolver.keyForNode] is.
///
/// Three rules, and the second and third are the ones a reader will not guess:
///
///  1. **A hidden node is dropped from a list, never refused.** A refusal
///     names what it refused; ask about a thousand names, keep the ones
///     refused rather than absent, and the plant's address space has been
///     enumerated by a station that may not read a byte of it (T-06-36).
///  2. **Only a *variable* is asked about.** `canSee` takes a plant key and a
///     folder is not one. A node the resolver maps to no key at all — a
///     folder, an intermediate struct, a method — is not asked about and is
///     not dropped. Pruning a folder would take every tag under it off the
///     tree, including the ones the station may see, on the strength of a
///     policy entry that was never about the folder.
///  3. **A path through a hidden node is null, not truncated.** A chain that
///     stopped at the last visible node would claim an edge that is not there
///     and would announce "something you may not see is under here" as
///     clearly as a refusal would.
///
/// Written as explicit member-by-member delegation like everything else in
/// this file — **never `noSuchMethod`** (see the class doc above): a forwarder
/// would absorb an interface member added later and serve it unfiltered.
///
/// Under the shipped [AllVisibleOperatorWrites] this whole class is a no-op —
/// `canSee` is `true` for every key — which is why the six browse contract
/// checks are unchanged by it. That is the acceptance shape 06-08 established:
/// a filter must be provably invisible against the default policy.
final class _PolicyBrowse implements BrowseApi {
  const _PolicyBrowse(this._source, this._resolver, this._canSee);

  final BrowseApi _source;
  final SeriesResolver _resolver;

  /// [PolicyStateMan.canSee], passed as a function rather than as the whole
  /// decorator so this class cannot reach anything else on it.
  final bool Function(String key) _canSee;

  /// Whether this station may know [node] is in the address space.
  ///
  /// Rule 2 above, in the order the checks have to happen: kind first, then
  /// the mapping, then the policy. Reordering them would ask `canSee` about a
  /// folder id, which is a string the policy was never written about.
  bool _visible(BrowseNode node) {
    if (!node.isVariable) return true;
    final key = _resolver.keyForNode(node.id);
    if (key == null) return true;
    return _canSee(key);
  }

  @override
  Future<List<BrowseNode>> fetchRoots() async =>
      (await _source.fetchRoots()).where(_visible).toList();

  @override
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent) async =>
      (await _source.fetchChildren(parent)).where(_visible).toList();

  /// The detail of [node], or — for one this station may not see — **the
  /// answer a node that does not exist gets**.
  ///
  /// The source is not asked, for `readFresh`'s reason (§E.2 item 2): the
  /// round trip is itself a side channel, and a caller who may not know a tag
  /// exists must not be able to make the plant be asked about it. What comes
  /// back instead is built from the node the caller already holds — the
  /// description and data type travelled with it in whatever list it came out
  /// of, so echoing them discloses nothing — and carries **no reading and no
  /// struct members**, which is the shape a source gives a node it has never
  /// heard of. `policy_test.dart` pins that by *comparing the two answers*
  /// rather than by restating this sentence as a literal, so a source that
  /// changes its nonexistent shape has to change both.
  @override
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node) async {
    if (!_visible(node)) {
      return BrowseNodeDetail(
          description: node.description, dataType: node.dataType);
    }
    return _source.fetchDetail(node);
  }

  @override
  Future<List<BrowseNode>?> resolvePath(String targetId) async {
    final chain = await _source.resolvePath(targetId);
    if (chain == null) return null;
    // Rule 3: any hidden step, anywhere in the chain, and there is no path.
    return chain.every(_visible) ? chain : null;
  }
}

/// Historical samples, **with the hiding rule applied** (10-03).
///
/// Browse's translation problem, one step further on. These methods are keyed
/// by a **series name**, not by a plant key and not by a node id, so the
/// question `canSee` needs — which tag do these samples belong to — has to be
/// asked of [SeriesResolver] first. `resolve` is what is consulted rather than
/// `keyForTable`, and that is deliberate: it understands the
/// `<series>:<member>` grammar, so the policy is asked about the tag rather
/// than about a chart's way of selecting a column out of one.
///
/// **What comes back is used for the answer and never for the argument.**
/// [_visible] reads `plantKey` and discards the rest; every method below hands
/// the source **the caller's own name**, unrewritten. That is 10-REVIEW CR-01's
/// rule and the reason it is stated twice in this file — see [_visible] for
/// what happened when the table travelled down instead.
///
/// Three rules.
///
///  1. **A hidden series is an empty series** — never a refusal. Same
///     argument as everywhere else in this file: a refusal names what it
///     refused, and a station that can tell "hidden" from "nothing recorded"
///     can enumerate the historian by asking.
///  2. **A series the resolver cannot map at all is answered the same way,
///     and is counted.** This is the pairing 10-CONTEXT amendment 6 forces
///     and it is the one a later reader is most likely to try to "fix", so
///     both halves are stated here:
///
///      * The **wire** answer must be indistinguishable from a series that
///        does not exist, because a refusal naming an unmapped table would
///        enumerate the historian exactly as a `forbidden` would (T-10-12).
///      * The **gateway** must not be silent about it, because fail-closed
///        with nothing to read is a chart that renders flat for months while
///        nobody knows a table was never mapped.
///
///     The reconciliation is [SeriesMappingTally]: silence outward, a count
///     and a name inward. Making the refusal informative breaks the first
///     half; dropping the count breaks the second. Neither is an improvement.
///
///     The honest limit, from research §C.2: the mapping covers what the
///     *gateway* collects, so a chart pointed at a pre-cutover table the
///     application's own collector wrote gets nothing until the migration runs
///     or the configuration declares a read-side alias. That is the correct
///     default, and the first time it happens it will look like a database
///     problem (Trap 7). The count is what makes it one query instead of one
///     afternoon.
///  3. **An entry is still returned for every requested series on the
///     multiple path.** A hidden or unmappable series is an *empty* entry,
///     never an omission — an omission would be a perfect existence oracle,
///     and it would also break the rule the contract check names ("an absent
///     entry and an empty entry are different answers and only one of them is
///     true"). The gateway's handler builds the map from the request as well,
///     so this holds twice over; both belts are cheap.
///
/// Note the asymmetry with browse, and do not make the two uniform: an
/// unmappable *node* is left alone there, because a folder legitimately maps
/// to no key, while an unmappable *series* is fail-closed here, because a
/// series always names something recorded.
///
/// Written as explicit member-by-member delegation — **never `noSuchMethod`**
/// — for the reason the class doc above gives.
///
/// Under the shipped [AllVisibleOperatorWrites] with a resolver that maps
/// everything, this class is a no-op: which is why the three timeseries
/// contract checks are unchanged by it, and is the acceptance shape 06-08
/// established.
final class _PolicyTimeseries implements TimeseriesApi {
  const _PolicyTimeseries(this._source, this._resolver, this._canSee,
      this._tally);

  final TimeseriesApi _source;
  final SeriesResolver _resolver;

  /// [PolicyStateMan.canSee], passed as a function rather than as the whole
  /// decorator so this class cannot reach anything else on it.
  final bool Function(String key) _canSee;

  final SeriesMappingTally _tally;

  /// Whether this station may read [wireName]. **The name is not rewritten.**
  ///
  /// ## The decorator authorizes; it does not translate (10-REVIEW CR-01)
  ///
  /// This used to answer `resolved.table` and every method below handed that
  /// table down as the source's `tableName` argument. That was a **second**
  /// resolution across one seam: [TimescaleReader] treats its argument as a
  /// wire series name and resolves it itself
  /// (`timescale_reader.dart:585-589`), against a map keyed by plant key. With
  /// the deployed `gw_` prefix — `CollectionEntry.table` is `tablePrefix +
  /// name` and the default prefix is `'gw_'` (`collection_config.dart:148`) —
  /// the second lookup missed and *every* timeseries request over the pipe
  /// answered `UnknownSeries`, refused as INVALID_PARAMS naming a table the
  /// caller never sent. And the member was dropped in the same hand-off, so
  /// `<series>:<member>` — 10-CONTEXT ruling 2's whole feature, ninety of the
  /// live plant's 140 collected keys — could not work even with an empty
  /// prefix: the reader saw a bare name for a struct table and answered "Ask
  /// for one member" to a caller that had.
  ///
  /// The rule that replaces it, and the one to keep: **each layer hands the
  /// next the vocabulary it was given.** The wire speaks series names, the
  /// resolver is the only translator, and it is consulted once per layer for
  /// the question that layer owns — here, "may this station see the tag these
  /// samples belong to", which is a question about `plantKey` and never about
  /// the table.
  ///
  /// The two false paths are different facts and only one of them is recorded:
  /// an unmappable series is counted, a hidden one is not. Hiding is a
  /// deliberate configuration and needs no diagnostic; a missing mapping is a
  /// gap somebody has to close.
  ///
  /// A [FormatException] cannot arrive here from the wire — `DataHandlers`
  /// refuses a malformed series name before this is reached, which is the
  /// grammar belt — but it is caught rather than thrown, because an embedder
  /// holding this decorator directly is a caller too and a policy layer that
  /// threw on a bad name would turn a typo into a handler failure.
  bool _visible(String wireName) {
    final ResolvedSeries? resolved;
    try {
      resolved = _resolver.resolve(wireName);
    } on FormatException {
      _tally.record(wireName);
      return false;
    }
    if (resolved == null) {
      _tally.record(wireName);
      return false;
    }
    // The key, not the member: a policy is written about tags, and
    // `CN02.MOT01.speed:speed` is a chart selecting a column out of one.
    return _canSee(resolved.plantKey);
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    if (!_visible(tableName)) return const [];
    return _source.queryTimeseriesData(tableName, to,
        orderBy: orderBy, from: from);
  }

  /// Rule 3: one entry per requested name, keyed by **the name the caller
  /// used**.
  ///
  /// The source is asked only about the series that survive the filter, and
  /// only once each — a hidden series must not cost a round trip either, for
  /// `readFresh`'s reason (§E.2 item 2): the round trip is itself a side
  /// channel.
  ///
  /// **De-duplicated by the address, never by the table** (10-REVIEW CR-01).
  /// The previous spelling passed `visible.values.toSet()` — the resolved
  /// tables — which silently collapsed two different member addresses of one
  /// struct into a single query and then answered both with the same rows. Two
  /// members of one table are two different series on this wire; a `Set` of
  /// the *names* keeps them apart while still refusing to ask twice for a name
  /// a caller repeated.
  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    final visible = <String>{
      for (final name in tableNames)
        if (_visible(name)) name,
    };
    final answers = visible.isEmpty
        ? const <String, List<TimeseriesData>>{}
        : await _source.queryTimeseriesDataMultiple(visible.toList(), to,
            orderBy: orderBy, from: from);
    return {
      for (final name in tableNames)
        name: visible.contains(name) ? answers[name] ?? const [] : const [],
    };
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    if (!_visible(tableName)) return const [];
    return _source.queryTimeseriesDataDownsampled(tableName, from, to,
        maxPoints: maxPoints);
  }
}

/// Saved history views, **with the hiding rule applied** (10-04).
///
/// A view is a list of *plant keys*, so unlike browse and unlike timeseries
/// this one needs no resolver at all — [PolicyStateMan.canSee] takes the keys
/// as they come.
///
/// Three rules, and the third is a decision rather than a mechanism:
///
///  1. **A hidden key is dropped from a view; the view itself still comes
///     back.** A view that vanished would itself say a view exists — the
///     operator saved it and the picker offered it a moment ago, so its
///     disappearance is a louder statement about the key it held than the
///     key's own absence is (T-10-13). The arm that proves the difference is
///     the boundary one: a view **all** of whose keys are hidden comes back as
///     a view with an *empty* key list. Every other case passes under either
///     rule.
///  2. **Graphs are not filtered.** A graph index is not a key and there is
///     nothing to hide in a title or an axis unit. Filtering them alongside
///     the keys is the plausible over-reach, and it would leave a view whose
///     axes lost their labels for a reason nobody could find.
///  3. **A hidden key is dropped from a *save*, silently** — see
///     [_visibleKeys] for the cost, which is real and is written down there
///     rather than here because that is where somebody will stand.
///
/// [selectHistoryViews] delegates untouched, and that is not an omission:
/// `HistoryViewRecord` carries an id, a name and two timestamps and **no key
/// list**, so there is nothing on it to filter. The keys live behind
/// [getHistoryViewKeys] and [getHistoryViewKeyNames], which are the two
/// methods that do filter.
///
/// ## And since 10-REVIEW CR-03 it also **gates** — per member, as of 17-07
///
/// The three rules above are about hiding, and hiding was all this class did
/// until the review. CR-03 then put one gate — "the role a setpoint takes" —
/// on the four destructive members, and that was the relay grading by station
/// role over rows the panel grades by member: sweep §3.12, the seam between
/// two guards answering differently about one table. There is now one answer.
/// Every member asks [_groupForMember] — `AccessPolicy.groupForHistoryView`,
/// the same switch `guarded_history_views.dart` consults — and the split is
/// the app's, in **both** directions (D-04, ruled 2026-09-07): the two
/// deletes take `configure` (a tightening over the wire), and the three
/// creative members are **open**.
///
/// [createHistoryView] asks too, and its group is null today. That is not a
/// loosening: it is the same open answer it always had, now stated by the
/// policy instead of by the absence of a call — so changing
/// `guarded_history_views.dart`'s `kHistoryViewWriteGroup` from null to
/// `configure` would gate the wire in the same edit, which is the property
/// this phase was after.
///
/// Written as explicit member-by-member delegation like everything else in
/// this file — **never `noSuchMethod`**: a forwarder would absorb an interface
/// member added later and serve it unfiltered *and* ungated, which is now two
/// jobs it would be skipping rather than one.
///
/// Under the shipped [AccessPolicyKeyPolicy] and a `PermissiveTokenValidator`
/// session — which holds every group — the gates are a no-op, which is why
/// the two history-view contract checks are unchanged by them.
final class _PolicyHistoryViews with _GroupGate implements HistoryViewApi {
  const _PolicyHistoryViews(
      this._source, this._canSee, this.identityOf, this.ledger,
      {required AccessGroup? Function(String member) groupForMember})
      : _groupForMember = groupForMember;

  final HistoryViewApi _source;

  /// [PolicyStateMan.canSee], passed as a function rather than as the whole
  /// decorator so this class cannot reach anything else on it.
  final bool Function(String key) _canSee;

  /// [PolicyStateMan.identityOf], for the five gated members. See
  /// [deleteHistoryView].
  @override
  final StationIdentity? Function() identityOf;

  @override
  final _DecisionLedger ledger;

  /// `AccessPolicy.groupForHistoryView`, passed as a function for the same
  /// reason [_canSee] is. Null means **open**, and only
  /// [_GroupGate._requireGroup] interprets it.
  final AccessGroup? Function(String member) _groupForMember;

  @override
  String get gateSurface => AccessSurface.historyView.wireName;

  /// The keys of [keys] this station may see.
  ///
  /// ## On the way *out* this is rule 1. On the way *in* it is a decision.
  ///
  /// Dropping a hidden key from a **save** means an operator's save can
  /// quietly lose a key they cannot see: they edit a view somebody else built,
  /// press save, and a line disappears from the chart with nothing said. That
  /// is a real cost and it is the reason this paragraph exists.
  ///
  /// The alternative is to refuse the save, and it is worse in two ways.
  /// Refusing *and saying why* names the hidden key, which is the whole of
  /// what the hiding rule closes — the same disclosure a `forbidden` refusal
  /// is. Refusing *without* saying why turns an invisible key into an
  /// unexplainable failure: the operator sees a save that will not go through,
  /// on a view that looks complete to them, with no field to correct and
  /// nothing in the message to act on. A key silently absent is at least a
  /// difference they can see on the chart.
  ///
  /// Under [AllVisibleOperatorWrites] neither happens, so this is recorded for
  /// whoever ships per-key hiding rather than chosen against evidence. When
  /// that day comes, the honest third option is an *audit* one — save what was
  /// asked, log what was dropped, and tell the operator "some keys were not
  /// saved" without naming them — which needs a logging surface this gateway
  /// does not have yet.
  ///
  /// The read side has no such tension: a key already stored is dropped from
  /// the answer, and there was never anything to tell the caller.
  List<String> _visibleKeys(List<String> keys) =>
      keys.where(_canSee).toList();

  /// Asks the policy like its four siblings, and the policy answers **open**
  /// today — the same open answer the absence of a gate used to spell, now
  /// spoken where it can be changed in one place. See the class doc.
  @override
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]) {
    final group = _groupForMember(AccessPolicy.historyViewCreate);
    _requireGroup(group, 'history.createView', 'no view was saved',
        itemKey: AccessPolicy.historyViewCreate);
    final visible = _visibleKeys(keys);
    final applied = _source.createHistoryView(
        name, visible, _visibleConfigs(keyConfigs), graphConfigs);
    _recordAllowed(group, 'history.createView',
        itemKey: AccessPolicy.historyViewCreate);
    return applied;
  }

  /// Open at the policy today, exactly as the panel's guard leaves it: an
  /// operator renaming the view of the line they run is doing their job
  /// (D-04, both directions).
  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]) {
    final group = _groupForMember(AccessPolicy.historyViewUpdate);
    _requireGroup(group, 'history.updateView', 'view $id is unchanged',
        itemKey: AccessPolicy.historyViewUpdate, member: '$id');
    final visible = _visibleKeys(keys);
    final applied = _source.updateHistoryView(
        id, name, visible, _visibleConfigs(keyConfigs), graphConfigs);
    _recordAllowed(group, 'history.updateView',
        itemKey: AccessPolicy.historyViewUpdate, member: '$id');
    return applied;
  }

  /// The per-key configuration of the keys that survived [_visibleKeys].
  ///
  /// Filtered with them rather than passed through: a configuration entry
  /// carries its own key, so leaving one behind would write a hidden key's
  /// name into a row the key itself never reached.
  Map<String, HistoryViewKeyRecord>? _visibleConfigs(
      Map<String, HistoryViewKeyRecord>? configs) {
    if (configs == null) return null;
    return {
      for (final entry in configs.entries)
        if (_canSee(entry.key)) entry.key: entry.value,
    };
  }

  /// **Gated** (10-REVIEW CR-03), and this is where the argument lives.
  ///
  /// Until the review, `_PolicyHistoryViews` filtered *keys* and gated
  /// *nothing*: all five mutators delegated straight through with no identity
  /// consulted, and the handlers above them added no check either. The only
  /// thing between the wire and this DELETE was `RelaySession`'s handshake
  /// gate, which asks whether a station said `hello` — not what it may do.
  ///
  /// The asymmetry that settles it, in one file: a `view`-role wall display was
  /// **refused** `preferences.setBool('svn.theme.dark', true)` and could
  /// **delete every saved history view in the plant**, one
  /// `history.deleteView{id: n}` at a time. The rows are not the gateway's —
  /// `history_view_store.dart:56-59` records them as "four small configuration
  /// tables the application's HMI has always written", so the target is shared
  /// plant data an engineer built by hand and that no other surface can
  /// restore. There is no idempotency id, no three-state outcome and no audit
  /// trail, and because `_viewId` deliberately accepts any int without bounding
  /// it (`data_handlers.dart:968-978`), enumeration of live ids by delete was
  /// free.
  ///
  /// 10-04 recorded the absence as deliberate, per 10-CONTEXT's "chart
  /// configuration, not plant state". **That reasoning holds for
  /// [createHistoryView] and it does not hold here.** Creating a view of your
  /// own costs nobody anything; deleting one destroys work that was not yours,
  /// and no reading of "not plant state" makes that a read.
  ///
  /// As of 17-07 the group is the **policy's answer, per member** —
  /// `configure` for the two deletes, matching what the panel's guard has
  /// always demanded (D-04) — rather than CR-03's one-size gate. The reads —
  /// [selectHistoryViews], [getHistoryViewKeys], [getHistoryViewGraphs],
  /// [getHistoryViewKeyNames], [listHistoryViewPeriods] and
  /// [getGlobalRetentionHorizon] — stay ungated by design; they are bounded
  /// instead, which is the other half of the review's finding (WR-05).
  ///
  /// Under a `PermissiveTokenValidator` session, which holds every group,
  /// this gate is a no-op — which is why the two history-view contract
  /// checks are unchanged by it, and is the acceptance shape 06-08
  /// established.
  @override
  Future<void> deleteHistoryView(int id) {
    final group = _groupForMember(AccessPolicy.historyViewDelete);
    _requireGroup(group, 'history.deleteView', 'view $id is still saved',
        itemKey: AccessPolicy.historyViewDelete, member: '$id');
    final applied = _source.deleteHistoryView(id);
    _recordAllowed(group, 'history.deleteView',
        itemKey: AccessPolicy.historyViewDelete, member: '$id');
    return applied;
  }

  /// Delegates. See the class doc: there are no keys on a
  /// [HistoryViewRecord] to filter, and the view itself is never hidden.
  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() =>
      _source.selectHistoryViews();

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(
      int viewId) async {
    final keys = await _source.getHistoryViewKeys(viewId);
    return {
      for (final entry in keys.entries)
        if (_canSee(entry.key)) entry.key: entry.value,
    };
  }

  /// Delegates. Rule 2: a graph index is not a key.
  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(int viewId) =>
      _source.getHistoryViewGraphs(viewId);

  /// The same filter as [getHistoryViewKeys], because the two are two reads of
  /// one row set and a caller picks whichever it needs. One fitted and the
  /// other forgotten would hide a key from the legend and hand it to the
  /// chart.
  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async =>
      _visibleKeys(await _source.getHistoryViewKeyNames(viewId));

  /// Open at the policy today, matching the panel: bookmarking eight hours
  /// you want to look at again is an operator doing their job (D-04). The
  /// unbounded-row-factory concern CR-03 raised is real and is answered
  /// where the panel answers it — auditing, and [listHistoryViewPeriods]
  /// being a caller-grown response (WR-05) — not by a gate the app does not
  /// have.
  @override
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end) {
    final group = _groupForMember(AccessPolicy.historyViewAddPeriod);
    _requireGroup(group, 'history.addPeriod',
        'no window was added to view $viewId',
        itemKey: AccessPolicy.historyViewAddPeriod, member: '$viewId');
    final applied = _source.addHistoryViewPeriod(viewId, name, start, end);
    _recordAllowed(group, 'history.addPeriod',
        itemKey: AccessPolicy.historyViewAddPeriod, member: '$viewId');
    return applied;
  }

  /// **Gated at `configure`** — the member the relay and the panel used to
  /// grade *differently*, now agreeing. See [deleteHistoryView].
  @override
  Future<void> deleteHistoryViewPeriod(int id) {
    final group = _groupForMember(AccessPolicy.historyViewDeletePeriod);
    _requireGroup(group, 'history.deletePeriod', 'window $id is still saved',
        itemKey: AccessPolicy.historyViewDeletePeriod, member: '$id');
    final applied = _source.deleteHistoryViewPeriod(id);
    _recordAllowed(group, 'history.deletePeriod',
        itemKey: AccessPolicy.historyViewDeletePeriod, member: '$id');
    return applied;
  }

  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(int viewId) =>
      _source.listHistoryViewPeriods(viewId);

  @override
  Future<DateTime?> getGlobalRetentionHorizon() =>
      _source.getGlobalRetentionHorizon();
}

/// Stored preferences: **anyone authenticated may read them, and writing one
/// takes the group the app's own table answers for THAT key** (17-07,
/// 17-CONTEXT D-03; sweep §3.12 point 1 closed).
///
/// The least obvious of the four seams, because a preference key is not a
/// plant key: `svn.chart.maxPoints` names a row in the gateway's own settings
/// store. 10-05 settled that preferences are policed by identity at all;
/// what it left was ONE question — "may this station actuate?" — asked about
/// every key alike.
///
/// ## Graded by key now, and why that closes a seam rather than adds a rule
///
/// **`key_mappings`.** That one preference row is the gateway's own routing
/// configuration — 518 KiB of it — and a station that can `setString` it
/// re-points the plant's tag map for every panel on the site. The previous
/// doc here argued the `operate` floor was "one rule, not seven copies of
/// it", and named the fix it declined to build: *"a
/// `canWritePreference(String key, Identity)` on [KeyPolicy] would be a
/// second policy surface"*. The fix landed (17-04), and it is not a second
/// surface: [KeyPolicy.canWritePreference] asks `kPrefAccessRules` — the
/// same thirty-four rows the app has graded these keys by since Phase 3, in
/// the same `flutter_preferences` table in the same Postgres. The
/// disagreement the floor left behind was not a hole, it was a **seam
/// between two guards answering differently about one table**, and there is
/// now one answer: `key_mappings` takes `configure` here exactly as it does
/// at a panel (D-03, ruled 2026-09-07 — the cost, an `operate`-only station
/// losing key-mapping saves over the wire, was accepted by name).
///
/// ## The refusal is `forbidden`, and here that is the *correct* answer
///
/// Everywhere else in this file a refusal that names what it refused is the
/// leak being closed: answer `forbidden` for a hidden tag and a station can
/// enumerate the plant by asking. Preferences invert that, because **reads are
/// all-visible**. A station that is refused a write has already read the key,
/// or could have; there is no existence left to conceal, and the two facts a
/// client acts on differently are "fix the key name" (`unknownKey`) and
/// "obtain the permission" (`forbidden`). This is the second, and it is the one
/// place in Phase 10 where saying so out loud is right.
///
/// The refusal is also **pre-effect**: raised before the source is touched, in
/// the same shape `value_handlers.dart:445-455` raises it for a plant write —
/// `ServerErrorCodes.forbidden` with a pre-substituted `data`, never
/// `RpcException.invalidParams`, because a refusal with no `data` is the one
/// `serialize` fills in with the offending request (the 02-05 hang). A gate
/// that fired after the write had landed would not be a gate; for
/// `key_mappings` it would be a report that the tag map has already moved.
///
/// ## Secret material is impossible by construction, and not because of this
///
/// Worth stating at the gate, because the two are easy to conflate and the
/// mistake is one-directional. This class is about `key_mappings`. It is **not**
/// what keeps credentials off the pipe: `PreferencesApi` simply omits the
/// `{bool secret = false}` parameter the concrete `Preferences` carries at
/// twelve sites, so there is no route from this wire to the secure store at
/// all, and `api_surface_test.dart` fails if any wire interface ever declares a
/// parameter with that name (SEC-01, T-10-18). A reader who reads this gate as
/// "secrets are handled" will eventually restore the parameter behind it.
///
/// Ruling 1 is **resolved**, not open: the user's 2026-09-02 morning review
/// kept `key_mappings` wire-writable behind this gate, on the argument that the
/// audit trail is what makes a gated configuration write defensible, and closed
/// the off-wire option.
///
/// Written as explicit member-by-member delegation like everything else in this
/// file — **never `noSuchMethod`**: a forwarder would absorb a mutator added to
/// the interface later and serve it ungated, which is this class's whole job.
///
/// Under a `PermissiveTokenValidator` session, which holds every group, the
/// gates are a no-op — which is why both preference contract checks pass
/// through them unchanged, and is the acceptance shape 06-08 established.
final class _PolicyPreferences with _GroupGate implements PreferencesApi {
  const _PolicyPreferences(this._source, this.identityOf, this.ledger,
      {required AccessGroup Function(String key) groupForKey,
      required bool Function(String key, StationIdentity identity) mayWrite})
      : _groupForKey = groupForKey,
        _mayWrite = mayWrite;

  final PreferencesApi _source;

  /// [PolicyStateMan.identityOf], passed as a function rather than as the
  /// whole decorator so this class cannot reach anything else on it.
  @override
  final StationIdentity? Function() identityOf;

  @override
  final _DecisionLedger ledger;

  @override
  String get gateSurface => AccessSurface.pref.wireName;

  /// `AccessPolicy.groupForPref` — the group a key *requires*, which is what
  /// a refusal states and an audit row's `groupRequired` column records.
  /// Never null: the table fails closed to a real group for anything
  /// unmatched.
  final AccessGroup Function(String key) _groupForKey;

  /// [KeyPolicy.canWritePreference] — the **verdict**, asked through the
  /// adapter so every preference question goes through the same seam every
  /// tag question does. Under the shipped composition the two functions here
  /// agree by construction (the adapter asks the same master); a scripted
  /// double can split them, which is exactly what makes the write-refusal
  /// arms falsifiable (D-12).
  final bool Function(String key, StationIdentity identity) _mayWrite;

  /// The gate every mutator takes, spelled once: the group for the row, the
  /// adapter for the verdict, the deny row before the throw, and the allow
  /// row after the delegation.
  Future<T> _graded<T>(
      String method, String key, String what, Future<T> Function() delegate) {
    final group = _groupForKey(key);
    _requireGroup(group, method, what,
        itemKey: key, may: (identity) => _mayWrite(key, identity));
    final applied = delegate();
    _recordAllowed(group, method, itemKey: key);
    return applied;
  }


  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _source.getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _source.getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key) => _source.getBool(key);

  @override
  Future<int?> getInt(String key) => _source.getInt(key);

  @override
  Future<double?> getDouble(String key) => _source.getDouble(key);

  @override
  Future<String?> getString(String key) => _source.getString(key);

  @override
  Future<List<String>?> getStringList(String key) =>
      _source.getStringList(key);

  @override
  Future<bool> containsKey(String key) => _source.containsKey(key);

  // The seven mutators. Each takes [_graded] with its own key, so a reader
  // adding an eighth sees what the other seven do — and so there is exactly
  // one spelling of the gate to get wrong.

  @override
  Future<void> setBool(String key, bool value) =>
      _graded('preferences.setBool', key, 'nothing was stored under "$key"',
          () => _source.setBool(key, value));

  @override
  Future<void> setInt(String key, int value) =>
      _graded('preferences.setInt', key, 'nothing was stored under "$key"',
          () => _source.setInt(key, value));

  @override
  Future<void> setDouble(String key, double value) =>
      _graded('preferences.setDouble', key, 'nothing was stored under "$key"',
          () => _source.setDouble(key, value));

  @override
  Future<void> setString(String key, String value) =>
      // The one D-03 is about: `key_mappings` is a string, it is the
      // gateway's own routing configuration, and its grading is the table's.
      _graded('preferences.setString', key, 'nothing was stored under "$key"',
          () => _source.setString(key, value));

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _graded('preferences.setStringList', key,
          'nothing was stored under "$key"',
          () => _source.setStringList(key, value));

  @override
  Future<void> remove(String key) =>
      // Removing a row is writing it: the same key, the same group.
      _graded('preferences.remove', key, '"$key" is still stored',
          () => _source.remove(key));

  /// **An unrestricted clear is refused** (10-REVIEW CR-02) — and that
  /// refusal is a **volume control, not a permission**, which is why it
  /// survives the per-key grading untouched: a session holding every group
  /// the master system has is still refused this shape of the call. The
  /// allow-listed form is graded per named key, exactly as [remove] is.
  ///
  /// Two facts make this worse than the other six mutators, and both are
  /// reasons to refuse rather than to log:
  ///
  ///  * **The damage outlives the call.** `CollectionPlanResolver`'s three maps
  ///    are built once at construction and do not follow a live
  ///    `KeyRouter.applyKeyMappings` (`collection_plan_resolver.dart:51-60`).
  ///    So after a `clear()` the running gateway keeps resolving series against
  ///    a plan whose source row no longer exists — it looks healthy — and the
  ///    **next restart** comes up with an empty keymapping, no collection plan
  ///    and a resolver that refuses everything. Cause and symptom separated by
  ///    a reboot is the hardest shape there is to diagnose.
  ///  * **Nothing else restores it.** `key_mappings` is 518 KiB of hand-built
  ///    routing; reconnecting does not bring it back, and no other surface on
  ///    this wire can rewrite it in one call.
  ///
  /// Refusing is the honest default for a call whose safe form costs the caller
  /// one parameter, and the message names the parameter. The allow-listed form
  /// still works and still takes `operate`, so a settings page emptying its own
  /// section is unaffected — `data_services_contract.dart`'s
  /// `checkPreferenceClearCarriesItsAllowList` is what holds that open, on all
  /// five legs, and is the check the review found missing entirely.
  ///
  /// The alternative considered and rejected was
  /// `allowList ?? (await getKeys()).difference(reservedKeys)` plus a log line:
  /// it keeps an unrestricted clear callable, but it also keeps every *other*
  /// preference in one un-undoable call, and it makes the reserved set a thing
  /// a caller cannot see from the interface. A refusal that says which
  /// parameter to add is the shorter path to the same place.
  ///
  /// The refusal is **pre-effect**, like every other one in this class: raised
  /// before the source is touched, with a pre-substituted `data` so
  /// `RpcException.serialize` cannot fill it with a request carrying `1e999`
  /// (the 02-05 hang).
  @override
  Future<void> clear({Set<String>? allowList}) {
    if (allowList != null) {
      // Graded per named key: clearing a row is writing it, and a list that
      // mixes gradings is refused at its most demanding member — the first
      // key the session's groups do not cover, named in the refusal.
      for (final key in allowList) {
        _requireGroup(_groupForKey(key), 'preferences.clear',
            '"$key" is still stored — nothing was removed',
            itemKey: key, may: (identity) => _mayWrite(key, identity));
      }
      final applied = _source.clear(allowList: allowList);
      for (final key in allowList) {
        _recordAllowed(_groupForKey(key), 'preferences.clear', itemKey: key);
      }
      return applied;
    }
    throw rpc.RpcException(
        ServerErrorCodes.forbidden,
        'preferences.clear with no allowList would remove every preference '
        'this gateway holds, ${reservedPreferenceKeys.join(', ')} included — '
        'the routing '
        'configuration the whole gateway is built from, which is not restored '
        'by reconnecting and whose loss does not show until the next restart. '
        'Nothing was removed, so this call definitively had no effect. Do not '
        'retry it unchanged: name the keys to clear in "allowList", which is '
        'the same call without the blast radius',
        data: substitutedRequest('preferences.clear'));
  }

  @override
  Stream<String> get onPreferencesChanged => _source.onPreferencesChanged;
}

// ---------------------------------------------------------------------------
// The four access families (17-03's getters, gated as of 17-07).
//
// Shared shape, worth stating once: every decorator takes its source as a
// THUNK evaluated only after the gate has passed — a refused caller may not
// cost a lookup (§E.2 item 2's side-channel argument), and on a composition
// whose source is unwired the refusal a wrongly-grouped caller gets is the
// verdict, never an `UnsupportedError` standing in for one. Every gate asks
// the injected group function — `AccessPolicy.groupForTemplate` /
// `groupForAdmin` / `groupForBackendConfig` — and never names a group.
// Writes record allow rows; reads record nothing on the allow path; every
// refusal records its deny row before the throw (D-05).
//
// Explicit member-by-member delegation, never `noSuchMethod`, for the same
// reason as everything else in this file.
// ---------------------------------------------------------------------------

/// Access templates and their bindings: the three reads open (a panel renders
/// the templates screen before anyone signs in, matching the store), the six
/// writes gated — including [bind] and [unbind], because pointing a key at a
/// template changes who may write that key just as much as editing the
/// template does.
final class _PolicyAccessTemplates with _GroupGate
    implements AccessTemplateApi {
  const _PolicyAccessTemplates(this._source, this.identityOf, this.ledger,
      {required AccessGroup Function(String member) groupFor})
      : _groupFor = groupFor;

  final AccessTemplateApi Function() _source;

  @override
  final StationIdentity? Function() identityOf;

  @override
  final _DecisionLedger ledger;

  @override
  String get gateSurface => AccessSurface.accessAdmin.wireName;

  /// `AccessPolicy.groupForTemplate`. The member name is passed so the call
  /// site says what it is asking about, exactly as the store does.
  final AccessGroup Function(String member) _groupFor;

  Future<T> _write<T>(String memberConstant, String wireMethod, String what,
      String subject, Future<T> Function() delegate) {
    final group = _groupFor(memberConstant);
    _requireGroup(group, wireMethod, what,
        itemKey: 'access_template.$memberConstant', member: subject);
    final applied = delegate();
    _recordAllowed(group, wireMethod,
        itemKey: 'access_template.$memberConstant', member: subject);
    return applied;
  }

  @override
  Future<List<AccessTemplate>> list() => _source().list();

  @override
  Future<Map<String, String>> bindings() => _source().bindings();

  @override
  Future<List<String>> keysBoundTo(String templateName) =>
      _source().keysBoundTo(templateName);

  @override
  Future<void> create(AccessTemplate value, {String? reason}) =>
      _write(AccessPolicy.templateCreate, AccessMethods.templateCreate,
          'template "${value.name}" was not created', value.name,
          () => _source().create(value, reason: reason));

  @override
  Future<void> update(AccessTemplate value, {String? reason}) =>
      _write(AccessPolicy.templateUpdate, AccessMethods.templateUpdate,
          'template "${value.name}" is unchanged', value.name,
          () => _source().update(value, reason: reason));

  @override
  Future<void> rename(String from, String to, {String? reason}) =>
      _write(AccessPolicy.templateRename, AccessMethods.templateRename,
          'template "$from" keeps its name', from,
          () => _source().rename(from, to, reason: reason));

  @override
  Future<void> delete(String name, {String? reason}) =>
      _write(AccessPolicy.templateDelete, AccessMethods.templateDelete,
          'template "$name" is still stored', name,
          () => _source().delete(name, reason: reason));

  @override
  Future<void> bind(String keyName, String templateName, {String? reason}) =>
      _write(AccessPolicy.templateBind, AccessMethods.templateBind,
          '"$keyName" is not bound', keyName,
          () => _source().bind(keyName, templateName, reason: reason));

  @override
  Future<void> unbind(String keyName, {String? reason}) =>
      _write(AccessPolicy.templateUnbind, AccessMethods.templateUnbind,
          '"$keyName" keeps its binding', keyName,
          () => _source().unbind(keyName, reason: reason));
}

/// Roles and accounts: nine writes gated, [roles] an open read matching the
/// store — and [listUsers] gated, which is this decorator departing from the
/// store's read policy **on an owner ruling** (2026-09-08):
///
/// The store leaves its two reads ungated on the reasoning that a read is not
/// an authorization change, and the app's deferral of a read gate was
/// reasoned for a panel already holding Postgres credentials — a reader who
/// can open the database gains nothing from a UI gate. Over the wire that
/// premise is FALSE: a valid token is not database credentials, and an
/// ungated [listUsers] would hand any station — view-only included — every
/// username and role in the plant. The group asked is still the master's own
/// answer for this whole concern (`groupForAdmin` → the one group that
/// answers for who-may-do-what), so this is the master's rule asked at the
/// wire, not a second rule.
///
/// **No secret in any refusal.** [createUser] and [setUserPassword] carry a
/// password in their params objects; the `what` strings below name the
/// SUBJECT and never touch the credential, and [_DecisionLedger]'s row has no
/// field a value ever flows into from here. `policy_access_gate_test.dart`
/// drives a distinctive password through both refusals and sweeps the
/// message, the error data and every row field for it (F-B, F-G).
final class _PolicyAccessAdmin with _GroupGate implements AccessAdminApi {
  const _PolicyAccessAdmin(this._source, this.identityOf, this.ledger,
      {required AccessGroup Function(String member) groupFor})
      : _groupFor = groupFor;

  final AccessAdminApi Function() _source;

  @override
  final StationIdentity? Function() identityOf;

  @override
  final _DecisionLedger ledger;

  @override
  String get gateSurface => AccessSurface.accessAdmin.wireName;

  /// `AccessPolicy.groupForAdmin`.
  final AccessGroup Function(String member) _groupFor;

  /// The gate for the nine writes. [itemKey] is the trail's own eight-string
  /// admin vocabulary (`audit.dart`'s class doc), so a relay-minted row
  /// filters under the same chips a panel-minted one does; [subject] is the
  /// account or role acted upon and goes in `member`, never in the itemKey.
  Future<T> _write<T>(String memberConstant, String wireMethod, String what,
      String itemKey, String subject, Future<T> Function() delegate) {
    final group = _groupFor(memberConstant);
    _requireGroup(group, wireMethod, what, itemKey: itemKey, member: subject);
    final applied = delegate();
    _recordAllowed(group, wireMethod, itemKey: itemKey, member: subject);
    return applied;
  }

  /// An open read, matching the store: a role's name and group set is what
  /// the templates screen renders before anyone signs in. The FIX-1 ruling
  /// names `listUsers` and the trail; widening it silently would be this
  /// file deciding policy.
  @override
  Future<List<AccessRole>> roles() => _source().roles();

  /// **Gated, unlike the store's read** — see the class doc.
  @override
  Future<List<UserSummary>> listUsers() {
    _requireGroup(_groupFor('listUsers'), AccessMethods.adminListUsers,
        'no accounts were listed',
        itemKey: 'listUsers');
    return _source().listUsers();
  }

  @override
  Future<void> createRole(AccessRole role, {String? reason}) =>
      _write(AccessPolicy.adminCreateRole, AccessMethods.adminCreateRole,
          'role "${role.name}" was not created', 'role.create', role.name,
          () => _source().createRole(role, reason: reason));

  @override
  Future<void> updateRole(AccessRole role, {String? reason}) =>
      _write(AccessPolicy.adminUpdateRole, AccessMethods.adminUpdateRole,
          'role "${role.name}" is unchanged', 'role.update', role.name,
          () => _source().updateRole(role, reason: reason));

  @override
  Future<void> deleteRole(String name, {String? reason}) =>
      _write(AccessPolicy.adminDeleteRole, AccessMethods.adminDeleteRole,
          'role "$name" is still stored', 'role.delete', name,
          () => _source().deleteRole(name, reason: reason));

  @override
  Future<void> renameRole(String from, String to, {String? reason}) =>
      _write(AccessPolicy.adminRenameRole, AccessMethods.adminRenameRole,
          'role "$from" keeps its name', 'role.rename', from,
          () => _source().renameRole(from, to, reason: reason));

  /// A whitelist write is `users`, like every other member here.
  ///
  /// Not `configure`, and the distinction is the point: a page whitelist is
  /// authorization data, so grading it with the page editor would let anybody
  /// who can author a page re-scope who sees which pages. The direct-mode
  /// store makes the same call in the same words; this decorator is the
  /// server-side half of it, and it is the half that actually enforces.
  @override
  Future<void> setRolePages(String subject, Set<String>? pages,
          {String? reason}) =>
      _write(
          AccessPolicy.adminSetRolePages,
          AccessMethods.adminSetRolePages,
          'role "$subject" keeps its pages',
          'role.pages',
          subject,
          () => _source().setRolePages(subject, pages, reason: reason));

  @override
  Future<void> setUserPages(String subject, Set<String>? pages,
          {String? reason}) =>
      _write(
          AccessPolicy.adminSetUserPages,
          AccessMethods.adminSetUserPages,
          'account "$subject" keeps its pages',
          'user.pages',
          subject,
          () => _source().setUserPages(subject, pages, reason: reason));

  /// The `what` names the subject and NEVER the credential riding beside it
  /// in [params] — see the class doc.
  @override
  Future<void> createUser(NewUserParams params) =>
      _write(AccessPolicy.adminCreateUser, AccessMethods.adminCreateUser,
          'account "${params.subject}" was not created', 'user.create',
          params.subject, () => _source().createUser(params));

  @override
  Future<void> deleteUser(String subject, {String? reason}) =>
      _write(AccessPolicy.adminDeleteUser, AccessMethods.adminDeleteUser,
          'account "$subject" is still stored', 'user.delete', subject,
          () => _source().deleteUser(subject, reason: reason));

  @override
  Future<void> setUserRole(String subject, String newRole, {String? reason}) =>
      _write(AccessPolicy.adminSetUserRole, AccessMethods.adminSetUserRole,
          'account "$subject" keeps its role', 'user.role', subject,
          () => _source().setUserRole(subject, newRole, reason: reason));

  @override
  Future<void> setUserStationAccount(String subject, bool value,
          {String? reason}) =>
      _write(
          AccessPolicy.adminSetUserStationAccount,
          AccessMethods.adminSetUserStationAccount,
          'account "$subject" keeps its station marking',
          'user.station_account',
          subject,
          () => _source()
              .setUserStationAccount(subject, value, reason: reason));

  /// The `what` names the subject and NEVER the credential riding beside it
  /// in [params] — see the class doc.
  @override
  Future<void> setUserPassword(SetUserPasswordParams params) =>
      _write(
          AccessPolicy.adminSetUserPassword,
          AccessMethods.adminSetUserPassword,
          'the password of "${params.subject}" is unchanged',
          'user.password',
          params.subject,
          () => _source().setUserPassword(params));
}

/// The audit trail's three reads, **all gated** — the other half of the FIX-1
/// ruling [_PolicyAccessAdmin.listUsers] carries: over the wire, an ungated
/// trail is every write anyone ever made, every username and every denial,
/// readable by any station holding any valid token. The group is
/// `groupForAdmin`'s answer — [AccessSurface.accessAdmin]'s doc says roles,
/// users and templates "all answer to `users`", and the trail OF that concern
/// answers to the same group.
///
/// An ALLOWED read records nothing: reading the trail must not grow the
/// trail, which is `audit_trail_store.dart`'s refusal-by-design. A REFUSED
/// read records its deny row — a station probing the trail is exactly the
/// event the trail exists to show, and no key existence is being concealed
/// on this family (the family's presence is public wire vocabulary).
final class _PolicyAudit with _GroupGate implements AuditApi {
  const _PolicyAudit(this._source, this.identityOf, this.ledger,
      {required AccessGroup Function(String member) groupFor})
      : _groupFor = groupFor;

  final AuditApi Function() _source;

  @override
  final StationIdentity? Function() identityOf;

  @override
  final _DecisionLedger ledger;

  @override
  String get gateSurface => AccessSurface.accessAdmin.wireName;

  final AccessGroup Function(String member) _groupFor;

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) {
    _requireGroup(_groupFor('entries'), AccessMethods.auditEntries,
        'no trail rows were read',
        itemKey: 'entries');
    return _source().entries(query);
  }

  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) {
    _requireGroup(
        _groupFor('memberCountsByAction'),
        AccessMethods.auditMemberCountsByAction,
        'no counts were read',
        itemKey: 'memberCountsByAction');
    return _source().memberCountsByAction(actionIds);
  }

  @override
  Future<List<String>> distinctWho() {
    _requireGroup(_groupFor('distinctWho'), AccessMethods.auditDistinctWho,
        'no names were read',
        itemKey: 'distinctWho');
    return _source().distinctWho();
  }
}

/// The backend's own configuration: **all five members gated, reads
/// included** (ACCESS-04, D-10) — the document is the plant's server list and
/// PLC addresses, and `BackendConfigApi`'s own doc grades every member. The
/// group is `groupForBackendConfig`'s, which derives from the
/// `state_man_config` row of `kPrefAccessRules` so the two transports onto
/// one concern cannot disagree.
///
/// The `relay` section's write refusal — you do not edit the socket over the
/// socket — is the far end's, by name, per the interface doc; this decorator
/// answers only who may ask at all.
final class _PolicyBackendConfig with _GroupGate implements BackendConfigApi {
  const _PolicyBackendConfig(this._source, this.identityOf, this.ledger,
      {required AccessGroup Function(String section) groupFor})
      : _groupFor = groupFor;

  final BackendConfigApi Function() _source;

  @override
  final StationIdentity? Function() identityOf;

  @override
  final _DecisionLedger ledger;

  @override
  String get gateSurface => AccessSurface.backendConfig.wireName;

  final AccessGroup Function(String section) _groupFor;

  @override
  Future<BackendConfigDocument> read() {
    _requireGroup(_groupFor('read'), AccessMethods.configRead,
        'the configuration was not read',
        itemKey: AccessPolicy.stateManConfigPrefKey, member: 'read');
    return _source().read();
  }

  @override
  Future<ConfigValidation> validate(String configJson) {
    _requireGroup(_groupFor('validate'), AccessMethods.configValidate,
        'nothing was validated',
        itemKey: AccessPolicy.stateManConfigPrefKey, member: 'validate');
    return _source().validate(configJson);
  }

  @override
  Future<void> write(String configJson, {String? reason}) {
    final group = _groupFor('write');
    _requireGroup(group, AccessMethods.configWrite,
        'the configuration is unchanged',
        itemKey: AccessPolicy.stateManConfigPrefKey, member: 'write');
    final applied = _source().write(configJson, reason: reason);
    _recordAllowed(group, AccessMethods.configWrite,
        itemKey: AccessPolicy.stateManConfigPrefKey, member: 'write');
    return applied;
  }

  @override
  Future<BackendConfigDocument?> previous() {
    _requireGroup(_groupFor('previous'), AccessMethods.configPrevious,
        'the previous configuration was not read',
        itemKey: AccessPolicy.stateManConfigPrefKey, member: 'previous');
    return _source().previous();
  }

  @override
  Future<void> restorePrevious({String? reason}) {
    final group = _groupFor('restorePrevious');
    _requireGroup(group, AccessMethods.configRestorePrevious,
        'nothing was restored',
        itemKey: AccessPolicy.stateManConfigPrefKey,
        member: 'restorePrevious');
    final applied = _source().restorePrevious(reason: reason);
    _recordAllowed(group, AccessMethods.configRestorePrevious,
        itemKey: AccessPolicy.stateManConfigPrefKey,
        member: 'restorePrevious');
    return applied;
  }
}
