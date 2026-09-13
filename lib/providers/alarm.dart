import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/config/config_item.dart' show ConfigKind;
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
  // Settles at once when no remote is attached — which is why the readiness
  // provider is awaited first: it completes once the first attach has been
  // acted on (or the station is offline, or the database has not answered
  // in twenty seconds), and only then does `syncSettled` mean anything.
  await ref.read(configStoreReadyProvider.future);
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

  final alarmMan = await AlarmMan.create(prefs, stateMan);

  // The row can still arrive *after* this built: a station that booted while
  // another was migrating, or one whose first attach timed out. Nothing else
  // rebuilds this provider on a shared change — the editor's invalidate is
  // for edits made here — so the store's own feed does it, when the row it
  // announces differs from what this instance was built from. Our own saves
  // announce a row equal to the config they wrote, so they rebuild nothing
  // twice. The store's stream, not the preference store's: the latter is
  // rebuilt on every database rebuild and a listener on it goes deaf (D-2).
  final feed = store.keyMappingChanges.listen((diff) async {
    final touched = [...diff.added, ...diff.changed, ...diff.removed].any(
        (item) =>
            item.kind == ConfigKind.preference && item.id == 'alarm_man_config');
    if (!touched) return;
    final now = await prefs.getString('alarm_man_config');
    if (now == jsonEncode(alarmMan.config.toJson())) return;
    ref.invalidateSelf();
  });
  ref.onDispose(feed.cancel);

  return alarmMan;
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
