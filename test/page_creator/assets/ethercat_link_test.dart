import 'dart:ui';

import 'package:flutter/material.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/ethercat_link_painter.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/page_creator/assets/registry.dart';

class _Box extends BaseAsset {
  _Box({double x = 0.5, double y = 0.5, double w = 0.1, double h = 0.06}) {
    coordinates = Coordinates(x: x, y: y);
    size = RelativeSize(width: w, height: h);
  }

  @override
  Widget build(context) => throw UnimplementedError();
  @override
  Widget configure(context) => throw UnimplementedError();
  @override
  Map<String, dynamic> toJson() => const {};
}

/// A struct value shaped like `ST_EtherCATLink_HMI`.
DynamicValue struct({
  bool linkUp = true,
  bool communicating = true,
  bool degraded = false,
  bool stale = false,
  int connectedMinutes = 0,
  int connectCount = 1,
  int crcErrors = 0,
  int? errorsLastHour,
}) {
  final v = DynamicValue(value: {
    LinkFields.linkUp: DynamicValue(value: linkUp),
    LinkFields.communicating: DynamicValue(value: communicating),
    LinkFields.degraded: DynamicValue(value: degraded),
    LinkFields.stale: DynamicValue(value: stale),
    LinkFields.connectedMinutes: DynamicValue(value: connectedMinutes),
    LinkFields.connectCount: DynamicValue(value: connectCount),
    LinkFields.crcErrors: DynamicValue(value: crcErrors),
    if (errorsLastHour != null)
      LinkFields.errorRate: DynamicValue(value: {
        LinkFields.errorRateHour: DynamicValue(value: errorsLastHour),
      }),
  });
  return v;
}

