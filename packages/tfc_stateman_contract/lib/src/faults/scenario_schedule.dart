/// A seeded fault storm: generated as pure data, played back against a proxy.
///
/// `[CITED: relay-websocket-notes.md §7.8]` fixes the requirement — *"failure
/// reproduction is `(seed, schedule log)` — same seed, same run"* — and
/// specifies the generator: random mode changes drawn from {flap, latency,
/// throttle, blackhole, clean} every 1–10 s for 30+ minutes.
///
/// **The determinism requirement is stricter than "use a seeded `Random`".**
/// Nothing that influences *which* fault happens or *when* may read a clock.
/// So the whole timeline is generated up front: [ScenarioSchedule.generate] is
/// a pure function from `(seed, duration, weights)` to an immutable
/// `List<ScheduledFault>`, and [ScenarioPlayback] is the only part that touches
/// time. Two things fall out of that split, and both are the reason for it:
/// generation is unit-testable with plain equality rather than with a fake
/// clock, and the generated list **is** the schedule log, so a failing soak
/// prints its own reproduction procedure with no separate recording mechanism.
///
/// This is the repo's established shape rather than a new one:
/// `packages/tfc_relay_protocol/lib/src/send_buffer.dart` states the same
/// pure-decision-core / timed-edge split in its library doc and enforces it by
/// making `poll(int nowMs)` take the clock as an argument. [FaultMutation]
/// mirrors that file's sealed-verdict shape for the same reason it has one — a
/// sealed base with one final class per lever makes [ScenarioPlayback.apply]
/// exhaustive, so a ninth mutation added without teaching playback about it is
/// a compile error rather than a lever that silently never fires.
///
/// **Seeded, and deliberately so.**
/// `packages/tfc_relay_protocol/lib/src/ulid.dart:17-21` insists on
/// [Random.secure] and explains why: a predictable write id lets a hostile
/// client re-query another operator's write outcome. This file insists on the
/// opposite, and names that one so the divergence reads as a decision rather
/// than as an oversight — a storm nobody can replay is a storm whose failures
/// cannot be fixed, and there is no attacker here to keep in the dark.
///
/// It goes one step further than `Random(seed)`, because the SDK's own seeded
/// generator documents that *"the implementation of the random stream can
/// change between releases"*. A repro log that stops reproducing after a Dart
/// upgrade is not a repro log — Phase 11's soak failures will be reproduced
/// weeks later, on a machine that has been updated in the meantime. So
/// [SeededScenarioRandom] is a `Random` this file owns and pins: same seed,
/// same stream, for as long as this source file says what it says.
///
/// **The generator consults the proxy's exclusion table.** `exclusiveModePairs`
/// is refused at set time, synchronously, by the lever being pulled — which
/// during a 30-minute soak means the storm aborting the run it was generated
/// to test. So the conflict is resolved during generation, deterministically
/// and inside the pure function: an arming draw emits explicit clears for every
/// incumbent it excludes, at the same offset, immediately before itself.
library;

import 'dart:async';
import 'dart:math';

import 'fault_proxy.dart';

/// One thing the storm does, and when.
///
/// Value equality and a [toString] that reads as a log line, because the list
/// of these is the artifact a failing soak prints and a human pastes back.
final class ScheduledFault {
  const ScheduledFault(this.offset, this.mutation);

  /// How far into the run this happens, measured from playback start.
  final Duration offset;

  /// What happens.
  final FaultMutation mutation;

  @override
  bool operator ==(Object other) =>
      other is ScheduledFault &&
      other.offset == offset &&
      other.mutation == mutation;

  @override
  int get hashCode => Object.hash(offset, mutation);

  @override
  String toString() => '[${_stamp(offset)}] $mutation';
}

/// One lever pull, as data.
///
/// One final class per lever on [FaultProxy], with the lever's own signature —
/// nullable where the lever is nullable, `enabled` where the lever has an
/// `enabled`. The correspondence is deliberate: [ScenarioPlayback.apply] is
/// then a one-to-one map rather than a translation layer with its own
/// opinions, and a reader comparing this file to `fault_proxy.dart` can check
/// it by eye.
sealed class FaultMutation {
  const FaultMutation();

