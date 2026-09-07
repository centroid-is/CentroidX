// Cold start used to leave the plant page blank until Postgres answered.
//
// `AssetView` renders whatever `pageManagerProvider` gives it, and that
// provider hangs off `preferencesProvider` -> `databaseProvider`. Measured
// against the real plant config: 75 ms when the server is reachable, 5 ms when
// the port refuses — and 10 012 ms when the host is routable but never answers,
// which is what a powered-off server or a cut link looks like. For those ten
// seconds the operator got `SizedBox.shrink()`.
//
// The app already loads a PageManager from local SharedPreferences before
// runApp (2.3 ms) and threw it away. Now it seeds `bootstrapPageManagerProvider`
// and the page paints from it immediately — clearly marked as unconfirmed,
// because that copy can be stale, and superseded the instant the database copy
// lands.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/widgets/zoomable_canvas.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc_dart/core/preferences.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Counts how many times a probe asset's subtree was mounted and torn down.
int _probeMounts = 0;
int _probeDisposes = 0;

/// An asset whose only job is to report whether its subtree survived a rebuild.
///
/// It wraps itself in a [SidePaneOwner] exactly as the real pane-owning assets
/// do (`AnalogBox`, the Beckhoff modules), so a teardown here closes a pane for
/// the same reason a teardown there would.
class _ProbeAsset extends BaseAsset {
  _ProbeAsset() {
    coordinates = Coordinates(x: 0.5, y: 0.5);
  }

  @override
  Widget build(BuildContext context) => const SidePaneOwner(
        paneId: 'probe',
        child: _Probe(),
      );

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {'type': 'probe'};
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _probeMounts++;
  }

  @override
  void dispose() {
    _probeDisposes++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 20, height: 20);
}

PageManager _managerWithProbe(String path) => PageManager(
      pages: {
        path: AssetPage(
          menuItem: MenuItem(label: path, path: path, icon: Icons.factory),
          assets: [_ProbeAsset()],
          mirroringDisabled: false,
        ),
      },
      prefs: InMemoryPreferences(),
    );

PageManager _managerWith(Iterable<String> paths) => PageManager(
      pages: {
        for (final path in paths)
          path: AssetPage(
            menuItem: MenuItem(label: path, path: path, icon: Icons.factory),
            assets: [],
            mirroringDisabled: false,
          ),
      },
      prefs: InMemoryPreferences(),
    );

Widget _app({
  required List<Override> overrides,
  String pageName = '/line-1',
}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(body: PlantPageView(pageName: pageName)),
      ),
    );

