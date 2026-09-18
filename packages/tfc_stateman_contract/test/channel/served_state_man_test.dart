/// The served half of the channel harness, judged from the far side only.
///
/// Everything asserted here is asserted through a raw `json_rpc_2.Peer` on the
/// other end of a `StreamChannelController` — never by reaching into the
/// `FakeStateMan` being served. That restriction is the point: if this file
/// could read the fake directly it would prove the fake works, which
/// `test/subscribe_contract_test.dart` already does. What is unproven until
/// here is that the *channel* carries the value path at all.
///
/// The notification-count case is the one worth reading twice. `setValues` is
/// documented (`lib/src/harness.dart:56-61`) as the unit the notification-count
/// promise is made about — 1500 keys arriving together cost one pass and k
/// notifications, not 1500 of each — and a served source that forwarded one
/// outbound message per changed key would satisfy every value assertion in this
/// file while turning the store contract's k-of-n property into a claim about
/// the client's deduplication rather than about the batch. So the count is
/// asserted here, at the boundary, where it is still attributable to the server.
@Tags(['meta'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// A motor speed on the pre-freezer conveyor line — the same key the subscribe
/// contract uses, so a failure here reads against the same tag.
const _speedKey = 'ST101.CN01.MOT01.speed';
const _otherKey = 'ST201.CN04.MOT01.speed';

void main() {
  test('serving begins with a snapshot of what the source already holds',
      () async {
    final fake = FakeStateMan();
    addTearDown(fake.dispose);
    fake.setValue(_speedKey, 1450);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    addTearDown(served.close);
    final far = _FarSide(pair.client);
    addTearDown(far.close);

    await within(far.untilUpdates(1), 'the opening snapshot');

    expect(far.updates.first[_speedKey]?.asInt, 1450,
        reason: 'a session that opened with no snapshot would leave every '
            'already-known key dark until it next happened to change — a '
            'slow-moving tank level would stay blank for an hour, which is the '
            'resync-is-a-snapshot rule (CLI-03) stated at connection time');
  });

  test('a read-shaped request is answered with the value the source holds',
      () async {
    final fake = FakeStateMan();
    addTearDown(fake.dispose);
    fake.setValue(_speedKey, 1450);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    addTearDown(served.close);
    final far = _FarSide(pair.client);
    addTearDown(far.close);

    final raw = await within(
        far.peer.sendRequest(HarnessMethods.readFresh, {'key': _speedKey}),
        'the answer to a read over the channel');

    expect(DynamicValue.fromJson((raw as Map).cast<String, Object?>()),
        fake.read(_speedKey),
        reason: 'a request that crossed the channel came back holding '
            'something other than the value the source has; every read the '
            'contract suite makes over this harness would then be measuring '
            'the encoder rather than the source');
  });

  test('a lever applied from the far side reaches the source, and the change '
      'comes back as an equal value', () async {
    final fake = FakeStateMan();
    addTearDown(fake.dispose);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    addTearDown(served.close);
    final far = _FarSide(pair.client);
    addTearDown(far.close);
    await within(far.untilUpdates(1), 'the opening snapshot');

    far.peer.sendNotification(HarnessMethods.setValue, {
      'key': _speedKey,
      'value': 1450,
      'q': Quality.good.code,
    });
    await within(far.untilUpdates(2), 'the update carrying the lever result');

    expect(fake.read(_speedKey)?.asInt, 1450,
        reason: 'the lever never reached the source, so no contract case '
            'running over this harness could make a value arrive');
    expect(far.updates[1][_speedKey], fake.read(_speedKey),
        reason: 'the value that came back is not equal to the one the source '
            'holds. The store contract judges an unchanged re-delivery by '
            '`==`, so a payload that does not round-trip to an equal value '
            'turns every repeat into a spurious rebuild');
  });

  test('two keys changed by one setValues arrive as exactly one notification',
      () async {
    final fake = FakeStateMan();
    addTearDown(fake.dispose);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    addTearDown(served.close);
    final far = _FarSide(pair.client);
    addTearDown(far.close);
    await within(far.untilUpdates(1), 'the opening snapshot');

    far.peer.sendNotification(HarnessMethods.setValues, {
      'values': {_speedKey: 1450, _otherKey: 3},
    });
    await within(far.untilUpdates(2), 'the update carrying the batch');

    // A barrier, not a sleep: a third message could only be in flight behind
    // this one, so a round trip that completes proves the second update is not
    // merely late.
    await within(far.peer.sendRequest(HarnessMethods.keys, const {}),
        'a round trip behind the batch');

    expect(far.updates.length, 2,
        reason: 'one batch of two keys cost ${far.updates.length} outbound '
            'notifications. At 1500 keys on one page that is 1500 messages for '
            'one upstream push, and the k-of-n promise the store contract '
            'measures would be satisfied by the client deduplicating rather '
            'than by the batch being a batch');
    expect(far.updates[1].keys, unorderedEquals([_speedKey, _otherKey]),
        reason: 'the single notification must carry both changed keys, or one '
            'of them was silently dropped rather than batched');
  });

  test('a write is answered with the outcome, not with a throw', () async {
    final fake = FakeStateMan();
    addTearDown(fake.dispose);
    fake.setValue(_speedKey, 1450);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    addTearDown(served.close);
    final far = _FarSide(pair.client);
    addTearDown(far.close);

    final raw = await within(
        far.peer.sendRequest(
            HarnessMethods.write, {'key': _speedKey, 'value': 1600}),
        'the answer to a write over the channel');

    final result = WriteResult.fromJson((raw as Map).cast<String, Object?>());
    expect(result, isA<WriteApplied>(),
        reason: 'a write nothing objected to came back as '
            '${result.runtimeType}; the ordinary case must be the one an '
            'operator can read as "done"');
    expect((result as WriteApplied).readback, 1600,
        reason: 'the served side must encode what the device holds; a '
            'boundary that echoed the written value would confirm a write on '
            'no evidence at all');
    expect(fake.read(_speedKey)?.asInt, 1600,
        reason: 'the write never reached the source, so every write case '
            'running over this harness would be measuring the encoder');
  });

  test('a peer that puts a non-finite number on the write path is answered '
      'with an error, not with silence', () async {
    // Reachable only from a raw frame: `jsonEncode` refuses to *emit* a
    // non-finite, but `1e999` silently *decodes* to Infinity, so the decoder
    // is exactly where poison enters from outside. The answer must be a
    // JSON-RPC error — which on a write means "definitively no effect", the
    // one retry-safe case — rather than a pending request nobody will ever
    // settle. RESEARCH Finding 15: a request with no answer hangs forever,
    // because there is no per-request deadline on this path and will not be
    // one until Phase 4.
    final fake = FakeStateMan();
    addTearDown(fake.dispose);
    fake.setValue(_speedKey, 1450);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    addTearDown(served.close);

    final answered = Completer<Map<String, Object?>>();
    final subscription = pair.client.stream.listen((message) {
      final decoded = jsonDecode(message);
      if (decoded is Map &&
          decoded['id'] == 1 &&
          !answered.isCompleted) {
        answered.complete(decoded.cast<String, Object?>());
      }
    });
    addTearDown(subscription.cancel);

    pair.client.sink.add('{"jsonrpc":"2.0","id":1,'
        '"method":"${HarnessMethods.write}",'
        '"params":{"key":"$_speedKey","value":1600,"expect":1e999}}');

    final reply = await within(answered.future,
        'the answer to a write carrying a non-finite compare-and-set guard');

    expect(reply['error'], isNotNull,
        reason: 'the write came back as a normal result, or not at all. A '
            'non-finite expect nulled on the way in turns a guarded write '
            'into an unconditional one, and a request left unanswered hangs '
            'the caller until something else times out — refusing it by '
            'error is the only answer that is both true and terminating');
    expect(reply['result'], isNull,
        reason: 'a refused write must not also carry an outcome');
    expect(fake.read(_speedKey)?.asInt, 1450,
        reason: 'the refusal must happen before the device is touched; a '
            'write that was refused *and* applied is the worst of both '
            'answers');
  });

  test('closing the channel closes the served peer without throwing',
      () async {
    final fake = FakeStateMan();
    addTearDown(fake.dispose);

    final pair = channelPair();
    final served = serveStateMan(fake, pair.server);
    final far = _FarSide(pair.client);

    await within(far.close(), 'the far side closing');
    await within(served.closed, 'the served peer noticing the channel closed');

    expect(served.isClosed, isTrue,
        reason: 'a served peer that survives its channel keeps the test '
            'isolate alive and keeps a listener on a store nobody is watching, '
            'so a leak in one case surfaces as an inexplicable notification in '
            'the next');
  });
}

/// A raw `json_rpc_2.Peer` on the client end, collecting update notifications.
///
/// Deliberately not `ChannelStateMan` (which does not exist yet at this point
/// in the plan and would, once it does, put the thing under test on both ends
/// of the channel): the server's outbound behaviour has to be observable
/// without a client implementation agreeing with it.
final class _FarSide {
  _FarSide(StreamChannel<String> channel) : peer = rpc.Peer(channel) {
    peer.registerMethod(Methods.update, (rpc.Parameters params) {
      final raw = params['changes'].asMap;
      updates.add({
        for (final entry in raw.entries)
          '${entry.key}': DynamicValue.fromJson(
              (entry.value as Map).cast<String, Object?>()),
      });
      final waiting = _waiting;
      _waiting = null;
      waiting?.complete();
    });
    // The error is swallowed on purpose: a channel that fails must fail the
    // check that named the property, never arrive as an unhandled zone error
    // attributed to whichever test happens to be running when it lands.
    unawaited(peer.listen().catchError((Object _) => null));
  }

  final rpc.Peer peer;
  final updates = <Map<String, DynamicValue>>[];
  Completer<void>? _waiting;

  /// Completes once at least [count] update notifications have arrived.
  Future<void> untilUpdates(int count) async {
    while (updates.length < count) {
      await (_waiting ??= Completer<void>()).future;
    }
  }

  Future<void> close() async {
    await peer.close();
  }
}
