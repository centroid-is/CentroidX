/// S3: a `writeStatus` readback must never walk a value **backwards**.
///
/// **The defect, in the plant.** Panel A writes 7001 to a setpoint at t0. The
/// answer is lost and the link dies under it, so the write resolves
/// `WriteUnknown` and its command stays in the unresolved set — correctly.
/// During the outage the tag moves to 8000 at t1 > t0, because a second panel
/// wrote it, or because the PLC's own logic did. Panel A reconnects; the
/// resync snapshot lands 8000, which is the truth; and *then* the reconnect's
/// `writeStatus` re-query answers `WriteApplied(readback: 7001, at: t0)` and
/// `_adoptReadback` puts 7001 back on the mimic — under [Quality.good], with a
/// **source time an hour older than the value it replaced**.
///
/// The gateway conflates, so it will not re-push 8000 unless the tag changes
/// again. On a quiet plant the wrong number therefore stands for the rest of
/// the shift, and it stands wearing good quality, which is the one badge that
/// tells an operator the figure can be acted on. That is the whole of the
/// project's stated core value inverted: "operators can always trust what the
/// screen shows".
///
/// **Why the existing suite could not see it.** `gate/long_outage_gate_test
/// .dart:192-196` uses *separate* watched and written keys, on purpose and with
/// its reason recorded — "one key would make a readback adopted from a write
/// indistinguishable from a resynced value". That is a good reason for F8's
/// question and it structurally excludes this one: the collision only exists
/// when the key an operator is pressing a button on **is** the key on the
/// mimic, which on a setpoint is always. So both arms below write and read the
/// same tag, and that is the point of the file rather than an incidental
/// choice.
///
/// **Where the guard goes, and where it deliberately does not.** Not in
/// `ValueStore.applyBatch`: an out-of-band batch carrying no `seq` is how a
/// *snapshot* is applied too, and a snapshot legitimately carries values older
/// than the cache when the plant itself is quiet — a store that refused older
/// stamps outright would refuse the recovery path this project resyncs
/// through. The comparison belongs where the two facts are both in hand and
/// their relative age means something: the adopt site, which knows it is
/// holding one device readback against one cached reading of the same tag.
///
/// **The decline is recorded rather than silent.** A readback that is dropped
/// with no trace is a gateway clock skew nobody can diagnose from a panel: the
/// number is simply right, and the write confirmation simply never shows. It
/// goes on `complaints`, which is the surface `_answerFor` already uses for
/// "something arrived that could not be taken at face value" and which the
/// panel puts in front of an engineer.
@TestOn('vm')
@Tags(['faults'])
library;

import 'dart:io' show Platform;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fault_fixture.dart';
import 'support/gate_bands.dart';
import 'support/write_answer_restamp.dart';
import 'support/runner_budget.dart';

/// The one tag both arms write to and watch. Same key, which is the file.
const String _key = scenarioKey;

/// What the tag holds before anybody touches it.
const int _beforeWrite = 7000;

/// What the operator commands, and therefore what the lost write's readback
/// says the device took.
const int _commanded = 7001;

/// What somebody else moves the tag to while panel A cannot hear it. Distinct
/// from [_commanded] by more than a rounding, so a mimic showing one of them
/// cannot be mistaken for the other in a failure message.
const int _movedDuringOutage = 8000;

/// An instant no plant clock will ever produce on its own: one second past the
/// epoch.
///
/// Used by the second arm as the `at` on a write answer, so that "this readback
/// is older than what is cached" is true by construction rather than by a
/// millisecond of luck on a fast runner. A stamp this old is also exactly what
/// a gateway whose clock has not been set yet reports after a cold boot, which
/// is the ordinary way this arrives in a real plant.
const int _epochish = 1000;

