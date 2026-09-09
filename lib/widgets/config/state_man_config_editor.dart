/// The ONE `StateManConfig` editor, over the ONE document.
///
/// Extracted from `lib/pages/server_config.dart`
/// (quick/20260908-unify-config-ui phase 2): the OPC UA / JBTM / Modbus
/// sections and their cards, re-parented onto a single [ConfigDocument]
/// read from and written to a [ConfigSource]. The transport decides WHERE
/// the document lives and nothing else — direct mode hands this widget a
/// `LocalPrefsConfigSource`, gateway mode (phase 3) a `GatewayConfigSource`
/// — so the plant backend gets the same typed form this station gets,
/// because it is the same data.
///
/// This also retires a latent bug the old page carried: each of the three
/// sections held its own full `StateManConfig` copy and saved the WHOLE
/// document, so section B's save clobbered section A's unsaved edits with
/// A's load-time state. One document, one dirty flag, one save button.
///
/// The save button is the page's ONE unsaved indicator — the per-section
/// "Unsaved Changes" pills are deliberately gone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:modbus_client/modbus_client.dart' show ModbusEndianness;
import 'package:tfc_dart/core/config_document.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../core/config_source.dart';
import '../../providers/state_man.dart';
import '../connection_status_chip.dart';
import '../duration_field.dart';
import '../panes/standard_dialog.dart';

/// The placeholder byte string legacy configs carry where a certificate or
/// key was never provided. Shared with the page's import/export card.
const kCertPlaceholder = "todo";

// The editor-owned affordance keys (phase 3 of quick/20260908-unify-config-ui).
// The gateway page passes its own 17-13 spellings (`kBackendConfig*`) for the
// affordances its suites already find; these are the defaults everywhere else.

/// The honest-absence line: rendered when the source has no live per-server
/// status (`hasLiveStatus == false`), INSTEAD of a grey chip that could be
/// mistaken for "not connected".
const Key kConfigStatusAbsenceKey = Key('config_status_absence');

// The "Advanced — edit as JSON" expansion is gone, by the owner's ruling, and
// so is the read-only card that printed a section's JSON into a disabled
// field. Both were JSON on a screen for people who do not read JSON. Neither
// removal loses a byte: `ConfigDocument` still carries every section and every
// unknown key it did not model — including `relay` — verbatim through an edit
// and back out of `encode()`, which is a property `config_document_test.dart`
// holds with a seeded round-trip. What is lost is the ability to EDIT a
// section this build has no form for; the recovery editor below still repairs
// a document that will not decode, and anything else is a backend-side edit,
// which is where `relay` always had to be changed anyway (D-10).

/// The raw text field of the recovery face — the stored document, shown
/// whole when it will not decode.
const Key kConfigRawRecoveryFieldKey = Key('config_raw_recovery_field');

/// The button that re-parses the recovery text into a fresh document.
const Key kConfigRawRecoveryApplyKey = Key('config_raw_recovery_apply');

/// Default keys for the affordances a host page may re-key.
const Key kConfigEditorRefusalKey = Key('config_editor_refusal');
const Key kConfigEditorRestoreKey = Key('config_editor_restore');
const Key kConfigEditorApplyNoteKey = Key('config_editor_apply_note');

// ===================== Certificate Generator (unchanged) =====================
class CertificateGenerator extends StatefulWidget {
  final Function(Uint8List?, Uint8List?) onCertificatesGenerated;

  const CertificateGenerator({
    super.key,
    required this.onCertificatesGenerated,
  });

  @override
  State<CertificateGenerator> createState() => _CertificateGeneratorState();
}

class _CertificateGeneratorState extends State<CertificateGenerator> {
  bool _isGenerating = false;
  String? _error;
  late TextEditingController _commonNameController;
  late TextEditingController _organizationController;
  late TextEditingController _validityDaysController;
  late TextEditingController _countryController;
  late TextEditingController _stateController;
  late TextEditingController _localityController;
  Uint8List? _cert;
  Uint8List? _key;

  @override
  void initState() {
    super.initState();

    // Initialize controllers with locale-aware defaults
    _initializeControllers();
  }

  void _initializeControllers() {
    final locale = Platform.localeName;
    final countryCode = locale.split('_').last;

    _commonNameController = TextEditingController(text: 'example.com');
    _organizationController =
        TextEditingController(text: 'Your company/organization name');
    _validityDaysController = TextEditingController(text: '365');
    _countryController = TextEditingController(text: countryCode);
    _stateController =
        TextEditingController(text: _getDefaultState(countryCode));
    _localityController =
        TextEditingController(text: _getDefaultLocality(countryCode));
  }

  String _getDefaultState(String countryCode) {
    // Provide default state/province based on country
    const stateMap = {
      'US': 'State',
      'CA': 'Province',
      'GB': 'England',
      'DE': 'Bundesland',
      'FR': 'Région',
      'IT': 'Regione',
      'ES': 'Comunidad',
      'NL': 'Provincie',
      'AU': 'State',
      'BR': 'Estado',
      'MX': 'Estado',
      'IS': 'Region',
    };
    return stateMap[countryCode] ?? 'State';
  }

  String _getDefaultLocality(String countryCode) {
    // Provide default city based on country
    const localityMap = {
      'US': 'City',
      'CA': 'City',
      'GB': 'London',
      'DE': 'Berlin',
      'FR': 'Paris',
      'IT': 'Rome',
      'ES': 'Madrid',
      'NL': 'Amsterdam',
      'AU': 'Sydney',
      'BR': 'São Paulo',
      'MX': 'Mexico City',
      'IS': 'Reykjavik',
    };
    return localityMap[countryCode] ?? 'City';
  }

  @override
  void dispose() {
    _commonNameController.dispose();
    _organizationController.dispose();
    _validityDaysController.dispose();
    _countryController.dispose();
    _stateController.dispose();
    _localityController.dispose();
    super.dispose();
  }

