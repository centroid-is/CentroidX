/// G1: a divergence under a quiet plant heals itself.
///
/// **The row.** *Silent divergence goes undetected while the plant is quiet.*
/// Force the client to drop one `u`, then hold every subscribed value constant
/// so no further `u` is produced, and assert that
/// the view goes **stale or resyncs** within the deadline.
/// 07-RESEARCH-PUBSUB §D.1 wrote the row down expecting it to fail first, and
/// it did — twice, for two different reasons, which is why this file has two
/// divergence arms rather than one. (The line above is the catalogue's own
/// text, unwrapped on purpose: `f_row_registry.dart`'s doc explains that a
/// wrapped anchor is byte-identical at runtime and not on disk, and the whole
/// value of an anchor is that `grep -F` finds the same bytes in both places.)
///
/// **Arm A, the lost push.** The gateway writes its current per-subscription
/// sequence into every tick (`tick_engine.dart:_writeTick`) and the client
/// throws it away: `FreshnessWatchdog.sawTick` keeps `evaluatedAt` and drops
/// `seq`. The notification handlers are armored drop-not-throw, so a `u` whose
/// body cannot be decoded is discarded without a sound, and the *only* thing
/// that would ever have noticed is the sequence gap on the **next** `u`. If the
/// plant then goes quiet there is no next `u`, and the panel sits on a value the
/// gateway has already superseded while `evaluatedAt` keeps advancing and the
/// freshness watchdog keeps reporting fresh.
///
/// **Arm B, the unannounced handle.** A `u` naming a handle the session never
/// announced costs a complaint and a skipped key — and the *rest* of the batch
/// is applied and the sequence advances (`connection_supervisor.dart:_update`).
/// So the sequence is intact and the cache is not, which means arm A's detector
/// cannot see this one: the tick agrees with the client to the number. Two
/// divergences, two fixes, and the second is why arm B stays red after the first
/// one lands.
///
/// **What "quiet" costs, measured, and why both controls exist.** A detector
/// that resyncs on a healthy quiet link is worse than the bug it fixes — one
/// panel turning silence into a rebuild per tick against the single process
/// serving the whole factory. Arms C and D are that guard, they assert the
/// gateway's own rebuild counter over at least twenty ticks, and **they were
/// green before either fix landed**, which is what makes them worth anything
/// afterwards.
///
/// **The lever both divergence arms use is the plant's own last word.** A value
/// this plant stops changing is degraded to `Quality.badStale` (516) by
/// `FakeStateMan.sweepFreshness` about 300 ms later, and that degradation is a
/// full `u` frame with a new sequence (measured in 07-06 at 351 ms). It is also
/// the *last* frame the plant will ever send for that key, so it is the only
/// frame whose loss produces the quiet-plant divergence the row is about:
/// corrupt the value-change frame instead and the staleness frame that follows
/// heals it 350 ms later, through the ordinary gap path, and the row passes
/// against a client with the bug still in it. Losing the staleness frame leaves
/// the panel showing a number under **good** quality that the gateway has
/// already marked untrustworthy, with nothing on screen to say so — which is
/// PROJECT.md's stale-but-plausible failure, spelled out.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

/// The second key arm B needs: one handle whose change is misfiled, and one
/// whose change is not, in the same batch.
const String _secondKey = 'ST101.CN02.MOT01.setpoint';

/// A handle number no session will ever announce.
///
/// The gateway hands out handles from 1 upwards, one per subscribed key
/// (`session_handlers.dart:208-230`), so on a two-key page 9999 is unreachable
/// by any amount of re-establishing.
const int _unannouncedHandle = 9999;

/// How many ticks the control arms watch a healthy link for.
///
/// Twenty at the 50 ms floor is one second — long enough that a detector firing
/// once per tick would show as twenty rebuilds rather than as a rounding error,
/// and short enough that two control arms cost two seconds of the lane.
const int _controlTicks = 20;

/// How often arm D's plant moves. Well inside the tick, so most ticks carry a
/// push and the off-by-one this arm exists to catch has something to be off by.
const Duration _busyInterval = Duration(milliseconds: 20);

