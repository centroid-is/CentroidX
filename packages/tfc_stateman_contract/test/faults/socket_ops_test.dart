/// That a reset is a reset, that a close is not one, and that asking the
/// machine for privileges cannot hang or prompt.
///
/// The distinction this file defends is the one the original `proxy.dart` got
/// wrong: its doc comment says `reject()` "destroys existing connections and
/// RSTs new ones", but RESEARCH Finding 1 measured `destroy()` sending a clean
/// **FIN** on POSIX. It surfaces as ECONNRESET only when the socket happens to
/// have unread inbound data — a coincidence, and one a `killOnce` mode cannot
/// rest on. `SO_LINGER{1, 0}` followed by `destroy()` produced a genuine reset
/// in 50 of 50 runs (Finding 2); `close()` ignores linger entirely.
///
/// So the reset arm and the clean-close arm are a matched pair. Either one
/// alone proves nothing: a `forceReset` that quietly degraded to a FIN would
/// pass a test that only asked "did the peer notice something", and the modes
/// built on it in later plans — half-open recovery, `killOnce` — would be
/// testing a graceful shutdown while claiming to test a cut cable.
///
/// The reset arm is gated on a runtime probe rather than on `Platform.isWindows`
/// (Assumptions Log A3): Winsock's `struct linger` is believed to use `u_short`
/// fields, which would make the 8-byte struct wrong there — but that is an
/// assumption, and `setRawOption` rejects a wrong-size struct loudly with
/// `OSError` errno 22, so the machine can be asked instead of guessed about.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// How many times the reset arm repeats.
///
/// Finding 2 ran 50; five is enough to catch a `forceReset` that resets *some*
/// of the time, which is the failure mode plain `destroy()` exhibits — it
/// depends on whether unread data happens to be sitting in the receive queue.
/// A single-iteration test passes against exactly that bug.
const _iterations = 5;

/// A loopback connection, both ends in this process.
typedef _Pair = ({Socket near, Socket far});

/// Opens a loopback pair and registers teardown for every piece of it the
/// moment it exists.
Future<_Pair> _loopbackPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = server.first;
  final near = await within(
    Socket.connect(server.address, server.port),
    'the loopback pair connected',
    budget: const Duration(seconds: 2),
  );
  addTearDown(near.destroy);
  final far = await within(
    accepted,
    'the listener accepted the loopback connection',
    budget: const Duration(seconds: 2),
  );
  addTearDown(far.destroy);
  return (near: near, far: far);
}

/// What the peer saw: the error object, or null for a clean end.
///
/// Deliberately collapses "ended cleanly" to null rather than to a sentinel
/// error, because the whole question this file asks is whether the peer got an
/// error or an orderly end, and a type that can express both without
/// ambiguity is what keeps the two arms honest about each other.
Future<Object?> _peerOutcome(Socket peer) {
  final outcome = Completer<Object?>();
  peer.listen(
    (_) {},
    onError: (Object error) {
      if (!outcome.isCompleted) outcome.complete(error);
    },
    onDone: () {
      if (!outcome.isCompleted) outcome.complete(null);
    },
  );
  return outcome.future;
}

