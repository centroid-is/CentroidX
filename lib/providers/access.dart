/// Access control wiring: the repository, the auth provider, the audit sink,
/// the station name, the device-local inactivity timeout, and the session
/// itself.
///
/// Everything in `packages/tfc_access` and `tfc_dart/core/access` is testable
/// in isolation and does nothing on its own. This is the file that puts it in
/// front of the operator.
///
/// **Phase 1 gates nothing.** Nothing here denies anything: `can()` is
/// vocabulary the Phase 3 guards will consult, and no route, asset or write
/// path changes behaviour because of this file.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:clock/clock.dart';
import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/access/local_auth_provider.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppUserData;
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show LinkDown, RemoteStateMan;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show SessionAuthMarkers, SessionLoginResult;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;

import '../core/access_authority.dart';
import '../core/gateway_config.dart';
import '../core/gateway_link_status.dart';
import '../core/gateway_state_man.dart';
import '../core/relayed_access_stores.dart';
import 'database.dart';
import 'gateway.dart';
import 'gateway_link.dart';
import 'gateway_preferences_slot.dart';
import 'preferences.dart';
import 'state_man.dart';

part 'access.g.dart';

/// How a gateway panel signs a person in: verify over the socket, and answer
/// with what the SERVER resolved. Null in direct mode, and null on a gateway
/// whose relay client is not built yet.
///
/// **A seam, so a widget test can drive sign-in without a live gateway** —
/// the `backendConfigApiProvider` pattern. Production reaches the ONE relay
/// client the panel already holds (`GatewayStateMan.remote`) and calls
/// `RemoteStateMan.sessionLogin`; the credential crosses the `wss://` frame
/// once and is verified server-side (Argon2id behind the backend's
/// `AuthProvider`). Nothing here decides whether the password was right — the
/// gateway does, and answers with the resolved user, role and groups.
typedef RelaySignIn = Future<SessionLoginResult> Function({
  required String username,
  required String password,
  String? station,
});

/// The relay sign-in seam, or null when this station cannot sign in over a
/// socket (direct mode, or a gateway whose client is not up).
///
/// A plain [FutureProvider] rather than a codegen one, matching
/// `gatewayVerifiedAccountProvider` and `gatewayConfigProvider`: it reaches
/// `stateManProvider` and needs no generated wiring, and a widget test
/// overrides it with `overrideWith` to drive sign-in without a live gateway.
final relaySignInProvider = FutureProvider<RelaySignIn?>((ref) async {
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (!gateway.isGateway) return null;
  final StateMan stateMan;
  try {
    stateMan = await ref.watch(stateManProvider.future);
  } on Object {
    return null;
  }
  final RemoteStateMan? remote = stateMan is GuardedStateMan
      ? stateMan.innerAs<GatewayStateMan>()?.remote
      : null;
  if (remote == null) return null;
  return ({required username, required password, station}) =>
      remote.sessionLogin(
        username: username,
        password: password,
        station: station,
      );
});

/// The device-local preference key holding the serialised session.
///
/// A constant rather than a literal so the login surface (plan 01-08) and the
/// first-user screen (plan 01-09) name the same key as the tests do.
const String kAccessSessionPrefKey = 'access.session';

/// The device-local preference key naming the account this panel is committed
/// to, or absent when it is committed to none.
///
/// A **bare username**, not a serialised session. Everything else — the role,
/// the groups, whether the account still exists, whether it is still a station
/// account — is re-resolved from the database on every resume, so this file
/// grants nothing on its own. The worst a hand-edited value can do is name a
/// different account, and [AccessSessionController._resumePanelAccount]
/// refuses any that is not still flagged `stationAccount`.
///
/// Separate from [kAccessSessionPrefKey] on purpose, and that separation *is*
/// the feature: a human signing in writes the session key and never touches
/// this one, so the panel's own identity survives their session, their
/// sign-out, their timeout and a restart without any suspend/restore
/// bookkeeping. Committing is a deliberate act at sign-in; un-committing is
/// signing the panel's own account out.
const String kAccessPanelAccountPrefKey = 'access.panel_account';

/// The device-local preference key holding the inactivity timeout, in minutes.
const String kAccessInactivityMinutesPrefKey =
    'access.inactivity_timeout_minutes';

/// The device-local flag that disables the inactivity expiry entirely.
///
/// The panel-PC case: a station commissioned to live signed in as its area
/// account. A **separate boolean**, never an inferred zero — the timeout
/// provider deliberately clamps a stray `0` up to the one-minute floor so a
/// hand-edited store cannot accidentally mint immortal sessions; disabling
/// expiry has to be said out loud.
const String kAccessInactivityDisabledPrefKey =
    'access.inactivity_timeout_disabled';

/// Spec §5: fifteen minutes unless the station says otherwise.
const Duration kDefaultInactivityTimeout = Duration(minutes: 15);

/// The narrowest inactivity timeout a station may configure.
///
/// Below a minute the timeout stops being an inactivity guard and starts being
/// a fault: an operator reading a trend for ninety seconds would be signed out
/// mid-glance.
const Duration kMinInactivityTimeout = Duration(minutes: 1);

/// The widest inactivity timeout a station may configure.
///
/// Eight hours is a shift. Beyond that "times out on inactivity" is no longer
/// true in any useful sense, and a station left elevated overnight is exactly
/// the accident this phase exists to make less likely.
const Duration kMaxInactivityTimeout = Duration(hours: 8);

/// Reads and writes for `app_role` and `app_user`, or null when this station
/// has no database.
///
/// Null is a normal state, not an error: `databaseProvider` yields null when
/// no Postgres is configured, and again during the boot window before the
/// connection opens. Every provider below survives that.
@Riverpod(keepAlive: true)
Future<AccessRepository?> accessRepository(Ref ref) async {
  final db = await ref.watch(databaseProvider.future);
  if (db == null) return null;
  return AccessRepository(db.db);
}

/// What verifies a credential on this station — the gate's first question.
///
/// [AccessGroup]-gated routes, the D-Bus controls and the menu lock all ask
/// [resolveAccessGate], and what that function needs to know is not "is there
/// a repository" but "can anybody be authenticated here, and by whom". On a
/// gateway panel those two questions have different answers:
/// `databaseProvider` returns null the moment the transport is gateway
/// (`database.dart`), so [accessRepositoryProvider] is null by design, while
/// sign-in works perfectly well over the socket ([relaySignInProvider]).
/// Reading the null as "nobody can sign in" is what hid every `/advanced`
/// entry from a signed-in engineer on the rig.
///
/// **`ref.read` on the config, `ref.watch` on the repository**, and the split
/// is deliberate — it mirrors `database.dart` line for line and for the same
/// two reasons. Transport is restart-to-apply (`gateway.dart`), and
/// `server_config.dart` invalidates [gatewayConfigProvider] on every save; a
/// watch here would flip a DIRECT station's authority to
/// [AccessAuthority.relay] the instant somebody typed in the gateway URL
/// field, i.e. before the restart that actually builds the relay client, and
/// the gate would then be consulting a session nothing can mint. The
/// repository, by contrast, must go on being watched: Postgres coming up or
/// dropping mid-shift has to move the gate exactly as it does today.
///
/// A config that cannot be read leaves the station direct, the default in
/// every direction (`readGatewayConfig`, `database.dart`).
///
/// A throwing repository surfaces here as an [AsyncError], which the gate maps
/// to [AccessAuthority.none] — the same fact as a resolved null, gated
/// identically, exactly as it was when the gate held the repository itself.
@Riverpod(keepAlive: true)
Future<AccessAuthority> accessAuthority(Ref ref) async {
  GatewayConfig gateway;
  try {
    gateway = await ref.read(gatewayConfigProvider.future);
  } catch (_) {
    gateway = GatewayConfig.defaults;
  }
  if (gateway.isGateway) {
    return accessAuthorityFor(isGateway: true, hasRepository: false);
  }
  final repo = await ref.watch(accessRepositoryProvider.future);
  return accessAuthorityFor(isGateway: false, hasRepository: repo != null);
}

