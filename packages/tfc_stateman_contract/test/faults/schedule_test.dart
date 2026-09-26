/// The seeded fault-storm driver: generation is pure, playback is timed.
///
/// The generation arms are plain computation — no sockets, no timers, no
/// clock — which is the whole claim `scenario_schedule.dart` makes, and the
/// reason they run in milliseconds while the rest of this directory measures
/// wall-clock behaviour through loopback.
///
/// Tagged `faults` with the rest of the kit rather than left untagged: the
/// playback arm below does open a proxy and a client, so a run that excluded
/// this file by tag and still exercised it would be measuring sockets in a
/// lane that promised none.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

/// The soak duration notes §7.8 specifies, used by the entry-count arm.
const _soakDuration = Duration(minutes: 30);

/// A short storm for the playback arms: seconds, not thirty minutes.
///
/// Phase 11 owns the long soak; this plan owns the instrument, and an
/// instrument that took half an hour to check would not be checked.
const _shortStorm = Duration(milliseconds: 2500);
const _shortMinGap = Duration(milliseconds: 150);
const _shortMaxGap = Duration(milliseconds: 400);

/// How many seeds the forbidden-pair sweep covers.
///
/// The plan asks for at least 100. The sweep is pure computation over a
/// half-hour timeline each, so the cost of the extra seeds is a second and the
/// benefit is that a rule with a narrow hole is more likely to fall into it.
const _sweepSeeds = 150;

