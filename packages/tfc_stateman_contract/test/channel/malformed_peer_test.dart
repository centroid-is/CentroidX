/// Every corruption in the catalogue, applied to a real `json_rpc_2` peer, and
/// asserted against the outcome RESEARCH *measured* rather than the outcome
/// intuition predicts.
///
/// The measurement is the whole point of this file. Nine of the thirteen
/// entries leave the pending request unsettled forever and four resolve, and
/// which is which is not inferable from the corruption: a `result` typed as a
/// String resolves, while an `id` typed as a Map hangs; `1e999` resolves (as
/// `Infinity`, in application code); an 8 MiB frame resolves in full. A
/// catalogue whose entries were only described would be a catalogue every
/// reader had to re-derive, and the derivation is wrong.
///
/// Two rules the assertions follow, both from `lib/src/meta.dart:60-79`:
///
///  * **Never a throws-matcher.** The Peer does not throw on a malformed
///    response — it replies `-32700` to the sender and carries on with the
///    client half never told anything failed (RESEARCH Finding 15). A matcher
///    that waited for a throw would hang for the runner's thirty seconds and
///    then report this file's name instead of the property. That absence is
///    grep-enforced, which is why the matcher is not named even in prose here.
///    The hang is asserted by converting a deadline
///    into a plain bool and asserting on the bool, which does produce a
///    `TestFailure` carrying its reason.
///  * **Every budget is short and named**, so silence fails fast. Nine hang
///    cases in one file is only affordable because each of them costs its
///    budget and not the runner's timeout, and the file's own runtime is
///    asserted at the end as evidence that they do.
///
/// Every case also asserts the two things that make the failure *quiet* rather
/// than loud: the Peer is still open afterwards, and a subsequent valid request
/// still gets an answer. A malformed frame does not take the link down. It
/// takes one request down, invisibly, and leaves the link looking healthy.
@Tags(['meta'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';

/// The default per-request deadline. Deliberately short: a hang case costs
/// exactly this, and nine of them have to fit inside [_fileBudget].
const _budget = Duration(milliseconds: 250);

/// The oversize entry moves 8 MiB through an encode, a channel and a decode.
/// It resolves — that is the finding — but not in 250 ms on a loaded machine.
const _oversizeBudget = Duration(seconds: 10);

/// Bounds the whole file. Nine hang cases must still cost seconds, not the
/// runner's timeout.
const _fileBudget = Duration(seconds: 30);

/// The result the server hands back when nothing has been corrupted, shaped
/// like a `WriteResult` so the corruptions land on a realistic message.
const _cleanResult = <String, Object?>{'cmd': 'w1', 'outcome': 'applied'};

/// What each catalogue entry was measured to do, keyed the same way the
/// catalogue is. Held separately from the catalogue on purpose: the assertion
/// that the two key sets are identical, in both directions, is what stops a
/// new corruption from being added without a proof.
final _expectations = <String, _Expected>{
  'truncateTail': _Expected.unsettled(
    'a frame cut short by a killed process',
  ),
  'truncateHalf': _Expected.unsettled(
    'a frame cut in the middle by a socket that went away mid-write',
  ),
  'truncateToFirstCharacter': _Expected.unsettled(
    'a frame that is nothing but its opening brace',
  ),
  'garbage': _Expected.unsettled(
    'a proxy or captive portal that answered with something that is not JSON',
  ),
  'empty': _Expected.unsettled('a zero-length frame'),
  'duplicate': _Expected.unsettled(
    'two documents concatenated by a framing bug',
  ),
  'dropJsonrpc': _Expected.unsettled(
    'a peer that omits the envelope version, which strict checks reject',
  ),
  'retypeId': _Expected.unsettled('an id that is a Map instead of a scalar'),
  'rewriteId': _Expected.unsettled('an answer to a request nobody is waiting for'),
  'retypeResult': _Expected.resolves(
    'there is no type check on result — a String arrives where a Map was '
        'expected and the caller casts it',
    (raw) => expect(
      raw,
      'oops',
      reason: 'the envelope was measured to pass a wrongly-typed result '
          'straight through (Finding 15). If this now fails, json_rpc_2 has '
          'started type-checking and the decode-boundary defences downstream '
          'can be re-scoped',
    ),
  ),
  'poisonNumber': _Expected.resolves(
    '1e999 reaches application code as Infinity, undefused by the envelope',
    (raw) {
      final value = (raw! as Map<String, Object?>)[poisonedKey];
      expect(value, isA<double>(),
          reason: 'the poisoned field decoded as ${value.runtimeType}');
      expect(
        (value! as double).isInfinite,
        isTrue,
        reason: 'a PLC value that overflowed a double arrived as $value '
            'instead of Infinity. The envelope does not defuse it — '
            'sanitize() on the decode path is the only defence, and this is '
            'the assertion that holds that in place (T-02-28)',
      );
    },
  ),
  'oversize': _Expected.resolves(
    'there is no frame-size limit — 8 MiB arrives whole',
    (raw) {
      final pad = (raw! as Map<String, Object?>)[padKey];
      expect(pad, isA<String>());
      expect(
        (pad! as String).length,
        greaterThanOrEqualTo(oversizeBytes ~/ 2),
        reason: 'the 8 MiB frame did not arrive whole. If a frame-size limit '
            'has appeared, T-02-29 changes shape: Phase 3 would no longer be '
            'the only place a cap can live',
      );
    },
    budget: _oversizeBudget,
  ),
  'unpairedSurrogate': _Expected.resolves(
    'a lone \\ud800 survives the message layer and becomes U+FFFD on a socket '
        '— it does not throw at either point',
    (raw) {
      final value = (raw! as Map<String, Object?>)[loneSurrogateKey]! as String;
      // Finding 15's row says "silently replaced with U+FFFD". Measured here,
      // over a String channel, the replacement has not happened yet: the lone
      // high surrogate arrives intact as one UTF-16 code unit, because nothing
      // between the two peers ever encoded it to bytes. That is a refinement
      // of the row rather than a contradiction of it — and it matters, because
      // the message layer and the byte layer therefore hand application code
      // two different strings for the same frame.
      expect(
        value.codeUnits,
        [0xD800],
        reason: 'the message layer was measured to pass an unpaired surrogate '
            'through intact. If it now raises, a mangled string has turned '
            'into a dropped frame, which is a different fault with a '
            'different defence',
      );
      // And what the byte layer does with the same value, which is the half
      // Finding 15 measured: U+FFFD, silently, still without raising.
      expect(
        utf8.decode(utf8.encode(value)),
        '\u{FFFD}',
        reason: 'a socket-backed peer was measured to deliver the replacement '
            'character. If UTF-8 encoding started throwing on a lone '
            'surrogate, one bad string would take down the frame it shares '
            'with every other message on that connection',
      );
    },
  ),
};

void main() {
  final wall = Stopwatch()..start();
  final ran = <String>{};

  group('the catalogue reaches the peer as measured', () {
    for (final entry in malformedPeerCatalogue.entries) {
      final expected = _expectations[entry.key];
      if (expected == null) continue; // the pairing test below reports this.

      test('${entry.key}: ${expected.because}', () async {
        ran.add(entry.key);
        final attempt = await _attempt(entry.value, budget: expected.budget);

        if (expected.check == null) {
          expect(
            attempt.settled,
            isFalse,
            reason: 'the request SETTLED. Finding 15 measured this corruption '
                'as leaving it unsettled forever, and every downstream '
                'defence — Phase 4\'s per-request deadline above all — is '
                'scoped on that. If json_rpc_2 has started failing pending '
                'requests on a malformed response, that scope is now wrong '
                'and cheaper than assumed. Resolved with ${attempt.resolved}, '
                'failed with ${attempt.failure}',
          );
        } else {
          expect(
            attempt.settled,
            isTrue,
            reason: 'the request did not settle inside ${expected.budget}. '
                'This corruption was measured to resolve; a hang here means '
                'the entry no longer produces the message it claims to',
          );
          expect(attempt.failure, isNull,
              reason: 'the request failed with ${attempt.failure} instead of '
                  'resolving');
          expected.check!(attempt.resolved);
        }

        // The two properties that make a malformed frame quiet rather than
        // loud, asserted for every entry including the ones that resolve.
        expect(attempt.peerOpen, isTrue,
            reason: 'the peer closed. A closed peer is an event a client can '
                'notice and report — the fault this catalogue exists to model '
                'is the one that leaves the link looking healthy');
        expect(attempt.laterAnswer, 'pong',
            reason: 'a valid request sent after the corruption went '
                'unanswered (got ${attempt.laterAnswer}). If a malformed '
                'frame took the whole session down, the hazard would be '
                'visible; it is invisible precisely because everything else '
                'keeps working');
      });
    }
  });

  test('the catalogue and its proofs name the same corruptions', () {
    expect(
      _expectations.keys.toSet(),
      malformedPeerCatalogue.keys.toSet(),
      reason: 'a corruption exists without a measured outcome, or an outcome '
          'without a corruption. The catalogue is only worth having because '
          'every entry carries a proof of what it actually does',
    );
    expect(
      malformedPeerCatalogue.length,
      greaterThanOrEqualTo(10),
      reason: 'RESEARCH prescribes ten message-layer corruptions; the '
          'catalogue has ${malformedPeerCatalogue.length}',
    );
    expect(
      ran,
      malformedPeerCatalogue.keys.toSet(),
      reason: 'a catalogue entry was registered but never exercised. This is '
          'the direction a loop over a registry silently loses: the entry is '
          'present, the suite is green, and nothing ran',
    );
  });

  test('the whole catalogue costs less than its budget', () {
    print('the malformed-peer catalogue ran in '
        '${wall.elapsed.inMilliseconds} ms '
        '(budget ${_fileBudget.inSeconds} s, '
        '${malformedPeerCatalogue.length} corruptions)');
    expect(
      wall.elapsed,
      lessThan(_fileBudget),
      reason: 'nine of these cases are hangs, and they are only affordable '
          'because each costs its own named budget. If this file starts '
          'costing tens of seconds, an assertion has stopped bounding its '
          'await and is being failed by the runner instead — which reports a '
          'file name rather than the corruption that broke',
    );
  });
}

/// What one corruption did: whether the request settled, what came back, and
/// whether the session survived it.
final class _Attempt {
  _Attempt({
    required this.settled,
    required this.resolved,
    required this.failure,
    required this.peerOpen,
    required this.laterAnswer,
  });

  final bool settled;
  final Object? resolved;
  final Object? failure;
  final bool peerOpen;
  final Object? laterAnswer;
}

/// Sends one request over a channel whose first response is corrupted, then
/// asks the same peer a second, uncorrupted question.
///
/// [onFirstMatching] with [isResponse] is what keeps the corruption surgical:
/// exactly one message is damaged, so the follow-up `ping` measures the
/// session's health rather than a second dose of the fault.
Future<_Attempt> _attempt(
  MessageCorruption corruption, {
  required Duration budget,
}) async {
  final pair = channelPair(
    corruptServerToClient: onFirstMatching(isResponse, corruption),
  );

  final server = rpc.Peer(pair.server)
    ..registerMethod('write', (rpc.Parameters _) => _cleanResult)
    ..registerMethod('ping', (rpc.Parameters _) => 'pong');
  final client = rpc.Peer(pair.client);
  unawaited(server.listen());
  unawaited(client.listen());
  addTearDown(() async {
    await client.close();
    await server.close();
  });

  var settled = true;
  Object? resolved;
  Object? failure;
  // Neither a completes-matcher nor a throws-matcher: neither converts a
  // never-settling future into a TestFailure, so the hang cases — which are
  // most of this catalogue — would escape as raw TimeoutExceptions naming
  // nothing. meta.dart:60-79, polarity inverted.
  await client
      .sendRequest('write', {'key': 'k'})
      .then<Object?>(
        (value) => resolved = value,
        onError: (Object error) => failure = error,
      )
      .timeout(budget, onTimeout: () {
        settled = false;
        return null;
      });

  Object? laterAnswer;
  await client
      .sendRequest('ping')
      .then<Object?>(
        (value) => laterAnswer = value,
        onError: (Object error) => laterAnswer = error,
      )
      .timeout(budget, onTimeout: () => laterAnswer = 'never answered');

  return _Attempt(
    settled: settled,
    resolved: resolved,
    failure: failure,
    peerOpen: !client.isClosed,
    laterAnswer: laterAnswer,
  );
}

/// One entry's measured outcome: either it never settles, or it resolves into
/// something this function asserts.
final class _Expected {
  const _Expected.unsettled(this.because)
      : check = null,
        budget = _budget;

  const _Expected.resolves(
    this.because,
    this.check, {
    this.budget = _budget,
  });

  /// The half-sentence that becomes the test's name.
  final String because;

  /// Null means the request was measured never to settle.
  final void Function(Object? resolved)? check;

  final Duration budget;
}
