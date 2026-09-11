/// The reconnect schedule: exponential growth, full jitter, hard ceiling.
///
/// A pure transform. It holds an attempt counter and a `Random`, and nothing
/// else — it does not read a clock and it does not schedule anything. Whoever
/// owns the reconnect loop asks for the next delay and waits it out; this
/// class only answers "how long".
///
/// **Why it is hand-rolled.** 04-PATTERNS "No Analog Found": nothing anywhere
/// in this repo retries anything, so there was no shape to copy. STACK
/// rejected the two obvious packages — `web_socket_client` shipped an infinite
/// backoff loop, and `flutter_websocket_plus` queues messages while
/// disconnected, which violates the write-safety property this whole product
/// rests on (a write is applied, rejected, or explicitly unknown — never
/// silently replayed later). Thirty lines under this package's own tests is
/// the smaller risk.
///
/// **Why full jitter, and not exponential alone.** The gateway is a single
/// process. When it restarts, every panel in the factory loses its socket
/// inside the same second, and a schedule without jitter brings all of them
/// back at the same instant — repeatedly, each wave landing on a server still
/// replaying snapshots for the previous one. That is the thundering herd, and
/// it is self-sustaining: the synchronised retry is what keeps the gateway too
/// busy to finish, which is what keeps the retries synchronised. Full jitter
/// draws uniformly over the *whole* window rather than jittering around its
/// edge, so the lower bound is zero: a few panels come back almost at once,
/// the rest fill in behind them, and the load is a ramp instead of a spike.
///
/// **Why the ceiling.** Past roughly half a minute the operator standing in
/// front of a blank panel has already concluded it is dead and reached for the
/// power switch — at which point the automatic recovery this class exists to
/// perform never happens. [ClientConfig.maxBackoffCap] refuses a larger cap at
/// construction; this class refuses a cap below its own base, because that
/// makes the schedule a constant from the first attempt.
library;

import 'dart:math';

/// Exponential backoff with full jitter under a fixed cap.
///
/// `next()` for attempt *n* returns a duration drawn uniformly from
/// `[0, min(cap, base * 2^n)]`. `reset()` puts the next draw back in the
/// attempt-0 window — the supervisor calls it on entry to `ready`, so a link
/// that flaps once an hour never accumulates its way to a 30 s stall.
final class Backoff {
  /// The attempt-0 window.
  final Duration base;

  /// The largest window any attempt may draw from.
  final Duration cap;

  final Random _random;

  int _attempt = 0;

  Backoff({
    required this.base,
    required this.cap,
    Random? random,
  }) : _random = random ?? Random() {
    if (base <= Duration.zero) {
      throw ArgumentError('base (${base.inMilliseconds} ms) must be positive: '
          'a zero window is a reconnect loop with no pause, which is the panel '
          'denying service to the gateway it is trying to reach');
    }
    if (cap < base) {
      throw ArgumentError('cap (${cap.inMilliseconds} ms) is below base '
          '(${base.inMilliseconds} ms): every attempt would be clamped to the '
          'same window, and a schedule that is a constant brings every panel '
          'back in the same instant');
    }
  }

  /// The delay to wait before the next connection attempt.
  Duration next() {
    final window = _windowMs();
    _attempt++;
    return Duration(milliseconds: _random.nextInt(window));
  }

  /// Return the schedule to its attempt-0 window.
  void reset() {
    _attempt = 0;
  }

  /// `min(cap, base * 2^attempt)` in milliseconds, at least 1.
  ///
  /// Doubling in a loop with an early return rather than shifting: an attempt
  /// counter that keeps shifting eventually wraps to a negative window, and a
  /// negative window is a crash on the one code path whose entire job is to
  /// survive a long outage.
  int _windowMs() {
    final capMs = cap.inMilliseconds;
    var window = base.inMilliseconds;
    for (var i = 0; i < _attempt; i++) {
      if (window >= capMs) return _atLeastOne(capMs);
      window *= 2;
    }
    return _atLeastOne(window > capMs ? capMs : window);
  }

  /// `nextInt` refuses a zero bound, and a sub-millisecond base rounds to
  /// zero. One millisecond of jitter is still jitter.
  static int _atLeastOne(int ms) => ms < 1 ? 1 : ms;
}
