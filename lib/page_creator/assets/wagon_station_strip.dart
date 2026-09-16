/// A pallet wagon's stations, drawn as one horizontal strip.
///
/// The mimic above answers "where is the wagon"; this answers "why is it
/// there, and what is it waiting for". One cell per commissioned station, in
/// rail order, each saying who it is, which way a pallet moves through it,
/// what it is doing right now, and where along the rail it stands — so the
/// strip can be dropped directly under a rails-mode conveyor and read as the
/// row of stations that conveyor's wagon runs between.
///
/// Reads the whole row off one key. See [WagonAsset] for why that matters.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541.dart' show DynamicValue;

import '../../providers/state_man.dart';
import '../../theme.dart' show HmiColorRole;
import 'common.dart';
import 'wagon_asset.dart';
import 'wagon_station.dart';

part 'wagon_station_strip.g.dart';

@JsonSerializable(explicitToJson: true)
class WagonStationStripConfig extends WagonAsset {
  @override
  String get displayName => 'Wagon Stations';

  @override
  String get category => 'Visualization';

  @override
  List<String> get searchKeywords => const [
        'wagon',
        'shuttle',
        'pallet',
        'station',
        'transfer',
        'rail',
        'strip',
        'interlock',
      ];

  /// Whether each cell prints its position along the rail.
  ///
  /// On by default: the figure is what ties a cell to the wagon drawn above
  /// it. Worth turning off on a narrow strip, where four lines of text in a
  /// 90 px cell is three too many.
  bool showPositions;

  WagonStationStripConfig({
    super.stationsKey,
    super.wagonStateKey,
    this.showPositions = true,
  }) {
    // A row of ten cells wants most of a page's width; the 3% default square
    // is a dot.
    size = const RelativeSize(width: 0.55, height: 0.16);
  }

  WagonStationStripConfig.preview() : this();

  factory WagonStationStripConfig.fromJson(Map<String, dynamic> json) =>
      _$WagonStationStripConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$WagonStationStripConfigToJson(this);

  /// The label sits in the strip's own header, so the canvas must not paint
  /// it a second time floating beside the box.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  bool get showLabel => false;

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        ...super.bulkProperties,
        BoolBulkProperty(
          id: 'WagonStationStripConfig.showPositions',
          label: 'Show positions',
          group: wagonBulkGroup,
          read: () => showPositions,
          apply: (value) => showPositions = value,
        ),
      ];

  @override
  Widget build(BuildContext context) => WagonStationStrip(config: this);

  @override
  Widget configure(BuildContext context) =>
      _WagonStationStripEditor(config: this);
}

/// Runtime widget: subscribes the array — and the state string when there is
/// one — and hands the decoded row to [WagonStationStripView].
class WagonStationStrip extends ConsumerWidget {
  const WagonStationStrip({super.key, required this.config});

  final WagonStationStripConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (config.stationsKey.isEmpty) {
      // Nothing bound yet — the palette tile, and an asset just dropped. A
      // sample says what the thing is for better than an empty box does.
      return WagonStationStripView(
        stations: sampleWagonStations(),
        title: config.text,
        wagonState: 'Sample',
        caption: 'Bind the station array in the editor',
        showPositions: config.showPositions,
      );
    }

