import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/navigator_key.dart';
import '../providers/proposal_state.dart';

/// Persistent banner displayed at the top of the app when AI proposals are pending.
///
/// NEVER auto-dismisses -- stays visible until the operator explicitly accepts,
/// rejects, or dismisses every pending proposal.
///
/// Positioned in the main.dart builder Stack (same pattern as ChatOverlay).
class ProposalBanner extends ConsumerStatefulWidget {
  const ProposalBanner({super.key});

  @override
  ConsumerState<ProposalBanner> createState() => _ProposalBannerState();
}

class _ProposalBannerState extends ConsumerState<ProposalBanner> {
  bool _expanded = false;

  /// The proposal a press of Accept is still waiting to save, if any.
  ///
  /// Accept cannot write anything by itself -- applying a proposal belongs to
  /// the editor that owns the data -- so when no editor has staged it yet,
  /// Accept beams to that editor and remembers the id here. The listeners in
  /// [build] fire the commit the moment the editor publishes one, which is
  /// what makes a single press finish the job the button's label promises.
  int? _autoCommitId;

  @override
  Widget build(BuildContext context) {
    // Completes an Accept that had to open an editor first. See
    // [_autoCommitId]; registered before the early returns below so it stays
    // armed across the rebuild that empties the banner.
    //
    // The per-proposal seam is preferred: an editor that offers a commit for
    // exactly the armed id can be told to save exactly that one, whatever
    // else has arrived in the queue since the press. Editors offer it before
    // they publish the batch commit below, so this listener wins whenever it
    // can.
    ref.listen<Map<int, ProposalItemActions>>(proposalItemActionsProvider,
        (previous, offered) {
      final armed = _autoCommitId;
      if (armed == null) return;
      final item = offered[armed];
      if (item == null) return;
      _autoCommitId = null;
      // A microtask later, for the reason given on the batch listener.
      Future.microtask(() => item.commit(armed));
    });
    // The batch seam, for an editor that offers nothing per proposal.
    ref.listen<Future<void> Function()?>(proposalCommitProvider,
        (previous, commit) {
      final armed = _autoCommitId;
      if (armed == null || commit == null) return;
      _autoCommitId = null;
      // Only while the queue is still exactly the proposal that was accepted.
      // Such an editor stages every pending proposal of its type and commits
      // them as one save, so a proposal that arrived in the meantime would be
      // written by an Accept the operator never pressed on it.
      final pending = ref.read(proposalStateProvider).proposals;
      if (pending.length != 1 || pending.first.id != armed) return;
      // A microtask later, not now: an editor publishes its commit and
      // captures the ProviderContainer that commit reads from in one
      // post-frame callback, and publishing is what woke this listener --
      // so calling straight back into it lands before the container is set
      // and _commitProposals returns having written nothing.
      Future.microtask(commit);
    });

    final state = ref.watch(proposalStateProvider);
    // An armed Accept outlives its proposal only as a stale trigger: decided
    // elsewhere in the meantime, it must not fire on a later staging.
    if (_autoCommitId != null &&
        !state.proposals.any((p) => p.id == _autoCommitId)) {
      _autoCommitId = null;
    }
    if (!state.hasPending) return const SizedBox.shrink();

    // Stay visible on the editor page too. The in-editor bar is now purely
    // informational (title + the change list), so hiding here would leave the
    // operator on a page showing a staged edit with no way to accept it.
    final proposals = state.proposals;
    if (proposals.isEmpty) return const SizedBox.shrink();
    final count = proposals.length;

    return Positioned(
      key: const ValueKey('proposal-banner'),
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        elevation: 8,
        child: Container(
          color: Colors.grey.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SafeArea(
            bottom: false,
            child: count == 1
                ? _buildSingleProposal(proposals.first)
                : _buildMultipleProposals(proposals, count),
          ),
        ),
      ),
    );
  }

  Widget _buildSingleProposal(PendingProposal proposal) {
    return Row(
      children: [
        const Icon(Icons.auto_awesome, color: Colors.amber, size: 20),
        const SizedBox(width: 10),
        _ActionChip(proposal.action),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'AI Proposal: ${proposal.title}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        _buildViewButton(proposal),
        const SizedBox(width: 4),
        // The whole queue is this one proposal, so Accept can commit it.
        _buildAcceptButton(proposal, isWholeQueue: true),
        const SizedBox(width: 4),
        _buildRejectButton(proposal, isWholeQueue: true),
      ],
    );
  }

  Widget _buildMultipleProposals(
      List<PendingProposal> proposals, int count) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, color: Colors.amber, size: 20),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // The collapsed header is all most operators read before
              // pressing Accept all, so say up front what the batch does:
              // "3 create · 1 delete" reads very differently from "4".
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: '$count AI Proposals',
                    children: [
                      TextSpan(
                        text: '   ${_actionSummary(proposals)}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Accepting twenty-one bindings one row at a time is not review,
              // it is data entry -- the operator has already read the list.
              // Kept beside the count so it is reachable without expanding.
              _buildAcceptAllButton(proposals),
              const SizedBox(width: 4),
              _buildRejectAllButton(proposals),
              const SizedBox(width: 4),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                color: Colors.white70,
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const Divider(color: Colors.white24, height: 16),
          // Twenty-one rows would push the page off the bottom of the screen.
          // Cap the drawer and scroll inside it instead.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(
              shrinkWrap: true,
              children: proposals.map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const SizedBox(width: 30),
                  _ActionChip(p.action),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${p.editorLabel}: ${p.title}',
                      style: const TextStyle(color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _buildViewButton(p),
                  const SizedBox(width: 4),
                  // One row out of a batch. Accept saves this row and nothing
                  // else through the editor's per-proposal commit; Reject
                  // un-stages and drops this row and nothing else. The rest
                  // of the batch stays pending, and stays acceptable.
                  _buildAcceptButton(p, isWholeQueue: false),
                  const SizedBox(width: 4),
                  _buildRejectButton(p, isWholeQueue: false),
                ],
              ),
            ),
              ).toList(),
            ),
          ),
        ],
      ],
    );
  }

  /// Opens the editor with the whole queue still pending.
  ///
  /// Deliberately NOT acceptProposal() per item: that marks a proposal
  /// accepted in the database and drops it from state without ever applying
  /// the patch to the page, so the edit is silently lost. The apply happens
  /// in the editor, which consumes proposals while they are still pending and
  /// folds a run of asset_update into a single edit -- reviewed once, saved
  /// once, and marked accepted only once that save has persisted.
  Widget _buildAcceptAllButton(List<PendingProposal> proposals) {
    return TextButton.icon(
      onPressed: () {
        // Staged already? Commit it. The editor applied the batch and
        // published its save here; calling it applies and persists, and the
        // proposals are marked accepted as part of that save.
        final commit = ref.read(proposalCommitProvider);
        if (commit != null) {
          commit();
          return;
        }
        // Otherwise open the editor, which stages the whole pending queue
        // and publishes its commit -- then this button accepts.
        _openEditorTakes(proposals.first);
      },
      icon: const Icon(Icons.done_all, size: 16),
      label: Text(ref.watch(proposalCommitProvider) != null
          ? 'Accept all (${proposals.length})'
          : 'Review all (${proposals.length})'),
      style: TextButton.styleFrom(
        foregroundColor: Colors.greenAccent,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// Drops the whole queue, reverting the editor if it has staged it.
  ///
  /// Mirrors accept-all: once the editor has applied the batch, rejecting has
  /// to undo those edits as well as mark the rows rejected, or the operator is
  /// left with an unsaved page full of changes and no proposals explaining
  /// them. Without a staged batch there is nothing to revert, so plain
  /// rejectProposal per row is the whole job.
  Widget _buildRejectAllButton(List<PendingProposal> proposals) {
    return TextButton.icon(
      onPressed: () {
        final discard = ref.read(proposalDiscardProvider);
        if (discard != null) {
          discard();
          return;
        }
        final notifier = ref.read(proposalStateProvider.notifier);
        for (final p in proposals) {
          notifier.rejectProposal(p.id);
        }
      },
      icon: const Icon(Icons.close, size: 16),
      label: Text('Reject all (${proposals.length})'),
      style: TextButton.styleFrom(
        foregroundColor: Colors.redAccent,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// Accept for one proposal: apply it, then mark it accepted -- in that
  /// order, and both.
  ///
  /// Never a bare `acceptProposal()`. That marks the proposal decided and
  /// drops it from state without applying anything, which is the trap
  /// [_buildAcceptAllButton] has documented since the batch buttons were
  /// written; the single-proposal row and the drawer rows kept calling it
  /// anyway. Reported on 2026-08-31 against a `delete_alarm` proposal:
  /// pressing Accept on the single-proposal banner took the banner away and
  /// deleted nothing, and the operator had to scroll down in the alarm editor
  /// and press "Remove Alarm" -- the editor's own per-proposal control, and
  /// the only thing on screen that was actually removing the alarm.
  ///
  /// The work belongs to the editor that owns the data, so Accept either
  /// fires a commit that editor offered, or opens it and fires the commit as
  /// soon as one appears (see [_autoCommitId]).
  ///
  /// The commit it prefers is the per-proposal one on
  /// [proposalItemActionsProvider], which saves this proposal and nothing
  /// else -- so a row of a batch can be accepted on its own, leaving the rest
  /// pending. [isWholeQueue] only matters for an editor that offers nothing
  /// per proposal: its batch commit may be fired when this proposal is the
  /// whole queue (the single-proposal banner), and never for a row of a
  /// batch, where it would save the operator's other rows too.
  Widget _buildAcceptButton(PendingProposal proposal,
      {required bool isWholeQueue}) {
    return TextButton(
      onPressed: () => _accept(proposal, isWholeQueue: isWholeQueue),
      style: TextButton.styleFrom(
        foregroundColor: Colors.green,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('Accept'),
    );
  }

  void _accept(PendingProposal proposal, {required bool isWholeQueue}) {
    final item = ref.read(proposalItemActionsProvider)[proposal.id];
    if (item != null) {
      item.commit(proposal.id);
      return;
    }
    if (isWholeQueue) {
      final commit = ref.read(proposalCommitProvider);
      if (commit != null) {
        commit();
        return;
      }
    }
    // Nothing staged: the editor has to see the proposal before it can save
    // it. Arm the commit so the operator's one press still finishes, rather
    // than leaving them to press again.
    _autoCommitId = proposal.id;
    if (!_openEditorTakes(proposal)) _autoCommitId = null;
  }

  /// Reject for one proposal: revert the staged edit, then mark it rejected
  /// -- the same two halves as Accept, and in the same order.
  ///
  /// Never a bare `rejectProposal()` while an editor has the proposal staged.
  /// That only does the second half: the banner went away and the staged
  /// assets stayed on the page, where the operator's next save wrote them
  /// exactly as an accept would have. Reported on 2026-09-02 against a
  /// `propose_asset` batch: a rejected 35-asset cabinet-layout proposal
  /// persisted to its page. The per-proposal discard on
  /// [proposalItemActionsProvider] does both halves for exactly this row;
  /// the editor's batch discard does them for the whole queue, and is only
  /// fired when this proposal is the whole queue. With nothing staged there
  /// is nothing to revert, so the plain reject is the whole job.
  Widget _buildRejectButton(PendingProposal proposal,
      {required bool isWholeQueue}) {
    return TextButton(
      onPressed: () => _reject(proposal, isWholeQueue: isWholeQueue),
      style: TextButton.styleFrom(
        foregroundColor: Colors.red,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('Reject'),
    );
  }

  void _reject(PendingProposal proposal, {required bool isWholeQueue}) {
    final item = ref.read(proposalItemActionsProvider)[proposal.id];
    if (item != null) {
      item.discard(proposal.id);
      return;
    }
    if (isWholeQueue) {
      final discard = ref.read(proposalDiscardProvider);
      if (discard != null) {
        discard();
        return;
      }
    }
    ref.read(proposalStateProvider.notifier).rejectProposal(proposal.id);
  }

  Widget _buildViewButton(PendingProposal proposal) {
    return TextButton(
      onPressed: () {
        // Looking is not deciding, but the AI is told the proposal was opened.
        ref.read(proposalStateProvider.notifier).viewProposal(proposal.id);
        _openEditorTakes(proposal);
      },
      style: TextButton.styleFrom(
        foregroundColor: Colors.blue,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('View'),
    );
  }

  /// Gets [proposal] in front of the editor that owns it, and says whether it
  /// got there.
  ///
  /// Two ways in, because there are two situations. When that editor is
  /// already the screen the operator is standing on, it is handed the
  /// proposal directly: beaming to the route you are already on rebuilds the
  /// route's *builder* and not the page it built, so the mounted editor never
  /// hears about the proposal. That is exactly the case the operator hit --
  /// page editor open on one page, View on a proposal for another, and the
  /// editor stayed where it was. The mounted editor publishes
  /// [proposalReviewProvider] for this; see [ProposalReviewEntry]. From
  /// anywhere else in the app, beaming is what opens the editor.
  ///
  /// The route check matters: a page editor being on screen must not make it
  /// the destination for an alarm proposal.
  ///
  /// Returns false when there is nowhere to go -- an unknown proposal type
  /// has no route, and Beamer is absent in tests -- so a caller waiting on
  /// the editor to publish its commit knows the editor is never coming.
  bool _openEditorTakes(PendingProposal proposal) {
    final route = proposal.editorRoute;
    if (route == null) return false;
    final entry = ref.read(proposalReviewProvider);
    if (entry != null && entry.route == route) {
      entry.enter(proposal.proposalJson);
      return true;
    }
    try {
      final navKey = ref.read(navigatorKeyProvider);
      final ctx = navKey?.currentContext ?? context;
      Beamer.of(ctx).beamToNamed(route, data: proposal.proposalJson);
      return true;
    } catch (_) {
      // Beamer not available -- ignore
      return false;
    }
  }

  /// "2 create · 1 edit · 1 delete", listing only the actions present.
  String _actionSummary(List<PendingProposal> proposals) {
    final counts = <ProposalOp, int>{};
    for (final p in proposals) {
      counts[p.action] = (counts[p.action] ?? 0) + 1;
    }
    return [
      if (counts.containsKey(ProposalOp.create))
        '${counts[ProposalOp.create]} create',
      if (counts.containsKey(ProposalOp.update))
        '${counts[ProposalOp.update]} edit',
      if (counts.containsKey(ProposalOp.delete))
        '${counts[ProposalOp.delete]} delete',
    ].join(' · ');
  }
}

/// Small labelled tag saying what accepting the proposal does: CREATE,
/// EDIT, or DELETE.
///
/// A title like "conveyor.speed" reads identically whether the AI wants to
/// add the mapping or remove it; the operator should not have to open the
/// editor to find out which. Delete gets the same red as Reject on purpose:
/// it is the row where accepting destroys something.
class _ActionChip extends StatelessWidget {
  const _ActionChip(this.action);

  final ProposalOp action;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (action) {
      ProposalOp.create => ('CREATE', Icons.add, Colors.greenAccent),
      ProposalOp.update => ('EDIT', Icons.edit, Colors.lightBlueAccent),
      ProposalOp.delete =>
        ('DELETE', Icons.delete_outline, Colors.redAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        border: Border.all(color: color.withAlpha(140)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
