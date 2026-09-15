/// The throttle, measured in bytes per second — roadmap criterion 2's own
/// named example.
///
/// RESEARCH Finding 5 measured a token bucket against a firehose sender, with
/// the timing started at the first delivered byte:
///
/// | Target | Window | Measured |
/// |---|---|---|
/// | 1000 kbit/s | 3 s | 1002.3 kbit/s |
/// | 1000 kbit/s | 6 s | 1001.0 kbit/s |
/// | 100 kbit/s  | 3 s | 100.0 kbit/s  |
/// | 100 kbit/s  | 6 s | 100.2 kbit/s  |
/// | 10 kbit/s   | 3 s | 10.0 kbit/s   |
///
/// So the mechanism is accurate to a fifth of a per cent, and the band here is
/// a full twentieth (Assumption A5: CI hardware is slower and noisier than the
/// machine that table came from). The window is never shorter than three
/// seconds, because the bucket's one-second burst cap dominates anything below
/// about two.
///
/// **The two rates are not arbitrary.** They are the ones Phase 7's F19 and
/// F20 name — 1 Mbit/s and 100 kbit/s — and those scenarios assert against
/// this mode directly. A throttle that does not actually throttle turns their
/// conflation evidence into a coincidence: "the client kept up under a slow
/// link" is only interesting if the link was slow.
///
/// **Wall-clock by design, and budgeted.** Two measurement windows plus a
/// pressure window plus an integrity run is about fifteen seconds, and the
/// file is meant to stay under twenty-five. Plan 02-14 budgets the whole fault
/// suite, and this file is the largest single line item in it; anything added
/// here should replace an arm rather than join it.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// F19's rate, in bytes: one megabit per second.
const _oneMegabit = 1000 * 1000 ~/ 8;

/// F20's rate, in bytes: one hundred kilobits per second.
const _hundredKilobit = 100 * 1000 ~/ 8;

/// The measurement window.
///
/// Longer than the three seconds Finding 5 established as the floor, because
/// the floor is where the one-second burst cap stops mattering and this is a
/// noisier machine than the one that measured it.
const _window = Duration(milliseconds: 3500);

/// The fraction either side of the configured rate a measurement may land in.
///
/// Finding 5 measured 0.002. This is 0.05 — twenty-five times the observed
/// error, which is the widening Assumption A5 asks for, and still tight enough
/// that a throttle off by a factor of two, or absent, fails immediately.
const _tolerance = 0.05;

/// The ceiling the pressure arm holds the proxy's queue to.
///
/// Four times the delay line's 1 MiB high-water: RESEARCH Finding 7 measured
/// the real peak at 1.26-1.29 MB, because `dart:io` has already handed over a
/// chunk by the time the pause takes effect. The bound is "high-water plus one
/// socket buffer", and an assertion at exactly 1 MiB would be measuring the
/// kernel's buffer-sizing heuristics.
const _queueBound = 4 * 1024 * 1024;

/// How long the pressure arm runs a firehose against a slow throttle.
const _pressureWindow = Duration(seconds: 4);

/// How many bytes the integrity arm checks, byte for byte.
///
/// At [_oneMegabit] this is about a second of traffic — enough to cross many
/// slices of the bucket, which is where a throttle that splits chunks would
/// drop or duplicate the seam.
const _integrityBytes = 128 * 1024;

/// The block the upstream server sends over and over.
///
/// A repeating block rather than one enormous payload: the sender is a
/// firehose that never stops, and a repeating block still lets the integrity
/// arm say exactly which byte should have been where.
const _blockBytes = 64 * 1024;

const _connectBudget = Duration(seconds: 5);

