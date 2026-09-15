/// The per-proposal seam between an editor and the banner:
/// [proposalItemActionsProvider] and the two moves editors make on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/providers/proposal_state.dart';

ProposalItemActions _actions() => ProposalItemActions(
      commit: (_) async {},
      discard: (_) async {},
    );

void main() {
  late ProviderContainer container;
  late StateController<Map<int, ProposalItemActions>> slot;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    slot = container.read(proposalItemActionsProvider.notifier);
  });

  test('nothing is offered until an editor stages something', () {
    expect(container.read(proposalItemActionsProvider), isEmpty);
  });

  test('offer puts the same actions behind every id given', () {
    final mine = _actions();
    slot.offer([1, 2], mine);
    final offered = container.read(proposalItemActionsProvider);
    expect(offered.keys, unorderedEquals([1, 2]));
    expect(identical(offered[1], mine), isTrue);
    expect(identical(offered[2], mine), isTrue);
  });

  test('two editors on one page each keep their own rows', () {
    final keys = _actions();
    final templates = _actions();
    slot.offer([1, 2], keys);
    slot.offer([3], templates);

    // The key-mappings section drops one of its rows.
    slot.withdraw(keys, [1]);
    final offered = container.read(proposalItemActionsProvider);
    expect(offered.keys, unorderedEquals([2, 3]));
    expect(identical(offered[3], templates), isTrue,
        reason: 'the other section\'s row is untouched');
  });

  test('withdraw with no ids takes every row of that editor and no other',
      () {
    final keys = _actions();
    final templates = _actions();
    slot.offer([1, 2], keys);
    slot.offer([3], templates);

    slot.withdraw(keys);
    expect(container.read(proposalItemActionsProvider).keys, [3]);
  });

  test('withdraw only removes entries that hold the same actions', () {
    // An editor that was replaced by a sibling must not take the sibling's
    // row down with it -- the same "only if it is still ours" rule the batch
    // slots are cleared by.
    final old = _actions();
    final replacement = _actions();
    slot.offer([1], old);
    slot.offer([1], replacement);

    slot.withdraw(old, [1]);
    expect(identical(container.read(proposalItemActionsProvider)[1], replacement),
        isTrue);
  });

  test('a withdraw that changes nothing does not notify', () {
    var notifications = 0;
    container.listen(proposalItemActionsProvider, (_, __) => notifications++);
    slot.withdraw(_actions());
    slot.offer(const [], _actions());
    expect(notifications, 0);
  });
}
