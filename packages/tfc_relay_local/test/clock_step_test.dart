/// An NTP step on the gateway machine must not make a stale plant fresh.
///
/// **Phase 7's CR-01, server-side.** The client fix (`6a499d65`, "age staleness
/// on a monotonic anchor, not the panel's RTC") settled the argument for one
/// panel; 08-REVIEW CR-02 found the same arithmetic on the gateway, where it
/// affects every panel at once. An elapsed-time question — *how long since this
/// value arrived* — must be asked of an elapsed-time clock. `DateTime.now()`
/// steps: NTP corrects it, an operator sets it, a VM resumes with a different
/// one. Subtracting two readings of a clock that can step is arithmetic whose
/// answer can be negative, and a negative age reads as *fresh*.
///
/// The gateway runs on a plant PC under NTP. A backwards correction larger than
/// `staleAfter` made `now.difference(arrived)` negative for **every key in the
/// store at once**, so the sweep degraded nothing and `judge` on the read path
/// agreed with it — the whole plant showing confident, current-looking numbers
/// from PLCs nobody had heard from. That is the failure PROJECT.md names as the
/// reason this project exists, arriving through the clock rather than through
/// the wire.
///
/// Both clocks are injected here, and that is the point: the wall clock steps
/// backwards while the elapsed clock keeps counting, which is exactly what the
/// two clocks do during an NTP correction. Nothing in these cases sleeps.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// Long enough that the step has to be deliberate to cross it.
const Duration staleAfter = Duration(seconds: 5);

/// The plant PC's RTC: movable in both directions, because NTP moves it in
/// both directions.
final class WallClock {
  DateTime at = DateTime.utc(2026, 9, 2, 6);
  DateTime call() => at;
  void step(Duration by) => at = at.add(by);
}

/// The anchor an age must be measured on: monotonic, and it only goes forward.
final class ElapsedClock {
  int ms = 0;
  int call() => ms;
  void advance(Duration by) => ms += by.inMilliseconds;
}

({
  LocalStateMan man,
  FakeUpstreamLink link,
  WallClock wall,
  ElapsedClock elapsed,
}) build() {
  final wall = WallClock();
  final elapsed = ElapsedClock();
  final link = FakeUpstreamLink(alias: st101Alias, keys: const <String>[st101Key]);
  final man = LocalStateMan(
    links: <UpstreamLink>[link],
    router: KeyRouter.overLinks(
      <UpstreamLink>[link],
      mappings: keyMappingsOf(const <String>[st101Key], alias: st101Alias),
    ),
    staleAfter: staleAfter,
    now: wall.call,
    elapsedMs: elapsed.call,
  );
  return (man: man, link: link, wall: wall, elapsed: elapsed);
}

void main() {
  group('CR-02: freshness is aged on a monotonic anchor, never on the RTC', () {
    test('a value older than the deadline stays stale across a BACKWARDS clock '
        'step larger than the deadline', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{st101Key: DynamicValue(value: 41.5)});
      expect(built.man.read(st101Key)!.quality, Quality.good);

      // Real time passes. Nothing arrives.
      built.elapsed.advance(staleAfter * 2);
      expect(built.man.read(st101Key)!.quality, Quality.badStale,
          reason: 'silence past the deadline is what the sweep exists to make '
              'visible');

      // And now NTP corrects the plant PC backwards by an hour, which is the
      // ordinary shape of a correction on a machine whose clock has drifted.
      built.wall.step(const Duration(hours: -1));

      expect(built.man.read(st101Key)!.quality, Quality.badStale,
          reason: 'the value did not become current because a clock moved. '
              'Subtracting two DateTime.now() readings makes this negative for '
              'every key in the store at once, so the sweep degrades nothing '
              'and every panel shows a plant nobody has heard from as fresh '
              '(07-REVIEW CR-01, reintroduced gateway-side)');
      expect(built.man.read(st101Key)!.value, 41.5,
          reason: 'staleness is still about the timestamp, not the number');
    });

    test('a FORWARDS step does not grey out a plant that is answering', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{st101Key: DynamicValue(value: 7)});

      built.wall.step(const Duration(hours: 1));
      built.elapsed.advance(const Duration(milliseconds: 10));

      expect(built.man.read(st101Key)!.quality, Quality.good,
          reason: 'the mirror image of the same defect: a forward correction '
              'greys the whole plant, and an operator who has learned that '
              'grey boxes clear themselves has learned to ignore the one '
              'signal this gateway exists to give them');
    });

    test('the sweep itself — not only the read-path re-derivation — is aged on '
        'the anchor', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      // A live listener, so the sweep's clock is running and the node's cached
      // value (rather than read()'s synchronous re-derivation) is the witness.
      final handle = built.man.listen(st101Key);
      void noop() {}
      handle.addListener(noop);
      addTearDown(() => handle.removeListener(noop));

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{st101Key: DynamicValue(value: 1)});
      built.elapsed.advance(staleAfter * 2);
      built.wall.step(const Duration(hours: -1));

      await _until(() => handle.value.quality == Quality.badStale,
          reason: 'the sweep and the read path must agree, or a page that '
              'subscribes and a page that polls disagree about the same tag');
    });
  });

  group('CR-02: data_age_ms is the same question and gets the same clock', () {
    test('it never reads negative after a backwards step', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{st101Key: DynamicValue(value: 3)});

      built.elapsed.advance(const Duration(seconds: 2));
      built.wall.step(const Duration(hours: -1));

      final age = built.man.read(PipeKeys.upstreamDataAgeMs(st101Alias))!;
      expect(age.value, 2000,
          reason: 'the gauge measures how long since a value arrived, which is '
              'an elapsed-time question. A negative age published under a good '
              'quality is a number no page can render sensibly');
      expect(age.quality.isGood, isTrue);
    });

    test('it advances with the anchor while the RTC stands still', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{st101Key: DynamicValue(value: 3)});
      built.elapsed.advance(const Duration(milliseconds: 1500));

      expect(built.man.read(PipeKeys.upstreamDataAgeMs(st101Alias))!.value, 1500);
    });
  });

  group('CR-02: no new timer was added to pay for it', () {
    test('the timer count is still zero unwatched and one watched', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      expect(built.man.liveTimers, 0);
      final watch = built.man.subscribe(st101Key).listen((_) {});
      addTearDown(watch.cancel);
      expect(built.man.liveTimers, 1,
          reason: 'the anchor is a Stopwatch, which is arithmetic and not a '
              'clock somebody has to cancel');
    });
  });
}

Future<void> _until(bool Function() predicate,
    {Duration within = const Duration(seconds: 3), String? reason}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the condition did not hold within ${within.inMilliseconds} ms'
          '${reason == null ? '' : ' — $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
