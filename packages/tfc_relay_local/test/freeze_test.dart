/// The five structural promises this package makes on day one.
///
/// These properties are *the reason* `LocalStateMan` is a new package rather
/// than five hundred more lines inside `tfc_relay_server`. That package pins
/// itself at exactly one repeating timer (`teardown_test.dart:495-540`) and it
/// is right to: one tick engine over one registry, and a second periodic timer
/// there would double every client's frame rate and halve the value of every
/// backpressure verdict. This package genuinely needs three — a `runIterate`
/// driver, a freshness sweep and a fan-in linger — and the honest answer to
/// that is a **named allow-list of its own**, not an exemption bolted onto
/// somebody else's sweep until their property means nothing.
///
/// So the promises are written down here, before there is anything to enforce
/// them against, and each one is proven to be *looking*. Three rules the file
/// follows, and the reasons are not stylistic:
///
///  1. **Every sweep takes its directory as an argument.** That is what makes
///     the empty-temp-directory falsification arm possible at all — a sweep
///     that hard-codes its own path cannot be pointed at a tree that is known
///     to contain nothing, so nothing can ever demonstrate that it counts.
///     `mode_integrity_test.dart:379`'s `_proofFiles(Directory)` is the shape.
///  2. **Every number is declared here**, as a `const` with a comment saying
///     what would legitimately move it — never derived from the thing it is
///     counting, because a count that recomputes its own expectation agrees
///     with every future.
///  3. **Anti-vacuity comes before the count.** Directory exists → directory
///     holds `.dart` files → the same sweep over an empty temp directory
///     reports zero → *then* the count
///     (`no_retry_test.dart:327-364`, `handler_table_test.dart:289-296`,
///     `teardown_test.dart:496-499` all learned this the same way).
///
/// Several counts were **zero on day one**, because on day one this package was
/// one interface file. A case named "no timer outside the allow-list" that
/// passes over a tree with no timers in it is a case nobody should trust
/// without its empty-directory sibling, so the ones that are still zero say so
/// out loud in their names rather than letting a future reader mistake an
/// empty tree for a clean one. 08-05 moved four of them off zero.
@TestOn('vm')
@Tags(['meta'])
library;

import 'dart:io';

import 'package:test/test.dart';

// ---------------------------------------------------------------- the scopes
//
// Relative to the package root, which is where `dart test` runs from. The
// anti-vacuity group's first case is what catches a working directory that is
// not what this file assumes.

final Directory libRoot = Directory('lib');
final Directory libSrc = Directory('lib/src');
final Directory testRoot = Directory('test');

/// The collection subsystem (8b-01) — the scope of the fire-and-forget
/// sweep, because that is where 8b-02's flush machinery will live.
final Directory libCollect = Directory('lib/src/collect');

/// The soak's two trees (11-01, 11-02) — the scope of freeze 9.
final Directory testSoak = Directory('test/soak');
final Directory testSoakSupport = Directory('test/support/soak');

// ------------------------------------------------------------- the allow-lists

/// Files permitted to hold a `Timer.periodic(`, each naming the plan that
/// earned the entry.
///
/// **One entry, added by 08-05 in the same commit as the timer it names.**
/// Nothing is pre-approved — the plan that lands each timer adds its entry
/// here in the same commit, which is what makes the next one a decision rather
/// than a drift:
///
///  * 08-05's freshness sweep — **landed**, entry below.
///  * 08-05's fan-in linger — **landed**, on [retainedTimerAllowList] rather
///    than here, because it is a one-shot rather than a periodic. 08-03
///    anticipated it as a bare `_timer` field with no entry anywhere; 08-05's
///    house rules require every timer to arrive with an allow-list entry, and
///    the second list is the reconciliation.
///  * 08-07's `runIterate` driver — **landed**, entry below.
///
/// **Final for Phase 8, checked by 08-13's gate** — and moved to four total
/// entries by 8b-03, which is a new phase making the decision the sentence
/// below demands, not a drift past it. The composition root added none: it
/// has no cadence of its own, and 08-12's per-session overlay deliberately
/// recomputes on the read path rather than on a clock. If a later phase wants
/// `data_age_ms` pushed on a cadence, the honest place is the tick engine's
/// existing timer in `tfc_relay_server` — not a fifth entry here.
const Map<String, String> periodicTimerAllowList = <String, String>{
  // 08-05, task 3. Listener-gated: started when the store gains its first
  // watcher and stopped when it loses its last, so with nobody watching there
  // is no timer at all. Interval is staleAfter ~/ 4 with a floor. It cannot be
  // replaced by a deadline check on paths that already run — only a clock can
  // notice silence, and the frozen-session failure emits nothing at all.
  'freshness_sweep.dart': '08-05 — the listener-gated freshness sweep',
  // 08-07, task 2. ONE supervised iterate driver per OPC UA link, owned by the
  // link, started inside connect() (the session cannot activate unless somebody
  // is turning the crank) and cancelled in dispose() before the client is
  // deleted. The shape it REPLACES is what earns the entry: `state_man.dart`
  // spawns two unawaited `() async {…}()` loops per client (`:1364`, `:1398`)
  // driving the same blocking FFI call with a bare `Logger()`, no error seam
  // and nothing that stops. Errors here go to a list a test reads and to an
  // injected callback (T-08-27).
  'opcua_upstream_link.dart': '08-07 — the supervised runIterate driver',
  // 8b-03, task 1. The per-entry sample timers behind `sample_interval` —
  // one `Timer.periodic(` spelling, one timer per interval entry, held in a
  // named map so each is reachable and cancellable. UNLIKE the freshness
  // sweep and the fan-in linger these are NOT listener-gated, and that is
  // the justification, not an oversight: historisation is the process's own
  // job and nobody is watching by definition — the gate is the lifecycle
  // (start()/stop()), never a subscriber count. Carries collector.dart:297's
  // cancel-the-previous guard so a re-collect after a mapping edit does not
  // leave the first timer inserting alongside its replacement.
  'collection_runner.dart': '8b-03 — the per-entry sample timers',
};

/// Files permitted to hold a **retained one-shot** `Timer(`, each naming the
/// plan that earned the entry.
///
/// A second list rather than a second meaning on the first, because the two
/// hazards are different: a `Timer.periodic` runs forever and a retained
/// `Timer(` runs once but can outlive the thing it was scheduled about. The
/// naming rule (`Timer(` must appear on a line that also names a `_timer`
/// field, so it is reachable and cancellable) is necessary and was never
/// sufficient — it says a timer *can* be cancelled, not that anybody decided
/// it should exist. 08-05's house rules require both of this plan's timers to
/// be allow-listed in the same commit that creates them; 08-03 anticipated the
/// linger as a `_timer` field rather than an entry here, and this is the
/// reconciliation: it is both.
const Map<String, String> retainedTimerAllowList = <String, String>{
  // 08-05, task 2. ONE-SHOT, not a periodic: armed per key when its refcount
  // reaches zero and cancelled by any new subscribe for that key, which is the
  // guard against the bug the incumbent documents at state_man.dart:2736-2739
  // (a timer that removes by key and evicts the live entry that replaced it).
  // Defaults to Duration.zero, in which case no timer is created at all.
  'fanin.dart': '08-05 — the fan-in linger, one-shot per key at refcount zero',
  // 10-09, task 2. ONE-SHOT, and LISTENER-GATED, which is the part that
  // earned the entry rather than merely justified it: the feed's channel
  // opens on the first subscriber and closes with the last, and the back-off
  // is armed only on the path between those two — `_stop` and `close` both
  // cancel it, so a feed nobody is subscribed to holds no timer at all.
  // `listenToChannel` ends its stream with onDone and no error when the
  // connection dies (database_drift.dart:1066-1069), and re-listening with no
  // delay against a database that is down is a hot loop; upstream's
  // PreferencesWatcher uses the same five seconds for the same reason
  // (preferences_watch.dart:41). Project memory is the other half of why this
  // is an entry and not an oversight: an always-on Timer.periodic in relay
  // plumbing has already failed unrelated widget tests once.
  'preference_change_feed.dart':
      '10-09 — the re-listen back-off, one-shot and listener-gated',
};

/// Test files permitted to hold a literal port number, each naming why.
///
/// **Empty, and it should stay that way.** Two worktrees must be able to run
/// this suite at once.
const Map<String, String> literalPortAllowList = <String, String>{};

/// The soak's plant-side applied-write ledger, by name.
///
/// **A symbol and not a path**, because the failure this guards against is an
/// import *from* `lib/`, and an import names the class. Written down here so
/// the sweep, its falsification arm and the "the needle is real" arm all read
/// the same string.
const String appliedWriteLedgerSymbol = 'AppliedWriteLedger';

/// Where that class is declared, relative to the package root.
const String appliedWriteLedgerSource =
    'test/support/soak/applied_write_ledger.dart';

