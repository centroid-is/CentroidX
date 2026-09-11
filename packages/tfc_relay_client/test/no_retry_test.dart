@TestOn('vm')

/// WRT-03: no code path in this system re-sends a write on its own.
///
/// **What the requirement claims.** A re-send is always an operator decision.
/// Not on a timeout, not on a reconnect, not on the one verdict that is
/// re-send-safe (`not_received`) — the machine never decides to actuate a
/// second time because the first answer was slow or absent. CLAUDE.md states
/// it as "never auto-retried", and it is the sentence the whole three-state
/// `WriteResult` exists to keep enforceable: "unknown" is only honest if
/// nothing downstream quietly turns it into "try again".
///
/// **The behavioural half already exists, in three places.** They are named
/// here rather than restated, because a fourth copy of an existing assertion is
/// a maintenance cost that buys nothing:
///
///  * `tfc_stateman_contract/lib/src/write_contract.dart:341-365` —
///    `checkExactlyOneUpstreamAttemptPerCmd`, which runs against every
///    implementation on every leg and asserts the plant's own attempt counter
///    is 1 for both an ordinary write and one whose outcome nobody knows.
///  * `test/gate/half_open_gate_test.dart:148` — F5a, a write across a
///    total blackhole: `debugWritesSent == 1`.
///  * `test/gate/write_in_flight_gate_test.dart:91-104` — F7a, the link killed
///    with a write on the wire: `debugWritesSent == 1` before the reconnect and
///    again after the `writeStatus` re-query, because the recovery asks about
///    the command rather than repeating it.
///
/// **What this file adds is the structural half.** Every one of those cases
/// judges a retry that exists. None of them says anything about a retry that
/// does not exist *yet* — and the way this property dies is not a broken test,
/// it is somebody wrapping a send in a `for` loop or a `.retry()` extension in
/// a refactor that looks like plumbing. So the four seams through which a write
/// can reach the plant are pinned at exactly one call site each, measured in
/// this tree, with the failure message naming the file and line of every
/// occurrence found — so a second call site reads as "here is the second
/// actuation" and not as "expected 1, got 2".
///
/// **What the structural arm does not prove** (05-RESEARCH §D.2). It pins
/// *call sites* and one scheduling primitive. It does not pin control flow: a
/// `for (var i = 0; i < 2; i++)` wrapped around the one existing
/// `sendRequest` passes every case in groups 1 and 2, because there is still
/// exactly one call site. That gap is what group 3 is for — it watches the
/// plant's own counter across a link flap, where a loop shows up as a second
/// attempt no matter how it was spelled. Neither group is sufficient alone;
/// the pair is.
///
/// An analyzer plugin would close the gap properly and was rejected for a
/// stated reason (05-RESEARCH §D.2 arm 3): it needs `analyzer` as a dependency,
/// which is the version-solve blocker three pubspecs in this workspace name
/// explicitly. A grep pin plus a behavioural arm is the cheapest honest
/// mechanism, and "honest" is doing work in that sentence — see the paragraph
/// above.
///
/// **Why there is no `retry` substring sweep.** It was measured and it is not
/// pinnable: `retry` appears 3 times in `lib/src/client_config.dart` and 10
/// times in `lib/src/connection_supervisor.dart` in non-comment text, and all
/// thirteen are *reconnect* vocabulary — `_retry` the backoff timer, "the very
/// first retry would already…" in a config refusal. Retrying a dial is
/// legitimate and necessary; retrying a write is the thing this file exists to
/// forbid. A sweep that could not tell them apart would be switched off within
/// a month. Do not add one.
///
/// **Precedent.** The sweep helpers are `tfc_relay_server`'s
/// `test/handler_table_test.dart:110-158` (`_testFiles` / `_mentions`) and both
/// of its anti-vacuity arms at `:192-214`; the read-the-source-as-text shape
/// with an `existsSync` guard is `test/client_config_test.dart:202-222`.
library;

import 'dart:io';

import 'package:test/test.dart';

