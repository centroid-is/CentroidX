/// The all-keys preference change signal: this gateway's writes, and
/// everybody else's.
///
/// ## Why not `PreferencesWatcher`
///
/// `tfc_dart` already has a class for exactly the gap this closes — a headless
/// process never hearing an edit an HMI station made — and it is **not
/// instantiated here**. Its constructor takes a `Set<String> keys` and freezes
/// it (`preferences_watch.dart:34-43`), which is the wrong shape for DB-03: a
/// key created after the watcher was built is invisible to it forever, and
/// DB-03 wants *any* preference's change to reach a second client. Research
/// §E.2 recommended listening to the channel underneath it directly, which is
/// what this does, and the citation is here so nobody re-adds the watcher for
/// symmetry.
///
/// The digest machinery goes with it. `PreferencesWatcher` answers every
/// signal with a server-side `md5(value)` query so a re-save of an identical
/// config is a no-op. That is worth its query when the watched set is fixed
/// and small; over *all* keys it is a query per notification against a table
/// whose largest row is half a megabyte, to suppress an event whose only cost
/// downstream is one coalesced frame. The trade is recorded rather than
/// inherited: **this feed announces a write, not a difference**, so a client
/// that saves the value it already had makes every panel re-read once.
///
/// ## The two halves, and why the merge needs de-duplication
///
///  * **Local** — `Preferences`' own broadcast controller
///    (`preferences.dart:154-155`), which fires for writes made through this
///    process. The gateway is the single writer for every connected client, so
///    this half alone satisfies contract check 13.
///  * **The channel** — `flutter_preferences`' keyed LISTEN/NOTIFY trigger,
///    which fires for writes made by *anybody*, including this gateway.
///
/// So a gateway-originated write arrives twice: once locally, and a few
/// milliseconds later as its own NOTIFY. [window] is what collapses that pair.
///
/// ### The window's arithmetic
///
/// 250 ms, and the number is a bound on **one event's round trip**, not a
/// guess about how busy the machine is. `pg_notify` delivers at commit; the
/// notification connection is a dedicated idle socket
/// (`database_drift.dart:470`, 8b-02's `…:notify` convention), so the delay
/// between the local stream firing and the NOTIFY landing is one TCP hop plus
/// the driver's read loop — single-digit milliseconds on a LAN and on the
/// loopback the gateway actually uses. 250 ms is roughly fifty times that.
///
/// What the margin costs, stated plainly: **two genuinely distinct edits to
/// the same key less than 250 ms apart are announced once.** That is safe for
/// every client this pipe has, because they all react by re-reading and the
/// re-read returns the later value; it would be wrong only for a client
/// counting edits, and nothing counts edits. The case that keeps this honest
/// is the one asserting a second change *outside* the window is **not**
/// suppressed — a window that had quietly become minutes would still pass the
/// first half.
///
/// De-duplication suppresses the *event* and never the [invalidate]: a
/// suppressed NOTIFY still drops the store's cache, so the read a client makes
/// after the one event it did get is fresh. Getting that backwards would trade
/// a duplicate frame for a stale answer.
///
/// ## The gap, made visible
///
/// The channel is listener-gated: it opens on the first subscriber and closes
/// with the last, because a gateway with no sessions has nobody to tell and no
/// reason to hold a connection open. That means there are two ways to be deaf
/// — nobody listening, and the notification connection dying — and both leave
/// a window in which somebody else's edit produces no event at all.
///
/// So every successful (re-)listen is followed by [resync], which re-reads the
/// table and announces every key that differs from the cache. A missed NOTIFY
/// therefore costs latency, not the event. A re-listen is also logged, because
/// a plant where preference edits sometimes arrive late should not be
/// indistinguishable from one where they always arrive at once.
///
/// ## An observation, and deliberately no change
///
/// `_preferenceChanged` on the client calls
/// `watchdog.sawFrame(InboundFrame.update)`
/// (`connection_supervisor.dart:764`), so a preference notification counts as
/// evidence the link is alive. That is consistent with "freshness resets on
/// any inbound frame", and it means a chatty preference store could mask a
/// dead *value* path. Nothing here changes because of it; the observation is
/// the deliverable.
///
/// ## The payload is the key and never the value
///
/// `enableKeyedNotificationChannel` ships `{"action":…,"key":…}` — a few dozen
/// bytes whatever the row holds (`database_drift.dart:1190-1238`). It has to:
/// `pg_notify` caps payloads at 8000 bytes and enforces the cap **by erroring
/// the statement that fired the trigger**, so a row-payload trigger on a table
/// holding a 530 KiB `key_mappings` would make every save of that row fail
/// outright. This file therefore reads the key out of the payload and goes
/// back to the table for anything else.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import 'timescale_reader.dart' show DatabaseSupplier;

