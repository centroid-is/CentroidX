/// The `PIPE.` vocabulary: every pipeline-health key name, spelled once.
///
/// ## Why one file
///
/// `PIPE.` acquires producers in three packages at once — the client mints the
/// pipe's own five, the gateway's session overlay mints the per-client ones,
/// and the local implementation mints the per-link and per-certificate ones.
/// A key name is matched by AlarmMan configuration out in the plant, so a
/// second spelling does not fail a test: it compiles, it keeps every suite
/// green, and it quietly stops matching every deployment. The constant that
/// used to live beside the certificate producer said this in so many words —
/// *"named as a constant rather than spelled at each site so the reserved list
/// and this producer cannot drift apart by a typo"* — and this file is that
/// sentence applied to the whole namespace rather than to one key.
///
/// The enforcement is a grep, not a type: a `'PIPE.…'` literal anywhere in any
/// `lib/` outside this file is the drift. Import the constant.
///
/// ## These are keys, not an API
///
/// *"There is no health method."* `PIPE.*` names are subscribable exactly like
/// a temperature — same store, same quality codes, same widgets
/// (`state_man_api.dart`, and the frozen interface member count that pins it).
/// Nothing here is a method on anything, and adding one would be a different
/// decision than the one this file records.
library;

/// The reserved names, the per-alias builders, and the two send-buffer lanes.
abstract final class PipeKeys {
  /// The reserved namespace the pipe reports on itself through (design §4.7,
  /// HLTH-01). The trailing dot is part of it, so a plant area called `PIPES`
  /// is not reserved by accident.
  static const String prefix = 'PIPE.';

  /// **A prefix test, never a roster lookup.**
  ///
  /// This is the whole mechanism of HLTH-02 and HLTH-03. The freshness sweep
  /// skips health keys by prefix and the keymapping ingest reserves them by
  /// prefix, which means a key invented in a later phase is swept correctly
  /// and reserved correctly on the day it is invented, with no edit to this
  /// file. An enumerated check would leave every new health key unreserved
  /// and greying-out until somebody remembered to come back here — and the
  /// symptom of forgetting is an indicator that reads stale precisely while
  /// nothing is wrong.
  static bool isPipeKey(String key) => key.startsWith(prefix);

  // ---------------------------------------------------------------- group 1
  // Client-side, produced by `RemoteStateMan`.
  //
  // These five are the reference implementation's seeded roster
  // (`FakeStateMan.healthKeys`) and **that roster stays at five**: a sixth
  // entry puts the key on every contract leg, including the in-memory ones
  // where there is no upstream link and no certificate to report on. They are
  // named here so the two agree; the agreement is asserted by this package's
  // test against literals, because this package has no dependencies and the
  // contract kit depends on it rather than the other way round.

  /// The pipe is up. Seeded, not left unknown: a health indicator that reads
  /// "unknown" until the first fault tells an operator nothing at the moment
  /// they most need telling.
  static const String connected = '${prefix}connected';

  /// Round-trip to the gateway, milliseconds.
  static const String rttMs = '${prefix}rtt_ms';

  /// Age of the newest value received, milliseconds.
  ///
  /// The pipe-wide half of [upstreamDataAgeMs]: this one is about the socket to
  /// the gateway, that one is about one PLC behind it.
  static const String dataAgeMs = '$prefix$_dataAgeMsTail';

  /// Reconnects this process has made.
  static const String reconnects = '${prefix}reconnects';

  /// The session epoch (ULID). A change means the client's cache means
  /// nothing.
  static const String epoch = '${prefix}epoch';

  // ---------------------------------------------------------------- group 2
  // Per-session, produced by the gateway's session health overlay (08-12).
  //
  // **These cannot come from the shared `LocalStateMan`.** It is one instance
  // serving every panel in the plant, and every key below is a fact about one
  // socket: this panel's send buffer, this panel's tick rate, this panel's
  // egress. It is the same argument the certificate overlay makes about why
  // the policy decorator is built per session — a per-client fact served from
  // a shared source is a number that is right for whichever client last
  // wrote it.

