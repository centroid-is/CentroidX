/// The per-link health producer: every PLC's condition as an ordinary tag.
///
/// ## There is no health method
///
/// The absence is a recorded decision, not an omission (design §4.7, HLTH-01).
/// These names are subscribable exactly like a temperature — same store, same
/// quality codes, same widgets — which is what makes a health indicator
/// something an integrator can drop on a page rather than something the client
/// has to grow an API for. Every name is built by [PipeKeys]; nothing here
/// spells one.
///
/// ## Seeded at construction
///
/// Every key exists before anything can subscribe, for
/// `fake_state_man.dart:616-622`'s reason, quoted because it is the whole
/// argument: *"a health indicator that reads unknown until the first fault
/// tells an operator nothing at the moment they most need telling."* A page
/// bound to a key the store has never heard of shows a blank, and a blank is
/// also what a mistyped binding looks like.
///
/// ## Never a plausible zero, and never a plausible false
///
/// `cert_health_state_man.dart:115-126` is the rule and it generalises: a
/// reading this producer cannot make is a **null** value under
/// [Quality.errorConfig]. Never `0`, never `false`, never the epoch instant.
///
///  * `connected: false` on a link nobody has asked about yet sends an
///    engineer to a PLC that is fine. "Not known yet" and "known to be down"
///    are different things on a wall.
///  * `birth_count: 0` on an unasked link reads as a PLC that has never come up
///    since the gateway started, which is a specific and alarming claim.
///  * `last_death_at: 0` renders as 1 January 1970.
///
/// The inverse holds too, and it is why `last_error` and `last_death_at` are
/// **null under good quality** once the link has been asked: the gateway
/// looked, and the answer is "nothing". That is knowledge, and an empty string
/// would be a value a page could render into a blank box.
///
/// ## Event-driven, with one gauge re-derived on read
///
/// This producer starts no clock. Six of the seven keys change only on a link
/// event, which is exactly why they are exempt from the freshness sweep
/// (HLTH-02) — a value that changes once a shift is always older than any
/// freshness deadline. The seventh, `data_age_ms`, is a gauge: it advances with
/// elapsed time whether or not anything happens — on a monotonic anchor and
/// never on the RTC (08-REVIEW CR-02; see [PipeHealth._elapsedMs]).
///
/// A gauge written only on events would freeze at the last event's reading,
/// which is the stale-but-plausible number this project exists to prevent
/// wearing a health key's clothes. It is handled the way 08-05 handles
/// freshness and for the same stated reason (`state_man.dart:1000`,
/// `:1005-1031`): the stored value is written on events, and [judge]
/// **re-derives it synchronously on read** without writing. So a diagnostics
/// poll is always correct, a read is still not an event, and no timer was
/// added to a package whose timer count is a pinned number.
///
/// What that leaves is a *pushed* `data_age_ms` that advances only when
/// something happens on its link. The slow-cadence refresh belongs with the
/// per-session gauges of 08-12 — `effective_hz`, `egress_kbps`,
/// `event_loop_lag_ms` all need one tick between them — and is recorded here
/// rather than built, because a second repeating clock in this package is a
/// decision somebody should make on purpose.
///
/// ## The app's shipped equivalent
///
/// `@conn/<alias>/<field>` (`conn_meta.dart:30-64`) answers almost exactly this
/// question already: its `reconnectCount` is `birth_count` under another name
/// and its `uptimeSec` is `last_death_at` inverted. That overlap is a good sign
/// — the Sparkplug `bdSeq` adoption is landing on something the plant already
/// wanted. 08-CONTEXT ruling 4: the gateway serves the reserved namespace only,
/// and an alias layer over it is a reversible later addition if page churn
/// proves painful. Recorded, not built.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'epoch.dart';
import 'upstream_link.dart';

/// Publishes one key set per configured upstream link.
///
/// Owned by `LocalStateMan`, which hands it the same private [ValueStore] every
/// other value in the gateway lives in — the health keys are not a second
/// store, a second cache or a second API.
final class PipeHealth {
  PipeHealth({
    required Iterable<UpstreamLink> links,
    required ValueStore store,
    required int Function() elapsedMs,
  })  : _links = <String, UpstreamLink>{
          for (final link in links) link.alias: link,
        },
        _store = store,
        _elapsedMs = elapsedMs,
        // The historian's six keys are seeded by the same producer, at the
        // same moment, for the same reason as the per-link ones: every key
        // exists before anything can subscribe, and a gateway that does not
        // collect serves them as null under errorConfig — never false,
        // never zero (8b-03).
        collect = CollectHealth(store: store, elapsedMs: elapsedMs) {
    _seed();
  }

