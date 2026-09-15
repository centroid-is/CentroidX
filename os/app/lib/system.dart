import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'answers.dart';

/// Paths the shell installer and this app agree on. The app is only a front end:
/// every destructive step stays in `centroidx-install`, which has been reviewed
/// and is exercised by CI, so there is exactly one implementation of "wipe a
/// disk and write an image".
class Paths {
  static const installer = '/usr/local/bin/centroidx-install';
  static const runtimeDir = '/run/centroidx';
  static const seed = '$runtimeDir/station.env';

  /// Written once per boot by centroidx-remote-access, as `code=XXXX`.
  ///
  /// weston's VNC backend authenticates through PAM as the user running
  /// weston, which is root — and the stick ships with root locked, so without
  /// that unit nobody could ever connect. The code is shown on screen because
  /// the person who needs it is on the phone to the person at the panel.
  static const remoteAccess = '$runtimeDir/remote-access';

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
/// Pass [boot] when the caller has already resolved the boot disk, so probing
/// it does not run twice for one screen.
Future<List<TargetDisk>> listDisks({String? boot}) async {
  boot ??= await bootDisk();
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

/// How a shutdown is asked for. Only [reboot] and [powerOff] read this; tests
/// replace it, because the alternative is a test suite that reboots the
/// machine running it.
@visibleForTesting
Future<ProcessResult> Function(String exe, List<String> args) runProcess =
    Process.run;

/// How long a `systemctl` invocation may take before it is treated as hung.
@visibleForTesting
Duration shutdownCallTimeout = const Duration(seconds: 10);

/// How long an ACCEPTED request is given to actually take the machine down
/// before the next rung is tried. Generous: a clean stop of the handful of
/// units on this stick is a second or two, and the units that could legitimately
/// take longer are the ones worth escalating past anyway.
@visibleForTesting
Duration shutdownGrace = const Duration(seconds: 10);

/// Reboots, escalating until something takes.
///
/// It returns only if the machine is still here -- a working reboot takes this
/// process with it -- so the answer is always the bad news: what every rung
/// said, joined, for the screen.
///
/// The one-line version of this (`systemctl reboot`, report a non-zero exit)
/// left the operator with a button that greyed out and a panel that stayed put:
/// the message went into the log below the fold, and "exit 0" is not the same
/// claim as "the machine went down". So each rung is watched, and there is
/// always a next one:
///
///   1. `systemctl reboot`                   stop every unit, unmount, reboot.
///   2. `systemctl --force reboot`           kill the processes and remount
///                                           read-only without stopping units,
///                                           so one hung stop job cannot hold
///                                           it.
///   3. `systemctl --force --force reboot`   sync(), then reboot(2) from
///                                           systemctl itself. It contacts no
///                                           init system, no D-Bus and no
///                                           logind -- it needs root and
///                                           nothing else, and this app runs as
///                                           root under centroidx-gui.service.
///
/// Rung 3 is safe here in a way it would not be on a running station: the
/// target disk was written, synced and unmounted by centroidx-install before
/// this screen appeared, and the stick itself holds nothing worth keeping.
Future<String> reboot() => _shutdown('reboot');

/// Offered beside Reboot when an install has failed. Rebooting a machine whose
/// disk was just wiped drops it at the firmware; powering it off is usually
/// what the operator wanted anyway, and it is one fewer reason to reach behind
/// a panel for the switch. Same ladder as [reboot], for the same reason.
Future<String> powerOff() => _shutdown('poweroff');

Future<String> _shutdown(String verb) async {
  final rungs = <List<String>>[
    [verb],
    ['--force', verb],
    ['--force', '--force', verb],
  ];
  final refusals = <String>[];
  for (final args in rungs) {
    final refusal = await _ask(args);
    if (refusal == null) {
      // Accepted. Nothing left to do but find out whether it was true.
      await Future<void>.delayed(shutdownGrace);
      refusals.add('systemctl ${args.join(' ')}: accepted, then nothing');
    } else {
      // A refusal is an answer already; there is no point waiting on it.
      refusals.add(refusal);
    }
  }
  return refusals.join('\n');
}

/// Null when the request was accepted, otherwise why it was not.
Future<String?> _ask(List<String> args) async {
  final cmd = 'systemctl ${args.join(' ')}';
  try {
    final r = await runProcess('systemctl', args).timeout(shutdownCallTimeout);
    if (r.exitCode == 0) return null;
    final msg = '${r.stderr}'.trim();
    return '$cmd: ${msg.isEmpty ? 'exited ${r.exitCode}' : msg}';
  } on TimeoutException {
    return '$cmd: no answer in ${shutdownCallTimeout.inSeconds}s';
  } on ProcessException catch (e) {
    return '$cmd: ${e.message}';
  }
}

/// Every non-loopback IPv4 this machine currently holds.
///
/// `dart:io` rather than parsing `ip -o -4 addr` (which is what the shell
/// installer's banner does, because it has no other option): the list is the
/// same and this needs no subprocess. The station's own About page builds the
/// equivalent from NetworkManager over D-Bus — there is no NetworkManager on
/// the USB, so the source differs even though the answer does not.
/// The per-boot remote-access code, or null when there is none.
///
/// Absent means the credential unit did not run, which is the one case worth
/// distinguishing: the remote view is then unreachable no matter what is typed,
/// so the UI must not offer an address as though it were usable.
Future<String?> remoteAccessCode() async {
  try {
    final f = File(Paths.remoteAccess);
    if (!f.existsSync()) return null;
    for (final line in (await f.readAsString()).split('\n')) {
      if (line.startsWith('code=')) {
        final v = line.substring('code='.length).trim();
        return v.isEmpty ? null : v;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

Future<List<String>> hostAddresses() async {
  try {
    final ifs = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    return [
      for (final i in ifs)
        for (final a in i.addresses) a.address,
    ];
  } on OSError {
    return const [];
  } on SocketException {
    return const [];
  }
}

Future<String?> _out(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trimRight();
  } on ProcessException {
    return null;
  }
}
