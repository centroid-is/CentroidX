# Making the WebSocket feature-complete

**Goal.** Every feature of the HMI works over the relay socket, and every one
has an end-to-end test over that socket. A relayed panel should be able to do
everything a direct-mode station can.

**Out of scope, by decision:** cameras and media. Deferred.

**Status of this document.** The gaps below are established from the code, not
assumed — each names its evidence. The sequencing is a proposal.

---

## 1. How to tell whether a feature works over the socket

Three questions, and a feature is only done when all three are yes.

1. **Is it on the wire?** A relay method or a `StateManApi` member exists.
   The registered surface is `relay_session.dart`'s method table, frozen by
   `surface_test.dart`. Today it carries ten families beside the value
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

Nothing outstanding. Live values, writes, three-state write outcomes,
`writeStatus`, hold-to-run and alarm acknowledge are all served, implemented
at both ends, and covered end to end — including actuation counted **at the
plant node** rather than inferred from what the panel was told
(`packages/tfc_relay_local/test/e2e/`, `test/e2e_assets/`).

Carry-over items already known, tracked but not feature gaps:
- **No audit row for a tag write or an alarm ack over the wire.** The access
  spec requires every hand-made write recorded, and the audit trail page
  therefore cannot show plant writes. Needs a decision first: the app's guard
  already mints an `actionId` in gateway mode while `RemoteStateMan` mints a
  separate `cmd`, so recording on both sides makes one operator action two
  row sets under two ids. Decide the id, then build.
- **Tag bindings refresh only on the token-file poll** (`bin/main.dart`), and
  should load before `server.start()` and fail closed if that first load
  fails.

### Tier 2 — features with NO wire path at all

These are the real feature gaps. Each needs a protocol family, a backend
implementation, a `relayed_*` client store, and an e2e case.

| Feature | Evidence | What a relayed panel gets today |
|---|---|---|
| **Reports** | no `report*` method on the wire; `guarded_report_store.dart` has no `relayed_` twin | the editor opens and lists nothing; a report the backend holds is invisible |
| **Knowledge base** | no `knowledge*` method; `guarded_knowledge_stores.dart` has no twin | the library says it cannot be reached |
| **Configuration history** | no `configHistory*` method; the gateway answers method-not-found | the page cannot show the plant's own config history |

All three are already pinned by cases in `test/e2e_pages/` — two as
`knownRed`, one as a passing assertion that the method is absent. When each is
built, those cases become the acceptance test.

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

### Step 0 — finish the inventory (half a day)
Answer the three questions for every remaining feature family, with
`file:line`. The method table, the `relayed_`/`guarded_` split and the
`databaseProvider` consumer list are the three inputs; the output is this
document's Tier 2 and Tier 3 made complete. **Do this before building
anything** — the point of the exercise is that nobody has to enumerate
features by hand later either.

### Step 1 — triage the five untriaged page cases (half a day)
They are the cheapest source of new Tier 2 entries. Each is either a defect
(convert to `knownRed` with a named reason) or a fixture bug (fix it). Then
add the CI job the lane is deliberately missing: it has none today because a
lane whose failures nobody has read is not evidence.

### Step 2 — build the three missing families (the bulk)
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

### Step 3 — close the audit gap (after the id decision)
Decide one action id, then record tag writes and alarm acks on the wire, and
turn the three audit-trail `knownRed` cases live.

### Step 4 — make coverage self-checking
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
