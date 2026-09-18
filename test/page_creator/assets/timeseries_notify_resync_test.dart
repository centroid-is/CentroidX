// A timeseries readout must never sit on a stale count.
//
// The BPM, rate and accept-ratio readouts fill a cache from one historical
// query and then trust LISTEN/NOTIFY to keep it current. NOTIFY is a stream
// that can stop without saying so: the dedicated connection carrying it dies
// (Postgres restart, a firewall dropping the idle flow) and the driver never
// tells the channel listeners; or the trigger feeding it is dropped by a table
// recreate while the connection stays perfectly healthy. Either way the
// readout on the mimic froze on its last count for the rest of the shift,
// while the same readout freshly mounted in the side pane — which fetches
// history on mount — showed the right figure. An operator comparing the two
// saw them disagree by whatever had happened since the stream died.
//
// The mixin now reconciles with the database on a timer, treats a channel
// that ends or errors as "fetch and re-subscribe", and treats rows the
// database has that the channel never delivered as proof the channel is
// quietly dead. These tests drive each of those through the mixin's own
// lifecycle against a fake database, with the timer under fake time.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/helper/timeseries_notify_mixin.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/state_man.dart';

const _key = 'line/packs';
const _window = Duration(minutes: 60);

/// One tick of the reconciling timer, with a little slack.
final _tick = kTimeseriesResyncInterval + const Duration(seconds: 1);

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// LISTEN/NOTIFY stand-in. Every channel handed out is kept, newest last, so
/// a test can end one, error one, or push a notification down it.
class _FakeAppDatabase extends Fake implements AppDatabase {
  final List<StreamController<String>> channels = [];

  /// How many times the trigger was (re)installed — one per subscription.
  int triggersInstalled = 0;

  @override
  Future<String> enableNotificationChannel(String tableName) async {
    triggersInstalled++;
    return 'table_${tableName}_changes';
  }

  @override
  Stream<String> listenToChannel(String channelName) {
    final controller = StreamController<String>();
    channels.add(controller);
    return controller.stream;
  }

  /// The subscription the widget currently holds.
  StreamController<String> get channel => channels.last;

  /// Delivers an INSERT notification for a row at [time], the way the
  /// trigger's `row_to_json` would: ISO 8601, with a zone.
  void notify(DateTime time) => channel.add(jsonEncode({
        'action': 'INSERT',
        'data': {'time': time.toUtc().toIso8601String(), 'value': 1},
      }));
}

/// The table, and a record of every query against it.
class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;

  final List<DateTime> rows = [];

  /// The `since` bound of every query, in order.
  final List<DateTime> fetches = [];

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    fetches.add(to);
    return [
      for (final t in rows)
        if (!t.isBefore(to)) TimeseriesData<dynamic>(1, t),
    ];
  }
}

class _FakeStateMan extends Fake implements StateMan {
  final _subs = StreamController<Map<String, String>>.broadcast();

  @override
  String resolveKey(String key) => key;

  @override
  String? getSubstitution(String key) => null;

  @override
  Stream<Map<String, String>> get substitutionsChanged => _subs.stream;
}

// ---------------------------------------------------------------------------
// A minimal counting readout on the mixin — what BPM and RatioNumber are.
// ---------------------------------------------------------------------------

class _Readout extends ConsumerStatefulWidget {
  const _Readout();

