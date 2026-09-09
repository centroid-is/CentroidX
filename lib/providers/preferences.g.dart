// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'preferences.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$preferencesHash() => r'dc99c11767cb2c9a10a12a5e64ba596d295694ff';

/// The shared configuration store, **guarded**.
///
/// Every caller in the app already reads this provider, so wrapping the value
/// here is what puts a check and an audit row on every configuration write in
/// the app without changing a single call site.
///
/// Copied from [preferences].
@ProviderFor(preferences)
final preferencesProvider = FutureProvider<PreferencesApi>.internal(
  preferences,
  name: r'preferencesProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$preferencesHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef PreferencesRef = FutureProviderRef<PreferencesApi>;
String _$systemPreferencesHash() => r'25476b8213a731afafd3e31b3b2f0c1f3e29132e';

/// The unchecked write path, for the defaults the app writes for itself.
///
/// **This is not "writes we want to allow".** It is "writes the app makes on
/// its own behalf when nobody has acted" — a config default written because
/// storage is empty. A Save button never qualifies, however inconvenient its
/// denial is; the fix for a legitimate operator write being refused is a rule
/// in `kPrefAccessRules`, not a call to this provider.
///
/// Every write through it still produces one audit row, marked `origin:
/// 'system'`. The set of files that may read this provider is capped by
/// [kSystemWriteCallSites] and by a test that compares that constant against
/// the source in both directions.
///
/// Falls back to the guarded object when `preferencesProvider` has been
/// overridden with something that is not a [GuardedPreferences], which is what
/// a test that overrides the store gets. A cast would turn that into a crash
/// in every such test for no gain.
///
/// Copied from [systemPreferences].
@ProviderFor(systemPreferences)
final systemPreferencesProvider = FutureProvider<PreferencesApi>.internal(
  systemPreferences,
  name: r'systemPreferencesProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$systemPreferencesHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SystemPreferencesRef = FutureProviderRef<PreferencesApi>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
