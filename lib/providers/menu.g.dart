// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'menu.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$menuTreeHash() => r'656dbcb662f24e15783d59e6ee4976575bb28f9f';

/// The full menu tree: every published page and every built-in entry, composed
/// live and session-blind.
///
/// Recomposes when [pageManagerProvider] answers — which is when the database
/// copy of the pages lands, and again whenever the page editor saves and
/// invalidates it. Until then it composes from [bootstrapPageManagerProvider],
/// the device-local cache `main()` seeds, exactly as the plant page already
/// does; a station whose database is slow shows its last-known menu rather
/// than nothing.
///
/// **Route groups are redeclared here**, through [RouteRegistry.replaceMenu],
/// because the groups and the tree are the same fact and must not be able to
/// come from two different snapshots of it.
///
/// The `RouteRegistry` menu list is written here as a mirror for the handful
/// of synchronous readers that have not migrated (the page editor, two
/// scaffold helpers). New code reads this provider.
///
/// Copied from [menuTree].
@ProviderFor(menuTree)
final menuTreeProvider = Provider<List<MenuItem>>.internal(
  menuTree,
  name: r'menuTreeProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$menuTreeHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef MenuTreeRef = ProviderRef<List<MenuItem>>;
String _$visibleMenuHash() => r'25a054a41df623f9aeaba1bbd0132c0adb53f768';

/// [menuTreeProvider] filtered by [resolvePageAccess], for the session in
/// force.
///
/// Watching `accessSessionProvider` here is the whole of amendment 2: a
/// sign-in rebuilds this provider, and every scaffold watching it rebuilds its
/// bar. Nothing upstream is touched.
///
/// A **leaf** survives when this session may open it. A **section** survives
/// when any leaf beneath it does — which is what makes a section whose pages
/// are all hidden disappear, the behaviour the popup menu already had for
/// group-locked entries.
///
/// Entries with no path and no children (neither a page nor a section) are
/// kept: they are not something this filter has an opinion about.
///
/// Copied from [visibleMenu].
@ProviderFor(visibleMenu)
final visibleMenuProvider = Provider<VisibleMenu>.internal(
  visibleMenu,
  name: r'visibleMenuProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$visibleMenuHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef VisibleMenuRef = ProviderRef<VisibleMenu>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
