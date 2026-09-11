/// What the change feed does when its last subscriber leaves **while it is
/// still coming up** (10-REVIEW WR-09).
///
/// The channel is listener-gated: `onListen` opens it and `onCancel` tears it
/// down, so the last session going home and the next one arriving is the
/// ordinary sequence rather than an exotic one. Coming up is not instantaneous
/// — `enableKeyedNotificationChannel` is a round trip, and [_proveListening]
/// then retries a `pg_notify` probe every 100 ms until one comes back — so
/// there is a window several hundred milliseconds wide in which the feed is
/// bringing a channel up for an audience that has already left.
///
/// `preference_change_feed_test.dart` owns everything that needs a real
/// LISTEN/NOTIFY and is `db`-tagged. This file's subject is the *lifecycle*,
/// which is Dart control flow, so it runs in the ordinary lane over a backend
/// that answers the two channel calls itself. Putting it behind the `db` tag
/// would hide a session-churn property on three of the four CI platforms.
@TestOn('vm')
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show QueryRow, ResultSetImplementation, Selectable, Variable;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_relay_local/src/data/preference_change_feed.dart';

/// A backend that answers the two channel calls and never delivers the probe.
///
/// The probe going unanswered is the point, not a shortcut: it is what holds
/// the feed inside [PreferenceChangeFeed._proveListening]'s retry loop for as
/// long as a case needs, which is the window WR-09 is about. A real server
/// answers in a millisecond and the window is real anyway — it is just too
/// short to stand in.
class ProbeStallBackend extends AppDatabase {
  ProbeStallBackend()
      : super.forTest(
            DatabaseConfig(), NativeDatabase.memory(logStatements: false));

  /// How many `pg_notify` probes were sent. A probe per retry is the loop
  /// running; zero is a case that measured nothing.
  int probes = 0;

  /// Whether the channel subscription was cancelled.
  bool cancelled = false;

  /// Whether a channel subscription is currently live — the thing a leak
  /// leaves behind.
  bool get channelSubscribed => _subscribed && !cancelled;
  bool _subscribed = false;

  final _channel = StreamController<String>(sync: true);

  @override
  Future<String> enableKeyedNotificationChannel(String table, String column) async =>
      '${table}_$column';

  @override
  Stream<String> listenToChannel(String channel) {
    _subscribed = true;
    return _channel.stream.transform(
      StreamTransformer<String, String>.fromHandlers(
        handleDone: (sink) => sink.close(),
      ),
    );
  }

  @override
  Selectable<QueryRow> customSelect(String query,
      {List<Variable> variables = const [],
      Set<ResultSetImplementation<dynamic, dynamic>> readsFrom = const {}}) {
    if (query.contains('pg_notify')) {
      probes++;
      return _NoRows();
    }
    return super.customSelect(query, variables: variables, readsFrom: readsFrom);
  }

  Future<void> shut() async {
    cancelled = true;
    await _channel.close();
  }
}

final class _NoRows implements Selectable<QueryRow> {
  @override
  Future<List<QueryRow>> get() async => const <QueryRow>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'this backend answers only get(); ${invocation.memberName} was called '
      'and would have been silently empty');
}

void main() {
  late ProbeStallBackend backend;
  late Database db;
  late PreferenceChangeFeed feed;
  late StreamController<String> local;
  late int resyncs;

  setUp(() {
    backend = ProbeStallBackend();
    db = Database(backend);
    addTearDown(db.close);
    local = StreamController<String>.broadcast();
    resyncs = 0;
    feed = PreferenceChangeFeed(
      database: () => db,
      local: local.stream,
      resync: () async {
        resyncs++;
        return const <String>{};
      },
      // Long enough that a re-listen cannot fire inside a case and confuse
      // what is being counted.
      relistenBackoff: const Duration(seconds: 30),
    );
    addTearDown(feed.close);
  });

  test('the last subscriber leaving mid-listen leaves the channel down',
      () async {
    final sub = feed.changes.listen((_) {});
    // Two retry intervals: enough that the probe loop has definitely gone
    // round, so the case is inside the window rather than before it.
    await Future<void>.delayed(
        PreferenceChangeFeed.probeRetryInterval * 2 + const Duration(milliseconds: 20));
    expect(backend.probes, greaterThan(0),
        reason: 'the anti-vacuity arm: if no probe was ever sent the feed '
            'never reached the window this case is about, and everything '
            'below is true of a feed that did nothing');

    await sub.cancel();
    // Long enough for the in-flight _proveListening to notice and unwind.
    await Future<void>.delayed(
        PreferenceChangeFeed.probeRetryInterval * 2 + const Duration(milliseconds: 20));

    expect(feed.hasListener, isFalse);
    expect(feed.channelUp, isFalse,
        reason: '_proveListening returns early on its own hasListener test, '
            'and control used to fall straight through to `_channelUp = true`. '
            'So the feed reported the channel as UP with nobody listening — '
            'and the next subscriber, arriving to a feed that already thinks '
            'it is up, is the session-churn shape the _stopping machinery '
            'exists for');
    expect(resyncs, 0,
        reason: 'and _closeTheGap must not run either: it is two full reads '
            'of the preference store, performed for an audience of none');
  });

  test('a subscriber that stays gets the channel up', () async {
    // The companion, and it goes here rather than being assumed: a feed that
    // never brought the channel up would satisfy every assertion above.
    final sub = feed.changes.listen((_) {});
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The probe comes back — this is what a working channel does, and the
    // stalled backend above is the same feed with that one message withheld.
    backend._channel.add('{"action":"PROBE","probe":"any"}');
    await pumpEventQueue();

    expect(backend.channelSubscribed, isTrue);
  });

  test('closing the feed while it is coming up leaves nothing subscribed',
      () async {
    final sub = feed.changes.listen((_) {});
    addTearDown(sub.cancel);
    await Future<void>.delayed(
        PreferenceChangeFeed.probeRetryInterval + const Duration(milliseconds: 20));

    await feed.close();

    expect(feed.channelUp, isFalse,
        reason: 'the same fall-through by the other door: a feed that closed '
            'mid-listen must not come to rest reporting a channel it does '
            'not have');
  });
}
