import 'dart:async';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../widgets/base_scaffold.dart';
import '../widgets/proposal_visual.dart';
import '../providers/proposal_state.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/config/config_item.dart' show ConfigItem;
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import '../widgets/fuzzy_search_bar.dart';
import '../widgets/bit_mask_grid.dart';
import '../widgets/key_mapping_sections.dart';
import '../providers/access_templates.dart';
import '../providers/preferences.dart';
import '../providers/state_man.dart';
import '../providers/database.dart';
import '../providers/config_store.dart';
import 'access_templates_section.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessTemplate, TagBindingResolver;

/// Extension to find a [ModbusConfig] by server alias without nullable cast.
extension ModbusConfigListExt on List<ModbusConfig> {
  ModbusConfig? findByAlias(String? alias) {
    if (alias == null) return null;
    for (final c in this) {
      if (c.serverAlias == alias) return c;
    }
    return null;
  }
}

enum _KeyStatus { ok, error, serverDisconnected, serverDisabled }

/// Everything on this page that is not the key list: the database banner, the
/// key section's own header and save row, the access-templates section and the
/// import/export card. Measured at 800x600.
///
/// **Measured on a station with no database**, which is the case the tests and
/// the goldens run. 04-08 re-measured the other end and left the number alone,
/// on purpose:
///
/// | State | Chrome |
/// |---|---|
/// | no database (this constant) | 516 |
/// | database, one template | 592 |
/// | database, templates list at its 168 px cap | 696 |
///
/// The unbound count row is ~30 px of that, and it renders only when there is
/// a database — so the no-database figure is unchanged by 04-08 and the
/// goldens do not move. The worst case, 696, is still **below**
/// `minContentHeight` (516 + 264 = 780), so the fallback gives the column
/// enough room and the key list is squeezed to one card rather than
/// overflowing. Verified by measurement at 800x600 with ten templates.
///
/// Raising the constant to cover 696 would push `minContentHeight` to ~960 and
/// engage the whole-page fallback on panels that lay out directly today, which
/// is a worse trade than a short list on a window nobody runs the plant from.
const double kKeyRepositoryChromeHeight = 516;

/// Three key cards. Below this the list is not worth showing and the page
/// scrolls as a whole instead.
const double kKeyRepositoryMinKeyListHeight = 264;

// ---------------------------------------------------------------------------
// The unbound-key surface — spec §7b's honesty requirement.
//
// An unbound key floors at `operate` (2026-09-02 ruling), and so does a
// member no bound template mentions — no key is unrestricted, but nothing
// above the floor is enforced until somebody binds it. **Nothing enforces
// that somebody remembered.** §7b's answer is that "enforcement is replaced
// by visibility …
// A key that should have been restricted must not stay open with no signal
// that someone forgot", and this count and this filter are that signal.
//
// **It is a working tool, not a compliance score.** The shipped state is zero
// templates and every key unbound, and that is correct by design — §7b: "The
// system therefore ships gating nothing and becomes stricter only as keys are
// bound." So there is no red, no warning glyph and no badge that reads as a
// defect: a station painted amber on the day it was commissioned teaches an
// operator to ignore the number, which costs exactly the case this exists for
// — somebody bound forty keys and forgot the forty-first. What the wording has
// to do is make the number **findable and true**, and say plainly which of the
// three states it is in, because a bare `0` reads as "not computed".
// ---------------------------------------------------------------------------

/// Some keys are bound and some are not — the only case with a fraction in it.
String kUnboundKeysCount(int unbound, int total) =>
    'No template governs $unbound of the $total keys here.';

/// Every key is bound. Said in words rather than as a zero.
String kUnboundKeysAllBound(int total) =>
    'Every one of the $total keys here is bound to a template.';

/// The shipped state. Named as the default, not as a fault.
String kUnboundKeysNoTemplates(int total) =>
    'No templates exist yet, so none of the $total keys here is gated — that '
    'is the shipped default, not a fault.';

/// The filter chip beside the count.
const String kUnboundKeysFilterLabel = 'Unbound only';

/// The count line, so a test reads the sentence the page renders.
const Key kUnboundKeysCountKey = Key('key-repository-unbound-count');

/// The filter chip.
const Key kUnboundKeysFilterKey = Key('key-repository-unbound-filter');

// ---------------------------------------------------------------------------
// What a key-mapping file does not carry.
//
// Since the 2026-08-30 ruling a key map is key mappings and nothing else: the
// bindings live in their own `users`-gated table. That is a real trap for a
// workflow engineers actually use — export from ST101, import on ST201 — and
// the file has nothing in it to say anything was dropped. So both halves of
// the card say it, before it matters, and each one names where to fix it. A
// disclosure that only says "not included" leaves somebody stuck; one that
// says where to go is a working instruction.
// ---------------------------------------------------------------------------

/// Shown in the import confirmation, **before** the import runs.
const String kKeyMappingsImportBindingsNote =
    'Access bindings are not in this file. The bindings already on this '
    'station are left exactly as they are, and every key arriving from the '
    'file is unbound — anyone with Operate can write it — until somebody '
    'binds it. Bind them on each key\'s card below, or have an agent sweep '
    'them with list_unbound_keys.';

/// Shown in the export result, so a file handed to another station is not
/// assumed to carry what it does not.
const String kKeyMappingsExportBindingsNote =
    'Key mappings only — access bindings are not in the file. A station that '
    'imports it gets every key unbound until somebody binds it there, on the '
    'key\'s card or over MCP with bind_key_access_template.';

/// ` @ st101` for a named server, nothing for an unnamed one.
///
/// Shared by the proposal card and the saved-key rows so a mapping reads the
/// same before and after it is accepted -- the two disagreeing is how a
/// proposal that did name a server came to look like one that did not.
String _aliasSuffix(Object? alias) {
  if (alias is! String || alias.isEmpty) return '';
  return ' @ $alias';
}

/// The full page widget with BaseScaffold (used in navigation).
class KeyRepositoryPage extends ConsumerWidget {
  /// Optional proposal JSON passed via Beamer route data.
  final String? proposalData;

  KeyRepositoryPage({super.key, this.proposalData});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BaseScaffold(
      title: 'Key Repository',
      body: KeyRepositoryContent(proposalData: proposalData),
    );
  }
}

/// The content widget (testable without BaseScaffold).
class KeyRepositoryContent extends ConsumerWidget {
  /// Optional proposal JSON passed down from KeyRepositoryPage.
  final String? proposalData;

  const KeyRepositoryContent({super.key, this.proposalData});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(databaseProvider);

    // The key list scrolls on its own (see [_KeyMappingsSection]) instead of
    // the whole page living in a SingleChildScrollView. A scroll view with a
    // shrink-wrapped list inside builds *every* key card up front, which is
    // what made a repository with thousands of keys crawl.
    final content = Column(
      children: [
        // Database status indicator
        dbAsync.when(
          data: (db) {
            if (db != null) return const SizedBox.shrink();
            return _DatabaseStatusBanner(connected: false);
          },
          loading: () => _DatabaseStatusBanner(connected: false, loading: true),
          error: (_, __) => _DatabaseStatusBanner(connected: false),
        ),
        Expanded(child: _KeyMappingsSection(proposalData: proposalData)),
        const SizedBox(height: 16),
        const AccessTemplatesSection(),
        const SizedBox(height: 16),
        _KeyMappingsImportExportCard(),
      ],
    );

    // Header, save button, the access-templates section and import/export are
    // fixed height; below this the key list has no room left and the column
    // would overflow. Fall back to scrolling the page as a whole (the key list
    // itself stays lazy).
    //
    // **Re-derived when the templates section landed, not nudged.** The old
    // value was 320, and it was never a height at which this column fitted:
    // measured at 800x600 the chrome above and below the key list already came
    // to ~344 px, so at 320 the list had negative room and the page overflowed
    // — 320 was the height at which scrolling *began*, not the height at which
    // the page worked. Adding the section made that gap visible rather than
    // creating it: with the section the chrome is ~516 px, and a key list worth
    // showing is three cards at ~82 px.
    //
    // So the constant is now what it always claimed to be: the chrome plus a
    // usable list. A 1080p panel is far above it and lays out directly; a short
    // window scrolls, which is what the fallback is for.
    const minContentHeight =
        kKeyRepositoryChromeHeight + kKeyRepositoryMinKeyListHeight;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight >= minContentHeight) return content;
        return SingleChildScrollView(
          // Not the primary scroll view: the key list inside is what a "scroll
          // the keys" gesture, and every test helper, means by the page's
          // scrollable. Leaving this primary would hand it the
          // PrimaryScrollController and make the two indistinguishable.
          primary: false,
          child: SizedBox(height: minContentHeight, child: content),
        );
      },
    );
  }
}

// ===================== Database Status Banner =====================

class _DatabaseStatusBanner extends StatelessWidget {
  final bool connected;
  final bool loading;

