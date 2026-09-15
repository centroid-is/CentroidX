/// Criterion 5, measured: two panels, one backend, one active set, the same
/// timestamps — over a real WebSocket, and **neither panel computed any of it**.
///
/// ## What makes this different from "two things agreed"
///
/// Two panels agreeing is not interesting on its own. The architecture this
/// phase replaces had two panels agreeing most of the time as well: each ran
/// its own `Evaluator` over its own copy of `alarm_man_config` against its own
/// subscriptions, and stamped what it found with its own `DateTime.now()`. Two
/// such panels agree until they do not, and the day they do not is the day two
/// operators read two different stop times for one event (T-14-45).
///
/// So every arm here is written against the *provenance* of the agreement, not
/// against the agreement. The instant on the wire is one the backend resolved,
/// once; the fields beside it were copied out of a configuration neither client
/// ever asked for; and arm 8 measures that neither client had the **means** to
/// derive any of it — its subscription carries exactly one key, no frame it
/// ever received names the alarm's input tag, and the only place the instant
/// appears on either socket is inside the `ALARM.active` payload itself.
///
/// ## Three clocks that cannot be confused for one another
///
/// | | Instant | What produces it |
/// |---|---|---|
/// | [kPlantInstant] | `2024-03-01T12:00:00.250Z` | the `sourceTime` on the alarm input — the right answer |
/// | [kBackendNow] | `2024-03-01T12:10:00.250Z` | the engine's injected clock — a receipt-stamping implementation lands here |
/// | the wall clock | 2026-… | what either panel would get by stamping the frame it received |
///
/// The gap between the first two is ten minutes, which is not a publishing
/// interval, so no transport delay can produce it by accident. The third is two
/// years away from both, which is what makes arm 2's equality meaningful:
/// it cannot pass because both sides happened to read a real clock in the same
/// millisecond, because a real clock cannot produce either of the other two.
///
/// ## The transport is a real socket, and the two panels are two sessions
///
/// [backendRelayFixture] binds the `RelayServer` that `composeBackendRelay`
/// built on an OS-chosen loopback port; each panel is its own TCP connection,
/// its own `RelaySession`, its own handle table and its own subscription.
/// Subscribing twice on one socket would make agreement arithmetic — a fan-out
/// that happens once cannot disagree with itself — and criterion 5 is about two
/// *sessions* being told the same thing.
///
/// No port literal appears in this file. `@Tags(['ws'])` is what makes the lane
/// nameable when a listening socket is unavailable.
///
/// ## What this file deliberately does not do
///
/// **No OPC UA fixture and no plant.** 14-10 owns the plant-side measurement —
/// a real server stamping a chosen instant, through a real acquisition worker —
/// and this file owns the wire. The alarm input here is driven through the
/// harness's fake worker, which puts an ordinary `PipeFrame` on the ordinary
/// path with a `sourceTime` of this file's choosing. Standing an OPC UA server
/// up as well would add a second thing that can fail without adding anything
/// either arm asserts.
///
/// **No `AlarmHistoryWriter`.** `historyId` is null throughout and the arms say
/// so. A database here would put this file in the Docker lane behind hardcoded
/// port 15432, which a parallel worktree may be holding, for a field nothing
/// here measures.
@TestOn('vm')
@Tags(['ws'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart'
    show kBackendStaleAfter;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../support/backend_ws_harness.dart';
import '../support/harnessed_backend_state_man.dart';
import '../support/memory_secrets.dart';

/// The instant the plant stamped the alarm's input with.
///
/// Whole milliseconds, and two years in the past: no wall clock on any machine
/// running this suite can produce it, and neither can the injected clock below.
final DateTime kPlantInstant = DateTime.utc(2024, 3, 1, 12, 0, 0, 250);

/// The engine's injected clock: ten minutes after the plant.
///
/// Where a receipt-stamping implementation lands. Arm 2 excludes it by name,
/// and sabotage (a) makes the arms print exactly this number.
final DateTime kBackendNow = kPlantInstant.add(const Duration(minutes: 10));

/// The alarm input. An ordinary contract key, routed by the harness's fake
/// worker like any other tag.
const String kInputKey = contractSpeedKey;

const String kAlarmUid = 'conveyor-overspeed';
const String kAlarmTitle = 'Conveyor overspeed';
const String kAlarmDescription = 'CN01 is running above its commissioned limit';
const List<String> kAlarmGroup = <String>['Line 3', 'Pre-freezer'];

/// A second, unrelated alarm on a second line — arm 3's, and only arm 3's.
///
/// One standing alarm cannot tell a snapshot from a delta: the two payloads are
/// identical. Two can. See arm 3 and sabotage (b).
const String kSecondInputKey = 'ST201.CN04.MOT01.speed';
const String kSecondAlarmUid = 'packer-overspeed';

/// The second alarm's onset: two seconds after the first, so the pair has a
/// deterministic oldest-first order the arm can name.
final DateTime kSecondPlantInstant =
    kPlantInstant.add(const Duration(seconds: 2));

/// What the panels call their subscription. One name, two sessions.
const String kSub = 'panel';

void main() {
  useMemorySecrets();

  // The real on-disk `Database` and `Preferences` `composeBackendRelay`
  // requires. Registered first so the ordering is visible rather than inferred.
  installBackendWsStore();

  // ------------------------------------------------------------------- arm 0
  //
  // Task 1's acceptance criterion, executed rather than argued: the harness
  // extension must be invisible to every leg that did not ask for it.
  test('arm 0 — the harness composes NO alarm engine unless a case asks for '
      'one, and refuses half an argument pair', () async {
    final plain = composeBackendUnderTest();
    addTearDown(() async {
      await plain.composition.dispose();
      plain.harness.shutdownFixture();
    });

    expect(plain.engine, isNull,
        reason: 'the shared contract suite runs against whatever this function '
            'returns. An engine nobody asked for is another holder of pipe '
            'subscriptions, another writer into the same ValueStore and a '
            'second reader of the freshness sweep — a change in WHAT the '
            'contract is being judged against, hiding inside a fixture');
    expect(plain.alarmPublications, isEmpty,
        reason: 'no engine, therefore nothing published into ALARM.*');

    expect(
        () => composeBackendUnderTest(clock: () => kBackendNow),
        throwsA(isA<ArgumentError>()),
        reason: 'a clock with no configuration is an argument that does '
            'nothing, which is the quietest kind of wrong');
    expect(
        () => composeBackendUnderTest(alarms: _config()),
        throwsA(isA<ArgumentError>()),
        reason: 'AlarmEngine has no default clock (D-2) and this fixture is a '
            'composition root');
  });

  // ------------------------------------------------------------------- arm 1
  test('arm 1 — one alarm standing, and both panels hold the SAME active set',
      () async {
    final rig = await _TwoPanels.standUp();
    rig.raise();
    await rig.awaitActive();

    final a = rig.a.entries;
    final b = rig.b.entries;

    expect(a.map((e) => (e.uid, e.ruleIndex)).toList(), [(kAlarmUid, 0)],
        reason: rig.evidence());
    expect(b.map((e) => (e.uid, e.ruleIndex)).toList(),
        a.map((e) => (e.uid, e.ruleIndex)).toList(),
        reason: 'two panels, one backend, and the sets differ. ${rig.evidence()}');

    // Not "the same pairs" — the same ENTRIES. `AlarmActiveEntry`'s equality is
    // over all eleven fields, so this also covers everything arms 2 and 5 name
    // and anything a later field addition brings with it.
    expect(b, a, reason: rig.evidence());
  });

  // ------------------------------------------------------------------- arm 2
  test('arm 2 — the timestamps are identical to the MILLISECOND, and they are '
      "the backend's, not either panel's", () async {
    final rig = await _TwoPanels.standUp();
    rig.raise();
    await rig.awaitActive();

    final onA = rig.a.entries.single.activeAtMs;
    final onB = rig.b.entries.single.activeAtMs;

    expect(onB, onA,
        reason: 'this is the divergence criterion 5 exists to close. Today '
            'each panel runs its own Evaluator and its own DateTime.now(), so '
            'two screens can show two stop times for one event (T-14-45). '
            '${_diagnose(onA)} / ${_diagnose(onB)}. ${rig.evidence()}');

    expect(onA, kPlantInstant.millisecondsSinceEpoch,
        reason: 'the number both panels hold must be the one the BACKEND '
            'resolved. ${_diagnose(onA)} ${rig.evidence()}');

    // The backend's own number, read off the engine on this side of the socket.
    expect(onA, rig.backendEntries.single.activeAtMs,
        reason: 'the panels agree with each other but not with the engine that '
            'stamped it, which would mean something between them rewrote it');

    expect(onA, isNot(kBackendNow.millisecondsSinceEpoch),
        reason: 'that is the injected clock — a receipt-stamping engine');
    expect(rig.a.entries.single.tsSource, relay.AlarmActiveEntry.tsSourcePlant,
        reason: 'the input carried a source timestamp, so the provenance on '
            'the wire is the plant\'s and both panels are told so');
    expect(rig.b.entries.single.tsSource, relay.AlarmActiveEntry.tsSourcePlant);
  });

  // ------------------------------------------------------------------- arm 3
  test('arm 3 — a panel that joins AFTER TWO alarms are standing is handed the '
      'WHOLE current set as a snapshot, not the last thing that changed',
      () async {
    // TWO alarms, and the second is the whole arm. **Measured, sabotage (b):**
    // with one standing alarm a delta publication and a snapshot publication
    // are byte-identical, so a backend that had quietly become delta-based
    // would pass a one-alarm version of this arm — and a late-joining panel
    // would then be told only about whatever changed last. Two alarms rising
    // one after the other is the smallest case in which "the whole set" and
    // "what changed" are different payloads.
    //
    // B is deliberately absent while the plant goes wrong. Twice.
    final rig = await _TwoPanels.standUp(connectB: false, twoAlarms: true);
    rig.raise();
    await rig.awaitCount(1, onlyA: true);
    rig.raiseSecond();
    // The barrier is "A has been TOLD about the second activation", not "A
    // holds two" — so a backend that told it the wrong thing fails the
    // assertion below by name instead of timing out on a wait.
    await rig.awaitValueFrames(2);
    expect(rig.backendEntries, hasLength(2), reason: rig.evidence());

    final beforeB = rig.a.entries;
    expect(beforeB.map((e) => e.uid).toList(), [kAlarmUid, kSecondAlarmUid],
        reason: 'panel A, which was connected throughout, must hold BOTH — '
            'oldest onset first, which is also the order the cap keeps. A '
            'panel holding only the alarm that moved last is a backend '
            'publishing what CHANGED rather than what IS. ${rig.evidence()}');

    // Now the operator opens a second screen.
    await rig.joinB();

    expect(rig.b.entries, hasLength(2),
        reason: 'PROJECT.md: resync = snapshot, never delta replay. A late '
            'joiner told only about CHANGES sees whichever alarm happened to '
            'move last and is blind to every alarm that was already standing — '
            'a screen showing one fault on a line that has two (T-14-46). '
            '${rig.evidence()}');
    expect(rig.b.entries, beforeB,
        reason: 'and they are the same entries, with the same instants — not a '
            're-derivation. ${rig.evidence()}');

    // It came in the subscribe answer, which is what "snapshot" means here:
    // B has been sent no update frame at all for this key.
    expect(rig.b.snapshotEntries, hasLength(2),
        reason: 'the whole set must be in the subscribe ANSWER. Arriving later, '
            'as updates, would mean the panel had an interval of showing '
            'nothing wrong on a plant that was already stopped');
    expect(rig.b.valueFrames, isEmpty,
        reason: 'no `u` frame was needed to make B correct, which is the whole '
            'of D-9: the active set rides the value path, so snapshot-on-'
            'subscribe is free rather than something alarms had to re-obtain');
  });

  // ------------------------------------------------------------------- arm 4
  test('arm 4 — the clear reaches both panels, and neither is left holding a '
      'stale entry', () async {
    final rig = await _TwoPanels.standUp();
    rig.raise();
    await rig.awaitActive();

    rig.clear();
    await rig.awaitEmpty();

    expect(rig.a.entries, isEmpty, reason: rig.evidence());
    expect(rig.b.entries, isEmpty, reason: rig.evidence());
    expect(rig.backendEntries, isEmpty,
        reason: 'and the backend agrees with both of them');

    // The key is still good and still subscribed — an empty active set is a
    // statement, not an absence.
    expect(rig.a.quality, relay.Quality.good, reason: rig.evidence());
    expect(rig.b.quality, relay.Quality.good, reason: rig.evidence());
  });

  // ------------------------------------------------------------------- arm 5
  test('arm 5 — the entry each panel receives is self-sufficient on the wire: '
      'it can be NAMED without a config lookup', () async {
    final rig = await _TwoPanels.standUp();
    rig.raise();
    await rig.awaitActive();

    for (final panel in [rig.a, rig.b]) {
      final entry = panel.entries.single;
      expect(entry.title, kAlarmTitle, reason: panel.name);
      expect(entry.description, kAlarmDescription, reason: panel.name);
      expect(entry.level, AlarmLevel.error.name, reason: panel.name);
      expect(entry.group, kAlarmGroup, reason: panel.name);
      expect(entry.expression, isNotNull,
          reason: 'the activation branch renders the formula with the values '
              'it fired on, and ${panel.name} is holding it');
      expect(entry.historyId, isNull,
          reason: 'this composition has no AlarmHistoryWriter, and an invented '
              'id is one a panel would follow to a query returning nothing');
    }

    // The point of the copy: the panels were never sent the configuration
    // these four fields came out of, so a station one restart behind still
    // names the alarm correctly.
    for (final panel in [rig.a, rig.b]) {
      expect(panel.framesMentioning('alarm_man_config'), isEmpty,
          reason: '${panel.name} was handed the alarm\'s NAME without ever '
              'being handed the alarm CONFIGURATION. That is the whole reason '
              'the fields are copied into the payload rather than joined '
              'against the panel\'s own copy, which is a copy of a different '
              'age');
    }
  });

  // ------------------------------------------------------------------- arm 6
  test('arm 6 — publish to receipt, MEASURED (Research Open Question 2)',
      () async {
    final rig = await _TwoPanels.standUp();

    // Twelve activations, each with its OWN instant so a publication can be
    // matched to the frame that carried it rather than counted by position,
    // and each preceded by a different delay so the sample walks across the
    // server's tick phase. One measurement taken at a fixed phase would answer
    // a different question — "how long does one publication take from where
    // this fixture happens to sit in the tick" — and the research asks whether
    // an `applyBatch` from outside the drain reaches sessions *promptly* or
    // *on the next tick*, which is a question about the whole phase.
    final gapsA = <int>[];
    final gapsB = <int>[];
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration(milliseconds: 9 * i));
      final stamp = kPlantInstant.add(Duration(seconds: i + 1));
      rig.raiseAt(stamp);
      await rig.awaitStamp(stamp);
      gapsA.add(rig.a.receiptOf(stamp)! - rig.publicationOf(stamp)!);
      gapsB.add(rig.b.receiptOf(stamp)! - rig.publicationOf(stamp)!);
      rig.clear();
      await rig.awaitEmpty();
    }

    String ms(int micros) => (micros / 1000).toStringAsFixed(1);
    final sorted = List.of(gapsA)..sort();
    // ignore: avoid_print
    print('OPEN QUESTION 2, MEASURED over ${gapsA.length} activations: an '
        "`applyBatch` issued from OUTSIDE the pipe's own drain reaches a "
        'connected session on the RelayServer\'s NEXT TICK, not immediately. '
        'Panel A publish->receipt: min ${ms(sorted.first)} ms, median '
        '${ms(sorted[sorted.length ~/ 2])} ms, max ${ms(sorted.last)} ms, '
        'against a configured tick of 100 ms. Panel B is the same fan-out one '
        'encode later: max |A-B| = '
        '${ms([
              for (var i = 0; i < gapsA.length; i++) (gapsA[i] - gapsB[i]).abs()
            ].reduce((x, y) => x > y ? x : y))} ms. '
        'Both panels are served from one encode of one value, so the answer to '
        '"do they converge" is structural; the answer to "how fast" is this '
        'distribution.');

    // Asserted GENEROUSLY and on purpose. The requirement is "the same", not
    // "instantly": a tight timing assertion here would be a flake on a loaded
    // CI runner, and the distribution above is the answer the research asked
    // for.
    for (var i = 0; i < gapsA.length; i++) {
      expect(gapsA[i], inInclusiveRange(0, const Duration(seconds: 5).inMicroseconds),
          reason: 'panel A never converged on activation $i, or a receipt '
              'preceded its own publication — which would mean the two '
              'readings did not come off one monotonic clock and the whole '
              'measurement is worthless. ${rig.evidence()}');
      expect(gapsB[i], inInclusiveRange(0, const Duration(seconds: 5).inMicroseconds),
          reason: 'panel B never converged on activation $i. ${rig.evidence()}');
    }
  });

  // ------------------------------------------------------------------- arm 7
  test('arm 7 — a QUIET plant does not grey the banner: ALARM.active is still '
      'good on both panels past kBackendStaleAfter', () async {
    final rig = await _TwoPanels.standUp();
    rig.raise();
    await rig.awaitActive();

    // The one long wait in this file, and it waits for the SWEEP rather than
    // for a number of seconds. `kBackendStaleAfter` is a production constant
    // chosen from a measured window (13-CONTEXT says in as many words not to
    // paper over that window), so it is not shaved — but a fixed
    // `staleAfter + 2 s` delay was measured FLAKY here and the arithmetic says
    // why: the sweep runs every `staleAfter ~/ 4` = 2.5 s, so a key can be up
    // to 12.5 s old before the pass that badges it, and a 12 s wait loses that
    // race about one run in four. Waiting for the badge itself is both
    // deterministic and strictly stronger.
    //
    // The alarm's own input, which nothing has refreshed, is what the sweep is
    // watched through: without this the arm would pass on a sweep that never
    // fired at all.
    await _waitUntil(
      () =>
          rig.backend.composition.freshness.read(kInputKey)?.quality ==
          relay.Quality.badStale,
      budget: kBackendStaleAfter * 3,
      reason: 'the freshness sweep never badged the alarm\'s input stale, so '
          'this arm proves nothing about what it skipped. ${rig.evidence()}',
    );
    expect(rig.backend.composition.freshness.sweeps, greaterThan(0),
        reason: 'and the pass is countable. ${rig.evidence()}');

    // One tick (100 ms) is all a quality-only transition needs to reach a
    // session. A full second, so "still good" is a measurement rather than a
    // race the arm happens to win.
    final beforeSettle = rig.backend.monotonic.elapsedMicroseconds;
    await Future<void>.delayed(const Duration(seconds: 1));

    // ---------------------------------------------------------------------
    // THE ANTI-VACUITY CHECK, and it is not decoration.
    //
    // MEASURED (sabotage (d), 14-11): with no heartbeat pump these sockets
    // were reaped six seconds after the handshake, so by this line both panels
    // had been disconnected for seven seconds and "the banner is still good"
    // was true because NOBODY WAS THERE TO BE TOLD OTHERWISE. Removing both
    // freshness exclusions turned nothing red. A negative arm that a collapse
    // makes vacuously true is worse than no arm, because it reports a green.
    //
    // So the arm now requires the panels to be demonstrably still attached and
    // still being spoken to at the instant it makes its claim.
    // ---------------------------------------------------------------------
    for (final panel in [rig.a, rig.b]) {
      expect(panel.closedByServer, isFalse,
          reason: '${panel.name} was disconnected before this arm made its '
              'claim, so "the banner never went grey" would only mean "the '
              'banner stopped being updated". ${rig.evidence()}');
      expect(panel.framesSince(beforeSettle), isNotEmpty,
          reason: '${panel.name} received NOTHING in the last second — no '
              'tick, no update. A silent socket cannot be evidence that a key '
              'stayed good on it. ${rig.evidence()}');
      expect(panel.heartbeats, greaterThan(0),
          reason: '${panel.name} never beat, so it is alive by luck rather '
              'than because it did what a panel does');
    }

    for (final panel in [rig.a, rig.b]) {
      expect(panel.quality, relay.Quality.good,
          reason: '${panel.name}: alarm state changes on EVENTS, so on a '
              'healthy plant ALARM.active is always older than any freshness '
              'deadline. Greying it out is pitfall P-6 — the banner going grey '
              'precisely when nothing is wrong — and it teaches operators that '
              'a grey alarm banner means nothing, at the moment they most need '
              'it to mean something. ${rig.evidence()}');
      expect(panel.entries.single.activeAtMs,
          kPlantInstant.millisecondsSinceEpoch,
          reason: '${panel.name} must still be holding the same entry: the '
              'input going stale suspends the rule and HOLDS its state (D-3), '
              'it does not clear it');
    }
  });

  // ------------------------------------------------------------------- arm 8
  test('arm 8 — NEITHER panel could have computed any of it', () async {
    final rig = await _TwoPanels.standUp();
    rig.raise();
    await rig.awaitActive();

    final instant = '${kPlantInstant.millisecondsSinceEpoch}';

    for (final panel in [rig.a, rig.b]) {
      // 1. One key. Not the inputs, not a rule, not a configuration.
      expect(panel.subscribedKeys, <String>[relay.AlarmKeys.active],
          reason: '${panel.name} is subscribed to something other than the '
              'active set, which would give it inputs to evaluate');
      expect(panel.rejectedKeys, isEmpty, reason: panel.name);

      // 2. The alarm's input tag reaches this panel in exactly ONE place:
      //    inside the rendered expression the BACKEND composed, which is a
      //    string, in the payload, produced on the activation branch. It is
      //    never a key the panel bound, never a handle it holds, and never a
      //    value frame it could time.
      //
      //    MEASURED, and it is the sharp edge of this whole arm: the render
      //    carries WHAT the rule read (`…speed{42.0} > 10`) and says nothing
      //    about WHEN — and "when" is the entire input to `resolveAlarmStamp`.
      //    A panel holding `42.0` still cannot produce `activeAtMs`, because
      //    the source timestamp that value arrived with never crossed this
      //    socket in any form. Clause 4 below is what pins that.
      for (final frame in panel.framesMentioning(kInputKey)) {
        expect(panel.isAlarmValueFrame(frame), isTrue,
            reason: '${panel.name} received the alarm\'s INPUT tag in a frame '
                'that is not its active-set payload: <$frame>. A panel that '
                'can bind the input can subscribe to it, and a panel that can '
                'subscribe to it gets its sourceTime — at which point this arm '
                'stops being evidence of anything');
      }
      for (final entry in panel.entries) {
        expect(entry.expression, contains(kInputKey),
            reason: '${panel.name}: the render is where the tag legitimately '
                'appears — an alarm whose formula a panel cannot show is an '
                'alarm nobody can diagnose (T-14-07)');
        expect(entry.expression, isNot(contains(instant)),
            reason: '${panel.name}: the render must not carry the instant '
                'either. It carries the VALUES the rule fired on and nothing '
                'about when they were measured, which is exactly why holding '
                'it does not let a panel re-derive activeAtMs');
      }

      // 3. Three method names were ever SENT on this socket: the handshake,
      //    the subscribe, and the heartbeat that keeps the session from being
      //    reaped. No preferences read, no browse, no read, no readMany.
      //
      //    Method names rather than a count of answered ids: the heartbeat
      //    makes the count non-deterministic, and a count could not tell a
      //    `preferences.getString` from a `ping` anyway — which is precisely
      //    the distinction this clause exists to make.
      //    A set DIFFERENCE, not an equality: the beat is periodic, so
      //    whether one has fired by the time a short arm reaches this line is
      //    a race. What must never happen is a FOURTH name.
      expect(
          panel.sentMethods.toSet().difference(<String>{
            relay.Methods.hello,
            relay.Methods.subscribe,
            relay.Methods.ping,
          }),
          isEmpty,
          reason: '${panel.name} called something beyond the three a watching '
              'panel needs. Every additional call is another way it could '
              'have obtained something it is supposed not to have — '
              '${panel.sentMethods}');
      expect(panel.sentMethods,
          containsAllInOrder(<String>[relay.Methods.hello, relay.Methods.subscribe]),
          reason: '${panel.name} did not handshake and subscribe, in that '
              'order, so the rest of this arm is describing a different rig');

      // 4. The instant appears on this socket ONLY inside the active-set
      //    payload. It has no other path here.
      final carrying = panel.framesMentioning(instant);
      expect(carrying, isNotEmpty,
          reason: '${panel.name} never received the instant at all, so the '
              'rest of this arm is vacuous');
      for (final frame in carrying) {
        expect(panel.isAlarmValueFrame(frame), isTrue,
            reason: '${panel.name} received $instant in a frame that is '
                'neither its ALARM.active subscribe answer nor an update for '
                'that subscription: <$frame>. The claim this arm makes is that '
                'the ONLY route by which that number reaches a panel is the '
                'active-set payload the backend stamped');
      }
    }

    // And the two panels are genuinely two sessions: different session ids,
    // different handles are permitted, one backend.
    expect(rig.a.sessionId, isNot(rig.b.sessionId),
        reason: 'one session subscribed twice is a fan-out that happens once, '
            'and a fan-out that happens once cannot disagree with itself — '
            'which would make every arm above arithmetic rather than evidence');
  });
}

