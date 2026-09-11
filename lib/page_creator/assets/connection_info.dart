// Connection Info asset.
//
// A compact status card that binds to the per-connection metadata a StateMan
// exposes as synthetic `@conn/<serverAlias>/<field>` meta-keys (see
// `packages/tfc_dart/lib/core/conn_meta.dart`). It picks one connection by
// its server alias and renders the applicable field set for the chosen
// protocol (common fields + that protocol's extras).
//
// Every meta-key value crosses as a scalar `DynamicValue`; the widget reads it
// through the type-safe `asString` / `asDouble` / `asInt` / `asBool` getters
// (which return a default rather than throwing), never `DynamicValue[]` (which
// throws on a missing member). A missing/unknown alias makes every `subscribe`
// error out — the card degrades to a "connection not found" state rather than
// an ErrorWidget.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'common.dart';
import '../../providers/state_man.dart';

part 'connection_info.g.dart';

/// Which protocol's field catalogue the card renders.
///
/// Decides the extra rows shown below the common fields and which meta-keys
/// are subscribed. Mirrors the split in `conn_meta.dart`
/// (`kConnMetaModbusOnlyFields` / `kConnMetaOpcuaOnlyFields`).
@JsonEnum()
enum ConnectionProtocol { modbus, opcua }

/// Configuration for a Connection Info asset.
///
/// Pure data model — JSON-serialisable, no widget wiring. Two payload fields
/// on top of the coordinates/size/label carried by [BaseAsset]:
///   * [serverAlias] — the connection to display. Blank renders the
///     "unconfigured" placeholder rather than binding anything.
///   * [protocol] — selects the extra field set (Modbus vs OPC-UA).
///
/// SERIALISATION SAFETY: `PageManager.load` wipes every page if any asset's
/// `fromJson` throws, so this factory must never throw on a partial map. Both
/// payload fields are optional constructor parameters with safe defaults
/// (missing `serverAlias` → `''`; missing/unknown `protocol` → `modbus`), and
/// [fromJson] back-fills the three [BaseAsset] keys the generated code casts
/// unconditionally (`asset_name` / `coordinates` / `size`) so even
/// `fromJson({})` yields a sensible default instead of crashing.
@JsonSerializable(explicitToJson: true)
class ConnectionInfoConfig extends BaseAsset {
  @override
  String get displayName => 'Connection Info';

  @override
  String get category => 'Diagnostics';

  /// The server alias whose connection metadata is displayed. Blank → the
  /// card shows an "unconfigured" placeholder and binds to nothing.
  String serverAlias;

  /// Which protocol's extra field set to render. Defaults to [modbus] so a
  /// legacy map without the key deserialises without throwing.
  @JsonKey(unknownEnumValue: ConnectionProtocol.modbus)
  ConnectionProtocol protocol;

  ConnectionInfoConfig({
    this.serverAlias = '',
    this.protocol = ConnectionProtocol.modbus,
  }) {
    // A status card needs more room than the 3%×3% BaseAsset default.
    size = const RelativeSize(width: 0.18, height: 0.16);
  }

  /// Preview factory for the asset palette.
  ConnectionInfoConfig.preview()
      : this(serverAlias: '', protocol: ConnectionProtocol.modbus);

  /// Back-fills the [BaseAsset] keys the generated `fromJson` reads
  /// unconditionally so a partial (or empty) map never throws.
  static Map<String, dynamic> _withDefaults(Map<String, dynamic> json) => {
        ...json,
        'asset_name': json['asset_name'] ?? 'ConnectionInfoConfig',
        'coordinates':
            json['coordinates'] ?? <String, dynamic>{'x': 0.0, 'y': 0.0},
        'size':
            json['size'] ?? <String, dynamic>{'width': 0.18, 'height': 0.16},
      };

  factory ConnectionInfoConfig.fromJson(Map<String, dynamic> json) =>
      _$ConnectionInfoConfigFromJson(_withDefaults(json));

