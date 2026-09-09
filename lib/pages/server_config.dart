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
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:cryptography_flutter/cryptography_flutter.dart' as crypto_fl;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi;

import '../core/config_source.dart';
import '../core/gateway_config.dart';
import '../core/gateway_link_status.dart' show GatewayLinkKind;
import '../core/gateway_state_man.dart';
import '../core/gateway_trust.dart';
import '../core/server_config_db.dart';
import '../widgets/config/state_man_config_editor.dart';
import '../theme.dart';
import '../widgets/base_scaffold.dart';
import '../widgets/config_target_banner.dart';
import '../widgets/gateway_identity_dialog.dart';
import '../widgets/gateway_link_status_row.dart';
import '../widgets/preferences.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/database.dart';
import '../providers/access.dart' show stationNameProvider;
import '../providers/gateway.dart';
import '../providers/gateway_link.dart';
import '../providers/state_man.dart';
import '../providers/preferences.dart';
import '../providers/database.dart';
// TODO not the best place but cross platform
import 'package:package_info_plus/package_info_plus.dart';

// The transport-independent editor widgetry moved to the widgets layer in
// phase 2 of quick/20260908-unify-config-ui. Re-exported so existing
// callers and tests that reached these names through this page keep
// compiling.
export '../widgets/config/state_man_config_editor.dart'
    show
        StateManConfigEditor,
        CertificateGenerator,
        UpperCaseTextFormatter,
        moveInList,
        kCertPlaceholder;