  /// This session's send buffer is shedding — the pipe is up but not keeping
  /// up.
  static const String linkDegraded = '${prefix}link_degraded';

  /// Ticks actually delivered to this session, versus the configured cadence.
  static const String effectiveHz = '${prefix}effective_hz';

  /// Bytes through this session's sink.
  static const String egressKbps = '${prefix}egress_kbps';

  /// Keys pending in this session's conflating buffer.
  static const String pendingKeys = '${prefix}pending_keys';

  /// Hold-to-run ticks dropped for this session (D-P5-I). The counter exists
  /// on the session already, with "the production home for the number is a
  /// `PIPE.*` health key" written beside it.
  static const String droppedHoldTicks = '${prefix}dropped_hold_ticks';

  /// Event-loop lag on the gateway's one isolate, milliseconds. Per-session
  /// only in where it is *served*; the number itself is process-wide, and it
  /// is here because the overlay is the thing that can answer for it.
  static const String eventLoopLagMs = '${prefix}event_loop_lag_ms';

  // ---------------------------------------------------------------- group 4
  // Gateway self, produced in `tfc_relay_server` (ruling 9 as amended).

  /// Whole days left on the leaf the gateway serves `wss` from.
  ///
  /// **The literal moved here verbatim** from the certificate producer, which
  /// now aliases this constant. The producer itself stays where it is: moving
  /// it would strand the socket-level cases that judge it, and the name is
  /// the only thing that had to be shared. Reads negative when the leaf has
  /// already lapsed, because "three days past" is exactly what an engineer
  /// needs to know.
  ///
  /// On HLTH-03's reserved list day one.
  static const String certDaysToExpiry = '${prefix}cert.days_to_expiry';

  // ---------------------------------------------------------------- group 5
  // The collection historian (8b-01), produced by the gateway's collection
  // runner on `LocalStateMan`.
  //
  // **Per-plant facts, so they live on the shared `LocalStateMan`** — ruling
  // 9's two homes: one historian per gateway, unlike group 2's per-socket
  // facts. And unlike the per-alias builders they ARE a finite roster, so
  // they join [declared] where the partition arithmetic can see them.

  /// The gateway is configured to historise. News, not a gauge: this
  /// flipping is an operator decision or a config load, and a panel that
  /// learns about it late trusts a chart that is not being fed.
  static const String collectEnabled = '${prefix}collect.enabled';

  /// The sink can reach Postgres. The historian's own [connected], scoped
  /// by the middle segment the way [_upstream] scopes a PLC's.
  static const String collectConnected = '${prefix}collect.connected';

  /// Rows written since start — `getStats()`'s `total_writes`, served as a
  /// key a panel can chart.
  static const String collectRowsWritten = '${prefix}collect.rows_written';

  /// Rows dropped, skipped or refused since start. **A lost row is a
  /// counted row** (8b house rule): this is the number that makes the
  /// no-silent-anything rule true for the historian.
  static const String collectRowsDropped = '${prefix}collect.rows_dropped';

  /// Rows waiting in the sink's buffers right now — the early warning for
  /// [collectRowsDropped], the same pairing `getStats()` makes with
  /// `queued_rows`.
  static const String collectQueuedRows = '${prefix}collect.queued_rows';

  /// The last sink error, **redacted**: a Postgres error carries the host,
  /// the database and the user, and this string becomes a key value a
  /// panel can read. The seam's `SinkStats.lastError` doc owns that rule;
  /// 8b-02 does the redaction and tests it.
  static const String collectLastError = '${prefix}collect.last_error';

