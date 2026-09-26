/// The thirteen ways a peer on the other end of a message channel sends
/// something the decoder was not written for.
///
/// This is the wire-fault injector Phase 1's review cycle demanded. All five of
/// that phase's Critical findings clustered at the undefended decode boundary
/// and no sabotage variant aimed there, so the boundary was being judged by
/// well-formed messages only. Everything here is well-formed messages' opposite,
/// applied at [channelPair]'s seam — the point a socket would occupy — in the
/// server → client direction only.
///
/// Each entry is a real-world instance of something, in the same way
/// `broken_write.dart`'s three sabotages are:
///
///  * a **truncated** frame is a process killed mid-write, or a socket that
///    went away with a partial buffer flushed;
///  * **garbage** is a captive portal, a proxy error page, or a TLS alert
///    arriving where a body was expected;
///  * a **duplicate** is a framing bug that concatenated two documents;
///  * a **dropped field** is a peer speaking a slightly older dialect;
///  * a **retyped** field is a gateway that re-encoded a body and got a type
///    wrong on the way through;
///  * a **rewritten id** is an answer to a request nobody is waiting for, which
///    is what a reconnect that replayed a queue produces;
///  * **`1e999`** is a PLC value that overflowed a double — the one entry here
///    that is not a bug in anybody's software, just arithmetic;
///  * an **oversize** frame is a historian query that matched more rows than
///    the caller expected;
///  * an **unpaired surrogate** is a string that was cut in half between its
///    two UTF-16 code units by something counting characters.
///
/// ## The measured outcomes, and why they are written down here
///
/// `json_rpc_2.Peer` **never fails a pending request on a malformed response.**
/// It wraps the channel in `respondToFormatExceptions`, which replies `-32700`
/// to the sender and continues; the client half of the Peer is never told that
/// a response it was waiting for failed to arrive. So nine of the entries below
/// leave the request **HUNG** — unsettled, forever, with the peer still open
/// and still answering everything else — and four resolve. Which is which is
/// not inferable: a `result` typed as a String resolves, an `id` typed as a Map
/// hangs. RESEARCH Finding 15 measured all thirteen rows, and each entry's doc
/// cites its row, because a catalogue whose outcomes had to be re-derived by
/// every reader would be re-derived wrongly.
///
/// Three of those outcomes are threats that this package cannot fix and does
/// not pretend to:
///
///  * the hang is T-02-27, transferred to Phase 4 and mitigated there — a
///    per-request deadline in `RemoteStateMan` turns it into an honest
///    `WriteUnknown`, verified in
///    `packages/tfc_relay_client/test/truncated_write_test.dart`, whose
///    counterpart here (`test/channel/truncated_write_test.dart`) goes on
///    holding the un-deadlined behaviour in place so the two can be compared;
///  * `1e999` arriving as `Infinity` is T-02-28, transferred to Phases 3-4 —
///    `sanitize` has to run on the decode path, not only on encode;
///  * the absence of any frame-size limit is T-02-29, transferred to Phase 3.
///
/// And one note for Phase 3's server, which nothing in Phase 2 can act on:
/// `-32700` **echoes the offending payload back** in `data.request`. An 8 MiB
/// garbage frame therefore produces an 8 MiB error response, which is an
/// amplifier pointed at whoever is logging it (T-02-30). Capping what goes into
/// `data` is the server's job.
///
/// ## Discipline
///
/// One surgical change per entry, leaving the rest of the message valid, so a
/// failure is attributable to that entry and not to a message that was broken
/// in three ways at once. That is `broken_write.dart:19-23`'s rule, for the
/// same reason: a fault that breaks everything proves nothing about anything.
///
/// The catalogue is data — [malformedPeerCatalogue], keyed by name, following
/// `contractRegistries` (`tfc_stateman_contract.dart:96-104`) — so a test can
/// iterate it and assert that every entry has a case, in both directions.
///
/// Corruptions are applied to *every* matching message unless composed with
/// [onFirstMatching], which is almost always what a test wants: damage one
/// message, then ask the same session an uncorrupted question and see whether
/// it still answers. That second half is the point. A malformed frame does not
/// take the link down; it takes one request down and leaves the link looking
/// healthy.
library;

