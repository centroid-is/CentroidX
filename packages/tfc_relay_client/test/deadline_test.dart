/// The one seam that stops a panel waiting forever.
///
/// Source: 04-RESEARCH Finding 1, four executed experiments against
/// `json_rpc_2` 4.1.0. Row 3 is the one that matters here: a response arriving
/// with a **different id never settles — still pending after 400 ms**, and no
/// close will ever fail it, because the library only fails the requests it
/// knows are outstanding and it has no idea that the answer to id 999999 was
/// supposed to be the answer to id 3.
///
/// What breaks in the plant without it: a gateway that keeps its socket open
/// and answers with the wrong correlation id — the `rewrittenId` entry of
/// `malformed_peer.dart`, which is what a reconnect replaying a queue actually
/// produces — leaves the panel on a spinner with a healthy-looking link. The
/// operator sees no error, no staleness and no values; there is nothing to
/// escalate and nothing to power-cycle. A deadline turns that into a visible
/// failure in one second.
///
/// The cases here are timing cases, so they assert windows and not instants:
/// STATE.md's Phase 2 handoff band, taken at its wider setting (75 ms slack,
/// 150 ms ceiling) so the same numbers hold on a developer's Mac and in Linux
/// CI. The bite is not the upper budget — it is [_deadline] `* 2`: a wrapper
/// that fires late, or twice, or applies the deadline per attempt rather than
/// per call, passes "it eventually threw" and fails that.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/deadline.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

/// The deadline every case below arms. Short enough that the suite stays
/// under a second, long enough to clear the platform band with room.
const Duration _deadline = Duration(milliseconds: 200);

/// STATE.md Phase 2 handoff: 75 ms slack / 150 ms ceiling off Linux. Taken
/// unconditionally, because a band that differs per platform is a band that
/// only ever gets tuned on the platform the author was sitting at.
const Duration _slack = Duration(milliseconds: 150);

/// What a "this must happen" wait is allowed to cost: the deadline plus the
/// band. Deliberately below `_deadline * 2`, so the budget and the bite are
/// not the same assertion wearing two hats.
final Duration _budget = _deadline + _slack;

/// A peer on the other end of an in-memory channel that answers however the
/// case tells it to — correctly, with somebody else's id, late, or not at all.
///
/// This is Finding 1's own experimental rig: a `StreamChannelController` pair
/// with a real `Peer` on the local end, so what is under test is the actual
/// library's correlation logic and not a mock of it.
final class _ScriptedPeer {
  final StreamChannelController<String> _controller;
  late final Peer peer;

  /// Every request this peer was asked, decoded, in order.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  /// Given a decoded request, the raw frame to answer with — or `null` to say
  /// nothing at all, which is the case a deadline exists for.
  String? Function(Map<String, Object?> request) reply;

  /// The controller is deliberately **not** `sync: true`. `json_rpc_2`'s
  /// `Client.sendRequest` calls `_send` at client.dart:131 and only registers
  /// the pending request at client.dart:134, so on a synchronous channel a
  /// reply can arrive before the request it answers is on the books and gets
  /// dropped as an unknown id. A real socket never does that; a sync
  /// controller does, and it would fake the very hang this file is about.
  _ScriptedPeer({required this.reply})
      : _controller = StreamChannelController<String>() {
    peer = Peer(_controller.local);
    // The listen future completes when the channel goes; a close with pending
    // requests is a normal end here, not a test failure.
    unawaited(peer.listen().catchError((Object _) {}));
    _controller.foreign.stream.listen((raw) {
      final request = jsonDecode(raw) as Map<String, Object?>;
      requests.add(request);
      final frame = reply(request);
      if (frame != null) _controller.foreign.sink.add(frame);
    });
  }

  /// Say nothing, ever. Finding 1 row 1's shape without the close.
  static String? silence(Map<String, Object?> request) => null;

  /// A well-formed answer to [request].
  static String answer(Map<String, Object?> request, Object? result) =>
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result});

  /// A well-formed answer to a request nobody made — Finding 1 row 3, the
  /// frame that hangs forever.
  static String answerToNobody(Object? result) =>
      jsonEncode({'jsonrpc': '2.0', 'id': 999999, 'result': result});

  /// Push a frame outside the request/response rhythm, for the late answer.
  void pushFrame(String raw) => _controller.foreign.sink.add(raw);

  Future<void> dispose() => peer.close();
}

/// Builds a scripted peer and tears it down the moment it exists.
_ScriptedPeer _scripted(
  String? Function(Map<String, Object?> request) reply,
) {
  final scripted = _ScriptedPeer(reply: reply);
  addTearDown(scripted.dispose);
  return scripted;
}

