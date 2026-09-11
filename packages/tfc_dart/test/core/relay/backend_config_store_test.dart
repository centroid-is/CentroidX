/// The backend's own `StateManConfig` file, served for reading and writing
/// over the wire (17-10, ACCESS-04's server half).
///
/// Against a real temp-directory file, not a mock filesystem — this store's
/// whole job is the file. The claims, one arm each:
///
///  1. `read` returns the file, `relay` section included, flagged read-only
///  2. `read` and `write` on a missing file refuse by name — an empty config
///     would render as "no servers configured" next to a plant that has four
///  3. `read` redacts secret VALUES (password, ssl_key) behind a sentinel and
///     still returns paths — the `TlsConfig` discipline: paths cross, bytes
///     and credentials do not (SECURITY FIX 3, T-17-10g)
///  4. `validate` answers ok / the parser's failure, and writes nothing
///  5. `write` of an invalid payload writes NOTHING — the file's bytes are
///     byte-identical afterwards (D-10's first hazard)
///  6. an accepted `write` replaces the file and leaves the previous contents
///     at `<path>.previous`, byte-identical
///  7. one level of undo: a second write overwrites `.previous` with the
///     immediately previous contents, not the original
///  8. `previous` returns those bytes (redacted); `restorePrevious` swaps them
///     back and leaves the rejected config at `.previous`; both refuse by name
///     when nothing has ever been written
///  9. a payload whose `relay` section DIFFERS is refused by name — you do not
///     edit the socket over the socket (D-10)
/// 10. a payload whose `relay` section is IDENTICAL succeeds — without this,
///     arm 9 is a refuse-everything trap
/// 11. `relay` absent-vs-present is a difference, in BOTH directions
/// 12. an accepted write leaves an audit row: surface `config`, itemKey the
///     file path, who/station/roleName from the verified session, origin
///     `relay`
/// 13. a stray top-level `"who"` key neither names the row nor reaches the
///     file (ACCESS-06)
/// 14. a REFUSED write also leaves a row, `allowed: false`, with the reason —
///     the relay refusal included
/// 15. composed with no path, every member refuses by name
/// 16. no restart: an accepted write signals nothing (restart-to-apply)
///
/// ## SECURITY FIX 3 — the config blob carries cleartext credentials
///
/// `OpcUAConfig.password` sits inside the config JSON and `ssl_key` is a
/// private key's bytes. A naive `read` would ship them whole to every screen
/// that opens the config page. So: `read`/`previous` replace each secret VALUE
/// with [kSecretPreservedSentinel]; a `write` carrying the sentinel means
/// "keep the stored secret", resolved server-side against the live file, so a
/// read-modify-write round trip cannot blank credentials. Three arms:
///  S1 (arm 3): a read's encoded frame contains no secret literal anywhere
///  S2: a sentinel round trip preserves the stored secret on disk, proven
///      through the non-redacting path (the file itself)
///  S3: an explicit new secret DOES write
/// plus: an unresolvable or ambiguous sentinel refuses by name rather than
/// writing the marker as a literal credential.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/relay/backend_config_store.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The station account a relay session resolves to (D-11's shape: a panel,
/// not a person, verified by the server).
const AccessSession _station = AccessSession(
  user: AuthenticatedUser(
    username: 'ST101-panel',
    roleName: 'Panel Admin',
    stationAccount: true,
  ),
  groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.administer},
);

/// The secret literals the fixture file carries. If either string ever
/// appears in a read's encoded frame, SECURITY FIX 3 has regressed.
const String _storedPassword = 'hunter2-very-secret';
final String _storedKeyB64 =
    base64Encode(utf8.encode('FAKE-OPCUA-PRIVATE-KEY-PEM-BYTES'));

final class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];
  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

