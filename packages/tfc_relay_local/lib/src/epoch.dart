/// The per-PLC epoch: one opaque token that changes when the server underneath
/// changes.
///
/// A TwinCAT program download rebuilds the address space. NodeIds the gateway
/// resolved an hour ago may now point at a different variable, or at nothing,
/// and the failure mode is the worst one this project has a name for: a
/// plausible number on the right-looking page. SRV-07's answer is this token
/// plus one rule — a handle carrying an old token cannot answer at all — and
/// [UpstreamRef.epoch] is where that rule is enforced.
///
/// ## The epoch is OPAQUE above this file
///
/// Nothing outside this library may parse an epoch, order two of them, or read
/// a timestamp out of one. **Only equality matters.** A caller that compares
/// epochs for recency has invented a clock the plant did not agree to: the
/// inputs below include a hash, the token is versioned, and the day a fourth
/// input lands the string changes shape. Three named constants and
/// [isUnreadableEpoch] are the entire vocabulary a caller gets.
///
/// ## Three inputs, because one of them is an assumption
///
/// **Assumption A1, in full, because this is the file where a future reader
/// will look for it.**
///
/// The roadmap's F24 mechanism is *"a change in a PLC's
/// `ServerStatus.StartTime` bumps its epoch, forces re-browse, and marks its
/// keys bad-quality"*. SVN's PLCs are Beckhoff TwinCAT, which means the OPC UA
/// server is **TF6100, a separate Windows service on the controller** — and a
/// PLC program download restarts the *PLC runtime*, not that service. Beckhoff
/// documents that the server "automatically imports the first PLC runtime into
/// its namespace" on download, but neither the InfoSys pages nor the TF6100
/// manual state whether `ServerStatus.StartTime` moves, or what happens to
/// previously-issued NodeIds. **Two web searches failed to settle it either
/// way; this is a genuine gap, not a formality** (08-RESEARCH §C.2).
///
/// *What is verified:* `Server_ServerStatus_StartTime` is numeric NodeId
/// **2257** in namespace 0 — `UA_NS0ID_SERVER_SERVERSTATUS_STARTTIME = 2257` in
/// the binding's own generated table (`open62541_bindings.dart:70202`), with
/// `…CURRENTTIME = 2258` on the next line, which is the node
/// `state_man.dart:1081` already reads as a heartbeat. The OPC Foundation Part
/// 5 §12.10 page carries no numeric ids, so the generated table is the
/// authority here rather than the spec page.
///
/// *Why this design does not depend on A1:* the epoch is derived from **three**
/// independent inputs (08-CONTEXT ruling 7), any one of which changing bumps
/// it:
///
///  1. `Server_ServerStatus_StartTime` — ns=0, i=2257. Moves on a server
///     restart. Whether it moves on a PLC download is A1.
///  2. A hash of `Server_NamespaceArray` — ns=0, i=2255. A re-import can
///     renumber namespace indices, and the index is what a NodeId carries, so
///     a renumbering is a silent re-pointing of every handle. This input
///     catches it **with the TF6100 service untouched**, which is precisely
///     the case A1 might leave blind.
///  3. An optional PLC build-stamp tag, whose key comes from configuration.
///     The most reliable signal of the three and the one the integrator
///     controls; it costs one `DINT` in a program the plant already owns
///     (`~/Projects/sildarvinnsla`). Absent by default.
///
/// *What would settle A1:* a read of `ns=0;i=2257` on ST101 at
/// `10.104.29.11` before and after a program download. 08-CONTEXT calls that a
/// **nice-to-have field verification, not a blocker** — said here so nobody
/// blocks a phase on it and nobody forgets it either.
///
/// *The next lever if the field check comes back saying StartTime does not
/// move:* a **handle-validity probe** — a *cluster* of `BadNodeIdUnknown` on
/// one alias is itself evidence of a reprogram, and `AutoDisposingStream`
/// already classifies that code as permanent (`state_man.dart:2718`). Research
/// ranks it third and this plan does **not** build it. It is recorded here as
/// the named next step rather than as a TODO nobody owns.
///
/// ## Pure combination, IO separated
///
/// [EpochInputs.combine] is a pure function of three optionals and is where the
/// subtle bugs live — ordering, null handling, a hash folded over something
/// with non-deterministic iteration order. It is tested with no server at all.
/// [readEpochInputs] is the only part that touches a socket, and it is
/// deliberately one function with one bounded read helper.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;

// -------------------------------------------------------------- the node ids

/// `Server_ServerStatus_StartTime`, numeric, namespace 0.
///
/// 2257. See the library doc for why the binding's generated table is the
/// authority for this number and not the spec page.
const int serverStatusStartTimeId = 2257;

