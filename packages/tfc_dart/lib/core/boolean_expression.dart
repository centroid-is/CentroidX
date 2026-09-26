import 'dart:async';

import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';

import 'state_man_types.dart';

part 'boolean_expression.g.dart';

@JsonSerializable()
class ExpressionConfig {
  final Expression value;

  ExpressionConfig({required this.value});

  factory ExpressionConfig.fromJson(Map<String, dynamic> json) =>
      _$ExpressionConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ExpressionConfigToJson(this);

  @override
  String toString() {
    return 'ExpressionConfig(value: $value)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ExpressionConfig && value.formula == other.value.formula;
  }

  @override
  int get hashCode => value.formula.hashCode;

  static ExpressionConfig from(ExpressionConfig copy) {
    return ExpressionConfig(value: copy.value);
  }
}

/// One evaluation of an [ExpressionConfig]: the verdict, and the bindings it
/// was reached from.
///
/// Both halves travel on both branches. See [Evaluator.streamController] for
/// why the [bindings] are handed over unformatted, and why they are handed
/// over even when [satisfied] is false.
class Evaluation {
  const Evaluation({required this.satisfied, required this.bindings});

  /// Whether the expression held for [bindings].
  final bool satisfied;

  /// Every variable the formula names, bound to the value the evaluation saw.
  ///
  /// Carries whatever metadata the value type carries -- for
  /// `package:open62541`'s [DynamicValue] that includes `sourceTimestamp`,
  /// which is the instant the PLC says the reading was produced.
  final Map<String, DynamicValue> bindings;

  @override
  String toString() => 'Evaluation(satisfied: $satisfied, '
      'bindings: ${bindings.keys.toList()})';
}

class Evaluator {
  final StateMan stateMan;
  final ExpressionConfig expression;
  StreamSubscription? subscription;

  /// Each evaluation, as its verdict plus the variable bindings it was reached
  /// from -- on **both** branches.
  ///
  /// This used to carry the *formatted* string -- `formatWithValues(map)` --
  /// which meant every listener paid for it whether or not it wanted one.
  /// Formatting walks `DynamicValue.toString()` per bound variable, and for a
  /// struct that is `MapBase.mapToString` over every member; it ran on every
  /// tag update of every variable of every alarm rule, every collector sample
  /// condition and every conditional icon on screen. Two of those three
  /// callers throw the string away: [Collector] only asks whether the
  /// condition is non-null, and the icon asset only calls [eval]. The
  /// bindings are already in hand, so handing them over and letting [state]
  /// -- the one caller that wants text -- do the formatting costs nothing and
  /// takes the string builder off the path of the two that do not. That
  /// argument is unchanged, and [state] is still the only formatter.
  ///
  /// What changed is the **false** branch. It used to emit `null`: the verdict
  /// survived and the bindings did not. But a deactivation is a transition, a
  /// transition needs a timestamp, and the value that says *when* it happened
  /// -- the `sourceTimestamp` of the reading that stopped satisfying the
  /// expression -- lives in the bindings that were being discarded. Every
  /// clear was therefore stamped with the machine's own clock, silently, and
  /// no caller could have done better because nothing downstream of here could
  /// see the plant's instant. Emitting the bindings on both branches is what
  /// makes `resolveAlarmStamp` (see `alarm_stamp.dart`) possible at all.
  StreamController<Evaluation> streamController =
      StreamController<Evaluation>.broadcast();

  Evaluator({required this.stateMan, required this.expression});

  Stream<bool> eval() {
    return _evaluations()
        .map((evaluation) => evaluation.satisfied)
        .distinct()
        .startWith(false);
  }

  /// The satisfied expression rendered with its values, or null when it is
  /// not satisfied. Alarms show this text, so it is built here and only here.
  Stream<String?> state() {
    return _evaluations().map((evaluation) => evaluation.satisfied
        ? expression.value.formatWithValues(evaluation.bindings)
        : null);
  }

