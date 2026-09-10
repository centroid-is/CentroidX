/// The audit trail's filter bar: five controls, one note, and no state of its
/// own beyond a debounce timer.
///
/// The page owns one [AuditTrailFilters] and hands it down; every control here
/// emits a whole new value through one `ValueChanged<AuditTrailFilters>` and
/// nothing else. That is `AlarmLevelFilterChips`' shape
/// (`lib/widgets/alarm.dart:102`), and it is what lets the bar be pumped in a
/// widget test without a database, a provider or a session.
///
/// ## The one default exclusion, and why it is on screen
///
/// The ROADMAP names exactly one default exclusion: `operate`. A jog button
/// pressed four hundred times an hour would otherwise be the whole page.
/// CONTEXT then rules that the exclusion is a **visible control** — a normal
/// group chip rendered deselected, with a one-line note — because hidden
/// behaviour reads as a bug and the row count would otherwise be inexplicable.
/// That note is [kAuditTrailOperateNote] and it renders whether or not
/// `operate` is currently selected.
///
/// Two other exclusions were offered and rejected: defaulting to denials-only,
/// and default-hiding `origin: 'system'`. The MCP reconnect noise is real, and
/// hiding it by default would make the page lie about what the station did.
/// Neither is implemented here, and neither should be added without reopening
/// that decision.
///
/// ## Nothing here queries anything
///
/// The `who` options are a parameter, the result summary is a parameter, and
/// the refresh affordance is a callback. The bar issues no statement, reads no
/// provider and starts no periodic timer. Its single timer is the keystroke
/// debounce below, which is one-shot and dies in `dispose`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tfc_access/tfc_access.dart';

import '../core/audit_trail_store.dart';
import 'button_graph.dart' show showSetDatePicker;
import 'fuzzy_search_bar.dart';

// ---------------------------------------------------------------------------
// Copy and keys
//
// Kept at the top of the file in the `access_gate.dart` / `audit_trail_row.dart`
// idiom, so a test asserts against the string the widget renders rather than
// one it supplies. Each `Key` is separate from the copy beside it: the copy is
// what a reader sees and may be rewritten, the key is what a test finds and
// must not change when the wording does.
// ---------------------------------------------------------------------------

/// The one line that explains the page's one default exclusion.
///
/// It exists because the exclusion is otherwise invisible. The ROADMAP names
/// `operate` as the single default exclusion; a page that quietly drops the
/// noisiest group is a page whose row count cannot be reconciled with the
/// table, and an unexplained gap in an audit trail is the one thing an audit
/// trail must never have.
///
/// The wording says both halves on purpose — **what** is hidden and **how to
/// get it back** — so the note doubles as the instruction for undoing it. It
/// renders in both selection states: a note that vanishes the moment you change
/// the thing it explains cannot be read a second time.
const String kAuditTrailOperateNote =
    'Operate and ungated writes are hidden by default — tap the Operate chip '
    'to include them.';

/// The eighth chip's label. Auth rows are not a group; see [AuditGroupChips].
const String kAuditTrailAuthChipLabel = 'Auth';

/// The `who` dropdown's null entry: every author, which is the default.
const String kAuditTrailAnyoneLabel = 'Anyone';

/// What the date chip says when no explicit range is set, which is also the
/// name of [kAuditTrailDefaultWindow].
const String kAuditTrailDefaultRangeLabel = 'Last 7 days';

/// What the result summary says when the query escaped the time bound.
const String kAuditTrailWholeTableLabel = 'All time';

/// The button that returns the page to the state it opened in.
const String kAuditTrailClearFiltersLabel = 'Clear filters';

/// The affordance that drops an explicit range without touching anything else.
const String kAuditTrailClearRangeTooltip = 'Clear range';

/// The bar's refresh affordance. There is no timer; see [AuditTrailFilterBar].
const String kAuditTrailRefreshTooltip = 'Refresh';

/// The prefix field's hint. It names what is searched and how far the search
/// reaches, because both are the point of the control.
const String kAuditTrailPrefixHint = 'Search all keys, e.g. CN04';

