/// The half of the storm `FaultProxy` has no lever for: upstream links,
/// gateway lifecycle, credentials and panel traffic — generated as pure data.
///
/// **This is a deliberate PARALLEL to `FaultMutation`, not an extension of
/// it.** `scenario_schedule.dart:82-89` states why that sealed type is exactly
/// one final class per `FaultProxy` lever: the correspondence is what makes
/// `ScenarioPlayback.apply` *"a one-to-one map rather than a translation layer
/// with its own opinions, and a reader comparing this file to
/// `fault_proxy.dart` can check it by eye."* An upstream epoch bump has no
/// proxy lever, a gateway restart has no proxy lever, and a revoked token has
/// no proxy lever; adding them to `FaultMutation` would destroy the one
/// property that makes its exhaustive switch worth having, and they would sit
/// in `tfc_stateman_contract`, which knows nothing about `LocalStateMan`. So
/// there are two sealed types, two generators and one merge — and the merge is
/// [mergeTotalOrder] in `soak_timeline.dart`, next door.
///
/// **The determinism requirement is the same one, inherited verbatim.**
/// Nothing here reads a clock, touches a file or consults ambient state:
/// [SoakEventSchedule.generateReport] is a pure function from its arguments to
/// an immutable list, so the generated list **is** the event log and a failing
/// soak prints its own reproduction procedure. `scenario_schedule.dart`'s
/// library doc makes the whole argument and this file does not repeat it.
///
/// **A SECOND generator off a salted seed, never a shared one.** The event
/// stream draws from a [SeededScenarioRandom] seeded `seed ^ _eventStreamSalt`
/// (0x50AC). Sharing one generator with the link half would couple them: the
/// day somebody adds a fifteenth event kind, every link-fault repro log ever
/// pasted into an issue would describe a storm that no longer happens for that
/// seed. With the salt, adding or removing an event kind shifts the event
/// stream and leaves the link timeline for that seed exactly where it was.
/// [SoakEventSchedule.generate] takes the **run's** seed and applies the salt
/// itself, so there is exactly one place it can be got wrong.
///
/// **`SoakEvent` is `sealed`, for `FaultMutation`'s reason.** 11-03's driver
/// applies a timeline through an exhaustive switch, so a fifteenth lever added
/// here without playback support is a compile error rather than an entry that
/// logs itself, fires into nothing and silently narrows the storm.
///
/// **Exclusivity is resolved during generation, never during playback** — the
/// link generator's argument, applied to four new rules. A storm that could
/// abort itself twenty minutes in on a `StateError`, or cull its own panel
/// population and then pass vacuously for the rest of the run, is a storm that
/// destroyed its own experiment. See [SoakExclusivityRules].
///
/// **The caller decides which panels the storm may touch.** [panels] is the
/// set of panels this generator is allowed to target, and a run with a
/// never-faulted control panel (11-RESEARCH §C.4) must **not** pass that
/// panel's id here: a `TokenRevocation` against the control would disconnect
/// the one panel whose flat reconnect count is the strongest arm every checker
/// has. This generator cannot tell a control panel from an ordinary one, so
/// the exclusion is the caller's and it is stated here rather than assumed.
library;

import 'dart:math';

import 'package:tfc_stateman_contract/faults.dart';

// ---------------------------------------------------------------- the vocabulary

/// One thing the storm does to the world outside the proxy, and when.
///
/// The parallel of `ScheduledFault`: value equality and a [toString] that
/// reads as a log line, because the list of these is half of the artifact a
/// failing soak prints and a human pastes back.
final class ScheduledSoakEvent {
  const ScheduledSoakEvent(this.offset, this.event);

  /// How far into the run this happens, measured from playback start.
  final Duration offset;

  /// What happens.
  final SoakEvent event;

  @override
  bool operator ==(Object other) =>
      other is ScheduledSoakEvent &&
      other.offset == offset &&
      other.event == event;

  @override
  int get hashCode => Object.hash(offset, event);

  @override
  String toString() => '[${formatScheduleStamp(offset)}] $event';
}

/// One lever pull outside the proxy, as data.
///
/// Sealed, so 11-03's `apply` is exhaustive — see the library doc.
sealed class SoakEvent {
  const SoakEvent();

  /// Which entry in [SoakEventKinds.all] this event is.
  ///
  /// The weights, the density report and the per-rule skip counters are all
  /// written in these names rather than in runtime types, for the reason
  /// `FaultMutation.mode` gives: one spelling that a map can be keyed by, so a
  /// misspelling is an `ArgumentError` naming the unknown key instead of a
  /// weight that silently draws nothing.
  String get kind;
}

/// The upstream device link for [alias] goes away.
///
/// Drives `FakeUpstreamLink.disconnectUpstream()`, which mass-degrades that
/// alias's keys and announces the state change **once**
/// (`fake_upstream_link.dart:395-403`).
final class UpstreamLinkDown extends SoakEvent {
  const UpstreamLinkDown(this.alias);

  final String alias;

  @override
  String get kind => SoakEventKinds.upstreamLinkDown;

  @override
  bool operator ==(Object other) =>
      other is UpstreamLinkDown && other.alias == alias;

  @override
  int get hashCode => Object.hash(kind, alias);

  @override
  String toString() => 'upstream $alias down';
}

