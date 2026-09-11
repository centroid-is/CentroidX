/// Injected latency, measured as a round trip, with an **additive** tolerance.
///
/// RESEARCH Finding 6 measured this mode's overhead directly:
///
/// | Configured per direction | RTT min / avg / max | Ideal RTT |
/// |---|---|---|
/// | 50 ms  | 102 / 104.8 / 109 ms  | 100 ms  |
/// | 200 ms | 404 / 404.7 / 405 ms  | 400 ms  |
/// | 500 ms | 1004 / 1004.6 / 1005 ms | 1000 ms |
///
/// The overhead is a small constant — 1 to 2.5 ms per direction — and not a
/// proportion of the configured delay. That is the whole reason every timing
/// assertion in this file is `inInclusiveRange(2 * d, 2 * d + _slack)` and never
/// a proportional band: a band of one twentieth is 5 ms at 50 ms, which is
/// tighter than the measured overhead and fails on a good day, and 25 ms at
/// 500 ms, which is looser than the overhead and would pass a mode that had
/// quietly stopped injecting anything. The slack is widened from the measured
/// 4-9 ms to 20 ms for CI hardware (Assumption A5), and it is the same slack
/// at both delays on purpose. It is 75 ms rather than 20 off Linux, where the
/// runners are shared and noisy — see [_slack] for why that is a statement
/// about the hardware and not a loosened assertion.
///
/// **What this mode is for.** Phase 7's F19 and F20 are slow-link scenarios;
/// their precondition is a proxy that can add a known one-way delay to a live
/// connection without disturbing anything else about it. So this file asserts
/// two things that are easy to forget in a timing test: that the delayed bytes
/// still all arrive, in order, and that setting the lever on an *already open*
/// connection changes that connection. A latency mode that only works when set
/// before connect cannot express "the link degrades at minute three", which is
/// the shape every one of those scenarios takes.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The additive slack every timing assertion in this file allows.
///
/// Finding 6 measured 2-9 ms of total round-trip overhead across 50, 200 and
/// 500 ms. It is a constant because the overhead is a constant, and it is
/// additive rather than proportional for the reason the library doc gives.
///
/// **Two values, by platform, and the Linux one is the real bound.** 20 ms is
/// Finding 6's measurement roughly doubled twice over, and it is what the
/// Linux leg keeps: that leg runs on the runner this phase's numbers were
/// taken against, and its resolution is what would notice a mode that had
/// quietly stopped injecting most of its delay. The hosted macOS and Windows
/// runners are neither quiet nor dedicated — `dart_test.yaml`'s
/// `concurrency: 1` removes this suite's self-inflicted noise and nothing
/// about a noisy neighbour — and tens of milliseconds of event-loop jitter
/// there is ordinary. At 20 ms those legs would go red about the runner while
/// naming the latency mode, which is the expensive kind of noise: it trains
/// people to re-run CI. 75 ms is wide enough for that jitter and still far
/// under the smallest delay this file injects, so a mode that stopped
/// injecting is caught on every leg.
final _slack = Platform.isLinux
    ? const Duration(milliseconds: 20)
    : const Duration(milliseconds: 75);

/// What a round trip may come in *under* the ideal by, and why the band was
/// one-sided before.
///
/// The ceiling above carries a platform-sized allowance and the floor carried
/// **none**: it was exactly `2 * latency`, so any measurement landing a hair
/// below the ideal failed. The first CI run of this suite produced exactly
/// that — **99,845 µs against a 100,000 µs floor, short by 155 µs** — and the
/// message blamed a delay "not applied to both directions", which was not what
/// happened. The stopwatch and the two `Future.delayed` calls do not share an
/// origin, so the observed total can round marginally under the sum.
///
/// **Two milliseconds is derived, not tuned.** The floor exists to catch a
/// missing direction, which at this file's smallest injected delay is a **50 ms**
/// shortfall — twenty-five times this allowance. So the arm still catches every
/// failure it was written for, with the same margin it always had, and stops
/// failing on measurement granularity it was never meant to judge.
const _floorSlack = Duration(milliseconds: 2);

/// The delay the headline arm injects, and the one the live-mutability arm
/// switches on mid-connection.
const _longDelay = Duration(milliseconds: 200);