  /// Which entry in [faultModes] this mutation drives.
  ///
  /// The generator and the composition sweep both key off this rather than off
  /// the runtime type, so the exclusion table — which is written in mode names
  /// — can be applied without a second mapping that could drift from this one.
  String get mode;

  /// Whether applying this switches the mode **on**.
  ///
  /// Mirrors `FaultProxy._isActive` for the same mode: jitter alone arms
  /// `latency`, a null byte count disarms `cutMidFrame`, and `killOnce` is
  /// always an arming pull because there is no lever that turns it off.
  bool get arms;
}

/// The cycle lever: down for [down], up for [up], repeating.
final class FlapMutation extends FaultMutation {
  const FlapMutation({required this.up, required this.down})
      : enabled = true;

  const FlapMutation.off()
      : up = _offHalf,
        down = _offHalf,
        enabled = false;

  final Duration up;
  final Duration down;
  final bool enabled;

  /// What the off form carries in its halves.
  ///
  /// `flap` validates its halves only on the way on, so the off form's numbers
  /// are never read. They are still positive rather than zero: a future
  /// refactor that moved the validation ahead of the `enabled` check would
  /// otherwise turn every clear in every generated storm into an
  /// `ArgumentError`, and the failure would name the flap lever rather than
  /// the change that caused it.
  static const _offHalf = Duration(seconds: 1);

  @override
  String get mode => 'flap';

  @override
  bool get arms => enabled;

  @override
  bool operator ==(Object other) =>
      other is FlapMutation &&
      other.enabled == enabled &&
      (!enabled || (other.up == up && other.down == down));

  @override
  int get hashCode => enabled ? Object.hash(up, down) : 0x1a9;

  @override
  String toString() => enabled
      ? 'flap up ${_ms(up)} down ${_ms(down)}'
      : 'flap off';
}

/// The one-way delay lever, with its jitter dial.
///
/// Both dials in one mutation because they are one mode: `jitter` has no entry
/// in [faultModes] and `FaultProxy._isActive` reports `latency` active when
/// either is set. Splitting them here would let a storm clear the delay and
/// leave the mode armed by a jitter nobody is tracking.
final class LatencyMutation extends FaultMutation {
  const LatencyMutation({this.latency, this.jitter});

  const LatencyMutation.off()
      : latency = null,
        jitter = null;

  final Duration? latency;
  final Duration? jitter;

  @override
  String get mode => 'latency';

  @override
  bool get arms => latency != null || jitter != null;

  @override
  bool operator ==(Object other) =>
      other is LatencyMutation &&
      other.latency == latency &&
      other.jitter == jitter;

  @override
  int get hashCode => Object.hash(latency, jitter);

  @override
  String toString() {
    final base = latency;
    if (base == null && jitter == null) return 'latency off';
    final spread = jitter;
    return 'latency ${base == null ? '0ms' : _ms(base)}'
        '${spread == null ? '' : ' ±${_ms(spread)}'}';
  }
}

/// The rate lever, per direction. Null is unmetered.
final class ThrottleMutation extends FaultMutation {
  const ThrottleMutation(this.bytesPerSecond);

  const ThrottleMutation.off() : bytesPerSecond = null;

  final int? bytesPerSecond;

  @override
  String get mode => 'throttle';

  @override
  bool get arms => bytesPerSecond != null;

  @override
  bool operator ==(Object other) =>
      other is ThrottleMutation && other.bytesPerSecond == bytesPerSecond;

  @override
  int get hashCode => bytesPerSecond.hashCode;

  @override
  String toString() {
    final rate = bytesPerSecond;
    return rate == null ? 'throttle off' : 'throttle $rate B/s';
  }
}

/// The half-open lever: sockets up, traffic gone.
final class BlackholeMutation extends FaultMutation {
  const BlackholeMutation({this.enabled = true});

  final bool enabled;

  @override
  String get mode => 'blackhole';

  @override
  bool get arms => enabled;

  @override
  bool operator ==(Object other) =>
      other is BlackholeMutation && other.enabled == enabled;

  @override
  int get hashCode => enabled ? 0x2b1 : 0x2b2;

