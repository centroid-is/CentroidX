/// The alarm engine: one evaluator, on backend main, for the whole plant.
///
/// Loads `alarm_man_config`, builds one [AlarmRuleWatcher] per `(alarm, rule)`,
/// keeps the active set, and publishes it to every connected panel as
/// [relay.AlarmKeys.active].
///
/// **Deliberately not everything.** This file does not persist — 14-06 adds
/// `alarm_history` — and it does not touch `bin/main.dart` — 14-08 wires it.
/// Keeping those apart is what makes the regression window at deletion time
/// zero: the engine can be complete and tested before anything is removed.
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
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// The preference row the plant's alarm definitions live in.
///
/// A preference, not the `alarm` table: `alarm.dart:351-360` reads exactly this
/// key, and nothing anywhere inserts into the `alarm` table (which is also why
/// `alarm_history.alarm_uid`'s `REFERENCES alarm (uid)` is a latent defect —
/// 14-06's problem, not this file's).
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
  });

  final AlarmConfig alarm;
  final AlarmRule rule;
  final int ruleIndex;
  final AlarmStamp stamp;
  final String? expressionText;
  bool pendingAck = false;

  relay.AlarmActiveEntry toEntry() => relay.AlarmActiveEntry(
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
        // 14-06 fills this. Null here is not a stub: this plan writes no row,
        // so there is no id to carry and inventing one would be a lie a panel
        // could follow to a query that returns nothing.
        historyId: null,
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
final class AlarmEngine {
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
    Duration skewWarnAfter = kAlarmSkewWarnAfter,
    this.maxPublishedEntries = kMaxPublishedAlarmEntries,
    String Function(String variable)? resolveKey,
    Logger? logger,
  })  : _values = values,
        _preferences = preferences,
        _publisher = publisher,
        _clock = clock,
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
  final Duration _skewWarnAfter;
  final String Function(String variable)? _resolveKey;
  final Logger _logger;

  /// The most entries [relay.AlarmKeys.active] will carry. See
  /// [kMaxPublishedAlarmEntries] for the number and its reason.
  final int maxPublishedEntries;

  final Map<(String, int), _ActiveAlarm> _active = {};
  final List<_RuleBinding> _rules = [];

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
  AlarmManConfig? get config => _config;

  /// The active set as it stands, without subscribing to anything.
  ///
  /// The observation surface that makes arm *"evaluates with nobody
  /// listening"* expressible: a reader that never touches [activeAlarms] still
  /// sees the truth.
  Set<relay.AlarmActiveEntry> get active =>
      {for (final entry in _active.values) entry.toEntry()};

  /// The active set as a stream, replaying the current value to a late
  /// subscriber.
  ///
  /// **Pure observation.** Listening starts nothing, cancels nothing and
  /// evaluates nothing; the last listener leaving does not stop the engine.
  Stream<Set<relay.AlarmActiveEntry>> activeAlarms() => _subject.stream;

  /// How many rules are currently suspended because an input is not good
  /// (CD-6).
  ///
  /// A counter and a log line. A `PIPE.`-namespace key carrying the same fact
  /// was the nicer option and is deferred rather than half-built: it needs a
  /// reserved key, a declaration on `BackendLiveValues` and a place on the
  /// panel, and none of those are this plan's.
  int get suspendedRuleCount =>
      _rules.where((binding) => binding.watcher.suspended).length;

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
          _rules.add(_RuleBinding(
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
            ),
          ));
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

  /// One rule changed its mind. Update the set, and publish if anything moved.
  void _onTransition(
      AlarmConfig alarm, AlarmRule rule, AlarmRuleTransition transition) {
    final identity = (alarm.uid, transition.ruleIndex);
    var changed = false;

    if (transition.active) {
      _active[identity] = _ActiveAlarm(
        alarm: alarm,
        rule: rule,
        ruleIndex: transition.ruleIndex,
        stamp: transition.stamp,
        expressionText: transition.expressionText,
      );
      changed = true;
    } else {
      final existing = _active[identity];
      if (existing != null) {
        if (rule.acknowledgeRequired) {
          // A fault that came and went between two glances at the screen is
          // still a fault somebody must see. It stays in the set, badged, until
          // [acknowledge].
          if (!existing.pendingAck) {
            existing.pendingAck = true;
            changed = true;
          }
        } else {
          _active.remove(identity);
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

  /// Acknowledges one `(uid, ruleIndex)` pair, clearing a [pendingAck] entry.
  ///
  /// The identity is `AckAlarmParams`'s, so 14-07's RPC has one call to make
  /// and no mapping to invent. Returns whether anything was acknowledged — an
  /// ack for an alarm that already cleared is not an error, it is a race an
  /// operator cannot avoid.
  bool acknowledge(String uid, int ruleIndex) {
    final removed = _active.remove((uid, ruleIndex));
    if (removed == null) return false;
    _publishActive();
    return true;
  }

  /// Rebuilds the payload, applies the cap and publishes at
  /// [relay.Quality.good].
  ///
  /// Entries go out **oldest onset first**, and that is also the order the cap
  /// keeps: on a plant-wide cascade the first thing that went wrong is the
  /// thing that explains the rest, so it is the last thing to drop off the
  /// list. Ties break on `(uid, ruleIndex)` so the payload is deterministic and
  /// an unchanged set never re-encodes differently.
  void _publishActive() {
    final all = [for (final entry in _active.values) entry.toEntry()]
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
