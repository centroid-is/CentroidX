/// `/advanced/server-config` — `administer` — over the relay.
///
/// In gateway mode this page edits the BACKEND's stateman file through
/// `backendConfig.read` / `validate` / `write` (`lib/pages/server_config.dart`
/// `BackendConfigSection`, `lib/core/config_source.dart` `GatewayConfigSource`),
/// and the backend answers from `BackendConfigStore` over the file
/// `CENTROID_STATEMAN_FILE_PATH` names. The round trip here is therefore the
/// strongest one in the lane: the bytes on the backend's disk change.
///
/// Three sessions are driven at every step, because §10's claim is about the
/// difference between them: `eng` (Engineering, holds `administer`), `op`
/// (Operator, `operate` alone, verified by the same `session.login`), and a
/// socket that never signed in.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show AccessMethods;

import '../support/backend_bench.dart';
import '../support/panel.dart';
import '../support/wire_probe.dart';

const String _route = '/advanced/server-config';
const String _title = 'Server Config';

/// The endpoint the edit writes. Not the plant's real one: the backend does
/// not restart itself on a save (`kBackendConfigRestartNoteKey`), so the live
/// link keeps serving and only the FILE changes — which is exactly what the
/// read-back measures.
const String _editedEndpoint = 'opc.tcp://10.104.20.99:4840';

/// The item key the policy decorator and `BackendConfigStore` audit every
/// `backendConfig.*` call under: `AccessPolicy.stateManConfigPrefKey`,
/// spelled here because the constant is the backend's and a renamed key must
/// fail this file.
const String _auditKey = 'state_man_config';

Future<Panel> _signedIn(WidgetTester tester, BackendBench bench,
    String username, String password) =>
    live(tester, () async {
      final p = await Panel.dial(bench.port);
      await p.ready();
      expect(await p.signIn(username, password), AccessSignInResult.ok);
      return p;
    });

/// Opens the alias card and scrolls its endpoint field into view — the steps
/// test/pages/server_config_gateway_editor_test.dart's `_editEndpoint` takes.
Future<void> _revealEndpoint(WidgetTester tester) async {
  await untilFound(tester, find.text(kHall),
      describe: 'the backend\'s server alias "$kHall" to render');
  await tester.scrollUntilVisible(find.text(kHall), 200,
      scrollable: find.byType(Scrollable).first);
  await settleFrames(tester);
  await tester.tap(find.text(kHall));
  await settleFrames(tester);
  await tester.scrollUntilVisible(
      find.widgetWithText(TextField, 'Endpoint URL'), 200,
      scrollable: find.byType(Scrollable).first);
  await settleFrames(tester);
}

