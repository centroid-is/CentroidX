/// Golden of the alarm list, for design review of the two changes to it: the
/// level quick-filter under the search bar, and the "Still active" row a
/// standing alarm now gets in History.
///
/// The chips carry the alarm palette, which is deliberately the same under
/// both themes — an info alarm must not change colour with the operator's
/// theme — so the goldens are also the check that a selected chip's label
/// stays readable on signal yellow and on Solarized red.
///
/// To update:
///   flutter test test/widgets/alarm_list_golden_test.dart \
///     --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/alarm.dart' show ListActiveAlarms, ViewActiveAlarm;
import 'package:tfc_dart/core/alarm.dart';

import 'alarm_fixture.dart';

AlarmFixture _plant() => AlarmFixture(
      active: {
        alarm('Motor overload',
            level: AlarmLevel.error, at: DateTime(2026, 8, 29, 8, 15)),
        alarm('Belt drifting',
            level: AlarmLevel.warning, at: DateTime(2026, 8, 29, 7, 42)),
        alarm('Shift started',
            level: AlarmLevel.info, at: DateTime(2026, 8, 29, 6, 0)),
      },
      past: [
        alarm('Line stopped',
            level: AlarmLevel.warning,
            at: DateTime(2026, 8, 28, 6, 10),
            ended: DateTime(2026, 8, 28, 6, 55)),
        alarm('Freezer door',
            level: AlarmLevel.error,
            at: DateTime(2026, 8, 28, 5, 0),
            ended: DateTime(2026, 8, 28, 5, 4)),
      ],
    );

/// The rig's cooler alarm as the panel now renders it: held true on a stale
/// input since 12 seconds after onset.
AlarmActive _cooler() => alarm(
      'Cooler temperature',
      level: AlarmLevel.warning,
      at: DateTime(2026, 9, 8, 19, 18, 4),
      staleInputs: const ['cooler.temp.avg'],
      staleSince: DateTime(2026, 9, 8, 19, 18, 16),
    );

AlarmFixture _held() => AlarmFixture(
      active: {
        _cooler(),
        alarm('Motor overload',
            level: AlarmLevel.error, at: DateTime(2026, 9, 8, 8, 15)),
      },
    );

/// Real glyphs — without this the list captures as placeholder boxes.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  // Without this the Active/History toggle and the search field capture as
  // empty boxes, and the bar under review is half unreadable.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

void main() {
  setUpAll(_loadFonts);

  group('alarm list golden',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('history, standing alarms on top — light', (tester) async {
      await pumpAlarmList(tester, _plant());
      await showHistory(tester);

      await expectLater(
        find.byType(ListActiveAlarms),
        matchesGoldenFile('goldens/alarm_list_history.png'),
      );
    });

    testWidgets('history, with the standing alarms on top — dark',
        (tester) async {
      await pumpAlarmList(tester, _plant(), dark: true);
      await showHistory(tester);

      await expectLater(
        find.byType(ListActiveAlarms),
        matchesGoldenFile('goldens/alarm_list_history_dark.png'),
      );
    });

    testWidgets('the error chip selected — light', (tester) async {
      await pumpAlarmList(tester, _plant());
      await tapLevelChip(tester, AlarmLevel.error);

      await expectLater(
        find.byType(ListActiveAlarms),
        matchesGoldenFile('goldens/alarm_list_error_filter.png'),
      );
    });

    testWidgets('every chip selected, for the label-on-fill contrast',
        (tester) async {
      await pumpAlarmList(tester, _plant());
      for (final level in AlarmLevel.values) {
        await tapLevelChip(tester, level);
      }

      await expectLater(
        find.byType(ListActiveAlarms),
        matchesGoldenFile('goldens/alarm_list_all_levels_selected.png'),
      );
    });

    // The D-3 hold badge, in both themes: the row must read as "check this
    // sensor", not as one more line of timestamp grey, and the bold badge
    // must stay legible on the warning fill in light and dark alike (the
    // rig-measured cooler defect, 2026-09-08).
    testWidgets('a held alarm names its dead input in the list — light',
        (tester) async {
      await pumpAlarmList(tester, _held());

      await expectLater(
        find.byType(ListActiveAlarms),
        matchesGoldenFile('goldens/alarm_list_held_input.png'),
      );
    });

    testWidgets('a held alarm names its dead input in the list — dark',
        (tester) async {
      await pumpAlarmList(tester, _held(), dark: true);

      await expectLater(
        find.byType(ListActiveAlarms),
        matchesGoldenFile('goldens/alarm_list_held_input_dark.png'),
      );
    });

    testWidgets('the detail card states the hold and its consequence — light',
        (tester) async {
      await pumpAlarmDetail(tester, _cooler());

      await expectLater(
        find.byType(ViewActiveAlarm),
        matchesGoldenFile('goldens/alarm_detail_held_input.png'),
      );
    });

    testWidgets('the detail card states the hold and its consequence — dark',
        (tester) async {
      await pumpAlarmDetail(tester, _cooler(), dark: true);

      await expectLater(
        find.byType(ViewActiveAlarm),
        matchesGoldenFile('goldens/alarm_detail_held_input_dark.png'),
      );
    });
  });
}
