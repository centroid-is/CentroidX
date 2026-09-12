import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'answers.dart';

/// Paths the shell installer and this app agree on. The app is only a front end:
/// every destructive step stays in `centroidx-install`, which has been reviewed
/// and is exercised by CI, so there is exactly one implementation of "wipe a
/// disk and write an image".
class Paths {
  static const installer = '/usr/local/bin/centroidx-install';
  static const runtimeDir = '/run/centroidx';
  static const seed = '$runtimeDir/station.env';

  /// Written by the installer once it has generated the station's WireGuard
  /// keypair. The private half never leaves the machine; this is the half that
  /// has to be registered on the server, so the app shows it at the end.
  static const publicKey = '$runtimeDir/wg-pubkey';
}

/// The disk the installer booted from, which must never be offered as a target.
Future<String?> bootDisk() async {
  final src = await _out('findmnt', ['-no', 'SOURCE', '/']);
  if (src == null || src.isEmpty) return null;
  final pk = await _out('lsblk', ['-no', 'PKNAME', src]);
  final name = pk?.split('\n').first.trim();
  return (name == null || name.isEmpty) ? null : name;
}

/// Candidate install targets. Returns empty rather than throwing when the boot
/// disk cannot be determined — the caller turns that into a refusal, because
/// there is no safe way to guess which disk not to erase.
Future<List<TargetDisk>> listDisks() async {
  final boot = await bootDisk();
  if (boot == null) return const [];
  final out = await _out('lsblk', ['-dno', 'NAME,SIZE,MODEL', '--sort', 'NAME']);
  if (out == null) return const [];
  final disks = <TargetDisk>[];
  for (final line in out.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final name = parts[0];
    if (name == boot) continue;
    if (RegExp(r'^(loop|sr|fd|ram|zram)').hasMatch(name)) continue;
    disks.add(TargetDisk(
      name: name,
      size: parts[1],
      model: parts.length > 2 ? parts.sublist(2).join(' ') : 'unknown',
    ));
  }
  return disks;
}

/// True when the boot disk could not be identified. The UI must refuse to offer
/// any target in that case rather than risk listing the USB it is running from.
Future<bool> bootDiskUnknown() async => (await bootDisk()) == null;

class InstallResult {
  InstallResult(this.exitCode, this.publicKey);
  final int exitCode;
  final String? publicKey;
  bool get ok => exitCode == 0;
}

/// Writes the seed and hands off to the shell installer, streaming its output so
/// the operator sees progress rather than a frozen screen for several minutes.
Future<InstallResult> runInstaller(
  Answers answers, {
  required void Function(String line) onLine,
}) async {
  await Directory(Paths.runtimeDir).create(recursive: true);
  final seed = File(Paths.seed);
  await seed.writeAsString(answers.toStationEnv());
  // The seed holds plaintext passwords for the few seconds before the installer
  // consumes it. It lives on a tmpfs and never reaches the target disk, but
  // there is no reason for it to be readable either.
  await Process.run('chmod', ['600', seed.path]);

  final proc = await Process.start(
    Paths.installer,
    ['--seed', seed.path, '--disk', answers.targetDisk!, '--no-reboot'],
    environment: {'TERM': 'dumb'},
  );
  final done = <Future<void>>[
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(onLine),
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(onLine),
  ];
  final code = await proc.exitCode;
  await Future.wait(done);
  // Best effort: absent when the operator skipped VPN setup.
  String? pub;
  final f = File(Paths.publicKey);
  if (f.existsSync()) pub = (await f.readAsString()).trim();
  return InstallResult(code, pub);
}

Future<void> reboot() => Process.run('systemctl', ['reboot']);

Future<String?> _out(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trimRight();
  } on ProcessException {
    return null;
  }
}
