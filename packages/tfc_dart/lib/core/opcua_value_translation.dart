/// The one open62541 → relay-protocol value crossing point, worker-side.
///
/// **This is the pipe's vocabulary edge.** The C-coupled `package:open62541`
/// `DynamicValue` stops here; everything downstream speaks the pure-Dart
/// `tfc_relay_protocol` vocabulary. [translateOpcUaSample] is the only function
/// that reads a binding sample and mints a protocol value, and it exists as its
/// own function, with its own tests and its own doc, for exactly that reason.
///
/// Moved down from `tfc_relay_local/lib/src/opcua_upstream_link.dart` in Phase
/// 12 so `tfc_dart` — which cannot depend on `tfc_relay_local` — holds the
/// single source of truth for the quality table and the converter. relay_local
/// re-exports these symbols so its own call sites keep compiling; two copies of
/// the quality table is exactly the divergence the v1.0 post-mortem (§11) warns
/// about.
///
/// **IMPORT-PREFIX HAZARD (R-6).** Two classes are called `DynamicValue` in
/// this solve, and two are called `LocalizedText`. Inside `tfc_dart`,
/// `package:open62541` is the native tongue and is imported **bare**; the relay
/// protocol — the one with [relay.DynamicValue.quality] and
/// [relay.DynamicValue.sourceTime] as first-class fields — is prefixed
/// `as relay`. The prefix is **not optional**: the protocol barrel also
/// re-exports `StateManApi`, a name `tfc_dart`'s own `StateMan` does not
/// implement, so an unprefixed import would collide. `translateOpcUaSample`'s
/// return type is therefore `relay.DynamicValue` and its `sample` parameter
/// stays the bare (open62541) `DynamicValue`. Only `relay.DynamicValue` may
/// ever cross the pipe.
library;

import 'package:open62541/open62541.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

// --------------------------------------------------------- the status codes
//
// Named constants rather than magic numbers, because the mapping below is the
// document a future reader checks against Part 4 and a hex literal in a switch
// is not checkable.

/// `Good`. Also what an *absent* status means (Part 4), which is why a null
/// code and a zero code answer the same quality — and why the adapter still
/// keeps them apart on the way in: `0` is a positive claim, `null` is the
/// absence of one.
const int opcUaStatusCodeGood = 0x00000000;

/// The `Uncertain` band's high bit.
const int opcUaUncertainMask = 0x40000000;

/// The `Bad` band's high bit.
const int opcUaBadMask = 0x80000000;

/// The tag is not in the address space at all.
const int opcUaBadNodeIdUnknown = 0x80340000;

/// The node id was syntactically refused.
const int opcUaBadNodeIdInvalid = 0x80330000;

/// The attribute does not exist on that node.
const int opcUaBadAttributeIdInvalid = 0x80350000;

/// The value does not fit the node's data type.
const int opcUaBadTypeMismatch = 0x80740000;

/// The link itself failed.
const int opcUaBadCommunicationError = 0x80050000;

/// The session or its channel is gone.
const int opcUaBadSessionIdInvalid = 0x80250000;

/// A read callback on the server threw. The fixture produces this one, and so
/// does a real PLC with an unhappy data source.
const int opcUaBadInternalError = 0x80020000;

/// The server is serving the last value it had, and says so.
const int opcUaUncertainLastUsableValue = 0x40900000;

/// Maps an OPC UA `StatusCode` onto the relay quality an operator reads.
///
/// The table is 08-RESEARCH §C.4's, and the reason it is a table rather than a
/// band check is that the two bad answers mean opposite things to the person
/// standing next to the machine:
///
/// | StatusCode | Quality | Why |
/// |---|---|---|
/// | absent, or `Good` (0) | [relay.Quality.good] | An absent status means Good (Part 4) |
/// | `BadNodeIdUnknown` (0x80340000) | [relay.Quality.errorConfig] | The tag left the address space. **Waiting will not fix it** |
/// | `BadNodeIdInvalid` (0x80330000) | [relay.Quality.errorConfig] | Same: the configuration names a node this server does not have |
/// | `BadAttributeIdInvalid` (0x80350000) | [relay.Quality.errorConfig] | Same, one level down |
/// | `BadTypeMismatch` (0x80740000) | [relay.Quality.errorTypeMismatch] | The mapping and the PLC disagree about the type |
/// | any other `Bad` (0x8…) | [relay.Quality.badCommFault] | Something went wrong on the link and waiting **might** fix it |
/// | any `Uncertain` (0x4…) | [relay.Quality.uncertainLastKnown] | A number, openly labelled as not vouched for |
///
/// The default for an unrecognised `Bad` is deliberately the *transient* one.
/// Guessing `errorConfig` for a code this table does not name tells an operator
/// to stop waiting for something that may be seconds away from coming back,
/// and that is the more expensive of the two mistakes.
relay.Quality qualityForOpcUaStatus(int? code) {
  if (code == null || code == opcUaStatusCodeGood) return relay.Quality.good;
  switch (code) {
    case opcUaBadNodeIdUnknown:
    case opcUaBadNodeIdInvalid:
    case opcUaBadAttributeIdInvalid:
      return relay.Quality.errorConfig;
    case opcUaBadTypeMismatch:
      return relay.Quality.errorTypeMismatch;
  }
  if (code & opcUaBadMask != 0) return relay.Quality.badCommFault;
  if (code & opcUaUncertainMask != 0) return relay.Quality.uncertainLastKnown;
  // Everything below 0x40000000 is the Good band with sub-codes.
  return relay.Quality.good;
}

