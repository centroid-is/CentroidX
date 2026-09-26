import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/state_man_types.dart';

import '../core/timeseries_source.dart';
import '../page_creator/assets/helper/timeseries_cache.dart';
import 'state_man.dart' show stateManProvider;
import 'timeseries_source.dart';

/// How often a tracked timeseries key reconciles its cache with the database.
///
/// This is the ceiling on how stale a readout can be when its NOTIFY stream
/// has stopped delivering — for whatever reason, detected or not.
const kTimeseriesResyncInterval = Duration(seconds: 30);

/// How far back each reconciling sweep looks.
///
/// Wider than [kTimeseriesResyncInterval] so consecutive sweeps overlap and a
/// row cannot fall between two of them, and wider than the collector's batch
/// lag so a row is never both too old for the slice and not yet inserted.
const kTimeseriesResyncWindow = Duration(minutes: 2);

/// A row older than this that a sweep finds in the database but not in the
/// cache is taken as proof that NOTIFY is no longer delivering for that key.
///
/// Younger rows are not: the collector batches its inserts, so a row's `time`
/// can lag its insert by seconds, and the sweep's query can return a row
/// whose notification is still on the wire. Sixty seconds is comfortably
/// beyond both.
const kTimeseriesNotifyGrace = Duration(seconds: 60);

/// How often a tracked key reconciles when its transport **cannot** push.
///
/// A gateway panel has no LISTEN/NOTIFY — the pipe carries none and no plan
/// adds one (`TimeseriesSource.liveInserts`) — so on that transport this poll
/// is not a fallback, it is the only way a row ever reaches the cache. At
/// [kTimeseriesResyncInterval] a BPM readout on a gateway panel would step
/// once every thirty seconds while the same readout on a direct station steps
/// with the plant, and an operator comparing the two would be right to
/// distrust both.
///
/// Five seconds is the cost of that honesty: one bounded query per tracked key
/// per five seconds, over a socket that is already carrying the subscription
/// tick. It is deliberately **not** as fast as a push — a poll cannot be —
/// and the readout is correct either way; what changes is how long it lags.
const kTimeseriesPollInterval = Duration(seconds: 5);

/// One live, reconciled timeseries key — shared by every readout showing it.
///
/// The first subscriber creates it (via [timeseriesTrackerProvider]); the
/// last one going disposes it. In between it owns, once per key rather than
/// once per widget: the LISTEN/NOTIFY subscription, the history fetch, the
/// [TimeseriesCache], and the periodic sweep that reconciles the cache with
/// the database, re-subscribing a channel that has ended, errored, or gone
/// quiet. Two readouts on the same key — the figure on the mimic and the same
/// figure in an open side pane — therefore read the same cache and cannot
/// disagree at all, where separate copies of the plumbing could disagree by
/// up to a sweep interval.
///
/// Values are always cached alongside timestamps, so counting readouts (BPM,
/// ratio) and value readouts (rate) share a tracker when they share a key.
///
/// Listeners are notified when the cache gains a row it did not have —
/// whether by NOTIFY, the initial fetch, or a sweep — and not otherwise.
class TimeseriesKeyTracker extends ChangeNotifier {
  TimeseriesKeyTracker({
    required this.tsKey,
    required Future<TimeseriesSource?> Function() source,
    required Future<StateMan> Function() stateMan,
  })  : _source = source,
        _stateMan = stateMan;

  /// The timeseries key (StateMan key; resolved to a table name per fetch).
  final String tsKey;

  /// **A [TimeseriesSource], not a `Database`.** The transport branch happens
  /// in `timeseriesSourceProvider`; this class asks three questions and does
  /// not know which end answers them. Before that seam existed the first line
  /// of [start] was `if (db == null) return`, and a gateway panel — where
  /// `databaseProvider` is null by design — never got past it.
  final Future<TimeseriesSource?> Function() _source;
  final Future<StateMan> Function() _stateMan;

  static final Logger _log = Logger();

  final TimeseriesCache cache = TimeseriesCache();

  TimeseriesSource? _readFrom;
  bool _disposed = false;

  /// Bumped by every (re)initialisation, so one overtaken by a newer one
  /// stops at its next await instead of subscribing on top of it.
  int _generation = 0;

  /// The widest window any current or past subscriber has asked for.
  /// Grows, never shrinks: a stale tail costs a few rows, a shrunken one
  /// costs another subscriber its data.
  int _windowMinutes = 0;

  /// The widest window any subscriber has asked for, for callers that must
  /// not prune the shared cache below what others need.
  int get windowMinutes => _windowMinutes;

