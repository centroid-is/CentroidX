/// The wrap, offline: every case here runs with **no database anywhere** —
/// the backend is `FakeWriteBackend` over in-memory sqlite, or a factory that
/// refuses, or a loopback port nothing listens on. That is the point of
/// wrapping `Database` behind a constructor-injected factory: the write
/// path's whole outage repertoire is drivable from a unit test.
///
/// What is asserted, in the plan's words:
///
///  * disabled means **no `Database` object at all**, proven by a factory
///    invocation counter rather than a nullable field;
///  * `start()` never waits for Postgres, `insert` never throws, and a down
///    database costs collection and nothing else;
///  * connection errors keep rows (queued), content rejections lose them
///    (dropped, counted) — `Database`'s own distinction, surfaced not
///    re-decided;
///  * `lastError` is redacted: no endpoint host, no database name, no
///    username, ever (`PIPE.collect.last_error` is a key any panel reads);
///  * `close()` flushes and leaves no timer pending;
///  * `ensureTable` is idempotent.
@TestOn('vm')
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_relay_local/src/collect/advisory_lock.dart';
import 'package:tfc_relay_local/src/collect/timescale_sink.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart'
    show CollectionConfig, CollectionEndpoint;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import '../support/fake_write_backend.dart';
import '../support/free_port.dart';

