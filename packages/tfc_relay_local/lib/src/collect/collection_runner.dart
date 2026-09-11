/// The value path → sink driver: one subscription per collected key, the
/// quality gate, the sample timers, retention registration, and the numbers
/// behind the six `PIPE.collect.*` keys.
///
/// ## The quality gate is this file's substantive decision
///
/// Only a **good-band** value (`band == 0`) is written. The app's collector
/// historises whatever arrives because open62541's `DynamicValue` has no
/// quality field to consult (08-RESEARCH §A.2); the gateway's values carry
/// [DynamicValue.quality] for real, so for the first time the historian can
/// decline.
///
/// **Uncertain is excluded on purpose, and the reason is
/// [Quality.uncertainLastKnown] itself**: "the last known value" is by
/// definition a value the field is no longer confirming, and inserting it at
/// `now()` manufactures a reading that never happened. A frozen value written
/// every five seconds through an upstream outage is a flat, plausible trend
/// that somebody later reads as "the line was running steady" — precisely the
/// class of lie this project exists to prevent. A gap in a trend is honest
/// and legible; a flat line is neither.
///
/// The counter is what keeps this from being a silent loss: every declined
/// sample increments the number behind [PipeKeys.collectRowsDropped], so an
/// operator asking "why is there no data between 14:02 and 14:20" gets the
/// answer from that key plus the upstream keys that were bad at the time.
/// (The originally-drafted separate skipped-quality key does not exist and
/// must not be minted: 8b-01 shipped six keys, the roster and its lane
/// partition are pinned by the protocol suite, and the dropped counter's own
/// seam doc already reads "dropped, skipped or refused".)
///
/// What this gate cannot do: the app's collector, writing the same tags with
/// no quality field, will keep filling those gaps until cutover — which is
/// exactly why the two write into disjoint `tablePrefix` namespaces until
/// then (`collection_config.dart`'s four-fact argument).
///
/// ## The pipeline order is the shipped collector's
///
/// Member extraction happens **before** anything else splits on mode, so the
/// insert path and any future real-time consumer agree on what a sample *is*
/// (`collector.dart:218-221`). Then the quality gate, then the interval
/// decision, then the insert.
///
/// ## Collection is a subscriber like any other
///
/// One [StateManApi.subscribe] per entry — the ordinary value path, no
/// private hook. That makes every collected key a permanent subscriber in
/// 08-05's refcount: a panel leaving a collected key does not release the
/// upstream subscription underneath it, deliberately and asserted
/// (T-8b-13, accepted). The replayed snapshot a subscription yields first is
/// **not a row** in change-driven mode: it is the cache replaying, not news
/// from the plant, and inserting it would stamp an old reading with a fresh
/// `now()` (T-8b-11).
///
/// ## One entry's failure costs one entry
///
/// `collector.dart:159-172` is the incident this repeats-by-not-repeating: a
/// discarded future rejecting inside the acquisition isolate killed
/// collection for the whole server and sent the supervisor into a respawn
/// loop, with a still-templated `$variable` key as the easy trigger. Here
/// every entry start is guarded, every fire-and-forget future carries a
/// handler on the same line (freeze 8 counts them), and a failure is
/// recorded against its key in [entryFailures].
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../pipe_health.dart';
import '../value_shaping.dart';
import 'collection_plan.dart';
import 'sample_gate.dart';
import 'timeseries_sink.dart';

/// How many milliseconds of whole missed sampling windows turn an interval
/// tick into a declined wake-up tick (09-09, F22e).
///
/// The number separates two populations that do not overlap: scheduler and
/// GC pauses on a loaded runner are tens of milliseconds, while the stalls
/// this guard exists for — a Veeam/VMware snapshot freezing the whole
/// process, an `Isolate.pause` in the gate lane — run seconds to tens of
/// seconds. A quarter second of plant nobody sampled is beyond any pause the
/// historian should write through, and hours below any freeze worth a gap.
/// Note the arithmetic is over MISSED windows (`(tickDelta - 1) * interval`),
/// so at production-scale sample intervals (>= 250 ms) a single missed
/// window already trips it, while the 25 ms ticks the unit suite runs need
/// ten — which is what keeps ordinary jitter from counting phantom drops.
const int _stallDeclineFloorMs = 250;

/// Drives [CollectionPlan.entries] from the value path into the sink.
final class CollectionRunner {
  CollectionRunner({
    required this.plan,
    required StateManApi stateMan,
    required TimeseriesSink sink,
    required CollectHealth health,
    DateTime Function()? now,
  })  : _stateMan = stateMan,
        _sink = sink,
        _health = health,
        _now = now ?? DateTime.now;