// ---------------------------------------------------------------- diagnostics

/// Names which of the three clocks an unexpected instant came from.
///
/// 14-10's helper, same argument: `Expected: <…> Actual: <…>` leaves the reader
/// to work out whether the number is the machine's wristwatch, the backend's
/// injected clock or the plant's stamp. This says so.
String _diagnose(int actualMs) {
  final actual = DateTime.fromMillisecondsSinceEpoch(actualMs, isUtc: true);
  if (actual == kPlantInstant) {
    return 'That is the PLANT\'s instant — the right answer.';
  }
  if (actual == kBackendNow) {
    return 'That is THE INJECTED CLOCK — the alarm was stamped at receipt (or '
        'at publication) instead of from the transition.';
  }
  if (actual.isAfter(DateTime.utc(2025))) {
    return 'That is a WALL-CLOCK instant — something read a real clock, which '
        'is exactly what a panel evaluating for itself would have done.';
  }
  return 'It matches none of the three clocks this file knows about.';
}

// -------------------------------------------------------------------- fixture

AlarmManConfig _config({bool twoAlarms = false}) =>
    AlarmManConfig(alarms: <AlarmConfig>[
      AlarmConfig(
        uid: kAlarmUid,
        title: kAlarmTitle,
        description: kAlarmDescription,
        group: kAlarmGroup,
        rules: <AlarmRule>[
          AlarmRule(
            level: AlarmLevel.error,
            expression:
                ExpressionConfig(value: Expression(formula: '$kInputKey > 10')),
            acknowledgeRequired: false,
          ),
        ],
      ),
      if (twoAlarms)
        AlarmConfig(
          uid: kSecondAlarmUid,
          title: 'Packer overspeed',
          description: 'CN04 is running above its commissioned limit',
          group: const <String>['Line 4'],
          rules: <AlarmRule>[
            AlarmRule(
              level: AlarmLevel.warning,
              expression: ExpressionConfig(
                  value: Expression(formula: '$kSecondInputKey > 10')),
              acknowledgeRequired: false,
            ),
          ],
        ),
    ]);

