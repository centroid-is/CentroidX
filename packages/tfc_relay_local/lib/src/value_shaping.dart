/// The three pure transforms a plant keymapping implies.
///
/// All three were **lifted** from working code rather than reimplemented, and
/// the reason matters: their edge cases are the plant's, not this project's.
/// `extractSampleMembers` returning null when nothing resolves looks arbitrary
/// until a struct arrives with none of its members; the single-bit/multi-bit
/// split in `applyBitMask` looks like a micro-optimisation until a page full
/// of indicators reads permanently truthy because a mask started answering
/// `1` where it used to answer `true`.
///
/// | Function | Lifted from |
/// |---|---|
/// | [applyBitMask] | `packages/tfc_dart/lib/core/state_man.dart:1314-1327` (a pure static already) |
/// | [applyM2400Shaping] | the same file, inline at `:2064-2073` (subscribe) and `:1819-1827` (read) |
/// | [extractSampleMember] | `packages/tfc_dart/lib/core/collector.dart:62-69` |
/// | [extractSampleMembers] | the same file, `:75-85` |
///
/// ## The one adaptation, and it is not cosmetic
///
/// These operate on **`tfc_relay_protocol`'s [DynamicValue]**, which carries a
/// [DynamicValue.quality] and a [DynamicValue.sourceTime]. The open62541 class
/// of the same name — the one the shipped functions take — carries neither, so
/// the shipped code could not drop a quality it never had. Here it can, and a
/// transform that hands back a plain-good value from an uncertain sample is a
/// number nobody can tell was guessed. So every function below **carries the
/// quality out with the value**, worst-wins, by handing the extracted child
/// back through `DynamicValue`'s own sanitizing constructor with the parent's
/// quality as the parent quality — which is the same composition
/// (`Quality.worst` plus "within one band the more specific code beats plain
/// good") that a struct's own members already get. Never a hand-rolled max.
///
/// There are two classes named `DynamicValue` in this solve. Files in this
/// package that touch both — the protocol adapters of 08-07 and 08-10 — should
/// import the OPC UA one under a prefix (`import
/// 'package:open62541/open62541.dart' as ua;`), the way `state_man.dart:14`
/// does in reverse for jbtm. **This file needs no such import**: every type it
/// names is a relay type, and an unused import would be an analyzer failure
/// arguing for a convention rather than following one.
///
/// ## Why `sample_members` is here with no consumer
///
/// Collection is Phase 8b (see 08-PLAN-INDEX), so nothing in Phase 8 calls
/// [extractSampleMembers]. It is lifted here anyway, deliberately: it belongs
/// beside its two siblings, it is fifteen lines, and 8b consuming a function
/// that already has tests is better than 8b writing it under time pressure.
/// If a reviewer objects to unused code, this paragraph is the answer.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Applies a bit mask to a raw value.
///
/// Ported semantics, unchanged: a null [bitMask] returns [value] untouched, a
/// non-numeric value passes through, a **single-bit** mask yields a `bool` and
/// a **multi-bit** mask yields the masked-and-shifted `int`.
///
/// The single-bit test is the power-of-two check `bitMask & (bitMask - 1) == 0`
/// from the shipped static. Getting it wrong in the generous direction — ints
/// where the page expects bools — turns every indicator bound through this
/// mask permanently truthy, because `1` is as true as `true` to a widget that
/// only asks `asBool`. That is a screen full of green while the line is down
/// (T-08-15).
DynamicValue applyBitMask(DynamicValue value, int? bitMask, int? bitShift) {
  if (bitMask == null) return value;
  final raw = value.value;
  if (raw is! num) return value;

  final masked = (raw.toInt() & bitMask) >>> (bitShift ?? 0);
  final isSingleBit = bitMask != 0 && (bitMask & (bitMask - 1)) == 0;

  // copyWith, not a fresh DynamicValue: the shipped line builds a new one and
  // drops everything it was not explicitly given, which on this class would
  // silently discard the quality and the source time.
  return isSingleBit
      ? value.copyWith(value: masked != 0, typeId: ValueType.boolean)
      : value.copyWith(value: masked);
}

