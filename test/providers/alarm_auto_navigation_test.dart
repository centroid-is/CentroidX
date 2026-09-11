/// The policy behind "take me to the alarm".
///
/// [AlarmAutoNavigator] is deliberately free of Flutter and Riverpod so that
/// the rules — what counts as a raise, who preempts whom, when a jump is
/// refused — are stated here as plain calls rather than pumped through a
/// widget tree. The wiring that feeds it is proven in
/// `test/widgets/alarm_auto_navigation_end_to_end_test.dart`.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/alarm_visibility.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/alarm_auto_navigation.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

AlarmActive activeFx({
  String uid = 'a1',
  AlarmLevel level = AlarmLevel.error,
}) {
  final rule = AlarmRule(
    level: level,
    expression: ExpressionConfig(value: Expression(formula: 'x')),
    acknowledgeRequired: false,
  );
  return AlarmActive(
    alarm: Alarm(
      config: AlarmConfig(
        uid: uid,
        title: 'Alarm $uid',
        description: 'desc',
        rules: [rule],
      ),
    ),
    notification: AlarmNotification(
      uid: uid,
      active: true,
      expression: 'x',
      rule: rule,
      timestamp: DateTime(2026, 1, 1),
    ),
  );
}

AssetPage pageFx(String path, List<Asset> assets) => AssetPage(
      menuItem: MenuItem(label: path, path: path, icon: Icons.abc),
      assets: assets,
      mirroringDisabled: false,
    );

AlarmVisibilityConfig beacon(List<String> uids, {bool announce = true}) =>
    AlarmVisibilityConfig(alarmUids: uids, announceInNavigation: announce);

final _pages = <String, AssetPage>{
  '/': pageFx('/', const []),
  '/freezer': pageFx('/freezer', [beacon(['a1'])]),
  '/packing': pageFx('/packing', [beacon(['a2'])]),
};

/// A navigator already past its settle window, primed on an empty plant —
/// the state the app is in when an operator is standing at a quiet panel.
AlarmAutoNavigator quietNavigator({
  Map<String, AssetPage>? pages,
  Duration settle = Duration.zero,
}) {
  final navigator = AlarmAutoNavigator(settle: settle);
  navigator.onActive(const [], pages: pages ?? _pages, enabled: true);
  return navigator;
}

/// The common case: everything reachable, standing on Home, nothing vetoed.
AlarmNavigationTarget? takeFromHome(AlarmAutoNavigator navigator) =>
    navigator.take(
      currentPath: '/',
      canOpen: (_) => true,
      suppressed: false,
    );

