@Tags(['meta'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// A future that will never complete, for the "the implementation went silent"
/// cases. Nothing ever completes this completer.
Future<T> neverCompletes<T>() => Completer<T>().future;

/// Stands in for the implementation under test. The helpers are generic, so
/// the meta-tests need nothing more than an object to pass through.
final class _DummyApi {
  const _DummyApi();
}

void main() {
  group('within', () {
    test('returns the value when the future is already done', () async {
      expect(await within(Future.value(7), 'x'), 7);
    });

    test('turns silence into a TestFailure naming the property and budget',
        () async {
      await expectLater(
        () => within(
          neverCompletes<int>(),
          'the first value for a subscribed key',
          budget: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<TestFailure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('the first value for a subscribed key'),
              contains('50 ms'),
            ),
          ),
        ),
      );
    });

    test('the silence failure is a TestFailure, not a TimeoutException',
        () async {
      // This is the whole point of the helper: a bare `.timeout()` yields a
      // TimeoutException, which the meta-assertion cannot tell apart from an
      // implementation that genuinely threw one.
      Object? caught;
      try {
        await within(neverCompletes<int>(), 'a value',
            budget: const Duration(milliseconds: 20));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<TestFailure>());
      expect(caught, isNot(isA<TimeoutException>()));
    });

    test('lets a genuine error through unchanged — it converts silence only',
        () async {
      await expectLater(
        () => within(Future<int>.error(StateError('boom')), 'x'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('boom'))),
      );
    });

    test('fails at roughly the budget, not at the test-runner timeout',
        () async {
      final sw = Stopwatch()..start();
      try {
        await within(neverCompletes<int>(), 'a value',
            budget: const Duration(milliseconds: 50));
      } catch (_) {
        // The assertion below is about when, not what.
      }
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('expectContractViolation', () {
    test('completes when the check reports the violation', () async {
      await expectContractViolation<_DummyApi>(
        (api) async => fail('subscribe dropped the key'),
        const _DummyApi(),
      );
    });

    test('fails when the check PASSED a deliberately broken implementation',
        () async {
      await expectLater(
        () => expectContractViolation<_DummyApi>(
          (api) async {},
          const _DummyApi(),
        ),
        throwsA(
          isA<TestFailure>().having(
            (f) => f.message,
            'message',
            contains('PASSED a deliberately broken implementation'),
          ),
        ),
      );
    });

    test('fails within its budget when the check hangs instead of failing',
        () async {
      final sw = Stopwatch()..start();
      await expectLater(
        () => expectContractViolation<_DummyApi>(
          (api) => neverCompletes<void>(),
          const _DummyApi(),
          budget: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<TestFailure>()
              .having((f) => f.message, 'message', contains('hung')),
        ),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a raw error reads differently from a hang and names its type',
        () async {
      // A check that throws instead of reporting through expect/fail produces
      // a failure message with no property name in it. That is a defect in the
      // check, and the meta-assertion has to say so rather than accept it.
      await expectLater(
        () => expectContractViolation<_DummyApi>(
          (api) async => throw StateError('boom'),
          const _DummyApi(),
        ),
        throwsA(
          isA<TestFailure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('StateError'),
              contains('through expect'),
              isNot(contains('hung')),
            ),
          ),
        ),
      );
    });
  });

  group('expectUnreachableMethod', () {
    test('a method-not-found failure is what the excuse is for', () async {
      await expectUnreachableMethod(
        'a property behind a handler nobody has written',
        () async => throw StateError('JSON-RPC error -32601: Unknown method.'),
      );
    });

    test('the code has to stand on its own, not merely appear', () async {
      // 04-REVIEW IN-03. A bare `contains` excused any failure whose text
      // happened to hold the digits — inside a nested `data` echo of the
      // request, inside a larger number, inside a timestamp. An excused
      // failure is worse than a red one: the report shows the gap everyone
      // already knew about, and the new defect leaves no trace at all.
      await expectLater(
        () => expectUnreachableMethod(
          'a property behind a handler nobody has written',
          () async => throw StateError('the value was -326013 at t=1732601000'),
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('a check that starts passing is reported, not quietly excused',
        () async {
      await expectLater(
        () => expectUnreachableMethod(
            'a property whose handler has just landed', () async {}),
        throwsA(isA<TestFailure>().having(
            (f) => f.message, 'message', contains('delete this check'))),
      );
    });
  });
}
