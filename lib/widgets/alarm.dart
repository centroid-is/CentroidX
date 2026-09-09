import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart' show Rx;

import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import '../chat/ai_context_action.dart';
import '../chat/asset_context_menu.dart' show buildAlarmContextBlock;
import '../chat/chat_overlay.dart' show ChatContextType;
import '../core/feature_flags.dart';
import '../providers/alarm.dart';
import '../theme.dart';
import 'base_scaffold.dart';
import 'boolean_expression.dart';
import 'fuzzy_search_bar.dart';
import 'proposal_visual.dart';

/// The alarm system's (background, foreground) colour pair for a level —
/// the single source every alarm surface reads: the list cards, the app-bar
/// banner, and the alarm visibility beacon asset.
///
/// Reads [AlarmColors], not the [ColorScheme]: alarm colors are the same
/// under every color scheme on purpose.
(Color, Color) alarmLevelColors(BuildContext context, AlarmLevel level) {
  final colors = AlarmColors.of(context);
  switch (level) {
    case AlarmLevel.info:
      return (colors.info, colors.onInfo);
    case AlarmLevel.warning:
      return (colors.warning, colors.onWarning);
    case AlarmLevel.error:
      return (colors.error, colors.onError);
  }
}

extension AlarmNotificationColors on AlarmNotification {
  /// Returns the background and text colors for this alarm level
  (Color, Color) getColors(BuildContext context) =>
      alarmLevelColors(context, rule.level);
}

/// The name a level goes by on screen.
String alarmLevelLabel(AlarmLevel level) {
  switch (level) {
    case AlarmLevel.info:
      return 'Info';
    case AlarmLevel.warning:
      return 'Warning';
    case AlarmLevel.error:
      return 'Error';
  }
}

/// What the History list shows: the alarms that have ended, paired with their
/// deactivation time, *and* the ones still standing, paired with null.
///
/// History used to be only what [AlarmMan] had already deactivated, so the
/// alarm an operator is standing in front of -- the one they scrolled here to
/// ask "when did this start?" about -- was the single alarm missing from it.
/// A live alarm belongs in the record too; it simply has no deactivation time
/// yet, and the row says so instead of leaving the line blank.
///
/// Still-active entries sort to the top, newest activation first; the ended
/// ones follow, newest deactivation first. An alarm that ran, cleared and came
/// back is two entries, because it was two events.
List<(AlarmActive, DateTime?)> alarmHistoryEntries(
  Iterable<AlarmActive?> history,
  Iterable<AlarmActive> active,
) {
  // By identity: [AlarmActive] has no value equality, and the same instance is
  // what AlarmMan moves from the active set into the history buffer -- so a
  // just-cleared alarm can be in both streams for a frame.
  final seen = Set<AlarmActive>.identity();
  final entries = <(AlarmActive, DateTime?)>[];
  for (final alarm in active) {
    if (seen.add(alarm)) entries.add((alarm, null));
  }
  for (final alarm in history) {
    if (alarm == null) continue;
    if (!seen.add(alarm)) continue;
    entries.add((alarm, alarm.deactivated));
  }

  entries.sort((a, b) {
    final aLive = a.$2 == null, bLive = b.$2 == null;
    if (aLive != bLive) return aLive ? -1 : 1;
    if (aLive) {
      return b.$1.notification.timestamp.compareTo(a.$1.notification.timestamp);
    }
    return b.$2!.compareTo(a.$2!);
  });
  return entries;
}

/// The level quick-filter: one chip per severity, worst first, each carrying
/// how many of the alarms in view sit at that level.
///
/// Nothing selected means every level. That keeps the list unfiltered by
/// default -- what an alarm page must show on arrival -- while a single tap
/// narrows it to the errors, and a second tap gives everything back.
class AlarmLevelFilterChips extends StatelessWidget {
  /// The levels currently kept. Empty means no filter at all.
  final Set<AlarmLevel> selected;

  /// Alarms per level in the list as it stands before this filter, so a chip
  /// says what tapping it would leave.
  final Map<AlarmLevel, int> counts;

  final ValueChanged<Set<AlarmLevel>> onChanged;

