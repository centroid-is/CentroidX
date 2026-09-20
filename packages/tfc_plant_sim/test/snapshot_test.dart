/// Deriving a spec from a plant's key mappings, and where it may be written.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_plant_sim/src/destination.dart';
import 'package:tfc_plant_sim/src/snapshot.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';

KeyMappingRow _row(String key, String payload) => (key: key, payload: payload);

const String _opcua = '{"opcua_node": {"namespace": 4, '
    '"identifier": "CN01.speed", "server_alias": "line1"}}';

void main() {
  group('deriving a spec', () {
    test('one server per alias, and it parses back', () {
      final yaml = specFromKeyMappings([
        _row('a', _opcua),
        _row('b', '{"opcua_node": {"namespace": 4, "identifier": '
            '"CN02.speed", "server_alias": "line2"}}'),
        _row('c', '{"opcua_node": {"namespace": 2, "identifier": '
            '"CN03.speed", "server_alias": "line1"}}'),
      ]);

      final spec = PlantSpec.parse(yaml);
      expect(spec.servers.map((s) => s.alias), ['line1', 'line2'],
          reason: 'sorted, so two exports of the same plant diff cleanly');
      expect(spec.servers.first.nodes.map((n) => n.id),
          ['CN01.speed', 'CN03.speed']);
      expect(spec.servers.first.nodes.last.namespace, 2,
          reason: 'the namespace is the mapping\'s, not a default');
    });

    test('rows with no OPC UA node are skipped and counted', () {
      final yaml = specFromKeyMappings([
        _row('a', _opcua),
        _row('b', '{"modbus_node": {"address": 40001}}'),
        _row('c', 'not json at all'),
      ]);

      expect(yaml, contains('2 row(s) skipped'));
      expect(PlantSpec.parse(yaml).servers.single.nodes, hasLength(1));
    });

    test('the file says what it is, in the file', () {
      final yaml = specFromKeyMappings([_row('a', _opcua)], note: 'line 3');
      expect(yaml, contains('CUSTOMER DATA'));
      expect(yaml, contains('does not belong in the CentroidX'));
      expect(yaml, contains('line 3'));
    });

    test('derived nodes hold still, and the file says why', () {
      final spec = PlantSpec.parse(specFromKeyMappings([_row('a', _opcua)]));
      expect(spec.servers.single.nodes.single.motion, Motion.constant,
          reason: 'a mapping says where a tag is, not what it does');
    });
  });

  group('where a derived spec may be written', () {
    late Directory repo;
    late Directory outside;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('plant-sim-repo');
      Directory('${repo.path}/.git').createSync();
      outside = Directory.systemTemp.createTempSync('plant-sim-out');
      addTearDown(() {
        repo.deleteSync(recursive: true);
        outside.deleteSync(recursive: true);
      });
    });

    test('outside the repository is allowed', () {
      final file = checkedDestination('${outside.path}/plant.yaml',
          repoRoot: repo.path);
      expect(file.path, endsWith('plant.yaml'));
    });

    test('inside the repository is refused, and says why', () {
      expect(
        () => checkedDestination('${repo.path}/packages/x/plant.yaml',
            repoRoot: repo.path),
        throwsA(isA<ForbiddenDestination>().having((e) => e.toString(),
            'message', allOf(contains('customer data'),
                contains('CENTROIDX_BENCH_SNAPSHOT')))),
      );
    });

    test(
        'a destination whose directory does not exist yet is still refused, '
        'through a symlinked repository path', () {
      // The fail-open case, pinned on every platform rather than on the one
      // whose temp directory happens to be a symlink.
      //
      // The guard resolves the repository root through symlinks. If it cannot
      // also resolve the destination — and it cannot, when the destination's
      // directory has not been created yet — then comparing the two is
      // comparing `/private/var/...` against `/var/...`, they never match, and
      // a spec derived from a customer's plant is written inside the tree.
      //
      // `<repo>/snapshots/plant.yaml` with no `snapshots/` directory is how a
      // first snapshot is taken, so this is the ordinary path and not a corner.
      final link = Directory.systemTemp.createTempSync('plant-sim-link');
      addTearDown(() => link.deleteSync(recursive: true));
      final aliased = '${link.path}/repo';
      Link(aliased).createSync(repo.path);

      expect(
        () => checkedDestination('$aliased/snapshots/plant.yaml',
            repoRoot: aliased),
        throwsA(isA<ForbiddenDestination>()),
        reason: 'a directory that does not exist yet must not be able to '
            'defeat the check that keeps plant data out of the repository',
      );
    });

    test('a path that walks back into the repository is refused', () {
      final sneaky = '${outside.path}/../${_leaf(repo.path)}/plant.yaml';
      expect(
        () => checkedDestination(sneaky, repoRoot: repo.path),
        throwsA(isA<ForbiddenDestination>()),
        reason: 'the check resolves the path; refusing only on the text of '
            'it would pass this and write the plant into the tree',
      );
    });

    test('the repository root itself is refused', () {
      expect(
        () => checkedDestination('${repo.path}/plant.yaml',
            repoRoot: repo.path),
        throwsA(isA<ForbiddenDestination>()),
      );
    });
  });
}

String _leaf(String path) => path.split(RegExp(r'[\\/]')).last;