void main() {
  group('a request nobody answers stops being a spinner', () {
    test('a response that never comes settles as a deadline expiry', () async {
      final scripted = _scripted(_ScriptedPeer.silence);
      final clock = Stopwatch()..start();

      await within(
        expectLater(
          callWithDeadline(() => scripted.peer, 'read', deadline: _deadline),
          throwsA(isA<TimeoutException>()),
        ),
        'a request the gateway never answers giving up on its own',
        budget: _budget,
      );
      clock.stop();

      expect(
        clock.elapsed,
        lessThan(_deadline * 2),
        reason: 'the deadline fired at ${clock.elapsedMilliseconds} ms for a '
            '${_deadline.inMilliseconds} ms budget: a panel that waits twice '
            'as long as it was told to is a panel whose configured deadline '
            'is a suggestion, and nobody sizing it can reason about it',
      );
    });

    test("a response carrying someone else's id still settles", () async {
      // 04-RESEARCH Finding 1 row 3: measured still pending at 400 ms, and no
      // close will ever fail it. This is the disjoint failure — the one thing
      // link detection cannot see and the whole reason this file exists.
      final scripted =
          _scripted((request) => _ScriptedPeer.answerToNobody('not yours'));
      final clock = Stopwatch()..start();

      await within(
        expectLater(
          callWithDeadline(() => scripted.peer, 'subscribe',
              deadline: _deadline),
          throwsA(isA<TimeoutException>()),
        ),
        'a mismatched-id answer settling instead of hanging forever',
        budget: _budget,
      );
      clock.stop();

      expect(scripted.requests, hasLength(1),
          reason: 'the request has to have actually gone out, or this case '
              'proves the deadline fires on a call that was never made');
      expect(
        clock.elapsed,
        lessThan(_deadline * 2),
        reason: 'Finding 1 measured this frame pending at 400 ms with a live '
            'peer still answering everything else: the operator sees a '
            'healthy link and an empty screen, so the only thing that ends it '
            'is this deadline ending it on time',
      );
    });
  });

  group('a settled call leaves nothing behind', () {
    test('a normal answer settles with the result and nothing fires later',
        () async {
      final scripted =
          _scripted((request) => _ScriptedPeer.answer(request, 42));

      final result = await within(
        callWithDeadline(() => scripted.peer, 'read', deadline: _deadline),
        'an answered call resolving with the answer',
        budget: _budget,
      );
      expect(result, 42);

      // Past the deadline, with the call long settled: a timer that outlived
      // its call would fire in here.
      Object? lateError;
      runZonedGuarded(() {}, (error, _) => lateError = error);
      await Future<void>.delayed(_deadline + _slack);

      expect(lateError, isNull,
          reason: 'a deadline that outlives the call it belongs to is a timer '
              'per RPC leaking across every reconnect, and on a 1500-key page '
              'that is what turns a reconnect into a stall');
      expect(result, 42,
          reason: 'the answer must not be revised by anything that happens '
              'after the call ended');
    });

    test('a late answer after the deadline changes nothing', () async {
      // Finding 1's caveat: `.timeout()` leaves `sendRequest` pending inside
      // the Peer, so the late answer really does arrive. It must land on the
      // floor.
      final scripted = _scripted(_ScriptedPeer.silence);
      Object? settled;
      Object? failure;

      final call = callWithDeadline(() => scripted.peer, 'write',
          deadline: _deadline)
        ..then((value) => settled = value).catchError((Object e) {
          failure = e;
          return null;
        });

      await within(
        expectLater(call, throwsA(isA<TimeoutException>())),
        'the write giving up at its deadline',
        budget: _budget,
      );

      // The answer the gateway was slow with, arriving after the verdict.
      scripted.pushFrame(
          _ScriptedPeer.answer(scripted.requests.single, 'applied'));
      await Future<void>.delayed(_slack);

      expect(settled, isNull,
          reason: 'a timed-out write that later resolves "applied" tells the '
              'operator the machine moved after they were already told the '
              'outcome was unknown and went to look — the screen must not '
              'change its mind behind them');
      expect(failure, isA<TimeoutException>(),
          reason: 'the timeout is the terminal verdict at the call site');

      // And the link itself is still usable: one dead request, not a dead peer.
      scripted.reply = (request) => _ScriptedPeer.answer(request, 'alive');
      expect(
        await within(
          callWithDeadline(() => scripted.peer, 'read', deadline: _deadline),
          'the next question after a late answer',
          budget: _budget,
        ),
        'alive',
      );
    });
  });

  group('the peer is captured before the call, never after', () {
    test('a reconnect during a call does not retarget the request', () async {
      final oldLink =
          _scripted((request) => _ScriptedPeer.answer(request, 'old link'));
      final newLink =
          _scripted((request) => _ScriptedPeer.answer(request, 'new link'));

      // What `_peer` points at, exactly as the supervisor owns it.
      Peer current = oldLink.peer;
      final call =
          callWithDeadline(() => current, 'read', deadline: _deadline);
      // The reconnect lands while the call is in flight.
      current = newLink.peer;

      expect(
        await within(call, 'the in-flight call resolving', budget: _budget),
        'old link',
        reason: 'a wrapper that reads the current peer after awaiting sends '
            'the request down the new socket, where the gateway has no '
            'in-flight state for it — for a write that is a second actuation '
            'of the machinery, which is the one thing this client must never '
            'do on its own',
      );
      expect(newLink.requests, isEmpty,
          reason: 'nothing at all may reach the replacement link on behalf of '
              'a call that started before it existed');
    });
  });

  group('no link at all', () {
    test('calling with no peer fails as link-down, in our own words', () {
      expect(
        () => callWithDeadline(() => null, 'write', deadline: _deadline),
        throwsA(isA<LinkDown>().having((e) => e.method, 'method', 'write')),
        reason: "json_rpc_2's own StateError for this reads 'The client is "
            "closed.', which the failure taxonomy has to tell apart from a "
            'genuine programming error by matching a message string — so the '
            'one case we can name ourselves, we name ourselves',
      );
    });

    test('link-down carries the call it belongs to into its message', () {
      Object? caught;
      try {
        callWithDeadline(() => null, 'subscribe', deadline: _deadline);
      } on LinkDown catch (e) {
        caught = e;
      }
      expect(caught.toString(), contains('subscribe'),
          reason: 'a log line saying only "link down" does not tell the '
              'engineer on the phone which page stopped working');
    });
  });
}
