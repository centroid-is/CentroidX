/// The journal, driven with synthetic checkpoints and synthetic violations.
///
/// **No pipe and no panels here.** The journal is the one piece of the soak
/// that can be proved on its own, and proving it on its own is the point: at
/// minute 23 of a real run it is the only thing standing between a failure and
/// a re-run, so it must not be first exercised by the run it exists to
/// diagnose.
///
/// The load-bearing case is [_flatAcrossFiveThousand]'s: the journal's own
/// retained-object count, sampled three times across five thousand
/// checkpoints, must not move. That is the harness proving it is not the leak
/// it will be measuring (pitfall 1), and it is asserted **on the structure,
/// never on RSS** — the same doctrine invariant 4 itself is built on.
@TestOn('vm')
@Tags(['soak'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/soak/invariant.dart';
import '../support/soak/soak_journal.dart';
import 'soak_registry.dart';

/// Named so the doc comment above can point at it.
const String _flatAcrossFiveThousand =
    'the retained-object count is flat across 5,000 checkpoints';

/// The declared duration every case in this file pretends to.
const Duration _declared = Duration(seconds: 90);

void main() {
  late Directory tmp;
  late SoakClock clock;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soak-journal-');
    clock = SoakClock.frozenAt(const Duration(seconds: 7),
        declaredDuration: _declared);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the seed', () {
    test('reaches stdout before anything else, and nothing else joins it',
        () async {
      final printed = <String>[];
      await runZoned(() async {
        announceSoakSeed(11, declaredDuration: _declared);
        final journal = SoakJournal.open(seed: 11, path: tmp.path);
        journal.writeConfig(<String, Object?>{'panels': 5});
        journal.writeReproLog('scenario seed=11 entries=0');
        journal.checkpoint(clock, <String, Object?>{'complaints': 0});
        journal.event(clock, <String, Object?>{'kind': 'flap'});
        await journal.close();
      },
          zoneSpecification: ZoneSpecification(
              print: (_, __, ___, line) => printed.add(line)));

      expect(printed, isNotEmpty,
          reason: 'nothing reached stdout at all. A run killed by a CI '
              'timeout, an OOM or a cancelled workflow leaves its stdout '
              'behind and may leave nothing else; the seed line is the '
              'cheapest insurance the soak has and it costs one print');
      expect(printed.first, contains('seed=11'),
          reason: 'the first line of output is "${printed.first}", which does '
              'not name the seed. It has to be first and not merely present: '
              'a killed run\'s tail is what a reader sees, and a seed printed '
              'after composition is a seed that never printed');
      expect(printed.first, contains(soakReproductionCommand(11)),
          reason: 'the seed line does not carry the command that reproduces '
              'the run: "${printed.first}". The reader who needs it most is '
              'the one looking at a truncated log');
      expect(printed, hasLength(1),
          reason: 'the journal printed as well as writing: $printed. Anything '
              'else on stdout pushes the seed line up the scrollback, and '
              'stdout in a hot loop is exactly the per-burst lag this file '
              'exists to avoid — everything else goes to disk');
    });
  });

  group('what is written before the clock starts', () {
    test('the merged timeline and the run constants, both on disk', () async {
      final journal = SoakJournal.open(seed: 23, path: tmp.path);
      journal.writeReproLog('scenario seed=23 entries=412 duration=0:35:00');
      journal.writeConfig(<String, Object?>{
        'panels': 5,
        'controlPanel': 0,
        'checkpointCadenceMs': 5000,
      });

      // Before close(), deliberately: the end of the run may not arrive, and
      // a timeline written at minute 35 is worthless to a run that died at 23.
      expect(File('${tmp.path}/repro.log').readAsStringSync(),
          contains('seed=23 entries=412'),
          reason: 'repro.log is not on disk before the first fault fires. The '
              'timeline is pure and fully known at t=0, so there is no reason '
              'to hold it, and every reason not to');

      final config = jsonDecode(File('${tmp.path}/config.json').readAsStringSync())
          as Map<String, Object?>;
      expect(config['seed'], 23,
          reason: 'config.json does not carry the seed: $config. Every '
              'artifact in the directory has to name its run, because they are '
              'read one at a time out of a downloaded zip');
      expect(config['checkpointCadenceMs'], 5000,
          reason: 'config.json dropped a constant it was given: $config. A '
              'verdict read six months later against changed defaults is '
              'uninterpretable, and the defaults are the thing nobody thinks '
              'to record');

      await journal.close();
    });
  });

  group('what is streamed during the run', () {
    test('one JSON object per checkpoint, written as it goes', () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      for (var i = 0; i < 3; i++) {
        journal.checkpoint(clock, <String, Object?>{'unresolvedWrites': i});
      }
      await journal.close();

      final lines = File('${tmp.path}/metrics.jsonl')
          .readAsLinesSync()
          .where((line) => line.isNotEmpty)
          .toList();
      expect(lines, hasLength(3),
          reason: 'metrics.jsonl holds ${lines.length} lines for three '
              'checkpoints. One object per line is what makes the file '
              'greppable and makes "when did this start growing?" one jq '
              'invocation');

      final decoded = lines
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      expect(decoded.map((r) => r['unresolvedWrites']), <int>[0, 1, 2],
          reason: 'the checkpoints are out of order or lost their payload: '
              '$decoded');
      expect(decoded.map((r) => r['checkpoint']), <int>[0, 1, 2],
          reason: 'the checkpoints are not indexed: $decoded. The trip record '
              'quotes the last twenty inline and a reader has to be able to '
              'line those up against the file');
    });

    test('every checkpoint carries BOTH clocks — 09-review WR-01', () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      journal.checkpoint(clock, <String, Object?>{'complaints': 0});
      await journal.close();

      final record = jsonDecode(File('${tmp.path}/metrics.jsonl')
          .readAsLinesSync()
          .first) as Map<String, Object?>;

      expect(record['monotonicMs'], 7000,
          reason: 'the checkpoint does not carry the monotonic reading: '
              '$record. Every verdict in the soak is aged on this clock');
      expect(record['wallMs'], isA<int>(),
          reason: 'the checkpoint does not carry a wall reading: $record. '
              'This is 09-review WR-01\'s owed cross-check: the reaper\'s '
              'stall forgiveness compares in ONE clock domain, the two domains '
              'agree under every lever the gate can pull, and they diverge '
              'exactly under a VM-snapshot stun where the guest\'s monotonic '
              'clock does not observe the freeze. The soak cannot produce a '
              'snapshot and therefore cannot produce a verdict — what it can '
              'do is make a divergence VISIBLE in the artifact rather than '
              'invisible by construction, and that costs one field per line');
      expect(record['wallMs'], greaterThan(1_700_000_000_000),
          reason: 'the wall reading is ${record['wallMs']}, which is not a '
              'plausible epoch millisecond count — a placeholder in this field '
              'is worse than an absent one, because a reader would compare it');
    });

    test('applied timeline entries stream with their offsets', () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      journal.event(clock, <String, Object?>{'kind': 'flap', 'panel': 'p1'});
      journal.event(clock, <String, Object?>{'kind': 'clean', 'panel': 'p1'});
      await journal.close();

      final lines = File('${tmp.path}/events.jsonl')
          .readAsLinesSync()
          .where((line) => line.isNotEmpty)
          .toList();
      expect(lines, hasLength(2),
          reason: 'events.jsonl holds ${lines.length} of two applied entries. '
              'Planned lives in repro.log; this file is what actually fired, '
              'and *planned ≠ applied* — a lever that silently did not — is a '
              'real failure mode that each half hides on its own');

      final first = jsonDecode(lines.first) as Map<String, Object?>;
      expect(first['monotonicMs'], 7000,
          reason: 'an applied event has no offset: $first. Without one it '
              'cannot be lined up against the metrics or against the '
              'timeline');
      expect(first['kind'], 'flap',
          reason: 'the event lost its payload: $first');
    });

    test(_flatAcrossFiveThousand, () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      final samples = <int, Map<String, int>>{};

      for (var i = 1; i <= 5000; i++) {
        journal.checkpoint(clock, <String, Object?>{
          'unresolvedWrites': i % 7,
          'complaints': i % 3,
          'rssBytes': 100000000 + i,
        });
        if (i == 100 || i == 2500 || i == 5000) {
          samples[i] = journal.retainedInventory;
        }
      }
      print('journal retention across 5,000 checkpoints: '
          '${samples.entries.map((e) => 'at ${e.key}: ${e.value} '
              '(total ${e.value.values.fold(0, (a, b) => a + b)})').join(' | ')}');
      await journal.close();

      final totals = samples.map(
          (at, inventory) => MapEntry(at, inventory.values.fold(0, (a, b) => a + b)));
      expect(totals[2500], totals[100],
          reason: 'the journal retained ${totals[100]} objects at checkpoint '
              '100 and ${totals[2500]} at 2,500. The recorder is accumulating, '
              'which means the harness becomes the leak invariant 4 is '
              'measuring — 07-RESEARCH trap 15 watched exactly this happen '
              'once already, when FrameSeam retained every inbound frame and '
              'twenty seconds of ticks made a gate case "the unbounded memory '
              'growth it is asserting against". Read the itemised inventory '
              'above to see which field grew');
      expect(totals[5000], totals[100],
          reason: 'the journal retained ${totals[100]} objects at checkpoint '
              '100 and ${totals[5000]} at 5,000. Five thousand checkpoints is '
              'roughly a seven-hour run at the 5 s cadence, so a slope here is '
              'a slope a real thirty-five-minute run would show at a twelfth '
              'the size — visible, but only to somebody looking');
      expect(totals[100], lessThan(100),
          reason: 'the journal holds ${totals[100]} objects, which is flat but '
              'large. Flat and large means somebody bounded a structure '
              'without sizing it: the tail is twenty checkpoints and the rings '
              'are empty in this case, so this number should be small enough '
              'to read');
      expect(journal.checkpointCount, 5000,
          reason: 'the journal counted ${journal.checkpointCount} of 5,000 '
              'checkpoints — a flat retention count means nothing if the '
              'checkpoints were not actually taken');
    });
  });

  group('the frame ring', () {
    test('holds exactly its capacity, and the OLDEST is the one that goes',
        () {
      final ring = FrameRing(capacity: 4);
      for (var i = 0; i < 5; i++) {
        ring.add(JournalledFrame(
          arrival: Duration(milliseconds: i * 100),
          seq: i,
          summary: 'frame $i',
        ));
      }

      expect(ring.length, 4,
          reason: 'the ring holds ${ring.length} frames at capacity + 1. A '
              'ring that grows is a list, and thirty-five minutes of inbound '
              'frames per panel is trap 15 with more zeroes');
      expect(ring.entries.first.seq, 1,
          reason: 'the ring dropped the newest instead of the oldest: '
              '${ring.entries.map((f) => f.seq).toList()}. A trip is diagnosed '
              'from what arrived immediately BEFORE it, which is the opposite '
              'of the violation log\'s choice and deliberately so');
      expect(ring.entries.last.seq, 4,
          reason: 'the most recent frame is not in the ring: '
              '${ring.entries.map((f) => f.seq).toList()}');
      expect(ring.evicted, 1,
          reason: 'the ring evicted ${ring.evicted} frames and counted '
              'differently. A bounded structure that does not say how much it '
              'dropped makes a partial dump look like a complete one');
    });

    test('the default capacity is stated and not incidental', () {
      expect(frameRingCapacity, 200,
          reason: 'the per-panel frame ring capacity is $frameRingCapacity. '
              'The number is load-bearing — five panels at two hundred is a '
              'thousand frames of headroom, roughly the last minute before a '
              'trip — and changing it means changing the arithmetic in its '
              'doc, not just the literal');
    });
  });

  group('the trip record', () {
    test('a trip with no ring says the ring was NOT RECORDED, never that it '
        'was empty', () async {
      // `SoakJournal.frame` has no producer in the composed run — nothing
      // outside this file calls it — so `_rings` is always empty on a real
      // run and every trip record takes this branch. The old wording, "no
      // frame ring for this violation", cannot be told apart from "the ring
      // was checked and nothing had arrived", and the file's opening doc
      // promises the reader "roughly the last minute before a trip, which is
      // the window a trip is diagnosed from". A forensic artifact that
      // silently reports its own absence is worse than no artifact.
      final journal = SoakJournal.open(seed: 11, path: tmp.path)
        ..writeTrip(
          SoakViolation(
            checker: 'freshnessHonesty',
            monotonic: const Duration(minutes: 5),
            scheduleOffset: const Duration(minutes: 5),
            panel: 'panel-2',
            detail: 'a breach with no frames behind it',
          ),
          armedModes: const <String>['blackhole'],
        );
      await journal.close();

      final trip = File('${tmp.path}/trip-0.txt').readAsStringSync();
      expect(trip, contains('NOT RECORDED'),
          reason: 'the reader must be told this is missing instrumentation '
              'rather than a quiet minute');
      expect(trip, contains('no producer'));
      expect(trip, isNot(contains('no frame ring for this violation')),
          reason: 'the ambiguous wording is the whole finding');
    });

    test('frames reach disk ONLY on a trip', () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      for (var i = 0; i < 3; i++) {
        journal.frame(
            'panel-2',
            JournalledFrame(
                arrival: Duration(milliseconds: i),
                seq: i,
                summary: 'u seq=$i'));
      }
      journal.checkpoint(clock, <String, Object?>{'complaints': 0});
      await journal.close();

      expect(File('${tmp.path}/frames-panel-2.jsonl').existsSync(), isFalse,
          reason: 'a green run wrote its frame rings to disk. Every panel '
              'dumping its ring on a passing soak makes the artifact unusable '
              'for the thing it is for — reading the ONE panel that tripped');
    });

    test('is self-contained: seed, offsets, armed modes, and the command',
        () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      for (var i = 0; i < 3; i++) {
        journal.checkpoint(clock, <String, Object?>{'complaints': i});
      }
      journal.frame(
          'panel-2',
          const JournalledFrame(
              arrival: Duration(milliseconds: 40), seq: 91, summary: 'u seq=91'));

      journal.writeTrip(
        SoakViolation(
          checker: freshnessHonesty,
          monotonic: const Duration(minutes: 23, seconds: 7),
          scheduleOffset: const Duration(minutes: 22, seconds: 58),
          detail: 'rendered a value 4,200 ms old as fresh',
          panel: 'panel-2',
          key: 'ST101.CN01.run',
          observed: 'fresh',
          expected: 'stale',
        ),
        armedModes: <String>['blackhole', 'latency'],
      );
      await journal.close();

      final trip = File('${tmp.path}/trip-0.txt').readAsStringSync();
      print('trip record is ${trip.length} characters');

      for (final fragment in <String>[
        'seed=11',
        freshnessHonesty,
        'panel-2',
        'ST101.CN01.run',
        '+23:07',
        '+22:58',
        'blackhole, latency',
        'RELAY_SOAK=1 RELAY_SOAK_SEED=11 dart test test/soak --tags soak',
      ]) {
        expect(trip, contains(fragment),
            reason: 'the trip record is missing "$fragment". It is read by '
                'somebody who does not have the run and cannot get it back: a '
                'minute-23 trip has to be diagnosable without re-running '
                'twenty-three minutes, and every field left out is a field '
                'that costs half an hour to recover.\n\n$trip');
      }

      expect(trip, contains('"complaints":2'),
          reason: 'the trip record does not quote the checkpoints leading up '
              'to the trip. What broke is half the question; when it started '
              'is the other half, and re-reading metrics.jsonl from inside the '
              'run would be the journal reading its own output.\n\n$trip');

      expect(File('${tmp.path}/frames-panel-2.jsonl').readAsStringSync(),
          contains('"seq":91'),
          reason: 'the tripping panel\'s frame ring was not dumped. The ring '
              'is held in memory for exactly this moment and discarded '
              'otherwise');
    });

    test('a trip on no particular panel still writes a record', () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      journal.writeTrip(
        const SoakViolation(
          checker: divergenceLedger,
          monotonic: Duration(minutes: 4),
          scheduleOffset: null,
          detail: 'the ledger control did not fire',
        ),
        armedModes: const <String>[],
      );
      await journal.close();

      final trip = File('${tmp.path}/trip-0.txt').readAsStringSync();
      expect(trip, contains(divergenceLedger),
          reason: 'a violation with no panel produced no readable record: '
              '$trip. Two of the six things the soak checks are not per-panel, '
              'and a record shape that only works for the other four loses '
              'them silently');
      expect(trip, contains('(none'),
          reason: 'the record prints an empty panel rather than saying there '
              'is none: $trip. A blank field reads as a missing field');
    });

    test('trips are numbered, so the second does not overwrite the first',
        () async {
      final journal = SoakJournal.open(seed: 11, path: tmp.path);
      for (var i = 0; i < 2; i++) {
        journal.writeTrip(
          SoakViolation(
            checker: boundedLogs,
            monotonic: Duration(minutes: i + 1),
            scheduleOffset: null,
            detail: 'complaint rate ceiling exceeded, occurrence $i',
          ),
          armedModes: const <String>['flap'],
        );
      }
      await journal.close();

      expect(File('${tmp.path}/trip-0.txt').existsSync(), isTrue,
          reason: 'the first trip record is gone');
      expect(File('${tmp.path}/trip-1.txt').readAsStringSync(),
          contains('occurrence 1'),
          reason: 'the second trip overwrote the first. A violation never ends '
              'the run, so a soak that trips is expected to trip more than '
              'once, and the FIRST is usually the informative one');
      expect(journal.tripCount, 2);
    });
  });

  group('where it writes', () {
    test('the default directory is the one the gitignore covers', () {
      expect(defaultSoakJournalDir, 'build/soak',
          reason: 'the journal writes to $defaultSoakJournalDir, and '
              'packages/tfc_relay_local/.gitignore ignores build/soak/. '
              'Moving one without the other puts a run\'s artifacts in front '
              'of `git add`, which is how a credential sweep becomes '
              'necessary rather than precautionary');
      expect(defaultSoakJournalDir, startsWith('build/'),
          reason: 'the journal writes outside build/, which the repository '
              'root ignores wholesale — the package-level rule is the '
              'explanation, not the only defence, and losing the second one is '
              'not worth doing quietly');
    });

    test('creates its directory rather than requiring one', () async {
      final nested = '${tmp.path}/build/soak';
      expect(Directory(nested).existsSync(), isFalse);

      final journal = SoakJournal.open(seed: 11, path: nested);
      journal.checkpoint(clock, <String, Object?>{'complaints': 0});
      await journal.close();

      expect(File('$nested/metrics.jsonl').existsSync(), isTrue,
          reason: 'the journal needed its directory to already exist. A fresh '
              'CI checkout has no build/ at all, and a soak that dies before '
              'the first fault because of a missing directory is the most '
              'expensive possible way to find that out');
    });
  });
}
