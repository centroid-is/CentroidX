/// One alarm rule, watched on backend main.
///
/// Takes its inputs from the pipe through [BackendValueSource] — the same seam,
/// and therefore the same freshness sweep and the same quality badges, a panel
/// reads — refuses to evaluate while any input is not good, emits only on a
/// change of the **boolean**, and stamps every transition from the plant.
///
/// **Deliberately not the engine.** Config, persistence, the active set and its
/// publication are 14-05's; this file is the evaluation core and nothing else.
/// A rule watcher that can be exercised against a fake value source with no
/// database and no pipe is what keeps the engine's own arms small, and the four
/// properties below are the ones worth isolating.
///
/// ## 1. Evaluation starts at [AlarmRuleWatcher.start], never at a listener
///
/// The defect this replaces is `alarm.dart:305` — `Alarm.onChange` hangs the
/// whole evaluation off a `StreamController.onListen`, by way of
/// `boolean_expression.dart:79`, so a rule is evaluated only while somebody is
/// watching its output. On a panel that is merely wasteful. On a headless
/// backend it is fatal: with no client attached, no rule is evaluated, no row
/// is written, and nothing anywhere reports that alarms are off. This class has
/// no stream and no listener gate at all — the sink is a callback supplied at
/// construction, so there is no "nobody is listening" state to be in. 14-08's
/// structural pin can only catch the `bin/main.dart` half of D-7; this is the
/// other half, and it is enforced by the shape of the class rather than by a
/// grep.
///
/// ## 2. A non-good input suspends the rule and HOLDS its state (D-3)
///
/// `Expression._evaluate` coerces a null value through `asDouble == 0.0` and
/// `asBool == false` (`boolean_expression.dart:329-344`), so `tank.temp < 5` on
/// an input that has not arrived evaluates **true**. That is not hypothetical:
/// 13-RIG-PROBE-EVIDENCE FIND-2 measured the first-ever subscriber to a key
/// receiving `uncertainNotYetKnown` with a null payload, and with 14-06 writing
/// a row on activation that window becomes a permanent false row in
/// `alarm_history` on every backend restart.
///
/// So a rule is evaluated only when **every** bound value's quality is in the
/// good band, and while it is not, the remembered boolean is held — not
/// activated, not deactivated. Holding rather than clearing matters on the
/// other edge too: deactivating on comms loss writes a false clear and closes a
/// real stop early, the exact under-reporting `alarmHistoryOverlaps`
/// (`alarm.dart:205-211`) exists to prevent.
///
/// The band, not the code. `Quality.isGood` is `0 <= code < 256`, and
/// `goodWritePending` (2) is in it: an operator's write being in flight is not
/// a reason to stop judging whether the plant is on fire. `Quality.worst`'s own
/// doc records the same trap from the other side.
///
/// The suspension is **observable and counted** ([suspended], [suspensions]) —
/// CD-6's exposure reads it — and logged once per entry into suspension, never
/// per tick. Project memory `logger-hot-path-stalls` measured `package:logger`
/// at seconds of lag when it is put on a per-value path (T-14-14).
///
/// ## 3. Transitions are on the boolean, never on the rendered string (P-3)
///
/// The `formatWithValues` render changes on every tag update of every bound
/// variable; the boolean does not. Comparing the string is the single most
/// likely way to fill `alarm_history` with one row per value change and drown
/// the real activation in it (T-14-13). The render is also computed **only on
/// the activation branch**, which is 14-02's hot-path property kept
/// (T-14-07): a deactivation carries no text because nothing displays one.
///
/// ## 4. Every transition is stamped by `resolveAlarmStamp`, over an injected
/// clock
///
/// [AlarmRuleWatcher.clock] is **required and has no default**. The default
/// belongs at the composition root in `bin/main.dart` and nowhere else (D-2),
/// which is why the string `DateTime.now(` does not appear in this file.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:open62541/open62541.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_dart/core/relay/relay_to_ua_value.dart';

/// A change in whether one alarm rule holds.
///
/// Immutable, and carrying everything a persister or a publisher needs without
/// asking a second question: which rule, which way, when, from where, and — on
/// activation only — what the formula read at the moment it fired.
final class AlarmRuleTransition {
  const AlarmRuleTransition({
    required this.ruleIndex,
    required this.active,
    required this.stamp,
    required this.isFirstEvaluation,
    this.expressionText,
  });

  /// Which rule of the owning alarm this is, per D-4's `(alarm_uid,
  /// rule_index)` identity.
  final int ruleIndex;

  /// Whether the rule now holds.
  final bool active;

  /// When the transition happened, and whether the plant or the backend says
  /// so. See `alarm_stamp.dart`.
  final AlarmStamp stamp;

