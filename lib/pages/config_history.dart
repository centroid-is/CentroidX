/// The configuration history: what changed, who changed it, and what this
/// list cannot tell you.
///
/// SC-4's surface. It watches one resolved [ConfigChangeQuery] per loaded
/// page, renders 04-04's grouped actions through [ConfigActionTile], and
/// states — permanently, on screen — the two things a reader would otherwise
/// have to infer from an absence.
///
/// ## Its own route, at `configure`
///
/// `kRaisedRoutes[kConfigHistoryRoute]` is [AccessGroup.configure]. The audit
/// trail next door is `users` because it displays every write anybody ever
/// made, including the denials that show where a role is configured too
/// tightly. This page displays configuration only, and the engineer it serves
/// — the one who edits pages and key maps — holds `configure`. Widening the
/// existing `users` entry to reach this page would have handed the audit trail
/// to everyone who can edit a page (T-04-06a), so this is a second entry rather
/// than a looser first one.
///
/// **Denied is not built here.** The route gate renders the locked body before
/// this page is reached. A second, weaker check on the page could disagree with
/// the first, and the disagreement would be an open page.
///
/// ## Four things "nothing on screen" can mean, and only one of them is empty
///
/// | On screen | What it means |
/// |---|---|
/// | [kConfigHistoryUnavailableKey] | no database was reached — the history is unavailable, and this page claims nothing about the plant |
/// | [kConfigHistoryEmptyKey] | the query ran and matched no row |
/// | [kConfigHistorySilentNoteKey] | some kinds write no history at all, so their absence from the list is not evidence |
/// | [kConfigHistoryScopeBannerKey] | station-local changes are not in this database and can never appear here |
///
/// The last two are **not** terminal states: they render beside a full list as
/// well as beside an empty one, because that is when they are most needed. An
/// operator who scrolls a populated history and does not find the page image
/// they replaced must not conclude it was never replaced — the log does not
/// know, and 04-04's `EntityHistory.isSilent` exists so the page can say so.
/// Six near-misses in this milestone have been some version of rendering "no
/// history" as "nothing happened".
///
/// ## Nothing on this page moves on its own
///
/// No timer, no scroll listener, no stream — the audit trail's ruling,
/// inherited whole. The page queries on arrival, on an explicit refresh, on a
/// filter change and on an explicit `Load more`, and at no other time.
///
/// ## The Page/Body split is mandatory
///
/// [BaseScaffold] calls `context.currentBeamLocation`, so it cannot be pumped
/// without a Beamer ancestor. Every widget test and every golden pumps
/// [ConfigHistoryBody].
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/config/config_history_policy.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_undo.dart';

import '../core/audit_trail_grouping.dart';
import '../core/config_change_store.dart';
import '../providers/config_history.dart';
import '../widgets/audit_trail_filters.dart'
    show
        kAuditTrailClearFiltersLabel,
        kAuditTrailDefaultRangeLabel,
        kAuditTrailWholeTableLabel,
        auditRangeLabel;
import '../widgets/base_scaffold.dart';
import '../widgets/config_change_row.dart';
import '../widgets/config_undo_dialogs.dart';
import '../widgets/fuzzy_search_bar.dart';

// ---------------------------------------------------------------------------
// The copy
// ---------------------------------------------------------------------------

/// The title over the page, and the words the Advanced menu entry is spelled
/// from.
const String kConfigHistoryTitle = 'Config History';

/// There is no database behind this station, or the read failed.
///
/// **Names no cause on purpose**, on the precedent `kAuditTrailUnavailable`
/// states: `databaseProvider` answers null both when Postgres was never
/// configured and when the connection threw, and a commissioning engineer sent
/// looking for the wrong problem is worse off than one told only that the
/// connection is down.
const String kConfigHistoryUnavailable =
    'The configuration history is unavailable — the database is not reachable.';

/// The query ran, and no row matched. About the filters, never about the table.
const String kConfigHistoryEmptyUnderFilters =
    'No configuration changes match these filters.';