// No `tfc_relay_protocol` import, and its absence is the point: group 3 names
// no `WriteResult` variant. It reads `outcome.cmd` and two counters, so the
// case cannot be quietly disarmed by 05-03 changing which variant comes back.
import 'support/fault_fixture.dart';

// ---------------------------------------------------------------------------
// The sweep.
// ---------------------------------------------------------------------------

/// Every `.dart` file under [directory], recursively; empty when it is absent.
///
/// Absence is reported as "nothing found" rather than thrown, because the
/// scopes below reach across package boundaries with `../` and the case that
/// notices a moved package should be the named `existsSync` one, not a
/// stack trace inside a helper.
List<File> _dartFiles(Directory directory) {
  if (!directory.existsSync()) return const [];
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();
}

/// Every non-comment occurrence of [needle] in [file], as `(line, text)`.
///
/// A line is dropped when its `trimLeft()` starts with `///` or `//`, which is
/// the same rule `client_config_test.dart:213` uses. Docs on this path
/// *discuss* the seams at length — `deadline.dart:34` and
/// `failure_taxonomy.dart:12` both name `sendRequest` in prose — and a sweep
/// that counted prose would be pinned to the wording of a comment.
///
/// One entry per match, not per line: two call sites written on one line are
/// two call sites.
List<(int, String)> _mentions(File file, Pattern needle) {
  final hits = <(int, String)>[];
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('///') || trimmed.startsWith('//')) continue;
    for (final _ in needle.allMatches(lines[i])) {
      hits.add((i + 1, lines[i]));
    }
  }
  return hits;
}

/// Every non-comment occurrence of [needle] under [scope], as `path:line  text`.
List<String> _occurrences(Directory scope, Pattern needle) {
  final hits = <String>[];
  for (final file in _dartFiles(scope)) {
    for (final (line, text) in _mentions(file, needle)) {
      hits.add('${file.path}:$line  ${text.trim()}');
    }
  }
  return hits;
}

// ---------------------------------------------------------------------------
// The seams.
// ---------------------------------------------------------------------------

/// One place a write can move one hop closer to the plant.
final class _Seam {
  const _Seam({
    required this.caseName,
    required this.spelling,
    required this.scope,
    required this.needle,
    required this.expected,
    required this.soleSite,
    required this.consequence,
  });

  /// The case name, written as the property rather than as the grep, so a
  /// failure in CI reads as a claim about the system.
  final String caseName;

  /// How the seam is spelled in the source, for the failure message.
  final String spelling;

  /// Directory to walk, **relative to the `tfc_relay_client` package root**.
  ///
  /// `dart test` runs with the package root as its working directory, which is
  /// what makes `../` reach the sibling packages. The `existsSync` case below
  /// is the one that notices when that stops being true.
  final String scope;

  final Pattern needle;

  /// Measured in this tree at plan time. An assertion, not a guess.
  final int expected;

  /// Where the one call site was when this pin was written. Informational: the
  /// line number will drift and the count will not.
  final String soleSite;

  /// What a second call site would mean on a plant, in the operator's terms.
  final String consequence;
}