  @override
  Map<String, dynamic> toJson() => _$ConnectionInfoConfigToJson(this);

  @override
  Widget build(BuildContext context) => ConnectionInfoCard(config: this);

  @override
  Widget configure(BuildContext context) =>
      _ConnectionInfoConfigEditor(config: this);
}

// ---------------------------------------------------------------------------
// State visual — pure mapping from raw fields to (colour, label).
// ---------------------------------------------------------------------------

/// The colour + label the state chip shows, resolved from the raw meta-fields.
///
/// Pure value type so the mapping is unit-testable without a live StateMan.
@immutable
class ConnectionStateVisual {
  final Color color;
  final String label;
  const ConnectionStateVisual(this.color, this.label);

  /// Priority: connected → green, connecting → amber, error → red, else grey.
  ///
  /// An error is inferred from a non-empty [lastError]; a plain disconnected
  /// connection with no error string stays grey.
  factory ConnectionStateVisual.resolve({
    required bool connected,
    required String state,
    required String lastError,
  }) {
    if (connected)
      return const ConnectionStateVisual(Colors.green, 'Connected');
    if (state.toLowerCase() == 'connecting') {
      return const ConnectionStateVisual(Colors.amber, 'Connecting');
    }
    if (lastError.trim().isNotEmpty) {
      return const ConnectionStateVisual(Colors.red, 'Error');
    }
    return const ConnectionStateVisual(Colors.grey, 'Disconnected');
  }
}

// ---------------------------------------------------------------------------
// Formatters — pure, so they are tested directly.
// ---------------------------------------------------------------------------

/// `12.34` → `"12.3 req/s"`.
String formatRequestsPerSec(double v) => '${v.toStringAsFixed(1)} req/s';

