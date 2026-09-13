/// The configuration history list item: one human action, its entities, and
/// the fields that actually moved.
///
/// Three widgets, one per level of the thing a reader is trying to read:
///
/// * [ConfigActionTile] — one [HistoryAction]. "Jón changed 3 assets", not
///   three unrelated lines. Its children are the action's entities.
/// * [ConfigChangeTile] — one `config_change` row: `kind:entityId` with an op
///   badge, expanding to the fields.
/// * [ConfigFieldRow] — one [FieldChange], `old → new`.
///
/// ## The field rows are computed here, on read, and never stored
///
/// A change row carries the **whole entity** on each side
/// (`ConfigItem.encodeEntity()`, which is the payload plus its position), and
/// [diffConfigEntities] turns the two strings into the fields that moved. That
/// is 04-02's ruling and this file is its only consumer: storing a field-level
/// diff would freeze one rendering of a value that a later build renders
/// differently, and would lose the position an undo needs.
///
/// The diff is computed **once, on first expansion**, and kept. An
/// `ExpansionTile` builds its children whether or not it is open, so diffing in
/// `build` would walk every visible action's entire JSON on every frame — with
/// the values a real station stores that is threat T-04-06c wearing a widget's
/// clothes. Values are already capped at 256 characters by `renderJsonValue`;
/// the memo is what keeps the *walk* off the frame budget as well.
///
/// ## Three shapes of change, rendered as three different things
///
/// `diffConfigEntities` answers an insert with one `noBaseline` row holding
/// only the new entity, a delete with one row holding only the old one, and an
/// update with one row per moved field. [ConfigFieldRow] renders those three
/// asymmetrically on purpose: an insert has nothing to compare against, and
/// drawing `— → {…}` would invite reading the em dash as a value that used to
/// be there.
///
/// ## Colour
///
/// Everything here comes from `HmiStateColors.of(context)`; the raw palette is
/// never named. An added entity carries a green mark and a removed one an
/// orange mark, both muted; an updated entity carries an equally sized
/// transparent placeholder so the column below the marks stays straight. Red
/// is not used at all — nothing on this page is a fault, and a history in which
/// every row is coloured stops distinguishing anything.
///
/// Dividers are drawn from `onSurface` at low alpha rather than
/// `colorScheme.outline`: neither of this app's schemes sets `outline`, so it
/// resolves to a value that is invisible on the dark one.
library;

import 'package:flutter/material.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_field_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';

import '../core/audit_trail_grouping.dart';
import '../core/config_change_store.dart';
import '../theme.dart';
import 'audit_trail_row.dart';
import 'base_scaffold.dart' show formatTimestamp;

// ---------------------------------------------------------------------------
// Copy and keys
//
// The `audit_trail_row.dart` idiom: the copy is what a reader sees and may be
// rewritten, the key is what a test finds and must not change when the wording
// does.
// ---------------------------------------------------------------------------

/// The tappable header of an action, so a test can open one without guessing
/// where the hit target is.
const Key kConfigActionHeaderKey = Key('config-action-header');

/// The mark on an action whose `audit_entry` header is missing.
const Key kConfigParentlessKey = Key('config-parentless-flag');

/// The sentence beneath it. Separate from the mark so a test can assert the
/// flag and the explanation independently — one without the other is a state
/// this page must never be in.
const Key kConfigParentlessNoteKey = Key('config-parentless-note');

/// The line that says what the filters removed from an action.
const Key kConfigHiddenChangesKey = Key('config-hidden-changes');

/// The tappable header of one entity inside an action.
const Key kConfigEntityHeaderKey = Key('config-entity-header');

/// The `added` / `changed` / `removed` badge on an entity row.
const Key kConfigOpBadgeKey = Key('config-op-badge');

/// The mark slot on an entity row, coloured for an insert or a delete and
/// transparent for an update.
const Key kConfigOpMarkKey = Key('config-op-mark');

/// The invisible stand-in the mark slot holds on an update.
const Key kConfigOpMarkPlaceholderKey = Key('config-op-mark-placeholder');

/// One field-level row under an expanded entity.
const Key kConfigFieldRowKey = Key('config-field-row');

/// The line an entity shows when its two sides differ in no field at all.
const Key kConfigNoFieldChangeKey = Key('config-no-field-change');

/// The detail line under an entity: station, scope and action id.
const Key kConfigEntityDetailKey = Key('config-entity-detail');

