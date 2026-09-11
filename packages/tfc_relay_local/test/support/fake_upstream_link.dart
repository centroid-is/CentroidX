/// An in-memory [UpstreamLink] with the levers every later plan needs to
/// break it on demand, per alias.
///
/// **The levers never go on a production class.** They live here, on the fake,
/// and 08-11's test-only `LocalStateMan` subclass forwards to them — the
/// arrangement `08-PATTERNS §5` recommends in so many words and that
/// `api_surface_test.dart` exists to keep true one layer up. That is also why
/// the nine names below are spelled **exactly** as `StateManHarness` spells
/// them (`harness.dart:47-130`): `setValue`, `setValues`, `setQuality`,
/// `dropKey`, `staleAfter`, `disconnectUpstream`, `reconnectUpstream`,
/// `roundTrips`, `statusNotifications`. This class does not *implement*
/// `StateManHarness` — it is not a `StateManApi` and the kit's interface
/// requires one — but matching the names now makes 08-11's forwarding
/// mechanical rather than a translation table somebody has to keep right.
///
/// The degradation and the announcement are deliberately **two methods**,
/// exactly as `fake_state_man.dart:598-605` keeps them and for its stated
/// reason: a variant that fans announcements out per key is the sabotage 08-09
/// runs, and it can only exist if the two are separable.
library;

import 'dart:async';

import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The test-only control surface: what stands in for the plant, on one link.
///
/// Obtained through `driverOf(link)` in the contract suite, which fails with a
/// message rather than a cast error — `harnessOf`'s reason
/// (`harness.dart:143-147`).
abstract interface class UpstreamLinkDriver {
  // ------------------------------------------------- the nine kit lever names

  /// Delivers [value] for [key] as one upstream update.
  ///
  /// [sourceTime] defaults to null rather than to "now" for the kit's reason
  /// (`harness.dart:48-54`): a source that stamps every arriving sample with
  /// its receive time makes two identical readings unequal, and the
  /// unchanged-value guard silently stops working.
  void setValue(String key, Object? value,
      {Quality quality = Quality.good, DateTime? sourceTime});

  /// Delivers many keys as exactly one batch.
  void setValues(Map<String, Object?> values);

  /// Re-delivers the current value for [key] under a different quality.
  void setQuality(String key, Quality quality);

  /// The tag is gone upstream: [key] reports [Quality.errorConfig] and never
  /// updates again.
  void dropKey(String key);

  /// The freshness deadline this link declares.
  Duration get staleAfter;

  /// The upstream device link is down.
  void disconnectUpstream();

  /// The upstream link is back, and a snapshot with it.
  void reconnectUpstream();

  /// Read + write + subscribe-establish calls that reached this link.
  int get roundTrips;

  /// How many times this link announced a change of link state. One per
  /// mass-degradation, never one per key.
  int get statusNotifications;

  // --------------------------------- the levers this phase needs on top, each
  // --------------------------------- named with the plan that drives it

  /// The PLC's identity changed: every [UpstreamRef] handed out so far is now
  /// stale. Drives **08-08**'s epoch work and Phase 9's F24 arm.
  void bumpEpoch();

  /// Stages the answer the next [UpstreamLink.write] gives, once. Drives
  /// **08-06**'s three-state write path, where the interesting outcomes are
  /// the ones a fake cannot reach by succeeding.
  void setNextWriteOutcome(WriteResult outcome);

  /// How long a read takes upstream. Drives **08-06**'s deadline arms: the
  /// only way to test a deadline is to be slower than one.
  Duration get readLatency;
  set readLatency(Duration value);

  /// How long a write takes upstream. Same, for the unknown-on-timeout arm.
  Duration get writeLatency;
  set writeLatency(Duration value);

  /// Makes exactly the next `resolve` answer null. Drives **08-04**'s router
  /// fallthrough, which needs a link that declines *one* key rather than a
  /// link that has gone away.
  void failNextResolve();

  /// The capability flags, which **08-11** hands to the contract leg — and
  /// which are how the M2400's read-only-ness becomes a `WriteRejected`
  /// instead of an `UnsupportedError`.
  void setSupportsWrites(bool value);
  void setSupportsBrowse(bool value);

  /// Hands the ingest path a payload straight from the "wire", before any
  /// sanitizing. Drives **08-05**: a struct-heavy PLC is exactly where
  /// `DynamicValue`'s depth bound bites, and the standing constraint is that a
  /// sanitize failure costs **one tag, never a poll cycle**.
  void emitRaw(String key, Object? raw);

  /// How many payloads the sanitizing constructor refused.
  int get sanitizeRefusals;

