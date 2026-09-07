import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Every shape must survive encode → jsonEncode → jsonDecode → decode, and
/// decoders must ignore unknown fields (forward compatibility).
void main() {
  Map<String, Object?> viaJson(Map<String, Object?> json,
          {Map<String, Object?> extra = const {'futureField': 123}}) =>
      jsonDecode(jsonEncode({...json, ...extra})) as Map<String, Object?>;

  test('HelloParams / HelloResult round-trip and tolerate unknown fields',
      () {
    final params = HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('centroid-hmi', '1.4.0'),
      capabilities: const {'deltaPush': true},
    );
    // The frame carries a `session` object it no longer has a field for — a
    // hello from a panel that predates 16-11's withdrawal. It is an unknown key
    // now, and the rule for unknown keys is that they are ignored, so this is
    // also the inbound half of the compatibility the withdrawal has to survive.
    final p = HelloParams.fromJson(viaJson(params.toJson(), extra: const {
      'futureField': 123,
      'session': {'id': '01J8', 'epoch': '01J7', 'lastSeq': {'s1': 4210}},
    }));
    expect(p.protocol, protocolVersion);
    expect(p.capabilities['deltaPush'], true);
    expect(p.toJson().containsKey('session'), isFalse,
        reason: 'a resume claim the gateway cannot honour must not be carried '
            'back out of a decode; there is no field to hold it and no code '
            'that could act on it');

    final result = HelloResult(
      protocol: protocolVersion,
      server: const PeerInfo('tfc-relay', '0.1.0'),
      sessionId: 'sid',
      epoch: 'e1',
      serverTime: 1786000000123,
    );
    final r = HelloResult.fromJson(viaJson(result.toJson()));
    expect(r.epoch, 'e1');
    expect(r.serverTime, 1786000000123);
  });

  test('a hello carries the panel\'s credential in a typed field', () {
    final params = HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('centroid-hmi', '1.4.0'),
      token: 'station-ST101-0123456789abcdef',
    );

    final wire = params.toJson();
    expect(wire['token'], 'station-ST101-0123456789abcdef',
        reason: 'the credential rides in its own key, not folded into '
            '`capabilities` — an open map the session logs and copies. A '
            'typed field is what makes "does anything log the token?" a grep '
            'rather than an audit');

    final p = HelloParams.fromJson(viaJson(wire));
    expect(p.token, 'station-ST101-0123456789abcdef',
        reason: 'a credential that does not survive the round trip is a panel '
            'the gateway refuses for a reason nobody can diagnose, because '
            'the token was sent and simply never arrived');
  });

  test('a hello with no credential carries no token key', () {
    final params = HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('centroid-hmi', '1.4.0'),
    );

    final wire = params.toJson();
    expect(wire.containsKey('token'), isFalse,
        reason: 'an absent credential must be absent, not an empty string: a '
            'diagnostic dump of a tokenless hello that shows `token: ""` '
            'tells the integrator the station was configured with a blank '
            'credential when it was configured with none, and those are two '
            'different faults with two different fixes. It is also the '
            'compatibility property — encoders omit absent optionals, so a '
            'tokenless hello is byte-identical to the one this build sent '
            'before the field existed');

    expect(HelloParams.fromJson(viaJson(wire)).token, isNull,
        reason: 'a hello with no token key decodes to no token; anything else '
            'invents a credential the panel never presented');
  });

  test('hello advertises the heartbeat deadline', () {
    // **Why the gateway has to say this number out loud.** The reaper closes
    // any session that has been silent longer than `heartbeatDeadline`
    // (`tick_engine.dart`), and the panel's only defence is to not be silent.
    // A cadence hard-coded on the client is a number nobody diffs against the
    // gateway's config: raise the deadline and the panel over-pings for ever;
    // lower it and every healthy panel in the plant is reaped once a deadline,
    // reconnecting and resyncing its whole page each time. That is not a
    // hypothetical — it is what this build did before 07-08b, measured in
    // 07-08-SUMMARY deviation 3.
    //
    // `tickMs` is the precedent in every respect: an additive key on the open
    // `capabilities` map, so a gateway that does not send it and a client that
    // does not read it are both still correct.
    final result = HelloResult(
      protocol: protocolVersion,
      server: const PeerInfo('tfc-relay', '0.1.0'),
      capabilities: const {'tickMs': 50, 'heartbeatDeadlineMs': 6000},
      sessionId: 'sid',
      epoch: 'e1',
      serverTime: 1786000000123,
    );

    final r = HelloResult.fromJson(viaJson(result.toJson()));
    expect(r.capabilities[HelloCapabilities.heartbeatDeadlineMs], 6000,
        reason: 'the deadline rides in the open capabilities map beside '
            'tickMs, so a gateway that predates the key and a client that '
            'ignores it are both still speaking this protocol');
    expect(r.heartbeatDeadlineMs, 6000,
        reason: 'the typed reader is what the client actually calls; a client '
            'that reached into the map itself would be the second place the '
            'key is spelled, and the first typo in it is silent');
  });

  test('an unusable heartbeat deadline reads as none at all', () {
    // The same tolerance `FreshnessWatchdog.learnedTickMs` applies to `tickMs`,
    // and for the same reason: `capabilities` is an open map, so whatever is
    // under this key came off a wire and may be a string, a negative number,
    // `1e999` decoded to Infinity, or absent. Every one of those has to mean
    // "this gateway told me nothing" — a pump that divided a garbage value by
    // three would either spin (0 ms) or never beat at all.
    // The value is spliced in as raw JSON **text** rather than as a Dart
    // object, because two of the cases below cannot be produced any other way:
    // `jsonEncode` throws on Infinity and NaN (CLAUDE.md's wire hazards), so a
    // fixture that built the frame with `jsonEncode` could never deliver the
    // `1e999` poison this reader has to survive. Decoding is the direction the
    // hazard actually arrives from.
    HelloResult withCapability(String rawJson) =>
        HelloResult.fromJson((jsonDecode('{'
                '"protocol":"$protocolVersion",'
                '"server":{"name":"tfc-relay","version":"0.1.0"},'
                '"capabilities":{"heartbeatDeadlineMs":$rawJson},'
                '"session":{"id":"s","epoch":"e","resumed":false},'
                '"clock":{"serverTime":1786000000123}}') as Map)
            .cast<String, Object?>());

    for (final unusable in <String>[
      'null',
      '0',
      '-1',
      '"soon"',
      // `1e999` decodes to Infinity in Dart, silently. It is named in
      // CLAUDE.md as decode poison and it is the reason this reader exists at
      // all rather than a bare `as int?`.
      '1e999',
      '-1e999',
    ]) {
      expect(withCapability(unusable).heartbeatDeadlineMs, isNull,
          reason: 'a gateway that advertised $unusable as its heartbeat '
              'deadline has advertised nothing usable, and the client must '
              'fall back on its own floor rather than derive a cadence from '
              'it');
    }

    expect(withCapability('6000.0').heartbeatDeadlineMs, 6000,
        reason: 'JSON has one number type and a gateway written in another '
            'language may well send 6000.0; refusing it would be refusing the '
            'same number for its spelling');
  });

  test('a hello result names the gateway process that answered', () {
    // Advisory only. It exists so that a wire capture taken on a LAN carrying
    // both a bench gateway and the plant gateway can be attributed without
    // correlating source ports — the Sparkplug `publisherId` adoption
    // (07-RESEARCH-PUBSUB), landed here because it costs one optional key.
    final result = HelloResult(
      protocol: protocolVersion,
      server: const PeerInfo('tfc-relay', '0.1.0'),
      sessionId: 'sid',
      epoch: 'e1',
      serverTime: 1786000000123,
      publisherId: 'gw-st101',
    );

    final wire = result.toJson();
    expect(wire['publisherId'], 'gw-st101',
        reason: 'the publisher name rides at the top level beside `protocol`, '
            'not inside `session` or `clock`: it identifies the process, '
            'which outlives every session it serves');

    expect(HelloResult.fromJson(viaJson(wire)).publisherId, 'gw-st101',
        reason: 'a name that does not survive the round trip is a capture '
            'that still cannot be attributed, which is the whole of what the '
            'field is for');
  });

  test('a hello result with no publisher name is byte-identical to the '
      'frame this build sent before the field existed', () {
    final result = HelloResult(
      protocol: protocolVersion,
      server: const PeerInfo('tfc-relay', '0.1.0'),
      sessionId: 'sid',
      epoch: 'e1',
      serverTime: 1786000000123,
    );

    final wire = result.toJson();
    expect(wire.containsKey('publisherId'), isFalse,
        reason: 'absent means absent, not an explicit null: a decoder in the '
            'plant that reads `publisherId` and finds JSON null must be '
            'unreachable, because the key is never sent at all');

    // The literal is the point. Asserting `toJson` against another call of
    // `toJson` would pass no matter what either one emitted; only a frozen
    // string can testify that a gateway which sets no publisher name puts the
    // exact same bytes on the wire as the build that had no such field. The
    // protocol version is interpolated because bumping it is a deliberate
    // wire change with its own decision, and this arm is making a claim about
    // one optional key, not about the version constant.
    //
    // **`"resumed":false` left this literal in 16-11, and that is exactly the
    // kind of edit this arm exists to make somebody justify.** It is not an
    // additive optional key going quiet; it is a field withdrawn from the
    // wire, which is a deliberate wire change with its own decision (HARD-03,
    // 16-CONTEXT.md) — the same category as bumping the protocol version, and
    // it had to be argued rather than absorbed. What makes it survivable is
    // that gateway and panels ship as one binary this milestone, so there is
    // no deployed decoder on the other side of the change. The decoder in this
    // build tolerates the key's presence *and* its absence; a decoder from
    // before it does not, and nothing in this package can reach one.
    expect(
        jsonEncode(wire),
        '{"protocol":"$protocolVersion",'
        '"server":{"name":"tfc-relay","version":"0.1.0"},'
        '"session":{"id":"sid","epoch":"e1"},'
        '"clock":{"serverTime":1786000000123}}',
        reason: 'an already-deployed panel decodes this frame; a byte that '
            'moved is a fleet-wide handshake failure, and the additive-'
            'optional idiom is what makes the field safe in both directions '
            'with no version negotiation. If this failed on the `session` '
            'object, read the paragraph above before updating the literal — '
            'that key was withdrawn once, deliberately, and a second one going '
            'the same way needs the same argument');

    expect(HelloResult.fromJson(viaJson(wire)).publisherId, isNull,
        reason: 'a frame with no publisher key decodes to no publisher, and '
            'throws nothing — the gateways already in the plant send exactly '
            'this frame');
  });

  // --- the session-resume withdrawal (16-11, HARD-03) -----------------------
  //
  // Session resume was withdrawn rather than implemented: honouring it meant
  // the gateway retaining per-session subscription state across a socket loss
  // and replaying from a per-subscription `lastSeq`, which is delta replay, and
  // CLAUDE.md's doctrine is "resync = snapshot, never delta replay". The
  // reasoning is in 16-CONTEXT.md. What is left behind is a compatibility
  // question in two directions, and these two arms are the two directions.

  /// A hello result frame, with the `session` map spliced in as raw JSON text.
  ///
  /// Text rather than a `HelloResult` built by the constructor, because the
  /// whole point of both arms below is a frame this build would not itself
  /// produce — one from the other side of a version skew. A fixture that could
  /// only express what the current encoder emits could not ask the question.
  HelloResult withSession(String sessionJson) =>
      HelloResult.fromJson((jsonDecode('{'
                  '"protocol":"$protocolVersion",'
                  '"server":{"name":"tfc-relay","version":"0.1.0"},'
                  '"session":$sessionJson,'
                  '"clock":{"serverTime":1786000000123}}') as Map)
          .cast<String, Object?>());

  test('a hello result that still carries `resumed` decodes, and the field is '
      'ignored', () {
    // The backwards direction: a gateway that predates the withdrawal, or a
    // capture replayed from one, still hands this build a frame with the key
    // in it. The library's rule is that decoders read known keys and ignore
    // everything else, so this must be an unremarkable decode — not an error,
    // and not a value anybody can act on.
    final r = withSession('{"id":"sid","epoch":"e1","resumed":true}');

    expect(r.sessionId, 'sid');
    expect(r.epoch, 'e1',
        reason: 'the epoch is what the client feeds to ResyncEngine.onHello; a '
            'frame carrying a withdrawn key must still deliver it');

    expect(r.serverTime, 1786000000123,
        reason: 'the whole frame decodes, not just the part before the '
            'withdrawn key');
  });

  test('a decoded `resumed` is not laundered back onto the wire', () {
    // Separate from the arm above on purpose. That one is about *tolerance* —
    // this build accepting an old frame — and it is green on both sides of the
    // withdrawal. This one is about the *emit*, and it is the arm that the
    // deletion turns green. Asserting both in one case would leave a failure
    // unable to say which of the two properties broke.
    //
    // `resumed: true` is the dangerous value: a client that believed it would
    // keep a cache the gateway cannot honour and show stale plant data under a
    // link that looks healthy. Re-emitting it after decoding would launder a
    // stale promise from a build that predates the withdrawal into one that
    // appears to make it — worse than the field ever was, because the second
    // gateway looks like it means it.
    final r = withSession('{"id":"sid","epoch":"e1","resumed":true}');

    expect(jsonEncode(r.toJson()), isNot(contains('resumed')),
        reason: 'the withdrawn key survived a decode/encode hop. Nothing in '
            'this build can produce a truthful value for it, so anything it '
            'emits is a guess wearing a protocol field');
  });

  test('a hello result with no `resumed` decodes', () {
    // The forwards direction, and the one that was broken. The decoder read
    // `session['resumed'] as bool`, which throws on absence — so the moment
    // anything stopped emitting the key, every panel with the old decoder
    // failed its handshake with a cast error and no diagnosis. The tolerance
    // has to land before the emit is removed, not with it, which is why this
    // arm exists on its own rather than as a corollary of the deletion.
    final r = withSession('{"id":"sid","epoch":"e1"}');

    expect(r.sessionId, 'sid');
    expect(r.epoch, 'e1',
        reason: 'this is the frame this build now emits. If it cannot be '
            'decoded, the gateway cannot talk to itself');
    expect(r.serverTime, 1786000000123,
        reason: 'a decode that threw partway would take the clock offset with '
            'it, and staleness is measured against that offset');
  });

  test('SubscribeResult: handles, snapshot, meta, and per-key rejection', () {
    final result = SubscribeResult(
      sub: 's1',
      epoch: 'e1',
      seq: 0,
      handles: const {'ST101.CN01.MOT01.speed': 1},
      meta: const {1: {'unit': 'rpm'}},
      snapshot: {1: WireValue.of(1450, t: 123)},
      rejected: const {'BOGUS.KEY': KeyReject('unknown_key')},
    );
    final r = SubscribeResult.fromJson(viaJson(result.toJson()));
    expect(r.handles['ST101.CN01.MOT01.speed'], 1);
    expect(r.snapshot[1]!.v, 1450);
    expect((r.meta[1] as Map)['unit'], 'rpm');
    expect(r.rejected['BOGUS.KEY']!.kind, 'unknown_key');
  });

  test('UpdateParams round-trips int handles through JSON string keys', () {
    final u = UpdateParams(
      sub: 's1',
      seq: 4211,
      t: 1786000000123,
      changes: {1: WireValue.of(42.5)},
      qualities: const {2: Quality.badStale},
      removed: const [7],
    );
    final r = UpdateParams.fromJson(viaJson(u.toJson()));
    expect(r.changes[1]!.v, 42.5);
    expect(r.qualities[2], Quality.badStale);
    expect(r.removed, [7]);
    expect(r.seq, 4211);
  });

  test('empty maps are omitted from the hot-path frame', () {
    final u = UpdateParams(sub: 's1', seq: 1, t: 2);
    final json = u.toJson();
    expect(json.containsKey('c'), isFalse);
    expect(json.containsKey('q'), isFalse);
    expect(json.containsKey('r'), isFalse);
  });

  test('TickParams carries per-subscription liveness', () {
    final tick = TickParams(
      serverTime: 1786000000123,
      subs: const {'s1': SubTick(seq: 4211, evaluatedAt: 1786000000100)},
    );
    final r = TickParams.fromJson(viaJson(tick.toJson()));
    expect(r.subs['s1']!.seq, 4211);
    expect(r.subs['s1']!.evaluatedAt, 1786000000100);
  });

  test('ResyncParams and StatusParams round-trip', () {
    final resync = ResyncParams(
        sub: 's1', epoch: 'e2', reason: 'gateway_stalled', stalledMs: 42000);
    final r = ResyncParams.fromJson(viaJson(resync.toJson()));
    expect(r.reason, 'gateway_stalled');
    expect(r.stalledMs, 42000);

    final status = StatusParams(
        alias: 'ST201', state: 'disconnected', error: 'BadNotConnected');
    final s = StatusParams.fromJson(viaJson(status.toJson()));
    expect(s.alias, 'ST201');
    expect(s.error, 'BadNotConnected');
  });

  test('a status frame names the gateway that observed the link', () {
    // Status is a notification: it arrives with no request to correlate it
    // against. On a LAN carrying two gateways that both watch an alias called
    // `ST201`, a capture of "ST201 went disconnected" is ambiguous without
    // this, and the two answers ("the bench rig lost its fake PLC" versus
    // "the plant lost a real one") are not close to each other.
    final status = StatusParams(
      alias: 'ST201',
      state: 'disconnected',
      error: 'BadNotConnected',
      publisherId: 'gw-st101',
    );

    final wire = status.toJson();
    expect(wire['publisherId'], 'gw-st101');
    expect(StatusParams.fromJson(viaJson(wire)).publisherId, 'gw-st101',
        reason: 'the client routes this notification through the DTO '
            '(connection_supervisor), so a field that does not survive '
            'fromJson is a field no client can ever read');
  });

  test('a status frame with no publisher name is byte-identical to the '
      'frame this build sent before the field existed', () {
    final status =
        StatusParams(alias: 'ST201', state: 'disconnected', error: 'Bad');

    final wire = status.toJson();
    expect(wire.containsKey('publisherId'), isFalse);
    expect(jsonEncode(wire),
        '{"alias":"ST201","state":"disconnected","error":"Bad"}',
        reason: 'status is the notification path, where a decoder that '
            'chokes throws somewhere nothing catches (03-REVIEW WR-06). The '
            'frame a publisher-less gateway sends must not have moved by a '
            'byte');
    expect(StatusParams.fromJson(viaJson(wire)).publisherId, isNull);
  });

  test('WriteParams round-trips and can never poison a frame', () {
    final w = WriteParams(
        cmd: '01J8', key: 'ST101.x', value: 1500, expect: 1400, ttlMs: 15000);
    expect(() => jsonEncode(w.toJson()), returnsNormally);
    final r = WriteParams.fromJson(viaJson(w.toJson()));
    expect(r.cmd, '01J8');
    expect(r.value, 1500);
    expect(r.expect, 1400);
    expect(r.ttlMs, 15000);
  });

  group('WriteParams refuses a non-finite argument', () {
    // CR-03. Sanitizing is right for telemetry; on the write path it turns
    // an operator's intent into a different actuation, silently.

    test('a non-finite value would write null to the tag', () {
      expect(
          () => WriteParams(cmd: '01J8', key: 'ST101.x', value: double.nan),
          throwsA(isA<ArgumentError>()
              .having((e) => e.name, 'name', 'value')
              .having((e) => e.message.toString(), 'message',
                  contains('did not choose'))));
    });

    test('a non-finite expect would drop the compare-and-set guard', () {
      // The sharper of the two: null means "no guard" in this encoding, so
      // a guarded write would silently become an unconditional one.
      expect(
          () => WriteParams(
              cmd: '01J8',
              key: 'ST101.x',
              value: 1,
              expect: double.infinity),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'expect')));
    });

    test('a non-finite buried inside a structure is found too', () {
      expect(
          () => WriteParams(
              cmd: '01J8',
              key: 'ST101.setpoint',
              value: {
                'lo': 1.0,
                'hi': [2.0, double.negativeInfinity]
              }),
          throwsArgumentError);
    });

    test('a 1e999 arriving from a peer is a malformed frame, not a write', () {
      // jsonDecode turns 1e999 into Infinity without complaint, so the
      // refusal is reachable from the wire; there it is a FormatException.
      final decoded = jsonDecode('{"cmd":"c","key":"k","value":1e999}')
          as Map<String, Object?>;
      expect(() => WriteParams.fromJson(decoded), throwsFormatException);
    });

    test('a finite write is untouched', () {
      final w = WriteParams(cmd: 'c', key: 'k', value: 0.0, expect: -1.5);
      expect([w.value, w.expect], [0.0, -1.5]);
    });
  });

  group('WriteParams carries the hold flag', () {
    // D-P5-C: engage and release are ordinary write frames carrying an
    // optional hold flag, so the request table stays at nine names and the
    // three-state outcome comes for free.

    test('a hold engage round-trips with the flag set', () {
      final w = WriteParams(cmd: '01J8', key: 'ST101.jog', value: 1, hold: true);
      expect(w.hold, isTrue);
      expect(w.toJson()['hold'], true);
      expect(WriteParams.fromJson(viaJson(w.toJson())).hold, isTrue);
    });

    test('an ordinary write omits the flag from the frame', () {
      final w = WriteParams(cmd: '01J8', key: 'ST101.sp', value: 5);
      expect(w.hold, isFalse);
      expect(w.toJson().containsKey('hold'), isFalse,
          reason: 'the hot path pays nothing for a field it does not use');
    });

    test('a frame with no hold key decodes to false', () {
      final decoded = jsonDecode('{"cmd":"c","key":"k","value":1}')
          as Map<String, Object?>;
      expect(WriteParams.fromJson(decoded).hold, isFalse);
    });

    test('a non-boolean hold flag is a malformed frame, not a coerced true',
        () {
      final decoded = jsonDecode('{"cmd":"c","key":"k","value":1,"hold":"yes"}')
          as Map<String, Object?>;
      expect(() => WriteParams.fromJson(decoded), throwsFormatException,
          reason: 'coercing would turn an ordinary write into a hold engage, '
              'or the reverse, and the gateway routes on this flag');
    });
  });

  group('WriteStatusParams', () {
    test('round-trips the ids it was asked about', () {
      final p = WriteStatusParams(const ['01ONE', '01TWO']);
      expect(p.toJson(), {
        'cmds': ['01ONE', '01TWO'],
      });
      expect(WriteStatusParams.fromJson(viaJson(p.toJson())).cmds,
          ['01ONE', '01TWO']);
    });

    test('a non-string cmd is refused at decode, not at iteration', () {
      // 05-REVIEW IN-03. `(json['cmds'] as List).cast<String>()` is a lazy
      // view: it decodes without complaint and throws later, wherever the
      // list is first walked — outside the decoder's try, which is exactly
      // the shape this package's tolerant decoders are built against.
      final decoded =
          jsonDecode('{"cmds":["01ONE",7]}') as Map<String, Object?>;
      expect(() => WriteStatusParams.fromJson(decoded), throwsFormatException,
          reason: 'the frame was accepted and the failure deferred to '
              'whoever iterates the list next');
    });

    test('a cmds that is not a list at all is refused', () {
      expect(() => WriteStatusParams.fromJson(const {'cmds': '01ONE'}),
          throwsFormatException);
      expect(() => WriteStatusParams.fromJson(const {}), throwsFormatException);
    });
  });

  group('HoldTickParams', () {
    test('round-trips through the slim wire keys', () {
      final t = HoldTickParams(key: 'ST101.CN01.jog', counter: 42);
      expect(t.toJson(), {'k': 'ST101.CN01.jog', 'n': 42});
      final r = HoldTickParams.fromJson(viaJson(t.toJson()));
      expect(r.key, 'ST101.CN01.jog');
      expect(r.counter, 42);
    });

    test('a tick with no key names no tag and is refused', () {
      expect(() => HoldTickParams.fromJson(const {'n': 1}),
          throwsFormatException);
      expect(() => HoldTickParams.fromJson(const {'k': '', 'n': 1}),
          throwsFormatException);
    });

    test('a non-numeric counter is refused', () {
      expect(() => HoldTickParams.fromJson(const {'k': 'x', 'n': 'two'}),
          throwsFormatException);
      expect(() => HoldTickParams.fromJson(const {'k': 'x'}),
          throwsFormatException);
    });

    test('a fractional counter is refused', () {
      expect(() => HoldTickParams.fromJson(const {'k': 'x', 'n': 1.5}),
          throwsFormatException);
    });

    test('a 1e999 counter decodes to Infinity and is refused', () {
      // The same poison the write path refuses: jsonDecode turns 1e999 into
      // Infinity without complaint, and `Infinity.toInt()` throws something
      // nobody at the boundary is catching.
      final decoded =
          jsonDecode('{"k":"ST101.jog","n":1e999}') as Map<String, Object?>;
      expect(() => HoldTickParams.fromJson(decoded), throwsFormatException);
    });

    test('a tick that names no tag cannot be constructed either', () {
      expect(() => HoldTickParams(key: '', counter: 1), throwsArgumentError);
    });
  });

  /// The delivery ack (`16-02-DECISION.md` §5.1). `ping` grows one optional
  /// params object carrying, per subscription, the highest sequence the client
  /// has actually **applied** — the numerator of the gap the gateway's
  /// slow-consumer verdict has been computing against a null since 16-08.
  ///
  /// **Every arm here is a tolerance arm, and that is the design.** A `ping`
  /// is the one frame that must never fail: it is what stops the reaper, so a
  /// decode that throws on a malformed ack would convert a client with a
  /// cosmetic bug into a client that is disconnected every heartbeat. The rule
  /// §5.1 sets is that each malformation degrades to *no ack for that
  /// subscription* and never to an exception — so the beat still lands, still
  /// moves the deadline, and the gateway simply learns nothing about delivery
  /// from it. That is the same answer it gets from a panel too old to send one.
  group('PingParams — the delivery ack on the wire', () {
    test('round-trips the applied sequence per subscription', () {
      const p = PingParams(ack: {'page-1': 10432, 'pane-motor-3': 88});
      expect(p.toJson(), {
        'ack': {'page-1': 10432, 'pane-motor-3': 88}
      });
      final r = PingParams.fromJson(viaJson(p.toJson()));
      expect(r.ack, {'page-1': 10432, 'pane-motor-3': 88});
    });

    test('a ping with no ack at all stays valid, for ever', () {
      // §5.1's compatibility promise: the gateway and the panels do not ship
      // together, so a beat from a build that predates this field must remain
      // an ordinary beat rather than becoming a refusal.
      expect(const PingParams().ack, isEmpty);
      expect(PingParams.fromJson(const {}).ack, isEmpty);
      expect(PingParams.fromJson(const {'futureField': 123}).ack, isEmpty);
      // And it does not put an empty object on the wire to say nothing with.
      expect(const PingParams().toJson(), isEmpty);
    });

    test('a non-map ack degrades to no ack, rather than throwing', () {
      for (final poison in <Object?>[
        'page-1',
        42,
        <String>['page-1'],
        null,
        true,
      ]) {
        expect(PingParams.fromJson({'ack': poison}).ack, isEmpty,
            reason: 'an ack of ${poison.runtimeType} must cost the beat '
                'nothing: a ping that throws is a panel the reaper collects '
                'for a malformed optional field');
      }
    });

    test('a non-integer sequence drops that subscription and keeps the rest',
        () {
      final r = PingParams.fromJson(const {
        'ack': {
          'page-1': 'ten thousand',
          'page-2': null,
          'page-3': 1.5,
          'page-4': <String, Object?>{},
          'page-5': 7,
        }
      });
      expect(r.ack, {'page-5': 7},
          reason: 'each bad entry degrades on its own — one unparseable '
              'subscription must not blind the gateway to the four beside it');
    });

    test('a 1e999 sequence is dropped, not rounded into an ack', () {
      // The decode poison this codebase defuses at every boundary: jsonDecode
      // turns 1e999 into Infinity silently, and `Infinity.toInt()` throws
      // inside whatever `try` the caller did not write. Refusing anything that
      // is not already an `int` defuses it here by construction — and refusing
      // rather than clamping matters, because a clamped Infinity is
      // `sentSeq`, which is an ack the client never sent claiming it is
      // perfectly caught up.
      final decoded =
          jsonDecode('{"ack":{"page-1":1e999}}') as Map<String, Object?>;
      expect(PingParams.fromJson(decoded).ack, isEmpty);
    });

    test('a non-string subscription name is dropped', () {
      final decoded = jsonDecode('{"ack":{"7":3}}') as Map<String, Object?>;
      // JSON object keys are strings, so this is what an integer-keyed ack
      // actually arrives as, and it is a legal subscription name to look up.
      expect(PingParams.fromJson(decoded).ack, {'7': 3});
    });
  });

  test('Icelandic strings survive every shape they can appear in', () {
    const name = 'Þorskflök í raspi';
    final u = UpdateParams(
        sub: 's1', seq: 1, t: 2, changes: {1: WireValue.of(name)});
    expect(
        UpdateParams.fromJson(viaJson(u.toJson())).changes[1]!.v, name);
    final rej = SubscribeResult.fromJson(viaJson(SubscribeResult(
      sub: 's1', epoch: 'e', seq: 0, handles: const {},
      snapshot: const {},
      rejected: {name: const KeyReject('unknown_key', message: name)},
    ).toJson()));
    expect(rej.rejected[name]!.message, name);
  });
}
