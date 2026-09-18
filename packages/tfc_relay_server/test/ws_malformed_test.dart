/// The server's decode boundary, driven by the only tool that reaches it.
///
/// `ws_fault_test.dart` breaks bytes and proves the session tears down; it
/// cannot prove anything about the decoder, because RFC 6455's UTF-8 validation
/// sits in front of the decoder and drops the frame with a 1007 (03-RESEARCH
/// Finding 12). `MalformedPeer` corrupts at the **message** level, so every
/// frame it produces is a well-formed WebSocket frame carrying malformed
/// contents — which is exactly, and only, what arrives at
/// `RelaySession`'s decode path. Phase 1's review found the decode boundary was
/// 5 of 5 Critical findings (STATE.md); this file is the server's.
///
/// ## Two rules copied from `malformed_peer_test.dart`, verbatim in intent
///
/// **Never a throws-matcher for a hang.** `json_rpc_2.Peer` wraps its channel
/// in `respondToFormatExceptions`: a frame it cannot parse is answered with
/// `-32700` to the *sender* and the peer carries on, and the caller waiting on
/// a request is never told anything at all. Nine of the thirteen catalogued
/// corruptions therefore leave a request unsettled **forever** with the link
/// still healthy. A hang is asserted here by converting a deadline into a bool
/// and asserting on the bool; a throws-matcher would be asserting that
/// something happened, which is the opposite of the property.
///
/// **Every budget is short and named**, so silence fails fast and the failure
/// names the property instead of the runner's 30-second timeout.
///
/// ## The closing property, which is the point of the file
///
/// A malformed frame may take **one request** down invisibly. It may not wedge
/// the session. So every case ends the same way: the session is still
/// registered, and a following *valid* request still gets its answer inside a
/// budget. That second half is what separates "the decoder rejected something"
/// from "the decoder rejected something and the client is now talking to a
/// corpse".
///
/// ## The highest-risk case in the phase
///
/// `poisonNumber` — `1e999` — is RESEARCH R7 and Pitfall 7, and it has its own
/// named case rather than living only in the sweep. `jsonDecode('1e999')`
/// yields `Infinity` silently, and `RpcException.serialize` copies the
/// offending **request** into `error.data` unless `data.request` is already set
/// (`json_rpc_2-4.1.0/lib/src/exception.dart:46-57`). An error response
/// carrying an Infinity cannot be encoded, so it is discarded *inside* the
/// Peer, and the caller waits forever on a path that has no deadline — Phase 4
/// owns deadlines and does not exist yet. `relay_session.dart`'s
/// `_answer`/`_substitute` is the mitigation (T-03-28) and this case is its
/// teeth: delete `_substitute` and this case fails on its budget rather than
/// passing quietly.
@Tags(['ws'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
// `subscriptionCount` is an extension on `SessionRegistry`; the registry
// itself arrives through the harness.
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/subscription_registry.dart';
// The catalogue and `oversizeBytes` live behind the channel-harness entry, not
// the contract barrel.
import 'package:tfc_stateman_contract/channel_harness.dart';

import 'support/bands.dart';
import 'support/ws_harness.dart';

/// A plant key the server will accept in a subscribe.
const _key = 'CN01.MOT01.speed';

/// How long a following **valid** request has to be answered.
///
/// The whole file's closing property runs on this budget. Ten times the
/// platform [ceiling] so a slow runner widens it in step with the rest of the
/// package rather than by a number chosen here; the tick is 50 ms and is also
/// the response pump (`ws_harness.dart:57-63`), so this is several pumps wide.
final _answerBudget = ceiling * 10;

/// How long the `1e999` error has to reach the client.
///
/// The same budget as an ordinary answer, deliberately: the property is that a
/// failing request fails *like a request*, not that it fails eventually. When
/// `_substitute` is removed this budget is what the case dies on.
final _poisonBudget = ceiling * 10;

/// How long an 8 MiB frame gets to cross loopback and be dealt with.
///
/// Wider than the others because this one is a measurement of a megabyte-scale
/// transfer rather than of a decision, and a budget sized for a decision would
/// make the case a flaky test of the runner's disk-free memory bandwidth.
final _oversizeBudget = ceiling * 40;

/// How deeply the poisoned frame nests, against a [maxValueDepth] of 64.
///
/// Comfortably past rather than one over: the property is "the sanitizer threw
/// and the boundary refused", not "the ceiling is exactly 64", and an
/// off-by-one here would make the case a test of the constant instead of the
/// behaviour.
const _pastTheCeiling = 200;

/// How much padding the poisoned frame carries, as the amplification's
/// measure.
///
/// 64 KiB rather than the 1 MiB the ingress ceiling actually permits, because
/// this case runs on every CI machine and the property does not need the full
/// megabyte to be visible — a refusal that echoed this would be three orders
/// of magnitude over [_refusalCeilingBytes].
const _padBytes = 64 * 1024;

/// How large a refusal for an unsanitizable frame may be.
///
/// A parse error with no source is a few hundred bytes of JSON. The bound is
/// generous enough that a reworded message does not fail the case and tight
/// enough that any echo of the frame does.
const _refusalCeilingBytes = 2048;

/// The corruptions this run actually drove, filled by the sweep.
///
/// The anti-vacuity arm reads it: a sweep that iterated nothing passes every
/// assertion it never made, and a catalogue entry added in a later phase with
/// no case here would be invisible without this.
final _exercised = <String>{};

void main() {
  group('every catalogued corruption leaves the session answering', () {
    for (final entry in malformedPeerCatalogue.entries) {
      test('${entry.key} takes one request down and leaves the session up',
          () async {
        final fixture = relayFixture();
        await fixture.ready;
        await fixture.hello();

        final sessions = fixture.server.sessions;
        final priorSessions = sessions.sessionCount;

        // A valid request, corrupted on its way out. Sent on the raw socket
        // rather than through the fixture's peer, because the peer would
        // refuse to encode several of these — and because a corruption the
        // sender's own encoder had to accept is not a corruption a peer can
        // actually receive.
        fixture.client.sink.add(entry.value(_request('sweep-${entry.key}')));

        // Several turns before the count is read: a session killed by the
        // corrupt frame dies asynchronously, so an assertion made in the same
        // turn as the send would pass against a server that was already
        // tearing the session down.
        await pumpEventQueue(times: 5);

        expect(sessions.sessionCount, priorSessions,
            reason: 'a malformed frame takes one request down; a session that '
                'disappeared here means the decode boundary answers bad input '
                'by dropping the client, and a panel would be reconnecting '
                'once per corrupt frame');

        expect(await _stillAnswers(fixture), isTrue,
            reason: 'the session stopped answering after a ${entry.key} frame '
                '— the corruption did not take one request down, it wedged '
                'the link, which is the failure this whole file exists to '
                'catch');

        // An error escaping into the ambient isolate is attributed by
        // package:test to whichever case is running when it lands, so the
        // turns given here are what make that failure land on this case.
        await pumpEventQueue(times: 5);

        _exercised.add(entry.key);
      }, timeout: const Timeout.factor(2));
    }
  });

  test('the sweep drove every catalogued corruption', () {
    expect(_exercised, isNotEmpty,
        reason: 'a sweep that iterated nothing passes every assertion it never '
            'made');
    expect(_exercised.length, malformedPeerCatalogue.length,
        reason: 'every entry in the catalogue must have been driven against '
            'the server: a corruption added in a later phase is covered here '
            'automatically only while this equality holds');
    expect(_exercised, malformedPeerCatalogue.keys.toSet(),
        reason: 'the driven set and the catalogue must be the same names, not '
            'merely the same size');
  });

  group('the corruptions with their own consequences', () {
    test('a handler throwing on a request carrying 1e999 still delivers an '
        'error over a real socket', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();

      // `1e999` is written as text because there is no way to reach it through
      // `jsonEncode` — encoding an Infinity is exactly what throws, which is
      // the asymmetry the whole trap is built on. `sub` is where a String
      // belongs, so decoding this drives the handler into a TypeError and
      // `_answer` has to turn that into an error the client can receive.
      const id = 'poison-1';
      fixture.client.sink.add('{"jsonrpc":"2.0","id":"$id",'
          '"method":"${Methods.subscribe}","params":'
          '{"sub":1e999,"keys":["$_key"]}}');

      final delivered =
          await _untilFrame(fixture, '"$id"', budget: _poisonBudget);

      expect(delivered, isTrue,
          reason: 'the caller was never told its request failed. An error '
              'response that echoes a request carrying Infinity cannot be '
              'encoded, so json_rpc_2 discards it inside the Peer and the '
              'caller waits forever — Phase 4 owns deadlines and does not '
              'exist yet, so forever is the literal duration. '
              'relay_session.dart\'s _substitute is what keeps the answer '
              'sendable; this case is what notices when it is gone');

      expect(await _stillAnswers(fixture), isTrue,
          reason: 'a poisoned request must cost one request, not the session');
    });

    test('an oversized frame does not kill the session', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();

      final sessions = fixture.server.sessions;
      final priorSessions = sessions.sessionCount;

      // A genuine oversized *request* — padded inside `params`, so the server
      // decodes and dispatches it rather than routing it to the client half as
      // a stray response.
      final pad = 'x' * oversizeBytes;
      fixture.client.sink.add('{"jsonrpc":"2.0","id":"oversize-1",'
          '"method":"${Methods.ping}","params":{"pad":${jsonEncode(pad)}}}');

      // **The request's own fate, which is what this case was missing**
      // (03-REVIEW WR-03). Until the ceiling landed, an 8 MiB request was
      // answered in full and this case asserted only that the session
      // survived — which any sane ceiling also preserves, so the case could
      // not have noticed the change it was written to notice.
      //
      // The refusal is a parse error rather than an answer to "oversize-1":
      // the ceiling is enforced before anything decodes the frame, so at the
      // moment of refusal the server does not yet know the request had an id.
      // That is the honest shape — a size limit that had to parse the frame to
      // apply it would be no limit at all.
      expect(
          await _untilFrame(fixture, '"error"', budget: _oversizeBudget),
          isTrue,
          reason: 'an ${oversizeBytes ~/ (1024 * 1024)} MiB frame is over the '
              'ingress ceiling and must be refused rather than served. The '
              'refusal itself carries no echo of the frame: json_rpc_2 answers '
              'a FormatException with exception.serialize(source), and a '
              'source of null is what keeps the refusal from being as large as '
              'the thing it refuses');
      expect(fixture.inbound.any((frame) => frame.contains('oversize-1')),
          isFalse,
          reason: 'nothing that comes back may carry the oversized request '
              'back with it — echoing it is the amplification the ceiling '
              'exists to stop, and it would arrive on the priority lane');

      expect(await _stillAnswers(fixture, budget: _oversizeBudget), isTrue,
          reason: 'an 8 MiB frame must cost at most the request that carried '
              'it; a session that died here would let one oversized query '
              'from one panel disconnect that panel every time it retried');
      expect(sessions.sessionCount, priorSessions,
          reason: 'the oversized frame must not take the session with it');
    }, timeout: const Timeout.factor(4));

    test('two documents concatenated in one frame leave the session answering',
        () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();

      final sessions = fixture.server.sessions;
      final priorSessions = sessions.sessionCount;

      // A framing bug that concatenated two documents. Neither copy is valid
      // JSON in the same frame, so *both* are lost — including the first,
      // which on its own would have been answered.
      final one = _request('duplicate-1');
      fixture.client.sink.add('$one$one');

      expect(await _stillAnswers(fixture), isTrue,
          reason: 'a concatenated frame is a framing bug on the client side; '
              'the server must reject it and keep serving, not treat it as a '
              'reason to end the session');
      expect(sessions.sessionCount, priorSessions,
          reason: 'the concatenated frame must not take the session with it');
      expect(sessions.subscriptionCount, 0,
          reason: 'a rejected frame must not have changed any state on the '
              'way to being rejected');
    });
  });

  group('the server can say what went wrong', () {
    // 03-REVIEW WR-10. Nothing in this package logged, and `rpc.Peer` was
    // built without `onUnhandledError`, whose documented behaviour when absent
    // is that "the exception will be swallowed"
    // (json_rpc_2-4.1.0/lib/src/server.dart:56-61). A handler that failed
    // while answering a *notification* is the shape that still cannot reach
    // the client — there is no request to fail — so it is the one that proves
    // the seam.
    test('a handler that fails on a notification is reported, not swallowed',
        () async {
      final reported = <String>[];
      final fixture =
          relayFixture(onError: (error, stack, where) => reported.add(where));
      await fixture.ready;
      await fixture.hello();

      // No `id`: a JSON-RPC notification. json_rpc_2 runs the handler and
      // discards the refusal, because there is nowhere to send it.
      fixture.client.sink.add('{"jsonrpc":"2.0","method":"${Methods.subscribe}",'
          '"params":{"sub":"","keys":["$_key"]}}');
      expect(await _stillAnswers(fixture), isTrue,
          reason: 'a failed notification costs nothing on the wire');

      expect(reported, contains('session peer'),
          reason: 'every failure the Phase 3 review found was invisible from '
              'the server side. For a gateway whose whole claim is that '
              'operators can trust what the screen shows, "the server cannot '
              'say what went wrong" is a gap of the same family as the ones '
              'this package carefully closes elsewhere');
    });
  });

  // ## The sibling-field arm (03-REVIEW CR-01 / CR-02)
  //
  // The `poison-1` case above puts `1e999` where a *String* belongs, so the
  // typed decode throws a TypeError and `_answer`'s TypeError arm — which
  // always substituted — catches it. That is one arm of the trap and it was
  // the only one covered, which is why six handler refusals and two whole
  // json_rpc_2-owned paths shipped able to hang a client.
  //
  // These cases put the poison in a sibling field the refusal never reads. The
  // request is therefore *valid* right up to the point where the server
  // refuses it for an unrelated reason, and the refusal is the frame that
  // cannot be encoded. Every one of them was reproduced against the real
  // server over a real socket before the fix; each `delivered=false` was a
  // client waiting forever on a healthy link.
  group('a refusal whose request carries 1e999 in a field it never reads '
      'still reaches the client', () {
    Future<void> arrives(RelayFixture fixture, String id, String frame,
        {required String refusal}) async {
      fixture.client.sink.add(frame);
      expect(await _untilFrame(fixture, '"$id"', budget: _poisonBudget), isTrue,
          reason: 'the $refusal never reached the client. The refusal itself '
              'is encodable; what is not is the raw request json_rpc_2 echoes '
              'into `error.data` when the thrower supplied no `data` of its '
              'own (exception.dart:46-57). The echo is discarded inside the '
              'Peer and the caller waits forever — relay_session.dart\'s '
              '_answer rebuild, its registered fallback and its ingress '
              '_defuse are the three mitigations, and this is what notices '
              'when one of them is gone');
      expect(await _stillAnswers(fixture), isTrue,
          reason: 'a poisoned request must cost one request, not the session');
    }

    test('subscribe refuses an empty "sub"', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      await arrives(
          fixture,
          'sibling-empty-sub',
          '{"jsonrpc":"2.0","id":"sibling-empty-sub",'
              '"method":"${Methods.subscribe}","params":{"sub":"",'
              '"keys":["$_key"],"maxRateHz":1e999}}',
          refusal: 'empty-"sub" refusal');
    });

    test('subscribe refuses a duplicate "sub"', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      await fixture.request(Methods.subscribe,
          params: {'sub': 'page-1', 'keys': [_key]});
      await arrives(
          fixture,
          'sibling-duplicate',
          '{"jsonrpc":"2.0","id":"sibling-duplicate",'
              '"method":"${Methods.subscribe}","params":{"sub":"page-1",'
              '"keys":["$_key"],"maxRateHz":1e999}}',
          refusal: 'duplicate-"sub" refusal');
    });

    test('subscribe refuses more keys than the ceiling allows', () async {
      final fixture = relayFixture(
          config: ServerConfig(
              tick: ServerConfig.minTick, maxKeysPerSubscribe: 1));
      await fixture.ready;
      await fixture.hello();
      await arrives(
          fixture,
          'sibling-too-many-keys',
          '{"jsonrpc":"2.0","id":"sibling-too-many-keys",'
              '"method":"${Methods.subscribe}","params":{"sub":"page-2",'
              '"keys":["$_key","CN01.MOT01.running"],"maxRateHz":1e999}}',
          refusal: 'over-limit-keys refusal');
    });

    test('subscribe refuses a session already at its subscription ceiling',
        () async {
      final fixture = relayFixture(
          config: ServerConfig(
              tick: ServerConfig.minTick, maxSubscriptionsPerSession: 1));
      await fixture.ready;
      await fixture.hello();
      await fixture.request(Methods.subscribe,
          params: {'sub': 'page-1', 'keys': [_key]});
      await arrives(
          fixture,
          'sibling-at-capacity',
          '{"jsonrpc":"2.0","id":"sibling-at-capacity",'
              '"method":"${Methods.subscribe}","params":{"sub":"page-2",'
              '"keys":["$_key"],"maxRateHz":1e999}}',
          refusal: 'at-capacity refusal');
    });

    test('unsubscribe refuses a name it has never heard of', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      await arrives(
          fixture,
          'sibling-unknown-sub',
          '{"jsonrpc":"2.0","id":"sibling-unknown-sub",'
              '"method":"${Methods.unsubscribe}",'
              '"params":{"sub":"never-existed","junk":1e999}}',
          refusal: 'unknown-subscription refusal');
    });

    // The two paths with no handler at all. Before the fix neither had any
    // armor: the session registered no fallback, so `Server._tryFallbacks`
    // threw a data-less methodNotFound, and nothing at all stands between a
    // client and `Server._validateRequest`.
    test('an unknown method name is refused rather than swallowed', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      await arrives(
          fixture,
          'sibling-unknown-method',
          '{"jsonrpc":"2.0","id":"sibling-unknown-method",'
              '"method":"nope.notAMethod","params":{"x":1e999}}',
          refusal: 'method-not-found refusal');
    });

    test('an envelope json_rpc_2 itself rejects is refused rather than '
        'swallowed', () async {
      final fixture = relayFixture();
      await fixture.ready;
      // Deliberately no hello: this shape needs no valid method name and no
      // gated handler, so it is reachable by anything that can open a socket.
      // That is what made it the widest of the four reproductions.
      await arrives(
          fixture,
          'sibling-no-method',
          '{"jsonrpc":"2.0","id":"sibling-no-method","params":{"x":1e999}}',
          refusal: 'invalid-request refusal');
    });

    test('a frame the sanitizer cannot process is refused, and the session '
        'survives it', () async {
      final fixture = relayFixture();
      await fixture.ready;
      // Deliberately no hello. This is the widest shape in the file: 06-RESEARCH
      // §H.1 measured that every non-hello method is refused before the
      // handshake, but `_defuse` runs on the *stream*, in front of the gate and
      // in front of json_rpc_2's own decode, so it is reachable by anything
      // that can complete the WebSocket upgrade.

      final sessions = fixture.server.sessions;
      final priorSessions = sessions.sessionCount;
      final priorFrames = fixture.inbound.length;

      // The three ingredients §H.2 measured together, and each is load-bearing.
      // Nested past `maxValueDepth` so `sanitize` throws; `1e999` so the echo
      // json_rpc_2 would build cannot be encoded; an unknown method so the
      // answer is built by `Server._tryFallbacks`, whose `data == null` is what
      // `serialize` fills with the raw request. The pad is the amplification:
      // up to `maxFrameBytes` of `params` echoed into the priority lane by a
      // peer that has not authenticated.
      final pad = 'x' * _padBytes;
      fixture.client.sink.add('{"jsonrpc":"2.0","id":"unsanitizable-1",'
          '"method":"nope.notAMethod","params":{"pad":${jsonEncode(pad)},'
          '"deep":${_nested(_pastTheCeiling, '1e999')}}}');

      expect(await _untilFrame(fixture, '"error"', budget: _poisonBudget),
          isTrue,
          reason: 'nothing came back at all. `sanitize` throws on a value '
              'nested past maxValueDepth, `_defuse` used to answer that by '
              'returning the frame unchanged, and the frame then reached '
              'json_rpc_2 intact: answered -32601 with the raw request echoed '
              'into error.data, which carries an Infinity, which jsonEncode '
              'refuses. The refusal is discarded inside the Peer and a caller '
              'without a deadline waits forever — the 02-05 hang, reachable '
              'before hello by anything that can open a socket');

      final refusals = fixture.inbound
          .skip(priorFrames)
          .where((frame) => frame.contains('"error"'))
          .toList();
      expect(refusals, isNotEmpty);
      for (final refusal in refusals) {
        expect(refusal.contains(pad), isFalse,
            reason: 'the refusal carried the padding back with it. That is the '
                'amplification T-06-17 names: ${_padBytes ~/ 1024} KiB in, the '
                'same out, into the priority lane, from a peer that never '
                'said hello — and the ingress ceiling allows up to a megabyte '
                'of it per frame');
        expect(refusal.length, lessThan(_refusalCeilingBytes),
            reason: 'the refusal is ${refusal.length} bytes. A refusal must '
                'cost the sender more than it costs this gateway, and the '
                'shape that guarantees it is a FormatException with no '
                'source — exactly what _underCeiling already throws');
      }

      expect(sessions.sessionCount, priorSessions,
          reason: 'an unsanitizable frame must cost the request, not the '
              'panel. That is the property the old pass-through was written '
              'to protect, and it is kept rather than traded');
      expect(await _stillAnswers(fixture), isTrue,
          reason: 'the session stopped answering after a poisoned frame. '
              'A per-request refusal that wedges the link is not a refusal, '
              'it is a kill switch reachable before the handshake');
    }, timeout: const Timeout.factor(2));

    test('every method except hello is refused before the handshake',
        () async {
      // A deliberately generous pre-hello window, and it is a statement about
      // this **sweep** rather than about the gateway (16-09).
      //
      // The case below sends one request per registered name — forty-odd of
      // them — before the handshake, each waiting a tick for its answer:
      // several seconds of un-helloed conversation that no panel has ever had.
      // `ServerConfig.preHelloDeadline` is an age since the upgrade and
      // deliberately does *not* move on pre-hello traffic (`_LastSeen.touch`,
      // 05-REVIEW WR-03: a peer shouting at a gate that keeps refusing it must
      // not be able to hold its own session open). So at the shipping 2 s the
      // gateway takes the socket back halfway through the sweep and this case
      // starts measuring the deadline instead of the gate.
      //
      // Raised through `heartbeatDeadline` rather than by setting
      // `preHelloDeadline` directly, so the derivation is the thing carrying
      // it: 30 s of heartbeat is 10 s of pre-hello, and the ping interval
      // moves with it because the constructor insists the deadline stay
      // inside it.
      final fixture = relayFixture(
          config: ServerConfig(
        tick: ServerConfig.minTick,
        heartbeatDeadline: const Duration(seconds: 30),
        pingInterval: const Duration(seconds: 60),
      ));
      await fixture.ready;

      // A **sweep, not a list** (06-RESEARCH §H.5). Phase 10 adds browse,
      // timeseries, historyViews and preferences to this table; written as a
      // literal, this case would keep passing while covering none of them, and
      // the forgotten one is the method that serves plant data to a peer that
      // never authenticated.
      final session = fixture.server.sessions.sessions.single;
      final registered = session.registeredMethods;
      final refusable = registered
          .where((method) =>
              method != Methods.hello && method != Methods.holdTick)
          .toList();

      expect(refusable, hasLength(registered.length - 2),
          reason: 'exactly two names are exempt from the request sweep — '
              'hello, which is the handshake, and the holdTick notification, '
              'which has no id for a refusal to name. A third exemption '
              'appearing here means a method was added outside both, so this '
              'guard is what keeps the sweep from quietly shrinking');
      expect(refusable, isNotEmpty,
          reason: 'a sweep that iterated nothing passes every assertion it '
              'never made');

      for (final method in refusable) {
        final error = await fixture.refusal(method,
            params: const <String, Object?>{},
            what: 'a pre-hello "$method"');
        expect(error.code, ServerErrorCodes.helloRequired,
            reason: '"$method" answered ${error.code} before the handshake. '
                'An unauthenticated session may do exactly one thing — say '
                'hello — and every other name must say so with the same code, '
                'or a client cannot tell "authenticate first" from "this '
                'server is broken"');
        expect(error.message, contains('hello_required'),
            reason: '"$method" refused without naming the reason, so the '
                'panel has nothing to log and nothing to act on');
        expect(_asMap(error.data)['request'], isA<String>(),
            reason: '"$method"\'s pre-hello refusal echoes the request. Every '
                'refusal on this wire carries a pre-substituted request, or '
                'one carrying 1e999 makes the refusal itself unencodable');
      }

      // **The exempt notification is covered rather than merely excluded**
      // (D-P5-H). Its refusal evaporates — there is no id to answer — so what
      // is asserted is the other half: it was dropped and counted, and it did
      // not reach a hold.
      fixture.client.sink.add(
          '{"jsonrpc":"2.0","method":"${Methods.holdTick}",'
          '"params":{"key":"$_key","n":1}}');
      await pumpEventQueue(times: 5);
      expect(session.registeredMethods, contains(Methods.holdTick),
          reason: 'the exempt name must still be on the table this sweep read '
              'its exemption from');

      expect(fixture.observedClose.closeCode, isNull,
          reason: 'refusing every method before hello must leave the socket '
              'open. Home Assistant\'s pre-auth rule, and the reason the '
              'reaper — not the gate — is what takes an idle unauthenticated '
              'session back');
      await fixture.hello();
    }, timeout: const Timeout.factor(2));

    // The behavioural cases above are what bite; this one is what keeps the
    // *shape* from coming back. 06-04's plan states the property as a grep
    // over the whole file — `return frame;` appearing exactly once — but the
    // file has two more of them that have nothing to do with the decoder
    // (`_LastSeen.touch`, the liveness tap, and `_underCeiling`'s
    // under-the-ceiling fast path), so the number in the plan is unreachable
    // without deleting unrelated code. Scoped to the one method, it is a real
    // pin and it lives here rather than in a plan document, where it can rot.
    test('_defuse has no catch-all pass-through left in it', () {
      final source = File('lib/src/relay_session.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      final start = source.indexOf('static String _defuse(String frame) {');
      expect(start, isNot(-1),
          reason: 'the method this case pins has been renamed or removed; the '
              'pin has to move with it rather than passing vacuously');
      final body = source.substring(start, source.indexOf('\n  }', start));

      expect('return frame;'.allMatches(body), hasLength(1),
          reason: '_defuse has ${'return frame;'.allMatches(body).length} '
              'pass-through returns. Exactly one is correct — the '
              '`if (!sanitized.hadNonFinite) return frame;` fast path, which '
              'is a frame that needed no defusing. A second one is the '
              'catch-all this plan removed: it hands a frame the sanitizer '
              'threw on straight to json_rpc_2, which echoes it back '
              'unencodably, and a peer that never said hello gets both a '
              'megabyte-scale amplification and the 02-05 hang out of it');
      expect(body, contains('throw FormatException('),
          reason: 'the refusal must be a sourceless FormatException — '
              '_underCeiling\'s shape, and the only one json_rpc_2 answers '
              'with -32700 while leaving the session alive');
    });

    test('an id that is itself non-finite still produces an answer', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      // `RpcException.serialize` copies the request's `id` into the response
      // and accepts any `num` (exception.dart:60) — Infinity is one. No
      // amount of care about `data` helps here; only defusing the frame before
      // the Peer decodes it does. The id arrives as null, so the needle is the
      // error code rather than the id.
      fixture.client.sink.add('{"jsonrpc":"2.0","id":1e999,'
          '"method":"nope.notAMethod","params":{}}');
      expect(
          await _untilFrame(fixture, '"error"', budget: _poisonBudget), isTrue,
          reason: 'a request whose own id is Infinity must still be answered: '
              'the id is sanitized to null at the boundary, which is the only '
              'place it can be, and a null id is what JSON-RPC says an error '
              'with an unusable id carries');
      expect(await _stillAnswers(fixture), isTrue,
          reason: 'a poisoned id must cost one request, not the session');
    });
  });
}

