import 'dart:async';

import 'package:logger/logger.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc_dart/core/state_man.dart';
import 'access.dart';
import 'access_policy.dart';
import 'config_store.dart';
import 'preferences.dart';
import 'collector.dart';

part 'state_man.g.dart';

/// File-level logger. These diagnostics used to go to stderr, which in a
/// windowed MSIX build with no console is discarded outright.
final Logger _log = Logger();

/// How the inner, unguarded [StateMan] is built.
typedef StateManFactory = Future<StateMan> Function({
  required StateManConfig config,
  required KeyMappings keyMappings,
  List<DeviceClient> deviceClients,
});

/// The seam through which [stateManProvider] constructs its inner [StateMan].
///
/// Production reads the default and nothing else overrides it. It exists so
/// that `guard_wiring_test.dart` can prove the properties this provider is
/// judged on — that a sign-in does not rebuild it, and that `close()` reaches
/// the inner instance exactly once — without opening an OPC UA connection in a
/// unit test. Those two properties have no other way to be observed, and both
/// of them failing looks like nothing at all until it is a plant.
final stateManFactoryProvider =
    Provider<StateManFactory>((ref) => StateMan.create);

@Riverpod(keepAlive: true)
Future<StateMan> stateMan(Ref ref) async {
  // Use ref.read instead of ref.watch to break the reactive dependency chain.
  // StateMan reads config once at init; DB reconnects should NOT cascade here
  // and destroy all OPC-UA connections/isolates.
  //
  // The configuration store is deliberately safe to read this way: its object
  // identity never changes for the life of the process, and the Postgres half
  // is attached underneath it. See `config_store.dart`.
  final store = (await ref.read(configStoreProvider.future)).inner;
  // The app's own default `state_man_config`, written on a station that has
  // never been configured, with nobody signed in, against a key the policy
  // classes as `administer` — so on the guarded object it would be a denial at
  // boot. The key mappings' own boot default is not here any more: it is the
  // store's `seedDefaultIfEmpty`, which only writes against a reachable and
  // genuinely empty shared database.
  final systemPrefs = await ref.read(systemPreferencesProvider.future);
  final config = await StateManConfig.fromPrefs(systemPrefs);

  // What the shared store holds. A station with no Postgres and an empty
  // mirror boots on empty mappings, which is the honest answer: it has no
  // shared configuration, and inventing an example key here would put one key
  // of nonsense into a plant the moment the database came back.
  final keyMappings = store.keyMappings;

  // A key_mappings save is applied incrementally: unchanged keys keep their
  // connections and subscriptions untouched, edited OPC UA keys are re-pointed
  // live, and only edits the adapters cannot absorb in place (classic-Modbus
  // register specs, M2400 extraction) fall back to a full provider rebuild —
  // the old "whole world awakens" path.
  //
  // **On the store's stream, not on `Preferences.onPreferencesChanged`.** That
  // was C-1: this provider reads preferences with `ref.read` on purpose (a
  // watch would drop every OPC UA connection on each database reconnect), so
  // it subscribed to the `Preferences` instance that existed at boot — and
  // `preferencesProvider` builds a *new* one on every reconnect, after which
  // the listener was attached to an object nobody wrote to again. The symptom
  // was key-mapping edits silently not applying, forever, after the first
  // database blip. The store outlives every provider rebuild, so subscribing
  // to it is the fix rather than a way of avoiding the bug.
  //
  // The diff comes from the store, which has already computed it to decide
  // which rows to write, and goes straight to `updateKeyMappings` — no
  // re-derivation from two full blobs.
  //
  // Applications are serialized through [pendingApply] so two rapid saves
  // cannot interleave their diffs out of order.
  var pendingApply = Future<void>.value();
  final listener = store.keyMappingChanges.listen(
    (diff) {
      pendingApply = pendingApply.then((_) async {
        try {
          final stateMan = await ref.read(stateManProvider.future);
          final result =
              stateMan.updateKeyMappings(store.keyMappings, diff: diff);
          if (result.requiresReload) {
            _log.i('key_mappings: full reload required '
                '(${result.reloadReasons.join('; ')})');
            ref.invalidateSelf();
          }
        } catch (error, stack) {
          // A key mapping that fails to apply is the direct cause of a dead
          // key on a page, and this is the only record that it happened.
          _log.e('Failed to apply key_mappings change: $error',
              error: error, stackTrace: stack);
        }
      });
    },
    onError: (Object error, StackTrace stack) {
      _log.e('Error in the key mapping change listener: $error',
          error: error, stackTrace: stack);
    },
  );

  try {
    final m2400Clients = createM2400DeviceClients(config.jbtm);
    final modbusClients = buildModbusDeviceClients(config.modbus, keyMappings);
    final deviceClients = [...m2400Clients, ...modbusClients];
    final stateMan = await ref.read(stateManFactoryProvider)(
        config: config,
        keyMappings: keyMappings,
        deviceClients: deviceClients);

    // Initialize collector
    ref.read(collectorProvider.future);

    // The **inner** instance, exactly once. Closing through the decorator
    // would forward to the same call and add nothing but a second path to get
    // it wrong.
    ref.onDispose(() async {
      listener.cancel();
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
    _log.e('Error parsing key mappings: $e');
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
