// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'access_admin.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$accessAdminStoreHash() => r'4821004d5d2610cefc3884cf2eff6be1a923b071';

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
///
/// Copied from [accessAdminStore].
@ProviderFor(accessAdminStore)
final accessAdminStoreProvider = FutureProvider<AccessAdminStore?>.internal(
  accessAdminStore,
  name: r'accessAdminStoreProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessAdminStoreHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AccessAdminStoreRef = FutureProviderRef<AccessAdminStore?>;
String _$accessAdminRolesHash() => r'215e24f7b2a4110d4c6765d4f312918d40087a63';

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
///
/// Copied from [accessAdminRoles].
@ProviderFor(accessAdminRoles)
final accessAdminRolesProvider =
    AutoDisposeFutureProvider<List<AccessRole>>.internal(
  accessAdminRoles,
  name: r'accessAdminRolesProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessAdminRolesHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AccessAdminRolesRef = AutoDisposeFutureProviderRef<List<AccessRole>>;
String _$accessAdminUsersHash() => r'8e5466578d2a5b426d40571ad49e4724555d0424';

/// Every account, ordered by username, for the users section.
///
/// Autodispose, empty-when-null and error-propagating for the same three
/// reasons as [accessAdminRoles]; the two are deliberately the same shape so a
/// reader of either section is not learning two conventions.
///
/// Copied from [accessAdminUsers].
@ProviderFor(accessAdminUsers)
final accessAdminUsersProvider =
    AutoDisposeFutureProvider<List<AppUserData>>.internal(
  accessAdminUsers,
  name: r'accessAdminUsersProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessAdminUsersHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AccessAdminUsersRef = AutoDisposeFutureProviderRef<List<AppUserData>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
