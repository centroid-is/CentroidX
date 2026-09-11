/// `relay_certs` — the command an integrator runs to provision a plant.
///
/// SEC-01 asks for tooling that generates a CA root and a server leaf. This is
/// it, and it needs no `openssl` on the machine: the certificate bytes come
/// from `lib/src/tls/mint.dart`, which is also what every test in this phase
/// mints through. That shared function is the point (06-RESEARCH §B.4). A
/// second ASN.1 path living in `bin/` would be a second place the iPAddress
/// SAN fix has to be remembered, and it would be the copy nobody re-tests —
/// so `relay_certs_test.dart` reads this file's own text and fails if the
/// string `ASN1` appears in it.
///
/// Two runs, in order:
///
/// ```
/// dart run tfc_relay_server:relay_certs --ca --out /etc/relay/pki
/// dart run tfc_relay_server:relay_certs --leaf \
///     --ca-cert /etc/relay/pki/ca.pem --ca-key /etc/relay/pki/ca-key.pem \
///     --san relay.svn.local --san 10.104.29.71 --days 365 \
///     --out /etc/relay/pki
/// ```
///
/// The root is provisioned once (ten years) to every panel; the leaf is
/// re-issued yearly, which the days-to-expiry health key turns into a Tuesday
/// ticket rather than an outage.
///
/// [main] is a thin wrapper over [run] so the tests can call it in-process:
/// spawning `dart run` from the worktree root fires the native-asset build
/// hooks and rebuilds mbedTLS before the script executes (trap 15).
///
/// Without this file SEC-01 is half-met — the library can mint, and nobody in
/// the plant has a way to ask it to.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

/// The exit code the process should carry.
///
/// `out` and `err` are [StringSink] rather than `IOSink` on purpose: `stdout`
/// and `stderr` are both, and so is a `StringBuffer`, which is what lets a
/// case assert on the message an integrator sees without a pipe or a
/// subprocess.
Future<int> run(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = _parser();

  ArgResults options;
  try {
    options = parser.parse(args);
  } on FormatException catch (e) {
    // A misspelled option is a refusal, not a crash: an integrator reading
    // `FormatException` learns nothing they can act on.
    stderrSink.writeln('relay_certs: ${e.message}');
    stderrSink.writeln(parser.usage);
    return 1;
  }

  if (options.flag('help')) {
    stdoutSink.writeln('Generate a private CA root and a gateway leaf for the '
        'relay pipe.\n');
    stdoutSink.writeln('Usage: relay_certs --ca   --out <dir>');
    stdoutSink.writeln('       relay_certs --leaf --ca-cert <path> '
        '--ca-key <path> [--san <name>]... --out <dir>\n');
    stdoutSink.writeln(parser.usage);
    return 0;
  }

  try {
    if (options.flag('ca')) return _mintRoot(options, stdoutSink);
    if (options.flag('leaf')) return _mintLeaf(options, stdoutSink);
    stderrSink.writeln('relay_certs: give exactly one of --ca or --leaf.');
    stderrSink.writeln(parser.usage);
    return 1;
  } on _Refused catch (refusal) {
    // Every refusal below reaches the operator as one sentence naming what is
    // missing. A stack trace on a plant machine at 6 a.m. is not a message.
    stderrSink.writeln('relay_certs: ${refusal.message}');
    return 1;
  } on FileSystemException catch (e) {
    stderrSink.writeln('relay_certs: ${e.path}: ${e.osError?.message ?? e.message}');
    return 1;
  }
}

Future<void> main(List<String> args) async => exit(await run(args));

ArgParser _parser() => ArgParser()
  ..addFlag('ca', negatable: false, help: 'Generate a private CA root.')
  ..addFlag('leaf',
      negatable: false, help: 'Generate a gateway leaf signed by a CA.')
  ..addOption('out',
      help: 'Directory the PEM files are written to.', valueHelp: 'dir')
  ..addOption('cn',
      help: 'Common name.', valueHelp: 'name')
  ..addOption('org', help: 'Organization.', valueHelp: 'name', defaultsTo: 'Centroid')
  ..addOption('ca-cert',
      help: 'Path to the CA certificate (--leaf).', valueHelp: 'path')
  ..addOption('ca-key',
      help: 'Path to the CA private key (--leaf).', valueHelp: 'path')
  ..addMultiOption('san',
      help: 'Subject-alternative name. A value that parses as an IP address '
          'is written as an iPAddress; anything else as a DNS name. Repeat '
          'for each. The panels dial addresses, so include them.',
      valueHelp: 'name-or-ip')
  // **No `defaultsTo` here, and that is the whole of it.**
  // `ArgResults.option` is `option.valueOrDefault(_parsed[name])`, so a
  // parser-level default is returned even when the flag is absent — which
  // means `_days`'s per-mode `fallback` is never reached and one number
  // silently wins for both subcommands. A 365-day root reads healthy for a
  // year and then stops every panel in the plant on the same morning, with
  // the days-to-expiry key measuring the leaf and reporting nothing wrong.
  ..addOption('days',
      help: 'Validity in days. Defaults to 3650 for --ca and 365 for --leaf.',
      valueHelp: 'n')
  // No parser default here either, and for the same reason.
  ..addOption('key-size',
      help: 'RSA key size in bits. Defaults to 4096 for --ca and 2048 for '
          '--leaf.',
      valueHelp: 'bits')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this usage.');

