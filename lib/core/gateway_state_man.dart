/// `StateMan`, but every value comes down one WebSocket.
///
/// **Why an adapter exists at all.** The milestone's premise is that
/// `StateManApi` is one interface implemented by both sides and widgets do not
/// change. Half of that is true: `RemoteStateMan` and `LocalStateMan` both
/// implement `StateManApi` (`packages/tfc_relay_protocol`). The other half is
/// not, and it is worth writing down rather than discovering twice —
/// **`tfc_dart`'s `StateMan`, which is the type this app's widgets actually
/// hold, does not implement `StateManApi` and never has.** They are two
/// interfaces:
///
///  * They disagree on the three methods they share. `StateMan.read` is
///    `Future<DynamicValue>`; `StateManApi.read` is a synchronous
///    `DynamicValue?` (cache peek) with the round trip on `readFresh`.
///    `StateMan.subscribe` returns `Future<Stream<…>>`; the API's returns a
///    `Stream<…>` synchronously. `StateMan.write` takes a `DynamicValue` and
///    returns `Future<void>`; the API's takes an `Object?` with `expect`/`cmd`
///    and returns a three-state `WriteResult`.
///  * They disagree on the value type. `StateMan` speaks
///    `package:open62541`'s `DynamicValue`; the protocol package defines its
///    own, deliberately, so that the gateway and a future web client never
///    pull in open62541's native assets. Every value crossing this class is
///    translated, the mirror of `tfc_relay_local`'s `translateOpcUaSample`.
///  * `StateMan` has fourteen members the API does not: `config`,
///    `keyMappings`, `updateKeyMappings`, `clients`, `deviceClients`,
///    `resolveKey`, `setSubstitution`, `getSubstitution`, `substitutions`,
///    `substitutionsChanged`, `isKeyDisabled`, `connMetaAliases`,
///    `subscribeConnMeta`, `close`. App code calls all of them.
///
/// So this class is what "widgets do not change" costs on this codebase: it
/// `implements StateMan` — the same trick `GuardedStateMan` already uses, and
/// the reason `stateManProvider`'s type does not move — and satisfies each of
/// those fourteen either locally or by documented refusal.
///
/// **What it cannot do, stated once here rather than discovered on a panel.**
///
///  * **Subscriptions are fixed at construction.** `RemoteStateMan` takes its
///    key set as a constructor argument and the supervisor re-establishes
///    exactly that set on every reconnect; the class exposes no way to add a
///    key later, and its `subscribe(key)` only hands back a view of a store
///    node that the fixed subscription feeds. This adapter therefore subscribes
///    to **every key in `key_mappings`** up front. On a station whose mapping
///    is the whole plant that is a large subscription, and it is the honest
///    reading of the API as it stands — the alternative is a page whose values
///    never arrive, silently.
///
///    `ALARM.active` is added to that set here, in [subscriptionKeys], for
///    exactly the same reason: it is never in `key_mappings` — the key-mapping
///    ingest *reserves* the `ALARM.` prefix rather than allowing it — and a key
///    added after construction is a key never served. Dropped, the runtime
///    symptom is an alarm banner that simply never updates, with no error
///    anywhere.
///  * **`clients` and `deviceClients` are empty.** They hand out live OPC UA
///    and Modbus client objects, and in gateway mode this process holds
///    neither. The eleven call sites are all browse/diagnostic UI —
///    `opcua_browse`, `umas_browse`, `opcua_array_index_field`, the Schneider
///    asset's raw node read, the server-config live-status chip and the MCP
///    node browser — so those degrade to "nothing to show" rather than
///    misreport. `RemoteStateMan` does expose a `browse` sub-API over the wire;
///    wiring the browse widgets to it is a follow-up, not this class's job.
///  * **Substitution is local, and that is correct.** `StateManApi`'s own doc
///    keeps `$variable` resolution off the wire. This class reimplements
///    `StateMan`'s resolver against its own map, so `OptionVariable` and the
///    timeseries mixin behave the same on both transports.
library;

import 'dart:async';
import 'dart:collection';

import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' as ua;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// A `StateMan` whose values arrive over the relay pipe.
class GatewayStateMan implements StateMan {
  GatewayStateMan({
    required RemoteStateMan remote,
    required this.config,
    required KeyMappings keyMappings,
    this.alias = '',
  })  : _remote = remote,
        _keyMappings = keyMappings;