  /// The collection historian's keys, published through this producer so
  /// they arrive by the same route as the upstream ones (8b-03). The
  /// collection runner drives it; nothing else writes these keys.
  final CollectHealth collect;

  final Map<String, UpstreamLink> _links;
  final ValueStore _store;

  /// The monotonic anchor `data_age_ms` is measured on.
  ///
  /// **Not a wall clock, and the type is what says so** (08-REVIEW CR-02).
  /// The gauge answers "how long since a value arrived", which is an
  /// elapsed-time question; subtracting two `DateTime.now()` readings made it
  /// go *negative* after a backwards NTP step, and a negative age published
  /// under [Quality.good] is a number no page can render sensibly.
  final int Function() _elapsedMs;

  /// Aliases the gateway has actually asked about.
  ///
  /// Until an alias is in here every one of its keys reads null under
  /// [Quality.errorConfig], because nothing this producer could say would be a
  /// reading. Set by [onLinkEvent], which `LocalStateMan.start` calls once per
  /// link whether the connect succeeded or threw.
  final Set<String> _asked = <String>{};

  /// The newest arrival per alias, on the elapsed anchor, for `data_age_ms`.
  final Map<String, int> _newestArrival = <String, int>{};

  /// A redacted error attributed to an alias rather than to one of its keys.
  final Map<String, String> _noted = <String, String>{};

  /// Every key this producer owns for [alias], in one list.
  ///
  /// Built from [PipeKeys] rather than spelled, so a name added to the
  /// vocabulary is added in one place. Callers get the roster for one alias;
  /// there is deliberately no roster of *aliases* here, because the aliases
  /// come out of a configuration file.
  static List<String> keysFor(String alias) => <String>[
        PipeKeys.upstreamConnected(alias),
        PipeKeys.upstreamState(alias),
        PipeKeys.upstreamLastError(alias),
        PipeKeys.upstreamEpoch(alias),
        PipeKeys.upstreamBirthCount(alias),
        PipeKeys.upstreamLastDeathAt(alias),
        PipeKeys.upstreamDataAgeMs(alias),
      ];

  /// The aliases this producer reports on.
  Iterable<String> get aliases => _links.keys;

  /// [link] did something worth reporting: it was asked, it changed state, its
  /// epoch moved, or it failed to open.
  ///
  /// Idempotent. One `applyBatch` per call, and a call in which nothing
  /// actually changed notifies nobody, because that is what the store does with
  /// a value equal to the one it holds.
  void onLinkEvent(UpstreamLink link) {
    _asked.add(link.alias);
    publish(link.alias);
  }

  /// Values arrived on [aliases] at elapsed millisecond [at]. Moves
  /// `data_age_ms` and nothing else.
  void noteArrivals(Iterable<String> aliases, int at) {
    final batch = <String, DynamicValue>{};
    for (final alias in aliases) {
      _newestArrival[alias] = at;
      if (!_asked.contains(alias)) continue;
      batch[PipeKeys.upstreamDataAgeMs(alias)] = _dataAge(alias);
    }
    _apply(batch);
  }

  /// Records a **redacted** error against [alias].
  ///
  /// The two inputs `LocalStateMan` already collects — a failed `start` connect
  /// and a per-key upstream stream error — are both redacted at the boundary
  /// they crossed. Nothing is redacted a second time here: one redactor used by
  /// every adapter is the property worth keeping (T-08-33), and a
  /// belt-and-braces pass at this call site would hide an adapter that forgot
  /// to apply it. The arm that feeds a credentialed endpoint in and reads the
  /// key value back out is what judges that.
  void noteError(String alias, String? redacted) {
    if (redacted == null || redacted.isEmpty) return;
    _noted[alias] = redacted;
    _asked.add(alias);
    publish(alias);
  }

  /// Republishes every key for [alias] as one batch.
  void publish(String alias) {
    final link = _links[alias];
    if (link == null) return;
    if (!_asked.contains(alias)) return;
    _apply(<String, DynamicValue>{
      // The coarse alarm bit: true only while the link is actually serving.
      // `unhealthy` is a live channel that has stopped publishing and
      // `reprogrammed` is a PLC whose address space moved underneath our
      // handles; neither is a link an operator should believe a number from,
      // and the nuance they carry is on `state` where a page can render it.
      PipeKeys.upstreamConnected(alias):
          _known(link.state == UpstreamLinkState.connected),
      PipeKeys.upstreamState(alias): _known(link.state.wireName),
      PipeKeys.upstreamLastError(alias): _known(link.lastError ?? _noted[alias]),
      PipeKeys.upstreamEpoch(alias): _epochOf(link),
      PipeKeys.upstreamBirthCount(alias): _known(link.birthCount),
      PipeKeys.upstreamLastDeathAt(alias):
          _known(link.lastDeathAt?.millisecondsSinceEpoch),
      PipeKeys.upstreamDataAgeMs(alias): _dataAge(alias),
    });
  }