  /// Everything [emitRaw] was handed, unsanitized, for 08-05 to point the
  /// gateway's own converter at.
  List<({String key, Object? raw})> get rawEmissions;

  /// Sets the raw upstream error, **before** redaction. The point of the lever
  /// is that a test can hand it a credential and watch it not come back out
  /// (T-08-08); drives **08-09**'s `last_error` key.
  void setLastError(String? raw);
}

/// The in-memory link.
///
/// Constructs disconnected and connects on demand, copying
/// `createM2400DeviceClients`'s division of labour (`state_man.dart:1292-1293`)
/// rather than arriving already connected — the lifecycle the real adapters
/// have is the lifecycle the contract should be exercising.
final class FakeUpstreamLink implements UpstreamLink, UpstreamLinkDriver {
  FakeUpstreamLink({
    required this.alias,
    Iterable<String> keys = const <String>[],
    this.staleAfter = const Duration(seconds: 5),
    bool supportsWrites = true,
    bool supportsBrowse = true,
  })  : _keys = Set<String>.of(keys),
        _supportsWrites = supportsWrites,
        _supportsBrowse = supportsBrowse;

  @override
  final String alias;

  @override
  final Duration staleAfter;

  /// The keys this link claims. **Empty means it claims everything** — which
  /// is what a single-link fixture wants, and what the two-link per-alias
  /// tests must not use.
  final Set<String> _keys;

  final Map<String, DynamicValue> _values = <String, DynamicValue>{};
  final Set<String> _dropped = <String>{};
  final Map<String, StreamController<DynamicValue>> _feeds =
      <String, StreamController<DynamicValue>>{};

  /// Streams handed to subscriptions taken out against a superseded epoch.
  /// Held so [dispose] can close them; never fed a value again.
  final List<StreamController<DynamicValue>> _staleFeeds =
      <StreamController<DynamicValue>>[];

  final StreamController<UpstreamLinkState> _states =
      StreamController<UpstreamLinkState>.broadcast();
  final StreamController<String> _epochs = StreamController<String>.broadcast();

  UpstreamLinkState _state = UpstreamLinkState.disconnected;
  int _epochSeq = 1;
  String? _rawLastError;
  DateTime? _lastDeathAt;
  int _birthCount = 0;
  int _roundTrips = 0;
  int _statusNotifications = 0;
  int _subscriptionsCreated = 0;
  int _sanitizeRefusals = 0;
  bool _supportsWrites;
  bool _supportsBrowse;
  bool _failNextResolve = false;
  WriteResult? _nextWriteOutcome;

  @override
  Duration readLatency = Duration.zero;

  @override
  Duration writeLatency = Duration.zero;

  final List<({String key, Object? raw})> _rawEmissions =
      <({String key, Object? raw})>[];

  /// Told about every write this link **applied**, if anybody is listening.
  ///
  /// **Opt-in and null by default**, so every existing user of this fake is
  /// untouched. The one consumer is 11-04's `AppliedWriteLedger`: §7.8 asks for
  /// a server-side log of applied writes compared after the run, and the
  /// gateway's own `WriteOutcomeLog` prunes at sixty seconds
  /// (`write_outcome_log.dart:210-214`), so the durable record has to live on
  /// the plant side of the fake. That is deviation 3 in `soak_registry.dart`.
  ///
  /// **On the test class, deliberately** — 08-03 task 2's rule that levers
  /// never go on a production class, and `freeze_test.dart`'s freeze 10 sweeps
  /// `lib/` for the ledger's name so the rule is mechanical rather than a
  /// convention.
  ///
  /// It fires on the line below that publishes the value and answers
  /// `WriteApplied`, and nowhere else: a staged outcome
  /// ([setNextWriteOutcome]) applies nothing, and a refusal is not an
  /// application. "Applied" here means what it means everywhere else in this
  /// system — applied *and read back*.
  void Function(String key, Object? value, String cmd)? onWriteApplied;

  // ------------------------------------------------------------ UpstreamLink

  @override
  UpstreamLinkState get state => _state;

  @override
  Stream<UpstreamLinkState> get stateStream => _states.stream;

  @override
  String? get lastError => redactUpstreamError(_rawLastError);

  @override
  String get epoch => 'epoch-$_epochSeq';

  @override
  Stream<String> get epochStream => _epochs.stream;

  @override
  int get birthCount => _birthCount;

  @override
  DateTime? get lastDeathAt => _lastDeathAt;

  @override
  bool get supportsWrites => _supportsWrites;

  @override
  bool get supportsBrowse => _supportsBrowse;

  @override
  int get upstreamSubscriptionsCreated => _subscriptionsCreated;

