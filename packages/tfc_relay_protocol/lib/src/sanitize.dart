/// Non-finite sanitization — the F28 / forum-survey rule.
///
/// Dart's jsonEncode THROWS on NaN and ±Infinity (it does not emit null the
/// way JavaScript does), so one open-circuit 4–20 mA input or a
/// divide-by-zero in a weigher rate calculation would fail the entire batch
/// for every client. And `1e999` silently *decodes* to Infinity, so poison
/// values can enter from outside too. Every value crosses [sanitize] before
/// it is placed in a frame.
library;

/// Result of sanitizing one value tree.
typedef SanitizeResult = ({Object? value, bool hadNonFinite});

/// Deepest structure [sanitize] — and [DynamicValue] construction, which uses
/// the same bound — will walk.
///
/// Both are recursive, and both run on the gateway over structures the
/// *upstream* controls: the OPC UA / Modbus / M2400 converters hand them
/// whatever shape the device declared. 64 is far deeper than any real PLC
/// structure. A self-referential list from a converter hits the same wall,
/// which is what keeps it from being an immediate stack overflow — and a
/// stack overflow on the gateway is every client's problem, not one tag's.
const int maxValueDepth = 64;

/// Returns [value] with every non-finite double replaced by `null`,
/// reporting whether any replacement happened (so the caller can attach
/// [Quality.badNonFinite]). Finite values pass through untouched; lists and
/// maps are rebuilt only if they contain an offender.
SanitizeResult sanitize(Object? value) {
  var hadNonFinite = false;

  Object? walk(Object? v, int depth) {
    if (depth > maxValueDepth) {
      throw ArgumentError.value(
          value,
          'value',
          'nested deeper than $maxValueDepth, or self-referential — either '
              'way this walk does not terminate on the stack it has');
    }
    if (v is double && !v.isFinite) {
      hadNonFinite = true;
      return null;
    }
    if (v is List) {
      List<Object?>? copy;
      for (var i = 0; i < v.length; i++) {
        final w = walk(v[i], depth + 1);
        if (!identical(w, v[i])) {
          copy ??= List<Object?>.of(v);
        }
        if (copy != null) copy[i] = w;
      }
      return copy ?? v;
    }
    if (v is Map) {
      // Key type preserved rather than forced to String: the OPC UA and M2400
      // converters do produce int-keyed maps, and rebuilding through
      // `cast<String, Object?>()` threw only for a map that actually
      // contained an offender — so the function worked for a given shape
      // right up until the day a weigher divided by zero.
      Map<Object?, Object?>? copy;
      for (final entry in v.entries) {
        final w = walk(entry.value, depth + 1);
        if (!identical(w, entry.value)) copy ??= Map<Object?, Object?>.of(v);
        if (copy != null) copy[entry.key] = w;
      }
      return copy ?? v;
    }
    return v;
  }

  final sanitized = walk(value, 1);
  return (value: sanitized, hadNonFinite: hadNonFinite);
}
