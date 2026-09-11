// A value that is stale must LOOK stale — pinned against a real socket and the
// real provider stack.
//
// **The defect this file exists for was photographed, not imagined.** The
// attended rig run of 2026-09-07 (`15-RIG-ATTENDED-20260907.md`, "Things that
// looked wrong on screen even though a test would pass", item 1) cut a
// connected panel's link and watched it:
//
//   | t              | chip                | values on the home page |
//   |----------------|---------------------|-------------------------|
//   | before the cut | green `Gateway live`| definite                |
//   | +25 s          | yellow `No gateway` | **still definite**      |
//   | +65 s          | yellow `No gateway` | **still definite**      |
//
// The chip was the only thing on the screen that knew. `CLAUDE.md`'s Core Value
// — *"values are fresh or visibly stale"* — did not hold on a real panel.
//
// 16-10-SUMMARY had already named the cause: `viewIsStale` and `viewFreshness`
// **had no reader in any `lib/`**. So the pin here is not about the watchdog,
// which was hardened twice this milestone and is right; it is about the last
// hop, from a verdict the client computes to a value an operator reads.
//
// **Why a real socket.** `RemoteStateMan`'s `dial:` seam and everything behind
// it live in `tfc_relay_client`'s `src/` and are not exported
// (`gateway_link_test.dart:6-13` argues this at length). The app cannot fake a
// connection; it can only make one. The far end is
// `test/helpers/scripted_gateway.dart`, and the near end is the real
// `stateManProvider` building a real `GuardedStateMan` around a real
// `GatewayStateMan` around a real `RemoteStateMan`. An arm that hand-built a
// `GatewayStateMan` would prove nothing: `value is GatewayStateMan` is false on
// every panel in the plant (15-RESEARCH F-1).
//
// **Every arm is a plain `test()`, never a widget test.** The widget binding's
// fake-async zone will not pump a real socket's completions, so an arm written
// that way waits for a frame that has already arrived. What a screen does with
// the verdict is pinned separately, in
// `test/widgets/stale_values_render_test.dart`.

@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart' show BehaviorSubject;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc/core/value_freshness.dart';
import 'package:tfc/providers/access.dart' show stationNameProvider;
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway.dart' show gatewayConfigProvider;
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/providers/value_freshness.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
// `DynamicValue` is spelled in both packages — the protocol's is the wire type
// and open62541's is what this app's widgets hold — and `PreferencesApi` is
// spelled in both `tfc_relay_protocol` and `tfc_dart`. This file wants
// open62541's value and `tfc_dart`'s store, so the protocol barrel is imported
// for its method names and constants only.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show Methods, defaultPageSubscription;

import '../helpers/scripted_gateway.dart';
import '../helpers/test_helpers.dart';

/// The client's knobs, every production wait lowered deliberately and
/// greppably — `gateway_link_test.dart:82-96`'s shape, for its reasons.
///
/// **`freshnessDeadline` is the number this file is about.** Production is 3 s
/// and the rig's cut was still invisible at 65 s, so the arms below do not need
/// the production value to observe the property — they need a link that has
/// provably gone a whole deadline without a frame, which 400 ms buys in a
/// hundredth of the wall clock. `allowTokenOverPlaintext` is irrelevant here
/// (no token) and left off.
ClientConfig _fastConfig() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 300),
      writeDeadline: const Duration(milliseconds: 300),
      freshnessDeadline: const Duration(milliseconds: 400),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(milliseconds: 120),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// The budget for "the panel got where it was going".
const Duration _recovery = Duration(seconds: 6);

/// This station's mapping.
///
/// It names [kScriptedSeededKey] because `GatewayStateMan` fixes the client's
/// subscription set from the mapping at construction, so a key absent here is a
/// key the scripted gateway is never asked for and a value that never lands.
final KeyMappings _mappings = KeyMappings(nodes: {
  kScriptedSeededKey: KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Connected')),
});