int _mintRoot(ArgResults options, StringSink out) {
  // Every refusal before the first side effect: the directory is not created
  // and the keygen — the expensive part — is not paid for by a run that
  // cannot finish.
  final days = _days(options, fallback: 3650);
  final keySize = _keySize(options, fallback: 4096);
  final dn = _distinguishedName(options, fallbackCn: 'Relay Private CA');
  final dir = _outDirectory(options);
  final keys = generateKeyPair(keySize: keySize);
  final now = DateTime.now().toUtc();

  final pem = mintCertificate(
    signingKey: keys.privateKey,
    issuer: dn,
    subject: dn,
    subjectPublicKey: keys.publicKey,
    notBefore: now.subtract(const Duration(days: 1)),
    notAfter: now.add(Duration(days: days)),
    ca: true,
  );

  _write(dir, 'ca.pem', pem, out);
  _write(dir, 'ca-key.pem', privateKeyToPem(keys.privateKey), out, private: true);
  return 0;
}

int _mintLeaf(ArgResults options, StringSink out) {
  final caCert = _readRequired(options, 'ca-cert');
  final caKey = _readRequired(options, 'ca-key');
  final days = _days(options, fallback: 365);
  final keySize = _keySize(options, fallback: 2048);

  final sans = options.multiOption('san');
  if (sans.isEmpty) {
    throw const _Refused('--leaf needs at least one --san. A leaf with no '
        'subject-alternative name matches no host, and every panel refuses '
        'it at the handshake.');
  }

  final issuer = _reproducibleIssuer(caCert, options.option('ca-cert')!);
  final subject = _distinguishedName(options, fallbackCn: sans.first);
  final dir = _outDirectory(options);
  final keys = generateKeyPair(keySize: keySize);
  final now = DateTime.now().toUtc();

  final pem = mintCertificate(
    signingKey: privateKeyFromPem(caKey),
    // Byte-identical to the CA's own subject name, because a verifier matches
    // the two on DER bytes and not on how they render. `_reproducibleIssuer`
    // is what makes "byte-identical" true rather than hoped for.
    issuer: issuer,
    subject: subject,
    subjectPublicKey: keys.publicKey,
    sans: sans,
    notBefore: now.subtract(const Duration(days: 1)),
    notAfter: now.add(Duration(days: days)),
  );

  _write(dir, 'leaf.pem', pem, out);
  _write(dir, 'leaf-key.pem', privateKeyToPem(keys.privateKey), out,
      private: true);
  return 0;
}

Directory _outDirectory(ArgResults options) {
  final path = options.option('out');
  if (path == null) {
    throw const _Refused('--out is required: name the directory the PEM files '
        'should be written to.');
  }
  final dir = Directory(path);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    // Only a directory this tool created. An integrator who pointed `--out`
    // at somewhere that already exists chose its mode, and silently changing
    // it is a surprise on a path that may hold other things.
    _restrict(dir.path, '700');
  }
  return dir;
}

/// Reads the file named by [name], refusing before anything is written.
///
/// The check is up front so a `--leaf` run that cannot succeed leaves no
/// half-written key material in the output directory.
String _readRequired(ArgResults options, String name) {
  final path = options.option(name);
  if (path == null) {
    throw _Refused('--$name is required with --leaf: the leaf has to be '
        'signed by something, and nothing was named.');
  }
  final file = File(path);
  if (!file.existsSync()) {
    throw _Refused('--$name: no such file: $path');
  }
  return file.readAsStringSync();
}

/// The subject name for the certificate this run mints, refused if the
/// encoder cannot carry it.
///
/// `pointycastle` writes whatever Dart string it is handed into a printable
/// string and validates nothing, so `--cn "Sjávarútvegur"` or an organisation
/// name carrying an underscore produces a certificate that is not valid DER.
/// It chains here, because both ends use the same encoder, and may be refused
/// by anything else that ever reads it — a Windows certificate store, an
/// inventory tool, the OPC UA stack next door.
Map<String, String> _distinguishedName(ArgResults options,
    {required String fallbackCn}) {
  final cn = options.option('cn');
  return {
    'CN': _printableOnly(cn ?? fallbackCn,
        cn != null ? '--cn' : '--cn (defaulted from the first --san)'),
    'O': _printableOnly(options.option('org')!, '--org'),
  };
}

/// Letters, digits, space and `'()+,-./:=?` — the whole of PrintableString.
final RegExp _printableAlphabet = RegExp(r"^[A-Za-z0-9 '()+,\-./:=?]+$");