/// One backend, two panels, and everything the arms read off them.
final class _TwoPanels {
  _TwoPanels._(this.fixture, this.a);

  final BackendRelayFixture fixture;

  ComposedBackendUnderTest get backend => fixture.backend;

  /// The panel that was already connected when the plant went wrong.
  final _Panel a;

  _Panel? _b;

  /// The second panel. Connected at stand-up unless a case asked otherwise.
  _Panel get b =>
      _b ?? (throw StateError('panel B has not joined yet — call joinB()'));

  static Future<_TwoPanels> standUp(
      {bool connectB = true, bool twoAlarms = false}) async {
    final fixture = backendRelayFixture(
      alarms: _config(twoAlarms: twoAlarms),
      // Injected, fixed and two years in the past, so "the plant's time" and
      // "the backend's time" can never accidentally be equal — the only
      // condition under which arm 2 can fail.
      clock: () => kBackendNow,
    );
    await fixture.ready;

    final rig = _TwoPanels._(fixture, await _Panel.attach(fixture.client));
    if (connectB) await rig.joinB();
    return rig;
  }

  Future<void> joinB() async =>
      _b = await _Panel.attach(await fixture.connectClient('B'));

  /// Puts the alarm's input above its limit, stamped by the plant.
  void raise() => raiseAt(kPlantInstant);

