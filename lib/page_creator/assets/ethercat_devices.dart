/// Every EtherCAT slave on the station, one dense row each.
///
/// The mimic answers "where is it"; this answers "is anything wrong, and
/// what". One row per slave across every master, in bus order, with the four
/// ports as four cells so a bad cable shows up as the same colour on two
/// adjacent rows — the port that sends and the port that receives.
///
/// Reads the two arrays `FB_EcDeviceDiag` publishes per master — one key
/// mapping each, whatever the slave count — so a hundred rows cost two
/// subscriptions per master rather than two hundred.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';

import '../../providers/state_man.dart';
import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/side_pane.dart';
import 'common.dart';
import 'ethercat_masters.dart';
import 'ethercat_slave.dart';
import 'ethercat_slave_pane.dart';

part 'ethercat_devices.g.dart';

@JsonSerializable(explicitToJson: true)
class EtherCatDeviceTableConfig extends BaseAsset {
  @override
  String get displayName => 'EtherCAT Devices';

  @override
  String get category => 'Beckhoff';

  @override
  List<String> get searchKeywords => const [
        'ethercat',
        'devices',
        'slaves',
        'diagnostics',
        'table',
        'crc',
        'link',
        'topology',
      ];

  /// One entry per EtherCAT master.
  List<EcBusConfig> buses;

  /// Open filtered to the rows that need attention.
  bool problemsOnly;

  EtherCatDeviceTableConfig({List<EcBusConfig>? buses, this.problemsOnly = false})
      : buses = buses ?? [] {
    // A table wants most of a page; the 3% default square is a dot.
    size = const RelativeSize(width: 0.62, height: 0.7);
  }

  EtherCatDeviceTableConfig.preview() : this();

  factory EtherCatDeviceTableConfig.fromJson(Map<String, dynamic> json) =>
      _$EtherCatDeviceTableConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$EtherCatDeviceTableConfigToJson(this);

  /// The keys sit one level down, in [buses], where the introspection in
  /// `BaseAsset.allKeys` cannot see them.
  @override
  List<String> get allKeys => [
        for (final b in buses) ...[
          if (b.diagKey.isNotEmpty) b.diagKey,
          if (b.infoKey.isNotEmpty) b.infoKey,
        ],
      ];

  @override
  Widget build(BuildContext context) => EtherCatDeviceTable(config: this);

  @override
  Widget configure(BuildContext context) =>
      _EtherCatDeviceTableEditor(config: this);
}

/// Runtime widget: subscribes the masters' arrays and lays out the table.
class EtherCatDeviceTable extends ConsumerStatefulWidget {
  const EtherCatDeviceTable({super.key, required this.config});

  final EtherCatDeviceTableConfig config;

  @override
  ConsumerState<EtherCatDeviceTable> createState() =>
      _EtherCatDeviceTableState();
}

class _EtherCatDeviceTableState extends ConsumerState<EtherCatDeviceTable> {
  /// Masters found in the key mappings, used while the config names none.
  List<EcBusConfig> _discovered = const [];
  Timer? _rediscover;

  /// Key mappings are edited in place — accepting one does not rebuild
  /// StateMan or fire any provider — so a table that was dropped before its
  /// masters were mapped would otherwise stay a sample until a restart.
  static const _rediscoverEvery = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _discover();
    _rediscover = Timer.periodic(_rediscoverEvery, (_) => _discover());
  }

  @override
  void dispose() {
    _rediscover?.cancel();
    super.dispose();
  }

  Future<void> _discover() async {
    if (widget.config.buses.isNotEmpty) return;
    List<EcBusConfig> found;
    try {
      final sm = await ref.read(stateManProvider.future);
      found = discoverEcMasters(sm.keyMappings);
    } catch (_) {
      found = const [];
    }
    String sig(List<EcBusConfig> l) =>
        [for (final b in l) '${b.label}|${b.keys.join(',')}'].join(';');
    if (!mounted || sig(found) == sig(_discovered)) return;
    setState(() => _discovered = found);
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final buses = config.buses.isNotEmpty ? config.buses : _discovered;
    if (buses.isEmpty) {
      // Nothing configured yet — on the palette and on a freshly dropped
      // asset. A sample says what the thing is for better than an empty box.
      return EcDeviceTableView(
        buses: ecSampleBuses(),
        caption: 'Sample — add a master in the editor',
        initialProblemsOnly: config.problemsOnly,
      );
    }
    return EcKeyValues(
      keys: [
        for (final b in buses) ...[b.diagKey, b.infoKey],
      ],
      builder: (context, values, errors) {
        final live = <EcBus>[];
        final notes = <String, String>{};
        for (final b in buses) {
          live.add(EcBus.fromValues(
            b.label,
            info: values[b.infoKey],
            diag: values[b.diagKey],
          ));
          final err = errors[b.diagKey] ?? errors[b.infoKey];
          if (err != null) {
            notes[b.label] = 'cannot read';
          } else if (b.diagKey.isNotEmpty && values[b.diagKey] == null) {
            notes[b.label] = 'waiting for data';
          }
        }
        return EcDeviceTableView(
          buses: live,
          busNotes: notes,
          initialProblemsOnly: config.problemsOnly,
          onOpen: (bus, slave) {
            final cfg = buses.firstWhere((b) => b.label == bus.label,
                orElse: () => buses.first);
            showSidePane(
              context: context,
              id: 'ethercat-slave-${cfg.diagKey}-${slave.position}',
              builder: (_) =>
                  EcSlaveLivePane(bus: cfg, position: slave.position),
            );
          },
        );
      },
    );
  }
}

