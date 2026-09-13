/// The audit trail: one page, one query, and three ways to have nothing to
/// show.
///
/// The first and only reader's screen. It watches one resolved [AuditQuery] per
/// loaded page, renders 05-05's filter bar above a virtualised list of 05-04's
/// grouped actions, and distinguishes the states that would otherwise all look
/// like a blank screen.
///
/// ## The three terminal states, and why they are three
///
/// Phase 2 ruled that **unavailable** and **empty** must be distinguishable.
/// An empty list drawn over an unreachable database asserts that nothing was
/// ever written on this station — which is the one lie an audit trail cannot
/// tell, and the reason `auditTrailEntriesProvider` answers a nullable
/// [AuditTrailResult] rather than a nullable list.
///
/// **Denied** is the third, and it is deliberately not built here. The route
/// gate renders the locked body before this page is reached, from
/// `kRaisedRoutes['/advanced/audit-trail']`. A second, weaker check on this page
/// could disagree with the first, and the disagreement would be an open page —
/// threat T-05-60. A test in `test/pages/audit_trail_test.dart` reads this
/// file's source with the comments stripped and fails if the permission enum or
/// the locked body is ever named in the code.
///
/// **Loading is none of the three.** Waiting says nothing yet, in exactly the
/// sense `access_gate.dart` already carries for its own three-way. A frame that
/// renders "No entries match these filters" before the query returns is a page
/// that lies for one frame, and a golden that captured such a frame would bake
/// the lie in.
///
/// ## Nothing on this page moves on its own
///
/// No timer, no scroll listener, no stream. The page queries on arrival, on an
/// explicit refresh, on a filter change and on an explicit `Load more`, and at
/// no other time. That is CONTEXT's ruling and it has two reasons: an always-on
/// `Timer.periodic` in this repo's plumbing has broken unrelated widget tests,
/// and an audit list that scrolls or reloads under the finger is unreadable
/// while you are trying to read a row off it. A comment-stripped grep in the
/// test file enforces the absence.
///
/// ## The Page/Body split is mandatory
///
/// `BaseScaffold` calls `context.currentBeamLocation`, so it cannot be pumped
/// without a Beamer ancestor. `FirstUserPage`/`FirstUserBody` and
/// `KeyRepositoryPage`/`KeyRepositoryContent` are the same split for the same
/// reason, and every widget test and every golden of this page pumps the Body.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audit_trail_grouping.dart';
import '../core/audit_trail_store.dart';
import '../providers/audit_trail.dart';
import '../widgets/audit_trail_filters.dart';
import '../widgets/audit_trail_row.dart';
import '../widgets/base_scaffold.dart';

// ---------------------------------------------------------------------------
// The copy
// ---------------------------------------------------------------------------

/// The title over the page, and the one word the Advanced menu entry is spelled
/// from.
const String kAuditTrailTitle = 'Audit Trail';

/// There is no database behind this station, or the read failed.
///
/// **Names no cause on purpose.** `databaseProvider` answers null both when
/// Postgres was never configured and when the connection threw, and the two are
/// indistinguishable by design — `lib/access_routes.dart` refuses to guess
/// between them in as many words, and `kAccessLockedNoDatabaseNote` and
/// `first_user.dart`'s `_kNoDatabase` both carry the same refusal. A
/// commissioning engineer sent looking for the wrong problem is worse off than
/// one told only that the connection is down.
///
/// Deliberately distinct from [kAuditTrailEmptyUnderFilters]: that one says the
/// query ran and matched nothing, and this one says no query ran at all. The
/// two must never be able to render in each other's place.
const String kAuditTrailUnavailable =
    'The trail is unavailable — the database is not reachable.';

/// The query ran, and no row matched.
///
/// **About the filters, never about the table.** CONTEXT's deferred list
/// records a fourth terminal state that would distinguish a genuinely empty
/// table ("Nothing has been recorded on this station yet") from "no rows match
/// these filters". This phase does not ship it, so this wording must claim
/// nothing whatever about what the table holds — the filter bar stays on screen
/// above it precisely so the operator can see and undo what excluded
/// everything.
///
/// Deliberately distinct from [kAuditTrailUnavailable]: this one is a real
/// answer from a database that was reached.
const String kAuditTrailEmptyUnderFilters = 'No entries match these filters.';

