/// The read half of the contract: what asking for a value costs, and what
/// "not known" is allowed to look like.
///
/// Three reads exist on the interface and CONTEXT D-03 splits them by cost:
/// [StateManApi.read] is synchronous and answers from the cache (the
/// `DeviceClient.read` convention, `state_man.dart:861-891`),
/// [StateManApi.readFresh] forces a round trip for diagnostics and readback
/// checks, and [StateManApi.readMany] answers many keys in one. The split is
/// only worth having if the costs are real, so the cases here are about
/// arithmetic as much as about values: ten cached reads must cost nothing, one
/// forced read must cost exactly one round trip, and fifty keys must cost one
/// round trip rather than fifty. N round trips over a link with 200 ms of
/// latency is the failure mode `state_man_api.dart` names as the reason this
/// project exists.
///
/// The other half is the null convention. `read` returning null means "nothing
/// is known yet", which is a different fact from "known to be zero" and a
/// different fact again from "known to be bad". A widget that cannot tell them
/// apart draws a plausible reading for a tag that may not exist.
///
/// Shape follows `subscribe_contract.dart`: no implementation is imported, the
/// factory passed to [runReadContract] is the only coupling to one, every case
/// is a named top-level function so `test/sabotage_freshness_test.dart` can run
/// it against a damaged implementation, and every await is wrapped in [within]
/// so silence fails by name instead of hanging to the runner's timeout.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';

/// A motor speed on the pre-freezer conveyor line: the ordinary case.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key, used as a barrier: awaiting a notification that *must*
/// arrive is how a case proves something else did not happen, with no sleep.
const _otherKey = 'ST201.CN04.MOT01.speed';

/// A key no source in this suite ever delivers — a tag mistyped into a page
/// config, or renamed in the PLC since the page was drawn.
const _missingKey = 'ST301.CN17.VLV02.stat';

/// How many keys the batched-read case asks for at once.
///
/// The diagnostics page reads dozens of tags when it opens; fifty is that
/// order of magnitude and makes an N-round-trip implementation unmistakable.
const _batchedReadKeyCount = 50;

