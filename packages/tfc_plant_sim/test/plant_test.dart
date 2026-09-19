/// The plant, seen the way a panel sees it: over a socket, with a real
/// client.
///
/// Every case here is a shape that broke something in production, and the
/// assertion is what the panel needed and did not get. A simulator that
/// served plausible numbers but not these shapes would have reproduced none
/// of those defects, which is the whole reason this file leads with them.
@TestOn('vm')
library;

import 'dart:async';

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';

/// Two servers, and between them each shape the README's table names.
const String _spec = '''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 1: stopped, 2: auto, 3: manual, 4: clean}
  - name: DriveStatus
    kind: struct
    members:
      - {name: run_mode, type: RunMode, value: 2}
      - {name: speed_hz, type: double, value: 50}
servers:
  - alias: hall1
    nodes:
      - {id: CN01.drive, type: DriveStatus, motion: cycle, period: 300ms}
      - {id: CN01.setpoint_kg, type: double, value: 12.5, motion: once}
      - {id: CN01.rate, type: double, value: 0, motion: constant, period: 100ms}
  - alias: hall2
    nodes:
      - {id: CN02.state, type: RunMode, value: 1, motion: once}
''';

void main() {
  late FakePlant plant;

  setUp(() async {
    plant = await FakePlant.start(PlantSpec.parse(_spec));
  });

  tearDown(() async => plant.close());

  /// A connected client against [alias], driven and closed with the test.
  ///
  /// `keepConnected` rather than `connect` + a hand-rolled iterate loop: it
  /// owns the pump, and the library's own doc says not to run both.
  Future<Client> connect(String alias) async {
    final client = Client();
    unawaited(client.keepConnected(plant.servers[alias]!.endpoint));
    await client.awaitConnect();
    addTearDown(() async => client.delete());
    return client;
  }

  /// One subscription on [client], for the monitored items a case opens.
  Future<int> subscribe(Client client) => client.subscriptionCreate();

  test('one server per alias, each on its own port', () {
    expect(plant.endpoints.keys, ['hall1', 'hall2']);
    final ports = plant.servers.values.map((s) => s.port).toSet();
    expect(ports, hasLength(2),
        reason: 'two servers sharing a port is one server');
    expect(plant.endpoints['hall1'], startsWith('opc.tcp://127.0.0.1:'));
  });

  test('a struct arrives with its members', () async {
    final client = await connect('hall1');
    final drive =
        await client.read(plant.servers['hall1']!.nodes['CN01.drive']!);

    expect(drive['speed_hz'].asDouble, 50);
    expect(drive['run_mode'].asInt, anyOf(0, 1, 2, 3, 4));
  });

  // The purple-conveyor shape. A panel colours equipment from the enum's
  // NAMES; when the dictionary does not cross, every state reads "unknown"
  // and the drawing goes violet. What the client has to be able to learn is
  // exactly this: value 2 is called "auto".
  test('an enum node carries its field names, not just an integer', () async {
    final client = await connect('hall2');
    final node = plant.servers['hall2']!.nodes['CN02.state']!;

    final schema = await client.buildSchema(await client.readDataTypeAttribute(node));
    final named = schema.values
        .where((v) => v.enumFields != null && v.enumFields!.isNotEmpty);
    expect(named, isNotEmpty,
        reason: 'without enum fields on the wire a panel has an integer and '
            'no name for it, which is what draws "unknown"');
    expect(named.first.enumFields![2]!.name, 'auto');
    expect(named.first.enumFields![0]!.name, 'fault');
  });

  // The stale-setpoint shape. A configured setpoint notifies at establishment
  // and never again, and a freshness sweep with no keep-alive badges it stale
  // while the value on it is correct.
  test('a "once" node reports at establishment and then goes quiet', () async {
    final client = await connect('hall1');
    final node = plant.servers['hall1']!.nodes['CN01.setpoint_kg']!;

    final seen = <DynamicValue>[];
    final sub = client.monitor(node, await subscribe(client)).listen(seen.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(seconds: 2));

    expect(seen, isNotEmpty, reason: 'the first report is the value it holds');
    expect(seen.first.asDouble, 12.5);
    expect(seen, hasLength(1),
        reason: 'a setpoint is a constant: it must NOT keep notifying, or the '
            'staleness this shape exists to reproduce never happens');
  });

  test('a node that moves keeps notifying', () async {
    final client = await connect('hall1');
    final node = plant.servers['hall1']!.nodes['CN01.drive']!;

    final seen = <int>[];
    final sub = client
        .monitor(node, await subscribe(client))
        .listen((value) => seen.add(value['run_mode'].asInt));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(seconds: 2));

    expect(seen.length, greaterThan(2),
        reason: 'a cycling drive reports every period');
    expect(seen.toSet().length, greaterThan(1),
        reason: 'and it actually changes state, or nothing downstream is '
            'exercised');
  });

  // "No data" and "zero" look identical on a chart, and only one of them is a
  // fault. The plant has to be able to serve an honest zero.
  test('a rate at zero is a value, not an absence', () async {
    final client = await connect('hall1');
    final node = plant.servers['hall1']!.nodes['CN01.rate']!;

    final value = await client.read(node);
    expect(value.asDouble, 0);
    expect(value.value, isNotNull,
        reason: 'zero with a value is a reading; null is a gap, and a panel '
            'must be able to tell them apart');
  });

  // A key mapping pointing at a node the PLC does not have. The operator sees
  // an empty page; the client must see a named, permanent refusal.
  test('a node taken out of the address space answers BadNodeIdUnknown',
      () async {
    final client = await connect('hall1');
    final node = plant.servers['hall1']!.nodes['CN01.rate']!;
    plant.servers['hall1']!.remove('CN01.rate');

    // The status by name, whatever the binding wraps it in: what matters to
    // a panel is that the refusal is permanent and says which node, not that
    // the read came back empty.
    await expectLater(
      client.read(node),
      throwsA(predicate<Object>(
          (e) => e.toString().contains('BadNodeIdUnknown') &&
              e.toString().contains('CN01.rate'),
          'a refusal naming BadNodeIdUnknown and the node')),
    );
  });

  test('a scenario can move a value, and a watcher sees it', () async {
    final client = await connect('hall1');
    final node = plant.servers['hall1']!.nodes['CN01.setpoint_kg']!;

    final seen = <double>[];
    final sub = client
        .monitor(node, await subscribe(client))
        .listen((v) => seen.add(v.asDouble));
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    plant.servers['hall1']!.set('CN01.setpoint_kg', 18.0);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(seen.last, 18.0,
        reason: 'the lever a scenario drives: the plant changed, and the '
            'panel was told');
  });
}
