/// Golden images of the transport mode switch, for design review — under the
/// **real station themes**, in both brightnesses.
///
/// Five frames, because they are the five things an operator sees. Collapsed on
/// a direct-mode station: the whole-plant default, where the card must read as a
/// *switch* and not as a fifth section, with the page below it exactly where it
/// was. Expanded on a direct station: the switch itself, above the four sections
/// it governs. A station already pointed at a gateway: the card opens on its own
/// settings, the live link is under the three fields, and the four sections are
/// gone. The note that replaces them. And the hostname advisory, showing while
/// Save is still enabled.
///
/// ## Why this file was re-shot rather than extended
///
/// It used to render through `buildTestableServerConfig`'s bare `MaterialApp`,
/// which carries **no theme at all**. Under that, `HmiStateColors.of(context)`
/// falls back to `solarizedLight` whatever the station is actually running, so
/// the advisory's yellow and the status row's green were never the plant's
/// colours and a regression on the dark scheme could not be caught. Both images
/// are therefore re-shot rather than copied, and each frame is shot twice.
/// The dark half is not decoration: neither Solarized scheme sets
/// `colorScheme.outline`, so an edge borrowed from it is fine in the light image
/// and invisible on base03 (project memory `solarized-outline-is-invisible`).
///
/// ## Image names
///
/// `server_config_transport_direct.png` and `server_config_transport_gateway.png`
/// keep their names and keep the frames they already held — the expanded direct
/// station and the gateway station. The diff is then a re-shoot of two images
/// plus three additions, with nothing deleted, which is what reads in a PR. The
/// three new frames take the same prefix so the set greps as one.
///
/// ## Fonts
///
/// The private FontAwesome/MaterialIcons loader this file used to carry is
/// gone; `loadThemedGoldenFonts()` covers the same ground. That loader also
/// carried a hardcoded `/opt/homebrew/share/flutter/...` fallback, which on this
/// machine is the **wrong Flutter** — `.flutter-version` pins 3.44.9 and the
/// global install is 3.41.9 — so it could quietly rasterise MaterialIcons from
/// one toolchain into an image authored on another.
///
/// To update: derive the failing set first by running without the flag (never a
/// blanket `--update-goldens` over the directory), then
/// `flutter test test/widgets/server_config_transport_golden_test.dart --update-goldens`.
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/widgets/gateway_link_status_row.dart';
import 'package:tfc_dart/core/preferences.dart';

import '../helpers/test_helpers.dart';
import '../helpers/themed_golden_host.dart';

/// Tall enough that the whole page is laid out and painted at once — the
/// sections live in a SingleChildScrollView, and anything below the fold
/// would capture as blank.
const Size _surface = Size(760, 1300);

final Uri _gatewayUrl = Uri.parse('wss://10.50.10.11:9443');

/// A live session, for the frame whose whole subject is the status row being
/// green. Built by the real mapper from the real inputs, so the prose in the
/// image is the prose the plant gets.
final GatewayLinkReport _connectedReport = describeGatewayLink(
  state: LinkState.ready,
  url: _gatewayUrl,
  elapsed: const Duration(seconds: 4),
);

StateManConfig _configWithOneOfEach() => StateManConfig(
      opcua: [
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.20.11:4840'
          ..serverAlias = 'ST101',
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.20.13:4840'
          ..serverAlias = 'ST301'
          ..enabled = false,
      ],
      jbtm: [
        M2400Config(host: '10.104.29.71')..serverAlias = 'W01',
        M2400Config(host: '10.104.29.78', enabled: false)..serverAlias = 'W08',
      ],
      modbus: [
        ModbusConfig(host: '10.104.20.30', serverAlias: 'BAADER'),
        ModbusConfig(
            host: '10.104.20.31', serverAlias: 'MULTIVAC', enabled: false),
      ],
    );

