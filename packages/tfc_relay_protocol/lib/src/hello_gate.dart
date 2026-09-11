/// Hello gating + version negotiation — relay-comm-design.md §4.1.
/// Pre-hello requests are rejected without closing (Home Assistant's
/// pre-auth rule); a failed negotiation closes with a named code and both
/// sides' version lists (MCP's rule). Pure state machine, no I/O.
library;

import 'messages.dart';
import 'methods.dart';

sealed class GateAction {
  const GateAction();
}

/// Proceed with the request.
final class GateAllow extends GateAction {
  const GateAllow();
}

/// Reject this request with a JSON-RPC error; the connection stays open.
final class GateReject extends GateAction {
  /// `hello_required` | `already_helloed`
  final String kind;
  const GateReject(this.kind);
}

/// Negotiation succeeded; [protocol] is the version both sides now speak.
final class GateAccept extends GateAction {
  final String protocol;
  const GateAccept(this.protocol);
}

/// Close the connection (protocol mismatch). Carries both version lists so
/// the client can log something actionable.
final class GateClose extends GateAction {
  final int closeCode;
  final List<String> supported;
  final List<String> requested;
  const GateClose(this.closeCode,
      {required this.supported, required this.requested});
}

/// The gate already closed the connection; nothing is processed anymore.
final class GateClosed extends GateAction {
  const GateClosed();
}

enum _GateState { awaitingHello, ready, closed }

final class HelloGate {
  /// Newest first; the negotiated version is the first mutual entry.
  final List<String> serverSupported;

  _GateState _state = _GateState.awaitingHello;

  HelloGate({this.serverSupported = const [protocolVersion]});

  /// Gate an incoming request by method name, before dispatch.
  GateAction checkRequest(String method) => switch (_state) {
        _GateState.closed => const GateClosed(),
        _GateState.ready => const GateAllow(),
        _GateState.awaitingHello => method == Methods.hello
            ? const GateAllow()
            : const GateReject('hello_required'),
      };

  /// Process a `hello`. On [GateClose] the caller must close the socket
  /// with the given code.
  GateAction negotiate(HelloParams params) {
    switch (_state) {
      case _GateState.closed:
        return const GateClosed();
      case _GateState.ready:
        return const GateReject('already_helloed');
      case _GateState.awaitingHello:
        final requested = params.supported.isEmpty
            ? [params.protocol]
            : params.supported;
        for (final version in serverSupported) {
          if (requested.contains(version)) {
            _state = _GateState.ready;
            return GateAccept(version);
          }
        }
        _state = _GateState.closed;
        return GateClose(CloseCodes.protocolMismatch,
            supported: serverSupported, requested: requested);
    }
  }
}
