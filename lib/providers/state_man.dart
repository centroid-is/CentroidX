import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show ClientConfig, RemoteStateMan;
import '../core/gateway_state_man.dart';
import '../core/relay_alarm_source.dart';
import 'access.dart';
import 'gateway.dart';
import 'access_policy.dart';
import 'preferences.dart';
import 'collector.dart';

part 'state_man.g.dart';

/// Reads `key_mappings`, seeding a default when the station has none.
///
/// [systemWrites] is where the **seed** goes, and only the seed. It is
/// optional and falls back to [prefs] so every existing caller and every
/// existing test keeps working untouched; `stateManProvider` passes
/// `systemPreferencesProvider` so that a station booting with an empty store
/// and nobody signed in is not denied its own default (`key_mappings` is a
/// `configure` key). An operator editing key mappings still goes through the
/// guarded object, because that write is not this one.
Future<KeyMappings> fetchKeyMappings(PreferencesApi prefs,
    {Preferences? systemWrites}) async {
  var keyMappingsJson = await prefs.getString('key_mappings');
  if (keyMappingsJson == null) {
    final defaultKeyMappings = KeyMappings(nodes: {
      "exampleKey": KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 42, identifier: "identifier"))
    });
    keyMappingsJson = jsonEncode(defaultKeyMappings.toJson());
    await (systemWrites ?? prefs).setString('key_mappings', keyMappingsJson);
  }
  return KeyMappings.fromJson(jsonDecode(keyMappingsJson));
}

/// Where [stateManProvider] publishes the relay client's alarm port, and the
/// only way anything else can reach it.
///
/// **Why a slot rather than a type test.** `GatewayStateMan` documents
/// "read it by type-testing the provider's value" — and that is not possible
/// from outside this file, because [stateManProvider] always returns a
/// `GuardedStateMan`, which deliberately exposes no way back to the object it
/// wraps. Widening the guard is the wrong fix: it lives in
/// `packages/tfc_dart`, it has one job, and a public `inner` on it is a hole
/// in the access policy for every caller, not just this one.
///
/// So the single construction site records what it built here, and clears it
/// when that object is closed. Direct mode leaves it null, which is what
/// `alarmManProvider` reads as "this station evaluates its own alarms".
///
/// Held as a mutable field on a plain object rather than as provider state on
/// purpose: [stateManProvider] rebuilds itself on a `key_mappings` reload, and
/// a cached provider would then hand out a client that had already been
/// disposed.
class GatewayAlarmSlot {
  /// The live relay client's alarm port, or null in direct mode.
  AlarmTransport? transport;
}

/// The one [GatewayAlarmSlot] for this container.
final gatewayAlarmSlotProvider = Provider<GatewayAlarmSlot>(
  (ref) => GatewayAlarmSlot(),
);

/// How the inner, unguarded [StateMan] is built.
typedef StateManFactory = Future<StateMan> Function({
  required StateManConfig config,
  required KeyMappings keyMappings,
  List<DeviceClient> deviceClients,
});

/// The seam through which [stateManProvider] constructs its inner [StateMan].
///
/// Production reads the default and never overrides it. It exists so
/// that `guard_wiring_test.dart` can prove the properties this provider is
/// judged on — that a sign-in does not rebuild it, and that `close()` reaches
/// the inner instance exactly once — without opening an OPC UA connection in a
/// unit test. Those two properties have no other way to be observed, and both
/// of them failing looks like nothing at all until it is a plant.
final stateManFactoryProvider =
    Provider<StateManFactory>((ref) => StateMan.create);

/// How the gateway-mode [StateMan] is built.
///
/// The signature is the one [GatewayStateMan]'s static factory takes,
/// `buildRemote` included: that optional parameter is the whole point of
/// routing the gateway branch through a provider at all, because the
/// production call site never passes one and a test has no other way to
/// supply it.
typedef GatewayStateManFactory = Future<GatewayStateMan> Function({
  required Uri uri,
  required ClientConfig clientConfig,
  required StateManConfig config,
  required KeyMappings keyMappings,
  String alias,
  RemoteStateMan Function({
    required Uri uri,
    required ClientConfig config,
    required Set<String> keys,
  })? buildRemote,
});

/// The seam through which [stateManProvider] constructs its gateway client.
///
/// Symmetric with [stateManFactoryProvider], and for the same reason:
/// production reads the default and never overrides it. It exists so
/// that `state_man_transport_test.dart` can prove the property criterion 1 is
/// judged on — that the address, the pinned root and the credential handed to
/// the client are verbatim this station's own preferences row — without a
/// panel in a unit test opening a socket to the plant's real gateway. The rig
/// measured that property once by hand from both ends' `/proc/net/tcp`
/// (13-RIG-E2E-EVIDENCE); a manual run is evidence, not a guard.
final gatewayStateManFactoryProvider =
    Provider<GatewayStateManFactory>((ref) => GatewayStateMan.create);