  Future<void> _generateCertificates() async {
    setState(() {
      _isGenerating = true;
      _error = null;
    });

    try {
      final commonName = _commonNameController.text.trim();
      final organization = _organizationController.text.trim();
      final validityDays = int.tryParse(_validityDaysController.text) ?? 365;
      final country = _countryController.text.trim();
      final state = _stateController.text.trim();
      final locality = _localityController.text.trim();

      if (commonName.isEmpty) {
        throw Exception('Common Name is required');
      }

      // Generate RSA key pair
      final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);

      // Create certificate signing request with locale-aware attributes
      final attributes = {
        'CN': commonName,
        'O': organization,
        'OU': 'OPC-UA',
        'C': country,
        'ST': state,
        'L': locality,
      };

      final csr = X509Utils.generateRsaCsrPem(
        attributes,
        keyPair.privateKey as RSAPrivateKey,
        keyPair.publicKey as RSAPublicKey,
        san: ['localhost', '127.0.0.1'],
      );

      // Generate self-signed certificate
      final certPem = X509Utils.generateSelfSignedCertificate(
        keyPair.privateKey as RSAPrivateKey,
        csr,
        validityDays,
        sans: ['localhost', '127.0.0.1'],
      );

      Uint8List certFile = utf8.encode(certPem);
      Uint8List keyString = utf8.encode(CryptoUtils.encodeRSAPrivateKeyToPem(
          keyPair.privateKey as RSAPrivateKey));

      setState(() {
        _cert = certFile;
        _key = keyString;
      });
      widget.onCertificatesGenerated(certFile, keyString);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Certificates generated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _isGenerating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Certificate generation form
          TextField(
            controller: _commonNameController,
            decoration: const InputDecoration(
              labelText: 'Common Name (CN)',
              hintText: 'example.com',
              prefixIcon: FaIcon(FontAwesomeIcons.server, size: 16),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _organizationController,
            decoration: const InputDecoration(
              labelText: 'Organization',
              hintText: 'Your company/organization name',
              prefixIcon: FaIcon(FontAwesomeIcons.building, size: 16),
            ),
          ),
          const SizedBox(height: 12),

          // Location fields
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 400;
              if (isNarrow) {
                return Column(
                  children: [
                    TextField(
                      controller: _countryController,
                      decoration: const InputDecoration(
                        labelText: 'Country (C)',
                        hintText: 'US/UK/DE/FR/IT/ES/NL/AU/BR/MX/IS',
                        prefixIcon: FaIcon(FontAwesomeIcons.flag, size: 16),
                      ),
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(2),
                        UpperCaseTextFormatter(),
                      ],
                      textCapitalization: TextCapitalization.characters,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _stateController,
                      decoration: const InputDecoration(
                        labelText: 'State/Province (ST)',
                        hintText: 'State',
                        prefixIcon: FaIcon(FontAwesomeIcons.map, size: 16),
                      ),
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _countryController,
                      decoration: const InputDecoration(
                        labelText: 'Country (C)',
                        hintText: 'US/UK/DE/FR/IT/ES/NL/AU/BR/MX/IS',
                        prefixIcon: FaIcon(FontAwesomeIcons.flag, size: 16),
                      ),
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(2),
                        UpperCaseTextFormatter(),
                      ],
                      textCapitalization: TextCapitalization.characters,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _stateController,
                      decoration: const InputDecoration(
                        labelText: 'State/Province (ST)',
                        hintText: 'State',
                        prefixIcon: FaIcon(FontAwesomeIcons.map, size: 16),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _localityController,
            decoration: const InputDecoration(
              labelText: 'Locality/City (L)',
              hintText: 'City',
              prefixIcon: FaIcon(FontAwesomeIcons.city, size: 16),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _validityDaysController,
            decoration: const InputDecoration(
              labelText: 'Validity (days)',
              hintText: '365',
              prefixIcon: FaIcon(FontAwesomeIcons.calendar, size: 16),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),

          // Error display
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.error),
              ),
              child: Row(
                children: [
                  FaIcon(FontAwesomeIcons.triangleExclamation,
                      color: Theme.of(context).colorScheme.error, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Certificate status
          if (_cert != null && _key != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const FaIcon(FontAwesomeIcons.circleCheck,
                          color: Colors.green, size: 16),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Certificates generated successfully!',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isGenerating ? null : _generateCertificates,
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const FaIcon(FontAwesomeIcons.plus, size: 16),
                  label: Text(_isGenerating
                      ? 'Generating...'
                      : 'Generate Certificates'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Moves the item at [oldIndex] to [newIndex] in [list], using the index
/// convention [ReorderableListView] hands to `onReorder`: [newIndex] is the
/// slot the item was dropped into *before* it is lifted out of its old
/// position, so a downwards move has to be decremented by one to land where
/// the operator actually let go.
///
/// Indices outside the list are clamped rather than thrown — a stray drag
/// must never corrupt a saved server configuration. Returns true when [list]
/// actually changed, so callers can skip a needless `setState`.
bool moveInList<T>(List<T> list, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= list.length) return false;
  var target = newIndex;
  if (target > oldIndex) target -= 1;
  if (target < 0) target = 0;
  if (target > list.length - 1) target = list.length - 1;
  if (target == oldIndex) return false;
  list.insert(target, list.removeAt(oldIndex));
  return true;
}

/// Hands out a stable widget key per row of a reorderable server list.
///
/// The server cards are stateful: they seed their [TextEditingController]s
/// from the server in `initState` and never re-read it. Left unkeyed, Flutter
/// matches cards to *positions*, so right after a drag the card sitting in
/// slot 0 would still be showing slot 0's old endpoint while being handed a
/// different server — and the next keystroke would write that stale text back
/// into the config. Each row instead gets an opaque id that travels with its
/// server through add, remove and reorder, so card state follows the server
/// rather than the slot.
class _RowKeys {
  int _nextId = 0;
  final List<int> _ids = [];

  /// Re-seeds identities for a freshly loaded list of [length] servers.
  void reset(int length) {
    _ids
      ..clear()
      ..addAll(List<int>.generate(length, (_) => _nextId++));
  }

  void add() => _ids.add(_nextId++);

  void removeAt(int index) {
    if (index >= 0 && index < _ids.length) _ids.removeAt(index);
  }

  void reorder(int oldIndex, int newIndex) =>
      moveInList(_ids, oldIndex, newIndex);

  /// Falls back to a positional key should identities ever drift out of step
  /// with the config — a missing or duplicated key crashes the list, and a
  /// mismatched card is a far cheaper failure than a red screen.
  Key operator [](int index) => ValueKey<String>(
      index < _ids.length ? 'server-${_ids[index]}' : 'server-slot-$index');
}

/// Leading slot for a server card: the card's own protocol [icon], preceded by
/// a grab handle when the card sits in a reorderable list.
///
/// The handle is an explicit [ReorderableDragStartListener] rather than the
/// list's default long-press handles — the cards are full of text fields and
/// buttons, and a long press anywhere on one picking the whole card up is not
/// what an operator editing an endpoint expects.
class _ServerCardLeading extends StatelessWidget {
  /// Index of the card in its [ReorderableListView], or null when the list is
  /// not reorderable (a single server) — then only [icon] is shown.
  final int? reorderIndex;
  final Widget icon;

  const _ServerCardLeading({required this.reorderIndex, required this.icon});

  @override
  Widget build(BuildContext context) {
    if (reorderIndex == null) return icon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReorderableDragStartListener(
          index: reorderIndex!,
          child: const MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.0),
              child: Icon(
                Icons.drag_indicator,
                size: 20,
                color: Colors.grey,
                semanticLabel: 'Drag to reorder',
              ),
            ),
          ),
        ),
        icon,
      ],
    );
  }
}

class _EmptyServersPlaceholder extends StatelessWidget {
  final FaIconData icon;
  final String title;
  final String subtitle;

  const _EmptyServersPlaceholder({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FaIcon(icon, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.grey)),
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

/// Section header with icon, title, and add button.
///
/// Used by OPC UA, JBTM, and Modbus server config sections to show
/// a responsive header row that collapses on narrow screens.
///
/// Deliberately carries NO unsaved marker: the whole editor holds one
/// document and one dirty flag, and the save button at the bottom is the
/// one place that says so.
class _ServerSectionHeader extends StatelessWidget {
  final String title;
  final FaIconData icon;
  final VoidCallback onAdd;

  const _ServerSectionHeader({
    required this.title,
    required this.icon,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 500;
        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  FaIcon(icon, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: onAdd,
                icon: const FaIcon(FontAwesomeIcons.plus, size: 16),
                label: const Text('Add Server'),
              ),
            ],
          );
        }
        return Row(
          children: [
            FaIcon(icon, size: 20),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const FaIcon(FontAwesomeIcons.plus, size: 16),
              label: const Text('Add Server'),
            ),
          ],
        );
      },
    );
  }
}

/// Compact enable/disable checkbox shown in a server card's header.
///
/// Disabling a server is the operator's escape hatch for a PLC that is off
/// the network: [StateMan] then never creates a client for it, so the
/// connect/reconnect loop and the per-key subscription retries — the two
/// things that flood the log with a machine down — never start. Keys that
/// point at the server fail fast with a `ServerDisabledException` instead.
class _ServerEnabledToggle extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ServerEnabledToggle({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled
          ? 'Server is enabled — untick to disable it and stop all\n'
              'connection attempts and key traffic for it.'
          : 'Server is disabled — tick to enable it again.',
      child: Checkbox(
        value: enabled,
        onChanged: (value) => onChanged(value ?? false),
      ),
    );
  }
}

/// Save/saved-state button for server config sections.
///
/// Shows "Save Configuration" (enabled, themed) when there are unsaved changes,
/// or "All Changes Saved" (disabled, grey) when config matches saved state.
class _SaveConfigButton extends StatelessWidget {
  final bool hasUnsavedChanges;
  final VoidCallback onSave;

  /// The button's own key, so a host page can pin its existing spelling on
  /// it (gateway mode passes `kBackendConfigSaveKey`).
  final Key? buttonKey;

  const _SaveConfigButton({
    required this.hasUnsavedChanges,
    required this.onSave,
    this.buttonKey,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            key: buttonKey,
            onPressed: hasUnsavedChanges ? onSave : null,
            icon: FaIcon(FontAwesomeIcons.floppyDisk,
                size: 16, color: hasUnsavedChanges ? null : Colors.grey),
            label: Text(
                hasUnsavedChanges ? 'Save Configuration' : 'All Changes Saved'),
            style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: hasUnsavedChanges ? null : Colors.grey),
          ),
        ),
      ],
    );
  }
}

// ===================== JBTM Server Config Card =====================

class _JbtmServerConfigCard extends StatefulWidget {
  final M2400Config server;
  final Function(M2400Config) onUpdate;
  final VoidCallback onRemove;
  final ConnectionStatus? connectionStatus;
  final Stream<ConnectionStatus>? connectionStream;
  final bool stateManLoading;

  /// See [_ServerConfigCard.reorderIndex].
  final int? reorderIndex;

  /// See [_ServerConfigCard.liveStatusKnown].
  final bool liveStatusKnown;

  const _JbtmServerConfigCard({
    super.key,
    required this.server,
    required this.onUpdate,
    required this.onRemove,
    this.connectionStatus,
    this.connectionStream,
    this.stateManLoading = false,
    this.reorderIndex,
    this.liveStatusKnown = true,
  });

  @override
  State<_JbtmServerConfigCard> createState() => _JbtmServerConfigCardState();
}