  const _DatabaseStatusBanner({
    required this.connected,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (connected) return const SizedBox.shrink();

    return Card(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withAlpha(25),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red),
        ),
        child: Row(
          children: [
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const FaIcon(FontAwesomeIcons.circleExclamation,
                  color: Colors.red, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                loading
                    ? 'Connecting to database...'
                    : 'Database not connected. Data collection will not work until the database is available.',
                style: TextStyle(
                  color: Colors.red[700],
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== Key Mappings Section =====================

class _KeyMappingsSection extends ConsumerStatefulWidget {
  final String? proposalData;
  const _KeyMappingsSection({this.proposalData});
  @override
  ConsumerState<_KeyMappingsSection> createState() =>
      _KeyMappingsSectionState();
}

/// One row of the key list with its search fields pre-lowercased.
///
/// Lowercasing every key/identifier/alias on each keystroke was a large part
/// of the search lag; the index is built once per mutation instead.
class _KeyRow {
  final String key;
  final KeyMappingEntry entry;
  final List<String> searchFields;

  const _KeyRow(this.key, this.entry, this.searchFields);
}

class _KeyMappingsSectionState extends ConsumerState<_KeyMappingsSection> {
  KeyMappings? _keyMappings;

  /// The store's key mapping items as this page loaded them — what a save is
  /// a save *over*. Handed to `saveKeyMappings` so a key another station
  /// added, changed or removed while this page was open is kept, adopted or
  /// refused rather than replaced with the copy on screen. Refreshed after
  /// every successful save and every load.
  List<ConfigItem>? _baselineItems;

  /// Encoded snapshot of the last persisted mappings, used for the unsaved
  /// check. Kept as a string so the comparison is one cached encode instead
  /// of re-serialising both sides on every build.
  String? _savedJson;
  StateManConfig? _stateManConfig;
  bool _isLoading = true;
  String? _error;
  String _searchQuery = '';
  final Map<String, _KeyStatus> _keyStatuses = {};

  /// Expansion state lives here rather than in the cards: the list is lazy,
  /// so a card scrolled out of view is destroyed and would otherwise forget
  /// that the operator had it open.
  final Set<String> _expandedKeys = {};

  final ScrollController _listController = ScrollController();

  // ---- Derived caches, all invalidated by [_invalidateDerived] ----
  String? _currentJsonCache;
  List<_KeyRow>? _rowsCache;
  String? _filterCacheQuery;
  List<_KeyRow>? _filterCache;
  List<String> _serverAliases = const [];
  List<String> _jbtmServerAliases = const [];
  List<String> _modbusServerAliases = const [];

  /// What the cards and the header need to know about bindings, refreshed at
  /// the top of every [build] from three providers. Not a derived cache — it is
  /// this frame's answer, and it costs three provider reads however many keys
  /// the repository holds.
  KeyBindingView _bindings = KeyBindingView.loading;

  /// The live snapshot behind [_bindings]. Held so [_buildCard] can ask which
  /// template name a key carries — including a dangling one, which
  /// `templateForKey` cannot report because it answers null for both gaps.
  TagBindingResolver? _resolver;

  /// This station's keys that no template governs — **`unboundKeys`'s answer
  /// and nothing else**.
  ///
  /// One definition, shared with the write path, so the filter cannot show a
  /// key the guard treats as bound (T-04-46). It includes a dangling binding,
  /// because a key naming a template that no longer exists resolves to no
  /// restriction at all and is therefore exactly as open as a key nobody
  /// touched.
  Set<String> _unbound = const {};

  /// Whether the list is showing only [_unbound].
  bool _unboundOnly = false;

  // Identity tokens for [_refreshUnbound]. The templates list is a fresh
  // instance on every load — `accessTemplatesProvider` re-reads **both**
  // tables and returns a new list — so a new instance means a new snapshot,
  // bindings included, even when the set of templates is unchanged.
  List<AccessTemplate>? _unboundCacheTemplates;
  List<_KeyRow>? _unboundCacheRows;

  /// The unbound filter applied to [_searchFiltered], and the search result it
  /// was computed from.
  List<_KeyRow>? _unboundFilterCache;
  List<_KeyRow>? _unboundFilterSource;

  /// Coalesces the per-key status updates produced by [_probeKeys] into at
  /// most one rebuild per 250 ms.
  Timer? _statusFlushTimer;
  bool _statusDirty = false;

  /// Keys still waiting to be probed, front first. [_prioritizeProbeQueue]
  /// reorders this in place when the search query changes, so the cards the
  /// operator is actually looking at get their status before the rest of
  /// the repository.
  final List<String> _probeQueue = [];

  /// Bumped by [_probeKeys] so workers from a superseded run stop instead
  /// of racing the new run for the queue.
  int _probeGeneration = 0;

  /// How many keys are probed at once. Each key on an unreachable server
  /// holds its read for the full 5 s timeout, so probing strictly one at a
  /// time turned a large repository into minutes of grey chips.
  static const int _probeConcurrency = 6;

  /// Proposal state.
  ///
  /// A batch, not a single proposal: an MCP client fires create_key_mapping
  /// one call at a time, so 28 mappings arrive as 28 proposals. Staging one
  /// at a time meant 28 separate reviews and 28 separate saves.
  /// The banner's callback slots, captured when publishing.
  ///
  /// Riverpod forbids `ref` inside dispose() -- "Cannot use ref after the
  /// widget was disposed" -- and these are plain (non-autoDispose)
  /// StateProviders, so their controllers outlive this State and can be held.
  StateController<Future<void> Function()?>? _commitSlot;
  StateController<Future<void> Function()?>? _discardSlot;

  /// The provider container, taken while this section is still alive.
  ///
  /// The banner outlives this widget -- it is published once and stays up
  /// while the operator navigates. By the time they press a button, this state
  /// can be deactivated or disposed, and then `ref` throws
  /// (`Cannot use "ref" after the widget was disposed`) before any work
  /// happens. On 2026-08-21 that made a batch of 16 mappings impossible to
  /// either accept or reject.
  ///
  /// The container rather than the values read out of it. A resolved
  /// `Future<Preferences>` names the instance that was current when the
  /// proposal was staged, and preferences are invalidated under us -- a
  /// server-config import and a reconnect re-sync both do it. Accepting after
  /// one of those would write the whole batch through a handle whose database
  /// is already closed. The container is what outlives the widget *and* stays
  /// current, so each press reads today's preferences and today's notifier.
  ProviderContainer? _container;

  /// Context-derived, so there is no container to re-read these from.
  ///
  /// The colour is deliberately not re-derived at press time: `Theme.of` is an
  /// ancestor lookup, and doing one off a dead element is the exact fault this
  /// whole capture exists to avoid. Switching theme between staging a proposal
  /// and accepting it therefore tints one snackbar with the old scheme's red,
  /// which is a fair trade for not risking the accept.
  ScaffoldMessengerState? _messengerHandle;
  Color? _errorColourHandle;

  final List<Map<String, dynamic>> _proposedMappings = [];
  final List<int> _proposalIds = [];
  bool get _isProposal => _proposedMappings.isNotEmpty;

  /// Where to report from. The handle whenever there is one -- every banner
  /// path has one, and looking an ancestor up off a dead element throws.
  /// The live lookup is for an ordinary Save, where no handle was ever taken
  /// and the page is by definition on screen.
  ScaffoldMessengerState? get _messenger {
    final handle = _messengerHandle;
    if (handle != null) return handle;
    return mounted ? ScaffoldMessenger.maybeOf(context) : null;
  }

  Color? get _errorColour {
    final handle = _errorColourHandle;
    if (handle != null) return handle;
    return mounted ? Theme.of(context).colorScheme.error : null;
  }

  /// Tells the operator something, from a path that may have outlived the
  /// page. Silent when there is no messenger to tell -- better than throwing
  /// out of the middle of an accept.
  void _report(String message, {bool error = false}) {
    _messenger?.showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? _errorColour : null,
    ));
  }

  @override
  void initState() {
    super.initState();
    _loadKeyMappings();
    // Whole queue, not just the one the banner routed us with -- but fall back
    // to that one when state is empty, because the chat batch card empties
    // proposalStateProvider before it navigates here.
    if (_stageKeyMappingProposals() == 0) {
      _stageRoutedProposal(widget.proposalData);
    }
  }

  /// Stages the proposal the route carried, when state has none.
  ///
  /// Not the one already resolved. The route payload outlives the decision --
  /// beamer keeps it on the location, so every later mount of this section is
  /// handed the same JSON, and by then the proposal has been accepted and
  /// dropped from state, which is the very condition this fallback triggers
  /// on. Rebuilding the section was enough to put the amber strip back over a
  /// mapping that was already written, and nothing was left pending that
  /// could take it down again. The rebuild is easier to hit than it looks:
  /// [KeyRepositoryContent] swaps LayoutBuilder branches at 320 px, so a
  /// resize does it without leaving the page, and so does navigating away and
  /// back to a location that still carries the data.
  void _stageRoutedProposal(String? json) {
    if (json == null) return;
    if (_routePayloadResolved(json)) return;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['_proposal_type'] != 'key_mapping') return;
      if (decoded['key'] is! String) return;
      _proposedMappings.add(decoded);
      _publishProposalCallbacks();
    } catch (_) {
      // Malformed JSON: nothing to stage.
    }
  }

  /// Whether the route payload has already been applied or discarded here.
  ///
  /// Read through `ref` rather than the captured container: this runs from
  /// [initState], where the container has not been taken yet.
  bool _routePayloadResolved(String json) {
    try {
      return ref
          .read(proposalStateProvider.notifier)
          .isRoutePayloadResolved(json);
    } catch (_) {
      // Provider unavailable (tests) -- nothing says it was resolved.
      return false;
    }
  }

  /// Marks the route payload resolved once this batch is accepted or
  /// rejected, so a later mount does not stage it again.
  ///
  /// Recorded on the notifier because the record has to outlive this State --
  /// resurrecting the strip takes nothing more than rebuilding the section.
  /// Called before the `mounted` check on both paths: a batch that resolved
  /// after the operator navigated away is still resolved.
  void _markRoutePayloadResolved(ProposalStateNotifier notifier) {
    final json = widget.proposalData;
    if (json == null) return;
    notifier.markRoutePayloadResolved(json);
  }

  @override
  void dispose() {
    // The banner holds these closures over this State; left set they would
    // fire into a disposed State after navigating away.
    //
    // After this frame, not during it: navigating away disposes us from
    // inside a build, and writing to a provider there trips riverpod's
    // "tried to modify a provider while the widget tree was building". Only
    // if the slot still holds our own closure -- a section that replaced us
    // has already published its own, and clearing that would take the
    // banner's buttons away from a live batch.
    final commitSlot = _commitSlot;
    final discardSlot = _discardSlot;
    final commit = _commitProposals;
    final discard = _discardProposals;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `mounted` on the controllers, not on us: a frame later the whole
      // ProviderScope may be gone too -- the app shutting down, or a test
      // ending -- and reading a disposed StateController throws.
      if (commitSlot != null &&
          commitSlot.mounted &&
          commitSlot.state == commit) {
        commitSlot.state = null;
      }
      if (discardSlot != null &&
          discardSlot.mounted &&
          discardSlot.state == discard) {
        discardSlot.state = null;
      }
    });
    _statusFlushTimer?.cancel();
    _listController.dispose();
    super.dispose();
  }

