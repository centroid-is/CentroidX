/// The side pane for one EtherCAT cable.
///
/// What an operator wants from a cable is not "is it up" — the colour on the
/// mimic already said that — but *should I go and look at it*. So the pane
/// leads with the two numbers that answer it: how long this link has held, and
/// how much it has been erroring lately.
///
/// Totals since commissioning are deliberately not the headline. A cable that
/// collected forty CRC errors two years ago is fine; one collecting them this
/// hour is not, and only the rolling figure separates them.
library;

import 'package:flutter/material.dart';

import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/pane_chrome.dart';
import 'ethercat_link.dart';
import 'ethercat_subdevice.dart';
import 'ethercat_subdevice_pane.dart';
import 'ethercat_link_painter.dart';

/// The chip at the top of the pane.
PaneStatus etherCatLinkPaneStatus(LinkHealth health) => switch (health) {
      LinkHealth.healthy => const PaneStatus.running('Connected'),
      LinkHealth.degraded => const PaneStatus.warning('Errors'),
      LinkHealth.down => const PaneStatus.fault('No link'),
      LinkHealth.idle => const PaneStatus.stopped('Not monitored'),
      LinkHealth.unknown => const PaneStatus.stopped('No data'),
    };

/// A plain widget fed values — the subscription belongs to the asset, which
/// outlives the overlay this is built into.
class EtherCatLinkPaneBody extends StatelessWidget {
  const EtherCatLinkPaneBody({
    super.key,
    required this.state,
    required this.onResetCounters,
  });

  /// Null when nothing is subscribed, or the node is not the struct.
  final EtherCatLinkState? state;

  /// Pulses `p_cmd_xResetCounters`. Completes when the pulse is over so the
  /// button can show it running.
  final Future<void> Function()? onResetCounters;