/// The full provider stack a panel runs, with nothing about the transport
/// faked except the client's waits.
///
/// **`gatewayStateManFactoryProvider` is overridden only to substitute
/// [_fastConfig], and it still calls the production `GatewayStateMan.create`.**
/// The object under observation is therefore the real guard around the real
/// adapter around a real client on a real socket; what moved is four durations.
/// Leaving it alone would mean an arm spending the production 3 s deadline and
/// a 30 s backoff cap to observe the recovery direction.
ProviderContainer _harness(PreferencesApi local,
    {List<Override> extra = const <Override>[]}) {
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _mappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      systemPreferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _mappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      localPreferencesProvider.overrideWithValue(local),
      databaseProvider.overrideWith((ref) async => null),
      stationNameProvider.overrideWithValue('staleness-panel'),
      collectorProvider.overrideWith((ref) async => null),
      stateManFactoryProvider.overrideWithValue(({
        required StateManConfig config,
        required KeyMappings keyMappings,
        List<DeviceClient> deviceClients = const [],
      }) async =>
          throw StateError('local StateMan construction reached')),
      gatewayStateManFactoryProvider.overrideWithValue(({
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
      }) =>
          GatewayStateMan.create(
            uri: uri,
            clientConfig: _fastConfig(),
            config: config,
            keyMappings: keyMappings,
            alias: alias,
            buildRemote: buildRemote,
          )),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A device-local store seeded with [row], and the stack reading it.
Future<ProviderContainer> _panel(GatewayConfig row,
    {List<Override> extra = const <Override>[]}) async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(local, row);
  return _harness(local, extra: extra);
}

/// Everything one key stream presented, values and reasons alike, in order.
///
/// **Recorded rather than awaited, because the claim is about what the panel
/// was last showing.** `expectLater(…, emitsError(…))` on a stream that never
/// errors fails as a timeout, and a timeout names nothing — least of all "the
/// panel went on presenting a pre-outage value as current", which is the whole
/// finding. A recorder can be asked what the last thing on the screen was.
final class _Presented {
  _Presented(this.container, this.key) {
    _held = container.listen(keyStreamProvider(key), (_, __) {},
        fireImmediately: true);
    _attach();
  }

  final ProviderContainer container;
  final String key;
  late final ProviderSubscription<Stream<DynamicValue>> _held;
  StreamSubscription<DynamicValue>? _values;
  Stream<DynamicValue>? _watched;

  /// Values and errors, interleaved in arrival order.
  final List<Object> events = <Object>[];

  /// Re-points at the provider's current stream.
  ///
  /// `keyStreamProvider` hands out a new subject whenever it rebuilds — a
  /// `stateManProvider` rebuild, a substitution change — and a recorder pinned
  /// to the first one would go quiet without saying so.
  void _attach() {
    final stream = container.read(keyStreamProvider(key));
    if (identical(stream, _watched)) return;
    _watched = stream;
    _values?.cancel();
    _values = stream.listen(events.add, onError: events.add);
  }

  /// What the panel is presenting right now: a value, a reason, or nothing yet.
  Object? get latest => events.isEmpty ? null : events.last;

  /// Whether the panel is presenting a definite value.
  bool get isDefinite => latest is DynamicValue;

  /// Waits until [predicate] holds of [latest], or gives up.
  Future<void> until(bool Function(Object? latest) predicate,
      {Duration budget = _recovery, String? reason}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      _attach();
      if (predicate(latest)) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('${reason ?? 'the key stream never reached the expected state'} '
        '(last presented: $latest, ${events.length} event(s) in total)');
  }

