/// Every EtherCAT subdevice on the station, one dense row each.
///
/// The mimic answers "where is it"; this answers "is anything wrong, and
/// what". One row per subdevice, under its master and its PLC in the order they
/// were configured, like the stop timeline's tree; with the four
/// ports as four cells so a bad cable shows up as the same colour on two
/// adjacent rows — the port that sends and the port that receives.
///
/// Reads the two arrays `FB_EcDeviceDiag` publishes per master — one key
/// mapping each, whatever the subdevice count — so a hundred rows cost two
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
import 'ethercat_ports.dart';
import 'ethercat_subdevice.dart';
import 'ethercat_subdevice_pane.dart';
import 'link_anchors.dart' show PageAssetsScope;

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
        'subdevices',
        'diagnostics',
        'table',
        'crc',
        'link',
        'topology',
      ];

  /// The PLCs, each with the EtherCAT masters it runs, in the order the table
  /// lists them.
  ///
  /// Pages saved before PLCs existed carry a flat `buses` list instead; see
  /// [EtherCatDeviceTableConfig.fromJson]. Only `plcs` is written back, so an
  /// older build opening a newer page finds no masters and falls back to
  /// discovery — the right station's table, just not in the chosen order.
  List<EcPlcConfig> plcs;

  /// Open filtered to the rows that need attention.
  bool problemsOnly;

  EtherCatDeviceTableConfig({List<EcPlcConfig>? plcs, this.problemsOnly = false})
      : plcs = plcs ?? [] {
    // A table wants most of a page; the 3% default square is a dot.
    size = const RelativeSize(width: 0.62, height: 0.7);
  }

  EtherCatDeviceTableConfig.preview() : this();

  factory EtherCatDeviceTableConfig.fromJson(Map<String, dynamic> json) {
    // A page saved before PLCs existed: its masters become one unnamed PLC,
    // which the table draws exactly as it drew the flat list.
    final legacy = json['buses'];
    if (json['plcs'] == null && legacy is List && legacy.isNotEmpty) {
      json = {
        ...json,
        'plcs': [
          {'label': '', 'masters': legacy},
        ],
      };
    }
    return _$EtherCatDeviceTableConfigFromJson(json);
  }

  @override
  Map<String, dynamic> toJson() => _$EtherCatDeviceTableConfigToJson(this);

  /// Every configured master, PLC by PLC.
  @JsonKey(includeFromJson: false, includeToJson: false)
  Iterable<EcBusConfig> get masters => plcs.expand((p) => p.masters);

  /// The keys sit two levels down, in [plcs], where the introspection in
  /// `BaseAsset.allKeys` cannot see them.
  @override
  List<String> get allKeys => [
        for (final b in masters) ...[
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
  /// PLCs found in the key mappings, used while the config names no master.
  List<EcPlcConfig> _discovered = const [];
  Timer? _rediscover;

  /// Key mappings are edited in place — accepting one does not rebuild
  /// StateMan or fire any provider — so a table that was dropped before its
  /// masters were mapped would otherwise stay a sample until a restart.
  static const _rediscoverEvery = Duration(seconds: 5);

  /// True once the widget is gone, so a lookup that was already in flight
  /// cannot touch the tree or start the next one.
  bool _disposed = false;

  /// Whether a lookup has been asked for yet. One per mount.
  bool _asked = false;

  @override
  void dispose() {
    _disposed = true;
    _rediscover?.cancel();
    super.dispose();
  }

  /// Looks for masters the first time this table is actually asked to show
  /// the plant, and never before.
  ///
  /// Not from `initState`, and not on a timer of its own: the page editor
  /// draws every asset in its palette as a thumbnail — a bare `build`, with
  /// none of the canvas's scopes around it — so anything this widget does on
  /// mount, a palette tile does too. Going to look for masters builds a
  /// StateMan behind the picture, and closing that one leaves a five-second
  /// timer that outlives the tree. `page_editor_golden_test` fails on it, and
  /// only on macOS: Windows cannot build the client at all, so the leak hides.
  void _discoverOnce() {
    if (_asked || _disposed) return;
    _asked = true;
    _discover();
    _rediscover = Timer.periodic(_rediscoverEvery, (_) => _discover());
  }

  Future<void> _discover() async {
    if (widget.config.masters.isNotEmpty) return;
    List<EcPlcConfig> found;
    try {
      final sm = await ref.read(stateManProvider.future);
      found = discoverEcPlcs(sm.keyMappings);
    } catch (_) {
      found = const [];
    }
    if (_disposed) return;
    String sig(List<EcPlcConfig> l) => [
          for (final p in l)
            '${p.label}>'
                '${[for (final b in p.masters) '${b.label}|${b.keys.join(',')}'].join(';')}',
        ].join('/');
    if (!mounted || sig(found) == sig(_discovered)) return;
    setState(() => _discovered = found);
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    // On a page — the runtime one or the editor's canvas — `PageAssetsScope`
    // is there; in the palette's thumbnails it is not, and neither is any
    // other scope. That is the line between a table and a picture of one, and
    // the only side of it that may go looking for the station's masters.
    if (PageAssetsScope.maybeOf(context) != null) _discoverOnce();
    final plcs = config.masters.isNotEmpty ? config.plcs : _discovered;
    final masters = [for (final p in plcs) ...p.masters];
    if (masters.isEmpty) {
      // Nothing configured yet — on the palette and on a freshly dropped
      // asset. A sample says what the thing is for better than an empty box.
      return EcDeviceTableView(
        plcs: ecSamplePlcs(),
        caption: 'Sample — add a PLC in the editor',
        initialProblemsOnly: config.problemsOnly,
        // A picture of the table, not a working one: this is what the palette
        // tile shows, and a tile must not hold a focusable field.
        interactive: false,
      );
    }
    return EcKeyValues(
      keys: [
        for (final b in masters) ...[b.diagKey, b.infoKey],
      ],
      builder: (context, values, errors) {
        final live = <EcPlc>[];
        // Keyed by the very objects built here rather than by label: two PLCs
        // can each have a Device 1.
        final configOf = <EcBus, (EcPlcConfig, EcBusConfig)>{};
        final notes = <EcBus, String>{};
        for (final p in plcs) {
          final buses = <EcBus>[];
          for (final b in p.masters) {
            final bus = EcBus.fromValues(
              b.label,
              info: values[b.infoKey],
              diag: values[b.diagKey],
            );
            buses.add(bus);
            configOf[bus] = (p, b);
            final err = errors[b.diagKey] ?? errors[b.infoKey];
            if (err != null) {
              notes[bus] = 'cannot read';
            } else if (b.diagKey.isNotEmpty && values[b.diagKey] == null) {
              notes[bus] = 'waiting for data';
            }
          }
          live.add(EcPlc(p.label, buses));
        }
        return EcDeviceTableView(
          plcs: live,
          busNotes: notes,
          initialProblemsOnly: config.problemsOnly,
          onOpen: (bus, subdevice) {
            final (plc, cfg) = configOf[bus]!;
            showSidePane(
              context: context,
              id: 'ethercat-subdevice-${cfg.diagKey}-${subdevice.position}',
              builder: (_) => EcSubDeviceLivePane(
                bus: cfg,
                position: subdevice.position,
                plcLabel: plc.label,
              ),
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

  /// A PLC or master row: its name and a summary line under it.
  static const groupRowHeight = 34.0;

  /// How far each level of the tree sits in from the one above.
  static const indent = 14.0;

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
    required this.plcs,
    this.busNotes = const {},
    this.initialProblemsOnly = false,
    this.onOpen,
    this.caption,
    this.interactive = true,
  });

  /// The PLCs, each with its masters, in the order they are listed.
  final List<EcPlc> plcs;

  /// A word per master when its data is missing.
  final Map<EcBus, String> busNotes;
  final bool initialProblemsOnly;
  final void Function(EcBus bus, EcSubDevice subdevice)? onOpen;

  /// Shown in the toolbar in place of the search box's hint.
  final String? caption;

  /// Whether the toolbar's search box is a real field.
  ///
  /// False where the table is a picture of itself — the palette tile, an
  /// asset dropped before its masters are named. A thumbnail must not hold a
  /// focusable text field: the page editor's own palette has one, and a
  /// second one on screen breaks anything that types into "the" search box.
  final bool interactive;

  @override
  State<EcDeviceTableView> createState() => _EcDeviceTableViewState();
}

/// One line of the table: how tall it is, and how to draw it at its index.
typedef _Row = ({double height, Widget Function(int index) build});

class _EcDeviceTableViewState extends State<EcDeviceTableView> {
  late bool _problemsOnly = widget.initialProblemsOnly;
  String _query = '';

  /// The PLC and master rows somebody has closed.
  ///
  /// Everything starts open: the table is there to answer "is anything
  /// wrong", and a closed group hides the answer. Kept as the closed set, not
  /// the open one, so a master that turns up later arrives open.
  final Set<String> _collapsed = {};

  /// A PLC row is only worth drawing when it tells PLCs apart, or when the one
  /// PLC was given a name. A page from before PLCs existed stays a list of
  /// masters.
  bool get _showPlcRows =>
      widget.plcs.length > 1 ||
      (widget.plcs.length == 1 && widget.plcs.single.label.isNotEmpty);

  static String _plcKey(EcPlc p) => 'p:${p.label}';
  static String _busKey(EcPlc p, EcBus b) => 'm:${p.label}/${b.label}';

  bool _matches(EcSubDevice s) {
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

  /// Opens every group holding a row the filter just picked out, so a search
  /// never lands on a closed group and looks like it found nothing.
  void _openMatches() {
    if (!_problemsOnly && _query.isEmpty) return;
    for (final p in widget.plcs) {
      for (final b in p.buses) {
        if (b.subdevices.any(_matches)) {
          _collapsed
            ..remove(_plcKey(p))
            ..remove(_busKey(p, b));
        }
      }
    }
  }

  void _toggle(String key) => setState(() {
        if (!_collapsed.remove(key)) _collapsed.add(key);
      });

  /// "1 fault, 2 warnings" or "all OK", in the colour of the worst of them.
  static (String, Color?) _health(int faults, int warns, HmiStateColors states) {
    String n(int c, String word) => '$c $word${c == 1 ? '' : 's'}';
    if (faults > 0) {
      return (
        n(faults, 'fault') + (warns > 0 ? ', ${n(warns, 'warning')}' : ''),
        states.red,
      );
    }
    if (warns > 0) return (n(warns, 'warning'), states.yellow);
    return ('all OK', null);
  }

  (String, Color?) _busSummary(EcBus bus, HmiStateColors states) {
    final note = widget.busNotes[bus];
    final (text, colour) = note != null
        ? (note, states.violet)
        : _health(
            bus.count(EcHealth.fault), bus.count(EcHealth.warning), states);
    return ('${bus.subdevices.length} subdevices · $text', colour);
  }

  (String, Color?) _plcSummary(EcPlc plc, HmiStateColors states) {
    // A PLC none of whose masters can be read says why, like a master does.
    final unread = plc.buses.isNotEmpty &&
        plc.buses.every((b) => widget.busNotes.containsKey(b));
    final (text, colour) = unread
        ? (widget.busNotes[plc.buses.first]!, states.violet)
        : _health(
            plc.count(EcHealth.fault), plc.count(EcHealth.warning), states);
    final m = plc.buses.length;
    return (
      '$m master${m == 1 ? '' : 's'} · ${plc.subdeviceCount} subdevices · $text',
      colour,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states =
        theme.extension<HmiStateColors>() ?? HmiStateColors.solarizedLight;
    final showPlcs = _showPlcRows;
    final busDepth = showPlcs ? 1 : 0;

    final rows = <_Row>[];
    for (final plc in widget.plcs) {
      if (showPlcs) {
        final key = _plcKey(plc);
        final open = !_collapsed.contains(key);
        final summary = _plcSummary(plc, states);
        rows.add((
          height: _Col.groupRowHeight,
          build: (_) => _GroupRow(
                key: ValueKey('ec-row-$key'),
                label: plc.label.isEmpty ? 'PLC' : plc.label,
                summary: summary,
                depth: 0,
                isPlc: true,
                open: open,
                onTap: () => _toggle(key),
              ),
        ));
        if (!open) continue;
      }
      for (final bus in plc.buses) {
        final key = _busKey(plc, bus);
        final open = !_collapsed.contains(key);
        final summary = _busSummary(bus, states);
        rows.add((
          height: _Col.groupRowHeight,
          build: (_) => _GroupRow(
                key: ValueKey('ec-row-$key'),
                label: bus.label,
                summary: summary,
                depth: busDepth,
                isPlc: false,
                open: open,
                onTap: () => _toggle(key),
              ),
        ));
        if (!open) continue;
        for (final s in bus.subdevices.where(_matches)) {
          rows.add((
            height: _Col.rowHeight,
            build: (i) => _SubdeviceRow(
                  bus: bus,
                  subdevice: s,
                  states: states,
                  zebra: i.isOdd,
                  onTap: widget.onOpen == null
                      ? null
                      : () => widget.onOpen!(bus, s),
                ),
          ));
        }
      }
    }
    final leafIndent = (busDepth + 1) * _Col.indent;

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
                child: _table(context, states, rows, _Col.minWidth, leafIndent),
              ),
            );
          }
          return _table(context, states, rows, w, leafIndent);
        }),
      ),
    );
  }

  /// The toolbar, the header and the rows, laid out for [width].
  Widget _table(
    BuildContext context,
    HmiStateColors states,
    List<_Row> rows,
    double width,
    double leafIndent,
  ) {
    return _LayoutScope(
      layout: _Layout(
        showModel: width >= _Col.hideModelBelow,
        showClean: width >= _Col.hideCleanBelow,
        leafIndent: leafIndent,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            buses: [for (final p in widget.plcs) ...p.buses],
            states: states,
            caption: widget.caption,
            interactive: widget.interactive,
            problemsOnly: _problemsOnly,
            onProblemsOnly: (v) => setState(() {
              _problemsOnly = v;
              _openMatches();
            }),
            onQuery: (v) => setState(() {
              _query = v.trim();
              _openMatches();
            }),
          ),
          const _HeaderRow(),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemExtentBuilder: (i, _) =>
                  i < rows.length ? rows[i].height : null,
              itemBuilder: (context, i) => rows[i].build(i),
            ),
          ),
        ],
      ),
    );
  }
}

