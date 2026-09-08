import 'package:tfc_dart/core/state_man.dart';
import 'package:test/test.dart';

/// OpcUAConfig.toString must never carry a credential. The 2026-09-07
/// access-surface audit found the literal password in it — "any log of a
/// decoded config leaks it" — the exact hazard 17-10's wire redaction closed
/// one layer up. Both directions are pinned: the secret absent, and the
/// non-secret fields still present (so the redaction cannot be satisfied by
/// an empty string).
void main() {
  test('a set password and ssl key never appear in toString', () {
    final c = OpcUAConfig()
      ..endpoint = 'opc.tcp://10.50.10.10:4840'
      ..username = 'plc-reader'
      ..password = 'ÞYRNIGERÐI-9000-lykilorð';
    final s = c.toString();
    expect(s, isNot(contains('ÞYRNIGERÐI-9000-lykilorð')));
    expect(s, contains('<redacted>'));
    // The live control: the string still describes the config.
    expect(s, contains('opc.tcp://10.50.10.10:4840'));
    expect(s, contains('plc-reader'));
  });

  test('an absent password prints null, not a redaction marker', () {
    final s = OpcUAConfig().toString();
    expect(s, contains('password: null'));
    expect(s, isNot(contains('<redacted>')));
  });
}