/// Files under the soak trees permitted to reach a wall clock or an unseeded
/// random, each naming why.
///
/// **Two, and both are output rather than decision.** The rule freeze 9
/// enforces is that nothing which influences *which* fault happens or *when*
/// may read anything but the seed; a file that only records what already
/// happened is on the other side of that line. Anything else added here needs
/// the same argument in the same words, and the case below refuses an entry
/// whose file no longer contains what it was exempted for — a stale exemption
/// silently widens the sweep.
const Map<String, String> soakDeterminismAllowList = <String, String>{
  // 11-01, task 3. The journal writes BOTH clocks at every checkpoint, which
  // is 09-review WR-01's evidence half: the monotonic and wall readings agree
  // under every lever CI can pull and diverge exactly under a VM-snapshot
  // stun, so a run where they drift apart has to be visible in the artifact
  // rather than invisible by construction. The journal is output; no decision
  // in the soak reads it.
  'soak_journal.dart': '11-01 — both clocks at every checkpoint (WR-01)',
  // 11-01, task 2's own falsification fixture, plus the needle of the
  // wall-clock sweep that lives in that file. A sweep for a token cannot
  // avoid spelling the token, and a fixture that plants one is the only thing
  // proving the sweep bites.
  'soak_manifest_test.dart':
      '11-01 — the wall-clock sweep\'s needle and its planted fixture',
  // 11-03, task 2. `RELAY_SOAK_SEED=random` draws the run's seed, and drawing
  // is the one place in the soak where an unseeded source is the point rather
  // than the bug this sweep exists for. Everything downstream of the draw is
  // seeded from it, and the number is printed on line one before anything is
  // composed and fed back through RELAY_SOAK_SEED to reproduce — so it decides
  // nothing that is not immediately recorded. One line, `_drawSeed`, at the
  // bottom of the file.
  'soak_test.dart': '11-03 — RELAY_SOAK_SEED=random draws the run\'s seed',
};

// ----------------------------------------------------------- the pinned counts

/// `Timer.periodic(` occurrences under `lib/src`.
///
/// **Three:** 08-05 task 3's freshness sweep, 08-07 task 2's supervised
/// `runIterate` driver, and 8b-03 task 1's sample timers (one spelling in
/// `collection_runner.dart`, however many entries carry an interval). Moves
/// when a plan on [periodicTimerAllowList] lands, and only then. A timer that
/// appears without its allow-list entry is caught by the offender case rather
/// than by this number, which is why both exist.
const int declaredPeriodicTimers = 3;

/// Retained one-shot `Timer(` occurrences under `lib/src`.
///
/// **Two.** 08-05 task 2 landed the fan-in linger; **10-09 task 2 landed the
/// preference feed's re-listen back-off**, in the commit that created it, and
/// this number moved with it. It moves when a plan on
/// [retainedTimerAllowList] lands, and only then.
///
/// The two are the same shape and both are gated, differently: the linger is
/// armed at refcount zero and cancelled by the next subscribe, and the
/// back-off exists only while the feed has a listener. Neither can run when
/// the thing it was scheduled about is gone, which is the property the number
/// is here to make somebody argue for.
const int declaredRetainedTimers = 2;

/// Lines under `lib/` that await an upstream `connect`/`read`/`write`.
///
/// **Two, both landed by 08-05** and both deliberately singular:
///
///  * `LocalStateMan.start` — the one place a link is opened, bounded by
///    `connectDeadline`.
///  * `LocalStateMan._readOne` — the one place an upstream read is awaited,
///    which is why `readFresh` is written as a one-key `readMany` rather than
///    as a second call site that could lose its deadline independently.
///
/// And, since 08-06:
///
///  * `LocalStateMan._crossIntoThePlant` — the one place an upstream *write*
///    is awaited, which the engage write, every hold tick and the release
///    write all funnel through, so the deadline cannot go missing on one of
///    them and stay present on the others.
///
/// And, since 08-07, the OPC UA adapter's own three — the only places in this
/// package that touch a socket rather than another object in it:
///
///  * `OpcUaUpstreamLink.connect` — `client.connect(endpoint)`, bounded.
///  * `OpcUaUpstreamLink.read` — `client.read(nodeId)`, bounded. This is the
///    line that refuses to inherit `state_man.dart:1868`'s
///    `await client.awaitConnect()` inside a read: no deadline there, so a
///    disconnected PLC pends the caller forever (T-08-10). `ClientWrapper`
///    does not bound it either, which is why the bound is applied at the
///    adapter boundary rather than by editing `tfc_dart`.
///  * `OpcUaUpstreamLink.write` — `client.write(nodeId, value)`, bounded, and
///    counted again below.
///
/// It moves **by a number somebody wrote down** — every one of those call
/// sites has to carry a `deadline` argument or a `.timeout(`, and the offender
/// case is what enforces that.
///
/// And, since 08-08, the epoch reader's one:
///
///  * `epoch.dart._readOrNull` — `client.read(node)`, bounded. **One helper,
///    not three call sites**, and that is the reason the reader is shaped the
///    way it is: `StartTime`, the `NamespaceArray` and the optional
///    build-stamp tag are three questions asked through one bounded, never-
///    throwing read, so a deadline cannot go missing on one of them and stay
///    present on the others. The epoch is the detector for a server that
///    changed underneath our handles; a detector that can hang is not one.
///
///  * **08-11 added the eighth:** `OpcUaAddressSpace.detailOf`'s
///    `client.read(nodeId)`, the browse panel's detail read, bounded by that
///    address space's own `deadline`. It arrived unbounded and **this sweep is
///    what caught it** — `LocalBrowse` already wrapped the level in a
///    `.timeout`, which bounds what the caller waits for and leaves the
///    binding's future pending against a dead PLC. A caller-side bound is not
///    a seam-side bound, and the difference is precisely T-08-10. (The
///    sibling `client.browse` call is bounded on the same argument; the sweep
///    matches `connect`/`read`/`write` and does not see it, which is the same
///    structural gap recorded below.)
///
/// **A site exists that this sweep structurally cannot see, and that
/// is a finding rather than an oversight.**
/// `OpcUaUpstreamLink._reopenSessionIfNeeded` dials
/// `client.connect(_endpoint).timeout(_connectDeadline)` and *stores* the
/// future instead of awaiting it on that line — it has to, because `dispose`
/// awaits that same future rather than deleting the native client out from
/// under an in-flight connect (a SEGV, measured, not theorised). The sweep
/// requires the word `await` on the line, so a **non-awaited** upstream call
/// escapes it completely. This one is bounded — the `.timeout(` is right
/// there — but the next one might not be. Widening the sweep to drop the
/// `await` requirement while keeping the deadline requirement would also
/// re-count every site in `local_state_man.dart` under a rule 08-05 and 08-06
/// did not agree to, so it is **recorded for 08-13's gate** rather than done
/// here on the way past.
///
/// **08-13's gate closed it, and not by widening this sweep.**
/// [unawaitedUpstreamSites] is a second sweep over the lines this one cannot
/// see, asserting the same bound on them. That number was unchanged at eight —
/// the composition root adds no crossing of its own, because everything it
/// touches it reaches through `LocalStateMan`.
///
/// **Nine since 08-REVIEW CR-01**, and the ninth is a deliberate edit made
/// while reading the rule above. `LocalStateMan._readBack` performs one
/// bounded read after an acknowledgement that carried no readback, because
/// neither real adapter can supply one and the alternative was publishing a
/// good-quality blank on the tag the operator had just written. It is a
/// **read**: freeze 4's write-site count is unmoved, which is the number that
/// would catch a retry.
///
/// **Ten since F7 (the array_index fix, b86fb5d2).** `OpcUaUpstreamLink.write`
/// now read-modify-writes when the ref addresses one array element: it reads
/// the whole array (`opcua_upstream_link.dart:692`, `.timeout(deadline)`),
/// substitutes the element, and writes it back. That read-back is the tenth
/// bounded await, added while reading this rule. It is a **read**; the
/// write-side of the RMW is counted by freeze 4 below.
///
/// **Eleven since the undecodable-keys fix.** `OpcUaUpstreamLink._probeDecode`
/// performs one bounded read per key per epoch (`.timeout(_probeDeadline)`),
/// because the binding's monitor callback swallows decode failures into
/// stderr and the read path is the only place the throw is catchable — the
/// 200-server bench's Guid/ByteString/LocalizedText/Range keys sat at 258
/// forever without it. It is a **read**, once per key per epoch, never
/// retried on transient failure inside the probe itself.
///
/// **Twelve since the write-typing fix.** `OpcUaUpstreamLink._writeTargetType`
/// reads one node's **DataType attribute** before shaping a write, because an
/// OPC UA Variant with no type is not a write at all and a Dart `int` does not
/// say whether the tag is an Int16 or a UInt32 — a guess is either a
/// `Bad_TypeMismatch` or, measured, a silently narrowed number reported
/// applied. It is a **read**, at most once per key **per epoch** (a DataType
/// cannot change while the address space stands), and free for any key the
/// decode probe or [OpcUaUpstreamLink.read] has already touched. Freeze 4's
/// write-site count is unmoved, which is the number that would catch a retry.
/// It is also the reason `readAttribute` joined the needle at
/// [_upstreamCall] — the crossing existed either way; the choice was whether
/// it would be countable.
const int declaredUpstreamAwaitSites = 12;