  // Labels are kept short deliberately: three tiles fit across a 380 px pane,
  // which leaves about 108 px each, and anything longer ellipses to
  // 'Connecte…' -- a label that has lost the word carrying its meaning.
  @override
  Widget build(BuildContext context) {
    final s = state;
    final theme = Theme.of(context);
    if (s == null) {
      return PaneBody(sections: [
        PaneBodySection.status(
          child: Text(
            'No diagnostics for this cable. It is drawn here to document the '
            'wiring; give it a link struct key to see how it is holding up.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ]);
    }

    final states =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;

    return PaneBody(
      sections: [
        PaneBodySection.status(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.stale)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'These figures have stopped updating, so they describe '
                    'the past rather than now.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: states.violet),
                  ),
                ),
              // Two per row, not three. A d:hh:mm uptime is the widest
              // value here and the interesting cables are the old ones:
              // 412 days ellipsed to '412d 07:…' in a 108 px tile, losing
              // exactly the digits somebody opened the pane to read.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  PaneMetricTile(
                    width: 184,
                    label: 'Uptime',
                    value: s.linkUp
                        ? formatDaysHoursMinutes(s.connectedMinutes)
                        : 'down',
                    icon: Icons.timelapse,
                    valueColor: s.linkUp ? null : states.red,
                  ),
                  PaneMetricTile(
                    width: 128,
                    label: 'Connects',
                    value: '${s.connectCount}',
                    icon: Icons.link,
                  ),
                  PaneMetricTile(
                    width: 184,
                    label: 'Best run',
                    value: formatDaysHoursMinutes(s.longestMinutes),
                    icon: Icons.trending_up,
                  ),
                  PaneMetricTile(
                    width: 128,
                    label: 'Errors/h',
                    value: '${s.errorsLastHour}',
                    icon: Icons.warning_amber,
                    valueColor: s.degraded ? states.yellow : null,
                  ),
                  PaneMetricTile(
                    width: 184,
                    label: 'Clean for',
                    value: formatDaysHoursMinutes(s.minutesSinceError),
                    icon: Icons.check_circle_outline,
                  ),
                  PaneMetricTile(
                    width: 128,
                    label: 'Available',
                    value: s.availabilityPct.toStringAsFixed(1),
                    unit: '%',
                    icon: Icons.percent,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _blame(s),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (onResetCounters != null)
          PaneBodySection.manual(
            title: 'Counters',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _ResetButton(onReset: onResetCounters!),
                const SizedBox(height: 8),
                Text(
                  'Zeroes the connection count, the error totals and the '
                  'longest run. The cable is not disturbed and the current '
                  'connection keeps counting.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// One line saying which way the evidence points.
  ///
  /// The forwarded count is the useful half of it: frames that arrived here
  /// already broken are not this cable's fault, and a run with plenty of them
  /// is a witness rather than a suspect.
  static String _blame(EtherCatLinkState s) {
    if (!s.linkUp) {
      return 'No link on this cable. The devices at either end will be '
          'unreachable, and everything downstream of them with it.';
    }
    if (s.crcErrors == 0) {
      return 'No errors counted on this cable since the last reset.';
    }
    if (s.forwardedErrors >= s.crcErrors) {
      return 'Most of what this cable has seen arrived already broken, so the '
          'damage is upstream of it rather than on it.';
    }
    if (s.lostLinks > s.connectCount) {
      return 'The controller has counted more link drops than the PLC scan '
          'saw, which means this link is flapping faster than the cycle time.';
    }
    return 'Errors are being counted on this cable itself.';
  }
}

/// The pane for a cable whose ends are bound devices.
///
/// The struct pane above answers "how has this cable held up" from figures the
/// PLC keeps per cable. There are none here, so this answers the same question
/// from the two ports instead — and adds the one thing only the topology can
/// say: whether the cable somebody drew is the cable the PLC has.
class EcLinkPaneBody extends StatelessWidget {
  const EcLinkPaneBody({
    super.key,
    required this.a,
    required this.subdeviceA,
    required this.busA,
    required this.b,
    required this.subdeviceB,
    required this.busB,
    this.onOpen,
  });

  final EcLinkEnd? a;
  final EcSubDevice? subdeviceA;
  final EcBus? busA;
  final EcLinkEnd? b;
  final EcSubDevice? subdeviceB;
  final EcBus? busB;

  /// Opens one end's device pane, where its counters can be cleared.
  final void Function(EcLinkEnd end)? onOpen;

  /// What the PLC's own topology says about this run.
  ///
  /// The mimic is a drawing and the export is the machine: when they disagree
  /// the drawing is wrong, and saying so is most of what this pane is for.
  String get verdict {
    final ends = [(a, subdeviceA, busA), (b, subdeviceB, busB)];
    for (final (end, subdevice, bus) in ends) {
      if (end == null || subdevice == null || bus == null) continue;
      final other = identical(end, a) ? b : a;
      final neighbour = bus.neighbour(subdevice, end.port);
      if (neighbour == null) {
        return 'The PLC topology has nothing on ${end.label} port '
            '${end.port.letter}. This cable is drawn here, not reported.';
      }
      if (other == null) continue;
      final theirs = neighbour.isMaster ? 'the master' : neighbour.subdevice!.label;
      final drawn = other.binding.name ?? other.label;
      if (!neighbour.isMaster &&
          _sameName(neighbour.subdevice!.label, drawn)) {
        return 'Confirmed by the PLC topology: ${end.label} port '
            '${end.port.letter} goes to ${neighbour.label}.';
      }
      return 'The PLC says ${end.label} port ${end.port.letter} goes to '
          '$theirs, not to $drawn. Either the cable is drawn wrong or the '
          'devices are bound to the wrong subdevices.';
    }
    return 'Only one end of this cable is bound, so the topology cannot '
        'confirm it.';
  }

  static bool _sameName(String a, String b) =>
      a.replaceAll(RegExp(r'\s+'), '').toUpperCase() ==
      b.replaceAll(RegExp(r'\s+'), '').toUpperCase();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;
    final clean = <int>[
      if (subdeviceA?.diag case final d? when d.crcSum > 0) d.crcStableSeconds,
      if (subdeviceB?.diag case final d? when d.crcSum > 0) d.crcStableSeconds,
    ];

    return PaneBody(sections: [
      PaneBodySection.status(
        title: 'Ends',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _EndRow(
                end: a, subdevice: subdeviceA, bus: busA, states: states),
            _EndRow(
                end: b, subdevice: subdeviceB, bus: busB, states: states),
            const SizedBox(height: 10),
            Text(verdict, style: theme.textTheme.bodySmall),
            if (clean.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Clean for ${formatEcAge(clean.reduce((x, y) => x < y ? x : y))}.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      if (onOpen != null)
        PaneBodySection.details(
          title: 'Devices',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final end in [a, b])
                if (end != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => onOpen!(end),
                      icon: const Icon(Icons.settings_ethernet, size: 18),
                      label: Text('Open ${end.label}'),
                    ),
                  ),
              Text(
                'The counters belong to the devices, not to the cable: '
                'clearing them is done there.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
    ]);
  }
}

/// One end: which device, which port, and what that port has counted.
class _EndRow extends StatelessWidget {
  const _EndRow({
    required this.end,
    required this.subdevice,
    required this.bus,
    required this.states,
  });

  final EcLinkEnd? end;
  final EcSubDevice? subdevice;
  final EcBus? bus;
  final HmiStateColors states;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (end == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text('An end that is not plugged into a bound device.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.disabledColor)),
      );
    }
    final d = subdevice?.diag;
    final health = subdevice == null || bus == null
        ? EcHealth.unknown
        : bus!.portHealth(subdevice!, end!.port);
    final crc = d?.crcPort[end!.port.index] ?? 0;
    final lost = d?.linkLostPort[end!.port.index] ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EcPortChip(port: end!.port, health: health, states: states),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(end!.label,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis),
                if (d != null && d.portFlagged(end!.port))
                  Text(d.linkFault!.label,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: ecHealthColor(states, health))),
                if (d == null)
                  Text('No diagnostics yet',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.disabledColor)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            d == null ? '—' : 'CRC $crc · drops $lost',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: crc > 0 || lost > 0 ? states.yellow : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResetButton extends StatefulWidget {
  const _ResetButton({required this.onReset});

  final Future<void> Function() onReset;

  @override
  State<_ResetButton> createState() => _ResetButtonState();
}

class _ResetButtonState extends State<_ResetButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              try {
                await widget.onReset();
              } finally {
                // The pane can close while the pulse is still going.
                if (mounted) setState(() => _busy = false);
              }
            },
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.restart_alt),
      label: const Text('Reset counters'),
    );
  }
}