  /// What to collect — decided and validated by 8b-01, never re-derived
  /// here. In particular [CollectionEntry.table] is the only spelling of
  /// each table name this class ever uses.
  final CollectionPlan plan;

  final StateManApi _stateMan;
  final TimeseriesSink _sink;
  final CollectHealth _health;

  /// Row timestamps. A wall clock and correctly so — a row's time is a fact
  /// shared with every other writer and reader of the database, unlike the
  /// ages and deadlines elsewhere in this package, which stay monotonic.
  final DateTime Function() _now;

  final Map<String, StreamSubscription<DynamicValue>> _subscriptions =
      <String, StreamSubscription<DynamicValue>>{};

  /// The per-entry sample timers, by key. The allow-list entry for this
  /// file (`freeze_test.dart`) carries the justification for their
  /// existence; the map is what makes each one reachable, cancellable, and
  /// replaceable by a re-collect without orphaning its predecessor.
  final Map<String, Timer> _sampleTimers = <String, Timer>{};

  /// The per-entry sampling conditions, by key (task 2). A gate holds its
  /// own variable subscriptions, so it is torn down with the entry it
  /// gates and with [stop].
  final Map<String, SampleGate> _gates = <String, SampleGate>{};

  final Map<String, String> _entryFailures = <String, String>{};

  StreamSubscription<bool>? _connectionSub;

  int _skipped = 0;
  bool _started = false;
  bool _stopped = false;

  /// Entries that could not start or whose stream errored, by key. One key's
  /// failure is recorded here and costs nothing else.
  Map<String, String> get entryFailures =>
      Map<String, String>.unmodifiable(_entryFailures);

  /// Samples this runner declined to hand to the sink: quality-gate
  /// refusals and samples where no configured member resolved. Added to the
  /// sink's own drop count for [PipeKeys.collectRowsDropped].
  int get skippedSamples => _skipped;

  /// Sample timers running right now.
  int get liveSampleTimers => _sampleTimers.length;

  /// Value-path subscriptions held right now.
  int get liveSubscriptions => _subscriptions.length;

  /// Starts every entry, isolating failures per key, and begins publishing
  /// the six health keys.
  Future<void> start() async {
    if (_started || _stopped) return;
    _started = true;
    _health.markEnabled();
    _connectionSub = _sink.connected.listen(
      (up) {
        _health.noteConnected(up);
        _refreshHealth();
      },
      // A sink whose connection stream errors is a degraded sink, not a
      // dead runner; its own lastError already carries the story.
      onError: (Object _) {},
    );
    for (final entry in plan.entries) {
      try {
        await collectEntry(entry);
      } catch (error) {
        // One unstartable key costs exactly that key (collector.dart:159-172
        // is what happens otherwise). Recorded, never rethrown.
        _entryFailures[entry.key] =
            'could not start collection for this key (this key only): $error';
      }
    }
  }