/// The authentication seam.
///
/// Named for the interface it provides rather than for [LocalAuthProvider],
/// the implementation behind it today. When OIDC lands it becomes an override
/// of this provider rather than a rename of every call site — which is the
/// whole reason `AuthProvider` is an interface.
@Riverpod(keepAlive: true)
Future<AuthProvider?> authProvider(Ref ref) async {
  final repo = await ref.watch(accessRepositoryProvider.future);
  if (repo == null) return null;
  return LocalAuthProvider(repo);
}

/// Where audit rows go. Three cases, and each gets a different sink:
///
///  1. **Gateway mode** → [ServerAuditedSink]. The trail lives at the far
///     end: every relayed operation is audited server-side by the backend's
///     policy decorator, attributed to the identity the server verified at
///     `hello` and stamped `origin: 'relay'` (D-05/D-11) — and the wire
///     deliberately has no method a client could write a row through, because
///     a client-supplied row is a forgery surface. This case must **not**
///     fall into [NullAuditSink]: a null sink on a gateway panel is a trail
///     that looks like a trail and records nothing, which is worse than no
///     trail at all (criterion 3). The named type is how a test tells the
///     cases apart.
///  2. **Direct mode, no database** → [NullAuditSink]. The two real cases
///     this always covered: the boot window before the connection is open,
///     and a station commissioned with no Postgres at all. Losing the trail
///     there is preferable to failing to boot — an HMI that will not start
///     because it cannot write an audit row is a stopped line. It **is** a
///     gap, and [NullAuditSink] is silent by design: a direct station running
///     without a database is *knowingly* running without a trail.
///  3. **Direct mode, database present** → [DriftAuditSink], which names
///     every row it loses.
///
/// `ref.watch` on the transport, never `ref.read`: this provider is
/// `keepAlive`, and `alarm.dart:45` records what a `ref.read` behind a
/// `keepAlive` cost — a stale transport whose stream closed rather than
/// errored, so nothing reported it.
@Riverpod(keepAlive: true)
Future<AuditSink> auditSink(Ref ref) async {
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (gateway.isGateway) return const ServerAuditedSink();
  final db = await ref.watch(databaseProvider.future);
  if (db == null) return const NullAuditSink();
  return DriftAuditSink(db.db);
}

/// The hostname of this panel.
///
/// This is the `station` column of every audit row, and it is what lets the
/// plant manager be shown *which panel* a setpoint was changed from. A trail
/// that records who and when but not where cannot answer "was that the packing
/// hall or the freezer?", which on a plant with identical screens in eight
/// rooms is most of the question.
///
/// `'unknown'` rather than a throw if the platform will not say: a nameless
/// station still writes rows, and a row with a vague station beats no row.
@Riverpod(keepAlive: true)
String stationName(Ref ref) {
  try {
    return io.Platform.localHostname;
  } on Object catch (e) {
    Logger().w('Could not read the local hostname for audit rows: $e');
    return 'unknown';
  }
}

/// How long a quiet panel keeps an elevated session, from device-local
/// preferences.
///
/// **Device-local on purpose.** The timeout is a property of the panel, not of
/// the plant: stations on one database front different equipment, and the
/// screen bolted to a packing line in constant use wants a different number
/// from the one in a locked electrical room. Storing it in the shared
/// `preferencesProvider` would let one station's setting decide another's.
///
/// Clamped to [kMinInactivityTimeout]..[kMaxInactivityTimeout] and logged when
/// it clamps — a stray `0` or a fat-fingered `10000` in the preferences file
/// must not turn into a session that ends instantly or never.
@Riverpod(keepAlive: true)
Future<Duration?> inactivityTimeout(Ref ref) async {
  final local = ref.watch(localPreferencesProvider);

  // The explicit off-switch, checked first: null means "no expiry at all",
  // and only this flag may produce it. An unreadable flag falls through to
  // the minutes — a mangled store must not widen the elevation window.
  try {
    if (await local.getBool(kAccessInactivityDisabledPrefKey) ?? false) {
      return null;
    }
  } on Object catch (e) {
    Logger().w(
      'Could not read "$kAccessInactivityDisabledPrefKey" — treating the '
      'expiry as enabled: $e',
    );
  }

  int? minutes;
  try {
    minutes = await local.getInt(kAccessInactivityMinutesPrefKey);
  } on Object catch (e) {
    // A mangled value costs the station its custom timeout, never its boot.
    Logger().w(
      'Could not read "$kAccessInactivityMinutesPrefKey" — falling back to '
      'the ${kDefaultInactivityTimeout.inMinutes}-minute default: $e',
    );
    return kDefaultInactivityTimeout;
  }

  if (minutes == null) return kDefaultInactivityTimeout;

  final requested = Duration(minutes: minutes);
  if (requested < kMinInactivityTimeout) {
    Logger().w(
      'Inactivity timeout of $minutes minute(s) is below the '
      '${kMinInactivityTimeout.inMinutes}-minute floor — clamping.',
    );
    return kMinInactivityTimeout;
  }
  if (requested > kMaxInactivityTimeout) {
    Logger().w(
      'Inactivity timeout of $minutes minute(s) is above the '
      '${kMaxInactivityTimeout.inHours}-hour ceiling — clamping.',
    );
    return kMaxInactivityTimeout;
  }
  return requested;
}

/// Whether the first account may still be created.
///
/// False when there is no database, and false when the question cannot be
/// asked. An unreachable database must not look like an open commissioning
/// window: the screen behind this flag creates an Engineering account with no
/// credential required beyond reaching the screen, so the failure direction is
/// "closed".
///
/// This is a convenience for the UI, not the guard. The real check runs inside
/// `AccessRepository.createFirstUser`'s transaction.
@Riverpod(keepAlive: true)
Future<bool> firstUserWindowOpen(Ref ref) async {
  final repo = await ref.watch(accessRepositoryProvider.future);
  if (repo == null) return false;
  try {
    return await repo.isUserTableEmpty;
  } on Object catch (e) {
    Logger().w(
      'Could not count app_user — treating the first-user window as closed: '
      '$e',
    );
    return false;
  }
}

/// What a sign-in attempt did.
///
/// [badCredentials] and [unavailable] are kept apart all the way from
/// `LocalAuthProvider`'s null-versus-throw contract to the login form. A
/// database blip is not somebody trying to get in, and the trail must not say
/// it was — see [AccessSessionController.signIn].
enum AccessSignInResult {
  /// Signed in. The session is now elevated.
  ok,

  /// The username or password was not recognised.
  badCredentials,

  /// Authentication could not be attempted — no database, or it threw.
  unavailable,
}

/// Who is standing at this panel, and what they may do.
///
/// Holds the session, restores it across a restart while it is still valid,
/// and drops back to anonymous on inactivity.
///
/// ## The countdown is listener-gated, the session is not
///
/// This provider is `keepAlive` so the *session* survives navigation — walking
/// from the alarm page to a mimic must not sign anybody out. The *countdown* is
/// a different thing: [InactivityMonitor] arms in its stream's `onListen` and
/// disarms in `onCancel`, and this controller subscribes only while the session
/// is elevated **and** something is listening to the provider.
///
/// That pairing is the whole reason plan 01-04 built the monitor the way it
/// did. An always-on `Timer.periodic` in shared plumbing has failed unrelated
/// widget tests in this repo before: a pending timer at the end of a
/// `testWidgets` body fails the test even when the widget under test never
/// touched the thing that armed it. A future refactor that subscribes
/// unconditionally in [build] reintroduces exactly that, and
/// `test/providers/access_session_test.dart` has tests whose only job is to
/// fail if it does.
///
/// ## `expiresAt` is the authority, the timer is only a prompt
///
/// Pausing the countdown must not extend the session. Every re-attach compares
/// `clock.now()` against `expiresAt` first and expires immediately if it has
/// passed; otherwise it arms for the time *remaining* via
/// [InactivityMonitor.arm]. Detaching and re-attaching therefore cannot buy an
/// operator another fifteen minutes.
@Riverpod(keepAlive: true)
class AccessSessionController extends _$AccessSessionController {
  /// How many listeners the provider currently has.
  ///
  /// Riverpod's `onCancel`/`onResume` express "the last listener left" and "a
  /// listener came back", which is the gating wanted — but `onResume` only
  /// fires *after* a cancel, so it never fires for the very first listener. A
  /// session restored from disk at boot, on a panel whose root scaffold listens
  /// once and never stops, would then hold an elevated session with no
  /// countdown attached and nothing to notice it had expired.
  ///
  /// Counting `onAddListener`/`onRemoveListener` gives the same 0↔1 edges plus
  /// that first one, so the rule reads the same and covers the boot case:
  /// **attach on 0→1 while elevated, detach on 1→0.**
  int _listeners = 0;