void main() {
  group('raising', () {
    test('an alarm raising on a beacon page navigates there', () {
      final navigator = quietNavigator();
      expect(
        navigator.onActive([activeFx(uid: 'a1')],
            pages: _pages, enabled: true),
        isTrue,
      );
      expect(takeFromHome(navigator)?.path, '/freezer');
    });

    test('an alarm that stays active does not navigate twice', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1')], pages: _pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer');

      // Same alarm, still on. The operator has since walked back to Home;
      // dragging them to the freezer again every time the alarm set is
      // republished would make the panel unusable.
      navigator.onActive([activeFx(uid: 'a1')], pages: _pages, enabled: true);
      expect(takeFromHome(navigator), isNull);
    });

    test('no beacon anywhere means no page to go to', () {
      final navigator = quietNavigator(pages: {'/': pageFx('/', const [])});
      navigator.onActive([activeFx(uid: 'a1')],
          pages: {'/': pageFx('/', const [])}, enabled: true);
      expect(takeFromHome(navigator), isNull);
    });

    test('a beacon with announce off is not a destination', () {
      final pages = {
        '/': pageFx('/', const []),
        '/freezer': pageFx('/freezer', [beacon(['a1'], announce: false)]),
      };
      final navigator = quietNavigator(pages: pages);
      navigator.onActive([activeFx(uid: 'a1')], pages: pages, enabled: true);
      expect(takeFromHome(navigator), isNull,
          reason: 'the switch that silences the navigation pulse silences '
              'the jump — it is the same statement of intent');
    });

    test('the flag off queues nothing', () {
      final navigator = quietNavigator();
      expect(
        navigator.onActive([activeFx(uid: 'a1')],
            pages: _pages, enabled: false),
        isFalse,
      );
      expect(takeFromHome(navigator), isNull);
    });

    test('turning the flag on does not jump for alarms already standing', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1')], pages: _pages, enabled: false);
      // The engineer flips the switch. a1 is still on, and is not news.
      navigator.onActive([activeFx(uid: 'a1')], pages: _pages, enabled: true);
      expect(takeFromHome(navigator), isNull);
    });
  });

  group('settling', () {
    test('alarms standing when the station connects do not navigate', () {
      final start = DateTime(2026, 9, 11, 6);
      final navigator = AlarmAutoNavigator(settle: const Duration(seconds: 15));
      withClock(Clock.fixed(start), () {
        navigator.onActive(const [], pages: _pages, enabled: true);
      });
      // Subscriptions coming up: each true expression fires within seconds of
      // the connection, which is indistinguishable from a plant raising every
      // alarm at once.
      withClock(Clock.fixed(start.add(const Duration(seconds: 2))), () {
        navigator.onActive([activeFx(uid: 'a1')],
            pages: _pages, enabled: true);
      });
      expect(takeFromHome(navigator), isNull);
    });

    test('an alarm raising after the window navigates', () {
      final start = DateTime(2026, 9, 11, 6);
      final navigator = AlarmAutoNavigator(settle: const Duration(seconds: 15));
      withClock(Clock.fixed(start), () {
        navigator.onActive(const [], pages: _pages, enabled: true);
      });
      withClock(Clock.fixed(start.add(const Duration(minutes: 5))), () {
        navigator.onActive([activeFx(uid: 'a1')],
            pages: _pages, enabled: true);
      });
      expect(takeFromHome(navigator)?.path, '/freezer');
    });

    test('resettle reopens the window without forgetting the hold', () {
      final start = DateTime(2026, 9, 11, 6);
      final navigator = AlarmAutoNavigator(settle: const Duration(seconds: 15));
      withClock(Clock.fixed(start), () {
        navigator.onActive(const [], pages: _pages, enabled: true);
      });
      withClock(Clock.fixed(start.add(const Duration(minutes: 5))), () {
        navigator.onActive([activeFx(uid: 'a1')],
            pages: _pages, enabled: true);
      });
      expect(takeFromHome(navigator)?.path, '/freezer');
      expect(navigator.hold?.alarmUid, 'a1');

      // Saving an alarm rebuilds AlarmMan, and every standing alarm is
      // re-raised into the new stream.
      navigator.resettle();
      withClock(Clock.fixed(start.add(const Duration(minutes: 6))), () {
        navigator.onActive(const [], pages: _pages, enabled: true);
        navigator.onActive([activeFx(uid: 'a1')],
            pages: _pages, enabled: true);
      });
      expect(takeFromHome(navigator), isNull,
          reason: 'a re-subscription is not a raise');
    });
  });

  group('preemption', () {
    test('a more severe alarm takes over', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1', level: AlarmLevel.warning)],
          pages: _pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer');

      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.warning),
        activeFx(uid: 'a2', level: AlarmLevel.error),
      ], pages: _pages, enabled: true);
      expect(navigator.take(
              currentPath: '/freezer', canOpen: (_) => true, suppressed: false)
          ?.path,
          '/packing');
    });

    test('an equally severe alarm does not', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1', level: AlarmLevel.error)],
          pages: _pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer');

      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.error),
        activeFx(uid: 'a2', level: AlarmLevel.error),
      ], pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/freezer',
              canOpen: (_) => true,
              suppressed: false),
          isNull);
    });

    test('a less severe alarm does not', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1', level: AlarmLevel.error)],
          pages: _pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer');

      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.error),
        activeFx(uid: 'a2', level: AlarmLevel.info),
      ], pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/freezer',
              canOpen: (_) => true,
              suppressed: false),
          isNull);
    });

    test('the hold releases when its alarm clears, and the next raise moves',
        () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1', level: AlarmLevel.error)],
          pages: _pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer');

      // a1 acknowledged and gone.
      navigator.onActive(const [], pages: _pages, enabled: true);
      expect(navigator.hold, isNull);

      navigator.onActive([activeFx(uid: 'a2', level: AlarmLevel.info)],
          pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/freezer',
              canOpen: (_) => true,
              suppressed: false)
              ?.path,
          '/packing',
          reason: 'nothing holds the screen any more, so an info alarm is '
              'free to claim it');
    });

    test('one alarm escalating warning to error preempts its own jump', () {
      final pages = {
        '/': pageFx('/', const []),
        '/freezer': pageFx('/freezer', [beacon(['a1'])]),
      };
      final navigator = quietNavigator(pages: pages);
      navigator.onActive([activeFx(uid: 'a1', level: AlarmLevel.warning)],
          pages: pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer');

      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.warning),
        activeFx(uid: 'a1', level: AlarmLevel.error),
      ], pages: pages, enabled: true);
      // Nowhere new to go — but the hold rises, which is what stops an
      // unrelated warning elsewhere from stealing the screen next.
      expect(
          navigator.take(
              currentPath: '/freezer',
              canOpen: (_) => true,
              suppressed: false),
          isNull);
      expect(navigator.hold?.level, AlarmLevel.error);
    });

    test('the most severe of a burst wins', () {
      final pages = {
        '/': pageFx('/', const []),
        '/freezer': pageFx('/freezer', [beacon(['a1'])]),
        '/packing': pageFx('/packing', [beacon(['a2'])]),
        '/intake': pageFx('/intake', [beacon(['a3'])]),
      };
      final navigator = quietNavigator(pages: pages);
      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.info),
        activeFx(uid: 'a2', level: AlarmLevel.error),
        activeFx(uid: 'a3', level: AlarmLevel.warning),
      ], pages: pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/packing');
    });
  });

  group('where the operator is standing', () {
    test('no jump when already on the page, but the hold is claimed', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1', level: AlarmLevel.warning)],
          pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/freezer',
              canOpen: (_) => true,
              suppressed: false),
          isNull);
      expect(navigator.hold?.alarmUid, 'a1',
          reason: 'the beacon is flashing in front of them; another warning '
              'elsewhere must not drag them off it');

      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.warning),
        activeFx(uid: 'a2', level: AlarmLevel.warning),
      ], pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/freezer',
              canOpen: (_) => true,
              suppressed: false),
          isNull);
    });

    test('a suppressed jump is dropped, not queued for later', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1')], pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/advanced/page-editor',
              canOpen: (_) => true,
              suppressed: true),
          isNull);
      // The engineer leaves the editor of their own accord. Nothing pounces.
      expect(takeFromHome(navigator), isNull);
      expect(navigator.hold?.alarmUid, 'a1');
    });

    test('a page this session cannot open is not a destination', () {
      final navigator = quietNavigator();
      navigator.onActive([activeFx(uid: 'a1')], pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/',
              canOpen: (path) => path != '/freezer',
              suppressed: false),
          isNull);
      expect(navigator.hold, isNull,
          reason: 'a page the operator cannot reach never held the screen, '
              'so it must not block the next alarm that can');
    });

    test('a locked page does not shadow a reachable one in the same burst',
        () {
      final navigator = quietNavigator();
      navigator.onActive([
        activeFx(uid: 'a1', level: AlarmLevel.error),
        activeFx(uid: 'a2', level: AlarmLevel.info),
      ], pages: _pages, enabled: true);
      expect(
          navigator.take(
              currentPath: '/',
              canOpen: (path) => path != '/freezer',
              suppressed: false)
              ?.path,
          '/packing',
          reason: 'the error is out of reach, so the info alarm the operator '
              'can actually open is what they are shown');
    });
  });

  group('choosing among beacons', () {
    test('a beacon naming the alarm beats a catch-all', () {
      final pages = {
        '/overview': pageFx('/overview', [beacon(const [])]),
        '/freezer': pageFx('/freezer', [beacon(['a1'])]),
      };
      final navigator = quietNavigator(pages: pages);
      navigator.onActive([activeFx(uid: 'a1')], pages: pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/freezer',
          reason: 'an overview page watching everything must not swallow '
              'every alarm in the plant');
    });

    test('a catch-all still answers for an alarm no beacon names', () {
      final pages = {
        '/overview': pageFx('/overview', [beacon(const [])]),
        '/freezer': pageFx('/freezer', [beacon(['a1'])]),
      };
      final navigator = quietNavigator(pages: pages);
      navigator.onActive([activeFx(uid: 'zz')], pages: pages, enabled: true);
      expect(takeFromHome(navigator)?.path, '/overview');
    });
  });
}
