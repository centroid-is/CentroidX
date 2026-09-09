/// The rules that govern the eight modes together.
///
/// Two halves, and they are opposite claims about the same table.
///
/// **What composes.** `latency`, `throttle` and `flap` set at once, all three
/// measured in one run: a round trip that costs the configured delay, a
/// sustained rate inside its band, and then the dropout at the end of the
/// up-window. The measurement is the proof. A proxy that accepted all three
/// and silently applied one would pass any test that only checked the levers
/// were set, and RESEARCH Finding 7's closing paragraph is why this works at
/// all — one flush-gated delay line per direction, so the three modes are
/// three gates on one queue rather than three buffers interacting.
///
/// **What cannot coexist.** Every pair in `exclusiveModePairs` throws at the
/// moment the second one is set, naming both. Not at forward time, and not by
/// quietly letting one win: a proxy in a state nobody designed produces a test
/// that passes for a reason its author did not intend, which is the most
/// expensive kind of green in this phase.
///
/// The exclusion half is driven off the table itself, in both orders, so a
/// pair added later without a test here is impossible — the test count is
/// asserted against the table's length at the bottom of the group.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

/// The one-way delay the compose arm sets. A round trip costs twice it.
const _latency = Duration(milliseconds: 50);

/// F20's rate, in bytes per second: one hundred kilobits.
const _rate = 100 * 1000 ~/ 8;

/// The band either side of [_rate] a measurement may land in.
///
/// The same twentieth `throttle_test.dart` uses, and for the same reason
/// (Assumption A5). Composition must not widen it: a throttle that only holds
/// its rate when it is the only mode set is a throttle this phase cannot use.
const _rateTolerance = 0.05;

/// How long the rate is measured over.
///
/// Finding 5's floor. Below about two seconds the bucket's one-second burst
/// cap dominates the reading.
const _rateWindow = Duration(seconds: 3);

/// Bytes delivered before the rate window opens.
///
/// One second of traffic at the configured rate, which is exactly the token
/// bucket's burst cap: `_accrue` clamps `_tokens` to `rate`, so a line that has
/// been idle can hand out at most [_rate] bytes faster than [_rate]. Spending
/// that many bytes therefore empties the bank whatever was in it, and the
/// window that opens next is steady state by construction rather than by luck.
///
/// **This is not slack, and it is not a settling delay.** It is the difference
/// between measuring a rate and measuring a rate plus a burst. This arm arms
/// the throttle *before* the client connects — the modes are set on the proxy,
/// not on a live connection, which is the whole point of a composition test —
/// so by the time the firehose starts, connect and the latency probe have let
/// the bucket bank about 200 ms of budget. `throttle_test.dart` never sees this
/// because it sets the lever on an open connection immediately before the go
/// byte, and the setter re-bases the bucket to zero.
///
/// Measured: with the bank released as ten separate 250-byte slices and only
/// the first excluded, a 3 s window reads 13 273 B/s against 12 500 —
/// +6.2 %, and CI measured +6.1 %, +6.2 % and +6.4 % on three runs across two
/// platforms. See the replay arm below, which reproduces it without a socket.
const _warmUpBytes = _rate;

/// The up half of the compose arm's flap.
///
/// Long enough to hold a connect, a latency probe and a full rate window with
/// room to spare — the measurements must not straddle a transition, or the
/// arm becomes a test of how fast the runner is.
const _up = Duration(seconds: 8);
const _down = Duration(seconds: 1);

/// What a round trip may cost on top of `2 * latency`.
///
/// `latency_test.dart` allows 20 ms for the proxy's own overhead. This allows
/// 60, because the probe also crosses a throttle that hands out its budget in
/// slices of a fiftieth of a second, and a slice boundary can be waited for in
/// each direction. Still far tighter than the failure it is here to catch: a
/// composition that dropped the latency mode would come back in single-digit
/// milliseconds.
const _roundTripSlack = Duration(milliseconds: 60);

const _probeBytes = 64;
const _blockBytes = 64 * 1024;
const _connectBudget = Duration(seconds: 5);

/// The byte that tells the upstream server to start firehosing.
const _firehose = 0xf0;

