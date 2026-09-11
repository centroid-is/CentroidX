/// SRV-08 with four PLCs on the wire instead of one.
///
/// The contract kit measures the mass degradation over **one** fake upstream
/// link, because `StateManHarness.disconnectUpstream()` takes no alias — it
/// models a source with a single plant behind it, and its two checks
/// (`freshness_contract.dart:210-232` and `:234-265`) are written to that
/// shape. `LocalStateMan` has four links, and SRV-08's wording is *per link*.
/// 08-CONTEXT ruling 8: both legs run, neither substitutes for the other, and
/// this file is the multi-link one.
///
/// The property the contract leg structurally cannot see is the one an operator
/// notices first: **losing ST101 must not grey out ST201's page.** A mimic with
/// half its boxes greyed reads as a plant fault and sends somebody to the wrong
/// end of the building — and if the greying is *wrong*, the wrong end of the
/// building is where they stay.
///
/// Three properties, three ways of getting them wrong, and each way is
/// sabotaged in the summary:
///
///  1. **Isolation** — the alias filter. Drop it and every PLC dies together.
///  2. **One announcement** — degrade and announce are two methods, exactly as
///     `fake_state_man.dart:598-605` keeps them and for its stated reason.
///     Fold the announcement into the per-key loop and one link loss is twenty
///     status events here, fifteen hundred in the plant, arriving in the
///     instant the client is trying to redraw the page they are all about.
///     Sparkplug sends one NDEATH for a whole node for the same reason.
///  3. **The band guard** — a key already at `errorConfig` stages no change.
///     Overwrite it unconditionally and the gateway repaints "this tag is gone"
///     as "the link is down", which tells an operator to wait for something
///     that is never coming back.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, KeyMappings;

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// Twenty keys per station.
///
/// Twenty rather than two because the announcement count is the thing under
/// test and a count of one is indistinguishable from a count of "however many
/// keys there were" when there is one key. Twenty makes the per-key-fan-out
/// sabotage report `20`, which is a number nobody can misread.
const int keysPerStation = 20;