  /// Drops every cache derived from [_keyMappings]. Call from anything that
  /// mutates the mappings.
  void _invalidateDerived() {
    _currentJsonCache = null;
    _rowsCache = null;
    _filterCache = null;
    _filterCacheQuery = null;
    _unboundCacheRows = null;
    _unboundFilterCache = null;
    _unboundFilterSource = null;
  }

  /// Recomputes [_unbound], but only when the key list or the snapshot behind
  /// it actually moved.
  ///
  /// Called once at the top of [build]. Both guards are identity checks, which
  /// is what keeps this off the per-frame path: `_rows` is a cache dropped by
  /// [_invalidateDerived], and [templates] is a fresh list on every load of
  /// `accessTemplatesProvider`. So scrolling, typing in the search box and
  /// every repaint in between cost one `identical` each — not a walk of a
  /// repository with thousands of keys (T-04-48).
  void _refreshUnbound(List<AccessTemplate>? templates) {
    final rows = _rows;
    if (identical(rows, _unboundCacheRows) &&
        identical(templates, _unboundCacheTemplates)) {
      return;
    }
    _unboundCacheRows = rows;
    _unboundCacheTemplates = templates;
    final resolver = _resolver;
    // With no resolver at all nothing can be bound, which is the same answer
    // `unboundKeys` gives for an empty snapshot — spelled out rather than
    // relying on it, because the two agreeing is the whole claim.
    _unbound = resolver == null
        ? {for (final row in rows) row.key}
        : resolver.unboundKeys([for (final row in rows) row.key]).toSet();
    _unboundFilterCache = null;
    _unboundFilterSource = null;
  }

  /// Stages every pending `key_mapping` proposal in one batch.
  ///
  /// Safe to re-enter: ids already staged are skipped, so a proposal landing
  /// after the first joins the batch instead of being dropped.
  ///
  /// Returns how many were newly staged.
  int _stageKeyMappingProposals() {
    var added = 0;
    try {
      final state = ref.read(proposalStateProvider);
      for (final p in state.proposals) {
        if (p.proposalType != 'key_mapping') continue;
        if (_proposalIds.contains(p.id)) continue;
        try {
          final decoded = jsonDecode(p.proposalJson);
          if (decoded is! Map<String, dynamic>) continue;
          if (decoded['_proposal_type'] != 'key_mapping') continue;
          if (decoded['key'] is! String) continue;
          _proposedMappings.add(decoded);
          _proposalIds.add(p.id);
          added++;
        } catch (_) {
          // A malformed proposal must not take the rest of the batch with it.
        }
      }
    } catch (_) {
      // Provider unavailable (tests) -- nothing to stage.
    }
    if (added > 0) _publishProposalCallbacks();
    return added;
  }

