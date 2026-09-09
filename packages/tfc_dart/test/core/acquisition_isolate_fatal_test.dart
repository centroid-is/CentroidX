/// `bin/data_acquisition_isolate.dart` spawns with `Isolate.spawn(...)` and
/// does NOT pass `errorsAreFatal: false` — and true is the default. So ANY
/// uncaught async error anywhere in that isolate kills all acquisition for
/// that server, and the supervisor respawns it. A throw that is deterministic
/// and periodic therefore produces a permanent crashloop, not a recovery.
///
/// These tests hunt for unguarded throws reachable in that isolate, and
/// establish the premise itself with a real spawned isolate.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/state_man.dart';

class NoopDatabase implements Database {
  final List<dynamic> rows = [];

  @override
  Future<void> registerRetentionPolicy(String t, RetentionPolicy r) async {}

  @override
  Future<void> insertTimeseriesData(String t, DateTime time, dynamic v) async {
    rows.add(v);
  }

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Entry point for the premise test: one unguarded throw from a periodic
/// timer, exactly the shape of the collector's sample timer.
void _throwFromTimerEntry(SendPort ready) {
  ready.send('alive');
  Object? nothing;
  Timer.periodic(const Duration(milliseconds: 20), (_) async {
    // Uncaught async error out of a Timer callback, exactly the shape of the
    // collector's sample timer before the guard went back in.
    ready.send('len=${nothing!.toString().length}');
  });
  Timer.periodic(const Duration(milliseconds: 50), (_) => ready.send('tick'));
}

void main() {
  test(
      'PREMISE: one unguarded throw from a timer kills the acquisition '
      'isolate', () async {
    // Spawned exactly as bin/data_acquisition_isolate.dart:193 does — no
    // errorsAreFatal argument, so it defaults to true.
    final rx = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final events = <String>[];
    rx.listen((m) => events.add(m as String));
    var died = false;
    exits.listen((_) => died = true);
    var errored = false;
    errors.listen((_) => errored = true);

    await Isolate.spawn(_throwFromTimerEntry, rx.sendPort,
        onError: errors.sendPort, onExit: exits.sendPort);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    rx.close();
    errors.close();
    exits.close();

    expect(events, contains('alive'), reason: 'sanity: the isolate started');
    // This is the mechanism, not a defect — it documents why every finding
    // below is fatal rather than merely noisy.
    expect(errored && died, isTrue,
        reason: 'A single unguarded async throw terminated the isolate. '
            'Everything it was running — every subscription, every poll '
            'loop, every buffered write not yet flushed — went with it.');
    expect(events.where((e) => e == 'tick').length, lessThan(5),
        reason: 'The isolate stopped doing its work almost immediately.');
  });

  test(
      'a templated collected key must not kill the isolate at Collector '
      'construction', () async {
    // A collected key that names a substitution variable. In the UI these
    // resolve once the OptionVariable asset that owns them publishes — but
    // the acquisition isolate has no assets and no UI, so NOTHING ever
    // publishes a substitution there and the key stays templated forever.
    final stateMan = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {
        r'Line1.$period.throughput': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'Throughput'),
          collect: CollectEntry(
              key: r'Line1.$period.throughput', name: 'throughput'),
        ),
      }),
    );
    addTearDown(
        () => stateMan.close().timeout(const Duration(seconds: 5), onTimeout: () {}));

    final errors = <Object>[];
    await runZonedGuarded(() async {
      Collector(
        config: CollectorConfig(collect: true),
        stateMan: stateMan,
        database: NoopDatabase(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }, (e, _) => errors.add(e));

    expect(errors, isEmpty,
        reason: 'The Collector constructor calls `collectEntry(...)` and '
            'DISCARDS the returned Future (collector.dart:158) — not even '
            'unawaited(). collectEntry awaits stateMan.subscribe(), which '
            'throws StateManException from _throwIfUnresolved for a key that '
            'still names a variable. That is an uncaught async error during '
            'construction, so with errorsAreFatal the isolate dies before it '
            'ever collects anything, respawns, and dies again: a permanent '
            'crashloop that takes down EVERY key on that server, not just '
            'the templated one. Errors: $errors');
  });
}
