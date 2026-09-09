@TestOn('browser')
library;

// This file's first job is to be **compiled**. `tfc_relay_client` was
// unbuildable for the web over `dart:io` in exactly two files — the dial and
// the pinned `HttpClient` the dial needs — while the other fourteen were
// already platform-free. A stray `import 'dart:io'` creeping back into any of
// them compiles perfectly on the VM and fails only when somebody tries
// `flutter build web` months later; here it fails the lane.
//
// Its second job is the rules that are *different* in a browser, which are
// stricter rather than looser, and which are easy to get backwards:
//
//   - `wss` only. A browser cannot be trusted to refuse plaintext on its own —
//     whether it does depends on how the page was served, so a page opened
//     over `http://` would happily put a station credential on the wire.
//   - No configured root. There is no API to add a trust root, to pin one, or
//     to read the peer certificate, so a `ClientTlsConfig` here is a claim the
//     platform cannot honour — refused rather than ignored.
//   - `wss` with *no* root is therefore the only dialable shape, and it is the
//     exact combination a station refuses.

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/dial/pinned_dialer.dart';
import 'package:tfc_relay_client/src/dial/trust_capability.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:test/test.dart';

void main() {
  test('the browser is known not to pin', () {
    expect(kCanPinTrustRoot, isFalse);
    expect(PinnedDialer.pins, isFalse);
  });

  group('checkDialable, browser rules', () {
    test('wss with no root is the dialable shape', () {
      // The mirror image of the station rule, which refuses precisely this.
      expect(
        () => ClientConfig().checkDialable(Uri.parse('wss://gw.plant:9443')),
        returnsNormally,
      );
    });

    test('ws is refused, however the page was served', () {
      expect(
        () => ClientConfig().checkDialable(Uri.parse('ws://gw.plant:9443')),
        throwsA(isA<ArgumentError>().having(
            (e) => '$e', 'message', contains('wss:// only'))),
      );
    });

    test('http and https are refused as schemes too', () {
      for (final scheme in ['http', 'https']) {
        expect(
          () => ClientConfig().checkDialable(Uri.parse('$scheme://gw.plant')),
          throwsArgumentError,
          reason: '$scheme is not a WebSocket scheme',
        );
      }
    });

    test('a configured root is refused rather than silently ignored', () {
      // Ignoring it would leave a configuration that *reads* as pinned while
      // nothing pins — the failure mode a packet capture finds months later.
      expect(
        () => ClientConfig(tls: ClientTlsConfig.pem('-----BEGIN CERTIFICATE-'))
            .checkDialable(Uri.parse('wss://gw.plant:9443')),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('cannot use one'))),
      );
    });
  });

  group('the dialler refuses before it opens anything', () {
    test('a plaintext dial never reaches a socket', () async {
      final attempt = await PinnedDialer(null).dial(Uri.parse('ws://gw:9443'));
      expect(attempt, isA<ConnectFailed>());
      expect('${(attempt as ConnectFailed).error}', contains('wss:// only'));
      // No socket was opened, so there is no close code to report — as
      // opposed to zero, which would read as a socket that closed cleanly.
      expect(attempt.closeCode, isNull);
    });

    test('a configured root fails every dial with the same sentence', () async {
      final dialler = PinnedDialer(ClientTlsConfig.pem('-----BEGIN CERT'));
      final attempt = await dialler.dial(Uri.parse('wss://gw.plant:9443'));
      expect(attempt, isA<ConnectFailed>());
      expect('${(attempt as ConnectFailed).error}',
          contains('browser cannot use one'));
    });

    test('a refused dial never claims the certificate was untrusted',
        () async {
      // A browser cannot tell a refused certificate from an absent gateway:
      // the socket fires a bare error and closes 1006 with an empty reason.
      // Guessing would send an engineer to the wrong end of the wire.
      final attempt = await PinnedDialer(null).dial(Uri.parse('ws://gw:1'));
      expect((attempt as ConnectFailed).certificateUntrusted, isFalse);
    });
  });
}
