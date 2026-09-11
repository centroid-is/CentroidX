/// What this gateway answers about a tag its source does not serve.
///
/// **Source: 06-RESEARCH §E.1**, a probe executed against a live `RelayServer`
/// over a real socket. It measured every surface and found two with no answer
/// at all:
///
///  * `readFresh` forwarded straight to `api.readFresh` and reported whatever
///    the source said — `{"v":null,"q":258}` on the fake, with **no `rejected`
///    map** — where `read` answered `q:770` plus `KeyReject(unknownKey)`. Two
///    read methods disagreeing about one tag is the divergence 04-REVIEW WR-11
///    already fixed once, between `read` and `readMany`.
///  * `write` was worse than unchecked: it **applied and created the key**
///    (`{"outcome":"applied","readback":1}`, and `api.keys` gained the tag).
///
/// ## What breaks in the plant without this file
///
/// A page config carries ~1500 hand-edited tag names. When one of them is a
/// typo, or names a tag an upstream engineer renamed last Tuesday, the panel
/// has to be told so — and told the *same* thing by whichever read method the
/// widget happens to use. A `readFresh` answering `uncertainNotYetKnown` says
/// "wait, it is coming", so the tag renders as merely quiet and the typo
/// survives on the page for months. That is the stale-but-plausible failure
/// PROJECT.md exists to prevent, arriving through the one method whose entire
/// purpose is to settle whether a value is real.
///
/// The write half is heavier. A write to a tag the source does not serve used
/// to *create* it: the operator got "applied", the readback confirmed it, and
/// nothing at all had happened in the plant. On a safety-relevant path a
/// gateway that invents a tag rather than refusing is the worst available
/// option — the one three-state outcome an operator cannot act on is a false
/// "applied".
///
/// ## Why the agreement is asserted against itself
///
/// The first case compares `read`'s answer to `readFresh`'s **field by field**
/// rather than against hard-coded literals. A later phase is free to change
/// the shape — 06-08's hiding rule imitates it, and Phase 10 adds surfaces —
/// and the property that must survive all of it is that the two read methods
/// say the same thing about the same tag. A literal would go stale; this does
/// not.
@Tags(['ws'])
library;

import 'package:json_rpc_2/error_code.dart' as rpc_error;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
// `KeyRejectKinds` is the server's own vocabulary, not the protocol's, so it
// arrives from the source file rather than from the barrel.
import 'package:tfc_relay_server/src/session_handlers.dart' show KeyRejectKinds;

import 'support/ws_harness.dart';

/// A tag no fixture ever seeds, in the plant's own naming convention so that
/// the case reads like the mistake it models — a real key with a typo in it —
/// rather than like a synthetic string.
const _ghost = 'CN01.MOT01.speeed';

/// A tag the fixture does seed. The control arm of every case here.
const _served = 'CN01.MOT01.speed';

