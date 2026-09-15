/// A hand-cranked millisecond clock for the pure cores.
///
/// It is this small on purpose. Every core in this stack takes its timestamp
/// as a *parameter* — `ConflatingSendBuffer.poll(nowMs)` does, `LagMonitor.poll
/// (nowMs)` does — so no component needs a clock abstraction injected into it,
/// and none has one. That convention (03-RESEARCH, Wave 0 note) is what makes
/// a stall test an arithmetic test: to model a 400 ms freeze you advance a
/// counter, you do not sleep for 400 ms on a hosted CI runner and hope.
///
/// The tear-off exists for the wiring plans later in this phase, where the
/// tick engine takes an `int Function()` so production can pass a real clock
/// and tests can pass this one.
library;

/// A monotonic millisecond counter that only moves when you move it.
final class FakeClock {
  /// Current time in milliseconds. Starts at [start].
  int nowMs;

  FakeClock({int start = 0}) : nowMs = start;

  /// Moves time forward. Negative advances are rejected: a clock that could go
  /// backwards would let a test assert a stall the real system can never see.
  void advance(int ms) {
    if (ms < 0) {
      throw ArgumentError.value(ms, 'ms', 'time does not run backwards');
    }
    nowMs += ms;
  }

  /// The `int Function()` seam. Pass `clock.now` where a clock is injected.
  int now() => nowMs;
}
