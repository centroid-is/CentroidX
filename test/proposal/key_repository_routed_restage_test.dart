/// The staged-proposal strip must not come back once the batch is resolved.
///
/// "I accepted but the yellow box is still on top in key repository." The
/// mapping was written; the amber strip above the key list was still claiming
/// a proposal was pending, over a mapping that had already been saved.
///
/// [_KeyMappingsSection] stages proposals two ways: from `proposalStateProvider`
/// (each carrying an id) and from the JSON the route hands it, which carries
/// none — the chat batch card calls `acceptAllOfType()` first, so the
/// proposals are already out of state by the time it beams here. The second
/// path is a fallback, taken whenever state holds nothing.
///
/// Beamer keeps that JSON on the location, so every later mount of the
/// section is handed it again — and after an accept, state *is* empty, which
/// is exactly what the fallback triggers on. So mounting the section again
/// staged the accepted proposal a second time. These tests mount it again by
/// leaving the page and coming back, which is what the operator did; a plain
/// window resize does it too, without any navigation at all, because
/// [KeyRepositoryContent] swaps LayoutBuilder branches at 320 px and the
/// section lands in a different place in the tree.
///
/// Sibling of `alarm_editor_routed_accept_test.dart` (#358), which pinned the
/// other half of the same invariant: the batch leaves when it is accepted.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/proposal_visual.dart';

import '../helpers/test_helpers.dart';

const _id = 101;
const _key = 'PROPOSED.KEY.ONE';

/// The amber strip above the key list — one badge per staged mapping, and the
/// visible "a proposal is pending" marker the operator was complaining about.
Finder get stagedStrip => find.byType(ProposalBadge);

PendingProposal _proposal(int id, String key) => PendingProposal(
      id: id,
      proposalType: 'key_mapping',
      title: 'map $key',
      proposalJson: jsonEncode({
        '_proposal_type': 'key_mapping',
        'key': key,
        'opcua_node': OpcUANodeConfig(namespace: 2, identifier: key).toJson(),
      }),
      operatorId: 'ai',
      createdAt: DateTime(2026, 8, 31),
    );

/// The page, its container, and every [Preferences] the provider has built.
class _Rig {
  _Rig(this.tester, this.container, this.proposals, this.prefs, this.store,
      this.routed);

  final WidgetTester tester;
  final ProviderContainer container;
  final ProposalStateNotifier proposals;
  final List<Preferences> prefs;
  final GuardedConfigStore store;
  final String? routed;

  Future<void> Function()? get commit => container.read(proposalCommitProvider);
  Future<void> Function()? get discard =>
      container.read(proposalDiscardProvider);

  /// Pumps the page, with the route payload still attached.
  Future<void> pumpPage() async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: KeyRepositoryContent(proposalData: routed)),
      ),
    ));
    await settle(tester);
  }

  /// Leaves the page and comes back to it.
  ///
  /// The section's State is disposed and a new one is built, and beamer hands
  /// the new one the same [routed] payload — the location keeps it, so the
  /// address the operator returns to still carries the proposal that opened
  /// the editor.
  Future<void> leaveAndReturn() async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    ));
    await tester.pump();
    await pumpPage();
  }

  /// The mappings as stored — `config_item` rows since plan 02-06.
  Iterable<String> get savedKeys => store.inner.keyMappings.nodes.keys;
}

/// Pumps the key repository with the proposal pending in state *and* its JSON
/// on the route — what the banner's View button produces.
Future<_Rig> _pump(
  WidgetTester tester, {
  required bool pending,
  required bool routed,
}) async {
  final proposal = _proposal(_id, _key);
  final proposals = ProposalStateNotifier();
  if (pending) proposals.addProposal(proposal);

  final built = <Preferences>[];
  final store = await createTestConfigStore(session: kConfiguringTestSession);
  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) async {
      final prefs = await createTestPreferences(
        keyMappings: KeyMappings(nodes: {}),
        stateManConfig: StateManConfig(opcua: []),
      );
      built.add(prefs);
      return prefs;
    }),
    configStoreProvider.overrideWith((ref) async => store),
    databaseProvider.overrideWith((ref) async => null),
    stateManProvider
        .overrideWith((ref) => throw StateError('No StateMan in tests')),
    proposalStateProvider.overrideWith((ref) => proposals),
  ]);
  addTearDown(container.dispose);

  final rig = _Rig(tester, container, proposals, built, store,
      routed ? proposal.proposalJson : null);
  await rig.pumpPage();
  return rig;
}

void main() {
  testWidgets('the strip stays down when the section is rebuilt after an '
      'accept', (tester) async {
    final rig = await _pump(tester, pending: true, routed: true);
    expect(stagedStrip, findsOneWidget,
        reason: 'the proposal is pending, so the page stages it');

    await rig.commit!();
    await tester.pumpAndSettle();

    expect(await rig.savedKeys, contains(_key),
        reason: 'the accept writes the mapping');
    expect(stagedStrip, findsNothing,
        reason: 'nothing is staged the moment the batch is accepted');
    expect(rig.proposals.state.hasPending, isFalse);

    // The operator leaves the key repository and comes back. No new
    // proposal; the same address, still carrying the JSON that opened it.
    await rig.leaveAndReturn();

    expect(stagedStrip, findsNothing,
        reason: 'a strip back up over an already-saved mapping tells the '
            'operator a proposal is still pending when nothing is: the '
            'banner is gone with the state, so nothing on screen can take '
            'it down again');
    expect(await rig.savedKeys, contains(_key),
        reason: 'and the mapping it was announcing is still saved');
  });

  testWidgets('the strip stays down when the section is rebuilt after a '
      'reject', (tester) async {
    final rig = await _pump(tester, pending: true, routed: true);
    expect(stagedStrip, findsOneWidget);

    await rig.discard!();
    await tester.pumpAndSettle();
    expect(stagedStrip, findsNothing);

    await rig.leaveAndReturn();

    expect(stagedStrip, findsNothing,
        reason: 'a rejected proposal must not come back either');
    expect(await rig.savedKeys, isNot(contains(_key)),
        reason: 'reject must not touch the mappings');
  });

  // The guard must not swallow the path the fallback exists for: the chat
  // batch card empties proposalStateProvider before it beams, so a payload
  // that has never been resolved is the only copy of a batch still waiting to
  // be applied.
  testWidgets('an unresolved route payload still stages with state empty',
      (tester) async {
    final rig = await _pump(tester, pending: false, routed: true);

    expect(stagedStrip, findsOneWidget,
        reason: 'nothing is pending, so the route payload is the batch');
    expect(rig.commit, isNotNull,
        reason: 'and the banner must be able to accept it');

    await rig.commit!();
    await tester.pumpAndSettle();

    expect(await rig.savedKeys, contains(_key));
    expect(stagedStrip, findsNothing);
  });
}
