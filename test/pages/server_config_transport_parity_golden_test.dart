/// The Server Config page, whole, in both transports — the pair of images
/// the owner's ruling is actually about.
///
/// > "the server config should look exactly the same as with gateway and
/// > without gateway … the only difference is a toggle at the top for
/// > gateway, where you enter the address and port."
///
/// A single image cannot state that. These are shot as a **pair per theme**,
/// same width, same fixtures, same three sections on each side, so the two can
/// be laid beside each other and the differences counted by eye: the address
/// field inside the transport card, the target chip instead of the station
/// caption, the attribution line, and the two cards that say what they do not
/// do on a gateway station. Nothing else may differ.
///
/// Both brightnesses, because half the point of the page is colour that has to
/// survive the dark scheme the night shift runs (project memory
/// `solarized-outline-is-invisible`).
///
/// To update: flutter test test/pages/server_config_transport_parity_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument, ConfigValidation;

import '../helpers/test_helpers.dart';
import '../helpers/themed_golden_host.dart';

/// Tall enough for the whole page in either mode; wide enough that the card
/// headers stay on one row (they collapse below 500px).
const Size _viewport = Size(900, 1900);

const _gatewayUrl = 'wss://centroidx-backend:9443';

/// One OPC UA server, the same one on both sides, so the two images differ by
/// the page and not by their fixtures.
const _sharedOpcua = <String, Object?>{
  'endpoint': 'opc.tcp://10.104.20.10:4840',
  'server_alias': 'ST101',
  'publishing_interval_ms': 250,
};

const _backendConfig = <String, Object?>{
  'opcua': [_sharedOpcua],
  'relay': <String, Object?>{
    'port': 9443,
    'token_file': '/etc/centroid/relay-tokens.json',
  },
};

class _ScriptedBackend implements BackendConfigApi {
  @override
  Future<BackendConfigDocument> read() async => BackendConfigDocument(
        configJson: jsonEncode(_backendConfig),
        readOnlySections: const ['relay'],
        hasPrevious: false,
      );

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);

  @override
  Future<void> write(String configJson, {String? reason}) async {}

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
      // Pinned, so the card shows the settled state an operator finds rather
      // than the "Save fetches the identity" promise.
      caPem: '-----BEGIN CERTIFICATE-----\n'
          'dGhlIHBsYW50IENBLCBhcyBhcHByb3ZlZCBieSB0aGUgb3BlcmF0b3I=\n'
          '-----END CERTIFICATE-----\n',
    ),
  );
  return prefs;
}

Future<void> _prepare(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these goldens are for reading, not for pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _pumpDirect(WidgetTester tester, {required bool dark}) async {
  await _prepare(tester);
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      theme: themedGoldenTheme(dark: dark),
      stateManConfig: StateManConfig(
        opcua: [
          OpcUAConfig()
            ..endpoint = _sharedOpcua['endpoint'] as String
            ..serverAlias = _sharedOpcua['server_alias'] as String,
        ],
      ),
    ),
  );
}

Future<void> _pumpGateway(WidgetTester tester, {required bool dark}) async {
  await _prepare(tester);
  await pumpAndLoad(
    tester,
    buildTestableServerConfig(
      theme: themedGoldenTheme(dark: dark),
      localPreferences: await _gatewayStation(),
      overrides: [
        backendConfigApiProvider.overrideWith((ref) async => _ScriptedBackend()),
        gatewayVerifiedAccountProvider.overrideWith((ref) async => 'st101-panel'),
        // A working station. Without this the fixture's absent StateMan
        // publishes the honest "could not build its gateway connection"
        // block, and the pair of images would then be comparing a healthy
        // direct page against a broken gateway one — a difference in the
        // fixtures, photographed as if it were a difference in the page.
        gatewayLinkProvider.overrideWith((ref) => Stream.value(
              GatewayLinkReport(
                kind: GatewayLinkKind.connected,
                headline: 'Connected to $_gatewayUrl',
                detail: 'The panel is holding a live session.',
                url: Uri.parse(_gatewayUrl),
              ),
            )),
      ],
    ),
  );
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

void main() {
  setUpAll(loadThemedGoldenFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());

    // The import/export card asks the platform for the build version in
    // `initState` — including in gateway mode, where its build renders the
    // statement face instead of the buttons. Unmocked it throws a
    // MissingPluginException into the frame.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc-hmi',
        'packageName': 'is.centroid.tfc',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );
  });

  testWidgets('direct — the whole page, light', (tester) async {
    await _pumpDirect(tester, dark: false);
    await _expectGolden(tester, 'server_config_direct_light.png');
  });

  testWidgets('gateway — the whole page, light', (tester) async {
    await _pumpGateway(tester, dark: false);
    await _expectGolden(tester, 'server_config_gateway_light.png');
  });

  testWidgets('direct — the whole page, dark', (tester) async {
    await _pumpDirect(tester, dark: true);
    await _expectGolden(tester, 'server_config_direct_dark.png');
  });

  testWidgets('gateway — the whole page, dark', (tester) async {
    await _pumpGateway(tester, dark: true);
    await _expectGolden(tester, 'server_config_gateway_dark.png');
  });
}
