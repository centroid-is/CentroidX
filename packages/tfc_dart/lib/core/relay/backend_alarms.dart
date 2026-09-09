/// The alarm engine: one evaluator, on backend main, for the whole plant.
///
/// Loads `alarm_man_config`, builds one [AlarmRuleWatcher] per `(alarm, rule)`,
/// keeps the active set, and publishes it to every connected panel as
/// [relay.AlarmKeys.active].
///
/// **Deliberately not everything.** This file does not touch `bin/main.dart` —
/// 14-08 wires it. Keeping that apart is what makes the regression window at
/// deletion time zero: the engine can be complete and tested before anything is
/// removed.
///
/// ## 0. It persists, and there is no flag saying whether (D-4, D-6)
///
/// One `alarm_history` row per activation, opened when a rule goes true and
/// closed when it clears — see `backend_alarm_history.dart`. The engine takes
/// an optional [AlarmHistoryWriter]; when it is absent nothing is written and
/// the fact is **logged once at start**, which is the only honest degradation.
/// There is no `historyToDb` boolean and there will not be one: a flag that
/// decides whether an object writes to a database is a flag somebody sets
/// wrong, and the duplicate-write hazard is removed by construction instead —
/// no other object in this codebase has a write path left after 14-07.
///
/// **A restart mid-alarm is adopted or closed, never erased and never guessed
/// at silently.** [start] loads every open row before the watchers begin.
/// A row whose `(uid, ruleIndex)` is not in the current configuration is closed
/// immediately as `inferred_config_change` — no evaluation is ever coming for
/// it. The rest wait: at each owning rule's **first** post-restart evaluation
/// the row is adopted when the rule still holds (keeping its original
/// `created_at`, which is the plant's own start instant and the whole point) or
/// closed as `inferred_restart` when it does not. A rule whose inputs never
/// reach the good band produces no first evaluation, so its row is left open
/// and counted by [pendingAdoptionCount] — "we do not know" is the honest
/// state, and it is reported rather than resolved by invention.
///
/// **A persistence failure never stops evaluation** (T-14-24). Every write is
/// caught, logged with the row identity, and evaluation carries on. A gap in
/// the history is a better outcome than a plant with no alarms.
///
/// ## 1. Evaluation is not gated on a consumer (D-6, D-7)
///
/// `AlarmMan` hangs its entire wiring off `_activeAlarmsController.onListen`
/// (`alarm.dart:305`), by way of `boolean_expression.dart:79`. On a panel that
/// is merely wasteful. On a headless backend it is fatal and silent: with no
/// client attached, no rule is evaluated, no row is written, and nothing
/// anywhere reports that alarms are off. The workaround in the current backend
/// is `bin/main.dart:94` — the process subscribing to its own alarm stream so
/// that the `onListen` body runs.
///
/// Here the wiring is [AlarmEngine.start] and nothing else. [activeAlarms] is
/// a pure observation surface over a `BehaviorSubject` with **no `onListen`
/// body at all**, and `AlarmRuleWatcher` below it has no stream to listen to
/// in the first place. Subscribing changes nothing; not subscribing costs
/// nothing.
///
/// ## 2. The subscriptions belong to the engine, for the life of the process
///
/// Each watcher takes one `BackendValueSource.subscribe` per resolved variable
/// at `start()` and holds it. Holding it is what makes the pipe issue
/// `PipeSubscribe` upstream, so the 0→1 refcount transition must not reverse
/// when the last panel closes — an alarm that stops being evaluated because
/// nobody happened to be looking is the defect this whole phase exists to
/// remove.
///
/// **Ordering obligation (D-7, P-4).** [start] must be called from
/// `bin/main.dart` **after** every `pipe.addWorker(...)`. A subscribe for a key
/// no worker owns costs no message and is silently dropped — 13-03's
/// `PipeResnapshot` contract — so an engine started before the spawn loop would
/// be subscribed to nothing, with no error anywhere and no symptom until the
/// day an alarm should have fired. 14-08 owns that call site and pins the
/// order structurally.
///
/// ## 3. `ALARM.active` is a snapshot, published on change
///
/// One key, one list, one entry per active alarm-**rule** instance, each entry
/// self-sufficient (see `AlarmActiveEntry`). Published only when the set
/// actually changes: the render string under an alarm moves on every tag
/// update, and a fan-out to every connected panel per tag update is the cost
/// this guard exists to avoid.
///
/// The payload is **bounded** by [AlarmEngine.maxPublishedEntries] with an
/// explicit truncation marker and a log line. `DynamicValue` bounds nesting at
/// 64 but says nothing about breadth (T-14-17), and deciding the ceiling beats
/// discovering it on the worst day the plant has had.
///
/// ## 4. Operator input is refused by name and never stops the backend
///
/// Three untrusted things reach this object, and each has its own refusal:
///
///  * **A mangled `alarm_man_config`** (T-14-15). `alarm.dart:360` throws
///    `FormatException` out of `AlarmMan.create` today, and 13-RIG-PROBE FIND-4
///    watched exactly that kill the backend after a `\copy` mangled the row's
///    `\"` escapes. Here the parse is caught, the preference key and the parse
///    offset are named, and the engine comes up empty rather than not at all.
///  * **One unparseable formula** (T-14-16). Caught per rule by the watcher,
///    reported by name through [refusals], and every other rule keeps running.
///  * **A plant tag named into the `ALARM.` namespace** (T-14-08). Refused at
///    [start], because this is the object that holds both the key mapping and
///    the namespace. `tfc_relay_local`'s `KeyRouter:439` covers the gateway
///    path and has no backend twin; 14-03 made `BackendLiveValues.keys` a set
///    so such a key is not *duplicated*, and left the *refusal* here.
///
/// ## 5. The clock is injected, with no default (D-2)
///
/// The string `DateTime.now(` does not appear in this file. 14-08 supplies the
/// real one at the composition root and nowhere else.
library;

import 'dart:async';
import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/alarm_rule_watcher.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// The preference row the plant's alarm definitions live in.
///
/// A preference, not the `alarm` table: `alarm.dart:351-360` reads exactly this
/// key, and nothing anywhere inserts into the `alarm` table. That is why
/// `alarm_history.alarm_uid` carried `REFERENCES alarm (uid)` and made every
/// history insert on Postgres a guaranteed SQLSTATE 23503 — dropped in schema
/// v7 (14-01), measured against a real server there, and the reason this engine
/// can write a row at all.
const String kAlarmManConfigKey = 'alarm_man_config';

/// How many entries [relay.AlarmKeys.active] carries before it is cut.
///
/// 200 is roughly ten times the worst simultaneous-alarm count SVN's lines can
/// produce and still a payload of a few tens of kilobytes, fanned out once per
/// change rather than per tag update. The number exists so that a runaway
/// configuration — a rule bound to a struct that went bad in 1500 places —
/// costs a truncated banner and a log line instead of a frame nobody can
/// encode. `DynamicValue` bounds nesting at 64; nothing bounds breadth
/// (T-14-17).
const int kMaxPublishedAlarmEntries = 200;

/// Where the engine puts the active set.
///
/// A seam, not a `PipeMainEndpoint`, for the reason `backend_seams.dart` states
/// about its own two: *"a plan that adds a capability adds a file that
/// implements one of these seams and a constructor argument at the composition
/// root; it never edits the composer."* It is also what lets every arm in
/// `backend_alarms_test.dart` run with no pipe at all.
abstract interface class AlarmStatePublisher {
  /// Makes [value] the current reading of [key] for every connected client.
  void publish(String key, relay.DynamicValue value);
}

