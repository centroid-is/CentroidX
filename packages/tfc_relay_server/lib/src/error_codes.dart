/// The gateway's own JSON-RPC error codes, and what a client should do about
/// each one.
///
/// All of them sit in −32000..−32099, the range JSON-RPC 2.0 reserves for
/// implementation-defined server errors; the envelope's own codes (−32700
/// parse error, −32600 invalid request, −32601 method not found, −32602
/// invalid params, −32603 internal error) are `json_rpc_2`'s to send and never
/// appear here.
///
/// Spelled in `CloseCodes`' style (`methods.dart:34-40`): one flat
/// `abstract final class` of constants, because a code that a client switches
/// on is data, and an enum would not survive the wire without a mapping table
/// nobody would keep current.
///
/// A code exists so the client can *behave differently*. Two failures that
/// call for the same client behaviour share a code; a failure with no distinct
/// response deserves no constant of its own.
///
/// ## What the write path's codes inherit, and why [ServerErrorCodes.forbidden]
/// fits without an exception
///
/// On `write`, a JSON-RPC error means one specific thing —
/// `write_result.dart:6-8` — **definitively no effect, safe to re-send**. It
/// is not a third outcome beside applied/rejected/unknown; it is the statement
/// that the operator's action never left the gateway. Every refusal on that
/// ladder is therefore raised before the plant is touched: the non-finite
/// guard, the shape checks, the unserved-tag refusal (06-04), the idempotency
/// window's mismatch, the second-engage refusal.
///
/// [ServerErrorCodes.forbidden] joins that ladder and inherits the promise
/// intact, which is the pleasing part: an unauthorized write is refused above
/// `api.write`, above the in-flight `_record` and above the idempotency
/// window, so nothing was sent to a machine and nothing was written into the
/// outcome log. A later `writeStatus` about that command therefore answers
/// `not_received` — the one re-send-safe verdict — rather than `unknown`, and
/// it is *entitled* to, because the action provably never happened. A gate
/// placed a few lines lower would still refuse and would still look correct,
/// and the only visible symptom would be a reconnecting panel told "unknown"
/// about a setpoint that never moved, which is the answer that makes an
/// operator press the button a second time.
library;

abstract final class ServerErrorCodes {
  /// The session has not said `hello` yet. Say it, then re-send. The
  /// connection is still open — this is a correction, not an eviction.
  static const helloRequired = -32001;

  /// A `hello` arrived on a session that already negotiated. Keep using the
  /// session you have; a client sending this twice has a state bug, and
  /// re-negotiating in place would silently reset an epoch its subscriptions
  /// depend on.
  static const alreadyHelloed = -32002;

  /// The credential presented with `hello` was refused. Re-authenticate before
  /// reconnecting; reconnecting with the same token will be refused again, so
  /// a backoff loop around it is a busy loop.
  static const unauthorized = -32003;

  /// No protocol version in common. The error data carries both lists —
  /// upgrade or downgrade to one of `supported`; retrying unchanged cannot
  /// succeed. The session is also closed with
  /// `CloseCodes.protocolMismatch`.
  ///
  /// Not in the plan's original six. Added because the alternative was to
  /// answer a version mismatch with a code meaning something else, and a
  /// client that cannot tell "wrong version" from "wrong credential" retries
  /// the one case that can never succeed.
  static const versionMismatch = -32004;

  /// The identity may **see** this tag but may not actuate it.
  ///
  /// Do not retry: the session is fine, reading continues, and nothing about
  /// this request will get a different answer next time. What is missing is a
  /// permission the station does not have — a `view` panel asked to write —
  /// and obtaining it is an edit to the gateway's token file, not something a
  /// client can wait out. Kept distinct from the envelope's −32602 for exactly
  /// the reason at the top of this file: a client behaves differently. −32602
  /// on this path says "the request was malformed, fix the call"; there is
  /// nothing wrong with this call.
  ///
  /// **Never sent for a tag the identity may not see.** That case is
  /// `INVALID_PARAMS` plus `KeyReject(unknownKey)` — byte-identical to a tag
  /// that does not exist — because answering "forbidden" would tell the asker
  /// the tag is real, which is the enumeration the hiding rule exists to
  /// prevent (06-CONTEXT decision 2, T-06-37). The two refusals are two
  /// different facts and the client acts on them differently: fix the tag
  /// name, versus obtain the permission.
  static const forbidden = -32005;

  /// The request's params were the wrong shape for the method. A client bug,
  /// deterministic: fix the call, do not retry it. Kept distinct from the
  /// envelope's −32602 because it is raised by the *typed decode* inside a
  /// handler, which is where a `String` field arriving as a number lands.
  static const typeMismatch = -32010;

  /// The handler failed while serving a request that was well formed. Not the
  /// client's fault and possibly transient: retrying is legitimate, with
  /// backoff. Nothing about the request was applied unless the method's own
  /// documentation says otherwise — and for `write`, "unknown" is a distinct
  /// outcome carried in the result, never an error.
  static const handlerFailed = -32011;

  /// The named subscription does not exist on this session. Stop sending for
  /// it and resubscribe if it is still wanted; the server has no record to
  /// remove. Usually the tail of a resync the client did not finish applying.
  static const unknownSubscription = -32020;
}
