/// Turns an export of a plant's key mappings into a plant spec.
///
/// ```sh
/// # on the station, or through its database:
/// psql -U centroid -d hmi -At -F$'\t' \
///   -c "select id, payload from config_item where kind = 'key_mapping'" \
///   > rows.tsv
///
/// dart run tfc_plant_sim:snapshot --rows rows.tsv \
///   --out "$CENTROIDX_BENCH_SNAPSHOT/plant.yaml"
/// ```
///
/// The output is customer data and the tool refuses to write it inside this
/// repository. See `lib/src/destination.dart`.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:tfc_plant_sim/src/destination.dart';
import 'package:tfc_plant_sim/src/snapshot.dart';

Future<int> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('rows',
        help: 'A tab-separated export of key_mapping rows: id<TAB>payload.')
    ..addOption('out',
        help: 'Where to write the spec. Must be outside this repository.')
    ..addOption('note', help: 'A line for the file\'s header.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    return 64;
  }
  if (parsed['help'] as bool || parsed['rows'] == null || parsed['out'] == null) {
    stdout.writeln('Derives a plant spec from exported key mappings.\n');
    stdout.writeln(parser.usage);
    return parsed['rows'] == null || parsed['out'] == null ? 64 : 0;
  }

  final rowsFile = File(parsed['rows'] as String);
  if (!rowsFile.existsSync()) {
    stderr.writeln('no export at ${rowsFile.path}');
    return 66;
  }

  final File out;
  try {
    out = checkedDestination(parsed['out'] as String);
  } on ForbiddenDestination catch (e) {
    stderr.writeln(e);
    return 73;
  }

  final rows = <KeyMappingRow>[];
  var malformed = 0;
  for (final line in rowsFile.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final tab = line.indexOf('\t');
    if (tab < 0) {
      malformed++;
      continue;
    }
    rows.add((key: line.substring(0, tab), payload: line.substring(tab + 1)));
  }
  if (rows.isEmpty) {
    stderr.writeln('${rowsFile.path} has no rows this tool can read: expected '
        'lines of "id<TAB>payload"$malformed');
    return 65;
  }

  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
      specFromKeyMappings(rows, note: parsed['note'] as String?));
  stdout.writeln('wrote ${out.path} from ${rows.length} row(s)'
      '${malformed == 0 ? '' : ', $malformed unreadable line(s) skipped'}');
  return 0;
}