  /// The formula rendered with the values it was evaluated against — **null on
  /// a deactivation**, on purpose.
  ///
  /// Only an active alarm displays its expression, and building the string
  /// walks `DynamicValue.toString()` per bound variable. Keeping it off the
  /// false branch is 14-02's measured property (T-14-07), and keeping it off
  /// the no-transition path entirely is P-3's.
  final String? expressionText;

  /// Whether this is the first evaluation this watcher ever completed.
  ///
  /// 14-06's restart reconciliation needs exactly this: an `alarm_history` row
  /// left open by a previous process is adopted or closed on the rule's first
  /// post-restart evaluation (D-4), and a first evaluation that came out
  /// `false` must still be reported or the open row stays open forever.
  final bool isFirstEvaluation;

  @override
  String toString() => 'AlarmRuleTransition(rule $ruleIndex, '
      'active: $active, $stamp'
      '${isFirstEvaluation ? ', first' : ''})';
}

/// Watches one alarm rule. See the library doc for why each property is here.
final class AlarmRuleWatcher {
  AlarmRuleWatcher({
    required BackendValueSource values,
    required ExpressionConfig expression,
    required this.ruleIndex,
    required DateTime Function() clock,
    required void Function(AlarmRuleTransition transition) onTransition,
    Duration skewWarnAfter = kAlarmSkewWarnAfter,
    String Function(String variable)? resolveKey,
    Logger? logger,
  })  : _values = values,
        _expression = expression,
        _clock = clock,
        _onTransition = onTransition,
        _skewWarnAfter = skewWarnAfter,
        _resolveKey = resolveKey ?? _identity,
        _logger = logger ?? Logger();

  static String _identity(String variable) => variable;

  final BackendValueSource _values;
  final ExpressionConfig _expression;
  final DateTime Function() _clock;
  final void Function(AlarmRuleTransition transition) _onTransition;
  final Duration _skewWarnAfter;
  final String Function(String variable) _resolveKey;
  final Logger _logger;

  /// Which rule of the owning alarm this watcher is. Copied onto every
  /// transition.
  final int ruleIndex;

  List<String> _variables = const [];
  List<String> _subscribedKeys = const [];
  StreamSubscription<List<StampedValue>>? _subscription;
  bool _started = false;
  bool _suspended = false;
  int _suspensions = 0;
  int _evaluations = 0;
  bool? _last;
  String? _refusal;
  int _refusalCount = 0;

  /// The variables the formula names, in first-appearance order, deduplicated.
  ///
  /// Empty until [start] has run, and empty forever if the formula was refused.
  List<String> get variables => _variables;

  /// The keys those variables resolved to, positionally aligned with
  /// [variables].
  ///
  /// Differs from [variables] only when a `resolveKey` was supplied — Seam 4's
  /// `$variable` substitution. SVN has zero alarms configured today so nothing
  /// uses it (assumption A5), and that is precisely why the hook is here: a
  /// resolver that does not exist is a resolver nobody adds later.
  List<String> get subscribedKeys => _subscribedKeys;

  /// Whether evaluation is currently suspended because an input is not good.
  bool get suspended => _suspended;

  /// How many times this rule has *entered* suspension.
  ///
  /// Entries, not ticks. A rule whose input is dead for an hour is one
  /// suspension, not one per publishing interval — the same reason the log line
  /// fires once (T-14-14).
  int get suspensions => _suspensions;

  /// How many evaluations have completed, i.e. passed the quality gate and
  /// produced a verdict.
  ///
  /// Counts evaluations, not transitions: arm 7's "ten updates, one transition"
  /// is only meaningful next to "and all ten were evaluated".
  int get evaluations => _evaluations;

  /// Why this rule is not being evaluated, or null when it is.
  ///
  /// Set exactly once, by a formula this codebase cannot parse. See [start].
  String? get refusal => _refusal;

  /// How many times [refusal] has been reported. At most one.
  int get refusalCount => _refusalCount;

  /// Resolves the rule's variables, subscribes to each, and begins evaluating.
  ///
  /// **This is the whole gate, and it is not `onListen`.** Called from the
  /// composition root after every worker is spawned (D-7's ordering: a
  /// subscribe for a key no worker owns costs no message and is silently
  /// dropped, so an engine started before the spawn loop would be subscribed to
  /// nothing, with no error). One `BackendValueSource.subscribe` is taken per
  /// variable and held for the life of the process — holding it is what makes
  /// the pipe issue `PipeSubscribe` upstream and what stops the last panel
  /// closing from dropping a monitored item an alarm depends on.
  ///
  /// **Never throws.** An operator-authored formula is untrusted input compiled
  /// on the backend, and `Expression._parseExpressionUncached` throws
  /// [ArgumentError] on one it cannot read. Today that would take
  /// `AlarmMan.create` — and with it the backend — down at boot, which is
  /// T-14-11. Here it is reported once by name, this watcher stays constructed
  /// and inert, and every other rule keeps running.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final List<String> variables;
    try {
      // extractVariables() parses, so this is where a malformed formula lands.
      // toSet() is a LinkedHashSet: order is first appearance, and a variable
      // named twice in one formula must not cost two subscriptions — the
      // refcount upstream is real.
      variables = _expression.value.extractVariables().toSet().toList();
    } catch (error, stack) {
      _refuse(error, stack);
      return;
    }

