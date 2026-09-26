/// Phase 3 of quick/20260908-unify-config-ui: the gateway branch stops being
/// a raw JSON textarea and renders the SAME typed editor direct mode renders,
/// over a `GatewayConfigSource` — the owner's ruling made structural
/// ("backend configuration should be exactly the same ui page as server
/// config in direct to plcs, it is the same data").
///
/// What these arms judge, in one line each:
///
///  * the swap itself — the typed sections render in gateway mode, and the
///    primary JSON textarea is gone (demoted, not deleted);
///  * fidelity over the wire from the FORM — a typed edit crosses with the
///    relay section byte-verbatim and every unknown key intact, and the
///    local store is not written;
///  * no JSON is printed on this page any more — neither the Advanced
///    expansion nor the read-only card that showed `relay` in a disabled
///    field (the owner removed both) — and the sections they used to show
///    still cross the wire verbatim, which is the property that made
///    removing the VIEW safe;
///  * honest absence — gateway mode has no live status, and the screen says
///    so instead of drawing a grey chip that reads as "not connected";
///  * apply semantics — the restart-to-apply copy is the transport's answer
///    (`ConfigSource.applySemantics`), not furniture on both modes;
///  * the way back — restore is driven by `source.hasPrevious()` (which is
///    `read().hasPrevious`), and `previous()` is never asked (17-10
///    deviation 4);
///  * the escape hatch for a document that will not decode — shown whole as
///    text with the parser's refusal, repairable from the panel (the
///    alternative is SSH, the exact regression this milestone exists to
///    avoid);
///  * a validate-refused save surfaces the far end's sentence verbatim and
///    writes nothing.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/widgets/connection_status_chip.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument, ConfigValidation;

import '../helpers/test_helpers.dart';

// ---------------------------------------------------------------------------
// Keys. The 17-13 kBackendConfig* spellings stay on the gateway affordances;
// the editor-owned ones (status absence, raw recovery) get editor-owned
// spellings, declared as literals here so this file fails by "found nothing"
// rather than by a compile error somebody could silence.
// ---------------------------------------------------------------------------

const _editor = Key('backend_config_editor');
const _save = Key('backend_config_save');
const _restore = Key('backend_config_restore');
const _refusal = Key('backend_config_refusal');
const _restartNote = Key('backend_config_restart_note');
// The relay card's own arms (present/disabled/explained) stay in
// server_config_target_test.dart — arm 4 holds unchanged across the swap.

const _absence = Key('config_status_absence');
/// The deleted Advanced-JSON field, still spelled here: an arm that asserts
/// an absence has to name the thing that must be absent.
const _advancedField = Key('config_advanced_json_field');
const _recoveryField = Key('config_raw_recovery_field');
const _recoveryApply = Key('config_raw_recovery_apply');

const _station = 'SVN-ST101';
const _gatewayUrl = 'wss://10.50.10.11:9443';

/// The backend's live document, salted with unknown content at every depth
/// the fidelity rule names: an unknown per-entry key, an unknown top-level
/// section, and the read-only `relay` section.
const _liveConfig = <String, Object?>{
  'opcua': [
    <String, Object?>{
      'endpoint': 'opc.tcp://10.104.20.10:4840',
      'server_alias': 'ST101',
      'publishing_interval_ms': 250,
      'vendor_note': 'kept-verbatim',
    },
  ],
  'collector_hints': <String, Object?>{'window': '5m'},
  'relay': <String, Object?>{
    'port': 9443,
    'token_file': '/etc/centroid/relay-tokens.json',
  },
};

/// A scripted far end: answers what it is told to, records every call, and
/// counts `previous()` so the widget layer can prove nobody asked it.
class ScriptedBackendConfig implements BackendConfigApi {
  ScriptedBackendConfig({
    Map<String, Object?> config = _liveConfig,
    String? rawConfigJson,
    this.hasPrevious = false,
    this.writeRefusal,
    this.validateAnswer = const ConfigValidation(ok: true),
  }) : configJson = rawConfigJson ?? jsonEncode(config);

  String configJson;
  bool hasPrevious;
  Object? writeRefusal;
  ConfigValidation validateAnswer;

