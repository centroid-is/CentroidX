import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/alarm.dart';
import 'config_store.dart';
import 'preferences.dart';
import 'state_man.dart';
part 'alarm.g.dart';

@Riverpod(keepAlive: true)
Future<AlarmMan> alarmMan(Ref ref) async {
  // Use ref.read to avoid cascade invalidation from DB reconnects.
  // AlarmMan reads config once at creation; it doesn't need live DB updates.
  final prefs = await ref.read(preferencesProvider.future);
  final stateMan = await ref.read(stateManProvider.future);

  // "No alarm_man_config" means "this plant has none" only once the first
  // reconcile has landed: the snapshot is filled from the local mirror, so a
  // fresh station attached to a configured plant reads null until then. The
  // seed below must not write an empty configuration into a plant with two
  // hundred alarms — the store would refuse it as a conflict, and swallow
  // that, but the *read* that follows would still be null for this boot.
  // Settles at once when no remote is attached.
  final store = (await ref.read(configStoreProvider.future)).inner;
  await store.syncSettled;

  // `AlarmMan.create` treats an absent `alarm_man_config` as empty and writes
  // nothing. The seed lives here, through the system path — no check, no
  // refusal offline — so that the row exists once a station has seen the
  // plant, and `create` never has to write: its own `_saveConfig` stays on
  // the guarded object, reached only from addAlarm/removeAlarm/updateAlarm
  // behind the `configure`-gated alarm editor and never from `ackAlarm`.
  if (await prefs.getString('alarm_man_config') == null) {
    final systemPrefs = await ref.read(systemPreferencesProvider.future);
    await systemPrefs.setString(
        'alarm_man_config', jsonEncode(AlarmManConfig(alarms: [])));
  }

  return await AlarmMan.create(prefs, stateMan);
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
