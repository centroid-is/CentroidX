/// One registry, two legs, and — as of 10-05 — **no difference at all**.
///
/// This file's headline used to be that the gateway leg differs from the
/// in-memory reference leg by exactly the named gap. The gap is now empty, so
/// the sentence it asserts has become the strongest single statement this
/// phase can make: **`channel.passes − ws.passes` is empty**, which is to say
/// the gateway leg passes exactly what the reference leg passes. Thirteen
/// checks were out of reach when Phase 10 opened, every one of them for a
/// missing handler; four plans landed those handlers, and each entry left
/// [unreachableChecks] in the commit that made it reachable.
///
/// `ws_contract_test.dart` proves the gateway leg is green. Green is not the
/// claim this file makes. A leg can be green while judging a *different set of
/// properties* than the reference does — a case dropped by a capability flag,
/// a case rebound to a weaker lever, a case that only ever ran in memory — and
/// every one of those leaves both drivers green and this file red.
///
/// **Why a count would not do**, and why an empty gap does not make a count
/// adequate after all. The obvious version of this test compares two numbers:
/// the reference passes 50, the gateway passes 50, done. That arithmetic holds
/// just as well if the gateway silently failed `a rejected write carries a
/// greppable reason` and silently passed one of the browse checks against a
/// handler that answers something plausible and wrong. Two legs agreeing on a
/// number while judging different checks is the whole failure this file exists
/// to catch, so what is compared is **set membership**:
/// `channel.passes − ws.passes` must equal [unreachableChecks] element for
/// element — an empty set today — and `ws.passes − channel.passes` must be
/// empty too. There is no `.length` anywhere in the parity assertion or in
/// the two arms either side of it. The five in the file are all elsewhere and
/// all accounted for: two in the coverage case (`swept` against
/// the registry), two in the budget case's printed line, and one in
/// `_Sweep.agree`, which is the anti-vacuity guard — the one place a count is
/// the right question, because "fewer than two legs" is exactly what makes a
/// comparison vacuous.
///
/// **The companion arm starts mattering now**, and it is worth saying because
/// it has been quietly true for nine phases. `the gateway leg passes nothing
/// the reference does not` was arithmetically hard to violate while the
/// gateway had thirteen missing handlers: a leg that answers -32601 cannot
/// pass a check the reference fails. With the table closed it becomes a real
/// question, and it gets realer in 10-07, when a database-backed
/// implementation replaces `FakeTimeseries` behind the gateway leg — a real
/// historian could pass a check the in-memory fake fails, and the honest
/// reading of that is not "the gateway is better" but "the two legs are being
/// judged on different things again".
///
/// **The legs are rebound, never reduced.** Both legs run the whole registry
/// with no capability flag anywhere — strictly stronger than
/// `ws_contract_test.dart`'s all-true flags, because there is no flag here to
/// switch off. Two cases take a lever per leg, exactly as `runWriteContract`
/// rebinds them: the read-only case needs a declared key on *both* legs or it
/// would judge different things on each, and the lost-link case needs the
/// gateway leg's deferred cut (`dropUpstreamUnderAWriteInFlight`) because over
/// a socket the default lever fires before the write has left. A rebinding
/// changes *how* a property is provoked on one transport; it never adds or
/// removes a case, which is the contract library's own doctrine
/// (`tfc_stateman_contract.dart:128-131`) and is what keeps the compared sets
/// the same size as the registry.
///
/// **This sweep is proven to bite**, three ways. A sweep with no legs and a
/// sweep with no checks each report zero outcomes rather than agreement — two
/// empty sets are equal, which is the greenest thing a comparison can say about
/// nothing. And a deliberately broken leg from the kit's own sabotage fakes is
/// reported as a difference *by property name*, so the mechanism is shown to
/// notice a leg that behaves differently rather than merely to run.
@TestOn('vm')
@Tags(['meta'])
library;

import 'dart:async';

import 'package:test/test.dart';
// `StateManApi` itself lives in the protocol package, not the contract one:
// the contract judges the interface, it does not own it.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/broken_subscribe.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../support/client_harness.dart';
import 'ws_contract_test.dart' show unreachableChecks;
import '../support/runner_budget.dart';

/// The designated read-only key, character-identical to the one
/// `ws_contract_test.dart:47` declares and to the server package's.
///
/// Declared on **both** legs. A key declared on one leg only would make the
/// read-only case assert "writes to this key are refused" on one side and
/// "writes to some fallback key are refused" on the other — a difference in
/// what is judged, wearing the clothes of a difference in transport.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