/// Column widths, shared by the header and every row so they line up.
abstract final class _Col {
  static const dot = 18.0;
  static const pos = 34.0;

  /// Includes a trailing gap, so a truncated model name does not run into
  /// the state beside it.
  static const model = 132.0;
  static const state = 56.0;
  static const port = 26.0;
  static const crc = 52.0;
  static const drops = 44.0;
  static const clean = 72.0;
  static const rowHeight = 22.0;

  /// Below these the columns that are least often read go first.
  static const hideModelBelow = 620.0;
  static const hideCleanBelow = 760.0;

  /// The smallest box the toolbar, the header and a couple of rows lay out
  /// in. Anything smaller renders at this size and is scaled down.
  static const minWidth = 480.0;
  static const minHeight = 160.0;
}

/// The table itself, fed values — so it can be goldened without a server.
class EcDeviceTableView extends StatefulWidget {
  const EcDeviceTableView({
    super.key,
    required this.buses,
    this.busNotes = const {},
    this.initialProblemsOnly = false,
    this.onOpen,
    this.caption,
  });

  final List<EcBus> buses;

  /// A word per master when its data is missing, keyed by label.
  final Map<String, String> busNotes;
  final bool initialProblemsOnly;
  final void Function(EcBus bus, EcSlave slave)? onOpen;

  /// Shown in the toolbar in place of the search box's hint.
  final String? caption;

  @override
  State<EcDeviceTableView> createState() => _EcDeviceTableViewState();
}

class _EcDeviceTableViewState extends State<EcDeviceTableView> {
  late bool _problemsOnly = widget.initialProblemsOnly;
  String _query = '';

  bool _matches(EcSlave s) {
    if (_problemsOnly &&
        s.health != EcHealth.warning &&
        s.health != EcHealth.fault &&
        s.health != EcHealth.unknown) {
      return false;
    }
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return s.label.toLowerCase().contains(q) ||
        (s.info?.model.toLowerCase().contains(q) ?? false) ||
        '#${s.position}' == q ||
        '${s.position}' == q;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;

    final rows = <Widget Function(int index)>[];
    for (final bus in widget.buses) {
      final shown = bus.slaves.where(_matches).toList();
      rows.add((_) => _BusHeader(
            bus: bus,
            note: widget.busNotes[bus.label],
            states: states,
          ));
      for (final s in shown) {
        rows.add((i) => _SlaveRow(
              bus: bus,
              slave: s,
              states: states,
              zebra: i.isOdd,
              onTap: widget.onOpen == null
                  ? null
                  : () => widget.onOpen!(bus, s),
            ));
      }
    }

    return Material(
      color: theme.colorScheme.surface,
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          fontSize: 12,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        child: LayoutBuilder(builder: (context, constraints) {
          // Below a size where the toolbar and one row still fit — a palette
          // tile, a freshly dropped asset, a config pane's preview — lay out
          // at that size and scale down. A legible miniature of the table
          // says what it is; a box of overflow stripes does not.
          final w = constraints.maxWidth, h = constraints.maxHeight;
          if (!w.isFinite ||
              !h.isFinite ||
              w < _Col.minWidth ||
              h < _Col.minHeight) {
            return FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: w.isFinite && w > _Col.minWidth ? w : _Col.minWidth,
                height: h.isFinite && h > _Col.minHeight ? h : _Col.minHeight,
                child: _table(context, states, rows, _Col.minWidth),
              ),
            );
          }
          return _table(context, states, rows, w);
        }),
      ),
    );
  }

  /// The toolbar, the header and the rows, laid out for [width].
  Widget _table(
    BuildContext context,
    HmiStateColors states,
    List<Widget Function(int index)> rows,
    double width,
  ) {
    return _LayoutScope(
      layout: _Layout(
        showModel: width >= _Col.hideModelBelow,
        showClean: width >= _Col.hideCleanBelow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            buses: widget.buses,
            states: states,
            caption: widget.caption,
            problemsOnly: _problemsOnly,
            onProblemsOnly: (v) => setState(() => _problemsOnly = v),
            onQuery: (v) => setState(() => _query = v.trim()),
          ),
          const _HeaderRow(),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemExtent: _Col.rowHeight,
              itemBuilder: (context, i) => rows[i](i),
            ),
          ),
        ],
      ),
    );
  }
}

