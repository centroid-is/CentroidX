/// Rejecting an asset proposal has to take the proposed assets off the page.
///
/// Reported from the plant on 2026-09-02: an MCP `propose_asset` staged a
/// 35-asset "ST101 cabinet layout" proposal onto `/+ST101`, the operator
/// pressed the banner's Reject -- the feedback stream duly recorded
/// "Rejected the asset proposal 'ST101 cabinet layout'" -- and moments later
/// the live `page_editor_data` config held all 35 proposed assets anyway.
/// The operator's words: "reject does not remove the proposal from the page
/// editor."
///
/// The seam: the banner's per-row Reject (and the chat batch card's
/// Reject All) only dropped the proposal from [proposalStateProvider]. The
/// editor had already folded the proposed assets into its working copy, so
/// they stayed on the canvas with the editor still marked unsaved, and the
/// operator's next save wrote them exactly as an accept would have. The same
/// hole explains an earlier "accepted duplicates" incident: a rejected copy
/// lingered staged, the proposal was re-made and accepted, and both copies
/// were saved.
///
/// These tests drive the real editor behind a real Beamer route with the
/// real banner stacked above it, exactly as `main.dart` assembles them, and
/// then read what a save actually persists.
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
import 'package:tfc/widgets/proposal_banner.dart';
import 'package:tfc/widgets/proposal_visual.dart';

import '../helpers/page_editor_harness.dart'
    show
        FakeEditorPreferences,
        editorBox,
        imageStoreOf,
        setUpEditorEnvironment,
        testImageStore;

/// The one asset the operator drew themselves, at x=0.2. Everything a
/// proposal adds lands elsewhere, so persisted x-coordinates say exactly
/// which assets survived.
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

/// An `asset` proposal adding one box to the home page at [x] -- the shape
/// `propose_asset` delivers.
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
      createdAt: DateTime(2026, 9, 2),
    );

/// The app, as `main.dart` assembles it: the editor behind a real Beamer
/// route, with the banner stacked above the Navigator, and the notifier
/// wired to the feedback stream the way `proposalStateProvider` builds it --
/// the editor un-stages off that stream, so a bare notifier would hide the
/// very seam under test.
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
      continue; // e.g. a base64 image blob
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

Future<(FakeEditorPreferences, ProposalStateNotifier)> _pumpApp(
    WidgetTester tester) async {
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
  return (prefs, proposals);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    setUpEditorEnvironment();
  });

  testWidgets(
      'Reject on the single-proposal banner un-stages the proposed assets, '
      'and a later save persists none of them', (tester) async {
    final (prefs, proposals) = await _pumpApp(tester);

    // The proposal arrives and the open editor stages it.
    proposals.addProposal(_pending(1, 'ST101 cabinet layout', 0.6));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsOneWidget,
        reason: 'the editor stages the proposal for review');

    // The operator says no.
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    expect(proposals.state.hasPending, isFalse,
        reason: 'the proposal was decided');
    expect(find.byType(ProposalBadge), findsNothing,
        reason: 'a rejected proposal must not stay staged');

    // The bug: the rejected assets were still in the working copy, so the
    // operator's next save wrote them as if accepted.
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    expect(await _savedHomeXs(prefs), [_operatorX],
        reason: 'a save after reject must persist none of the rejected '
            'assets');
  });

  testWidgets(
      'a reject that goes straight to state (chat card Reject All) '
      'un-stages the editor copy too', (tester) async {
    final (prefs, proposals) = await _pumpApp(tester);

    proposals.addProposal(_pending(1, 'ST101 cabinet layout', 0.6));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsOneWidget);

    // The chat batch card path: no banner button, no editor callback --
    // just the state notifier.
    await proposals.rejectAllOfType('asset');
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsNothing);

    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    expect(await _savedHomeXs(prefs), [_operatorX]);
  });

  testWidgets('dismissing works like rejecting: nothing staged survives',
      (tester) async {
    final (prefs, proposals) = await _pumpApp(tester);

    proposals.addProposal(_pending(1, 'ST101 cabinet layout', 0.6));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsOneWidget);

    await proposals.dismissProposal(1);
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsNothing);

    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    expect(await _savedHomeXs(prefs), [_operatorX]);
  });

  testWidgets('rejecting one row of a staged batch keeps the other staged',
      (tester) async {
    final (prefs, proposals) = await _pumpApp(tester);

    proposals.addProposal(_pending(1, 'sensor A', 0.6));
    proposals.addProposal(_pending(2, 'sensor B', 0.8));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsNWidgets(2),
        reason: 'both proposals stage as one batch');

    // The drawer's per-row Reject: only the state notifier hears about it.
    await proposals.rejectProposal(1);
    await tester.pumpAndSettle();
    expect(find.byType(ProposalBadge), findsOneWidget,
        reason: 'the surviving row must stay staged for review');

    // Accepting the survivor persists it -- and not the rejected sibling.
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    expect(await _savedHomeXs(prefs), [_operatorX, 0.8],
        reason: 'the rejected asset must be gone, the surviving one kept');
    expect(proposals.state.hasPending, isFalse,
        reason: 'the save accepts the surviving proposal');
  });

  testWidgets('Accept still persists the proposal exactly once',
      (tester) async {
    final (prefs, proposals) = await _pumpApp(tester);

    proposals.addProposal(_pending(1, 'ST101 cabinet layout', 0.6));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(await _savedHomeXs(prefs), [_operatorX, 0.6],
        reason: 'accepted assets are saved once -- no duplicates');
    expect(proposals.state.hasPending, isFalse);
  });
}
