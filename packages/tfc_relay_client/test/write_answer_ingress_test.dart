/// S8: the write RPC's answer is the one ingress this client does not sanitize.
///
/// Every other frame that reaches `RemoteStateMan` from the wire crosses
/// [sanitize] on the way in — the hello result, `u`, `tick`, `resync`, `status`
/// and the preference notifications all decode through
/// `_asJson(sanitize(...).value)` in `connection_supervisor.dart`. The direct
/// write answer does not: it decodes straight out of `_asJson(raw)`. So the one
/// message an operator's finger is waiting on is the one message this client
/// takes at face value.
///
/// **Two shapes get through, and the *second* one is worse.**
///
/// `"at": 1e999` decodes to `Infinity` — `jsonDecode` produces it silently,
/// which is the whole reason F28's sanitization exists — and
/// `WriteResult.fromJson`'s `at is num` guard admits it, because `Infinity` is
/// a `num`. `at.toInt()` then throws `UnsupportedError`. That throw happens
/// inside `_write`'s try, so it reaches the taxonomy — which rethrows every
/// `Error` on purpose, because a defect in this process must never be reported
/// to an operator as a condition of the plant. The result is that `write()`
/// **throws** where it promised a three-state outcome.
///
/// `"at": 1e17` is finite, so nothing refuses it. The outcome is built, the
/// command is struck from the unresolved set as settled — and *then*
/// `_adoptReadback` calls `DateTime.fromMillisecondsSinceEpoch` on it, outside
/// the try, and throws `RangeError`. The operator is shown an error for a write
/// that **landed and was read back**, and the command is no longer in the set
/// `writeStatus` re-queries, so nothing will ever tell them otherwise. An
/// operator shown a failure for a write that succeeded is an invitation to
/// re-actuate, and re-actuating is the one thing this whole system is built to
/// stop happening by accident.
///
/// **Neither is hypothetical arithmetic.** `1e17` ms is what a device with an
/// unset RTC or a microsecond/millisecond unit confusion reports; `1e999` is
/// the JSON poison this project has already been bitten by twice
/// (`dynamic_value.dart:343-348` guards `isFinite` before `toInt` for exactly
/// this reason, on the value path). The write path is the last one without the
/// guard.
///
/// **What the fix is not allowed to do.** It must not collapse `unknown` into
/// `failed`: an answer whose stamp cannot be read is not proof the write did
/// not happen, and the command has to stay re-queryable. And it must not
/// downgrade an outcome the gateway *did* establish — an `applied` answer with
/// an unusable audit stamp is still an applied write, and reporting it unknown
/// sends a fitter across the factory for a valve that moved.
@TestOn('vm')
@Tags(['faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fault_fixture.dart';
import 'support/gate_bands.dart';
import 'support/write_answer_restamp.dart';

/// The tag the writes go to.
const String _key = scenarioKey;

/// What the plant holds before the write, and what the operator commands.
const int _before = 1200;
const int _commanded = 1500;

/// The JSON poison: a literal `jsonDecode` turns into `Infinity` without a
/// word, and which nothing in this process could ever *encode*.
const String _infinite = '1e999';

/// A finite stamp outside the range `DateTime` can represent.
///
/// `DateTime.fromMillisecondsSinceEpoch` accepts ±8 640 000 000 000 000 ms and
/// throws outside it. This is eleven times that, spelled as an integer literal
/// so the wire carries an ordinary JSON number and every guard that looks for a
/// non-finite one waves it through — which is the reason this arm exists beside
/// the one above rather than being folded into it.
const String _outOfRange = '100000000000000000';

/// One write, run to whatever conclusion it reaches: an outcome, a throw, or a
/// deadline.
///
/// A record rather than a bare await, for `truncated_write_test.dart`'s reason:
/// letting a throw escape into a `throwsA` matcher reports this file's name
/// rather than the write an operator lost, and a `completes` matcher lets a
/// deadline escape as a raw `TimeoutException`.
typedef Attempt = ({WriteResult? outcome, Object? thrown, DynamicValue? page});

Future<Attempt> _attempt(FaultFixture fixture, String cmd) async {
  try {
    final outcome =
        await fixture.client.write(_key, _commanded, cmd: cmd).timeout(recovery);
    // Read in the microtask the write resolved in, before any socket event can
    // be delivered — `write_readback_freshness_test.dart` argues the ordering.
    return (outcome: outcome, thrown: null, page: fixture.client.read(_key));
  } catch (error) {
    return (outcome: null, thrown: error, page: fixture.client.read(_key));
  }
}

void main() {
  group('S8 — a hostile stamp on a write answer', () {
    test('an infinite `at` resolves the write as unknown instead of throwing',
        () async {
      final fixture = await faultFixture(
        keys: const {_key},
        corrupt: restampAppliedWriteAnswer(_infinite),
        seed: (plant) => plant.setValue(_key, _before),
      );
      await until('the link', () => fixture.client.isReady);

      final cmd = newUlid();
      final attempt = await _attempt(fixture, cmd);
      print('S8 infinite: outcome ${attempt.outcome}, threw ${attempt.thrown}, '
          'unresolved ${fixture.client.debugUnresolvedCmds}, plant attempts '
          '${fixture.served.upstreamWriteAttempts(cmd)}');

      // ANTI-VACUITY: the poison reached the decoder. An injector that matched
      // nothing is the vacuous pass every fault test is one typo away from.
      expect(
          fixture.seam.inbound.any((frame) => frame.contains('"at":$_infinite')),
          isTrue,
          reason: 'no inbound frame carries the infinite stamp, so the client '
              'decoded the gateway\'s own well-formed answer and this case '
              'measured an ordinary applied write. Inbound so far: '
              '${fixture.seam.inbound}');
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'the plant recorded '
              '${fixture.served.upstreamWriteAttempts(cmd)} attempts for this '
              'command. The corruption is on the *answer* only — the request '
              'arrives whole — so zero would mean the fixture broke the '
              'request instead, and the dangerous asymmetry this case is about '
              '(the plant moved; the panel cannot read the receipt) would not '
              'exist');

      expect(attempt.thrown, isNull,
          reason: 'write() threw ${attempt.thrown} instead of resolving. '
              '`Infinity.toInt()` is an `UnsupportedError`, the taxonomy '
              'rethrows every `Error` on purpose, and so a gateway — or '
              'anything on the path with a JSON writer that spells overflow as '
              '`1e999` — can make this client break its one unbreakable '
              'promise: a write reports its outcome as a value, never as an '
              'exception. The operator gets a red box with a Dart type in it '
              'for a write that reached the plant');
      expect(attempt.outcome, isA<WriteUnknown>(),
          reason: 'the write resolved ${attempt.outcome}. The gateway said '
              '"applied" and then named an instant that is not one, so what '
              'came back is half an audit record — which `WriteResult.fromJson` '
              'already treats as no proof of application at all. Unknown is the '
              'honest verdict and it is the only one that keeps the command '
              're-queryable');
      expect(attempt.outcome, isNot(isA<WriteNotReceived>()),
          reason: 'the write resolved ${attempt.outcome}: "never received" is '
              'the single verdict in this system that tells an operator a '
              're-send is safe, and the plant took this write. Reaching it from '
              'a stamp nobody could read would move a machine twice');
      expect(fixture.client.debugUnresolvedCmds, contains(cmd),
          reason: 'the command left the unresolved set with an unknown '
              'outcome, so no reconnect will ever ask the gateway what became '
              'of it. Unknown is the one verdict that must not settle — that '
              'is what makes the writeStatus recovery reachable at all, and '
              'without it the operator who was told "unknown" is never told '
              'anything else');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the panel put ${fixture.client.debugWritesSent} writes on '
              'the wire for one an operator issued. An unreadable answer is '
              'never grounds to repeat an actuation');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
        'an `at` outside DateTime\'s range does not throw a settled outcome '
        'away', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        corrupt: restampAppliedWriteAnswer(_outOfRange),
        seed: (plant) => plant.setValue(_key, _before),
      );
      await until('the link', () => fixture.client.isReady);

      final cmd = newUlid();
      final attempt = await _attempt(fixture, cmd);
      print('S8 out-of-range: outcome ${attempt.outcome}, threw '
          '${attempt.thrown}, page on resolution ${attempt.page?.value} at '
          '${attempt.page?.sourceTime}, unresolved '
          '${fixture.client.debugUnresolvedCmds}, complaints '
          '${fixture.client.complaints}');

      expect(
          fixture.seam.inbound
              .any((frame) => frame.contains('"at":$_outOfRange')),
          isTrue,
          reason: 'no inbound frame carries the out-of-range stamp, so this '
              'case measured an ordinary applied write. Inbound so far: '
              '${fixture.seam.inbound}');
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'the plant recorded '
              '${fixture.served.upstreamWriteAttempts(cmd)} attempts for this '
              'command, so the write this case says "landed" did not land and '
              'nothing below is about the shape it names');

      expect(attempt.thrown, isNull,
          reason: 'write() threw ${attempt.thrown}. This is the worse of the '
              'two shapes: the stamp is *finite*, so every non-finite guard '
              'waves it through, the outcome is built, the command is struck '
              'from the unresolved set as settled — and only then does '
              '`_adoptReadback` call DateTime.fromMillisecondsSinceEpoch on it, '
              'outside the try. The operator is shown an error for a write that '
              'landed and was read back, about a command nothing will ever '
              're-query. That is an invitation to press the button again');
      expect(attempt.outcome, isA<WriteApplied>(),
          reason: 'the write resolved ${attempt.outcome}. The gateway '
              'established `applied` and named the readback the device '
              'reported holding — that is the confirmation, and it is intact. '
              'Refusing to *stamp the store* with an instant this panel cannot '
              'represent is not grounds to unsay the outcome: reporting '
              'unknown here sends a fitter out to look at a machine that '
              'already reported back, which is how a plant learns to ignore '
              'the word');
      expect(fixture.client.debugUnresolvedCmds, isNot(contains(cmd)),
          reason: 'an established `applied` outcome left the command in the '
              'unresolved set: ${fixture.client.debugUnresolvedCmds}. Every '
              'reconnect for the rest of the shift will re-query a command '
              'that has an answer, and the set is what `writeStatus` is '
              'refused for overrunning');
      expect(attempt.page?.sourceTime?.year ?? 0, lessThan(10000),
          reason: 'the page carries source time ${attempt.page?.sourceTime} '
              'the instant the write resolved. A stamp a quarter of a million '
              'years in the future makes every freshness comparison '
              'downstream of it answer "brand new" for ever, which is the one '
              'answer that must never be reachable by accident: a value that '
              'can never go stale is a dead tag nobody will be warned about');
      expect(fixture.client.complaints, isNotEmpty,
          reason: 'the client refused the stamp and said nothing about it. A '
              'gateway sending unrepresentable instants is a configuration '
              'fault somebody has to be able to find, and the panel that saw '
              'it is the only witness');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
