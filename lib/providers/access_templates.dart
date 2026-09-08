/// The access templates, in memory, and the two ways to ask what they say.
///
/// 04-01 built the resolver, 04-03 built the store, 04-04 taught the guard to
/// ask one question per changed member. This file is the connection: it loads
/// `access_template` and `access_key_binding` into one snapshot, hands
/// `accessPolicyProvider` a callback onto it, and gives widgets the same
/// answer without an await.
///
/// **The shape, and why it is this shape.** Four providers, of which exactly
/// one holds state and exactly one can be invalidated:
///
/// | Provider | Rebuilds when | Read by |
/// |---|---|---|
/// | [tagBindingResolverProvider] | never | the policy, the loader, [tagAccessProvider] |
/// | [accessTemplateStoreProvider] | the database changes | the loader, 04-07, 04-09 |
/// | [accessTemplatesProvider] | invalidated after a write | the key-repository UI |
/// | [tagAccessProvider] | a sign-in, or a load | widgets |
///
/// Everything downstream of the plant connection hangs off the first row, and
/// the first row has no dependencies at all. That is what lets a template edit
/// change what the guard answers without costing an OPC UA connection.
///
/// **What this file deliberately does not do.** It registers no listener on
/// the preferences change stream. Bindings used to live on `KeyMappingEntry`,
/// inside the key-mapping blob, and a save of that blob was how a binding
/// changed; the 2026-08-30 ruling moved them into their own table, because a
/// binding is authorization data and the key-mapping preference is
/// `configure`-classified. So a key-mapping save can no longer change a
/// binding, and there is nothing here to subscribe to. `state_man.dart` next
/// door *does* listen, which is why the absence is written down: it would
/// otherwise read as an oversight. `access_templates_test.dart` asserts it as
/// a grep (T-04-28) rather than trusting this paragraph.
///
/// **The orphan this leaves, named rather than swept.** A key removed from the
/// key mappings leaves its binding row behind. Nothing here cleans that up.
/// The row is harmless — `unboundKeys` never sees the key, because the key
/// list no longer contains it — and deleting rows on a key-mapping save would
/// be an unaudited `users`-grade write triggered by a `configure`-grade
/// action, which is exactly the confusion the ruling removed. 04-08 surfaces
/// orphans; it does not sweep them either.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_access/tfc_access.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';

import '../core/access_template_store.dart';
import '../core/gateway_state_man.dart';
import '../core/relayed_access_stores.dart';
import 'access.dart';
import 'access_policy.dart';
import 'database.dart';
import 'gateway.dart';
import 'state_man.dart';

part 'access_templates.g.dart';

/// This file's diagnostic logger. The load is the only thing that logs.
final Logger _log = Logger();