/// `Server_NamespaceArray`, numeric, namespace 0.
const int serverNamespaceArrayId = 2255;

/// The node the link reads for input 1.
ua.NodeId get startTimeNode => ua.NodeId.fromNumeric(0, serverStatusStartTimeId);

/// The node the link reads for input 2.
ua.NodeId get namespaceArrayNode =>
    ua.NodeId.fromNumeric(0, serverNamespaceArrayId);

// ------------------------------------------------------------- the sentinels

/// The epoch of a link that has never asked.
///
/// **Not the same statement as [unreadableEpoch]** and the difference is
/// load-bearing: "never asked" is a fact about this gateway, "asked and got
/// nothing" is a fact about a server. Only the second one is evidence, and only
/// the second one is a reason to refuse to adopt a reading (see
/// `OpcUaUpstreamLink._refreshEpoch`).
const String unconnectedEpoch = 'e1:unconnected';

/// The epoch of a server that answered none of the three questions.
///
/// A server that answers nothing must not accidentally *agree* with a server
/// that answered — an identifier derived from three nulls is `cert_health_
/// state_man.dart:115-126`'s plausible zero wearing an identity's clothes. This
/// value is a distinguishable marker and [isUnreadableEpoch] is how a caller
/// asks, without parsing anything.
const String unreadableEpoch = 'e1:unreadable';

/// Whether [epoch] means "this server answered none of the identity questions".
///
/// Equality against a named constant, which is the only comparison this file
/// permits above itself.
bool isUnreadableEpoch(String epoch) => epoch == unreadableEpoch;

// ---------------------------------------------------------------- the inputs

/// What one re-reading of a server's identity decided.
///
/// Five outcomes rather than a bool, because the caller's next move differs
/// for each and a bool would collapse the two that matter most: "the server
/// says it is the same one" and "the server would not say" look identical to
/// an `if` and mean opposite things to a link deciding whether to keep dialing.
enum EpochOutcome {
  /// The reading matched. Same server, no event, nothing to do.
  unchanged,

  /// The first reading on a link that had never asked. An identity was
  /// learned, not changed — no bump.
  adopted,

  /// The server underneath changed. Handles are stale and the bump ran.
  bumped,

  /// The server answered none of the identity questions. **Not adopted**: a
  /// link cannot tell a reprogram from a silence, and on a reconnect path this
  /// is also the honest signal that the session is not really activated.
  unreadable,

  /// There was no client to ask, or the link is being disposed.
  notAsked,
}

/// Which of the three questions a server actually answered.
enum EpochInput {
  /// `ns=0;i=2257`.
  startTime,

  /// `ns=0;i=2255`, hashed.
  namespaceArray,

  /// The configured build-stamp tag, if there is one.
  buildStamp,
}

/// One reading of a server's identity.
///
/// Every field is optional because every read can fail independently, and a
/// server that refuses one question still identifies itself with the others.
final class EpochInputs {
  const EpochInputs({
    this.startTime,
    this.namespaceArrayHash,
    this.buildStamp,
  });

  /// What the server said `ServerStatus.StartTime` is, or null if it did not
  /// say.
  final DateTime? startTime;

  /// [hashNamespaceArray] over what the server said its namespaces are.
  ///
  /// A hash rather than the array itself because this value is combined into a
  /// short token, and because the *only* operation anything performs on it is
  /// equality.
  final String? namespaceArrayHash;

  /// Whatever the configured build-stamp tag read, stringified.
  final String? buildStamp;

  /// A reading in which every question went unanswered.
  static const EpochInputs unreadable = EpochInputs();

  /// Which inputs contributed. Empty means [isUnreadable].
  Set<EpochInput> get contributed => <EpochInput>{
        if (startTime != null) EpochInput.startTime,
        if (namespaceArrayHash != null) EpochInput.namespaceArray,
        if (buildStamp != null) EpochInput.buildStamp,
      };

  /// Whether the server answered nothing at all.
  bool get isUnreadable => contributed.isEmpty;

  /// The opaque token.
  ///
  /// Deterministic: the same reading always produces the same string, in this
  /// process and the next one. That is why the hash below is hand-rolled
  /// FNV-1a over bytes rather than anything built on `Object.hash` or
  /// `String.hashCode`, both of which are seeded per isolate group and would
  /// make a gateway restart look like a plant-wide reprogramming.
  ///
  /// **Presence is part of the reading.** A server that stops answering one of
  /// its own identity nodes produces a different epoch from the same server
  /// answering all three, and that is deliberate: the gateway cannot rule out
  /// that the thing which stopped answering is the thing that changed. The
  /// wholly-unreadable case is the one exception, and it is handled by the link
  /// rather than here — see `OpcUaUpstreamLink._refreshEpoch`.
  /// **No `StringBuffer` in this file, and that is not a style choice.**
  /// `freeze_test.dart`'s upstream-write sweep matches any `.write(` under
  /// `lib/`, which is what pins the gateway's crossings into the plant at one
  /// per layer (T-08-22). A buffer here would have added four hits to that
  /// count and the fix would have been an allow-list — a safety pin diluted by
  /// a string builder. Concatenation costs nothing on a path that runs once
  /// per session activation.
  String combine() {
    if (isUnreadable) return unreadableEpoch;
    final canonical = _field(
            't',
            startTime == null
                ? null
                : '${startTime!.toUtc().microsecondsSinceEpoch}') +
        _field('n', namespaceArrayHash) +
        _field('b', buildStamp);
    return 'e1:${_fnv1a64(canonical)}';
  }

