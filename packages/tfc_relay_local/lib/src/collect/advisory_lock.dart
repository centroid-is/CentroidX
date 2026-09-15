/// The ownership guarantee: one gateway per (database, table-prefix)
/// namespace, enforced with a Postgres session advisory lock.
///
/// ## Why a dedicated connection, outside the pool
///
/// A session advisory lock lives on its **session**. Taken on a pooled
/// connection it would be released the moment the pool recycled that
/// connection — silently, with no log line anywhere — and the guarantee
/// would evaporate while both gateways kept reporting healthy. So the lock
/// is held on one dedicated connection opened outside the pool and kept for
/// the process's life, tagged `<applicationName>:lock` — exactly the shape
/// `AppDatabase` uses for its one LISTEN/NOTIFY connection
/// (`database_drift.dart:157-169`, the `:notify` idiom), for exactly the
/// same reason.
///
/// ## Why the key is computed in Dart
///
/// `hashtext()` would tie the lock number to a Postgres version's hash
/// implementation; two gateways on different server versions could compute
/// different keys for the same namespace and both "own" it. A 64-bit FNV-1a
/// over `centroidx.collector:<database>:<tablePrefix>` is stable, spelled
/// here once, and unit-testable without a server.
///
/// ## Why `try`, never the blocking form
///
/// `pg_advisory_lock` waits. A gateway that hangs on startup waiting for a
/// lock is a gateway that is down — and the whole phase's rule is that a
/// database can cost collection and nothing else. `pg_try_advisory_lock`
/// answers immediately; a refusal is reported with the holder's
/// `application_name` (a `pg_locks` ⋈ `pg_stat_activity` join), which turns
/// "we are not collecting" into "the gateway called X is collecting into
/// this namespace" — the difference between a mystery and a fix.
///
/// ## The limit, stated because a reader will assume more
///
/// This lock cannot stop the **app's collector**: that process never takes
/// it, and 08-CONTEXT ruling 3 keeps it running unchanged until app
/// integration cuts over. The lock covers gateway-versus-gateway — the
/// bench gateway on the same plant LAN, the case `publisherId` exists for.
/// The app is covered structurally, by 8b-01's table prefix. Two
/// mechanisms, two threats, neither redundant.
library;

import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

/// 64-bit FNV-1a over the UTF-8 bytes of [input].
///
/// Wrapping arithmetic on the VM's 64-bit ints — this package is
/// server-side only, so no web caveat applies. Reference vectors (asserted
/// in the suite): `fnv1a64('')` is the offset basis `0xcbf29ce484222325`,
/// `fnv1a64('a')` is `0xaf63dc4c8601ec8c`.
int fnv1a64(String input) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash *= 0x100000001b3; // wraps, deliberately
  }
  return hash;
}

/// Another collector already owns the namespace. [holder] is the other
/// side's `pg_stat_activity.application_name` when it could be read — a
/// name this project mints itself, so reporting it discloses no host,
/// database or credential.
final class AdvisoryLockRefused implements Exception {
  const AdvisoryLockRefused(this.holder);

  final String? holder;

  @override
  String toString() => holder == null
      ? 'AdvisoryLockRefused: another collector holds this namespace'
      : 'AdvisoryLockRefused: another collector holds this namespace: '
          '$holder';
}

/// One held lock on one dedicated session.
final class AdvisoryLock {
  AdvisoryLock._(this._connection, this.key, this.applicationName);

  final pg.Connection _connection;

  /// The FNV-1a key this session holds, for diagnostics and tests.
  final int key;

  /// What this session calls itself in `pg_stat_activity` — the name the
  /// *other* gateway's refusal will report.
  final String applicationName;

  /// The lock key for a namespace. Spelled once, here.
  static int lockKeyFor(
          {required String database, required String tablePrefix}) =>
      fnv1a64('centroidx.collector:$database:$tablePrefix');

  /// Opens the dedicated session and takes the lock, or throws
  /// [AdvisoryLockRefused] naming the holder. Any other failure (server
  /// down, auth) propagates as-is — the caller's redaction handles it like
  /// every other connect error.
  static Future<AdvisoryLock> acquire({
    required pg.Endpoint endpoint,
    required pg.SslMode sslMode,
    required String applicationName,
    required String tablePrefix,
    Duration connectTimeout = const Duration(seconds: 5),
  }) async {
    final key =
        lockKeyFor(database: endpoint.database, tablePrefix: tablePrefix);
    final tag = '$applicationName:lock';
    final connection = await pg.Connection.open(
      endpoint,
      settings: pg.ConnectionSettings(
        sslMode: sslMode,
        applicationName: tag,
        connectTimeout: connectTimeout,
        // The pool's keepalive shape: this session only ever holds, so it
        // is the one a stateful firewall sees as idle — and a lock session
        // that died unnoticed is a guarantee that evaporated unnoticed.
        keepAliveInterval: const Duration(seconds: 5),
        keepAliveCount: 3,
      ),
    );
    try {
      final granted = await connection.execute(
        r'SELECT pg_try_advisory_lock($1)',
        parameters: [key],
      );
      if (granted.first.first == true) {
        return AdvisoryLock._(connection, key, tag);
      }
      final holder = await holderOf(connection, key);
      throw AdvisoryLockRefused(holder);
    } catch (_) {
      // Refused or errored either way, this session holds nothing worth a
      // server slot.
      await connection.close(force: true);
      rethrow;
    }
  }

  /// Who holds [key] right now, by `application_name` — best effort, null
  /// when the row cannot be read (the holder may have just released).
  ///
  /// `pg_try_advisory_lock(bigint)` files the key as classid = high 32
  /// bits, objid = low 32 bits, objsubid = 1; the join matches those parts
  /// rather than re-assembling them server-side, because shifting a
  /// bigint by 32 overflows for keys with the top bit set.
  static Future<String?> holderOf(pg.Connection connection, int key) async {
    try {
      final rows = await connection.execute(
        r'SELECT a.application_name '
        r'FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid '
        r"WHERE l.locktype = 'advisory' AND l.granted "
        r'AND l.classid = $1::oid AND l.objid = $2::oid AND l.objsubid = 1',
        parameters: [key >>> 32, key & 0xFFFFFFFF],
      );
      if (rows.isEmpty) return null;
      return rows.first.first as String?;
    } catch (_) {
      return null;
    }
  }

  /// Whether the session under the lock is still alive. False means the
  /// guarantee is gone and the owner must degrade and re-acquire.
  bool get isHeld => _connection.isOpen;

  /// Ends the session, which releases the lock server-side — a session
  /// advisory lock needs no explicit unlock.
  Future<void> release() async {
    try {
      await _connection.close();
    } catch (_) {
      // A session that will not close cleanly is force-closed; either way
      // the server releases the lock when the backend goes.
      await _connection.close(force: true);
    }
  }
}
