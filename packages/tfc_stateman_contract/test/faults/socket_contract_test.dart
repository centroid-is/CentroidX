/// The contract, judged over a real TCP socket, through the fault proxy.
///
/// The channel harness proves the contract survives a message boundary. It does
/// not prove the contract survives a *network*: a `StreamChannelController`
/// delivers on a microtask, never fragments a message, never reorders a close
/// against the data in front of it, and cannot be blackholed. Everything the
/// fault kit exists to inject needs a descriptor to inject it into.
///
/// So this file runs the same sub-suites the channel harness runs, against the
/// same client, over a loopback socket that goes through a [FaultProxy]. Four
/// separate claims, one group each:
///
///  * **Framing.** A JSON message split across two TCP segments arrives whole.
///    This is the one property the channel harness could never have tested,
///    because a controller has no segments.
///  * **The contract.** Subscribe, read and write, unmodified, through the
///    socket leg with the proxy passing traffic through.
///  * **The bite.** With `blackhole()` pulled, named value-path checks fail —
///    the socket leg's answer to `channel_bite_test.dart`'s severed channel. A
///    harness that quietly handed back a local object would pass the group
///    above and fail here, which is the only reason the group above is worth
///    anything.
///  * **Hygiene.** Twenty build/teardown cycles of the whole harness leave the
///    process's open-socket count where they found it. 02-02 established the
///    criterion against the bare proxy; a harness that stacks a server socket
///    and two peers on top of each proxied pair is where it actually gets
///    tested.
@Tags(['faults', 'contract'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// Carried across from `channel_write_contract_test.dart` verbatim, so the
/// write sub-suite is configured identically on both legs. A socket leg that
/// judged a different set of cases would make the parity sweep meaningless.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

/// How long the harness is given to bind, start the proxy and connect.
///
/// Generous: this is loopback, so it is milliseconds in practice, and the
/// budget exists to turn a wedged connect into a named failure rather than a
/// runner timeout.
const _connectBudget = Duration(seconds: 2);

/// How long a blackholed check is given to notice.
///
/// Deliberately tighter than [expectContractViolation]'s two-second default and
/// matched to `channel_bite_test.dart`: every await inside these cases is
/// wrapped in a 200 ms `within`, so a violation that takes longer than this is
/// one that escaped a deadline rather than one the fault caused.
const _biteBudget = Duration(milliseconds: 800);

/// How many harness build/teardown cycles the hygiene arm runs.
const _harnessCycles = 20;

/// Cycles run before the baseline is taken.
///
/// The first connection in a process allocates things that are never freed
/// because they were never per-connection — a resolver cache, the proxy's
/// first accept path. Counting before those exist reads them as this harness's
/// leak.
const _warmupCycles = 3;

/// How long the kernel is given to finish closing descriptors before counting.
///
/// The measurement delay `leak_test.dart` documents at length: `destroy()` is
/// asynchronous with respect to the fd actually closing, and there is no event
/// that says the table has settled.
const _settle = Duration(milliseconds: 250);

void main() {
  group('the framing reassembles what TCP split', () {
    test('a message delivered in two segments arrives as one', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final received = <String>[];
      final both = Completer<void>();
      server.listen((socket) {
        lineChannel(socket).stream.listen(
          (message) {
            received.add(message);
            if (received.length == 2 && !both.isCompleted) both.complete();
          },
          // Required, not defensive. This arm destroys its client, and a
          // destroyed peer reaches the served socket as an error on the read
          // stream — with no handler it becomes an unhandled async error and
          // package:test attributes it to whichever case is running by then,
          // which here is a contract case forty lines away that has nothing
          // to do with framing.
          onError: (Object _) {},
        );
      });

      final client =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      addTearDown(client.destroy);

      const whole = '{"jsonrpc":"2.0","method":"split","id":1}';
      const half = 12;
      client.add(utf8.encode(whole.substring(0, half)));
      await client.flush();
      // The split itself, not synchronisation: the point of this arm is that
      // the adapter reassembles a message the kernel handed it in two pieces,
      // and the only way to guarantee two pieces on loopback is to leave a gap
      // between them. Nothing below depends on how long the gap was.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      client.add(utf8.encode('${whole.substring(half)}\n'));
      client.add(utf8.encode('{"second":true}\n'));
      await client.flush();

      await within(both.future, 'both framed messages arriving',
          budget: _connectBudget);
      expect(received, [whole, '{"second":true}'],
          reason: 'the adapter delivered ${received.length} message(s) — '
              '$received. The first was written as two TCP segments and must '
              'arrive as one message; the second shared a segment with the '
              'tail of the first and must arrive as a second. A framer that '
              'treats one read as one message breaks a JSON-RPC session at '
              'the first payload larger than a segment, which is every '
              'browse response');
    });
  });

  group('the contract, over a socket, through the proxy', () {
    runSubscribeContract(socketServedFake);
    runReadContract(socketServedFake);
    runWriteContract(socketServedFake, readOnlyKey: _readOnlyKey);
  });

  group('a proxy lever bites what severing a channel bites', () {
    test('the current value is no longer delivered on subscription', () async {
      await _expectBlackholed(checkListenDeliversCurrentValue,
          reason: 'blackholing the proxy left `listen` still delivering a '
              'current value, so the value came from somewhere other than the '
              'served source — the harness is handing back a local object and '
              'the sub-suites above prove nothing about a network');
    });

    test('subsequent changes no longer arrive', () async {
      await _expectBlackholed(checkListenDeliversSubsequentChanges,
          reason: 'blackholing the proxy left updates arriving, so the update '
              'path is not the socket');
    });

    test('the subscribe stream no longer mirrors listen', () async {
      await _expectBlackholed(checkSubscribeStreamMirrorsListen,
          reason: 'blackholing the proxy left the subscribe stream producing '
              'values, so that stream is not fed from the served source');
    });

    test('an unknown key no longer reports a config error', () async {
      await _expectBlackholed(checkUnknownKeyReportsConfigErrorNotThrow,
          reason: 'blackholing the proxy left the unknown-key verdict arriving, '
              'so the verdict is decided on this side of the socket rather than '
              'by the source that owns the key space');
    });
  });

  group('the harness leaves no descriptors behind', () {
    test('$_harnessCycles build/teardown cycles return the count to baseline',
        () async {
      for (var i = 0; i < _warmupCycles; i++) {
        await _cycle();
      }
      final baseline = await _countAfterSettle();
      for (var i = 0; i < _harnessCycles; i++) {
        await _cycle();
      }
      final after = await _countAfterSettle();

      expect(after - baseline, 0,
          reason: 'the open-socket count went from $baseline to $after over '
              '$_harnessCycles harness cycles — ${after - baseline} '
              'descriptor(s), about '
              '${((after - baseline) / _harnessCycles).toStringAsFixed(2)} per '
              'cycle. Each cycle opens a listening socket, an accepted server '
              'peer, a client socket and the proxy\'s two, so a per-cycle '
              'remainder names how many of the five the teardown misses. A '
              'harness that leaks one fd per case exhausts the table partway '
              'through a suite and fails as a connect error somewhere else');
    }, skip: canCountOpenSockets ? null : openSocketCountSkipReason);
  });
}

/// Builds a socket-served source, blackholes the proxy in front of it, and
/// asserts [check] reports the violation.
///
/// The lever is pulled after the harness is connected, so the failure is
/// traffic vanishing on an established session rather than a connect that
/// never happened — the same distinction `blackhole_test.dart` draws, applied
/// to a contract case instead of to an echo.
Future<void> _expectBlackholed(
  Check<StateManApi> check, {
  required String reason,
}) async {
  final harness = serveFakeOverSocket();
  addTearDown(harness.api.dispose);
  await within(harness.ready, 'the socket harness connecting',
      budget: _connectBudget);
  harness.proxy.blackhole();
  try {
    await expectContractViolation(check, harness.api, budget: _biteBudget);
  } on TestFailure catch (failure) {
    fail('$reason\n\n${failure.message}');
  }
}

/// One full build and teardown of the socket harness.
Future<void> _cycle() async {
  final harness = serveFakeOverSocket();
  await within(harness.ready, 'the socket harness connecting',
      budget: _connectBudget);
  await harness.api.dispose();
}

/// Counts open socket descriptors, after letting the kernel catch up.
Future<int> _countAfterSettle() async {
  await Future.delayed(_settle);
  return openSocketCount();
}
