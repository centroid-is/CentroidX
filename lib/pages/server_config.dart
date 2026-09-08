import 'dart:async';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:cryptography_flutter/cryptography_flutter.dart' as crypto_fl;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument;

import '../core/gateway_config.dart';
import '../core/gateway_state_man.dart';
import '../core/gateway_trust.dart';
import '../core/relayed_access_stores.dart' show relayedAccessErrors;
import '../core/server_config_db.dart';
import '../theme.dart';
import '../widgets/base_scaffold.dart';
import '../widgets/config_target_banner.dart';
import '../widgets/connection_status_chip.dart';
import '../widgets/duration_field.dart';
import '../widgets/gateway_identity_dialog.dart';
import '../widgets/gateway_link_status_row.dart';
import '../widgets/preferences.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:modbus_client/modbus_client.dart' show ModbusEndianness;
import 'package:tfc_dart/core/database.dart';
import '../providers/access.dart' show stationNameProvider;
import '../providers/gateway.dart';
import '../providers/gateway_link.dart';
import '../providers/state_man.dart';
import '../providers/preferences.dart';
import '../providers/database.dart';
// TODO not the best place but cross platform
import 'package:package_info_plus/package_info_plus.dart';

part 'server_config.g.dart';

const _certPlaceholder = "todo";

// ===================== Secure Envelope (Encryption Helper) =====================
class SecureEnvelope {
  static final Random _rng = Random.secure();
  static const String aadStr = 'centroid-v1';

  /// Forwarders onto the one hook, which lives with the one derivation in
  /// `package:tfc_access`. There is deliberately no storage here: two hooks is
  /// how a suite ends up running real 200k-iteration derivations somewhere
  /// nobody noticed. These exist so existing tests — and any future caller
  /// that knows this name — keep working unchanged.
  ///
  /// The ignores are the point rather than a wart: these two lines *are* the
  /// test hook, so reaching a @visibleForTesting member from them is exactly
  /// what they are for. Any other use in lib/ should still be flagged.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  static int? get kdfIterationsForTest => Pbkdf2Kdf.iterationsForTest;
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  static set kdfIterationsForTest(int? v) => Pbkdf2Kdf.iterationsForTest = v;

  static List<int> _rand(int n) =>
      List<int>.generate(n, (_) => _rng.nextInt(256));

  /// Encrypts [jsonConfig] with PBKDF2(HMAC-SHA256) -> AES-256-GCM
  /// using [compiledPrefix]+[exportPostfix] as the passphrase.
  static Future<Map<String, dynamic>> encrypt({
    required Map<String, dynamic> jsonConfig,
    required String compiledPrefix,
    required String exportPostfix,
  }) async {
    // Ensure fast native backends where available. This stays on the Flutter
    // side: cryptography_flutter is a plugin, and tfc_access is pure Dart.
    // Cryptography.instance is process-global, so the shared Pbkdf2Kdf below
    // picks this up anyway.
    crypto.Cryptography.instance =
        crypto_fl.FlutterCryptography.defaultInstance;

    final passphrase = '$compiledPrefix$exportPostfix';

    final iterations = Pbkdf2Kdf.iterations;
    final salt = _rand(16);
    final key = await Pbkdf2Kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
      iterations: iterations,
    );

    final algo = crypto.AesGcm.with256bits();
    final nonce = _rand(12);

    final clear = utf8.encode(jsonEncode(jsonConfig));
    final box = await algo.encrypt(
      clear,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(aadStr),
    );

    return {
      'version': 1,
      'kdf': {
        'name': 'pbkdf2-hmac-sha256',
        'iterations': iterations,
        'salt_b64': base64Encode(salt),
      },
      'cipher': {
        'name': 'aes-256-gcm',
        'nonce_b64': base64Encode(nonce),
      },
      'aad': aadStr,
      'ciphertext_b64': base64Encode(box.cipherText),
      'tag_b64': base64Encode(box.mac.bytes),
    };
  }

  /// Decrypts an envelope to a JSON Map using [compiledPrefix]+[postfix].
  static Future<Map<String, dynamic>> decrypt({
    required Map<String, dynamic> envelope,
    required String compiledPrefix,
    required String postfix,
  }) async {
    // As in encrypt: the accelerator belongs to the Flutter package, and the
    // shared Pbkdf2Kdf inherits it through the process-global instance.
    crypto.Cryptography.instance =
        crypto_fl.FlutterCryptography.defaultInstance;

    final passphrase = '$compiledPrefix$postfix';

    final salt = base64Decode(envelope['kdf']['salt_b64']);
    final iterations = envelope['kdf']['iterations'] as int;
    final nonce = base64Decode(envelope['cipher']['nonce_b64']);
    final cipherText = base64Decode(envelope['ciphertext_b64']);
    final tag = base64Decode(envelope['tag_b64']);
    final aad = utf8.encode(envelope['aad'] as String);

    // The count comes out of the envelope, not from the current default: an
    // envelope written at 10 iterations must still open after the default
    // changes. This is why the shared derivation takes iterations at all.
    final key = await Pbkdf2Kdf.deriveKey(
      passphrase: passphrase,
      salt: salt,
      iterations: iterations,
    );

    final algo = crypto.AesGcm.with256bits();
    final clear = await algo.decrypt(
      crypto.SecretBox(cipherText, nonce: nonce, mac: crypto.Mac(tag)),
      secretKey: key,
      aad: aad,
    );

    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}

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

class ServerConfigPage extends ConsumerWidget {
  const ServerConfigPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BaseScaffold(
      title: 'Server Configuration',
      body: const ServerConfigBody(),
    );
  }
}

/// The body content of [ServerConfigPage], extracted for testability.
///
/// Contains all server configuration sections (Database, OPC UA, JBTM, Modbus)
/// and the Import/Export card. Separated from [ServerConfigPage] so widget
/// tests can render without the [BaseScaffold] (which requires Beamer routing).
class ServerConfigBody extends ConsumerWidget {
  const ServerConfigBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch a simple counter that gets incremented on import
    final refreshKey = ref.watch(refreshKeyProvider);

    // The saved transport, not the one being edited. Restart-to-apply means
    // the running panel is on whatever was saved, and hiding the four sections
    // the instant a radio button moves would tell the operator the panel had
    // already changed.
    //
    // Absent or still loading reads as direct mode, which is what an
    // unconfigured station runs.
    final gateway = ref.watch(gatewayConfigProvider).valueOrNull ??
        GatewayConfig.defaults;

    // The station's own name, for the direct-mode banner and the gateway
    // section's attribution row — the same string every audit row's `station`
    // column carries.
    final stationName = ref.watch(stationNameProvider);

    return SingleChildScrollView(
      child: Column(
        children: [
          // Which machine this page edits, named, before anything editable.
          // One screen, two targets — silently configuring the wrong one is
          // the failure mode, and this row is the page's answer to it.
          gateway.isGateway
              ? ConfigTargetBanner.backend(name: gateway.url)
              : ConfigTargetBanner.station(name: stationName),
          const SizedBox(height: 16),

          // Which pipe this station runs on. In gateway mode
          // the four sections below are not siblings of it — they are
          // irrelevant, and it is this card that says so.
          TransportModeCard(key: ValueKey('transport_$refreshKey')),
          const SizedBox(height: 16),

          if (!gateway.isGateway) ...[
            // Database Configuration Section
            DatabaseConfigWidget(key: ValueKey('db_$refreshKey')),
            const SizedBox(height: 16),

            // OPC-UA Servers Section
            _OpcUAServersSection(key: ValueKey('opcua_$refreshKey')),
            const SizedBox(height: 16),

            // JBTM M2400 Servers Section
            _JbtmServersSection(key: ValueKey('jbtm_$refreshKey')),
            const SizedBox(height: 16),

            // Modbus TCP Servers Section
            _ModbusServersSection(key: ValueKey('modbus_$refreshKey')),
            const ImportExportCard(),
          ] else ...[
            // The backend's own configuration — the page's second target
            // (ACCESS-04). It sits above the hidden-sections note because it
            // is the thing an administrator opened this page for.
            BackendConfigSection(key: ValueKey('backend_config_$refreshKey')),
            const SizedBox(height: 16),
            const _DirectSectionsHiddenNote(),
          ],
        ],
      ),
    );
  }
}

@riverpod
class RefreshKey extends _$RefreshKey {
  @override
  int build() => 0;

