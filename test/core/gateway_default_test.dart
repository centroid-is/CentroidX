@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc_dart/core/preferences_api.dart';
import 'package:tfc/core/gateway_default.dart';

/// The transport a client comes up on when nothing has told it otherwise.
///
/// This is the arm that decides whether a browser can reach the plant at all.
/// `direct` is the one mode a page can never satisfy — it cannot open an OPC UA
/// session, a Modbus socket or a Postgres pool — so a web build that fell back
/// to it threw in `direct_transport_web.dart` before any screen could offer a
/// different choice. A fresh tab has no preferences row, so the fallback *is*
/// the configuration for every first visit.
void main() {
  group('the default transport', () {
    test('a station with no row still runs direct, exactly as it does today',
        () {
      // The native arm, which is what this VM test exercises. Changing it would
      // re-point every unconfigured panel in the plant at a gateway it was
      // never pointed at, which is the failure this pins against.
      expect(defaultGatewayConfig().mode, TransportMode.direct);
      expect(defaultGatewayConfig().url, isEmpty);
      expect(defaultGatewayConfig().isGateway, isFalse);
    });

    test('an absent row takes the default rather than a hardcoded direct',
        () async {
      final prefs = _EmptyPrefs();
      final read = await readGatewayConfig(prefs);
      expect(read.mode, defaultGatewayConfig().mode,
          reason: 'readGatewayConfig must go through the seam; a literal '
              'GatewayConfig.defaults here is what made every web client boot '
              'into the one mode it cannot have');
    });

    test('a corrupt row lands on the default too, not on direct by name',
        () async {
      final prefs = _EmptyPrefs(raw: 'not json at all');
      final read = await readGatewayConfig(prefs);
      expect(read.mode, defaultGatewayConfig().mode,
          reason: 'a client that cannot read its transport choice must still '
              'come up on a transport it could possibly have');
    });

    test('a stored row still wins over the default', () async {
      final prefs = _EmptyPrefs(
          raw: '{"mode":"gateway","url":"wss://plant.example:8443"}');
      final read = await readGatewayConfig(prefs);
      expect(read.isGateway, isTrue);
      expect(read.url, 'wss://plant.example:8443',
          reason: 'the default is a default: an operator who pointed this '
              'client somewhere must find it still pointed there after a '
              'reload');
    });
  });
}

/// A preferences store holding at most the transport row.
class _EmptyPrefs implements PreferencesApi {
  _EmptyPrefs({this.raw});
  final String? raw;

  @override
  Future<String?> getString(String key) async =>
      key == GatewayConfig.prefsKey ? raw : null;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('readGatewayConfig reads one key: getString');
}
