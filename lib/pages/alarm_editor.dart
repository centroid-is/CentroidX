import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/alarm.dart';
import '../widgets/base_scaffold.dart';
import 'package:tfc_dart/core/alarm.dart';
import '../providers/alarm.dart';
import '../providers/proposal_state.dart';

class AlarmEditorPage extends ConsumerStatefulWidget {
  /// Optional proposal JSON passed via Beamer route data.
  final String? proposalData;

  const AlarmEditorPage({Key? key, this.proposalData}) : super(key: key);

  @override
  ConsumerState<AlarmEditorPage> createState() => _AlarmEditorPageState();
}

class _AlarmEditorPageState extends ConsumerState<AlarmEditorPage> {
  AlarmConfig? _edit;
  AlarmConfig? _show;
  bool _create = false;
  AlarmConfig? _createTemplate;

  /// Proposals staged as a batch.
  ///
  /// An MCP client fires create_alarm one call per alarm, so a set of 38
  /// arrives as 38 proposals. Staging one at a time meant 38 separate
  /// reviews and 38 separate saves.
  /// The banner's callback slots, captured when publishing.
  ///
  /// Riverpod forbids `ref` inside dispose() -- "Cannot use ref after the
  /// widget was disposed" -- and these are plain (non-autoDispose)
  /// StateProviders, so their controllers outlive this State and can be held.
  StateController<Future<void> Function()?>? _commitSlot;
  StateController<Future<void> Function()?>? _discardSlot;

  /// The provider container the banner's accept and reject work through,
  /// captured while this page is still alive.
  ///
  /// Same reason the slots above are held: the banner outlives this page. It
  /// is published once and stays up while the operator navigates, so by the
  /// time a button is pressed this State can be gone and `ref` throws before
  /// a single alarm is written. On 2026-08-21 that shape left a batch of 16
  /// key mappings impossible to either accept or reject -- the mappings were
  /// saved, no proposal was marked accepted, and the batch came back on the
  /// next load. A ProviderContainer belongs to the ProviderScope at the app
  /// root, so it outlives this widget and can be held safely; reading the
  /// providers off it at call time also keeps them current across an
  /// invalidate, which a cached notifier would not.
  ProviderContainer? _container;

  /// The messenger to report through once a proposal is staged.
  ///
  /// Context-derived, so unlike the providers there is no container to
  /// re-read it from. `mounted` is not enough of a guard for the lookup:
  /// an element that has been *deactivated* still reports `mounted == true`,
  /// and `ScaffoldMessenger.of` walks ancestors that are no longer there.
  ScaffoldMessengerState? _messengerHandle;

  /// Where to report from. The handle whenever there is one -- every path
  /// that can outlive the page has one by then. The live lookup covers the
  /// form being used before anything was staged, when the page is by
  /// definition on screen.
  ScaffoldMessengerState? get _messenger {
    final handle = _messengerHandle;
    if (handle != null) return handle;
    return mounted ? ScaffoldMessenger.maybeOf(context) : null;
  }

  final List<AlarmConfig> _proposedAlarms = [];
  final List<int> _proposalIds = [];

  /// Uids among [_proposedAlarms] that accepting should *remove*.
  ///
  /// Kept by uid rather than by index because a batch mixes creates, updates
  /// and deletes -- they arrive as separate MCP calls -- and the form pops
  /// entries off the front of the list as it accepts them one at a time.
  final Set<String> _proposedDeleteUids = {};

  bool get _isProposal => _proposedAlarms.isNotEmpty;

  /// Whether the alarm the form is showing is staged for removal.
  bool get _proposedIsDelete =>
      _proposedAlarm != null &&
      _proposedDeleteUids.contains(_proposedAlarm!.uid);

  /// The alarm the form edits: the first of the batch. Accepting from the
  /// form applies that one edited config and leaves the rest staged.
  AlarmConfig? get _proposedAlarm =>
      _proposedAlarms.isEmpty ? null : _proposedAlarms.first;

  @override
  void initState() {
    super.initState();
    if (_stageAlarmProposals() == 0) _stageRoutedProposal(widget.proposalData);
  }

