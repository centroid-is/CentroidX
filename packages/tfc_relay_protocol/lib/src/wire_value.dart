import 'dynamic_value.dart';
import 'quality.dart';
import 'sanitize.dart';

/// The largest epoch-millisecond magnitude `DateTime` can represent.
///
/// `DateTime.fromMillisecondsSinceEpoch` accepts −8640000000000000 through
/// +8640000000000000 **inclusive** and throws a `RangeError` on anything
/// outside it. That is ±100 000 000 days, i.e. the years 275760 BC to AD
/// 275760 — no plant clock reaches it and no skew produces it, so a `t` past
/// this bound is a gateway that is wrong, not a gateway that is early.
///
/// **`isFinite` is not a range check**, and that confusion is what produced
/// the gap this constant closes (WSH-08). The guard in [WireValue.fromJson]
/// was written against the `1e999` decode poison — which parses to `Infinity`
/// and makes `toInt()` throw — and it does that job. `1e17` is perfectly
/// finite, sails through it, and detonates one layer later inside
/// [WireValue.toDynamicValue]. One entry deep in a subscribe snapshot that
/// throw used to leave the whole decode and, through `ResyncEngine.onHello`,
/// put the panel in a permanent reconnect loop against a snapshot that would
/// never change.
const int maxRepresentableEpochMs = 8640000000000000;

/// Whether [t] is a source timestamp that can actually become a `DateTime`.
///
/// Both halves matter and neither implies the other: [num.isFinite] rejects
/// the `Infinity` a `1e999` on the wire decodes to, and the range rejects a
/// finite number `DateTime` refuses. See [maxRepresentableEpochMs].
bool isRepresentableEpochMs(Object? t) =>
    t is num &&
    t.isFinite &&
    t >= -maxRepresentableEpochMs &&
    t <= maxRepresentableEpochMs;

/// A value on the wire: `{"v": …}` with optional `"q"` (quality, omitted
/// when good) and `"t"` (source timestamp, UTC epoch ms, omitted in slim
/// pushes where the batch timestamp applies).
///
/// Construction goes through [WireValue.of], which sanitizes non-finite
/// doubles and drops a [t] outside `DateTime`'s range — there is deliberately
/// no way to build a WireValue that `jsonEncode` throws on, and since WSH-08
/// no way to build one that [toDynamicValue] throws on either.
final class WireValue {
  final Object? v;
  final Quality q;
  final int? t;

  const WireValue._(this.v, this.q, this.t);

  /// Sanitizing constructor: non-finite doubles anywhere in [value] become
  /// null and force quality to [Quality.badNonFinite] (worst-wins with
  /// [quality]).
  ///
  /// A [t] that `DateTime` cannot represent becomes **absent**, not clamped.
  /// A clamped timestamp is a lie about freshness, and freshness is the one
  /// thing this type exists to keep computable at the panel (see
  /// [toDynamicValue]); `null` is the type's own honest answer for "no usable
  /// timestamp", and every consumer already handles it.
  ///
  /// The range check lives **here**, in the one constructor every path funnels
  /// through, rather than at the decode. The class doc's promise is that there
  /// is no way to build a `WireValue` that `jsonEncode` throws on; this is the
  /// same promise for [toDynamicValue], and a promise that only holds for
  /// values that happened to arrive over a socket is not one.
  factory WireValue.of(Object? value,
      {Quality quality = Quality.good, int? t}) {
    final s = sanitize(value);
    final q = s.hadNonFinite
        ? Quality.worst([quality, Quality.badNonFinite])
        : quality;
    return WireValue._(s.value, q, isRepresentableEpochMs(t) ? t : null);
  }

  factory WireValue.fromJson(Map<String, Object?> json) {
    // Re-sanitize on decode: `1e999` in incoming JSON silently parses to
    // Infinity and would detonate on the next encode.
    final t = json['t'];
    return WireValue.of(
      json['v'],
      quality: Quality.fromWire(json['q']),
      // `isFinite` before `toInt()`: a `1e999` timestamp decodes to Infinity,
      // on which toInt() throws. This narrows the wire's `num` to an `int` and
      // nothing more — the **range** is [WireValue.of]'s business, because it
      // is a property of every WireValue and not only of a decoded one.
      t: t is num && t.isFinite ? t.toInt() : null,
    );
  }

  /// This value as the store type the rest of the client speaks.
  ///
  /// **The [t] half is the reason this exists.** Every decode site on the
  /// client used to build `DynamicValue(value: v, quality: q)` by hand and drop
  /// the timestamp on the floor, at three separate places — the subscribe
  /// snapshot, the update push and the `readFresh`/`readMany` answers. A value
  /// whose source time is gone cannot be aged by anything downstream: staleness
  /// stops being computable at the panel, `readFresh` cannot be shown to be
  /// newer than the cache it was called to bypass, and the freshness badge the
  /// operator reads becomes a property of when the frame arrived rather than of
  /// when the plant measured it.
  ///
  /// UTC on the way out, because [t] is epoch milliseconds and a local-time
  /// `DateTime` here would put the panel's timezone into a comparison against
  /// a timestamp the gateway stamped in UTC.
  DynamicValue toDynamicValue() => DynamicValue(
        value: v,
        quality: q,
        sourceTime:
            t == null ? null : DateTime.fromMillisecondsSinceEpoch(t!, isUtc: true),
      );

  Map<String, Object?> toJson() => {
        'v': v,
        if (q != Quality.good) 'q': q.code,
        if (t != null) 't': t,
      };

  @override
  bool operator ==(Object other) =>
      other is WireValue && other.v == v && other.q == q && other.t == t;

  @override
  int get hashCode => Object.hash(v, q, t);

  @override
  String toString() => 'WireValue(v: $v, q: ${q.code}${t == null ? '' : ', t: $t'})';
}
