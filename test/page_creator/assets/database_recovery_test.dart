// Timeseries assets must come back on their own when the database appears
// late.
//
// `databaseProvider` returns null — it does not throw — while Postgres is
// unreachable, and retries itself in the background until it connects. Assets
// that grabbed it once with `ref.read` in initState took the null, bailed, and
// stayed blank for the rest of the session.
//
// That is not a rare race. On a plant-wide power cut Flutter is drawing in a
// couple of seconds while Postgres is still replaying WAL, so the HMI wins the
// race essentially every time and every counter, rate and trend on the mimic
// comes up dead until somebody restarts the station.
//
// The obvious fix — swap `ref.read` for `ref.watch` in initState — does NOT
// work, and fails silently. `ConsumerStatefulElement.build` moves
// `_dependencies` aside into `_oldDependencies`, lets the build re-register
// what it watches, then closes everything left over. A watch registered in
// initState is never re-registered by build, so it is closed at the end of the
// first build and never fires again. The first group below pins that down; it
// is the reason `reinitOnTimeseriesSourceAvailable` uses `listenManual`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/bpm.dart';
import 'package:tfc/page_creator/assets/graph.dart';
import 'package:tfc/page_creator/assets/helper/database_recovery.dart';
import 'package:tfc/page_creator/assets/helper/timeseries_notify_mixin.dart';
import 'package:tfc/page_creator/assets/rate_value.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/core/timeseries_source.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// LISTEN/NOTIFY stand-in: hands out a channel per table and never emits.
class _FakeAppDatabase extends Fake implements AppDatabase {
  @override
  Future<String> enableNotificationChannel(String tableName) async =>
      '${tableName}_notify';

  @override
  Stream<String> listenToChannel(String channelName) => const Stream.empty();
}

/// Records which tables were queried, so a test can tell "the asset fetched
/// its history" from "the asset merely stopped throwing".
class _RecordingDatabase extends Fake implements Database {
  final List<String> queried = [];

  /// The `to` bound of each query. The readout and its chart window ask for
  /// very different history depths, which is how a test tells them apart.
  final List<DateTime> queriedTo = [];

  @override
  final AppDatabase db = _FakeAppDatabase();

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    queried.add(tableName);
    queriedTo.add(to);
    return <TimeseriesData<dynamic>>[];
  }

  /// Queries reaching further back than [minutes] — i.e. the chart window's,
  /// not the readout's.
  int deepQueries(int minutes) => queriedTo
      .where((t) => DateTime.now().difference(t) > Duration(minutes: minutes))
      .length;
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

/// The database the overridden [databaseProvider] hands out. Driving it
/// through a provider (rather than re-creating the scope) reproduces what the
/// real provider does when its retry succeeds: same provider, new value.
final _dbSourceProvider = StateProvider<Database?>((ref) => null);

List<Override> _overrides(StateMan stateMan) => [
      databaseProvider.overrideWith((ref) async => ref.watch(_dbSourceProvider)),
      stateManProvider.overrideWith((ref) async => stateMan),
      // The device-local store: the helper now listens to
      // `timeseriesSourceProvider`, which consults the transport row before it
      // decides where history comes from. An empty in-memory store reads as
      // direct mode — the station every arm here is about.
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
    ];

/// Wraps [child] and exposes the container so a test can flip the database on
/// without rebuilding the scope.
class _Harness extends StatelessWidget {
  const _Harness({
    required this.container,
    required this.child,
    this.size = const Size(300, 200),
  });

  final ProviderContainer container;
  final Widget child;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
                width: size.width, height: size.height, child: child),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// A minimal host for TimeseriesNotifyMixin — the mixin backs the BPM,
// RateValue and RatioNumber readouts, which are the widgets that live on the
// mimic page for the whole shift.
// ---------------------------------------------------------------------------

class _MixinHost extends ConsumerStatefulWidget {
  const _MixinHost();