  /// Every evaluation, verdict and bindings alike.
  ///
  /// The surface an alarm engine needs: it must stamp a deactivation from the
  /// same plant instants an activation was stamped from, and only this stream
  /// carries them across the false branch.
  Stream<Evaluation> evaluations() => _evaluations();

  Stream<Evaluation> _evaluations() {
    streamController.onListen = () async {
      final variables = expression.value.extractVariables();
      final List<Stream<DynamicValue>> streams;
      try {
        streams = await Future.wait(variables.map((variable) async {
          final stream = await stateMan.subscribe(variable);
          return stream;
        }));
      } catch (error, stack) {
        // subscribe() throws synchronously for keys on a disabled server.
        // Surface it on the stream instead of letting it escape this async
        // onListen callback as an unhandled zone error.
        streamController.addError(error, stack);
        return;
      }

      subscription = CombineLatestStream.list<DynamicValue>(streams).listen(
        (values) {
          final map = Map.fromEntries(variables
              .asMap()
              .entries
              .map((e) => MapEntry(e.value, values[e.key])));
          // One add, both branches: the bindings go over whatever the verdict
          // is. See the streamController doc.
          streamController.add(Evaluation(
            satisfied: expression.value.evaluate(map),
            bindings: map,
          ));
        },
        onError: (error, stack) {
          streamController.addError(error, stack);
        },
      );
    };

    streamController.onCancel = () async {
      await subscription?.cancel();
      // streamController.close();
    };

    return streamController.stream;
  }

  void cancel() {
    subscription?.cancel();
    streamController.close();
  }
}

class Expression {
  final String formula;

  // Define operators as static constants
  static const operators = {
    'AND': 'Logical AND (both sides must be true)',
    'OR': 'Logical OR (either side can be true)',
    '<': 'Less than',
    '<=': 'Less than or equal',
    '>': 'Greater than',
    '>=': 'Greater than or equal',
    '==': 'Equal to',
    '!=': 'Not equal to',
  };
  static final expressionRegex = RegExp(r'(AND|OR|<=|>=|==|!=|<|>|\(|\))');

  Expression({required this.formula});

  /// Creates an Expression from JSON
  factory Expression.fromJson(Map<String, dynamic> json) {
    return Expression(formula: json['formula'] as String);
  }

  /// Converts the Expression to JSON
  Map<String, dynamic> toJson() => {'formula': formula};

  /// Validates if the expression looks like a valid boolean expression
  bool isValid() {
    late List<_Token> tokens;
    try {
      tokens = _parseExpression();
    } catch (_) {
      return false;
    }
    if (tokens.isEmpty) return false;

    int parenCount = 0;
    bool expectOperand = true;

    for (final token in tokens) {
      if (token.parenthesis == '(') {
        if (!expectOperand) return false;
        parenCount++;
        expectOperand = true;
      } else if (token.parenthesis == ')') {
        parenCount--;
        if (parenCount < 0 || expectOperand) return false;
        expectOperand = false;
      } else if (token.operator != null) {
        if (expectOperand) return false;
        expectOperand = true;
      } else if (token.value != null || token.literal != null) {
        if (!expectOperand) return false;
        expectOperand = false;
      }
    }

    if (parenCount != 0 || expectOperand) return false;
    return true;
  }

  /// Parses the expression and returns a list of variable names used in the expression
  List<String> extractVariables() {
    final tokens = _parseExpression();
    return tokens
        .where((token) => token.value != null)
        .map((token) => token.value!)
        .toList();
  }

  /// [formula] parsed into tokens, computed once.
  ///
  /// [formula] is final, so the token list cannot change -- yet every
  /// `evaluate()` and every `formatWithValues()` used to re-run the regex,
  /// the substring/trim per token and `parseLiteral`'s toLowerCase +
  /// `double.tryParse` + `int.tryParse`, on every tag update of every
  /// variable of every alarm rule, collector sample condition and conditional
  /// icon on screen. A parse that throws (an invalid formula) is not cached,
  /// so it still throws the same [ArgumentError] on every call.
  List<_Token>? _tokens;

