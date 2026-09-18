// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'preferences.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$preferencesHash() => r'cecea358ebdb1045cb3f328f4c7033a28c0c82f0';

/// The shared configuration store, **guarded**.
///
/// Every caller in the app already reads this provider, so wrapping the value
/// here is what puts a check and an audit row on every configuration write in
/// the app without changing a single call site.
///
/// Copied from [preferences].
@ProviderFor(preferences)
final preferencesProvider = FutureProvider<Preferences>.internal(
  preferences,
  name: r'preferencesProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$preferencesHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef PreferencesRef = FutureProviderRef<Preferences>;
String _$systemPreferencesHash() => r'e714d27544ea2c138954a1959976e55ada6cbaf5';

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
final systemPreferencesProvider = FutureProvider<Preferences>.internal(
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
typedef SystemPreferencesRef = FutureProviderRef<Preferences>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
