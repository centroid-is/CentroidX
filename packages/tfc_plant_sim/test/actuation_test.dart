/// What the plant records about having been moved.
///
/// The instrument the relay's write-safety claims are measured with, tested
/// here before anything relies on it. A counter that silently miscounts would
/// make every downstream assertion about "a write is never retried" a
/// statement about the counter.
@TestOn('vm')
library;

import 'dart:async';

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';

/// One ordinary node and one that records, so a case can show the difference.
const String _spec = '''
servers:
  - alias: hall1
    nodes:
      - {id: CN01.setpoint_kg, type: double, value: 12.5, motion: once, records: true}
      - {id: CN01.rate, type: double, value: 0, motion: constant, period: 100ms}
''';

void main() {
  late FakePlant plant;
  late RunningServer hall;

  setUp(() async {
    plant = await FakePlant.start(PlantSpec.parse(_spec));
    hall = plant.servers['hall1']!;
  });

  tearDown(() async => plant.close());

  Future<Client> connect() async {
    final client = Client();
    unawaited(client.keepConnected(hall.endpoint));
    await client.awaitConnect();
    addTearDown(() async => client.delete());
    return client;
  }

  /// Writes [v] to [node] with the type the node already carries.
  ///
  /// A bare Dart number has no deducible OPC UA type (`Unable to deduce type
  /// double for 18.0`), so the value has to be handed the one the node is
  /// already serving — which is what a real client does after browsing, and
  /// what `RunningServer.set` does from its seeds.
  Future<void> writeDouble(Client client, NodeId node, double v) async {
    final current = await client.read(node);
    await client.write(node, DynamicValue(value: v, typeId: current.typeId));
  }

  /// Waits for [predicate], polling, because a write crosses a socket and a
  /// callback before it reaches the log.
  Future<void> until(bool Function() predicate, String what) async {
    final deadline = Stopwatch()..start();
    while (!predicate()) {
      if (deadline.elapsed > const Duration(seconds: 10)) {
        fail('timed out waiting for $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a recording node serves its value like any other', () async {
    final client = await connect();
    final read = await client.read(hall.nodes['CN01.setpoint_kg']!);
    expect(read.asDouble, 12.5,
        reason: 'a data source is still a node a client can read');
  });

  test('a client write is recorded, with the value that arrived', () async {
    final client = await connect();
    await writeDouble(client, hall.nodes['CN01.setpoint_kg']!, 18.0);

    await until(() => hall.actuationCount('CN01.setpoint_kg') == 1,
        'the write to reach the node');
    final actuation = hall.actuationsOf('CN01.setpoint_kg').single;
    expect(actuation.value.asDouble, 18.0);
    expect(actuation.node, 'CN01.setpoint_kg');
  });

  test('two writes of the SAME value are two actuations', () async {
    final client = await connect();
    final node = hall.nodes['CN01.setpoint_kg']!;

    await writeDouble(client, node, 18.0);
    await until(() => hall.actuationCount('CN01.setpoint_kg') == 1,
        'the first write');
    await writeDouble(client, node, 18.0);
    await until(() => hall.actuationCount('CN01.setpoint_kg') == 2,
        'the second write');

    // The property the whole instrument exists for. A read-back cannot tell
    // these apart — the node holds 18.0 either way — so a duplicated command
    // is invisible to every check that asks the plant what its value is. It is
    // visible only to a plant that counted.
    expect(hall.actuationCount('CN01.setpoint_kg'), 2,
        reason: 'a second command to a machine is a second movement of that '
            'machine, whether or not it changed the number');
    final read = await client.read(node);
    expect(read.asDouble, 18.0,
        reason: 'and the read-back is identical, which is the point');
  });

  test('the plant moving itself is not an actuation', () async {
    await connect();
    hall.set('CN01.setpoint_kg', 21.0);
    // Long enough that a write routed through the server would have landed.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(hall.actuations, isEmpty,
        reason: 'the log means "a client did this"; a scenario raising a '
            'level is the plant, not a command');
    final client = await connect();
    final read = await client.read(hall.nodes['CN01.setpoint_kg']!);
    expect(read.asDouble, 21.0,
        reason: 'and the lever still moved the value it was pulled on');
  });

  test('an ordinary node records nothing', () async {
    final client = await connect();
    await writeDouble(client, hall.nodes['CN01.rate']!, 7.0);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(hall.actuationsOf('CN01.rate'), isEmpty,
        reason: 'recording is opt-in: it changes a node from a stored '
            'variable into a data source, which is a different sampling '
            'shape and not what most of the fixtures want');
  });

  test('a recording node is monitorable, and reports what was written',
      () async {
    final client = await connect();
    final node = hall.nodes['CN01.setpoint_kg']!;
    final seen = <double>[];
    final sub = client
        .monitor(node, await client.subscriptionCreate())
        .listen((v) => seen.add(v.asDouble));
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    await writeDouble(client, node, 33.0);
    await until(() => seen.isNotEmpty && seen.last == 33.0,
        'the sampled value to reach the subscriber');

    expect(seen.last, 33.0,
        reason: 'a data source is sampled rather than pushed, so this is the '
            'arm that proves the sampling actually runs');
  });

  test('clearing the log leaves the node where it is', () async {
    final client = await connect();
    final node = hall.nodes['CN01.setpoint_kg']!;
    await writeDouble(client, node, 18.0);
    await until(() => hall.actuationCount('CN01.setpoint_kg') == 1, 'a write');

    hall.clearActuations();
    expect(hall.actuations, isEmpty);
    final read = await client.read(node);
    expect(read.asDouble, 18.0,
        reason: 'forgetting what was counted is not undoing it');
  });
}