String _printableOnly(String value, String option) {
  if (_printableAlphabet.hasMatch(value)) return value;
  throw _Refused('$option is "$value", which the certificate name encoder '
      'cannot carry. The alphabet is letters, digits, space and the '
      'punctuation \'()+,-./:=? — no underscore, no @, no *, nothing outside '
      'ASCII. The library does not check this, so the file would be written '
      'and would not be valid; it would work against this tool\'s own CA and '
      'be refused by anything else that reads it.');
}

/// The CA's subject name, or a refusal when this tool cannot reproduce it.
///
/// The issuer name on a leaf has to be **byte-identical** to the subject name
/// on its root, and the round trip here goes through text: the name is read
/// back as strings and written out again as printable strings. That preserves
/// the characters and loses the encoding. `openssl` writes `CN` as a UTF8
/// string by default, so a root minted anywhere but here yields a leaf that
/// chains to nothing — and the message every panel then shows is the one a
/// wrong CA and an expired leaf also show (trap 16). Refusing here costs one
/// parse and turns that into a sentence at provisioning time.
Map<String, String> _reproducibleIssuer(String caCertPem, String path) {
  final foreign = subjectNameTagsFromPem(caCertPem)
      .entries
      .where((entry) => entry.value != printableStringTag)
      .map((entry) => entry.key)
      .toList();
  if (foreign.isNotEmpty) {
    throw _Refused('the CA at $path writes ${foreign.join(', ')} in its '
        'subject name with a string encoding this tool cannot reproduce — '
        'openssl uses a UTF8 string for the common name, relay_certs uses a '
        'printable string. A verifier matches a leaf\'s issuer name to the '
        'root\'s subject name on the raw bytes, so the leaf this run would '
        'write chains to nothing and every panel reports '
        'CERTIFICATE_VERIFY_FAILED, which is the same message a wrong CA and '
        'an expired leaf produce. Mint the root with `relay_certs --ca` and '
        'sign against that one.');
  }
  return subjectNameFromPem(caCertPem);
}

int _keySize(ArgResults options, {required int fallback}) {
  final raw = options.option('key-size');
  if (raw == null) return fallback;
  final bits = int.tryParse(raw);
  if (bits == null || bits < 2048) {
    throw _Refused('--key-size must be a whole number of bits and at least '
        '2048, not "$raw".');
  }
  return bits;
}

int _days(ArgResults options, {required int fallback}) {
  final raw = options.option('days');
  if (raw == null) return fallback;
  final days = int.tryParse(raw);
  if (days == null || days <= 0) {
    throw _Refused('--days must be a positive whole number, not "$raw".');
  }
  return days;
}

/// Writes [contents] to `dir/name`, restricting a private key **before** the
/// bytes go in.
///
/// The order is the point. `writeAsStringSync` creates a file at
/// `0666 & ~umask` — 0644 on a normal account — so a write-then-chmod leaves
/// the gateway's identity readable by every account on the machine for the
/// interval in between. Creating the file empty, restricting it, and only then
/// writing means the window contains nothing worth reading.
void _write(Directory dir, String name, String contents, StringSink out,
    {bool private = false}) {
  final path = '${dir.path}${Platform.pathSeparator}$name';
  final file = File(path)..createSync();
  if (private) _restrict(path, '600', onFailure: file.deleteSync);
  file.writeAsStringSync(contents);
  out.writeln('wrote $path');
}

/// Restricts [path] to [mode], or refuses.
///
/// **Both halves are load-bearing.** A discarded `ProcessResult` is a `chmod`
/// that may never have run — a missing binary, a container with a trimmed
/// image — and exit 0 on its own is not evidence either: a filesystem that
/// does not carry POSIX modes (a bind mount, a FAT stick) reports success and
/// leaves the file exactly as it was. So the result is checked and the mode is
/// then read back. Either failure is a non-zero exit naming the file, never a
/// `wrote /etc/relay/pki/ca-key.pem` the integrator has no reason to doubt.
void _restrict(String path, String mode, {void Function()? onFailure}) {
  if (Platform.isWindows) return;
  final chmod = Process.runSync('chmod', [mode, path]);
  if (chmod.exitCode == 0 && FileStat.statSync(path).mode & 0x3F == 0) return;
  final why = chmod.exitCode == 0
      ? 'the mode did not take — this filesystem does not carry POSIX '
          'permissions'
      : 'chmod exited ${chmod.exitCode} (${'${chmod.stderr}'.trim()})';
  onFailure?.call();
  throw _Refused('could not restrict $path to $mode: $why. Refusing to leave '
      'key material on a path this machine cannot protect; mount the PKI '
      'directory on a filesystem that carries modes, or provision on the '
      'gateway host.');
}

/// An operator-facing refusal: one sentence, no stack trace, exit 1.
final class _Refused implements Exception {
  const _Refused(this.message);
  final String message;
  @override
  String toString() => message;
}