  /// The same, with a chosen plant instant — arm 6 needs one per activation so
  /// a publication can be matched to the frame that carried it.
  void raiseAt(DateTime sourceTime) =>
      backend.harness.setValue(kInputKey, 42.0, sourceTime: sourceTime);

  /// Raises the second alarm (arm 3 only), two seconds after the first.
  void raiseSecond() => backend.harness
      .setValue(kSecondInputKey, 42.0, sourceTime: kSecondPlantInstant);

  /// Puts it back under, stamped a second later — still the plant's clock.
  void clear() => backend.harness.setValue(kInputKey, 1.0,
      sourceTime: kPlantInstant.add(const Duration(seconds: 1)));

  /// The active set as the ENGINE holds it, on this side of the socket.
  List<relay.AlarmActiveEntry> get backendEntries =>
      backend.engine!.active.toList();

  int get lastPublicationMicros => backend.alarmPublications.last.atMicros;

  /// When the backend published the set carrying an entry stamped [stamp].
  ///
  /// Matched by the instant in the payload rather than by position, so a
  /// publication nobody was expecting — a `historyId` republication, a second
  /// rule's first verdict — cannot silently shift the pairing.
  int? publicationOf(DateTime stamp) {
    for (final publication in backend.alarmPublications) {
      if (publication.key != relay.AlarmKeys.active) continue;
      // `toJson(slim: true)`, never `.value`: `DynamicValue` normalizes a list
      // of maps into `List<DynamicValue>` of `Map<Object, DynamicValue>`, so
      // the raw field is not the payload `decodeList` speaks. The slim form is
      // literally what goes on the wire, which is also what makes this
      // comparison a comparison of the same bytes the panel decoded.
      final decoded = relay.AlarmActiveEntry
          .decodeList(publication.value.toJson(slim: true));
      if (decoded.entries
          .any((e) => e.activeAtMs == stamp.millisecondsSinceEpoch)) {
        return publication.atMicros;
      }
    }
    return null;
  }

