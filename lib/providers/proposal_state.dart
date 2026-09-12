import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../core/pending_proposals_store.dart';
import 'preferences.dart' show localPreferencesProvider;
import 'proposal.dart';

export 'proposal.dart'
    show PendingProposal, ProposalOp, nextLocalProposalId, proposalRoutes;

/// Prefix marking operator-decision notes in the chat conversation.
///
/// Notes carry the user role so every LLM provider keeps them in
/// chronological order (Claude hoists system-role messages into the system
/// parameter), and the prefix lets [MessageBubble] hide them -- they are
/// feedback for the AI, not something the operator needs shown back.
const kOperatorDecisionPrefix = '[Operator decision]';

/// An operator decision on AI proposals, relayed back to the AI.
///
/// Emitted by [ProposalStateNotifier] whenever the operator accepts,
/// rejects, dismisses, or opens a proposal -- from any surface (banner
/// buttons, batch cards, editor commit/discard). The chat layer turns these
/// into operator-decision notes in the conversation so the AI learns what
/// happened to its proposals.
class ProposalFeedback {
  /// One of `accepted`, `rejected`, `dismissed`, `viewed`.
  final String action;

  /// The proposals the action applied to. Bulk actions arrive as one event.
  final List<PendingProposal> proposals;

  const ProposalFeedback({required this.action, required this.proposals});
}

