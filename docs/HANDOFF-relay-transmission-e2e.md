# Handoff — `relay-transmission-e2e`

Worktree `/Users/jonb/Projects/tfc-hmi-worktrees/relay-transmission-e2e`,
branched off `origin/feat/relay-pipe` (PR #463). 33 commits, tree clean.
Nothing pushed; no PR opened.

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

## Outstanding, in order

1. **PLC owns the momentary latch** (ruled 2026-09-20, Jón). Not this
   branch's work. What this branch owes when it lands: one e2e per asset —
   press, kill the link, assert the bit falls at the node. **The
   `ConveyorGate` pusher and Festo VTUG coil FBs were never read**; only
   `FB_MButton` (safe, self-clearing) and `FB_ATV320` (latches) were. Read the
   plan's Tier 1 for the catch about comms watchdogs under the relay.
2. ~~Five untriaged page cases~~ — **done 2026-09-20.** All five run down:
   one product defect (`page_editor.dart` `setState` after dispose, fixed),
   three fixture faults (a green case seeded by a `knownRed` one; a finder on
   a title that is never rendered; a page bounded by a clock `testWidgets`
   freezes), and one that was never a failure — it only fails under the wrong
   Flutter SDK. Each case's story is in the file's own doc.

   The `knownRed` set had never been run either, and running it found **two of
   fifteen already green** — the history-view read floor this branch fixed,
   and `browse.fetchDetail` against a forged node kind, whose case demanded
   the wrong remedy (a refusal, where the shipped fix answers as for a node
   that does not exist — a refusal would confirm the node is there). Both are
   ordinary cases now.

   The lane is green at **35 pass / 13 known-red** and has a CI job,
   `e2e-pages-test`, which runs the gated set too and **fails if a known-red
   case passes** — that is how the two above would have been caught the day
   their fixes landed rather than months later.

   **It surfaced one new finding, below.**
3. **Panel-vs-station confusions** (plan Tier 1b) — IP settings and station
   operations act on the *panel's* NetworkManager when relayed. An afternoon
   to make honest; highest safety-per-hour in the document.
4. **Six dark families** — reports, knowledge base, config history,
   page-editor save, config-store sync, chat/MCP. One null darkens them all:
   `lib/providers/database.dart:50-52`.
5. **Audit rows for tag writes** — needs the one-action-id decision first, or
   one operator action becomes two row sets under two ids.
6. **Tag bindings refresh** runs only on the token-file poll; should load
   before `server.start()` and fail closed on a failed first load.

---

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
```
cd packages/tfc_relay_local && dart test --exclude-tags "db || soak"
CENTROIDX_E2E_ASSETS=1 flutter test test/e2e_assets/ --concurrency=1
CENTROIDX_E2E_PAGES=1  flutter test test/e2e_pages   --concurrency=1   # needs docker
```