/// The second delay, an order of magnitude apart from [_longDelay].
///
/// Two arms far apart are what distinguish an additive tolerance from a
/// proportional one: a proportional band wide enough for 50 ms is far too wide
/// at 200 ms, and the same slack passing at both is the evidence.
const _shortDelay = Duration(milliseconds: 50);

/// The jitter arm's spread, redrawn per chunk and per direction.
const _jitterSpread = Duration(milliseconds: 30);

/// How many round trips the jitter arm samples.
///
/// Enough that two identical readings mean "the jitter is not being drawn"
/// rather than "the dice came up the same twice".
const _jitterSamples = 8;

/// The ceiling the live-mutability arm holds its *undelayed* round trip to.
///
/// Loopback through the proxy measures a millisecond or two. The ceiling is
/// far above that and far below the 400 ms the same connection must show after
/// the lever is set, so the arm cannot pass by both readings being slow —
/// which is the property being kept, and the reason 150 ms off Linux is still
/// a ceiling rather than a formality. The first round trip of the file pays
/// for a cold-start JIT compile of the whole pump path, and on a loaded
/// Windows runner that alone can approach 100 ms.
final _undelayedCeiling = Platform.isLinux
    ? const Duration(milliseconds: 100)
    : const Duration(milliseconds: 150);

/// A payload small enough to cross as one chunk in each direction.
///
/// The measurement is of the delay, not of serialisation: a payload big enough
/// to need several chunks would pipeline through the line and measure the last
/// chunk's delay plus the transfer, which is a different number.
const _probeBytes = 64;

/// The integrity arm's payload — many chunks, all of them delayed.
const _integrityBytes = 256 * 1024;

const _connectBudget = Duration(seconds: 5);
const _arrivalBudget = Duration(seconds: 30);
const _chunkBytes = 64 * 1024;

void main() {
  test('delays a round trip by twice the per-direction latency, at 200 ms',
      () async {
    await _expectAdditiveRoundTrip(_longDelay);
  });

  test('delays a round trip by twice the per-direction latency, at 50 ms — '
      'the same additive slack, not a proportional one', () async {
    await _expectAdditiveRoundTrip(_shortDelay);
  });

  test('jitter varies successive round trips, and every one still lands in '
      'the band', () async {
    final link = await _link();
    link.proxy.latency = _shortDelay;
    link.proxy.jitter = _jitterSpread;

    final samples = <Duration>[];
    for (var i = 0; i < _jitterSamples; i++) {
      samples.add(await link.roundTrip(_pattern(_probeBytes)));
    }
    print('latency ${_shortDelay.inMilliseconds} ms with jitter '
        '${_jitterSpread.inMilliseconds} ms: round trips '
        '${samples.map((s) => s.inMilliseconds).join(', ')} ms');

    // Two directions, so the extra is drawn twice: the upper bound is the
    // ideal round trip plus two full spreads plus the constant overhead.
    final floor = _shortDelay * 2 - _floorSlack;
    final ceiling = _shortDelay * 2 + _jitterSpread * 2 + _slack;
    for (final rtt in samples) {
      // Compared in microseconds because `inInclusiveRange` is a numeric
      // matcher: the bounds are still the additive Durations above, and the
      // reason below states them in the milliseconds a reader thinks in.
      expect(rtt.inMicroseconds,
          inInclusiveRange(floor.inMicroseconds, ceiling.inMicroseconds),
          reason: 'a round trip took ${rtt.inMilliseconds} ms, outside '
              '${floor.inMilliseconds}-${ceiling.inMilliseconds} ms. Jitter '
              'widens the band; it does not license a delay shorter than the '
              'one configured, and a delay longer than the spread is a queue '
              'that stalled rather than a die that rolled high');
    }
    expect(samples.map((s) => s.inMilliseconds).toSet().length, greaterThan(1),
        reason: 'all $_jitterSamples round trips measured the same whole '
            'millisecond, so the jitter is not being redrawn — a fixed extra '
            'delay is just a different latency, and the scenarios that ask '
            'for jitter are asking for the variance itself');
  });

  test('delivers every byte, in order, through a non-trivial delay', () async {
    final link = await _link();
    link.proxy.latency = _shortDelay;
    final payload = _pattern(_integrityBytes);

    await link.roundTrip(payload);
    final echoed = link.takeReceived();

    expect(echoed.length, payload.length,
        reason: 'the delayed link returned ${echoed.length} of '
            '${payload.length} bytes. A latency mode that also drops bytes '
            'makes every downstream test attribute the loss to the wrong '
            'cause: F19 would read as a protocol bug under a slow link when '
            'what it found was the harness eating a chunk');
    final firstDifference = _firstDifference(echoed, payload);
    expect(firstDifference, -1,
        reason: 'byte $firstDifference differs, so the delayed link reordered '
            'or corrupted the stream. Chunks held back for their deadline must '
            'come out in the order they went in, or the delay line has become '
            'a reordering fault nobody asked for');
  });

  test('changes the behaviour of a connection that is already open', () async {
    final link = await _link();

    final undelayed = await link.roundTrip(_pattern(_probeBytes));
    expect(undelayed, lessThan(_undelayedCeiling),
        reason: 'the untouched proxy already took ${undelayed.inMilliseconds} '
            'ms for a $_probeBytes-byte round trip, so the reading below '
            'proves nothing about the lever — something other than latency is '
            'slow on this rig');

    link.proxy.latency = _longDelay;
    final delayed = await link.roundTrip(_pattern(_probeBytes));
    print('live mutation: ${undelayed.inMilliseconds} ms before, '
        '${delayed.inMilliseconds} ms after setting '
        '${_longDelay.inMilliseconds} ms per direction');

    expect(
      delayed.inMicroseconds,
      // `- _floorSlack`, like `_expectAdditiveRoundTrip` and the short-delay
      // arm. This arm was the one place the derived floor allowance never
      // reached, and CI found it exactly the way the constant's own doc
      // predicts: **399,612 us against a 400,000 us floor, short by 388 us**,
      // with the message blaming a direction that had not gone missing. The
      // stopwatch and the two `Future.delayed` calls do not share an origin,
      // so the observed total can round marginally under the sum. Two
      // milliseconds still catches the failure this floor exists for — a
      // missing direction is a 200 ms shortfall here, a hundred times the
      // allowance.
      inInclusiveRange((_longDelay * 2 - _floorSlack).inMicroseconds,
          (_longDelay * 2 + _slack).inMicroseconds),
      reason: 'the same socket measured ${delayed.inMilliseconds} ms after '
          'latency was set on the running proxy. The lever has to reach the '
          'connections that are already open, or no scenario can express "the '
          'link degrades while the client is connected" — which is the only '
          'shape F19 and F20 come in, since a client that was never connected '
          'has nothing to degrade',
    );
  });
}

