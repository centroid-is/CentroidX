/// The freshness kernel: the cadence arithmetic and the staleness predicate.
///
/// These arms exist because two sweeps — `BackendFreshnessSweep` in `tfc_dart`
/// and `FreshnessSweep` in `tfc_relay_local` — carried the same thirty lines
/// twice, and the failure they exist to prevent is the one PROJECT.md names as
/// the reason the project exists: a plausible number under a good quality,
/// arriving from a PLC nobody has heard from. A watchdog with two bodies is a
/// watchdog that can be fixed in one of them.
///
/// Each condition of the predicate gets its own arm. A single arm exercising
/// several conditions at once lets a mutation to one hide behind another — the
/// gate-that-cannot-bite failure this milestone has now produced five times
/// (18-BASELINE F6).
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('the cadence', () {
    test('a quarter of the deadline, exactly', () {
      expect(freshnessIntervalFor(const Duration(seconds: 10)),
          const Duration(milliseconds: 2500),
          reason: 'a value is then reported stale within 125% of its deadline '
              'rather than within 200%, and that margin is what keeps a '
              'freshness case green on a loaded machine');
    });

    test('the floor bites under an implausibly short deadline', () {
      expect(freshnessIntervalFor(const Duration(milliseconds: 4)),
          const Duration(milliseconds: 5),
          reason: 'a deadline out of a configuration file must not turn the '
              'sweep into a busy loop on the one isolate serving every client');
    });

    test('the boundary, where the quarter equals the floor', () {
      // 20 ms / 4 == 5 ms, so the comparison is `<` and not `<=` on exactly
      // this input. A flip to `<=` returns the floor rather than the quarter —
      // the same Duration here, which is why the two arms either side matter.
      expect(freshnessIntervalFor(const Duration(milliseconds: 20)),
          const Duration(milliseconds: 5));
      expect(freshnessIntervalFor(const Duration(milliseconds: 24)),
          const Duration(milliseconds: 6),
          reason: 'one tick above the boundary the quarter wins');
      expect(freshnessIntervalFor(const Duration(milliseconds: 16)),
          const Duration(milliseconds: 5),
          reason: 'one tick below it the floor wins');
    });

    test('the floor is 5 ms, pinned as a value', () {
      // Pinned because two sweeps agreeing on a constant is the property, not
      // the constant itself. An assertion written against the constant would
      // move when the constant moved and assert the mutation against itself
      // (18-02's finding on `maxRedactedErrorLength`), so this is the literal.
      expect(minimumFreshnessInterval, const Duration(milliseconds: 5));
    });
  });

  group('the predicate', () {
    const deadline = Duration(seconds: 10);

    bool stale({
      String key = 'ST101.CN01.MOTOR.speed',
      Quality quality = Quality.good,
      int? lastHeardMs = 0,
      int nowMs = 0,
      Duration staleAfter = deadline,
      bool skipAlarmKeys = false,
    }) =>
        isStaleNow(
          key: key,
          quality: quality,
          lastHeardMs: lastHeardMs,
          nowMs: nowMs,
          staleAfter: staleAfter,
          skipAlarmKeys: skipAlarmKeys,
        );

    test('a value heard from a millisecond ago is not stale', () {
      expect(stale(lastHeardMs: 1000, nowMs: 1001), isFalse);
    });

    test('the deadline is inclusive-from: at it stale, one ms before it not',
        () {
      // Both copies used `<` on the elapsed difference. A flip to `<=` is a
      // one-character mutation that shifts every verdict in the plant by a
      // tick, so the boundary is pinned in both directions rather than once.
      expect(stale(lastHeardMs: 0, nowMs: 10000), isTrue,
          reason: 'now - lastHeard == staleAfter is past the deadline');
      expect(stale(lastHeardMs: 0, nowMs: 9999), isFalse,
          reason: 'one millisecond inside the deadline is still current');
    });

    test('a key never heard from is not stale — notYetKnown is not stale', () {
      // `uncertainNotYetKnown` and `badStale` are different statements, and
      // the second implies the first was once true. Nothing has ever arrived
      // for this key, so there is no silence to notice.
      // A day of elapsed time, written as a decimal and not as a shift: this
      // package's other web arm exists because a `<<` that is 48 bits wide on
      // the VM is 32 bits wide under dart2js (18-01), and a fixture built from
      // one is a fixture that means something different per target.
      expect(stale(lastHeardMs: null, nowMs: 86400000), isFalse);
    });

    test('the sweep only ever degrades: already badStale stages nothing', () {
      // If it could raise a quality an operator would watch a fault clear
      // itself while the fault was still happening — the same lie as a stale
      // value, arrived at from the other direction and harder to catch
      // because it looks like recovery.
      expect(stale(quality: Quality.badStale, lastHeardMs: 0, nowMs: 3600000),
          isFalse);
    });

    test('the degrade-only guard is on the BAND, not on one code', () {
      // The comparison is `badStale.band <= quality.band`, so a code invented
      // in a later phase is handled on the day it is invented. Three fixtures:
      // the same band as badStale under a different code, a strictly worse
      // band, and — the live control — a better one.
      expect(Quality.badCommFault.band, Quality.badStale.band,
          reason: 'the same band under a different code; the fixture only '
              'means anything if that is still true');
      expect(stale(quality: Quality.badCommFault, lastHeardMs: 0, nowMs: 3600000),
          isFalse);
      expect(Quality.errorConfig.band, greaterThan(Quality.badStale.band));
      expect(stale(quality: Quality.errorConfig, lastHeardMs: 0, nowMs: 3600000),
          isFalse,
          reason: 'a permanent configuration fault must not be downgraded to a '
              'transient staleness');
      expect(Quality.uncertainLastKnown.band, lessThan(Quality.badStale.band));
      expect(
          stale(
              quality: Quality.uncertainLastKnown,
              lastHeardMs: 0,
              nowMs: 3600000),
          isTrue,
          reason: 'a live control: an uncertain value is in a BETTER band than '
              'badStale, so the guard must not swallow it — without this the '
              'two arms above would pass against a predicate that never stales '
              'anything at all');
    });

    test('PIPE. is skipped by prefix, including a key invented here', () {
      expect(stale(key: 'PIPE.connected', lastHeardMs: 0, nowMs: 3600000),
          isFalse);
      // A prefix test and never a roster: `PIPE.upstream.st101.invented_later`
      // is declared nowhere, and that is the point. A health key changes on a
      // cadence this predicate cannot see, so on a healthy pipe it is always
      // older than any deadline; staling it greys out the one indicator an
      // operator uses to decide whether to believe the rest of the screen,
      // and greys it out exactly when nothing is wrong (HLTH-02).
      expect(
          stale(
              key: 'PIPE.upstream.st101.invented_later',
              lastHeardMs: 0,
              nowMs: 3600000),
          isFalse);
      // The live control for the two above: strip the prefix and the same
      // inputs stale. Without it both would pass against a predicate that
      // never returns true.
      expect(stale(key: 'connected', lastHeardMs: 0, nowMs: 3600000), isTrue);
    });

    test('ALARM. is skipped when the caller asks for it', () {
      // Alarm state changes on EVENTS: the engine republishes the active set
      // when a rule transitions and at no other time, so on a healthy plant
      // the last publish is arbitrarily old and that is exactly what "no
      // alarms" looks like. Silence here is news, not the absence of news.
      expect(
          stale(
              key: 'ALARM.active',
              lastHeardMs: 0,
              nowMs: 3600000,
              skipAlarmKeys: true),
          isFalse);
    });

    test('ALARM. ages like any other key when the caller does not', () {
      // The other half of the divergence, and it must DISAGREE with the arm
      // above. `tfc_relay_local` passes false because no alarm producer writes
      // into that store: a key literally named `ALARM.*` in a keymapping there
      // is an ordinary plant tag with an unfortunate name, and staling it is
      // correct.
      expect(
          stale(
              key: 'ALARM.active',
              lastHeardMs: 0,
              nowMs: 3600000,
              skipAlarmKeys: false),
          isTrue);
    });

    test('the two skips are two arguments and cannot collapse into one', () {
      // A `PIPE.` key skips with the alarm policy OFF. If the two prefixes
      // were one skip set behind one flag, this would age. `alarm_keys.dart`
      // pins that neither prefix is a prefix of the other; these arms pin that
      // the two reasons stay two arguments.
      expect(
          stale(
              key: 'PIPE.connected',
              lastHeardMs: 0,
              nowMs: 3600000,
              skipAlarmKeys: false),
          isFalse);
      // And the mirror: an alarm key is NOT covered by the pipe skip.
      expect(
          stale(
              key: 'ALARM.active',
              lastHeardMs: 0,
              nowMs: 3600000,
              skipAlarmKeys: false),
          isTrue);
      expect(PipeKeys.isPipeKey(AlarmKeys.prefix), isFalse,
          reason: 'neither prefix contains the other, which is what keeps the '
              'two skips from quietly becoming one');
      expect(AlarmKeys.isAlarmKey(PipeKeys.prefix), isFalse);
    });

    test('the anchor is elapsed milliseconds, and takes no clock', () {
      // There is deliberately no clock seam. A seam that accepts a steppable
      // clock is a seam somebody steps: a backwards NTP step made the old
      // wall-clock subtraction negative for EVERY key at once, so the sweep
      // degraded nothing and the whole plant read fresh from PLCs nobody had
      // heard from (08-REVIEW CR-02). A negative difference here is a caller
      // bug, and it reads NOT stale rather than throwing — the same verdict
      // the two copies gave, unchanged by the move.
      expect(stale(lastHeardMs: 5000, nowMs: 0), isFalse);
    });
  });
}
