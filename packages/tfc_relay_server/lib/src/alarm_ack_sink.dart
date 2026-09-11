/// The one seam an acknowledge crosses on its way out of the gateway.
///
/// Phase 14 plan 12, ALRM-04.
library;

/// Where an accepted [Methods.ackAlarm] goes.
///
/// ## Why a seam and not a dependency
///
/// This package cannot name an alarm engine. The engine lives in `tfc_dart`,
/// and `tfc_dart` depends on *this* package — so a direct reference here would
/// be a cycle, and the version-solve consequence of pulling the Flutter side
/// into a pure-Dart server package is the analyzer-cap blocker that has stopped
/// this repo twice in twelve months. So the gateway takes the engine as an
/// argument, injected at [RelayServer] construction in the style
/// `TokenValidator` and `KeyPolicy` are: a deployment supplies its own, a test
/// supplies a recorder, and this package stays able to be built and tested with
/// no alarm engine in the world.
///
/// It is on the barrel for that reason and only that reason — an embedder
/// writing `RelayServer(alarmAcks:)` has to be able to name the type.
///
/// ## Why it returns a plain future and not an outcome type
///
/// A write has a three-state ladder — applied / rejected / unknown — because a
/// write moves a machine and an operator who is told the wrong thing about it
/// presses the button again. **An acknowledge moves nothing in the plant.**
/// Inventing a three-state answer here would be worse than not having one: it
/// would be a vocabulary with no failure mode behind it, and the client code
/// that switched on it would be handling cases that cannot occur.
///
/// So the contract is the ordinary Dart one. **Completing** means the engine
/// accepted the acknowledge and applied it. **Throwing** means it did not —
/// the row was not found, the database refused, the engine was shutting down —
/// and the gateway turns that into `handlerFailed` rather than into a success,
/// because an operator told an alarm was acknowledged while it sits on the
/// banner is the one answer nobody can act on.
///
/// The operator's real confirmation is neither of those. It is the alarm
/// leaving `AlarmKeys.active`, which is PROJECT.md's *"readback is the only
/// confirmation"* applied here without an exception.
///
/// ## Why two plain arguments rather than the wire DTO
///
/// `AckAlarmParams` belongs to `tfc_relay_protocol`, and a seam an embedder
/// *implements* should not oblige it to decode a wire shape it did not choose.
/// The two values are D-4's `(alarm_uid, rule_index)`, which is also the key of
/// the partial unique index on `alarm_history`, so an engine can resolve the
/// open row from them and nothing else.
abstract interface class AlarmAckSink {
  /// Acknowledge the open alarm row identified by [alarmUid] and [ruleIndex].
  ///
  /// Called only after the gateway has checked that `AlarmKeys.active` is a key
  /// this station may see and that the station may actuate it — the same
  /// `KeyPolicy.canWrite` answer that gates a write. An implementation does not
  /// repeat the authorization decision and must not soften it.
  ///
  /// **Idempotent by contract.** Acknowledging an already-acknowledged row is a
  /// no-op that completes, not an error: the second ack of the same alarm is
  /// the same operator intent as the first, which is exactly why the wire frame
  /// carries no idempotency key to distinguish them.
  Future<void> acknowledge(String alarmUid, int ruleIndex);
}
