/// Cases derived from Home Assistant's websocket_api test_auth.py
/// (test_pre_auth_only_auth_allowed, test_auth_sending_unknown_type_
/// disconnects) and MCP's version-negotiation rules, mapped onto the
/// hello gate from relay-comm-design.md §4.1.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  HelloParams hello({List<String> supported = const [protocolVersion]}) =>
      HelloParams(
        protocol: supported.first,
        supported: supported,
        client: const PeerInfo('test-client', '0.0.1'),
      );

  group('pre-hello gating (HA: pre-auth only auth allowed)', () {
    test('any request before hello is rejected but the connection survives',
        () {
      final gate = HelloGate();
      final action = gate.checkRequest(Methods.subscribe);
      final reject = action as GateReject;
      expect(reject.kind, 'hello_required');

      // The client can still recover by saying hello properly.
      expect(gate.negotiate(hello()), isA<GateAccept>());
      expect(gate.checkRequest(Methods.subscribe), isA<GateAllow>());
    });

    test('hello itself is always allowed first', () {
      expect(HelloGate().checkRequest(Methods.hello), isA<GateAllow>());
    });
  });

  group('version negotiation (MCP rules)', () {
    test('exact match is echoed back', () {
      final gate = HelloGate();
      final accept = gate.negotiate(hello()) as GateAccept;
      expect(accept.protocol, protocolVersion);
    });

    test('server picks a mutual version when the preferred one is unknown',
        () {
      final gate =
          HelloGate(serverSupported: const ['2027-01-01', protocolVersion]);
      final accept = gate
          .negotiate(hello(supported: ['1999-01-01', protocolVersion]))
          as GateAccept;
      expect(accept.protocol, protocolVersion);
    });

    test('no mutual version: close with protocolMismatch and name both sides',
        () {
      final gate = HelloGate();
      final close =
          gate.negotiate(hello(supported: ['1999-01-01'])) as GateClose;
      expect(close.closeCode, CloseCodes.protocolMismatch);
      expect(close.supported, [protocolVersion]);
      expect(close.requested, ['1999-01-01']);
      // After a failed negotiation everything is dead.
      expect(gate.checkRequest(Methods.subscribe), isA<GateClosed>());
    });

    test('a second hello after success is rejected, not renegotiated', () {
      final gate = HelloGate();
      gate.negotiate(hello());
      final reject = gate.negotiate(hello()) as GateReject;
      expect(reject.kind, 'already_helloed');
      // The session survives — rejecting is not closing.
      expect(gate.checkRequest(Methods.write), isA<GateAllow>());
    });
  });
}
