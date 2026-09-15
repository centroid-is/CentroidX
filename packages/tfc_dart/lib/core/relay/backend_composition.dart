/// The one object graph `centroidx-backend` serves the relay WebSocket from.
///
/// Every collaborator this phase built — the live values over the pipe, the
/// freshness sweep, the browse tree, the series resolver, the three data
/// services over the backend's own `Database`, the write router — is judged in
/// isolation by its own plan. None of that says anything about the graph the
/// **binary** constructs, and last milestone the graph the binary constructed
/// was the only one that shipped and the only one nothing had ever assembled
/// (Phase 10's CR-01, restated by 13-CONTEXT as criterion 4).
///
/// So there is exactly one function that builds it, [composeBackendRelay], and
/// exactly two callers: `bin/main.dart` and
/// `test/core/relay/backend_composition_test.dart`. A structural arm in that
/// test asserts the first of those appears **once**, because two composition
/// sites is two graphs and only one of them would be under test.
///
/// ## Why this file is under `lib/` and not in `bin/`
///
/// `bin/` is not addressable by any `package:` URI, so nothing in it can be
/// imported by a test. `tfc_relay_local`'s `buildGateway`
/// (`gateway_config.dart:586`) is here for the same reason and records the same
/// argument. That is not a style preference: it is the entire mechanism by
/// which criterion 4 is satisfiable at all. Moving any part of this graph into
/// `main` puts that part beyond the reach of every test in the workspace.
///
/// ## Allocation only. Nothing here binds, connects or starts.
///
/// [composeBackendRelay] returns the server **unstarted**, the way
/// `buildGateway` returns a gateway whose links are not open. Binding is the
/// caller's, which is what lets `bin/main.dart` print the boot line before it
/// binds — and lets the composition test assemble the whole graph without
/// opening a port.
///
/// ## What this file must never grow
///
/// A teardown on the shutdown path. [BackendRelayComposition.dispose] exists
/// for tests and for nothing else; `bin/main.dart`'s `_shutdown` awaits
/// nothing and must never learn to close this server.
/// `test/core/pipe_shutdown_structure_test.dart` bans `.close(` anywhere in
/// `bin/*.dart` for that reason, and the process is about to `exit(0)` — the
/// sockets go with it.
///
/// The one thing the shutdown path *does* reach this graph for is
/// `RelayServer.announceDraining()` — a queued 4002 close frame per socket,
/// releasing nothing and awaiting nothing, so a panel can tell a planned
/// restart from a broken network (rig probe P9). Announcing is not closing.
library;

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart'
    show
        AccessGroup,
        AccessPolicy,
        AccessRole,
        AuditSink,
        AuthProvider,
        AuthenticatedUser;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show AccessAdminApi, AccessTemplateApi, BackendConfigApi;
import 'package:tfc_relay_server/tfc_relay_server.dart';

import '../access/access_repository.dart';
import '../access/drift_audit_sink.dart';
import '../access/local_auth_provider.dart';
import '../database.dart';
import '../pipe_main_endpoint.dart';
import '../preferences.dart';
import '../state_man.dart' show KeyMappings;
import 'backend_access.dart';
import 'backend_alarm_ack.dart';
import 'backend_alarm_history_source.dart';
import 'backend_config_store.dart';
import 'backend_alarms.dart' show GatewayAlarmEngine;
import 'backend_browse.dart';
import 'backend_data_services.dart';
import 'backend_freshness.dart';
import 'backend_live_values.dart';
import 'backend_state_man.dart';
import 'backend_writes.dart';
import 'key_mapping_series_resolver.dart';
import 'relay_config.dart';