/// [AlarmStatePublisher] over the pipe's own `ValueStore`.
///
/// On the `_seedHealth` precedent (`backend_live_values.dart:291`): a reserved
/// key is written straight into `PipeMainEndpoint.store` with `applyBatch`, so
/// it *is* a `ValueStoreNode` with the same handle identity, the same equality
/// guard and the same k-of-n notification arithmetic as a temperature. No
/// worker owns a reserved key, so no inbound frame can ever contend for it.
///
/// One key per call here, unlike `announceLinkLoss`'s batch, because there is
/// exactly one key: the whole reason the active set is a single value is that
/// a snapshot delivered as N keys is N arrivals with no instant at which a
/// client holds a consistent picture.
final class PipeStoreAlarmPublisher implements AlarmStatePublisher {
  PipeStoreAlarmPublisher(this._pipe);

  final PipeMainEndpoint _pipe;

  @override
  void publish(String key, relay.DynamicValue value) =>
      _pipe.store.applyBatch(<String, relay.DynamicValue>{key: value});
}

/// Something an acknowledgement can be handed to. [AlarmEngine] is the one.
///
/// **Why this exists rather than the engine's own type.** `backend_alarm_ack.dart`
/// adapts an engine to the gateway's `AlarmAckSink`, and the two properties
/// that adapter has — it passes both values through unchanged, and it does not
/// swallow a failure — are properties *of the adapter*, measurable only with
/// something other than the real engine behind it. [AlarmEngine] is a `final
/// class`, so nothing can stand in for it. One member wide, declared here
/// because this is the file that owns the acknowledge.
abstract interface class AlarmAcknowledger {
  /// See [AlarmEngine.acknowledge].
  Future<void> acknowledge(String alarmUid, int ruleIndex);
}

/// The alarm definitions that were **actually in force**, for whoever has to
/// resolve a stored row against them.
///
/// Separate from [AlarmAcknowledger] because the two capabilities genuinely
/// come apart — `relay_server.dart:318` makes the same point about its own two
/// alarm seams — and declared for [AlarmAcknowledger]'s reason: `AlarmEngine`
/// is a `final class`, so a reader that named it could not be measured against
/// anything else.
///
/// **The engine's copy, never a second read of `alarm_man_config`.** Re-reading
/// the preference would be a second answer to "which alarms exist" that can
/// disagree with the one the rules were evaluated under — including in the case
/// that matters most, where the engine *refused* an unparseable configuration
/// (`_refuseConfig`) and is running none. Null there says exactly that, and a
/// reader that had gone to the preference row itself would resolve a row
/// against definitions no alarm was ever judged by.
abstract interface class AlarmDefinitions {
  /// See [AlarmEngine.config] — null when the configuration could not be read.
  AlarmManConfig? get config;
}

/// Everything the relay gateway needs from the alarm engine, as one argument.
///
/// **One parameter rather than two, and that is the whole reason this type
/// exists.** `composeBackendRelay` wires an acknowledge sink and a history
/// source from the same object; two optional parameters would let a composition
/// pass one and forget the other, and a gateway that acknowledges but cannot
/// remember would refuse `alarmHistory` **by name** — a refusal that reads as a
/// deliberate deployment choice and is indistinguishable from one. That is not
/// hypothetical: it is precisely the defect the SVN rig met, where the history
/// seam shipped complete and unwired and every panel was told the gateway
/// serves no history.
abstract interface class GatewayAlarmEngine
    implements AlarmAcknowledger, AlarmDefinitions {}

/// One active alarm-rule instance, as the engine holds it.
///
/// Mutable where the wire type is not: [pendingAck] flips in place when an
/// `acknowledgeRequired` rule clears, and rebuilding the whole entry for one
/// boolean would make the "did anything change?" comparison a deep one.
final class _ActiveAlarm {
  _ActiveAlarm({
    required this.alarm,
    required this.rule,
    required this.ruleIndex,
    required this.stamp,
    required this.expressionText,
    this.historyId,
  });

  final AlarmConfig alarm;
  final AlarmRule rule;
  final int ruleIndex;
  final AlarmStamp stamp;
  final String? expressionText;
  bool pendingAck = false;

  /// Whether an operator has said they have seen this.
  ///
  /// An acknowledged entry stays in `_active` — it is **not** deleted — and is
  /// filtered out of everything a panel can observe. Keeping it is what makes
  /// the eventual clear able to close the right `alarm_history` row: the row is
  /// still open, and this object is the only thing holding its id.
  bool acknowledged = false;

  /// The backend's receipt instant for that acknowledgement, or null.
  AlarmStamp? acknowledgedStamp;

  /// The clearing evaluation's stamp, remembered while the entry is held for an
  /// acknowledgement ([pendingAck]).
  ///
  /// The stop ended when the PLANT said it ended. When the acknowledgement
  /// finally arrives and closes the row, this is the instant it closes at — not
  /// the acknowledgement's, which would move a completed stop's end forward to
  /// whenever somebody next looked at a screen.
  AlarmStamp? clearedStamp;

  /// Whether [clearedStamp] is a **reconstruction** rather than a measurement.
  ///
  /// True only on an entry adopted out of a `pending_ack` row at boot: this
  /// process never watched that condition go false, and the instant it holds is
  /// its own first post-restart evaluation — the best-known bound, not the
  /// thing that happened. The close that eventually uses it therefore says
  /// `inferred_restart` and not `acknowledged`, because a stop analysis has to
  /// be able to tell a measured end from a reconstructed one (T-14-23). The
  /// acknowledgement is still recorded, in `acknowledged_at`, which is the
  /// column that means "somebody saw this".
  bool clearedStampInferred = false;

  /// Why [clearedStamp] is a reconstruction, when [clearedStampInferred] and
  /// a reason more specific than `inferred_restart` both apply.
  ///
  /// Null on a measured clear and on the restart adoption (whose close keeps
  /// saying `inferred_restart`). Set to `inferred_input_recovery` when the
  /// clearing verdict was the first after a D-3 suspension: the plant may
  /// have recovered at any point while the input was dead, so the instant is
  /// a bound, and the row has to say WHICH kind of bound or a stop analysis
  /// reads a sensor outage as a backend restart.
  String? clearedInferredReason;

  /// The `alarm_history` row this activation was opened as.
  ///
  /// Null until the INSERT comes back, and null forever when the engine was
  /// composed with no writer. Mutable for the same reason [pendingAck] is: the
  /// id arrives after the entry does, and a database round trip must not hold
  /// up the banner (see [AlarmEngine._onTransition]).
  ///
  /// It is also the handle the *close* uses. Holding it on the entry, rather
  /// than in a second map keyed by identity, is what makes a clear that arrives
  /// before its own INSERT resolved still find the right row: the closure that
  /// closes captures this object.
  int? historyId;

  /// [staleInputs]/[staleSinceMs] are the engine's to supply: they live on
  /// the rule's WATCHER, not on this entry, because the hold is a fact about
  /// the rule's inputs right now and this object is a fact about one
  /// activation. See `AlarmEngine._wireEntry`.
  relay.AlarmActiveEntry toEntry({
    List<String> staleInputs = const [],
    int? staleSinceMs,
  }) =>
      relay.AlarmActiveEntry(
        uid: alarm.uid,
        ruleIndex: ruleIndex,
        level: rule.level.name,
        title: alarm.title,
        description: alarm.description,
        group: alarm.group,
        expression: expressionText,
        activeAtMs: stamp.at.toUtc().millisecondsSinceEpoch,
        tsSource: stamp.source.wireName,
        pendingAck: pendingAck,
        // The `alarm_history` row id, as a string because that is the wire
        // type. Null only while the INSERT is in flight, or forever on an
        // engine composed with no writer — never invented, because a panel
        // would follow an invented id to a query that returns nothing.
        historyId: historyId == null ? null : '$historyId',
        staleInputs: staleInputs,
        staleSinceMs: staleSinceMs,
      );
}

