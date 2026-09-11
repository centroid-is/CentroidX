/// One registry, two harnesses, one pass set — roadmap criterion 3's assertion.
///
/// Every other file in this package judges an implementation. This one judges
/// the *harnesses*: it runs the identical `allContractChecks` registry through
/// the channel-served factory and the socket-served factory and asserts that
/// the set of properties which passed is the same set on both sides.
///
/// **Why the claim needs its own file.** "The same protocol assertions pass in
/// both harnesses" is easy to believe and easy to be wrong about. Each
/// individual harness has its own contract file, and both are green — but two
/// green files prove that each transport passes the cases somebody pointed at
/// it, not that they pass the same cases. A sub-suite added to one file and
/// forgotten in the other, a factory whose defaults drifted, a case that only
/// ever ran in-process: each of those leaves both files green and this one red.
///
/// **What is compared, and what must never be.** Pass sets. Nothing else.
/// A `StreamChannelController` delivers on a microtask and a socket delivers
/// through the kernel, so the socket leg is slower by a margin that depends on
/// the host's load — comparing how long either side took, or how many events
/// each produced after a fixed wait, would produce a red build that says
/// nothing about either harness's correctness and everything about the machine
/// it ran on (RESEARCH Risk 7). The mechanism that makes a single assertion
/// work on both legs already exists: `within()` names the property and gives
/// it a budget, so a case states *what* must happen and by *when* rather than
/// *how fast*. Do not add a comparison of the two legs' timings here. If one
/// leg is too slow to satisfy a case's budget, that is a failed check and the
/// pass sets will differ — which is the signal, reported by name.
///
/// **The failure message is the deliverable.** "3 checks differ" sends the
/// next engineer to read the whole registry. "`a subscribed key delivers its
/// current value, good` passes over a channel and fails over a socket:
/// <message>" sends them to one place. The symmetric difference is listed by
/// property name, on both sides, with the failing side's own message.
///
/// Structure is `suite_integrity_test.dart`'s, deliberately: a wall-clock
/// budget on the sweep, one case per check, and a `runZonedGuarded` collector
/// so an error escaping after its case finished is attributed to the check
/// that produced it instead of failing whatever came next.
@TestOn('vm')
@Tags(['meta'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// What the whole sweep is allowed to cost.
///
/// Two full contract registries, one of them over real loopback sockets with a
/// proxy in the middle, makes this the slowest meta-test in the package. The
/// budget is what keeps that honest: a sweep that quietly grows past it is
/// paid for on every CI run by everybody.
const _budget = Duration(seconds: 120);

/// What one check is allowed to cost on one leg before it counts as failed.
///
/// Every case wraps its awaits in a 200 ms `within`, so a check still running
/// after this has escaped a deadline. Recorded as a failure on that leg rather
/// than left to hang, because a hang here would take the parity assertion with
/// it and report nothing.
const _caseBudget = Duration(seconds: 5);

/// The harness names, used in every message so the two legs are never confused.
const _channel = 'channel';
const _socket = 'socket';

/// Properties that passed on each leg.
final _passed = <String, Set<String>>{
  _channel: <String>{},
  _socket: <String>{},
};

/// Why a property failed, keyed `leg/property`.
final _why = <String, String>{};

/// Errors that escaped a check after its case had finished.
///
/// Collected across the whole sweep and read once at the end, for the reason
/// `suite_integrity_test.dart` gives: a check that starts two deadlines can
/// leak the loser's failure long after the winner has already been recorded,
/// and a per-case assertion would swallow exactly the errors worth catching.
final _leaked = <String>[];

/// How many checks the sweep actually ran, counted rather than assumed.
var _swept = 0;

void main() {
  final wall = Stopwatch()..start();

  group('the same registry, run through both harnesses', () {
    allContractChecks.forEach((property, check) {
      test(property, () async {
        await _record(_channel, property, check, channelServedFake);
        await _record(_socket, property, check, socketServedFake);
        _swept++;
      });
    });
  });

  group('the sweep itself', () {
    test('every registered check was run through both harnesses', () {
      expect(_swept, allContractChecks.length,
          reason: 'the sweep ran $_swept of ${allContractChecks.length} '
              'registered checks. The parity claim is about the whole '
              'registry, so a check the sweep never reached is a property '
              'whose two legs nobody compared — and it would read as parity '
              'rather than as a gap');
    });

    test('the two harnesses pass the same set of properties', () {
      final channelOnly = _passed[_channel]!.difference(_passed[_socket]!);
      final socketOnly = _passed[_socket]!.difference(_passed[_channel]!);

      expect(_passed[_socket], _passed[_channel], reason: _parityReason(channelOnly, socketOnly));
    });

    test('no check leaked an error into the zone on either leg', () {
      expect(_leaked, isEmpty,
          reason: 'these errors escaped after the case that caused them had '
              'finished, so they fail an unrelated test later in the run:\n'
              '${_leaked.join('\n')}');
    });

    test('the parity sweep costs less than its declared budget', () {
      print('the harness-parity sweep ran in ${wall.elapsed.inMilliseconds} ms '
          '(${allContractChecks.length} checks x 2 harnesses, budget '
          '${_budget.inSeconds} s)');
      expect(wall.elapsed, lessThan(_budget),
          reason: 'running one registry through two harnesses took '
              '${wall.elapsed.inSeconds} s, which is the cost this budget '
              'exists to keep off every CI run');
    });
  });
}

/// Runs [check] against a fresh instance from [make] and records the outcome.
///
/// Records rather than asserts: a check failing on *both* legs is not a parity
/// violation, and failing this case here would report it as one. What a
/// double failure means — a real contract bug, or a case that needs a
/// capability neither factory declares — is the business of the sub-suite
/// files, which run the same checks and do assert.
///
/// The guarded zone is not decoration. Whatever the check throws on the future
/// awaited below is caught here; anything it throws on a *second* future goes
/// to the ambient handler, which in a test isolate fails an unrelated case
/// later on. Catching it here attributes it to the leg and the property that
/// produced it.
Future<void> _record(
  String harness,
  String property,
  Check<StateManApi> check,
  StateManApi Function() make,
) async {
  final api = make();
  final settled = Completer<bool>();

  runZonedGuarded(
    () async {
      try {
        await check(api);
        if (!settled.isCompleted) settled.complete(true);
      } catch (error) {
        _why['$harness/$property'] = '$error';
        if (!settled.isCompleted) settled.complete(false);
      }
    },
    (error, stack) => _leaked.add('$harness/$property: '
        '${error.runtimeType} — $error'),
  );

  var passed = false;
  try {
    passed = await settled.future.timeout(_caseBudget);
  } on TimeoutException {
    _why['$harness/$property'] =
        'did not settle within ${_caseBudget.inSeconds} s — the check escaped '
        'its own deadline on this leg';
  }
  if (passed) _passed[harness]!.add(property);

  await api.dispose();
}

/// The message the parity assertion carries when the two legs disagree.
///
/// Every differing property is named on its own line with the failing leg's
/// own message, because that message already names the property in operator
/// terms — `within()` saw to that — and repeating it here is what turns a set
/// comparison back into a diagnosis.
String _parityReason(Set<String> channelOnly, Set<String> socketOnly) {
  if (channelOnly.isEmpty && socketOnly.isEmpty) {
    return 'the pass sets differ in size but not in membership, which should '
        'be impossible — read the two sets directly';
  }

  final lines = <String>[
    'the two harnesses do not agree on which properties hold. Every line '
        'below is one property that passed on one leg and failed on the '
        'other, which means either the harnesses are not judging the same '
        'thing or the transport itself broke the property:',
  ];
  for (final property in channelOnly) {
    lines.add('  * `$property` passes over a channel and FAILS over a socket: '
        '${_why['$_socket/$property'] ?? 'no message recorded'}');
  }
  for (final property in socketOnly) {
    lines.add('  * `$property` passes over a socket and FAILS over a channel: '
        '${_why['$_channel/$property'] ?? 'no message recorded'}');
  }
  return lines.join('\n');
}