/// The seven hops, gateway-ward, each singular today.
///
/// The first four were measured 2026-08-14, before the hold path existed. The
/// last three are 05-REVIEW WR-05: an engage is a real write with a real
/// three-state outcome, so "the engage came back unknown, try once more" is
/// precisely the well-meaning wrapper these pins exist to catch — and unlike a
/// setpoint, the second one starts a jog nobody is holding. All measured in
/// this worktree with `///` and `//` lines stripped.
final List<_Seam> _seams = <_Seam>[
  _Seam(
    // This exact name is what a second `peer.sendRequest(` under `lib/` trips.
    caseName: 'the client has exactly one place where a request leaves for '
        'the gateway',
    spelling: 'sendRequest',
    scope: 'lib',
    needle: RegExp(r'sendRequest'),
    expected: 1,
    soleSite: 'lib/src/deadline.dart:95, inside callWithDeadline',
    consequence: 'every request this client makes — writes included — goes '
        'through one line, and that line reads the peer into a local before it '
        'suspends so a reconnect cannot retarget a request at the replacement '
        'socket (deadline.dart:90-95). A second send site is a second place '
        'that guarantee has to be re-established by hand, and the first time '
        'it is not, an operator\'s one press of a button strokes the ram '
        'twice.',
  ),
  _Seam(
    caseName: 'the client names the write method in exactly one place',
    spelling: 'Methods.write',
    scope: 'lib',
    // Word-bounded on purpose: `Methods.writeStatus` at
    // remote_state_man.dart:691 contains `Methods.write` as a substring, and
    // it is the *recovery* method — the one that asks about a command instead
    // of repeating it. A substring sweep would count the cure as a symptom.
    needle: RegExp(r'Methods\.write\b'),
    expected: 1,
    soleSite: 'lib/src/remote_state_man.dart:544, inside RemoteStateMan.write',
    consequence: 'the write method is named once, by the method that mints the '
        'id, registers it as unresolved and counts the send. A second mention '
        'is a write leaving the client without that bookkeeping, so its '
        'outcome is unattributable and `writeStatus` can never ask about it.',
  ),
  _Seam(
    caseName: 'the gateway hands a write to the source in exactly one place',
    spelling: 'api.write(',
    scope: '../tfc_relay_server/lib',
    needle: RegExp(r'api\.write\('),
    expected: 1,
    soleSite: '../tfc_relay_server/lib/src/value_handlers.dart:309',
    consequence: 'this is the gateway\'s only crossing into the plant, and it '
        'is wrapped by the outcome log that makes the write answerable after a '
        'reconnect. A retry here is the worst of the four: the client sent '
        'once, believes it sent once, and reports one outcome for two '
        'actuations.',
  ),
  _Seam(
    caseName: 'the gateway takes a source-side hold in exactly one place',
    spelling: 'api.holdToRun(',
    scope: '../tfc_relay_server/lib',
    needle: RegExp(r'api\.holdToRun\('),
    expected: 1,
    soleSite: '../tfc_relay_server/lib/src/value_handlers.dart:532, inside '
        'the write path\'s hold branch',
    consequence: 'an engage is a real write, so a retry around it is a second '
        'movement of a machine the operator asked to move once — and unlike a '
        'setpoint, the second one starts a jog nobody is holding. A second '
        'site is also a second handle: the map that `releaseAllHolds` '
        'iterates holds one entry per key, and a hold that is not in it is a '
        'hold no session teardown can end.',
  ),
  _Seam(
    caseName: 'the gateway releases a hold in exactly one place on the write '
        'path',
    spelling: 'hold.release(',
    scope: '../tfc_relay_server/lib',
    // Word-bounded, which deliberately does not match `releaseAllHolds`'s
    // call: that one is spelled `hold\n  .release(reason:` across two lines
    // and is the *teardown* path, not the write path. Pinning both under one
    // count would make a legitimate edit to either look like a second
    // actuation site on the other.
    needle: RegExp(r'\bhold\.release\('),
    expected: 1,
    soleSite: '../tfc_relay_server/lib/src/value_handlers.dart:545, the '
        'hold-flag release branch',
    consequence: 'the release writes the zero that stops the machine in the '
        'same PLC scan. A second site is a second zero on a tag another panel '
        'may be feeding, and 0 is reserved for "released" — so the second one '
        'tells that panel\'s PLC the operator let go when they have not.',
  ),
  _Seam(
    caseName: 'the client feeds a deadman from exactly one place',
    spelling: 'Methods.holdTick',
    scope: 'lib',
    needle: RegExp(r'Methods\.holdTick'),
    expected: 1,
    soleSite: 'lib/src/remote_state_man.dart:764, inside _sendHoldTick',
    consequence: 'the one site gates every pulse on the link being ready and '
        'drops the rest, because a tick that cannot be sent must never be '
        'stored (`_WsSink.add` buffers without bound and reports nothing, '
        'flutter#103306). A second site is a second thing that can put a '
        'counter value on the wire without that gate, which is a burst of '
        'stale counter values arriving the instant a stalled link recovers — '
        'a machine jogging on a finger that came off a minute ago.',
  ),
  _Seam(
    caseName: 'the plant counts an upstream attempt in exactly one place',
    spelling: '_attempt(cmd)',
    scope: '../tfc_stateman_contract/lib',
    needle: RegExp(r'_attempt\(cmd\)'),
    expected: 1,
    soleSite: '../tfc_stateman_contract/lib/testing/fake_state_man.dart:688, '
        'inside attemptUpstreamWrite',
    consequence: 'this counter is what every behavioural no-retry check in the '
        'suite reads. A second increment site does not cause a double '
        'actuation — it makes the number that would have detected one stop '
        'meaning "attempts", which is worse, because the suite goes on '
        'reporting green (fake_state_man.dart:670-681 argues the same point '
        'from the other side).',
  ),
];

