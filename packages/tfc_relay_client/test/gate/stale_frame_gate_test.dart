/// F18: a frame that belongs to a stream, or a session, that has moved on.
///
/// **F18 — Duplicate/stale frames after reconnect.** Scripted server sends
/// old-epoch `values` after resync. The catalogue asks that the client discards
/// frames from a previous connection epoch — epoch/generation id in the
/// protocol, asserted here.
///
/// Two arms, and they are two different staleness questions. The first replays
/// a frame inside one establishment: the sequence number has moved on and the
/// old frame must not be applied behind it. The second replays a frame from
/// *before* a reconnect, which is the harder half — a resync restarts the
/// sequence at the gateway's snapshot, so without a per-subscription generation
/// a pre-drop frame is byte-indistinguishable from the first frame of the
/// session that replaced it. 04-REVIEW CR-04 minted `g` for exactly this, and
/// the second arm is the deviation that recorded the gap converted into an
/// assertion.
///
/// Both frames are captured off the wire rather than hand-written: F18 is about
/// a frame the gateway genuinely sent, and a stand-in would assert against a
/// shape somebody guessed.
///
/// Moved here verbatim from `test/contract/fault_contract_test.dart` in Phase 7
/// (07-02); bodies unchanged.
///
/// **G4 — Seq gap across a generation change**, added in 07-06, beside the F18
/// arms it shares a fixture with. §D.1's row: a subscribe-on-existing-id
/// re-establish drops the old send-buffer lane; assert a frame from generation
/// *g* arriving after the snapshot for *g+1* is discarded, and that the client
/// does **not** count it as a gap and resync again.
///
/// **What makes it G4 rather than a third F18.** F18b's replayed frame is from
/// before a *reconnect*, and its sequence is whatever the old session left it
/// with; either guard could be the one that stops it. G4 chooses the sequence
/// the next genuine frame would carry, so the sequence check would have
/// **accepted** it and only the generation guard can reject it — and the
/// re-establish is on the **same socket**, which is the hazard 04-REVIEW CR-04
/// minted the generation for and the one an epoch cannot see. 07-04 measured
/// that no socket-killing fault can reach it: under `flap(200ms, 200ms)` the
/// peer is retired before an in-flight frame can arrive, so both guards fired
/// zero times across a ten-second flap and F3's case stayed green with both of
/// them deleted. This case is where that clause gets asserted, which is why F3
/// carried a partial entry naming 07-06 as its owner.
///
/// The lever for the same-socket re-establish is a sequence gap, because that
/// is the one a case can pull without a scripted gateway: `BatchSeqGap` sends
/// the resync engine to `_resubscribe`, the gateway re-establishes the page in
/// place (`session_handlers.dart:147-176`), and the generation moves while the
/// session, the socket and the epoch all stay exactly where they were.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/frame_seam.dart';
import '../support/gate_bands.dart';

/// The gateway's answer to a `subscribe`: the one frame carrying the field
/// spelled out in full. Counted before and after the injection, because "no
/// second resync" is a claim about what the *gateway* was asked to do.
bool _isSnapshotAnswer(String frame) => frame.contains('"generation"');

/// The generation the gateway currently holds for [sub] — its own count of how
/// many times it has rebuilt this page, since one is minted per subscribe from
/// a gateway-wide counter (`subscription_registry.dart:190-205`).
int _rebuildsServed(FaultFixture fixture, String sub) {
  final state =
      fixture.server.sessions.sessions.single.subscriptions.get(sub);
  if (state == null) {
    fail('the gateway holds no subscription named "$sub"');
  }
  return state.generation;
}

/// The last `u` frame the wire has delivered.
///
/// **Read at the instant of an injection, never before an `await`.** A value
/// this plant stops changing goes `badStale` about 350 ms later
/// (`quality.dart:20`), and the gateway sends that as a *second* update frame
/// carrying the same value and a quality — measured: `seq 1 {"v":1500}` then
/// `seq 2 {"v":1500,"q":516}` 351 ms behind it. A sequence pinned before a
/// settle and injected after one is therefore a replay rather than the
/// in-sequence frame the case meant to inject, and the guard that rejects it is
/// the sequence check — the very thing G4 exists to rule out. Frames reach the
/// seam's list in the same callback that queues them for the peer, so a
/// sequence computed here and injected with no `await` in between is the one
/// the client will next be expecting.
String _lastUpdateFrame(FaultFixture fixture) {
  final frame = fixture.seam.lastMatching(
      (message) => message.contains('"method":"${Methods.update}"'));
  if (frame == null) {
    fail('no update frame has arrived, so there is no sequence to inject '
        'against and the injection below would be measuring nothing');
  }
  return frame;
}