  Future<void> dispose() async {
    await _values?.cancel();
    _held.close();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  group('a gateway panel whose link goes down', () {
    test('stops presenting the value it can no longer vouch for', () async {
      // The rig's sequence, on a socket. `answering` is the plant switch: with
      // it false the gateway accepts a socket and then says nothing at all,
      // which is what a half-open link through a sleeping NAT looks like and
      // what the rig produced with an iptables DROP.
      var answering = true;
      final gateway = await ScriptedGateway.start((link, method, id) {
        if (!answering) return;
        if (method == Methods.hello) link.hello(id);
        if (method == Methods.subscribe) {
          link.snapshot(id, defaultPageSubscription, value: true);
        }
      });
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final presented = _Presented(container, kScriptedSeededKey);
      addTearDown(presented.dispose);

      await presented.until((latest) => latest is DynamicValue,
          reason: 'the panel never showed a definite value to begin with, so '
              'nothing below is about a value going stale');
      expect((presented.latest! as DynamicValue).asBool, isTrue);

      // The claim this arm exists to make: the object the values came through
      // is the one a panel really has.
      final stateMan = await container.read(stateManProvider.future);
      expect(stateMan, isA<GuardedStateMan>());
      expect((stateMan as GuardedStateMan).innerAs<GatewayStateMan>(),
          isNotNull);

      // The cut.
      answering = false;
      await gateway.dropLive();

      await presented.until((latest) => latest is StaleValues,
          reason: 'THE RIG DEFECT: the link is down and the panel is still '
              'presenting the value it received before the cut as though it '
              'were current');
      expect(presented.isDefinite, isFalse);
    });

    test('presents a definite value again once the link comes back', () async {
      // The other direction, and it is not decoration: a panel that greys out
      // and stays grey through a recovered link is a panel nobody trusts the
      // grey of. `viewBecameFresh` is called from `_enter(LinkState.ready)`,
      // which by construction is after every page's snapshot has been adopted
      // (16-10 / S9) — so what comes back is the new connection's value, not
      // the one held over the outage.
      var answering = true;
      final gateway = await ScriptedGateway.start((link, method, id) {
        if (!answering) return;
        if (method == Methods.hello) link.hello(id);
        if (method == Methods.subscribe) {
          link.snapshot(id, defaultPageSubscription, value: true);
        }
      });
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final presented = _Presented(container, kScriptedSeededKey);
      addTearDown(presented.dispose);
      await presented.until((latest) => latest is DynamicValue);

      answering = false;
      await gateway.dropLive();
      await presented.until((latest) => latest is StaleValues,
          reason: 'the panel never went stale, so the recovery this arm is '
              'named for is a recovery from nothing');

      answering = true;

      await presented.until((latest) => latest is DynamicValue,
          reason: 'the link came back and the panel is still refusing to show '
              'its values');
      expect((presented.latest! as DynamicValue).asBool, isTrue);
    });

    test('the verdict the panel gates on is the client\'s own', () async {
      // Anti-vacuity for the two arms above: they would both pass against a
      // provider that greyed values on some other signal entirely — a socket
      // close, a link state, a guess. This one names the getter.
      var answering = true;
      final gateway = await ScriptedGateway.start((link, method, id) {
        if (!answering) return;
        if (method == Methods.hello) link.hello(id);
        if (method == Methods.subscribe) {
          link.snapshot(id, defaultPageSubscription, value: true);
        }
      });
      final container = await _panel(GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));

      final presented = _Presented(container, kScriptedSeededKey);
      addTearDown(presented.dispose);
      await presented.until((latest) => latest is DynamicValue);

      final stateMan = await container.read(stateManProvider.future);
      final remote =
          (stateMan as GuardedStateMan).innerAs<GatewayStateMan>()!.remote;
      final freshness = container.read(valueFreshnessProvider);
      expect(freshness.isWatchingLink, isTrue,
          reason: 'a gateway panel must be tracking a client, or every '
              'negative arm in this file is vacuous');
      expect(remote.viewIsStale, isFalse);
      expect(freshness.isStale, isFalse);

      answering = false;
      await gateway.dropLive();
      await presented.until((latest) => latest is StaleValues);

      expect(remote.viewIsStale, isTrue,
          reason: 'the client\'s own verdict, not a second model in lib/');
      expect(freshness.isStale, isTrue);
    });
  });

  group('the two windows a socket arm cannot reach', () {
    // Both of these are about values MOVING while the badge is set, which a
    // dead loopback socket cannot produce: nothing arrives from a gateway that
    // has stopped answering. Driven through the same provider with the verdict
    // supplied directly, which is what `ValueFreshness` being a plain bool and
    // a plain stream is for.

    test('a page opened during an outage says so before any value arrives',
        () async {
      // An operator navigating to another page mid-outage builds a brand-new
      // key stream whose subject is empty — and an empty subject renders as
      // "waiting for a first reading", the same thing a healthy panel shows for
      // one frame at boot. On a link that has gone quiet that is the wrong
      // sentence: nothing is coming.
      final container = ProviderContainer(overrides: [
        stateManProvider.overrideWith((ref) async => _NeverStateMan()),
        valueFreshnessProvider.overrideWithValue(_staleGate()),
      ]);
      addTearDown(container.dispose);

      final presented = _Presented(container, 'CN01.Temp');
      addTearDown(presented.dispose);

      await presented.until((latest) => latest is StaleValues,
          budget: const Duration(seconds: 2),
          reason: 'a key stream built while the panel was already stale waited '
              'for a transition that had already happened');
    });

    test('a value that arrives while the badge is set is not shown as current',
        () async {
      // 16-10 / S9's window, from the widget side. `viewBecameFresh` is called
      // only once every page's snapshot has been adopted, so values DO keep
      // landing while the verdict still reads stale — the store answers, and a
      // resync pushes snapshots for seconds beforehand. Publishing those would
      // put a mid-resync reading on the glass under a badge that says the panel
      // cannot vouch for it.
      final stateMan = _SilentStateMan();
      final container = ProviderContainer(overrides: [
        stateManProvider.overrideWith((ref) async => stateMan),
        valueFreshnessProvider.overrideWithValue(_staleGate()),
      ]);
      addTearDown(container.dispose);

      final presented = _Presented(container, 'CN01.Temp');
      addTearDown(presented.dispose);
      await presented.until((latest) => latest is StaleValues,
          budget: const Duration(seconds: 2));

      stateMan.controller.add(DynamicValue(value: 7.5));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(presented.isDefinite, isFalse,
          reason: 'a reading that arrived while the panel could not vouch for '
              'its view was published as though it could');
      expect(presented.latest, isA<StaleValues>());
    });
  });