/// The gateway's own count of how many times it has rebuilt this page.
///
/// The same reading `resync_gate_test.dart:_rebuildsServed` takes and for the
/// same reason — one generation is minted per subscribe from a gateway-wide
/// counter, so with one client on one page the delta *is* the number of
/// subscribes the gateway served. Restated here rather than shared: the two
/// files are read side by side when a row goes red, and a helper that moved
/// would take both rows with it.
int _rebuildsServed(FaultFixture fixture, String sub) {
  final state =
      fixture.server.sessions.sessions.single.subscriptions.get(sub);
  if (state == null) {
    fail('the gateway holds no subscription named "$sub", so there is nothing '
        'to count rebuilds of');
  }
  return state.generation;
}

/// The gateway's answer to a `subscribe`, recognised by the one field only it
/// carries (`resync_gate_test.dart:112`).
bool _isSnapshotAnswer(String frame) => frame.contains('"generation"');

bool _isUpdateFrame(String frame) =>
    frame.contains('"method":"${Methods.update}"');

bool _isTickFrame(String frame) => frame.contains('"method":"${Methods.tick}"');

/// How many ticks this seam has carried.
int _ticksSeen(FaultFixture fixture) =>
    fixture.seam.inbound.where(_isTickFrame).length;

/// The decoded `params` of [frame], or null when it is not a JSON object.
Map<String, Object?>? _paramsOf(String frame) {
  final decoded = jsonDecode(frame);
  if (decoded is! Map) return null;
  final params = decoded['params'];
  return params is Map ? params.cast<String, Object?>() : null;
}

/// The sequence [frame] carries for [sub] if it is a tick, else null.
int? _tickSeqOf(String frame, String sub) {
  final subs = _paramsOf(frame)?['subs'];
  if (subs is! Map) return null;
  final entry = subs[sub];
  return entry is Map && entry['seq'] is num
      ? (entry['seq'] as num).toInt()
      : null;
}

/// The sequence an update frame carries, or null when its body is not one this
/// client could have decoded either.
int? _updateSeqOf(String frame) {
  final seq = _paramsOf(frame)?['seq'];
  return seq is num ? seq.toInt() : null;
}

/// Waits until [fixture] has carried [count] more ticks than it had at [from].
Future<void> _awaitTicks(FaultFixture fixture, int from, int count) =>
    until('$count ticks on a healthy link',
        () => _ticksSeen(fixture) - from >= count,
        budget: recovery);

/// Discards exactly one inbound `u` frame, by making its body undecodable.
///
/// **Why a corruption rather than a swallow.** `MessageCorruption` is
/// `String Function(String)` — the seam has no way to deliver nothing — so the
/// frame is delivered with a body the client cannot parse, which is
/// `MalformedPeer`'s own layer and the injection the catalogue names. What
/// happens next is the armor: `UpdateParams.fromJson` throws on a `seq` that is
/// not a number, `_armored` turns it into an `RpcException`, and `json_rpc_2`
/// discards errors raised by a **notification** handler because there is no id
/// to answer them to (`server.dart:215-217`). Nothing is written back to the
/// gateway, nothing is logged, and the sequence the gateway believes it has
/// delivered is one ahead of the one the client has applied. That silence is
/// the whole point of the row.
///
/// A truncation or `garbage()` would lose the frame too, but they are not JSON,
/// so the client's peer answers `-32700` — a frame on the wire, from a case
/// whose subject is that nothing appears on the wire.
final class _DropOneUpdate {
  /// Set to true the moment the case wants the next `u` to be lost.
  bool armed = false;

  /// The frame that was discarded, so the case can prove its lever fired
  /// instead of assuming it.
  String? discarded;

  String call(String message) {
    if (!armed || !_isUpdateFrame(message)) return message;
    final decoded = jsonDecode(message) as Map<String, Object?>;
    final params = (decoded['params']! as Map).cast<String, Object?>();
    armed = false;
    discarded = message;
    params['seq'] = 'this is not a sequence number';
    decoded['params'] = params;
    return jsonEncode(decoded);
  }
}