import 'dart:convert';
import 'dart:math' as math;

/// A transform applied to one encoded message in flight.
///
/// The same signature `channelPair(corruptServerToClient: …)` takes, so any
/// entry here can be handed to the harness directly.
typedef MessageCorruption = String Function(String message);

/// The field [poisonNumber] adds, so a test can find what it decoded to.
const poisonedKey = 'poisoned';

/// The field [oversize] pads, so a test can measure what arrived.
const padKey = 'pad';

/// The field [unpairedSurrogate] writes its lone `\ud800` into.
const loneSurrogateKey = 'loneSurrogate';

/// The frame size [malformedPeerCatalogue]'s `oversize` entry inflates to.
///
/// 8 MiB, from Finding 15's row: it resolves in full, because there is no
/// frame-size limit anywhere in the path.
const oversizeBytes = 8 * 1024 * 1024;

// ---------------------------------------------------------------- truncation

/// Delivers only the first [characters] of the encoded message.
///
/// Measured: **HUNG** (Finding 15, rows "truncated — last 5 chars dropped" and
/// "truncated — first char only"). The prefix fails to parse, the receiving
/// peer replies `-32700` to the sender, and the pending request is left
/// unsettled with the peer still open. This is CR-01's real shape: a truncated
/// write result does not throw, it never arrives.
MessageCorruption truncateTo(int characters) =>
    (message) => message.substring(0, math.min(characters, message.length));

/// Delivers the leading [fraction] of the encoded message.
///
/// Measured: **HUNG** (Finding 15, as [truncateTo]). Expressed as a fraction
/// because a frame cut by a dead socket is cut wherever the buffer ended, not
/// at a character count anybody chose.
MessageCorruption truncate(double fraction) => (message) =>
    truncateTo((message.length * fraction).floor())(message);

// ------------------------------------------------------------- not a message

/// Replaces the message with bytes that are not JSON at all.
///
/// Measured: **HUNG** (Finding 15, row "garbage bytes"). The request is left
/// unsettled; the `-32700` sent back carries the garbage in `data.request`.
MessageCorruption garbage() => (_) => '<not json>';

/// Replaces the message with a zero-length one.
///
/// Measured: **HUNG** (Finding 15, row "empty string"). Worth its own entry
/// because an empty frame is what a half-open socket produces and because
/// `''` is the input most hand-written decoders forget.
MessageCorruption empty() => (_) => '';

/// Sends the message twice, concatenated, as one frame.
///
/// Measured: **HUNG** (Finding 15, row "two JSON documents concatenated"). The
/// concatenation is not valid JSON, so neither copy is delivered — including
/// the first one, which on its own would have settled the request. A framing
/// bug therefore loses the very message it duplicated.
MessageCorruption duplicate() => (message) => '$message$message';

// ------------------------------------------------------------- field surgery

/// Removes [name] from the top level of the message.
///
/// Measured with `'jsonrpc'`: **HUNG** (Finding 15, row "missing jsonrpc
/// key"). `strictProtocolChecks` defaults to true and is the difference
/// between rejecting and accepting this; the default is deliberately kept,
/// because the non-strict behaviour — the same frame quietly accepted — is
/// itself a corruption worth having a test for.
MessageCorruption dropField(String name) =>
    _rewrite((json) => json.remove(name));