  @override
  String toString() => 'EpochInputs(${contributed.join(', ')})';
}

/// One field of the canonical encoding, length-prefixed.
///
/// The length prefix is not decoration: without it `('ab', 'c')` and
/// `('a', 'bc')` encode identically, and two different servers would share an
/// epoch. Absence is its own token (`-`) rather than an empty string, so a
/// server that answered "" is not the same reading as a server that did not
/// answer.
String _field(String tag, String? value) =>
    value == null ? '$tag:-;' : '$tag:${value.length}:$value;';

/// A hash of the server's namespace table, **in order**.
///
/// Order-sensitive because the namespace **index** is what a NodeId carries.
/// The same uris renumbered name different nodes, and a set hash would read a
/// re-import — the very event input 2 exists to catch — as no change at all.
/// The index is written into the encoding rather than merely implied by
/// position, so the property survives somebody later swapping the fold for a
/// commutative one.
String hashNamespaceArray(List<String> uris) {
  final parts = <String>['ns:${uris.length};'];
  for (var i = 0; i < uris.length; i++) {
    parts.add('$i=${uris[i].length}:${uris[i]};');
  }
  return _fnv1a64(parts.join());
}

/// FNV-1a, 64-bit, over the UTF-16 code units of [text], as 16 hex digits.
///
/// Hand-rolled and dependency-free on purpose: this phase adds no packages
/// (threat T-08-SC), and the property that matters — the same bytes give the
/// same digits in every process, forever — is not one `String.hashCode`
/// offers. Not a cryptographic hash and not used as one: nothing here defends
/// against an adversary choosing a namespace table, it defends against a
/// gateway failing to notice that one changed.
///
/// 64-bit wraparound arithmetic. Server-side only; this would silently lose
/// precision compiled to JavaScript, and this package is not.
String _fnv1a64(String text) {
  const int offsetBasis = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  var hash = offsetBasis;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    hash ^= unit & 0xff;
    hash = hash * prime;
    if (unit > 0xff) {
      hash ^= (unit >> 8) & 0xff;
      hash = hash * prime;
    }
  }
  // Rendered as two 32-bit halves rather than as one `toRadixString(16)`.
  // A Dart `int` IS 64-bit, so `toUnsigned(64)` is a no-op on it and a hash
  // whose top bit is set renders with a MINUS SIGN — measured, first run: the
  // namespace hash came out `-50441b5490a7532a`. Deterministic either way, but
  // an identifier that is sometimes negative invites somebody downstream to
  // parse it, and this file's one house rule is that nobody parses it.
  final high = (hash >> 32) & 0xffffffff;
  final low = hash & 0xffffffff;
  return '${high.toRadixString(16).padLeft(8, '0')}'
      '${low.toRadixString(16).padLeft(8, '0')}';
}

// -------------------------------------------------------------------- the IO

/// One deadline, spent across the phases of a multi-step operation.
///
/// **08-REVIEW WR-05.** The pattern this replaces handed the same `deadline` to
/// each phase in turn, so a bound that read as five seconds admitted five
/// seconds *per phase*: `connect` spent it on the session, again on the
/// subscription and again on the epoch, and the epoch reader spent it three
/// more times on its own three reads — about `5 × connectDeadline` for one
/// link, and `LocalStateMan.start` walks its links sequentially, so four dark
/// PLCs kept the socket unbound for over three minutes on the defaults.
///
/// A deployment sizing a deadline is sizing how long it is willing to wait,
/// and the number it types has to be that. Each phase gets what is left.
///
/// [minimumSlice] is what a phase gets once the budget is spent, and it is not
/// zero on purpose: a `.timeout(Duration.zero)` fires before the call it wraps
/// can even start, which turns "we ran out of time" into "this operation is
/// impossible" and loses the distinction in the error. One millisecond expires
/// immediately in practice and still lets the call be made.
final class DeadlineBudget {
  DeadlineBudget(this.total) : _spent = Stopwatch()..start();

  /// What the caller asked for, over everything.
  final Duration total;