/// Seconds → `h:mm:ss` (e.g. `3725.0` → `"1:02:05"`).
String formatUptime(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// `1.5` → `"1.5 s"`.
String formatAgeSec(double v) => '${v.toStringAsFixed(1)} s';

// ---------------------------------------------------------------------------
// Widget — runtime entry point.
// ---------------------------------------------------------------------------

/// Live status card driven by the `@conn/<alias>/<field>` meta-keys.
///
/// The combined stream is hoisted in `initState` (and re-hoisted only when the
/// alias or protocol changes) so high-frequency rebuilds never trigger a
/// resubscribe storm — the same Pitfall-2 invariant `Sensor` observes.
class ConnectionInfoCard extends ConsumerStatefulWidget {
  final ConnectionInfoConfig config;
  const ConnectionInfoCard({super.key, required this.config});

  @override
  ConsumerState<ConnectionInfoCard> createState() => _ConnectionInfoCardState();
}

class _ConnectionInfoCardState extends ConsumerState<ConnectionInfoCard> {
  /// `field → DynamicValue` for the whole valid field set. `null` when the
  /// alias is blank (nothing to subscribe to).
  Stream<Map<String, DynamicValue>>? _stream;

  /// The `(alias, protocol)` the current stream was built for — compared in
  /// `didUpdateWidget` so an in-place config mutation still re-hoists.
  String? _hoistedKey;

  @override
  void initState() {
    super.initState();
    _hoist();
  }

  @override
  void didUpdateWidget(covariant ConnectionInfoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_hoistedKey != _keyFor(widget.config)) _hoist();
  }

  String _keyFor(ConnectionInfoConfig c) =>
      '${c.serverAlias}|${c.protocol.name}';

  void _hoist() {
    final config = widget.config;
    _hoistedKey = _keyFor(config);
    final alias = config.serverAlias.trim();
    if (alias.isEmpty) {
      _stream = null;
      return;
    }
    // One subscription for the whole card: a single timer and one snapshot
    // per tick, instead of a per-field subscription each running its own.
    // An unknown alias throws inside switchMap, which surfaces as a stream
    // error → "Connection not found".
    _stream = ref
        .read(stateManProvider.future)
        .asStream()
        .switchMap((sm) => sm.subscribeConnMeta(alias));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.config.serverAlias.trim().isEmpty) {
      return _CardFrame(
        title: 'Connection Info',
        child: _PlaceholderBody(
          icon: Icons.settings_ethernet,
          message: 'No connection selected',
        ),
      );
    }

    return StreamBuilder<Map<String, DynamicValue>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _CardFrame(
            title: widget.config.serverAlias,
            child: const _PlaceholderBody(
              icon: Icons.link_off,
              message: 'Connection not found',
            ),
          );
        }
        if (!snapshot.hasData) {
          return _CardFrame(
            title: widget.config.serverAlias,
            child: const _PlaceholderBody(
              icon: Icons.hourglass_empty,
              message: 'Connecting…',
            ),
          );
        }
        return _CardFrame(
          title: widget.config.serverAlias,
          headerTrailing: _stateChip(snapshot.data!),
          child: _body(snapshot.data!),
        );
      },
    );
  }

  // --- Safe field access ---------------------------------------------------
  String _s(Map<String, DynamicValue> m, String f) =>
      m.containsKey(f) ? m[f]!.asString : '';
  double _d(Map<String, DynamicValue> m, String f) =>
      m.containsKey(f) ? m[f]!.asDouble : 0;
  int _i(Map<String, DynamicValue> m, String f) =>
      m.containsKey(f) ? m[f]!.asInt : 0;
  bool _b(Map<String, DynamicValue> m, String f) =>
      m.containsKey(f) ? m[f]!.asBool : false;

  Widget _stateChip(Map<String, DynamicValue> m) {
    final visual = ConnectionStateVisual.resolve(
      connected: _b(m, 'connected'),
      state: _s(m, 'state'),
      lastError: _s(m, 'lastError'),
    );
    return Container(
      key: const ValueKey('connection-info-state-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: visual.color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        visual.label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _body(Map<String, DynamicValue> m) {
    // The protocol comes from the data, not the operator's dropdown — a
    // mis-set dropdown must not break a resolvable connection.
    final isModbus = m.containsKey('unitId');
    final lastError = _s(m, 'lastError');

    final rows = <Widget>[
      _Row(
          label: 'Requests',
          value: formatRequestsPerSec(_d(m, 'requestsPerSec'))),
      _Row(
          label: 'Destination',
          value: '${_s(m, 'destIp')}:${_i(m, 'destPort')}'),
      _Row(label: 'Uptime', value: formatUptime(_d(m, 'uptimeSec'))),
      _Row(label: 'Reconnects', value: '${_i(m, 'reconnectCount')}'),
      if (isModbus) ...[
        _Row(label: 'Unit ID', value: '${_i(m, 'unitId')}'),
        _Row(label: 'Source port', value: '${_i(m, 'sourcePort')}'),
        _Row(label: 'Poll interval', value: '${_i(m, 'pollIntervalMs')} ms'),
      ] else ...[
        _Row(label: 'Endpoint', value: _s(m, 'endpoint')),
        _Row(label: 'Channel', value: _s(m, 'channelState')),
        _Row(label: 'Session', value: _s(m, 'sessionState')),
        _Row(label: 'Subscribed', value: '${_i(m, 'subscribedKeys')}'),
        _Row(label: 'Data age', value: formatAgeSec(_d(m, 'lastDataAgeSec'))),
      ],
      if (lastError.trim().isNotEmpty)
        _Row(label: 'Error', value: lastError, valueColor: Colors.red),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

/// A card shell that scales its fixed-width content down to the asset box, so
/// the same internal layout reads at any placed size.
class _CardFrame extends StatelessWidget {
  final String title;
  final Widget? headerTrailing;
  final Widget child;
  const _CardFrame({
    required this.title,
    required this.child,
    this.headerTrailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: 240,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lan, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (headerTrailing != null) headerTrailing!,
                  ],
                ),
                const Divider(height: 12),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaceholderBody extends StatelessWidget {
  final IconData icon;
  final String message;
  const _PlaceholderBody({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _Row({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: valueColor,
                fontWeight:
                    valueColor != null ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Config editor — the body of the configure side pane.
// ---------------------------------------------------------------------------

/// Editor body for [ConnectionInfoConfig].
///
/// All edits mutate the live `widget.config` instance and call `setState`, so
/// the page editor picks the change up and re-renders the canvas preview (the
/// stateless-pane-mutates-without-setState bug does not apply here).
///
/// The alias field is a free-text box (the source of truth) plus a row of
/// suggestion chips loaded from `StateManConfig.fromPrefs` — tapping a chip
/// fills the alias AND sets the matching protocol.
class _ConnectionInfoConfigEditor extends ConsumerStatefulWidget {
  final ConnectionInfoConfig config;
  const _ConnectionInfoConfigEditor({required this.config});

  @override
  ConsumerState<_ConnectionInfoConfigEditor> createState() =>
      _ConnectionInfoConfigEditorState();
}

class _ServerSuggestion {
  final String alias;
  final ConnectionProtocol protocol;
  const _ServerSuggestion(this.alias, this.protocol);
}

class _ConnectionInfoConfigEditorState
    extends ConsumerState<_ConnectionInfoConfigEditor> {
  late TextEditingController _aliasController;
  List<_ServerSuggestion> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _aliasController = TextEditingController(text: widget.config.serverAlias);
    _loadSuggestions();
  }

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    try {
      // Ask the live router rather than re-deriving aliases from the raw
      // config: these are exactly the identities `@conn` keys resolve to
      // (unnamed servers appear under their synthetic host:port identity),
      // so every chip offered here is guaranteed to bind.
      final sm = await ref.read(stateManProvider.future);
      final out = <_ServerSuggestion>[
        for (final a in sm.connMetaAliases)
          _ServerSuggestion(
              a.alias,
              a.isModbus
                  ? ConnectionProtocol.modbus
                  : ConnectionProtocol.opcua),
      ];
      if (mounted) setState(() => _suggestions = out);
    } catch (_) {
      // Suggestions are a convenience; the text field still works without them.
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return Container(
      width: 360,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connection', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),

            // -- Server alias (source of truth) --
            TextField(
              controller: _aliasController,
              decoration: const InputDecoration(
                labelText: 'Server alias',
                hintText: 'e.g. plc1',
              ),
              onChanged: (v) => setState(() => config.serverAlias = v),
            ),
            const SizedBox(height: 8),

            // -- Suggestion chips from the configured servers --
            if (_suggestions.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _suggestions.map((s) {
                  return ActionChip(
                    label: Text('${s.alias} (${s.protocol.name})'),
                    onPressed: () {
                      setState(() {
                        config.serverAlias = s.alias;
                        config.protocol = s.protocol;
                        _aliasController.text = s.alias;
                      });
                    },
                  );
                }).toList(),
              ),
            const SizedBox(height: 16),

            // -- Protocol --
            Text('Protocol', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            SegmentedButton<ConnectionProtocol>(
              segments: const [
                ButtonSegment(
                    value: ConnectionProtocol.modbus, label: Text('Modbus')),
                ButtonSegment(
                    value: ConnectionProtocol.opcua, label: Text('OPC-UA')),
              ],
              selected: {config.protocol},
              onSelectionChanged: (sel) =>
                  setState(() => config.protocol = sel.first),
            ),
            const SizedBox(height: 16),

            // -- Size --
            SizeField(
              initialValue: config.size,
              onChanged: (v) => setState(() => config.size = v),
            ),
            const SizedBox(height: 16),

            // -- Coordinates --
            CoordinatesField(
              initialValue: config.coordinates,
              onChanged: (c) => setState(() => config.coordinates = c),
              enableAngle: true,
            ),
          ],
        ),
      ),
    );
  }
}
