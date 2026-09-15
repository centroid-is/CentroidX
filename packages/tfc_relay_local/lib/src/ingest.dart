/// One poisoned tag costs one tag.
///
/// The standing constraint since Phase 1, reaching here the first code able to
/// break it: **sanitize failure = ONE TAG fails, never a poll cycle.**
///
/// `sanitize` throws `ArgumentError` on depth > 64 or on a self-referential
/// structure (`packages/tfc_relay_protocol/lib/src/sanitize.dart:33-39`), and
/// `DynamicValue`'s constructor enforces the same bound on the way in
/// (`dynamic_value.dart:609-619`) — deliberately, because that constructor runs
/// *on the gateway* over structures the **upstream** controls. A struct-heavy
/// TwinCAT tag is exactly where a depth-64 structure appears, and the honest
/// framing is that the bound will be hit by ordinary configuration and not by
/// an attacker.
///
/// So the `try`/`catch` is **per key**, and the arithmetic is the whole point:
/// a poll cycle at this plant is 430 tags. Wrapping the batch costs 429 good
/// readings to one bad one, and costs them silently — every affected page reads
/// unknown, and nothing anywhere says which tag did it. Wrapping the key costs
/// one tag and names it.
///
/// ## What is caught
///
/// Every `Object`, not just `ArgumentError`. Narrowing the catch to the one
/// exception `sanitize` documents would make the guarantee depend on the
/// converters — which 08-07 and 08-10 have not written yet — never throwing
/// anything else, and that is a promise about code that does not exist. The
/// boundary's job is that one tag's conversion cannot cost the cycle, whatever
/// went wrong inside it; the error object is kept, so a diagnosis is not lost
/// in exchange.
///
/// ## Worst-wins is not re-implemented here
///
/// There is deliberately no hand-rolled quality comparison in this file.
/// `DynamicValue`'s constructor composes worst-wins over the supplied quality
/// and every child's, and mints `Quality.badNonFinite` through `Quality.worst`
/// for a non-finite leaf (`dynamic_value.dart:643-648`). Calling it *is* the
/// composition. A second implementation here would be a second thing to keep
/// right, and the two would disagree on the day somebody added a code.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// One key/value pair as it came off a link, **before** any sanitizing.
///
/// The `raw` is whatever the protocol converter produced: a number, a string, a
/// nested map for a struct, a list for an array. `FakeUpstreamLink.rawEmissions`
/// hands these out unsanitized for the same reason — a converter tested against
/// its own output proves only that it is consistent with itself.
typedef RawSample = ({String key, Object? raw});

/// What one batch produced, and what it refused.
final class IngestOutcome {
  IngestOutcome({
    required Map<String, DynamicValue> batch,
    required Map<String, Object> refusals,
  })  : batch = Map<String, DynamicValue>.unmodifiable(batch),
        refusals = Map<String, Object>.unmodifiable(refusals);

  /// The `ValueStore.applyBatch` argument: **every** key that was offered,
  /// including the refused ones. A refused key is present carrying a bad
  /// quality and a null value, never absent — a missing entry is a blank where
  /// a fault belongs.
  final Map<String, DynamicValue> batch;

  /// The keys whose **final** entry in [batch] is a refusal, and what threw.
  ///
  /// Per key, never per file and never per cycle. "Final" matters when a key
  /// appears twice in one cycle (08-REVIEW IN-02): the batch is keyed by name,
  /// so a later good sample replaces an earlier refused one, and reporting the
  /// key as refused would describe a value that is not the one every
  /// subscriber is about to read.
  ///
  /// **[IngestLog] still records the throw.** The two are different questions
  /// — *what is this batch publishing as bad* versus *what has ever failed to
  /// convert* — and the log is the one that answers the second, which is the
  /// one a converter bug shows up in.
  final Map<String, Object> refusals;

