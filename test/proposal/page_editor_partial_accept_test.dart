/// One row of a staged asset batch, accepted or rejected from the banner on
/// its own.
///
/// The page editor stages a batch by applying it to its working copy over
/// one pre-proposal snapshot, so a single proposal cannot be peeled out of
/// the patched pages. Its per-row commit goes back to the snapshot, stages
/// just that proposal, saves, and restages what is still pending -- the
/// same round trip its per-row reject has made since 2026-09-02.
///
/// Same rig as `page_editor_reject_unstage_test.dart`: the real editor
/// behind a real Beamer route, the real banner above it, and what a save
/// actually persists read back from preferences.
library;

import 'dart:async';
import 'dart:convert';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
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
import 'package:tfc/providers/web_view_prewarm.dart';
import 'package:tfc/widgets/proposal_banner.dart';
import 'package:tfc/widgets/proposal_visual.dart';

import '../helpers/page_editor_harness.dart'
    show
        FakeEditorPreferences,
        editorBox,
        imageStoreOf,
        setUpEditorEnvironment,
        testImageStore;

const double _operatorX = 0.2;

PageManager _oneBoxManager(FakeEditorPreferences prefs) => PageManager(
      prefs: prefs,
      pages: {
        '/': AssetPage(
          menuItem: const MenuItem(label: 'Home', path: '/', icon: Icons.home),
          assets: [editorBox(_operatorX, 0.2)],
          mirroringDisabled: true,
          navigationPriority: 0,
        ),
      },
    );

String _assetProposal(String title, double x) => jsonEncode({
      '_proposal_type': 'asset',
      '_op': 'create',
      'title': title,
      'page_key': '/',
      'children': [editorBox(x, 0.5).toJson()],
    });

PendingProposal _pending(int id, String title, double x) => PendingProposal(
      id: id,
      proposalType: 'asset',
      title: title,
      proposalJson: _assetProposal(title, x),
      operatorId: 'local',
      createdAt: DateTime(2026, 9, 13),
    );

Widget _appUnderTest(PageManager manager, ProposalStateNotifier proposals,
    StreamController<ProposalFeedback> feedback) {
  final routerDelegate = BeamerDelegate(
    initialPath: '/advanced/page-editor',
    locationBuilder: RoutesLocationBuilder(
      routes: {
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
      webViewPrewarmProvider.overrideWithValue(0),
      pageImageStoreProvider.overrideWith((ref) async {
        final prefs = manager.prefs;
        return prefs is FakeEditorPreferences
            ? imageStoreOf(prefs)
            : testImageStore();
      }),
      databaseProvider.overrideWith((ref) async => null),
      alarmManProvider
          .overrideWith((ref) => throw StateError('No AlarmMan in tests')),
      proposalFeedbackProvider.overrideWithValue(feedback),
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

/// The persisted x of every asset on the saved home page, or null when
/// nothing has been saved yet.
Future<List<double>?> _savedHomeXs(FakeEditorPreferences prefs) async {
  for (final value in (await prefs.getAll()).values) {
    if (value is! String) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    final page = decoded['/'];
    if (page is Map<String, dynamic> && page['assets'] is List) {
      return [
        for (final asset in page['assets'] as List)
          ((asset as Map<String, dynamic>)['coordinates']
              as Map<String, dynamic>)['x'] as double,
      ];
    }
  }
  return null;
}

Future<(FakeEditorPreferences, ProposalStateNotifier, ProviderContainer)>
    _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final prefs = FakeEditorPreferences();
  final feedback = StreamController<ProposalFeedback>.broadcast();
  addTearDown(feedback.close);
  final proposals = ProposalStateNotifier(feedback: feedback);
  await tester
      .pumpWidget(_appUnderTest(_oneBoxManager(prefs), proposals, feedback));
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
      tester.element(find.byType(ProposalBanner)),
      listen: false);
  return (prefs, proposals, container);
}

/// The banner's drawer row for [title].
Finder _rowOf(String title) => find
    .ancestor(of: find.text('Page Editor: $title'), matching: find.byType(Row))
    .first;

Future<void> _pressOnRow(
    WidgetTester tester, String title, String button) async {
  await tester
      .tap(find.descendant(of: _rowOf(title), matching: find.text(button)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    setUpEditorEnvironment();
  });

  testWidgets(
      'Accept on one row of a staged batch saves that asset and keeps the '
      'other staged', (tester) async {
    final (prefs, proposals, container) = await _pumpApp(tester);

    proposals.addProposal(_pending(1, 'sensor A', 0.6));
    proposals.addProposal(_pending(2, 'sensor B', 0.8));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsNWidgets(2),
        reason: 'both proposals stage as one batch');
    expect(container.read(proposalItemActionsProvider).keys,
        unorderedEquals([1, 2]),
        reason: 'each staged row is offered to the banner on its own');

    await tester.tap(find.textContaining('2 AI Proposals'));
    await tester.pumpAndSettle();
    await _pressOnRow(tester, 'sensor B', 'Accept');

    expect(await _savedHomeXs(prefs), [_operatorX, 0.8],
        reason: 'the accepted asset is saved, and only that one');
    expect(proposals.state.proposals.map((p) => p.id), [1],
        reason: 'the other is still pending');
    expect(find.byType(ProposalBadge), findsOneWidget,
        reason: 'and still staged for review');
    expect(container.read(proposalItemActionsProvider).keys, [1]);

    // Still acceptable: the survivor is the single-proposal banner now.
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(await _savedHomeXs(prefs), [_operatorX, 0.8, 0.6]);
    expect(proposals.state.hasPending, isFalse);
    expect(find.byType(ProposalBadge), findsNothing);
  });

  testWidgets(
      'Reject on one row of a staged batch un-stages it, and the other still '
      'saves', (tester) async {
    final (prefs, proposals, container) = await _pumpApp(tester);

    proposals.addProposal(_pending(1, 'sensor A', 0.6));
    proposals.addProposal(_pending(2, 'sensor B', 0.8));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('2 AI Proposals'));
    await tester.pumpAndSettle();
    await _pressOnRow(tester, 'sensor A', 'Reject');

    expect(proposals.state.proposals.map((p) => p.id), [2]);
    expect(find.byType(ProposalBadge), findsOneWidget,
        reason: 'the surviving row stays staged');
    expect(container.read(proposalItemActionsProvider).keys, [2]);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(await _savedHomeXs(prefs), [_operatorX, 0.8],
        reason: 'the rejected asset is gone, the accepted one saved');
    expect(proposals.state.hasPending, isFalse);
  });
}