/// What this view is a view **of**, stated permanently rather than inferred.
///
/// C-13: shared configuration lives in Postgres and station-scoped
/// configuration lives in each station's own SQLite, which is never pushed
/// anywhere. A Postgres-backed history therefore cannot show a station-local
/// change — not another station's, and not this one's. Rendered from
/// `ConfigHistoryResult.showsStationScopedChanges`, so the sentence and the
/// fact cannot drift apart.
const String kConfigHistoryScopeNote =
    'Shared configuration only. Changes to a station’s own local settings '
    'are recorded on that station and never appear here — not even this '
    'station’s.';

/// The cap was reached: there are older matching rows this query did not
/// return.
const String kConfigHistoryLimitNote =
    'Showing the newest $kConfigChangeRowLimit changes. Narrow the range or '
    'the filters to see further back.';

/// The explicit paging action. A button, never a scroll position.
const String kConfigHistoryLoadMoreLabel = 'Load more';

/// What the entity search box asks for.
const String kConfigHistoryPrefixHint = 'Search entity ids, e.g. /roe';

/// The tooltip on the refresh control.
const String kConfigHistoryRefreshTooltip = 'Refresh';

/// The control that puts one action back.
const String kConfigHistoryUndoLabel = 'Undo';

/// The tooltip on it — what it will do, in the write's terms.
const String kConfigHistoryUndoTooltip =
    'Write this action’s changes back as they were';

/// Said after an undo lands.
///
/// Names the second half deliberately: an operator who believes an undo erased
/// the original action would be surprised by the history, and the confirmation
/// dialog has already promised this sentence.
const String kConfigHistoryUndoneNote =
    'Undone. The restore is in the history as its own action.';

/// The action's rows are not in the log.
///
/// Distinct from every other refusal, and it is worth its own sentence: the
/// change rows an undo inverts are gone (or were never written, which is what a
/// history-exempt kind does), so there is nothing to name as blocked. Telling
/// an operator "nothing moved" would be a claim this station cannot support.
const String kConfigHistoryUndoNothingToDoNote =
    'This action has no change rows in the log, so there is nothing to put '
    'back.';

/// The kinds that write no `config_change` row at all, said out loud.
///
/// **Derived from `kHistoryExemptKinds` rather than typed out**, so a kind
/// added to the policy updates this sentence instead of quietly falsifying it.
/// The preference clause is spelled here because the exemption on that side is
/// by id (`server_config_envelope`) and not by kind: it is one row, it holds
/// ciphertext, and 04-11 moves it.
///
/// The distinction the sentence exists for: a kind with no rows is the log
/// being **silent**, which is not the same claim as the entity never having
/// changed. Only one of those two is something this page knows.
String configHistorySilentNote() {
  final kinds = kHistoryExemptKinds
      .map((kind) => configKindLabel(kind, plural: true))
      .toList()
    ..sort();
  final subject = kinds.join(', ');
  final capitalised =
      subject.isEmpty ? subject : subject[0].toUpperCase() + subject.substring(1);
  return '$capitalised and the encrypted server settings keep no history: '
      'this list says nothing about whether they changed.';
}

/// One line above the list: how much came back, and over what window.
///
/// The window is named beside the number rather than assumed, because a search
/// drops the time bound entirely — "12 changes" means something different when
/// it is all time.
String configHistoryResultSummary({
  required int rowCount,
  required int actionCount,
  required ConfigHistoryFilters filters,
}) {
  final changes = rowCount == 1 ? '1 change' : '$rowCount changes';
  final actions = actionCount == 1 ? '1 action' : '$actionCount actions';
  return '$changes in $actions · ${configHistoryWindowLabel(filters)}';
}

/// What window [filters] describes, in the words the filter chip uses.
String configHistoryWindowLabel(ConfigHistoryFilters filters) {
  final range = filters.range;
  if (range != null) return auditRangeLabel(range);
  return filters.isSearching
      ? kAuditTrailWholeTableLabel
      : kAuditTrailDefaultRangeLabel;
}

// ---------------------------------------------------------------------------
// The keys
// ---------------------------------------------------------------------------

/// The unavailable screen. Exactly one of this, [kConfigHistoryEmptyKey] and
/// [kConfigHistoryListKey] is on screen at a time, and none of them is while
/// the first query is still out.
const Key kConfigHistoryUnavailableKey =
    ValueKey<String>('config-history-unavailable');

/// The "no rows matched" screen — a statement about the filters.
const Key kConfigHistoryEmptyKey = ValueKey<String>('config-history-empty');