void main() {
  group('decode', () {
    test('reads the struct', () {
      final s = EtherCatLinkState.tryParse(
          struct(connectedMinutes: 4321, connectCount: 7, crcErrors: 12))!;
      expect(s.linkUp, isTrue);
      expect(s.connectedMinutes, 4321);
      expect(s.connectCount, 7);
      expect(s.crcErrors, 12);
    });

    test('a node that is not the struct decodes to null', () {
      // A plain BOOL under the key is somebody's mistake, not a cable. Better
      // to paint "cannot tell" than to guess a health from it.
      expect(EtherCatLinkState.tryParse(DynamicValue(value: true)), isNull);
    });

    test('a struct missing a member degrades instead of throwing', () {
      // DynamicValue.operator[] throws on a missing member, and a PLC running
      // an older revision of the DUT must not take the mimic down.
      final partial = DynamicValue(value: {
        LinkFields.linkUp: DynamicValue(value: true),
      });
      final s = EtherCatLinkState.tryParse(partial);
      expect(s, isNotNull);
      expect(s!.linkUp, isTrue);
      expect(s.crcErrors, 0);
      expect(s.availabilityPct, 0);
    });
  });

  group('rolling error rate', () {
    test('reads the hour window off the nested counter', () {
      // The number that decides whether anybody walks out to the cable.
      final s = EtherCatLinkState.tryParse(
          struct(crcErrors: 4000, errorsLastHour: 12))!;
      expect(s.errorsLastHour, 12);
      expect(s.crcErrors, 4000, reason: 'the lifetime total is separate');
    });

    test('a struct without the counter reads zero rather than throwing', () {
      // An older PLC revision may not carry ST_Counter at all.
      expect(EtherCatLinkState.tryParse(struct())!.errorsLastHour, 0);
    });

    test('a counter without that window reads zero too', () {
      final partial = DynamicValue(value: {
        LinkFields.linkUp: DynamicValue(value: true),
        LinkFields.errorRate: DynamicValue(value: {
          'Minute1': DynamicValue(value: 3),
        }),
      });
      expect(EtherCatLinkState.tryParse(partial)!.errorsLastHour, 0);
    });
  });

  group('health', () {
    test('a clean link is healthy', () {
      expect(EtherCatLinkState.tryParse(struct())!.health, LinkHealth.healthy);
    });

    test('errors above the rate make it degraded, not healthy', () {
      // The case the whole three-state scheme exists for: still up, still
      // passing traffic, and on its way out.
      expect(EtherCatLinkState.tryParse(struct(degraded: true))!.health,
          LinkHealth.degraded);
    });

    test('no link is down, degraded or not', () {
      expect(EtherCatLinkState.tryParse(struct(linkUp: false))!.health,
          LinkHealth.down);
      expect(
          EtherCatLinkState.tryParse(struct(linkUp: false, degraded: true))!
              .health,
          LinkHealth.down);
    });

    test('stale outranks everything, including a link that reads up', () {
      // Values that are not being updated must not be reported as facts. A
      // cable whose diagnostics stopped arriving looks perfectly healthy in
      // the struct, which is exactly why this has to win.
      expect(EtherCatLinkState.tryParse(struct(stale: true))!.health,
          LinkHealth.unknown);
      expect(
          EtherCatLinkState.tryParse(struct(stale: true, linkUp: false))!
              .health,
          LinkHealth.unknown);
    });
  });

  group('d:h:m formatting', () {
    test('under a day drops the day part', () {
      expect(formatDaysHoursMinutes(0), '00:00');
      expect(formatDaysHoursMinutes(5), '00:05');
      expect(formatDaysHoursMinutes(65), '01:05');
      expect(formatDaysHoursMinutes(1439), '23:59');
    });

    test('a day and over carries it', () {
      expect(formatDaysHoursMinutes(1440), '1d 00:00');
      expect(formatDaysHoursMinutes(1445), '1d 00:05');
      expect(formatDaysHoursMinutes(4321), '3d 00:01');
    });

    test('runs past what a TIME could have held', () {
      // 49.7 days is where a 32-bit millisecond TIME saturates, which is why
      // the PLC counts minutes. A cable in since commissioning reads its real
      // age rather than everything pinning at the same ceiling.
      expect(formatDaysHoursMinutes(100 * 1440), '100d 00:00');
      expect(formatDaysHoursMinutes(900 * 1440 + 61), '900d 01:01');
    });

    test('a negative count reads as zero rather than nonsense', () {
      expect(formatDaysHoursMinutes(-5), '00:00');
    });
  });

  group('config', () {
    test('round-trips through JSON with its run', () {
      final cfg = EtherCatLinkConfig(
        key: 'ST301.link1',
        run: LinkRun(
          from: LinkEnd(assetId: 'ek', port: 'X2'),
          to: LinkEnd(assetId: 'ep', port: 'X1'),
          waypoints: [
            LinkWaypoint.onRun(0.4, -0.2),
            LinkWaypoint.pinned('ek', 0.03, 0.01),
          ],
          radius: 0.04,
        ),
      );
      cfg.variant = 'EtherCatLinkConfig';

      final back = EtherCatLinkConfig.fromJson(cfg.toJson());
      expect(back.key, 'ST301.link1');
      expect(back.run.from.assetId, 'ek');
      expect(back.run.to.port, 'X1');
      expect(back.run.waypoints, hasLength(2));
      expect(back.run.waypoints[1].pinnedTo, 'ek');
      expect(back.run.radius, 0.04);
    });

    test('survives the registry, which is what a page load uses', () {
      final cfg = EtherCatLinkConfig(key: 'k');
      cfg.variant = 'EtherCatLinkConfig';
      final parsed = AssetRegistry.parse({
        'assets': [cfg.toJson()]
      });
      expect(parsed.single, isA<EtherCatLinkConfig>());
      expect((parsed.single as EtherCatLinkConfig).key, 'k');
    });

    test('mirrors with the page, because a bend is chiral', () {
      // Without this the stack skips the flip and a mirrored station shows a
      // cable bending a way it does not bend on the floor.
      expect(EtherCatLinkConfig().mirrorsWithPage, isTrue);
    });

    test('reports the assets it depends on', () {
      final cfg = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: 'a', port: 'X2'),
          to: LinkEnd(assetId: 'b', port: 'X1'),
          waypoints: [LinkWaypoint.pinned('a', 0, 0)],
        ),
      );
      expect(cfg.referencedAssetIds, ['a', 'b', 'a']);
    });
  });

  group('paste remapping', () {
    test('both ends and every pin follow the copies', () {
      final cfg = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: 'old-a', port: 'X2'),
          to: LinkEnd(assetId: 'old-b', port: 'X1'),
          waypoints: [LinkWaypoint.pinned('old-a', 0.01, 0.02)],
        ),
      );
      cfg.remapAssetIds({'old-a': 'new-a', 'old-b': 'new-b'});
      expect(cfg.run.from.assetId, 'new-a');
      expect(cfg.run.to.assetId, 'new-b');
      expect(cfg.run.waypoints.single.pinnedTo, 'new-a');
    });

    test('an end outside the pasted group keeps pointing at the original', () {
      // Copy a cable on its own and it still runs where it ran.
      final cfg = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: 'still-there', port: 'X2'),
          to: LinkEnd(assetId: 'old-b', port: 'X1'),
        ),
      );
      cfg.remapAssetIds({'old-b': 'new-b'});
      expect(cfg.run.from.assetId, 'still-there');
      expect(cfg.run.to.assetId, 'new-b');
    });

    test('a free end is untouched', () {
      final cfg = EtherCatLinkConfig(
        run:
            LinkRun(from: LinkEnd(x: 0.2, y: 0.3), to: LinkEnd(x: 0.8, y: 0.7)),
      );
      cfg.remapAssetIds({'anything': 'else'});
      expect(cfg.run.from.assetId, isNull);
      expect(cfg.run.from.x, 0.2);
    });
  });

  group('boxOn', () {
    const canvas = Size(1000, 600);

    test('a run takes its box from the devices it plugs into', () {
      final a = _Box(x: 0.2, y: 0.3)..ensureId();
      final b = _Box(x: 0.7, y: 0.8)..ensureId();
      final cfg = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: a.id, port: 'X2'),
          to: LinkEnd(assetId: b.id, port: 'X1'),
        ),
        thickness: 0.01,
      );

      final box = cfg.boxOn([a, b, cfg], canvas)!;
      // X2 on `a` is its right face; X1 on `b` its left.
      expect(box.left, closeTo(0.25 - 0.01, 1e-9));
      expect(box.right, closeTo(0.65 + 0.01, 1e-9));
      expect(box.top, closeTo(0.3 - 0.01, 1e-9));
      expect(box.bottom, closeTo(0.8 + 0.01, 1e-9));
    });

    test('the box follows a device that moved', () {
      final a = _Box(x: 0.2, y: 0.3)..ensureId();
      final b = _Box(x: 0.7, y: 0.8)..ensureId();
      final cfg = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: a.id, port: 'X2'),
          to: LinkEnd(assetId: b.id, port: 'X1'),
        ),
      );
      final before = cfg.boxOn([a, b], canvas)!;
      a.coordinates = Coordinates(x: 0.05, y: 0.05);
      final after = cfg.boxOn([a, b], canvas)!;
      expect(after.left, lessThan(before.left));
      expect(after.top, lessThan(before.top));
    });

    test('a corner outside the two ends is still inside the box', () {
      final a = _Box(x: 0.2, y: 0.5)..ensureId();
      final b = _Box(x: 0.8, y: 0.5)..ensureId();
      final cfg = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: a.id, port: 'X2'),
          to: LinkEnd(assetId: b.id, port: 'X1'),
          waypoints: [LinkWaypoint.onRun(0.5, -0.4)],
        ),
      );
      final box = cfg.boxOn([a, b], canvas)!;
      for (final p
          in cfg.run.resolve(canvas, PageLinkAnchors([a, b], canvas)).points) {
        expect(box.contains(Offset(p.dx / canvas.width, p.dy / canvas.height)),
            isTrue);
      }
    });

    test('every other asset still sits where it was dropped', () {
      // boxOn is additive: nothing but a run may answer it.
      expect(_Box().boxOn(const [], canvas), isNull);
    });

    test('a zero canvas does not produce a nonsense box', () {
      expect(EtherCatLinkConfig().boxOn(const [], Size.zero), isNull);
    });
  });
}