/// The one live binding snapshot on the panel.
///
/// ## Why this is a `keepAlive` provider holding a mutable object
///
/// The obvious shape for this is `FutureProvider<AccessPolicy>` — load the
/// templates, build a policy from them, hand it out. Do not do that, and this
/// paragraph is here to stop the next person who tries.
///
/// `lib/providers/state_man.dart` reads [accessPolicyProvider] once, with
/// `ref.read`, to build the `GuardedStateMan` that owns **every OPC UA
/// connection and every subscription on the panel**. If the policy became a
/// value that changes when the templates change, then editing a template — or
/// binding one key, or a Postgres reconnect that reloads the snapshot — would
/// invalidate the policy, rebuild `stateManProvider`, and drop the plant
/// connection. Operators would see the whole screen go stale because somebody
/// in the office renamed a template.
///
/// `guard_wiring_test.dart`'s *"signing in and out does not rebuild
/// stateManProvider"* is the test that stops being true, and T-04-25 is the
/// threat. So the policy is handed a **callback** — `groupFor` on this object —
/// and this object never changes identity. Its snapshot is replaced in place
/// by [accessTemplatesProvider]. 04-01's `identical()` test exists for exactly
/// this, and there is a matching one here.
///
/// The provider therefore has **no dependencies**: nothing can invalidate it,
/// so nothing can rebuild it, so nothing downstream of it rebuilds either.
/// That is the property, and it is worth the mutable object.
///
/// ## Why it kicks the loader
///
/// Having no dependencies is what creates the hole the kick below closes. See
/// the comment at the kick; it is the reason this plan exists.
@Riverpod(keepAlive: true)
TagBindingResolver tagBindingResolver(Ref ref) {
  final resolver = TagBindingResolver();

  // The kick. Nothing in the design above makes the load happen, and that is
  // the hole.
  //
  // Every consumer reads *this* provider rather than the loader: the policy
  // takes a callback onto it, `tagAccessProvider` reads it, and neither
  // depends on `accessTemplatesProvider`. So without this line a station with
  // templates created and keys bound comes up with an empty snapshot,
  // `groupFor` answers null for every one of them, `guarded_state_man.dart`
  // permits every write, and the panel is byte-identically indistinguishable
  // from one nobody ever configured — silently, with every test passing.
  // Worse, the only thing that would have started the load is opening
  // `/advanced/key-repository`, which is also the only page that surfaces
  // unbound keys: bindings would have taken effect only for the person looking
  // at the screen that reports them missing.
  //
  // Forced from here rather than from a caller so that no caller can forget
  // it. The idiom is `state_man.dart`'s `ref.read(collectorProvider.future)` —
  // an unawaited read whose value nobody wants, whose purpose is that the
  // provider runs. It is scheduled rather than called inline because this
  // provider is mid-build and the loader reads it back.
  //
  // **One-way on purpose.** The resolver starts the load; the load never
  // rebuilds the resolver. Making `accessPolicyProvider` depend on the loader
  // is the obvious alternative and it is the one thing this design forbids: it
  // would rebuild the policy on every template edit, rebuild
  // `stateManProvider`, and drop every OPC UA connection on the panel.
  scheduleMicrotask(() async {
    try {
      await ref.read(accessTemplatesProvider.future);
    } on Object catch (e) {
      // Swallowed and logged rather than rethrown: a failed template load must
      // not take down the provider every guard on the panel depends on. What
      // is left behind is visible — the resolver stays `neverLoaded`.
      _log.w('Access templates did not load — every bound key answers only '
          'the Operate floor '
          'until they do (state=${resolver.state}): $e');
    }
  });

  // And the window before that load lands answers **null**, not "refused".
  // Failing closed on `neverLoaded` would refuse every write on a panel that
  // is merely still booting, and refuse them for ever on a station
  // commissioned without Postgres, where the load can never complete. What is
  // not acceptable is that the window be indistinguishable from a configured
  // station, and `resolver.state` is what fixes that: `neverLoaded` and
  // `loaded`-with-nothing-bound answer identically and are different values.
  return resolver;
}

