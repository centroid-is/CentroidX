/// The spec reader, and what it refuses.
///
/// A spec is written by hand by somebody debugging something else, so every
/// refusal has to name where it went wrong. These cases are as much about the
/// message as about the throw.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';

const String _minimal = '''
servers:
  - alias: hall1
    nodes:
      - id: CN01.speed
        type: double
''';

void main() {
  test('reads servers, nodes and their defaults', () {
    final spec = PlantSpec.parse(_minimal);
    expect(spec.servers, hasLength(1));
    final server = spec.servers.single;
    expect(server.alias, 'hall1');
    expect(server.port, 0,
        reason: 'no port asks the kernel for one, so two benches on one box '
            'do not fight');
    final node = server.nodes.single;
    expect(node.namespace, 4,
        reason: 'the namespace a PLC publishes its own tags in');
    expect(node.motion, Motion.constant);
    expect(node.period, const Duration(seconds: 1));
  });

  test('reads an enum and a struct that names it', () {
    final spec = PlantSpec.parse('''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 2: auto}
  - name: DriveStatus
    kind: struct
    members:
      - {name: run_mode, type: RunMode, value: 2}
      - {name: speed_hz, type: double}
servers:
  - alias: hall1
    nodes:
      - {id: CN01.drive, type: DriveStatus, motion: cycle, period: 500ms}
''');
    expect(spec.types['RunMode']!.isEnum, isTrue);
    expect(spec.types['RunMode']!.values[2], 'auto');
    final drive = spec.types['DriveStatus']!;
    expect(drive.isEnum, isFalse);
    expect(drive.members.map((m) => m.name), ['run_mode', 'speed_hz']);
    expect(spec.servers.single.nodes.single.period,
        const Duration(milliseconds: 500));
  });

  group('refusals name the path', () {
    void refuses(String source, String path, Matcher message) {
      expect(
        () => PlantSpec.parse(source),
        throwsA(isA<PlantSpecError>()
            .having((e) => e.path, 'path', path)
            .having((e) => e.message, 'message', message)),
      );
    }

    test('a plant with no servers', () {
      refuses('servers: []', 'spec.servers', contains('serves nothing'));
    });

    test('a node typed as something undeclared', () {
      refuses('''
servers:
  - alias: hall1
    nodes:
      - {id: CN01.drive, type: DriveStatus}
''', 'spec.servers[0].nodes[0].type', contains('neither a built-in'));
    });

    test('two servers sharing an alias', () {
      refuses('''
servers:
  - {alias: hall1, nodes: []}
  - {alias: hall1, nodes: []}
''', 'spec.servers[1].alias', contains('one server per alias'));
    });

    test('cycling a type that has no enum in it', () {
      refuses('''
servers:
  - alias: hall1
    nodes:
      - {id: CN01.speed, type: double, motion: cycle}
''', 'spec.servers[0].nodes[0].motion', contains('has none'));
    });

    test('an enum with no values', () {
      refuses('''
types:
  - {name: RunMode, kind: enum, values: {}}
servers:
  - {alias: hall1, nodes: []}
''', 'spec.types[0].values', contains('names no state'));
    });

    test('a duration nobody can read', () {
      refuses('''
servers:
  - alias: hall1
    nodes:
      - {id: CN01.speed, type: double, period: "every 5 seconds"}
''', 'spec.servers[0].nodes[0].period', contains('not a duration'));
    });
  });
}