  @override
  ConsumerState<_MixinHost> createState() => _MixinHostState();
}

class _MixinHostState extends ConsumerState<_MixinHost>
    with TimeseriesNotifyMixin<_MixinHost> {
  int displayUpdates = 0;

  @override
  List<String> get tsKeys => ['line/packs'];

  @override
  String? get tsIntervalVariable => null;

  @override
  int get tsMaxWindowMinutes => 60;

  @override
  void tsOnIntervalChanged(int minutes) {}

  @override
  void tsUpdateDisplay() => displayUpdates++;

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
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
// A host that does the naive thing, to show why the naive thing is not enough.
// ---------------------------------------------------------------------------

class _NaiveWatchHost extends ConsumerStatefulWidget {
  const _NaiveWatchHost({required this.inInitState});

  /// Watch from `initState` (the swap the fix was first proposed as) or from
  /// `didChangeDependencies` (the same swap, moved somewhere the framework
  /// permits it).
  final bool inInitState;

  @override
  ConsumerState<_NaiveWatchHost> createState() => _NaiveWatchHostState();
}

class _NaiveWatchHostState extends ConsumerState<_NaiveWatchHost> {
  int builds = 0;

  @override
  void initState() {
    super.initState();
    if (widget.inInitState) ref.watch(databaseProvider);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.inInitState && builds == 0) ref.watch(databaseProvider);
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    return const SizedBox.shrink();
  }
}

