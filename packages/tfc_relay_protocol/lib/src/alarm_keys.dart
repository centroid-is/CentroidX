/// The `ALARM.` vocabulary: the reserved namespace the plant's active alarm
/// set travels through, spelled once.
///
/// ## Why one file, and why here
///
/// This package is the only one both ends already depend on. The producer is
/// the backend's alarm engine in `tfc_dart`; the consumers are the backend's
/// own value plumbing, the relay server that answers subscriptions, and every
/// panel that draws an alarm banner. A key name is matched by configuration
/// out in the plant, so a second spelling does not fail a test: it compiles,
/// it keeps every suite green, and it quietly stops matching every deployment.
///
/// The enforcement is a grep, not a type: an `'ALARM.…'` literal anywhere in
/// any `lib/` outside this file is the drift. Import the constant.
///
/// ## Three decisions, recorded here because the file is the only defence
///
/// **1. A key, not an RPC (D-9).** The active set is a *state snapshot*, and
/// the value path already delivers everything a snapshot wants: subscription,
/// conflation, snapshot-on-reconnect, fan-out, staleness and the access policy
/// that governs every other key. `pipe_keys.dart` already recorded the ruling
/// for pipeline health — *"There is no health method … these are keys, not an
/// API"* — and the backend already seeds `PIPE.connected` into the pipe's own
/// `ValueStore` and serves it like a temperature. A new `alarms.*` protocol
/// message would instead touch `tfc_relay_protocol`, `tfc_relay_server`,
/// `tfc_relay_client` and the shared contract suite in order to *re-obtain*
/// capabilities the existing machinery hands over free. PROJECT.md's
/// *"resync = snapshot, never delta replay"* is not a compromise the value
/// path forces on alarms; it is the correct semantics for an active set.
///
/// **2. A prefix test, never a roster lookup.** Quoted from its source,
/// `pipe_keys.dart`: *"a prefix test, never a roster lookup … so a key
/// invented in a later phase is swept correctly and reserved correctly on the
/// day it is invented."* An enumerated check would leave every alarm key added
/// later unreserved and greying-out until somebody remembered to come back
/// here, and the symptom of forgetting is an alarm banner that reads stale
/// precisely while nothing is wrong. The trailing dot is part of the prefix,
/// so a plant area called `ALARMS` is not reserved by accident — every tag
/// under it would otherwise be excluded from the freshness sweep, which is the
/// same lie inverted: an area that can never go stale however long it has been
/// silent.
///
/// **3. Timestamps travel as DATA inside the payload, never in
/// `DynamicValue.sourceTime`.** Forced by the code, not by taste. The panel
/// converts a relay value to `open62541`'s value type through `toUaValue`
/// (`tfc_dart/lib/core/gateway_state_man.dart:311`), and that type carries no
/// `sourceTime` and no `quality` field at all. A timestamp put in the metadata
/// is therefore dropped silently somewhere no test is looking, and the panel
/// renders an alarm stamped from whenever it happened to be drawn. So the
/// engine puts epoch milliseconds in the payload, beside the fields it
/// describes.
///
/// ## What is deliberately NOT here
///
/// The payload's field names. This file is the namespace only: the shape of
/// one active-alarm entry is the alarm engine's, and putting it here would
/// make every consumer of a key name recompile against a data model it does
/// not read.
library;

/// The reserved names of the alarm namespace.
abstract final class AlarmKeys {
  /// The reserved namespace the alarm engine publishes through.
  ///
  /// The trailing dot is part of it, so a plant area called `ALARMS` is not
  /// reserved by accident. Deliberately distinct from, and not a prefix of,
  /// `PipeKeys.prefix`: the freshness sweep and `markStale` each carry
  /// `isPipeKey(key) || isAlarmKey(key)`, and two predicates that overlapped
  /// would be one predicate wearing two names — removing the wrong half would
  /// change nothing observable until the day the other half was removed too.
  static const String prefix = 'ALARM.';

  /// **A prefix test, never a roster lookup.**
  ///
  /// The whole mechanism: the freshness sweep skips alarm keys by prefix and
  /// the key-mapping ingest reserves them by prefix, so a key invented in a
  /// later phase is swept correctly and reserved correctly on the day it is
  /// invented, with no edit to this file. See the library doc for why an
  /// enumerated check is the wrong shape.
  static bool isAlarmKey(String key) => key.startsWith(prefix);

  /// The whole active set, as one value.
  ///
  /// A list of entries, one per active alarm-rule instance, published by the
  /// backend's alarm engine into the pipe's `ValueStore` and read by every
  /// panel like any other key. **One key rather than one key per alarm**: the
  /// active set is a snapshot, and a snapshot delivered as N keys is N
  /// separate arrivals a client has to reassemble — with no instant at which
  /// it holds a consistent picture, and no way to learn that an alarm cleared
  /// except by noticing a key that stopped arriving.
  ///
  /// **It is not produced by the value plumbing that declares it.** The
  /// backend's value source lists this name so the relay server will answer a
  /// subscription for it rather than `unknownKey`; the engine is what puts a
  /// value there. Until the engine has run, the honest reading is
  /// "not heard from yet", which is exactly what an undeclared, unseeded key
  /// already says.
  ///
  /// Never badged stale by age. Alarm state changes on *events*, so on a
  /// healthy plant this key is always older than any freshness deadline —
  /// greying it out would teach operators that a grey alarm banner means
  /// nothing, at the moment they most need it to mean something.
  static const String active = '${prefix}active';
}
