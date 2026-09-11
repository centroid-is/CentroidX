/// A parseable trust anchor for a test, and nothing more.
///
/// [throwawayCaPath] mints a self-signed RSA root and returns a path to it, so
/// an arm can build the pinned `SecurityContext(withTrustedRoots: false)
/// ..setTrustedCertificates(path)` that `RemoteStateMan`'s constructor builds
/// (`remote_state_man.dart:124-132`) and reach the code beyond it. The three
/// `basic_utils` calls are the ones already running in production in this
/// repo: `packages/tfc_dart/bin/generate_certs.dart:37-60`.
///
/// **This anchor never signs anything, is never presented by a server, and
/// carries no SAN.** That is deliberate and it is what keeps `basic_utils`'
/// subject-alternative-name defect out of reach: it encodes *every* SAN as a
/// `dNSName` — `X509Utils.dart:480-484` is literally `ASN1PrintableString(
/// stringValue: s, tag: 0x82)` with no parameter to change it — so an IP
/// literal goes in as the DNS *string* `"10.50.10.11"` and the leaf is refused
/// when dialled by address. That is measured in
/// `packages/tfc_relay_server/lib/src/tls/mint.dart:1-30`. **No plan in this
/// phase may try to mint an IP-only-SAN leaf with this library.** The rig's
/// FIND-B case is covered the cheap way instead: `_refusalReason` maps every
/// `HandshakeException` to one sentence regardless of cause
/// (`connection_supervisor.dart:450-467`), so a `wss://` dial at a plaintext
/// `HttpServer` reaches the identical app-visible input with no TLS server, no
/// leaf and no key.
///
/// **Paths, never the checkout.** The PEM is written under
/// `Directory.systemTemp` with the recursive delete registered at acquisition,
/// the discipline `tls_client_test.dart:202-212` states: an arm that fails an
/// assertion before its own cleanup line still takes the key off the machine,
/// and no run may leave a `.pem` somewhere `git add` would find it.
library;

import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// The minted PEM, once per isolate.
///
/// **The string is cached; the file is not.** RSA-2048 keygen is the whole
/// cost (~0.4 s), and a file write is free. Caching the *path* instead would
/// mean the `addTearDown` inside the lazy initialiser ran at the end of the
/// first case that called it, deleting the directory under every later case
/// that holds the same path — a fixture that works alone and fails in a suite.
String? _cachedPem;

/// A fresh file holding a self-signed 2048-bit RSA root, deleted at teardown.
///
/// Call it from inside a test body: the delete is registered per call, at
/// acquisition, which is only legal where a test is running.
String throwawayCaPath() {
  final pem = _cachedPem ??= _mintRootPem();

  final dir = Directory.systemTemp.createTempSync('phase15-ca-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final path = '${dir.path}${Platform.pathSeparator}root.pem';
  File(path).writeAsStringSync(pem);
  return path;
}

/// Keypair, CSR, self-signed certificate — the three calls, in that order.
String _mintRootPem() {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  // No SAN, and no `san:` argument anywhere in this file. See the library doc.
  const attributes = {
    'CN': 'Phase 15 Throwaway CA',
    'O': 'Centroid',
    'C': 'IS',
  };
  final csr = X509Utils.generateRsaCsrPem(
    attributes,
    pair.privateKey as RSAPrivateKey,
    pair.publicKey as RSAPublicKey,
  );
  return X509Utils.generateSelfSignedCertificate(
    pair.privateKey as RSAPrivateKey,
    csr,
    3650,
  );
}
