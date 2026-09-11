/// The freshness half of the contract: whether the number on the screen is
/// still true, and how the operator finds out that it is not.
///
/// This is the file the project's core value is written down in — *operators
/// can always trust what the screen shows: values are fresh or visibly stale*.
/// Everything else in the suite is about delivering values correctly and
/// cheaply; these cases are about the one failure that delivers nothing at all
/// and looks perfect while doing it. A page whose subscription died an hour ago
/// renders the same numbers, in the same colour, at the same refresh rate, as a
/// page watching a running plant. Nobody can see the difference by looking, so
/// the source has to say so.
///
/// Every case here is written from `relay-comm-design.md` rather than mirrored
/// from working code: RESEARCH grepped the existing codebase for
/// `sourceTimestamp`, `statusCode` and `DataValue` and found nothing — today's
/// values carry neither quality nor a timestamp, and no widget reads one. That
/// makes the sabotage variants in `broken_freshness.dart` unusually important:
/// with no incumbent behavior to compare against, `ServesStaleReads` and
/// `LiesAboutQuality` are the only evidence that these checks would catch the
/// two ways a real implementation will fail.
///
/// Four properties, in the order an operator meets them:
///
///  * **A value ages.** Past [StateManHarness.staleAfter] it reports
///    [Quality.badStale] through every read path, and going stale is itself a
///    change listeners hear about — the box greys out by itself.
///  * **A link dies.** Every affected key degrades to [Quality.badCommFault],
///    and the loss is announced **once**, not once per key.
///  * **The pipe reports on itself.** `PIPE.*` health keys are subscribable
///    like any plant tag (design §4.7, HLTH-01) and are excluded from their own
///    freshness accounting (HLTH-02) — a key that only changes when the link
///    changes is *always* older than the deadline on a healthy pipe, and
///    staling it would grey out the one indicator that says whether to trust
///    the rest of the screen.
///  * **Quality never heals on its own.** Only a new reading can improve it.
///
/// Timing is wall clock against the deadline the implementation declares,
/// because a freshness watchdog is precisely the machinery an injected clock
/// stops testing (CONTEXT's test-realism policy). There are no sleeps: where a
/// case needs to establish that the deadline has passed, it awaits a
/// notification that the deadline *causes* — a plant key going stale is both
/// the event and the proof, and it arrives as early as the implementation can
/// manage rather than as late as a hard-coded delay would.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';

/// A motor speed on the pre-freezer conveyor line: the ordinary case, a number
/// an operator reads off a mimic.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key on a different station, so "the link dropped" can be
/// distinguished from "one tag stopped".
const _otherKey = 'ST201.CN04.MOT01.speed';

/// The reserved namespace the pipe reports on itself through (design §4.7).
///
/// A prefix rather than a set: HLTH-02's exclusion rule is about the namespace,
/// and Phase 8's HLTH-03 will reject a plant keymapping that tries to claim a
/// name inside it.
const _healthPrefix = 'PIPE.';

/// Whether the pipe is up, as an ordinary subscribable value. There is no
/// health method on the wire — this key *is* the health API.
const _connectedKey = '${_healthPrefix}connected';

/// How many keys the announce-once case degrades at once.
///
/// Enough that a per-key fan-out is unmistakable, few enough to stay readable.
/// The page this promise was made about has 1500.
const _massDegradeKeyCount = 50;

/// How long a case will wait for something the freshness deadline causes.
///
/// Three times the declared deadline: tight enough that a source which never
/// runs its sweep fails quickly, tolerant enough to survive a sweep interval
/// and a loaded CI machine. CONTEXT's policy in one expression — tight but
/// tolerant, and derived from the implementation's own number rather than
/// guessed at by the suite.
Duration _deadlineBudget(StateManHarness plant) => plant.staleAfter * 3;

/// Plant keys of the kind one station's mimic is covered in.
List<String> _stationKeys(int count) => [
      for (var i = 1; i <= count; i++)
        'ST301.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
    ];