/// The upstream device link for [alias] comes back.
///
/// **Never drawn — always emitted as [UpstreamLinkDown]'s paired recovery**, at
/// a drawn offset inside a bounded outage window. That is what makes "the
/// storm does not leave a link down for the rest of the run" a property of the
/// generator rather than a rule somebody checks afterwards.
final class UpstreamLinkUp extends SoakEvent {
  const UpstreamLinkUp(this.alias);

  final String alias;

  @override
  String get kind => SoakEventKinds.upstreamLinkUp;

  @override
  bool operator ==(Object other) =>
      other is UpstreamLinkUp && other.alias == alias;

  @override
  int get hashCode => Object.hash(kind, alias);

  @override
  String toString() => 'upstream $alias up';
}

/// The PLC behind [alias] changed identity: every handle resolved so far is
/// stale.
///
/// Drives `FakeUpstreamLink.bumpEpoch()` — 08-08's multi-input epoch, which
/// forces a re-browse and bad quality on the handles taken out before it.
final class UpstreamEpochBump extends SoakEvent {
  const UpstreamEpochBump(this.alias);

  final String alias;

  @override
  String get kind => SoakEventKinds.upstreamEpochBump;

  @override
  bool operator ==(Object other) =>
      other is UpstreamEpochBump && other.alias == alias;

  @override
  int get hashCode => Object.hash(kind, alias);

  @override
  String toString() => 'upstream $alias epoch bump';
}

/// Every key on [alias] degrades at once, on **one** announcement.
///
/// Drives 08-09's `applyLinkLoss` / `announceLinkState` pair, kept separate on
/// the fake for exactly this reason (`fake_upstream_link.dart:16-19`): one
/// status notification per mass-degradation, never one per key.
final class UpstreamMassDegrade extends SoakEvent {
  const UpstreamMassDegrade(this.alias);

  final String alias;

  @override
  String get kind => SoakEventKinds.upstreamMassDegrade;

  @override
  bool operator ==(Object other) =>
      other is UpstreamMassDegrade && other.alias == alias;

  @override
  int get hashCode => Object.hash(kind, alias);

  @override
  String toString() => 'upstream $alias mass degrade';
}

/// Reads and writes on [alias] take [latency] to answer.
///
/// Drives `readLatency` / `writeLatency` on the fake, which is the only way to
/// exercise freeze 3's required-deadline discipline: the sole test of a
/// deadline is to be slower than one.
final class UpstreamSlowResolve extends SoakEvent {
  const UpstreamSlowResolve(this.alias, this.latency);

  final String alias;
  final Duration latency;

  @override
  String get kind => SoakEventKinds.upstreamSlowResolve;

  @override
  bool operator ==(Object other) =>
      other is UpstreamSlowResolve &&
      other.alias == alias &&
      other.latency == latency;

  @override
  int get hashCode => Object.hash(kind, alias, latency);

  @override
  String toString() =>
      'upstream $alias slow resolve ${latency.inMilliseconds}ms';
}

/// The gateway process stops and starts.
///
/// Drives `RelayServer.close()` then `start()` through 08-13's composition
/// root. Every subscription generation resets and the epoch changes at the
/// same moment, so this is the herd's whole reconnect path in one event.
final class GatewayRestart extends SoakEvent {
  const GatewayRestart();

  @override
  String get kind => SoakEventKinds.gatewayRestart;

  @override
  bool operator ==(Object other) => other is GatewayRestart;

  @override
  int get hashCode => SoakEventKinds.gatewayRestart.hashCode;

  @override
  String toString() => 'gateway restart';
}

/// [stationId]'s credential stops being valid.
///
/// Drives Phase 6's `RevocableTokenValidator` — rewrite the token file and
/// `RelayServer.reloadTokens`. The session closes 4001 and the panel redials
/// **exactly once** and then stops, by design: a refused credential is not
/// something to retry. Which is why this event never occurs without its
/// [TokenRestore].
final class TokenRevocation extends SoakEvent {
  const TokenRevocation(this.stationId);

  final String stationId;

  @override
  String get kind => SoakEventKinds.tokenRevocation;

  @override
  bool operator ==(Object other) =>
      other is TokenRevocation && other.stationId == stationId;

  @override
  int get hashCode => Object.hash(kind, stationId);

  @override
  String toString() => 'revoke $stationId';
}

/// [stationId]'s credential is valid again.
///
/// **Never drawn — always emitted as [TokenRevocation]'s paired recovery**, at
/// a drawn offset inside [SoakEventSchedule.tokenRestoreWindow]. Emitted at
/// generation time so it is in the repro log and a reader can see it, rather
/// than being a rule the driver applies invisibly.
final class TokenRestore extends SoakEvent {
  const TokenRestore(this.stationId);

  final String stationId;

  @override
  String get kind => SoakEventKinds.tokenRestore;

  @override
  bool operator ==(Object other) =>
      other is TokenRestore && other.stationId == stationId;

  @override
  int get hashCode => Object.hash(kind, stationId);

  @override
  String toString() => 'restore $stationId';
}

/// The routing configuration is re-ingested.
///
/// Drives `KeyRouter.applyKeyMappings`, which classifies and never throws
/// (08-PATTERNS §2) — the live-editable path that re-points subscriptions
/// underneath the panels holding them.
final class KeymappingReload extends SoakEvent {
  const KeymappingReload();

  @override
  String get kind => SoakEventKinds.keymappingReload;

  @override
  bool operator ==(Object other) => other is KeymappingReload;

