# Handoff — `relay-transmission-e2e`

Worktree `../tfc-hmi-worktrees/relay-transmission-e2e`,
branched off `origin/feat/relay-pipe` (PR #463). **Pushed** — this work IS
PR #463 now, and the worktree is in sync with it (0/0). Development continues
on that branch; `git push origin relay-transmission-e2e:feat/relay-pipe` is a
fast-forward from here.

**The plan lives in `docs/websocket-feature-completeness.md`.** Read that
first — this file is only the state of the work.

---

## What the branch does

Reviewed #463 with the brief "core protocol and transmission 100% on first
merge", built an adversarial e2e bench, and fixed what the review found.

### Transmission and protocol fixes
| What | Why it mattered |
|---|---|
| write-status clock skew | the gateway told a panel it was **safe to re-send** a command the plant had already taken. 1 s of skew was enough |
| access templates never consulted on the wire | `setpoints`/`device`/`force` all collapsed to `operate` the moment a value left the panel |
| the cold-key bypass | **my own first fix reintroduced the bug** — a write to a key nobody subscribed took the key-level answer and could actuate a `force`-bound member |
| numeric strictness in the member diff | dart2js sends `50` for `50.0`, so every integral REAL read as "moved" and the wire refused what the app allowed |
| browse hiding | `type:"folder"` on a hidden variable returned its live value; the node's **id** decides now, not the caller's claim |
| read floor on `write`/`ackAlarm` | a session holding nothing could enumerate the plant's address space |
| history-view floor | a session that could not *read* a saved chart could *overwrite* one |
| anonymous revocation | anonymous sessions were frozen while stations were re-graded; the comment defending it claimed a parallel that did not exist |
| Modbus narrowing | **live on the plant** — 70000 silently became 4464 on a Uint16 (BER02/03 are Saia-over-Modbus) |
| Modbus readback | was the poll cache, not a device read |
| freshness keep-alive port | 1103 of 1437 values wrongly badged stale; the fix existed in `tfc_dart` and had never reached `tfc_relay_local` |
| client frame ceiling, hello degradation, wire timestamp range-checks, per-entry containment, generation sentinel | `fix-wire`'s seven commits |
| `LocalStateMan` describes types | closed the violet-conveyor defect; the asset lane's enum case went green on its own |

### Test infrastructure built
- `packages/tfc_relay_local/test/support/plant_bench.dart` — plant → gateway →
  **fault proxy on the panel's socket** → real client. The crossing neither
  existing harness could make.
- **Actuation counting at the plant node** (`records: true` in
  `tfc_plant_sim`). A duplicated command is invisible to a read-back; this is
  the only instrument that can see it.
- `test/e2e_assets/` — real mimic widgets over the production provider chain
  (6 cases). `test/e2e_pages/` — eleven advanced routes (48 cases).
- Deep nested structs + a type-graph cycle guard that names the loop.
- `write_grading_benchmark_test.dart` — 1.08 µs/write, linear at 3.49× for 3×
  the leaves.

---

## Where this is — 2026-09-21 (third pass)

58 commits, pushed to `feat/relay-pipe` (PR #463).

**The keystone is closed, end to end.** A relayed panel now reads *and*
writes the plant's shared configuration: preferences through
`preferences.*`, and pages, assets and key mappings through
`configItems.replace`. Eight of the thirteen known-reds this branch started
with are green and promoted; **five remain**, and none of them is the
keystone.

The inventory this branch started from was 78 features: 51 served, 9 partial,
18 unserved. Call it **~59 of 78** now.

| Lane | State |
|---|---|
| `test/e2e_pages` | **46 pass, 5 known-red**, in UTC *and* `TZ=Europe/Copenhagen` |
| `test/e2e_assets` | 6 pass |
| app suite (`flutter test test/`) | 7888 pass, **2 pre-existing failures** (`gateway_link_test`) |
| `tfc_stateman_contract` | 997 pass |
| `tfc_relay_protocol` | 541 pass |
| `tfc_relay_server` | 1238 pass |
| `tfc_relay_client` | 771 pass |
| `tfc_relay_local` | **20 red, pre-existing** — see below |
| surface | 87 callable names, 95 members over eleven types, 41 access wire names, 37 access checks |

**The five that remain**, none of them a write path:

| Known-red | Item |
|---|---|
| a tag write from the panel leaves an audit row | 3 |
| an alarm acknowledge leaves an audit row | 3 |
| the `station` column is the gateway's knowledge of the socket | 3 |
| the knowledge base says it cannot be reached, not that it is empty | 4 |
| the server-config attribution line names the person | 5 |

**Every remaining gap is pinned by a `knownRed` case that fails today**, and
the CI job fails the day one of them starts passing without being promoted.

### Two traps this lane sets, and both read as a backend refusal

Either one costs an afternoon, because a save that silently never happens is
indistinguishable from a save the gateway threw away.

1. **A poll must not hold the frame pipeline still.**
   `live(tester, () => untilTrue(...))` suspends the binding's clock for its
   whole body. A save pressed in the tree is issued in the fake-async zone,
   and anything on its path that arms a `Timer` arms a *fake* timer, which
   only fires when the tester pumps. Measured: 175 polls over ten seconds all
   read the old row, and the write reached the gateway the instant the poll
   gave up. Use **`untilTrueWhilePumping`** for any claim about a write a
   *widget* issued; `untilTrue` is still right for a wire probe.
2. **Zero-duration pumps never finish an animation.** `settleFrames` advances
   real time, not the binding's clock, so an `ExpansionTile` stays mid-expand,
   its children overlap, and `tap` on a button inside it hit-tests the row
   header, warns, and does nothing. Pump *with a duration* after opening one.

### Open decisions somebody has to make

**PR #588 (`bench/fake-plant`) and this branch both add `packages/tfc_plant_sim`.**
An architecture review found this branch's copy is a strict content superset
(it adds `Actuation` recording, nested structs, two test files, and
independently contains 588's motion-timer fix); the commits are different, so
git sees add/add. **#588 should own the package.** Both also define a
`plant-sim-test` job in `.github/workflows/test.yml`, with different text —
whoever lands second must resolve to ONE job, or the workflow is invalid or a
job is silently dropped.

**Do not merge #588 into this branch to resolve it.** Tried, aborted: it
throws **29 conflicts** and #588 touches roughly **380 golden PNGs** plus
widget and page code. Goldens are Linux-rendered through `scripts/goldens.sh`
(see [[golden-raster-is-portable-except-text]]); resolving them on a Mac
produces wrong bytes. **If the repo squash-merges, #588 must land first.**

**This handoff is in the tree, and arguably should not be.** The same review
noted no `HANDOFF-*.md` exists under `docs/` on `origin/main` — it is session
state, not documentation of the product. Kept because it is what resumes this
work; move it to the PR description if #463 is about to merge.

### Unverified at the point this was written

The compare-and-swap fix (`0bc62bca6`) landed after the last full lane run.
Re-run before trusting the branch:

```
CENTROIDX_E2E_PAGES=1 flutter test test/e2e_pages --concurrency=1
flutter test test/
```

`tfc_dart`'s config and relay suites (450 + 28) and `dart analyze` are green
on it. The change is additive and only bites when `baseRevisions` is passed,
which only the relayed `configItems.replace` path does — so the blast radius
is confined, but it has not been proven.

Also unread: the tail of that review's answer on the `preferences.*` door. It
said the door "has the same read-outside-lock shape but carries no
base-revision contract; its only exposure is the same unchanged-but-deleted
gap, which loses nothing the caller intended" — and was cut off there. Worth
finishing before calling the write path done.

### Pre-existing red, proven not this branch's

**`packages/tfc_relay_local` is not green, and was not green before this
branch.** `test/collect/collection_runner_test.dart` fails **11 of 25** cases,
and the package as a whole fails 20, all in the collector family and all with
`the condition did not hold within 5000 ms`. The file uses no database at all
— `FakeSink` and `FakeUpstreamLink` behind a real `LocalStateMan` — so this is
logic or timing, not infrastructure, and it is not the load effect below: it
reproduces identically on a quiet machine, running the file alone.

Checked rather than assumed, twice:

  * reverting this branch's `config_store.dart` and `database_drift.dart`
    changes it not at all (14 pass, 11 fail either way);
  * checking the branch **base** out (`848c27089`, `feat/relay-pipe`) and
    running the same file gives the same 14 and 11.

No commit on this branch touches `packages/tfc_relay_local/lib/src/collect/`
or its tests. So it is PR #463's base that is red here, and it is outside this
branch's work — but it is inside the merge, and somebody has to own it before
"core protocol and transmission 100% on first merge" is true.

### A machine-level cause of mass red

A green lane run failed 40 of 51 cases with "the gateway closed the socket"
and one-second sign-in timeouts, then passed all 42 fifteen minutes later with
nothing changed. The cause was **6542 orphaned `umas_stub_server.py`
processes**, some nineteen days old, all reparented to PID 1, left behind by
UMAS test runs across several worktrees. Load was 7.5; the lane took 7:10
instead of 1:03. Before believing a mass failure in this lane, check
`pgrep -f umas_stub_server.py | wc -l` and `uptime`.

---

## The remaining work, in order

Each row names the acceptance test that is already written and already red.
Nothing below needs a new test first; they exist.

### 1. The keystone — CLOSED

All six of its known-reds are green. `BackendConfigWriter` writes the plant's
`config_item` rows on behalf of a verified identity; `preferences.*` and
`configItems.replace` are its two doors, and the app calls both. What is left
of the design below is one precondition — see "Preconditions".

### 2. The relayed panel's configuration mirror — CLOSED

Answered the way the work pointed: **a relayed panel trusts the wire.**
`configRowsComeOverTheWire` is the one place "can a mirror exist on this
platform" and "are this panel's rows in it" are told apart, and a relayed
station now reads pages, assets and key mappings the way a browser does. Its
mirror is still built, because it still owns this station's own scope.

Two screens had to learn that the rows can arrive after they opened — the
page editor re-snapshots, the key repository re-reads, and both only when
there is nothing unsaved to lose.

### 3. Audit rows for what the panel actually does

**Three known-reds.** The one-action-id decision they were blocked on is now
answered (see the design below): the decorator mints `newActionId()` per
graded call instead of passing the method name.

| Known-red case | What it needs |
|---|---|
| a tag write from the panel leaves an audit row | record on the write path |
| an alarm acknowledge leaves an audit row | same |
| the `station` column is the gateway's knowledge of the socket | stop trusting the label the client typed into `session.login` (D-11) |

Worth knowing before starting: `actionId: method` still reaches
`audit_entry.action_id` for every relayed decision row **except the
preferences door**, which now mints one per graded call. So every relayed
`history.createView` is still ONE action in the trail whose tile names
whoever wrote last, and the pattern to copy is `_PolicyPreferences._graded` —
`_requireGroup` and `_recordAllowed` already take an optional `actionId`, so
generalising it is a per-family edit and each family's pinned expectations
move with it. That was left deliberately narrow: a sweeping rename of a
column's contents made in passing is invisible in the diff of a feature
commit.

### 4. Knowledge base — no wire family at all

**One known-red**, and the largest single piece left. `guarded_knowledge_stores.dart`
has no `relayed_` twin. `TechDocIndex` carries `storeDocument`,
`updateSections`, `renameDocument`, `deleteDocument`, `updatePdfBytes` and
`search`, plus `PlcCodeIndex`'s own members — and `Uint8List` PDF payloads
against a 1 MiB frame ceiling, so it needs chunking or an out-of-band route.
Budget it as its own milestone, not an afternoon.

### 5. The smaller ones

- **Server config attribution line** (one known-red): it says "a station
  account, not a person" over a save that IS recorded against a person.
- **Chat / MCP** — `StateError('Database not connected')`, behind
  `kChatEnabled` (default true).
- **First-account creation** — impossible from a relayed panel.
- **UMAS browse** — dials its own `UmasClient` over TCP **from the panel**, so
  on a relayed deployment it reaches the wrong network entirely
  (`umas_browse.dart:375-420`).
- **Tag bindings refresh** runs only on the token-file poll; should load
  before `server.start()` and fail closed on a failed first load.
- **PLC owns the momentary latch** (ruled 2026-09-20). Not this branch's work.
  What this branch owes when it lands: one e2e per asset — press, kill the
  link, assert the bit falls at the node. **The `ConveyorGate` pusher and
  Festo VTUG coil FBs were never read**; only `FB_MButton` (safe,
  self-clearing) and `FB_ATV320` (latches) were.

### What is deliberately NOT in scope

**Cameras and media.** Deferred by the owner.

### Relayed browse — a trap, not a gap

The gateway's `browse.*` serves the **key namespace** (`HALL1.CN01.speed_hz`),
deliberately: answered from the key mappings so a dead PLC cannot make the key
picker spin (`backend_browse.dart`'s own header). The app's only browse caller
is the key-mapping editor, which needs **raw OPC UA node ids** to author a
mapping for a node nobody has mapped yet. Wiring the relayed source into
`browseOpcUaNode` would hand that editor the wrong address space. Authoring a
new key mapping over the relay needs an upstream browse, which 13-CONTEXT
considered and rejected.

---

## The keystone — what landed, and what the design still says

**It was:** the gateway could not write a `config_item` row.
`BackendSharedPreferences` refuses all seven mutators by name, a regression
from #465 (merged here at `22f18cdbb`, 2026-09-13), with no old code to
restore.

**It is now:** `BackendConfigWriter` in
`packages/tfc_dart/lib/core/relay/backend_config_writer.dart`, minted per
verified identity in `composeBackendRelay`'s `scopeFactory` and reaching the
wire as the fourth slot of `IdentityAccessFamilies`. `BackendSharedPreferences`
still refuses — it is the *composition-wide* source and the fallback when no
writer could be built, which is exactly the fail-closed default that slot
wants.

Three properties worth re-reading before extending it, each of which is a way
this writer could quietly destroy a plant's configuration:

- **The mirror is empty and must never delete.** `writeItems` replaces within
  kinds and this store's snapshot is permanently empty, so a save derived from
  it would remove every shared row of those kinds. Every write reads the
  plant's rows from Postgres first (`ConfigStore.readRemoteShared`) and hands
  them over as both the base of the replace set and as `derivedFrom`, which is
  what the diff, the sort keys and the compare-and-swap all run against.
  Mutation-verified: dropping `derivedFrom` reddens six cases.
- **One call is one action.** The id is minted in the policy decorator, before
  the check, and reaches the writer through `ActionScopedWrites` — a
  capability asked for by type, carried in a `Zone`. Not a parameter (that
  puts a client-supplied action id on the wire) and not a field (json_rpc_2
  dispatches without awaiting between frames, and this writer awaits a read of
  the plant before it writes).
- **Attribution is per call.** One gateway writes for every panel, so `who`,
  `roleName` and `station` are arguments rather than state.

### The design, settled by adversarial review — the parts still unimplemented

**One backend mechanism, two wire doors.** Every write of every kind already
funnels to `ConfigStore.writeItems` — preferences via `SharedRowPreferences`
→ the guard (`guarded_config_store.dart:812-830`), pages via `PageManager`
(`page_manager.dart:104-110`), key mappings via `saveKeyMappings`, undo via
`config_undo.dart:665-673`. So the gateway needs exactly **one** writer.

- `ConfigStore` in the composition: `local:` an ephemeral in-memory
  `AppDatabase`, `remote:` the backend's existing `Database`. Verified safe:
  the sync engine **never writes the remote** (`config_sync.dart:456-503`),
  removals derive from the caller's `derivedFrom` and not from the snapshot
  (`config_store.dart:722-735`), so an empty mirror can neither delete nor
  resurrect a shared row — the worst pre-reconcile case is a spurious
  `ConfigConflict`, closed by awaiting `store.syncSettled` before building the
  replace set. `stationScope` never reaches Postgres (`:672-681`).
- A **thin, stateless per-identity writer** minted in `scopeFactory`. It has
  to be per identity: `writeItems` takes `who` and `roleName` per call, so a
  composition-wide writer would put a constant in `config_change.who` while
  the audit row carries the verified username — one action id, two answers to
  "who did this", in the history this branch just put on the socket.
- **`writeItems` needs a `String? station` override** so `config_change.station`
  matches the audit row instead of always reading the gateway's name.
- **Two doors, because the grading genuinely differs.** Preferences are graded
  per *key*; a generic kind-graded member would have to grade a preference
  replace-set at the strictest key in the plant (`server_config_envelope`,
  `administer`) and lock a `configure` user out of saving `alarm_man_config`.
  So: keep `preferences.*`, and add `configItems.write` for `{page, asset}` /
  `{key_mapping}` with the check key derived **server-side from the kinds**
  and `preference` refused by name. Pin the two derived strings against
  `kConfigWriteKeys` with a test in `tfc_dart` — it can import both packages,
  `tfc_relay_server` cannot.
- **The action id: a non-wire capability interface**, type-tested by the
  decorator. Precedent is `TypeDescriptions` (`type_descriptor.dart:159`,
  tested at `policy_state_man.dart:555`). `_requireGroup` and `_recordAllowed`
  gain an `actionId` parameter; mint before the check, as
  `GuardedConfigStore.write` does.
  **Not** a `PreferencesApi` parameter — that puts a client-supplied action id
  on the wire, the forgery surface `AuditApi` refuses a write member for.
  **Not** a mutable "next action id" field: json_rpc_2 dispatches without
  awaiting between frames (`server.dart:114-115`), and the `await syncSettled`
  this design needs is exactly what would make request B's id land on request
  A's change rows.
- **Undo closes on the same store.** `executeUndo`'s seven inputs all exist at
  the backend, so `configHistory.undo(originalActionId)` plans and executes
  server-side and the client sends one string — the plan never crosses the
  wire, which is what keeps it from being a forgery surface. Two wrinkles: the
  gate is `undoGate(policy, plan)`, knowable only *after* planning, so the
  deny row comes from the plan's gate or the caught `AccessDenied` rather than
  from a constant; and the app's rule that a ready plan writing an empty diff
  is a contradiction must be mirrored.

### Preconditions — two of three are done, and the third is still open

1. **`libsqlite3-0` is in the backend image** (`docker/backend/Dockerfile`),
   and `BackendConfigWriter.create` degrades to null on any failure, with a
   test that injects a throwing mirror factory. Done.
2. **The reserved-key refusal is in** — `key_mappings` is refused by name for
   every session and every group, at the layer where the write lands, and
   bookkeeping ids survive every `clear`. Done.
3. **`ConfigStoreUnsafePoolException` is still open.** It fires when the
   backend's pool is > 1 (`config_store.dart`). Default is 1 and unset in
   compose, so it works today — but a deployment that raises
   `CENTROID_DB_MAX_POOL_CONNECTIONS` refuses every relayed configuration
   write, with a message about a pool that names nothing an operator set.
   Attach a dedicated pool-of-one `Database` or document it at the env knob.

### The design, as written before any of it was built

Kept because the arguments still hold — they are what any further write door
has to satisfy.


1. **`libsqlite3` is not in the backend image.** `docker/backend/Dockerfile:78-80`
   installs `ca-certificates` and nothing else; `sqlite3` 2.9.4 `dlopen`s
   `libsqlite3.so`. The gateway would construct the in-memory `AppDatabase`,
   throw `Failed to load dynamic library`, and **crash-loop under
   `restart: unless-stopped` with the plant's acquisition down** — while the
   macOS e2e bench passes, because macOS has a system libsqlite3. Add
   `libsqlite3-0` to the runtime apt line **and** build the store behind a
   try/catch that degrades to today's "writes refused", never to "backend
   down".
2. **A reserved-key refusal on `remove` and `clear(allowList:)`.** They are
   only group-graded, so once the blanket refusal lifts a `configure` session
   can delete the gateway's own `key_mappings` row over the wire.
3. **`ConfigStoreUnsafePoolException`** fires when the backend's pool is > 1
   (`config_store.dart:702-710`). Default is 1 and unset in compose, so it
   works today — but a deployment that raises `CENTROID_DB_MAX_POOL_CONNECTIONS`
   refuses every relayed write. Attach a dedicated pool-of-one `Database` or
   document it at the env knob.

### Deferred by name, not forgotten

**The relayed station-build panel's mirror** — item 2 of the map above. Scope
`configItems.write` to the mirror-less (browser) build in this PR and leave
the station-build refusal in place with a message; the rest is a client
design, untouched by any backend writer.

### Known, pre-existing, now visible

`_PolicyPreferences._graded` fires the **allow row after the delegate is
initiated, not after it completes** (`policy_state_man.dart:1530-1532`). Every
family does this. It is harmless while the backend cannot refuse; the moment
it can — CAS conflict, offline, pool — that row claims a save that never
landed.

## New finding — the relayed audit trail hides the newest rows under clock skew

`AuditTrailPage` bounds its default seven-day window at `clock.now()`
(`lib/pages/audit_trail.dart` `_firstPageOnly` → `AuditTrailFilters.toQuery`),
and `audit_entry.at` is stamped by whoever wrote the row. On a station those
are the same machine, which is why the window has never been a problem. **Over
the relay they are two machines**: the bound comes from the PANEL's clock and
the rows from the BACKEND's. A panel running even a second behind renders a
trail that is silently missing its newest rows, and the page has no way to say
so — it reports "N entries · Last 7 days", which is a claim about the plant's
history, not about the panel's clock.

This is the same class as the write-status skew this branch already fixed, and
the same class as the ungated-rows leg the store documents: recorded
faithfully, never shown, reads as "the trail missed it".

Two candidate fixes, and **neither is taken here** because the window is a
user-ruled specification ("the two modes, and the user's ruling behind them",
`audit_trail_store.dart`) and narrowing or widening its top edge is a decision
about what "Last 7 days" means, not a bug fix:

- **Open the upper bound in the default mode.** "The last seven days" has no
  natural upper edge; the bound exists only because `AuditWindow` is a closed
  interval. `AuditQueryParams` asserts both bounds or neither, so this needs a
  protocol shape for a half-open window.
- **Add slack** — `end: now + a minute or an hour`. One line, keeps the
  window closed, and turns a silent omission into a bounded one. It reddens
  the unit tests that assert the seven-day window exactly, which would need
  updating with the reason.

Measured, not inferred: the panel's own store answered **0 rows** for the
page's query and **5 rows** for the same query with the window removed, with
the rows stamped ~400 ms after the bound.

### Also noticed, not acted on

`BaseScaffold.title` is a **required** constructor parameter that nothing ever
reads — every page in the app passes one and no app bar renders it. Harmless,
but it cost an afternoon here: the knowledge-base case anchored on the page
title and there was no page title to find. Deleting it touches ~20 call sites
and showing it changes every screen, so it is a product decision rather than a
cleanup.

---

## Known-red and pre-existing, do not chase

- **19 `collect/` failures in `tfc_relay_local`** are **pre-existing on
  `origin/feat/relay-pipe`** — verified by checking the package out at the
  baseline and getting an identical 16 passed / 19 failed. They sit in
  `relay-packages-test`, which #463 already flags red on macOS.
- `trust_endpoint_test.dart` times out under heavy parallel load and passes
  twice in isolation — socket contention, not a defect.

## Gotchas that cost time
- `rm -rf .dart_tool/hooks_runner/shared/open62541/build/dl/src` whenever the
  native build says *"patch does not apply"*. Hit it in four packages.
- **Check `flutter --version` before reading any failure.** `which flutter` on
  the dev Mac is homebrew's 3.41.9; `.flutter-version` pins 3.44.9, and the
  older engine cannot decode the pinned SDK's `ink_sparkle.frag`, so every
  case that taps a Material surface dies with a shader error that looks like
  anything but a toolchain fault. The export does not survive between shell
  invocations either — put `PATH=~/flutter-sdks/$(cat .flutter-version)/bin:$PATH`
  inline on every command, backgrounded ones included.
- Parallel agents share this worktree's git index — **pathspec commits only**,
  never `git add -A`. Two agents editing `pubspec.yaml` from separate trees
  produced duplicate YAML keys that tests did not catch because
  `package_config` had not been re-resolved.
- zsh breaks `git commit -m` with embedded double quotes; use `-F <file>`.
- Agents hit session limits mid-task. Four did. Their work was recoverable
  from the worktree, but verify rather than trust a mid-edit tree.

## How to run the lanes

**Put the pinned SDK on PATH inline, every time.** `which flutter` is
homebrew's 3.41.9 and `.flutter-version` pins 3.44.9; shell state does not
survive between commands, so an `export` in one is gone in the next.

```
export PATH="$HOME/flutter-sdks/$(cat .flutter-version)/bin:$PATH"

cd packages/tfc_relay_local && dart test --exclude-tags "db || soak"
CENTROIDX_E2E_ASSETS=1 flutter test test/e2e_assets/ --concurrency=1

# The pages lane. Needs docker.
CENTROIDX_E2E_PAGES=1 flutter test test/e2e_pages --concurrency=1

# The same lane under a clock that is not UTC. NOT optional — it is the only
# thing that catches the text-comparison defect class, and it caught a real
# one that every UTC run passed.
TZ=Europe/Copenhagen CENTROIDX_E2E_PAGES=1 \
  flutter test test/e2e_pages --concurrency=1

# The gated set. Every KNOWN RED case must still FAIL; one that passes is a
# case protecting nothing and the CI job fails on it.
CENTROIDX_E2E_PAGES=1 CENTROIDX_E2E_PAGES_KNOWN_RED=1 \
  flutter test test/e2e_pages --concurrency=1
```

The CI job `e2e-pages-test` runs all four and reconciles the counts (42 green,
9 known-red), so a switch that stops reaching the tests is an error rather
than a green run.

**Before believing a mass failure in this lane, check the machine.** See
"A machine-level cause of mass red" above: 40 of 51 cases failed with socket
errors under load 7.5 and all 42 passed fifteen minutes later with nothing
changed.

## Where the rest is written down

- **`docs/websocket-feature-completeness.md`** — the plan, derived from 78
  features with `file:line` evidence, and the keystone section.
- **The `knownRed` case descriptions themselves.** Each names the defect it
  pins, in its own words, at the place a reader meets it. They are the
  specification for the work above; the table in this file is only an index
  into them.
