/// One registry, three transports, one pass set.
///
/// `harness_parity_test.dart` in the contract package made this claim about two
/// legs — an in-memory channel and a real TCP socket. This file is the same
/// claim with the WebSocket added, and it lives here rather than there because
/// the WS harness belongs to the server package and the contract package must
/// never gain an edge back to the thing it judges (T-03-17).
///
/// **Why three green files are not this claim.** Each leg has its own contract
/// driver and all three are green. That proves each transport passes the cases
/// somebody pointed at it — not that they pass the same cases. A sub-suite
/// added to one driver and forgotten in another, a factory whose defaults
/// drifted, a case that only ever ran in process: each of those leaves every
/// driver green and this file red.
///
/// **What is compared, and what must never be.** Pass sets — names and
/// outcomes, nothing else. Two measurements make text comparison across these
/// legs actively wrong, not merely fragile:
///
///  * The TCP leg turns an unpaired surrogate into U+FFFD on its way through
///    the framer (`line_channel.dart:31-38`).
///  * The WS leg does not deliver such a frame at all — a UTF-8-invalid payload
///    is dropped and the socket closes 1007 (RESEARCH Finding 12).
///
/// So the same message put in one end comes out as replacement characters on
/// one leg and as nothing at all on another. An assertion comparing that text
/// across legs is asserting each transport's UTF-8 error handling and calling
/// it parity. Timing is out for the reason the two-leg file already gives
/// (RESEARCH Risk 7): a controller delivers on a microtask, a socket goes
/// through the kernel, and the difference is a property of the host's load.
/// `within()` is the mechanism that makes one assertion work on every leg — a
/// case states what must happen and by when, so a leg too slow for a budget is
/// a failed check and the pass sets differ. Which is the signal, reported by
/// name.
///
/// **A fourth leg is one more row.** [_legs] is a table and everything below
/// iterates it. Phase 6's TLS leg should add a row and change nothing else.
///
/// **This sweep is proven to bite.** A parity sweep that cannot notice a broken
/// leg is decoration, and one whose discovery mechanism silently matches
/// nothing passes vacuously — `mode_integrity_test.dart:24-30`'s doctrine. So
/// the last group asserts the swept set is non-empty and as large as the
/// registry, asserts that a sweep with nothing in it reports zero rather than
/// agreement, and runs a deliberately broken implementation from the kit's own
/// sabotage fakes to prove a disagreement is reported by property name.
@TestOn('vm')
@Tags(['meta', 'ws'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/broken_subscribe.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/ws_harness.dart';

/// What the whole sweep is allowed to cost.
///
/// Three full contract registries, two of them over real loopback sockets and
/// one of those through a proxy, makes this the slowest test in the package —
/// and it still costs 4.9 s on the machine this was written on (44 checks x 3
/// legs, printed by the budget case on every run so the number stays visible).
///
/// So the ceiling is 60 s rather than the 120 s the two-leg sweep in
/// `tfc_stateman_contract` declares. Roughly twelve times the measurement,
/// which is enough headroom for a loaded CI box that is also running the
/// analyzer, and still tight enough to notice a sweep that grew an order of
/// magnitude. A budget set far above what the thing costs is not a budget: it
/// is a number that can only be tripped by a hang, and the per-check
/// [_caseBudget] already catches those with a name attached.
const _budget = Duration(seconds: 60);

/// What one check is allowed to cost on one leg before it counts as failed.
///
/// Every case wraps its awaits in a 200 ms `within`, so a check still running
/// after this has escaped a deadline. Recorded as a failure on that leg rather
/// than left to hang, because a hang here would take the parity assertion with
/// it and report nothing.
const _caseBudget = Duration(seconds: 5);

/// The transports under comparison, in the order their names read best.
///
/// Each entry is a named factory with the same defaults — `staleAfter` of
/// 300 ms, no read-only keys, no write latency — which is the property 03-04
/// enforced by copying them verbatim into the WS harness and which this file
/// depends on. A defaults difference between two legs reads here as a
/// *transport* difference and sends the next engineer looking for a socket bug
/// that is really a 300 ms deadline against a 500 ms one.
final _legs = <_Leg>[
  _Leg('channel', channelServedFake),
  _Leg('socket', socketServedFake),
  _Leg('ws', wsServedFake),
];

/// The leg every disagreement is reported against.
///
/// Arbitrary but fixed: the in-memory channel is the leg with no transport
/// under it, so "passes in memory and fails over a socket" is the sentence that
/// points at the transport rather than at the contract.
_Leg get _reference => _legs.first;

/// The roster this sweep runs: everything but the access family, by NAME.
///
/// 17-05 merged the 27-check access family into the kit roster (51 -> 78).
/// The kit's own channel harness serves the four access families, but the
/// socket and WS harnesses do not yet — sweeping the access checks against
/// them would buy 27 five-second case budgets per transport leg and leak
/// dispose-time errors into the zone, read by the leak arm as defects on
/// whatever case runs next. So the swept roster is pinned MINUS the named
/// set — a set, never a count, which is what keeps a 28th unjudged check
/// red (the count-blind defect 13-11 caught) — and the arithmetic arm
/// reconciles `swept + accessChecks.length == allContractChecks.length`.
/// The channel leg's access surface is judged by the kit's own
/// `channel_full_contract_test.dart`, not here.
/// access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
final _sweptRoster = allContractChecks.keys
    .where((property) => !accessChecks.containsKey(property))
    .toList();

/// The property `DropsSubscriptions` is built to violate.
///
/// Named here rather than inlined so the falsification case asserts on the same
/// string the registry uses. `sabotage_subscribe_test.dart:23-27` pins the same
/// pairing from the other direction — that file proves the check bites the
/// variant, this one proves the *sweep* notices when a leg is the variant.
const _droppedSubscription =
    'a listener is notified of every change after it attaches';

/// The whole-registry sweep, filled in by the per-check cases below.
final _main = _Sweep(_legs);

void main() {
  final wall = Stopwatch()..start();

  group('the same registry, run through every leg', () {
    for (final property in _sweptRoster) {
      test(property, () => _main.runCheck(property, allContractChecks[property]!));
    }
  });

  group('the sweep itself', () {
    test('every registered check outside the named access gap was run '
        'through every leg, and the gap reconciles to the roster', () {
      expect(_main.swept, _sweptRoster.length,
          reason: 'the sweep ran ${_main.swept} of '
              '${_sweptRoster.length} registered checks. The parity claim '
              'is about the whole registry, so a check the sweep never reached '
              'is a property whose legs nobody compared — and it would read as '
              'parity rather than as a gap');
      expect(_main.swept + accessChecks.length, allContractChecks.length,
          reason: 'swept plus the named access gap must reconcile to the '
              'whole roster of ${allContractChecks.length}; if it does not, '
              'a check exists that is neither swept nor accounted for');
    });

    test('every declared leg was actually swept', () {
      expect(_main.legsRecorded, _legs.map((leg) => leg.name).toSet(),
          reason: 'a leg declared in the table and never recorded is a '
              'transport that silently left the comparison. A leg that is '
              'legitimately unavailable on this host must skip by name — with '
              'a reason on the run report — because a leg that simply vanishes '
              'shrinks the compared set and makes the remaining agreement look '
              'like a stronger claim than it is');
    });

    test('the sweep recorded a full pass set on every leg', () {
      for (final leg in _legs) {
        expect(_main.passesOn(leg.name), isNotEmpty,
            reason: 'the ${leg.name} leg passed nothing at all. Three empty '
                'sets are equal to each other, so a sweep that discovers no '
                'outcomes reports perfect parity — the exact vacuous pass this '
                'assertion exists to make impossible');
        expect(_main.passesOn(leg.name), _sweptRoster.toSet(),
            reason: 'the ${leg.name} leg passed '
                '${_main.passesOn(leg.name).length} of the '
                '${_sweptRoster.length} swept checks. Every leg is expected '
                'to pass the whole swept roster — each has a green contract '
                'driver of its own — so a shortfall here is either a real '
                'regression on that transport or a check that escaped its '
                'deadline under the load of a three-leg sweep. Both are worth '
                'reading; neither is worth lowering this number for');
      }
    });

    test('every leg passes the same set of properties', () {
      for (final leg in _legs.skip(1)) {
        expect(_main.passesOn(leg.name), _main.passesOn(_reference.name),
            reason: _main.disagreementReport(_reference.name, leg.name));
      }
    });

    test('no check leaked an error into the zone on any leg', () {
      expect(_main.leaked, isEmpty,
          reason: 'these errors escaped after the case that caused them had '
              'finished, so they fail an unrelated test later in the run:\n'
              '${_main.leaked.join('\n')}');
    });

    test('the parity sweep costs less than its declared budget', () {
      print('the three-leg parity sweep ran in '
          '${wall.elapsed.inMilliseconds} ms '
          '(${_sweptRoster.length} checks x ${_legs.length} legs, budget '
          '${_budget.inSeconds} s; the ${accessChecks.length} access checks '
          'are the named unswept gap — 17-06/17-08 opt the legs in)');
      expect(wall.elapsed, lessThan(_budget),
          reason: 'running one registry through ${_legs.length} legs took '
              '${wall.elapsed.inSeconds} s, which is the cost this budget '
              'exists to keep off every CI run');
    });
  });

  group('the sweep cannot pass vacuously', () {
    test('a sweep with no legs reports zero rather than agreement', () async {
      final empty = _Sweep(const []);
      await empty.runAll(allContractChecks);

      expect(empty.outcomes, 0,
          reason: 'a sweep over an empty leg table recorded ${empty.outcomes} '
              'outcomes, which means it found legs somewhere other than the '
              'table it was handed');
      expect(empty.agree, isFalse,
          reason: 'a sweep that compared nothing reported agreement. Set '
              'equality is trivially true across zero legs, so without this '
              'guard a table that failed to populate — a factory list built '
              'from a filter that matched nothing, say — would be the greenest '
              'result this file can produce');
    });

    test('a sweep with no checks reports zero rather than agreement', () async {
      final empty = _Sweep(_legs);
      await empty.runAll(const <String, Check<StateManApi>>{});

      expect(empty.outcomes, 0,
          reason: 'a sweep over an empty registry recorded ${empty.outcomes} '
              'outcomes');
      expect(empty.agree, isFalse,
          reason: 'three legs that each passed nothing are three equal empty '
              'sets. That is the other half of the same vacuity: the legs are '
              'real, the registry is not, and the comparison is still about '
              'nothing');
    });

    test('a deliberately broken leg is reported as a named difference',
        () async {
      // `DropsSubscriptions` delivers the first value for a key and then goes
      // silent — an upstream subscription that died while the link stayed up.
      // Run in process rather than over a transport on purpose: this arm is
      // about the sweep noticing a leg whose *behaviour* differs, and putting a
      // socket under it would only add a way for the arm to fail for an
      // unrelated reason.
      final sabotaged = _Sweep([
        _reference,
        const _Leg('broken (drops subscriptions)', DropsSubscriptions.new),
      ]);
      await sabotaged.runAll(subscribeChecks);

      final differences = sabotaged.disagreements(
          _reference.name, 'broken (drops subscriptions)');

      expect(differences, contains(_droppedSubscription),
          reason: 'the sweep compared a correct leg against one that stops '
              'delivering changes and did not report `$_droppedSubscription` '
              'as a difference. It reported $differences. A parity sweep that '
              'cannot notice a broken leg is decoration: it would have said '
              'the same thing about these two legs as it says about three '
              'correct ones');
      expect(sabotaged.passesOn(_reference.name),
          contains(_droppedSubscription),
          reason: 'the difference must come from the broken leg failing, not '
              'from the reference leg failing too — otherwise this arm would '
              'pass just as well against a sweep that reports every check as a '
              'difference');
    });
  });
}

/// One transport under comparison: a name for the report, a factory to build.
final class _Leg {
  const _Leg(this.name, this.make);

  /// How this leg is named in every message, so two legs are never confused.
  final String name;

  /// Builds one fresh source on this transport. Same defaults on every leg.
  final StateManApi Function() make;
}

/// Runs a check registry through a leg table and records who passed what.
final class _Sweep {
  _Sweep(this.legs);

  final List<_Leg> legs;

  /// Properties that passed, per leg name.
  final _passed = <String, Set<String>>{};

  /// Why a property failed, keyed `leg/property`.
  final _why = <String, String>{};

  /// Errors that escaped a check after its case had finished.
  ///
  /// Collected across the whole sweep and read once at the end, for the reason
  /// `suite_integrity_test.dart` gives: a check that starts two deadlines can
  /// leak the loser's failure long after the winner was recorded, and a
  /// per-case assertion would swallow exactly the errors worth catching.
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
    return legs.every((leg) => _setsEqual(passesOn(leg.name), reference));
  }

  /// Properties that passed on exactly one of [a] and [b].
  Set<String> disagreements(String a, String b) =>
      passesOn(a).difference(passesOn(b))
        ..addAll(passesOn(b).difference(passesOn(a)));

  /// Runs every leg against one property and counts it swept.
  Future<void> runCheck(String property, Check<StateManApi> check) async {
    for (final leg in legs) {
      await _record(leg, property, check);
    }
    swept++;
  }

  /// Runs [checks] through every leg.
  Future<void> runAll(Map<String, Check<StateManApi>> checks) async {
    for (final entry in checks.entries) {
      await runCheck(entry.key, entry.value);
    }
  }

  /// Runs [check] against a fresh instance from [leg] and records the outcome.
  ///
  /// Records rather than asserts: a check failing on *every* leg is not a
  /// parity violation, and failing here would report it as one. What a
  /// unanimous failure means — a real contract bug, or a case needing a
  /// capability no factory declares — is the business of the per-leg contract
  /// drivers, which run the same checks and do assert.
  ///
  /// The guarded zone is not decoration. Whatever the check throws on the
  /// future awaited below is caught here; anything it throws on a *second*
  /// future goes to the ambient handler, which in a test isolate fails an
  /// unrelated case later on. Catching it here attributes it to the leg and the
  /// property that produced it.
  Future<void> _record(
    _Leg leg,
    String property,
    Check<StateManApi> check,
  ) async {
    final api = leg.make();
    final settled = Completer<bool>();

    runZonedGuarded(
      () async {
        try {
          await check(api);
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
    // is still a leg that was swept: `legsRecorded` answers "did this transport
    // take part", not "did it do well".
    final passes = _passed.putIfAbsent(leg.name, () => <String>{});
    if (passed) passes.add(property);
    outcomes++;

    await api.dispose();
  }

  /// The message the parity assertion carries when two legs disagree.
  ///
  /// Every differing property is named on its own line with the failing leg's
  /// own message, because that message already names the property in operator
  /// terms — `within()` saw to that — and repeating it here is what turns a set
  /// comparison back into a diagnosis. "3 checks differ" sends the next
  /// engineer to read the whole registry; naming one sends them to one place.
  String disagreementReport(String reference, String other) {
    final referenceOnly = passesOn(reference).difference(passesOn(other));
    final otherOnly = passesOn(other).difference(passesOn(reference));

    if (referenceOnly.isEmpty && otherOnly.isEmpty) {
      return 'the pass sets differ in size but not in membership, which should '
          'be impossible — read the two sets directly';
    }

    final lines = <String>[
      'the $reference and $other legs do not agree on which properties hold. '
          'Every line below is one property that passed on one leg and failed '
          'on the other, which means either the harnesses are not judging the '
          'same thing or the transport itself broke the property:',
    ];
    for (final property in referenceOnly) {
      lines.add('  * `$property` passes over $reference and FAILS over '
          '$other: ${_why['$other/$property'] ?? 'no message recorded'}');
    }
    for (final property in otherOnly) {
      lines.add('  * `$property` passes over $other and FAILS over '
          '$reference: ${_why['$reference/$property'] ?? 'no message recorded'}');
    }
    return lines.join('\n');
  }
}

/// Set equality without pulling `collection` in for one call.
bool _setsEqual(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