  /// Points a client at [uri] and wraps it.
  ///
  /// [config] and [keyMappings] are this station's own copies, still read from
  /// preferences in gateway mode: the gateway owns which upstreams are live,
  /// but the panel still needs the mapping to draw a key picker, a history
  /// tree and the `collect` flags on a sensor.
  /// [buildRemote] is a test seam, and production never supplies it.
  ///
  /// It exists so a test can assert **what the client was pointed at** —
  /// the address, the pinned root and the credential — without a live dial at
  /// the configured URL. Reading those off a *constructed* `RemoteStateMan` is
  /// possible (`uri` and `config` are public) and is the wrong way round:
  /// its constructor starts dialling immediately
  /// (`remote_state_man.dart:213`), so the observation would leave a dial loop
  /// running at the plant's real gateway address inside a unit test, and an
  /// undisposed dial loop is what makes unrelated widget tests flaky. This
  /// seam records the arguments before anything is allocated.
  ///
  /// The property has no other honest observation point.
  /// `state_man_transport_test.dart`'s original three arms prove only which
  /// class was built, and `stateManProvider` hands back a `GuardedStateMan`
  /// that cannot be unwrapped — so Phase 15 criterion 1, "the configured
  /// transport is the one the client actually dials", would otherwise rest on
  /// the one manual rig run that measured it (13-RIG-E2E-EVIDENCE) and on
  /// nothing thereafter.
  static Future<GatewayStateMan> create({
    required Uri uri,
    required ClientConfig clientConfig,
    required StateManConfig config,
    required KeyMappings keyMappings,
    String alias = '',
    RemoteStateMan Function({
      required Uri uri,
      required ClientConfig config,
      required Set<String> keys,
    })? buildRemote,
  }) async {
    // The default is inlined into the call rather than hoisted into a local or
    // written as a ternary, and both of the tidier spellings are wrong here
    // for a measured reason.
    //
    //  * **One argument list, so the seam cannot be a blind spot.** A ternary
    //    would spell the key set twice, once on each arm, and a test that goes
    //    through `buildRemote` would then never observe the default arm's
    //    copy — shortening only that one would leave every arm green and every
    //    panel grey. Written this way there is one `keys:` expression and both
    //    paths take it.
    //  * **`alarm_gateway_mode_test.dart:914` reads this file's source**,
    //    takes the statement holding the first literal `RemoteStateMan(` and
    //    requires `subscriptionKeys(keyMappings)` inside it, because its
    //    behavioural arm about `ALARM.active` is worth nothing if the
    //    production path stops going through that function. Hoisting the
    //    default into `final build = …;` moves the construction into a
    //    statement that carries no key set, and the guard then passes on a
    //    file it can no longer see.
    final remote = (buildRemote ??
        ({
          required Uri uri,
          required ClientConfig config,
          required Set<String> keys,
        }) =>
            RemoteStateMan(uri: uri, config: config, keys: keys))(
      uri: uri,
      config: clientConfig,
      keys: subscriptionKeys(keyMappings),
    );
    return GatewayStateMan(
      remote: remote,
      config: config,
      keyMappings: keyMappings,
      alias: alias,
    );
  }

  /// Everything this station's client subscribes: every mapped key, plus the
  /// alarm engine's active set.
  ///
  /// A named function rather than an expression inside [create] because
  /// `RemoteStateMan` takes its key set as a constructor argument and exposes
  /// no getter for it — so the only way to assert that `ALARM.active` is in
  /// there is to be able to call the thing that computes it. See the library
  /// doc for why a key added later is a key never served.
  static Set<String> subscriptionKeys(KeyMappings keyMappings) =>
      <String>{...keyMappings.keys, rp.AlarmKeys.active};

  final RemoteStateMan _remote;

  /// The live client, for a health line that wants `LinkState` or the clock
  /// offset. Not part of `StateMan`.
  ///
  /// **A bare type test on `stateManProvider`'s value does not reach this, and
  /// is false on every real panel.** That provider returns a
  /// `GuardedStateMan`, whose inner object is private with no getter, so
  /// `value is GatewayStateMan` is true only in a hand-built test — a guard
  /// that passes and observes nothing. Reach it through
  /// `GuardedStateMan.innerAs<GatewayStateMan>()` (the read-only unwrap plan
  /// 15-04 adds), or through the slot the construction site publishes
  /// (`GatewayAlarmSlot` in `lib/providers/state_man.dart`, which exists for
  /// exactly this reason).
  RemoteStateMan get remote => _remote;