  @override
  UpstreamRef? resolve(String key, Object mappingEntry) {
    if (_failNextResolve) {
      _failNextResolve = false;
      return null;
    }
    if (_dropped.contains(key)) return null;
    if (_keys.isNotEmpty && !_keys.contains(key)) return null;
    return UpstreamRef(
      alias: alias,
      epoch: epoch,
      // Whatever an adapter interprets. A NodeId here, a register spec there;
      // the router never looks inside it.
      payload: 'fake:$key',
      key: key,
    );
  }

  @override
  DynamicValue? peek(UpstreamRef ref) {
    // SRV-07, enforced before the cache is even consulted: a handle from
    // before the last epoch addresses a node the link no longer vouches for.
    if (_isStale(ref)) return null;
    return _values[ref.key];
  }

  @override
  Future<DynamicValue> read(UpstreamRef ref,
      {required Duration deadline}) async {
    _roundTrips++;
    if (_isStale(ref)) return _bad(Quality.badCommFault);

    // Slower than the caller was willing to wait: answer at the deadline, with
    // no reading. Never throw and never outrun it — `state_man.dart:1868`'s
    // deadline-less `awaitConnect()` is the shape this refuses to have.
    if (readLatency > deadline) {
      await Future<void>.delayed(deadline);
      return _bad(Quality.badCommFault);
    }
    await Future<void>.delayed(readLatency);

    if (_state != UpstreamLinkState.connected) return _bad(Quality.badCommFault);
    if (_dropped.contains(ref.key)) return _bad(Quality.errorConfig);
    // Nothing has arrived yet is uncertain, not error: waiting *does* fix it.
    return _values[ref.key] ?? _bad(Quality.uncertainNotYetKnown);
  }

  @override
  Future<WriteResult> write(
    UpstreamRef ref,
    DynamicValue value, {
    required String cmd,
    required Duration deadline,
    bool hasExpect = false,
  }) async {
    _roundTrips++;

    if (!_supportsWrites) {
      // The shape `cert_health_state_man.dart:411-424` refuses with, because
      // an operator reading two different refusals from two layers of the same
      // gateway learns nothing from the difference.
      return WriteRejected(
          cmd,
          const WriteReason('not_writable',
              message: 'this link is read-only', status: 'Bad_NotWritable'));
    }
    if (_isStale(ref)) {
      // Definitively no effect — nothing was sent — so this is a rejection and
      // not an unknown. The distinction is the whole write path.
      return WriteRejected(
          cmd,
          const WriteReason('stale_handle',
              message: 'the handle was resolved under a superseded epoch',
              status: 'Bad_NodeIdUnknown'));
    }
    if (writeLatency > deadline) {
      await Future<void>.delayed(deadline);
      return WriteUnknown(
          cmd,
          const WriteReason('plc_timeout',
              message: 'the deadline passed with the request on the wire'));
    }
    await Future<void>.delayed(writeLatency);

    final staged = _nextWriteOutcome;
    if (staged != null) {
      _nextWriteOutcome = null;
      return staged;
    }
    if (_state != UpstreamLinkState.connected) {
      return WriteUnknown(cmd, const WriteReason('link_lost'));
    }

    _publish(ref.key, value);
    onWriteApplied?.call(ref.key, value.value, cmd);
    // "Applied" means applied *and read back*; readback is the only
    // confirmation this system accepts.
    return WriteApplied(cmd,
        readback: value.value, at: DateTime.now().millisecondsSinceEpoch);
  }

  @override
  Stream<DynamicValue> subscribe(UpstreamRef ref) {
    _roundTrips++;
    // Counted on the ask, which is what `ClientWrapper.monitoredItemsCreated`
    // counts too. Deltas of creates; there is no delete counter to balance.
    _subscriptionsCreated++;

    if (_isStale(ref)) {
      // One bad value and then silence — and the stream stays OPEN, because an
      // ended stream reads to a widget as a key that stopped changing.
      final feed = StreamController<DynamicValue>();
      _staleFeeds.add(feed);
      feed.add(_bad(Quality.badCommFault));
      return feed.stream;
    }
    return _feedFor(ref.key).stream;
  }

  @override
  Future<void> connect({required Duration deadline}) async {
    if (_state == UpstreamLinkState.connected) return;
    _state = UpstreamLinkState.connected;
    _birthCount++;
    announceLinkState();
    _states.add(_state);
  }

  @override
  Future<void> dispose() async {
    for (final feed in _feeds.values) {
      await feed.close();
    }
    for (final feed in _staleFeeds) {
      await feed.close();
    }
    _feeds.clear();
    _staleFeeds.clear();
    await _states.close();
    await _epochs.close();
  }

  // ------------------------------------------------------ the nine kit levers

