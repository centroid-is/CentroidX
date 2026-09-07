/// `RemoteStateMan` refuses the four access families, by name, and still
/// serves the four data services.
///
/// Plan 17-03 added `accessTemplates`, `accessAdmin`, `audit` and
/// `backendConfig` to `StateManApi`. This client has no proxy for any of them —
/// plan 17-08 adds four to `client_sub_apis.dart` — so all four refuse.
///
/// ## Why a refusal and not a proxy that would surface `-32601`
///
/// That was the right answer for the data services before Phase 10, and
/// `remote_state_man.dart:635` says so: a proxy with no gateway handler
/// surfaced method-not-found, "which is the honest answer". It is not the right
/// answer here, because it is not yet honest — there is no `AccessMethods`
/// handler table on the gateway *and* no client proxy to send with, so a proxy
/// would have to be written before it could fail usefully. Until 17-08 writes
/// one, the member that does not exist should say it does not exist here, where
/// the caller is, rather than after a round trip.
///
/// A refusal on the client is also safe in the direction that matters:
/// authorisation is enforced server-side (17-CONTEXT's hard requirement), so a
/// client refusing early can only ever remove a capability, never grant one.
///
/// ## The anti-vacuity half
///
/// Every refusal group is paired with a **live control** on the same object.
/// `RemoteStateMan` dials lazily and never blocks in its constructor, so a
/// client pointed at a dead port is a perfectly good fixture for a getter
/// that answers without a round trip — which is exactly what the four
/// data-service getters do, and exactly what the four access getters must not.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The four getters this file judges.
const accessFamilies = <String>[
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
];

/// Reaches one access family without knowing which class [api] is.
Object? reachFamily(StateManApi api, String member) => switch (member) {
      'accessTemplates' => api.accessTemplates,
      'accessAdmin' => api.accessAdmin,
      'audit' => api.audit,
      'backendConfig' => api.backendConfig,
      _ => throw ArgumentError('unknown access family "$member"'),
    };

ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 300),
      writeDeadline: const Duration(milliseconds: 300),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// A port nothing is bound to — the panel's ordinary state at power-on.
Future<Uri> _deadPort() async {
  final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = dead.port;
  await dead.close();
  return Uri.parse('ws://127.0.0.1:$port');
}

void main() {
  late RemoteStateMan client;

  setUp(() async {
    client = RemoteStateMan(uri: await _deadPort(), config: _config());
    addTearDown(client.dispose);
  });

  group('RemoteStateMan refuses the four access families', () {
    for (final member in accessFamilies) {
      test('$member refuses, naming itself', () {
        expect(
          () => reachFamily(client, member),
          throwsA(isA<UnsupportedError>().having((e) => e.message.toString(),
              'message', contains('RemoteStateMan.$member'))),
          reason: 'a panel that asked for the audit trail and got '
              '"unsupported" with no member name cannot tell which of four '
              'families it was denied',
        );
      });
    }

    test('no refusal hides behind "TODO" or "not implemented"', () {
      for (final member in accessFamilies) {
        Object? caught;
        try {
          reachFamily(client, member);
        } catch (e) {
          caught = e;
        }
        final message = (caught as UnsupportedError).message.toString();
        expect(message.toLowerCase(), isNot(contains('todo')),
            reason: '$member: a refusal naming a plan tells an integrator '
                'nothing to change');
        expect(message.toLowerCase(), isNot(contains('not implemented')),
            reason: '$member: the member IS implemented; what is absent is the '
                'proxy behind it');
      }
    });

    test('no family answers with an empty proxy instead of refusing', () {
      // A `ClientAuditApi` that answered "no entries" without a wire method
      // behind it would draw an empty audit trail on a panel, for a plant that
      // has plenty, with nothing anywhere saying why. That is the same failure
      // `remote_state_man.dart` already refuses to make about timeseries.
      for (final member in accessFamilies) {
        Object? returned;
        var threw = false;
        try {
          returned = reachFamily(client, member);
        } catch (_) {
          threw = true;
        }
        expect(threw, isTrue,
            reason: 'RemoteStateMan.$member answered with $returned instead '
                'of refusing, and there is no wire method behind it to have '
                'answered from');
      }
    });

    test('LIVE CONTROL: the four data-service proxies are still built', () {
      // Without this the refusals above are satisfied by a client that has
      // failed to construct anything at all. These four answer from memory —
      // no round trip — so a dead port is irrelevant to them, which is what
      // makes them the right control for a getter-level property.
      expect(client.browse, isA<BrowseApi>());
      expect(client.timeseries, isA<TimeseriesApi>());
      expect(client.historyViews, isA<HistoryViewApi>());
      expect(client.preferences, isA<PreferencesApi>());
    });

    test('LIVE CONTROL: the client is a live StateManApi, not a husk', () {
      expect(client, isA<StateManApi>());
      expect(client.keys, isA<List<String>>());
    });
  });
}