  /// The countdown, rebuilt whenever the configured timeout changes.
  InactivityMonitor? _monitor;

  /// Non-null exactly while the countdown is attached.
  StreamSubscription<DateTime>? _expiry;

  /// True between a dispose (or the start of a rebuild) and the next [build].
  ///
  /// A timer that fires in that window must not write to `state`.
  bool _disposed = false;

  /// The hostname resolved at build, so the expiry handler can write its row
  /// from a timer callback without reaching back into `ref`.
  String _station = 'unknown';

  /// Null since the disable flag: no expiry, no monitor, no countdown.
  Duration? _timeout = kDefaultInactivityTimeout;

  /// True while the live session **is** this panel's committed account.
  ///
  /// Not derived from `user.stationAccount`: signing in as a station account
  /// without committing the panel is an ordinary (if non-expiring) session,
  /// and an engineer testing as `freezer` on their workstation must not thereby
  /// commission it. Only [commitPanelAccount] and a resume set this.
  ///
  /// It decides two things, both of which would be wrong the other way:
  ///
  /// * [signOut] clears [kAccessPanelAccountPrefKey] only when it is true, so
  ///   a human signing out hands the panel back rather than un-committing it.
  /// * [_persist] declines to write the panel's session into
  ///   [kAccessSessionPrefKey], which is the human slot. The panel lives in its
  ///   own key and re-resolves from the database; a copy in the session slot
  ///   would be a second, staler answer to the same question.
  ///
  /// Re-derived on every [build] rather than carried across one: a rebuild
  /// re-runs the restore, and that is what sets it.
  bool _onPanelSession = false;

  PreferencesApi? _local;

  /// Where auth rows go. Resolved at build for the same reason as [_station].
  AuditSink _sink = const NullAuditSink();

  /// Whether this station runs on the relay. Resolved at build.
  ///
  /// **Gateway sessions are per-run, and that is D-11, not a limitation.** A
  /// gateway panel signs in over the socket; the server verifies and mints
  /// the session, and a reconnect lands back at the awaiting-sign-in screen
  /// because there is no retained credential (increment C is Jón's open
  /// decision, deliberately unbuilt). So in gateway mode the session is
  /// **never persisted and never restored**: persisting it would be the
  /// panel asserting "I am jón" across a restart with no server session
  /// behind the claim — exactly the client-supplied identity D-11 forbids
  /// the server to believe. `_persist` and `_restoreOrAnonymous` both honour
  /// this flag.
  bool _isGateway = false;

  @override
  Future<AccessSession> build() async {
    // Registered synchronously, before the first await: Riverpod fires
    // `onAddListener` as soon as the element is listened to, which for a
    // `container.listen` happens right after the synchronous part of this
    // build. Both callback lists are cleared on every rebuild, so
    // re-registering here does not accumulate — but `_listeners` is notifier
    // state and must NOT be reset, because the listeners themselves survive a
    // rebuild.
    _disposed = false;
    // Re-derived by the restore below, never carried across a rebuild.
    _onPanelSession = false;
    ref.onAddListener(_onListenerAdded);
    ref.onRemoveListener(_onListenerRemoved);
    ref.onDispose(_disposeMonitor);

    // The client's half of ACCESS-01 on a gateway panel, registered
    // synchronously with the two above and for the same reason — a `listen`
    // after an await is not a build-time dependency.
    //
    // **`listen`, never `watch`.** A watch would rebuild this controller on
    // every link report, which is the session being torn down and restored
    // each time the socket blinks.
    //
    // Cheap in direct mode: `gatewayLinkProvider` reads the device-local
    // transport row, publishes exactly one `null` and never touches
    // `stateManProvider` unless the station is in gateway mode — a property
    // `test/providers/gateway_link_test.dart` pins with a throwing override.
    ref.listen<AsyncValue<GatewayLinkReport?>>(
      gatewayLinkProvider,
      (previous, next) => _onGatewayLink(next.valueOrNull),
    );

    _station = ref.watch(stationNameProvider);
    _local = ref.watch(localPreferencesProvider);
    _isGateway = (await ref.watch(gatewayConfigProvider.future)).isGateway;
    _timeout = await ref.watch(inactivityTimeoutProvider.future);
    // Before `_restoreOrFloor`, which writes a row when the stored session
    // turns out to have expired while the app was not running.
    _sink = await ref.watch(auditSinkProvider.future);
    final repo = await ref.watch(accessRepositoryProvider.future);

    // A fresh monitor per build, because `timeout` is final on it and the
    // configured value may have changed. The previous one is already gone:
    // Riverpod runs `onDispose` before a rebuild.
    final timeout = _timeout;
    // No monitor at all when expiry is off: _attach guards on `monitor ==
    // null` the same way it guards on `expiresAt == null`, so nothing arms
    // and nothing can fire.
    _monitor = timeout == null ? null : InactivityMonitor(timeout: timeout);

    final session = await _restoreOrFloor(repo);

    // The boot case the listener count exists for: if something is already
    // listening and the restored session is elevated, arm now. `state` is not
    // set until this future completes, so hand `_attach` the session directly.
    if (_listeners > 0 && session.isElevated) _attach(session);
    return session;
  }

  /// A gateway link report landed. Drop an elevated session the server is no
  /// longer holding.
  ///
  /// **Why the link is the signal.** A gateway session lives on the server and
  /// is per-run: `_signInOverRelay` deliberately does not persist it, and
  /// `_restoreOrAnonymous` deliberately does not restore it, because a session
  /// that outlived its socket would be the panel asserting "I am jón" with
  /// nothing behind the claim. That rule was written down and then not
  /// enforced — nothing in this file watched the link, so a relayed elevation
  /// survived in memory after the socket it was minted on had gone. This is
  /// the rule keeping its own promise.
  ///
  /// It is also how the demote-and-delete property arrives on a gateway panel.
  /// The backend runs a credential + role revocation poll and closes a retired
  /// account's session with **4001 on the next tick**
  /// (`packages/tfc_relay_server/test/session_login_ws_test.dart` arm 5). The
  /// client supervisor treats 4001 like any other close — the link went away,
  /// redial — so the close reaches this file as a link report that is no
  /// longer [GatewayLinkKind.connected], and the elevation goes with it. The
  /// redial comes back on the *station* credential, and the person signs in
  /// again; the server never restores their session, so neither may the panel.
  ///
  /// **A null report is direct mode** (or a gateway whose client is still
  /// building) and means nothing here. That is what keeps every direct-mode
  /// station untouched by this listener.
  ///
  /// **[GatewayLinkKind.connecting] drops too, and must.** It is the first
  /// state a closed socket passes through on its way to redialling; excluding
  /// it would mean a demotion is honoured only if the panel happens to still
  /// be failing to reconnect when the next report lands. At boot the session
  /// is anonymous, so the drop is a no-op there.
  void _onGatewayLink(GatewayLinkReport? report) {
    if (report == null || report.kind == GatewayLinkKind.connected) return;
    // Fire-and-forget with a handler attached: an unhandled error out of a
    // provider listener takes the zone down, and nothing here is awaited.
    unawaited(_dropSessionForLostLink().catchError((Object e) {
      Logger().w('Could not drop the session after the gateway link went '
          'away: $e');
    }));
  }

