/// A private CA and a server leaf, minted in pure Dart.
///
/// SEC-01 asks for tooling that produces a CA root and a gateway leaf. There
/// were three ways to get one (06-RESEARCH §B.2, all three executed):
///
///  1. `X509Utils.generateSelfSignedCertificate`, the route CONTEXT amendment
///     5 named and `packages/tfc_dart/bin/generate_certs.dart` already uses.
///     **Disproved.** `basic_utils` encodes every subject-alternative name as
///     a dNSName — `X509Utils.dart:480-484` is literally
///     `ASN1PrintableString(stringValue: s, tag: 0x82)`, with no parameter to
///     change it — so `10.104.29.71` goes in as the DNS *string*
///     `"10.104.29.71"`. Measured: such a leaf connects when dialled by name
///     and is refused with `CERTIFICATE_VERIFY_FAILED` when dialled by IP
///     literal. The panels dial IPs; ST101/ST201/ST301 are addresses. Latest
///     release is 5.8.2 (2025-02-23), so the defect is unfixed upstream.
///  2. Shell out to `openssl`. Works, and stays a fine provisioning story on
///     a workstation — but `relay-packages-test` runs on `windows-latest`,
///     and a test that needs `openssl` on `PATH` is a lane that goes red for
///     a reason unrelated to this code.
///  3. This file: ~100 lines of `package:pointycastle` ASN.1 with one
///     corrected `GeneralName` encoder. `pointycastle` is `basic_utils`' own
///     and only dependency, so nothing new enters the solve — a transitive
///     edge became direct. `basic_utils` stays, for RSA keygen and PEM
///     encode/parse only, which is the part it gets right.
///
/// `bin/relay_certs.dart` is a shell over these two functions and the tests
/// mint through them too, so the fixtures prove the tool rather than
/// resembling it. A second minting path would be a second place the `0x87`
/// fix has to be remembered.
///
/// Without this file the plant has no certificates at all, and with a
/// "simplified" [_generalName] it has certificates that work on a developer's
/// `wss://localhost` and fail on every panel — with an error message
/// indistinguishable from a wrong CA and from an expired leaf (trap 16).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// Narrowed to three names on purpose. `basic_utils` re-exports the whole of
// `pointycastle`, and an unrestricted import would let this file reach the
// certificate builders through it — which is the thing the library doc says
// this package does not do.
//
// The ASN.1 below is `package:pointycastle`'s, which is what `basic_utils`
// itself is built on. It is NOT `package:asn1lib`: the two libraries carry the
// same class names and incompatible APIs (`ASN1BitString(stringValues:)`
// versus positional, a `valueBytes` setter present versus absent), so a
// well-meant import swap costs a full compile-error round to discover
// (06-RESEARCH trap 13).
import 'package:basic_utils/basic_utils.dart'
    show CryptoUtils, StringUtils, X509Utils;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart'
    show
        PrivateKeyParameter,
        RSAPrivateKey,
        RSAPublicKey,
        RSASignature,
        SHA1Digest,
        Signer;

export 'package:pointycastle/export.dart' show RSAPrivateKey, RSAPublicKey;

/// One RSA keypair, named rather than positional.
///
/// `CryptoUtils.generateRSAKeyPair` hands back an
/// `AsymmetricKeyPair<PublicKey, PrivateKey>` whose halves have to be cast at
/// every call site; casting once, here, is the difference between a caller
/// reading `caKeys.privateKey` and a caller reading
/// `pair.privateKey as RSAPrivateKey`.
typedef RelayKeyPair = ({RSAPublicKey publicKey, RSAPrivateKey privateKey});