  void increment() => state++;
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

class _OpcUAServersSection extends ConsumerStatefulWidget {
  const _OpcUAServersSection({super.key});
  @override
  ConsumerState<_OpcUAServersSection> createState() =>
      _OpcUAServersSectionState();
}

class _OpcUAServersSectionState extends ConsumerState<_OpcUAServersSection> {
  StateManConfig? _config;
  StateManConfig? _savedConfig;
  bool _isLoading = false;
  String? _error;
  final _rowKeys = _RowKeys();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      _config = await StateManConfig.fromPrefs(
          await ref.read(preferencesProvider.future));
      _savedConfig = _config?.copy();
      _rowKeys.reset(_config?.opcua.length ?? 0);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get _hasUnsavedChanges {
    if (_config == null || _savedConfig == null) return false;
    final currentJson = jsonEncode(_config!.toJson());
    final savedJson = jsonEncode(_savedConfig!.toJson());
    return currentJson != savedJson;
  }

  Future<void> _saveConfig() async {
    if (_config == null) return;

    try {
      await _config!.toPrefs(await ref.read(preferencesProvider.future));
      _savedConfig = await StateManConfig.fromPrefs(
          await ref.read(preferencesProvider.future));
      ref.invalidate(stateManProvider);
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Configuration saved successfully!'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to save configuration: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  Future<void> _addServer() async {
    setState(() {
      _config?.opcua.add(OpcUAConfig());
      _rowKeys.add();
    });
  }

  Future<void> _updateServer(int index, OpcUAConfig server) async {
    setState(() => _config!.opcua[index] = server);
  }

  Future<void> _removeServer(int index) async {
    setState(() {
      _config!.opcua.removeAt(index);
      _rowKeys.removeAt(index);
    });
  }

  /// Drag-and-drop reorder. Order is cosmetic for lookups (keys bind to
  /// servers by alias, not position) but it is the order the operator reads
  /// on this page, in the key-mapping server dropdowns, and the order
  /// [StateMan] brings the clients up in — so it is worth being able to set.
  void _reorderServer(int oldIndex, int newIndex) {
    if (_config == null) return;
    if (!moveInList(_config!.opcua, oldIndex, newIndex)) return;
    setState(() => _rowKeys.reorder(oldIndex, newIndex));
  }

  Widget _buildServerList(StateManConfig config) {
    final stateManAsync = ref.watch(stateManProvider);
    final StateMan? stateMan = stateManAsync.valueOrNull;
    // A one-server list has nothing to reorder, so it gets no drag handles.
    final reorderable = config.opcua.length > 1;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: _reorderServer,
      itemCount: config.opcua.length,
      itemBuilder: (context, index) {
        ClientWrapper? wrapper;
        if (stateMan != null) {
          final server = config.opcua[index];
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
          key: _rowKeys[index],
          server: config.opcua[index],
          onUpdate: (server) => _updateServer(index, server),
          onRemove: () => _removeServer(index),
          connectionStatus: wrapper?.connectionStatus,
          connectionStream: wrapper?.connectionStream,
          // Data-plane health: catches the frozen-session shape where the
          // channel stays formally open but no value ever arrives again,
          // which the event-driven connectionStream can never report.
          effectiveStatus: wrapper?.effectiveStatus,
          effectiveStatusStream: wrapper?.effectiveStatusStream,
          stateManLoading: stateManAsync.isLoading,
          reorderIndex: reorderable ? index : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(FontAwesomeIcons.triangleExclamation,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Error loading configuration: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _loadConfig, child: const Text('Retry')),
              ElevatedButton(
                  onPressed: () => ref
                      .read(preferencesProvider.future)
                      .then((value) =>
                          value.remove(StateManConfig.configKey, secret: true))
                      .then((value) => _loadConfig()),
                  child: const Text('Delete saved configuration')),
            ],
          ),
        ),
      );
    }

    final config = _config ?? StateManConfig(opcua: []);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ServerSectionHeader(
              title: 'OPC-UA Servers',
              icon: FontAwesomeIcons.server,
              hasUnsavedChanges: _hasUnsavedChanges,
              onAdd: _addServer,
            ),
            const SizedBox(height: 16),
            config.opcua.isEmpty
                ? const SizedBox(
                    height: 200,
                    child: _EmptyServersPlaceholder(
                      icon: FontAwesomeIcons.server,
                      title: 'No servers configured',
                      subtitle: 'Add your first OPC-UA server to get started',
                    ),
                  )
                : _buildServerList(config),
            const SizedBox(height: 16),
            if (config.opcua.isNotEmpty || _hasUnsavedChanges)
              _SaveConfigButton(
                hasUnsavedChanges: _hasUnsavedChanges,
                onSave: _saveConfig,
              ),
          ],
        ),
      ),
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

// ===================== Transport Mode =====================

/// Which pipe this station runs on, and where the far end is.
///
/// **A mode switch, not a fifth section.** In gateway mode this panel opens no
/// OPC UA session, no Modbus socket and no collector, so three of the four
/// sections below it are not another thing to configure — they are inert. This
/// card therefore sits above them and `ServerConfigBody` hides them behind it.
///
/// **The fourth is Postgres, and it is still open.** A gateway-mode panel holds
/// one Postgres connection, for sign-in, preferences and the audit trail. That
/// is measured rather than assumed: the rig ran a panel in gateway mode and
/// found the connection to `172.18.0.6:5432` live throughout
/// (13-RIG-E2E-EVIDENCE FIND-C), and `lib/providers/database.dart` has no
/// transport branch that could close it. The database section is hidden anyway
/// because the address it configures is a *plant* setting an operator standing
/// at a gateway panel is not the person to change — not because nothing uses
/// it. Moving access, preferences and audit onto the relay is Phase 17; until
/// then this doc says what the panel actually opens, and
/// `test/core/gateway_copy_test.dart` keeps the old wording from coming back.
///
/// **Device-local, and that is why it does not save where its neighbours do.**
/// Every other section on this page writes through `preferencesProvider`, the
/// shared, DB-backed store, so that one machine can configure the plant. A
/// gateway URL must not travel that way for the same reason a Postgres address
/// must not: two stations reach the same service at different addresses, and
/// the sync would re-point one from the other. It writes through
/// `localPreferencesProvider` instead.
///
/// **Restart to apply**, deliberately, and the card says so after every save.
/// Swapping transport live means tearing down OPC UA sessions and a database
/// pool while widgets hold subscriptions against them.
class TransportModeCard extends ConsumerStatefulWidget {
  const TransportModeCard({super.key});

  @override
  ConsumerState<TransportModeCard> createState() => _TransportModeCardState();
}

class _TransportModeCardState extends ConsumerState<TransportModeCard> {
  /// What is on disk. `null` until the first read completes.
  GatewayConfig? _saved;

  /// What the operator has typed. Diffed against [_saved] for the save button.
  GatewayConfig _edited = GatewayConfig.defaults;

  /// A read is in flight. Bounded by [_load]'s `finally`, which is the whole
  /// difference between a spinner and a permanent spinner.
  bool _isLoading = true;

  /// Why the device-local row could not be read, or null.
  String? _error;

  /// Why the last Save's trust fetch failed, or null. Rendered in the card —
  /// the operator is standing at it — and cleared by the next edit or the
  /// next attempt.
  String? _trustError;

