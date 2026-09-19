/// Runs a fake plant until Ctrl-C.
///
/// ```sh
/// dart run tfc_plant_sim:plant --spec fixtures/demo_plant.yaml
/// ```
///
/// It prints one line per server — `alias endpoint` — and then a JSON object
/// of the same thing, so a script can pick the endpoints up without parsing
/// prose. A backend's `stateman.json` is written from those.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:tfc_plant_sim/tfc_plant_sim.dart';

Future<int> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('spec',
        abbr: 's',
        help: 'The plant spec to run. A spec taken from a real plant lives '
            'outside this repository.')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    return 64;
  }
  if (parsed['help'] as bool || parsed['spec'] == null) {
    stdout.writeln('Runs a fake plant from a spec.\n');
    stdout.writeln(parser.usage);
    return parsed['spec'] == null ? 64 : 0;
  }

  final file = File(parsed['spec'] as String);
  if (!file.existsSync()) {
    stderr.writeln('no spec at ${file.path}');
    return 66;
  }

  final PlantSpec spec;
  try {
    spec = PlantSpec.parse(file.readAsStringSync(), origin: file.path);
  } on PlantSpecError catch (e) {
    stderr.writeln(e);
    return 65;
  }

  final plant = await FakePlant.start(spec);
  for (final entry in plant.endpoints.entries) {
    stdout.writeln('${entry.key}\t${entry.value}');
  }
  stdout.writeln(jsonEncode(plant.endpoints));
  stdout.writeln('running; Ctrl-C to stop');

  // Stopped through the same path as a clean exit: the teardown order in
  // `FakePlant.close` is what keeps a shutdown from SEGVing the VM, and a
  // signal handler that skipped it would leave that landmine armed on every
  // interactive run.
  final done = ProcessSignal.sigint.watch().first;
  await done;
  await plant.close();
  stdout.writeln('stopped');
  return 0;
}