/// The list itself, present only when there is at least one action to draw.
const Key kConfigHistoryListKey = ValueKey<String>('config-history-list');

/// The waiting frame, which is none of the three.
const Key kConfigHistoryLoadingKey = ValueKey<String>('config-history-loading');

/// The permanent scope banner. Present in every state that has a database
/// behind it, populated or not.
const Key kConfigHistoryScopeBannerKey =
    ValueKey<String>('config-history-scope-banner');

/// The line naming the kinds that keep no history.
const Key kConfigHistorySilentNoteKey =
    ValueKey<String>('config-history-silent-note');

/// The filter bar.
const Key kConfigHistoryFilterBarKey =
    ValueKey<String>('config-history-filter-bar');

/// The entity search box.
const Key kConfigHistoryPrefixFieldKey =
    ValueKey<String>('config-history-prefix-field');

/// The author dropdown.
const Key kConfigHistoryWhoDropdownKey =
    ValueKey<String>('config-history-who-dropdown');

/// One kind chip.
Key configHistoryKindChipKey(ConfigKind kind) =>
    ValueKey<String>('config-history-kind-${kind.wireName}');

/// The bar's own `Clear filters`, present only while the filters are not
/// default.
const Key kConfigHistoryClearFiltersKey =
    ValueKey<String>('config-history-clear-filters');

/// The empty state's `Clear filters`, present only while they are.
///
/// Between the two, exactly one such control is on screen in every state —
/// never zero, and never two.
const Key kConfigHistoryEmptyClearFiltersKey =
    ValueKey<String>('config-history-empty-clear-filters');

/// The refresh control.
const Key kConfigHistoryRefreshKey = ValueKey<String>('config-history-refresh');

/// The line carrying [kConfigHistoryLimitNote].
const Key kConfigHistoryLimitNoteKey =
    ValueKey<String>('config-history-limit-note');

/// The `Load more` button, present only while the newest page came back full.
const Key kConfigHistoryLoadMoreKey =
    ValueKey<String>('config-history-load-more');

/// The one-line summary above the list.
const Key kConfigHistorySummaryKey = ValueKey<String>('config-history-summary');

/// One action's Undo control.
///
/// Keyed by action id rather than by index: the list re-sorts and re-pages, and
/// a test that tapped "the undo button in row 2" would be tapping whatever
/// landed there.
Key configHistoryUndoKey(String actionId) =>
    ValueKey<String>('config-history-undo-$actionId');

/// Whether this action can be offered an Undo at all.
///
/// Two conditions, both about what `planUndo` could possibly do with it:
///
///  * **it has change rows.** An action with none is either an audit-only
///    action or one that touched history-exempt entities only, and in both
///    cases the log holds nothing to invert. Offering a button that can only
///    ever answer "there is nothing to put back" would be worse than not
///    offering one.
///  * **every row is shared-scope.** C-13: station-scoped rows live in each
///    station's own SQLite and this view reads Postgres, so a station row
///    cannot appear here — and `planUndo` refuses one by scope regardless. The
///    check is kept anyway rather than left to the refusal, because an Undo
///    button that always refuses is a worse surface than none.
///
/// Judged on the **loaded** rows. An action whose siblings were filtered out
/// still offers Undo, and `planUndo` reads the action whole, so the write is
/// never the partial thing this list is showing.
bool configActionIsUndoable(HistoryAction action) =>
    action.changes.isNotEmpty &&
    action.changes.every((record) => record.change.scope.isShared);

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

/// Route target for `/advanced/config-history`.
///
/// Field-less so `createLocationBuilder` can register it as
/// `const ConfigHistoryPage()`. All of the logic lives in [ConfigHistoryBody].
class ConfigHistoryPage extends StatelessWidget {
  const ConfigHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BaseScaffold(
      title: kConfigHistoryTitle,
      body: ConfigHistoryBody(),
    );
  }
}

/// The page content, split from [ConfigHistoryPage] so tests and goldens can
/// pump it without [BaseScaffold]'s routing context.
class ConfigHistoryBody extends ConsumerStatefulWidget {
  const ConfigHistoryBody({super.key});

  @override
  ConsumerState<ConfigHistoryBody> createState() => ConfigHistoryBodyState();
}

