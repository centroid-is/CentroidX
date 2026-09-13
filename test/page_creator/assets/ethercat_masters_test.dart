import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_masters.dart';
import 'package:tfc_dart/core/state_man.dart';

KeyMappingEntry _node(String id, {String alias = 'st101', int? index}) =>
    KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 4, identifier: id)
        ..serverAlias = alias
        ..arrayIndex = index,
    );

void main() {
  test('groups the generated arrays by master, in master order', () {
    final masters = discoverEcMasters(KeyMappings(nodes: {
      'ect2.info': _node('ECT_Diag.Device_2_SlaveInfo'),
      'ect1.diag': _node('ECT_Diag.Device_1_Diag'),
      'ect2.diag': _node('ECT_Diag.Device_2_Diag'),
      'ect1.info': _node('ECT_Diag.Device_1_SlaveInfo'),
      'ect1.count': _node('ECT_Diag.Device_1_SlaveCount'),
      'CVS01.CN01.FD01': _node('ECT.CVS01_CN01_FD01.HMI'),
    }));
    expect([for (final m in masters) m.label], ['Device 1', 'Device 2']);
    expect(masters[0].diagKey, 'ect1.diag');
    expect(masters[0].infoKey, 'ect1.info');
    expect(masters[0].countKey, 'ect1.count');
    expect(masters[1].infoKey, 'ect2.info');
    expect(masters[1].countKey, isNull);
  });

  test('matches the identifier, so the key can be called anything', () {
    final masters = discoverEcMasters(KeyMappings(nodes: {
      'Line 1 bus diagnostics': _node('ECT_Diag.Device_3_Diag'),
    }));
    expect(masters.single.label, 'Device 3');
    expect(masters.single.diagKey, 'Line 1 bus diagnostics');
  });

  test('a master without its diag array is not listed', () {
    expect(
      discoverEcMasters(KeyMappings(nodes: {
        'i': _node('ECT_Diag.Device_1_SlaveInfo'),
      })),
      isEmpty,
    );
  });

  test('a single-element mapping is not a master', () {
    expect(
      discoverEcMasters(KeyMappings(nodes: {
        'one': _node('ECT_Diag.Device_1_Diag', index: 16),
      })),
      isEmpty,
    );
  });

  test('two stations both have a Device 1, so the alias is prefixed', () {
    final masters = discoverEcMasters(KeyMappings(nodes: {
      'a': _node('ECT_Diag.Device_1_Diag', alias: 'st201'),
      'b': _node('ECT_Diag.Device_1_Diag', alias: 'st101'),
    }));
    expect([for (final m in masters) m.label],
        ['st101 · Device 1', 'st201 · Device 1']);
  });
}