/// Merges this gateway's own preference writes with everybody else's.
final class PreferenceChangeFeed {
  PreferenceChangeFeed({
    required this.database,
    required Stream<String> local,
    void Function()? invalidate,
    Future<Set<String>> Function()? resync,
    this.window = defaultWindow,
    this.relistenBackoff = defaultRelistenBackoff,
    int Function()? clock,
    this.log,
  })  : _local = local,
        _invalidate = invalidate,
        _resync = resync,
        _clock = clock ?? _uptimeMicros;

  /// How long after emitting a key another event for it is the same change.
  /// See the library doc for the arithmetic.
  static const Duration defaultWindow = Duration(milliseconds: 250);

  /// How long to wait before listening again after the channel dropped.
  ///
  /// A bare re-listen with no delay against a database that is down is a hot
  /// loop; `PreferencesWatcher` uses the same five seconds for the same
  /// reason (`preferences_watch.dart:41`).
  static const Duration defaultRelistenBackoff = Duration(seconds: 5);

  /// How long the listen probe is given to come back before the feed stops
  /// waiting for it and listens anyway. See [_proveListening].
  static const Duration probeTimeout = Duration(seconds: 5);

  /// How often the listen probe is resent while it has not come back.
  ///
  /// A dropped probe is not a late probe — see [_proveListening] — so the
  /// only way to find the moment `LISTEN` registers is to keep asking.
  static const Duration probeRetryInterval = Duration(milliseconds: 100);

  /// The table whose rows this watches, and the column its trigger names.
  static const String table = 'flutter_preferences';
  static const String keyColumn = 'key';

  final DatabaseSupplier database;
  final Duration window;
  final Duration relistenBackoff;
  final void Function(String message)? log;

  final Stream<String> _local;
  final void Function()? _invalidate;
  final Future<Set<String>> Function()? _resync;

  /// **Monotonic microseconds, never a wall clock** (10-REVIEW WR-02).
  ///
  /// Both durations this class measures — the de-duplication window and the
  /// probe deadline — used to be computed from `DateTime.now()`, and both
  /// failed on a backwards step. An NTP correction at boot on a plant PC is
  /// the ordinary case, not an exotic one, which is why the same doctrine
  /// already governs `RelaySession`'s liveness clock (08-CR-01/CR-02,
  /// 09-WR-01). This is its fourth site.
  ///
  ///  * *[_announce].* The suppression test was `at.difference(last) < window`.
  ///    After a backwards step of `d` that difference is negative for every key
  ///    already in [_announced], so **every preference change is suppressed for
  ///    the whole of `d`** — and the pruning line could not evict the stale
  ///    entries either, because the same comparison is inverted. `invalidate()`
  ///    still runs, so the gateway's own cache is fresh while every connected
  ///    panel renders a value nobody told it had changed. That is "the edit
  ///    nobody saw", which is the failure DB-03 exists to prevent.
  ///  * *[_proveListening].* A backwards step means the deadline never
  ///    arrives and the loop issues `pg_notify` every 100 ms indefinitely; a
  ///    forward step gives up on the first retry, losing the gap-close the
  ///    probe exists to guarantee.
  ///
  /// Injected so a test can drive it, and **defended at the comparison
  /// anyway**: an injected clock is a caller's value and a caller can hand
  /// back anything. See [_announce].
  final int Function() _clock;

  /// This process's uptime, in microseconds — the default [_clock].
  ///
  /// Static because the anchor has to outlive any one feed: two feeds built a
  /// second apart must agree about which of two instants came first, and a
  /// per-instance `Stopwatch` would give each its own zero.
  static final Stopwatch _uptime = Stopwatch()..start();

  static int _uptimeMicros() => _uptime.elapsedMicroseconds;

  StreamSubscription<String>? _localSub;
  StreamSubscription<String>? _channelSub;