  Timer? _sweepTimer;
  bool _sweeping = false;
  StreamSubscription<TimeseriesInsert>? _notifySub;

  /// Whether the NOTIFY stream is believed to be delivering.
  bool _notifyAlive = false;

  /// Whether this key's source has a push channel at all.
  ///
  /// **The third state, and the reason it is a field rather than an inference
  /// from [_notifyAlive].** A direct-mode station pushes and may be
  /// temporarily disconnected; a gateway panel does not push and never will.
  /// Both read `_notifyAlive == false`, and treating them the same is what
  /// would put a re-subscribe attempt and a "stream is not available yet"
  /// warning on every sweep of every key of every gateway panel, forever,
  /// about a channel nobody is ever going to open. A fault line that cries
  /// wolf is a fault line nobody reads.
  ///
  /// Optimistic until measured: a tracker that has not yet asked assumes a
  /// push channel, so the polling cadence is never chosen before the source
  /// has answered.
  bool get transportPushes => _transportPushes;
  bool _transportPushes = true;

  /// Whether the "this transport polls" line has been said for this key, so it
  /// is said once and not per sweep.
  bool _reportedPolling = false;

  /// Why the last fetch for this key failed, or null when the last one worked.
  ///
  /// **Not a log line.** A readout drawing zero because the source is
  /// unreachable is indistinguishable on screen from a line that has not run,
  /// and the empty cache behind it is the same object in both cases. This is
  /// where the difference lives, and it is the same rule — for the same
  /// measured reason — as `RelayAlarmSource.historyError`.
  ///
  /// Cleared by the next fetch that succeeds. Listeners are notified when it
  /// changes, so a readout that renders it does not need its own poll.
  String? get fetchError => _fetchError;
  String? _fetchError;

  /// Consecutive failed subscribe attempts, and how many sweep ticks to sit
  /// out before the next one. A subscription that cannot be established —
  /// the trigger will not install, session after session — must not mean a
  /// retry plus a full-window fetch every tick forever; attempts double
  /// their spacing up to [_maxRetrySkipTicks] (5 minutes of 30 s ticks). The
  /// data does not back off with it: skipped ticks still merge the cheap
  /// reconciling slice, so the readout stays current from polling alone.
  int _subscribeFailures = 0;
  int _ticksUntilRetry = 0;
  static const _maxRetrySkipTicks = 9;

  /// When the last visible handle went hidden, so the sweep on resume can
  /// cover the whole stretch nobody was looking.
  DateTime? _quietSince;

  final List<TimeseriesTrackerHandle> _handles = [];

  bool get _alive => !_disposed;
  bool get _anyVisible => _handles.any((h) => h._visible);

  /// Registers a subscriber needing at least [windowMinutes] of history.
  ///
  /// Growing the window past what previous subscribers needed triggers a
  /// full-window merge so the new subscriber's deeper history is present.
  TimeseriesTrackerHandle attach({required int windowMinutes}) {
    final handle = TimeseriesTrackerHandle._(this);
    _handles.add(handle);
    if (_quietSince != null) {
      // Was fully hidden; this handle is visible, so wake up below via
      // the visibility path.
      _onVisibilityChanged(wasAnyVisible: false);
    }
    if (windowMinutes > _windowMinutes) {
      final grew = _windowMinutes > 0;
      _windowMinutes = windowMinutes;
      if (grew && _readFrom != null) {
        unawaited(_sweep(window: Duration(minutes: _windowMinutes)));
      }
    }
    return handle;
  }

  /// Called by the provider when [timeseriesSourceProvider] yields an instance
  /// the tracker is not already on — first connect, reconnect, new settings,
  /// or a relay client rebuilt behind a gateway panel.
  void onSourceAvailable(TimeseriesSource source) {
    // `==`, not `identical` — see `DatabaseTimeseriesSource.==`.
    if (!_alive || source == _readFrom) return;
    _notifySub?.cancel();
    _notifySub = null;
    _notifyAlive = false;
    _transportPushes = true;
    _reportedPolling = false;
    _subscribeFailures = 0;
    _ticksUntilRetry = 0;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    unawaited(_initData(source));
  }