/// A value nobody has heard about since the deadline reports as stale, through
/// every read path, while keeping the reading it last had.
///
/// The case this whole project exists for. The alternative — a value that stays
/// good because nothing contradicted it — is a frozen-fresh view: an operator
/// reads a number that stopped being true minutes ago, decides on it, and has
/// no way to know. It must also keep the last reading, greyed, rather than
/// blanking: "it was 1450 and we have lost touch" is actionable, "———" is not.
Future<void> checkValuePastDeadlineBecomesBadStale(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  // The next notification has to be the one the deadline caused. Without this
  // barrier, on a source that delivers asynchronously the next notification is
  // the *seed*, and the case then reads a value that is still perfectly fresh
  // and reports the source as frozen-fresh — the exact accusation this file
  // exists to make, made falsely.
  await arrived(api, _speedKey);
  final node = api.listen(_speedKey);
  final seen = observe(node);

  await within(
      seen.next,
      'the value going stale past the '
      '${plant.staleAfter.inMilliseconds} ms freshness deadline',
      budget: _deadlineBudget(plant));

  expect(node.value.quality, Quality.badStale,
      reason: 'nothing has been heard about this key since the freshness '
          'deadline and it still reads as ${node.value.quality.code}; a '
          'frozen-fresh view is the single failure this project exists to '
          'prevent, because it is the one an operator cannot see by looking');
  expect(api.read(_speedKey)?.quality, Quality.badStale,
      reason: 'listen() and read() disagreed about whether the number can be '
          'trusted — two answers to the one question the operator is asking');
  expect(node.value.asInt, 1450,
      reason: 'the last known reading must survive going stale; the operator '
          'needs to see what it was, greyed out, not an empty box that looks '
          'like an unbound tag');
}

/// Going stale is itself a change, delivered once, without anyone polling.
///
/// The screen greys out by itself. A source that degrades the value but only
/// tells whoever asks again leaves every already-open page showing a
/// confident number, which is the same failure with extra steps.
Future<void> checkStaleTransitionNotifiesListeners(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  // Counting starts after the seed has landed, or the seed's own notification
  // is folded into the count this case promises is exactly one.
  await arrived(api, _speedKey);
  final node = api.listen(_speedKey);
  final seen = observe(node);

  await within(seen.next, 'the notification that the value went stale',
      budget: _deadlineBudget(plant));

  expect(seen.count, 1,
      reason: 'going stale cost ${seen.count} notifications; it is one change '
          'and must cost one rebuild — a watchdog that re-announces staleness '
          'on every sweep turns 1500 quiet keys into a permanent rebuild '
          'storm the moment the plant goes idle');
  expect(node.value.quality.isGood, isFalse,
      reason: 'the listener fired but the value it carries still reads good; '
          'the page would rebuild and redraw the same confident number');
}

/// A new reading ends the staleness.
///
/// The other half of the promise: a source that greys a value out and cannot
/// bring it back teaches operators that grey means nothing, and the next real
/// staleness is ignored.
Future<void> checkFreshValueClearsStaleness(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  // The staleness this case recovers from has to be real, so the seed must be
  // in before the wait for it begins.
  await arrived(api, _speedKey);
  final node = api.listen(_speedKey);
  final seen = observe(node);

  await within(seen.next, 'the value going stale before it can be refreshed',
      budget: _deadlineBudget(plant));
  expect(node.value.quality, Quality.badStale,
      reason: 'this case needs a stale value to recover from and the value '
          'never went stale');

  plant.setValue(_speedKey, 1600);
  await within(seen.next, 'the notification for the reading that ends the '
      'staleness');

  expect(node.value.quality.isGood, isTrue,
      reason: 'a fresh reading arrived and the value still reads as stale; '
          'the box stays grey while the plant runs, and an operator who sees '
          'that twice stops believing grey at all');
  expect(node.value.asInt, 1600,
      reason: 'the recovered value must carry the new reading, not the one it '
          'went stale holding');
}

/// Losing the upstream link degrades every key served over it.
///
/// Not one key, not the key that happened to be read next: all of them, at
/// once. A page with half its boxes greyed is worse than one with all of them
/// greyed, because it looks like a plant fault instead of a link fault and
/// sends someone to the wrong end of the building.
Future<void> checkUpstreamLossDegradesAffectedKeys(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValues({_speedKey: 1450, _otherKey: 3});
  // Both keys, because the case asserts on both. The next notification after
  // this point is the degradation; before it, the next notification is the
  // seed, and a case that read the seed would find two perfectly good values
  // and call the source a liar.
  await arrived(api, _speedKey);
  await arrived(api, _otherKey);
  final speed = api.listen(_speedKey);
  final other = api.listen(_otherKey);
  final seen = observe(speed);

  plant.disconnectUpstream();
  await within(seen.next, 'the affected keys degrading when the upstream link '
      'dropped');

  expect(speed.value.quality, Quality.badCommFault,
      reason: 'the upstream device link is down and the value still reads as '
          '${speed.value.quality.code}; every number on every mimic would be '
          'a number from before the link died, with nothing on screen saying '
          'so');
  expect(other.value.quality, Quality.badCommFault,
      reason: 'the link loss degraded one key and not another — a mimic with '
          'half its boxes greyed reads as a plant fault and sends someone to '
          'the wrong end of the building');
  expect(speed.value.asInt, 1450,
      reason: 'the last known reading must survive the link loss, so the '
          'operator can see what the plant was doing when contact was lost');
}

