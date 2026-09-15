/// How many socket file descriptors this process is holding, right now.
///
/// The socket-leak criterion — open and tear down 100 proxied connections and
/// watch the count return to baseline — needs a number that is right when it
/// is **zero**, and that is the whole difficulty. RESEARCH Finding 11 measured
/// `lsof` exiting **1** when no rows match, so the ordinary
/// `if (exitCode != 0) throw` reflex (correct in
/// `tfc_dart/test/integration/docker_compose.dart:64`, wrong here) turns the
/// clean case into a failure and, in an earlier draft, into a silent `null`.
/// Hence `exitCode > 1` below, which is the single least obvious line in this
/// file.
///
/// Two more measured details are load-bearing:
///
/// - **The descriptor directory macOS exposes under `/dev` is a trap.**
///   Listing it from Dart throws `FileSystemException` errno 9 there — the
///   listing's own directory descriptor goes stale mid-iteration — and
///   `/proc/self/fd` does not exist on macOS at all. So Linux gets the
///   pure-Dart path and macOS shells out to `lsof`. Neither branch touches
///   that `/dev` directory, and a grep of this file for it proves so.
/// - **Sockets specifically, not descriptors generally.** On Linux the
///   `socket:` prefix on the readlink target is what excludes the test
///   runner's log files and whatever else moves during a run; on macOS `-i`
///   does the same job. A count of all open fds drifts for reasons that have
///   nothing to do with the code under test, and a drifting baseline is how a
///   leak criterion gets relaxed out of existence.
///
/// TIME_WAIT is deliberately not defended against: 1245 system-wide TIME_WAIT
/// entries accumulated during RESEARCH's 100-cycle run without moving the
/// count, because a TIME_WAIT socket holds a kernel table entry rather than a
/// descriptor. No `SO_REUSEADDR` gymnastics are needed.
///
/// Callers must let the kernel catch up before believing a count — `destroy()`
/// returns before the descriptor closes. See `test/faults/fd_count_test.dart`
/// for the sanctioned settle.
library;

import 'dart:io';

/// Whether [openSocketCount] can answer on this platform.
///
/// Declared as a capability rather than inferred at the call site, so a test
/// that needs it says so once where it registers — the pattern
/// `lib/src/write_contract.dart:601-616` established for the contract's own
/// declined capabilities. Windows has neither mechanism.
bool get canCountOpenSockets => Platform.isLinux || Platform.isMacOS;

/// Why [openSocketCount] cannot answer where [canCountOpenSockets] is false.
///
/// Travels straight into a `Skip(...)`, so it is phrased as the run report
/// will read it. A skip whose reason is "unavailable" tells the next engineer
/// nothing about whether to fix it.
const openSocketCountSkipReason =
    'open-fd counting needs /proc/self/fd or lsof; Windows has neither, so '
    'the socket-leak criterion cannot be judged there';

/// Open **socket** descriptors held by this process.
///
/// Throws [UnsupportedError] where [canCountOpenSockets] is false, and
/// [StateError] if the measurement itself fails — never a wrong number. A
/// leak counter that guesses is worse than one that refuses.
int openSocketCount() {
  if (Platform.isLinux) {
    var count = 0;
    for (final entry
        in Directory('/proc/self/fd').listSync(followLinks: false)) {
      try {
        if (Link(entry.path).targetSync().startsWith('socket:')) count++;
      } catch (_) {
        // The descriptor closed between the listing and the readlink. It is
        // not open now, which is the question being asked.
      }
    }
    return count;
  }
  if (!Platform.isMacOS) {
    throw UnsupportedError(openSocketCountSkipReason);
  }
  final result = Process.runSync('lsof', ['-p', '$pid', '-a', '-i', '-nP']);
  // lsof exits 1 when there are no matching rows. That is a count of zero, not
  // a failure — and zero is what a leak-free run is supposed to produce.
  if (result.exitCode > 1) {
    throw StateError('lsof failed: ${result.stderr}');
  }
  final output = (result.stdout as String).trim();
  return output.isEmpty ? 0 : output.split('\n').length - 1; // drop the header
}