  /// Kicks the initial connect. The source is often not up yet — on a
  /// plant-wide power cut Flutter is drawing while Postgres is still
  /// replaying WAL — in which case this bails and the provider's listen on
  /// [timeseriesSourceProvider] brings the tracker up when it arrives.
  ///
  /// **In gateway mode the source is never null**, so this no longer doubles
  /// as the silent off-switch it became when `databaseProvider` started
  /// branching on the transport.
  Future<void> start() async {
    final source = await _source();
    if (source == null || !_alive) return;
    // When the source is up from the start, onSourceAvailable fires the
    // moment the provider resolves — before this continuation gets its turn —
    // and has already initialised. Doing it again here would subscribe twice,
    // each time dropping and recreating the table's trigger.
    if (source == _readFrom) return;
    await _initData(source);
  }

  Future<void> _initData(TimeseriesSource source) async {
    final generation = ++_generation;
    _readFrom = source;
    bool superseded() => !_alive || generation != _generation;

    final sm = await _stateMan();
    if (superseded()) return;

    // Subscribe first, then fetch: a row landing between the two is then in
    // the fetch, or notified, or both — and both is fine, the cache is a set.
    // The other order leaves a gap the size of the fetch.
    await _subscribe(sm);
    if (superseded()) return;

    final merged = await _merge(
        sm, DateTime.now().subtract(Duration(minutes: _windowMinutes)));
    if (superseded()) return;

    if ((merged?.added ?? 0) > 0) notifyListeners();
    _startSweepTimer();
  }

  /// Opens the push channel, replacing any it already has.
  ///
  /// The stream ending or erroring — the connection under it died, and
  /// `AppDatabase` ends every channel stream when it notices — clears
  /// [_notifyAlive]; the next sweep fetches what was missed and calls this
  /// again. Failure to open at all (the table does not exist yet) is the
  /// same: the sweep keeps trying.
  ///
  /// **A source that answers null has no channel to open**, and that is not a
  /// failure. It sets [_transportPushes] false, says so once, and returns; the
  /// sweep then polls at [kTimeseriesPollInterval] and never asks again. See
  /// [transportPushes] for why the three states cannot be two.
  Future<void> _subscribe(StateMan sm) async {
    final source = _readFrom;
    if (source == null || !_alive) return;
    // Not awaited: there is nothing to wait for, and a cancel's future is
    // completed in the root zone, which under a fake-async test never gets
    // its turn — the whole sweep would stall behind it.
    _notifySub?.cancel();
    _notifySub = null;
    _notifyAlive = false;
    try {
      final tableName = sm.resolveKey(tsKey);
      final stream = await source.liveInserts(tableName);
      if (!_alive || source != _readFrom) return;
      if (stream == null) {
        _transportPushes = false;
        if (!_reportedPolling) {
          _reportedPolling = true;
          _log.i('"$tsKey" is polled every '
              '${kTimeseriesPollInterval.inSeconds}s: this station\'s '
              'timeseries source has no push channel. This is the gateway '
              'transport, not a fault — no re-subscribe will be attempted.');
        }
        return;
      }
      late final StreamSubscription<TimeseriesInsert> sub;
      sub = stream.listen(
        (insert) {
          if (!_alive) return;
          final fresh = cache.addEntry(tsKey, insert.time, insert.value);
          cache.prune(_windowMinutes);
          if (fresh) notifyListeners();
        },
        onError: (Object error) => _channelLost(sub, 'errored: $error'),
        onDone: () => _channelLost(sub, 'ended'),
      );
      _notifySub = sub;
      _notifyAlive = true;
      _transportPushes = true;
      _subscribeFailures = 0;
      _ticksUntilRetry = 0;
    } catch (e) {
      // Table may not exist yet, or the database is unreachable. The sweep
      // polls this key and retries the subscription, backing off while the
      // failures repeat.
      _subscribeFailures++;
      final skip = (1 << _subscribeFailures) - 1;
      _ticksUntilRetry =
          skip < _maxRetrySkipTicks ? skip : _maxRetrySkipTicks;
      _log.d('NOTIFY subscription for "$tsKey" not available yet '
          '(failure $_subscribeFailures, next attempt in '
          '${_ticksUntilRetry + 1} tick(s)): $e');
    }
  }

  /// The NOTIFY stream stopped. From here until the next sweep re-subscribes
  /// it, the key is polled.
  void _channelLost(StreamSubscription<TimeseriesInsert> sub, String how) {
    // A stream superseded by a fresh subscription may still report its end;
    // that is not news about the current one.
    if (!identical(_notifySub, sub)) return;
    _notifySub = null;
    _notifyAlive = false;
    sub.cancel();
    if (!_alive) return;
    _log.w('NOTIFY stream for "$tsKey" $how; '
        'polling until it can be re-subscribed');
  }