  @override
  String toString() => enabled ? 'blackhole on' : 'blackhole off';
}

/// The truncation lever: deliver n server→client bytes, then FIN.
final class CutMidFrameMutation extends FaultMutation {
  const CutMidFrameMutation(this.afterBytes);

  const CutMidFrameMutation.off() : afterBytes = null;

  final int? afterBytes;

  @override
  String get mode => 'cutMidFrame';

  @override
  bool get arms => afterBytes != null;

  @override
  bool operator ==(Object other) =>
      other is CutMidFrameMutation && other.afterBytes == afterBytes;

  @override
  int get hashCode => afterBytes.hashCode;

  @override
  String toString() {
    final n = afterBytes;
    return n == null ? 'cutMidFrame off' : 'cutMidFrame after $n B';
  }
}

/// The one-shot reset lever.
///
/// No off form, because the proxy has no lever that disarms it — see
/// [ScenarioSchedule.generate] for what the generator does about that.
final class KillOnceMutation extends FaultMutation {
  const KillOnceMutation();

  @override
  String get mode => 'killOnce';

  @override
  bool get arms => true;

  @override
  bool operator ==(Object other) => other is KillOnceMutation;

  @override
  int get hashCode => 0x3c7;

  @override
  String toString() => 'killOnce';
}

/// The refusal lever: destroy what is open, cut what arrives.
final class RejectMutation extends FaultMutation {
  const RejectMutation({this.enabled = true});

  final bool enabled;

  @override
  String get mode => 'reject';

  @override
  bool get arms => enabled;

  @override
  bool operator ==(Object other) =>
      other is RejectMutation && other.enabled == enabled;

  @override
  int get hashCode => enabled ? 0x4d1 : 0x4d2;

  @override
  String toString() => enabled ? 'reject on' : 'reject off';
}

/// The store-and-forward lever: hold server→client, keep client→server.
final class BufferServerToClientMutation extends FaultMutation {
  const BufferServerToClientMutation({this.enabled = true});

  final bool enabled;

  @override
  String get mode => 'bufferServerToClient';

  @override
  bool get arms => enabled;

  @override
  bool operator ==(Object other) =>
      other is BufferServerToClientMutation && other.enabled == enabled;

  @override
  int get hashCode => enabled ? 0x5e3 : 0x5e4;

  @override
  String toString() =>
      enabled ? 'bufferServerToClient on' : 'bufferServerToClient off';
}

/// How often each mode is drawn, relative to the others.
///
/// A map keyed by the names in [faultModes], plus [ScenarioSchedule.cleanMode].
/// Keyed by name and not by type so the keys can be checked against the mode
/// registry: a misspelling is an `ArgumentError` naming the unknown key, where
/// a typed builder would silently have weighted nothing and produced a storm
/// that never pulls the lever its author asked for.
final class ScenarioWeights {
  const ScenarioWeights(this.byMode);

  /// The five §7.8 names, equally weighted.
  ///
  /// The default, because it is the specified soak profile. None of these five
  /// exclude each other, so a default storm never needs the conflict
  /// resolution below — which is exactly why [everything] exists and why the
  /// sweep in `schedule_test.dart` uses it: a safety rule only exercised by
  /// the profile nobody runs is a safety rule nobody has tested.
  static const soak = ScenarioWeights(<String, int>{
    'flap': 1,
    'latency': 1,
    'throttle': 1,
    'blackhole': 1,
    ScenarioSchedule.cleanMode: 1,
  });

  /// Every declared mode, plus clean at three times the weight.
  ///
  /// Clean is weighted up because this profile includes `reject`, which
  /// excludes all seven others: without a bias toward clearing, a storm that
  /// armed it would spend the rest of the run clearing it again on every
  /// arming draw.
  static const everything = ScenarioWeights(<String, int>{
    'flap': 1,
    'latency': 1,
    'throttle': 1,
    'blackhole': 1,
    'cutMidFrame': 1,
    'killOnce': 1,
    'reject': 1,
    'bufferServerToClient': 1,
    ScenarioSchedule.cleanMode: 3,
  });