Future<void> main() async {
  final lingerWorks = await lingerResetSupported();

  group('forceReset', () {
    test('makes the peer observe an error, on every one of $_iterations runs',
        () async {
      final outcomes = <Object?>[];
      for (var i = 0; i < _iterations; i++) {
        final pair = await _loopbackPair();
        final seen = _peerOutcome(pair.near);
        forceReset(pair.far);
        outcomes.add(await within(
          seen,
          'the peer noticed the reset on run ${i + 1}',
          budget: const Duration(seconds: 2),
        ));
      }

      expect(outcomes.where((outcome) => outcome == null), isEmpty,
          reason: 'every run must surface an error rather than a clean end: a '
              'mode that silently sends FIN where it promises RST cannot test '
              'half-open recovery at all, and it fails that way invisibly — '
              'the peer still notices something, just the wrong thing');
      expect(outcomes.map(errnoOf).where((code) => code == null), isEmpty,
          reason: 'the errno must narrow out of every error, because '
              'Socket.connect and setRawOption throw bare OSError rather than '
              'SocketException — a harness that cannot read the code crashes '
              'where it meant to report');
    });
  },
      skip: lingerWorks ? null : lingerResetSkipReason);

  // Runs everywhere, and is the only arm in this file that must: it is the one
  // that judges the gate the others hang from. The reset group is skipped where
  // the probe says no, so nothing inside it can notice a probe that says yes on
  // a platform where forceReset sends a FIN — which is exactly what happened on
  // the first CI run, when the probe asked whether the kernel accepted
  // SO_LINGER rather than whether the peer saw a reset. Windows accepts the
  // option and still cannot reset, because dart:io calls shutdown(SD_BOTH)
  // before closing, and three arms failed there for a platform difference
  // nobody had measured.
  group('the probe and the primitive agree', () {
    test('a peer observes an error here exactly when the probe says it will',
        () async {
      final pair = await _loopbackPair();
      final seen = _peerOutcome(pair.near);
      forceReset(pair.far);
      final outcome = await within(
        seen,
        'the peer of a forceReset reached a terminal state',
        budget: const Duration(seconds: 2),
      );

      print('forceReset on ${Platform.operatingSystem}: probe says '
          '$lingerWorks, peer saw ${outcome ?? 'a clean end'}');

      expect(
        outcome != null,
        lingerWorks,
        reason: 'lingerResetSupported() answered $lingerWorks and the peer '
            '${outcome == null ? 'ended cleanly' : 'got $outcome'}. The probe '
            'is a gate: every arm asserting a peer-observable reset is skipped '
            'when it says no and run when it says yes, so a probe that answers '
            'a *different* question than its callers ask cannot be caught by '
            'any of them. A probe that only checks whether setRawOption threw '
            'fails here on any platform that accepts SO_LINGER and still sends '
            'a FIN',
      );
    });
  });

  group('the clean-close contrast', () {
    test('destroy() alone ends the peer cleanly — it is not a reset', () async {
      final pair = await _loopbackPair();
      final seen = _peerOutcome(pair.near);
      pair.far.destroy();

      expect(
          await within(seen, 'the peer noticed the destroy()',
              budget: const Duration(seconds: 2)),
          isNull,
          reason: 'destroy() sends a FIN on POSIX, so a killOnce mode built on '
              'it would be testing an orderly shutdown while its name promises '
              'a cut cable — this is the assertion that stops forceReset from '
              'being quietly replaced by the simpler call');
    });

    test('close() ends the peer cleanly too, even with linger set', () async {
      final pair = await _loopbackPair();
      final seen = _peerOutcome(pair.near);
      await pair.far.close();

      expect(
          await within(seen, 'the peer noticed the close()',
              budget: const Duration(seconds: 2)),
          isNull,
          reason: 'close() ignores SO_LINGER, which is why forceReset must end '
              'in destroy(); an implementation that switched to close() would '
              'stop resetting and nothing else here would notice');
    });
  });

  group('capability probes', () {
    test('each answers with a non-empty reason, and none of them prompt',
        () async {
      final probes = <String, Future<Capability> Function()>{
        'passwordless sudo': hasPasswordlessSudo,
        'tc': hasTc,
        'dnctl': hasDnctl,
        'pfctl': hasPfctl,
      };

      for (final probe in probes.entries) {
        final capability = await within(
          probe.value(),
          'the ${probe.key} probe answered',
          // Generous on purpose. The budget is not measuring speed here: a
          // probe that prompted for a password would never return at all, so
          // returning within any budget is the proof of non-interactivity.
          budget: const Duration(seconds: 5),
        );
        expect(capability.reason, isNotEmpty,
            reason: 'the ${probe.key} probe must say which half of the check '
                'decided the answer, because that string becomes the Skip() an '
                'engineer reads on CI — "unavailable" tells them nothing about '
                'whether the machine or the invocation is at fault');
      }
    });

    test('a second ask is served from cache, not from another process',
        () async {
      await hasPasswordlessSudo();
      final stopwatch = Stopwatch()..start();
      await hasPasswordlessSudo();
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(50),
          reason: 'an oslevel suite asks these questions once per test, and a '
              'sudo invocation per case turns a probe into the slowest thing '
              'in the run');
    });
  });
}
