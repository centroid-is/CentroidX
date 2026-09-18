/// One historical sample: a value and the instant it was recorded.
///
/// Mirrors `TimeseriesData<T>` (`packages/tfc_dart/lib/core/database.dart:1189`)
/// field for field and keeps its positional constructor, so the existing chart
/// call sites read the same whether the samples came from a local database or
/// from the pipe.
///
/// Two things the local class never had to care about are enforced here,
/// because these now cross a socket:
///
///  * **Time is an absolute instant.** It crosses as UTC epoch milliseconds
///    (an `int`), the protocol package's one timestamp convention
///    (`WireValue.t`, `HelloResult.serverTime`, `SubTick.evaluatedAt`), and is
///    normalized to UTC on construction so `fromJson(toJson())` is `==` to the
///    original.
///  * **No non-finite double can reach `jsonEncode`.** A divide-by-zero in a
///    weigher rate calculation or an open-circuit 4–20 mA input would
///    otherwise throw and fail the whole batch for every connected client.
library;

import 'sanitize.dart';

/// A value observed at an instant.
final class TimeseriesData<T> {
  final T value;

  /// Always UTC. Construct with any [DateTime]; it is normalized here.
  final DateTime time;

  const TimeseriesData._(this.value, this.time);

  /// Sanitizing constructor — positional and verbatim, matching
  /// `database.dart:1198`.
  ///
  /// A non-finite double becomes `null` here, at construction, while the type
  /// still admits it. When [T] does not admit null (`TimeseriesData<double>`),
  /// nulling the field would throw, so the poison value stays in [value] and
  /// is nulled by [toJson] instead: neither construction nor encoding can ever
  /// throw on it. Use a nullable [T] when the source can produce non-finite
  /// numbers and the reader must see the gap.
  factory TimeseriesData(T value, DateTime time) {
    final sanitized = sanitize(value).value;
    return TimeseriesData._(
      sanitized == null && null is! T ? value : sanitized as T,
      _utc(time),
    );
  }

  /// Tolerant decode. Numbers are read through `num`, so an integral sample
  /// serialized as `7` still lands in a `TimeseriesData<double>`. Pass
  /// [decode] for values JSON cannot represent as a primitive (structures,
  /// enums, byte strings).
  factory TimeseriesData.fromJson(Map<String, Object?> json,
      {T Function(Object? raw)? decode}) {
    final raw = json['v'];
    return TimeseriesData(
      decode == null ? _coerce<T>(raw) : decode(raw),
      DateTime.fromMillisecondsSinceEpoch((json['t'] as num?)?.toInt() ?? 0,
          isUtc: true),
    );
  }

  Map<String, Object?> toJson() => {
        'v': sanitize(value).value,
        't': time.millisecondsSinceEpoch,
      };

  /// Equality through the same sanitizer the encoder uses, so it agrees with
  /// the wire representation.
  ///
  /// The constructor deliberately keeps a non-finite value when [T] does not
  /// admit null, and `NaN == NaN` is false — so a `TimeseriesData<double>`
  /// from a weigher divide-by-zero was not equal to itself while its hashCode
  /// stayed stable, which breaks the `Set`/`Map` contract and makes any
  /// de-duplication downstream silently keep every copy. Two samples that
  /// encode identically are the same sample.
  @override
  bool operator ==(Object other) =>
      other is TimeseriesData<T> &&
      other.time == time &&
      sanitize(other.value).value == sanitize(value).value;

  @override
  int get hashCode => Object.hash(sanitize(value).value, time);

  @override
  String toString() => 'TimeseriesData(value: $value, time: $time)';
}

/// UTC at millisecond precision — the precision the wire carries — so a
/// decoded sample is `==` to the one that was encoded.
DateTime _utc(DateTime t) =>
    DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch, isUtc: true);

/// JSON has one number type; Dart has two. Widen or narrow to whatever [T]
/// asks for, and leave anything else to the cast so the failure names the
/// type that was expected.
T _coerce<T>(Object? raw) {
  if (raw is T) return raw;
  if (raw is num) {
    if (0.0 is T) return raw.toDouble() as T;
    if (0 is T) return raw.toInt() as T;
  }
  return raw as T;
}