/// One rule of one alarm, and the watcher evaluating it.
final class _RuleBinding {
  _RuleBinding(this.alarm, this.rule, this.ruleIndex, this.watcher);

  final AlarmConfig alarm;
  final AlarmRule rule;
  final int ruleIndex;
  final AlarmRuleWatcher watcher;
}

/// The plant's one alarm evaluator. See the library doc for why each property
/// is here.
final class AlarmEngine implements GatewayAlarmEngine {
  /// Builds the engine and seeds [relay.AlarmKeys.active] **before anything
  /// can subscribe**.
  ///
  /// The seed is an **empty list at [relay.Quality.uncertainNotYetKnown]**, and
  /// the quality is the whole point. `_seedHealth` makes the same
  /// "before anything can subscribe" argument for `PIPE.connected` and reaches
  /// the opposite conclusion about the value, quoting `pipe_health.dart`: *"a
  /// health indicator that reads unknown until the first fault tells an
  /// operator nothing."* That argument does not transfer. "No alarms are
  /// active" and "the engine has not evaluated a rule yet" are different facts
  /// and only one of them is reassuring — seeding `good` would have this object
  /// assert the plant is fine before it has looked at it. Research Open
  /// Question 3's recommendation, taken; to reverse it, change the quality here
  /// and the arm named *seeded honestly at construction*.
  AlarmEngine({
    required BackendValueSource values,
    required PreferencesApi preferences,
    required AlarmStatePublisher publisher,
    required DateTime Function() clock,
    AlarmHistoryWriter? history,
    Duration skewWarnAfter = kAlarmSkewWarnAfter,
    this.maxPublishedEntries = kMaxPublishedAlarmEntries,
    String Function(String variable)? resolveKey,
    Logger? logger,
  })  : _values = values,
        _preferences = preferences,
        _publisher = publisher,
        _clock = clock,
        _history = history,
        _skewWarnAfter = skewWarnAfter,
        _resolveKey = resolveKey,
        _logger = logger ?? Logger() {
    _publisher.publish(
      relay.AlarmKeys.active,
      relay.DynamicValue(
        value: relay.AlarmActiveEntry.encodeList(const []),
        quality: relay.Quality.uncertainNotYetKnown,
      ),
    );
  }

  final BackendValueSource _values;
  final PreferencesApi _preferences;
  final AlarmStatePublisher _publisher;
  final DateTime Function() _clock;
  final AlarmHistoryWriter? _history;
  final Duration _skewWarnAfter;
  final String Function(String variable)? _resolveKey;
  final Logger _logger;

  /// The most entries [relay.AlarmKeys.active] will carry. See
  /// [kMaxPublishedAlarmEntries] for the number and its reason.
  final int maxPublishedEntries;

  final Map<(String, int), _ActiveAlarm> _active = {};
  final List<_RuleBinding> _rules = [];

  /// [_rules] keyed by D-4's identity, for the publish path.
  ///
  /// Filled alongside [_rules] in [_buildWatchers] and never afterwards. The
  /// wire entry for an active alarm carries its rule's CURRENT suspension
  /// state, which lives on the watcher — this is the join, O(1) per entry
  /// instead of a scan per entry per publication.
  final Map<(String, int), _RuleBinding> _bindingIndex = {};

  /// Open `alarm_history` rows waiting for their rule's first post-restart
  /// evaluation, keyed by D-4's identity.
  ///
  /// Emptied one key at a time as the verdicts arrive. Whatever is still in it
  /// belongs to rules whose inputs never reached the good band, and those rows
  /// stay open on purpose — see [pendingAdoptionCount].
  final Map<(String, int), OpenAlarmRow> _pendingAdoption = {};

  /// Every database write, in the order the transitions produced them.
  ///
  /// Serialised rather than fired in parallel: a clear can arrive before its
  /// own activation's INSERT has come back, and the UPDATE needs the id that
  /// INSERT returns. Chaining is also what keeps one slow query from
  /// interleaving two edges of the same row.
  Future<void> _writes = Future<void>.value();

  /// A plain [BehaviorSubject] with **no `onListen` body**. See the library
  /// doc; `alarm.dart:305` must not have an analogue here.
  ///
  /// Carries the whole active set, uncapped: the cap bounds what crosses the
  /// wire, never what this process knows.
  final BehaviorSubject<Set<relay.AlarmActiveEntry>> _subject =
      BehaviorSubject<Set<relay.AlarmActiveEntry>>.seeded(
          const <relay.AlarmActiveEntry>{});

  AlarmManConfig? _config;
  String? _configRefusal;
  bool _started = false;
  bool _hasEvaluated = false;
  int _publications = 0;

  /// Whether [start] has run to completion.
  bool get started => _started;

  /// The alarm definitions in force, or null when the configuration could not
  /// be read. See [refusals].
  ///
  /// [AlarmDefinitions]' one member: the gateway's history reader resolves a
  /// stored row's group and `acknowledgeRequired` against **this** copy, and
  /// null is a load-bearing answer — a refused configuration resolves nothing
  /// rather than resolving against definitions no alarm was ever judged by.
  @override
  AlarmManConfig? get config => _config;

  /// The active set as it stands, without subscribing to anything.
  ///
  /// The observation surface that makes arm *"evaluates with nobody
  /// listening"* expressible: a reader that never touches [activeAlarms] still
  /// sees the truth.
  ///
  /// **Acknowledged entries are not in it**, and they are still being tracked:
  /// see [_ActiveAlarm.acknowledged]. This getter answers the question a panel
  /// asks — "what is on the banner" — which is the same question
  /// [relay.AlarmKeys.active] answers, and the two must never disagree.
  Set<relay.AlarmActiveEntry> get active =>
      {for (final entry in _published) _wireEntry(entry)};

  /// The entries a panel is entitled to see: everything active that nobody has
  /// acknowledged yet.
  Iterable<_ActiveAlarm> get _published =>
      _active.values.where((entry) => !entry.acknowledged);

  /// How many acknowledged alarm-rule instances are still standing.
  ///
  /// Off the banner, still true, and their `alarm_history` rows still open —
  /// which is the correct state and the one this plan exists to produce. A
  /// count rather than a list because what a reader needs to know is that the
  /// engine has not forgotten them: an acknowledged entry it dropped would be a
  /// row nothing could ever close.
  int get acknowledgedStandingCount =>
      _active.values.where((entry) => entry.acknowledged).length;

  /// The active set as a stream, replaying the current value to a late
  /// subscriber.
  ///
  /// **Pure observation.** Listening starts nothing, cancels nothing and
  /// evaluates nothing; the last listener leaving does not stop the engine.
  Stream<Set<relay.AlarmActiveEntry>> activeAlarms() => _subject.stream;

  /// How many rules are currently suspended because an input is not good
  /// (CD-6).
  ///
  /// Consumed by [_onSuspensionEdge]'s log line — the aggregate an operator
  /// greps for when three rules go quiet at once — and readable by anything
  /// composing this engine. The per-rule fact travels further: an entry on
  /// the banner carries its own `staleInputs` on the wire, so a panel needs
  /// no second query to say WHY a held alarm is held.
  int get suspendedRuleCount =>
      _rules.where((binding) => binding.watcher.suspended).length;