/// Sets [d] on a fresh link and asserts the round trip is `2d` plus [_slack].
Future<void> _expectAdditiveRoundTrip(Duration d) async {
  final link = await _link();

  // **The link's own cost, measured on this link, before any delay is set.**
  //
  // The band below is about the delay this proxy *injects*, and comparing a
  // delayed round trip against `2d` alone silently folds in whatever the
  // undelayed round trip costs on this machine. That is about a millisecond on
  // a developer's laptop and tens of milliseconds on a hosted agent:
  // `relay-packages-test (windows-latest)` measured 184 ms against a 175 ms
  // ceiling at d=50 ms, so 84 ms of it was the runner and only 100 ms was the
  // lever.
  //
  // Widening the slack is not available as a fix. It has to stay under the
  // smallest ideal round trip this file produces (100 ms, at d=50 ms) or a
  // proxy that doubled its delay instead of adding it would pass the ceiling —
  // which is the one thing the ceiling is for. Subtracting the baseline
  // removes the runner from the comparison instead of making room for it, and
  // leaves the slack covering jitter, which is what it was sized for.
  final baseline = await link.roundTrip(_pattern(_probeBytes));

  link.proxy.latency = d;

  final measured = await link.roundTrip(_pattern(_probeBytes));
  final rtt = measured - baseline;
  // Printed as well as asserted: a CI failure that reads "412 ms" says the
  // rig was slow, and one that reads "3 ms" says the mode did not engage.
  // The assertion alone cannot tell those apart.
  print('latency ${d.inMilliseconds} ms per direction: round trip '
      '${measured.inMilliseconds} ms less a ${baseline.inMilliseconds} ms '
      'undelayed baseline = ${rtt.inMilliseconds} ms attributable to the lever '
      '(ideal ${(d * 2).inMilliseconds} ms)');

  // Microseconds because `inInclusiveRange` is a numeric matcher; the bounds
  // are the additive Durations, never a proportion of `d`.
  expect(
    rtt.inMicroseconds,
    inInclusiveRange((d * 2 - _floorSlack).inMicroseconds,
        (d * 2 + _slack).inMicroseconds),
    reason: 'a round trip through a proxy delaying ${d.inMilliseconds} ms per '
        'direction took ${rtt.inMilliseconds} ms, outside '
        '${(d * 2).inMilliseconds}-${(d * 2 + _slack).inMilliseconds} ms. '
        'Below the floor means the delay was not applied to both directions; '
        'above the ceiling by more than the constant scheduler overhead means '
        'something is queueing rather than delaying',
  );
}

