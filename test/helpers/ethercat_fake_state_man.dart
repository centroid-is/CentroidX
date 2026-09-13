/// A StateMan for EtherCAT widget tests: arrays pushed by key, writes
/// recorded, key mappings supplied.
library;

import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Mappings shaped like a station's `ECT_Diag`: one master, its diag and
/// info arrays under the keys `ect1.diag` and `ect1.info`.
KeyMappings ecDevice1Mappings() => KeyMappings(nodes: {
      'ect1.diag': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(
              namespace: 4, identifier: 'ECT_Diag.Device_1_Diag')),
      'ect1.info': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(
              namespace: 4, identifier: 'ECT_Diag.Device_1_SlaveInfo')),
    });

class EcFakeStateMan implements StateMan {
  EcFakeStateMan({KeyMappings? mappings})
      : _mappings = mappings ?? KeyMappings(nodes: {});

  final KeyMappings _mappings;
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<({String key, DynamicValue value})> writes = [];

  void push(String key, DynamicValue value) =>
      _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).add(value);

  @override
  KeyMappings get keyMappings => _mappings;

  @override
  String resolveKey(String key) => key;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).stream;

  @override
  Future<DynamicValue> read(String key) async {
    final s = _streams[key];
    if (s == null || !s.hasValue) throw StateError('No value for $key');
    return s.value;
  }

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add((key: key, value: value));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'EcFakeStateMan: ${invocation.memberName} not implemented');
}