void main() {
  group('F18 — a frame from a stream that has moved on', () {
    test('F18a: a stale frame from a stream that has moved on is discarded, '
        'never applied', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // A real frame, captured off the wire rather than hand-written: F18 is
      // about a frame the gateway genuinely sent, and a stand-in would be
      // asserting against a shape somebody guessed. `Methods.update` is `'u'`
      // — one character on purpose, it is the hot path — so the marker comes
      // from the constant rather than from the word "update", which appears
      // nowhere on the wire.
      fixture.served.setValue(scenarioKey, 1300);
      await until('an update frame carrying the older value',
          () => fixture.client.read(scenarioKey)?.value == 1300);
      final staleFrame = fixture.seam.lastMatching(
          (message) => message.contains('"method":"${Methods.update}"'));
      expect(staleFrame, isNotNull,
          reason: 'no update frame was captured, so the injection below would '
              'deliver nothing and this case would pass by doing nothing');

      // The stream moves on, so the captured frame is now genuinely behind it.
      fixture.served.setValue(scenarioKey, 1500);
      await until('the current value',
          () => fixture.client.read(scenarioKey)?.value == 1500);

      // Re-delivered: the framing bug, the store-and-forward peer, the
      // reconnect that replayed a queue. Injected rather than provoked because
      // TCP does not duplicate frames on its own — the only way to drive this
      // against a real client is to be the peer that sends it.
      fixture.seam.inject(staleFrame!);
      await Future<void>.delayed(settle);

      expect(fixture.client.read(scenarioKey)?.value, 1500,
          reason: 'the reading fell back to a value the stream had already '
              'moved past. That is the F18 failure exactly: a number from two '
              'batches ago rendered under good quality, with nothing on screen '
              'to say it is old, on a mimic an operator is about to act on. '
              '`ValueStore.applyBatch` judges the sequence before it applies '
              'anything for this reason, and a batch at or behind the last '
              'applied one is discarded rather than written');
      expect(
          fixture.client.complaints
              .where((complaint) => complaint.contains('never announced')),
          isEmpty,
          reason: 'the injected frame named a handle this session does not '
              'know, so it was dropped for the wrong reason and the assertion '
              'above is vacuous: nothing was ever going to be applied');

      // And the client is still usable. A replay makes the resync engine
      // resubscribe — "a duplicate on the wire means the stream is not what
      // the client thought it was" (`resync_engine.dart:149-152`) — and
      // against the real gateway that resubscribe **succeeds**: a subscribe
      // naming a live subscription is a *re-establish*, which drops the old
      // listeners and the old establishment's pending send-buffer lane
      // (`session_handlers.dart:147-174`, `ConflatingSendBuffer.dropSub`) and
      // answers with one entry, one seq, a fresh snapshot and a new
      // generation.
      //
      // **Corrected 07-13, owed since 07-06.** This paragraph used to say the
      // resubscribe was *refused* with -32602 because the subscription still
      // existed on the live session, citing
      // `subscription_registry.dart:214`. That has not been true since
      // 04-REVIEW CR-03: line 214 is now `bool contains(String sub)` and the
      // refusal it fed was deleted, precisely because it wedged this recovery
      // path — a gapped client asked for the page, the refusal threw before
      // `store.clear()` could rebase `lastSeq`, and the next frame was another
      // gap, for as long as the socket lived. The re-establish is the
      // mechanism 07-06's G3a and G4 both drive, so the old wording described
      // a build the rest of this directory contradicts, and the "gap written
      // up in the 04-11 SUMMARY" is closed.
      //
      // What the two arms below assert is unchanged and still worth asserting:
      // the recovery costs the panel nothing it was holding. The cache is not
      // blanked back to the replayed value, the link is up, and the next call
      // is answered — which is the property either way, and the only thing
      // this case can see from outside.
      final fresh = await fixture.client.readFresh(scenarioKey).timeout(recovery);
      expect(fresh.value, 1500,
          reason: 'a forced round trip after the replay did not come back with '
              'the current reading, so the failed resubscribe took something '
              'down with it');
      expect(fixture.client.isReady, isTrue, // window-exempt: the readFresh round trip two lines above completed and returned the current reading — a completed event that cannot happen over a link the client has stopped believing in; this asserts consistency with it
          reason: 'the panel left ready over a link that never closed');
    });

    test('F18b: an old-generation frame after a reconnect is dropped', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // A real frame from *this* establishment, captured off the wire.
      fixture.served.setValue(scenarioKey, 1300);
      await until('an update frame from the first session',
          () => fixture.client.read(scenarioKey)?.value == 1300);
      final beforeTheDrop = fixture.seam.lastMatching(
          (message) => message.contains('"method":"${Methods.update}"'));
      expect(beforeTheDrop, isNotNull,
          reason: 'nothing was captured, so the injection below delivers '
              'nothing and this case passes by doing nothing');

      // The link dies and comes back: a new session, a new epoch, a new
      // subscription — and, because the counter spans the gateway rather than
      // the socket, a generation the captured frame cannot match.
      fixture.proxy.killOnce();
      await until('the reconnect', () => fixture.client.isReady,
          budget: recovery);
      fixture.served.setValue(scenarioKey, 1500);
      await until('the current value after the reconnect',
          () => fixture.client.read(scenarioKey)?.value == 1500,
          budget: recovery);

      fixture.seam.inject(beforeTheDrop!);
      await Future<void>.delayed(settle);

      expect(fixture.client.read(scenarioKey)?.value, 1500,
          reason: 'a reading from the session before the drop went onto the '
              'mimic under good quality. Worse than the number itself: it '
              'takes the sequence baseline with it, so the genuine frame at '
              'that seq is then discarded as a replay and the operator keeps '
              'the old number until the tag next changes');
      expect(
          fixture.client.complaints
              .where((complaint) => complaint.contains('never announced')),
          isEmpty,
          reason: 'handles are server-global and never released, so the '
              'captured frame names a handle this session does know. If it '
              'did not, the frame would have been dropped for the wrong '
              'reason and the assertion above would be vacuous');
    });
  });

  group('G4 — a sequence gap across a generation change', () {
    test('G4: an old-generation frame after the new snapshot is dropped by the '
        'generation check, and is not counted as a gap', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // A real frame from generation *g*, captured off the wire.
      fixture.served.setValue(scenarioKey, 1300);
      await until('an update frame from the first establishment',
          () => fixture.client.read(scenarioKey)?.value == 1300);
      final fromTheOldGeneration = fixture.seam.lastMatching(
          (message) => message.contains('"method":"${Methods.update}"'));
      expect(fromTheOldGeneration, isNotNull,
          reason: 'nothing was captured, so every injection below delivers '
              'nothing and this case passes by doing nothing');
      final oldStamp = FrameSeam.stampOf(fromTheOldGeneration!);

      // The re-establish, on the same socket: a gap sends the resync engine to
      // `_resubscribe`, the gateway rebuilds the page in place, and the
      // generation moves to *g+1* while the session and the epoch stay put.
      final beforeTheRebuild =
          _rebuildsServed(fixture, defaultPageSubscription);
      fixture.seam.inject(FrameSeam.restamped(fromTheOldGeneration,
          seq: oldStamp.seq + 10, generation: oldStamp.generation));
      await until('the page to be re-established in place',
          () => _rebuildsServed(fixture, defaultPageSubscription) >
              beforeTheRebuild,
          budget: recovery);
      final generation = _rebuildsServed(fixture, defaultPageSubscription);

      // A genuine frame *on the new generation*, so the sequence the client is
      // measuring against is one this case can name rather than infer.
      fixture.served.setValue(scenarioKey, 1500);
      await until('an update frame from the new establishment',
          () => fixture.client.read(scenarioKey)?.value == 1500);
      final liveStamp = FrameSeam.stampOf(_lastUpdateFrame(fixture));
      expect(liveStamp.generation, generation,
          reason: 'the last update frame carries generation '
              '${liveStamp.generation} and the gateway holds $generation, so '
              'the re-establish this case depends on did not happen the way it '
              'thinks it did');

      final rebuildsBefore = generation;
      final answersBefore =
          fixture.seam.inbound.where(_isSnapshotAnswer).length;
      final complaintsBefore = fixture.client.complaints.length;

      // **The arm that makes this G4 and not a third F18.** The sequence is the
      // one the *next* genuine frame would carry — the last delivered frame's
      // plus one, which `ValueStore.applyBatch` scores as `BatchOk` — so the
      // sequence check would have accepted this frame and applied its values.
      // The only thing in `onUpdate` that can reject it is
      // `generation != state.generation`. Computed here, in the same
      // synchronous breath as the injection, for the reason
      // [_lastUpdateFrame]'s doc gives.
      // Every value the page publishes from here on. The cache read below is
      // taken after a settle, and a settle is long enough for the *recovery* a
      // missing guard would trigger to have repaired the cache already —
      // measured: with the guard deleted the injected 1300 is applied, the
      // genuine frame at that sequence is then discarded as a replay, and the
      // resync puts 1500 back inside 400 ms. The mimic still showed the wrong
      // number, so the assertion that catches it has to be a recorder rather
      // than a reading.
      final published = <Object?>[];
      final watching =
          fixture.client.subscribe(scenarioKey).listen((v) => published.add(v.value));
      addTearDown(watching.cancel);

      final inSequence = FrameSeam.stampOf(_lastUpdateFrame(fixture)).seq + 1;
      print('G4: injecting (generation ${oldStamp.generation}, seq '
          '$inSequence) against a subscription at (generation $generation, seq '
          '${inSequence - 1}) — in sequence for the new generation, so only '
          'the generation check can reject it');
      fixture.seam.inject(FrameSeam.restamped(fromTheOldGeneration,
          seq: inSequence, generation: oldStamp.generation));
      await Future<void>.delayed(settle);

      expect(published, isNot(contains(1300)),
          reason: 'the page published $published after the injection, so the '
              'old-generation value reached the mimic even if a later recovery '
              'took it off again. Its sequence fitted, which is the whole '
              'point: the sequence check could not have stopped it, so the '
              'generation check is the only guard between an old-generation '
              'frame and the operator');
      expect(fixture.client.read(scenarioKey)?.value, 1500,
          reason: 'the page settled on a value from the establishment before '
              'the re-establish, under good quality');
      expect(_rebuildsServed(fixture, defaultPageSubscription), rebuildsBefore,
          reason: 'the gateway rebuilt the page again after the discarded '
              'frame, so the client counted it as a gap and resynced — the '
              'clause the survey names. One dropped frame becoming one rebuild '
              'is how a re-establish turns into a loop of them');
      expect(fixture.seam.inbound.where(_isSnapshotAnswer).length, answersBefore,
          reason: 'a snapshot answer arrived after the injection, so a second '
              'recovery ran even though the gateway\'s own generation says it '
              'was not asked for one');
      expect(fixture.client.complaints.length, complaintsBefore,
          reason: 'the engine complained about the discarded frame: '
              '${fixture.client.complaints}. A frame crossing a re-establish '
              'is the ordinary shape of recovery, not a configuration problem '
              'anyone can act on, and a log line per frame during a storm is '
              'the log flood F2 forbids');

      // Anti-vacuity: the same frame, stamped with the *current* generation,
      // does change the cache. Without this the case passes against a client
      // that ignores every injected frame — which is exactly what a seam with
      // no live connection behind it would look like.
      fixture.seam.inject(FrameSeam.restamped(fromTheOldGeneration,
          seq: FrameSeam.stampOf(_lastUpdateFrame(fixture)).seq + 1,
          generation: generation));
      await until('the same frame to be applied once its generation matches',
          () => fixture.client.read(scenarioKey)?.value == 1300,
          budget: recovery);
    });
  });
}
