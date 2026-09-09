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

import 'dart:async';
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
import 'package:tfc/core/gateway_trust.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/widgets/gateway_identity_dialog.dart';
import 'package:tfc/widgets/gateway_link_status_row.dart';
import 'package:tfc_dart/core/preferences.dart';

import '../helpers/test_helpers.dart';
import '../helpers/themed_golden_host.dart';
import '../helpers/golden_tolerance.dart';

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

/// What the one-field flow leaves in the row: material, not a path. The
/// gateway frames below therefore show the pinned-CA line with its
/// fingerprint — the state every station configured through the ceremony is
/// in, and the state the operator reads to answer "what does this panel
/// trust".
const String _pinnedPem = '-----BEGIN CERTIFICATE-----\n'
    'dGhlIHBsYW50IENBLCBhcyBhcHByb3ZlZCBieSB0aGUgb3BlcmF0b3I=\n'
    '-----END CERTIFICATE-----\n';

/// A device-local store already pointed at the gateway.
Future<PreferencesApi> _savedGatewayStation() async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(
    local,
    const GatewayConfig(
      mode: TransportMode.gateway,
      url: 'wss://10.50.10.11:9443',
      caPem: _pinnedPem,
    ),
  );
  return local;
}

void main() {
  // Same reason as the app-bar strip: a whole transport card of antialiased
  // text drifts at the 0.01% default between this machine and CI's macOS
  // runner, while reproducing exactly here. A real change to the card is far
  // larger than this margin.
  useTolerantGoldenComparator(tolerance: 0.002);

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
      bool pinLinkUnresolved = false,
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
            // A stream that never carries anything and is never closed: the
            // provider stays `AsyncLoading`, which is a *different* state from
            // one that resolved to `null`. A closed empty stream would be a
            // third thing again. `gateway_link_chip_test.dart:151-158` states
            // the same distinction for the same reason.
            if (pinLinkUnresolved)
              gatewayLinkProvider.overrideWith((ref) {
                final controller = StreamController<GatewayLinkReport?>();
                ref.onDispose(controller.close);
                return controller.stream;
              }),
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
        expect(find.textContaining('Pinned plant CA'), findsOneWidget,
            reason: 'the one-field flow\'s answer to "what does this panel '
                'trust" is this line and its fingerprint; a gateway frame '
                'without it is a frame of the old card');

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              'goldens/server_config_transport_gateway$suffix.png'),
        );
      });

      // The hidden-sections-note frame is gone with its subject: the owner
      // deleted the note itself ("it is implied by the toggle switch in
      // Transport"), so a frame whose stated subject was that note's
      // corrected Postgres paragraph has nothing left to photograph. The
      // rule that the note stays absent is functional, in
      // `server_config_transport_mode_test.dart` — a golden of presence
      // cannot guard an absence, and a golden of absence guards nothing.

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
        expectNoSpinner('advisory');

        // This frame gained a second sentence with the one-field flow: the
        // trust note, because a hostname dial with nothing pinned is exactly
        // the state Save's ceremony exists for. Named so the frame cannot
        // silently lose it.
        expect(find.textContaining('No plant CA pinned yet'), findsOneWidget);

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

        // Whole-page, for the reason given on the hidden-note frame above: a
        // finder aimed at the Transport `Card` does not crop to that card, it
        // captures whatever repaint boundary happens to enclose it.
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              'goldens/server_config_transport_advisory$suffix.png'),
        );
      });

      testWidgets('the identity ceremony: fingerprint, Approve, Reject, $label',
          (tester) async {
        // The dialog alone, at its own size: it is the one security prompt
        // in the flow, the operator reads it exactly once per plant CA, and
        // its whole job is a fingerprint legible enough to compare character
        // by character — which is what this frame reviews.
        await tester.binding.setSurfaceSize(const Size(560, 480));
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themedGoldenTheme(dark: dark),
          home: Scaffold(
            body: GatewayIdentityDialog(
              gateway: Uri.parse('wss://10.50.10.11:9443'),
              fingerprint: caFingerprintSha256(_pinnedPem),
            ),
          ),
        ));
        await settle(tester);

        expect(find.text('Approve'), findsOneWidget);
        expect(find.text('Reject'), findsOneWidget);
        expect(find.textContaining('certificate authority'), findsWidgets);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              'goldens/server_config_gateway_identity_dialog$suffix.png'),
        );
      });
    }
  });
}