class _JbtmServerConfigCardState extends State<_JbtmServerConfigCard> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _aliasController;
  ConnectionStatus? _connectionStatus;
  StreamSubscription<ConnectionStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.server.host);
    _portController =
        TextEditingController(text: widget.server.port.toString());
    _aliasController =
        TextEditingController(text: widget.server.serverAlias ?? '');
    _connectionStatus = widget.connectionStatus;
    _subscribeToStatus();
  }

  @override
  void didUpdateWidget(covariant _JbtmServerConfigCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connectionStream != oldWidget.connectionStream) {
      _connectionStatus = widget.connectionStatus;
      _subscribeToStatus();
    }
  }

  void _subscribeToStatus() {
    _statusSub?.cancel();
    _statusSub = widget.connectionStream?.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  void _updateServer({bool? enabled}) {
    final updated = M2400Config(
      host: _hostController.text,
      port: int.tryParse(_portController.text) ?? 52211,
      enabled: enabled ?? widget.server.enabled,
    )..serverAlias =
        _aliasController.text.isEmpty ? null : _aliasController.text;
    widget.onUpdate(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: _ServerCardLeading(
          reorderIndex: widget.reorderIndex,
          icon: const FaIcon(FontAwesomeIcons.scaleBalanced, size: 20),
        ),
        title: Text(
          widget.server.serverAlias ??
              '${widget.server.host}:${widget.server.port}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: widget.server.enabled ? null : Colors.grey,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        subtitle: Text(
          '${widget.server.host}:${widget.server.port}',
          style: TextStyle(color: Colors.grey[600]),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Honest absence (phase 3): where live status cannot be known
            // (gateway mode — the backend's client health is not on the
            // wire), no chip renders at all rather than a grey "Not active"
            // that reads as "not connected". A disabled server is a config
            // fact, knowable on any transport, so its chip stays.
            if (widget.liveStatusKnown || !widget.server.enabled) ...[
              ConnectionStatusChip(
                status: _connectionStatus,
                stateManLoading: widget.stateManLoading,
                disabled: !widget.server.enabled,
              ),
              const SizedBox(width: 4),
            ],
            _ServerEnabledToggle(
              enabled: widget.server.enabled,
              onChanged: (value) => _updateServer(enabled: value),
            ),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.trash, size: 16),
              onPressed: () {
                showConfirmDialog(
                  context: context,
                  title: 'Remove server',
                  message: 'Are you sure you want to remove this JBTM server?',
                  confirmLabel: 'Remove',
                  destructive: true,
                ).then((confirmed) {
                  if (confirmed) widget.onRemove();
                });
              },
            ),
            const SizedBox(width: 8),
            const FaIcon(FontAwesomeIcons.chevronDown, size: 16),
          ],
        ),
        onExpansionChanged: (expanded) => setState(() {}),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 400;
                    if (isNarrow) {
                      return Column(
                        children: [
                          TextField(
                            controller: _hostController,
                            decoration: const InputDecoration(
                              labelText: 'Host',
                              hintText: 'localhost',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.server, size: 16),
                            ),
                            onChanged: (_) => _updateServer(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _portController,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              hintText: '52211',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.hashtag, size: 16),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (_) => _updateServer(),
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _hostController,
                            decoration: const InputDecoration(
                              labelText: 'Host',
                              hintText: 'localhost',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.server, size: 16),
                            ),
                            onChanged: (_) => _updateServer(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 1,
                          child: TextField(
                            controller: _portController,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              hintText: '52211',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.hashtag, size: 16),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (_) => _updateServer(),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _aliasController,
                  decoration: const InputDecoration(
                    labelText: 'Server Alias (optional)',
                    hintText: 'My M2400 Scale',
                    prefixIcon: FaIcon(FontAwesomeIcons.tag, size: 16),
                  ),
                  onChanged: (_) => _updateServer(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== Modbus Server Config Card =====================

class _ModbusServerConfigCard extends StatefulWidget {
  final ModbusConfig server;
  final Function(ModbusConfig) onUpdate;
  final VoidCallback onRemove;
  final ConnectionStatus? connectionStatus;
  final Stream<ConnectionStatus>? connectionStream;
  // TD-004 (v1.1.x): combined TCP + UMAS health. Optional — when null
  // the chip falls back to pure TCP. Modbus cards backed by a
  // ModbusDeviceClientAdapter with `umasEnabled == true` should
  // always supply both so the chip can surface a broken UMAS session
  // as `umasUnhealthy` instead of falsely showing green.
  final EffectiveDeviceStatus? effectiveStatus;
  final Stream<EffectiveDeviceStatus>? effectiveStatusStream;
  final bool stateManLoading;

  /// See [_ServerConfigCard.reorderIndex].
  final int? reorderIndex;

  /// See [_ServerConfigCard.liveStatusKnown].
  final bool liveStatusKnown;

  const _ModbusServerConfigCard({
    super.key,
    required this.server,
    required this.onUpdate,
    required this.onRemove,
    this.connectionStatus,
    this.connectionStream,
    this.effectiveStatus,
    this.effectiveStatusStream,
    this.stateManLoading = false,
    this.reorderIndex,
    this.liveStatusKnown = true,
  });

  @override
  State<_ModbusServerConfigCard> createState() =>
      _ModbusServerConfigCardState();
}

class _ModbusServerConfigCardState extends State<_ModbusServerConfigCard> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _unitIdController;
  late TextEditingController _aliasController;
  List<TextEditingController> _pollGroupNameControllers = [];
  ConnectionStatus? _connectionStatus;
  StreamSubscription<ConnectionStatus>? _statusSub;
  // TD-004 (v1.1.x): mirror the TCP-status subscription pattern for
  // the derived UMAS-aware effective status.
  EffectiveDeviceStatus? _effectiveStatus;
  StreamSubscription<EffectiveDeviceStatus>? _effectiveStatusSub;
  late bool _umasEnabled;
  late ModbusEndianness _endianness;
  late int _addressBase;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.server.host);
    _portController =
        TextEditingController(text: widget.server.port.toString());
    _unitIdController =
        TextEditingController(text: widget.server.unitId.toString());
    _aliasController =
        TextEditingController(text: widget.server.serverAlias ?? '');
    _umasEnabled = widget.server.umasEnabled;
    _endianness = widget.server.endianness;
    _addressBase = widget.server.addressBase;
    _connectionStatus = widget.connectionStatus;
    _effectiveStatus = widget.effectiveStatus;
    _subscribeToStatus();
    _subscribeToEffectiveStatus();
    _initPollGroupControllers();
  }

  void _initPollGroupControllers() {
    // Dispose old controllers. Intervals need none — each row's
    // [DurationField] owns its own text.
    for (final c in _pollGroupNameControllers) {
      c.dispose();
    }
    // Create new controllers from current poll groups
    _pollGroupNameControllers = widget.server.pollGroups
        .map((pg) => TextEditingController(text: pg.name))
        .toList();
  }

  @override
  void didUpdateWidget(covariant _ModbusServerConfigCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connectionStream != oldWidget.connectionStream) {
      _connectionStatus = widget.connectionStatus;
      _subscribeToStatus();
    }
    if (widget.effectiveStatusStream != oldWidget.effectiveStatusStream) {
      _effectiveStatus = widget.effectiveStatus;
      _subscribeToEffectiveStatus();
    }
    if (widget.server.pollGroups.length != _pollGroupNameControllers.length) {
      _initPollGroupControllers();
    }
  }

  void _subscribeToStatus() {
    _statusSub?.cancel();
    _statusSub = widget.connectionStream?.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });
  }

  void _subscribeToEffectiveStatus() {
    _effectiveStatusSub?.cancel();
    _effectiveStatusSub = widget.effectiveStatusStream?.listen((status) {
      if (mounted) setState(() => _effectiveStatus = status);
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _effectiveStatusSub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _unitIdController.dispose();
    _aliasController.dispose();
    for (final c in _pollGroupNameControllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// Builds a [ModbusConfig] from the current controller/field state.
  ModbusConfig _buildConfig(
      {List<ModbusPollGroupConfig>? pollGroups, bool? enabled}) {
    return ModbusConfig(
      host: _hostController.text,
      port: (int.tryParse(_portController.text) ?? 502).clamp(1, 65535),
      unitId: (int.tryParse(_unitIdController.text) ?? 1).clamp(0, 255),
      pollGroups: pollGroups ?? widget.server.pollGroups,
      umasEnabled: _umasEnabled,
      endianness: _endianness,
      addressBase: _addressBase,
      enabled: enabled ?? widget.server.enabled,
    )..serverAlias =
        _aliasController.text.isEmpty ? null : _aliasController.text;
  }

  Widget _unitIdInfoButton() {
    return IconButton(
      icon: const Icon(Icons.info_outline, size: 20),
      tooltip: 'Modbus TCP Unit ID (0-255).\n'
          'Identifies the device when routing through a gateway.\n\n'
          'Common defaults:\n'
          '\u2022 Schneider M340/M580: 255 (NOC), 0/1 (data)\n'
          '\u2022 Schneider M241: any (ignores unit ID)\n'
          '\u2022 Siemens S7-1200/1500: 255\n'
          '\u2022 Allen-Bradley/Rockwell: 0 or 1\n'
          '\u2022 ABB AC800M: 255\n'
          '\u2022 Omron CJ/NJ: 0\n'
          '\u2022 Wago 750: 1\n'
          '\u2022 Beckhoff BC/BK: 1\n'
          '\u2022 Danfoss VLT: 1\n'
          '\u2022 Mitsubishi FX/Q: 1\n'
          '\u2022 Phoenix Contact: 1\n\n'
          'Most TCP devices ignore unit ID (identified by IP).\n'
          'For serial gateways, unit ID = slave address (1-247).\n'
          'Try 1 first, then 0, then 255.',
      onPressed: null,
    );
  }

  void _addPollGroup() {
    final pollGroups =
        List<ModbusPollGroupConfig>.from(widget.server.pollGroups);
    pollGroups.add(ModbusPollGroupConfig(
      name: 'group_${widget.server.pollGroups.length}',
      intervalMs: 1000,
    ));
    widget.onUpdate(_buildConfig(pollGroups: pollGroups));
  }

  void _removePollGroup(int index) {
    final pollGroups =
        List<ModbusPollGroupConfig>.from(widget.server.pollGroups);
    pollGroups.removeAt(index);
    widget.onUpdate(_buildConfig(pollGroups: pollGroups));
  }

  void _updatePollGroup(int index, {Duration? interval}) {
    final pollGroups =
        List<ModbusPollGroupConfig>.from(widget.server.pollGroups);
    pollGroups[index] = ModbusPollGroupConfig(
      name: _pollGroupNameControllers[index].text,
      intervalMs: interval?.inMilliseconds ??
          widget.server.pollGroups[index].intervalMs,
    );
    widget.onUpdate(_buildConfig(pollGroups: pollGroups));
  }

  void _updateServer() {
    widget.onUpdate(_buildConfig());
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: _ServerCardLeading(
          reorderIndex: widget.reorderIndex,
          icon: const FaIcon(FontAwesomeIcons.networkWired, size: 20),
        ),
        title: Text(
          widget.server.serverAlias ??
              '${widget.server.host}:${widget.server.port}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: widget.server.enabled ? null : Colors.grey,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        subtitle: Text(
          '${widget.server.host}:${widget.server.port} (Unit ${widget.server.unitId})',
          style: TextStyle(color: Colors.grey[600]),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // TD-004 (v1.1.x): surface UMAS session health when
            // umasEnabled is on. Falls back to pure TCP otherwise.
            // Honest absence (phase 3): see the JBTM card's chip.
            if (widget.liveStatusKnown || !widget.server.enabled) ...[
              ConnectionStatusChip(
                status: _connectionStatus,
                effectiveStatus: _umasEnabled ? _effectiveStatus : null,
                stateManLoading: widget.stateManLoading,
                disabled: !widget.server.enabled,
              ),
              const SizedBox(width: 4),
            ],
            _ServerEnabledToggle(
              enabled: widget.server.enabled,
              onChanged: (value) =>
                  widget.onUpdate(_buildConfig(enabled: value)),
            ),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.trash, size: 16),
              onPressed: () {
                showConfirmDialog(
                  context: context,
                  title: 'Remove server',
                  message:
                      'Are you sure you want to remove this Modbus server?',
                  confirmLabel: 'Remove',
                  destructive: true,
                ).then((confirmed) {
                  if (confirmed) widget.onRemove();
                });
              },
            ),
            const SizedBox(width: 8),
            const FaIcon(FontAwesomeIcons.chevronDown, size: 16),
          ],
        ),
        onExpansionChanged: (expanded) => setState(() {}),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 400;
                    if (isNarrow) {
                      return Column(
                        children: [
                          TextField(
                            controller: _hostController,
                            decoration: const InputDecoration(
                              labelText: 'Host',
                              hintText: 'localhost',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.server, size: 16),
                            ),
                            onChanged: (_) => _updateServer(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _portController,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              hintText: '502',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.hashtag, size: 16),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (_) => _updateServer(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _unitIdController,
                            decoration: InputDecoration(
                              labelText: 'Unit ID',
                              hintText: '0-255',
                              prefixIcon: const FaIcon(
                                  FontAwesomeIcons.addressCard,
                                  size: 16),
                              suffixIcon: _unitIdInfoButton(),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (_) => _updateServer(),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: _hostController,
                                decoration: const InputDecoration(
                                  labelText: 'Host',
                                  hintText: 'localhost',
                                  prefixIcon:
                                      FaIcon(FontAwesomeIcons.server, size: 16),
                                ),
                                onChanged: (_) => _updateServer(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 1,
                              child: TextField(
                                controller: _portController,
                                decoration: const InputDecoration(
                                  labelText: 'Port',
                                  hintText: '502',
                                  prefixIcon: FaIcon(FontAwesomeIcons.hashtag,
                                      size: 16),
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (_) => _updateServer(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 1,
                              child: TextField(
                                controller: _unitIdController,
                                decoration: InputDecoration(
                                  labelText: 'Unit ID',
                                  hintText: '0-255',
                                  prefixIcon: const FaIcon(
                                      FontAwesomeIcons.addressCard,
                                      size: 16),
                                  suffixIcon: _unitIdInfoButton(),
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (_) => _updateServer(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _aliasController,
                  decoration: const InputDecoration(
                    labelText: 'Server Alias (optional)',
                    hintText: 'My Modbus Server',
                    prefixIcon: FaIcon(FontAwesomeIcons.tag, size: 16),
                  ),
                  onChanged: (_) => _updateServer(),
                ),
                const Divider(height: 24),
                ExpansionTile(
                  title:
                      Text('Poll Groups (${widget.server.pollGroups.length})'),
                  leading:
                      const FaIcon(FontAwesomeIcons.clockRotateLeft, size: 16),
                  initiallyExpanded: false,
                  children: [
                    ...widget.server.pollGroups.asMap().entries.map((entry) {
                      final i = entry.key;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        child: Row(children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _pollGroupNameControllers[i],
                              decoration: const InputDecoration(
                                  labelText: 'Name', isDense: true),
                              onChanged: (_) => _updatePollGroup(i),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 1,
                            child: DurationField(
                              value: Duration(
                                  milliseconds: entry.value.intervalMs),
                              labelText: 'Interval',
                              isDense: true,
                              // Same bounds the old clamp enforced.
                              min: const Duration(milliseconds: 50),
                              max: const Duration(milliseconds: 999999),
                              units: const [
                                DurationUnit.milliseconds,
                                DurationUnit.seconds,
                                DurationUnit.minutes,
                              ],
                              resolution: const Duration(milliseconds: 1),
                              onChanged: (v) =>
                                  _updatePollGroup(i, interval: v),
                            ),
                          ),
                          IconButton(
                            icon:
                                const FaIcon(FontAwesomeIcons.trash, size: 14),
                            onPressed: () => _removePollGroup(i),
                            tooltip: 'Remove poll group',
                          ),
                        ]),
                      );
                    }),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: TextButton.icon(
                        icon: const FaIcon(FontAwesomeIcons.plus, size: 14),
                        label: const Text('Add Poll Group'),
                        onPressed: _addPollGroup,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<ModbusEndianness>(
                          value: _endianness,
                          decoration: const InputDecoration(
                            labelText: 'Byte Order',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: ModbusEndianness.ABCD,
                              child: Text('ABCD (Big-Endian)'),
                            ),
                            DropdownMenuItem(
                              value: ModbusEndianness.CDAB,
                              child: Text('CDAB (Word Swap)'),
                            ),
                            DropdownMenuItem(
                              value: ModbusEndianness.BADC,
                              child: Text('BADC (Byte Swap)'),
                            ),
                            DropdownMenuItem(
                              value: ModbusEndianness.DCBA,
                              child: Text('DCBA (Little-Endian)'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _endianness = value);
                              _updateServer();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.info_outline),
                        tooltip:
                            'Byte order for 32-bit values (float, int32, etc.).\n'
                            'Most devices use ABCD (Big-Endian, Modbus standard).\n\n'
                            'Common vendor defaults:\n'
                            '\u2022 Schneider/Modicon: CDAB (Word Swap)\n'
                            '\u2022 Siemens S7: ABCD (Big-Endian)\n'
                            '\u2022 Allen-Bradley/Rockwell: CDAB or DCBA (varies)\n'
                            '\u2022 ABB: ABCD (Big-Endian)\n'
                            '\u2022 Omron: CDAB (Word Swap)\n'
                            '\u2022 Wago: ABCD (Big-Endian)\n'
                            '\u2022 Beckhoff: ABCD (Big-Endian)\n'
                            '\u2022 Danfoss VLT: ABCD (Big-Endian)\n'
                            '\u2022 Mitsubishi: CDAB (Word Swap)\n'
                            '\u2022 Phoenix Contact: ABCD (Big-Endian)\n\n'
                            'If multi-register values read as garbage, try CDAB first.',
                        onPressed: null,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _addressBase,
                          decoration: const InputDecoration(
                            labelText: 'Address Base',
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 0, child: Text('0 (Protocol Default)')),
                            DropdownMenuItem(
                                value: 1, child: Text('1 (Modicon/Schneider)')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _addressBase = value);
                              _updateServer();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.info_outline),
                        tooltip: 'Address base for register numbering.\n\n'
                            'Base 0: Wire address = configured address (e.g., HR 0 = PDU 0x0000)\n'
                            'Base 1: Wire address = configured address - 1 (e.g., HR 1 = PDU 0x0000)\n\n'
                            'Common vendor conventions:\n'
                            '\u2022 0-based: Siemens, ABB, Beckhoff, Wago, Omron, Allen-Bradley\n'
                            '\u2022 1-based: Schneider M340/M580, Mitsubishi, Delta, Unitronics\n\n'
                            'When in doubt, use 0 (protocol default).',
                        onPressed: null,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                CheckboxListTile(
                  title: const Text('Schneider UMAS'),
                  subtitle:
                      const Text('Variable browsing via FC90 (M340/M580 only)'),
                  value: _umasEnabled,
                  onChanged: (value) {
                    setState(() => _umasEnabled = value ?? false);
                    _updateServer();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerConfigCard extends StatefulWidget {
  final OpcUAConfig server;
  final Function(OpcUAConfig) onUpdate;
  final VoidCallback onRemove;
  final ConnectionStatus? connectionStatus;
  final Stream<ConnectionStatus>? connectionStream;

  /// Combined link + data-plane health from [ClientWrapper]. Timer-derived,
  /// so it goes `opcuaUnhealthy` when values silently stop flowing — the
  /// case the pure [connectionStream] chip used to render green forever.
  final EffectiveDeviceStatus? effectiveStatus;
  final Stream<EffectiveDeviceStatus>? effectiveStatusStream;
  final bool stateManLoading;

  /// Index of this card in the enclosing [ReorderableListView], or null when
  /// the list has nothing to reorder. Drives the drag handle — see
  /// [_ServerCardLeading].
  final int? reorderIndex;

  /// Whether live per-server status can be known on this transport
  /// (`ConfigSource.hasLiveStatus`). When false the chip does not render at
  /// all — a grey "Not active" beside a server the backend may be connected
  /// to right now would be a lie, and the editor renders one honest-absence
  /// line instead ([kConfigStatusAbsenceKey]). A disabled server's chip
  /// stays: that is a config fact, knowable on any transport.
  final bool liveStatusKnown;

  const _ServerConfigCard({
    super.key,
    required this.server,
    required this.onUpdate,
    required this.onRemove,
    this.connectionStatus,
    this.connectionStream,
    this.effectiveStatus,
    this.effectiveStatusStream,
    this.stateManLoading = false,
    this.reorderIndex,
    this.liveStatusKnown = true,
  });

  @override
  State<_ServerConfigCard> createState() => _ServerConfigCardState();
}

class _ServerConfigCardState extends State<_ServerConfigCard> {
  late TextEditingController _endpointController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _serverAliasController;
  /// Held as values, not controllers: [DurationField] owns its own text and
  /// only reports back a duration it has already parsed and clamped.
  late Duration _publishingInterval;
  late Duration _secureChannelLifetime;
  ConnectionStatus? _connectionStatus;
  StreamSubscription<ConnectionStatus>? _stateSubscription;
  EffectiveDeviceStatus? _effectiveStatus;
  StreamSubscription<EffectiveDeviceStatus>? _effectiveStatusSub;

  /// False until the user touches the password field. While false the stored
  /// password is passed through untouched on save, so the field can stay
  /// blank — pre-filling an obscured field would count out the password's
  /// length in dots to anyone glancing at the screen.
  bool _passwordEdited = false;

  @override
  void initState() {
    super.initState();
    _endpointController = TextEditingController(text: widget.server.endpoint);
    _usernameController =
        TextEditingController(text: widget.server.username ?? '');
    _passwordController = TextEditingController();
    _serverAliasController =
        TextEditingController(text: widget.server.serverAlias ?? '');
    _publishingInterval = widget.server.publishingInterval;
    _secureChannelLifetime = widget.server.secureChannelLifetime;
    _connectionStatus = widget.connectionStatus;
    _effectiveStatus = widget.effectiveStatus;
    _listenToState();
  }

  @override
  void didUpdateWidget(covariant _ServerConfigCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectionStream != widget.connectionStream ||
        oldWidget.effectiveStatusStream != widget.effectiveStatusStream) {
      _stateSubscription?.cancel();
      _effectiveStatusSub?.cancel();
      _connectionStatus = widget.connectionStatus;
      _effectiveStatus = widget.effectiveStatus;
      _listenToState();
    }
  }

  void _listenToState() {
    _stateSubscription = widget.connectionStream?.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });
    _effectiveStatusSub = widget.effectiveStatusStream?.listen((status) {
      if (mounted) setState(() => _effectiveStatus = status);
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _effectiveStatusSub?.cancel();
    _endpointController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _serverAliasController.dispose();
    super.dispose();
  }

  void _updateServer({bool? enabled}) {
    final updatedServer = OpcUAConfig()
      ..endpoint = _endpointController.text
      ..username =
          _usernameController.text.isEmpty ? null : _usernameController.text
      ..password = _passwordEdited
          ? (_passwordController.text.isEmpty ? null : _passwordController.text)
          : widget.server.password
      ..serverAlias = _serverAliasController.text.isEmpty
          ? null
          : _serverAliasController.text
      ..sslCert = widget.server.sslCert
      ..sslKey = widget.server.sslKey
      ..enabled = enabled ?? widget.server.enabled
      // Already parsed and clamped by the DurationFields, which stay silent
      // on a half-typed box rather than reporting a value nobody asked for.
      ..publishingIntervalMs = _publishingInterval.inMilliseconds
      ..secureChannelLifetimeMs = _secureChannelLifetime.inMilliseconds;

    widget.onUpdate(updatedServer);
  }

  Future<void> _selectCertificate() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pem', 'crt', 'cer'],
        dialogTitle: 'Select Certificate File',
        initialDirectory: (await getApplicationSupportDirectory()).path,
      );

      if (result != null && result.files.single.path != null) {
        setState(() async {
          widget.server.sslCert =
              await (File(result.files.single.path!).readAsBytes());
        });
        _updateServer();
      }
    } catch (e) {
      if (!context.mounted) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error selecting certificate: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  Future<void> _selectPrivateKey() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pem', 'key'],
        dialogTitle: 'Select Private Key File',
        initialDirectory: (await getApplicationSupportDirectory()).path,
      );

      if (result != null && result.files.single.path != null) {
        setState(() async {
          widget.server.sslKey =
              await (File(result.files.single.path!).readAsBytes());
        });
        _updateServer();
      }
    } catch (e) {
      if (!context.mounted) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error selecting private key: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  void _showCertificateGenerator() {
    showDialog(
      context: context,
      builder: (context) {
        final size = MediaQuery.of(context).size;
        final isSmallScreen = size.width < 600;
        return StandardDialogFrame(
          title: 'Generate SSL certificates',
          icon: Icons.verified_user,
          width: isSmallScreen ? size.width * 0.85 : 640,
          child: SizedBox(
            width: isSmallScreen ? size.width * 0.85 : 600,
            height: isSmallScreen ? size.height * 0.6 : 600,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                child: CertificateGenerator(
                  onCertificatesGenerated: (cert, key) {
                    setState(() {
                      widget.server.sslCert = cert;
                      widget.server.sslKey = key;
                    });
                    _updateServer();
                    Navigator.of(context).pop();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String? uint8ListToString(Uint8List? ls) {
    return ls != null ? String.fromCharCodes(ls) : null;
  }

  /// The stored password never enters the field; a saved one is signalled by
  /// a fixed-width hint so the dot count says nothing about its length.
  Widget _passwordField() {
    final hasSaved =
        !_passwordEdited && (widget.server.password?.isNotEmpty ?? false);
    return TextField(
      controller: _passwordController,
      decoration: InputDecoration(
        labelText: 'Password (optional)',
        prefixIcon: const FaIcon(FontAwesomeIcons.lock, size: 16),
        hintText: hasSaved ? '••••••••' : null,
        helperText: hasSaved ? 'Saved — leave blank to keep it' : null,
        // Floats the label off the empty field so the hint dots above are
        // what reads as the field's content.
        floatingLabelBehavior: hasSaved
            ? FloatingLabelBehavior.always
            : FloatingLabelBehavior.auto,
        suffixIcon: hasSaved
            ? IconButton(
                tooltip: 'Remove password',
                icon: const FaIcon(FontAwesomeIcons.xmark, size: 16),
                onPressed: () {
                  setState(() => _passwordEdited = true);
                  _passwordController.clear();
                  _updateServer();
                },
              )
            : null,
      ),
      obscureText: true,
      onChanged: (_) {
        if (!_passwordEdited) setState(() => _passwordEdited = true);
        _updateServer();
      },
    );
  }

  /// Publishing interval and SecureChannel lifetime.
  ///
  /// Both are shown with their effect spelled out rather than their protocol
  /// name — an operator setting these is deciding how fast the screen
  /// updates and how often the session is renewed, not filling in an OPC-UA
  /// service parameter.
  Widget _timingCard(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 400;
        // Units are restricted per field rather than left wide open: minutes
        // on a field that stops at five seconds would be a dropdown where
        // every choice is out of range.
        final intervalField = DurationField(
          value: _publishingInterval,
          labelText: 'Update interval',
          helperText: 'higher = less PLC load',
          prefixIcon: const FaIcon(FontAwesomeIcons.gaugeHigh, size: 16),
          min: const Duration(milliseconds: OpcUAConfig.publishingIntervalMinMs),
          max: const Duration(milliseconds: OpcUAConfig.publishingIntervalMaxMs),
          units: const [DurationUnit.milliseconds, DurationUnit.seconds],
          onChanged: (value) {
            setState(() => _publishingInterval = value);
            _updateServer();
          },
        );
        final lifetimeField = DurationField(
          value: _secureChannelLifetime,
          labelText: 'Secure channel lifetime',
          helperText: 'renewed at 75% of this',
          prefixIcon: const FaIcon(FontAwesomeIcons.clockRotateLeft, size: 16),
          min: const Duration(
              milliseconds: OpcUAConfig.secureChannelLifetimeMinMs),
          max: const Duration(
              milliseconds: OpcUAConfig.secureChannelLifetimeMaxMs),
          units: const [
            DurationUnit.seconds,
            DurationUnit.minutes,
            DurationUnit.hours,
          ],
          onChanged: (value) {
            setState(() => _secureChannelLifetime = value);
            _updateServer();
          },
        );
        return Card(
          child: Padding(
            padding: EdgeInsets.all(isNarrow ? 12.0 : 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const FaIcon(FontAwesomeIcons.stopwatch, size: 16),
                    const SizedBox(width: 8),
                    Text('Timing',
                        style: Theme.of(context).textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: 12),
                if (isNarrow)
                  Column(children: [
                    intervalField,
                    const SizedBox(height: 12),
                    lifetimeField,
                  ])
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: intervalField),
                      const SizedBox(width: 12),
                      Expanded(child: lifetimeField),
                    ],
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
    final sslCertString = uint8ListToString(widget.server.sslCert);
    final sslKeyString = uint8ListToString(widget.server.sslKey);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: _ServerCardLeading(
          reorderIndex: widget.reorderIndex,
          icon: FaIcon(
            FontAwesomeIcons.server,
            size: 20,
            color: sslCertString == kCertPlaceholder ||
                    sslKeyString == kCertPlaceholder
                ? Theme.of(context).colorScheme.error
                : null,
          ),
        ),
        title: Text(
          widget.server.serverAlias ?? widget.server.endpoint,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: widget.server.enabled ? null : Colors.grey,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        subtitle: Text(widget.server.endpoint,
            style: TextStyle(color: Colors.grey[600]),
            overflow: TextOverflow.ellipsis,
            maxLines: 1),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Honest absence (phase 3): see [liveStatusKnown].
            if (widget.liveStatusKnown || !widget.server.enabled) ...[
              ConnectionStatusChip(
                status: _connectionStatus,
                effectiveStatus: _effectiveStatus,
                stateManLoading: widget.stateManLoading,
                disabled: !widget.server.enabled,
              ),
              const SizedBox(width: 4),
            ],
            _ServerEnabledToggle(
              enabled: widget.server.enabled,
              onChanged: (value) => _updateServer(enabled: value),
            ),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.trash, size: 16),
              onPressed: () {
                showConfirmDialog(
                  context: context,
                  title: 'Remove server',
                  message: 'Are you sure you want to remove this server?',
                  confirmLabel: 'Remove',
                  destructive: true,
                ).then((confirmed) {
                  if (confirmed) widget.onRemove();
                });
              },
            ),
            const SizedBox(width: 8),
            const FaIcon(FontAwesomeIcons.chevronDown, size: 16),
          ],
        ),
        onExpansionChanged: (expanded) => setState(() {}),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _endpointController,
                  decoration: const InputDecoration(
                    labelText: 'Endpoint URL',
                    hintText: 'opc.tcp://localhost:4840',
                    prefixIcon: FaIcon(FontAwesomeIcons.link, size: 16),
                  ),
                  onChanged: (_) => _updateServer(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _serverAliasController,
                  decoration: const InputDecoration(
                    labelText: 'Server Alias (optional)',
                    hintText: 'My OPC-UA Server',
                    prefixIcon: FaIcon(FontAwesomeIcons.tag, size: 16),
                  ),
                  onChanged: (_) => _updateServer(),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 400;
                    if (isNarrow) {
                      return Column(
                        children: [
                          TextField(
                            controller: _usernameController,
                            decoration: const InputDecoration(
                              labelText: 'Username (optional)',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.user, size: 16),
                            ),
                            onChanged: (_) => _updateServer(),
                          ),
                          const SizedBox(height: 12),
                          _passwordField(),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _usernameController,
                            decoration: const InputDecoration(
                              labelText: 'Username (optional)',
                              prefixIcon:
                                  FaIcon(FontAwesomeIcons.user, size: 16),
                            ),
                            onChanged: (_) => _updateServer(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _passwordField()),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                _timingCard(context),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 400;
                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(isNarrow ? 12.0 : 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const FaIcon(FontAwesomeIcons.certificate,
                                    size: 16),
                                const SizedBox(width: 8),
                                Text('SSL Certificates',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                widget.server.sslCert == null
                                    ? Text(
                                        'Please import or generate a certificate if needed')
                                    : sslCertString == kCertPlaceholder
                                        ? Text(
                                            'Please import or generate a certificate',
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error),
                                          )
                                        : Text('Certificate in place'),
                                const SizedBox(height: 8),
                                ElevatedButton.icon(
                                  onPressed: _selectCertificate,
                                  icon: const FaIcon(
                                      FontAwesomeIcons.folderOpen,
                                      size: 14),
                                  label: const Text('Browse Certificate'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                widget.server.sslKey == null
                                    ? Text(
                                        'Please import or generate a private key if needed')
                                    : sslKeyString == kCertPlaceholder
                                        ? Text(
                                            'Please import or generate a private key',
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error),
                                          )
                                        : Text('Private key in place'),
                                const SizedBox(height: 8),
                                ElevatedButton.icon(
                                  onPressed: _selectPrivateKey,
                                  icon: const FaIcon(
                                      FontAwesomeIcons.folderOpen,
                                      size: 14),
                                  label: const Text('Browse Private Key'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _showCertificateGenerator,
                                icon: const FaIcon(FontAwesomeIcons.plus,
                                    size: 14),
                                label: const Text('Generate New Certificates'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
        text: newValue.text.toUpperCase(), selection: newValue.selection);
  }
}

// ===================== The editor itself =====================

/// The three server sections over ONE [ConfigDocument], read from and
/// written to the [ConfigSource] the transport selected. See the library
/// doc for why this widget exists.
class StateManConfigEditor extends ConsumerStatefulWidget {
  const StateManConfigEditor({
    super.key,
    required this.source,
    this.onResetSavedConfig,
    this.saveButtonKey,
    this.refusalRowKey,
    this.restoreButtonKey,
    this.applyNoteKey,
  });

  /// Where the document lives. The transport decides this and nothing else.
  final ConfigSource source;

  /// Direct mode's escape hatch when the stored document will not load:
  /// delete it so the next load reseeds the default. The button is hidden
  /// when this is null (gateway mode — you do not delete the backend's
  /// config file from a panel).
  final Future<void> Function()? onResetSavedConfig;

  /// Host-page spellings for the affordances existing suites already find
  /// (the gateway page passes its 17-13 `kBackendConfig*` keys). Defaults
  /// are the editor-owned `kConfigEditor*` constants.
  final Key? saveButtonKey;
  final Key? refusalRowKey;
  final Key? restoreButtonKey;
  final Key? applyNoteKey;

  @override
  ConsumerState<StateManConfigEditor> createState() =>
      _StateManConfigEditorState();
}

class _StateManConfigEditorState extends ConsumerState<StateManConfigEditor> {
  ConfigDocument? _doc;

  /// The document as last read or written — dirty is `encode() != this`,
  /// which the minimal-diff rule makes exact: an edit typed back to its
  /// original value compares clean again. Null while nothing loaded, AND
  /// after the raw recovery editor replaced a document the store could not
  /// parse — there is then no known-saved counterpart, so the document is
  /// unsaved by definition (see [_hasUnsavedChanges]).
  String? _savedEncoded;
  bool _isLoading = false;
  String? _error;

  /// The far end's refusal (or the local parser's), verbatim — rendered in
  /// the refusal row until the next attempt. This widget composes no refusal
  /// prose of its own: a paraphrase is a second place two different
  /// refusals could start reading the same (17-13).
  String? _refusal;

  /// `source.hasPrevious()` as of the last load/save — which is
  /// `read().hasPrevious`, never `previous()` (17-10 deviation 4). Drives
  /// the restore button.
  bool _hasPrevious = false;

  /// The stored text, fetched when [ConfigSource.read] refused to parse it —
  /// the escape hatch for a document that will not decode. Non-null switches
  /// the error face into the raw recovery editor.
  RawConfig? _rawRecovery;
  String? _recoveryError;

  final _recoveryController = TextEditingController();

  final _opcuaKeys = _RowKeys();
  final _jbtmKeys = _RowKeys();
  final _modbusKeys = _RowKeys();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _recoveryController.dispose();
    super.dispose();
  }

  /// The operator-facing sentence for [error]. A protocol refusal carries
  /// the far end's message; anything else is shown as what it is.
  static String _describe(Object error) =>
      error is rpc.RpcException ? error.message : error.toString();

  /// Re-points [_doc] and everything derived from it. The single place a
  /// new document enters this state, whether from load or the raw recovery
  /// editor.
  ///
  /// `doc.readOnlySections` is deliberately not read here any more: the
  /// sections it names are no longer rendered, and they need nothing done to
  /// them to survive — [ConfigDocument] carries every unmodelled section
  /// verbatim from `parse` to `encode`, which is what a gateway save relies
  /// on to re-attach `relay` byte-for-byte.
  void _adoptDocument(ConfigDocument doc, {required String? savedEncoded}) {
    _doc = doc;
    _savedEncoded = savedEncoded;
    _opcuaKeys.reset(doc.opcua.length);
    _jbtmKeys.reset(doc.jbtm.length);
    _modbusKeys.reset(doc.modbus.length);
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _refusal = null;
      _rawRecovery = null;
      _recoveryError = null;
    });

    try {
      final doc = await widget.source.read();
      _adoptDocument(doc, savedEncoded: doc.encode());
      _hasPrevious = await widget.source.hasPrevious();
    } on FormatException catch (e) {
      // The stored document is the source's truth even when it will not
      // decode: fetch it whole for the raw recovery editor. The
      // alternative is SSH — the exact regression the escape hatch exists
      // to prevent.
      _error = e.message;
      try {
        final raw = await widget.source.readRaw();
        _rawRecovery = raw;
        _recoveryController.text = raw.text;
      } catch (inner) {
        _error = _describe(inner);
      }
    } catch (e) {
      _error = _describe(e);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get _hasUnsavedChanges {
    final doc = _doc;
    if (doc == null) return false;
    final saved = _savedEncoded;
    // A document adopted from the raw recovery editor has no known-saved
    // counterpart: unsaved by definition, so the fix can be saved at all.
    if (saved == null) return true;
    return doc.encode() != saved;
  }

  /// What a successful save MEANS on this transport, said where it happens —
  /// from [ConfigSource.applySemantics], never hardcoded per page.
  String get _savedCopy => switch (widget.source.applySemantics) {
        ApplySemantics.appliedOnSave => 'Configuration saved successfully!',
        ApplySemantics.restartToApply =>
          'Saved to the backend. It applies the new configuration when it '
              'restarts.',
      };

  /// The persistent footer under the save button. Direct mode has none on
  /// purpose: a save there is applied on the spot (the source invalidates
  /// the live StateMan), and a restart note would teach operators to
  /// restart things that need no restart.
  String? get _applyNote => switch (widget.source.applySemantics) {
        ApplySemantics.appliedOnSave => null,
        ApplySemantics.restartToApply =>
          'Takes effect when the backend restarts — it does not restart '
              'itself.',
      };

  Future<void> _save() async {
    final doc = _doc;
    if (doc == null) return;
    setState(() => _refusal = null);

    try {
      // The authoritative check, at the source, before anything is written:
      // gateway asks the backend's own validate(), direct runs the same
      // StateManConfig.fromJson the local StateMan boots with.
      final validation = await widget.source.validate(doc);
      if (!validation.ok) {
        if (mounted) {
          // The refuser's own sentences, verbatim, in the refusal row —
          // where they stay readable, unlike a snackbar that scrolls away.
          setState(() => _refusal = validation.problems.join(' '));
        }
        return;
      }

      await widget.source.write(doc);
      _savedEncoded = doc.encode();
      // A write may create the far end's one-level .previous.
      _hasPrevious = await widget.source.hasPrevious();
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(_savedCopy), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _refusal = _describe(e));
    }
  }

  Future<void> _restore() async {
    setState(() => _refusal = null);
    try {
      await widget.source.restorePrevious();
      await _load();
    } catch (e) {
      if (!mounted) return;
      // The far end's refusal, verbatim — restorePrevious may refuse by
      // name (17-10 deviation 4), and its sentence is the operator's.
      setState(() => _refusal = _describe(e));
    }
  }

  /// Re-parses the raw recovery editor's text into a fresh document. The
  /// stored document is the broken one, so the result is unsaved by
  /// definition ([_savedEncoded] stays null) and the save button arms.
  void _applyRecoveryJson() {
    final recovery = _rawRecovery;
    if (recovery == null) return;
    try {
      final parsed = ConfigDocument.parse(_recoveryController.text,
          readOnlySections: recovery.readOnlySections);
      setState(() {
        _adoptDocument(parsed, savedEncoded: null);
        _error = null;
        _rawRecovery = null;
        _recoveryError = null;
      });
    } on FormatException catch (e) {
      setState(() => _recoveryError = e.message);
    } catch (e) {
      setState(() => _recoveryError = e.toString());
    }
  }

  // ---- section mutations ----------------------------------------------

  void _addOpcua() {
    setState(() {
      _doc?.opcua.add(ConfigEntry.fresh(OpcUAConfig()));
      _opcuaKeys.add();
    });
  }

  void _addJbtm() {
    setState(() {
      _doc?.jbtm.add(ConfigEntry.fresh(M2400Config(
        host: 'localhost',
        port: 52211,
      )));
      _jbtmKeys.add();
    });
  }

  void _addModbus() {
    setState(() {
      _doc?.modbus.add(ConfigEntry.fresh(ModbusConfig(
        host: 'localhost',
        port: 502,
        unitId: 1,
        pollGroups: [ModbusPollGroupConfig(name: 'default', intervalMs: 1000)],
      )));
      _modbusKeys.add();
    });
  }

  /// Drag-and-drop reorder. Order is cosmetic for lookups (keys bind to
  /// servers by alias, not position) but it is the order the operator reads
  /// on this page, in the key-mapping server dropdowns, and the order
  /// [StateMan] brings the clients up in — so it is worth being able to set.
  void _reorder<T>(List<ConfigEntry<T>> entries, _RowKeys keys, int oldIndex,
      int newIndex) {
    if (!moveInList(entries, oldIndex, newIndex)) return;
    setState(() => keys.reorder(oldIndex, newIndex));
  }

  void _removeAt<T>(List<ConfigEntry<T>> entries, _RowKeys keys, int index) {
    setState(() {
      entries.removeAt(index);
      keys.removeAt(index);
    });
  }

  // ---- section lists ----------------------------------------------------

  Widget _opcuaList(ConfigDocument doc, AsyncValue<StateMan>? stateManAsync) {
    final StateMan? stateMan = stateManAsync?.valueOrNull;
    // A one-server list has nothing to reorder, so it gets no drag handles.
    final reorderable = doc.opcua.length > 1;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) =>
          _reorder(doc.opcua, _opcuaKeys, oldIndex, newIndex),
      itemCount: doc.opcua.length,
      itemBuilder: (context, index) {
        final entry = doc.opcua[index];
        final server = entry.value;
        ClientWrapper? wrapper;
        if (stateMan != null) {
          wrapper = stateMan.clients.cast<ClientWrapper?>().firstWhere(
                (w) =>
                    (server.serverAlias != null &&
                        server.serverAlias!.isNotEmpty &&
                        w!.config.serverAlias == server.serverAlias) ||
                    w!.config.endpoint == server.endpoint,
                orElse: () => null,
              );
        }
        return _ServerConfigCard(
          key: _opcuaKeys[index],
          server: server,
          onUpdate: (edited) => setState(() => entry.update(edited)),
          onRemove: () => _removeAt(doc.opcua, _opcuaKeys, index),
          connectionStatus: wrapper?.connectionStatus,
          connectionStream: wrapper?.connectionStream,
          // Data-plane health: catches the frozen-session shape where the
          // channel stays formally open but no value ever arrives again,
          // which the event-driven connectionStream can never report.
          effectiveStatus: wrapper?.effectiveStatus,
          effectiveStatusStream: wrapper?.effectiveStatusStream,
          stateManLoading: stateManAsync?.isLoading ?? false,
          reorderIndex: reorderable ? index : null,
          liveStatusKnown: widget.source.hasLiveStatus,
        );
      },
    );
  }

  Widget _jbtmList(ConfigDocument doc, AsyncValue<StateMan>? stateManAsync) {
    final StateMan? stateMan = stateManAsync?.valueOrNull;
    final reorderable = doc.jbtm.length > 1;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) =>
          _reorder(doc.jbtm, _jbtmKeys, oldIndex, newIndex),
      itemCount: doc.jbtm.length,
      itemBuilder: (context, index) {
        final entry = doc.jbtm[index];
        final server = entry.value;
        M2400DeviceClientAdapter? adapter;
        if (stateMan != null) {
          adapter = stateMan.deviceClients
              .whereType<M2400DeviceClientAdapter>()
              .cast<M2400DeviceClientAdapter?>()
              .firstWhere(
                (dc) =>
                    (server.serverAlias != null &&
                        server.serverAlias!.isNotEmpty &&
                        dc!.serverAlias == server.serverAlias) ||
                    (dc!.wrapper.host == server.host &&
                        dc.wrapper.port == server.port),
                orElse: () => null,
              );
        }
        return _JbtmServerConfigCard(
          key: _jbtmKeys[index],
          server: server,
          onUpdate: (edited) => setState(() => entry.update(edited)),
          onRemove: () => _removeAt(doc.jbtm, _jbtmKeys, index),
          connectionStatus: adapter?.connectionStatus,
          connectionStream: adapter?.connectionStream,
          stateManLoading: stateManAsync?.isLoading ?? false,
          reorderIndex: reorderable ? index : null,
          liveStatusKnown: widget.source.hasLiveStatus,
        );
      },
    );
  }

  Widget _modbusList(ConfigDocument doc, AsyncValue<StateMan>? stateManAsync) {
    final StateMan? stateMan = stateManAsync?.valueOrNull;
    final reorderable = doc.modbus.length > 1;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) =>
          _reorder(doc.modbus, _modbusKeys, oldIndex, newIndex),
      itemCount: doc.modbus.length,
      itemBuilder: (context, index) {
        final entry = doc.modbus[index];
        final server = entry.value;
        ModbusDeviceClientAdapter? adapter;
        if (stateMan != null) {
          adapter = stateMan.deviceClients
              .whereType<ModbusDeviceClientAdapter>()
              .cast<ModbusDeviceClientAdapter?>()
              .firstWhere(
                (dc) =>
                    (server.serverAlias != null &&
                        server.serverAlias!.isNotEmpty &&
                        dc!.serverAlias == server.serverAlias) ||
                    (dc!.wrapper.host == server.host &&
                        dc.wrapper.port == server.port),
                orElse: () => null,
              );
        }
        return _ModbusServerConfigCard(
          key: _modbusKeys[index],
          server: server,
          onUpdate: (edited) => setState(() => entry.update(edited)),
          onRemove: () => _removeAt(doc.modbus, _modbusKeys, index),
          connectionStatus: adapter?.connectionStatus,
          connectionStream: adapter?.connectionStream,
          // TD-004 (v1.1.x): combined TCP + UMAS health stream so the
          // chip surfaces a broken UMAS session as `umasUnhealthy`.
          effectiveStatus: adapter?.effectiveStatus,
          effectiveStatusStream: adapter?.effectiveStatusStream,
          stateManLoading: stateManAsync?.isLoading ?? false,
          reorderIndex: reorderable ? index : null,
          liveStatusKnown: widget.source.hasLiveStatus,
        );
      },
    );
  }

  // ---- sections ----------------------------------------------------------

  Widget _section({
    required String title,
    required FaIconData icon,
    required VoidCallback onAdd,
    required bool isEmpty,
    required String emptyTitle,
    required String emptySubtitle,
    required Widget Function() list,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ServerSectionHeader(
              title: title,
              icon: icon,
              onAdd: onAdd,
            ),
            const SizedBox(height: 16),
            isEmpty
                ? SizedBox(
                    height: 200,
                    child: _EmptyServersPlaceholder(
                      icon: icon,
                      title: emptyTitle,
                      subtitle: emptySubtitle,
                    ),
                  )
                : list(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      final recovery = _rawRecovery;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FaIcon(FontAwesomeIcons.triangleExclamation,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Could not read the configuration: $_error',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (recovery != null) ...[
                // The escape hatch for a document that will not decode: the
                // stored text, whole and repairable from the panel.
                Text(
                  'The stored document is shown whole below, exactly as the '
                  'source holds it. Fix it here and apply, or paste a '
                  'known-good document.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: kConfigRawRecoveryFieldKey,
                  controller: _recoveryController,
                  maxLines: null,
                  style: theme.textTheme.bodySmall,
                  decoration: const InputDecoration(
                    labelText: 'Stored document (raw)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_recoveryError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _recoveryError!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      key: kConfigRawRecoveryApplyKey,
                      onPressed: _applyRecoveryJson,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Apply JSON'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                        onPressed: _load, child: const Text('Retry')),
                    if (widget.onResetSavedConfig != null) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                          onPressed: () => widget.onResetSavedConfig!()
                              .then((_) => _load()),
                          child: const Text('Delete saved configuration')),
                    ],
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    ElevatedButton(
                        onPressed: _load, child: const Text('Retry')),
                    if (widget.onResetSavedConfig != null) ...[
                      const SizedBox(width: 8),
                      ElevatedButton(
                          onPressed: () => widget.onResetSavedConfig!()
                              .then((_) => _load()),
                          child: const Text('Delete saved configuration')),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }

    final doc = _doc;
    if (doc == null) {
      return const SizedBox.shrink();
    }

    // Live per-server status exists only where the clients run (direct
    // mode). Over the relay the backend's client health is not on the wire
    // yet, and an unwatched provider here would drag a direct StateMan up
    // on a gateway panel.
    final stateManAsync =
        widget.source.hasLiveStatus ? ref.watch(stateManProvider) : null;

    final applyNote = _applyNote;

    return Column(
      children: [
        if (!widget.source.hasLiveStatus) ...[
          // The honest absence: no chips render below, and this line says
          // why — never a grey chip that reads as "not connected" beside a
          // server the backend may be connected to right now.
          Row(
            key: kConfigStatusAbsenceKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 16,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Connection status is not visible over the relay — the '
                  'backend\'s client health does not cross the wire yet, so '
                  'nothing here claims connected or disconnected.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        _section(
          title: 'OPC-UA Servers',
          icon: FontAwesomeIcons.server,
          onAdd: _addOpcua,
          isEmpty: doc.opcua.isEmpty,
          emptyTitle: 'No servers configured',
          emptySubtitle: 'Add your first OPC-UA server to get started',
          list: () => _opcuaList(doc, stateManAsync),
        ),
        const SizedBox(height: 16),
        _section(
          title: 'JBTM M2400 Servers',
          icon: FontAwesomeIcons.scaleBalanced,
          onAdd: _addJbtm,
          isEmpty: doc.jbtm.isEmpty,
          emptyTitle: 'No JBTM servers configured',
          emptySubtitle: 'Add your first JBTM M2400 server to get started',
          list: () => _jbtmList(doc, stateManAsync),
        ),
        const SizedBox(height: 16),
        _section(
          title: 'Modbus TCP Servers',
          icon: FontAwesomeIcons.networkWired,
          onAdd: _addModbus,
          isEmpty: doc.modbus.isEmpty,
          emptyTitle: 'No Modbus servers configured',
          emptySubtitle: 'Add your first Modbus TCP server to get started',
          list: () => _modbusList(doc, stateManAsync),
        ),
        const SizedBox(height: 16),
        if (_refusal != null) ...[
          Row(
            key: widget.refusalRowKey ?? kConfigEditorRefusalKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _refusal!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (_hasPrevious) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: widget.restoreButtonKey ?? kConfigEditorRestoreKey,
                  onPressed: _restore,
                  icon:
                      const FaIcon(FontAwesomeIcons.clockRotateLeft, size: 14),
                  label: const Text('Restore previous configuration'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // The ONE save button, for the ONE document — and the one unsaved
        // indicator on the page.
        _SaveConfigButton(
          hasUnsavedChanges: _hasUnsavedChanges,
          onSave: _save,
          buttonKey: widget.saveButtonKey,
        ),
        if (applyNote != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              applyNote,
              key: widget.applyNoteKey ?? kConfigEditorApplyNoteKey,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}
