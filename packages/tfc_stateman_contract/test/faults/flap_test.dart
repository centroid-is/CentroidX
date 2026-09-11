/// The link going down and coming back, on a timer — F2, in the operator's
/// own words.
///
/// The description this project started from was "a dropout every other
/// second" on the plant floor. That is `flap(1s, 1s)`, and the main arm below
/// is that sentence executed: sixty seconds of it, a client that reconnects
/// the way the real one does, and three aggregates read at the end.
///
/// **Every assertion here is an aggregate over a window, and that is a rule
/// rather than a style.** RESEARCH Finding 10 measured a connect attempt
/// completing on the far side of a state transition — `t=1204ms
/// forwarding=false connect OK in 189ms` — so a flag read at assertion time
/// does not describe what the connection experienced. An instantaneous
/// assertion against a flapping proxy is not merely flaky; it is measuring a
/// different thing from the one it names, and the next person to see it fail
/// relaxes the bound rather than the timing (02-PATTERNS anti-pattern table,
/// last two rows). So: counts over a minute, survival across a full cycle,
/// and a transition counter compared before and after — never
/// `expect(somethingIsUpRightNow, …)`.
///
/// **What the three aggregates are for.** Reconnect attempts under a bound
/// catches the hot retry loop — a client spinning on connect for a minute
/// looks identical to a healthy one if you only count the successes. An empty
/// escaped-error collector catches the async error that lands after this test
/// has finished and fails an unrelated one. And `peakPendingBytes` catches the
/// proxy that accumulates a little state per cycle, which thirty cycles will
/// show and one will not.
///
/// **Budget.** About seventy seconds, nearly all of it the soak. F2 asks for
/// sixty and the number is in the criterion, so it is not shortened here; the
/// two hygiene arms beside it are sub-second by comparison and use a 200 ms
/// cycle rather than the operator's 1 s.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

/// F2's cycle: the dropout every other second, as the operator described it.
const _up = Duration(seconds: 1);
const _down = Duration(seconds: 1);

/// How long the soak runs. F2 names sixty seconds; this is that number.
const _soak = Duration(seconds: 60);

/// The cycle the two hygiene arms use.
///
/// Short on purpose: they are about the timer's lifetime, not about the
/// operator's scenario, and a 200 ms cycle proves the same property in a
/// fiftieth of the time.
const _shortUp = Duration(milliseconds: 200);
const _shortDown = Duration(milliseconds: 200);

/// How long the client waits after a failed or lost connection.
///
/// The bound below is derived from this number, so the two must move together:
/// a client that retried instantly would make any attempt bound arbitrary.
const _retryBackoff = Duration(milliseconds: 250);

/// How often the connected client speaks.
const _probeInterval = Duration(milliseconds: 250);

const _probeBytes = 64;

/// The ceiling on reconnect attempts over the soak.
///
/// Derived, not guessed: with [_retryBackoff] between attempts a client cannot
/// honestly try more than `_soak / _retryBackoff` times, and the slack covers
/// the attempts that succeed and return immediately. What it catches is the
/// failure mode worth catching — a reconnect loop with no backoff, which
/// against thirty down-windows produces attempts in the thousands.
final _attemptBound =
    _soak.inMilliseconds ~/ _retryBackoff.inMilliseconds + 20;

/// The fewest dropouts a minute of `flap(1s, 1s)` may produce.
///
/// Thirty are expected. Twenty is the floor, because the assertion exists to
/// catch a flap that never flapped, and a runner slow enough to lose a third
/// of the cycles is a different failure with a different message.
const _minDrops = 20;

/// The fewest echoes that must have crossed the link during the up-windows.
///
/// Without this, a proxy that simply stayed down for sixty seconds would
/// satisfy every other aggregate in the arm.
const _minEchoes = 20;

const _connectBudget = Duration(seconds: 5);