  Future<void> awaitStamp(DateTime stamp) => _waitUntil(
        () => a.receiptOf(stamp) != null && b.receiptOf(stamp) != null,
        reason: 'an activation stamped ${stamp.toIso8601String()} never '
            'reached both panels. ${evidence()}',
      );

  Future<void> awaitActive({bool onlyA = false}) =>
      awaitCount(1, onlyA: onlyA);

  /// Waits until panel A has received [n] value frames for the active set.
  ///
  /// A barrier on ARRIVAL rather than on content: whether the content is right
  /// is what the arm asserts, and a barrier that waited for the right content
  /// would turn a wrong answer into a timeout with no property named.
  Future<void> awaitValueFrames(int n) => _waitUntil(
        () => a.valueFrames.length >= n,
        reason: 'panel A was never told about activation $n. ${evidence()}',
      );

  Future<void> awaitCount(int count, {bool onlyA = false}) => _waitUntil(
        () =>
            a.entries.length == count &&
            (onlyA || (_b?.entries.length ?? 0) == count),
        reason: '$count active alarm(s) never reached '
            '${onlyA ? 'panel A' : 'both panels'}. ${evidence()}',
      );

  Future<void> awaitEmpty() => _waitUntil(
        () => a.entries.isEmpty && (_b?.entries.isEmpty ?? true),
        reason: 'the clear never reached both panels. ${evidence()}',
      );

