/// The difference between this panel's clock and the gateway's, captured at
/// hello and applied to everything after it.
///
/// Source: 04-RESEARCH Finding 5b, executed against the real gateway.
/// `hello.serverTime = 1786711225713` against a local `1786711225765` — 52 ms,
/// same machine. `tick.serverTime` tracked wall clock exactly over a 7 s wait
/// and `SubTick.evaluatedAt` came back the same magnitude, so the two clocks
/// really are subtractable. CR-04 (STATE.md line 79) is the ruling that makes
/// it legal in the first place: the wire carries wall-clock epoch milliseconds
/// everywhere, and the gateway's internal measurement stays monotonic behind
/// that boundary.
///
/// The rule, in one line: `clockOffset = localNowMs - hello.serverTime`,
/// re-captured at every hello — every reconnect gets a fresh one, because a
/// panel that has been asleep in a cold room comes back with a different
/// answer than it went to sleep with.
///
/// **All staleness arithmetic in this package is done in the server's clock.**
/// A panel in a fish factory is an ordinary machine in a wet, cold room, and
/// one of them will have a dead CMOS battery and boot thinking it is 2016. Judge
/// freshness against *that* clock and every value goes grey the instant it
/// connects: the operator is blind, and nothing is wrong with the plant. So
/// CLI-05 says a wrong local clock is a **warning** — surfaced, logged, and
/// then ignored in favour of the gateway's time. Never a grey plant.
///
/// Pure data: no clock is read in here. The local `now` is an argument, which
/// is also why testing a ten-year skew needs no fake-time package — the case
/// just passes the number.
library;

/// One captured skew, with the judgement about whether it is believable.
///
/// Immutable, because it belongs to a connection: the next hello makes a new
/// one rather than mutating this.
final class ClockOffset {
  const ClockOffset({
    required this.offsetMs,
    required this.implausible,
    required this.warning,
  });

  /// A connection whose clocks agree exactly. The starting point before any
  /// hello has been seen.
  static const ClockOffset none =
      ClockOffset(offsetMs: 0, implausible: false, warning: null);

  /// `localNowMs - serverTimeMs`: positive when this panel runs ahead of the
  /// gateway.
  final int offsetMs;

  /// Whether [offsetMs] is further from zero than the configured threshold
  /// (`ClientConfig.implausibleClockThreshold`).
  ///
  /// A flag, not a switch: nothing in this package changes what it computes
  /// because of it.
  final bool implausible;

  /// The operator- and integrator-facing sentence, or `null` when the clocks
  /// are close enough to say nothing.
  final String? warning;

  /// Captures the skew from a hello: [serverTimeMs] is `hello.serverTime`,
  /// [localNowMs] is what this machine thought the time was when the frame
  /// arrived.
  factory ClockOffset.fromHello(
    int serverTimeMs,
    int localNowMs, {
    required Duration threshold,
  }) {
    final int offsetMs = localNowMs - serverTimeMs;
    final bool implausible = offsetMs.abs() > threshold.inMilliseconds;
    return ClockOffset(
      offsetMs: offsetMs,
      implausible: implausible,
      warning: implausible ? _warningFor(offsetMs, threshold) : null,
    );
  }

  /// A gateway timestamp — `tick.serverTime`, `SubTick.evaluatedAt` — read in
  /// this machine's clock. For display only.
  int toLocal(int serverMs) => serverMs + offsetMs;

  /// A local timestamp read in the gateway's clock. This is the direction
  /// freshness uses, and it keeps working when the local clock is nonsense.
  int toServer(int localMs) => localMs - offsetMs;

  static String _warningFor(int offsetMs, Duration threshold) {
    final String direction = offsetMs > 0 ? 'ahead of' : 'behind';
    return 'this panel\'s clock is ${Duration(milliseconds: offsetMs.abs())} '
        '$direction the gateway\'s, which is past the '
        '${threshold.inMilliseconds} ms threshold — set the panel\'s clock or '
        'point it at the plant NTP server. Values are still being shown and '
        'their freshness is still being measured against the gateway\'s clock, '
        'so nothing on screen is wrong; only this machine\'s idea of the date '
        'is.';
  }

  @override
  String toString() => 'ClockOffset($offsetMs ms'
      '${implausible ? ', implausible' : ''})';
}