@Riverpod(keepAlive: true)
Future<StateMan> stateMan(Ref ref) async {
  // Use ref.read instead of ref.watch to break the reactive dependency chain.
  // StateMan reads config once at init; DB reconnects should NOT cascade here
  // and destroy all OPC-UA connections/isolates.
  final prefs = await ref.read(preferencesProvider.future);
  // The app's own defaults, for the two writes below. Both fire on a station
  // that has never been configured, with nobody signed in, against keys the
  // policy classes as `configure` and `administer` — so on the guarded object
  // they would be denials at boot.
  final systemPrefs = await ref.read(systemPreferencesProvider.future);
  final config = await StateManConfig.fromPrefs(systemPrefs);

  final keyMappings = await fetchKeyMappings(prefs, systemWrites: systemPrefs);

  // Read here, not in `onDispose`. When the whole container goes down the
  // container refuses reads before it runs the dispose callbacks
  // ("Tried to read a provider from a ProviderContainer that was already
  // disposed"), and a throw in there takes the `stateMan.close()` below it
  // with it — so a teardown bug would present as a leaked OPC UA session.
  final alarmSlot = ref.read(gatewayAlarmSlotProvider);

  // Watch for changes in specific preferences.
  //
  // A key_mappings save is applied incrementally: unchanged keys keep their
  // connections and subscriptions untouched, edited OPC UA keys are
  // re-pointed live, and only edits the adapters cannot absorb in place
  // (classic-Modbus register specs, M2400 extraction) fall back to a full
  // provider rebuild — the old "whole world awakens" path.
  //
  // Applications are serialized through [pendingApply] so two rapid saves
  // cannot interleave their diffs out of order.
  var pendingApply = Future<void>.value();
  final listener = prefs.onPreferencesChanged.listen(
    (key) {
      if (key == 'key_mappings') {
        pendingApply = pendingApply.then((_) async {
          try {
            final stateMan = await ref.read(stateManProvider.future);
            final newPrefs = await ref.read(preferencesProvider.future);
            final result = stateMan.updateKeyMappings(
                await fetchKeyMappings(newPrefs, systemWrites: systemPrefs));
            if (result.requiresReload) {
              stderr.writeln('key_mappings: full reload required '
                  '(${result.reloadReasons.join('; ')})');
              ref.invalidateSelf();
            }
          } catch (error) {
            stderr.writeln('Failed to apply key_mappings change: $error');
          }
        });
      }
    },
    onError: (error) {
      stderr.writeln('Error in preferences listener: $error');
    },
  );

  // Which pipe this station runs on. Device-local, read once here, and
  // deliberately `ref.read` rather than `ref.watch` for the same reason the
  // preferences above are: this provider is `keepAlive` and holds every
  // connection on the panel, so a live re-read would tear OPC UA sessions and
  // the Postgres pool down under widgets holding subscriptions. Switching
  // transport is restart-to-apply, which matches the rest of the config-watch
  // behaviour on this codebase.
  final gateway = await ref.read(gatewayConfigProvider.future);

  try {
    final StateMan stateMan;
    if (gateway.isGateway) {
      // One WebSocket for VALUES: no device clients, no collector. The
      // gateway owns the upstream sessions and does the historising; a panel
      // that also collected would write a second copy of every sample.
      //
      // **And one Postgres connection**, which is not optional and is not
      // closed by this branch. `lib/providers/database.dart` has no transport
      // branch at all, so sign-in, preferences and the audit trail still go
      // over the station's own database link in gateway mode — measured on the
      // rig, 13-RIG-E2E-EVIDENCE FIND-C. Closing that dependency (access,
      // preferences and audit over the relay) is Phase 17; until then, any
      // copy claiming this panel opens only a WebSocket is false, and a
      // source-scan test keeps the old wording from coming back.
      final refusal = gateway.validationError;
      if (refusal != null) {
        throw StateError('Gateway mode is selected but the configuration '
            'cannot be dialled: $refusal');
      }
      final gatewayStateMan = await ref.read(gatewayStateManFactoryProvider)(
        uri: gateway.uri,
        clientConfig: await gateway.toClientConfig(),
        config: config,
        keyMappings: keyMappings,
      );
      // The alarm source reads `ALARM.active` and sends acknowledges through
      // the SAME client — a second one would be a second socket, a second
      // subscription and a second session for the gateway to police. See
      // [GatewayAlarmSlot] for why it cannot simply type-test this provider.
      alarmSlot.transport = RemoteAlarmTransport(gatewayStateMan.remote);
      stateMan = gatewayStateMan;
    } else {
      final m2400Clients = createM2400DeviceClients(config.jbtm);
      final modbusClients =
          buildModbusDeviceClients(config.modbus, keyMappings);
      final deviceClients = [...m2400Clients, ...modbusClients];
      stateMan = await ref.read(stateManFactoryProvider)(
          config: config,
          keyMappings: keyMappings,
          deviceClients: deviceClients);

      // Initialize collector
      ref.read(collectorProvider.future);
    }

    // The **inner** instance, exactly once. Closing through the decorator
    // would forward to the same call and add nothing but a second path to get
    // it wrong.
    ref.onDispose(() async {
      listener.cancel();
      // Cleared before the close, so nothing can pick a disposed client out of
      // the slot while the socket is going down.
      alarmSlot.transport = null;
      await stateMan.close();
    });

    return GuardedStateMan(
      inner: stateMan,
      policy: ref.read(accessPolicyProvider),
      // A callback, and never a watch on the session provider. This provider
      // is `keepAlive` and holds every OPC UA connection on the panel; a watch
      // would rebuild it — and drop every connection and every subscription —
      // on each sign-in, sign-out and inactivity timeout. Pinned by
      // `guard_wiring_test.dart`'s "signing in and out does not rebuild
      // stateManProvider", which also greps this file for that mistake.
      session: () => sessionInForce(ref),
      audit: RefAuditSink(ref),
      station: ref.read(stationNameProvider),
      // So a whole-struct write becomes one row per member that actually
      // moved, rather than two blobs.
      readBaseline: (key) => stateMan.read(key),
      onDenied: (denial) => reportAccessDenial(ref, denial),
    );
  } catch (e) {
    listener.cancel();
    stderr.writeln('Error parsing key mappings: $e');
    rethrow;
  }
}

