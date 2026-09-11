/// The server-global key→handle table. Internal seam: an embedder configures
/// and starts a server, it does not mint handles.
///
/// Pure data structure: no I/O, no clock.
///
/// **Why this is server-global, and not per subscription.** Encode-once is
/// only literally achievable if the update body is byte-identical for every
/// client, and 03-RESEARCH Finding 3 shows what that costs if you get it
/// wrong. The body is `{"1":{"v":…},"2":{…}}` — handles, not keys — so two
/// panels watching the same motor must be handed the *same integer* or their
/// bodies differ and each one costs its own encode. Finding 2 measured that
/// bill on the alternative path: `Peer.sendNotification` JSON-encodes once per
/// peer, 7 639 µs/tick against 110 µs at 100 clients × 200 keys — **69.6×**,
/// with no error and no warning, invisible until the plant is on it. Minting
/// handles per subscription forces a per-client remap of every key in the
/// body, which is that same slow strategy arrived at by accident.
///
/// `SubscribeResult.handles` is already `Map<String, int>` returned per
/// subscribe, so handing back globally-consistent integers needs no change to
/// the wire contract: two clients subscribing to one key simply see the same
/// number.
///
/// **Lifetime is permanent this phase** (03-CONTEXT amendment: the key space
/// is bounded — a plant has the tags it has). There is deliberately no method
/// to give a handle back: the absence *is* the enforcement, because reuse
/// would point a reconnecting panel at whichever tag inherited its integer.
/// The size assertions in `handle_table_test.dart` are the first half of that
/// guarantee; 03-11's teardown test is the second, asserting the table is
/// unmoved by session churn. If a future unbounded key source ever appears —
/// browse-generated keys, say — that teardown assertion is what catches it,
/// and the decision gets revisited then rather than silently.
library;

/// Maps plant keys to the dense small integers that ride the wire.
///
/// Monotonic from 1. Zero is never minted, so a zero-valued handle decoded
/// from a malformed frame resolves to nothing rather than to the first key.
final class HandleTable {
  final Map<String, int> _byKey = {};
  final Map<int, String> _byHandle = {};
  int _next = 1;

  /// The handle for [key], minting one on first sight.
  ///
  /// Idempotent: the second call, from any session, returns the first call's
  /// integer. That property is what the encode-once body depends on.
  int handleFor(String key) {
    final existing = _byKey[key];
    if (existing != null) return existing;
    final handle = _next++;
    _byKey[key] = handle;
    _byHandle[handle] = key;
    return handle;
  }

  /// One subscribe's worth of handles, in the order the keys were asked for.
  ///
  /// A key repeated within one call yields one entry, not two — the result is
  /// keyed by key.
  Map<String, int> handlesFor(Iterable<String> keys) {
    final result = <String, int>{};
    for (final key in keys) {
      result[key] = handleFor(key);
    }
    return result;
  }

  /// The key [handle] stands for, or null if it was never minted.
  ///
  /// This is how a write or a subscription change is resolved back to a tag,
  /// so a wrong inverse writes to the wrong place in the plant.
  String? keyOf(int handle) => _byHandle[handle];

  /// How many distinct keys have ever been seen. Never decreases.
  int get size => _byKey.length;

  /// Every key that has a handle, in mint order.
  Iterable<String> get keys => _byKey.keys;
}
