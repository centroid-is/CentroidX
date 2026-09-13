/// Pending proposals across an engine restart.
///
/// The Windows runner rebuilds the Flutter engine to recover a lost render
/// context, and a rebuild is a fresh Dart isolate: until the queue was
/// mirrored to the device-local store, every undecided proposal died with
/// the old isolate and the operator was told there was nothing pending. A
/// "restart" here is a second [ProposalStateNotifier] built over the same
/// preferences store, which is exactly what the next isolate does.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/pending_proposals_store.dart';
import 'package:tfc/providers/preferences.dart' show localPreferencesProvider;
import 'package:tfc/providers/proposal_state.dart';

void main() {
  PendingProposal proposal({
    required int id,
    String type = 'alarm',
    String title = 'High temp',
    String? json,
    String operator = 'local',
    DateTime? createdAt,
  }) =>
      PendingProposal(
        id: id,
        proposalType: type,
        title: title,
        proposalJson: json ?? '{"_proposal_type":"$type","title":"$title"}',
        operatorId: operator,
        createdAt: createdAt ?? clock.now(),
      );

  /// A notifier over [prefs], with its restore settled.
  Future<ProposalStateNotifier> boot(
    PreferencesApi prefs, {
    StreamController<ProposalFeedback>? feedback,
  }) async {
    final notifier = ProposalStateNotifier(
      feedback: feedback,
      store: PendingProposalStore(prefs),
    );
    addTearDown(notifier.dispose);
    await pumpEventQueue();
    return notifier;
  }

  test('pending proposals survive a restart, with fresh ids', () async {
    final prefs = InMemoryPreferences();

    final first = await boot(prefs);
    first.addProposal(proposal(id: -1, title: 'High temp'));
    first.addProposal(proposal(id: -2, type: 'page', title: 'Packing hall'));
    await pumpEventQueue();

    final second = await boot(prefs);
    final titles = second.state.proposals.map((p) => p.title).toList();
    expect(titles, ['High temp', 'Packing hall']);
    // Ids are process-local handles and are minted again on restore. They
    // must still be distinct from each other and from anything the new
    // isolate hands out next.
    final ids = second.state.proposals.map((p) => p.id).toSet();
    expect(ids, hasLength(2));
    second.addProposal(proposal(id: nextLocalProposalId(), title: 'Third'));
    expect(second.state.proposals.map((p) => p.id).toSet(), hasLength(3));
  });

  test('a decision made before the restart is not resurrected', () async {
    final prefs = InMemoryPreferences();

    final first = await boot(prefs);
    first.addProposal(proposal(id: -1, title: 'Accepted one'));
    first.addProposal(proposal(id: -2, title: 'Rejected one'));
    first.addProposal(proposal(id: -3, title: 'Still open'));
    await first.acceptProposal(-1);
    await first.rejectProposal(-2);
    await pumpEventQueue();

    final second = await boot(prefs);
    expect(second.state.proposals.map((p) => p.title), ['Still open']);
  });

  test('bulk decisions and dismissals are persisted too', () async {
    final prefs = InMemoryPreferences();

    final first = await boot(prefs);
    first.addProposal(proposal(id: -1, type: 'alarm', title: 'A'));
    first.addProposal(proposal(id: -2, type: 'alarm', title: 'B'));
    first.addProposal(proposal(id: -3, type: 'page', title: 'P'));
    await first.acceptAllOfType('alarm');
    await first.dismissProposal(-3);
    await pumpEventQueue();

    final second = await boot(prefs);
    expect(second.state.proposals, isEmpty);
    expect(await prefs.containsKey(pendingProposalsPrefsKey), isFalse);
  });

  test('a proposal already reported as viewed is not reported again',
      () async {
    final prefs = InMemoryPreferences();
    final firstFeedback = StreamController<ProposalFeedback>.broadcast();
    addTearDown(firstFeedback.close);

    final first = await boot(prefs, feedback: firstFeedback);
    first.addProposal(proposal(id: -1, title: 'Looked at'));
    first.addProposal(proposal(id: -2, title: 'Not yet'));
    await first.viewProposal(-1);
    await pumpEventQueue();

    final secondFeedback = StreamController<ProposalFeedback>.broadcast();
    addTearDown(secondFeedback.close);
    final actions = <String>[];
    secondFeedback.stream.listen(
        (f) => actions.add('${f.action}:${f.proposals.single.title}'));

    final second = await boot(prefs, feedback: secondFeedback);
    final looked =
        second.state.proposals.firstWhere((p) => p.title == 'Looked at');
    final notYet =
        second.state.proposals.firstWhere((p) => p.title == 'Not yet');
    await second.viewProposal(looked.id);
    await second.viewProposal(notYet.id);
    await pumpEventQueue();

    expect(actions, ['viewed:Not yet']);
  });

  test('a corrupt persisted blob is ignored, not fatal', () async {
    final prefs = InMemoryPreferences();
    await prefs.setString(pendingProposalsPrefsKey, '{"v":1,"proposals":[oops');

    final notifier = await boot(prefs);
    expect(notifier.state.proposals, isEmpty);

    // The queue keeps working, and the next change replaces the bad blob.
    notifier.addProposal(proposal(id: -1, title: 'After the corruption'));
    await pumpEventQueue();
    final decoded =
        decodePendingProposals(await prefs.getString(pendingProposalsPrefsKey));
    expect(decoded.single.title, 'After the corruption');
  });

  test('a store that cannot be reached leaves the queue working', () async {
    final notifier = ProposalStateNotifier(
      store: PendingProposalStore(_BrokenPreferences()),
    );
    addTearDown(notifier.dispose);
    await pumpEventQueue();

    notifier.addProposal(proposal(id: -1));
    await pumpEventQueue();
    expect(notifier.state.pendingCount, 1);
    await notifier.acceptProposal(-1);
    await pumpEventQueue();
    expect(notifier.state.pendingCount, 0);
  });

  test('a proposal that arrives before the restore is kept, and deduplicated',
      () async {
    final prefs = InMemoryPreferences();
    final first = await boot(prefs);
    first.addProposal(proposal(id: -1, title: 'Old'));
    first.addProposal(proposal(id: -2, title: 'Re-proposed'));
    await pumpEventQueue();

    // The next isolate's store answers asynchronously; a client that noticed
    // the banner go blank may already have proposed the same thing again by
    // then, with byte-identical JSON.
    final second = ProposalStateNotifier(store: PendingProposalStore(prefs));
    addTearDown(second.dispose);
    second.addProposal(proposal(id: -10, title: 'Re-proposed'));
    second.addProposal(proposal(id: -11, title: 'Brand new'));
    await pumpEventQueue();

    expect(second.state.proposals.map((p) => p.title),
        ['Old', 'Re-proposed', 'Brand new']);
  });

  test('proposals older than the expiry are not restored', () async {
    final prefs = InMemoryPreferences();
    final first = await boot(prefs);
    first.addProposal(proposal(
      id: -1,
      title: 'Yesterday',
      createdAt: clock.now().subtract(pendingProposalMaxAge * 2),
    ));
    first.addProposal(proposal(id: -2, title: 'Today'));
    await pumpEventQueue();

    final second = await boot(prefs);
    expect(second.state.proposals.map((p) => p.title), ['Today']);
  });

  test('the provider restores through the device-local preferences', () async {
    final prefs = InMemoryPreferences();
    await PendingProposalStore(prefs)
        .save([_persisted(title: 'From the last generation')]);

    final container = ProviderContainer(overrides: [
      localPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    container.read(proposalStateProvider);
    await pumpEventQueue();
    expect(
      container.read(proposalStateProvider).proposals.map((p) => p.title),
      ['From the last generation'],
    );
  });

  test('the provider still builds when no preferences store exists',
      () async {
    // Every widget test that does not stub shared_preferences: the store
    // provider absorbs the failure and the queue runs unpersisted.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(pendingProposalStoreProvider), isNull);
    container.read(proposalStateProvider.notifier).addProposal(proposal(id: -1));
    expect(container.read(proposalStateProvider).pendingCount, 1);
  });
}

PersistedProposal _persisted({required String title}) => PersistedProposal(
      proposalType: 'alarm',
      title: title,
      proposalJson: '{"_proposal_type":"alarm","title":"$title"}',
      operatorId: 'local',
      createdAt: clock.now(),
    );

class _BrokenPreferences extends InMemoryPreferences {
  @override
  Future<String?> getString(String key) async => throw StateError('broken');

  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('broken');

  @override
  Future<void> remove(String key) async => throw StateError('broken');
}