  const AlarmLevelFilterChips({
    super.key,
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  /// Worst first: the chip reached for in a hurry is the one nearest the edge.
  static const List<AlarmLevel> order = [
    AlarmLevel.error,
    AlarmLevel.warning,
    AlarmLevel.info,
  ];

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      // Wrap, not Row: the alarm list is 2/5 of the page and the chips have to
      // fold onto a second line rather than overflow it.
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [for (final level in order) _chip(context, level)],
      ),
    );
  }

  Widget _chip(BuildContext context, AlarmLevel level) {
    final (background, foreground) = alarmLevelColors(context, level);
    final isSelected = selected.contains(level);
    return FilterChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      // The dot is the level's own colour, which is how the cards below are
      // already read; on a selected chip the fill has taken that colour, so
      // the dot inverts to stay visible.
      avatar: CircleAvatar(
        radius: 6,
        backgroundColor: isSelected ? foreground : background,
      ),
      label: Text('${alarmLevelLabel(level)} ${counts[level] ?? 0}'),
      labelStyle: isSelected
          ? Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground)
          : null,
      selected: isSelected,
      selectedColor: background,
      onSelected: (keep) {
        final next = {...selected};
        if (keep) {
          next.add(level);
        } else {
          next.remove(level);
        }
        onChanged(next);
      },
    );
  }
}

class ListAlarms extends ConsumerStatefulWidget {
  final void Function(AlarmConfig)? onEdit;
  final void Function(AlarmConfig)? onShow;
  final void Function(AlarmConfig)? onDelete;
  final void Function(AlarmConfig?)? onCreate;

  /// Optional AI-proposed alarm to display at the top of the list.
  final AlarmConfig? proposedAlarm;

  const ListAlarms({
    super.key,
    this.onEdit,
    this.onShow,
    this.onDelete,
    this.onCreate,
    this.proposedAlarm,
  });

  @override
  ConsumerState<ListAlarms> createState() => _ListAlarmsState();
}

class _ListAlarmsState extends ConsumerState<ListAlarms> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: ref.watch(alarmManProvider.future),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final alarms =
              fuzzyFilter<Alarm>(snapshot.data!.alarms.toList(), _searchQuery, [
            (a) => a.config.title,
            (a) =>
                a.config.rules.map((r) => r.expression.value.formula).join(' '),
          ]);

          Widget addButton = IconButton(
            key: const ValueKey('alarm-editor-add'),
            icon: const Icon(Icons.add),
            onPressed: () {
              widget.onCreate?.call(null);
            },
          );
          if (kChatEnabled) {
            addButton = AiContextMenuWrapper(
              menuItems: const [
                AiMenuItem(
                  label: 'Create alarm with AI',
                  prefillText:
                      'Create an alarm that [describe what should trigger '
                      "the alarm, e.g. 'activates when pump pressure "
                      "exceeds 50 bar']",
                ),
              ],
              child: addButton,
            );
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    addButton,
                    Expanded(
                      child: FuzzySearchBar(
                        hintText: 'Search alarms...',
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // Show proposed alarm at top if present
              if (widget.proposedAlarm != null)
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: proposalDecoration(),
                  // The amber highlight is painted by the box above, so the
                  // tile needs its own Material to ink on -- otherwise the tap
                  // ripple is painted on the page's Material, underneath the
                  // highlight, and never shows. Transparent, so the highlight
                  // renders exactly as before; the radius matches the box so
                  // the splash stays inside the rounded corners.
                  child: Material(
                    type: MaterialType.transparency,
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: const ProposalBadge(),
                      title: Text(widget.proposedAlarm!.title),
                      subtitle: Text(
                          'AI Proposed: ${widget.proposedAlarm!.description}'),
                      onTap: () => widget.onShow?.call(widget.proposedAlarm!),
                    ),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: alarms.length,
                  itemBuilder: (context, index) {
                    final alarm = alarms[index];
                    Widget copyButton = IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        widget.onCreate?.call(alarm.config);
                      },
                    );
                    Widget editButton = IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () {
                        widget.onEdit?.call(alarm.config);
                      },
                    );
                    if (kChatEnabled) {
                      copyButton = AiContextMenuWrapper(
                        menuItems: [
                          AiMenuItem(
                            label: 'Duplicate alarm with AI',
                            prefillText:
                                'Create a new alarm similar to "${alarm.config.title}" '
                                'but [describe what should be different]',
                            contextBlock: buildAlarmContextBlock(alarm.config),
                            contextLabel: alarm.config.title,
                            contextType: ChatContextType.alarm,
                          ),
                        ],
                        child: copyButton,
                      );
                      editButton = AiContextMenuWrapper(
                        menuItems: [
                          AiMenuItem(
                            label: 'Edit alarm with AI',
                            prefillText: 'Edit alarm "${alarm.config.title}" - '
                                '[describe what you want to change]',
                            contextBlock: buildAlarmContextBlock(alarm.config),
                            contextLabel: alarm.config.title,
                            contextType: ChatContextType.alarm,
                          ),
                        ],
                        child: editButton,
                      );
                    }
                    return ListTile(
                      title: Text(alarm.config.title),
                      subtitle: Text(alarm.config.description),
                      trailing: SizedBox(
                        width: 144,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            copyButton,
                            editButton,
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () async {
                                // Show confirmation dialog
                                final shouldDelete = await showConfirmDialog(
                                  context: context,
                                  title: 'Delete alarm',
                                  message:
                                      'Are you sure you want to delete alarm '
                                      '"${alarm.config.title}"?',
                                  confirmLabel: 'Delete',
                                  destructive: true,
                                );

                                // If user confirmed deletion
                                if (shouldDelete && context.mounted) {
                                  final alarmMan =
                                      await ref.read(alarmManProvider.future);
                                  alarmMan.removeAlarm(alarm.config);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Text('Alarm deleted!'),
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .tertiary,
                                      ),
                                    );
                                  }
                                  widget.onDelete?.call(alarm.config);
                                  setState(() {});
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      onTap: () => widget.onShow?.call(alarm.config),
                    );
                  },
                ),
              ),
            ],
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}