    // Two nested `StreamBuilder`s over `keyStreamProvider`, rather than
    // subscriptions of our own. The provider shares one monitored item per
    // key however many widgets ask, replays the last value on a rebuild, and
    // disposes itself with the page — and it means this widget owns no
    // `StreamSubscription` to cancel, which is worth having: an awaited
    // `cancel()` in asset code silently stalls fake-async widget tests.
    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(config.stationsKey)),
      builder: (context, stations) {
        if (!config.hasWagonState) {
          return _view(stations, null);
        }
        return StreamBuilder<DynamicValue>(
          stream: ref.watch(keyStreamProvider(config.wagonStateKey!)),
          builder: (context, wagonState) => _view(stations, wagonState),
        );
      },
    );
  }

  Widget _view(
    AsyncSnapshot<DynamicValue> stations,
    AsyncSnapshot<DynamicValue>? wagonState,
  ) {
    // A key the PLC will not serve is already reported by StateMan, with the
    // node id and the server's own answer; repeating it per rebuild wrote a
    // line a frame while a window was being dragged.
    final row = stations.hasError || !stations.hasData
        ? const <WagonStation>[]
        : wagonStationsFromValue(stations.data);

    final String? caption;
    if (stations.hasError) {
      caption = 'Cannot read the station array';
    } else if (!stations.hasData) {
      caption = 'Waiting for data';
    } else if (row.isEmpty) {
      caption = 'No station in the array is enabled and named';
    } else {
      caption = null;
    }

    final state = wagonState != null && wagonState.hasData
        ? wagonState.data!.asString.trim()
        : null;

    return WagonStationStripView(
      stations: row,
      title: config.text,
      wagonState: state == null || state.isEmpty ? null : state,
      caption: caption,
      showPositions: config.showPositions,
    );
  }
}

/// The width the strip is laid out at before it is scaled into its box.
///
/// Only the width is a constant. The height is whatever the cells turn out to
/// need, which is the point: four lines of text are as tall as the theme's
/// text styles make them, and a guessed constant here is an overflow on the
/// first scheme that sets a different line height.
abstract final class _Strip {
  static const cellWidth = 120.0;
  static const cellGap = 4.0;
  static const padding = 6.0;
  static const headerHeight = 20.0;

  /// The narrowest a strip is ever laid out at, whatever it holds — an empty
  /// one still has to fit its caption.
  static const minWidth = 240.0;
}

/// The strip itself, fed values — so it can be goldened without a server.
class WagonStationStripView extends StatelessWidget {
  const WagonStationStripView({
    super.key,
    required this.stations,
    this.title,
    this.wagonState,
    this.caption,
    this.showPositions = true,
  });

  /// The commissioned stations, already filtered and in rail order — see
  /// [wagonStationsFromValue], which is the only thing that decides either.
  final List<WagonStation> stations;

  /// The asset's own label, drawn at the left of the header.
  final String? title;

  /// The wagon's state string, when the optional second key is bound.
  final String? wagonState;

  /// A word about why the strip is not showing stations.
  final String? caption;

  final bool showPositions;

  bool get _hasHeader =>
      (title ?? '').isNotEmpty || wagonState != null || caption != null;

  /// The width [_strip] is built at, before scaling.
  double get _designWidth => math.max(
        _Strip.minWidth,
        _Strip.padding * 2 +
            stations.length * _Strip.cellWidth +
            math.max(0, stations.length - 1) * _Strip.cellGap,
      );