part 'server_config.g.dart';


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

    // **One page, one shape, both transports.** The owner's ruling, twice
    // given: "backend configuration should be exactly the same ui page as
    // server config in direct to plcs, it is the same data", and then "the
    // server config should look exactly the same with gateway and without —
    // the only difference is a toggle at the top for gateway". So the column
    // below does not fork: every slot is filled in both modes, in the same
    // order, and the transport decides only what each slot is *about*.
    //
    //  1. Transport — the toggle, and the gateway address when it is on.
    //  2. The target, named — this station, or the backend being dialled.
    //  3. Database — the station's own, or the honest statement that a
    //     gateway station opens none (`DatabaseConfigWidget` branches).
    //  4. The OPC UA / JBTM / Modbus editor — the SAME widget over the
    //     transport's own [ConfigSource].
    //  5. Import / Export — the station's own config envelope, or the honest
    //     statement that it does not follow the transport.
    return SingleChildScrollView(
      child: Column(
        children: [
          // Which pipe this station runs on. Device-local in BOTH modes, so
          // it sits first and no target marker sits above it — the target is
          // a fact about the content below, and it is said there (ACCESS-04).
          TransportModeCard(key: ValueKey('transport_$refreshKey')),
          const SizedBox(height: 16),

          // The target, named, above the sections it describes — the same
          // slot in both modes. The two faces differ because the fact does:
          // editing your own station is the unremarkable case and reads as a
          // caption; editing another machine is the failure mode the ROADMAP
          // names first and wears the attention chip.
          Align(
            alignment: Alignment.centerLeft,
            child: gateway.isGateway
                ? ConfigTargetBanner.backend(name: gateway.url)
                : ConfigTargetBanner.station(name: stationName),
          ),
          // Who a save here is recorded against. Gateway-only because the
          // fact is: only a remote machine verifies this panel's session and
          // can name the account (ACCESS-06). A direct station's saves are
          // device-local and there is no second party to attribute them to.
          if (gateway.isGateway) ...[
            const SizedBox(height: 4),
            const _GatewayAttributionLine(),
          ],
          const SizedBox(height: 8),

          // Database Configuration Section. The SAME editable card in both
          // transports (owner's ruling: "i dont see a reason why we cannot
          // change or see database config") — these are this station's own
          // settings, held in device-local secure storage, and they are what
          // it runs on the moment the transport goes back to Direct. Gateway
          // mode changes one thing inside it: nothing dials, so nothing
          // claims a connection state.
          DatabaseConfigWidget(key: ValueKey('db_$refreshKey')),
          const SizedBox(height: 16),

          // The OPC UA / JBTM / Modbus sections, over ONE document with ONE
          // save button. The same widget in both modes — direct over this
          // station's preferences, gateway over the backend's config file —
          // which is the whole of the owner's ruling.
          if (gateway.isGateway)
            BackendConfigSection(
              key: ValueKey('backend_config_$refreshKey'),
              targetUrl: gateway.url,
            )
          else
            StateManConfigEditor(
              key: ValueKey('stateman_$refreshKey'),
              source: LocalPrefsConfigSource(
                prefs: () => ref.read(preferencesProvider.future),
                onApplied: () => ref.invalidate(stateManProvider),
              ),
              onResetSavedConfig: () async {
                final prefs = await ref.read(preferencesProvider.future);
                await prefs.remove(StateManConfig.configKey, secret: true);
              },
            ),
          const SizedBox(height: 16),
          const ImportExportCard(),
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

// ===================== Transport Mode =====================

/// Which pipe this station runs on, and where the far end is.
///
/// **A mode switch, not a fifth section.** In gateway mode this panel opens no
/// OPC UA session, no Modbus socket and no collector, so three of the four
/// sections below it are not another thing to configure — they are inert. This
/// card therefore sits above them, and every one of them stays in its slot and
/// says what it is under this transport.
///
/// **The fourth is Postgres.** The rig ran a panel in gateway mode and found a
/// connection to `172.18.0.6:5432` live throughout (13-RIG-E2E-EVIDENCE
/// FIND-C); `providers/database.dart` has since grown the transport branch
/// that closes it, and `providers/preferences.dart` carries the same branch
/// one level up so nothing pulls the pool back in by watching. The database
/// card is nonetheless **shown and editable in both transports** — the owner's
/// ruling, at the rig: "i dont see a reason why we cannot change or see
/// database config". The settings are this station's own, they are read from
/// and written to device-local secure storage by `DatabaseConfig.fromPrefs`,
/// and they are what the station runs on the moment somebody switches back to
/// Direct. What the card must not do in gateway mode is dial, or claim a
/// connection state it is not in; `lib/widgets/preferences.dart` holds that
/// line, and `test/core/gateway_copy_test.dart` keeps the old false wording
/// from coming back.
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
    //
    // **Driven from the link state, not the typed URL alone** — the fix for
    // the rig's photographed defect. `GatewayConfig.advisory` is a pure
    // function of the URL and cannot know whether the certificate actually
    // carries a SAN for the name; only the handshake knows that. A live
    // session over `wss://name` is proof it does, so the proactive warning is
    // false while connected — and a warning that fires while the very thing
    // it warns will fail is succeeding teaches operators to ignore the row.
    // Suppressed whenever the link is connected; the reactive half (the
    // `sanHint` in `GatewayLinkStatusRow`) still fires at handshake-failure
    // time, which is the only moment the warning can be known to be true.
    final connected =
        linkReport?.kind == GatewayLinkKind.connected;
    final advisory = connected ? null : _edited.advisory;

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

    // **Always open, at the top of the page.** It used to be an
    // `ExpansionTile` collapsed in direct mode, on the argument that an
    // expanded card pushes the sections below it down on every station in
    // the plant. The owner overruled that: the transport toggle IS the one
    // difference between the two faces of this page, and a difference folded
    // behind a disclosure triangle is one an operator has to already know
    // about to find. Everything below this card is now the same in both
    // modes, so this is the whole of what the toggle costs in height.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.networkWired, size: 20),
              const SizedBox(width: 8),
              Text('Transport', style: theme.textTheme.titleMedium),
              const SizedBox(width: 16),
              // Device-local, said as a property OF the control rather than
              // as a paragraph above it. It used to be two full lines of
              // prose at the top of the card ("way too bloated", the owner,
              // standing at the rig): true, but not an instruction — nothing
              // an operator does about it, and it was crowding out the one
              // sentence they must act on. The full statement, and why the
              // row must never travel through `preferencesProvider`, is in
              // this class's doc comment and in
              // `test/pages/server_config_transport_card_test.dart`.
              Expanded(
                child: Text(
                  'This station only — never imported or synced.',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // **The transport, as ONE control.** The mode and the place the
          // mode dials are one decision, so they are one row: choosing
          // "Relay gateway" opens the address beside the segment that asked
          // for it, not two rows further down under a paragraph. The owner's
          // words, at the rig: "the toggle and the gateway address belong on
          // the same row".
          //
          // `minHeight` is the field's own height, applied in BOTH
          // transports: a direct station's row is the same height as a
          // gateway station's, so flipping the toggle reveals the address
          // without the card growing under the finger that flipped it, and
          // the empty half of the row in direct mode reads as space rather
          // than as something missing.
          //
          // The breakpoint is measured, not chosen: the widest of the two
          // segment label sets is ~345 logical pixels, and an address field
          // narrower than ~280 cannot show `centroidx-backend:9443` — the
          // name this plant actually dials — without ellipsising it. 345 +
          // 12 + 280 = 637, so below 640 the two stack. The page's other
          // breakpoints (500 for the Import/Export header, 400 in the
          // editor) are about different content and would leave this row
          // squeezed for the whole 500–640 band.
          LayoutBuilder(
            builder: (context, constraints) {
              final toggle = SegmentedButton<TransportMode>(
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
              );
              final address = _edited.isGateway
                  ? TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Gateway address and port',
                        // The examples are the helper now. The line that
                        // used to sit under this field — "IP address or
                        // host name, and the port. wss unless you type a
                        // scheme." — said what the hint shows and what the
                        // saved value spells (`wss://…`, filled in by
                        // [normalizeGatewayAddress] and read back into this
                        // controller), and it cost a row of the card on
                        // every gateway panel in the plant. A scheme that
                        // cannot be dialled is still refused by name, below.
                        hintText: '10.50.10.11:9443  or  '
                            'centroidx-backend:9443',
                        border: OutlineInputBorder(),
                      ),
                      // Normalised on the way in, not on the way out:
                      // everything that reads this row — the refusal below,
                      // the trust fetch, the boot path — sees the URL it
                      // will actually dial, so no second spelling of "what
                      // did the operator mean" can appear.
                      onChanged: (value) => _edit(
                          _edited.copyWith(url: normalizeGatewayAddress(value))),
                    )
                  : null;
              if (address != null && constraints.maxWidth < 640) {
                // Narrow panel: the same two controls, stacked, with the
                // toggle left where it sits when there is room beside it.
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: toggle),
                    const SizedBox(height: 12),
                    address,
                  ],
                );
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Row(
                  children: [
                    toggle,
                    if (address != null) ...[
                      const SizedBox(width: 12),
                      Expanded(child: address),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (_edited.isGateway) ...[
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
          //
          // The ONE line of prose left in this card rides beside it rather
          // than under it. Of the three sentences this card used to carry,
          // this is the one an operator acts on — the panel does not change
          // transport until it is restarted, and a save that looked like it
          // took effect immediately is the misreading the line exists to
          // prevent. It sits in the same row as the button that causes it.
          LayoutBuilder(
            builder: (context, constraints) {
              final button = ElevatedButton.icon(
                onPressed: canSave ? _save : null,
                icon: FaIcon(FontAwesomeIcons.floppyDisk,
                    size: 16, color: canSave ? unsavedInk : Colors.grey),
                label: Text(switch ((_hasUnsavedChanges, refusal)) {
                  (false, _) => 'All Changes Saved',
                  (true, final String _) => 'Cannot save yet',
                  (true, _) => 'Save Configuration',
                }),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                  foregroundColor: canSave ? unsavedInk : null,
                  backgroundColor: canSave ? unsavedFill : Colors.grey,
                ),
              );
              final note = Text(
                'Changing the transport takes effect when the HMI restarts.',
                style: theme.textTheme.bodySmall,
              );
              // Same 640 as the control row above, for the same reason and
              // so the card has one shape per width rather than two.
              if (constraints.maxWidth < 640) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    note,
                    const SizedBox(height: 8),
                    button,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: note),
                  const SizedBox(width: 16),
                  button,
                ],
              );
            },
          ),
          ],
        ),
      ),
    );
  }
}