/// The case whose lever has to differ per leg, named rather than inlined.
///
/// `runWriteContract` rebinds this one by the same string
/// (`write_contract.dart:645-647`), so if the registry ever renames it, the
/// rebinding below stops matching and the sweep runs the default-lever version
/// on both legs — where the gateway leg fails it and this file reports the
/// failure as a parity violation. Loud, and pointed at the right line.
const _linkLostCase =
    'a write in flight when the link drops is unknown, never a failure';

/// The read-only case, named for the same reason.
const _readOnlyCase = 'a write to a read-only key is rejected, not thrown';

/// What the whole sweep is allowed to cost.
///
/// Two full registries, one of them building a real `RelayServer` on a real
/// loopback socket per case, measures ~11 s on the machine this was written on
/// (printed by the budget case every run, so the number stays visible). 90 s is
/// roughly eight times that — headroom for a loaded CI box, still tight enough
/// to notice a sweep that grew an order of magnitude.
const _budget = Duration(seconds: 90);

/// What one check is allowed to cost on one leg before it counts as failed.
///
/// Every case wraps its awaits in a 200 ms `within`, so a check still running
/// after five seconds has escaped a deadline. Recorded as a failure on that leg
/// rather than left to hang: a hang here would take the parity assertion down
/// with it and report nothing at all.
const _caseBudget = Duration(seconds: 5);

/// The reference leg: the same `FakeStateMan` the gateway serves, reached over
/// an in-memory channel with no socket under it.
///
/// Chosen as the reference for the reason the server package's three-leg sweep
/// gives: the leg with no transport under it makes "passes in memory, fails
/// over the gateway" the sentence that points at the gateway rather than at the
/// contract.
final _channel = _Leg('channel', channelServedFake);

/// The leg under judgement: `RemoteStateMan` over a real WebSocket in front of
/// a real `RelayServer`.
final _ws = _Leg(
  'ws',
  relayServedFake,
  dropLinkWithWritesInFlight: dropUpstreamUnderAWriteInFlight,
);

final _legs = <_Leg>[_channel, _ws];

/// The property `DropsSubscriptions` is built to violate.
///
/// Named here so the falsification arm asserts on the same string the registry
/// uses, rather than on a copy that could drift into matching nothing.
const _droppedSubscription =
    'a listener is notified of every change after it attaches';

final _main = _Sweep(_legs);

/// The roster this sweep runs: everything but the access family, by NAME.
///
/// 17-05 grew `allContractChecks` from 51 to 78 with the 27 access checks.
/// The gateway leg has no access surface yet, so sweeping them would buy 27
/// five-second case budgets against RemoteStateMan and 27 dispose-time
/// StateErrors leaked into the zone — read by the leak arm as defects on
/// whatever case runs next. The gap is pinned as a set rather than lowered
/// into a count, and the arithmetic arm below reconciles
/// `swept + accessChecks.length == allContractChecks.length`.
/// access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
final _sweptRoster = allContractChecks.keys
    .where((property) => !accessChecks.containsKey(property))
    .toList();