  /// The re-listen back-off, one-shot and cancellable.
  ///
  /// Named `_timer` because `freeze_test.dart`'s sweep requires a retained
  /// `Timer(` to sit on a line that names a field, so that it is reachable
  /// and cancellable — and `preference_change_feed.dart` is on that file's
  /// `retainedTimerAllowList` with `declaredRetainedTimers` moved in the same
  /// commit. It only ever exists while somebody is listening: [_stop] cancels
  /// it, so a feed nobody is subscribed to holds no timer at all.
  Timer? _timer;

  /// When each key was last announced, on [_clock], for the de-duplication
  /// window.
  final Map<String, int> _announced = <String, int>{};

  /// The in-flight listen probe, and the nonce it is waiting for.
  Completer<void>? _probe;
  String? _probeNonce;
  int _probeCount = 0;

  bool _closed = false;

  /// True once the channel has been subscribed and until it drops.
  bool _channelUp = false;

  /// Guards against two overlapping listen attempts — a re-listen firing
  /// while the previous attempt is still awaiting its `CREATE TRIGGER`.
  bool _listening = false;

  late final StreamController<String> _controller =
      StreamController<String>.broadcast(onListen: _start, onCancel: _stop);

  /// Every key whose value changed. Broadcast, and listener-gated.
  Stream<String> get changes => _controller.stream;

  /// Whether anybody is listening right now.
  bool get hasListener => _controller.hasListener;

  /// Whether the cross-process channel is currently subscribed.
  bool get channelUp => _channelUp;

  // ------------------------------------------------------------- lifecycle

  void _start() {
    if (_closed) return;
    _localSub = _local.listen(
      _announce,
      onError: (Object e) => log?.call('preference local stream error: $e'),
    );
    unawaited(_listenToChannel().catchError((Object e) {
      log?.call('preference notification listen failed: $e');
    }));
  }