/// Broadcast channel for [ProposalFeedback] events.
///
/// Lives outside [proposalStateProvider] so the chat lifecycle can subscribe
/// once, independently of the notifier's own lifetime.
final proposalFeedbackProvider =
    Provider<StreamController<ProposalFeedback>>((ref) {
  final controller = StreamController<ProposalFeedback>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

/// Immutable snapshot of all pending proposals across types.
class ProposalState {
  final List<PendingProposal> proposals;

  const ProposalState({this.proposals = const []});

  int get pendingCount => proposals.length;

  bool get hasPending => proposals.isNotEmpty;

  /// Filter proposals by type (alarm, page, asset, key_mapping).
  List<PendingProposal> ofType(String type) =>
      proposals.where((p) => p.proposalType == type).toList();
}

/// Holds the proposals the operator has not decided on yet.
///
/// A proposal exists from the moment a write tool hands it to the UI until
/// the operator accepts, rejects or dismisses it. Accepting is what makes the
/// *change* durable, and that write belongs to the editor.
///
/// The queue itself is mirrored to the device-local store through [store]
/// on every change, and read back when the next notifier is built. That is
/// what lets it outlive the Windows runner's engine rebuilds: a rebuild is a
/// new Dart isolate, and until this landed every undecided proposal went with
/// the old one -- see `lib/core/pending_proposals_store.dart`. A notifier
/// built without a store (tests, a platform with no preferences plugin)
/// behaves exactly as before.
class ProposalStateNotifier extends StateNotifier<ProposalState> {
  ProposalStateNotifier({
    StreamController<ProposalFeedback>? feedback,
    PendingProposalStore? store,
    Logger? logger,
  })  : _feedback = feedback,
        _store = store,
        _logger = logger ?? Logger(),
        super(const ProposalState()) {
    if (store != null) {
      unawaited(_restore(store));
    }
  }

  final StreamController<ProposalFeedback>? _feedback;
  final PendingProposalStore? _store;
  final Logger _logger;

  /// Writes are chained so two rapid changes cannot land on disk out of
  /// order: the later state must be the one that survives.
  Future<void> _writes = Future<void>.value();

  /// Proposals already reported as viewed, so re-opening an editor does not
  /// spam the AI with repeat notes.
  final _viewedIds = <int>{};

  /// Every change to [state] goes through here, so every change is mirrored.
  /// Persisting from the setter rather than from each mutator is what makes
  /// it impossible for a new decision path to forget to.
  @override
  set state(ProposalState value) {
    super.state = value;
    _persist();
  }

  void _persist() {
    final store = _store;
    if (store == null) return;
    final snapshot = [
      for (final p in state.proposals)
        PersistedProposal(
          proposalType: p.proposalType,
          title: p.title,
          proposalJson: p.proposalJson,
          operatorId: p.operatorId,
          createdAt: p.createdAt,
          viewed: _viewedIds.contains(p.id),
        ),
    ];
    _writes = _writes.then((_) => store.save(snapshot));
  }

  /// Brings back whatever the previous isolate left undecided.
  ///
  /// Runs after construction, so proposals can already have arrived by the
  /// time the store answers: the restored ones are placed *before* them --
  /// they are older -- and anything whose JSON is already present is dropped,
  /// the same identity rule [addProposal] uses. Ids are minted afresh; a
  /// restored proposal that had been viewed is marked so, and is not
  /// reported as viewed a second time.
  Future<void> _restore(PendingProposalStore store) async {
    final restored = await store.load();
    if (!mounted || restored.isEmpty) return;

    final present = state.proposals.map((p) => p.proposalJson).toSet();
    final revived = <PendingProposal>[];
    for (final stored in restored) {
      if (!present.add(stored.proposalJson)) continue;
      final id = nextLocalProposalId();
      if (stored.viewed) _viewedIds.add(id);
      revived.add(PendingProposal(
        id: id,
        proposalType: stored.proposalType,
        title: stored.title,
        proposalJson: stored.proposalJson,
        operatorId: stored.operatorId,
        createdAt: stored.createdAt,
      ));
    }
    if (revived.isEmpty) return;

    _logger.i('Restored ${revived.length} pending proposal(s) left undecided '
        'by the previous engine generation');
    state = ProposalState(proposals: [...revived, ...state.proposals]);
  }

  /// Proposal payloads an editor has already resolved -- applied or discarded.
  ///
  /// Every editor stages proposals two ways: out of [state], and out of the
  /// raw JSON its route carries. The route fallback exists because the chat
  /// batch card calls [acceptAllOfType] *before* it beams, so the JSON on the
  /// route is the only copy left of a batch that still has to be applied; an
  /// editor takes that path whenever [state] holds nothing for it.
  ///
  /// Beamer keeps that JSON on the location, so it is handed to the editor
  /// again on every later mount -- and by then the proposal has been accepted
  /// and dropped from [state], which is exactly the condition the fallback
  /// triggers on. Rebuilding the editor was therefore enough to stage an
  /// already-applied proposal a second time: the amber strip came back over a
  /// mapping that was already written, with nothing pending anywhere that
  /// could take it down again.
  ///
  /// So editors record here what they have resolved, and the route fallback
  /// consults it. Keyed by the payload rather than by proposal id, because
  /// the route carries no id: [addProposal] already treats the JSON as a
  /// proposal's identity for the same reason.
  ///
  /// A set literal keeps insertion order, which makes the cap below a plain
  /// FIFO trim. This record is deliberately NOT persisted with the queue: it
  /// answers for route payloads, and Beamer's route data does not survive an
  /// engine restart either, so a restored editor starts with nothing to
  /// double-stage. The record only ever has to outlive an editor's State.
  final _resolvedRoutePayloads = <String>{};

  /// How many resolved payloads to remember. Far more than the handful of
  /// batches an operator resolves in a sitting, and small enough that the set
  /// cannot grow without bound over a station's uptime.
  static const _resolvedRoutePayloadLimit = 128;

  /// Records that an editor has applied or discarded [json], so a later mount
  /// handed the same route payload does not stage it again.
  ///
  /// See [_resolvedRoutePayloads]. Safe to call with a payload that was never
  /// staged from a route: the record is only ever read by that fallback.
  void markRoutePayloadResolved(String json) {
    _resolvedRoutePayloads.add(json);
    while (_resolvedRoutePayloads.length > _resolvedRoutePayloadLimit) {
      _resolvedRoutePayloads.remove(_resolvedRoutePayloads.first);
    }
  }

  /// Whether [json] has already been resolved by an editor.
  ///
  /// Only the route fallback asks. Staging out of [state] deliberately does
  /// not, so a proposal the AI makes again -- identical JSON, freshly
  /// pending -- still reaches the operator.
  bool isRoutePayloadResolved(String json) =>
      _resolvedRoutePayloads.contains(json);

  /// Add a proposal if it is not already present.
  ///
  /// Deduplicates by both id and proposal JSON content. The JSON check is the
  /// one that does the work: an in-app tool call surfaces the same proposal
  /// twice, once from the server's proposal callback and once from the tool
  /// result, and those two carry different locally-minted ids but identical
  /// JSON -- the write tool returns the encoding of the very map the callback
  /// was handed.
  void addProposal(PendingProposal proposal) {
    if (state.proposals.any((p) =>
        p.id == proposal.id || p.proposalJson == proposal.proposalJson)) {
      return;
    }
    state = ProposalState(
      proposals: [...state.proposals, proposal],
    );
  }

  /// Accept a proposal: report the decision and drop it from state.
  ///
  /// The `async` suspends nothing now that there is no write to wait for, so
  /// the removal lands in the caller's own microtask. That is what closes the
  /// "yellow boxes came back" race: a batch accept fired these without
  /// awaiting the database round trip inside, and the editor's listener
  /// re-staged whatever had not been removed yet. The [Future] stays because
  /// every editor call site awaits it.
  Future<void> acceptProposal(int id) async {
    _emitFeedback('accepted', id);
    _removeFromState(id);
  }

  /// Reject a proposal: report the decision and drop it from state.
  Future<void> rejectProposal(int id) async {
    _emitFeedback('rejected', id);
    _removeFromState(id);
  }

  /// Dismiss a proposal: report the decision and drop it from state.
  Future<void> dismissProposal(int id) async {
    _emitFeedback('dismissed', id);
    _removeFromState(id);
  }

  /// Record that the operator opened a proposal in its editor.
  ///
  /// Keeps the proposal pending -- a look is not a decision. Reported to the
  /// AI once per proposal.
  Future<void> viewProposal(int id) async {
    if (!state.proposals.any((p) => p.id == id)) return;
    if (!_viewedIds.add(id)) return;
    _emitFeedback('viewed', id);
    // The look is part of what the next isolate has to know, or it would
    // report the same view again.
    _persist();
  }

  /// Accept all proposals of a given type.
  ///
  /// Returns the accepted proposals so the caller can route them to editors.
  /// Removes exactly the ids it reported on, so a proposal that arrives in
  /// the meantime stays pending rather than being silently swallowed.
  Future<List<PendingProposal>> acceptAllOfType(String type) async {
    final matching =
        state.proposals.where((p) => p.proposalType == type).toList();
    final matchingIds = matching.map((p) => p.id).toSet();
    _emitFeedbackAll('accepted', matching);
    state = ProposalState(
      proposals:
          state.proposals.where((p) => !matchingIds.contains(p.id)).toList(),
    );
    return matching;
  }

  /// Reject all proposals of a given type. See [acceptAllOfType].
  Future<void> rejectAllOfType(String type) async {
    final matching =
        state.proposals.where((p) => p.proposalType == type).toList();
    final matchingIds = matching.map((p) => p.id).toSet();
    _emitFeedbackAll('rejected', matching);
    state = ProposalState(
      proposals:
          state.proposals.where((p) => !matchingIds.contains(p.id)).toList(),
    );
  }

  void _removeFromState(int id) {
    state = ProposalState(
      proposals: state.proposals.where((p) => p.id != id).toList(),
    );
  }

  /// Emits feedback for a single proposal still present in state.
  ///
  /// A decision on an id that is no longer in state (already consumed by a
  /// concurrent path) carries no title or type to report, so it is skipped.
  void _emitFeedback(String action, int id) {
    final matches = state.proposals.where((p) => p.id == id);
    if (matches.isEmpty) return;
    _emitFeedbackAll(action, [matches.first]);
  }

  void _emitFeedbackAll(String action, List<PendingProposal> proposals) {
    final feedback = _feedback;
    if (feedback == null || feedback.isClosed || proposals.isEmpty) return;
    feedback.add(ProposalFeedback(action: action, proposals: proposals));
  }
}

/// The device-local store the pending queue is mirrored to, or null when
/// there is none to be had.
///
/// Null rather than an error on purpose: [localPreferencesProvider] builds a
/// `SharedPreferencesAsync`, which throws when no platform implementation is
/// registered -- every widget test that does not stub it. The queue must
/// keep working without a store, exactly as it did before persistence, so
/// that failure is absorbed here and never reaches [proposalStateProvider].
final pendingProposalStoreProvider = Provider<PendingProposalStore?>((ref) {
  try {
    return PendingProposalStore(ref.watch(localPreferencesProvider));
  } catch (_) {
    return null;
  }
});

/// Universal proposal state provider.
///
/// Tracks all pending proposals across types (alarm, page, asset,
/// key_mapping). Fed by `ChatNotifier`, which is where the MCP server's
/// proposal callback lands. Deliberately depends on nothing that can rebuild:
/// it used to watch the database connection, so a reconnect rebuilt the
/// notifier and dropped every proposal the operator had not yet acted on.
/// The store provider above is a plain value that is built once and never
/// invalidated.
final proposalStateProvider =
    StateNotifierProvider<ProposalStateNotifier, ProposalState>((ref) {
  return ProposalStateNotifier(
    feedback: ref.watch(proposalFeedbackProvider),
    store: ref.watch(pendingProposalStoreProvider),
  );
});


/// How the banner commits a staged proposal.
///
/// Applying a proposal and saving it belongs to the page editor -- it owns the
/// page data and the undo snapshot. The operator's accept/reject controls
/// belong in one place, the notification banner, rather than being duplicated
/// on an in-editor bar where one copy applied and the other silently did not.
/// The editor publishes its commit here while it is showing a staged
/// proposal; the banner calls it. Null when nothing is staged.
final proposalCommitProvider =
    StateProvider<Future<void> Function()?>((ref) => null);

/// How the banner discards a staged proposal.
///
/// Counterpart to [proposalCommitProvider]: reverting the staged edit needs
/// the editor's pre-proposal snapshot, which only the editor holds.
final proposalDiscardProvider =
    StateProvider<Future<void> Function()?>((ref) => null);

/// How the banner hands a proposal to an editor that is already on screen.
///
/// The banner's View and "Review all" beam to the proposal's editor route.
/// That works from anywhere else in the app, but not from the editor itself:
/// beaming to the route you are already on rebuilds the route's *builder*
/// and not the page it built. Flutter's page-based routes only re-run
/// `buildPage` on `changedExternalState`, and a settings change routes
/// through `changedInternalState` instead -- so the freshly built
/// `PageEditor(proposalData: ...)` is thrown away, the mounted one never sees
/// the new proposal, and `didUpdateWidget` never runs.
///
/// So the mounted editor publishes a way in. While it is up, the banner calls
/// this instead of beaming; with nothing published, the beam is still the
/// right answer because the editor has to be built in the first place.
class ProposalReviewEntry {
  const ProposalReviewEntry({required this.route, required this.enter});

  /// The editor route this entry serves, e.g. `/advanced/page-editor`.
  ///
  /// Checked against [PendingProposal.editorRoute] before use: an alarm
  /// proposal must not be handed to the page editor just because the page
  /// editor happens to be the screen in front of the operator.
  final String route;

  /// Routes the open editor to the proposal and stages it, the same thing a
  /// cold open does through `initState`.
  final void Function(String proposalJson) enter;
}

/// The editor currently on screen, if it is one that can take a proposal.
///
/// Null whenever no such editor is mounted. See [ProposalReviewEntry].
final proposalReviewProvider =
    StateProvider<ProposalReviewEntry?>((ref) => null);