/// The `users`-gated CRUD over both authorization tables, or null when this
/// station has no database.
///
/// Null is a normal state, exactly as it is for `accessRepositoryProvider`: no
/// Postgres configured, and again during the boot window before the connection
/// opens. The loader below treats null as "nothing is bound", which is the
/// deliberate ungated case.
///
/// **In gateway mode the store is non-null with no database at all** — a
/// [RelayedAccessTemplateStore] over the panel's one relay client, because in
/// gateway mode the templates live behind the backend and the database route
/// must be genuinely unnecessary, not merely unused (17-12, ACCESS-01).
///
/// The session is a **callback**, `sessionInForce(ref)`, and never a watch —
/// see `access_policy.dart`'s library doc for the reasoning. A watch here would
/// rebuild this provider, and with it the database handle it holds, on every
/// sign-in, sign-out and inactivity timeout (T-04-30). [tagAccessProvider] is
/// the one deliberate exception in this file and says why at its own
/// declaration.
@Riverpod(keepAlive: true)
Future<AccessTemplateStore?> accessTemplateStore(Ref ref) async {
  // `ref.watch`, never `ref.read`, on the config AND the StateMan:
  // `alarm.dart:45` records what `ref.read` behind a `keepAlive` cost — a
  // stale transport over a disposed client whose streams CLOSE rather than
  // error, so nothing reported it (the Phase 14 blocker).
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (gateway.isGateway) {
    // The relayed route, through the ONE client the panel already holds —
    // a second client would be a second socket, a second session and a
    // second identity in the revocation sweep. The check, the audit row and
    // every invariant live at the far end, above the backend's own store.
    final stateMan = await ref.watch(stateManProvider.future);
    final remote = stateMan is GuardedStateMan
        ? stateMan.innerAs<GatewayStateMan>()?.remote
        : null;
    if (remote == null) {
      // Refuse by name, exactly as `alarmManProvider` does: a silent
      // fallback to the database here is how the local route quietly comes
      // back, and a route that exists will be taken.
      throw UnsupportedError(
          'accessTemplateStoreProvider is not available in gateway mode: '
          'this station resolved a StateMan with no relay client behind it. '
          'Fix the gateway branch of lib/providers/state_man.dart — do not '
          'fall back to the database here.');
    }
    return RelayedAccessTemplateStore(
      api: remote.accessTemplates,
      onDenied: (denial) => reportAccessDenial(ref, denial),
    );
  }

  final db = await ref.watch(databaseProvider.future);
  if (db == null) return null;
  return AccessTemplateStore(
    db: db.db,
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.read(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );
}

/// Loads both tables into [tagBindingResolverProvider], and exposes the
/// templates for the UI.
///
/// `list()` and `bindings()` — two tables, **one** `setSnapshot`. Applying one
/// half without the other leaves a window in which every binding dangles,
/// which 04-01 and 04-03 both warned about.
///
/// Refresh by invalidating this provider after any template **or** binding
/// write. Both go through [AccessTemplateStore], so there is one trigger and
/// no listener to leak.
///
/// ## Why a failed load keeps the previous snapshot
///
/// A store throw — Postgres away mid-read — leaves the **previous snapshot in
/// place** and only marks it stale. It does not clear it. Since the
/// 2026-09-02 ruling an unreadable binding source degrades to the operate
/// floor rather than to "unrestricted", which softens the blast radius of a
/// cleared snapshot — but only to the floor.
///
/// Here it is not. Clearing the snapshot on a blink would silently unrestrict
/// every bound key on the panel for the duration of a retry — an elevation of
/// privilege (T-04-26) caused by a network hiccup, with nothing on screen to
/// say so. Keeping the old answers is the conservative choice and the stale
/// state is how the staleness stays visible.
@Riverpod(keepAlive: true)
Future<List<AccessTemplate>> accessTemplates(Ref ref) async {
  final resolver = ref.read(tagBindingResolverProvider);
  final store = await ref.watch(accessTemplateStoreProvider.future);

  if (store == null) {
    // A station commissioned without Postgres. Nothing is bound and nothing is
    // gated — deliberately — and the snapshot is `loaded`, not `neverLoaded`,
    // so the deliberate case and the accidental one stay different values.
    _applySnapshot(resolver, const [], const {});
    return const [];
  }

  try {
    final templates = await store.list();
    final bindings = await store.bindings();
    _applySnapshot(resolver, templates, bindings);
    return templates;
  } on Object catch (e) {
    resolver.markStale();
    _log.w('Could not reload the access templates — keeping the previous '
        'snapshot (${resolver.boundKeyCount} bound key(s), '
        'state=${resolver.state}): $e');
    rethrow;
  }
}

/// Replaces the snapshot, and logs the first time it ever lands.
///
/// The `neverLoaded -> loaded` transition is logged exactly once, with the
/// counts, so a station where the load never completes is diagnosable from the
/// log rather than only from the behaviour of a control somebody tried to use.
void _applySnapshot(
  TagBindingResolver resolver,
  List<AccessTemplate> templates,
  Map<String, String> bindings,
) {
  final first = resolver.state == TagBindingSnapshotState.neverLoaded;
  resolver.setSnapshot(
    keyToTemplate: bindings,
    templates: {for (final t in templates) t.name: t},
  );
  if (first) {
    _log.i('Access templates loaded: ${resolver.templateCount} template(s), '
        '${resolver.boundKeyCount} bound key(s).');
  }
}

/// "Is this control locked?", answered without an await.
///
/// Spec §7b requires the group to resolve **at tap time**, because the sign-in
/// prompt appears when the control is tapped and not when a write comes back
/// refused. That requirement used to be free: the binding lived in the
/// key-mapping blob, which was already in memory. The 2026-08-30 ruling moved
/// bindings into a table, so it is no longer free — this class, over the
/// snapshot [accessTemplatesProvider] fills, is what makes it true again.
///
/// **No member of this class may return a future.** One `await` here would
/// pass every functional test in this phase and silently end tap-time
/// elevation: the control would render, the operator would tap it, and the
/// lock would appear a frame later or not at all.
/// `access_templates_test.dart` derives the signatures from this source and
/// asserts it.
///
/// It computes nothing itself. [groupFor] is the resolver's answer and
/// [canWrite] is that answer plus `AccessSession.can` — a second copy of the
/// operate-floor rule here is how the UI and the guard end up disagreeing.
class TagAccess {
  const TagAccess({
    required TagBindingResolver resolver,
    required AccessSession session,
  })  : _resolver = resolver,
        _session = session;

  final TagBindingResolver _resolver;
  final AccessSession _session;

  /// The group required to write [member] of [key]. Never null — the
  /// resolver floors at `operate` (2026-09-02 ruling).
  AccessGroup groupFor(String key, {String? member}) =>
      _resolver.groupFor(key, member);

  /// Whether the session in force may write [member] of [key].
  ///
  /// True when the session holds the required group — which is at least
  /// `operate` for every key, bound or not. This is the **only** thing a
  /// widget needs in order to decide whether to render a lock.
  bool canWrite(String key, {String? member}) =>
      _session.can(groupFor(key, member: member));

  /// The template [key] is bound to, or null when it is unbound — or bound to
  /// a template that no longer exists, which reads the same from here and is
  /// reported by `unboundKeys`.
  AccessTemplate? templateFor(String key) => _resolver.templateForKey(key);

  /// Whether the snapshot behind these answers has ever loaded.
  ///
  /// A `neverLoaded` resolver answers null for everything, exactly like a
  /// station with nothing bound. 04-08 renders the difference.
  TagBindingSnapshotState get snapshotState => _resolver.state;
}

/// [TagAccess] for the session in force, rebuilt when that session changes.
///
/// ## Why this watches the session where the store must not
///
/// The asymmetry is deliberate and looks like an inconsistency until it is
/// stated, so: a **widget** must rebuild on sign-in — the moment the operator
/// is allowed through a control, the lock has to come off without waiting for
/// anything else to happen. The **plant connection** must not rebuild on
/// sign-in, ever, because rebuilding it drops every OPC UA subscription on the
/// panel. `accessTemplateStoreProvider` above therefore takes the session as a
/// callback, and this one watches it. Do not "fix" the inconsistency by making
/// them match; fixing it in the wrong direction is T-04-30.
///
/// While the session is still loading this resolves on [kSessionWhileLoading],
/// the same conservative floor both guards use, so a control never renders
/// unlocked and then locks a frame later (T-04-29).
///
/// It also watches [accessTemplatesProvider] — for the rebuild, not the value.
/// Binding a key has to take the lock off, or put it on, without the operator
/// navigating away and back. That watch is safe here for the same reason it
/// would be fatal in `accessPolicyProvider`: nothing that holds a connection
/// reads this provider.
@riverpod
TagAccess tagAccess(Ref ref) {
  final resolver = ref.watch(tagBindingResolverProvider);
  ref.watch(accessTemplatesProvider);
  final session = ref.watch(accessSessionProvider).valueOrNull;
  return TagAccess(
    resolver: resolver,
    session: session ?? kSessionWhileLoading,
  );
}
