/// The two dialogs undo needs: what will be written back, and why it will not
/// be.
///
/// ## The confirmation names the *write*, not the change
///
/// An operator about to undo something is not asking "what did I do" — the row
/// they tapped already says that. They are asking "what is about to happen to
/// the plant". So every line here is phrased as the write, and never as
/// `you changed CN04`. The two readings differ most in exactly the case that
/// matters — undoing an *insert* deletes a row, and an operator who read the
/// dialog as a description of the original edit would not expect that.
///
/// ## One verb per operation, and the operation is what varies
///
/// Three inverses, three verbs, chosen so that the **state of the row right
/// now** is legible from the word alone:
///
/// | Verb | The row now | What the undo writes |
/// |---|---|---|
/// | `Re-create` | is gone | an insert of the old entity |
/// | `Revert` | is there, holding something else | an overwrite with the old entity |
/// | `Delete` | is there, and this action put it there | a removal |
///
/// An earlier draft said `Restore …` and `Put … back as it was`, which are two
/// phrasings of one idea: a reader could not tell which line meant the row was
/// absent. The distinction is not cosmetic — re-creating a row somebody else
/// has since re-created is the collision `ConfigConflict.created` exists for,
/// and it is the line an operator should read twice.
///
/// **`Delete` is styled apart.** It is the only line in the list that removes
/// something, and on a dialog whose whole job is "here is what I am about to
/// write" the destructive line must be distinguishable at a glance. It carries
/// the muted orange the history list already uses for a removed entity
/// (`ConfigChangeTile`'s op mark), so the two surfaces name removal with the
/// same colour rather than inventing a second vocabulary.
///
/// Position is named where it exists, because position is part of the entity a
/// restore writes back (`ConfigItem.encodeEntity`) and putting an asset back on
/// the wrong page is the failure the whole history design guards against. It is
/// named as *"in its original order"* rather than as a number: `sort_index`
/// holds a gapped stored key (1024, 2048 — `sort_keys.dart`), and telling an
/// operator their asset returns to "position 2048" would be honest about the
/// column and meaningless about the screen.
///
/// A `Revert` names the destination too, and names it as a destination rather
/// than as a move: the step carries the old entity and not the current one, so
/// this file cannot tell whether the page or the order is what changed. "on
/// /roe, in its original order" is true either way; "back onto /roe" would
/// claim it had left.
///
/// ## The refusal is structured, not one sentence
///
/// [UndoBlocker.summary] is written to be shown verbatim, and that is the right
/// shape for a snackbar or a log line. A dialog listing five blocked entities
/// is a different problem: it has to be **scannable**, so each entity gets its
/// own name, its own who/when line and one clause saying what is wrong.
///
/// It is also a golden problem. `UndoBlocker.summary` renders its instant with
/// `DateTime.toLocal()`, which makes the string depend on the machine's
/// timezone — a golden generated in Reykjavík and compared in CI would differ
/// by whatever offset the runner has. The who/when line here goes through
/// [formatTimestamp], the same formatter every other timestamp on this page
/// uses, so the picture is stable and the two pages agree on what a time looks
/// like.
///
/// **Nothing here decides anything.** Both dialogs are pure functions of the
/// values handed to them: the confirmation cannot write and the refusal cannot
/// retry. That is what lets both be pumped directly in a golden without a
/// database, a session or a route.
library;

import 'package:flutter/material.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_undo.dart';

import '../theme.dart' show HmiStateColors;
import 'base_scaffold.dart' show formatTimestamp;
import 'config_change_row.dart' show configKindLabel;

// ---------------------------------------------------------------------------
// The copy
// ---------------------------------------------------------------------------

/// The confirmation's title. A question, because it is one.
const String kConfigUndoConfirmTitle = 'Undo this action?';

/// The line above the list of writes.
const String kConfigUndoConfirmLead =
    'This will write the following back to the shared configuration:';

/// What the history will look like afterwards, said before the operator
/// commits rather than discovered afterwards.
///
/// The append-only rule, in an operator's words: the original action does not
/// disappear and this is not a way to erase it. Somebody who believed an undo
/// removed the evidence would be surprised by the history, and it is better to
/// be surprised now.
const String kConfigUndoConfirmAuditNote =
    'Both stay in the history: the original action, and this undo recorded as '
    'an action of its own.';

