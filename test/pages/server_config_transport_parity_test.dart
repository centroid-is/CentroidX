/// One page, two transports, the same shape — the owner's ruling as
/// geometry.
///
/// > "the server config should look exactly the same as with gateway and
/// > without gateway … the only difference is a toggle at the top for
/// > gateway, where you enter the address and port."
///
/// The earlier unification made the *editor* the same widget in both modes.
/// What was left was page furniture: gateway mode grew a Backend
/// Configuration header card and lost the database and import/export cards
/// entirely, so the two faces still read as two screens. These arms hold the
/// page to one shape.
///
/// They are structural rather than golden on purpose. A golden of each mode
/// proves each image is what it was yesterday; it cannot state that the two
/// images are the same page, and it cannot fail when one mode quietly loses a
/// section. The goldens in `server_config_transport_parity_golden_test.dart`
/// are for the eye; these arms are the claim.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/widgets/config_target_banner.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument, ConfigValidation;

import '../helpers/test_helpers.dart';

const _gatewayUrl = 'wss://10.50.10.11:9443';

/// The backend's document: one OPC UA server and the read-only `relay`
/// section, so the gateway face has the same three sections to render that a
/// configured direct station has.
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

/// A far end that answers and records nothing else — the wire is 17-08's
/// territory and this file is about the page's shape.
class _ScriptedBackend implements BackendConfigApi {
  String configJson = jsonEncode(_liveConfig);

  @override
  Future<BackendConfigDocument> read() async => BackendConfigDocument(
        configJson: configJson,
        readOnlySections: const ['relay'],
        hasPrevious: false,
      );

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);

  @override
  Future<void> write(String configJson, {String? reason}) async {
    this.configJson = configJson;
  }

  @override
  Future<BackendConfigDocument?> previous() async => null;

  @override
  Future<void> restorePrevious({String? reason}) async {}
}

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

/// Tears the previous page down before the next one goes up.
///
/// Two `ProviderScope`s with different override counts cannot replace one
/// another in place (riverpod asserts on it), and every arm here pumps both
/// faces of the page to compare them. An empty frame between is the whole
/// fix, and it is also honest: the two faces are two boots, not a live swap —
/// transport is restart-to-apply.
Future<void> _clear(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await settle(tester);
}

/// The page in gateway mode, over a backend that answers.
Future<void> _pumpGateway(WidgetTester tester) async {
  await _clear(tester);
  await tester.binding.setSurfaceSize(const Size(900, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      localPreferences: await _gatewayStation(),
      overrides: [
        backendConfigApiProvider.overrideWith((ref) async => _ScriptedBackend()),
      ],
    ),
  );
}

/// The page in direct mode, over a station configured with one server of each
/// kind — the same three sections the backend serves, so a difference in the
/// list of slots is a difference in the PAGE and not in the fixtures.
Future<void> _pumpDirect(WidgetTester tester) async {
  await _clear(tester);
  await tester.binding.setSurfaceSize(const Size(900, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      stateManConfig: StateManConfig(
        opcua: [
          OpcUAConfig()
            ..endpoint = 'opc.tcp://10.104.20.10:4840'
            ..serverAlias = 'ST101',
        ],
      ),
    ),
  );
}

/// The page's slots, named, in the order they are laid out.
///
/// Read from geometry rather than from the widget tree so that a slot moved
/// into some wrapper still counts as being where it looks like it is — which
/// is the only sense in which an operator can say two pages look the same.
List<String> _slotOrder(WidgetTester tester) {
  final slots = <String, Finder>{
    'transport': find.byType(TransportModeCard).first,
    'target banner': find.byKey(kConfigTargetBannerKey).first,
    'database': find.text('Database Configuration').first,
    'opcua': find.text('OPC-UA Servers').first,
    'jbtm': find.text('JBTM M2400 Servers').first,
    'modbus': find.text('Modbus TCP Servers').first,
    // `.last`, and this is the one place the page has two of something: the
    // transport card carries its own save button for the device-local row,
    // and both buttons wear the same three words when there is nothing to
    // save. The lower one is the document's, which is the slot meant here.
    'save': find.text('All Changes Saved').last,
    'import/export': find.text('Import / Export').first,
  };
  final found = <(double, String)>[];
  for (final entry in slots.entries) {
    if (entry.value.evaluate().isEmpty) continue;
    found.add((tester.getRect(entry.value).top, entry.key));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, name) in found) name];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  testWidgets('the page has the same slots, in the same order, in both '
      'transports', (tester) async {
    await _pumpDirect(tester);
    final direct = _slotOrder(tester);

    await _pumpGateway(tester);
    final gateway = _slotOrder(tester);

    expect(direct, gateway,
        reason: 'the owner\'s ruling, as one comparison: whatever the page '
            'shows in one transport it shows in the other, in the same '
            'order. This fails on a slot dropped in either direction — '
            'which is exactly how gateway mode came to look like a '
            'different screen (no database card, no import/export, and a '
            'Backend Configuration header nothing else has)');

    // Anti-vacuity: two empty lists compare equal. The order below is the
    // page, spelled out, so a change to it is a decision somebody made.
    expect(
        direct,
        [
          'transport',
          'target banner',
          'database',
          'opcua',
          'jbtm',
          'modbus',
          'save',
          'import/export',
        ],
        reason: 'and the shape itself is pinned: transport first (it is the '
            'one difference), then the target it applies to, then the '
            'sections, then the one save button, then transfer');
  });

  testWidgets('the target is named in both modes — this station, or the '
      'backend being dialled', (tester) async {
    await _pumpDirect(tester);
    expect(
        find.descendant(
            of: find.byKey(kConfigTargetBannerKey),
            matching: find.textContaining(kTestStationName)),
        findsOneWidget,
        reason: 'sameness of shape must not cost the ACCESS-04 affordance: '
            'the machine about to be edited is named');

    await _pumpGateway(tester);
    expect(
        find.descendant(
            of: find.byKey(kConfigTargetBannerKey),
            matching: find.textContaining('10.50.10.11')),
        findsOneWidget,
        reason: 'and in gateway mode it is the endpoint the panel dials — '
            'silently configuring the wrong machine is the failure mode the '
            'ROADMAP names before it names the feature');
  });

  testWidgets('no JSON is on the page in either transport', (tester) async {
    for (final pump in [_pumpDirect, _pumpGateway]) {
      await pump(tester);
      expect(find.textContaining('Advanced'), findsNothing,
          reason: 'the "Advanced — edit as JSON" expansion is gone by the '
              'owner\'s ruling, in BOTH modes — it was one widget, shared');
      expect(find.textContaining('read-only from here'), findsNothing);
      expect(find.textContaining('token_file'), findsNothing,
          reason: 'and nothing prints a section as JSON anywhere');
    }
  });

  testWidgets('the address field is the only thing gateway mode adds',
      (tester) async {
    await _pumpDirect(tester);
    expect(find.text('Gateway address and port'), findsNothing,
        reason: 'a direct station is asked for no address');

    await _pumpGateway(tester);
    expect(find.text('Gateway address and port'), findsOneWidget,
        reason: 'the toggle at the top, and under it the one question the '
            'gateway transport actually needs answered');
    expect(find.textContaining('10.50.10.11:9443'), findsWidgets,
        reason: 'filled in from the saved row, not an empty field beside a '
            'station that is already dialling');
  });
}