  @override
  int get hashCode => SoakEventKinds.keymappingReload.hashCode;

  @override
  String toString() => 'keymapping reload';
}

/// [panel] subscribes to [keys].
final class PanelSubscribe extends SoakEvent {
  PanelSubscribe(this.panel, Iterable<String> keys)
      : keys = List<String>.unmodifiable(keys);

  final String panel;
  final List<String> keys;

  @override
  String get kind => SoakEventKinds.panelSubscribe;

  @override
  bool operator ==(Object other) =>
      other is PanelSubscribe &&
      other.panel == panel &&
      _sameKeys(other.keys, keys);

  @override
  int get hashCode => Object.hash(kind, panel, Object.hashAll(keys));

  @override
  String toString() => '$panel subscribe ${keys.join('+')}';
}

/// [panel] drops [keys].
final class PanelUnsubscribe extends SoakEvent {
  PanelUnsubscribe(this.panel, Iterable<String> keys)
      : keys = List<String>.unmodifiable(keys);

  final String panel;
  final List<String> keys;

  @override
  String get kind => SoakEventKinds.panelUnsubscribe;

  @override
  bool operator ==(Object other) =>
      other is PanelUnsubscribe &&
      other.panel == panel &&
      _sameKeys(other.keys, keys);

  @override
  int get hashCode => Object.hash(kind, panel, Object.hashAll(keys));

  @override
  String toString() => '$panel unsubscribe ${keys.join('+')}';
}

/// [panel] writes [value] to [key] — one operator action.
///
/// The cmd id is **not** here and never will be: the client mints it with
/// `Random.secure` (`ulid.dart:17-21`, for a good reason), so it is not
/// reproducible across two runs of one seed. The *n*-th write of the run is
/// the stable identity, which is `invariant.dart:87-90`'s rule.
final class PanelWrite extends SoakEvent {
  const PanelWrite(this.panel, this.key, this.value);

  final String panel;
  final String key;
  final Object? value;

  @override
  String get kind => SoakEventKinds.panelWrite;

  @override
  bool operator ==(Object other) =>
      other is PanelWrite &&
      other.panel == panel &&
      other.key == key &&
      other.value == value;

  @override
  int get hashCode => Object.hash(kind, panel, key, value);

  @override
  String toString() => '$panel write $key=$value';
}

/// [panel] asks for [window] of history on [series].
///
/// Phase 10's data-services surface, taken at a low rate (11-RESEARCH open
/// question 1). The soak asserts only that a query **answers or refuses and
/// never drops the session** — whether the rows are right stays Phase 10's
/// evidence. There is no database in this lane, so a refusal is an entirely
/// ordinary outcome and the arm is written to expect either.
final class PanelQuery extends SoakEvent {
  const PanelQuery(this.panel, this.series, this.window);

  final String panel;
  final String series;
  final Duration window;

  @override
  String get kind => SoakEventKinds.panelQuery;

  @override
  bool operator ==(Object other) =>
      other is PanelQuery &&
      other.panel == panel &&
      other.series == series &&
      other.window == window;

  @override
  int get hashCode => Object.hash(kind, panel, series, window);

  @override
  String toString() => '$panel query $series over ${window.inMinutes}m';
}

/// The plant changes [key] to [value] underneath everything else.
///
/// §7.8's *"a scripted server mutates values"*, and the lever invariant 3's
/// whole comparison rests on: without mutations the resync check compares a
/// client to a plant that never moved.
final class PlantMutate extends SoakEvent {
  const PlantMutate(this.key, this.value);

  final String key;
  final Object? value;

  @override
  String get kind => SoakEventKinds.plantMutate;

  @override
  bool operator ==(Object other) =>
      other is PlantMutate && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash(kind, key, value);

  @override
  String toString() => 'plant $key=$value';
}

