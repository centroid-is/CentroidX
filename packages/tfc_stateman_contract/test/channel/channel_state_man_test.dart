/// The client end of the harness, on the properties the sub-suites do not
/// reach.
///
/// `channel_subscribe_contract_test.dart` and `channel_store_contract_test.dart`
/// judge this implementation against the Phase 1 cases, which is the real
/// verdict. What is left over is a short list of things those cases assume
/// rather than assert, and each one is a way the harness could look right and
/// be measuring the wrong object: a client that answered `read` from something
/// other than its own store, a client whose `subscribe` streams outlive the
/// source, a client that satisfied `StateManApi` but not `harnessOf`, and the
/// round-trip counter — which lives on the *served* side and is therefore the
/// one observable a naive channel client would silently stop being judged by.
///
/// The write cases at the bottom are here for a different reason: they reach
/// arms of `WriteResult` and corners of the write path that no healthy source
/// produces, so `channel_write_contract_test.dart` — which is the real verdict
/// on the write path — could never exercise them. [WriteNotReceived] is a
/// `writeStatus` answer, and a non-finite number is a thing `jsonEncode`
/// refuses to put in a frame at all.
@Tags(['meta'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

const _speedKey = 'ST101.CN01.MOT01.speed';
const _otherKey = 'ST201.CN04.MOT01.speed';
const _missingKey = 'ST301.CN17.VLV02.stat';

/// A setpoint: the key a write case writes to, and the one the write contract
/// uses, so a failure here reads against the same tag.
const _setpointKey = 'ST101.CN01.MOT01.setpoint';

void main() {
  test('a driver can take the control surface off it', () {
    final api = channelServedFake();
    addTearDown(api.dispose);

    // Not `expect(api, isA<StateManHarness>())`: harnessOf is what every
    // sub-suite actually calls, and it reports a missing control surface
    // through `fail` rather than a cast error. Calling it is the only way to
    // prove the message an author would get is the one they should get.
    expect(harnessOf(api), same(api),
        reason: 'a channel-served implementation that does not satisfy '
            'harnessOf cannot be handed to any sub-suite at all — no case '
            'could make a value arrive for it');
  });

  test('read answers from the client store: null until an update arrives',
      () async {
    final api = channelServedFake();
    addTearDown(api.dispose);
    final plant = harnessOf(api);

    expect(api.read(_speedKey), isNull,
        reason: 'a key nothing has arrived for must read as not-known, which '
            'is a different fact from a known-bad value and the reason read() '
            'is nullable at all');

    final seen = observe(api.listen(_speedKey));
    plant.setValue(_speedKey, 1450);
    await within(seen.next, 'the first value arriving over the channel');

    expect(api.read(_speedKey)?.asInt, 1450);
    expect(api.read(_missingKey), isNull,
        reason: 'a key the source never served must stay unknown on the '
            'client; a client that invented a value for it would launder a '
            'mistyped page binding into a plausible reading');
    expect(api.keys, contains(_speedKey),
        reason: 'the client key list must grow as updates arrive — it is what '
            'the picker and the diagnostics page read');
  });

  test('a quality change with an unchanged number still notifies; an '
      'identical re-delivery does not', () async {
    final api = channelServedFake();
    addTearDown(api.dispose);
    final plant = harnessOf(api);

    final node = api.listen(_speedKey);
    final seen = observe(node);
    plant.setValue(_speedKey, 1450);
    await within(seen.next, 'the first value');

    plant.setQuality(_speedKey, Quality.badStale);
    await within(seen.next, 'the notification for a value that went stale');
    expect(node.value.quality, Quality.badStale,
        reason: 'the number did not move but its trustworthiness did, and that '
            'is the change an operator most needs to see — a client that '
            'compared values only would leave a stale reading looking healthy');

    final before = seen.count;
    plant.setValue(_speedKey, 1450, quality: Quality.badStale);

    // A barrier on a key that genuinely changed, so the absence of an event is
    // asserted after something that would have carried one.
    final barrier = observe(api.listen(_otherKey));
    plant.setValue(_otherKey, 3);
    await within(barrier.next, 'a genuinely changed key notifying');

    expect(seen.count, before,
        reason: 're-delivering an identical value over the channel rebuilt the '
            'page. The unchanged-value guard has to survive encode/decode, or '
            'every poll cycle costs a rebuild per key on the busiest page in '
            'the plant');
  });

  test('dispose closes every stream subscribe handed out', () async {
    final api = channelServedFake();
    addTearDown(api.dispose);
    final plant = harnessOf(api);

    final closed = Completer<void>();
    final firstValue = Completer<DynamicValue>();
    final received = <DynamicValue>[];
    final subscription = api.subscribe(_speedKey).listen(
      (value) {
        received.add(value);
        if (!firstValue.isCompleted) firstValue.complete(value);
      },
      onDone: closed.complete,
    );
    addTearDown(subscription.cancel);

    plant.setValue(_speedKey, 1450);
    await within(firstValue.future,
        'the subscribe() stream carrying a value over the channel');

    await within(api.dispose(), 'dispose() completing');
    await within(closed.future,
        'the handed-out stream closing when the source was disposed');

    expect(received.single.asInt, 1450,
        reason: 'the stream adapter must carry what the store carries; two '
            'numbers for one tag on one page is the worst thing this API can '
            'do');
  });

  test('the round-trip counter measures the client, though it lives on the '
      'source', () async {
    final api = channelServedFake();
    addTearDown(api.dispose);
    final plant = harnessOf(api);

    plant.setValue(_speedKey, 1450);
    plant.setValue(_otherKey, 3);
    await within(observe(api.listen(_otherKey)).next, 'the seed values',
        budget: const Duration(seconds: 1));

    final before = plant.roundTrips;
    final many = await within(
        api.readMany([_speedKey, _otherKey]), 'readMany over the channel');

    expect(many[_speedKey]?.asInt, 1450);
    expect(plant.roundTrips - before, 1,
        reason: 'reading two keys cost ${plant.roundTrips - before} round '
            'trips. A client that fans readMany out into one request per key '
            'is invisible on its own side and shows up here — which is the '
            'whole reason this counter is read off the served source rather '
            'than mirrored over the channel');

    await within(api.readFresh(_speedKey), 'readFresh over the channel');
    expect(plant.roundTrips - before, 2,
        reason: 'a forced read must reach the source; a client answering it '
            'from its own cache would defeat the one call a diagnostics page '
            'makes when the cache is the thing under suspicion');
  });

  // ------------------------------------------------------------- write path

  test('a driver can take the *write* control surface off it', () {
    final api = channelServedFake();
    addTearDown(api.dispose);

    // The same argument as `harnessOf` above, one interface along: five of the
    // ten write cases pull a lever that only exists here, and
    // `writeHarnessOf` is what reports a missing one as a sentence rather than
    // as a cast error naming a line in the contract package.
    expect(writeHarnessOf(api), same(api),
        reason: 'a channel-served implementation that does not satisfy '
            'writeHarnessOf cannot be handed to runWriteContract at all — no '
            'case could make the device answer for it');
  });

  test('every arm of the write outcome survives the round trip', () async {
    // Scripted rather than provoked, because two of the four are unreachable
    // through a healthy source: WriteNotReceived is a `writeStatus` answer,
    // and the applied/rejected arms carry fields (`at`, `status`) that a live
    // source fills with values a test cannot predict. What is being measured
    // is the encoding, so the outcomes have to be known exactly.
    const applied = WriteApplied('01JBQ0000000000000000APPLY',
        readback: 1500, at: 1786000000000);
    const rejected = WriteRejected(
        '01JBQ0000000000000000REJEC',
        WriteReason('interlocked',
            message: 'guard door open', status: 'Bad_NotWritable'),
        at: 1786000000001);
    const unknown = WriteUnknown('01JBQ0000000000000000UNKNO',
        WriteReason('plc_timeout', message: 'the device never answered'));
    const notReceived = WriteNotReceived('01JBQ0000000000000000NOTRE');

    final source = _ScriptedWrites([applied, rejected, unknown, notReceived]);
    final pair = channelPair();
    final session = serveStateMan(source, pair.server);
    final api = ChannelStateMan(
      channel: pair.client,
      observables: source,
      closeServed: () async {
        await session.close();
        await source.dispose();
      },
    );
    addTearDown(api.dispose);

    for (final expected in <WriteResult>[
      applied,
      rejected,
      unknown,
      notReceived
    ]) {
      final got = await within(api.write(_setpointKey, 1500),
          'the ${expected.runtimeType} outcome coming back over the channel');

      expect(got.runtimeType, expected.runtimeType,
          reason: 'a ${expected.runtimeType} crossed the channel and arrived '
              'as a ${got.runtimeType}. The four arms are what a caller '
              'switches on, and two of them call for opposite operator '
              'actions — a boundary that folds one into another decides what '
              'an operator is told happened to the plant');
      expect(got.toJson(), expected.toJson(),
          reason: 'the outcome arrived with different fields than it left '
              'with: ${got.toJson()} against ${expected.toJson()}. The reason '
              'kind in particular is what a support engineer greps six months '
              'later');
    }
  });

  test('a non-finite value is refused, never nulled onto a live tag', () async {
    // `jsonEncode` throws on Infinity rather than emitting null, so the number
    // cannot cross this channel at all — and this side is the only side that
    // ever sees it. Sanitizing is the right answer for telemetry, where the
    // alternative is a frame that fails for every client on a real pipe. It is
    // the wrong one here: a nulled *value* is a write of null to a live tag,
    // which actuates the device with something nobody chose while the operator
    // is told the write applied, and the badge that used to follow it was
    // local to this one panel. Refused before the send, like the `expect`
    // below and like `WriteParams` one layer down.
    final api = channelServedFake();
    addTearDown(api.dispose);
    final plant = harnessOf(api);

    plant.setValue(_setpointKey, 1200);
    await arrived(api, _setpointKey);

    for (final poison in const <double>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      await expectLater(
          api.write(_setpointKey, poison), throwsArgumentError,
          reason: 'a write of $poison resolved instead of being refused. It '
              'cannot travel on this channel, so resolving means it was '
              'changed into a null that can — and the tag an operator is '
              'watching took it');
    }

    expect(api.read(_setpointKey)?.asInt, 1200,
        reason: 'the reading moved to ${api.read(_setpointKey)?.value} on a '
            'write that was refused; a refused write leaves the tag exactly '
            'as it was');
    expect(api.read(_setpointKey)?.quality, isNot(Quality.badNonFinite),
        reason: 'the key was badged a fault by a write that never happened. '
            'The plant has no fault here — one widget divided by zero');
  });

  test('a non-finite expect is refused, never nulled into an unguarded write',
      () async {
    final api = channelServedFake();
    addTearDown(api.dispose);

    // Nulling it would be the silent failure: null is this path's encoding of
    // "no compare-and-set guard", so a sanitized expect turns a guarded write
    // into an unconditional one — the operator's "only if it still reads
    // 1200" quietly becomes "whatever it reads".
    await expectLater(
        api.write(_setpointKey, 1500, expect: double.nan), throwsArgumentError,
        reason: 'a non-finite expect must be refused where it was typed. '
            'Nothing upstream of a write box can legitimately produce a NaN, '
            'so this is programmer error, and an error is the one thing the '
            'write path is allowed to do about it — as against hanging, which '
            'is what an unencodable request would otherwise become');
  });
}

/// A served source whose write answers are scripted.
///
/// Breaks the same seam every sabotage variant breaks
/// ([FakeStateMan.attemptUpstreamWrite]) and inherits everything else, so the
/// value path under these writes is the real one.
final class _ScriptedWrites extends FakeStateMan {
  _ScriptedWrites(this._answers);

  final List<WriteResult> _answers;
  var _next = 0;

  @override
  Future<WriteResult> attemptUpstreamWrite(
    String cmd,
    String key,
    Object? value, {
    Object? expected,
  }) async =>
      _answers[_next++];
}