/// The button that does it.
const String kConfigUndoConfirmLabel = 'Undo';

/// The button that does not.
const String kConfigUndoCancelLabel = 'Cancel';

/// The refusal's title. Names the outcome, not the mechanism.
const String kConfigUndoBlockedTitle = 'This action can no longer be undone';

/// The first thing an operator needs to know about a refusal: nothing happened.
///
/// Stated before the reasons, and stated in both refusal paths — the plan that
/// was never ready and the race lost after Undo was pressed — because after
/// pressing a button labelled Undo, "did some of it go through" is the question
/// that matters most and the one a list of entity names does not answer.
const String kConfigUndoBlockedLead =
    'The configuration has moved on since this action. Nothing has been '
    'written.';

/// The dismissal.
const String kConfigUndoBlockedDismissLabel = 'Close';

/// What one blocked entity's problem is, in one clause.
///
/// Deliberately short and deliberately not [UndoBlocker.summary]: the entity,
/// the author and the instant are already three separate lines above it, so
/// this says only the thing they do not.
String configUndoBlockerClause(UndoBlocker blocker) => switch (blocker.reason) {
      UndoBlockReason.newerChange =>
        'Undoing this action would discard that change.',
      UndoBlockReason.entityMoved =>
        'What is stored is no longer what this action left, and the history '
            'does not say who changed it.',
      UndoBlockReason.unsupportedScope =>
        'This row belongs to one station and can only be changed on that '
            'station.',
      UndoBlockReason.unsupportedKind =>
        'This kind is not written through the shared configuration path.',
      UndoBlockReason.unknownKind =>
        'This station does not know how to write that kind — undo it from a '
            'station running the build that made the change.',
      UndoBlockReason.internalRow =>
        'This is bookkeeping the configuration store keeps about itself, not '
            'a setting anybody chose.',
    };

/// `asset /roe/CN04` — one entity, named the way the rest of the page names
/// entities.
String configUndoBlockerTitle(UndoBlocker blocker) =>
    '${blocker.kindName} ${blocker.entityId}';

/// Who moved it and when, or null when the log does not know.
///
/// Null rather than "unknown": a line reading *"Changed by unknown"* invents an
/// actor. When there is no newer change row there is genuinely nobody to name,
/// and [configUndoBlockerClause] says so instead.
String? configUndoBlockerAuthorLine(UndoBlocker blocker) {
  final who = blocker.who;
  final at = blocker.at;
  if (who == null) return null;
  return at == null
      ? 'Changed by $who'
      : 'Changed by $who · ${formatTimestamp(at)}';
}

/// One line of the confirmation: what this step writes.
///
/// Phrased as the write and never as the original edit, one verb per
/// operation — see the library doc for the table and the argument.
String configUndoStepSentence(UndoStep step) {
  final what = '${configKindLabel(step.kind)} ${step.entityId}';
  final item = step.item;
  final where = item?.parentId == null ? '' : ' on ${item!.parentId}';
  final order = item?.sortIndex == null ? '' : ', in its original order';

  return switch (step.inverseOp) {
    // The one an operator can misread, so it says the word.
    ConfigChangeOp.delete => 'Delete $what',
    ConfigChangeOp.insert => 'Re-create $what$where$order',
    ConfigChangeOp.update => 'Revert $what to its previous version$where$order',
  };
}

/// Whether this step removes something.
///
/// The confirmation styles these apart; nothing else branches on it. A
/// predicate rather than a check on [UndoStep.inverseOp] at the call site, so
/// "which lines are destructive" is answered in one place if a fourth op ever
/// exists.
bool configUndoStepIsDestructive(UndoStep step) =>
    step.inverseOp == ConfigChangeOp.delete;

// ---------------------------------------------------------------------------
// The keys
// ---------------------------------------------------------------------------

/// The confirmation dialog.
const Key kConfigUndoConfirmKey = ValueKey<String>('config-undo-confirm');

/// One line of the confirmation's write list.
const Key kConfigUndoStepKey = ValueKey<String>('config-undo-step');

