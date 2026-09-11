/// Unknown versus rejected — the highest-consequence two-way branch in the
/// client.
///
/// Source: 04-RESEARCH Finding 1, notes 2 and 3, measured against
/// `json_rpc_2` 4.1.0. A transport that closes under an in-flight request
/// fails it with
///
/// > `StateError: Bad state: The client closed with pending request "…".`
///
/// — **not** an `RpcException`. So `on RpcException` misses connection loss
/// entirely, and the error *type* is the discriminator between two opposite
/// verdicts: `StateError` → `WriteUnknown`, `RpcException` → `WriteRejected`.
///
/// What breaks in the plant when they are the wrong way round. "Rejected"
/// means the machine did not move: the operator reads the reason, changes
/// something, and tries again. "Unknown" means nobody knows: the operator has
/// to go and look at the equipment before touching anything. Report a lost
/// link as a refusal and you have told someone a valve definitely did not open
/// when it may well have; report a genuine interlock refusal as unknown and
/// you send a fitter across the factory for nothing, which is how a plant
/// learns to ignore the warning.
///
/// Note 3 is the trap underneath it: `StateError` is also what a plain
/// programming error looks like, and the message string is the only thing
/// telling them apart. A bare `on StateError` at this seam swallows a real bug
/// and reports it to the operator as a plant condition, which is the worst of
/// both — the write outcome is wrong *and* the defect is invisible.
library;

import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/deadline.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The exact frames Finding 1 observed, constructed as the library constructs
/// them — message text included, because the text is the discriminator.
final StateError _closedWithPending =
    StateError('The client closed with pending request "write".');
final StateError _alreadyClosed = StateError('The client is closed.');

/// A ULID-shaped command id. Nothing here parses it; it only has to survive.
const String _cmd = '01J0000000000000000000000A';

