/// The banner's **View** has to take the operator to the page the proposal is
/// about, exactly as **Review all** does.
///
/// Reported from the plant: with the page editor open on one page and a
/// proposal arriving for another, pressing View left the editor on the page it
/// was already showing. The operator is looking at page A while the banner
/// claims to be showing them a change to page B.
///
/// A widget test rather than a source assertion: the whole failure lives in
/// what the editor does with a *second* beam to a route it is already on, and
/// only a pumped editor behind a real [BeamerDelegate] exercises that.
library;

import 'dart:convert';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/page_images.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/widgets/proposal_banner.dart';

import '../helpers/page_editor_harness.dart'
    show
        FakeEditorPreferences,
        coordsOf,
        imageStoreOf,
        testImageStore,
        editorBox,
        pressEditorKey,
        readBackHomeAssets,
        selectedCount,
        setUpEditorEnvironment,
        tapAsset;

/// The two pages the operator can be on. Their labels are what the editor's
/// page selector prints, so they are how the test reads which page is open.
const _homeLabel = 'Home';
const _boxesLabel = 'Boxes';
const _boxesKey = '/boxes';

PageManager _twoPageManager(FakeEditorPreferences prefs) => PageManager(
      prefs: prefs,
      pages: {
        '/': AssetPage(
          menuItem:
              const MenuItem(label: _homeLabel, path: '/', icon: Icons.home),
          assets: [editorBox(0.2, 0.2)],
          mirroringDisabled: true,
          navigationPriority: 0,
        ),
        _boxesKey: AssetPage(
          menuItem: const MenuItem(
              label: _boxesLabel, path: _boxesKey, icon: Icons.inventory),
          assets: [editorBox(0.7, 0.7)],
          mirroringDisabled: true,
          navigationPriority: 1,
        ),
      },
    );

/// An `asset` proposal that adds one box to [pageKey] — the shape
/// `propose_asset` delivers, with `page_key` naming the page it belongs to.
String _assetProposalFor(String pageKey) => jsonEncode({
      '_proposal_type': 'asset',
      '_op': 'create',
      'title': 'Freezer sensor',
      'page_key': pageKey,
      'children': [editorBox(0.4, 0.4).toJson()],
    });

PendingProposal _pending(String proposalJson) => PendingProposal(
      id: -1,
      proposalType: 'asset',
      title: 'Freezer sensor',
      proposalJson: proposalJson,
      operatorId: 'local',
      createdAt: DateTime(2026, 8, 31),
    );

/// The app, as `main.dart` assembles it: the editor behind a real Beamer
/// route that reads the beam's `data` into `proposalData`, with the banner
/// stacked above the Navigator in `MaterialApp.builder`.
Widget _appUnderTest(PageManager manager, ProposalStateNotifier proposals) {
  final routerDelegate = BeamerDelegate(
    initialPath: '/advanced/page-editor',
    locationBuilder: RoutesLocationBuilder(
      routes: {
        // Byte for byte what main.dart registers.
        '/advanced/page-editor': (context, state, args) => BeamPage(
              key: const ValueKey('/advanced/page-editor'),
              title: 'Page Editor',
              child: PageEditor(proposalData: args is String ? args : null),
            ),
      },
    ).call,
  );
  return ProviderScope(
    overrides: [
      pageManagerProvider.overrideWith((ref) async => manager),
      pageImageStoreProvider.overrideWith((ref) async {
        final prefs = manager.prefs;
        return prefs is FakeEditorPreferences
            ? imageStoreOf(prefs)
            : testImageStore();
      }),
      databaseProvider.overrideWith((ref) async => null),
      alarmManProvider
          .overrideWith((ref) => throw StateError('No AlarmMan in tests')),
      proposalStateProvider.overrideWith((ref) => proposals),
    ],
    child: BeamerProvider(
      routerDelegate: routerDelegate,
      child: MaterialApp.router(
        routerDelegate: routerDelegate,
        routeInformationParser: BeamerParser(),
        builder: (context, navigatorChild) => Stack(
          children: [navigatorChild!, const ProposalBanner()],
        ),
      ),
    ),
  );
}

/// How many assets the saved page map holds for [pageKey].
Future<int> _savedAssetCount(FakeEditorPreferences prefs, String pageKey) async {
  for (final value in (await prefs.getAll()).values) {
    if (value is! String) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      continue; // e.g. a base64 image blob
    }
    if (decoded is! Map<String, dynamic>) continue;
    final page = decoded[pageKey];
    if (page is Map<String, dynamic> && page['assets'] is List) {
      return (page['assets'] as List).length;
    }
  }
  return -1;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // Deliberately leaves "Boxes" out of the navigation registry: the only
    // place its label can appear is the editor's own page selector, which is
    // what makes find.text a reading of which page is open.
    setUpEditorEnvironment();
  });

  testWidgets(
      'View on a proposal for another page switches the editor to that page',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final prefs = FakeEditorPreferences();
    final proposals = ProposalStateNotifier();
    await tester.pumpWidget(_appUnderTest(_twoPageManager(prefs), proposals));
    await tester.pumpAndSettle();

    // The operator is in the editor, on Home.
    expect(find.text(_homeLabel), findsWidgets,
        reason: 'the editor opens on the first page');
    expect(find.text(_boxesLabel), findsNothing);

    // A proposal arrives for the other page. It stays pending rather than
    // being folded into the page on screen (#374), so the editor is still on
    // Home and the banner is up.
    proposals.addProposal(_pending(_assetProposalFor(_boxesKey)));
    await tester.pumpAndSettle();
    expect(find.text('View'), findsOneWidget,
        reason: 'the banner offers View for the single pending proposal');

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();

    // The whole point: the editor is now showing the proposal's page.
    expect(find.text(_boxesLabel), findsWidgets,
        reason: 'View must move the editor to the proposal page');
    // And the proposal staged onto that page rather than being left pending:
    // the operator was sent to look at something, so there has to be
    // something to look at. Saving is how the staged page becomes readable.
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    expect(await _savedAssetCount(prefs, _boxesKey), 2,
        reason: 'the proposed box must be staged onto Boxes');
    expect(await _savedAssetCount(prefs, '/'), 1,
        reason: 'and not onto the page the operator was standing on');
  });

  testWidgets('the switch keeps unsaved edits on the page being left',
      (tester) async {
    // Switching pages inside the editor is not leaving it: every page lives in
    // one in-memory map and a save writes all of them. So the switch is not
    // routed through the unsaved-changes guard -- and this pins that the
    // reason holds, rather than the guard merely having been forgotten.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final prefs = FakeEditorPreferences();
    final proposals = ProposalStateNotifier();
    await tester.pumpWidget(_appUnderTest(_twoPageManager(prefs), proposals));
    await tester.pumpAndSettle();

    // An unsaved edit on Home: nudge the box off its stored x.
    await tapAsset(tester, 0.2, 0.2);
    expect(selectedCount(tester), 1, reason: 'the box on Home is selected');
    await pressEditorKey(tester, LogicalKeyboardKey.arrowRight);

    proposals.addProposal(_pending(_assetProposalFor(_boxesKey)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text(_boxesLabel), findsWidgets);

    // No dialog stood in the way, and the edit is still there to save.
    expect(find.text('Unsaved changes'), findsNothing,
        reason: 'a page switch discards nothing, so it must not ask');
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    final home = readBackHomeAssets(prefs);
    expect(home, isNotNull);
    expect(coordsOf(home!.single)['x'], isNot(0.2),
        reason: 'the nudge on Home must survive the switch to Boxes');
  });
}
