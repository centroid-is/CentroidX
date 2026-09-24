import 'dart:async';
import 'dart:collection';
import 'package:rxdart/rxdart.dart';
import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../converter/dynamic_value_converter.dart';
import '../core/boolean_expression.dart';
import 'collect_config.dart';
import 'state_man_types.dart';
import 'database.dart';

// CollectEntry / CollectorConfig live in a file with no database behind it,
// because a key mapping carries one and every client parses key mappings.
export 'collect_config.dart';



class Collector {
  final CollectorConfig config;
  final StateMan stateMan;

  /// Where stored rows are read from — [collectStream]'s backfill, and the
  /// history panes'. The [database] itself where this process has one; the
  /// relay's timeseries reads on a gateway panel ([Collector.readOnly]).
  final TimeseriesReader history;

  final Database? _database;

  /// The database this collector writes to. Only the process that collects
  /// has one: a [Collector.readOnly] never inserts, and asking it for a
  /// database is a defect in the caller rather than a state to handle.
  Database get database =>
      _database ??
      (throw StateError('this collector reads history over the relay and '
          'has no database; collecting needs one'));
  final Map<String, CollectEntry> _collectEntries = {};
  final Map<CollectEntry, StreamSubscription<DynamicValue>> _subscriptions = {};
  final Map<CollectEntry, Stream<DynamicValue>> _realTimeStreams = {};
  final Map<CollectEntry, AutoDisposingStream<List<TimeseriesData<dynamic>>>>
      _collectStreams = {};
  final Map<CollectEntry, Evaluator> _evaluators = {};
  final Map<CollectEntry, Timer> _sampleTimers = {};
  // Recovery from a collected stream completing under us (see the onDone in
  // collectEntryImpl). One generation per collectEntryImpl call: a done from
  // a superseded listener, or a retry that fires after stopCollect, close or
  // a re-collect, must find its generation gone and do nothing.
  final Map<CollectEntry, int> _generation = {};
  final Map<CollectEntry, Timer> _resubscribeTimers = {};
  final Map<CollectEntry, int> _resubscribeFailures = {};
  bool _closed = false;
  final Logger logger = Logger();

  // Performance instrumentation
  int _eventCount = 0;
  int _insertCount = 0;
  final Stopwatch _uptime = Stopwatch();
  final Stopwatch _jsonConversionTime = Stopwatch();
  final Stopwatch _insertTime = Stopwatch();
  DateTime? _lastStatsReset;

  static const configLocation = 'collector_config';

  Collector({
    required this.config,
    required this.stateMan,
    required Database database,
  })  : _database = database,
        history = database {
    _start();
  }

  /// A collector that records nothing and reads its history from [history] —
  /// a gateway panel's, whose rows live behind the backend.
  ///
  /// [config] must not collect: there is nothing here to insert into.
  Collector.readOnly({
    required this.config,
    required this.stateMan,
    required this.history,
  })  : assert(!config.collect, 'a read-only collector cannot collect'),
        _database = null {
    _start();
  }

  void _start() {
    _uptime.start();
    _lastStatsReset = DateTime.now();
    final keyMappings = stateMan.keyMappings;
    var skipped = 0;
    for (var value in keyMappings.nodes.values) {
      if (value.collect == null) continue;
      // A key on a disabled server has no client to subscribe to. Counting
      // them and logging once keeps the startup log to a single line instead
      // of one failure per key.
      if (stateMan.isKeyDisabled(value.collect!.key)) {
        skipped++;
        continue;
      }
      // The Future MUST be handled. This runs inside the data-acquisition
      // isolate, which is spawned with errorsAreFatal (the default), so a
      // discarded Future that rejects is an uncaught async error that kills
      // acquisition for the WHOLE server and sends the supervisor into a
      // respawn loop. The easy trigger is a key still naming an unresolved
      // $variable: those resolve in the UI when an OptionVariable asset
      // publishes, but nothing publishes substitutions inside the acquisition
      // isolate, so the key stays templated and subscribe() throws every time.
      // One unstartable key must cost exactly that key.
      final entry = value.collect!;
      unawaited(collectEntry(entry).catchError((Object e) {
        logger.e('[collector] could not start collection for "${entry.key}" '
            '(this key only): $e');
      }));
    }
    if (skipped > 0) {
      logger.i('[collector] Skipped $skipped collected key(s) on disabled '
          'server(s)');
    }
  }