  @override
  void setValue(String key, Object? value,
          {Quality quality = Quality.good, DateTime? sourceTime}) =>
      _publish(
          key,
          DynamicValue(
              value: value, quality: quality, sourceTime: sourceTime));

  @override
  void setValues(Map<String, Object?> values) {
    for (final entry in values.entries) {
      _publish(entry.key, DynamicValue(value: entry.value));
    }
  }

  @override
  void setQuality(String key, Quality quality) {
    final cached = _values[key];
    _publish(
        key,
        cached == null
            ? DynamicValue(value: null, quality: quality)
            : cached.copyWith(quality: quality));
  }

  @override
  void dropKey(String key) {
    _dropped.add(key);
    // errorConfig and a null payload: the tag is gone, waiting will not fix
    // it, and the last plausible number must stop rendering.
    _publish(key, _bad(Quality.errorConfig));
  }

  @override
  void disconnectUpstream() {
    // Already down is not a second event.
    if (_state == UpstreamLinkState.disconnected) return;
    _state = UpstreamLinkState.disconnected;
    _lastDeathAt = DateTime.now();
    applyLinkLoss();
    announceLinkState();
    _states.add(_state);
  }

  @override
  void reconnectUpstream() {
    if (_state == UpstreamLinkState.connected) return;
    _state = UpstreamLinkState.connected;
    _birthCount++;
    applyLinkRestored();
    announceLinkState();
    _states.add(_state);
  }

  @override
  int get roundTrips => _roundTrips;

  @override
  int get statusNotifications => _statusNotifications;

  // ------------------------------------------------- degradation, and only it

  /// One pass over this link's keys. **Separate from [announceLinkState]** —
  /// see the library doc; 08-09's sabotage is a variant that fans the
  /// announcement out inside this loop, and it can only be written if the two
  /// are apart.
  void applyLinkLoss() {
    for (final key in _values.keys.toList()) {
      final cached = _values[key]!;
      // A key already at a worse-or-equal band stages no change. errorConfig
      // means the tag is gone and waiting will not fix it; badCommFault means
      // the link is down and waiting might. Overwriting the first with the
      // second tells the operator to wait for something never coming back.
      if (Quality.badCommFault.band <= cached.quality.band) continue;
      _publish(key, cached.copyWith(quality: Quality.badCommFault));
    }
  }

  /// The snapshot after a reconnect: link-degraded keys come back
  /// **uncertain**, not good. The link being back is not evidence about the
  /// number, and each value is good again only once it has been re-read.
  void applyLinkRestored() {
    for (final key in _values.keys.toList()) {
      final cached = _values[key]!;
      if (cached.quality != Quality.badCommFault) continue;
      _publish(key, cached.copyWith(quality: Quality.uncertainLastKnown));
    }
  }

  /// Announces that the link's state changed — once, however many keys it
  /// cost.
  void announceLinkState() => _statusNotifications++;

  // --------------------------------------------------- the phase's own levers

  @override
  void bumpEpoch() {
    _epochSeq++;
    _epochs.add(epoch);
  }

  @override
  void setNextWriteOutcome(WriteResult outcome) => _nextWriteOutcome = outcome;

  @override
  void failNextResolve() => _failNextResolve = true;

  @override
  void setSupportsWrites(bool value) => _supportsWrites = value;

  @override
  void setSupportsBrowse(bool value) => _supportsBrowse = value;

  @override
  void setLastError(String? raw) => _rawLastError = raw;

  @override
  int get sanitizeRefusals => _sanitizeRefusals;

  @override
  List<({String key, Object? raw})> get rawEmissions =>
      List<({String key, Object? raw})>.unmodifiable(_rawEmissions);

  @override
  void emitRaw(String key, Object? raw) {
    _rawEmissions.add((key: key, raw: raw));
    try {
      _publish(key, DynamicValue(value: raw));
    } on ArgumentError {
      // The standing constraint, made mechanical: sanitize failure = ONE TAG
      // fails, never a poll cycle. The refusal is recorded on the tag that
      // caused it and every other key on this link is untouched.
      _sanitizeRefusals++;
      _publish(key, _bad(Quality.errorConfig));
    }
  }

  // ----------------------------------------------------------------- internals

  bool _isStale(UpstreamRef ref) => ref.epoch != epoch;

  static DynamicValue _bad(Quality quality) =>
      DynamicValue(value: null, quality: quality);

  StreamController<DynamicValue> _feedFor(String key) =>
      _feeds.putIfAbsent(key, StreamController<DynamicValue>.broadcast);

  void _publish(String key, DynamicValue value) {
    _values[key] = value;
    final feed = _feeds[key];
    if (feed != null && !feed.isClosed) feed.add(value);
  }
}