/// Re-files exactly one key's change in one inbound `u` frame under a handle
/// the session never announced.
///
/// The frame stays a perfectly well-formed, in-sequence `u` carrying a genuine
/// change for the other key: that is the shape the row is about. The handle map
/// is learned from the subscribe answer as it passes through the same lens, so
/// the number rewritten is the one the gateway really assigned rather than one
/// this case guessed.
final class _MisfileOneHandle {
  _MisfileOneHandle(this.key);

  /// Whose change is misfiled.
  final String key;

  bool armed = false;

  /// The frame as the gateway sent it, before the handle was moved.
  String? misfiled;

  int? _handle;

  String call(String message) {
    if (_isSnapshotAnswer(message)) _learnHandles(message);
    if (!armed || !_isUpdateFrame(message)) return message;
    final handle = _handle;
    if (handle == null) return message;
    final decoded = jsonDecode(message) as Map<String, Object?>;
    final params = (decoded['params']! as Map).cast<String, Object?>();
    final changes = params['c'];
    if (changes is! Map || !changes.containsKey('$handle')) return message;
    armed = false;
    misfiled = message;
    changes['$_unannouncedHandle'] = changes.remove('$handle');
    return jsonEncode(decoded);
  }

  void _learnHandles(String message) {
    final decoded = jsonDecode(message);
    if (decoded is! Map) return;
    final result = decoded['result'];
    if (result is! Map) return;
    final handles = result['handles'];
    if (handles is! Map) return;
    final handle = handles[key];
    if (handle is num) _handle = handle.toInt();
  }
}