void serverConfigCases(BackendBench Function() bench) {
  group('the server configuration page', () {
    testWidgets(
        'opens for an engineer verified by the gateway and renders the '
        'BACKEND\'s configuration, not an empty form', (tester) async {
      await useDesktopSurface(tester, size: const Size(1100, 2600));
      final panel =
          await _signedIn(tester, bench(), kEngineer, kEngineerPassword);
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ServerConfigPage()));

      // The backend's document, by content: the alias the bench wrote into
      // the stateman file, rendered inside the typed editor. An empty form
      // renders the section headings and none of this.
      await untilFound(tester, find.byKey(kBackendConfigEditorKey),
          describe: 'the backend configuration editor to mount');
      await untilFound(tester, find.text(kHall),
          describe: 'the backend\'s server alias "$kHall" to render');
      expect(find.text('OPC-UA Servers'), findsOneWidget);
      // The attribution line only a gateway panel renders.
      expect(find.byKey(kBackendConfigAttributionKey), findsOneWidget);
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets(
        'the attribution line names the PERSON the gateway verified at '
        'session.login, not a station account that does not exist',
        (tester) async {
      // `gatewayVerifiedAccountProvider` answers `RemoteStateMan.
      // verifiedAccount`, which the supervisor fills from the HELLO
      // capabilities — the token-verified station account. A browser or a
      // panel that signed in as a person presents no token, so the line used
      // to read "recorded against this station's verified account — a
      // station account, not a person", while the audit rows the save
      // actually produces (asserted in the round-trip case below) carry the
      // person's username. The line now watches the access session and
      // names the person when there is one; the station text stays for a
      // station-credential session, where it is the truth.
      await useDesktopSurface(tester, size: const Size(1100, 2600));
      final panel =
          await _signedIn(tester, bench(), kEngineer, kEngineerPassword);
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ServerConfigPage()));
      await untilFound(tester, find.byKey(kBackendConfigAttributionKey));
      // The name arrives through a FutureProvider, one frame or more after
      // the row itself mounts — wait for it rather than reading the row on
      // the frame it appeared.
      await untilFound(tester, find.textContaining('($kEngineer)'),
          describe: 'the account the save is recorded against — the one the '
              'gateway resolved at session.login');
      await dismount(tester);
    });

    testWidgets(
        'an edit made in the widget lands in the backend\'s stateman file on '
        'disk and is audited against the verified account', (tester) async {
      await useDesktopSurface(tester, size: const Size(1100, 2600));
      final panel =
          await _signedIn(tester, bench(), kEngineer, kEngineerPassword);
      final before = bench().statemanOnDisk();
      final opcuaBefore = (before['opcua'] as List).cast<Map>();
      expect(opcuaBefore.single['endpoint'], isNot(_editedEndpoint),
          reason: 'the anti-vacuity check: the file must not already hold '
              'the value the edit is about to write');
      final auditBefore = await live(
          tester, () => bench().decisionRows(keyPrefix: _auditKey));

      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ServerConfigPage()));
      await _revealEndpoint(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Endpoint URL'), _editedEndpoint);
      await settleFrames(tester);
      await tester.ensureVisible(find.byKey(kBackendConfigSaveKey));
      await settleFrames(tester);
      await tester.tap(find.byKey(kBackendConfigSaveKey));
      await settleFrames(tester, frames: 10);

      // A refused save renders its reason in the refusal row. Asserting on
      // it first turns a silent timeout below into the backend's own words.
      final refusal = find.byKey(kBackendConfigRefusalKey);
      expect(refusal, findsNothing,
          reason: 'the save was refused: '
              '${refusal.evaluate().isEmpty ? '' : tester.widget(refusal)}');

      // The file on the backend's disk: the only place the truth is.
      await live(tester, () => untilTrue(() {
            final opcua =
                (bench().statemanOnDisk()['opcua'] as List).cast<Map>();
            return opcua.single['endpoint'] == _editedEndpoint;
          },
          describe: 'the backend\'s stateman file to hold the edited '
              'endpoint'));
      final after = bench().statemanOnDisk();
      expect(after['relay'], before['relay'],
          reason: 'the relay section is read-only over the wire and must '
              'survive a save byte-for-byte');
      expect(File('${bench().statemanPath}.previous').existsSync(), isTrue,
          reason: 'an accepted write keeps the previous document for '
              'restorePrevious');

      // Audited, against the verified account, at the backend.
      await live(tester, () => untilTrue(() async {
            final rows = await bench().decisionRows(keyPrefix: _auditKey);
            return rows.length > auditBefore.length &&
                rows.first.who == kEngineer &&
                rows.first.allowed &&
                rows.first.origin == 'relay';
          },
          within: const Duration(seconds: 10),
          describe: 'an allowed audit row for the write, attributed to '
              '$kEngineer with origin relay'));
      await dismount(tester);
    });

    testWidgets(
        'the edit reads back through the page on a second panel',
        (tester) async {
      // What a second engineer at another station sees is the strongest
      // "it landed" a screen can give: this panel never held the draft.
      await useDesktopSurface(tester, size: const Size(1100, 2600));
      final opcua = (bench().statemanOnDisk()['opcua'] as List).cast<Map>();
      expect(opcua.single['endpoint'], _editedEndpoint,
          reason: 'runs after the round trip above, on the file it wrote');
      final panel =
          await _signedIn(tester, bench(), kEngineer, kEngineerPassword);
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ServerConfigPage()));
      await _revealEndpoint(tester);
      final field = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Endpoint URL'));
      expect(field.controller?.text, _editedEndpoint,
          reason: 'the second panel reads the backend, so it must show the '
              'endpoint the first one wrote');
      await dismount(tester);
    });

    testWidgets(
        'the gateway refuses backendConfig.read and .write to a verified '
        'operator and to a session nobody signed in on — the page\'s lock is '
        'the affordance, the refusal is the property', (tester) async {
      final port = bench().port;
      final statemanBefore = File(bench().statemanPath).readAsStringSync();

      await live(tester, () async {
        // A verified operator: the credential is real, the role is real, the
        // group is not there.
        final op = await WireProbe.signedIn(port,
            username: kOperator, password: kOperatorPassword);
        final read = await op.call(AccessMethods.configRead);
        expect(read.isError, isTrue,
            reason: 'op holds operate alone and backendConfig.read takes '
                'administer');
        expect(read.errorCode, WireErrors.forbidden, reason: '$read');
        expect(read.errorMessage, contains('administer'),
            reason: 'the refusal names the group, §10\'s "two messages"');
        final write = await op.call(AccessMethods.configWrite,
            {'configJson': '{"opcua":[]}', 'reason': 'probe'});
        expect(write.errorCode, WireErrors.forbidden, reason: '$write');
        await op.close();

        // Nobody: the plant's anonymous account, graded by the policy.
        final nobody = await WireProbe.anonymous(port);
        final anonRead = await nobody.call(AccessMethods.configRead);
        expect(anonRead.errorCode, WireErrors.forbidden, reason: '$anonRead');
        final anonWrite = await nobody.call(AccessMethods.configWrite,
            {'configJson': '{"opcua":[]}', 'reason': 'probe'});
        expect(anonWrite.errorCode, WireErrors.forbidden,
            reason: '$anonWrite');
        await nobody.close();

        // The control: the same frames from eng succeed, so the refusals
        // above are about the group and not about the frames.
        final eng = await WireProbe.signedIn(port,
            username: kEngineer, password: kEngineerPassword);
        final engRead = await eng.call(AccessMethods.configRead);
        expect(engRead.isError, isFalse, reason: '$engRead');
        await eng.close();

        // The refusals are recorded, attributed to who was refused (D-05).
        await untilTrue(() async {
          final rows = await bench().decisionRows(keyPrefix: _auditKey);
          return rows.any((r) => !r.allowed && r.who == kOperator);
        },
            within: const Duration(seconds: 10),
            describe: 'a deny row for the operator\'s refused write');
      });

      expect(File(bench().statemanPath).readAsStringSync(), statemanBefore,
          reason: 'neither refused write may have touched the file');
    });

    testWidgets(
        'the page itself locks for a verified operator — with the group the '
        'gateway resolved, not one the panel decided', (tester) async {
      await useDesktopSurface(tester, size: const Size(1100, 1400));
      final panel =
          await _signedIn(tester, bench(), kOperator, kOperatorPassword);
      final session = await live(tester, panel.session);
      expect(session.isElevated, isTrue);
      expect(session.can(AccessGroup.administer), isFalse,
          reason: 'the groups are the server\'s answer to session.login');
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ServerConfigPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey),
          describe: 'the locked body for a verified operator');
      expect(find.text(kAccessLockedHeadline), findsOneWidget);
      expect(find.byKey(kBackendConfigEditorKey), findsNothing);
      expect(find.text(kHall), findsNothing,
          reason: 'a locked page renders none of the backend\'s document');
      await dismount(tester);
    });

    testWidgets('the page locks for a session nobody signed in on',
        (tester) async {
      // `routeAllowedWhenNobodyCanSignIn` opens this route when the link
      // cannot authenticate; it CAN here, so the lock holds.
      await useDesktopSurface(tester, size: const Size(1100, 1400));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        return p;
      });
      await tester.pumpWidget(
          hostRoute(panel, _route, _title, const ServerConfigPage()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey),
          describe: 'the locked body for a session nobody signed in on');
      expect(find.byKey(kBackendConfigEditorKey), findsNothing);
      await dismount(tester);
    });
  });
}