void main() {
  group('a link that went away is never a refusal', () {
    test('a link that died mid-write resolves unknown, because rejected means '
        'the machine did not move', () {
      final outcome = writeOutcomeFor(_cmd, _closedWithPending);

      expect(outcome, isA<WriteUnknown>(),
          reason: 'the socket closed with the write already sent: the PLC may '
              'have taken it. Calling that rejected tells the operator the '
              'machine did not move, and they act on that — this is the '
              'write-safety defect Finding 1 exists to prevent');
      expect((outcome as WriteUnknown).reason.kind, 'link_lost',
          reason: 'the kind has to be greppable in a log a week later');
      expect(outcome.cmd, _cmd,
          reason: 'without the cmd there is nothing for writeStatus to '
              'reconcile on reconnect, and unknown stays unknown forever');
    });

    test('a client that was already closed resolves unknown too', () {
      expect(writeOutcomeFor(_cmd, _alreadyClosed), isA<WriteUnknown>(),
          reason: 'Finding 1 row 4: sending on a closed peer is the same '
              'ignorance about the plant as losing the link mid-flight');
    });

    test('a deadline expiry resolves unknown — the answer may still be on its '
        'way', () {
      final outcome = writeOutcomeFor(
          _cmd, TimeoutException('Future not completed', _deadline));

      expect(outcome, isA<WriteUnknown>());
      expect((outcome as WriteUnknown).reason.kind, 'deadline_expired',
          reason: 'a distinct kind from link_lost, because the two need '
              'different things looked at: one is the network, the other is a '
              'gateway or PLC taking longer than it was given');
    });

    test('our own link-down resolves unknown, with the call in the reason', () {
      final outcome = writeOutcomeFor(_cmd, const LinkDown('write'));

      expect(outcome, isA<WriteUnknown>());
      expect((outcome as WriteUnknown).reason.kind, 'link_down');
    });

    test('an answer nobody could decode resolves unknown, never a throw', () {
      // STATE.md Phase 1 handoff and CR-01: a truncated write result is a
      // write whose fate this side cannot establish. Decoding it must not
      // throw, or the operator is told the write failed and re-sends it.
      final outcome =
          writeOutcomeFor(_cmd, const FormatException('unexpected end of input'));

      expect(outcome, isA<WriteUnknown>(),
          reason: 'half an answer proves nothing about the machinery, and a '
              'throw here reads to the operator as "it failed"');
    });
  });

  group('a server that said no is a refusal, with its words', () {
    test('a server refusal resolves rejected, carrying the code and message',
        () {
      final outcome = writeOutcomeFor(
          _cmd, RpcException(-32004, 'no common protocol version'));

      expect(outcome, isA<WriteRejected>(),
          reason: 'a JSON-RPC error on a write is definitively no effect and '
              'is the one retry-safe case (STATE.md Phase 1 handoff) — '
              'calling it unknown sends someone to look at a machine that '
              'provably never moved');
      final rejected = outcome as WriteRejected;
      expect(rejected.reason.message, contains('no common protocol version'),
          reason: 'the operator needs the server\'s own words, not our '
              'paraphrase of them');
      expect(rejected.reason.status, contains('-32004'),
          reason: 'the code is what an engineer greps for when the message '
              'has been translated or truncated');
    });

    test('a refused non-finite expect stays a refusal all the way up', () {
      // STATE.md Phase 1 handoff: a non-finite `expect` is an ArgumentError at
      // construction and a FormatException → JSON-RPC error on the wire.
      // Definitively no effect, and therefore retry-safe — the only outcome
      // that is.
      final outcome = writeOutcomeFor(
          _cmd, RpcException.invalidParams('expect must be finite'));

      expect(outcome, isA<WriteRejected>(),
          reason: 'the gateway refused the request before touching the PLC; '
              'downgrading that to unknown hides a client-side bug behind a '
              'plant-condition warning');
    });
  });

  group('a bug in this client stays a bug', () {
    test('a programming-error StateError is rethrown, not laundered into an '
        'unknown write', () {
      // `Iterable.single` on the wrong list throws exactly this.
      expect(
        () => writeOutcomeFor(_cmd, StateError('No element')),
        throwsA(isA<StateError>()),
        reason: 'a bare `on StateError` here swallows it and reports our own '
            'defect to the operator as a lost link: the write outcome is '
            'wrong and the bug is invisible, which is the pair of failures '
            'this seam exists to keep apart',
      );
    });

    test('a type error is rethrown too', () {
      expect(
        () => writeOutcomeFor(
            _cmd, ArgumentError.value(null, 'value', 'must not be null')),
        throwsA(isA<ArgumentError>()),
        reason: 'an Error subtype is a defect in this process, not a '
            'condition of the plant, and the crash report is worth more than '
            'a soothing "unknown"',
      );
    });

    test('the message predicate is the only discriminator, and it is narrow',
        () {
      expect(isLinkLossMessage(_closedWithPending.message.toString()), isTrue);
      expect(isLinkLossMessage(_alreadyClosed.message.toString()), isTrue);
      expect(isLinkLossMessage('No element'), isFalse,
          reason: 'widen this predicate and every programming error in the '
              'client starts being reported as a plant condition');
      expect(isLinkLossMessage('Cannot add to a closed sink'), isFalse,
          reason: 'a sink misuse is our bug, however much it reads like a '
              'link fault');
    });
  });

  group('classification is total on the write path', () {
    test('every wire failure produces a WriteResult and none of them is '
        'rejected by accident', () {
      final wireFailures = <Object>[
        _closedWithPending,
        _alreadyClosed,
        TimeoutException('Future not completed', _deadline),
        const LinkDown('write'),
        const FormatException('unexpected end of input'),
        const SocketException('Connection reset by peer'),
      ];

      for (final failure in wireFailures) {
        final outcome = writeOutcomeFor(_cmd, failure);
        expect(outcome, isA<WriteUnknown>(),
            reason: 'not one of these is the server saying no, and only the '
                'server saying no may resolve rejected: ${failure.runtimeType}');
      }
    });

    test('the classifier has exactly two shapes and neither of them is a '
        'retry instruction', () {
      expect(classifyFailure(_closedWithPending), isA<LinkLoss>());
      expect(classifyFailure(RpcException(-32000, 'no')), isA<ServerRefusal>());
    });
  });

  group('nothing in the client library re-issues a request', () {
    test('no code path in lib/ calls anything that re-sends', () {
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue,
          reason: 'this case reads the library as text, so it must be run '
              'from the package root the CI step sets as its '
              'working-directory');

      // Call-shaped only: the prose in this package argues about retrying at
      // length, and an argument against a retry is not a retry.
      final reIssue = RegExp(
          r'(retry|resend|re_?send)\s*\(|\.\s*(retry|resend)\b',
          caseSensitive: false);

      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          if (line.startsWith('///') || line.startsWith('//')) continue;
          if (reIssue.hasMatch(line)) {
            offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'a write is an actuation of machinery — a ram, a valve, a '
              'diverter. Re-sending one because the first answer did not '
              'arrive actuates it a second time, and the client cannot know '
              'whether the first one landed. That decision belongs to a human '
              'looking at the machine, which is why MQTT QoS 1 and every '
              'queueing socket wrapper were ruled out in STACK');
    });
  });
}

/// A deadline value for constructing `TimeoutException`s. Not used to wait on
/// anything: nothing in this file is a timing case.
const Duration _deadline = Duration(seconds: 2);