void main() {
  test('delivers at one megabit per second, measured over three and a half '
      'seconds', () async {
    await _expectRate(_oneMegabit, 'F19 / 1 Mbit/s');
  });

  test('delivers at one hundred kilobits per second — F20\'s rate, an order '
      'of magnitude down', () async {
    await _expectRate(_hundredKilobit, 'F20 / 100 kbit/s');
  });

  test('refuses a rate of zero rather than reading as armed and shaping '
      'nothing', () async {
    final rig = await _Rig.open();

    for (final rate in [0, -1, -_oneMegabit]) {
      expect(() => rig.proxy.throttleBytesPerSec = rate, throwsArgumentError,
          reason: 'a rate of $rate is stored, makes the composition table '
              'report throttle armed, and is then skipped by the bucket, '
              'which only meters a positive rate. That is the third state '
              'fault_proxy.dart:20-27 forbids: the lever is set, the mode '
              'test passes, and the traffic goes through at full speed. Every '
              'neighbouring lever refuses its own impossible value at set '
              'time — flap a zero half, cutMidFrame a negative count — so a '
              'rate of zero is a gap in the rule, not an exception to it');
    }

    // `reject` excludes `throttle`, so it is the observable for whether a
    // throttle is armed — the lever itself is setter-only, and "armed" is a
    // claim about the composition table rather than about a stored number.
    await rig.proxy.reject();
    await rig.proxy.reject(enabled: false);

    rig.proxy.throttleBytesPerSec = _hundredKilobit;
    expect(() => rig.proxy.reject(), throwsStateError,
        reason: 'a positive rate must still arm the mode, or the refusal '
            'above was bought by disarming the lever entirely');

    rig.proxy.throttleBytesPerSec = null;
    await rig.proxy.reject();
    await rig.proxy.reject(enabled: false);
  });

  test('holds its queue under the bound while a firehose runs into a slow '
      'throttle', () async {
    final rig = await _Rig.open();
    rig.proxy.throttleBytesPerSec = _hundredKilobit;
    rig.start();

    // A measurement window, not synchronisation: the property is "the queue
    // does not grow while the sender outruns the drain", so time passing is
    // the experiment and there is no event to await.
    await Future<void>.delayed(_pressureWindow);
    final peak = rig.proxy.peakPendingBytes;
    print('firehose into a $_hundredKilobit B/s throttle for '
        '${_pressureWindow.inSeconds} s: peak pending $peak bytes, '
        '${rig.receivedBytes} delivered');

    expect(peak, greaterThanOrEqualTo(defaultHighWaterBytes),
        reason: 'the proxy never queued as much as its own high-water mark, '
            'so the firehose never outran the throttle and the bound below '
            'passes without having been tested — the vacuous pass this phase '
            'keeps finding');
    expect(peak, lessThan(_queueBound),
        reason: 'the proxy held $peak bytes against a bound of $_queueBound. '
            'A firehose against a slow throttle is the exact shape RESEARCH '
            'measured growing to 4463 MB unmitigated (T-02-09); if the token '
            'bucket had been built as a second buffer instead of a gate on '
            'the existing queue, this is where it would show');
  });

  test('delivers the bytes intact and in order through the throttle',
      () async {
    final rig = await _Rig.open();
    rig.proxy.throttleBytesPerSec = _oneMegabit;
    final wanted = rig.firstBytes(_integrityBytes);
    rig.start();

    final delivered = await within(
        wanted, 'the first $_integrityBytes throttled bytes arrived',
        budget: const Duration(seconds: 20));

    final expected = _expectedPrefix(_integrityBytes);
    expect(delivered.length, _integrityBytes,
        reason: 'the throttled link delivered ${delivered.length} of '
            '$_integrityBytes bytes');
    final firstDifference = _firstDifference(delivered, expected);
    expect(firstDifference, -1,
        reason: 'byte $firstDifference differs, so the throttle dropped, '
            'duplicated or reordered at a slice boundary. A rate limiter that '
            'hands out partial chunks has exactly one interesting bug, and it '
            'is this one: the seam between two slices of the same chunk. A '
            'mode that broke the bytes as well as slowing them would prove '
            'nothing about slowness — the sabotage has to be surgical');
  });
}

/// Sets [bytesPerSec] on an open connection and measures what arrives.
Future<void> _expectRate(int bytesPerSec, String label) async {
  final rig = await _Rig.open();
  // Set *after* the connection is open: the lever is live-mutable, and every
  // scenario that uses it degrades a link somebody is already talking over.
  rig.proxy.throttleBytesPerSec = bytesPerSec;
  final measuring = rig.deliveredIn(_window);
  rig.start();

  final measured = await within(measuring,
      'the $label window closed on the far side of the throttle',
      budget: _window + const Duration(seconds: 20));
  final rate = measured.bytes *
      Duration.microsecondsPerSecond /
      measured.elapsed.inMicroseconds;
  // Printed as well as asserted, so a CI failure reads as a number: "121 400
  // B/s against 125 000" is a slow runner, and "1 900 000 B/s" is a throttle
  // that never engaged. The assertion alone cannot tell those apart.
  print('throttle $label: ${rate.round()} B/s measured over '
      '${measured.elapsed.inMilliseconds} ms (${measured.bytes} bytes), '
      'target $bytesPerSec B/s');

  expect(
    measured.elapsed,
    lessThan(rig.sinceStart),
    reason: 'the measured window is not shorter than the whole run, so it '
        'started at connection open rather than at the first delivered byte. '
        'Everything before the first byte — the request crossing the link, '
        'the bucket filling its first slice — is dead time that would drag '
        'the measured rate down and let a throttle running fast pass',
  );
  expect(
    rate,
    inInclusiveRange(
        bytesPerSec * (1 - _tolerance), bytesPerSec * (1 + _tolerance)),
    reason: 'the $label throttle delivered ${rate.round()} bytes per second '
        'against a configured $bytesPerSec. A throttle that does not throttle '
        'turns Phase 7\'s conflation evidence into a coincidence: F19 and F20 '
        'assert that the client stays correct on a slow link, and neither '
        'means anything if the link was never slow',
  );
}

