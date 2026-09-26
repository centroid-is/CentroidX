/// What this machine will let the OS-level fault tests actually do.
///
/// CONTEXT's mandate is "named skip, not silence": an OS-level leg that never
/// runs anywhere must not look identical to one that runs everywhere. A test
/// that returns early on `if (!hasRoot)` reports as **passing**, so the
/// capability is declared once here, at the registration point, and turns into
/// a `Skip(...)` whose reason says which half of the check decided the answer
/// — the idiom `lib/src/write_contract.dart:601-675` already uses for the
/// contract's own declined capabilities.
///
/// Each probe is two-part, because both halves fail differently and both are
/// worth telling apart (RESEARCH Finding 13, measured on this machine):
///
/// | Probe | Unprivileged result | Meaning |
/// |---|---|---|
/// | `sudo -n true` | exit 1 | no passwordless sudo |
/// | `dnctl list` | exit 69 | present but unprivileged |
/// | `pfctl -s info` | exit 1 | present but unprivileged |
/// | `tc` on macOS | not found | Linux-only, as expected |
///
/// Two properties this file must never lose:
///
/// - **Non-interactive.** `sudo -n` is what guarantees no password prompt. A
///   probe that prompts does not fail — it *hangs*, on a CI runner with nobody
///   at the keyboard, until the job times out.
/// - **Argument vectors, never interpolated strings.** Every external command
///   here is a fixed `List<String>` to [Process.run]. The OS-level helpers
///   these probes gate will take an interface name from their caller, and an
///   interface name must never be able to become a command.
///
/// Answers are cached: an `oslevel` suite asks per test, and a `sudo`
/// invocation per case would make the probe the slowest thing in the run.
library;

import 'dart:async';
import 'dart:io';

/// Whether a machine capability is available, and why it is or is not.
///
/// [reason] is populated in **both** cases, not only the unavailable one. The
/// available branch's reason is what a future engineer reads when an OS-level
/// test behaves oddly on a machine where it did run, and a field that is
/// sometimes empty is a field that gets logged as blank.
typedef Capability = ({bool available, String reason});

/// How long any single probe may take before it counts as unavailable.
///
/// A probe that hangs is worse than one that says no: it stalls the runner
/// (threat T-02-02). `sudo -n` returns immediately by construction, so
/// reaching this timeout means something is wrong with the machine, and
/// "wrong with the machine" is exactly the unavailable case.
const _probeTimeout = Duration(seconds: 5);

Capability? _sudo;
Capability? _tc;
Capability? _dnctl;
Capability? _pfctl;

/// Runs [executable] with [arguments] and reports how it exited.
///
/// Returns a null exit code when the binary is absent — [ProcessException] is
/// how `dart:io` reports ENOENT — so callers can tell "not installed" from
/// "installed and refused", which is the whole point of a two-part probe.
Future<int?> _run(String executable, List<String> arguments) async {
  try {
    final result =
        await Process.run(executable, arguments).timeout(_probeTimeout);
    return result.exitCode;
  } on TimeoutException {
    return null;
  } catch (_) {
    // ProcessException (ENOENT) and anything else the platform raises for a
    // command it cannot start. Caught as Object because dart:io is not
    // consistent about the type here.
    return null;
  }
}

/// Whether `sudo` will run something without asking for a password.
///
/// The gate for every OS-level leg on both platforms. `-n` is load-bearing:
/// without it a machine with a password-protected sudo prompts and the probe
/// never returns.
Future<Capability> hasPasswordlessSudo() async =>
    _sudo ??= await _probePasswordlessSudo();

Future<Capability> _probePasswordlessSudo() async {
  final code = await _run('sudo', ['-n', 'true']);
  return code == 0
      ? (available: true, reason: 'sudo -n true succeeded')
      : (
          available: false,
          reason: 'no passwordless sudo on this machine: sudo -n true '
              '${code == null ? 'did not return' : 'exited $code'}',
        );
}

/// Whether `tc netem` can be installed on an interface here.
///
/// Two parts: the binary exists, **and** a privileged `tc` invocation
/// succeeds. Both are needed — `tc` present without root is the ordinary
/// developer machine, and root without `tc` is a container nobody installed
/// `iproute2` into. Linux-only; macOS fails the first half.
Future<Capability> hasTc() async => _tc ??= await _probeTc();

Future<Capability> _probeTc() async {
  final present = await _run('tc', ['-Version']);
  if (present != 0) {
    return (
      available: false,
      reason: 'tc is not installed here (iproute2 provides it, and it is '
          'Linux-only), so kernel traffic shaping cannot be set up at all',
    );
  }
  final privileged =
      await _run('sudo', ['-n', 'tc', 'qdisc', 'show', 'dev', 'lo']);
  return privileged == 0
      ? (available: true, reason: 'tc is installed and runs under sudo -n')
      : (
          available: false,
          reason: 'tc is installed but not privileged here: sudo -n tc '
              '${privileged == null ? 'did not return' : 'exited $privileged'}'
              ' — netem needs root to touch a qdisc',
        );
}

/// Whether macOS dummynet pipes can be configured here.
///
/// `dnctl` is present on stock macOS and exits **69** (`EX_UNAVAILABLE`,
/// "Operation not permitted") unprivileged, so the binary check alone would
/// report a capability the machine does not have.
Future<Capability> hasDnctl() async => _dnctl ??= await _probeDnctl();

Future<Capability> _probeDnctl() async {
  final present = await _run('dnctl', ['list']);
  if (present == null) {
    return (
      available: false,
      reason: 'dnctl is not present on this machine, so macOS dummynet '
          'shaping is unavailable (it ships with macOS and not with Linux)',
    );
  }
  final privileged = await _run('sudo', ['-n', 'dnctl', 'list']);
  return privileged == 0
      ? (available: true, reason: 'dnctl is present and runs under sudo -n')
      : (
          available: false,
          reason: 'dnctl is present but unprivileged: it exited $present '
              'directly and sudo -n dnctl '
              '${privileged == null ? 'did not return' : 'exited $privileged'}'
              ' — configuring a pipe needs root',
        );
}

/// Whether `pf` can be loaded and enabled here.
///
/// The other half of the macOS leg: `dnctl` configures a pipe, but traffic
/// only enters it through a pf rule. Unprivileged `pfctl -s info` exits 1 with
/// "/dev/pf: Permission denied".
Future<Capability> hasPfctl() async => _pfctl ??= await _probePfctl();

Future<Capability> _probePfctl() async {
  final present = await _run('pfctl', ['-s', 'info']);
  if (present == null) {
    return (
      available: false,
      reason: 'pfctl is not present on this machine, so no pf rule can '
          'classify traffic into a dummynet pipe',
    );
  }
  final privileged = await _run('sudo', ['-n', 'pfctl', '-s', 'info']);
  return privileged == 0
      ? (available: true, reason: 'pfctl is present and runs under sudo -n')
      : (
          available: false,
          reason: 'pfctl is present but unprivileged: it exited $present '
              'directly and sudo -n pfctl '
              '${privileged == null ? 'did not return' : 'exited $privileged'}'
              ' — /dev/pf is root-only',
        );
}
