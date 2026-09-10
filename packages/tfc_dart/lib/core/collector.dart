import 'dart:async';
import 'dart:collection';
import 'package:rxdart/rxdart.dart';
import 'package:logger/logger.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../converter/dynamic_value_converter.dart';
import '../converter/duration_converter.dart';
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
  final Database database;
  final Map<String, CollectEntry> _collectEntries = {};
  final Map<CollectEntry, StreamSubscription<DynamicValue>> _subscriptions = {};
  final Map<CollectEntry, Stream<DynamicValue>> _realTimeStreams = {};
  final Map<CollectEntry, AutoDisposingStream<List<TimeseriesData<dynamic>>>>
      _collectStreams = {};
  final Map<CollectEntry, Evaluator> _evaluators = {};
  final Map<CollectEntry, Timer> _sampleTimers = {};
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
    required this.database,
  }) {
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
        logger.e('[collector] Stream DONE for $name — '
            'no more data will be collected! sampleTimer active=${sampleTimer?.isActive}');
        // Clean up timer when stream is done
        sampleTimer?.cancel();
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
    final entry = _collectEntries[key];

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
        final rows = await database.queryTimeseriesData(
            collectTableName(entry), sinceTime);
        if (cancelled) return;
        final history = Queue<TimeseriesData<dynamic>>.from(rows)
          ..addAll(buffer.toList());
        historicalData = history;
        buffer.clear();
        streamController.add(history.toList());
      } catch (e) {
        logger.e('Failed to load historical data for key $key: $e');
        if (!streamController.isClosed) streamController.addError(e);
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

  /// Stop a collection.
  void stopCollect(CollectEntry entry) {
    _subscriptions[entry]?.cancel();
    _subscriptions.remove(entry);
    _sampleTimers.remove(entry)?.cancel();
    _evaluators[entry]?.cancel();
    _evaluators.remove(entry);
  }

  void close() {
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
