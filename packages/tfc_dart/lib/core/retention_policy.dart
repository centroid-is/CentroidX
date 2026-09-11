/// Retention policy — the value type, with no database behind it.
///
/// Split out of `database.dart` because `RetentionPolicy` is *configuration*:
/// it rides inside a `CollectEntry`, which rides inside a `KeyMappingEntry`,
/// which any client has to be able to parse. `database.dart` reaches drift,
/// postgres and `dart:io`; a client whose history arrives over the relay has
/// none of those and still has to read the same JSON.
///
/// `database.dart` exports this file, so nothing that already imported it
/// changes.
library;

import 'package:json_annotation/json_annotation.dart';
import 'package:logger/logger.dart';

import '../converter/duration_converter.dart';

part 'retention_policy.g.dart';

final _logger = Logger();

/// The longest retention anything may ask for: ten years.
///
/// Also the number the UI clamps to. It is not an arbitrary round figure — it
/// has to stay well below [kLegacyMicrosecondCutoffMinutes] so that no value an
/// operator can enter is ever mistaken for a legacy microsecond value. See the
/// cutoff's own documentation for the two populations involved.
const int kMaxRetentionDays = 3650;

/// The shortest retention that will be installed.
///
/// This guard exists to catch a **unit-conversion artifact**, not to second-
/// guess an operator who wants a short window. That distinction sets the
/// threshold, and it is why this is a minute rather than an hour.
///
/// The defect was a cliff in [durationFromMinutesTolerant]: a `drop_after_min`
/// above the cutoff is re-read as *microseconds*, so a retention typed in days
/// came back as a fraction of a minute. The artifacts it produces are bounded
/// and land firmly in the seconds range. With the cutoff at fifty years
/// (26 280 000 minutes), a stored value is only misread when the typed day
/// count exceeds 18 250, and the misread duration is `days × 1440`
/// *microseconds*:
///
///   * 18 251 days (just over the cutoff) -> 26.3 s
///   * 36 500 days (a hundred years, a plausible fat-finger) -> 52.6 s
///   * the originally reported 3651 days, under the old cutoff -> 5.26 s
///
/// Every one is under a minute, so a one-minute floor rejects all of them, and
/// zero and negative with them.
///
/// An hour was the first choice here and it was wrong: it rejected a ten-minute
/// retention, which is a perfectly reasonable window for a high-rate diagnostic
/// tag — a vibration or current trace sampled at 100 Hz — and which the
/// integration suite legitimately uses. "Nothing legitimate asks for it" was an
/// assumption, and the test suite was evidence against it.
///
/// Policy about what an operator may *choose* lives in the UI, which clamps the
/// retention field to 1..[kMaxRetentionDays] days. This constant is the
/// narrower backstop for values already on disk, and it should stay narrow:
/// every minute of headroom it takes away is a configuration somebody might
/// legitimately need.
const Duration kMinRetentionDuration = Duration(minutes: 1);

/// Tables the retention machinery must never be pointed at.
///
/// These are the access-control tables from schema v6. `audit_entry` is the
/// audit trail — append-only, never pruned — and `app_user` / `app_role` are
/// the identities the trail refers to; a swept role table turns every historic
/// row into a name with nothing behind it.
///
/// [Database.registerRetentionPolicy] refuses any of these by name. See that
/// method for why the refusal lives there rather than in a test.
const Set<String> kRetentionExemptTables = {
  'audit_entry',
  'app_user',
  'app_role',
};

// https://docs.tigerdata.com/api/latest/data-retention/add_retention_policy/
@JsonSerializable(explicitToJson: true)
class RetentionPolicy {
  @DurationMinutesConverterNonNull()
  @JsonKey(name: 'drop_after_min')
  final Duration
      dropAfter; // Chunks fully older than this interval when the policy is run are dropped
  @DurationMinutesConverter()
  @JsonKey(name: 'schedule_interval_min')
  final Duration?
      scheduleInterval; // The interval between the finish time of the last execution and the next start. Defaults to NULL.

  const RetentionPolicy({required this.dropAfter, this.scheduleInterval});

  /// Whether this policy is safe to install.
  ///
  /// A [dropAfter] under [kMinRetentionDuration] — including zero and negative,
  /// which the retention field accepted without complaint — deletes the history
  /// rather than bounding it.
  bool get isUsable => dropAfter >= kMinRetentionDuration;

  /// Reads a stored policy, capping a [dropAfter] that is longer than
  /// [kMaxRetentionDays].
  ///
  /// The cap matters for configs that are already on disk. A station that was
  /// given 3651 days wrote 5_257_440 into `drop_after_min`, one minute-count
  /// past the old microsecond cutoff, and every start since has read it back as
  /// 5.26 *seconds*. Moving the cutoff restores the operator's meaning — 3651
  /// days — and this cap then brings it inside the supported range instead of
  /// letting an out-of-range number back into the system.
  ///
  /// Values *below* the minimum are deliberately left alone rather than raised
  /// to some default. A retention nobody chose is a retention nobody can be
  /// held to; these are refused at the point of installation instead, which
  /// leaves whatever policy the table already has untouched and deletes
  /// nothing. See [isUsable] and [AppDatabase.updateRetentionPolicy].
  factory RetentionPolicy.fromJson(Map<String, dynamic> json) {
    final p = _$RetentionPolicyFromJson(json);
    const max = Duration(days: kMaxRetentionDays);
    if (p.dropAfter <= max) return p;
    _logger.w(
        'Retention of ${p.dropAfter.inDays} days is longer than the supported '
        'maximum of $kMaxRetentionDays days; using $kMaxRetentionDays days.');
    return RetentionPolicy(
        dropAfter: max, scheduleInterval: p.scheduleInterval);
  }

  Map<String, dynamic> toJson() => _$RetentionPolicyToJson(this);

  @override
  bool operator ==(Object other) {
    if (other is RetentionPolicy) {
      return dropAfter == other.dropAfter &&
          scheduleInterval == other.scheduleInterval;
    }
    return false;
  }

  @override
  int get hashCode => dropAfter.hashCode ^ scheduleInterval.hashCode;

  @override
  String toString() =>
      'RetentionPolicy(dropAfter: $dropAfter, scheduleInterval: $scheduleInterval)';
}
