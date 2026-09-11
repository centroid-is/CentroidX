import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/registry.dart';

/// An asset that refers to two others, standing in for the cable until it
/// lands. Nothing else in the tree holds another asset's id yet, and the paste
/// remap is not worth trusting on an implementation with no callers.
class _RefAsset extends BaseAsset {
  _RefAsset(this.fromId, this.toId);

  String? fromId;
  String? toId;

  @override
  Widget build(context) => throw UnimplementedError();
  @override
  Widget configure(context) => throw UnimplementedError();
  @override
  Map<String, dynamic> toJson() => {'from': fromId, 'to': toId};

  @override
  void remapAssetIds(Map<String, String> idMap) {
    fromId = idMap[fromId] ?? fromId;
    toId = idMap[toId] ?? toId;
  }
}

void main() {
  group('asset ids', () {
    test('an asset starts with no id', () {
      // The whole point of minting lazily: a page nothing links across never
      // grows the field.
      expect(LEDConfig(key: 'a').id, isNull);
    });

    test('ensureId mints one and then keeps returning it', () {
      final led = LEDConfig(key: 'a');
      final first = led.ensureId();
      expect(first, isNotEmpty);
      expect(led.ensureId(), first);
      expect(led.id, first);
    });

    test('assignNewId replaces the id it had', () {
      final led = LEDConfig(key: 'a');
      final first = led.ensureId();
      final second = led.assignNewId();
      expect(second, isNot(first));
      expect(led.id, second);
    });

    test('ids do not collide across a page full of assets', () {
      final ids = {
        for (var i = 0; i < 5000; i++) LEDConfig(key: 'a').ensureId()
      };
      expect(ids, hasLength(5000));
    });

    test('remapAssetIds does nothing on an asset that refers to nothing', () {
      final led = LEDConfig(key: 'a');
      final id = led.ensureId();
      led.remapAssetIds({id: 'something-else'});
      // Its *own* id is not a reference and must not be rewritten by a remap.
      expect(led.id, id);
    });
  });

  group('serialization', () {
    test('an asset with no id serialises without the key at all', () {
      // This is what keeps the change additive. A page saved before ids
      // existed has to round-trip byte for byte.
      expect(LEDConfig(key: 'a').toJson().containsKey('id'), isFalse);
    });

    test('an id round-trips through JSON', () {
      final led = LEDConfig(key: 'a');
      led.variant = 'LEDConfig';
      final id = led.ensureId();
      expect(LEDConfig.fromJson(led.toJson()).id, id);
    });

    test('JSON written before ids existed still parses', () {
      final led = LEDConfig(key: 'a');
      led.variant = 'LEDConfig';
      final json = led.toJson()..remove('id');
      expect(LEDConfig.fromJson(json).id, isNull);
    });

    test('the id survives the registry, which is what a page load uses', () {
      final led = LEDConfig(key: 'a');
      led.variant = 'LEDConfig';
      final id = led.ensureId();
      final parsed = AssetRegistry.parse({
        'assets': [led.toJson()]
      });
      expect(parsed.single.id, id);
    });
  });

  group('paste re-identification', () {
    test('a pasted copy does not keep the original id', () {
      final original = LEDConfig(key: 'a');
      final id = original.ensureId();
      final copy = LEDConfig(key: 'a')..id = id;

      reidentifyAssets([copy]);
      expect(copy.id, isNotNull);
      expect(copy.id, isNot(id));
    });

    test('an asset pasted without an id is left without one', () {
      final copy = LEDConfig(key: 'a');
      reidentifyAssets([copy]);
      expect(copy.id, isNull);
    });

    test('references inside the pasted group follow the copies', () {
      // Duplicate a coupler, a box and the cable between them: the second
      // cable has to run between the second pair.
      final couplerCopy = LEDConfig(key: 'ek')..id = 'old-coupler';
      final boxCopy = LEDConfig(key: 'ep')..id = 'old-box';
      final cableCopy = _RefAsset('old-coupler', 'old-box');

      reidentifyAssets([couplerCopy, boxCopy, cableCopy]);

      expect(couplerCopy.id, isNot('old-coupler'));
      expect(boxCopy.id, isNot('old-box'));
      expect(cableCopy.fromId, couplerCopy.id);
      expect(cableCopy.toId, boxCopy.id);
    });

    test(
        'references out of the pasted group are left pointing at the originals',
        () {
      // A cable copied on its own still runs where it ran.
      final cableCopy = _RefAsset('coupler-on-the-page', 'box-on-the-page');
      reidentifyAssets([cableCopy]);
      expect(cableCopy.fromId, 'coupler-on-the-page');
      expect(cableCopy.toId, 'box-on-the-page');
    });

    test('a group with one copied end remaps only that end', () {
      final boxCopy = LEDConfig(key: 'ep')..id = 'old-box';
      final cableCopy = _RefAsset('coupler-left-behind', 'old-box');

      reidentifyAssets([boxCopy, cableCopy]);

      expect(cableCopy.fromId, 'coupler-left-behind');
      expect(cableCopy.toId, boxCopy.id);
    });
  });

  group('every registered asset carries its id through JSON', () {
    // The one guard against a stale `.g.dart`. An asset whose generated code
    // predates the `id` field still compiles, still renders and still saves —
    // it just drops the id on the way out, so every cable plugged into it
    // unplugs itself on the next page load. `FestoVTUGConfig` was exactly
    // that on main. Testing one asset by hand does not catch the next one;
    // sweeping the palette does.
    for (final entry in AssetRegistry.defaultFactories.entries) {
      test('${entry.key}', () {
        final asset = entry.value();
        final id = asset.ensureId();

        final json = asset.toJson();
        expect(json['id'], id,
            reason: '${entry.key} does not write its id — regenerate '
                'its .g.dart with build_runner');

        final parsed = AssetRegistry.parse({
          'assets': [json]
        });
        expect(parsed, hasLength(1),
            reason: '${entry.key} did not survive AssetRegistry.parse');
        expect(parsed.single.id, id,
            reason: '${entry.key} does not read its id back — regenerate '
                'its .g.dart with build_runner');
      });
    }
  });

  group('copy through the clipboard JSON', () {
    test('a round trip through the copy format carries the id', () {
      // `_copyAssets` encodes exactly this shape; if the id did not survive
      // it, paste would have nothing to remap and cables would silently
      // unplug on every copy.
      final led = LEDConfig(key: 'a');
      led.variant = 'LEDConfig';
      final id = led.ensureId();
      final wire = jsonEncode({
        'assets': [led.toJson()]
      });
      final parsed = AssetRegistry.parse(jsonDecode(wire));
      expect(parsed.single.id, id);
    });
  });
}
