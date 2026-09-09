/// The config target, photographed: six frames, both station themes (17-13,
/// redesigned per owner — a card-header chip and a caption line, not a page
/// band).
///
/// The plan's human check stands in front of these twelve PNGs and answers
/// one question — standing at frames 2 and 3, is it obvious you are editing
/// the backend and not this screen? Everything here serves that question:
///
///  1. `config_target_direct`         — this station, named, one quiet
///                                      caption line;
///  2. `config_target_gateway`        — the target chip alone: attention
///                                      yellow, antenna, the URL. Its home —
///                                      the card's own header line — is in
///                                      every frame from 3 on;
///  3. `config_target_relay_disabled` — the whole card: header naming the
///                                      target, relay section present,
///                                      greyed and explained (D-10);
///  4. `config_target_refused`        — a save the parser refused, in the
///                                      parser's own words;
///  5. `config_target_relay_refused`  — a relay-section edit refused, in
///                                      D-10's words, visibly not frame 4's;
///  6. `config_target_restore`        — the way back, offered because the
///                                      backend reports a previous document.
///
/// The host is 15-07's (`themedGoldenHost` + `roboto-mono`), and every frame
/// asserts its subject in the same pump that records it — `matchesGoldenFile`
/// will happily record a frame that lost its subject, and the recorded image
/// then becomes the baseline that hides the loss. Both brightnesses always:
/// the banner's border is `onSurface` with alpha precisely because a borrowed
/// edge role is invisible on dark, and a light-only golden could not see that
/// regress. Nothing here reads a clock; there is no `DateTime.now()` anchor
/// anywhere in these frames.
///
/// To update: derive the failing set first, then
/// `flutter test test/widgets/config_target_banner_golden_test.dart --update-goldens`.
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/config_target_banner.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, BackendConfigDocument, ConfigValidation;

import '../helpers/themed_golden_host.dart';

/// The station name in every frame. A constant, because the production value
/// is `Platform.localHostname` and a golden with a hostname in it disagrees
/// with itself by machine.
const _station = 'SVN-ST101';

/// The endpoint frame 2 names — the machine the operator is about to edit.
const _gatewayUrl = 'wss://10.50.10.11:9443';

/// The backend's document, fixed. One editable section and the one that is
/// not.
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

/// The parser's refusal, for frame 4 — it names the field.
final rpc.RpcException _parserRefusal = rpc.RpcException(
  -32011,
  'BackendConfigStore.write refused: The submitted document could not be '
  'parsed as a StateManConfig: publishing_interval_ms must be a number.',
);

/// D-10's refusal, for frame 5 — visibly not frame 4's.
final rpc.RpcException _relayRefusal = rpc.RpcException(
  -32011,
  'BackendConfigStore.write refused: The `relay` section differs from the '
  'live configuration, and it is not remotely editable: it configures the '
  'very socket this edit arrived on. Change it at the machine '
  '(/etc/centroid/state-man.json) and restart the backend.',
);

/// A scripted far end, enough of one for six photographs.
class _ScriptedBackend implements BackendConfigApi {
  _ScriptedBackend({this.hasPrevious = false, this.writeRefusal});

  final bool hasPrevious;
  final Object? writeRefusal;

  @override
  Future<BackendConfigDocument> read() async => BackendConfigDocument(
        configJson: jsonEncode(_liveConfig),
        readOnlySections: const ['relay'],
        hasPrevious: hasPrevious,
      );

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);

  @override
  Future<void> write(String configJson, {String? reason}) async {
    final refusal = writeRefusal;
    if (refusal != null) throw refusal;
  }

  @override
  Future<BackendConfigDocument?> previous() async => null;

  @override
  Future<void> restorePrevious({String? reason}) async {}
}

/// Pumps like the page tests do: bounded explicit frames, never
/// `pumpAndSettle` — an indeterminate spinner mid-load would hang it.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpBanner(
  WidgetTester tester,
  Widget banner, {
  required bool dark,
}) async {
  // 100px of height, not the old 220: the redesign's whole claim is that
  // each face is one line, and the frame should not flatter it with a band
  // of empty canvas.
  await tester.binding.setSurfaceSize(const Size(760, 100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    themedGoldenHost(
      Padding(
        padding: const EdgeInsets.all(16),
        child: Align(alignment: Alignment.topLeft, child: banner),
      ),
      dark: dark,
    ),
  );
  await _settle(tester);
}

Future<void> _pumpSection(
  WidgetTester tester,
  _ScriptedBackend backend, {
  required bool dark,
}) async {
  // Phase 3: the section's body is the typed StateManConfigEditor — three
  // section cards, the relay card, the Advanced expansion and the save row
  // — so the frame is a page, not a band.
  await tester.binding.setSurfaceSize(const Size(900, 2150));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendConfigApiProvider.overrideWith((ref) async => backend),
        stationNameProvider.overrideWithValue(_station),
      ],
      child: themedGoldenHost(
        SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: BackendConfigSection(targetUrl: _gatewayUrl),
          ),
        ),
        dark: dark,
      ),
    ),
  );
  await _settle(tester);
  expect(find.byType(CircularProgressIndicator), findsNothing,
      reason: 'the scripted read has resolved; a spinner in a golden is a '
          'promise the frame cannot keep');
  // Every card frame carries the ACCESS-04 affordance: the header chip
  // naming the machine this card edits. Asserted in the pump that records,
  // so a frame that lost its subject fails instead of re-baselining.
  expect(
      find.descendant(
          of: find.byKey(const Key('backend_config_header')),
          matching: find.textContaining('10.50.10.11')),
      findsOneWidget,
      reason: 'the card header must name the target, or the frame records a '
          'card that could be editing anything');
}