/// Public so a widget test can reach [buildCount].
class ConfigHistoryBodyState extends ConsumerState<ConfigHistoryBody> {
  /// The filter controls' state, as one value.
  ConfigHistoryFilters _filters = const ConfigHistoryFilters();

  /// The **resolved** queries this page is watching, oldest page last.
  ///
  /// Resolved here and never in `build`: `clock.now()` read inside `build`
  /// yields a different `window.end` on every frame, `ConfigChangeQuery ==`
  /// goes false, and the autoDispose family issues a fresh round trip per
  /// painted frame. The audit trail's T-05-67, which this page would
  /// reintroduce for free by being written the obvious way.
  late List<ConfigChangeQuery> _pages;

  /// How many times `build` has run. Read by the query-stability test, which
  /// would otherwise pass vacuously if it failed to trigger a rebuild at all.
  int buildCount = 0;

  @override
  void initState() {
    super.initState();
    _pages = _firstPageOnly(_filters);
  }

  /// Start over from the newest matching row. The only place [clock] is read.
  List<ConfigChangeQuery> _firstPageOnly(ConfigHistoryFilters filters) =>
      <ConfigChangeQuery>[filters.toQuery(now: clock.now())];

  /// A new question starts a new answer.
  void _onFiltersChanged(ConfigHistoryFilters next) {
    setState(() {
      _filters = next;
      _pages = _firstPageOnly(next);
    });
  }

  /// Refresh means "show me the current newest".
  ///
  /// The reset alone is not enough: under a clock that has not visibly moved
  /// the freshly resolved query equals the old one and the family answers from
  /// cache. The invalidate names the queries about to be watched rather than
  /// the whole family, so it does not re-execute the `Load more` pages this
  /// reset has just discarded.
  void _refresh() {
    final fresh = _firstPageOnly(_filters);
    setState(() {
      _pages = fresh;
    });
    for (final query in fresh) {
      ref.invalidate(configHistoryActionsProvider(query));
    }
  }