/// A valid JSON-RPC request, as the text a corruption is applied to.
String _request(String id) =>
    '{"jsonrpc":"2.0","id":"$id","method":"${Methods.ping}"}';

/// [leaf] wrapped in [depth] JSON arrays, as text.
///
/// Written rather than built and encoded, for the same reason `1e999` is
/// written: `jsonEncode` is exactly what refuses the value at the middle of
/// this, so the frame cannot be produced by the encoder a client would use.
String _nested(int depth, String leaf) => '${'[' * depth}$leaf${']' * depth}';

/// One decoded JSON object, cast where json_rpc_2 hands back `Object?`.
Map<String, Object?> _asMap(Object? raw) =>
    (raw! as Map).cast<String, Object?>();

/// Whether a following **valid** request is answered inside [budget].
///
/// The closing property of every case in this file, in one place so that all
/// of them mean the same thing by it. A deadline converted into a bool: silence
/// is the failure mode being guarded against, and a matcher cannot express it.
Future<bool> _stillAnswers(RelayFixture fixture, {Duration? budget}) async {
  final within = budget ?? _answerBudget;
  try {
    await fixture.request(Methods.ping, budget: within);
    return true;
  } on rpc.RpcException {
    // An *error* answer is still an answer: the server was reachable, it
    // decided, and it replied. Only a session that says nothing is wedged.
    return true;
  } catch (_) {
    // Everything else is a session that did not answer, and the distinction is
    // load-bearing rather than defensive. A blanket `return true` here reads as
    // "it threw, so it was alive", which is exactly backwards: a peer whose
    // stream has errored, or a sink that has been closed under it, throws
    // *synchronously* and instantly — so a dead session would score as the
    // liveliest one in the file. That version of this helper passed against a
    // deliberately broken server during this plan's RED run, which is why the
    // clause above is narrowed to the one exception that means "answered".
    // `within()`'s TestFailure for silence lands here too, and means the same
    // thing: no answer.
    return false;
  }
}

/// Whether a frame containing [needle] reaches the client inside [budget].
///
/// Reads `fixture.inbound` rather than awaiting a peer request, because the
/// requests these cases send are written straight onto the socket — the
/// fixture's own peer has no pending entry for their ids and would discard the
/// answers. A deadline turned into a bool, for the same reason as everywhere
/// else here.
Future<bool> _untilFrame(RelayFixture fixture, String needle,
    {required Duration budget}) async {
  final deadline = DateTime.now().add(budget);
  while (!fixture.inbound.any((frame) => frame.contains(needle))) {
    if (DateTime.now().isAfter(deadline)) return false;
    await pumpEventQueue(times: 1);
  }
  return true;
}
