/// The five value methods, judged as handler bodies rather than over a wire.
///
/// They are called here the way `RelaySession._on` calls them — one
/// `rpc.Parameters`, one answer or one `RpcException` — with a hand-cranked
/// clock, because everything the outcome log promises is arithmetic about
/// *when* a command was seen and nothing about how long a test is willing to
/// sleep. Registration is 04-02 task 2's subject and is asserted over a real
/// socket in `surface_test.dart`; what is asserted below is what each body
/// answers once it has been reached.
///
/// Two of these cases exist because the wrong answer is worse than no answer:
///
///  * **`not_received` is a licence to re-actuate.** It is the one outcome
///    that tells an operator a re-send is safe, so a gateway that has merely
///    *forgotten* a command must never spell its amnesia that way. The
///    aged-out case below is the one that separates "we never saw it" from
///    "we no longer remember it".
///  * **A non-finite `expect` is not a value to clean up.** Null is this
///    path's encoding of "no compare-and-set guard", so sanitizing an
///    `Infinity` away turns "only if it still reads 1200" into "whatever it
///    reads" — a guarded write silently made unconditional
///    (`messages.dart:373-401`, `channel_state_man.dart:229-250`).
library;

import 'package:json_rpc_2/error_code.dart' as rpc_error;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/value_handlers.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/fake_clock.dart';

/// A clock far enough from zero that a ULID minted on it is a plausible id:
/// the timestamp field is 48 bits of epoch milliseconds, and a test that
/// minted at zero would be asserting about ids from 1970.
const int _epochStart = 1_760_000_000_000;

/// The handlers under test, their source, and the clock both share.
final class _Kit {
  _Kit(this.handlers, this.api, this.clock, this.config, this.log);

  final ValueHandlers handlers;
  final FakeStateMan api;
  final FakeClock clock;
  final ServerConfig config;

  /// The gateway's log. Held so [reconnect] can hand the same one to the next
  /// session, which is what a real server does.
  final WriteOutcomeLog log;

  /// A cmd minted on this kit's clock, exactly as a client would mint one at
  /// the moment the operator pressed the button.
  String mintCmd() => newUlid(nowMs: clock.nowMs);

  /// The same gateway, the same plant, the same clock, the same log — and a
  /// fresh set of handlers, which is what the link dying and coming back
  /// produces (`relay_session.dart`: handlers are built per session).
  _Kit reconnect() => _Kit(
        ValueHandlers(
          api: api,
          config: config,
          now: clock.now,
          outcomes: log,
        ),
        api,
        clock,
        config,
        log,
      );
}

/// A source that hands back a live hold and then ends it on its own.
///
/// Not exotic: a `LocalStateMan` whose PLC link drops under a live hold does
/// exactly this, and so does any source that tears a hold down for its own
/// reasons. The gateway's `_holds` entry is then a handle that is no longer
/// held, and the point of the case that uses this is that such an entry must
/// not wedge the key against every later engage.
final class _EndsHoldsItself extends FakeStateMan {
  final handedOut = <HoldHandle>[];

  @override
  Future<HoldHandle> holdToRun(String key) async {
    final hold = await super.holdToRun(key);
    handedOut.add(hold);
    return hold;
  }
}

_Kit _kit({
  Duration writeOutcomeTtl = const Duration(seconds: 60),
  Set<String> readOnlyKeys = const {},
  FakeStateMan? source,
}) {
  final api = source ?? FakeStateMan(readOnlyKeys: readOnlyKeys);
  final clock = FakeClock(start: _epochStart);
  final config = ServerConfig(writeOutcomeTtl: writeOutcomeTtl);
  final log = WriteOutcomeLog(ttl: writeOutcomeTtl, now: clock.now);
  addTearDown(api.dispose);
  return _Kit(
    ValueHandlers(
      api: api,
      config: config,
      now: clock.now,
      outcomes: log,
    ),
    api,
    clock,
    config,
    log,
  );
}

rpc.Parameters _params(String method, Map<String, Object?> value) =>
    rpc.Parameters(method, value);

Map<String, Object?> _asMap(Object? raw) => (raw! as Map).cast<String, Object?>();

/// Ten plant keys in the house convention, all with values.
Map<String, Object?> _tenKeys() => {
      for (var i = 1; i <= 10; i++)
        'CN${i.toString().padLeft(2, '0')}.MOT01.speed': i,
    };

