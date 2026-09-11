@TestOn('vm')
@Tags(['ws'])

/// SEC-02 with the root carried as *material* instead of a mounted path.
///
/// The plant asked for one thing to type — `wss://10.50.10.11:9443` — and a
/// `rootCertPath` is the second thing: a filesystem path an operator standing
/// at a panel has no way to answer ("how do I obtain pem path, and what is
/// that"). The material variant lets the app acquire the root over the
/// gateway's trust endpoint, show its fingerprint, and pin the *bytes* in the
/// device-local store — the same shape `OpcUAConfig` already uses for its
/// certificate material.
///
/// **This does not reopen the paths-never-bytes ruling for secrets.** That
/// ruling (OQ4, `TlsConfig` on the server side) exists because a config object
/// that can hold *key* material ends up holding it — in a preferences row, a
/// log line, a crash dump. A CA root certificate is public material: it is
/// literally what the gateway hands anyone who asks. `client_config_test.dart`
/// keeps sweeping this package for `List<int>` fields, and the private key
/// discipline on the server is untouched.
///
/// **The pin must still be a real pin.** The refusal arm below runs a genuine
/// handshake against a leaf minted under a *different* CA — not a mocked
/// verifier — and its live control is a second panel pinned to that foreign
/// root reaching ready against the very same listener. Same fixture, one input
/// varied, which is `tls_client_test.dart`'s whole discipline; the harness
/// here is that file's, reproduced because its helpers are private to it.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';

/// A key `FakeStateMan` seeds at construction, so a subscribe against a real
/// gateway answers with a real snapshot and no plant has to be simulated.
const String _seededKey = 'PIPE.connected';

/// The ceiling on any dial here (trap 17: an unreachable address is 75 s on
/// macOS). A hang guard, never a measurement.
const Duration _dialBudget = Duration(seconds: 10);

/// The budget for "the panel got where it was going".
const Duration _recovery = Duration(seconds: 5);

ClientConfig _config({ClientTlsConfig? tls}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
      connectTimeout: _dialBudget,
      tls: tls,
    );

// ---------------------------------------------------------------------------
// Certificates — `tls_client_test.dart`'s wiring, over the same minter the
// CLI uses. One RSA keypair per purpose per isolate; certificates are free.
// ---------------------------------------------------------------------------

typedef _Ca = ({
  String certPem,
  String keyPem,
  Map<String, String> dn,
  RelayKeyPair keys,
});

({RelayKeyPair ca, RelayKeyPair leaf})? _pairs;

({RelayKeyPair ca, RelayKeyPair leaf}) _keyPairs() =>
    _pairs ??= (ca: generateKeyPair(), leaf: generateKeyPair());

_Ca _mintCaNamed(Map<String, String> dn, RelayKeyPair keys) {
  final now = DateTime.now().toUtc();
  return (
    certPem: mintCertificate(
      signingKey: keys.privateKey,
      issuer: dn,
      subject: dn,
      subjectPublicKey: keys.publicKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 3650)),
      ca: true,
    ),
    keyPem: privateKeyToPem(keys.privateKey),
    dn: dn,
    keys: keys,
  );
}

/// A ten-year private root, the way the plant's is provisioned.
_Ca _mintCa() =>
    _mintCaNamed({'CN': 'Relay Test CA', 'O': 'Centroid'}, _keyPairs().ca);

/// A root the plant-pinned panel does *not* carry — what makes a CA foreign.
_Ca _mintForeignCa() => _mintCaNamed(
    {'CN': 'Someone Else Entirely', 'O': 'Not Centroid'}, _keyPairs().leaf);

String _mintLeaf({required _Ca ca}) {
  final now = DateTime.now().toUtc();
  return mintCertificate(
    signingKey: ca.keys.privateKey,
    issuer: ca.dn,
    subject: {'CN': 'relay-gateway', 'O': 'Centroid'},
    subjectPublicKey: _keyPairs().leaf.publicKey,
    sans: const ['localhost', '127.0.0.1'],
    notBefore: now.subtract(const Duration(days: 1)),
    notAfter: now.add(const Duration(days: 365)),
  );
}

/// Writes the gateway's chain and key into a fresh temp directory — the
/// gateway still mounts files; it is the *panel* that carries material here.
({String chainPath, String keyPath}) _mountGateway({required String chainPem}) {
  final dir = Directory.systemTemp.createTempSync('relay-pem-pin-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final sep = Platform.pathSeparator;
  final chainPath = '${dir.path}${sep}chain.pem';
  final keyPath = '${dir.path}${sep}chain-key.pem';
  File(chainPath).writeAsStringSync(chainPem);
  File(keyPath).writeAsStringSync(privateKeyToPem(_keyPairs().leaf.privateKey));
  return (chainPath: chainPath, keyPath: keyPath);
}

/// A real gateway on an ephemeral port, serving a leaf from [chainPem].
Future<int> _gateway({required String chainPem}) async {
  final mounted = _mountGateway(chainPem: chainPem);
  final served = FakeStateMan();
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: ServerConfig(
      tick: ServerConfig.minTick,
      tls: TlsConfig(chainPath: mounted.chainPath, keyPath: mounted.keyPath),
    ),
    onError: (_, __, ___) {},
  );
  addTearDown(server.close);
  addTearDown(served.dispose);
  await server.start();
  return server.port;
}

