/// The side pane for one EtherCAT subdevice, and the plumbing the table, the
/// binding editor and the cable share to read the bus arrays.
///
/// The pane answers the question the table row cannot: *which* link. The row
/// says a drive is erroring; the pane says it is port A, which is the cable
/// from the drive before it, and that the other end of that cable is clean.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541.dart' show DynamicValue;

import '../../providers/state_man.dart';
import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'ethercat_command.dart';
import 'ethercat_ports.dart';
import 'ethercat_subdevice.dart';

/// The state colour for [health], from the page's scheme.
Color ecHealthColor(HmiStateColors states, EcHealth health) =>
    switch (health) {
      EcHealth.ok => states.green,
      EcHealth.warning => states.yellow,
      EcHealth.fault => states.red,
      EcHealth.unused => states.grey,
      EcHealth.unknown => states.violet,
    };

/// The chip at the top of the pane.
PaneStatus ecSubDevicePaneStatus(EcSubDevice? subdevice) {
  final d = subdevice?.diag;
  if (d == null) return const PaneStatus.stopped('No data');
  return switch (d.health) {
    EcHealth.ok => const PaneStatus.running('OP'),
    EcHealth.warning => PaneStatus.warning(
        d.linkFault == EcLinkFault.additionalLink ? 'Extra link' : 'Errors'),
    EcHealth.fault => PaneStatus.fault(_faultWord(d)),
    EcHealth.unused || EcHealth.unknown => const PaneStatus.stopped('No data'),
  };
}

String _faultWord(EcSubDeviceDiag d) {
  if (!d.present) return 'Not present';
  if (d.error) return 'Error';
  if (d.state != EcSubDeviceState.op) return d.state.label;
  return d.linkFault?.label ?? 'Fault';
}

String _flaggedPorts(EcSubDeviceDiag d) {
  if (d.linkState & 0xF0 == 0) return 'every port';
  final ports = [
    for (final p in EcPort.values)
      if (d.portFlagged(p)) p.letter,
  ];
  return 'port ${ports.join('/')}';
}

/// A span of seconds as a short age: `42s`, `4m`, `3h 12m`, `5d 3h`.
///
/// Not `d:hh:mm` like the cable's uptime: in a 70 px column `00:04` reads as
/// four seconds as easily as four minutes, and what the column is for is
/// "how long ago", where the unit is the whole answer.
String formatEcAge(int seconds) {
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  if (h < 24) return '${h}h ${m % 60}m';
  return '${h ~/ 24}d ${h % 24}h';
}

/// One sentence on what [d] means, for the pane and the binding preview.
String ecSubDeviceSummary(EcSubDeviceDiag d) {
  if (!d.present) {
    return 'Not answering on the bus. Everything after it on this master is '
        'unreachable too.';
  }
  if (d.error) return 'In ${d.state.label} with the error flag set.';
  if (d.state != EcSubDeviceState.op) {
    return 'In ${d.state.label}, not OP: no process data is being exchanged.';
  }
  final fault = d.linkFault;
  if (fault == EcLinkFault.additionalLink) {
    return 'In OP. An extra link on ${_flaggedPorts(d)} that the '
        'configuration does not know about.';
  }
  if (fault != null) return '${fault.label} on ${_flaggedPorts(d)}.';
  if (d.crcFresh) {
    return 'In OP, with CRC errors in the last hour '
        '(${d.crcSum} since the counters were cleared).';
  }
  if (d.linkLostSum > 0) {
    final n = d.linkLostSum;
    return 'In OP. The link has dropped $n time${n == 1 ? '' : 's'} since '
        'the counters were cleared.';
  }
  return 'In OP, no recent errors.';
}

/// Latest value of each of [keys], rebuilt whenever one changes.
///
/// One subscription per key however many widgets ask: StateMan shares the
/// monitored item, so the table, a pane and six cables all reading
/// `Device_1_Diag` cost one read of it.
class EcKeyValues extends ConsumerStatefulWidget {
  const EcKeyValues({super.key, required this.keys, required this.builder});

  final List<String> keys;
  final Widget Function(
    BuildContext context,
    Map<String, DynamicValue> values,
    Map<String, Object> errors,
  ) builder;

  @override
  ConsumerState<EcKeyValues> createState() => _EcKeyValuesState();
}

