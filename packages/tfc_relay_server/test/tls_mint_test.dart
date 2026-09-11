/// The certificate minter, judged at the DER tag rather than at the text.
///
/// 06-RESEARCH §B.2 measured the reason this code exists at all. `basic_utils`
/// — the library this repo already ships, and the one CONTEXT amendment 5
/// named — encodes *every* subject-alternative name as a dNSName
/// (`X509Utils.dart:480-484`, `ASN1PrintableString(stringValue: s, tag: 0x82)`),
/// so a leaf provisioned for `10.104.29.71` carries the literal DNS *string*
/// "10.104.29.71", and a panel dialling that IP literal is answered
/// `CERTIFICATE_VERIFY_FAILED`. The panels dial IPs — ST101/ST201/ST301 are
/// addresses, not names. So the certificate bytes are ours.
///
/// Every case below reads the DER tag byte and never the rendered text: tag
/// `0x82` carrying the characters `127.0.0.1` is *precisely* what the broken
/// encoding produces, so a string comparison passes on the bug. The hostname
/// case is here so a "cleanup" that unifies the two branches the other way —
/// everything an iPAddress — cannot pass either. Between them the two cases
/// pin the branch, which is the whole of the finding (trap 12).
///
/// Without this file, the next person who tidies `_generalName` ships a leaf
/// that works on their laptop (`wss://localhost`) and fails on every panel in
/// the plant, with an error message identical to a wrong CA and to an expired
/// certificate (trap 16).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/asn1.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_server/src/tls/mint.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart' as barrel;

import 'support/certs.dart';

/// `id-ce-keyUsage`, `id-ce-basicConstraints`, `id-ce-subjectAltName`,
/// `id-ce-extKeyUsage` — spelled as the numbers a DER dump shows, because a
/// symbolic name resolved through the same library that writes the extension
/// would agree with any mistake it made.
const _keyUsage = '2.5.29.15';
const _basicConstraints = '2.5.29.19';
const _subjectAltName = '2.5.29.17';
const _extKeyUsage = '2.5.29.37';
const _subjectKeyId = '2.5.29.14';
const _authorityKeyId = '2.5.29.35';

/// The tbsCertificate of [pem], parsed.
ASN1Sequence _tbsOf(String pem) {
  final der = CryptoUtils.getBytesFromPEMString(pem);
  final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
  return cert.elements!.first as ASN1Sequence;
}

/// The DER value octets of the extension carrying [oid], or `null` when the
/// certificate does not carry that extension at all.
Uint8List? _extensionOctets(String pem, String oid) {
  final tagged = _tbsOf(pem).elements!.where((e) => e.tag == 0xA3);
  if (tagged.isEmpty) return null;
  final exts = ASN1Parser(tagged.first.valueBytes).nextObject() as ASN1Sequence;
  for (final ext in exts.elements!.cast<ASN1Sequence>()) {
    final id = ext.elements!.first as ASN1ObjectIdentifier;
    if (id.objectIdentifierAsString == oid) {
      return (ext.elements!.last as ASN1OctetString).octets;
    }
  }
  return null;
}

/// The GeneralName entries of the subjectAltName extension, untouched: the
/// tag byte as written and the value octets as written.
List<({int tag, Uint8List value})> _subjectAltNames(String pem) {
  final octets = _extensionOctets(pem, _subjectAltName);
  if (octets == null) return const [];
  final names = ASN1Parser(octets).nextObject() as ASN1Sequence;
  return [
    for (final n in names.elements!) (tag: n.tag!, value: n.valueBytes!),
  ];
}

/// The 20 bytes of `subjectKeyIdentifier`, which is a bare OCTET STRING.
Uint8List? _subjectKeyIdOf(String pem) {
  final octets = _extensionOctets(pem, _subjectKeyId);
  if (octets == null) return null;
  return (ASN1Parser(octets).nextObject() as ASN1OctetString).octets;
}

