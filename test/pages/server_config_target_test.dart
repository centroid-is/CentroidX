/// One screen, two targets — and the operator can tell which machine they are
/// editing (17-13, ACCESS-04/ACCESS-06).
///
/// The ROADMAP names the failure mode before the feature: silently configuring
/// the wrong machine. Arm 2 is that sentence as a test — it asserts the store
/// that was NOT written, because a page that shows the remote config and saves
/// the local one passes every arm that only asserts "a save happened".
///
/// The fixture is 15-05's (`buildTestableServerConfig` + `_gatewayStation`'s
/// shape), not a second one. The backend at the far end is a scripted
/// [BackendConfigApi]: the wire, the policy check and the audit row are
/// 17-08/17-09/17-10's tested territory, and this file is about the page.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument, ConfigValidation;

import '../helpers/test_helpers.dart';

// ---------------------------------------------------------------------------
// The structural keys the page exports. Spelled as literals here so this file
// compiles — and fails by "found nothing" — before the page grows them; the
// GREEN task declares constants with these exact strings and the goldens use
// those.
// ---------------------------------------------------------------------------

const _banner = Key('config_target_banner');
// `backend_config_editor` still exists — it now keys the typed
// StateManConfigEditor rather than a textarea; the swap arm lives in
// server_config_gateway_editor_test.dart.
const _relayField = Key('backend_config_relay_field');
const _save = Key('backend_config_save');
const _restore = Key('backend_config_restore');
const _refusal = Key('backend_config_refusal');
const _attribution = Key('backend_config_attribution');
const _restartNote = Key('backend_config_restart_note');

/// The station name every arm pins. Overridden onto [stationNameProvider]
/// because the production value is `Platform.localHostname`, which is a
/// different string on every machine that runs this suite.
const _station = 'SVN-ST101';

/// A container-id-shaped hostname, the exact shape the rig photographed in
/// the attribution row. Set as the station name in the attribution arm so the
/// fix — show the verified account, never this — has something to be checked
/// against.
const _machineId = '00fb2feb2a16';

/// The endpoint the gateway fixture dials — the machine the banner must name.
const _gatewayUrl = 'wss://10.50.10.11:9443';

/// The backend's live configuration, as the scripted far end serves it.
/// One editable section (`opcua`) and the one that is not (`relay`, D-10).
const _liveConfig = <String, Object?>{
  'opcua': [
    <String, Object?>{
      'endpoint': 'opc.tcp://10.104.20.10:4840',
      'server_alias': 'ST101',
      'publishing_interval_ms': 250,
    },
  ],
  'relay': <String, Object?>{
    'port': 9443,
    'token_file': '/etc/centroid/relay-tokens.json',
  },
};

/// A scripted far end. Records what was written and can be told to refuse.
class ScriptedBackendConfig implements BackendConfigApi {
  ScriptedBackendConfig({
    Map<String, Object?> config = _liveConfig,
    this.hasPrevious = false,
    this.writeRefusal,
    this.readRefusal,
  }) : configJson = jsonEncode(config);

  String configJson;
  bool hasPrevious;

  /// Thrown by [write] when set — the backend refusing, in the backend's own
  /// words, exactly as the client proxy re-raises it.
  Object? writeRefusal;

  /// Thrown by [read] when set — the state a panel is in when the relay is
  /// down or the backend will not answer, which is arm 14's whole subject.
  Object? readRefusal;

  final List<String> writes = [];
  int reads = 0;
  int restoreCalls = 0;

  @override
  Future<BackendConfigDocument> read() async {
    reads++;
    final refusal = readRefusal;
    if (refusal != null) throw refusal;
    return BackendConfigDocument(
      configJson: configJson,
      readOnlySections: const ['relay'],
      hasPrevious: hasPrevious,
    );
  }

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);

  @override
  Future<void> write(String configJson, {String? reason}) async {
    final refusal = writeRefusal;
    if (refusal != null) throw refusal;
    writes.add(configJson);
    this.configJson = configJson;
    hasPrevious = true;
  }

  @override
  Future<BackendConfigDocument?> previous() async => hasPrevious
      ? BackendConfigDocument(
          configJson: jsonEncode(_liveConfig),
          readOnlySections: const ['relay'],
        )
      : null;

  @override
  Future<void> restorePrevious({String? reason}) async {
    restoreCalls++;
  }
}