/// The separator between group segments as an operator types them.
///
/// A slash, because that is how everyone already writes a hierarchy, and it
/// is one of the few characters unlikely to appear inside a machine name.
const alarmGroupSeparator = '/';

/// Splits what the operator typed into an [AlarmConfig.group] address.
///
/// Blank segments are dropped rather than becoming groups with no name, so
/// trailing separators and double slashes are forgiving instead of corrupting
/// the tree.
List<String> parseAlarmGroup(String text) => text
    .split(alarmGroupSeparator)
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// Renders an [AlarmConfig.group] the way the field expects it back.
String formatAlarmGroup(List<String> group) =>
    group.join(' $alarmGroupSeparator ');

/// Where an alarm sits in the tree, with completion over the groups that
/// already exist.
class _GroupField extends StatelessWidget {
  const _GroupField({
    required this.value,
    required this.editable,
    required this.suggestions,
    required this.onChanged,
  });

  final String value;
  final bool editable;
  final List<String> suggestions;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final parsed = parseAlarmGroup(value);
    final helper = parsed.isEmpty
        ? 'Ungrouped — sits at the top of the alarm tree'
        : 'In ${parsed.join(' › ')}';

    return Autocomplete<String>(
      initialValue: TextEditingValue(text: value),
      optionsBuilder: (editing) {
        final typed = editing.text.trim().toLowerCase();
        if (!editable) return const Iterable<String>.empty();
        if (typed.isEmpty) return suggestions;
        return suggestions
            .where((e) => e.toLowerCase().contains(typed));
      },
      onSelected: onChanged,
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        return TextFormField(
          key: const ValueKey('alarm-form-group'),
          controller: controller,
          focusNode: focusNode,
          enabled: editable,
          decoration: InputDecoration(
            labelText: 'Group',
            hintText: 'Line 3 $alarmGroupSeparator Multivac',
            helperText: helper,
            suffixIcon: editable && controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Ungroup',
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  )
                : null,
          ),
          onChanged: onChanged,
          onFieldSubmitted: (_) => onSubmitted(),
        );
      },
    );
  }
}

class AlarmForm extends ConsumerStatefulWidget {
  final AlarmConfig? initialConfig;
  final void Function(AlarmConfig)? onSubmit;
  final String? submitText;
  final bool editable;

  const AlarmForm({
    super.key,
    this.initialConfig,
    this.onSubmit,
    this.submitText,
    this.editable = false,
  });

  @override
  ConsumerState<AlarmForm> createState() => _AlarmFormState();
}

class _AlarmFormState extends ConsumerState<AlarmForm> {
  final _formKey = GlobalKey<FormState>();
  late String _title;
  late String _description;
  late List<AlarmRule> _rules;
  late String _group;
  late bool _bindToGroup;
  late bool _countsAsStop;

