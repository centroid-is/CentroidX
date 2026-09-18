/// Four-band quality code carried with every value.
///
/// Band layout follows Ignition's proven model (good 0–255, uncertain
/// 256–511, bad 512–767, error 768–1023); the specific subcode numbers are
/// provisional until the open decision on mapping to OPC UA StatusCodes is
/// settled. The two states that must stay distinct:
/// [uncertainLastKnown] (holding the last known value — pipe may be fine)
/// vs [badStale] (past the freshness deadline — do not trust the number).
extension type const Quality(int code) {
  static const good = Quality(192);

  /// Write accepted, readback not yet observed (the in-flight window an
  /// operator must be able to see).
  static const goodWritePending = Quality(2);

  /// Current value unavailable; this is the last known value.
  static const uncertainLastKnown = Quality(257);

  /// Out-of-date past the requested freshness deadline.
  static const badStale = Quality(516);

  /// Upstream device link is down.
  static const badCommFault = Quality(522);

  /// Source produced NaN/±Infinity; the value field is null (JSON cannot
  /// carry it and Dart's jsonEncode throws — sanitized at the OPC UA
  /// boundary, see Sanitize).
  static const badNonFinite = Quality(524);

  /// Nothing has arrived for this key yet — the first batch is still in
  /// flight, or the page has just resynced.
  ///
  /// Uncertain rather than [errorConfig], which means the opposite thing:
  /// waiting *does* fix this. On the slow link this API was shaped for, every
  /// key on a 1500-key page passes through this state for one round trip, and
  /// reporting them all as configuration errors would teach operators that the
  /// one non-transient error code is transient.
  static const uncertainNotYetKnown = Quality(258);

  /// Source bytes were not valid in the configured string encoding;
  /// replacement characters were substituted.
  static const uncertainEncoding = Quality(260);

  /// A peer sent a code outside the four bands. This side cannot judge how
  /// far the value may be trusted, and "cannot judge" is exactly what the
  /// uncertain band means — not a band-less code that answers no to every
  /// question a widget can ask.
  static const uncertainUnknownCode = Quality(259);

  /// The key no longer exists upstream (tag deleted / renamed): a
  /// configuration error, not a transient — waiting will not fix it.
  static const errorConfig = Quality(770);

  /// A peer declared one type and sent a value of another (`{"type":
  /// "integer", "value": "five"}`). The leaf could not be decoded, so it
  /// reads null; the code is what stops that null looking like an absent
  /// reading. Also non-transient — the two ends disagree about the tag.
  static const errorTypeMismatch = Quality(771);

  /// Highest representable code. The four bands are 0–1023; anything above
  /// belongs to no band, so [worst] would never select it and every band
  /// predicate would answer false.
  static const int maxCode = 1023;

  /// Decodes a peer-supplied code.
  ///
  /// The wire is treated as hostile for exactly this class of hazard — the
  /// `1e999` decode poison is defused at the same boundary — and the quality
  /// code is the field that decides whether an operator may believe the
  /// number. The realistic trigger is a version-skewed peer or a proxy rather
  /// than an attacker; the consequence is the same either way.
  ///
  /// An absent (or explicitly null) code means good: quality is omitted from
  /// the wire when there is nothing to report.
  factory Quality.fromWire(Object? raw) {
    if (raw == null) return good;
    if (raw is! num) return uncertainUnknownCode;
    // `1e999` decodes to Infinity, and Infinity.toInt() throws.
    if (raw is double && !raw.isFinite) return uncertainUnknownCode;
    final code = raw.toInt();
    return code < 0 || code > maxCode ? uncertainUnknownCode : Quality(code);
  }

  bool get isGood => code >= 0 && code < 256;
  bool get isUncertain => code >= 256 && code < 512;
  bool get isBad => code >= 512 && code < 768;
  bool get isError => code >= 768 && code <= maxCode;

  /// Band severity for worst-wins composition (higher is worse).
  int get band => code >> 8;

  /// Worst-quality-wins: a derived value can never look healthier than its
  /// worst input.
  ///
  /// Ties are broken by position, so the first input of the worst band wins —
  /// callers pass the value's own quality first. Seeding the accumulator with
  /// [good] instead would discard every good-band input that is not literally
  /// [good]: `worst([goodWritePending])` used to answer `good`, silently
  /// dropping the badge an operator watches while a write is in flight.
  static Quality worst(Iterable<Quality> qualities) {
    Quality? result;
    for (final q in qualities) {
      if (result == null || q.band > result.band) result = q;
    }
    return result ?? good;
  }
}