  Future<Stream<DynamicValue>> _toBeCollected(CollectEntry entry) async {
    if (entry.sampleExpression != null) {
      _evaluators[entry] = Evaluator(
        stateMan: stateMan,
        expression: entry.sampleExpression!,
      );
      final shouldSampleStream = _evaluators[entry]!.state();
      final dataStream = await stateMan.subscribe(entry.key);

      // Combine streams: emit latest data value when sample condition is not null
      return shouldSampleStream
          .where((sampleCondition) => sampleCondition != null)
          .switchMap((_) => dataStream.take(1))
          .asBroadcastStream();
    }
    return await stateMan.subscribe(entry.key);
  }

  /// Initiate a collection of data from a node.
  /// Returns when the collection is started.
  Future<void> collectEntry(CollectEntry entry) async {
    _collectEntries[entry.key] =
        entry; // needs to be here for non collection client, but fetching data from other collectors
    if (!config.collect) {
      return;
    }

    final subscription = await _toBeCollected(entry);
    await collectEntryImpl(entry, subscription);
  }

  Future<void> collectEntryImpl(
      CollectEntry entry, Stream<DynamicValue> subscription,
      {bool skipFirstSample = true}) async {
    _collectEntries[entry.key] = entry; // todo: duplicated for testing
    final name = collectTableName(entry);
    await database.registerRetentionPolicy(name, entry.retention);

    // Member extraction happens BEFORE the broadcast split so the insert
    // path and the real-time chart stream agree on what a sample is.
    final members = entry.sampleMembers;
    if (members != null && members.isNotEmpty) {
      var warned = false;
      subscription = subscription
          .map((value) {
            final row = extractSampleMembers(value, members);
            if (row == null && !warned) {
              warned = true;
              logger.w('[collector] $name: none of sample_members $members '
                  'found in value — samples are being skipped');
            }
            return row;
          })
          .where((value) => value != null)
          .cast<DynamicValue>();
    }

    subscription = subscription.asBroadcastStream();

    // Claim this entry. Anything the previous collectEntryImpl for it left
    // behind -- its listener's onDone, a pending resubscribe -- is stale now.
    final gen = (_generation[entry] ?? 0) + 1;
    _generation[entry] = gen;
    _resubscribeTimers.remove(entry)?.cancel();

    // Variables for sampling logic
    Timer? sampleTimer;
    DynamicValue? latestValue;

    Future<void> insertValue(DynamicValue newValue) async {
      _insertCount++;
      final time = DateTime.now().toUtc();
      final value = const DynamicValueConverter().toJson(newValue, slim: true);
      try {
        await database.insertTimeseriesData(name, time, value);
      } catch (e) {
        logger.w('Insert failed for $name: $e');
      }
    }

    _subscriptions[entry] = subscription.listen(
      (value) {
        _eventCount++;
        // A value proves the subscription is alive: the next done starts the
        // ladder from its first rung again.
        _resubscribeFailures.remove(entry);
        if (_eventCount % 1000 == 1 || _eventCount <= 5) {
          logger.d('[collector] $name received value #$_eventCount');
        }
        if (entry.sampleInterval == null) {
          if (skipFirstSample) {
            skipFirstSample = false;
            return;
          }
          // No sampling - collect every value immediately
          // Don't await - just fire and forget for better performance
          unawaited(insertValue(value));
        } else {
          // Store the latest value for periodic sampling
          latestValue = value;
        }
      },
      onError: (error, stackTrace) {
        logger.e(
            '[collector] Error for $name (subscription will continue): $error',
            error: error,
            stackTrace: stackTrace);
      },
      onDone: () {
        // The stream behind a collected key completes when its OPC UA
        // subscription is lost for good: the server drops the SecureChannel,
        // the raw stream reports done, and AutoDisposingStream closes the
        // subject and retires the entry. Every other consumer survives that
        // because it subscribes again on its own -- a panel on its next
        // navigation, and StateMan builds it a fresh subscription because the
        // spent entry is gone. The collector subscribes once for the life of
        // the process, so for it a done used to be terminal: the sample timer
        // was cancelled, the log said "no more data will be collected", and
        // that was true until the backend was restarted.
        //
        // Now a done is the cue to subscribe again. StateMan.subscribe()
        // itself keeps trying for as long as the server is away, so the wait
        // here only has to keep the collector from hammering a server that
        // just lost hundreds of subscriptions at once -- the storm the ladder
        // in state_man.dart exists for, so it is the same ladder.
        sampleTimer?.cancel();
        if (_closed || _generation[entry] != gen) return;
        _subscriptions.remove(entry);
        _scheduleResubscribe(entry, gen, name);
      },
    );

    // Set up periodic sampling if sample interval is specified
    if (entry.sampleInterval != null) {
      sampleTimer = Timer.periodic(entry.sampleInterval!, (timer) async {
        final val = latestValue;
        if (val == null) return;
        await insertValue(val);
      });
      // collectEntryImpl can run twice for one entry (a re-collect after a
      // mapping edit); without this the first timer is orphaned and keeps
      // inserting alongside its replacement.
      _sampleTimers[entry]?.cancel();
      _sampleTimers[entry] = sampleTimer;
    }

    _realTimeStreams[entry] = subscription;
  }

