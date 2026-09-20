# Making the WebSocket feature-complete

**Goal.** Every feature of the HMI works over the relay socket, and every one
has an end-to-end test over that socket. A relayed panel should be able to do
everything a direct-mode station can.

**Out of scope, by decision:** cameras and media. Deferred.

**Status of this document.** Derived from a full inventory: **78 features in
12 families**, of which 51 are served by the wire, 9 partially, and 18 not at
all; 29 are covered end to end over a real socket. Each gap names its
evidence. The sequencing is a proposal.

---

## 1. How to tell whether a feature works over the socket

Three questions, and a feature is only done when all three are yes.

1. **Is it on the wire?** A relay method or a `StateManApi` member exists.
   The registered surface is `relay_session.dart`'s method table, frozen by
   `surface_test.dart`. It carries **88 request methods and 6
   server-to-client notifications**, in ten families beside the value
   surfaces: `accessAdmin`, `accessTemplates`, `audit`, `backendConfig`,
   `browse`, `configItems`, `historyViews`, `preferences`, `session`,
   `timeseries`.
2. **Does the panel use it when relayed?** The app must not reach *past* the
   socket. `databaseProvider` answers **null** in gateway mode by design
   (`lib/providers/database.dart`), so anything that reads it directly is a
   feature that silently does nothing on a relayed panel.
3. **Is it tested over a real socket?** Not against a fake source, and not at
   the unit level.

**The reliable tell for question 2** is the `lib/core/` naming:
`relayed_*.dart` is the socket implementation, `guarded_*.dart` is the
direct-database one. A family with a `guarded_` file and no `relayed_` twin
does not work on a relayed panel.

```
relayed_access_stores.dart    relayed_config_items.dart
relayed_history_views.dart    relayed_preferences.dart

guarded_history_views.dart    <- has its twin
guarded_knowledge_stores.dart <- NO TWIN
guarded_report_store.dart     <- NO TWIN
```

---

## 2. The gaps, ranked

Ranked by whether the feature touches the plant's controls, then by what an
operator loses.

### Tier 1 — the plant's controls

**The socket carries everything. The app does not use the safest part of it.**

`holdToRun` and `HoldHandle` are implemented on the wire, in both gateway
compositions and in the client — and **no code under `lib/` calls either**
(grep: zero references outside `tfc_relay_client`). Every momentary control is
instead two plain writes: `start_stop_button.dart:26` says so in its own
words, *"pulses (true on press, false on release)"*, and `_writePulse` sends
`true` on tap-down and `false` on release as independent commands.

So the release is an ordinary write with an ordinary write's failure modes. If
the link dies, the panel is killed, or the operator's finger leaves the glass
while the socket is stalled, the `true` has landed and the `false` may never
be sent. Whether the machine then keeps running is a property of the PLC
program — a level-triggered `runKey` keeps running; an edge-triggered one does
not — so this is not a defect that can be confirmed or dismissed from this
repository alone. **It needs an answer from the PLC source before anything
else in this document is scheduled.**

That is precisely the hazard `hold`/`h` exists to remove: one key is one
counter, the counter stops the moment the ticks stop, and the gateway releases
every hold on session teardown. The deadman is built, tested and unused.

The hazard *is* covered at the gate level
(`packages/tfc_relay_local/test/gate/stuck_momentary_gate_test.dart`) — but
against a fake upstream, and never against a real plant with a real button
widget, so nothing measures what a stuck momentary does at the node.

**Action, ahead of every feature below:**
1. Establish from `~/Projects/sildarvinnsla` whether the SVN commands are
   level- or edge-triggered. That answer decides whether this is a live
   safety gap or a latent one.
2. Either move the momentary assets onto `holdToRun`, or write down why two
   plain writes are acceptable for these keys — with the PLC behaviour as the
   evidence, not as an assumption.
3. Add the missing e2e: press, lose the link before release, and assert at the
   plant node what state the machine is left in. The bench counts actuations
   at the node already, so this is a case rather than a new instrument.