  @override
  Widget build(BuildContext context) {
    // Laid out once at a fixed width and its own natural height, then scaled
    // into whatever box the page gives the asset. Two things follow from
    // that, and both are why it is done this way rather than by measuring the
    // box: the cells cannot overflow, because nothing ever hands them less
    // room than they asked for; and a strip is the same picture at every size
    // on the page, so ten of them at ten sizes still read alike.
    //
    // `BoxFit.contain` rather than `scaleDown`: an asset is sized by whoever
    // dropped it, and a strip that refused to grow into its own box would
    // sit in the top corner of it looking broken.
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topCenter,
      child: SizedBox(width: _designWidth, child: _strip(context)),
    );
  }

  Widget _strip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_Strip.padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_hasHeader) ...[
              SizedBox(height: _Strip.headerHeight, child: _header(context)),
              const SizedBox(height: _Strip.cellGap),
            ],
            if (stations.isNotEmpty)
              Row(
                // The cells are all the same height, so centring them is the
                // same as stretching — and stretch is illegal here, where the
                // row's own height is whatever its tallest cell needs.
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < stations.length; i++) ...[
                    if (i > 0) const SizedBox(width: _Strip.cellGap),
                    Expanded(
                      child: _WagonStationCell(
                        station: stations[i],
                        showPosition: showPositions,
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = (title ?? '').trim();
    return Row(
      children: [
        if (label.isNotEmpty) ...[
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        if (wagonState != null)
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                border:
                    Border.all(color: scheme.primary.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_shipping_outlined,
                      size: 11, color: scheme.primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      wagonState!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (caption != null)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                caption!,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The colour a state is drawn in, from the page's scheme rather than a baked
/// value — the HMI ships a light and a dark theme and two colour schemes, and
/// a literal never follows any of them.
///
/// Only [WagonStationState.blocked] gets a loud one. It is the single state
/// that means the wagon is stuck until somebody acts, and if everything on the
/// strip shouts then nothing does.
Color wagonStateColor(BuildContext context, WagonStationState state) =>
    (switch (state) {
      WagonStationState.blocked => HmiColorRole.red,
      WagonStationState.delivering => HmiColorRole.blue,
      WagonStationState.ready => HmiColorRole.green,
      WagonStationState.asking => HmiColorRole.yellow,
      WagonStationState.idle => HmiColorRole.grey,
    })
        .resolve(context);

class _WagonStationCell extends StatelessWidget {
  const _WagonStationCell({required this.station, required this.showPosition});

  final WagonStation station;
  final bool showPosition;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final here = station.atStation;
    final stateColor = wagonStateColor(context, station.state);

    return Tooltip(
      message: [
        '${station.name} (#${station.index})',
        '${station.role.label}, ${station.side.label}',
        station.state.label,
        station.positionLabel,
        if (here) 'The wagon is at this station',
      ].join('\n'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        decoration: BoxDecoration(
          color: here
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          border: Border.all(
            color: here ? scheme.primary : scheme.outlineVariant,
            width: here ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (here) ...[
                  // "The wagon is here" has to survive being scaled down to a
                  // thumbnail, so it is a shape and a border rather than a
                  // word somebody has to be able to read.
                  Icon(Icons.my_location, size: 11, color: scheme.primary),
                  const SizedBox(width: 3),
                ],
                Expanded(
                  child: Text(
                    station.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${station.role.shortLabel} · ${station.side.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: stateColor.withValues(alpha: 0.18),
                border: Border.all(color: stateColor),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                station.state.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: station.state == WagonStationState.blocked
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
            if (showPosition) ...[
              const SizedBox(height: 3),
              Text(
                station.positionLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WagonStationStripEditor extends StatefulWidget {
  const _WagonStationStripEditor({required this.config});

  final WagonStationStripConfig config;

  @override
  State<_WagonStationStripEditor> createState() =>
      _WagonStationStripEditorState();
}

class _WagonStationStripEditorState extends State<_WagonStationStripEditor> {
  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return SingleChildScrollView(
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'One key for the whole row: the wagon\'s '
              'ARRAY [1..10] OF ST_WagonStation. Stations that are not '
              'enabled, or have no name, are not drawn.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            KeyField(
              label: 'Station array',
              initialValue: config.stationsKey,
              onChanged: (value) =>
                  setState(() => config.stationsKey = value.trim()),
            ),
            const SizedBox(height: 16),
            KeyField(
              label: 'Wagon state (optional)',
              initialValue: config.wagonStateKey ?? '',
              onChanged: (value) => setState(
                  () => config.wagonStateKey = value.trim().isEmpty
                      ? null
                      : value.trim()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: config.text,
              decoration: const InputDecoration(labelText: 'Label'),
              onChanged: (value) => setState(() => config.text = value),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Text('Show positions')),
                Switch(
                  value: config.showPositions,
                  onChanged: (value) =>
                      setState(() => config.showPositions = value),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizeField(
              initialValue: config.size,
              onChanged: (value) => setState(() => config.size = value),
            ),
            const SizedBox(height: 16),
            CoordinatesField(
              initialValue: config.coordinates,
              onChanged: (value) => setState(() => config.coordinates = value),
            ),
          ],
        ),
      ),
    );
  }
}
