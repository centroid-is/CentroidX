/// Access control wiring: the repository, the auth provider, the audit sink,
/// the station name, and the session itself — whose inactivity timeout is the
/// signed-in account's own.
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

import 'database.dart';
import 'preferences.dart';

part 'access.g.dart';

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

/// The two device-local keys that used to hold a per-station inactivity
/// timeout: the minutes, and a switch that disabled expiry for every session
/// on the panel.
///
/// **Read by nothing any more** — the timeout is the account's
/// (`app_user.inactivity_timeout_minutes`). They are named only so
/// [AccessSessionController] can remove them at boot: support reads the
/// preferences mirror, and a stale `true` disable flag sitting there would
/// look like it still meant something.
@visibleForTesting
const List<String> kLegacyInactivityPrefKeys = [
  'access.inactivity_timeout_minutes',
  'access.inactivity_timeout_disabled',
];

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

/// Where audit rows go.
///
/// [NullAuditSink] when there is no database. That covers two real cases: the
/// boot window before the connection is open, and a station commissioned with
/// no Postgres at all. Losing the trail there is preferable to failing to
/// boot — an HMI that will not start because it cannot write an audit row is a
/// stopped line.
///
/// But it **is** a gap, and it is the kind of gap nobody notices, because a
/// missing row looks exactly like an action that never happened. What makes it
/// visible is the sink's own error logging: [DriftAuditSink] names every row it
/// loses. [NullAuditSink] is silent by design, so a station running without a
/// database is knowingly running without a trail.
@Riverpod(keepAlive: true)
Future<AuditSink> auditSink(Ref ref) async {
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

/// How an account's stored minutes become its sessions' timeout.
///
/// [resolveInactivityTimeout] in production. A provider only so tests can
/// scale minutes down to real milliseconds — a countdown measured in minutes
/// cannot be waited out in a widget test, and the monitor's timers are real.
final inactivityTimeoutResolverProvider =
    Provider<InactivityTimeoutResolver>((ref) => resolveInactivityTimeout);

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

/// What a self-service password change did.
///
/// Sibling of [AccessSignInResult], and shaped the same way for the same
/// reason: the dialog has to say something different for each of these, and
/// collapsing any two of them produces a sentence that sends somebody to fix
/// the wrong thing.
enum AccessPasswordChangeResult {
  /// The stored password is now the new one. The session is untouched.
  ok,

  /// The current password did not verify.
  wrongCurrentPassword,

  /// It could not be attempted: no database, the provider threw, or the session
  /// belongs to a station account.
  ///
  /// Three causes, one answer, deliberately. Each is a fact about the station or
  /// the account rather than about what was typed, none is anything the person
  /// at the panel can act on differently, and the message for all three points
  /// at the log — which is where the three *are* distinguished.
  unavailable,

  /// Nobody is signed in — either already, or as of a moment ago.
  ///
  /// Two ways in, and neither is defensive padding. The inactivity countdown
  /// keeps running while the dialog is open, so a session can expire between
  /// opening the form and submitting it. And the signed-in account can be
  /// deleted by an administrator mid-session, which
  /// [AccessSessionController.changeOwnPassword] answers by flooring the
  /// session and then reporting it here.
  ///
  /// Its own value because it is the one case with a useful next step — sign in
  /// again — and because the app bar has just stopped showing an identity.
  /// Saying "could not be changed, the log has the details" while the badge
  /// disappears would describe a different event from the one on screen.
  notSignedIn,
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

  /// The countdown for the session in force. Built by [_ensureMonitor], and
  /// replaced whenever a session's timeout differs from the one it counts.
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

  /// How an account's stored minutes become its timeout. Resolved at build.
  InactivityTimeoutResolver _resolveTimeout = resolveInactivityTimeout;

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

    _station = ref.watch(stationNameProvider);
    _local = ref.watch(localPreferencesProvider);
    _resolveTimeout = ref.watch(inactivityTimeoutResolverProvider);
    await _dropLegacyTimeoutPrefs();
    // Before `_restoreOrFloor`, which writes a row when the stored session
    // turns out to have expired while the app was not running.
    _sink = await ref.watch(auditSinkProvider.future);
    final repo = await ref.watch(accessRepositoryProvider.future);

    // No monitor is built here. The timeout belongs to the session, so
    // `_attach` builds one for whichever session it arms — see
    // [_ensureMonitor]. The previous one is already gone: Riverpod runs
    // `onDispose` before a rebuild.
    final session = await _restoreOrFloor(repo);

    // The boot case the listener count exists for: if something is already
    // listening and the restored session is elevated, arm now. `state` is not
    // set until this future completes, so hand `_attach` the session directly.
    if (_listeners > 0 && session.isElevated) _attach(session);
    return session;
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
        await _anonymousSession(repo);

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

    final account = await _resolveAccount(repo, role, stored.username);
    final timeout = _resolveTimeout(account.minutes);
    return AccessSession(
      user: AuthenticatedUser(
        username: stored.username,
        roleName: role.name,
        displayName: stored.displayName,
      ),
      groups: role.groups,
      // Both re-resolved from the database like the groups are, and for the
      // same reason: the payload carries neither, so a hand-edited preferences
      // file can widen neither what this panel sees nor how long it stays
      // elevated.
      allowedPages: account.pages,
      inactivityTimeout: timeout,
      // The payload's `expiresAt` is still the authority — a restart must not
      // hand out a fresh window — but an administrator who shortened this
      // account's timeout while the panel was off gets the shorter one.
      expiresAt: _narrowed(stored.expiresAt, timeout),
    );
  }

  /// [expiresAt], pulled in to `now + timeout` when that is sooner.
  ///
  /// Never later. A timeout changed under a live (or restored) session
  /// applies only in the narrowing direction: widening it would be an
  /// extension nobody earned at the panel, and the next pointer-down extends
  /// by the new value anyway.
  DateTime? _narrowed(DateTime? expiresAt, Duration? timeout) {
    if (expiresAt == null || timeout == null) return expiresAt;
    final cap = clock.now().add(timeout);
    return cap.isBefore(expiresAt) ? cap : expiresAt;
  }

  /// What [username]'s own `app_user` row adds to a session built on [role]:
  /// the pages it may see, and its stored inactivity minutes.
  ///
  /// One read for both, so the two halves cannot come from two reads of a row
  /// somebody is editing.
  ///
  /// The pages are the composition point: the account's own whitelist
  /// replaces its role's when it has one, and inherits the role's when it does
  /// not (`effectiveAllowedPages`). Resolved here, once, so that nothing
  /// downstream of the session has to know two levels exist.
  ///
  /// [username] null is an anonymous session — no `app_user` row, so nothing
  /// to override with, and the role's whitelist *is* the session's.
  ///
  /// **An unreadable user row composes as inherit, not as block,** and its
  /// minutes as null — the default window, never "never". The row cannot be
  /// read exactly when the database is unreachable, and the ruling for that
  /// window is the same one `anonymousRole` makes: a panel that blanks its
  /// pages because Postgres blinked is worse than one showing pages whose
  /// controls still refuse. A blink must not mint an immortal session either.
  Future<({Set<String>? pages, int? minutes})> _resolveAccount(
    AccessRepository? repo,
    AccessRole role,
    String? username,
  ) async {
    final inherited = effectiveAllowedPages(user: null, role: role.allowedPages);
    if (repo == null || username == null) {
      return (pages: inherited, minutes: null);
    }
    try {
      final row = await repo.user(username);
      return (
        pages: effectiveAllowedPages(
          user: decodeAllowedPagesColumn(row?.allowedPages),
          role: role.allowedPages,
        ),
        minutes: row?.inactivityTimeoutMinutes,
      );
    } on Object catch (e) {
      Logger().w(
        'Could not read the app_user row for "$username" — falling back to '
        'the role\'s pages and the default timeout: $e',
      );
      return (pages: inherited, minutes: null);
    }
  }

  /// The whole anonymous identity — groups and pages — from one read.
  ///
  /// Anonymous resolves to [kOperatorRoleName] and has no `app_user` row, so
  /// the Operator role is the session. Reading both halves from one
  /// [AccessRepository.anonymousRole] call is what stops the groups and the
  /// whitelist coming from two reads of a row somebody is editing.
  Future<AccessRole> _anonymousRole(AccessRepository? repo) async {
    if (repo == null) {
      // No database. The seeded Operator role — and, deliberately, **no**
      // whitelist: see [_effectivePages] for why this window fails open.
      return AccessRole(
        name: kOperatorRoleName,
        groups: {
          ...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups,
        },
        seeded: true,
      );
    }
    return repo.anonymousRole();
  }

  /// The anonymous session, groups and pages together.
  Future<AccessSession> _anonymousSession(AccessRepository? repo) async {
    final role = await _anonymousRole(repo);
    return AccessSession.anonymous(
      role.groups,
      operatorAllowedPages: role.allowedPages,
    );
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

    final account = await _resolveAccount(repo, role, user.username);
    // The account's own window. A station account has none — the freezer
    // display's identity does not time out anywhere — and that flag is the
    // only thing that can make a session immortal.
    final timeout =
        user.stationAccount ? null : _resolveTimeout(account.minutes);
    final session = AccessSession(
      user: user,
      groups: role.groups,
      allowedPages: account.pages,
      inactivityTimeout: timeout,
      expiresAt: timeout == null ? null : clock.now().add(timeout),
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
    // A sign-in over a live session must not inherit its countdown: `_attach`
    // returns early while a subscription exists, so the new account would
    // otherwise count down the previous one's remainder, at the previous
    // one's timeout, until its first pointer-down.
    _detach();
    _attach(session);
    return AccessSignInResult.ok;
  }

  /// Change the signed-in account's own password.
  ///
  /// The username is never a parameter. It comes from the live session, which
  /// is what makes this self-service rather than an ungated way to rewrite
  /// anybody's credential — and it is why nothing here needs the `users` group
  /// that [AccessAdminStore.setUserPassword] requires. The two paths write the
  /// same column and must not be merged: one is an administrator acting on
  /// somebody else and is gated, the other is an account's own holder proving
  /// they hold it and must never be.
  ///
  /// ## The session is left exactly as it was
  ///
  /// Not signed out, not re-persisted, and its `expiresAt` not moved. The
  /// authority came from the sign-in and is unchanged; a session stores no
  /// password, so there is nothing in it to invalidate. Signing somebody out
  /// here would punish the one flow that did everything right, and on a panel
  /// it would be worse than that.
  ///
  /// Nor does it count as activity. [refreshGroupsFromRoles] set that
  /// precedent: the countdown measures *inactivity at the panel*, and a dialog
  /// submission is already a pointer event that poked it. Poking it again from
  /// here would extend the window a second time for one interaction.
  ///
  /// **Sessions elsewhere keep working.** Somebody signed in as the same
  /// account on another panel stays signed in, because nothing anywhere
  /// re-checks a password mid-session — sessions end by timeout or by
  /// sign-out, and that is as true after this call as before it. Worth stating
  /// because "change the password, kick out the other sessions" is what the
  /// reader expects from a web application, and this is not one.
  ///
  /// **A session that expires between the guard below and the write still gets
  /// its change.** That is correct, not a race to close: the operation is
  /// authorised by the current password, which was just presented and verified,
  /// not by the session. The session decides whether the affordance is offered
  /// and whose account is meant; it is not the credential. Refusing here would
  /// throw away a correct password because a countdown elapsed during the two
  /// derivations the change itself was paying for.
  ///
  /// ## Station accounts are refused
  ///
  /// A station account's password is commissioning material. It is changed on
  /// the users screen, by an administrator, and it records itself as
  /// `user.password`. Two reasons it cannot be changed from here:
  ///
  /// A resumed panel session carries no proof of anybody's presence — nobody
  /// presented a credential to get it; `_resumePanelAccount` handed it over
  /// when the previous human's session ended. Recording a credential change
  /// against an identity that never logged in is precisely the confusion
  /// `session.resume` exists to prevent, and it would be recorded as
  /// *self-service*, which is the one thing it certainly was not.
  ///
  /// And the account is shared, so "your own password" is not a thing it has.
  /// One person changing it at one panel silently breaks every other panel
  /// committed to it, and the trail would name that person as though they had
  /// only changed their own.
  ///
  /// The dialog is not offered for these sessions at all
  /// (`access_status_action.dart`), so reaching the refusal below means a
  /// second call site got it wrong — the same belt-and-braces shape
  /// [commitPanelAccount] uses, and for the same reason.
  Future<AccessPasswordChangeResult> changeOwnPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final session = state.valueOrNull;
    final user = session?.user;
    if (session == null || user == null) {
      return AccessPasswordChangeResult.notSignedIn;
    }

    if (user.stationAccount) {
      Logger().w(
        'Refusing a self-service password change for the station account '
        '"${user.username}". A station account\'s password is changed by an '
        'administrator on the users screen; the app bar does not offer this '
        'for station accounts, so this call came from somewhere that should '
        'not have made it.',
      );
      return AccessPasswordChangeResult.unavailable;
    }

    final AuthProvider? resolved;
    try {
      resolved = await ref.read(authProviderProvider.future);
    } on Object {
      return AccessPasswordChangeResult.unavailable;
    }

    // Asked for the capability rather than assumed: an implementation with no
    // password to change — OIDC, one day — simply does not implement it, and
    // this returns `unavailable` instead of throwing behind an affordance that
    // should not have been offered. `access_status_action.dart` asks the same
    // question before offering the menu, so in practice this is the second
    // answer to a question already answered — and on the day the answer turns
    // to "no", neither site needs editing.
    //
    // This also absorbs the no-database case without a separate branch: the
    // provider yields null when no Postgres is configured and during the boot
    // window, and null is not a `PasswordSelfService`. Both are the same normal
    // state `accessRepositoryProvider` documents, and both deserve the same
    // answer.
    //
    // An if-case rather than `is!` plus a cast. `PasswordSelfService` is not a
    // subtype of `AuthProvider` — the two are deliberately unrelated
    // interfaces — so an `is!` test would narrow nothing and the call would
    // still need an `as` behind it. The pattern binds the capability directly.
    final PasswordSelfService auth;
    if (resolved case final PasswordSelfService capable) {
      auth = capable;
    } else {
      return AccessPasswordChangeResult.unavailable;
    }

    final PasswordChangeResult outcome;
    try {
      outcome = await auth.changePassword(
        username: user.username,
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
    } on Object catch (e) {
      // Infrastructure, not a credential — and no audit row, the same rule
      // `signIn` keeps. The message carries neither password: `e` here is a
      // database error, never the ArgumentError, which the dialog's own
      // validation makes unreachable.
      Logger().w('A password change could not be attempted: $e');
      return AccessPasswordChangeResult.unavailable;
    }

    switch (outcome) {
      case PasswordChangeResult.ok:
        await _record(AuditRecord.passwordChange(
          who: user.username,
          station: _station,
          roleName: session.roleName,
          actionId: newActionId(),
          at: clock.now(),
        ));
        return AccessPasswordChangeResult.ok;

      case PasswordChangeResult.wrongCurrentPassword:
        await _record(AuditRecord.passwordChangeFailed(
          who: user.username,
          station: _station,
          roleName: session.roleName,
          actionId: newActionId(),
          at: clock.now(),
        ));
        return AccessPasswordChangeResult.wrongCurrentPassword;

      case PasswordChangeResult.accountMissing:
        // The account was deleted while this session was open. No audit row:
        // an account being gone is not a password event, and the drop routes
        // deliberately write none either. `refreshGroupsFromRoles` already owns
        // this exact situation — it re-resolves the session and drops it to the
        // floor when the account has vanished, clearing the stored session on
        // the way.
        await refreshGroupsFromRoles();

        // `notSignedIn`, not `unavailable`, and the reason is on the screen
        // rather than in the enum: the line above has just floored the session,
        // so the app bar's badge disappears in the same frame this answer is
        // rendered in. "The password could not be changed, the log has the
        // details" next to an identity visibly vanishing is two unrelated
        // stories; "your session ended" is the one the person is watching
        // happen, and by the time it is shown it is the literal truth.
        return AccessPasswordChangeResult.notSignedIn;
    }
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

    final timeout = session.inactivityTimeout;
    final extended = AccessSession(
      user: session.user,
      groups: session.groups,
      // Carried forward unchanged. An activity extension re-resolves nothing —
      // it must not silently widen or narrow what is visible, and it runs on
      // every pointer-down, where a database read would be indefensible.
      allowedPages: session.allowedPages,
      inactivityTimeout: timeout,
      // Extended by this session's own timeout — the account's, not the
      // panel's. A session with no expiry (a station account, a resumed
      // panel) has nothing to extend, and an activity extension must not
      // conjure one onto it.
      expiresAt: (timeout == null || session.expiresAt == null)
          ? null
          : clock.now().add(timeout),
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
  /// Every call site writes exactly one row: login, login.failed, logout, the
  /// two timeout paths, and the two outcomes of [changeOwnPassword] that were
  /// judged rather than prevented.
  ///
  /// There are deliberately more branches that write none than branches that
  /// write. `signIn`'s `unavailable` path; and four of [changeOwnPassword]'s —
  /// nobody signed in, the station-account refusal, no provider or one without
  /// the capability, and the throw. Each is commented where it happens, and all
  /// for one reason: a row here asserts that somebody did something, and an
  /// outage, a guard and a request that was never made are none of them.
  ///
  /// [changeOwnPassword]'s `accountMissing` writes none either, for a different
  /// reason worth keeping separate — the account being gone is not a password
  /// event, and the session drop it triggers deliberately records nothing.
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
    if (expiresAt == null) return;
    final monitor = _ensureMonitor(session.inactivityTimeout);
    if (monitor == null) return;

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

  /// The countdown for [timeout], reusing the current monitor when it already
  /// counts that.
  ///
  /// `InactivityMonitor.timeout` is final, so a session whose window differs
  /// from the last one's needs a new monitor — two accounts with different
  /// timeouts on one panel, or an administrator changing the one in force.
  /// Called only from [_attach], after its gating, so a monitor is still only
  /// ever built for an elevated session that something is listening to. And
  /// building one arms nothing: the monitor starts counting in its stream's
  /// `onListen`, which is `_attach`'s subscription.
  InactivityMonitor? _ensureMonitor(Duration? timeout) {
    final current = _monitor;
    if (current != null && current.timeout == timeout) return current;
    _detach();
    _monitor = null;
    if (current != null) unawaited(current.dispose());
    if (timeout == null) return null;
    return _monitor = InactivityMonitor(timeout: timeout);
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
      // Only reachable from a monitor, which exists only for a session with a
      // timeout — the account's own.
      reason: 'No activity for '
          '${current.inactivityTimeout?.inMinutes} minute(s).',
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
    state = AsyncData(await _anonymousSession(repo));
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
      allowedPages: (await _resolveAccount(repo, role, username)).pages,
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
  ///   were [_anonymousSession] — reached at build, at restore and at
  ///   sign-out.
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
  /// time out. It never moves `expiresAt` later. It attaches the inactivity
  /// monitor in exactly one case — the account's timeout itself changed — and
  /// then only for the time already remaining (pulled in to `now + timeout`
  /// when that is sooner), through [_attach]'s usual gating. Otherwise the
  /// anonymous arm and the surviving-elevated arm attach and detach nothing.
  ///
  /// It writes **no audit row**. `audit.dart`'s four auth itemKeys are `login`,
  /// `login_failed`, `logout` and `session_timeout`, and re-resolving groups is
  /// none of them; the role write itself is already recorded by
  /// `AccessAdminStore` as `role.update`, with the group sets as `old → new`. A
  /// second row here would be one action producing two unrelated rows.
  ///
  /// It has exactly **three** permitted device-local persistence writes, and
  /// they are named together so a later reader does not take any for an
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
  /// 3. [_persist] on the **narrowing** route — the account's timeout was
  ///    shortened so far that `now + timeout` is sooner than the stored
  ///    `expiresAt`. The one stored `expiresAt` this may rewrite, and only
  ///    earlier: a restart must not restore the wider window the edit took
  ///    away.
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

    // The anonymous arm. `_anonymousSession` keeps its own fallback to the
    // seeded Operator set when there is no repository, which is the same
    // conservative floor a build resolves on.
    if (!session.isElevated) {
      state = AsyncData(await _anonymousSession(repo));
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

    if (repo == null) {
      await drop('the database is unreachable, so the account behind the '
          'session cannot be confirmed');
      return;
    }

    final String roleNameNow;
    // The account's own whitelist column, lifted out of the try beside the
    // role name so the session below composes from the same single read.
    final String? userPagesNow;
    // And its timeout, from the same read.
    final int? minutesNow;
    try {
      final row = await repo.user(username);
      if (row == null) {
        await drop('the account no longer exists');
        return;
      }
      roleNameNow = row.roleName;
      userPagesNow = row.allowedPages;
      minutesNow = row.inactivityTimeoutMinutes;
    } on Object catch (e) {
      await drop('the app_user row could not be read: $e');
      return;
    }

    final role = await _roleOrNull(repo, roleNameNow);
    if (role == null) {
      await drop('the role "$roleNameNow" the account now holds cannot be '
          'resolved — it was deleted or renamed');
      return;
    }

    if (_disposed) return;
    // A session that never expires stays that way — a station account is
    // flagged at sign-in, and flipping the flag applies at the next one. A
    // session that does expire takes the account's timeout as it stands now.
    final timeoutNow =
        session.inactivityTimeout == null ? null : _resolveTimeout(minutesNow);
    final next = AccessSession(
      user: AuthenticatedUser(
        username: username,
        roleName: role.name,
        displayName: session.user!.displayName,
      ),
      groups: role.groups,
      // Composed from the row this method already read, rather than from a
      // second read that could disagree with it. This is what makes an edit on
      // the access screen change the menu on this panel without a restart.
      allowedPages: effectiveAllowedPages(
        user: decodeAllowedPagesColumn(userPagesNow),
        role: role.allowedPages,
      ),
      inactivityTimeout: timeoutNow,
      expiresAt: _narrowed(session.expiresAt, timeoutNow),
    );
    state = AsyncData(next);

    // A changed timeout needs a monitor that counts it. Re-attached for the
    // time already remaining, never a fresh window — this is an
    // administrator's edit, not activity at the panel — and through
    // `_attach`'s gating, so a session nothing is listening to arms nothing.
    if (timeoutNow != session.inactivityTimeout) {
      _detach();
      _attach(next);
    }

    // The demotion route and the narrowing route. Either way the stored copy
    // would otherwise restore wider than what is now in force.
    if (role.name != session.user!.roleName ||
        next.expiresAt != session.expiresAt) {
      await _persist(next);
    }
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

  /// Remove the retired per-station timeout keys, saying so once.
  ///
  /// A panel that had "Sessions never expire" on was keeping a signed-in
  /// display alive with it; the log line names what does that now. Never
  /// throws — a store that cannot be cleaned costs a stale key, not a boot.
  Future<void> _dropLegacyTimeoutPrefs() async {
    final local = _local;
    if (local == null) return;
    for (final key in kLegacyInactivityPrefKeys) {
      try {
        if (!await local.containsKey(key)) continue;
        await local.remove(key);
        Logger().w(
          'Removed the retired per-station setting "$key". Inactivity '
          'timeouts are per account now (the users list on the access page). '
          'A panel that must stay signed in: flag its account as a station '
          'account and commit the panel to it at sign-in.',
        );
      } on Object catch (e) {
        Logger().w('Could not remove the retired setting "$key": $e');
      }
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
