/// The one assertion in this phase that has to be counted rather than timed.
///
/// 03-RESEARCH Finding 2 benchmarked the fan-out at 100 clients × 200 changed
/// keys. Encoding per client — which is what `Peer.sendNotification` does,
/// because `json_rpc_2` wraps the channel in a JSON codec transformer per peer
/// — cost **7 639 µs per tick**. Encoding the changed body once and splicing
/// each client's envelope around it by string concatenation cost **110 µs**.
/// **69.6×**, and the slow path throws nothing, logs nothing and passes every
/// functional test in this repo. A timing assertion for that would be flaky on
/// a hosted runner and useless on a fast one, so this file counts encoder
/// calls instead: the count is exact, and it is exact on every machine.
///
/// The honest property is **one encode per distinct changed-key set per tick**,
/// not one encode per tick (03-RESEARCH Finding 3). Both halves are asserted
/// here, in those words, so nobody later has to weaken a promise this file
/// made too strongly.
library;

import 'dart:convert';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/frame_encoder.dart';
import 'package:test/test.dart';

import 'support/counting_encoder.dart';

/// A changed-value map over [count] consecutive handles starting at [from] —
/// the shape a drain hands the encoder.
Map<int, WireValue> changesOver(int count, {int from = 1}) => {
      for (var h = from; h < from + count; h++) h: WireValue.of(h * 1.5),
    };

/// Decodes a produced frame and returns its `params` object.
Map<String, Object?> paramsOf(String frame) =>
    ((jsonDecode(frame) as Map)['params'] as Map).cast<String, Object?>();

