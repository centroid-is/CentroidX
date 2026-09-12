import 'package:centroidx_setup/answers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('password validation', () {
    test('rejects anything the shell/compose path cannot carry', () {
      // The same charset the shell installer enforces. A space would run the
      // rest of the value as a command when station.conf was still sourced;
      // a $ is eaten by compose interpolation.
      expect(validatePassword('foo bar12'), isNotNull);
      expect(validatePassword(r'has$dollar'), isNotNull);
      expect(validatePassword('back`tick`x'), isNotNull);
      expect(validatePassword('semi;colonx'), isNotNull);
      expect(validatePassword("quote'x123"), isNotNull);
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
      expect(validateStationName('Frystar'), isNull);
      expect(validateStationName('st-101'), isNull);
      expect(validateStationName(''), isNotNull);
      expect(validateStationName('-leading'), isNotNull);
      expect(validateStationName('trailing-'), isNotNull);
      expect(validateStationName('has space'), isNotNull);
      expect(validateStationName('under_score'), isNotNull);
    });
  });

  group('station.env', () {
    test('is key=value the shell installer can parse, and omits VPN when skipped', () {
      final a = Answers()
        ..stationName = 'Frystar'
        ..centroidPassword = 'aaaaaaaa'
        ..rootPassword = 'bbbbbbbb'
        ..vncPassword = 'cccccccc'
        ..dbPassword = 'dddddddd';
      final env = a.toStationEnv();
      expect(env, contains('STATION_NAME=Frystar'));
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
        ..vpnAddress = '10.13.1.42/24';
      expect(a.vpnComplete, isTrue);
      expect(a.toStationEnv(), contains('VPN_ENDPOINT=vpn:13255'));
      expect(a.toStationEnv(), contains('VPN_ALLOWED_IPS=10.13.1.0/24'));
    });
  });
}
