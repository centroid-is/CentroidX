// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'access_templates.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$tagBindingResolverHash() =>
    r'9f34eda9b17e130389de45d82cdd9878bcb3cdde';

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
///
/// Copied from [tagBindingResolver].
@ProviderFor(tagBindingResolver)
final tagBindingResolverProvider = Provider<TagBindingResolver>.internal(
  tagBindingResolver,
  name: r'tagBindingResolverProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$tagBindingResolverHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef TagBindingResolverRef = ProviderRef<TagBindingResolver>;
String _$accessTemplateStoreHash() =>
    r'7343096be48fe6014f3d5952c770f3913ed3a013';

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
///
/// Copied from [accessTemplateStore].
@ProviderFor(accessTemplateStore)
final accessTemplateStoreProvider =
    FutureProvider<AccessTemplateStore?>.internal(
  accessTemplateStore,
  name: r'accessTemplateStoreProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessTemplateStoreHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AccessTemplateStoreRef = FutureProviderRef<AccessTemplateStore?>;
String _$accessTemplatesHash() => r'54b06df06d18a388c7c8b61aaac86d530758ae3c';

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
///
/// Copied from [accessTemplates].
@ProviderFor(accessTemplates)
final accessTemplatesProvider = FutureProvider<List<AccessTemplate>>.internal(
  accessTemplates,
  name: r'accessTemplatesProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessTemplatesHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AccessTemplatesRef = FutureProviderRef<List<AccessTemplate>>;
String _$tagAccessHash() => r'6499e04ea77a0e761ec5316baaaa413f14b491d7';

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
///
/// Copied from [tagAccess].
@ProviderFor(tagAccess)
final tagAccessProvider = AutoDisposeProvider<TagAccess>.internal(
  tagAccess,
  name: r'tagAccessProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$tagAccessHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef TagAccessRef = AutoDisposeProviderRef<TagAccess>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