class _Layout {
  const _Layout({
    required this.showModel,
    required this.showClean,
    required this.leafIndent,
  });
  final bool showModel;
  final bool showClean;

  /// How far a subdevice row sits in, under its master (and its PLC). The
  /// header takes the same, so the columns stay over their figures.
  final double leafIndent;
}

class _LayoutScope extends InheritedWidget {
  const _LayoutScope({required this.layout, required super.child});
  final _Layout layout;

  static _Layout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LayoutScope>()?.layout ??
      const _Layout(showModel: true, showClean: true, leafIndent: _Col.indent);

  @override
  bool updateShouldNotify(_LayoutScope old) =>
      old.layout.showModel != layout.showModel ||
      old.layout.showClean != layout.showClean ||
      old.layout.leafIndent != layout.leafIndent;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.buses,
    required this.states,
    required this.caption,
    required this.interactive,
    required this.problemsOnly,
    required this.onProblemsOnly,
    required this.onQuery,
  });

  final List<EcBus> buses;
  final HmiStateColors states;
  final String? caption;
  final bool interactive;
  final bool problemsOnly;
  final ValueChanged<bool> onProblemsOnly;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var total = 0, ok = 0, warn = 0, fault = 0, unknown = 0;
    for (final b in buses) {
      for (final s in b.subdevices) {
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
            child: interactive
                ? TextField(
                    onChanged: onQuery,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: caption ?? 'Find a device',
                      prefixIcon: const Icon(Icons.search, size: 16),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 8),
                    ),
                  )
                : _SearchBoxPicture(
                    label: caption ?? 'Find a device', theme: theme),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Problems only'),
            selected: problemsOnly,
            // Inert in a thumbnail, like the search box beside it.
            onSelected: interactive ? onProblemsOnly : null,
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