  final List<String> writes = [];
  final List<String> validateCalls = [];
  int reads = 0;
  int previousCalls = 0;
  int restoreCalls = 0;

  @override
  Future<BackendConfigDocument> read() async {
    reads++;
    return BackendConfigDocument(
      configJson: configJson,
      readOnlySections: const ['relay'],
      hasPrevious: hasPrevious,
    );
  }

  @override
  Future<ConfigValidation> validate(String configJson) async {
    validateCalls.add(configJson);
    return validateAnswer;
  }

  @override
  Future<void> write(String configJson, {String? reason}) async {
    final refusal = writeRefusal;
    if (refusal != null) throw refusal;
    writes.add(configJson);
    this.configJson = configJson;
    hasPrevious = true;
  }

  @override
  Future<BackendConfigDocument?> previous() async {
    previousCalls++;
    return null;
  }

  @override
  Future<void> restorePrevious({String? reason}) async {
    restoreCalls++;
  }
}

/// A station already switched to the gateway, as its device-local row.
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

Future<
    ({
      ScriptedBackendConfig api,
      Preferences shared,
    })> _pumpGateway(
  WidgetTester tester, {
  ScriptedBackendConfig? api,
}) async {
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
        stationNameProvider.overrideWithValue(_station),
        backendConfigApiProvider.overrideWith((ref) async => backend),
      ],
    ),
  );
  return (api: backend, shared: shared);
}

Future<void> _pumpDirect(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      stateManConfig: sampleStateManConfigWithModbus(),
    ),
  );
}

/// Expands the one OPC UA card and types [endpoint] into its endpoint field.
Future<void> _editEndpoint(WidgetTester tester, String endpoint) async {
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
}

