/// One seam decides whether a failed call means "we do not know" or "the
/// server said no".
///
/// Source: 04-RESEARCH Finding 1, four experiments executed against
/// `json_rpc_2` 4.1.0:
///
/// | Situation | Observed outcome | Exact type |
/// |---|---|---|
/// | Request in flight, transport closes under it | rejects | `StateError: Bad state: The client closed with pending request "neverAnswered".` |
/// | Same, but the close came from a real `killOnce` through FaultProxy | rejects, identical message | `StateError: Bad state: The client closed with pending request "subscribe".` |
/// | Response arrives carrying a **different id** | never settles — still pending after 400 ms | (eternal hang) |
/// | `sendRequest` called after the peer is already closed | throws | `StateError: Bad state: The client is closed.` |
///
/// Two consequences, and the second one is why this file exists.
///
/// **`on RpcException` misses connection loss entirely.** The library reports
/// a lost link as a `StateError`, so a call site that catches only
/// `RpcException` never sees it, and one that treats every caught error as a
/// server answer gets the verdict exactly backwards.
///
/// **The verdicts are opposites in the plant.** *Rejected* means the machine
/// did not move: the operator reads the reason, changes something, tries
/// again. *Unknown* means nobody knows: the operator has to walk out and look
/// at the equipment before touching anything. Report a lost link as a refusal
/// and you have told someone a valve definitely did not open when it may well
/// have opened. Report a genuine interlock refusal as unknown and you send a
/// fitter across the factory for nothing — which is how a plant learns to
/// ignore the warning, and then ignores the real one.
///
/// **The trap underneath** (Finding 1 note 3): `StateError` is also what a
/// plain programming error looks like, and the message string is the only
/// thing that tells them apart. So the match lives in exactly one predicate,
/// [isLinkLossMessage], deliberately narrow, and anything it does not
/// recognise is rethrown. A bare `on StateError` at this seam would swallow
/// our own defect *and* report it to the operator as a plant condition.
///
/// **Nothing here re-issues a request.** A write is an actuation — a ram, a
/// valve, a diverter — and this side cannot know whether the first one landed.
/// Re-sending is a second actuation, so it is a decision for a human looking
/// at the machine. `taxonomy_test.dart` enforces that over the whole of `lib/`
/// as a CI-run case, not a one-off grep.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'deadline.dart';

/// The greppable `WriteReason.kind` values this seam produces.
///
/// Distinct kinds for distinct things to go and look at: `link_lost` is the
/// network, `deadline_expired` is a gateway or PLC that took longer than it
/// was given, `link_down` is this panel with no socket at all.
abstract final class FailureKind {
  /// The transport went away with the request already on it.
  static const String linkLost = 'link_lost';

  /// The deadline fired before any answer arrived.
  static const String deadlineExpired = 'deadline_expired';

  /// There was no connection to send the call down in the first place.
  static const String linkDown = 'link_down';

  /// The gateway answered with a JSON-RPC error.
  static const String serverRefused = 'server_refused';

  /// Something arrived but could not be made sense of.
  static const String undecodableAnswer = 'undecodable_answer';
}

/// What a failed call turned out to be. Two shapes, because there are two
/// verdicts and conflating them is the defect this file prevents.
sealed class CallFailure {
  const CallFailure();
}

/// The link, or our knowledge of it, went away. The request's fate is not
/// established — which for a write is `WriteUnknown` and nothing else.
final class LinkLoss extends CallFailure {
  /// The `WriteReason.kind` this maps to; see [FailureKind].
  final String kind;

  /// What was observed, for the log line and for the operator's screen.
  final String detail;

  const LinkLoss(this.kind, this.detail);
}

/// The gateway answered, and the answer was "no". A JSON-RPC error on a write
/// means definitively no effect (STATE.md Phase 1 handoff), which makes it the
/// only retry-safe outcome there is — and even then, re-sending is the
/// operator's decision.
final class ServerRefusal extends CallFailure {
  /// The JSON-RPC error code, kept because a code survives translation and
  /// truncation of the message.
  final int code;

  /// The server's own words.
  final String message;

  /// Whatever the server attached; carried, not interpreted.
  final Object? data;

  const ServerRefusal(this.code, this.message, {this.data});
}

/// True for the two message shapes `json_rpc_2` uses when the link is what
/// failed — and, deliberately, for nothing else.
///
/// The exact texts are `Client.withoutJson`'s close handler
/// (`client.dart:79-80`) and `Client._send`'s guard (`client.dart:163`).
/// Widening this predicate is how every programming error in the client starts
/// being reported to an operator as a plant condition, so it matches the
/// library's literals and stops.
bool isLinkLossMessage(String message) =>
    message.contains('The client closed with pending request') ||
    message.contains('The client is closed');