void main() {
  group('the two read methods agree about a tag this source does not serve',
      () {
    test('read and readFresh give the same answer about a tag this source '
        'does not serve', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_served, 1200);

      final fromRead = _asMap(
          await fixture.request(Methods.read, params: {'key': _ghost}));
      final fromFresh = _asMap(
          await fixture.request(Methods.readFresh, params: {'key': _ghost}));

      expect(fromFresh, equals(fromRead),
          reason: 'read and readFresh answered differently about "$_ghost". '
              'One of them is telling the panel the tag is merely quiet and '
              'the other that it does not exist, so which sentence the '
              'operator gets depends on which method the widget happened to '
              'call — and the quiet one is how a renamed PLC tag survives on '
              'a page for months. Asserted against each other rather than '
              'against a literal so that a later phase changing the shape '
              'still has to change both');
    });

    test('the shared answer is the errorConfig one, not the not-yet-known one',
        () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();

      final answer = _asMap(
          await fixture.request(Methods.readFresh, params: {'key': _ghost}));
      final value = _asMap(answer['value']);
      final rejected = _asMap(answer['rejected']);

      expect(value['q'], Quality.errorConfig.code,
          reason: 'readFresh answered quality ${value['q']} for a tag the '
              'source does not serve. 258 (uncertainNotYetKnown) means "no '
              'reading has arrived yet, wait"; 770 (errorConfig) means "the '
              'source affirmatively says this tag is gone". The gateway knows '
              'the second, and only the second is a sentence an engineer can '
              'act on');
      expect(value['v'], isNull,
          reason: 'a tag that does not exist has no reading, and a non-null '
              'value under a bad quality is what a widget renders as a real '
              'number in a warning colour');
      expect(_asMap(rejected[_ghost])['kind'], KeyRejectKinds.unknownKey,
          reason: 'the rejection is keyed by tag and names unknownKey, so a '
              'client decodes it the same way it decodes read\'s and '
              'readMany\'s — 04-REVIEW WR-11 is the divergence that cost');
    });

    test('readFresh on a served key still forces exactly one round trip',
        () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_served, 1200);

      final before = fixture.served.roundTrips;
      final answer = _asMap(
          await fixture.request(Methods.readFresh, params: {'key': _served}));

      expect(fixture.served.roundTrips, before + 1,
          reason: 'an existence check that also swallowed the round trip '
              'would turn "the cache is under suspicion" into "the cache '
              'answers", which is the one thing readFresh exists not to do');
      expect(answer.containsKey('rejected'), isFalse,
          reason: 'a served key carries no rejection map; a client that saw '
              'one would decode a healthy tag as misconfigured');
      expect(_asMap(answer['value'])['v'], 1200,
          reason: 'the forced read must carry the reading the source has');
    });
  });

  group('a write to a tag this source does not serve never reaches the plant',
      () {
    test('a write to a tag this source does not serve is refused, and does '
        'not create it', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_served, 1200);

      final cmd = newUlid();
      final error = await fixture.refusal(Methods.write,
          params: {'cmd': cmd, 'key': _ghost, 'value': 1450},
          what: 'a write naming a tag the source does not serve');

      // **INVALID_PARAMS, not -32005 forbidden** (06-RESEARCH §E.7 rows 2 and
      // 3). Those are different facts and the client behaves differently: a
      // nonexistent tag is a typo to fix, an unauthorized one is a permission
      // to obtain. 06-08 makes a hidden key take this exact path, and a
      // "forbidden" here would leak the existence the hiding rule conceals.
      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'INVALID_PARAMS on this path means "definitively no effect, '
              'safe to re-send", which is exactly true of a refusal raised '
              'before the plant is touched. A code that meant anything else '
              'would tell the panel to leave the operator\'s action '
              'unresolved');
      expect(error.message, _unknownKeyMessage(_ghost),
          reason: 'the refusal carries the same sentence read and readMany '
              'produce for the same tag, byte for byte. 06-08 asserts that a '
              'hidden key is indistinguishable from a nonexistent one, and '
              'two hand-copied strings cannot hold that property');

      final data = _asMap(error.data);
      expect(data['request'], isA<String>(),
          reason: 'RpcException.serialize copies the offending request into '
              'error.data unless data["request"] is already set, and one '
              'carrying 1e999 then makes the error itself unencodable — the '
              'peer drops it and a caller with no deadline waits forever');
      expect(_asMap(_asMap(data['rejected'])[_ghost])['kind'],
          KeyRejectKinds.unknownKey,
          reason: 'the refusal carries the same rejected map, keyed by tag, '
              'that the read surfaces carry, so one decoder reads all four');

      // **Nothing was sent.**
      expect(fixture.served.keys, isNot(contains(_ghost)),
          reason: 'the write created the tag. Before this plan a write to an '
              'unserved key answered "applied" with a readback and api.keys '
              'gained the tag — the operator was told a setpoint took on a '
              'machine that never heard of it, which is the one three-state '
              'answer nobody can act on');
      expect(fixture.served.upstreamWriteAttempts(cmd), 0,
          reason: 'the refusal must be raised above api.write, not below it. '
              'A device consulted before the refusal makes INVALID_PARAMS a '
              'lie about a frame that already reached a contactor');

      // **And nothing was remembered.** The refusal sits above the in-flight
      // pre-record, so the outcome log holds nothing for this cmd — and a
      // freshly minted ULID inside the window is the one case that earns
      // `not_received`, the only re-send-safe answer this gateway gives.
      final status = _asMap(
          await fixture.request(Methods.writeStatus, params: {'cmds': [cmd]}));
      final results = status['results']! as List;
      expect(WriteResult.fromJson(_asMap(results.single)),
          isA<WriteNotReceived>(),
          reason: 'writeStatus found something logged for a write that was '
              'refused before the plant was touched. That means the refusal '
              'was placed below the in-flight pre-record, and the panel\'s '
              'reconnect re-query would then answer "unknown" about an action '
              'that provably never happened');
    });

    test('a hold-to-run engage on a tag this source does not serve is refused '
        'before the hold is taken', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();

      final cmd = newUlid();
      final error = await fixture.refusal(Methods.write,
          params: {'cmd': cmd, 'key': _ghost, 'value': 1, 'hold': true},
          what: 'an engage naming a tag the source does not serve');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, _unknownKeyMessage(_ghost),
          reason: 'one check covers both seams, because api.holdToRun is '
              'reachable only through the write path — so the engage gets the '
              'same sentence the plain write gets');
      expect(fixture.served.keys, isNot(contains(_ghost)),
          reason: 'an engage on a tag nobody serves would put a 1 on a '
              'deadman tag this gateway invented, and then feed it at 10 Hz');
      expect(fixture.served.mintedCmds, isEmpty,
          reason: 'the source was never asked for a handle: the refusal is '
              'above api.holdToRun, which is where "no device was consulted" '
              'stops being a claim and starts being a fact');
    });

    test('a write to a served key is unchanged, replay included', () async {
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_served, 1200);

      final cmd = newUlid();
      final first = _asMap(await fixture.request(Methods.write,
          params: {'cmd': cmd, 'key': _served, 'value': 1450}));
      expect(WriteResult.fromJson(first), isA<WriteApplied>(),
          reason: 'the existence check must cost an unserved tag and nothing '
              'else; a served write that stopped applying would be a jog '
              'button that stopped working');

      // The Stripe semantic, re-asserted here because the new check sits in
      // the same ladder the idempotency window reads from: one press arriving
      // twice is still one press, answered from the log with no second
      // api.write.
      final replay = _asMap(await fixture.request(Methods.write,
          params: {'cmd': cmd, 'key': _served, 'value': 1450}));
      expect(replay, equals(first),
          reason: 'the replay of an applied write must re-adopt the same '
              'readback onto the mimic; a different answer under one id is '
              'two outcomes for one operator action');
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'one press, one movement of the machine');
    });
  });
}

/// The sentence the gateway uses for a tag its source does not serve.
///
/// Spelled out here rather than imported: the property under test is that the
/// server's four surfaces all produce this *same* text, and a test that read
/// the server's own constant would pass no matter what that constant became.
String _unknownKeyMessage(String key) =>
    'this source does not serve "$key" — usually a typo in a page config, '
    'occasionally a tag renamed upstream';

/// One decoded JSON object, cast where the wire hands back `Object?`.
Map<String, Object?> _asMap(Object? raw) =>
    (raw! as Map).cast<String, Object?>();
