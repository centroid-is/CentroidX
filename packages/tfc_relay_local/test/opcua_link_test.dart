/// The OPC UA adapter, against a real OPC UA server.
///
/// `@TestOn('!windows')` for `subscription_inactivity_test.dart:1`'s reason:
/// the CI matrix includes `windows-latest` and an in-process open62541 `Server`
/// is not run there. The annotation goes on the FILE, which is why the legs
/// that need a real server live in their own files and the package's pure legs
/// stay vm-clean.
@TestOn('!windows')
@Tags(['opcua'])
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'support/opcua_server_fixture.dart';

/// The plant's own spelling, as everywhere else in this package.
const String speedKey = 'ST101.CN01.MOT01.speed';
const String setpointKey = 'ST101.CN01.MOT01.setpoint';
const String secondKey = 'ST101.CN02.MOT01.speed';

/// This link's alias. 08-04's handoff is emphatic: the router does **not**
/// filter candidate links by `server_alias` — it offers a key to every link in
/// order and takes the first claim — so the adapter checks the alias itself or
/// it takes another PLC's key on a two-PLC plant.
const String alias = 'ST101';

/// Generous: none of these cases is a latency measurement.
const Duration generous = Duration(seconds: 10);

/// The keymapping entry the router would hand `resolve`.
KeyMappingEntry mappingFor(String key, {String? serverAlias = alias, int? arrayIndex}) {
  final node = OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
    ..serverAlias = serverAlias
    ..arrayIndex = arrayIndex;
  return KeyMappingEntry()..opcuaNode = node;
}

/// A mapping entry describing a node this adapter cannot reach.
KeyMappingEntry get nonOpcUaMapping => KeyMappingEntry();

