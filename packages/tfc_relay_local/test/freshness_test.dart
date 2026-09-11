/// Silence becomes visible, and the clock that notices only runs while
/// somebody is watching.
///
/// **Every staleness assertion is read inside an [until] window, never as an
/// instant read of a wall-clock-derived boolean.** The sweep is a real timer on
/// the real clock — deliberately, because a sweep that only advances when a
/// test advances a fake clock is precisely the machinery that then fails to run
/// in the plant (`fake_state_man.dart:19-24`) — so the question a case can
/// honestly ask is "does this become true within a bounded window", not "is it
/// true on this exact microsecond".
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// Short enough to keep the suite cheap, long enough that a loaded machine does
/// not trip it between two statements of the same case.
const Duration staleAfter = Duration(milliseconds: 60);

/// A health key **no roster contains**.
///
/// This is HLTH-02's teeth. `PipeKeys.declared` does not hold this name and
/// neither does `FakeStateMan.healthKeys`, so a sweep that skipped health keys
/// by looking them up in a list would stale it — and the whole point of the
/// prefix rule is that a key invented in a later phase is swept correctly on
/// the day it is invented, with no edit anywhere.
const String inventedHealthKey = 'PIPE.invented.later';

({LocalStateMan man, FakeUpstreamLink link}) build() {
  const keys = [st101Key, st201Key];
  final link = FakeUpstreamLink(alias: st101Alias, keys: keys);
  final man = LocalStateMan(
    links: [link],
    router: KeyRouter.overLinks(
      [link],
      mappings: keyMappingsOf(keys, alias: st101Alias),
    ),
    staleAfter: staleAfter,
  );
  return (man: man, link: link);
}