  @override
  void initState() {
    super.initState();
    _title = widget.initialConfig?.title ?? '';
    _description = widget.initialConfig?.description ?? '';
    _rules = widget.initialConfig?.rules.toList() ?? [];
    _group = formatAlarmGroup(widget.initialConfig?.group ?? const []);
    _bindToGroup = widget.initialConfig?.bindToGroup ?? false;
    _countsAsStop = widget.initialConfig?.countsAsStop ?? true;
  }

  /// Groups that already exist, so the operator picks an existing name
  /// instead of inventing "Line3" beside "Line 3" and splitting a machine's
  /// history in two.
  List<String> _knownGroups() {
    final man = ref.watch(alarmManProvider).valueOrNull;
    if (man == null) return const [];
    final seen = <String>{};
    for (final alarm in man.alarms) {
      final group = alarm.config.group;
      // every prefix is a real group someone could file under
      for (var i = 1; i <= group.length; i++) {
        seen.add(formatAlarmGroup(group.sublist(0, i)));
      }
    }
    final out = seen.where((e) => e.isNotEmpty).toList()..sort();
    return out;
  }

  // Add a method to check if all expressions are valid
  bool _areAllExpressionsValid() {
    return _rules.every((rule) => rule.expression.value.isValid());
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            TextFormField(
              key: const ValueKey('alarm-form-title'),
              decoration: const InputDecoration(labelText: 'Title'),
              initialValue: _title,
              onChanged: (v) => _title = v,
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              enabled: widget.editable,
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('alarm-form-description'),
              decoration: const InputDecoration(labelText: 'Description'),
              initialValue: _description,
              onChanged: (v) => _description = v,
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              enabled: widget.editable,
            ),
            const SizedBox(height: 16),
            _GroupField(
              value: _group,
              editable: widget.editable,
              suggestions: _knownGroups(),
              onChanged: (v) => setState(() {
                _group = v;
                // Binding to nothing is meaningless, so clearing the group
                // clears the flag rather than leaving it set but inert.
                if (parseAlarmGroup(v).isEmpty) _bindToGroup = false;
              }),
            ),
            SwitchListTile(
              key: const ValueKey('alarm-form-bind-to-group'),
              title: const Text('This alarm is the group itself'),
              subtitle: const Text(
                  'For equipment with no finer alarms yet — the coarse '
                  '“this machine stopped” signal, rather than one alarm '
                  'inside the group.'),
              value: _bindToGroup,
              onChanged: widget.editable && parseAlarmGroup(_group).isNotEmpty
                  ? (v) => setState(() => _bindToGroup = v)
                  : null,
            ),
            SwitchListTile(
              key: const ValueKey('alarm-form-counts-as-stop'),
              title: const Text('Counts as a stop'),
              subtitle: const Text(
                  'On by default: an activation is downtime in the stop '
                  'analysis. Turn off for advisory alarms that never halt '
                  'the line.'),
              value: _countsAsStop,
              onChanged: widget.editable
                  ? (v) => setState(() => _countsAsStop = v)
                  : null,
            ),
            const SizedBox(height: 16),
            ..._rules.asMap().entries.map((entry) {
              final i = entry.key;
              final rule = entry.value;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      const SizedBox(height: 16),
                      DropdownButtonFormField<AlarmLevel>(
                        value: rule.level,
                        decoration: InputDecoration(
                          labelText: 'Alarm Level',
                          border: const OutlineInputBorder(),
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                        ),
                        items: AlarmLevel.values
                            .map((level) => DropdownMenuItem(
                                  value: level,
                                  child: Text(level.name),
                                ))
                            .toList(),
                        onChanged: widget.editable
                            ? (level) {
                                if (level != null) {
                                  setState(() {
                                    _rules[i] = AlarmRule(
                                      level: level,
                                      expression: rule.expression,
                                      acknowledgeRequired:
                                          rule.acknowledgeRequired,
                                    );
                                  });
                                }
                              }
                            : null,
                      ),
                      ExpressionBuilder(
                        value: rule.expression.value,
                        editable: widget.editable,
                        onChanged: (expr) => setState(() {
                          _rules[i] = AlarmRule(
                            level: rule.level,
                            expression: ExpressionConfig(value: expr),
                            acknowledgeRequired: rule.acknowledgeRequired,
                          );
                        }),
                      ),
                      SwitchListTile(
                        title: const Text('Acknowledge Required'),
                        value: rule.acknowledgeRequired,
                        onChanged: widget.editable
                            ? (val) => setState(() {
                                  _rules[i] = AlarmRule(
                                    level: rule.level,
                                    expression: rule.expression,
                                    acknowledgeRequired: val,
                                  );
                                })
                            : null,
                      ),
                      if (widget.editable)
                        TextButton(
                          onPressed: () => setState(() => _rules.removeAt(i)),
                          child: const Text('Remove Rule'),
                        ),
                    ],
                  ),
                ),
              );
            }),
            if (widget.editable)
              ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add Rule'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _rules.isEmpty
                      ? Theme.of(context).colorScheme.errorContainer
                      : null,
                  foregroundColor: _rules.isEmpty
                      ? Theme.of(context).colorScheme.onErrorContainer
                      : null,
                ),
                onPressed: () => setState(() => _rules.add(
                      AlarmRule(
                        level: AlarmLevel.info,
                        expression:
                            ExpressionConfig(value: Expression(formula: '')),
                        acknowledgeRequired: false,
                      ),
                    )),
              ),
            const SizedBox(height: 16),
            if (widget.onSubmit != null)
              ElevatedButton(
                onPressed: (_rules.isEmpty || !_areAllExpressionsValid())
                    ? null
                    : () {
                        if (_formKey.currentState?.validate() ?? false) {
                          final group = parseAlarmGroup(_group);
                          final config = AlarmConfig(
                            uid: widget.initialConfig?.uid ??
                                UniqueKey().toString(),
                            key: widget.initialConfig?.key,
                            title: _title,
                            description: _description,
                            rules: _rules,
                            group: group,
                            bindToGroup: _bindToGroup && group.isNotEmpty,
                            countsAsStop: _countsAsStop,
                          );
                          widget.onSubmit?.call(config);
                        }
                      },
                child: Text(widget.submitText ?? 'Submit'),
              ),
          ],
        ),
      ),
    );
  }
}