  /// Stages the proposal the route carried, for callers that removed it from
  /// state before navigating.
  ///
  /// The chat batch card calls acceptAllOfType() -- which empties
  /// proposalStateProvider -- and only then beams here with the JSON in tow.
  /// Reading state alone would stage nothing and apply nothing, while every
  /// proposal in the batch had already been marked accepted.
  ///
  /// Not the payload this editor has already resolved, though. Beamer keeps
  /// the JSON on the location, so a later mount is handed it again -- with
  /// state empty, because the proposal was accepted and dropped, which is the
  /// condition this fallback triggers on. Navigating back would otherwise
  /// stage an alarm that is already written and put the amber strip back up
  /// over it, with nothing pending anywhere to take it down.
  void _stageRoutedProposal(String? json) {
    if (json == null) return;
    if (_routePayloadResolved(json)) return;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return;
      final map = Map<String, dynamic>.from(decoded)..remove('_proposal_type');
      final isDelete = map.remove('_op') == 'delete';
      final config = AlarmConfig.fromJson(map);
      _proposedAlarms.add(config);
      if (isDelete) _proposedDeleteUids.add(config.uid);
      _publishProposalCallbacks();
    } catch (_) {
      // Malformed JSON: nothing to stage.
    }
  }

  /// Whether the route payload has already been applied or discarded here.
  ///
  /// Through `ref`, because this runs from [initState] where the container
  /// has not been captured yet.
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

  /// Marks the route payload resolved, so a later mount of this page does not
  /// stage it again. See [_stageRoutedProposal].
  ///
  /// Recorded on the notifier because the record has to outlive this State.
  void _markRoutePayloadResolved([ProviderContainer? container]) {
    final json = widget.proposalData;
    if (json == null) return;
    final scope = container ?? _container;
    if (scope == null) return;
    scope.read(proposalStateProvider.notifier).markRoutePayloadResolved(json);
  }

  /// Stages every pending alarm proposal in one batch.
  ///
  /// Safe to re-enter: ids already staged are skipped, so a proposal landing
  /// after the first joins the batch instead of being dropped on the floor.
  ///
  /// Returns how many were newly staged.
  int _stageAlarmProposals() {
    var added = 0;
    try {
      final state = ref.read(proposalStateProvider);
      for (final p in state.proposals) {
        if (p.proposalType != 'alarm' &&
            p.proposalType != 'alarm_create' &&
            p.proposalType != 'alarm_update') {
          continue;
        }
        if (_proposalIds.contains(p.id)) continue;
        try {
          final decoded = jsonDecode(p.proposalJson);
          if (decoded is! Map<String, dynamic>) continue;
          final map = Map<String, dynamic>.from(decoded)
            ..remove('_proposal_type');
          // delete_alarm sends the whole config so it parses like any other
          // proposal; only `_op` says what accepting it does.
          final isDelete = map.remove('_op') == 'delete';
          final config = AlarmConfig.fromJson(map);
          _proposedAlarms.add(config);
          if (isDelete) _proposedDeleteUids.add(config.uid);
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
  /// The inline amber Accept/Reject bar that used to sit above the editor is
  /// gone: one place to act on a proposal, not two. The form below still
  /// offers "Accept Proposal" for the alarm being edited, which is a
  /// different job -- accepting an *edited* config.
  void _publishProposalCallbacks() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final commitSlot = ref.read(proposalCommitProvider.notifier);
      commitSlot.state = _commitProposals;
      _commitSlot = commitSlot;
      final discardSlot = ref.read(proposalDiscardProvider.notifier);
      discardSlot.state = _discardProposals;
      _discardSlot = discardSlot;
      // Taken here, where `ref` and `context` are known good, because the two
      // callbacks above can be invoked long after this page is gone.
      _container = ProviderScope.containerOf(context, listen: false);
      _messengerHandle = ScaffoldMessenger.maybeOf(context);
    });
  }

  /// Applies every staged alarm, then marks the proposals accepted.
  Future<void> _commitProposals() async {
    if (_proposedAlarms.isEmpty) return;
    // Through the container, never `ref`: this is the banner's accept, and by
    // the time it runs this page may be disposed. `ref` throws then, and it
    // throws again after the await below even when the page was alive at the
    // start -- which is how a batch could be written and left pending.
    final container = _container;
    if (container == null) return;
    // Deliberately NOT wrapped in a try: a failure here must abort before
    // anything is marked accepted. Swallowing it and running the accept loop
    // anyway would write zero alarms and still mark all N proposals accepted,
    // which is exactly the loss the ordering below exists to prevent.
    final alarmMan = await container.read(alarmManProvider.future);
    for (final a in _proposedAlarms) {
      // updateAlarm writes the uid back -- in place now, but still written --
      // so routing a removal through it would leave the alarm standing and
      // delete nothing.
      if (_proposedDeleteUids.contains(a.uid)) {
        alarmMan.removeAlarm(a);
      } else {
        alarmMan.updateAlarm(a);
      }
    }
    container.invalidate(alarmManProvider);

    // Awaited, and only after the alarms are in: acceptProposal marks the row
    // accepted in the database, so doing it first would lose them on failure.
    final notifier = container.read(proposalStateProvider.notifier);
    for (final id in _proposalIds) {
      try {
        await notifier.acceptProposal(id);
      } catch (e) {
        // Reported rather than swallowed: an accept that silently fails to
        // land leaves the proposal pending with its alarm already written,
        // and the batch returns on the next load with nothing to explain it.
        debugPrint('alarm proposal $id could not be marked accepted: $e');
      }
    }
    _clearStagedBatch();
  }

  /// Drops the whole batch without adding any alarm.
  Future<void> _discardProposals() async {
    // See [_commitProposals]: this is the banner's reject, and reaching for
    // `ref` here is what threw "Cannot use ref after the widget was disposed"
    // before a single proposal could be marked rejected.
    final container = _container;
    if (container == null) return;
    final notifier = container.read(proposalStateProvider.notifier);
    for (final id in _proposalIds) {
      try {
        await notifier.rejectProposal(id);
      } catch (e) {
        debugPrint('alarm proposal $id could not be marked rejected: $e');
      }
    }
    _clearStagedBatch();
  }

  /// Drops the staged batch and retires the banner, whether or not this page
  /// is still on screen.
  ///
  /// The slots go through the stored controllers rather than `ref.read`, for
  /// the same reason the callbacks do; only the rebuild depends on [mounted].
  void _clearStagedBatch() {
    // Before the lists are emptied is as good as after; what matters is that
    // the route payload stops being stageable at the same moment the batch
    // it staged stops existing.
    _markRoutePayloadResolved();
    _proposedAlarms.clear();
    _proposalIds.clear();
    // Cleared with the alarms it annotates. Left behind, a uid staged for
    // deletion in one batch marks an unrelated alarm that happens to reuse
    // the uid in the next one, and accepting that batch removes it instead
    // of writing it.
    _proposedDeleteUids.clear();
    _show = null;
    if (mounted) setState(() {});
    _commitSlot?.state = null;
    _discardSlot?.state = null;
  }

  /// Accept the proposal with the (possibly edited) alarm config from the form.
  ///
  /// A removal goes through [AlarmMan.removeAlarm]; everything else through
  /// [AlarmMan.updateAlarm], which handles both create and update:
  /// - For new alarms (no matching UID): appended to the end of the list.
  /// - For updated alarms (matching UID): replaced where it already sits, so
  ///   accepting an edit neither duplicates the alarm nor moves it.
  Future<void> _acceptProposalWithConfig(AlarmConfig editedConfig) async {
    final removing = _proposedDeleteUids.contains(editedConfig.uid);
    // The form's own Accept starts with this page on screen, so `ref` would
    // work for the first read -- but not after the awaits below, and this
    // method awaits twice before it is done touching providers. The container
    // is read off the captured handle for the same reason the banner's
    // callbacks are: it outlives the page, and reading the providers off it
    // at call time keeps them current across an invalidate.
    var container = _container;
    if (container == null && mounted) {
      container = ProviderScope.containerOf(context, listen: false);
    }
    if (container == null) return;
    // Taken before the first await, while the page is certainly on screen and
    // an ancestor lookup is safe.
    final messenger = _messenger;
    try {
      final alarmMan = await container.read(alarmManProvider.future);
      if (removing) {
        alarmMan.removeAlarm(editedConfig);
      } else {
        alarmMan.updateAlarm(editedConfig);
      }

      // Invalidate the provider so the alarm list rebuilds with the new alarm.
      container.invalidate(alarmManProvider);
    } catch (_) {}

    // Only the alarm the form was editing leaves the batch; anything else
    // still staged stays for the banner to accept.
    //
    // There is an id to mark accepted only for a proposal staged out of
    // `proposalStateProvider`. One staged from the route carries none -- the
    // chat batch card calls acceptAllOfType() before it beams here, so the
    // proposal is already out of state and already marked. Nesting the batch
    // pop below inside this block is what left an accepted routed proposal
    // staged forever: the alarm was written, and the amber staged strip, the
    // highlighted row and the "Accept Proposal" pane all stayed up over an
    // alarm that was already saved.
    if (_proposalIds.isNotEmpty) {
      // Removed only AFTER the await returns. Dropping it first meant a
      // failed accept left the id out of _proposalIds while still in state,
      // and the next listener tick re-staged it as a duplicate.
      final id = _proposalIds.first;
      await container.read(proposalStateProvider.notifier).acceptProposal(id);
      _proposalIds.removeAt(0);
    }
    // The alarm leaves the batch however it was staged. The delete flag
    // leaves with the alarm it marks: dropping it earlier would leave a
    // still-staged removal looking like an ordinary update.
    if (_proposedAlarms.isNotEmpty) {
      _proposedDeleteUids.remove(_proposedAlarms.removeAt(0).uid);
    }

    // Told through the handle, not a fresh lookup: navigating away mid-accept
    // deactivates this element, which still reports `mounted == true` while
    // `ScaffoldMessenger.of` is already walking ancestors that are gone.
    messenger?.showSnackBar(
      SnackBar(
          content:
              Text(removing ? 'Alarm removed.' : 'Alarm proposal accepted!')),
    );

    _show = null;
    if (mounted) setState(() {});
    // Through the stored controllers, for the same reason: the accept may
    // have outlived the page, and the banner still has to lose its buttons.
    if (_proposedAlarms.isEmpty) {
      // The batch the route staged is gone, so the payload must stop being
      // stageable with it -- otherwise coming back to this page stages the
      // alarm that was just written and puts the strip back over it.
      _markRoutePayloadResolved(container);
      _commitSlot?.state = null;
      _discardSlot?.state = null;
    }
  }

  @override
  void dispose() {
    // The banner holds these closures over this State. Left set, "Accept all"
    // would call into a disposed State after navigating away: nothing saved,
    // proposals still pending, and an uncaught async error.
    //
    // After this frame, not during it: navigating away disposes us from
    // inside a build, and writing to a provider there trips riverpod's
    // "tried to modify a provider while the widget tree was building". Only
    // if the slot still holds our own closure -- an editor that replaced us
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reactively watch for new alarm proposals arriving via MCP.
    ref.listen<ProposalState>(proposalStateProvider, (prev, next) {
      // No "already showing one" guard: a later proposal joins the batch.
      if (_stageAlarmProposals() > 0) setState(() {});
    });

    return BaseScaffold(
      title: _isProposal ? 'Alarm Editor -- AI Proposal' : 'Alarms Editor',
      body: Column(
        children: [
          // The inline amber Accept/Reject bar used to live here. Removed:
          // the black banner is the one place proposals are acted on. What
          // remains is a plain count, so a staged batch is still obvious.
          if (_isProposal)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.amber.shade50,
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.amber),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_proposedAlarms.length == 1
                        ? _proposedIsDelete
                            ? 'AI proposal: remove ${_proposedAlarm!.title}'
                            : 'AI proposal: ${_proposedAlarm!.title}'
                        : '${_proposedAlarms.length} AI alarm proposals '
                            'staged - accept them from the banner above, or '
                            'edit this one below and accept it on its own.'),
                  ),
                ],
              ),
            ),
          const AlarmAutoNavigateSetting(),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Alarm List (left pane)
                  Expanded(
                    flex: 2,
                    child: ListAlarms(
                      proposedAlarm: _proposedAlarm,
                      onEdit: (config) {
                        setState(() {
                          _edit = config;
                          _show = null;
                          _create = false;
                        });
                      },
                      onShow: (config) {
                        setState(() {
                          _show = config;
                          _edit = null;
                          _create = false;
                        });
                      },
                      onCreate: (config_template) {
                        setState(() {
                          _create = true;
                          _createTemplate = config_template;
                          _edit = null;
                          _show = null;
                        });
                      },
                      onDelete: (config) {
                        setState(() {
                          if (_edit?.uid == config.uid) {
                            _edit = null;
                          }
                          if (_show?.uid == config.uid) {
                            _show = null;
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Editor Form (right pane)
                  Expanded(
                    flex: 3,
                    child: _isProposal && _proposedAlarm != null
                        // Read-only for a removal: editing the fields of an
                        // alarm about to be deleted changes nothing, and the
                        // edited config would be what gets removed.
                        ? _proposedIsDelete
                            ? AlarmForm(
                                key: ValueKey(
                                    'alarm-removal-form-${_proposedAlarm!.uid}'),
                                initialConfig: _proposedAlarm!,
                                submitText: 'Remove Alarm',
                                onSubmit: (_) {
                                  _acceptProposalWithConfig(_proposedAlarm!);
                                },
                              )
                            : AlarmForm(
                                key: ValueKey(
                                    'alarm-proposal-form-${_proposedAlarm!.uid}'),
                                initialConfig: _proposedAlarm!,
                                editable: true,
                                submitText: 'Accept Proposal',
                                onSubmit: (editedConfig) {
                                  _acceptProposalWithConfig(editedConfig);
                                },
                              )
                        : _edit != null || _show != null || _create
                            ? Column(
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.end,
                                    children: [
                                      IconButton(
                                        key: const ValueKey(
                                            'alarm-editor-close-pane'),
                                        icon: const Icon(Icons.close,
                                            size: 18),
                                        color: Colors.grey,
                                        tooltip: 'Close',
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            const BoxConstraints(),
                                        splashRadius: 14,
                                        onPressed: () {
                                          setState(() {
                                            _create = false;
                                            _createTemplate = null;
                                            _edit = null;
                                            _show = null;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  if (_edit != null)
                                    Expanded(
                                      child: EditAlarm(
                                        key: ValueKey(
                                            _edit?.uid ?? 'edit'),
                                        config: _edit!,
                                        onSubmit: () {
                                          setState(() {
                                            _edit = null;
                                          });
                                        },
                                      ),
                                    )
                                  else if (_show != null)
                                    Expanded(
                                      child: AlarmForm(
                                        key: ValueKey(
                                            _show?.uid ?? 'show'),
                                        initialConfig: _show!,
                                        submitText: 'Close',
                                        onSubmit: (config) {
                                          setState(() {
                                            _show = null;
                                          });
                                        },
                                      ),
                                    )
                                  else if (_create)
                                    Expanded(
                                      child: CreateAlarm(
                                        key: ValueKey(_createTemplate?.uid ?? 'new'),
                                        template: _createTemplate,
                                        onSubmit: () {
                                          setState(() {
                                            _create = false;
                                          });
                                        },
                                      ),
                                    ),
                                ],
                              )
                            : Center(
                                child: Text(
                                  '',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The plant-wide "jump to the alarm's page" switch.
///
/// On this page rather than in Preferences because it is a decision about
/// alarms, and because the roles that may edit an alarm are exactly the roles
/// that should be making it: `alarm_man_config` is `configure` in
/// `kPrefAccessRules`, so the switch and the alarms it sits above are guarded
/// by one rule rather than two.
///
/// Which page an alarm jumps to is not set here, and deliberately has no field
/// anywhere: it is the page an operator put an Alarm beacon on, the same fact
/// that already decides which navigation entry pulses. See
/// `lib/providers/alarm_auto_navigation.dart`.
class AlarmAutoNavigateSetting extends ConsumerStatefulWidget {
  const AlarmAutoNavigateSetting({super.key});

  @override
  ConsumerState<AlarmAutoNavigateSetting> createState() =>
      _AlarmAutoNavigateSettingState();
}

class _AlarmAutoNavigateSettingState
    extends ConsumerState<AlarmAutoNavigateSetting> {
  @override
  Widget build(BuildContext context) {
    final alarmMan = ref.watch(alarmManProvider).valueOrNull;
    // Nothing to switch until there is an alarm manager to switch it on, and
    // a tile that renders enabled-but-inert would be worse than no tile: the
    // operator would flip it and it would not stick.
    if (alarmMan == null) return const SizedBox.shrink();

    return SwitchListTile(
      key: const ValueKey('alarm-editor-auto-navigate'),
      value: alarmMan.config.autoNavigate,
      onChanged: (value) => setState(() => alarmMan.setAutoNavigate(value)),
      secondary: const Icon(Icons.open_in_new),
      title: const Text('Go to the alarm\'s page when it raises'),
      subtitle: Text(
        alarmMan.config.autoNavigate
            ? 'The screen follows a raising alarm to the page its beacon is '
                'on, if the signed-in user can open that page. A second alarm '
                'only takes over if it is more severe.'
            : 'The screen stays where it is. Navigation entries still pulse.',
      ),
    );
  }
}