/// The access-control rule this backend ships with, **chosen here**.
///
/// `RelayServer`'s `policy` parameter has a default
/// (`relay_server.dart:152`), and a default that ships is a decision nobody
/// made. Naming it here makes changing it an edit somebody has to write down,
/// in a file a reviewer reads, rather than the silent consequence of an
/// argument nobody typed.
///
/// **The rule is not stated here.** The value is an [AccessPolicyKeyPolicy] —
/// an adapter over the master access system (17-07), which forwards every write
/// question to `AccessPolicy` and answers `canSee` true for everything, there
/// being no hiding data in the tree. Choosing it is therefore choosing to
/// **defer** to the one master system rather than choosing a rule: Phase 17's
/// constitution is that there is one access-control system and the WebSocket
/// builds on top of it, so a second rule spelled here would be the duplication
/// that 17-07 deleted: the old key policy compared a role against a two-valued
/// enum this package declared itself, and disagreed with the app in both
/// directions (`key_policy.dart:186` records what it replaced).
///
/// The bare `const AccessPolicy()` — no tag bindings, no route table — is the
/// shipped answer, and it is deliberate: the backend grades no *routes*
/// (`kRaisedRoutes` is an app concern), and an unbound tag floors at
/// `AccessGroup.operate` by `groupForTag`'s own ruling, so this is fail-closed
/// rather than fail-open. When per-tag policy data arrives, it is injected
/// here.
///
/// **Deliberately NOT `const`.** Dart canonicalises const instances, so
/// `policy: const AccessPolicyKeyPolicy()` and no argument at all are the same
/// object — indistinguishable by any assertion, which would make the
/// composition test's policy arm vacuous. A distinct instance is what lets
/// "somebody chose this" be a fact a test can read by identity.
final KeyPolicy backendRelayPolicy =
    AccessPolicyKeyPolicy(policy: const AccessPolicy());

/// The assembled graph: everything [composeBackendRelay] built, still unstarted.
///
/// The collaborators are surfaced rather than hidden behind [server] because
/// criterion 4's arm walks them and asserts each runtime type. A graph whose
/// parts cannot be named is a graph whose parts cannot be pinned, and the fake
/// that ships is the one nothing could see.
final class BackendRelayComposition {
  BackendRelayComposition({
    required this.api,
    required this.liveValues,
    required this.freshness,
    required this.resolver,
    required this.policy,
    required this.server,
    _AccountCache? accounts,
  }) : _accounts = accounts;

  /// The in-memory account cache the synchronous [UserResolver] answers from,
  /// or null when this deployment configured no credential source and so has
  /// no accounts to resolve. Refreshed by [refreshAccounts].
  final _AccountCache? _accounts;

  /// The `StateManApi` the server serves every session from.
  final BackendStateMan api;

  /// The live half over the pipe's cache. Wrapped by [freshness]; the adapter
  /// never reads it directly.
  final BackendLiveValues liveValues;

  /// The staleness watchdog around [liveValues], and what [api] actually reads.
  final BackendFreshnessSweep freshness;

  /// Browse node ids and history table names, from the same key mappings the
  /// pipe's workers were registered with.
  final KeyMappingSeriesResolver resolver;

  /// Who may see and who may actuate. See [backendRelayPolicy].
  final KeyPolicy policy;

  /// The listening end, **not yet listening**. `await server.start()` binds.
  final RelayServer server;

  /// Closes the server and releases the adapter.
  ///
  /// **For tests, and for nothing on the process's shutdown path.** The backend
  /// stops by `_shutdown` in `bin/main.dart`, which kills every acquisition
  /// worker, announces the drain and calls `exit(0)` without awaiting
  /// anything — an awaited teardown there has been measured at 5.76 s and is a
  /// container Docker SIGKILLs in the middle of a write. The sockets this
  /// closes go with the process anyway.
  Future<void> dispose() async {
    await server.close();
    await api.dispose();
  }

