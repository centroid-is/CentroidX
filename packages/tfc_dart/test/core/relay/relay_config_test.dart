/// The relay's configuration, judged on the two facts a plant depends on:
/// an absent section is silently OFF, and a present-but-broken one is loud.
///
/// Every arm passes its environment in as a map. Nothing here reads
/// `Platform.environment`, which is what lets one run judge a dozen different
/// deployments.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

/// A `stateman.json`-shaped map with the fields the backend already reads,
/// plus whatever [relay] section the arm is about.
Map<String, dynamic> _stateman({Object? relay, bool includeRelayKey = true}) =>
    <String, dynamic>{
      'opcua': <dynamic>[],
      'modbus': <dynamic>[],
      'jbtm': <dynamic>[],
      if (includeRelayKey) 'relay': relay,
    };

/// The smallest section that is legal: a port and a stated credential source.
Map<String, dynamic> _minimalRelay({
  Object? port = 8443,
  Object? credentials = const <String, dynamic>{'source': 'none'},
  Map<String, dynamic> extra = const <String, dynamic>{},
}) =>
    <String, dynamic>{
      'port': port,
      'credentials': credentials,
      ...extra,
    };

RelayConfig? _parse(
  Object? relay, {
  Map<String, String> env = const <String, String>{},
  bool includeRelayKey = true,
}) =>
    RelayConfig.fromJson(
      _stateman(relay: relay, includeRelayKey: includeRelayKey),
      env: env,
      source: 'stateman.json',
    );

/// [source] with `//` line comments and `/* */` blocks removed.
///
/// The same shape as `pipe_shutdown_structure_test.dart`'s, and for the same
/// reason: this file's subject documents at length the spellings it forbids,
/// and a scan a comment can trip is a scan somebody deletes.
String _stripComments(String source) {
  final out = StringBuffer();
  var inBlock = false;
  for (final rawLine in source.split('\n')) {
    var line = rawLine;
    if (inBlock) {
      final end = line.indexOf('*/');
      if (end < 0) continue;
      line = line.substring(end + 2);
      inBlock = false;
    }
    final blockStart = line.indexOf('/*');
    if (blockStart >= 0) {
      inBlock = true;
      line = line.substring(0, blockStart);
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
    final comment = _lineCommentAt(line);
    if (comment >= 0) line = line.substring(0, comment);
    out.writeln(line);
  }
  return out.toString();
}

int _lineCommentAt(String line) {
  var singles = 0;
  var doubles = 0;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (c == "'") singles++;
    if (c == '"') doubles++;
    if (c == '/' && line[i + 1] == '/' && singles.isEven && doubles.isEven) {
      return i;
    }
  }
  return -1;
}

/// The names passed to the single `ServerConfig(` construction in [source].
///
/// Depth-aware, so `TlsConfig(chainPath: …)` nested inside an argument does
/// not contribute `chainPath`. Returns the labels at the top level only.
Set<String> _serverConfigArgumentNames(String source) {
  const anchor = 'ServerConfig(';
  // Not `indexOf`: `toServerConfig()` contains the anchor as a suffix, and a
  // scan that matched the method's own name would read an empty argument list
  // and pass for ever.
  var at = -1;
  for (var i = source.indexOf(anchor); i >= 0; i = source.indexOf(anchor, i + 1)) {
    final before = i == 0 ? ' ' : source[i - 1];
    if (!RegExp(r'[A-Za-z0-9_$]').hasMatch(before)) {
      at = i;
      break;
    }
  }
  if (at < 0) return <String>{};
  var depth = 1;
  var i = at + anchor.length;
  final segments = <String>[];
  final current = StringBuffer();
  for (; i < source.length; i++) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) break;
    }
    if (c == ',' && depth == 1) {
      segments.add(current.toString());
      current.clear();
      continue;
    }
    current.write(c);
  }
  segments.add(current.toString());
  final names = <String>{};
  final label = RegExp(r'^([A-Za-z_]\w*)\s*:');
  for (final segment in segments) {
    final m = label.firstMatch(segment.trim());
    if (m != null) names.add(m.group(1)!);
  }
  return names;
}