/// Wide enough for [kAuditTrailPrefixHint] and for a fully qualified key --
/// the two things this field has to be able to show.
const double kAuditTrailPrefixFieldWidth = 360;

/// The three outcome segments, in the order they render.
const String kAuditTrailOutcomeAnyLabel = 'All';
const String kAuditTrailOutcomeAllowedLabel = 'Allowed';
const String kAuditTrailOutcomeDeniedLabel = 'Denied';

/// The chip for one [AccessGroup], found by its `name` rather than its label so
/// a reworded label does not break a test about behaviour.
Key auditGroupChipKey(String groupName) =>
    ValueKey<String>('audit-group-chip-$groupName');

/// The eighth chip.
const Key kAuditTrailAuthChipKey = ValueKey<String>('audit-auth-chip');

/// The line carrying [kAuditTrailOperateNote].
const Key kAuditTrailOperateNoteKey = ValueKey<String>('audit-operate-note');

/// The key-prefix search field.
const Key kAuditTrailPrefixFieldKey = ValueKey<String>('audit-prefix-field');

/// The author dropdown.
const Key kAuditTrailWhoDropdownKey = ValueKey<String>('audit-who-dropdown');

/// The all/allowed/denied segmented control.
const Key kAuditTrailOutcomeKey = ValueKey<String>('audit-outcome-segments');

/// The date-range affordance.
const Key kAuditTrailRangeChipKey = ValueKey<String>('audit-range-chip');

/// The affordance that drops an explicit range and nothing else.
const Key kAuditTrailClearRangeKey = ValueKey<String>('audit-clear-range');

/// The bar's own `Clear filters`. 05-06's empty body owns the other one.
const Key kAuditTrailClearFiltersKey = ValueKey<String>('audit-clear-filters');

/// The refresh affordance. There is no clock behind it; see
/// [AuditTrailFilterBar].
const Key kAuditTrailRefreshKey = ValueKey<String>('audit-refresh');

/// The one line stating how many rows came back, and over what window.
const Key kAuditTrailResultSummaryKey =
    ValueKey<String>('audit-result-summary');

/// How long the operator has to stop typing before the database is asked.
///
/// Long enough that a whole key is typed inside one window, short enough that
/// the answer feels like it followed the typing.
const Duration kAuditTrailSearchDebounce = Duration(milliseconds: 300);

/// What one [AccessGroup]'s chip says.
///
/// Derived from the enum's own `name` rather than a lookup table, so an eighth
/// group gets a label the day it is declared instead of a blank chip or a
/// missing one. `AccessGroup`'s doc calls an eighth value "a decision, not an
/// edit"; this file must not be one of the places that decision has to be
/// repeated.
String auditGroupChipLabel(AccessGroup group) {
  final name = group.name;
  if (name.isEmpty) return name;
  return name[0].toUpperCase() + name.substring(1);
}

// ---------------------------------------------------------------------------
// The group chips
// ---------------------------------------------------------------------------