  /// Every non-builder key above, in one list.
  ///
  /// The per-alias keys are deliberately absent: an alias is a runtime value,
  /// so there is no finite roster of them and anything that needed one would
  /// be wrong the first time a PLC was added.
  static const List<String> declared = [
    // group 1 — client
    connected,
    rttMs,
    dataAgeMs,
    reconnects,
    epoch,
    // group 2 — per session
    linkDegraded,
    effectiveHz,
    egressKbps,
    pendingKeys,
    droppedHoldTicks,
    eventLoopLagMs,
    // group 4 — gateway self
    certDaysToExpiry,
    // group 5 — the collection historian
    collectEnabled,
    collectConnected,
    collectRowsWritten,
    collectRowsDropped,
    collectQueuedRows,
    collectLastError,
  ];

  // ---------------------------------------------------------------- group 3
  // Per upstream link, produced by `LocalStateMan` (08-09).
  //
  // Builders rather than constants, because the alias is a runtime value out
  // of the keymapping file.

  /// `PIPE.upstream.<alias>.` — the per-link sub-namespace.
  static const String _upstream = '${prefix}upstream.';

  /// This link is up (HLTH-02 as written).
  static String upstreamConnected(String alias) => _link(alias, _connectedTail);

  /// The `StatusParams.state` vocabulary for this link, including
  /// `reprogrammed` — which is the epoch-bump state, not a synonym for
  /// disconnected.
  static String upstreamState(String alias) => _link(alias, _stateTail);

  /// Why this link is down, in the PLC's own words (HLTH-02 as written).
  static String upstreamLastError(String alias) => _link(alias, _lastErrorTail);

  /// Per-PLC epoch (SRV-07): StartTime + namespace hash + build stamp. A
  /// change means every cached value from this PLC means nothing.
  static String upstreamEpoch(String alias) => _link(alias, _epochTail);

  /// Monotonic connect counter — the Sparkplug `bdSeq` analogue.
  static String upstreamBirthCount(String alias) =>
      _link(alias, _birthCountTail);

  /// When this link last died, UTC epoch ms.
  ///
  /// With [upstreamBirthCount] this is the pair that distinguishes "up for six
  /// hours" from "flapped forty times since breakfast" — two situations that
  /// a bare `connected` bit reports identically, and which want two different
  /// people called.
  static String upstreamLastDeathAt(String alias) =>
      _link(alias, _lastDeathAtTail);

  /// Age of the newest value on this link, milliseconds.
  ///
  /// The seventh builder, added by 08-09 — the one key 08-02 declined to
  /// declare because it had no producer yet. **It needed no edit to
  /// [_priorityTails]**, and that is the suffix rule working rather than an
  /// omission: `data_age_ms` is a gauge, gauges ride the conflated lane, and
  /// an unconflated fast-moving gauge is a queue the core value forbids
  /// outright. It is also deliberately absent from [declared] — an alias is a
  /// runtime value and the per-alias keys have no finite roster.
  ///
  /// [dataAgeMs] is the same field asked about the pipe rather than about one
  /// PLC. Two facts, one word, and the test pins that the two spellings cannot
  /// drift.
  static String upstreamDataAgeMs(String alias) => _link(alias, _dataAgeMsTail);

  static String _link(String alias, String tail) {
    // An alias carrying a dot would mint a key `aliasOf` reads back as null:
    // the name is dot-delimited and there would be no way to tell the alias
    // from the field. The result is a health key that attributes to no link,
    // which is the "key nothing will ever route" this whole file exists to
    // prevent — cheaper refused at the mint than diagnosed in the plant.
    if (alias.isEmpty || alias.contains('.')) {
      throw ArgumentError.value(
          alias, 'alias', 'must be non-empty and must not contain a dot');
    }
    return '$_upstream$alias.$tail';
  }

