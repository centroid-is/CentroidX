/// Hold-to-run against a real tag.
///
/// The safety property is not that a release message arrives — it is that a
/// counter **stops advancing**, which the PLC notices inside its deadman
/// window (`hold_handle.dart:1-10`; the PLC counterpart is
/// `relay-comm-design.md` §4.6a's `FB_HoldToRun` with `T#1000MS`). Everything
/// below is shaped by that inversion:
///
///  * the engage and the release are **ordinary writes** with three-state
///    outcomes — a hold can be interlocked out exactly like any other command;
///  * the ticks in between are fire-and-forget, because *"a tick that is lost
///    costs nothing a re-tick 100 ms later does not fix"*
///    (`hold_handle.dart:9-10`, quoted as the plan asks);
///  * and a torn-down source leaves a **zero** on the tag rather than a frozen
///    counter, because a frozen counter is a machine nobody is holding that the
///    PLC still thinks somebody is.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// A key no keymapping in this file contains, so the router refuses it.
const String unmappedKey = 'ST101.CN99.MOT01.speed';

({LocalStateMan man, FakeUpstreamLink link}) buildHoldFixture({
  bool supportsWrites = true,
}) {
  final link = FakeUpstreamLink(
    alias: st101Alias,
    keys: const <String>[st101Key, st201Key],
    supportsWrites: supportsWrites,
  );
  final man = LocalStateMan(
    links: <UpstreamLink>[link],
    router: KeyRouter.overLinks(
      <UpstreamLink>[link],
      mappings:
          keyMappingsOf(const <String>[st101Key, st201Key], alias: st101Alias),
    ),
    staleAfter: const Duration(seconds: 30),
  );
  return (man: man, link: link);
}

/// What the PLC would read on [key] right now — the link's own cache, not the
/// gateway's store, because the question this file asks is what the *plant*
/// sees.
Object? tagValue(FakeUpstreamLink link, String key) =>
    link.peek(link.resolve(key, 'entry')!)?.value;