  /// Append one page of strictly older rows. A button, never infinite scroll.
  ///
  /// The window is carried over from the head query rather than re-derived from
  /// the clock: re-reading it would move the window's *start* forward by
  /// however long the page has been open, silently skipping the oldest rows —
  /// which are the ones this button was tapped to see.
  void _loadMore(DateTime? oldestAt, int? oldestId) {
    if (oldestAt == null) return;
    final head = _pages.first;
    setState(() {
      _pages = <ConfigChangeQuery>[
        ..._pages,
        ConfigChangeQuery(
          window: head.window,
          before: oldestAt,
          beforeId: oldestId,
          entityPrefix: head.entityPrefix,
          who: head.who,
          kinds: head.kinds,
          scopeWireNames: head.scopeWireNames,
          limit: head.limit,
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    buildCount++;

    final pages = <AsyncValue<ConfigHistoryResult?>>[
      for (final query in _pages) ref.watch(configHistoryActionsProvider(query)),
    ];

    // Unavailable is a resolved null or an error; still loading is neither and
    // says nothing yet. Taken over every page: if any part of what is on screen
    // failed to read, the page cannot claim the list is complete.
    final unavailable = pages.any(
      (page) => page.hasError || (page.hasValue && page.requireValue == null),
    );
    if (unavailable) return _unavailable(context);
    if (!pages.first.hasValue) return _loading();

    final resolved = <ConfigHistoryResult>[
      for (final page in pages)
        if (page.hasValue) page.requireValue!,
    ];
    final actions = <HistoryAction>[
      for (final result in resolved) ...result.actions,
    ];
    // The number the `LIMIT` applied to, not `actions.length`: nine rows of one
    // page save are one action, and it is the nine that the cap counted.
    final rowCount =
        resolved.fold<int>(0, (sum, result) => sum + result.changeRowCount);
    final tail = resolved.last;
    final pending = pages.any((page) => !page.hasValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: _filterBar(context, actions),
        ),
        // Above the list and above the empty message alike: the two sentences
        // are about what this view *is*, and they are needed most when the list
        // is full and looks complete.
        _banner(context, showsStationScoped: tail.showsStationScopedChanges),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            configHistoryResultSummary(
              rowCount: rowCount,
              actionCount: actions.length,
              filters: _filters,
            ),
            key: kConfigHistorySummaryKey,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        if (actions.isEmpty)
          Expanded(child: _empty(context))
        else
          Expanded(child: _list(actions)),
        if (actions.isNotEmpty && tail.reachedLimit) ...[
          _limitNote(context),
          _loadMoreButton(pending ? null : tail.oldestAt, tail.oldestId),
        ],
      ],
    );
  }

  /// A progress indicator rather than an empty box: this route is reached
  /// deliberately, and a blank page reads as broken. Carries none of the three
  /// terminal keys, which is the assertion the goldens rest on.
  Widget _loading() => const Center(
        key: kConfigHistoryLoadingKey,
        child: CircularProgressIndicator(),
      );

  /// No filter bar and no banner here: there is nothing to filter, and a
  /// sentence about what this view shows would be describing a view that is not
  /// showing anything. That absence is also what stops this screen looking like
  /// the empty one.
  Widget _unavailable(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: kConfigHistoryUnavailableKey,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text(kConfigHistoryUnavailable, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  /// The message, and the `Clear filters` the bar above cannot render.
  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: kConfigHistoryEmptyKey,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_alt_off,
                  size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text(
                kConfigHistoryEmptyUnderFilters,
                textAlign: TextAlign.center,
              ),
              if (_filters.isDefault) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  key: kConfigHistoryEmptyClearFiltersKey,
                  onPressed: () => _onFiltersChanged(_filters.cleared()),
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text(kAuditTrailClearFiltersLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The two sentences this page owes a reader whatever the list holds.
  ///
  /// [showsStationScoped] comes from the read model rather than from a literal,
  /// so the day station-scoped rows do reach this database the sentence stops
  /// being printed instead of becoming a lie.
  ///
  /// The divider is `onSurface` at low alpha: `colorScheme.outline` is unset in
  /// both of this app's schemes and resolves to something invisible on the dark
  /// one.
  Widget _banner(BuildContext context, {required bool showsStationScoped}) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Container(
      key: kConfigHistoryScopeBannerKey,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.18),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!showsStationScoped)
                  Text(kConfigHistoryScopeNote, style: style),
                Text(
                  configHistorySilentNote(),
                  key: kConfigHistorySilentNoteKey,
                  style: style,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The virtualised list.
  ///
  /// No `itemExtent` and no `prototypeItem`: an action is an `ExpansionTile`
  /// whose height changes when it opens, and a fixed extent would clip it.
  /// `ListView.builder` is what keeps a 500-row result from building every tile
  /// in one frame.
  /// The virtualised list, each action beside its Undo.
  ///
  /// The control is **composed next to** [ConfigActionTile] rather than added
  /// inside it: the tile is the history's read-only rendering and is shared
  /// with the goldens 04-06 already baselined, and threading an action callback
  /// through it would put a write concern into the widget that draws a row.
  ///
  /// `CrossAxisAlignment.start` pins the button to the header line, so it does
  /// not drift to the vertical middle of a tile the operator has expanded.
  Widget _list(List<HistoryAction> actions) => ListView.builder(
        key: kConfigHistoryListKey,
        itemCount: actions.length,
        itemBuilder: (context, index) {
          final action = actions[index];
          // Keyed by the action, not by position: an undo prepends a new
          // action and shifts every other one down, and an unkeyed list would
          // hand each shifted action the State — expansion, cached diff — of
          // the one that used to sit at its index.
          return Row(
            key: ValueKey(action.actionId),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: ConfigActionTile(action: action)),
              if (configActionIsUndoable(action))
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: Tooltip(
                    message: kConfigHistoryUndoTooltip,
                    child: TextButton.icon(
                      key: configHistoryUndoKey(action.actionId),
                      // Disabled while one is in flight, rather than guarded on
                      // the way in: a second tap must look refused, not
                      // ignored.
                      onPressed:
                          _undoInFlight == null ? () => _undo(action) : null,
                      icon: const Icon(Icons.undo, size: 16),
                      label: const Text(kConfigHistoryUndoLabel),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  // -------------------------------------------------------------------------
  // Undo
  // -------------------------------------------------------------------------

  /// The action currently being undone, or null. One at a time: two undos in
  /// flight against overlapping entities would have the second refused by the
  /// compare-and-swap for a reason the operator did not cause.
  String? _undoInFlight;

  /// Plan it, ask whether this session may, confirm it, write it, show it.
  ///
  /// Every branch that stops short says why, and none of them stops silently.
  /// The gate is checked **before** the confirmation opens — a dialog an
  /// operator cannot finish is a worse refusal than an immediate one — and the
  /// real enforcement is inside `executeUndo` regardless (T-04-10a).
  Future<void> _undo(HistoryAction action) async {
    // Two taps in one frame both reach the callback the frame was built with;
    // the disabled button is a frame late. One undo at a time is the rule,
    // and this is where it is enforced.
    if (_undoInFlight != null) return;
    final controller = ref.read(configUndoControllerProvider);
    setState(() => _undoInFlight = action.actionId);
    try {
      final plan = await controller.plan(action.actionId);
      if (!mounted) return;

      if (plan == null) {
        _note(kConfigHistoryUnavailable);
        return;
      }
      if (plan.isUnknownAction) {
        _note(kConfigHistoryUndoNothingToDoNote);
        return;
      }
      if (!plan.isReady) {
        await _showBlocked(plan.blockers);
        return;
      }
      // The standard treatment: the operator gets the app's own denial prompt,
      // the trail gets a refused row, and nothing is issued to the store.
      if (!controller.mayUndo(plan)) {
        await controller.refuse(plan);
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => ConfigUndoConfirmDialog(plan: plan),
      );
      if (confirmed != true || !mounted) return;

      final outcome = await controller.execute(plan);
      if (!mounted) return;
      switch (outcome) {
        case UndoDone():
          // No optimistic edit anywhere: the list is re-read from the store,
          // so what is on screen afterwards is what the database holds.
          _refresh();
          _note(kConfigHistoryUndoneNote);
        case UndoBlocked(:final blockers):
          await _showBlocked(blockers);
        case UndoDenied():
          // Already prompted and already recorded by the controller. A second
          // message here would be the same refusal told twice.
          break;
        case UndoUnavailable(:final message):
          _note(message);
      }
    } on Object catch (error) {
      // Everything the controller does not classify: a driver error out of
      // the store's transaction, an argument error, a plan that could not be
      // read. Left to escape, it landed in an async void handler and the
      // operator saw a button that did nothing — and tapped it again.
      if (mounted) _note('Undo failed: $error');
    } finally {
      if (mounted) {
        setState(() => _undoInFlight = null);
      } else {
        _undoInFlight = null;
      }
    }
  }

  Future<void> _showBlocked(List<UndoBlocker> blockers) => showDialog<void>(
        context: context,
        builder: (_) => ConfigUndoBlockedDialog(blockers: blockers),
      );

  /// One line to the operator. A snackbar and not a dialog: none of these needs
  /// an answer.
  void _note(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Under the list, not over it: the cap is a fact about the bottom of the
  /// result, and the operator reads it when they get there.
  Widget _limitNote(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Text(
        kConfigHistoryLimitNote,
        key: kConfigHistoryLimitNoteKey,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// The only way past the cap, and it is a tap.
  Widget _loadMoreButton(DateTime? oldestAt, int? oldestId) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: kConfigHistoryLoadMoreKey,
            onPressed: oldestAt == null
                ? null
                : () => _loadMore(oldestAt, oldestId),
            icon: const Icon(Icons.expand_more, size: 16),
            label: const Text(kConfigHistoryLoadMoreLabel),
          ),
        ),
      );

  // -------------------------------------------------------------------------
  // The filter bar
  // -------------------------------------------------------------------------

  /// The audit trail's filter shapes, over this table's columns.
  ///
  /// Kept in this file rather than lifted into a shared widget: every control
  /// in `audit_trail_filters.dart` is typed on `AuditTrailFilters`, and making
  /// them generic to share four of them would touch a page this plan is not
  /// changing.
  Widget _filterBar(BuildContext context, List<HistoryAction> actions) {
    return Column(
      key: kConfigHistoryFilterBarKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SizedBox(
              width: 360,
              child: FuzzySearchBar(
                key: kConfigHistoryPrefixFieldKey,
                hintText: kConfigHistoryPrefixHint,
                onChanged: (raw) =>
                    _onFiltersChanged(_filters.copyWith(entityPrefix: raw.trim())),
              ),
            ),
            const SizedBox(width: 12),
            _whoDropdown(context, actions),
            const Spacer(),
            if (!_filters.isDefault)
              TextButton.icon(
                key: kConfigHistoryClearFiltersKey,
                onPressed: () => _onFiltersChanged(_filters.cleared()),
                icon: const Icon(Icons.filter_alt_off, size: 16),
                label: const Text(kAuditTrailClearFiltersLabel),
              ),
            IconButton(
              key: kConfigHistoryRefreshKey,
              tooltip: kConfigHistoryRefreshTooltip,
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final kind in ConfigKind.values) _kindChip(context, kind),
          ],
        ),
      ],
    );
  }

  /// The `who` filter, over the authors **in the loaded rows**.
  ///
  /// `ConfigChangeStore` has no `SELECT DISTINCT who` — the audit trail has
  /// one, and adding its twin here is a store change this plan does not make.
  /// The consequence is stated rather than hidden: this dropdown offers the
  /// people whose changes are on screen, so narrowing by someone who has not
  /// written in the loaded window means widening the window first. The
  /// currently selected author is always among the options, so a filter that
  /// outlives the rows that suggested it cannot assert inside
  /// `DropdownButton`.
  Widget _whoDropdown(BuildContext context, List<HistoryAction> actions) {
    final scheme = Theme.of(context).colorScheme;
    final options = <String>{
      for (final action in actions)
        for (final record in action.changes) record.change.who,
      if (_filters.who != null) _filters.who!,
    }.toList()
      ..sort();

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
      child: DropdownButton<String?>(
        key: kConfigHistoryWhoDropdownKey,
        value: _filters.who,
        underline: const SizedBox.shrink(),
        isDense: true,
        isExpanded: true,
        icon: Icon(Icons.unfold_more, size: 16, color: scheme.onSurfaceVariant),
        onChanged: (who) => _onFiltersChanged(
          who == null
              ? _filters.copyWith(clearWho: true)
              : _filters.copyWith(who: who),
        ),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(
              'Anyone',
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
              child: Text(who,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }

  /// One kind chip.
  ///
  /// **A history-exempt kind's chip is disabled rather than absent.** Selecting
  /// it could only ever return nothing, and an operator who filtered to page
  /// images and saw an empty list would read it as "no page image ever
  /// changed". Leaving the chip out entirely has the same failure one step
  /// removed — the kind simply would not be mentioned. Disabled, with
  /// [kConfigHistorySilentNoteKey] in the banner above saying why, is the only
  /// arrangement in which the reader is told the difference between a kind with
  /// no changes and a kind with no history.
  ///
  /// An empty `kinds` list means **no constraint**, so every chip renders
  /// selected; the first tap therefore deselects one rather than selecting one,
  /// which is `AuditGroupChips`' convention and `AlarmLevelFilterChips`' before
  /// it.
  Widget _kindChip(BuildContext context, ConfigKind kind) {
    final theme = Theme.of(context);
    final exempt = kHistoryExemptKinds.contains(kind);
    final selected = !exempt &&
        (_filters.kinds.isEmpty || _filters.kinds.contains(kind));

    return Tooltip(
      message: exempt ? configHistorySilentNote() : '',
      child: FilterChip(
        key: configHistoryKindChipKey(kind),
        label: Text(configKindLabel(kind, plural: true)),
        labelStyle: theme.textTheme.labelSmall,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        selected: selected,
        onSelected: exempt ? null : (next) => _onKindToggled(kind, next),
      ),
    );
  }

  /// Toggling one kind, with "empty means all" preserved on both edges.
  ///
  /// The exempt kinds are never in the emitted set: they are not selectable, so
  /// an "all selected" state that included them would send the store a
  /// constraint naming kinds that can never match.
  void _onKindToggled(ConfigKind kind, bool next) {
    final selectable = ConfigKind.values
        .where((k) => !kHistoryExemptKinds.contains(k))
        .toList();
    final current = _filters.kinds.isEmpty
        ? selectable.toSet()
        : _filters.kinds.toSet();
    final updated = next ? (current..add(kind)) : (current..remove(kind));
    // Back to "no constraint" once everything selectable is selected again, so
    // the default value and the all-chips-on value are the same value.
    final kinds = updated.length == selectable.length
        ? const <ConfigKind>[]
        : selectable.where(updated.contains).toList();
    _onFiltersChanged(_filters.copyWith(kinds: kinds));
  }
}