final substitutionsChangedProvider =
    StreamProvider<Map<String, String>>((ref) async* {
  final sm = await ref.watch(stateManProvider.future);
  yield* sm.substitutionsChanged;
});

/// The live value of one key, as a stream that outlives the widgets watching
/// it.
///
/// Assets used to build their subscriptions inside `build`, which handed
/// `StreamBuilder` a new stream object on every rebuild — and a new object
/// means cancel the old subscription and open a fresh one. Resizing a window
/// or dragging an asset around the page editor rebuilds continuously, so
/// every asset on the page dropped and re-made its subscriptions once a
/// frame. Measured on the plant HMI that cost ~130 KiB of log a second, kept
/// StateMan's retry ladder permanently reset to its first step, and left the
/// window visibly lagging the mouse.
///
/// Reading through this instead, the subscription belongs to the *key* rather
/// than to whoever happens to be drawing it. A rebuild re-listens to a
/// [BehaviorSubject] that is already open and already holds the latest value;
/// nothing reaches StateMan at all. Two assets bound to the same key share one
/// subscription instead of opening two, and the value they show is the same
/// value by construction.
///
/// Auto-disposed, so leaving a page releases what that page was reading. A
/// rebuild does not: the watching element re-establishes its subscription
/// within the same frame, so the listener count never reaches zero.
final keyStreamProvider =
    Provider.autoDispose.family<Stream<DynamicValue>, String>((ref, key) {
  // Rebuilt if the connection is replaced, so the streams handed out are
  // always the current StateMan's. Until one exists there is nothing to
  // subscribe to, and an empty stream leaves each asset showing the same
  // "no value yet" it shows while waiting for a first reading.
  final stateMan = ref.watch(stateManProvider).valueOrNull;
  if (stateMan == null) return const Stream<DynamicValue>.empty();

  // A key like `Line1.$sb_line_stats_period` names its target through a
  // variable, and StateMan resolves that variable ONCE, at subscribe time.
  // Holding one subscription for the raw key is therefore wrong in both
  // directions: subscribed before the OptionVariable publishes, the resolve
  // throws and the failure would be held forever; subscribed after, the
  // stream stays pointed at the old target when the operator picks a new
  // period. Before subscriptions were shared, every widget rebuild happened
  // to retry the resolve, which is what made substitution appear to work.
  //
  // So a substituted key re-subscribes when the substitutions change — the
  // provider rebuilds, resolves against the new values, and every watcher is
  // handed the new stream. Plain keys skip this entirely; substitution
  // changes are operator clicks, not process data.
  if (key.contains(r'$')) {
    ref.watch(substitutionsChangedProvider);
  }

  // A subject rather than the raw stream: it is broadcast, so a rebuild may
  // re-listen freely, and it replays the last value, so an asset that
  // re-listens shows what it last knew instead of blanking.
  final subject = BehaviorSubject<DynamicValue>();
  StreamSubscription<DynamicValue>? subscription;
  var disposed = false;

  Future<void> open() async {
    try {
      final values = await stateMan.subscribe(key);
      if (disposed) return;
      subscription = values.listen(subject.add, onError: subject.addError);
    } catch (error, stackTrace) {
      // Reported to whoever is watching rather than swallowed: an asset bound
      // to a key the PLC does not serve should show that, and StateMan does
      // its own retrying underneath.
      if (!disposed) subject.addError(error, stackTrace);
    }
  }

  unawaited(open());
  ref.onDispose(() {
    disposed = true;
    subscription?.cancel();
    subject.close();
  });

  return subject.stream;
});