  /// A Save (which may include a fetch and a dialog) is in flight. Guards
  /// re-entry only; the button's visuals stay the three-state switch below.
  bool _saving = false;

  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Started once, here, and never from `build`. It used to be called from
    // inside `build` with its future discarded (15-RESEARCH P-7): a throw out
    // of `prefs.getString` — a device-local store that will not answer, which
    // is a real station condition — left `_saved` null, so the card rebuilt to
    // the spinner, called `_load` again, and spun forever while the rejection
    // went to the ambient error handler. Nothing on screen ever said anything.
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// Reads the device-local transport row.
  ///
  /// The shape is `_JbtmServersSectionState._loadConfig`'s, deliberately: set
  /// loading, `try`, catch into [_error], and clear the flag in a `finally` so
  /// there is no path out of this method that leaves the card claiming a read
  /// is still in flight.
  ///
  /// [refresh] invalidates the provider first. Without it a Retry re-reads the
  /// *cached rejection* — `FutureProvider` holds its error — and the button
  /// would be a refusal with a dead retry on it, which is a spinner with extra
  /// steps.
  Future<void> _load({bool refresh = false}) async {
    if (refresh) ref.invalidate(gatewayConfigProvider);
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final loaded = await ref.read(gatewayConfigProvider.future);
      if (!mounted) return;
      _urlController.text = loaded.url;
      _tokenController.text = loaded.tokenPath ?? '';
      _saved = loaded;
      _edited = loaded;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get _hasUnsavedChanges => _saved != null && _edited != _saved;

  /// Saves — and on a `wss` address with nothing pinned, Save IS the trust
  /// ceremony: fetch the gateway's identity, show the fingerprint, and write
  /// only on Approve. Reject and a failed fetch write nothing at all: a
  /// half-saved row (URL yes, trust no) would boot the panel into exactly the
  /// notBuilt state the ceremony exists to prevent.
  ///
  /// The other trust path is silent by design: a legacy `caCertPath` row
  /// migrates its file's bytes into pinned material here
  /// ([GatewayConfig.migrateLegacyTrust]) — same bytes the station already
  /// dialled under every day, so no new trust decision is being made and no
  /// dialog would have anything to ask.
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _trustError = null;
    });
    try {
      var next = _edited;
      if (next.needsTrustAcquisition) {
        final FetchedGatewayTrust trust;
        try {
          trust = await ref.read(gatewayTrustFetcherProvider)(next.uri);
        } on GatewayTrustException catch (error) {
          if (!mounted) return;
          setState(() => _trustError = error.message);
          return;
        }
        if (!mounted) return;
        final approved = await showGatewayIdentityDialog(
          context,
          gateway: next.uri,
          fingerprint: trust.sha256Fingerprint,
        );
        if (!approved || !mounted) return;
        next = next.copyWith(caPem: trust.caPem);
      } else {
        next = next.migrateLegacyTrust();
      }
      await writeGatewayConfig(ref.read(localPreferencesProvider), next);
      ref.invalidate(gatewayConfigProvider);
      if (!mounted) return;
      setState(() {
        _saved = next;
        _edited = next;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transport saved. Restart the HMI to apply it.'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _edit(GatewayConfig next) => setState(() {
        _edited = next;
        // A stale fetch refusal over a corrected address would read as the
        // correction having failed too.
        _trustError = null;
      });

  /// What the pinned material fingerprints as — or the honest sentence when a
  /// hand-edited row does not parse. Never a throw into `build`.
  String _pinnedFingerprint(String pem) {
    try {
      return caFingerprintSha256(pem);
    } on GatewayTrustException {
      return 'not a certificate — Forget this and save again';
    }
  }

  @override
  Widget build(BuildContext context) {
    // The live link, or null. Watched here rather than through a nested
    // `Consumer` because `package:basic_utils` — imported by this file for
    // certificate parsing — also exports a `Consumer`, and an `as prefix` on
    // one of two whole-library imports to place one builder is a worse trade
    // than one extra rebuild of a card that already calls `setState` on every
    // keystroke.
    //
    // The provider consults the *saved* transport first and short-circuits to
    // null in direct mode before it ever reads `stateManProvider`, so a direct
    // station cannot grow a status row by accident. Null renders as absence.
    final linkReport = ref.watch(gatewayLinkProvider).valueOrNull;

    // The refusal frame, copied from `_JbtmServersSectionState.build`. A card
    // that cannot read its own settings has to say so: the operator can act on
    // "the store did not answer" and can act on nothing at all when the same
    // condition is drawn as a spinner.
    final error = _error;
    if (error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(FontAwesomeIcons.triangleExclamation,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Could not read this station\'s transport setting: $error'),
              const SizedBox(height: 8),
              Text(
                'The panel is running on whatever transport it read at boot. '
                'Until this row can be read, it cannot be changed here.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => _load(refresh: true),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final saved = _saved;
    if (saved == null || _isLoading) {
      // Genuinely still reading, and bounded: `_load`'s `finally` clears the
      // flag on every path, including the throwing one, which lands on the
      // frame above rather than here.
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final refusal = _edited.validationError;
    // Deliberately NOT `refusal`, and deliberately not folded into it. See the
    // comment on the save button below and `GatewayConfig.advisory`'s own doc.
    final advisory = _edited.advisory;

    // The save button is this card's ONE indicator of unsaved state — the
    // trailing `Unsaved` pill it used to duplicate is gone by owner ruling
    // (a second spelling of one fact). That promotion comes with the pill's
    // legibility obligation: with `backgroundColor: null` the M3 defaults
    // resolve the unsaved label to `primary` on `surfaceContainerLow`, which
    // in solarized light is green #859900 on cream base2 — 2.62:1, under
    // WCAG 1.4.11's 3:1 floor for UI components. So the unsaved face wears
    // the pill's ratified treatment instead: [HmiStateColors.yellow] —
    // attention, not alarm; only fault red may be saturated — as a 30-alpha
    // tint over the card, with the label split on brightness for the reason
    // `AlarmColors.onSignal` exists: both schemes' yellows are mid-luminance,
    // readable as ink on a dark card and far too dim on a cream one, where
    // `onSurface` carries the label and the tint carries the colour. The
    // tint is pre-blended over the card so the button's `Material` stays
    // opaque under its elevation. Ratios are pinned per theme by
    // `server_config_save_button_unsaved_state_test.dart`.
    final theme = Theme.of(context);
    final canSave = _hasUnsavedChanges && refusal == null;
    final attention = HmiStateColors.of(context).yellow;
    final unsavedInk = theme.brightness == Brightness.dark
        ? attention
        : theme.colorScheme.onSurface;
    final unsavedFill = Color.alphaBlend(
        attention.withAlpha(30),
        theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow);

    // Collapsed by default in direct mode — the shape `McpServerSection`
    // already uses for a device-local setting, and the reason is not only
    // consistency: an expanded card here pushes the four sections down the
    // page on every station in the plant, for a setting almost none of them
    // will ever change.
    return Card(
      child: ExpansionTile(
        leading: const FaIcon(FontAwesomeIcons.networkWired, size: 20),
        title: const Text('Transport'),
        subtitle: Text(saved.isGateway
            ? 'Relay gateway — ${saved.url}'
            : 'Direct to PLCs'),
        // A gateway station opens on its own settings; a direct one does not
        // have any to show.
        initiallyExpanded: saved.isGateway,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This setting belongs to this station only. It is never '
            'exported, imported or synced from another machine.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          SegmentedButton<TransportMode>(
            segments: const [
              ButtonSegment(
                value: TransportMode.direct,
                label: Text('Direct to PLCs'),
                icon: FaIcon(FontAwesomeIcons.plug, size: 14),
              ),
              ButtonSegment(
                value: TransportMode.gateway,
                label: Text('Relay gateway'),
                icon: FaIcon(FontAwesomeIcons.towerBroadcast, size: 14),
              ),
            ],
            selected: {_edited.mode},
            onSelectionChanged: (selection) =>
                _edit(_edited.copyWith(mode: selection.first)),
          ),
          const SizedBox(height: 12),
          if (_edited.isGateway) ...[
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Gateway address',
                hintText: 'wss://10.50.10.11:9443',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => _edit(_edited.copyWith(url: value)),
            ),
            const SizedBox(height: 12),
            // The trust line — what replaced the "PEM path" field ("how do I
            // obtain pem path, and what is that"). Three states, one visible
            // at a time: pinned material with its fingerprint and a Forget;
            // a legacy provisioned file, named until the next save migrates
            // it; or the promise of the fetch-and-approve ceremony. Nothing
            // here is an input.
            if (_edited.caPem != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FaIcon(FontAwesomeIcons.certificate, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Pinned plant CA'),
                        Text(
                          'SHA-256 ${_pinnedFingerprint(_edited.caPem!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    // An edit, not a write: the pin actually goes when the
                    // operator saves — and that save runs the ceremony
                    // again, which is the deliberate path for a genuinely
                    // re-keyed plant. A changed CA never re-prompts on a
                    // connection; it is refused there.
                    onPressed: () =>
                        _edit(_edited.copyWith(clearCaPem: true)),
                    child: const Text('Forget'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ] else if (_edited.caCertPath != null) ...[
              Text(
                'Trusting CA file: ${_edited.caCertPath} — saving will pin '
                'its contents to this station.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
            ] else if (_edited.needsTrustAcquisition) ...[
              Text(
                'No plant CA pinned yet — Save fetches the gateway\'s '
                'identity for your approval.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
            ],
            // Legacy-only: the station-token work is removing the credential
            // file entirely, so the field renders solely on a station whose
            // saved row still carries one — anywhere else it would be a
            // second unanswerable question on a card that just lost its
            // first. Kept visible while a value exists so the ws:// refusal
            // that names it stays clearable.
            if (_saved?.tokenPath != null || _edited.tokenPath != null) ...[
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'Station credential file (legacy)',
                  helperText: 'A file holding this station\'s token. Clear '
                      'it when the gateway runs no token file.',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => _edit(_edited.copyWith(
                  tokenPath: value.trim().isEmpty ? null : value.trim(),
                  clearTokenPath: value.trim().isEmpty,
                )),
              ),
              const SizedBox(height: 12),
            ],
            // The trust fetch's own refusal, beside the fields like the
            // validation refusal below: the operator who tapped Save is
            // standing here, not at a log.
            if (_trustError != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _trustError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            // A warning, in a warning's voice, and visibly not the refusal
            // below it. `HmiStateColors.yellow` is the repo's manual/attention
            // colour; `colorScheme.error` is what a refusal wears, and wearing
            // it here would tell the operator the configuration is rejected
            // when it is about to be saved.
            if (advisory != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: HmiStateColors.of(context).yellow),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      advisory,
                      style:
                          TextStyle(color: HmiStateColors.of(context).yellow),
                    ),
                  ),
                ],
              ),
            if (advisory != null) const SizedBox(height: 12),
            if (refusal != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      refusal,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            if (refusal != null) const SizedBox(height: 12),
          ],
          // The live link, under the address field and the trust line, where
          // an operator who has just typed the address is standing.
          //
          // Outside the `_edited.isGateway` block on purpose: a link that is
          // live right now must not vanish because a radio button moved and has
          // not been saved yet. The guard is the provider's null and nothing
          // else — see the note at the top of `build`.
          //
          // Nothing is rendered while the provider is still resolving. Not a
          // spinner: `access_status_action.dart:44-51` gives the reason, and
          // this surface rebuilds on every keystroke in the field above.
          if (linkReport != null) ...[
            GatewayLinkStatusRow(report: linkReport),
            const SizedBox(height: 12),
          ],
          // **`advisory` is not in this condition and must never be added to
          // it, nor to the label switch below.** The two states are
          // `_hasUnsavedChanges` and `refusal`, where `refusal` is
          // `validationError` alone. A hostname advisory says the certificate
          // *may* not carry a SAN for the name that was typed; a plant that
          // provisions DNS SANs is perfectly legitimate, and refusing to save
          // its configuration would make this card wrong for that whole plant.
          // `test/pages/server_config_transport_mode_test.dart`'s "a wss dial
          // by name shows the advisory and Save stays enabled" is the arm that
          // notices if somebody folds it in.
          //
          // Not `_SaveConfigButton`: that one has two states and this has
          // three. A configuration that cannot be dialled is not saveable —
          // the panel would construct nothing at the next boot and show a
          // start-up error instead of the message the operator can read
          // right here — but calling that state "All Changes Saved" would be
          // a lie about work the operator has just done and can still see on
          // screen.
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: canSave ? _save : null,
                  icon: FaIcon(FontAwesomeIcons.floppyDisk,
                      size: 16, color: canSave ? unsavedInk : Colors.grey),
                  label: Text(switch ((_hasUnsavedChanges, refusal)) {
                    (false, _) => 'All Changes Saved',
                    (true, final String _) => 'Cannot save yet',
                    (true, _) => 'Save Configuration',
                  }),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    foregroundColor: canSave ? unsavedInk : null,
                    backgroundColor: canSave ? unsavedFill : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Changing the transport takes effect when the HMI restarts.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// What sits where the four direct-mode sections were.
///
/// An empty space would read as a page that failed to load. This says which
/// decision removed them and how to get them back.
///
/// **It used to claim the station held nothing but the relay socket, and that
/// its database settings were the gateway's. Both were false**, and the exact
/// sentences are not quoted here because the scan in
/// `test/core/gateway_copy_test.dart` is literal and a quotation would make it
/// a question nobody could answer. Read them out of this file's history. The rig
/// ran a panel in gateway mode and measured one Postgres connection to
/// `172.18.0.6:5432` live for the whole run, carrying sign-in, preferences and
/// the audit trail (13-RIG-E2E-EVIDENCE FIND-C); `lib/providers/database.dart`
/// has no transport branch that could close it, and the database address is
/// this station's own, not the gateway's. An operator who read the old note and
/// then found a Postgres session on the panel would have had no reason to trust
/// anything else this page said. Closing the dependency for real — access,
/// preferences and audit over the relay — is Phase 17.
class _DirectSectionsHiddenNote extends StatelessWidget {
  const _DirectSectionsHiddenNote();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FaIcon(FontAwesomeIcons.circleInfo, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'This station takes its values from the relay gateway: no '
                'OPC UA session, no Modbus socket, no collector. Those '
                'settings belong to the gateway and are configured there.\n\n'
                'It still opens one Postgres connection, for sign-in, '
                'preferences and the audit trail. That database is shared '
                'with the rest of the plant and its address is configured '
                'elsewhere, so the section is hidden here rather than gone.\n\n'
                'Switch back to Direct to PLCs to edit them all here.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== Backend Configuration (gateway target) ==============

/// The one relay client's [BackendConfigApi], for a station in gateway mode.
///
/// The shape is `accessTemplateStoreProvider`'s (17-12), on purpose: the
/// backend's config is reached through the ONE client the panel already
/// holds — a second client would be a second socket, a second session and a
/// second identity in the revocation sweep. `ref.watch`, never `ref.read`,
/// on the config AND the StateMan: `alarm.dart:45` records what `ref.read`
/// behind a `keepAlive` cost — a stale transport over a disposed client whose
/// streams CLOSE rather than error, so nothing reported it (the Phase 14
/// blocker).
final backendConfigApiProvider = FutureProvider<BackendConfigApi>((ref) async {
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (!gateway.isGateway) {
    // Refuse by name rather than answer null: direct mode has no backend
    // target, and nothing on a direct station may read this provider — the
    // page branches before it ever would.
    throw StateError(
        'backendConfigApiProvider is a gateway-mode surface: a direct '
        'station edits its own StateManConfig through preferencesProvider, '
        'and this page never reads the backend\'s from direct mode.');
  }
  final stateMan = await ref.watch(stateManProvider.future);
  final remote = stateMan is GuardedStateMan
      ? stateMan.innerAs<GatewayStateMan>()?.remote
      : null;
  if (remote == null) {
    // Refuse by name, exactly as the 17-12 stores do: a silent fallback here
    // is how a second route quietly appears, and a route that exists will be
    // taken.
    throw UnsupportedError(
        'backendConfigApiProvider is not available: this station resolved a '
        'StateMan with no relay client behind it. Fix the gateway branch of '
        'lib/providers/state_man.dart — do not fall back to anything here.');
  }
  return remote.backendConfig;
});

/// The editable half of the backend's configuration document.
const Key kBackendConfigEditorKey = Key('backend_config_editor');

/// The `relay` section, rendered and not editable (D-10).
const Key kBackendConfigRelayFieldKey = Key('backend_config_relay_field');

/// The section's own save button — its ONE unsaved-state indicator, the same
/// ruling the Transport card's save button carries.
const Key kBackendConfigSaveKey = Key('backend_config_save');

/// The way back: present only while the backend reports a previous document.
const Key kBackendConfigRestoreKey = Key('backend_config_restore');

/// The backend's refusal, in the backend's own words.
const Key kBackendConfigRefusalKey = Key('backend_config_refusal');

/// Who a save is recorded against — a station account, named as one.
const Key kBackendConfigAttributionKey = Key('backend_config_attribution');

/// Restart-to-apply, said where the save happens.
const Key kBackendConfigRestartNoteKey = Key('backend_config_restart_note');

/// The backend's `StateManConfig`, editable from a gateway-mode panel —
/// except for the section that carries the edit (ACCESS-04, D-10).
///
/// Reads come from `backendConfig.read`, saves go to `backendConfig.write`;
/// nothing here touches this station's own preferences. The check, the audit
/// row and the validation live at the far end (17-09/17-10); this card is the
/// screen for them and adds no second policy.
class BackendConfigSection extends ConsumerStatefulWidget {
  const BackendConfigSection({super.key});

  @override
  ConsumerState<BackendConfigSection> createState() =>
      _BackendConfigSectionState();
}

class _BackendConfigSectionState extends ConsumerState<BackendConfigSection> {
  BackendConfigApi? _api;
  BackendConfigDocument? _doc;

  /// Why the backend's config could not be read, or null.
  String? _loadError;
  bool _isLoading = true;

  /// The refusal of the last save or restore, verbatim from the far end —
  /// the parser's sentence for an invalid document, D-10's for a relay-
  /// section edit. This card composes no refusal prose of its own: a
  /// paraphrase is a second place the two refusals could start reading the
  /// same.
  String? _refusalText;

  final _editorController = TextEditingController();

  /// The editable text as it was last loaded, for the save button's unsaved
  /// diff.
  String _loadedEditableText = '';

  /// The read-only sections of the live document, decoded, re-attached
  /// verbatim on save so the document that crosses is whole. Only sections
  /// the operator's editable text does not itself carry are re-attached — a
  /// differing `relay` typed into the editor crosses as typed and is refused
  /// by name at the far end, which is the honest path for it.
  Map<String, Object?> _readOnlyLive = const {};

  /// One controller per read-only section's disabled field, owned here so
  /// they are disposed rather than re-minted every build.
  final Map<String, TextEditingController> _readOnlyControllers = {};

  @override
  void initState() {
    super.initState();
    _editorController.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _editorController.dispose();
    for (final controller in _readOnlyControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The operator-facing sentence for [error]. A protocol refusal carries the
  /// far end's message; anything else is shown as what it is.
  static String _describe(Object error) =>
      error is rpc.RpcException ? error.message : error.toString();

  Future<void> _load({bool refresh = false}) async {
    if (refresh) ref.invalidate(backendConfigApiProvider);
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final api = await ref.read(backendConfigApiProvider.future);
      final doc = await relayedAccessErrors(api.read);
      if (!mounted) return;
      _api = api;
      _applyDocument(doc);
    } on Object catch (e) {
      _loadError = _describe(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Splits [doc] into the editable text and the read-only sections.
  ///
  /// The document travels as text; splitting it needs a decode, and the
  /// re-encode below is the same trade 17-10's redaction already made —
  /// showing the read-only sections greyed wins over preserving the byte
  /// layout of a file the backend re-parses anyway.
  void _applyDocument(BackendConfigDocument doc) {
    _doc = doc;
    Map<String, Object?>? decoded;
    try {
      final raw = jsonDecode(doc.configJson);
      if (raw is Map<String, dynamic>) decoded = raw;
    } on FormatException {
      decoded = null;
    }
    if (decoded == null) {
      // A document this station cannot decode is still the backend's truth:
      // show it whole and let the far end's parser own any refusal.
      _readOnlyLive = const {};
      for (final controller in _readOnlyControllers.values) {
        controller.dispose();
      }
      _readOnlyControllers.clear();
      _loadedEditableText = doc.configJson;
    } else {
      const encoder = JsonEncoder.withIndent('  ');
      final readOnly = doc.readOnlySections.toSet();
      final editable = <String, Object?>{
        for (final entry in decoded.entries)
          if (!readOnly.contains(entry.key)) entry.key: entry.value,
      };
      _readOnlyLive = <String, Object?>{
        for (final entry in decoded.entries)
          if (readOnly.contains(entry.key)) entry.key: entry.value,
      };
      for (final entry in _readOnlyLive.entries) {
        _readOnlyControllers
            .putIfAbsent(entry.key, TextEditingController.new)
            .text = encoder.convert(entry.value);
      }
      _readOnlyControllers.removeWhere((name, controller) {
        if (_readOnlyLive.containsKey(name)) return false;
        controller.dispose();
        return true;
      });
      _loadedEditableText = encoder.convert(editable);
    }
    _editorController.text = _loadedEditableText;
    setState(() {});
  }

  bool get _hasUnsavedChanges =>
      _doc != null && _editorController.text != _loadedEditableText;

  /// The document that crosses: the operator's editable sections plus the
  /// live read-only sections they cannot have typed. `putIfAbsent`, not a
  /// blind spread — a read-only section the operator somehow smuggled into
  /// the editable text must cross as typed and be refused by name at the far
  /// end, not be silently papered over here.
  String _payload() {
    final text = _editorController.text;
    try {
      final edited = jsonDecode(text);
      if (edited is! Map<String, dynamic>) return text;
      final merged = <String, Object?>{...edited};
      for (final entry in _readOnlyLive.entries) {
        merged.putIfAbsent(entry.key, () => entry.value);
      }
      return jsonEncode(merged);
    } on FormatException {
      // Not decodable here — sent as typed, so the refusal the operator
      // reads is the parser's own sentence rather than this card's guess.
      return text;
    }
  }

  Future<void> _save() async {
    final backendConfig = _api;
    if (backendConfig == null) return;
    setState(() => _refusalText = null);
    try {
      await relayedAccessErrors(() => backendConfig.write(_payload()));
      final doc = await relayedAccessErrors(backendConfig.read);
      if (!mounted) return;
      _applyDocument(doc);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved to the backend. It applies the new '
              'configuration when it restarts.'),
          backgroundColor: Colors.green,
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _refusalText = _describe(e));
    }
  }

  Future<void> _restore() async {
    final backendConfig = _api;
    if (backendConfig == null) return;
    try {
      await relayedAccessErrors(() => backendConfig.restorePrevious());
      final doc = await relayedAccessErrors(backendConfig.read);
      if (!mounted) return;
      _refusalText = null;
      _applyDocument(doc);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _refusalText = _describe(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stationName = ref.watch(stationNameProvider);

    final loadError = _loadError;
    if (loadError != null) {
      // The refusal frame, in the shape every section on this page uses: a
      // card that cannot read what it edits has to say so, with a retry.
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(FontAwesomeIcons.triangleExclamation,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('Could not read the backend\'s configuration: $loadError'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => _load(refresh: true),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final doc = _doc;
    if (doc == null || _isLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const FaIcon(FontAwesomeIcons.server, size: 20),
                const SizedBox(width: 8),
                Text('Backend Configuration',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'These are the backend\'s own settings, read and saved over '
              'the relay connection. This station\'s transport is the card '
              'above, and its sign-in database is unchanged by anything '
              'saved here.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              key: kBackendConfigEditorKey,
              controller: _editorController,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'Backend configuration (JSON)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            for (final entry in _readOnlyControllers.entries) ...[
              TextField(
                key: entry.key == 'relay'
                    ? kBackendConfigRelayFieldKey
                    : Key('backend_config_readonly_${entry.key}'),
                controller: entry.value,
                enabled: false,
                maxLines: null,
                decoration: InputDecoration(
                  labelText: '${entry.key} — read-only from here',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Changing the ${entry.key} port or its TLS from here would '
                'cut this screen off mid-change, so this section is changed '
                'on the machine the backend runs on.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
            ],
            if (_refusalText != null) ...[
              Row(
                key: kBackendConfigRefusalKey,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _refusalText!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (doc.hasPrevious) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: kBackendConfigRestoreKey,
                      onPressed: _restore,
                      icon: const FaIcon(FontAwesomeIcons.clockRotateLeft,
                          size: 14),
                      label: const Text('Restore previous configuration'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              key: kBackendConfigAttributionKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.desktop_windows, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'A save here is recorded against the account the gateway '
                    'verified for this station ($stationName) — a station '
                    'account, not a person.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    key: kBackendConfigSaveKey,
                    onPressed: _hasUnsavedChanges ? _save : null,
                    icon: FaIcon(FontAwesomeIcons.floppyDisk,
                        size: 16,
                        color: _hasUnsavedChanges ? null : Colors.grey),
                    label: Text(_hasUnsavedChanges
                        ? 'Save Configuration'
                        : 'All Changes Saved'),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor:
                            _hasUnsavedChanges ? null : Colors.grey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              key: kBackendConfigRestartNoteKey,
              'A saved configuration takes effect when the backend restarts. '
              'The backend does not restart itself, and nothing on this '
              'screen changes until it has.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Section header with icon, title, unsaved badge, and add button.
///
/// Used by OPC UA, JBTM, and Modbus server config sections to show
/// a responsive header row that collapses on narrow screens.
class _ServerSectionHeader extends StatelessWidget {
  final String title;
  final FaIconData icon;
  final bool hasUnsavedChanges;
  final VoidCallback onAdd;

  const _ServerSectionHeader({
    required this.title,
    required this.icon,
    required this.hasUnsavedChanges,
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
                  if (hasUnsavedChanges) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.orange,
                          borderRadius: BorderRadius.circular(12)),
                      child: const Text('Unsaved',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
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
            if (hasUnsavedChanges) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(12)),
                child: const Text('Unsaved Changes',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
            ],
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

  const _SaveConfigButton({
    required this.hasUnsavedChanges,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
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

// ===================== JBTM M2400 Servers Section =====================

class _JbtmServersSection extends ConsumerStatefulWidget {
  const _JbtmServersSection({super.key});
  @override
  ConsumerState<_JbtmServersSection> createState() =>
      _JbtmServersSectionState();
}

class _JbtmServersSectionState extends ConsumerState<_JbtmServersSection> {
  StateManConfig? _config;
  StateManConfig? _savedConfig;
  bool _isLoading = false;
  String? _error;
  final _rowKeys = _RowKeys();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      _config = await StateManConfig.fromPrefs(
          await ref.read(preferencesProvider.future));
      _savedConfig = _config?.copy();
      _rowKeys.reset(_config?.jbtm.length ?? 0);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get _hasUnsavedChanges {
    if (_config == null || _savedConfig == null) return false;
    final currentJson = jsonEncode(_config!.toJson());
    final savedJson = jsonEncode(_savedConfig!.toJson());
    return currentJson != savedJson;
  }

  Future<void> _saveConfig() async {
    if (_config == null) return;

    try {
      await _config!.toPrefs(await ref.read(preferencesProvider.future));
      _savedConfig = await StateManConfig.fromPrefs(
          await ref.read(preferencesProvider.future));
      ref.invalidate(stateManProvider);
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('JBTM configuration saved successfully!'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to save JBTM configuration: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  void _addServer() {
    setState(() {
      _config?.jbtm.add(M2400Config(host: 'localhost', port: 52211));
      _rowKeys.add();
    });
  }

  /// See [_OpcUAServersSectionState._reorderServer].
  void _reorderServer(int oldIndex, int newIndex) {
    if (_config == null) return;
    if (!moveInList(_config!.jbtm, oldIndex, newIndex)) return;
    setState(() => _rowKeys.reorder(oldIndex, newIndex));
  }

  Widget _buildJbtmServerList(StateManConfig config) {
    final stateManAsync = ref.watch(stateManProvider);
    final StateMan? stateMan = stateManAsync.valueOrNull;
    final reorderable = config.jbtm.length > 1;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: _reorderServer,
      itemCount: config.jbtm.length,
      itemBuilder: (context, index) {
        M2400DeviceClientAdapter? adapter;
        if (stateMan != null) {
          final server = config.jbtm[index];
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
          key: _rowKeys[index],
          server: config.jbtm[index],
          onUpdate: (server) => _updateServer(index, server),
          onRemove: () => _removeServer(index),
          connectionStatus: adapter?.connectionStatus,
          connectionStream: adapter?.connectionStream,
          stateManLoading: stateManAsync.isLoading,
          reorderIndex: reorderable ? index : null,
        );
      },
    );
  }

  void _updateServer(int index, M2400Config server) {
    setState(() => _config!.jbtm[index] = server);
  }

  void _removeServer(int index) {
    setState(() {
      _config!.jbtm.removeAt(index);
      _rowKeys.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(FontAwesomeIcons.triangleExclamation,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Error loading JBTM configuration: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _loadConfig, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final config = _config ?? StateManConfig(opcua: []);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ServerSectionHeader(
              title: 'JBTM M2400 Servers',
              icon: FontAwesomeIcons.scaleBalanced,
              hasUnsavedChanges: _hasUnsavedChanges,
              onAdd: _addServer,
            ),
            const SizedBox(height: 16),
            config.jbtm.isEmpty
                ? const SizedBox(
                    height: 200,
                    child: _EmptyServersPlaceholder(
                      icon: FontAwesomeIcons.scaleBalanced,
                      title: 'No JBTM servers configured',
                      subtitle:
                          'Add your first JBTM M2400 server to get started',
                    ),
                  )
                : _buildJbtmServerList(config),
            const SizedBox(height: 16),
            if (config.jbtm.isNotEmpty || _hasUnsavedChanges)
              _SaveConfigButton(
                hasUnsavedChanges: _hasUnsavedChanges,
                onSave: _saveConfig,
              ),
          ],
        ),
      ),
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

  const _JbtmServerConfigCard({
    super.key,
    required this.server,
    required this.onUpdate,
    required this.onRemove,
    this.connectionStatus,
    this.connectionStream,
    this.stateManLoading = false,
    this.reorderIndex,
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
            ConnectionStatusChip(
              status: _connectionStatus,
              stateManLoading: widget.stateManLoading,
              disabled: !widget.server.enabled,
            ),
            const SizedBox(width: 4),
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

// ===================== Modbus TCP Servers Section =====================

class _ModbusServersSection extends ConsumerStatefulWidget {
  const _ModbusServersSection({super.key});
  @override
  ConsumerState<_ModbusServersSection> createState() =>
      _ModbusServersSectionState();
}

class _ModbusServersSectionState extends ConsumerState<_ModbusServersSection> {
  StateManConfig? _config;
  StateManConfig? _savedConfig;
  bool _isLoading = false;
  String? _error;
  final _rowKeys = _RowKeys();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      _config = await StateManConfig.fromPrefs(
          await ref.read(preferencesProvider.future));
      _savedConfig = _config?.copy();
      _rowKeys.reset(_config?.modbus.length ?? 0);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get _hasUnsavedChanges {
    if (_config == null || _savedConfig == null) return false;
    final currentJson = jsonEncode(_config!.toJson());
    final savedJson = jsonEncode(_savedConfig!.toJson());
    return currentJson != savedJson;
  }

  Future<void> _saveConfig() async {
    if (_config == null) return;

    try {
      await _config!.toPrefs(await ref.read(preferencesProvider.future));
      _savedConfig = await StateManConfig.fromPrefs(
          await ref.read(preferencesProvider.future));
      ref.invalidate(stateManProvider);
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Modbus configuration saved successfully!'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to save Modbus configuration: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    }
  }

  void _addServer() {
    setState(() {
      _config?.modbus.add(ModbusConfig(
        host: 'localhost',
        port: 502,
        unitId: 1,
        pollGroups: [ModbusPollGroupConfig(name: 'default', intervalMs: 1000)],
      ));
      _rowKeys.add();
    });
  }

  /// See [_OpcUAServersSectionState._reorderServer].
  void _reorderServer(int oldIndex, int newIndex) {
    if (_config == null) return;
    if (!moveInList(_config!.modbus, oldIndex, newIndex)) return;
    setState(() => _rowKeys.reorder(oldIndex, newIndex));
  }

  Widget _buildModbusServerList(StateManConfig config) {
    final stateManAsync = ref.watch(stateManProvider);
    final StateMan? stateMan = stateManAsync.valueOrNull;
    final reorderable = config.modbus.length > 1;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: _reorderServer,
      itemCount: config.modbus.length,
      itemBuilder: (context, index) {
        ModbusDeviceClientAdapter? adapter;
        if (stateMan != null) {
          final server = config.modbus[index];
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
          key: _rowKeys[index],
          server: config.modbus[index],
          onUpdate: (server) => _updateServer(index, server),
          onRemove: () => _removeServer(index),
          connectionStatus: adapter?.connectionStatus,
          connectionStream: adapter?.connectionStream,
          // TD-004 (v1.1.x): combined TCP + UMAS health stream so the
          // chip surfaces a broken UMAS session as `umasUnhealthy`.
          effectiveStatus: adapter?.effectiveStatus,
          effectiveStatusStream: adapter?.effectiveStatusStream,
          stateManLoading: stateManAsync.isLoading,
          reorderIndex: reorderable ? index : null,
        );
      },
    );
  }

  void _updateServer(int index, ModbusConfig server) {
    setState(() => _config!.modbus[index] = server);
  }

  void _removeServer(int index) {
    setState(() {
      _config!.modbus.removeAt(index);
      _rowKeys.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FaIcon(FontAwesomeIcons.triangleExclamation,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Error loading Modbus configuration: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _loadConfig, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final config = _config ?? StateManConfig(opcua: []);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ServerSectionHeader(
              title: 'Modbus TCP Servers',
              icon: FontAwesomeIcons.networkWired,
              hasUnsavedChanges: _hasUnsavedChanges,
              onAdd: _addServer,
            ),
            const SizedBox(height: 16),
            config.modbus.isEmpty
                ? const SizedBox(
                    height: 200,
                    child: _EmptyServersPlaceholder(
                      icon: FontAwesomeIcons.networkWired,
                      title: 'No Modbus servers configured',
                      subtitle:
                          'Add your first Modbus TCP server to get started',
                    ),
                  )
                : _buildModbusServerList(config),
            const SizedBox(height: 16),
            if (config.modbus.isNotEmpty || _hasUnsavedChanges)
              _SaveConfigButton(
                hasUnsavedChanges: _hasUnsavedChanges,
                onSave: _saveConfig,
              ),
          ],
        ),
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
            ConnectionStatusChip(
              status: _connectionStatus,
              effectiveStatus: _umasEnabled ? _effectiveStatus : null,
              stateManLoading: widget.stateManLoading,
              disabled: !widget.server.enabled,
            ),
            const SizedBox(width: 4),
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
            color: sslCertString == _certPlaceholder ||
                    sslKeyString == _certPlaceholder
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
            ConnectionStatusChip(
              status: _connectionStatus,
              effectiveStatus: _effectiveStatus,
              stateManLoading: widget.stateManLoading,
              disabled: !widget.server.enabled,
            ),
            const SizedBox(width: 4),
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
                                    : sslCertString == _certPlaceholder
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
                                    : sslKeyString == _certPlaceholder
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

class ImportExportCard extends ConsumerStatefulWidget {
  const ImportExportCard({super.key});

  static const String _compiledPrefix = 'Flottur köttur:'; // same secret prefix

  @override
  ConsumerState<ImportExportCard> createState() => _ImportExportCardState();
}

class _ImportExportCardState extends ConsumerState<ImportExportCard> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _packageInfo = info);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 500;
            final versionText = _packageInfo != null
                ? Text(
                    'v${_packageInfo!.version}+${_packageInfo!.buildNumber}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(100),
                        ),
                  )
                : null;
            final buttons = <Widget>[
              FilledButton.icon(
                onPressed: () => _onLoadFromDb(context, ref),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Load from Database'),
              ),
              OutlinedButton.icon(
                onPressed: () => _onStoreToDb(context, ref),
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Store in Database'),
              ),
              OutlinedButton.icon(
                onPressed: () => _onImport(context, ref),
                icon: const Icon(Icons.file_upload),
                label: const Text('Import File'),
              ),
              OutlinedButton.icon(
                onPressed: () => _onExport(context, ref),
                icon: const Icon(Icons.file_download),
                label: const Text('Export File'),
              ),
            ];
            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.sync_alt, size: 20),
                      const SizedBox(width: 8),
                      Text('Import / Export',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final button in buttons) ...[
                    button,
                    if (button != buttons.last) const SizedBox(height: 8),
                  ],
                  if (versionText != null) ...[
                    const SizedBox(height: 12),
                    Center(child: versionText),
                  ],
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.sync_alt, size: 20),
                    const SizedBox(width: 8),
                    Text('Import / Export',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (versionText != null)
                      Expanded(
                          child: Align(
                              alignment: Alignment.centerRight,
                              child: versionText)),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: buttons,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // -------------------- EXPORT --------------------
  Future<void> _onExport(BuildContext context, WidgetRef ref) async {
    try {
      final jsonMap = await _collectExportJson(ref);

      final postfix = _generatePostfix(12);
      final envelope = await SecureEnvelope.encrypt(
        jsonConfig: jsonMap,
        compiledPrefix: ImportExportCard._compiledPrefix,
        exportPostfix: postfix,
      );

      String? savePath;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Encrypted Config',
          fileName: 'server_config.enc',
          type: FileType.custom,
          allowedExtensions: ['enc'],
        );
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
        savePath = path.join(dir.path, 'server_config_$ts.enc');
      }
      if (savePath == null) return;

      final file = File(savePath);
      await file
          .writeAsString(const JsonEncoder.withIndent('  ').convert(envelope));

      if (!context.mounted) return;

      // Show postfix/code
      // ignore: use_build_context_synchronously
      await showStandardDialog<void>(
        context: context,
        title: 'Export complete',
        icon: Icons.lock_outline,
        actionsBuilder: (ctx) => [
          PaneAction(
            label: 'Copy code',
            icon: Icons.copy,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: postfix));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Code copied to clipboard')),
              );
            },
          ),
        ],
        builder: (ctx) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Encrypted file saved.'),
              const SizedBox(height: 12),
              const Text('Use this code to decrypt:'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.withAlpha(50),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey),
                ),
                child: SelectableText(
                  postfix,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('Location:',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SelectableText(file.path,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    }
  }

  // -------------------- IMPORT --------------------
  Future<void> _onImport(BuildContext context, WidgetRef ref) async {
    try {
      final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['enc'],
        dialogTitle: 'Select Encrypted Config',
      );
      if (pick == null || pick.files.single.path == null) return;

      final file = File(pick.files.single.path!);
      final envelope =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      if (!context.mounted) return;

      // Ask for code
      final ctrl = TextEditingController();
      final postfix = await showStandardDialog<String?>(
        context: context,
        title: 'Enter code to decrypt',
        icon: Icons.key,
        actionsBuilder: (ctx) => [
          PaneAction.primary(
            label: 'Decrypt',
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
        builder: (ctx) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Current server config will be overwritten!',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.orange),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'Enter the code shared with you',
                ),
                obscureText: true,
              ),
            ],
          ),
        ),
      );
      if (postfix == null || postfix.isEmpty) return;

      // Decrypt & scrub
      final decrypted = await SecureEnvelope.decrypt(
        envelope: envelope,
        compiledPrefix: ImportExportCard._compiledPrefix,
        postfix: postfix,
      );

      final missingCerts = await _applyDecryptedConfig(ref, decrypted);

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            missingCerts == 0
                ? 'Config imported. Existing certificates were kept.'
                : 'Config imported. Please generate new certificates for '
                    '$missingCerts server(s).',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error),
      );
    }
  }

  /// Persists a decrypted config map (StateManConfig JSON with an optional
  /// 'database' entry) and rebuilds everything that reads it. Shared by the
  /// file import and the database import.
  ///
  /// [applyDatabase] is false for the database import: this client is
  /// connected to the database right now through its local settings, and the
  /// stored config's connection details — saved by another machine, possibly
  /// reaching the same server by a different address or credentials — must
  /// not replace a working connection. The file import keeps applying them;
  /// that is how a fresh client gets its database config in the first place.
  ///
  /// Returns how many imported servers still need certificates generated
  /// after this client's existing ones were reused.
  Future<int> _applyDecryptedConfig(WidgetRef ref, Map<String, dynamic> decrypted,
      {bool applyDatabase = true}) async {
    // Persist Database first (so DB widget re-reads correct values)
    if (applyDatabase && decrypted['database'] != null) {
      final db = DatabaseConfig.fromJson(decrypted['database']);
      await db.toPrefs();
    }
    decrypted.remove('database');

    final stateMan = StateManConfig.fromJson(decrypted);
    final prefs = await ref.read(preferencesProvider.future);

    // Exports scrub certificates down to a placeholder. Where this client
    // already holds real certificates for the same server, keep them — the
    // server trusts that certificate already, so regenerating gains nothing
    // and breaks the trust the PLC was configured with.
    StateManConfig? current;
    try {
      current = await StateManConfig.fromPrefs(prefs);
    } catch (_) {
      // No (or unreadable) saved config — nothing to reuse.
    }
    final missingCerts = _reuseExistingCerts(stateMan, current);

    await stateMan.toPrefs(prefs);

    // Trigger rebuilds:
    if (applyDatabase) ref.invalidate(databaseProvider);
    ref.invalidate(stateManProvider);
    ref.read(refreshKeyProvider.notifier).increment();
    return missingCerts;
  }

  /// Replaces scrubbed certificate placeholders in [incoming] with this
  /// client's existing certificates for the same server — matched by
  /// endpoint, falling back to alias so a server that moved address keeps
  /// its certificate too. Returns how many servers still hold the
  /// placeholder afterwards.
  int _reuseExistingCerts(StateManConfig incoming, StateManConfig? current) {
    bool isPlaceholder(Uint8List? bytes) =>
        bytes != null && String.fromCharCodes(bytes) == _certPlaceholder;
    bool hasRealCerts(OpcUAConfig s) =>
        s.sslCert != null &&
        s.sslKey != null &&
        !isPlaceholder(s.sslCert) &&
        !isPlaceholder(s.sslKey);

    final candidates =
        (current?.opcua ?? const <OpcUAConfig>[]).where(hasRealCerts).toList();
    var missing = 0;
    for (final server in incoming.opcua) {
      if (!isPlaceholder(server.sslCert) && !isPlaceholder(server.sslKey)) {
        continue; // real certs, or none configured at all — leave untouched
      }
      OpcUAConfig? match;
      for (final cand in candidates) {
        if (cand.endpoint == server.endpoint) {
          match = cand;
          break;
        }
      }
      if (match == null && server.serverAlias != null) {
        for (final cand in candidates) {
          if (cand.serverAlias == server.serverAlias) {
            match = cand;
            break;
          }
        }
      }
      if (match != null) {
        server.sslCert = match.sslCert;
        server.sslKey = match.sslKey;
      } else {
        missing++;
      }
    }
    return missing;
  }

  /// Collects the current config as the JSON map that gets encrypted:
  /// StateManConfig with cert paths scrubbed, plus the database config.
  /// Shared by the file export and the database export.
  Future<Map<String, dynamic>> _collectExportJson(WidgetRef ref) async {
    final prefs = await ref.read(preferencesProvider.future);
    final stateMan = await StateManConfig.fromPrefs(prefs);
    final db = await DatabaseConfig.fromPrefs();
    final jsonMap = _scrubCertPaths(stateMan.toJson());
    jsonMap['database'] = db.toJson();
    return jsonMap;
  }

  // -------------------- STORE IN / LOAD FROM DATABASE --------------------

  void _showError(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  /// Stores the current config in the shared database, encrypted with a
  /// password the operator chooses. Any client connected to the same
  /// database can then import it with that password — no file to carry
  /// between machines.
  Future<void> _onStoreToDb(BuildContext context, WidgetRef ref) async {
    try {
      final db = await ref.read(databaseProvider.future);
      if (db == null) {
        if (context.mounted) {
          _showError(context,
              'No database connection — configure and save the database first.');
        }
        return;
      }

      // Fetched only so the dialog can warn what gets replaced; a corrupt
      // stored row must not block overwriting it with a good one.
      StoredServerConfig? existing;
      try {
        existing = await ServerConfigDb.fetch(db.db);
      } catch (_) {}

      if (!context.mounted) return;
      final password = await _promptStorePassword(context, existing);
      if (password == null) return;

      final jsonMap = await _collectExportJson(ref);
      final envelope = await SecureEnvelope.encrypt(
        jsonConfig: jsonMap,
        compiledPrefix: ImportExportCard._compiledPrefix,
        exportPostfix: password,
      );

      // Through the guarded store, not through Drift: replacing the whole
      // server configuration is an `administer` write and belongs in the
      // trail like any other.
      final prefs = await ref.read(preferencesProvider.future);
      try {
        await ServerConfigDb.publish(
          prefs,
          StoredServerConfig(
            savedAt: DateTime.now(),
            savedBy: Platform.localHostname,
            envelope: envelope,
          ),
        );
      } on AccessDenied {
        // The shared denial listener already prompts; a second dialog here
        // would be two prompts for one refused action.
        return;
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Config stored in database. Other clients can import it with the password.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      _showError(context, 'Storing config in database failed: $e');
    }
  }

  /// Imports the config another client stored in the shared database.
  Future<void> _onLoadFromDb(BuildContext context, WidgetRef ref) async {
    try {
      final db = await ref.read(databaseProvider.future);
      if (db == null) {
        if (context.mounted) {
          _showError(context,
              'No database connection — configure and save the database first.');
        }
        return;
      }

      final stored = await ServerConfigDb.fetch(db.db);
      if (stored == null) {
        if (context.mounted) {
          _showError(context, 'No config stored in the database yet.');
        }
        return;
      }

      if (!context.mounted) return;
      final decrypted = await _promptLoadPassword(context, stored);
      if (decrypted == null) return;

      final missingCerts =
          await _applyDecryptedConfig(ref, decrypted, applyDatabase: false);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            missingCerts == 0
                ? 'Config imported from database. Existing certificates were kept.'
                : 'Config imported from database. Please generate new '
                    'certificates for $missingCerts server(s).',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      _showError(context, 'Loading config from database failed: $e');
    }
  }

  static String _describeStored(StoredServerConfig stored) {
    final when = stored.savedAt?.toLocal().toString().split('.').first;
    final by = stored.savedBy;
    if (when != null && by != null) return 'stored $when by $by';
    if (when != null) return 'stored $when';
    if (by != null) return 'stored by $by';
    return 'already stored';
  }

  /// Asks the operator to choose (and confirm) the encryption password.
  /// Returns null when cancelled.
  Future<String?> _promptStorePassword(
      BuildContext context, StoredServerConfig? existing) async {
    // Not disposed, like the import-code dialog's controller: the dialog's
    // dismissal animation still reads them after this future completes.
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final error = ValueNotifier<String?>(null);
    return await showStandardDialog<String?>(
      context: context,
      title: 'Store config in database',
      icon: Icons.cloud_upload_outlined,
      actionsBuilder: (ctx) => [
        PaneAction.primary(
          label: 'Store',
          onPressed: () {
            final password = passwordCtrl.text;
            if (password.length < 6) {
              error.value = 'Password must be at least 6 characters.';
              return;
            }
            if (password != confirmCtrl.text) {
              error.value = 'Passwords do not match.';
              return;
            }
            Navigator.pop(ctx, password);
          },
        ),
      ],
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The server config — including credentials — is encrypted '
              'with this password and stored in the shared database. Any '
              'client connected to the same database can import it by '
              'entering the same password.',
            ),
            if (existing != null) ...[
              const SizedBox(height: 12),
              Text(
                'This replaces the config ${_describeStored(existing)}.',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.orange),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: passwordCtrl,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmCtrl,
              decoration: const InputDecoration(labelText: 'Confirm password'),
              obscureText: true,
            ),
            ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (_, message, __) => message == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        message,
                        style:
                            TextStyle(color: Theme.of(ctx).colorScheme.error),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Asks for the password and decrypts [stored] right in the dialog, so a
  /// wrong password shows an error and lets the operator retry instead of
  /// dumping them back to the page. Returns the decrypted config map, or
  /// null when cancelled.
  Future<Map<String, dynamic>?> _promptLoadPassword(
      BuildContext context, StoredServerConfig stored) async {
    // Not disposed — see _promptStorePassword.
    final passwordCtrl = TextEditingController();
    final error = ValueNotifier<String?>(null);
    var busy = false;
    return await showStandardDialog<Map<String, dynamic>?>(
      context: context,
      title: 'Load config from database',
      icon: Icons.cloud_download_outlined,
      actionsBuilder: (ctx) => [
        PaneAction.primary(
          label: 'Decrypt & import',
          onPressed: () async {
            if (busy) return;
            final password = passwordCtrl.text;
            if (password.isEmpty) {
              error.value = 'Enter the password.';
              return;
            }
            busy = true;
            try {
              final decrypted = await SecureEnvelope.decrypt(
                envelope: stored.envelope,
                compiledPrefix: ImportExportCard._compiledPrefix,
                postfix: password,
              );
              if (ctx.mounted) Navigator.pop(ctx, decrypted);
            } catch (_) {
              // AES-GCM authentication failure — wrong password (or a
              // corrupt envelope, which reads the same from here).
              error.value = 'Incorrect password.';
            } finally {
              busy = false;
            }
          },
        ),
      ],
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Config ${_describeStored(stored)}.'),
            const SizedBox(height: 12),
            const Text(
              'Current server config will be overwritten!',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordCtrl,
              decoration: const InputDecoration(
                labelText: 'Password',
                hintText: 'Password chosen when the config was stored',
              ),
              obscureText: true,
              autofocus: true,
            ),
            ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (_, message, __) => message == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        message,
                        style:
                            TextStyle(color: Theme.of(ctx).colorScheme.error),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _generatePostfix(int length) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  // Remove sslCert/sslKey file paths from incoming JSON and count affected servers
  Map<String, dynamic> _scrubCertPaths(Map<String, dynamic> jsonMap) {
    final copy =
        jsonDecode(jsonEncode(jsonMap)) as Map<String, dynamic>; // deep copy
    if (copy['opcua'] is List) {
      for (final s in (copy['opcua'] as List)) {
        if (s is Map<String, dynamic>) {
          if ((s['ssl_cert'] != null) && (s['ssl_key'] != null)) {
            s['ssl_cert'] =
                Base64Converter().toJson(utf8.encode(_certPlaceholder));
            s['ssl_key'] =
                Base64Converter().toJson(utf8.encode(_certPlaceholder));
          }
        }
      }
    }
    return copy;
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