void main() {
  // ---------------------------------------------------------------------
  group('off is what happens when nobody configured it', () {
    test('no relay key at all is null, and does not throw', () {
      expect(_parse(null, includeRelayKey: false), isNull,
          reason: 'every plant backend gets this binary before anybody turns '
              'the WebSocket on; an absent section must be OFF, not a boot '
              'failure and not a default-on server');
    });

    test('an explicit null relay section is null, and does not throw', () {
      expect(_parse(null), isNull);
    });

    test('a stateman file with no relay section reads as off, not as an error',
        () async {
      final dir = await Directory.systemTemp.createTemp('relay-config-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/stateman.json');
      await file.writeAsString(
          jsonEncode(_stateman(relay: null, includeRelayKey: false)));

      expect(await RelayConfig.fromStatemanFile(file.path), isNull);
    });

    test('a stateman file that is not there is loud, not off', () async {
      await expectLater(
        () => RelayConfig.fromStatemanFile('/nonexistent/stateman.json'),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
            contains('/nonexistent/stateman.json'))),
        reason: 'a misspelled path that read as "relay off" is a plant '
            'running unserved with nothing in the log about it',
      );
    });

    test('a present section with the same file comes back on', () async {
      final dir = await Directory.systemTemp.createTemp('relay-config-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/stateman.json');
      await file.writeAsString(jsonEncode(_stateman(relay: _minimalRelay())));

      final config = await RelayConfig.fromStatemanFile(file.path);
      expect(config, isNotNull);
      expect(config!.port, 8443);
    });
  });

  // ---------------------------------------------------------------------
  group('a present section that is broken is loud, and names the field', () {
    void refuses(String name, Object? relay, Matcher message,
        {Map<String, String> env = const <String, String>{}}) {
      test(name, () {
        expect(
            () => _parse(relay, env: env),
            throwsA(isA<ArgumentError>()
                .having((e) => '${e.message}', 'message', message)));
      });
    }

    refuses('the section is not an object', <dynamic>['port'],
        allOf(contains('relay'), contains('object')));

    refuses('port is missing', <String, dynamic>{
      'credentials': <String, dynamic>{'source': 'none'},
    }, allOf(contains('relay.port'), contains('ephemeral')));

    refuses('port is not a number', _minimalRelay(port: '8443'),
        allOf(contains('relay.port'), contains('8443')));

    refuses('port is outside 0-65535', _minimalRelay(port: 70000),
        allOf(contains('relay.port'), contains('70000')));

    refuses(
        'credentials is missing',
        <String, dynamic>{'port': 8443},
        allOf(contains('relay.credentials'),
            contains('unauthenticated')));

    refuses(
        'credentials names an unknown source',
        _minimalRelay(
            credentials: <String, dynamic>{'source': 'ldap'}),
        allOf(contains('relay.credentials.source'), contains('ldap'),
            contains('token_file')));

    refuses(
        'a token_file source names no file',
        _minimalRelay(
            credentials: <String, dynamic>{'source': 'token_file'}),
        contains('relay.credentials.token_file'));

    refuses(
        'address is not an address',
        _minimalRelay(extra: <String, dynamic>{'address': 'plc-01.svn.local'}),
        allOf(contains('relay.address'), contains('plc-01.svn.local')));

    refuses(
        'allowed_origins is not a list of strings',
        _minimalRelay(extra: <String, dynamic>{
          'allowed_origins': <dynamic>['https://a', 7],
        }),
        contains('relay.allowed_origins'));

    refuses('tls is not an object',
        _minimalRelay(extra: <String, dynamic>{'tls': 'on'}),
        contains('relay.tls'));

    refuses(
        'a key nobody knows is refused rather than ignored',
        _minimalRelay(extra: <String, dynamic>{'prot': 8443}),
        allOf(contains('prot'), contains('relay')));

    test('the typo and the absence are different facts', () {
      // The one sentence this whole group exists for.
      expect(_parse(null, includeRelayKey: false), isNull);
      expect(() => _parse(_minimalRelay(extra: {'prot': 8443})),
          throwsA(isA<ArgumentError>()),
          reason: 'a section with a typo in it must not read as "off": that '
              'is how a plant runs unserved for a week with a green log');
    });
  });

  // ---------------------------------------------------------------------
  group('TLS is all-or-nothing, refused at parse time', () {
    test('a chain with no key is refused, naming the key', () {
      expect(
          () => _parse(_minimalRelay(extra: <String, dynamic>{
                'tls': <String, dynamic>{'chain_path': '/etc/relay/chain.pem'},
              })),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('relay.tls.key_path'), contains('chain_path')))));
    });

    test('a key with no chain is refused, naming the chain', () {
      expect(
          () => _parse(_minimalRelay(extra: <String, dynamic>{
                'tls': <String, dynamic>{'key_path': '/etc/relay/key.pem'},
              })),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              contains('relay.tls.chain_path'))));
    });

    test('both together build a TlsConfig, password included', () {
      final config = _parse(_minimalRelay(extra: <String, dynamic>{
        'tls': <String, dynamic>{
          'chain_path': '/etc/relay/chain.pem',
          'key_path': '/etc/relay/key.pem',
          'key_password': 'hunter2',
        },
      }))!;
      final tls = config.toServerConfig().tls!;
      expect(tls.chainPath, '/etc/relay/chain.pem');
      expect(tls.keyPath, '/etc/relay/key.pem');
      expect(tls.keyPassword, 'hunter2');
    });

    test('no tls section is plaintext, deliberately and visibly', () {
      final config = _parse(_minimalRelay())!;
      expect(config.toServerConfig().tls, isNull);
      expect(config.bootLogLine, contains('TLS no'));
    });

    // The local grep for the callback that turns pinning off used to live
    // here. It greps one file, `lib/core/relay/relay_config.dart`, which
    // `tfc_relay_client/test/no_bad_certificate_test.dart` sweeps along with
    // every other .dart file in the repository — so no coverage was lost by
    // removing it. What it cost was the sweep itself: that sweep is a plain
    // substring match by design (an identifier-aware or language-aware rule
    // would be the one thing it has to get wrong), so the two literals here
    // counted as occurrences and the repository-wide ban had been red since
    // dccf0259. A permanently-red test stops being informative, and this one
    // is the TLS ratchet.
  });

  // ---------------------------------------------------------------------
  group('one credential source, chosen by one field', () {
    test('a token file and a validator declaration together are refused', () {
      expect(
          () => _parse(_minimalRelay(credentials: <String, dynamic>{
                'source': 'validator',
                'token_file': '/run/secrets/relay-tokens.json',
              })),
          throwsA(isA<ArgumentError>().having(
              (e) => '${e.message}',
              'message',
              allOf(
                contains('sources of truth'),
                contains('relay_server.dart:155'),
              ))),
          reason: 'without this arm the same configuration reaches '
              'RelayServer\'s constructor and throws there — at boot, on a '
              'plant machine, with nobody standing next to it');
    });

    test('the env token file over a validator deployment is refused too', () {
      expect(
          () => _parse(
                _minimalRelay(
                    credentials: <String, dynamic>{'source': 'validator'}),
                env: const <String, String>{
                  'CENTROID_RELAY_TOKEN_FILE': '/run/secrets/relay-tokens.json',
                },
              ),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('sources of truth'),
                  contains('CENTROID_RELAY_TOKEN_FILE')))));
    });

    test('a token file deployment sets auth and declares no validator', () {
      final config = _parse(_minimalRelay(credentials: <String, dynamic>{
        'source': 'token_file',
        'token_file': '/run/secrets/relay-tokens.json',
      }))!;
      expect(config.suppliesOwnValidator, isFalse);
      expect(config.toServerConfig().auth?.tokenFilePath,
          '/run/secrets/relay-tokens.json');
    });

    test('a validator deployment leaves auth null', () {
      final config = _parse(_minimalRelay(
          credentials: <String, dynamic>{'source': 'validator'}))!;
      expect(config.suppliesOwnValidator, isTrue);
      expect(config.toServerConfig().auth, isNull,
          reason: 'the ArgumentError at relay_server.dart:155 fires on '
              'auth != null AND an explicit validator; the config layer is '
              'what makes that pair unconstructible');
    });

    test('source "none" is auth null and no validator claim', () {
      final config = _parse(_minimalRelay())!;
      expect(config.suppliesOwnValidator, isFalse);
      expect(config.toServerConfig().auth, isNull);
    });

    test('across every source, at most one of auth / validator is produced',
        () {
      final sources = <Map<String, dynamic>>[
        <String, dynamic>{'source': 'none'},
        <String, dynamic>{'source': 'validator'},
        <String, dynamic>{
          'source': 'token_file',
          'token_file': '/run/secrets/relay-tokens.json',
        },
      ];
      for (final credentials in sources) {
        final config = _parse(_minimalRelay(credentials: credentials))!;
        final both = config.toServerConfig().auth != null &&
            config.suppliesOwnValidator;
        expect(both, isFalse,
            reason: 'credentials $credentials produced both an AuthConfig and '
                'a validator claim, which is the exact pair RelayServer '
                'refuses at construction');
      }
    });
  });

  // ---------------------------------------------------------------------
  group('env overrides the operational knobs, and only those', () {
    for (final off in const <String>['0', 'false', 'FALSE', 'no', 'off']) {
      test('CENTROID_RELAY_ENABLED=$off forces off with a section present', () {
        expect(
            _parse(_minimalRelay(),
                env: <String, String>{'CENTROID_RELAY_ENABLED': off}),
            isNull);
      });
    }

    for (final on in const <String>['1', 'true', 'TRUE', 'yes', 'on']) {
      test('CENTROID_RELAY_ENABLED=$on leaves a present section on', () {
        expect(
            _parse(_minimalRelay(),
                env: <String, String>{'CENTROID_RELAY_ENABLED': on}),
            isNotNull);
      });
    }

    test('CENTROID_RELAY_ENABLED=maybe is refused, naming the variable', () {
      expect(
          () => _parse(_minimalRelay(),
              env: const <String, String>{'CENTROID_RELAY_ENABLED': 'maybe'}),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('CENTROID_RELAY_ENABLED'), contains('maybe')))));
    });

    test('CENTROID_RELAY_ENABLED=1 does not invent a section', () {
      expect(
          _parse(null,
              includeRelayKey: false,
              env: const <String, String>{'CENTROID_RELAY_ENABLED': '1'}),
          isNull,
          reason: 'an env variable cannot supply a port, a credential source '
              'or a certificate; enabling nothing is still nothing');
    });

    test('CENTROID_RELAY_PORT replaces the file port', () {
      final config = _parse(_minimalRelay(),
          env: const <String, String>{'CENTROID_RELAY_PORT': '9443'})!;
      expect(config.port, 9443);
      expect(config.toServerConfig().port, 9443);
    });

    test('CENTROID_RELAY_PORT that is not a port is refused', () {
      expect(
          () => _parse(_minimalRelay(),
              env: const <String, String>{'CENTROID_RELAY_PORT': 'https'}),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              allOf(contains('CENTROID_RELAY_PORT'), contains('https')))));
    });

    test('CENTROID_RELAY_ADDRESS replaces the file address', () {
      final config = _parse(
          _minimalRelay(extra: <String, dynamic>{'address': '127.0.0.1'}),
          env: const <String, String>{'CENTROID_RELAY_ADDRESS': '10.104.29.5'})!;
      expect(config.toServerConfig().address.address, '10.104.29.5');
    });

    test('CENTROID_RELAY_ADDRESS that is a hostname is refused', () {
      expect(
          () => _parse(_minimalRelay(),
              env: const <String, String>{
                'CENTROID_RELAY_ADDRESS': 'backend.svn.local'
              }),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              contains('CENTROID_RELAY_ADDRESS'))));
    });

    test('the TLS pair can be supplied entirely from env', () {
      final config = _parse(_minimalRelay(), env: const <String, String>{
        'CENTROID_RELAY_TLS_CHAIN': '/run/tls/chain.pem',
        'CENTROID_RELAY_TLS_KEY': '/run/tls/key.pem',
      })!;
      final tls = config.toServerConfig().tls!;
      expect(tls.chainPath, '/run/tls/chain.pem');
      expect(tls.keyPath, '/run/tls/key.pem');
      expect(tls.keyPassword, isNull);
    });

    test('half a TLS pair from env is refused after the overlay', () {
      expect(
          () => _parse(_minimalRelay(),
              env: const <String, String>{
                'CENTROID_RELAY_TLS_CHAIN': '/run/tls/chain.pem'
              }),
          throwsA(isA<ArgumentError>().having(
              (e) => '${e.message}', 'message', contains('key_path'))),
          reason: 'a half-configured pair must not reach bind time, where the '
              'symptom is a SecurityContext failure naming a file');
    });

    test('CENTROID_RELAY_TLS_KEY_PASSWORD overlays the file pair', () {
      final config = _parse(
          _minimalRelay(extra: <String, dynamic>{
            'tls': <String, dynamic>{
              'chain_path': '/etc/relay/chain.pem',
              'key_path': '/etc/relay/key.pem',
            },
          }),
          env: const <String, String>{
            'CENTROID_RELAY_TLS_KEY_PASSWORD': 'from-the-vault'
          })!;
      expect(config.toServerConfig().tls!.keyPassword, 'from-the-vault');
    });

    test('CENTROID_RELAY_TOKEN_FILE supplies the credential source', () {
      final config = _parse(_minimalRelay(), env: const <String, String>{
        'CENTROID_RELAY_TOKEN_FILE': '/run/secrets/relay-tokens.json',
      })!;
      expect(config.toServerConfig().auth?.tokenFilePath,
          '/run/secrets/relay-tokens.json');
    });

    test('CENTROID_RELAY_TOKEN_FILE replaces a file token path', () {
      final config = _parse(
          _minimalRelay(credentials: <String, dynamic>{
            'source': 'token_file',
            'token_file': '/etc/relay/old-tokens.json',
          }),
          env: const <String, String>{
            'CENTROID_RELAY_TOKEN_FILE': '/run/secrets/relay-tokens.json',
          })!;
      expect(config.toServerConfig().auth?.tokenFilePath,
          '/run/secrets/relay-tokens.json');
    });

    test('two environments in one run give two configurations', () {
      final json = _stateman(relay: _minimalRelay());
      final a = RelayConfig.fromJson(json,
          env: const <String, String>{'CENTROID_RELAY_PORT': '9001'})!;
      final b = RelayConfig.fromJson(json,
          env: const <String, String>{'CENTROID_RELAY_PORT': '9002'})!;
      expect(a.port, 9001);
      expect(b.port, 9002);
    });

    test('the parser never reads the process environment', () {
      final source = _stripComments(
          File('lib/core/relay/relay_config.dart').readAsStringSync());
      expect('Platform.environment'.allMatches(source).length, 0,
          reason: 'a parser that reads the process environment cannot be '
              'tested for two configurations in one run, which is what the '
              'arm above does');
    });
  });

  // ---------------------------------------------------------------------
  group('toServerConfig names what it configures and nothing else', () {
    test('every field this config does not name is at its ServerConfig default',
        () {
      final defaults = ServerConfig();
      final mapped = _parse(_minimalRelay())!.toServerConfig();

      // Asserted against `ServerConfig()`, never against a literal: a number
      // copied here is a number that drifts from the package that argued for
      // it.
      expect(mapped.tick, defaults.tick);
      expect(mapped.heartbeatDeadline, defaults.heartbeatDeadline);
      expect(mapped.minHeartbeatDeadline, defaults.minHeartbeatDeadline);
      expect(mapped.pingInterval, defaults.pingInterval);
      expect(mapped.stallThreshold, defaults.stallThreshold);
      expect(mapped.maxPending, defaults.maxPending);
      expect(mapped.peakThreshold, defaults.peakThreshold);
      expect(mapped.peakWindowMs, defaults.peakWindowMs);
      expect(mapped.maxKeysPerSubscribe, defaults.maxKeysPerSubscribe);
      expect(mapped.maxSubscriptionsPerSession,
          defaults.maxSubscriptionsPerSession);
      expect(mapped.maxTimeseriesPoints, defaults.maxTimeseriesPoints);
      expect(mapped.maxFrameBytes, defaults.maxFrameBytes);
      expect(mapped.maxPendingBytes, defaults.maxPendingBytes);
      expect(mapped.writeOutcomeTtl, defaults.writeOutcomeTtl);
      expect(mapped.allowedOrigins, defaults.allowedOrigins);
      expect(mapped.address.address, defaults.address.address);
      expect(mapped.publisherId, defaults.publisherId);
    });

    test('the construction passes only the labels this config names', () {
      // The arm above cannot see a default RE-SPELLED as a literal: a copied
      // `maxTimeseriesPoints: 6000` equals `ServerConfig().maxTimeseriesPoints`
      // and passes. This one reads the source and refuses the label itself, so
      // a number can only arrive here by being added to the allow list in the
      // same diff.
      const named = <String>{
        'address',
        'port',
        'tls',
        'auth',
        'allowedOrigins',
        'publisherId',
      };
      final source = _stripComments(
          File('lib/core/relay/relay_config.dart').readAsStringSync());
      expect(_serverConfigArgumentNames(source), named,
          reason: 'toServerConfig may pass only the fields RelayConfig names. '
              'Every other ServerConfig field keeps the default the server '
              'package argued for; re-spelling one here is how two numbers '
              'start disagreeing');
    });

    test('the label scan is not vacuous', () {
      final source = _stripComments(
          File('lib/core/relay/relay_config.dart').readAsStringSync());
      expect(_serverConfigArgumentNames(source), isNotEmpty);
      expect(_serverConfigArgumentNames(source), contains('port'));
    });

    test('the named fields do arrive', () {
      final mapped = _parse(_minimalRelay(extra: <String, dynamic>{
        'address': '0.0.0.0',
        'publisher_id': 'centroidx-backend-svn',
        'allowed_origins': <dynamic>['https://hmi.svn.local'],
        'tls': <String, dynamic>{
          'chain_path': '/etc/relay/chain.pem',
          'key_path': '/etc/relay/key.pem',
        },
      }))!
          .toServerConfig();
      expect(mapped.address.address, '0.0.0.0');
      expect(mapped.port, 8443);
      expect(mapped.publisherId, 'centroidx-backend-svn');
      expect(mapped.allowedOrigins, <String>['https://hmi.svn.local']);
      expect(mapped.tls, isNotNull);
    });
  });

  // ---------------------------------------------------------------------
  group('one boot line, and an operator can tell which happened', () {
    test('the off line names the absent section and the file', () {
      final boot = RelayBoot.fromStatemanJson(
          _stateman(relay: null, includeRelayKey: false),
          source: '/etc/centroid/stateman.json');
      expect(boot.isOn, isFalse);
      expect(boot.config, isNull);
      expect(boot.bootLogLine, contains('OFF'));
      expect(boot.bootLogLine, contains('no `relay` section'));
      expect(boot.bootLogLine, contains('/etc/centroid/stateman.json'));
    });

    test('the env-disabled off line says which variable did it', () {
      final boot = RelayBoot.fromStatemanJson(
          _stateman(relay: _minimalRelay()),
          source: '/etc/centroid/stateman.json',
          env: const <String, String>{'CENTROID_RELAY_ENABLED': '0'});
      expect(boot.isOn, isFalse);
      expect(boot.bootLogLine, contains('OFF'));
      expect(boot.bootLogLine, contains('CENTROID_RELAY_ENABLED'));
    });

    test('an absent section beats the env variable in the reason it gives', () {
      final boot = RelayBoot.fromStatemanJson(
          _stateman(relay: null, includeRelayKey: false),
          source: '/etc/centroid/stateman.json',
          env: const <String, String>{'CENTROID_RELAY_ENABLED': '0'});
      expect(boot.bootLogLine, contains('no `relay` section'),
          reason: 'there was nothing to disable; the truthful reason is the '
              'one an operator can act on');
    });

    test('the on line carries address, port, TLS, credentials and origins', () {
      final boot = RelayBoot.fromStatemanJson(
          _stateman(
              relay: _minimalRelay(extra: <String, dynamic>{
            'address': '0.0.0.0',
            'allowed_origins': <dynamic>['https://hmi.svn.local'],
            'tls': <String, dynamic>{
              'chain_path': '/etc/relay/chain.pem',
              'key_path': '/etc/relay/key.pem',
              'key_password': 'hunter2',
            },
            'credentials': <String, dynamic>{
              'source': 'token_file',
              'token_file': '/run/secrets/relay-tokens.json',
            },
          })),
          source: '/etc/centroid/stateman.json');

      expect(boot.isOn, isTrue);
      final line = boot.bootLogLine;
      expect(line, contains('ON'));
      expect(line, contains('0.0.0.0'));
      expect(line, contains('8443'));
      expect(line, contains('TLS yes'));
      expect(line, contains('/run/secrets/relay-tokens.json'));
      expect(line, contains('1 allowed origin'));
    });

    test('the on line never carries the key password', () {
      final boot = RelayBoot.fromStatemanJson(
          _stateman(
              relay: _minimalRelay(extra: <String, dynamic>{
            'tls': <String, dynamic>{
              'chain_path': '/etc/relay/chain.pem',
              'key_path': '/etc/relay/key.pem',
              'key_password': 'hunter2',
            },
          })),
          source: '/etc/centroid/stateman.json');
      expect(boot.bootLogLine, isNot(contains('hunter2')));
    });

    test('the two shapes are one line each and tell each other apart', () {
      final off = RelayBoot.fromStatemanJson(
          _stateman(relay: null, includeRelayKey: false),
          source: 's.json');
      final on = RelayBoot.fromStatemanJson(_stateman(relay: _minimalRelay()),
          source: 's.json');
      expect(off.bootLogLine.split('\n').length, 1);
      expect(on.bootLogLine.split('\n').length, 1);
      expect(off.bootLogLine, isNot(on.bootLogLine));
      expect(on.bootLogLine, isNot(contains('OFF')));
    });

    test('bootLogLine on the instance is the on shape', () {
      final config = _parse(_minimalRelay())!;
      expect(config.bootLogLine, contains('ON'));
    });
  });
}