/// The mass degradation is announced once, not once per key.
///
/// Sparkplug sends one NDEATH for a whole node for exactly this reason. At 1500
/// keys a per-key fan-out is 1500 status events for one event, arriving in the
/// instant the client is already busy re-rendering every box on the page: a
/// denial of service against the operator's own screen, delivered by their own
/// gateway at the worst possible moment.
Future<void> checkUpstreamLossAnnouncesOnce(StateManApi api) async {
  final plant = harnessOf(api);

  final keys = _stationKeys(_massDegradeKeyCount);
  plant.setValues({
    for (var i = 0; i < keys.length; i++) keys[i]: 1000 + i,
  });
  // The `before` snapshot has to be taken after the seed has landed and the
  // notification waited for below has to be the degradation. Neither is true
  // on an asynchronous source without this: the case would read the counter
  // before the source had processed anything, wake on the seed, and compare
  // two numbers taken either side of nothing at all.
  await arrived(api, keys.first);
  final watched = observe(api.listen(keys.first));

  final before = plant.statusNotifications;
  plant.disconnectUpstream();
  await within(watched.next, 'the keys degrading when the upstream link '
      'dropped');
  final announcements = plant.statusNotifications - before;

  expect(announcements, 1,
      reason: 'losing one link cost $announcements status announcements for '
          '${keys.length} keys; the same shape at 1500 keys is 1500 events '
          'for one event, delivered in the instant the client is trying to '
          'redraw the page they are all about');
}

/// `PIPE.*` health keys are subscribed like any plant tag, and track the link.
///
/// There is no health method on the wire — its absence is a recorded decision,
/// not an omission (design §4.7, HLTH-01). So `listen('PIPE.connected')` is the
/// health API, and it must go through the same store, the same quality codes
/// and the same widgets as a temperature. If it does not, a client has no way
/// at all to ask whether the pipe is alive.
Future<void> checkHealthKeysAreSubscribableLikeAnyTag(StateManApi api) async {
  final plant = harnessOf(api);

  // Health rides the ordinary value path, which is the property — so it also
  // arrives the way an ordinary value arrives, and on a source across a
  // message boundary that is not instantly. A case that read the key before
  // its first value landed would report a healthy pipe as one that cannot say
  // whether it is alive.
  await arrived(api, _connectedKey);
  final connected = api.listen(_connectedKey);
  expect(connected.value.value, isNotNull,
      reason: '$_connectedKey read as unknown on a source that is up; health '
          'rides the ordinary value path and there is no separate API to fall '
          'back on, so a null here leaves the client unable to ask whether '
          'the pipe is alive');
  expect(connected.value.asBool, isTrue,
      reason: 'the source is up and its own health key says it is not');
  expect(api.keys, contains(_connectedKey),
      reason: 'the health key is missing from the key list; the diagnostics '
          'page and the page editor\'s picker find keys that way, so a health '
          'indicator nobody can discover is one nobody will put on a page');

  final seen = observe(connected);
  plant.disconnectUpstream();
  await within(seen.next, '$_connectedKey reporting the link loss');

  expect(connected.value.asBool, isFalse,
      reason: 'the upstream link dropped and $_connectedKey still says '
          'connected — the indicator an operator checks before trusting the '
          'rest of the screen would be the last thing on it to be wrong');
}