void main() {
  late ProviderContainer container;
  late _FakeStateMan stateMan;
  late _RecordingDatabase database;

  setUp(() {
    stateMan = _FakeStateMan();
    database = _RecordingDatabase();
    container = ProviderContainer(overrides: _overrides(stateMan));
  });

  tearDown(() => container.dispose());

  /// Bring the database up, the way the provider's own retry does.
  void databaseComesUp() {
    container.read(_dbSourceProvider.notifier).state = database;
  }

  // -------------------------------------------------------------------------
  group('why listenManual', () {
    testWidgets('ref.watch in initState throws', (tester) async {
      await tester.pumpWidget(_Harness(
          container: container,
          child: const _NaiveWatchHost(inInitState: true)));

      // ConsumerStatefulElement._container is a `late` field initialised with
      // ProviderScope.containerOf(this) — an inherited-widget dependency, and
      // taking one before initState returns is a framework error. `ref.read`
      // gets away with it because it uses containerOf(listen: false).
      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(error.toString(), contains('initState'));
    });

    testWidgets('a watch taken outside build is closed by the first build',
        (tester) async {
      await tester.pumpWidget(_Harness(
          container: container,
          child: const _NaiveWatchHost(inInitState: false)));
      await tester.pumpAndSettle();

      final state =
          tester.state<_NaiveWatchHostState>(find.byType(_NaiveWatchHost));
      final buildsBefore = state.builds;
      expect(buildsBefore, greaterThan(0));

      databaseComesUp();
      await tester.pumpAndSettle();

      // If the watch had stuck, the element would have been marked dirty and
      // rebuilt. It does not: ConsumerStatefulElement.build swaps
      // `_dependencies` out and closes whatever the build did not re-watch.
      expect(state.builds, equals(buildsBefore),
          reason: 'ref.watch outside build must not be trusted to notify — '
              'if this ever starts failing, riverpod changed and '
              'reinitOnTimeseriesSourceAvailable can be reconsidered');
    });
  });

  // -------------------------------------------------------------------------
  group('reinitOnTimeseriesSourceAvailable', () {
    testWidgets('fires when the database arrives after a null start',
        (tester) async {
      final seen = <TimeseriesSource>[];
      TimeseriesSource? current;

      await tester.pumpWidget(_Harness(
        container: container,
        child: _CallbackHost(onInit: (ref) {
          reinitOnTimeseriesSourceAvailable(
            ref,
            currentSource: () => current,
            onSourceAvailable: (db) {
              current = db;
              seen.add(db);
            },
          );
        }),
      ));
      await tester.pumpAndSettle();
      expect(seen, isEmpty, reason: 'no database yet');

      databaseComesUp();
      await tester.pumpAndSettle();
      // A new `DatabaseTimeseriesSource` over the database that just arrived —
      // the identity a caller compares is the source's, not the handle's.
      expect(seen, hasLength(1));
      expect(seen.single, isA<DatabaseTimeseriesSource>());
    });

    testWidgets('does not re-fire for the same database instance',
        (tester) async {
      var calls = 0;
      TimeseriesSource? current;

      await tester.pumpWidget(_Harness(
        container: container,
        child: _CallbackHost(onInit: (ref) {
          reinitOnTimeseriesSourceAvailable(
            ref,
            currentSource: () => current,
            onSourceAvailable: (db) {
              current = db;
              calls++;
            },
          );
        }),
      ));
      await tester.pumpAndSettle();

      databaseComesUp();
      await tester.pumpAndSettle();
      // A repeat emission of the same instance — a rebuild of the override
      // chain, not a reconnect — must not tear the asset down and refetch.
      container.invalidate(databaseProvider);
      await tester.pumpAndSettle();

      expect(calls, equals(1));
    });

    testWidgets('survives rebuilds of the host widget', (tester) async {
      var calls = 0;
      TimeseriesSource? current;

      Widget host() => _Harness(
            container: container,
            child: _CallbackHost(onInit: (ref) {
              reinitOnTimeseriesSourceAvailable(
                ref,
                currentSource: () => current,
                onSourceAvailable: (db) {
                  current = db;
                  calls++;
                },
              );
            }),
          );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      // Twenty frames of the sort a window resize produces. This is exactly
      // what kills a build-scoped subscription registered in initState.
      for (var i = 0; i < 20; i++) {
        await tester.pumpWidget(host());
        await tester.pump(const Duration(milliseconds: 16));
      }

      databaseComesUp();
      await tester.pumpAndSettle();

      expect(calls, equals(1),
          reason: 'the recovery hook must outlive the widget being redrawn');
    });
  });

  // -------------------------------------------------------------------------
  group('TimeseriesNotifyMixin', () {
    testWidgets('fetches history once the database appears late',
        (tester) async {
      await tester.pumpWidget(
          _Harness(container: container, child: const _MixinHost()));
      await tester.pumpAndSettle();

      expect(database.queried, isEmpty,
          reason: 'nothing to query against yet');

      databaseComesUp();
      await tester.pumpAndSettle();

      expect(database.queried, contains('line/packs'),
          reason: 'the readout stayed dead after the database came up');
      final state = tester.state<_MixinHostState>(find.byType(_MixinHost));
      expect(state.displayUpdates, greaterThan(0));
    });

    testWidgets('does not re-fetch while the database stays down',
        (tester) async {
      await tester.pumpWidget(
          _Harness(container: container, child: const _MixinHost()));
      await tester.pumpAndSettle();

      // Several failed retries in a row, all yielding null.
      for (var i = 0; i < 5; i++) {
        container.invalidate(databaseProvider);
        await tester.pumpAndSettle();
      }

      expect(database.queried, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('GraphAsset', () {
    testWidgets('charts history once the database appears late',
        (tester) async {
      final config = GraphAssetConfig(
        primarySeries: [GraphSeriesConfig(key: 'line/weight', label: 'weight')],
      );

      // Wide enough that the chart's own button row does not overflow — an
      // overflow is a layout error and fails the test on its own.
      await tester.pumpWidget(_Harness(
          container: container,
          size: const Size(900, 600),
          child: GraphAsset(config)));
      await tester.pumpAndSettle();

      expect(database.queried, isEmpty);

      databaseComesUp();
      await tester.pumpAndSettle();

      expect(database.queried, contains('line/weight'),
          reason: 'the trend stayed empty after the database came up');
    });

    // Surfaced by the test above: _initRealtimeUpdates assigns
    // `_rtThrottleTimer` unconditionally, and _cleanup only cancelled the
    // realtime *subscriptions*. Every teardown — dispose, and every
    // didUpdateWidget re-init — orphaned a 1 Hz timer holding the State alive.
    // flutter_test's own end-of-test `!timersPending` invariant is what
    // catches it, so the assertion here is the teardown itself.
    testWidgets('tearing the trend down cancels its realtime throttle timer',
        (tester) async {
      final config = GraphAssetConfig(
        primarySeries: [GraphSeriesConfig(key: 'line/weight', label: 'weight')],
      );

      await tester.pumpWidget(_Harness(
          container: container,
          size: const Size(900, 600),
          child: GraphAsset(config)));
      await tester.pumpAndSettle();
      databaseComesUp();
      await tester.pumpAndSettle();

      // The timer only exists once realtime came up.
      expect(database.queried, isNotEmpty);

      await tester.pumpWidget(_Harness(
          container: container,
          size: const Size(900, 600),
          child: const SizedBox.shrink()));
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  // The floating chart windows. Their doc comments say they are meant to be
  // dragged off the readout and left running, so "just close and reopen it"
  // is not the answer for them either.
  //
  // The readout underneath is on TimeseriesNotifyMixin and fetches the same
  // table, so the discriminator is depth: the readout reaches back
  // tsMaxWindowMinutes (60 by default) while the chart window asks for
  // howMany × the largest preset (20 × 60 = 1200).
  // -------------------------------------------------------------------------
  group('floating chart windows', () {
    testWidgets('BPM chart refetches when the database appears late',
        (tester) async {
      await tester.pumpWidget(_Harness(
        container: container,
        size: const Size(900, 700),
        child: BpmWidget(config: BpmConfig(key: 'line/packs')),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BpmWidget));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('BPM Counter'), findsOneWidget,
          reason: 'the chart window did not open');
      expect(database.queried, isEmpty, reason: 'no database yet');

      databaseComesUp();
      // Bounded pumps, not pumpAndSettle: once the chart window has a
      // database it reschedules its poll timer forever, so there is no
      // settled state to wait for.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(database.deepQueries(600), greaterThan(0),
          reason: 'the chart window stayed empty after the database came up '
              '(only the readout underneath refetched)');

      closeAllFloatingDialogs();
      await tester.pump();
      await tester.pumpWidget(_Harness(
          container: container,
          size: const Size(900, 700),
          child: const SizedBox.shrink()));
      await tester.pump();
    });

    testWidgets('RateValue chart refetches when the database appears late',
        (tester) async {
      await tester.pumpWidget(_Harness(
        container: container,
        size: const Size(900, 700),
        child: RateValueWidget(config: RateValueConfig(key: 'line/kg')),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(RateValueWidget));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Rate Value'), findsOneWidget,
          reason: 'the chart window did not open');
      expect(database.queried, isEmpty, reason: 'no database yet');

      databaseComesUp();
      // Bounded pumps, not pumpAndSettle: once the chart window has a
      // database it reschedules its poll timer forever, so there is no
      // settled state to wait for.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(database.deepQueries(600), greaterThan(0),
          reason: 'the chart window stayed empty after the database came up '
              '(only the readout underneath refetched)');

      closeAllFloatingDialogs();
      await tester.pump();
      await tester.pumpWidget(_Harness(
          container: container,
          size: const Size(900, 700),
          child: const SizedBox.shrink()));
      await tester.pump();
    });
  });
}

/// Runs [onInit] once from initState with the state's own ref.
class _CallbackHost extends ConsumerStatefulWidget {
  const _CallbackHost({required this.onInit});

  final void Function(WidgetRef ref) onInit;

  @override
  ConsumerState<_CallbackHost> createState() => _CallbackHostState();
}

class _CallbackHostState extends ConsumerState<_CallbackHost> {
  @override
  void initState() {
    super.initState();
    widget.onInit(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