/// Lines under `lib/` that cross into the plant **without** the word `await`.
///
/// **The blind spot, made countable.** 08-07 and 08-11 both recorded that
/// [declaredUpstreamAwaitSites] requires `await` on the line, so a call whose
/// future is stored — or which is not a future at all — escapes it entirely,
/// and both left it "for 08-13's gate". This is that: a second sweep over
/// exactly the lines the first cannot see, pinned the same way, so the fourth
/// one is a decision rather than a drift.
///
/// **Three, and each is a different reason for not awaiting:**
///
///  * `OpcUaUpstreamLink._reopenSessionIfNeeded` — `client.connect(_endpoint)
///    .timeout(_connectDeadline)`, **stored** so `dispose` can await it rather
///    than deleting the native client out from under an in-flight connect (a
///    measured SEGV, 08-07). Bounded on its own line.
///  * `DeviceClientUpstreamLink.performWrite` — `client.write(...)`, a one-line
///    **seam** whose single caller is fourteen lines below it and applies
///    `.timeout(deadline)` there. The bound is one frame up, at the one pinned
///    crossing (`declaredUpstreamWriteSites`), and moving it into the seam
///    would give the overriding subclasses two places to lose it.
///  * `DeviceClientUpstreamLink.connect` — `client.connect()`, which is
///    `void`, not a future: `modbus_device_client.dart:1273` is
///    `void connect() => wrapper.connect()`. There is nothing to await, nothing
///    to bound and nothing to leak; the link's state comes from
///    `effectiveStatusStream`, and the deadline this method takes belongs to
///    the caller's wait on that stream.
///
/// **Four since F7 (the array_index fix, b86fb5d2).** The fourth is the same
/// shape as the `performWrite` seam above: `OpcUaUpstreamLink.write`'s scalar
/// branch is `await client\n.write(...).timeout(deadline)` split across lines,
/// so the `.write(` needle matches a physical line without `await` on it while
/// the bound sits one line up. Bounded, and not a fire-and-forget — a decision,
/// read here, not a drift.
///
/// **What this sweep still does not see, and it is named rather than fixed:**
/// `browse` is not in the needle, so `OpcUaAddressSpace.childrenOf`'s
/// `client.browse(...).timeout(deadline)` is invisible to both sweeps. Adding
/// it would re-count every browse site in the package under a rule 08-11 did
/// not agree to, on the way past a closing task. It is bounded today; the
/// obligation moves to whichever plan next edits `local_browse.dart`.
const int declaredUnawaitedUpstreamSites = 4;

/// Lines under `lib/` that call `.write(` on an upstream.
///
/// The `no_retry_test.dart:182-293` seam shape, scoped to this package.
///
/// **Three: one composer, and one per writable protocol.**
///
///  * `LocalStateMan._crossIntoThePlant` (08-06) — the composer's one crossing,
///    which the engage write, every hold tick and the release write all funnel
///    through.
///  * `OpcUaUpstreamLink.write` (08-07) — the OPC UA adapter's one crossing
///    into the actual socket.
///  * `DeviceClientUpstreamLink.performWrite` (08-10) — the same, for the
///    `DeviceClient`-backed protocols. **One site for both of them**, because
///    the Modbus link and the M2400 link share a base and the M2400 never
///    reaches it: it is `supportsWrites: false` and refuses above this line.
///
/// The rule the number enforces is unchanged and is not "three": it is **one
/// call site per layer per transport**, and no site may become "one per
/// protocol with a wrapper around them" — the wrapper is where a retry goes.
/// Anyone adding a site trips this pin rather than a code review, which
/// is the whole reason the number is written down (T-08-22). The
/// **behavioural** half of the same property is `opcua_fault_test.dart`'s
/// write-during-reconnect arm: this pin counts call sites, that arm counts what
/// reached the wire while `ClientWrapper` was re-establishing a session
/// underneath it — and `modbus_link_test.dart`'s `writes` list is the same
/// count on the other transport.
///
/// **Four since F7 (the array_index fix, b86fb5d2), and it is still one layer,
/// one transport.** `OpcUaUpstreamLink.write` now has two mutually-exclusive
/// branches: an array element does read-modify-write (`opcua_upstream_link
/// .dart:694`), a scalar writes directly (`:697`). Two call sites in one
/// method, never both for one operation, neither wrapping the other — which is
/// the shape the rule forbids (a wrapper is where a retry hides), and this is
/// not it. The retry-shape sweep (`retryShapedWrites`, freeze 4's first case)
/// is the property that would catch an actual re-send and it stays empty. If a
/// future edit can fold the two branches back into one crossing without
/// materialising the whole array on a scalar write, it should — and drop this
/// back to three.
const int declaredUpstreamWriteSites = 4;

/// The dev-dependency test kit that must never be reachable from `lib/`.
const String contractKitPackage = 'tfc_stateman_contract';

/// `StateManApi` members `LocalStateMan` has not written yet.
///
/// **This number must reach zero, and each unit of it has an owner.** 07-01's
/// `gateOutstanding` doctrine, applied to a class rather than to a gate: a
/// self-deleting list with an owner beats a red suite, because a phase whose
/// own gate is red cannot tell a new failure from a known one.
///
///  * **0 owed by 08-06** — `write`, `writeStatus` and `holdToRun` are all
///    written, and the count came down with each of them in the commit that
///    closed it.
///  * **0 owed by 08-11** — `browse` landed with `local_browse.dart`, and the
///    count came down with it in the same commit.
///  * **3 owed by 10-01** — `timeseries`, `historyViews`, `preferences`.
///
/// **08-13's gate re-checked it and left it at three.** 08-13's plan asked for
/// zero here, drafted before 08-11 measured the question and took the escape
/// clause its own plan offered. Zeroing it now would mean three stub getters —
/// a chart that silently draws nothing — or three members deleted from the only
/// written record of what is owed, to make a closing task's checklist tidy. The
/// number is a ledger, not a score. It reaches zero when 10-01 builds the
/// historian, and the contract leg reaches 50 in the same commit.
///
/// **Why this is 3 and not 0.** 08-11's plan asked for zero on the argument
/// that "the data-services members are answered by the capability flag rather
/// than by an implementation", and gave the escape clause in the same
/// paragraph: *"if they cannot be answered without throwing, say so and keep
/// the ledger honest rather than zeroing it by fiat."* They cannot.
/// `supportsDataServices: false` removes the seven data-services **cases** from
/// the contract leg; it does not give `LocalStateMan.timeseries` anything to
/// return, and there is no historian behind this package at all until Phase 10
/// builds one. Zeroing the count would have meant either three getters
/// returning empty stubs — a chart that silently draws nothing is worse than
/// one that says it has no source — or three members deleted from a ledger
/// that is the only written record of what is owed. The number is what it is,
/// and it has an owner.
///
/// The plan that closes each member decrements this in the same commit. A
/// member that quietly starts working without this number moving is a member
/// nobody decided to ship.
///
/// **10-07 took it from three to two**, in the commit that made
/// `LocalStateMan.timeseries` answer a `TimescaleReader`. That member no
/// longer throws at all: a gateway composed WITHOUT a historian — no
/// `collection:` block, so no database object exists anywhere — throws a
/// `StateError` naming the composition instead, which is a deployment fact
/// rather than an unwritten member, and the ledger would be lying if it still
/// counted it.
///
/// **10-08 took it from two to one**, in the commit that made
/// `LocalStateMan.historyViews` answer a `HistoryViewStore` — the same move,
/// the same argument, and the same `StateError` naming a composition with no
/// database rather than an `UnimplementedError` naming a plan.
///
/// **10-09 task 3 took it to ZERO**, in the commit that made
/// `LocalStateMan.preferences` answer a `PreferenceStore`. Nothing under
/// `lib/src` throws an `UnimplementedError` any more.
///
/// The number stays, and stays at zero, for the reason every other zero in
/// this file stays: a sweep whose count is zero proves nothing on its own, so
/// the pin is paired with the offender arm that seeds a temp directory and
/// checks the sweep can still see one. Deleting the constant would delete the
/// property along with the debt.
///
/// **Reaching zero is not the same as the three data-services members being
/// unconditional.** `timeseries` and `historyViews` throw a `StateError`, and
/// `preferences` an `UnsupportedError`, when the gateway was composed without
/// a database. Those are deployment facts naming a composition, not unwritten
/// code naming a plan, and this sweep deliberately does not count them — see
/// `fanin_test.dart`'s three "no longer owed" cases, each of which asserts the
/// member is composable as well as that it refuses.
const int declaredUnimplementedMembers = 0;