  /// The weight of each drawable name. Zero-weight entries are never drawn.
  final Map<String, int> byMode;

  /// The sum of every weight — the range a draw is taken from.
  int get total => byMode.values.fold(0, (sum, weight) => sum + weight);

  /// Throws unless every key names a mode and the weights can be drawn from.
  ///
  /// Called by [ScenarioSchedule.generate] before anything is generated, so a
  /// bad profile fails at the call that supplied it rather than 300 entries
  /// later.
  void validate() {
    for (final entry in byMode.entries) {
      if (entry.key != ScenarioSchedule.cleanMode &&
          !faultModes.contains(entry.key)) {
        throw ArgumentError.value(
            entry.key,
            'byMode',
            'not a fault mode; the drawable names are '
                '${faultModes.join(', ')} and '
                '"${ScenarioSchedule.cleanMode}". A key that names no mode '
                'weights nothing, so the storm would quietly never pull that '
                'lever');
      }
      if (entry.value < 0) {
        throw ArgumentError.value(entry.value, 'byMode[${entry.key}]',
            'a weight is a share of the draws, so it cannot be negative');
      }
    }
    if (total <= 0) {
      throw ArgumentError.value(byMode, 'byMode',
          'every weight is zero, so there is nothing to draw and the storm '
              'would be a list of no events wearing a duration');
    }
  }

  /// Draws one name, consuming exactly one number from [random].
  ///
  /// Exactly one, unconditionally: a draw that sometimes consumed two would
  /// make the stream depend on the outcome of earlier draws in a way that is
  /// still deterministic but impossible to reason about when a profile changes.
  String _draw(Random random) {
    var ticket = random.nextInt(total);
    for (final entry in byMode.entries) {
      ticket -= entry.value;
      if (ticket < 0) return entry.key;
    }
    // Unreachable while `total` is the sum of the same values, and cheaper to
    // state than to leave to a fall-through returning the last key by accident.
    throw StateError('weight draw fell off the end of ${byMode.keys.join(', ')}');
  }
}

/// The pure generator: `(seed, duration, weights)` → an immutable timeline.
abstract final class ScenarioSchedule {
  /// The drawable name that means "clear everything currently armed".
  ///
  /// §7.8 lists it beside the four modes, and it is not one: it has no lever,
  /// no entry in [faultModes] and no test file of its own. It expands during
  /// generation into an explicit clear per armed mode, so the log says which
  /// levers went off rather than leaving a reader to reconstruct it.
  static const cleanMode = 'clean';