  /// Arms the next attempt to subscribe [entry] again after its stream
  /// completed, or after the previous attempt failed.
  ///
  /// The wait walks [kSubscribeBackoffSeconds] per consecutive failure and
  /// resets the moment a value arrives on the new stream. There is no give-up
  /// rung: the node comes back when its server does, and the top of the
  /// ladder is cheap enough to keep asking. Only [close] ends it.
  void _scheduleResubscribe(CollectEntry entry, int gen, String name) {
    final failures = (_resubscribeFailures[entry] ?? 0) + 1;
    _resubscribeFailures[entry] = failures;
    final delay = subscribeBackoffFor(failures);
    logger.w('[collector] Stream DONE for $name -- subscribing again in '
        '${delay.inSeconds}s (attempt $failures)');
    _resubscribeTimers.remove(entry)?.cancel();
    _resubscribeTimers[entry] = Timer(delay, () {
      _resubscribeTimers.remove(entry);
      unawaited(_resubscribe(entry, gen, name));
    });
  }

  Future<void> _resubscribe(CollectEntry entry, int gen, String name) async {
    if (_closed || _generation[entry] != gen) return;
    // _toBeCollected builds a fresh Evaluator for a sampled-by-expression
    // entry; the one that fed the dead stream would otherwise keep its
    // variable subscriptions alive with nobody listening.
    _evaluators.remove(entry)?.cancel();
    final Stream<DynamicValue> stream;
    try {
      stream = await _toBeCollected(entry);
    } catch (e) {
      // Nothing to hold on to: a failed subscribe leaves no stream, and
      // StateMan keeps or retires its own entry. Try again, one rung up --
      // unless the collector went away while this waited.
      if (_closed || _generation[entry] != gen) return;
      logger.e('[collector] subscribing $name again failed '
          '(attempt ${_resubscribeFailures[entry]}): $e');
      _scheduleResubscribe(entry, gen, name);
      return;
    }
    // The subscribe above can take as long as the server is away. If the
    // collector was closed, or the entry re-collected, while it waited, the
    // stream is somebody else's to own now.
    if (_closed || _generation[entry] != gen) return;
    try {
      // A fresh subscription replays the node's current value at once. After
      // a gap of unknown length that value is worth a row -- it is what marks
      // the series alive again -- so it is not skipped the way the first
      // value at startup is.
      await collectEntryImpl(entry, stream, skipFirstSample: false);
      logger.i('[collector] subscribed $name again');
    } catch (e) {
      if (_closed || _generation[entry] != gen) return;
      logger.e('[collector] subscribing $name again failed '
          '(attempt ${_resubscribeFailures[entry]}): $e');
      _scheduleResubscribe(entry, gen, name);
    }
  }