/// Polls [condition] until it holds or [budget] runs out, then fails naming
/// [what]. The sink's numbers move on an event loop the test does not drive,
/// so every count is read inside a window, never as an instant.
Future<void> eventually(
  bool Function() condition,
  String what, {
  Duration budget = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(budget);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('$what did not become true within ${budget.inMilliseconds} ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A between-attempt sleep short enough that a test never waits on the
/// production backoff ladder.
Future<void> shortSleep(Duration _) =>
    Future<void>.delayed(const Duration(milliseconds: 5));

/// An enabled config whose endpoint is never successfully dialled. The names
/// are chosen to be greppable in `lastError`: if any of them shows up there,
/// the redaction is not redacting.
CollectionConfig enabledConfig({int? port}) => CollectionConfig(
      enabled: true,
      endpoint: CollectionEndpoint(
        host: port == null ? 'redact-me-host.invalid' : '127.0.0.1',
        // 1 when injected factories make the endpoint unreachable-by-design;
        // a drawn free port when the production dial path is the subject.
        port: port ?? 1,
        database: 'redact_me_db',
        username: 'redact_me_user',
        password: 'redact_me_password',
      ),
      connectTimeout: const Duration(seconds: 2),
      queryTimeout: const Duration(seconds: 2),
    );

void main() {
  // A simulated outage produces one warning per flush; the assertions here
  // are on the counters, the same choice tfc_dart's write-queue tests make.
  final realLevel = Logger.level;
  setUpAll(() => Logger.level = Level.off);
  tearDownAll(() => Logger.level = realLevel);

  group('the wrap constructs nothing it was not asked for', () {
    test('a disabled sink never invokes the backend factory', () async {
      var built = 0;
      final sink = TimescaleSink(
        CollectionConfig(), // enabled defaults to false
        backendFactory: (_) async {
          built++;
          return Database(FakeWriteBackend());
        },
        sleep: shortSleep,
      );
      await sink.start();
      await sink.insert('gw_t', DateTime.utc(2026), 1.0);
      await sink.flush();
      await sink.close();
      expect(built, 0,
          reason: 'enabled: false must mean no Database object at all — '
              'Database starts a flush timer in its constructor, so an '
              'object built and thrown away is already a leak. The counter '
              'is the assertion precisely so a "construct then discard" '
              'implementation cannot pass it');
    });
  });

  group('a down database costs collection and nothing else', () {
    test(
        'start() returns with no server reachable; rows queue; connected '
        'stays false', () async {
      final port = await freePort(); // nothing listens here
      final sink = TimescaleSink(
        enabledConfig(port: port),
        useIsolate: false,
        sleep: shortSleep,
      );
      addTearDown(sink.close);
      final seen = <bool>[];
      final sub = sink.connected.listen(seen.add);
      addTearDown(sub.cancel);

      await within(sink.start(), 'start() returning with no server reachable',
          budget: const Duration(milliseconds: 500));

      for (var i = 1; i <= 3; i++) {
        await within(sink.insert('gw_t', DateTime.utc(2026, 1, i), i * 1.0),
            'insert #$i completing against a down database');
      }
      await eventually(() => sink.stats.rowsQueued == 3,
          'three rows counted as queued while the database is down');
      expect(sink.stats.rowsWritten, 0);
      expect(seen, isNot(contains(true)),
          reason: 'nothing was ever reachable, so a true on the connected '
              'stream would be an invention');
    });

    test('insert never throws — down, rejecting, untypeable, unnameable',
        () async {
      final backend = FakeWriteBackend();
      final sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async => Database(backend),
        sleep: shortSleep,
      );
      addTearDown(sink.close);
      await sink.start();
      await within(sink.connected.firstWhere((up) => up),
          'the sink coming up over an accepting backend',
          budget: const Duration(seconds: 5));

      // A down backend: the row buffers.
      backend.down = true;
      await within(sink.insert('gw_a', DateTime.utc(2026), 1.0),
          'insert completing against a down backend');
      backend.down = false;

      // A backend that rejects the batch contents at the flush boundary.
      backend.rejectWith = Exception('Severity.error 22003: out of range');
      await within(sink.insert('gw_b', DateTime.utc(2026), 2.0),
          'insert completing against a rejecting backend');
      await within(sink.flush(), 'flush completing over a rejecting backend');
      backend.rejectWith = null;

      // A table that cannot be typed: first sample null, table absent.
      backend.existsResult = false;
      await within(sink.insert('gw_c', DateTime.utc(2026), null),
          'insert completing for an untypeable first sample');
      backend.existsResult = true;

      // A table name the layer below refuses outright.
      final droppedBefore = sink.stats.rowsDropped;
      await within(sink.insert('', DateTime.utc(2026), 3.0),
          'insert completing for an empty table name');
      expect(sink.stats.rowsDropped, droppedBefore + 1,
          reason: 'a row the sink could not even hand over is still a lost '
              'row, and a lost row is a counted row');
    });
  });

  group("Database's own keep-or-lose distinction, surfaced", () {
    late FakeWriteBackend backend;
    late TimescaleSink sink;

    setUp(() async {
      backend = FakeWriteBackend();
      sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async => Database(backend),
        sleep: shortSleep,
      );
      await sink.start();
      await within(sink.connected.firstWhere((up) => up),
          'the sink coming up over an accepting backend',
          budget: const Duration(seconds: 5));
    });

    tearDown(() => sink.close());

    test('buffered rows reach the backend in arrival order after flush()',
        () async {
      for (var i = 1; i <= 5; i++) {
        await sink.insert('gw_t', DateTime.utc(2026, 1, i), i.toDouble());
      }
      expect(backend.stored, isEmpty,
          reason: 'nothing has been flushed yet — insert is a buffer append');
      await sink.flush();
      expect(backend.storedValues, [1.0, 2.0, 3.0, 4.0, 5.0],
          reason: 'every row, in arrival order — a hole or a reorder here '
              'is a hole or a reorder in the plant history');
      await eventually(() => sink.stats.rowsWritten == 5,
          'five rows counted as written');
      expect(sink.stats.rowsQueued, 0);
      expect(sink.stats.rowsDropped, 0);
    });

    test('a connection error keeps the rows, visible as queued', () async {
      backend.down = true;
      // 60 crosses the internal 50-row batch boundary, so both the inline
      // flush path and the explicit one are exercised.
      for (var i = 1; i <= 60; i++) {
        await sink.insert('gw_t', DateTime.utc(2026).add(Duration(seconds: i)),
            i.toDouble());
      }
      await sink.flush();
      expect(sink.stats.rowsQueued, 60,
          reason: 'a database that is down is the database\'s fault: every '
              'row is kept and counted as waiting');
      expect(sink.stats.rowsDropped, 0);
      expect(backend.stored, isEmpty);
    });

    test('a content rejection loses exactly those rows, counted as dropped',
        () async {
      backend.rejectWith =
          Exception('Severity.error 22003: integer out of range');
      for (var i = 1; i <= 5; i++) {
        await sink.insert('gw_t', DateTime.utc(2026).add(Duration(seconds: i)),
            i.toDouble());
      }
      await sink.flush();
      expect(sink.stats.rowsDropped, 5,
          reason: 'a SQLSTATE class 22 is the batch\'s own fault and '
              're-sending identical rows cannot succeed — the loss must be '
              'immediate and counted, not a five-second retry heartbeat');
      expect(sink.stats.rowsQueued, 0,
          reason: 're-queueing a poisoned batch is the infinite loop '
              'Database._handleFailedBatch exists to prevent');
    });
  });

  group('a refused namespace is a counted drop, never a deferred replay',
      () {
    test(
        'rows handed over while refused are dropped-and-counted, the pen is '
        'drained, and takeover replays nothing from the contested window',
        () async {
      final backend = FakeWriteBackend();
      var refuse = true;
      final sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async {
          if (refuse) throw const AdvisoryLockRefused('other-gateway');
          return Database(backend);
        },
        sleep: shortSleep,
      );
      addTearDown(sink.close);

      // One row lands in the pen during the connect window, before the
      // refusal is known.
      await sink.insert('gw_t', DateTime.utc(2026, 1, 1), 0.5);
      await sink.start();
      await eventually(
          () => sink.stats.lastError?.contains('other-gateway') ?? false,
          'the refusal naming the holder');

      // The refusal drained the pen: the contested-window row is a counted
      // drop, not a replay waiting to happen.
      expect(sink.stats.rowsQueued, 0,
          reason: 'a refused gateway holding a pen is a takeover that '
              'back-fills the window another writer owned (WR-01)');
      expect(sink.stats.rowsDropped, 1);

      // Rows handed over while refused: dropped and counted, never penned.
      for (var i = 1; i <= 3; i++) {
        await sink.insert(
            'gw_t', DateTime.utc(2026, 1, 1 + i), i.toDouble());
      }
      expect(sink.stats.rowsQueued, 0);
      expect(sink.stats.rowsDropped, 4);

      // The holder releases; this gateway takes over — and replays NOTHING
      // from the refused hour.
      refuse = false;
      await within(sink.connected.firstWhere((up) => up),
          'the takeover connecting', budget: const Duration(seconds: 5));
      await sink.flush();
      expect(backend.stored, isEmpty,
          reason: 'the shared tables must never hold both gateways\' '
              'samples for the refused window — that is the doubling '
              'defect arriving retroactively');

      // Post-takeover rows land normally.
      await sink.insert('gw_t', DateTime.utc(2026, 2, 1), 9.0);
      await sink.flush();
      expect(backend.storedValues, [9.0]);
      expect(sink.stats.rowsDropped, 4,
          reason: 'ownership acquired: drops stop with the refusal');
    });
  });

  group('lastError is redacted', () {
    test('no endpoint host, no database name, no username — by value',
        () async {
      final sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async => throw Exception(
            'FATAL: connection to "redact-me-host.invalid" failed: '
            'database "redact_me_db", user "redact_me_user"'),
        sleep: shortSleep,
      );
      addTearDown(sink.close);
      await sink.start();
      await eventually(() => sink.stats.lastError != null,
          'a connect failure surfacing in lastError');

      final err = sink.stats.lastError!;
      expect(err, isNot(contains('redact-me-host.invalid')),
          reason: 'the endpoint host, straight out of the driver error — '
              'this string becomes PIPE.collect.last_error, which any panel '
              'can subscribe to (T-8b-07)');
      expect(err, isNot(contains('redact_me_db')),
          reason: 'the database name must not reach a panel');
      expect(err, isNot(contains('redact_me_user')),
          reason: 'the username must not reach a panel');
      expect(err, isNot(contains('redact_me_password')),
          reason: 'and the credential, obviously, though no driver should '
              'ever echo it');
      expect(err, contains('Exception'),
          reason: 'redaction is not muteness: the failure class survives, '
              'so an operator can still tell a refusal from a timeout');
    });

    test('a five-character token in a driver message is not laundered into '
        'a SQLSTATE (IN-04)', () async {
      final sink = TimescaleSink(
        enabledConfig(),
        // A pid here; a port in a socket message is the same shape. The
        // freeze's literal-port sweep is why this arm does not spell one.
        backendFactory: (_) async =>
            throw Exception('server closed: backend pid 42840 terminated'),
        sleep: shortSleep,
      );
      addTearDown(sink.close);
      await sink.start();
      await eventually(() => sink.stats.lastError != null,
          'a connect failure surfacing in lastError');
      expect(sink.stats.lastError, isNot(contains('SQLSTATE')),
          reason: 'a port number matched by shape alone would be served as '
              '"SQLSTATE 42840" — the pattern must not claim standard-fixed '
              'provenance for a token it did not verify (IN-04)');
    });

    test('a genuine driver SQLSTATE survives, anchored to the driver\'s own '
        'message shape', () async {
      final sink = TimescaleSink(
        enabledConfig(),
        // ServerException.toString() is '\$severity \$code: \$message'
        // (postgres exceptions.dart:160); this is that shape, as it also
        // survives an isolate hop as a plain string.
        backendFactory: (_) async =>
            throw Exception('Severity.error 22003: value out of range'),
        sleep: shortSleep,
      );
      addTearDown(sink.close);
      await sink.start();
      await eventually(() => sink.stats.lastError != null,
          'a connect failure surfacing in lastError');
      expect(sink.stats.lastError, contains('SQLSTATE 22003'),
          reason: 'anchoring must not cost the one detail the redaction '
              'deliberately keeps: the standard-fixed failure code');
    });
  });

  group('shutdown and idempotence', () {
    test('close() flushes what is buffered, and a second close is a no-op',
        () async {
      final backend = FakeWriteBackend();
      final sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async => Database(backend),
        sleep: shortSleep,
      );
      await sink.start();
      await within(sink.connected.firstWhere((up) => up),
          'the sink coming up over an accepting backend',
          budget: const Duration(seconds: 5));
      for (var i = 1; i <= 3; i++) {
        await sink.insert('gw_t', DateTime.utc(2026, 1, i), i.toDouble());
      }
      await within(sink.close(), 'close() completing',
          budget: const Duration(seconds: 5));
      expect(backend.storedValues, [1.0, 2.0, 3.0],
          reason: 'close() flushes: rows an orderly shutdown was holding '
              'are not an acceptable loss');
      await within(sink.close(), 'a second close() completing',
          budget: const Duration(seconds: 5));
    });

    test('rows the final flush could not push are counted losses, and '
        'post-close stats do not report them as written (IN-01)', () async {
      final backend = FakeWriteBackend();
      final sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async => Database(backend),
        sleep: shortSleep,
      );
      await sink.start();
      await within(sink.connected.firstWhere((up) => up),
          'the sink coming up over an accepting backend',
          budget: const Duration(seconds: 5));

      backend.down = true;
      for (var i = 1; i <= 3; i++) {
        await sink.insert('gw_t', DateTime.utc(2026, 1, i), i.toDouble());
      }
      await within(sink.close(), 'close() completing over a down backend',
          budget: const Duration(seconds: 5));

      expect(backend.stored, isEmpty,
          reason: 'nothing reached the backend — the fixture is the loss '
              'case, or this asserts nothing');
      expect(sink.stats.rowsWritten, 0,
          reason: 'every row ever handed over reported as written — '
              'including the three just discarded by db.close() — is the '
              'lie an incident post-mortem would read (IN-01)');
      expect(sink.stats.rowsDropped, 3,
          reason: 'a lost row is a counted row, wherever it was lost — '
              'including at the moment of shutdown');

      // A straggler after close is a lost row too, not a silent return.
      await sink.insert('gw_t', DateTime.utc(2026, 2, 1), 4.0);
      expect(sink.stats.rowsDropped, 4);
    });

    test('ensureTable is idempotent — the second identical call issues '
        'nothing new', () async {
      final backend = FakeWriteBackend();
      final sink = TimescaleSink(
        enabledConfig(),
        backendFactory: (_) async => Database(backend),
        sleep: shortSleep,
      );
      addTearDown(sink.close);
      await sink.start();
      await within(sink.connected.firstWhere((up) => up),
          'the sink coming up over an accepting backend',
          budget: const Duration(seconds: 5));

      const retention = RetentionPolicy(dropAfter: Duration(days: 30));
      await sink.ensureTable('gw_t', retention);
      final callsAfterFirst = backend.existsCalls;
      await sink.ensureTable('gw_t', retention);
      expect(backend.existsCalls, callsAfterFirst,
          reason: 'the runner calls ensureTable on every (re)connect; a '
              'second identical call must not issue another round of '
              'catalog queries and policy statements');
    });
  });
}