/// Files under `lib/` allowed to import the database layer — the wrap seam.
///
/// **Two, and the two are named below.** 8b-02 raised it from zero to one in
/// the same commit that created `collect/timescale_sink.dart`, the write
/// adapter; 10-07 raised it to two in the same commit that created
/// `data/timescale_reader.dart`, the read adapter and its mirror. The point of
/// the seam is that the rest of the package cannot reach past it: `Database`
/// starts a flush timer in its constructor and retries its connect until it
/// opens, and a third import site is a third place those behaviours leak onto
/// the gateway's value path — and a place a second connection pool would get
/// built without anyone deciding to. The sweep also flags an unrestricted
/// `tfc_dart/tfc_dart.dart` barrel import, because the barrel re-exports the
/// database layer wholesale — a `show` clause is what keeps a barrel import
/// from being a back door.
///
/// (`package:postgres` is deliberately NOT in the sweep's needles: the
/// driver's types are not `Database`, and the advisory lock's dedicated
/// out-of-pool connection needs them without inheriting the flush timer or
/// the connect ladder this seam exists to contain. `package:drift` is not one
/// either, for the same reason and for one more: the reader needs `Variable`
/// to parameterise two statements `Database` exposes no method for, and
/// parameterising is the opposite of the hazard this file exists to watch.)
const int declaredSeamImportFiles = 2;

/// The files [declaredSeamImportFiles] permits, by path fragment.
///
/// One writes and never reads; one reads and never writes. The second half of
/// that sentence is enforced separately — see [writeCallSitesUnder].
const List<String> declaredSeamFiles = <String>[
  'collect/timescale_sink.dart',
  'data/timescale_reader.dart',
];

/// Insert and retention call sites under `lib/src/data/` — **zero**.
///
/// PHASE 10 READS AND NEVER WRITES. `registerRetentionPolicy` does not merely
/// register: on a table whose policy differs it *uninstalls the existing one
/// and installs its own* (`database.dart:847-864`), which is precisely the
/// two-writer fight 8b spent a whole verdict avoiding while the application's
/// own collector still runs against the same server. A read path that called
/// it would restart that fight from the side nobody is watching — 8b's
/// `side_by_side_test.dart` reads the app's policy before and after, and this
/// pin is what keeps a future edit from making that case start failing for a
/// reason nobody could find.
const int declaredDataWriteSites = 0;

/// Files under `lib/` spelling the literal `'gw_'` — exactly one.
///
/// The default prefix is the side-by-side guarantee
/// (`collection_config.dart`'s class doc carries the four-fact argument). A
/// default duplicated into a second place is a default that drifts, and
/// this one drifting means gateway rows in the app's tables.
const String prefixSpellingFile = 'collection_config.dart';

/// `unawaited(` lines under `lib/src/collect/` with no error handler.
///
/// **Zero in this plan.** Project memory: `unawaited()` attaches no handler
/// — a fire-and-forget future that can error needs `.catchError(` or an
/// `onError:` on the same line, and `StateMan._monitor`
/// (`state_man.dart:2369`) is the in-repo example of doing it right. The
/// collect subsystem is where 8b-02's flush machinery lands, which is why
/// the scope is pinned before there is anything in it to offend.
const int declaredUnhandledFireAndForget = 0;

/// A forwarder is forbidden in the composer, by name.
///
/// `policy_state_man.dart:80-87`'s reason, which `cert_health_state_man.dart:
/// 153-158` then repeats: a `noSuchMethod` forwarder silently absorbs a member
/// added to `StateManApi` in a later phase — the new member works, unpoliced,
/// and nothing says so. Explicit member-by-member implementation makes a new
/// member a compile error and therefore a decision.
const String forwarderSpelling = 'noSuchMethod';

/// Retry shapes forbidden on an upstream write line.
const List<String> retryShapes = <String>[
  'retry',
  'attempt',
  'backoff',
  'Future.doWhile',
];