  /// Hands the black banner the commit/discard actions for this batch.
  ///
  /// The inline amber bar that used to carry Accept/Reject here is gone: one
  /// place to act on a proposal, not two. What stays inline is the highlighted
  /// row showing the proposed mapping, which is the point of navigating here.
  void _publishProposalCallbacks() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final commitSlot = ref.read(proposalCommitProvider.notifier);
      commitSlot.state = _commitProposals;
      _commitSlot = commitSlot;
      final discardSlot = ref.read(proposalDiscardProvider.notifier);
      discardSlot.state = _discardProposals;
      _discardSlot = discardSlot;
      // Taken here, where `ref` and `context` are known good, because the
      // callbacks above can be invoked long after this section is gone.
      // `listen: false`: this is not a build, so it must not register a
      // dependency, only look the scope up.
      _container = ProviderScope.containerOf(context, listen: false);
      _messengerHandle = ScaffoldMessenger.maybeOf(context);
      _errorColourHandle = Theme.of(context).colorScheme.error;
    });
  }

  /// Applies every staged mapping, saves once, then marks them accepted.
  Future<void> _commitProposals() async {
    if (_keyMappings == null || _proposedMappings.isEmpty) return;
    // Fresh keys go to the *top* of the repository, like _addKey's: that is
    // where _revealKey can land in O(1). A proposal for an existing key
    // updates it in place, keeping its position.
    final fresh = <String, KeyMappingEntry>{};
    String? firstKey;
    for (final m in _proposedMappings) {
      final key = m['key'] as String?;
      if (key == null) continue;

      // A removal carries no fields to merge.
      if (m['_op'] == 'delete') {
        _removeKey(key);
        continue;
      }

      // Start from what the key already has. This used to build a fresh
      // KeyMappingEntry and assign only opcuaNode, so proposing a new node id
      // silently discarded that key's collect settings -- its retention and
      // sample interval -- along with any m2400/modbus/io binding on it. A
      // proposal says what changes; everything it does not mention has to
      // survive.
      final entry = _keyMappings!.nodes[key] ?? KeyMappingEntry();

      // Node kinds are exclusive: a proposal that re-points a key to one
      // protocol clears the others, because an entry carrying two bindings
      // is ambiguous -- reads resolve through whichever the server getter
      // finds first, silently.
      final opcuaNode = m['opcua_node'];
      if (opcuaNode is Map<String, dynamic>) {
        entry.opcuaNode = OpcUANodeConfig.fromJson(opcuaNode);
        entry.m2400Node = null;
        entry.modbusNode = null;
      }
      final m2400Node = m['m2400_node'];
      if (m2400Node is Map<String, dynamic>) {
        entry.m2400Node = M2400NodeConfig.fromJson(m2400Node);
        entry.opcuaNode = null;
        entry.modbusNode = null;
      }
      final modbusNode = m['modbus_node'];
      if (modbusNode is Map<String, dynamic>) {
        entry.modbusNode = ModbusNodeConfig.fromJson(modbusNode);
        entry.opcuaNode = null;
        entry.m2400Node = null;
      }
      // UMAS symbol name: set when given, cleared by an explicit null.
      if (m.containsKey('variable_name')) {
        entry.variableName = m['variable_name'] as String?;
      }

      final collect = m['collect'];
      if (collect is Map<String, dynamic>) {
        entry.collect = CollectEntry.fromJson(collect)..key = key;
      } else if (collect == null && m.containsKey('collect')) {
        // An explicit null turns collection off for this key.
        entry.collect = null;
      }

      if (_keyMappings!.nodes.containsKey(key)) {
        _keyMappings!.nodes[key] = entry;
      } else {
        fresh[key] = entry;
      }
      _expandedKeys.add(key);
      firstKey ??= key;
    }
    if (fresh.isNotEmpty) {
      _keyMappings!.nodes = {...fresh, ..._keyMappings!.nodes};
    }
    _invalidateDerived();
    if (!await _saveKeyMappings()) return;

    // Awaited, and only after the save has persisted: acceptProposal marks
    // the row accepted in the database, so doing it first would lose the
    // mappings if the save failed.
    final notifier = _container?.read(proposalStateProvider.notifier);
    if (notifier == null) return;
    var failed = 0;
    for (final id in _proposalIds) {
      try {
        await notifier.acceptProposal(id);
      } catch (_) {
        failed++;
      }
    }
    // A swallowed failure is the quiet form of the bug this method already
    // guards against: the mappings are in preferences, the rows are still
    // pending in the database, and clearing the batch would tell the operator
    // it is done while the next load brings it all back. Keep the batch up
    // instead, so Accept can be pressed again -- both halves are idempotent.
    if (failed > 0) {
      _report(
        '$failed of ${_proposalIds.length} proposals could not be marked '
        'accepted. The mappings are saved; press Accept again.',
        error: true,
      );
      return;
    }
    _markRoutePayloadResolved(notifier);
    if (!mounted) return;
    setState(() {
      _proposedMappings.clear();
      _proposalIds.clear();
    });
    _commitSlot?.state = null;
    _discardSlot?.state = null;
    if (firstKey != null) _revealKey(firstKey);
  }

  /// Drops the whole batch without touching the mappings.
  Future<void> _discardProposals() async {
    final notifier = _container?.read(proposalStateProvider.notifier);
    if (notifier == null) return;
    var failed = 0;
    for (final id in _proposalIds) {
      try {
        await notifier.rejectProposal(id);
      } catch (_) {
        failed++;
      }
    }
    // As in [_commitProposals]: a rejection that did not reach the database
    // comes back on the next load, so the batch stays up rather than
    // pretending it is gone.
    if (failed > 0) {
      _report(
        '$failed of ${_proposalIds.length} proposals could not be marked '
        'rejected. Press Reject again.',
        error: true,
      );
      return;
    }
    _markRoutePayloadResolved(notifier);
    if (!mounted) return;
    setState(() {
      _proposedMappings.clear();
      _proposalIds.clear();
    });
    _commitSlot?.state = null;
    _discardSlot?.state = null;
  }

  Future<void> _loadKeyMappings() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // The plant's wiring comes from the shared configuration store, one row
      // per key. `state_man_config` is not this phase's key and still comes
      // out of preferences.
      final store = await ref.read(configStoreProvider.future);
      _keyMappings = store.inner.keyMappings;
      _baselineItems = store.inner.keyMappingItems;
      _invalidateDerived();
      _savedJson = _currentJson();
      final prefs = await ref.read(preferencesProvider.future);
      _stateManConfig = await StateManConfig.fromPrefs(prefs);
      _rebuildAliasLists();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _probeKeys();
      }
    }
  }

  String _currentJson() =>
      _currentJsonCache ??= jsonEncode(_keyMappings!.toJson());

  bool get _hasUnsavedChanges {
    if (_keyMappings == null || _savedJson == null) return false;
    return _currentJson() != _savedJson;
  }

  /// Persists the mappings, reporting whether they actually landed.
  ///
  /// The result matters to [_commitProposals]: a proposal must stay pending
  /// when its mappings did not save, or it is lost with nothing written.
  Future<bool> _saveKeyMappings() async {
    if (_keyMappings == null) return false;
    // Unfocus active text field to commit pending changes (e.g. key rename)
    FocusManager.instance.primaryFocus?.unfocus();
    // Resolved before the first await. Showing a snackbar looks up an
    // ancestor, and once this section has been deactivated that lookup throws
    // -- `mounted` is still true at that point, so it is not a sufficient
    // guard. Accepting a batch of proposals rebuilds this subtree, which is
    // exactly when it happened: the save persisted, the success snackbar
    // threw, the catch threw again, and `_commitProposals` never reached
    // `acceptProposal`. The mappings were written but every proposal stayed
    // pending, so they came back on the next load.
    final messenger = _messenger;
    final errorColour = _errorColour;
    try {
      // The container when the banner drove us here, because `ref` is gone by
      // then; `ref` for an ordinary Save, where no container was ever taken.
      // Either way the read happens now, so an invalidated configStoreProvider
      // hands back the live instance rather than a closed one.
      final store = await (_container?.read(configStoreProvider.future) ??
          ref.read(configStoreProvider.future));
      // Unfocusing above may have committed a rename, so re-encode.
      _invalidateDerived();
      final json = _currentJson();
      // The guarded store writes one row per key that actually moved, records
      // one bounded audit row, and throws rather than reporting a success it
      // did not have. The three arms below are its three refusals.
      await store.saveKeyMappings(_keyMappings!, baseline: _baselineItems);
      // The next save is measured against what the store holds now, not
      // against the open. Keys the merge kept from another station are in
      // the store and not on screen; a reload shows them.
      _baselineItems = store.inner.keyMappingItems;
      // `json` rather than a fresh read of the store: the store serves its
      // keys in sorted order, and re-encoding from it would make a repository
      // whose on-screen order differs (a duplicated key sits beside its
      // original) look permanently dirty. What matters to [_hasUnsavedChanges]
      // is that what is on screen is what was written, and it is.
      _savedJson = json;
      // No stateManProvider invalidate here: the provider's store listener
      // diffs the save and applies it live — it only rebuilds the whole
      // StateMan when an edit cannot be absorbed in place.
      if (mounted) setState(() {});

      messenger?.showSnackBar(
        const SnackBar(
            content: Text('Key mappings saved successfully!'),
            backgroundColor: Colors.green),
      );
      return true;
    } on ConfigStoreOfflineException catch (e) {
      // C-11: what used to be a green snackbar over a write that reached
      // nothing. The message names the work that did not land, so the operator
      // knows what to redo.
      messenger?.showSnackBar(
        SnackBar(
            content: Text('Not saved — the database is unreachable. '
                'Nothing was written: ${e.attempted}.'),
            backgroundColor: errorColour),
      );
      return false;
    } on ConfigConflict catch (e) {
      // SC-5. The conflict is per key, so the message names it, and Reload
      // brings the other station's edit here rather than leaving the operator
      // to guess how to get it.
      messenger?.showSnackBar(
        SnackBar(
          content: Text('"${e.key}" was changed on another station. '
              'Reload to see it, then save again.'),
          backgroundColor: errorColour,
          action: SnackBarAction(
            label: 'Reload',
            onPressed: _reloadAfterConflict,
          ),
        ),
      );
      return false;
    } catch (e) {
      // AccessDenied falls through here exactly as it did before: the denial
      // has already been recorded and reported by the guard.
      messenger?.showSnackBar(
        SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: errorColour),
      );
      return false;
    }
  }

  /// The Reload action on a conflict snackbar.
  ///
  /// Discards unsaved edits, so it asks first when there are any — through the
  /// page's existing confirm dialog rather than a second kind of prompt.
  Future<void> _reloadAfterConflict() async {
    if (!mounted) return;
    if (_hasUnsavedChanges) {
      final confirm = await showConfirmDialog(
        context: context,
        title: 'Reload key mappings',
        message: 'Another station changed a key while you were editing. '
            'Reloading discards your unsaved edits and shows what is stored. '
            'Continue?',
        confirmLabel: 'Reload',
        destructive: true,
      );
      if (!confirm) return;
    }
    if (!mounted) return;
    await _loadKeyMappings();
  }

  final Map<String, GlobalKey> _cardKeys = {};

  /// Scrolls the newly added/duplicated [name] into view once it is laid out.
  ///
  /// The list is lazy, so a card outside the viewport has no element yet and
  /// [Scrollable.ensureVisible] has nothing to target. When the key is the
  /// first one — which is where [_addKey] and [_commitProposals] put new
  /// keys — jump to the top and retry on the following frame. New keys go to
  /// the top rather than the bottom because jumping to the *end* of a lazy
  /// list has no known extent to land on: the sliver re-estimates every
  /// frame, building one more card each time, which froze the page for ~10 s
  /// on a repository with thousands of keys. A key inserted mid-list (a
  /// duplicate) sits next to its original, which is on screen, so its card
  /// is already built and the ensureVisible branch handles it.
  void _revealKey(String name) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final keyContext = _cardKeys[name]?.currentContext;
      if (keyContext != null) {
        Scrollable.ensureVisible(keyContext,
            duration: const Duration(milliseconds: 300));
        return;
      }
      final isFirst = _keyMappings?.nodes.keys.firstOrNull == name;
      if (!isFirst || !_listController.hasClients) return;
      _listController.jumpTo(_listController.position.minScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _cardKeys[name]?.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx);
      });
    });
  }

  void _addKey() {
    final baseName = 'new_key';
    var name = baseName;
    var i = 1;
    while (_keyMappings!.nodes.containsKey(name)) {
      name = '${baseName}_$i';
      i++;
    }
    _cardKeys[name] = GlobalKey();
    _expandedKeys.add(name);
    setState(() {
      _keyMappings!.nodes = {
        name: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 0, identifier: ''),
        ),
        ..._keyMappings!.nodes,
      };
      _invalidateDerived();
    });
    _revealKey(name);
  }

  void _duplicateKey(String key) {
    final original = _keyMappings!.nodes[key];
    if (original == null) return;
    final copy = KeyMappingEntry.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
    var newName = '${key}_copy';
    var i = 1;
    while (_keyMappings!.nodes.containsKey(newName)) {
      newName = '${key}_copy_$i';
      i++;
    }
    if (copy.collect != null) {
      copy.collect!.key = newName;
    }
    _cardKeys[newName] = GlobalKey();
    _expandedKeys.add(newName);
    // Insert copy right after the original, preserving order
    final newNodes = <String, KeyMappingEntry>{};
    for (final kv in _keyMappings!.nodes.entries) {
      newNodes[kv.key] = kv.value;
      if (kv.key == key) {
        newNodes[newName] = copy;
      }
    }
    setState(() {
      _keyMappings!.nodes = newNodes;
      _invalidateDerived();
    });
    _revealKey(newName);
  }

  void _removeKey(String key) {
    _cardKeys.remove(key);
    _keyStatuses.remove(key);
    _expandedKeys.remove(key);
    setState(() {
      _keyMappings!.nodes.remove(key);
      _invalidateDerived();
    });
  }

  /// Requests a rebuild for freshly probed statuses, at most once per 250 ms.
  ///
  /// Probing thousands of keys used to rebuild the whole page per key (and
  /// copy the status map each time, making it quadratic).
  void _scheduleStatusFlush() {
    _statusDirty = true;
    if (_statusFlushTimer != null) return;
    _statusFlushTimer = Timer(const Duration(milliseconds: 250), () {
      _statusFlushTimer = null;
      if (!mounted || !_statusDirty) return;
      _statusDirty = false;
      setState(() {});
    });
  }

  Future<void> _probeKeys() async {
    if (_keyMappings == null || _keyMappings!.nodes.isEmpty) return;

    // Await instead of peeking at valueOrNull: opening this page right
    // after app start used to catch the provider still loading and
    // silently skip probing, leaving every chip blank.
    final StateMan stateMan;
    try {
      stateMan = await ref.read(stateManProvider.future);
    } catch (_) {
      return; // No StateMan configured; nothing to probe.
    }
    if (!mounted) return;

    _probeQueue
      ..clear()
      ..addAll(_keyMappings!.nodes.keys);
    _prioritizeProbeQueue();
    final generation = ++_probeGeneration;
    final workers = _probeQueue.length < _probeConcurrency
        ? _probeQueue.length
        : _probeConcurrency;
    for (var i = 0; i < workers; i++) {
      unawaited(_probeWorker(stateMan, generation));
    }
  }

  /// One probe worker: pulls keys off [_probeQueue] until it is empty or
  /// this run is superseded.
  Future<void> _probeWorker(StateMan stateMan, int generation) async {
    while (mounted &&
        generation == _probeGeneration &&
        _probeQueue.isNotEmpty) {
      final key = _probeQueue.removeAt(0);
      // The operator can rename or delete keys while a long probe runs.
      // Statuses are written in place now, so skip keys that are gone —
      // otherwise the map keeps entries no card will ever read, and a key
      // later given that same name inherits a stale status.
      if (!_keyMappings!.nodes.containsKey(key)) {
        _keyStatuses.remove(key);
        continue;
      }
      // Keys on a disabled server have nothing to probe — reading them
      // would just burn the 5 s timeout each.
      if (stateMan.isKeyDisabled(key)) {
        _keyStatuses[key] = _KeyStatus.serverDisabled;
        _scheduleStatusFlush();
        continue;
      }
      _KeyStatus status;
      try {
        await stateMan.read(key).timeout(const Duration(seconds: 5));
        status = _KeyStatus.ok;
      } on TimeoutException {
        status = _KeyStatus.serverDisconnected;
      } catch (e) {
        final msg = e.toString().toLowerCase();
        status = msg.contains('not found') || msg.contains('connect')
            ? _KeyStatus.serverDisconnected
            : _KeyStatus.error;
      }
      if (!mounted || generation != _probeGeneration) return;
      // The key may have been renamed or deleted while the read ran.
      if (_keyMappings!.nodes.containsKey(key)) {
        _keyStatuses[key] = status;
        _scheduleStatusFlush();
      }
    }
  }

  /// Moves keys matching the current search to the front of [_probeQueue],
  /// keeping relative order within both groups. Without this, a search
  /// typed mid-probe kept fetching statuses in full-repository order and
  /// the filtered cards sat blank behind thousands of hidden keys.
  void _prioritizeProbeQueue() {
    if (_probeQueue.isEmpty || _searchQuery.isEmpty) return;
    final visible = {for (final row in _filteredEntries) row.key};
    if (visible.isEmpty) return;
    final front = <String>[];
    final back = <String>[];
    for (final key in _probeQueue) {
      (visible.contains(key) ? front : back).add(key);
    }
    _probeQueue
      ..clear()
      ..addAll(front)
      ..addAll(back);
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);
    _prioritizeProbeQueue();
  }

  void _renameKey(String oldKey, String newKey) {
    if (oldKey == newKey) return;
    if (_keyMappings!.nodes.containsKey(newKey)) return;
    final entry = _keyMappings!.nodes[oldKey];
    if (entry == null) return;
    if (entry.collect != null) {
      entry.collect!.key = newKey;
    }
    final cardKey = _cardKeys.remove(oldKey);
    if (cardKey != null) _cardKeys[newKey] = cardKey;
    final status = _keyStatuses.remove(oldKey);
    if (status != null) _keyStatuses[newKey] = status;
    if (_expandedKeys.remove(oldKey)) _expandedKeys.add(newKey);
    // Rebuild map preserving insertion order
    final newNodes = <String, KeyMappingEntry>{};
    for (final kv in _keyMappings!.nodes.entries) {
      newNodes[kv.key == oldKey ? newKey : kv.key] = kv.value;
    }
    setState(() {
      _keyMappings!.nodes = newNodes;
      _invalidateDerived();
    });
  }

  void _updateEntry(String key, KeyMappingEntry entry) {
    setState(() {
      _keyMappings!.nodes[key] = entry;
      _invalidateDerived();
    });
  }

  /// Reorders the key at [oldIndex] to [newIndex] in the underlying
  /// [_keyMappings.nodes] map.
  ///
  /// [oldIndex] and [newIndex] are indices into the current iteration
  /// order of the map (which equals the rendered list when no search
  /// filter is active — reorder is disabled while a search query is
  /// in effect, so this assumption holds).
  ///
  /// Follows the ReorderableListView convention: if [newIndex] is
  /// greater than [oldIndex], it must be decremented by one to land
  /// at the intended slot (because the item is conceptually removed
  /// first, then inserted).
  void _reorderKey(int oldIndex, int newIndex) {
    if (_keyMappings == null) return;
    if (oldIndex == newIndex) return;
    final entries = _keyMappings!.nodes.entries.toList();
    if (oldIndex < 0 || oldIndex >= entries.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target > entries.length - 1) target = entries.length - 1;
    if (target == oldIndex) return;
    final moved = entries.removeAt(oldIndex);
    entries.insert(target, moved);
    final newNodes = <String, KeyMappingEntry>{};
    for (final kv in entries) {
      newNodes[kv.key] = kv.value;
    }
    setState(() {
      _keyMappings!.nodes = newNodes;
      _invalidateDerived();
    });
  }

  /// The key list with search fields pre-lowercased. Rebuilt only when the
  /// mappings change, not on every keystroke.
  List<_KeyRow> get _rows {
    if (_keyMappings == null) return const [];
    return _rowsCache ??= [
      for (final e in _keyMappings!.nodes.entries)
        _KeyRow(e.key, e.value, [
          e.key.toLowerCase(),
          (e.value.opcuaNode?.identifier ?? '').toLowerCase(),
          (e.value.opcuaNode?.serverAlias ??
                  e.value.m2400Node?.serverAlias ??
                  e.value.modbusNode?.serverAlias ??
                  '')
              .toLowerCase(),
        ]),
    ];
  }

  List<_KeyRow> get _searchFiltered {
    final rows = _rows;
    if (_searchQuery.isEmpty) return rows;
    if (_filterCache != null && _filterCacheQuery == _searchQuery) {
      return _filterCache!;
    }
    final q = _searchQuery.toLowerCase();
    final scored = <(int, _KeyRow)>[];
    for (final row in rows) {
      final score = fuzzyScoreFields(row.searchFields, q);
      if (score != null) scored.add((score, row));
    }
    _filterCacheQuery = _searchQuery;
    return _filterCache = rankedItems(scored);
  }

  /// The search result, then the unbound filter on top of it.
  ///
  /// Composed rather than alternative: an engineer sweeping the conveyors
  /// wants "the CN keys nobody bound", not a choice between the two. The
  /// predicate rides inside the existing cache path — a second list rebuilt
  /// per frame is what made this page crawl before, and the comment at
  /// `KeyRepositoryContent.build` says so.
  List<_KeyRow> get _filteredEntries {
    final searched = _searchFiltered;
    if (!_unboundOnly) return searched;
    if (_unboundFilterCache != null &&
        identical(_unboundFilterSource, searched)) {
      return _unboundFilterCache!;
    }
    _unboundFilterSource = searched;
    return _unboundFilterCache = [
      for (final row in searched)
        if (_unbound.contains(row.key)) row,
    ];
  }

  /// The three server-alias lists used to be getters that rebuilt on every
  /// build and were handed to every card. They only change when the config
  /// is (re)loaded.
  void _rebuildAliasLists() {
    final cfg = _stateManConfig;
    _serverAliases = _nonEmptyAliases(cfg?.opcua.map((c) => c.serverAlias));
    _jbtmServerAliases = _nonEmptyAliases(cfg?.jbtm.map((c) => c.serverAlias));
    _modbusServerAliases =
        _nonEmptyAliases(cfg?.modbus.map((c) => c.serverAlias));
  }

  static List<String> _nonEmptyAliases(Iterable<String?>? aliases) => [
        for (final a in aliases ?? const <String?>[])
          if (a != null && a.isNotEmpty) a,
      ];

  @override
  Widget build(BuildContext context) {
    // Reactively watch for new key mapping proposals arriving via MCP.
    ref.listen<ProposalState>(proposalStateProvider, (prev, next) {
      // No "already showing one" guard: a later proposal joins the batch.
      if (_stageKeyMappingProposals() > 0) setState(() {});
    });

    // Bindings, watched **once** for the whole list rather than per card, and
    // before the early returns below so this widget's provider dependencies do
    // not change shape between builds. The count in the header, the badge on
    // each card and the filter all read this one object; see [KeyBindingView].
    final storeAsync = ref.watch(accessTemplateStoreProvider);
    final templatesAsync = ref.watch(accessTemplatesProvider);
    _resolver = ref.watch(tagBindingResolverProvider);
    _bindings = KeyBindingView(
      store: storeAsync.valueOrNull,
      templateNames: [
        for (final t in templatesAsync.valueOrNull ?? const <AccessTemplate>[])
          t.name,
      ],
      loaded: storeAsync.hasValue || storeAsync.hasError,
    );
    _refreshUnbound(templatesAsync.valueOrNull);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(FontAwesomeIcons.triangleExclamation,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Error loading key mappings: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _loadKeyMappings, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredEntries;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The inline amber Accept/Reject bar used to live here. Removed:
        // the black banner is the one place proposals are acted on, and two
        // competing controls meant the operator could accept in one place
        // while the other still showed the change as pending.
        //
        // What stays inline is the proposed mapping itself -- highlighted
        // rows are why you navigate here, the same role the yellow outline
        // plays in the page editor.
        if (_isProposal)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: proposalDecoration(),
            // Same reason as the proposed-alarm row: a ListTile inks on the
            // nearest Material, which is above the highlight. These rows are
            // read-only today so nothing splashes, but the box is the same
            // trap, and the tile asserts the moment one gets an onTap.
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _proposedMappings.length,
                itemBuilder: (context, i) {
                  final m = _proposedMappings[i];
                  final node = m['opcua_node'];
                  // The server alias belongs on this line. It is what routes
                  // the key, it lives inside `opcua_node` rather than at the
                  // top of the proposal, and leaving it off made a mapping
                  // that names a server look identical to one that names
                  // none -- while the accepted row directly below rendered
                  // "@ st101" and the proposal card did not. The operator is
                  // deciding whether to accept from this line.
                  final ident = node is Map<String, dynamic>
                      ? '${node['namespace']}:${node['identifier']}'
                          '${_aliasSuffix(node['server_alias'])}'
                      : '';
                  return ListTile(
                    dense: true,
                    leading: const ProposalBadge(),
                    title: Text('${m['key']}'),
                    subtitle:
                        Text(ident.isEmpty ? 'AI proposed key mapping' : ident),
                  );
                },
              ),
            ),
          ),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isNarrow = constraints.maxWidth < 500;
                      if (isNarrow) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const FaIcon(FontAwesomeIcons.key, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('Key Mappings',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                ),
                                if (_hasUnsavedChanges) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: Colors.orange,
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: const Text('Unsaved',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                hintText: 'Search keys...',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: _onSearchChanged,
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: _addKey,
                              icon:
                                  const FaIcon(FontAwesomeIcons.plus, size: 16),
                              label: const Text('Add Key'),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Row(
                            children: [
                              const FaIcon(FontAwesomeIcons.key, size: 20),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text('Key Mappings',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              if (_hasUnsavedChanges) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                      color: Colors.orange,
                                      borderRadius: BorderRadius.circular(12)),
                                  child: const Text('Unsaved Changes',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ],
                              const Spacer(),
                              SizedBox(
                                width: 200,
                                child: TextField(
                                  decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    hintText: 'Search keys...',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: _onSearchChanged,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: _addKey,
                                icon: const FaIcon(FontAwesomeIcons.plus,
                                    size: 16),
                                label: const Text('Add Key'),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  // The unbound count and its filter, on their own line under
                  // the header. Absent when there is no database, deliberately:
                  // the access-templates section below already says that once,
                  // and a number nobody can compute must not be rendered as a
                  // zero. Absent with no keys, because "0 of 0" is not a fact
                  // about anything.
                  if (_bindings.available && _rows.isNotEmpty)
                    _buildUnboundHeader(context),
                  const SizedBox(height: 16),
                  // Key list. Both branches scroll themselves and build lazily —
                  // only the cards on screen exist, so a repository with thousands
                  // of keys costs the same to render as one with ten.
                  Expanded(
                    child: filtered.isEmpty
                        ? const _EmptyKeysWidget()
                        // Reorder needs the rendered list to be the whole map
                        // in map order, which neither a search nor the unbound
                        // filter leaves true.
                        : (_searchQuery.isEmpty && !_unboundOnly)
                            ? ReorderableListView.builder(
                                scrollController: _listController,
                                buildDefaultDragHandles: false,
                                itemCount: filtered.length,
                                onReorder: _reorderKey,
                                itemBuilder: (context, index) => _buildCard(
                                    filtered[index],
                                    reorderIndex: index),
                              )
                            : ListView.builder(
                                controller: _listController,
                                itemCount: filtered.length,
                                itemBuilder: (context, index) =>
                                    _buildCard(filtered[index]),
                              ),
                  ),
                  const SizedBox(height: 16),
                  // Save button
                  Row(
                    children: [
                      if (_keyMappings!.nodes.isNotEmpty || _hasUnsavedChanges)
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed:
                                _hasUnsavedChanges ? _saveKeyMappings : null,
                            icon: FaIcon(FontAwesomeIcons.floppyDisk,
                                size: 16,
                                color: _hasUnsavedChanges ? null : Colors.grey),
                            label: Text(_hasUnsavedChanges
                                ? 'Save Key Mappings'
                                : 'All Changes Saved'),
                            style: ElevatedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                backgroundColor:
                                    _hasUnsavedChanges ? null : Colors.grey),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The unbound count and its filter.
  ///
  /// Three sentences, one per state, and never a bare number — see the note at
  /// [kUnboundKeysCount]. Nothing here is coloured as a fault: this is the
  /// muted `onSurfaceVariant` the locks and the prompts use, because the
  /// shipped state is "no templates, every key unbound" and painting that
  /// amber would train the operator to ignore the one station-day where it
  /// matters.
  Widget _buildUnboundHeader(BuildContext context) {
    final theme = Theme.of(context);
    final total = _rows.length;
    final unbound = _unbound.length;
    final text = _bindings.templateNames.isEmpty
        ? kUnboundKeysNoTemplates(total)
        : unbound == 0
            ? kUnboundKeysAllBound(total)
            : kUnboundKeysCount(unbound, total);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              key: kUnboundKeysCountKey,
              // No maxLines: this line is the one thing on the page that says
              // the plant has a gap, and clipping it would be the failure it
              // exists to prevent.
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            key: kUnboundKeysFilterKey,
            label: const Text(kUnboundKeysFilterLabel),
            selected: _unboundOnly,
            visualDensity: VisualDensity.compact,
            onSelected: (selected) => setState(() {
              _unboundOnly = selected;
              _unboundFilterCache = null;
              _unboundFilterSource = null;
            }),
          ),
        ],
      ),
    );
  }

  /// Builds one key card. [reorderIndex] is non-null only in the
  /// reorderable (unfiltered) list.
  Widget _buildCard(_KeyRow row, {int? reorderIndex}) {
    // Every card gets a stable GlobalKey keyed by entry name, not just
    // newly-added ones. _renameKey and _reorderKey both keep the GlobalKey
    // associated with the entry's current name, so it survives reorders and
    // renames alike.
    final cardKey = _cardKeys.putIfAbsent(row.key, () => GlobalKey());
    return _KeyMappingCard(
      key: cardKey,
      keyName: row.key,
      entry: row.entry,
      bindings: _bindings,
      // The raw name, not the resolved template: a key naming a template that
      // no longer exists must render as a gap rather than as unbound, and
      // `templateForKey` answers null for both.
      boundTemplate: _resolver?.boundTemplateName(row.key),
      serverAliases: _serverAliases,
      jbtmServerAliases: _jbtmServerAliases,
      modbusServerAliases: _modbusServerAliases,
      modbusConfigs: _stateManConfig?.modbus ?? const [],
      onUpdate: (updated) => _updateEntry(row.key, updated),
      onRename: (newName) => _renameKey(row.key, newName),
      onCopy: () => _duplicateKey(row.key),
      onRemove: () => _showDeleteDialog(row.key),
      initiallyExpanded: _expandedKeys.contains(row.key),
      onExpansionChanged: (expanded) {
        // No setState: the tile animates itself, and this only needs to be
        // remembered for when the lazy list rebuilds the card.
        if (expanded) {
          _expandedKeys.add(row.key);
        } else {
          _expandedKeys.remove(row.key);
        }
      },
      status: _keyStatuses[row.key],
      reorderIndex: reorderIndex,
    );
  }

  void _showDeleteDialog(String key) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Remove key',
      message: 'Are you sure you want to remove "$key"?',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) _removeKey(key);
  }
}

