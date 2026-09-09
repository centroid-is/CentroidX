import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';

import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';

part 'checklists.g.dart';

@JsonSerializable(explicitToJson: true)
class ChecklistsConfig extends BaseAsset {
  @override
  String get displayName => 'Checklists';
  @override
  String get category => 'Application';

  List<LEDConfig> line1;
  List<LEDConfig> line2;
  List<LEDConfig> line3;

  ChecklistsConfig(
      {required this.line1, required this.line2, required this.line3});

  factory ChecklistsConfig.fromJson(Map<String, dynamic> json) =>
      _$ChecklistsConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$ChecklistsConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return Checklists(config: this);
  }

  static const previewStr = 'Checklists preview';

  ChecklistsConfig.preview()
      : line1 = [LEDConfig.preview()],
        line2 = [LEDConfig.preview()],
        line3 = [LEDConfig.preview()];

  /// Returns a widget for configuring this checklist config.
  @override
  Widget configure(BuildContext context) {
    return _ChecklistsConfigEditor(config: this);
  }
}

class _ChecklistsConfigEditor extends StatefulWidget {
  final ChecklistsConfig config;
  const _ChecklistsConfigEditor({required this.config});

  @override
  State<_ChecklistsConfigEditor> createState() =>
      _ChecklistsConfigEditorState();
}

class _ChecklistsConfigEditorState extends State<_ChecklistsConfigEditor> {
  late List<List<LEDConfig>> lines;