/// A fresh RSA keypair, 2048 bits unless [keySize] says otherwise.
///
/// Separate from [mintCertificate] on purpose: this costs 158–201 ms on a Mac
/// and closer to a second on a Windows runner (06-RESEARCH §B.3), while a
/// certificate signed from an existing pair costs ~15 ms. A suite hoists this
/// into a `setUpAll` and then mints as many certificates as its cases need.
///
/// RSA and not ECDSA. A P-256 pair generates in about a millisecond and the
/// temptation is obvious, but dart:io's acceptance of an EC leaf on this path
/// is **not measured** (06-RESEARCH A9), and the certificate that every panel
/// in a fish factory trusts is not the place to find out.
///
/// **Size is a parameter because lifetime is.** 2048 is the default and is
/// right for the leaf: NIST SP 800-57 puts it at acceptable-through-2030 and
/// the leaf is re-issued yearly. The root is not — it is provisioned once for
/// ten years to every panel in the plant, which is the same argument
/// [_extensions] already makes about the EKU decision ("narrowing it is a
/// decision that cannot be revisited without a site visit to every panel"),
/// applied to a parameter where it had not been. `relay_certs --ca` therefore
/// asks for 4096, at a measured one-off cost of ~0.8 s at provisioning time
/// and nothing at all afterwards. The fixtures keep the default.
RelayKeyPair generateKeyPair({int keySize = 2048}) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: keySize);
  return (
    publicKey: pair.publicKey as RSAPublicKey,
    privateKey: pair.privateKey as RSAPrivateKey,
  );
}

/// The PKCS#1 PEM for [key], as `SecurityContext.usePrivateKey` reads it.
///
/// Here rather than at the call sites so `basic_utils` is imported by exactly
/// one file in this package: if it goes unmaintained (18 months since its last
/// release), the replacement is ~40 lines in this library and nothing else
/// moves.
String privateKeyToPem(RSAPrivateKey key) =>
    CryptoUtils.encodeRSAPrivateKeyToPem(key);

/// The RSA private key in [pem] — how `relay_certs --leaf` picks up the CA key
/// an integrator points it at.
RSAPrivateKey privateKeyFromPem(String pem) =>
    CryptoUtils.rsaPrivateKeyFromPem(pem);

/// The subject name of the certificate in [pem], keyed by dotted OID and in
/// the order the certificate carries it.
///
/// This is how a leaf gets an issuer name that is *byte-identical* to its CA's
/// subject name: a verifier matches the two on their DER bytes, so a name
/// rebuilt from readable labels — or in a different order — reads the same in
/// a dump and builds no chain. [mintCertificate] therefore accepts dotted-OID
/// keys as well as labels like `CN`.
Map<String, String> subjectNameFromPem(String pem) =>
    X509Utils.x509CertificateFromPem(pem)
        .tbsCertificate!
        .subject
        .map((oid, value) => MapEntry(oid, value ?? ''));

/// The DER tag of an `ASN1PrintableString` — the one string type
/// [_distinguishedName] can write.
const int printableStringTag = 0x13;

/// Which ASN.1 string type each attribute of the subject name in [pem] is
/// written as, keyed by dotted OID.
///
/// The companion [subjectNameFromPem] cannot answer this: it returns text, and
/// [_distinguishedName] then re-encodes every value as an
/// `ASN1PrintableString`. The round trip therefore preserves the *characters*
/// and not the *encoding*, while a verifier matches issuer to subject on DER
/// bytes. `openssl`'s default for `CN` is `UTF8String`, so a CA root produced
/// by anything but this tool yields a leaf whose issuer name does not match
/// the root's subject name — no chain builds, and every panel reports
/// `CERTIFICATE_VERIFY_FAILED`, which is byte-identical to what a wrong CA and
/// an expired leaf produce (trap 16).
///
/// `relay_certs --leaf` reads this and refuses rather than minting a leaf that
/// chains to nothing. (Copying the issuer's DER through verbatim would *fix*
/// the foreign-CA case instead of reporting it, and is the shape to reach for
/// if the plant ever needs a root minted elsewhere; it is a bigger change than
/// this phase should make on the certificate path.)
Map<String, int> subjectNameTagsFromPem(String pem) {
  final cert =
      ASN1Parser(CryptoUtils.getBytesFromPEMString(pem)).nextObject()
          as ASN1Sequence;
  final tbs = cert.elements!.first as ASN1Sequence;
  // `[0] version` is `EXPLICIT ... OPTIONAL`, so a v1 certificate puts the
  // subject one slot earlier. Everything this tool mints is v3.
  final subject =
      tbs.elements![tbs.elements!.first.tag == 0xA0 ? 5 : 4] as ASN1Sequence;
  return {
    for (final rdn in subject.elements!.cast<ASN1Set>())
      for (final atv in rdn.elements!.cast<ASN1Sequence>())
        (atv.elements!.first as ASN1ObjectIdentifier)
            .objectIdentifierAsString!: atv.elements![1].tag!,
  };
}