void main() {
  group('the sweeps are looking at something', () {
    // Comes first, and this ordering is the whole lesson: every count below is
    // trivially satisfied by reading nothing.
    test('every scope exists', () {
      for (final scope in <Directory>[libRoot, libSrc, testRoot]) {
        expect(scope.existsSync(), isTrue,
            reason: 'no directory at "${scope.path}", so every count this file '
                'reports over it is 0 and every pin has been passing against '
                'nothing. These paths are relative to the package root; dart '
                'test was invoked from ${Directory.current.path}');
      }
    });

    test('every scope holds dart files', () {
      for (final scope in <Directory>[libRoot, libSrc, testRoot]) {
        expect(dartFilesIn(scope), isNotEmpty,
            reason: 'the scope "${scope.path}" exists and holds no .dart file, '
                'so the sweeps over it read nothing');
      }
    });

    test('all five sweeps report zero over an empty directory', () {
      final empty = Directory.systemTemp.createTempSync('relay-local-freeze-');
      addTearDown(() => empty.deleteSync(recursive: true));

      expect(dartFilesIn(empty), isEmpty);
      expect(timerOffenders(empty), isEmpty);
      expect(periodicTimerCount(empty), 0);
      expect(retainedTimerCount(empty), 0);
      expect(mentionsOf(empty, contractKitPackage), isEmpty);
      expect(upstreamAwaitSites(empty), isEmpty);
      expect(unboundedUpstreamAwaits(empty), isEmpty);
      expect(upstreamWriteSites(empty), isEmpty);
      expect(retryShapedWrites(empty), isEmpty);
      expect(unimplementedMemberSites(empty), isEmpty);
      expect(forwarderSites(empty), isEmpty);
      expect(harnessLeverSites(empty), isEmpty);
      expect(soakDeterminismOffenders(empty), isEmpty);
      expect(literalPortLines(empty), isEmpty,
          reason: 'pointed at an empty directory a sweep that reports an '
              'occurrence is inventing rather than measuring, and nothing it '
              'says about the real scopes can be trusted');
    });
  });

  group('freeze 1: timers are named', () {
    test('no repeating or retained timer outside the two allow-lists', () {
      expect(timerOffenders(libSrc), isEmpty,
          reason: 'a repeating or retained timer exists in a file that no plan '
              'put on the allow-list. Add the entry in the same commit as the '
              'timer, naming the plan, or the fourth one is a drift nobody '
              'decided on');
    });

    test('the retained one-shot timer count is the declared one', () {
      expect(retainedTimerCount(libSrc), declaredRetainedTimers,
          reason: 'a one-shot timer that outlives what it was scheduled about '
              'is the incumbent\'s documented bug (state_man.dart:2736-2739). '
              'Each one is a named field in an allow-listed file, and the '
              'total is written down so a second one is a decision');
    });

    test('the repeating-timer count is the declared one', () {
      expect(periodicTimerCount(libSrc), declaredPeriodicTimers,
          reason: 'this package declares its own timer discipline rather than '
              'borrowing tfc_relay_server\'s one-timer pin, and the price of '
              'that freedom is writing the number down');
    });
  });

  group('freeze 2: the contract kit is not in lib/', () {
    test('no file under lib/ mentions the kit, comments included', () {
      expect(mentionsOf(libRoot, contractKitPackage), isEmpty,
          reason: 'the contract package is a dev dependency — a test kit with '
              'fakes in it. An import from lib/ ships those fakes to the '
              'plant, and this sweep reads comments too because a commented-'
              'out import is one keystroke from a real one. '
              '`cert_health_state_man.dart:20-23` names the kit by ROLE '
              'rather than by package for exactly this reason, and that is the '
              'discipline to copy when lib/ needs to talk about it');
    });

    test('the needle is the real package name, not a typo', () {
      // Non-vacuous on purpose: a misspelled needle would pass the case above
      // forever. The pubspec is where the name is independently written down.
      expect(File('pubspec.yaml').readAsStringSync(), contains(contractKitPackage),
          reason: 'no dev_dependency by that name, so the sweep above is '
              'hunting a string this repository does not use');
    });
  });

  group('freeze 10: the soak\'s applied-write ledger is not in lib/ (11-04)',
      () {
    test('no file under lib/ mentions it, comments included', () {
      // 08-03 task 2's rule — levers never go on a production class — made
      // mechanical. The ledger exists because `WriteOutcomeLog` prunes at 60 s
      // and cannot answer "applied twice?" at minute 35; the temptation it
      // creates is to solve that in the gateway by keeping applied writes for
      // ever, which is an unbounded structure on the one isolate serving every
      // panel in the plant. A test-only ledger is the right answer precisely
      // because it is test-only, and this is what keeps it so.
      //
      // Comments included, for freeze 2's reason: a commented-out import is
      // one keystroke from a real one.
      expect(mentionsOf(libRoot, appliedWriteLedgerSymbol), isEmpty,
          reason: 'the applied-write ledger is a test harness. Reachable from '
              'lib/ it becomes an unbounded per-write structure in the '
              'shipping gateway, which is the memory invariant 4 exists to '
              'assert about. If lib/ needs to answer "applied twice", that is '
              'a design conversation and a bounded structure, not this class');
    });

    test('and the sweep bites a file that does mention it', () {
      // Non-vacuous: a renamed class would make the arm above pass for ever
      // while the sweep hunted a string this repository no longer uses.
      final planted = _plant('leaked.dart',
          'import "../test/support/soak/applied_write_ledger.dart";\n'
          'final ledger = $appliedWriteLedgerSymbol();\n');
      expect(mentionsOf(planted, appliedWriteLedgerSymbol), isNotEmpty,
          reason: 'the sweep did not catch a file that names the ledger '
              'twice, so the arm above is hunting nothing');
    });

    test('the needle is the real class name', () {
      // The other half of non-vacuity, and freeze 2's own second case: the
      // string has to exist where the class is declared, or a typo in the
      // needle passes both arms above.
      expect(File(appliedWriteLedgerSource).readAsStringSync(),
          contains('final class $appliedWriteLedgerSymbol'),
          reason: 'no class by that name at $appliedWriteLedgerSource, so the '
              'sweep is hunting a symbol this repository does not declare');
    });
  });

  group('freeze 3: no unbounded upstream await', () {
    test('every awaited upstream call carries a deadline or a timeout', () {
      expect(unboundedUpstreamAwaits(libRoot), isEmpty,
          reason: 'an upstream connect/read/write awaited with neither a '
              'deadline argument nor a .timeout() pends forever against a '
              'disconnected PLC, which hangs the poll cycle for every other '
              'key on that link. This is state_man.dart:1868 inherited rather '
              'than prevented (T-08-10)');
    });

    test('the upstream call-site count is the declared one — six since '
        '08-07, so this case counts something as well as being non-vacuous',
        () {
      expect(upstreamAwaitSites(libRoot), hasLength(declaredUpstreamAwaitSites),
          reason: 'a new upstream call site should be a deliberate edit to '
              'this number, so that the person adding it reads the rule '
              'above while they are here');
    });

    test('the NON-awaited crossings are the declared three — 08-13 closing the '
        'gap 08-07 and 08-11 both recorded', () {
      expect(unawaitedUpstreamSites(libRoot),
          hasLength(declaredUnawaitedUpstreamSites),
          reason: 'a stored or fire-and-forget crossing into the plant is '
              'invisible to the sweep above, and a fourth one arriving '
              'silently is exactly how an unbounded dial gets into this '
              'package. Read the three above before you make it four');
    });

    test('the non-awaited sweep is non-vacuous', () {
      expect(unawaitedUpstreamSites(libRoot), isNotEmpty,
          reason: 'an empty result means the needle stopped matching and the '
              'case above has been passing on nothing');
    });
  });

  group('freeze 4: no write retry', () {
    test('no retry shape on any upstream write line', () {
      expect(retryShapedWrites(libRoot), isEmpty,
          reason: 'no auto-retry, at any layer, ever. The three-state outcome '
              'is what makes a re-send the operator\'s decision, and readback '
              'is the only confirmation. A well-meaning wrapper that repeats '
              'an unknown write is one actuation the operator did not ask for '
              '— and on a hold-to-run engage it is a jog nobody is holding');
    });

    test('the upstream write call-site count is the declared one — one per '
        'layer since 08-07, and it stays one per layer', () {
      expect(upstreamWriteSites(libRoot), hasLength(declaredUpstreamWriteSites),
          reason: 'the gateway\'s crossing into the plant is the one place a '
              'retry could hide. no_retry_test.dart pins the server\'s at '
              'exactly one call site for this reason; this is the same pin '
              'with tfc_relay_local/lib as the scope');
    });
  });

  group('freeze 7: ruling 10 stays wired', () {
    test('latin1DecoderFor has a caller under lib/ that is not its own file',
        () {
      // **08-REVIEW WR-01 in one assertion.** What 08-10 shipped was a
      // mechanism plus its unit tests with the wire between them missing:
      // decodePlantString, latin1DecoderFor and Quality.uncertainEncoding had
      // no caller anywhere in lib/, the config field was parsed and echoed,
      // and every actual decode was still utf8-with-allowMalformed. Nothing
      // failed, which is exactly why it shipped — and why the threat register
      // could record T-08-37 as "Mitigated".
      //
      // A call-site count is the cheapest thing that can tell "wired" from
      // "present". The behavioural evidence is in encoding_test.dart, which
      // runs Latin-1 bytes through a real socket into a link built by
      // buildUpstreamLink; this pin is what notices the day somebody
      // simplifies the composition root and takes the argument out with it.
      final callers = mentionsOf(libRoot, 'latin1DecoderFor')
          .where((hit) => !hit.contains('string_encoding.dart'))
          .toList();

      expect(callers, isNotEmpty,
          reason: 'the per-server encoding is a feature a deployment '
              'configures and cannot otherwise observe: it fails by producing '
              'plausible text, not by producing an error. If nothing in lib/ '
              'calls the decoder factory then "string_encoding" is a field '
              'the gateway validates, echoes back, and ignores');
    });
  });

  group('freeze 6: the composer owes what it says it owes', () {
    test('the unimplemented-member count is the declared one', () {
      expect(unimplementedMemberSites(libSrc),
          hasLength(declaredUnimplementedMembers),
          reason: 'every member left unwritten names the plan that owes it, '
              'and the total is written down here so 08-06 and 08-11 can '
              'decrement it rather than discover it. A member that starts '
              'working without this number moving is a member nobody decided '
              'to ship');
    });

    test('the unimplemented-member sweep can still see an offender', () {
      // declaredUnimplementedMembers is ZERO as of 10-09 task 3, so the pin
      // above proves nothing on its own: a sweep that always returns empty
      // passes it, and so does one pointed at the wrong directory. The
      // ledger was the thing that used to keep this sweep honest, and now
      // that the ledger is empty this arm is.
      final seeded = Directory.systemTemp.createTempSync('relay-owed-');
      addTearDown(() => seeded.deleteSync(recursive: true));
      File('${seeded.path}/owed.dart').writeAsStringSync(
          "Object get thing => throw UnimplementedError('99-01 owes thing');\n");
      File('${seeded.path}/prose.dart').writeAsStringSync(
          '/// This member used to throw UnimplementedError( and no longer does.\n');

      final sites = unimplementedMemberSites(seeded);
      expect(sites, hasLength(1),
          reason: 'the throw must be seen and the doc comment must not — a '
              'sweep that flagged prose would make it impossible to write '
              'down that a member STOPPED being owed, which is exactly what '
              'local_state_man.dart now says in three places');
      expect(sites.single, contains('99-01'));
    });

    test('every unimplemented member names an owning plan', () {
      final anonymous = unimplementedMemberSites(libSrc)
          // `\d\d-\d\d` and not `08-\d\d` since 08-11: the three members still
          // owed are owed by a LATER PHASE, and a regex that only recognises
          // this phase's plan ids would force a member with a real owner to be
          // spelled with a fake one. The property being defended is "an
          // UnimplementedError names a plan", not "it names one of ours".
          .where((site) => !RegExp(r'\d\d-\d\d').hasMatch(site))
          .toList();
      expect(anonymous, isEmpty,
          reason: 'an UnimplementedError with no plan id in it is a TODO, and '
              'a TODO is a thing nobody owns');
    });

    test('no lever from the test-only control surface is declared in lib/', () {
      expect(harnessLeverSites(libSrc), isEmpty,
          reason: 'a `StateManHarness` lever is declared on a production '
              'class. Those six members exist to make a value appear or a link '
              'fall over, and on a class a connected session can reach they '
              'are an unauthenticated write path into every operator\'s '
              'screen: setValue on a speed tag is a stopped conveyor reading '
              'as running, minted by the gateway itself and indistinguishable '
              'from a real sample (T-08-42). They belong on the test-only '
              'wrapper in test/support/, and 08-11 added this sweep because '
              'the shortest path to a green contract leg is to put them here '
              'and nothing else was watching');
    });

    test('the lever sweep can see an offender, one per lever', () {
      // The pin above is ZERO, so the empty-directory arm alone proves
      // nothing: a sweep that always returned empty would pass both. And a
      // list-driven regex has a second way to go quiet — a lever added to
      // [harnessLevers] that the pattern cannot match — so this seeds one
      // declaration per lever and requires the count to track the list.
      final seeded = Directory.systemTemp.createTempSync('relay-lever-');
      addTearDown(() => seeded.deleteSync(recursive: true));
      for (final lever in harnessLevers) {
        File('${seeded.path}/$lever.dart')
            .writeAsStringSync('void $lever() {}\n');
      }
      File('${seeded.path}/innocent.dart')
          .writeAsStringSync('void setSomethingElse() {}\n');

      expect(harnessLeverSites(seeded), hasLength(harnessLevers.length),
          reason: 'every lever in the list must be one the sweep can '
              'actually see. A name added to harnessLevers that the '
              'declaration pattern does not match reads as a lever being '
              'guarded and guards nothing — which is worse than not listing '
              'it, because the list is what a reader checks');
    });

    test('no file under lib/ forwards with noSuchMethod', () {
      // Comments are skipped here, unlike freeze 2's kit sweep. The two are
      // different hazards: a commented-out *import* is one keystroke from a
      // real one, while a doc comment arguing that a forwarder must not be
      // used is the argument this sweep exists to enforce — the same reason
      // `teardown_test.dart:510-512` skips `///` when hunting timers.
      expect(forwarderSites(libSrc), isEmpty,
          reason: 'policy_state_man.dart:80-87. A forwarder absorbs a member '
              'added to StateManApi in a later phase: the new member works, '
              'unpoliced, and nothing says so. Explicit delegation makes it a '
              'compile error and therefore a decision');
    });
  });

  group('freeze 8: the collection seam (8b-01)', () {
    test('the three sweeps report zero over an empty directory', () {
      final empty =
          Directory.systemTemp.createTempSync('relay-collect-freeze-');
      addTearDown(() => empty.deleteSync(recursive: true));

      expect(seamImportFiles(empty), isEmpty);
      expect(prefixSpellingFiles(empty), isEmpty);
      expect(unhandledFireAndForgetSites(empty), isEmpty,
          reason: 'pointed at an empty directory a sweep that reports an '
              'occurrence is inventing rather than measuring');
    });

    test('the three sweeps can each see an offender', () {
      // Two of the pins below are ZERO, so the empty-directory arm alone
      // proves nothing: a sweep that always returns empty passes both.
      // Seed a directory with the offences and watch each one reported —
      // that is what makes a zero pin a measurement.
      final seeded =
          Directory.systemTemp.createTempSync('relay-collect-offend-');
      addTearDown(() => seeded.deleteSync(recursive: true));
      File('${seeded.path}/direct.dart').writeAsStringSync(
          "import 'package:tfc_dart/core/database.dart';\n");
      File('${seeded.path}/barrel.dart')
          .writeAsStringSync("import 'package:tfc_dart/tfc_dart.dart';\n");
      File('${seeded.path}/shown.dart').writeAsStringSync(
          "import 'package:tfc_dart/tfc_dart.dart'\n"
          '    show RetentionPolicy;\n');
      File('${seeded.path}/prefix.dart')
          .writeAsStringSync("const p = 'gw_';\n");
      File('${seeded.path}/fire.dart')
          .writeAsStringSync('void f() { unawaited(g()); }\n');

      expect(seamImportFiles(seeded), hasLength(2),
          reason: 'the direct import and the unrestricted barrel are both '
              'back doors to Database and must both be seen; the '
              'show-restricted barrel import is not one, and flagging it '
              'would outlaw the constants task 1 imports on purpose');
      expect(prefixSpellingFiles(seeded), ['prefix.dart']);
      expect(unhandledFireAndForgetSites(seeded), hasLength(1),
          reason: 'an unawaited( with no handler on the line is exactly '
              'the shape this sweep exists to stop');
    });

    test('the wrap seam is two files, and they are the named ones', () {
      final files = seamImportFiles(libRoot);
      expect(files, hasLength(declaredSeamImportFiles),
          reason: 'the point of the seam is that the rest of the package '
              'cannot reach past it: Database starts a flush timer in its '
              'constructor and retries its connect until it opens, and an '
              'import site outside the two named files puts both on the '
              'gateway\'s value path — and is where a second connection '
              'pool gets built without anyone deciding to. 8b-02 raised '
              'this to one and 10-07 to two, each in the commit that '
              'created the file it names');
      for (final declared in declaredSeamFiles) {
        expect(files.where((f) => f.contains(declared)), hasLength(1),
            reason: 'the seam is these two files and no others; '
                '$declared is missing or duplicated');
      }
    });

    test('nothing under lib/src/data/ can write or retire history', () {
      expect(writeCallSitesUnder(Directory('${libSrc.path}/data')),
          hasLength(declaredDataWriteSites),
          reason: 'PHASE 10 READS AND NEVER WRITES. registerRetentionPolicy '
              'uninstalls a differing policy and installs its own '
              '(database.dart:847-864), which is the two-writer fight 8b '
              'settled while the app collector still runs — restarting it '
              'from the read path would show up as 8b\'s side_by_side case '
              'failing for a reason nobody could locate');
    });

    test('the write sweep can see an offender', () {
      // declaredDataWriteSites is ZERO, so the pin above proves nothing on
      // its own: a sweep that always returns empty passes it.
      final seeded = Directory.systemTemp.createTempSync('relay-data-write-');
      addTearDown(() => seeded.deleteSync(recursive: true));
      File('${seeded.path}/insert.dart').writeAsStringSync(
          'void f(Object db) { db.insertTimeseriesData(t, now, v); }\n');
      File('${seeded.path}/retention.dart').writeAsStringSync(
          'void f(Object db) { db.registerRetentionPolicy(t, p); }\n');
      File('${seeded.path}/mention.dart').writeAsStringSync(
          '/// insertTimeseriesData is what the SINK does, not this.\n');

      expect(writeCallSitesUnder(seeded), hasLength(2),
          reason: 'both write doors are seen, and a doc comment naming one '
              'is not a call site — a sweep that flagged prose would make '
              'the honest explanation of why there is no write path here '
              'impossible to write down');
    });

    test('the prefix has one spelling', () {
      expect(prefixSpellingFiles(libRoot), [prefixSpellingFile],
          reason: 'the default prefix is the side-by-side guarantee, and a '
              'default duplicated into a second place is a default that '
              'drifts — this one drifting means gateway rows in the app\'s '
              'tables with no error anywhere');
    });

    test('no unhandled fire-and-forget under lib/src/collect/', () {
      expect(dartFilesIn(libCollect), isNotEmpty,
          reason: 'the collect scope exists and holds .dart files, or the '
              'pin below has been passing against nothing');
      expect(unhandledFireAndForgetSites(libCollect),
          hasLength(declaredUnhandledFireAndForget),
          reason: 'unawaited() attaches no handler (project memory): a '
              'flush future that rejects with nobody listening is an '
              'uncaught async error on the gateway\'s one isolate. '
              'StateMan._monitor (state_man.dart:2369) is the in-repo '
              'example of doing it right — copy that shape');
    });
  });

  group('freeze 5: no literal port', () {
    test('no test file hard-codes a port number', () {
      expect(literalPortLines(testRoot), isEmpty,
          reason: 'two worktrees must be able to run this suite at once. A '
              'hard-coded listening port collides across parallel runs and '
              'the collision looks exactly like a real failure in the code '
              'under test — which is how an afternoon goes. Bind zero and ask '
              'the socket what it got; TcpProxy already defaults that way');
    });
  });

  group('freeze 9: the soak trees cannot reach an unseeded random or a wall '
      'clock (11-02)', () {
    test('the two soak scopes exist and hold dart files', () {
      // First, and for the reason at the top of this file: the sweep below is
      // trivially satisfied by reading nothing, and these two paths are new.
      for (final scope in <Directory>[testSoak, testSoakSupport]) {
        expect(scope.existsSync(), isTrue,
            reason: 'no directory at "${scope.path}", so freeze 9 has been '
                'passing against nothing');
        expect(dartFilesIn(scope), isNotEmpty,
            reason: '"${scope.path}" holds no .dart file');
      }
    });

    test('no file under test/soak/ or test/support/soak/ reaches one', () {
      expect(
          <String>[
            ...soakDeterminismOffenders(testSoak),
            ...soakDeterminismOffenders(testSoakSupport),
          ],
          isEmpty,
          reason: 'the whole soak is a pure function of its seed, and a '
              'single stray `Random(` or `DateTime.now()` in a checker or a '
              'generator breaks reproduction in the way that is hardest to '
              'notice: the seed is right, the repro log is right, the log '
              'still prints, and the run diverges anyway. Nothing in the '
              'artifact says so, and the reproduction attempt produces a '
              'different storm that looks like the failure not reproducing. '
              'Seed a SeededScenarioRandom, or take the clock from SoakClock; '
              'if the line genuinely records rather than decides, it needs an '
              'entry in soakDeterminismAllowList with its argument');
    });

    test('the sweep bites a file that does reach one — three tokens, three '
        'fixtures', () {
      // A sweep for an ABSENT token passes over an empty file, so the arm
      // above is decoration until something proves it counts. One fixture per
      // forbidden spelling, fed through the real directory sweep rather than
      // through the line matcher, so the file walk and the allow-list are
      // exercised too.
      for (final (name, line) in <(String, String)>[
        ('bare_random.dart', '  final r = Random(7);'),
        ('secure_random.dart', '  final r = Random.secure();'),
        ('wall_clock.dart', '  final at = DateTime.now();'),
        // The UTC-native spelling, and the one a Dart 3 author reaches for.
        // 11-04 sabotage 2 aged the freshness verdict on the wall clock INSIDE
        // the checker and produced a fully green ninety-second arm — 718,480
        // judged readings, zero violations — because wall and monotonic agree
        // on a machine nobody is stepping. Freeze 9 was the ONLY thing that
        // caught it. So for that failure class this sweep is not one line of
        // defence among several; it is the whole of it, and a needle it does
        // not carry is a hole with nothing behind it. Written
        // `DateTime.timestamp().difference(_epoch)` the same sabotage passed
        // the sweep and the milestone would have shipped claiming a monotonic
        // anchor it did not have.
        ('utc_wall_clock.dart', '  final at = DateTime.timestamp();'),
      ]) {
        final planted = _plant(name, line);
        final hits = soakDeterminismOffenders(planted);
        expect(hits, hasLength(1),
            reason: 'the sweep did not catch "$line" in $name, so the arm '
                'above would pass on the day somebody writes it: $hits');
        expect(hits.single, contains(name));
      }
    });

    test('and it does NOT bite a file that only names one in a comment', () {
      // The repo's own experience: `grep -c` counts comments, and a header
      // paragraph explaining why `DateTime.now()` is forbidden would make the
      // sweep self-invalidating. `invariant.dart:88` already names
      // `Random.secure` in a doc comment for a good reason.
      final planted = _plant(
        'commentary.dart',
        '/// Never use Random(7) or DateTime.now() here.\n'
        '// Random.secure() is worse.\n'
        'void nothing() {}',
      );
      expect(soakDeterminismOffenders(planted), isEmpty,
          reason: 'a file that merely explains the rule was reported as '
              'breaking it, so the sweep cannot coexist with its own '
              'documentation');
    });

    test('every allow-list entry still earns its place', () {
      // The other direction, and the one nobody checks: an exemption for a
      // file that no longer contains what it was exempted for is a hole in
      // the sweep that reads as a rule.
      for (final entry in soakDeterminismAllowList.entries) {
        final matches = <File>[
          for (final scope in <Directory>[testSoak, testSoakSupport])
            ...dartFilesIn(scope)
                .where((f) => f.uri.pathSegments.last == entry.key),
        ];
        expect(matches, hasLength(1),
            reason: 'soakDeterminismAllowList exempts "${entry.key}" '
                '(${entry.value}) and the soak trees hold '
                '${matches.length} files by that name');
        expect(nonDeterministicLines(matches.single.readAsStringSync()),
            isNotEmpty,
            reason: '"${entry.key}" is exempted from freeze 9 and no longer '
                'contains anything the sweep would have caught. The entry is '
                'now a standing exemption for a file nobody is watching — '
                'delete it');
      }
    });
  });
}

