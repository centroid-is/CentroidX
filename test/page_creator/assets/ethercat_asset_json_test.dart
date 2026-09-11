import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_asset.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/schneider.dart';

/// Through JSON text and back, the way a page save and load does it.
Asset roundTrip(Asset a) {
  final parsed = AssetRegistry.parse(
      jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
  // `parse` skips an asset it cannot read rather than throwing, so a broken
  // round trip shows up as an empty list, not an exception.
  expect(parsed, hasLength(1), reason: '${a.runtimeType} did not parse back');
  return parsed.single;
}

void main() {
  final family = {
    for (final e in AssetRegistry.defaultFactories.entries)
      if (e.value() is EtherCatAsset) e.key: e.value,
  };

  test('the family is the subdevices, not the masters or the passive parts', () {
    final names = {for (final t in family.keys) t.toString()};
    expect(
        names,
        containsAll(<String>[
          'BeckhoffEK1100Config',
          'BeckhoffEK1110Config',
          'BeckhoffEL1008Config',
          'BeckhoffEL2008Config',
          'BeckhoffEL3054Config',
          'BeckhoffEL9222Config',
          'BeckhoffEL2912Config',
          'BeckhoffEL6070Config',
          'BeckhoffPS2001Config',
          'BeckhoffCU2508Config',
          'BeckhoffEPBoxConfig',
          'SchneiderATV320Config',
          'FestoVTUGConfig',
        ]));
    for (final notASlave in [
      'BeckhoffCX5010Config',
      'BeckhoffCX5340Config',
      'BeckhoffEL9186Config',
      'BeckhoffEL9187Config',
      'EtherCatLinkConfig',
      'EtherCatDeviceTableConfig',
    ]) {
      expect(names, isNot(contains(notASlave)));
    }
  });

  for (final entry in family.entries) {
    final type = entry.key;

    test('$type: unbound saves exactly as before', () {
      final a = entry.value() as EtherCatAsset;
      expect(a.toJson().containsKey('ecSubDevice'), isFalse);
      expect((roundTrip(a) as EtherCatAsset).ecSubDevice, isNull);
    });

    test('$type: a binding survives a save and load', () {
      final a = entry.value() as EtherCatAsset
        ..ecSubDevice = EcSubDeviceBinding(
          diagKey: 'ECT_Diag.Device_1_Diag',
          infoKey: 'ECT_Diag.Device_1_SlaveInfo',
          position: 17,
          name: 'CVS01.CN01.FD01',
        );
      final back = roundTrip(a) as EtherCatAsset;
      expect(back.runtimeType, type);
      expect(back.ecSubDevice!.diagKey, 'ECT_Diag.Device_1_Diag');
      expect(back.ecSubDevice!.infoKey, 'ECT_Diag.Device_1_SlaveInfo');
      expect(back.ecSubDevice!.position, 17);
      expect(back.ecSubDevice!.name, 'CVS01.CN01.FD01');
      expect(back.isEcBound, isTrue);
      expect(back.allKeys, containsAll(['ECT_Diag.Device_1_Diag',
          'ECT_Diag.Device_1_SlaveInfo']));
    });
  }

  test('a coupler and a drive saved before bindings existed are unchanged',
      () {
    // What a production page holds today: no ecSubDevice anywhere.
    for (final a in <Asset>[
      BeckhoffEK1100Config()
        ..nameOrId = 'ST107.A1.00'
        ..coordinates = Coordinates(x: 0.2, y: 0.3),
      SchneiderATV320Config(label: 'CVS01.\nCN01.FD01', hmisKey: 'CVS01.CN01.FD01.HMIS')
        ..coordinates = Coordinates(x: 0.4, y: 0.6),
    ]) {
      final before = jsonEncode(a.toJson());
      final after = jsonEncode(roundTrip(a).toJson());
      expect(after, before, reason: '${a.runtimeType} re-serialised differently');
      expect(before, isNot(contains('ecSubDevice')));
    }
  });
}
