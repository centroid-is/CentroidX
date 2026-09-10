/// The seam between the administration screen and 06-03's store: one provider
/// that reaches the store, and two that feed the page its lists.
///
/// It is deliberately thin. Every question about permission, every audit row
/// and every invariant lives below this file — in `AccessAdminStore` and, for
/// the last-`users`-holder rule, in `AccessRepository`'s transaction. What is
/// here is wiring, and the value of writing it once is that 06-07 and 06-08 —
/// the roles section and the users section, written in parallel — reach the
/// same store through the same three names.
///
/// **Nothing in this file polls.** There is no periodic timer, no stream over
/// the authorization tables and no `ref.listen` on the session. Both lists are
/// refreshed by `ref.invalidate` from the caller after a write, which is the
/// convention `access_templates.dart` set and Phase 5 restated. A subscription
/// would put a listener on a database that has no change feed configured for
/// these two tables — one that would never fire and would still have to be torn
/// down.
///
/// **The other half of a role write lives next door.** Invalidating
/// [accessAdminRolesProvider] refreshes the *list*; it does not change what the
/// running app permits. `AccessSessionController.refreshGroupsFromRoles` is
/// what does that, and the roles section calls both. See that method's own doc
/// for why the `Operator` banner is otherwise a promise the screen does not
/// keep.
library;

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';

import '../core/access_admin_store.dart';
import '../core/gateway_state_man.dart';
import '../core/relayed_access_stores.dart';
import 'access.dart';
import 'access_policy.dart';
import 'gateway.dart';
import 'state_man.dart';

part 'access_admin.g.dart';

/// The `users`-gated CRUD over `app_role` and `app_user`, or null when this
/// station has no database.
///
/// Null is a normal state, not an error, exactly as it is for
/// [accessRepositoryProvider]: no Postgres configured, and again during the
/// boot window before the connection opens. The page renders that as a terminal
/// state; nothing here throws for it.
///
/// The session is a **callback**, `sessionInForce(ref)`, and never a watch. A
/// watch here would rebuild this provider — and with it the repository handle
/// it holds — on every sign-in, sign-out and inactivity timeout (T-04-30), and
/// it would not even buy anything: `AccessAdminStore` resolves the session per
/// operation precisely so a store built while anonymous is the same store that
/// permits the write a second later. `access_admin_test.dart` proves that with
/// an `identical` assertion across a sign-in rather than trusting this
/// paragraph.
///
/// `keepAlive: true` for the same reason `accessTemplateStoreProvider` is: it
/// holds a handle, and rebuilding it every time somebody opens the screen would
/// re-derive that handle for nothing.
@Riverpod(keepAlive: true)
Future<AccessAdminStore?> accessAdminStore(Ref ref) async {
  // `ref.watch`, never `ref.read`, on the config AND the StateMan:
  // `alarm.dart:45` records what `ref.read` behind a `keepAlive` cost — a
  // stale transport over a disposed client whose streams CLOSE rather than
  // error, so nothing reported it (the Phase 14 blocker).
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (gateway.isGateway) {
    // The relayed route, through the one client the panel holds
    // (`innerAs`, 15-04's read-only unwrap). The `users` gate and the audit
    // row live server-side, above the backend's own store — enforcement
    // does not move here, only the wire to reach it.
    final stateMan = await ref.watch(stateManProvider.future);
    final remote = stateMan is GuardedStateMan
        ? stateMan.innerAs<GatewayStateMan>()?.remote
        : null;
    if (remote == null) {
      // Refuse by name rather than fall back to the repository — a route
      // that exists will be taken, and the local one must not exist here.
      throw UnsupportedError(
          'accessAdminStoreProvider is not available in gateway mode: this '
          'station resolved a StateMan with no relay client behind it. Fix '
          'the gateway branch of lib/providers/state_man.dart — do not fall '
          'back to the database here.');
    }
    return RelayedAccessAdminStore(
      api: remote.accessAdmin,
      onDenied: (denial) => reportAccessDenial(ref, denial),
    );
  }

  final repository = await ref.watch(accessRepositoryProvider.future);
  if (repository == null) return null;
  return AccessAdminStore(
    repository: repository,
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.read(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );
}

/// Every role, for the roles section.
///
/// Plain `@riverpod` — **autoDispose**, unlike `accessTemplatesProvider`, and
/// the difference is worth stating because the two files otherwise look alike.
/// The templates snapshot is `keepAlive` because it feeds the plant-connection
/// policy and every guard on the panel reads through it; this list feeds one
/// page and nothing else, so it should go away with the page rather than hold a
/// stale roster for the rest of the session.
///
/// An empty list when there is no store, rather than a throw. "No database" and
/// "no roles" are different claims and the section says which it is from the
/// store provider's own value; what this list must not do is turn a station
/// commissioned without Postgres into an error box.
///
/// A store failure *is* propagated — an unreadable roster must not render as an
/// empty one, because an empty roles list is a claim about the tables that
/// would be false.
@riverpod
Future<List<AccessRole>> accessAdminRoles(Ref ref) async {
  final store = await ref.watch(accessAdminStoreProvider.future);
  if (store == null) return const [];
  return store.roles();
}

/// Every account, ordered by username, for the users section.
///
/// Autodispose, empty-when-null and error-propagating for the same three
/// reasons as [accessAdminRoles]; the two are deliberately the same shape so a
/// reader of either section is not learning two conventions.
@riverpod
Future<List<UserSummary>> accessAdminUsers(Ref ref) async {
  final store = await ref.watch(accessAdminStoreProvider.future);
  if (store == null) return const [];
  return store.listUsers();
}
