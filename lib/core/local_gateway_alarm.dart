/// The panel's own alarm about its gateway link — client-local, in-memory,
/// and **never in TimescaleDB**. This file is the mapping from a
/// [GatewayLinkReport] to the [AlarmActive] the panel's ordinary alarm
/// surfaces render; `lib/providers/local_gateway_alarm.dart` owns when it is
/// raised and cleared.
///
/// ## Why this alarm must never be persisted or backend-evaluated
///
/// It replaced the app bar's gateway-link pill, which nobody watched; losing
/// the backend now announces itself the way any other fault does — in the
/// alarm banner and on the Alarm View page. But it is deliberately NOT an
/// alarm in the plant's alarm system, for three reasons that are each
/// sufficient alone:
///
///  1. **The alarm exists precisely because the backend is unreachable.** An
///     alarm about a dead link cannot be stored through the dead link — the
///     backend's alarm engine, the `ALARM.active` key and the
///     `alarm_history` table are all on the far side of the very connection
///     this alarm reports the loss of.
///  2. **It is about THIS panel's connectivity, not a plant condition.** It
///     is meaningless to every other station, and a row for it in a shared
///     history would be noise beside real plant faults.
///  3. **Persisting it would be a row storm.** One row per panel per outage
///     — reconnect flaps included — into a table that exists to record what
///     went wrong on the LINE, written by every station in the plant at
///     exactly the moment the infrastructure is misbehaving.
///
/// So it is ephemeral: raised in memory when the link report says the panel
/// is out of touch, gone the moment the link returns, never a definition row,
/// never a history row, never acknowledged (there is nowhere to record the
/// receipt), and `countsAsStop: false` (a lost panel link is not plant
/// downtime). On a panel even the direct-mode [AlarmMan] could not persist it
/// — history is written only by the backend's `AlarmHistoryWriter` (D-6) —
/// but this alarm never enters ANY [AlarmSource] at all: the two surfaces
/// take it as a value beside the plant set, so `ackAlarm`, the history
/// buffer and `getRecentAlarms` cannot reach it by construction.
///
/// ## The uid is deliberately OUTSIDE the `ALARM.` namespace
///
/// `packages/tfc_relay_protocol/lib/src/alarm_keys.dart` owns `ALARM.` — the
/// reserved RELAY-KEY namespace the backend's alarm engine publishes through.
/// [kLocalGatewayAlarmUid] is not a key: it names nothing on the wire, is
/// never subscribed, never crosses to the backend, and an operator (or a
/// grep) finding it must not read it as something the backend produced. It is
/// also not a UUID, on purpose — every plant alarm's uid is editor-minted,
/// and a name that says what it is makes "where did this alarm come from"
/// answerable from a screenshot.
///
/// ## What it covers — every [GatewayLinkKind], mapped deliberately
///
/// The chip this replaces carried `notBuilt` ("Panel misconfigured") — the
/// transport that could not even be CONSTRUCTED, plan 15-08's closed gap —
/// and deleting the chip without absorbing that state would re-open it. The
/// switch below is total with no `default`, so a new kind is a compile error
/// here exactly as it is on every other surface of this vocabulary. The
/// distinctions the titles draw are the operator's ACTIONS: an unreachable
/// gateway may fix itself and is chased at the far end; a misconfigured
/// panel never fixes itself and is chased on this station's disk; a refusal
/// is a decision somebody has to act on.
///
/// **Silence is deliberate on exactly three inputs:** a null report (direct
/// mode — there is no gateway, so there must be no such alarm, or half the
/// fleet stands in permanent alarm and the surface stops being read),
/// `connected`, and `connecting` (the first dial inside its patience window —
/// `gatewayLinkProvider` flips a stalled first dial to `unreachable` when the
/// patience expires, so this file never needs its own clock for that).
///
/// ## Colour
///
/// The alarm renders through the alarm surface's own vocabulary —
/// `AlarmColors.error`, the reserved, scheme-invariant fault red (ISA-18.2)
/// — because a panel showing stale values on every page IS a genuine fault,
/// and fault red is the one saturated colour the house rules allow. Nothing
/// here names a colour: reusing the surface is the point.
///
/// ## It is pure
///
/// No widgets, no I/O, no `DateTime.now()` — [raisedAt] is injected by the
/// provider from `gatewayLinkClockProvider`, which is what keeps the goldens
/// of this alarm constants. The prose is the report's own `headline` and
/// `detail`, written once in `gateway_link_status.dart` and not reworded
/// here; `GatewayLinkReport.raw` — the ticket text this app did not write —
/// is deliberately NOT carried into [AlarmNotification.expression], because
/// the alarm pane is operator prose and the Transport card is where a
/// support engineer reads the raw reason.
library;