  group('a direct station', () {
    test('never grows a staleness verdict, and never builds a StateMan to be '
        'told so', () async {
      var built = false;
      final container = await _panel(
        const GatewayConfig(mode: TransportMode.direct),
        extra: [
          stateManProvider.overrideWith((ref) {
            built = true;
            throw StateError('stateManProvider was built in direct mode');
          }),
        ],
      );
      // The config row is read asynchronously; the provider is watched so the
      // rebuild that carries the answer actually happens.
      final held = container.listen(valueFreshnessProvider, (_, __) {},
          fireImmediately: true);
      addTearDown(held.close);
      await container.read(gatewayConfigProvider.future);

      final freshness = container.read(valueFreshnessProvider);

      expect(freshness.isStale, isFalse);
      expect(freshness.isWatchingLink, isFalse,
          reason: 'there is no link to watch on a direct station');
      expect(built, isFalse,
          reason: 'the absence is decided on the config row before anything '
              'heavier is touched — reading stateManProvider here would open '
              'every OPC UA session on the panel to be told there is no '
              'gateway');
    });

    test('keeps presenting values while its own StateMan says nothing at all',
        () async {
      // The negative arm with teeth. A direct station's values must survive a
      // silence that would grey a gateway station: the same absence of frames,
      // and the opposite answer, because there is no link whose deadline could
      // expire.
      final silent = _SilentStateMan();
      final container = await _panel(
        const GatewayConfig(mode: TransportMode.direct),
        extra: [stateManProvider.overrideWith((ref) async => silent)],
      );

      final presented = _Presented(container, 'CN01.Temp');
      addTearDown(presented.dispose);
      await presented.until((latest) => latest is DynamicValue);

      silent.controller.add(DynamicValue(value: 3.5));
      // Longer than a gateway station's whole freshness deadline.
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(presented.isDefinite, isTrue,
          reason: 'a direct station has no gateway and no link-level '
              'staleness; greying it out is the regression this arm exists '
              'to catch');
      expect((presented.latest! as DynamicValue).asDouble, closeTo(3.5, 1e-9));
      expect(
          presented.events.whereType<StaleValues>(), isEmpty,
          reason: 'not one withheld value on a station with no link');
    });
  });
}

/// A panel that has gone a whole freshness deadline without a frame.
///
/// Registered for teardown at construction: the object holds a subscription to
/// the transitions stream, and an arm that failed before disposing it would
/// leave one behind.
ValueFreshness _staleGate() {
  final transitions = StreamController<bool>.broadcast();
  final gate =
      ValueFreshness.watching(stale: true, transitions: transitions.stream);
  addTearDown(() async {
    await gate.dispose();
    await transitions.close();
  });
  return gate;
}

/// A StateMan whose subscription never yields anything at all.
class _NeverStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      StreamController<DynamicValue>.broadcast().stream;
}

/// A direct-mode StateMan that yields one value and then goes quiet for ever.
///
/// A [BehaviorSubject] rather than a bare broadcast controller: the provider
/// awaits `subscribe` before it listens, so a value pushed in between is
/// dropped by a plain broadcast stream and the arm then measures its own
/// harness racing itself.
class _SilentStateMan extends Fake implements StateMan {
  final BehaviorSubject<DynamicValue> controller =
      BehaviorSubject<DynamicValue>.seeded(DynamicValue(value: 1.0));

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => controller.stream;
}