  @override
  ConsumerState<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends ConsumerState<_Readout>
    with TimeseriesNotifyMixin<_Readout> {
  int count = 0;
  int updates = 0;

  @override
  List<String> get tsKeys => [_key];

  @override
  String? get tsIntervalVariable => null;

  @override
  int get tsMaxWindowMinutes => _window.inMinutes;

  @override
  void tsOnIntervalChanged(int minutes) {}

  @override
  void tsUpdateDisplay() {
    if (!mounted) return;
    setState(() {
      count = tsCache.countSince(_key, DateTime.now().subtract(_window));
      updates++;
    });
  }

  @override
  void initState() {
    super.initState();
    tsInit();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    tsDidChangeDependencies();
  }

  @override
  void dispose() {
    tsDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('$count');
}

void main() {
  late _FakeAppDatabase appDb;
  late _FakeDatabase database;
  late _FakeStateMan stateMan;

  setUp(() {
    appDb = _FakeAppDatabase();
    database = _FakeDatabase(appDb);
    stateMan = _FakeStateMan();
  });

  Widget harness() => ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => database),
          // The device-local store: `timeseriesSourceProvider` consults the
          // transport row before it decides where history comes from, and an
          // empty in-memory store reads as direct mode — the station these
          // arms are about. Same override, for the same reason,
          // `audit_trail_test.dart` carries.
          localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
          stateManProvider.overrideWith((ref) async => stateMan),
        ],
        child: const MaterialApp(home: Scaffold(body: _Readout())),
      );

  _ReadoutState state(WidgetTester tester) =>
      tester.state<_ReadoutState>(find.byType(_Readout));

  DateTime ago(Duration d) => DateTime.now().subtract(d);

  /// Mounts the readout over a table holding one row, and settles.
  Future<void> mount(WidgetTester tester) async {
    database.rows.add(ago(const Duration(minutes: 10)));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(state(tester).count, 1, reason: 'history was not fetched');
    expect(appDb.channels, hasLength(1), reason: 'NOTIFY was not subscribed');
  }

  testWidgets('counts history and live notifications', (tester) async {
    await mount(tester);

    appDb.notify(DateTime.now());
    await tester.pump();

    expect(state(tester).count, 2);
  });

  testWidgets(
      'a channel that ends is re-fetched over the full window and '
      're-subscribed on the next tick', (tester) async {
    await mount(tester);

    // The notification connection dies; AppDatabase ends the stream.
    await appDb.channel.close();
    await tester.pump();
    // A row that landed while nobody was listening. Older than the
    // reconciling slice, so only a full-window fetch finds it.
    database.rows.add(ago(const Duration(minutes: 5)));

    await tester.pump(_tick);
    await tester.pumpAndSettle();

    expect(state(tester).count, 2, reason: 'the missed row was not fetched');
    expect(appDb.channels, hasLength(2),
        reason: 'NOTIFY was not re-subscribed');
    expect(appDb.triggersInstalled, 2);

    // And the new subscription is the live one.
    appDb.notify(DateTime.now());
    await tester.pump();
    expect(state(tester).count, 3);
  });

  testWidgets('a channel that errors is treated the same', (tester) async {
    await mount(tester);

    appDb.channel.addError(StateError('socket closed'));
    await tester.pump();
    database.rows.add(ago(const Duration(minutes: 5)));

    await tester.pump(_tick);
    await tester.pumpAndSettle();

    expect(state(tester).count, 2);
    expect(appDb.channels, hasLength(2));
    expect(tester.takeException(), isNull,
        reason: 'a channel error must be handled, not thrown to the zone');
  });

  testWidgets(
      'rows a live-looking channel never delivered are swept up, and the '
      'channel is re-opened', (tester) async {
    await mount(tester);

    // The trigger was dropped — the stream is open, and silent. This row is
    // older than the grace period, so NOTIFY had every chance to deliver it,
    // and still inside the sweep's slice once the tick has moved the clock
    // on by another [_tick].
    database.rows.add(ago(kTimeseriesNotifyGrace + const Duration(seconds: 5)));

    await tester.pump(_tick);
    await tester.pumpAndSettle();

    expect(state(tester).count, 2, reason: 'the sweep did not merge the row');
    expect(appDb.channels, hasLength(2),
        reason: 'a quiet channel must be re-subscribed');
    expect(appDb.triggersInstalled, 2,
        reason: 're-subscribing is what reinstalls a dropped trigger');
  });

  testWidgets(
      'a row younger than the grace is counted but does not condemn the '
      'channel', (tester) async {
    await mount(tester);

    // Freshly inserted; its notification may simply still be on the wire.
    database.rows.add(ago(const Duration(seconds: 5)));

    await tester.pump(_tick);
    await tester.pumpAndSettle();

    expect(state(tester).count, 2);
    expect(appDb.channels, hasLength(1),
        reason: 'no evidence the channel is dead, so no churn');
  });

  testWidgets('a tick with nothing new repaints nothing', (tester) async {
    await mount(tester);
    final updatesBefore = state(tester).updates;
    final fetchesBefore = database.fetches.length;

    await tester.pump(_tick);
    await tester.pumpAndSettle();

    expect(database.fetches.length, fetchesBefore + 1,
        reason: 'the sweep must still ask the database');
    expect(state(tester).updates, updatesBefore,
        reason: 'and must not rebuild when the answer changes nothing');
    expect(appDb.channels, hasLength(1));
  });

  testWidgets('the same row from history and from NOTIFY counts once',
      (tester) async {
    await mount(tester);

    // The row history already delivered, now announced by NOTIFY — in UTC,
    // where the query handed it over in local time.
    appDb.notify(database.rows.single);
    await tester.pump();

    expect(state(tester).count, 1);
  });

  testWidgets('nothing runs after dispose', (tester) async {
    await mount(tester);
    final fetchesBefore = database.fetches.length;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(_tick);
    await tester.pump(_tick);

    expect(database.fetches.length, fetchesBefore);
    expect(appDb.channel.hasListener, isFalse,
        reason: 'the NOTIFY subscription must be cancelled with the widget');
    expect(tester.takeException(), isNull);
  });
}