import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

import 'gateway_link_status.dart';

/// The one spelling of the local gateway alarm's uid.
///
/// See the library doc: outside `ALARM.` (that is the relay-key namespace,
/// and this is not a key), and readable rather than a UUID (so its origin is
/// answerable from a screenshot). `test/core/local_gateway_alarm_test.dart`
/// pins both properties with `AlarmKeys.isAlarmKey` as the live control.
const String kLocalGatewayAlarmUid = 'local-panel.gateway-link';

/// The alarm [report] warrants on THIS panel's alarm surfaces, or null.
///
/// Null for a null report (direct mode), for a healthy link and for a first
/// dial still inside its patience window — see the library doc for why each
/// silence is deliberate. [raisedAt] is when the outage began as the caller
/// latched it, never an ambient clock.
AlarmActive? localGatewayAlarm(
  GatewayLinkReport? report, {
  required DateTime raisedAt,
}) {
  if (report == null) return null;

  // Total, no `default`: a new GatewayLinkKind must be mapped here on the
  // day it is invented, not fall silently to whichever branch survives.
  final String? title = switch (report.kind) {
    GatewayLinkKind.connected => null,
    GatewayLinkKind.connecting => null,
    GatewayLinkKind.unreachable => 'Gateway unreachable',
    GatewayLinkKind.untrustedCertificate => 'Gateway certificate refused',
    GatewayLinkKind.credentialRefused => 'Gateway refused this panel',
    GatewayLinkKind.versionRefused => 'Gateway refused this build',
    // Not "unreachable": nothing was ever dialled. The fault is on this
    // station's own disk and waiting will not fix it — the operator must be
    // sent to Server Config, not to the switch cupboard. This is the 15-08
    // state the deleted chip used to carry.
    GatewayLinkKind.notBuilt => 'Panel misconfigured',
  };
  if (title == null) return null;

  final rule = AlarmRule(
    level: AlarmLevel.error,
    // There is no expression: nothing evaluated this alarm and nothing will.
    // The empty formula is never parsed — `AlarmNotification.expression`
    // below is null, and no Evaluator is ever constructed over this rule.
    expression: ExpressionConfig(value: Expression(formula: '')),
    // An acknowledgement would have to be recorded somewhere, and there is
    // deliberately nowhere. The alarm clears itself when the link returns.
    acknowledgeRequired: false,
  );

  return AlarmActive(
    alarm: Alarm(
      config: AlarmConfig(
        uid: kLocalGatewayAlarmUid,
        title: title,
        // The report's own two sentences, unreworded: the headline names the
        // endpoint, the detail names the end of the wire to go and check.
        description: '${report.headline}. ${report.detail}',
        rules: [rule],
        // A lost panel link is not plant downtime. This alarm never reaches
        // the stop analysis anyway (it reads `alarm_history`, which this
        // never enters), but the flag states the intent where the next
        // reader will look for it.
        countsAsStop: false,
      ),
    ),
    notification: AlarmNotification(
      uid: kLocalGatewayAlarmUid,
      active: true,
      // Deliberately not `report.raw` — see the library doc.
      expression: null,
      rule: rule,
      timestamp: raisedAt,
      ruleIndex: 0,
      // Neither `plant` nor `backendReceipt` is true of this instant — it is
      // this station's own clock — and inventing a third wire value for a
      // stamp that never goes on the wire would widen a persistence
      // vocabulary this alarm exists to stay out of. Null is the honest
      // "no wire provenance".
      tsSource: null,
    ),
  );
}
