/// `MalformedPeer` pointed at `RemoteStateMan`: the failures a close cannot
/// catch, and the deadline that is the only thing standing between them and a
/// panel stuck on a spinner.
///
/// **The load-bearing case is the mismatched id.** 04-RESEARCH Finding 1 drove
/// four experiments against `json_rpc_2` 4.1.0 and three of them end in a
/// `StateError` the client can classify. The fourth does not end at all:
///
/// > Response arrives carrying a **different id** → **never settles — still
/// > pending after 400 ms** (eternal hang).
///
/// A closed transport *does* fail its in-flight requests — the library tracks
/// them and completes them on close — so the deadline is not a second line of
/// defence against link loss. What the library cannot notice is that a
/// well-formed response for someone else's id was not the response to this
/// one. That is `malformed_peer.dart`'s `rewriteId`, it is what a reconnect
/// replaying a queue produces, and it is the failure the whole of
/// `deadline.dart` exists for. This file is where that claim is cashed against
/// a real socket instead of a channel.
///
/// **Nine of the thirteen catalogue entries hang and four resolve, and which is
/// which is not inferable** (Finding 15, and `malformed_peer_test.dart` proves
/// every row at the channel layer). This file does not re-prove the catalogue;
/// it takes one entry from each *class* — an answer to nobody, a frame cut
/// short, and a payload of the wrong type — and asserts what the panel does
/// with it. Two of the three hang at the envelope and are ended by the
/// deadline; the third resolves and is caught by the decode boundary. Both
/// outcomes are honest and neither is a hang.
///
/// **Every case also asserts the session survived.** A malformed frame does not
/// take the link down. It takes one request down and leaves the link looking
/// healthy — which is what makes it worth a file: the operator sees a page that
/// is connected, values that are updating, and one control that never answers.
/// The corruptions are all composed with `onFirstMatching`, so exactly one
/// message is damaged and the follow-up question is a real one.
///
/// **No matcher waits for a throw here, and none waits for completion.** Both
/// let a deadline escape as a raw `TimeoutException`, which reports this file's
/// name instead of the property; the rule is `meta.dart:60-79`'s and it is
/// grep-enforced. A call that may not answer is awaited through `within`, which
/// turns silence into a named failure, and its outcome is inspected as data.
@TestOn('vm')
@Tags(['contract', 'faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../support/fault_fixture.dart';

/// The key every case reads and writes. Seeded before the gateway starts, so
/// it is in the address space by the time the client subscribes.
const _key = 'ST101.CN01.MOT01.setpoint';

/// The deadline the client under test is given.
///
/// Short and greppable, for `client_config.dart`'s reason: the lowered floor is
/// what makes a hang assertable inside a case's own budget rather than at the
/// runner's timeout.
const _deadline = Duration(milliseconds: 400);

/// How long a call gets before this file calls it unanswered.
///
/// Comfortably above [_deadline] plus a round trip, so a case that fails here
/// is reporting a deadline that did not fire rather than a slow machine.
const _budget = Duration(seconds: 3);

/// The marker that picks out a `readFresh` answer on the wire.
///
/// `"value"` is `readFresh`'s result key and appears in no other message the
/// gateway sends on this page — updates carry `"c"`, snapshots carry
/// `"snapshot"` — so a corruption armed on it lands on the answer this case
/// asked for and leaves the handshake, the snapshot and every tick around it
/// intact. Corrupting the *first* response instead would damage `hello`, and
/// every case in the file would be measuring a client that never connected.
bool _isReadAnswer(String message) => message.contains('"value"');

/// The same, for a write answer: `"outcome"` is `WriteResult.toJson`'s
/// discriminator.
bool _isWriteAnswer(String message) => message.contains('"outcome"');

void main() {
  group('a peer that answers with something else', () {
    test('an answer carrying someone else\'s id costs one deadline, not the '
        'client', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        config: faultClientConfig(control: _deadline),
        corrupt: onFirstMatching(_isReadAnswer, rewriteId('nobody-is-waiting')),
        seed: (plant) => plant.setValue(_key, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final started = DateTime.now();
      final failure = await _outcomeOf(
        fixture.client.readFresh(_key),
        'the read whose answer was re-addressed to nobody',
      );
      final took = DateTime.now().difference(started);

      expect(failure, isA<TimeoutException>(),
          reason: 'the call came back with $failure. json_rpc_2 has no '
              'per-request timeout of its own and does not notice that a '
              'well-formed answer was addressed to someone else, so nothing '
              'below `callWithDeadline` can end this call: a different outcome '
              'here means the deadline is not what settled it, and the panel '
              'that gets the real version of this fault waits forever on a '
              'page that looks connected');
      expect(took, lessThan(_deadline + _budget),
          reason: 'the answer took ${took.inMilliseconds} ms against a '
              '${_deadline.inMilliseconds} ms deadline');

      // And the failure is one request wide. The link never closed, so a
      // client that reset its session over one bad frame would be throwing
      // away a page that is still working.
      expect(fixture.client.isReady, isTrue,
          reason: 'the client left ready over a link that never closed');
      final second = await within(fixture.client.readFresh(_key),
          'a second read on the same connection', budget: _budget);
      expect(second.value, 1200,
          reason: 'the next request on the same session did not answer, so the '
              'mismatched id took the whole conversation down rather than the '
              'one call it belonged to');
      expect(fixture.seam.dials, 1,
          reason: 'the client redialled, so it recovered by rebuilding the '
              'link rather than by surviving the frame — which is a different '
              'and much more expensive answer to a single bad message');
    });

    test('a frame cut short is ended by the deadline, and the session lives',
        () async {
      final fixture = await faultFixture(
        keys: const {_key},
        config: faultClientConfig(control: _deadline),
        corrupt: onFirstMatching(_isReadAnswer, truncate(0.9)),
        seed: (plant) => plant.setValue(_key, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final failure = await _outcomeOf(
        fixture.client.readFresh(_key),
        'the read whose answer was cut short',
      );

      expect(failure, isA<TimeoutException>(),
          reason: 'the call came back with $failure. A truncated frame does '
              'not fail the pending request: the envelope answers -32700 to '
              'the sender and carries on, and the client half is never told '
              '(Finding 15). The deadline is the only thing that ends it');

      final second = await within(fixture.client.readFresh(_key),
          'a second read after the truncated one', budget: _budget);
      expect(second.value, 1200,
          reason: 'the peer stayed open and kept answering everything else — '
              'that is the measured behaviour, and a client that could not use '
              'the surviving session would be discarding a working link');
    });

    test('a result of the wrong type is a FormatException, not a cast crash',
        () async {
      final fixture = await faultFixture(
        keys: const {_key},
        config: faultClientConfig(control: _deadline),
        corrupt: onFirstMatching(_isReadAnswer, retype('result', 'oops')),
        seed: (plant) => plant.setValue(_key, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final failure = await _outcomeOf(
        fixture.client.readFresh(_key),
        'the read whose result was retyped to a String',
      );

      expect(failure, isA<FormatException>(),
          reason: 'the call came back with $failure. The envelope does not '
              'type-check the payload at all — a String where a Map was '
              'expected resolves (Finding 15) — so the decode boundary is the '
              'only thing between a lying peer and the store. It must report '
              'in its own words: a raw TypeError from a cast names a line in '
              'the protocol package instead of naming the peer, and a value '
              'that reached the store would be a number on a mimic that the '
              'plant never sent');

      final second = await within(fixture.client.readFresh(_key),
          'a second read after the retyped one', budget: _budget);
      expect(second.value, 1200);
    });

    test('the same lie on the write path is an unknown outcome, never a throw '
        'and never a refusal', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        config: faultClientConfig(write: _deadline),
        corrupt: onFirstMatching(_isWriteAnswer, retype('result', 'oops')),
        seed: (plant) => plant.setValue(_key, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final outcome = await within(fixture.client.write(_key, 1500),
          'the write whose answer could not be decoded', budget: _budget);

      expect(outcome, isA<WriteUnknown>(),
          reason: 'the write came back $outcome. The answer arrived and could '
              'not be understood, so what the device did is exactly unknown — '
              'and the one verdict that must never come out of an undecodable '
              'answer is a refusal, which tells an operator the machine '
              'definitely did not move');
      expect((outcome as WriteUnknown).reason.kind,
          FailureKind.undecodableAnswer,
          reason: 'the unknown must name what went wrong; an operator sent to '
              'look at a machine deserves to know whether the link died or the '
              'gateway spoke nonsense');
      expect(fixture.client.debugUnresolvedCmds, contains(outcome.cmd),
          reason: 'an unknown outcome that is not held for re-query is an '
              'outcome nobody will ever establish');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the write was sent more than once — on a plant that is a '
              'second stroke of a ram the operator commanded once');
    });
  });
}

/// Runs [call] and hands back what it failed with, or null if it succeeded.
///
/// The deadline is `within`'s, so a call that never settles fails this test
/// naming the property rather than hanging until the runner gives up — and the
/// failure is captured as data rather than allowed to escape, because "it threw
/// this particular thing" is the assertion, not the accident.
Future<Object?> _outcomeOf(Future<Object?> call, String what) async {
  Object? failure;
  await within(
    call.then<void>((_) {}, onError: (Object error) => failure = error),
    what,
    budget: _budget,
  );
  return failure;
}