  @override
  final Logger logger = Logger();

  /// This station's copy of the direct-mode config.
  ///
  /// Kept so `lib/providers/plc.dart` and the MCP server listing still have
  /// something to enumerate. It describes what this station *would* dial in
  /// direct mode, which on a correctly provisioned panel is the same set of
  /// PLCs the gateway is in front of.
  @override
  final StateManConfig config;

  KeyMappings _keyMappings;

  @override
  KeyMappings get keyMappings => _keyMappings;

  @override
  set keyMappings(KeyMappings value) => _keyMappings = value;

  @override
  String alias;

  /// Empty: this process holds no OPC UA session. See the library doc.
  @override
  List<ClientWrapper> get clients => const [];

  /// Empty: this process holds no Modbus or M2400 socket. See the library doc.
  @override
  List<DeviceClient> get deviceClients => const [];

  // ------------------------------------------------------------ substitution

  final Map<String, String> _substitutions = {};
  final StreamController<Map<String, String>> _subsChanged =
      StreamController<Map<String, String>>.broadcast();

  @override
  void setSubstitution(String key, String value) {
    if (_substitutions[key] == value) return;
    _substitutions[key] = value;
    _subsChanged.add(Map.unmodifiable(_substitutions));
  }

  @override
  String? getSubstitution(String key) => _substitutions[key];

  @override
  Map<String, String> get substitutions => Map.unmodifiable(_substitutions);

  @override
  Stream<Map<String, String>> get substitutionsChanged => _subsChanged.stream;

  /// The same resolver `StateMan` runs, against this object's own map.
  ///
  /// Deliberately a copy rather than a call into the local implementation:
  /// `StateMan`'s version is an instance method on a class this mode never
  /// constructs, and the behaviour — replace every `$name`, return the key
  /// unchanged when nothing matches — is four lines.
  @override
  String resolveKey(String key) {
    if (!key.contains(r'$')) return key;
    var resolved = key;
    for (final entry in _substitutions.entries) {
      resolved = resolved.replaceAll('\$${entry.key}', entry.value);
    }
    return resolved;
  }

  // ----------------------------------------------------------------- values

  /// A forced round trip, because that is what `StateMan.read` promises.
  ///
  /// The interface's synchronous cache peek is `StateManApi.read`; this method
  /// name means something else on this side and quietly returning a stale
  /// cached value under it would be the wrong kind of compatible.
  @override
  Future<ua.DynamicValue> read(String key) async =>
      toUaValue(await _remote.readFresh(resolveKey(key)));

  @override
  Future<Map<String, ua.DynamicValue>> readMany(List<String> keys) async {
    final resolved = {for (final key in keys) resolveKey(key): key};
    final answer = await _remote.readMany(resolved.keys.toList());
    return {
      for (final entry in answer.entries)
        resolved[entry.key] ?? entry.key: toUaValue(entry.value),
    };
  }

  @override
  Future<Stream<ua.DynamicValue>> subscribe(String key) async =>
      _remote.subscribe(resolveKey(key)).map(toUaValue);

  /// A write, collapsed onto `Future<void>` — and never silently.
  ///
  /// The pipe's whole point is that a write is applied, rejected or explicitly
  /// unknown. `StateMan.write` has one success and one failure channel, so the
  /// two non-applied outcomes both become a throw, with the outcome named in
  /// the message. `WriteUnknown` in particular must not read as success: the
  /// operator has to know the readback is the only confirmation.
  @override
  Future<void> write(String key, ua.DynamicValue value) async {
    final result = await _remote.write(resolveKey(key), plainValueOf(value));
    switch (result) {
      case rp.WriteApplied():
        return;
      case rp.WriteRejected(reason: final reason):
        throw StateManException('Write to "$key" was rejected by the gateway: '
            '${reason.message ?? reason.kind}');
      case rp.WriteUnknown(reason: final reason):
        throw StateManException('Write to "$key" may or may not have been '
            'applied (${reason.message ?? reason.kind}). It has NOT been '
            'retried; read the value back before acting on it.');
      case rp.WriteNotReceived():
        throw StateManException('Write to "$key" never reached the gateway. '
            'Nothing was applied.');
    }
  }

