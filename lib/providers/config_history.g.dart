// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'config_history.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$configChangeStoreHash() => r'f10c5493782d416074739e24d1416d5f06bec87e';

/// Reads of `config_change`, or null when this station has no database.
///
/// Null is a normal state, exactly as it is for [auditTrailStoreProvider] next
/// door: no Postgres configured, and again during the boot window before the
/// connection opens. The two causes are **indistinguishable by design** —
/// `databaseProvider` returns null for both — which is why the page's copy
/// names no cause and says only that the history is unavailable.
///
/// `keepAlive`, for the same reason the audit store is: this holds the handle
/// `databaseProvider` already owns, and the query result is the thing worth
/// releasing.
///
/// Copied from [configChangeStore].
@ProviderFor(configChangeStore)
final configChangeStoreProvider = FutureProvider<ConfigChangeStore?>.internal(
  configChangeStore,
  name: r'configChangeStoreProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$configChangeStoreHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ConfigChangeStoreRef = FutureProviderRef<ConfigChangeStore?>;
String _$configHistoryActionsHash() =>
    r'a0864a1effb559bef70d5f7863fc068c3dba64d9';

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

/// One [ConfigChangeQuery], one page of history — or null when this station
/// has no database.
///
/// ## Why the change rows are the primary read
///
/// Three statements, in this order:
///
/// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
///    the subject of the page, and it is the read that surfaces an action
///    whose `audit_entry` header is missing. Starting from the audit side
///    would never ask about such an action.
/// 2. `entriesByAction` — the headers for the action ids those rows named. An
///    id with no header is a parentless action and renders as one.
/// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
///    changes hidden" can exist: the excluded rows are not in the result set.
///
/// ## Null, error and empty are three answers
///
/// Null means the history is **unavailable** — no database. An error means the
/// database was there and the read failed, which must not be swallowed here:
/// "nothing changed" is a claim about the plant's configuration and a failed
/// read is not entitled to make it. A [ConfigHistoryResult] with no actions
/// means the query ran and matched nothing.
///
/// Copied from [configHistoryActions].
@ProviderFor(configHistoryActions)
const configHistoryActionsProvider = ConfigHistoryActionsFamily();

/// One [ConfigChangeQuery], one page of history — or null when this station
/// has no database.
///
/// ## Why the change rows are the primary read
///
/// Three statements, in this order:
///
/// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
///    the subject of the page, and it is the read that surfaces an action
///    whose `audit_entry` header is missing. Starting from the audit side
///    would never ask about such an action.
/// 2. `entriesByAction` — the headers for the action ids those rows named. An
///    id with no header is a parentless action and renders as one.
/// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
///    changes hidden" can exist: the excluded rows are not in the result set.
///
/// ## Null, error and empty are three answers
///
/// Null means the history is **unavailable** — no database. An error means the
/// database was there and the read failed, which must not be swallowed here:
/// "nothing changed" is a claim about the plant's configuration and a failed
/// read is not entitled to make it. A [ConfigHistoryResult] with no actions
/// means the query ran and matched nothing.
///
/// Copied from [configHistoryActions].
class ConfigHistoryActionsFamily
    extends Family<AsyncValue<ConfigHistoryResult?>> {
  /// One [ConfigChangeQuery], one page of history — or null when this station
  /// has no database.
  ///
  /// ## Why the change rows are the primary read
  ///
  /// Three statements, in this order:
  ///
  /// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
  ///    the subject of the page, and it is the read that surfaces an action
  ///    whose `audit_entry` header is missing. Starting from the audit side
  ///    would never ask about such an action.
  /// 2. `entriesByAction` — the headers for the action ids those rows named. An
  ///    id with no header is a parentless action and renders as one.
  /// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
  ///    changes hidden" can exist: the excluded rows are not in the result set.
  ///
  /// ## Null, error and empty are three answers
  ///
  /// Null means the history is **unavailable** — no database. An error means the
  /// database was there and the read failed, which must not be swallowed here:
  /// "nothing changed" is a claim about the plant's configuration and a failed
  /// read is not entitled to make it. A [ConfigHistoryResult] with no actions
  /// means the query ran and matched nothing.
  ///
  /// Copied from [configHistoryActions].
  const ConfigHistoryActionsFamily();

  /// One [ConfigChangeQuery], one page of history — or null when this station
  /// has no database.
  ///
  /// ## Why the change rows are the primary read
  ///
  /// Three statements, in this order:
  ///
  /// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
  ///    the subject of the page, and it is the read that surfaces an action
  ///    whose `audit_entry` header is missing. Starting from the audit side
  ///    would never ask about such an action.
  /// 2. `entriesByAction` — the headers for the action ids those rows named. An
  ///    id with no header is a parentless action and renders as one.
  /// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
  ///    changes hidden" can exist: the excluded rows are not in the result set.
  ///
  /// ## Null, error and empty are three answers
  ///
  /// Null means the history is **unavailable** — no database. An error means the
  /// database was there and the read failed, which must not be swallowed here:
  /// "nothing changed" is a claim about the plant's configuration and a failed
  /// read is not entitled to make it. A [ConfigHistoryResult] with no actions
  /// means the query ran and matched nothing.
  ///
  /// Copied from [configHistoryActions].
  ConfigHistoryActionsProvider call(
    ConfigChangeQuery query,
  ) {
    return ConfigHistoryActionsProvider(
      query,
    );
  }

  @override
  ConfigHistoryActionsProvider getProviderOverride(
    covariant ConfigHistoryActionsProvider provider,
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
  String? get name => r'configHistoryActionsProvider';
}

/// One [ConfigChangeQuery], one page of history — or null when this station
/// has no database.
///
/// ## Why the change rows are the primary read
///
/// Three statements, in this order:
///
/// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
///    the subject of the page, and it is the read that surfaces an action
///    whose `audit_entry` header is missing. Starting from the audit side
///    would never ask about such an action.
/// 2. `entriesByAction` — the headers for the action ids those rows named. An
///    id with no header is a parentless action and renders as one.
/// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
///    changes hidden" can exist: the excluded rows are not in the result set.
///
/// ## Null, error and empty are three answers
///
/// Null means the history is **unavailable** — no database. An error means the
/// database was there and the read failed, which must not be swallowed here:
/// "nothing changed" is a claim about the plant's configuration and a failed
/// read is not entitled to make it. A [ConfigHistoryResult] with no actions
/// means the query ran and matched nothing.
///
/// Copied from [configHistoryActions].
class ConfigHistoryActionsProvider
    extends AutoDisposeFutureProvider<ConfigHistoryResult?> {
  /// One [ConfigChangeQuery], one page of history — or null when this station
  /// has no database.
  ///
  /// ## Why the change rows are the primary read
  ///
  /// Three statements, in this order:
  ///
  /// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
  ///    the subject of the page, and it is the read that surfaces an action
  ///    whose `audit_entry` header is missing. Starting from the audit side
  ///    would never ask about such an action.
  /// 2. `entriesByAction` — the headers for the action ids those rows named. An
  ///    id with no header is a parentless action and renders as one.
  /// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
  ///    changes hidden" can exist: the excluded rows are not in the result set.
  ///
  /// ## Null, error and empty are three answers
  ///
  /// Null means the history is **unavailable** — no database. An error means the
  /// database was there and the read failed, which must not be swallowed here:
  /// "nothing changed" is a claim about the plant's configuration and a failed
  /// read is not entitled to make it. A [ConfigHistoryResult] with no actions
  /// means the query ran and matched nothing.
  ///
  /// Copied from [configHistoryActions].
  ConfigHistoryActionsProvider(
    ConfigChangeQuery query,
  ) : this._internal(
          (ref) => configHistoryActions(
            ref as ConfigHistoryActionsRef,
            query,
          ),
          from: configHistoryActionsProvider,
          name: r'configHistoryActionsProvider',
          debugGetCreateSourceHash:
              const bool.fromEnvironment('dart.vm.product')
                  ? null
                  : _$configHistoryActionsHash,
          dependencies: ConfigHistoryActionsFamily._dependencies,
          allTransitiveDependencies:
              ConfigHistoryActionsFamily._allTransitiveDependencies,
          query: query,
        );

  ConfigHistoryActionsProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.query,
  }) : super.internal();

  final ConfigChangeQuery query;

  @override
  Override overrideWith(
    FutureOr<ConfigHistoryResult?> Function(ConfigHistoryActionsRef provider)
        create,
  ) {
    return ProviderOverride(
      origin: this,
      override: ConfigHistoryActionsProvider._internal(
        (ref) => create(ref as ConfigHistoryActionsRef),
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
  AutoDisposeFutureProviderElement<ConfigHistoryResult?> createElement() {
    return _ConfigHistoryActionsProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is ConfigHistoryActionsProvider && other.query == query;
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
mixin ConfigHistoryActionsRef
    on AutoDisposeFutureProviderRef<ConfigHistoryResult?> {
  /// The parameter `query` of this provider.
  ConfigChangeQuery get query;
}

class _ConfigHistoryActionsProviderElement
    extends AutoDisposeFutureProviderElement<ConfigHistoryResult?>
    with ConfigHistoryActionsRef {
  _ConfigHistoryActionsProviderElement(super.provider);

  @override
  ConfigChangeQuery get query => (origin as ConfigHistoryActionsProvider).query;
}

String _$configActionChangesHash() =>
    r'0c5b2e07e4e713efd8b88bf0f342c493e389f11c';

/// One action's `config_change` rows, **unfiltered** — what the expander opens.
///
/// The join [configHistoryActionsProvider] cannot do: its rows passed the
/// filters, and an action whose siblings did not is exactly the one an
/// operator expands. Reading by `action_id` here returns all of them, in the
/// order they were written.
///
/// An action with no rows is absent from `changesByAction`'s map, which this
/// renders as an empty list — and an empty list here is **not** the same claim
/// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
/// `ConfigChangeStore.entityHistory` when the question is about one entity;
/// its `isSilent` carries that distinction properly.
///
/// Copied from [configActionChanges].
@ProviderFor(configActionChanges)
const configActionChangesProvider = ConfigActionChangesFamily();

/// One action's `config_change` rows, **unfiltered** — what the expander opens.
///
/// The join [configHistoryActionsProvider] cannot do: its rows passed the
/// filters, and an action whose siblings did not is exactly the one an
/// operator expands. Reading by `action_id` here returns all of them, in the
/// order they were written.
///
/// An action with no rows is absent from `changesByAction`'s map, which this
/// renders as an empty list — and an empty list here is **not** the same claim
/// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
/// `ConfigChangeStore.entityHistory` when the question is about one entity;
/// its `isSilent` carries that distinction properly.
///
/// Copied from [configActionChanges].
class ConfigActionChangesFamily
    extends Family<AsyncValue<List<ConfigChangeRecord>>> {
  /// One action's `config_change` rows, **unfiltered** — what the expander opens.
  ///
  /// The join [configHistoryActionsProvider] cannot do: its rows passed the
  /// filters, and an action whose siblings did not is exactly the one an
  /// operator expands. Reading by `action_id` here returns all of them, in the
  /// order they were written.
  ///
  /// An action with no rows is absent from `changesByAction`'s map, which this
  /// renders as an empty list — and an empty list here is **not** the same claim
  /// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
  /// `ConfigChangeStore.entityHistory` when the question is about one entity;
  /// its `isSilent` carries that distinction properly.
  ///
  /// Copied from [configActionChanges].
  const ConfigActionChangesFamily();

  /// One action's `config_change` rows, **unfiltered** — what the expander opens.
  ///
  /// The join [configHistoryActionsProvider] cannot do: its rows passed the
  /// filters, and an action whose siblings did not is exactly the one an
  /// operator expands. Reading by `action_id` here returns all of them, in the
  /// order they were written.
  ///
  /// An action with no rows is absent from `changesByAction`'s map, which this
  /// renders as an empty list — and an empty list here is **not** the same claim
  /// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
  /// `ConfigChangeStore.entityHistory` when the question is about one entity;
  /// its `isSilent` carries that distinction properly.
  ///
  /// Copied from [configActionChanges].
  ConfigActionChangesProvider call(
    String actionId,
  ) {
    return ConfigActionChangesProvider(
      actionId,
    );
  }

  @override
  ConfigActionChangesProvider getProviderOverride(
    covariant ConfigActionChangesProvider provider,
  ) {
    return call(
      provider.actionId,
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
  String? get name => r'configActionChangesProvider';
}

/// One action's `config_change` rows, **unfiltered** — what the expander opens.
///
/// The join [configHistoryActionsProvider] cannot do: its rows passed the
/// filters, and an action whose siblings did not is exactly the one an
/// operator expands. Reading by `action_id` here returns all of them, in the
/// order they were written.
///
/// An action with no rows is absent from `changesByAction`'s map, which this
/// renders as an empty list — and an empty list here is **not** the same claim
/// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
/// `ConfigChangeStore.entityHistory` when the question is about one entity;
/// its `isSilent` carries that distinction properly.
///
/// Copied from [configActionChanges].
class ConfigActionChangesProvider
    extends AutoDisposeFutureProvider<List<ConfigChangeRecord>> {
  /// One action's `config_change` rows, **unfiltered** — what the expander opens.
  ///
  /// The join [configHistoryActionsProvider] cannot do: its rows passed the
  /// filters, and an action whose siblings did not is exactly the one an
  /// operator expands. Reading by `action_id` here returns all of them, in the
  /// order they were written.
  ///
  /// An action with no rows is absent from `changesByAction`'s map, which this
  /// renders as an empty list — and an empty list here is **not** the same claim
  /// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
  /// `ConfigChangeStore.entityHistory` when the question is about one entity;
  /// its `isSilent` carries that distinction properly.
  ///
  /// Copied from [configActionChanges].
  ConfigActionChangesProvider(
    String actionId,
  ) : this._internal(
          (ref) => configActionChanges(
            ref as ConfigActionChangesRef,
            actionId,
          ),
          from: configActionChangesProvider,
          name: r'configActionChangesProvider',
          debugGetCreateSourceHash:
              const bool.fromEnvironment('dart.vm.product')
                  ? null
                  : _$configActionChangesHash,
          dependencies: ConfigActionChangesFamily._dependencies,
          allTransitiveDependencies:
              ConfigActionChangesFamily._allTransitiveDependencies,
          actionId: actionId,
        );

  ConfigActionChangesProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.actionId,
  }) : super.internal();

  final String actionId;

  @override
  Override overrideWith(
    FutureOr<List<ConfigChangeRecord>> Function(ConfigActionChangesRef provider)
        create,
  ) {
    return ProviderOverride(
      origin: this,
      override: ConfigActionChangesProvider._internal(
        (ref) => create(ref as ConfigActionChangesRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        actionId: actionId,
      ),
    );
  }

  @override
  AutoDisposeFutureProviderElement<List<ConfigChangeRecord>> createElement() {
    return _ConfigActionChangesProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is ConfigActionChangesProvider && other.actionId == actionId;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, actionId.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin ConfigActionChangesRef
    on AutoDisposeFutureProviderRef<List<ConfigChangeRecord>> {
  /// The parameter `actionId` of this provider.
  String get actionId;
}

class _ConfigActionChangesProviderElement
    extends AutoDisposeFutureProviderElement<List<ConfigChangeRecord>>
    with ConfigActionChangesRef {
  _ConfigActionChangesProviderElement(super.provider);

  @override
  String get actionId => (origin as ConfigActionChangesProvider).actionId;
}

String _$configHistoryFilterStateHash() =>
    r'c792011181033ac5762d3318d49849fac491859e';

/// What the filter bar holds.
///
/// A notifier rather than a plain state provider so the page mutates it by
/// name — `setEntityPrefix`, `clear` — instead of rebuilding the whole value at
/// six call sites. `ConfigHistoryFilters.copyWith` carries the clear flags that
/// make "set this to null" expressible; see its doc for why a bare nullable
/// parameter cannot.
///
/// Copied from [ConfigHistoryFilterState].
@ProviderFor(ConfigHistoryFilterState)
final configHistoryFilterStateProvider = AutoDisposeNotifierProvider<
    ConfigHistoryFilterState, ConfigHistoryFilters>.internal(
  ConfigHistoryFilterState.new,
  name: r'configHistoryFilterStateProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$configHistoryFilterStateHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$ConfigHistoryFilterState = AutoDisposeNotifier<ConfigHistoryFilters>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
