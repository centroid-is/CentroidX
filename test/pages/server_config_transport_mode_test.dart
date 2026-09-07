import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/gateway_link_status_row.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// A station already switched to the gateway, as its preferences row.
Future<PreferencesApi> _gatewayStation({
  String url = 'wss://10.50.10.11:9443',
  String? caCertPath = '/pki/ca.pem',
}) async {
  final prefs = InMemoryPreferences();
  await writeGatewayConfig(
    prefs,
    GatewayConfig(
      mode: TransportMode.gateway,
      url: url,
      caCertPath: caCertPath,
    ),
  );
  return prefs;
}

/// Opens the transport card, which is collapsed on a direct-mode station.
Future<void> _expandTransport(WidgetTester tester) async {
  await tester.tap(find.text('Transport'));
  await settle(tester);
}

/// The four direct-mode sections, by the headings they render.
void _expectDirectSections(Matcher matcher) {
  expect(find.text('OPC-UA Servers'), matcher);
  expect(find.text('JBTM M2400 Servers'), matcher);
  expect(find.text('Modbus TCP Servers'), matcher);
}

/// A device-local store that cannot read the transport row.
///
/// This is a real station condition, not a hypothetical: the row lives in a
/// file-backed store on the panel, and a store that will not answer is the
/// input that used to spin [TransportModeCard] forever with the rejection
/// landing on the ambient error handler (15-RESEARCH P-7). Only
/// [GatewayConfig.prefsKey] throws, so the arm measures the card's own load and
/// not every other consumer of the same store on the page.
class _UnreadableStore extends InMemoryPreferences {
  _UnreadableStore();

  /// Flipped to false by the retry arm, which is the whole point of a retry.
  bool broken = true;

  /// How many times the card asked. A retry that never re-reads is a refusal
  /// with a dead button on it.
  int reads = 0;

  @override
  Future<String?> getString(String key) async {
    if (key == GatewayConfig.prefsKey) {
      reads++;
      if (broken) {
        throw const FileSystemFailure('the device-local store did not answer');
      }
    }
    return super.getString(key);
  }
}

