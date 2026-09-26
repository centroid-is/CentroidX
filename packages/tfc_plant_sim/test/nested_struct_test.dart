/// A struct inside a struct, which is what a PLC publishes.
///
/// Every shape this package served was one level deep, and the paths that
/// matter are deeper: an access template binds a DOTTED member path, the
/// wire's containment rules recurse, and the type dictionary describes members
/// of members. A fixture that could not nest meant none of those were ever
/// exercised against a real server.
@TestOn('vm')
library;

import 'dart:async';

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';

/// A drive that carries a motor that carries its own status: three levels,
/// with an enum at the bottom.
const String _spec = '''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 1: stopped, 2: auto, 3: manual, 4: clean}
  - name: MotorStatus
    kind: struct
    members:
      - {name: run_mode, type: RunMode, value: 2}
      - {name: speed_hz, type: double, value: 50}
  - name: Motor
    kind: struct
    members:
      - {name: status, type: MotorStatus}
      - {name: current_a, type: double, value: 4.5}
  - name: DriveStatus
    kind: struct
    members:
      - {name: motor, type: Motor}
      - {name: fault_code, type: int, value: 0}
servers:
  - alias: hall1
    nodes:
      - {id: CN01.drive, type: DriveStatus, motion: once}
''';

void main() {
  test('a three-level struct is served whole, with the enum at the bottom',
      () async {
    final plant = await FakePlant.start(PlantSpec.parse(_spec));
    addTearDown(plant.close);
    final hall = plant.servers['hall1']!;

    final client = Client();
    unawaited(client.keepConnected(hall.endpoint));
    await client.awaitConnect();
    addTearDown(() async => client.delete());

    final value = await client.read(hall.nodes['CN01.drive']!);

    // Level one.
    expect(value.contains('motor'), isTrue, reason: 'read back: $value');
    expect(value.contains('fault_code'), isTrue);

    // Level two: the member that is itself a struct kept its shape rather
    // than collapsing into whatever `_scalar` made of a type name it had
    // never heard of, which is what happened before nesting was served.
    final motor = value['motor'];
    expect(motor.contains('status'), isTrue, reason: 'motor: $motor');
    expect(motor['current_a'].asDouble, 4.5);

    // Level three, and the enum under it. This is the shape the whole
    // package exists for, two levels further down than it could previously
    // reach.
    final status = motor['status'];
    expect(status['speed_hz'].asDouble, 50);
    expect(status['run_mode'].asInt, 2);
    expect(status['run_mode'].enumFields?[2]?.name, 'auto',
        reason: 'the enum names must survive nesting: a client reads a state '
            'by name, and a nested member is where a type dictionary is '
            'most likely to be dropped');
  });

  test('a struct that contains itself is refused, and the message names the '
      'loop', () {
    expect(
      () => PlantSpec.parse('''
types:
  - name: Node
    kind: struct
    members:
      - {name: child, type: Node}
servers:
  - alias: hall1
    nodes:
      - {id: CN01.x, type: Node}
'''),
      throwsA(isA<PlantSpecError>().having((e) => e.toString(), 'message',
          allOf(contains('contains itself'), contains('Node -> Node')))),
      reason: 'a value of that type has no size; building one recurses until '
          'the stack goes, and a stack overflow while standing a fixture up '
          'reads as a crash in whatever was running',
    );
  });

  test('a longer cycle is refused too, naming the whole loop', () {
    expect(
      () => PlantSpec.parse('''
types:
  - name: A
    kind: struct
    members: [{name: b, type: B}]
  - name: B
    kind: struct
    members: [{name: a, type: A}]
servers:
  - alias: hall1
    nodes:
      - {id: CN01.x, type: A}
'''),
      throwsA(isA<PlantSpecError>().having((e) => e.toString(), 'message',
          contains('A -> B -> A'))),
      reason: 'naming the loop is what makes it fixable; "a cycle exists" is '
          'not',
    );
  });

  test('a member naming a type nobody declared is refused', () {
    expect(
      () => PlantSpec.parse('''
types:
  - name: Drive
    kind: struct
    members: [{name: motor, type: Moter}]
servers:
  - alias: hall1
    nodes:
      - {id: CN01.x, type: Drive}
'''),
      throwsA(isA<PlantSpecError>().having((e) => e.toString(), 'message',
          allOf(contains('Drive.motor'), contains('Moter')))),
      reason: 'a typo in a member type used to be served as a scalar of an '
          'unknown built-in rather than refused at the file',
    );
  });

  test('a member may name a type declared later in the file', () {
    // The reason the check runs after the whole table is read rather than
    // per entry. Forward references are ordinary in a hand-written spec.
    final spec = PlantSpec.parse('''
types:
  - name: Drive
    kind: struct
    members: [{name: motor, type: Motor}]
  - name: Motor
    kind: struct
    members: [{name: speed_hz, type: double, value: 1}]
servers:
  - alias: hall1
    nodes:
      - {id: CN01.x, type: Drive}
''');
    expect(spec.types.keys, containsAll(<String>['Drive', 'Motor']));
  });
}