/// Phase 3 retarget: the benign edit goes through the TYPED form — expand
/// the server card, change the endpoint, press the ONE save button — exactly
/// as an operator would, because the raw textarea is demoted to the Advanced
/// expansion.
Future<void> _editAndSave(WidgetTester tester) async {
  await tester.tap(find.text('ST101'));
  await _settle(tester);
  await tester.ensureVisible(
      find.widgetWithText(TextField, 'Endpoint URL'));
  await _settle(tester);
  await tester.enterText(find.widgetWithText(TextField, 'Endpoint URL'),
      'opc.tcp://10.104.20.10:4841');
  await _settle(tester);
  await tester.ensureVisible(find.byKey(const Key('backend_config_save')));
  await _settle(tester);
  await tester.tap(find.byKey(const Key('backend_config_save')));
  await _settle(tester);
}

Future<void> _shoot(WidgetTester tester, String name) => expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );

void main() {
  setUpAll(loadThemedGoldenFonts);

  group('config target goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    for (final dark in [false, true]) {
      final label = dark ? 'dark' : 'light';
      final suffix = dark ? '_dark' : '';

      testWidgets('frame 1: direct mode names this station, $label',
          (tester) async {
        await _pumpBanner(tester, const ConfigTargetBanner.station(name: _station),
            dark: dark);

        expect(find.textContaining(_station), findsOneWidget,
            reason: 'the frame is only the direct frame if the station is '
                'named in it');
        await _shoot(tester, 'config_target_direct$suffix');
      });

      testWidgets('frame 2: gateway mode names the backend, $label',
          (tester) async {
        await _pumpBanner(
            tester, const ConfigTargetBanner.backend(name: _gatewayUrl),
            dark: dark);

        expect(find.textContaining('10.50.10.11'), findsOneWidget,
            reason: 'the whole point: the machine about to be edited, named');
        await _shoot(tester, 'config_target_gateway$suffix');
      });

      testWidgets('frame 3: the relay section, present and greyed, $label',
          (tester) async {
        await _pumpSection(tester, _ScriptedBackend(), dark: dark);

        final relay = tester.widget<TextField>(
            find.byKey(const Key('backend_config_relay_field')));
        expect(relay.enabled, isFalse,
            reason: 'the frame is only D-10\'s frame if the section is in it '
                'and dead');
        expect(find.textContaining('cut this screen off'), findsOneWidget);
        await _shoot(tester, 'config_target_relay_disabled$suffix');
      });

      testWidgets('frame 4: a refused save, in the parser\'s words, $label',
          (tester) async {
        await _pumpSection(
            tester, _ScriptedBackend(writeRefusal: _parserRefusal),
            dark: dark);
        await _editAndSave(tester);

        expect(
            find.descendant(
                of: find.byKey(const Key('backend_config_refusal')),
                matching: find.textContaining('publishing_interval_ms')),
            findsOneWidget,
            reason: 'the refusal names the field, or this frame records '
                'nothing worth reviewing');
        await _shoot(tester, 'config_target_refused$suffix');
      });

      testWidgets('frame 5: a refused relay edit, in D-10\'s words, $label',
          (tester) async {
        await _pumpSection(
            tester, _ScriptedBackend(writeRefusal: _relayRefusal),
            dark: dark);
        await _editAndSave(tester);

        expect(
            find.descendant(
                of: find.byKey(const Key('backend_config_refusal')),
                matching: find.textContaining('not remotely editable')),
            findsOneWidget);
        expect(find.textContaining('could not be parsed'), findsNothing,
            reason: 'the two refusals must be told apart at a glance');
        await _shoot(tester, 'config_target_relay_refused$suffix');
      });

      testWidgets('frame 6: the restore control, offered, $label',
          (tester) async {
        await _pumpSection(tester, _ScriptedBackend(hasPrevious: true),
            dark: dark);

        expect(find.byKey(const Key('backend_config_restore')), findsOneWidget,
            reason: 'the backend reports a previous document, so the way '
                'back is on screen');
        await _shoot(tester, 'config_target_restore$suffix');
      });
    }
  });
}