/// What the far side must have received in its first [length] bytes.
Uint8List _expectedPrefix(int length) {
  final block = _pattern(_blockBytes);
  final expected = Uint8List(length);
  for (var i = 0; i < length; i++) {
    expected[i] = block[i % _blockBytes];
  }
  return expected;
}

/// One window's worth of delivery, read at a single instant.
typedef _Delivery = ({int bytes, Duration elapsed});

/// A client talking through the proxy to an upstream firehose.
final class _Rig {
  _Rig._(this.proxy, this.client) {
    client.listen(
      _onData,
      // A destroyed socket at teardown reports both, and an unhandled one
      // lands on whichever test happens to be running.
      onError: (Object _) {},
      onDone: () {},
    );
  }

  final FaultProxy proxy;
  final Socket client;

  final BytesBuilder _received = BytesBuilder(copy: false);

  /// Wall clock from [start] — the whole run, handshake included.
  final Stopwatch _run = Stopwatch();

  /// Wall clock from the **first delivered byte**.
  ///
  /// Started inside the data handler and nowhere else, which is what makes
  /// "the measurement begins at the first byte" a property of the code rather
  /// than of a comment. Finding 5 timed it the same way.
  Stopwatch? _delivery;

  /// Bytes delivered strictly after [_delivery] started.
  ///
  /// The chunk that starts the clock is deliberately not counted: at the
  /// window sizes here that is under one per cent, and it can only bias the
  /// measured rate *downward* — so a throttle delivering too fast cannot hide
  /// behind it, which is the direction that matters.
  int _measured = 0;

  Duration _window = Duration.zero;
  Completer<_Delivery>? _windowDone;

  int _wanted = -1;
  Completer<Uint8List>? _prefixDone;

  int get receivedBytes => _received.length;

  /// How long since [start] — the denominator a naive measurement would use.
  Duration get sinceStart => _run.elapsed;

  /// Asks the upstream server to begin.
  ///
  /// The server sends nothing until this arrives, which is what keeps the
  /// measurement honest: bytes forwarded in the window between the pair being
  /// accepted and the lever being set would be unthrottled, and at these rates
  /// a megabyte of head start is several seconds of budget.
  void start() {
    _run.start();
    client.add(const <int>[_goByte]);
    unawaited(client.flush().catchError((Object _) {}));
  }

  /// Completes when [window] has elapsed since the first delivered byte.
  Future<_Delivery> deliveredIn(Duration window) {
    _window = window;
    return (_windowDone ??= Completer<_Delivery>()).future;
  }

  /// Completes with the first [bytes] bytes to arrive.
  Future<Uint8List> firstBytes(int bytes) {
    _wanted = bytes;
    return (_prefixDone ??= Completer<Uint8List>()).future;
  }

  void _onData(Uint8List data) {
    _received.add(data);
    final delivery = _delivery;
    if (delivery == null) {
      _delivery = Stopwatch()..start();
    } else {
      _measured += data.length;
      final done = _windowDone;
      if (done != null && !done.isCompleted && delivery.elapsed >= _window) {
        // Both readings taken here, in one synchronous step, so the byte count
        // and the elapsed time describe the same instant.
        done.complete((bytes: _measured, elapsed: delivery.elapsed));
      }
    }
    final prefix = _prefixDone;
    if (prefix != null && !prefix.isCompleted && _received.length >= _wanted) {
      final all = _received.toBytes();
      prefix.complete(Uint8List.sublistView(all, 0, _wanted));
    }
  }

  /// A client, a proxy and an upstream firehose, all torn down with the test.
  static Future<_Rig> open() async {
    final upstream = await _firehoseServer();
    final proxy = FaultProxy(targetPort: upstream.port);
    await proxy.start();
    addTearDown(proxy.shutdown);

    final client = await within(
      Socket.connect(InternetAddress.loopbackIPv4, proxy.port),
      'the client reached the proxy on port ${proxy.port}',
      budget: _connectBudget,
    );
    addTearDown(client.destroy);
    unawaited(client.done.catchError((Object _) => client));
    return _Rig._(proxy, client);
  }
}

/// The byte that tells the upstream server to open the tap.
const _goByte = 0x67;

/// A loopback server that floods a repeating block once asked to.
///
/// Its writes are gated on `flush()` for the same reason the delay line's are:
/// an ungated firehose buffers inside its own `dart:io` sink and reproduces
/// Finding 7's four and a half gigabytes in the rig rather than in the code
/// under test.
Future<ServerSocket> _firehoseServer() async {
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
    unawaited(socket.done.catchError((Object _) => socket));
    socket.listen(
      (_) async {
        try {
          while (!stopped) {
            socket.add(block);
            await socket.flush();
          }
        } catch (_) {
          // The test tore the rig down mid-write. That is how this loop is
          // meant to end.
        }
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
/// A run of zeroes would let a link that dropped a slice still compare equal.
Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}

/// The index of the first differing byte, or -1 when the prefixes match.
int _firstDifference(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : shared;
}
