/// Adapts SQL written with `?` placeholders to PostgreSQL's `$N` style.
///
/// Drift's `customSelect`/`customStatement` pass SQL through to the backend
/// verbatim, so queries shared between the SQLite test harness and the
/// production Postgres connection need this translation. Same contract as
/// the MCP server's `adaptSql`; duplicated here because tfc_dart is the
/// upstream package.
String adaptSqlPlaceholders(String sql, {required bool isPostgres}) {
  if (!isPostgres) return sql;
  var n = 0;
  return sql.replaceAllMapped('?', (_) {
    n++;
    return '\$$n';
  });
}

/// Quotes an identifier (table or column name) for interpolation into SQL.
/// Collected-table names contain dots, so they must always be quoted.
String quoteIdentifier(String name) => '"${name.replaceAll('"', '""')}"';
