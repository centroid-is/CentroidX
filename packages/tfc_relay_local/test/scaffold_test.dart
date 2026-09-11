/// Proof that the open62541 pin is REAL, not a smoke test.
///
/// `pubspec.lock` is gitignored in this repository, so nothing on disk records
/// which open62541 a build actually resolved. If the `dependency_overrides`
/// entry is ever dropped, mistyped, or quietly "cleaned up", `dart pub get`
/// does not complain — it just resolves the pub.dev release, and this package
/// silently loses three shipped fixes (open62541_dart #91, #92, #97) plus the
/// StatusCode and sourceTimestamp work the gateway's entire quality story rests
/// on. The failure would surface later, on a plant, as values that look fine.
///
/// This file makes that failure LOUD and IMMEDIATE: it names
/// `DynamicValue.statusCode` and `DynamicValue.sourceTimestamp`, which do not
/// exist on the pub release or on the old `dev` SHA. Against the wrong pin it
/// does not fail an assertion — it fails to COMPILE, naming the missing
/// members. A mystery becomes a red test.
///
/// Keep it that way. Anything added here must keep referencing both new
/// members directly; replacing them with a version string or a `contains`
/// check would turn a compile-time guarantee into a runtime hope.
@Tags(['meta'])
library;

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';

void main() {
  group('the open62541 pin', () {
    test('carries the quality and source-time fields the gateway needs', () {
      // Referencing the members at all is the load-bearing half of this test.
      // The assertions are the second half: they pin the DEFAULT, which is the
      // one thing the gateway must be able to rely on when it decides whether
      // a value has a quality or merely has no claim attached.
      final fresh = DynamicValue();

      expect(
        fresh.statusCode,
        isNull,
        reason: 'a value that never came from a server carries no quality; if '
            'this ever read 0 the gateway would publish "the PLC says this is '
            'good" about a number no PLC has ever seen',
      );
      expect(
        fresh.sourceTimestamp,
        isNull,
        reason: 'and no source time; a plausible instant here would become a '
            'freshness promise that nothing upstream ever made',
      );
    });

    test('carries them through the copy constructor too', () {
      // Anti-vacuity for the case above: null on a fresh value proves nothing
      // if the fields cannot hold anything else. This arm shows they are real
      // storage, and that DynamicValue.from — which is on every path a value
      // takes through the binding — does not drop them.
      final stamped = DynamicValue(value: 1)
        ..statusCode = 0x80020000
        ..sourceTimestamp = DateTime.utc(2026, 9, 1);

      final copy = DynamicValue.from(stamped);

      expect(
        copy.statusCode,
        0x80020000,
        reason: 'a copy that dropped the code would silently upgrade a Bad '
            'reading to "no claim", and no claim is what the gateway reads as '
            '"not from a server at all"',
      );
      expect(
        copy.sourceTimestamp,
        DateTime.utc(2026, 9, 1),
        reason: 'a copy that dropped the source time would make the adapter '
            'substitute arrival time without knowing it had to',
      );
    });
  });
}