void main() {
  test(
      'a dropout every other second for a full minute: the client survives, '
      'its retries stay bounded, and nothing escapes — F2', () async {
    final rig = await _Rig.open();
    final escaped = <String>[];
    final client = _ReconnectingClient(rig.proxy.port);

    rig.proxy.flap(_up, _down);
    final run = Stopwatch()..start();
    await _guarded(escaped, () async {
      unawaited(client.run());
      // The soak is the experiment, not synchronisation: the property is what
      // sixty seconds of flapping does to a client, so sixty seconds have to
      // pass. There is no event that means "a minute of dropouts happened".
      await Future<void>.delayed(_soak);
      await client.stop();
    });
    run.stop();
    rig.proxy.flap(_up, _down, enabled: false);

    // Printed as well as asserted: "148 attempts, 30 drops" is the mode
    // working, "1 attempt, 0 drops" is a flap that never fired, and
    // "3200 attempts" is a client spinning. The assertions can tell the first
    // from the others, but only the numbers say which of the others it was.
    print('flap(${_up.inSeconds}s, ${_down.inSeconds}s) for '
        '${run.elapsed.inMilliseconds} ms: ${client.attempts} connect '
        'attempts, ${client.connects} connected, ${client.drops} dropouts, '
        '${client.echoes} echoes, ${rig.proxy.flapTransitions} transitions, '
        'peak pending ${rig.proxy.peakPendingBytes} bytes');

    expect(escaped, isEmpty,
        reason: 'an error escaped the zone during the soak. This is the one '
            'failure that does not stay in its own test: an async error with '
            'no handler is reported against whichever case happens to be '
            'running when it lands, so a flap that leaks one turns a green '
            'suite into a suite with a wandering red — and the case it fails '
            'is never this one');
    expect(client.drops, greaterThanOrEqualTo(_minDrops),
        reason: 'the client saw ${client.drops} dropouts in a minute of '
            'flap(1s, 1s), where thirty were due. Under $_minDrops means the '
            'link was not actually cycling, and every other aggregate in this '
            'arm passes trivially against a proxy that never flapped');
    expect(client.echoes, greaterThanOrEqualTo(_minEchoes),
        reason: 'only ${client.echoes} probes came back, so the up-windows '
            'were not forwarding. A mode that goes down and stays down is not '
            'a flap, and it satisfies the drop count and the attempt bound '
            'without ever restoring the link');
    expect(client.attempts, lessThan(_attemptBound),
        reason: 'the client made ${client.attempts} connect attempts against '
            'a bound of $_attemptBound. The bound is '
            '`soak / backoff + slack`, so exceeding it means attempts were '
            'made faster than the backoff allows — the hot reconnect loop '
            'F2 exists to rule out, which on a real plant floor is a client '
            'that hammers a recovering PLC exactly when it can least afford '
            'it');
    expect(rig.proxy.peakPendingBytes, lessThan(defaultHighWaterBytes),
        reason: 'the proxy queued ${rig.proxy.peakPendingBytes} bytes against '
            'a high-water mark of $defaultHighWaterBytes, while carrying '
            '$_probeBytes-byte probes. The traffic here cannot fill a queue, '
            'so anything approaching the mark is per-cycle state accumulating '
            'across thirty teardowns rather than traffic in flight');

    await _until(() => rig.proxy.livePairs == 0,
        budget: const Duration(seconds: 5));
    expect(rig.proxy.livePairs, isZero,
        reason: 'the proxy still holds ${rig.proxy.livePairs} pairs after the '
            'client stopped. Thirty cycles of tearing pairs down is exactly '
            'where the descriptor leak Finding 11 measured would come back, '
            'and `leak_test.dart` counts descriptors while this counts pairs '
            '— the pair is the one that says which cycle lost it');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('turning flap off leaves the link up, whichever half of the cycle it '
      'stopped in', () async {
    final rig = await _Rig.open();
    rig.proxy.flap(_shortUp, _shortDown);
    // Stopped in the *down* half deliberately: the first transition is the one
    // that takes the link down, so this is the half where "off" is ambiguous.
    // A lever that merely cancelled its timer would leave the proxy black and
    // every scenario after the flap would fail for the wrong reason.
    await _until(() => rig.proxy.flapTransitions >= 1,
        budget: const Duration(seconds: 5));
    rig.proxy.flap(_shortUp, _shortDown, enabled: false);

    final client = await _connect(rig.proxy.port);
    final closed = Completer<void>();
    final replies = BytesBuilder(copy: false);
    client.listen(replies.add,
        onError: (Object _) => _complete(closed),
        onDone: () => _complete(closed),
        cancelOnError: true);
    addTearDown(client.destroy);

    // Longer than a whole cycle, which is the window this arm is about: a
    // timer still running would have taken the link down and back inside it.
    final aFullCycle = _shortUp + _shortDown + const Duration(milliseconds: 300);
    client.add(_pattern(_probeBytes));
    await client.flush();
    await Future<void>.delayed(aFullCycle);

    expect(closed.isCompleted, isFalse,
        reason: 'the connection ended inside ${aFullCycle.inMilliseconds} ms '
            'of a flap that had been turned off, which is longer than a full '
            'cycle — so the cycle was still running');
    expect(replies.length, _probeBytes,
        reason: 'the link carried ${replies.length} of $_probeBytes bytes '
            'across a full cycle after the flap was turned off. Off has to '
            'mean forwarding, not "stopped wherever it happened to be"');
  });

  test('cancels its timers on shutdown, so a flapping proxy cannot outlive '
      'its test', () async {
    final rig = await _Rig.open();
    rig.proxy.flap(_shortUp, _shortDown);
    await _until(() => rig.proxy.flapTransitions >= 3,
        budget: const Duration(seconds: 5));
    final before = rig.proxy.flapTransitions;

    await rig.proxy.shutdown();
    await Future<void>.delayed((_shortUp + _shortDown) * 3);

    expect(rig.proxy.flapTransitions, before,
        reason: 'the transition counter moved from $before to '
            '${rig.proxy.flapTransitions} after shutdown(), so a timer '
            'survived it. The counter is incremented at the top of the timer '
            'callback, ahead of the shutdown guard, for exactly this reading: '
            'a periodic timer nobody cancelled keeps the isolate alive after '
            'its test has passed, and the runner hangs at the end of the '
            'suite with no failure to point at (T-02-31)');
  });
}

/// Runs [body] in a guarded zone, collecting anything that escapes into
/// [escaped].
///
/// The shape `suite_integrity_test.dart:190-208` uses, and for the same
/// reason: an error thrown on a future nobody is awaiting goes to the ambient
/// handler, and in a test isolate that means it fails an unrelated case later
/// on. Collecting it here attributes it to the run that produced it.
Future<void> _guarded(
    List<String> escaped, Future<void> Function() body) async {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      try {
        await body();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    },
    (error, stack) => escaped.add('${error.runtimeType} — $error'),
  );
  await done.future;
}

/// Polls [condition] until it holds or [budget] runs out.
///
/// Polling rather than sleeping a guessed interval: the caller states the
/// property it is waiting for, and a slow runner costs a few more polls
/// instead of turning into a flake.
Future<void> _until(bool Function() condition,
    {required Duration budget}) async {
  final deadline = Stopwatch()..start();
  while (!condition() && deadline.elapsed < budget) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _complete(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

/// A client that reconnects the way the real one does, and counts what happened.
///
/// Deliberately not a smart client: fixed backoff, one probe every
/// [_probeInterval], no jitter. The bound this file asserts is derived from
/// the backoff, and a client with an adaptive policy would make the bound a
/// statement about the client instead of about the proxy.
final class _ReconnectingClient {
  _ReconnectingClient(this.port);

  final int port;

  /// Every `Socket.connect` call, successful or not.
  int attempts = 0;

  /// The ones that returned a socket.
  int connects = 0;

  /// Connections that ended without this client asking them to.
  int drops = 0;

  int echoedBytes = 0;

  bool _stopped = false;
  Socket? _socket;

  int get echoes => echoedBytes ~/ _probeBytes;

  Future<void> run() async {
    while (!_stopped) {
      attempts++;
      final Socket socket;
      try {
        socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: _connectBudget);
      } catch (_) {
        // A refused or reset connect during a down-window is the mode
        // working, not an error: Finding 8 measured both outcomes from
        // consecutive attempts against one proxy.
        await Future<void>.delayed(_retryBackoff);
        continue;
      }
      if (_stopped) {
        socket.destroy();
        return;
      }
      connects++;
      _socket = socket;
      final ended = Completer<void>();
      // A socket destroyed under a flap completes `done` with an error nobody
      // is waiting for, which is precisely the escaped error the soak asserts
      // is absent — so this client must not be the one producing it.
      unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      socket.listen((data) => echoedBytes += data.length,
          onError: (Object _) => _complete(ended),
          onDone: () => _complete(ended),
          cancelOnError: true);

      while (!_stopped && !ended.isCompleted) {
        try {
          socket.add(_pattern(_probeBytes));
          await socket.flush();
        } catch (_) {
          // Writing into a socket the proxy has just reset. The write path
          // throws both synchronously and on the flush, hence one try around
          // both.
          _complete(ended);
          break;
        }
        await Future.any<void>(
            [Future<void>.delayed(_probeInterval), ended.future]);
      }

      socket.destroy();
      _socket = null;
      if (_stopped) return;
      drops++;
      await Future<void>.delayed(_retryBackoff);
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _socket?.destroy();
    _socket = null;
    // One poll interval, so the run loop notices the flag and returns before
    // the caller reads the counters.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A proxy in front of a fresh echo server, both torn down at the end.
final class _Rig {
  _Rig._(this.proxy);

  final FaultProxy proxy;

  static Future<_Rig> open() async {
    final echo = await _echoServer();
    final proxy = FaultProxy(targetPort: echo.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
    return _Rig._(proxy);
  }
}

Future<ServerSocket> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    socket.listen(
      (data) {
        try {
          socket.add(data);
        } catch (_) {
          // The proxy tore this connection down mid-echo, which is the whole
          // point of the mode under test.
        }
      },
      onError: (Object _) => socket.destroy(),
      onDone: socket.destroy,
      cancelOnError: true,
    );
  });
  addTearDown(server.close);
  return server;
}

Future<Socket> _connect(int port) => Socket.connect(
    InternetAddress.loopbackIPv4, port,
    timeout: _connectBudget);

/// A recognisable payload — not zeroes, which every buffer already is.
Uint8List _pattern(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7 + 13) & 0xff));