  /// What [key] should read as right now, for callers on the read path.
  ///
  /// The identity for everything except `data_age_ms`; see the library doc for
  /// why that one is different. It does not write, so a poll costs no
  /// notifications.
  DynamicValue judge(String key, DynamicValue cached) {
    // The historian's counters are gauges recomputed on the read path, the
    // same treatment `data_age_ms` gets below and for the same reason: the
    // stored value is written on a deadline, so a poll between two deadline
    // publishes must still answer the current number without writing.
    if (CollectHealth.owns(key)) return collect.judge(key, cached);
    final alias = PipeKeys.aliasOf(key);
    if (alias == null) return cached;
    if (key != PipeKeys.upstreamDataAgeMs(alias)) return cached;
    if (!_asked.contains(alias)) return cached;
    return _dataAge(alias);
  }

  /// Every key of every configured link, at "nothing has been asked yet".
  void _seed() {
    final batch = <String, DynamicValue>{};
    for (final alias in _links.keys) {
      for (final key in keysFor(alias)) {
        batch[key] = _unknown();
      }
    }
    _apply(batch);
  }

  /// The epoch, as an **opaque string and nothing else**.
  ///
  /// No parsing, no ordering, no "newer than" — equality against the link's
  /// current token is the entire vocabulary an epoch has (08-08). The quality
  /// carries the three cases the token itself cannot:
  ///
  ///  * [isUnreadableEpoch] — the server was asked and would not say. That is a
  ///    comms condition, and the token is published anyway so a page shows
  ///    *which* kind of not-knowing this is.
  ///  * [unconnectedEpoch] — the link has never successfully read an identity.
  ///    A different statement from unreadable, and waiting does fix it.
  ///  * anything else — a real identity.
  DynamicValue _epochOf(UpstreamLink link) {
    final token = link.epoch;
    if (isUnreadableEpoch(token)) {
      return DynamicValue(value: token, quality: Quality.badCommFault);
    }
    if (token == unconnectedEpoch) {
      return DynamicValue(value: token, quality: Quality.uncertainNotYetKnown);
    }
    return DynamicValue(value: token, quality: Quality.good);
  }

  /// The age of the newest value on [alias], or the honest absence of one.
  DynamicValue _dataAge(String alias) {
    final newest = _newestArrival[alias];
    if (newest == null) return _unknown();
    // Two readings of a monotonic counter, so the answer cannot be negative
    // and cannot jump when the plant PC's RTC is corrected. See [_elapsedMs].
    return _known(_elapsedMs() - newest);
  }

  /// A reading. Null is allowed and means "the answer is nothing" — which is
  /// why the quality is good: the gateway looked.
  ///
  /// No `sourceTime`. Stamping one would make every republish a different value
  /// even when the reading had not moved, and every listener on every health
  /// key would be woken by every link event in the plant.
  static DynamicValue _known(Object? value) => DynamicValue(value: value);

  /// No reading at all.
  static DynamicValue _unknown() =>
      DynamicValue(value: null, quality: Quality.errorConfig);

  void _apply(Map<String, DynamicValue> batch) {
    if (batch.isEmpty) return;
    // One pass, k notifications for k changed keys. Applied directly rather
    // than through the composer's upstream-ingest seam on purpose: a health
    // key is not news from the plant, and recording an arrival for it would put
    // it back inside the freshness accounting it is excluded from.
    _store.applyBatch(batch);
  }
}

/// The collection historian's six `PIPE.collect.*` keys (8b-03).
///
/// Owned by [PipeHealth] and driven by the collection runner. The same three
/// rules as the per-link producer, restated because each one is load-bearing
/// here too:
///
///  * **Seeded at construction.** All six exist as null under
///    [Quality.errorConfig] before anything can subscribe. A gateway that
///    does not collect answers "not configured" — never `false` (an engineer
///    sent to a database that is fine) and never `0` (a historian that has
///    apparently written nothing since forever).
///  * **News is pushed, gauges ride a deadline.** `enabled` flipping, the
///    sink's connection moving and `last_error` changing are events and
///    publish immediately (they are the priority lane's keys). The three
///    counters are recomputed **on a deadline from paths that already run**
///    — the runner's insert path calls [update] and this class publishes at
///    most once per [refreshInterval] — the `refreshIfDue()` shape
///    (`session_health_state_man.dart:263`), chosen because this package's
///    timer count is a pinned number and a counter does not need a clock of
///    its own.
///  * **The read path re-derives.** [judge] answers the *current* counters
///    synchronously without writing, exactly the way `data_age_ms` is
///    handled above, so a poll between two deadline publishes is still
///    correct and a read is still not an event.
///
/// `last_error` is served **verbatim**: the sink redacts before it stores
/// (T-8b-14), and a second pass here would hide a sink that forgot.
final class CollectHealth {
  CollectHealth({
    required ValueStore store,
    required int Function() elapsedMs,
    this.refreshInterval = const Duration(milliseconds: 250),
  })  : _store = store,
        _elapsedMs = elapsedMs {
    _seed();
  }

