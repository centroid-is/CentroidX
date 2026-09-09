import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/alarm.dart';
import '../core/relay_alarm_source.dart';
import 'gateway.dart';
import 'database.dart';
import 'preferences.dart';
import 'preferences_local_store.dart';
import 'state_man.dart';
part 'alarm.g.dart';

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
@Riverpod(keepAlive: true)
Future<AlarmSource> alarmMan(Ref ref) async {
  // WATCH, not read, and taken **before the first await** so the dependency is
  // registered synchronously (CR-01).
  //
  // Every source this provider builds is wired to the StateMan below — the
  // gateway branch through the relay client's alarm port, the direct branch
  // through the rule subscriptions `AlarmMan` opens on it — so an alarm source
  // that outlives its StateMan is an alarm source reading a connection that is
  // gone.
  //
  // It happens on an ordinary operator action. `GatewayStateMan`
  // `updateKeyMappings` returns a non-empty `reloadReasons` unconditionally,
  // so in gateway mode **every** `key_mappings` save takes
  // `state_man.dart:139`'s `ref.invalidateSelf()` and disposes the
  // `RemoteStateMan`. With `ref.read` this provider was never invalidated: it
  // kept a `RemoteAlarmTransport` over a disposed client for the life of the
  // process, and because that client CLOSES its handed-out streams rather than
  // erroring them, the banner froze with no error on screen and no line on
  // stderr. Direct mode has the same shape on the Modbus-spec / M2400 reload
  // path, one step rarer.
  //
  // This is not the "cascade invalidation from DB reconnects" the old comment
  // guarded against: `stateManProvider` itself reads `preferencesProvider` with
  // `ref.read`, so a database reconnect does not rebuild it and therefore does
  // not reach here. What does reach here is exactly what should — the StateMan
  // being replaced.
  final stateManFuture = ref.watch(stateManProvider.future);

  // Still `ref.read`: preferences are read once at construction and a
  // reconnect must not tear the alarm source down under a live banner.
  final prefs = await ref.read(preferencesProvider.future);
  final stateMan = await stateManFuture;

  // `AlarmMan.create` writes an empty default when `alarm_man_config` is
  // absent — at boot, on a station that has never been configured, with nobody
  // signed in, against a `configure` key. Seeding it here through the system
  // path means `create` finds the key present and never writes, which leaves
  // `packages/tfc_dart/lib/core/alarm.dart` untouched: its own `_saveConfig`
  // stays on the guarded object, which is right, because it is reached only
  // from addAlarm/removeAlarm/updateAlarm behind the `configure`-gated alarm
  // editor and never from `ackAlarm`.
  if (await prefs.getString('alarm_man_config') == null) {
    final systemPrefs = await ref.read(systemPreferencesProvider.future);
    await systemPrefs.setString(
        'alarm_man_config', jsonEncode(AlarmManConfig(alarms: [])));
  }

  final gateway = await ref.read(gatewayConfigProvider.future);
  if (gateway.isGateway) {
    // The client is built by `stateManProvider`, which was awaited above; it
    // publishes the port into the slot because `GuardedStateMan` cannot be
    // unwrapped. See [GatewayAlarmSlot].
    final transport = ref.read(gatewayAlarmSlotProvider).transport;
    if (transport == null) {
      throw UnsupportedError('alarmManProvider is not available in gateway '
          'mode: this station resolved a StateMan that is not a '
          'GatewayStateMan, so there is no relay client to read ALARM.active '
          'through. Fix the gateway branch of lib/providers/state_man.dart — '
          'do not fall back to evaluating the rules here.');
    }
    final source = await RelayAlarmSource.create(
      transport: transport,
      preferences: prefs,
      // Null on a station with no Postgres of its own, and on every browser.
      // The alarm *history* is still local in gateway mode (D-11); when it
      // moves onto the wire this argument is what stops being needed.
      database: await ref.watch(databaseProvider.future),
    );
    // `RelayAlarmSource.close` had no caller anywhere before CR-01, so every
    // rebuild — a key-mappings save, an alarm edit, which invalidates this
    // provider by name (`alarm_editor.dart:245`) — left a live subscription,
    // two BehaviorSubjects and a `_reloadHistory` chain behind on a client
    // that no longer existed.
    ref.onDispose(source.close);
    return source;
  }

  // `clock: DateTime.now` is required, and this provider is the composition
  // root that supplies it for a panel: `packages/tfc_dart/lib/core/alarm.dart`
  // spells the literal nowhere, so an alarm instant can only ever be the
  // plant's word or a reading someone handed in on purpose (14-07, D-2).
  // Direct mode: the evaluator runs here, against this station's own store.
  return await AlarmMan.create(
      await ref.read(localStorePreferencesProvider.future), stateMan,
      clock: DateTime.now);
}

/// The alarm list of whichever [AlarmMan] is current, or `null` when there is
/// none to read right now.
///
/// [AlarmMan.config.alarms] is mutated in place, but every accepted alarm edit
/// follows the mutation with `invalidate(alarmManProvider)` -- which builds a
/// new [AlarmMan] around a new list loaded back from preferences. Anything
/// that captured the [AlarmMan], or its list, is pinned to an orphan from that
/// moment on. Long-lived consumers (the MCP alarm reader) call this on every
/// read instead, so an invalidate is picked up without restarting the app.
///
/// Returns `null` rather than an empty list while the provider is rebuilding,
/// so a consumer can tell "not readable yet" from "no alarms configured".
List<AlarmConfig>? currentAlarmConfigs(Ref ref) {
  try {
    return ref.read(alarmManProvider).valueOrNull?.config.alarms;
  } catch (_) {
    // The container is gone (shutdown mid-tool-call). Nothing to report --
    // the caller falls back to what it last saw rather than throwing.
    return null;
  }
}