void main() {
  useRunnerBudgets();

  final wall = Stopwatch()..start();

  group('the same registry, run through both legs', () {
    for (final property in _sweptRoster) {
      test(property, () => _main.runCheck(property));
    }
  });

  group('the sweep itself', () {
    test('every registered check outside the named access gap was run '
        'through both legs, and the gap reconciles to the roster', () {
      expect(_main.swept, _sweptRoster.length,
          reason: 'the sweep ran ${_main.swept} of '
              '${_sweptRoster.length} registered checks. The parity claim '
              'is about the whole registry, so a check the sweep never reached '
              'is a property nobody compared across the two legs — and it '
              'would read here as parity rather than as a gap');
      expect(_main.swept + accessChecks.length, allContractChecks.length,
          reason: 'swept plus the named access gap must reconcile to the '
              'whole roster of ${allContractChecks.length}; if it does not, '
              'a check exists that is neither swept nor accounted for');
    });

    test('both declared legs were actually swept', () {
      expect(_main.legsRecorded, {_channel.name, _ws.name},
          reason: 'a leg declared in the table and never recorded is a leg '
              'that silently left the comparison. One leg compared against '
              'itself agrees perfectly and means nothing');
    });

    test('neither leg passed nothing at all', () {
      for (final leg in _legs) {
        expect(_main.passesOn(leg.name), isNotEmpty,
            reason: 'the ${leg.name} leg passed no checks whatsoever. Two '
                'empty sets are equal to each other, so a sweep that '
                'discovered no outcomes would report perfect parity — the '
                'exact vacuous pass this arm exists to make impossible. Read '
                'the per-leg failures before reading anything else in this '
                'file');
      }
    });

    test('the reference leg passes the whole swept roster', () {
      expect(_main.passesOn(_channel.name), _sweptRoster.toSet(),
          reason: 'the in-memory reference leg did not pass every check, so '
              'the difference measured below is not "what the gateway cannot '
              'do" — it is that minus whatever the reference also failed. A '
              'shortfall here is either a real contract regression or a case '
              'that escaped its deadline under the load of a two-leg sweep; '
              'both are worth reading and neither is worth subtracting');
    });

    test('what the gateway leg does not pass is exactly the named gap', () {
      // The access family is not in this difference because it is not swept
      // at all — see [_sweptRoster], where it is pinned and reconciled.
      expect(
          _main.passesOn(_channel.name).difference(_main.passesOn(_ws.name)),
          unreachableChecks.toSet(),
          reason: _main.disagreementReport(_channel.name, _ws.name));
    });

    test('the gateway leg passes nothing the reference does not', () {
      expect(_main.passesOn(_ws.name).difference(_main.passesOn(_channel.name)),
          isEmpty,
          reason: 'a property that holds over the gateway and fails in memory '
              'is not good news. Either the reference regressed, or the '
              'gateway leg is passing a case the reference judges more '
              'strictly — a harness answering for the plant rather than '
              'forwarding to it, say. ${_main.disagreementReport(
        _channel.name,
        _ws.name,
      )}');
    });

    test('no check leaked an error into the zone on either leg', () {
      expect(_main.leaked, isEmpty,
          reason: 'these errors escaped the check that caused them, so they '
              'would otherwise fail an unrelated case later in the run — '
              'which is how a defect on one leg gets reported against a '
              'property on the other:\n${_main.leaked.join('\n')}');
    });

    test('the parity sweep costs less than its declared budget', () {
      print('the two-leg parity sweep ran in ${wall.elapsed.inMilliseconds} ms '
          '(${_sweptRoster.length} checks x ${_legs.length} legs, budget '
          '${_budget.inSeconds} s; the ${accessChecks.length} access checks '
          'are the named unswept gap — 17-06/17-08 opt the gateway leg in)');
      expect(wall.elapsed, lessThan(_budget),
          reason: 'running one registry through ${_legs.length} legs took '
              '${wall.elapsed.inSeconds} s, which is the cost this budget '
              'exists to keep off every CI run');
    });
  });

  group('the sweep cannot pass vacuously', () {
    test('a sweep with no legs reports zero rather than agreement', () async {
      final empty = _Sweep(const []);
      await empty.runAll(allContractChecks.keys);

      expect(empty.outcomes, 0,
          reason: 'a sweep over an empty leg table recorded ${empty.outcomes} '
              'outcomes, which means it found legs somewhere other than the '
              'table it was handed');
      expect(empty.agree, isFalse,
          reason: 'a sweep that compared nothing reported agreement. Set '
              'equality is trivially true across zero legs, so without this '
              'guard a leg table that failed to populate would be the greenest '
              'result this file can produce');
    });

    test('a sweep with no checks reports zero rather than agreement', () async {
      final empty = _Sweep(_legs);
      await empty.runAll(const <String>[]);

      expect(empty.outcomes, 0,
          reason: 'a sweep over an empty registry recorded ${empty.outcomes} '
              'outcomes');
      expect(empty.agree, isFalse,
          reason: 'two legs that each passed nothing are two equal empty sets. '
              'That is the other half of the same vacuity: the legs are real, '
              'the registry is not, and the comparison is still about nothing');
    });

    test('a deliberately broken leg is reported as a named difference',
        () async {
      // In process on purpose: this arm is about the sweep noticing a leg whose
      // *behaviour* differs, and putting a socket under it would only add a way
      // for the arm to fail for an unrelated reason.
      const brokenLeg = 'broken (drops subscriptions)';
      final sabotaged = _Sweep([
        _channel,
        // Wrapped rather than passed as a tear-off: the sabotage fakes take no
        // `readOnlyKeys`, and this arm runs subscribe checks, which never
        // write. Declaring one here would be a parameter no leg reads.
        _Leg(brokenLeg, ({Set<String> readOnlyKeys = const {}}) =>
            DropsSubscriptions()),
      ]);
      await sabotaged.runAll(subscribeChecks.keys);

      expect(sabotaged.disagreements(_channel.name, brokenLeg),
          contains(_droppedSubscription),
          reason: 'the sweep compared a correct leg against one that stops '
              'delivering changes and did not report `$_droppedSubscription` '
              'as a difference. A parity sweep that cannot notice a broken leg '
              'is decoration: it would say the same thing about these two legs '
              'as it says about the two real ones');
      expect(sabotaged.passesOn(_channel.name), contains(_droppedSubscription),
          reason: 'the difference has to come from the broken leg failing, not '
              'from the reference failing too — otherwise this arm would pass '
              'against a sweep that called everything a difference');
    });
  });
}