// The hidden-sections note that used to sit under the Backend Configuration
// card is gone, by the owner's ruling: it narrated what the transport toggle
// above already shows, and on a panel that narration cost the vertical space
// the JSON editor needs. What it said honestly about the Postgres connection
// is still true and still written down — in the TransportModeCard doc comment
// above — and `test/core/gateway_copy_test.dart` keeps holding this file to
// it. Its history (including the false claims 15-05 corrected) is in git.

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

/// The username the gateway verified this session as, for the attribution
/// row — or null when the gateway named none (an awaiting-sign-in session,
/// or a gateway too old to say).
///
/// **The fix for the rig's photographed attribution defect.** The row used
/// to print `stationNameProvider` — this panel's own hostname — which on the
/// rig rendered a bare container id (`00fb2feb2a16`), useless to an operator
/// and to anyone reading the audit trail later. The account the *server*
/// verified is the honest thing to name, and it is unknowable client-side
/// except from the hello answer's `account` capability, which
/// `RemoteStateMan.verifiedAccount` carries. Reached through the ONE relay
/// client the panel already holds, the `backendConfigApiProvider` pattern.
///
/// A `FutureProvider` rather than a watch on a stream: the verified account
/// is stable for the life of a station session, the page rebuilds on save
/// and navigation, and a re-read costs one getter. Refuses in direct mode
/// by answering null — the attribution row is a gateway-only surface.
final gatewayVerifiedAccountProvider = FutureProvider<String?>((ref) async {
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (!gateway.isGateway) return null;
  final stateMan = await ref.watch(stateManProvider.future);
  final remote = stateMan is GuardedStateMan
      ? stateMan.innerAs<GatewayStateMan>()?.remote
      : null;
  return remote?.verifiedAccount;
});

