/// The sweep may only ever DEGRADE — the gateway's side of it.
///
/// ## Why this file exists, and why it is a separate one
///
/// 18-03 extracted the staleness predicate into `tfc_relay_protocol` and then
/// sabotaged it, one condition at a time, to find out which of the two
/// dependent suites would notice. Deleting the degrade-only guard —
/// `Quality.badStale.band <= quality.band` — turned **nothing** red here: the
/// whole offline lane, 820 arms including one named *"quality never improves on
/// its own"*, ran green against a sweep that could raise a quality.
///
/// The backend's suite did not catch it either, but the backend is *structurally*
/// protected: `BackendValueSource.markStale` carries its own copy of the same
/// band comparison (`backend_live_values.dart`), so a sweep that asked to
/// improve a quality is refused downstream. **The gateway has no such second
/// guard.** `LocalStateMan._degrade` is `_store.applyBatch(values)` and nothing
/// else, so the kernel's guard is the only thing standing between a key at
/// `badCommFault` or `errorConfig` and a sweep quietly relabelling it
/// `badStale`.
///
/// That is a fault clearing itself on screen while the fault is still
/// happening: the same lie as a stale value, arrived at from the other
/// direction and harder to catch because it looks like recovery. An operator
/// watching a comms fault would see it become "merely stale" four times a
/// deadline, on its own, with the PLC still unreachable.
///
/// The arms live in their own file rather than in `freshness_test.dart` because
/// 18-03's own verification requires that file to pass with **zero lines edited
/// by the plan** — a test the refactor touched is a test that cannot testify
/// about the refactor.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// Short enough to keep the suite cheap, long enough that a loaded machine does
/// not trip it between two statements of the same case.
const Duration staleAfter = Duration(milliseconds: 60);

LocalStateMan build() {
  const keys = [st101Key, st201Key];
  final link = FakeUpstreamLink(alias: st101Alias, keys: keys);
  return LocalStateMan(
    links: [link],
    router: KeyRouter.overLinks(
      [link],
      mappings: keyMappingsOf(keys, alias: st101Alias),
    ),
    staleAfter: staleAfter,
  );
}

void main() {
  late LocalStateMan man;

  setUp(() async {
    man = build();
    await man.start();
    addTearDown(man.dispose);
  });

  group('the sweep may only ever degrade', () {
    test('the live control: a GOOD value that goes quiet really does stale',
        () async {
      // Without this the two arms below would pass against a sweep that never
      // ran at all — the gate-that-cannot-bite failure this milestone has
      // produced repeatedly. Every negative arm here is paired with it.
      final watch = man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);

      man.applyUpstreamBatch({st101Key: DynamicValue(value: 41.5)});
      expect(man.read(st101Key)!.quality, Quality.good);

      await _until(() => man.read(st101Key)!.quality == Quality.badStale,
          reason: 'the sweep must be running for the arms below to mean '
              'anything');
    });

    test('a key at badCommFault is NOT relabelled badStale when it goes quiet',
        () async {
      // Same band as badStale, worse code. `badCommFault` says the link to
      // this PLC is down; `badStale` says the number is merely old. Replacing
      // the first with the second is a downgrade of the news, and the operator
      // reading the screen would conclude the link had come back.
      final watch = man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);

      man.applyUpstreamBatch({
        st101Key: DynamicValue(value: 41.5, quality: Quality.badCommFault),
      });
      expect(man.read(st101Key)!.quality, Quality.badCommFault);

      // Four sweep intervals of silence — twice as long as it takes a good
      // value to stale, so the sweep has certainly looked at this key.
      await Future<void>.delayed(staleAfter * 2);

      expect(man.read(st101Key)!.quality, Quality.badCommFault,
          reason: 'the sweep raised a quality: a comms fault relabelled as '
              'mere staleness is a fault clearing itself on screen while the '
              'fault is still happening');
    });

    test('a key at errorConfig is not improved ACROSS a band either', () async {
      // The band-crossing case. `errorConfig` is band 3, `badStale` is band 2,
      // so this is not a same-band code swap but a strict improvement — and
      // the guard is written on the band precisely so a code invented in a
      // later phase is handled on the day it is invented.
      expect(Quality.errorConfig.band, greaterThan(Quality.badStale.band),
          reason: 'the fixture only means anything while that ordering holds');

      final watch = man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);

      man.applyUpstreamBatch({
        st101Key: DynamicValue(value: 41.5, quality: Quality.errorConfig),
      });
      expect(man.read(st101Key)!.quality, Quality.errorConfig);

      await Future<void>.delayed(staleAfter * 2);

      expect(man.read(st101Key)!.quality, Quality.errorConfig,
          reason: 'a permanent configuration fault must not be downgraded to '
              'a transient staleness by a watchdog');
    });
  });
}

/// Waits for [predicate] to hold, or fails naming what never happened.
Future<void> _until(
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