  @override
  void initState() {
    super.initState();
    lines = [widget.config.line1, widget.config.line2, widget.config.line3];
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizeField(
              initialValue: widget.config.size,
              onChanged: (size) => setState(() => widget.config.size = size)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(3, (lineIdx) {
                  return Container(
                    width: 400,
                    margin:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: SizedBox(
                          height: 800,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Line ${lineIdx + 1}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                ...List.generate(lines[lineIdx].length,
                                    (ledIdx) {
                                  final ledConfig = lines[lineIdx][ledIdx];
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      ledConfig.configure(context),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: IconButton(
                                          icon: Icon(Icons.delete),
                                          onPressed: () {
                                            setState(() {
                                              lines[lineIdx].removeAt(ledIdx);
                                            });
                                          },
                                        ),
                                      ),
                                      const Divider(),
                                    ],
                                  );
                                }),
                                TextButton.icon(
                                  icon: Icon(Icons.add),
                                  label: Text('Add LED'),
                                  onPressed: () {
                                    setState(() {
                                      lines[lineIdx].add(LEDConfig.preview());
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class Checklists extends StatefulWidget {
  final ChecklistsConfig config;

  const Checklists({super.key, required this.config});

  @override
  State<Checklists> createState() => _ChecklistsState();
}

class _ChecklistsState extends State<Checklists> {
  String get _dialogId => 'checklists:${identityHashCode(widget)}';

  /// Three columns of checklist state — too wide for a pane, and something an
  /// operator works through while watching the line, so it floats.
  void _showChecklistDialog(BuildContext context) {
    showFloatingDialog(
      context: context,
      id: _dialogId,
      title: 'Checklists',
      icon: Icons.checklist,
      size: const Size(1200, 560),
      builder: (context) {
        final theme = Theme.of(context);
        final lines = [
          widget.config.line1,
          widget.config.line2,
          widget.config.line3,
        ];
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          // IntrinsicHeight so the hairlines between the columns run the full
          // height of the tallest one; the dialog body scrolls as a whole.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var lineIdx = 0; lineIdx < lines.length; lineIdx++)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0),
                      decoration: lineIdx == 0
                          ? null
                          : BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color:
                                      theme.dividerColor.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                      child: ChecklistColumn(
                        title: 'Line ${lineIdx + 1}',
                        steps: lines[lineIdx],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return UtilityButton(
      label: 'Checklists',
      onTap: () => _showChecklistDialog(context),
    );
  }
}

/// One line's checklist: a header with how far along it is, a thin progress
/// bar, and the steps themselves, numbered, with a hairline between them.
///
/// Every step is an LED bound to a PLC bool, so "done" is whatever the PLC
/// says it is -- nothing here is ticked by hand or written back. The column
/// reads each key once through [keyStreamProvider], the same way the LED
/// asset does, and paints the LED from that value rather than letting every
/// row subscribe on its own: the header needs the values anyway to count.
class ChecklistColumn extends ConsumerStatefulWidget {
  final String title;
  final List<LEDConfig> steps;

  const ChecklistColumn({super.key, required this.title, required this.steps});

  @override
  ConsumerState<ChecklistColumn> createState() => _ChecklistColumnState();
}

class _ChecklistColumnState extends ConsumerState<ChecklistColumn> {
  Stream<List<bool?>>? _cachedValues;
  int? _cachedSignature;

  static bool _bound(LEDConfig step) =>
      step.key.isNotEmpty && step.key != LEDConfig.previewStr;

  /// The live value of every bound step, in step order, with `null` for a
  /// step that has not reported yet or whose key the PLC will not serve.
  ///
  /// Built once per set of streams, not once per build -- see the note on
  /// `_valuesStream` in `conveyor.dart` for what re-subscribing per frame
  /// costs. Each source is made optional (errors and silence become `null`)
  /// so one dead key leaves the rest of the column working.
  Stream<List<bool?>> _valuesStream(List<Stream<DynamicValue>?> sources) {
    final signature = Object.hashAll(
        [for (final s in sources) s == null ? 0 : identityHashCode(s)]);
    final cached = _cachedValues;
    if (cached != null && signature == _cachedSignature) return cached;

    final combined = CombineLatestStream<bool?, List<bool?>>(
      [
        for (final s in sources)
          if (s == null)
            Stream<bool?>.value(null)
          else
            s
                .map<bool?>((value) => value.asBool)
                .transform(StreamTransformer<bool?, bool?>.fromHandlers(
                  handleError: (error, stackTrace, sink) => sink.add(null),
                ))
                .startWith(null),
      ],
      (values) => List<bool?>.unmodifiable(values),
    ).shareReplay(maxSize: 1);

    _cachedSignature = signature;
    _cachedValues = combined;
    return combined;
  }

  /// What the row shows: a preview LED is lit, like the LED asset's own
  /// preview; an unbound one is unknown.
  static bool? _stateOf(LEDConfig step, bool? value) {
    if (step.key == LEDConfig.previewStr) return true;
    if (step.key.isEmpty) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.isEmpty) {
      return _ChecklistColumnBody(
        title: widget.title,
        steps: const [],
        states: const [],
      );
    }
    final sources = [
      for (final step in steps)
        _bound(step) ? ref.watch(keyStreamProvider(step.key)) : null,
    ];
    return StreamBuilder<List<bool?>>(
      stream: _valuesStream(sources),
      builder: (context, snapshot) {
        final values = snapshot.data ?? List<bool?>.filled(steps.length, null);
        return _ChecklistColumnBody(
          title: widget.title,
          steps: steps,
          states: [
            for (var i = 0; i < steps.length; i++)
              _stateOf(steps[i], values[i]),
          ],
        );
      },
    );
  }
}

class _ChecklistColumnBody extends StatelessWidget {
  final String title;
  final List<LEDConfig> steps;

  /// One entry per step: done, not done, or unknown.
  final List<bool?> states;

  const _ChecklistColumnBody({
    required this.title,
    required this.steps,
    required this.states,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final doneColor = HmiStateColors.of(context).green;
    final hairline = theme.dividerColor.withValues(alpha: 0.5);
    final muted = scheme.onSurface.withValues(alpha: 0.6);

    final total = steps.length;
    final done = states.where((s) => s == true).length;
    final complete = total > 0 && done == total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ─── Header: title, N / M, thin progress ───
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (total > 0)
                Text(
                  '$done / $total',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: complete ? doneColor : muted,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
        if (total > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: done / total,
              minHeight: 3,
              color: doneColor,
              backgroundColor: theme.dividerColor,
            ),
          ),
        const SizedBox(height: 4),

        // ─── Steps ───
        if (total == 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Text(
              'No steps configured',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ),
        for (var i = 0; i < total; i++)
          _ChecklistStepRow(
            index: i + 1,
            step: steps[i],
            state: states[i],
            // A hairline under every step but the last, like the detail
            // rows in the panes.
            hairline: i == total - 1 ? null : hairline,
            muted: muted,
            doneColor: doneColor,
          ),
      ],
    );
  }
}

class _ChecklistStepRow extends StatelessWidget {
  final int index;
  final LEDConfig step;
  final bool? state;
  final Color? hairline;
  final Color muted;
  final Color doneColor;

  const _ChecklistStepRow({
    required this.index,
    required this.step,
    required this.state,
    required this.hairline,
    required this.muted,
    required this.doneColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = state == true;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7.0),
      decoration: hairline == null
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: hairline!)),
            ),
      child: Row(
        children: [
          // Step number, so "step 4" means the same thing on the floor as
          // it does on the screen.
          SizedBox(
            width: 22,
            child: Text(
              '$index.',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // The LED, at a fixed size: a step indicator, not a panel lamp.
          SizedBox(
            width: 16,
            height: 16,
            child: LedRaw(step, value: state),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              step.text ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                // A done step steps back, so what is left stands out.
                color: done ? muted : null,
              ),
            ),
          ),
          if (done) ...[
            const SizedBox(width: 8),
            Icon(Icons.check, size: 16, color: doneColor),
          ],
        ],
      ),
    );
  }
}