Everything else in this tier is sound: live values, writes, three-state
outcomes, `writeStatus` and alarm acknowledge are served, implemented at both
ends, and covered end to end with actuation counted at the plant node.

Carry-over items, tracked but not feature gaps:
- **No audit row for a tag write or an alarm ack over the wire.** Needs a
  decision first: the app's guard mints an `actionId` in gateway mode while
  `RemoteStateMan` mints a separate `cmd`, so recording on both sides makes
  one operator action two row sets under two ids.
- **Tag bindings refresh only on the token-file poll** (`bin/main.dart`), and
  should load before `server.start()` and fail closed if that first load
  fails.

### Tier 1b — features that answer about the PANEL as if about the STATION

**Ranked above the unserved families, because an error is honest and a
plausible wrong answer is not.** Each of these has no `isGateway` branch at
all, so on a relayed panel it silently reports the panel host instead of the
plant's station — and nothing on screen says which machine is being described.

| Feature | Reaches past the relay at | What an engineer actually sees |
|---|---|---|
| **IP settings; station operations (D-Bus)** | `lib/pages/ip_settings.dart`, `lib/widgets/tfc_operations.dart`, `lib/widgets/dbus_gate.dart` — no `isGateway` branch | edits the **panel's** NetworkManager, restarts the **panel's** services, believing they are the station's |
| **About Linux: temperatures, system clock, update channel** | `lib/core/hardware_temperatures.dart:105-111,272` reads `/sys/class/hwmon` via `File()` | the panel host's temperatures and clock, presented as the station's |
| **Database stats pane** | `lib/widgets/panes/database_stats_pane.dart:74,125` | says "this database is local storage, not a Postgres" about the **panel** |
| **Knowledge base** | `lib/providers/tech_doc.dart:35-40,94` returns `[]` | the library opens and lists **nothing, with no error** — there is no empty-state message |
| **Config-store sync / undo** | `lib/providers/config_store.dart:146-150` detaches the remote when the database is null | the store runs local-only; undo and sync are silently absent |

The IP-settings row is the one to fix first in this tier. The others mislead;
that one lets somebody change the wrong machine's network configuration, and
`test/e2e_pages/pages/ip_settings.dart` exercises only the access gate, never
which host is being addressed.

The cheap first move for all five is the same and is not a feature: **make
them say which machine they are describing, or refuse when relayed.** That
converts a wrong answer into an honest one in an afternoon, and can land well
before any of them gets a wire path.

### Tier 2 — features with NO wire path at all

**Six families, not three.** 18 individual features across them; 51 of 78 are
served, 9 partially.

| Family | What a relayed panel gets |
|---|---|
| **Reports** | editor opens, lists nothing; a report the backend holds is invisible |
| **Knowledge base** (tech docs, PLC code, drawings) | the library says it cannot be reached |
| **Configuration history** | the gateway answers method-not-found |
| **Page-editor save** | `UnsupportedError` — "edit the pages on a station"; reads work via `configItems` |
| **Config-store sync** | see Tier 1b — silent, not an error |
| **Chat / MCP** | `StateError('Database not connected')`, behind `kChatEnabled` (default true) |
| **First-account page** | account creation impossible from a relayed panel |
| **UMAS browse (Modbus)** | dials its own `UmasClient` over TCP **from the panel**, so it reaches the wrong network |

All six hang off the same root: `databaseProvider` answers `null` when
`gateway.isGateway` (`lib/providers/database.dart:50-52`), and
`mcpDatabaseProvider` follows it (`lib/providers/server_database.dart:11-14`).
That is deliberate — the gateway is not supposed to hold a second connection
to the plant's Postgres — which is exactly why each family needs a wire path
rather than a database.

Three of the six are already pinned by cases in `test/e2e_pages/`. Those
become the acceptance tests.

### Tier 2b — the two gateway compositions disagree

`LocalStateMan` refuses, unconditionally, what `composeBackendRelay` serves:
`accessTemplates`, `accessAdmin`, `audit`, `backendConfig`, `configItems`
(`packages/tfc_relay_local/lib/src/local_state_man.dart:1739-1751`),
`preferences` without a database (`:1689`), and `timeseries`/`historyViews`
without a historian (`:1616-1648`). It also has **no alarm engine** — alarms
live only in `packages/tfc_dart/lib/core/relay/backend_alarms.dart`.