/// `AREAnn.DEVnn.SUBnn` — the convention `keymap_fixtures.dart` documents.
List<String> stationKeys(String station) => <String>[
      for (var i = 1; i <= keysPerStation; i++)
        '$station.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

final List<String> st101Keys = stationKeys('ST101');
final List<String> st201Keys = stationKeys('ST201');

/// Two links, forty keys, one composer over both.
///
/// Both fakes get an **explicit key set**. A `FakeUpstreamLink` built with none
/// claims everything (`fake_upstream_link.dart:144-147`), and the first link
/// declared would then take the second link's keys — which is precisely the
/// trap 08-03 wrote down and 08-04 fell into anyway.
({LocalStateMan man, FakeUpstreamLink st101, FakeUpstreamLink st201})
    buildTwoLinks() {
  final st101 = FakeUpstreamLink(alias: st101Alias, keys: st101Keys);
  final st201 = FakeUpstreamLink(alias: st201Alias, keys: st201Keys);
  final man = LocalStateMan(
    links: <UpstreamLink>[st101, st201],
    router: KeyRouter.overLinks(
      <UpstreamLink>[st101, st201],
      mappings: KeyMappings(nodes: <String, KeyMappingEntry>{
        ...keyMappingsOf(st101Keys, alias: st101Alias).nodes,
        ...keyMappingsOf(st201Keys, alias: st201Alias).nodes,
      }),
    ),
    // Well past anything this file waits for: the freshness sweep is 08-05's
    // and a value quietly going `badStale` mid-case would be indistinguishable
    // from the link loss under test.
    staleAfter: const Duration(seconds: 30),
  );
  return (man: man, st101: st101, st201: st201);
}

/// The seed every arm starts from: forty good values, one per key.
///
/// Applied through the composer's own ingest seam rather than through the
/// links, so the *only* thing that can degrade a key in this file is
/// `LocalStateMan`'s own alias-filtered pass. A fake whose internal cache was
/// also seeded would degrade its own copies on `disconnectUpstream()` and the
/// isolation arm could pass on the fake's behaviour instead of the subject's.
void seedBothStations(LocalStateMan man) => man.applyUpstreamBatch(<String, DynamicValue>{
      for (var i = 0; i < st101Keys.length; i++)
        st101Keys[i]: DynamicValue(value: 10 + i),
      for (var i = 0; i < st201Keys.length; i++)
        st201Keys[i]: DynamicValue(value: 500 + i),
    });

/// Counts notifications per key, on listeners attached **before** the event.
///
/// The technique `checkUpstreamLossAnnouncesOnce` relies on: a counter read
/// after the fact cannot tell one batch from twenty, and a listener attached
/// afterwards sees nothing at all.
final class NotificationCounter {
  NotificationCounter(this.man, Iterable<String> keys) {
    for (final key in keys) {
      final handle = man.listen(key);
      void bump() {
        counts[key] = (counts[key] ?? 0) + 1;
        // Sampled INSIDE the notification, synchronously. This is the only way
        // to observe the degrade-then-announce ordering: the announcement rides
        // a broadcast stream and is therefore delivered a microtask later
        // whichever order the code ran in, so a case comparing two stream
        // events would pass under the sabotage it exists to catch.
        announcementsAtFirstChange ??= man.statusNotifications;
      }

      handle.addListener(bump);
      _detach.add(() => handle.removeListener(bump));
    }
  }

  final LocalStateMan man;
  final Map<String, int> counts = <String, int>{};
  final List<void Function()> _detach = <void Function()>[];

  /// What [LocalStateMan.statusNotifications] read the first time any key in
  /// this set notified.
  int? announcementsAtFirstChange;

  int get total => counts.values.fold(0, (a, b) => a + b);

  int totalOver(Iterable<String> keys) =>
      keys.fold(0, (sum, key) => sum + (counts[key] ?? 0));

  void detach() {
    for (final off in _detach) {
      off();
    }
    _detach.clear();
  }
}

void main() {
  late LocalStateMan man;
  late FakeUpstreamLink st101;
  late FakeUpstreamLink st201;

  setUp(() async {
    final built = buildTwoLinks();
    man = built.man;
    st101 = built.st101;
    st201 = built.st201;
    await man.start();
    addTearDown(man.dispose);
    seedBothStations(man);
  });

  group('SRV-08 per alias: one PLC\'s loss costs one PLC', () {
    test('losing one link degrades exactly that link\'s keys, on value AND '
        'quality', () async {
      final before = man.statusNotifications;
      st101.disconnectUpstream();
      await pumpEventQueue();

      for (final key in st101Keys) {
        expect(man.read(key)!.quality, Quality.badCommFault,
            reason: '$key is served by ST101 and ST101 is down; a value still '
                'reading good is a number from before the link died with '
                'nothing on screen saying so');
      }
      for (var i = 0; i < st101Keys.length; i++) {
        expect(man.read(st101Keys[i])!.value, 10 + i,
            reason: 'the last known reading must survive the loss, so an '
                'operator can see what the plant was doing when contact went');
      }

      for (var i = 0; i < st201Keys.length; i++) {
        final untouched = man.read(st201Keys[i])!;
        expect(untouched.quality, Quality.good,
            reason: '${st201Keys[i]} is served by ST201, which is up. Greying '
                'it out because a different PLC died is a plant fault the '
                'plant does not have');
        expect(untouched.value, 500 + i,
            reason: 'asserted on value as well as quality: a degradation that '
                'also dropped the number would pass a quality-only check');
      }

      final announcements = man.statusNotifications - before;
      print('ISOLATION st101 degraded=${st101Keys.length} '
          'st201 untouched=${st201Keys.length} announcements=$announcements');
      expect(announcements, 1);
    });

    test('the degradation is ONE batch: one notification per changed key and '
        'not one more', () async {
      final counter = NotificationCounter(man, <String>[...st101Keys, ...st201Keys]);
      addTearDown(counter.detach);

      final before = man.statusNotifications;
      st101.disconnectUpstream();
      await pumpEventQueue();
      final announcements = man.statusNotifications - before;

      print('BATCH notifications=${counter.total} '
          '(st101=${counter.totalOver(st101Keys)}, '
          'st201=${counter.totalOver(st201Keys)}) announcements=$announcements');

      expect(counter.totalOver(st101Keys), keysPerStation,
          reason: 'twenty keys changed, so twenty notifications. More than one '
              'per key means the pass ran more than once — the store\'s '
              'promise is that a batch costs one pass and k notifications, and '
              'a link loss is the largest batch this source will ever apply');
      expect(counter.totalOver(st201Keys), 0,
          reason: 'ST201 changed nothing, so ST201\'s listeners heard nothing. '
              'A notification with no value change is a rebuild for every '
              'widget on a page about a PLC that is fine');
      expect(announcements, 1);
    });

    test('the keys degrade BEFORE the world is told', () async {
      final counter = NotificationCounter(man, st101Keys);
      addTearDown(counter.detach);

      final before = man.statusNotifications;
      st101.disconnectUpstream();
      await pumpEventQueue();

      print('ORDER announcementsAtFirstChange='
          '${counter.announcementsAtFirstChange} before=$before');
      expect(counter.announcementsAtFirstChange, before,
          reason: 'when the first key degraded, no announcement had yet been '
              'made. A panel that learns the link is down and then reads a key '
              'that has not degraded yet sees a good value under a dead link, '
              'which is exactly the stale-but-plausible failure the project '
              'exists to prevent');
      expect(man.statusNotifications, before + 1,
          reason: 'and the announcement did happen — an ordering arm that '
              'passes because nothing was ever announced is vacuous');
    });

    test('a key already carrying worse news stages no change, and the '
        'announcement still moves by exactly one', () async {
      // errorConfig (770) is a worse band than badCommFault (522): the tag is
      // gone and waiting will not fix it. Repainting it as a comm fault tells
      // the operator to wait for something never coming back.
      final gone = st101Keys.first;
      man.applyUpstreamBatch(<String, DynamicValue>{
        gone: DynamicValue(value: null, quality: Quality.errorConfig),
      });

      final counter = NotificationCounter(man, st101Keys);
      addTearDown(counter.detach);

      final before = man.statusNotifications;
      st101.disconnectUpstream();
      await pumpEventQueue();
      final announcements = man.statusNotifications - before;

      print('BAND GUARD changed=${counter.total} (of ${st101Keys.length}) '
          'announcements=$announcements');

      expect(man.read(gone)!.quality, Quality.errorConfig,
          reason: 'the band guard: a key already worse than badCommFault keeps '
              'its own worse news');
      expect(counter.counts[gone], isNull,
          reason: 'and it staged NO change, so its listeners were not woken. '
              'fake_state_man.dart:570 — a key needing no change should notify '
              'nobody');
      expect(counter.total, keysPerStation - 1);
      expect(announcements, 1,
          reason: 'one link event is one announcement whether nineteen keys '
              'moved or twenty');
    });

    test('a health key is NOT degraded by the event it exists to report',
        () async {
      // Seeded through the store here; 08-09 task 2 puts a producer behind it
      // and `pipe_keys_local_test.dart` asserts the same property against the
      // real one. A light that goes out when the thing it monitors fails is
      // not an indicator.
      final stateKey = PipeKeys.upstreamState(st101Alias);
      man.applyUpstreamBatch(<String, DynamicValue>{
        stateKey: DynamicValue(value: UpstreamLinkState.connected.wireName),
      });

      st101.disconnectUpstream();
      await pumpEventQueue();

      final health = man.read(stateKey)!;
      print('HEALTH KEY $stateKey quality=${health.quality.code} '
          'value=${health.value}');
      expect(health.quality.band, Quality.good.band,
          reason: 'the mass degradation must skip the namespace that reports '
              'it. HLTH-02: health keys are excluded from their own accounting');
      expect(health.value, isNotNull);
    });

    test('losing BOTH links produces two announcements, one per alias, each '
        'naming its own', () async {
      final seen = <StatusParams>[];
      final sub = man.statusStream.listen(seen.add);
      addTearDown(sub.cancel);

      st101.disconnectUpstream();
      await pumpEventQueue();
      st201.disconnectUpstream();
      await pumpEventQueue();

      print('TWO LINKS announcements='
          '${seen.map((s) => '${s.alias}:${s.state}').toList()}');

      expect(seen, hasLength(2));
      expect(seen.map((s) => s.alias).toList(), <String>[st101Alias, st201Alias],
          reason: 'each announcement names the link it is about. An event that '
              'named the wrong PLC would send somebody to the wrong end of the '
              'building with the gateway\'s own authority behind it');
      for (final status in seen) {
        expect(status.state, UpstreamLinkState.disconnected.wireName,
            reason: 'the state travels as the wire vocabulary '
                '(messages.dart:493-495); a string the client\'s status '
                'handler cannot switch on is a link state the screen cannot '
                'render');
      }
      for (final key in <String>[...st101Keys, ...st201Keys]) {
        expect(man.read(key)!.quality, Quality.badCommFault);
      }
    });

    test('the announcement is built through StatusParams and survives '
        'fromJson', () async {
      // 03-REVIEW WR-06, which this channel has already been bitten by once: a
      // hand-built map reached a conforming client, `StatusParams.fromJson` hit
      // `json['alias'] as String` on null, and threw on the notification path
      // where nothing catches.
      final seen = <StatusParams>[];
      final sub = man.statusStream.listen(seen.add);
      addTearDown(sub.cancel);

      st101.disconnectUpstream();
      await pumpEventQueue();

      final round = StatusParams.fromJson(seen.single.toJson());
      expect(round.alias, st101Alias);
      expect(round.state, UpstreamLinkState.disconnected.wireName);
    });

    test('restoring a link leaves its keys uncertainLastKnown — not good — '
        'and announces once', () async {
      st101.disconnectUpstream();
      await pumpEventQueue();

      final before = man.statusNotifications;
      st101.reconnectUpstream();
      await pumpEventQueue();
      final announcements = man.statusNotifications - before;

      final restored = man.read(st101Keys.first)!;
      print('RESTORE quality=${restored.quality.code} value=${restored.value} '
          'announcements=$announcements');

      expect(restored.quality, Quality.uncertainLastKnown,
          reason: 'the link being back is not evidence about the number. Each '
              'value is good again only once it has been re-read; a snapshot '
              'that came back good would make a reconnection a way of '
              'laundering an hour-old reading into a current one');
      expect(restored.value, 10,
          reason: 'and it keeps its reading — recovery is a snapshot, never a '
              'forgetting');
      expect(announcements, 1);
      for (final key in st201Keys) {
        expect(man.read(key)!.quality, Quality.good,
            reason: 'ST201 was never touched by either event');
      }
    });
  });

  group('T-08-33: the announcement is fanned out, so it is swept too', () {
    test('a credentialed endpoint in the link\'s error reaches neither the '
        'announcement nor any key on the forty-key set', () async {
      final announced = <StatusParams>[];
      final sub = man.statusStream.listen(announced.add);
      addTearDown(sub.cancel);

      st101.setLastError(
          'opc.tcp://plc-user:hunter2@10.104.29.11/UA refused the session');
      st101.disconnectUpstream();
      await pumpEventQueue();

      final carried = '${announced.single.toJson()}';
      print('ANNOUNCED $carried');
      for (final secret in <String>['hunter2', 'plc-user', '10.104.29.11']) {
        expect(carried, isNot(contains(secret)),
            reason: 'a status notification goes to every connected session '
                'unasked, so the redaction has to have happened before the '
                'string ever became one. This is the local half of 06-06\'s '
                'server-side credential sweep');
      }
      expect(announced.single.error, isNotNull,
          reason: 'anti-vacuity: an announcement with no error at all would '
              'pass every assertion above while saying nothing');

      for (final key in <String>[...st101Keys, ...st201Keys]) {
        expect('${man.read(key)!.value}', isNot(contains('hunter2')));
      }
    });
  });
}
