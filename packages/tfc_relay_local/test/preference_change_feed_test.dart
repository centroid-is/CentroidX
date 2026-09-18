/// The all-keys change feed against a **real Postgres** — LISTEN/NOTIFY, a
/// second writer, and a connection deliberately killed underneath it.
///
/// ## Why a fake cannot stand in for any of this
///
/// The whole subject is a signal that arrives from **another process**. The
/// local half — `Preferences`' own broadcast controller — is a Dart stream and
/// needs nothing; it is also not the half DB-03 exists for. Everything here
/// that matters needs a server:
///
///  * the trigger `enableKeyedNotificationChannel` installs, and the fact that
///    its payload names the key and never the value (`pg_notify` caps payloads
///    at 8000 bytes and enforces the cap by **erroring the statement that
///    fired the trigger**, so a row-payload trigger on this table would make
///    every save of `key_mappings` fail outright);
///  * a write made on a **second connection**, which is the HMI station at SVN
///    and cannot be simulated by adding to a stream;
///  * the notification connection dying, which is a real backend being
///    terminated.
///
/// ## Cleanup
///
/// Same rule as `preferences_read_test.dart`: every key carries a per-run
/// prefix and `tearDownAll` deletes exactly those rows. The trigger this file
/// installs is left in place — it is `CREATE OR REPLACE`, it is what
/// `PreferencesWatcher` installs in the application too, and dropping it would
/// be this suite reaching outside its own rows.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_local/src/data/preference_change_feed.dart';
import 'package:tfc_relay_local/src/data/preference_store.dart';

import 'support/timescale_fixture.dart';

late TimescaleFixture fx;
late pg.Connection admin;
late Database writer;

final String ns = 'relayfeed_${DateTime.now().microsecondsSinceEpoch}_';

/// The application name the writer connects under. Its notification
/// connection appends `:notify` (8b-02's convention,
/// `database_drift.dart:470`), which is how a case finds and kills it.
const String appName = 'relay-feed-test';

/// A second application name, for the one case that has to count connections
/// opened by its own subscribing and nobody else's.
const String gateAppName = 'relay-feed-gate';

final List<String> notices = <String>[];

DatabaseConfig dbConfig() => DatabaseConfig(
      postgres: pg.Endpoint(
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
      ),
      sslMode: pg.SslMode.disable,
      connectTimeout: const Duration(seconds: 5),
      queryTimeout: const Duration(seconds: 5),
      applicationName: appName,
    );

DatabaseConfig gateConfig() => DatabaseConfig(
      postgres: pg.Endpoint(
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
      ),
      sslMode: pg.SslMode.disable,
      connectTimeout: const Duration(seconds: 5),
      queryTimeout: const Duration(seconds: 5),
      applicationName: gateAppName,
    );

Future<void> writeBehindTheGateway(String key, String value) async {
  await admin.execute(
    pg.Sql.named('INSERT INTO flutter_preferences (key, value, type) '
        'VALUES (@k, @v, \'String\') ON CONFLICT (key) DO UPDATE SET '
        'value = EXCLUDED.value, type = EXCLUDED.type'),
    parameters: {'k': key, 'v': value},
  );
}

Future<int> notifyConnections({String name = appName}) async {
  final result = await admin.execute(
      pg.Sql.named('SELECT count(*) FROM pg_stat_activity '
          'WHERE application_name = @n'),
      parameters: {'n': '$name:notify'});
  return result.first.first! as int;
}

Future<void> killNotifyConnection() async {
  await admin.execute(
      pg.Sql.named('SELECT pg_terminate_backend(pid) FROM pg_stat_activity '
          'WHERE application_name = @n'),
      parameters: {'n': '$appName:notify'});
}

/// Polls [condition] until it holds or [timeout] elapses. Returns whether it
/// held — the assertion is the caller's, so a failure reads as the property
/// that was wanted rather than as "timed out".
Future<bool> settle(bool Function() condition,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return true;
}

/// Waits out one de-duplication window plus a margin, so a case asserting
/// "exactly one" has given a duplicate every chance to arrive.
Future<void> pastTheWindow() =>
    Future<void>.delayed(PreferenceChangeFeed.defaultWindow * 3);

