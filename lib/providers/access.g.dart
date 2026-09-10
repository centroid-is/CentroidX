// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'access.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$accessRepositoryHash() => r'47922da60536a5d1379c44146bc3408e2c561961';

/// Reads and writes for `app_role` and `app_user`, or null when this station
/// has no database.
///
/// Null is a normal state, not an error: `databaseProvider` yields null when
/// no Postgres is configured, and again during the boot window before the
/// connection opens. Every provider below survives that.
///
/// Copied from [accessRepository].
@ProviderFor(accessRepository)
final accessRepositoryProvider = FutureProvider<AccessRepository?>.internal(
  accessRepository,
  name: r'accessRepositoryProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessRepositoryHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AccessRepositoryRef = FutureProviderRef<AccessRepository?>;
String _$authProviderHash() => r'f344be07868fbf4975f0c3d9f260fa87191ea622';

/// The authentication seam.
///
/// Named for the interface it provides rather than for [LocalAuthProvider],
/// the implementation behind it today. When OIDC lands it becomes an override
/// of this provider rather than a rename of every call site — which is the
/// whole reason `AuthProvider` is an interface.
///
/// Copied from [authProvider].
@ProviderFor(authProvider)
final authProviderProvider = FutureProvider<AuthProvider?>.internal(
  authProvider,
  name: r'authProviderProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$authProviderHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AuthProviderRef = FutureProviderRef<AuthProvider?>;
String _$auditSinkHash() => r'8c60017008841289ac9c8809af9b989e2d0c58d1';

/// Where audit rows go.
///
/// [NullAuditSink] when there is no database. That covers two real cases: the
/// boot window before the connection is open, and a station commissioned with
/// no Postgres at all. Losing the trail there is preferable to failing to
/// boot — an HMI that will not start because it cannot write an audit row is a
/// stopped line.
///
/// But it **is** a gap, and it is the kind of gap nobody notices, because a
/// missing row looks exactly like an action that never happened. What makes it
/// visible is the sink's own error logging: [DriftAuditSink] names every row it
/// loses. [NullAuditSink] is silent by design, so a station running without a
/// database is knowingly running without a trail.
///
/// Copied from [auditSink].
@ProviderFor(auditSink)
final auditSinkProvider = FutureProvider<AuditSink>.internal(
  auditSink,
  name: r'auditSinkProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$auditSinkHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AuditSinkRef = FutureProviderRef<AuditSink>;
String _$stationNameHash() => r'74beada44345d4b12893b321c72971feb21f85c4';

/// The hostname of this panel.
///
/// This is the `station` column of every audit row, and it is what lets the
/// plant manager be shown *which panel* a setpoint was changed from. A trail
/// that records who and when but not where cannot answer "was that the packing
/// hall or the freezer?", which on a plant with identical screens in eight
/// rooms is most of the question.
///
/// `'unknown'` rather than a throw if the platform will not say: a nameless
/// station still writes rows, and a row with a vague station beats no row.
///
/// Copied from [stationName].
@ProviderFor(stationName)
final stationNameProvider = Provider<String>.internal(
  stationName,
  name: r'stationNameProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$stationNameHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef StationNameRef = ProviderRef<String>;
String _$inactivityTimeoutHash() => r'bb2aaa4f6d37bed5dd16e8ebf475494c0f181e7d';

/// How long a quiet panel keeps an elevated session, from device-local
/// preferences.
///
/// **Device-local on purpose.** The timeout is a property of the panel, not of
/// the plant: stations on one database front different equipment, and the
/// screen bolted to a packing line in constant use wants a different number
/// from the one in a locked electrical room. Storing it in the shared
/// `preferencesProvider` would let one station's setting decide another's.
///
/// Clamped to [kMinInactivityTimeout]..[kMaxInactivityTimeout] and logged when
/// it clamps — a stray `0` or a fat-fingered `10000` in the preferences file
/// must not turn into a session that ends instantly or never.
///
/// Copied from [inactivityTimeout].
@ProviderFor(inactivityTimeout)
final inactivityTimeoutProvider = FutureProvider<Duration?>.internal(
  inactivityTimeout,
  name: r'inactivityTimeoutProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$inactivityTimeoutHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef InactivityTimeoutRef = FutureProviderRef<Duration?>;
String _$firstUserWindowOpenHash() =>
    r'012d3f6639bb65e570675d77fcd0f22bbc122c22';

/// Whether the first account may still be created.
///
/// False when there is no database, and false when the question cannot be
/// asked. An unreachable database must not look like an open commissioning
/// window: the screen behind this flag creates an Engineering account with no
/// credential required beyond reaching the screen, so the failure direction is
/// "closed".
///
/// This is a convenience for the UI, not the guard. The real check runs inside
/// `AccessRepository.createFirstUser`'s transaction.
///
/// Copied from [firstUserWindowOpen].
@ProviderFor(firstUserWindowOpen)
final firstUserWindowOpenProvider = FutureProvider<bool>.internal(
  firstUserWindowOpen,
  name: r'firstUserWindowOpenProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$firstUserWindowOpenHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef FirstUserWindowOpenRef = FutureProviderRef<bool>;
String _$accessSessionControllerHash() =>
    r'8625ba0e8cdda7155596b5a8ab778cb8af9ea560';

/// Who is standing at this panel, and what they may do.
///
/// Holds the session, restores it across a restart while it is still valid,
/// and drops back to anonymous on inactivity.
///
/// ## The countdown is listener-gated, the session is not
///
/// This provider is `keepAlive` so the *session* survives navigation — walking
/// from the alarm page to a mimic must not sign anybody out. The *countdown* is
/// a different thing: [InactivityMonitor] arms in its stream's `onListen` and
/// disarms in `onCancel`, and this controller subscribes only while the session
/// is elevated **and** something is listening to the provider.
///
/// That pairing is the whole reason plan 01-04 built the monitor the way it
/// did. An always-on `Timer.periodic` in shared plumbing has failed unrelated
/// widget tests in this repo before: a pending timer at the end of a
/// `testWidgets` body fails the test even when the widget under test never
/// touched the thing that armed it. A future refactor that subscribes
/// unconditionally in [build] reintroduces exactly that, and
/// `test/providers/access_session_test.dart` has tests whose only job is to
/// fail if it does.
///
/// ## `expiresAt` is the authority, the timer is only a prompt
///
/// Pausing the countdown must not extend the session. Every re-attach compares
/// `clock.now()` against `expiresAt` first and expires immediately if it has
/// passed; otherwise it arms for the time *remaining* via
/// [InactivityMonitor.arm]. Detaching and re-attaching therefore cannot buy an
/// operator another fifteen minutes.
///
/// Copied from [AccessSessionController].
@ProviderFor(AccessSessionController)
final accessSessionControllerProvider =
    AsyncNotifierProvider<AccessSessionController, AccessSession>.internal(
  AccessSessionController.new,
  name: r'accessSessionControllerProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$accessSessionControllerHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AccessSessionController = AsyncNotifier<AccessSession>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
