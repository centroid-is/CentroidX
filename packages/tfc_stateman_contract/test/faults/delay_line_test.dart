/// Proof that a stalled consumer cannot make the proxy eat the test host.
///
/// RESEARCH Finding 7 measured the naive proxy — `to.add(data)` and move on —
/// going from 163 MB to **4463 MB** of RSS in four seconds against a consumer
/// whose subscription was paused, because `dart:io`'s `Socket` sink buffers
/// without limit and offers no `bufferedAmount` to notice with. The gated
/// version measured 164 → 181 MB at 4 s and 188 → 193 MB at 12 s, with an
/// internal queue peaking at 1.26 and 1.29 MB against a 1 MiB high-water.
///
/// The two numbers that matter are the pair, not either one alone. A queue
/// that is merely *slower* also looks small at four seconds; what says
/// "bounded" is that twelve seconds does not cost three times as much. So the
/// long arm here asserts the 12 s peak against the 4 s peak, and both assert
/// the bound — which is high-water plus one socket buffer, written as
/// [_expectWithinBound] against the largest chunk the line was actually handed
/// rather than as a constant. See [_rssCeiling] for why the constant this file
/// used to carry was a reading of one machine's kernel.
///
/// What is being defended is the ability to observe a fault at all. Every mode
/// in this phase — latency, throttle, blackhole, flap — parks bytes in this
/// queue while it does its work. An unbounded line means the test host dies of
/// RSS before the fault it was injecting is observed, and the CI failure names
/// the runner rather than the mode.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The absolute ceiling both stalled-consumer arms assert, on top of the exact
/// invariant.
///
/// **Why this is not 4 MiB any more.** The bound is "high-water plus one socket
/// buffer", and the first-ever CI run of this file showed that one socket
/// buffer is not a constant. `dart:io` reads a POSIX socket with `available()`
/// — the whole kernel receive queue in one call — so the chunk that crosses the
/// high-water mark is as large as the kernel let the receive buffer grow. On
/// ubuntu, `net.ipv4.tcp_rmem` tops out at 6 MiB and autotuning reaches it
/// under a firehose, leaving ~3 MiB of usable payload; the three ubuntu
/// failures peaked at 4 213 776, 4 253 341 and 4 325 694 bytes, which is 1 MiB
/// of high-water plus 3.02–3.13 MiB of one read. macOS defaults that buffer to
/// about 408 KB and Windows reads a fixed 64 KiB, so neither platform came
/// close. Confirmed by raising `SO_RCVBUF` on the source socket locally: at
/// 4 MiB the line took a single 5 566 192-byte chunk and peaked at exactly
/// that.
///
/// So the real assertion is the relational one below —
/// `peak < highWater + largestChunk` — which is what the code enforces: the
/// pause is applied synchronously in `_onData`, so at most one chunk can cross
/// the mark. This constant is the second, coarser arm, and it defends a
/// different property: that the host does not die of RSS. RESEARCH's ungated
/// implementation reached 4463 MB in these same four seconds, so any ceiling
/// under a hundred megabytes catches it within the first tenth of a second.
/// 16 MiB is above every plausible kernel maximum — Linux 6 MiB of `tcp_rmem`,
/// macOS 8 MiB of `kern.ipc.maxsockbuf` — plus the 1 MiB high-water, with
/// roughly 1.8x of headroom, and 279 times below what the failure it is here to
/// catch reaches in the same window.
const _rssCeiling = 16 * 1024 * 1024;

/// How long the short stalled-consumer window runs.
const _shortRun = Duration(seconds: 4);

/// How long the long stalled-consumer window runs.
///
/// Three times [_shortRun], which is what makes the comparison meaningful: an
/// unbounded queue grows with time, so tripling the window would triple the
/// peak.
const _longRun = Duration(seconds: 12);

/// The most the twelve-second sample may exceed the four-second one.
///
/// Both samples come from **one** rig, which is the only way this comparison
/// means anything: peak pending bytes vary by a megabyte between rigs
/// depending on how much `dart:io` had already buffered when the pause landed
/// and how the kernel sized that connection's buffers, so two rigs compared
/// against each other measure that variance and fail on a busy machine.
/// Sampled twice in one run, the number is monotonic and the ratio is a
/// statement about growth and nothing else. 1.5x is generous for a queue that
/// fills within the first second and far below the 3x an unbounded one shows
/// over 3x the window.
const _growthAllowance = 1.5;

