import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/alarm_visibility.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/lid_inspection.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/nav_alarm.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc_dart/core/alarm.dart';

import 'alarm_visibility_config_test.dart' show activeFx;

LidInspectionLive _live({
  double? score = 0.31,
  double threshold = 0.62,
  bool? anomaly = false,
  bool? armed = true,
  bool? cameraOk = true,
  Map<LidNode, String> errors = const {},
}) {
  return LidInspectionLive(
    values: {
      if (score != null) LidNode.score: DynamicValue(value: score),
      LidNode.threshold: DynamicValue(value: threshold),
      if (anomaly != null) LidNode.anomaly: DynamicValue(value: anomaly),
      if (armed != null) LidNode.armed: DynamicValue(value: armed),
      if (cameraOk != null) LidNode.cameraOk: DynamicValue(value: cameraOk),
    },
    errors: errors,
  );
}

void main() {
  group('LidInspectionConfig JSON', () {
    test('round-trips its own fields and the inherited beacon fields', () {
      final config = LidInspectionConfig(
        keyPrefix: 'LID01',
        camera: 'cam-a',
        recentLimit: 5,
        trainingBatch: 30,
        alarmUids: ['lid-anomaly:LID01'],
        announceInNavigation: false,
      )
        ..text = 'Lid camera'
        ..coordinates = Coordinates(x: 0.4, y: 0.5, angle: 0);

      final json = config.toJson();
      expect(json['asset_name'], 'LidInspectionConfig');
      expect(json['key_prefix'], 'LID01');
      expect(json['camera'], 'cam-a');
      expect(json['recent_limit'], 5);
      expect(json['training_batch'], 30);
      expect(json['alarm_uids'], ['lid-anomaly:LID01']);
      expect(json['announce_in_navigation'], isFalse);

      final back = LidInspectionConfig.fromJson(json);
      expect(back.keyPrefix, 'LID01');
      expect(back.camera, 'cam-a');
      expect(back.recentLimit, 5);
      expect(back.trainingBatch, 30);
      expect(back.alarmUids, ['lid-anomaly:LID01']);
      expect(back.announceInNavigation, isFalse);
      expect(back.text, 'Lid camera');
      expect(back.coordinates.x, 0.4);
    });

    test('defaults: empty prefix, camera follows prefix, 8 recent, 20 per '
        'collect, announces, no alarms bound', () {
      final config = LidInspectionConfig.fromJson({
        'asset_name': 'LidInspectionConfig',
        'coordinates': {'x': 0.1, 'y': 0.1, 'angle': 0},
        'size': {'width': 0.1, 'height': 0.1},
      });
      expect(config.keyPrefix, '');
      expect(config.camera, '');
      expect(config.recentLimit, 8);
      expect(config.trainingBatch, 20);
      expect(config.alarmUids, isEmpty);
      expect(config.announceInNavigation, isTrue);
    });

    test('the registry parses it back as this type, not the beacon', () {
      final config = LidInspectionConfig(keyPrefix: 'LID02');
      final parsed = AssetRegistry.parse({
        'assets': [config.toJson()],
      });
      expect(parsed, hasLength(1));
      expect(parsed.single, isA<LidInspectionConfig>());
      expect((parsed.single as LidInspectionConfig).keyPrefix, 'LID02');
    });

    test('the palette has a preview instance with sample figures', () {
      final preview = AssetRegistry.createDefaultAsset(LidInspectionConfig);
      expect(preview, isA<LidInspectionConfig>());
      expect((preview as LidInspectionConfig).isPreview, isTrue);
      expect(preview.keyPrefix, 'LID01');
    });

    test('is a beacon: navigation pulse discovers it by type', () {
      final tile = LidInspectionConfig(
          keyPrefix: 'LID01', alarmUids: ['lid-anomaly:LID01']);
      final page = AssetPage(
        menuItem: MenuItem(label: 'Packing', path: '/packing', icon: Icons.abc),
        assets: [tile],
        mirroringDisabled: false,
      );
      final levels = navigationAlarmLevels(
        pages: {'/packing': page},
        active: [activeFx(uid: 'lid-anomaly:LID01')],
      );
      expect(levels, {'/packing': AlarmLevel.error});

      tile.announceInNavigation = false;
      expect(
          navigationAlarmLevels(
            pages: {'/packing': page},
            active: [activeFx(uid: 'lid-anomaly:LID01')],
          ),
          isEmpty);
    });
  });

  group('Keys and camera', () {
    test('every node key is prefix.suffix', () {
      final config = LidInspectionConfig(keyPrefix: 'LID01');
      expect(config.key(LidNode.score), 'LID01.Score');
      expect(config.key(LidNode.command), 'LID01.Command');
      for (final node in LidNode.values) {
        expect(config.key(node), startsWith('LID01.'));
      }
    });

    test('cameraId falls back to the prefix', () {
      expect(LidInspectionConfig(keyPrefix: 'LID01').cameraId, 'LID01');
      expect(LidInspectionConfig(keyPrefix: 'LID01', camera: 'east').cameraId,
          'east');
    });

    test('title prefers the label, then the prefix, then a generic name', () {
      expect(LidInspectionConfig().title, 'Lid inspection');
      expect(LidInspectionConfig(keyPrefix: 'LID01').title, 'LID01');
      expect((LidInspectionConfig(keyPrefix: 'LID01')..text = 'Lids').title,
          'Lids');
    });

    test('Command is write-only; everything else is subscribed', () {
      expect(LidNode.command.subscribed, isFalse);
      expect(LidNode.command.writable, isTrue);
      expect(
          LidNode.values.where((n) => n.subscribed).length,
          LidNode.values.length - 1);
      expect(LidNode.values.where((n) => n.writable).map((n) => n.suffix),
          ['Threshold', 'Armed', 'Command']);
    });

    test('commands are the strings the service parses', () {
      expect(LidCommand.collect(20), 'collect:20');
      expect(LidCommand.train, 'train');
      expect(LidCommand.reload, 'reload');
    });
  });

  group('State', () {
    test('a failed Score subscription is unavailable, whatever else says', () {
      final live = _live(anomaly: true, errors: {LidNode.score: 'not mapped'});
      expect(lidInspectionState(live), LidInspectionState.unavailable);
    });

    test('no Score value yet is connecting', () {
      expect(lidInspectionState(_live(score: null)),
          LidInspectionState.connecting);
      expect(lidInspectionState(const LidInspectionLive()),
          LidInspectionState.connecting);
    });

    test('CameraOk false is offline, even mid-anomaly', () {
      expect(lidInspectionState(_live(anomaly: true, cameraOk: false)),
          LidInspectionState.offline);
    });

    test('armed: anomaly / ok', () {
      expect(lidInspectionState(_live(anomaly: true)),
          LidInspectionState.anomaly);
      expect(lidInspectionState(_live()), LidInspectionState.ok);
    });

    test('shadow: anomaly is recorded but flagged as shadow', () {
      expect(lidInspectionState(_live(anomaly: true, armed: false)),
          LidInspectionState.shadowAnomaly);
      expect(lidInspectionState(_live(armed: false)),
          LidInspectionState.shadow);
    });

    test('an absent Armed node counts as armed', () {
      expect(lidInspectionState(_live(anomaly: true, armed: null)),
          LidInspectionState.anomaly);
    });

    test('captions carry the verdict and the score', () {
      expect(lidInspectionTileCaption(LidInspectionState.ok, _live()),
          'OK 0.31');
      expect(
          lidInspectionTileCaption(
              LidInspectionState.anomaly, _live(score: 0.87, anomaly: true)),
          'ANOMALY 0.87');
      expect(
          lidInspectionTileCaption(LidInspectionState.shadowAnomaly,
              _live(score: 0.87, anomaly: true, armed: false)),
          'Shadow · anomaly 0.87');
      expect(lidInspectionTileCaption(LidInspectionState.offline, _live()),
          'Camera offline');
      expect(
          lidInspectionTileCaption(
              LidInspectionState.connecting, const LidInspectionLive()),
          'Connecting…');
    });

    test('pane chips: only an armed anomaly is a fault', () {
      expect(lidInspectionPaneStatus(LidInspectionState.anomaly),
          const PaneStatus.fault('Anomaly'));
      expect(lidInspectionPaneStatus(LidInspectionState.shadowAnomaly),
          const PaneStatus.warning('Anomaly (shadow)'));
      expect(lidInspectionPaneStatus(LidInspectionState.shadow),
          const PaneStatus.warning('Shadow mode'));
      expect(lidInspectionPaneStatus(LidInspectionState.ok),
          const PaneStatus.running('OK'));
      expect(lidInspectionPaneStatus(LidInspectionState.offline),
          const PaneStatus.stale('Camera offline'));
    });

    test('typed getters read the dynamic values, null when absent or null',
        () {
      final live = LidInspectionLive(values: {
        LidNode.score: DynamicValue(value: 0.5),
        LidNode.goodSamples: DynamicValue(value: 12),
        LidNode.lidType: DynamicValue(value: ''),
        LidNode.trainingState: DynamicValue(value: 'training'),
        LidNode.armed: DynamicValue(value: null),
      });
      expect(live.score, 0.5);
      expect(live.goodSamples, 12);
      expect(live.lidType, isNull, reason: 'empty string reads as absent');
      expect(live.trainingState, 'training');
      expect(live.armed, isNull);
      expect(live.threshold, isNull);
    });
  });

  group('Anomaly alarm', () {
    test('formula ANDs Anomaly with Armed so shadow mode is silent', () {
      final config = LidInspectionConfig(keyPrefix: 'LID01')..text = 'Lids';
      final alarm = lidAnomalyAlarmConfig(config);
      expect(alarm.uid, 'lid-anomaly:LID01');
      expect(alarm.title, 'Lids: lid anomaly');
      expect(alarm.rules, hasLength(1));
      final rule = alarm.rules.single;
      expect(rule.level, AlarmLevel.error);
      expect(rule.acknowledgeRequired, isTrue,
          reason: 'one bad lid must stay on screen until someone looked');
      expect(rule.expression.value.formula, 'LID01.Anomaly AND LID01.Armed');
      expect(rule.expression.value.extractVariables(),
          unorderedEquals(['LID01.Anomaly', 'LID01.Armed']));
      expect(alarm.countsAsStop, isFalse,
          reason: 'a bad lid does not stop the line');
    });

    test('the uid is stable per prefix, so re-creating updates not adds', () {
      expect(lidAnomalyAlarmUid('LID01'), lidAnomalyAlarmUid('LID01'));
      expect(lidAnomalyAlarmUid('LID01'), isNot(lidAnomalyAlarmUid('LID02')));
    });
  });

  group('Setup help', () {
    test('names every node with the operator\'s own prefix', () {
      final help =
          lidInspectionSetupHelp(LidInspectionConfig(keyPrefix: 'LID07'));
      for (final node in LidNode.values) {
        expect(help, contains('LID07.${node.suffix}'),
            reason: 'help must list ${node.suffix}');
        expect(help, contains(node.meaning));
      }
      expect(help, contains('written by the HMI'));
    });

    test('shows a placeholder prefix until one is typed', () {
      final help = lidInspectionSetupHelp(LidInspectionConfig());
      expect(help, contains('LID01.Score'));
    });

    test('covers the alarm formula, the table, the dataset folder and the '
        'training commands', () {
      final help = lidInspectionSetupHelp(
          LidInspectionConfig(keyPrefix: 'LID01', trainingBatch: 25));
      expect(help, contains('LID01.Anomaly AND LID01.Armed'));
      expect(help, contains('lid_inspection'));
      expect(help, contains('/data/models/<lid type>/dataset/good/'));
      expect(help, contains('Collect 25 good lids'));
      expect(help, contains('Train model'));
      expect(help, contains('Reload model'));
      expect(help, contains('shadow mode'));
      expect(help, contains('docs/lid-inspection.md'));
    });
  });

  test('the beacon helpers apply unchanged', () {
    // The subclass reuses the beacon's alarm matching; a tile bound to one
    // uid ignores another alarm.
    final matched = matchingActiveAlarms(
      [activeFx(uid: 'lid-anomaly:LID01'), activeFx(uid: 'other')],
      LidInspectionConfig(keyPrefix: 'LID01', alarmUids: ['lid-anomaly:LID01'])
          .alarmUids,
    );
    expect(matched.map((a) => a.alarm.config.uid), ['lid-anomaly:LID01']);
  });
}