  final ValueStore _store;
  final int Function() _elapsedMs;

  /// The most a counter publish may lag the counter. Small enough that a
  /// chart of `rows_written` moves visibly, large enough that a 430-entry
  /// plant sampling at once does not turn every insert into a store write.
  final Duration refreshInterval;

  /// The six, in one list — built from [PipeKeys], nothing spelled here.
  static const List<String> ownKeys = <String>[
    PipeKeys.collectEnabled,
    PipeKeys.collectConnected,
    PipeKeys.collectRowsWritten,
    PipeKeys.collectRowsDropped,
    PipeKeys.collectQueuedRows,
    PipeKeys.collectLastError,
  ];

  /// Whether [key] is one of the six.
  static bool owns(String key) => ownKeys.contains(key);

  bool _enabled = false;
  bool? _connected;
  int _rowsWritten = 0;
  int _rowsDropped = 0;
  int _rowsQueued = 0;
  String? _lastError;

  /// Whether the runner has ever reported. Until it has, every key stays at
  /// the seed and [judge] is the identity — "not configured" must not decay
  /// into a plausible zero because somebody polled.
  bool _asked = false;

  int _publishedAtMs = 0;

  /// Collection started: `enabled` flips true. News — published immediately.
  void markEnabled() {
    _asked = true;
    _enabled = true;
    _publish();
  }

  /// The sink's connection state moved. News — published immediately.
  void noteConnected(bool up) {
    _asked = true;
    _connected = up;
    _publish();
  }

  /// The runner's insert path reporting the current numbers.
  ///
  /// Deadline-gated: a changed `lastError` is news and publishes at once,
  /// anything else waits for [refreshInterval] since the last publish. The
  /// fields are always taken, so [judge] answers current numbers even while
  /// the store still holds the previous publish.
  void update({
    required int rowsWritten,
    required int rowsDropped,
    required int rowsQueued,
    String? lastError,
  }) {
    _asked = true;
    final errorChanged = lastError != _lastError;
    _rowsWritten = rowsWritten;
    _rowsDropped = rowsDropped;
    _rowsQueued = rowsQueued;
    _lastError = lastError;
    if (!errorChanged &&
        _elapsedMs() - _publishedAtMs < refreshInterval.inMilliseconds) {
      return;
    }
    _publish();
  }

  /// What [key] should read as right now — the current counter for the three
  /// gauges, the cached value for everything else. Does not write.
  DynamicValue judge(String key, DynamicValue cached) {
    if (!_asked) return cached;
    return switch (key) {
      PipeKeys.collectRowsWritten => _known(_rowsWritten),
      PipeKeys.collectRowsDropped => _known(_rowsDropped),
      PipeKeys.collectQueuedRows => _known(_rowsQueued),
      _ => cached,
    };
  }

  void _publish() {
    _publishedAtMs = _elapsedMs();
    _store.applyBatch(<String, DynamicValue>{
      PipeKeys.collectEnabled: _known(_enabled),
      // The sink has not said anything yet: the honest absence of a reading,
      // not a plausible false.
      PipeKeys.collectConnected:
          _connected == null ? _unknown() : _known(_connected),
      PipeKeys.collectRowsWritten: _known(_rowsWritten),
      PipeKeys.collectRowsDropped: _known(_rowsDropped),
      PipeKeys.collectQueuedRows: _known(_rowsQueued),
      // Null under good once asked: the gateway looked, and the answer is
      // "nothing" — PipeHealth's rule, unchanged.
      PipeKeys.collectLastError: _known(_lastError),
    });
  }

  void _seed() {
    _store.applyBatch(<String, DynamicValue>{
      for (final key in ownKeys) key: _unknown(),
    });
  }

  static DynamicValue _known(Object? value) => DynamicValue(value: value);

  static DynamicValue _unknown() =>
      DynamicValue(value: null, quality: Quality.errorConfig);
}