  /// Get performance statistics
  Map<String, dynamic> getStats() {
    final uptimeSec =
        _uptime.elapsed.inSeconds > 0 ? _uptime.elapsed.inSeconds : 1;
    return {
      'total_events': _eventCount,
      'events_per_sec': _eventCount / uptimeSec,
      'total_inserts': _insertCount,
      'inserts_per_sec': _insertCount / uptimeSec,
      'uptime_seconds': uptimeSec,
      'active_subscriptions': _subscriptions.length,
      'json_conversion_ms': _jsonConversionTime.elapsedMilliseconds,
      'avg_json_conversion_us': _insertCount > 0
          ? (_jsonConversionTime.elapsedMicroseconds / _insertCount)
              .toStringAsFixed(1)
          : '0',
      'insert_time_ms': _insertTime.elapsedMilliseconds,
      'avg_insert_ms': _insertCount > 0
          ? (_insertTime.elapsedMilliseconds / _insertCount).toStringAsFixed(2)
          : '0',
    };
  }

  /// Reset performance statistics
  void resetStats() {
    _eventCount = 0;
    _insertCount = 0;
    _uptime.reset();
    _uptime.start();
    _lastStatsReset = DateTime.now();
  }

  Stream<TimeseriesData<dynamic>> collectUpdates(String key) {
    key = stateMan.resolveKey(key);
    final entry = _collectEntries[key];

    if (entry == null) {
      return Stream.error(StateError('No collection configured for key: $key'));
    }
    // A station that is not the collector has the entry but no live stream:
    // collectEntry returns before populating _realTimeStreams when
    // config.collect is false. Match the sibling branch above rather than
    // throwing a bare null-check TypeError at the caller.
    final rt = _realTimeStreams[entry];
    if (rt == null) {
      return Stream.error(
          StateError('No live collection running for key: $key'));
    }
    return rt
        .map((value) => TimeseriesData<dynamic>(value, DateTime.now().toUtc()));
  }

  /// Returns a Stream of the collected data.
  /// This stream provides both historical data and real-time updates.
  Stream<List<TimeseriesData<dynamic>>> collectStream(String key,
      {Duration since = const Duration(days: 1)}) {
    key = stateMan.resolveKey(key);
    final entry = _entryFor(key);

    if (entry == null) {
      return Stream.error(StateError('No collection configured for key: $key'));
    }

    final sinceTime = DateTime.now().toUtc().subtract(since);

    // Check if we already have a subscription entry for this key
    if (_collectStreams.containsKey(entry)) {
      return _collectStreams[entry]!.stream;
    }

    final subscriptionEntry =
        AutoDisposingStream<List<TimeseriesData<dynamic>>>(
      collectTableName(entry),
      (name) {
        _collectStreams.remove(entry);
        logger.d('Removed collect stream entry for $name');
      },
      idleTimeout: const Duration(minutes: 30),
    );

    _collectStreams[entry] = subscriptionEntry;

    // Create a stream controller for real-time updates
    final streamController =
        StreamController<List<TimeseriesData<dynamic>>>.broadcast();

    StreamSubscription<DynamicValue>? realTimeSubscription;

    // History first, live second -- and never wait on live. The old order
    // awaited the OPC UA subscription before it touched the database, so a
    // key whose node cannot be monitored (a stats key the PLC no longer
    // publishes) kept its trend on a spinner for as long as the retry ladder
    // ran, which is forever, with a year of history sitting in the table.
    // Now the table answers on its own, the chart draws, and live samples
    // join in whenever the subscription comes up.
    var cancelled = false;
    streamController.onListen = () async {
      Queue<TimeseriesData<dynamic>>? historicalData;
      final Queue<TimeseriesData<dynamic>> buffer =
          Queue<TimeseriesData<dynamic>>();

      unawaited(() async {
        try {
          var rtStream = _realTimeStreams[entry] ?? await _toBeCollected(entry);
          if (cancelled) return;
          if (entry.sampleInterval != null) {
            rtStream =
                rtStream.throttleTime(entry.sampleInterval!, trailing: true);
          }
          realTimeSubscription = rtStream.listen(
            (value) {
              final newSample = TimeseriesData<dynamic>(
                const DynamicValueConverter().toJson(value, slim: true),
                DateTime.now().toUtc(),
              );
              final history = historicalData;
              if (history == null) {
                buffer.add(newSample);
                return;
              }
              history.add(newSample);

              // Remove old data outside the retention window
              final cutoffTime = DateTime.now().toUtc().subtract(since);
              while (history.isNotEmpty &&
                  history.first.time.isBefore(cutoffTime)) {
                history.removeFirst();
              }
              streamController.add(history.toList());
            },
            onError: (error, stackTrace) {
              logger.e('Error collecting data for key $key',
                  error: error, stackTrace: stackTrace);
            },
          );
          if (cancelled) realTimeSubscription?.cancel();
        } catch (e, st) {
          // Live failed; the history already drawn stays. Surface it on the
          // stream only if nothing has been delivered yet, so the chart says
          // why instead of waiting.
          logger.e('Failed to subscribe live data for key $key',
              error: e, stackTrace: st);
          if (historicalData == null && !streamController.isClosed) {
            streamController.addError(e);
          }
        }
      }());

      try {
        final rows = await this.history.queryTimeseriesData(
            collectTableName(entry), sinceTime);
        if (cancelled) return;
        final history = Queue<TimeseriesData<dynamic>>.from(rows)
          ..addAll(buffer.toList());
        historicalData = history;
        buffer.clear();
        streamController.add(history.toList());
      } catch (e) {
        logger.e('Failed to load historical data for key $key: $e');
        if (cancelled || streamController.isClosed) return;
        // Open the gate anyway.
        //
        // The live listener above holds every sample back until
        // `historicalData` is non-null, so a history query that never
        // succeeds meant live samples were buffered for a backfill that was
        // never coming: the chart showed the error and then never moved
        // again, however healthy the subscription behind it was. It also
        // grew `buffer` without bound -- on a 2 Hz key, for as long as the
        // stream lived.
        //
        // An empty window is the honest starting point: no stored history,
        // and everything from now on. The error still goes out first, so a
        // key that is genuinely dead says why instead of sitting on a
        // spinner.
        final opened = Queue<TimeseriesData<dynamic>>.from(buffer);
        buffer.clear();
        historicalData = opened;
        streamController.addError(e);
        if (opened.isNotEmpty) streamController.add(opened.toList());
      }
    };

    // Use the raw stream to feed the subscription entry
    subscriptionEntry.subscribe(streamController.stream, null);

    // Clean up when the stream is cancelled
    streamController.onCancel = () {
      cancelled = true;
      realTimeSubscription?.cancel();
      streamController.close();
    };

    return subscriptionEntry.stream;
  }