  /// (Re)starts the sweep timer at the cadence this transport needs.
  ///
  /// [kTimeseriesResyncInterval] where the source pushes — the sweep is a
  /// reconciliation, and the rows arrive on the channel between ticks. On a
  /// source that cannot push, the sweep **is** the delivery, and it runs at
  /// [kTimeseriesPollInterval]; a thirty-second step on a gateway panel is
  /// visibly wrong beside the same readout on a direct station.
  void _startSweepTimer() {
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(
        _transportPushes ? kTimeseriesResyncInterval : kTimeseriesPollInterval,
        (_) {
      if (!_alive || !_anyVisible) return;
      unawaited(_sweep());
    });
  }

  /// Reconciles now, rather than at the next tick.
  ///
  /// The public spelling of the sweep. A readout that has just been told its
  /// source came back — or a test — needs to be able to ask, and reaching for
  /// the private one from outside is how a second cadence grows.
  Future<void> refreshNow() => _sweep();

  /// Reconciles the cache with the database.
  ///
  /// With the NOTIFY stream gone the full window is fetched again and the
  /// stream re-opened. With the stream looking fine the last [window] is
  /// merged in — cheap, an index range on a few dozen rows — which both
  /// corrects the count and tests the stream: rows older than
  /// [kTimeseriesNotifyGrace] that only the database knew about mean it has
  /// quietly stopped delivering, and it is re-opened on the spot. The trigger
  /// gets recreated by that, which is the cure for the one way a stream goes
  /// quiet with its connection intact — a table recreate dropping the
  /// trigger.
  Future<void> _sweep({Duration window = kTimeseriesResyncWindow}) async {
    if (_readFrom == null || !_alive || _sweeping) return;
    _sweeping = true;
    try {
      final sm = await _stateMan();
      if (!_alive) return;
      final maxWindow = Duration(minutes: _windowMinutes);
      var changed = false;
      if (_notifyAlive) {
        final slice = window < maxWindow ? window : maxWindow;
        final now = DateTime.now();
        final missed = await _merge(sm, now.subtract(slice),
            missedBefore: now.subtract(kTimeseriesNotifyGrace));
        if (!_alive) return;
        if (missed != null) {
          if (missed.added > 0) changed = true;
          if (missed.silent > 0) {
            _log.w('NOTIFY stream for "$tsKey" has gone quiet: '
                '${missed.silent} row(s) older than '
                '${kTimeseriesNotifyGrace.inSeconds}s arrived without a '
                'notification; re-subscribing');
            await _subscribe(sm);
          }
        }
      } else if (!_transportPushes) {
        // The poll IS the delivery on this transport. No re-subscribe, no
        // backoff, no warning — there is no channel to re-open, and the sweep
        // ran at [kTimeseriesPollInterval] precisely so this branch carries
        // the readout.
        final slice = window < maxWindow ? window : maxWindow;
        final missed = await _merge(sm, DateTime.now().subtract(slice));
        if (!_alive) return;
        if ((missed?.added ?? 0) > 0) changed = true;
      } else {
        if (_ticksUntilRetry > 0) {
          _ticksUntilRetry--;
        } else {
          await _subscribe(sm);
          if (!_alive) return;
          // A source that has just told us it does not push must not fall
          // through to the retry cadence below; it now owns the branch above.
          if (!_transportPushes) _startSweepTimer();
        }
        // A successful (re)subscribe earns the full-window fetch that closes
        // whatever gap the outage left. While attempts are backing off, the
        // cheap slice keeps the readout current from polling alone.
        final span = _notifyAlive
            ? maxWindow
            : (window < maxWindow ? window : maxWindow);
        final missed = await _merge(sm, DateTime.now().subtract(span));
        if ((missed?.added ?? 0) > 0) changed = true;
      }
      if (!_alive) return;
      cache.prune(_windowMinutes);
      if (changed) notifyListeners();
    } finally {
      _sweeping = false;
    }
  }

  /// Fetches rows since [since] and merges them into the cache.
  ///
  /// Returns how many were new, and how many of those were already older
  /// than [missedBefore] — rows NOTIFY should have delivered long ago. Null
  /// when the query failed (the table may not exist yet), which is not the
  /// same as nothing new.
  Future<({int added, int silent})?> _merge(StateMan sm, DateTime since,
      {DateTime? missedBefore}) async {
    final source = _readFrom;
    if (source == null) return null;
    try {
      final tableName = sm.resolveKey(tsKey);
      final rows = await source.queryTimeseriesData(tableName, since,
          orderBy: 'time ASC');
      if (!_alive || source != _readFrom) return null;
      _clearFetchError();
      var silent = 0;
      if (missedBefore != null) {
        for (final row in rows) {
          if (row.time.isBefore(missedBefore) &&
              !cache.contains(tsKey, row.time)) {
            silent++;
          }
        }
      }
      final added =
          cache.addEntries(tsKey, [for (final r in rows) (r.time, r.value)]);
      return (added: added, silent: silent);
    } catch (e) {
      _recordFetchError(e);
      return null;
    }
  }