  String evidence() => 'backend: active=${backendEntries.length}, '
      'evaluations=${backend.engine!.evaluations}, '
      'publications=${backend.engine!.publications}, '
      'suspended=${backend.engine!.suspendedRuleCount}, '
      'refusals=${backend.engine!.refusals}, '
      'rules=${backend.engine!.config?.alarms.length}, '
      'inputs=${[
        for (final k in const [kInputKey, kSecondInputKey])
          '$k=${backend.composition.freshness.read(k)?.value}'
              '@${backend.composition.freshness.read(k)?.quality.code}'
      ]}; '
      'A: ${a.describe()}; B: ${_b?.describe() ?? 'not connected'}';
}

/// One panel: a socket, a session, one subscription, and its current view.
final class _Panel {
  _Panel._(this._client, this._snapshot, this._subscribed, this.sessionId);

  static Future<_Panel> attach(BackendRelayClient client) async {
    final hello = await client.hello();
    // Listening BEFORE the subscribe request goes out. An update that raced
    // the answer would otherwise be a frame nobody saw, and the panel's view
    // would be permanently one transition behind for a reason no arm names.
    final frames = <ServerNotification>[];
    final sub = client.notifications.listen(frames.add);
    addTearDown(sub.cancel);

    final result = await client.subscribe(kSub, <String>[relay.AlarmKeys.active]);
    final panel = _Panel._(client, result, frames, hello.sessionId);
    return panel;
  }

