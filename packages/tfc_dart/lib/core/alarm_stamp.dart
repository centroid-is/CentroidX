/// When an alarm transition happened, and who says so.
///
/// One rule, one file, one function -- because the backend engine and the
/// direct-mode `AlarmMan` both stamp transitions, and two implementations of
/// "when did the stop start" would eventually disagree about a number an
/// operator is judged on.
///
/// The function takes plain `DateTime?`s rather than a value class, because
/// the two callers do not share one: the panel's values are
/// `package:open62541`'s `DynamicValue` (`sourceTimestamp`) and the pipe's are
/// `package:tfc_relay_protocol`'s (`sourceTime`). Neither type is imported
/// here, deliberately.
library;

/// Where the instant on an alarm row came from.
///
/// The distinction is the whole point of recording it: "the plant said so" and
/// "the backend guessed" are different facts, and a stop analysis that cannot
/// tell them apart is a stop analysis nobody can audit.
enum AlarmTsSource {
  /// Every value contributing to the evaluation carried a source timestamp,
  /// and the stamp is the newest of them.
  plant,

  /// At least one contributing value carried no source timestamp (or the
  /// evaluation bound nothing at all), so the stamp is the instant the backend
  /// received the evaluation.
  backendReceipt;

  /// The string persisted in `alarm_history.ts_source` and put on the wire.
  ///
  /// Spelled here and nowhere else. Every writer reads it off this getter, so
  /// renaming the enum constant cannot silently change what old rows mean.
  String get wireName => switch (this) {
        AlarmTsSource.plant => 'plant',
        AlarmTsSource.backendReceipt => 'backend_receipt',
      };
}

/// An instant, and the provenance that makes it interpretable.
final class AlarmStamp {
  const AlarmStamp({required this.at, required this.source});

  /// The instant the transition is recorded as having happened.
  final DateTime at;

  /// Whether [at] came from the plant or from the backend's own clock.
  final AlarmTsSource source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlarmStamp && other.at == at && other.source == source;

  @override
  int get hashCode => Object.hash(at, source);

  @override
  String toString() => 'AlarmStamp(${at.toIso8601String()}, ${source.wireName})';
}

/// The default beyond which a disagreement between the plant's clock and the
/// backend's is worth complaining about (CD-3).
const Duration kAlarmSkewWarnAfter = Duration(seconds: 60);

/// Resolves the instant to stamp a transition with, from the source timestamps
/// of the values bound in the evaluation that produced it.
///
/// **D-1 -- the newest, not the oldest.** An alarm rule binds every variable
/// its formula names, so one evaluation carries N source timestamps and must
/// choose one instant. A conjunction becomes true when the *last* of its
/// conditions does, which is the newest contributing instant. `min` would be
/// actively wrong: the bound set includes setpoints and constants that have not
/// moved since boot, so it would stamp an alarm that started this minute with
/// the instant of the last PLC restart. (Stated limitation, accepted: for a
/// disjunction the newest bound instant can be later than the true onset,
/// bounded by the update period of the operands that are not the cause.
/// Per-operand attribution is deferred idea DI-3.)
///
/// **D-2 -- a missing source timestamp is labelled, never silent.** If any
/// contributing value has no instant -- or the evaluation bound nothing at all,
/// as a literal-only formula does -- the stamp is [clock]'s reading and the
/// source is [AlarmTsSource.backendReceipt]. Refusing to stamp would mean
/// refusing to record the alarm, and PROJECT.md's core value is *never
/// silently*, not *never at all*: a labelled approximation an operator can see
/// and distrust beats a missing row.
///
/// **The clock is injected and read exactly once.** `DateTime.now` is supplied
/// at the composition root in `bin/main.dart` and nowhere else, which is why
/// the string `DateTime.now(` does not appear in this file. Two reads of a real
/// clock are two different instants, so the skew check and the fallback would
/// be judging against different receipts; the single local below makes that
/// unrepresentable, and a counting fake in the tests proves there is no second,
/// hidden reading.
///
/// **Skew is reported and never clamped.** When the winning source timestamp is
/// more than [skewWarnAfter] away from the receipt instant, [onSkew] is called
/// once with the signed difference (positive = the plant is ahead) and the
/// offending instant -- and the value is returned *unchanged*. Clamping to the
/// receipt would hide a real PLC clock fault, which is exactly the class of
/// thing this milestone exists to make visible; silently accepting it would
/// too.
AlarmStamp resolveAlarmStamp({
  required Iterable<DateTime?> sourceTimes,
  required DateTime Function() clock,
  Duration skewWarnAfter = kAlarmSkewWarnAfter,
  void Function(Duration skew, DateTime sourceTime)? onSkew,
}) {
  // Read once. See the doc above -- this local is load-bearing.
  final receipt = clock();

  DateTime? newest;
  var sawAny = false;
  for (final t in sourceTimes) {
    sawAny = true;
    if (t == null) {
      // One unknown poisons the set: a max over a set with an unknown member
      // is not a plant instant, however many known members it has.
      return AlarmStamp(at: receipt, source: AlarmTsSource.backendReceipt);
    }
    if (newest == null || t.isAfter(newest)) newest = t;
  }

  if (!sawAny || newest == null) {
    return AlarmStamp(at: receipt, source: AlarmTsSource.backendReceipt);
  }

  final skew = newest.difference(receipt);
  if (skew.abs() > skewWarnAfter) {
    onSkew?.call(skew, newest);
  }
  return AlarmStamp(at: newest, source: AlarmTsSource.plant);
}