  /// Starts — or restarts, after a mapping edit — collection for one entry.
  ///
  /// Safe to call again for a key already collecting: the previous
  /// subscription is cancelled here and the previous sample timer by the
  /// guard below, so a re-collect never leaves the first timer inserting
  /// alongside its replacement (`collector.dart:294-298`'s lesson).
  Future<void> collectEntry(CollectionEntry entry) async {
    if (_stopped) return;
    await _subscriptions.remove(entry.key)?.cancel();
    await _gates.remove(entry.key)?.stop();
    // The cancel-the-previous guard, BEFORE the mode split — regardless of
    // the NEW entry's mode (CR-02). Inside `if (interval != null)` it only
    // ever ran on interval→interval re-collects: an edit that REMOVED the
    // interval orphaned the old timer with a frozen `latest` and a stopped
    // gate, inserting that frozen band-0 value at a fresh now() every tick
    // until stop() — the flat-line lie the class doc promises this method
    // prevents (collector.dart:294-298's lesson, completed).
    _sampleTimers.remove(entry.key)?.cancel();
    // Re-read after every await (WR-04, 08-REVIEW's connect() shape): a
    // stop() that lands while this call is suspended runs the whole
    // teardown, and the resumed call must not rebuild a subscription and a
    // timer into cleared maps — a live timer owned by a runner that reports
    // itself stopped, inserting into a sink about to close.
    if (_stopped) return;

    // Retention is registered once per table, before the first insert can
    // create the table untyped. An entry 8b-01 marked `adjusted` carries a
    // null retention, which the seam contract reads as "install no policy"
    // — the table keeps everything rather than fighting over an unusable
    // policy at every start.
    await _sink.ensureTable(entry.table, entry.retention);
    if (_stopped) return;
    // Everything below is synchronous until this method returns — the gate
    // build, the subscribe and the timer creation cannot interleave with a
    // stop(), so these two re-checks are the complete set.

    final interval = entry.sampleInterval;
    final members = entry.sampleMembers;

    // The first event a subscription yields is the store's cached snapshot
    // replaying — not an arrival. In change mode it is never a row; in
    // interval mode it may be held (a warm cache is a legitimate current
    // value for a trend) but a skip it causes is not a counted loss,
    // because nothing arrived to lose.
    var awaitingReplay = true;
    var heldIsArrival = false;
    DynamicValue? latest;

    // The gate is built and started BEFORE the value subscription, so a
    // rejected expression — the parse failure or the templated $variable —
    // leaves nothing of this entry running. Its variables ride the ordinary
    // subscribe path too.
    SampleGate? gate;
    final expression = entry.sampleExpression;
    if (expression != null) {
      final built = SampleGate(
        expression: expression,
        stateMan: _stateMan,
        onTransition: (open) {
          // The gate going true samples the value the entry is holding —
          // the app's gated collector does the same (its gate stream
          // `take(1)`s the data stream, whose first event is the replayed
          // current value). The quality gate still applies: an untrusted
          // held value stays a gap.
          if (!open || interval != null) return;
          final held = latest;
          if (held == null || held.quality.band != 0) return;
          _insert(entry, held);
        },
      );
      built.start();
      _gates[entry.key] = built;
      gate = built;
    }

    final subscription = _stateMan.subscribe(entry.key).listen(
      (value) {
        final isReplay = awaitingReplay;
        awaitingReplay = false;
        if (isReplay && interval == null) return;

        // Extraction FIRST — before the mode split, so the insert path and
        // any future real-time consumer agree on what a sample is
        // (collector.dart:218-221).
        var sample = value;
        if (members != null && members.isNotEmpty) {
          final row = extractSampleMembers(value, members);
          if (row == null) {
            // A good-band sample none of whose members resolve is a real
            // sample lost to configuration: counted. A placeholder or
            // degraded value that resolves nothing lost no row — but it IS
            // the plant no longer confirming this key, so the held value
            // must degrade with it (CR-01): every consumer of `latest`
            // re-checks the band, and a raw unextracted struct held here
            // can never be inserted, only decline a tick or a gate-open.
            if (value.quality.band == 0) {
              _countSkip();
            } else {
              latest = value;
            }
            return;
          }
          sample = row;
        }

        if (interval != null) {
          latest = sample;
          if (!isReplay) heldIsArrival = true;
          return;
        }

        if (sample.quality.band != 0) {
          _countSkip();
          // The held value must track the key's CURRENT state (CR-01):
          // change mode judges the band at arrival time, and letting a
          // pre-degradation `latest` survive here means the gate-open hook
          // — whose variables are OTHER keys that can repaint good first —
          // inserts a band-0 reading at now() for a key that is currently
          // dark. Interval mode already holds the current truth by updating
          // unconditionally above; this is the same rule on this branch.
          latest = sample;
          return;
        }
        if (gate != null && !gate.isOpen) {
          // The condition is not (evaluably) true: the change is held, not
          // written. Not a counted loss — a closed gate is the operator's
          // configuration doing its job, not a row the historian failed.
          latest = sample;
          return;
        }
        _insert(entry, sample);
        latest = sample;
      },
      onError: (Object error, StackTrace stack) {
        // One key's stream error costs that key's sample, never the batch —
        // and the subscription continues (cancelOnError below).
        _entryFailures[entry.key] =
            'the value stream errored (collection continues): $error';
      },
      cancelOnError: false,
    );
    _subscriptions[entry.key] = subscription;

    if (interval != null) {
      var lastTick = 0;
      final timer = Timer.periodic(interval, (t) {
        // A tick that skipped whole periods is a WAKE-UP tick: the isolate
        // (or the process under it) was stalled across full sampling
        // windows, and it fires before the freshness sweep's own overdue
        // pass can degrade what the stall left behind — the sample deadline
        // is always the earlier one. `Timer.periodic` reports the missed
        // periods itself (`t.tick` jumps), which is information already in
        // scope, the same instinct as the reaper's LagStalled credit
        // (09-08). The floor keeps ordinary scheduler jitter out of it: a
        // GC pause is tens of milliseconds, a backup-snapshot freeze is
        // seconds, and only the second may open a gap.
        final missedWindowMs =
            (t.tick - lastTick - 1) * interval.inMilliseconds;
        final wokeFromStall = missedWindowMs > _stallDeclineFloorMs;
        lastTick = t.tick;
        final held = latest;
        // Nothing to sample before the first value: a tick with no reading
        // writes nothing and counts nothing — a row that never existed is
        // not a lost row.
        if (held == null) return;
        // A closed gate stops the tick from sampling at all — the operator
        // said "only while", and while is not now.
        if (gate != null && !gate.isOpen) return;
        if (wokeFromStall) {
          // The held value predates a gap nobody sampled through. Writing
          // it at now() stamps a pre-stall reading as current — after a 45 s
          // backup freeze that is a 45-second-old number wearing a fresh
          // timestamp, the one-row flat line F22e catches (09-09). Decline
          // and count the DECLINE, singular: `Timer.periodic` coalesces
          // every missed window into this one wake-up callback, so
          // PIPE.collect.rows_dropped moves by ~1 per stall however many
          // windows the freeze swallowed (~450 at 100 ms over 45 s). The
          // counter vouches for declines it made, not for windows it slept
          // through — whether the gate was open or the held band good
          // mid-freeze is unknowable from here — so the LOSS measure is the
          // gap itself, which stays legible in the trend; the counter says
          // that a stall-decline happened (09-REVIEW IN-03). A fresh
          // arrival processed earlier in this same wake burst is declined
          // too — the heuristic reads tick counts, not the held value's
          // age — at the cost of one row plus one counted decline
          // (09-REVIEW IN-04, edge a). Within one sweep interval the sweep
          // rules on the value's real age, and a live upstream re-vouches
          // it with its next arrival — an on-schedule tick then resumes
          // writing. What those post-decline ticks may stamp is bounded by
          // `staleAfter` (09-REVIEW IN-04, edge b): a quiet plant after a
          // short freeze resumes writes of the pre-freeze value, but a
          // value younger than staleAfter is one the system's own
          // freshness policy calls current, and the overdue sweep — which
          // fires in the same wake burst, before the next scheduled sample
          // tick can — rules the moment its real age crosses that line.
          if (heldIsArrival) _countSkip();
          return;
        }
        if (held.quality.band == 0) {
          _insert(entry, held);
          return;
        }
        // The held value is degraded: the tick declines, and — when a value
        // genuinely arrived and went bad — counts. This is the outage arm:
        // a gap plus a number, never a flat line.
        if (heldIsArrival) _countSkip();
      });
      // Belt to the top-of-method cancel's braces: two collectEntry calls
      // for one key can interleave across the ensureTable await, and the
      // loser's timer must not be silently overwritten while alive. The
      // cancel that carries the re-collect guarantee is the unconditional
      // one at the top (CR-02) — do not rely on this line for it.
      _sampleTimers[entry.key]?.cancel();
      _sampleTimers[entry.key] = timer;
    }
  }