/// The gateway does not know the word `ackAlarm` at all.
///
/// **The one place this phase's additive wire change is observable.** A name
/// added to the protocol is invisible to an old client — it never calls it —
/// and visible to a new client against an old gateway only as `json_rpc_2`'s
/// fallback `-32601`. Every other way a gateway can decline an acknowledge is
/// an ordinary [RpcException] and stays one, including 14-12's named "this
/// gateway serves no alarm engine" refusal, which shares [handlerFailed]
/// (`-32011`) with a *failing* engine because a panel can do nothing different
/// about either.
///
/// **So the distinction is a type and not a code.** Two answers a widget has to
/// tell apart by switching on an integer are two answers somebody eventually
/// gets the wrong way round. The sentences they produce ask an operator for
/// different actions:
///
/// | Answer | What it means | Who fixes it |
/// |---|---|---|
/// | [AlarmAckUnsupported] | this gateway predates alarm acknowledge | whoever upgrades the gateway |
/// | `-32011`, no engine | this gateway was composed without an `AlarmAckSink` | whoever wires `RelayServer(alarmAcks:)` |
/// | `-32005`, forbidden | this station has no operate role | whoever holds the token file |
///
/// Reading the first as the third sends a fitter hunting a permission that is
/// not missing, which is the spoofing threat T-14-55 names.
///
/// **Extends [RpcException] rather than replacing it**, carrying the gateway's
/// own code and words through unaltered. A caller that only knows about
/// `RpcException` — every generic error surface in the app — keeps working and
/// shows the gateway's sentence; a caller that has something better to say
/// catches this type first. Narrowing an answer must never cost a caller the
/// answer it already handled.
final class AlarmAckUnsupported extends RpcException {
  AlarmAckUnsupported(this.method, String message, {Object? data})
      : super(methodNotFound, message, data: data);

  /// `json_rpc_2`'s `METHOD_NOT_FOUND`, named here so this file does not import
  /// `error_code.dart` for one integer the wire has already fixed.
  static const int methodNotFound = -32601;

  /// The method the gateway did not recognise. Carried because a panel logging
  /// "unsupported" without saying *what* is unsupported has told nobody
  /// anything.
  final String method;

  @override
  String toString() =>
      'AlarmAckUnsupported: this gateway does not know "$method" — it predates '
      'alarm acknowledge and has to be upgraded. Nothing was acknowledged, and '
      'no permission is missing. The gateway said: $message';
}

/// The gateway does not know the word `alarmHistory` at all.
///
/// [AlarmAckUnsupported]'s sibling, for its reason and one that binds harder.
/// The acknowledge's three answers ask an operator for three different actions;
/// alarm history's ask for **four**, and the fourth is the one this type exists
/// to keep out of the other three:
///
/// | Answer | What it means | Who fixes it |
/// |---|---|---|
/// | [AlarmHistoryUnsupported] | this gateway predates alarm history | whoever upgrades the gateway |
/// | `-32011`, no source | this gateway was composed without an `AlarmHistorySource` | whoever wires `RelayServer(alarmHistory:)` |
/// | `-32602`, not served | this station may not see `ALARM.active` | whoever holds the access policy |
/// | an empty list | **this plant has had no alarms in that window** | nobody — it is a fact |
///
/// The last row is the whole point. A gateway-mode panel was answering it for
/// all four cases, silently, because `getRecentAlarms` read a database that
/// gateway mode no longer builds. Every other row on this table has to stay
/// distinguishable from it and from each other, or the panel is back to
/// reporting a fact about the wire as a fact about the factory.
///
/// **Extends [RpcException]**, carrying the gateway's own code and words
/// through unaltered, for [AlarmAckUnsupported]'s reason: narrowing an answer
/// must never cost a caller the answer it already handled.
final class AlarmHistoryUnsupported extends RpcException {
  AlarmHistoryUnsupported(this.method, String message, {Object? data})
      : super(AlarmAckUnsupported.methodNotFound, message, data: data);

  /// The method the gateway did not recognise. Carried because "unsupported"
  /// without saying *what* has told nobody anything.
  final String method;

  @override
  String toString() =>
      'AlarmHistoryUnsupported: this gateway does not know "$method" — it '
      'predates alarm history over the pipe and has to be upgraded. This is '
      'NOT a plant with no alarm history, and nothing about the plant was '
      'learned. The gateway said: $message';
}

/// Sorts a thrown [error] into the two verdicts.
///
/// Rethrows anything that is a defect in this process rather than a condition
/// of the plant: an unrecognised `StateError`, and every other `Error`
/// subtype. A crash report is worth more than a soothing "unknown", and an
/// invisible bug that reports itself as a lost link is the worst outcome
/// available.
///
/// Everything else that can arrive off a wire — [TimeoutException],
/// [LinkDown], `FormatException` from half an answer, a socket error — is
/// [LinkLoss], because none of them establishes what the machinery did.
CallFailure classifyFailure(Object error) {
  if (error is RpcException) {
    return ServerRefusal(error.code, error.message, data: error.data);
  }
  if (error is TimeoutException) {
    return const LinkLoss(
        FailureKind.deadlineExpired, 'no answer before the deadline');
  }
  if (error is LinkDown) {
    return LinkLoss(FailureKind.linkDown, error.toString());
  }
  if (error is StateError) {
    // The one string match in the client, isolated here on purpose.
    if (isLinkLossMessage(error.message)) {
      return LinkLoss(FailureKind.linkLost, error.message);
    }
    throw error;
  }
  if (error is Error) {
    // TypeError, ArgumentError, NoSuchMethodError: ours, not the plant's.
    throw error;
  }
  return LinkLoss(FailureKind.undecodableAnswer, error.toString());
}

/// The write verdict for a call that failed, for the command id [cmd].
///
/// Total over everything [classifyFailure] classifies: link loss and deadline
/// expiry become [WriteUnknown], a refusal becomes [WriteRejected], and there
/// is no arm that turns ignorance into a refusal. What it does not swallow is
/// a defect in this process — those still escape, by design, and
/// `taxonomy_test.dart` has a named case proving it.
WriteResult writeOutcomeFor(String cmd, Object error) =>
    switch (classifyFailure(error)) {
      LinkLoss(:final kind, :final detail) =>
        WriteUnknown(cmd, WriteReason(kind, message: detail)),
      ServerRefusal(:final code, :final message) => WriteRejected(
          cmd,
          WriteReason(FailureKind.serverRefused,
              message: message, status: 'jsonrpc:$code'),
        ),
    };
