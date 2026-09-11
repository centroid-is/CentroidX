/// F7: the link dies between the write going out and the answer coming back.
///
/// **F7 — Drop between write sent and response.** `blackhole()` right after
/// write frame forwarded. The catalogue asks for the same as F6 —
/// outcome unknown, surfaced, not replayed.
///
/// Four arms: the link dying with a write in flight, the write that turns out
/// to have *landed* while the link was down, the gateway's `not_received`
/// answer, and a refusal that crossed a real socket.
///
/// **These arms are F7 and not F6, and the distinction is the point.** F6 is
/// `cutMidFrame()` on the write request — a write truncated on the wire. These
/// four inject `killOnce` and a stalled write: the frame goes out whole and the
/// *answer* is what never arrives. Naming them F6 would report a row as covered
/// whose injection this file never pulls, and F6's own failure mode — a
/// half-written frame the decoder has to reject without desynchronising — would
/// be gated by a case that cannot produce it. F6 keeps its `missing` entry
/// until 07-05 lands the real injection.
///
/// **The lever deviation, verbatim from the file these arms came from** — the
/// deviations registry points at it:
///
/// > **A recovery arm ends its outage with a kill, never by lifting a
/// > blackhole.** Measured, not preferred.
/// >
/// > The `writeStatus` re-query goes out on *entry* to `ready`
/// > (`remote_state_man.dart`, `_onLinkState`) and nowhere else, so any arm
/// > about the recovery has to take the client out of `ready` and put it back.
/// > Driven by lowering the freshness deadline and waiting for the watchdog to
/// > notice a blackholed link, the applied-while-down arm wedged the reconnect
/// > past a fifteen-second budget in one run of four and finished in under a
/// > second in the other three. The mechanism is in the lever's own
/// > documentation: a blackhole swallows *both* directions, so the client's own
/// > close never reaches the gateway either, and the replacement session has to
/// > establish beside a session the gateway still believes in.
/// >
/// > `killOnce` has none of that — it is the lever F1, F6/F7 and F18 all use,
/// > the gateway sees the close immediately, and the arms below run in a second.
/// > The blackhole survives in exactly one place, the `not_received` arm, where
/// > swallowing the outbound frame *is* the fault being injected; that arm
/// > restores forwarding before it cuts.
///
/// Moved here verbatim from `test/contract/fault_contract_test.dart` in Phase 7
/// (07-02); bodies unchanged.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

