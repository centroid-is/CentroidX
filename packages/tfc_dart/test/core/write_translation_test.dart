/// The three-state write classifier, in its new home.
///
/// The pure arms moved down with the code: what `translateWriteAnswer` makes of
/// each `WriteAnswer` per protocol, the ambiguity rule (unknown is the safe
/// default; only a named refusal is rejected), the write-status alignment guard
/// and the array-element ruling. No device, no link — that is the whole point of
/// pure functions. relay_local keeps its real-link arms, which exercise these
/// same functions through the re-export.
library;

import 'package:tfc_dart/core/write_translation.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

const String cmd = 'cmd-1';

void main() {
  group('OPC UA: a named refusal is rejected, everything else is unknown', () {
    test('an acknowledgement is applied, carrying readback and stamp', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteAcknowledged(readback: 42, at: 1700000000000),
      );
      expect(result, isA<WriteApplied>());
      result as WriteApplied;
      expect(result.cmd, cmd);
      expect(result.readback, 42);
      expect(result.at, 1700000000000);
    });

    test('each named refusal code becomes WriteRejected by that name', () {
      for (final entry in opcUaWriteRefusals.entries) {
        final result = translateWriteAnswer(
          protocol: UpstreamProtocol.opcUa,
          cmd: cmd,
          answer: WriteStatusAnswer(entry.key),
        );
        expect(result, isA<WriteRejected>(),
            reason: '0x${entry.key.toRadixString(16)} is a named refusal');
        expect((result as WriteRejected).reason.status, entry.value);
      }
    });

    test('an unruled Bad status is unknown, never rejected', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x80020000),
      );
      expect(result, isA<WriteUnknown>());
      expect((result as WriteUnknown).reason.kind, 'unruled_status');
    });

    test('Good code is applied', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteStatusAnswer(opcUaStatusGood),
      );
      expect(result, isA<WriteApplied>());
    });

    test('a deadline is unknown regardless of requestSent', () {
      for (final sent in <bool>[true, false]) {
        final result = translateWriteAnswer(
          protocol: UpstreamProtocol.opcUa,
          cmd: cmd,
          answer: WriteDeadlineExpired(requestSent: sent),
        );
        expect(result, isA<WriteUnknown>());
        expect((result as WriteUnknown).reason.kind, 'plc_timeout');
      }
    });

    test('a throw is unknown (link_lost), and the message is redacted', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: WriteThrew(
            StateError('closed talking to opc.tcp://svc:hunter2@10.0.0.5:4840/')),
      );
      expect(result, isA<WriteUnknown>());
      result as WriteUnknown;
      expect(result.reason.kind, 'link_lost');
      expect(result.reason.message, isNot(contains('hunter2')),
          reason: 'credentials must be redacted before becoming a key value');
      expect(result.reason.message, isNot(contains('10.0.0.5')));
    });

    test('a named refusal in prose is rejected (both spellings)', () {
      for (final text in <String>[
        'Failed to write value: BadNotWritable',
        'Failed to write value: Bad_NotWritable',
      ]) {
        final result = translateWriteAnswer(
          protocol: UpstreamProtocol.opcUa,
          cmd: cmd,
          answer: WriteErrorText(text),
        );
        expect(result, isA<WriteRejected>(), reason: text);
        expect((result as WriteRejected).reason.status, 'Bad_NotWritable');
      }
    });

    test('a sentence this file cannot read is unknown, never rejected', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteErrorText('Failed to write value: something new'),
      );
      expect(result, isA<WriteUnknown>());
      expect((result as WriteUnknown).reason.kind, 'unparsed_upstream_error');
    });
  });

  group('Modbus: an exception response is the device answering', () {
    test('an ack is applied', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteAcknowledged(readback: true),
      );
      expect(result, isA<WriteApplied>());
    });

    test('a named exception code is rejected', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x02),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Modbus_IllegalDataAddress');
    });

    test('an UNnamed exception code is still a refusal', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x7F),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, contains('0x7f'));
    });
  });

  group('UMAS: a typed exception splits the same way', () {
    test('a typed code is rejected by name', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.umas,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x0F),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Umas_0x0f');
    });

    test('a throw is unknown', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.umas,
        cmd: cmd,
        answer: WriteThrew(StateError('socket closed')),
      );
      expect(result, isA<WriteUnknown>());
    });
  });

  group('M2400: read-only by protocol answers a refusal, never an exception',
      () {
    test('even a deadline resolves to the read-only refusal', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.m2400,
        cmd: cmd,
        answer: const WriteDeadlineExpired(),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason, notWritableReason);
    });

    test('even an ack from that direction is a refusal (adapter bug, not news)',
        () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.m2400,
        cmd: cmd,
        answer: const WriteAcknowledged(readback: 1),
      );
      expect(result, isA<WriteRejected>());
    });
  });

  group('the ambiguity rule holds across every protocol', () {
    test('a deadline is unknown everywhere except the read-only M2400', () {
      for (final protocol in UpstreamProtocol.values) {
        final result = translateWriteAnswer(
          protocol: protocol,
          cmd: cmd,
          answer: const WriteDeadlineExpired(),
        );
        if (protocol == UpstreamProtocol.m2400) {
          expect(result, isA<WriteRejected>());
        } else {
          expect(result, isA<WriteUnknown>(), reason: '$protocol');
        }
      }
    });
  });

  group('the array-element ruling: refuse, do not read-modify-write', () {
    test('no expect is refused by name', () {
      final refusal = guardArrayElementWrite(cmd: cmd, hasExpect: false);
      expect(refusal, isA<WriteRejected>());
      expect((refusal! as WriteRejected).reason.kind,
          'array_element_requires_expect');
    });

    test('with expect the write may proceed (null)', () {
      expect(guardArrayElementWrite(cmd: cmd, hasExpect: true), isNull);
    });
  });

  group('writeStatus alignment is positional and never shifted', () {
    test('a matching list passes through', () {
      final answers = <WriteResult>[
        WriteApplied('a', readback: null, at: 1),
        WriteApplied('b', readback: null, at: 2),
      ];
      final aligned = alignWriteStatusAnswers(<String>['a', 'b'], answers);
      expect(aligned, answers);
    });

    test('a mismatch is substituted IN PLACE, later entries keep their answer',
        () {
      final answers = <WriteResult>[
        WriteApplied('WRONG', readback: null, at: 1),
        WriteApplied('b', readback: null, at: 2),
      ];
      final aligned = alignWriteStatusAnswers(<String>['a', 'b'], answers);
      expect(aligned[0], isA<WriteUnknown>());
      expect((aligned[0] as WriteUnknown).reason.kind, 'misaligned_result');
      expect(aligned[0].cmd, 'a');
      expect(aligned[1], isA<WriteApplied>());
      expect(aligned[1].cmd, 'b');
    });

    test('a short answer list is padded with misaligned, not truncated', () {
      final aligned = alignWriteStatusAnswers(
        <String>['a', 'b'],
        <WriteResult>[WriteApplied('a', readback: null, at: 1)],
      );
      expect(aligned.length, 2);
      expect(aligned[1], isA<WriteUnknown>());
      expect(aligned[1].cmd, 'b');
    });
  });
}
