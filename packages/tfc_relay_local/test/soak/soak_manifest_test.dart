/// The soak's own audit: the deviations print, the counts are written down
/// twice, and no checker name appears that nobody declared.
///
/// The analogue of `gate_manifest_test.dart` one level up, with the row table
/// deliberately absent (11-RESEARCH §F.1). What this file audits is the two
/// things the soak's registry actually holds — the six checker names and the
/// declared departures from §7.8 — plus, from 11-01 task 2, the vacuity gate
/// that makes a checker's green mean something.
///
/// **The counts live here, not in the registry.** [_declaredDeviations] and
/// [_declaredCheckerNames] are written down in this file on purpose, which is
/// `gate_manifest_test.dart:44-50`'s argument: a sweep that derives both sides
/// of its comparison from the same source asserts nothing. An entry deleted
/// from `soakDeviations` takes its own `.length` with it and every in-file
/// count still agrees with itself; these two numbers are the only place the
/// deletion shows.
///
/// **The print is the point.** Later phases and the milestone audit read the
/// deviations block out of a run report rather than out of the source, so it
/// goes to stdout on every run whether or not anything below fails — the same
/// reason `gate_manifest_test.dart:597-601` gives.
///
/// **Why the clause cannot be machine-checked against the catalogue.** Gate A
/// asserts that each deviation's clause is a substring of its row's
/// `verbatimText`, which works because the catalogue text is embedded in
/// `f_row_registry.dart`. §7.8 lives in `relay-websocket-notes.md`, which is
/// **not in the repository** — it is a working document on the author's
/// machine. So the [SoakDeviation.clause] field *is* the embedded copy, and
/// the floor this file can enforce is that it exists and is not a paraphrase
/// of nothing. Quoting it verbatim is a discipline the reviewer checks, not
/// one a sweep can.
@TestOn('vm')
@Tags(['soak'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/soak/invariant.dart';
import 'soak_registry.dart';

/// How many departures from §7.8 this plan seeded, and how many names the
/// checker list is claimed to hold.
///
/// Both are equalities rather than floors, which is where this file differs
/// from gate A's `_declaredDeviations >= 9`. Gate A expected its registry to
/// keep growing through a thirteen-plan phase and wanted only the *shrinking*
/// case caught. Here the growth is enumerated in advance — 11-PLAN-INDEX
/// expects five, six if 11-04's short-arm distribution needs gating, seven if
/// 11-05 deviates the server-side log clause — so an appending plan changes
/// this number in the same commit as its entry, and an entry that arrives
/// without one is a departure nobody declared in the index.
const int _declaredDeviations = 6;

/// Six: the five invariants of §7.8 plus the divergence ledger.
///
/// A seventh would be a finding rather than a breach (11-RESEARCH assumption
/// A10): §7.8 names five properties, and something the soak needs to check
/// that is not one of them is worth a conversation before it is worth a
/// checker.
const int _declaredCheckerNames = 6;

/// The shortest reasoning that can carry an argument, in characters.
///
/// Sixty, which is gate A's convention applied to a different field: an entry
/// too short to argue is an entry nobody argued. The failure mode this catches
/// is not a lazy author, it is a later edit that trims a reasoning down to a
/// label while leaving the entry in place — at which point the registry still
/// has five rows and none of them says anything.
const int _reasoningFloor = 60;

void main() {
  group('RES-03\'s ledger', () {
    test('is printed, in full, on every run', () {
      // Same argument as the deviations block below: the print IS the
      // deliverable. The milestone audit reads this beside gate A's and gate
      // B's registries, and a ledger only ever read by an assertion is a
      // ledger nobody reads.
      print('');
      print('RES-03 evidence ledger (${res03Ledger.length} rows)');
      print('');
      for (final row in res03Ledger) {
        print(row.criterion);
        print('   command : ${row.command}');
        print('   result  : ${row.result}');
        print('   SILENT ABOUT: ${row.caveat}');
        print('');
      }
      expect(res03Ledger, isNotEmpty);
    });

    test('every row carries a command, a result and a caveat', () {
      // **The caveat is the load-bearing field.** This phase produced four
      // separate cases where a green run meant less than it appeared —
      // 11-04 sabotage 2, 11-05 sabotage 4, and both halves of 11-06's
      // epochChange finding — each caught by a structural pin and by nothing
      // in the soak. A ledger row with an empty caveat is a row claiming its
      // evidence has no edge, and none of them does.
      for (final row in res03Ledger) {
        expect(row.command, isNotEmpty, reason: row.criterion);
        expect(row.result, isNotEmpty, reason: row.criterion);
        expect(row.caveat.length, greaterThan(40),
            reason: 'the caveat on "${row.criterion}" is '
                '${row.caveat.length} characters, which is not a statement of '
                'what the row is silent about. A ledger that reads as '
                'unqualified green is a failing ledger');
      }
    });

    test('covers all four of the ROADMAP\'s criteria', () {
      final numbered = res03Ledger.map((row) => row.criterion.trim()).toList();
      for (final prefix in <String>['1.', '2.', '3.', '4.']) {
        expect(numbered.any((c) => c.startsWith(prefix)), isTrue,
            reason: 'no ledger row answers ROADMAP criterion $prefix — and a '
                'requirement closed with a criterion unanswered is closed on '
                'somebody\'s memory of it. Rows present: $numbered');
      }
    });
  });

  group('the deviations registry', () {
    test('is printed, in full, on every run', () {
      // The print is the deliverable. 11-01's SUMMARY pastes this block
      // verbatim and the milestone audit reads it beside gate A's and gate
      // B's; a registry only ever read by an assertion is a registry nobody
      // reads.
      print('');
      print('soak deviations from relay-websocket-notes.md §7.8 '
          '(${soakDeviations.length} entries)');
      print('');
      for (var i = 0; i < soakDeviations.length; i++) {
        final deviation = soakDeviations[i];
        print('${i + 1}. ${deviation.id}');
        print('   §7.8 says : "${deviation.clause}"');
        print('   instead   : ${deviation.instead}');
        print('   because   : ${deviation.reasoning}');
        print('');
      }

      expect(soakDeviations, isNotEmpty,
          reason: 'the deviations registry is empty, so this run reports that '
              'the soak does exactly what §7.8 says. That has not been true '
              'since the phase was planned: the lane default is 90 s and not '
              '30+ min, and invariant 4 is structural and not a heap '
              'high-water mark');
    });

    test('holds exactly the number of entries this phase declared', () {
      final ids = soakDeviations.map((d) => d.id).toList();
      expect(soakDeviations, hasLength(_declaredDeviations),
          reason: 'soakDeviations holds ${soakDeviations.length} entries and '
              'this phase declares $_declaredDeviations. The entries present '
              'are $ids. A plan that appends a deviation raises this number in '
              'the same commit; a deviation that disappears is a promise the '
              'soak quietly widened, and this count is the only place either '
              'shows — every other arm in this file derives both of its sides '
              'from the list itself');
    });

    test('still holds all five day-one departures, by id', () {
      // Written out rather than derived, and it is the arm that makes a
      // deletion *legible*. The count above catches that something went
      // missing; a bare count cannot say what, because the list it would name
      // it from is the list that lost it. These five ids are the second copy.
      expect(
          soakDeviations.map((d) => d.id),
          containsAll(<String>[
            'the 90-second default',
            'invariant 4 is asserted structurally; RSS is journalled and never '
                'asserted',
            'invariant 2 reconciles continuously against a test-only '
                'plant-side ledger',
            'the full arm is judged on Ubuntu only',
            'no docker-compose integration tier',
          ]),
          reason: 'one of the five departures 11-01 seeded is no longer in '
              'soakDeviations — the ids present are '
              '${soakDeviations.map((d) => d.id).toList()}. Every one of the '
              'five is a thing the soak does differently from §7.8, so an '
              'entry that disappears does not make the soak match the '
              'catalogue, it makes the mismatch undocumented');
    });

    test('every entry quotes a clause and argues for its replacement', () {
      final emptyClause = [
        for (final deviation in soakDeviations)
          if (deviation.clause.trim().isEmpty) deviation.id,
      ];
      expect(emptyClause, isEmpty,
          reason: 'these deviations name no §7.8 clause: $emptyClause. An '
              'entry without the catalogue text it departs from cannot be '
              'checked against the catalogue by anybody, which is the only '
              'thing an entry is for — and §7.8 is not in this repository, so '
              'the quoted copy is the only copy a reader has');

      final emptyInstead = [
        for (final deviation in soakDeviations)
          if (deviation.instead.trim().isEmpty) deviation.id,
      ];
      expect(emptyInstead, isEmpty,
          reason: 'these deviations do not say what the soak does instead: '
              '$emptyInstead. Four of the five departures are numbers, and a '
              'departure whose replacement number is not written down is a '
              'number nobody can check');

      final tooShort = [
        for (final deviation in soakDeviations)
          if (deviation.reasoning.length < _reasoningFloor)
            '${deviation.id} (${deviation.reasoning.length} chars)',
      ];
      expect(tooShort, isEmpty,
          reason: 'these deviations reason in fewer than $_reasoningFloor '
              'characters: $tooShort. An entry too short to argue is an entry '
              'nobody argued, and the failure this floor catches is a later '
              'edit that trims a reasoning to a label while leaving the row in '
              'place — five entries, none of which says anything');
    });

    test('no entry is declared twice', () {
      final seen = <String>{};
      final duplicated = [
        for (final deviation in soakDeviations)
          if (!seen.add('${deviation.id}|${deviation.clause}')) deviation.id,
      ];
      expect(duplicated, isEmpty,
          reason: 'these deviation ids appear more than once with the same '
              'clause: $duplicated. Two entries for one departure make the '
              'count agree with the declaration while covering one fewer '
              'thing than it claims. Two entries against the SAME clause with '
              'DIFFERENT ids are legitimate and deliberate — the heap clause '
              'is departed from twice, once for what is asserted and once for '
              'where it is judged');
    });
  });

  group('the checker names', () {
    test('are exactly the six this phase declared, all distinct', () {
      expect(declaredCheckers, hasLength(_declaredCheckerNames),
          reason: 'declaredCheckers holds ${declaredCheckers.length} names and '
              'this phase declares $_declaredCheckerNames — the five §7.8 '
              'invariants plus the divergence ledger. A sixth invariant is a '
              'finding worth a conversation, not a name added to a list; a '
              'missing one is a checker nobody will notice never registered, '
              'because an unregistered name prints as pending and an absent '
              'name prints as nothing at all');

      expect(declaredCheckers.toSet(), hasLength(_declaredCheckerNames),
          reason: 'declaredCheckers holds a duplicate: $declaredCheckers. The '
              'registration audit is keyed by name, so two checkers sharing '
              'one name would share one slot and the second would silently '
              'replace the first');
    });

    test('name the five invariants of §7.8 and the ledger', () {
      // Written out rather than derived, for the same reason the counts are:
      // a renamed constant that is still in the list passes every other arm
      // in this group.
      expect(
          declaredCheckers,
          containsAll(<String>[
            'freshnessHonesty',
            'terminalStateWrites',
            'eventualResync',
            'boundedMemory',
            'boundedLogs',
            'divergenceLedger',
          ]),
          reason: 'declaredCheckers is $declaredCheckers, which is missing one '
              'of the six names 11-04, 11-05 and 11-06 register against. A '
              'checker registering under a name this list does not hold fails '
              'the registration audit, so a rename here silently breaks a '
              'later plan rather than this one');
    });

    test('no name is empty or padded', () {
      final malformed = [
        for (final name in declaredCheckers)
          if (name.trim() != name || name.isEmpty) '"$name"',
      ];
      expect(malformed, isEmpty,
          reason: 'these checker names are empty or carry surrounding '
              'whitespace: $malformed. The names are map keys in the '
              'registration audit and in the per-checker verdict block, and a '
              'padded key reads identically to its unpadded twin in a run '
              'report while failing every lookup');
    });
  });

  group('the vacuity gate', () {
    test('a checker one reading below its floor fails, and it is named', () {
      final blind = _FakeChecker(
        name: boundedLogs,
        judged: 29,
        floor: 30,
      );

      Object? thrown;
      try {
        assertNoVacuousVerdict(<InvariantChecker>[blind]);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<TestFailure>(),
          reason: 'a checker one reading short of its floor passed the gate. '
              'That is a run reporting a green verdict on an invariant it did '
              'not measure enough of to have one, which is the exact failure '
              'this gate exists for');
      expect(thrown.toString(), contains(boundedLogs),
          reason: 'the failure does not name the checker: $thrown. Naming only '
              'the invariant sends the reader to the wrong file — the pipe may '
              'be fine and the instrument blind, and those are different '
              'mornings');
      expect(thrown.toString(), contains('29'),
          reason: 'the failure does not carry the count it measured: $thrown. '
              'Without both numbers the reader cannot tell "took none" from '
              '"took nearly enough", and those need different responses');
      expect(thrown.toString(), contains('30'),
          reason: 'the failure does not carry the floor it measured against: '
              '$thrown');
    });

    test('a checker exactly at its floor passes', () {
      final atFloor = _FakeChecker(
        name: freshnessHonesty,
        judged: 30,
        floor: 30,
      );

      expect(() => assertNoVacuousVerdict(<InvariantChecker>[atFloor]),
          returnsNormally,
          reason: 'the floor is a minimum, not an exclusive bound. A checker '
              'that took exactly the readings its floor demands has the '
              'evidence its verdict claims, and failing it would make every '
              'floor secretly one higher than it says');
    });

    test('an empty list passes, because 11-03 lands a driver with none', () {
      expect(() => assertNoVacuousVerdict(<InvariantChecker>[]), returnsNormally,
          reason: 'the empty-list call is deliberately a seam: 11-03 lands the '
              'driver with zero checkers registered and calls this, so 11-04 '
              'adds a checker instead of performing a refactor. Failing here '
              'would force the driver plan to debug a checker and a harness at '
              'the same time');
    });

    test('the floor scales with the DECLARED duration, not with elapsed', () {
      const perMinute = 20;
      final short = minimumSamplesForDuration(
          perMinute: perMinute, declared: const Duration(seconds: 90));
      final full = minimumSamplesForDuration(
          perMinute: perMinute, declared: const Duration(minutes: 35));

      print('floor at $perMinute/min: 90 s arm = $short readings, '
          '35 min arm = $full readings');

      expect(short, 30,
          reason: 'the 90-second arm floors at $short readings for '
              '$perMinute/min, and ninety seconds is a minute and a half. A '
              'floor that did not scale would give the short arm the long '
              "arm's floor, which it cannot reach — and a lane that always "
              'fails gets excluded, which is how a soak stops running');
      expect(full, 700,
          reason: 'the 35-minute arm floors at $full readings for '
              '$perMinute/min. If this equalled the short arm\'s floor the '
              'long arm would clear it in the first ninety seconds and the '
              'remaining thirty-three minutes would be unaudited');
    });

    test('the floor never computes to zero', () {
      final tiny = minimumSamplesForDuration(
          perMinute: 1, declared: const Duration(milliseconds: 200));
      print('floor at 1/min over 200 ms = $tiny reading');

      expect(tiny, greaterThanOrEqualTo(1),
          reason: 'the floor computed to $tiny for a very short run, which is '
              'an assertion that cannot fail. A checker with a zero floor is '
              'indistinguishable in a run report from a checker that worked, '
              'and that is the whole thing this apparatus exists to prevent');
    });
  });

  group('a checker whose sample throws', () {
    test('records a violation and does not propagate', () {
      final broken = _ThrowingChecker();
      final clock = SoakClock.frozenAt(const Duration(seconds: 12),
          declaredDuration: const Duration(seconds: 90));

      expect(() => broken.sample(clock), returnsNormally,
          reason: 'the checker threw out of sample() and killed the run. One '
              'trip must not end the soak: the question "did the other four '
              'also fail, and did this one recur?" is worth more than the '
              'minutes saved, and the run has to reach its end-of-run '
              'reconciliation to produce a verdict at all');

      expect(broken.violations, hasLength(1),
          reason: 'the throw was swallowed without a trace. A checker that '
              'silently stops reading is worse than one that crashes — it '
              'reports green for the rest of the run');
      expect(broken.violations.single.toString(), contains('the sampler blew up'),
          reason: 'the recorded violation does not carry the original error: '
              '${broken.violations.single}. The exception is the only evidence '
              'of what broke, and it is gone by the time anybody reads the '
              'journal');
      expect(broken.violations.single.checker, boundedMemory,
          reason: 'the violation is attributed to '
              '"${broken.violations.single.checker}" rather than to the '
              'checker that threw');
    });

    test('and takes no judgeable reading for it', () {
      final broken = _ThrowingChecker();
      final clock = SoakClock.frozenAt(const Duration(seconds: 1),
          declaredDuration: const Duration(seconds: 90));
      for (var i = 0; i < 5; i++) {
        broken.sample(clock);
      }

      expect(broken.judgedSamples, 0,
          reason: 'a checker that threw five times counted '
              '${broken.judgedSamples} judgeable readings. A reading that '
              'ended in an exception judged nothing, and counting it would let '
              'a permanently broken sampler clear its own floor — the two '
              'mechanisms would then cancel out exactly where they are both '
              'needed');
    });
  });

  group('the violation log', () {
    test('caps at its capacity and counts the overflow', () {
      final log = ViolationLog(capacity: 10);
      for (var i = 0; i < 84; i++) {
        log.add(_violation(detail: 'occurrence $i'));
      }
      print('violation log at capacity 10 after 84 records: '
          '${log.entries.length} retained, ${log.overflow} overflowed, '
          '${log.total} total');

      expect(log.entries, hasLength(10),
          reason: 'the log retained ${log.entries.length} of 84 violations '
              'against a capacity of 10. The freshness sampler runs at 25 ms '
              'per key per panel, so one stuck panel is eighty-four thousand '
              'violations over a full run, and retaining them makes the '
              'harness the leak it is measuring');
      expect(log.overflow, 74,
          reason: 'the overflow counted ${log.overflow} rather than 74. A '
              'capped list without a counter reports "10 violations" for a run '
              'that had eighty-four, which is a worse lie than the memory it '
              'saves');
      expect(log.total, 84,
          reason: 'the total came to ${log.total} rather than 84 — and the '
              'total is the number that goes in the verdict block');
    });

    test('keeps the first occurrences, not the last', () {
      final log = ViolationLog(capacity: 3);
      for (var i = 0; i < 6; i++) {
        log.add(_violation(detail: 'occurrence $i'));
      }

      expect(log.entries.first.detail, 'occurrence 0',
          reason: 'the log kept the latest violations and dropped the '
              'earliest. What a soak needs is when the breach STARTED — the '
              'hundred-thousandth instance of a stuck panel says nothing the '
              'first did not, and the first is the one with the timeline '
              'position worth looking up');
      expect(log.entries.last.detail, 'occurrence 2',
          reason: 'the retained window is not the first three: '
              '${log.entries.map((v) => v.detail).toList()}');
    });
  });

  group('a violation quotes itself completely', () {
    test('so it can be pasted into an issue without the run', () {
      final rendered = _violation(
        detail: 'rendered a value 4,200 ms old as fresh',
        panel: 'panel-3',
        key: 'ST101.CN01.run',
        observed: 'fresh',
        expected: 'stale',
        scheduleOffset: const Duration(minutes: 23, seconds: 4),
      ).toString();
      print('violation renders as: $rendered');

      for (final fragment in <String>[
        boundedMemory,
        'panel-3',
        'ST101.CN01.run',
        'fresh',
        'stale',
        '+23:04',
        'rendered a value 4,200 ms old as fresh',
      ]) {
        expect(rendered, contains(fragment),
            reason: 'the rendered violation is missing "$fragment": '
                '$rendered. A violation quoted into an issue is read by '
                'somebody who does not have the run, and every field left out '
                'of toString is a field they have to ask for');
      }
    });

    test('a violation with no timeline position says so rather than zero', () {
      final rendered = _violation(detail: 'the sampler blew up').toString();

      expect(rendered, contains('n/a'),
          reason: 'a violation with no schedule offset rendered as $rendered. '
              'Printing +00:00.000 for "not attributable to a timeline entry" '
              'sends the reader to the first event of the run, which is the '
              'one place the fault definitely was not');
    });
  });

  group('the contract exposes no wall clock', () {
    test('invariant.dart does not reach one, anywhere', () {
      final source = File(_invariantSource).readAsStringSync();
      final mentions = _wallClockMentions(source);

      expect(mentions, isEmpty,
          reason: 'the checker contract reaches a wall clock at: $mentions. '
              'SoakClock hands out monotonic elapsed and the declared duration '
              'and nothing else on purpose — 07-REVIEW CR-01\'s standing '
              'lesson is never to age a verdict on the panel\'s RTC, and this '
              'file makes that unreachable rather than merely forbidden. The '
              'journal takes its own wall reading, because the journal is '
              'output');
    });

    test('and the sweep bites a file that does reach one', () {
      // A sweep that stops looking reports full coverage of nothing
      // (gate_manifest_test.dart:35). The arm above passes on an empty file,
      // so this one feeds it a file that should fail.
      const planted = 'final stamp = DateTime.now();';

      expect(_wallClockMentions(planted), isNotEmpty,
          reason: 'the wall-clock sweep did not catch a planted '
              'occurrence, so the arm above is decoration: it would pass on '
              'the day somebody adds one');
    });
  });

  group('the reverse sweep', () {
    test('a checker under an undeclared name fails, and is named', () {
      final rogue = _FakeChecker(name: 'jitterBudget', judged: 10, floor: 1);

      Object? thrown;
      try {
        assertEveryCheckerIsDeclared(
            <InvariantChecker>[rogue], declaredCheckers);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<TestFailure>(),
          reason: 'a checker registered under a name soak_registry.dart does '
              'not declare passed the sweep. That checker is invisible to the '
              'verdict block, so it neither reports nor shows up as pending — '
              'the one state the registry exists to make impossible');
      expect(thrown.toString(), contains('jitterBudget'),
          reason: 'the failure does not name the undeclared checker: $thrown');
    });

    test('the declared names pass', () {
      final declared = <InvariantChecker>[
        for (final name in declaredCheckers)
          _FakeChecker(name: name, judged: 1, floor: 1),
      ];

      expect(() => assertEveryCheckerIsDeclared(declared, declaredCheckers),
          returnsNormally,
          reason: 'a checker registered under one of the six declared names '
              'was rejected, which would make the registry unusable by the '
              'three plans that register against it');
    });
  });
}

/// Where the contract lives, relative to the package root.
const String _invariantSource = 'test/support/soak/invariant.dart';

/// Every line of [source] that reaches a wall clock.
///
/// Two spellings, because both are reachable: the type name, and the `.now()`
/// call on anything that offers one.
List<String> _wallClockMentions(String source) {
  final lines = source.split('\n');
  return <String>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].contains('DateTime') || lines[i].contains('.now()'))
        'line ${i + 1}: ${lines[i].trim()}',
  ];
}