/// A signed X.509 certificate, as a PEM string.
///
/// Pass [ca] `true` for a root — it is what puts `basicConstraints: CA:TRUE`
/// in, and without it no chain builds. A leaf gets `CA:FALSE` (encoded as DER
/// requires, by omitting the default) plus `extendedKeyUsage: serverAuth`.
///
/// [serial] may be given when an integrator is re-issuing against a serial
/// their inventory already names; omitted, a random 63-bit positive integer is
/// used. Never a counter: two certificates from one issuer sharing a serial is
/// a chain-building failure, and a verifier is entitled to treat the second as
/// the first.
String mintCertificate({
  required RSAPrivateKey signingKey,
  required Map<String, String> issuer,
  required Map<String, String> subject,
  required RSAPublicKey subjectPublicKey,
  List<String> sans = const [],
  required DateTime notBefore,
  required DateTime notAfter,
  BigInt? serial,
  bool ca = false,
}) {
  final sigAlg = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromName('sha256WithRSAEncryption'))
    ..add(ASN1Null());

  final tbs = ASN1Sequence()
    // [0] version, explicit: 2 means v3, which is what makes the extensions
    // below legal at all. A v1 certificate with an extensions block is not a
    // certificate with extensions, it is a parse error.
    ..add(ASN1Object(tag: 0xA0)..valueBytes = ASN1Integer.fromtInt(2).encode())
    ..add(ASN1Integer(serial ?? _randomSerial()))
    ..add(sigAlg)
    ..add(_distinguishedName(issuer))
    ..add(ASN1Sequence()
      ..add(_time(notBefore))
      ..add(_time(notAfter)))
    ..add(_distinguishedName(subject))
    ..add(_publicKeyBlock(subjectPublicKey))
    ..add(ASN1Object(tag: 0xA3)
      ..valueBytes = _extensions(
        sans: sans,
        ca: ca,
        subjectKeyId: _keyIdentifier(subjectPublicKey),
        // Derived from the signing key rather than passed in: the issuer's
        // public key *is* the public half of the key doing the signing, and
        // an extra parameter would be a second thing a caller can get wrong
        // in a way no test would notice until a rollover. `publicExponent` is
        // computed from p, q and d by `RSAPrivateKey`'s constructor, so it is
        // there whatever route the key arrived by.
        authorityKeyId: _keyIdentifier(RSAPublicKey(
            signingKey.modulus!, signingKey.publicExponent!)),
      ).encode());

  final outer = ASN1Sequence()
    ..add(tbs)
    ..add(sigAlg)
    ..add(ASN1BitString(stringValues: _sign(tbs.encode(), signingKey)));

  final body = StringUtils.chunk(base64.encode(outer.encode()), 64).join('\n');
  return '-----BEGIN CERTIFICATE-----\n$body\n-----END CERTIFICATE-----';
}

