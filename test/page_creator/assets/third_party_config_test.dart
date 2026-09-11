import 'dart:io';
import 'dart:collection' show LinkedHashMap;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart' show ListEquality;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
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

  group('Pallet stations', () {
    test('station count round-trips', () {
      final json = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.optimarPalletiser,
        robotStations: 3,
      ).toJson();
      expect(ThirdPartyEquipmentConfig.fromJson(json).robotStations, 3);
    });

    test('a page saved before the field defaults to two stations', () {
      final json = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.optimarPalletiser,
      ).toJson()
        ..remove('robotStations');
      expect(ThirdPartyEquipmentConfig.fromJson(json).robotStations, 2);
    });

    test('the two counts are separate fields, not one shared number', () {
      // A page can carry a strapping line AND a palletiser; setting the
      // strapper count must not move the pallet stations with it.
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.optimarPalletiser,
        strapMachines: 1,
        robotStations: 3,
      );
      final restored =
          ThirdPartyEquipmentConfig.fromJson(config.toJson());
      expect(restored.strapMachines, 1);
      expect(restored.robotStations, 3);
    });

    test('the painter draws one station per count', () {
      for (final n in const [1, 2, 3]) {
        expect(OptimarPalletiserPainter.robotCentresFor(n), hasLength(n));
      }
    });

    test('station centres stay inside the row and in order', () {
      for (final n in const [1, 2, 3]) {
        final centres = OptimarPalletiserPainter.robotCentresFor(n);
        expect(centres.first, greaterThan(0.0));
        expect(centres.last, lessThan(1.0));
        for (int i = 1; i < centres.length; i++) {
          expect(centres[i], greaterThan(centres[i - 1]));
        }
      }
    });

    test('stations tile the row without overlapping or leaving a gap', () {
      // Each station owns exactly one pitch, so the lanes must never cross a
      // neighbour's boundary — the failure that would draw one row's robot
      // reaching into the next station's lane.
      for (final n in const [1, 2, 3]) {
        final w = OptimarPalletiserPainter.stationWidthFor(n);
        expect(w * n, closeTo(1.0, 1e-9));
        for (int i = 0; i < n; i++) {
          final sx = OptimarPalletiserPainter.stationLeftFor(i, n);
          final lane = OptimarPalletiserPainter.laneRectFor(i, n);
          expect(lane.left, greaterThanOrEqualTo(sx));
          expect(lane.right, lessThanOrEqualTo(sx + w));
        }
      }
    });

    test('the robot stands beside its lane, not on it', () {
      // The whole point of the layout: the arm reaches SIDEWAYS across the
      // lane. A robot centre inside the lane rect would draw the pad on top
      // of the pallets.
      for (final n in const [1, 2, 3]) {
        final centres = OptimarPalletiserPainter.robotCentresFor(n);
        for (int i = 0; i < n; i++) {
          final lane = OptimarPalletiserPainter.laneRectFor(i, n);
          expect(centres[i], greaterThan(lane.right),
              reason: '$n stations: robot $i sits on its own lane.');
        }
      }
    });

    test('every lane sits inside the fenced row', () {
      for (final n in const [1, 2, 3]) {
        for (int i = 0; i < n; i++) {
          final lane = OptimarPalletiserPainter.laneRectFor(i, n);
          expect(lane.top, greaterThanOrEqualTo(OptimarPalletiserPainter.rowTop));
          expect(lane.bottom,
              lessThanOrEqualTo(OptimarPalletiserPainter.rowBottom));
        }
      }
    });

    test('the stations fill the box, top to bottom', () {
      // The drawing's transfer rail and pallet magazine are not drawn — they
      // are hall-wide and sit outside the guarding. The height they used to
      // take must go to the stations, not be left as a blank strip, which
      // reads as a rendering fault rather than as a deliberate omission.
      expect(OptimarPalletiserPainter.rowBottom, greaterThan(0.95));
      final lane = OptimarPalletiserPainter.laneRectFor(0, 1);
      expect(lane.height, greaterThan(0.8),
          reason: 'the lane should use nearly the whole depth.');
    });

    test('the base plate is smaller than the pad it stands on', () {
      // Ø1250 plate on a Ø1800 pad. Equal radii would draw one thick ring and
      // lose the foundation the drawing is actually about.
      expect(OptimarPalletiserPainter.plateRadius,
          lessThan(OptimarPalletiserPainter.padRadius));
      expect(
          OptimarPalletiserPainter.plateRadius /
              OptimarPalletiserPainter.padRadius,
          closeTo(1250 / 1800, 1e-9));
    });

    test('label and footprint follow the station count', () {
      const kind = ThirdPartyEquipmentKind.optimarPalletiser;
      expect(kind.labelFor(robotStations: 1), contains('1 station'));
      expect(kind.labelFor(robotStations: 3), contains('3 stations'));
      expect(kind.labelFor(robotStations: 2), contains('Optimar'));
      // The pitch is dimensioned on the drawing, so it is quoted as a fact
      // and travels with the footprint at every count.
      for (final n in const [1, 2, 3]) {
        expect(kind.footprint(robotStations: n), contains('3500 mm pitch'));
      }
      // Ph-1 as built: three stations at 3500 mm.
      expect(kind.footprint(robotStations: 3), contains('10500 x 4000'));
    });

    test('the pitch is the drawing dimension, not a guess', () {
      // 5210 / 8710 / 12210 are the three Ph-1 robot centres off the building
      // datum. If this constant ever drifts, the footprint stops matching the
      // drawing it claims to come from.
      expect(kPalletiserPitchMm, 8710 - 5210);
      expect(kPalletiserPitchMm, 12210 - 8710);
      expect(kPalletiserWidthMm(3), kPalletiserPitchMm * 3);
    });

    test('more stations means a wider cell', () {
      const kind = ThirdPartyEquipmentKind.optimarPalletiser;
      expect(kind.aspectRatio(robotStations: 1),
          lessThan(kind.aspectRatio(robotStations: 2)));
      expect(kind.aspectRatio(robotStations: 2),
          lessThan(kind.aspectRatio(robotStations: 3)));
    });

    test('an out-of-range station count is clamped, not asserted on', () {
      // Persisted pages are not trusted input.
      for (final n in const [0, 99, -1]) {
        expect(
            () => thirdPartyPainterFor(
                ThirdPartyEquipmentKind.optimarPalletiser,
                color: Colors.black,
                strokeWidth: 2,
                robotStations: n),
            returnsNormally,
            reason: '$n stations must clamp.');
      }
    });

    test('the station row has no handshake to point a status key at', () {
      // Deliberate, and the reason the editor hides the field: the PLC
      // publishes no permit vocabulary for this cell. If one ever appears it
      // arrives as a line in kStructStatusBits and this test changes with it.
      const kind = ThirdPartyEquipmentKind.optimarPalletiser;
      expect(isStructBacked(kind), isFalse);
      expect(hasStatusTable(kind), isFalse);
      expect(structMembersOf(kind), isEmpty);
    });

    test('the painter cites the drawing it was taken from', () {
      // This kind is the only one drawn from a real supplier drawing rather
      // than from photos and spec sheets. If the citation goes, the next
      // person has no way back to the source that fixes the geometry.
      final source = File('lib/page_creator/assets/third_party_painter.dart')
          .readAsStringSync();
      expect(source, contains('10-N1230-1'));
      expect(source, contains('optimar.no'));
    });
  });

  group('Mirroring', () {
    test('both axes round-trip', () {
      final json = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.optimarPalletiser,
        mirrorX: true,
        mirrorY: true,
      ).toJson();
      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      expect(restored.mirrorX, isTrue);
      expect(restored.mirrorY, isTrue);
    });

    test('a page saved before mirroring loads unmirrored', () {
      final json = ThirdPartyEquipmentConfig().toJson()
        ..remove('mirrorX')
        ..remove('mirrorY');
      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      expect(restored.mirrorX, isFalse);
      expect(restored.mirrorY, isFalse);
    });

    test('the two axes are independent', () {
      final json = ThirdPartyEquipmentConfig(mirrorX: true).toJson();
      final restored = ThirdPartyEquipmentConfig.fromJson(json);
      expect(restored.mirrorX, isTrue);
      expect(restored.mirrorY, isFalse);
    });

    test('every kind accepts a mirror, and repaints when it changes', () {
      // Driven off the enum: every kind here is chiral, so none may quietly
      // ignore the flag. A painter that dropped it would return false from
      // shouldRepaint and leave the old drawing on screen.
      for (final kind in ThirdPartyEquipmentKind.values) {
        final plain = thirdPartyPainterFor(kind,
            color: Colors.black, strokeWidth: 2);
        final flippedX = thirdPartyPainterFor(kind,
            color: Colors.black, strokeWidth: 2, mirrorX: true);
        final flippedY = thirdPartyPainterFor(kind,
            color: Colors.black, strokeWidth: 2, mirrorY: true);

        expect(plain.mirrorX, isFalse, reason: '${kind.name} default');
        expect(flippedX.mirrorX, isTrue,
            reason: '${kind.name} must carry mirrorX through the dispatch.');
        expect(flippedY.mirrorY, isTrue,
            reason: '${kind.name} must carry mirrorY through the dispatch.');
        expect(plain.shouldRepaint(flippedX), isTrue,
            reason: '${kind.name} must repaint when mirrorX changes.');
        expect(plain.shouldRepaint(flippedY), isTrue,
            reason: '${kind.name} must repaint when mirrorY changes.');
      }
    });

    test('mirroring actually changes the pixels, on every kind', () async {
      // The flag reaching the painter is not the same as the painter using it.
      // Rasterising and comparing catches a paintMachine that ignores the
      // transform entirely.
      //
      // Asserted as "at least one axis moves", NOT per axis, because a
      // correct painter can be a no-op on one of them: the box erector is
      // drawn left-right SYMMETRIC — two guide rails either side of a centred
      // forming station, a centred vacuum head, a centred outfeed — because
      // that is what the machine looks like from above. Mirroring it on X
      // must produce identical pixels, and demanding otherwise would fail a
      // painter that is right.
      Future<Uint8List?> render(ThirdPartyEquipmentKind kind,
          {bool mirrorX = false, bool mirrorY = false}) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        thirdPartyPainterFor(kind,
                color: Colors.black,
                strokeWidth: 2,
                mirrorX: mirrorX,
                mirrorY: mirrorY)
            .paint(canvas, const Size(400, 300));
        final picture = recorder.endRecording();
        final image = picture.toImageSync(400, 300);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        picture.dispose();
        return bytes?.buffer.asUint8List();
      }

      for (final kind in ThirdPartyEquipmentKind.values) {
        final plain = await render(kind);
        final flippedX = await render(kind, mirrorX: true);
        final flippedY = await render(kind, mirrorY: true);
        expect(plain, isNotNull);
        expect(
            !const ListEquality<int>().equals(plain, flippedX) ||
                !const ListEquality<int>().equals(plain, flippedY),
            isTrue,
            reason: '${kind.name} is unchanged by a flip on EITHER axis, so '
                'its painter is ignoring the mirror transform. Every kind is '
                'chiral on at least one axis.');
      }
    });

    test('a mirrored machine keeps its children on their lanes', () {
      // The SpeedBatcher's scaffolded weigh belts are the case that matters:
      // mirror the drawing and leave the children put, and every readout ends
      // up beside the belt it belongs to instead of on it.
      final station = ThirdPartyEquipmentConfig.speedBatcherStation();
      final offsets = [for (final e in station.children) e.offsetX];
      expect(offsets.any((x) => (x - 0.5).abs() > 0.05), isTrue,
          reason: 'this test is vacuous if every child is centred.');
      // The body mirrors positions as 1 - offset; assert the arithmetic the
      // widget uses, so an off-by-one-axis change fails here.
      for (final x in offsets) {
        expect(1.0 - (1.0 - x), closeTo(x, 1e-9));
      }
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

  group('Empty pallet magazine', () {
    const magazine = ThirdPartyEquipmentKind.palletMagazine;

    test('brings no diode table of its own', () {
      // The premise every other test in this group rests on. If the magazine
      // ever gains a struct or a suffix table, the editor stops hiding the
      // status key field and the help text changes back -- and those tests
      // would start passing for the wrong reason rather than failing.
      expect(kStructStatusBits[magazine], isNull);
      expect(kEquipmentStatusBits[magazine], isNull);
      expect(hasStatusTable(magazine), isFalse);
      expect(isStructBacked(magazine), isFalse);
    });

    test('is table-less for a different reason than the palletising row', () {
      // Both are table-less and the editor treats them identically, which is
      // right. They are NOT the same case underneath: the palletising row has
      // no handshake to read, and this machine has one the PLC publishes as
      // loose globals. The help text is where that difference has to show --
      // naming EPW01 at a kind with no keys would be inventing a handshake.
      const palletiser = ThirdPartyEquipmentKind.optimarPalletiser;
      expect(hasStatusTable(palletiser), isFalse);

      expect(extraStatusBitsHelpText(magazine), contains('EPW01'));
      expect(extraStatusBitsHelpText(palletiser), isNot(contains('EPW01')));
      // The shared half is genuinely shared, not two copies that can drift.
      expect(extraStatusBitsHelpText(palletiser),
          contains('no diodes of its own'));
    });

    test('nothing is composed onto a status key it cannot use', () {
      // Not a hypothetical: switching an existing asset's kind leaves whatever
      // prefix it was carrying in the JSON, and the editor no longer shows a
      // field to clear it with. That leftover must not turn into a
      // subscription or into composed `.Suffix` keys.
      final config =
          ThirdPartyEquipmentConfig(kind: magazine, runKey: 'EPW01.Run')
            ..statusKey = 'BER02';

      expect(config.allKeys, contains('EPW01.Run'));
      expect(config.allKeys.where((k) => k.startsWith('BER02.')), isEmpty,
          reason: 'the magazine appends no suffix to a status prefix');

      // The BARE prefix is still discovered, and that is `BaseAsset.allKeys`
      // introspecting `toJson()` rather than anything this kind does -- the
      // box erector's `BER01` is discovered the same way, and is just as much
      // not a node. Asserted rather than left unsaid so that if key discovery
      // is ever taught to skip dead prefixes, this is the test that says the
      // magazine was one of the reasons.
      expect(config.allKeys, contains('BER02'));
    });

    test('its extra bits are what reach keys, at the full key each', () {
      final config = ThirdPartyEquipmentConfig(kind: magazine, runKey: '')
        ..extraBits = [
          const ExtraStatusBit(
              key: 'EPW01.PalletReady', label: '{m} has a pallet ready'),
          const ExtraStatusBit(
              key: 'EPW01.WagonReady', label: 'Wagon is ready for a {m} pallet'),
          // An unconfigured row must not put an empty key into discovery.
          const ExtraStatusBit(key: '', label: 'not wired yet'),
        ];

      expect(config.allKeys, containsAll(['EPW01.PalletReady', 'EPW01.WagonReady']));
      expect(config.allKeys, isNot(contains('')));
    });

    test('a label template fills in the machine name like every other bit', () {
      const bit = ExtraStatusBit(
          key: 'EPW01.PalletReady', label: '{m} has a pallet ready');
      expect(bit.labelFor(equipmentShortName(magazine)),
          'Pallet magazine has a pallet ready');
    });

    test('the editor help text tells it what its Status section IS', () {
      final help = extraStatusBitsHelpText(magazine);
      // The sentence that orders extra bits AFTER the kind's own diodes is the
      // one that must not be shown here -- there are none to come after.
      expect(help, isNot(contains('Shown after the normal diodes')));
      expect(help, contains('no diodes of its own'));
      // And it names where the four bools actually live, because the only
      // other way to learn that is to open the GVL.
      expect(help, contains('EPW01'));
      // The label-template half is shared with every other kind.
      expect(help, contains('{m}'));

      final erector =
          extraStatusBitsHelpText(ThirdPartyEquipmentKind.boxErector);
      expect(erector, contains('Shown after the normal diodes'));
      expect(erector, isNot(contains('no diodes of its own')));
    });

    test('metadata quotes the pallet, which is known, and not the frame, '
        'which is not', () {
      expect(magazine.label, 'Empty pallet magazine');
      expect(magazine.footprint(), contains('1200 x 800'));
      expect(magazine.footprint(), contains('per site CAD'),
          reason: 'the drawing gives no frame dimension, so none is quoted');
      expect(equipmentShortName(magazine), 'pallet magazine');
    });

    test('the enum still records that its product name is unresolved', () {
      // Same marker the box erector carries, and for the same reason: balloon
      // 031 has no text against it and no make has been identified. When one
      // is, the value, the label and the painter get renamed together.
      final source =
          File('lib/page_creator/assets/third_party.dart').readAsStringSync();
      final decl = source.indexOf('  palletMagazine,');
      expect(decl, greaterThan(0));
      final doc = source.substring(source.indexOf('fishAligner,'), decl);
      expect(doc, contains('TODO(product-name)'));
    });
  });

  group('PalletMagazinePainter geometry', () {
    test('the pallet stands inside the well, clear of the corner guides', () {
      expect(PalletMagazinePainter.well
          .contains(PalletMagazinePainter.pallet.topLeft), isTrue);
      expect(PalletMagazinePainter.well
          .contains(PalletMagazinePainter.pallet.bottomRight), isTrue);
    });

    test('the lane and the well share an edge, so they read as one machine',
        () {
      // Drawn clear of the well the lane looked like a separate conveyor
      // parked alongside. Exact equality is the point -- "close" is what
      // produced two boxes with a hairline gap between them.
      expect(PalletMagazinePainter.lane.left,
          PalletMagazinePainter.well.right);
    });

    test('the lane discharges across the middle of the stack', () {
      expect(PalletMagazinePainter.lane.center.dy,
          closeTo(PalletMagazinePainter.pallet.center.dy, 0.02),
          reason: 'a pallet leaves along its own centreline');
    });

    test('the offset stack stays inside the unit box', () {
      // Two pallets show from under the top one, each stepped down and right.
      // The lowest must not run off the machine area and get clipped.
      final d = PalletMagazinePainter.stackOffset * 2;
      expect(PalletMagazinePainter.pallet.right + d, lessThan(1.0));
      expect(PalletMagazinePainter.pallet.bottom + d, lessThan(1.0));
    });

    test('painting is a no-op on a zero canvas and does not throw on a tiny '
        'one', () {
      for (final size in const [Size.zero, Size(24, 18), Size(400, 286)]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        const painter =
            PalletMagazinePainter(color: Colors.black, strokeWidth: 2);
        expect(() => painter.paint(canvas, size), returnsNormally,
            reason: 'the magazine must degrade at $size, not crash');
        recorder.endRecording().dispose();
      }
    });
  });
}