class CreateAlarm extends ConsumerWidget {
  final void Function() onSubmit;
  final AlarmConfig? template;

  const CreateAlarm({super.key, required this.onSubmit, this.template});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlarmForm(
      initialConfig: template == null ? null : AlarmConfig.from(template!),
      editable: true,
      submitText: 'Create Alarm',
      onSubmit: (config) async {
        final newConfig = AlarmConfig(
          uid: UniqueKey().toString(),
          key: config.key,
          title: config.title,
          description: config.description,
          rules: config.rules,
        );

        final alarmMan = await ref.read(alarmManProvider.future);
        alarmMan.addAlarm(newConfig);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Alarm created!')),
          );
        }
        onSubmit();
        ref.invalidate(alarmManProvider);
      },
    );
  }
}

class EditAlarm extends ConsumerWidget {
  final AlarmConfig config;
  final void Function() onSubmit;

  const EditAlarm({
    super.key,
    required this.config,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlarmForm(
      editable: true,
      initialConfig: config,
      onSubmit: (updatedConfig) async {
        final alarmMan = await ref.read(alarmManProvider.future);
        alarmMan.updateAlarm(updatedConfig);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Alarm updated!')),
          );
        }
        ref.invalidate(alarmManProvider);
        onSubmit();
      },
    );
  }
}

class ListActiveAlarms extends ConsumerStatefulWidget {
  final void Function(AlarmActive)? onShow;
  final void Function()? onViewChanged;

  /// Every time the active list arrives (not the history), after the frame,
  /// with the alarms in list order. The page uses it to pick a default
  /// selection, so the detail pane is not empty on arrival.
  final void Function(List<AlarmActive> active)? onActiveAlarms;

  const ListActiveAlarms({
    super.key,
    this.onShow,
    this.onViewChanged,
    this.onActiveAlarms,
  });

  @override
  ConsumerState<ListActiveAlarms> createState() => _ListActiveAlarmsState();
}

class _ListActiveAlarmsState extends ConsumerState<ListActiveAlarms> {
  String _searchQuery = '';
  bool _showHistory = false;

  /// The levels the operator has tapped. Empty means every level; it survives
  /// the Active/History toggle, because "I am only looking at errors" is a
  /// stance on the plant, not on which of the two lists is on screen.
  final Set<AlarmLevel> _levelFilter = {};