  // List of (variable, operator, variable, operator, variable, ...)
  List<_Token> _parseExpression() => _tokens ??= _parseExpressionUncached();

  List<_Token> _parseExpressionUncached() {
    if (formula.isEmpty) return [];

    // Get all matches (both operators and the text between them)
    final matches = expressionRegex.allMatches(formula);
    final tokens = <_Token>[];
    var lastEnd = 0;

    for (final match in matches) {
      // Add the text before the operator (if any)
      final beforeOp = formula.substring(lastEnd, match.start).trim();
      if (beforeOp.isNotEmpty) {
        if (beforeOp.contains(' ') || beforeOp.contains('\t')) {
          throw ArgumentError('Variable name: "$beforeOp" contains whitespace');
        }
        if (parseLiteral(beforeOp) != null) {
          tokens.add(_Token(literal: beforeOp));
        } else {
          tokens.add(_Token(value: beforeOp));
        }
      }

      // Add the operator
      final operator = match.group(0);
      if (operator != null) {
        if (operator == '(' || operator == ')') {
          tokens.add(_Token(parenthesis: operator));
        } else {
          tokens.add(_Token(operator: operator));
        }
      }
      lastEnd = match.end;
    }

    // Add any remaining text after the last operator
    final remaining = formula.substring(lastEnd).trim();
    if (remaining.isNotEmpty) {
      if (remaining.contains(' ') || remaining.contains('\t')) {
        throw ArgumentError('Variable name: $remaining contains whitespace');
      }
      if (parseLiteral(remaining) != null) {
        tokens.add(_Token(literal: remaining));
      } else {
        tokens.add(_Token(value: remaining));
      }
    }

    // Validate that we have a valid pattern of variables and operators
    if (tokens.isEmpty) return [];

    return tokens;
  }

  /// Operator precedence, built once rather than as a fresh LinkedHashMap on
  /// every evaluation -- and evaluation happens per tag update.
  static const Map<String, int> _precedence = {
    'OR': 1,
    'AND': 2,
    '==': 3,
    '!=': 3,
    '<': 3,
    '<=': 3,
    '>': 3,
    '>=': 3,
  };