/// One leg under comparison: a name for the report, a factory, and the levers
/// that have to be bound per transport.
final class _Leg {
  const _Leg(this.name, this.make, {this.dropLinkWithWritesInFlight});

  /// How this leg is named in every message, so two legs are never confused.
  final String name;

  /// Builds one fresh source on this leg.
  ///
  /// Narrowed to the one parameter this file passes. Both real factories take
  /// the same seven — `staleAfter`, `writeLatency` and the four fixtures —
  /// with identical defaults, which is the property 04-09 preserved by copying
  /// `channelServedFake`'s signature verbatim and which this comparison rests
  /// on: a defaults difference between two legs reads here as a *transport*
  /// difference and sends the next engineer hunting a socket bug that is
  /// really a 300 ms deadline against a 500 ms one. Naming only `readOnlyKeys`
  /// keeps that shared shape unrestated rather than duplicated into a third
  /// place that could drift.
  final StateManApi Function({Set<String> readOnlyKeys}) make;

  /// How this leg cuts the upstream while a write is in flight, when the
  /// default (`disconnectUpstream` on the harness) cannot reach the state the
  /// case is named for. Null means the default, which is right in memory.
  final void Function(StateManApi api)? dropLinkWithWritesInFlight;

  /// This leg's binding of [property] — the registry's check, with the two
  /// lever-taking cases rebound the way `runWriteContract` rebinds them.
  ///
  /// Every other case is the registry's own closure, untouched. That is the
  /// property that makes the comparison meaningful: the two legs differ in
  /// transport and in lever, never in what is asserted.
  Check<StateManApi> checkFor(String property) {
    if (property == _readOnlyCase) {
      return (api) =>
          checkReadOnlyKeyIsRejectedNotThrown(api, readOnlyKey: _readOnlyKey);
    }
    if (property == _linkLostCase && dropLinkWithWritesInFlight != null) {
      return (api) => checkLostLinkYieldsUnknownNeverFailure(api,
          dropLinkWithWritesInFlight: dropLinkWithWritesInFlight);
    }
    return allContractChecks[property]!;
  }

  /// One fresh source on this leg, with the read-only key declared.
  StateManApi build() => make(readOnlyKeys: const {_readOnlyKey});
}

/// Runs a registry through a leg table and records who passed what.
final class _Sweep {
  _Sweep(this.legs);

  final List<_Leg> legs;

  /// Properties that passed, per leg name.
  final _passed = <String, Set<String>>{};

  /// Why a property failed, keyed `leg/property`.
  final _why = <String, String>{};

  /// Errors that escaped a check after its case had finished.
  ///
  /// Collected across the whole sweep and read once at the end: a check that
  /// starts two deadlines can leak the loser's failure long after the winner
  /// was recorded, and a per-case assertion would swallow exactly the errors
  /// worth catching.
  final leaked = <String>[];

  /// How many checks the sweep reached, counted rather than assumed.
  var swept = 0;

  /// How many leg-and-property outcomes were recorded, pass or fail.
  ///
  /// The anti-vacuity number: a sweep that discovered nothing to run has zero
  /// here while its pass sets are still trivially equal.
  var outcomes = 0;

  /// The legs that actually produced an outcome, by name.
  Set<String> get legsRecorded => _passed.keys.toSet();

  /// Properties that passed on [leg].
  Set<String> passesOn(String leg) => _passed[leg] ?? const <String>{};

  /// Whether every leg agrees — and whether there was anything to agree about.
  ///
  /// The second clause is the point. Set equality across zero legs, or across
  /// legs that each passed nothing, is true and means nothing.
  bool get agree {
    if (legs.length < 2 || outcomes == 0) return false;
    final reference = passesOn(legs.first.name);
    if (reference.isEmpty) return false;
    return legs.every(
        (leg) => _setsEqual(passesOn(leg.name), reference));
  }

  /// Properties that passed on exactly one of [a] and [b].
  Set<String> disagreements(String a, String b) =>
      passesOn(a).difference(passesOn(b))
        ..addAll(passesOn(b).difference(passesOn(a)));

  /// Runs every leg against one property and counts it swept.
  Future<void> runCheck(String property) async {
    for (final leg in legs) {
      await _record(leg, property);
    }
    swept++;
  }