class _Layout {
  const _Layout({required this.showModel, required this.showClean});
  final bool showModel;
  final bool showClean;
}

class _LayoutScope extends InheritedWidget {
  const _LayoutScope({required this.layout, required super.child});
  final _Layout layout;

  static _Layout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LayoutScope>()?.layout ??
      const _Layout(showModel: true, showClean: true);

  @override
  bool updateShouldNotify(_LayoutScope old) =>
      old.layout.showModel != layout.showModel ||
      old.layout.showClean != layout.showClean;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.buses,
    required this.states,
    required this.caption,
    required this.problemsOnly,
    required this.onProblemsOnly,
    required this.onQuery,
  });

  final List<EcBus> buses;
  final HmiStateColors states;
  final String? caption;
  final bool problemsOnly;
  final ValueChanged<bool> onProblemsOnly;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var total = 0, ok = 0, warn = 0, fault = 0, unknown = 0;
    for (final b in buses) {
      for (final s in b.slaves) {
        total++;
        switch (s.health) {
          case EcHealth.ok:
            ok++;
          case EcHealth.warning:
            warn++;
          case EcHealth.fault:
            fault++;
          case EcHealth.unknown || EcHealth.unused:
            unknown++;
        }
      }
    }
    TextSpan count(int n, String word, Color colour) => TextSpan(children: [
          const TextSpan(text: '  ·  '),
          TextSpan(
            text: '$n',
            style: TextStyle(color: colour, fontWeight: FontWeight.w700),
          ),
          TextSpan(text: ' $word'),
        ]);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            height: 30,
            child: TextField(
              onChanged: onQuery,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: caption ?? 'Find a device',
                prefixIcon: const Icon(Icons.search, size: 16),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Problems only'),
            selected: problemsOnly,
            onSelected: onProblemsOnly,
            visualDensity: VisualDensity.compact,
            labelStyle: const TextStyle(fontSize: 12),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.bodySmall,
                children: [
                  TextSpan(
                    text: '$total devices',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  count(ok, 'OK', states.green),
                  if (warn > 0) count(warn, 'warning', states.yellow),
                  if (fault > 0) count(fault, 'fault', states.red),
                  if (unknown > 0) count(unknown, 'no data', states.violet),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = _LayoutScope.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget cell(String t, double w, {bool right = false}) => SizedBox(
          width: w,
          child: Text(t,
              style: style, textAlign: right ? TextAlign.right : null),
        );
    return Container(
      height: _Col.rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          const SizedBox(width: _Col.dot),
          cell('#', _Col.pos),
          Expanded(child: Text('Device', style: style)),
          if (layout.showModel) cell('Model', _Col.model),
          cell('State', _Col.state),
          for (final p in EcPort.values)
            SizedBox(
              width: _Col.port,
              child: Text(p.letter, style: style, textAlign: TextAlign.center),
            ),
          cell('CRC', _Col.crc, right: true),
          cell('Drops', _Col.drops, right: true),
          if (layout.showClean) cell('Clean for', _Col.clean, right: true),
        ],
      ),
    );
  }
}

class _BusHeader extends StatelessWidget {
  const _BusHeader({required this.bus, required this.states, this.note});