/// Writes [contents] to [name] in a fresh temp directory, cleaned up after.
Directory _plant(String name, String contents) {
  final directory = Directory.systemTemp.createTempSync('relay-soak-freeze-');
  addTearDown(() => directory.deleteSync(recursive: true));
  File('${directory.path}/$name').writeAsStringSync(contents);
  return directory;
}

// ---------------------------------------------------------------- the sweeps
//
// Crude and line-based, in the style the two existing sweeps in this
// repository already use. A parsed AST would be more precise and would also be
// a thing to maintain; these are meant to be readable by the person they are
// about to stop.

/// Every `.dart` file under [directory], or none if it does not exist.
List<File> dartFilesIn(Directory directory) => directory.existsSync()
    ? directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList()
    : <File>[];

/// A doc comment arguing *about* a timer is not a timer
/// (`teardown_test.dart:510-512`).
bool _isDocComment(String line) => line.trimLeft().startsWith('///');

/// And neither is an ordinary comment, for the sweeps that say so.
/// `no_retry_test.dart:181` measures with both stripped.
bool _isAnyComment(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('///') || trimmed.startsWith('//');
}

/// Timer offences: a `Timer.periodic(` in a file no plan allow-listed, or a
/// retained `Timer(` that does not name a field.
List<String> timerOffenders(Directory directory) {
  final offenders = <String>[];
  for (final file in dartFilesIn(directory)) {
    final name = file.uri.pathSegments.last;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isDocComment(line)) continue;
      if (line.contains('Timer.periodic(') &&
          !periodicTimerAllowList.containsKey(name)) {
        offenders.add('${file.path}:${i + 1}: $line');
      }
      // `Timer.run` is exempt and does not match this spelling anyway: it
      // cannot outlive the turn it was scheduled in and it holds nothing open
      // (`teardown_test.dart:519-522`). A constructed `Timer(...)` can do
      // both, so it has to be reachable through a named field to be
      // cancellable — AND its file has to be one a plan put on the retained
      // list. The naming rule alone says a timer can be cancelled, not that
      // anybody decided it should exist.
      if (line.contains('Timer(')) {
        if (!line.contains('_timer')) {
          offenders.add('${file.path}:${i + 1}: $line');
        } else if (!retainedTimerAllowList.containsKey(name)) {
          offenders.add('${file.path}:${i + 1}: $line');
        }
      }
    }
  }
  return offenders;
}