/// The one file group 2 reads, relative to the package root.
const _remoteStateManPath = 'lib/src/remote_state_man.dart';

/// The one file group 2b reads — the heartbeat's carve-out.
const _heartbeatPumpPath = 'lib/src/heartbeat_pump.dart';

// ---------------------------------------------------------------------------
// The behavioural arm.
// ---------------------------------------------------------------------------

/// The tag group 3 drives. Seeded before the gateway starts, because
/// `FakeStateMan.keys` does not name a tag until a value has been set on it
/// and a key seeded later is rejected as a typo (`fault_fixture.dart:103-109`).
const _flapKey = 'ST101.CN01.MOT01.setpoint';

/// The budget for "the panel came back": a capped backoff draw, a dial, a
/// handshake and a snapshot. `support/gate_bands.dart:64-68`'s number and
/// its argument — a liveness budget, never a latency measurement.
const Duration _recovery = Duration(seconds: 5);

/// Long enough for anything that was going to happen to have happened.
///
/// Used at exactly one place and only for the one shape a poll cannot
/// establish — that *nothing* further occurred. Polling for a second upstream
/// attempt would pass the instant it did not find one, which is every instant
/// before the retry a well-meaning wrapper is about to make.
/// `support/gate_bands.dart:70-75` is the same constant for the same
/// reason.
const Duration _settle = Duration(milliseconds: 400);

