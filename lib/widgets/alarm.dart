import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart' show Rx;

import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
// Chat is not compiled for the browser; see `chat/editor_ai.dart`.
import '../chat/editor_ai.dart';
import '../chat/chat_context_types.dart' show ChatContextType;
import '../core/feature_flags.dart';
import '../providers/alarm.dart';
import '../providers/local_gateway_alarm.dart';
import '../theme.dart';
import 'base_scaffold.dart';
import 'boolean_expression.dart';
import 'button_graph.dart' show showSetDatePicker;
import 'fuzzy_search_bar.dart';
import 'period_menu.dart';
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
///
/// [history] is the union of what the database was asked for and what
/// [AlarmMan] still holds in memory, so the same activation arrives twice as
/// two different objects. They are collapsed by *value* -- uid plus activation
/// time -- rather than by identity, which only ever caught the in-memory case.
///
/// [window] drops what the period on screen does not cover, by **overlap**:
/// an alarm that went off before the window and cleared inside it is part of
/// that period, and one still standing overlaps every window it started
/// before. Started-inside would hide exactly the alarm the operator came to
/// read.
List<(AlarmActive, DateTime?)> alarmHistoryEntries(
  Iterable<AlarmActive?> history,
  Iterable<AlarmActive> active, {
  DateTimeRange? window,
}) {
  bool inWindow(AlarmActive row, DateTime? deactivated) {
    if (window == null) return true;
    return !row.notification.timestamp.isAfter(window.end) &&
        (deactivated == null || !deactivated.isBefore(window.start));
  }

  final seen = <String>{};
  final entries = <(AlarmActive, DateTime?)>[];
  void add(AlarmActive alarm, DateTime? deactivated) {
    if (!seen.add('${alarm.notification.uid}@'
        '${alarm.notification.timestamp.microsecondsSinceEpoch}')) {
      return;
    }
    if (!inWindow(alarm, deactivated)) return;
    entries.add((alarm, deactivated));
  }

  // The live set first, so an alarm caught mid-clear -- in both the active set
  // and the history buffer for a frame -- is listed as the standing one.
  for (final alarm in active) {
    add(alarm, null);
  }
  for (final alarm in history) {
    if (alarm == null) continue;
    add(alarm, alarm.deactivated);
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
                                    _rules[i] = rule.copyWith(level: level);
                                  });
                                }
                              }
                            : null,
                      ),
                      ExpressionBuilder(
                        value: rule.expression.value,
                        editable: widget.editable,
                        onChanged: (expr) => setState(() {
                          _rules[i] = rule.copyWith(
                              expression: ExpressionConfig(value: expr));
                        }),
                      ),
                      const SizedBox(height: 8),
                      _OnDelayField(
                        key: ValueKey('alarm-form-rule-$i-on-delay'),
                        value: rule.onDelay,
                        editable: widget.editable,
                        onChanged: (delay) => setState(() {
                          _rules[i] = _rules[i].copyWith(onDelay: delay);
                        }),
                      ),
                      SwitchListTile(
                        title: const Text('Acknowledge Required'),
                        value: rule.acknowledgeRequired,
                        onChanged: widget.editable
                            ? (val) => setState(() {
                                  _rules[i] =
                                      rule.copyWith(acknowledgeRequired: val);
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

/// How long a rule's expression must hold before the alarm goes active, in
/// seconds. The timing itself runs wherever the rule is evaluated (the
/// backend); this only edits [AlarmRule.onDelay].
class _OnDelayField extends StatelessWidget {
  final Duration value;
  final bool editable;
  final ValueChanged<Duration> onChanged;

  const _OnDelayField({
    super.key,
    required this.value,
    required this.editable,
    required this.onChanged,
  });

  /// Seconds as typed, or null when it is not a delay.
  static Duration? _parse(String? text) {
    final seconds = double.tryParse((text ?? '').trim());
    if (seconds == null || seconds.isNaN || seconds.isInfinite || seconds < 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static String _format(Duration d) {
    final seconds = d.inMilliseconds / 1000;
    return seconds == seconds.roundToDouble()
        ? seconds.toInt().toString()
        : seconds.toString();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: _format(value),
      enabled: editable,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'Active after',
        suffixText: 's',
        helperText: 'How long the expression must hold before the alarm '
            'goes active. 0 raises it at once.',
        helperMaxLines: 2,
      ),
      validator: (text) => _parse(text) == null ? 'Seconds, 0 or more' : null,
      onChanged: (text) {
        final delay = _parse(text);
        if (delay != null) onChanged(delay);
      },
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

/// The stretch the History list opens on when nothing has been picked.
///
/// A day, not the whole table. The list is now bounded at the *query*, so the
/// default is also the promise the header makes — and a shift handover asks
/// about the last day, not about last month.
const kAlarmHistoryDefaultSpan = Duration(hours: 24);

/// How many history rows one period may bring back.
///
/// The same ceiling the stop timeline uses. A busy plant can spend it all on
/// an hour, which is why the window bounds the query rather than the list:
/// an unbounded newest-first read would draw a week with six days missing,
/// silently.
const _historyRowLimit = 2000;

class ListActiveAlarms extends ConsumerStatefulWidget {
  final void Function(AlarmActive)? onShow;
  final void Function()? onViewChanged;

  /// Every time the active list arrives (not the history), after the frame,
  /// with the alarms in list order. The page uses it to pick a default
  /// selection, so the detail pane is not empty on arrival.
  final void Function(List<AlarmActive> active)? onActiveAlarms;

  /// Fixed clock for tests and goldens: bounds the rolling history window and
  /// stills the refresh timer. Live when null.
  final DateTime? clock;

  /// What "Pick a date range…" opens. Injected so a test can exercise the
  /// control without building a third-party modal, whose rendering is not
  /// this repo's to pin.
  final PeriodRangePicker pickRange;

  const ListActiveAlarms({
    super.key,
    this.onShow,
    this.onViewChanged,
    this.onActiveAlarms,
    this.clock,
    this.pickRange = showSetDatePicker,
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

  /// An absolute range the operator picked, or null for the live rolling
  /// period. It bounds the database read as well as the list: asking a
  /// newest-first buffer for last Tuesday returns yesterday instead.
  DateTimeRange? _range;

  /// A rolling span picked at runtime, or null for [kAlarmHistoryDefaultSpan].
  Duration? _interval;

  /// The database read for the period on screen. Merged with what the
  /// [AlarmSource] still holds in memory, because the row for a clear is written
  /// fire-and-forget and may not be readable for a moment after the alarm
  /// closes — the in-memory ring has it instantly.
  List<AlarmActive> _rows = const [];

  /// Bumped by every [_loadHistory] so a superseded one cannot stomp the
  /// winner: changing the period twice in a row starts two overlapping reads.
  int _generation = 0;

  /// True while a period change's read is in flight. The stale list stays up
  /// under a thin progress strip rather than being replaced by a spinner,
  /// which would throw away the scroll position and the selection with it.
  bool _reloading = false;

  /// Live safety net while History is on: the rolling window walks away from
  /// the last read, and rows written by other stations never announce
  /// themselves.
  Timer? _refresh;

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  /// The stretch of history to show: the picked range, or the rolling one.
  DateTimeRange _fetchWindow() {
    final range = _range;
    if (range != null) return range;
    final now = widget.clock ?? DateTime.now();
    return DateTimeRange(start: now.subtract(_span), end: now);
  }

  Duration get _span => _interval ?? kAlarmHistoryDefaultSpan;

  /// The list's streams, made once per mode (active / history). Built inline
  /// they were a new object on every rebuild -- every search keystroke -- and
  /// StreamBuilder answered each with its spinner.
  ///
  /// Both modes carry the same triple so the builder is one shape: the
  /// source, its in-memory ring of cleared activations, and the live set.
  /// The Active list has no use for the ring and never subscribes to it.
  ///
  /// [AlarmSource], not [AlarmMan]: in gateway mode the ring and the live set
  /// arrive over the relay, and the widget must not care which it has.
  Stream<(AlarmSource, List<AlarmActive?>, List<AlarmActive>)>? _stream;
  bool? _streamShowsHistory;

  Stream<(AlarmSource, List<AlarmActive?>, List<AlarmActive>)> _streamFor(
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
              (AlarmSource, List<AlarmActive?>, List<AlarmActive>)>(
              alarmMan.history(),
              alarmMan.activeAlarms(),
              (history, active) => (alarmMan, history, active.toList()),
            )
          : alarmMan.activeAlarms().map(
              (active) => (alarmMan, const <AlarmActive?>[], active.toList())),
    );
  }

  /// Reads the period out of the database.
  ///
  /// Failure keeps whatever is on screen and says so in the log rather than
  /// replacing a working list with an error page: the in-memory ring still
  /// answers for everything since this station started, which is the part an
  /// operator most often wants.
  Future<void> _loadHistory() async {
    final generation = ++_generation;
    final window = _fetchWindow();
    try {
      final man = await ref.read(alarmManProvider.future);
      final rows = await man.getRecentAlarms(
        limit: _historyRowLimit,
        from: window.start,
        to: window.end,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _rows = rows;
        _reloading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      debugPrint('Alarm history read failed: $e');
      setState(() => _reloading = false);
    }
  }

  /// History is live too — but only its period drifts, so a minute is enough.
  /// A fixed clock means a test or a golden, where a timer is only flake.
  void _syncRefreshTimer() {
    final wanted = _showHistory && widget.clock == null;
    if (wanted == (_refresh != null)) return;
    _refresh?.cancel();
    _refresh = wanted
        ? Timer.periodic(const Duration(minutes: 1), (_) => _loadHistory())
        : null;
  }

  /// An absolute range, or null to go back to the live rolling period.
  void _setRange(DateTimeRange? range) {
    setState(() {
      _range = range;
      _reloading = true;
    });
    _loadHistory();
  }

  /// A rolling span ending now. Always live, so it drops any absolute range.
  void _setInterval(Duration interval) {
    setState(() {
      _interval = interval;
      _range = null;
      _reloading = true;
    });
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    // The panel's own gateway alarm, or null on every direct station and on
    // a healthy link. It is merged HERE, as a value beside whatever the
    // AlarmSource says — never into the source itself, which is what keeps
    // it out of ackAlarm, out of the history buffer and out of TimescaleDB
    // (lib/core/local_gateway_alarm.dart owns that argument). It rides above
    // the search and level filters on purpose: while the gateway is down
    // every plant row on this page may be stale, and the row that says so
    // must not be filterable away. It is NOT in the history list — history
    // is the persisted record, and this alarm is deliberately not a record.
    final localAlarm = ref.watch(localGatewayAlarmProvider);
    return StreamBuilder<(AlarmSource, List<AlarmActive?>, List<AlarmActive>)>(
      stream: _streamFor(_showHistory),
      builder: (context, snapshot) {
        // An error is not a loading state. `alarmManProvider` throws for
        // real reasons — a gateway client with no alarm transport says so by
        // name — and every one of them arrived here as a stream error, which
        // `hasData == false` renders as a spinner that never stops. Reported
        // on the plant (2026-09-17) as "alarm view is constantly loading",
        // with nothing in the console, because a provider error is not an
        // uncaught exception and nothing printed it.
        if (snapshot.hasError && localAlarm == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 8),
                  Text('The alarm list could not be loaded',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  // The cause, verbatim and selectable. Whoever is standing at
                  // the panel is the person who can say whether it is the link
                  // or the plant, and they cannot do that from a spinner.
                  SelectableText('${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData && localAlarm == null) {
          return const Center(child: CircularProgressIndicator());
        }

        // No data with a standing local alarm is not a loading state worth a
        // spinner: in gateway mode the alarm source itself rides the
        // transport, so the one condition that takes the source away is the
        // condition the local alarm reports. Render what the panel knows.
        final alarmMan = snapshot.data?.$1;
        final ring = snapshot.data?.$2 ?? const <AlarmActive?>[];
        final active = snapshot.data?.$3 ?? const <AlarmActive>[];
        final window = _fetchWindow();
        var alarms = _showHistory
            ? alarmHistoryEntries([..._rows, ...ring], active, window: window)
            : [for (final a in active) (a, null as DateTime?)];

        if (!_showHistory && widget.onActiveAlarms != null) {
          final listed = [
            if (localAlarm != null) localAlarm,
            for (final a in alarms) a.$1,
          ];
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onActiveAlarms!(listed);
          });
        }
        if (_showHistory) {
          alarms = fuzzyFilter(alarms, _searchQuery, [
            (e) => e.$1.alarm.config.title,
            (e) => e.$1.alarm.config.description,
          ]);
        } else if (alarmMan != null) {
          alarms = alarmMan
              .filterAlarms(alarms.map((a) => a.$1).toList(), _searchQuery)
              .map((a) => (a, null as DateTime?))
              .toList();
        }

        // Prepended AFTER the search filter (a query must not be able to
        // hide the reason its own results may be stale) and BEFORE the
        // counts (a red error card beside an "Error 0" chip would read as a
        // broken counter). The level filter below exempts it for the same
        // reason the search does. Active view only — see the comment on
        // localAlarm above.
        if (!_showHistory && localAlarm != null) {
          alarms = [(localAlarm, null), ...alarms];
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
              .where((a) =>
                  identical(a.$1, localAlarm) ||
                  _levelFilter.contains(a.$1.notification.rule.level))
              .toList();
        }

        final Widget body;
        if (alarms.isEmpty) {
          body = Expanded(
            child: Center(
              child: Text(_emptyMessage()),
            ),
          );
        } else {
          body = Expanded(
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
                        // The D-3 hold, named and dated. A held alarm can
                        // neither clear nor re-fire, so a row without this
                        // line is a warning the operator will wait on
                        // forever — the rig-measured cooler defect
                        // (2026-09-08). Bold on purpose: this is the row's
                        // one actionable fact.
                        if (alarm.notification.staleInputs.isNotEmpty)
                          Text(
                            'Input stale'
                            '${alarm.notification.staleSince != null ? ' since ${formatTimestamp(alarm.notification.staleSince!)}' : ''}'
                            ' — ${alarm.notification.staleInputs.join(', ')}',
                            style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w600,
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
          );
        }

        return Column(
          children: [
            _buildSearchAndToggleBar(counts, window),
            body,
          ],
        );
      },
    );
  }

  /// Why the list is empty, in the operator's terms.
  ///
  /// "No alarms" over a bounded history is the wrong answer: nothing happened
  /// *in the last day* is a different statement from nothing ever happened,
  /// and the one the period control exists to let them widen.
  String _emptyMessage() {
    if (_levelFilter.isNotEmpty) return 'No alarms at the selected levels';
    if (_showHistory) return 'No alarms in this period';
    return 'No alarms';
  }

  Widget _buildSearchAndToggleBar(
      Map<AlarmLevel, int> counts, DateTimeRange window) {
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
                            _reloading = _showHistory;
                          });
                          _syncRefreshTimer();
                          if (_showHistory) _loadHistory();
                          widget.onViewChanged?.call();
                        },
                      ),
                    ),
                  ],
                );
              }),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AlarmLevelFilterChips(
                      selected: _levelFilter,
                      counts: counts,
                      onChanged: (levels) => setState(() {
                        _levelFilter
                          ..clear()
                          ..addAll(levels);
                      }),
                    ),
                    // Its own line, not the chips' -- sharing one row took
                    // enough width off the chips to fold them, and the period
                    // is the one thing in this bar that must never be
                    // abbreviated: an elided date reads as today.
                    //
                    // Only in History. The Active list is whatever is wrong
                    // now, and a period over it would be a control that does
                    // nothing.
                    if (_showHistory)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _periodMenu(window),
                        ),
                      ),
                  ],
                ),
              ),
              // The period changed and the read has not landed: the rows on
              // screen are still the old period's. Said without tearing the
              // list down. Clipped to the bar's own radius -- the Material
              // above does not clip its children, so a square strip would
              // overhang both rounded bottom corners.
              if (_reloading)
                const ClipRRect(
                  borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(12)),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The period control, hung off the read-out that names the stretch on
  /// screen — the operator who wants a different stretch reaches for the
  /// thing telling them which one they have.
  Widget _periodMenu(DateTimeRange window) {
    return PeriodMenu(
      keyPrefix: 'alarm-history',
      range: _range,
      interval: _interval,
      defaultSpan: kAlarmHistoryDefaultSpan,
      window: _fetchWindow,
      pickRange: widget.pickRange,
      onRangeChanged: _setRange,
      onIntervalChanged: _setInterval,
      child: PeriodMenuLabel(
        live: _range == null,
        label: periodWindowLabel(window, widget.clock ?? DateTime.now()),
        iconSize: 14,
        textStyle: Theme.of(context).textTheme.labelMedium,
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
            if (alarm.notification.staleInputs.isNotEmpty) ...[
              const SizedBox(height: 16),
              // The hold, and its consequence. "Cannot change state" is the
              // sentence that stops an operator waiting for a held alarm to
              // clear on its own: the state shown is remembered, not being
              // re-earned, until the named input delivers again.
              Text(
                'Input stale'
                '${alarm.notification.staleSince != null ? ' since ${formatTimestamp(alarm.notification.staleSince!)}' : ''}'
                ': ${alarm.notification.staleInputs.join(', ')}. '
                'This alarm cannot change state until the input returns — '
                'check the sensor.',
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w600,
                ),
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
                // Drawn and enabled in both transports. `canAck` above is the
                // only thing that decides whether an operator sees this
                // control; how the acknowledge travels is not a reason to hide
                // an action they are allowed to take (Q-1, ruled 2026-09-06).
                onPressed: () async {
                  final alarmMan = await ref.read(alarmManProvider.future);
                  try {
                    // Awaited, because in gateway mode this crosses the pipe.
                    // Direct mode completes immediately -- there the local
                    // removal is the whole effect.
                    await alarmMan.ackAlarm(alarm);
                  } catch (error) {
                    // Shown, never swallowed: a refusal the operator cannot
                    // see is the silent loss this project exists to prevent.
                    // And the card stays open -- one that closed here would
                    // have told them it worked.
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Acknowledge failed: $error')),
                      );
                    }
                    return;
                  }
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
