import 'package:open62541/open62541.dart' show NodeId;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

KeyMappingEntry _opcua(String id, {int ns = 4, String? alias, int? index}) =>
    KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: ns, identifier: id)
        ..serverAlias = alias
        ..arrayIndex = index,
    );

void main() {
  final mappings = KeyMappings(nodes: {
    'ect1.diag': _opcua('ECT_Diag.Device_1_Diag', alias: 'st101'),
    'ect1.diag[3]': _opcua('Somewhere.Else', alias: 'st201'),
    'SPB01.CN01': _opcua('ECT.SPB01_CN01.HMI', alias: 'st101'),
    'numeric': _opcua('4711', alias: 'st101'),
    'one.element': _opcua('ECT_Diag.Device_1_Diag', alias: 'st101', index: 4),
  });

  group('derived keys', () {
    test('an element and a member of a mapped array', () {
      expect(mappings.lookupNodeId('ect1.diag[17]'),
          (NodeId.fromString(4, 'ECT_Diag.Device_1_Diag[17]'), null));
      expect(mappings.lookupNodeId('ect1.diag[17].p_cmd_resetCrcCounter'), (
        NodeId.fromString(4, 'ECT_Diag.Device_1_Diag[17].p_cmd_resetCrcCounter'),
        null,
      ));
    });

    test('nested indices and members', () {
      expect(mappings.lookupNodeId('ect1.diag[17].p_stat_aCrcPort[2]'), (
        NodeId.fromString(4, 'ECT_Diag.Device_1_Diag[17].p_stat_aCrcPort[2]'),
        null,
      ));
    });

    test('inherits the server alias of the mapped key', () {
      expect(mappings.lookupServerAlias('ect1.diag[9].p_stat_bOk'), 'st101');
    });

    test('a key that is mapped outright is never derived', () {
      expect(mappings.lookupNodeId('ect1.diag[3]'),
          (NodeId.fromString(4, 'Somewhere.Else'), null));
      expect(mappings.lookupServerAlias('ect1.diag[3]'), 'st201');
    });

    test('the longest mapped prefix wins', () {
      expect(mappings.lookupNodeId('ect1.diag[3][1]'),
          (NodeId.fromString(4, 'Somewhere.Else[1]'), null));
    });

    test('a misspelt dotted key stays unmapped', () {
      // The suffix must start with an element index. Without that, every
      // typo under a mapped prefix would silently become a child read.
      expect(mappings.lookupNodeId('SPB01.CN01.FD01'), isNull);
      expect(mappings.lookupServerAlias('SPB01.CN01.FD01'), isNull);
    });

    test('garbage after the index stays unmapped', () {
      expect(mappings.lookupNodeId('ect1.diag[17]-x'), isNull);
      expect(mappings.lookupNodeId('ect1.diag[x]'), isNull);
    });

    test('no child of a numeric node id or of a single-element mapping', () {
      expect(mappings.lookupNodeId('numeric[1]'), isNull);
      expect(mappings.lookupNodeId('one.element[1]'), isNull);
    });

    test('an unknown key is still unknown', () {
      expect(mappings.lookupNodeId('nothing[1]'), isNull);
      expect(mappings.lookupNodeId('[1]'), isNull);
    });
  });
}
