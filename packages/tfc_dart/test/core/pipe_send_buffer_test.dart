/// The conflation state machine's unit lane (PIPE-11, criterion 1 and 2).
///
/// Pure: no clock, no I/O, no fake time — every timestamp in here is data the
/// caller passes in. That is the whole reason [PipeSendBuffer] refuses to own a
/// clock, and it is what makes these arms deterministic under `concurrency: 1`
/// alongside the rest of the suite.
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// The instant the fabricated bursts are stamped from. A fixed literal, never
/// `DateTime.now()` — a golden/unit arm anchored to the wall clock is a
/// flake waiting for a slow runner.
final _t0 = DateTime.utc(2026, 9, 5, 12);

/// A rotation of qualities so every put in a burst is distinguishable: if the
/// buffer kept the *first* value, or composed qualities across puts, the
/// assertion on the 199th would not hold by accident.
const _qualities = <relay.Quality>[
  relay.Quality.good,
  relay.Quality.goodWritePending,
  relay.Quality.uncertainLastKnown,
  relay.Quality.badStale,
  relay.Quality.badCommFault,
];

relay.Quality _qualityFor(int i) => _qualities[i % _qualities.length];

DateTime _sourceTimeFor(int i) => _t0.add(Duration(milliseconds: i));

/// One notification as the worker would translate it: value, quality and the
/// source instant travelling together.
relay.DynamicValue _sample(int i) => relay.DynamicValue(
      value: i,
      quality: _qualityFor(i),
      sourceTime: _sourceTimeFor(i),
    );

/// A stand-in for whatever the worker endpoint will actually put on the
/// priority lane (a typed subscription error, a worker-death notice, a
/// ready/epoch bump). The lane is `Object?` on purpose — these messages are
/// process-internal, never a wire shape — so the buffer's contract is only
/// that it hands them back verbatim and in order.
final class _PipeError {
  final String key;
  final String detail;
  const _PipeError(this.key, this.detail);
}