void main() {
  group('F7 — a write in flight when the link dies', () {
    test('F7a: the link dies with a write in flight — unknown, held, and '
        'never re-actuated', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // Stalled at the plant so the cut lands while the write is genuinely
      // out, rather than before it left or after it came back — the ordering
      // `dropUpstreamUnderAWriteInFlight` exists to get right on the other leg.
      fixture.served.stallWrites();
      final pending = fixture.client.write(scenarioKey, 1500);
      await until('the write to reach the plant',
          () => fixture.served.writesInFlight > 0,
          budget: recovery);
      expect(fixture.served.writesInFlight, greaterThan(0),
          reason: 'nothing was parked at the plant, so the cut below would '
              'have hit an idle link and the case would be F1 wearing F6\'s '
              'name');

      fixture.proxy.killOnce();

      final outcome = await pending.timeout(recovery);
      expect(outcome, isA<WriteUnknown>(),
          reason: 'the write came back $outcome. It was out on the wire when '
              'the link died: the device may have taken it, and the only '
              'honest verdict is that nobody knows');
      expect((outcome as WriteUnknown).reason.kind,
          anyOf(FailureKind.linkLost, FailureKind.linkDown,
              FailureKind.deadlineExpired));
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the write reached the wire more than once');
      expect(fixture.client.debugUnresolvedCmds, contains(outcome.cmd),
          reason: 'the command has to survive the reconnect, because its id is '
              'the only handle `writeStatus` has on it');

      // The recovery asks; it does not re-actuate.
      await until('the writeStatus re-query after the reconnect',
          () => fixture.client.debugWriteStatusQueries.isNotEmpty,
          budget: recovery);
      expect(fixture.client.debugWriteStatusQueries.first, contains(outcome.cmd),
          reason: 'the re-query went out without asking about the one command '
              'whose fate is unknown');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the reconnect re-sent the write. That is the single most '
              'dangerous thing this client could do, and it is why recovery is '
              'a question about the command rather than a repeat of it');

      // **What came back, not merely that something went out** (04-REVIEW
      // CR-02). This arm is the one the old shape was missing, and its absence
      // is why nothing noticed that the gateway was answering `not_received`
      // here: the write was received, forwarded, and is parked at the plant
      // right now, and `not_received` is the one verdict that tells an operator
      // it is safe to press the button again.
      await until('the re-query to be answered',
          () => fixture.client.debugWriteStatusAnswers.isNotEmpty,
          budget: recovery);
      final answered = fixture.client.debugWriteStatusAnswers
          .firstWhere((result) => result.cmd == outcome.cmd,
              orElse: () => fail('the re-query came back with no answer about '
                  '${outcome.cmd}, which is the only command it asked about'));
      expect(answered, isNot(isA<WriteNotReceived>()),
          reason: 'the gateway answered "never received" about a write it had '
              'received and forwarded, and which is upstream at this moment. '
              'That answer sends the operator back to the button');
      expect(answered, isA<WriteUnknown>(),
          reason: 'the write is parked at the plant: nobody knows yet, and '
              'that is the honest answer');
      expect(answered.isSafeToResend, isFalse, reason: 'a write parked at the plant is the one an operator must never be offered a re-send button for: the ram may already be moving');
      expect(fixture.client.debugUnresolvedCmds, contains(outcome.cmd),
          reason: 'an unknown answer settles nothing, so the command stays '
              'held for the next entry to ready to ask about again');

      // Released after the assertions so the plant does not carry a stalled
      // write into teardown.
      fixture.served.releaseWrites();
    });

    test('F7b: a write that landed while the link was down comes back '
        'applied, and resolves exactly once', () async {
      // **05-RESEARCH §E.2 gap 2.** The case above only ever reaches the arm
      // where the write is still parked at the plant, so the re-query answers
      // `unknown` and settles nothing. The other half — the write actually
      // *landed* during the outage — is the one that exercises
      // `RemoteStateMan._settle` end to end: the command leaving the
      // unresolved set, the readback adopted, and the late outcome going out
      // on `onWriteResolved` so that an operator who was told "unknown",
      // walked out to look at the machine and came back is told what
      // happened. Nothing drove that path before this arm.
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final resolved = <WriteResult>[];
      final watching = fixture.client.onWriteResolved.listen(resolved.add);
      addTearDown(watching.cancel);

      /// Every answer this client has been given about [cmd], in order.
      List<WriteResult> answersAbout(String cmd) => fixture
          .client.debugWriteStatusAnswers
          .where((result) => result.cmd == cmd)
          .toList();

      // Stalled at the plant, so the cut lands with the write genuinely
      // upstream rather than before it left.
      fixture.served.stallWrites();
      final pending = fixture.client.write(scenarioKey, 1500);
      await until('the write to reach the plant',
          () => fixture.served.writesInFlight > 0,
          budget: recovery);

      // `killOnce`, the same lever the case above uses, and **not** a
      // blackhole. Driven at a blackhole this arm wedged the reconnect for
      // 15 s in one run of four: the client's own close is swallowed too, so
      // the gateway keeps the dead session — and its subscription — while the
      // replacement session tries to establish. The kill is the fault this arm
      // is about anyway, and it is the one the rest of this file is built on.
      fixture.proxy.killOnce();
      final outcome = await pending.timeout(recovery);
      expect(outcome, isA<WriteUnknown>(),
          reason: 'the write came back $outcome with the link cut under it; '
              'nobody could know yet');
      expect(fixture.client.debugUnresolvedCmds, contains(outcome.cmd),
          reason: 'the command was not held for re-query, so the resolution '
              'this case is about could never be asked for');

      // **The first re-query still finds it parked**, and that is the state
      // the existing case above ends in. The gateway records
      // `unknown(in_flight)` *before* it crosses into the plant, precisely so
      // that a question asked at this moment is answered "on its way to a
      // machine" rather than "never received".
      await until('the first re-query after the reconnect to be answered',
          () => answersAbout(outcome.cmd).isNotEmpty,
          budget: recovery);
      expect(answersAbout(outcome.cmd).first, isA<WriteUnknown>(),
          reason: 'the first answer was '
              '${answersAbout(outcome.cmd).first}, not unknown — the write is '
              'stalled at the plant at this instant, so anything else means '
              'this arm never passed through the state it is supposed to '
              'resolve *from* and proves nothing the case above does not');
      expect(resolved.where((result) => result.cmd == outcome.cmd), isEmpty,
          reason: 'an unknown answer settles nothing and must not be announced '
              'to the operator as a resolution');
      expect(fixture.client.read(scenarioKey)?.value, isNot(1500),
          reason: 'the client already shows the new value, so the plant took '
              'the write before this case released it and the resolution '
              'below is a subscription update wearing a re-query\'s clothes');

      // And now it lands, with the panel no longer waiting on it.
      fixture.served.releaseWrites();
      await until('the plant to take the write',
          () => fixture.served.writesInFlight == 0,
          budget: recovery);

      // The next entry to `ready` is what asks again — the re-query goes out
      // there and nowhere else. Counted rather than watched for `isReady`
      // going false: the reconnect can be over before a 10 ms poll sees it.
      final answersBefore = answersAbout(outcome.cmd).length;
      fixture.proxy.killOnce();
      await until(
          'the re-query that goes out after the write had landed',
          () => answersAbout(outcome.cmd).length > answersBefore,
          budget: recovery);

      final answered = answersAbout(outcome.cmd).last;
      expect(answered, isA<WriteApplied>(),
          reason: 'the write reached the device and the device took it, and '
              'the re-query answered $answered. An operator who was shown '
              '"unknown" and is now shown anything other than "applied" has '
              'been told the machine may not have moved when it did');
      expect(answered.isSafeToResend, isFalse,
          reason: 'a write that has already been applied is not re-send-safe. '
              'Offering the button again here is the second stroke of a ram '
              'the operator commanded once');
      // **What this arm does not force.** The reconnect's own snapshot carries
      // the plant's current reading too, so the store showing 1500 does not
      // isolate `_adoptReadback` from the resync — the same shape 04-REVIEW
      // WR-01 recorded rather than pretended away. What it does isolate is
      // everything below: one emission, and the command settled.
      expect(fixture.client.read(scenarioKey)?.value, 1500,
          reason: 'the resolution never reached the store, so the mimic still '
              'shows the setpoint the operator typed over');
      expect(resolved.where((result) => result.cmd == outcome.cmd), hasLength(1),
          reason: 'the late outcome went out '
              '${resolved.where((r) => r.cmd == outcome.cmd).length} times. '
              'Zero means the operator is never told how the unknown ended; '
              'more than one means the panel raises the same resolution twice '
              'and the second one reads as a new event');
      expect(fixture.client.debugUnresolvedCmds, isNot(contains(outcome.cmd)),
          reason: 'the command stayed unresolved after an established answer, '
              'so it is re-queried on every reconnect for the rest of the '
              'shift');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the recovery re-actuated the plant. It asks what became of '
              'the command; it never repeats it');
    });

    test('F7c: an answer of not_received settles the command, and is the '
        'only re-send-safe verdict', () async {
      // **05-RESEARCH §E.2 gap 3.** The server side has this
      // (`value_handlers_test.dart:423-431`); nothing exercised the *client's*
      // handling of a `not_received` answer arriving from a re-query. It is
      // not `WriteUnknown`, so it falls through to `_settle` — and it is the
      // one verdict the re-send-safe getter is true for, which makes this the
      // arm where being wrong sends an operator back to a button.
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final resolved = <WriteResult>[];
      final watching = fixture.client.onWriteResolved.listen(resolved.add);
      addTearDown(watching.cancel);

      // **Swallowed on the way out**, before the gateway sees a byte of it,
      // and the blackhole is the only lever that can do that: `killOnce`
      // would cut before the frame left or after it arrived, and `sever` on
      // the in-memory pair drops server-to-client only. Blackholed bytes are
      // lost and never replayed (`fault_proxy.dart`, RESEARCH Finding 4),
      // which is what makes the answer below honest rather than merely early.
      //
      // The command is freshly minted, datable, after the outcome log's own
      // start and inside its TTL: the positive evidence the gateway insists on
      // before it will say "never received" (`value_handlers.dart`,
      // `_statusOf`). Forgetting is not evidence.
      fixture.proxy.blackhole();
      final outcome = await fixture.client.write(scenarioKey, 1500).timeout(recovery);

      expect(outcome, isA<WriteUnknown>(),
          reason: 'the write came back $outcome into a swallowed link');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the frame never left this client, so the gateway has '
              'nothing to have an opinion about and the answer below would be '
              'unremarkable');
      expect(fixture.served.upstreamWriteAttempts(outcome.cmd), 0,
          reason: 'the plant recorded an attempt for a command the link '
              'swallowed, so this case is not about a write that never '
              'arrived');
      expect(fixture.client.debugUnresolvedCmds, contains(outcome.cmd),
          reason: 'an unknown that is not held for re-query is an unknown '
              'nobody will ever establish');

      // Forwarding restored and *then* the link cut: the re-query goes out on
      // entry to `ready` and nowhere else, and a kill is how this file's other
      // cases get there. Waiting for a blackholed link to be noticed by the
      // freshness watchdog instead left the gateway holding a session whose
      // close it never saw, which wedged the replacement's establishment for
      // fifteen seconds in one run of four.
      fixture.proxy.blackhole(enabled: false);
      fixture.proxy.killOnce();
      await until(
          'the re-query to come back with an answer about ${outcome.cmd}',
          () => fixture.client.debugWriteStatusAnswers
              .any((result) => result.cmd == outcome.cmd),
          budget: recovery);

      final answered = fixture.client.debugWriteStatusAnswers
          .firstWhere((result) => result.cmd == outcome.cmd);
      expect(answered, isA<WriteNotReceived>(),
          reason: 'the gateway answered $answered about a command it demonstrably '
              'never saw. "Unknown" here is merely unhelpful; anything that '
              'settles the command as having happened would be a lie about a '
              'machine');
      expect(answered.isSafeToResend, isTrue,
          reason: 'this is the one verdict that licenses offering the button '
              'again, and it is only safe because the gateway had to date the '
              'command against its own clock to reach it');
      expect(fixture.client.debugUnresolvedCmds, isNot(contains(outcome.cmd)),
          reason: 'never-received is an established answer and must settle the '
              'command; leaving it unresolved re-asks a question the gateway '
              'has already answered, on every reconnect, forever');
      expect(resolved.where((result) => result.cmd == outcome.cmd), hasLength(1),
          reason: 'the operator was shown "unknown" and is owed the '
              'resolution exactly once');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the client re-sent the write on learning it was never '
              'received. Re-send-safe is a statement about what an operator '
              'may be offered, never about what this client does on its own — '
              'that distinction is the whole of WRT-03');
      expect(fixture.served.upstreamWriteAttempts(outcome.cmd), 0,
          reason: 'the plant was actuated by the recovery');
    });

    test('F7d: a refusal over a socket means the plant was untouched',
        () async {
      // **05-RESEARCH §E.2 gap 4, and the direct answer to the CONTEXT threat
      // flag.** The gateway proves this at the handler
      // (`value_handlers_test.dart:355-370`, `upstreamWriteAttempts`
      // unchanged); nothing proved it over a real socket. The claim being
      // judged is the standing ruling that `INVALID_PARAMS` on the write path
      // means definitively no effect — because a refusal that might have
      // actuated is a button an operator presses twice.
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final cmd = newUlid();
      final first = await fixture.client
          .write(scenarioKey, 1500, cmd: cmd)
          .timeout(recovery);
      expect(first, isA<WriteApplied>(),
          reason: 'the first write under this id came back $first, so the '
              'collision below would be a collision with nothing');
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'the plant did not record the first write under the id the '
              'client minted, so the count this case reads afterwards is not '
              'about this command');

      // The same id, a different value: two different operator intents under
      // one action id, which 05-03 deliberately keeps a refusal rather than
      // folding into the replay window (D-P5-B).
      final second = await fixture.client
          .write(scenarioKey, 1600, cmd: cmd)
          .timeout(recovery);

      expect(second, isA<WriteRejected>(),
          reason: 'a duplicate-id collision came back as $second. Rejected is '
              'the only honest mapping: the gateway raised before it touched '
              'the plant, so this is the one refusal that carries a guarantee '
              'about the machine');
      expect((second as WriteRejected).reason.kind, FailureKind.serverRefused);
      expect(second.isSafeToResend, isFalse,
          reason: 'a refusal is not a licence to re-send. The defect is in the '
              'caller — two different writes under one id — and repeating it '
              'under a fresh id is an operator decision about a machine, never '
              'this client\'s');
      expect(second.reason.message, contains('nothing was sent'),
          reason: 'the sentence that reaches the operator is what makes the '
              'refusal actionable, and "nothing was sent" is the part that '
              'stops them pressing again to be sure. Got: '
              '${second.reason.message}');
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'the plant recorded '
              '${fixture.served.upstreamWriteAttempts(cmd)} attempts for this '
              'command. The second frame was refused before the gateway '
              'crossed into the plant, so anything above 1 means '
              'INVALID_PARAMS on the write path does not mean "no effect" — '
              'and every refusal this client has ever reported as definitive '
              'stops being one');
      expect(fixture.served.read(scenarioKey)?.value, 1500,
          reason: 'the tag carries the refused value, so the second write '
              'reached the device after all');
      expect(fixture.client.debugWritesSent, 2,
          reason: 'the second frame never left, so the refusal was this '
              'client\'s local duplicate-id guard rather than the gateway\'s '
              '— and the property this case exists to prove is about the '
              'gateway');
      expect(fixture.client.debugUnresolvedCmds, isNot(contains(cmd)),
          reason: 'a refusal is an established answer; holding it for re-query '
              'asks the gateway forever about a write it already refused');
    });
  });
}
