/// Whether the station dials Postgres, decided by the transport.
///
/// The owner's observation, reproduced as an arm: a panel in gateway mode
/// opened Preferences and read "Connected" — because `databaseProvider` had no
/// transport branch, and `preferencesProvider` (keepAlive, watched by
/// everything) pulls it up at boot whether or not any screen asks. The whole
/// premise of gateway mode is one WebSocket to the backend, with the backend
/// as the only process that touches TimescaleDB; a panel holding its own
/// Postgres connection needs credentials and a database route this milestone
/// exists to remove, and can silently mask a broken relay path because a
/// screen served from the panel's own database looks identical.
///
/// **The instrument cannot pass by accident.** Both halves share it: a real
/// loopback listener counts TCP connections. The gateway arm asserts zero
/// arrive; the direct arm — the live control — asserts one does, on the same
/// harness, so a broken listener or a provider that stopped dialling entirely
/// reddens the control rather than greening the claim.
///
/// The `preferencesProvider` group applies 17-12's technique one level up:
/// `databaseProvider` overridden to THROW (not just null — a provider can be
/// null-safe and still propagate an exception from a watch it did not need),
/// and the real `preferencesProvider` must build anyway. Its mirror arm keeps
/// direct mode honest: there the database MUST still be consulted.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/test_helpers.dart';

/// A real TCP listener that counts every connection it receives.
///
/// Each accepted socket is destroyed immediately, so a Postgres handshake
/// against it fails fast rather than waiting out a protocol timeout. What is
/// under test is whether a dial *arrives*, never whether it succeeds.
final class _DialCounter {
  _DialCounter._(this._socket);

  final ServerSocket _socket;
  final Completer<void> firstDial = Completer<void>();
  int count = 0;

  int get port => _socket.port;

  static Future<_DialCounter> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final counter = _DialCounter._(socket);
    socket.listen((client) {
      counter.count++;
      if (!counter.firstDial.isCompleted) counter.firstDial.complete();
      client.destroy();
    });
    addTearDown(() => socket.close());
    return counter;
  }
}

/// Seeds the device-local database row with an endpoint at [port] on loopback.
///
/// A VALID row on purpose, in both arms: 17-12's arm 11 recorded why —
/// "unused" is not "unavailable"; a route that exists will be taken, so the
/// gateway arm must show it is not taken even though it could be.
Future<void> _seedDatabaseRow(int port) => DatabaseConfig(
      postgres: pg.Endpoint(
        host: '127.0.0.1',
        port: port,
        database: 'plant',
        username: 'hmi',
        password: 'not-a-secret-this-is-a-test',
      ),
      // Fail fast when the counter's destroy is not enough.
      connectTimeout: const Duration(seconds: 2),
      applicationName: 'database_transport_test',
    ).toPrefs();