/// How often the modelled client writes while waiting for a dropout.
///
/// Frequent relative to the 16 s budget and far cheaper than the firehose it
/// runs beside — the point is to touch the socket, not to move data.
const _keepalive = Duration(milliseconds: 250);

void main() {
  test('latency, throttle and flap all bite in the same run', () async {
    final rig = await _Rig.open();
    rig.proxy.latency = _latency;
    rig.proxy.throttleBytesPerSec = _rate;
    rig.proxy.flap(_up, _down);
    final run = Stopwatch()..start();

    final client = await _Client.connect(rig.proxy.port);
    final roundTrip = await client.probe();
    final measured = await client.rateOver(_rateWindow);
    final measuredBy = run.elapsed;

    // **The precondition the whole arm rests on, asserted instead of assumed.**
    // Everything above has to finish inside the up half of the flap, or the
    // rate window straddled a transition and the number it produced is a rate
    // measured across a dropout. Locally that is 4.1 s of 8 — connect, a
    // 100 ms probe, an 800 ms warm-up and a 3 s window — so the headroom is
    // roughly 2x and the warm-up spent one second of it. If a future change
    // spends the rest, this line says so; without it the symptom is the
    // dropout assertion failing for a reason nowhere near it.
    expect(measuredBy, lessThan(_up),
        reason: 'the rate window closed ${measuredBy.inMilliseconds} ms into '
            'an ${_up.inMilliseconds} ms up-window, so the measurement above '
            'straddled the flap and is a rate taken across a dropout. Either '
            'the up half needs to grow or the measurement needs to shrink — '
            'not the rate tolerance, which is the one thing here that must not '
            'move');

    final droppedAt = await client.awaitDrop(
      budget: _up * 2,
      state: () => 'the rate window closed at ${measuredBy.inMilliseconds} ms '
          'of an ${_up.inMilliseconds} ms up-window; since then the proxy has '
          'made ${rig.proxy.flapTransitions} flap transition(s), retired '
          '${rig.proxy.pairsRetiredWithLiveClient} pair(s) without ending '
          'their client, and holds '
          '${rig.proxy.livePairs} live pair(s)',
    );
    run.stop();

    print('composed: round trip ${roundTrip.inMilliseconds} ms against '
        '${(_latency * 2).inMilliseconds} ms configured, '
        '${measured.round()} B/s against $_rate B/s, dropout at '
        '${droppedAt.inMilliseconds} ms against an up-window of '
        '${_up.inMilliseconds} ms');

    expect(
      roundTrip.inMicroseconds,
      inInclusiveRange((_latency * 2).inMicroseconds,
          (_latency * 2 + _roundTripSlack).inMicroseconds),
      reason: 'the round trip cost ${roundTrip.inMilliseconds} ms with '
          'latency, throttle and flap all set. Under the floor means the '
          'latency mode was dropped when the others were set — the silent '
          'failure this arm exists for, and one that no assertion about the '
          'levers themselves can see',
    );
    expect(
      measured,
      inInclusiveRange(_rate * (1 - _rateTolerance), _rate * (1 + _rateTolerance)),
      reason: 'the composed link delivered ${measured.round()} B/s against a '
          'configured $_rate. A throttle that only holds its rate alone is '
          'not usable by any scenario that also degrades the link, which is '
          'most of them',
    );
    expect(
      droppedAt,
      greaterThanOrEqualTo(_up - const Duration(milliseconds: 500)),
      reason: 'the link went away after ${droppedAt.inMilliseconds} ms of an '
          '${_up.inMilliseconds} ms up-window, so something other than the '
          'flap cut it — a composition that turned the latency or throttle '
          'path into a teardown would show here and nowhere else',
    );
    expect(
      droppedAt,
      lessThan(_up + const Duration(seconds: 2)),
      reason: 'no dropout arrived within ${(_up + const Duration(seconds: 2)).inSeconds} s, '
          'so the flap was not running while the other two modes were set. '
          'All three have to be observable in one run; two out of three is '
          'the exact result a table of levers cannot distinguish from three',
    );
    // The other half of the dropout claim, and the half a client cannot see.
    //
    // Everything above asks whether the client *learned* the link went away.
    // This asks whether the proxy ever *told* it — a pair that leaves without
    // its client socket being ended is a peer connected to nothing, with no
    // reset coming, and the assertions above would blame the budget for it.
    // Measured at 0 across 680 000 connections and 446 flap transitions in
    // `storm_probe_test.dart`; if it is ever not 0, the fault is here and not
    // in the runner.
    expect(rig.proxy.pairsRetiredWithLiveClient, 0,
        reason: 'the proxy retired a pair whose client socket it never ended. '
            'The dropout this arm waits for was never sent, so no budget and '
            'no client could have observed it');
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('the rate window', () {
    // The bank the compose arm's connect-and-probe lets the bucket accrue:
    // measured at 2500 bytes, which is the 200 ms between the line opening and
    // the firehose reaching it, at 12 500 B/s.
    const banked = 2500;

    test('reads the same rate whatever size the peer delivers in', () {
      for (final chunk in <int>[250, banked, _blockBytes]) {
        final measured =
            _replay(chunkBytes: chunk, warmUpBytes: _warmUpBytes, bank: banked);
        print('replay: $chunk-byte reads, warm-up $_warmUpBytes B, bank '
            '$banked B: ${measured.round()} B/s against $_rate');
        expect(
          measured,
          inInclusiveRange(
              _rate * (1 - _rateTolerance), _rate * (1 + _rateTolerance)),
          reason: 'the same stream delivered in $chunk-byte reads measured '
              '${measured.round()} B/s. Chunk boundaries are the peer\'s '
              'kernel, not the throttle: loopback coalesces on macOS and does '
              'not on the Linux and Windows runners, and an estimator that '
              'reads the two differently is measuring which runner it is on',
        );
      }
    });

    test('a warm-up of one byte is the bug CI found', () {
      // `warmUpBytes: 1` is exactly the rule this file used to carry — open the
      // window at the first chunk, and do not count that chunk. It is written
      // as a warm-up here so the sabotage is one parameter away from the fix
      // rather than a reimplementation that could drift from it.
      final coalesced =
          _replay(chunkBytes: banked, warmUpBytes: 1, bank: banked);
      expect(
        coalesced,
        inInclusiveRange(
            _rate * (1 - _rateTolerance), _rate * (1 + _rateTolerance)),
        reason: 'with the bank arriving as one read the old rule swallowed the '
            'whole burst and measured ${coalesced.round()} B/s. This is the '
            'arm that passed on a developer Mac for the length of the phase, '
            'and it is here so the next reader knows the green was luck',
      );

      final sliced = _replay(chunkBytes: 250, warmUpBytes: 1, bank: banked);
      print('replay: the old rule read ${coalesced.round()} B/s from a '
          'coalesced bank and ${sliced.round()} B/s from a sliced one, '
          'against $_rate');
      expect(
        sliced,
        greaterThan(_rate * (1 + _rateTolerance)),
        reason: 'the same bank arriving as ten 250-byte reads has nine of them '
            'counted inside the window and measures ${sliced.round()} B/s '
            'against $_rate. If this stops being out of band the warm-up above '
            'has stopped being load-bearing and can be deleted — but it does '
            'not stop by itself, because the burst cap is a documented '
            'property of the bucket',
      );
    });
  });

  group('what cannot coexist', () {
    var cases = 0;

    for (final conflict in exclusiveModePairs) {
      for (final order in <({String first, String second})>[
        (first: conflict.a, second: conflict.b),
        (first: conflict.b, second: conflict.a),
      ]) {
        cases++;
        test('${order.first} then ${order.second}', () async {
          final rig = await _Rig.open();
          await _setMode(rig.proxy, order.first);

          expect(
            () => _setMode(rig.proxy, order.second),
            throwsA(isA<StateError>()
                .having((e) => e.message, 'message', contains(order.first))
                .having((e) => e.message, 'message', contains(order.second))),
            reason: 'setting ${order.second} while ${order.first} is set has '
                'to throw here, at set time, with both names in the message. '
                'Both names because the caller pulled one lever and the '
                'conflict is with a lever pulled somewhere else — a message '
                'naming only the one that threw sends the reader to the wrong '
                'line. At set time because the alternative is a proxy that '
                'accepted the pair and behaved as one of them, and a test '
                'passing against that is passing for a reason nobody chose: '
                '${conflict.why}',
          );
        });
      }
    }

    test('has a case for every declared pair, in both orders', () {
      expect(cases, exclusiveModePairs.length * 2,
          reason: 'the table declares ${exclusiveModePairs.length} exclusive '
              'pairs and this group generated $cases cases. The count is '
              'asserted rather than trusted so a pair added to the table '
              'later cannot arrive without its test — the loop above is '
              'generated from the table, so the only way these disagree is a '
              'pair filtered out on the way in');
    });

    test('names only real modes, once each', () {
      for (final conflict in exclusiveModePairs) {
        expect(conflict.a, isIn(faultModes),
            reason: '${conflict.a} is not a declared mode, so this row '
                'excludes nothing while reading as though it did');
        expect(conflict.b, isIn(faultModes),
            reason: '${conflict.b} is not a declared mode');
        expect(conflict.a, isNot(conflict.b),
            reason: 'a mode cannot exclude itself; this row would make '
                '${conflict.a} unsettable the moment it was set');
        expect(conflict.why, isNotEmpty,
            reason: 'the row carries the sentence the exception prints, and '
                'an empty one leaves the caller with two names and no reason');
      }
      final keys = exclusiveModePairs
          .map((c) => (<String>[c.a, c.b]..sort()).join('×'))
          .toList();
      expect(keys.toSet(), hasLength(keys.length),
          reason: 'a pair declared twice generates two identical cases and '
              'makes the count above agree with a table that is wrong');
    });
  });

  test('clearing one member makes the other settable again', () async {
    final rig = await _Rig.open();
    rig.proxy.blackhole();

    expect(() => rig.proxy.bufferServerToClient = true,
        throwsA(isA<StateError>()),
        reason: 'the pair has to be refused while both would be set, or the '
            'arm below proves nothing');

    rig.proxy.blackhole(enabled: false);
    expect(() => rig.proxy.bufferServerToClient = true, returnsNormally,
        reason: 'blackhole was cleared, so the direction it was discarding is '
            'free for the withhold to take. A rule implemented as a latch — '
            '"this proxy has had blackhole set, so buffering is out for '
            'good" — would fail here, and every scenario that moves from one '
            'fault to another on one proxy would fail with it');
  });

  test('clearing a mode is never refused, whatever else is set', () async {
    final rig = await _Rig.open();
    rig.proxy.latency = _latency;
    rig.proxy.latency = null;
    // Reject excludes every shaping mode, so with it set the shaping levers
    // are closed — but their *off* positions must stay open, or a scenario
    // could reach a state it cannot leave.
    await rig.proxy.reject();

    expect(() => rig.proxy.latency = null, returnsNormally,
        reason: 'clearing latency while rejecting has to be allowed: the '
            'check is about what is being switched on, not about which '
            'levers are named in the table. A proxy that refused an off '
            'switch would be a proxy a scenario can drive into a corner');
    expect(() => rig.proxy.blackhole(enabled: false), returnsNormally,
        reason: 'the same for the off position of a mode that was never on');
    expect(() => rig.proxy.flap(_up, _down, enabled: false), returnsNormally,
        reason: 'and the same for the flap, whose off switch carries the '
            'durations only because the lever is one function');
  });
}

/// Sets [mode] on [proxy] the way a caller would.
///
/// One switch rather than a map, so a mode added to `faultModes` without a
/// line here is a compile-time hole the default case reports by name at run
/// time rather than a silently missing key.
Future<void> _setMode(FaultProxy proxy, String mode) {
  switch (mode) {
    case 'flap':
      proxy.flap(_up, _down);
    case 'latency':
      proxy.latency = _latency;
    case 'throttle':
      proxy.throttleBytesPerSec = _rate;
    case 'blackhole':
      proxy.blackhole();
    case 'cutMidFrame':
      proxy.cutMidFrame(137);
    case 'killOnce':
      proxy.killOnce();
    case 'reject':
      // Returned rather than awaited inside the switch: the conflict check
      // runs before the first await, so the throw reaches an `expect` that is
      // watching for a synchronous one. A `reject` that validated after an
      // await would deliver its refusal as an unhandled future error instead,
      // attributed to whichever test was running when it landed.
      return proxy.reject();
    case 'bufferServerToClient':
      proxy.bufferServerToClient = true;
    default:
      fail('no setter for mode "$mode" in this test, so the pair naming it '
          'cannot be exercised — add one beside the others');
  }
  return Future<void>.value();
}

/// Drives a [_RateWindow] with a synthetic throttled stream and returns what
/// it measured.
///
/// The stream is the one the compose arm sees: [bank] bytes released at line
/// speed the instant the firehose starts — the budget the token bucket accrued
/// while the connection was idle — and then a steady [_rate], handed out in the
/// throttle's own 20 ms slices. [chunkBytes] is the size the peer's reads come
/// out in, which is what varies between platforms and must not vary the answer.
double _replay(
    {required int chunkBytes, required int warmUpBytes, required int bank}) {
  final window =
      _RateWindow(warmUpBytes: warmUpBytes, window: _rateWindow);
  const sliceBytes = _rate ~/ 50;
  const sliceMicros = Duration.microsecondsPerSecond ~/ 50;
  // The peer's reads, as (byte count, arrival) pairs. The bank arrives at one
  // instant however many reads it takes; the steady stream one slice per slice
  // interval after it.
  var at = 200 * Duration.microsecondsPerMillisecond;
  double? measured;
  void deliver(int bytes, int atMicros) {
    for (var sent = 0; sent < bytes && measured == null; sent += chunkBytes) {
      final size = sent + chunkBytes <= bytes ? chunkBytes : bytes - sent;
      measured ??= window.add(size, atMicros);
    }
  }

  deliver(bank, at);
  // Ten seconds of steady traffic: enough for any warm-up plus any window this
  // file configures, and the loop stops at the first reading anyway.
  for (var slice = 0; slice < 500 && measured == null; slice++) {
    at += sliceMicros;
    deliver(sliceBytes, at);
  }
  if (measured == null) {
    fail('the replay ran out of stream before the window closed, so the '
        'reading below would be of nothing');
  }
  return measured!;
}

/// Bytes per second, read over a window that opens after a warm-up.
///
/// Separated from [_Client] so the estimator can be driven from a synthetic
/// stream — the replay arm above feeds it the burst that broke it on CI, which
/// is not a thing a loopback socket can be asked to produce on demand.
///
/// **Chunk boundaries must not change the answer.** A byte stream delivered as
/// one 2500-byte read and the same stream delivered as ten 250-byte reads are
/// the same stream; an estimator that reads them differently is measuring the
/// peer's kernel. That is what the old rule here did — it opened the window at
/// the first chunk and discarded exactly that chunk, so how much of the bucket's
/// banked burst escaped the discard depended on whether loopback coalesced it.
final class _RateWindow {
  _RateWindow({required this.warmUpBytes, required this.window});

  /// Bytes that must be delivered before the window opens. Their time is not
  /// counted either — the window starts at the arrival that completes them.
  final int warmUpBytes;

  final Duration window;

  int _warmedUp = 0;
  int? _openedAtMicros;
  int _bytes = 0;

  /// Feeds one delivered chunk; returns the rate once the window has closed.
  ///
  /// Null until then. Called with the arrival instant rather than reading a
  /// clock of its own, so the byte count and the elapsed time always describe
  /// the same instant.
  double? add(int bytes, int atMicros) {
    final openedAt = _openedAtMicros;
    if (openedAt == null) {
      _warmedUp += bytes;
      if (_warmedUp >= warmUpBytes) _openedAtMicros = atMicros;
      return null;
    }
    _bytes += bytes;
    final elapsed = atMicros - openedAt;
    if (elapsed < window.inMicroseconds) return null;
    return _bytes * Duration.microsecondsPerSecond / elapsed;
  }
}

/// A client that can measure a round trip, then a rate, then a dropout.
final class _Client {
  _Client._(this._socket) {
    _socket.listen(_onData,
        onError: (Object _) => _onEnd(), onDone: _onEnd, cancelOnError: true);
    unawaited(_socket.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final Socket _socket;
  final Stopwatch _run = Stopwatch()..start();

  Completer<void>? _probeDone;
  int _probeBytesSeen = 0;

  Completer<double>? _rateDone;
  _RateWindow? _rateWindow;

  final Completer<Duration> _dropped = Completer<Duration>();

  static Future<_Client> connect(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
        timeout: _connectBudget);
    addTearDown(socket.destroy);
    return _Client._(socket);
  }

  /// Sends a small payload and returns how long the echo took to come back.
  Future<Duration> probe() async {
    final done = _probeDone = Completer<void>();
    final started = Stopwatch()..start();
    _socket.add(_pattern(_probeBytes));
    await _socket.flush();
    await done.future.timeout(const Duration(seconds: 20));
    started.stop();
    return started.elapsed;
  }

  /// Asks the upstream for a firehose and measures bytes per second over
  /// [window], timed from the end of a [_warmUpBytes] warm-up.
  ///
  /// Not from the request, because everything before the first byte — the
  /// command crossing the link, the first chunk waiting out the latency — is
  /// dead time that drags the measured rate down and lets a throttle running
  /// fast pass. Not from the first byte either, because the first bytes are the
  /// bucket's banked burst leaving at line speed, which drags it *up*; see
  /// [_warmUpBytes].
  Future<double> rateOver(Duration window) {
    _rateWindow = _RateWindow(warmUpBytes: _warmUpBytes, window: window);
    final done = _rateDone = Completer<double>();
    _socket.add(<int>[_firehose]);
    unawaited(_socket.flush());
    return done.future.timeout(window + const Duration(seconds: 30));
  }

  /// Waits for the link to go away and returns how far into the run it did.
  ///
  /// **Fails by name, with the proxy's own account of what it did.** A bare
  /// `.timeout` here produced the whole of one CI failure — "TimeoutException
  /// after 0:00:16: Future not completed", no line of context, on a run that
  /// prints nothing until after this call returns. That message cannot tell
  /// apart the two things it could mean, and they need opposite
  /// investigations: a flap that never fired (the timer, the mode, the
  /// exclusion table) and a flap that fired at a client which did not notice
  /// (the reset, the socket, this listener). [state] is the caller's snapshot
  /// of the proxy at the moment of the failure, so the next occurrence names
  /// which one it was instead of costing another round of guessing.
  Future<Duration> awaitDrop({
    required Duration budget,
    required String Function() state,
  }) async {
    // The keepalive is not decoration, and it is not a way of making this arm
    // easier to pass.
    //
    // A Dart socket that is only *read* does not learn on macOS that its peer
    // has reset it. `storm_probe_test.dart` measured this over 340 000
    // connections: every miss had read exactly 5000 bytes — one whole throttle
    // up-window — and sat silent for six seconds, and every single one
    // delivered its end **the instant a byte was written to it**
    // (`WRITE-THEN-END`, 12 of 12). The proxy had already reset the peer in
    // every case; `FaultProxy.pairsRetiredWithLiveClient` was 0 throughout.
    // So the reset was sent, the connection was dead, and only the
    // notification was latent.
    //
    // A bare reader is therefore a client this project does not ship. The real
    // one is `RemoteStateMan`, which wires a `HeartbeatPump` — a periodic
    // `Methods.ping` — precisely because "a panel that sends nothing after its
    // handshake" cannot notice a link that has gone. This models that pump, so
    // the arm measures the dropout a real panel would see rather than one no
    // client of ours would wait for.
    //
    // It does not weaken the assertion: if the proxy ever failed to reset the
    // peer, these writes would keep succeeding, no end would arrive, and the
    // arm would still fail — and the "never sent" half is pinned independently
    // and permanently by the counter checked at the end of this test.
    final keepalive = Timer.periodic(_keepalive, (_) async {
      if (_dropped.isCompleted) return;
      try {
        _socket.add(const <int>[0]);
        await _socket.flush();
      } on Object {
        // A write that fails IS the client learning the link is gone — the
        // same way the heartbeat's send failing is how the supervisor learns.
        _onEnd();
      }
    });
    try {
      return await _dropped.future.timeout(budget);
    } on TimeoutException {
      fail('the link never went away: no dropout reached this client within '
          '${budget.inSeconds} s. ${state()}. A transition count above zero '
          'with the link still up means the flap fired and the reset did not '
          'reach the peer; a count of zero means the flap was not running '
          'while the other two modes were set, which is the composition '
          'failure this arm exists for');
    } finally {
      keepalive.cancel();
    }
  }

  void _onData(Uint8List data) {
    final probe = _probeDone;
    if (probe != null && !probe.isCompleted) {
      _probeBytesSeen += data.length;
      if (_probeBytesSeen >= _probeBytes) probe.complete();
      return;
    }
    final rate = _rateDone;
    final window = _rateWindow;
    if (rate == null || window == null || rate.isCompleted) return;
    final measured = window.add(data.length, _run.elapsedMicroseconds);
    if (measured != null) rate.complete(measured);
  }

  void _onEnd() {
    if (!_dropped.isCompleted) _dropped.complete(_run.elapsed);
  }
}

/// A proxy in front of an upstream that echoes, and firehoses on command.
final class _Rig {
  _Rig._(this.proxy);

  final FaultProxy proxy;

  static Future<_Rig> open() async {
    final upstream = await _upstreamServer();
    final proxy = FaultProxy(targetPort: upstream.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
    return _Rig._(proxy);
  }
}

/// Echoes what it is sent, until it is sent [_firehose] alone.
///
/// The lifetime plumbing is `throttle_test.dart`'s `_firehoseServer` shape,
/// copied deliberately rather than reinvented. A firehose whose only stop
/// condition is a throwing write does not stop: once the proxy has gone, the
/// writes complete against a dead socket as fast as the loop can issue them,
/// the isolate never reaches the event loop again, and the runner hangs with
/// no failing test — package:test's own timeout cannot fire either, because
/// firing it needs the timer queue this loop is starving.
Future<ServerSocket> _upstreamServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final block = _pattern(_blockBytes);
  var stopped = false;
  addTearDown(() => stopped = true);
  final accepted = <Socket>[];
  addTearDown(() {
    for (final socket in accepted) {
      socket.destroy();
    }
  });

  final accepts = server.listen((socket) {
    accepted.add(socket);
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    var firehosing = false;
    // Set the moment this connection ends, and checked every iteration below.
    // This flag is the difference between a firehose and a hung suite: the
    // flap under test takes the pair away mid-stream, and writing into a
    // socket whose peer has gone does *not* throw — it completes as fast as
    // the loop can issue it, which starves the event loop of the very isolate
    // the test, the client and package:test's own timeout all run in. The
    // symptom is a runner that never returns and never fails.
    var gone = false;
    void end() {
      gone = true;
      socket.destroy();
    }

    socket.listen(
      (data) async {
        if (firehosing) return;
        if (data.length == 1 && data.first == _firehose) {
          firehosing = true;
          // A wall-clock backstop as well as the flag, because the flag is
          // delivered by the event loop and the failure being guarded against
          // is the event loop not getting a turn. A Stopwatch needs nobody's
          // permission to advance.
          final runaway = Stopwatch()..start();
          try {
            // Gated on `flush()` for the same reason the delay line's writes
            // are: an ungated firehose buffers inside its own `dart:io` sink
            // and reproduces Finding 7's 4463 MB in the sender instead of the
            // proxy.
            while (!stopped &&
                !gone &&
                runaway.elapsed < const Duration(seconds: 30)) {
              socket.add(block);
              await socket.flush();
            }
          } catch (_) {
            // The rig was torn down mid-write, which is how this ends.
          }
          return;
        }
        try {
          socket.add(data);
        } catch (_) {
          // The proxy cut this connection mid-echo, which several of the
          // modes under test do on purpose.
        }
      },
      onError: (Object _) => end(),
      onDone: end,
    );
  });
  addTearDown(accepts.cancel);
  return server;
}

Uint8List _pattern(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7 + 13) & 0xff));