void main() {
  group('the write path has one call site per seam', () {
    // Anti-vacuity, and the reason it comes first: every count case below is
    // trivially satisfiable by reading nothing. `handler_table_test.dart:
    // 192-214` learned this the same way.
    test('every scope the sweep reads exists', () {
      for (final scope in {for (final seam in _seams) seam.scope}) {
        expect(Directory(scope).existsSync(), isTrue,
            reason: 'the sweep found no directory at "$scope", so every count '
                'it reports for that scope is 0 and every pin over it has '
                'been passing against nothing. These paths are relative to '
                'the tfc_relay_client package root; dart test was invoked '
                'from ${Directory.current.path}. Either a package moved or '
                'the working directory did.');
      }
    });

    test('the sweep found dart files in every scope', () {
      for (final scope in {for (final seam in _seams) seam.scope}) {
        expect(_dartFiles(Directory(scope)), isNotEmpty,
            reason: 'the scope "$scope" exists and holds no .dart file, so '
                'the sweep over it read nothing. A scope that resolves to '
                'nothing makes every count zero and every assertion below '
                'vacuous.');
      }
    });

    test('discovery reports zero for an empty directory', () {
      final empty = Directory.systemTemp.createTempSync('relay-no-retry-');
      addTearDown(() => empty.deleteSync(recursive: true));

      expect(_dartFiles(empty), isEmpty);
      for (final seam in _seams) {
        expect(_occurrences(empty, seam.needle), isEmpty,
            reason: 'pointed at an empty directory the sweep reported an '
                'occurrence of ${seam.spelling}, so the counter is inventing '
                'rather than measuring and nothing it says about the real '
                'scopes can be trusted');
      }
    });

    for (final seam in _seams) {
      test(seam.caseName, () {
        final found = _occurrences(Directory(seam.scope), seam.needle);

        expect(found, hasLength(seam.expected),
            reason: 'the ${seam.spelling} seam has ${found.length} '
                'non-comment call sites under "${seam.scope}", not '
                '${seam.expected}.\n\n'
                '${seam.consequence}\n\n'
                'At the time this pin was written the only one was '
                '${seam.soleSite}. Everything the sweep found now:\n'
                '${found.isEmpty ? '  (nothing — see the anti-vacuity cases '
                    'above)' : found.map((hit) => '  $hit').join('\n')}\n\n'
                'If the new site is genuinely not a second actuation — a '
                'rename, a second *read* path — raise the expected count here '
                'and say in this file why the new site cannot re-send a '
                'write. Raising the number without that sentence is how this '
                'pin stops being one.');
      });
    }
  });

  group('the client schedules nothing of its own on the write path', () {
    // A weaker claim than the group above and worth being precise about: this
    // pins one scheduling primitive in one file. A retry does not need a
    // `Timer` — a `for` loop around the existing call site would pass this
    // group and pass group 1 too, because it adds no call site. That is what
    // group 3 is for: the plant's own counter cannot be fooled by control
    // flow.
    //
    // `Timer` is pinned anyway because the *delayed* retry is the shape that
    // actually ships: "it timed out, wait 200 ms, send it again". The backoff
    // timer that legitimately exists lives in `connection_supervisor.dart` and
    // dials sockets; `remote_state_man.dart:283`'s `debugTimerCount` is a
    // delegation to it and contains no `Timer(` of its own.
    test('remote_state_man.dart schedules nothing', () {
      final source = File(_remoteStateManPath);
      expect(source.existsSync(), isTrue,
          reason: 'this case reads the implementation as text, so it must run '
              'with the tfc_relay_client package root as the working '
              'directory; dart test was invoked from '
              '${Directory.current.path} and found no '
              '$_remoteStateManPath');

      for (final needle in <Pattern>[RegExp(r'Timer\('), RegExp(r'Timer\.periodic')]) {
        final found = _mentions(source, needle)
            .map((hit) => '$_remoteStateManPath:${hit.$1}  ${hit.$2.trim()}')
            .toList();

        expect(found, isEmpty,
            reason: 'the client\'s write path now schedules something of its '
                'own:\n${found.map((hit) => '  $hit').join('\n')}\n\n'
                'Every legitimate timer this client owns belongs to the '
                'connection supervisor and its watchdog, which dial sockets '
                'and time out reads. A timer here schedules something about a '
                'write, and the only thing there is to schedule about a write '
                'whose answer has not come back is sending it again — which '
                'is an operator\'s decision and never this process\'s.');
      }
    });
  });

  group('the heartbeat is a carve-out, and the carve-out is fenced', () {
    // **Why this group exists at all.** The group above pins
    // `remote_state_man.dart` at zero `Timer(`, and that pin is what made
    // 07-08 escalate the missing heartbeat as a Rule 4 finding rather than
    // fixing it inline: a periodic client-to-gateway frame needs a timer, and
    // the file that would have held it is the file that may not.
    //
    // 07-08b did not loosen that pin. It put the timer in a file of its own
    // and fenced that file here, which is the difference between a carve-out
    // and an exception. The write path still schedules nothing; one other file
    // schedules exactly one thing, and the two cases below say what it is
    // allowed to be.
    //
    // **What this does not claim.** Same limit as the group above, in the same
    // words: this pins a scheduling primitive and a method name, not control
    // flow. A `for` loop inside `_sendBeat` would pass both cases. What it
    // catches is the shape that actually ships — a second timer added to "also
    // re-send X every N seconds", and a send site widened from `ping` to
    // something with an effect on the plant.
    test('$_heartbeatPumpPath schedules exactly one thing', () {
      final source = File(_heartbeatPumpPath);
      expect(source.existsSync(), isTrue,
          reason: 'this case reads the implementation as text and found no '
              '$_heartbeatPumpPath; dart test was invoked from '
              '${Directory.current.path}. If the pump was renamed or removed, '
              'this pin has to move with it — a carve-out whose fence stopped '
              'matching anything is a carve-out with no fence');

      final periodic = _mentions(source, RegExp(r'Timer\.periodic\('))
          .map((hit) => '$_heartbeatPumpPath:${hit.$1}  ${hit.$2.trim()}')
          .toList();
      expect(periodic, hasLength(1),
          reason: 'the heartbeat pump holds ${periodic.length} periodic '
              'timers, not one:\n${periodic.map((h) => '  $h').join('\n')}\n\n'
              'One is the whole permission this file was given. A second '
              'periodic timer in here is something else being scheduled '
              'alongside the heartbeat, with the heartbeat\'s exemption and '
              'without the heartbeat\'s argument — and `debugTimerCount` would '
              'go on answering 1, because it reports the field rather than '
              'counting the timers. If the new one is genuinely a liveness '
              'frame, say here why it cannot carry anything else.');

      final oneShot = _mentions(source, RegExp(r'(?<!\.)\bTimer\('))
          .map((hit) => '$_heartbeatPumpPath:${hit.$1}  ${hit.$2.trim()}')
          .toList();
      expect(oneShot, isEmpty,
          reason: 'the heartbeat pump now schedules a one-shot timer as well:\n'
              '${oneShot.map((h) => '  $h').join('\n')}\n\n'
              'A `Timer(...)` here is a delay before doing something once, and '
              'the only things this class does are beat and stop. A retry '
              'after a failed beat would be the first one written, and a beat '
              'that is worth retrying two hundred milliseconds later is a beat '
              'the next period covers anyway.');
    });

    test('the heartbeat names one method, and it is ping', () {
      final source = File(_heartbeatPumpPath);
      expect(source.existsSync(), isTrue,
          reason: 'no $_heartbeatPumpPath to read; see the case above');

      final named = _mentions(source, RegExp(r'Methods\.\w+'));
      expect(named, isNotEmpty,
          reason: 'the pump names no protocol method at all in non-comment '
              'text, so the assertion below is about an empty list — either '
              'the send site moved out of this file, in which case the fence '
              'is around the wrong thing, or the sweep stopped reading it');

      final spellings = <String>{
        for (final (_, text) in named)
          for (final match in RegExp(r'Methods\.\w+').allMatches(text))
            match.group(0)!,
      };
      expect(spellings, {'Methods.ping'},
          reason: 'the heartbeat pump names $spellings. It may name '
              '`Methods.ping` and nothing else.\n\n'
              'This is the fence, and the thing on the other side of it is a '
              'timer that fires on its own schedule with no operator behind '
              'it. `ping` is safe there because it has no effect on the plant '
              'and no outcome anybody has to reconcile; a write, a hold tick '
              'or even a read on that same timer is a frame nobody asked for, '
              'sent on a repeating schedule, with none of the bookkeeping '
              '`RemoteStateMan.write` does — and in the worst case it is a '
              'machine moving because a timer went off.\n\n'
              'If the pump genuinely needs a second method, it is no longer a '
              'heartbeat and it does not belong behind this exemption.');
    });
  });

  group('a link flap with a write in flight costs the plant one attempt', () {
    // The half groups 1 and 2 cannot reach. A `for` loop around the one
    // existing call site adds no call site and no timer, and it is the second
    // most likely way this property dies (the first is a library doing it for
    // us, which is why `_seams` spans three packages). Control flow is
    // invisible to a text sweep and unmissable at the plant: the counter
    // increments whatever the loop looked like.
    test('a write in flight across a link flap reaches the plant exactly once',
        () async {
      // **Why this asserts the counter and not the outcome kind**
      // (05-RESEARCH §D.2 arm 2). The obvious version of this case asserts
      // `WriteUnknown(gateway_lost_track)` at the end. It would pass today and
      // stop testing anything the moment 05-03 lands the idempotency window:
      // a same-fingerprint replay is then answered from the gateway's outcome
      // log and never reaches the plant at all, so the outcome stays exactly
      // as expected while the property it stood for goes unmeasured. The
      // plant's own attempt counter survives that change, because it is
      // counting the thing the requirement is about — actuations, not
      // answers.
      //
      // **Both ends, and neither alone.** `debugWritesSent` is the client's
      // account of how many times it offered bytes to a socket;
      // `upstreamWriteAttempts` is the plant's account of how many times a
      // command reached it. A retry in the client moves the first; a retry in
      // the gateway or in the source moves only the second. The pair reads
      // "sent once, arrived once", and either on its own is half a claim —
      // which is precisely the asymmetry the sabotage arm for this case
      // exercises.
      //
      // The fixture is imported from `support/fault_fixture.dart` rather than
      // rebuilt, because the teardown ordering it documents is easy to get
      // wrong and a fifth copy would be a fifth place to get it wrong in.
      final fixture = await faultFixture(
        keys: const {_flapKey},
        withProxy: true,
        seed: (plant) => plant.setValue(_flapKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // Anti-vacuity: the page has to have been live before the flap, or the
      // whole case is a statement about a client that never worked.
      expect(fixture.client.read(_flapKey)?.value, 1200,
          reason: 'the subscription was not carrying the seeded value before '
              'the write, so nothing below is about a live panel');

      // Stalled at the plant so the cut lands while the write is genuinely
      // out — not before it left, not after it came back.
      fixture.served.stallWrites();
      final pending = fixture.client.write(_flapKey, 1500);
      await until('the write to reach the plant',
          () => fixture.served.writesInFlight > 0,
          budget: _recovery);

      // The flap: cut, and let the client's own reconnect loop bring it back.
      fixture.proxy.killOnce();

      final outcome = await pending.timeout(_recovery);

      // Anti-vacuity for the counter read below. `upstreamWriteAttempts`
      // answers 0 for an id it has never heard of, so an assertion of 1
      // against the wrong id would fail — but an assertion of 1 against the
      // right id only means "one attempt" if the plant is keyed by the id the
      // client minted. The gateway forwards the client's cmd rather than
      // minting its own (`value_handlers.dart:295-311`), and this is the case
      // that notices if that ever changes.
      expect(fixture.served.mintedCmds, contains(outcome.cmd),
          reason: 'the plant never saw the command id the client minted, so '
              'the attempt count read below is about some other write — or '
              'about no write at all');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the client offered the write to a socket '
              '${fixture.client.debugWritesSent} times for one operator '
              'action');

      // The recovery has to have actually run before "it did not re-send"
      // means anything: a client still down has not had the opportunity.
      await until('the link to come back after the flap',
          () => fixture.client.isReady,
          budget: _recovery);
      await until('the writeStatus re-query to be answered',
          () => fixture.client.debugWriteStatusAnswers.isNotEmpty,
          budget: _recovery);

      // The plant finally answers, and it answers "I never got a reply from
      // the device" — the non-applied outcome, which is the only kind anybody
      // ever writes a retry for. A source-side retry wrapper fires here, on
      // this line, after every client-side assertion above has already passed.
      fixture.served.releaseWrites(applied: false);
      await Future<void>.delayed(_settle);

      expect(fixture.served.upstreamWriteAttempts(outcome.cmd), 1,
          reason: 'the operator pressed the button once and the command '
              'reached the plant '
              '${fixture.served.upstreamWriteAttempts(outcome.cmd)} times. '
              'On a setpoint that is a value written twice and nobody the '
              'wiser; on a jog or a start it is the machine moving twice. '
              'Everything between the client and the plant — the send seam, '
              'the reconnect, the writeStatus recovery, the gateway\'s '
              'forward — has to be a pass-through for this number to stay at '
              '1, which is why this arm is worth its wall-clock seconds even '
              'with four grep pins above it');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the recovery re-sent the write instead of asking about it. '
              'The reconnect path\'s only legitimate move for an unresolved '
              'command is writeStatus');
    });
  }, tags: 'faults');
}