/// The cap was reached, so there are older matching rows this query did not
/// return.
///
/// Deliberately distinct from both of the above, and not a terminal state at
/// all: it renders *with* a full list rather than instead of one. The 500-row
/// cap exists to be visible rather than to be worked around silently (T-05-65),
/// so the page says the number out loud and names the two ways to see further
/// back.
const String kAuditTrailLimitNote =
    'Showing the newest $kAuditTrailRowLimit entries. Narrow the range or the '
    'filters to see further back.';

/// The explicit paging action. A button, never a scroll position.
const String kAuditTrailLoadMoreLabel = 'Load more';

// ---------------------------------------------------------------------------
// The keys
// ---------------------------------------------------------------------------

/// The unavailable screen. Exactly one of this, [kAuditTrailEmptyKey] and
/// [kAuditTrailListKey] is on screen at a time, and none of them is while the
/// first query is still out.
const Key kAuditTrailUnavailableKey =
    ValueKey<String>('audit-trail-unavailable');

/// The "no rows matched" screen — a statement about the filters, not about the
/// table.
const Key kAuditTrailEmptyKey = ValueKey<String>('audit-trail-empty');

/// The list itself, present only when there is at least one action to draw.
const Key kAuditTrailListKey = ValueKey<String>('audit-trail-list');

/// The sticky column header above the list. Present only when there are rows:
/// an empty result shows [kAuditTrailEmptyKey] and a heading over nothing would
/// be furniture.
const Key kAuditTrailHeaderKey = ValueKey<String>('audit-trail-header');

/// The waiting frame. Its own key so 05-08's goldens can assert which state
/// they captured before capturing it.
const Key kAuditTrailLoadingKey = ValueKey<String>('audit-trail-loading');

/// The empty state's own `Clear filters`.
///
/// 05-05's bar renders one only while the filters are *not* default; this one
/// renders only while they are. Between them exactly one such control is on
/// screen in every state — never zero, and never two.
const Key kAuditTrailEmptyClearFiltersKey =
    ValueKey<String>('audit-trail-empty-clear-filters');

/// The line carrying [kAuditTrailLimitNote].
const Key kAuditTrailLimitNoteKey = ValueKey<String>('audit-trail-limit-note');

/// The `Load more` button. Present only while the newest page came back full.
const Key kAuditTrailLoadMoreKey = ValueKey<String>('audit-trail-load-more');

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

/// Route target for `/advanced/audit-trail`.
///
/// Field-less on purpose so `createLocationBuilder` can register it as
/// `const AuditTrailPage()`. All of the logic lives in [AuditTrailBody].
class AuditTrailPage extends StatelessWidget {
  const AuditTrailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BaseScaffold(
      title: kAuditTrailTitle,
      body: AuditTrailBody(),
    );
  }
}

/// The page content, split from [AuditTrailPage] so tests and goldens can pump
/// it without [BaseScaffold]'s routing context.
///
/// [BaseScaffold] calls `context.currentBeamLocation`, so it cannot be pumped
/// without a Beamer ancestor. `FirstUserBody` and `KeyRepositoryContent` are
/// the same split for the same reason.
class AuditTrailBody extends ConsumerStatefulWidget {
  const AuditTrailBody({super.key});

  @override
  ConsumerState<AuditTrailBody> createState() => AuditTrailBodyState();
}

/// Public so a widget test can reach [buildCount].
class AuditTrailBodyState extends ConsumerState<AuditTrailBody> {
  /// The filter controls' state, as one value. The bar holds none of it and
  /// emits a whole new value through `onChanged`.
  AuditTrailFilters _filters = const AuditTrailFilters();