void main() {
  late Directory tmp;
  late String path;
  late _RecordingSink sink;
  late int reloads;
  late BackendConfigStore store;

  Map<String, Object?> baseConfig() => {
        'opcua': <Object?>[
          <String, Object?>{
            'endpoint': 'opc.tcp://10.104.29.11:4840',
            'username': 'hmi',
            'password': _storedPassword,
            'ssl_key': _storedKeyB64,
            'server_alias': 'ST101',
          },
          <String, Object?>{
            'endpoint': 'opc.tcp://10.104.29.12:4840',
            'server_alias': 'ST201',
          },
        ],
        'jbtm': <Object?>[],
        'modbus': <Object?>[],
        'relay': {
          'port': 8787,
          'token_file': '/etc/centroid/relay-tokens.json',
        },
      };

  String enc(Map<String, Object?> m) => jsonEncode(m);

  Future<List<int>> fileBytes([String? p]) => File(p ?? path).readAsBytes();

  BackendConfigStore storeOver(String? p) => BackendConfigStore(
        path: p,
        session: () => _station,
        station: 'ST101',
        audit: sink,
        reloadSignal: () => reloads++,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('backend-config-store-');
    path = '${tmp.path}/stateman.json';
    await File(path).writeAsString(enc(baseConfig()));
    sink = _RecordingSink();
    reloads = 0;
    store = storeOver(path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('reading', () {
    test('arm 1: read returns the file including the relay section, '
        'flagged read-only, with hasPrevious false before any write',
        () async {
      final doc = await store.read();
      final decoded = jsonDecode(doc.configJson) as Map<String, dynamic>;
      expect((decoded['relay'] as Map)['port'], 8787,
          reason: 'the relay section must be READABLE — the screen shows it '
              'greyed rather than pretending it does not exist (D-10)');
      expect((decoded['opcua'] as List), hasLength(2));
      expect(doc.readOnlySections, contains('relay'),
          reason: 'the screen greys what the far end will refuse');
      expect(doc.hasPrevious, isFalse);
    });

    test('arm 2: read and write on a missing file refuse by name', () async {
      final absent = '${tmp.path}/absent.json';
      final missing = storeOver(absent);
      await expectLater(
          missing.read(),
          throwsA(predicate((e) =>
              '$e'.contains('BackendConfigStore.read') &&
              '$e'.contains(absent))),
          reason: 'an empty config would render as "no servers configured" '
              'on a screen, next to a plant that has four');
      await expectLater(
          missing.write(enc(baseConfig())),
          throwsA(predicate((e) =>
              '$e'.contains('BackendConfigStore.write') &&
              '$e'.contains(absent))));
    });

    test('arm 3: read redacts secret values behind the sentinel and still '
        'returns paths (SECURITY FIX 3 / S1)', () async {
      final doc = await store.read();
      final frame = jsonEncode(doc.toJson());
      expect(frame, isNot(contains(_storedPassword)),
          reason: 'the OPC UA password must never cross the wire');
      expect(frame, isNot(contains(_storedKeyB64)),
          reason: 'a TLS private key must never cross the wire — paths '
              'cross, bytes do not');
      expect(frame, contains(kSecretPreservedSentinel));
      expect(frame, contains('/etc/centroid/relay-tokens.json'),
          reason: 'the relay section names a token file PATH, not a token, '
              'and the path is returned');
      final decoded = jsonDecode(doc.configJson) as Map<String, dynamic>;
      final first = (decoded['opcua'] as List)[0] as Map;
      final second = (decoded['opcua'] as List)[1] as Map;
      expect(first['password'], kSecretPreservedSentinel);
      expect(first['ssl_key'], kSecretPreservedSentinel);
      expect(second['password'], isNull,
          reason: 'an entry that HOLDS no secret must not gain a sentinel — '
              'a sentinel on write means "keep the stored secret", and there '
              'is nothing stored to keep');
    });
  });

  group('validating and writing', () {
    test('arm 4: validate answers ok / the parser message, and writes nothing',
        () async {
      final before = await fileBytes();

      final ok = await store.validate(enc(baseConfig()));
      expect(ok.ok, isTrue);
      expect(ok.problems, isEmpty);

      final notJson = await store.validate('{"opcua": [');
      expect(notJson.ok, isFalse);
      expect(notJson.problems, isNotEmpty);

      final wrongShape = await store.validate(enc({
        ...baseConfig(),
        'opcua': 'not-a-list',
      }));
      expect(wrongShape.ok, isFalse);
      expect(wrongShape.problems, isNotEmpty,
          reason: 'the parser\'s message names the field; "invalid" is not '
              'an operator-grade answer');

      expect(await fileBytes(), before,
          reason: 'validate must write NOTHING');
      expect(File('$path.previous').existsSync(), isFalse);
    });

    test('arm 5: write of an invalid payload writes nothing — the file is '
        'byte-identical afterwards', () async {
      final before = await fileBytes();
      await expectLater(
          store.write(enc({...baseConfig(), 'opcua': 42})),
          throwsA(anything));
      expect(await fileBytes(), before,
          reason: 'validation before persistence is D-10\'s first hazard, '
              'and the assertion has to be about the FILE');
      expect(File('$path.previous').existsSync(), isFalse);
    });

    test('arm 6: an accepted write replaces the file and leaves the previous '
        'contents at <path>.previous, byte-identical', () async {
      final original = await fileBytes();
      final payload = baseConfig();
      ((payload['opcua'] as List)[1] as Map)['publishing_interval_ms'] = 250;
      final submitted = enc(payload);

      await store.write(submitted, reason: 'slow ST201 down');

      expect(await fileBytes(), utf8.encode(submitted),
          reason: 'the accepted document is what lands, verbatim');
      expect(await fileBytes('$path.previous'), original,
          reason: 'the previous file survives every accepted write');
      expect((await store.read()).hasPrevious, isTrue);
    });

    test('arm 7: one level of undo — a second write overwrites .previous '
        'with the immediately previous contents, not the original', () async {
      final p1 = baseConfig();
      ((p1['opcua'] as List)[1] as Map)['publishing_interval_ms'] = 250;
      final p2 = baseConfig();
      ((p2['opcua'] as List)[1] as Map)['publishing_interval_ms'] = 500;

      await store.write(enc(p1));
      await store.write(enc(p2));

      expect(await fileBytes('$path.previous'), utf8.encode(enc(p1)),
          reason: 'one level, stated: nobody may assume a history');
    });

    test('arm 8: previous returns the kept document (redacted); '
        'restorePrevious swaps it back and keeps the rejected config at '
        '.previous; both refuse by name when nothing was ever written',
        () async {
      // Anti-vacuity first, before any write has happened.
      await expectLater(
          store.previous(),
          throwsA(predicate((e) =>
              '$e'.contains('BackendConfigStore.previous'))),
          reason: 'previous on a file that has never been written refuses by '
              'name rather than returning empty');
      await expectLater(
          store.restorePrevious(),
          throwsA(predicate((e) =>
              '$e'.contains('BackendConfigStore.restorePrevious'))));

      final original = await fileBytes();
      final p1 = baseConfig();
      ((p1['opcua'] as List)[1] as Map)['publishing_interval_ms'] = 250;
      await store.write(enc(p1));

      final prev = await store.previous();
      final prevDecoded = jsonDecode(prev!.configJson) as Map<String, dynamic>;
      expect(((prevDecoded['opcua'] as List)[1] as Map)
              .containsKey('publishing_interval_ms'),
          isFalse,
          reason: 'previous is the ORIGINAL document, before the write');
      expect(((prevDecoded['opcua'] as List)[0] as Map)['password'],
          kSecretPreservedSentinel,
          reason: 'previous is redacted exactly as read is (SECURITY FIX 3)');

      await store.restorePrevious(reason: 'p1 broke the boot');
      expect(await fileBytes(), original,
          reason: 'restore puts the previous document back');
      expect(await fileBytes('$path.previous'), utf8.encode(enc(p1)),
          reason: 'the rejected config stays reachable, so the operator can '
              'go forward again after a failed restart');
    });
  });

  group('the relay section', () {
    test('arm 9: a payload whose relay section differs is refused by name, '
        'and the file is unchanged', () async {
      final before = await fileBytes();
      final payload = baseConfig();
      (payload['relay'] as Map)['port'] = 9999;
      await expectLater(
          store.write(enc(payload)),
          throwsA(predicate((e) =>
              '$e'.contains('relay') &&
              '$e'.contains('socket over the socket'))),
          reason: 'the relay section configures the socket the edit arrives '
              'on; the message says WHY, not merely no');
      expect(await fileBytes(), before);
      expect(sink.rows.last.allowed, isFalse);
    });

    test('arm 10: a payload whose relay section is identical succeeds — '
        'the live control that keeps arm 9 from being a refuse-everything '
        'trap', () async {
      final payload = baseConfig();
      ((payload['opcua'] as List)[1] as Map)['publishing_interval_ms'] = 300;
      await store.write(enc(payload));
      expect(await fileBytes(), utf8.encode(enc(payload)),
          reason: 'a screen round-trips the whole file; refusing every '
              'payload that CONTAINS a relay section would refuse every '
              'write');
    });

    test('arm 11: relay absent-vs-present is a difference, both directions',
        () async {
      // (a) live file HAS a relay section; the payload deletes it.
      final before = await fileBytes();
      final without = baseConfig()..remove('relay');
      await expectLater(
          store.write(enc(without)),
          throwsA(predicate((e) => '$e'.contains('relay'))),
          reason: 'a diff that only compares present-to-present would let a '
              'payload turn the relay off');
      expect(await fileBytes(), before);

      // (b) live file has NO relay section; the payload adds one.
      final bare = '${tmp.path}/bare.json';
      await File(bare).writeAsString(enc(baseConfig()..remove('relay')));
      final bareStore = storeOver(bare);
      final bareBefore = await fileBytes(bare);
      await expectLater(
          bareStore.write(enc(baseConfig())),
          throwsA(predicate((e) => '$e'.contains('relay'))),
          reason: 'turning the relay ON remotely is the same edit in the '
              'other direction');
      expect(await fileBytes(bare), bareBefore);
    });
  });

  group('attribution', () {
    test('arm 12: an accepted write leaves an audit row attributed to the '
        'verified station account', () async {
      await store.write(enc(baseConfig()), reason: 'no-op rewrite');
      final row = sink.rows.singleWhere((r) => r.allowed);
      expect(row.surface, 'config');
      expect(row.itemKey, path);
      expect(row.who, 'ST101-panel');
      expect(row.station, 'ST101');
      expect(row.roleName, 'Panel Admin');
      expect(row.origin, 'relay');
    });

    test('arm 13: a stray top-level "who" key neither names the row nor '
        'reaches the file (ACCESS-06)', () async {
      final payload = baseConfig();
      payload['who'] = 'somebody-else';
      await expectLater(store.write(enc(payload)), throwsA(anything));
      expect(sink.rows, isNotEmpty);
      for (final row in sink.rows) {
        expect(row.who, 'ST101-panel',
            reason: 'recording a client-supplied identity as verified is '
                'worse than recording none');
      }
      expect(await File(path).readAsString(), isNot(contains('somebody-else')),
          reason: 'the stray key must not reach the file either');
    });

    test('arm 14: a refused write also leaves a row, allowed false, with the '
        'refusal reason — the relay refusal included', () async {
      await expectLater(
          store.write(enc({...baseConfig(), 'opcua': 42})),
          throwsA(anything));
      final invalidRow = sink.rows.last;
      expect(invalidRow.allowed, isFalse);
      expect(invalidRow.reason, isNotNull);
      expect(invalidRow.reason, isNotEmpty);

      final payload = baseConfig();
      (payload['relay'] as Map)['port'] = 9999;
      await expectLater(store.write(enc(payload)), throwsA(anything));
      final relayRow = sink.rows.last;
      expect(relayRow.allowed, isFalse);
      expect(relayRow.reason, contains('relay'),
          reason: 'the relay refusal is not a permission refusal and must '
              'still be traceable');
    });
  });

  group('composition', () {
    test('arm 15: composed with no path, every member refuses by name',
        () async {
      final unwired = storeOver(null);
      Matcher named(String member) => throwsA(predicate(
          (e) => '$e'.contains('BackendConfigStore.$member')));
      await expectLater(unwired.read(), named('read'));
      await expectLater(unwired.validate('{}'), named('validate'));
      await expectLater(unwired.write('{}'), named('write'));
      await expectLater(unwired.previous(), named('previous'));
      await expectLater(unwired.restorePrevious(), named('restorePrevious'));
    });

    test('arm 16: no restart — an accepted write signals nothing', () async {
      await store.write(enc(baseConfig()));
      expect(reloads, 0,
          reason: 'restart-to-apply is a decision; a store that quietly '
              'reloaded would be a different, much riskier product');
    });
  });

  group('secrets round trip (SECURITY FIX 3)', () {
    test('S2: a sentinel means "keep the stored secret" — a read-modify-write '
        'round trip cannot blank credentials', () async {
      final doc = await store.read();
      final m = jsonDecode(doc.configJson) as Map<String, dynamic>;
      expect(((m['opcua'] as List)[0] as Map)['password'],
          kSecretPreservedSentinel,
          reason: 'precondition: the round trip really starts from a '
              'redacted document');
      ((m['opcua'] as List)[0] as Map)['publishing_interval_ms'] = 400;

      await store.write(jsonEncode(m.cast<String, Object?>()));

      // The non-redacting internal path: the file itself.
      final raw = await File(path).readAsString();
      expect(raw, contains(_storedPassword),
          reason: 'the stored password survives the round trip');
      expect(raw, contains(_storedKeyB64),
          reason: 'the stored private key survives the round trip');
      expect(raw, isNot(contains(kSecretPreservedSentinel)),
          reason: 'the sentinel is a marker, never a stored value');
      final parsed =
          StateManConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(parsed.opcua.first.password, _storedPassword);
      expect(parsed.opcua.first.publishingIntervalMs, 400,
          reason: 'the benign edit landed alongside the preserved secret');
    });

    test('S3: an explicit new secret DOES write', () async {
      final newKeyB64 = base64Encode(utf8.encode('ROTATED-KEY-BYTES'));
      final payload = baseConfig();
      ((payload['opcua'] as List)[0] as Map)['password'] = 'rotated-pass-123';
      ((payload['opcua'] as List)[0] as Map)['ssl_key'] = newKeyB64;

      await store.write(enc(payload));

      final raw = await File(path).readAsString();
      expect(raw, contains('rotated-pass-123'));
      expect(raw, contains(newKeyB64));
      expect(raw, isNot(contains(_storedPassword)),
          reason: 'a rotation replaces; the sentinel path is the only "keep"');
    });

    test('S4: a sentinel that matches no stored server refuses by name — '
        'the marker must never be written as a literal credential', () async {
      final before = await fileBytes();
      final payload = baseConfig();
      (payload['opcua'] as List).add({
        'endpoint': 'opc.tcp://ghost:4840',
        'password': kSecretPreservedSentinel,
      });
      await expectLater(
          store.write(enc(payload)),
          throwsA(predicate((e) =>
              '$e'.contains('preserved-secret') &&
              '$e'.contains('opc.tcp://ghost:4840'))));
      expect(await fileBytes(), before);
      expect(sink.rows.last.allowed, isFalse);
    });

    test('S5: a sentinel against an ambiguous endpoint refuses by name — '
        'never guess which server\'s credential to attach', () async {
      final twin = '${tmp.path}/twin.json';
      final twinConfig = {
        'opcua': [
          {
            'endpoint': 'opc.tcp://10.104.29.11:4840',
            'password': 'first-secret',
          },
          {
            'endpoint': 'opc.tcp://10.104.29.11:4840',
            'password': 'second-secret',
          },
        ],
        'jbtm': <Object?>[],
        'modbus': <Object?>[],
      };
      await File(twin).writeAsString(jsonEncode(twinConfig));
      final twinStore = storeOver(twin);
      final doc = await twinStore.read();
      final m = jsonDecode(doc.configJson) as Map<String, dynamic>;
      final before = await fileBytes(twin);
      await expectLater(
          twinStore.write(jsonEncode(m.cast<String, Object?>())),
          throwsA(predicate((e) => '$e'.contains('preserved-secret'))));
      expect(await fileBytes(twin), before);
    });
  });
}
