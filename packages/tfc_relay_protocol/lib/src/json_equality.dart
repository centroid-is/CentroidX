/// Deep, key-order-insensitive equality over *raw decoded JSON* — the
/// fingerprint the gateway's idempotency window compares (05-RESEARCH §A.2).
///
/// One caller: the duplicate-cmd decision in `value_handlers.write`
/// (`value_handlers.dart:276`). A repeated cmd id carrying the same key and
/// the same value is one operator action arriving twice and must be answered
/// with the logged outcome; a repeated id carrying anything else stays a
/// refusal. That decision is only as honest as this comparison.
///
/// Three equalities already in reach were all wrong for it:
///
/// * `DynamicValue.operator ==` (`dynamic_value.dart:562-572`) compares
///   `quality`, `sourceTime`, `typeId`, `displayName` and more. A write
///   payload is raw decoded JSON (`messages.dart:400`) and carries none of
///   that, so using it would mean manufacturing metadata and then comparing
///   the metadata we just manufactured. Its private `_valuesEqual`
///   (`:705-722`) is typed for `DynamicValue` collections, not JSON.
/// * `jsonEncode(a) == jsonEncode(b)` makes key order significant. JSON object
///   order is not semantically meaningful, so a client that rebuilt its params
///   map in a different iteration order would have its own replay refused as
///   a new write.
/// * `package:collection`'s `DeepCollectionEquality` would do it, but
///   `tfc_relay_protocol` has zero runtime dependencies on purpose — the
///   Flutter app imports it, and that property is load-bearing for the app's
///   version solve. Twenty lines here are cheaper than a dependency there.
///
/// **The direction this errs in is deliberate.** A false "not equal" costs a
/// refusal, and a refusal on this path means "definitively no effect" — true
/// for the second write as well, so the operator is told something honest. A
/// false "equal" reports one write's outcome for a genuinely different write:
/// the screen says a setpoint was applied that nobody applied. So anything
/// unrecognised, mismatched, or merely suspicious answers `false`.
library;

/// Whether [a] and [b] are the same decoded JSON payload.
///
/// Maps compare regardless of key order; lists compare in order, because JSON
/// *array* order is meaningful where object order is not. Everything else
/// compares by value, with numbers held to their runtime type.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;

  if (a is Map) {
    if (b is! Map) return false;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      // `containsKey` and not `b[key] == null`: an absent key and a key
      // holding null are different instructions to the PLC (omit the field
      // vs. clear it), and equal lengths alone do not prove the same keys.
      if (!b.containsKey(entry.key)) return false;
      if (!jsonEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (b is Map) return false;

  if (a is List) {
    if (b is! List) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (b is List) return false;

  if (a is num) {
    if (b is! num) return false;
    // `1 == 1.0` is true in Dart across int and double. That is exactly the
    // confusion being refused: a DINT write of 1 and a REAL write of 1.0 are
    // two different writes to two differently typed tags, and the second must
    // not be answered with the first one's outcome. NaN falls out of `==`
    // as not-equal, which is the safe direction anyway (and `sanitize`
    // removes it before a payload ever reaches here).
    return a.runtimeType == b.runtimeType && a == b;
  }
  if (b is num) return false;

  // Leaves: String, bool, null, and anything unexpected. `==` on an
  // unexpected object is identity, which `identical` already ruled out — so
  // an unrecognised shape lands on false, per the err-toward-not-equal rule.
  return a == b;
}