  final _searchBarKey = GlobalKey<FuzzySearchBarState>();

  /// The list's stream, made once per mode (active / history). Built inline
  /// it was a new object on every rebuild -- every search keystroke -- and
  /// StreamBuilder answered each with its spinner.
  Stream<(AlarmMan, List<(AlarmActive, DateTime?)>)>? _stream;
  bool? _streamShowsHistory;

  Stream<(AlarmMan, List<(AlarmActive, DateTime?)>)> _streamFor(
      bool showHistory) {
    final cached = _stream;
    if (cached != null && _streamShowsHistory == showHistory) return cached;
    _streamShowsHistory = showHistory;
    return _stream =
        Stream.fromFuture(ref.read(alarmManProvider.future)).asyncExpand(
      // History reads both streams: AlarmMan's buffer holds only the alarms it
      // has already deactivated, and the standing ones belong in the record
      // too -- see [alarmHistoryEntries].
      (alarmMan) => showHistory
          ? Rx.combineLatest2<List<AlarmActive?>, Set<AlarmActive>,
              (AlarmMan, List<(AlarmActive, DateTime?)>)>(
              alarmMan.history(),
              alarmMan.activeAlarms(),
              (history, active) =>
                  (alarmMan, alarmHistoryEntries(history, active)),
            )
          : alarmMan.activeAlarms().map((active) =>
              (alarmMan, active.map((a) => (a, null as DateTime?)).toList())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<(AlarmMan, List<(AlarmActive, DateTime?)>)>(
      stream: _streamFor(_showHistory),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        var (alarmMan, alarms) = snapshot.data!;
        if (!_showHistory && widget.onActiveAlarms != null) {
          final active = [for (final a in alarms) a.$1];
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onActiveAlarms!(active);
          });
        }
        if (_showHistory) {
          alarms = fuzzyFilter(alarms, _searchQuery, [
            (e) => e.$1.alarm.config.title,
            (e) => e.$1.alarm.config.description,
          ]);
        } else {
          alarms = alarmMan
              .filterAlarms(alarms.map((a) => a.$1).toList(), _searchQuery)
              .map((a) => (a, null as DateTime?))
              .toList();
        }

        // Counted before the level filter is applied, so a chip states what
        // is behind it rather than what is left after itself.
        final counts = <AlarmLevel, int>{
          for (final level in AlarmLevel.values)
            level: alarms
                .where((a) => a.$1.notification.rule.level == level)
                .length,
        };
        if (_levelFilter.isNotEmpty) {
          alarms = alarms
              .where((a) => _levelFilter.contains(a.$1.notification.rule.level))
              .toList();
        }

        if (alarms.isEmpty) {
          return Column(
            children: [
              _buildSearchAndToggleBar(counts),
              Expanded(
                child: Center(
                  child: Text(_levelFilter.isEmpty
                      ? 'No alarms'
                      : 'No alarms at the selected levels'),
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            _buildSearchAndToggleBar(counts),
            Expanded(
              child: ListView.builder(
                itemCount: alarms.length,
                itemBuilder: (context, index) {
                  final (alarm, deactivationTime) = alarms[index];
                  final (backgroundColor, textColor) =
                      alarm.notification.getColors(context);

                  return Card(
                    color: backgroundColor,
                    child: ListTile(
                      title: Text(
                        alarm.alarm.config.title,
                        style: TextStyle(color: textColor),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Activated: ${formatTimestamp(alarm.notification.timestamp)}',
                            style: TextStyle(
                              color: textColor.withAlpha(178),
                            ),
                          ),
                          if (deactivationTime != null)
                            Text(
                              'Deactivated: ${formatTimestamp(deactivationTime)}',
                              style: TextStyle(
                                color: textColor.withAlpha(178),
                              ),
                            )
                          // In the history list an alarm with no deactivation
                          // time has not ended yet -- say so, rather than
                          // leaving a row that looks like a missing timestamp.
                          else if (_showHistory)
                            Text(
                              'Still active',
                              style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      onTap: () => widget.onShow?.call(alarm),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSearchAndToggleBar(Map<AlarmLevel, int> counts) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surface,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).colorScheme.surface,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(builder: (context, constraints) {
                // The list column is 2/5 of the page, so in a narrow
                // window the bar can be under 250 px -- less than the
                // labelled toggle alone, and the search field then
                // overflowed. Below that, the segments keep their icons and
                // say their name in a tooltip instead.
                final compact = constraints.maxWidth < 360;
                return Row(
                  children: [
                    // Search field
                    Expanded(
                      child: FuzzySearchBar(
                        key: _searchBarKey,
                        hintText:
                            'Search ${_showHistory ? "historical" : "active"} alarms...',
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                        },
                      ),
                    ),
                    // Toggle
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: SegmentedButton<bool>(
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: WidgetStateProperty.all(BorderSide.none),
                        ),
                        segments: [
                          ButtonSegment<bool>(
                            value: false,
                            icon: const Icon(Icons.warning, size: 18),
                            label: compact ? null : const Text('Active'),
                            tooltip: compact ? 'Active' : null,
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            icon: const Icon(Icons.history, size: 18),
                            label: compact ? null : const Text('History'),
                            tooltip: compact ? 'History' : null,
                          ),
                        ],
                        selected: {_showHistory},
                        onSelectionChanged: (Set<bool> newSelection) {
                          setState(() {
                            _showHistory = newSelection.first;
                            _searchQuery = '';
                            _searchBarKey.currentState?.clear();
                          });
                          widget.onViewChanged?.call();
                        },
                      ),
                    ),
                  ],
                );
              }),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: AlarmLevelFilterChips(
                  selected: _levelFilter,
                  counts: counts,
                  onChanged: (levels) => setState(() {
                    _levelFilter
                      ..clear()
                      ..addAll(levels);
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ViewActiveAlarm extends ConsumerWidget {
  final AlarmActive alarm;
  final void Function()? onClose;

  const ViewActiveAlarm({
    super.key,
    required this.alarm,
    this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (backgroundColor, textColor) = alarm.notification.getColors(context);
    final isActive = alarm.notification.active;
    final requiresAck = alarm.notification.rule.acknowledgeRequired;
    // `pendingAck` is cleared by AlarmMan the moment an instance leaves the
    // active set, so it alone says "cleared, awaiting ack". The deactivation
    // time no longer distinguishes anything: it is stamped when the condition
    // drops, ack pending or not.
    final canAck = !isActive && alarm.pendingAck;

    return Card(
      color: backgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Expanded so a long title wraps instead of overflowing —
                // this card also renders at side-pane width (380) inside the
                // alarm visibility asset's pane.
                Expanded(
                  child: Text(
                    alarm.alarm.config.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                    color: textColor,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Activated: ${formatTimestamp(alarm.notification.timestamp)}',
                  style: TextStyle(
                    color: textColor.withAlpha(178),
                    fontSize: Theme.of(context).textTheme.bodySmall?.fontSize,
                  ),
                ),
                if (alarm.deactivated != null)
                  Text(
                    'Deactivated: ${formatTimestamp(alarm.deactivated!)}',
                    style: TextStyle(
                      color: textColor.withAlpha(178),
                      fontSize: Theme.of(context).textTheme.bodySmall?.fontSize,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              alarm.alarm.config.description,
              style: TextStyle(color: textColor),
            ),
            const SizedBox(height: 16),
            // Wrap, not Row — at side-pane width the two chips can exceed
            // the card and must break onto a second line, not overflow.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: textColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Level: ${alarm.notification.rule.level.name.toUpperCase()}',
                    style: TextStyle(color: textColor),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: textColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Status: ${isActive ? 'ACTIVE' : 'INACTIVE'}',
                    style: TextStyle(color: textColor),
                  ),
                ),
              ],
            ),
            if (alarm.notification.expression != null) ...[
              const SizedBox(height: 16),
              Text(
                'Expression: ${alarm.notification.expression}',
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
              ),
            ],
            if (requiresAck) ...[
              const SizedBox(height: 16),
              Text(
                'This alarm requires acknowledgment',
                style: TextStyle(
                  color: textColor,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (canAck) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () async {
                  final alarmMan = await ref.read(alarmManProvider.future);
                  alarmMan.ackAlarm(alarm);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Alarm acknowledged')),
                    );
                  }
                  onClose?.call();
                },
                icon: const Icon(Icons.check),
                label: const Text('Acknowledge'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: textColor,
                  foregroundColor: backgroundColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