/// One chip per [AccessGroup], then one for auth rows, then the note.
///
/// ## Why there are eight chips and not seven
///
/// Auth rows — `login`, `login.failed`, `logout`, `session.timeout` and
/// `session.resume` — carry an **empty** `group_required`, because signing in
/// is not gated on a group. A
/// bare `group_required IN (...)` would therefore drop every sign-in from the
/// page. CONTEXT rejected putting auth rows on a separate tab precisely because
/// interleaving is what preserves "who signed in right before this write", so
/// the rows have to stay in the list; the eighth chip is what makes them
/// *filterable* rather than unconditional. `AuditTrailStore.entries` ORs the
/// `surface = 'auth'` leg in for it.
///
/// ## Selection semantics: what is shared with `AlarmLevelFilterChips`
///
/// **Shared, and locked.** Nothing selected means no constraint — every group,
/// every row. CONTEXT's words: *"Filters combine: AND across dimensions, OR
/// within a multi-select dimension, empty selection = no constraint. Identical
/// to `AlarmLevelFilterChips` (`lib/widgets/alarm.dart:96-101`), so the
/// semantics are already learned."* It reads backwards on first encounter —
/// deselect everything, see everything — and the next reader's instinct will be
/// to "fix" it into "empty means nothing matches". That inversion was proposed
/// once in this phase, labelled a documented divergence, and reverted. This
/// widget therefore does not block the empty state and does not helpfully
/// re-select anything to prevent it.
///
/// **Not shared: the *initial* set.** `AlarmLevelFilterChips` starts empty;
/// this one starts with the six non-`operate` groups plus auth selected
/// ([kAuditTrailDefaultGroupNames]). That single difference — a non-empty
/// default rather than an empty one — is the entire mechanism by which
/// `operate` is excluded on open, and it is the only reason the row count
/// differs from an unfiltered table. It is also why [kAuditTrailOperateNote]
/// has to be beside these chips.
///
/// ## No counts
///
/// `AlarmLevelFilterChips` puts a count on each chip and can, because it
/// filters in memory over a list it already holds. Every filter here is pushed
/// into SQL, so a chip could not state how many rows it would add without a
/// second query per chip, and a count over the loaded window would be a number
/// that looks authoritative and is not. The result count is stated once, above
/// the list, labelled with the window it came from.
class AuditGroupChips extends StatelessWidget {
  const AuditGroupChips({
    super.key,
    required this.filters,
    required this.onChanged,
  });

  /// The state the parent owns. This widget holds none of its own.
  final AuditTrailFilters filters;