  final EcBus bus;
  final HmiStateColors states;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faults = bus.count(EcHealth.fault);
    final warns = bus.count(EcHealth.warning);
    final String summary;
    final Color? colour;
    if (note != null) {
      summary = note!;
      colour = states.violet;
    } else if (faults > 0) {
      summary = '$faults fault${faults == 1 ? '' : 's'}'
          '${warns > 0 ? ', $warns warning${warns == 1 ? '' : 's'}' : ''}';
      colour = states.red;
    } else if (warns > 0) {
      summary = '$warns warning${warns == 1 ? '' : 's'}';
      colour = states.yellow;
    } else {
      summary = 'all OK';
      colour = null;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      color: theme.colorScheme.surfaceContainer,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: bus.label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(
            text: '   ${bus.slaves.length} slaves · ',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          TextSpan(
            text: summary,
            style: TextStyle(color: colour, fontWeight: FontWeight.w600),
          ),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _SlaveRow extends StatelessWidget {
  const _SlaveRow({
    required this.bus,
    required this.slave,
    required this.states,
    required this.zebra,
    this.onTap,
  });

  final EcBus bus;
  final EcSlave slave;
  final HmiStateColors states;
  final bool zebra;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = _LayoutScope.of(context);
    final d = slave.diag;
    final health = slave.health;
    final muted = theme.colorScheme.onSurfaceVariant;
    final stateText = d == null
        ? '—'
        : !d.present
            ? 'GONE'
            : d.state.label + (d.error ? '+E' : '');

    return Material(
      color: zebra
          ? theme.colorScheme.onSurface.withValues(alpha: 0.035)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: _Col.dot,
                child: Align(
                  alignment: Alignment.centerLeft,
                  // Painted, not an icon glyph: a status dot must not depend
                  // on a font having loaded.
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: ecHealthColor(states, health),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: _Col.pos,
                child: Text('${slave.position}',
                    style: TextStyle(color: muted)),
              ),
              Expanded(
                child: Text(
                  slave.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              if (layout.showModel)
                Container(
                  width: _Col.model,
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    slave.info?.model ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted),
                  ),
                ),
              SizedBox(
                width: _Col.state,
                child: Text(
                  stateText,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: health == EcHealth.fault ? states.red : null,
                  ),
                ),
              ),
              for (final p in EcPort.values)
                SizedBox(
                  width: _Col.port,
                  child: Center(child: _portCell(p)),
                ),
              SizedBox(
                width: _Col.crc,
                child: Text(
                  d == null || d.crcSum == 0 ? '·' : '${d.crcSum}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: d != null && d.crcFresh ? states.yellow : muted,
                    fontWeight: d != null && d.crcFresh
                        ? FontWeight.w700
                        : null,
                  ),
                ),
              ),
              SizedBox(
                width: _Col.drops,
                child: Text(
                  d == null || d.linkLostSum == 0 ? '·' : '${d.linkLostSum}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: d != null && d.linkLostSum > 0
                        ? states.yellow
                        : muted,
                    fontWeight:
                        d != null && d.linkLostSum > 0 ? FontWeight.w700 : null,
                  ),
                ),
              ),
              if (layout.showClean)
                SizedBox(
                  width: _Col.clean,
                  child: Text(
                    // The time since the sum last rose only means something
                    // once there has been a rise to measure from.
                    d == null || d.crcSum == 0
                        ? '·'
                        : formatEcAge(d.crcStableSeconds),
                    textAlign: TextAlign.right,
                    style: TextStyle(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _portCell(EcPort p) {
    final d = slave.diag;
    final health = bus.portHealth(slave, p);
    final crc = d?.crcPort[p.index] ?? 0;
    final lost = d?.linkLostPort[p.index] ?? 0;
    final n = bus.neighbour(slave, p);
    final chip = EcPortChip(
      port: p,
      health: health,
      states: states,
      width: 22,
      height: 15,
      // A count where there is one: the letter is already in the header.
      text: crc > 0
          ? _compact(crc)
          : lost > 0
              ? '↯$lost'
              : '',
    );
    return Tooltip(
      message: [
        'Port ${p.letter} → ${n?.label ?? 'not connected'}',
        if (d != null) 'CRC $crc · drops $lost',
        if (d != null && d.portFlagged(p)) d.linkFault!.label,
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: chip,
    );
  }

  static String _compact(int n) {
    if (n < 1000) return '$n';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
    if (n < 1000000) return '${n ~/ 1000}k';
    return '${n ~/ 1000000}M';
  }
}

/// A made-up station for the palette and an unconfigured asset. Shaped like
/// ST101 — a terminal block, a line of drives, a junction with a branch — and
/// with one of each thing the table exists to show.
List<EcBus> ecSampleBuses() {
  EcSlave s(
    String bus,
    int pos,
    String name,
    String model,
    int addr,
    int prev,
    EcPort? prevPort, {
    int deviceState = 8,
    int linkState = 0,
    List<int> crc = const [0, 0, 0, 0],
    List<int> lost = const [0, 0, 0, 0],
    int stable = 9 * 86400,
  }) =>
      EcSlave(
        busLabel: bus,
        position: pos,
        info: EcSlaveInfo(
          name: '$name ($model)',
          model: model,
          physAddr: addr,
          prevPhysAddr: prev,
          prevPort: prevPort,
        ),
        diag: EcSlaveDiag(
          deviceState: deviceState,
          linkState: linkState,
          crcSum: crc.fold(0, (a, b) => a + b),
          crcStableSeconds: stable,
          crcPort: crc,
          linkLostPort: lost,
        ),
      );

  const b = EcPort.b, c = EcPort.c;
  return [
    EcBus('Device 1', [
      s('Device 1', 1, 'ST101.A1.01', 'EL6070', 1001, 0, b),
      s('Device 1', 2, 'ST101.A1.02', 'EL9222-5500', 1002, 1001, b),
      s('Device 1', 3, 'ST101.A1.03', 'EL1008', 1003, 1002, b),
      s('Device 1', 4, 'ST101.A1.15', 'EK1110', 1004, 1003, b),
      s('Device 1', 5, 'CVS01.CN01.FD01', 'ATV320 EtherCAT', 1005, 1004, b,
          crc: const [14, 0, 0, 0], stable: 240),
      s('Device 1', 6, 'CVS01.CN02.FD01', 'ATV320 EtherCAT', 1006, 1005, b,
          crc: const [3, 0, 0, 0], stable: 5 * 86400),
      s('Device 1', 7, 'CVS01.CN03.FD01', 'ATV320 EtherCAT', 1007, 1006, b,
          deviceState: 0, linkState: 0x01),
    ]),
    EcBus('Device 2', [
      s('Device 2', 1, 'Box 84', 'CU2508', 1001, 0, b),
      s('Device 2', 2, 'ST107.A1.00', 'EK1100', 1002, 1001, b),
      s('Device 2', 3, 'ST107.A1.01', 'EL1008', 1003, 1002, b),
      s('Device 2', 4, 'ST101.EM02', 'EP2338-0002', 1004, 1002, c,
          lost: const [2, 0, 0, 0]),
      s('Device 2', 5, 'ST101.RM04', 'EK1100', 1005, 1004, b,
          deviceState: 4),
    ]),
  ];
}

/// Configure form: the masters, and whether to open filtered.
class _EtherCatDeviceTableEditor extends StatefulWidget {
  const _EtherCatDeviceTableEditor({required this.config});

  final EtherCatDeviceTableConfig config;

  @override
  State<_EtherCatDeviceTableEditor> createState() =>
      _EtherCatDeviceTableEditorState();
}

class _EtherCatDeviceTableEditorState
    extends State<_EtherCatDeviceTableEditor> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buses = widget.config.buses;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'One entry per EtherCAT master: the key of its '
            'ECT_Diag.Device_<n>_Diag array and of its '
            'ECT_Diag.Device_<n>_SlaveInfo array.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < buses.length; i++)
            Card(
              key: ObjectKey(buses[i]),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            initialValue: buses[i].label,
                            decoration:
                                const InputDecoration(labelText: 'Master'),
                            onChanged: (v) => buses[i].label = v,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() => buses.removeAt(i)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    KeyField(
                      label: 'Diagnostics array key',
                      initialValue: buses[i].diagKey,
                      onChanged: (v) => buses[i].diagKey = v,
                    ),
                    const SizedBox(height: 8),
                    KeyField(
                      label: 'Slave info array key',
                      initialValue: buses[i].infoKey,
                      onChanged: (v) => buses[i].infoKey = v,
                    ),
                  ],
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed: () => setState(() =>
                buses.add(EcBusConfig(label: 'Device ${buses.length + 1}'))),
            icon: const Icon(Icons.add),
            label: const Text('Add master'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Open showing problems only'),
            value: widget.config.problemsOnly,
            onChanged: (v) => setState(() => widget.config.problemsOnly = v),
          ),
        ],
      ),
    );
  }
}