/// The editable half of the backend's configuration document.
const Key kBackendConfigEditorKey = Key('backend_config_editor');

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

/// Who a save on this page is recorded against, on a gateway station.
///
/// **The fix for the rig's photographed attribution defect, kept.** The line
/// used to print `stationNameProvider` — this panel's own hostname, which on
/// the rig rendered a bare container id (`00fb2feb2a16`), useless to an
/// operator and to anyone reading the audit trail later. The account the
/// *server* verified is the honest thing to name.
///
/// It is the one caption on this page that renders in only one mode, and the
/// reason is that the fact exists in only one mode: a direct station's saves
/// are its own, with no second party that verified anything to name.
class _GatewayAttributionLine extends ConsumerWidget {
  const _GatewayAttributionLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final verifiedAccount =
        ref.watch(gatewayVerifiedAccountProvider).valueOrNull;
    return Row(
      key: kBackendConfigAttributionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.desktop_windows,
            size: 14,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            verifiedAccount == null
                ? 'Saves are recorded against this station\'s verified '
                    'account — a station account, not a person.'
                : 'Saves are recorded against this station\'s verified '
                    'account ($verifiedAccount) — a station account, not a '
                    'person.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
          ),
        ),
      ],
    );
  }
}

/// The backend's `StateManConfig`, editable from a gateway-mode panel.
///
/// **This is the gateway slot of the ONE page**, and it holds the SAME
/// [StateManConfigEditor] direct mode renders — over a [GatewayConfigSource]
/// instead of a [LocalPrefsConfigSource]. That is the owner's ruling
/// ("backend configuration should be exactly the same ui page as server
/// config in direct to plcs, it is the same data"), and after the same
/// owner's second pass there is nothing left around the editor except what
/// the transport genuinely needs: the relay client has to be *built* before
/// there is a document to edit, so this widget is the loading face and the
/// cannot-build face for that one asynchronous step.
///
/// The header card this widget used to carry — a title row, the target chip
/// and the attribution line — is gone. The target and the attribution moved
/// up to the page, where the direct face has them too; a second title over an
/// editor that already names its three sections was the last thing making
/// this mode look like a different screen.
///
/// Reads come from `backendConfig.read`, saves go to `backendConfig.write`;
/// nothing here touches this station's own preferences. The check, the audit
/// row and the validation live at the far end (17-09/17-10); this is the
/// screen for them and adds no second policy.
class BackendConfigSection extends ConsumerWidget {
  const BackendConfigSection({super.key, required this.targetUrl});