This matters for testing rather than for the plant: `buildGateway` is what
both e2e lanes compose, so every feature in that list is untestable by the
lanes that exist. Decide deliberately whether `LocalStateMan` is a harness
that should grow these, or whether the lanes should compose
`composeBackendRelay` and pay for a Postgres.

**And four pages that touch the plant are in no socket lane at all:**
`AlarmViewPage`, `StopTimeline` (downtime), `HistoryViewPage`, `ReportsPage`.
Reports is unserved; the other three are *served but untested over a socket*,
which is the more dangerous category — nothing would notice them breaking.

### Tier 3 — served, but coverage or correctness unverified

- **The five untriaged page cases** in `test/e2e_pages/` (server config edit
  landing on disk, audit trail rendering backend rows, page editor opening,
  `configItems.items(page)` gating, knowledge base opening). Deliberately not
  marked `knownRed` — nobody has established whether they are defects or
  unfinished fixtures. Triage is cheap and comes first in Tier 3, because it
  may move items into Tier 2.
- **Downtime, alarm rules, theming, i18n, page editor save** — each needs the
  three questions above answered with evidence. Not yet established either
  way; the inventory that would settle them is the first task below.

---

## 3. The plan

### Step 0 — settle the momentary-control question (first, and blocking)
See Tier 1. Read the PLC source for whether the commands are level- or
edge-triggered, then either move the momentary assets onto `holdToRun` or
record why two plain writes are safe for these keys. Nothing else in this
document is worth scheduling ahead of a possible stuck-machine hazard.

### Step 1 — make the panel/station confusions honest (an afternoon)
Tier 1b. Add the `isGateway` branch, or a banner naming the host. Cheapest
safety-per-hour in this document, and independent of every other step.

### Step 2 — triage the five untriaged page cases (half a day)
They are the cheapest source of new Tier 2 entries. Each is either a defect
(convert to `knownRed` with a named reason) or a fixture bug (fix it). Then
add the CI job the lane is deliberately missing: it has none today because a
lane whose failures nobody has read is not evidence.

### Step 3 — build the six missing families (the bulk)
Per family, in this order, because each one is a smaller version of the next:
**config history → knowledge base → reports.**

For each:
1. A protocol family in `tfc_relay_protocol` — methods, params, results,
   decoded per entry so one bad row costs one row.
2. A backend implementation behind `StateManApi`'s optional-interface pattern,
   graded by `PolicyStateMan` **through the decorator**, not by a call-site
   check. Reads take the family's read floor; writes take the group the app
   already demands, so the two transports cannot disagree.
3. A `relayed_*.dart` client store, chosen by the same transport branch its
   siblings use.
4. The `knownRed` case in `test/e2e_pages/` flipped to a live assertion. That
   is the acceptance test: it already exists and already fails.

### Step 4 — close the audit gap (after the id decision)
Decide one action id, then record tag writes and alarm acks on the wire, and
turn the three audit-trail `knownRed` cases live.

### Step 5 — make coverage self-checking
The lesson from the enum case: a hand-set skip is a step somebody forgets, and
a green lane then says nothing about the thing it was skipping. Prefer a test
that **asks the system** what it supports and asserts accordingly. A sweep
that walks the method table and fails when a registered method has no e2e case
would keep this document honest without anybody maintaining it.

---

## 4. Rules for the work

- **Every fix gets a test verified red first.** A fix without a test that
  provably bites is not done.
- **No second copy of a rule.** If the app and the wire must agree, they ask
  one function — `gradeTagWrite` is the pattern.
- **A feature is not done when the method exists.** It is done when a relayed
  panel does the thing, proven by a case driving the real widget over a real
  socket.
- **Performance is measured, not assumed.** The write path carries a benchmark
  (`test/measurement/write_grading_benchmark_test.dart`) whose ceilings catch
  a change in the *shape* of a cost. New families on hot paths get the same.