Future<void> _tapSave(WidgetTester tester) async {
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

  // ---------------------------------------------------------------------
  // The swap: the typed editor renders in gateway mode, the raw textarea
  // is demoted.
  // ---------------------------------------------------------------------
  testWidgets(
      'gateway mode renders the typed sections, and the primary JSON '
      'textarea is gone', (tester) async {
    await _pumpGateway(tester);

    final section = find.byType(BackendConfigSection);
    expect(
        find.descendant(
            of: section, matching: find.text('OPC-UA Servers')),
        findsOneWidget,
        reason: 'the same typed form direct mode renders — the owner\'s '
            'ruling, made structural');
    expect(
        find.descendant(of: section, matching: find.text('ST101')),
        findsOneWidget,
        reason: 'and it holds the backend\'s actual document, not an empty '
            'form');

    // The 17-13 key stays — but it now names the editor, not a TextField.
    final editorWidget = tester.widget(find.byKey(_editor));
    expect(editorWidget, isNot(isA<TextField>()),
        reason: 'the raw JSON textarea is no longer the primary editor');

  });

  // ---------------------------------------------------------------------
  // Fidelity from the typed form, over the wire.
  // ---------------------------------------------------------------------
  testWidgets(
      'a typed edit crosses with relay byte-verbatim and unknown keys '
      'intact, and the local store is not written', (tester) async {
    final fixture = await _pumpGateway(tester);
    final localBefore = await fixture.shared
        .getString(StateManConfig.configKey, secret: true);

    await _editEndpoint(tester, 'opc.tcp://10.104.20.10:4841');
    await _tapSave(tester);

    expect(fixture.api.writes, hasLength(1),
        reason: 'the save must reach the backend');
    final written =
        jsonDecode(fixture.api.writes.single) as Map<String, dynamic>;
    final opc = (written['opcua'] as List).first as Map<String, dynamic>;
    expect(opc['endpoint'], 'opc.tcp://10.104.20.10:4841',
        reason: 'the edit the operator typed is what crossed');
    expect(opc['vendor_note'], 'kept-verbatim',
        reason: 'unknown per-entry key must survive the typed edit — the '
            'reason ConfigDocument exists');
    expect(written['collector_hints'], {'window': '5m'},
        reason: 'unknown top-level section must survive');
    expect(
        const DeepCollectionEquality()
            .equals(written['relay'], _liveConfig['relay']),
        isTrue,
        reason: 'relay is read-only over the wire (D-10): present, never '
            'silently absent, reproduced exactly');

    final localAfter = await fixture.shared
        .getString(StateManConfig.configKey, secret: true);
    expect(localAfter, localBefore,
        reason: 'the ROADMAP\'s named failure mode: showing the backend\'s '
            'config and saving the station\'s own');
  });

  // ---------------------------------------------------------------------
  // The JSON is gone from the SCREEN — and from the screen only.
  //
  // The owner removed both JSON surfaces by name: the "Advanced — edit as
  // JSON" expansion and the read-only card that printed `relay` into a
  // disabled field. The hazard in obeying that is obvious and is what this
  // arm exists for: a removal that also stopped CARRYING what it stopped
  // SHOWING would look identical on screen and would silently drop the
  // backend's relay section on the next save. So absence and preservation are
  // asserted in one arm, against one document.
  // ---------------------------------------------------------------------
  testWidgets(
      'no JSON is printed on the page, and the sections it used to print '
      'still cross the wire verbatim', (tester) async {
    final fixture = await _pumpGateway(tester);

    expect(find.textContaining('Advanced'), findsNothing,
        reason: 'the JSON expansion is gone by the owner\'s ruling — a '
            'textarea of JSON is not a form for people who do not read JSON');
    expect(find.byKey(_advancedField), findsNothing);
    expect(find.textContaining('read-only from here'), findsNothing,
        reason: 'and so is the disabled card that printed a section\'s JSON');
    expect(find.textContaining('token_file'), findsNothing,
        reason: 'nothing on this page prints the relay section any more, in '
            'either mode — the absence is the whole point of the ruling');

    await _editEndpoint(tester, 'opc.tcp://10.104.20.10:4841');
    await _tapSave(tester);

    final written =
        jsonDecode(fixture.api.writes.single) as Map<String, dynamic>;
    expect(
        const DeepCollectionEquality()
            .equals(written['relay'], _liveConfig['relay']),
        isTrue,
        reason: 'removing the VIEW must not remove the CONTENT: the backend '
            'refuses a document whose relay section differs from the live '
            'one, so a save that dropped it would fail by the wrong name — '
            'and one that dropped it silently would be worse');
    expect(written['collector_hints'], {'window': '5m'},
        reason: 'the same for a top-level section this build has no form '
            'for: unshown is not unkept');
  });

  // ---------------------------------------------------------------------
  // Honest absence: no live status over the relay, said rather than faked.
  // ---------------------------------------------------------------------
  testWidgets(
      'gateway mode draws no status chip and says why the status is '
      'absent', (tester) async {
    await _pumpGateway(tester);

    expect(find.byType(ConnectionStatusChip), findsNothing,
        reason: 'a grey "Not active" chip beside a server the backend may '
            'be connected to right now is a lie — the backend\'s client '
            'health is not on the wire');
    expect(find.text('Not active'), findsNothing);
    expect(find.byKey(_absence), findsOneWidget,
        reason: 'the absence is rendered honestly, once, in words');
    expect(find.textContaining('not visible over the relay'), findsOneWidget);
  });

  testWidgets(
      'direct mode keeps its chips and carries no absence line',
      (tester) async {
    await _pumpDirect(tester);

    expect(find.byType(ConnectionStatusChip), findsWidgets,
        reason: 'direct mode has live per-server status; the chips stay');
    expect(find.byKey(_absence), findsNothing,
        reason: 'the absence line is the gateway\'s fact, not furniture');
  });

  // ---------------------------------------------------------------------
  // Apply semantics: the copy is the transport's answer.
  // ---------------------------------------------------------------------
  testWidgets(
      'gateway mode says restart-to-apply, from applySemantics, at the '
      'save and after it', (tester) async {
    await _pumpGateway(tester);

    expect(find.byKey(_restartNote), findsOneWidget);
    expect(find.textContaining('when the backend restarts'), findsWidgets,
        reason: 'a save that silently changes nothing visible is a save an '
            'operator repeats');

    await _editEndpoint(tester, 'opc.tcp://10.104.20.10:4841');
    await _tapSave(tester);
    expect(find.textContaining('restarts'), findsWidgets,
        reason: 'the saved confirmation says what the save MEANS here');
  });

  testWidgets('direct mode carries no restart-to-apply copy',
      (tester) async {
    await _pumpDirect(tester);

    expect(find.textContaining('when the backend restarts'), findsNothing,
        reason: 'direct applies on save (stateManProvider invalidate); a '
            'restart note here would teach operators to restart things '
            'that need no restart');
  });

  // ---------------------------------------------------------------------
  // The way back: driven by source.hasPrevious(), previous() never asked.
  // ---------------------------------------------------------------------
  testWidgets(
      'restore renders from source.hasPrevious() and previous() is never '
      'called', (tester) async {
    final fixture = await _pumpGateway(
        tester, api: ScriptedBackendConfig(hasPrevious: true));

    expect(find.byKey(_restore), findsOneWidget,
        reason: 'the backend reports a previous document; the way back is '
            'on screen without waiting for a refusal');
    expect(fixture.api.previousCalls, 0,
        reason: '17-10 deviation 4: previous() may refuse by name on a '
            'never-written file, so it is not the "is there something to '
            'restore" question — read().hasPrevious is');

    await tester.ensureVisible(find.byKey(_restore));
    await tester.tap(find.byKey(_restore));
    await settle(tester);
    expect(fixture.api.restoreCalls, 1);
    expect(fixture.api.previousCalls, 0,
        reason: 'and restoring still never asks previous()');
  });

  // ---------------------------------------------------------------------
  // The escape hatch for a document that will not decode.
  // ---------------------------------------------------------------------
  testWidgets(
      'an undecodable document is shown whole as text, repairable from '
      'the panel', (tester) async {
    final fixture = await _pumpGateway(tester,
        api: ScriptedBackendConfig(rawConfigJson: '[1, 2, 3]'));

    expect(find.textContaining('top level must be a JSON object'),
        findsOneWidget,
        reason: 'the parser\'s refusal, verbatim — the operator standing at '
            'the panel is the audience');
    final recovery = tester.widget<TextField>(find.byKey(_recoveryField));
    expect(recovery.controller!.text, '[1, 2, 3]',
        reason: 'the document is the backend\'s truth even when it will '
            'not decode: shown whole, exactly as served');

    // Repair it from the panel — the alternative is SSH.
    await tester.enterText(
        find.byKey(_recoveryField), jsonEncode(_liveConfig));
    await settle(tester);
    await tester.ensureVisible(find.byKey(_recoveryApply));
    await tester.tap(find.byKey(_recoveryApply));
    await settle(tester);

    expect(find.text('OPC-UA Servers'), findsOneWidget,
        reason: 'the repaired document parses, so the typed form takes '
            'over');
    expect(find.text('Save Configuration'), findsOneWidget,
        reason: 'the repair is an unsaved change: the ONE save button is '
            'armed and nothing was written yet');
    expect(fixture.api.writes, isEmpty);

    await _tapSave(tester);
    expect(fixture.api.writes, hasLength(1),
        reason: 'and the fix crosses through the normal save path');
  });

  // ---------------------------------------------------------------------
  // A validate-refused save: the far end's sentence, nothing written.
  // ---------------------------------------------------------------------
  testWidgets(
      'a validate refusal renders the far end\'s sentence verbatim and '
      'nothing is written', (tester) async {
    final fixture = await _pumpGateway(tester,
        api: ScriptedBackendConfig(
            validateAnswer: const ConfigValidation(ok: false, problems: [
          'The `jbtm` entry at index 0 names no host.',
        ])));

    await _editEndpoint(tester, 'opc.tcp://10.104.20.10:4841');
    await _tapSave(tester);

    expect(find.byKey(_refusal), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(_refusal),
            matching: find.textContaining('names no host')),
        findsOneWidget,
        reason: 'the backend\'s own validate() sentence, verbatim — no '
            'local paraphrase');
    expect(fixture.api.writes, isEmpty,
        reason: 'a refused validation must not be followed by the write');
  });
}
