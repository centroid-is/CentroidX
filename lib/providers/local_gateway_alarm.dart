/// When the panel's own gateway alarm stands, and since when.
///
/// [localGatewayAlarmProvider] is the one value the two alarm surfaces — the
/// app-bar banner in `base_scaffold.dart` and the active list in
/// `widgets/alarm.dart` — merge beside the plant's set. It is derived
/// entirely from [gatewayLinkProvider], so:
///
///  * **direct mode is silence by construction** — that provider publishes
///    `null` there, and null maps to no alarm;
///  * **there are no timers here.** The patience window (the only clock-driven
///    transition in this vocabulary) already lives in `gatewayLinkProvider`,
///    listener-gated; a second timer would be the always-on `Timer.periodic`
///    this repo's plumbing has been bitten by before.
///
/// **This provider never touches an [AlarmSource].** The alarm it publishes
/// is a bare value the surfaces render; it is not added to any `AlarmMan`,
/// not acknowledged, not in any history buffer, and
/// `test/providers/local_gateway_alarm_test.dart` pins that a raise
/// instantiates neither `alarmManProvider`, `preferencesProvider` nor
/// `stateManProvider` — the whole of the argument in
/// `lib/core/local_gateway_alarm.dart` depends on that closure staying
/// closed.
///
/// ## The latch
///
/// The alarm's timestamp answers "since when has this panel been out of
/// touch", so it is stamped ONCE, when the report first turns alarm-worthy,
/// and held across every later report of the same outage — prose changes
/// ("the connection ended" → "gone quiet") and kind changes ("unreachable" →
/// "refused") alike. Re-stamping on each report would make the alarm look
/// freshly raised all night. The latch clears when the report goes quiet
/// (connected, connecting, or direct), so a second outage is a second event
/// with its own instant.
///
/// The built [AlarmActive] is also reused by identity while its title and
/// description stand: the Alarm View retains its selection by uid, but the
/// history-merge on that page dedupes by identity, and a value that churned
/// per rebuild would defeat any consumer that does.
///
/// The latch lives on a plain object behind its own `Provider` — the
/// `GatewayLinkTimerProbe` shape from `gateway_link.dart`, for the same
/// reason: state on the derived provider itself would be thrown away by
/// exactly the rebuild the latch exists to survive.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/alarm.dart';

import '../core/local_gateway_alarm.dart';
import 'gateway_link.dart';

/// The outage latch: when the standing outage began, and the alarm built for
/// it. Both null while the link is healthy.
final class LocalGatewayAlarmSlot {
  /// When the current outage was first observed, by
  /// [gatewayLinkClockProvider]'s clock. Held across kind and prose changes;
  /// cleared on recovery.
  DateTime? raisedAt;

  /// The alarm as last built, reused by identity while its words stand.
  AlarmActive? current;
}

/// The one [LocalGatewayAlarmSlot] for this container.
final localGatewayAlarmSlotProvider =
    Provider<LocalGatewayAlarmSlot>((ref) => LocalGatewayAlarmSlot());

/// The panel's own gateway alarm, or null while there is nothing to say.
///
/// Null on every direct station, on a healthy link, during the first dial's
/// patience window, and while the link report is still unresolved — all four
/// render as absence on the surfaces, which is what keeps this alarm from
/// standing on half the fleet.
final localGatewayAlarmProvider = Provider<AlarmActive?>((ref) {
  final slot = ref.watch(localGatewayAlarmSlotProvider);
  final clock = ref.watch(gatewayLinkClockProvider);
  // `valueOrNull` collapses loading AND error to "no report": a link-status
  // provider that cannot say what the link is doing cannot honestly raise an
  // alarm about it.
  final report = ref.watch(gatewayLinkProvider).valueOrNull;

  final alarm = localGatewayAlarm(
    report,
    raisedAt: slot.raisedAt ?? clock(),
  );
  if (alarm == null) {
    // Recovery (or nothing yet): clear the latch so the NEXT outage is a new
    // event with its own instant. Ephemerality is the whole design — no
    // history entry lingers anywhere when this returns null.
    slot.raisedAt = null;
    slot.current = null;
    return null;
  }

  slot.raisedAt = alarm.notification.timestamp;
  final held = slot.current;
  if (held != null &&
      held.alarm.config.title == alarm.alarm.config.title &&
      held.alarm.config.description == alarm.alarm.config.description) {
    return held;
  }
  slot.current = alarm;
  return alarm;
});