/// The `keyIdentifier` field of `authorityKeyIdentifier`, which is `[0]
/// IMPLICIT` inside a SEQUENCE — so the bytes are the context-tagged object's
/// value, not an OCTET STRING's contents.
Uint8List? _authorityKeyIdOf(String pem) {
  final octets = _extensionOctets(pem, _authorityKeyId);
  if (octets == null) return null;
  final seq = ASN1Parser(octets).nextObject() as ASN1Sequence;
  return seq.elements!.first.valueBytes;
}

/// The serial number as the certificate carries it.
BigInt _serialOf(String pem) =>
    (_tbsOf(pem).elements![1] as ASN1Integer).integer!;

/// The issuer distinguished name, rendered the way a DER dump renders it.
String _issuerOf(String pem) {
  final parsed = X509Utils.x509CertificateFromPem(pem);
  return parsed.tbsCertificate!.issuer.values.join('/');
}

/// The repository root, found by walking up from wherever `dart test` was
/// invoked. `.git` is a **file** inside a worktree and a directory in the main
/// checkout, so both count — this repository's agents run in worktrees.
Directory _repositoryRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    final isRoot = Directory('${dir.path}/packages').existsSync() &&
        (Directory('${dir.path}/.git').existsSync() ||
            File('${dir.path}/.git').existsSync());
    if (isRoot) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('no repository root above ${Directory.current.path} — this sweep '
          'is scanning nothing and would pass on an empty answer');
    }
    dir = parent;
  }
}