/// The mark on a line that removes something. Present once per destructive
/// step and never otherwise, which is what a test can count.
const Key kConfigUndoDestructiveKey =
    ValueKey<String>('config-undo-destructive');

/// The note about what the history keeps.
const Key kConfigUndoAuditNoteKey = ValueKey<String>('config-undo-audit-note');

/// The button that commits the undo.
const Key kConfigUndoConfirmButtonKey =
    ValueKey<String>('config-undo-confirm-button');

/// The button that does not.
const Key kConfigUndoCancelButtonKey =
    ValueKey<String>('config-undo-cancel-button');

/// The refusal dialog.
const Key kConfigUndoBlockedKey = ValueKey<String>('config-undo-blocked');

/// The sentence saying nothing was written.
const Key kConfigUndoBlockedLeadKey =
    ValueKey<String>('config-undo-blocked-lead');

/// One blocked entity's name.
const Key kConfigUndoBlockedEntityKey =
    ValueKey<String>('config-undo-blocked-entity');

/// One blocked entity's who/when line. Absent when the log does not know who.
const Key kConfigUndoBlockedAuthorKey =
    ValueKey<String>('config-undo-blocked-author');

/// One blocked entity's clause.
const Key kConfigUndoBlockedClauseKey =
    ValueKey<String>('config-undo-blocked-clause');

/// The refusal's dismissal.
const Key kConfigUndoBlockedDismissKey =
    ValueKey<String>('config-undo-blocked-dismiss');

// ---------------------------------------------------------------------------
// The dialogs
// ---------------------------------------------------------------------------

/// What undoing [plan] will write, and a button to do it.
///
/// Pops `true` on confirm and null on cancel or a barrier tap, so the caller
/// treats every not-`true` answer as "do nothing" without enumerating the ways
/// a dialog can close.
class ConfigUndoConfirmDialog extends StatelessWidget {
  const ConfigUndoConfirmDialog({super.key, required this.plan});

  final UndoPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return AlertDialog(
      key: kConfigUndoConfirmKey,
      title: const Text(kConfigUndoConfirmTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kConfigUndoConfirmLead, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            for (final step in plan.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (configUndoStepIsDestructive(step))
                      Icon(Icons.remove_circle_outline,
                          key: kConfigUndoDestructiveKey,
                          size: 16,
                          color: colors.orange)
                    else
                      Icon(Icons.chevron_right,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        configUndoStepSentence(step),
                        key: kConfigUndoStepKey,
                        style: configUndoStepIsDestructive(step)
                            ? theme.textTheme.bodyMedium
                                ?.copyWith(color: colors.orange)
                            : theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              kConfigUndoConfirmAuditNote,
              key: kConfigUndoAuditNoteKey,
              style: secondary,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: kConfigUndoCancelButtonKey,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(kConfigUndoCancelLabel),
        ),
        FilledButton(
          key: kConfigUndoConfirmButtonKey,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(kConfigUndoConfirmLabel),
        ),
      ],
    );
  }
}

/// Why the undo will not happen, entity by entity.
///
/// Takes the blockers rather than the plan: the same dialog serves a plan that
/// was never ready and a race lost between confirm and write, and in the second
/// case the blockers come from re-asking [planUndo] after the conflict. One
/// refusal, one shape, whichever end of the window it arrived from.
class ConfigUndoBlockedDialog extends StatelessWidget {
  const ConfigUndoBlockedDialog({super.key, required this.blockers});

  final List<UndoBlocker> blockers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return AlertDialog(
      key: kConfigUndoBlockedKey,
      title: const Text(kConfigUndoBlockedTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kConfigUndoBlockedLead,
              key: kConfigUndoBlockedLeadKey,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final blocker in blockers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      configUndoBlockerTitle(blocker),
                      key: kConfigUndoBlockedEntityKey,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (configUndoBlockerAuthorLine(blocker)
                        case final line?) ...[
                      const SizedBox(height: 2),
                      Text(line,
                          key: kConfigUndoBlockedAuthorKey, style: secondary),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      configUndoBlockerClause(blocker),
                      key: kConfigUndoBlockedClauseKey,
                      style: secondary,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: kConfigUndoBlockedDismissKey,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(kConfigUndoBlockedDismissLabel),
        ),
      ],
    );
  }
}