/// How many `Timer.periodic(` occurrences live under [directory].
int periodicTimerCount(Directory directory) {
  var count = 0;
  for (final file in dartFilesIn(directory)) {
    for (final line in file.readAsLinesSync()) {
      if (_isDocComment(line)) continue;
      if (line.contains('Timer.periodic(')) count++;
    }
  }
  return count;
}

/// How many retained one-shot `Timer(` occurrences live under [directory].
int retainedTimerCount(Directory directory) {
  var count = 0;
  for (final file in dartFilesIn(directory)) {
    for (final line in file.readAsLinesSync()) {
      if (_isDocComment(line)) continue;
      if (line.contains('Timer(')) count++;
    }
  }
  return count;
}

/// Every line under [directory] containing [needle] — **comments included**.
List<String> mentionsOf(Directory directory, String needle) {
  final hits = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(needle)) hits.add('${file.path}:${i + 1}');
    }
  }
  return hits;
}

/// An awaited call to something an upstream answers.
/// `readAttribute` is in the needle since the write-typing fix, and it is the
/// one widening this sweep has taken: `OpcUaUpstreamLink._writeTargetType`
/// asks a node for its DataType before shaping a write, which is a genuine
/// crossing into the plant and `\.read\(` cannot see it — `.readAttribute(`
/// does not match, because the needle requires the `(` to follow the verb.
/// Adding the crossing without adding the needle would have put a bounded read
/// on the write path where neither sweep could count it, which is precisely
/// the drift these two numbers exist to stop. `browse` is still out; see
/// [unawaitedUpstreamSites]' closing paragraph for whose obligation that is.
final RegExp _upstreamCall =
    RegExp(r'\.\s*(awaitConnect|connect|readAttribute|read|write)\s*\(');

/// Every line under [directory] that awaits an upstream call.
List<String> upstreamAwaitSites(Directory directory) {
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.contains('await')) continue;
      if (!_upstreamCall.hasMatch(line)) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}

/// The subset of [upstreamAwaitSites] with no bound on how long they may take.
List<String> unboundedUpstreamAwaits(Directory directory) =>
    upstreamAwaitSites(directory)
        .where((site) => !site.contains('deadline') && !site.contains('.timeout('))
        .toList();

/// Every line under [directory] that calls an upstream **without** awaiting it.
///
/// **08-13's gate closes the blind spot 08-07 and 08-11 both recorded.**
/// [upstreamAwaitSites] requires the word `await` on the line, so a call whose
/// future is *stored* rather than awaited — `_reopenSessionIfNeeded`'s dial,
/// which has to be stored so `dispose` can await it instead of deleting the
/// native client out from under an in-flight connect (a measured SEGV) — was
/// invisible to it. So was `OpcUaAddressSpace.childrenOf`'s
/// `client.browse(...).timeout(deadline)`, on the other half of the same gap.
///
/// This sweep is the other half and it is deliberately **not** the widening
/// 08-07 refused: it does not re-count the awaited sites under a new rule, it
/// counts only the lines the first sweep cannot see. The property asserted on
/// them is the same one — a bound — because the hazard is the same one. A
/// crossing into the plant that can hang is a poll cycle that can hang, and
/// whether the caller wrote `await` on that line has nothing to do with it.
List<String> unawaitedUpstreamSites(Directory directory) {
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (line.contains('await')) continue;
      if (!_upstreamCall.hasMatch(line)) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}