  /// How many `alarm_history` rows are still waiting to be adopted or closed.
  ///
  /// Non-zero after [start] means rows a previous process left open whose rules
  /// have not yet produced a verdict — usually because an input has not reached
  /// the good band. Those rows are deliberately left alone: D-4's fourth row
  /// says "we do not know" is the honest state, and closing them would invent a
  /// clear while deleting them would erase a stop that may still be running.
  /// The count falls to zero as the verdicts arrive, and a count that never
  /// falls is a rule whose inputs never came back.
  int get pendingAdoptionCount => _pendingAdoption.length;

  /// Whether this engine is writing to `alarm_history` at all.
  ///
  /// An observation, not a switch: there is no `historyToDb` (D-6). False means
  /// the composition root handed this engine no writer, which [start] also logs
  /// once.
  bool get persists => _history != null;

  /// Completes when every database write enqueued so far has finished.
  ///
  /// Exists for tests and for an orderly shutdown. Production code does not
  /// await it — the whole design is that the wire does not wait for the
  /// database — but an arm that asserted on a row before its INSERT returned
  /// would be a flake, and a process that exited mid-INSERT would leave one.
  ///
  /// Loops because a write can enqueue another: the activation's INSERT
  /// republishes, and a clear arriving in between adds its own UPDATE.
  Future<void> persistenceIdle() async {
    for (var pass = 0; pass < 16; pass++) {
      final chain = _writes;
      await chain;
      if (identical(chain, _writes)) return;
    }
    _logger.w('AlarmEngine.persistenceIdle gave up after 16 passes: the write '
        'chain is still growing. Either the plant is producing transitions '
        'faster than the database can take them, or something is enqueuing '
        'work from inside a write.');
  }

  /// How many evaluations every rule has completed between them.
  int get evaluations =>
      _rules.fold(0, (sum, binding) => sum + binding.watcher.evaluations);

  /// How many times the active set has been published since [start].
  ///
  /// The constructor's seed is **not** counted: it is the honest absence of an
  /// active set, not a publication of one.
  int get publications => _publications;

  /// Everything this engine is refusing to do, and why, by name.
  ///
  /// Computed live rather than accumulated, so a rule that refuses on its first
  /// evaluation rather than at parse time appears here too. Empty is the normal
  /// answer.
  List<String> get refusals => <String>[
        if (_configRefusal != null) _configRefusal!,
        for (final binding in _rules)
          if (binding.watcher.refusal != null)
            'alarm "${binding.alarm.uid}": ${binding.watcher.refusal}',
      ];

  /// Loads the configuration, wires one watcher per rule and begins evaluating.
  ///
  /// **Call this after every `pipe.addWorker(...)`** — see the library doc's
  /// ordering obligation (D-7 / P-4).
  ///
  /// Throws [UnsupportedError], and only that, when the value source declares a
  /// key inside the reserved `ALARM.` namespace. Everything else an operator
  /// can get wrong is reported through [refusals] and leaves the engine
  /// running.
  Future<void> start() async {
    if (_started) return;

    _refuseForeignAlarmKeys();
    await _loadConfig();
    _buildWatchers();
    // Before the watchers, never after: a transition that arrived while the
    // open rows were still being read would open a SECOND row for an activation
    // that is already recorded, and the partial unique index would refuse it —
    // correctly, and with a 23505 nobody could explain.
    await _reconcileOpenRows();
    for (final binding in _rules) {
      await binding.watcher.start();
    }
    _started = true;

    // A configuration that parsed and declares no rules HAS completed its
    // evaluation pass — there was nothing in it. Saying so is what keeps SVN,
    // which has zero alarms configured today, from reading "not evaluated yet"
    // forever. A configuration that did NOT parse is a different fact and is
    // deliberately left uncertain: nothing is being evaluated there.
    if (_configRefusal == null && _rules.isEmpty) {
      _hasEvaluated = true;
      _publishActive();
    }
  }

  /// Loads every open `alarm_history` row and decides what can be decided now.
  ///
  /// Two answers are available at boot and no more:
  ///
  ///  * the row's `(uid, ruleIndex)` is **not in the current configuration** —
  ///    no evaluation will ever come for it, so it is closed straight away as
  ///    `inferred_config_change`, stamped by the injected clock and labelled
  ///    `backend_receipt` because there is no rule left to get a plant instant
  ///    from. A row with a NULL `rule_index` (written before schema v7) lands
  ///    here too: it cannot be matched to a rule, and assuming it means rule 0
  ///    would be a guess dressed as a fact.
  ///  * anything else waits in [_pendingAdoption] for its rule's first verdict.
  ///
  /// **Not `getRecentAlarms`** — see [AlarmHistoryWriter.loadOpenRows] for the
  /// reason (P-9), which is that the method drops precisely the rows the first
  /// branch above exists to close.
  Future<void> _reconcileOpenRows() async {
    final history = _history;
    if (history == null) {
      // Once, at start, and never again. This is the whole of D-6's honest
      // degradation: there is no flag to consult, so the only thing that can be
      // said is that this composition has no writer.
      _logger.w('AlarmEngine is running with NO alarm history writer: rules '
          'are being evaluated and published, and nothing is being written to '
          'alarm_history. There is no historyToDb flag to check (D-6) — hand '
          'the engine an AlarmHistoryWriter at the composition root if this '
          'backend is meant to persist.');
      return;
    }

    final List<OpenAlarmRow> open;
    try {
      open = await history.loadOpenRows();
    } catch (error, stack) {
      _logger.e(
          'AlarmEngine.start could not read the open alarm_history rows '
          '($error). Any row a previous process left open stays open, and '
          'this engine will open its own rows as alarms fire — which the '
          'partial unique index will refuse for as long as the old ones are '
          'there. Evaluation continues either way.',
          error: error,
          stackTrace: stack);
      return;
    }

    final known = <(String, int)>{
      for (final binding in _rules) (binding.alarm.uid, binding.ruleIndex),
    };

    for (final row in open) {
      final ruleIndex = row.ruleIndex;
      final identity = ruleIndex == null ? null : (row.alarmUid, ruleIndex);
      if (identity != null && known.contains(identity)) {
        _pendingAdoption[identity] = row;
        continue;
      }
      _logger.i('alarm_history row #${row.id} ("${row.alarmUid}" rule '
          '${ruleIndex ?? 'none'}) is open but no rule of the current '
          'configuration owns it, so nothing will ever evaluate it. Closing it '
          'as ${AlarmHistoryWriter.reasonInferredConfigChange}.');
      _enqueueWrite(
        'close #${row.id} (${AlarmHistoryWriter.reasonInferredConfigChange})',
        () => history.closeActivation(
          id: row.id,
          stamp: _receiptStamp(),
          reason: AlarmHistoryWriter.reasonInferredConfigChange,
        ),
      );
    }

    if (_pendingAdoption.isNotEmpty) {
      _logger.w('${_pendingAdoption.length} alarm_history row(s) were left '
          'open by a previous process: '
          '${_pendingAdoption.values.join(', ')}. Each is adopted or closed at '
          'its rule\'s first post-restart evaluation (D-4). Until that '
          'evaluation arrives the row stays open, because "we do not know" is '
          'the honest state and inventing a clear would shorten a stop that '
          'may still be running.');
    }
  }

  /// The backend's own receipt instant, labelled as such.
  ///
  /// Used where there is no evaluation to take a plant instant from: the
  /// config-change close, and nothing else. `DateTime.now(` does not appear in
  /// this file (D-2).
  AlarmStamp _receiptStamp() =>
      AlarmStamp(at: _clock(), source: AlarmTsSource.backendReceipt);

