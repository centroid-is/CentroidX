import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  Map<String, Object?> roundTrip(WriteResult r) =>
      jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>;

  group('WriteResult', () {
    test('applied round-trips with readback and timestamp', () {
      final r = WriteResult.fromJson(roundTrip(const WriteApplied(
        '01J8XW3K9P',
        readback: 1500,
        at: 1786000000456,
      )));
      final applied = r as WriteApplied;
      expect(applied.cmd, '01J8XW3K9P');
      expect(applied.readback, 1500);
      expect(applied.at, 1786000000456);
    });

    test('rejected carries the device reason — it is a result, not an error',
        () {
      final r = WriteResult.fromJson(roundTrip(const WriteRejected(
        'cmd1',
        WriteReason('interlocked',
            message: 'guard door open', status: 'Bad_NotWritable'),
      )));
      final rejected = r as WriteRejected;
      expect(rejected.reason.kind, 'interlocked');
      expect(rejected.reason.status, 'Bad_NotWritable');
    });

    test('unknown round-trips', () {
      final r = WriteResult.fromJson(roundTrip(const WriteUnknown(
        'cmd2',
        WriteReason('plc_timeout', message: 'no response from ST101'),
      )));
      expect((r as WriteUnknown).reason.kind, 'plc_timeout');
    });

    test('not_received round-trips', () {
      final r = WriteResult.fromJson(roundTrip(const WriteNotReceived('cmd3')));
      expect(r, isA<WriteNotReceived>());
    });

    test('an unrecognized outcome degrades to unknown, never throws', () {
      // Forward compatibility on the safety path: a newer server's outcome
      // this client doesn't know is not proof of application.
      final r = WriteResult.fromJson({
        'cmd': 'cmd4',
        'outcome': 'partially_applied',
      });
      final unknown = r as WriteUnknown;
      expect(unknown.reason.kind, contains('partially_applied'));
    });

    group('a malformed payload resolves unknown rather than throwing', () {
      // CR-01. The whole point of the sealed type is that "the PLC may have
      // applied this" cannot collapse into a thrown error. A decoder that
      // throws puts that collapse back, on the two arms that matter most:
      // an `unknown` truncated by a half-closed socket, and an `applied`
      // whose `at` a slightly-different server omits.

      test('unknown with no reason at all', () {
        final r = WriteResult.fromJson({'cmd': 'X', 'outcome': 'unknown'});
        final unknown = r as WriteUnknown;
        expect(unknown.cmd, 'X');
        expect(unknown.reason.kind, WriteReason.unspecified);
      });

      test('applied with no `at` is not proof of application', () {
        final r = WriteResult.fromJson(
            {'cmd': 'X', 'outcome': 'applied', 'readback': 1});
        expect(r, isA<WriteUnknown>());
        expect((r as WriteUnknown).reason.kind, 'malformed_result:applied');
      });

      test('rejected with no reason still names a kind', () {
        final r = WriteResult.fromJson({'cmd': 'X', 'outcome': 'rejected'});
        final rejected = r as WriteRejected;
        expect(rejected.reason.kind, WriteReason.unspecified);
        expect(rejected.at, isNull);
      });

      test('wrong-typed fields degrade instead of detonating', () {
        final r = WriteResult.fromJson({
          'cmd': 'X',
          'outcome': 'rejected',
          'at': 'yesterday',
          'reason': {'kind': 7, 'message': 42},
        });
        final rejected = r as WriteRejected;
        expect(rejected.at, isNull);
        expect(rejected.reason.kind, WriteReason.unspecified);
        expect(rejected.reason.message, isNull);
      });

      test('a reason that is not an object at all', () {
        final r = WriteResult.fromJson(
            {'cmd': 'X', 'outcome': 'unknown', 'reason': 'plc_timeout'});
        expect((r as WriteUnknown).reason.kind, WriteReason.unspecified);
      });

      test('a missing outcome is unknown, not an exception', () {
        final r = WriteResult.fromJson({'cmd': 'X'});
        expect((r as WriteUnknown).reason.kind, contains('null'));
      });
    });

    test('a payload with no usable cmd is a protocol error', () {
      // The one throw the write path keeps: without an id there is nothing
      // `writeStatus` could ever reconcile, so this is not a write outcome.
      expect(() => WriteResult.fromJson({'outcome': 'applied', 'at': 1}),
          throwsFormatException);
      expect(() => WriteResult.fromJson({'cmd': '', 'outcome': 'unknown'}),
          throwsFormatException);
      expect(() => WriteResult.fromJson({'cmd': 7, 'outcome': 'unknown'}),
          throwsFormatException);
    });

    test('the sealed switch is exhaustive — every state must be handled', () {
      // This test exists so removing/adding a state breaks compilation
      // here first, in a file whose comments explain the safety rules.
      String describe(WriteResult r) => switch (r) {
            WriteApplied() => 'applied',
            WriteRejected() => 'rejected',
            WriteUnknown() => 'unknown — verify, never auto-retry',
            WriteNotReceived() => 'not received — operator may re-send',
          };
      expect(describe(const WriteNotReceived('x')), contains('re-send'));
      expect(describe(const WriteUnknown('x', WriteReason('link_lost'))),
          contains('never auto-retry'));
    });

    group('re-send safety is a member of the type', () {
      // 05-RESEARCH §E.2 Gap 1. Until now "only not_received is re-send-safe"
      // lived as prose in three doc comments and one switch label in the
      // contract suite, so a caller building a re-send button had nothing to
      // test but `is WriteNotReceived`.
      //
      // What this group costs if a fifth outcome is ever added: the switch
      // below stops compiling, in this file, next to this comment. That is
      // the point. A new arm would otherwise inherit `false` in silence —
      // which is the safe default, but silence is not a decision, and the
      // re-send policy for a new outcome is a decision somebody has to make
      // in writing.
      String nameOf(WriteResult r) => switch (r) {
            WriteApplied() => 'WriteApplied',
            WriteRejected() => 'WriteRejected',
            WriteUnknown() => 'WriteUnknown',
            WriteNotReceived() => 'WriteNotReceived',
          };

      const everyOutcome = <WriteResult>[
        WriteApplied('cmd', readback: 1450, at: 1786000000456),
        WriteRejected('cmd', WriteReason('interlocked')),
        WriteUnknown('cmd', WriteReason('link_lost')),
        WriteNotReceived('cmd'),
      ];

      test(
          'exactly one outcome is re-send-safe, and it is the one the gateway '
          'needed evidence for', () {
        final safe = everyOutcome
            .where((r) => r.isSafeToResend)
            .map(nameOf)
            .toSet();
        expect(safe, {'WriteNotReceived'},
            reason: 'offering a re-send for any other outcome invites the '
                'operator to move the machine twice — not_received is the '
                'only verdict the gateway reached with positive evidence');
      });

      test('the four arms answer individually, not just as a set', () {
        expect(const WriteApplied('c', readback: 1, at: 1).isSafeToResend,
            isFalse,
            reason: 'the write already landed; re-sending would apply it a '
                'second time');
        expect(
            const WriteRejected('c', WriteReason('interlocked')).isSafeToResend,
            isFalse,
            reason: 'the device said no for a reason; the operator clears the '
                'interlock, not the dialog');
        expect(const WriteUnknown('c', WriteReason('plc_timeout')).isSafeToResend,
            isFalse,
            reason: 'the write may already be at the plant — verify by '
                'readback, never re-send blind');
        expect(const WriteNotReceived('c').isSafeToResend, isTrue,
            reason: 'the gateway proved it never saw this cmd, so a re-send '
                'may be offered — offered, still never automatic');
      });

      test('a truncated answer cannot arrive re-send-safe', () {
        // The decode path and the getter have to agree: every payload that
        // degrades to unknown (half-closed socket, version skew, an applied
        // with no `at`) must come back not-safe.
        for (final json in <Map<String, Object?>>[
          {'cmd': 'X', 'outcome': 'unknown'},
          {'cmd': 'X'},
          {'cmd': 'X', 'outcome': 'applied', 'readback': 1},
          {'cmd': 'X', 'outcome': 'partially_applied'},
        ]) {
          expect(WriteResult.fromJson(json).isSafeToResend, isFalse,
              reason: 'a malformed answer about $json is not proof the plant '
                  'was untouched');
        }
        expect(
            WriteResult.fromJson({'cmd': 'X', 'outcome': 'not_received'})
                .isSafeToResend,
            isTrue,
            reason: 'the one answer that does carry that proof has to survive '
                'the wire');
      });
    });
  });
}
