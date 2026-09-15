/// The two outbound size ceilings, and the arithmetic that produced them.
///
/// ## Why there has to be one at all
///
/// Every other ceiling in this gateway is on **ingress** or on **accumulated**
/// bytes. `ServerConfig.maxFrameBytes` is 1 MiB and stops an oversized
/// *request*. `ServerConfig.maxPendingBytes` is 8 MiB per session's priority
/// lane, and a response goes **into** that lane, **un-conflated**, drained only
/// by the tick. Nothing anywhere bounds what one answer may be before it is
/// built.
///
/// At SVN the collected keys sample every 5 s
/// (`svn-key-mappings.json`: `sample_interval_us: 5000000`) and retain for 365
/// days (`retention.drop_after_min: 525600`) — 6.3 million rows in one table.
/// A chart widening its window from a day to a month asks for 518 400 rows,
/// which at [measuredBytesPerSample] is about 21 MiB in a single JSON-RPC
/// response: two and a half whole session lanes. The overflow verdict is
/// `BufferDisconnect` → `close(4004)`, so the operator is told they
/// disconnected. They did not; they asked for too much.
///
/// ## Refuse, never truncate, and never clamp
///
/// There is no silent clamp in this file and none downstream of it. A
/// truncated series is "a line that stops in mid-air" and the operator reads
/// the truncation point as *now* (`data_services_contract.dart:196-199`), so
/// the over-limit answer is refused with [ResultTooLarge] naming the limit,
/// what was measured and the method that would answer the same question inside
/// it. `data_handlers.dart`'s `_sized` maps that to `INVALID_PARAMS` — a bad
/// *request*, which is what it is, rather than `handlerFailed` (-32011) which
/// the wire documents as possibly transient and a panel may retry forever.
///
/// ## The arithmetic, so a reader can redo it with a calculator
///
/// **[measuredBytesPerSample] = 44 B.** Measured, not inherited: the protocol's
/// own encoder (`timeseries.dart`) writes one sample as
/// `{"v":<value>,"t":<epoch ms>}` plus the `,` that joins it to the next, so
/// the fixed part is 24 B and the variable part is how the value prints. The
/// research's ~30 B estimate is what a *tidy* value costs. The plant does not
/// produce tidy values: every collected column is `double precision` and most
/// of what fills it arrives as a PLC `REAL`, a float32 widened to float64,
/// which prints its whole binary artifact. Freezer air at −18.1 °C is
/// `-18.100000381469727` and encodes to **44 B**; the corpus in
/// `read_limits_test.dart` means 35 B. The ceiling is derived from the worst,
/// because half of a noisy series is above the mean and a budget that half a
/// series exceeds is not a budget.
///
/// **[defaultMaxTimeseriesRows] = 40 000 rows.** The priority lane holds
/// `maxPendingBytes` = 8 MiB per session (`server_config.dart:131`, default at
/// `:336`) and is **not** conflated: a response sits there until the tick
/// drains it, alongside the value updates and notifications the same session
/// is receiving. Budgeting one response at a quarter of the lane leaves room
/// for a four-series chart plus ordinary traffic:
///
/// > 8 388 608 B ÷ 4 = 2 097 152 B; 2 097 152 ÷ 44 B = **47 662 rows**.
///
/// The default is set below that with headroom — **40 000**, which is
/// 1 760 000 B, **21 % of the whole lane**. The headroom is for the two things
/// the per-sample figure does not carry: the JSON-RPC envelope and the
/// per-series map key that a `queryTimeseriesDataMultiple` answer adds once per
/// series (a member-projected address, `<series>:<member>`, is the longest of
/// those). Neither is per-sample, which is why they are headroom rather than a
/// term in the division.
///
/// **What 40 000 rows means as a window**, because that sentence is what an
/// engineer reads when the refusal fires: at 5 s sampling it is **2.3 days**.
/// A day is 17 280 rows and is answered. A month is 518 400 rows, 13× the cap,
/// and is refused with `queryTimeseriesDataDownsampled` named as the fix. A
/// week (120 960 rows) is refused too, and correctly: a week of 5 s samples is
/// 121 000 points on a chart that has at most 1920 columns.
///
/// **[defaultMaxPreferenceBytes] = 1 MiB.** This one is not divided out of the
/// lane, it is *matched* to `maxFrameBytes`, and the argument is symmetry: a
/// value too large to be **written** over the pipe is also too large to be read
/// in bulk. One number to remember instead of two.
///
/// It also has to clear today's real data, and the honest figure is bigger than
/// the raw one. `svn-prefs-live-20260811.csv` is four rows and 675 890 B of
/// values, but `getAll` answers a **map that is then JSON-encoded**, and the
/// two big rows are themselves JSON documents whose every `"` becomes `\"`.
/// Measured: **754 707 B encoded**, +11.7 %. Against a 1 MiB cap that is a
/// margin of 293 869 B — the store fills **72 %** of the ceiling today.
///
/// That margin is thin and it shrinks, because `key_mappings` has one entry per
/// plant tag. The `getAll` cap is therefore the first of the two 1 MiB limits
/// the plant will reach: `key_mappings` alone encodes to 590 539 B, 56 % of
/// `maxFrameBytes`, so a bulk read breaks before a single write does. The fix
/// named in the refusal is the allow-list, which every real caller of `getAll`
/// should be passing anyway.
///
/// ## Overridable, and non-positive is refused
///
/// The composition root may pass its own. A zero or negative ceiling refuses
/// every query, and a gateway that refuses every query presents as "the
/// historian is empty" — so it is refused at construction, naming the field,
/// the way `ServerConfig._positive` does for the ceilings this one is derived
/// from.
library;