/// A named failure, so the card's error frame has something to quote and the
/// arm can look for it rather than for "Exception".
class FileSystemFailure implements Exception {
  const FileSystemFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The one report the two override arms drive the card with.
GatewayLinkReport _report({
  GatewayLinkKind kind = GatewayLinkKind.connected,
  String headline = 'Connected to wss://10.50.10.11:9443',
  String detail = 'The panel is holding a live session.',
  bool terminal = false,
}) =>
    GatewayLinkReport(
      kind: kind,
      headline: headline,
      detail: detail,
      terminal: terminal,
      url: Uri.parse('wss://10.50.10.11:9443'),
    );

/// `buildTestableServerConfig` with one more override.
///
/// **Duplicated on purpose, and only until plan 15-07.** That plan owns
/// `test/helpers/test_helpers.dart` and adds an `overrides` parameter to
/// `buildTestableServerConfig` properly; two plans editing that file in the
/// same wave is how a helper ends up with two half-merged signatures. The
/// override list below is copied verbatim from
/// `test_helpers.dart:311-333` — when 15-07 lands, delete this and pass the
/// extra overrides through.
Widget _serverConfigWith(
  List<Override> extra, {
  PreferencesApi? localPreferences,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences()),
      localPreferencesProvider
          .overrideWithValue(localPreferences ?? InMemoryPreferences()),
      databaseProvider.overrideWith((ref) async => null),
      stateManProvider
          .overrideWith((ref) => throw StateError('No StateMan in tests')),
      ...extra,
    ],
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: ServerConfigBody()),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  group('transport mode switch', () {
    testWidgets('a station that has never been configured is direct, and the '
        'four sections are exactly as they were', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());

      expect(find.text('Transport'), findsOneWidget);
      // Collapsed, so the page below it is where it always was.
      expect(find.byType(SegmentedButton<TransportMode>), findsNothing);
      expect(find.text('Direct to PLCs'), findsOneWidget,
          reason: 'the collapsed subtitle names the mode without opening it');

      await _expandTransport(tester);
      expect(
        tester
            .widget<SegmentedButton<TransportMode>>(
                find.byType(SegmentedButton<TransportMode>))
            .selected,
        {TransportMode.direct},
      );
      _expectDirectSections(findsOneWidget);
      // No gateway fields until gateway is chosen — the card is a switch, not
      // a fifth section.
      expect(find.text('Gateway address'), findsNothing);
    });

    testWidgets('choosing the gateway reveals the three things a dial needs',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _expandTransport(tester);

      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      expect(find.text('Gateway address'), findsOneWidget);
      expect(find.text('Plant CA certificate (PEM path)'), findsOneWidget);
      expect(find.text('Station credential file (optional)'), findsOneWidget);
    });

    // Restart-to-apply: the running panel is on the saved transport, so moving
    // a radio button must not make the page claim the switch already happened.
    testWidgets('the four sections stay while the change is unsaved',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _expandTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      _expectDirectSections(findsOneWidget);
    });

    testWidgets('a saved gateway station hides the four sections and says why',
        (tester) async {
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: await _gatewayStation()),
      );

      _expectDirectSections(findsNothing);
      expect(find.text('Database Configuration'), findsNothing);
      // Changed in 15-05, deliberately, and it is the only line of the file's
      // original eight arms this plan touched. It used to assert the note said
      // the station "opens no connections of its own" — which the rig measured
      // as false (13-RIG-E2E-EVIDENCE FIND-C: one Postgres connection to
      // 172.18.0.6:5432 live throughout gateway mode). An arm pinning a false
      // sentence keeps it false, so it now pins the honest one instead; the
      // absence half is `test/core/gateway_copy_test.dart`'s.
      expect(
        find.textContaining('no OPC UA session'),
        findsOneWidget,
      );
    });
  });

  group('refusing a configuration that cannot be dialled', () {
    testWidgets('wss with no CA root is refused, and save stays disabled',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _expandTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);

      expect(find.textContaining('CA root'), findsOneWidget);
      // Not "All Changes Saved": there are changes, and the operator can see
      // them. The button says it will not take them yet.
      expect(find.text('Cannot save yet'), findsOneWidget);
      final save = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Cannot save yet'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(save.onPressed, isNull,
          reason: 'a panel that cannot dial must not be saveable: the refusal '
              'belongs here, not in a start-up error at the next boot');
    });

    testWidgets('adding the CA root clears the refusal and enables save',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _expandTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), '/pki/ca.pem');
      await settle(tester);

      expect(find.textContaining('CA root'), findsNothing);
      final save = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Save Configuration'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(save.onPressed, isNotNull);
    });
  });

  group('saving', () {
    testWidgets('writes to the device-local store, and says restart',
        (tester) async {
      final local = InMemoryPreferences();
      await pumpAndLoad(
          tester, buildTestableServerConfig(localPreferences: local));
      await _expandTransport(tester);

      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), '/pki/ca.pem');
      await settle(tester);

      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      final saved = await readGatewayConfig(local);
      expect(saved.mode, TransportMode.gateway);
      expect(saved.url, 'wss://10.50.10.11:9443');
      expect(saved.caCertPath, '/pki/ca.pem');

      expect(find.textContaining('Restart the HMI'), findsOneWidget);
    });

    // The one property that separates this from every other section on the
    // page: a gateway URL must not travel to the plant's other stations.
    testWidgets('never writes to the shared, DB-backed store', (tester) async {
      final local = InMemoryPreferences();
      final shared = await createTestPreferences(
          stateManConfig: StateManConfig(opcua: const []));
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: local),
      );
      await _expandTransport(tester);

      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'ws://bench:9443');
      await settle(tester);
      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      expect(await local.getString(GatewayConfig.prefsKey), isNotNull);
      expect(await shared.getString(GatewayConfig.prefsKey), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // The hostname advisory — rig FIND-B, and the widget half of the rule
  // ---------------------------------------------------------------------
  //
  // Plan 15-02 landed the value-level half: `GatewayConfig.advisory` fires on a
  // DNS-name `wss://` host and is null on an address, and a unit arm models the
  // button's predicate (`_hasUnsavedChanges && refusal == null`) and asserts it
  // stays true. That arm models the widget. These two watch it.
  //
  // The pair is deliberate: on its own, "no advisory row" (the second arm)
  // passes on a card that can never render one at all. The first arm is the
  // other direction.

  group('the hostname advisory shows without disabling Save', () {
    /// Direct station → gateway, typed by hand, so `_hasUnsavedChanges` is
    /// genuinely true and the button's enabled state is about the advisory
    /// rather than about there being nothing to save.
    Future<void> typeGateway(WidgetTester tester, String url) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _expandTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, url);
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), '/pki/ca.pem');
      await settle(tester);
    }

    testWidgets('a wss dial by name shows the advisory and Save stays enabled',
        (tester) async {
      await typeGateway(tester, 'wss://plc-gw.svn:9444');

      expect(find.textContaining('subject-alternative name'), findsOneWidget,
          reason: 'the operator has to learn this while the keyboard is still '
              'in their hands, not at the next restart');

      // The property, not the label: an advisory that reads as a refusal and
      // stops a legitimate DNS-SAN plant from saving is the threat (T-15-23).
      expect(find.text('Cannot save yet'), findsNothing);
      final save = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Save Configuration'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(save.onPressed, isNotNull,
          reason: 'advisory is not refusal: a plant that provisions DNS SANs '
              'is legitimate and must be allowed to save');
    });

    testWidgets('a wss dial by address shows no advisory at all',
        (tester) async {
      await typeGateway(tester, 'wss://10.50.10.11:9443');

      expect(find.textContaining('subject-alternative name'), findsNothing,
          reason: 'on an address dial the name is not a candidate cause, and '
              'a hint that is always shown is a hint nobody reads');
      final save = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Save Configuration'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(save.onPressed, isNotNull);
    });
  });

  // ---------------------------------------------------------------------
  // The spinner that never stopped — 15-RESEARCH P-7
  // ---------------------------------------------------------------------
  //
  // Never `pumpAndSettle` in this group: it does not return while a
  // `CircularProgressIndicator` is in the tree, and the indicator is the very
  // widget these arms exist to remove. A hang is not a red.

  group('a device-local store that will not answer', () {
    testWidgets('renders a refusal with a Retry, and no spinner survives',
        (tester) async {
      final store = _UnreadableStore();
      await pumpAndLoad(
          tester, buildTestableServerConfig(localPreferences: store));

      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a card that cannot read its own settings must say so; a '
              'spinner that never stops is the failure criterion 2 forbids');
      expect(find.textContaining('did not answer'), findsOneWidget,
          reason: 'the refusal names the failure rather than "Error"');
      expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
    });

    testWidgets('and the Retry actually re-reads once the store recovers',
        (tester) async {
      final store = _UnreadableStore();
      await pumpAndLoad(
          tester, buildTestableServerConfig(localPreferences: store));
      final readsBefore = store.reads;

      store.broken = false;
      await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
      await settle(tester);

      expect(store.reads, greaterThan(readsBefore),
          reason: 'a refusal with a dead retry is a spinner with extra steps');
      expect(find.textContaining('did not answer'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Transport'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------
  // The honest copy — rig FIND-C
  // ---------------------------------------------------------------------

  group('the hidden-sections note tells the truth about Postgres', () {
    testWidgets('it names the Postgres connection and claims no more than that',
        (tester) async {
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: await _gatewayStation()),
      );

      expect(find.textContaining('Postgres'), findsOneWidget,
          reason: 'the rig measured one Postgres connection live throughout '
              'gateway mode, for sign-in, preferences and the audit trail');
      expect(find.textContaining('no connections of its own'), findsNothing);
      expect(
          find.textContaining('The database, OPC UA, JBTM and Modbus settings '
              'belong to the gateway'),
          findsNothing,
          reason: 'the database settings do not belong to the gateway; this '
              'station still uses its own');
    });
  });

  // ---------------------------------------------------------------------
  // The live status row — surface (a) of two
  // ---------------------------------------------------------------------

  group('the live link status row', () {
    testWidgets('is in the card on a gateway station', (tester) async {
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayLinkProvider
                .overrideWith((ref) => Stream.value(_report())),
          ],
          localPreferences: await _gatewayStation(),
        ),
      );

      expect(find.byKey(kGatewayLinkStatusRowKey), findsOneWidget);
    });

    testWidgets('and is absent on a direct station', (tester) async {
      // Direct mode publishes null, and null must render as *absence* rather
      // than as an empty pill (15-04's handover note).
      await pumpAndLoad(
        tester,
        _serverConfigWith([
          gatewayLinkProvider.overrideWith((ref) => Stream.value(null)),
        ]),
      );
      await _expandTransport(tester);

      expect(find.byKey(kGatewayLinkStatusRowKey), findsNothing);
    });

    testWidgets('renders the report it is given and composes no message',
        (tester) async {
      // Two surfaces, one source of truth. A card that paraphrases is a second
      // place the vocabulary can drift, and the app-bar chip (15-06) would then
      // disagree with the card an operator is standing at.
      const sentinel = 'ZZ-SENTINEL: the gateway refused this panel';
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayLinkProvider.overrideWith((ref) => Stream.value(_report(
                  kind: GatewayLinkKind.credentialRefused,
                  headline: sentinel,
                  detail: 'ZZ-SENTINEL-DETAIL: check the credential file.',
                  terminal: true,
                ))),
          ],
          localPreferences: await _gatewayStation(),
        ),
      );

      expect(find.text(sentinel), findsOneWidget);
      expect(find.textContaining('ZZ-SENTINEL-DETAIL'), findsOneWidget);
    });

    // The behavioural pending-timer canary plan 15-04 could not have.
    //
    // Arm 11 there — an always-on `Timer.periodic` created at provider
    // construction — turned NOTHING red, and the cause was measured rather than
    // guessed: `grep -rln gatewayLinkProvider lib/` returned only the
    // provider's own file, so nothing in the app observed it and Flutter's
    // "A Timer is still pending" check had nothing to fire on. This arm is the
    // observation point: the real provider, constructed and watched by a real
    // widget, with no override. Flutter fails the test if a timer outlives it,
    // and the probe assertion below names what happened when it does.
    testWidgets('arms no timer on a station whose link it cannot observe',
        (tester) async {
      final probe = GatewayLinkTimerProbe();
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [gatewayLinkTimerProbeProvider.overrideWithValue(probe)],
          localPreferences: await _gatewayStation(),
        ),
      );

      expect(probe.armed, isFalse,
          reason: 'a timer left armed under a widget is how an unrelated '
              'widget test in another file starts failing with "A Timer is '
              'still pending"');
      expect(probe.armedFor, isEmpty);
    });
  });
}
