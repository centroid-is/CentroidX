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
2. **Five untriaged page cases** in `test/e2e_pages/` — never passed, never
   diagnosed, deliberately *not* marked `knownRed` because nobody established
   whether they are defects or unfinished fixtures. The lane has **no CI job**
   for that reason. Triage first; it may move items into the gap list.
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