  DynamicValue _evaluate(
      List<_Token> tokens, Map<String, DynamicValue> variables) {
    // Convert infix tokens to RPN using the Shunting-yard algorithm
    final outputQueue = <_Token>[];
    final operatorStack = <_Token>[];

    for (final token in tokens) {
      if (token.value != null) {
        // Variable or literal
        outputQueue.add(token);
      } else if (token.literal != null) {
        // Literal
        outputQueue.add(token);
      } else if (token.operator != null) {
        // Operator
        while (operatorStack.isNotEmpty &&
            operatorStack.last.operator != null &&
            _precedence[operatorStack.last.operator]! >=
                _precedence[token.operator]!) {
          outputQueue.add(operatorStack.removeLast());
        }
        operatorStack.add(token);
      } else if (token.parenthesis == '(') {
        operatorStack.add(token);
      } else if (token.parenthesis == ')') {
        while (
            operatorStack.isNotEmpty && operatorStack.last.parenthesis != '(') {
          outputQueue.add(operatorStack.removeLast());
        }
        if (operatorStack.isNotEmpty && operatorStack.last.parenthesis == '(') {
          operatorStack.removeLast();
        } else {
          throw ArgumentError('Mismatched parentheses');
        }
      }
    }

    // Drain remaining operators
    while (operatorStack.isNotEmpty) {
      final top = operatorStack.removeLast();
      if (top.parenthesis != null) {
        throw ArgumentError('Mismatched parentheses');
      }
      outputQueue.add(top);
    }

    // Evaluate the RPN expression
    final evalStack = <DynamicValue>[];

    DynamicValue evaluateOp(DynamicValue lhs, String op, DynamicValue rhs) {
      switch (op) {
        case 'AND':
          return DynamicValue(value: lhs.asBool && rhs.asBool);
        case 'OR':
          return DynamicValue(value: lhs.asBool || rhs.asBool);
        case '<':
          return DynamicValue(value: lhs.asDouble < rhs.asDouble);
        case '<=':
          return DynamicValue(value: lhs.asDouble <= rhs.asDouble);
        case '>':
          return DynamicValue(value: lhs.asDouble > rhs.asDouble);
        case '>=':
          return DynamicValue(value: lhs.asDouble >= rhs.asDouble);
        case '==':
          {
            if (lhs.isString && rhs.isString) {
              return DynamicValue(value: lhs.asString == rhs.asString);
            }
            if (lhs.isBoolean && rhs.isBoolean) {
              return DynamicValue(value: lhs.asBool == rhs.asBool);
            }
            return DynamicValue(value: lhs.asDouble == rhs.asDouble);
          }
        case '!=':
          {
            if (lhs.isString && rhs.isString) {
              return DynamicValue(value: lhs.asString != rhs.asString);
            }
            if (lhs.isBoolean && rhs.isBoolean) {
              return DynamicValue(value: lhs.asBool != rhs.asBool);
            }
            return DynamicValue(value: lhs.asDouble != rhs.asDouble);
          }
        default:
          throw ArgumentError('Invalid operator $op');
      }
    }

    for (final tok in outputQueue) {
      if (tok.value != null) {
        final name = tok.value!;
        var val = variables[name];
        if (val == null) {
          throw ArgumentError('Variable $name not found');
        }
        evalStack.add(val);
      } else if (tok.literal != null) {
        evalStack.add(parseLiteral(tok.literal!)!);
      } else if (tok.operator != null) {
        if (evalStack.length < 2) {
          throw ArgumentError('Invalid expression');
        }
        final rhs = evalStack.removeLast();
        final lhs = evalStack.removeLast();
        final evaluation = evaluateOp(lhs, tok.operator!, rhs);
        evalStack.add(evaluation);
      }
    }

    if (evalStack.length != 1) {
      throw ArgumentError('Invalid expression');
    }
    return evalStack.first;
  }

  /// Evaluates the expression with given variable values
  bool evaluate(Map<String, DynamicValue> variables) {
    final tokens = _parseExpression();
    if (tokens.isEmpty) return false;
    final result = _evaluate(tokens, variables);
    return result.asBool;
  }

  /// Formats the expression with given variable values
  /// Example:
  /// formula: "A AND B"
  /// variables: {"A": true, "B": false}
  /// result: "A{true} AND B{false}"
  String formatWithValues(Map<String, DynamicValue> variables) {
    // Split the formula into tokens
    final tokens = _parseExpression();
    final result = StringBuffer();

    for (final token in tokens) {
      if (token.value != null) {
        final value = variables[token.value!];
        result.write('${token.value}{${value.toString().trim()}}');
      } else if (token.operator != null) {
        // For operators, add spaces around them
        result.write(' ${token.operator} ');
      } else if (token.parenthesis != null) {
        // For parentheses, add them as is
        result.write(token.parenthesis);
      } else if (token.literal != null) {
        // For literals, add them as is
        result.write('${token.literal}');
      }
    }

    return result.toString().trim();
  }

  DynamicValue? parseLiteral(String value) {
    // Handle boolean literals
    if (value.toLowerCase() == 'true') {
      return DynamicValue(value: true);
    }
    if (value.toLowerCase() == 'false') {
      return DynamicValue(value: false);
    }

    // Handle numeric literals
    final numValue = double.tryParse(value);
    if (numValue != null) {
      return DynamicValue(value: numValue);
    }

    // Handle string literals (quoted)
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return DynamicValue(value: value.substring(1, value.length - 1));
    }
    return null;
  }
}

class _Token {
  final String? value;
  final String? operator;
  final String? parenthesis;
  final String? literal;

  _Token({this.value, this.operator, this.parenthesis, this.literal});
}