/// A [pageManagerProvider] override that never resolves — the black-hole
/// database.
Override _dbNeverAnswers() =>
    pageManagerProvider.overrideWith((ref) => Completer<PageManager>().future);

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('paints the cached page while the database is still pending',
      (tester) async {
    await tester.pumpWidget(_app(overrides: [
      _dbNeverAnswers(),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWith(['/line-1'])),
    ]));
    await tester.pump();

    expect(find.byType(AssetStack), findsOneWidget,
        reason: 'the cached layout should be on screen, not a blank box');
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsOneWidget,
        reason: 'and it must be marked as not yet confirmed');
  });

  testWidgets('stays blank when there is no cached page to fall back on',
      (tester) async {
    await tester.pumpWidget(_app(overrides: [
      _dbNeverAnswers(),
      bootstrapPageManagerProvider.overrideWithValue(null),
    ]));
    await tester.pump();

    expect(find.byType(AssetStack), findsNothing);
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsNothing);
  });

  testWidgets('the database copy supersedes the cached one and clears the mark',
      (tester) async {
    final completer = Completer<PageManager>();
    await tester.pumpWidget(_app(overrides: [
      pageManagerProvider.overrideWith((ref) => completer.future),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWith(['/line-1'])),
    ]));
    await tester.pump();
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsOneWidget);

    completer.complete(_managerWith(['/line-1']));
    await tester.pumpAndSettle();

    expect(find.byType(AssetStack), findsOneWidget);
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsNothing,
        reason: 'confirmed against the database, so no longer provisional');
  });

  testWidgets('a page deleted on another station disappears when the database '
      'copy arrives', (tester) async {
    // The whole point of the staleness mark: the cached copy can disagree with
    // the database, and the database always wins the moment it speaks.
    final completer = Completer<PageManager>();
    await tester.pumpWidget(_app(overrides: [
      pageManagerProvider.overrideWith((ref) => completer.future),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWith(['/line-1'])),
    ]));
    await tester.pump();
    expect(find.byType(AssetStack), findsOneWidget);

    completer.complete(_managerWith(['/line-2']));
    await tester.pumpAndSettle();

    expect(find.byType(AssetStack), findsNothing);
    expect(find.textContaining('not found'), findsOneWidget);
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsNothing);
  });

  testWidgets('a page-editor save does not fall back to the boot-time copy',
      (tester) async {
    // The page editor invalidates `pageManagerProvider` after saving. If that
    // reset dropped the resolved value we would fall back to the copy loaded
    // at app start — showing the operator the layout from *before* the edit,
    // under a staleness banner, for as long as the reload took.
    var served = 0;
    final container = ProviderContainer(overrides: [
      pageManagerProvider.overrideWith((ref) async {
        served++;
        return _managerWith(['/line-1']);
      }),
      bootstrapPageManagerProvider.overrideWithValue(_managerWith(['/old'])),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: PlantPageView(pageName: '/line-1')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsNothing);

    container.invalidate(pageManagerProvider);
    await tester.pump();

    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsNothing,
        reason: 'a reload of a page we already have is not a cold start');
    expect(find.byType(AssetStack), findsOneWidget);
    await tester.pumpAndSettle();
    expect(served, 2);
  });

  testWidgets('a database error still shows the cached page, marked',
      (tester) async {
    await tester.pumpWidget(_app(overrides: [
      pageManagerProvider
          .overrideWith((ref) => Future<PageManager>.error('no route to host')),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWith(['/line-1'])),
    ]));
    await tester.pumpAndSettle();

    expect(find.byType(AssetStack), findsOneWidget,
        reason: 'an unreachable server must not blank the plant page');
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsOneWidget);
  });

  testWidgets('the staleness mark is outside the zoomable canvas',
      (tester) async {
    // This is what makes showing an unconfirmed layout safe at all. Inside the
    // canvas the strip would pan and zoom with the plant, so an operator who
    // scrolled the page could put the warning off screen and be left looking
    // at an unconfirmed layout with nothing saying so.
    await tester.pumpWidget(_app(overrides: [
      _dbNeverAnswers(),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWith(['/line-1'])),
    ]));
    await tester.pump();

    expect(find.byType(ZoomableCanvas), findsOneWidget);
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ZoomableCanvas),
        matching: find.byKey(PlantPageView.unverifiedBannerKey),
      ),
      findsNothing,
      reason: 'the mark must not be pannable or zoomable off screen',
    );
  });

  testWidgets('an unchanged page keeps its asset subtrees when the database '
      'copy lands', (tester) async {
    // AssetStack keys each asset by `ObjectKey(asset)` — object identity — so
    // that a z-order change moves the element instead of restarting every
    // asset's subscriptions (#180). The database copy is deserialized
    // separately from the cached one, so every Asset is a different instance
    // even when the layout is byte-identical. Without care that means the
    // whole page is torn down and re-subscribed the moment Postgres answers,
    // and any pane the operator has open closes under their finger.
    _probeMounts = 0;
    _probeDisposes = 0;
    final completer = Completer<PageManager>();
    await tester.pumpWidget(_app(overrides: [
      pageManagerProvider.overrideWith((ref) => completer.future),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWithProbe('/line-1')),
    ]));
    await tester.pump();
    expect(_probeMounts, 1);

    completer.complete(_managerWithProbe('/line-1'));
    await tester.pumpAndSettle();

    expect(_probeDisposes, 0,
        reason: 'the layout did not change, so nothing should have been '
            'torn down — a teardown restarts every subscription and closes '
            'any open equipment pane');
    expect(_probeMounts, 1);
  });

  testWidgets('a page the cache has never seen waits rather than claiming it '
      'does not exist', (tester) async {
    // A page created on another station is absent from this station's cache.
    // "Page not found" would be a lie until the database has had its say.
    await tester.pumpWidget(_app(overrides: [
      _dbNeverAnswers(),
      bootstrapPageManagerProvider
          .overrideWithValue(_managerWith(['/line-2'])),
    ]));
    await tester.pump();

    expect(find.textContaining('not found'), findsNothing);
    expect(find.byKey(PlantPageView.unverifiedBannerKey), findsOneWidget);
  });
}