void main() {
  group('ScenarioSchedule.generate — the pure part', () {
    test('the same seed produces an identical timeline', () {
      final first = ScenarioSchedule.generate(
        seed: 42,
        duration: _soakDuration,
      );
      final second = ScenarioSchedule.generate(
        seed: 42,
        duration: _soakDuration,
      );

      // Element-wise equality over the whole list, not a length comparison: a
      // generator that drifted in its parameters while keeping its cadence
      // would produce two lists of the same length describing two different
      // runs, and reproduction from a seed would be a claim nobody checked.
      expect(second, equals(first),
          reason: 'a soak failure is reproduced from its seed alone, so two '
              'generations of one seed that differ mean the repro procedure '
              'in notes §7.8 does not work');

      // And byte-identical once serialised, because the serialised form is
      // what a failing run prints and what a human pastes back.
      expect(ScenarioSchedule.reproLog(seed: 42, timeline: second),
          equals(ScenarioSchedule.reproLog(seed: 42, timeline: first)));
    });

    test('different seeds produce different timelines', () {
      final logs = <String>{};
      for (var seed = 1; seed <= 20; seed++) {
        final timeline =
            ScenarioSchedule.generate(seed: seed, duration: _soakDuration);
        logs.add(ScenarioSchedule.reproLog(seed: seed, timeline: timeline));
      }
      expect(logs, hasLength(20),
          reason: 'two seeds that generate the same storm make the seed '
              'useless as a way to vary a soak run');
    });

    test('a 30-minute run is a few hundred entries, generated in well under a '
        'second', () {
      final clock = Stopwatch()..start();
      final timeline = ScenarioSchedule.generate(
        seed: 7,
        duration: _soakDuration,
        weights: ScenarioWeights.everything,
      );
      clock.stop();

      // 30 minutes at a 1–10 s cadence is ~327 draws; conflict resolution adds
      // a clear or two per arming draw, so the band is wide on the top side.
      expect(timeline.length, inInclusiveRange(200, 1200),
          reason: 'notes §7.8 sizes a 30-minute storm at a few hundred '
              'entries; far outside that band means the cadence drifted');
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'Phase 11 generates the whole timeline before the soak '
              'starts, so generation cost must not show up as soak time');

      expect(timeline.first.offset, greaterThanOrEqualTo(Duration.zero));
      expect(timeline.last.offset, lessThan(_soakDuration));
    });

    test('offsets never go backwards', () {
      final timeline = ScenarioSchedule.generate(
        seed: 99,
        duration: _soakDuration,
        weights: ScenarioWeights.everything,
      );
      var previous = Duration.zero;
      for (final entry in timeline) {
        expect(entry.offset, greaterThanOrEqualTo(previous),
            reason: 'playback walks the list in order against a single '
                'drift-corrected timer, so an offset that went backwards '
                'would be applied immediately and out of sequence');
        previous = entry.offset;
      }
    });

    test('no forbidden mode pair is ever co-armed, over $_sweepSeeds seeds',
        () {
      final armings = <String, int>{};
      var resolutions = 0;
      for (var seed = 0; seed < _sweepSeeds; seed++) {
        final timeline = ScenarioSchedule.generate(
          seed: seed,
          duration: _soakDuration,
          weights: ScenarioWeights.everything,
        );
        resolutions += _assertNeverCoArmed(seed, timeline, armings);
      }

      // The sweep above can only fail if the guarded path is reached, so the
      // two checks below are what stop it from passing vacuously. Without
      // them, a generator that simply never armed `reject` would sail through
      // 150 seeds having tested none of the seven rows that name it.
      expect(armings.keys, containsAll(faultModes),
          reason: 'a mode the sweep never armed is a mode whose exclusion '
              'rules the sweep never checked, so this arm would be green for '
              'a generator that had quietly stopped emitting it');
      expect(resolutions, greaterThan(100),
          reason: 'a conflict resolution is a clear emitted at the same '
              'offset immediately before an arming draw — the mechanism this '
              'whole arm exists to verify. Zero of them means the storm never '
              'produced a conflict, and the guard was never asked anything');
    });

    test('the returned timeline is unmodifiable', () {
      final timeline =
          ScenarioSchedule.generate(seed: 3, duration: const Duration(minutes: 1));

      expect(() => timeline.add(timeline.first), throwsUnsupportedError,
          reason: 'the timeline is the repro log; a caller that could append '
              'to it could make the log disagree with the seed that produced '
              'it');
      expect(() => timeline.clear(), throwsUnsupportedError);
      expect(() => timeline[0] = timeline.last, throwsUnsupportedError);
    });

    test('generation refuses arguments that cannot describe a run', () {
      expect(
          () => ScenarioSchedule.generate(seed: 1, duration: Duration.zero),
          throwsArgumentError);
      expect(
          () => ScenarioSchedule.generate(
              seed: 1,
              duration: const Duration(minutes: 1),
              minGap: Duration.zero),
          throwsArgumentError);
      expect(
          () => ScenarioSchedule.generate(
              seed: 1,
              duration: const Duration(minutes: 1),
              minGap: const Duration(seconds: 5),
              maxGap: const Duration(seconds: 1)),
          throwsArgumentError);
    });

    test('weights are checked against the mode registry', () {
      expect(() => ScenarioWeights(const {'flapp': 1}).validate(),
          throwsArgumentError,
          reason: 'a misspelled mode name would silently weight nothing, and '
              'the storm would quietly never exercise the mode its author '
              'asked for');
      expect(() => ScenarioWeights(const {'flap': 0}).validate(),
          throwsArgumentError,
          reason: 'a total weight of zero has no mode to draw');
      expect(() => ScenarioWeights(const {'flap': -1}).validate(),
          throwsArgumentError);
      expect(ScenarioWeights.soak.validate, returnsNormally);
      expect(ScenarioWeights.everything.validate, returnsNormally);
    });

    test('the default weights are the five notes §7.8 names', () {
      expect(ScenarioWeights.soak.byMode.keys,
          unorderedEquals(<String>['flap', 'latency', 'throttle', 'blackhole',
            ScenarioSchedule.cleanMode]));
    });

    test('the everything weights name every declared mode', () {
      expect(
          ScenarioWeights.everything.byMode.keys.where((m) => m != ScenarioSchedule.cleanMode),
          unorderedEquals(faultModes),
          reason: 'a mode declared in faultModes but absent here is a lever '
              'no storm can ever pull, which is the same silent gap the mode '
              'registry exists to prevent');
    });
  });

  group('ScenarioPlayback — the timed part', () {
    test('applies a generated storm to a live proxy, in order', () async {
      final proxy = await _proxy();
      final traffic = _Traffic(proxy.port)..start();
      addTearDown(traffic.stop);

      final timeline = ScenarioSchedule.generate(
        seed: 2026,
        duration: _shortStorm,
        minGap: _shortMinGap,
        maxGap: _shortMaxGap,
      );
      expect(timeline, isNotEmpty,
          reason: 'a playback arm over an empty timeline asserts nothing');

      final playback =
          ScenarioPlayback(proxy: proxy, timeline: timeline, seed: 2026);
      await playback.run().timeout(_shortStorm * 4);

      expect(playback.applied, equals(timeline),
          reason: 'the applied log is how a soak notices that what ran was '
              'not what was planned — a divergence neither half can see '
              'alone.\n${playback.divergenceReport}');
    });

    test('two runs of the same seed apply the same sequence', () async {
      final first = await _playShortStorm(seed: 31337);
      final second = await _playShortStorm(seed: 31337);

      expect(second, equals(first),
          reason: 'same seed, same run — notes §7.8. Two playbacks that '
              'diverge mean the seed does not determine the storm, and a '
              'reproduction attempt would be testing something else');
    });

    test('a full 30-minute storm applies to a real proxy without a lever '
        'throwing', () async {
      // The pure sweep checks the generator against a model of the exclusion
      // table. This checks it against the table's actual enforcement — the
      // `StateError` the levers throw — by pulling every lever a half-hour
      // storm asks for, back to back and without waiting out the offsets.
      // Only the *decisions* need to be spread over thirty minutes; the
      // refusals are synchronous and state-based, so they surface just as well
      // in a tight loop.
      final proxy = await _proxy();
      final timeline = ScenarioSchedule.generate(
        seed: 8,
        duration: _soakDuration,
        weights: ScenarioWeights.everything,
      );

      for (final entry in timeline) {
        await expectLater(
          ScenarioPlayback.apply(proxy, entry.mutation),
          completes,
          reason: 'applying $entry threw, so the generator and '
              'exclusiveModePairs have drifted apart.\n'
              '${ScenarioSchedule.reproLog(seed: 8, timeline: timeline)}',
        );
      }
    });

    test('a playback stopped before it ran refuses to run rather than hanging',
        () async {
      final proxy = await _proxy();
      final timeline = ScenarioSchedule.generate(
        seed: 90210,
        duration: _shortStorm,
        minGap: _shortMinGap,
        maxGap: _shortMaxGap,
      );
      final playback =
          ScenarioPlayback(proxy: proxy, timeline: timeline, seed: 90210);

      // The order an unconditional `addTearDown(playback.stop)` registered at
      // construction produces when the body never gets as far as run().
      playback.stop();

      expect(playback.run, throwsStateError,
          reason: 'stop() only completes the run future if one exists, so a '
              'run() afterwards builds a fresh completer, calls _schedule, '
              'which returns immediately because the driver is stopped — and '
              'the future never completes. The caller then hangs until '
              'package:test times the case out thirty seconds later, and the '
              'failure names the test file rather than this object, which is '
              'the exact failure mode within() exists to eliminate everywhere '
              'else in this package');
      expect(playback.applied, isEmpty);
      expect(playback.isRunning, isFalse);
    });

    test('stop() cancels the pending timer and nothing further is applied',
        () async {
      final proxy = await _proxy();
      final timeline = ScenarioSchedule.generate(
        seed: 5150,
        duration: _shortStorm,
        minGap: _shortMinGap,
        maxGap: _shortMaxGap,
      );
      final playback =
          ScenarioPlayback(proxy: proxy, timeline: timeline, seed: 5150);

      final run = playback.run();
      await Future<void>.delayed(_shortMaxGap + const Duration(milliseconds: 50));
      playback.stop();
      final atStop = playback.applied;

      expect(atStop, isNotEmpty,
          reason: 'a stop before anything was applied would make the '
              'quiescence assertion below vacuous');
      expect(atStop.length, lessThan(timeline.length),
          reason: 'a stop after the last entry would prove nothing about '
              'cancellation');
      await run.timeout(const Duration(seconds: 1),
          onTimeout: () => fail('stop() must complete the run future; a '
              'caller awaiting it would hang for the rest of the storm'));

      // Longer than everything left on the timeline. A timer that survived
      // stop() has had every remaining offset in which to fire.
      await Future<void>.delayed(
          timeline.last.offset + const Duration(milliseconds: 500));

      expect(playback.applied, equals(atStop),
          reason: 'a timer that outlived stop() keeps pulling levers on a '
              'proxy the test has finished with, and keeps the isolate alive '
              'after the case that owned it passed — the runner then hangs at '
              'the end of the suite with no failure to point at (T-02-37)');
      expect(playback.isRunning, isFalse);
    });

    test('a lever that throws surfaces the seed and the whole timeline',
        () async {
      final proxy = await _proxy();
      // Hand-built, not generated: the generator resolves this pair away, so
      // the only way to reach the failure path is to hand playback a timeline
      // the generator would never emit. That is also the real-world shape of
      // the bug this path exists for — the table and the generator drifting.
      final timeline = <ScheduledFault>[
        const ScheduledFault(Duration.zero, RejectMutation()),
        const ScheduledFault(Duration(milliseconds: 40),
            LatencyMutation(latency: Duration(milliseconds: 20))),
      ];
      final playback =
          ScenarioPlayback(proxy: proxy, timeline: timeline, seed: 4242);

      final failure = await playback
          .run()
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(failure, isA<ScenarioPlaybackFailure>());
      final report = failure.toString();
      // The whole reproduction procedure, in the text of one failure.
      expect(report, contains('seed=4242'));
      expect(report, contains('reject on'));
      expect(report, contains('latency 20ms'));
      expect(report, contains('applied 1 of 2'));
      printOnFailure(report);
    });
  });
}

