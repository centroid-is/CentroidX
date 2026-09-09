/// A rolling per-second request rate, used by every client wrapper's health
/// line.
///
/// Its own file because it is arithmetic over a clock and nothing else — no
/// session, no socket, no `dart:io`. It lived in `conn_meta.dart`, which also
/// holds an OPC-UA-backed metadata source and therefore reaches
/// `package:open62541` and `dart:ffi`; importing all of that to count requests
/// is what kept `modbus_client_wrapper.dart` off a web build.
library;

import 'dart:collection';

/// Turns a monotonically increasing request counter into a rolling
/// requests-per-second figure.
///
/// The counter is sampled lazily: reading [ratePerSec] folds every whole
/// wall-clock second elapsed since the previous read into a moving window of
/// [windowSeconds] per-second deltas and returns their average. Idle seconds
/// contribute a 0 to the window, so the rate decays to zero when traffic
/// stops. No background [Timer] is used, so there is nothing to leak.
///
/// The clock is injectable for deterministic tests.
class RollingRate {
  final int windowSeconds;
  final DateTime Function() _clock;

  int _counter = 0;
  int _lastSampledCounter = 0;
  DateTime? _lastSampleTime;
  final Queue<double> _window = Queue<double>();

  RollingRate({this.windowSeconds = 5, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    // Seed the baseline so the first elapsed second is measured from
    // construction, not from the first [ratePerSec] read.
    _lastSampleTime = _clock();
  }

  /// Record [n] requests (default 1).
  void increment([int n = 1]) => _counter += n;

  /// Total requests recorded since construction.
  int get total => _counter;

  void _sampleIfDue() {
    final now = _clock();
    _lastSampleTime ??= now;
    final elapsed = now.difference(_lastSampleTime!).inSeconds;
    if (elapsed <= 0) return;
    if (elapsed > windowSeconds) {
      // Nothing sampled the rate for longer than the window covers
      // (meta-keys sample lazily — this can be the first read after days).
      // There is no per-second information for the gap: back-filling one
      // zero per elapsed second would do O(uptime) work, and attributing
      // the whole gap's delta to one in-window second would show a bogus
      // spike. Start a fresh window instead — the rate reads 0 now and
      // converges over the next [windowSeconds] seconds of real samples.
      _window.clear();
      _lastSampledCounter = _counter;
      _lastSampleTime = now;
      return;
    }
    final delta = _counter - _lastSampledCounter;
    // The whole delta lands in the first elapsed second; any further elapsed
    // seconds were idle and contribute 0.
    _window.addLast(delta.toDouble());
    for (var i = 1; i < elapsed; i++) {
      _window.addLast(0);
    }
    while (_window.length > windowSeconds) {
      _window.removeFirst();
    }
    _lastSampledCounter = _counter;
    // Advance by whole seconds so the fractional remainder carries into the
    // next sample instead of being dropped.
    _lastSampleTime = _lastSampleTime!.add(Duration(seconds: elapsed));
  }

  /// The current rolling requests-per-second average.
  double get ratePerSec {
    _sampleIfDue();
    if (_window.isEmpty) return 0;
    return _window.reduce((a, b) => a + b) / _window.length;
  }
}
