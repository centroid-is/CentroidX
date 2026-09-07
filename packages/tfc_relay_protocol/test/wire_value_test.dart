/// `WireValue`'s timestamp, and the range `isFinite` does not check.
///
/// Source: WEBSOCKET-REVIEW-FINDINGS S7 (WSH-08). `WireValue.fromJson` guards
/// `t` with `t is num && t.isFinite`, which was written against the `1e999`
/// decode poison and does its job there. It is **not** a range check:
/// `1e17` is perfectly finite, sails through, and then
/// `toDynamicValue`'s `DateTime.fromMillisecondsSinceEpoch` refuses it with an
/// `ArgumentError` — because `DateTime` stops at ±8.64e15 ms.
///
/// One entry deep in a subscribe snapshot that `ArgumentError` used to leave
/// the whole decode and, through `ResyncEngine.onHello`, put the panel in a
/// permanent reconnect loop. The client-side containment is
/// `tfc_relay_client/test/poisoned_snapshot_test.dart`; this file pins the
/// protocol-side half, which is that the type tells the truth about a
/// timestamp it cannot represent rather than detonating on it.
///
/// The existing `WireValue` arms live in `sanitize_test.dart` beside the
/// sanitizer they are about. These are a separate concern — range, not
/// finiteness — and are kept apart on purpose so a future reader does not read
/// "it is sanitized" as "it is in range".
library;

import 'dart:convert';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('a source timestamp DateTime cannot represent', () {
    test('1e17 is finite, out of range, and decodes as an absent timestamp',
        () {
      final decoded = jsonDecode('{"v":41.5,"t":1e17}') as Map<String, Object?>;
      final wv = WireValue.fromJson(decoded);

      // The reading survives. An unusable timestamp is a reason to lose the
      // timestamp, never the value.
      expect(wv.v, 41.5);
      expect(wv.t, isNull,
          reason: 'absent, not clamped: a clamped timestamp is a lie about '
              'freshness, and null is this type\'s own honest answer');
      expect(wv.toDynamicValue().sourceTime, isNull);
      // The arm that was red before the fix: this threw an ArgumentError.
      expect(() => wv.toDynamicValue(), returnsNormally);
      expect(wv.toDynamicValue().value, 41.5);
    });

    test('the negative side is refused the same way', () {
      final wv = WireValue.fromJson(
          jsonDecode('{"v":1,"t":-1e17}') as Map<String, Object?>);
      expect(wv.t, isNull);
      expect(() => wv.toDynamicValue(), returnsNormally);
    });

    test('8.64e15 — the boundary — is IN range and is kept', () {
      // Decided deliberately: the bound is inclusive, because
      // `DateTime.fromMillisecondsSinceEpoch(8640000000000000)` is a
      // `DateTime` Dart is perfectly happy to build. Rejecting it would
      // discard a timestamp the platform can represent, which is a different
      // lie from the one this change is fixing.
      final wv = WireValue.fromJson(
          jsonDecode('{"v":1,"t":8.64e15}') as Map<String, Object?>);
      expect(wv.t, 8640000000000000);
      expect(wv.toDynamicValue().sourceTime,
          DateTime.fromMillisecondsSinceEpoch(8640000000000000, isUtc: true));
    });

    test('one millisecond past the boundary is out', () {
      final wv = WireValue.fromJson(
          const {'v': 1, 't': 8640000000000001});
      expect(wv.t, isNull);
      expect(() => wv.toDynamicValue(), returnsNormally);
    });

    test('ordinary timestamps are untouched', () {
      // Anti-vacuity for the whole group: a range check that rejected
      // everything would satisfy every arm above.
      final wv = WireValue.fromJson(const {'v': 7, 't': 1735689600000});
      expect(wv.t, 1735689600000);
      expect(wv.toDynamicValue().sourceTime,
          DateTime.fromMillisecondsSinceEpoch(1735689600000, isUtc: true));
    });

    test('1e999 stays refused — isFinite is still doing its own job', () {
      final wv = WireValue.fromJson(
          jsonDecode('{"v":1,"t":1e999}') as Map<String, Object?>);
      expect(wv.t, isNull);
    });
  });
}
