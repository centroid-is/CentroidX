/// The binary has no way to read the shared `flutter_preferences` table.
///
/// This is the other half of the fail-open fix, and the half that cannot be
/// written as a behaviour test in this lane. The first live path was a
/// standalone launch against a *migrated* plant: `migrateMcpConfigToDeviceLocal`
/// deletes `mcp.config` and every legacy `mcp_tools_*_enabled` key from the
/// shared store, so both of the binary's old selects missed and
/// `fromLegacyMap({})` returned all nine groups enabled. Reproducing that
/// needs a Postgres server, which this suite does not have.
///
/// So the claim is made structurally instead, and it is a stronger one than
/// the behaviour test would have been: there is no such read to reach. What
/// the shared table contains, and whether the migration has emptied it, can
/// no longer change what this server exposes — because nothing on the path
/// from `main` to a registered tool group looks at it.
///
/// The table class went with the read. `tfc_dart` keeps its declaration on
/// purpose -- a plant carries the table until somebody runs the drop tool, and
/// a build whose schema does not know the table can neither open that database
/// nor drop it -- but this package has neither need: it drops nothing and
/// reads nothing. So there is no mention left here at all, and a schema this
/// package does not need is a schema that invites the read back.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.path.contains('tfc_mcp_server')
      ? Directory.current.path
      : '${Directory.current.path}/packages/tfc_mcp_server';

  /// Every hand-written Dart file the binary can reach.
  ///
  /// Generated drift output is excluded on principle rather than necessity:
  /// it mirrors whatever the schema declares, so it reports the declaration
  /// rather than a decision.
  List<File> productionSources() {
    return [
      File('$packageRoot/bin/tfc_mcp_server.dart'),
      ...Directory('$packageRoot/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('.g.dart')),
    ];
  }

  test('the entrypoint does not mention the shared preferences table at all',
      () {
    final source = File('$packageRoot/bin/tfc_mcp_server.dart')
        .readAsStringSync();

    expect(source, isNot(contains('serverFlutterPreferences')),
        reason: 'the toggle source is the spawner, not a table');
    expect(source, isNot(contains('flutter_preferences')));
    expect(source, isNot(contains('fromLegacyMap')),
        reason: 'the legacy-key fallback is what defaulted nine groups to '
            'enabled when the migration had emptied the store');
  });

  test('no production file names it, with nothing excluded', () {
    final offenders = <String>[];

    for (final file in productionSources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('serverFlutterPreferences') ||
            lines[i].contains('ServerFlutterPreferences')) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'a read here decides capability from a table the migration '
            'empties and the cutover drops:\n${offenders.join('\n')}');
  });

  test('the schema no longer declares the table either', () {
    // The exclusion this test used to carry is gone with the declaration, and
    // that is the point: while `server_database.dart` was skipped, a real read
    // added to that one file would have gone unseen. Now nothing is skipped.
    final source =
        File('$packageRoot/lib/src/database/server_database.dart')
            .readAsStringSync();

    expect(source, isNot(contains('class ServerFlutterPreferences')));
    expect(source, isNot(contains("tableName => 'flutter_preferences'")));
  });

  test('tests that want the retired table build it themselves', () {
    // Not a leftover: `config_service_test.dart` seeds the blob to prove the
    // readers ignore it, and that claim only means something against a
    // database where the table really exists. The DDL helper is how a test
    // gets one now, which is also how a plant has one.
    final helper =
        File('$packageRoot/test/helpers/config_rows.dart').readAsStringSync();

    expect(helper, contains('CREATE TABLE IF NOT EXISTS flutter_preferences'));
  });
}
