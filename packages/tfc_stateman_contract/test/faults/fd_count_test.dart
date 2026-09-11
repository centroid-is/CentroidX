/// Proof that the open-socket counter actually counts.
///
/// The roadmap's socket-leak criterion is "open and tear down 100 proxied
/// connections, the open-socket count returns to baseline". That criterion is
/// only worth anything if the counter can see a socket in the first place, and
/// the obvious counter cannot: RESEARCH Finding 11 measured `lsof` exiting **1**
/// when no rows match, so a naive `exitCode != 0` check reports failure exactly
/// when the honest answer is zero — which is the answer the *passing* case
/// produces. A leak test built on that counter passes with the proxy's
/// `destroy()` calls commented out (RESEARCH Pitfall 2).
///
/// So this file holds [_held] connections open deliberately and asserts the
/// counter notices, then closes them and asserts it comes back down. RESEARCH
/// measured the control arm at 41 open fds against a baseline of 0, and a real
/// leak — one forgotten `destroy()` on the upstream-accepted socket — as
/// deltas of 10 / 60 / 160 over 10 / 50 / 100 cycles. Resolution is one file
/// descriptor, which is precisely the bug class the criterion exists for.
///
/// Without this file the fd counter is a number nobody has ever seen move.
@Tags(['faults'])
@OnPlatform({
  'windows': Skip('open-fd counting needs /proc/self/fd or lsof and Windows '
      'has neither, so the socket-leak criterion goes unjudged there — a '
      'named skip on the run report rather than a vacuous pass'),
})
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// How many connections the control arm holds open at once.
///
/// Each one costs two descriptors in this process — the client end and the
/// end the loopback listener accepted — so the observed delta is about twice
/// this. The assertion uses this number as a floor rather than the doubled
/// one, because what is being proven is that the counter moves with reality,
/// not the arithmetic of who holds which end.
const _held = 20;

/// How long to wait after a teardown before believing a count.
///
/// RESEARCH Finding 11: `destroy()` is asynchronous with respect to the
/// descriptor actually closing, and counting too early produces intermittent
/// off-by-a-few deltas (Pitfall 3). 300-400 ms was enough across 100-cycle
/// runs on both platforms.
const _settle = Duration(milliseconds: 400);

/// Counts open socket fds, after letting the kernel catch up.
///
/// The delay here is a **measurement** delay, not synchronisation — the one
/// use of `Future.delayed` this phase sanctions. There is no event to await
/// for "the fd table has settled"; the kernel does not announce it. Every
/// count in this file goes through this helper so no arm can accidentally read
/// a half-settled table and blame the code under test.
Future<int> _countAfterSettle() async {
  await Future<void>.delayed(_settle);
  return openSocketCount();
}

void main() {
  test('answers with a number, and zero is an answer rather than a failure',
      () {
    expect(openSocketCount(), greaterThanOrEqualTo(0),
        reason: 'a counter that throws instead of answering zero fails the '
            'leak criterion exactly when the code under test is clean, so the '
            'first honest proxy anyone writes reads as the leaky one');
  });

  test('declares itself available on a platform that can actually count', () {
    expect(canCountOpenSockets, isTrue,
        reason: 'this file is skipped by name on the platforms that cannot '
            'count, so reaching here while declaring itself unavailable means '
            'the capability flag and the skip annotation disagree — and the '
            'flag is what later plans will gate their leak tests on');
    expect(openSocketCountSkipReason, isNotEmpty,
        reason: 'the reason travels into a Skip() on every leak test, and an '
            'empty one turns a visible "not judged here" into silence');
  });

  test('notices $_held sockets held open, and comes back down when they close',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final accepted = <Socket>[];
    final allAccepted = Completer<void>();
    final subscription = server.listen((socket) {
      accepted.add(socket);
      if (accepted.length == _held && !allAccepted.isCompleted) {
        allAccepted.complete();
      }
    });
    addTearDown(subscription.cancel);

    final baseline = await _countAfterSettle();

    final clients = <Socket>[];
    addTearDown(() {
      for (final socket in clients) {
        socket.destroy();
      }
    });
    for (var i = 0; i < _held; i++) {
      clients.add(await within(
        Socket.connect(server.address, server.port),
        'held connection ${i + 1} of $_held reached the loopback listener',
        budget: const Duration(seconds: 2),
      ));
    }
    await within(
      allAccepted.future,
      'the listener accepted all $_held held connections',
      budget: const Duration(seconds: 5),
    );

    final whileHeld = await _countAfterSettle();
    expect(whileHeld - baseline, greaterThanOrEqualTo(_held),
        reason: 'a counter that cannot see $_held sockets held open cannot see '
            'one leaked socket either, and the leak criterion it backs would '
            'pass against a proxy that forgets every destroy() it owes');

    for (final socket in clients) {
      socket.destroy();
    }
    for (final socket in accepted) {
      socket.destroy();
    }

    final afterRelease = await _countAfterSettle();
    expect(afterRelease, baseline,
        reason: 'the count must fall back to where it started, or it is '
            'measuring something that outlives the socket — and every later '
            'leak assertion becomes a false alarm engineers learn to ignore');
  });
}