  /// Re-reads the account → role → groups chain from the database into the
  /// synchronous resolver's cache, so the next sweep grades against the current
  /// state of `app_user`/`app_role`.
  ///
  /// **The embedder's poll calls this immediately before
  /// `server.reloadTokensIfChanged()`** (bin/main.dart). The two halves are
  /// deliberately separate: `reloadTokensIfChanged`'s file digest guards the
  /// re-PARSE of the token file, but a role demotion or a deleted account never
  /// touches that file (17-04b's user model), so the resolver the sweep
  /// consults through `stillValid` must be refreshed from the database on the
  /// same tick or a database-only revocation would never take effect. This is
  /// the honest adaptation of the plan's "refreshed by reloadTokensIfChanged":
  /// that method lives in `tfc_relay_server` and cannot reach this cache, so
  /// the embedder drives both.
  ///
  /// A no-op — and cheap — when this composition has no account source. Never
  /// throws out of a failed database read into the caller's tick; a stale cache
  /// is the safe answer (it revokes nobody it should not), the same trade
  /// `FileTokenValidator.stillValid`'s unreachable-source swallow makes.
  Future<void> refreshAccounts() async => _accounts?.refresh();
}

/// The synchronous [UserResolver]'s backing store: one username → account map,
/// read from `app_user`/`app_role` and refreshed on the embedder's tick.
///
/// **Synchronous at the point of use is the whole reason this exists.**
/// `FileTokenValidator.validate` (at hello) and `stillValid` (per session, per
/// sweep tick) both call the resolver, and neither may `await`: an `await` on
/// the hello path opens the subscription-race `key_policy.dart` documents, and
/// `stillValid` running `N` Postgres round trips for `N` sessions on every tick
/// would make revocation a load test. So the chain is chased once, into memory,
/// by [refresh], and the resolver reads the map.
///
/// The accounts and roles are a handful of rows and cache trivially — this is
/// `UserResolver`'s own stated expectation.
final class _AccountCache {
  _AccountCache(this._repository, {Logger? logger})
      : _logger = logger ?? Logger();

  final AccessRepository _repository;
  final Logger _logger;

  Map<String, ResolvedUser> _byUsername = const <String, ResolvedUser>{};

  /// The synchronous seam handed to `RelayServer.accounts`. Answers null for an
  /// unknown username — never an empty group set, which would be
  /// indistinguishable in the trail from an account deliberately granted
  /// nothing (D-06, fail-closed).
  ResolvedUser? resolve(String username) => _byUsername[username];

  /// Re-reads every account and its role's groups into the map.
  ///
  /// A read failure keeps the previous map rather than emptying it: an empty
  /// map answers null for every station, which the sweep reads as "revoked" and
  /// would close every screen in the plant for the length of a database
  /// hiccup — the exact asymmetry `stillValid` refuses. The lost refresh is
  /// logged, because a cache that silently stopped updating is the one defect
  /// nobody notices.
  Future<void> refresh() async {
    try {
      final roles = await _repository.roles();
      final groupsByRole = <String, Set<AccessGroup>>{
        for (final AccessRole role in roles) role.name: role.groups,
      };
      final users = await _repository.listUsers();
      final next = <String, ResolvedUser>{};
      for (final row in users) {
        final groups = groupsByRole[row.roleName];
        // An account whose role was deleted resolves to null (absent from the
        // map) rather than to a phantom empty grant — same fail-closed rule as
        // an unknown username.
        if (groups == null) continue;
        next[row.username] = ResolvedUser(
          user: AuthenticatedUser(
            username: row.username,
            roleName: row.roleName,
            stationAccount: row.stationAccount,
          ),
          groups: groups,
        );
      }
      _byUsername = next;
    } on Object catch (error, stack) {
      _logger.e('backend relay: account cache refresh failed; keeping the '
          'previously loaded ${_byUsername.length} account(s) rather than '
          'revoking the plant on a database hiccup',
          error: error, stackTrace: stack);
    }
  }
}