  /// Generates the whole storm. No clock, no I/O, no ambient state.
  ///
  /// Cadence is a uniform draw from `[minGap, maxGap]` — §7.8's 1–10 s by
  /// default. Entries stop before [duration]; a storm that armed a mode on its
  /// last microsecond would leave the soak's final assertions running against
  /// a fault nobody scheduled time to observe.
  ///
  /// **Conflict resolution, and why it is in here.** An arming draw whose mode
  /// excludes something already armed emits clears for those incumbents at the
  /// same offset, in the order they were armed, immediately before itself. The
  /// resolution is part of the pure function, so the same seed still gives the
  /// same list.
  ///
  /// **`killOnce` is the exception, and it is conservative on purpose.** It is
  /// the one mode with no off lever: `FaultProxy` disarms it when a connection
  /// arrives to be reset, and generation cannot know whether one will. So once
  /// a storm has drawn it, the generator treats it as armed for the rest of
  /// the run and skips any later draw of `cutMidFrame` or `reject` — the two
  /// modes that exclude it. The cost is a bias away from two modes in the tail
  /// of a storm that drew `killOnce`; the alternative is a `StateError` from a
  /// lever mid-soak, which ends the run instead of testing it. `clean` cannot
  /// clear it either, for the same reason, and does not pretend to.
  static List<ScheduledFault> generate({
    required int seed,
    required Duration duration,
    ScenarioWeights weights = ScenarioWeights.soak,
    Duration minGap = const Duration(seconds: 1),
    Duration maxGap = const Duration(seconds: 10),
  }) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration',
          'a storm needs a positive duration; zero generates no events and '
              'would pass every invariant a soak checks');
    }
    if (minGap <= Duration.zero) {
      throw ArgumentError.value(
          minGap,
          'minGap',
          'a zero gap is not a fast storm — it is an unbounded number of '
              'entries at offset zero, all applied in one turn of the event '
              'loop');
    }
    if (maxGap < minGap) {
      throw ArgumentError.value(
          maxGap, 'maxGap', 'the gap band is empty: minGap is $minGap');
    }
    weights.validate();

    final random = SeededScenarioRandom(seed);
    final timeline = <ScheduledFault>[];
    // Insertion-ordered, and the order is load-bearing: it decides which
    // incumbent is cleared first when one draw conflicts with several, and a
    // hash-ordered set would make that depend on the hash of a string.
    final armed = <String>{};
    final spread = (maxGap - minGap).inMicroseconds;
    var offset = Duration.zero;

    while (true) {
      offset += minGap +
          Duration(microseconds: spread == 0 ? 0 : random.nextInt(spread + 1));
      if (offset >= duration) break;

      final drawn = weights._draw(random);

      if (drawn == cleanMode) {
        for (final mode in armed.toList()) {
          final clear = _clearFor(mode);
          if (clear == null) continue;
          timeline.add(ScheduledFault(offset, clear));
          armed.remove(mode);
        }
        continue;
      }

      // Already armed, and clearable: the draw toggles it off. That is what
      // gives a storm its churn — without it, a mode drawn twice would be set
      // twice with different parameters and never go away.
      if (armed.contains(drawn)) {
        final clear = _clearFor(drawn);
        if (clear != null) {
          timeline.add(ScheduledFault(offset, clear));
          armed.remove(drawn);
          continue;
        }
      }

      final clears = <FaultMutation>[];
      var blocked = false;
      for (final incumbent in armed.toList()) {
        if (!_excludes(drawn, incumbent)) continue;
        final clear = _clearFor(incumbent);
        if (clear == null) {
          blocked = true;
          break;
        }
        clears.add(clear);
      }
      if (blocked) continue;

      for (final clear in clears) {
        timeline.add(ScheduledFault(offset, clear));
        armed.remove(clear.mode);
      }
      timeline.add(ScheduledFault(offset, _armFor(drawn, random)));
      armed.add(drawn);
    }

    return List.unmodifiable(timeline);
  }

  /// The `(seed, schedule log)` pair notes §7.8 reproduces a failure from.
  ///
  /// Everything needed to regenerate the run is in the header, so a log pasted
  /// into an issue is self-contained: a reader does not have to know which
  /// weights or which cadence the failing soak used.
  static String reproLog({
    required int seed,
    required List<ScheduledFault> timeline,
    Duration? duration,
    ScenarioWeights? weights,
  }) {
    final header = StringBuffer('scenario seed=$seed entries=${timeline.length}');
    if (duration != null) header.write(' duration=$duration');
    if (weights != null) {
      final profile = weights.byMode.entries
          .map((entry) => '${entry.key}:${entry.value}')
          .join(',');
      header.write(' weights=$profile');
    }
    return <String>[
      header.toString(),
      for (final entry in timeline) entry.toString(),
    ].join('\n');
  }

  /// Whether arming [mode] while [other] is armed is refused by the proxy.
  ///
  /// Reads [exclusiveModePairs] rather than restating it. A second copy of the
  /// rule here would agree with the proxy right up until somebody edited one
  /// of them, and the disagreement would surface as a `StateError` twenty
  /// minutes into a soak.
  static bool _excludes(String mode, String other) {
    for (final conflict in exclusiveModePairs) {
      if (conflict.a == mode && conflict.b == other) return true;
      if (conflict.b == mode && conflict.a == other) return true;
    }
    return false;
  }

  /// The mutation that switches [mode] off, or null if the proxy has no lever
  /// that does.
  static FaultMutation? _clearFor(String mode) => switch (mode) {
        'flap' => const FlapMutation.off(),
        'latency' => const LatencyMutation.off(),
        'throttle' => const ThrottleMutation.off(),
        'blackhole' => const BlackholeMutation(enabled: false),
        'cutMidFrame' => const CutMidFrameMutation.off(),
        'reject' => const RejectMutation(enabled: false),
        'bufferServerToClient' =>
          const BufferServerToClientMutation(enabled: false),
        // The one mode with no off lever. Null rather than a no-op mutation,
        // so callers have to decide what to do about it instead of emitting a
        // clear that clears nothing and a log line that lies.
        'killOnce' => null,
        _ => throw StateError('no clear mutation for mode "$mode"; it is '
            'drawable, so a storm can arm it and then never let go'),
      };

  /// The mutation that switches [mode] on, with parameters drawn from [random].
  ///
  /// The bands are the ones the mode tests in this directory already use, kept
  /// small enough that a 1–10 s cadence gets to observe the effect before the
  /// next draw changes it.
  static FaultMutation _armFor(String mode, Random random) => switch (mode) {
        'flap' => FlapMutation(
            up: _millis(random, 200, 1500),
            down: _millis(random, 200, 1500),
          ),
        'latency' => LatencyMutation(
            latency: _millis(random, 10, 500),
            jitter: _millis(random, 0, 50),
          ),
        // 4 KiB/s to 256 KiB/s: slow enough to be visible over a window,
        // fast enough that a client is not simply dead.
        'throttle' => ThrottleMutation(4096 + random.nextInt(258048)),
        'blackhole' => const BlackholeMutation(),
        'cutMidFrame' => CutMidFrameMutation(1 + random.nextInt(4096)),
        'killOnce' => const KillOnceMutation(),
        'reject' => const RejectMutation(),
        'bufferServerToClient' => const BufferServerToClientMutation(),
        _ => throw StateError('no arm mutation for mode "$mode"'),
      };

  static Duration _millis(Random random, int low, int high) =>
      Duration(milliseconds: low + random.nextInt(high - low + 1));
}

