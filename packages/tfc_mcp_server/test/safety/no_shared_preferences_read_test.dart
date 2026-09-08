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
/// The one surviving mention is the drift table *declaration* in
/// `server_database.dart`, which describes a table the plant still carries as
/// rollback insurance. It is a schema, not a read; it goes when the table
/// does, with the cutover drop.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.path.contains('tfc_mcp_server')
      ? Directory.current.path
      : '${Directory.current.path}/packages/tfc_mcp_server';

  /// Every hand-written Dart file the binary can reach.
  ///
  /// Generated drift output is excluded: it mirrors the schema declaration
  /// and would report the table whatever the production code does.
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

  test('nothing outside the schema declaration selects from it', () {
    final offenders = <String>[];

    for (final file in productionSources()) {
      final isSchemaDeclaration =
          file.path.endsWith('database/server_database.dart');
      if (isSchemaDeclaration) continue;

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

  test('the surviving mention is a table declaration, not a query', () {
    // Stated positively so the exclusion above cannot quietly grow to cover
    // a real read that somebody adds to the same file.
    final source =
        File('$packageRoot/lib/src/database/server_database.dart')
            .readAsStringSync();

    expect(source, contains('class ServerFlutterPreferences extends Table'));
    expect(source, isNot(contains('select(')),
        reason: 'the schema file describes tables; it does not read them');
  });
}
