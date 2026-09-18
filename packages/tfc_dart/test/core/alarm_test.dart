import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

void main() {
  group('Alarm expression', () {
    test('Alarm expression simple AND', () {
      final expression = Expression(formula: 'A AND B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: true), 'B': DynamicValue(value: true)}),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false)
          }),
          isFalse);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true)
          }),
          isFalse);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false)
          }),
          isFalse);
    });
    test('Alarm expression simple OR', () {
      final expression = Expression(formula: 'A OR B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: true), 'B': DynamicValue(value: true)}),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false)
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true)
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false)
          }),
          isFalse);
    });
    test('Alarm expression AND OR', () {
      final expression = Expression(formula: 'A AND B OR C');
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: true)
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: true)
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: false)
          }),
          isFalse);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: true)
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: false)
          }),
          isFalse);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: true)
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: false)
          }),
          isFalse);
    });
    test('Alarm expression AND OR AND', () {
      final expression = Expression(formula: 'A AND B OR C AND D');

      // Test case 1: All true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: true)
          }),
          isTrue);

      // Test case 2: A AND B true, C AND D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: false)
          }),
          isTrue);

      // Test case 3: A AND B false, C AND D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: true)
          }),
          isTrue);

      // Test case 4: A true, B false, C true, D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: true)
          }),
          isTrue);

      // Test case 5: A true, B false, C true, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: false)
          }),
          isFalse);

      // Test case 6: A true, B false, C false, D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: true)
          }),
          isFalse);

      // Test case 7: A true, B false, C false, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: false)
          }),
          isFalse);

      // Test case 8: A false, B true, C true, D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: true)
          }),
          isTrue);

      // Test case 9: A false, B true, C true, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: false)
          }),
          isFalse);

      // Test case 10: A false, B true, C false, D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: true)
          }),
          isFalse);

      // Test case 11: A false, B true, C false, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: false)
          }),
          isFalse);

      // Test case 12: A false, B false, C true, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: false)
          }),
          isFalse);

      // Test case 13: A false, B false, C false, D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: true)
          }),
          isFalse);

      // Test case 14: A false, B false, C false, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: false),
            'B': DynamicValue(value: false),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: false)
          }),
          isFalse);

      // Test case 15: A true, B true, C true, D false
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: true),
            'D': DynamicValue(value: false)
          }),
          isTrue);

      // Test case 16: A true, B true, C false, D true
      expect(
          expression.evaluate({
            'A': DynamicValue(value: true),
            'B': DynamicValue(value: true),
            'C': DynamicValue(value: false),
            'D': DynamicValue(value: true)
          }),
          isTrue);
    });
    test('Alarm expression <', () {
      final expression = Expression(formula: 'A < B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 2)}),
          isTrue);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 1)}),
          isFalse);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 0)}),
          isFalse);
    });
    test('Alarm expression <=', () {
      final expression = Expression(formula: 'A <= B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 2)}),
          isTrue);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 1)}),
          isTrue);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 0)}),
          isFalse);
    });
    test('Alarm expression >', () {
      final expression = Expression(formula: 'A > B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 2)}),
          isFalse);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 1)}),
          isFalse);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 0)}),
          isTrue);
    });
    test('Alarm expression >=', () {
      final expression = Expression(formula: 'A >= B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 2)}),
          isFalse);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 1)}),
          isTrue);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 0)}),
          isTrue);
    });
    test('Alarm expression ==', () {
      final expression = Expression(formula: 'A == B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 1)}),
          isTrue);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 2)}),
          isFalse);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 0)}),
          isFalse);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: "foo"),
            'B': DynamicValue(value: "bar")
          }),
          isFalse);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: "foo"),
            'B': DynamicValue(value: "foo")
          }),
          isTrue);
    });
    test('Alarm expression !=', () {
      final expression = Expression(formula: 'A != B');
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 1)}),
          isFalse);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 2)}),
          isTrue);
      expect(
          expression.evaluate(
              {'A': DynamicValue(value: 1), 'B': DynamicValue(value: 0)}),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: "foo"),
            'B': DynamicValue(value: "bar")
          }),
          isTrue);
      expect(
          expression.evaluate({
            'A': DynamicValue(value: "foo"),
            'B': DynamicValue(value: "foo")
          }),
          isFalse);
    });
    test('Simple parentheses: A AND (B OR C)', () {
      final expression = Expression(formula: 'A AND (B OR C)');
      expect(
        expression.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: true),
        }),
        isTrue,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: false),
          'B': DynamicValue(value: true),
          'C': DynamicValue(value: true),
        }),
        isFalse,
      );
    });

    test('Simple grouping: (A AND B) OR C', () {
      final expression = Expression(formula: '(A AND B) OR C');
      expect(
        expression.evaluate({
          'A': DynamicValue(value: false),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: false),
        }),
        isFalse,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: true),
          'C': DynamicValue(value: false),
        }),
        isTrue,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: false),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: true),
        }),
        isTrue,
      );
    });

    test('Nested parentheses: A AND (B OR (C AND D))', () {
      final expression = Expression(formula: 'A AND (B OR (C AND D))');
      expect(
        expression.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: true),
          'D': DynamicValue(value: true),
        }),
        isTrue,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: true),
          'D': DynamicValue(value: false),
        }),
        isFalse,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: false),
          'B': DynamicValue(value: true),
          'C': DynamicValue(value: false),
          'D': DynamicValue(value: true),
        }),
        isFalse,
      );
    });

    test('Deep nested: ((A OR B) AND (C OR D)) OR E', () {
      final expression = Expression(formula: '((A OR B) AND (C OR D)) OR E');
      expect(
        expression.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: false),
          'D': DynamicValue(value: true),
          'E': DynamicValue(value: false),
        }),
        isTrue,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: false),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: false),
          'D': DynamicValue(value: false),
          'E': DynamicValue(value: false),
        }),
        isFalse,
      );
      expect(
        expression.evaluate({
          'A': DynamicValue(value: false),
          'B': DynamicValue(value: false),
          'C': DynamicValue(value: false),
          'D': DynamicValue(value: false),
          'E': DynamicValue(value: true),
        }),
        isTrue,
      );
    });

    test('Mismatched parentheses should throw', () {
      final bad1 = Expression(formula: 'A AND (B OR C');
      expect(
        () => bad1.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: true),
          'C': DynamicValue(value: true),
        }),
        throwsArgumentError,
      );
      final bad2 = Expression(formula: 'A AND B) OR C');
      expect(
        () => bad2.evaluate({
          'A': DynamicValue(value: true),
          'B': DynamicValue(value: true),
          'C': DynamicValue(value: true),
        }),
        throwsArgumentError,
      );
    });

    test('Is expression valid', () {
      // Valid simple expressions
      expect(Expression(formula: 'A AND B').isValid(), isTrue);
      expect(Expression(formula: '(A AND B)').isValid(), isTrue);
      expect(Expression(formula: 'A AND (B OR C)').isValid(), isTrue);
      expect(Expression(formula: 'A').isValid(), isTrue);

      // More complex valid expressions
      expect(Expression(formula: '((A))').isValid(), isTrue);
      expect(Expression(formula: '(A)').isValid(), isTrue);
      expect(Expression(formula: '(A OR B) AND C').isValid(), isTrue);
      expect(Expression(formula: 'A OR (B AND C)').isValid(), isTrue);
      expect(
          Expression(formula: 'A AND (B AND (C OR D)) OR E').isValid(), isTrue);
      expect(Expression(formula: 'A OR B AND C').isValid(), isTrue);
      expect(Expression(formula: 'A AND B AND C OR D OR E').isValid(), isTrue);

      // Invalid expressions
      expect(Expression(formula: '').isValid(), isFalse);
      expect(Expression(formula: 'AND A B').isValid(), isFalse);
      expect(Expression(formula: 'A AND B)').isValid(), isFalse);
      expect(Expression(formula: '(A AND B').isValid(), isFalse);
      expect(Expression(formula: '()').isValid(), isFalse);
      expect(Expression(formula: ')(').isValid(), isFalse);
      expect(Expression(formula: '(A AND)').isValid(), isFalse);
      expect(Expression(formula: '(AND A B)').isValid(), isFalse);
      expect(Expression(formula: '(AND A OR B)').isValid(), isFalse);
      expect(Expression(formula: 'A OR OR B').isValid(), isFalse);
      expect(Expression(formula: 'A AND B C').isValid(), isFalse);
      expect(Expression(formula: 'A (B OR C)').isValid(), isFalse);
      expect(Expression(formula: '(A OR B) C').isValid(), isFalse);
      expect(Expression(formula: '((A AND B)').isValid(), isFalse);
      expect(Expression(formula: '(A AND B))').isValid(), isFalse);

      expect(
          Expression(
                  formula:
                      'Line1.running == true AND Line1.Conveyor1.InPlace == false')
              .isValid(),
          isTrue);
      ;
    });
  });

  group('Alarm expression formatWithValues', () {
    test('Format with values', () {
      final expression = Expression(formula: 'A AND B');
      final formatted = expression.formatWithValues(
          {'A': DynamicValue(value: true), 'B': DynamicValue(value: false)});
      expect(formatted, 'A{true} AND B{false}');
    });
    test('Format with values complex expressions', () {
      // Test 1: Complex nested expression with mixed types
      final expression1 = Expression(formula: '(A AND B) OR (C AND D)');
      final formatted1 = expression1.formatWithValues({
        'A': DynamicValue(value: true),
        'B': DynamicValue(value: false),
        'C': DynamicValue(value: 42),
        'D': DynamicValue(value: "test")
      });
      expect(formatted1, '(A{true} AND B{false}) OR (C{42} AND D{test})');

      // Test 2: Deep nested expression with comparison operators
      final expression2 =
          Expression(formula: '((A > B) AND (C <= D)) OR (E == F)');
      final formatted2 = expression2.formatWithValues({
        'A': DynamicValue(value: 100),
        'B': DynamicValue(value: 50),
        'C': DynamicValue(value: 75),
        'D': DynamicValue(value: 75),
        'E': DynamicValue(value: "status"),
        'F': DynamicValue(value: "status")
      });
      expect(formatted2,
          '((A{100} > B{50}) AND (C{75} <= D{75})) OR (E{status} == F{status})');

      // Test 3: Multiple comparison operators with different types
      final expression3 = Expression(formula: 'A != B AND C > D OR E < F');
      final formatted3 = expression3.formatWithValues({
        'A': DynamicValue(value: "active"),
        'B': DynamicValue(value: "inactive"),
        'C': DynamicValue(value: 200),
        'D': DynamicValue(value: 150),
        'E': DynamicValue(value: 25),
        'F': DynamicValue(value: 50)
      });
      expect(formatted3,
          'A{active} != B{inactive} AND C{200} > D{150} OR E{25} < F{50}');

      // Test 4: Complex boolean expression with multiple levels
      final expression4 =
          Expression(formula: 'A AND (B OR (C AND D)) OR (E AND F)');
      final formatted4 = expression4.formatWithValues({
        'A': DynamicValue(value: true),
        'B': DynamicValue(value: false),
        'C': DynamicValue(value: true),
        'D': DynamicValue(value: false),
        'E': DynamicValue(value: true),
        'F': DynamicValue(value: true)
      });
      expect(formatted4,
          'A{true} AND (B{false} OR (C{true} AND D{false})) OR (E{true} AND F{true})');

      // Test 5: Expression with all operator types
      final expression5 =
          Expression(formula: 'A < B AND C > D OR E <= F AND G >= H');
      final formatted5 = expression5.formatWithValues({
        'A': DynamicValue(value: 10),
        'B': DynamicValue(value: 20),
        'C': DynamicValue(value: 30),
        'D': DynamicValue(value: 25),
        'E': DynamicValue(value: 40),
        'F': DynamicValue(value: 40),
        'G': DynamicValue(value: 50),
        'H': DynamicValue(value: 45)
      });
      expect(formatted5,
          'A{10} < B{20} AND C{30} > D{25} OR E{40} <= F{40} AND G{50} >= H{45}');
    });

    test('Format with values with literal values', () {
      final expression = Expression(formula: 'A == "test" AND B == 42');
      final formatted = expression.formatWithValues(
          {'A': DynamicValue(value: "test"), 'B': DynamicValue(value: 42)});
      expect(formatted, 'A{test} == "test" AND B{42} == 42');
    });
  });

  test('Alarm expression with literal values', () {
    var expression = Expression(formula: 'A == true');
    expect(expression.evaluate({'A': DynamicValue(value: true)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: false)}), isFalse);
    expression = Expression(formula: 'A == True');
    expect(expression.evaluate({'A': DynamicValue(value: true)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: false)}), isFalse);
    expression = Expression(formula: 'A == TRUE');
    expect(expression.evaluate({'A': DynamicValue(value: true)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: false)}), isFalse);
    expression = Expression(formula: 'A == TRuE');
    expect(expression.evaluate({'A': DynamicValue(value: true)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: false)}), isFalse);
    expression = Expression(formula: 'A == TrUE');
    expect(expression.evaluate({'A': DynamicValue(value: true)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: false)}), isFalse);
  });
  test('Alarm expression with numeric literals', () {
    // Test integer literals
    var expression = Expression(formula: 'A == 42');
    expect(expression.evaluate({'A': DynamicValue(value: 42)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: 43)}), isFalse);

    // Test negative numbers
    expression = Expression(formula: 'A == -42');
    expect(expression.evaluate({'A': DynamicValue(value: -42)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: 42)}), isFalse);

    // Test decimal numbers
    expression = Expression(formula: 'A == 3.14');
    expect(expression.evaluate({'A': DynamicValue(value: 3.14)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: 3.15)}), isFalse);

    // Test numeric comparisons
    expression = Expression(formula: 'A > 100');
    expect(expression.evaluate({'A': DynamicValue(value: 101)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: 100)}), isFalse);
    expect(expression.evaluate({'A': DynamicValue(value: 99)}), isFalse);

    // Test multiple numeric comparisons
    expression = Expression(formula: 'A > 100 AND B < 50');
    expect(
        expression.evaluate(
            {'A': DynamicValue(value: 101), 'B': DynamicValue(value: 49)}),
        isTrue);
    expect(
        expression.evaluate(
            {'A': DynamicValue(value: 101), 'B': DynamicValue(value: 51)}),
        isFalse);

    // Test numeric ranges
    expression = Expression(formula: 'A >= 0 AND A <= 100');
    expect(expression.evaluate({'A': DynamicValue(value: 50)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: 0)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: 100)}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: -1)}), isFalse);
    expect(expression.evaluate({'A': DynamicValue(value: 101)}), isFalse);

    // Test complex numeric expressions
    expression = Expression(formula: '(A > 100 OR B < 50) AND C == 0');
    expect(
        expression.evaluate({
          'A': DynamicValue(value: 101),
          'B': DynamicValue(value: 51),
          'C': DynamicValue(value: 0)
        }),
        isTrue);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: 99),
          'B': DynamicValue(value: 49),
          'C': DynamicValue(value: 0)
        }),
        isTrue);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: 101),
          'B': DynamicValue(value: 51),
          'C': DynamicValue(value: 1)
        }),
        isFalse);
  });
  test('Alarm expression with string literals', () {
    var expression = Expression(formula: 'A == "test"');
    expect(expression.evaluate({'A': DynamicValue(value: "test")}), isTrue);
    expect(expression.evaluate({'A': DynamicValue(value: "other")}), isFalse);
    expression = Expression(formula: 'A != "test"');
    expect(expression.evaluate({'A': DynamicValue(value: "test")}), isFalse);
    expect(expression.evaluate({'A': DynamicValue(value: "other")}), isTrue);
    expression = Expression(formula: 'A == "test" AND B == "other"');
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "test"),
          'B': DynamicValue(value: "other")
        }),
        isTrue);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "test"),
          'B': DynamicValue(value: "test")
        }),
        isFalse);

    expression = Expression(formula: 'A == "test" OR B == "other"');
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "test"),
          'B': DynamicValue(value: "other")
        }),
        isTrue);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "test"),
          'B': DynamicValue(value: "test")
        }),
        isTrue);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "other"),
          'B': DynamicValue(value: "test")
        }),
        isFalse);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "other"),
          'B': DynamicValue(value: "other")
        }),
        isTrue);

    expression = Expression(formula: 'A == \'test\' AND B == "other"');
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "test"),
          'B': DynamicValue(value: "other")
        }),
        isTrue);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "test"),
          'B': DynamicValue(value: "test")
        }),
        isFalse);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "other"),
          'B': DynamicValue(value: "test")
        }),
        isFalse);
    expect(
        expression.evaluate({
          'A': DynamicValue(value: "other"),
          'B': DynamicValue(value: "other")
        }),
        isFalse);
  });
  group('Alarm expression extractVariables', () {
    test('Literal not in variables', () {
      final expression = Expression(
          formula:
              'Line1.running == true AND Line1.Conveyor1.InPlace == false');
      expect(expression.extractVariables(),
          ['Line1.running', 'Line1.Conveyor1.InPlace']);
    });
  });
}