  /// Runs [properties] through every leg.
  Future<void> runAll(Iterable<String> properties) async {
    for (final property in properties) {
      await runCheck(property);
    }
  }

  /// Runs [property] against a fresh instance from [leg] and records it.
  ///
  /// Records rather than asserts: a check failing on *both* legs is not a
  /// parity violation, and failing here would report it as one. What a
  /// unanimous failure means is the business of the per-leg contract drivers,
  /// which run the same checks and do assert — and of the reference-leg arm
  /// above, which is where a unanimous failure surfaces by name.
  Future<void> _record(_Leg leg, String property) async {
    final check = leg.checkFor(property);
    final settled = Completer<bool>();
    StateManApi? api;

    // The source is **built inside** the guarded zone, not before it.
    //
    // Not a style choice. Standing up the gateway leg starts work that outlives
    // the constructor — a socket dial, a `hello`, the page subscribe — and the
    // futures behind it belong to whichever zone created them. Built outside,
    // an error from any of those is delivered to the enclosing *test* zone,
    // where it fails whichever case happens to be running with no leg and no
    // property attached to it. That is how the very first version of this file
    // reported `a disposed source notifies nobody` as broken over the gateway
    // while the driver next door ran the same check green: the case was fine,
    // the attribution was not.
    runZonedGuarded(
      () async {
        try {
          api = leg.build();
          await check(api!);
          if (!settled.isCompleted) settled.complete(true);
        } catch (error) {
          _why['${leg.name}/$property'] = '$error';
          if (!settled.isCompleted) settled.complete(false);
        }
      },
      (error, stack) =>
          leaked.add('${leg.name}/$property: ${error.runtimeType} — $error'),
    );

    var passed = false;
    try {
      passed = await settled.future.timeout(_caseBudget);
    } on TimeoutException {
      _why['${leg.name}/$property'] =
          'did not settle within ${_caseBudget.inSeconds} s — the check '
          'escaped its own deadline on this leg';
    }

    // Registered before the outcome is filed, so a leg whose every check fails
    // is still a leg that was swept: `legsRecorded` answers "did this leg take
    // part", not "did it do well".
    final passes = _passed.putIfAbsent(leg.name, () => <String>{});
    if (passed) passes.add(property);
    outcomes++;

    // The sweep's own cleanup, and it is never allowed to decide an outcome.
    //
    // `a disposed source notifies nobody` disposes the source as the whole
    // point of the case, so this is the second dispose. In memory that is a
    // no-op; over the gateway the client answers "the readiness barrier was
    // disposed while a call was waiting for the link", because a shutdown is
    // already under way and `dispose` has an unsubscribe to send. Letting that
    // escape failed the case on the ws leg and on that leg only — a cleanup
    // detail reported as a transport difference, which is precisely the wrong
    // answer from a file whose job is to tell those two apart.
    //
    // Swallowed rather than recorded because whether `dispose` behaves is a
    // property the registry already judges, on both legs, by name. The outcome
    // above was filed before this line runs, so a real dispose defect still
    // shows up where it belongs.
    try {
      await api?.dispose();
    } catch (_) {
      // Already disposed by the case, or shutting down. Not this file's claim.
    }
  }

  /// The message the parity assertion carries when the two legs disagree.
  ///
  /// Every differing property is named on its own line with the failing leg's
  /// own message, because that message already names the property in operator
  /// terms and repeating it here is what turns a set comparison back into a
  /// diagnosis. "3 checks differ" sends the next engineer to read the whole
  /// registry; naming one sends them to one place.
  String disagreementReport(String reference, String other) {
    final referenceOnly = passesOn(reference).difference(passesOn(other));
    final otherOnly = passesOn(other).difference(passesOn(reference));

    final lines = <String>[
      'the $reference and $other legs must differ by exactly the checks named '
          'in `unreachableChecks`, and they do not. Every line below is a '
          'property that passed on one leg and failed on the other. A line '
          'that is not in the gap list is either a real defect over the '
          'gateway or a harness judging something different; a gap-list entry '
          'missing from these lines is a handler that has landed, and the '
          'entry must be deleted so the check is judged on its merits:',
    ];
    for (final property in referenceOnly) {
      lines.add('  * `$property` passes over $reference and FAILS over '
          '$other: ${_why['$other/$property'] ?? 'no message recorded'}');
    }
    for (final property in otherOnly) {
      lines.add('  * `$property` passes over $other and FAILS over '
          '$reference: '
          '${_why['$reference/$property'] ?? 'no message recorded'}');
    }
    return lines.join('\n');
  }
}

bool _setsEqual(Set<String> a, Set<String> b) =>
    a.containsAll(b) && b.containsAll(a);