/// Every line under [directory] that calls `.write(` on something.
List<String> upstreamWriteSites(Directory directory) {
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.contains('.write(')) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}

/// The subset of [upstreamWriteSites] carrying a retry shape.
List<String> retryShapedWrites(Directory directory) => upstreamWriteSites(
        directory)
    .where((site) => retryShapes.any((shape) => site.contains(shape)))
    .toList();

/// Every line under [directory] that throws an [UnimplementedError].
///
/// Comments are skipped for the usual reason — a doc comment arguing about an
/// unwritten member is not an unwritten member — and the line itself is kept
/// so the "names its owner" case can read the plan id out of it.
List<String> unimplementedMemberSites(Directory directory) {
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.contains('UnimplementedError(')) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}

/// The six `StateManHarness` levers, as they would be spelled in a class body.
///
/// **Six and not nine.** `staleAfter`, `roundTrips` and `statusNotifications`
/// are the surface's three *observables*, and two of them are already
/// legitimate members of `LocalStateMan` — `staleAfter` is the deadline this
/// source declares and `statusNotifications` is 08-09's binding, forwarded by
/// the harness rather than invented by it. Reading a count is not a way to move
/// a plant. The six below are.
const List<String> harnessLevers = <String>[
  'setValue',
  'setValues',
  'setQuality',
  'dropKey',
  'disconnectUpstream',
  'reconnectUpstream',
  // The seventh, added by 10-11 when the `db` contract leg grew one.
  // `StateManDataHarness` is declared beside its cases rather than on
  // `StateManApi` for the reason its own doc gives: *"a client that could
  // insert samples could forge history, and a chart is evidence"*. A
  // `seedTimeseries` on a class a session can reach is that client, and it is
  // worse than the other six — a forged value expires the moment the next
  // real sample lands, and a forged row is on disk until retention takes it.
  // Recording is the gateway's job, upstream of anything a socket reaches.
  'seedTimeseries',
];

/// Every non-comment line under [directory] declaring one of [harnessLevers].
///
/// Matches a **declaration**, not a call: `lib/` may perfectly well call
/// something named `setValue` on a client it wraps, and forbidding the word
/// would be a sweep nobody could keep green. What must not exist is a member
/// with one of these names on a class a session can reach.
List<String> harnessLeverSites(Directory directory) {
  final declaration = RegExp(
      r'^\s*(?:@override\s+)?(?:void|Future<void>|set)\s+(' +
          harnessLevers.join('|') +
          r')\s*[(=]');
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!declaration.hasMatch(line)) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}

/// Every non-comment line under [directory] that names the forwarder.
List<String> forwarderSites(Directory directory) {
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.contains(forwarderSpelling)) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}

/// Files under [directory] whose imports reach the database layer: either
/// seam file by path, or the `tfc_dart` barrel with no `show` clause — the
/// barrel re-exports the database layer wholesale, so an unrestricted import
/// of it is the same back door wearing a different URI.
///
/// The statement can wrap — a `show` clause on its own line is the ordinary
/// formatting — so the whole statement is judged, not the line.
List<String> seamImportFiles(Directory directory) {
  final files = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.trimLeft().startsWith('import ')) continue;
      var statement = line;
      var j = i;
      while (!statement.contains(';') && ++j < lines.length) {
        statement += ' ${lines[j]}';
      }
      final reachesSeam =
          statement.contains('tfc_dart/core/database.dart') ||
              statement.contains('tfc_dart/core/database_drift.dart') ||
              (statement.contains('tfc_dart/tfc_dart.dart') &&
                  !statement.contains(' show '));
      if (reachesSeam) {
        files.add('${file.path}:${i + 1}');
        break;
      }
    }
  }
  return files;
}

/// Insert and retention call sites under [directory], outside comments.
///
/// The two doors `Database` opens onto writing history: `insertTimeseriesData`
/// puts a row in, `registerRetentionPolicy` decides what gets thrown away —
/// and the second one *uninstalls* whatever policy it disagrees with.
List<String> writeCallSitesUnder(Directory directory) {
  final sites = <String>[];
  if (!directory.existsSync()) return sites;
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (line.contains('insertTimeseriesData') ||
          line.contains('registerRetentionPolicy')) {
        sites.add('${file.path}:${i + 1}');
      }
    }
  }
  return sites;
}

/// Files under [directory] spelling the literal `'gw_'` outside a comment,
/// by bare file name so the pin reads as the sentence it is.
List<String> prefixSpellingFiles(Directory directory) {
  final files = <String>[];
  for (final file in dartFilesIn(directory)) {
    for (final line in file.readAsLinesSync()) {
      if (_isAnyComment(line)) continue;
      if (!line.contains("'gw_'")) continue;
      files.add(file.uri.pathSegments.last);
      break;
    }
  }
  return files;
}

/// Every non-comment `unawaited(` line under [directory] that carries
/// neither a `.catchError(` nor an `onError` on the same line.
///
/// Crude and line-based like everything else here; a handler attached on a
/// following line will be flagged, and the fix is to put it on the same
/// line the way `collector.dart:169` and `state_man.dart:2369` both do.
List<String> unhandledFireAndForgetSites(Directory directory) {
  final sites = <String>[];
  for (final file in dartFilesIn(directory)) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.contains('unawaited(')) continue;
      if (line.contains('.catchError(') || line.contains('onError')) continue;
      sites.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return sites;
}

/// A bare `Random(`, not the tail of a longer name.
///
/// The negative lookbehind is load-bearing: `SeededScenarioRandom(seed)` — the
/// generator the soak is REQUIRED to use — ends in `Random(`, so a plain
/// `contains` would report every correct call site as a violation and the
/// sweep would have to be deleted within a day.
final RegExp _bareRandom = RegExp(r'(?<![A-Za-z0-9_$])Random\(');

/// Every non-comment line of [source] that reaches an unseeded random or a
/// wall clock.
///
/// Comment lines are skipped, and that is not optional: `invariant.dart:88`
/// names `Random.secure` in a doc comment explaining why the soak does the
/// opposite, and this file's own allow-list argues about `DateTime.now()`. A
/// sweep that a paragraph about the rule can break is a sweep that gets
/// deleted rather than obeyed.
List<String> nonDeterministicLines(String source) {
  final lines = source.split('\n');
  return <String>[
    for (var i = 0; i < lines.length; i++)
      if (!_isAnyComment(lines[i]) &&
          (_bareRandom.hasMatch(lines[i]) ||
              lines[i].contains('Random.secure') ||
              lines[i].contains('DateTime.now()') ||
              // Dart's OTHER wall clock, and the one this sweep would have
              // waved through. `DateTime.timestamp()` is the UTC-native form
              // of `DateTime.now().toUtc()`; it appears nowhere in the
              // repository today, which is what made this a gap rather than a
              // breach. It matters because freeze 9 was the ONLY thing that
              // caught 11-04 sabotage 2 — a wall-clock-aged freshness verdict
              // that left the ninety-second arm fully green over 718,480
              // judged readings — so for that failure class the sweep is the
              // whole defence rather than one layer of it.
              lines[i].contains('DateTime.timestamp(')))
        'line ${i + 1}: ${lines[i].trim()}',
  ];
}

/// Every file under [directory] that reaches one, outside the allow-list.
///
/// Reported as `path:line: text`, so a failure names the file and the line
/// rather than only the count — the reader's next action is to open it.
List<String> soakDeterminismOffenders(Directory directory) {
  final offenders = <String>[];
  for (final file in dartFilesIn(directory)) {
    final name = file.uri.pathSegments.last;
    if (soakDeterminismAllowList.containsKey(name)) continue;
    for (final hit in nonDeterministicLines(file.readAsStringSync())) {
      offenders.add('${file.path}:${hit.replaceFirst('line ', '')}');
    }
  }
  return offenders;
}

/// A four- or five-digit integer that is not part of a longer identifier.
final RegExp _portLiteral = RegExp(r'\b\d{4,5}\b');

/// Every line under [directory] that puts a literal number next to a port.
List<String> literalPortLines(Directory directory) {
  final hits = <String>[];
  for (final file in dartFilesIn(directory)) {
    final name = file.uri.pathSegments.last;
    if (literalPortAllowList.containsKey(name)) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_isAnyComment(line)) continue;
      if (!line.toLowerCase().contains('port')) continue;
      if (!_portLiteral.hasMatch(line)) continue;
      hits.add('${file.path}:${i + 1}: ${line.trim()}');
    }
  }
  return hits;
}