  /// Cancels every subscription and sample timer, flushes the sink, and
  /// leaves no pending timer. Idempotent.
  ///
  /// Deliberately does not close the sink: the composition root owns the
  /// sink's lifecycle the way `LocalStateMan` owns the links'.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final timer in _sampleTimers.values) {
      timer.cancel();
    }
    _sampleTimers.clear();
    for (final subscription in _subscriptions.values.toList()) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final gate in _gates.values.toList()) {
      await gate.stop();
    }
    _gates.clear();
    await _connectionSub?.cancel();
    _connectionSub = null;
    await _sink.flush();
    _refreshHealth();
  }

  void _insert(CollectionEntry entry, DynamicValue sample) {
    // `insert` is contracted non-throwing (the seam doc); the handler on the
    // same line is for the sink that breaks the contract, because an
    // unhandled async error here takes down the isolate serving every panel
    // — freeze 8 pins this shape.
    unawaited(_sink.insert(entry.table, _now().toUtc(), sample.toJson(slim: true)).catchError((Object error) => _noteSinkBreach(entry.key, error)));
    _refreshHealth();
  }

  void _noteSinkBreach(String key, Object error) {
    _entryFailures[key] =
        'the sink broke its non-throwing insert contract: $error';
  }

  void _countSkip() {
    _skipped++;
    _refreshHealth();
  }

  /// The health keys are refreshed from here — the paths that already run —
  /// on [CollectHealth]'s deadline. No timer anywhere in this class serves
  /// the health keys; the sample timers sample.
  void _refreshHealth() {
    final stats = _sink.stats;
    _health.update(
      rowsWritten: stats.rowsWritten,
      // A lost row is a counted row, wherever it was lost: the sink's own
      // drops plus everything this runner declined.
      rowsDropped: stats.rowsDropped + _skipped,
      rowsQueued: stats.rowsQueued,
      // The sink's string, verbatim: redacted at the sink (T-8b-14), and a
      // second pass here would hide a sink that forgot.
      lastError: stats.lastError,
    );
  }
}
