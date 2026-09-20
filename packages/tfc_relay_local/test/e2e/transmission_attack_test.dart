/// The transmission, attacked, with a real plant moving underneath it.
///
/// `end_to_end_test.dart` proves the layers agree on a cooperative link.
/// `ws_harness.dart` breaks the panel-facing link but has a `FakeStateMan`
/// behind the server. This file is the crossing of the two: the panel's own
/// socket is cut, stalled, throttled and flapped **while a PLC keeps changing
/// the values the panel was already showing**.
///
/// That combination is what the branch's central promise is about. "The screen
/// stops lying when the link dies" is not a claim about a link — it is a claim
/// about what a panel displays while a machine it can no longer hear keeps
/// moving. A fake source cannot make that claim false, because nothing under
/// it changes while the link is down.
///
/// ## Every write case counts at the plant
///
/// `RunningServer.actuationCount` is taken inside the OPC UA server, by the
/// node that received the write, before any answer is composed. A duplicated
/// command is **invisible to a read-back** — the node holds the same number
/// whether it was moved once or twice — so a suite that asserted on what the
/// panel was told afterwards would pass on a stack that silently actuated
/// twice. This is the only instrument in the repository that can fail that
/// way, and the reason the bench stands up a real plant at all.
///
/// ## Budgets
///
/// Generous and named. Nothing here is a latency measurement; every budget is
/// a liveness bound that converts *nothing happening* into a named failure,
/// and a tight one on a loaded CI box produces a red suite that says nothing
/// about the code.
@TestOn('!windows')
@Tags(['opcua', 'e2e'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/plant_bench.dart';

/// The ramping node: it moves every 100 ms, so a frozen reading is visible.
final String speedKey = plantKey('HALL1', 'CN01.speed_hz');

/// The recording node: what a write actuates, and what the plant counts.
const String setpointNode = 'CN01.setpoint_kg';
final String setpointKey = plantKey('HALL1', setpointNode);

/// The struct with an enum member — #588's violet-conveyor shape.
final String driveKey = plantKey('HALL1', 'CN01.drive');

/// A rate that sits at zero: "no data" and "zero" must not look the same.
final String rateKey = plantKey('HALL1', 'CN01.rate');

/// After this much silence the client must have stopped calling its cache
/// good. `ClientConfig.freshnessDeadline` is 3 s by default; the margin is for
/// the sweep's own cadence and a loaded machine, not for the property.
const Duration honestyDeadline = Duration(seconds: 8);

void main() {
  group('the screen stops lying when the link dies', () {
    test(
        'the panel publishes the link-staleness verdict once it can no longer '
        'hear the plant, while the plant goes on moving without it', () async {
      final bench = await standUpPlant();
      expect(bench.panel.read(speedKey)!.quality.isGood, isTrue,
          reason: 'the case begins from a link that demonstrably worked');
      expect(bench.panel.viewIsStale, isFalse);

      // The plant keeps ramping throughout, which is the difference between
      // this file and every harness with a fake source behind the server:
      // while the link is down the number on the panel is not merely old, it
      // is wrong about a machine that has moved on.
      //
      // `blackhole` is the fault this project says it is built against — "a
      // peer that has not closed anything and has simply stopped answering,
      // which no `onDone` will ever report" (`fault_proxy.dart:564-566`).
      bench.link.blackhole();

      await until(() => bench.panel.viewIsStale,
          within: honestyDeadline,
          describe: "the panel to publish that its view is no longer the "
              "current connection's");

      // And it stays honest. A one-shot check at the end of a window is a
      // claim about one instant; the promise is about every instant.
      await neverDuring(
        () => !bench.panel.viewIsStale,
        const Duration(seconds: 3),
        describe: 'the panel called its view fresh again while the link was '
            'still blackholed and the plant had moved on without it',
      );
    });

    test(
        'LAYERING: the per-value quality is NOT the link-staleness signal, '
        'and a consumer that reads it instead re-opens the rig defect',
        () async {
      // This case pins a seam that has already failed in the field, so the
      // next time it slips it is a red test and not a site visit.
      //
      // `lib/core/value_freshness.dart:4-14` records it: on 2026-09-07 an
      // attended rig run cut a connected panel's link, and at +25 s and again
      // at +65 s the app-bar chip read yellow `No gateway` while **every plant
      // value on the home page still rendered definite**. The cause was not
      // missing plumbing — `viewIsStale` and `viewFreshness` simply "had no
      // reader in any `lib/`".
      //
      // The split is deliberate: `read(key)` keeps the last value the plant
      // actually sent, at the quality it actually had, and link-level
      // staleness is published separately. Both halves are asserted, because
      // a change to EITHER changes the contract every widget depends on:
      //   * if the quality starts degrading, this goes red and the withholding
      //     story has moved — a decision, not a tidy-up;
      //   * if `viewIsStale` stops flipping, the rig defect is back.
      final bench = await standUpPlant();
      bench.link.blackhole();

      await until(() => bench.panel.viewIsStale,
          within: honestyDeadline, describe: 'the staleness verdict');

      // Well past any per-value deadline, and the ramp has gone round many
      // times at the plant.
      await Future<void>.delayed(const Duration(seconds: 6));

      expect(bench.panel.read(speedKey)!.quality.isGood, isTrue,
          reason: 'the client deliberately does NOT degrade a value it merely '
              'stopped hearing about — it keeps the last thing the plant '
              'actually said. Anything rendering from this alone shows a '
              'definite number for a machine it cannot hear, which is what '
              'the rig saw at +65 s');
      expect(bench.panel.viewIsStale, isTrue,
          reason: 'and the verdict a widget must actually consult is true');
    });

    test('the panel recovers to what is true NOW, not to a replayed backlog',
        () async {
      final bench = await standUpPlant();

      bench.link.blackhole();
      await until(() => bench.panel.viewIsStale,
          within: honestyDeadline,
          describe: 'the view to be declared stale');

      // Long enough that a queue would have built a visible backlog: the ramp
      // steps every 100 ms.
      await Future<void>.delayed(const Duration(seconds: 3));
      bench.link.blackhole(enabled: false);

      await until(() => !bench.panel.viewIsStale,
          within: const Duration(seconds: 45),
          describe: 'the panel to declare its view fresh again — which the '
              'supervisor does only from `_enter(LinkState.ready)`, after '
              'every page snapshot has been adopted, so this means "these '
              'values are the current connection\'s" and not "a frame '
              'arrived"');

      // Conflate, never queue: what comes back is the latest value, and the
      // panel converges rather than animating thirty seconds of history it
      // cannot act on. Sampled twice a second apart — a backlog being drained
      // would still be marching through old values here.
      final first = bench.panel.read(speedKey)!.value! as num;
      await Future<void>.delayed(const Duration(seconds: 1));
      final second = bench.panel.read(speedKey)!.value! as num;
      expect(second, isNot(equals(first)),
          reason: 'a recovered link is a live link: the ramp is still moving '
              'and the panel is still following it');
    });

    test('zero arrives as a number, not as an absence', () async {
      final bench = await standUpPlant();
      final rate = bench.panel.read(rateKey)!;
      expect(rate.value, 0,
          reason: 'a rate sitting at zero is a number; "no data" and "zero" '
              'look identical on a chart and only one of them is a fault');
      expect(rate.quality.isGood, isTrue,
          reason: 'and on arrival it is a good zero, not an uncertain one');
    });

    test(
        'CHARACTERISATION: a live, correct, unchanging value is withheld '
        'while the link is healthy', () async {
      // Not an approval. This records what the stack does today, because the
      // behaviour is load-bearing for an operator and is currently asserted
      // nowhere.
      //
      // `CN01.rate` is published by a running PLC over a live subscription and
      // its value is correct. It is withheld anyway, because an OPC UA
      // monitored item reports ON CHANGE and there is no per-value keep-alive
      // on the upstream path — `requestedMaxKeepAliveCount` is the
      // subscription's keep-alive (opcua_upstream_link.dart:856,997) and a
      // keep-alive message carries no data values, so nothing restamps what it
      // covers.
      //
      // Most tags on a real plant are constant most of the time: a setpoint, a
      // recipe number, a mode that has been in auto all shift, a counter on a
      // stopped line. If this is the intended behaviour then every one of them
      // renders `---` `staleAfter` after its last change, and an operator
      // learns that the badge means nothing — which is how a genuinely stale
      // value gets believed later.
      //
      // If it is fixed, this case goes red and should be REPLACED by the
      // assertion that a live constant stays good, not re-baselined.
      final bench = await standUpPlant();
      expect(bench.panel.read(rateKey)!.quality.isGood, isTrue);
      expect(bench.panel.linkState, LinkState.ready);

      await until(() => !bench.panel.read(rateKey)!.quality.isGood,
          within: const Duration(seconds: 15),
          describe: 'the unchanging rate to be withheld');

      expect(bench.panel.linkState, LinkState.ready,
          reason: 'the link never broke: nothing is wrong except that the '
              'value did not change');
      expect(bench.panel.read(rateKey)!.value, 0,
          reason: 'and the withheld number is still the right one — this is '
              'the stack hiding a correct value, not losing it');
      expect(bench.panel.read(speedKey)!.quality.isGood, isTrue,
          reason: 'while a neighbour that does change is still believed, '
              'which is what makes this about change and not about the link');
    });
  });

  group('a write is never applied twice, counted at the machine', () {
    test('a write whose answer never arrives actuates at most once', () async {
      final bench = await standUpPlant();
      expect(bench.actuations(setpointNode), 0,
          reason: 'nothing has commanded this node yet');

      // Cut the answer's way home the moment the command is on the wire. The
      // command may or may not reach the plant; that is the whole point of the
      // three-state outcome.
      final pending = bench.panel.write(setpointKey, 21.5);
      bench.link.blackhole();

      final outcome = await pending;
      expect(outcome, isNot(isA<WriteApplied>()),
          reason: 'an answer that never came back cannot be reported as a '
              'fact about the machine');

      bench.link.blackhole(enabled: false);
      await until(() => bench.panel.linkState == LinkState.ready,
          within: const Duration(seconds: 45),
          describe: 'the panel to reconnect and re-query its unresolved '
              'command');
      // Time for a retry to have happened, if one were going to.
      await Future<void>.delayed(const Duration(seconds: 3));

      final count = bench.actuations(setpointNode);
      expect(count, lessThanOrEqualTo(1),
          reason: 'NOTHING auto-retries: not the RPC layer, not the send '
              'buffer, not the client. A second actuation here is a second '
              'command to a machine that nobody issued');

      // The sharper half: the outcome and the count must agree. A
      // `notReceived` is the only outcome that says "safe to re-send", so it
      // must be backed by the plant never having moved.
      if (outcome is WriteNotReceived) {
        expect(count, 0,
            reason: 'notReceived is the one outcome that invites a re-send; '
                'if the plant moved, that invitation is a duplicate '
                'actuation waiting to happen');
      }
    });

    test('a burst of writes across a flapping link never over-actuates',
        () async {
      final bench = await standUpPlant();
      const sent = <double>[31.0, 32.0, 33.0, 34.0, 35.0];

      bench.link.flap(const Duration(milliseconds: 700),
          const Duration(milliseconds: 400));
      final outcomes = <WriteResult>[];
      for (final value in sent) {
        try {
          outcomes.add(await bench.panel.write(setpointKey, value));
        } on Object {
          // A write that throws is a write that did not resolve; the count at
          // the plant is still the thing under test.
        }
      }
      bench.link.flap(Duration.zero, Duration.zero, enabled: false);

      await until(() => bench.panel.linkState == LinkState.ready,
          within: const Duration(seconds: 60),
          describe: 'the link to settle after the flapping stopped');
      await Future<void>.delayed(const Duration(seconds: 3));

      final actuations = bench.server().actuationsOf(setpointNode);
      // **Non-vacuity first.** "At most five" is trivially satisfied by zero,
      // and zero is what a flap that happened to block every write would
      // produce — a green case proving only that nothing got through. The
      // upper bound means something only once something landed.
      expect(actuations, isNotEmpty,
          reason: 'not one of five writes reached the plant, so the bound '
              'below is satisfied by an empty link rather than by the '
              'no-retry rule. Slow the flap down until writes get through');
      expect(actuations.length, lessThanOrEqualTo(sent.length),
          reason: 'five commands cannot become six movements: '
              '${actuations.map((a) => a.value.asDouble).toList()}');

      // Nothing was invented on the way. A value at the plant that the panel
      // never sent would mean a frame was replayed, reordered or synthesised.
      for (final actuation in actuations) {
        expect(sent, contains(actuation.value.asDouble),
            reason: 'the plant moved to a value no panel ever commanded');
      }

      // And every outcome reported as applied really did reach the plant.
      final applied = outcomes.whereType<WriteApplied>().length;
      expect(actuations.length, greaterThanOrEqualTo(applied),
          reason: 'an outcome cannot report more actuations than the machine '
              'performed');
    });

    test('the same command id is not actuated twice across a reconnect',
        () async {
      final bench = await standUpPlant();
      final first = await bench.panel.write(setpointKey, 44.0);
      expect(first, isA<WriteApplied>());
      await until(() => bench.actuations(setpointNode) == 1,
          describe: 'the first write to land at the node');

      // Drop the session entirely. On redial the client re-queries
      // `writeStatus` for anything unresolved; nothing here is unresolved, so
      // nothing may be re-sent.
      //
      // Through `breakAndHeal` so the drop is PROVEN to have happened: a
      // `killOnce` that did nothing would leave this case asserting that a
      // link which never broke did not replay a write.
      await breakAndHeal(bench, pull: bench.link.killOnce);
      await Future<void>.delayed(const Duration(seconds: 3));

      expect(bench.actuations(setpointNode), 1,
          reason: 'a resolved write is finished business; a reconnect must '
              'not replay it');
    });
  });

  group('one bad tag costs one tag', () {
    test('a node that leaves the address space does not take the page with it',
        () async {
      final bench = await standUpPlant();
      expect(bench.panel.read(rateKey)!.quality.isGood, isTrue);

      // What a key mapping pointing at a tag the PLC does not have looks like
      // from a panel: BadNodeIdUnknown, for ever.
      bench.server().remove('CN01.rate');

      await until(() => !bench.panel.read(rateKey)!.quality.isGood,
          within: const Duration(seconds: 30),
          describe: 'the removed node to stop reading good at the panel');

      // Containment. The neighbours are still live, and the panel is still
      // following the ramp.
      final before = bench.panel.read(speedKey)!.value! as num;
      await until(() => bench.panel.read(speedKey)!.value != before,
          within: const Duration(seconds: 20),
          describe: 'the rest of the page to keep flowing while one tag is '
              'broken');
      expect(bench.panel.read(speedKey)!.quality.isGood, isTrue,
          reason: 'a missing tag is one tag, not a page');
      expect(bench.panel.linkState, LinkState.ready,
          reason: 'and it is certainly not a reason to drop the link');
    });
  });

  group('conflation holds under a starved link', () {
    test('a throttled panel converges on the latest value, not a backlog',
        () async {
      final bench = await standUpPlant();

      // A trickle, against a ramp stepping every 100 ms across a page of
      // keys: production far outruns delivery.
      bench.link.throttleBytesPerSec = 256;
      await Future<void>.delayed(const Duration(seconds: 4));
      bench.link.throttleBytesPerSec = null;

      await until(() => bench.panel.linkState == LinkState.ready,
          within: const Duration(seconds: 45),
          describe: 'the link to recover after the throttle lifted');

      // The property: once the pipe is open again the panel is following the
      // plant within a couple of ramp steps, rather than working through
      // everything it missed.
      await until(
        () {
          final value = bench.panel.read(speedKey);
          return value != null && value.quality.isGood;
        },
        within: const Duration(seconds: 30),
        describe: 'a good value after the throttle lifted',
      );
      final first = bench.panel.read(speedKey)!.value! as num;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final second = bench.panel.read(speedKey)!.value! as num;
      expect(second, isNot(equals(first)),
          reason: 'a conflating buffer hands over the newest value per key; a '
              'queue would still be draining what it kept');
    });
  });

  group('the shapes that broke things, through the gateway', () {
    test('an enum inside a struct keeps its field names across a reconnect',
        () async {
      final bench = await standUpPlant();
      expect(bench.panel.read(driveKey)!.toString(), contains('run_mode'),
          reason: 'the type dictionary reached the panel on the first '
              'snapshot');

      await breakAndHeal(bench, pull: bench.link.killOnce);

      // The defect this shape is named for: a panel colours equipment from
      // enum NAMES, so a run_mode that survives a resync as a bare integer
      // draws every conveyor violet. A resync is a fresh snapshot, and a
      // fresh snapshot is exactly where a type dictionary can be dropped.
      //
      // Asserted on the value the wait itself accepted, never on a re-read:
      // after a resync the store is re-seeded, so a second `read` can answer a
      // different value than the one that satisfied the condition — and a case
      // that waits for one value and asserts on another is reporting a race.
      late final String recovered;
      await until(
        () {
          final value = bench.panel.read(driveKey);
          if (value?.value == null) return false;
          recovered = value.toString();
          return true;
        },
        within: const Duration(seconds: 30),
        describe: 'the struct to come back after the resync',
      );
      expect(recovered, contains('run_mode'),
          reason: 'the member names must survive a resync, not just the '
              'first snapshot');
    });
  });
}