/// The parser's refusal — arm 5's. It names the field that was wrong.
final rpc.RpcException _parserRefusal = rpc.RpcException(
  -32011,
  'BackendConfigStore.write refused: The submitted document could not be '
  'parsed as a StateManConfig: publishing_interval_ms must be a number.',
);

/// The relay-section refusal — arm 7's, D-10's exact voice. It must not read
/// like arm 5's: one is "your config is wrong", this is "this section cannot
/// be changed from here".
final rpc.RpcException _relayRefusal = rpc.RpcException(
  -32011,
  'BackendConfigStore.write refused: The `relay` section differs from the '
  'live configuration, and it is not remotely editable: it configures the '
  'very socket this edit arrived on, and you do not edit the socket over the '
  'socket. Change it at the machine (/etc/centroid/state-man.json) and '
  'restart the backend.',
);

/// A station already switched to the gateway, as its device-local row —
/// 15-05's `_gatewayStation`, verbatim in shape.
Future<PreferencesApi> _gatewayStation() async {
  final prefs = InMemoryPreferences();
  await writeGatewayConfig(
    prefs,
    GatewayConfig(
      mode: TransportMode.gateway,
      url: _gatewayUrl,
      caCertPath: '/pki/ca.pem',
    ),
  );
  return prefs;
}

/// The wiring seam this file shares with the GREEN task. At RED it answered
/// `const []` (the page had no seam to override), so every gateway arm failed
/// by "found nothing" while arms 1 and 11 stayed green; GREEN flipped this
/// one function to override the page's provider with the scripted far end.
List<Override> _scriptedBackend(ScriptedBackendConfig api) => [
      backendConfigApiProvider.overrideWith((ref) async => api),
    ];

/// The verified-account seam for the attribution arm. Null answers the
/// "unknown yet" phrasing; a name answers the named phrasing. Overridden so
/// the arm need not stand up a live relay to reach `RemoteStateMan
/// .verifiedAccount`.
List<Override> _verifiedAccount(String? account) => [
      gatewayVerifiedAccountProvider.overrideWith((ref) async => account),
    ];

/// The page, in gateway mode, over a scripted backend.
Future<
    ({
      ScriptedBackendConfig api,
      Preferences shared,
    })> _pumpGateway(
  WidgetTester tester, {
  ScriptedBackendConfig? api,
  // Null leaves the account unknown (the boot / old-gateway phrasing); a
  // value drives the named attribution AND sets the station hostname to the
  // machine-id shape, so the arm can prove the id is not what shows.
  String? verifiedAccount,
}) async {
  // The typed editor (phase 3) is a page of section cards, not one
  // textarea; a taller surface keeps these arms about behaviour instead of
  // scroll mechanics.
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final backend = api ?? ScriptedBackendConfig();
  final shared = await createTestPreferences();
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      localPreferences: await _gatewayStation(),
      overrides: [
        preferencesProvider.overrideWith((ref) async => shared),
        stationNameProvider
            .overrideWithValue(verifiedAccount == null ? _station : _machineId),
        ..._scriptedBackend(backend),
        ..._verifiedAccount(verifiedAccount),
      ],
    ),
  );
  return (api: backend, shared: shared);
}

/// The page, in direct mode. The scripted backend is wired anyway, so arm 1
/// can assert it was never consulted — the pre-effect half of arm 2's claim,
/// pointing the other way.
Future<
    ({
      ScriptedBackendConfig api,
      Preferences shared,
    })> _pumpDirect(WidgetTester tester) async {
  final backend = ScriptedBackendConfig();
  final shared = await createTestPreferences();
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      localPreferences: InMemoryPreferences(),
      overrides: [
        preferencesProvider.overrideWith((ref) async => shared),
        stationNameProvider.overrideWithValue(_station),
        ..._scriptedBackend(backend),
      ],
    ),
  );
  return (api: backend, shared: shared);
}

/// The benign edit every save arm makes through the TYPED form (phase 3
/// retarget: the raw textarea is demoted to the Advanced expansion, so
/// "edit and save" means what it means to an operator — expand the server
/// card, change a field, press the ONE save button).
const _editedEndpoint = 'opc.tcp://10.104.20.10:4841';

