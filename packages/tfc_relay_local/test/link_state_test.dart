/// The link-state handler is about the TRANSITION, and it must reach every
/// subscribed key rather than every cached one.
///
/// Two 08-REVIEW findings, both of which leave a key claiming something the
/// link cannot support.
///
/// **WR-06 — handle the event you were handed.** The subscription dropped the
/// emitted state and the handler re-read `link.state`. Broadcast delivery is
/// asynchronous, so two transitions raised in one synchronous run arrive at a
/// handler that reads the *final* state twice: a link that dropped and came
/// back is handled as "connected, connected", `applyLinkLoss` never runs, and
/// `applyLinkRestored` then finds nothing degraded to relabel. The keys keep
/// `Quality.good` across a link that went away. `announceLinkState` had the
/// mirror of it — announcing the state at handler time, so a client could
/// receive two identical frames and never the one that changed.
///
/// **WR-13 — a key nobody has heard from yet is still on the link.** The mass
/// degradation walked the *cache*, and a key with a monitored item that has
/// not yet produced a sample is in neither the cache nor the store's values.
/// Losing the link staged nothing for it, so its subscriber sat at
/// `uncertainNotYetKnown` — "waiting does fix it" — for a link that is down.
/// The window is small on a healthy plant and unbounded on a tag whose PLC
/// never came up at all, which is exactly when somebody is looking at it.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

({LocalStateMan man, FakeUpstreamLink link}) build() {
  const keys = <String>[st101Key, st201Key];
  final link = FakeUpstreamLink(alias: st101Alias, keys: keys);
  final man = LocalStateMan(
    links: <UpstreamLink>[link],
    router: KeyRouter.overLinks(
      <UpstreamLink>[link],
      mappings: keyMappingsOf(keys, alias: st101Alias),
    ),
    staleAfter: const Duration(seconds: 30),
  );
  return (man: man, link: link);
}

/// Lets the broadcast stream deliver everything queued.
Future<void> settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('WR-06: two transitions in one turn are two transitions', () {
    test('a drop and a return raised in the same synchronous run leaves the '
        'keys uncertain, never good', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();
      await settle();

      // Seeded through the composer's own ingest seam rather than through the
      // link's feed, deliberately: the fake degrades its own cache on
      // disconnect and would publish that down a subscribed feed, which is a
      // second path to the right answer and would hide whether the handler
      // did its job.
      built.man.applyUpstreamBatch(
          <String, DynamicValue>{st101Key: DynamicValue(value: 41.5)});
      expect(built.man.read(st101Key)!.quality, Quality.good);

      // Both raised before the event loop turns — two `EffectiveDeviceStatus`
      // events in one run is the ordinary shape of a flap.
      built.link.disconnectUpstream();
      built.link.reconnectUpstream();
      await settle();

      final ended = built.man.read(st101Key)!;
      expect(ended.quality, isNot(Quality.good),
          reason: 'the link went down and came back. A value that kept its '
              'good quality across that has been vouched for by nothing — it '
              'is the stale-but-plausible reading this project exists to '
              'prevent, arriving because the handler asked the link what state '
              'it was in NOW instead of reading the event it was handed');
      expect(ended.quality, Quality.uncertainLastKnown,
          reason: 'and the honest label is the reconnect one: the number is '
              'the last thing anybody measured, and it is good again only once '
              'it has been re-read');
      expect(ended.value, 41.5);
    });

    test('the announcement carries the state that changed, not the state at '
        'handler time', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();
      await settle();

      final announced = <String>[];
      final watch = built.man.statusStream.listen((s) => announced.add(s.state));
      addTearDown(watch.cancel);

      built.link.disconnectUpstream();
      built.link.reconnectUpstream();
      await settle();

      expect(announced, <String>['disconnected', 'connected'],
          reason: 'a client that receives two identical frames and never the '
              'one that changed cannot tell a flap from a link that was always '
              'up. The frame is about a transition, so it has to carry the '
              'transition');
    });

    test('a single transition still announces exactly once, however many keys '
        'it cost', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();
      await settle();

      built.man.applyUpstreamBatch(<String, DynamicValue>{
        for (var i = 0; i < 20; i++) '$st101Key.$i': DynamicValue(value: i),
        st101Key: DynamicValue(value: 1),
      });
      final before = built.man.statusNotifications;

      built.link.disconnectUpstream();
      await settle();

      expect(built.man.statusNotifications - before, 1,
          reason: 'at fifteen hundred keys, one event per key is a denial of '
              'service against the operator\'s own screen delivered by their '
              'own gateway at the worst possible moment');
    });
  });

  group('WR-13: a key that has never delivered still degrades on link loss',
      () {
    test('a subscriber waiting for its first sample is told the link is down, '
        'not to keep waiting', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();
      await settle();

      // Subscribed, and nothing has ever arrived for it: the node exists and
      // holds no value, which is the state a tag whose PLC never came up sits
      // in indefinitely.
      final seen = <Quality>[];
      final watch = built.man.subscribe(st101Key).listen((v) => seen.add(v.quality));
      addTearDown(watch.cancel);
      await settle();
      expect(built.man.read(st101Key)?.value, isNull,
          reason: 'anti-vacuity: nothing may have arrived for it');

      built.link.disconnectUpstream();
      await settle();

      expect(built.man.read(st101Key)!.quality, Quality.badCommFault,
          reason: 'uncertainNotYetKnown means "waiting does fix it", and for a '
              'link that is down that is the wrong instruction. _onUpstreamEnded '
              'already stages a null-valued badCommFault for the stream-ended '
              'case, so the shape was established — applyLinkLoss just skipped '
              'the key instead');
      expect(built.man.read(st101Key)!.value, isNull,
          reason: 'and never a zero and never a false: nothing was measured');
      expect(seen, contains(Quality.badCommFault),
          reason: 'the subscriber has to be TOLD, not merely be able to poll '
              'for it');
    });

    test('and it comes back as not-yet-known rather than last-known, because '
        'there is no last known', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();
      await settle();

      final watch = built.man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);
      await settle();

      built.link.disconnectUpstream();
      await settle();
      built.link.reconnectUpstream();
      await settle();

      expect(built.man.read(st101Key)!.quality, Quality.uncertainNotYetKnown,
          reason: 'uncertainLastKnown on a key with no value would name a '
              'reading that does not exist. Waiting genuinely does fix this '
              'one now that the link is back');
    });
  });
}
