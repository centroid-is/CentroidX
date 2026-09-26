@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
// The decision the web arm makes, without the DOM it reads its inputs from.
// `gateway_default_web.dart` itself imports `package:web` and is the one file
// in this seam a VM test cannot drive; everything it decides lives here, and
// is driven here with any page and any declaration. The seam's VM arm is
// covered by `gateway_default_test.dart`.
import 'package:tfc/core/gateway_declaration.dart';
import 'package:tfc_dart/core/preferences_api.dart';

/// The transport a browser comes up on when nothing has told it otherwise.
///
/// Three sources in one order — the stored row, the served declaration, the
/// page's own origin — and each has a failure that must be told apart from the
/// others: a missing declaration is the origin, a malformed one is a refusal
/// with the typo in it, and a stored row is never displaced by either.
void main() {
  group('the origin, with no declaration', () {
    test('an https page dials back to its own origin over wss', () {
      final config = gatewayDefaultFor(
          page: Uri.parse('https://gateway.plant:8443/index.html'));
      expect(config.isGateway, isTrue);
      expect(config.url, 'wss://gateway.plant:8443');
      expect(config.undialableWhen(canPinTrust: false), isNull,
          reason: 'a browser cannot pin, so a trustless wss row is the one '
              'dial it can make — nothing may stand between a fresh tab and '
              'the gateway that served it');
    });

    test('a default port is not spelled out', () {
      final config =
          gatewayDefaultFor(page: Uri.parse('https://gateway.plant/'));
      expect(config.url, 'wss://gateway.plant',
          reason: 'the page did not name a port, so neither does the dial; '
              'wss takes 443 on its own');
    });

    test('an http page derives ws, which a browser refuses by name rather '
        'than dialling', () {
      final config =
          gatewayDefaultFor(page: Uri.parse('http://127.0.0.1:8771/'));
      expect(config.isGateway, isTrue);
      expect(config.url, 'ws://127.0.0.1:8771');
      // The boot path consults `undialable` before it constructs a client, so
      // this is what `stateManProvider` throws on and what the link reports
      // as notBuilt — and what makes `relayCanAuthenticate` false, which is
      // the condition that opens Server Config to an unsigned-in browser.
      final refusal = config.undialableWhen(canPinTrust: false);
      expect(refusal, isNotNull);
      expect(refusal, contains('wss'));
    });

    test('a page with no origin gets no address to guess at', () {
      final config = gatewayDefaultFor(
          page: Uri.parse('file:///C:/bundle/index.html'));
      expect(config.isGateway, isTrue,
          reason: 'direct is the one mode a page can never satisfy');
      expect(config.url, isEmpty);
      expect(config.validationErrorWhen(canPinTrust: false),
          contains('Enter the gateway address'));
    });
  });

  group('the declaration served with the page', () {
    // A bench: the bundle comes from a plain static server that is not the
    // gateway, so the origin would be wrong on its own.
    final bench = Uri.parse('http://127.0.0.1:8771/');

    test('a declared address beats the origin', () {
      final config = gatewayDefaultFor(
          page: bench, declared: 'wss://10.50.10.11:9443');
      expect(config.isGateway, isTrue);
      expect(config.url, 'wss://10.50.10.11:9443');
      expect(config.undialableWhen(canPinTrust: false), isNull,
          reason: 'this is the whole point: a browser served from a host '
              'that is not the gateway comes up dialling the gateway, with '
              'nobody typing anything');
    });

    test('an address without a scheme is completed to wss, as the Server '
        'Config field completes it', () {
      final config =
          gatewayDefaultFor(page: bench, declared: '10.50.10.11:9443');
      expect(config.url, 'wss://10.50.10.11:9443');
      expect(config.undialableWhen(canPinTrust: false), isNull);
    });

    test('surrounding whitespace is not part of the address', () {
      final config = gatewayDefaultFor(
          page: bench, declared: '  wss://10.50.10.11:9443\n');
      expect(config.url, 'wss://10.50.10.11:9443');
    });

    for (final (label, declared) in const <(String, String?)>[
      ('an absent tag', null),
      ('an empty tag', ''),
      ('a whitespace-only tag', '   '),
      ("the template's un-substituted placeholder",
          kGatewayDeclarationPlaceholder),
    ]) {
      test('$label is no declaration, and the origin stands', () {
        final config = gatewayDefaultFor(page: bench, declared: declared);
        expect(config.url, 'ws://127.0.0.1:8771',
            reason: 'a bundle served by something that knows nothing of the '
                'tag must behave exactly as it did before the tag existed — '
                'never as a configured-but-broken gateway');
      });
    }

    test('the placeholder is matched exactly, so it cannot hide a typo', () {
      expect(kGatewayDeclarationPlaceholder, r'$CENTROIDX_GATEWAY',
          reason: 'the serving host substitutes this token; renaming it '
                  'silently would leave every deployed template inert');
      final config = gatewayDefaultFor(
          page: bench, declared: r'$CENTROIDX_GATEWAY_TYPO');
      expect(config.url, isNot('ws://127.0.0.1:8771'),
          reason: 'a dollar-something that is not the placeholder is a real '
              'declaration that happens to be wrong');
      expect(config.validationErrorWhen(canPinTrust: false), isNotNull);
    });

    test('a malformed declaration is refused by name, with the typo in it',
        () {
      final config = gatewayDefaultFor(
          page: bench, declared: 'wss://10.50.10.11:9443 (the gateway)');
      expect(config.isGateway, isTrue);
      expect(config.url, contains('(the gateway)'),
          reason: 'verbatim: the misconfigured banner and the Server Config '
              'field both show the operator what was declared');
      final refusal = config.validationErrorWhen(canPinTrust: false);
      expect(refusal, isNotNull,
          reason: 'silently dropping a bad declaration would dial the origin '
              'and fail somewhere less legible; the integrator must see '
              'the typo');
      expect(config.undialableWhen(canPinTrust: false), refusal,
          reason: 'the boot path refuses on the same sentence the field '
              'shows');
    });

    test('a plaintext declaration is refused in a browser like any ws dial',
        () {
      final config =
          gatewayDefaultFor(page: bench, declared: 'ws://bench:9443');
      expect(config.url, 'ws://bench:9443', reason: 'kept as typed');
      expect(config.undialableWhen(canPinTrust: false), contains('wss'));
    });

    test('the tag is named where the serving host will look for it', () {
      expect(kGatewayDeclarationMetaName, 'centroidx-gateway');
    });
  });

  group('the stored row wins over both', () {
    test('a saved transport row is returned before the default is asked',
        () async {
      const saved = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://the-one-the-operator-chose:9443',
      );
      final prefs = InMemoryPreferences();
      await writeGatewayConfig(prefs, saved);

      var fallbackAsked = false;
      final read = await readGatewayConfig(prefs, fallback: () {
        fallbackAsked = true;
        return gatewayDefaultFor(
            page: Uri.parse('http://127.0.0.1:8771/'),
            declared: 'wss://what-the-server-declared:9443');
      });

      expect(read, saved,
          reason: 'Server Config saved this in the browser; a redeploy of '
              'the bundle with a different declaration must not move it');
      expect(fallbackAsked, isFalse,
          reason: 'the declaration is a default, not a pin: it is not even '
              'consulted while a row exists, so it cannot overwrite one');
    });

    test('with no row, the fallback is what a fresh tab gets', () async {
      final read = await readGatewayConfig(
        InMemoryPreferences(),
        fallback: () => gatewayDefaultFor(
            page: Uri.parse('http://127.0.0.1:8771/'),
            declared: 'wss://what-the-server-declared:9443'),
      );
      expect(read.url, 'wss://what-the-server-declared:9443');
    });
  });
}
