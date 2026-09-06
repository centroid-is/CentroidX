import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/alarm.dart';
import '../core/relay_alarm_source.dart';
import 'gateway.dart';
import 'preferences.dart';
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
  // Use ref.read to avoid cascade invalidation from DB reconnects.
  // AlarmMan reads config once at creation; it doesn't need live DB updates.
  final prefs = await ref.read(preferencesProvider.future);
  final stateMan = await ref.read(stateManProvider.future);

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
    return await RelayAlarmSource.create(
        transport: transport, preferences: prefs);
  }

  // `clock: DateTime.now` is required, and this provider is the composition
  // root that supplies it for a panel: `packages/tfc_dart/lib/core/alarm.dart`
  // spells the literal nowhere, so an alarm instant can only ever be the
  // plant's word or a reading someone handed in on purpose (14-07, D-2).
  return await AlarmMan.create(prefs, stateMan, clock: DateTime.now);
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