/// One `GeneralName`, and the entire finding of 06-RESEARCH §B.
///
/// **Do not unify these two branches.** They look like one function with a
/// redundant test and they are not: a dNSName is tag `0x82` and carries text,
/// an iPAddress is tag `0x87` and carries the raw address octets. Collapsing
/// them into the dNSName form is exactly the `basic_utils` defect, and it is
/// invisible from a laptop — `wss://localhost` keeps working while every panel
/// dialling `wss://10.104.x.x` is refused. Collapsing them the other way
/// breaks the developer dial instead. `tls_mint_test.dart` asserts the tag
/// byte on both branches for that reason.
ASN1Object _generalName(String name) {
  final ip = InternetAddress.tryParse(name);
  if (ip != null) {
    return ASN1Object(tag: 0x87)
      ..valueBytes = Uint8List.fromList(ip.rawAddress);
  }
  return ASN1IA5String(stringValue: name, tag: 0x82);
}

/// The v3 extension block.
ASN1Sequence _extensions({
  required List<String> sans,
  required bool ca,
  required Uint8List subjectKeyId,
  required Uint8List authorityKeyId,
}) {
  final exts = ASN1Sequence();

  if (sans.isNotEmpty) {
    final names = ASN1Sequence();
    for (final s in sans) {
      names.add(_generalName(s));
    }
    exts.add(_extension('2.5.29.17', names.encode()));
  }

  // basicConstraints, critical on both. On a leaf the `cA` field is absent,
  // which DER spells "the default", which is FALSE — and a leaf that asserted
  // CA:TRUE would be a second certificate authority nobody provisioned,
  // holding a key that lives on the gateway rather than in a safe.
  final constraints = ASN1Sequence();
  if (ca) constraints.add(ASN1Boolean(true));
  exts.add(_extension('2.5.29.19', constraints.encode(), critical: true));

  // keyUsage, critical. BoringSSL did not check this in the probe (§B.1) and
  // "it did not check today" is not a property to build a plant on: the site
  // runs more than one TLS stack, and the OPC UA side is stricter.
  //   root: digitalSignature | keyCertSign | cRLSign  -> bits 0, 5, 6
  //   leaf: digitalSignature | keyEncipherment        -> bits 0, 2
  exts.add(_extension(
    '2.5.29.15',
    (ASN1BitString(stringValues: [ca ? 0x86 : 0xA0])
          ..unusedbits = ca ? 1 : 5)
        .encode(),
    critical: true,
  ));

  if (!ca) {
    // extendedKeyUsage: serverAuth, on the leaf only. Deliberately not on the
    // root: an EKU on a CA narrows the whole chain under the nesting rules
    // some verifiers apply, and the root is provisioned once for ten years —
    // narrowing it is a decision that cannot be revisited without a site
    // visit to every panel.
    final eku = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromIdentifierString('1.3.6.1.5.5.7.3.1'));
    exts.add(_extension('2.5.29.37', eku.encode()));
  }

  // subjectKeyIdentifier and authorityKeyIdentifier. RFC 5280 asks conforming
  // CAs for both so that path construction is possible, and nothing here needs
  // them today — the chain is one hop and dart:io builds it. They matter at
  // the *rollover*: two roots with the same subject name exist at once by
  // design during one, and a verifier holding both has to try each in turn
  // unless the leaf names the key that signed it. That moment is ten years
  // from the provisioning visit and a long way from anyone who remembers this
  // file, which is the argument for writing them now.
  exts.add(_extension('2.5.29.14', ASN1OctetString(octets: subjectKeyId)
      .encode()));
  exts.add(_extension(
      '2.5.29.35',
      // `keyIdentifier [0] IMPLICIT OCTET STRING` — implicit, so the context
      // tag *replaces* the OCTET STRING's, and a nested 0x04 here would be
      // twenty bytes of payload nobody can match.
      (ASN1Sequence()..add(ASN1Object(tag: 0x80)..valueBytes = authorityKeyId))
          .encode()));

  return exts;
}

/// RFC 5280's method-1 key identifier: SHA-1 over the `subjectPublicKey` BIT
/// STRING's contents, excluding the tag, the length and the unused-bits octet.
///
/// SHA-1, and deliberately: this is a name, not a signature. Every stack that
/// reads the field computes it this way, and an identifier that disagreed with
/// theirs would be worse than no identifier — it would name a key nobody can
/// find.
Uint8List _keyIdentifier(RSAPublicKey key) =>
    SHA1Digest().process(_rsaPublicKeyDer(key));