/// Ceilings on what one answer may be, applied before it is built.
final class ReadLimits {
  ReadLimits({
    this.maxTimeseriesRows = defaultMaxTimeseriesRows,
    this.maxPreferenceBytes = defaultMaxPreferenceBytes,
    this.maxHistoryViewRows = defaultMaxHistoryViewRows,
  }) {
    _positive('maxTimeseriesRows', maxTimeseriesRows);
    _positive('maxPreferenceBytes', maxPreferenceBytes);
    _positive('maxHistoryViewRows', maxHistoryViewRows);
  }

  /// Bytes one encoded sample costs, worst case, on this plant's data.
  ///
  /// See the library doc. Measured through `TimeseriesData.toJson()` and
  /// `jsonEncode`, and pinned by a case that re-measures it on every run: if
  /// the encoder changes, this constant moves and
  /// [defaultMaxTimeseriesRows] is recomputed in the same commit.
  static const int measuredBytesPerSample = 44;

  /// Rows one query may answer with, across all its series.
  ///
  /// 2 097 152 B ÷ 44 B = 47 662; set to 40 000 with headroom. 2.3 days at the
  /// plant's 5 s sampling — a day is answered, a month is refused.
  static const int defaultMaxTimeseriesRows = 40000;

  /// Bytes an encoded `getAll` answer may be.
  ///
  /// 1 MiB, matching `ServerConfig.maxFrameBytes`. Today's live store encodes
  /// to 754 707 B, which is 72 % of it.
  static const int defaultMaxPreferenceBytes = 1024 * 1024;

  /// Rows one history-view read may answer with.
  ///
  /// A `HistoryViewRecord` encodes to roughly [measuredBytesPerViewRow], so
  /// 5 000 of them is about 600 000 B — **7 % of the 8 MiB priority lane**, an
  /// order of magnitude below the timeseries budget because these rows are
  /// small and there is no legitimate reason for there to be many. SVN has
  /// dozens of saved charts; five thousand is far past any plant and still far
  /// short of the ~70 000 that makes `history.selectViews` an 8 MiB single
  /// entry, which is the number 10-REVIEW WR-05 measured.
  ///
  /// The same ceiling covers a view's keys, its graphs and its saved windows.
  /// One number rather than four, because they are the same hazard from the
  /// same door and four ceilings would be four things to keep in step for a
  /// distinction nobody can act on.
  static const int defaultMaxHistoryViewRows = 5000;

  /// Bytes one encoded `HistoryViewRecord` costs, near enough.
  ///
  /// An id, a name and two ISO timestamps. Used only to derive
  /// [defaultMaxHistoryViewRows] and stated so the division can be redone.
  static const int measuredBytesPerViewRow = 120;

  /// The row ceiling for one `queryTimeseriesData`, and for the **sum** across
  /// a `queryTimeseriesDataMultiple`.
  ///
  /// The sum and not per-table, because the multi-series path is the one a
  /// four-series chart takes and four tables each at the cap would produce four
  /// times the budget in one frame — which is the failure the budget exists to
  /// prevent, arrived at by obeying the limit four times.
  final int maxTimeseriesRows;

  /// The encoded-byte ceiling for `getAll` with no allow-list.
  ///
  /// **Encoded**, not the sum of the value lengths: the frame is what fills the
  /// lane and JSON escaping of a 518 KiB `key_mappings` string is not free.
  final int maxPreferenceBytes;

  /// The row ceiling for one history-view read — the picker, a view's keys, a
  /// view's graphs, a view's saved windows.
  ///
  /// **Caller-grown, unlike the other two** (10-REVIEW WR-05). A timeseries
  /// answer is bounded by how long the plant has been running; these four are
  /// bounded by how many rows a client has created, and until CR-03 the create
  /// side took no role at all. It still takes no *quota*: `historyCreateView`
  /// and `historyAddPeriod` are row factories in a table shared with the
  /// plant's own HMI, and an `operate` station in a loop is the whole
  /// amplification.
  final int maxHistoryViewRows;

  static void _positive(String name, int value) {
    if (value <= 0) {
      throw ArgumentError('$name ($value) must be positive: a non-positive '
          'ceiling refuses every query, and a gateway that refuses every '
          'query presents to an operator as "the historian is empty"');
    }
  }

  @override
  String toString() => 'ReadLimits(maxTimeseriesRows: $maxTimeseriesRows, '
      'maxPreferenceBytes: $maxPreferenceBytes, '
      'maxHistoryViewRows: $maxHistoryViewRows)';
}