  /// The keys this station knows about — from the mapping, not from what has
  /// arrived.
  ///
  /// `RemoteStateMan.keys` deliberately answers "keys a value has arrived for",
  /// which is the right answer for its own picker and the wrong one here: a
  /// page editor listing keys must offer a tag that is configured but has not
  /// ticked yet, exactly as direct mode does.
  @override
  List<String> get keys => _keyMappings.keys.toList();

  // ------------------------------------------------------------- refusals

  /// False. Which upstreams are live is the gateway's business, and a panel
  /// that greyed keys out on a stale local `enabled` flag would be lying.
  @override
  bool isKeyDisabled(String key) => false;

  /// Empty: `@conn` meta-keys describe connections this process does not hold.
  @override
  List<({String alias, bool isModbus})> get connMetaAliases => const [];

  @override
  Stream<Map<String, ua.DynamicValue>> subscribeConnMeta(String alias) =>
      throw StateManException(
          'Connection metadata for "$alias" is not available in gateway mode: '
          'this panel holds no upstream connections of its own.');

  /// Always a full reload.
  ///
  /// The live re-point direct mode performs is a re-point of an OPC UA monitored
  /// item this process does not own. The key set is also fixed for the life of
  /// the client, so a mapping edit genuinely needs a new one.
  @override
  KeyMappingsUpdateResult updateKeyMappings(KeyMappings newKeyMappings) {
    _keyMappings = newKeyMappings;
    return KeyMappingsUpdateResult(
      added: const {},
      removed: const {},
      changed: const {},
      resubscribed: const {},
      reloadReasons: const [
        'gateway mode: the relay client\'s key set is fixed at construction',
      ],
    );
  }

  @override
  Future<void> close() async {
    await _subsChanged.close();
    await _remote.dispose();
  }

  @override
  void addSubscription({
    required String key,
    required Stream<ua.DynamicValue> subscription,
    required ua.DynamicValue? firstValue,
  }) =>
      throw UnsupportedError(
          'addSubscription is a direct-mode test seam; a gateway client is '
          'fed by its own socket.');
}

/// The relay's value, as the one the rest of this app speaks.
///
/// The mirror of `tfc_relay_local`'s `translateOpcUaSample`, and structurally
/// the same recursion: structs and arrays are rebuilt member by member so the
/// result is a real `open62541` object graph rather than a `Map` hiding inside
/// one `DynamicValue`.
///
/// Quality does not survive the crossing, because on this open62541 version
/// there is nowhere on `ua.DynamicValue` to put it. A bad-quality reading
/// arrives as a null value, which is what the relay already normalises it to
/// (`translateOpcUaSample` nulls the value when the quality is bad or error),
/// and staleness is surfaced by the client's own freshness signal rather than
/// per value.
ua.DynamicValue toUaValue(rp.DynamicValue value, {String? name}) {
  final raw = value.value;
  if (raw is Map<Object, rp.DynamicValue>) {
    final out = ua.DynamicValue(name: name);
    out.value = LinkedHashMap<String, ua.DynamicValue>();
    for (final entry in raw.entries) {
      final member = '${entry.key}';
      out[member] = toUaValue(entry.value, name: member);
    }
    return out;
  }
  if (raw is List<rp.DynamicValue>) {
    final out = ua.DynamicValue(name: name);
    out.value = <ua.DynamicValue>[];
    for (var index = 0; index < raw.length; index++) {
      out[index] = toUaValue(raw[index]);
    }
    return out;
  }
  return ua.DynamicValue(value: raw, name: name);
}

/// A value the relay's sanitizing constructor will accept, out of one of ours.
///
/// Copied in shape from `tfc_relay_local`'s `_plainValueOf` — the same
/// unwrapping, in the same direction the gateway does it, so a value that
/// round-trips through the pipe comes back as itself.
Object? plainValueOf(ua.DynamicValue value) {
  final raw = value.value;
  if (raw is ua.DynamicValue) return plainValueOf(raw);
  if (raw is List) {
    return <Object?>[
      for (final element in raw)
        element is ua.DynamicValue ? plainValueOf(element) : element,
    ];
  }
  if (raw is Map) {
    return <String, Object?>{
      for (final entry in raw.entries)
        '${entry.key}': entry.value is ua.DynamicValue
            ? plainValueOf(entry.value as ua.DynamicValue)
            : entry.value,
    };
  }
  return raw;
}
