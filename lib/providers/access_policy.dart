/// The write-path plumbing: the one [AccessPolicy] both guards consult, the
/// stream every denial lands on, and the counted set of writes the app makes on
/// its own behalf.
///
/// **Why this is not in `lib/providers/access.dart`.** That file is identity
/// and session: who is signed in, when the session expires, where the audit
/// rows go. The app bar watches it on every frame. This file is the write path:
/// it is read by exactly two providers and one listener, and it must never
/// reach back toward the session — a `watch` in that direction rebuilds
/// `stateManProvider` on every sign-in and drops every OPC UA connection on the
/// panel. Keeping the two files apart is what makes that a visible import
/// rather than one more line in a long file; `guard_wiring_test.dart` asserts
/// this source names none of `databaseProvider`, `preferencesProvider` or
/// `accessSessionProvider`.
library;

import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_access/tfc_access.dart';

import '../access_routes.dart';
import 'access.dart';
import 'access_templates.dart';

part 'access_policy.g.dart';

/// The single answer to "what does writing *this* require?".
///
/// `keepAlive` and pure: it holds no connection, reads no preference and asks
/// nothing of the database. Since 04-05 it reads exactly one provider —
/// [tagBindingResolverProvider], which has no dependencies of its own and can
/// therefore never rebuild — so it is still true that nothing can invalidate
/// this provider and there is no path by which rebuilding it cascades into the
/// plant connection.
///
/// [kRaisedRoutes] is passed in rather than imported by `tfc_access`, which is
/// pure Dart and must not reach into the Flutter app for a route table. That
/// leaves two sources for one truth — this map and the [RouteRegistry] the
/// navigation menu reads — and `guard_wiring_test.dart` compares the two
/// answers for every raised route rather than restating an expected value.
///
/// The [TagBindingLookup] is `groupFor` on the one [TagBindingResolver] the
/// panel holds — a **callback on a mutable object**, deliberately, and never a
/// value read out of the database.
///
/// The distinction is the whole design of plan 04-05 and it is easy to undo by
/// accident. `tagBindingResolverProvider` has no dependencies and never
/// rebuilds; `accessTemplatesProvider` replaces the snapshot *inside* it when a
/// template or a binding changes. So an edit changes what this policy answers
/// on the very next write, while this policy — and everything downstream of
/// it — is never rebuilt.
///
/// Make the lookup a value instead (a `FutureProvider<AccessPolicy>` over the
/// templates, or a `ref.watch` of the loader here) and every template edit
/// invalidates this provider, rebuilds `stateManProvider`, and drops every OPC
/// UA connection and subscription on the panel. `guard_wiring_test.dart`'s
/// "signing in and out does not rebuild stateManProvider" is the assertion
/// that stops being true; T-04-25 is the threat. `ref.read`, not `ref.watch`,
/// for the same reason, and `access_templates_test.dart` asserts the shape of
/// this line from source.
///
/// Until the first load completes the resolver is empty and `groupForTag`
/// answers the operate floor for every key (2026-09-02 ruling) — a bounded
/// window during which bindings that raise a key above `operate` are not yet
/// in force. `TagBindingSnapshotState.neverLoaded` is what tells that window
/// apart from a station with nothing bound.
@Riverpod(keepAlive: true)
AccessPolicy accessPolicy(Ref ref) => AccessPolicy(
      tagBindings: ref.read(tagBindingResolverProvider).groupFor,
      routes: kRaisedRoutes,
    );

/// Holds the denial controller.
///
/// Private so that [reportAccessDenial] is the only way an event enters the
/// stream. A provider handing the controller out would make every `add` call
/// site a place the trail could be forged from.
final _accessDenialSinkProvider =
    Provider<StreamController<AccessDenied>>((ref) {
  // Broadcast for two reasons, both of them the point of the stream. Plan
  // 03-07's listener attaches and detaches with the app's navigation, which a
  // single-subscription stream forbids; and a broadcast controller **drops**
  // events while nobody is listening rather than buffering them, so a denial
  // from four screens ago is not replayed at whoever mounts the prompt next.
  // The purpose of a denial event is to show a refusal *now*.
  final controller = StreamController<AccessDenied>.broadcast();
  // A StreamController in shared plumbing has the same failure mode as an
  // always-on timer if it is never closed (spec §10).
  ref.onDispose(controller.close);
  return controller;
});

/// Every refusal both guards produce, as a stream a widget can listen to.
///
/// Read it, do not `watch` it for the value: it is a plain [Provider] holding a
/// broadcast [Stream], not a `StreamProvider`. A `StreamProvider` would cache
/// the last event as `AsyncData` and hand it to the next widget that mounts,
/// which is the replay this stream exists to avoid.
final accessDenialsProvider = Provider<Stream<AccessDenied>>(
  (ref) => ref.watch(_accessDenialSinkProvider).stream,
);

/// Publish [denial] to [accessDenialsProvider]. The only entry point.
///
/// Typed to [Ref] because every production caller is a provider's `onDenied`
/// closure. Publishing into a torn-down container is a **no-op rather than a
/// throw**, in both the ways it can happen: the controller already closed, or
/// the container itself disposed so the read throws. A guard's `onDenied` can
/// fire from a write already in flight while the app is shutting down, and an
/// exception there would turn an orderly shutdown into a crash — for an event
/// that by definition has no listener left to show it.
void reportAccessDenial(Ref ref, AccessDenied denial) {
  final StreamController<AccessDenied> controller;
  try {
    controller = ref.read(_accessDenialSinkProvider);
  } on Object {
    return;
  }
  if (controller.isClosed) return;
  controller.add(denial);
}