void main() {
  useRunnerBudgets();

  group('S3 — a readback may not put an older reading on the mimic', () {
    // **Skipped on Windows, and the reason is the lever rather than the
    // platform.**
    //
    // This case needs a specific interleaving: the write request arrives whole,
    // the plant records the attempt, and the *answer* is truncated on its way
    // back. `cutMidFrame(n)` cannot express that. It spends a byte budget on
    // the next n bytes travelling server->client, whatever they belong to, and
    // the gateway's tick engine puts a frame on that line every 100 ms
    // (`ServerConfig.tick`, `server_config.dart:435`). A tick is comparable in
    // size to the `frameLength ~/ 2` budget armed below, so the cut lands on a
    // tick unless the whole write round trip completes inside the gap — about
    // 5 ms of a 100 ms window on a developer's machine, and not reliably so on
    // a loaded hosted agent. When the tick wins, the link dies before the
    // request is sent, the plant records **0** attempts, and the case fails on
    // its own fixture-check: "this case is not the defect it is named for".
    //
    // Three fixes were tried and rejected rather than assumed:
    //   * quiescing the inbound direction before arming — the competition just
    //     resumes at the next tick, 100 ms later. This was committed in
    //     8a865762 and the next Windows run failed identically;
    //   * a wider `n` — a budget too wide for ticks to spend is also wide
    //     enough to let the whole answer through, so nothing is truncated and
    //     the write resolves instead of going unknown;
    //   * scaling the case's budgets — this is not slowness, it is an ordering.
    //
    // `gate/cut_mid_write_gate_test.dart` arms the same lever for the same
    // interleaving. This comment used to say that file was safe because it
    // "asserts only that the outcome is WriteUnknown" — that was wrong. It
    // asserts `upstreamWriteAttempts == 1` at line 138, exactly as this case
    // does. It simply had not failed yet, which on a race is not the same as
    // being immune, and the Windows agent produced it one commit later. Both
    // are skipped there now, for this one reason.
    //
    // The property itself — a readback may not walk a value backwards — is not
    // platform-specific: it is measured on macOS and Linux every run, and the
    // two arms below cover the same rule on the direct path with no fault
    // injection at all, so those keep running on all three platforms. The
    // durable fix is a lever that can cut a *named* frame.
    test(
        'a writeStatus answer about a lost write does not overwrite the value '
        'that arrived while the link was down', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        seed: (plant) => plant.setValue(_key, _beforeWrite,
            sourceTime: DateTime.now().toUtc()),
      );
      await until('the link', () => fixture.client.isReady);

      // ---------------------------------------------------------------- the
      // control write, which measures the frame the cut is placed inside and
      // proves the write path was healthy before the fault. Borrowed whole
      // from `gate/cut_mid_write_gate_test.dart`, including the reason a
      // hard-coded byte count is refused: a case that has quietly stopped
      // truncating anything still passes every assertion about the caller's
      // verdict, because the link would simply die a little later.
      final controlCmd = newUlid();
      final control = await fixture.client
          .write(_key, _beforeWrite, cmd: controlCmd)
          .timeout(recovery);
      expect(control, isA<WriteApplied>(),
          reason: 'the control write came back $control on an unfaulted link, '
              'so the page was not live and everything below would be '
              'measuring a broken fixture rather than a stale readback');

      final frameLength = fixture.seam.inbound
          .firstWhere((frame) => frame.contains(controlCmd),
              orElse: () => fail('no inbound frame mentions the control '
                  'command, so there is nothing to measure the cut against '
                  'and the cut length would be a magic number'))
          .length;
      fixture.proxy.cutMidFrame(frameLength ~/ 2);

      // ---------------------------------------------------------------- t0:
      // the write that reaches the plant and whose answer is lost. The request
      // arrives whole — the lever arms the server->client direction only — so
      // the device really does take 7001 and the gateway really does record
      // `applied` for this command. What is lost is only the panel's knowledge
      // of it, which is precisely the shape that makes the re-query necessary
      // and the shape that makes its answer dangerous.
      final lostCmd = newUlid();
      final lost =
          await fixture.client.write(_key, _commanded, cmd: lostCmd).timeout(recovery);
      expect(lost, isA<WriteUnknown>(),
          reason: 'the write came back $lost with the answer truncated on the '
              'wire. Nobody can know whether the plant took it, and this case '
              'needs it to stay unresolved so that the reconnect re-queries '
              'it — which is the path the stale readback arrives down');
      expect(fixture.client.debugUnresolvedCmds, contains(lostCmd),
          reason: 'the lost command is not in the unresolved set, so no '
              'writeStatus re-query will ever ask about it and the rest of '
              'this case would be watching a recovery that never happens');
      expect(fixture.served.upstreamWriteAttempts(lostCmd), 1,
          reason: 'the plant recorded '
              '${fixture.served.upstreamWriteAttempts(lostCmd)} attempts for '
              'the lost command. Zero means the request never arrived, the '
              'gateway has no `applied` outcome to answer with, and this case '
              'is not the defect it is named for');

      // ---------------------------------------------------------------- t1:
      // somebody else moves the tag while panel A is dark. The stamp is
      // explicit and read afterwards, because the whole assertion is an
      // ordering between two instants and `FakeStateMan.setValue` leaves
      // `sourceTime` null unless it is given one (`fake_state_man.dart:332`) —
      // a null stamp is a value nothing can be compared against, and this case
      // would then be vacuous no matter what the client did.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final movedAt = DateTime.now().toUtc();
      fixture.served.setValue(_key, _movedDuringOutage, sourceTime: movedAt);

      // **The plant is brought to a standstill before the link comes back, and
      // this is load-bearing rather than tidiness.** `FakeStateMan` sweeps
      // freshness every quarter of its 300 ms `staleAfter` and degrades a value
      // that has stopped arriving, which is one more push — carrying the
      // plant's own $_movedDuringOutage — landing at an instant nothing here
      // controls. The first run of this case caught exactly that: the stale
      // readback *was* adopted, the degrade push landed 80 ms later carrying
      // the right value again, and the row's headline assertion went green over
      // the top of the defect it exists to catch. A degraded value is terminal
      // for a tag that is not moving (`fake_state_man.dart:517` skips a key
      // already at or below `badStale`), so waiting for the degrade *here*
      // makes the adopt the last event on this key rather than the
      // second-to-last one.
      await until('the plant to mark the value it moved as stale',
          () => fixture.served.read(_key)?.quality == Quality.badStale,
          budget: recovery);

      // ------------------------------------------------------------ recovery.
      // Lifting the cut is the only way back: it is sticky across pairs, and
      // at this length it lands inside the WebSocket handshake response, so no
      // dial would ever complete while it is armed.
      fixture.proxy.cutMidFrame(null);
      await until('the link back after the cut was lifted',
          () => fixture.client.isReady,
          budget: const Duration(seconds: 15));

      // The snapshot is applied before the client enters `ready`, and the
      // re-query is issued on entry to `ready` and nowhere else
      // (`remote_state_man.dart:1394-1399`) — so the ordering this case needs
      // is guaranteed by construction rather than by a delay: the truth lands
      // first and the stale readback arrives on top of it.
      await until('the resync to put the plant\'s current value on the page',
          () => fixture.client.read(_key)?.value == _movedDuringOutage,
          budget: recovery);
      final resynced = fixture.client.read(_key);

      await until('the recovered panel to be answered about the lost write',
          () => fixture.client.debugWriteStatusAnswers
              .any((answer) => answer.cmd == lostCmd),
          budget: recovery);
      final answer = fixture.client.debugWriteStatusAnswers
          .firstWhere((result) => result.cmd == lostCmd);

      // Long enough for an adopt to have happened, because the property below
      // is that one did *not*. A poll cannot establish an absence.
      await Future<void>.delayed(settle);

      final now = fixture.client.read(_key);
      print('S3: resync landed ${resynced?.value} at ${resynced?.sourceTime}; '
          'the re-query answered $answer '
          '(${answer is WriteApplied ? 'readback ${answer.readback} at '
              '${DateTime.fromMillisecondsSinceEpoch(answer.at, isUtc: true)}' : 'no readback'}); '
          'the page now shows ${now?.value} at ${now?.sourceTime} '
          'quality ${now?.quality}; complaints ${fixture.client.complaints}');

      // ANTI-VACUITY. Every clause below is about an answer that carried an
      // older readback for this key; an answer of any other shape means the
      // case measured nothing at all and must say so rather than pass.
      expect(answer, isA<WriteApplied>(),
          reason: 'the gateway answered $answer about a command it decoded, '
              'forwarded, and watched the plant apply. Without an `applied` '
              'answer there is no readback to adopt and this case is not '
              'exercising the adopt path — nothing below would be evidence of '
              'anything');
      final applied = answer as WriteApplied;
      expect(applied.readback, _commanded,
          reason: 'the re-query answered with a readback of '
              '${applied.readback} rather than the $_commanded the plant took '
              'at t0. This case is about a *stale* reading being adopted over '
              'a newer one, so a readback that already agrees with the page '
              'would make the assertion below true for free');
      expect(resynced?.quality, Quality.badStale,
          reason: 'the resync put ${resynced?.quality} on the page, not the '
              'stale badge the plant was waited into. The wait above exists so '
              'that the adopt is the last thing to touch this key — a plant '
              'still due a degrade push would heal a wrongly adopted readback '
              'a tick later, and the row would go green over the top of the '
              'defect it is named for');
      expect(resynced?.sourceTime, isNotNull,
          reason: 'the value the resync put on the page carries no source '
              'time, so there is nothing for a freshness comparison to compare '
              'against and the guard cannot be shown to have fired. That is '
              'the `FakeStateMan.setValue` default leaking into the case — the '
              'seed and the mid-outage move must both pass `sourceTime:`');
      expect(
          DateTime.fromMillisecondsSinceEpoch(applied.at, isUtc: true)
              .isBefore(resynced!.sourceTime!),
          isTrue,
          reason: 'the readback is stamped '
              '${DateTime.fromMillisecondsSinceEpoch(applied.at, isUtc: true)} '
              'and the value on the page is stamped ${resynced.sourceTime}, so '
              'the readback is NOT older and there is no backwards step for '
              'the guard to refuse. The mid-outage move has to land after the '
              'write it is racing, which is what the delay before it is for');

      // ------------------------------------------------------------ THE ROW.
      expect(now?.value, _movedDuringOutage,
          reason: 'the page shows ${now?.value} after the recovery, against a '
              'plant holding $_movedDuringOutage. The re-query answered '
              '`applied` with the readback $_commanded stamped '
              '${DateTime.fromMillisecondsSinceEpoch(applied.at, isUtc: true)} '
              '— a reading from *before* the outage — and it was adopted over '
              'the value the resync had just established. The gateway '
              'conflates, so nothing will correct this until the tag moves '
              'again: on a quiet plant an operator reads $_commanded, under '
              'good quality, for the rest of the shift, on a setpoint that '
              'actually holds $_movedDuringOutage');
      expect(now?.quality, resynced.quality,
          reason: 'the page shows ${now?.quality} for a tag the resync '
              'established as ${resynced.quality}. This is the half of the '
              'defect that bites hardest: the adopt site stamps '
              '${Quality.good} unconditionally, so a readback adopted over a '
              'value the gateway had already marked stale does not merely put '
              'an old number on the mimic — it *launders* it, and the operator '
              'is shown a figure wearing the one badge that says it can be '
              'acted on. Refusing the readback has to leave the last confirmed '
              'reading exactly as it was, badge included');
      // Against what the *resync* established rather than against [movedAt]
      // itself: `DynamicValue.toJson` puts `millisecondsSinceEpoch` on the
      // wire, so the microseconds `DateTime.now()` gives the plant are gone by
      // the time the page has it, and comparing the two is a test that can
      // never pass for a reason that has nothing to do with the client.
      expect(now?.sourceTime, resynced.sourceTime,
          reason: 'the page shows source time ${now?.sourceTime} against the '
              '${resynced.sourceTime} the resync established (the plant '
              'stamped $movedAt, to the millisecond the wire carries). A value '
              'whose stamp walked backwards is one every downstream age '
              'calculation — the freshness badge, the trend, the alarm dwell — '
              'now computes from the wrong instant, and it is the half of this '
              'defect that survives even when the two values happen to be '
              'equal');
      expect(fixture.client.complaints, isNotEmpty,
          reason: 'the client refused the readback and said nothing about it. '
              'A silent decline is a gateway clock skew nobody can diagnose '
              'from a panel: the number on the mimic is simply right and the '
              'operator\'s write confirmation simply never appears. The '
              'refusal belongs on the same surface `_answerFor` records a '
              'misaligned answer on');
      expect(fixture.client.debugWritesSent, 2,
          reason: 'the panel put ${fixture.client.debugWritesSent} writes on '
              'the wire for the two an operator issued. Nothing in this file '
              'licenses a re-send, and a recovery that repeats a write is a '
              'second actuation of a machine somebody commanded once');
    },
        timeout: const Timeout(Duration(seconds: 90)),
        skip: Platform.isWindows
            ? 'cutMidFrame cannot target the write answer: the gateway ticks '
                'onto the same line every 100 ms and spends the byte budget '
                'first unless the round trip beats it, which it does not '
                'reliably on a hosted agent. See the comment on this case.'
            : null);

    test(
        'a write answer carrying a readback older than the page is refused on '
        'the direct path too', () async {
      final seededAt = DateTime.now().toUtc();
      final fixture = await faultFixture(
        keys: const {_key},
        corrupt: restampAppliedWriteAnswer('$_epochish'),
        seed: (plant) =>
            plant.setValue(_key, _movedDuringOutage, sourceTime: seededAt),
      );
      await until('the link', () => fixture.client.isReady);
      await until('the page to carry the plant\'s seeded value',
          () => fixture.client.read(_key)?.value == _movedDuringOutage,
          budget: recovery);

      final cmd = newUlid();
      Object? thrown;
      WriteResult? outcome;
      // Captured in the same microtask the write resolves in, which is the
      // only instant this path can be read at: the plant really did take the
      // write, so the subscription is about to push $_commanded with no source
      // time at all, and a page read after that arrives cannot tell an adopt
      // that was refused from one that was overwritten a tick later. A future
      // completing schedules a microtask, and the microtask queue drains
      // before the next I/O event, so nothing from the socket can land between
      // `_adoptReadback` and this line.
      DynamicValue? pageOnResolution;
      try {
        outcome =
            await fixture.client.write(_key, _commanded, cmd: cmd).timeout(recovery);
        pageOnResolution = fixture.client.read(_key);
      } catch (error) {
        thrown = error;
      }

      print('S3 direct: outcome $outcome, threw $thrown, page on resolution '
          '${pageOnResolution?.value} at ${pageOnResolution?.sourceTime}, now '
          '${fixture.client.read(_key)?.value} at '
          '${fixture.client.read(_key)?.sourceTime}; complaints '
          '${fixture.client.complaints}');

      // ANTI-VACUITY: the restamp landed. An injector that matched nothing is
      // the vacuous pass every fault test is one typo away from.
      expect(fixture.seam.inbound.any((frame) => frame.contains('"at":$_epochish')),
          isTrue,
          reason: 'no inbound frame carries the restamped `at`, so the answer '
              'the client decoded was the gateway\'s own and this case '
              'measured an ordinary applied write. Inbound so far: '
              '${fixture.seam.inbound}');

      expect(thrown, isNull,
          reason: 'write() threw $thrown instead of resolving. A write reports '
              'its outcome as a value and never as an exception '
              '(`remote_state_man.dart:786-796`): a call site that has to '
              'catch to find out what the machine did is a call site that will '
              'forget to');
      expect(outcome, isA<WriteApplied>(),
          reason: 'the write resolved $outcome. The gateway said applied and '
              'named a readback, and refusing to *adopt* a stale stamp is not '
              'grounds to downgrade the outcome the gateway established — '
              'reporting unknown here sends an operator out to look at a '
              'machine that reported back');
      expect(
          pageOnResolution?.sourceTime,
          isNot(DateTime.fromMillisecondsSinceEpoch(_epochish, isUtc: true)),
          reason: 'the page carries source time '
              '${pageOnResolution?.sourceTime} the instant the write resolved, '
              'which is the stamp the corrupted answer put on it. Every '
              'downstream age calculation — the freshness badge, the trend '
              'window, an alarm dwell — now reads this tag as fifty-six years '
              'old, and the value it is stamping is the one the operator just '
              'typed rather than anything the plant confirmed at that instant');
      expect(fixture.client.complaints, isNotEmpty,
          reason: 'the client adopted, or silently dropped, a readback stamped '
              '${DateTime.fromMillisecondsSinceEpoch(_epochish, isUtc: true)} '
              'onto a page whose value is stamped $seededAt. This is the same '
              'guard as the arm above, reached through `_write` rather than '
              'through `_settle`: a fix installed only on the recovery path '
              'leaves the direct path — every setpoint an operator types, on '
              'every healthy link — walking values backwards whenever the '
              'gateway\'s clock is behind the plant\'s');
      expect(
          fixture.client.complaints.any((line) => line.contains(_key)),
          isTrue,
          reason: 'the client complained about something, but no line names '
              '$_key: ${fixture.client.complaints}. A refusal that does not '
              'say which tag it refused is one nobody can act on, and it would '
              'let this assertion pass on a complaint about something else '
              'entirely');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a readback sharing an instant with the page is still adopted',
        () async {
      // **The other side of the boundary, and it was found by sabotage.**
      // Widening the refusal from `stamp.isBefore(cached)` to
      // `!stamp.isAfter(cached)` — one character of difference, and the
      // obvious way to write the guard — turned nothing red anywhere in this
      // package, including the full 44-check contract suite. The reason is
      // structural rather than an oversight in some case: `FakeStateMan`
      // applies a write's readback with `sourceTime` null
      // (`fake_state_man.dart:936`), so the ordinary write path in every
      // harness here leaves the store holding values with no stamp at all, and
      // a comparison against null short-circuits. Nothing in the package had
      // ever put a *stamped* value on the page and then written to it.
      //
      // The equality case is not a curiosity. It is the ordinary race this
      // whole method exists for: the gateway answers the write on the RPC path
      // and pushes the same reading on the subscription path, and on a source
      // that stamps its readings both carry the instant the device reported.
      // Refusing an equal stamp would leave the pending badge on screen for a
      // whole tick after every confirmed write — the exact symptom
      // `_adoptReadback`'s doc opens by describing.
      final seededAt = DateTime.now().toUtc();
      // To the millisecond the wire actually carries, so "the same instant" is
      // the same instant on both sides of the comparison rather than a
      // microsecond apart.
      final onTheWire = DateTime.fromMillisecondsSinceEpoch(
          seededAt.millisecondsSinceEpoch,
          isUtc: true);
      final fixture = await faultFixture(
        keys: const {_key},
        corrupt:
            restampAppliedWriteAnswer('${seededAt.millisecondsSinceEpoch}'),
        seed: (plant) =>
            plant.setValue(_key, _movedDuringOutage, sourceTime: seededAt),
      );
      await until('the link', () => fixture.client.isReady);
      await until('the page to carry the plant\'s seeded value',
          () => fixture.client.read(_key)?.value == _movedDuringOutage,
          budget: recovery);
      expect(fixture.client.read(_key)?.sourceTime, onTheWire,
          reason: 'the page carries ${fixture.client.read(_key)?.sourceTime} '
              'rather than the seeded $onTheWire, so the readback below will '
              'not be sharing an instant with anything and this arm is testing '
              'the ordinary newer-than case the others already cover');

      final outcome = await fixture.client
          .write(_key, _commanded, cmd: newUlid())
          .timeout(recovery);
      final pageOnResolution = fixture.client.read(_key);
      print('S3 equal stamps: outcome $outcome, page on resolution '
          '${pageOnResolution?.value} at ${pageOnResolution?.sourceTime}; '
          'complaints ${fixture.client.complaints}');

      expect(outcome, isA<WriteApplied>(),
          reason: 'the write came back $outcome on a healthy link, so this arm '
              'never reached the adopt site at all');
      expect(pageOnResolution?.value, _commanded,
          reason: 'the page still shows ${pageOnResolution?.value} the instant '
              'the write resolved. The readback shares its instant with the '
              'reading it replaces, which is what an RPC answer and a '
              'tick-quantised push carrying the same device reading look like '
              '— the ordinary case. A guard that refuses it leaves the '
              'operator looking at the number they typed over, still wearing '
              'the pending badge, until the next tick corrects it — and if '
              'that tick is the one lost to a reconnect, until the tag next '
              'moves');
      expect(pageOnResolution?.sourceTime, onTheWire,
          reason: 'the page carries ${pageOnResolution?.sourceTime}, so the '
              'value on it did not come from the adopt: the plant\'s own push '
              'of an applied readback carries no source time at all '
              '(`fake_state_man.dart:936`), and a null here means the '
              'subscription beat the answer and this arm measured the push '
              'rather than the guard');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the client complained about a readback it had every reason '
              'to take: ${fixture.client.complaints}. Equality is not a step '
              'backwards, and a guard that treats it as one turns the '
              'complaint list into noise at the rate an operator presses '
              'buttons');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