  /// How many keys converted cleanly.
  ///
  /// Counted by asking the batch, not by subtracting (08-REVIEW IN-02).
  /// [batch] is keyed by name, so a key appearing twice in one poll cycle
  /// collapses to one entry while `batch.length - refusals.length` went on
  /// treating the two maps as if they described the same population — and
  /// counted a key that had landed as refused, reaching zero or below it on a
  /// cycle with several such keys. Diagnostics only, but this number is
  /// described below as evidence somebody reads.
  int get landed =>
      batch.keys.where((key) => !refusals.containsKey(key)).length;

  @override
  String toString() =>
      'IngestOutcome(landed: $landed, refused: ${refusals.length})';
}

/// Remembers which keys have already been complained about.
///
/// **Once per key per process, not once per sample.** A struct that fails at
/// 10 Hz writes 864,000 identical lines a day, and the second one says nothing
/// the first did not — while the volume is itself a fault, because a log that
/// rotates every twenty minutes has lost the evidence of everything else.
final class IngestLog {
  IngestLog({void Function(String key, Object error)? sink}) : _sink = sink;

  final void Function(String key, Object error)? _sink;
  final Set<String> _seen = <String>{};

  int _refusals = 0;
  int _logged = 0;

  /// Every refusal ever seen, counted. The number is a diagnostic in its own
  /// right: a key refused twice is a converter bug, a key refused ten thousand
  /// times is a tag somebody should re-map.
  int get refusals => _refusals;

  /// How many refusals actually reached the sink.
  int get logged => _logged;

  /// The distinct keys that have been refused.
  Set<String> get refusedKeys => Set<String>.unmodifiable(_seen);

  /// Records one refusal; returns whether this is the first for [key].
  bool note(String key, Object error) {
    _refusals++;
    if (!_seen.add(key)) return false;
    _logged++;
    _sink?.call(key, error);
    return true;
  }
}

/// The quality a value the converter could not represent reads as.
///
/// `errorConfig` and not a bad-band code, because the two say different things
/// and only one of them is true here: `badCommFault` means the link is down and
/// waiting might fix it, while `errorConfig` means the configuration is wrong
/// and waiting will not. A structure this gateway cannot represent is the
/// second, and telling an operator to wait for something that is never coming
/// is worse than telling them nothing.
const Quality refusedSampleQuality = Quality.errorConfig;

/// Converts a batch of raw upstream samples into a `ValueStore.applyBatch`
/// argument, refusing at most one key at a time.
///
/// [quality] is the quality the link established for this batch — good for an
/// ordinary sample, `uncertainLastKnown` for a snapshot after a reconnect. It
/// is composed with whatever the value itself implies (a non-finite leaf mints
/// `badNonFinite`) by `DynamicValue`'s own constructor; see the library doc.
IngestOutcome ingestSamples(
  Iterable<RawSample> samples, {
  Quality quality = Quality.good,
  DateTime? sourceTime,
  IngestLog? log,
}) {
  final batch = <String, DynamicValue>{};
  final refusals = <String, Object>{};
  for (final sample in samples) {
    try {
      batch[sample.key] = DynamicValue(
        value: sample.raw,
        quality: quality,
        sourceTime: sourceTime,
      );
      // A later good sample for a key that failed earlier in the same cycle
      // REPLACES its refusal, because it has already replaced its value: the
      // batch is keyed by name (08-REVIEW IN-02). The throw is not forgotten —
      // `log` has it, and that is where a converter bug is diagnosed from.
      refusals.remove(sample.key);
    } catch (error) {
      refusals[sample.key] = error;
      log?.note(sample.key, error);
      // A null payload, always. The last plausible number must stop rendering:
      // a good-quality 0 on a speed tag is a stopped conveyor and a
      // good-quality false on a permit is an interlock reading satisfied, and
      // neither of those happened.
      batch[sample.key] =
          DynamicValue(value: null, quality: refusedSampleQuality);
    }
  }
  return IngestOutcome(batch: batch, refusals: refusals);
}