  final BackendRelayClient _client;
  final relay.SubscribeResult _snapshot;
  final List<ServerNotification> _subscribed;

  /// The gateway's own id for this session — different per socket.
  final String sessionId;

  String get name => 'panel ${_client.name}';

  /// The keys the server actually bound, from the subscribe answer.
  List<String> get subscribedKeys => _snapshot.handles.keys.toList();

  Map<String, relay.KeyReject> get rejectedKeys => _snapshot.rejected;

  int? get _handle => _snapshot.handles[relay.AlarmKeys.active];

  /// Every `u` frame for this subscription that moved the active set.
  List<({int seq, relay.WireValue value, int atMicros})> get valueFrames {
    final out = <({int seq, relay.WireValue value, int atMicros})>[];
    for (final frame in _updates) {
      final value = frame.update.changes[_handle];
      if (value == null) continue;
      out.add((seq: frame.update.seq, value: value, atMicros: frame.atMicros));
    }
    return out;
  }

  List<({relay.UpdateParams update, int atMicros})> get _updates => [
        for (final n in _subscribed)
          if (n.method == relay.Methods.update)
            (
              update: relay.UpdateParams.fromJson(n.params),
              atMicros: n.atMicros
            )
      ].where((f) => f.update.sub == kSub).toList();

  /// When the most recent value for this key landed, on the fixture's clock.
  int? get lastValueMicros =>
      valueFrames.isEmpty ? null : valueFrames.last.atMicros;