/// The same table, read out of a formatted error string.
///
/// The binding's `read`/`connect` failures arrive as text — and under
/// `useIsolate: true` they arrive as text *by construction*, because
/// `isolate.dart` marshals every error across the port as `e.toString()`
/// (08-01's finding, the same one that made the write path's numeric code a
/// non-contained change). So the string branch is not a fallback for sloppy
/// servers; it is the only branch the isolate path can take, and 08-06's
/// `WriteErrorText` exists for the same reason on the write side.
relay.Quality qualityForOpcUaErrorText(String text) {
  if (text.contains('BadNodeIdUnknown') || text.contains('BadNodeIdInvalid')) {
    return relay.Quality.errorConfig;
  }
  if (text.contains('BadAttributeIdInvalid')) return relay.Quality.errorConfig;
  if (text.contains('BadTypeMismatch')) return relay.Quality.errorTypeMismatch;
  // **The binding's own decode failures, by their exact sentences.** The
  // pinned binding throws `'Unsupported nodeId type: …'` when a variant's
  // declared DataType has no payload mapping (`common.dart:170` — the bench's
  // Guid/ByteString/LocalizedText/Range keys), and `'Unsupported binary
  // encoding id: …'` when an ExtensionObject's encoding is unknown to it
  // (`opcua_serializer.dart:322`). Both are statements about THIS binding and
  // THAT type, not about the link: waiting will not fix either, so the
  // transient default below would be the wrong instruction. [relay.Quality
  // .errorTypeMismatch] rather than `errorConfig`, because the tag exists and
  // the mapping found it — what disagrees is the type the server serves and
  // the types this side can decode, which is 771's exact sentence: "the leaf
  // could not be decoded, so it reads null; the code is what stops that null
  // looking like an absent reading."
  if (text.contains('Unsupported nodeId type') ||
      text.contains('Unsupported binary encoding id')) {
    return relay.Quality.errorTypeMismatch;
  }
  return relay.Quality.badCommFault;
}

/// One monitored-item sample, translated.
///
/// Three facts from 08-01 shape this function and none of them are optional:
///
///  1. **Quality and source time come from the VALUE attribute only.** One
///     logical key is four monitored items — `monitor()` asks for DataType,
///     Value, Description and DisplayName — and only the VALUE attribute
///     arrives with a source timestamp. The binding already restricts the
///     recording to that attribute; this function is downstream of it and does
///     not have to re-check, but a caller that starts feeding it other
///     attributes' samples will clobber a Bad code with Good.
///  2. **A Bad sample carries no payload.** `hasValue` is clear on it, so
///     `statusCode != 0` arrives with a stale-or-null value. The value is
///     therefore dropped rather than published under a bad badge: a number
///     nobody measured, rendered greyed-out, is still a number nobody measured.
///  3. **Arrival is not freshness.** A sample arriving says something reached
///     the socket; [relay.DynamicValue.quality] is what says whether it is
///     worth reading.
///
/// When the server sends no source timestamp, [arrivedAt] is used and
/// [onSourceTimeFallback] is called — a counter or a one-time log, **not
/// silence** — and the quality is deliberately **not** degraded for it. A
/// server that omits the timestamp is not a server sending a bad reading, and
/// degrading it would make every such server permanently suspect (threat
/// T-08-25's other half).
relay.DynamicValue translateOpcUaSample(
  DynamicValue sample, {
  required DateTime arrivedAt,
  required void Function() onSourceTimeFallback,
}) {
  final quality = qualityForOpcUaStatus(sample.statusCode);
  final stamped = sample.sourceTimestamp;
  if (stamped == null) onSourceTimeFallback();
  final sourceTime = stamped ?? arrivedAt;
  final bad = quality.isBad || quality.isError;
  return relay.DynamicValue(
    value: bad ? null : _plainValueOf(sample),
    quality: quality,
    sourceTime: sourceTime,
  );
}

/// The payload of a binding value, as something the relay's sanitizing
/// constructor will accept.
///
/// Structs and arrays are handed over as-is and [relay.DynamicValue]'s own
/// normalisation does the rest — including the depth bound, whose refusal is
/// the standing "one tag, never a poll cycle" constraint.
Object? _plainValueOf(DynamicValue sample) {
  final raw = sample.value;
  if (raw is DynamicValue) return _plainValueOf(raw);
  if (raw is List) {
    return <Object?>[
      for (final element in raw)
        element is DynamicValue ? _plainValueOf(element) : element,
    ];
  }
  if (raw is Map) {
    return <String, Object?>{
      for (final entry in raw.entries)
        '${entry.key}': entry.value is DynamicValue
            ? _plainValueOf(entry.value as DynamicValue)
            : entry.value,
    };
  }
  return raw;
}
