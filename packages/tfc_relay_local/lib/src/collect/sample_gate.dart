/// `sample_expression` gating over the shipped [Expression] evaluator.
///
/// ## What is reused, and what deliberately is not
///
/// [Expression] — the parser, the operator table and `evaluate` — is reused
/// whole: the pure part is the part with the edge cases, and a second
/// operator table is a second place for `==` on a bool to drift from `==` on
/// a double. `Evaluator` itself is NOT reused: it takes the app's `StateMan`
/// (`boolean_expression.dart:41`) and returns `Future<Stream<…>>`-shaped
/// plumbing this package deliberately does not have. The binding below is
/// the whole replacement: subscribe each variable through [StateManApi] —
/// the ordinary path, again — combine the latest values, evaluate.
///
/// ## Unevaluable is FALSE
///
/// A gate variable that is missing, degraded, or of a shape the evaluator
/// cannot read makes the gate **false** — not true, and not "keep the last
/// verdict". A condition nobody can currently evaluate is a condition that
/// has not been met: the fail-safe direction, and the same instinct as the
/// runner's own quality gate. "The last known verdict" would sample straight
/// through an outage of the very variable the operator chose as the guard.
///
/// ## No `$`-substitution
///
/// `state_man_api.dart:26-31` froze substitution as client-local and 08-04's
/// router refuses a key containing `$` at the door, so an expression naming
/// a templated variable can never evaluate on the gateway. It is rejected at
/// [start] — which is also what bit the shipped collector
/// (`collector.dart:159-167` names the still-templated `$variable` as the
/// easy trigger for the respawn-loop incident).
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/boolean_expression.dart'
    show Expression, ExpressionConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// One entry's sampling condition, held current from the value path.
final class SampleGate {
  SampleGate({
    required ExpressionConfig expression,
    required StateManApi stateMan,
    void Function(bool open)? onTransition,
  })  : _expression = expression,
        _stateMan = stateMan,
        _onTransition = onTransition;

  final ExpressionConfig _expression;
  final StateManApi _stateMan;

  /// Called on every verdict change, after [isOpen] moved. The runner's
  /// change-mode hook: the gate going true samples the held value.
  final void Function(bool open)? _onTransition;

  final Map<String, StreamSubscription<DynamicValue>> _subscriptions =
      <String, StreamSubscription<DynamicValue>>{};
  final Map<String, DynamicValue> _latest = <String, DynamicValue>{};
  late final Set<String> _variables;

  bool _open = false;
  bool _stopped = false;

  /// The current verdict. False until every variable has a good-band,
  /// evaluable reading AND the expression holds.
  bool get isOpen => _open;

  /// Gate subscriptions held right now.
  int get liveSubscriptions => _subscriptions.length;

  /// Parses the expression and subscribes its variables.
  ///
  /// Throws [ArgumentError] — for the caller to record against the entry's
  /// key — when the formula cannot be parsed or names a `$` variable.
  /// Nothing is subscribed when this throws.
  void start() {
    // Both refusals happen BEFORE any subscription exists, so a rejected
    // entry leaves nothing behind to cancel.
    _variables = Set<String>.of(_expression.value.extractVariables());
    for (final variable in _variables) {
      if (variable.contains(r'$')) {
        throw ArgumentError.value(
            variable,
            'sample_expression',
            'names a templated variable, and substitution is client-local by '
                'frozen decision — the router refuses \$ keys, so this gate '
                'could never evaluate. Resolve the variable in the mapping');
      }
    }
    for (final variable in _variables) {
      _subscriptions[variable] = _stateMan.subscribe(variable).listen(
        (value) {
          _latest[variable] = value;
          _recompute();
        },
        // One variable's stream error makes the gate unevaluable — which
        // is false — and costs nothing else.
        onError: (Object error, StackTrace stack) {
          _latest.remove(variable);
          _recompute();
        },
        cancelOnError: false,
      );
    }
  }

  /// Cancels every variable subscription. No stream outlives this.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final subscription in _subscriptions.values.toList()) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  void _recompute() {
    final bindings = <String, ua.DynamicValue>{};
    var evaluable = true;
    for (final variable in _variables) {
      final held = _latest[variable];
      final converted = held == null ? null : _evaluableValueOf(held);
      if (converted == null) {
        evaluable = false;
        break;
      }
      bindings[variable] = converted;
    }
    bool open;
    if (!evaluable) {
      open = false;
    } else {
      try {
        open = _expression.value.evaluate(bindings);
      } catch (_) {
        // An expression the evaluator refuses at runtime is unevaluable,
        // and unevaluable is false.
        open = false;
      }
    }
    if (open == _open) return;
    _open = open;
    _onTransition?.call(open);
  }

  /// **The one conversion site between the two classes named
  /// `DynamicValue`** — the relay's, which carries a quality, and the
  /// OPC UA one the shipped operator table reads `asBool` / `asDouble` /
  /// `asString` from, which does not (08-RESEARCH §A.2's finding, not an
  /// accident). It exists as one named function because a second conversion
  /// site is where the quality check gets forgotten: the check lives HERE,
  /// and a value that fails it does not convert — the gate is unevaluable,
  /// and unevaluable is false.
  ///
  /// Only scalars convert. A struct or array as a gate variable has no
  /// meaning to the operator table's accessors, and coercing one would let
  /// `asBool`'s permissive parsing invent a verdict.
  static ua.DynamicValue? _evaluableValueOf(DynamicValue value) {
    if (value.quality.band != 0) return null;
    final raw = value.value;
    if (raw is! num && raw is! bool && raw is! String) return null;
    return ua.DynamicValue(value: raw);
  }
}
