// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'audit_trail.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$auditTrailStoreHash() => r'5d1dda178789538423946e8bf536df04a67f5d2b';

/// Reads of `audit_entry`, or null when this station has no database.
///
/// Null is a normal state, exactly as it is for `accessRepositoryProvider` and
/// for `accessTemplateStoreProvider` next door: no Postgres configured, and
/// again during the boot window before the connection opens. The two causes are
/// **indistinguishable by design** — `databaseProvider` returns null for both —
/// which is why the page's copy names no cause and says only that the trail is
/// unavailable.
///
/// `keepAlive`, unlike [auditTrailEntriesProvider] below: this holds the handle
/// `databaseProvider` already owns and rebuilding it on every page visit would
/// be churn for nothing. The query result is the thing worth releasing.
///
/// Copied from [auditTrailStore].
@ProviderFor(auditTrailStore)
final auditTrailStoreProvider = FutureProvider<AuditTrailStore?>.internal(
  auditTrailStore,
  name: r'auditTrailStoreProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$auditTrailStoreHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AuditTrailStoreRef = FutureProviderRef<AuditTrailStore?>;
String _$auditTrailEntriesHash() => r'42ac457c602aa4af8e9b1da587fc2414be63f096';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

/// One [AuditQuery], one statement, one set of grouped actions — or null when
/// this station has no database.
///
/// ## Why this one is autoDispose where its neighbours are not
///
/// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
/// stated reason: they feed the plant-connection policy, and rebuilding them
/// would rebuild the database handle — and with it every OPC UA subscription on
/// the panel — on every sign-in. Nothing of the sort is true here. This feeds
/// one page and nothing else, so holding a query result after the page is gone
/// is a cache nobody reads and a handle held on behalf of nobody.
/// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
/// copies; the family argument is the only thing this one adds.
///
/// ## Null, error and empty are three answers
///
/// Null means the trail is **unavailable** — no database. An error means the
/// database was there and the read failed, which the page also renders as
/// unavailable, and which must not be swallowed here: "nothing matched" is a
/// claim about the plant's history and a failed read is not entitled to make
/// it. An [AuditTrailResult] with no actions means the query ran and matched
/// nothing.
///
/// ## Refresh
///
/// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
/// Nothing here polls; see the library doc for why, and for what a future
/// live-update hook would have to look like instead.
///
/// Copied from [auditTrailEntries].
@ProviderFor(auditTrailEntries)
const auditTrailEntriesProvider = AuditTrailEntriesFamily();

/// One [AuditQuery], one statement, one set of grouped actions — or null when
/// this station has no database.
///
/// ## Why this one is autoDispose where its neighbours are not
///
/// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
/// stated reason: they feed the plant-connection policy, and rebuilding them
/// would rebuild the database handle — and with it every OPC UA subscription on
/// the panel — on every sign-in. Nothing of the sort is true here. This feeds
/// one page and nothing else, so holding a query result after the page is gone
/// is a cache nobody reads and a handle held on behalf of nobody.
/// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
/// copies; the family argument is the only thing this one adds.
///
/// ## Null, error and empty are three answers
///
/// Null means the trail is **unavailable** — no database. An error means the
/// database was there and the read failed, which the page also renders as
/// unavailable, and which must not be swallowed here: "nothing matched" is a
/// claim about the plant's history and a failed read is not entitled to make
/// it. An [AuditTrailResult] with no actions means the query ran and matched
/// nothing.
///
/// ## Refresh
///
/// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
/// Nothing here polls; see the library doc for why, and for what a future
/// live-update hook would have to look like instead.
///
/// Copied from [auditTrailEntries].
class AuditTrailEntriesFamily extends Family<AsyncValue<AuditTrailResult?>> {
  /// One [AuditQuery], one statement, one set of grouped actions — or null when
  /// this station has no database.
  ///
  /// ## Why this one is autoDispose where its neighbours are not
  ///
  /// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
  /// stated reason: they feed the plant-connection policy, and rebuilding them
  /// would rebuild the database handle — and with it every OPC UA subscription on
  /// the panel — on every sign-in. Nothing of the sort is true here. This feeds
  /// one page and nothing else, so holding a query result after the page is gone
  /// is a cache nobody reads and a handle held on behalf of nobody.
  /// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
  /// copies; the family argument is the only thing this one adds.
  ///
  /// ## Null, error and empty are three answers
  ///
  /// Null means the trail is **unavailable** — no database. An error means the
  /// database was there and the read failed, which the page also renders as
  /// unavailable, and which must not be swallowed here: "nothing matched" is a
  /// claim about the plant's history and a failed read is not entitled to make
  /// it. An [AuditTrailResult] with no actions means the query ran and matched
  /// nothing.
  ///
  /// ## Refresh
  ///
  /// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
  /// Nothing here polls; see the library doc for why, and for what a future
  /// live-update hook would have to look like instead.
  ///
  /// Copied from [auditTrailEntries].
  const AuditTrailEntriesFamily();

  /// One [AuditQuery], one statement, one set of grouped actions — or null when
  /// this station has no database.
  ///
  /// ## Why this one is autoDispose where its neighbours are not
  ///
  /// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
  /// stated reason: they feed the plant-connection policy, and rebuilding them
  /// would rebuild the database handle — and with it every OPC UA subscription on
  /// the panel — on every sign-in. Nothing of the sort is true here. This feeds
  /// one page and nothing else, so holding a query result after the page is gone
  /// is a cache nobody reads and a handle held on behalf of nobody.
  /// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
  /// copies; the family argument is the only thing this one adds.
  ///
  /// ## Null, error and empty are three answers
  ///
  /// Null means the trail is **unavailable** — no database. An error means the
  /// database was there and the read failed, which the page also renders as
  /// unavailable, and which must not be swallowed here: "nothing matched" is a
  /// claim about the plant's history and a failed read is not entitled to make
  /// it. An [AuditTrailResult] with no actions means the query ran and matched
  /// nothing.
  ///
  /// ## Refresh
  ///
  /// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
  /// Nothing here polls; see the library doc for why, and for what a future
  /// live-update hook would have to look like instead.
  ///
  /// Copied from [auditTrailEntries].
  AuditTrailEntriesProvider call(
    AuditQuery query,
  ) {
    return AuditTrailEntriesProvider(
      query,
    );
  }

  @override
  AuditTrailEntriesProvider getProviderOverride(
    covariant AuditTrailEntriesProvider provider,
  ) {
    return call(
      provider.query,
    );
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'auditTrailEntriesProvider';
}

/// One [AuditQuery], one statement, one set of grouped actions — or null when
/// this station has no database.
///
/// ## Why this one is autoDispose where its neighbours are not
///
/// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
/// stated reason: they feed the plant-connection policy, and rebuilding them
/// would rebuild the database handle — and with it every OPC UA subscription on
/// the panel — on every sign-in. Nothing of the sort is true here. This feeds
/// one page and nothing else, so holding a query result after the page is gone
/// is a cache nobody reads and a handle held on behalf of nobody.
/// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
/// copies; the family argument is the only thing this one adds.
///
/// ## Null, error and empty are three answers
///
/// Null means the trail is **unavailable** — no database. An error means the
/// database was there and the read failed, which the page also renders as
/// unavailable, and which must not be swallowed here: "nothing matched" is a
/// claim about the plant's history and a failed read is not entitled to make
/// it. An [AuditTrailResult] with no actions means the query ran and matched
/// nothing.
///
/// ## Refresh
///
/// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
/// Nothing here polls; see the library doc for why, and for what a future
/// live-update hook would have to look like instead.
///
/// Copied from [auditTrailEntries].
class AuditTrailEntriesProvider
    extends AutoDisposeFutureProvider<AuditTrailResult?> {
  /// One [AuditQuery], one statement, one set of grouped actions — or null when
  /// this station has no database.
  ///
  /// ## Why this one is autoDispose where its neighbours are not
  ///
  /// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
  /// stated reason: they feed the plant-connection policy, and rebuilding them
  /// would rebuild the database handle — and with it every OPC UA subscription on
  /// the panel — on every sign-in. Nothing of the sort is true here. This feeds
  /// one page and nothing else, so holding a query result after the page is gone
  /// is a cache nobody reads and a handle held on behalf of nobody.
  /// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
  /// copies; the family argument is the only thing this one adds.
  ///
  /// ## Null, error and empty are three answers
  ///
  /// Null means the trail is **unavailable** — no database. An error means the
  /// database was there and the read failed, which the page also renders as
  /// unavailable, and which must not be swallowed here: "nothing matched" is a
  /// claim about the plant's history and a failed read is not entitled to make
  /// it. An [AuditTrailResult] with no actions means the query ran and matched
  /// nothing.
  ///
  /// ## Refresh
  ///
  /// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
  /// Nothing here polls; see the library doc for why, and for what a future
  /// live-update hook would have to look like instead.
  ///
  /// Copied from [auditTrailEntries].
  AuditTrailEntriesProvider(
    AuditQuery query,
  ) : this._internal(
          (ref) => auditTrailEntries(
            ref as AuditTrailEntriesRef,
            query,
          ),
          from: auditTrailEntriesProvider,
          name: r'auditTrailEntriesProvider',
          debugGetCreateSourceHash:
              const bool.fromEnvironment('dart.vm.product')
                  ? null
                  : _$auditTrailEntriesHash,
          dependencies: AuditTrailEntriesFamily._dependencies,
          allTransitiveDependencies:
              AuditTrailEntriesFamily._allTransitiveDependencies,
          query: query,
        );

  AuditTrailEntriesProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.query,
  }) : super.internal();

  final AuditQuery query;

  @override
  Override overrideWith(
    FutureOr<AuditTrailResult?> Function(AuditTrailEntriesRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: AuditTrailEntriesProvider._internal(
        (ref) => create(ref as AuditTrailEntriesRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        query: query,
      ),
    );
  }

  @override
  AutoDisposeFutureProviderElement<AuditTrailResult?> createElement() {
    return _AuditTrailEntriesProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is AuditTrailEntriesProvider && other.query == query;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, query.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin AuditTrailEntriesRef on AutoDisposeFutureProviderRef<AuditTrailResult?> {
  /// The parameter `query` of this provider.
  AuditQuery get query;
}

class _AuditTrailEntriesProviderElement
    extends AutoDisposeFutureProviderElement<AuditTrailResult?>
    with AuditTrailEntriesRef {
  _AuditTrailEntriesProviderElement(super.provider);

  @override
  AuditQuery get query => (origin as AuditTrailEntriesProvider).query;
}

String _$auditWhoOptionsHash() => r'314988cb41608661fc6d7e47b23dac945325b10e';

/// Every distinct `who` in the table, for the filter bar's dropdown.
///
/// Answers an **empty list** — not null and not an error — when the store is
/// null. A `who` dropdown with no options on an unreachable database is
/// correct; an exception here would take the whole filter bar down with it, and
/// the page already says "unavailable" once, from [auditTrailEntriesProvider].
/// Saying it twice, in two shapes, is not more honest.
///
/// Copied from [auditWhoOptions].
@ProviderFor(auditWhoOptions)
final auditWhoOptionsProvider =
    AutoDisposeFutureProvider<List<String>>.internal(
  auditWhoOptions,
  name: r'auditWhoOptionsProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$auditWhoOptionsHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AuditWhoOptionsRef = AutoDisposeFutureProviderRef<List<String>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
