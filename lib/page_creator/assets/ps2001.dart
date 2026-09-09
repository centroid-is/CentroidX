/// Beckhoff PS2001-2410 — the 24 V DC / 10 A supply behind each station's
/// 24 V rail.
///
/// The PLC publishes one `ST_PS2001_2410` per unit
/// (`SVNCoreComponents/ECT/ST_PS2001_2410.TcDUT`), linked straight off the
/// unit's `PSU Inputs` PDO. Six members, all read-only — the supply takes no
/// commands, so unlike the EL9222 there is nothing for the HMI to write and
/// the pane is a reading, not a control.
///
/// Two of the six are analogue, and they are the reason this asset exists at
/// all. Everything else on a mimic answers "is it on?"; the output volts and
/// amps answer "how close is it to falling over?", which is the question
/// somebody actually walks to the cabinet with.
///
/// This library holds the decode and the operator surface. The subscription
/// lives with the asset in `beckhoff.dart` — a pane is built into the root
/// overlay and a widget that reads providers from there is not on the page's
/// tree.
library;

import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../../painter/beckhoff/ps2001.dart' show Ps2001FaceState;
import '../../theme.dart' show HmiStateColors;
import '../../widgets/graph.dart' show GraphAxisConfig, GraphType;
import 'graph.dart' show GraphAssetConfig, GraphSeriesConfig;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'led.dart' show LEDPainter, LEDType;

/// The members of an `ST_PS2001_2410` that carry a flag, each with the words
/// an operator reads instead of the member name.
enum Ps2001Flag {
  /// `PSU Inputs^DC OK` — the output is within tolerance. This is the lamp
  /// on the front of the housing.
  dcOk('p_stat_DC_OK', 'Output in tolerance'),

  /// `PSU Inputs^Warning` — a non-critical condition: running hot, or close
  /// to full load. Still supplying.
  warning('p_stat_Warning', 'Running hot or near full load'),

  /// `PSU Inputs^Error` — a device fault: overload or short-circuit hiccup
  /// mode, or an overtemperature shutdown.
  error('p_stat_Error', 'Device fault'),

  /// `PSU Inputs Device^Input undervoltage` — the AC mains feeding this unit
  /// is below its valid range.
  inputUndervoltage('p_stat_Input_undervoltage', 'Mains input low');

  const Ps2001Flag(this.member, this.label);

  /// Struct member carrying this flag.
  final String member;

  /// What the pane calls this bit. Operator words, never the member name.
  final String label;
}

/// Struct member carrying the measured output voltage, in volts.
const String ps2001VoltageMember = 'p_stat_Output_voltage';

/// Struct member carrying the measured output current, in amperes.
const String ps2001CurrentMember = 'p_stat_Output_current';

/// The two measured members over time, on their own axes.
///
/// Volts sit around 24 and amps between 0 and 10, so they cannot share a
/// scale — on one axis the current is a flat line along the bottom and the
/// trend is useless for the thing an operator opened it for. Voltage takes
/// the left axis, current the right.
///
/// Charting a struct member rather than a scalar key needs the collector to
/// have picked these two out with `sample_members`; a key collected whole
/// gives [GraphSeriesConfig.member] nothing to pluck and the trace comes back
/// empty. That is why the trend is opt-in per asset rather than always on.
/// One measured member on its own, for a tile-sized sparkline.
///
/// The preview is a "something is happening" cue at 90 px; two traces on two
/// axes in that space is a smudge. Each tile previews its own quantity and
/// the tap opens [ps2001TrendConfig], where both fit.
GraphAssetConfig ps2001SeriesConfig({
  required String stateKey,
  required String member,
  required String label,
  required String unit,
  Duration window = const Duration(minutes: 30),
}) =>
    GraphAssetConfig(
      graphType: GraphType.timeseries,
      primarySeries: [
        GraphSeriesConfig(key: stateKey, label: label, member: member),
      ],
      yAxis: GraphAxisConfig(unit: unit),
      timeWindowMinutes: window,
    );

GraphAssetConfig ps2001TrendConfig({
  required String stateKey,
  String? headerText,
  Duration window = const Duration(minutes: 30),
}) =>
    GraphAssetConfig(
      graphType: GraphType.timeseries,
      primarySeries: [
        GraphSeriesConfig(
          key: stateKey,
          label: 'Output',
          member: ps2001VoltageMember,
        ),
      ],
      secondarySeries: [
        GraphSeriesConfig(
          key: stateKey,
          label: 'Draw',
          member: ps2001CurrentMember,
        ),
      ],
      yAxis: const GraphAxisConfig(unit: 'V'),
      yAxis2: const GraphAxisConfig(unit: 'A'),
      timeWindowMinutes: window,
      headerText: headerText,
    );

/// The unit's rated output. Used only to say how much headroom is left —
/// PS2001-**2410** is the 24 V, 10 A part, which is the only PS2001 variant
/// fitted on this plant.
const double ps2001RatedCurrent = 10.0;

