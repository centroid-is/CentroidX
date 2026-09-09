import 'dart:io';
import 'dart:collection' show LinkedHashMap;
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc/converter/color_converter.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/number.dart';
import 'package:tfc/page_creator/assets/ratio_number.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/page_creator/assets/third_party.dart';
import 'package:tfc/theme.dart' show HmiColorRole;
import 'package:tfc/page_creator/assets/third_party_painter.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart' show PaneStatus;

void main() {
  group('ThirdPartyEquipmentConfig defaults', () {
    test('preview is a usable, wide default', () {
      final config = ThirdPartyEquipmentConfig.preview();

      expect(config.kind, ThirdPartyEquipmentKind.multivac);
      expect(config.runKey, '');
      expect(config.invertRunPolarity, isFalse);
      expect(config.textPos, TextPos.below);
      // BaseAsset defaults to 3% x 3%, which would squash a plan view into an
      // unreadable stamp. The constructor must widen it.
      expect(config.size.width, greaterThan(0.05));
      expect(config.size.height, greaterThan(0.05));
    });

    test('stopped defaults to grey — red is reserved for faults', () {
      final config = ThirdPartyEquipmentConfig();
      // Roles, not literals: a literal is frozen at pick time and ignores a
      // later scheme switch, which is what left the running LED a saturated
      // Material green under the muted scheme.
      expect(config.stoppedColor, AssetColor.grey);
      expect(config.runningColor, AssetColor.green);
    });

    test('displayName and category place it in its own palette group', () {
      final config = ThirdPartyEquipmentConfig.preview();
      expect(config.displayName, '3rd Party Equipment');
      expect(config.category, 'Third Party');
    });
  });

  group('JSON round-trip', () {
    test('every field survives toJson -> fromJson', () {
      final original = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.strappingLine,
        runKey: 'ST301.PK01.STRAP01.Running',
        invertRunPolarity: true,
        runningColor: const AssetColor.literal(Colors.lime),
        stoppedColor: const AssetColor.literal(Colors.orange),
        outlineColor: const AssetColor.literal(Colors.indigo),
        strokeWidth: 3.5,
        tag: 'STRAP-01',
        showTag: true,
        notes: 'Afak SL-15-3, three StrapX heads.',
      )
        ..coordinates = Coordinates(x: 0.25, y: 0.5, angle: 90)
        ..size = const RelativeSize(width: 0.2, height: 0.14);

      final restored =
          ThirdPartyEquipmentConfig.fromJson(original.toJson());

      expect(restored.kind, ThirdPartyEquipmentKind.strappingLine);
      expect(restored.runKey, 'ST301.PK01.STRAP01.Running');
      expect(restored.invertRunPolarity, isTrue);
      // A literal must survive as a literal -- pages saved before the role
      // system existed hold these, and they must not be reinterpreted as a
      // role. Compared by value, not by object: a MaterialColor narrows to a
      // plain Color through the JSON map, which is the same colour but not
      // the same instance.
      for (final (actual, expected) in [
        (restored.runningColor, Colors.lime),
        (restored.stoppedColor, Colors.orange),
        (restored.outlineColor, Colors.indigo),
      ]) {
        expect(actual.isRole, isFalse);
        expect(actual.literal!.toARGB32(), expected.toARGB32());
      }
      expect(restored.strokeWidth, 3.5);
      expect(restored.tag, 'STRAP-01');
      expect(restored.showTag, isTrue);
      expect(restored.notes, 'Afak SL-15-3, three StrapX heads.');
      expect(restored.coordinates.x, 0.25);
      expect(restored.coordinates.angle, 90);
      expect(restored.size.width, 0.2);
      expect(restored.size.height, 0.14);
    });

    test('unknown kind in persisted JSON falls back instead of throwing', () {
      final json = ThirdPartyEquipmentConfig.preview().toJson();
      json['kind'] = 'someFutureMachine';

      expect(ThirdPartyEquipmentConfig.fromJson(json).kind,
          ThirdPartyEquipmentKind.multivac);
    });

    test('text aliases tag, and a null text does not clobber a legacy tag', () {
      final config = ThirdPartyEquipmentConfig(tag: 'MV-01', showTag: true);
      expect(config.text, 'MV-01');

      // The generated fromJson assigns `..text =` AFTER the constructor has
      // set `tag`. Legacy pages persist `text: null` alongside a real `tag`;
      // adopting the null would silently erase the operator's label.
      config.text = null;
      expect(config.tag, 'MV-01');

      config.text = 'MV-02';
      expect(config.tag, 'MV-02');
    });

    test('the page label is gated on showTag; the tag itself is not', () {
      final config = ThirdPartyEquipmentConfig(tag: 'SB-01');

      // Off by default: AssetStack scales the label with the asset's bounding
      // box and these machines are big, so the tag paints huge on the mimic.
      // The side pane titles itself from `tag` directly, not `text`.
      expect(config.showTag, isFalse);
      expect(config.text, isNull);
      expect(config.tag, 'SB-01');

      config.showTag = true;
      expect(config.text, 'SB-01');
    });

    test('a hidden tag still survives the JSON round-trip', () {
      // With showTag off, `text` serialises as null — the tag must ride its
      // own JSON key or hiding the label would erase it on save.
      final original = ThirdPartyEquipmentConfig(tag: 'SB-01');
      final restored = ThirdPartyEquipmentConfig.fromJson(original.toJson());

      expect(restored.tag, 'SB-01');
      expect(restored.showTag, isFalse);
      expect(restored.text, isNull);
    });

    test('legacy JSON without showTag defaults to hidden', () {
      // A page saved before showTag existed has no such key and persisted
      // `text` equal to the tag (the old getter was unconditional). Loading
      // it must hide the label — that is the point of the default — while
      // keeping the tag.
      final json = ThirdPartyEquipmentConfig(tag: 'MV-01').toJson();
      json.remove('showTag');
      json['text'] = 'MV-01';

      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      expect(restored.showTag, isFalse);
      expect(restored.tag, 'MV-01');
      expect(restored.text, isNull);
    });

    test('runKey is discoverable through BaseAsset.allKeys', () {
      final config = ThirdPartyEquipmentConfig(runKey: 'ST301.MV01.Running');
      expect(config.allKeys, contains('ST301.MV01.Running'));
    });

    test('statusKey round-trips and is discoverable through allKeys', () {
      final original = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        statusKey: 'SB1',
      );

      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.statusKey, 'SB1');
      // Ends in "Key", so the BaseAsset introspection must pick it up — the
      // key-discovery UI would otherwise never offer the handshake struct.
      expect(restored.allKeys, contains('SB1'));
    });

    test('legacy JSON without statusKey loads with it empty', () {
      final json = jsonDecode(jsonEncode(
              ThirdPartyEquipmentConfig(kind: ThirdPartyEquipmentKind.speedBatcher)
                  .toJson()))
          as Map<String, dynamic>;
      json.remove('statusKey');

      expect(ThirdPartyEquipmentConfig.fromJson(json).statusKey, '');
    });
  });

  group('Extra loose status bits', () {
    test('an extra bit round-trips with its key, label and colour', () {
      // The immediate use: a Multivac struct-backed off SPB0n.multivac, with
      // its outfeed permit declared as a loose bit reading a key in a
      // different namespace (MVC0n.PermitOutfeed).
      final original = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.multivac,
        statusKey: 'SPB02.Multivac',
        extraBits: const [
          ExtraStatusBit(
            key: 'MVC02.PermitOutfeed',
            label: '{m} may send boxes on',
            onRole: HmiColorRole.green,
          ),
        ],
      );

      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(restored.extraBits, hasLength(1));
      final bit = restored.extraBits.single;
      expect(bit.key, 'MVC02.PermitOutfeed');
      expect(bit.label, '{m} may send boxes on');
      expect(bit.labelFor('Multivac'), 'Multivac may send boxes on');
      expect(bit.onRole, HmiColorRole.green);
    });

    test('the extra key is discoverable through allKeys, undecorated', () {
      // A complete key, not a suffix — it must surface verbatim so key
      // discovery offers it exactly as it will be read.
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.multivac,
        statusKey: 'SPB01.Multivac',
        extraBits: const [
          ExtraStatusBit(
              key: 'MVC01.PermitOutfeed', label: 'Way out is clear'),
        ],
      );
      expect(config.allKeys, contains('MVC01.PermitOutfeed'));
      // Not appended to statusKey the way a prefix suffix would be.
      expect(config.allKeys,
          isNot(contains('SPB01.Multivac.MVC01.PermitOutfeed')));
    });

    test('an empty-key extra bit is skipped by key discovery', () {
      final config = ThirdPartyEquipmentConfig(
        extraBits: const [ExtraStatusBit(key: '', label: 'unset')],
      );
      expect(config.allKeys, isNot(contains('')));
    });

    test('extraBits default to empty, not null, on legacy JSON', () {
      final json = ThirdPartyEquipmentConfig.preview().toJson();
      json.remove('extraBits');
      expect(ThirdPartyEquipmentConfig.fromJson(json).extraBits, isEmpty);
    });

    test('the default colour is green, what a permit is everywhere in this file',
        () {
      // Both of the strapper's permits, both of the box erector's infeeds and
      // its outfeed are green; red is WaitingFrustration's alone.
      const bit = ExtraStatusBit(key: 'k', label: 'l');
      expect(bit.onRole, HmiColorRole.green);
    });

    test('an unknown onRole in newer JSON falls back to green, not a throw', () {
      // A config written by a newer build must not take the pane down.
      final json = jsonDecode(jsonEncode(ThirdPartyEquipmentConfig(
        extraBits: const [ExtraStatusBit(key: 'k', label: 'l')],
      ).toJson())) as Map<String, dynamic>;
      (json['extraBits'] as List).first['onRole'] = 'someFutureColour';

      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      expect(restored.extraBits.single.onRole, HmiColorRole.green);
    });

    test('several extra bits keep their order and each own key', () {
      final config = ThirdPartyEquipmentConfig(
        extraBits: const [
          ExtraStatusBit(key: 'MVC03.PermitOutfeed', label: 'out'),
          ExtraStatusBit(
              key: 'MVC03.PermitInfeed', label: 'in', onRole: HmiColorRole.blue),
        ],
      );
      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
      expect(restored.extraBits.map((b) => b.key),
          ['MVC03.PermitOutfeed', 'MVC03.PermitInfeed']);
      expect(restored.extraBits.map((b) => b.onRole),
          [HmiColorRole.green, HmiColorRole.blue]);
    });
  });

  group('Children inside the box', () {
    test('a conveyor child survives the round-trip with its position', () {
      final original = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        runKey: 'ST201.SB01.Running',
        children: [
          ThirdPartyChildEntry(
            id: 'lane-infeed',
            offsetX: 0.245,
            offsetY: 0.65,
            child: ConveyorConfig.preview(),
          ),
        ],
      );

      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(restored.children, hasLength(1));
      final entry = restored.children.single;
      expect(entry.id, 'lane-infeed');
      expect(entry.offsetX, closeTo(0.245, 1e-9));
      expect(entry.offsetY, closeTo(0.65, 1e-9));
      expect(entry.child, isA<ConveyorConfig>());
    });

    test('heterogeneous children round-trip and keep their order', () {
      final original = ThirdPartyEquipmentConfig(children: [
        ThirdPartyChildEntry(child: ConveyorConfig.preview()),
        ThirdPartyChildEntry(child: SensorConfig.preview()),
      ]);

      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(restored.children.map((e) => e.child.runtimeType),
          [ConveyorConfig, SensorConfig]);
    });

    test('an unregistered child asset_name fails loudly', () {
      // Silently dropping the child would let a saved page lose the conveyor
      // an operator depends on, with no error anywhere.
      final json = ThirdPartyEquipmentConfig(
        children: [ThirdPartyChildEntry(child: SensorConfig.preview())],
      ).toJson();
      (json['children'] as List).first['child']['asset_name'] = 'NopeConfig';

      expect(() => ThirdPartyEquipmentConfig.fromJson(json),
          throwsA(isA<FormatException>()));
    });

    test('child keys surface through allKeys alongside the run key', () {
      final conveyor = ConveyorConfig.preview();
      final config = ThirdPartyEquipmentConfig(
        runKey: 'ST201.SB01.Running',
        children: [ThirdPartyChildEntry(child: conveyor)],
      );

      expect(config.allKeys, contains('ST201.SB01.Running'));
      for (final key in conveyor.allKeys) {
        expect(config.allKeys, contains(key),
            reason: 'A conveyor placed inside the box must not be invisible '
                'to key discovery.');
      }
    });

    test('entry ids are unique even when created back to back', () {
      final ids = {
        for (int i = 0; i < 50; i++)
          ThirdPartyChildEntry(child: SensorConfig.preview()).id
      };
      expect(ids, hasLength(50));
    });

    test('children default to empty, not null, on legacy JSON', () {
      final json = ThirdPartyEquipmentConfig.preview().toJson();
      json.remove('children');
      expect(ThirdPartyEquipmentConfig.fromJson(json).children, isEmpty);
    });
  });

  group('SpeedBatcher station scaffold', () {
    List<ThirdPartyChildEntry> scaffold() =>
        buildSpeedBatcherStationChildren();

    test('builds 2 conveyors, 2 weights and 2 accept ratios', () {
      // Exactly what the station is: each checkweigher is a conveyor, with a
      // weight and an accept rate on it.
      final children = scaffold();
      expect(children, hasLength(6));
      expect(children.where((e) => e.child is ConveyorConfig), hasLength(2));
      expect(children.where((e) => e.child is NumberConfig), hasLength(2));
      expect(children.where((e) => e.child is RatioNumberConfig), hasLength(2));
    });

    test('the weigh-belt conveyors are bidirectional', () {
      // These belts get jogged both ways. A one-way belt would draw an arrow
      // that contradicts what the operator can see happening.
      for (final conveyor in scaffold()
          .map((e) => e.child)
          .whereType<ConveyorConfig>()) {
        expect(conveyor.bidirectional, isTrue);
        expect(conveyor.reverseDirection ?? false, isFalse,
            reason: 'Arrow direction comes from the sign of the live '
                'frequency, not a static flag.');
        expect(conveyor.coordinates.angle, 180,
            reason: 'Product runs right-to-left across the weigh belts, so '
                'the belt is turned half a revolution to make a positive '
                'frequency point with the flow.');
      }
    });

    test('weight sits right of the belt, accept rate left', () {
      final children = scaffold();
      final belts = children.where((e) => e.child is ConveyorConfig).toList();

      for (final belt in belts) {
        final row = children
            .where((e) =>
                e.child is! ConveyorConfig &&
                (e.offsetY - belt.offsetY).abs() < 0.02)
            .toList();
        expect(row, hasLength(2),
            reason: 'Each weigh belt gets exactly two readouts on its row.');

        final left = row.reduce((a, b) => a.offsetX < b.offsetX ? a : b);
        final right = row.reduce((a, b) => a.offsetX > b.offsetX ? a : b);

        expect(left.offsetX, lessThan(belt.offsetX));
        expect(right.offsetX, greaterThan(belt.offsetX));
        expect(left.child, isA<RatioNumberConfig>(),
            reason: 'Accept rate goes on the left.');
        expect(right.child, isA<NumberConfig>(),
            reason: 'Weight goes on the right.');
        expect((right.child as NumberConfig).units, isEmpty,
            reason: 'No unit is scaffolded — the operator sets it with the '
                'tag, since the PLC value is not always grams.');
      }
    });

    test('every scaffolded child lands inside the machine area', () {
      for (final entry in scaffold()) {
        expect(entry.offsetX, inInclusiveRange(0.0, 1.0));
        expect(entry.offsetY, inInclusiveRange(0.0, 1.0));
      }
    });

    test('the belts land on the painted weigh-belt beds', () {
      // The scaffold and the painter must agree on where the belt goes, or a
      // live conveyor floats off its bed.
      final belts = scaffold()
          .where((e) => e.child is ConveyorConfig)
          .map((e) => Offset(e.offsetX, e.offsetY))
          .toList();
      final decks = [
        SpeedBatcherPainter.deckOf(SpeedBatcherPainter.checkweigher1Frame),
        SpeedBatcherPainter.deckOf(SpeedBatcherPainter.checkweigher2Frame),
      ].map((r) => r.center).toList();

      for (final deck in decks) {
        expect(belts.any((b) => (b - deck).distance < 1e-9), isTrue,
            reason: 'A belt must sit at $deck.');
      }
    });

    test('readouts carry no graph, and no key to start with', () {
      for (final number in scaffold()
          .map((e) => e.child)
          .whereType<NumberConfig>()) {
        expect(number.key, isEmpty,
            reason: 'The operator points each readout at its own tag.');
        expect(number.graphConfig, isNull,
            reason: 'A tap-through to a trend from a nested child is a '
                'surprise.');
      }
      for (final ratio in scaffold()
          .map((e) => e.child)
          .whereType<RatioNumberConfig>()) {
        expect(ratio.key1, isEmpty);
        expect(ratio.key2, isEmpty);
      }
    });

    test('the station factory builds a ready-to-wire SpeedBatcher', () {
      // A SpeedBatcher without its belts and readouts is not a useful asset,
      // so it must not be possible to get one by accident.
      final config = ThirdPartyEquipmentConfig.speedBatcherStation();
      expect(config.kind, ThirdPartyEquipmentKind.speedBatcher);
      expect(config.children.where((e) => e.child is ConveyorConfig),
          hasLength(2));
      expect(config.children.where((e) => e.child is NumberConfig),
          hasLength(2));
      expect(config.children.where((e) => e.child is RatioNumberConfig),
          hasLength(2));
    });

    test('the whole station survives a JSON round-trip', () {
      final config = ThirdPartyEquipmentConfig.speedBatcherStation(
          acceptWindowMinutes: 20);
      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);

      expect(restored.children, hasLength(6));
      expect(
          restored.children
              .map((e) => e.child)
              .whereType<RatioNumberConfig>()
              .first
              .sinceMinutes,
          const Duration(minutes: 20));
    });

    test('readouts are marked upright, the belts are not', () {
      for (final entry in scaffold()) {
        if (entry.child is ConveyorConfig) {
          expect(entry.keepUpright, isFalse,
              reason: 'Machinery must turn with the machine it belongs to.');
        } else {
          expect(entry.keepUpright, isTrue,
              reason: 'A weight or ratio you have to tilt your head to read '
                  'is useless.');
        }
      }
    });

    test('the accept ratio carries its averaging window natively', () {
      // RatioNumberConfig models accepted-over-total across a rolling window,
      // so the window is a real field rather than text smuggled into a units
      // string — it cannot be read as an instantaneous figure.
      RatioNumberConfig ratioFor(int minutes) =>
          buildSpeedBatcherStationChildren(acceptWindowMinutes: minutes)
              .map((e) => e.child)
              .whereType<RatioNumberConfig>()
              .first;

      expect(ratioFor(30).sinceMinutes, const Duration(minutes: 30));
      expect(ratioFor(15).sinceMinutes, const Duration(minutes: 15));
    });

    test('the chart can be switched to the window the figure is quoted over',
        () {
      // The readout opens its chart on `sinceMinutes`. With the RatioNumber
      // default presets ([1, 5, 10, 60, 240]) a 30-minute station opened on a
      // window none of the toggles could show: nothing lit up, and once
      // another was pressed there was no way back to 30.
      RatioNumberConfig ratioFor(int minutes) =>
          buildSpeedBatcherStationChildren(acceptWindowMinutes: minutes)
              .map((e) => e.child)
              .whereType<RatioNumberConfig>()
              .first;

      expect(ratioFor(30).intervalPresets, contains(30));
      expect(ratioFor(45).intervalPresets, contains(45),
            reason: 'A non-standard window is folded in too.');
      expect(ratioFor(30).intervalPresets, orderedEquals([1, 5, 10, 30, 60, 240]),
          reason: 'Sorted and de-duplicated — 30 is not appended twice.');
    });

    test('accept bars are clock-aligned and counted in whole packs', () {
      final ratio = buildSpeedBatcherStationChildren()
          .map((e) => e.child)
          .whereType<RatioNumberConfig>()
          .first;

      // Clock-aligned: a 10-minute interval buckets at :00, :10, :20, so two
      // operators a minute apart read the same bars.
      expect(ratio.barsClockAligned, isTrue);
      // The bars count packs. Half a pack is not a tick.
      expect(ratio.integersOnly, isTrue);
    });

    test('the station pushes its accept settings onto stations saved earlier',
        () {
      // Pages placed before this were persisted with the RatioNumber
      // defaults. Repaired on load rather than by a migration: the parent
      // owns these children.
      final stale = RatioNumberConfig(key1: 'a', key2: 'b')
        ..intervalPresets = [1, 5, 10, 60, 240]
        ..barsClockAligned = false
        ..integersOnly = false;
      final json = jsonDecode(jsonEncode(ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        acceptWindowMinutes: 30,
        children: [ThirdPartyChildEntry(child: stale)],
      ).toJson())) as Map<String, dynamic>;

      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      final ratio =
          restored.children.single.child as RatioNumberConfig;
      expect(ratio.intervalPresets, contains(30));
      expect(ratio.barsClockAligned, isTrue);
      expect(ratio.integersOnly, isTrue);
    });

    test('turning clock alignment off on the station reaches both readouts',
        () {
      final config = ThirdPartyEquipmentConfig.speedBatcherStation();
      final ratios = config.children
          .map((e) => e.child)
          .whereType<RatioNumberConfig>()
          .toList();
      expect(ratios, hasLength(2));

      config.acceptBarsClockAligned = false;
      config.applyAcceptReadoutSettings();
      expect(ratios.every((r) => !r.barsClockAligned), isTrue);

      // ... and survives the round-trip, rather than snapping back to the
      // default on the next page load.
      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
      expect(restored.acceptBarsClockAligned, isFalse);
      expect(
          restored.children
              .map((e) => e.child)
              .whereType<RatioNumberConfig>()
              .every((r) => !r.barsClockAligned),
          isTrue);
    });

    test('a station saved before the alignment field defaults to aligned', () {
      final json = jsonDecode(jsonEncode(
              ThirdPartyEquipmentConfig.speedBatcherStation().toJson()))
          as Map<String, dynamic>;
      json.remove('acceptBarsClockAligned');

      expect(ThirdPartyEquipmentConfig.fromJson(json).acceptBarsClockAligned,
          isTrue);
    });

    test('the pane offers the configured window plus the chart presets', () {
      final config = ThirdPartyEquipmentConfig.speedBatcherStation(
          acceptWindowMinutes: 45);
      final ratios = config.children
          .map((e) => e.child)
          .whereType<RatioNumberConfig>()
          .toList();

      final options = thirdPartyAcceptWindowOptions(ratios,
          acceptWindowMinutes: config.acceptWindowMinutes);
      expect(options, orderedEquals([1, 5, 10, 30, 45, 60, 240]),
          reason: 'Sorted, de-duplicated, and the same ladder the chart '
              'toggles use — the picker and the chart must not disagree.');
      expect(options, contains(45),
          reason: 'The pane must open on a window it can offer.');

      // A station whose readouts were never scaffolded still offers its own
      // window rather than an empty list.
      expect(
          thirdPartyAcceptWindowOptions(const [], acceptWindowMinutes: 20),
          orderedEquals([20]));
    });

    test('the window reads as an operator would say it', () {
      expect(formatAcceptWindow(30), '30\u{00A0}min');
      expect(formatAcceptWindow(60), '1\u{00A0}h');
      expect(formatAcceptWindow(240), '4\u{00A0}h');
      expect(formatAcceptWindow(1440), '1\u{00A0}d');
      // Not a whole number of hours — minutes beat a rounded lie.
      expect(formatAcceptWindow(90), '90\u{00A0}min');
    });

    test('load cells sit clear of the belt centre', () {
      // The live Conveyor draws its run-direction arrow in the middle of the
      // belt; a painted block there sits right under it.
      final deck =
          SpeedBatcherPainter.deckOf(SpeedBatcherPainter.checkweigher1Frame);
      for (final x in [deck.left + 0.05, deck.right - 0.05]) {
        expect((x - deck.center.dx).abs(), greaterThan(0.1),
            reason: 'Load cell marks must not land under the arrow.');
      }
    });

    test('keepUpright and the text angle round-trip', () {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        childTextAngle: 15,
        acceptWindowMinutes: 45,
        children: [
          ThirdPartyChildEntry(
              keepUpright: true, child: NumberConfig(key: 'w')),
        ],
      );
      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);

      expect(restored.childTextAngle, 15);
      expect(restored.acceptWindowMinutes, 45);
      expect(restored.children.single.keepUpright, isTrue);
    });

    test('legacy JSON without the new fields still loads', () {
      // Encode for real before mutating: a child's `toJson()` can leave
      // nested objects (Coordinates, RelativeSize) as live instances rather
      // than maps, and only jsonEncode flattens them. This mirrors the page
      // save path, which always goes through JSON.
      final json = jsonDecode(jsonEncode(ThirdPartyEquipmentConfig(
        children: [ThirdPartyChildEntry(child: NumberConfig(key: 'w'))],
      ).toJson())) as Map<String, dynamic>;

      json.remove('childTextAngle');
      json.remove('acceptWindowMinutes');
      (json['children'] as List).first.remove('keepUpright');

      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      expect(restored.childTextAngle, 0);
      expect(restored.acceptWindowMinutes, 30);
      expect(restored.children.single.keepUpright, isFalse);
    });

    test('the scaffold survives a JSON round-trip intact', () {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        children: buildSpeedBatcherStationChildren(),
      );
      final restored = ThirdPartyEquipmentConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);

      expect(restored.children, hasLength(6));
      expect(restored.children.where((e) => e.child is ConveyorConfig),
          hasLength(2));
      for (final conveyor in restored.children
          .map((e) => e.child)
          .whereType<ConveyorConfig>()) {
        expect(conveyor.bidirectional, isTrue);
      }
    });
  });

  group('Strapping heads', () {
    test('head count round-trips', () {
      final json = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.strappingLine,
        strapMachines: 2,
      ).toJson();
      expect(ThirdPartyEquipmentConfig.fromJson(json).strapMachines, 2);
    });

    test('the painter draws one arch per head', () {
      for (final heads in const [1, 2, 3]) {
        expect(StrappingLinePainter.machineCentresFor(heads), hasLength(heads));
      }
    });

    test('arch centres stay inside the machine and in order', () {
      for (final heads in const [1, 2, 3]) {
        final centres = StrappingLinePainter.machineCentresFor(heads);
        expect(centres.first, greaterThan(0.05));
        expect(centres.last, lessThan(0.95));
        for (int i = 1; i < centres.length; i++) {
          expect(centres[i], greaterThan(centres[i - 1]));
        }
      }
    });

    test('label and footprint follow the strapper count', () {
      const kind = ThirdPartyEquipmentKind.strappingLine;
      expect(kind.labelFor(strapMachines: 1), contains('1 x StrapX'));
      expect(kind.labelFor(strapMachines: 3), contains('3 x StrapX'));
      // Only the 3-strapper length is published; the others must say so.
      expect(kind.footprint(strapMachines: 3), isNot(contains('estimated')));
      expect(kind.footprint(strapMachines: 2), contains('estimated'));
      expect(kind.footprint(strapMachines: 2), contains('2 strappers'));
    });

    test('fewer strappers means a shorter line', () {
      const kind = ThirdPartyEquipmentKind.strappingLine;
      expect(kind.aspectRatio(strapMachines: 1),
          lessThan(kind.aspectRatio(strapMachines: 2)));
      expect(kind.aspectRatio(strapMachines: 2),
          lessThan(kind.aspectRatio(strapMachines: 3)));
    });

    test('an out-of-range head count is clamped, not asserted on', () {
      // Persisted pages are not trusted input.
      expect(
          () => thirdPartyPainterFor(ThirdPartyEquipmentKind.strappingLine,
              color: Colors.black, strokeWidth: 2, strapMachines: 99),
          returnsNormally);
      expect(
          () => thirdPartyPainterFor(ThirdPartyEquipmentKind.strappingLine,
              color: Colors.black, strokeWidth: 2, strapMachines: 0),
          returnsNormally);
    });
  });

  group('Registry wiring', () {
    test('parse round-trips the asset out of a page JSON blob', () {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        runKey: 'ST201.SB01.Running',
      );
      final page = {
        'assets': [config.toJson()]
      };

      final parsed = AssetRegistry.parse(page);
      expect(parsed, hasLength(1));
      expect(parsed.single, isA<ThirdPartyEquipmentConfig>());
      expect((parsed.single as ThirdPartyEquipmentConfig).kind,
          ThirdPartyEquipmentKind.speedBatcher);
    });

    test('the asset palette can create one by name', () {
      final asset =
          AssetRegistry.createDefaultAssetByName('ThirdPartyEquipmentConfig');
      expect(asset, isA<ThirdPartyEquipmentConfig>());
    });
  });

  group('Run polarity', () {
    test('normal polarity passes the raw bool through', () {
      expect(
          thirdPartyIsRunning(rawBool: true, invertRunPolarity: false), isTrue);
      expect(thirdPartyIsRunning(rawBool: false, invertRunPolarity: false),
          isFalse);
    });

    test('inverted polarity flips it, for a stopped-contact machine', () {
      expect(
          thirdPartyIsRunning(rawBool: true, invertRunPolarity: true), isFalse);
      expect(
          thirdPartyIsRunning(rawBool: false, invertRunPolarity: true), isTrue);
    });
  });

  group('Painter dispatch', () {
    test('every kind maps to its own painter type', () {
      final painters = <Type>{};
      for (final kind in ThirdPartyEquipmentKind.values) {
        final painter =
            thirdPartyPainterFor(kind, color: Colors.black, strokeWidth: 2);
        painters.add(painter.runtimeType);
      }
      // One painter class per kind — no shared painter switching on `kind`
      // internally, which is what keeps painter state from leaking when the
      // operator changes the kind in the editor.
      expect(painters, hasLength(ThirdPartyEquipmentKind.values.length));
    });

    test('shouldRepaint is true across kinds and across colour changes', () {
      final multivac = thirdPartyPainterFor(ThirdPartyEquipmentKind.multivac,
          color: Colors.black, strokeWidth: 2);
      final erector = thirdPartyPainterFor(ThirdPartyEquipmentKind.boxErector,
          color: Colors.black, strokeWidth: 2);
      final recoloured = thirdPartyPainterFor(
          ThirdPartyEquipmentKind.multivac,
          color: Colors.red,
          strokeWidth: 2);
      final identical = thirdPartyPainterFor(ThirdPartyEquipmentKind.multivac,
          color: Colors.black, strokeWidth: 2);

      expect(multivac.shouldRepaint(erector), isTrue);
      expect(multivac.shouldRepaint(recoloured), isTrue);
      expect(multivac.shouldRepaint(identical), isFalse);
    });
  });

  group('Layout geometry', () {
    test('the LED header never overlaps the machine area', () {
      for (final size in const [
        Size(400, 80),
        Size(300, 260),
        Size(900, 166),
        Size(120, 90),
      ]) {
        final boundary = thirdPartyBoundaryRect(size);
        final machine = thirdPartyMachineArea(size);
        final ledBottom = boundary.top +
            thirdPartyLedInset(size) +
            thirdPartyLedDiameter(size);

        expect(machine.top, greaterThanOrEqualTo(ledBottom),
            reason: 'LED must sit in a header strip above the drawing '
                'at $size.');
      }
    });

    test('a degenerate rect falls back to the boundary instead of inverting',
        () {
      const tiny = Size(20, 14);
      final area = thirdPartyMachineArea(tiny);
      expect(area.width, greaterThan(0));
      expect(area.height, greaterThan(0));
    });

    test('painting a zero-sized canvas is a no-op, not a crash', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = thirdPartyPainterFor(ThirdPartyEquipmentKind.multivac,
          color: Colors.black, strokeWidth: 2);
      expect(() => painter.paint(canvas, Size.zero), returnsNormally);
      recorder.endRecording().dispose();
    });
  });

  group('Kind metadata', () {
    test('every kind has a label, a footprint and a sane aspect ratio', () {
      for (final kind in ThirdPartyEquipmentKind.values) {
        expect(kind.label, isNotEmpty);
        expect(kind.footprint(), isNotEmpty);
        // Two kinds are portrait (SpeedBatcher, box erector) and the Multivac
        // is 5.4:1, so the band has to be wide — it is only guarding against
        // a degenerate or absurd value.
        expect(kind.aspectRatio(), greaterThan(0.2));
        expect(kind.aspectRatio(), lessThan(10.0));
      }
    });

    test('the box erector still records that its product name is unresolved',
        () {
      // The marker moved out of the label and into the enum's doc comment:
      // an operator reading the pane should not be shown "TODO", but the
      // reminder must not vanish with it. The make/model of the box erector
      // on the line has still not been identified, and every other kind is
      // named after its manufacturer.
      //
      // Asserted on the source rather than the label for that reason. When
      // the machine is identified, this test goes along with the comment,
      // the label and the painter.
      final source =
          File('lib/page_creator/assets/third_party.dart').readAsStringSync();
      final enumBlock = source.substring(
          source.indexOf('enum ThirdPartyEquipmentKind'),
          source.indexOf('  String get label'));
      expect(enumBlock, contains('TODO(product-name)'),
          reason: 'the reminder that the box erector is unidentified is gone '
              'from both the label and the enum');

      expect(ThirdPartyEquipmentKind.boxErector.label, isNot(contains('TODO')),
          reason: 'operators should not be shown a TODO in the pane header');
    });
  });

  group('SpeedBatcher status bits', () {
    test('the four diodes match the retired flat asset, less Running', () {
      // Same members, labels and colours as speedbatcher.dart, so the pane
      // reads identically to the widget the operators already know -- with
      // `p_stat_Running` dropped, because [speedBatcherPaneStatus] builds the
      // header badge out of that same member and the machine on the page
      // carries the run LED. One bit, stated three times on one screen.
      expect(speedBatcherStatusBits.map((b) => b.member), [
        'p_stat_Cleaning',
        'p_stat_BatchReady',
        'p_stat_DropOk',
        'p_stat_Dropped',
      ]);
      for (final bit in speedBatcherStatusBits) {
        expect(
            bit.onRole,
            bit.member == 'p_stat_Cleaning'
                ? HmiColorRole.blue
                : HmiColorRole.green);
      }
    });

    test('a present bit reads through, true and false alike', () {
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_Running': true,
        'p_stat_Cleaning': false,
      }));
      expect(structStatusBitOf(status, 'p_stat_Running'), isTrue);
      expect(structStatusBitOf(status, 'p_stat_Cleaning'), isFalse);
    });

    test('a missing member degrades to unknown instead of throwing', () {
      // Three of the five bits have never been confirmed against the live
      // PLC, and `DynamicValue.operator[]` throws on a missing member — a
      // struct without the bit must give the grey `!`, not take the pane
      // down.
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_Running': true,
      }));
      expect(structStatusBitOf(status, 'p_stat_BatchReady'), isNull);
    });

    test('no struct at all — or a non-struct value — is unknown', () {
      expect(structStatusBitOf(null, 'p_stat_Running'), isNull);
      expect(
          structStatusBitOf(
              DynamicValue(value: true), 'p_stat_Running'),
          isNull);
    });
  });

  group('strapping line status bits', () {
    test('the members are the ones ST_StrappingLine_HMI publishes', () {
      // Read off the live st101 address space at
      // ns=4;s=STM01.STM01.hmi. Getting these wrong is silent: a member the
      // struct does not carry renders as the grey `!` forever rather than
      // failing, so the names are pinned here.
      expect(strappingLineStatusBits.map((b) => b.member), [
        'p_stat_WaitingFrustration',
        'p_stat_StrappingMachines[0].p_stat_Rdy',
        'p_stat_StrappingMachines[1].p_stat_Rdy',
        'p_stat_InfeedPermitted',
        'p_stat_OutfeedPermitted',
      ]);
    });

    test('a head path resolves through the array', () {
      // ST_StrappingLine_HMI declares ARRAY [1..2], and the server's browse
      // names keep that 1-based -- but reading the struct hands us a Dart
      // list, so head 1 is index 0. Getting this backwards would silently
      // swap the two heads' diodes, which no type error would catch.
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_StrappingMachines': [
          DynamicValue.fromMap(
              LinkedHashMap<String, dynamic>.from({'p_stat_Rdy': true})),
          DynamicValue.fromMap(
              LinkedHashMap<String, dynamic>.from({'p_stat_Rdy': false})),
        ],
      }));

      expect(structMemberPath('p_stat_StrappingMachines[0].p_stat_Rdy'),
          ['p_stat_StrappingMachines', 0, 'p_stat_Rdy']);
      expect(
          structStatusBitOf(status, 'p_stat_StrappingMachines[0].p_stat_Rdy'),
          isTrue);
      expect(
          structStatusBitOf(status, 'p_stat_StrappingMachines[1].p_stat_Rdy'),
          isFalse);
    });

    test('an out-of-range head is unknown, not a crash', () {
      // DynamicValue.operator[] throws on a bad index; a strapper wired for
      // one head must give the grey `!` rather than taking the pane down.
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_StrappingMachines': [
          DynamicValue.fromMap(
              LinkedHashMap<String, dynamic>.from({'p_stat_Rdy': true})),
        ],
      }));

      expect(
          structStatusBitOf(status, 'p_stat_StrappingMachines[1].p_stat_Rdy'),
          isNull);
      expect(structStatusBitOf(status, 'p_stat_Missing[0].p_stat_Rdy'), isNull);
    });

    test('the frustration row names the strapper as the cause', () {
      // The bit means everything upstream is ready and the machine has not
      // taken the box -- not that product is being released TO somewhere. The
      // two readings invert who is at fault, and an operator acts on the
      // difference.
      final frustration = strappingLineStatusBits
          .firstWhere((b) => b.member == 'p_stat_WaitingFrustration');
      expect(frustration.labelFor('strapping machine'),
          'Strapping machine is stopping the line');
      expect(frustration.onRole, HmiColorRole.red,
          reason: 'it is the one bit that says something is wrong');
    });

    test('a label with no {m} is left alone', () {
      // The SpeedBatcher's labels predate templating and carry no placeholder.
      for (final bit in speedBatcherStatusBits) {
        expect(bit.labelFor('SpeedBatcher'), bit.label);
      }
    });

    test('the strapper is struct-backed, not prefix-backed', () {
      expect(kStructStatusBits[ThirdPartyEquipmentKind.strappingLine],
          same(strappingLineStatusBits));
      expect(kEquipmentStatusBits[ThirdPartyEquipmentKind.strappingLine], isNull,
          reason: 'both maps would render two Status sections');
    });
  });

  group('multivac status bits', () {
    test('the members are the ones SP_Packing_HMI publishes, in order', () {
      // Read off the live SPB0n.multivac.hmi struct (an SP_Packing_HMI). A
      // member the struct does not carry renders as the grey `!` forever
      // rather than failing, so the names are pinned here. Ordered like the
      // strapper: the red stopping-line bit first, then ready -> waiting ->
      // done.
      expect(multivacStatusBits.map((b) => b.member), [
        'p_stat_WaitingFrustration',
        'p_stat_DropOk',
        'p_stat_DropRequestFeedback',
        'p_stat_DropFinished',
      ]);
    });

    test('the stopping-line row is first, red, and names the Multivac', () {
      // Option A: the same member the strapper uses, relabelled to name the
      // Multivac itself as the holdup rather than blaming the upstream release.
      final first = multivacStatusBits.first;
      expect(first.member, 'p_stat_WaitingFrustration');
      expect(first.onRole, HmiColorRole.red,
          reason: 'it is the one bit that says something is wrong');
      expect(
          first.labelFor(
              equipmentShortName(ThirdPartyEquipmentKind.multivac)),
          'Multivac is stopping the line');
    });

    test('the remaining rows keep their prefix-era colours and wording', () {
      final byMember = {for (final b in multivacStatusBits) b.member: b};
      expect(byMember['p_stat_DropOk']!.onRole, HmiColorRole.green);
      expect(byMember['p_stat_DropOk']!.labelFor('Multivac'),
          'Multivac is ready for fish');
      expect(byMember['p_stat_DropRequestFeedback']!.onRole,
          HmiColorRole.yellow);
      expect(byMember['p_stat_DropRequestFeedback']!.labelFor('Multivac'),
          'Fish waiting to drop to Multivac');
      expect(byMember['p_stat_DropFinished']!.onRole, HmiColorRole.green);
      expect(byMember['p_stat_DropFinished']!.labelFor('Multivac'),
          'Drop to Multivac is complete');
    });

    test('the multivac is struct-backed, not prefix-backed', () {
      expect(kStructStatusBits[ThirdPartyEquipmentKind.multivac],
          same(multivacStatusBits));
      expect(kEquipmentStatusBits[ThirdPartyEquipmentKind.multivac], isNull,
          reason: 'both maps would render two Status sections');
    });
  });

  group('fish aligner status bits', () {
    test('the members are the ones SP_Packing_HMI publishes, in order', () {
      // Read off the live SPB0n.packing.hmi struct (an SP_Packing_HMI, the
      // same FB the Multivac reads). A member the struct does not carry
      // renders as the grey `!` forever rather than failing, so the names are
      // pinned here. Ordered like the strapper/multivac: the red stopping-line
      // bit first, then ready -> waiting -> done.
      expect(fishAlignerStatusBits.map((b) => b.member), [
        'p_stat_WaitingFrustration',
        'p_stat_DropOk',
        'p_stat_DropRequestFeedback',
        'p_stat_DropFinished',
      ]);
    });

    test('the stopping-line row is first, red, and names the batch aligner', () {
      // Option A: the same member the strapper/multivac uses, relabelled to
      // name the aligner itself as the holdup rather than blaming the upstream
      // release.
      final first = fishAlignerStatusBits.first;
      expect(first.member, 'p_stat_WaitingFrustration');
      expect(first.onRole, HmiColorRole.red,
          reason: 'it is the one bit that says something is wrong');
      expect(
          first.labelFor(
              equipmentShortName(ThirdPartyEquipmentKind.fishAligner)),
          'Batch aligner is stopping the line');
    });

    test('the remaining rows keep their prefix-era colours and wording', () {
      final byMember = {for (final b in fishAlignerStatusBits) b.member: b};
      expect(byMember['p_stat_DropOk']!.onRole, HmiColorRole.green);
      expect(byMember['p_stat_DropOk']!.labelFor('batch aligner'),
          'Batch aligner is ready for fish');
      expect(byMember['p_stat_DropRequestFeedback']!.onRole,
          HmiColorRole.yellow);
      expect(byMember['p_stat_DropRequestFeedback']!.labelFor('batch aligner'),
          'Fish waiting to drop to batch aligner');
      expect(byMember['p_stat_DropFinished']!.onRole, HmiColorRole.green);
      expect(byMember['p_stat_DropFinished']!.labelFor('batch aligner'),
          'Drop to batch aligner is complete');
    });

    test('the fish aligner reads the same struct shape as the multivac', () {
      // Both read SPB0n.packing.hmi (an SP_Packing_HMI); the diode lists are
      // intentionally identical member-for-member and colour-for-colour.
      expect(fishAlignerStatusBits.map((b) => b.member),
          multivacStatusBits.map((b) => b.member));
      expect(fishAlignerStatusBits.map((b) => b.onRole),
          multivacStatusBits.map((b) => b.onRole));
    });

    test('the fish aligner is struct-backed, not prefix-backed', () {
      expect(kStructStatusBits[ThirdPartyEquipmentKind.fishAligner],
          same(fishAlignerStatusBits));
      expect(kEquipmentStatusBits[ThirdPartyEquipmentKind.fishAligner], isNull,
          reason: 'both maps would render two Status sections');
    });
  });

  group('box erector status bits', () {
    final bits = kEquipmentStatusBits[ThirdPartyEquipmentKind.boxErector]!;

    test('one key per PLC member, appended to the prefix', () {
      // The whole point of this kind: suffixes off `statusKey`, so `BER01`
      // yields BER01.WaitingFrustration and friends. Each is a mapping an
      // engineer can point at and rename, rather than a member name pinned
      // against a .TcPOU that renders a grey `!` when the PLC moves.
      expect(bits.map((b) => b.suffix), [
        'WaitingFrustration',
        'PermitInfeed',
        'PermitOutfeed',
      ]);
      // The kind reads NO struct: it must be in exactly one routing map, or
      // the pane would render two Status sections.
      expect(kStructStatusBits[ThirdPartyEquipmentKind.boxErector], isNull);
      expect(isStructBacked(ThirdPartyEquipmentKind.boxErector), isFalse);
      expect(structMembersOf(ThirdPartyEquipmentKind.boxErector), isEmpty);
    });

    test('three rows: who is blocking it, and what it will take', () {
      // The pane briefly drew seventeen struct members in six collapsible
      // groups. That is a diagnostics dump, not an operator pane -- the
      // per-drive and pusher faults are alarms. The two carton-chute rows are
      // per-instance extra bits, not entries here, because only BER01 has
      // those sensors.
      expect(bits, hasLength(3));
      expect(
          bits
              .map((b) => b.labelFor(
                  equipmentShortName(ThirdPartyEquipmentKind.boxErector)))
              .toList(),
          [
            'Box erector is stopping the line',
            'Box erector is ready for product',
            'Box erector may send boxes on',
          ]);
    });

    test('no Running diode -- the header badge and the run LED say it', () {
      // Jon, on this pane: "we don't need a diode for running, it is in the
      // top". The struct-backed kinds already read it that way -- see the note
      // on [multivacStatusBits], whose `p_stat_Run` "feeds the run LED/badge"
      // and is deliberately not drawn.
      expect(bits.map((b) => b.suffix), isNot(contains(kBoxErectorRunSuffix)));
      // But the KEY is untouched. Deleting the bit without moving the key to
      // [kBoxErectorRunSuffix] would have taken `BER01.Running` out of key
      // discovery, and an unused-key sweep would then have offered to delete a
      // live mapping.
      expect(kBoxErectorRunSuffix, 'Running');
    });

    test('every non-diode suffix off the prefix stays discoverable', () {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.boxErector,
        statusKey: 'BER01',
        runKey: '',
      );
      expect(config.allKeys, contains('BER01.$kBoxErectorRunSuffix'));
      expect(config.allKeys, contains('BER01.$kBoxErectorCommsSuffix'));
    });

    test('the colours follow the house vocabulary', () {
      final bySuffix = {for (final b in bits) b.suffix: b};
      // Green: every permit -- the rule the whole file keeps.
      expect(bySuffix['PermitInfeed']!.onRole, HmiColorRole.green);
      expect(bySuffix['PermitOutfeed']!.onRole, HmiColorRole.green);
      // Red: the one row that says something is WRONG.
      expect(bySuffix['WaitingFrustration']!.onRole, HmiColorRole.red);
    });

    test('the outfeed permit is the SAME sentence as the strapper', () {
      // One handshake under two PLC names. Two wordings for it would make one
      // fact read as two different ones down a column of open panes.
      final erector = bits.firstWhere((b) => b.suffix == 'PermitOutfeed');
      final strapper = strappingLineStatusBits
          .firstWhere((b) => b.member == 'p_stat_OutfeedPermitted');
      expect(erector.label, strapper.label);
      expect(erector.onRole, strapper.onRole);
    });

    test('the frustration row keeps the strapper wording, red', () {
      final erector = bits.firstWhere((b) => b.suffix == 'WaitingFrustration');
      final strapper = strappingLineStatusBits
          .firstWhere((b) => b.member == 'p_stat_WaitingFrustration');
      expect(erector.label, strapper.label);
      expect(erector.onRole, strapper.onRole);
    });

    test('the two non-diode suffixes ride the same prefix', () {
      // Neither is drawn as a lamp: one decides whether the others may be
      // believed, the other feeds the trend. They are named here so a prefix
      // rename moves all six keys together.
      expect(kBoxErectorCommsSuffix, 'ModbusHealthy');
      expect(kBoxErectorBpmSuffix, 'CartonsPerMinute');
      expect(bits.map((b) => b.suffix), isNot(contains(kBoxErectorCommsSuffix)),
          reason: 'the link-health bit is a gate, not a row');
      expect(bits.map((b) => b.suffix), isNot(contains(kBoxErectorBpmSuffix)),
          reason: 'a rate is not a lamp');
    });
  });

  group('SpeedBatcher pane badge', () {
    DynamicValue struct(Map<String, dynamic> members) =>
        DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from(members));
    const fallback = PaneStatus.stale();

    test('Cleaning wins, even while Running is still up', () {
      // Mid-wash the struct can carry both bits; "Cleaning" is the truth an
      // operator acts on. A runKey-only badge showed Stopped during a wash —
      // the exact lie the badge exists to avoid.
      final status = speedBatcherPaneStatus(
          struct({'p_stat_Running': true, 'p_stat_Cleaning': true}), fallback);
      expect(status.label, 'Cleaning');
      expect(status.color, Colors.blue,
          reason: 'Badge blue must match the Cleaning diode.');
    });

    test('Running bit drives Running/Stopped', () {
      expect(
          speedBatcherPaneStatus(
              struct({'p_stat_Running': true, 'p_stat_Cleaning': false}),
              fallback),
          const PaneStatus.running());
      expect(
          speedBatcherPaneStatus(
              struct({'p_stat_Running': false, 'p_stat_Cleaning': false}),
              fallback),
          const PaneStatus.stopped());
    });

    test('an unreadable struct leaves the runKey-derived fallback standing',
        () {
      expect(speedBatcherPaneStatus(null, fallback), fallback);
      expect(speedBatcherPaneStatus(struct({}), fallback), fallback);
    });
  });

  group('Box erector throughput (bpm)', () {
    test('the trend needs the throughput key collected, nothing more', () {
      // A plain numeric key now, so an entry for it is the whole requirement.
      // It used to also have to carry the member in `sample_members`, because
      // the number lived three levels inside an FB_BPM instance in the status
      // struct; one key per PLC member retires that.
      expect(boxErectorBpmTrendAvailable(null), isFalse,
          reason: 'uncollected: no history exists, so offer no chart');
      expect(
          boxErectorBpmTrendAvailable(
              CollectEntry(key: 'BER01.CartonsPerMinute')),
          isTrue);
    });

    test('the rate axis counts in whole cartons', () {
      // Cartons leave the erector one at a time, so a gridline offering 12.8
      // of one is a precision the machine does not have.
      //
      // Asserted here rather than left to the golden because the axis labels
      // are painted onto the chart canvas, not into `Text` widgets: no finder
      // can read them back, and a golden says only that some pixels moved.
      for (final compact in [true, false]) {
        expect(boxErectorBpmYAxis(compact: compact).decimals, 0,
            reason: 'compact: $compact');
        // NOT integersOnly. That moves the gridlines instead of the text, and
        // on the 15-minute preview -- short enough for only two ticks -- the
        // rounded step came out wider than the range and took the top label
        // with it, leaving an axis that read `0` and nothing else.
        expect(boxErectorBpmYAxis(compact: compact).integersOnly, isFalse,
            reason: 'compact: $compact');
        // The floor stays pinned: a rate chart that rescales its baseline
        // turns a small dip into an apparent stoppage.
        expect(boxErectorBpmYAxis(compact: compact).min, 0);
      }
      // Only the labels are rounded. The unit still names the quantity in the
      // expanded chart, and is dropped in the tile where the header names it.
      expect(boxErectorBpmYAxis(compact: false).unit, 'Cartons/min');
      expect(boxErectorBpmYAxis(compact: true).unit, isEmpty);
    });
  });

  group('Box erector Modbus link gate', () {
    test('healthy, down, and ABSENT are three different answers', () {
      expect(boxErectorCommsOf({kBoxErectorCommsSuffix: true}), isTrue);
      expect(boxErectorCommsOf({kBoxErectorCommsSuffix: false}), isFalse);

      // Absent must be null, NOT false. BER02/BER03 have no ModbusHealthy key
      // mapped, and nothing has arrived yet on a pane that just opened;
      // treating either as "link down" would blank a working pane.
      expect(boxErectorCommsOf({'Running': true}), isNull);
      expect(boxErectorCommsOf(const {}), isNull);
      // A key that ERRORED lands as an explicit null, and is likewise unknown.
      expect(boxErectorCommsOf({kBoxErectorCommsSuffix: null}), isNull);
    });

    test('every diode can be lit and still be a lie -- hence the gate', () {
      // The failure this guards. FB_BER01ScadaPoll decodes the Saia's process
      // word unconditionally, so when the Modbus link drops every published
      // bit HOLDS its last value. One key per member does not change that:
      // four separate OPC UA subscriptions to four frozen PLC variables are
      // just as confidently wrong as one frozen struct, and our subscription
      // to ST101 stays perfectly healthy throughout.
      const frozen = <String, bool?>{
        kBoxErectorCommsSuffix: false,
        'Running': true,
        'PermitInfeed': true,
        'PermitOutfeed': true,
      };
      expect(frozen['Running'], isTrue,
          reason: 'the stale bit is indistinguishable from a live one');
      expect(boxErectorCommsOf(frozen), isFalse,
          reason: 'only the health key reveals it');
    });
  });
}