/// A health key is never accused of being stale by its own accounting.
///
/// HLTH-02. `PIPE.connected` changes only when the link changes, so on a
/// healthy pipe it is *always* older than the freshness deadline. A source that
/// applies the deadline to it greys out the one indicator that says whether to
/// trust everything else — and it does so precisely when everything is fine,
/// which is how an operator learns to ignore it.
Future<void> checkHealthKeysExcludedFromOwnFreshness(StateManApi api) async {
  final plant = harnessOf(api);

  // A plant key is the barrier: when *it* has gone stale, the deadline has
  // demonstrably passed, and the health key has been sitting untouched for at
  // least as long. No sleep, and no guess about how long the sweep takes.
  plant.setValue(_speedKey, 1450);
  // The barrier's own barrier: the plant key's seed has to be in before the
  // wait for its staling begins, and the health key's first value has to be in
  // before the case can say anything about its quality at all.
  await arrived(api, _speedKey);
  await arrived(api, _connectedKey);
  final speed = api.listen(_speedKey);
  final speedSeen = observe(speed);
  final connected = api.listen(_connectedKey);

  await within(
      speedSeen.next,
      'a plant key going stale, which is this case\'s proof that the '
      '${plant.staleAfter.inMilliseconds} ms deadline has passed',
      budget: _deadlineBudget(plant));
  expect(speed.value.quality, Quality.badStale,
      reason: 'the barrier this case rests on did not happen: the plant key '
          'never went stale, so nothing has been established about the health '
          'key yet');

  expect(connected.value.quality, isNot(Quality.badStale),
      reason: 'the pipe accused its own health key of being stale (HLTH-02). '
          '$_connectedKey changes only when the link changes, so on a healthy '
          'pipe it is always older than the deadline — staling it greys out '
          'the indicator an operator uses to decide whether the rest of the '
          'screen can be believed, and greys it out exactly when nothing is '
          'wrong');
  expect(connected.value.quality.isGood, isTrue,
      reason: 'the health key degraded while the pipe was up; whatever the '
          'code, a non-good health indicator on a healthy link is a false '
          'alarm the operator will learn to dismiss');
}

/// Time never upgrades a quality; only a new reading can.
///
/// Bad quality is sticky by design. A source that lets a value heal on a timer
/// shows a green number that nothing has confirmed — the same lie as a stale
/// value, arrived at from the other direction, and harder to catch because it
/// looks like recovery.
Future<void> checkQualityNeverImprovesOnItsOwn(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  plant.setQuality(_speedKey, Quality.uncertainLastKnown);
  await arrived(api, _speedKey);
  final node = api.listen(_speedKey);

  // The barrier is a second key crossing the same deadline: once it has gone
  // stale, enough time has passed that a source which heals on a timer would
  // have healed.
  plant.setValue(_otherKey, 3);
  // And the barrier only establishes that if the wait below is a wait for the
  // *staling* rather than for the seed. Without this the case passes on an
  // asynchronous source having established nothing — the worst outcome of the
  // three, because a vacuous pass is indistinguishable in CI from a real one.
  await arrived(api, _otherKey);
  final barrier = observe(api.listen(_otherKey));
  await within(
      barrier.next,
      'a second key going stale, which is this case\'s proof that the '
      '${plant.staleAfter.inMilliseconds} ms deadline has passed',
      budget: _deadlineBudget(plant));

  expect(node.value.quality.band,
      greaterThanOrEqualTo(Quality.uncertainLastKnown.band),
      reason: 'time alone improved a value from uncertain to '
          '${node.value.quality.code}; quality improves only when a new '
          'reading arrives, and a source that heals on a timer puts a '
          'confident number on screen that nothing upstream has confirmed');
  expect(node.value.quality.isGood, isFalse,
      reason: 'a value that was explicitly marked untrustworthy read as good '
          'again without any new reading');
}

/// Every freshness property, keyed by the sentence it asserts.
///
/// The key is the test name, so a failure in CI reads as the promise that was
/// broken rather than as a function identifier.
const freshnessChecks = <String, Check<StateManApi>>{
  'a value past the freshness deadline reports as stale, through every read '
      'path': checkValuePastDeadlineBecomesBadStale,
  'going stale is itself a change listeners hear about':
      checkStaleTransitionNotifiesListeners,
  'a fresh reading clears the staleness': checkFreshValueClearsStaleness,
  'losing the upstream link degrades every key served over it':
      checkUpstreamLossDegradesAffectedKeys,
  'losing the upstream link is announced once, not once per key':
      checkUpstreamLossAnnouncesOnce,
  'health keys are subscribable like any plant tag':
      checkHealthKeysAreSubscribableLikeAnyTag,
  'a health key is never accused of being stale by its own accounting':
      checkHealthKeysExcludedFromOwnFreshness,
  'quality never improves on its own': checkQualityNeverImprovesOnItsOwn,
};

/// Registers the freshness contract against implementations from [make].
///
/// One fresh instance per case, disposed by `addTearDown`: these cases run the
/// implementation's real watchdog on the wall clock, and a source left running
/// from a previous case would keep sweeping — and keep notifying — under the
/// next one's counts.
void runFreshnessContract(StateManApi Function() make) {
  group('freshness', () {
    freshnessChecks.forEach((property, check) {
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