  /// Monotonic, for 07-REVIEW CR-01's reason: a budget aged on the wall clock
  /// is a budget an NTP correction can hand back or take away.
  final Stopwatch _spent;

  /// The floor under [remaining].
  static const Duration minimumSlice = Duration(milliseconds: 1);

  /// What is left of [total], never less than [minimumSlice].
  Duration get remaining {
    final left = total - _spent.elapsed;
    return left > minimumSlice ? left : minimumSlice;
  }
}

/// How an epoch reading is obtained, so a test can supply one.
///
/// The link takes one of these rather than calling [readEpochInputs] directly:
/// a case about the *bump choreography* must be able to say "the server's
/// identity changed" without restarting a server, and a case about the
/// *reading* must be able to run against a real one. [readEpochInputs] is the
/// default and is what production uses.
typedef EpochInputsReader = Future<EpochInputs> Function(
  ua.ClientApi client, {
  required Duration deadline,
  ua.NodeId? buildStampNode,
});

/// Reads a server's identity, bounded by [deadline], **never throwing**.
///
/// Each input is read independently and each failure is absorbed: a server
/// that refuses one question still yields an epoch from the others, and
/// [EpochInputs.contributed] says which ones answered. A configured
/// [buildStampNode] that does not resolve is the *unreadable* case for that
/// input, not an exception — a misspelled build-stamp key must not take the
/// whole epoch down with it, because then the detector fails on exactly the
/// configuration mistake that is easiest to make.
///
/// [deadline] is required and has no default, for `UpstreamLink.read`'s reason:
/// an unbounded upstream await must not be writable by omission.
/// **[deadline] bounds the whole reading, not each of the three reads.**
/// 08-REVIEW WR-05: each `_readOrNull` used to carry the full deadline, so
/// three sequential reads against a dark PLC cost three times what the caller
/// asked for — and `connect` then added its own two phases on top, and
/// `LocalStateMan.start` multiplied the lot by the link count. A budget that
/// means five seconds has to mean five seconds.
Future<EpochInputs> readEpochInputs(
  ua.ClientApi client, {
  required Duration deadline,
  ua.NodeId? buildStampNode,
}) async {
  final budget = DeadlineBudget(deadline);
  final started = await _readOrNull(client, startTimeNode, budget.remaining);
  final namespaces =
      await _readOrNull(client, namespaceArrayNode, budget.remaining);
  final stamp = buildStampNode == null
      ? null
      : await _readOrNull(client, buildStampNode, budget.remaining);
  return EpochInputs(
    startTime: _asDateTime(started),
    namespaceArrayHash:
        namespaces == null ? null : hashNamespaceArray(_asStringList(namespaces)),
    buildStamp: stamp?.value?.toString(),
  );
}

/// The one place in this file that touches the wire.
///
/// One call site, bounded, and never throwing: the binding reports a failed
/// read by completing with a formatted **String** rather than an exception
/// object (measured against the in-process server:
/// `'Failed to read attribute: BadNodeIdUnknown NodeId: ns=1;s=nope …'`), and
/// under `useIsolate: true` every error is flattened to a string by
/// construction anyway. A bare `catch` is therefore the correct shape here and
/// not laziness — there is no type to be specific about.
Future<ua.DynamicValue?> _readOrNull(
    ua.ClientApi client, ua.NodeId node, Duration deadline) async {
  try {
    return await client.read(node).timeout(deadline);
  } catch (_) {
    return null;
  }
}

/// A `StartTime` reading as a [DateTime].
///
/// The binding hands `ns=0;i=2257` back as a Dart [DateTime] already (measured
/// against the in-process server). The integer branch is the raw `UA_DateTime`
/// shape — 100 ns ticks since 1601 — which is what a binding change or another
/// server could plausibly produce, and [ua.uaDateTimeToDateTime] is the
/// binding's own conversion for it.
DateTime? _asDateTime(ua.DynamicValue? sample) {
  final raw = sample?.value;
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  if (raw is int) return ua.uaDateTimeToDateTime(raw);
  if (raw is String) return DateTime.tryParse(raw)?.toUtc();
  return null;
}

/// A `NamespaceArray` reading as a list of uris, in server order.
///
/// The binding hands the array back as `List<DynamicValue>` (measured), so each
/// element is unwrapped rather than stringified — a `DynamicValue`'s
/// `toString()` is a formatted, indented rendering, and hashing that would make
/// the epoch depend on the binding's display code.
List<String> _asStringList(ua.DynamicValue sample) {
  final raw = sample.value;
  if (raw is! List) return <String>[if (raw != null) '$raw'];
  return <String>[
    for (final element in raw)
      element is ua.DynamicValue ? '${element.value}' : '$element',
  ];
}