/// The M2400 weigher shaping: filter on the status field, then extract the
/// named one.
///
/// Both shipped paths do this inline and in this order, and the order is the
/// point: the filter decides whether the sample exists at all, and only then
/// is a field taken out of it.
///
///  * A record whose `status` does not equal [statusFilter] yields **null** —
///    the sample is *filtered*, not emitted as a null-valued reading. A null
///    reading would overwrite the last good weight on the operator's screen
///    with a dash every time a batch record of the wrong kind went past.
///  * A record that passes yields the member named by [field], carrying the
///    record's quality and source time with it.
///  * With no [field] the whole record is the value.
///
/// **Two departures from the shipped inline code, both in the same direction.**
/// The shipped path indexes with `dv['status']` and `dv[fieldName]`, and on
/// this class `operator []` throws [StateError] on a missing member. A throw
/// here would cost the poll cycle rather than the tag, which is the standing
/// constraint stated backwards. So a record with no `status` where a filter is
/// configured, and a [field] the record does not carry, both answer a
/// [Quality.errorConfig] value with a null payload: the tag is misconfigured,
/// waiting will not fix it, and the last plausible number must stop rendering.
/// Silently filtering those instead would be the page-reads-unknown-forever
/// failure with nothing in any log saying why.
DynamicValue? applyM2400Shaping(
  DynamicValue record, {
  int? statusFilter,
  String? field,
}) {
  if (statusFilter != null) {
    if (!record.contains('status')) return _misconfigured(record);
    if (record['status'].asInt != statusFilter) return null;
  }
  if (field == null) return record;
  if (!record.contains(field)) return _misconfigured(record);
  return _carryingParent(record[field], record);
}

/// Resolves [path] (dotted member segments) inside a structured [value].
///
/// Returns null when any segment is missing or the current level is not a
/// struct — the caller skips that member rather than inserting garbage.
DynamicValue? extractSampleMember(DynamicValue value, String path) {
  var current = value;
  for (final segment in path.split('.')) {
    if (!current.isObject || !current.contains(segment)) return null;
    current = current[segment];
  }
  // Identity means the path was empty; there is nothing to carry.
  return identical(current, value) ? value : _carryingParent(current, value);
}

/// Builds the one-row-per-sample object for a `sample_members` collection:
/// each resolvable path becomes a member keyed by its **full dotted path**.
///
/// The full path is the key, not the leaf name, because two members called the
/// same thing under two different parents would otherwise collide and one
/// chart would silently plot the other one.
///
/// Returns null when **no** member resolves — that sample is skipped entirely
/// rather than inserted as an empty row. A table of empty rows is worse than a
/// gap: the gap is visible.
DynamicValue? extractSampleMembers(DynamicValue value, List<String> members) {
  final row = <String, DynamicValue>{};
  for (final path in members) {
    final member = extractSampleMember(value, path);
    if (member == null) continue;
    row[path] = member;
  }
  if (row.isEmpty) return null;
  // The constructor composes worst-wins over the members for us, so one bad
  // member makes the row bad without anything here comparing bands.
  return DynamicValue(
    value: row,
    quality: value.quality,
    sourceTime: value.sourceTime,
  );
}

/// A configured tag the record cannot answer for.
DynamicValue _misconfigured(DynamicValue record) => DynamicValue(
      value: null,
      quality: Quality.errorConfig,
      sourceTime: record.sourceTime,
    );

/// [child] with [parent]'s quality composed over its own and [parent]'s source
/// time if the child has none.
///
/// The composition is `DynamicValue`'s, reached by handing the child straight
/// to the sanitizing constructor: worst-wins across bands, and within one band
/// the more specific code beats plain `good` — which is how a member with a
/// write in flight keeps its badge instead of reporting healthy.
DynamicValue _carryingParent(DynamicValue child, DynamicValue parent) =>
    DynamicValue(
      value: child,
      quality: parent.quality,
      sourceTime: child.sourceTime ?? parent.sourceTime,
      typeId: child.typeId,
      sourceTypeId: child.sourceTypeId,
      displayName: child.displayName,
      description: child.description,
      enumFields: child.enumFields,
    );
