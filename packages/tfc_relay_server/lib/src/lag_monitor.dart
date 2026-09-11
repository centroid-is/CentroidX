/// Turns tick-to-tick drift into a verdict the gateway can act on. Internal
/// seam: an embedder configures and starts a server, it does not poll a
/// monitor.
///
/// Pure state machine: no clock, no timer, no I/O. The caller passes the
/// timestamp, exactly as `ConflatingSendBuffer.poll(nowMs)` does, which is why
/// a 400 ms freeze costs a test nothing to reproduce.
///
/// **The measurements this is built on** (03-RESEARCH Finding 10). Idle, the
/// observed per-tick lags were `[2, 1, 0, -1, 0]` ms — a ±2 ms noise floor, so
/// any threshold above roughly 50 ms is comfortably outside ordinary drift and
/// a threshold near 5 ms would be an alarm about nothing. A 400 ms synchronous
/// stall at a 100 ms period produced exactly **one** oversized gap and **no
/// catch-up burst**: the timer does not fire repeatedly to make up lost
/// ground. That is why one stall yields one verdict here with no debounce
/// state — the debounce would be guarding against a burst that was measured
/// not to happen.
///
/// **Where to call it** (for 03-07, which wires this in): inside the same tick
/// callback that does the fan-out, not in a separate timer. A monitor on its
/// own timer measures its own scheduling, not the freeze the panels actually
/// saw; when the loop is blocked, both timers are blocked, and only the
/// callback that was supposed to be sending data knows how long the data was
/// not being sent.
///
/// **Which number `stalledMs` carries.** The two candidates differ by exactly
/// one period and both read plausibly in a log: the absolute wall-clock gap
/// (400) or the excess over the period (300). Server and client must agree,
/// because `ResyncParams.stalledMs` crosses the wire and a panel renders it as
/// a sentence. 03-CONTEXT chose **absolute**: a panel says "the plant view was
/// frozen for 400 ms", which is a statement about the plant. The excess is a
/// statement about a tick period the client does not know. The threshold, by
/// contrast, is compared against the *excess* — lateness is what makes a tick
/// worth announcing, and a threshold on the absolute gap would change meaning
/// every time the tick period was retuned.
library;

/// What one [LagMonitor.poll] concluded.
///
/// Sealed so the tick engine's switch is exhaustive by the compiler: a future
/// third verdict cannot be silently ignored by the code that decides whether
/// to resync the plant.
sealed class LagVerdict {
  const LagVerdict();
}

/// The loop is running on time. The overwhelmingly common case.
final class LagOk extends LagVerdict {
  const LagOk();
}

/// The event loop was frozen and the clients must be told.
final class LagStalled extends LagVerdict {
  /// The **absolute** wall-clock gap between the two ticks, in milliseconds —
  /// how long the gateway was not serving anybody. Goes on the wire as
  /// `ResyncParams.stalledMs` with reason `gateway_stalled`.
  final int stalledMs;

  const LagStalled(this.stalledMs);

  @override
  String toString() => 'LagStalled(${stalledMs}ms)';
}

/// Watches the interval between ticks and reports freezes.
final class LagMonitor {
  /// The tick period the caller schedules at. Lateness is measured against it.
  final int periodMs;

  /// How late a tick may be, over and above [periodMs], before it counts as a
  /// stall. Keep it well above the ±2 ms measured noise floor.
  final int thresholdMs;

  int? _lastMs;

  LagMonitor({required this.periodMs, required this.thresholdMs});

  /// Records a tick at [nowMs] and judges the gap since the previous one.
  ///
  /// The first call only primes the monitor: there is no earlier tick for it
  /// to have been late against, and a server that announced a stall on its own
  /// first tick would resync every panel on every restart.
  LagVerdict poll(int nowMs) {
    final last = _lastMs;
    _lastMs = nowMs;
    if (last == null) return const LagOk();

    final gap = nowMs - last;
    final excess = gap - periodMs;
    if (excess <= thresholdMs) return const LagOk();
    // Reported absolute (excess + periodMs == gap); see the library doc for
    // why the threshold is on the excess and the report is not.
    return LagStalled(excess + periodMs);
  }
}