  /// The **resolved** queries this page is watching, oldest page last.
  ///
  /// `build` watches each element and concatenates the resulting actions in
  /// order. There is no `ref.listen`, no `addPostFrameCallback` and no mutable
  /// row buffer, because appending rows during `build` would append them again
  /// on every rebuild (T-05-68).
  ///
  /// **The resolution happens here and never in `build`.** This is not a style
  /// preference. `clock.now()` called inside `build` yields a `window.end`
  /// microseconds later on every frame, so `AuditQuery ==` goes false, the
  /// autoDispose family creates a new instance and disposes the old one, and
  /// the page issues a fresh `entries` plus `memberCountsByAction` round trip
  /// *per painted frame*. That is threat T-05-21 reintroduced at the page
  /// layer — T-05-67 — and a test that freezes the clock cannot see it, which
  /// is why the regression guard in the test file runs under the live clock.
  /// The `==` that 05-03 tests is only load-bearing if the argument is stable,
  /// and making it stable is this file's job.
  late List<AuditQuery> _pages;

  /// How many times `build` has run. Read by the query-stability test, which
  /// would otherwise pass vacuously if it failed to trigger a rebuild at all.
  int buildCount = 0;

  @override
  void initState() {
    super.initState();
    _pages = _firstPageOnly(_filters);
  }

  /// Start over from the newest matching row.
  ///
  /// The single place `_pages` is reduced to one element, and the only place
  /// [clock] is read. Three callers, and all three need it:
  ///
  /// - `initState`, so the page issues its opening query on arrival;
  /// - the refresh callback, because a refresh that kept the old pages would
  ///   show stale rows above fresh ones with no boundary between them;
  /// - the filter-changed callback, because a filter change that kept them
  ///   would leave rows on screen that the new filter excludes.
  ///
  /// `clock.now()` rather than `DateTime.now()`, so a test can freeze it with
  /// `withClock` and assert the seven-day window exactly rather than
  /// approximately.
  List<AuditQuery> _firstPageOnly(AuditTrailFilters filters) =>
      <AuditQuery>[filters.toQuery(now: clock.now())];

  /// A new question starts a new answer.
  void _onFiltersChanged(AuditTrailFilters next) {
    setState(() {
      _filters = next;
      _pages = _firstPageOnly(next);
    });
  }

  /// Refresh means "show me the current newest", not "show me the same stale
  /// page again".
  ///
  /// The reset alone is not enough: under a clock that has not visibly moved,
  /// the freshly resolved query equals the old one and the family would answer
  /// from cache. The invalidate is what makes the round trip happen; the reset
  /// is what stops the accumulated older pages surviving it.
  ///
  /// The invalidation names the queries that are about to be watched rather
  /// than the whole family. Invalidating the family would also re-execute the
  /// `Load more` pages this reset has just discarded — they are still alive
  /// until the rebuild drops them, so a whole-family invalidate spends a
  /// database round trip on rows nobody will ever see, and leaves the last
  /// statement the page issued being one for a page it had already thrown
  /// away.
  void _refresh() {
    final fresh = _firstPageOnly(_filters);
    setState(() {
      _pages = fresh;
    });
    for (final query in fresh) {
      ref.invalidate(auditTrailEntriesProvider(query));
    }
    // Kept alive across visits, so refresh is what picks up a name that has
    // written its first row since.
    ref.invalidate(auditWhoOptionsProvider);
  }