Future<rpc.RpcException> _refusal(
    Future<Object?> call, String what) async {
  try {
    await call;
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

void main() {
  group('read', () {
    test('a key the plant serves answers from the cache', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 1200);

      final answer =
          _asMap(await kit.handlers.read(_params(Methods.read, {
        'key': 'CN01.MOT01.speed',
      })));

      expect(answer['key'], 'CN01.MOT01.speed');
      expect(WireValue.fromJson(_asMap(answer['value'])).v, 1200,
          reason: 'read is the cached path: it answers with what the gateway '
              'last heard from the PLC, which is the number already on the '
              'operator\'s screen');
      expect(answer['rejected'], isNull);
    });

    test('a key the source does not serve is answered, not thrown', () async {
      final kit = _kit();
      kit.api.setValues(_tenKeys());

      final answer =
          _asMap(await kit.handlers.read(_params(Methods.read, {
        'key': 'CN99.NOPE01.invented',
      })));

      final wire = WireValue.fromJson(_asMap(answer['value']));
      expect(wire.v, isNull);
      expect(wire.q, Quality.errorConfig,
          reason: 'a tag this source cannot serve is a configuration error '
              'and not a value that is late: waiting will not fix a typo in a '
              'page config, and an uncertain code would tell the operator to '
              'wait');
      expect(_asMap(answer['rejected']).keys, ['CN99.NOPE01.invented'],
          reason: 'keyed by tag, exactly as readMany keys it (04-REVIEW '
              'WR-11). Two neighbouring methods that spell one field two ways '
              'is a client decoding the wrong one in silence');
      expect(
          _asMap(_asMap(answer['rejected'])['CN99.NOPE01.invented'])['kind'],
          'unknownKey',
          reason: 'the reason rides with the answer so a page editor can say '
              'which of its 1500 bindings is wrong');
    });

    test('a blank key is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          kit.handlers.read(_params(Methods.read, {'key': '  '})),
          'a read of a blank key');

      expect(error.code, rpc_error.INVALID_PARAMS);
    });
  });

  group('readFresh', () {
    test('the forced round trip keeps the source timestamp', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 1200,
          sourceTime: DateTime.fromMillisecondsSinceEpoch(_epochStart));

      final before = kit.api.roundTrips;
      final answer =
          _asMap(await kit.handlers.readFresh(_params(Methods.readFresh, {
        'key': 'CN01.MOT01.speed',
      })));

      expect(kit.api.roundTrips, before + 1,
          reason: 'readFresh is the call a diagnostics page makes when the '
              'cache is the thing under suspicion; answering it from the '
              'cache would answer the wrong question');
      final wire = WireValue.fromJson(_asMap(answer['value']));
      expect(wire.t, _epochStart,
          reason: 'the readback check compares the instant the PLC produced '
              'the value, not the instant the gateway relayed it');
    });
  });

  group('readMany', () {
    test('one mistyped key among ten costs that one key, not the call',
        () async {
      final kit = _kit();
      kit.api.setValues(_tenKeys());

      final answer =
          _asMap(await kit.handlers.readMany(_params(Methods.readMany, {
        'keys': [..._tenKeys().keys, 'CN99.NOPE01.invented'],
      })));

      expect(_asMap(answer['values']).keys.toSet(), _tenKeys().keys.toSet(),
          reason: 'a page config carries ~1500 hand-edited keys; failing the '
              'whole call on one typo turns it into a blank control-room '
              'screen');
      expect(_asMap(answer['rejected']).keys, ['CN99.NOPE01.invented']);
    });

    test('one round trip serves however many keys were asked for', () async {
      final kit = _kit();
      kit.api.setValues(_tenKeys());

      final before = kit.api.roundTrips;
      await kit.handlers.readMany(_params(Methods.readMany, {
        'keys': _tenKeys().keys.toList(),
      }));

      expect(kit.api.roundTrips, before + 1,
          reason: 'ten keys as ten round trips over a link with 200 ms of '
              'latency is the failure this method exists to remove');
    });

    test('an empty key list is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          kit.handlers.readMany(_params(Methods.readMany, {'keys': <String>[]})),
          'a readMany asking for nothing');

      expect(error.code, rpc_error.INVALID_PARAMS);
    });

    test('a list over the server\'s ceiling is refused', () async {
      final kit = _kit();
      final config = ServerConfig();

      final error = await _refusal(
          kit.handlers.readMany(_params(Methods.readMany, {
            'keys': [
              for (var i = 0; i <= config.maxKeysPerSubscribe; i++) 'CN01.K$i.v'
            ],
          })),
          'a readMany over the key ceiling');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('${config.maxKeysPerSubscribe}'));
    });
  });

  group('write', () {
    test('the answer carries an outcome and the client\'s own cmd', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));

      expect(answer['outcome'], 'applied');
      expect(answer['cmd'], cmd,
          reason: 'the cmd the operator\'s action was minted under is what '
              'writeStatus is queried by; an answer carrying the gateway\'s '
              'own id could never be reconciled');
      expect(WriteResult.fromJson(answer), isA<WriteApplied>());
    });

    test('a rejection is an answer, not an error', () async {
      final kit = _kit(readOnlyKeys: {'CN01.MOT01.speed'});
      kit.api.setValue('CN01.MOT01.speed', 0);

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': kit.mintCmd(),
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));

      expect(WriteResult.fromJson(answer), isA<WriteRejected>(),
          reason: 'the device said no. A JSON-RPC error means "definitively '
              'no effect and safe to retry", which is a different sentence');
    });

    test('a non-finite expect is refused rather than silently dropped',
        () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 1200);

      final error = await _refusal(
          kit.handlers.write(_params(Methods.write, {
            'cmd': kit.mintCmd(),
            'key': 'CN01.MOT01.speed',
            'value': 1400,
            'expect': double.infinity,
          })),
          'a write carrying a non-finite compare-and-set guard');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(error.message, contains('guard'),
          reason: 'the refusal names the consequence — a guarded write made '
              'unconditional — rather than naming a type');
      expect(kit.api.mintedCmds, isEmpty,
          reason: 'refused before the plant was touched');
    });

    test('a write the gateway loses track of answers unknown, not an error',
        () async {
      final kit = _kit();
      final cmd = kit.mintCmd();
      // Seeded before the dispose, because `write` consults `api.keys` since
      // 06-04 and a key with no stored value is not in that list
      // (`fake_state_man.dart:283-286`). Without the seed this case would die
      // on the existence check and never reach the disposed source it exists
      // to drive. The tag is legitimately pre-existing; the source still
      // throws, which is the shape being asserted.
      kit.api.setValue('CN01.MOT01.speed', 1200);
      // A disposed source is the cheapest thing that throws from `write`; the
      // shape being asserted is any failure the gateway cannot interpret.
      await kit.api.dispose();

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));

      expect(WriteResult.fromJson(answer), isA<WriteUnknown>(),
          reason: 'a throw on the write path collapses "the PLC may have '
              'applied this" into "this definitely did not happen", and the '
              'second sentence is what makes an operator press the button '
              'again');
    });
  });

  // 04-REVIEW CR-05. The `cmd` arrives from the wire and used to be taken
  // verbatim, so any peer past the handshake could send two different writes
  // under one id: both went upstream, the second overwrote the first's
  // outcome, and writeStatus then reported one answer covering two actuations.
  group('one cmd, one actuation', () {
    test('two writes under one id with different values are refused before '
        'the plant is touched', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));
      final attemptsAfterFirst =
          kit.api.upstreamWriteAttempts(cmd);

      final error = await _refusal(
          kit.handlers.write(_params(Methods.write, {
            'cmd': cmd,
            'key': 'CN01.MOT01.speed',
            'value': 1500,
          })),
          'a second write under a live cmd');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'a shape refusal raised before the plant is touched is the '
              'one class of refusal this path allows, and INVALID_PARAMS on a '
              'write means "definitively no effect" — which here is true');
      expect(kit.api.upstreamWriteAttempts(cmd), attemptsAfterFirst,
          reason: 'the refusal has to happen before anything goes upstream, '
              'or it is a report about an actuation that already occurred');
      expect(kit.api.read('CN01.MOT01.speed')?.value, 1200,
          reason: 'the device holds what the first write put there');
      expect(error.message, contains('nothing was sent'),
          reason: 'the refusal reaches the operator as '
              'WriteRejected(server_refused) — "the device said no" — because '
              'failure_taxonomy maps every RpcException that way, and that '
              'mapping is deliberately left alone. The message is therefore '
              'the only thing that can say no device was consulted');
      expect(error.message, contains('caller'),
          reason: 'naming it a defect in the caller rather than a condition '
              'of the machine is what stops an operator hunting an interlock '
              'that does not exist');
      expect(_asMap(error.data)['request'], isA<String>(),
          reason: 'the rewritten message still travels through _refuse, which '
              'pre-substitutes data["request"]; a refusal that let '
              'RpcException.serialize echo the offending request could carry '
              '1e999 into the error itself and hang every caller (02-05)');
    });

    test('a replay carrying a different compare-and-set guard is refused',
        () async {
      // D-P5-B. "Set 1450" and "set 1450 only if it still reads 1200" are two
      // different operator intents, so the same id over both is a collision
      // even though the key and the value agree.
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 1200);
      final cmd = kit.mintCmd();
      await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1450,
        'expect': 1200,
      }));
      final attemptsAfterFirst = kit.api.upstreamWriteAttempts(cmd);

      final error = await _refusal(
          kit.handlers.write(_params(Methods.write, {
            'cmd': cmd,
            'key': 'CN01.MOT01.speed',
            'value': 1450,
          })),
          'an unguarded write replaying a guarded one\'s id');

      expect(error.code, rpc_error.INVALID_PARAMS);
      expect(kit.api.upstreamWriteAttempts(cmd), attemptsAfterFirst,
          reason: 'answering the unguarded write from the guarded one\'s log '
              'entry would report that a check passed which was never made');
    });

    test('a cmd whose outcome has aged out is a new command again', () async {
      // Anti-vacuity, and the honest boundary: the refusal is about what this
      // gateway still remembers. Past the TTL there is no entry to collide
      // with, and the id is indistinguishable from one nobody has used. The
      // idempotency window does not widen that boundary: with no entry there
      // is no fingerprint to match either, so a replay past the TTL is not
      // answered from the log — it goes upstream on its merits, exactly as it
      // did before 05-03.
      final kit = _kit(writeOutcomeTtl: const Duration(seconds: 60));
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));

      kit.clock.advance(const Duration(seconds: 61).inMilliseconds);
      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1500,
      })));

      // Answered rather than refused: the gateway has no entry to collide
      // with, and refusing an id it cannot remember would be refusing on a
      // hunch. What the *source* does with a re-used id is the source's own
      // business — this one keeps every id it has ever been handed and treats
      // a repeat as the caller's bug, so the outcome below is unknown rather
      // than applied. The claim here is about the gateway's boundary.
      expect(WriteResult.fromJson(answer).cmd, cmd,
          reason: 'past the TTL the id is indistinguishable from one nobody '
              'has used, and the write goes upstream on its merits');
    });
  });

  // 05-03. The other half of "one id, one actuation": the *same* write
  // arriving twice is one operator action, not two, and the honest answer is
  // the outcome that action already got. A client that restarted still holds
  // the id it minted, and refusing it would settle the id against a write
  // whose fate the operator was asking about.
  group('the idempotency window', () {
    test('a replayed write is answered from the log and the plant is touched '
        'once', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      final first = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));
      expect(WriteResult.fromJson(first), isA<WriteApplied>(),
          reason: 'the case is about a replay of a settled write; if the '
              'first one did not settle applied the replay proves nothing');

      final replay = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));

      final answered = WriteResult.fromJson(replay);
      expect(answered, isA<WriteApplied>(),
          reason: 'the same press arriving twice gets the outcome that press '
              'already got. Note what a second trip upstream would produce '
              'instead: the source keeps every id it has been handed and '
              'throws on a repeat, which the gateway maps to unknown — so '
              '"applied" here can only have come from the log');
      expect((answered as WriteApplied).readback,
          (WriteResult.fromJson(first) as WriteApplied).readback,
          reason: 'the readback is what the mimic displays; a replay must put '
              'the same number on the screen as the original did');
      expect(answered.cmd, cmd);
      expect(kit.api.upstreamWriteAttempts(cmd), 1,
          reason: 'one operator action, one movement of the machine. This '
              'count is the whole property — everything else is bookkeeping');
    });

    test('a replay arriving while the first write is upstream is answered '
        'unknown, not refused', () async {
      // D-P5-A, and the reason it is not a refusal: a refusal arrives at the
      // client as WriteRejected(server_refused), which *settles* the id — and
      // it would settle it against a write that is at that moment on its way
      // to a machine. An unknown leaves the id unresolved, so the next ready
      // re-queries writeStatus and the operator learns what actually happened.
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      kit.api.stallWrites();

      final inFlight = kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));
      await pumpEventQueue();

      final replay = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));

      final answered = WriteResult.fromJson(replay);
      expect(answered, isA<WriteUnknown>());
      expect((answered as WriteUnknown).reason.kind, 'in_flight',
          reason: 'the gateway has sent this write upstream and has not heard '
              'back: that is the pre-record talking, and it is the truest '
              'thing anyone can say at this instant');
      expect(kit.api.upstreamWriteAttempts(cmd), 1,
          reason: 'the replay was answered from the log, so the stalled write '
              'is still the only one out');

      kit.api.releaseWrites();
      expect(WriteResult.fromJson(_asMap(await inFlight)), isA<WriteApplied>(),
          reason: 'the original settles on its own merits; the replay changed '
              'nothing about it');
    });

    test('an operator re-send after not_received is not refused', () async {
      // The anti-vacuity arm (05-RESEARCH §A.3, path 2). `not_received` is the
      // one verdict that makes a re-send safe, and the re-send carries the
      // same cmd because the operator's action is the same action. If this
      // plan's window turned that into a refusal it would have removed the
      // only safe re-send in the system.
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      kit.clock.advance(1000);
      final cmd = kit.mintCmd();

      final before = await _status(kit, [cmd]);
      expect(before.single, isA<WriteNotReceived>(),
          reason: 'minted after this log started, dated by a clock the '
              'gateway trusts, inside the TTL, and never recorded: the '
              'gateway can say it never arrived');

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      })));

      expect(WriteResult.fromJson(answer), isA<WriteApplied>(),
          reason: 'the log holds no entry for this id — answering not_received '
              'is precisely the claim that it holds none — so there is nothing '
              'to match and nothing to collide with, and the write goes '
              'upstream on its merits');
      expect(kit.api.upstreamWriteAttempts(cmd), 1);
    });
  });

  group('writeStatus', () {
    test('a command written a moment ago answers with the outcome it got',
        () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));

      final results = await _status(kit, [cmd]);

      expect(results.single, isA<WriteApplied>());
      expect(results.single.cmd, cmd);
    });

    test('a command the gateway never saw answers not_received', () async {
      final kit = _kit();

      final results = await _status(kit, [kit.mintCmd()]);

      expect(results.single, isA<WriteNotReceived>(),
          reason: 'the command was minted inside the window and no outcome '
              'was ever recorded for it, so the gateway can say it never '
              'arrived — the one answer that makes a re-send safe');
    });

    test(
        'an aged-out command answers unknown, because not_received is a '
        'licence to re-actuate machinery', () async {
      final kit = _kit(writeOutcomeTtl: const Duration(seconds: 60));
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));

      kit.clock.advance(const Duration(seconds: 61).inMilliseconds);
      final results = await _status(kit, [cmd]);

      expect(results.single, isA<WriteUnknown>(),
          reason: 'the gateway forgot the outcome; forgetting is not evidence '
              'that the write never happened, and not_received would tell the '
              'operator it is safe to actuate the machine a second time');
      expect(results.single.cmd, cmd);
    });

    test('the outcome log does not grow across aged-out commands', () async {
      // T-04-06, re-run after 05-03 widened the entry: an entry now also
      // carries the key and the two decoded payloads it was recorded for, both
      // bounded at ingress by maxFrameBytes. The entry got bigger; the bound
      // is still "writes within the TTL", and the bound is what matters.
      final kit = _kit(writeOutcomeTtl: const Duration(seconds: 60));
      kit.api.setValue('CN01.MOT01.speed', 0);

      for (var i = 0; i < 20; i++) {
        await kit.handlers.write(_params(Methods.write, {
          'cmd': kit.mintCmd(),
          'key': 'CN01.MOT01.speed',
          'value': i,
        }));
        kit.clock.advance(const Duration(seconds: 10).inMilliseconds);
        await _status(kit, [kit.mintCmd()]);
      }

      expect(kit.handlers.recordedOutcomes, lessThanOrEqualTo(7),
          reason: 'a log with a TTL and no pruning is a memory leak an '
              'authenticated client can drive: at one write per ten seconds '
              'and a 60 s window, seven entries is everything still inside it');
    });

    test('a command still in flight is answerable, and not as not_received',
        () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      kit.api.stallWrites();

      final inFlight = kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));
      await pumpEventQueue();
      final results = await _status(kit, [cmd]);

      expect(results.single, isNot(isA<WriteNotReceived>()),
          reason: 'the command is upstream right now. Telling the operator it '
              'never arrived, while it is in flight, is the one answer that '
              'invites a second actuation of a moving machine');
      expect(results.single, isA<WriteUnknown>());

      kit.api.releaseWrites();
      await inFlight;
    });

    test('an empty cmd list is refused', () async {
      final kit = _kit();

      final error = await _refusal(
          kit.handlers.writeStatus(
              _params(Methods.writeStatus, {'cmds': <String>[]})),
          'a writeStatus asking about nothing');

      expect(error.code, rpc_error.INVALID_PARAMS);
    });

    test('a cmd that is not an id at all answers unknown', () async {
      final kit = _kit();

      final results = await _status(kit, ['not-a-ulid']);

      expect(results.single, isA<WriteUnknown>(),
          reason: 'nothing can be dated, so nothing can be ruled out; the '
              'safe answer to "I cannot tell" is unknown');
    });
  });

  // 04-REVIEW CR-02. `not_received` is a licence to re-actuate a machine, so
  // the gateway may only give it about a window it can vouch for with its own
  // clock — and it may not lose the window every time a socket dies, because a
  // socket dying is the *only* thing that ever makes a client ask.
  group('writeStatus across a reconnect', () {
    test('a cmd minted before this log started answers unknown, never '
        'not_received', () async {
      final kit = _kit();

      // The panel pressed the button before this gateway process was recording
      // — which, after a gateway restart, is every command that crossed the
      // outage.
      final cmd = newUlid(nowMs: _epochStart - 5000);
      final results = await _status(kit, [cmd]);

      expect(results.single, isNot(isA<WriteNotReceived>()),
          reason: 'never having been told is not evidence of never having '
              'happened, and not_received is what sends an operator back to '
              'the button');
      expect(results.single, isA<WriteUnknown>());
      expect((results.single as WriteUnknown).reason.kind,
          'outcome_unwitnessed');
    });

    test('a cmd minted in the future answers unknown, never not_received',
        () async {
      // A panel whose clock runs four minutes ahead: inside
      // `implausibleClockThreshold`, which 04-CONTEXT rules warns and keeps
      // going, so skew of exactly this size is anticipated elsewhere in the
      // phase. Unclamped it bought a `not_received` window of `ttl + skew`.
      final kit = _kit();
      final cmd =
          newUlid(nowMs: _epochStart + const Duration(minutes: 4).inMilliseconds);

      final results = await _status(kit, [cmd]);

      expect(results.single, isA<WriteUnknown>());
      expect((results.single as WriteUnknown).reason.kind,
          'outcome_unwitnessed');
    });

    test('an outcome recorded on one session is answerable on the next',
        () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));

      // The link dies and the panel reconnects: a *new* session, new handlers,
      // the same gateway and therefore the same log.
      final reconnected = kit.reconnect();
      final results = await _status(reconnected, [cmd]);

      expect(results.single, isA<WriteApplied>(),
          reason: 'the write was applied and the gateway knows it. A log that '
              'died with the socket answered this question with the empty '
              'set every single time it was asked');
      expect(results.single.cmd, cmd);
    });

    test('a write still upstream when the link died is unknown on the new '
        'session, not not_received', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();
      kit.api.stallWrites();
      final inFlight = kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1200,
      }));
      await pumpEventQueue();

      final results = await _status(kit.reconnect(), [cmd]);

      expect(results.single, isNot(isA<WriteNotReceived>()),
          reason: 'the gateway received this command and forwarded it; the '
              'device may have taken it. This is the exact sequence that made '
              'the panel tell an operator a write it had sent never arrived');
      expect(results.single, isA<WriteUnknown>());

      kit.api.releaseWrites();
      await inFlight;
    });

    test('a cmd minted after the log started and never seen is still '
        'not_received', () async {
      // The anti-vacuity arm: the clamps above must not have turned the one
      // safe answer off altogether. A gateway that was up, recording, and
      // never told about this command can say so.
      final kit = _kit();
      kit.clock.advance(1000);
      final cmd = kit.mintCmd();

      final results = await _status(kit.reconnect(), [cmd]);

      expect(results.single, isA<WriteNotReceived>());
    });
  });

  // 05-05 / D-P5-C. Engage and release are ordinary write frames carrying one
  // extra flag, which is what buys them a three-state outcome, an entry in the
  // outcome log and `writeStatus` reconciliation across a reconnect with no
  // new code. What the flag changes is the *seam*: an engage goes to
  // `api.holdToRun` and takes a handle this session can feed, not to
  // `api.write`, which would put a 1 on the tag with nothing behind it and no
  // way to advance the counter afterwards.
  //
  // The observable throughout is the source's own write bookkeeping. A write
  // that went through `api.write` carries the client's cmd upstream, so
  // `upstreamWriteAttempts(cmd)` is 1; a write that went through the hold seam
  // does not, because the handle mints its own ids for the engage and the
  // release. That difference is what tells "a hold was taken" from "a number
  // was written".
  group('hold-to-run: the flag routes to a different seam', () {
    test('an engage takes a source-side hold, not a one-off write', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final engageCmd = kit.mintCmd();

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': engageCmd,
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));

      expect(WriteResult.fromJson(answer), isA<WriteApplied>(),
          reason: 'the engage is a real write and "did the hold take" is a '
              'three-state question');
      expect(answer['cmd'], engageCmd,
          reason: 'the source mints its own id inside holdToRun, so the '
              'outcome has to be relabelled under the operator\'s id or '
              'writeStatus could never reconcile the engage');
      expect(kit.api.read('CN01.MOT01.speed')?.value, 1,
          reason: 'the deadman counter starts at 1 the moment the button goes '
              'down');
      expect(kit.api.upstreamWriteAttempts(engageCmd), 0,
          reason: 'the client\'s cmd did not go upstream as a write, because '
              'the engage is not one: it is holdToRun, and the handle it '
              'returns is what the ticks feed');

      // The load-bearing arm, and the reason this case is not a call count:
      // a release under the hold flag can only be answered by a *handle*, so
      // a release that never reached the plant's write path is proof there
      // was a live hold here to release. Route the engage through `api.write`
      // instead and there is no handle, the release falls through to the
      // ordinary path, and this expectation reads 1.
      final releaseCmd = kit.mintCmd();
      final released = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': releaseCmd,
        'key': 'CN01.MOT01.speed',
        'value': 0,
        'hold': true,
      })));

      expect(kit.api.upstreamWriteAttempts(releaseCmd), 0,
          reason: 'the release went through the handle this session engaged. '
              'If the engage had been an ordinary write there would have been '
              'no handle to release and this count would be 1 — which is what '
              'makes this arm the proof that a hold was taken');
      expect(WriteResult.fromJson(released), isA<WriteApplied>());
      expect(kit.api.read('CN01.MOT01.speed')?.value, 0,
          reason: '0 is reserved for released, and the tag says so');
    });

    test('a release with no hold held writes zero on its merits', () async {
      // The mirror of the arm above, and the reason it is allowed: writing 0
      // to a deadman tag is a legitimate thing to do, and a gateway that
      // restarted holds no handle for a hold its predecessor engaged.
      // Refusing here would make a perfectly sensible release look like a
      // caller defect and leave the operator with a counter nobody can stop.
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 7);
      final cmd = kit.mintCmd();

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 0,
        'hold': true,
      })));

      expect(WriteResult.fromJson(answer), isA<WriteApplied>());
      expect(kit.api.upstreamWriteAttempts(cmd), 1,
          reason: 'no handle, so this is an ordinary write and it goes '
              'upstream under the operator\'s own id');
      expect(kit.api.read('CN01.MOT01.speed')?.value, 0);
    });

    test('a hold write carrying 7 is refused before the plant is touched',
        () async {
      // The counter's vocabulary on the *write* path is exactly 1 and 0.
      // Intermediate values arrive as ticks, which are notifications with no
      // cmd and no outcome; letting one in here would make `write` a way to
      // put an arbitrary integer on a deadman tag while calling it an engage.
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();

      final error = await _refusal(
          kit.handlers.write(_params(Methods.write, {
            'cmd': cmd,
            'key': 'CN01.MOT01.speed',
            'value': 7,
            'hold': true,
          })),
          'a hold write carrying an out-of-band counter value');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'a shape refusal raised before the plant is touched is the '
              'one class of refusal this path allows, and here "definitively '
              'no effect" is true');
      expect(kit.api.upstreamWriteAttempts(cmd), 0);
      expect(kit.api.mintedCmds, isEmpty,
          reason: 'refused before api.holdToRun and before api.write: nothing '
              'was consulted, so the source has not seen an id at all');
      expect(kit.api.read('CN01.MOT01.speed')?.value, 0,
          reason: 'the tag still holds what it held');
      expect(error.message, contains('tick'),
          reason: 'the refusal names where an intermediate counter value '
              'belongs — a tick — rather than naming a type');
      expect(error.message, contains('nothing was sent'),
          reason: 'the refusal reaches the operator as '
              'WriteRejected(server_refused), so the message is the only '
              'thing that can say no device was consulted');
      expect(_asMap(error.data)['request'], isA<String>(),
          reason: 'the new refusal travels through _refuse, which '
              'pre-substitutes data["request"] (02-05)');
    });

    test('a replayed engage is answered from the log and the hold is taken '
        'once', () async {
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);
      final cmd = kit.mintCmd();

      final first = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));
      expect(WriteResult.fromJson(first), isA<WriteApplied>(),
          reason: 'a replay of a settled engage proves nothing if the engage '
              'did not settle');
      final mintedAfterFirst = kit.api.mintedCmds.length;

      final replay = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));

      expect(WriteResult.fromJson(replay), isA<WriteApplied>(),
          reason: 'one press of a hold-to-run button arriving twice is one '
              'press: it is answered with the outcome that press already got');
      expect(kit.api.mintedCmds, hasLength(mintedAfterFirst),
          reason: 'a second holdToRun would have minted a second engage write '
              'at the source — one operator action, one movement of the '
              'machine, and that is the whole property');
    });

    test('a second engage on a key this session already holds is refused',
        () async {
      // 05-REVIEW WR-02. The branch used to overwrite the map entry, and the
      // displaced handle was then unreachable: no tick could find it, a
      // release write reached only the entry, and `releaseAllHolds` iterates
      // `_holds.values` — so teardown missed it too. It stayed engaged in the
      // source's own live-hold registry until the source itself went away,
      // with its `onReleased` completer never completing.
      final kit = _kit();
      kit.api.setValue('CN01.MOT01.speed', 0);

      final first = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': kit.mintCmd(),
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));
      expect(WriteResult.fromJson(first), isA<WriteApplied>(),
          reason: 'the first engage did not take, so there is no live hold '
              'for the second one to collide with and this case proves '
              'nothing');
      final mintedAfterFirst = kit.api.mintedCmds.length;

      final secondCmd = kit.mintCmd();
      final error = await _refusal(
          kit.handlers.write(_params(Methods.write, {
            'cmd': secondCmd,
            'key': 'CN01.MOT01.speed',
            'value': 1,
            'hold': true,
          })),
          'a second engage on a key this session already holds');

      expect(error.code, rpc_error.INVALID_PARAMS,
          reason: 'the refusal is raised before api.holdToRun, so '
              '"definitively no effect" is true and INVALID_PARAMS is the '
              'honest code');
      expect(kit.api.mintedCmds, hasLength(mintedAfterFirst),
          reason: 'a second source-side hold was taken. That handle is the '
              'orphan: unreachable by tick, by release and by '
              'releaseAllHolds, and left engaged at the source with its '
              'onReleased completer never completing');
      expect(kit.api.upstreamWriteAttempts(secondCmd), 0);
      expect(error.message, contains('one deadman'),
          reason: 'the refusal has to say why one key is one hold, because it '
              'reaches the operator as WriteRejected(server_refused) and the '
              'message is all they get');

      // The live hold is untouched by the refusal: still feedable, still the
      // handle a release will find. A refusal that quietly ended the first
      // hold would stop a machine the operator is still holding the button
      // for.
      await kit.handlers.holdTick(_params(Methods.holdTick, {
        'k': 'CN01.MOT01.speed',
        'n': 2,
      }));
      expect(kit.api.read('CN01.MOT01.speed')?.value, 2,
          reason: 'the tick after the refusal did not reach the tag, so the '
              'refusal took the live hold down with it');

      kit.handlers.releaseAllHolds();
      expect(kit.api.read('CN01.MOT01.speed')?.value, 0,
          reason: 'teardown left the deadman counter where it was, which is a '
              'hold outliving the session that engaged it');
    });

    test('a hold the source ended on its own does not wedge the key',
        () async {
      // The other half of WR-02's refusal: it is conditional on the entry
      // still being *held*. A source that ends a hold for its own reasons —
      // a PLC link dropping under it — leaves an entry in `_holds` that is
      // inert, and refusing against that forever would make the key
      // un-engageable for the life of the session. An inert handle is not an
      // orphan: there is nothing left to release.
      final source = _EndsHoldsItself();
      final kit = _kit(source: source);
      kit.api.setValue('CN01.MOT01.speed', 0);

      final first = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': kit.mintCmd(),
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));
      expect(WriteResult.fromJson(first), isA<WriteApplied>());
      final mintedAfterFirst = source.mintedCmds.length;

      await source.handedOut.single.release(reason: HoldEnded.disconnect);

      final second = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': kit.mintCmd(),
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));

      expect(WriteResult.fromJson(second), isA<WriteApplied>(),
          reason: 'the key was wedged by a handle nothing can release. The '
              'operator presses the jog button after the link came back and '
              'the gateway refuses forever');
      expect(source.mintedCmds.length, greaterThan(mintedAfterFirst),
          reason: 'the second engage was answered without a second hold being '
              'taken at the source, so the ticks that follow have nothing to '
              'feed');
      expect(source.handedOut, hasLength(2));
    });

    test('an engage the gateway loses track of answers unknown, not an error',
        () async {
      final kit = _kit();
      final cmd = kit.mintCmd();
      // Seeded before the dispose, for the same reason as the plain-write
      // case above: since 06-04 an engage is refused for a tag `api.keys` does
      // not list, and `FakeStateMan.keys` lists only keys with a stored value.
      // The seed makes the tag legitimately pre-existing; the throw out of the
      // disposed source is still what the case measures.
      kit.api.setValue('CN01.MOT01.speed', 0);
      // A disposed source is the cheapest thing that throws out of holdToRun;
      // the shape asserted is any failure the gateway cannot interpret.
      await kit.api.dispose();

      final answer = _asMap(await kit.handlers.write(_params(Methods.write, {
        'cmd': cmd,
        'key': 'CN01.MOT01.speed',
        'value': 1,
        'hold': true,
      })));

      final result = WriteResult.fromJson(answer);
      expect(result, isA<WriteUnknown>(),
          reason: 'a throw out of the hold seam is the same class of event as '
              'a throw out of api.write: the engage may still have reached the '
              'device, and saying otherwise is what makes an operator press '
              'the button again');
      expect((result as WriteUnknown).reason.kind, 'gateway_lost_track',
          reason: 'one try/catch covers both seams, so both answer with the '
              'same reason');
    });
  });

  group('the error armor', () {
    test('every refusal carries a pre-substituted request', () async {
      final kit = _kit();

      final refusals = <rpc.RpcException>[
        await _refusal(kit.handlers.read(_params(Methods.read, {'key': ''})),
            'a blank read'),
        await _refusal(
            kit.handlers
                .readMany(_params(Methods.readMany, {'keys': <String>[]})),
            'an empty readMany'),
        await _refusal(
            kit.handlers.write(_params(Methods.write, {
              'cmd': kit.mintCmd(),
              'key': 'CN01.MOT01.speed',
              'value': 1,
              'expect': double.nan,
            })),
            'a write with a non-finite guard'),
        await _refusal(
            kit.handlers
                .writeStatus(_params(Methods.writeStatus, {'cmds': <String>[]})),
            'an empty writeStatus'),
      ];

      for (final error in refusals) {
        expect(_asMap(error.data)['request'], isA<String>(),
            reason: 'RpcException.serialize copies the offending request into '
                'error.data unless data["request"] is already set. One request '
                'carrying 1e999 would then make the *error* unencodable, the '
                'peer drops it, and every caller with no deadline waits '
                'forever (the 02-05 hang)');
      }
    });
  });
}

/// `writeStatus` for [cmds], decoded.
Future<List<WriteResult>> _status(_Kit kit, List<String> cmds) async {
  final answer = _asMap(await kit.handlers
      .writeStatus(_params(Methods.writeStatus, {'cmds': cmds})));
  return [
    for (final raw in answer['results']! as List)
      WriteResult.fromJson((raw as Map).cast<String, Object?>()),
  ];
}
