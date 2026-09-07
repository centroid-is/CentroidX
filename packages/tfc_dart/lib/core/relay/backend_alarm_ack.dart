/// The one file in `tfc_dart` that names the gateway's acknowledge seam.
///
/// ## Why this is a separate file and not `implements AlarmAckSink` on the
/// engine
///
/// `backend_alarms.dart` must not import `tfc_relay_server`, and the reason is
/// D-8 rather than tidiness. The alarm engine is constructed
/// **unconditionally** — `bin/main.dart` builds it above the relay guard, so
/// that turning the WebSocket off does not turn the plant's alarms off — while
/// the relay section is optional and SVN runs with it absent today. An engine
/// whose own declaration named `AlarmAckSink` would be an engine a backend with
/// no relay could not build. The dependency edge exists (`tfc_dart` →
/// `tfc_relay_server`, one-way, pinned by `package_edge_test.dart`), so the
/// import would compile; it is the *coupling* that would be wrong, and it would
/// be wrong in the direction that takes the plant's alarms out with the
/// WebSocket.
///
/// So the seam is named here, in a file constructed only inside the relay
/// composition, and `backend_alarm_ack_test.dart` asserts by source scan that
/// the string `tfc_relay_server` appears nowhere in the engine.
///
/// ## Why it is thin, and stays thin
///
/// Authorization is the gateway's (14-12: `AlarmHandlers` asks the same
/// `KeyPolicy.canWrite` question a write asks, through the same expression).
/// A second opinion here would be a second place to get it wrong, and the two
/// could drift without anything failing. Filtering, logging and retrying are
/// somebody else's job for the same reason. What is left is one field, one
/// method and one `await` — and the test measures the file's non-comment line
/// count, because a fat adapter is policy that escaped the gateway.
library;

import 'package:tfc_relay_server/tfc_relay_server.dart' show AlarmAckSink;

import 'backend_alarms.dart';

/// Hands an accepted `ackAlarm` to the alarm engine, and nothing else.
///
/// **Completing means applied; throwing means not** — `AlarmAckSink`'s
/// contract, kept by doing nothing to the answer. A swallowed failure here
/// becomes an operator told the alarm was acknowledged while it sits on the
/// banner, which is the one answer nobody can act on.
final class BackendAlarmAckSink implements AlarmAckSink {
  const BackendAlarmAckSink(this.engine);

  /// The engine this gateway acknowledges into.
  ///
  /// Public so the composition arm can assert it is *the* engine the panels are
  /// served from, rather than a second one acknowledging into nothing.
  final AlarmAcknowledger engine;

  @override
  Future<void> acknowledge(String alarmUid, int ruleIndex) =>
      engine.acknowledge(alarmUid, ruleIndex);
}