  Future<void> _dropSessionForLostLink() async {
    if (_disposed) return;
    final session = state.valueOrNull;
    if (session == null || !session.isElevated) return;

    Logger().w(
      'Dropping the elevated session for "${session.user!.username}" to '
      'anonymous: the gateway link went away, and a gateway session does not '
      'survive it — sign in again once the panel is connected.',
    );
    _detach();
    // No `_clearStoredSession()`: `_persist` returns early in gateway mode, so
    // there has never been a payload to clear. Naming that here rather than
    // calling it defensively keeps the "two permitted persistence writes" list
    // in `refreshGroupsFromRoles` true.
    await _toAnonymous();
  }

  // -----------------------------------------------------------------------
  // Restore
  // -----------------------------------------------------------------------

  /// Read the device-local payload and turn it into a live session, or fall to
  /// this panel's floor.
  ///
  /// The floor is the panel's committed station account when there is one and
  /// it still resolves, and anonymous otherwise — see [_resumePanelAccount].
  /// **Every** exit here goes through it, including the three failure exits: a
  /// corrupt, expired or unresolvable *human* payload says nothing about the
  /// panel's own identity, and dropping to anonymous in those cases would make
  /// a committed panel lose itself to a mangled session file it does not own.
  ///
  /// The stored payload is unvalidated data from a file on a station anybody
  /// can walk up to. It is checked for expiry and its **groups are re-resolved
  /// from the role**, never read from the payload — `AccessSession.toJson`
  /// deliberately does not serialise them, so a hand-edited file cannot grant a
  /// group the role does not have.
  Future<AccessSession> _restoreOrFloor(AccessRepository? repo) async {
    /// The panel's committed account, or anonymous. Deferred rather than
    /// computed up front: the common case restores a human session and never
    /// needs it, and resuming writes an audit row.
    Future<AccessSession> floor() async =>
        await _resumePanelAccount(repo) ??
        AccessSession.anonymous(await _anonymousGroups(repo));

    // A gateway panel never restores a session: its elevation is a server
    // session that a reconnect does not carry, so a restored one would be an
    // unbacked client claim (see [_isGateway]). Anonymous — the seeded
    // Operator floor — is the honest boot state until somebody signs in.
    if (_isGateway) {
      return AccessSession.anonymous(await _anonymousGroups(repo));
    }

    final raw = await _readStoredSession();
    if (raw == null) return floor();

    final stored = AccessSession.parse(raw);
    if (stored == null) {
      // A corrupt payload costs the operator a login prompt, never the app its
      // boot.
      Logger().w(
        'The stored session in "$kAccessSessionPrefKey" could not be read — '
        'clearing it and starting anonymous.',
      );
      await _clearStoredSession();
      return floor();
    }

    if (stored.isExpiredAt(clock.now())) {
      // The session ended while the station was off. It gets the same row a
      // live timeout does — otherwise a panel switched off at the end of a
      // shift shows an elevated session simply ceasing, with nothing in the
      // trail saying when.
      await _clearStoredSession();
      await _record(AuditRecord.sessionTimeout(
        who: stored.username,
        station: _station,
        roleName: stored.roleName,
        actionId: newActionId(),
        at: clock.now(),
        reason: 'The session expired at ${stored.expiresAt.toIso8601String()} '
            'while the app was not running.',
      ));
      return floor();
    }

    final role = repo == null ? null : await _roleOrNull(repo, stored.roleName);
    if (role == null) {
      // The role was renamed or deleted, or the database is unreachable. Either
      // way there is no group set to restore against, and signing somebody in
      // against an undefined one is worse than making them log in again.
      Logger().w(
        'The stored session names the role "${stored.roleName}", which cannot '
        'be resolved — starting anonymous.',
      );
      await _clearStoredSession();
      return floor();
    }

    return AccessSession(
      user: AuthenticatedUser(
        username: stored.username,
        roleName: role.name,
        displayName: stored.displayName,
      ),
      groups: role.groups,
      expiresAt: stored.expiresAt,
    );
  }

  Future<Set<AccessGroup>> _anonymousGroups(AccessRepository? repo) async {
    if (repo == null) {
      // No database. Fall back to the seeded Operator groups rather than
      // throwing: a logged-out panel that cannot jog a conveyor because
      // Postgres blinked is a stopped line. The seeded set is the narrowest
      // Operator has ever been, so this is the conservative floor and not a
      // guess.
      return {
        ...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups,
      };
    }
    return repo.anonymousGroups();
  }