/// A device-local store already pointed at the gateway.
Future<PreferencesApi> _savedGatewayStation() async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(
    local,
    const GatewayConfig(
      mode: TransportMode.gateway,
      url: 'wss://10.50.10.11:9443',
      caCertPath: '/home/centroid/relay_config/pki/ca.pem',
    ),
  );
  return local;
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());

    // The Import/Export card at the bottom of the page reads PackageInfo in
    // initState. Unmocked it throws MissingPluginException mid-capture and
    // fails the golden.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc',
        'packageName': 'is.centroid.tfc',
        'version': '0.0.0',
        'buildNumber': '0',
      },
    );
  });

  // The server cards are built almost entirely out of FontAwesome and Material
  // icons — the power toggle being the whole point of one of these frames — and
  // the test environment registers neither by default. Without this the image
  // comes out as rows of tofu boxes.
  setUpAll(loadThemedGoldenFonts);

  group('transport mode golden',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    Future<void> pumpPage(
      WidgetTester tester, {
      required bool dark,
      PreferencesApi? localPreferences,
      GatewayLinkReport? linkReport,
    }) async {
      await tester.binding.setSurfaceSize(_surface);
      // 1:1 pixels — this golden is for reading in a PR, not pixel
      // archaeology.
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pumpAndLoad(
        tester,
        buildTestableServerConfig(
          stateManConfig: _configWithOneOfEach(),
          localPreferences: localPreferences,
          theme: themedGoldenTheme(dark: dark),
          overrides: [
            if (linkReport != null)
              gatewayLinkProvider.overrideWith((ref) => Stream.value(linkReport)),
          ],
        ),
      );
    }

    /// Every frame on this page asserts this in the pump that records it.
    ///
    /// P-7 was a `CircularProgressIndicator` that never went away: the card
    /// re-entered its own load from `build`, so a device-local read that failed
    /// left the operator looking at a spinner forever. Plan 15-05 moved the
    /// load to `initState` and bounded it. A golden cannot tell a spinner that
    /// is about to disappear from one that is not, so the property is asserted
    /// rather than looked at.
    void expectNoSpinner(String frame) {
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '$frame: the page has finished loading, and an indeterminate '
              'indicator here is the shape of a promise the card cannot keep '
              '(P-7)');
    }

    for (final dark in [false, true]) {
      final label = dark ? 'dark' : 'light';
      final suffix = dark ? '_dark' : '';

      testWidgets('direct station, collapsed — the whole-plant default, $label',
          (tester) async {
        await pumpPage(tester, dark: dark);
        expectNoSpinner('direct collapsed');

        // The point of the frame: the card is a switch, not a fifth section,
        // and the four sections below it are where they were.
        expect(find.text('OPC-UA Servers'), findsOneWidget);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              'goldens/server_config_transport_direct_collapsed$suffix.png'),
        );
      });

      testWidgets('direct station, card opened, $label', (tester) async {
        await pumpPage(tester, dark: dark);
        await tester.tap(find.text('Transport'));
        await settle(tester);
        expectNoSpinner('direct expanded');

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/server_config_transport_direct$suffix.png'),
        );
      });

      testWidgets('gateway station, connected — the status row green, $label',
          (tester) async {
        await pumpPage(
          tester,
          dark: dark,
          localPreferences: await _savedGatewayStation(),
          linkReport: _connectedReport,
        );
        expectNoSpinner('gateway connected');

        // Anti-vacuity: this frame's whole subject is the live row, and the
        // page renders perfectly well without it — null is direct mode and
        // renders as absence. Name it before recording.
        expect(find.byKey(kGatewayLinkStatusRowKey), findsOneWidget,
            reason: 'this image is only a connected-gateway golden if the '
                'status row is in it');

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              'goldens/server_config_transport_gateway$suffix.png'),
        );
      });

      testWidgets('the hidden-sections note, corrected copy, $label',
          (tester) async {
        await pumpPage(
          tester,
          dark: dark,
          localPreferences: await _savedGatewayStation(),
        );
        expectNoSpinner('hidden note');

        // Framed on the note itself rather than on the whole page: the frame's
        // subject is the *copy*, and a full-page capture of it is the gateway
        // frame above with one row missing. The sentence being checked is the
        // second paragraph — the one that stopped claiming this station opens
        // no connections of its own, because it opens exactly one, to Postgres.
        final note = find
            .ancestor(
              of: find.textContaining('It still opens one Postgres connection'),
              matching: find.byType(Card),
            )
            .first;
        expect(note, findsOneWidget);

        await expectLater(
          note,
          matchesGoldenFile(
              'goldens/server_config_transport_hidden_note$suffix.png'),
        );
      });

      testWidgets('the hostname advisory, with Save still enabled, $label',
          (tester) async {
        // Typed by hand from a direct station, so `_hasUnsavedChanges` is
        // genuinely true and the button's enabled state is about the advisory
        // rather than about there being nothing to save.
        await pumpPage(tester, dark: dark);
        await tester.tap(find.text('Transport'));
        await settle(tester);
        await tester.tap(find.text('Relay gateway'));
        await settle(tester);
        await tester.enterText(
            find.byType(TextField).first, 'wss://plc-gw.svn:9444');
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(1), '/pki/ca.pem');
        await settle(tester);
        expectNoSpinner('advisory');

        expect(find.textContaining('subject-alternative name'), findsOneWidget,
            reason: 'the operator has to learn this while the keyboard is '
                'still in their hands, not at the next restart');

        // The property, in the same pump that records the image. An advisory
        // that reads as a refusal and stops a legitimate DNS-SAN plant from
        // saving is the threat (T-15-23), and a picture of a yellow row cannot
        // tell you whether the button under it is dead.
        expect(find.text('Cannot save yet'), findsNothing);
        final save = tester.widget<ElevatedButton>(find
            .ancestor(
                of: find.text('Save Configuration'),
                matching: find.byType(ElevatedButton))
            .first);
        expect(save.onPressed, isNotNull,
            reason: 'advisory is not refusal: a plant that provisions DNS SANs '
                'is legitimate and must be allowed to save');

        final card = find
            .ancestor(
                of: find.text('Transport'), matching: find.byType(Card))
            .first;
        await expectLater(
          card,
          matchesGoldenFile(
              'goldens/server_config_transport_advisory$suffix.png'),
        );
      });
    }
  });
}