/// A client, a proxy and an echo server, all torn down with the test.
Future<_Link> _link() async {
  final echo = await _echoServer();
  final proxy = FaultProxy(targetPort: echo.port);
  await proxy.start();
  addTearDown(proxy.shutdown);

  final socket = await within(
    Socket.connect(InternetAddress.loopbackIPv4, proxy.port),
    'the client reached the proxy on port ${proxy.port}',
    budget: _connectBudget,
  );
  addTearDown(socket.destroy);
  unawaited(socket.done.catchError((Object _) => socket));
  return _Link(proxy, socket);
}

/// One client socket through one proxy, with a timed round trip.
final class _Link {
  _Link(this.proxy, this.socket) {
    socket.listen(
      _onData,
      // A destroyed socket at teardown reports both of these, and an
      // unhandled one lands on whichever test is running at the time.
      onError: (Object _) {},
      onDone: () {},
    );
  }

  final FaultProxy proxy;
  final Socket socket;

  final BytesBuilder _received = BytesBuilder(copy: false);
  int _target = -1;
  Completer<void>? _waiting;

  /// Everything received so far, emptying the buffer.
  Uint8List takeReceived() => _received.takeBytes();

  /// Writes [payload] and returns how long its echo took to come back.
  ///
  /// The stopwatch starts before the write and stops when the last byte is
  /// back, so it measures both directions — which is the quantity Finding 6
  /// tabulated, and the one an operator experiences.
  Future<Duration> roundTrip(Uint8List payload) async {
    final want = _received.length + payload.length;
    final arrived = _waitFor(want);
    final elapsed = Stopwatch()..start();
    for (var offset = 0; offset < payload.length; offset += _chunkBytes) {
      final end = min(offset + _chunkBytes, payload.length);
      socket.add(Uint8List.sublistView(payload, offset, end));
      await socket.flush();
    }
    await within(arrived, 'the echo of ${payload.length} bytes came back',
        budget: _arrivalBudget);
    elapsed.stop();
    return elapsed.elapsed;
  }

  Future<void> _waitFor(int bytes) {
    if (_received.length >= bytes) return Future<void>.value();
    _target = bytes;
    return (_waiting ??= Completer<void>()).future;
  }

  void _onData(Uint8List data) {
    _received.add(data);
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted && _received.length >= _target) {
      _waiting = null;
      waiting.complete();
    }
  }
}

/// A loopback echo server that gates its own writes and destroys what it
/// accepted.
///
/// Ungated, the echo server would buffer inside its own `dart:io` sink and the
/// round trip would measure that instead of the injected delay.
Future<ServerSocket> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = <Socket>[];
  addTearDown(() {
    for (final socket in accepted) {
      socket.destroy();
    }
  });

  final accepts = server.listen((socket) {
    accepted.add(socket);
    unawaited(socket.done.catchError((Object _) => socket));
    late final StreamSubscription<Uint8List> echoing;
    echoing = socket.listen(
      (data) {
        socket.add(data);
        echoing.pause(socket.flush().catchError((Object _) {}));
      },
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
    );
  });
  addTearDown(accepts.cancel);
  return server;
}

/// A deterministic pattern whose shifts are visible.
///
/// A run of zeroes would let a link that dropped a chunk still compare equal.
Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}

/// The index of the first differing byte, or -1 when the prefixes match.
///
/// Compared by index rather than by `expect(a, b)` so a failure names one
/// offset instead of printing a quarter of a megabyte of hex into the CI log.
int _firstDifference(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : shared;
}
