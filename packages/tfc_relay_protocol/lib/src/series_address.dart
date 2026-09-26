/// How a wire series name is spelled, and the contract that maps it to a
/// table.
///
/// ## `<series>` or `<series>:<member>`, and why
///
/// A recorded value is not always a scalar. The collector samples chosen
/// members out of a structured value — an `FB_Sensor`'s `ST_Sensor_HMI`
/// struct, say — and stores every sample as one row in one table, keyed by
/// the member paths (`collector.dart:33-36`, `sample_members`). A chart wants
/// one line out of that row.
///
/// 10-CONTEXT ruling 2 settles how: **the gateway projects one scalar series
/// per member**, addressed `<series>:<member>`, resolved where the table→key
/// mapping already lives. The wire's sample type stays `num`, and the bytes
/// are proportional to what the chart actually asked for. This matches the
/// app's own convention — `GraphSeriesConfig.member` is how a chart already
/// picks a member out of a shared table — so a ported call site reads the
/// same.
///
/// Option B, sending whole rows as `Object?`, was rejected: it breaks every
/// chart's arithmetic (the samples stop being numbers) and ships members
/// nobody asked for over a link whose whole purpose is not to.
///
/// ## Refuse, do not guess
///
/// A series name is a client-supplied string that ends up choosing a physical
/// table. Every shape that is not exactly one of the two above is a
/// [FormatException] — the decode-boundary convention this package already
/// uses — and never a best-effort split. Guessing at `a:b:c` answers a
/// different question than the one asked, and the asker cannot tell.
library;

/// A series name as the wire spells it: a series, and optionally one member of
/// it.
///
/// Construct with [SeriesAddress.parse]; there is no unchecked constructor,
/// because the only way this type is ever built is out of a string somebody
/// sent.
final class SeriesAddress {
  const SeriesAddress._(this.series, this.member);

  /// The series the client named — the plant-side name, not the physical
  /// table. [SeriesResolver] maps it.
  ///
  /// Dots inside it belong to the plant key (`AREAnn.DEVnn.SUBnn`) and are not
  /// a separator this grammar owns.
  final String series;

  /// The one member of a structured sample the caller wants, or null for the
  /// series as recorded.
  final String? member;

  /// Parses [wireName], refusing anything that is not `<series>` or
  /// `<series>:<member>`.
  ///
  /// Throws a [FormatException] naming [wireName] on: more than one colon (a
  /// member cannot itself be addressed), an empty series, or an empty member.
  /// A trailing colon is a caller that meant to select a member and did not,
  /// and answering the whole series instead would ship exactly the members
  /// ruling 2 refuses to ship.
  factory SeriesAddress.parse(String wireName) {
    final parts = wireName.split(':');
    if (parts.length > 2) {
      throw FormatException(
          'a series name may select at most one member, so it carries at most '
          'one colon; `$wireName` carries ${parts.length - 1}. A member of a '
          'member is not addressable on this wire',
          wireName);
    }
    final series = parts.first;
    if (series.isEmpty) {
      throw FormatException(
          'a series name cannot be empty; `$wireName` names no series',
          wireName);
    }
    if (parts.length == 1) return SeriesAddress._(series, null);
    final member = parts[1];
    if (member.isEmpty) {
      throw FormatException(
          'a colon selects a member, so `$wireName` ends mid-selection. Drop '
          'the colon to ask for the series as recorded',
          wireName);
    }
    return SeriesAddress._(series, member);
  }

  /// The wire spelling — `parse(a.toString()) == a` for both shapes.
  @override
  String toString() => member == null ? series : '$series:$member';

  @override
  bool operator ==(Object other) =>
      other is SeriesAddress &&
      other.series == series &&
      other.member == member;

  @override
  int get hashCode => Object.hash(series, member);
}

/// One wire series name, resolved: the physical table, the member, the plant
/// key.
///
/// Three answers in one object on purpose. A caller that could obtain the
/// table without the plant key would be a caller that can read history for a
/// tag the identity may not see — `canSee` is asked about the key, and the
/// timeseries methods are keyed by table
/// (`policy_state_man.dart:267-271` states the problem this shape answers).
/// Travelling together is what makes forgetting the check a compile error
/// rather than a policy hole.
final class ResolvedSeries {
  const ResolvedSeries({
    required this.table,
    required this.member,
    required this.plantKey,
  });

  /// The physical table the samples are in — the `gw_`-prefixed name for a
  /// gateway-collected series, the app collector's own for the tables it still
  /// writes.
  final String table;

  /// The member the caller selected, or null for the series as recorded.
  /// Carried through from [SeriesAddress.member].
  final String? member;

  /// The plant key this table records, which is the name `canSee` is asked
  /// about.
  final String plantKey;

  @override
  String toString() =>
      'ResolvedSeries($table${member == null ? '' : ':$member'} → $plantKey)';
}

/// The mapping between what a client names and what the database holds.
///
/// Three lookups, one direction each, and **null always means refuse**:
///
///  * [resolve] — a wire series name to the table, member and plant key
///    behind it.
///  * [keyForTable] — a physical table to the plant key it records.
///  * [keyForNode] — a browse node id to the plant key it is.
///
/// Fail-closed is the rule, not a default: 10-CONTEXT amendment 6 says an
/// unmappable table is **not served** until it is mapped. A caller that read
/// null as "no mapping, so no policy applies" would serve history for a tag
/// the identity may not see, which is the enumeration the hiding rule exists
/// to prevent.
///
/// **There is deliberately no implementation of this in `lib/`** — not even an
/// identity one that returns its argument. A permissive default is a
/// production hole with a test's name on it: it ships, something binds to it
/// because it is the only one available, and the fail-closed rule above
/// becomes advice. The only way to get a resolver is to supply one. 10-07
/// builds the real one over 8b's `CollectionPlan`, which already names both
/// the plant key and the table; fixtures get theirs from
/// `tfc_relay_server/test/support/`.
abstract interface class SeriesResolver {
  /// The table, member and plant key behind [wireName], or null to refuse.
  ///
  /// [wireName] is parsed as a [SeriesAddress], so a malformed name throws a
  /// [FormatException] rather than resolving to null — "you spelled it wrong"
  /// and "there is no such series" are two different facts and the caller acts
  /// on them differently.
  ResolvedSeries? resolve(String wireName);

  /// The plant key [table] records, or null to refuse.
  String? keyForTable(String table);

  /// The plant key [nodeId] is, or null to refuse.
  String? keyForNode(String nodeId);
}