/// One supply as it last reported itself.
///
/// Every member is nullable and a member the server never served stays null
/// rather than collapsing to `false` or `0`. A supply reading 0.0 V because
/// nothing arrived looks exactly like a supply that has actually collapsed,
/// and that is not a distinction to lose on a page somebody troubleshoots
/// from.
@immutable
class Ps2001Status {
  const Ps2001Status({
    required this.flags,
    required this.voltage,
    required this.current,
  });

  final Map<Ps2001Flag, bool?> flags;

  /// Measured output voltage in volts, or null when unpublished.
  final double? voltage;

  /// Measured output current in amperes, or null when unpublished.
  final double? current;

  /// Reads a subscribed `ST_PS2001_2410`. A null [struct] — no key
  /// configured, nothing received yet — yields an all-unknown status.
  factory Ps2001Status.read(DynamicValue? struct) {
    double? number(String member) {
      if (struct == null || !struct.contains(member)) return null;
      final value = struct[member];
      return value.isNull ? null : value.asDouble;
    }

    return Ps2001Status(
      flags: {
        for (final flag in Ps2001Flag.values)
          flag: switch (struct) {
            null => null,
            final s => s.contains(flag.member) ? s[flag.member].asBool : null,
          },
      },
      voltage: number(ps2001VoltageMember),
      current: number(ps2001CurrentMember),
    );
  }

  bool? operator [](Ps2001Flag flag) => flags[flag];

  bool _set(Ps2001Flag flag) => flags[flag] ?? false;

  /// True when nothing at all has been published for this unit.
  bool get isUnknown =>
      flags.values.every((v) => v == null) && voltage == null && current == null;

  /// How much of the unit's rating is still spare, 0..1, or null when the
  /// current is unpublished.
  double? get headroom {
    final drawn = current;
    if (drawn == null) return null;
    return ((ps2001RatedCurrent - drawn) / ps2001RatedCurrent).clamp(0.0, 1.0);
  }

  Ps2001FaceState get state {
    if (isUnknown) return Ps2001FaceState.unknown;
    if (_set(Ps2001Flag.error)) return Ps2001FaceState.faulted;
    if (_set(Ps2001Flag.inputUndervoltage)) {
      return Ps2001FaceState.undervoltage;
    }
    if (_set(Ps2001Flag.warning)) return Ps2001FaceState.warning;
    // DC OK unpublished but something else was: the rail's own answer is
    // missing, so do not invent "down" for it.
    return switch (flags[Ps2001Flag.dcOk]) {
      true => Ps2001FaceState.healthy,
      false => Ps2001FaceState.down,
      null => Ps2001FaceState.unknown,
    };
  }
}

/// The chip the pane header shows.
PaneStatus ps2001PaneStatus(Ps2001FaceState state) => switch (state) {
      Ps2001FaceState.faulted => const PaneStatus.fault('Fault'),
      Ps2001FaceState.undervoltage => const PaneStatus.fault('Mains low'),
      Ps2001FaceState.warning => const PaneStatus.warning('Strained'),
      Ps2001FaceState.healthy => const PaneStatus.running('Supplying'),
      Ps2001FaceState.down => const PaneStatus.stopped('Output down'),
      Ps2001FaceState.unknown => const PaneStatus.unknown('No data'),
    };

/// What the state means and what to do about it.
String ps2001Explanation(Ps2001FaceState state) => switch (state) {
      Ps2001FaceState.faulted =>
        'The supply reports a fault — an overload or short circuit has put it '
            'into hiccup mode, or it has shut down on temperature. Everything '
            'on this 24 V rail is at risk. Find what is drawing the current '
            'before the unit gives up entirely.',
      Ps2001FaceState.undervoltage =>
        'The mains feeding this supply is below its valid range. The 24 V '
            'output may still look healthy, but it will not stay that way. '
            'This is a problem upstream of the cabinet, not inside it.',
      Ps2001FaceState.warning =>
        'The supply is flagging a non-critical condition — running hot, or '
            'close to full load. It is still supplying its rail. Check the '
            'current below against the 10 A rating.',
      Ps2001FaceState.healthy =>
        'The output is inside tolerance and nothing is flagged.',
      Ps2001FaceState.down =>
        'The output is below the DC OK threshold and the supply is not '
            'reporting a fault, which is what a unit that has been switched '
            'off looks like. Check its mains feed.',
      Ps2001FaceState.unknown =>
        'Nothing has arrived for this supply. Either no key is configured '
            'for it or the PLC link is down.',
    };

// ---------------------------------------------------------------------------
// Operator surface
// ---------------------------------------------------------------------------

/// The PS2001 pane body.
///
/// A plain [StatelessWidget] fed values — the subscription belongs to the
/// asset, which outlives the overlay this is built into.
class Ps2001PaneBody extends StatelessWidget {
  const Ps2001PaneBody({
    super.key,
    required this.status,
    this.description,
    this.trendTile,
  });

  final Ps2001Status status;

  /// The trend block, or null when the page author left the trend out.
  ///
  /// Injected as a built widget rather than built here, the way the analog
  /// box does it: the chart needs the collector provider, and a canned
  /// preview keeps the pane's own tests provider-free.
  final Widget? trendTile;