/// Every file allowed to reach the unchecked write path.
///
/// The path is `GuardedPreferences.systemWrites`, reached through
/// `systemPreferencesProvider`. **It is not "writes we want to allow".** It is
/// "writes the app makes on its own behalf when nobody has acted": a
/// configuration default written because storage is empty. A Save button never
/// qualifies, however inconvenient its denial. If a legitimate operator-facing
/// write turns out to be refused, the fix is a rule in `kPrefAccessRules`, not
/// an entry here — widening this list moves a write out of the trail and out
/// of the check at once.
///
/// `guard_wiring_test.dart` compares this constant against the source of
/// `lib/` in **both** directions: a use in a file that is not listed fails,
/// and a listed file that has stopped using it fails too. Files that are owed
/// rather than done are in [kSystemWriteCallSitesOwed].
///
/// | File | Why it needs it |
/// |---|---|
/// | `lib/providers/preferences.dart` | declares `systemPreferencesProvider`, the path itself |
/// | `lib/providers/state_man.dart` | default `key_mappings`, and `StateManConfig.fromPrefs`' default `state_man_config` |
/// | `lib/providers/page_manager.dart` | the default page layout, seeded **unawaited** by `PageManager.load()` |
/// | `lib/providers/alarm.dart` | the empty `alarm_man_config` `AlarmMan.create` would otherwise write |
/// | `lib/page_creator/assets/recipes.dart` | the empty recipe list written on the **read** path, when an asset is opened |
/// | `lib/providers/collector.dart` | the default `collector_config`, and the carry-over of a config still only on the device |
/// | `lib/providers/mcp_bridge.dart` | the config migration's removal of the stale shared `mcp.config` row, at boot with nobody signed in |
const List<String> kSystemWriteCallSites = [
  'lib/providers/preferences.dart',
  'lib/providers/state_man.dart',
  'lib/providers/page_manager.dart',
  'lib/providers/alarm.dart',
  'lib/page_creator/assets/recipes.dart',
  'lib/providers/collector.dart',
  'lib/providers/mcp_bridge.dart',
];

/// The entries of [kSystemWriteCallSites] that do not use the path **yet**.
///
/// The cap test's expected set is [kSystemWriteCallSites] minus this one, so a
/// file can be declared with its reason before it is routed without the test
/// failing meanwhile, and closing it is a one-line deletion here that the test
/// then enforces. Plan 03-11's gate catches the mismatch if it never happens.
///
/// **Empty since 03-09**, which routed the two 03-06 left here. It stays as a
/// declared, tested-empty mechanism rather than being deleted: the next plan
/// that needs to land a call site and its routing separately has somewhere
/// honest to say so, instead of quietly widening the allow-list.
const List<String> kSystemWriteCallSitesOwed = <String>[];

/// The session a guard resolves on while [accessSessionProvider] is still
/// loading, or has errored.
///
/// Anonymous holding the **seeded Operator groups**, mirroring
/// `AccessSessionController._anonymousSession`. The boot window is real — the
/// session resolves through the database and the guards are built before it
/// answers — and the alternative, an empty group set, would refuse a jog on a
/// panel that is merely still starting. It is the conservative floor rather
/// than a guess: the seeded Operator set is the narrowest Operator has ever
/// been, so it is still the strict answer for `configure` and `administer`.
final AccessSession kSessionWhileLoading = AccessSession.anonymous({
  ...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups,
});

/// The session in force **at this instant**, for a guard's `session` callback.
///
/// `ref.read`, never `ref.watch`. A watch would make the reading provider
/// rebuild on every sign-in, sign-out and inactivity timeout; for
/// `stateManProvider` that means dropping every OPC UA connection and every
/// subscription on the panel each time somebody signs in. That is what the
/// callback parameter on both guards exists for, and
/// `guard_wiring_test.dart`'s "the session is a callback, not a watch" group
/// is what keeps it that way.
///
/// A disposed container answers [kSessionWhileLoading] rather than throwing:
/// a write already in flight during shutdown should be refused or permitted on
/// the strict floor, not crash.
AccessSession sessionInForce(Ref ref) {
  try {
    return ref.read(accessSessionProvider).valueOrNull ?? kSessionWhileLoading;
  } on Object {
    return kSessionWhileLoading;
  }
}

/// The audit sink **as it is now**, resolved once per row.
///
/// Both guards are built once and outlive several `auditSinkProvider` values:
/// a station boots with no database, answers [NullAuditSink], and gets a
/// [DriftAuditSink] when Postgres opens. Awaiting the sink at construction
/// instead would capture whichever one existed at boot, and a `ref.watch` of
/// it would rebuild the guard — and, for `stateManProvider`, the plant
/// connection — on every database reconnect, which is precisely what
/// `state_man.dart`'s `ref.read` on preferences exists to prevent.
///
/// So the resolution moves to the row. `record` is already `async` and both
/// guards already wrap every `record` call in a `try`/`catch` that logs and
/// swallows, so a throw here — a disposed container, a sink that never
/// resolves — can neither fail a permitted write nor replace an
/// `AccessDenied`.
class RefAuditSink implements AuditSink {
  const RefAuditSink(this._ref);

  final Ref _ref;

  @override
  Future<void> record(AuditRecord entry) async {
    final sink = await _ref.read(auditSinkProvider.future);
    await sink.record(entry);
  }
}
