/// The hot path's encoder. Internal seam: an embedder configures and starts a
/// server, it does not assemble frames.
///
/// Pure: no I/O, no clock, no socket. The caller owns the tick.
///
/// **Why this class exists at all.** 03-RESEARCH Finding 2 benchmarked four
/// fan-out strategies at 100 clients × 200 changed keys per tick:
///
/// | strategy | µs/tick |
/// |---|---|
/// | `Peer.sendNotification` (encodes once *per peer*) | 7 639 |
/// | encode the body once, splice per-client envelopes | 110 |
///
/// **69.6×.** `json_rpc_2` wraps each peer's channel in a JSON codec
/// transformer, so the obvious wiring pays the full encode per connected
/// panel, silently: nothing throws, nothing logs, and every functional test
/// still passes. The only symptom is a plant-floor screen falling behind.
/// `frame_encoder_test.dart` counts encoder calls so that regression is caught
/// by an exact integer rather than by a stopwatch on a hosted runner.
///
/// **The honest property is per changed-key set, not per tick.** Finding 3:
/// the shared bytes are the `c`/`q`/`r` body, which is keyed by *handle*, and
/// handles are server-global ([HandleTable]) precisely so two panels watching
/// one motor produce byte-identical bodies. Two panels whose changed-handle
/// sets differ do not share, and cost two encodes. Saying "one encode per
/// tick" would be a promise this code cannot keep, so the tests say the longer
/// thing instead.
///
/// **What is not shared:** `sub` and `seq` are per client, so the envelope is
/// assembled by string concatenation around the pre-encoded body. Building a
/// map and encoding that is the 7 639 µs strategy arrived at by accident.
///
/// Values are not part of the cache signature. Within one tick a handle has
/// one value — it comes from the server's own state — so two clients with the
/// same changed-handle set necessarily have the same changed values. Across
/// ticks that is false, which is why [FrameEncoder.beginTick] clears the
/// cache.
library;

import 'dart:convert';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Builds the per-tick update body once per distinct changed-handle set, and
/// splices each client's JSON-RPC envelope around it.
///
/// Lifetime is the server, not the tick: the instance is reused and
/// [beginTick] resets its per-tick state.
final class FrameEncoder {
  /// The one encoder in this class. Injected so tests can count calls — see
  /// the library doc for why counting is the only honest assertion here.
  final String Function(Object?) _encode;

  /// Signature of a changed-handle set → the body fragment already encoded
  /// for it. Cleared every tick, so it cannot grow without bound and cannot
  /// serve stale numbers.
  final Map<String, String> _bodies = {};

  FrameEncoder({String Function(Object?) encode = jsonEncode})
      : _encode = encode;

  /// Starts a new tick, discarding the previous tick's bodies.
  ///
  /// This is the whole lifetime policy of the cache. A body that survived a
  /// tick boundary would ship last tick's values under this tick's timestamp
  /// — a screen showing a stale number as current, which is the one failure
  /// this project exists to prevent — and the cache would also be an
  /// unbounded server-heap allocation keyed by client-influenced data.
  void beginTick() => _bodies.clear();

  /// The escaped JSON string literal for a subscription name, quotes included.
  ///
  /// A subscription name is client-chosen text and it is spliced into a frame
  /// we build by hand, so concatenating it raw is an injection into our own
  /// output stream. Call this **once per session**, when the subscription is
  /// created, and hand the result to [updateFrame] on every tick: escaping per
  /// tick would put an encode back on the per-client path and undo the whole
  /// point of this class.
  String subLiteral(String sub) => _encode(sub);

  /// The `c`/`q`/`r` fields of an [UpdateParams], encoded once per distinct
  /// changed-handle set within the current tick.
  ///
  /// Returns a JSON *fragment* — the object's contents without its braces, so
  /// [updateFrame] can splice it into the params object. Empty when nothing
  /// changed.
  ///
  /// The field names and the omit-when-empty rule are taken from
  /// `UpdateParams.toJson`; `frame_encoder_test.dart` round-trips a produced
  /// frame through `UpdateParams.fromJson` so a hand-built envelope cannot
  /// drift away from the DTO.
  String bodyFor(
    Map<int, WireValue> changes,
    Map<int, Quality> qualities,
    List<int> removed,
  ) {
    final signature = _signature(changes, qualities, removed);
    final cached = _bodies[signature];
    if (cached != null) return cached;

    final fields = <String, Object?>{
      if (changes.isNotEmpty)
        'c': {for (final e in changes.entries) '${e.key}': e.value.toJson()},
      if (qualities.isNotEmpty)
        'q': {for (final e in qualities.entries) '${e.key}': e.value.code},
      if (removed.isNotEmpty) 'r': removed,
    };
    final encoded = _encode(fields);
    // `{"c":…}` → `"c":…`; `{}` → ``. Splicing a fragment is what keeps the
    // envelope a concatenation instead of a second encode.
    final body = encoded.substring(1, encoded.length - 1);
    _bodies[signature] = body;
    return body;
  }

  /// One client's `u` notification: the shared [body] with this client's own
  /// addressing concatenated around it.
  ///
  /// [sub] must be the value [subLiteral] returned — an escaped JSON string
  /// literal, quotes included — not a bare name.
  String updateFrame({
    required String sub,
    required int seq,
    required int t,
    required int generation,
    required String body,
  }) {
    assert(sub.length >= 2 && sub.startsWith('"') && sub.endsWith('"'),
        'sub must come from subLiteral(); a raw name produces invalid JSON');
    final tail = body.isEmpty ? '' : ',$body';
    // `g` alongside `sub`/`seq`/`t` in the envelope rather than in the shared
    // body: it is per subscription, so two clients whose changed-handle sets
    // match still share one encoded body. One integer written by
    // concatenation costs nothing the envelope was not already paying.
    return '{"jsonrpc":"2.0","method":"${Methods.update}",'
        '"params":{"sub":$sub,"seq":$seq,"t":$t,"g":$generation$tail}}';
  }

  /// A cheap identity for a changed-handle set: the three collections' handles
  /// in ascending order.
  ///
  /// Sorted because two clients' drains can iterate the same handles in
  /// different insertion orders; unsorted, they would miss each other's cached
  /// body and pay two encodes for one set.
  String _signature(
    Map<int, WireValue> changes,
    Map<int, Quality> qualities,
    List<int> removed,
  ) {
    final buffer = StringBuffer();
    _appendSorted(buffer, changes.keys);
    buffer.write('|');
    _appendSorted(buffer, qualities.keys);
    buffer.write('|');
    _appendSorted(buffer, removed);
    return buffer.toString();
  }

  void _appendSorted(StringBuffer buffer, Iterable<int> handles) {
    final sorted = handles.toList(growable: false)..sort();
    for (var i = 0; i < sorted.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(sorted[i]);
    }
  }
}