  /// The one way anything leaves this widget.
  final ValueChanged<AuditTrailFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = filters.groupNames.toSet();
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wrap, not Row: the bar sits above a full-width list and can be
        // narrow, so the chips have to fold onto a second line rather than
        // overflow it.
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final group in AccessGroup.values)
              _chip(
                context,
                key: auditGroupChipKey(group.name),
                label: auditGroupChipLabel(group),
                isSelected: selected.contains(group.name),
                onSelected: (keep) => _toggleGroup(group, keep),
              ),
            _chip(
              context,
              key: kAuditTrailAuthChipKey,
              label: kAuditTrailAuthChipLabel,
              isSelected: filters.includeAuth,
              onSelected: (keep) => onChanged(filters.copyWith(includeAuth: keep)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          kAuditTrailOperateNote,
          key: kAuditTrailOperateNoteKey,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// The chip mechanics of `AlarmLevelFilterChips._chip`, minus its avatar and
  /// its count. No colour is named here at all: a selected chip takes the
  /// theme's own selection fill, because these chips carry no severity and a
  /// filter bar painted eight colours stops distinguishing anything.
  Widget _chip(
    BuildContext context, {
    required Key key,
    required String label,
    required bool isSelected,
    required ValueChanged<bool> onSelected,
  }) =>
      FilterChip(
        key: key,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        showCheckmark: false,
        label: Text(label),
        selected: isSelected,
        onSelected: onSelected,
      );

  /// Adds or removes one group name, keeping the list in [AccessGroup]
  /// declaration order.
  ///
  /// Rebuilt from the enum rather than appended to, so two filter states that
  /// differ only in the order the operator tapped their chips compare equal —
  /// `AuditQuery` sorts anyway, but a provider family keyed on the *filters*
  /// would otherwise miss its cache on a re-tap.
  ///
  /// Names the enum does not know are carried through untouched rather than
  /// dropped. `group_required` is an open vocabulary: a station running a newer
  /// build can have written a group this one has never heard of, and silently
  /// deleting it from the filter on an unrelated tap would change what the
  /// query returns for a reason the operator never asked for.
  void _toggleGroup(AccessGroup group, bool keep) {
    final selected = filters.groupNames.toSet();
    if (keep) {
      selected.add(group.name);
    } else {
      selected.remove(group.name);
    }

    final known = {for (final value in AccessGroup.values) value.name};
    final next = <String>[
      for (final value in AccessGroup.values)
        if (selected.contains(value.name)) value.name,
      for (final name in filters.groupNames)
        if (!known.contains(name) && selected.contains(name)) name,
    ];
    onChanged(filters.copyWith(groupNames: next));
  }
}

// ---------------------------------------------------------------------------
// The key-prefix search field
// ---------------------------------------------------------------------------

/// The `item_key` prefix field, and the only stateful thing in this file.
///
/// ## Why this one is debounced when `alarm.dart`'s is not
///
/// [FuzzySearchBar.onChanged] fires on every keystroke and is undebounced. That
/// is right for the alarm page, whose search filters a list already in memory:
/// six keystrokes there are six cheap passes over a few hundred objects.
///
/// Here they are six **database** queries, and each one is potentially over the
/// whole `audit_entry` table — because CONTEXT's user override rules that this
/// field escapes the seven-day default: *"the search bar searches the database,
/// not the loaded page … Searching must answer 'has anyone ever written this
/// key', not 'did anyone this week'."* `AuditTrailFilters.isSearching` flips
/// the moment this field is non-empty, and `toQuery` drops the time bound for
/// it. So the widget's job is to make that escape cheap enough to do per
/// keystroke without actually doing it per keystroke: one query per pause.
///
/// ## The shape of the timer, and the shape that is forbidden
///
/// A one-shot `Timer`, cancelled when it is replaced and cancelled again in
/// `dispose`. That is `history_table_pane.dart`'s `_updateTimer` — the only
/// debounce this repo has — copied deliberately rather than reinvented.
///
/// The repeating form is the forbidden one, and not as a matter of taste: an
/// always-on repeating timer in this repo's plumbing has broken unrelated
/// widget tests, and CONTEXT rules there is no timer on this page at all beyond
/// this debounce. A test reads this file with the comments stripped and fails
/// if the repeating constructor ever appears in the code.
///
/// The trim is not cosmetic. A stray trailing space would make the prefix
/// `'CN04 '`, whose `LIKE 'CN04 %'` matches nothing — and it would still flip
/// `isSearching`, so the page would drop its seven-day bound to run a
/// whole-table scan that cannot hit.
class AuditPrefixField extends StatefulWidget {
  const AuditPrefixField({
    super.key,
    required this.filters,
    required this.onChanged,
    this.searchBarKey,
    this.debounce = kAuditTrailSearchDebounce,
  });

  /// The state the parent owns.
  final AuditTrailFilters filters;

  /// Emitted once per pause, never once per keystroke.
  final ValueChanged<AuditTrailFilters> onChanged;

  /// The bar's handle on the inner field, so `Clear filters` can empty the box
  /// through the `GlobalKey<FuzzySearchBarState>.clear()` idiom
  /// (`alarm.dart:667`, `:879`).
  final GlobalKey<FuzzySearchBarState>? searchBarKey;

  /// Overridable so a test can drive the window without waiting on the clock.
  final Duration debounce;

  @override
  State<AuditPrefixField> createState() => _AuditPrefixFieldState();
}

class _AuditPrefixFieldState extends State<AuditPrefixField> {
  /// One-shot. See the class doc for the form this must never take.
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onTyped(String raw) {
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      if (!mounted) return;
      widget.onChanged(widget.filters.copyWith(keyPrefix: raw.trim()));
    });
  }

  @override
  Widget build(BuildContext context) => FuzzySearchBar(
        key: widget.searchBarKey,
        hintText: kAuditTrailPrefixHint,
        onChanged: _onTyped,
      );
}

// ---------------------------------------------------------------------------
// The author dropdown
// ---------------------------------------------------------------------------

/// The `who` filter: everyone the table has ever recorded, plus `Anyone`.
///
/// [options] is a parameter and not a provider read, so the whole bar pumps in
/// a widget test with no database behind it. In production the page fills it
/// from `AuditTrailStore.distinctWho`, which is a `SELECT DISTINCT who` over
/// the whole table with no `LIMIT`: the list of people who have ever touched
/// one station is small by nature, and a bound there would silently hide the
/// person somebody is looking for.
///
/// A [AuditTrailFilters.who] that is not in [options] falls back to `Anyone`
/// rather than being passed to `DropdownButton`, which asserts on a value with
/// no matching item. A filter can outlive the row set that suggested it — the
/// operator picks a name, then narrows the window past that person's last
/// write — and the difference between the fallback and no fallback is a stale
/// filter versus a crash. The filter value itself is left alone; only the
/// rendering falls back.
class AuditWhoDropdown extends StatelessWidget {
  const AuditWhoDropdown({
    super.key,
    required this.filters,
    required this.options,
    required this.onChanged,
  });

