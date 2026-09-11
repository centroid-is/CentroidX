// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'alarm.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$alarmManHash() => r'7e2d1c0c1866b4e43b8086ae7c00bf110b56f857';

/// Where this panel's alarms come from, which depends on the transport.
///
/// The type is [AlarmSource], not [AlarmMan], and the branch is the same one
/// `state_man.dart:126` makes. In direct mode this station is wired to the
/// PLCs and evaluates its own rules, so it builds an [AlarmMan] and nothing
/// about that changes. In gateway mode the backend's alarm engine has already
/// evaluated them and published the answer under `ALARM.active`, so the panel
/// is TOLD its active set and builds a [RelayAlarmSource], which evaluates
/// nothing and subscribes to no rule variable at all.
///
/// There is deliberately **no fallback**. If gateway mode resolves a
/// `StateMan` with no relay client behind it, this refuses by name rather than
/// quietly building an [AlarmMan]: a silent fallback is precisely how
/// panel-side evaluation comes back (T-14-39), and the plant symptom of it
/// coming back is measured — the rig's rule on `__agg_default_connected`,
/// which nothing in this repository produces, stands permanently on a healthy
/// plant when a gateway-mode panel evaluates it.
///
/// Copied from [alarmMan].
@ProviderFor(alarmMan)
final alarmManProvider = FutureProvider<AlarmSource>.internal(
  alarmMan,
  name: r'alarmManProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$alarmManHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AlarmManRef = FutureProviderRef<AlarmSource>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