bool _sameKeys(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// --------------------------------------------------------------- the registry

/// Every event kind, and the subset a storm may draw.
///
/// A closed set written down once, so the weights can be validated against it
/// and the density report can be keyed by it. Two of the fourteen are
/// **recoveries** and are deliberately not drawable: emitting them only as the
/// paired half of a disruption is what makes exclusivity rule 2 structural
/// rather than a property somebody checks afterwards.
abstract final class SoakEventKinds {
  static const String upstreamLinkDown = 'upstreamLinkDown';
  static const String upstreamLinkUp = 'upstreamLinkUp';
  static const String upstreamEpochBump = 'upstreamEpochBump';
  static const String upstreamMassDegrade = 'upstreamMassDegrade';
  static const String upstreamSlowResolve = 'upstreamSlowResolve';
  static const String gatewayRestart = 'gatewayRestart';
  static const String tokenRevocation = 'tokenRevocation';
  static const String tokenRestore = 'tokenRestore';
  static const String keymappingReload = 'keymappingReload';
  static const String panelSubscribe = 'panelSubscribe';
  static const String panelUnsubscribe = 'panelUnsubscribe';
  static const String panelWrite = 'panelWrite';
  static const String panelQuery = 'panelQuery';
  static const String plantMutate = 'plantMutate';

  /// All fourteen arms of the sealed type.
  static const List<String> all = <String>[
    upstreamLinkDown,
    upstreamLinkUp,
    upstreamEpochBump,
    upstreamMassDegrade,
    upstreamSlowResolve,
    gatewayRestart,
    tokenRevocation,
    tokenRestore,
    keymappingReload,
    panelSubscribe,
    panelUnsubscribe,
    panelWrite,
    panelQuery,
    plantMutate,
  ];

  /// The two emitted only as a paired recovery.
  static const List<String> pairedRecoveries = <String>[
    upstreamLinkUp,
    tokenRestore,
  ];

  /// The twelve a storm draws from.
  static const List<String> drawable = <String>[
    upstreamLinkDown,
    upstreamEpochBump,
    upstreamMassDegrade,
    upstreamSlowResolve,
    gatewayRestart,
    tokenRevocation,
    keymappingReload,
    panelSubscribe,
    panelUnsubscribe,
    panelWrite,
    panelQuery,
    plantMutate,
  ];
}

/// The four exclusivity rules, plus the two structural skips, by name.
///
/// Named constants rather than string literals because the per-rule skip
/// counter is the **only** thing that can prove a rule was ever exercised. A
/// rule resolves by *not emitting*, so unlike the link generator's conflict
/// resolution — which emits a clear a sweep can see
/// (`schedule_test.dart:139-143`) — there is nothing in the output to count.
/// Without the counters the four sweeps below could pass over a storm that
/// never came close to breaking any of them.
abstract final class SoakExclusivityRules {
  /// Rule 1. A restart's own recovery must complete before the next one, or
  /// the run measures restart-during-restart — which is F23's row, not this
  /// phase's.
  static const String restartSeparation = 'restartSeparation';

  /// Rule 2. Every revocation carries its restore, and a station already
  /// revoked is not revoked again. Without this the panel population shrinks
  /// monotonically: a refused credential stops the redial loop by design
  /// (Phase 6), so a storm that revokes without restoring ends with zero
  /// panels and the last twenty minutes measure nothing while every invariant
  /// passes vacuously.
  static const String revocationPairing = 'revocationPairing';

  /// Rule 3. No epoch bump on an alias that is currently down. 08-09 ordered
  /// the degradation paths so they do not fight; the storm must not
  /// manufacture the state that phase specifically avoided.
  static const String bumpOnDownAlias = 'bumpOnDownAlias';

  /// Rule 4. At most one write per panel in flight — one cmd id is one
  /// operator action (04-REVIEW CR-05), and concurrent writes from one panel
  /// are a different scenario.
  static const String writeInFlight = 'writeInFlight';

  /// Not one of the four, and counted anyway: a draw suppressed because it
  /// (or its recovery) would have reached into a generated quiet window.
  static const String quietWindow = 'quietWindow';

  /// Counted apart from [quietWindow] on purpose. A draw whose recovery would
  /// have run past the **end of the run** is suppressed by the same
  /// arithmetic, and lumping the two together would report a quiet-window
  /// suppression count that is non-zero for a timeline with no windows in it
  /// — which is exactly the kind of number somebody reads once and trusts.
  static const String runTail = 'runTail';

  /// Not one of the four either: a draw that would have fired into nothing —
  /// a second link-down on an alias already down, an unsubscribe from a panel
  /// holding no subscription. An event that applies to nothing does not fail;
  /// it silently narrows the storm, which is worse.
  static const String noOp = 'noOp';

  static const List<String> all = <String>[
    restartSeparation,
    revocationPairing,
    bumpOnDownAlias,
    writeInFlight,
    quietWindow,
    runTail,
    noOp,
  ];
}

// ---------------------------------------------------------------- the windows

/// An interval in which the storm arms nothing, computed at generation time.
///
/// Half-open: `[start, end)`. Derived by `computeStableWindows` in
/// `soak_timeline.dart`, which owns the arithmetic; the type lives here
/// because the event generator has to know where the windows are in order to
/// draw around them.
final class StableWindow {
  const StableWindow(this.start, this.end);

  final Duration start;
  final Duration end;

  Duration get length => end - start;

  bool contains(Duration offset) => offset >= start && offset < end;

  @override
  bool operator ==(Object other) =>
      other is StableWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() =>
      '${formatScheduleStamp(start)}..${formatScheduleStamp(end)} '
      '(${length.inMilliseconds}ms)';
}

// ---------------------------------------------------------------- the weights

/// How often each drawable kind is drawn, relative to the others.
///
/// Keyed by the names in [SoakEventKinds.drawable] and validated against them,
/// which is `ScenarioWeights`' argument copied deliberately: a misspelling is
/// an `ArgumentError` naming the unknown key, where a typed builder would have
/// weighted nothing and produced a storm that never pulls the lever its author
/// asked for.
final class SoakEventWeights {
  const SoakEventWeights(this.byKind);

  /// The default profile, and the arithmetic behind every number.
  ///
  /// At the default 10–40 s band the mean gap is 25 s, so a storm draws
  /// **2.4 times a minute** and the total weight of 23 makes one weight point
  /// worth 0.104 draws a minute. Against the link half's ~11 entries a minute
  /// the whole event stream is deliberately sparse: each of these has a
  /// recovery cost measured in seconds, and a storm that fires them faster
  /// than they recover measures recovery-during-recovery rather than the pipe.
  ///
  ///  * `plantMutate` **6** (~0.63/min) is the largest because it is the only
  ///    lever that moves plant truth, and invariant 3 compares client value to
  ///    plant truth. A storm that rarely mutates compares a client to a plant
  ///    that never moved, which passes for the wrong reason.
  ///  * `panelWrite` **3** (~0.31/min) — one operator action per panel at a
  ///    time (rule 4), so a higher weight mostly buys skips.
  ///  * `panelQuery` **3** (~0.31/min). **This is a declared departure from
  ///    the plan's "~1/min"**: one query a minute is 42 % of every event draw
  ///    at the frozen 10–40 s band, which would leave every other lever —
  ///    including `plantMutate` — under a tenth of a draw a minute. The
  ///    departure is recorded in 11-02's SUMMARY with this arithmetic; the
  ///    measured rate is printed by `soak_schedule_test.dart` on every run so
  ///    the number is never taken on trust.
  ///  * `panelSubscribe` **2** against `panelUnsubscribe` **1**, so the
  ///    subscribed set grows on average rather than draining to nothing.
  ///  * `upstreamLinkDown` **2** (~0.21/min, and each emits its paired up).
  ///  * everything else **1** (~0.10/min, so ~4 in a thirty-five-minute run):
  ///    an epoch bump, a mass degrade, a slow resolve, a gateway restart, a
  ///    revocation and a keymapping reload are each expensive enough that four
  ///    in thirty-five minutes is a storm rather than a queue.
  static const SoakEventWeights soak = SoakEventWeights(<String, int>{
    SoakEventKinds.plantMutate: 6,
    SoakEventKinds.panelWrite: 3,
    SoakEventKinds.panelQuery: 3,
    SoakEventKinds.panelSubscribe: 2,
    SoakEventKinds.panelUnsubscribe: 1,
    SoakEventKinds.upstreamLinkDown: 2,
    SoakEventKinds.upstreamEpochBump: 1,
    SoakEventKinds.upstreamMassDegrade: 1,
    SoakEventKinds.upstreamSlowResolve: 1,
    SoakEventKinds.gatewayRestart: 1,
    SoakEventKinds.tokenRevocation: 1,
    SoakEventKinds.keymappingReload: 1,
  });

  /// The weight of each drawable name. Zero-weight entries are never drawn.
  final Map<String, int> byKind;

  /// The sum of every weight — the range a draw is taken from.
  int get total => byKind.values.fold(0, (sum, weight) => sum + weight);

  /// Throws unless every key names a drawable kind and the weights can be
  /// drawn from.
  void validate() {
    for (final entry in byKind.entries) {
      if (!SoakEventKinds.drawable.contains(entry.key)) {
        final recovery = SoakEventKinds.pairedRecoveries.contains(entry.key);
        throw ArgumentError.value(
            entry.key,
            'byKind',
            recovery
                ? 'is a paired recovery, not a drawable kind. It is emitted '
                    'only as the second half of the disruption that requires '
                    'it, which is what makes exclusivity rule 2 structural; '
                    'weighting it would let a storm restore a credential it '
                    'never revoked'
                : 'is not an event kind; the drawable names are '
                    '${SoakEventKinds.drawable.join(', ')}. A key that names '
                    'no kind weights nothing, so the storm would quietly '
                    'never pull that lever');
      }
      if (entry.value < 0) {
        throw ArgumentError.value(entry.value, 'byKind[${entry.key}]',
            'a weight is a share of the draws, so it cannot be negative');
      }
    }
    if (total <= 0) {
      throw ArgumentError.value(
          byKind,
          'byKind',
          'every weight is zero, so there is nothing to draw and the storm '
              'would be a list of no events wearing a duration');
    }
  }

  /// Draws one name, consuming exactly one number from [random].
  ///
  /// Exactly one, unconditionally — `ScenarioWeights._draw`'s rule, and for
  /// its reason: a draw that sometimes consumed two would make the stream
  /// depend on the outcome of earlier draws in a way that is still
  /// deterministic and impossible to reason about when a profile changes.
  String draw(Random random) {
    var ticket = random.nextInt(total);
    for (final entry in byKind.entries) {
      ticket -= entry.value;
      if (ticket < 0) return entry.key;
    }
    throw StateError('weight draw fell off the end of ${byKind.keys.join(', ')}');
  }
}

// -------------------------------------------------------------- the generator

/// What one generation produced, and what it refused to produce.
///
/// [skipsByRule] is the half that cannot be recovered from [events]: a rule
/// resolves by suppressing a draw, so the only trace it leaves is this
/// counter. Without it the four exclusivity sweeps would be green for a
/// generator that never came close to breaking a rule — which is the shape of
/// vacuity the whole soak apparatus exists to refuse.
final class SoakEventGeneration {
  SoakEventGeneration({
    required List<ScheduledSoakEvent> events,
    required Map<String, int> skipsByRule,
    required Map<String, int> drawsByKind,
    required this.draws,
  })  : events = List<ScheduledSoakEvent>.unmodifiable(events),
        skipsByRule = Map<String, int>.unmodifiable(skipsByRule),
        drawsByKind = Map<String, int>.unmodifiable(drawsByKind);

  /// The generated timeline, in offset order.
  final List<ScheduledSoakEvent> events;

  /// How many draws each rule suppressed, keyed by [SoakExclusivityRules].
  final Map<String, int> skipsByRule;

  /// How many times each kind was drawn, drawn-not-emitted included.
  final Map<String, int> drawsByKind;

  /// How many draws the generator made in total.
  final int draws;
}

/// The pure generator: arguments in, an immutable event timeline out.
abstract final class SoakEventSchedule {
  /// The salt that keeps the two streams independent.
  ///
  /// **0x50AC.** Changing it invalidates every event repro log ever printed,
  /// which is `SeededScenarioRandom`'s own rule about its constants and is why
  /// this one is written out rather than derived from anything.
  static const int _eventStreamSalt = 0x50AC;

  /// The salt, for the repro log.
  ///
  /// Readable because a log that does not name it is not self-contained: a
  /// reader six weeks later has the run's seed and needs to know what the
  /// event stream was actually seeded with.
  static int get eventStreamSalt => _eventStreamSalt;

  /// The seed the event stream is drawn from, for a run seeded [seed].
  static int eventSeedFor(int seed) => seed ^ _eventStreamSalt;

  /// The default gap band — 10–40 s, mean 25 s.
  static const Duration defaultMinGap = Duration(seconds: 10);
  static const Duration defaultMaxGap = Duration(seconds: 40);

  /// Rule 1's separation: a gateway restart's own recovery.
  static const Duration restartSeparation = Duration(seconds: 15);

  /// Rule 2's window: a revoked credential is restored inside this.
  ///
  /// The floor exists so a restore is never so immediate that the panel's
  /// single redial (Phase 6: a refused credential stops the loop) has not
  /// happened yet — a revocation the panel never noticed is an event that
  /// fired into nothing.
  static const Duration tokenRestoreMin = Duration(seconds: 5);
  static const Duration tokenRestoreWindow = Duration(seconds: 60);

  /// How long a link stays down before its paired [UpstreamLinkUp].
  static const Duration linkOutageMin = Duration(seconds: 5);
  static const Duration linkOutageMax = Duration(seconds: 30);

  /// Rule 4's window: `LocalStateMan.writeDeadline` defaults to five seconds
  /// (`local_state_man.dart:98`), so five seconds after a write the previous
  /// one has reached one of its three terminal states. A pure generator cannot
  /// know when a write actually resolved — that is the point of it being pure
  /// — so the deadline is the honest model of "in flight", and it is the same
  /// number the gateway uses.
  static const Duration writeFlightWindow = Duration(seconds: 5);

  /// How long before a quiet window opens the storm stops reaching into it.
  ///
  /// A recovery that finishes at the instant a window opens has not finished
  /// as far as the window is concerned: the client still has a resync in
  /// flight. One second of margin, and it is why every kind declares a
  /// [recoverySpanOf].
  static const Duration windowGuard = Duration(seconds: 1);

  /// Keys per alias when the caller supplies none.
  static const int keysPerAlias = 3;

  /// The default key pool for [aliases], in the plant's own
  /// `AREA.DEV.SUB` shape so a repro log reads like the tags it stands for.
  static List<String> defaultKeysFor(Iterable<String> aliases) => <String>[
        for (final alias in aliases)
          for (var i = 1; i <= keysPerAlias; i++)
            '$alias.CN${i.toString().padLeft(2, '0')}.run',
      ];

  /// How long after [kind] fires the world is still settling.
  ///
  /// Used only to keep the storm out of the generated quiet windows: a draw
  /// whose recovery would run past the next window's opening is suppressed.
  /// The windows are where invariant 3 requires convergence, so a window
  /// entered mid-recovery would report divergences that were simply not
  /// finished converging — 11-RESEARCH assumption A4's failure, arriving from
  /// the other side.
  static Duration recoverySpanOf(String kind) => switch (kind) {
        // Both carry a paired recovery whose offset is clamped against the
        // window directly, so a span here would double-count.
        SoakEventKinds.upstreamLinkDown => Duration.zero,
        SoakEventKinds.tokenRevocation => Duration.zero,
        SoakEventKinds.gatewayRestart => restartSeparation,
        SoakEventKinds.upstreamEpochBump => const Duration(seconds: 5),
        SoakEventKinds.upstreamMassDegrade => const Duration(seconds: 3),
        SoakEventKinds.upstreamSlowResolve => const Duration(seconds: 3),
        SoakEventKinds.keymappingReload => const Duration(seconds: 2),
        SoakEventKinds.panelSubscribe => const Duration(seconds: 2),
        SoakEventKinds.panelUnsubscribe => const Duration(seconds: 2),
        SoakEventKinds.panelWrite => writeFlightWindow,
        SoakEventKinds.panelQuery => const Duration(seconds: 2),
        SoakEventKinds.plantMutate => const Duration(seconds: 1),
        _ => throw StateError('no recovery span for kind "$kind"; it is '
            'drawable, so a storm can emit it into a quiet window'),
      };

  /// Generates the event half of a storm. No clock, no I/O, no ambient state.
  ///
  /// Takes the **run's** [seed] and salts it internally — see the library doc.
  static List<ScheduledSoakEvent> generate({
    required int seed,
    required Duration duration,
    required List<String> panels,
    required List<String> aliases,
    SoakEventWeights weights = SoakEventWeights.soak,
    Duration minGap = defaultMinGap,
    Duration maxGap = defaultMaxGap,
    Iterable<String>? keys,
    List<StableWindow> quietWindows = const <StableWindow>[],
  }) =>
      generateReport(
        seed: seed,
        duration: duration,
        panels: panels,
        aliases: aliases,
        weights: weights,
        minGap: minGap,
        maxGap: maxGap,
        keys: keys,
        quietWindows: quietWindows,
      ).events;

  /// The same, plus the counters that prove the rules were exercised.
  static SoakEventGeneration generateReport({
    required int seed,
    required Duration duration,
    required List<String> panels,
    required List<String> aliases,
    SoakEventWeights weights = SoakEventWeights.soak,
    Duration minGap = defaultMinGap,
    Duration maxGap = defaultMaxGap,
    Iterable<String>? keys,
    List<StableWindow> quietWindows = const <StableWindow>[],
  }) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(
          duration,
          'duration',
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
    if (panels.isEmpty) {
      throw ArgumentError.value(
          panels,
          'panels',
          'a storm with no panels to target draws panel events that name '
              'nobody, so every per-panel invariant passes vacuously. The '
              'never-faulted control is excluded by not being in this list, '
              'which means an all-control population is a caller error');
    }
    if (aliases.isEmpty) {
      throw ArgumentError.value(aliases, 'aliases',
          'a storm with no upstream aliases can break nothing upstream');
    }
    weights.validate();

    final keyPool = List<String>.unmodifiable(keys ?? defaultKeysFor(aliases));
    if (keyPool.isEmpty) {
      throw ArgumentError.value(keys, 'keys', 'the key pool is empty');
    }

    final random = SeededScenarioRandom(eventSeedFor(seed));
    final events = <ScheduledSoakEvent>[];
    final skips = <String, int>{
      for (final rule in SoakExclusivityRules.all) rule: 0,
    };
    final draws = <String, int>{
      for (final kind in SoakEventKinds.drawable) kind: 0,
    };

    // Recoveries drawn ahead of the events that follow them, held in offset
    // order and flushed in place. This is why the monotonicity arm exists: an
    // implementation that appended them at the end would produce a list whose
    // offsets go backwards, and playback would apply half the storm at once.
    final pending = <ScheduledSoakEvent>[];
    final downAliases = <String>{};
    final revokedStations = <String>{};
    final subscribed = <String, Set<String>>{
      for (final panel in panels) panel: <String>{},
    };
    final lastWriteAt = <String, Duration>{};
    Duration? lastRestartAt;

    // Sorted window starts, so "the next window" is a scan rather than a sort
    // inside the loop.
    final windows = List<StableWindow>.of(quietWindows)
      ..sort((a, b) => a.start.compareTo(b.start));

    StableWindow? windowContaining(Duration offset) {
      for (final window in windows) {
        if (window.contains(offset)) return window;
      }
      return null;
    }

    /// Where the storm has to stop reaching, from [offset], and which of the
    /// two barriers it ran into. The reason travels with the limit so a
    /// suppression is counted under what actually caused it.
    ({Duration limit, String reason}) barrierAfter(Duration offset) {
      for (final window in windows) {
        if (window.start > offset) {
          return (
            limit: window.start - windowGuard,
            reason: SoakExclusivityRules.quietWindow
          );
        }
      }
      return (limit: duration, reason: SoakExclusivityRules.runTail);
    }

    void flushPendingUpTo(Duration offset) {
      while (pending.isNotEmpty && pending.first.offset <= offset) {
        final entry = pending.removeAt(0);
        switch (entry.event) {
          case UpstreamLinkUp(:final alias):
            downAliases.remove(alias);
          case TokenRestore(:final stationId):
            revokedStations.remove(stationId);
          default:
            break;
        }
        events.add(entry);
      }
    }

    void schedulePending(ScheduledSoakEvent entry) {
      var index = pending.length;
      while (index > 0 && pending[index - 1].offset > entry.offset) {
        index--;
      }
      pending.insert(index, entry);
    }

    String pick(List<String> from) => from[random.nextInt(from.length)];

    Duration between(Duration low, Duration high) {
      final spread = (high - low).inMicroseconds;
      return low +
          Duration(microseconds: spread <= 0 ? 0 : random.nextInt(spread + 1));
    }

    final gapSpread = (maxGap - minGap).inMicroseconds;
    var offset = Duration.zero;

    while (true) {
      offset += minGap +
          Duration(
              microseconds: gapSpread == 0 ? 0 : random.nextInt(gapSpread + 1));
      if (offset >= duration) break;

      flushPendingUpTo(offset);

      final inside = windowContaining(offset);
      if (inside != null) {
        // Resume drawing after the window rather than inside it. The window is
        // where invariant 3 requires convergence; an event in it turns a
        // required convergence into an optional one.
        skips[SoakExclusivityRules.quietWindow] =
            skips[SoakExclusivityRules.quietWindow]! + 1;
        offset = inside.end;
        continue;
      }

      final kind = weights.draw(random);
      draws[kind] = draws[kind]! + 1;

      final barrier = barrierAfter(offset);
      final floor = barrier.limit;

      void skip(String rule) => skips[rule] = skips[rule]! + 1;

      if (offset + recoverySpanOf(kind) > floor) {
        skip(barrier.reason);
        continue;
      }

      switch (kind) {
        case SoakEventKinds.upstreamLinkDown:
          final alias = pick(aliases);
          if (downAliases.contains(alias)) {
            // `disconnectUpstream` returns early when the link is already
            // down (fake_upstream_link.dart:397), so a second one would be a
            // log line describing nothing.
            skip(SoakExclusivityRules.noOp);
            continue;
          }
          final latest = floor;
          if (offset + linkOutageMin > latest) {
            skip(barrier.reason);
            continue;
          }
          final recoverAt = between(
            offset + linkOutageMin,
            _earlier(offset + linkOutageMax, latest),
          );
          events.add(ScheduledSoakEvent(offset, UpstreamLinkDown(alias)));
          schedulePending(
              ScheduledSoakEvent(recoverAt, UpstreamLinkUp(alias)));
          downAliases.add(alias);

        case SoakEventKinds.upstreamEpochBump:
          final alias = pick(aliases);
          if (downAliases.contains(alias)) {
            skip(SoakExclusivityRules.bumpOnDownAlias);
            continue;
          }
          events.add(ScheduledSoakEvent(offset, UpstreamEpochBump(alias)));

        case SoakEventKinds.upstreamMassDegrade:
          events.add(
              ScheduledSoakEvent(offset, UpstreamMassDegrade(pick(aliases))));

        case SoakEventKinds.upstreamSlowResolve:
          final alias = pick(aliases);
          final latency = between(const Duration(milliseconds: 100),
              const Duration(milliseconds: 2000));
          events
              .add(ScheduledSoakEvent(offset, UpstreamSlowResolve(alias, latency)));

        case SoakEventKinds.gatewayRestart:
          final since = lastRestartAt;
          if (since != null && offset - since < restartSeparation) {
            skip(SoakExclusivityRules.restartSeparation);
            continue;
          }
          events.add(ScheduledSoakEvent(offset, const GatewayRestart()));
          lastRestartAt = offset;

        case SoakEventKinds.tokenRevocation:
          final station = pick(panels);
          if (revokedStations.contains(station)) {
            skip(SoakExclusivityRules.revocationPairing);
            continue;
          }
          final latest = _earlier(offset + tokenRestoreWindow, floor);
          if (offset + tokenRestoreMin > latest) {
            // No room to restore before the next quiet window opens. Emitting
            // the revocation anyway would either leave the panel gone or put
            // its redial inside the window; refusing the draw is the only
            // option that keeps both properties.
            skip(SoakExclusivityRules.revocationPairing);
            continue;
          }
          final restoreAt = between(offset + tokenRestoreMin, latest);
          events.add(ScheduledSoakEvent(offset, TokenRevocation(station)));
          schedulePending(
              ScheduledSoakEvent(restoreAt, TokenRestore(station)));
          revokedStations.add(station);

        case SoakEventKinds.keymappingReload:
          events.add(ScheduledSoakEvent(offset, const KeymappingReload()));

        case SoakEventKinds.panelSubscribe:
          final panel = pick(panels);
          final count = 1 + random.nextInt(3);
          final chosen = <String>[];
          for (var i = 0; i < count; i++) {
            final key = pick(keyPool);
            if (!chosen.contains(key)) chosen.add(key);
          }
          events.add(ScheduledSoakEvent(offset, PanelSubscribe(panel, chosen)));
          subscribed[panel]!.addAll(chosen);

        case SoakEventKinds.panelUnsubscribe:
          final panel = pick(panels);
          final held = subscribed[panel]!;
          if (held.isEmpty) {
            skip(SoakExclusivityRules.noOp);
            continue;
          }
          final key = held.elementAt(random.nextInt(held.length));
          events.add(ScheduledSoakEvent(
              offset, PanelUnsubscribe(panel, <String>[key])));
          held.remove(key);

        case SoakEventKinds.panelWrite:
          final panel = pick(panels);
          final previous = lastWriteAt[panel];
          if (previous != null && offset - previous < writeFlightWindow) {
            skip(SoakExclusivityRules.writeInFlight);
            continue;
          }
          events.add(ScheduledSoakEvent(
              offset, PanelWrite(panel, pick(keyPool), random.nextInt(1000))));
          lastWriteAt[panel] = offset;

        case SoakEventKinds.panelQuery:
          events.add(ScheduledSoakEvent(
              offset,
              PanelQuery(pick(panels), pick(keyPool),
                  _queryWindows[random.nextInt(_queryWindows.length)])));

        case SoakEventKinds.plantMutate:
          events.add(ScheduledSoakEvent(
              offset, PlantMutate(pick(keyPool), random.nextInt(1000))));

        default:
          throw StateError('drew "$kind", which no arm of the generator '
              'emits. A drawable kind with no emission is a lever the storm '
              'weights and never pulls');
      }
    }

    // Every pending recovery was clamped inside the run when it was drawn, so
    // this flush is what puts the tail of the storm in the log rather than a
    // set of disruptions with no matching recovery.
    flushPendingUpTo(duration);

    return SoakEventGeneration(
      events: events,
      skipsByRule: skips,
      drawsByKind: draws,
      draws: draws.values.fold(0, (sum, count) => sum + count),
    );
  }

  /// The history windows a panel asks for. Fixed rather than drawn as a
  /// continuous range, so a repro log reads `over 5m` instead of
  /// `over 4m 51.203s`.
  static const List<Duration> _queryWindows = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];
}

Duration _earlier(Duration a, Duration b) => a <= b ? a : b;

/// `mm:ss.mmm`, so a log column lines up and a reader can scan offsets.
///
/// The same rendering `scenario_schedule.dart`'s private `_stamp` produces,
/// spelled again here because it is private there and because the merged log
/// has to render both halves identically or the columns do not line up. A
/// case in `soak_schedule_test.dart` pins the two against each other.
String formatScheduleStamp(Duration offset) {
  final minutes = offset.inMinutes.toString().padLeft(2, '0');
  final seconds = (offset.inSeconds % 60).toString().padLeft(2, '0');
  final millis = (offset.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$minutes:$seconds.$millis';
}