/// Replaces the value of [field] with [value], leaving every other field
/// valid.
///
/// The entry whose two uses disagree, which is the reason the outcomes are
/// written down rather than reasoned about:
///
///  * `retype('id', <Map>)` — **HUNG** (Finding 15, row "id is a Map"): the
///    envelope is checked, so an id of the wrong type is rejected and the
///    request left unsettled.
///  * `retype('result', <String>)` — **resolves** (Finding 15, row "result is
///    a String where a Map is expected"): the *payload* is not checked at all.
///    The caller receives a String and casts it, and where that cast lands is
///    application code, not the envelope.
MessageCorruption retype(String field, Object? value) =>
    _rewrite((json) => json[field] = value);

/// Rewrites the response's `id` to [id] — an answer to a request nobody sent.
///
/// Measured: **HUNG** (Finding 15, row "id replaced with an unknown value").
/// The peer has no pending request under that id, so the response is
/// discarded, and the request that *is* pending is left unsettled. This is
/// what a reconnect that replayed a queue produces.
MessageCorruption rewriteId(Object? id) => _rewrite((json) => json['id'] = id);

// -------------------------------------------------------------- payload rot

/// Adds a [poisonedKey] field holding `1e999` to the result.
///
/// Measured: **resolves**, and the value arrives in application code as
/// `Infinity` (Finding 15, row "result contains 1e999"). The envelope does not
/// defuse it and no decoder in the path raises.
///
/// The asymmetry is the finding: `jsonEncode(double.infinity)` *throws*, so the
/// outbound direction fails loudly while the inbound direction fails silently.
/// `sanitize` is the only defence and it has to run on decode as well as on
/// encode (T-02-28).
///
/// Written by textual substitution because there is no way to reach `1e999`
/// through `jsonEncode` — encoding an infinity is exactly what throws.
MessageCorruption poisonNumber({bool negative = false}) => (message) {
      final decoded = _decodeObject(message);
      if (decoded == null) return message;
      _intoResult(decoded, poisonedKey, 0);
      return jsonEncode(decoded).replaceFirst(
        '"$poisonedKey":0',
        '"$poisonedKey":${negative ? '-' : ''}1e999',
      );
    };

/// Pads the result until the encoded message is at least [bytes] long.
///
/// Measured with 8 MiB: **resolves in full** (Finding 15, row "result padded
/// to 8 MiB). There is no frame-size limit anywhere in the path — not in the
/// channel, not in the envelope — which is the entry's whole point. The cap
/// belongs to Phase 3's server session (T-02-29), and this is the test that
/// will hold it once it exists.
MessageCorruption oversize(int bytes) => (message) {
      final decoded = _decodeObject(message);
      if (decoded == null) return message;
      _intoResult(decoded, padKey, 'x' * math.max(0, bytes - message.length));
      return jsonEncode(decoded);
    };

/// Writes a lone `\ud800` — half of a surrogate pair — into the result.
///
/// Measured: **resolves**, and it does **not** throw at any point — which is
/// the part worth having a test for. A string cut in half between its two
/// UTF-16 code units arrives mangled rather than missing, so nothing anywhere
/// reports that a value changed.
///
/// Finding 15's row reads "silently replaced with U+FFFD". Re-measured over
/// this String-based channel it is more precise than that, and the difference
/// is a fact about the two harness layers rather than about the corruption:
///
///  * **message layer** (here): the lone high surrogate survives intact, as
///    one UTF-16 code unit `0xD800`, because nothing between the peers ever
///    encoded it to bytes;
///  * **byte layer** (a socket, and plan 02-12's proxy): `utf8.encode` emits
///    `EF BF BD` for it, so the same frame arrives as U+FFFD.
///
/// So the two layers hand application code two different strings for one
/// frame, and a comparison written against one of them fails on the other.
/// `test/channel/malformed_peer_test.dart` asserts both halves.
MessageCorruption unpairedSurrogate() => (message) {
      final decoded = _decodeObject(message);
      if (decoded == null) return message;
      const marker = '__lone_surrogate__';
      _intoResult(decoded, loneSurrogateKey, marker);
      return jsonEncode(decoded).replaceFirst('"$marker"', r'"\ud800"');
    };

// -------------------------------------------------------------- combinators

