/// One row of a staged key-mapping batch, accepted or rejected on its own.
///
/// The key repository stages every pending `key_mapping` proposal as one
/// batch and used to offer the banner one commit for the lot. Since
/// 2026-09-13 it also offers a commit and a discard per proposal id on
/// [proposalItemActionsProvider], so the banner's row buttons can take one
/// mapping and leave the rest staged -- and it reconciles the batch against
/// the queue, so a row rejected on any surface is never written by a later
/// Accept all.
///
/// The rig is the one `key_repository_proposal_test.dart` uses: a real
/// configuration store over an in-memory database, and every claim read
/// back from it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/providers/state_man.dart';

import '../helpers/test_helpers.dart';

const _idOne = 101;
const _idTwo = 102;
const _idThree = 103;
const _keyOne = 'line1.conveyor_a.speed';
const _keyTwo = 'line1.conveyor_b.speed';
const _keyThree = 'line1.conveyor_c.speed';

class _RecordingProposals extends ProposalStateNotifier {
  final List<int> accepted = [];
  final List<int> rejected = [];

  @override
  Future<void> acceptProposal(int id) async {
    accepted.add(id);
    await super.acceptProposal(id);
  }

  @override
  Future<void> rejectProposal(int id) async {
    rejected.add(id);
    await super.rejectProposal(id);
  }
}

class _Staged {
  _Staged(this.container, this.proposals, this.store);

  final ProviderContainer container;
  final _RecordingProposals proposals;
  final GuardedConfigStore store;

  Future<void> Function()? get commit =>
      container.read(proposalCommitProvider);
  Future<void> Function()? get discard =>
      container.read(proposalDiscardProvider);
  Map<int, ProposalItemActions> get items =>
      container.read(proposalItemActionsProvider);

  Iterable<String> get savedKeys => store.inner.keyMappings.nodes.keys;
  List<int> get pendingIds =>
      container.read(proposalStateProvider).proposals.map((p) => p.id).toList();
}

PendingProposal _proposal(int id, String key) => PendingProposal(
      id: id,
      proposalType: 'key_mapping',
      title: 'map $key',
      proposalJson: jsonEncode({
        '_proposal_type': 'key_mapping',
        'key': key,
        'opcua_node':
            OpcUANodeConfig(namespace: 2, identifier: key).toJson(),
      }),
      operatorId: 'ai',
      createdAt: DateTime(2026, 9, 13),
    );

Future<_Staged> _stageBatch(WidgetTester tester) async {
  final proposals = _RecordingProposals();
  proposals.addProposal(_proposal(_idOne, _keyOne));
  proposals.addProposal(_proposal(_idTwo, _keyTwo));
  proposals.addProposal(_proposal(_idThree, _keyThree));

  final store = await createTestConfigStore(session: kConfiguringTestSession);
  final container = ProviderContainer(overrides: [
    preferencesProvider.overrideWith((ref) async =>
        createTestPreferences(keyMappings: KeyMappings(nodes: {}))),
    configStoreProvider.overrideWith((ref) async => store),
    databaseProvider.overrideWith((ref) async => null),
    stateManProvider
        .overrideWith((ref) => throw StateError('No StateMan in tests')),
    proposalStateProvider.overrideWith((ref) => proposals),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: Scaffold(body: KeyRepositoryContent())),
  ));
  await settle(tester);

  return _Staged(container, proposals, store);
}

void main() {
  testWidgets('each staged row is offered to the banner on its own',
      (tester) async {
    final staged = await _stageBatch(tester);

    expect(staged.items.keys, unorderedEquals([_idOne, _idTwo, _idThree]));
    expect(staged.commit, isNotNull,
        reason: 'the batch commit is still there for Accept all');
  });

  testWidgets(
      'accepting one row saves that mapping, marks it, and leaves the other '
      'two staged and acceptable', (tester) async {
    final staged = await _stageBatch(tester);

    await staged.items[_idTwo]!.commit(_idTwo);
    await tester.pump();

    expect(staged.savedKeys, [_keyTwo],
        reason: 'exactly the accepted mapping reaches the store');
    expect(staged.proposals.accepted, [_idTwo]);
    expect(staged.pendingIds, [_idOne, _idThree],
        reason: 'the others are neither dropped nor accepted');
    expect(staged.items.keys, unorderedEquals([_idOne, _idThree]),
        reason: 'and still staged, one row each');
    expect(staged.commit, isNotNull);

    // Still acceptable afterwards, as a batch.
    await staged.commit!();
    await tester.pump();
    expect(staged.savedKeys, containsAll([_keyOne, _keyTwo, _keyThree]));
    expect(staged.proposals.accepted, [_idTwo, _idOne, _idThree]);
    expect(staged.pendingIds, isEmpty);
    expect(staged.items, isEmpty);
    expect(staged.commit, isNull, reason: 'nothing left to accept');
  });

  testWidgets('rejecting one row drops that mapping and leaves the rest',
      (tester) async {
    final staged = await _stageBatch(tester);

    await staged.items[_idOne]!.discard(_idOne);
    await tester.pump();

    expect(staged.proposals.rejected, [_idOne]);
    expect(staged.savedKeys, isEmpty, reason: 'a reject writes nothing');
    expect(staged.pendingIds, [_idTwo, _idThree]);
    expect(staged.items.keys, unorderedEquals([_idTwo, _idThree]));

    await staged.commit!();
    await tester.pump();
    expect(staged.savedKeys, unorderedEquals([_keyTwo, _keyThree]),
        reason: 'the rejected mapping was never written');
    expect(staged.proposals.accepted, [_idTwo, _idThree]);
  });

  testWidgets('a row rejected straight from the queue is un-staged too',
      (tester) async {
    // The chat batch card, the banner's row Reject before this section was
    // offered it, an MCP-side dismiss: none of them ask this section. It
    // reconciles against the queue instead. Before it did, the rejected
    // mapping stayed staged and the next Accept all wrote it.
    final staged = await _stageBatch(tester);

    await staged.proposals.rejectProposal(_idOne);
    await staged.proposals.dismissProposal(_idThree);
    await tester.pump();
    expect(staged.items.keys, [_idTwo]);
    expect(find.text(_keyOne), findsNothing,
        reason: 'the amber row for the rejected mapping is gone');

    await staged.commit!();
    await tester.pump();
    expect(staged.savedKeys, [_keyTwo]);
    expect(staged.proposals.accepted, [_idTwo]);
    expect(staged.commit, isNull);
  });

  testWidgets('a proposal that arrives during a row accept is left pending',
      (tester) async {
    // The listener stages arrivals into the batch under the commit's awaits.
    // Nothing about the per-row commit may swallow them: they are neither
    // written nor dropped, and they are offered afterwards.
    final staged = await _stageBatch(tester);

    final commit = staged.items[_idOne]!.commit(_idOne);
    staged.proposals.addProposal(_proposal(104, 'line1.conveyor_d.speed'));
    await commit;
    await tester.pump();

    expect(staged.savedKeys, [_keyOne]);
    expect(staged.pendingIds, [_idTwo, _idThree, 104]);
    expect(staged.items.keys, unorderedEquals([_idTwo, _idThree, 104]));
  });
}
