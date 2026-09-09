/// A key the binding can NEVER decode must say so — not sit at
/// `uncertainNotYetKnown` for the life of the process.
///
/// **The finding, measured by the 200-server bench:** Guid, ByteString,
/// LocalizedText and the built-in `Range` struct are undecodable by the pinned
/// binding. On the subscribe path the decode throw happens inside the
/// binding's monitor callback and is written to **stderr and nowhere else**
/// (`client.dart`, the `_safeErr("Error converting data for: …")` catch), so
/// the adapter's `listen`/`onError` pair never fires and the key stays at 258
/// forever — indistinguishable from "merely late". That is the quiet lie this
/// milestone exists to end, in its third shape.
///
/// **The repair under test:** the read path DOES propagate the decode throw
/// (`'Unsupported nodeId type: …'`, a string — and under `useIsolate: true`
/// every error is a string by construction). So `_establish` fires a one-shot
/// **decode probe** read per key per epoch; a probe that fails with a
/// non-transient (error-band) classification publishes that verdict for the
/// key, and a probe that fails transiently publishes NOTHING — the comm
/// machinery owns transients, and a probe that painted every slow key red
/// would replace a quiet lie with a loud one.
///
/// `FakeUaClient` rather than the real in-process server, deliberately: the
/// real server cannot serve a Guid variable through this binding at all (the
/// same serializer gap, from the other side), and what these cases judge is
/// this package's own bookkeeping — what the link does when the read path
/// throws the binding's exact sentence.
library;

import 'dart:async';

import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, OpcUANodeConfig;
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:open62541/open62541.dart' as ua;

import 'support/fake_ua_client.dart';

const String alias = 'ST101';
const String guidKey = 'ST101.CN01.MOT01.guid';
const String plainKey = 'ST101.CN01.MOT01.speed';

/// The pinned binding's exact decode-failure sentence (`common.dart:170`),
/// as the bench reproduced it for `i=14` (Guid).
const String unsupportedGuid =
    'Unsupported nodeId type: NodeId(namespace: 0, identifier: 14)';

KeyMappingEntry nodeEntry(String key) => KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'GVL.$key')
        ..serverAlias = alias,
    );

({OpcUaUpstreamLink link, FakeUaClient client}) build() {
  final client = FakeUaClient();
  final link = OpcUaUpstreamLink(
    alias: alias,
    endpoint: 'opc.tcp://127.0.0.1:4840',
    client: client,
    epochReader: _quietEpoch,
    // Parked, as in opcua_lifecycle_test.dart: the only reads a case sees in
    // `client.reads` must be the ones under test.
    iteratePeriod: const Duration(seconds: 30),
  );
  return (link: link, client: client);
}

Future<EpochInputs> _quietEpoch(ua.ClientApi client,
        {required Duration deadline, ua.NodeId? buildStampNode}) async =>
    EpochInputs(startTime: DateTime.utc(2026), namespaceArrayHash: 'abc');