/// Every `.pem` committed anywhere under `packages/`, ignoring build output.
List<String> _pemFilesInRepository() {
  final found = <String>[];
  void walk(Directory dir) {
    for (final entry in dir.listSync(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (entry is Directory) {
        if (name == '.dart_tool' || name == '.git' || name == 'build') continue;
        walk(entry);
      } else if (entry is File && name.endsWith('.pem')) {
        found.add(entry.path);
      }
    }
  }

  walk(Directory('${_repositoryRoot().path}/packages'));
  return found;
}

void main() {
  late RelayKeyPair caKeys;
  late RelayKeyPair leafKeys;
  late DateTime now;
  const caDn = {'CN': 'Relay Test CA', 'O': 'Centroid'};
  const leafDn = {'CN': 'relay-gateway', 'O': 'Centroid'};

  // ~180 ms apiece (06-RESEARCH §B.3), which is why the keys are generated
  // once for the file and every case mints from them at ~15 ms.
  setUpAll(() {
    caKeys = generateKeyPair();
    leafKeys = generateKeyPair();
    now = DateTime.now().toUtc();
  });

  String mintLeafWith({
    List<String> sans = const ['localhost', '127.0.0.1'],
    BigInt? serial,
  }) =>
      mintCertificate(
        signingKey: caKeys.privateKey,
        issuer: caDn,
        subject: leafDn,
        subjectPublicKey: leafKeys.publicKey,
        sans: sans,
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: now.add(const Duration(days: 365)),
        serial: serial,
      );

  String mintRoot() => mintCertificate(
        signingKey: caKeys.privateKey,
        issuer: caDn,
        subject: caDn,
        subjectPublicKey: caKeys.publicKey,
        sans: const [],
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: now.add(const Duration(days: 3650)),
        ca: true,
      );

  group('subject-alternative names', () {
    test('an IP subject-alternative name is an iPAddress, not a DNS string',
        () {
      final sans = _subjectAltNames(mintLeafWith(sans: const ['127.0.0.1']));

      expect(sans, hasLength(1));
      expect(sans.single.tag, 0x87,
          reason: 'a panel dialling wss://10.104.x.x is answered '
              'CERTIFICATE_VERIFY_FAILED unless the address is a real '
              'iPAddress GeneralName; tag 0x82 here is the basic_utils defect '
              'shipped verbatim');
      expect(sans.single.value, Uint8List.fromList([127, 0, 0, 1]),
          reason: 'an iPAddress carries the four raw address octets — the '
              'ASCII text "127.0.0.1" is exactly what the broken encoding '
              'writes, so it must not be what passes here');
    });

    test('a hostname subject-alternative name is a dNSName', () {
      final sans = _subjectAltNames(mintLeafWith(sans: const ['localhost']));

      expect(sans, hasLength(1));
      expect(sans.single.tag, 0x82,
          reason: 'unifying the two GeneralName branches into iPAddress would '
              'fix the IP dial and break every hostname dial — a developer '
              'laptop on wss://localhost stops connecting');
      expect(ascii.decode(sans.single.value), 'localhost');
    });

    test('a leaf carries both name kinds in the order asked for', () {
      final sans = _subjectAltNames(
          mintLeafWith(sans: const ['localhost', '127.0.0.1', '10.104.29.71']));

      expect(sans.map((s) => s.tag), [0x82, 0x87, 0x87],
          reason: 'one leaf serves the developer by name and the plant by '
              'address; a minter that can only do one of them means two '
              'certificates to keep in step');
      expect(sans[2].value, Uint8List.fromList([10, 104, 29, 71]));
    });
  });

  group('serial numbers', () {
    test('two leaves from one CA never share a serial', () {
      final first = _serialOf(mintLeafWith());
      final second = _serialOf(mintLeafWith());

      expect(first, isNot(second),
          reason: 'two certificates from one issuer sharing a serial is a '
              'chain-building failure — a verifier is entitled to treat the '
              'second as the first, and one leaf on a test bench never shows '
              'it');
      expect(first > BigInt.zero, isTrue,
          reason: 'a negative or zero serial is malformed; some stacks refuse '
              'the certificate outright');
      expect(first < (BigInt.one << 64), isTrue,
          reason: 'the serial stays inside 64 bits, so a DER dump on a plant '
              'machine is readable rather than a 40-digit wall');
    });

    test('an explicit serial is what the certificate carries', () {
      final wanted = BigInt.from(0x0DEFACED);

      expect(_serialOf(mintLeafWith(serial: wanted)), wanted,
          reason: 'an integrator re-issuing a leaf must be able to pin the '
              'serial their CRL or inventory already names');
    });
  });

  group('extensions', () {
    test('the root declares CA:TRUE and a leaf does not', () {
      final rootOctets = _extensionOctets(mintRoot(), _basicConstraints);
      final leafOctets = _extensionOctets(mintLeafWith(), _basicConstraints);

      final root = ASN1Parser(rootOctets).nextObject() as ASN1Sequence;
      expect((root.elements!.first as ASN1Boolean).boolValue, isTrue,
          reason: 'without CA:TRUE on the root no chain builds and every '
              'panel refuses the gateway');

      if (leafOctets != null) {
        final leaf = ASN1Parser(leafOctets).nextObject() as ASN1Sequence;
        final asserted = leaf.elements!.isEmpty
            ? false
            : (leaf.elements!.first as ASN1Boolean).boolValue;
        expect(asserted, isFalse,
            reason: 'a leaf that asserts CA:TRUE can sign for any name in the '
                'plant — the gateway key becomes a second certificate '
                'authority nobody provisioned');
      }
    });

    test('a leaf declares extendedKeyUsage serverAuth', () {
      final octets = _extensionOctets(mintLeafWith(), _extKeyUsage);
      expect(octets, isNotNull,
          reason: 'BoringSSL does not check EKU here today, and "it did not '
              'check today" is not a property to build a plant on — every '
              'other TLS stack on site expects it (§B.1)');

      final eku = ASN1Parser(octets).nextObject() as ASN1Sequence;
      expect(
          eku.elements!
              .cast<ASN1ObjectIdentifier>()
              .map((o) => o.objectIdentifierAsString),
          contains('1.3.6.1.5.5.7.3.1'));
    });

    test('both the root and a leaf declare a keyUsage', () {
      for (final entry in {'root': mintRoot(), 'leaf': mintLeafWith()}.entries) {
        final octets = _extensionOctets(entry.value, _keyUsage);
        expect(octets, isNotNull,
            reason: 'the ${entry.key} without keyUsage is a certificate a '
                'stricter stack than BoringSSL may refuse, and the plant runs '
                'more than one stack');
        final bits = ASN1Parser(octets).nextObject() as ASN1BitString;
        expect(bits.stringValues, isNotEmpty);
      }
    });

    test('the leaf names the key that signed it, and the root names its own',
        () {
      final root = mintRoot();
      final leaf = mintLeafWith();

      expect(_subjectKeyIdOf(root), hasLength(20),
          reason: 'RFC 5280 asks a conforming CA for a subjectKeyIdentifier so '
              'that path construction is possible. SHA-1 of the subject public '
              'key bit string is the convention every other stack writes, and '
              'twenty bytes is what that is');
      expect(_authorityKeyIdOf(leaf), _subjectKeyIdOf(root),
          reason: 'this is the whole value of the pair: at a CA rollover two '
              'roots with the same subject name exist at once, and a verifier '
              'holding both has to try them in turn unless the leaf says which '
              'key signed it. That is a long way from anyone who remembers '
              'this file');
      expect(_subjectKeyIdOf(leaf), isNot(_subjectKeyIdOf(root)),
          reason: 'the leaf identifies its own key, not the issuer\'s — an '
              'SKI copied from the issuer would make the leaf look like the '
              'root to a verifier matching on the identifier');
      expect(_authorityKeyIdOf(root), _subjectKeyIdOf(root),
          reason: 'a self-signed root signed itself, so its authority is its '
              'own key');
    });
  });

  group('round trip', () {
    test('a minted leaf parses back with the validity it was asked for', () {
      final wanted = DateTime.utc(now.year + 1, now.month, now.day, 11, 22, 33);
      final pem = mintCertificate(
        signingKey: caKeys.privateKey,
        issuer: caDn,
        subject: leafDn,
        subjectPublicKey: leafKeys.publicKey,
        sans: const ['localhost'],
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: wanted,
      );

      // `validity` is non-nullable while `tbsCertificate` is nullable, and the
      // SAN accessor beside it is misspelled `subjectAlternativNames` upstream
      // (trap 14) — read the field that is spelled right.
      final parsed = X509Utils.x509CertificateFromPem(pem);
      expect(parsed.tbsCertificate!.validity.notAfter.toUtc(), wanted,
          reason: 'the cert-expiry health key counts days from this field; if '
              'the minter rounds it, the 30-day alarm fires on the wrong '
              'Tuesday');
    });

    test('the barrel exports the minting helper', () {
      expect(barrel.mintCertificate, isA<Function>(),
          reason: 'provisioning is something an embedder does, and 06-05 mints '
              'client-side fixtures against this same function rather than '
              "reaching into another package's src/");
      expect(barrel.generateKeyPair, isA<Function>());
    });
  });

  // The fixture every later TLS plan mints from. It is tested here rather than
  // trusted, because 06-03, 06-05, 06-07 and 06-09 all bind or dial against
  // whatever it produces: a fixture that quietly mints a hostname-only leaf
  // would make four plans' rejection arms pass for the wrong reason.
  group('the certificate fixture', () {
    test('certKeyPairs generates once and hands the same pair back', () {
      final first = certKeyPairs();
      final second = certKeyPairs();

      expect(identical(first.ca, second.ca), isTrue,
          reason: 'an RSA-2048 keypair costs 158-201 ms here and closer to a '
              'second on the Windows runner; regenerating per case turns a '
              'TLS suite into the slowest lane in CI');
      expect(identical(first.leaf, second.leaf), isTrue);
      expect(first.ca.privateKey.modulus, isNot(first.leaf.privateKey.modulus),
          reason: 'the CA and the leaf must not share a key — a leaf holding '
              'the signing key is the CA, whatever its basicConstraints say');
    });

    test('mintLeaf defaults to a hostname and an IP subject-alternative name',
        () {
      final sans = _subjectAltNames(mintLeaf(ca: mintCa()));

      expect(sans.map((s) => s.tag), [0x82, 0x87],
          reason: "06-07's proxy is dialled at 127.0.0.1:<proxy port>, so the "
              'IP SAN in the default is load-bearing, not decoration — '
              'without it every fault-harness leg fails the handshake instead '
              'of the fault it was written for');
      expect(sans.last.value, Uint8List.fromList([127, 0, 0, 1]));
    });

    test('a foreign CA signs a leaf no pinned client should accept', () {
      final trusted = mintCa();
      final foreign = mintForeignCa();
      final foreignLeaf = mintLeaf(ca: foreign);

      expect(_issuerOf(foreignLeaf), isNot(_issuerOf(mintLeaf(ca: trusted))),
          reason: "the rejection arms in 06-03 and 06-05 prove a client "
              'refuses a leaf from another authority; if the two roots were '
              'the same authority those arms would pass while pinning was '
              'switched off entirely');
      expect(foreign.keyPem, isNot(trusted.keyPem),
          reason: 'a foreign CA that shares the trusted key is not foreign');
    });

    test('a near-expiry leaf is a notAfter argument, not a second keygen', () {
      final before = certKeyPairs();
      final pem = mintLeaf(
        ca: mintCa(),
        notAfter: DateTime.now().toUtc().add(const Duration(days: 17)),
      );

      final notAfter =
          X509Utils.x509CertificateFromPem(pem).tbsCertificate!.validity.notAfter;
      expect(notAfter.difference(DateTime.now()).inDays, inInclusiveRange(16, 17),
          reason: "SEC-04's 30-day alarm is verified against a certificate "
              'like this one; a fixture that cannot express "expires soon" '
              'means the alarm ships untested');
      expect(identical(certKeyPairs().leaf, before.leaf), isTrue,
          reason: 'expressing a different validity must not cost another '
              'keypair — that is the whole reason the two are separate calls');
    });

    test('writeCertFixture releases its directory when the case ends', () {
      var directory = '';
      // Registered BEFORE the fixture on purpose: teardowns run last-in
      // first-out, so this one runs *after* the recursive delete the fixture
      // registers at acquisition. Registered after, it would run first and
      // assert against a directory nobody had removed yet.
      addTearDown(() {
        expect(Directory(directory).existsSync(), isFalse,
            reason: 'a fixture that leaves its temp directory behind leaks a '
                'private key PEM onto the machine and, over a full suite, '
                'enough descriptors to make an unrelated case fail');
      });

      final ca = mintCa();
      final paths = writeCertFixture(
        chainPem: mintLeaf(ca: ca),
        keyPem: leafKeyPem(),
        rootPem: ca.certPem,
      );
      directory = paths.directory;

      expect(File(paths.chainPath).existsSync(), isTrue);
      expect(File(paths.keyPath).existsSync(), isTrue);
      expect(File(paths.rootPath!).existsSync(), isTrue);
      expect(paths.directory.startsWith(_repositoryRoot().path), isFalse,
          reason: 'fixtures are written to the system temp directory, not '
              'into the checkout, so a crashed run cannot leave key material '
              'where `git add` will find it');
    });

    test('the suite mints its own certificates and commits none', () {
      // The fixture is exercised first so this is not a case that passes
      // because nothing ever minted anything.
      final ca = mintCa();
      expect(mintLeaf(ca: ca), startsWith('-----BEGIN CERTIFICATE-----'));

      expect(_pemFilesInRepository(), isEmpty,
          reason: 'a committed certificate rots on a schedule nobody watches: '
              'the day it expires, every relay test fails at the handshake '
              'with an error indistinguishable from a wrong CA, and the fix '
              'is a commit rather than a rerun');
    });
  });
}
