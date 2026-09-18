// One timeseries key, one stream — however many readouts are looking at it.
//
// Before this, every readout instance owned its own NOTIFY subscription,
// history fetch, cache and reconciling sweep. The page's accept-ratio and the
// same figure in an open side pane were two full copies of the plumbing that
// merely tended to agree. This drives the shared per-key tracker: a second
// readout on the same key must ride the first one's subscription and cache,
// see the same numbers by construction, and the whole thing must fold up only
// when the last readout goes.

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

final _tick = kTimeseriesResyncInterval + const Duration(seconds: 1);

// ---------------------------------------------------------------------------
// Doubles — same shape as timeseries_notify_resync_test.dart.
// ---------------------------------------------------------------------------

class _FakeAppDatabase extends Fake implements AppDatabase {
  final List<StreamController<String>> channels = [];
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

  StreamController<String> get channel => channels.last;

  void notify(DateTime time) => channel.add(jsonEncode({
        'action': 'INSERT',
        'data': {'time': time.toUtc().toIso8601String(), 'value': 1},
      }));
}

/// A database whose NOTIFY trigger can never be installed — a table the
/// collector owns with permissions gone wrong, say. The one shape of failure
/// that would otherwise retry (with a full-window fetch each time) every
/// sweep forever.
class _FailingAppDatabase extends _FakeAppDatabase {
  int attempts = 0;

  @override
  Future<String> enableNotificationChannel(String tableName) async {
    attempts++;
    throw StateError('permission denied for table $tableName');
  }
}

class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;

  final List<DateTime> rows = [];
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
// A minimal counting readout on the mixin.
// ---------------------------------------------------------------------------

class _Readout extends ConsumerStatefulWidget {
  const _Readout({super.key, this.windowMinutes = 60});

  final int windowMinutes;

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
  int get tsMaxWindowMinutes => widget.windowMinutes;

  @override
  void tsOnIntervalChanged(int minutes) {}

  @override
  void tsUpdateDisplay() {
    if (!mounted) return;
    setState(() {
      count = tsCache.countSince(
          _key,
          DateTime.now()
              .subtract(Duration(minutes: widget.windowMinutes)));
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

  Widget harness(List<Widget> readouts) => ProviderScope(
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
        child: MaterialApp(home: Scaffold(body: Column(children: readouts))),
      );

  List<_ReadoutState> states(WidgetTester tester) =>
      tester.stateList<_ReadoutState>(find.byType(_Readout)).toList();

  DateTime ago(Duration d) => DateTime.now().subtract(d);

  const pageReadout = _Readout(key: ValueKey('page'));
  const paneReadout = _Readout(key: ValueKey('pane'));

  /// Mounts the page and pane readouts over a table holding one row.
  Future<void> mountBoth(WidgetTester tester) async {
    database.rows.add(ago(const Duration(minutes: 10)));
    await tester.pumpWidget(harness(const [pageReadout, paneReadout]));
    await tester.pumpAndSettle();
  }

  testWidgets('two readouts on one key share one subscription and one fetch',
      (tester) async {
    await mountBoth(tester);

    expect(appDb.channels, hasLength(1),
        reason: 'the key must be LISTENed to once, not once per readout');
    expect(appDb.triggersInstalled, 1,
        reason: 'one subscription means one trigger install');
    expect(database.fetches, hasLength(1),
        reason: 'history must be fetched once and shared');
    for (final s in states(tester)) {
      expect(s.count, 1, reason: 'both readouts read the shared cache');
    }
  });

  testWidgets('a notification lands on both readouts at once', (tester) async {
    await mountBoth(tester);

    appDb.notify(DateTime.now());
    await tester.pump();

    for (final s in states(tester)) {
      expect(s.count, 2,
          reason: 'page and pane must agree by construction, not by luck');
    }
  });

  testWidgets('the reconciling sweep runs once per key, not per readout',
      (tester) async {
    await mountBoth(tester);
    final fetchesBefore = database.fetches.length;

    await tester.pump(_tick);
    await tester.pumpAndSettle();

    expect(database.fetches.length, fetchesBefore + 1,
        reason: 'one shared sweep, not one per readout');
  });

  testWidgets('closing the pane leaves the page readout live', (tester) async {
    await mountBoth(tester);

    await tester.pumpWidget(harness(const [pageReadout]));
    await tester.pumpAndSettle();

    expect(appDb.channel.hasListener, isTrue,
        reason: 'the surviving readout still owns the subscription');

    appDb.notify(DateTime.now());
    await tester.pump();
    expect(states(tester).single.count, 2);
  });

  testWidgets('the last readout going tears the whole thing down',
      (tester) async {
    await mountBoth(tester);
    final fetchesBefore = database.fetches.length;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(_tick);
    await tester.pump(_tick);

    expect(appDb.channel.hasListener, isFalse,
        reason: 'no readouts left, the NOTIFY subscription must go');
    expect(database.fetches.length, fetchesBefore,
        reason: 'and the sweep with it');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a subscription that keeps failing backs off instead of hammering, '
      'while the display stays fed from cheap merges', (tester) async {
    final failing = _FailingAppDatabase();
    database = _FakeDatabase(failing);
    database.rows.add(ago(const Duration(minutes: 10)));

    await tester.pumpWidget(harness(const [pageReadout]));
    await tester.pumpAndSettle();
    expect(failing.attempts, 1, reason: 'the initial subscribe attempt');
    expect(states(tester).single.count, 1,
        reason: 'no NOTIFY, but history still fetched');

    // Attempts must space out: not one per tick.
    final attemptsPerTick = <int>[];
    for (var i = 0; i < 8; i++) {
      final before = failing.attempts;
      await tester.pump(_tick);
      await tester.pumpAndSettle();
      attemptsPerTick.add(failing.attempts - before);
    }
    final total = attemptsPerTick.fold(0, (a, b) => a + b);
    expect(total, lessThan(5),
        reason: '8 ticks of a hopeless subscription must not mean 8 attempts '
            '(got $attemptsPerTick)');
    expect(total, greaterThan(0), reason: 'but it must keep trying');

    // Meanwhile every tick still reconciled: a fresh row is picked up by the
    // next sweep even while the subscription is backing off.
    final countBefore = states(tester).single.count;
    database.rows.add(DateTime.now());
    await tester.pump(_tick);
    await tester.pumpAndSettle();
    expect(states(tester).single.count, countBefore + 1,
        reason: 'backing off the subscribe must not back off the data');
  });

  testWidgets('a readout with a wider window grows the shared cache',
      (tester) async {
    // A row visible only to a 2-hour window.
    database.rows.add(ago(const Duration(minutes: 90)));
    database.rows.add(ago(const Duration(minutes: 10)));
    await tester
        .pumpWidget(harness(const [_Readout(key: ValueKey('narrow'))]));
    await tester.pumpAndSettle();
    expect(states(tester).single.count, 1,
        reason: 'the 60-minute readout must not count the 90-minute row');

    await tester.pumpWidget(harness(const [
      _Readout(key: ValueKey('narrow')),
      _Readout(key: ValueKey('wide'), windowMinutes: 120),
    ]));
    await tester.pumpAndSettle();

    final all = states(tester);
    expect(all[0].count, 1, reason: 'the narrow window is unchanged');
    expect(all[1].count, 2,
        reason: 'the wide readout re-fetched far enough back for its window');
  });
}