class _EcKeyValuesState extends ConsumerState<EcKeyValues> {
  final _subs = <String, StreamSubscription<DynamicValue>>{};
  final _values = <String, DynamicValue>{};
  final _errors = <String, Object>{};

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(EcKeyValues old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Subscribes what is new, drops what is gone, leaves the rest alone — a
  /// rebuild must not be a resubscribe.
  void _sync() {
    final want = {
      for (final k in widget.keys)
        if (k.isNotEmpty) k,
    };
    for (final k in _subs.keys.toList()) {
      if (want.contains(k)) continue;
      // Never awaited: an awaited cancel stalls fake-async widget tests.
      unawaited(_subs.remove(k)!.cancel());
      _values.remove(k);
      _errors.remove(k);
    }
    for (final k in want) {
      if (_subs.containsKey(k)) continue;
      _subs[k] = ref
          .read(stateManProvider.future)
          .asStream()
          .asyncExpand((sm) => sm.subscribe(k).asStream())
          .asyncExpand((s) => s)
          .listen(
        (v) {
          if (!mounted) return;
          setState(() {
            _values[k] = v;
            _errors.remove(k);
          });
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() => _errors[k] = e);
        },
      );
    }
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      unawaited(s.cancel());
    }
    _subs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _values, _errors);
}

/// The pane for subdevice [position] on [bus], live.
///
/// Subscribes for itself rather than being handed a snapshot: a pane opened
/// to watch a flapping link has to show it flapping.
class EcSubDeviceLivePane extends ConsumerWidget {
  const EcSubDeviceLivePane({super.key, required this.bus, required this.position});

  final EcBusConfig bus;
  final int position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EcKeyValues(
      keys: [bus.diagKey, bus.infoKey],
      builder: (context, values, errors) {
        final b = EcBus.fromValues(bus.label,
            info: values[bus.infoKey], diag: values[bus.diagKey]);
        final subdevice = b.at(position);
        final model = subdevice?.info?.model ?? '';
        return SidePane(
          title: subdevice?.label ?? '#$position',
          subtitle: [
            bus.label,
            '#$position',
            if (model.isNotEmpty) model,
          ].join(' · '),
          icon: Icons.settings_ethernet,
          status: ecSubDevicePaneStatus(subdevice),
          child: subdevice == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('This subdevice is not in the array any more.'),
                )
              : EcSubDevicePaneBody(
                  bus: b,
                  subdevice: subdevice,
                  onReset: bus.diagKey.isEmpty
                      ? null
                      : (member) => ref
                          .read(ecCommandWriterProvider)
                          .setCommand(ref,
                              diagKey: bus.diagKey,
                              position: position,
                              member: member),
                ),
        );
      },
    );
  }
}

/// A plain widget fed values, so it can be goldened without a server.
class EcSubDevicePaneBody extends StatelessWidget {
  const EcSubDevicePaneBody({
    super.key,
    required this.bus,
    required this.subdevice,
    this.onReset,
  });

  final EcBus bus;
  final EcSubDevice subdevice;

  /// Sets one of [EcDiagFields.resetCrc] / [EcDiagFields.resetLinkLost].
  final Future<void> Function(String member)? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;
    final d = subdevice.diag;
    final info = subdevice.info;