/// What an action whose `audit_entry` row never landed says about itself.
///
/// **Not "corrupt" and not "error".** The store commits its change rows and
/// writes the audit header afterwards; a crash between the two leaves exactly
/// this. The rows below are real, they say what changed, who changed it and
/// when — the only thing missing is the header, and the sentence says which
/// consequence that has (no recorded permission) rather than casting doubt on
/// the changes themselves.
const String kConfigParentlessNote =
    'No audit header was recorded for this action — the changes below are '
    'complete, but the permission it ran under was not written.';

/// What the filters removed from an action, stated where a reader sees it.
String kConfigHiddenChangesNote(int hidden, int total) =>
    '$hidden of $total changes hidden by filters';

/// The whole-entity row an insert produces.
const String kConfigEntityAddedLabel = 'New entity';

/// The whole-entity row a delete produces.
const String kConfigEntityRemovedLabel = 'Removed entity';

/// The whole-entity row an unparseable side produces — the diff could not read
/// one of the two, so the entity is shown whole rather than field by field.
const String kConfigEntityWholeLabel = 'Entire entity';

/// An entity whose two sides hold the same fields.
///
/// Possible without being a defect: a save that rewrote an entity to the value
/// it already held still writes a row, and `rev`, `updatedAt` and `updatedBy`
/// are not part of the entity encoding, so there is genuinely nothing to show.
/// Saying so is better than an empty expansion, which reads as a bug.
const String kConfigNoFieldChange = 'No field-level difference recorded.';

/// The prefixes on the entity detail line.
const String kConfigScopeLabel = 'Scope:';

/// See [kConfigScopeLabel].
const String kConfigStationLabel = 'Station:';

/// See [kConfigScopeLabel].
const String kConfigActionIdLabel = 'Action:';

/// The badge on one entity row.
String configOpLabel(ConfigChangeOp op) => switch (op) {
      ConfigChangeOp.insert => 'added',
      ConfigChangeOp.update => 'changed',
      ConfigChangeOp.delete => 'removed',
    };

/// A human name for one [ConfigKind], singular or plural.
///
/// **Falls back to the wire name rather than throwing.** Several stations write
/// to one database and a station on a newer build will write a kind this one
/// has never heard of; an exhaustive switch here would be a page that goes
/// blank on the day somebody upgrades one panel. The same open-vocabulary rule
/// `auditOriginLabel` states.
String configKindLabel(ConfigKind kind, {bool plural = false}) {
  final one = switch (kind) {
    ConfigKind.page => 'page',
    ConfigKind.asset => 'asset',
    ConfigKind.keyMapping => 'key mapping',
    ConfigKind.preference => 'preference',
    ConfigKind.pageImage => 'page image',
  };
  return plural ? '${one}s' : one;
}

/// What one action did, counted by kind: `3 assets`, `2 assets, 1 page`.
///
/// Counted over the **visible** children, with [HistoryAction.hiddenCount]
/// reconciled on its own line rather than folded in here: a phrase that counted
/// rows the reader cannot see would name three assets above two.
String configActionCounts(HistoryAction action) {
  final byKind = <ConfigKind, int>{};
  for (final record in action.changes) {
    byKind.update(record.change.kind, (n) => n + 1, ifAbsent: () => 1);
  }
  if (byKind.isEmpty) return 'no configuration entities';
  final parts = <String>[
    for (final entry in byKind.entries)
      '${entry.value} ${configKindLabel(entry.key, plural: entry.value != 1)}',
  ];
  return parts.join(', ');
}

/// The action's headline: who did it, and to how much.
String configActionSummary(HistoryAction action) =>
    '${action.who} changed ${configActionCounts(action)}';

/// `kind:entityId`, the identity a change row carries and an `audit_entry` row
/// does not.
String configEntityLabel(ConfigChange change) =>
    '${change.kind.wireName}:${change.entityId}';

// ---------------------------------------------------------------------------
// Geometry — the audit row's, so the two lists scan alike
// ---------------------------------------------------------------------------

/// The height of one entity line.
const double kConfigRowHeight = kAuditRowHeight;

/// The width of the op mark slot, occupied whether it is coloured or not.
const double kConfigMarkWidth = kAuditMarkWidth;

/// The height of the mark inside [kConfigRowHeight].
const double kConfigMarkHeight = kAuditMarkHeight;

/// The gap between columns.
const double kConfigColumnGap = kAuditColumnGap;

/// The indent one level of nesting adds.
const double kConfigNestIndent = 16;