/// A proxy in front of an echo server, both torn down with the case.
Future<FaultProxy> _proxy() async {
  final upstream = await _echoServer();
  final proxy = FaultProxy(targetPort: upstream.port);
  await proxy.start();
  addTearDown(proxy.shutdown);
  return proxy;
}

/// Plays the short storm for [seed] against a fresh proxy, and returns the log.
Future<List<ScheduledFault>> _playShortStorm({required int seed}) async {
  final proxy = await _proxy();
  final traffic = _Traffic(proxy.port)..start();
  addTearDown(traffic.stop);
  final timeline = ScenarioSchedule.generate(
    seed: seed,
    duration: _shortStorm,
    minGap: _shortMinGap,
    maxGap: _shortMaxGap,
  );
  final playback =
      ScenarioPlayback(proxy: proxy, timeline: timeline, seed: seed);
  await playback.run().timeout(_shortStorm * 4);
  await traffic.stop();
  return playback.applied;
}

/// An upstream that echoes, and nothing else.
///
/// Deliberately not `composition_test.dart`'s firehose server. Plan 02-11
/// measured a firehose into a socket whose peer had gone completing as fast as
/// the loop could issue writes, starving the event loop that the test, the
/// client and package:test's own timeout all run in — a runner that never
/// returns and never fails. The storm arms above drive the same modes that
/// produced it, so they carry no firehose at all: the `gone` flag and the
/// wall-clock backstop are the cure, and having nothing to cure is better.
Future<ServerSocket> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = <Socket>[];
  addTearDown(() {
    for (final socket in accepted) {
      socket.destroy();
    }
  });
  final accepts = server.listen((socket) {
    accepted.add(socket);
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    socket.listen(
      (data) {
        try {
          socket.add(data);
        } catch (_) {
          // A storm mode cut this connection mid-echo, which several of them
          // do on purpose.
        }
      },
      onError: (Object _) => socket.destroy(),
      onDone: socket.destroy,
    );
  });
  addTearDown(accepts.cancel);
  return server;
}

