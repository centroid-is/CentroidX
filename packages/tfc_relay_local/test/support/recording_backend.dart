/// A drift backend that writes down every statement, and the prefixing
/// resolver the reader cases hand it.
///
/// Lifted out of `timescale_reader_test.dart` when a second file needed the
/// same two levers: `composed_seam_test.dart` composes the *policy decorator*
/// in front of a real [TimescaleReader] over this backend, which is the one
/// composition nothing in the suite had ever assembled (10-REVIEW CR-01). A
/// second copy would have let the reader-only cases and the composed cases
/// drift into judging different fixtures, which is the whole failure the
/// review named.
///
/// It stays in `test/support/` and never in a `lib/`: [OneSeries] is a
/// [SeriesResolver], and `series_address.dart:150-158` plus
/// `handler_table_test.dart`'s sweep forbid shipping one.
library;

import 'package:drift/drift.dart'
    show QueryRow, ResultSetImplementation, Selectable, Variable;
import 'package:drift/native.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ResolvedSeries, SeriesAddress, SeriesResolver;

/// Every statement this backend was asked to run, and canned answers for the
/// two paths a reader takes.
///
/// `tableQuery` and `customSelect` are the only two doors to SQL that
/// `Database`'s read methods use, so recording both is what makes "the query
/// never ran" a measurement rather than a hope.
class RecordingBackend extends AppDatabase {
  RecordingBackend()
      : super.forTest(
            DatabaseConfig(), NativeDatabase.memory(logStatements: false));

  /// `(sql, columns)` for every `tableQuery`, in call order.
  final List<({String table, List<String>? columns, String? orderBy})>
      tableQueries = [];

  /// Raw SQL for every `customSelect`.
  final List<String> statements = [];

  /// What `information_schema.columns` should answer: column name → data type.
  Map<String, String> columns = <String, String>{'value': 'double precision'};

  /// Rows `tableQuery` answers with.
  List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];

  bool get touchedSql => tableQueries.isNotEmpty || statements.isNotEmpty;

  /// Just the reader's bounded window queries, in call order.
  ///
  /// `statements` also carries the `information_schema` probe that runs before
  /// every read, and a case asserting "the query that was built" means the one
  /// that touches the series' own table.
  List<String> get windowQueries =>
      statements.where((s) => s.contains('::timestamptz')).toList();

  @override
  Future<List<QueryRow>> tableQuery(
    String tableName, {
    List<String>? columns,
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
  }) async {
    tableQueries
        .add((table: tableName, columns: columns, orderBy: orderBy));
    return [for (final row in rows) QueryRow(row, this)];
  }

  @override
  Selectable<QueryRow> customSelect(String query,
      {List<Variable> variables = const [],
      Set<ResultSetImplementation<dynamic, dynamic>> readsFrom = const {}}) {
    statements.add(query);
    if (query.contains('::timestamptz')) {
      // The reader's own bounded window query (10-10). Answered from [rows]
      // rather than executed: the backend underneath is SQLite and knows
      // nothing of `timestamptz`, and what these cases measure is the SQL that
      // was built rather than what Postgres would do with it. The db lane in
      // `read_limits_test.dart` is where a real server answers it.
      return _CannedRows([for (final row in rows) QueryRow(row, this)]);
    }
    if (query.contains('information_schema.columns')) {
      // The shape `TimescaleReader._columnsOf` reads.
      return super.customSelect(
        columns.entries
            .map((e) =>
                "SELECT '${e.key}' AS column_name, '${e.value}' AS data_type")
            .join(' UNION ALL '),
      );
    }
    return super.customSelect(query, variables: variables, readsFrom: readsFrom);
  }
}

/// Rows handed straight back, for a statement the SQLite underneath cannot run.
///
/// Only `get()` is answered. Everything else throws by name rather than
/// returning an empty stream, because a `watch()` that silently produced
/// nothing would make a case pass by measuring the absence of its own subject.
final class _CannedRows implements Selectable<QueryRow> {
  _CannedRows(this._rows);

  final List<QueryRow> _rows;

  @override
  Future<List<QueryRow>> get() async => _rows;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'the recording backend answers only get(); '
      '${invocation.memberName} was called and would have been silently '
      'empty');
}

/// Maps exactly what the cases need and refuses everything else, so a hostile
/// name has nothing to ride in on.
///
/// **The table is not the series**, and that is the point of this fixture
/// rather than an incidental detail: `gw_` is the prefix every ordinary
/// deployment carries (`collection_config.dart:148`), and a resolver answering
/// `table == series` makes a double resolution idempotent and therefore
/// invisible. Every other resolver in the suite is an identity one; this is
/// the one that can see CR-01.
final class OneSeries implements SeriesResolver {
  const OneSeries({this.table = 'gw_Line1.Motor1'});

  final String table;

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    if (address.series != 'Line1.Motor1') return null;
    return ResolvedSeries(
        table: table, member: address.member, plantKey: address.series);
  }

  @override
  String? keyForTable(String t) => t == table ? 'Line1.Motor1' : null;

  @override
  String? keyForNode(String nodeId) => null;
}