/// Applies [corruption] to the first message satisfying [when], and forwards
/// everything else verbatim.
///
/// The combinator that keeps a corruption surgical. Without it a transform
/// damages every message the session ever sends, so the follow-up question
/// that proves the session survived would be damaged too, and the proof would
/// be measuring the injector rather than the peer.
MessageCorruption onFirstMatching(
  bool Function(String message) when,
  MessageCorruption corruption,
) {
  var fired = false;
  return (message) {
    if (fired || !when(message)) return message;
    fired = true;
    return corruption(message);
  };
}

/// Whether [message] is a JSON-RPC response — an answer with an id, rather
/// than a notification or a request.
///
/// Used as [onFirstMatching]'s predicate so a corruption lands on an answer.
/// Evaluated against the message *before* corruption, so a transform that
/// destroys the JSON does not stop its own predicate from matching.
bool isResponse(String message) {
  final decoded = _decodeObject(message);
  return decoded != null &&
      decoded['id'] != null &&
      (decoded.containsKey('result') || decoded.containsKey('error'));
}

// ----------------------------------------------------------------- registry

/// Every corruption, keyed by name, as data.
///
/// Iterable, so `test/channel/malformed_peer_test.dart` can assert that each
/// entry has a proof of its measured outcome and 02-14's sweep can assert that
/// each entry has a case. Nine of these hang and four resolve; see each
/// entry's doc for its Finding 15 row.
final malformedPeerCatalogue = Map<String, MessageCorruption>.unmodifiable(
  <String, MessageCorruption>{
    // HUNG — the tail of the frame never arrived.
    'truncateTail': truncate(0.9),
    // HUNG — cut in the middle.
    'truncateHalf': truncate(0.5),
    // HUNG — an opening brace and nothing else.
    'truncateToFirstCharacter': truncateTo(1),
    // HUNG — not JSON at all.
    'garbage': garbage(),
    // HUNG — a zero-length frame.
    'empty': empty(),
    // HUNG — two documents in one frame; both are lost.
    'duplicate': duplicate(),
    // HUNG — strict protocol checks reject an envelope with no version.
    'dropJsonrpc': dropField('jsonrpc'),
    // HUNG — the envelope IS type-checked, unlike the payload.
    'retypeId': retype('id', const {'not': 'an id'}),
    // HUNG — an answer to a request nobody is waiting for.
    'rewriteId': rewriteId('nobody-is-waiting'),
    // RESOLVES — the payload is not type-checked at all.
    'retypeResult': retype('result', 'oops'),
    // RESOLVES — as Infinity, in application code.
    'poisonNumber': poisonNumber(),
    // RESOLVES — in full. There is no frame-size limit.
    'oversize': oversize(oversizeBytes),
    // RESOLVES — intact over a String channel, U+FFFD over a socket. Never
    // raised at either layer.
    'unpairedSurrogate': unpairedSurrogate(),
  },
);

// ------------------------------------------------------------------ plumbing

/// Decodes [message] as a JSON object, or null if it is not one.
Map<String, Object?>? _decodeObject(String message) {
  try {
    final decoded = jsonDecode(message);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Decodes, applies [change], re-encodes — and forwards anything that was not
/// a JSON object untouched, so an entry composed onto an already-corrupted
/// message degrades to a no-op rather than to an exception at the seam.
MessageCorruption _rewrite(void Function(Map<String, Object?> json) change) =>
    (message) {
      final decoded = _decodeObject(message);
      if (decoded == null) return message;
      change(decoded);
      return jsonEncode(decoded);
    };

/// Puts [key] into the message's `result` map, creating one if the result is
/// not a map, so a payload corruption stays inside the payload.
void _intoResult(Map<String, Object?> message, String key, Object? value) {
  final result = message['result'];
  if (result is Map<String, Object?>) {
    result[key] = value;
  } else {
    message['result'] = <String, Object?>{key: value};
  }
}