// ===================== Empty State =====================

class _EmptyKeysWidget extends StatelessWidget {
  const _EmptyKeysWidget();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const FaIcon(FontAwesomeIcons.key, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text('No keys configured',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.grey)),
          const SizedBox(height: 8),
          const Text('Add your first key mapping to get started',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

// ===================== Key Mapping Card =====================

class _KeyMappingCard extends StatefulWidget {
  final String keyName;
  final KeyMappingEntry entry;
  final List<String> serverAliases;
  final List<String> jbtmServerAliases;
  final List<String> modbusServerAliases;
  final List<ModbusConfig> modbusConfigs;

  /// The store, the template names and whether any of it has loaded. Handed
  /// down rather than watched here so the header's count and this card's badge
  /// cannot disagree — see [KeyBindingView].
  final KeyBindingView bindings;

  /// The template name in `access_key_binding` for this key, dangling or not.
  final String? boundTemplate;
  final Function(KeyMappingEntry) onUpdate;
  final Function(String) onRename;
  final VoidCallback onCopy;
  final VoidCallback onRemove;
  final bool initiallyExpanded;

  /// Reported so the parent can remember expansion across the lazy list
  /// destroying and rebuilding this card as it scrolls.
  final ValueChanged<bool>? onExpansionChanged;
  final _KeyStatus? status;

  /// When non-null, this card is rendered inside a [ReorderableListView]
  /// and a drag handle is shown that lets the operator grab the card to
  /// reorder it. The value is the card's index in the reorderable list,
  /// which [ReorderableDragStartListener] uses to initiate the drag.
  final int? reorderIndex;

  const _KeyMappingCard({
    super.key,
    required this.keyName,
    required this.entry,
    required this.serverAliases,
    required this.jbtmServerAliases,
    required this.modbusServerAliases,
    required this.modbusConfigs,
    required this.bindings,
    required this.boundTemplate,
    required this.onUpdate,
    required this.onRename,
    required this.onCopy,
    required this.onRemove,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.status,
    this.reorderIndex,
  });

  @override
  State<_KeyMappingCard> createState() => _KeyMappingCardState();
}

class _KeyMappingCardState extends State<_KeyMappingCard> {
  late TextEditingController _keyNameController;
  late FocusNode _keyNameFocusNode;
  bool _collectEnabled = false;

  @override
  void initState() {
    super.initState();
    _keyNameController = TextEditingController(text: widget.keyName);
    _keyNameFocusNode = FocusNode();
    _keyNameFocusNode.addListener(_onKeyNameFocusChange);
    _collectEnabled = widget.entry.collect != null;
  }

  @override
  void didUpdateWidget(covariant _KeyMappingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyName != widget.keyName &&
        _keyNameController.text != widget.keyName) {
      _keyNameController.text = widget.keyName;
    }
    if ((widget.entry.collect != null) != _collectEnabled) {
      _collectEnabled = widget.entry.collect != null;
    }
  }

  void _onKeyNameFocusChange() {
    if (!_keyNameFocusNode.hasFocus) {
      _submitKeyName(_keyNameController.text);
    }
  }

  void _submitKeyName(String value) {
    if (value.isNotEmpty && value != widget.keyName) {
      widget.onRename(value);
    }
  }

  @override
  void dispose() {
    _keyNameFocusNode.removeListener(_onKeyNameFocusChange);
    _keyNameFocusNode.dispose();
    _keyNameController.dispose();
    super.dispose();
  }

  bool get _isM2400 => widget.entry.m2400Node != null;
  bool get _isModbus => widget.entry.modbusNode != null;

  String _buildSubtitle() {
    if (_isModbus) {
      final node = widget.entry.modbusNode!;
      final variableName = widget.entry.variableName;
      // Prefer the UMAS symbol path over the Modbus address when the
      // mapping is bound by name — operators recognise their FB-instance
      // member names, not 'holdingRegister[N]'.
      if (variableName != null && variableName.isNotEmpty) {
        return '$variableName${_aliasSuffix(node.serverAlias)}';
      }
      var subtitle = '${node.registerType.name}[${node.address}]';
      subtitle += ' ${node.dataType.name}';
      subtitle += _aliasSuffix(node.serverAlias);
      return subtitle;
    }
    if (_isM2400) {
      final node = widget.entry.m2400Node!;
      var subtitle = 'REC=${node.recordType.name}(${node.recordType.id})';
      if (node.field != null) {
        subtitle += '; FLD=${node.field!.displayName}(${node.field!.id})';
      }
      subtitle += _aliasSuffix(node.serverAlias);
      return subtitle;
    }
    final node = widget.entry.opcuaNode;
    if (node == null) return 'No config';
    var subtitle = 'ns=${node.namespace}; id=${node.identifier}';
    subtitle += _aliasSuffix(node.serverAlias);
    if (node.arrayIndex != null) {
      subtitle += ' [${node.arrayIndex}]';
    }
    return subtitle;
  }

  void _updateOpcUaConfig(OpcUANodeConfig config) {
    widget.onUpdate(widget.entry.copyWith(opcuaNode: config));
  }

  void _updateM2400Config(M2400NodeConfig config) {
    widget.onUpdate(widget.entry.copyWith(m2400Node: config));
  }

  void _switchToM2400() {
    widget.onUpdate(KeyMappingEntry(
      m2400Node: M2400NodeConfig(recordType: M2400RecordType.recBatch),
      collect: widget.entry.collect,
    ));
  }

  void _switchToOpcUa() {
    widget.onUpdate(KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 0, identifier: ''),
      collect: widget.entry.collect,
      bitMask: widget.entry.bitMask,
      bitShift: widget.entry.bitShift,
    ));
  }

  void _switchToModbus() {
    widget.onUpdate(KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        registerType: ModbusRegisterType.holdingRegister,
        address: 0,
      ),
      collect: widget.entry.collect,
      bitMask: widget.entry.bitMask,
      bitShift: widget.entry.bitShift,
    ));
  }

  // TD-010 (v1.1.x): _updateModbusConfig + _updatePickedVariableName
  // moved into [KeyMappingModbusSection] so the page editor and this
  // row share one implementation.

  void _updateBitMask(int? mask, int? shift) {
    if (mask == null) {
      widget.onUpdate(widget.entry.copyWith(clearBitMask: true));
    } else {
      widget.onUpdate(widget.entry.copyWith(bitMask: mask, bitShift: shift));
    }
  }

  /// Returns true if the current key uses a bit/boolean data type
  /// (coils, discrete inputs, or explicit bit type).
  /// When true, the bit mask grid restricts to single-bit selection.
  bool get _isBitType {
    if (_isModbus) {
      final node = widget.entry.modbusNode!;
      if (node.dataType == ModbusDataType.bit) return true;
      if (node.registerType == ModbusRegisterType.coil ||
          node.registerType == ModbusRegisterType.discreteInput) {
        return true;
      }
    }
    return false;
  }

  /// Returns the number of bits for the current data type.
  int get _bitCountForDataType {
    if (_isModbus) {
      final dt = widget.entry.modbusNode!.dataType;
      switch (dt) {
        case ModbusDataType.int32:
        case ModbusDataType.uint32:
        case ModbusDataType.float32:
          return 32;
        default:
          return 16;
      }
    }
    // OPC UA: default to 16 bits
    return 16;
  }

  void _toggleCollect(bool enabled) {
    setState(() => _collectEnabled = enabled);
    widget.onUpdate(widget.entry.copyWith(
      collect: enabled
          ? CollectEntry(
              key: widget.keyName,
              retention: const RetentionPolicy(
                  dropAfter: Duration(days: 365), scheduleInterval: null),
            )
          : null,
    ));
  }

  void _updateCollectEntry(CollectEntry collect) {
    widget.onUpdate(widget.entry.copyWith(collect: collect));
  }

  Widget _buildTrailing() {
    final chip = _buildStatusChip();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // What governs this key, at a glance, on the collapsed card. Draws
        // nothing when there is nothing to say — see [KeyBindingBadge].
        KeyBindingBadge(
          keyName: widget.keyName,
          bindings: widget.bindings,
          boundTemplate: widget.boundTemplate,
        ),
        if (chip != null) ...[
          chip,
          const SizedBox(width: 8),
        ],
        IconButton(
          icon: const FaIcon(FontAwesomeIcons.copy, size: 16),
          onPressed: widget.onCopy,
        ),
        IconButton(
          icon: const FaIcon(FontAwesomeIcons.trash, size: 16),
          onPressed: widget.onRemove,
        ),
        const SizedBox(width: 8),
        const FaIcon(FontAwesomeIcons.chevronDown, size: 16),
      ],
    );
  }

  Widget? _buildStatusChip() {
    if (widget.status == null) return null;
    final (color, label) = switch (widget.status!) {
      _KeyStatus.ok => (Colors.green, 'OK'),
      _KeyStatus.error => (Colors.red, 'Error'),
      _KeyStatus.serverDisconnected => (Colors.red, 'Disconnected'),
      // Grey, not red: the server is off because someone switched it off.
      _KeyStatus.serverDisabled => (Colors.grey, 'Disabled'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: widget.onExpansionChanged,
        leading: widget.reorderIndex != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ReorderableDragStartListener(
                    index: widget.reorderIndex!,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.0),
                        child: Icon(
                          Icons.drag_indicator,
                          size: 20,
                          color: Colors.grey,
                          semanticLabel: 'Drag to reorder',
                        ),
                      ),
                    ),
                  ),
                  FaIcon(
                    FontAwesomeIcons.key,
                    size: 20,
                    color: _collectEnabled ? Colors.green : null,
                  ),
                ],
              )
            : FaIcon(
                FontAwesomeIcons.key,
                size: 20,
                color: _collectEnabled ? Colors.green : null,
              ),
        title: Text(
          widget.keyName,
          style: const TextStyle(fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        subtitle: Text(
          _buildSubtitle(),
          style: TextStyle(color: Colors.grey[600]),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        trailing: _buildTrailing(),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Key name
                TextField(
                  controller: _keyNameController,
                  focusNode: _keyNameFocusNode,
                  decoration: const InputDecoration(
                    labelText: 'Key Name',
                    prefixIcon: FaIcon(FontAwesomeIcons.tag, size: 16),
                  ),
                  onChanged: (value) => _submitKeyName(value),
                  onSubmitted: (value) => _submitKeyName(value),
                ),
                const SizedBox(height: 12),
                // Device type selector
                if (widget.jbtmServerAliases.isNotEmpty ||
                    widget.modbusServerAliases.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Row(
                      children: [
                        const FaIcon(FontAwesomeIcons.plug, size: 14),
                        const SizedBox(width: 8),
                        Text('Device Type',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(width: 12),
                        ChoiceChip(
                          label: const Text('OPC UA'),
                          selected: !_isM2400 && !_isModbus,
                          onSelected: (selected) {
                            if (selected && (_isM2400 || _isModbus))
                              _switchToOpcUa();
                          },
                        ),
                        if (widget.jbtmServerAliases.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('M2400'),
                            selected: _isM2400,
                            onSelected: (selected) {
                              if (selected && !_isM2400) _switchToM2400();
                            },
                          ),
                        ],
                        if (widget.modbusServerAliases.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Modbus'),
                            selected: _isModbus,
                            onSelected: (selected) {
                              if (selected && !_isModbus) _switchToModbus();
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                // Protocol-specific config section
                if (_isModbus)
                  // TD-010 (v1.1.x): both the page editor and this key
                  // repository row used to inline the same picker-wiring
                  // boilerplate. Both now route through
                  // [KeyMappingModbusSection] so the wiring lives in one
                  // place and can't drift.
                  KeyMappingModbusSection(
                    entry: widget.entry,
                    modbusServerAliases: widget.modbusServerAliases,
                    modbusConfigs: widget.modbusConfigs,
                    onEntryChanged: widget.onUpdate,
                    defaultNodeConfigBuilder: () => widget.entry.modbusNode!,
                  )
                else if (_isM2400)
                  M2400ConfigSection(
                    config: widget.entry.m2400Node ??
                        M2400NodeConfig(recordType: M2400RecordType.recBatch),
                    jbtmServerAliases: widget.jbtmServerAliases,
                    onChanged: _updateM2400Config,
                  )
                else
                  OpcUaConfigSection(
                    config: widget.entry.opcuaNode ??
                        OpcUANodeConfig(namespace: 0, identifier: ''),
                    serverAliases: widget.serverAliases,
                    onChanged: _updateOpcUaConfig,
                  ),
                // Bit selection — required for bit types, optional mask
                // for others.
                //
                // F-5 (v1.1.x): when the operator has bound a UMAS symbol
                // path via Browse, the runtime read path ignores
                // bitMask/bitShift just like the address fields. Hide the
                // section entirely so there's no "edits the mask, nothing
                // happens" trap — the UMAS chip's clear-X re-exposes the
                // section.
                if (!_isM2400 &&
                    _isBitType &&
                    (widget.entry.variableName == null ||
                        widget.entry.variableName!.isEmpty)) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Bit Select (required)',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        BitMaskGrid(
                          bitCount: _bitCountForDataType,
                          currentMask: widget.entry.bitMask,
                          singleBit: true,
                          onChanged: (result) {
                            _updateBitMask(result.mask, result.shift);
                          },
                        ),
                      ],
                    ),
                  ),
                ] else if (!_isM2400 &&
                    (widget.entry.variableName == null ||
                        widget.entry.variableName!.isEmpty)) ...[
                  const Divider(),
                  ExpansionTile(
                    title: const Text('Bit Mask (optional)'),
                    initiallyExpanded: widget.entry.bitMask != null,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: BitMaskGrid(
                          bitCount: _bitCountForDataType,
                          currentMask: widget.entry.bitMask,
                          onChanged: (result) {
                            _updateBitMask(result.mask, result.shift);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                // Collection Config Section
                CollectionConfigSection(
                  enabled: _collectEnabled,
                  collect: widget.entry.collect,
                  keyName: widget.keyName,
                  onToggle: _toggleCollect,
                  onChanged: _updateCollectEntry,
                ),
                // Who may write this key. Last, and its own block: everything
                // above is how the key is *read* from the plant, and this is
                // the only control on the card that does not go through Save —
                // it writes the `users`-gated table the moment it is chosen.
                // The reasoning is at the section itself.
                KeyAccessTemplateSection(
                  keyName: widget.keyName,
                  bindings: widget.bindings,
                  boundTemplate: widget.boundTemplate,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== Import/Export Card =====================

class _KeyMappingsImportExportCard extends ConsumerWidget {
  const _KeyMappingsImportExportCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 500;
            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.sync_alt, size: 20),
                      const SizedBox(width: 8),
                      Text('Import / Export',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _onImport(context, ref),
                    icon: const FaIcon(FontAwesomeIcons.fileImport, size: 16),
                    label: const Text('Import'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _onExport(context, ref),
                    icon: const FaIcon(FontAwesomeIcons.fileExport, size: 16),
                    label: const Text('Export'),
                  ),
                ],
              );
            }
            return Row(
              children: [
                const Icon(Icons.sync_alt, size: 20),
                const SizedBox(width: 8),
                Text('Import / Export',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _onImport(context, ref),
                  icon: const FaIcon(FontAwesomeIcons.fileImport, size: 16),
                  label: const Text('Import'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _onExport(context, ref),
                  icon: const FaIcon(FontAwesomeIcons.fileExport, size: 16),
                  label: const Text('Export'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _onExport(BuildContext context, WidgetRef ref) async {
    // ---------------------------------------------------------------------
    // Decided, 04-08: this file carries **no** access bindings, and there is
    // no "also export bindings" option, no second file and no bindings section
    // in the JSON. Written here because the omission looks like one.
    //
    // The reason is the 2026-08-30 ruling itself. An export/import pair that
    // carried bindings would put an authorization write behind this card —
    // which is `configure`-gated, on a `configure`-gated route — and then make
    // it portable between stations. That is precisely the path the ruling
    // closed, re-opened in file form. A binding has to be written by something
    // that checks `users` and leaves an audit row naming a person; a JSON file
    // dropped through a file picker is neither.
    //
    // The supported way to move bindings between stations is the MCP sweep:
    // `list_access_templates` and `bind_key_access_template`, which propose,
    // are approved by somebody holding `users`, and land in the trail with
    // `origin: 'mcp'`. That is named in the copy below, not only here.
    // ---------------------------------------------------------------------
    try {
      final store = await ref.read(configStoreProvider.future);
      final keyMappings = store.inner.keyMappings;
      final jsonString =
          const JsonEncoder.withIndent('  ').convert(keyMappings.toJson());

      String? savePath;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Export Key Mappings',
          fileName: 'key_mappings.json',
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
        savePath = path.join(dir.path, 'key_mappings_$ts.json');
      }
      if (savePath == null) return;

      final file = File(savePath);
      await file.writeAsString(jsonString);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Key mappings exported to ${file.path}',
                // The path is the one line here that may be elided: it can be
                // arbitrarily long, and letting it wrap without limit would
                // push the disclosure below off the strip — which is the line
                // that matters.
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                kKeyMappingsExportBindingsNote,
                // Pinned rather than left to the default so a later change to
                // the copy fails the height assertion instead of silently
                // ellipsising the sentence that says what the file does not
                // contain.
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    }
  }

  Future<void> _onImport(BuildContext context, WidgetRef ref) async {
    try {
      final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: 'Import Key Mappings',
      );
      if (pick == null || pick.files.single.path == null) return;

      final file = File(pick.files.single.path!);
      final jsonMap =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final imported = KeyMappings.fromJson(jsonMap);

      if (!context.mounted) return;

      // Confirm overwrite — and say, before it runs, what the file does not
      // carry. The bindings are untouched by everything below: this path holds
      // `configure`, a binding needs `users`, and clearing them "to stay
      // consistent" would be the silent unbind spec §7d forbids on a delete.
      // A row whose key the import removes is left orphaned on purpose; the
      // unbound count above is where it shows up.
      final confirm = await showConfirmDialog(
        context: context,
        title: 'Import key mappings',
        message: 'This will overwrite all existing key mappings with '
            '${imported.nodes.length} imported keys. Continue?'
            '\n\n$kKeyMappingsImportBindingsNote',
        confirmLabel: 'Import',
        destructive: true,
      );
      if (!confirm) return;

      final store = await ref.read(configStoreProvider.future);
      // A replace, and the store's diff does the delete accounting: a key the
      // file does not carry becomes a removal row rather than disappearing
      // inside a rewritten blob. This is the first import that is legible in
      // the change log.
      await store.saveKeyMappings(imported);
      // Applied incrementally by the stateManProvider store listener; it
      // self-invalidates only if the import touches Modbus/M2400 keys.

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Imported ${imported.nodes.length} key mappings successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    } on ConfigStoreOfflineException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Not imported — the database is unreachable. '
                'Nothing was written: ${e.attempted}.'),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    } on ConfigConflict catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Not imported — "${e.key}" was changed on another '
                'station. Reload the page and import again.'),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    }
  }
}