  /// What this supply feeds, when the page says. Named so the operator does
  /// not have to work out which rail `ST301.T1` is.
  final String? description;

  /// The two figures worth crossing a plant for, and the only two the struct
  /// measures.
  static String _volts(double? value) =>
      value == null ? '—' : value.toStringAsFixed(1);

  static String _amps(double? value) =>
      value == null ? '—' : value.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final state = status.state;
    final headroom = status.headroom;

    return PaneBody(
      sections: [
        PaneBodySection.status(
          title: 'Supply',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (description != null) ...[
                Text(description!, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
              ],
              PaneExplainRow(
                label: 'State',
                value: ps2001PaneStatus(state).label,
                valueColor: ps2001PaneStatus(state).color,
                // A supply that is out should be readable without a second
                // tap.
                initiallyExpanded: state == Ps2001FaceState.faulted ||
                    state == Ps2001FaceState.undervoltage,
                explanationBuilder: (context) => Text(
                  ps2001Explanation(state),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 10),
              PaneTileRow(
                children: [
                  PaneMetricTile(
                    label: 'Output',
                    value: _volts(status.voltage),
                    unit: 'V',
                    icon: Icons.bolt,
                    valueColor: _voltageColor(colors, status),
                  ),
                  PaneMetricTile(
                    label: 'Draw',
                    value: _amps(status.current),
                    unit: 'A',
                    icon: Icons.trending_up,
                    valueColor: _currentColor(colors, status),
                  ),
                  PaneMetricTile(
                    label: 'Spare',
                    value: headroom == null
                        ? '—'
                        : (headroom * 100).toStringAsFixed(0),
                    unit: '%',
                    icon: Icons.battery_std,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final flag in Ps2001Flag.values)
                PaneDetailRow(
                  // The diode is a fixed 22 px against a label that can wrap,
                  // so centre it.
                  crossAxisAlignment: CrossAxisAlignment.center,
                  label: flag.label,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CustomPaint(
                      painter: LEDPainter(
                        color: _diodeColor(colors, flag, status[flag]),
                        ledType: LEDType.circle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (trendTile != null)
          PaneBodySection.trend(title: 'Over time', child: trendTile!),
      ],
    );
  }

  /// Green while the rail is in tolerance, red once the unit says it is not.
  /// Left uncoloured when there is no DC OK bit to judge against — the
  /// number alone does not know what this unit's threshold is set to.
  Color? _voltageColor(HmiStateColors colors, Ps2001Status status) =>
      switch (status[Ps2001Flag.dcOk]) {
        true => colors.green,
        false => colors.red,
        null => null,
      };

  /// Coloured off the rating, not off a flag: the unit warns late, and an
  /// operator adding one more load wants to see the draw creeping up first.
  Color? _currentColor(HmiStateColors colors, Ps2001Status status) {
    final headroom = status.headroom;
    if (headroom == null) return null;
    if (headroom <= 0.05) return colors.red;
    if (headroom <= 0.2) return colors.yellow;
    return null;
  }

  /// `DC OK` set is good news; the other three are the unit complaining, and
  /// they are not equally serious. Only red belongs to what has stopped or is
  /// about to — a supply merely running hot has not stopped anything, and red
  /// on a mimic is what sends an electrician across the plant. A null stays
  /// unlit; see [Ps2001Status].
  Color? _diodeColor(HmiStateColors colors, Ps2001Flag flag, bool? value) =>
      switch (value) {
        null => null,
        true => switch (flag) {
            Ps2001Flag.dcOk => colors.green,
            Ps2001Flag.warning => colors.yellow,
            Ps2001Flag.error || Ps2001Flag.inputUndervoltage => colors.red,
          },
        false => flag == Ps2001Flag.dcOk ? colors.red : Colors.white,
      };
}

/// Opens the PS2001 pane.
///
/// [stream] feeds the whole pane, so one subscription covers it and dies with
/// the pane.
void showPs2001Pane({
  required BuildContext context,
  required String id,
  required String title,
  required Stream<({Ps2001Status status, String? description})> stream,
  Widget? trendTile,
}) {
  showSidePane(
    context: context,
    id: id,
    builder: (paneContext) =>
        StreamBuilder<({Ps2001Status status, String? description})>(
      stream: stream,
      builder: (context, snap) {
        final data = (snap.hasData && !snap.hasError) ? snap.data : null;
        final status = data?.status ?? Ps2001Status.read(null);

        return SidePane(
          title: title,
          // Kept short: the subtitle shares its row with the status chip in
          // a 380 px pane, and 'Beckhoff · 24 V supply' came out as
          // 'Beckhoff · 24 V supp…'.
          subtitle: 'Beckhoff · supply',
          icon: Icons.power,
          status: ps2001PaneStatus(status.state),
          child: Ps2001PaneBody(
            status: status,
            description: data?.description,
            trendTile: trendTile,
          ),
        );
      },
    ),
  );
}