  /// When the frame carrying an entry stamped [stamp] landed here.
  ///
  /// Null until it has. Matched on the instant inside the payload, so this is
  /// also the barrier arm 6 waits on: "the panel holds THIS activation", not
  /// "some frame arrived".
  int? receiptOf(DateTime stamp) {
    for (final frame in valueFrames) {
      final decoded = relay.AlarmActiveEntry.decodeList(frame.value.v);
      if (decoded.entries
          .any((e) => e.activeAtMs == stamp.millisecondsSinceEpoch)) {
        return frame.atMicros;
      }
    }
    return null;
  }

  /// The current wire state of `ALARM.active` at this panel: the snapshot, with
  /// every later frame for it applied in order.
  ///
  /// Quality-only transitions (`q`) are folded in as well as value changes,
  /// which is what makes arm 7 able to fail: a sweep that badged the key
  /// `badStale` sends exactly that and nothing else.
  ({Object? value, relay.Quality quality}) get _state {
    final seed = _snapshot.snapshot[_handle];
    var value = seed?.v;
    var quality = seed?.q ?? relay.Quality.uncertainNotYetKnown;
    for (final frame in _updates) {
      final changed = frame.update.changes[_handle];
      if (changed != null) {
        value = changed.v;
        quality = changed.q;
        continue;
      }
      final q = frame.update.qualities[_handle];
      if (q != null) quality = q;
    }
    return (value: value, quality: quality);
  }

  relay.Quality get quality => _state.quality;

  /// The active set this panel currently holds, decoded off the wire.
  List<relay.AlarmActiveEntry> get entries =>
      relay.AlarmActiveEntry.decodeList(_state.value).entries;

  /// What was in the SUBSCRIBE ANSWER — before any update could arrive.
  List<relay.AlarmActiveEntry> get snapshotEntries =>
      relay.AlarmActiveEntry.decodeList(_snapshot.snapshot[_handle]?.v).entries;

  /// Every raw frame this panel received containing [needle].
  List<String> framesMentioning(String needle) =>
      [for (final f in _client.inbound) if (f.contains(needle)) f];

  /// Every method name this panel has sent.
  List<String> get sentMethods => _client.sentMethods;

  /// How many heartbeats it has sent.
  int get heartbeats => _client.heartbeats;

  /// Whether the gateway has closed this panel's socket.
  bool get closedByServer => _client.closedByServer;

  /// Every server notification that landed after [micros] on the rig's clock.
  List<ServerNotification> framesSince(int micros) =>
      [for (final n in _subscribed) if (n.atMicros > micros) n];

  /// Whether [frame] is this panel's active-set subscribe answer, or an update
  /// for that subscription carrying its handle.
  bool isAlarmValueFrame(String frame) {
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return false;
    if (decoded['id'] is int) {
      // The only request that can answer with a value is the subscribe, and it
      // must be the one that bound this key.
      final result = decoded['result'];
      return result is Map &&
          (result['handles'] as Map?)?.containsKey(relay.AlarmKeys.active) ==
              true;
    }
    if (decoded['method'] != relay.Methods.update) return false;
    final params = (decoded['params'] as Map?)?.cast<String, Object?>();
    if (params == null) return false;
    final update = relay.UpdateParams.fromJson(params);
    return update.sub == kSub && update.changes.containsKey(_handle);
  }

  String describe() => 'closedByServer=$closedByServer, '
      'beats=$heartbeats, handle=$_handle, quality=${quality.code}, '
      'entries=${entries.map((e) => '${e.uid}#${e.ruleIndex}@'
          '${e.activeAtMs}').toList()}, '
      'updates=${valueFrames.length}, frames=${_client.inbound.length}';
}

/// Polls [condition] until it holds, or fails with [reason].
///
/// A poll rather than a stream await, for the reason the state above is
/// reconstructed rather than accumulated: the property is "what does this panel
/// hold now", and a barrier that waited for a specific frame would pass on a
/// backend that sent the right frame and the wrong value.
Future<void> _waitUntil(
  bool Function() condition, {
  required String reason,
  Duration budget = const Duration(seconds: 20),
}) async {
  // A `Stopwatch`, not two readings of `DateTime.now()`. Nothing in this file
  // is anchored on a wall clock — that is the whole subject of arm 2 — and a
  // backwards NTP step across a poll would turn a passing barrier into a
  // failure nobody could reproduce.
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > budget) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