    _variables = List.unmodifiable(variables);
    _subscribedKeys =
        List.unmodifiable([for (final v in variables) _resolveKey(v)]);

    if (variables.isEmpty) {
      // A literal-only formula binds nothing. CombineLatestStream.list over an
      // empty list never emits, so wiring it would be a subscription to
      // silence; saying so here beats a reader wondering why.
      _logger.w('alarm rule $ruleIndex binds no variables '
          '("${_expression.value.formula}"); it will never be evaluated.');
      return;
    }

    final streams = [
      for (final key in _subscribedKeys) _values.subscribeStamped(key),
    ];

    _subscription = CombineLatestStream.list<StampedValue>(streams).listen(
      _onValues,
      onError: (Object error, StackTrace stack) {
        // A value source that errors is not a rule that is false. Report and
        // hold, exactly as the quality gate does.
        _logger.w('alarm rule $ruleIndex: its value source reported an error; '
            'the rule\'s state is held.', error: error, stackTrace: stack);
      },
    );
  }

  /// Releases the subscriptions this watcher holds.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// One combined emission: every bound variable, latest value each.
  ///
  /// `CombineLatestStream` does not emit until every input has produced once,
  /// which is where "nothing is evaluated before every variable has a value"
  /// comes from. That is free here and pinned by an arm anyway, so a later
  /// rewrite onto something else cannot lose it silently.
  void _onValues(List<StampedValue> bound) {
    // ---- 1. the quality gate (D-3). State is held; nothing is emitted.
    final refusedBy = <String>[];
    for (var i = 0; i < bound.length; i++) {
      if (!bound[i].value.quality.isGood) refusedBy.add(_variables[i]);
    }
    if (refusedBy.isNotEmpty) {
      if (!_suspended) {
        _suspended = true;
        _suspensions++;
        _logger.w('alarm rule $ruleIndex suspended: '
            '${refusedBy.join(', ')} not in the good band. '
            'Its state is held at ${_last ?? 'unevaluated'}.');
      }
      return;
    }

    // ---- 2. recovery, logged once for the same reason the suspension is.
    if (_suspended) {
      _suspended = false;
      _logger.i('alarm rule $ruleIndex resumed: every input is good again.');
    }

    // ---- 3. convert for the boolean math (DI-7) and evaluate.
    final bindings = <String, DynamicValue>{};
    for (var i = 0; i < bound.length; i++) {
      bindings[_variables[i]] =
          relayToUaValue(bound[i].value, name: _variables[i]);
    }

    final bool satisfied;
    try {
      satisfied = _expression.value.evaluate(bindings);
    } catch (error, stack) {
      _refuse(error, stack);
      return;
    }
    _evaluations++;

    // ---- 4. transition on the BOOLEAN (P-3), or on the first verdict at all.
    final isFirstEvaluation = _last == null;
    if (!isFirstEvaluation && _last == satisfied) return;
    _last = satisfied;

    // ---- 5. stamp from the plant (D-1/D-2), over the injected clock.
    final stamp = resolveAlarmStamp(
      // `sourceTimeIfSourced`, NOT `value.sourceTime`. Both are non-null for a
      // substituted instant and look identical; only the flag that rode the
      // pipe tells them apart, and a null here is what makes D-2 label the row
      // `backend_receipt` instead of vouching for a clock the plant never saw.
      sourceTimes: [for (final value in bound) value.sourceTimeIfSourced],
      clock: _clock,
      skewWarnAfter: _skewWarnAfter,
      onSkew: (skew, sourceTime) => _logger.w(
        'alarm rule $ruleIndex: the plant instant $sourceTime is '
        '${skew.inSeconds}s from this backend\'s clock. Written unchanged — '
        'clamping would hide a PLC clock fault.',
      ),
    );

    // ---- 6. render only on activation (T-14-07).
    _onTransition(AlarmRuleTransition(
      ruleIndex: ruleIndex,
      active: satisfied,
      stamp: stamp,
      isFirstEvaluation: isFirstEvaluation,
      expressionText:
          satisfied ? _expression.value.formatWithValues(bindings) : null,
    ));
  }

  /// Records that this rule cannot be evaluated, once, by name.
  void _refuse(Object error, StackTrace stack) {
    if (_refusal != null) return;
    _refusalCount++;
    _refusal = 'alarm rule $ruleIndex is NOT being evaluated: its formula '
        '"${_expression.value.formula}" could not be read ($error). '
        'Every other rule is unaffected.';
    _logger.e(_refusal, error: error, stackTrace: stack);
  }
}