/// A `Random` whose stream this file owns, so a seed keeps its meaning.
///
/// `dart:math`'s seeded `Random` documents that its stream may change between
/// SDK releases. That is fine for jitter and wrong for a repro log: Phase 11
/// reproduces a soak failure from `(seed, schedule log)` weeks after the run,
/// on a machine that has been updated since, and a generator whose stream
/// moved under a Dart upgrade would produce a *different* storm from the same
/// seed while still looking deterministic in every same-session test.
///
/// splitmix64 for seeding, xorshift64* for the stream — twenty lines, no
/// dependency, and pinned by this source file. Any change to the constants
/// below invalidates every schedule log ever printed, which is why they are
/// written out rather than derived.
///
/// VM only, like the rest of the fault kit (`faults.dart` reaches for
/// `dart:io`): the arithmetic below relies on 64-bit wrapping integers.
final class SeededScenarioRandom implements Random {
  SeededScenarioRandom(int seed) : _state = _mix(seed == 0 ? _golden : seed);

  /// The odd 64-bit constant splitmix64 is specified with.
  static const _golden = 0x9E3779B97F4A7C15;

  int _state;

  /// splitmix64's finalizer, used once to spread a small seed over 64 bits.
  ///
  /// Without it, `SeededScenarioRandom(1)` and `SeededScenarioRandom(2)` start
  /// one bit apart and xorshift takes several draws to diverge — so the first
  /// few entries of neighbouring seeds' storms would look alike, which is the
  /// one property the different-seeds test exists to deny.
  static int _mix(int seed) {
    var z = seed + _golden;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// xorshift64*, one 64-bit step.
  int _next() {
    var x = _state;
    x ^= x >>> 12;
    x ^= x << 25;
    x ^= x >>> 27;
    _state = x;
    return x * 0x2545F4914F6CDD1D;
  }

  /// The top 53 bits of a step, which is every bit a Dart double can hold.
  int _bits53() => _next() >>> 11;

  @override
  int nextInt(int max) {
    if (max <= 0 || max > 0xFFFFFFFF) {
      throw RangeError.range(max, 1, 0xFFFFFFFF, 'max');
    }
    // Modulo, with the bias that implies. At 53 bits of input the bias for the
    // ranges this file draws is on the order of 2^-30 of a draw, and the
    // alternative — rejection sampling — makes the number of steps consumed
    // depend on the values drawn, which is a worse property for a stream whose
    // whole job is to be replayable.
    return _bits53() % max;
  }

  @override
  double nextDouble() => _bits53() / 9007199254740992.0;

  @override
  bool nextBool() => (_next() & 1) != 0;
}

/// Applies a generated timeline to a live proxy, and records what it applied.
///
/// **The only timed thing in this file.** CONTEXT restricts injected clocks to
/// pure state machines, and this driver is deliberately not one: it pulls real
/// levers on real sockets with real timers. The part that needed determinism —
/// which fault, and when — was moved out of the timed path rather than faked
/// inside it, which is the whole argument of the library doc above.
///
/// **One chained timer, not one timer per entry.** Each step schedules the
/// next from the elapsed time of a single [Stopwatch], so a mutation that
/// takes a moment to apply — `reject` awaits its own teardown — does not push
/// every later offset out by that much. It also makes [stop] exactly true:
/// there is only ever one pending timer to cancel, so "no timer fires after
/// stop" is a property of the shape rather than a bookkeeping claim (T-02-37).
final class ScenarioPlayback {
  ScenarioPlayback({
    required this.proxy,
    required this.timeline,
    required this.seed,
  });