  /// The alias inside a `PIPE.upstream.<alias>.<field>` key, or null for any
  /// other string.
  ///
  /// The per-link health producer reads the alias back out of the key to
  /// attribute a mass degradation to one PLC and leave the others alone. A key
  /// it cannot parse degrades nothing, or everything.
  static String? aliasOf(String key) {
    if (!key.startsWith(_upstream)) return null;
    final parts = key.split('.');
    // Exactly `PIPE` / `upstream` / alias / field. Anything longer or shorter
    // is malformed, and guessing which segment was meant to be the alias is
    // how a typo becomes a silently mis-attributed fault.
    if (parts.length != 4) return null;
    final alias = parts[2];
    return alias.isEmpty ? null : alias;
  }

  // ------------------------------------------------------------------ lanes

  /// State-change keys, which are never conflated.
  ///
  /// **Why the split exists.** HLTH-02 wants health keys on the priority lane,
  /// and the priority lane is documented as never conflated — so a fast-moving
  /// gauge put there is a queue, and a queue is forbidden by the core value
  /// outright. The design's own sentence settles which half goes where: *"a
  /// degraded link must still deliver the news that it is degraded"*. That is
  /// the news. `egress_kbps` is the telemetry, and telemetry that arrives one
  /// tick late has cost nobody anything.
  static const Set<String> priorityLane = {
    connected,
    epoch,
    linkDegraded,
    // 8b-01: the historian's news. `enabled` flipping and the Postgres
    // connection dropping are state changes; `last_error` is why, in the
    // same sentence — the same filing as the per-link `last_error`.
    collectEnabled,
    collectConnected,
    collectLastError,
  };

  /// Gauges, which ride the ordinary conflated lane.
  ///
  /// Together with [priorityLane] this partitions [declared] — asserted by set
  /// arithmetic in the test rather than by a third hand-written list, because
  /// a hand-written list is the fourth place to make the same typo.
  static const Set<String> conflatedLane = {
    rttMs,
    dataAgeMs,
    reconnects,
    effectiveHz,
    egressKbps,
    pendingKeys,
    droppedHoldTicks,
    eventLoopLagMs,
    certDaysToExpiry,
    // 8b-01: the historian's three counters. Fast-moving; unconflated they
    // would be a queue, which the core value forbids outright.
    collectRowsWritten,
    collectRowsDropped,
    collectQueuedRows,
  };

  static const String _connectedTail = 'connected';
  static const String _stateTail = 'state';
  static const String _lastErrorTail = 'last_error';
  static const String _epochTail = 'epoch';
  static const String _birthCountTail = 'birth_count';
  static const String _lastDeathAtTail = 'last_death_at';
  static const String _dataAgeMsTail = 'data_age_ms';

  /// The last segment of every key that is news rather than telemetry.
  static const Set<String> _priorityTails = {
    _connectedTail,
    _stateTail,
    _lastErrorTail,
    _epochTail,
    _birthCountTail,
    _lastDeathAtTail,
    'link_degraded',
    // 8b-01: the historian's on/off is news. The namespace guard in
    // [ridesPriorityLane] still holds — an ordinary tag ending in
    // `.enabled` is plant telemetry and is never promoted.
    'enabled',
  };

  /// Does [key] ride the never-conflated lane?
  ///
  /// **Decided by suffix, not by roster.** The per-alias keys have no finite
  /// roster — the aliases come out of a keymapping file that an integrator
  /// edits — so a lane rule that enumerated keys would need an edit here every
  /// time a PLC was added to the plant, and the failure mode of forgetting is
  /// that the new PLC's *loss announcement* rides the conflated lane and can
  /// be dropped by the very congestion it is reporting.
  ///
  /// A key outside the namespace is never promoted, however it is spelled: an
  /// ordinary tag ending in `.connected` is plant telemetry, and putting plant
  /// telemetry on the unconflated lane is how that lane becomes a queue.
  static bool ridesPriorityLane(String key) {
    if (!isPipeKey(key)) return false;
    final tail = key.split('.').last;
    return _priorityTails.contains(tail);
  }
}