void main() {
  group('PipeSendBuffer — conflation (PIPE-11 criterion 1)', () {
    test('a 200-notification burst for one key drains to exactly one value, '
        'latest wins, quality and sourceTime preserved', () {
      final buffer = PipeSendBuffer();

      for (var i = 0; i < 200; i++) {
        buffer.putValue('a', _sample(i));
      }

      final frame = buffer.drain();

      // One message per key per tick, regardless of notification rate. This is
      // the bound: the plant's rate cannot become the pipe's queue depth.
      expect(frame.values, hasLength(1));
      final a = frame.values['a']!;
      expect(a.value, 199, reason: 'latest wins, not first');
      expect(a.quality, _qualityFor(199),
          reason: 'the winning sample keeps its own quality');
      expect(a.sourceTime, _sourceTimeFor(199),
          reason: 'the source instant is the PLC\'s, carried through unchanged');
    });

    test('one value per key across keys; a second drain is empty', () {
      final buffer = PipeSendBuffer();
      buffer.putValue('a', _sample(1));
      buffer.putValue('b', _sample(2));
      buffer.putValue('c', _sample(3));

      final first = buffer.drain();
      expect(first.values.keys, unorderedEquals(['a', 'b', 'c']));
      expect(first.isEmpty, isFalse);

      // Conflate, never queue: draining empties the buffer, so recovery never
      // has a backlog to flush.
      final second = buffer.drain();
      expect(second.values, isEmpty);
      expect(second.priority, isEmpty);
      expect(second.isEmpty, isTrue);
    });

    test('drain of an untouched buffer is an empty frame', () {
      expect(PipeSendBuffer().drain().isEmpty, isTrue);
    });

    test('putQuality composes rather than replaces when the pending value is '
        'non-finite', () {
      final buffer = PipeSendBuffer();
      // An open-circuit 4-20 mA reading: the sanitizing ctor nulls the payload
      // and flags badNonFinite.
      buffer.putValue(
          'a', relay.DynamicValue(value: double.nan, sourceTime: _t0));
      buffer.putQuality('a', relay.Quality.good);

      final a = buffer.drain().values['a']!;
      expect(a.quality, relay.Quality.badNonFinite,
          reason: 'a quality-only transition is not news about the value; '
              'letting good win outright lands the fault as a blank box');
      expect(a.value, isNull);
      expect(a.sourceTime, _t0, reason: 'the pending source instant survives');
    });

    test('putQuality replaces when the pending value is finite', () {
      final buffer = PipeSendBuffer();
      buffer.putValue('a', _sample(7));
      buffer.putQuality('a', relay.Quality.uncertainLastKnown);

      final a = buffer.drain().values['a']!;
      expect(a.quality, relay.Quality.uncertainLastKnown);
      expect(a.value, 7, reason: 'the value itself is unchanged upstream');
      expect(a.sourceTime, _sourceTimeFor(7));
    });

    test('putValue supersedes a pending quality-only transition', () {
      final buffer = PipeSendBuffer();
      buffer.putQuality('a', relay.Quality.badCommFault);
      buffer.putValue('a', _sample(4));

      final a = buffer.drain().values['a']!;
      expect(a.value, 4);
      expect(a.quality, _qualityFor(4),
          reason: 'the newer whole sample carries its own quality');
    });

    test('remove retires the key: it is absent from the drained values', () {
      final buffer = PipeSendBuffer();
      buffer.putValue('a', _sample(1));
      buffer.putValue('b', _sample(2));
      buffer.remove('a');

      final frame = buffer.drain();
      expect(frame.values.containsKey('a'), isFalse,
          reason: 'onDone / key-retired supersedes everything pending');
      expect(frame.values.keys, ['b']);
    });

    test('putValue after remove wins (the key came back in the same tick)', () {
      final buffer = PipeSendBuffer();
      buffer.putValue('a', _sample(1));
      buffer.remove('a');
      buffer.putValue('a', _sample(9));

      expect(buffer.drain().values['a']!.value, 9);
    });
  });

  group('PipeSendBuffer — the priority lane is never conflated '
      '(PIPE-11 criterion 2)', () {
    test('value -> error -> value in one tick delivers all three', () {
      final buffer = PipeSendBuffer();
      const boom = _PipeError('k', 'Bad_CommunicationError');

      buffer.putValue('k', _sample(1));
      buffer.putPriority(boom);
      buffer.putValue('k', _sample(2));

      final frame = buffer.drain();

      // The error is NOT absorbed by the latest-per-key map. If it were, the
      // operator would see a fresh number with no sign the link had faulted in
      // between — stale-but-plausible, by a different door.
      expect(frame.priority, [same(boom)]);
      // ...and the later value is not swallowed by the error either.
      expect(frame.values['k']!.value, 2);
      expect(frame.values['k']!.quality, _qualityFor(2));
      // Three events put, three events delivered, in one frame.
      expect(frame.priority.length + frame.values.length, 2,
          reason: 'two conflated values collapse to one; the error stands '
              'alone on its own lane');
    });

    test('priority events keep FIFO order across the drain', () {
      final buffer = PipeSendBuffer();
      final events = [
        const _PipeError('k', 'first'),
        const _PipeError('k', 'second'),
        const _PipeError('j', 'third'),
      ];
      for (final e in events) {
        buffer.putPriority(e);
      }
      // Telemetry interleaved between them must not reorder the lane.
      buffer.putValue('k', _sample(5));

      final frame = buffer.drain();
      expect(frame.priority.map((e) => (e as _PipeError).detail),
          ['first', 'second', 'third']);
    });

    test('a repeated error for one key is never collapsed', () {
      final buffer = PipeSendBuffer();
      for (var i = 0; i < 5; i++) {
        buffer.putPriority(_PipeError('k', 'retry $i'));
      }
      expect(buffer.drain().priority, hasLength(5),
          reason: 'the priority lane has no last-wins rule at all');
    });

    test('a priority event alone makes the frame non-empty and creates no '
        'phantom value entry', () {
      final buffer = PipeSendBuffer();
      buffer.putPriority(const _PipeError('k', 'worker died'));

      final frame = buffer.drain();
      expect(frame.isEmpty, isFalse);
      expect(frame.values, isEmpty);
      expect(buffer.drain().isEmpty, isTrue, reason: 'the lane drained empty');
    });

    test('remove() cancels pending telemetry but not the retirement notice',
        () {
      final buffer = PipeSendBuffer();
      buffer.putValue('k', _sample(1));
      buffer.putPriority(const _PipeError('k', 'key retired'));
      buffer.remove('k');

      final frame = buffer.drain();
      expect(frame.values, isEmpty);
      expect(frame.priority, hasLength(1),
          reason: 'silence about a retired key is not acceptable');
    });
  });
}
