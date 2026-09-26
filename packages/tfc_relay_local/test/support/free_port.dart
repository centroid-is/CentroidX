/// Where an in-process OPC UA server gets its port, and why it is not a
/// literal.
///
/// **The obvious thing is forbidden and the second-obvious thing does not
/// work.** `subscription_inactivity_test.dart:30-31` allocates
/// `14840 + Random().nextInt(1000)` plus a per-test index; that collides across
/// parallel worktrees exactly the way `tfc_dart`'s hard-coded 15432 does
/// (project memory), and the collision surfaces as a fault-mode failure in the
/// code under test rather than as a bind error. So the freeze suite forbids a
/// port literal in this directory outright.
///
/// The natural answer is `Server(port: 0)` — and it was **measured, not
/// assumed**. open62541 accepts it and logs *"Dynamic port assignment will be
/// used"*, then binds an OS-assigned pair of sockets. It works. What does not
/// work is finding out **which** port it got: `Server`
/// (`open62541/lib/src/server.dart:33-48`) passes the number straight to
/// `UA_ServerConfig_setMinimal` and exposes nothing afterwards, so a client has
/// no address to connect to. The probe run is recorded in 08-07's SUMMARY;
/// `lsof` found the sockets, and `lsof` is not a portable way to find out where
/// your own test server is listening.
///
/// Hence [freePort]: ask the kernel for a port the ordinary way, give it back,
/// and hand the number to `Server`. That has a race in it and the race is why
/// [withFreePort] exists — see below.
library;

import 'dart:async';
import 'dart:io';

/// One port nothing was listening on a moment ago.
///
/// Binds a `ServerSocket` on 0, reads what the kernel assigned, closes it, and
/// returns the number.
///
/// **This is a race and pretending otherwise would be worse.** Between the
/// close here and the caller's bind, another process on the machine can take
/// the port — the window is small and it is not zero, and on a CI box running
/// three OS matrix legs it is a real window. Two things follow, and both are
/// deliberate:
///
///  * The caller retries. [withFreePort] does it so that no caller has to
///    remember.
///  * A fixed range is **worse**, not safer. A literal (or a random draw inside
///    a literal range) collides with the *other copy of this suite* — the case
///    that actually happens, every time two worktrees run at once — and it
///    collides deterministically rather than occasionally. The kernel's
///    allocator at least knows what is in use right now.
Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final assigned = socket.port;
  await socket.close();
  return assigned;
}

/// How many times [withFreePort] re-draws before it gives up.
///
/// Three: enough to make the close-then-bind race disappear from the failure
/// budget, few enough that a machine with no free ports at all still fails in
/// under a second instead of spinning.
const int freePortAttempts = 3;

/// Runs [bind] against a fresh [freePort], re-drawing on failure.
///
/// [bind] receives a port and must either return its result or throw. A throw
/// is treated as "that port did not work", which is the honest reading: the
/// binding's `Server.start()` throws when `UA_Server_run_startup` refuses, and
/// the overwhelmingly likely reason for a refusal on a port the kernel just
/// called free is that somebody else took it in between.
///
/// The last attempt's error is rethrown rather than swallowed into a generic
/// message, because the third failure in a row is usually not a race and the
/// caller needs to see what it actually was.
Future<T> withFreePort<T>(FutureOr<T> Function(int port) bind) async {
  Object? lastError;
  StackTrace? lastStack;
  for (var attempt = 0; attempt < freePortAttempts; attempt++) {
    final port = await freePort();
    try {
      return await bind(port);
    } catch (error, stack) {
      lastError = error;
      lastStack = stack;
    }
  }
  Error.throwWithStackTrace(
    StateError('could not bind a free port in $freePortAttempts attempts; the '
        'last failure was: $lastError'),
    lastStack ?? StackTrace.current,
  );
}