/// A search box that is only a drawing of one.
///
/// Same shape and weight as the real field so a thumbnail reads as the table
/// it stands for, with nothing to focus and nothing to type into.
class _SearchBoxPicture extends StatelessWidget {
  const _SearchBoxPicture({required this.label, required this.theme});

  final String label;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final hint = theme.hintColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: hint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: hint),
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
      padding: EdgeInsets.only(left: 6 + layout.leafIndent, right: 8),
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

/// A PLC's or a master's row: its name, and a line saying how it is doing.
///
/// Drawn after the stop timeline's group lanes — a triangle, the name in bold,
/// a small summary under it, one indent step per level — so a tree of devices
/// and a tree of stops read the same way. A tap opens or closes what is under
/// it.
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    super.key,
    required this.label,
    required this.summary,
    required this.depth,
    required this.isPlc,
    required this.open,
    required this.onTap,
  });

  final String label;
  final (String, Color?) summary;
  final int depth;

  /// A PLC row rather than a master's. Coloured by what it is, not by depth:
  /// a page with no PLC rows keeps its masters in the colour they always had.
  final bool isPlc;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, colour) = summary;
    return Material(
      // A PLC a step darker than its masters, so it stands off them. Highest
      // rather than High: the app's themes set only the low and highest
      // containers, and the others fall back to a lighter default.
      color: isPlc
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.surfaceContainer,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.only(left: 6 + depth * _Col.indent, right: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: Icon(
                  open ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 16,
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9,
                        color: colour ?? theme.colorScheme.onSurfaceVariant,
                        fontWeight: colour != null ? FontWeight.w600 : null,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubdeviceRow extends StatelessWidget {
  const _SubdeviceRow({
    required this.bus,
    required this.subdevice,
    required this.states,
    required this.zebra,
    this.onTap,
  });

  final EcBus bus;
  final EcSubDevice subdevice;
  final HmiStateColors states;
  final bool zebra;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = _LayoutScope.of(context);
    final d = subdevice.diag;
    final health = subdevice.health;
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
          padding: EdgeInsets.only(left: 6 + layout.leafIndent, right: 8),
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
                child: Text('${subdevice.position}',
                    style: TextStyle(color: muted)),
              ),
              Expanded(
                child: Text(
                  subdevice.label,
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
                    subdevice.info?.model ?? '',
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
                  // A port this part does not have is left empty. An outlined
                  // cell would say "a socket, with nothing in it", which is a
                  // different and wrong statement about an ATV320's C and D.
                  child: ecShownPorts(bus, subdevice).contains(p)
                      ? Center(child: _portCell(p))
                      : null,
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
    final d = subdevice.diag;
    final health = bus.portHealth(subdevice, p);
    final crc = d?.crcPort[p.index] ?? 0;
    final lost = d?.linkLostPort[p.index] ?? 0;
    final n = bus.neighbour(subdevice, p);
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
  EcSubDevice s(
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
      EcSubDevice(
        busLabel: bus,
        position: pos,
        info: EcSubDeviceInfo(
          name: '$name ($model)',
          model: model,
          physAddr: addr,
          prevPhysAddr: prev,
          prevPort: prevPort,
        ),
        diag: EcSubDeviceDiag(
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

/// [ecSampleBuses] as two PLCs, so the sample shows both levels of the tree.
List<EcPlc> ecSamplePlcs() {
  final buses = ecSampleBuses();
  return [
    EcPlc('PLC 1', [buses[0]]),
    EcPlc('PLC 2', [buses[1]]),
  ];
}

/// Configure form: the PLCs and their masters, and whether to open filtered.
class _EtherCatDeviceTableEditor extends StatefulWidget {
  const _EtherCatDeviceTableEditor({required this.config});

  final EtherCatDeviceTableConfig config;

  @override
  State<_EtherCatDeviceTableEditor> createState() =>
      _EtherCatDeviceTableEditorState();
}

class _EtherCatDeviceTableEditorState
    extends State<_EtherCatDeviceTableEditor> {
  List<EcPlcConfig> get _plcs => widget.config.plcs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'One entry per PLC, and in it one per EtherCAT master: the key of '
            'its ECT_Diag.Device_<n>_Diag array and of its '
            'ECT_Diag.Device_<n>_SlaveInfo array. The table lists them in '
            'this order; drag a handle to change it.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Leave the PLC name empty when there is only one; the table then '
            'lists masters only.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _reorderable(_plcs, _plcCard),
          OutlinedButton.icon(
            onPressed: () => setState(() => _plcs.add(EcPlcConfig(
                  label: 'PLC ${_plcs.length + 1}',
                  masters: [EcBusConfig(label: 'Device 1')],
                ))),
            icon: const Icon(Icons.add),
            label: const Text('Add PLC'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Open showing problems only'),
            value: widget.config.problemsOnly,
            onChanged: (v) => setState(() => widget.config.problemsOnly = v),
          ),
          const SizedBox(height: 16),
          // Every other asset's form carries these, and without them the only
          // way to change a table's box was the canvas's grow/shrink buttons,
          // ten percent a click and both sides at once.
          SizeField(
            initialValue: widget.config.size,
            onChanged: (s) => setState(() => widget.config.size = s),
          ),
          const SizedBox(height: 12),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            onChanged: (c) => setState(() => widget.config.coordinates = c),
          ),
        ],
      ),
    );
  }

  /// [items] as cards dragged into order by their handles, laid out in full
  /// inside the form's own scroll view — a station has a handful of each.
  ///
  /// Both levels use it, one inside the other. A handle drags within the
  /// nearest list above it, which is why a PLC's handle sits in its card's
  /// header, outside the list of its masters. Dragging a master into another
  /// PLC is the card's move menu, not a drag: two lists cannot hand an item
  /// between them.
  Widget _reorderable<T>(List<T> items, IndexedWidgetBuilder itemBuilder) =>
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        buildDefaultDragHandles: false,
        itemCount: items.length,
        // onReorder, not onReorderItem — see system_clock_section.dart.
        // ignore: deprecated_member_use
        onReorder: (oldIndex, newIndex) => setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          items.insert(newIndex, items.removeAt(oldIndex));
        }),
        itemBuilder: itemBuilder,
      );

  Widget _handle(int index) => ReorderableDragStartListener(
        index: index,
        child: const Padding(
          padding: EdgeInsets.only(right: 8),
          child: Tooltip(
            message: 'Drag to reorder',
            child: Icon(Icons.drag_indicator),
          ),
        ),
      );

  Widget _plcCard(BuildContext context, int i) {
    final plc = _plcs[i];
    return Card(
      key: ObjectKey(plc),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _handle(i),
                Expanded(
                  child: TextFormField(
                    initialValue: plc.label,
                    decoration: const InputDecoration(labelText: 'PLC'),
                    onChanged: (v) => plc.label = v,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove PLC',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _plcs.removeAt(i)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _reorderable(
              plc.masters,
              (context, j) => _masterCard(context, plc, j),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => plc.masters.add(
                    EcBusConfig(label: 'Device ${plc.masters.length + 1}'))),
                icon: const Icon(Icons.add),
                label: const Text('Add master'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _masterCard(BuildContext context, EcPlcConfig plc, int j) {
    final bus = plc.masters[j];
    final others = [
      for (final (k, p) in _plcs.indexed)
        if (!identical(p, plc)) (k, p),
    ];
    return Card.outlined(
      key: ObjectKey(bus),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                _handle(j),
                Expanded(
                  child: TextFormField(
                    initialValue: bus.label,
                    decoration: const InputDecoration(labelText: 'Master'),
                    onChanged: (v) => bus.label = v,
                  ),
                ),
                if (others.isNotEmpty)
                  PopupMenuButton<EcPlcConfig>(
                    tooltip: 'Move to another PLC',
                    icon: const Icon(Icons.drive_file_move_outline),
                    onSelected: (to) => setState(() {
                      plc.masters.remove(bus);
                      to.masters.add(bus);
                    }),
                    itemBuilder: (_) => [
                      for (final (k, p) in others)
                        PopupMenuItem(
                          value: p,
                          child: Text(
                              p.label.isEmpty ? 'PLC ${k + 1}' : p.label),
                        ),
                    ],
                  ),
                IconButton(
                  tooltip: 'Remove master',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => plc.masters.removeAt(j)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            KeyField(
              label: 'Diagnostics array key',
              initialValue: bus.diagKey,
              onChanged: (v) => bus.diagKey = v,
            ),
            const SizedBox(height: 8),
            KeyField(
              label: 'Subdevice info array key',
              initialValue: bus.infoKey,
              onChanged: (v) => bus.infoKey = v,
            ),
          ],
        ),
      ),
    );
  }
}
