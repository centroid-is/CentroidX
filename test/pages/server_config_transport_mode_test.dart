import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/core/gateway_trust.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/gateway_link_status_row.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// What the fake fetcher hands back, and what Approve must pin verbatim.
const String _approvedPem = '-----BEGIN CERTIFICATE-----\n'
    'dGhlIHBsYW50IENBLCBhcyBhcHByb3ZlZCBieSB0aGUgb3BlcmF0b3I=\n'
    '-----END CERTIFICATE-----\n';

/// The fingerprint of [_approvedPem], computed by the app's own function —
/// self-consistent on purpose. The dialog shows what the fetcher handed it;
/// the pinned row afterwards *recomputes* from the stored material (a display
/// that derives from the material cannot lie about it), so a fake whose claim
/// disagreed with its material would fail the arm for the wrong reason.
/// Proving the fetcher computes locally is `test/core/gateway_trust_test.dart`'s.
final String _fingerprint = caFingerprintSha256(_approvedPem);

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

/// Was: opens the transport card, which used to be collapsed on a direct-mode
/// station. The card no longer collapses — the owner moved the toggle to the
/// top of the page in the open, because it is the ONE difference between the
/// two faces of this page and a difference behind a disclosure triangle is one
/// you have to already know about to find.
///
/// Kept as a named step rather than deleted from thirteen call sites: what
/// each arm below is doing is still "reach the transport controls", and the
/// step now costs no gesture. The claim that it costs none is its own arm
/// ('the toggle is reachable with no gesture at all').
Future<void> _openTransport(WidgetTester tester) async {
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
      // Open, at the top, with no disclosure triangle in front of it.
      expect(find.byType(SegmentedButton<TransportMode>), findsOneWidget,
          reason: 'the toggle is reachable with no gesture at all — the whole '
              'of what the owner asked for at the top of this page');
      expect(find.text('Direct to PLCs'), findsOneWidget,
          reason: 'and the mode is named on the segment, not in a subtitle '
              'that only appears while the card is shut');

      await _openTransport(tester);
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
      expect(find.text('Gateway address and port'), findsNothing);
    });

    testWidgets('choosing the gateway reveals one field: the address',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _openTransport(tester);

      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      expect(find.text('Gateway address and port'), findsOneWidget);
      // The two questions an operator cannot answer are gone. Trust is
      // fetched and approved at Save ("how do I obtain pem path" was the
      // owner's, verbatim), and the credential file is on its way out with
      // the station-token work — the field only appears on a station whose
      // saved row still carries one.
      expect(find.text('Plant CA certificate (PEM path)'), findsNothing);
      expect(find.text('Station credential file (optional)'), findsNothing);
      expect(find.textContaining('No plant CA pinned yet'), findsNothing,
          reason: 'nothing typed yet — the trust note belongs to a wss '
              'address, not to the empty field');
    });

    // Restart-to-apply: the running panel is on the saved transport, so moving
    // a radio button must not make the page claim the switch already happened.
    testWidgets('the four sections stay while the change is unsaved',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      _expectDirectSections(findsOneWidget);
    });

    testWidgets(
        'a saved gateway station renders the SAME page, with the backend as '
        'its target and no note narrating the toggle', (tester) async {
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: await _gatewayStation()),
      );

      // The owner's ruling: "the server config should look exactly the same
      // with gateway and without — the only difference is a toggle at the top
      // for gateway". So the page keeps its slots; what changes is what each
      // slot is about. (The section headings themselves are the editor's, and
      // this fixture stands up no backend for it to read — the parity arms in
      // server_config_transport_parity_test.dart do that with one.)
      expect(find.text('Database Configuration'), findsOneWidget,
          reason: 'the database card stays in its slot, and in gateway mode '
              'it is the same editable card — the owner, at the rig: "i dont '
              'see a reason why we cannot change or see database config". '
              'What it drops there is the claim, not the settings; the arms '
              'for that are in server_config_transport_card_test.dart');
      expect(find.textContaining('Not used in gateway mode'), findsOneWidget,
          reason: 'import/export is the card that genuinely does nothing '
              'here — its paths write this station\'s own certificates, and '
              'an "Import File" that reported success while changing nothing '
              'the backend reads is this page\'s own failure mode. One card '
              'says it now, not two');
      expect(find.text('Import / Export'), findsOneWidget,
          reason: 'so does import/export: same slot, and its own honest face');

      // The narration stays deleted — the toggle above states the mode, and
      // prose beside a control that already says it is noise. 15-05 re-pointed
      // this at the corrected Postgres copy after the rig measured the
      // original claim false (13-RIG-E2E-EVIDENCE FIND-C); the note itself is
      // gone, and the honest Postgres sentence lives in `server_config.dart`'s
      // comments where `test/core/gateway_copy_test.dart` holds it present.
      expect(find.textContaining('no OPC UA session'), findsNothing);
      expect(find.textContaining('takes its values from the relay'),
          findsNothing);
    });
  });

  group('refusing a configuration that cannot be dialled', () {
    // The old first arm of this group — "wss with no CA root is refused, and
    // save stays disabled" — is deliberately gone, and this is the record of
    // where it went. Save is now the step that acquires trust, so disabling
    // it for missing trust would disable the acquisition; the value-level
    // guarantee moved to `GatewayConfig.undialable`, which stateManProvider
    // consults at boot (`gateway_config_test.dart` pins both halves). What
    // this group still owns is the refusals Save cannot fix.
    testWidgets('a scheme that is not a WebSocket stays refused',
        (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      await tester.enterText(
          find.byType(TextField).first, 'https://10.50.10.11:9443');
      await settle(tester);

      expect(find.textContaining('Scheme must be wss'), findsOneWidget);
      expect(find.text('Cannot save yet'), findsOneWidget);
      final save = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Cannot save yet'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(save.onPressed, isNull);
    });
  });

  group('trust is acquired at Save: fetch, fingerprint, approve', () {
    testWidgets('a wss address with nothing pinned says so, and Save is the '
        'way forward', (tester) async {
      await pumpAndLoad(tester, buildTestableServerConfig());
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);

      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);

      expect(find.textContaining('No plant CA pinned yet'), findsOneWidget);
      final save = tester.widget<ElevatedButton>(find
          .ancestor(
              of: find.text('Save Configuration'),
              matching: find.byType(ElevatedButton))
          .first);
      expect(save.onPressed, isNotNull,
          reason: 'Save runs the fetch-and-approve ceremony; a disabled '
              'button here is the pem-path deadlock wearing new clothes');
    });

    testWidgets('Approve pins exactly what the fetch returned', (tester) async {
      final local = InMemoryPreferences();
      var fetches = 0;
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayTrustFetcherProvider.overrideWithValue((uri) async {
              fetches++;
              expect(uri, Uri.parse('wss://10.50.10.11:9443'),
                  reason: 'the fetch must be for the very URL the operator '
                      'typed — anything else is a pin for a different '
                      'gateway');
              return FetchedGatewayTrust(
                  caPem: _approvedPem, sha256Fingerprint: _fingerprint);
            }),
          ],
          localPreferences: local,
        ),
      );
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);

      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      // The noVNC-shaped ceremony: identity, fingerprint, a real choice.
      expect(find.text('Gateway identity'), findsOneWidget);
      expect(find.textContaining(_fingerprint), findsOneWidget,
          reason: 'the dialog must show the fingerprint the fetcher '
              'computed from the received DER — it is the one thing the '
              'operator can compare against the gateway\'s own print-out');

      await tester.tap(find.text('Approve'));
      await settle(tester);

      expect(fetches, 1);
      final saved = await readGatewayConfig(local);
      expect(saved.mode, TransportMode.gateway);
      expect(saved.caPem, _approvedPem,
          reason: 'what is pinned must be byte-identical to what was '
              'fetched and fingerprinted — a normalisation here would make '
              'the pin differ from what the operator approved');
      expect(saved.caCertPath, isNull);
      expect(find.textContaining('Restart the HMI'), findsOneWidget);
      // And the card now wears the pin.
      expect(find.textContaining('Pinned plant CA'), findsOneWidget);
      expect(find.textContaining(_fingerprint), findsOneWidget);
    });

    // The field asks for "address and port" and must mean it. These two arms
    // are the operator's half of `normalizeGatewayAddress`: what is typed is
    // what an integrator wrote down, and what is dialled, fetched and pinned
    // is the secure URL — no scheme typed anywhere.
    for (final (label, typed, dialled) in [
      ('an IP address', '10.50.10.11:9443', 'wss://10.50.10.11:9443'),
      (
        'an FQDN',
        'centroidx-backend:9443',
        'wss://centroidx-backend:9443',
      ),
    ]) {
      testWidgets('$label and a port, typed bare, is dialled over wss',
          (tester) async {
        final local = InMemoryPreferences();
        Uri? fetchedFor;
        await pumpAndLoad(
          tester,
          _serverConfigWith(
            [
              gatewayTrustFetcherProvider.overrideWithValue((uri) async {
                fetchedFor = uri;
                return FetchedGatewayTrust(
                    caPem: _approvedPem, sha256Fingerprint: _fingerprint);
              }),
            ],
            localPreferences: local,
          ),
        );
        await _openTransport(tester);
        await tester.tap(find.text('Relay gateway'));
        await settle(tester);
        await tester.enterText(find.byType(TextField).first, typed);
        await settle(tester);

        await tester.tap(find.text('Save Configuration'));
        await settle(tester);
        expect(fetchedFor, Uri.parse(dialled),
            reason: 'the identity fetched must be the one for the URL this '
                'panel will actually dial — an unnormalised "$typed" has no '
                'host to fetch from at all');
        await tester.tap(find.text('Approve'));
        await settle(tester);

        final saved = await readGatewayConfig(local);
        expect(saved.url, dialled,
            reason: 'the stored row is what the boot path reads; it must be '
                'dialable without the page that wrote it being present to '
                'reinterpret it');
        expect(saved.undialable, isNull,
            reason: 'and it must satisfy the boot guard, not merely the '
                'edit-time one');
      });
    }

    testWidgets('Reject writes nothing at all', (tester) async {
      final local = InMemoryPreferences();
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayTrustFetcherProvider.overrideWithValue((uri) async =>
                FetchedGatewayTrust(
                    caPem: _approvedPem, sha256Fingerprint: _fingerprint)),
          ],
          localPreferences: local,
        ),
      );
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);

      await tester.tap(find.text('Save Configuration'));
      await settle(tester);
      await tester.tap(find.text('Reject'));
      await settle(tester);

      expect(await local.getString(GatewayConfig.prefsKey), isNull,
          reason: 'a rejected identity must leave no trace: not the URL, '
              'not the mode, and certainly not the material — half-saving '
              'would boot the panel into the very notBuilt state the '
              'ceremony exists to prevent');
      expect(find.textContaining('Pinned plant CA'), findsNothing);
    });

    testWidgets('a fetch that fails says why, in the card, and writes nothing',
        (tester) async {
      final local = InMemoryPreferences();
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayTrustFetcherProvider.overrideWithValue((uri) async =>
                throw GatewayTrustException(
                    'the gateway did not answer at '
                    'http://10.50.10.11:9444/relay-trust within 10 s. Check '
                    'that the address is right and the gateway is running, '
                    'then save again.')),
          ],
          localPreferences: local,
        ),
      );
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(
          find.byType(TextField).first, 'wss://10.50.10.11:9443');
      await settle(tester);

      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      expect(find.textContaining('did not answer'), findsOneWidget,
          reason: 'the operator is standing at this card; the refusal '
              'renders here, in their own words, not in a log');
      expect(await local.getString(GatewayConfig.prefsKey), isNull);
    });

    testWidgets('a saved legacy CA path migrates to pinned material on the '
        'next save, with no fetch and no dialog', (tester) async {
      final dir = Directory.systemTemp.createTempSync('transport-card-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/ca.pem';
      File(path).writeAsStringSync(_approvedPem);

      final local = await _gatewayStation(caCertPath: path);
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayTrustFetcherProvider.overrideWithValue((uri) async =>
                fail('a station that already trusts a provisioned file must '
                    'not re-ask the gateway who it is')),
          ],
          localPreferences: local,
        ),
      );

      // The legacy shape is named while it is still there.
      expect(find.textContaining('Trusting CA file'), findsOneWidget);

      // Any edit, so there is something to save. By label: on a station
      // whose row is already gateway other cards on the page render text
      // fields of their own, so `.first` is not this card's.
      await tester.enterText(
          find.widgetWithText(TextField, 'Gateway address and port'),
          'wss://10.50.10.11:9444');
      await settle(tester);
      await tester.ensureVisible(find.text('Save Configuration'));
      await settle(tester);
      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      final saved = await readGatewayConfig(local);
      expect(saved.url, 'wss://10.50.10.11:9444',
          reason: 'the edit and the migration ride the same save — a '
              'migration assertion alone would also pass on a save that '
              'never ran against a row that already carried material');
      expect(saved.caPem, _approvedPem,
          reason: 'same bytes, new home: the station already dialled under '
              'this file every day, so its contents move without a new '
              'trust decision');
      expect(saved.caCertPath, isNull);
    });

    testWidgets('Forget clears the pin so the next save re-fetches',
        (tester) async {
      final prefs = InMemoryPreferences();
      await writeGatewayConfig(
        prefs,
        const GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://10.50.10.11:9443',
          caPem: _approvedPem,
        ),
      );
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: prefs),
      );

      expect(find.textContaining('Pinned plant CA'), findsOneWidget);
      await tester.tap(find.text('Forget'));
      await settle(tester);

      expect(find.textContaining('No plant CA pinned yet'), findsOneWidget,
          reason: 'forgetting is an edit, not a write: the pin goes when '
              'the operator saves, and the save runs the ceremony again — '
              'which is the deliberate path for a genuinely re-keyed plant');
    });
  });

  group('the credential file field is legacy-only', () {
    testWidgets('a station whose saved row carries a tokenPath still sees '
        'the field, so it can be cleared', (tester) async {
      final prefs = InMemoryPreferences();
      await writeGatewayConfig(
        prefs,
        const GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://10.50.10.11:9443',
          caPem: _approvedPem,
          tokenPath: '/etc/centroid/station.token',
        ),
      );
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: prefs),
      );

      expect(find.text('Station credential file (legacy)'), findsOneWidget,
          reason: 'hiding the field on a station that still has a value '
              'would strand the value: the ws:// refusal names it and the '
              'operator would have no way to clear it. The station-token '
              'work deletes the field and the value together');
    });

    testWidgets('a saved gateway station with NO token file — the '
        'signed-in-over-the-socket shape — does not show the field at all',
        (tester) async {
      // Defect 3, the other polarity: once sign-in over the socket works, a
      // panel needs no credential file, and the legacy field must disappear
      // for everyone not actively holding one. The rig still holds one (the
      // arm above), so this is hide-when-unused, not delete-for-all.
      final prefs = InMemoryPreferences();
      await writeGatewayConfig(
        prefs,
        const GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://centroidx-backend:9443',
          caPem: _approvedPem,
        ),
      );
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: prefs),
      );

      expect(find.text('Station credential file (legacy)'), findsNothing,
          reason: 'no token file in play, no field: an unanswerable, '
              'on-its-way-out question must not sit on the card of a panel '
              'that signs in over the socket');
    });
  });

  group('saving', () {
    testWidgets('writes to the device-local store, and says restart',
        (tester) async {
      final local = InMemoryPreferences();
      await pumpAndLoad(
          tester, buildTestableServerConfig(localPreferences: local));
      await _openTransport(tester);

      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      // A bench ws:// dial: this arm is about WHERE the row lands and what
      // the card says after; the wss fetch-and-approve path has its own
      // group above.
      await tester.enterText(
          find.byType(TextField).first, 'ws://bench:9443');
      await settle(tester);

      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      final saved = await readGatewayConfig(local);
      expect(saved.mode, TransportMode.gateway);
      expect(saved.url, 'ws://bench:9443');

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
      await _openTransport(tester);

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
      await _openTransport(tester);
      await tester.tap(find.text('Relay gateway'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, url);
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

    // The photographed defect (rig, gateway mode): the advisory warned that
    // a name would fail the handshake while a live session over that very
    // name was up three lines below. An advisory that fires while the thing
    // it warns will fail is succeeding teaches operators to ignore the
    // warning row. Driven from the link state now, not the typed URL: a
    // connection to `wss://name` is proof the certificate carries a SAN for
    // that name, so the advisory is suppressed.
    testWidgets('a live session over the named host suppresses the advisory',
        (tester) async {
      final local = await _gatewayStation(
          url: 'wss://centroidx-backend:9443', caCertPath: null);
      await writeGatewayConfig(
        local,
        const GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://centroidx-backend:9443',
          caPem: '-----BEGIN CERTIFICATE-----\nMIIB\n'
              '-----END CERTIFICATE-----',
        ),
      );
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayLinkProvider.overrideWith((ref) => Stream.value(_report(
                  headline: 'Connected to wss://centroidx-backend:9443',
                  detail: 'The panel is holding a live session.',
                ))),
          ],
          localPreferences: local,
        ),
      );

      expect(find.textContaining('subject-alternative name'), findsNothing,
          reason: 'the leaf plainly carries a SAN for this name — the '
              'handshake succeeded on it — so warning that it might not is '
              'false, and a false warning row trains operators to ignore the '
              'true ones');
      // The live control: the connected row IS on screen, so the advisory's
      // absence is a suppression, not an empty card.
      expect(find.textContaining('holding a live session'), findsOneWidget);
    });

    testWidgets('an unreachable link over a named host still shows the '
        'advisory — the honest case, and the live control for the arm above',
        (tester) async {
      final local = await _gatewayStation(
          url: 'wss://centroidx-backend:9443', caCertPath: null);
      await writeGatewayConfig(
        local,
        const GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://centroidx-backend:9443',
          caPem: '-----BEGIN CERTIFICATE-----\nMIIB\n'
              '-----END CERTIFICATE-----',
        ),
      );
      await pumpAndLoad(
        tester,
        _serverConfigWith(
          [
            gatewayLinkProvider.overrideWith((ref) => Stream.value(_report(
                  kind: GatewayLinkKind.untrustedCertificate,
                  headline: 'The certificate at wss://centroidx-backend:9443 '
                      'was refused',
                  detail: 'This panel would not trust the certificate.',
                ))),
          ],
          localPreferences: local,
        ),
      );

      expect(find.textContaining('subject-alternative name'), findsOneWidget,
          reason: 'a certificate refusal on a name IS the case the advisory '
              'is for — here it fires, which is what keeps the suppression '
              'above a suppression and not a deletion');
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

  group('the page claims nothing about Postgres either way', () {
    // The hidden-sections note is gone (the toggle above already states the
    // mode), and with it went the page's only rendered Postgres sentence.
    // Silence is honest here; the honest sentence itself still lives in
    // `server_config.dart`'s comments, and `test/core/gateway_copy_test.dart`
    // holds it present at source level — the arm that matters is that the
    // FALSE claims never come back as rendered text.
    testWidgets('no rendered text claims or denies the Postgres connection',
        (tester) async {
      await pumpAndLoad(
        tester,
        buildTestableServerConfig(localPreferences: await _gatewayStation()),
      );

      expect(find.textContaining('Postgres'), findsNothing,
          reason: 'the note that carried the corrected copy was deleted '
              'whole — a page that renders no claim cannot render a false '
              'one');
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
      await _openTransport(tester);

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