void main() {
  group('G1 — a divergence under a quiet plant heals itself', () {
    test('G1a: a push lost while the plant is quiet is caught by the tick and '
        'healed', () async {
      final drop = _DropOneUpdate();
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        corrupt: drop.call,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      await until('the page', () => fixture.client.read(scenarioKey) != null);

      // The plant moves once and the client sees it. This frame is *not* the
      // one that is lost — losing it would be healed by the staleness frame
      // behind it, through the ordinary gap path, and the row would pass
      // against the bug. See the library doc.
      fixture.served.setValue(scenarioKey, 1300);
      await until('the change to land',
          () => fixture.client.read(scenarioKey)?.value == 1300);

      // Anti-vacuity 1: the page carried the value before anything was
      // dropped, and carried it under good quality.
      final before = fixture.client.read(scenarioKey);
      expect(before?.value, 1300,
          reason: 'the page was not holding the plant\'s value before the '
              'drop, so nothing below could show it stopped holding it');
      expect(before?.quality, Quality.good,
          reason: 'the page already carried a degraded quality before the '
              'drop, so the divergence this arm creates would be invisible: '
              'the panel would already be showing what the plant is about to '
              'say');

      // Armed synchronously, right here: the very next `u` is the one the
      // plant's freshness sweep produces, and it is the last one it will ever
      // produce for this key.
      drop.armed = true;
      final rebuiltBefore = _rebuildsServed(fixture, defaultPageSubscription);

      // Waited on the *lever*, not on the plant: the freshness sweep degrades
      // the plant's own cache and the frame that carries the degradation
      // leaves on the next tick, so a case that waited for
      // `served.read(...).quality` would run ahead of its own injection by up
      // to a tick and then accuse it of never firing.
      await until('the last frame the plant will send to be discarded',
          () => drop.discarded != null, budget: recovery);
      // Counted from the loss, not from the arming: the frame is lost when the
      // plant's freshness sweep produces it, which is a few ticks after this
      // arm asked for it, and "how long the divergence lasted" is the number
      // the row is about.
      final ticksAtDrop = _ticksSeen(fixture);
      await until('the plant to mark its own value stale',
          () => fixture.served.read(scenarioKey)?.quality == Quality.badStale,
          budget: recovery);

      // Anti-vacuity 2: the lever fired, on the frame it was aimed at.
      expect(drop.discarded, isNotNull,
          reason: 'no update frame was discarded, so this arm never induced a '
              'divergence and everything below is a statement about a healthy '
              'link');
      expect(_updateSeqOf(drop.discarded!), isNotNull,
          reason: 'the frame that was discarded carried no decodable sequence '
              'even before the corruption, so it was not the `u` this arm '
              'meant to lose');

      // The lie, printed on every run — green or red. On a red run this line
      // is the whole finding: a panel holding a number under good quality that
      // the gateway has already marked untrustworthy, while the view reports
      // fresh and the tick has been saying otherwise the entire time.
      final lastTick = fixture.seam.inbound.lastWhere(_isTickFrame);
      print('G1a: after the drop the panel holds '
          '${fixture.client.read(scenarioKey)?.value}@q'
          '${fixture.client.read(scenarioKey)?.quality.code} and the plant '
          'holds ${fixture.served.read(scenarioKey)?.value}@q'
          '${fixture.served.read(scenarioKey)?.quality.code}; the tick '
          'advertises seq ${_tickSeqOf(lastTick, defaultPageSubscription)} '
          'against an applied ${_updateSeqOf(drop.discarded!)! - 1}; '
          'viewIsStale=${fixture.client.viewIsStale}');

      // The row's own clause: within a bounded number of ticks the panel
      // agrees with the plant again, because a resync happened. Today it never
      // does — the gateway's sequence is one ahead of the client's, the tick
      // says so on every one of the next twenty, and nothing reads it.
      await until(
          'the panel to agree with the plant again',
          () =>
              fixture.client.read(scenarioKey)?.quality ==
              fixture.served.read(scenarioKey)?.quality,
          budget: recovery);
      final healedAfter = _ticksSeen(fixture) - ticksAtDrop;

      print('G1a: one `u` discarded on its way in (${drop.discarded!.length} '
          'b, seq ${_updateSeqOf(drop.discarded!)}); the panel agreed with the '
          'plant again after $healedAfter ticks; rebuilds served '
          '$rebuiltBefore -> ${_rebuildsServed(fixture, defaultPageSubscription)}');

      expect(fixture.client.read(scenarioKey)?.value,
          fixture.served.read(scenarioKey)?.value,
          reason: 'the panel and the plant disagree about the value after the '
              'recovery, so whatever healed the quality did not deliver a '
              'current reading with it');
      expect(_rebuildsServed(fixture, defaultPageSubscription),
          rebuiltBefore + 1,
          reason: 'the page was rebuilt '
              '${_rebuildsServed(fixture, defaultPageSubscription) - rebuiltBefore} '
              'times to recover one lost frame. One is the whole budget: a '
              'detector that fires on every tick until the recovery completes '
              'turns one dropped push into a rebuild storm, which is the '
              'denial of service arms C and D exist to forbid');
    });

    test('G1b: an update naming a handle the session never announced is a '
        'resync, not a shrug', () async {
      final misfile = _MisfileOneHandle(_secondKey);
      final fixture = await faultFixture(
        keys: const {scenarioKey, _secondKey},
        corrupt: misfile.call,
        seed: (plant) {
          plant.setValue(scenarioKey, 1200);
          plant.setValue(_secondKey, 2400);
        },
      );
      await until('the link', () => fixture.client.isReady);
      await until(
          'the page',
          () =>
              fixture.client.read(scenarioKey) != null &&
              fixture.client.read(_secondKey) != null);

      fixture.served.setValue(scenarioKey, 1300);
      fixture.served.setValue(_secondKey, 2500);
      await until(
          'both changes to land',
          () =>
              fixture.client.read(scenarioKey)?.value == 1300 &&
              fixture.client.read(_secondKey)?.value == 2500);

      // Anti-vacuity 1: both keys were current and good before the misfile, so
      // the divergence below is one this arm created.
      expect(fixture.client.read(_secondKey)?.quality, Quality.good,
          reason: 'the misfiled key was already carrying a degraded quality, '
              'so the frame this arm is about to misfile would tell the panel '
              'nothing it did not already believe');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the client had already complained before the unannounced '
              'handle was injected: ${fixture.client.complaints}. The '
              'complaint count below is the evidence that the frame arrived '
              'and was understood, so it has to start at zero');

      misfile.armed = true;
      final rebuiltBefore = _rebuildsServed(fixture, defaultPageSubscription);

      // The lever first, then the plant — see arm A: the sweep degrades the
      // plant's cache a tick before the frame carrying it reaches the seam.
      await until('the last frame the plant will send to be misfiled',
          () => misfile.misfiled != null, budget: recovery);
      final ticksAtMisfile = _ticksSeen(fixture);
      await until('the plant to mark its own values stale',
          () => fixture.served.read(_secondKey)?.quality == Quality.badStale,
          budget: recovery);

      // Anti-vacuity 2: the lever fired on a frame that carried both keys, so
      // the batch really did hold a legitimate change beside the unannounced
      // handle. Without this the arm could be judging a frame that named
      // nothing else.
      expect(misfile.misfiled, isNotNull,
          reason: 'no update frame was misfiled, so no unannounced handle ever '
              'reached the client and this arm has not run its own scenario');
      final changes = _paramsOf(misfile.misfiled!)?['c'];
      expect(changes, isA<Map<String, Object?>>().having(
              (map) => map.length, 'handles in the misfiled batch', 2),
          reason: 'the misfiled frame carried $changes, so it did not hold a '
              'legitimate change beside the unannounced one and the "the rest '
              'of the batch is still applied" half of this row is untested');

      // The legitimate half of the batch was applied and the complaint was
      // recorded: the client understood the frame, filed what it could, and
      // said out loud what it could not.
      await until(
          'the legitimate half of the batch',
          () => fixture.client.read(scenarioKey)?.quality == Quality.badStale,
          budget: recovery);
      expect(
          fixture.client.complaints
              .where((line) => line.contains('$_unannouncedHandle'))
              .length,
          1,
          reason: 'the client recorded '
              '${fixture.client.complaints} for one unannounced handle. The '
              'complaint is diagnostic and somebody reads it, so the resync '
              'this row asks for is in addition to it and never instead of it');

      // The lie, printed on every run. The second number is what makes this a
      // second row rather than a second symptom of the first: the sequence the
      // tick advertises is the one the client has applied, so arm A's detector
      // has nothing to see here and never will.
      final lastTick = fixture.seam.inbound.lastWhere(_isTickFrame);
      print('G1b: after the misfile the panel holds '
          '${fixture.client.read(_secondKey)?.value}@q'
          '${fixture.client.read(_secondKey)?.quality.code} and the plant '
          'holds ${fixture.served.read(_secondKey)?.value}@q'
          '${fixture.served.read(_secondKey)?.quality.code}; the tick '
          'advertises seq ${_tickSeqOf(lastTick, defaultPageSubscription)} '
          'against an applied ${_updateSeqOf(misfile.misfiled!)} — in '
          'agreement, which is why the tick cannot see this one');

      // The row's clause. Today the sequence advanced over a cache that lost a
      // value, so arm A's tick detector agrees with the client to the number
      // and nothing ever heals: the panel holds a value under good quality
      // that the gateway marked untrustworthy, for as long as the plant stays
      // quiet.
      await until(
          'the misfiled key to agree with the plant again',
          () =>
              fixture.client.read(_secondKey)?.quality ==
              fixture.served.read(_secondKey)?.quality,
          budget: recovery);
      final healedAfter = _ticksSeen(fixture) - ticksAtMisfile;
      final rebuilt =
          _rebuildsServed(fixture, defaultPageSubscription) - rebuiltBefore;

      print('G1b: one change re-filed under handle $_unannouncedHandle; the '
          'batch\'s other change was applied and one complaint recorded; the '
          'misfiled key agreed with the plant again after $healedAfter ticks; '
          '$rebuilt rebuilds served');

      expect(fixture.client.read(_secondKey)?.value,
          fixture.served.read(_secondKey)?.value,
          reason: 'the panel and the plant disagree about the misfiled key\'s '
              'value, so the recovery did not deliver a current reading');
      expect(rebuilt, 1,
          reason: 'the gateway rebuilt the page $rebuilt times for one batch '
              'naming one unannounced handle. One batch is one resync however '
              'many handles in it were strangers');
    });

    test('G1c: a quiet healthy link costs no rebuilds at all', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      await until('the page', () => fixture.client.read(scenarioKey) != null);

      // From here the plant is not touched. Its freshness sweep degrades the
      // seeded value once, ~300 ms in, and after that there is nothing left to
      // send: this is the "quiet plant" the row's own injection asks for, and
      // a detector that reads silence as loss fires here.
      final rebuiltBefore = _rebuildsServed(fixture, defaultPageSubscription);
      final answersBefore =
          fixture.seam.inbound.where(_isSnapshotAnswer).length;
      final ticksBefore = _ticksSeen(fixture);
      await _awaitTicks(fixture, ticksBefore, _controlTicks);

      final ticks = _ticksSeen(fixture) - ticksBefore;
      final rebuilt =
          _rebuildsServed(fixture, defaultPageSubscription) - rebuiltBefore;
      final answers =
          fixture.seam.inbound.where(_isSnapshotAnswer).length - answersBefore;
      print('G1c: $ticks ticks over a quiet healthy link; $rebuilt rebuilds '
          'served, $answers snapshot answers on the wire; complaints '
          '${fixture.client.complaints.length}');

      expect(ticks, greaterThanOrEqualTo(_controlTicks),
          reason: 'only $ticks ticks arrived, so the absence below was watched '
              'over a window too short to mean anything');
      expect(rebuilt, 0,
          reason: 'the gateway rebuilt the page $rebuilt times across $ticks '
              'ticks of a link with nothing wrong with it. A plant that is '
              'simply not moving must cost zero resyncs — a detector that '
              'reads quiet as loss is worse than the divergence it fixes, '
              'because it turns every idle panel in the factory into a rebuild '
              'per tick against the one process serving all of them');
      expect(answers, 0,
          reason: 'the gateway served no rebuild and the client still saw '
              '$answers snapshot answers, so something re-subscribed without '
              'the registry counting it and the count above is not measuring '
              'what it claims to');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the client complained over a healthy quiet link: '
              '${fixture.client.complaints}');
    });

    test('G1d: a busy healthy link costs no rebuilds either', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      await until('the page', () => fixture.client.read(scenarioKey) != null);

      final rebuiltBefore = _rebuildsServed(fixture, defaultPageSubscription);
      final answersBefore =
          fixture.seam.inbound.where(_isSnapshotAnswer).length;
      final ticksBefore = _ticksSeen(fixture);

      // A push under most ticks. This is the arm that catches an off-by-one
      // between the gateway's *last emitted* sequence and the client's *last
      // applied* one: the two are equal on a healthy link only because the
      // update is written to the socket before the tick that advertises it
      // (`tick_engine.dart`: `_fanOut` then `_writeTick`, same drain), and a
      // detector that compared them the wrong way round would fire on every
      // single one of these.
      var value = 1200;
      while (_ticksSeen(fixture) - ticksBefore < _controlTicks) {
        fixture.served.setValue(scenarioKey, ++value);
        await Future<void>.delayed(_busyInterval);
      }
      await until('the last change to land',
          () => fixture.client.read(scenarioKey)?.value == value,
          budget: recovery);

      final ticks = _ticksSeen(fixture) - ticksBefore;
      final pushes = fixture.seam.inbound.where(_isUpdateFrame).length;
      final rebuilt =
          _rebuildsServed(fixture, defaultPageSubscription) - rebuiltBefore;
      final answers =
          fixture.seam.inbound.where(_isSnapshotAnswer).length - answersBefore;
      print('G1d: $ticks ticks over a busy healthy link, $pushes update frames '
          'delivered; $rebuilt rebuilds served, $answers snapshot answers on '
          'the wire');

      expect(ticks, greaterThanOrEqualTo(_controlTicks),
          reason: 'only $ticks ticks arrived, so the absence below was watched '
              'over a window too short to mean anything');
      expect(pushes, greaterThan(_controlTicks ~/ 2),
          reason: 'only $pushes update frames were delivered across $ticks '
              'ticks, so this arm is a second copy of the quiet one and the '
              'off-by-one it exists to catch never had a chance to fire');
      expect(rebuilt, 0,
          reason: 'the gateway rebuilt the page $rebuilt times across $ticks '
              'ticks of a busy link with nothing wrong with it. This is the '
              'most likely way the tick-sequence comparison goes wrong: the '
              'gateway advertises its *last emitted* sequence and the client '
              'holds its *last applied* one, and a comparison off by one fires '
              'on every push a healthy plant makes');
      expect(answers, 0,
          reason: 'the client saw $answers snapshot answers while the gateway '
              'counted no rebuild, so the two readings disagree');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the client complained over a healthy busy link: '
              '${fixture.client.complaints}');
    });

    test('the tick advertises the sequence the client has applied, on every '
        'tick of a healthy link', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      await until('the page', () => fixture.client.read(scenarioKey) != null);

      var value = 1200;
      final ticksBefore = _ticksSeen(fixture);
      while (_ticksSeen(fixture) - ticksBefore < _controlTicks) {
        fixture.served.setValue(scenarioKey, ++value);
        await Future<void>.delayed(_busyInterval);
      }

      // Walked in wire order, which is the order the client processed them in:
      // one subscription's frames arrive on one socket and `Peer` reads them
      // in sequence. `applied` is what the client's `SubscriptionState.lastSeq`
      // must be holding at the instant each tick is handled — the sequence of
      // the last frame it was handed — and the client publishes no getter for
      // the real one, so this is a reconstruction and says so.
      int? applied;
      final rows = <String>[];
      final disagreements = <String>[];
      for (final frame in fixture.seam.inbound) {
        if (_isSnapshotAnswer(frame)) {
          final seq = jsonDecode(frame) as Map<String, Object?>;
          final result = (seq['result']! as Map).cast<String, Object?>();
          applied = (result['seq']! as num).toInt();
          continue;
        }
        if (_isUpdateFrame(frame)) {
          applied = _updateSeqOf(frame) ?? applied;
          continue;
        }
        if (!_isTickFrame(frame)) continue;
        final advertised = _tickSeqOf(frame, defaultPageSubscription);
        if (advertised == null || applied == null) continue;
        rows.add('tick ${rows.length + 1}: advertised $advertised, applied '
            '$applied');
        if (advertised != applied) {
          disagreements.add(rows.last);
        }
      }

      print('the tick\'s seq against the client\'s last applied sequence, '
          '${rows.length} ticks of a busy healthy link:');
      for (final row in rows) {
        print('  $row');
      }

      expect(rows.length, greaterThanOrEqualTo(_controlTicks),
          reason: 'only ${rows.length} ticks named this subscription, so the '
              'agreement below was measured over too few to be a measurement. '
              'The whole fix in `_tick` rests on this relationship, and 07-07 '
              'is required to measure it rather than read it off the source');
      expect(disagreements, isEmpty,
          reason: 'the gateway advertised a sequence the client had not '
              'applied on these ticks: $disagreements. On a healthy link the '
              'two are equal because the update frame is written to the socket '
              'before the tick that advertises it — `_fanOut` runs before '
              '`_writeTick` in the same drain (`tick_engine.dart`), and '
              '`nextSeq()` is called only when a frame is actually emitted '
              '(deferred pushes are re-buffered, not numbered). If they '
              'disagree here, the comparison `_tick` makes is not the one this '
              'plan measured and the fix has the wrong shape');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the client complained during the measurement: '
              '${fixture.client.complaints}. A complaint means a frame was '
              'refused rather than applied, and the reconstruction above '
              'assumes every delivered frame was applied');
    });
  });
}