  final AuditTrailFilters filters;

  /// Every distinct author, sorted. Supplied by the page.
  final List<String> options;

  final ValueChanged<AuditTrailFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = options.contains(filters.who) ? filters.who : null;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
      child: DropdownButton<String?>(
        key: kAuditTrailWhoDropdownKey,
        value: value,
        underline: const SizedBox.shrink(),
        isDense: true,
        isExpanded: true,
        icon: Icon(Icons.unfold_more, size: 16, color: scheme.onSurfaceVariant),
        onChanged: (who) => onChanged(
          who == null
              ? filters.copyWith(clearWho: true)
              : filters.copyWith(who: who),
        ),
        items: [
          // Italic, and first: it is the absence of a filter rather than one of
          // the people, which is the same distinction `history_view.dart`'s
          // saved-period dropdown draws with its `None` entry.
          DropdownMenuItem<String?>(
            value: null,
            child: Text(
              kAuditTrailAnyoneLabel,
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final who in options)
            DropdownMenuItem<String?>(
              value: who,
              child: Text(
                who,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The outcome toggle
// ---------------------------------------------------------------------------

/// What one [AuditOutcomeFilter] segment says.
String auditOutcomeLabel(AuditOutcomeFilter outcome) => switch (outcome) {
      AuditOutcomeFilter.any => kAuditTrailOutcomeAnyLabel,
      AuditOutcomeFilter.allowedOnly => kAuditTrailOutcomeAllowedLabel,
      AuditOutcomeFilter.deniedOnly => kAuditTrailOutcomeDeniedLabel,
    };

/// All / Allowed / Denied.
///
/// `any` is the default and stays the default: defaulting to denials-only was
/// offered and rejected, because a page that opens showing only refusals is not
/// a trail of what the station did. Spec §2's point that a denied write is the
/// more interesting line is served by making denials *one tap away*, not by
/// hiding everything else on arrival.
class AuditOutcomeSegments extends StatelessWidget {
  const AuditOutcomeSegments({
    super.key,
    required this.filters,
    required this.onChanged,
  });

  final AuditTrailFilters filters;
  final ValueChanged<AuditTrailFilters> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<AuditOutcomeFilter>(
        key: kAuditTrailOutcomeKey,
        showSelectedIcon: false,
        segments: [
          for (final outcome in AuditOutcomeFilter.values)
            ButtonSegment<AuditOutcomeFilter>(
              value: outcome,
              label: Text(auditOutcomeLabel(outcome)),
            ),
        ],
        selected: {filters.outcome},
        onSelectionChanged: (selection) =>
            onChanged(filters.copyWith(outcome: selection.first)),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            Theme.of(context).textTheme.labelMedium,
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// The date range, and how a window is named
// ---------------------------------------------------------------------------

/// What opens when the date chip is tapped.
///
/// A parameter rather than a direct call so the chip is testable. The default
/// is [showSetDatePicker] from `button_graph.dart`, the range picker this repo
/// already has — a third-party modal from `board_datetime_picker`, reused and
/// not rebuilt. It must never be opened inside a golden: its rendering belongs
/// to that package and is not this phase's to pin.
typedef AuditRangePicker = Future<DateTimeRange?> Function(
  BuildContext context,
  DateTimeRange? current,
);

/// `2026-08-01 06:00 → 2026-08-30 18:30`.
///
/// `history_view.dart`'s `_rangeLabel` with the seconds dropped: an audit
/// window is chosen to the minute and the extra two digits are two more
/// characters to ellipsise away on a narrow bar.
String auditRangeLabel(AuditWindow window) =>
    '${_stamp(window.start)} → ${_stamp(window.end)}';

String _stamp(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// The name of the window [filters] would actually be answered over.
///
/// Not simply the date chip's label. The chip states the *explicit* range and
/// says [kAuditTrailDefaultRangeLabel] when there is none, which is what the
/// control does; this states what the **query** did, and a search escapes the
/// seven-day bound entirely (`AuditTrailFilters.toQuery`). Reporting "Last 7
/// days" beside a count that was taken over the whole table would be the exact
/// wrong-answer-that-looks-right the search escape exists to prevent.
String auditTrailWindowLabel(AuditTrailFilters filters) {
  final range = filters.range;
  if (range != null) return auditRangeLabel(range);
  if (filters.isSearching) return kAuditTrailWholeTableLabel;
  return kAuditTrailDefaultRangeLabel;
}

/// `42 entries · Last 7 days`.
///
/// One line, stated once, above the list — never on a chip. A number without
/// the window that produced it is a claim the operator cannot check, and
/// counts on the chips would each need their own query to be true.
String auditTrailResultSummary({
  required int count,
  required AuditTrailFilters filters,
}) =>
    '$count ${count == 1 ? 'entry' : 'entries'} · '
    '${auditTrailWindowLabel(filters)}';

// ---------------------------------------------------------------------------
// The bar
// ---------------------------------------------------------------------------

/// The one widget the audit trail page mounts.
///
/// Five controls and a note in one folding container: the key-prefix field, the
/// group chips, the outcome segments, the `who` dropdown and the date-range
/// chip, with `Clear filters`, `Clear range`, a refresh button and the result
/// summary around them. The lighter `surfaceContainerHighest` container of
/// `history_view.dart`'s top controls rather than `alarm.dart`'s elevated
/// `Material`: this bar sits above a dense table and an elevation shadow across
/// the full width would cut the page in half.
///
/// ## Clear filters means "the state the page opened in"
///
/// `AuditTrailFilters.cleared()`, not an empty filter set. `operate` stays
/// **deselected** afterwards, auth stays on, the outcome returns to `any` and
/// the range and the search go away. The ROADMAP's single default exclusion is
/// a decision, not an accident of initialisation, and a Clear that brought
/// `operate` writes back would quietly disagree with [kAuditTrailOperateNote]
/// rendered two lines above it.
///
/// It renders only while [AuditTrailFilters.isDefault] is false. With the
/// filters already default there is nothing for it to undo, and 05-06's empty
/// body renders its own `Clear filters` for the "no rows match" case — so
/// exactly one such control is on screen in every state, and never two.
///
/// ## The refresh affordance is a button, not a clock
///
/// CONTEXT rules there is no timer on this page: it refreshes on open and on
/// this control. The bar starts nothing, reads no provider, and knows nothing
/// about where the rows come from. Any future live-update work must be
/// listener-gated — started in `onListen`, stopped in `onCancel` — rather than
/// added here as a periodic tick.
class AuditTrailFilterBar extends StatefulWidget {
  const AuditTrailFilterBar({
    super.key,
    required this.filters,
    required this.whoOptions,
    required this.onChanged,
    this.resultSummary,
    this.onRefresh,
    this.pickRange = showSetDatePicker,
    this.debounce = kAuditTrailSearchDebounce,
  });

  /// The state the page owns.
  final AuditTrailFilters filters;

  /// Every distinct author, from `AuditTrailStore.distinctWho`.
  final List<String> whoOptions;

  /// The one way filter state leaves this bar.
  final ValueChanged<AuditTrailFilters> onChanged;

  /// The line built by [auditTrailResultSummary]. Null while nothing has been
  /// counted — during the first load, or under the denied and unavailable
  /// states, where a count would be a claim about rows nobody read.
  final String? resultSummary;

  /// The page's reload. Null disables the button rather than hiding it.
  final VoidCallback? onRefresh;

  /// Injected so the chip is testable without building a third-party modal.
  final AuditRangePicker pickRange;

  /// Forwarded to [AuditPrefixField].
  final Duration debounce;

  @override
  State<AuditTrailFilterBar> createState() => _AuditTrailFilterBarState();
}

class _AuditTrailFilterBarState extends State<AuditTrailFilterBar> {
  /// `Clear filters` has to empty the box as well as the filter, through the
  /// `GlobalKey<FuzzySearchBarState>.clear()` idiom `alarm.dart` already uses.
  /// `FuzzySearchBar` holds its own `TextEditingController` and takes no
  /// initial value, so this handle is the only way to reach it.
  final GlobalKey<FuzzySearchBarState> _searchBarKey =
      GlobalKey<FuzzySearchBarState>();

  Future<void> _pickRange() async {
    final current = widget.filters.range;
    final picked = await widget.pickRange(
      context,
      current == null
          ? null
          : DateTimeRange(start: current.start, end: current.end),
    );
    // Null is the operator cancelling, which changes nothing. Emitting here
    // would turn a dismissed modal into a fresh query.
    if (picked == null) return;
    widget.onChanged(
      widget.filters.copyWith(
        range: AuditWindow(start: picked.start, end: picked.end),
      ),
    );
  }

  void _clearFilters() {
    _searchBarKey.currentState?.clear();
    widget.onChanged(widget.filters.cleared());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filters = widget.filters;
    final summary = widget.resultSummary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap, not Row: at a narrow window the five controls fold onto a
          // second and third line rather than overflowing the bar.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // A `TextField` has no intrinsic width and a `Wrap` child is
              // free to be as wide as the bar, so the field is bounded here
              // rather than allowed to claim the whole first line.
              //
              // 240 was too narrow for either thing this field holds: the hint
              // (`kAuditTrailPrefixHint`, 26 characters) ellipsised, and the
              // keys people actually search for are longer still --
              // `ST201.MV01.p_par_SealTime` is 25. A search box that cannot
              // show its own placeholder, let alone what you typed, reads as
              // broken. `Wrap` still folds the bar onto another line when the
              // window cannot take the extra width.
              SizedBox(
                width: kAuditTrailPrefixFieldWidth,
                child: AuditPrefixField(
                  key: kAuditTrailPrefixFieldKey,
                  filters: filters,
                  onChanged: widget.onChanged,
                  searchBarKey: _searchBarKey,
                  debounce: widget.debounce,
                ),
              ),
              AuditOutcomeSegments(
                filters: filters,
                onChanged: widget.onChanged,
              ),
              AuditWhoDropdown(
                filters: filters,
                options: widget.whoOptions,
                onChanged: widget.onChanged,
              ),
              _rangeChip(context),
              if (filters.range != null)
                IconButton(
                  key: kAuditTrailClearRangeKey,
                  onPressed: () =>
                      widget.onChanged(filters.copyWith(clearRange: true)),
                  icon: const Icon(Icons.event_busy, size: 18),
                  tooltip: kAuditTrailClearRangeTooltip,
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                key: kAuditTrailRefreshKey,
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: kAuditTrailRefreshTooltip,
                visualDensity: VisualDensity.compact,
              ),
              if (!filters.isDefault)
                TextButton.icon(
                  key: kAuditTrailClearFiltersKey,
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text(kAuditTrailClearFiltersLabel),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.labelMedium,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          AuditGroupChips(filters: filters, onChanged: widget.onChanged),
          if (summary != null) ...[
            const SizedBox(height: 6),
            Text(
              summary,
              key: kAuditTrailResultSummaryKey,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  /// `history_view.dart`'s `_buildDateRangeChip`: an outlined container with a
  /// calendar icon and a `Flexible` ellipsising label, so a long
  /// `start → end` shortens rather than overflowing.
  ///
  /// Its resting label is [kAuditTrailDefaultRangeLabel] — the *name* of the
  /// default window, not a preset. There is no preset menu: CONTEXT leaves the
  /// affordance to discretion "as long as the 7-day default and the 500 cap
  /// hold", and a list of ranges is more surface than this page needs.
  Widget _rangeChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final range = widget.filters.range;

    return InkWell(
      key: kAuditTrailRangeChipKey,
      borderRadius: BorderRadius.circular(6),
      onTap: _pickRange,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline.withAlpha(80)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_today, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                range == null
                    ? kAuditTrailDefaultRangeLabel
                    : auditRangeLabel(range),
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