Future<void> _editAndSave(WidgetTester tester,
    {String endpoint = _editedEndpoint}) async {
  await tester.scrollUntilVisible(
    find.text('ST101'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await settle(tester);
  await tester.tap(find.text('ST101'));
  await settle(tester);
  await tester.scrollUntilVisible(
    find.widgetWithText(TextField, 'Endpoint URL'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await settle(tester);
  await tester.enterText(
      find.widgetWithText(TextField, 'Endpoint URL'), endpoint);
  await settle(tester);
  await tester.ensureVisible(find.byKey(_save));
  await settle(tester);
  await tester.tap(find.byKey(_save));
  await settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  // -------------------------------------------------------------------------
  // Arm 1 — direct mode is unchanged: the store that was written is the
  // station's own preferences, and the backend was never consulted.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 1: a direct-mode save writes StateManConfig to this station\'s own '
      'preferences, and never the backend', (tester) async {
    final fixture = await _pumpDirect(tester);

    // Today's page, exactly: add an OPC UA server and save the section.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add Server').first);
    await settle(tester);
    await tester.ensureVisible(find.text('Save Configuration').first);
    await tester.tap(find.text('Save Configuration').first);
    await settle(tester);

    final saved = await fixture.shared
        .getString(StateManConfig.configKey, secret: true);
    expect(saved, isNotNull);
    final decoded =
        StateManConfig.fromJson(jsonDecode(saved!) as Map<String, dynamic>);
    expect(decoded.opcua, hasLength(1),
        reason: 'the direct-mode save path is today\'s: the section writes '
            'the station\'s own StateManConfig through preferencesProvider');

    expect(fixture.api.writes, isEmpty,
        reason: 'a direct station\'s config is its own; nothing here may '
            'travel to the backend');
    expect(fixture.api.reads, isZero,
        reason: 'direct mode must not even read the backend\'s config — a '
            'page that shows one machine and saves another is the ROADMAP\'s '
            'named failure mode, in either direction');
  });

  // -------------------------------------------------------------------------
  // Arm 2 — gateway mode targets the backend, and the local store is NOT
  // written. The pre-effect half catches a page that shows the remote config
  // and saves the local one.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 2: a gateway-mode save goes to backendConfig.write with the live '
      'relay section re-attached, and the local store is not written',
      (tester) async {
    final fixture = await _pumpGateway(tester);
    final localBefore = await fixture.shared
        .getString(StateManConfig.configKey, secret: true);

    await _editAndSave(tester);

    expect(fixture.api.writes, hasLength(1),
        reason: 'the save must reach the backend');
    final written =
        jsonDecode(fixture.api.writes.single) as Map<String, Object?>;
    expect(
        ((written['opcua'] as List).first
            as Map<String, Object?>)['endpoint'],
        _editedEndpoint,
        reason: 'the edit the operator typed is what crossed');
    expect((written['relay'] as Map<String, Object?>?)?['port'], 9443,
        reason: 'the document re-attaches the live relay section verbatim '
            '(ConfigDocument carries it whole) — a document sent without it '
            'would be refused for the wrong reason');

    final localAfter = await fixture.shared
        .getString(StateManConfig.configKey, secret: true);
    expect(localAfter, localBefore,
        reason: 'THE named failure mode: showing the backend\'s config and '
            'saving the station\'s own. The local StateManConfig row must be '
            'byte-identical after a gateway-mode save');
  });

  // -------------------------------------------------------------------------
  // Arm 3 — the banner names the machine, differently in each mode.
  // -------------------------------------------------------------------------
  testWidgets('arm 3: the banner names this station in direct mode',
      (tester) async {
    await _pumpDirect(tester);

    final banner = find.byKey(_banner);
    expect(banner, findsOneWidget);
    expect(
        find.descendant(of: banner, matching: find.textContaining(_station)),
        findsOneWidget,
        reason: 'a banner that only says "this station" would pass on a '
            'station that is not this one; the name is the claim');
    expect(
        find.descendant(
            of: banner, matching: find.textContaining('10.50.10.11')),
        findsNothing,
        reason: 'direct mode must not name a backend nothing is dialling');
  });

  testWidgets(
      'arm 3: the banner names the backend\'s endpoint host in gateway mode',
      (tester) async {
    await _pumpGateway(tester);

    final banner = find.byKey(_banner);
    expect(banner, findsOneWidget);
    expect(
        find.descendant(
            of: banner, matching: find.textContaining('10.50.10.11')),
        findsOneWidget,
        reason: 'the banner\'s whole job: the machine about to be edited is '
            'the one the panel is dialling, named. "A banner exists" would '
            'pass on a banner naming the wrong machine');
  });

  // -------------------------------------------------------------------------
  // Arm 4 — the relay section renders, is not editable, and says why.
  // Present, disabled, explained: three properties, three assertions. Hiding
  // it would pass the "not editable" half alone.
  // -------------------------------------------------------------------------
  testWidgets('arm 4: the relay section is present, disabled and explained',
      (tester) async {
    await _pumpGateway(tester);

    final relayFinder = find.byKey(_relayField);
    expect(relayFinder, findsOneWidget,
        reason: 'present: an operator who cannot see the relay port will go '
            'and look for it somewhere worse');

    final relay = tester.widget<TextField>(relayFinder);
    expect(relay.enabled, isFalse,
        reason: 'disabled: the section configures the socket this edit '
            'arrives on (D-10)');
    expect(relay.controller?.text, contains('token_file'),
        reason: 'the section\'s actual content is shown, not a placeholder');

    expect(find.textContaining('cut this screen off'), findsOneWidget,
        reason: 'explained: the copy says why, in operator language');
  });

  // -------------------------------------------------------------------------
  // Arm 5 — a rejected save shows the parser's message, not "failed".
  // -------------------------------------------------------------------------
  testWidgets('arm 5: a rejected save surfaces the parser\'s own sentence',
      (tester) async {
    final fixture = await _pumpGateway(
        tester, api: ScriptedBackendConfig(writeRefusal: null));
    fixture.api.writeRefusal = _parserRefusal;

    await _editAndSave(tester);

    expect(find.byKey(_refusal), findsOneWidget);
    // Scoped to the refusal row: the editor's own text also carries the
    // field name, which is not the claim — the claim is that the REFUSAL
    // names it.
    expect(
        find.descendant(
            of: find.byKey(_refusal),
            matching: find.textContaining('publishing_interval_ms')),
        findsOneWidget,
        reason: 'the operator-facing text must contain the field the parser '
            'named — "Save failed" is a refusal nobody can act on');
  });

  // -------------------------------------------------------------------------
  // Arm 6 — a rejected save leaves a way back, and the way back is not
  // always-present furniture.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 6 (anti-vacuity): before anything was ever overwritten, there is '
      'no restore control', (tester) async {
    await _pumpGateway(
        tester, api: ScriptedBackendConfig(hasPrevious: false));

    expect(find.byKey(_restore), findsNothing,
        reason: 'an always-present restore control proves nothing; it appears '
            'only when the backend reports a previous document to restore');
  });

  testWidgets(
      'arm 6: after a refusal there is a restore control, and it calls '
      'restorePrevious', (tester) async {
    final fixture = await _pumpGateway(tester,
        api: ScriptedBackendConfig(
            hasPrevious: true, writeRefusal: _parserRefusal));

    await _editAndSave(tester);
    expect(find.byKey(_refusal), findsOneWidget,
        reason: 'the refusal must be on screen for this to be the arm it '
            'claims to be');

    final restore = find.byKey(_restore);
    expect(restore, findsOneWidget);
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await settle(tester);
    expect(fixture.api.restoreCalls, 1,
        reason: 'the control must reach BackendConfigApi.restorePrevious — '
            'a button that only repaints is a way back to nowhere');
  });

  // -------------------------------------------------------------------------
  // Arm 7 — a relay-section refusal has its own message, distinct from an
  // invalid-config refusal.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 7: a relay-section refusal reads as "cannot be changed from here", '
      'not as "your config is wrong"', (tester) async {
    final fixture = await _pumpGateway(tester);
    fixture.api.writeRefusal = _relayRefusal;

    await _editAndSave(tester);

    expect(find.byKey(_refusal), findsOneWidget);
    expect(find.textContaining('not remotely editable'), findsOneWidget,
        reason: 'D-10\'s refusal, in D-10\'s words');
    expect(find.textContaining('could not be parsed'), findsNothing,
        reason: 'the two refusals must not read the same: one is about the '
            'document, the other about the section that carries the edit');
  });

  // -------------------------------------------------------------------------
  // Arm 8 — restart-to-apply is said after a successful save.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 8: after a successful save the copy says the backend applies it '
      'on restart', (tester) async {
    await _pumpGateway(tester);

    await _editAndSave(tester);

    expect(find.byKey(_restartNote), findsOneWidget);
    expect(find.textContaining('when the backend restarts'), findsWidgets,
        reason: 'a save that silently changes nothing visible is a save an '
            'operator repeats — the backend does not restart itself (17-10)');
  });

  // -------------------------------------------------------------------------
  // Arm 9 — attribution is shown and is honest: a station account, named,
  // and marked as a station rather than a person.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 9: the save is attributed to the VERIFIED ACCOUNT by name — never '
      'the machine id the panel used to print', (tester) async {
    // The photographed defect: the row read "…verified account
    // (00fb2feb2a16)…" — the container's hostname, useless to an operator
    // and to the audit trail. The station's hostname is deliberately set to
    // that machine-id shape here, and the account the gateway verified is a
    // readable name; the row must show the name and never the id.
    await _pumpGateway(tester, verifiedAccount: 'rig-panel-eng');

    final attribution = find.byKey(_attribution);
    expect(attribution, findsOneWidget);
    expect(
        find.descendant(
            of: attribution,
            matching: find.textContaining('rig-panel-eng')),
        findsOneWidget,
        reason: 'named: the account the SERVER verified, from the hello '
            'answer — not a value this client invented');
    expect(
        find.descendant(
            of: attribution, matching: find.textContaining(_machineId)),
        findsNothing,
        reason: 'the machine id is a fact about the container, not about the '
            'account a save is recorded against — the whole of the '
            'photographed defect');
    expect(
        find.descendant(
            of: attribution,
            matching: find.textContaining('station account')),
        findsOneWidget);
    expect(
        find.descendant(
            of: attribution, matching: find.textContaining('not a person')),
        findsOneWidget,
        reason: 'ACCESS-06: a screen that implies a person signed off is the '
            'UI form of recording a client-supplied identity as verified');
  });

  // -------------------------------------------------------------------------
  // Arm 10 — the copy does not overclaim. A source-text arm, 15-05 FIND-C's
  // rule carried forward with what 17-12 changed: gateway mode is CLOSER to
  // one WebSocket now, and still not there — session login still needs a
  // database, so no copy may say "only the WebSocket".
  // -------------------------------------------------------------------------
  test('arm 10: no copy claims the panel uses only the WebSocket', () {
    const paths = [
      'lib/pages/server_config.dart',
      'lib/widgets/config_target_banner.dart',
    ];
    for (final path in paths) {
      final file = File(path);
      expect(file.existsSync(), isTrue,
          reason: '$path must exist — the banner is this plan\'s artifact, '
              'and a scan over a missing file proves nothing');
      final source = file
          .readAsStringSync()
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(source, isNot(contains('only the websocket')),
          reason: '$path: session login still needs a database (17-12); '
              'claiming more isolation than the panel has is 15-05 FIND-C');
    }
  });

  // -------------------------------------------------------------------------
  // Arm 11 — `administer` still gates the route. Nothing in this plan
  // loosens /advanced/server-config.
  // -------------------------------------------------------------------------
  test('arm 11: /advanced/server-config still takes administer', () {
    expect(kRaisedRoutes[kServerConfigRoute], AccessGroup.administer,
        reason: 'the existing route gate, unchanged — the page grew a second '
            'target, not a second audience');
  });

  // -------------------------------------------------------------------------
  // Arm 12 — placement and height: the owner's complaint, encoded. The target
  // is a card-header affordance, not a page banner. It used to sit above the
  // Transport card — labelling the one card that is device-local in BOTH
  // modes — and spent a full band of height on one sentence. These arms are
  // geometric on purpose: a golden of the affordance being present cannot
  // guard the rule that the old band is absent.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 12: in gateway mode the target lives inside the Backend '
      'Configuration card, below Transport, one line tall', (tester) async {
    await _pumpGateway(tester);

    expect(
        find.descendant(
            of: find.byType(BackendConfigSection),
            matching: find.byKey(_banner)),
        findsOneWidget,
        reason: 'the target is a fact about the Backend Configuration card — '
            'the card whose editor reads and writes that machine — so it '
            'lives on that card\'s own header, not above the Transport card '
            'it used to mislabel');
    expect(find.byKey(_banner), findsOneWidget,
        reason: 'and there is exactly one: a second copy above the page '
            'would be the old band back');

    final transportTop = tester.getRect(find.byType(TransportModeCard)).top;
    final bannerTop = tester.getRect(find.byKey(_banner)).top;
    expect(bannerTop, greaterThan(transportTop),
        reason: 'nothing about the target sits above the Transport card');

    final height = tester.getSize(find.byKey(_banner)).height;
    expect(height, lessThanOrEqualTo(32),
        reason: 'one line, not a band: the JSON editor is what the operator '
            'needs the vertical space for (measured ${height}px)');
  });

  testWidgets(
      'arm 12: in direct mode the caption sits below Transport, above the '
      'sections it describes, one line tall', (tester) async {
    await _pumpDirect(tester);

    final transportBottom =
        tester.getRect(find.byType(TransportModeCard)).bottom;
    final banner = tester.getRect(find.byKey(_banner));
    expect(banner.top, greaterThanOrEqualTo(transportBottom),
        reason: 'the caption describes the station sections below it; the '
            'Transport card is device-local in both modes and is not part '
            'of that claim');

    final dbTop = tester.getRect(find.text('Database Configuration')).top;
    expect(banner.bottom, lessThanOrEqualTo(dbTop),
        reason: 'above the first section it describes');

    expect(banner.height, lessThanOrEqualTo(26),
        reason: 'a caption line, not a band (measured ${banner.height}px)');
  });

  // -------------------------------------------------------------------------
  // Arm 13 — the deleted narration stays deleted. The transport toggle
  // already states the mode; prose that narrates a control beside it is
  // noise, and the owner removed it by name. Functional absence assertions,
  // because a golden cannot guard an absence.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 13: no prose narrates the transport mode in gateway mode',
      (tester) async {
    await _pumpGateway(tester);

    expect(find.textContaining('read and saved over'), findsNothing,
        reason: 'the Backend Configuration description paragraph is gone — '
            'the header names the target, the toggle above states the mode');
    expect(find.textContaining('takes its values from the relay'),
        findsNothing,
        reason: 'the hidden-sections note is gone: it restated what the '
            'transport toggle already shows');
    expect(find.textContaining('It still opens one Postgres connection'),
        findsNothing,
        reason: 'the note went whole, not sentence by sentence');
  });

  // -------------------------------------------------------------------------
  // Arm 14 — the refused/cannot-read face still names its target. A sabotage
  // pass found this hole: the loaded face's header was guarded, the error
  // face's was not, and the error face is exactly where an operator is about
  // to be surprised — "the backend refused" is only actionable when you can
  // see WHICH backend.
  // -------------------------------------------------------------------------
  testWidgets(
      'arm 14: when the backend cannot be read, the card still names the '
      'machine that refused', (tester) async {
    await _pumpGateway(tester,
        api: ScriptedBackendConfig(
            readRefusal: rpc.RpcException(
                -32011, 'the relay is not accepting this station')));

    // Phase 3 retarget: a document-level read refusal now renders on the
    // EDITOR's error face ('Could not read the configuration: …'), while
    // the chrome keeps its own face for a relay client that cannot be
    // built. Both spell the refusal 'Could not read the', and both must
    // carry the far end's sentence verbatim.
    expect(find.textContaining('Could not read the'), findsOneWidget,
        reason: 'this arm is only the error-face arm if the error face is '
            'on screen');
    expect(find.textContaining('the relay is not accepting this station'),
        findsOneWidget,
        reason: 'the far end\'s own words, not a paraphrase');
    expect(
        find.descendant(
            of: find.byType(BackendConfigSection),
            matching: find.byKey(_banner)),
        findsOneWidget,
        reason: 'the target chip must survive onto the error face');
    expect(
        find.descendant(
            of: find.byKey(_banner),
            matching: find.textContaining('10.50.10.11')),
        findsOneWidget,
        reason: 'named, not just present — a refusal from an unnamed machine '
            'sends the operator to the wrong one');
  });
}