/// Waits until [link] reports [UpstreamLinkState.connected].
///
/// `connect()` returning is **not** the same as being connected, and that is
/// the adapter's design rather than a slow test: the state comes from
/// `ClientWrapper.effectiveStatus`, which stays `connecting` until the
/// heartbeat's first tick proves the data plane works. A link that went green
/// on a session activation and nothing else is the frozen-session failure with
/// a head start.
Future<void> awaitConnected(OpcUaUpstreamLink link,
    {Duration within = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(within);
  while (link.state != UpstreamLinkState.connected) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the link never reached connected; it is ${link.state} and the '
          'heartbeat has not ticked');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('the fixture stands up and comes down cleanly', () {
    test('ten times in a row, no port collision and no SEGV', () async {
      // The concurrency-tolerance claim the wave structure rests on, in the
      // cheapest form that can falsify it: a literal port would fail this on
      // the second iteration and a fixed range would fail it across two
      // shells. Ten cycles in one process is the first half; the second half
      // is running this file from two shells at once, which is an acceptance
      // criterion rather than a case (nothing inside one process can assert
      // about another).
      final ports = <int>{};
      for (var i = 0; i < 10; i++) {
        final fixture = await OpcUaServerFixture.start(valueKeys: [speedKey]);
        ports.add(fixture.port);
        await fixture.dispose();
      }
      expect(ports, hasLength(greaterThan(1)),
          reason: 'ten fixtures that all got the same port would mean the '
              'allocator is handing out a constant, and every claim this file '
              'makes about parallel runs would be false');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('a value from a real server carries the server\'s own time', () {
    late OpcUaServerFixture fixture;
    late OpcUaUpstreamLink link;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(
        valueKeys: [speedKey, secondKey],
        writeKeys: [setpointKey],
      );
      addTearDown(fixture.dispose);
      link = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        // False in the fixture so a test can reach into the client; true in
        // production, where the blocking FFI stays off the tick isolate.
        useIsolate: false,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);
    });

    test('read answers with the server\'s own source time, not with now',
        () async {
      // The cheap half of the headline claim, on the read path: the instant
      // comes off the wire and is not manufactured here. The offset arm below
      // is the one that can tell the two apart.
      fixture.setValue(speedKey, 3);
      final ref = link.resolve(speedKey, mappingFor(speedKey))!;

      final seen = await link.read(ref, deadline: generous);

      expect(seen.sourceTime, isNotNull,
          reason: 'a value with no source time is a value whose age nobody '
              'can compute, and the freshness sweep would then be measuring '
              'the gateway\'s own clock against itself');
    });

    test('a value with no source timestamp falls back to arrival, says so, '
        'and is NOT degraded for it', () async {
      // Nothing in this fixture can strip a source timestamp off the wire —
      // open62541's server supplies one for every sampled read — so the
      // fallback is exercised where it lives, as a function, and the counter
      // it feeds is asserted through the link.
      final before = link.sourceTimeFallbacks;
      final arrival = DateTime.utc(2026, 9, 1, 12);
      final translated = translateOpcUaSample(
        ua.DynamicValue(value: 7),
        arrivedAt: arrival,
        onSourceTimeFallback: () {},
      );

      expect(translated.sourceTime, arrival);
      expect(translated.quality, Quality.good,
          reason: 'a server that does not send a source timestamp is not a '
              'server sending a bad reading. Degrading the quality for it '
              'would make every such server permanently suspect');
      expect(link.sourceTimeFallbacks, before,
          reason: 'the counter belongs to the link, and this call did not go '
              'through one — a counter that moves for a bare function call is '
              'counting the test rather than the plant');
    });

    test('resolve claims its own alias and refuses another PLC\'s key', () {
      expect(link.resolve(speedKey, mappingFor(speedKey)), isNotNull);
      expect(link.resolve(speedKey, mappingFor(speedKey, serverAlias: 'ST201')),
          isNull,
          reason: '08-04: the router does not filter by alias, it asks every '
              'link in order and takes the first claim. A resolve that claims '
              'anything with the right SHAPE takes ST201\'s key on a two-PLC '
              'plant, and the router\'s ambiguity check does not save you '
              'because the two links have different aliases');
      expect(link.resolve(speedKey, nonOpcUaMapping), isNull,
          reason: 'an entry with no opcua_node is not this adapter\'s');
      expect(link.resolve(speedKey, const <String, Object?>{}), isNull,
          reason: 'and neither is something that is not a mapping entry at '
              'all — null is "not mine", never a throw');
    });

    test('a handle is stamped with the link\'s current epoch', () {
      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      expect(ref.epoch, link.epoch);
      expect(ref.alias, alias);
      expect(ref.key, speedKey);
    });

    test('read answers the server\'s value inside the deadline', () async {
      fixture.setValue(speedKey, 11);
      final ref = link.resolve(speedKey, mappingFor(speedKey))!;

      final seen = await link.read(ref, deadline: generous);

      expect(seen.value, 11);
      expect(seen.quality, Quality.good);
    });

    test('the link reports connected, and maps from EffectiveDeviceStatus',
        () async {
      expect(link.state, UpstreamLinkState.connected);
      expect(
          mapEffectiveStatus(EffectiveDeviceStatus.opcuaUnhealthy),
          UpstreamLinkState.unhealthy,
          reason: 'connected-but-the-subscription-is-dead is unhealthy, not '
              'connected. That is F27\'s shape and Phase 9 wants it');
      expect(mapEffectiveStatus(EffectiveDeviceStatus.connected),
          UpstreamLinkState.connected);
      expect(mapEffectiveStatus(EffectiveDeviceStatus.connecting),
          UpstreamLinkState.connecting);
      expect(mapEffectiveStatus(EffectiveDeviceStatus.disconnected),
          UpstreamLinkState.disconnected);
      expect(mapEffectiveStatus(EffectiveDeviceStatus.umasUnhealthy),
          UpstreamLinkState.unhealthy);
    });

    test('a write reaches the server exactly once and reads back applied',
        () async {
      final ref = link.resolve(setpointKey, mappingFor(setpointKey))!;

      final result = await link.write(ref, DynamicValue.of(5),
          cmd: 'cmd-1', deadline: generous);

      expect(result, isA<WriteApplied>());
      expect(result.cmd, 'cmd-1');
      expect(fixture.writeCount(setpointKey), 1,
          reason: 'counted at the far end of the wire, which is the only '
              'place that can tell one write from a re-issued one');
    });

    test('an array-element write is refused by name, without an expect',
        () async {
      // 08-06's handoff: guardArrayElementWrite has no caller until an adapter
      // that can see the arrayIndex calls it, and this is that adapter. The
      // UpstreamLink signature carries no `expect`, so an element write is
      // always the read-modify-write the ruling refuses.
      final ref = link.resolve(
          setpointKey, mappingFor(setpointKey, arrayIndex: 2))!;

      final result = await link.write(ref, DynamicValue.of(5),
          cmd: 'cmd-arr', deadline: generous);

      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.kind,
          'array_element_requires_expect');
      expect(fixture.writeCount(setpointKey), 0,
          reason: 'a refusal that still wrote is not a refusal');
    });

    test('a read-only link rejects rather than throwing', () async {
      final readOnly = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        useIsolate: false,
        supportsWrites: false,
      );
      addTearDown(readOnly.dispose);
      await readOnly.connect(deadline: generous);
      final ref = readOnly.resolve(setpointKey, mappingFor(setpointKey))!;

      final result = await readOnly.write(ref, DynamicValue.of(5),
          cmd: 'cmd-ro', deadline: generous);

      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Bad_NotWritable');
    });

    test('the iterate loop is supervised and stops on dispose', () async {
      // The shape being replaced is `state_man.dart:1364` and `:1398`: two
      // unawaited `() async {…}()` loops with a bare Logger() and no error
      // seam. The property that matters is that the loop is owned, countable
      // and stoppable.
      expect(link.iterateTicks, greaterThan(0),
          reason: 'a supervised loop that never ran is a loop nobody is '
              'driving, and every value in this file arrived by accident');
      final atDispose = link.iterateTicks;

      await link.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(link.iterateTicks, atDispose,
          reason: 'a timer that outlives dispose keeps a blocking FFI call on '
              'the event loop of whatever runs next');
      expect(link.iterateErrors, isEmpty,
          reason: 'and its errors reach a seam a test can read, rather than a '
              'bare Logger()');
    });
  });

  group('the headline: source time is the server\'s, not the arrival\'s', () {
    test(
        'a sample held on the wire for a second and a half still reports the '
        'instant the SERVER stamped', () async {
      // **How the offset is made, and why not the obvious way.** The plan asks
      // for a value published with a source timestamp a minute in the past.
      // That turned out not to be reachable through the pinned binding, and
      // the finding is recorded rather than worked around: `Server.write`
      // (`server.dart:1096`) hands `UA_Server_writeValue` a bare variant with
      // no timestamp control, `addDataSourceVariableNode`'s read callback
      // (`:275-325`) sets only the hasValue bit, and neither exposes
      // `sourceTimestamp`. Writing early and subscribing late was tried and
      // MEASURED: the offset came back as 66 ms, because the server restamps
      // at sampling time.
      //
      // So the offset is made at the other end. The sample is stamped by the
      // server at T0 and then **held in the proxy** for a second and a half
      // before it is allowed to arrive. The reported instant must be T0. An
      // adapter that stamps DateTime.now() reports the arrival instant and the
      // measured offset collapses to nearly zero — which is exactly the
      // discrimination the plan wanted, produced by delaying delivery rather
      // than by back-dating a stamp, and therefore using the real server's own
      // clock rather than a number this test made up.
      final fixture = await OpcUaServerFixture.start(
          valueKeys: [speedKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final proxy = fixture.proxy!;
      final link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);

      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      final seen = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(seen.add);
      addTearDown(sub.cancel);
      // Let the first sample through, so what follows is measured on an
      // established subscription rather than on session setup.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      seen.clear();

      // Withhold the server→client direction. The client keeps sending
      // PublishRequests — only the answers are held.
      proxy.bufferServerToClient = true;
      fixture.setValue(speedKey, 77);
      final stampedAround = DateTime.now().toUtc();

      const held = Duration(milliseconds: 1500);
      await Future<void>.delayed(held);
      // Phase 2's documented trap, named rather than worked around: `flush()`
      // is genuinely a no-op while withhold is OFF, so the order here is
      // load-bearing — release while still buffering, then stop buffering.
      proxy.flush();
      proxy.bufferServerToClient = false;

      final sample = await Future.any<DynamicValue>([
        Future<DynamicValue>.delayed(const Duration(seconds: 8),
            () => throw StateError('no sample arrived after the flush')),
        () async {
          while (seen.every((v) => v.value != 77)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return seen.firstWhere((v) => v.value == 77);
        }(),
      ]);
      final arrivedAt = DateTime.now().toUtc();
      final sourceTime = sample.sourceTime!.toUtc();
      final offset = arrivedAt.difference(sourceTime);

      print('HEADLINE server sourceTime = ${sourceTime.toIso8601String()}');
      print('HEADLINE arrival instant   = ${arrivedAt.toIso8601String()}');
      print('HEADLINE offset            = ${offset.inMilliseconds} ms');

      expect(sample.quality, Quality.good);
      expect(offset.inMilliseconds, greaterThan(1000),
          reason: 'the value was stamped by the server before it was held on '
              'the wire for ${held.inMilliseconds} ms. An adapter that stamps '
              'DateTime.now() reports the arrival instant, the offset '
              'collapses to milliseconds, and "fresh" comes to mean "we heard '
              'about it just now" rather than "the plant measured it just now"');
      expect(sourceTime.isBefore(stampedAround.add(const Duration(seconds: 1))),
          isTrue,
          reason: 'and it must be the instant around the write, not some '
              'other past instant — an adapter reporting a constant would '
              'pass the offset check above too');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
        'and a BAD sample carries the server\'s instant too, which is what the '
        'opt-in delivery flag actually buys', () async {
      // **This arm exists because the obvious sabotage survived twice, and the
      // second survival taught something worth writing down.** Dropping
      // `deliverBadStatus: true` does NOT change the quality: the binding's
      // dropped-sample path calls `addError('Failed to read value: '
      // '${statusCodeToString(code)}')`, and that sentence *names the code* —
      // `BadNodeIdUnknown` is in the string — so this adapter's text mapper
      // reads it correctly and answers `errorConfig` either way. That is a
      // genuine finding: the quality table does not rest on the flag alone,
      // and the text branch 08-06 assumed for writes is real on the read side
      // too.
      //
      // What the flag buys is the TIME. A delivered Bad sample arrives with
      // `hasStatus | hasSourceTimestamp` set and no payload (08-01's measured
      // 0b110), so it says WHEN the tag went bad. The error branch has no
      // timestamp at all and the adapter can only stamp the moment it noticed.
      // On a link that was blocked for a second and a half those are a second
      // and a half apart, and the difference is the operator's question:
      // "did this fail just now, or was it already failing before the
      // network went?"
      final fixture = await OpcUaServerFixture.start(
          valueKeys: [speedKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final proxy = fixture.proxy!;
      final link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);

      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      final seen = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      seen.clear();

      proxy.bufferServerToClient = true;
      fixture.deleteNode(speedKey);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      proxy.flush();
      proxy.bufferServerToClient = false;

      await Future<void>.delayed(const Duration(milliseconds: 800));
      final arrivedAt = DateTime.now().toUtc();
      final bad = seen.lastWhere((v) => v.quality.isError || v.quality.isBad,
          orElse: () => fail('no bad sample arrived at all'));
      final offset = arrivedAt.difference(bad.sourceTime!.toUtc());
      print('BADSAMPLE quality = ${bad.quality}');
      print('BADSAMPLE sourceTime = ${bad.sourceTime!.toUtc().toIso8601String()}');
      print('BADSAMPLE offset = ${offset.inMilliseconds} ms');

      expect(bad.quality, Quality.errorConfig);
      expect(offset.inMilliseconds, greaterThan(1000),
          reason: 'the server stamped this Bad sample when the tag went away, '
              'and it then sat on the wire. An adapter fed by the error '
              'channel instead has no server instant to report and stamps the '
              'moment it noticed — the offset collapses, and the operator is '
              'told the tag failed when the network came back rather than '
              'before it went');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('the quality table, against a real server', () {
    late OpcUaServerFixture fixture;
    late OpcUaUpstreamLink link;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(
        valueKeys: [speedKey],
        writeKeys: [setpointKey],
      );
      addTearDown(fixture.dispose);
      link = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        useIsolate: false,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);
    });

    test('a Bad sample arrives as a value with a mapped quality, not as a '
        'dropped sample', () async {
      // The opt-in delivery flag is what makes this possible at all: at the
      // binding's default a Bad sample is DROPPED and its code survives only
      // as English on the error channel (08-01). And a Bad sample carries no
      // payload — statusCode != 0 with a stale-or-null value — so arrival is
      // not evidence of freshness.
      final ref = link.resolve(setpointKey, mappingFor(setpointKey))!;
      final seen = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      fixture.setReadFails(setpointKey);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(seen.any((v) => v.quality.isBad || v.quality.isError), isTrue,
          reason: 'without deliverBadStatus: true the sample never arrives at '
              'all and this key just stops updating — a value frozen at its '
              'last plausible number, which is the exact failure this project '
              'exists to prevent');
      expect(seen.last.value, isNull,
          reason: 'a Bad DataValue has hasValue clear: there is no payload, '
              'and rendering the last one under a bad badge is still a number '
              'nobody measured');
    });

    test(
        'the CODE survives the trip: a deleted node reads errorConfig, which '
        'only the delivered sample can say', () async {
      // **This arm exists because a mutation survived without it.** Dropping
      // `deliverBadStatus: true` left the whole suite green: with the flag off
      // the binding discards the sample and pushes `'Failed to read value: …'`
      // onto the error channel instead, and the adapter's onError handler
      // turns that into a bad-quality value with a null payload — which every
      // other assertion in this file accepts.
      //
      // What the flag actually buys is the NUMBER. `'Failed to read value'`
      // names no status code, so the text path can only answer the transient
      // `badCommFault`; the delivered sample carries 0x80340000 and answers
      // `errorConfig`. "The link is having trouble, wait" and "this tag no
      // longer exists, stop waiting" are different instructions to an
      // operator, and this is the one assertion that can tell them apart.
      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      final seen = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      seen.clear();

      fixture.deleteNode(speedKey);
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(seen, isNotEmpty,
          reason: 'the tag disappearing must produce a sample. Silence here is '
              'a panel holding the last plausible number forever');
      expect(seen.last.quality, Quality.errorConfig,
          reason: 'the sample carried BadNodeIdUnknown. Without the opt-in '
              'delivery flag the code is replaced by an English sentence and '
              'this reads badCommFault — an operator told to wait for a tag '
              'that is never coming back');
      expect(seen.last.value, isNull);
    });

    test('BadNodeIdUnknown is errorConfig, because waiting will not fix it',
        () {
      expect(qualityForOpcUaStatus(opcUaBadNodeIdUnknown), Quality.errorConfig);
      expect(qualityForOpcUaStatus(opcUaBadNodeIdInvalid), Quality.errorConfig);
    });

    test('the code mapping is the table in §C.4', () {
      expect(qualityForOpcUaStatus(0), Quality.good,
          reason: 'an absent status means Good (Part 4), and 0 is a positive '
              'claim rather than the absence of one');
      expect(qualityForOpcUaStatus(null), Quality.good);
      expect(qualityForOpcUaStatus(opcUaBadCommunicationError),
          Quality.badCommFault);
      expect(qualityForOpcUaStatus(opcUaBadTypeMismatch),
          Quality.errorTypeMismatch);
      expect(qualityForOpcUaStatus(opcUaUncertainLastUsableValue),
          Quality.uncertainLastKnown);
      expect(qualityForOpcUaStatus(opcUaBadInternalError), Quality.badCommFault,
          reason: 'a Bad code this table does not name is a comms fault: the '
              'link said something went wrong and waiting might fix it. '
              'Calling it errorConfig would tell the operator to stop waiting');
    });

    test('read against a disconnected server answers inside the deadline and '
        'does not hang', () async {
      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      await fixture.dispose();

      final stopwatch = Stopwatch()..start();
      final seen = await link
          .read(ref, deadline: const Duration(milliseconds: 300))
          .timeout(const Duration(seconds: 5),
              onTimeout: () => fail('read outran its own deadline — this is '
                  'state_man.dart:1868 inherited rather than prevented, and a '
                  'disconnected PLC pends the caller forever'));
      stopwatch.stop();
      print('DEADLINE read answered in ${stopwatch.elapsedMilliseconds} ms');

      expect(seen.quality.isBad || seen.quality.isError, isTrue);
      expect(seen.value, isNull,
          reason: 'a timed-out read has no reading, and the last one is not '
              'an answer to the question that was asked');
    });

    test('a stale handle never answers a value', () async {
      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      link.debugBumpEpoch();

      final seen = await link.read(ref, deadline: generous);

      expect(seen.value, isNull,
          reason: 'SRV-07: no stale-handle read ever returns a value. The '
              'handle addresses a node that may now mean a different tag');
      expect(link.peek(ref), isNull);
      final written = await link.write(ref, DynamicValue.of(1),
          cmd: 'cmd-stale', deadline: generous);
      expect(written, isNot(isA<WriteApplied>()));
    });
  });

/// F7 from the rig sweep (RIG-TEST-FINDINGS.md): a key mapped with an
/// `array_index` must carry the ELEMENT, exactly as the shipped StateMan does
/// (`state_man.dart:1871` read, `:2553` subscribe, `:2033-2039` write). The
/// deployed gateway streamed the whole 10-element array under both
/// `data.real.1` and `data.real.5` and historised `double precision[]`
/// columns where the app's tables hold scalars — one key, two schemas,
/// depending on which process wrote it.
void arrayElementGroup() {
  group('a key with an array_index carries the element, not the array', () {
    const arrayKey = 'plant.rData';
    late OpcUaServerFixture fixture;
    late OpcUaUpstreamLink link;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(
        valueKeys: [arrayKey],
        // Born an array of doubles — see the fixture's seedValues doc; a
        // scalar-seeded node coerces the write below to a scalar.
        seedValues: {arrayKey: <double>[1.5, 2.5, 3.5]},
      );
      addTearDown(fixture.dispose);
      link = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        useIsolate: false,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);
    });

    test('read slices to the element and keeps the sample\'s envelope',
        () async {
      final ref =
          link.resolve(arrayKey, mappingFor(arrayKey, arrayIndex: 1))!;
      final seen = await link.read(ref, deadline: generous);
      expect(seen.value, 2.5,
          reason: 'the app\'s read does value[idx] '
              '(state_man.dart:1871); the deployed gateway returned the '
              'whole array and the panel\'s widget cast blew up');
      expect(seen.quality, Quality.good);
      expect(seen.sourceTime, isNotNull,
          reason: 'slicing must not cost the envelope: the source instant '
              'belongs to the sample, and the element is the sample here');
    });

    test('subscribe delivers elements, never the whole array', () async {
      final ref =
          link.resolve(arrayKey, mappingFor(arrayKey, arrayIndex: 2))!;
      final first = link
          .subscribe(ref)
          .firstWhere((v) => v.quality == Quality.good)
          .timeout(generous);
      fixture.setValue(arrayKey, [9.5, 8.5, 7.5]);
      final seen = await first;
      expect(seen.value, anyOf(3.5, 7.5),
          reason: 'either the initial sample or the update, but always one '
              'element — a mimic bound to a number cannot render a list');
      expect(seen.value, isNot(isA<List<Object?>>()));
    });

    test('an element write is a read-modify-write that spares the '
        'neighbours', () async {
      final ref =
          link.resolve(arrayKey, mappingFor(arrayKey, arrayIndex: 1))!;
      final result = await link.write(ref, DynamicValue.of(42.5),
          cmd: 'cmd-rmw', deadline: generous, hasExpect: true);
      expect(result, isA<WriteApplied>(),
          reason: 'with expect supplied the guard steps aside, and the '
              'documented read-modify-write must then actually exist: the '
              'deployed build would have written the scalar over the whole '
              'array node');
      final whole =
          await link.read(link.resolve(arrayKey, mappingFor(arrayKey))!,
              deadline: generous);
      expect([whole[0].value, whole[1].value, whole[2].value],
          [1.5, 42.5, 3.5],
          reason: 'one element changed, two survived — the whole point of '
              'read-modify-write');
    });

    test('an index past the end reads as errorTypeMismatch, not a throw',
        () async {
      final ref =
          link.resolve(arrayKey, mappingFor(arrayKey, arrayIndex: 9))!;
      final seen = await link.read(ref, deadline: generous);
      expect(seen.quality, Quality.errorTypeMismatch,
          reason: 'the mapping and the server disagree about the tag\'s '
              'shape; 771 is the code that says exactly that, and null under '
              'it is what stops the miss looking like an absent reading');
      expect(seen.value, isNull);
    });
  });
}

  arrayElementGroup();
}