  /// The collect entry for [key]: the one registered at construction, or —
  /// failing that — the one the StateMan's mappings carry **now**.
  ///
  /// The second half is for a gateway panel. Its mappings arrive over the
  /// relay and are taken in place after the StateMan is built (on a browser's
  /// first visit the boot set is empty), so a collector that only knew the
  /// entries it was constructed with would refuse every trend until a reload.
  /// Only reads come this way: nothing here starts collecting.
  CollectEntry? _entryFor(String key) {
    final known = _collectEntries[key];
    if (known != null) return known;
    final adopted = stateMan.keyMappings.nodes[key]?.collect;
    if (adopted != null) _collectEntries[key] = adopted;
    return adopted;
  }

  /// Stop a collection.
  void stopCollect(CollectEntry entry) {
    // Retire the listener's onDone and any retry in flight for this entry.
    _generation[entry] = (_generation[entry] ?? 0) + 1;
    _resubscribeTimers.remove(entry)?.cancel();
    _resubscribeFailures.remove(entry);
    _subscriptions[entry]?.cancel();
    _subscriptions.remove(entry);
    _sampleTimers.remove(entry)?.cancel();
    _evaluators[entry]?.cancel();
    _evaluators.remove(entry);
  }

  void close() {
    // Before the cancels: cancelling a subscription does not run its onDone,
    // but a retry already armed would otherwise fire into a closed collector
    // and subscribe on its behalf.
    _closed = true;
    for (final timer in _resubscribeTimers.values) {
      timer.cancel();
    }
    _resubscribeTimers.clear();
    _resubscribeFailures.clear();
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();

    for (final evaluator in _evaluators.values) {
      evaluator.cancel();
    }
    _evaluators.clear();

    for (final timer in _sampleTimers.values) {
      timer.cancel();
    }
    _sampleTimers.clear();
  }
}