  final FaultProxy proxy;

  /// The generated storm, in offset order.
  final List<ScheduledFault> timeline;

  /// The seed that generated [timeline], carried so failures can print it.
  final int seed;

  final List<ScheduledFault> _applied = <ScheduledFault>[];
  final Stopwatch _clock = Stopwatch();
  Completer<void>? _finished;
  Timer? _pending;
  int _index = 0;
  bool _stopped = false;

  /// What has actually been applied, in the order it was applied.
  ///
  /// Compared against [timeline] by the tests: a divergence between what was
  /// planned and what happened is the failure mode a soak cannot otherwise
  /// see, because both halves look fine on their own.
  List<ScheduledFault> get applied => List.unmodifiable(_applied);

  /// Whether the driver is between [run] and its completion.
  bool get isRunning => _finished != null && !_finished!.isCompleted;

  /// Plays the whole timeline. Completes when it ends or when [stop] is called.
  ///
  /// Completes with a [ScenarioPlaybackFailure] if a lever throws — which,
  /// given the generator's conflict resolution, means the exclusion table and
  /// the generator have drifted apart. The failure carries the repro log,
  /// because that is the moment somebody needs it.
  ///
  /// Refuses to run a playback that has been [stop]ped, in the shape
  /// `FaultProxy.start()` uses for the same situation. A stopped driver
  /// schedules nothing — `_schedule` returns on the first line — so a fresh
  /// completer would be one nothing ever completes, and the caller would hang
  /// until package:test's own timeout named the test file rather than the
  /// playback. An unconditional `addTearDown(playback.stop)` registered at
  /// construction time makes stop-before-run easy to arrive at by accident,
  /// which is exactly when a hang is hardest to attribute.
  Future<void> run() {
    if (_stopped) {
      throw StateError('this playback has been stopped; build a new one '
          'rather than restarting it — a stopped driver schedules nothing, so '
          'run() would return a future that never completes and the failure '
          'would name the test file instead of this object');
    }
    final existing = _finished;
    if (existing != null) return existing.future;
    final finished = _finished = Completer<void>();
    _clock.start();
    _schedule();
    return finished.future;
  }

  /// Stops the storm and cancels the pending timer. Idempotent.
  ///
  /// Does **not** undo what has been applied: a caller that wants a clean link
  /// afterwards clears the modes itself, or shuts the proxy down. Unwinding
  /// here would mean this driver deciding the order of eight lever pulls
  /// nobody scheduled, on a proxy a test may already be asserting against.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _pending?.cancel();
    _pending = null;
    _clock.stop();
    final finished = _finished;
    if (finished != null && !finished.isCompleted) finished.complete();
  }

  /// The `(seed, schedule log)` artifact for this run.
  String get reproLog =>
      ScenarioSchedule.reproLog(seed: seed, timeline: timeline);

