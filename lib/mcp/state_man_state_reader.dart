import 'dart:async';
import 'dart:io' as io;

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show ServerAliasProvider, StateReader;

/// [StateReader] implementation backed by the Flutter app's [StateMan].
///
/// Subscribes to each key in [StateMan.keyMappings] and caches values
/// for synchronous access by the MCP server's tag tools. This bridges
/// live OPC UA / M2400 data into the in-process MCP server.
///
/// Usage:
/// ```dart
/// final reader = StateManStateReader(stateMan);
/// await reader.init(); // subscribes to all keys
/// reader.getValue('pump1.speed'); // synchronous cached access
/// reader.dispose(); // cancel all subscriptions
/// ```
class StateManStateReader implements StateReader, ServerAliasProvider {
  final StateMan? _stateMan;

  /// Latest value per subscribed key.
  ///
  /// An entry is either a plain scalar (int, double, bool, String) or a
  /// [_DeferredRender] holding the [DynamicValue] itself. See [_extractValue]
  /// for why the structured ones are not rendered on arrival, and [_render]
  /// for where they are.
  final Map<String, dynamic> _cache = {};
  final Map<String, StreamSubscription<DynamicValue>> _subscriptions = {};

  /// Keys whose subscription is currently being established, so a burst of
  /// queries against a fresh key opens one subscription rather than one per
  /// query.
  final Set<String> _subscribing = {};

  /// Keys available from this reader, re-read from the source on every use.
  ///
  /// In production this consults [StateMan.keyMappings] *live*. It used to be
  /// copied once at construction — which quietly broke the workflow this MCP
  /// server itself prescribes: an agent proposes a key mapping, the operator
  /// accepts it, `StateMan.updateKeyMappings` makes it readable immediately —
  /// and then `get_tag_value` answered "Tag not found" against the stale
  /// snapshot until the app was restarted. The mapping was live everywhere
  /// except in the tool telling the agent it did not exist.
  final List<String> Function() _keySource;

  /// Test-only streams for subscription simulation.
  final Map<String, Stream<DynamicValue>> _testStreams;

  /// Test-only stand-in for [StateMan.subscribe].
  ///
  /// When supplied, [init] awaits this instead of reading [_testStreams],
  /// which lets a test exercise the *awaiting* half of a subscription --
  /// including one that never resolves.
  final Future<Stream<DynamicValue>> Function(String key)? _testSubscribe;

  /// How long a single [StateMan.subscribe] may take before the key is
  /// abandoned.
  ///
  /// A key whose mapping names no server -- or names one that is not
  /// configured -- can leave `subscribe` pending forever rather than
  /// throwing. Without a deadline that one key would stall the whole
  /// warm-up and leave every later key permanently null.
  final Duration subscribeTimeout;

  /// Default deadline for a single subscription.
  static const defaultSubscribeTimeout = Duration(seconds: 15);

  /// How many keys are subscribed concurrently.
  ///
  /// Bounded so a large mapping (>1500 keys in a full plant config) does not
  /// open every subscription against the OPC UA clients at once.
  static const subscribeConcurrency = 32;

  /// Creates a [StateManStateReader] backed by the given [StateMan].
  StateManStateReader(StateMan stateMan,
      {this.subscribeTimeout = defaultSubscribeTimeout})
      : _stateMan = stateMan,
        _keySource = (() => stateMan.keyMappings.nodes.keys.toList()),
        _testStreams = const {},
        _testSubscribe = null;

  /// Creates a [StateManStateReader] for unit testing without a real [StateMan].
  ///
  /// Accepts a list of keys and a map of streams to simulate subscriptions.
  /// This avoids the need for a real OPC UA / FFI-backed StateMan instance.
  ///
  /// Pass [subscribe] instead of [streams] to simulate the await on
  /// `StateMan.subscribe` itself -- e.g. a key that never resolves.
  ///
  /// Pass [liveKeys] to simulate a key list that changes after construction —
  /// the situation an accepted key-mapping proposal creates in production.
  StateManStateReader.forTest({
    required List<String> keys,
    Map<String, Stream<DynamicValue>> streams = const {},
    Future<Stream<DynamicValue>> Function(String key)? subscribe,
    List<String> Function()? liveKeys,
    this.subscribeTimeout = defaultSubscribeTimeout,
  })  : _stateMan = null,
        _keySource = (liveKeys ?? (() => keys)),
        _testStreams = streams,
        _testSubscribe = subscribe;

  /// Subscribes to each key and populates the value cache.
  ///
  /// Each subscription converts [DynamicValue] to a plain Dart value
  /// (int, double, bool, String, or null) via the `.value` property
  /// and stores it in the cache for synchronous access.
  ///
  /// Keys that fail to subscribe (e.g., OPC UA disconnected) or that do not
  /// resolve within [subscribeTimeout] are skipped -- they will return null
  /// from [getValue], but they no longer hold up the remaining keys.
  Future<void> init() async {
    final keys = _keySource();
    for (var i = 0; i < keys.length; i += subscribeConcurrency) {
      final batch = keys.skip(i).take(subscribeConcurrency);
      await Future.wait(batch.map(_subscribeKey));
    }
  }