  /// Records a failed fetch and says so **once** per fault, not per sweep.
  ///
  /// The first failure after a working read is a warning naming the key,
  /// because on a source that cannot push this is the only delivery path and
  /// a readout stuck at zero has no other explanation on screen. Repeats stay
  /// at debug: a table that does not exist yet is the ordinary case on a
  /// station whose collector has not run, and a warning every five seconds
  /// about it is a warning nobody reads.
  void _recordFetchError(Object error) {
    final was = _fetchError;
    _fetchError = '$error';
    if (was == null) {
      _log.w('History for "$tsKey" could not be read: $error. Readouts over '
          'this key are showing what they last had, which is NOT a '
          'measurement of the plant.');
      notifyListeners();
    } else {
      _log.d('History for "$tsKey" still not available: $error');
    }
  }

  /// Clears the fault a working read disproves, and tells listeners.
  void _clearFetchError() {
    if (_fetchError == null) return;
    _fetchError = null;
    notifyListeners();
  }

  void _detach(TimeseriesTrackerHandle handle) {
    final wasVisible = _anyVisible;
    _handles.remove(handle);
    if (wasVisible && !_anyVisible) _onVisibilityChanged(wasAnyVisible: true);
    // Disposal when the last handle goes is the provider's job (autoDispose),
    // not ours — a new subscriber may be arriving in the same frame.
  }

  void _onVisibilityChanged({required bool wasAnyVisible}) {
    final nowVisible = _anyVisible;
    if (nowVisible && !wasAnyVisible) {
      // Back in front of an operator: reconcile now rather than at the next
      // tick, over a window that covers everything the sweep did not look at
      // while nobody was watching. NOTIFY kept the cache current in the
      // meantime if it was delivering; this is for when it was not.
      final hiddenFor = _quietSince == null
          ? Duration.zero
          : DateTime.now().difference(_quietSince!);
      _quietSince = null;
      if (_readFrom != null) {
        _startSweepTimer();
        unawaited(_sweep(window: hiddenFor + kTimeseriesResyncWindow));
      }
    } else if (!nowVisible && wasAnyVisible) {
      _quietSince = DateTime.now();
      _sweepTimer?.cancel();
      _sweepTimer = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sweepTimer?.cancel();
    _notifySub?.cancel();
    _notifySub = null;
    _handles.clear();
    cache.clear();
    super.dispose();
  }
}

/// One subscriber's stake in a [TimeseriesKeyTracker]: its visibility.
///
/// The tracker sweeps while any handle is visible and pauses when none is;
/// the first handle turning visible again triggers an immediate catch-up
/// sweep over the hidden stretch.
class TimeseriesTrackerHandle {
  TimeseriesTrackerHandle._(this._tracker);

  final TimeseriesKeyTracker _tracker;
  bool _visible = true;

  set visible(bool value) {
    if (_visible == value) return;
    final wasAnyVisible = _tracker._anyVisible;
    _visible = value;
    _tracker._onVisibilityChanged(wasAnyVisible: wasAnyVisible);
  }

  void detach() => _tracker._detach(this);
}

/// The shared per-key tracker. Alive while anyone listens (`listenManual`
/// from the readouts), disposed when the last one goes.
final timeseriesTrackerProvider =
    Provider.autoDispose.family<TimeseriesKeyTracker, String>((ref, key) {
  final tracker = TimeseriesKeyTracker(
    tsKey: key,
    source: () => ref.read(timeseriesSourceProvider.future),
    stateMan: () => ref.read(stateManProvider.future),
  );
  // `timeseriesSourceProvider` yields null while a DIRECT station's Postgres
  // is unreachable and retries itself; a genuinely new instance — first
  // connect, reconnect, new settings, a rebuilt relay client — re-runs the
  // tracker's init. In gateway mode it never yields null: it answers a
  // relayed source or throws by name.
  ref.listen<AsyncValue<TimeseriesSource?>>(timeseriesSourceProvider,
      (previous, next) {
    final source = next.valueOrNull;
    if (source != null) tracker.onSourceAvailable(source);
  });
  ref.onDispose(tracker.dispose);
  unawaited(tracker.start());
  return tracker;
});