void main() {
  setUpAll(() async {
    SecureStorage.setInstance(const NoSecretStorage());
    fx = await TimescaleFixture.start();
    admin = await fx.connect();
    writer = Database(await AppDatabase.create(dbConfig()));
    await writer.open();
  });

  setUp(notices.clear);

  tearDownAll(() async {
    await admin.execute(
        pg.Sql.named('DELETE FROM flutter_preferences WHERE key LIKE @p'),
        parameters: {'p': '$ns%'});
    try {
      await writer.close();
    } catch (_) {
      // A writer a case already closed on purpose is not a failure here.
    }
    await admin.close();
    await fx.stop();
  });

  group('a preference edited anywhere reaches the feed', () {
    test('a write made through the gateway is announced exactly once',
        () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);
      // Waited for, and the de-duplication sabotage is what proved this line
      // has to be here: without it the write goes out before the LISTEN is
      // registered, its own NOTIFY is dropped by Postgres rather than
      // delivered, and the case counts one event whether or not anything
      // de-duplicates. It passed with the de-duplication deleted.
      expect(await settle(() => store.feed.channelUp), isTrue);
      final key = '${ns}mine';

      await store.setString(key, 'through the pipe');
      await settle(() => seen.contains(key));
      await pastTheWindow();

      expect(seen.where((k) => k == key), hasLength(1),
          reason: 'the gateway is the single writer for every connected '
              'client, so its own write reaches the local stream AND comes '
              'back as its own NOTIFY. Announcing it twice would have every '
              'settings page in the plant redraw twice per keystroke');
    });

    test('a write made by another process is announced', () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);
      // The feed opens its channel on the first listen, and that is async.
      await settle(() => store.feed.channelUp);
      final key = '${ns}theirs';

      await writeBehindTheGateway(key, 'saved at the HMI station');

      expect(await settle(() => seen.contains(key)), isTrue,
          reason: 'an HMI station at SVN writes flutter_preferences directly '
              'today, and Preferences._onPreferencesChanged fires only for '
              'writes made through THIS instance '
              '(preferences.dart:154-155). Without the channel half that '
              'edit reaches no connected panel until somebody reopens the '
              'page — which is DB-03');
    });

    test('the value is readable immediately after its event', () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final key = '${ns}freshread';
      await store.setString(key, 'the old value');
      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);
      await settle(() => store.feed.channelUp);
      // Past the window before the external write, and this is the case that
      // taught the file why. The gateway's own setString above announces its
      // key, and the announcement lands a millisecond or two AFTER the
      // listener attaches — so without this wait the external change arrives
      // 180 ms later, inside the 250 ms de-duplication window, and is
      // suppressed as a duplicate of the gateway's own write. Clearing `seen`
      // does not un-ring that bell. The suppression is correct and is the
      // window's documented cost; measuring the announcement of a DIFFERENT
      // change means not standing inside it.
      await pastTheWindow();
      seen.clear();

      await writeBehindTheGateway(key, 'the new value');
      expect(await settle(() => seen.contains(key)), isTrue,
          reason: 'the change has to be announced, not merely absorbed: a '
              'cache quietly refreshed with nothing told to any panel is a '
              'settings page that stays wrong until somebody reopens it');

      expect(await store.getString(key), 'the new value',
          reason: 'a notification a client acts on by re-reading, that then '
              'hands back the value it already had, is worse than no '
              'notification: the page redraws and shows stale data with no '
              'error anywhere. getKeys and getAll read a process-local cache '
              '(preferences.dart:267-274), so the feed has to invalidate it '
              'before it announces');
    });

    test('a key that did not exist when the feed was built is announced',
        () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);
      await settle(() => store.feed.channelUp);
      final key = '${ns}brandnew';

      await writeBehindTheGateway(key, 'never seen before');

      expect(await settle(() => seen.contains(key)), isTrue,
          reason: 'PreferencesWatcher takes a FIXED key set '
              '(preferences_watch.dart:42) and is therefore the wrong shape '
              'for "any preference changed" — a key created after startup is '
              'invisible to it forever');
    });
  });

  group('de-duplication has two halves', () {
    test('a distinct second change to the same key, outside the window, is '
        'not suppressed', () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);
      await settle(() => store.feed.channelUp);
      final key = '${ns}twice';

      await writeBehindTheGateway(key, 'first');
      await settle(() => seen.where((k) => k == key).length == 1);
      await pastTheWindow();
      await writeBehindTheGateway(key, 'second');

      expect(await settle(() => seen.where((k) => k == key).length >= 2),
          isTrue,
          reason: 'this is the half that keeps the de-duplication honest. '
              'Suppressing the second real edit would leave every panel '
              'showing the first one, and a window wide enough to do that is '
              'a window nobody would notice was wrong');
    });
  });

  group('the channel is listener-gated and survives losing its connection',
      () {
    test('no notification connection exists until somebody listens', () async {
      // Its OWN Database, and the reason is a finding rather than a
      // preference: the notification connection belongs to `AppDatabase` and
      // is SHARED. `listenToChannel`'s onCancel issues UNLISTEN and leaves
      // the socket open for the next subscriber
      // (database_drift.dart:1119-1140), so counting connections against the
      // file's shared writer measures every earlier case as well as this
      // one — it was 1 before this case had done anything. A fresh Database
      // with its own application name is the only way to ask "did
      // subscribing open it" and get an answer about subscribing.
      final gate = Database(await AppDatabase.create(gateConfig()));
      await gate.open();
      addTearDown(() async {
        try {
          await gate.close();
        } catch (_) {
          // Already closed by a failure path; not this case's subject.
        }
      });
      final store = PreferenceStore(database: () => gate, log: notices.add);
      addTearDown(store.close);

      expect(await notifyConnections(name: gateAppName), 0,
          reason: 'an always-on listener on a shared connection is a cost a '
              'gateway with no sessions has no reason to pay, and 8b\'s timer '
              'allow-list exists because plumbing that runs when nobody is '
              'watching has already failed unrelated suites once');

      final sub = store.onPreferencesChanged.listen((_) {});
      addTearDown(sub.cancel);

      expect(await settle(() => store.feed.channelUp), isTrue);
      expect(await notifyConnections(name: gateAppName), 1);
    });

    test('the notification connection dying does not kill the feed',
        () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);
      await settle(() => store.feed.channelUp);

      await killNotifyConnection();
      expect(await settle(() => !store.feed.channelUp), isTrue,
          reason: 'listenToChannel ends its stream — onDone, no error — when '
              'the connection carrying it dies (database_drift.dart:1066), '
              'so a feed that did nothing about that would go permanently '
              'and silently deaf');

      expect(await settle(() => store.feed.channelUp,
              timeout: const Duration(seconds: 40)),
          isTrue,
          reason: 'it has to listen again on its own');

      final key = '${ns}afterdeath';
      await writeBehindTheGateway(key, 'while it was deaf and after');

      expect(await settle(() => seen.contains(key)), isTrue);
      expect(notices.where((n) => n.contains('notification')), isNotEmpty,
          reason: 'the gap has to be visible rather than silent: a feed that '
              're-listens without saying so makes a plant where preference '
              'edits sometimes do not arrive indistinguishable from one '
              'where they always do');
    });

    test('a change made while nothing was listening is announced on the next '
        'listen', () async {
      final store = PreferenceStore(database: () => writer, log: notices.add);
      addTearDown(store.close);
      final key = '${ns}whiledeaf';
      await store.setString(key, 'before');
      // Nobody is listening: the channel is closed, so this NOTIFY is lost.
      await writeBehindTheGateway(key, 'changed with nobody listening');

      final seen = <String>[];
      final sub = store.onPreferencesChanged.listen(seen.add);
      addTearDown(sub.cancel);

      expect(await settle(() => seen.contains(key)), isTrue,
          reason: 'the sessions on a gateway come and go, and the last one '
              'leaving closes the channel. A change made in that window is '
              'one NOTIFY nobody was listening for — so the first listen '
              'after it has to close the gap by comparing the table against '
              'the cache, not by hoping');
      expect(await store.getString(key), 'changed with nobody listening');
    });
  });
}