  /// The endpoint this panel is dialling — the machine a save here changes.
  /// Named on the page's own target chip, above this widget; kept as a
  /// constructor argument because the refusal face below spells it too, and
  /// "the backend refused" is only actionable when you can see WHICH backend.
  final String targetUrl;

  /// The operator-facing sentence for [error]. A protocol refusal carries the
  /// far end's message; anything else is shown as what it is.
  static String _describe(Object error) =>
      error is rpc.RpcException ? error.message : error.toString();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final apiAsync = ref.watch(backendConfigApiProvider);

    return apiAsync.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      // The relay client itself could not be built (no gateway StateMan,
      // provider refusal). Document-level read refusals render inside the
      // editor, which keeps the far end's sentence verbatim.
      error: (error, _) => Card(
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
                      'Could not read the configuration of $targetUrl: '
                      '${_describe(error)}',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(backendConfigApiProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (api) => StateManConfigEditor(
        // The 17-13 key, kept: it names the editable half of the backend's
        // document — which is now the whole typed editor, not a textarea.
        key: kBackendConfigEditorKey,
        source: GatewayConfigSource(api: api),
        saveButtonKey: kBackendConfigSaveKey,
        refusalRowKey: kBackendConfigRefusalKey,
        restoreButtonKey: kBackendConfigRestoreKey,
        applyNoteKey: kBackendConfigRestartNoteKey,
      ),
    );
  }
}

/// Moving a STATION's configuration between machines: an encrypted envelope
/// to a file, or to the shared database.
///
/// It occupies the same slot in both transports, because the page has one
/// shape — but on a gateway station it renders a statement instead of four
/// buttons. It is now the ONLY card on the page that does: the database card
/// stayed editable in both transports by the owner's ruling, because its
/// settings are still this station's own and it runs on them the moment the
/// transport goes back to Direct. The difference here is that these are not
/// settings but ACTIONS, and the actions genuinely do nothing a gateway
/// station wants: every path reads and writes THIS station's own preferences
/// and its own certificates. An "Import File" that reported success while
/// changing nothing the backend reads is precisely the failure mode this page
/// exists to prevent, one target further along.
class ImportExportCard extends ConsumerStatefulWidget {
  const ImportExportCard({super.key});

  static const String _compiledPrefix = 'Flottur köttur:'; // same secret prefix

  @override
  ConsumerState<ImportExportCard> createState() => _ImportExportCardState();
}

/// The import/export card on a gateway-mode station: a statement, not a set
/// of buttons. Same slot, muted voice — the treatment the database card used
/// to share before it went back to being editable in both transports, and the
/// reason it no longer does: a setting can be stored for later, but a button
/// that acts on nothing the panel reads cannot.
class _GatewayImportExportCard extends StatelessWidget {
  const _GatewayImportExportCard();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final muted = onSurface.withValues(alpha: 0.65);
    return Card(
      child: ListTile(
        leading: Icon(Icons.sync_alt, size: 20, color: muted),
        title: const Text('Import / Export'),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Not used in gateway mode. This moves a station\'s own '
            'configuration and certificates between machines; the backend\'s '
            'configuration is edited above and saved straight to the backend.',
            style: TextStyle(color: muted),
          ),
        ),
      ),
    );
  }
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
    // Absent or still loading reads as direct mode — the transport an
    // unconfigured station runs, and the face this card has always had.
    final gateway = ref.watch(gatewayConfigProvider).valueOrNull ??
        GatewayConfig.defaults;
    if (gateway.isGateway) return const _GatewayImportExportCard();
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
        bytes != null && String.fromCharCodes(bytes) == kCertPlaceholder;
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
                Base64Converter().toJson(utf8.encode(kCertPlaceholder));
            s['ssl_key'] =
                Base64Converter().toJson(utf8.encode(kCertPlaceholder));
          }
        }
      }
    }
    return copy;
  }
}

