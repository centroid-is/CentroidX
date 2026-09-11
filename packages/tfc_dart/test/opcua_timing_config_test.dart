import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The two timing knobs on [OpcUAConfig]: how fast the server publishes to
/// us, and how long the SecureChannel is asked to live. Both used to be
/// hardcoded — the publishing interval as open62541's 100 ms default, the
/// lifetime as a bare `Duration(minutes: 1)` in `OpcUaStateMan.create` left over
/// from reproducing the frozen-session bug.
void main() {
  group('OpcUAConfig timing defaults', () {
    test('a fresh config publishes at 100 ms and renews every 10 minutes', () {
      final config = OpcUAConfig();
      // The interval keeps the value that was already in force. The lifetime
      // deliberately does not: 60 s was bench scaffolding, and the default
      // is open62541's own.
      expect(config.publishingIntervalMs, 100);
      expect(config.secureChannelLifetimeMs, 600000);
    });

    test('the Duration getters convert from the stored milliseconds', () {
      final config = OpcUAConfig()
        ..publishingIntervalMs = 250
        ..secureChannelLifetimeMs = 300000;

      expect(config.publishingInterval, const Duration(milliseconds: 250));
      expect(config.secureChannelLifetime, const Duration(minutes: 5));
    });

    test('the publishing interval stays under the heartbeat stale window', () {
      // The heartbeat rides the same subscription as every data key, so a
      // maximum at or above [ClientWrapper.heartbeatStaleAfter] would let a
      // healthy server report itself unhealthy.
      expect(
        Duration(milliseconds: OpcUAConfig.publishingIntervalMaxMs),
        lessThan(ClientWrapper.heartbeatStaleAfter),
      );
    });
  });

  group('OpcUAConfig timing serialization', () {
    test('serializes under snake_case keys', () {
      final json = (OpcUAConfig()
            ..publishingIntervalMs = 500
            ..secureChannelLifetimeMs = 120000)
          .toJson();

      expect(json, containsPair('publishing_interval_ms', 500));
      expect(json, containsPair('secure_channel_lifetime_ms', 120000));
    });

    test('round-trips both values', () {
      final restored = OpcUAConfig.fromJson((OpcUAConfig()
            ..endpoint = 'opc.tcp://10.0.0.1:4840'
            ..publishingIntervalMs = 1000
            ..secureChannelLifetimeMs = 3600000)
          .toJson());

      expect(restored.endpoint, 'opc.tcp://10.0.0.1:4840');
      expect(restored.publishingIntervalMs, 1000);
      expect(restored.secureChannelLifetimeMs, 3600000);
    });

    test('a config saved before these fields existed still loads', () {
      // Every station in the field has a stored config shaped like this. It
      // must come back with sane values, not zeroes — a 0 ms publishing
      // interval would ask the PLC to publish as fast as it can answer.
      final legacy = <String, dynamic>{
        'endpoint': 'opc.tcp://10.104.28.11:4840',
        'server_alias': 'st101',
        'enabled': true,
      };

      final restored = OpcUAConfig.fromJson(legacy);
      expect(restored.publishingIntervalMs, 100);
      // Note this is a behaviour CHANGE for the stations, and an intended
      // one: they have been renewing every 45 s off the old hardcoded 60 s,
      // and loading this config moves them to open62541's 10 minutes.
      expect(restored.secureChannelLifetimeMs, 600000);
    });

    test('the values survive a StateManConfig round-trip', () {
      final config = StateManConfig(opcua: [
        OpcUAConfig()
          ..serverAlias = 'st201'
          ..publishingIntervalMs = 750
          ..secureChannelLifetimeMs = 900000,
      ]);

      final restored = StateManConfig.fromJson(config.toJson());
      expect(restored.opcua.single.publishingIntervalMs, 750);
      expect(restored.opcua.single.secureChannelLifetimeMs, 900000);
    });

    test('toString reports both, so a boot log says what the server got', () {
      final text = (OpcUAConfig()
            ..publishingIntervalMs = 200
            ..secureChannelLifetimeMs = 30000)
          .toString();

      expect(text, contains('publishingIntervalMs: 200'));
      expect(text, contains('secureChannelLifetimeMs: 30000'));
    });
  });
}