  Future<AccessRole?> _roleOrNull(AccessRepository repo, String name) async {
    try {
      return await repo.role(name);
    } on Object catch (e) {
      Logger().w('Could not resolve the role "$name": $e');
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Sign in / sign out
  // -----------------------------------------------------------------------

  /// Attempt a sign-in.
  ///
  /// Returns [AccessSignInResult.badCredentials] when the provider returns
  /// null, and [AccessSignInResult.unavailable] when it throws. **The two are
  /// not collapsed.** `LocalAuthProvider` distinguishes them precisely so a
  /// database blip is not recorded as somebody trying to get in.
  Future<AccessSignInResult> signIn(String username, String password) async {
    // A gateway panel verifies over the socket — the server checks the
    // credential and answers with the resolved user, role and groups. This
    // is the fix for the PRIMARY defect: 17-12 relayed the access stores and
    // left authentication on a Postgres connection the panel no longer has,
    // so sign-in read "unavailable" forever. It goes through the relay now.
    if (_isGateway) return _signInOverRelay(username, password);

    final AuthProvider? auth;
    final AccessRepository? repo;
    try {
      auth = await ref.read(authProviderProvider.future);
      repo = await ref.read(accessRepositoryProvider.future);
    } on Object {
      return AccessSignInResult.unavailable;
    }
    if (auth == null || repo == null) return AccessSignInResult.unavailable;

    final AuthenticatedUser? user;
    try {
      user = await auth.authenticate(username, password);
    } on Object catch (e) {
      // Infrastructure, not a credential. The message deliberately carries
      // neither field.
      // No audit row on this path, deliberately. `LocalAuthProvider`
      // distinguishes null from throw precisely so a database blip is not
      // recorded as somebody trying to get in, and a trail full of phantom
      // failed attempts during an outage is a trail nobody reads.
      Logger().w('Sign-in could not be attempted: $e');
      return AccessSignInResult.unavailable;
    }

    if (user == null) {
      await _record(AuditRecord.loginFailed(
        // Untrusted input straight off the login form; `AuditRecord` truncates
        // it. The password is not passed anywhere near this record.
        who: username,
        station: _station,
        actionId: newActionId(),
        at: clock.now(),
      ));
      return AccessSignInResult.badCredentials;
    }

    final role = await _roleOrNull(repo, user.roleName);
    if (role == null) {
      // `LocalAuthProvider` already refuses this, so reaching it means a second
      // implementation behind the same seam. Refuse rather than elevate against
      // an undefined group set.
      Logger().w(
        'Signed-in user "${user.username}" holds the unresolvable role '
        '"${user.roleName}" — refusing the session.',
      );
      return AccessSignInResult.unavailable;
    }

    final session = AccessSession(
      user: user,
      groups: role.groups,
      // Never-expiring two ways: the station-wide disable (null timeout) or
      // the account's own v8 flag. The flag wins even under a normal
      // timeout — the freezer display's identity does not time out anywhere.
      expiresAt: (_timeout == null || user.stationAccount)
          ? null
          : clock.now().add(_timeout!),
    );

    await _record(AuditRecord.login(
      who: user.username,
      station: _station,
      roleName: role.name,
      actionId: newActionId(),
      at: clock.now(),
    ));

    // A fresh sign-in is somebody's session, not the panel's — even when the
    // account is a station account. Committing the panel is a separate,
    // deliberate step (see [commitPanelAccount]); until it is taken this
    // behaves exactly like any other login.
    _onPanelSession = false;
    state = AsyncData(session);
    await _persist(session);
    _attach(session);
    return AccessSignInResult.ok;
  }

  /// Sign in on a gateway panel: verify over the socket, server-side.
  ///
  /// The panel decides nothing about whether the password was right — it
  /// hands username and password to the relay, the gateway verifies (Argon2id
  /// behind its `AuthProvider`) and answers with the resolved user, role and
  /// groups, and this builds the session from that answer. No audit row is
  /// written here: the trail lives at the far end, where the server already
  /// recorded the login `origin: 'relay'` (D-05); `_sink` is
  /// [ServerAuditedSink] and would no-op anyway.
  ///
  /// **No persistence.** The session is held for this run only — see
  /// [_isGateway]. A reconnect returns to the awaiting-sign-in screen.
  ///
  /// The two refusal answers are kept apart exactly as the direct path keeps
  /// them: the gateway's `bad_credentials` marker is [badCredentials], and
  /// every other refusal — an unreachable user source, a dead link, a
  /// station-credential session, a gateway serving no sign-in — is
  /// [unavailable], because none of them is somebody mistyping a password and
  /// telling them it was would send them to reset one that was never wrong.
  Future<AccessSignInResult> _signInOverRelay(
      String username, String password) async {
    final RelaySignIn? signInFn;
    try {
      signInFn = await ref.read(relaySignInProvider.future);
    } on Object {
      return AccessSignInResult.unavailable;
    }
    if (signInFn == null) return AccessSignInResult.unavailable;

    final SessionLoginResult result;
    try {
      result =
          await signInFn(username: username, password: password, station: _station);
    } on rpc.RpcException catch (e) {
      // The gateway answered and said no. Only its `bad_credentials` marker
      // is a wrong password; everything else is infrastructure or policy and
      // must not read as "your password is wrong". The message is the
      // gateway's own and is never spliced with the credential.
      if (e.message.contains(SessionAuthMarkers.badCredentials)) {
        return AccessSignInResult.badCredentials;
      }
      Logger().w('Relay sign-in was refused: ${e.message}');
      return AccessSignInResult.unavailable;
    } on LinkDown {
      // No link to the gateway — the honest "cannot reach the user database"
      // of gateway mode, and never a credential verdict.
      return AccessSignInResult.unavailable;
    } on Object catch (e) {
      Logger().w('Relay sign-in could not be attempted: $e');
      return AccessSignInResult.unavailable;
    }

    final session = AccessSession(
      user: result.user,
      groups: result.groups,
      // Same expiry rule as the direct path: a station account and the
      // station-wide disable never expire; a person's session takes the
      // inactivity window. The server sweep is the authority on revocation;
      // this is the local idle timeout on top.
      expiresAt: (_timeout == null || result.user.stationAccount)
          ? null
          : clock.now().add(_timeout!),
    );
    state = AsyncData(session);
    // Deliberately no `_persist`: gateway sessions are per-run (see above).
    _attach(session);
    // This panel booted on the copy of `key_mappings` in its own cache,
    // because the backend refuses the shared store to a session nobody has
    // signed in on — the deadlock `RelayedPreferences` documents. This is the
    // first moment it is allowed to read that key, so ask for the copy to be
    // caught up; a difference lands on the reload path `stateManProvider`
    // already has. A hint, not a step of signing in: it is fire-and-forget,
    // it changes nothing if the panel is already current, and nothing here
    // waits on it.
    ref.read(gatewayPreferencesSlotProvider).requestReconcile();
    return AccessSignInResult.ok;
  }


  /// Commit this panel to the account that is signed in right now.
  ///
  /// The panel keeps this identity across restarts, and hands it back whenever
  /// a human's session over it ends — by sign-out, by inactivity, or by the
  /// app restarting. Signing this account out is what ends the commitment.
  ///
  /// Refuses unless the live session belongs to a `stationAccount`. That flag
  /// is an administrator saying "this identity is a panel, not a person", and
  /// it is the only thing standing between this method and a panel wearing
  /// somebody's personal login forever. The caller — the sign-in dialog — only
  /// offers the choice when the flag is set, so a refusal here means a second
  /// call site got it wrong.
  ///
  /// Returns true when the panel is committed.
  Future<bool> commitPanelAccount() async {
    final session = state.valueOrNull;
    final user = session?.user;
    if (user == null || !user.stationAccount) {
      Logger().w(
        'Refusing to commit this panel: the live session is '
        '${user == null ? 'not signed in' : '"${user.username}", which is not '
            'a station account'}.',
      );
      return false;
    }

    final local = _local;
    if (local == null) return false;
    try {
      await local.setString(kAccessPanelAccountPrefKey, user.username);
    } on Object catch (e) {
      Logger().w('Could not commit this panel to "${user.username}": $e');
      return false;
    }

    // The panel's identity lives in its own key from here on. Clearing the
    // human slot is what stops the same login existing twice, once as a
    // session that a restart would reject for having no expiry and once as the
    // commitment that actually survives.
    _onPanelSession = true;
    await _clearStoredSession();
    ref.invalidate(panelAccountProvider);
    return true;
  }

  /// Whether this panel is committed, and to whom. Null when it is not.
  ///
  /// For the sign-in dialog, which offers to commit a panel that is not
  /// already committed to the account signing in.
  Future<String?> panelAccount() => _readPanelAccount();

  /// Sign out deliberately.
  ///
  /// Always available, per spec §5 — there is no state in which an operator
  /// cannot hand the panel back.
  ///
  /// Signing out means signing out of **your own** session, which on a
  /// committed panel resolves into two different-looking outcomes from one
  /// rule:
  ///
  /// * A human who signed in over the panel lands back on the panel's account.
  ///   They did not commit it and do not un-commit it.
  /// * Somebody signed in *as* the panel's account un-commits the panel and
  ///   lands on anonymous. This is the documented way out, and the only one —
  ///   which is why there is no separate de-commissioning control.
  Future<void> signOut() async {
    final current = state.valueOrNull;
    _detach();

    // A gateway panel signs out at the far end too, so the server returns the
    // session to its awaiting-sign-in sentinel and the sweep stops carrying
    // it. Best-effort: a dead link already means the session is unreachable,
    // and the local drop to anonymous below is what the operator sees. No
    // client audit row — the server writes the logout `origin: 'relay'`.
    if (_isGateway && current != null && current.isElevated) {
      try {
        final signInFn = await ref.read(relaySignInProvider.future);
        if (signInFn != null) {
          final stateMan = await ref.read(stateManProvider.future);
          final remote = stateMan is GuardedStateMan
              ? stateMan.innerAs<GatewayStateMan>()?.remote
              : null;
          await remote?.sessionLogout();
        }
      } on Object catch (e) {
        Logger().w('Relay sign-out could not be delivered: $e');
      }
      await _toAnonymous();
      return;
    }

    if (current != null && current.isElevated) {
      await _record(AuditRecord.logout(
        who: current.user!.username,
        station: _station,
        roleName: current.roleName,
        actionId: newActionId(),
        at: clock.now(),
      ));
    }

    await _clearStoredSession();
    // Before `_toFloor`, which would otherwise resume the account being signed
    // out and turn an explicit sign-out into a no-op.
    //
    // The username comparison is not redundant with [_onPanelSession]. That
    // flag means "this session *is* the resumed panel", and it is false when
    // somebody signs in fresh as the account the panel is already committed to
    // — which is reachable, because the commit prompt is suppressed in exactly
    // that case. Without the comparison their sign-out would resume the panel
    // instead of ending it, and it would take two sign-outs to do what the
    // dialog promised one would.
    final signingOut = current?.user?.username;
    if (_onPanelSession ||
        (signingOut != null && signingOut == await _readPanelAccount())) {
      await _clearPanelAccount();
    }
    await _toFloor();
  }

  /// Records activity. Cheap and safe to call on every pointer-down.
  ///
  /// `BaseScaffold` wires this to pointer-down from the first frame (plan
  /// 01-08), which is *before* [build] has resolved on a cold start — and again
  /// if the provider has errored. So the read is guarded: reading `state.value`
  /// unguarded throws, and it would throw on the operator's first tap after a
  /// restart, which is the worst possible moment.
  void poke() {
    final session = state.valueOrNull;
    if (session == null) return;
    if (!session.isElevated) return;

    final extended = AccessSession(
      user: session.user,
      groups: session.groups,
      // A session with no expiry — the station-wide disable or a station
      // account — has nothing to extend, and an activity extension must not
      // conjure one onto it.
      expiresAt: (_timeout == null || session.expiresAt == null)
          ? null
          : clock.now().add(_timeout!),
    );
    state = AsyncData(extended);
    unawaited(_persist(extended));
    _monitor?.poke();
  }

  /// True while the inactivity countdown is armed.
  ///
  /// Reads the monitor rather than the subscription, so it is false both when
  /// nothing is listening and when nothing is elevated.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  bool get timerIsRunning => _monitor?.isRunning ?? false;

  // -----------------------------------------------------------------------
  // The audit trail
  // -----------------------------------------------------------------------

  /// Append one row.
  ///
  /// There are exactly four call sites — login, login.failed, logout and the
  /// two timeout paths — and each writes one row. There is deliberately a fifth
  /// branch that writes none: `signIn`'s `unavailable` path, commented where it
  /// happens.
  ///
  /// **No `reason` is prompted for on any auth event.** The free-text reason
  /// prompt belongs to `configure` and `administer` *writes* and arrives in
  /// Phase 3; the only `reason` values written here are the two timeout
  /// strings, and the controller supplies them, not a person. Phase 3 should
  /// not assume the prompt already exists.
  ///
  /// [DriftAuditSink] already swallows and logs its own failures (plan 01-05),
  /// so this catch is for a *different* sink. Refusing to sign somebody in
  /// because the audit database blinked is worse than a gap in the trail, and
  /// that has to stay true whoever implements the interface.
  Future<void> _record(AuditRecord entry) async {
    try {
      await _sink.record(entry);
    } on Object catch (e, s) {
      Logger().e(
        'AUDIT ROW LOST: ${entry.itemKey} for ${entry.who}@${entry.station}, '
        'actionId=${entry.actionId}. The action itself was not affected — '
        'only its record.',
        error: e,
        stackTrace: s,
      );
    }
  }

  // -----------------------------------------------------------------------
  // The countdown
  // -----------------------------------------------------------------------

  void _onListenerAdded() {
    _listeners++;
    if (_listeners == 1) _attachIfElevated();
  }

  void _onListenerRemoved() {
    _listeners--;
    if (_listeners <= 0) {
      _listeners = 0;
      _detach();
    }
  }

  void _attachIfElevated() {
    final session = state.valueOrNull;
    if (session == null) return;
    _attach(session);
  }

  /// Subscribe to the countdown for the time [session] has left.
  ///
  /// A no-op unless the session is elevated and something is listening — the
  /// two halves of the gating rule, checked in one place so no caller has to
  /// remember both.
  void _attach(AccessSession session) {
    if (_disposed) return;
    if (!session.isElevated) return;
    if (_listeners <= 0) return;
    if (_expiry != null) return;

    final expiresAt = session.expiresAt;
    final monitor = _monitor;
    if (expiresAt == null || monitor == null) return;

    final remaining = expiresAt.difference(clock.now());
    if (remaining > Duration.zero) {
      _expiry = monitor.expirations.listen((_) => unawaited(_expire()));
      // The subscription's `onListen` armed for the *full* timeout. Narrow it
      // to what is actually left, so a session sitting on a page nobody is
      // watching does not gain the whole timeout back every time somebody
      // navigates to it.
      //
      // `arm`, not a fresh `InactivityMonitor(timeout: remaining)`: a new
      // monitor would arm correctly once and then make every subsequent
      // `poke()` re-arm for that remainder instead of the full fifteen minutes,
      // silently shortening every session after the first detach.
      monitor.arm(remaining);
      return;
    }

    // Already past `expiresAt`. Pausing the countdown must not extend the
    // session, so re-attaching after a long gap ends it here rather than
    // handing out a fresh window.
    unawaited(_expire());
  }

  void _detach() {
    final sub = _expiry;
    _expiry = null;
    if (sub != null) unawaited(sub.cancel());
  }

  /// The session ran out: back to anonymous.
  Future<void> _expire() async {
    final current = state.valueOrNull;
    _detach();
    if (current == null || !current.isElevated) return;

    await _record(AuditRecord.sessionTimeout(
      who: current.user!.username,
      station: _station,
      roleName: current.roleName,
      actionId: newActionId(),
      at: clock.now(),
      // Only reachable from the monitor's expiry, which exists only while a
      // timeout does.
      reason: 'No activity for ${_timeout!.inMinutes} minute(s).',
    ));
    await _clearStoredSession();
    await _toFloor();
  }

  void _disposeMonitor() {
    _disposed = true;
    _detach();
    final monitor = _monitor;
    _monitor = null;
    if (monitor != null) unawaited(monitor.dispose());
  }

  /// Straight to anonymous, with no panel account resumed.
  ///
  /// **Not [_toFloor], and the difference is the security property.** #482 made
  /// the ordinary way down resume this panel's committed station account, which
  /// is right for a direct panel: the commitment is a local fact about a local
  /// identity. On a **gateway** panel it is not, because there the session is a
  /// server session and the whole rule of this branch is that authorisation is
  /// enforced at the far end. Resuming a committed account out of local
  /// preferences after the link dropped would be the panel granting itself a
  /// role the gateway never confirmed — an unbacked client claim, which is the
  /// thing [_isGateway] exists to prevent.
  ///
  /// So the two gateway routes down — the lost link and a relay sign-out — land
  /// here, and every other route keeps going through [_toFloor].
  Future<void> _toAnonymous() async {
    if (_disposed) return;
    final repo = await ref.read(accessRepositoryProvider.future);
    if (_disposed) return;
    _onPanelSession = false;
    state = AsyncData(AccessSession.anonymous(await _anonymousGroups(repo)));
  }

  /// The one way down: this panel's committed account, or anonymous.
  ///
  /// Every route that used to reach anonymous now reaches here — [signOut],
  /// [_expire] and the three drops in [refreshGroupsFromRoles] — so "a human's
  /// session ending hands the panel back" is one method rather than three
  /// call sites that each have to remember.
  Future<void> _toFloor() async {
    if (_disposed) return;
    final repo = await ref.read(accessRepositoryProvider.future);
    if (_disposed) return;

    final resumed = await _resumePanelAccount(repo);
    if (_disposed) return;
    if (resumed != null) {
      _onPanelSession = true;
      state = AsyncData(resumed);
      return;
    }

    _onPanelSession = false;
    state = AsyncData(AccessSession.anonymous(await _anonymousGroups(repo)));
  }

  /// This panel's committed account as a live session, or null.
  ///
  /// Null covers "no panel is committed" and "the commitment cannot be honoured
  /// right now", and the caller treats them the same: fall to anonymous.
  ///
  /// ## Nothing is trusted from the preference file
  ///
  /// The file supplies a username and nothing else. The role, the groups and
  /// the account's continued right to be a panel identity are all read from the
  /// database on **every** resume, so a resume cannot hand back permissions the
  /// account no longer has — a role edited or the account demoted while a human
  /// was signed in takes effect the moment the panel comes back.
  ///
  /// Three checks, each closing a hole a stored session would leave open:
  ///
  /// 1. **The row still exists.** Deleting the account un-commissions every
  ///    panel committed to it, at their next resume. Without this, deleting
  ///    `freezer` would leave its panels holding its groups indefinitely — and
  ///    indefinitely is the operative word, because a panel session has no
  ///    expiry to run out.
  /// 2. **It is still `stationAccount`.** Turning that flag off is how an
  ///    administrator says "this is a person now", and a person's identity must
  ///    not be what a panel silently wears. It is also what stops a hand-edited
  ///    preference file naming a *human* account: the file can name anybody,
  ///    but only a flagged account resumes.
  /// 3. **Its role resolves.** Same reasoning as the restore path — signing
  ///    somebody in against an undefined group set is worse than anonymous.
  ///
  /// ## An outage must not un-commission the panel
  ///
  /// A null repository, an unreadable row or an unresolvable role returns null
  /// **without clearing** [kAccessPanelAccountPrefKey]. The commitment is a
  /// deliberate act and only a deliberate act undoes it; a panel that drops to
  /// anonymous because Postgres blinked must come back to itself when Postgres
  /// does, with nobody driving to the plant. That asymmetry — refuse freely,
  /// clear never — is the whole reason this is separate from the three drop
  /// routes in [refreshGroupsFromRoles], which *do* clear.
  Future<AccessSession?> _resumePanelAccount(AccessRepository? repo) async {
    final username = await _readPanelAccount();
    if (username == null) return null;

    if (repo == null) {
      Logger().w(
        'This panel is committed to "$username" but the database is not '
        'reachable — staying anonymous without un-committing it.',
      );
      return null;
    }

    final AppUserData? row;
    try {
      row = await repo.user(username);
    } on Object catch (e) {
      Logger().w(
        'Could not read the app_user row for this panel\'s account '
        '"$username" — staying anonymous without un-committing it: $e',
      );
      return null;
    }

    if (row == null) {
      Logger().w(
        'This panel is committed to "$username", which no longer exists. '
        'Un-committing the panel.',
      );
      await _clearPanelAccount();
      return null;
    }

    if (!row.stationAccount) {
      Logger().w(
        'This panel is committed to "$username", which is no longer a station '
        'account. Un-committing the panel.',
      );
      await _clearPanelAccount();
      return null;
    }

    final role = await _roleOrNull(repo, row.roleName);
    if (role == null) {
      Logger().w(
        'This panel\'s account "$username" holds the role "${row.roleName}", '
        'which cannot be resolved — staying anonymous without un-committing '
        'the panel.',
      );
      return null;
    }

    await _record(AuditRecord.sessionResume(
      who: username,
      station: _station,
      // The role resolved now, not the one it held when the panel was
      // committed.
      roleName: role.name,
      actionId: newActionId(),
      at: clock.now(),
    ));

    return AccessSession(
      user: AuthenticatedUser(
        username: username,
        roleName: role.name,
        stationAccount: true,
      ),
      groups: role.groups,
      // A panel does not time out. Nothing arms for a null `expiresAt` —
      // `_attach` and `poke` both already decline — so this needs no new
      // guard anywhere.
      expiresAt: null,
    );
  }

  /// Re-resolve the session in force against `app_role` and `app_user`, in
  /// place, without signing anybody in or out.
  ///
  /// ## Who calls this, and why it is not optional
  ///
  /// Two call sites, both on the administration screen:
  ///
  /// * **After any role write** (06-07). The roles section puts a banner on the
  ///   `Operator` row saying that ticking a group there grants it to every
  ///   logged-out panel on the floor. `AccessRepository.anonymousGroups()` is
  ///   what resolves that claim, and until this method existed its only callers
  ///   were [_anonymousGroups] — reached at build, at restore and at sign-out.
  ///   So without this call the banner warns about a change the app does not
  ///   apply until something else happens to rebuild the session, which is
  ///   worse than no banner: it is a promise the screen does not keep.
  /// * **After any user write that can change the caller's own privileges**,
  ///   which is `setUserRole` and `deleteUser` (06-08). CONTEXT's lockout
  ///   invariant is "at least one account holds a role granting `users`", not
  ///   "you may not edit yourself", so an admin may demote or delete their own
  ///   account whenever a second holder exists.
  ///
  /// ## The elevated arm re-reads the row, never the cached name
  ///
  /// It resolves [AccessRepository.user] for the signed-in username **first**,
  /// and then resolves *that row's* `roleName`. Resolving the name the session
  /// already carries is one call shorter and wrong: that name is exactly what a
  /// role change writes over, so it would answer the old role and the method
  /// would silently fail in the one case it exists for.
  ///
  /// The username is compared exactly. `app_user.username` is a case-sensitive
  /// primary key and `user('JON')` deliberately does not find `jon`; nothing
  /// here folds.
  ///
  /// ## Three routes down to anonymous
  ///
  /// The `app_user` row has disappeared — the account was deleted, possibly by
  /// its own holder; the row's role cannot be resolved — deleted or renamed;
  /// or the repository is unreachable, so neither can be confirmed. A session
  /// whose account no longer exists is not an elevated session, and leaving it
  /// holding `users` is the privilege-retention hole this method exists to
  /// close.
  ///
  /// Each of the three does what [signOut] and [_expire] already do on the way
  /// down: `_detach()`, then `_clearStoredSession()`, then [_toFloor].
  ///
  /// * The **detach** is not decoration. [_attach] early-returns at
  ///   `if (_expiry != null)`, so a live subscription left behind would make
  ///   the next sign-in's `monitor.arm(remaining)` never run, and the new
  ///   operator would count down the dropped session's leftover remainder until
  ///   their first pointer-down re-armed it. That is bounded and fail-safe — an
  ///   early logout, not a retained privilege — which is why it is worth one
  ///   line and not worth a workaround.
  /// * The **clear** is the difference between closing the hole and closing it
  ///   until the next restart. [_restoreOrFloor] resolves the *stored*
  ///   payload's role name and never consults `app_user`, so a payload left
  ///   behind by a self-delete restores **elevated**, with the deleted
  ///   account's name and the old role's groups, on any start inside the
  ///   remaining window. [poke] would not overwrite it either: it returns early
  ///   on a non-elevated session.
  ///
  /// ## What it must not do
  ///
  /// It does not call [poke] — an admin saving a role in another tab is not the
  /// signed-in operator touching the panel, and quietly extending a session
  /// because somebody re-saved a role is an inactivity timeout that does not
  /// time out. It does not change `expiresAt`. It **never attaches** the
  /// inactivity monitor; the anonymous arm and the surviving-elevated arm
  /// attach and detach nothing.
  ///
  /// It writes **no audit row**. `audit.dart`'s four auth itemKeys are `login`,
  /// `login_failed`, `logout` and `session_timeout`, and re-resolving groups is
  /// none of them; the role write itself is already recorded by
  /// `AccessAdminStore` as `role.update`, with the group sets as `old → new`. A
  /// second row here would be one action producing two unrelated rows.
  ///
  /// It has exactly **two** permitted device-local persistence writes, and they
  /// are named together so a later reader does not take either for an
  /// oversight:
  ///
  /// 1. `_clearStoredSession()` on the three drop routes above.
  /// 2. [_persist] of the newly published session on the **demotion** route —
  ///    the row still exists and its role still resolves, but its `role_name`
  ///    differs from the one the session was carrying — **with the same
  ///    `expiresAt` the session already had**. Here the session stays elevated,
  ///    so no drop route fires and nothing clears the payload, while the stored
  ///    copy keeps the old, wider role name; a restart inside the remaining
  ///    window would restore through `_roleOrNull(repo, stored.roleName)` with
  ///    the groups the demotion just removed. Carrying the existing `expiresAt`
  ///    through unchanged is what keeps "never rewrite a stored `expiresAt`"
  ///    intact: this rewrites the role, not the clock.
  ///
  /// A no-op after dispose, like [_toFloor].
  Future<void> refreshGroupsFromRoles() async {
    if (_disposed) return;
    final session = state.valueOrNull;
    if (session == null) return;

    AccessRepository? repo;
    try {
      repo = await ref.read(accessRepositoryProvider.future);
    } on Object catch (e) {
      Logger().w('Could not reach the access repository to re-resolve the '
          'session groups: $e');
      repo = null;
    }
    if (_disposed) return;

    // The anonymous arm. `_anonymousGroups` keeps its own fallback to the
    // seeded Operator set when there is no repository, which is the same
    // conservative floor a build resolves on.
    if (!session.isElevated) {
      state = AsyncData(AccessSession.anonymous(await _anonymousGroups(repo)));
      return;
    }

    final username = session.user!.username;

    /// The one way down from elevated, in the order [signOut] and [_expire]
    /// use. No audit row: the account being gone is not a logout event, and
    /// there is nobody to attribute one to.
    Future<void> drop(String why) async {
      Logger().w(
        'Dropping the elevated session for "$username" to anonymous: $why.',
      );
      _detach();
      await _clearStoredSession();
      await _toFloor();
    }

    // **Which authority is being asked to confirm this account?** Not "is
    // there a repository" — that question read a gateway panel, which has no
    // repository by design and permanently, as a database outage and demoted a
    // correctly signed-in engineer to anonymous. The three answers are the
    // enum's, derived once by [accessAuthorityFor] from the two facts this
    // controller already holds.
    switch (accessAuthorityFor(
      isGateway: _isGateway,
      hasRepository: repo != null,
    )) {
      case AccessAuthority.relay:
        // The server is the authority, and it already enforces ACCESS-01: the
        // backend's credential + role revocation poll retires a demoted or
        // deleted account's session and closes the socket 4001 on the next
        // tick (`session_login_ws_test.dart` arm 5, every 10 s on the rig).
        // The panel holds no user table and could not confirm anything if it
        // wanted to, so it must not manufacture a demotion out of an absence
        // it was designed to have. Honouring the close is the client's half,
        // and that is [_dropSessionForLostLink], not this method.
        //
        // The cost, stated rather than hidden: an admin demoting a role from
        // *this* panel's access screen no longer sees their own session narrow
        // in the same frame. It narrows when the server says so, within the
        // poll interval. An immediate local answer would be the panel deciding
        // its own privileges, which is the thing gateway mode exists not to do.
        return;
      case AccessAuthority.none:
        // Kept deliberately. Direct mode with no reachable Postgres: nothing
        // on this station can confirm the account, the session was minted
        // against a database that is no longer answering, and an elevated
        // session with nothing behind it is the privilege-retention hole this
        // method exists to close. The operator loses elevation on a blip and
        // signs in again, which is the fail-safe direction.
        await drop('the database is unreachable, so the account behind the '
            'session cannot be confirmed');
        return;
      case AccessAuthority.local:
        break;
    }

    // `local` is `hasRepository: true` by [accessAuthorityFor]'s definition,
    // so this is the switch's own postcondition rather than an assumption.
    final localRepo = repo!;

    final String roleNameNow;
    try {
      final row = await localRepo.user(username);
      if (row == null) {
        await drop('the account no longer exists');
        return;
      }
      roleNameNow = row.roleName;
    } on Object catch (e) {
      await drop('the app_user row could not be read: $e');
      return;
    }

    final role = await _roleOrNull(localRepo, roleNameNow);
    if (role == null) {
      await drop('the role "$roleNameNow" the account now holds cannot be '
          'resolved — it was deleted or renamed');
      return;
    }

    if (_disposed) return;
    final next = AccessSession(
      user: AuthenticatedUser(
        username: username,
        roleName: role.name,
        displayName: session.user!.displayName,
      ),
      groups: role.groups,
      expiresAt: session.expiresAt,
    );
    state = AsyncData(next);

    // The demotion route, and the only re-persist. Same clock, new role.
    if (role.name != session.user!.roleName) await _persist(next);
  }

  // -----------------------------------------------------------------------
  // Device-local persistence
  // -----------------------------------------------------------------------
  //
  // Through `localPreferencesProvider` and never `preferencesProvider`. A
  // session is a property of the person standing at *this* panel; syncing it
  // through the shared database would sign somebody in on eight screens at
  // once, which is the exact failure that separation exists to prevent
  // (spec §10).

  Future<void> _persist(AccessSession session) async {
    // Never on a gateway panel: the retained secret that would survive a
    // restart is increment C's open decision (Jón's), and a persisted
    // session with no credential behind it is an unbacked claim across a
    // reconnect (see [_isGateway]). Sign in, hold the session for this run.
    if (_isGateway) return;
    final local = _local;
    if (local == null || !session.isElevated) return;
    // The panel's own session lives in `kAccessPanelAccountPrefKey` and
    // re-resolves from the database; a copy here would be a second, staler
    // answer to the same question — and one a restart rejects, because a panel
    // session has no `expiresAt`.
    if (_onPanelSession) return;
    try {
      await local.setString(
        kAccessSessionPrefKey,
        jsonEncode(session.toJson()),
      );
    } on Object catch (e) {
      // A session that cannot be persisted is still a valid session; it just
      // will not survive a restart.
      Logger().w('Could not persist the session: $e');
    }
  }

  Future<String?> _readStoredSession() async {
    final local = _local;
    if (local == null) return null;
    try {
      return await local.getString(kAccessSessionPrefKey);
    } on Object catch (e) {
      Logger().w('Could not read the stored session: $e');
      return null;
    }
  }

  Future<void> _clearStoredSession() async {
    final local = _local;
    if (local == null) return;
    try {
      await local.remove(kAccessSessionPrefKey);
    } on Object catch (e) {
      Logger().w('Could not clear the stored session: $e');
    }
  }

  /// The username this panel is committed to, or null.
  ///
  /// An empty stored value reads as null rather than as an account named "",
  /// so a half-written preference file un-commits the panel instead of
  /// sending [_resumePanelAccount] to look up a row that cannot exist.
  Future<String?> _readPanelAccount() async {
    final local = _local;
    if (local == null) return null;
    try {
      return panelAccountOrNull(
          await local.getString(kAccessPanelAccountPrefKey));
    } on Object catch (e) {
      Logger().w('Could not read this panel\'s committed account: $e');
      return null;
    }
  }

  Future<void> _clearPanelAccount() async {
    _onPanelSession = false;
    final local = _local;
    if (local == null) return;
    try {
      await local.remove(kAccessPanelAccountPrefKey);
    } on Object catch (e) {
      Logger().w('Could not un-commit this panel: $e');
    }
    // The one funnel for every way a commitment ends — a sign-out and the
    // three resume refusals all land here — so the read-out follows all of
    // them from a single line.
    ref.invalidate(panelAccountProvider);
  }
}

/// The session provider, under the name every consumer uses.
///
/// `riverpod_generator` names a notifier provider after its class, which would
/// make this `accessSessionControllerProvider` — the controller is an
/// implementation detail and the thing being read is the session. The alias is
/// the public name: the app bar, `BaseScaffold` and the first-user screen all
/// watch `accessSessionProvider`, and `.notifier`, `.future` and
/// `overrideWith` all work through it unchanged.
final accessSessionProvider = accessSessionControllerProvider;

/// A stored panel-account value as the rest of the code must read it.
///
/// An empty string is not an account named "" — it is no commitment at all.
/// One function rather than the same two-line check in both readers: a
/// half-written preference file that un-commits the panel for the resume but
/// still names an account on the Session card would be worse than either
/// answer on its own.
String? panelAccountOrNull(String? stored) =>
    (stored == null || stored.isEmpty) ? null : stored;

/// Which account this panel is committed to, or null when it is committed to
/// none.
///
/// Read from the device-local store rather than from the live session, because
/// that is the question being asked: a commitment outlives whoever is standing
/// at the panel, so a human signed in over a committed panel must still be
/// able to see what it returns to when they leave.
///
/// Kept current by the two methods that write the key —
/// [AccessSessionController.commitPanelAccount] and
/// `_clearPanelAccount` — so a commit or the sign-out that ends one shows up
/// without a reload.
final panelAccountProvider = FutureProvider<String?>((ref) async =>
    panelAccountOrNull(await ref
        .watch(localPreferencesProvider)
        .getString(kAccessPanelAccountPrefKey)));
