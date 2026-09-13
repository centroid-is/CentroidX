// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'alarm_auto_navigation.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$alarmAutoNavigationHash() =>
    r'ac6bd846b3cb778b84a83a95a91a29c70fd1ff72';

/// The live navigator, and a signal to look at it.
///
/// The state is a counter, not the target: the target is taken from the
/// navigator by whoever can answer [AlarmAutoNavigator.take]'s questions, and
/// a counter is the smallest thing that makes `ref.listen` fire for a second
/// raise that happens to name the same page as the first.
///
/// Keep-alive, and deliberately not rebuilt by anything: navigation must
/// outlive the page it navigates away from.
///
/// Copied from [AlarmAutoNavigation].
@ProviderFor(AlarmAutoNavigation)
final alarmAutoNavigationProvider =
    NotifierProvider<AlarmAutoNavigation, int>.internal(
  AlarmAutoNavigation.new,
  name: r'alarmAutoNavigationProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$alarmAutoNavigationHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AlarmAutoNavigation = Notifier<int>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