  /// Append one page of strictly older rows.
  ///
  /// **A button, and never infinite scroll.** CONTEXT rules it explicitly, and
  /// the reason underneath the ruling is that an audit list which loads as you
  /// scroll never has a stable position to read a row off — the thing you were
  /// looking at moves while you look at it. The 500-row cap exists to be
  /// *visible* rather than to be worked around silently, so the note above this
  /// button says the number and this button is the only way past it. A
  /// scroll-position listener that pre-fetched would be infinite scroll wearing
  /// a button's clothes, and the comment-stripped grep in the test file forbids
  /// the listener it would need (T-05-66).
  ///
  /// It appends a **query** to [_pages]. Nothing appends rows anywhere: `build`
  /// watches every element and concatenates their actions in order, so the
  /// newly fetched actions arrive beneath what is already on screen, the list
  /// does not reset to the top, and a rebuild that adds no page leaves the row
  /// count exactly where it was. Appending rows inside `build` would append
  /// them again on every frame (T-05-68).
  ///
  /// The cursor lives inside the last element of [_pages] rather than in a
  /// free-standing `_before` field, which is the only place it could go stale
  /// without also going unwatched.
  ///
  /// **The window is carried over from the head query rather than re-derived
  /// from the clock.** Re-reading the clock here would move the window's
  /// *start* forward by however long the page had been open, and the rows
  /// between the old start and the new one are exactly the oldest ones — the
  /// ones this button was tapped to see. A page left open for an hour would
  /// silently skip an hour of history, which is the same class of
  /// wrong-answer-that-looks-right the whole-table search escape exists to
  /// prevent. Everything else is carried through untouched too, so paging
  /// narrows the window the filters produced rather than replacing the rule
  /// that produced it.
  void _loadMore(DateTime? oldestAt) {
    if (oldestAt == null) return;
    final head = _pages.first;
    setState(() {
      _pages = <AuditQuery>[
        ..._pages,
        AuditQuery(
          window: head.window,
          before: oldestAt,
          keyPrefix: head.keyPrefix,
          who: head.who,
          groupNames: head.groupNames,
          includeAuth: head.includeAuth,
          outcome: head.outcome,
          limit: head.limit,
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    buildCount++;

    // An unreachable database gives an empty option list rather than an error,
    // by design in 05-03: the page already says "unavailable" once, and saying
    // it twice in two shapes is not more honest.
    final whoOptions =
        ref.watch(auditWhoOptionsProvider).valueOrNull ?? const <String>[];

    // One `ref.watch` per loaded page, keyed on the query the bar's last
    // emission produced. Every filter is pushed into SQL by
    // `AuditTrailFilters.toQuery` and this page filters nothing in memory:
    // filtering the loaded rows would show three denials while the table held
    // three hundred.
    final pages = <AsyncValue<AuditTrailResult?>>[
      for (final query in _pages) ref.watch(auditTrailEntriesProvider(query)),
    ];

    // Unavailable is a resolved null or an error; still loading is neither, and
    // says nothing yet. The three-way `access_gate.dart` already carries.
    //
    // Taken over every page rather than only the first: if any part of what is
    // on screen failed to read, the page cannot claim the list is complete, and
    // a failed read is not entitled to make a claim about the plant's history.
    final unavailable = pages.any(
      (page) => page.hasError || (page.hasValue && page.requireValue == null),
    );
    if (unavailable) return _unavailable(context);

    // Only the *first* page gates the whole screen. A later page still in
    // flight leaves the rows already on screen where they are — hiding them
    // would throw away the reading position that paging further back exists to
    // keep.
    if (!pages.first.hasValue) return _loading();

    final resolved = <AuditTrailResult>[
      for (final page in pages)
        if (page.hasValue) page.requireValue!,
    ];
    final actions = <AuditAction>[
      for (final result in resolved) ...result.actions,
    ];
    // The number the `LIMIT` applied to, not `actions.length`: eight rows of
    // one struct write are one action, and it is the eight that the cap
    // counted.
    final rowCount =
        resolved.fold<int>(0, (sum, result) => sum + result.rowCount);
    final tail = resolved.last;
    // True while a `Load more` page is still in flight. The button is disabled
    // rather than hidden for its duration, so it does not flicker out from
    // under the finger that just tapped it and a second tap cannot append the
    // same cursor twice.
    final pending = pages.any((page) => !page.hasValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: AuditTrailFilterBar(
            filters: _filters,
            whoOptions: whoOptions,
            // One line, above the list, stating the count *and* the window it
            // was counted over. `auditTrailResultSummary` says "All time" once
            // the query escaped the seven-day bound, which is the whole reason
            // the window is named beside the number rather than assumed.
            resultSummary: auditTrailResultSummary(
              count: rowCount,
              filters: _filters,
            ),
            onChanged: _onFiltersChanged,
            onRefresh: _refresh,
          ),
        ),
        if (actions.isEmpty)
          Expanded(child: _empty(context))
        else ...[
          _header(context),
          Expanded(child: _list(actions)),
        ],
        if (actions.isNotEmpty && tail.reachedLimit) ...[
          _limitNote(context),
          _loadMoreButton(pending ? null : tail.oldestAt),
        ],
      ],
    );
  }

  /// A progress indicator rather than an empty box: this route is reached
  /// deliberately, and a blank page reads as broken.
  ///
  /// Carries none of the three terminal keys, which is the assertion 05-08's
  /// goldens rest on.
  Widget _loading() => const Center(
        key: kAuditTrailLoadingKey,
        child: CircularProgressIndicator(),
      );

  /// No filter bar here: there is nothing to filter, and a bar over an
  /// unreachable database would offer controls that cannot change the answer.
  Widget _unavailable(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: kAuditTrailUnavailableKey,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text(kAuditTrailUnavailable, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  /// The message, and the `Clear filters` the bar above cannot render.
  ///
  /// 05-05's bar shows its own `Clear filters` only while the filters are not
  /// default. That leaves exactly one case uncovered — an empty result under
  /// the filters the page opened with — and this covers it, so the count on
  /// screen is one in every state rather than zero in this one.
  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: kAuditTrailEmptyKey,
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
                kAuditTrailEmptyUnderFilters,
                textAlign: TextAlign.center,
              ),
              if (_filters.isDefault) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  key: kAuditTrailEmptyClearFiltersKey,
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

  /// The virtualised list.
  ///
  /// No `itemExtent` and no `prototypeItem`: a multi-member action is an
  /// `ExpansionTile` whose height changes when it opens, and a fixed extent
  /// would clip it. `history_table_pane.dart`'s `itemExtent: 32.0` is the right
  /// shape for a table of fixed rows and the wrong one here.
  ///
  /// The column header, above the scroll view rather than inside it.
  ///
  /// Sticky by construction: it is a sibling of the `Expanded` list in the same
  /// `Column`, so the rows scroll under it and it cannot scroll away. Putting it
  /// in the `ListView` as index 0 would have scrolled it off, which is exactly
  /// what a header is for avoiding.
  ///
  /// The widths are the row's own constants -- [kAuditTimeColumnWidth],
  /// [kAuditWhoColumnWidth], the flex 3 / flex 2 split and [kAuditColumnGap] --
  /// so the header cannot drift out of alignment with the rows it names.
  ///
  /// No label over the trailing origin chip: that column is the chip's own
  /// width rather than a fixed one, and a heading that does not line up is
  /// worse than none. No label over the mark either -- it is a 4px colour bar,
  /// and the legend for it belongs beside the filters, not here.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    Widget cell(String label) => Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );

    return Container(
      key: kAuditTrailHeaderKey,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: kAuditMarkWidth),
          const SizedBox(width: kAuditColumnGap),
          SizedBox(width: kAuditTimeColumnWidth, child: cell('Time')),
          const SizedBox(width: kAuditColumnGap),
          SizedBox(width: kAuditWhoColumnWidth, child: cell('Who')),
          const SizedBox(width: kAuditColumnGap),
          Expanded(flex: 3, child: cell('Item')),
          const SizedBox(width: kAuditColumnGap),
          Expanded(flex: 2, child: cell('Change')),
        ],
      ),
    );
  }

  /// `ListView.builder` is what keeps a 500-action result from building 500
  /// tiles in one frame (T-05-64).
  Widget _list(List<AuditAction> actions) => ListView.builder(
        key: kAuditTrailListKey,
        itemCount: actions.length,
        itemBuilder: (context, index) =>
            AuditActionTile(action: actions[index]),
      );

  /// Under the list, not over it: the cap is a fact about the bottom of the
  /// result, and the operator reads it when they get there.
  Widget _limitNote(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Text(
        kAuditTrailLimitNote,
        key: kAuditTrailLimitNoteKey,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// The only way past the cap, and it is a tap.
  Widget _loadMoreButton(DateTime? oldestAt) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: kAuditTrailLoadMoreKey,
            onPressed: oldestAt == null ? null : () => _loadMore(oldestAt),
            icon: const Icon(Icons.expand_more, size: 16),
            label: const Text(kAuditTrailLoadMoreLabel),
          ),
        ),
      );
}