/// Chunk size the firehose writes.
const _chunkBytes = 64 * 1024;

/// The least the firehose must have pushed for a bounded-memory arm to mean
/// anything.
///
/// Without it, a rig that failed to connect reports a peak of zero and the
/// bound passes vacuously — the same shape of lie RESEARCH Pitfall 2 found in
/// the first leak counter.
const _minimumOffered = 1024 * 1024;

const _connectBudget = Duration(seconds: 5);
const _arrivalBudget = Duration(seconds: 20);

void main() {
  test('carries bytes through intact and in order', () async {
    final rig = await _Rig.open(stalled: false);
    final payload = _pattern(512 * 1024);

    rig.firehose.add(payload);
    await rig.firehose.flush();

    await within(
      rig.receivedAtLeast(payload.length),
      'every byte written into the line came out of the far side',
      budget: _arrivalBudget,
    );

    final received = rig.takeReceived();
    expect(received.length, payload.length,
        reason: 'a line that drops or duplicates bytes turns every later mode '
            'test into a coin flip: cutMidFrame(137) cannot be judged against '
            'a transport that loses bytes on its own');
    final firstDifference = _firstDifference(received, payload);
    expect(firstDifference, -1,
        reason: 'byte $firstDifference differs, so the line reordered or '
            'corrupted the stream — a proxy that does that makes every fault '
            'mode built on it unfalsifiable');
  });

  test('holds its queue under the bound against a consumer that never reads',
      () async {
    final run = await _measureStalledRun(_shortRun, sampleAt: _shortRun);

    expect(run.bytesOffered, greaterThanOrEqualTo(_minimumOffered),
        reason: 'the firehose only managed ${run.bytesOffered} bytes, so the '
            'rig never pressured the line and its peak of ${run.peakAtEnd} '
            'proves nothing — a bounded-memory arm that never applied '
            'pressure is the vacuous pass this phase keeps finding');
    _expectWithinBound(run.peakAtEnd, run, at: _shortRun);
  });

  test('the bound follows the chunk the source hands over, not a constant',
      () async {
    // The ubuntu failure, reproduced without a kernel. `dart:io` reads a POSIX
    // socket with `available()`, so one chunk is the whole receive queue: on a
    // GitHub ubuntu runner autotuning takes `tcp_rmem` to its 6 MiB maximum and
    // the line is handed ~3 MiB at once, where macOS hands it ~0.4 MB and
    // Windows a fixed 64 KiB. Measured locally by raising SO_RCVBUF on a real
    // source socket: at 4 MiB the line took a single 5 566 192-byte chunk and
    // peaked at exactly that.
    //
    // Driven from a controller rather than a socket because the size of one
    // read is the *independent variable* here and no kernel lets a test set it
    // honestly — the socket arms above are what establish that these chunks are
    // real. What is under test is the queue's policy, which owes the same
    // answer whatever size the reads come in.
    final rig = await _Rig.openWithoutSource(stalled: true);
    final source = StreamController<List<int>>();
    addTearDown(() async {
      // The line first. Closing a controller whose subscription is paused
      // never completes — the done event has nowhere to go — and this line is
      // paused for the whole arm on purpose.
      await rig.line.close();
      await source.close();
    });
    rig.line.start(source.stream);

    const oversized = 8 * 1024 * 1024;
    source.add(Uint8List(oversized));
    await pumpEventQueue();

    print('oversized read: peak ${rig.line.peakPendingBytes} bytes from one '
        '${rig.line.largestChunkBytes}-byte chunk against a high-water of '
        '${rig.line.highWaterBytes}');

    expect(rig.line.largestChunkBytes, oversized,
        reason: 'the line never saw the oversized read, so the bound below is '
            'being asserted against an idle queue');
    expect(rig.line.sourcePaused, isTrue,
        reason: 'one read past the high-water must pause the source, or the '
            'invariant this arm asserts has nothing holding it up');
    expect(rig.line.peakPendingBytes,
        lessThan(rig.line.highWaterBytes + rig.line.largestChunkBytes),
        reason: 'the queue held ${rig.line.peakPendingBytes} bytes after one '
            'chunk crossed the mark. The pause is synchronous, so this is the '
            'policy, and it holds whatever the kernel hands over');
    expect(rig.line.peakPendingBytes, greaterThan(4 * 1024 * 1024),
        reason: 'this arm exists because a constant bound cannot express the '
            'invariant above: at this chunk size the 4 MiB both this file and '
            'buffer_test.dart used to assert is exceeded by a queue that is '
            'behaving perfectly. If this stops being true the reproduction has '
            'stopped reproducing, and the ubuntu failure it stands for — 4 213 '
            '776, 4 253 341 and 4 325 694 bytes against 4 194 304 — is '
            'unguarded again');
  });

  test(
      'is bounded rather than merely slower: three times the window is not '
      'three times the queue', () async {
    // One rig, sampled twice. Two rigs compared against each other measure
    // per-connection buffer variance, which is about a megabyte and has
    // nothing to do with whether the queue grows.
    final run = await _measureStalledRun(_longRun, sampleAt: _shortRun);

    expect(run.bytesOffered, greaterThanOrEqualTo(_minimumOffered),
        reason: 'the long window pushed only ${run.bytesOffered} bytes, so '
            'the comparison below is between two readings of an idle rig');
    _expectWithinBound(run.peakAtSample, run, at: _shortRun);
    _expectWithinBound(run.peakAtEnd, run, at: _longRun);
    expect(
      run.peakAtEnd,
      lessThanOrEqualTo((run.peakAtSample * _growthAllowance).ceil()),
      reason: 'the same line peaked at ${run.peakAtSample} bytes after '
          '${_shortRun.inSeconds} s and ${run.peakAtEnd} after '
          '${_longRun.inSeconds} s. The queue must be *bounded*, not merely '
          'slower to fill: a line that grows with time passes a four-second '
          'test and takes the soak run down at minute forty, where the '
          'failure looks like a memory leak in whatever the harness was '
          'testing',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('pauses its source at the high-water mark and resumes below the low',
      () async {
    final rig = await _Rig.open(stalled: true);
    // Both subscribed before any pressure is applied, so neither can miss the
    // transition it is waiting for.
    final paused =
        rig.line.sourcePausedChanges.firstWhere((p) => p, orElse: () => false);
    final resumed =
        rig.line.sourcePausedChanges.firstWhere((p) => !p, orElse: () => true);

    var stopped = false;
    final firehose = _firehoseUntil(rig.firehose, () => stopped);

    // `orElse` reports the stream closing without the transition, so the
    // assertion below reads the same either way instead of arriving as a
    // StateError from inside `firstWhere`.
    final sawPause = await within(paused, 'the line paused its source',
        budget: _arrivalBudget);
    expect(sawPause, isTrue,
        reason: 'the line never stopped reading from its source, so the only '
            'thing standing between a stalled consumer and the test host\'s '
            'heap is how fast the sender happens to be');
    expect(rig.line.sourcePaused, isTrue,
        reason: 'the pause event and the flag must agree, or callers that '
            'poll the flag see a different line from callers that watch the '
            'stream');
    expect(rig.line.pendingBytes, greaterThan(0),
        reason: 'a line that pauses with nothing pending is pausing on '
            'something other than its own queue depth');

    stopped = true;
    rig.consumer.resume();

    final sawResume = await within(resumed, 'the line resumed its source',
        budget: _arrivalBudget);
    expect(sawResume, isFalse,
        reason: 'the line stayed paused after its consumer started reading '
            'again, so one burst of backpressure wedges the connection for '
            'good — a fault mode that never ends is not a fault mode');
    expect(rig.line.sourcePaused, isFalse,
        reason: 'the resume event and the flag must agree, or callers that '
            'poll the flag see a different line from callers that watch the '
            'stream');

    await firehose;
  });

  test('closes without hanging while bytes are still pending, and lets go of '
      'its source', () async {
    final rig = await _Rig.open(stalled: true);
    var stopped = false;
    final firehose = _firehoseUntil(rig.firehose, () => stopped);

    await within(
      rig.line.sourcePausedChanges.firstWhere((p) => p, orElse: () => false),
      'the line filled its queue against the stalled consumer',
      budget: _arrivalBudget,
    );
    stopped = true;

    await within(rig.line.close(), 'close() returned while bytes were pending',
        budget: const Duration(seconds: 5));
    await within(rig.line.done, 'the line reported itself finished',
        budget: const Duration(seconds: 5));

    expect(rig.line.pendingBytes, 0,
        reason: 'a closed line still holding bytes is holding them for ever: '
            'nothing will drain it, and every teardown in the suite leaks that '
            'much heap per connection');

    await firehose;
  });
}

/// One stalled-consumer window, read at two points on the same rig.
///
/// [highWater] and [largestChunk] travel with the peaks because the bound is a
/// statement about all three together, and reading them off a rig the assertion
/// no longer holds would be reading them off a different connection.
typedef _StalledRun = ({
  int peakAtSample,
  int peakAtEnd,
  int bytesOffered,
  int highWater,
  int largestChunk,
});

/// Asserts one peak against both halves of the bounded-memory criterion.
///
/// The exact half first, because it is the one that can fail for a reason worth
/// reading: the queue's policy is "pause synchronously the moment the mark is
/// reached", so at most one chunk can be in flight past it and the peak is
/// strictly below the mark plus the largest chunk the source ever handed over.
/// Nothing about that sentence mentions a platform. The [_rssCeiling] half
/// second, because a kernel that handed over half a gigabyte in one read would
/// satisfy the first and still take the host down.
void _expectWithinBound(int peak, _StalledRun run, {required Duration at}) {
  expect(
    peak,
    lessThan(run.highWater + run.largestChunk),
    reason: 'the line peaked at $peak bytes at ${at.inSeconds} s against a '
        'high-water of ${run.highWater} and a largest delivered chunk of '
        '${run.largestChunk}. The pause is applied synchronously in _onData, '
        'so exactly one chunk can cross the mark and nothing can arrive behind '
        'it until the queue drains to the low-water; a peak above this means '
        'the line kept reading after it said it had stopped, which is the '
        'bound failing rather than the runner being unusual',
  );
  expect(
    peak,
    lessThan(_rssCeiling),
    reason: 'the line held $peak bytes at ${at.inSeconds} s against a ceiling '
        'of $_rssCeiling. Ungated, RESEARCH measured the same four seconds '
        'cost 4463 MB of RSS, and a test host that dies of memory never '
        'reports on the fault it was injecting. If this fails while the '
        'assertion above passes, the queue is still obeying its policy and the '
        'kernel handed it a single chunk larger than any receive buffer this '
        'ceiling was derived against — which is a fact about the runner worth '
        'putting in the ceiling\'s derivation, not slack worth adding to it',
  );
}

/// Runs a firehose into a line whose consumer never reads, for [window],
/// recording the peak at [sampleAt] on the way past.
Future<_StalledRun> _measureStalledRun(Duration window,
    {required Duration sampleAt}) async {
  final rig = await _Rig.open(stalled: true);
  var stopped = false;
  final firehose = _firehoseUntil(rig.firehose, () => stopped);

  // A measurement window, not synchronisation. The property under test is
  // "the queue does not grow while time passes", so time passing *is* the
  // experiment — there is no event to await, because the assertion is about
  // the absence of one. Written in the unparameterised form so the phase-wide
  // grep for sleeps finds it.
  await Future.delayed(sampleAt);
  final peakAtSample = rig.line.peakPendingBytes;
  await Future.delayed(window - sampleAt);
  final peakAtEnd = rig.line.peakPendingBytes;
  final largestChunk = rig.line.largestChunkBytes;

  stopped = true;
  rig.firehose.destroy();
  final offered = await firehose;
  await rig.line.close();
  // Printed, not merely asserted: RESEARCH's table is a pair of numbers per
  // window, and a future regression is far easier to read as "the peak tripled
  // when the window tripled" than as one failed comparison.
  print('stalled consumer: peak pending $peakAtSample bytes at '
      '${sampleAt.inSeconds} s, $peakAtEnd at ${window.inSeconds} s, '
      '$offered bytes offered, largest chunk $largestChunk against a '
      'high-water of ${rig.line.highWaterBytes}');
  return (
    peakAtSample: peakAtSample,
    peakAtEnd: peakAtEnd,
    bytesOffered: offered,
    highWater: rig.line.highWaterBytes,
    largestChunk: largestChunk,
  );
}

/// Writes as fast as the far side will take it, gating on `flush()`.
///
/// The gate is what keeps the *rig* honest: an ungated firehose buffers inside
/// its own `dart:io` sink and reproduces Finding 7's 4.5 GB in the test rather
/// than in the code under test.
Future<int> _firehoseUntil(Socket socket, bool Function() stopped) async {
  final chunk = Uint8List(_chunkBytes);
  var offered = 0;
  try {
    while (!stopped()) {
      socket.add(chunk);
      await socket.flush();
      offered += chunk.length;
    }
  } catch (_) {
    // The rig destroyed the socket to end the window; the write in flight
    // failing is how this loop is meant to stop.
  }
  return offered;
}

/// A line under test, with a firehose on one end and a consumer on the other.
///
/// Both ends are real loopback sockets. CONTEXT's test-realism policy restricts
/// injected clocks and fake transports to pure state machines, and this is the
/// opposite of one: what is being measured is how `dart:io` behaves when the
/// kernel stops accepting writes.
final class _Rig {
  _Rig._(this.line, this.firehose, this.consumer, this._received);

  final DelayLine line;

  /// The line's source socket, held so [open] can start the line on it and
  /// [openWithoutSource] can leave it unread.
  Socket? _sourceSocket;

  /// Writes into the socket the line reads from.
  final Socket firehose;

  /// The far side. Paused for the whole test when the rig is stalled.
  final StreamSubscription<Uint8List> consumer;

  final BytesBuilder _received;
  int _target = -1;
  Completer<void>? _reached;

  int get receivedBytes => _received.length;

  Uint8List takeReceived() => _received.takeBytes();

  /// Completes once at least [bytes] have arrived at the consumer.
  Future<void> receivedAtLeast(int bytes) {
    if (_received.length >= bytes) return Future<void>.value();
    _target = bytes;
    return (_reached ??= Completer<void>()).future;
  }

  void _onReceived(Uint8List data) {
    _received.add(data);
    final reached = _reached;
    if (reached != null && !reached.isCompleted && _received.length >= _target) {
      reached.complete();
    }
  }

  /// Builds the rig and registers every teardown at acquisition.
  static Future<_Rig> open({required bool stalled}) async {
    final rig = await openWithoutSource(stalled: stalled);
    rig.line.start(rig._sourceSocket!);
    return rig;
  }

  /// The same rig with its line not yet started.
  ///
  /// For the one arm whose independent variable is the size of a single read:
  /// it starts the line on a controller of its own instead of on
  /// [_sourceSocket], because no kernel lets a test choose that size honestly.
  static Future<_Rig> openWithoutSource({required bool stalled}) async {
    final consumerListener =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(consumerListener.close);
    final consumerAccepted = Completer<Socket>();
    final consumerAccepts = consumerListener.listen(consumerAccepted.complete);
    addTearDown(consumerAccepts.cancel);

    final destination = await within(
      Socket.connect(consumerListener.address, consumerListener.port),
      'the line reached its destination on loopback',
      budget: _connectBudget,
    );
    addTearDown(destination.destroy);
    _ignoreDone(destination);

    final consumerSocket = await within(consumerAccepted.future,
        'the consumer accepted the line\'s destination socket',
        budget: _connectBudget);
    addTearDown(consumerSocket.destroy);
    _ignoreDone(consumerSocket);

    final sourceListener =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(sourceListener.close);
    final sourceAccepted = Completer<Socket>();
    final sourceAccepts = sourceListener.listen(sourceAccepted.complete);
    addTearDown(sourceAccepts.cancel);

    final firehose = await within(
      Socket.connect(sourceListener.address, sourceListener.port),
      'the firehose reached the line\'s source listener',
      budget: _connectBudget,
    );
    addTearDown(firehose.destroy);
    _ignoreDone(firehose);

    final source = await within(
        sourceAccepted.future, 'the line\'s source socket was accepted',
        budget: _connectBudget);
    addTearDown(source.destroy);
    _ignoreDone(source);

    final rig = _Rig._(
      DelayLine(destination: destination),
      firehose,
      consumerSocket.listen(null),
      BytesBuilder(copy: false),
    );
    rig.consumer.onData(rig._onReceived);
    if (stalled) rig.consumer.pause();
    addTearDown(rig.consumer.cancel);
    addTearDown(rig.line.close);

    rig._sourceSocket = source;
    return rig;
  }
}

/// Swallows a socket's `done` failure.
///
/// Every socket in this file is destroyed at teardown, and a destroyed socket
/// completes `done` with an error nobody is waiting for — which `package:test`
/// reports as an unhandled async error against whichever test happens to be
/// running when it lands.
void _ignoreDone(Socket socket) {
  unawaited(socket.done.catchError((Object _) => socket));
}

/// A deterministic pattern whose shifts are visible.
///
/// A run of zeroes would let a line that dropped a chunk still compare equal.
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
/// offset instead of printing half a megabyte of hex into the CI log.
int _firstDifference(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : shared;
}