/// Builds the graph `centroidx-backend` serves the relay from. Allocation only.
///
/// [config] is the parsed `relay` section of the backend's own stateman file
/// (`relay_config.dart`); a null config means the relay is off and this
/// function is not called at all.
///
/// [pipe], [keyMappings], [database] and [prefs] are the four things
/// `bin/main.dart` already holds by the time it reaches the relay block. None
/// of them is created here: a composition root that opened its own database
/// connection would give the plant a second pool nobody counted.
///
/// **[values] and [freshness] are now in that same category, and for a sharper
/// reason: alarms must run when this function is not called at all.** The relay
/// is off by default and SVN runs that way today (13-06), so a value source
/// that only exists inside this composition is a value source that only exists
/// when somebody has configured a WebSocket — and 14-05's alarm engine feeding
/// from it would go dark exactly where Phase 14 is aimed (D-8 / P-5). Whether
/// the plant is monitored must not be decided by a deployment choice about a
/// socket. So `bin/main.dart` builds the pair before the relay guard, hands it
/// to the engine, and passes it in here.
///
/// Supply **both or neither**; exactly one is refused below. When both are
/// given, [staleAfter] is not consulted — the pair already carries its own
/// deadline — and a disagreement between the two is logged rather than
/// silently resolved.
///
/// [alarms] is the alarm engine an accepted `ackAlarm` is handed to **and** the
/// definitions a history row is resolved against. Optional, and null is a real
/// deployment: a gateway composed without one refuses both an acknowledge and a
/// history read by name rather than accepting them into nothing (14-12). It is
/// **not** the same argument as [values]/[freshness] — those exist because the
/// engine must run whether or not this function is called at all, whereas this
/// one exists because the *gateway* needs a way back to it.
///
/// Typed [GatewayAlarmEngine] — both capabilities in one parameter — so that
/// wiring one and forgetting the other is not a state a caller can reach. That
/// is the shape of the defect this seam shipped with: the history half was
/// built end to end and never passed, and every gateway panel was told the
/// backend serves no alarm history.
///
/// [validator] is required when — and refused unless — [config] says the
/// composition root supplies the credential check. See the argument below.
///
/// [methodKeys] declares which mapped keys are *callables* rather than
/// variables. Production passes none and the default is none; see the paragraph
/// beside the `BackendBrowse` construction for why a contract leg passes one.
BackendRelayComposition composeBackendRelay({
  required RelayConfig config,
  required PipeMainEndpoint pipe,
  required KeyMappings keyMappings,
  required Database database,
  required Preferences prefs,
  KeyPolicy? policy,
  TokenValidator? validator,
  TimeseriesLimits? limits,
  BackendLiveValues? values,
  BackendFreshnessSweep? freshness,
  GatewayAlarmEngine? alarms,
  Duration staleAfter = kBackendStaleAfter,
  Set<String> methodKeys = const <String>{},
  String? statemanFilePath,
  Logger? log,
}) {
  final logger = log ?? Logger();
  final serverConfig = config.toServerConfig();

  // ------------------------------------------------------------ credentials
  //
  // `RelayServer` throws when it is given both a `ServerConfig.auth` and an
  // explicit validator (`relay_server.dart:155`) — two sources of truth for
  // the credential check. 13-06 already makes that pair unrepresentable in the
  // config (`RelayCredentials` is a sealed three), and this function must not
  // re-introduce it at the call site by passing a `validator:` alongside an
  // `auth`. Refused here rather than forwarded, so the message names the
  // composition root instead of arriving from a server constructor in a
  // container log at 03:00 about a file somebody edited that afternoon.
  if (config.suppliesOwnValidator && validator == null) {
    throw ArgumentError('composeBackendRelay: ${config.source} declares '
        'credentials.source = "validator", which says the composition root '
        'supplies the credential check — and none was passed. A root that '
        'supplies none would leave RelayServer\'s permissive default checking '
        'tokens on the plant LAN. Pass `validator:`, or change the config to '
        '{"source": "token_file"} or {"source": "none"}');
  }
  if (!config.suppliesOwnValidator && validator != null) {
    throw ArgumentError('composeBackendRelay: a validator was passed, but '
        '${config.source} configures credentials as '
        '${config.credentials.description}. Two sources of truth for the '
        'credential check is what relay_server.dart:155 refuses; it is '
        'refused here so the refusal names the config file rather than the '
        'server constructor. Remove whichever is not the deployment');
  }

  // ----------------------------------------------------- one value source
  //
  // Both or neither. Refused here rather than half-honoured, for the same
  // reason the two refusals above are: the mistake is a composition mistake,
  // and it must be loud at boot rather than a fault an operator meets at 03:00.
  //
  // What half a pair actually does is worse than it reads. `BackendLiveValues`
  // registers `pipe.onKeyRetired` in its constructor and
  // `BackendFreshnessSweep` registers `pipe.onWorkerDied` and
  // `onWorkerReady` — deliberately, because *"an obligation wired at a call
  // site is an obligation that can be forgotten at a call site"* (13-03). They
  // are plain fields, so the LAST object built wins and the earlier one goes
  // deaf without saying so. Supplying only `values` makes this function wrap a
  // second sweep around the caller's live half, and that second sweep takes
  // `onWorkerDied` off the sweep the caller is reading through. Supplying only
  // `freshness` is the mirror: a sweep wrapped around a live half this
  // composition does not surface, sitting beside one it built — two value
  // sources for one plant, disagreeing about which keys are stale.
  if ((values == null) != (freshness == null)) {
    throw ArgumentError('composeBackendRelay: `values` and `freshness` must be '
        'supplied together or not at all — '
        '${values == null ? '`freshness` was passed without `values`' : '`values` was passed without `freshness`'}. '
        'Each of these objects registers a pipe callback in its constructor '
        '(onKeyRetired on the live half, onWorkerDied and onWorkerReady on the '
        'sweep), and those are plain fields: a second one built here silently '
        'overwrites the caller\'s and the caller\'s object stops hearing about '
        'retired keys and dead workers. A sweep wrapped around a different '
        'live-values object is two value sources for one plant. Pass both — '
        'the pair `bin/main.dart` built for the alarm engine — or pass neither '
        'and let this function build them');
  }

  // ------------------------------------------------------------- live values
  //
  // The real pipe. Reads are the cache and are synchronous by construction —
  // never a reach across the isolate port that could park a session, which is
  // the whole point of Phase 12.
  //
  // Built here ONLY when the caller supplied none. `bin/main.dart` supplies a
  // pair, because the alarm engine needs one whether or not this function is
  // ever called — see the doc above.
  // Named `sweep` rather than `freshness` only because the parameter above owns
  // that name now. Everything downstream reads through this one.
  final BackendLiveValues liveValues;
  final BackendFreshnessSweep sweep;
  if (values != null) {
    liveValues = values;
    sweep = freshness!;
    if (liveValues.staleAfter != staleAfter) {
      logger.w('composeBackendRelay: the supplied value source carries a '
          '${liveValues.staleAfter.inSeconds}s staleness deadline and this '
          'call passed ${staleAfter.inSeconds}s. The SUPPLIED one wins — it is '
          'the pair the alarm engine is already reading through, and two '
          'deadlines for one plant is two answers to "is this value still '
          'true". Remove whichever is not the deployment');
    }
  } else {
    liveValues = BackendLiveValues(
      pipe: pipe,
      keyMappings: keyMappings,
      staleAfter: staleAfter,
      logger: logger,
    );

    // The watchdog goes AROUND the live half, and the adapter reads through it.
    // The other order serves a value that has gone quiet to a panel still
    // badged good. The pipe is handed in as the link-transition observer, so a
    // worker's death and its respawn are each one announcement rather than a
    // slow decay.
    sweep = BackendFreshnessSweep(
      values: liveValues,
      staleAfter: staleAfter,
      pipe: pipe,
      logger: logger,
    );
  }

  // --------------------------------------------------------------- discovery
  //
  // Both from the key mappings main already loaded to decide which worker got
  // spawned with which keys — so neither can disagree with the router. A browse
  // that reached into a worker is the stall this phase exists to prevent.
  final resolver = KeyMappingSeriesResolver(
    keyMappings: keyMappings,
    logger: logger,
  );

  // `methodKeys` defaults to EMPTY, and empty is the honest production answer:
  // `KeyMappingEntry` has no callable concept, so SVN's address space declares
  // no methods (13-04 Finding 1) and `bin/main.dart` passes nothing. `readValue`
  // is the SWEEP's read, not the live half's, so a detail pane shows the same
  // staleness the tag shows.
  //
  // It is a PARAMETER, and only 13-11's WebSocket contract leg passes one.
  // `checkBrowseNodeTypesDistinguishFoldersFromVariables` asserts that a
  // callable comes back typed `method` and is not expandable, and a mapping
  // cannot produce such a node however it is written — so a leg served from
  // this composition with no seam for the declared set would fail that check
  // with no bug behind it, and the only alternatives were to serve a
  // hand-assembled graph (which is what criterion 4 exists to forbid) or to
  // record the check as a gap (which criterion 1 forbids). The default keeps
  // production byte-for-byte what it was.
  final browse = BackendBrowse(
    keyMappings: keyMappings,
    readValue: sweep.read,
    methodKeys: methodKeys,
  );

  // ----------------------------------------------------------- data services
  //
  // Over the connection main already owns. `BackendHistoryViews` wants the
  // drift `AppDatabase` and `BackendTimeseries` wants the wrapper; both come
  // off the one `Database`, so there is one pool and one place it is opened.
  final timeseries = BackendTimeseries.overDatabase(
    database: database,
    resolver: resolver,
    // The ceilings' arithmetic is written out in `backend_data_services.dart`
    // beside the paragraph that justifies each number. Re-spelling one here is
    // how two numbers start disagreeing — the mistake 13-06's label scan
    // refuses for `ServerConfig`, and the same rule applies to this one.
    limits: limits ?? TimeseriesLimits(),
  );
  final historyViews = BackendHistoryViews.overDatabase(database: database.db);
  final preferences = BackendPreferences.overPreferences(prefs);

  // --------------------------------------------------------- access families
  //
  // Only the AUDIT family is wired here, and the asymmetry is deliberate
  // (17-06). `BackendAudit` reads `audit_entry` and holds no session: one
  // instance is correct for every connection, exactly like the three data
  // services above. `BackendAccessTemplates` and `BackendAccessAdmin` exist
  // and are judged in `backend_access_test.dart`, but each one attributes its
  // audit rows to a session and a station — and at composition time there is
  // no identity to attribute to. Constructing them here with an invented
  // session would write rows naming somebody the server never verified, which
  // is the false attribution D-11 forbids. They are constructed where the
  // relay identity is minted (17-09), one per verified station, and until
  // then `BackendStateMan` keeps refusing those two families by name.
  //
  // This does NOT put the trail on the wire ahead of its gate: every handler
  // reads through the per-session `PolicyStateMan`, which refuses `audit.*`
  // until 17-07 grades it. What this line changes is the source BEHIND that
  // gate, so 17-07 has something real to grade.
  final audit = BackendAudit(database: database.db);

  // ------------------------------------------------------------- the audit SINK
  //
  // Where every per-session `PolicyStateMan` WRITES its authorization verdicts
  // (D-05, 17-09). A `DriftAuditSink` over the backend's own `AppDatabase` — the
  // same `audit_entry` table, the same rows and the same `origin` a panel writes
  // in direct mode, so one SELECT answers for panel and wire alike. This is a
  // different object from the `audit` FAMILY above: the family READS the trail
  // over the wire, this SINK writes it. A backend always has a database here
  // (`composeBackendRelay` requires one), so the sink is always real; the
  // `NullAuditSink` degrade `RelayServer` defaults to is for the fixtures that
  // pass no sink, never for the shipped graph — a wire verdict with no row is a
  // decision nobody can answer for, and CR-01's arm pins the type.
  final AuditSink auditSink = DriftAuditSink(database.db);

  // ------------------------------------------------- accounts + scoped families
  //
  // A token file names usernames and grants nothing (D-06); who each one is and
  // what its role may do is the database's answer. `RelayServer.start()` refuses
  // a token file with no resolver (relay_server.dart:496), so a token-file
  // deployment MUST wire one — and there is no permissive fallback, on
  // `FileTokenValidator`'s own reasoning about a misspelled PEM. The resolver is
  // synchronous (it is called at hello and per-session per-sweep-tick), so it
  // reads an in-memory cache the embedder's poll refreshes; see [_AccountCache]
  // and [BackendRelayComposition.refreshAccounts].
  //
  // Built only when the config actually names a token file: a `none` or
  // `validator` deployment has no usernames to resolve, and a resolver there
  // would be answering a question nobody asked. `database` is always present, so
  // "a token file and no database to resolve roles from" — the compose-time
  // refusal the plan asked for — is not a reachable state through this
  // signature; the refusal it maps onto is `start()`'s own, one layer down.
  final _AccountCache? accountCache =
      config.credentials is RelayTokenFileCredentials
          ? _AccountCache(AccessRepository(database.db), logger: logger)
          : null;
  final UserResolver? accounts = accountCache?.resolve;

  // Increment B of the 2026-09-08 no-station-file ruling: the seam
  // `session.login` verifies through, filled with the SAME
  // `LocalAuthProvider` over the SAME `AccessRepository` the panel used in
  // direct mode. One master access system — the wire adds no second
  // verification path, and `no_second_policy_test.dart` stays green because
  // this is authentication (who), not authorization (what). Built exactly
  // when there are accounts to resolve against: a `none` or `validator`
  // deployment names no usernames, and a verifier with nothing behind it
  // would be answering a question nobody asked — the same condition
  // [accountCache] is gated on, so the two are null together, and
  // `RelayServer.start` gates the credential-less-admission wrap on this
  // being non-null. The Argon2id derivation it runs is heavy (measured: a
  // `createUser` blew an 8 s budget under load), which is exactly why it
  // lives on the post-hello login path and not in `validate`.
  final AuthProvider? loginVerifier = accountCache == null
      ? null
      : LocalAuthProvider(AccessRepository(database.db), logger: logger);

  // The per-identity template, admin and config families (D-11): built once
  // per verified station at `hello`, never at compose time — a family
  // constructed here with an invented session would write rows naming somebody
  // the server never verified. `RelayServer` invokes this with the
  // resolver-verified identity and swaps the families UNDER its policy
  // decorator (`_IdentityScopedSource`), so a scoped family is graded exactly
  // as a shared one. The return is `relay_session`'s `IdentityAccessFamilies`
  // record; it is written structurally because that typedef is not on the
  // server's barrel.
  //
  // `backendConfig` is the third slot, the Phase 17 gate's one named
  // carry-forward (17-11 dev 3): the store attributes accepted AND refused
  // config writes to the session (17-10), so it could not be wired
  // sessionlessly without forging D-11 attribution. It serves the file at
  // `statemanFilePath` — the boot file `bin/main.dart` already reads
  // (CENTROID_STATEMAN_FILE_PATH). A composition handed no path still mints
  // the store, and the store refuses every member by name (its own
  // `_require`): fail closed, and the refusal says what to wire.
  ({
    AccessTemplateApi accessTemplates,
    AccessAdminApi accessAdmin,
    BackendConfigApi? backendConfig,
  }) scopeFactory(StationIdentity identity) => (
        accessTemplates: BackendAccessTemplates(
          database: database.db,
          session: () => identity.session,
          station: identity.station,
          audit: auditSink,
          logger: logger,
        ),
        accessAdmin: BackendAccessAdmin(
          database: database.db,
          session: () => identity.session,
          station: identity.station,
          audit: auditSink,
          logger: logger,
        ),
        backendConfig: BackendConfigStore(
          path: statemanFilePath,
          session: () => identity.session,
          station: identity.station,
          audit: auditSink,
          logger: logger,
        ),
      );

  // ------------------------------------------------------------------ writes
  //
  // Down the pipe, three-state, never auto-retried, and badging the value the
  // widget is already watching while it is in flight.
  //
  // The read-modify-write set is derived from the SAME mappings the workers
  // were registered with, for the reason the resolver above is: two derivations
  // of "which keys are array elements" is how a guard starts covering a
  // different set of keys from the one the router serves. Rig probe P4a is what
  // this argument costs when the set is absent — a blind element write answered
  // `applied` on a real PLC array.
  final writes = BackendWrites(
    pipe: pipe,
    values: sweep,
    readModifyWriteKeys: readModifyWriteKeysOf(keyMappings),
    logger: logger,
  );

  final api = BackendStateMan(
    values: sweep,
    writes: writes,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
    audit: audit,
  );

  final chosenPolicy = policy ?? backendRelayPolicy;

  // Relay errors go to the backend's logger and not to `reportToStderr`, so a
  // session fault appears in the same stream as everything else the plant
  // prints. A message on a second stream is a message nobody correlates.
  void onError(Object error, StackTrace stack, String where) =>
      logger.e('relay: $where', error: error, stackTrace: stack);

  // **Spelled twice on purpose.** `RelayServer` tells "you configured nothing"
  // from "you configured a validator" by IDENTITY against its own
  // `permissiveDefault` (`relay_server.dart:155`), so
  // `validator: validator ?? RelayServer.permissiveDefault` would also work —
  // and would put a `validator:` argument in the source of a composition whose
  // whole promise is that it does not pass one alongside an `auth`. A promise
  // a reader can check by looking is worth six duplicated lines.
  // ------------------------------------------------------------- the acks
  //
  // Null when there is no engine, and null is a real deployment rather than a
  // mistake: `tfc_relay_local`'s harness composes a gateway with none, and so
  // does every fixture in the server package. The gateway then refuses an
  // acknowledge **by name** (14-12's null-sink branch: "this gateway serves no
  // alarm engine") instead of accepting one into nothing and answering an
  // operator that it worked.
  //
  // Typed by capability rather than as `AlarmEngine` so this file names what it
  // needs and not the implementation — and so a composition arm can hand it a
  // recorder and read the wiring off the server.
  final alarmAcks = alarms == null ? null : BackendAlarmAckSink(alarms);

  // ------------------------------------------------------------ the history
  //
  // Null on the same condition and for the same reason: a gateway with no
  // engine refuses `alarmHistory` **by name** ("this gateway serves no alarm
  // history") rather than answering `{entries: []}`, which on a panel is a
  // factory that has never had an alarm.
  //
  // **This line is the whole defect.** The protocol type, the server handler,
  // the relay client and the app side all shipped; nothing ever passed
  // `alarmHistory:`, so the null branch was the only branch a plant reached and
  // the rig met a refusal naming a composition problem — this composition. The
  // reader is built over the SAME `Database` every other service on this graph
  // is (one pool, opened in one place) and reads the definitions off the SAME
  // engine `alarmAcks` acknowledges into, so the two can never be resolving a
  // row against a configuration nothing was evaluated under.
  final alarmHistory = alarms == null
      ? null
      : BackendAlarmHistorySource(database: database.db, definitions: alarms);

  final RelayServer server;
  if (validator == null) {
    server = RelayServer(
      api: api,
      config: serverConfig,
      // Named, never defaulted. See [backendRelayPolicy].
      policy: chosenPolicy,
      resolver: resolver,
      alarmAcks: alarmAcks,
      alarmHistory: alarmHistory,
      audit: auditSink,
      accounts: accounts,
      accessFor: scopeFactory,
      loginVerifier: loginVerifier,
      onError: onError,
    );
  } else {
    server = RelayServer(
      api: api,
      config: serverConfig,
      policy: chosenPolicy,
      resolver: resolver,
      validator: validator,
      alarmAcks: alarmAcks,
      alarmHistory: alarmHistory,
      audit: auditSink,
      accounts: accounts,
      accessFor: scopeFactory,
      // Refused above unless `config.suppliesOwnValidator`, which is the
      // `validator` credential source — a deployment that names its own
      // check has no `token_file` accounts, so this is null here anyway.
      loginVerifier: loginVerifier,
      onError: onError,
    );
  }

  return BackendRelayComposition(
    api: api,
    liveValues: liveValues,
    freshness: sweep,
    resolver: resolver,
    policy: chosenPolicy,
    server: server,
    accounts: accountCache,
  );
}