/// A client that keeps trying to talk through the proxy while a storm runs.
///
/// It asserts nothing. Its only job is to make sure the levers are pulled
/// against a link that has traffic on it: a blackhole with no bytes to swallow
/// and a flap with no pair to drop exercise none of the code paths a storm is
/// supposed to reach, so a playback arm without this would be applying
/// settings to an idle object rather than driving a proxy.
final class _Traffic {
  _Traffic(this._port);

  final int _port;
  bool _stopped = false;
  Socket? _socket;

  void start() => unawaited(_loop());

  Future<void> stop() async {
    _stopped = true;
    _socket?.destroy();
    _socket = null;
  }

  Future<void> _loop() async {
    // A wall-clock backstop as well as the flag, for 02-11's reason: a flag is
    // delivered by the event loop, and the failure worth guarding against is
    // the event loop not getting a turn. A Stopwatch needs nobody's permission
    // to advance.
    final backstop = Stopwatch()..start();
    while (!_stopped && backstop.elapsed < const Duration(seconds: 60)) {
      try {
        final socket = await Socket.connect(
            InternetAddress.loopbackIPv4, _port,
            timeout: const Duration(seconds: 2));
        _socket = socket;
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        var gone = false;
        void end() => gone = true;
        socket.listen((_) {}, onError: (Object _) => end(), onDone: end);
        while (!_stopped && !gone) {
          socket.add(Uint8List.fromList(const <int>[1, 2, 3, 4]));
          await socket.flush();
          // A real gap between writes. Without it this loop is the firehose.
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        socket.destroy();
      } catch (_) {
        // The storm refused, reset or blackholed the connection — which is the
        // storm working. Reconnect after a beat.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}

/// Fails if [timeline] ever arms a mode while a mode it excludes is armed.
///
/// Derived from [exclusiveModePairs] — the proxy's own table — rather than
/// from a second copy of the rule written here. A sweep that restated the
/// exclusions would pass whenever the generator and the test made the same
/// mistake, which is the only mistake worth catching.
///
/// Counts each arming into [armings] and returns how many conflict
/// resolutions it saw, so the caller can prove the guarded path was reached.
int _assertNeverCoArmed(
    int seed, List<ScheduledFault> timeline, Map<String, int> armings) {
  final armed = <String>{};
  var resolutions = 0;
  for (var index = 0; index < timeline.length; index++) {
    final entry = timeline[index];
    final mutation = entry.mutation;
    if (!mutation.arms) {
      armed.remove(mutation.mode);
      continue;
    }
    armings[mutation.mode] = (armings[mutation.mode] ?? 0) + 1;
    // A clear sharing this entry's offset is the generator having resolved a
    // conflict rather than the storm having toggled something off in its own
    // right — the two are distinguishable only by the shared offset.
    if (index > 0 &&
        timeline[index - 1].offset == entry.offset &&
        !timeline[index - 1].mutation.arms) {
      resolutions++;
    }
    for (final conflict in exclusiveModePairs) {
      final String other;
      if (conflict.a == mutation.mode) {
        other = conflict.b;
      } else if (conflict.b == mutation.mode) {
        other = conflict.a;
      } else {
        continue;
      }
      if (!armed.contains(other)) continue;
      fail('seed $seed arms ${mutation.mode} at ${entry.offset} while $other '
          'is armed — the proxy throws a StateError at set time for that '
          'pair, so this storm would abort the soak it was generated for '
          'instead of testing it.\n'
          '${ScenarioSchedule.reproLog(seed: seed, timeline: timeline)}');
    }
    armed.add(mutation.mode);
  }
  return resolutions;
}
