/// The one relay-protocol → open62541 value crossing point, backend-main side.
///
/// **The mirror of `opcua_value_translation.dart`, and deliberately not part of
/// it.** That file's whole doc is *"the one open62541 → relay crossing point,
/// worker-side"*; a reverse function living in it would make its first sentence
/// false, and the two directions are not symmetric — one is the pipe's ingress
/// on an acquisition isolate, the other is a consumer on main converting back
/// for a library it cannot change.
///
/// **Why the crossing exists at all.** `Expression`
/// (`core/boolean_expression.dart`) is typed on `package:open62541`'s
/// `DynamicValue` and stays that way — deferred idea DI-7. Every collector
/// sample condition and every conditional icon on every page evaluates through
/// it, so genericising it over the value type in a TDD phase risks the whole
/// app to save one converter. The backend therefore converts the pipe's value
/// for the boolean math and keeps the authoritative quality and source time on
/// the relay side, where they are first-class fields.
///
/// **What the caller must NOT read off the result.** The returned value carries
/// [DynamicValue.sourceTimestamp] and [DynamicValue.statusCode] because the
/// pinned open62541 build (branch `monitor-quality-sourcetime`,
/// `0251aa09`) has both fields and a converted value has no business being
/// lamer than the one it came from. But the status code is a *band*, not a
/// round trip: `relay.Quality` has four bands and dozens of subcodes with no
/// OPC UA counterpart, so `errorConfig` and `badCommFault` both come out as a
/// generic Bad. `AlarmRuleWatcher` gates on `relay.DynamicValue.quality` and
/// stamps from `relay.DynamicValue.sourceTime`, never on what comes out of
/// here.
///
/// **The absent payload is carried, never filled in.** A bad-quality relay
/// value has a null value (`translateOpcUaSample` nulls it at the ingress), and
/// this function passes the null through. Substituting a zero would be the
/// forged activation D-3 exists to prevent: `Expression._evaluate` reads a null
/// through `asDouble == 0.0`, so `tank.temp < 5` on a dead link would be true,
/// and no gate downstream could tell that number from a real reading.
///
/// **IMPORT-PREFIX HAZARD (R-6).** Same house rule as
/// `opcua_value_translation.dart`: inside `tfc_dart`, `package:open62541` is
/// the native tongue and is imported bare; the protocol — the one with
/// `quality` and `sourceTime` — is prefixed `as relay`. The prefix is not
/// optional; the protocol barrel also re-exports `StateManApi`, a name this
/// package's own `StateMan` does not implement.
library;

import 'dart:collection';

import 'package:open62541/open62541.dart';
import 'package:tfc_dart/core/opcua_value_translation.dart'
    show opcUaBadMask, opcUaStatusCodeGood, opcUaUncertainMask;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// [value] as an `open62541` value, member by member and element by element.
///
/// Structs (`Map<Object, relay.DynamicValue>`) and arrays
/// (`List<relay.DynamicValue>`) are rebuilt into a real object graph rather
/// than a `Map` hiding inside one value — the same recursion
/// `gateway_state_man.dart`'s `toUaValue` does on the panel, repeated here
/// because that file lives in the Flutter app and `tfc_dart` cannot depend on
/// it. A bare `Map` in `DynamicValue.value` answers `DynamicType.unknown` to
/// every accessor, so a struct member comparison in a formula would silently
/// read `0.0`.
///
/// [name] names the resulting value; nested members are named by their own key.
DynamicValue relayToUaValue(relay.DynamicValue value, {String? name}) {
  final raw = value.value;

  if (raw is Map<Object, relay.DynamicValue>) {
    final out = DynamicValue(name: name);
    out.value = LinkedHashMap<String, DynamicValue>();
    for (final entry in raw.entries) {
      final member = '${entry.key}';
      out[member] = relayToUaValue(entry.value, name: member);
    }
    return _stamp(out, value);
  }

  if (raw is List<relay.DynamicValue>) {
    final out = DynamicValue(name: name);
    out.value = <DynamicValue>[];
    for (var index = 0; index < raw.length; index++) {
      out[index] = relayToUaValue(raw[index]);
    }
    return _stamp(out, value);
  }

  return _stamp(DynamicValue(value: raw, name: name), value);
}

/// Copies the metadata the pinned build can hold onto [out].
///
/// The fields are not constructor parameters on this open62541 version, so they
/// are set after construction. Kept in one function so a value built on any of
/// the three branches above is stamped identically.
DynamicValue _stamp(DynamicValue out, relay.DynamicValue from) {
  out.sourceTimestamp = from.sourceTime;
  out.statusCode = _uaStatusForQuality(from.quality);
  return out;
}

/// The OPC UA status **band** for a relay quality.
///
/// Band only, and said so out loud: the forward table in
/// `opcua_value_translation.dart` is many-to-one (every unrecognised Bad code
/// becomes `badCommFault`), so no inverse exists. Returning the generic band
/// code is the honest answer — it says "bad" without inventing a reason a
/// server never gave. The uncertain and bad band bits are the same constants
/// the forward direction tests against, spelled once.
int _uaStatusForQuality(relay.Quality quality) {
  if (quality.isGood) return opcUaStatusCodeGood;
  if (quality.isUncertain) return opcUaUncertainMask;
  // Bad and error alike: the relay's error band is fed from OPC UA Bad codes
  // (`BadNodeIdUnknown` → `errorConfig`), so Bad is where it came from.
  return opcUaBadMask;
}