// ---------------------------------------------------------------------------
// ConfigFieldRow
// ---------------------------------------------------------------------------

/// One [FieldChange]: the path that moved, and what it moved between.
///
/// The three shapes are rendered as three different things — see the library
/// doc. Every string is capped at one line, so a value that reached the 256
/// character cap cannot make one row taller than its neighbours.
class ConfigFieldRow extends StatelessWidget {
  const ConfigFieldRow({super.key, required this.change});

  final FieldChange change;

  /// What the left column says.
  ///
  /// A `field` of null means the row is about the whole entity, and which of
  /// the three whole-entity cases it is is readable from the two sides:
  /// `noBaseline` is an insert, a null `newValue` is a delete, and both present
  /// is a side the diff could not parse.
  String get label {
    final field = change.field;
    if (field != null) return field;
    if (change.noBaseline) return kConfigEntityAddedLabel;
    if (change.newValue == null) return kConfigEntityRemovedLabel;
    return kConfigEntityWholeLabel;
  }

  /// What the right column says.
  ///
  /// An insert shows the new entity alone and a delete the old one alone: a
  /// transition needs two sides, and drawing an em dash opposite one of them
  /// invites reading it as a value that was there.
  String get value {
    if (change.noBaseline) return change.newValue ?? kAuditValueMissing;
    // The whole-entity delete: one side, no arrow. A *field* that an update
    // removed is not that case — it has a name, and `old → —` is what says
    // it went away; drawn as its old value alone it read as still set.
    if (change.newValue == null && change.field == null) {
      return change.oldValue ?? kAuditValueMissing;
    }
    return '${change.oldValue ?? kAuditValueMissing} $kAuditTransitionArrow '
        '${change.newValue ?? kAuditValueMissing}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.textTheme.bodySmall;
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Padding(
      key: kConfigFieldRowKey,
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: secondary,
            ),
          ),
          const SizedBox(width: kConfigColumnGap),
          Expanded(
            flex: 3,
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ConfigChangeTile
// ---------------------------------------------------------------------------

/// One `config_change` row: the entity it changed, expanding to the fields.
///
/// Stateful for one reason — the memoised diff. See the library doc.
class ConfigChangeTile extends StatefulWidget {
  const ConfigChangeTile({super.key, required this.record});

  final ConfigChangeRecord record;

  @override
  State<ConfigChangeTile> createState() => ConfigChangeTileState();
}

/// Public so a widget test can assert the diff ran once.
class ConfigChangeTileState extends State<ConfigChangeTile> {
  /// The field rows, or null while the tile has never been opened.
  List<FieldChange>? _fields;

  /// How many times [diffConfigEntities] has run for this tile. Read by the
  /// test that pins the memo — without it the assertion would pass vacuously.
  int diffCount = 0;

  @override
  void didUpdateWidget(covariant ConfigChangeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The memo is of *this* record's diff. The tile is keyed by row id so an
    // element rarely changes records, but a rebuild that does hand it another
    // must not draw the old one's fields under the new one's title.
    if (oldWidget.record != widget.record) _fields = null;
  }

  List<FieldChange> _ensureFields() {
    final cached = _fields;
    if (cached != null) return cached;
    diffCount++;
    final change = widget.record.change;
    final computed = diffConfigEntities(change.oldValue, change.newValue);
    _fields = computed;
    return computed;
  }

  /// The op mark: green added, orange removed, nothing at all for an update.
  Widget _mark(BuildContext context) {
    final colors = HmiStateColors.of(context);
    final color = switch (widget.record.change.op) {
      ConfigChangeOp.insert => colors.green,
      ConfigChangeOp.delete => colors.orange,
      ConfigChangeOp.update => null,
    };
    if (color == null) {
      return const SizedBox(
        key: kConfigOpMarkPlaceholderKey,
        width: kConfigMarkWidth,
        height: kConfigMarkHeight,
      );
    }
    return SizedBox(
      width: kConfigMarkWidth,
      height: kConfigMarkHeight,
      child: ColoredBox(key: kConfigOpMarkKey, color: color),
    );
  }

  Widget _badge(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: kConfigOpBadgeKey,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        configOpLabel(widget.record.change.op),
        maxLines: 1,
        style: theme.textTheme.labelSmall,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = widget.record.change;
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final fields = _fields;

    return ExpansionTile(
      tilePadding: const EdgeInsets.only(left: kConfigNestIndent, right: 8),
      childrenPadding: const EdgeInsets.fromLTRB(
        kConfigNestIndent * 2,
        0,
        16,
        8,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      dense: true,
      // `onExpansionChanged` is what runs the diff, not `build`: a shut tile
      // costs nothing, and an open one costs one walk for as long as it lives.
      onExpansionChanged: (open) {
        if (!open || _fields != null) return;
        setState(_ensureFields);
      },
      title: SizedBox(
        height: kConfigRowHeight,
        child: Row(
          key: kConfigEntityHeaderKey,
          children: [
            _mark(context),
            const SizedBox(width: kConfigColumnGap),
            _badge(context),
            const SizedBox(width: kConfigColumnGap),
            Expanded(
              child: Text(
                configEntityLabel(change),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: kConfigColumnGap),
            Text(formatTimestamp(change.at), maxLines: 1, style: secondary),
          ],
        ),
      ),
      children: [
        Text(
          '$kConfigScopeLabel ${change.scope.wireName}'
          '    $kConfigStationLabel ${change.station}'
          '    $kConfigActionIdLabel ${change.actionId}',
          key: kConfigEntityDetailKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        // Null until the tile has been opened once. `ExpansionTile` constructs
        // this list whether or not it is showing it, so reading `_fields` here
        // rather than calling `_ensureFields` is what keeps the walk off the
        // frame budget of a shut tile.
        if (fields == null)
          const SizedBox.shrink()
        else if (fields.isEmpty)
          Text(
            kConfigNoFieldChange,
            key: kConfigNoFieldChangeKey,
            style: secondary,
          )
        else
          for (final field in fields) ConfigFieldRow(change: field),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// ConfigActionTile
// ---------------------------------------------------------------------------

/// One human action: who did it, to how many entities, expanding to them.
///
/// The list is read as **actions**. One page save that moved three assets is
/// one line saying so, not three unrelated lines an operator has to correlate
/// by timestamp.
///
/// An action arrives **open** when it is parentless or partly filtered, and
/// shut otherwise — the two open cases are the ones carrying a sentence the
/// reader needs, and `AuditActionTile` already opens a partial action on
/// arrival for the same reason.
class ConfigActionTile extends StatelessWidget {
  const ConfigActionTile({super.key, required this.action});

  final HistoryAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final secondary = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final group = action.requiredGroupLabel;

    return ExpansionTile(
      initiallyExpanded: action.isParentless || action.isPartial,
      maintainState: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: kConfigColumnGap),
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Row(
        key: kConfigActionHeaderKey,
        children: [
          // The parentless mark, in the same slot the entity rows put theirs,
          // so a missing header is visible before anything is expanded.
          if (action.isParentless)
            SizedBox(
              width: kConfigMarkWidth,
              height: kConfigMarkHeight,
              child: ColoredBox(
                key: kConfigParentlessKey,
                color: colors.orange,
              ),
            )
          else
            const SizedBox(width: kConfigMarkWidth, height: kConfigMarkHeight),
          const SizedBox(width: kConfigColumnGap),
          Expanded(
            child: Text(
              configActionSummary(action),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: kConfigColumnGap),
          Text(formatTimestamp(action.at), maxLines: 1, style: secondary),
        ],
      ),
      // Indented to the title's text column rather than to the tile's edge:
      // the mark slot is 4px plus a gap, and a subtitle that started outside it
      // would jog left of every line it belongs to.
      subtitle: Padding(
        padding: const EdgeInsets.only(
          left: kConfigMarkWidth + kConfigColumnGap,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (group.isNotEmpty)
              Text(group, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: secondary),
            if (action.isParentless)
              Text(
                kConfigParentlessNote,
                key: kConfigParentlessNoteKey,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: secondary,
              ),
            if (action.isPartial)
              Text(
                kConfigHiddenChangesNote(
                  action.hiddenCount,
                  action.totalChangeCount + action.totalAuditRowCount,
                ),
                key: kConfigHiddenChangesKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: secondary,
              ),
          ],
        ),
      ),
      children: [
        for (final child in action.children)
          switch (child) {
            // The header row, drawn by the audit trail's own widget rather than
            // re-implemented: a `page.save` line has to read the same on both
            // pages or the two will drift.
            AuditMemberChild(:final row) =>
              Padding(
                padding: const EdgeInsets.only(left: kConfigNestIndent),
                child: AuditEntryLine(row: row, showDetail: true),
              ),
            ConfigChangeChild(:final record) => ConfigChangeTile(
                key: ValueKey(record.id),
                record: record,
              ),
          },
      ],
    );
  }
}