/// `Extension ::= SEQUENCE { extnID, critical DEFAULT FALSE, extnValue }`.
ASN1Sequence _extension(String oid, Uint8List value, {bool critical = false}) {
  final ext = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromIdentifierString(oid));
  // DER forbids encoding a field that equals its default, so `critical FALSE`
  // is an absent field, not a `false`.
  if (critical) ext.add(ASN1Boolean(true));
  return ext..add(ASN1OctetString(octets: value));
}

/// `Time ::= CHOICE { utcTime, generalTime }`.
///
/// UTCTime writes a two-digit year, so 2050 encodes identically to 1950 —
/// a ten-year root minted in 2041 would come back already expired, and the
/// error a panel reports for that is the same string it reports for a wrong
/// CA. RFC 5280 draws the line at 2050; so does this.
ASN1Object _time(DateTime t) {
  final utc = t.toUtc();
  return utc.year < 2050 ? ASN1UtcTime(utc) : ASN1GeneralizedTime(utc);
}

/// A random positive 63-bit serial.
///
/// 63 rather than 64 bits so the high bit is clear: a DER INTEGER is two's
/// complement, and a value with bit 63 set needs a leading zero octet to stay
/// positive. Staying under it keeps the encoding — and a hex dump read on a
/// plant machine — boring.
BigInt _randomSerial() {
  final rng = Random.secure();
  var serial = BigInt.zero;
  for (var i = 0; i < 8; i++) {
    serial = (serial << 8) | BigInt.from(rng.nextInt(256));
  }
  serial &= (BigInt.one << 63) - BigInt.one;
  return serial.sign == 0 ? BigInt.one : serial;
}

/// `Name ::= RDNSequence` — one single-valued RDN per entry, in the order
/// given, because a DN is an ordered thing and re-ordering it changes it.
///
/// A key is either a label (`CN`, `O`) or a dotted OID (`2.5.4.3`). The second
/// form is what [subjectNameFromPem] hands back, and taking it here is what
/// lets `relay_certs --leaf` reproduce a CA's subject name byte for byte
/// instead of approximately.
ASN1Sequence _distinguishedName(Map<String, String> attributes) {
  final name = ASN1Sequence();
  attributes.forEach((key, value) {
    final oid = _dottedOid.hasMatch(key)
        ? ASN1ObjectIdentifier.fromIdentifierString(key)
        : ASN1ObjectIdentifier.fromName(key);
    name.add(ASN1Set(elements: [
      ASN1Sequence(elements: [
        oid,
        ASN1PrintableString(stringValue: value),
      ])
    ]));
  });
  return name;
}

final RegExp _dottedOid = RegExp(r'^\d+(\.\d+)+$');

/// `SubjectPublicKeyInfo` for an RSA key.
ASN1Sequence _publicKeyBlock(RSAPublicKey key) {
  final algorithm = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromName('rsaEncryption'))
    ..add(ASN1Null());
  return ASN1Sequence()
    ..add(algorithm)
    ..add(ASN1BitString(stringValues: _rsaPublicKeyDer(key)));
}

/// `RSAPublicKey ::= SEQUENCE { modulus, publicExponent }` — the bytes that go
/// inside the `subjectPublicKey` BIT STRING, and the bytes [_keyIdentifier]
/// hashes. One function so the two cannot drift: an identifier computed over
/// something other than what the certificate carries names nothing.
Uint8List _rsaPublicKeyDer(RSAPublicKey key) => (ASN1Sequence()
      ..add(ASN1Integer(key.modulus))
      ..add(ASN1Integer(key.exponent)))
    .encode();

Uint8List _sign(Uint8List bytes, RSAPrivateKey key) {
  final signer = Signer('SHA-256/RSA')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  return (signer.generateSignature(bytes) as RSASignature).bytes;
}