  /// Subscribes a single key and wires its stream into [_cache].
  ///
  /// Never throws: subscription failures are logged and the key is left
  /// uncached.
  Future<void> _subscribeKey(String key) async {
    if (_subscriptions.containsKey(key) || !_subscribing.add(key)) return;
    try {
      Stream<DynamicValue> stream;
      if (_stateMan == null) {
        // Test mode: await the injected subscriber, else use provided streams
        if (_testSubscribe != null) {
          stream = await _testSubscribe(key).timeout(subscribeTimeout);
        } else if (_testStreams.containsKey(key)) {
          stream = _testStreams[key]!;
        } else {
          return;
        }
      } else {
        stream = await _stateMan.subscribe(key).timeout(subscribeTimeout);
      }

      final sub = stream.listen(
        (dynamicValue) => _cache[key] = _extractValue(dynamicValue),
        onError: (error) {
          io.stderr.writeln(
              'StateManStateReader: subscription error for key "$key": $error');
        },
      );
      _subscriptions[key] = sub;
    } catch (e) {
      io.stderr.writeln(
          'StateManStateReader: failed to subscribe to key "$key": $e');
    } finally {
      // On failure the key leaves the pending set, so a later query retries
      // rather than being locked out by one bad attempt. Queries are
      // human-paced; StateMan's own backoff bounds anything faster.
      _subscribing.remove(key);
    }
  }

  /// Extract a plain Dart value from a [DynamicValue].
  ///
  /// Returns int, double, bool, String, or null for scalar types. Anything
  /// else -- a struct, an array, a DateTime, a NodeId -- is parked in a
  /// [_DeferredRender] and turned into a String only if somebody reads it.
  ///
  /// The rendering used to happen right here, in the subscription callback.
  /// For a struct that means `LinkedHashMap<String, DynamicValue>.toString()`:
  /// `MapBase.mapToString` walking every member, each member's own
  /// `DynamicValue.toString` (itself three interpolations), and the
  /// `StringBuffer` behind them -- a fresh string per member per update. This
  /// reader subscribes to *every* key in the mapping (>1500 in a full plant
  /// config), so that ran at the plant's whole tag-update rate, while the
  /// only consumers of the cache are the MCP tag tools, which read at human
  /// pace. Practically all of it was built and thrown away.
  ///
  /// Parking the [DynamicValue] costs one small object and no extra
  /// retention: the value is already held upstream as the replay buffer of
  /// its `AutoDisposingStream`, so the cache holds a pointer to an object
  /// that was going to live anyway.
  static dynamic _extractValue(DynamicValue dv) {
    final v = dv.value;
    if (v == null) return null;
    if (v is int || v is double || v is bool || v is String) return v;
    return _DeferredRender(dv);
  }

  /// Turns a cache entry into what a reader expects: scalars unchanged,
  /// deferred structured values rendered -- once -- to the String the eager
  /// version produced.
  static dynamic _render(dynamic cached) =>
      cached is _DeferredRender ? cached.rendered : cached;

  @override
  List<String> get keys => _keySource();

  @override
  dynamic getValue(String key) {
    // A key that gained a mapping after [init] has no subscription yet.
    // Start one on first touch; this read still answers from the cache —
    // null, honestly, until the first value lands — and the next one sees
    // the live value. Sync interface, so awaiting here is not an option.
    if (!_subscriptions.containsKey(key) &&
        !_subscribing.contains(key) &&
        _keySource().contains(key)) {
      unawaited(_subscribeKey(key));
    }
    return _render(_cache[key]);
  }

  @override
  Map<String, dynamic> get currentValues => Map.unmodifiable(
      {for (final e in _cache.entries) e.key: _render(e.value)});

  @override
  List<String> get serverAliases {
    if (_stateMan == null) return const [];
    return _stateMan.config.opcua
        .map((c) => c.serverAlias)
        .whereType<String>()
        .toList();
  }

  /// Cancel all stream subscriptions and clear the cache.
  void dispose() {
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
    _subscribing.clear();
    _cache.clear();
  }
}

/// A structured [DynamicValue] sitting in [StateManStateReader]'s cache,
/// rendered to a String only when somebody asks for it -- and then only once.
///
/// Rendering is what the reader used to do on every update of every
/// structured key; see [StateManStateReader._extractValue].
class _DeferredRender {
  _DeferredRender(this._value);

  final DynamicValue _value;
  Object? _rendered;
  bool _hasRendered = false;

  /// The exact String the eager version put in the cache.
  Object? get rendered {
    if (_hasRendered) return _rendered;
    _hasRendered = true;
    try {
      _rendered = _value.value.toString();
    } catch (_) {
      // The old code caught a throwing `_extractValue` and cached
      // `dynamicValue.toString()` instead. Keep that fallback, and swallow a
      // throw from it too: this now runs inside a read, and an MCP tag query
      // returning null beats one throwing out of a synchronous getter.
      try {
        _rendered = _value.toString();
      } catch (_) {
        _rendered = null;
      }
    }
    return _rendered;
  }
}
