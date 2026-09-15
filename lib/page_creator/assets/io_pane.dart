import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../../painter/beckhoff/io8.dart' show IOState;
import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'led.dart' show LEDPainter, LEDType;

/// The shared operator surface for digital I/O modules — Beckhoff EL1008 /
/// EL2008, Advantys STB DDI3725 / DDO3705.
///
/// The pane answers two questions, and it answers both without opening
/// anything: *is this module healthy*, and *what is each channel wired to*.
///
/// It used to answer only the first, and put the per-channel answer behind a
/// "Channel detail" tile that opened a ~900px `RowIOView` grid in a floating
/// dialog. That width was force buttons and filter fields, not information —
/// and on this plant the PLC accepts no override, so the buttons were a
/// control surface for a capability that does not exist. With them gone the
/// only thing the dialog still carried was the channel descriptions, which
/// fit in the pane perfectly well and belong there: a description you have
/// to open a window to read is a description nobody reads.
///
/// [gridBuilder] is what remains of that dialog, and it is now optional. A
/// module whose PLC does take a force still passes one and keeps its tile;
/// the Beckhoff terminals pass nothing and have no dialog at all.
///
/// Keeping it in one place means the five modules cannot drift apart.

/// Counts of channels that are high and channels that are forced.
({int high, int forced}) countChannels(List<IOState> states) {
  var high = 0;
  var forced = 0;
  for (final s in states) {
    if (s == IOState.high || s == IOState.forcedHigh) high++;
    if (s == IOState.forcedHigh || s == IOState.forcedLow) forced++;
  }
  return (high: high, forced: forced);
}

/// One channel as the pane lists it.
///
/// [name] is what the PLC and the terminal both call the point — `I1`, `O3`,
/// `I0`. [description] is what the plant calls it. Both are shown, in two
/// columns, and that pairing is the whole point of the row: an operator
/// reads "Kettle high level" and an electrician reads `I1`, off one line,
/// without either having to hold the other in their head.
@immutable
class IoChannelEntry {
  const IoChannelEntry({
    required this.name,
    required this.lamps,
    this.description,
  });

  /// The PLC's name for the point. Never empty — it is the column that makes
  /// the list scannable, and a blank gutter breaks the alignment that does
  /// the scanning.
  final String name;

  /// What this channel is wired to, when anybody has said. Null leaves the
  /// description column empty, which is honest: nobody has named it.
  final String? description;

  /// The module's own read-out for this channel. Left to the caller because
  /// the vocabulary differs — an EL1008 channel is an [IOState], an EP2338
  /// port is a pair of nullable bits — and a shared enum big enough for both
  /// would describe neither.
  final Widget lamps;
}

/// The per-channel list: the pane's answer to "what is each channel".
///
/// Three columns, and they stay in their columns down the whole list. A
/// fixed-width name gutter is what lets the eye run down `I1..I8` without
/// reading; a ragged left edge, which is what you get from putting the
/// description first and the name after it, costs a fixation per row.
class IoChannelList extends StatelessWidget {
  const IoChannelList({super.key, required this.channels});

  final List<IoChannelEntry> channels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final channel in channels)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                // The gutter. Wide enough for 'I0'..'O16' and no wider —
                // every character past the longest name is a character of
                // distance between the name and what it means.
                SizedBox(
                  width: 34,
                  child: Text(
                    channel.name,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    channel.description ?? '',
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                channel.lamps,
              ],
            ),
          ),
      ],
    );
  }
}

/// The lamp for one [IOState], in this repo's state vocabulary.
///
/// Green is the plant telling us something and yellow is us driving it, so
/// an input high and an output high are not the same colour. Forced is
/// orange wherever it appears in this repo, and it can still appear here:
/// the force *controls* are gone because the PLC accepts no override, but a
/// value the PLC reports as forced is still worth showing, and showing it
/// loudly.
class IoStateLamp extends StatelessWidget {
  const IoStateLamp({
    super.key,
    required this.state,
    this.isOutput = false,
  });

  final IOState state;
  final bool isOutput;

  @override
  Widget build(BuildContext context) {
    final colors = HmiStateColors.of(context);
    final color = switch (state) {
      IOState.error => colors.red,
      IOState.forcedHigh || IOState.forcedLow => Colors.orange,
      IOState.high => isOutput ? colors.yellow : colors.green,
      IOState.low => Colors.white,
    };

    return SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(
        painter: LEDPainter(
          color: color,
          // Outputs are square and inputs round, the same way round as the
          // EP2338 pane draws them — one shape vocabulary across the I/O
          // panes, so a shape means a direction and not a module.
          ledType: isOutput ? LEDType.square : LEDType.circle,
        ),
      ),
    );
  }
}

