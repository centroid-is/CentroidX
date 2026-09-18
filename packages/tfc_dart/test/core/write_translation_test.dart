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

  // ------------------------------------------------------------------------
  // The redactor, rule by rule.
  //
  // These mirror `tfc_relay_local`'s
  // `test/upstream_link_contract_test.dart:72-173` one arm for one arm, with
  // the same inputs, so the two files can be diffed and seen to ask the two
  // sides the same questions. Before these arms existed, this package's entire
  // coverage of the redactor was one assertion inside the `link_lost` case
  // above (`:76`), exercising rule 1 of eight.
  //
  // The redactor is private in this package, so no arm can call it directly.
  // Each goes through [redactedVia], which is a real public entry point —
  // `translateWriteAnswer` with an unruled OPC UA status — and asserts on the
  // `WriteReason.message` that reaches a panel. That indirection is the honest
  // cost of the function being private, and it is deliberately not paid by
  // making it public: a public symbol left behind is a symbol somebody imports.
  group('the redactor, rule by rule', () {
    test('rule 1: takes the credentials out with the endpoint', () {
      final out = redactedVia(
          'connect failed: opc.tcp://svc:hunter2@10.104.29.11:4840/ua/server');

      expect(out, isNot(contains('hunter2')),
          reason: 'the password rode in on the endpoint userinfo, which is '
              'where a real open62541 connect error puts it — and this string '
              'becomes a plant-visible WriteReason.message (T-08-33)');
      expect(out, isNot(contains('10.104.29.11')));
      expect(out, contains('<endpoint>'),
          reason: 'the redacted form must still say what kind of thing was '
              'removed, or the diagnostic is worthless');
    });

    test('rules 2 and 3: takes certificate paths out, on both platforms', () {
      expect(redactedVia('cannot read /etc/centroid/certs/client.pem'),
          isNot(contains('client.pem')));
      expect(redactedVia(r'cannot read C:\centroid\certs\client.pfx'),
          isNot(contains('client.pfx')));
    });

    test('rule 5: takes a labelled host out', () {
      expect(redactedVia('SocketException: address = 10.104.29.71:502'),
          isNot(contains('10.104.29.71')));
    });

    test('rule 6: takes a BARE IPv4 out, with no label in front of it', () {
      // The arm the mirrored set does not otherwise reach: every other host
      // sample here carries an `address =` label, so rule 5 would eat them
      // first and rule 6 could be deleted without any of them noticing.
      final out = redactedVia('connection refused by 10.104.29.71:502')!;

      expect(out, isNot(contains('10.104.29.71')));
      expect(out, contains('<host>'));
    });

    test(
        'rules 7 and 8: takes an IPv6 literal out, in both of the shapes '
        'dart:io writes them', () {
      for (final raw in <String>[
        'SocketException: connect failed, address = fd00::10:104:29:11',
        'SocketException: connect failed, address = [fd00:1:2:3:4:5:6:7]:4840',
        'no route to ::1',
      ]) {
        final out = redactedVia(raw)!;
        expect(out, isNot(contains('fd00')), reason: raw);
        expect(out, isNot(contains('::1')), reason: raw);
        expect(out, contains('<host>'), reason: raw);
      }
    });

    test(
        'rule 5: takes a DNS hostname out, which names a machine as much as '
        'an address does', () {
      final out = redactedVia(
          'SocketException: Failed host lookup, address = st101.svn.local')!;

      expect(out, isNot(contains('st101.svn.local')),
          reason: 'a hostname names the PLC and the site as clearly as its '
              'address does, and the redactor is documented as deliberately '
              'over-broad — missing one costs plant topology');
      expect(out, contains('<host>'));
      expect(out, contains('Failed host lookup'),
          reason: 'and the part that says what went wrong survives, or the '
              'message is useless to the engineer it exists for');
    });

    test('the over-broad rule stops somewhere: a clock time is not an IPv6 '
        'address', () {
      // `09:49:57` is two colons and a lot of hex digits. A redactor that ate
      // every timestamp would make this message unreadable for the sake of
      // nothing, so rules 7 and 8 require `::` or at least three colons.
      final out = redactedVia('at 09:49:57 the session dropped')!;
      expect(out, contains('09:49:57'));
    });

    test('rule 4: takes a credential out even without a scheme in front of it',
        () {
      final out = redactedVia('rejected (username=admin password=s3cr3t)');

      expect(out, isNot(contains('s3cr3t')));
      expect(out, isNot(contains('admin')));
    });

    test('keeps the part of the message that says what went wrong', () {
      expect(redactedVia('BadUserAccessDenied from opc.tcp://plc:4840/'),
          contains('BadUserAccessDenied'),
          reason: 'redaction that removes the diagnosis as well as the '
              'credential just makes the operator ask somebody for the log');
    });

    test('bounds the length, because this becomes a plant-visible message', () {
      final out = redactedVia('x' * 5000)!;

      // 201, as a LITERAL, and deliberately not `maxRedactedErrorLength + 1`.
      // An arm written against the constant moves when the constant moves, so
      // raising the cap would not turn it red — it would assert the mutation
      // against itself. The number this arm exists to pin is 200.
      expect(out.length, lessThanOrEqualTo(201),
          reason: 'an upstream that flaps under a verbose stack trace would '
              'otherwise push kilobytes into a message shown on a panel');
    });

    test('passes null through as null, not as an empty message', () {
      // The only route that can hand the redactor a null is an unruled status
      // with no prose. A null answer takes the documented fallback; an empty
      // string would take the `??` branch too, so what this really pins is
      // that the redactor does not invent a message where there was none.
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteStatusAnswer(_unruledStatus, text: null),
      );
      expect((result as WriteUnknown).reason.message,
          contains('no ruling'),
          reason: 'a link that never carried prose has no message, and '
              'inventing "" for it would read as an error nobody wrote down');
    });
  });
}

/// An OPC UA status code this file has no ruling for, so [translateWriteAnswer]
/// answers [WriteUnknown] and carries the redacted prose through verbatim.
const int _unruledStatus = 0x80020000;

/// [raw] as it reaches a plant-visible `WriteReason.message`.
///
/// The redactor is private in this package. This is the shortest public path
/// that reaches it without transforming its answer: `_fromCode`'s unruled-status
/// branch assigns `message` the redactor's output unchanged, so what comes back
/// here is exactly what the redactor returned.
String? redactedVia(String? raw) {
  final result = translateWriteAnswer(
    protocol: UpstreamProtocol.opcUa,
    cmd: cmd,
    answer: WriteStatusAnswer(_unruledStatus, text: raw),
  );
  return (result as WriteUnknown).reason.message;
}
