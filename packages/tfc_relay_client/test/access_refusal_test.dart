/// `RemoteStateMan` serves all four access families, and none of them by
/// refusal any more.
///
/// ## What this file used to claim, and why the claim flipped
///
/// Between 17-03 and 17-08 the four getters refused with an
/// `UnsupportedError` naming the missing proxy, and this file pinned that —
/// its own doc said "until 17-08 writes one". 17-08 wrote them:
/// `client_sub_apis.dart` gained `ClientAccessTemplateApi`,
/// `ClientAccessAdminApi`, `ClientAuditApi` and `ClientBackendConfigApi`, and
/// the getters answer with proxies built once and kept, exactly as the four
/// data services are. The refusal arms would now be false claims, so the file
/// keeps only the halves that are still true — the exhaustiveness guard over
/// the four families, and the live controls.
///
/// The proxies' own behavioural pins — one request per member, the
/// no-identity payload pin, `forbidden` → `AccessDenied` with the message
/// intact, the two no-retry halves, the structured domain payload and the
/// contract leg — live in `access_proxies_test.dart`, which supersedes this
/// file's refusal groups rather than duplicating them here.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The four getters this file judges — the exhaustiveness guard: a fifth
/// access family added to `StateManApi` without a row here is invisible to
/// this sweep, and the surface test in the contract kit reddens on the count.
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

/// A port nothing is bound to — the panel's ordinary state at power-on. The
/// getters under test answer without a round trip, so a dead port is the
/// right fixture: anything they did over the wire would hang here instead of
/// passing quietly.
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

  group('RemoteStateMan serves the four access families', () {
    for (final member in accessFamilies) {
      test('$member answers with a proxy, without a round trip', () {
        expect(reachFamily(client, member), isNotNull,
            reason: 'a panel that asked for $member and was refused after '
                '17-08 has lost a capability the plan shipped — the getter '
                'is one line over the proxy 17-08 wrote');
      });
    }

    test('each family answers the same instance every time', () {
      for (final member in accessFamilies) {
        expect(identical(reachFamily(client, member), reachFamily(client, member)),
            isTrue,
            reason: '$member: the sub-APIs are built once and kept '
                '(remote_state_man.dart\'s sub-API block); a fresh instance '
                'per getter read would be a different shape for no reason');
      }
    });

    test('LIVE CONTROL: the four data-service proxies are still built', () {
      // Without this the group above is satisfied by a client that has
      // failed to construct anything at all. These four answer from memory —
      // no round trip — so a dead port is irrelevant to them.
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
