/// The encode-counting seam. It exists because the failure it guards has no
/// error message and no symptom until a hundred panels are connected.
///
/// 03-RESEARCH Finding 2 measured the two fan-out strategies at 100 clients ×
/// 200 changed keys: encoding per client (which is what
/// `Peer.sendNotification` does internally, once per peer) cost **7 639 µs per
/// tick**; encoding the body once and splicing per-client envelopes around it
/// cost **110 µs** — **69.6×**. Nothing throws when you get this wrong. The
/// server keeps serving, every functional test stays green, and the only
/// evidence is that a plant-floor screen is late. So the counter *is* the
/// alarm: a test that asserts `calls == 1` is the only thing standing between
/// this codebase and the slow strategy.
///
/// Deliberately trivial — it delegates to `jsonEncode` and counts. A fixture
/// that transformed the output could hide a difference the real encoder would
/// show.
library;

import 'dart:convert';

/// A `String Function(Object?)` that counts how many times it was called.
///
/// Pass `encoder.call` (or the instance itself, which is callable) wherever a
/// `String Function(Object?)` encode seam is expected.
final class CountingEncoder {
  int _calls = 0;

  /// The seam. Identical output to `jsonEncode`, so a test that round-trips a
  /// produced frame is testing the real thing.
  String call(Object? value) {
    _calls++;
    return jsonEncode(value);
  }

  /// How many times [call] has run since construction or the last [reset].
  int get calls => _calls;

  /// Zeroes the counter — used to exclude once-per-session work (escaping a
  /// subscription name, say) from a per-tick assertion.
  void reset() => _calls = 0;
}