/// A panel pointed at [uri], trusting exactly the material it was handed.
///
/// No `dial:` override: what these cases prove is that the production
/// constructor builds its one pinned `HttpClient` out of *bytes* and hands it
/// to the socket, and a harness dial would be a test of the harness.
RemoteStateMan _panel(String uri, {required ClientTlsConfig tls}) {
  final client = RemoteStateMan(
    uri: Uri.parse(uri),
    config: _config(tls: tls),
    keys: const {_seededKey},
  );
  addTearDown(client.dispose);
  return client;
}

/// Polls [done] until it holds or [budget] runs out, failing with [what].
Future<void> _until(String what, bool Function() done,
    {Duration budget = _recovery}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('the material variant is refused when it cannot mean anything', () {
    test('empty material is refused at construction', () {
      expect(
        () => ClientTlsConfig.pem(''),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('rootCertPem'))),
        reason: 'empty material handed to SecurityContext is a context that '
            'trusts nothing, and every handshake then fails with the exact '
            'message a real impostor produces — the panel would report an '
            'attack instead of a missing certificate',
      );
    });

    test('whitespace-only material is refused at construction', () {
      expect(
        () => ClientTlsConfig.pem(' \n\t '),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('rootCertPem'))),
        reason: 'a preferences row that decayed to whitespace must fail at '
            'construction, where the message can name the field, not at the '
            'first dial, where it names nothing',
      );
    });

    test('each variant carries its own source and no phantom of the other',
        () {
      final ca = _mintCa();
      final material = ClientTlsConfig.pem(ca.certPem);
      expect(material.rootCertPem, ca.certPem);
      expect(material.rootCertPath, isNull,
          reason: 'a non-null path beside material would make RemoteStateMan '
              'choose, and the wrong precedence would read a file the '
              'operator never named');

      final byPath = ClientTlsConfig(rootCertPath: '/mnt/pki/ca.pem');
      expect(byPath.rootCertPath, '/mnt/pki/ca.pem');
      expect(byPath.rootCertPem, isNull);
    });

    test('toString never carries the certificate body', () {
      final ca = _mintCa();
      final rendered = ClientTlsConfig.pem(ca.certPem).toString();
      expect(rendered, isNot(contains('BEGIN CERTIFICATE')),
          reason: 'the root is public material, but a config toString that '
              'dumps a 2 kB PEM into every log line and support ticket is '
              'noise that trains people to stop reading configs');
    });

    test('checkDialable treats material exactly as it treats a path', () {
      final ca = _mintCa();
      final config = ClientConfig(tls: ClientTlsConfig.pem(ca.certPem));
      // wss with a pinned root: dialable.
      config.checkDialable(Uri.parse('wss://127.0.0.1:9443/'));
      // A pinned root on a plaintext dial is the same lie whichever way the
      // root arrived: the config reads as encrypted and the traffic is not.
      expect(
        () => config.checkDialable(Uri.parse('ws://127.0.0.1:8080/')),
        throwsA(isA<ArgumentError>()),
        reason: 'material must not slip past the refusal the path variant '
            'already earns — the mistake being refused is about the dial, '
            'not about how the root was provisioned',
      );
    });
  });

  group('a PEM-pinned panel against a real gateway', () {
    test('material pins: the panel reaches ready and holds a snapshot',
        () async {
      final ca = _mintCa();
      final port = await _gateway(chainPem: _mintLeaf(ca: ca));

      final panel = _panel('wss://127.0.0.1:$port',
          tls: ClientTlsConfig.pem(ca.certPem));

      await _until('the material-pinned link to reach ready',
          () => panel.isReady);

      expect(panel.read(_seededKey), isNotNull,
          reason: 'a socket that opened but carries no snapshot is a TLS '
              'listener with no gateway behind it. The whole stack has to '
              'come up over the material pin: handshake, hello, subscribe, '
              'snapshot');
    });

    test(
        'a leaf under a different CA is refused, and the refusal is the pin — '
        'the same listener satisfies a panel pinned to that CA', () async {
      final plant = _mintCa();
      final foreign = _mintForeignCa();
      final port = await _gateway(chainPem: _mintLeaf(ca: foreign));

      // The live control FIRST, against the same listener: a panel pinned to
      // the foreign root completes the whole stack. Whatever the plant-pinned
      // panel reports below, it cannot be blamed on the listener.
      final control = _panel('wss://127.0.0.1:$port',
          tls: ClientTlsConfig.pem(foreign.certPem));
      await _until('the control panel to reach ready', () => control.isReady);

      final panel = _panel('wss://127.0.0.1:$port',
          tls: ClientTlsConfig.pem(plant.certPem));

      await _until(
        'the plant-pinned panel to refuse the foreign certificate',
        () =>
            panel.lastDownReason
                ?.startsWith("the gateway's certificate was not trusted") ??
            false,
      );
      expect(panel.isReady, isFalse,
          reason: 'a panel that reports a certificate refusal and is ready '
              'anyway has two sources of truth, and the screen is reading '
              'the wrong one');
    });
  });
}