void main() {
  group('the deadman is an ordinary tag, written through the ordinary path',
      () {
    late LocalStateMan man;
    late FakeUpstreamLink link;

    setUp(() async {
      final built = buildHoldFixture();
      man = built.man;
      link = built.link;
      await man.start();
      addTearDown(man.dispose);
    });

    test('engage is a real write: the outcome is three-state and the tag reads '
        '1', () async {
      final hold = await man.holdToRun(st101Key);

      expect(hold.engagement, isA<WriteApplied>());
      expect(hold.isHeld, isTrue);
      expect(hold.counter, 1);
      expect(tagValue(link, st101Key), 1,
          reason: 'there is exactly one key and it is the one passed in — the '
              'tag IS the deadman counter, and a sibling-tag naming '
              'convention invented in Dart would have to be matched by hand '
              'in every PLC program');
      await hold.release();
    });

    test('the engage is an ordinary command in the outcome log, and writeStatus '
        'can answer for it', () async {
      final hold = await man.holdToRun(st101Key);
      final answers =
          await man.writeStatus(<String>[hold.engagement.cmd]);
      expect(answers.single, isA<WriteApplied>(),
          reason: 'a hold engage is a write like any other: it is the ticks '
              'that are special, not the engage');
      await hold.release();
    });

    test('each tick writes the counter the GATEWAY minted, monotonically',
        () async {
      final hold = await man.holdToRun(st101Key);

      hold.tick();
      await pump();
      expect(tagValue(link, st101Key), 2);
      hold.tick();
      hold.tick();
      await pump();
      expect(tagValue(link, st101Key), 4,
          reason: 'the wire\'s n is discarded and the gateway mints its own '
              '(value_handlers.dart:628-654) — never trust a wire integer on '
              'a deadman tag. HoldHandle.tick() takes no argument at all, '
              'which is that rule expressed in the type');
      await hold.release();
    });

    test('ticks are fire-and-forget: a tick whose write answers UNKNOWN does '
        'not end the hold and does not throw', () async {
      final hold = await man.holdToRun(st101Key);

      link.setNextWriteOutcome(
          const WriteUnknown('01J0000000000000000000000A',
              WriteReason('plc_timeout')));
      hold.tick();
      await pump();

      expect(hold.isHeld, isTrue,
          reason: '"a tick that is lost costs nothing a re-tick 100 ms later '
              'does not fix" (hold_handle.dart:9-10). Ending a hold on one '
              'lost tick would stop a machine an operator is still holding');
      await hold.release();
    });

    test('a held button costs the write bookkeeping nothing', () async {
      final hold = await man.holdToRun(st101Key);
      final afterEngage = man.writeOutcomeCount;

      for (var i = 0; i < 20; i++) {
        hold.tick();
      }
      await pump();

      expect(man.writeOutcomeCount, afterEngage,
          reason: 'at 10 Hz a two-minute hold is 1,200 ticks. Recording them '
              'would evict the operator\'s real write outcomes out of a '
              'bounded log inside seconds, and a tick is liveness rather than '
              'a command anybody will ask writeStatus about');
      await hold.release();
    });

    test('release writes 0 and answers three-state', () async {
      final hold = await man.holdToRun(st101Key);
      hold.tick();
      await pump();

      final outcome = await hold.release();

      expect(outcome, isA<WriteApplied>());
      expect(hold.isHeld, isFalse);
      expect(tagValue(link, st101Key), 0);
      expect(await hold.onReleased, HoldEnded.operatorLetGo);
    });
  });

  group('a hold that was never taken is inert', () {
    test('a read-only key is refused at engage, with the same Bad_NotWritable '
        'shape as any other read-only write', () async {
      final built = buildHoldFixture(supportsWrites: false);
      await built.man.start();
      addTearDown(built.man.dispose);

      final hold = await built.man.holdToRun(st101Key);

      expect(hold.engagement, isA<WriteRejected>());
      expect((hold.engagement as WriteRejected).reason.status,
          'Bad_NotWritable');
      expect(hold.isHeld, isFalse);
      expect(await hold.onReleased, HoldEnded.refused);
    });

    test('an unmapped key is refused at engage — nothing was sent', () async {
      final built = buildHoldFixture();
      await built.man.start();
      addTearDown(built.man.dispose);

      final hold = await built.man.holdToRun(unmappedKey);
      expect(hold.engagement, isA<WriteRejected>());
      expect(hold.isHeld, isFalse);
    });

    test('feeding an inert handle writes NOTHING', () async {
      final built = buildHoldFixture(supportsWrites: false);
      await built.man.start();
      addTearDown(built.man.dispose);

      final hold = await built.man.holdToRun(st101Key);
      final before = built.link.roundTrips;
      hold.tick();
      hold.tick();
      await pump();

      expect(built.link.roundTrips, before,
          reason: 'a hold whose engage did not apply was never taken, and a '
              'handle that could still be fed would be a deadman counter '
              'advancing on a machine nobody engaged');
    });
  });

  group('a torn-down source leaves a zero, not a frozen counter', () {
    test('dispose under a live hold ends it with HoldEnded.disposed and the '
        'tag reads 0', () async {
      final built = buildHoldFixture();
      await built.man.start();

      final hold = await built.man.holdToRun(st101Key);
      hold.tick();
      hold.tick();
      await pump();
      expect(tagValue(built.link, st101Key), 3);

      await built.man.dispose();

      expect(await hold.onReleased, HoldEnded.disposed);
      expect(hold.isHeld, isFalse);
      expect(tagValue(built.link, st101Key), 0,
          reason: 'THE arm of this file, and it is about a machine rather '
              'than about a counter. The PLC drops the output when the '
              'counter stops changing, so a frozen 3 left behind is a machine '
              'the PLC still believes somebody is holding for as long as its '
              'deadman window lasts. Saying zero is the honest thing, and '
              'Phase 5\'s shipped precedent is exactly this: disconnect stops '
              'a hold by TWO mechanisms and the tag reads 0, not frozen');
    });

    test('dispose with no live hold is still quiet, and disposing twice does '
        'not write twice', () async {
      final built = buildHoldFixture();
      await built.man.start();
      final hold = await built.man.holdToRun(st101Key);
      await built.man.dispose();
      final after = built.link.roundTrips;
      await built.man.dispose();

      expect(built.link.roundTrips, after,
          reason: 'release() is idempotent and dispose() is too — a '
              'disconnect racing an operator\'s finger must not put two zeros '
              'on the wire');
      expect(await hold.onReleased, HoldEnded.disposed);
    });
  });
}

/// Lets the fire-and-forget tick writes settle.
///
/// A tick returns nothing on purpose — giving it an outcome would invite
/// somebody to await it, and awaiting liveness is how a stalled socket becomes
/// a queue (`hold_handle.dart:127-133`). So a case that wants to see the tag
/// move has to let the event loop run instead.
Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