/// Fifty tags of the kind a diagnostics page opens with.
List<String> _diagnosticsKeys() => [
      for (var i = 1; i <= _batchedReadKeyCount; i++)
        'ST201.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

/// `read` presents no reading until a value has actually arrived, and the real
/// one after.
///
/// The distinction a widget cannot draw without: "nothing known yet" renders as
/// a placeholder and "known to be zero" renders as a zero. A source that
/// answers zero for an unknown key puts a plausible reading on a mimic for a
/// tag that may not exist at all.
///
/// **Two spellings of "nothing yet", and the case accepts exactly those two.**
/// A source that has never heard the key named answers `null`. A source that
/// declares its page up front — which every real one does, `LocalStateMan` from
/// its DeviceClient config and a panel from its subscribe — has heard the key
/// named and has been told there is no reading, and answers that state in the
/// vocabulary the protocol has for it: a value of `null` carrying
/// [Quality.uncertainNotYetKnown]. Neither is a reading, which is the property;
/// insisting on the first spelling was insisting on the in-memory fake's
/// *representation*.
///
/// That distinction had never actually been judged over a socket. Until the
/// suite grew [linkUp] the case ran before the gateway's snapshot landed, so on
/// the WS and fault legs it asserted `null` against a store that had not been
/// filled yet and passed by outrunning the transport. It is stricter now than
/// it was: the state it accepts is named, so a confident zero, a good-quality
/// null and a last-known reading all still fail it.
Future<void> checkSyncReadIsNullBeforeFirstValue(StateManApi api) async {
  final plant = harnessOf(api);

  final before = api.read(_speedKey);
  expect(
      before == null ||
          (before.value == null &&
              before.quality == Quality.uncertainNotYetKnown),
      isTrue,
      reason: 'a key nothing has been heard about read as $before; "not known '
          'yet" and "known to be zero" must be distinguishable, or every '
          'unbound box on a new page shows a confident number. A source that '
          'has not heard the key named answers null; one that declared it and '
          'has no reading answers a null value at '
          '${Quality.uncertainNotYetKnown.code}. Anything else is a reading '
          'that does not exist');

  final node = api.listen(_speedKey);
  final seen = observe(node);
  // Zero on purpose: the one reading that is indistinguishable from a
  // null-as-zero implementation, so the case fails against one.
  plant.setValue(_speedKey, 0);
  await within(seen.next, 'the first value for the key under test');

  final cached = api.read(_speedKey);
  expect(cached, isNotNull,
      reason: 'a value arrived and the synchronous read still reported '
          'nothing known — a widget building in that frame would draw a '
          'placeholder over a reading the source already had');
  expect(cached!.asInt, 0,
      reason: 'a genuine zero must survive the round trip through the cache; '
          'a source that treats zero as absent hides a stopped motor');
}

/// Ten synchronous reads cost no round trips at all.
///
/// `read` is documented as answering from the cache. An implementation that
/// quietly makes it a request turns a build — which reads every bound key —
/// into a burst of traffic on the slow link the API was shaped around.
Future<void> checkSyncReadCostsNoRoundTrip(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  // The ten reads below have to be reads of something *cached*, which is the
  // word the property uses. Without this barrier they are ten reads of a key
  // the source has not delivered yet on any implementation that delivers
  // asynchronously — and a miss is precisely where an implementation that
  // secretly round-trips would round-trip, so the case would be aimed away
  // from the behaviour it is named for.
  await arrived(api, _speedKey);
  final before = plant.roundTrips;

  for (var i = 0; i < 10; i++) {
    api.read(_speedKey);
  }

  // A round trip started but not yet awaited is still a round trip, so count
  // only after the event loop has turned — behind a barrier that must fire
  // rather than behind a sleep.
  final other = api.listen(_otherKey);
  final barrier = observe(other);
  plant.setValue(_otherKey, 3);
  await within(barrier.next, 'a genuinely changed key notifying');

  expect(plant.roundTrips, before,
      reason: 'ten cached reads cost ${plant.roundTrips - before} round '
          'trips; a widget rebuild reads every key it is bound to, so a read '
          'that touches the link turns one frame on a 1500-key page into a '
          'traffic burst on the connection this API exists to protect');
}

/// `readFresh` costs exactly one round trip and never answers with something
/// older than the cache already holds.
///
/// It exists for the case where the cache is the thing under suspicion — a
/// readback check after a write, a diagnostics page proving a value is real. An
/// implementation that answers it from the cache has removed the only tool for
/// distinguishing a live value from a remembered one.
Future<void> checkReadFreshCostsExactlyOneRoundTrip(StateManApi api) async {
  final plant = harnessOf(api);

  final stamped = DateTime.utc(2026, 8, 13, 6, 30);
  plant.setValue(_speedKey, 1450, sourceTime: stamped);
  // This case compares the forced read against the cache, so the cache has to
  // have something in it before the comparison is set up. An implementation
  // whose values cross a message boundary has not delivered the seed yet at
  // this line, and the assertion below would then blame the source for the
  // case's impatience.
  await arrived(api, _speedKey);
  final cached = api.read(_speedKey);
  expect(cached, isNotNull,
      reason: 'the case needs a cached value to compare against; the value '
          'the harness delivered never reached the cache');

  final before = plant.roundTrips;
  final fresh = await within(
      api.readFresh(_speedKey), 'readFresh resolving with a value');

  expect(plant.roundTrips, before + 1,
      reason: 'a forced read cost ${plant.roundTrips - before} round trips; '
          'zero means it answered from the cache it exists to bypass, and '
          'more than one means a diagnostics page paying an unpredictable '
          'multiple of the link latency per key');
  expect(fresh.asInt, 1450,
      reason: 'a forced read must return the reading the source actually has');
  final cachedTime = cached!.sourceTime;
  expect(cachedTime, isNotNull,
      reason: 'the harness delivered a stamped reading and the cache dropped '
          'the stamp; a value whose source time is gone cannot be aged by '
          'anything downstream');
  expect(fresh.sourceTime, isNotNull,
      reason: 'a freshly read value arrived without a source timestamp — '
          'nothing downstream can then judge how old it is, which is the one '
          'question readFresh is asked to settle');
  expect(fresh.sourceTime!.isBefore(cachedTime!), isFalse,
      reason: 'the forced read answered with a value older than the cached '
          'one; a readback check would confirm a write against a reading from '
          'before it was sent');
}

/// Fifty keys cost one round trip, not fifty.
///
/// The promise `readMany` is kept on the wire surface for. On a link with
/// 200 ms of latency the difference between one and fifty is ten seconds of a
/// diagnostics page that appears to have hung.
Future<void> checkReadManyCostsOneRoundTripForManyKeys(StateManApi api) async {
  final plant = harnessOf(api);

  final keys = _diagnosticsKeys();
  plant.setValues({
    for (var i = 0; i < keys.length; i++) keys[i]: 1000 + i,
  });

  final before = plant.roundTrips;
  final values = await within(
      api.readMany(keys), 'readMany over ${keys.length} keys resolving');
  final spent = plant.roundTrips - before;

  expect(spent, 1,
      reason: 'reading ${keys.length} keys cost $spent round trips; over a '
          'link with 200 ms of latency that is '
          '${(spent * 200 / 1000).toStringAsFixed(1)} s before the '
          'diagnostics page draws anything, and N round trips for N keys is '
          'precisely the failure this project exists to remove');
  expect(values, hasLength(keys.length),
      reason: 'the batched read answered for ${values.length} of '
          '${keys.length} keys');
  expect(values[keys.first]?.asInt, 1000,
      reason: 'a batched read must carry the readings, not just the keys');
}

/// Every requested key comes back, including the ones with nothing behind them.
///
/// A key omitted from the answer is indistinguishable from one that was never
/// asked for: the caller writes a blank cell where it needed to write a fault.
/// Absence must be reported as a bad-quality value, which renders, rather than
/// as a missing map entry, which does not.
Future<void> checkReadManyReturnsEveryRequestedKey(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  final values = await within(api.readMany([_speedKey, _missingKey]),
      'readMany resolving for a known and an unknown key');

  expect(values.keys, containsAll([_speedKey, _missingKey]),
      reason: 'a requested key was missing from the answer; the caller cannot '
          'tell an omitted key from an unasked one, so the diagnostics page '
          'shows an empty cell for a tag that is in trouble');
  expect(values[_speedKey]?.asInt, 1450,
      reason: 'the known key must carry its reading');
  expect(values[_missingKey]?.quality.isGood, isFalse,
      reason: 'a key with nothing behind it came back good; a null rendered '
          'under a good quality is a tag that looks healthy and empty, which '
          'is how a renamed PLC tag survives on a page for months');
}

/// Every read property, keyed by the sentence it asserts.
///
/// The key is the test name, so a failure in CI reads as the promise that was
/// broken rather than as a function identifier.
const readChecks = <String, Check<StateManApi>>{
  'a synchronous read is null until the first value arrives':
      checkSyncReadIsNullBeforeFirstValue,
  'a synchronous read costs no round trip': checkSyncReadCostsNoRoundTrip,
  'a forced read costs exactly one round trip and is never older than the '
      'cache': checkReadFreshCostsExactlyOneRoundTrip,
  'fifty keys cost one round trip, not fifty':
      checkReadManyCostsOneRoundTripForManyKeys,
  'a batched read answers for every key asked of it, including empty ones':
      checkReadManyReturnsEveryRequestedKey,
};

/// Registers the read contract against implementations from [make].
///
/// One fresh instance per case, disposed by `addTearDown`: the round-trip
/// counter is only meaningful when nothing from a previous case has spent any.
void runReadContract(StateManApi Function() make) {
  group('read', () {
    readChecks.forEach((property, check) {
      test(property, () async {
        final api = make();
        addTearDown(api.dispose);
        // The link, before the property. On an in-process source this is a
        // synchronous read and nothing more; behind a socket it is where the
        // connect, the handshake and the first subscribe come due, and leaving
        // them inside the case's own budget made the first check in this suite
        // a measurement of the transport (`harness.dart`'s [linkUp]).
        await linkUp(api);
        await check(api);
      });
    });
  });
}
