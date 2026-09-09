import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/state_man_types.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show ClientConfig, RemoteStateMan;
import '../core/gateway_state_man.dart';
import '../core/relay_alarm_source.dart';
import '../core/value_freshness.dart';
import 'access.dart';
import 'direct_transport.dart';
import 'state_man_config_read.dart';
import 'gateway.dart';
import 'access_policy.dart';
import 'preference_changes.dart';
import 'preferences.dart';
import 'value_freshness.dart';

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
    {PreferencesApi? systemWrites}) async {
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
    Provider<StateManFactory>((ref) => createOpcUaStateMan);

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
  final config = await ref.read(stateManConfigProvider.future);

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
  // Through the transport-aware stream, not the store: the drift-backed one
  // and the relayed one both announce edits and neither type is the other.
  final listener = ref.read(preferenceChangesProvider.stream).listen(
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
      // The station-side Postgres dependency the rig measured here
      // (13-RIG-E2E-EVIDENCE FIND-C) is closed now: `lib/providers/
      // database.dart` branches on the transport and returns before dialling,
      // and `preferencesProvider` no longer watches it in gateway mode —
      // access, the audit trail and templates went over the relay in 17-12,
      // and the shared configuration store runs on the device-local mirror.
      // What a gateway panel still opens beside the socket is device-local
      // storage, which is a file, not a connection.
      //
      // `undialable`, not `validationError`: the edit-time getter deliberately
      // lets a wss row with no pinned trust through so the Save button can
      // run the fetch-and-approve ceremony, but at boot there is no Save
      // coming — a trustless row here is exactly as undialable as ever, and
      // refusing it by name is what lands on GatewayLinkKind.notBuilt instead
      // of on the CERTIFICATE_VERIFY_FAILED a genuine impostor also produces.
      final refusal = gateway.undialable;
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
      // The panel's own sessions, and the collector that historises them.
      // Behind `direct_transport.dart` because an OPC UA client is `dart:ffi`
      // and a browser has no equivalent — the web arm refuses by name rather
      // than building something that would never receive a value.
      stateMan = await buildDirectStateMan(ref,
          config: config, keyMappings: keyMappings);
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
///
/// ## And it is where staleness becomes visible
///
/// **The rig measured what this gate is for.** On 2026-09-07 a connected
/// panel's link was cut and, at +25 s and again at +65 s, the app-bar chip read
/// yellow `No gateway` while **every plant value on the home page still
/// rendered definite** — no `!`, no `--- °C`, no greying. The chip was the only
/// thing on the screen that knew. 16-10-SUMMARY had already named the cause:
/// `viewIsStale` and `viewFreshness` **had no reader in any `lib/`**.
///
/// This is the reader, and it is here rather than in the assets for one
/// reason: **twenty-odd widgets render values and every one of them reads this
/// provider.** A greying added to each is twenty chances to miss one, and the
/// one missed is the one an operator is standing in front of. One funnel, one
/// gate.
///
/// While [valueFreshnessProvider] says the panel cannot vouch for its values
/// the subject carries [StaleValues] instead of a value — the same channel a
/// subscribe that threw already uses, which every asset in the library already
/// renders as its unknown-value form (`(hasData && !hasError) ? … : null` →
/// `---`, `!`, a grey belt). Nothing about the pixels is invented, so nothing
/// about the pixels can move.
///
/// **The value is withheld, not decorated.** A number the panel cannot vouch
/// for is a number an operator must not read, and the app's existing word for
/// that is `---`. Rendering it greyed-but-legible would leave the digits on the
/// glass to be read across a room by somebody who never saw the chip.
final keyStreamProvider =
    Provider.autoDispose.family<Stream<DynamicValue>, String>((ref, key) {
  // Rebuilt if the connection is replaced, so the streams handed out are
  // always the current StateMan's. Until one exists there is nothing to
  // subscribe to, and an empty stream leaves each asset showing the same
  // "no value yet" it shows while waiting for a first reading.
  final stateMan = ref.watch(stateManProvider).valueOrNull;
  if (stateMan == null) return const Stream<DynamicValue>.empty();

  // Whether this panel can vouch for what it shows. A direct station's answer
  // is a constant built without reading anything heavier than its transport
  // row, so this costs the plant's existing stations nothing and — pinned by
  // `visible_staleness_test.dart`'s two direct-mode arms — can never grey one
  // out.
  //
  // Watched, not read: the OBJECT is stable across a link flapping (it holds
  // its own verdict and publishes transitions), so this dependency rebuilds
  // this provider only when the transport row or the StateMan changes, which
  // are the two things that already rebuild it. A `watch` on something that
  // changed identity per transition would drop and re-open every subscription
  // on the panel each time the link blinked.
  final freshness = ref.watch(valueFreshnessProvider);

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
  StreamSubscription<bool>? freshnessChanges;
  var disposed = false;

  // The last reading this key received, held so the transition back to fresh
  // can re-publish it. By then it IS the current connection's value: the
  // client only clears its badge from `_enter(LinkState.ready)`, which is
  // reached after every page's snapshot has been adopted (16-10 / S9), and
  // adopting a snapshot pushes each key through the subscription below.
  DynamicValue? held;

  /// Puts the panel's current answer for this key on the subject.
  ///
  /// One function for both directions so the two cannot drift: a stale panel
  /// says why it has no value, a fresh one says what the value is.
  void publish() {
    if (disposed) return;
    if (freshness.isStale) {
      subject.addError(StaleValues(key));
    } else if (held != null) {
      subject.add(held!);
    }
  }

  // Seeded, not merely followed. A page opened DURING an outage builds this
  // provider from scratch and would otherwise wait for a transition that
  // already happened, showing the store's pre-outage reading until the link
  // came back.
  if (freshness.isStale) subject.addError(StaleValues(key));
  freshnessChanges = freshness.changes.listen((_) => publish());

  Future<void> open() async {
    try {
      final values = await stateMan.subscribe(key);
      if (disposed) return;
      subscription = values.listen(
        (value) {
          held = value;
          // Through `publish`, not straight onto the subject: values do keep
          // arriving while the badge is set — the store still answers, and a
          // resync pushes snapshots for seconds before the view is fresh —
          // and those are precisely the ones that must not be shown as
          // current.
          publish();
        },
        onError: subject.addError,
      );
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
    freshnessChanges?.cancel();
    subject.close();
  });

  return subject.stream;
});
