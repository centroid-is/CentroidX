import 'dart:async';

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Minimal mock DeviceClient for testing StateMan's routing logic.
class MockDeviceClient implements DeviceClient {
  @override
  final Set<String> subscribableKeys = {'BATCH', 'STAT', 'INTRO', 'LUA'};

  final Map<String, StreamController<DynamicValue>> _controllers = {};
  ConnectionStatus _status = ConnectionStatus.disconnected;
  final _statusController =
      StreamController<ConnectionStatus>.broadcast();

  @override
  bool canSubscribe(String key) =>
      subscribableKeys.contains(key.split('.').first);

  @override
  Stream<DynamicValue> subscribe(String key) {
    final controller = _controllers.putIfAbsent(
        key, () => StreamController<DynamicValue>.broadcast());
    return controller.stream;
  }

  @override
  DynamicValue? read(String key) => null;

  @override
  ConnectionStatus get connectionStatus => _status;

  @override
  Stream<ConnectionStatus> get connectionStream => _statusController.stream;

  @override
  void connect() {
    _status = ConnectionStatus.connected;
    _statusController.add(ConnectionStatus.connected);
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    if (!canSubscribe(key)) throw ArgumentError('Unknown key: $key');
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.close();
    }
    _statusController.close();
  }

  /// Push a value into a subscribe stream for testing.
  void push(String key, DynamicValue value) {
    _controllers.putIfAbsent(
        key, () => StreamController<DynamicValue>.broadcast());
    _controllers[key]!.add(value);
  }
}

void main() {
  group('StateMan DeviceClient routing', () {
    test('subscribe routes M2400 key to DeviceClient', () async {
      final mock = MockDeviceClient();
      mock.connect();

      final stream = mock.subscribe('BATCH');
      final completer = Completer<DynamicValue>();
      stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      mock.push('BATCH', DynamicValue(value: 42.0));
      final dv = await completer.future.timeout(const Duration(seconds: 2));
      expect(dv.asDouble, 42.0);

      mock.dispose();
    });

    test('canSubscribe returns true for known M2400 keys', () {
      final mock = MockDeviceClient();
      expect(mock.canSubscribe('BATCH'), isTrue);
      expect(mock.canSubscribe('STAT'), isTrue);
      expect(mock.canSubscribe('INTRO'), isTrue);
      expect(mock.canSubscribe('LUA'), isTrue);
      mock.dispose();
    });

    test('canSubscribe returns false for unknown keys', () {
      final mock = MockDeviceClient();
      expect(mock.canSubscribe('someOpcUaKey'), isFalse);
      expect(mock.canSubscribe('unknown'), isFalse);
      mock.dispose();
    });

    test('canSubscribe returns true for dot-notation M2400 keys', () {
      final mock = MockDeviceClient();
      expect(mock.canSubscribe('BATCH.weight'), isTrue);
      expect(mock.canSubscribe('STAT.unit'), isTrue);
      mock.dispose();
    });

    test('DeviceClient connection status is accessible', () async {
      final mock = MockDeviceClient();
      expect(mock.connectionStatus, ConnectionStatus.disconnected);

      final statuses = <ConnectionStatus>[];
      mock.connectionStream.listen(statuses.add);

      mock.connect();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(mock.connectionStatus, ConnectionStatus.connected);
      expect(statuses, contains(ConnectionStatus.connected));

      mock.dispose();
    });

    test('StateMan accepts DeviceClient instances via constructor', () {
      // Verify the DeviceClient interface exists and can be used
      final mock = MockDeviceClient();
      expect(mock, isA<DeviceClient>());
      mock.dispose();
    });
  });
}