    return PaneBody(sections: [
      PaneBodySection.status(
        child: d == null
            ? Text(
                'No diagnostics for this subdevice yet. Either the array has not '
                'been read, or the PLC is not filling it.',
                style: theme.textTheme.bodySmall,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PaneMetricTile(
                        width: 104,
                        label: 'State',
                        value: d.state.label,
                        icon: Icons.memory,
                        valueColor: d.state == EcSubDeviceState.op && !d.error
                            ? null
                            : states.red,
                      ),
                      PaneMetricTile(
                        width: 104,
                        label: 'CRC',
                        value: '${d.crcSum}',
                        icon: Icons.warning_amber,
                        valueColor: d.crcFresh ? states.yellow : null,
                      ),
                      PaneMetricTile(
                        width: 104,
                        label: 'Drops',
                        value: '${d.linkLostSum}',
                        icon: Icons.link_off,
                        valueColor: d.linkLostSum > 0 ? states.yellow : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    d.crcSum == 0
                        ? ecSubDeviceSummary(d)
                        : '${ecSubDeviceSummary(d)} Last CRC rise '
                            '${formatEcAge(d.crcStableSeconds)} ago.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
      ),
      // A status section, not details: which link is the answer the pane is
      // opened for, and details sort below the reset buttons.
      PaneBodySection.status(
        title: 'Links',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Only the sockets this part has: four rows for a two-port drive
            // would be two rows of "Not connected" that can never be anything
            // else.
            for (final p in ecShownPorts(bus, subdevice))
              _PortRow(bus: bus, subdevice: subdevice, port: p, states: states),
          ],
        ),
      ),
      PaneBodySection.details(
        title: 'Subdevice',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PaneDetailRow(
                label: 'Model',
                value: (info?.model ?? '').isEmpty ? '—' : info!.model),
            PaneDetailRow(
                label: 'Address',
                value: info == null || info.physAddr == 0
                    ? '—'
                    : '${info.physAddr}'),
            PaneDetailRow(label: 'Master', value: bus.label),
            PaneDetailRow(label: 'Position', value: '${subdevice.position}'),
          ],
        ),
      ),
      if (onReset != null && d != null)
        PaneBodySection.manual(
          title: 'Counters',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ResetButton(
                label: 'Clear CRC counters',
                onReset: () => onReset!(EcDiagFields.resetCrc),
              ),
              const SizedBox(height: 8),
              _ResetButton(
                label: 'Clear link drops',
                onReset: () => onReset!(EcDiagFields.resetLinkLost),
              ),
              const SizedBox(height: 8),
              Text(
                'Clears the figures on this subdevice only. The bus is not '
                'disturbed, and the time since the last CRC rise keeps '
                'counting — clearing the count does not mend the cable.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
    ]);
  }
}

/// Port letter, what it goes to, and its two counters.
class _PortRow extends StatelessWidget {
  const _PortRow({
    required this.bus,
    required this.subdevice,
    required this.port,
    required this.states,
  });

  final EcBus bus;
  final EcSubDevice subdevice;
  final EcPort port;
  final HmiStateColors states;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = subdevice.diag;
    final neighbour = bus.neighbour(subdevice, port);
    final health = bus.portHealth(subdevice, port);
    final colour = ecHealthColor(states, health);
    final crc = d?.crcPort[port.index] ?? 0;
    final lost = d?.linkLostPort[port.index] ?? 0;
    // Only where the colour says so: a subdevice that is gone flags every port,
    // and "Not present" under an empty socket says nothing useful.
    final flagged = (d?.portFlagged(port) ?? false) &&
        (health == EcHealth.fault || health == EcHealth.warning);
    final small = theme.textTheme.bodySmall;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EcPortChip(port: port, health: health, states: states),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  neighbour?.label ?? 'Not connected',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: neighbour == null ? theme.disabledColor : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (flagged)
                  Text(d!.linkFault!.label,
                      style: small?.copyWith(color: colour)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            neighbour == null && crc == 0 && lost == 0
                ? '—'
                : 'CRC $crc · drops $lost',
            style: small?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: crc > 0 || lost > 0 ? states.yellow : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A port letter on its health colour. Shared with the table's port columns
/// so the two read as the same thing.
class EcPortChip extends StatelessWidget {
  const EcPortChip({
    super.key,
    required this.port,
    required this.health,
    required this.states,
    this.text,
    this.width = 22,
    this.height = 18,
  });

  final EcPort port;
  final EcHealth health;
  final HmiStateColors states;

  /// What to print instead of the letter — the table puts a count here.
  final String? text;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colour = ecHealthColor(states, health);
    // Unused is an outline, so a row of four reads as "two cables" at a
    // glance rather than as four lamps of which two are grey.
    final unused = health == EcHealth.unused;
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: unused ? null : colour,
        borderRadius: BorderRadius.circular(3),
        border: unused ? Border.all(color: colour, width: 1) : null,
      ),
      child: Text(
        text ?? port.letter,
        maxLines: 1,
        style: TextStyle(
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: unused ? colour : states.onState,
        ),
      ),
    );
  }
}

class _ResetButton extends StatefulWidget {
  const _ResetButton({required this.label, required this.onReset});

  final String label;
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
              final messenger = ScaffoldMessenger.maybeOf(context);
              setState(() => _busy = true);
              try {
                await widget.onReset();
              } catch (e) {
                messenger?.showSnackBar(
                  SnackBar(content: Text('${widget.label} failed: $e')),
                );
              } finally {
                // The pane can close while the write is still out.
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
      label: Text(widget.label),
    );
  }
}