  /// T-14-08. The backend's only reserved-prefix check.
  ///
  /// `BackendLiveValues.keys` is a set as of 14-03, so such a key is no longer
  /// *duplicated* — but nothing yet *refused* it, and the gateway-side refusal
  /// (`tfc_relay_local`'s `KeyRouter:439`) has no backend twin. This engine is
  /// the object that holds both the key mapping and the namespace, so this is
  /// where it belongs.
  ///
  /// Refusal shape follows `backend_state_man.dart:90`: the member, the
  /// collaborator, and one sentence saying what to change.
  void _refuseForeignAlarmKeys() {
    for (final key in _values.keys) {
      if (!relay.AlarmKeys.isAlarmKey(key)) continue;
      if (key == relay.AlarmKeys.active) continue;
      throw UnsupportedError(
          'AlarmEngine.start is refusing to start: its BackendValueSource '
          'declares the key "$key", which is inside the reserved '
          '"${relay.AlarmKeys.prefix}" namespace this engine publishes '
          'through. Rename that key mapping in the operator configuration — '
          '"${relay.AlarmKeys.active}" is the only name permitted under that '
          'prefix, and a plant tag sharing it would overwrite the active alarm '
          'set every connected panel reads.');
    }
  }

  /// Reads and parses [kAlarmManConfigKey], refusing by name rather than
  /// throwing (T-14-15).
  ///
  /// An **absent** key is an empty configuration and is entirely normal — the
  /// plant may simply have no alarms yet, which is SVN today. Unlike
  /// `AlarmMan.create`, nothing is written back: a boot that seeds a
  /// preferences row is a boot that can seed it over a row it failed to read.
  Future<void> _loadConfig() async {
    final String? raw;
    try {
      raw = await _preferences.getString(kAlarmManConfigKey);
    } catch (error, stack) {
      _refuseConfig(
          'The "$kAlarmManConfigKey" preference could not be read ($error). '
          'Until it can be, no alarm is being evaluated; the rest of the '
          'backend is unaffected.',
          error,
          stack);
      return;
    }

    if (raw == null) {
      _config = AlarmManConfig(alarms: const []);
      return;
    }

    try {
      _config = AlarmManConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException catch (error, stack) {
      // 13-RIG-PROBE FIND-4: a `\copy` mangled this row's `\"` escapes and the
      // backend died at boot. The offset is in the message because it is the
      // only thing that makes a 40 kB row fixable by hand.
      _refuseConfig(
          'The "$kAlarmManConfigKey" preference is not valid JSON — the parse '
          'gave up at offset ${error.offset} (${error.message}). Until that '
          'row is fixed no alarm is being evaluated; the rest of the backend '
          'is unaffected.',
          error,
          stack);
    } catch (error, stack) {
      _refuseConfig(
          'The "$kAlarmManConfigKey" preference parsed as JSON but is not an '
          'alarm configuration ($error). Until that row is fixed no alarm is '
          'being evaluated; the rest of the backend is unaffected.',
          error,
          stack);
    }
  }

  void _refuseConfig(String message, Object error, StackTrace stack) {
    _configRefusal = message;
    _config = null;
    _logger.e(message, error: error, stackTrace: stack);
  }

  /// One watcher per `(alarm, ruleIndex)`, per D-4's identity.
  ///
  /// A construction failure is caught and named rather than allowed to
  /// propagate: one bad definition among two hundred must cost that one alarm
  /// and nothing else (T-14-16). The watcher already catches an unparseable
  /// *formula* itself and reports it through [refusals]; this catch is for
  /// everything else a definition can be wrong about.
  void _buildWatchers() {
    for (final alarm in _config?.alarms ?? const <AlarmConfig>[]) {
      for (var index = 0; index < alarm.rules.length; index++) {
        final rule = alarm.rules[index];
        try {
          final binding = _RuleBinding(
            alarm,
            rule,
            index,
            AlarmRuleWatcher(
              values: _values,
              expression: rule.expression,
              ruleIndex: index,
              clock: _clock,
              skewWarnAfter: _skewWarnAfter,
              resolveKey: _resolveKey,
              logger: _logger,
              onTransition: (transition) =>
                  _onTransition(alarm, rule, transition),
              onSuspensionChanged: () => _onSuspensionEdge(alarm.uid, index),
            ),
          );
          _rules.add(binding);
          _bindingIndex[(alarm.uid, index)] = binding;
        } catch (error, stack) {
          _logger.e(
              'alarm "${alarm.uid}" rule $index could not be constructed and '
              'is NOT being evaluated ($error). Every other rule is '
              'unaffected.',
              error: error,
              stackTrace: stack);
        }
      }
    }
  }

  /// `cleared` for a clear this engine watched happen; the input-recovery
  /// bound for one it could only infer. See [AlarmRuleTransition.afterSuspension].
  static String _clearReason(AlarmRuleTransition transition) =>
      transition.afterSuspension
          ? AlarmHistoryWriter.reasonInferredInputRecovery
          : AlarmHistoryWriter.reasonCleared;

  /// One rule crossed a suspension edge — entered the hold or left it.
  ///
  /// Two duties, both edge-not-tick (T-14-14):
  ///
  ///  * **The aggregate log line**, consuming [suspendedRuleCount]: when
  ///    three rules go quiet at once, "3 of 9" is the sentence an operator
  ///    greps for, and no per-rule line adds up to it.
  ///  * **Republish when a banner entry changed shape.** The active SET did
  ///    not move — a hold moves nothing, that is its whole point — but the
  ///    entry's `staleInputs`/`staleSinceMs` did, and nothing else re-encodes
  ///    the payload. A suspension on a rule with nothing published changes
  ///    nothing a panel can see, so nothing is fanned out for it.
  void _onSuspensionEdge(String alarmUid, int ruleIndex) {
    _logger.i('alarm suspension edge: $suspendedRuleCount of '
        '${_rules.length} alarm rule(s) suspended on a not-good input.');
    final entry = _active[(alarmUid, ruleIndex)];
    if (entry != null && !entry.acknowledged) _publishActive();
  }

  /// One rule changed its mind. Update the set, and publish if anything moved.
  ///
  /// The in-memory set moves **first and synchronously**, and the database
  /// follows on [_writes]. A banner that waited for a round trip to Postgres
  /// would be a banner a database outage can freeze, and the whole point of
  /// T-14-24 is that the history is the thing allowed to have gaps.
  void _onTransition(
      AlarmConfig alarm, AlarmRule rule, AlarmRuleTransition transition) {
    final identity = (alarm.uid, transition.ruleIndex);
    var changed = false;

    // The restart reconciliation resolves here, and only on a FIRST verdict:
    // that is the one evaluation that can say whether the condition a previous
    // process recorded is still true. `AlarmRuleWatcher` always emits its first
    // completed evaluation, false branch included, which is what makes an open
    // row closable at all.
    if (transition.isFirstEvaluation) {
      final pending = _pendingAdoption.remove(identity);
      if (pending != null) {
        return _resolveAdoption(alarm, rule, transition, pending);
      }
    }

    if (transition.active) {
      // An entry being HELD for an acknowledgement whose condition has come
      // back. Its `alarm_history` row is still open, so the INSERT below would
      // meet the v7 partial unique index — SQLSTATE 23505 — which
      // `_enqueueWrite` swallows by design (T-14-24). The consequence is
      // silent and doubly wrong: the new stop gets no row at all, and the held
      // row stays open forever with nothing left holding its id, growing an
      // unbounded stop in the table a downtime report reads. So the completed
      // stop is closed first, at the instant it really ended.
      //
      // Reachable with no restart at all — an intermittent acknowledgeRequired
      // fault is an ordinary thing on a plant — and reachable more often now
      // that the badge survives one (CR-02).
      final held = _active[identity];
      if (held != null && held.pendingAck && !held.acknowledged) {
        _logger.i('alarm "${alarm.uid}" rule ${transition.ruleIndex} was being '
            'held for an acknowledgement and its condition has come back. The '
            'held activation is closed at the instant it cleared and this one '
            'gets its own row; nobody acknowledged the first, and it is on the '
            'banner again either way.');
        _closeRow(
            held,
            held.clearedStamp ?? transition.stamp,
            held.clearedStampInferred
                ? (held.clearedInferredReason ??
                    AlarmHistoryWriter.reasonInferredRestart)
                : AlarmHistoryWriter.reasonCleared);
      }
      final entry = _ActiveAlarm(
        alarm: alarm,
        rule: rule,
        ruleIndex: transition.ruleIndex,
        stamp: transition.stamp,
        expressionText: transition.expressionText,
      );
      _active[identity] = entry;
      _openRow(entry, transition);
      changed = true;
    } else {
      final existing = _active[identity];
      if (existing != null) {
        if (existing.acknowledged) {
          // **This is the close the acknowledge deliberately did not make.**
          // The operator silenced it while the condition was still true, so
          // the row was left open; the plant has now ended the stop, and the
          // row closes at the plant's instant as `cleared` — a measurement,
          // not the consequence of somebody pressing a button. Unless the
          // verdict is the first after a suspension, in which case the
          // instant is a bound and the reason says so.
          _active.remove(identity);
          _closeRow(existing, transition.stamp, _clearReason(transition));
          // `changed` stays FALSE on purpose: this entry left the published
          // set when it was acknowledged, so nothing a panel can see moves
          // here and no fan-out is owed.
        } else if (rule.acknowledgeRequired) {
          // A fault that came and went between two glances at the screen is
          // still a fault somebody must see. It stays in the set, badged, until
          // [acknowledge].
          if (!existing.pendingAck) {
            existing.pendingAck = true;
            // Remembered now, used later. When the acknowledgement arrives it
            // closes the row at THIS instant, because this is when the stop
            // actually ended.
            existing.clearedStamp = transition.stamp;
            if (transition.afterSuspension) {
              // The held clear is a bound, and it must still say so when the
              // acknowledgement finally closes the row — hours later, long
              // after the transition that knew is gone.
              existing.clearedStampInferred = true;
              existing.clearedInferredReason =
                  AlarmHistoryWriter.reasonInferredInputRecovery;
            }
            // And remembered DURABLY (CR-02). Until this call the badge lived
            // in this process's memory and nowhere else, so a restart — which
            // happens on every alarm_man_config or key_mappings save — closed
            // the row as `inferred_restart` and the fault never reached a
            // banner. On the write chain like every other database operation,
            // so a clear that arrives before its own INSERT returned still
            // finds the id.
            _markPendingAck(existing);
            changed = true;
          }
        } else {
          _active.remove(identity);
          // The measured clear, `cleared` — unless the verdict is the first
          // after a D-3 suspension, in which case this engine did NOT watch
          // the condition go false: it watched the sensor come back with the
          // condition already over, and `inferred_input_recovery` is what
          // keeps that tellable from a measurement (T-14-23).
          _closeRow(existing, transition.stamp, _clearReason(transition));
          changed = true;
        }
      }
    }

    // The FIRST completed evaluation is a publication even when nothing became
    // active, because it is the moment "not known yet" becomes "nothing is
    // wrong" — two different things to an operator looking at a banner.
    final firstVerdict = !_hasEvaluated;
    _hasEvaluated = true;
    if (changed || firstVerdict) _publishActive();
  }

  /// Adopts or closes the open row [pending], on its rule's first verdict.
  ///
  /// **Adopt when the rule still holds.** The entry is registered with the
  /// row's ORIGINAL `createdAt` and its id, and **nothing is inserted**. Keeping
  /// the plant's own start instant across a restart is the whole point of D-4's
  /// adopt branch: re-stamping it with the restart would shorten every stop
  /// that spans one, in the direction nobody audits.
  ///
  /// **Close as `inferred_restart` when it does not.** The stamp is the
  /// evaluation's — the best-known bound on when it really cleared — and the
  /// reason says it is a reconstruction, so a stop analysis can tell it from
  /// something this engine actually watched happen.
  void _resolveAdoption(AlarmConfig alarm, AlarmRule rule,
      AlarmRuleTransition transition, OpenAlarmRow pending) {
    final identity = (alarm.uid, transition.ruleIndex);

    if (transition.active) {
      final adopted = _ActiveAlarm(
        alarm: alarm,
        rule: rule,
        ruleIndex: transition.ruleIndex,
        // The row's instant and the row's provenance, not this evaluation's.
        // Re-deriving the provenance as `plant` would relabel a previous
        // process's guess as the plant's word.
        stamp: AlarmStamp(
          at: pending.createdAt,
          source: _tsSourceOf(pending),
        ),
        expressionText: transition.expressionText,
        historyId: pending.id,
      );
      // **`pendingAck` is deliberately NOT carried across here** (CR-02, and
      // it is the trap the review named). The row may well say `pending_ack`
      // — an `acknowledgeRequired` rule that cleared before the restart —
      // but the condition is TRUE at this verdict, so this alarm is happening
      // and is standing, not waiting to be seen. Adopting the flag would let
      // `acknowledge()` take its `entry.pendingAck` branch and close the row
      // at the receipt instant: a stop that is still running reported as
      // having ended the moment an operator pressed a button, which is
      // T-14-56 and the one invariant this file's doc says must never break.
      //
      // The unacknowledged fault the row records is not lost by this — the
      // rule going false again badges the entry and writes the column again,
      // through the ordinary path.
      if (pending.pendingAck) {
        _logger.i('alarm_history row #${pending.id} for "${alarm.uid}" rule '
            '${transition.ruleIndex} was waiting to be acknowledged, but its '
            'condition is true again at this backend\'s first evaluation. It '
            'is adopted as STANDING: an alarm that is happening cannot be '
            'closed by an acknowledgement.');
      }
      // The acknowledgement survives the restart, because the column now
      // carries it. Without this an operator who silenced a standing alarm
      // before a backend restart would find it back on the banner afterwards,
      // with nothing to distinguish that from nobody having pressed the button
      // — and the row is open, so it would be silenced again and stamped
      // again, overwriting the first acknowledgement's instant.
      final acknowledgedAt = pending.acknowledgedAt;
      if (acknowledgedAt != null) {
        adopted.acknowledged = true;
        adopted.acknowledgedStamp = AlarmStamp(
            at: acknowledgedAt, source: AlarmTsSource.backendReceipt);
      }
      _active[identity] = adopted;
      _logger.i('adopted alarm_history row #${pending.id} for '
          '"${alarm.uid}" rule ${transition.ruleIndex}: the condition is still '
          'true, so the activation the previous process recorded is the same '
          'activation, and it keeps its onset of '
          '${pending.createdAt.toIso8601String()}.');
    } else if (pending.pendingAck && pending.acknowledgedAt == null) {
      // **The unacknowledged fault, adopted rather than erased** (CR-02).
      //
      // The row says an `acknowledgeRequired` rule had already gone false and
      // nobody had seen it. Closing it here as `inferred_restart` — which is
      // what this branch did for as long as the column was never written — is
      // exactly the erasure: the fault reaches no banner, and the history says
      // "reconstructed after a restart" rather than "an unacknowledged fault
      // occurred". A rule with `acknowledgeRequired` exists for the fault that
      // fires and clears between two glances at the screen, and this backend
      // restarts on every `alarm_man_config` or `key_mappings` save.
      //
      // So it goes back into the held state, badged, and the row stays open
      // until somebody acknowledges it.
      //
      // `clearedStamp` is THIS evaluation's — the best-known bound on when it
      // really cleared, and the same instant the close above would have used —
      // and it is flagged as a reconstruction so the eventual close says
      // `inferred_restart` rather than claiming this engine measured the end.
      //
      // The `acknowledgedAt == null` half matters: a row that is both
      // `pending_ack` and already acknowledged can only exist because the
      // close after an acknowledgement did not land. Re-badging that would ask
      // an operator to acknowledge something they already have, and would
      // overwrite the instant they first saw it.
      final held = _ActiveAlarm(
        alarm: alarm,
        rule: rule,
        ruleIndex: transition.ruleIndex,
        stamp: AlarmStamp(
          at: pending.createdAt,
          source: _tsSourceOf(pending),
        ),
        expressionText: transition.expressionText,
        historyId: pending.id,
      )
        ..pendingAck = true
        ..clearedStamp = transition.stamp
        ..clearedStampInferred = true;
      _active[identity] = held;
      _logger.w('alarm_history row #${pending.id} for "${alarm.uid}" rule '
          '${transition.ruleIndex} was left open by a previous process with an '
          'acknowledgement outstanding, and its condition is no longer true. '
          'It is back on the banner, badged, and its row stays open — a fault '
          'nobody has seen is not a fault that stops having happened because '
          'the backend restarted. Its end instant is this engine\'s first '
          'evaluation, which is a bound and not a measurement, and the close '
          'will say so.');
    } else {
      _logger.i('closing alarm_history row #${pending.id} for "${alarm.uid}" '
          'rule ${transition.ruleIndex} as '
          '${AlarmHistoryWriter.reasonInferredRestart}: its condition was no '
          'longer true at the first evaluation after this backend came up.');
      final history = _history;
      if (history != null) {
        _enqueueWrite(
          'close #${pending.id} '
          '(${AlarmHistoryWriter.reasonInferredRestart})',
          () => history.closeActivation(
            id: pending.id,
            stamp: transition.stamp,
            reason: AlarmHistoryWriter.reasonInferredRestart,
          ),
        );
      }
    }

    // A resolved adoption is a real change to the set either way — one entry
    // appeared, or one open row stopped being open — and it is also this
    // rule's first verdict, so the publication is owed on both counts.
    _hasEvaluated = true;
    _publishActive();
  }

  /// The provenance stored on [row], or the honest fallback.
  ///
  /// A row written before schema v7 has no `ts_source`. `backend_receipt` is
  /// what that is: nobody recorded that the plant supplied the instant, and
  /// claiming it did would be inventing the audit trail rather than the number.
  AlarmTsSource _tsSourceOf(OpenAlarmRow row) =>
      row.tsSource == AlarmTsSource.plant.wireName
          ? AlarmTsSource.plant
          : AlarmTsSource.backendReceipt;

  /// Opens a row for [entry], and republishes once its id is known.
  ///
  /// Two publications for one activation, and that is the deliberate trade: the
  /// banner goes out at once with a null `historyId`, and the id follows when
  /// the database answers. Waiting for the round trip would put a Postgres
  /// outage in front of the alarm banner; never republishing would leave every
  /// panel unable to correlate a live alarm with its row without a second
  /// query, which is what `historyId` exists to avoid (D-9).
  void _openRow(_ActiveAlarm entry, AlarmRuleTransition transition) {
    final history = _history;
    if (history == null) return;
    _enqueueWrite(
      'open ${entry.alarm.uid} rule ${entry.ruleIndex}',
      () async {
        final id = await history.openActivation(
          alarm: entry.alarm,
          ruleIndex: entry.ruleIndex,
          rule: entry.rule,
          expression: transition.expressionText,
          stamp: transition.stamp,
        );
        entry.historyId = id;
        // Only if this entry is still the live one: an alarm that cleared while
        // the INSERT was in flight has already been published as gone, and
        // republishing here would put it back on every panel.
        if (identical(_active[(entry.alarm.uid, entry.ruleIndex)], entry)) {
          _publishActive();
        }
      },
    );
  }

  /// Closes the row [entry] was opened as, if it was opened at all.
  void _closeRow(_ActiveAlarm entry, AlarmStamp stamp, String reason) {
    final history = _history;
    if (history == null) return;
    _enqueueWrite(
      'close ${entry.alarm.uid} rule ${entry.ruleIndex} ($reason)',
      () async {
        final id = entry.historyId;
        if (id == null) {
          // The activation's INSERT failed, so there is no row to close. Said
          // out loud: an alarm whose clear was written against nothing is a
          // stop with no end and no record of why.
          _logger.w('alarm "${entry.alarm.uid}" rule ${entry.ruleIndex} '
              'cleared, but no alarm_history row was ever opened for it, so '
              'there is nothing to close as "$reason". The activation insert '
              'failed earlier and was logged then.');
          return;
        }
        await history.closeActivation(id: id, stamp: stamp, reason: reason);
      },
    );
  }

  /// Puts one database operation on the serialised write chain.
  ///
  /// **Nothing here may take the engine down** (T-14-24). A failure is logged
  /// with the row identity and whatever the server said, and the chain carries
  /// on: an engine that stopped evaluating because a database went away is a
  /// worse outcome for a plant than a gap in its history.
  void _enqueueWrite(String what, Future<void> Function() operation) {
    _writes = _writes.then((_) async {
      try {
        await operation();
      } catch (error, stack) {
        _logger.e(
            'alarm_history write failed ($what): $error. The engine keeps '
            'evaluating — a gap in the history is a better outcome than a '
            'plant with no alarms.',
            error: error,
            stackTrace: stack);
      }
    });
  }

  /// Acknowledges one `(alarmUid, ruleIndex)` pair.
  ///
  /// **An acknowledgement is the operator saying "I have seen this", not the
  /// plant saying "this is over".** It silences the alarm and records who-when;
  /// it does not end a stop.
  ///
  /// What that means, column by column:
  ///
  ///  * `acknowledged_at` is stamped on the open `alarm_history` row, from the
  ///    injected clock and labelled `backend_receipt` (D-2) — an acknowledgement
  ///    is a human act at the backend and there is no plant instant for it.
  ///  * **If the condition is still true the row stays OPEN.** The stop is
  ///    still happening. Closing it here would report a stop as having ended
  ///    the moment somebody pressed a button, which is precisely the
  ///    under-reporting `alarmHistoryOverlaps` (`alarm.dart:205-211`) exists to
  ///    prevent — and it is silent, and in the direction nobody audits. The
  ///    entry is kept in `_active`, marked, and filtered out of everything a
  ///    panel observes; when the plant finally clears it the row closes as
  ///    `cleared` at the plant's own instant.
  ///  * **If the condition had already cleared** — the `pendingAck` case, where
  ///    the entry was being held on the banner waiting for exactly this — the
  ///    row closes now, with `deactivated_reason = 'acknowledged'` (D-4) and
  ///    `deactivated_at` set to the CLEARING evaluation's instant. Never the
  ///    acknowledgement's: the stop ended when the plant said it ended.
  ///
  /// The identity is `AckAlarmParams`'s, so the gateway's RPC has one call to
  /// make and no mapping to invent.
  ///
  /// **Idempotent, and completing on a miss is part of the contract.** A second
  /// acknowledgement of the same alarm, or one for an alarm that has already
  /// gone, is logged and returns. Two operators on two panels pressing the same
  /// button is the ordinary case, not the edge case, and a throw here reaches
  /// the second one as `handlerFailed` — told something is broken when nothing
  /// is.
  @override
  Future<void> acknowledge(String alarmUid, int ruleIndex) async {
    final identity = (alarmUid, ruleIndex);
    final entry = _active[identity];
    if (entry == null) {
      _logger.i('acknowledge for "$alarmUid" rule $ruleIndex matched no active '
          'alarm; nothing to do. Normally a race an operator cannot avoid — '
          'the alarm cleared while the frame was in flight, or another panel '
          'got there first — and not an error. A panel sending these steadily '
          'is a panel whose view of the plant has diverged.');
      return;
    }
    if (entry.acknowledged) {
      _logger.i('"$alarmUid" rule $ruleIndex was already acknowledged; the '
          'second acknowledgement is a no-op. The wire carries no idempotency '
          'key precisely because this is the same operator intent as the '
          'first.');
      return;
    }

    entry.acknowledged = true;
    final receipt = _receiptStamp();
    entry.acknowledgedStamp = receipt;
    _stampAcknowledged(entry, receipt);

    if (entry.pendingAck) {
      // The condition had already gone false and the entry was being held for
      // this. Now it can go, and its row closes at the instant the PLANT
      // cleared it — recorded when that happened, not read from a clock now.
      _active.remove(identity);
      // `acknowledged` says this engine WATCHED the clear and closed the row at
      // the instant it measured. An entry adopted out of a `pending_ack` row at
      // boot did not: this process never saw that condition go false, and its
      // `clearedStamp` is its own first post-restart evaluation. Labelling that
      // `acknowledged` would make a bound indistinguishable from a measurement
      // in the one column a stop analysis is audited on (T-14-23) — so it says
      // `inferred_restart`, and `acknowledged_at` carries the fact that
      // somebody saw it.
      _closeRow(
          entry,
          entry.clearedStamp ?? receipt,
          entry.clearedStampInferred
              ? (entry.clearedInferredReason ??
                  AlarmHistoryWriter.reasonInferredRestart)
              : AlarmHistoryWriter.reasonAcknowledged);
    }

    _publishActive();
  }

  /// Badges [entry]'s open row as waiting to be acknowledged, leaving it open.
  ///
  /// On the write chain and reading `historyId` from *inside* the closure, for
  /// [_closeRow]'s reason: the activation's INSERT may still be in flight when
  /// the rule clears, and the chain is what makes the id present by the time
  /// this runs.
  void _markPendingAck(_ActiveAlarm entry) {
    final history = _history;
    if (history == null) return;
    _enqueueWrite(
      'pending_ack ${entry.alarm.uid} rule ${entry.ruleIndex}',
      () async {
        final id = entry.historyId;
        if (id == null) {
          _logger.w('alarm "${entry.alarm.uid}" rule ${entry.ruleIndex} '
              'cleared with an acknowledgement outstanding, but no '
              'alarm_history row was ever opened for it, so there is nothing '
              'to badge. The activation insert failed earlier and was logged '
              'then; a restart before somebody acknowledges will lose the '
              'fault entirely.');
          return;
        }
        await history.markPendingAck(id: id);
      },
    );
  }

  /// Stamps `acknowledged_at` on [entry]'s open row, leaving it open.
  ///
  /// On the write chain like every other database operation, and reading
  /// `historyId` from *inside* the enqueued closure for [_closeRow]'s reason:
  /// the activation's INSERT may still be in flight when the acknowledgement
  /// arrives, and the chain is what makes the id present by the time this runs.
  void _stampAcknowledged(_ActiveAlarm entry, AlarmStamp stamp) {
    final history = _history;
    if (history == null) return;
    _enqueueWrite(
      'acknowledge ${entry.alarm.uid} rule ${entry.ruleIndex}',
      () async {
        final id = entry.historyId;
        if (id == null) {
          _logger.w('alarm "${entry.alarm.uid}" rule ${entry.ruleIndex} was '
              'acknowledged, but no alarm_history row was ever opened for it, '
              'so there is nothing to stamp. The activation insert failed '
              'earlier and was logged then; the acknowledgement still took '
              'effect on the banner.');
          return;
        }
        await history.acknowledgeActivation(id: id, stamp: stamp);
      },
    );
  }

  /// Rebuilds the payload, applies the cap and publishes at
  /// [relay.Quality.good].
  ///
  /// Entries go out **oldest onset first**, and that is also the order the cap
  /// keeps: on a plant-wide cascade the first thing that went wrong is the
  /// thing that explains the rest, so it is the last thing to drop off the
  /// list. Ties break on `(uid, ruleIndex)` so the payload is deterministic and
  /// an unchanged set never re-encodes differently.
  /// [_ActiveAlarm.toEntry], joined with its rule's live suspension state.
  ///
  /// The join is here and not on the entry because the hold belongs to the
  /// WATCHER: it can begin and end many times while one activation stands,
  /// and it exists for rules with no activation at all. An entry whose rule
  /// is not suspended states its liveness explicitly — empty, null — so a
  /// panel can tell "not held" from "sent by a build that predates the field".
  relay.AlarmActiveEntry _wireEntry(_ActiveAlarm entry) {
    final watcher = _bindingIndex[(entry.alarm.uid, entry.ruleIndex)]?.watcher;
    if (watcher == null || !watcher.suspended) return entry.toEntry();
    return entry.toEntry(
      staleInputs: watcher.suspendedInputs,
      staleSinceMs: watcher.suspendedSince?.toUtc().millisecondsSinceEpoch,
    );
  }

  void _publishActive() {
    // `_published`, never `_active.values`: an acknowledged entry is still
    // tracked — its `alarm_history` row is open and this engine is the only
    // thing that can close it — and it is deliberately not on any banner.
    final all = [for (final entry in _published) _wireEntry(entry)]
      ..sort((a, b) {
        final byOnset = a.activeAtMs.compareTo(b.activeAtMs);
        if (byOnset != 0) return byOnset;
        final byUid = a.uid.compareTo(b.uid);
        return byUid != 0 ? byUid : a.ruleIndex.compareTo(b.ruleIndex);
      });

    final truncated = all.length > maxPublishedEntries;
    final shown = truncated ? all.sublist(0, maxPublishedEntries) : all;
    final omitted = all.length - shown.length;

    if (truncated) {
      _logger.w('${relay.AlarmKeys.active} truncated: ${all.length} alarm-rule '
          'instances are active and the cap is $maxPublishedEntries, so '
          '$omitted were omitted from the payload. The engine still holds all '
          'of them; only what crosses the wire is cut.');
    }

    _publications++;
    _publisher.publish(
      relay.AlarmKeys.active,
      relay.DynamicValue(
        value: relay.AlarmActiveEntry.encodeList(shown,
            truncated: truncated, omitted: omitted),
        // Good: an evaluation completed and this is its result. The seeded
        // uncertainNotYetKnown is left behind here and never returned to.
        quality: relay.Quality.good,
      ),
    );
    _subject.add(Set<relay.AlarmActiveEntry>.unmodifiable(all));
  }

  /// Releases every subscription this engine holds.
  Future<void> dispose() async {
    for (final binding in _rules) {
      await binding.watcher.dispose();
    }
    _rules.clear();
    await _subject.close();
  }
}