void main() {
  late LocalStateMan man;

  setUp(() async {
    man = build().man;
    await man.start();
    addTearDown(man.dispose);
  });

  group('a value nobody has heard from stops claiming to be current', () {
    test('past the deadline it reads badStale, keeps its number, and its '
        'sourceTime does NOT advance', () async {
      final stamped = DateTime.utc(2026, 9, 1, 6, 30);
      final watch = man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);

      man.applyUpstreamBatch({
        st101Key: DynamicValue(value: 41.5, sourceTime: stamped),
      });
      expect(man.read(st101Key)!.quality, Quality.good);

      await until(() => man.read(st101Key)!.quality == Quality.badStale,
          reason: 'the sweep must notice silence; nothing else can');

      expect(man.read(st101Key)!.value, 41.5,
          reason: 'staleness is about the timestamp, not the number. Blanking '
              'the value would tell an operator the tag never existed, which '
              'is a different and untrue thing');
      expect(man.read(st101Key)!.sourceTime, stamped,
          reason: 'a degradation is not news from upstream. A sweep that '
              'restamped sourceTime would make the value look freshly '
              'delivered at the exact moment it stopped being trustworthy');
    });

    test('a fresh update clears the staleness, and the transition notified '
        'exactly once', () async {
      var notifications = 0;
      final handle = man.listen(st101Key);
      void count() => notifications++;
      handle.addListener(count);
      addTearDown(() => handle.removeListener(count));

      man.applyUpstreamBatch({st101Key: DynamicValue(value: 1)});
      final afterArrival = notifications;

      // Probed on the NODE, not through read(): read() re-derives the verdict
      // synchronously and would answer badStale before the sweep had staged
      // anything, so it cannot witness "the sweep staged it exactly once".
      // The node's cached value is changed by the sweep and by nothing else.
      await until(() => handle.value.quality == Quality.badStale);
      expect(notifications - afterArrival, 1,
          reason: 'the sweep runs four times per deadline. A key needing no '
              'change must stage no change, or every listening page rebuilds '
              'on every tick — the band comparison at fake_state_man.dart:517 '
              'rather than Quality.worst, and for exactly this reason');

      // Two more sweep intervals with nothing arriving: still no news.
      await Future<void>.delayed(man.sweepInterval * 3);
      expect(notifications - afterArrival, 1);

      man.applyUpstreamBatch({st101Key: DynamicValue(value: 2)});
      expect(man.read(st101Key)!.quality, Quality.good);
      await Future<void>.delayed(man.sweepInterval * 2);
      expect(man.read(st101Key)!.quality, Quality.good,
          reason: 'and it stays good until the deadline passes again');
    });
  });

  group('health keys are excluded from their own freshness accounting', () {
    test('a PIPE. key no roster contains still reads its own quality after ten '
        'times the deadline', () async {
      final watch = man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);

      man.applyUpstreamBatch({
        inventedHealthKey: DynamicValue(value: 'up'),
        st101Key: DynamicValue(value: 1),
      });

      // The plant key going stale is the proof the sweep ran at all.
      await until(() => man.read(st101Key)!.quality == Quality.badStale);
      await Future<void>.delayed(staleAfter * 10);

      expect(man.read(inventedHealthKey)!.quality, Quality.good,
          reason: 'connected, birth_count, last_death_at, state, epoch and '
              'days_to_expiry all change only on an event, so any freshness '
              'accounting greys them out permanently and precisely while '
              'nothing is wrong (08-RESEARCH D.3). The skip is by PREFIX; an '
              'enumerated list is a list a new key gets added outside of, and '
              'this key is not on any list');
      expect(man.read(inventedHealthKey)!.value, 'up');
    });
  });

  group('the clock only runs while somebody is watching', () {
    test('no timer before the first listener, one while watched, none after '
        'the last', () async {
      expect(man.liveTimers, 0,
          reason: 'an always-on Timer.periodic leaks past every test that '
              'builds a source without draining it, and an unobserved gateway '
              'has nobody to tell anyway (state_man.dart:966-992)');

      final watch = man.subscribe(st101Key).listen((_) {});
      expect(man.liveTimers, 1);

      final second = man.subscribe(st201Key).listen((_) {});
      expect(man.liveTimers, 1,
          reason: 'one clock for the store, not one per key');

      await second.cancel();
      expect(man.liveTimers, 1);
      await watch.cancel();
      expect(man.liveTimers, 0);
    });

    test('a read taken after a PARKED period is still correct, because the '
        'verdict is re-derived on read rather than only on tick', () async {
      man.applyUpstreamBatch({st101Key: DynamicValue(value: 5)});
      expect(man.liveTimers, 0, reason: 'nobody is watching');

      await Future<void>.delayed(staleAfter * 3);

      expect(man.liveTimers, 0,
          reason: 'and nobody started watching, so no sweep has run');
      expect(man.read(st101Key)!.quality, Quality.badStale,
          reason: 'the synchronous getter re-derives on every read, so nothing '
              'goes stale while the timer is parked — ClientWrapper\'s third '
              'property (state_man.dart:1000, :1005-1031), and the thing that '
              'makes the listener gate safe rather than merely cheap');
      expect(man.read(st101Key)!.value, 5);
    });

    test('the sweep interval is a quarter of the deadline, with a floor', () {
      expect(FreshnessSweep.intervalFor(staleAfter), staleAfter ~/ 4,
          reason: 'a value is then reported stale within 125% of the deadline '
              'rather than 200% (fake_state_man.dart:200-213)');
      expect(FreshnessSweep.intervalFor(const Duration(milliseconds: 1)),
          FreshnessSweep.minimumInterval,
          reason: 'an implausibly short deadline must not turn the sweep into '
              'a busy loop on the isolate serving every client');
      expect(man.sweepInterval, staleAfter ~/ 4);
    });
  });
}

/// Waits for [predicate] to hold, or fails naming what never happened.
Future<void> until(
  bool Function() predicate, {
  Duration within = const Duration(seconds: 3),
  String? reason,
}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the condition did not hold within ${within.inMilliseconds} ms'
          '${reason == null ? '' : ' — $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
