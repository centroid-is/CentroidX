import 'package:centroidx_setup/answers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('password validation', () {
    test('rejects anything the shell/compose path cannot carry', () {
      // A space would run the rest of the value as a command if any of the
      // four layers ever stopped quoting it, and it is also what makes a '#'
      // start a comment in compose's dotenv parser.
      expect(validatePassword('foo bar12'), isNotNull);
      expect(validatePassword('tab\tstop12'), isNotNull);
      // $ is eaten by compose interpolation; the rest are command syntax.
      expect(validatePassword(r'has$dollar'), isNotNull);
      expect(validatePassword('back`tick`x'), isNotNull);
      expect(validatePassword('semi;colonx'), isNotNull);
      expect(validatePassword("quote'x123"), isNotNull);
      expect(validatePassword('double"quote'), isNotNull);
      expect(validatePassword(r'back\slash1'), isNotNull);
      expect(validatePassword('amper&sand1'), isNotNull);
      expect(validatePassword('pipe|char12'), isNotNull);
      expect(validatePassword('redirect>12'), isNotNull);
      expect(validatePassword('redirect<12'), isNotNull);
      expect(validatePassword('paren(then)1'), isNotNull);
      // Not ASCII: chpasswd and a container's shell disagree about these.
      expect(validatePassword('þorlákur12'), isNotNull);
      // A newline would end the key=value line and make the rest of the
      // password a key of its own. The shell side needed a second attempt to
      // catch this (grep matches line by line), so it is asserted on both.
      expect(validatePassword('newline\npass'), isNotNull);
    });

    test('rejects short values', () {
      expect(validatePassword('short'), isNotNull);
      expect(validatePassword(''), isNotNull);
      expect(validatePassword(null), isNotNull);
    });

    test('accepts the documented charset', () {
      expect(validatePassword('a-pass:with@odd%chars'), isNull);
      expect(validatePassword('Plain12345'), isNull);
      expect(validatePassword('dots.and_unders~/+'), isNull);
    });

    test("accepts '#', which the old allow list refused for no reason", () {
      // Reported from a panel: an operator could not type the password they
      // wanted. '#' only opens a comment in compose's dotenv when whitespace
      // precedes it, and whitespace is refused above, so it is safe at every
      // layer this value travels through.
      expect(validatePassword('hash#pass1'), isNull);
      expect(validatePassword('#leading12'), isNull);
      expect(validatePassword('trailing1#'), isNull);
    });

    test('accepts the rest of the printable symbols', () {
      // These are word-expansion characters at worst -- a wrong filename
      // inside a shell, never a command -- so there is no reason to make an
      // operator hunt for a key that is allowed.
      for (final c in r'''!,=?*^[]{}'''.split('')) {
        expect(validatePassword('pass${c}word1'), isNull,
            reason: 'should accept $c');
      }
    });

    test('refuses exactly the characters the rule text names', () {
      // The message under the field and the check must not drift apart; the
      // shell installer prints the same list from PASSWORD_RULE.
      for (final c in hazardousPasswordChars.split('')) {
        expect(validatePassword('aaaaaaaa$c'), isNotNull,
            reason: 'rule names $c but the validator allows it');
      }
    });
  });

  group('generated passwords', () {
    test('always satisfy the validator', () {
      for (var i = 0; i < 200; i++) {
        expect(validatePassword(generatePassword()), isNull);
      }
    });

    test('avoid look-alike characters, since they get read off a screen', () {
      for (var i = 0; i < 200; i++) {
        expect(generatePassword(), isNot(matches(RegExp('[lIO01]'))));
      }
    });
  });

  group('station name', () {
    test('must be a usable hostname and certificate CN', () {
      expect(validateStationName('line1'), isNull);
      expect(validateStationName('st-101'), isNull);
      expect(validateStationName(''), isNotNull);
      expect(validateStationName('-leading'), isNotNull);
      expect(validateStationName('trailing-'), isNotNull);
      expect(validateStationName('has space'), isNotNull);
      expect(validateStationName('under_score'), isNotNull);
    });
  });

  group('keyboard layout', () {
    test('accepts only the three the station offers', () {
      for (final l in keyboardLayouts) {
        expect(validateKeyboardLayout(l.code), isNull);
      }
      expect(validateKeyboardLayout('de'), isNotNull);
      expect(validateKeyboardLayout('IS'), isNotNull);
      expect(validateKeyboardLayout(''), isNotNull);
      expect(validateKeyboardLayout(null), isNotNull);
    });

    test('defaults to the first layout and reaches station.env', () {
      final a = Answers()..stationName = 'line1';
      expect(a.keyboardLayout, keyboardLayouts.first.code);
      expect(a.toStationEnv(),
          contains('KEYBOARD_DEFAULT=${keyboardLayouts.first.code}\n'));
      a.keyboardLayout = 'pl';
      expect(a.toStationEnv(), contains('KEYBOARD_DEFAULT=pl\n'));
    });
  });

  group('the VPN step', () {
    test('prefills the endpoint with Centroid\'s obfuscator', () {
      // Typing wireguard-obf.centroid.is:13256 on a touchscreen keyboard is a
      // transcription error waiting to happen, and every station Centroid
      // installs uses the same one. It is the obfuscator's address, not the
      // WireGuard server's (wireguard-1.centroid.is): wg0.conf's Endpoint is
      // 127.0.0.1, so this is the only address that leaves the machine.
      expect(Answers().vpnEndpoint, defaultVpnEndpoint);
      expect(defaultVpnEndpoint, 'wireguard-obf.centroid.is:13256');
    });

    test('the prefill alone does not make the block complete', () {
      // vpnComplete decides whether the VPN block reaches station.env. A
      // default that satisfied one of its five fields would be a step towards
      // writing a half-configured wg0.conf, which is the outcome the
      // all-or-nothing rule exists to prevent.
      expect(Answers().vpnComplete, isFalse);
      expect(Answers().toStationEnv(), isNot(contains('VPN_')));
    });
  });

  group('station.env', () {
    test('is key=value the shell installer can parse, and omits VPN when skipped', () {
      final a = Answers()
        ..stationName = 'line1'
        ..centroidPassword = 'aaaaaaaa'
        ..rootPassword = 'bbbbbbbb'
        ..vncPassword = 'cccccccc'
        ..dbPassword = 'dddddddd';
      final env = a.toStationEnv();
      expect(env, contains('STATION_NAME=line1'));
      expect(env, contains('DB_PASSWORD=dddddddd'));
      expect(env, isNot(contains('VPN_')));
      // Every non-comment line must be a single KEY=value the parser handles.
      for (final line in env.trim().split('\n')) {
        if (line.startsWith('#')) continue;
        expect(line, matches(RegExp(r'^[A-Z_]+=')));
      }
    });

    test('includes VPN fields only when the set is complete', () {
      final a = Answers()
        ..stationName = 'x'
        ..vpnWanted = true
        ..vpnEndpoint = 'vpn:13255';
      expect(a.vpnComplete, isFalse);
      expect(a.toStationEnv(), isNot(contains('VPN_ENDPOINT')));

      a
        ..vpnObfuscatorKey = 'k'
        ..vpnServerPublicKey = 'p'
        ..vpnAddress = '192.0.2.42/24';
      // Still incomplete: allowed-IPs has no default any more, and the form
      // requires it, so this must too or the field is silently dropped.
      expect(a.vpnComplete, isFalse);
      expect(a.toStationEnv(), isNot(contains('VPN_ENDPOINT')));

      a.vpnAllowedIps = '192.0.2.0/24';
      expect(a.vpnComplete, isTrue);
      expect(a.toStationEnv(), contains('VPN_ENDPOINT=vpn:13255'));
      expect(a.toStationEnv(), contains('VPN_ALLOWED_IPS=192.0.2.0/24'));
    });
  });
}