  /// The same, plus what was actually applied — for a divergence.
  String get divergenceReport => '$reproLog\n'
      '--- applied ${_applied.length} of ${timeline.length} ---\n'
      '${_applied.join('\n')}';

  void _schedule() {
    if (_stopped) return;
    if (_index >= timeline.length) {
      final finished = _finished;
      _clock.stop();
      if (finished != null && !finished.isCompleted) finished.complete();
      return;
    }
    final due = timeline[_index].offset - _clock.elapsed;
    _pending = Timer(due < Duration.zero ? Duration.zero : due, _fire);
  }

  Future<void> _fire() async {
    _pending = null;
    if (_stopped) return;
    final entry = timeline[_index];
    try {
      await apply(proxy, entry.mutation);
    } catch (error, stack) {
      final finished = _finished;
      _stopped = true;
      _clock.stop();
      if (finished != null && !finished.isCompleted) {
        finished.completeError(
            ScenarioPlaybackFailure(entry, error, divergenceReport), stack);
      }
      return;
    }
    // Checked again after the await: `stop()` may have run while a lever that
    // awaits its own teardown was in flight, and appending here would leave an
    // applied log with an entry after the stop that ended the run.
    if (_stopped) return;
    _applied.add(entry);
    _index++;
    _schedule();
  }

  /// Pulls the lever [mutation] names on [proxy].
  ///
  /// An exhaustive switch over the sealed [FaultMutation], which is the point
  /// of it being sealed: a ninth lever added to `fault_proxy.dart` with a
  /// mutation beside it and no arm here fails `dart analyze` at this switch,
  /// rather than becoming a storm entry that logs itself and does nothing.
  ///
  /// `reject` is the only arm that returns a future worth awaiting — it tears
  /// down live pairs — and the whole method is `Future`-returning so the
  /// chained timer can wait for it before timing the next offset.
  static Future<void> apply(FaultProxy proxy, FaultMutation mutation) {
    switch (mutation) {
      case FlapMutation(:final up, :final down, :final enabled):
        proxy.flap(up, down, enabled: enabled);
      case LatencyMutation(:final latency, :final jitter):
        // Latency before jitter, and both always: jitter is the same mode's
        // second dial, so setting one and leaving the other would arm the mode
        // with a value from the previous mutation still in place.
        proxy.latency = latency;
        proxy.jitter = jitter;
      case ThrottleMutation(:final bytesPerSecond):
        proxy.throttleBytesPerSec = bytesPerSecond;
      case BlackholeMutation(:final enabled):
        proxy.blackhole(enabled: enabled);
      case CutMidFrameMutation(:final afterBytes):
        proxy.cutMidFrame(afterBytes);
      case KillOnceMutation():
        proxy.killOnce();
      case RejectMutation(:final enabled):
        // Returned rather than awaited in the arm, for the reason
        // `FaultProxy.reject` is not an `async` function: its composition check
        // is a synchronous throw, and it must stay one all the way out to
        // `_fire`'s try block.
        return proxy.reject(enabled: enabled);
      case BufferServerToClientMutation(:final enabled):
        proxy.bufferServerToClient = enabled;
    }
    return Future<void>.value();
  }
}

/// A lever threw during playback, with everything needed to reproduce it.
final class ScenarioPlaybackFailure implements Exception {
  const ScenarioPlaybackFailure(this.entry, this.cause, this.report);

  /// The entry whose lever threw.
  final ScheduledFault entry;

  /// What the lever threw.
  final Object cause;

  /// The repro log, plus what had been applied before the throw.
  final String report;

  @override
  String toString() => 'the storm could not be played: applying $entry threw '
      '$cause.\nThe generator resolves the exclusion table before emitting, so '
      'this means the table and the generator have drifted apart — or the '
      'proxy was in a state the storm did not put it in.\n$report';
}

/// `mm:ss.mmm`, so a log column lines up and a reader can scan offsets.
String _stamp(Duration offset) {
  final minutes = offset.inMinutes.toString().padLeft(2, '0');
  final seconds = (offset.inSeconds % 60).toString().padLeft(2, '0');
  final millis = (offset.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$minutes:$seconds.$millis';
}

String _ms(Duration value) => '${value.inMilliseconds}ms';