  /// The in-flight teardown of the previous subscription.
  ///
  /// **`onCancel` cannot be awaited, and the notification connection is
  /// shared, and together those two facts are a bug** — measured, not
  /// imagined. Cancelling a `listenToChannel` subscription issues `UNLISTEN`
  /// on `AppDatabase`'s one notification connection
  /// (`database_drift.dart:1119-1140`); a `StreamController`'s `onCancel`
  /// returns void here, so the feed cannot hold that up. If the next
  /// subscriber's `LISTEN` goes out on the same connection before the
  /// previous one's `UNLISTEN` lands, the server applies them in the wrong
  /// order and the **new** subscriber is silently unsubscribed — up and
  /// hearing nothing, with no error anywhere.
  ///
  /// That is a session-churn bug in production and not only in a suite: the
  /// channel is listener-gated, so the last session leaving and the next one
  /// arriving is exactly this sequence. Keeping the future here and awaiting
  /// it before the next `LISTEN` serialises the pair.
  Future<void>? _stopping;

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _channelUp = false;
    unawaited(_localSub?.cancel().catchError((Object _) {}));
    _localSub = null;
    final channel = _channelSub;
    _channelSub = null;
    if (channel != null) {
      _stopping = channel.cancel().catchError((Object _) {});
    }
  }

  /// Opens the keyed channel and subscribes to it, then closes whatever gap
  /// there was while it was not listening.
  Future<void> _listenToChannel() async {
    if (_closed || _listening || !_controller.hasListener) return;
    _listening = true;
    try {
      // Before anything is sent: see [_stopping].
      final stopping = _stopping;
      if (stopping != null) {
        await stopping;
        if (identical(_stopping, stopping)) _stopping = null;
        if (_closed || !_controller.hasListener) return;
      }
      // The 10-08 seam: the supplier's value carries the static type, so
      // these are checked calls and this file still does not import the
      // database layer.
      final db = (database() ?? _noStore()).db;
      final channel = await db.enableKeyedNotificationChannel(table, keyColumn);
      if (_closed || !_controller.hasListener) return;
      final sub = db.listenToChannel(channel).listen(
        _onPayload,
        onError: (Object e) {
          log?.call('preference notification channel error: $e');
        },
        // `listenToChannel` ends the stream — onDone, no error — when the
        // connection carrying it dies (`database_drift.dart:1066-1069`).
        onDone: _channelDropped,
      );
      // **Re-checked after the assignment, not only before it** (10-REVIEW
      // WR-09). The guard one line up runs, then `listen` happens; if the last
      // subscriber cancels in that gap, [_stop] reads a still-null
      // [_channelSub], sets no [_stopping] and returns — and this line would
      // then install a subscription nothing cancels until [close]. A live
      // `LISTEN` on the shared notification connection with no listener behind
      // it is exactly what [_stopping] exists to serialise away, arriving one
      // statement earlier than that machinery guards, and session churn is the
      // ordinary case rather than the exotic one.
      //
      // Unwound into [_stopping] rather than merely cancelled, so the next
      // `LISTEN` still waits for this `UNLISTEN` to land: out of order, the
      // server silently unsubscribes the NEW subscriber.
      if (_closed || !_controller.hasListener) {
        _stopping = sub.cancel().catchError((Object _) {});
        return;
      }
      _channelSub = sub;
      // **A wall clock here on purpose**, and the one place it is right: a
      // nonce is not a duration. What it has to be is unlikely to collide with
      // a *neighbouring gateway's* probe on the same channel, and two
      // processes share no uptime origin — [_probeCount] alone would have both
      // of them at 0. An NTP step cannot hurt it: a repeated nonce would at
      // worst complete a probe the same feed is already waiting for.
      final nonce =
          '${DateTime.now().microsecondsSinceEpoch}-${_probeCount++}';
      await _proveListening(nonce, () async {
        await db.customSelect(r'SELECT pg_notify($1, $2)', variables: [
          Variable.withString(channel),
          Variable.withString(jsonEncode({'action': 'PROBE', 'probe': nonce})),
        ]).get();
      });
      // Checked again, for WR-09's other half: [_proveListening] returns early
      // on its own `hasListener` test, and control used to fall straight
      // through to here — so the feed reported the channel as up with nobody
      // listening, and [_closeTheGap] then ran two full reads of the store for
      // an audience of none.
      if (_closed || !_controller.hasListener) return;
      _channelUp = true;
    } catch (e) {
      log?.call('preference notification channel could not be opened, '
          'retrying in ${relistenBackoff.inSeconds}s: $e');
      _scheduleRelisten();
      return;
    } finally {
      _listening = false;
    }
    // Only after the channel is up, so nothing that happens from here on is
    // missed: anything that changed while it was down is caught by the
    // comparison, and anything after it arrives as a notification.
    await _closeTheGap();
  }

  /// Notifies this channel until one of those notifications comes back.
  ///
  /// **This is what makes [_closeTheGap] a gap-closer rather than a race, and
  /// it has to retry rather than send once.** `listenToChannel` hands back a
  /// stream whose `onListen` opens the shared connection and issues `LISTEN`
  /// *asynchronously* (`database_drift.dart:1076-1118`), so the subscription
  /// object exists some time before Postgres has registered it. In that
  /// window a commit is announced by neither a notification (nobody is
  /// registered) nor the resync (which has not run yet).
  ///
  /// A single probe cannot detect the window it is trying to close, because
  /// **`pg_notify` delivers only to sessions listening at the moment it
  /// fires**: a probe sent one millisecond too early is not delayed, it is
  /// dropped, and waiting five seconds for it waits for something that will
  /// never arrive. Measured, and it is how this was found — the first
  /// implementation sent one probe and logged a five-second timeout on a
  /// channel that was working perfectly. So the probe repeats every
  /// [probeRetryInterval] until one returns. The first to come back proves
  /// the `LISTEN` is registered, and everything committed after that moment
  /// is heard.
  ///
  /// The payload carries no `key`, so [_keyFromPayload] answers null and
  /// nothing is announced — including in the application's own
  /// `PreferencesWatcher`, which reads the same field and skips a null the
  /// same way (`preferences_watch.dart:121-129`). Other listeners on this
  /// channel therefore see a message they already know to ignore.
  ///
  /// A probe that never comes back is logged and **does not fail the
  /// listen**: the subscription is real either way, and treating a slow probe
  /// as a dead channel would spin the back-off against a database that is
  /// working.
  ///
  /// [send] is built at the call site, where the database's static type is
  /// the one [DatabaseSupplier] declares. Taking a `dynamic` here instead
  /// would have kept the import freeze at two and thrown away every
  /// compile-time check on the statement, which is the trade 10-08 refused.
  Future<void> _proveListening(
      String nonce, Future<void> Function() send) async {
    final probe = Completer<void>();
    _probeNonce = nonce;
    _probe = probe;
    final giveUpAt = _clock() + probeTimeout.inMicroseconds;
    try {
      while (!probe.isCompleted) {
        await send();
        try {
          await probe.future.timeout(probeRetryInterval);
        } on TimeoutException {
          if (_closed || !_controller.hasListener) return;
          if (_clock() > giveUpAt) {
            log?.call('the preference notification probe did not come back '
                'within ${probeTimeout.inMilliseconds}ms; listening anyway, '
                'but a change made in the last moment may only be seen at '
                'the next resync');
            return;
          }
        }
      }
    } finally {
      _probeNonce = null;
      _probe = null;
    }
  }

  void _channelDropped() {
    if (_closed) return;
    _channelUp = false;
    log?.call('the preference notification connection ended; edits made by '
        'other processes are not being heard until it is re-established');
    _scheduleRelisten();
  }

  void _scheduleRelisten() {
    if (_closed || !_controller.hasListener) return;
    _timer?.cancel();
    _timer = Timer(relistenBackoff, () {
      unawaited(_listenToChannel().catchError((Object e) {
        log?.call('preference notification re-listen failed: $e');
      }));
    });
  }

  /// Announces every key that changed while nothing was listening.
  Future<void> _closeTheGap() async {
    final resync = _resync;
    if (resync == null) return;
    try {
      final changed = await resync();
      if (changed.isEmpty) return;
      // Named, and at info level by the caller's choosing: this is the
      // evidence that a gap existed at all. A gateway that silently caught
      // up looks exactly like one that never fell behind.
      log?.call('${changed.length} preference(s) changed while this gateway '
          'was not listening and are being announced now: '
          '${changed.join(', ')}');
      for (final key in changed) {
        if (_closed) return;
        _announce(key);
      }
    } catch (e) {
      log?.call('preference resync after (re-)listen failed: $e');
    }
  }

  // ---------------------------------------------------------------- events

  void _onPayload(String payload) {
    if (_isOurProbe(payload)) {
      final probe = _probe;
      if (probe != null && !probe.isCompleted) probe.complete();
      return;
    }
    final key = _keyFromPayload(payload);
    if (key == null) return;
    // ALWAYS, and before the de-duplication: a suppressed event must still
    // leave the cache fresh, or the one event a client does get leads it to
    // read the value it already had.
    _invalidate?.call();
    _announce(key);
  }

  /// Whether [payload] is the probe **this** feed is waiting for.
  ///
  /// By nonce, not by shape: several gateways can share a database, and a
  /// neighbour's probe must not be mistaken for ours or the ordering
  /// guarantee in [_proveListening] would be somebody else's round trip.
  bool _isOurProbe(String payload) {
    final nonce = _probeNonce;
    if (nonce == null) return false;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> && decoded['probe'] == nonce;
    } catch (_) {
      return false;
    }
  }

  /// The payload shape `enableKeyedNotificationChannel` writes:
  /// `{"action": "UPDATE", "key": "key_mappings"}`.
  static String? _keyFromPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded['key'] as String?;
    } catch (_) {
      // Not ours, or malformed. Nothing to announce and nothing to fix: the
      // channel is named after this table, so this is somebody else's
      // trigger and their business.
    }
    return null;
  }

  void _announce(String key) {
    if (_closed || _controller.isClosed) return;
    final at = _clock();
    final windowUs = window.inMicroseconds;
    final last = _announced[key];
    // **The negative arm is the belt** (10-REVIEW WR-02). [_clock] is
    // monotonic by default and cannot go backwards, but it is injectable and
    // an injected clock is a caller's value. A negative elapsed time means the
    // clock moved backwards, and the honest reading of that is "long ago" —
    // announce, and re-anchor. Treating it as "just now" is what suppressed
    // every change for the whole of the step.
    final since = last == null ? null : at - last;
    if (since != null && since >= 0 && since < windowUs) return;
    _announced
      ..removeWhere((_, when) {
        final age = at - when;
        // Same rule for the prune: a negative age is not a fresh entry, it is
        // an entry the clock stepped over, and leaving it in is what made the
        // suppression permanent.
        return age < 0 || age >= windowUs;
      })
      ..[key] = at;
    _controller.add(key);
  }

  Never _noStore() => throw StateError(
      'the preference store has no database, so there is no channel to '
      'listen on');

  /// Releases the channel, the local subscription and the back-off timer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _channelUp = false;
    await _localSub?.cancel();
    _localSub = null;
    await _channelSub?.cancel();
    _channelSub = null;
    // A teardown `_stop` started and could not await. Awaiting it here is
    // what makes `close()` mean "nothing of mine is still in flight".
    await _stopping;
    _stopping = null;
    await _controller.close();
  }
}