/// Opens the standard digital-I/O module pane.
///
/// [summaryStream] feeds the strip (raw + force is enough); [statesOf] turns
/// an emission into per-channel states — each module keeps its own bit order.
/// [gridBuilder] builds the wide per-channel grid shown in the floating
/// dialog, and owns its own subscription so it is released when that dialog
/// closes.
void showIoModulePane({
  required BuildContext context,
  required String id,
  required String title,
  required String subtitle,
  required Stream<Map<String, DynamicValue>> summaryStream,
  required List<IOState> Function(Map<String, DynamicValue>? data) statesOf,
  /// Names channel [index] the way the PLC does — `I1`, `O3`. Defaults to a
  /// bare channel number, which is right for a module whose points have no
  /// better name.
  String Function(int index)? channelName,

  /// What channel [index] is wired to, or null when nobody has said.
  String? Function(Map<String, DynamicValue>? data, int index)? descriptionOf,

  /// True when this module's points are outputs — it drives the lamp shape
  /// and colour, not the layout.
  bool isOutput = false,

  /// The old floating force grid. Optional: a module whose PLC takes no
  /// override passes nothing and gets no dialog.
  WidgetBuilder? gridBuilder,
  IconData icon = Icons.developer_board,
  String gridLabel = 'Channel detail',
  String gridSummary = 'Force and descriptions for every channel',
  Size gridSize = const Size(940, 560),
  String highLabel = 'High',
}) {
  showSidePane(
    context: context,
    id: id,
    builder: (paneContext) => StreamBuilder<Map<String, DynamicValue>>(
      stream: summaryStream,
      builder: (context, snap) {
        final data = (snap.hasData && !snap.hasError) ? snap.data : null;
        final states = statesOf(data);
        final counts = countChannels(states);
        final total = states.length;

        return SidePane(
          title: title,
          subtitle: subtitle,
          icon: icon,
          status: data == null
              ? const PaneStatus.stale('No data')
              : counts.forced > 0
                  ? PaneStatus.warning('${counts.forced} forced')
                  : const PaneStatus.running('Live'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              PaneSection(
                title: 'Channels',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PaneTileRow(
                      children: [
                        PaneMetricTile(
                          label: highLabel,
                          value: '${counts.high}',
                          unit: '/ $total',
                          icon: Icons.input,
                        ),
                        // Only when something actually is forced. On a PLC
                        // that accepts no override this tile read '0 / 8'
                        // forever, which is a line of pane spent saying
                        // nothing — and made the one time it said something
                        // easy to miss.
                        if (counts.forced > 0)
                          PaneMetricTile(
                            label: 'Forced',
                            value: '${counts.forced}',
                            unit: '/ $total',
                            icon: Icons.pan_tool,
                            valueColor: Colors.orange,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // The channel list is the strip. A row of eight lozenges
                    // above a list of eight lamps said the same thing twice,
                    // and numbered them '1..8' while the list called them
                    // 'I1..I8' — two names for one channel, a metre apart.
                    IoChannelList(
                      channels: [
                        for (var i = 0; i < total; i++)
                          IoChannelEntry(
                            name: channelName?.call(i) ?? '${i + 1}',
                            description: descriptionOf?.call(data, i),
                            lamps: IoStateLamp(
                              state: states[i],
                              isOutput: isOutput,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (gridBuilder != null) ...[
                const Divider(height: 1),
                PaneSection(
                  title: 'Detail',
                  child: PaneExpandTile(
                    label: gridLabel,
                    summary: gridSummary,
                    icon: Icons.grid_on,
                    expandedTitle: '$title — channels',
                    expandedSize: gridSize,
                    expandedBuilder: gridBuilder,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

/// Wraps a `RowIOView` grid so it scrolls sideways instead of overflowing
/// when the operator narrows the floating dialog.
///
/// A row needs ~900px for state + force + filters + description twice over;
/// below that the grid scrolls rather than clipping controls out of reach.
class IoGridViewport extends StatelessWidget {
  final Widget child;
  final double minWidth;

  const IoGridViewport({
    super.key,
    required this.child,
    this.minWidth = 900,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: constraints.maxWidth < minWidth
              ? minWidth
              : constraints.maxWidth,
          child: child,
        ),
      ),
    );
  }
}