void main() {
  group('an undecodable type speaks instead of sitting at not-yet-known', () {
    test(
        'the decode probe turns the binding\'s swallowed throw into '
        'errorTypeMismatch with a null payload', () async {
      final built = build();
      addTearDown(built.link.dispose);
      await built.link.connect(deadline: const Duration(seconds: 5));

      final ref = built.link.resolve(guidKey, nodeEntry(guidKey))!;
      built.client.readFailure = unsupportedGuid;

      final events = <DynamicValue>[];
      built.link.subscribe(ref).listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, isNotEmpty,
          reason: 'the silence under test: the monitor callback swallowed the '
              'decode throw, nothing probed, and the key never spoke');
      expect(events.last.quality, Quality.errorTypeMismatch,
          reason: 'non-transient: waiting will not teach the binding Guid, '
              'and a transient label (badCommFault/258) tells the operator '
              'to keep waiting');
      expect(events.last.value, isNull,
          reason: 'no payload was ever decoded; a non-null here would be an '
              'invented reading');
      expect(built.link.peek(ref)!.quality, Quality.errorTypeMismatch,
          reason: 'the verdict must be cached, not only streamed — a page '
              'opened later reads peek');
    });

    test(
        'BOTH polarities: a key that merely has not arrived yet stays silent '
        '(not-yet-known), while the undecodable one beside it speaks',
        () async {
      final built = build();
      addTearDown(built.link.dispose);
      await built.link.connect(deadline: const Duration(seconds: 5));

      // Arm 1: decodes fine (probe read succeeds), no sample has arrived yet.
      final plainRef = built.link.resolve(plainKey, nodeEntry(plainKey))!;
      final plainEvents = <DynamicValue>[];
      built.link.subscribe(plainRef).listen(plainEvents.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(plainEvents, isEmpty,
          reason: 'polarity guard: a slow key must NOT become an error — the '
              'probe may only publish what it affirmatively learned, or half '
              'the plant is red at boot');
      expect(built.link.peek(plainRef), isNull,
          reason: 'nothing arrived and nothing was invented: the composer '
              'keeps reading this as uncertainNotYetKnown');

      // Arm 2 (the live control that proves arm 1 can fail): the sibling key
      // whose probe DOES throw the decode sentence speaks, on the same link,
      // in the same window.
      built.client.readFailure = unsupportedGuid;
      final guidRef = built.link.resolve(guidKey, nodeEntry(guidKey))!;
      final guidEvents = <DynamicValue>[];
      built.link.subscribe(guidRef).listen(guidEvents.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(guidEvents.map((e) => e.quality), contains(Quality.errorTypeMismatch));
      expect(plainEvents, isEmpty,
          reason: 'the undecodable verdict must not leak onto the key that '
              'is merely un-arrived');
    });

    test('a TRANSIENT probe failure publishes nothing — comm faults are not '
        'this probe\'s news', () async {
      final built = build();
      addTearDown(built.link.dispose);
      await built.link.connect(deadline: const Duration(seconds: 5));

      final ref = built.link.resolve(guidKey, nodeEntry(guidKey))!;
      built.client.readFailure = 'Connection reset by peer';

      final events = <DynamicValue>[];
      built.link.subscribe(ref).listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, isEmpty,
          reason: 'a probe that grades a socket hiccup as a per-key verdict '
              'is a second lie; the link machinery owns transients');

      // Live control: the same key, the same subscription — only the sentence
      // changes to the binding's decode failure, re-probed under a new epoch,
      // and now it speaks.
      built.client.readFailure = unsupportedGuid;
      built.link.debugBumpEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.map((e) => e.quality), contains(Quality.errorTypeMismatch));
    });

    test('probed once per key per epoch, and the verdict is not re-spammed',
        () async {
      final built = build();
      addTearDown(built.link.dispose);
      await built.link.connect(deadline: const Duration(seconds: 5));

      final ref = built.link.resolve(guidKey, nodeEntry(guidKey))!;
      built.client.readFailure = unsupportedGuid;

      final events = <DynamicValue>[];
      built.link.subscribe(ref).listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(built.client.reads, hasLength(1),
          reason: 'one probe per key per epoch — this is the "log once per '
              'key, not per sample" discipline in read form');
      final verdicts =
          events.where((e) => e.quality == Quality.errorTypeMismatch).length;
      expect(verdicts, 1);

      // A reprogram is the one moment the type can genuinely change, so a new
      // epoch re-probes — and a verdict identical to the cached one is not
      // re-published (the band guard already refuses the duplicate).
      built.link.debugBumpEpoch();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(built.client.reads, hasLength(2),
          reason: 're-probed under the new epoch: after a PLC download the '
              'tag may have become decodable, and never re-asking would make '
              'the verdict permanent across reprograms');
      expect(
          events.where((e) => e.quality == Quality.errorTypeMismatch).length,
          1,
          reason: 'same verdict, no second event — dedup is what keeps this '
              'off the hot path');
    });
  });
}