/// A device-local store carrying the gateway-mode row.
Future<PreferencesApi> _gatewayLocal() async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(
    local,
    // `ws://` so `validationError` is null without a CA file; the URL is
    // never dialled here — no StateMan is built in this file.
    const GatewayConfig(mode: TransportMode.gateway, url: 'ws://127.0.0.1:1'),
  );
  return local;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  group('databaseProvider', () {
    test('a gateway station never dials Postgres, even with a valid row',
        () async {
      final counter = await _DialCounter.start();
      await _seedDatabaseRow(counter.port);

      final ref = ProviderContainer(overrides: [
        localPreferencesProvider.overrideWithValue(await _gatewayLocal()),
      ]);
      addTearDown(ref.dispose);

      final db = await ref.read(databaseProvider.future);
      expect(db, isNull,
          reason: 'gateway mode holds one WebSocket to the backend; the '
              'backend is the only process that touches TimescaleDB');

      // Grace window for a dial that would be in flight. The direct arm below
      // is the live control proving this counter sees one when it happens.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(counter.count, 0,
          reason: 'the owner watched a gateway panel report "Connected": the '
              'provider had no transport branch and dialled the row anyway');

      // Reading again must not start a retry loop either.
      expect(await ref.read(databaseProvider.future), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(counter.count, 0);
    });

    test('a direct station still dials — the live control', () async {
      final counter = await _DialCounter.start();
      await _seedDatabaseRow(counter.port);

      // An empty device-local store: direct is the default in every
      // direction, and the plant runs it today.
      final ref = ProviderContainer(overrides: [
        localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      ]);
      addTearDown(ref.dispose);

      // The counter is not a Postgres server, so the open fails and the
      // provider answers null — its normal unreachable state. The assertion
      // is the dial itself.
      final db = await ref.read(databaseProvider.future);
      expect(db, isNull);

      await counter.firstDial.future.timeout(const Duration(seconds: 15),
          onTimeout: () => fail(
              'direct mode never dialled the configured endpoint: the fix '
              'for gateway mode must not break the mode half the plant runs'));
      expect(counter.count, greaterThanOrEqualTo(1));
    });
  });

  group('preferencesProvider', () {
    /// The real provider under both transports, with `databaseProvider`
    /// replaced by a recorder. [answer] throwing is 17-12's technique.
    ({ProviderContainer ref, bool Function() touched}) harness({
      required PreferencesApi local,
      required FutureOr<Database?> Function() answer,
    }) {
      var touched = false;
      final ref = ProviderContainer(overrides: [
        localPreferencesProvider.overrideWithValue(local),
        databaseProvider.overrideWith((_) {
          touched = true;
          return answer();
        }),
      ]);
      addTearDown(ref.dispose);
      return (ref: ref, touched: () => touched);
    }

    test('gateway mode builds without touching the database provider at all',
        () async {
      final h = harness(
        local: await _gatewayLocal(),
        answer: () =>
            throw StateError('postgres unreachable: connection refused'),
      );

      final prefs = await h.ref.read(preferencesProvider.future);

      // The screen the owner was looking at reads `prefs.database` for its
      // "Connected" line; in gateway mode there must be nothing to read.
      expect(prefs.database, isNull);
      expect(h.touched(), isFalse,
          reason: 'a keepAlive provider that merely WATCHES databaseProvider '
              'connects the plant even when no screen asks; gateway mode must '
              'not have the dependency, not merely survive it');

      // The store itself must be functional on the local mirror, not merely
      // constructed: a read must answer rather than throw. (A write probe
      // would measure the access guard, not the transport — unknown keys
      // require the administer group by design.)
      expect(await prefs.getString('key_mappings'), isNull);

      // The mirror of the direct arm's rebuild check: in gateway mode the
      // dependency does not exist, so invalidating databaseProvider must NOT
      // rebuild the store — a listen-without-read would still tie the world
      // to a provider gateway mode has no business with.
      h.ref.invalidate(databaseProvider);
      final second = await h.ref.read(preferencesProvider.future);
      expect(identical(prefs, second), isTrue);
      expect(h.touched(), isFalse);
    });

    test('gateway mode with a database PRESENT still carries none', () async {
      // Arm 11's lesson, one level up: the throwing arm cannot see a branch
      // that falls through when a database happens to be available.
      final h = harness(
        local: await _gatewayLocal(),
        answer: () => _NeverUsedDatabase(),
      );

      final prefs = await h.ref.read(preferencesProvider.future);
      expect(prefs.database, isNull);
      expect(h.touched(), isFalse);
    });

    test('direct mode still consults the database — the live control',
        () async {
      final h = harness(
        local: InMemoryPreferences(),
        answer: () => null,
      );

      final prefs = await h.ref.read(preferencesProvider.future);
      expect(prefs.database, isNull); // null answer, honest null carried
      expect(h.touched(), isTrue,
          reason: 'direct mode must keep watching databaseProvider on the '
              'same seam it always did — a "fix" that severed both modes '
              'would break the plant to quiet a settings page');

      // The touch flag alone is satisfiable through the audit sink, which
      // also consults databaseProvider in direct mode — a sabotage run
      // measured exactly that (`final db = null;` here reddened nothing).
      // The WATCH relationship is the property: a database that connects
      // must rebuild the shared store, or every direct station boots onto
      // the local mirror and stays there.
      h.ref.invalidate(databaseProvider);
      final rebuilt = await h.ref.read(preferencesProvider.future);
      expect(identical(prefs, rebuilt), isFalse,
          reason: 'invalidating databaseProvider must rebuild the direct-mode '
              'preferences — severing the watch leaves the plant reading a '
              'store that never notices Postgres coming up');
    });
  });
}

/// A database object whose every member throws.
///
/// Handed to the arm that proves gateway mode does not take an available
/// route: if any code path reaches for it, the arm fails with this sentence
/// rather than a green run over an accidental no-op.
final class _NeverUsedDatabase extends Fake implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
      'gateway mode reached into a Database instance it must not hold');
}