SoakViolation _violation({
  required String detail,
  String? panel,
  String? key,
  Object? observed,
  Object? expected,
  Duration? scheduleOffset,
}) =>
    SoakViolation(
      checker: boundedMemory,
      monotonic: const Duration(minutes: 23, seconds: 7, milliseconds: 412),
      scheduleOffset: scheduleOffset,
      detail: detail,
      panel: panel,
      key: key,
      observed: observed,
      expected: expected,
    );

/// A checker with the counters set by hand, for driving the gate.
final class _FakeChecker implements InvariantChecker {
  _FakeChecker({
    required this.name,
    required int judged,
    required int floor,
  })  : judgedSamples = judged,
        minimumSamplesForAVerdict = floor;

  @override
  final String name;

  @override
  final int judgedSamples;

  @override
  final int minimumSamplesForAVerdict;

  @override
  List<SoakViolation> get violations => const <SoakViolation>[];

  // This fake drives the vacuity gate and records nothing, so both counters
  // are zero and agree with the empty list above. A fake whose total
  // disagreed with its retained list would be a fake that could not be used
  // to test the gate it exists for.
  @override
  int get violationTotal => 0;

  @override
  int get violationOverflow => 0;

  @override
  void sample(SoakClock clock) {}
}

/// A checker whose reading throws every time, which is what
/// [GuardedSampling] is for.
final class _ThrowingChecker with GuardedSampling {
  @override
  final String name = boundedMemory;

  @override
  final ViolationLog violationLog = ViolationLog();

  @override
  int judgedSamples = 0;

  @override
  int get minimumSamplesForAVerdict => 1;

  @override
  void takeReading(SoakClock clock) {
    throw StateError('the sampler blew up');
  }
}