void main() {
  late CountingEncoder encoder;
  late FrameEncoder subject;

  setUp(() {
    encoder = CountingEncoder();
    subject = FrameEncoder(encode: encoder.call);
  });

  group('one encode per distinct changed-key set per tick', () {
    test('one client, one encode', () {
      final sub = subject.subLiteral('line1');
      encoder.reset();

      subject.beginTick();
      final body = subject.bodyFor(changesOver(200), const {}, const []);
      subject.updateFrame(sub: sub, seq: 1, t: 1000, generation: 1, body: body);

      expect(encoder.calls, 1,
          reason: 'a single client with 200 changed keys must cost exactly '
              'one encode; anything more is the per-client path that measured '
              '69.6x slower and never says so');
    });

    test('fifty clients sharing a changed-key set cost one encode', () {
      final subs = [
        for (var i = 0; i < 50; i++) subject.subLiteral('panel$i'),
      ];
      encoder.reset();

      subject.beginTick();
      for (var i = 0; i < subs.length; i++) {
        final body = subject.bodyFor(changesOver(200), const {}, const []);
        subject.updateFrame(sub: subs[i], seq: i + 1, t: 1000, generation: 1, body: body);
      }

      expect(encoder.calls, 1,
          reason: 'fifty panels watching the same tags must share one encoded '
              'body; encoding per panel is the 69.6x path, and the plant only '
              'finds out by watching a screen fall behind');
    });

    test('fifty disjoint clients cost fifty encodes', () {
      final subs = [
        for (var i = 0; i < 50; i++) subject.subLiteral('panel$i'),
      ];
      encoder.reset();

      subject.beginTick();
      for (var i = 0; i < subs.length; i++) {
        final body =
            subject.bodyFor(changesOver(4, from: i * 4 + 1), const {}, const []);
        subject.updateFrame(sub: subs[i], seq: 1, t: 1000, generation: 1, body: body);
      }

      expect(encoder.calls, 50,
          reason: 'sharing is only possible between identical changed-key '
              'sets; claiming one encode per tick would be a promise this '
              'code cannot keep');
    });

    test('handle insertion order does not split the cache', () {
      subject.beginTick();
      final ascending = subject.bodyFor(
          {1: WireValue.of(1), 2: WireValue.of(2)}, const {}, const []);
      encoder.reset();
      final descending = subject.bodyFor(
          {2: WireValue.of(2), 1: WireValue.of(1)}, const {}, const []);

      expect(encoder.calls, 0,
          reason: 'two clients whose drains happened to iterate in different '
              'orders are still watching the same tags and must share a body');
      expect(descending, ascending);
    });

    test('qualities and removals are part of the changed-key set', () {
      subject.beginTick();
      subject.bodyFor(changesOver(2), const {}, const []);
      encoder.reset();

      subject.bodyFor(changesOver(2), const {}, const [9]);
      expect(encoder.calls, 1,
          reason: 'a client being told a handle went away must not be handed '
              'the body of a client that was not');
    });

    test('the body cache does not survive a tick boundary', () {
      subject.beginTick();
      final first =
          subject.bodyFor({1: WireValue.of(10.0)}, const {}, const []);
      encoder.reset();

      subject.beginTick();
      final second =
          subject.bodyFor({1: WireValue.of(11.0)}, const {}, const []);

      expect(encoder.calls, 1,
          reason: 'a cache that outlived a tick would ship last tick numbers '
              'to a screen that shows them as current, which is the worst '
              'thing this project can do');
      expect(second, isNot(first));
      expect(second, contains('11'));
    });
  });

  group('the envelope', () {
    test('two clients sharing a body still get their own sub and seq', () {
      final a = subject.subLiteral('line1');
      final b = subject.subLiteral('line2');
      subject.beginTick();
      final body = subject.bodyFor(changesOver(3), const {}, const []);

      final frameA = subject.updateFrame(sub: a, seq: 7, t: 1700, generation: 1, body: body);
      final frameB = subject.updateFrame(sub: b, seq: 42, t: 1700, generation: 1, body: body);

      final pa = UpdateParams.fromJson(paramsOf(frameA));
      final pb = UpdateParams.fromJson(paramsOf(frameB));
      expect([pa.sub, pa.seq], ['line1', 7]);
      expect([pb.sub, pb.seq], ['line2', 42]);
      expect(pa.changes, pb.changes,
          reason: 'the shared part is the values; the addressing is not');
    });

    test('a produced frame round-trips through UpdateParams.fromJson', () {
      final sub = subject.subLiteral('line1');
      subject.beginTick();
      final body = subject.bodyFor(
        {1: WireValue.of(12.5), 2: WireValue.of('running')},
        {3: Quality.uncertainLastKnown},
        const [4],
      );
      final frame = subject.updateFrame(sub: sub, seq: 9, t: 1234, generation: 1, body: body);

      final decoded = jsonDecode(frame) as Map;
      expect(decoded['jsonrpc'], '2.0');
      expect(decoded['method'], Methods.update,
          reason: 'a hand-built envelope that disagrees with the method '
              'constant is a wire break no unit test of the DTO would catch');

      final params = UpdateParams.fromJson(paramsOf(frame));
      expect(params.sub, 'line1');
      expect(params.seq, 9);
      expect(params.t, 1234);
      expect(params.generation, 1,
          reason: 'the generation is what lets a client drop a frame from the '
              'establishment before its last snapshot; a frame that carries '
              'none is one it has to guess about');
      expect(params.changes[1]?.v, 12.5);
      expect(params.changes[2]?.v, 'running');
      expect(params.qualities[3], Quality.uncertainLastKnown);
      expect(params.removed, [4]);
    });

    test('an empty changed set still produces a legal frame', () {
      final sub = subject.subLiteral('line1');
      subject.beginTick();
      final body = subject.bodyFor(const {}, const {}, const []);
      final params = UpdateParams.fromJson(
          paramsOf(subject.updateFrame(sub: sub, seq: 1, t: 5, generation: 1, body: body)));

      expect(params.changes, isEmpty);
      expect(params.removed, isEmpty);
      expect(params.seq, 1);
    });

    test('a subscription name of quotes and backslashes cannot break the frame',
        () {
      const nasty = r'he said "\", then {"jsonrpc":"2.0"}';
      final sub = subject.subLiteral(nasty);
      subject.beginTick();
      final body = subject.bodyFor(changesOver(1), const {}, const []);
      final frame = subject.updateFrame(sub: sub, seq: 3, t: 9, generation: 1, body: body);

      final params = UpdateParams.fromJson(paramsOf(frame));
      expect(params.sub, nasty,
          reason: 'the subscription name is client-chosen text spliced into a '
              'frame we build by hand; unescaped, a client could write its own '
              'JSON-RPC message into our output stream');
      expect(params.seq, 3);
    });

    test('each client\'s frame carries its own subscription generation', () {
      final a = subject.subLiteral('line1');
      final b = subject.subLiteral('line2');
      subject.beginTick();
      final body = subject.bodyFor(changesOver(3), const {}, const []);

      // The same tick, the same body, two subscriptions at different points in
      // their own lives — one of them has just been re-established.
      final frameA =
          subject.updateFrame(sub: a, seq: 1, t: 1, generation: 1, body: body);
      final frameB =
          subject.updateFrame(sub: b, seq: 1, t: 1, generation: 4, body: body);

      expect(UpdateParams.fromJson(paramsOf(frameA)).generation, 1);
      expect(UpdateParams.fromJson(paramsOf(frameB)).generation, 4,
          reason: 'the generation is per subscription, so it belongs in the '
              'envelope with sub and seq and not in the shared body — where it '
              'would split the encode cache two panels are meant to share');
    });

    test('escaping a subscription name is once-per-session work', () {
      final sub = subject.subLiteral('line1');
      encoder.reset();
      subject.beginTick();
      final body = subject.bodyFor(changesOver(2), const {}, const []);
      encoder.reset();

      for (var i = 0; i < 10; i++) {
        subject.updateFrame(sub: sub, seq: i, t: 1, generation: 1, body: body);
      }

      expect(encoder.calls, 0,
          reason: 'per-tick envelope assembly is concatenation only; an encode '
              'hiding in here scales with clients and undoes the whole point');
    });
  });
}
