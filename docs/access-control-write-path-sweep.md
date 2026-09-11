# Write-path sweep — every path from Dart code to a persistent store

## 1. What this is, and why it exists

`docs/access-control-spec.md` §6 lists the write paths that reach a store
without passing `StateMan.write` or `PreferencesApi.set*` — the two interfaces
the Phase 3 guards wrap. It was written as three. A fourth of exactly the same
shape, the history view's Drift deletes, had been sitting in the tree the whole
time and was found during Phase 2 only because somebody read the ungated-routes
list and checked one claim. §6 is now amended to four and says outright: assume
there is a fifth. A guard beside an unenumerated hole is the decorative outcome
§6 exists to prevent, and this phase's failure mode is the silent one — a guard
that misses a write path looks identical to one that covers it, from every
screen, forever.

This document is the enumeration, and the verdict for each site. It is
reproducible: **`bash scripts/sweep-write-paths.sh`** from the repository root
re-runs every search and prints the same list. That script is a report, not a
gate; plan 03-11 turns a subset of its section 4 into a CI check, and plan 03-12
re-runs the whole thing and asserts every hit still has a row here. Sites are
matched by **file and call**, not by line number — line numbers move on every
edit, and a check that fails on reformatting gets deleted rather than fixed.

**Sweep run: 2026-08-29**, over `lib`, `centroid-hmi/lib`, `demo` and
`packages/*/lib`, excluding `test`, `build` and `.dart_tool`.
**Re-run: 2026-08-30** by plan 03-12, against the tree seven plans later. The
per-section hit counts in the headings below carry both numbers where they
differ; every new hit has a row, one row was found to have been missing since
the first run (§4.1 F), and no row was left stale. From that re-run onwards the
comparison is a test — `test/core/phase_03_coverage_test.dart` runs the script
and reconciles its hits against this document's table rows in **both**
directions, by file, so a write path added after today fails a suite rather
than waiting to be read about. **Only the tables of §2 and §3 count as rows
for that comparison** (narrowed 2026-09-07): a run record in §4.3 and a key
reconciliation in §5 are records of measurements, not verdicts, and a full
path appearing in one must not discharge the obligation to give that file a
verdict — with every `|` row counted, deleting a file's real §2 row could
leave the gate green because §4.3a's table still named it, which is this
document's own decorative-outcome defect pointed at itself. A §4.3 section
may therefore name files however reads best; nothing it says can satisfy the
gate. The script's own
header records its two output conventions: comment-only lines are dropped (a
comment is not a call, which is why `centroid-hmi/lib/main.dart:449` quoting
`adb.deleteHistoryView` in a note is not a site), and hits inside generated
files are collapsed to a counted line per file rather than listed. Both are
limits on the search and both are restated in §6 below.

**Re-run: 2026-09-05** against the relay branch, and this one is different in
kind from the first two. Both of those swept one program: a Flutter app whose
writes start at a widget, travel through a provider and end at a store, with a
route gate or a decorator somewhere in between. The relay packages
(`tfc_relay_client`, `tfc_relay_local`, `tfc_relay_protocol`,
`tfc_relay_server`, `tfc_stateman_contract`) are **not that program**. They are
a separate Dart backend and its client half, and the repository root's
`pubspec.yaml` names none of them — the app links `tfc_dart`,
`tfc_mcp_server`, `jbtm` and `tfc_access`, and nothing under `lib/`,
`centroid-hmi/lib/` or `demo/` imports a relay package at all. The script
sweeps them because its roots are `packages/*/lib`, which is correct: a write
path is a write path whichever process runs it.

Seventeen files came back with no row. Every one is in those five packages, and
**the reason none of them had a verdict is that the vocabulary had no term for
what guards them.** The relay's writes are not reached from a widget on a
route; they arrive over a WebSocket, from a session whose token was exchanged
for an `Identity{stationId, role}`, and are refused by the relay's own policy
decorator before they reach a store. That is a guard, and calling it
`not widget-reachable` would have been true-sounding and wrong — it would have
filed a live, remotely reachable DELETE beside a drift `Migrator` callback. §2
gains two terms rather than stretching one, §3.12 tells the relay's guard model
once, and §4.5 records what the run found.

**Re-run: 2026-09-07** by the coverage test's own reconciliation, against the
backend milestone's tree. Five files carried hits with no row, fifty hits
between them, and no new verdict term is needed: three are
`packages/tfc_dart/lib/core/relay/` — the **centroidx-backend**, a second
server-side composition served through the very same `PolicyStateMan` §3.12
describes — and two are the app's gateway-mode side. §4.3c records the run.
The largest fact in it is again a negative — no unguarded write path — with
one nuance worth reading before trusting it: the alarm acknowledge is gated by
`canWrite` at the handler rather than `requireOperate` in the decorator. Same
policy object, same fail-closed answer; the §2.2 row for
`backend_alarm_history.dart:335` spells out why that is a property and not a
gap.

**Same-day addendum (2026-09-07):** plan 17-06 landed
`packages/tfc_dart/lib/core/relay/backend_access.dart` — the backend's three
access families over the very store classes 17-02 moved — after that re-run's
tables were written, and the gate went red exactly as designed: six hits, no
row, plus a new hit in the already-rowed `backend_composition.dart` (`:369`,
the audit family's construction). The rows are in §2.2 and §2.3, and the
finding compresses to one sentence: **nothing in that file is reachable from a
connected client today**, because `PolicyStateMan` refuses all four access
families wholesale (`_noAccessGate`) until 17-07 grades them, only the
sessionless read-only audit family is even constructed until 17-09 mints
templates and admin per verified identity, and the gates the file must not
duplicate — `users` plus an audit row — live inside the stores it delegates
to, exactly where the panel's direct mode already exercises them.

**The answer to "is there a fifth?" is yes**, and it is in §4. The largest new
finding is a family the spec never mentions: three raw-Drift index classes in
`packages/tfc_mcp_server`, called directly from the Knowledge Base page, which
Phase 2 deliberately left ungated because it reads as a read surface. Plans
03-13 and 03-14 close it at the controls and at the route; §3.1 records both,
and the operational cost of the second.

---

## 2. The table

The verdict vocabulary is fixed at **seven** terms. Every row carries exactly
one; no row is blank and no row says "probably".

| Verdict | Meaning |
|---|---|
| `guarded by NN-NN` | a plan routes it through a guard. `03-NN` for the plans in this phase; one later row carries `06-03`, which closed §3.3 |
| `route-gated (Phase 2)` | reachable only from a route in `kRaisedRoutes` |
| `session-gated (relay policy)` | reached over the relay's WebSocket, and refused by `PolicyStateMan` (`packages/tfc_relay_server/lib/src/policy/policy_state_man.dart`) unless the session's `AccessSession` holds the `AccessGroup` the master `AccessPolicy` requires for that surface — the same question the app's guards ask, of the same policy object. Since Phase 17 (17-07/17-09/17-11) this is one enforcement point consuming the one master system, not a second policy; §3.12 records how it came to agree. Every row carrying this verdict keeps it — the redefinition is a change of wording, not of which rows are gated, and no row needs re-verdicting. The row says which member is gated and which is deliberately not |
| `not widget-reachable` | provider or core machinery with no path from a widget; the row says which and why the claim holds |
| `test-kit only (dev dependency)` | in `packages/tfc_stateman_contract`, which every package that uses it names under `dev_dependencies` and which no production `lib/` in the repository imports. Not compiled into the app or into the gateway. The row still says what the call would write, so the claim is checkable rather than a category |
| `correct as-is` | the audit sink, the guards themselves, and the stores' own declarations |
| `left open: <reason>` | found, understood, and deliberately not closed |

**Why two new terms rather than one, and why neither is a stretch of an old
one.** They make opposite kinds of statement, so one term cannot carry both.
`session-gated (relay policy)` says *a guard exists and here it is* — the row
points at a check the reader can go and read. `test-kit only (dev dependency)`
says *this code is not in any shipped binary* — a claim about the dependency
graph, not about a guard. Filing either under `not widget-reachable` would have
been literally true and materially false: nothing in the relay is
widget-reachable, so that verdict would have absorbed the whole of five
packages and said nothing about any of them, including the DELETE that a
connected client can reach in one call.

Where a file carries many calls of one shape, the row names the shape and lists
the lines, because that is how plan 03-12 compares — by file and call.

### 2.1 Named Drift write helpers on `AppDatabase` (script §1 — 44 hits at the 2026-08-29 run, 54 at the 2026-08-30 re-run, 111 at the 2026-09-05 re-run, 135 at the 2026-09-07 re-run)

The ten new hits are plan 03-10's guard, which declares the same five method
names and delegates to them. That is the shape a guard has, and it is why the
count going **up** is the expected outcome of closing a bypass rather than a
regression.

Fifty-five of the fifty-seven further hits at the 2026-09-05 run are the same
five method names travelling the length of the relay — declared once on the
wire interface, called once by the client's proxy, served once by the gateway's
handlers, decorated once by the policy, implemented once against the database,
and reproduced four times over by the contract kit. The other two are new lines
in files this section already rowed.

**Nine rows, and the first five of them are one method chain rather than five
write paths.** A `history.deleteView` frame reaches exactly one `DELETE`:
`client_sub_apis` sends it, `data_handlers` receives it, `policy_state_man`
decides it, `history_view_store` executes it, and `state_man_api` only declares
that the method exists. The rows say where in that chain each file sits, so a
reader is not left counting five deletes where there is one. The last four are
the contract kit, which is a different claim entirely.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/history_view.dart:1155` | `store.deleteHistoryView(v.id)` | `history_view` + cascades | delete-view button on `/advanced/history-view` (**not** raised) | `guarded by 03-10` |
| `lib/pages/history_view.dart:1192` | `store.addHistoryViewPeriod(...)` | `history_view_period` | save-period control on the same page | `guarded by 03-10` |
| `lib/pages/history_view.dart:1237` | `store.deleteHistoryViewPeriod(p.id)` | `history_view_period` | delete-period button | `guarded by 03-10` |
| `lib/pages/history_view.dart:1359` | `store.createHistoryView(...)` | `history_view` | save-as control | `guarded by 03-10` |
| `lib/pages/history_view.dart:1411` | `store.updateHistoryView(...)` | `history_view` | save control | `guarded by 03-10` |
| `lib/core/guarded_history_views.dart:127-179` | the same five names on `HistoryViewStore`, each delegating to `_db.<name>` | `history_view`, `history_view_period` | `historyViewStoreProvider`, from the five controls above | `correct as-is` — this **is** the guard; the check and the row happen here and the delegation below them |
| `packages/tfc_dart/lib/core/database_drift.dart:698, 742, 785, 845, 855, 898, 1116` | the seven method **declarations** | — | — | `correct as-is` (this is the API section 1 searches for; declaring it is not calling it) |
| `packages/tfc_dart/lib/core/database_drift.dart:424-427, 466-476, 506-508` | `m.createTable(<table>)` | schema | drift `Migrator` inside `onUpgrade`/`onCreate` | `not widget-reachable` — a different method of the same name on `Migrator`, called only by drift's migration callback at database open |
| `packages/tfc_mcp_server/lib/src/database/server_database.dart:356-397` | `m.createTable(<table>)` | schema | same, for the MCP server's own database | `not widget-reachable` — same reason |
| `packages/tfc_dart/lib/core/database.dart:930` | `db.updateRetentionPolicy(tableName, retention)` | timescale policy | `Database._applyRetentionPolicy` ← `registerRetentionPolicy` ← `Collector` (`collector.dart:216`) | `not widget-reachable` — no widget calls it; the widget-reachable input is the `collector_config` key, which `03-09` guards |
| `packages/tfc_dart/lib/core/database.dart:1715, 1738` | `db.createTable(tableName, ...)` | timeseries tables | `Database` creating a table on first insert | `not widget-reachable` — driven by a sample arriving, not by a control |
| `packages/tfc_relay_protocol/lib/src/state_man_api.dart:321, 326, 331, 347, 351` | the five history-view mutators, **declared** on `HistoryViewApi` | — | — | `correct as-is` — an interface declaration, the same shape as `database_drift.dart`'s seven above and `operations.dart:88` below: declaring a method is not calling one. It is the file's own stated rule that "a method that exists is a thing any connected client may invoke, so adding one is an access-control decision", and `api_surface_test.dart` fails when this file grows or shrinks — which is a **surface** control, not a guard, and the row says so rather than banking it as one |
| `packages/tfc_relay_server/lib/src/policy/policy_state_man.dart:739-743, 750-755, 811-813, 850-853, 858-860` | the five names on `_PolicyHistoryViews`, each delegating to `_source.<name>` | `history_view`, `history_view_period` | every `history.*` frame on the wire, through `DataHandlers` | `correct as-is` — this **is** the relay's guard, and the row is here for the same reason `guarded_history_views.dart`'s is: the check and the delegation happen in this file. `updateHistoryView`, `deleteHistoryView`, `addHistoryViewPeriod` and `deleteHistoryViewPeriod` each call `requireOperate(...)` before delegating; `createHistoryView` deliberately does not, and §3.12 carries that asymmetry rather than leaving it implied by a row |
| `packages/tfc_relay_server/lib/src/data_handlers.dart:440, 455, 474, 552, 559` | `source.historyViews.<name>(...)` | `history_view`, `history_view_period` | the `history.createView` / `updateView` / `deleteView` / `addPeriod` / `deletePeriod` methods, registered on the session's peer | `session-gated (relay policy)` — `source` is the session's `PolicyStateMan`, never the shared plant (`relay_session.dart` builds `DataHandlers(source: api, …)` where `api` is the decorator), so there is no unwrapped source in scope for a handler to reach around. Every registration also passes `RelaySession._on`, which applies the pre-`hello` handshake gate |
| `packages/tfc_relay_local/lib/src/data/history_view_store.dart:95-99, 104-112, 140-142, 211-221, 225-226` | the five names on `HistoryViewStore`, each reaching `database().db.<name>` | `history_view`, `history_view_period` | `_PolicyHistoryViews`, from the five handlers above | `session-gated (relay policy)` — the store the relay's guard delegates through, and the row is here rather than at `correct as-is` on purpose: these rows are the **same four tables** `lib/pages/history_view.dart` writes through `03-10`'s guard, so a reader arriving at this file needs to be told which of the two guards stands above it. This one. Reached only from the policy decorator, which is reached only from a gated handler |
| `packages/tfc_relay_client/lib/src/client_sub_apis.dart:275, 288, 301, 336, 347` | the five names on the client's `HistoryViewApi` proxy | **no store in this process** | a Flutter client of the gateway — which is nothing in this repository today | `session-gated (relay policy)` — the far end is the enforcement. Each of these sends one JSON-RPC request and awaits one answer; the store, and the `requireOperate` above it, are in the gateway. Worth stating because the verdict looks generous otherwise: a client-side method call cannot write what the gateway's policy refuses, and the refusal comes back as a `forbidden` the caller must handle |
| `lib/core/relayed_access_stores.dart:221, 226, 236` | `_api.create(...)`, `_api.update(...)`, `_api.delete(...)` on the relayed template proxy | **no store in this process** | `accessTemplateStoreProvider` / `accessAdminStoreProvider` / `auditTrailStoreProvider` in gateway mode, from the same key-repository and admin screens as the direct stores | `session-gated (relay policy)` — the far end is the enforcement, the same verdict and the same reason as `client_sub_apis.dart` above: these `.update(`/`.delete(` calls are on an `AccessTemplateApi`, not an `AppDatabase`, and each becomes one JSON-RPC request whose `users` gate and audit row live above the backend's own store. Added 2026-09-08 by plan 17-12, which routed the three access stores and the audit sink through the pipe when the transport is a WebSocket, so criterion ACCESS-01 works with Postgres unreachable. A `forbidden` comes back as the same `AccessDenied` a direct refusal throws, and a domain error (`template_in_use` etc.) keeps its `tfc_dart` type — mapped in this file, since the client package may not import `tfc_dart` |
| `lib/core/relayed_preferences.dart:415-500` | the five `set*` names, `remove` and `clear` on `RelayedPreferences`, each routed either to `api.<name>(...)` on the client's `PreferencesApi` proxy or to `_inner.<name>(...)` on this station's own store | **no store in this process** for the wire arm; the device-local store for the local arm | `preferencesProvider` in gateway mode, from every configuration screen in the app — the alarm editor via `RelayAlarmSource._saveConfig` being the one this file was written for | `session-gated (relay policy)` for the wire arm — the same verdict and the same reason as `relayed_access_stores.dart` above: each call becomes one JSON-RPC request whose per-key `AccessPolicy.groupForPref` gate and audit row are applied by `_PolicyPreferences` above the backend's own store, and a `forbidden` returns as the `AccessDenied` the direct path throws. `device-local by construction` for the local arm — it is reached only for a `secret: true` call (which goes to the OS keychain, never to any table), for a key named in `device_local_preferences.dart`, or for the one bootstrap key `key_mappings` while the relay client is still being built; none of the three reaches a shared table on this transport. Added 2026-09-09, which routed the shared configuration store through the pipe so an alarm rule edited on a gateway panel reaches the plant instead of that panel's own mirror |
| `packages/tfc_stateman_contract/lib/src/channel/channel_sub_apis.dart:248, 261, 274, 309, 320` | the same five, over the harness channel | — | the contract suite's client side | `test-kit only (dev dependency)` — `client_sub_apis.dart` above is this file "ported method for method", and the port is the shipping one. This copy speaks `harness.`-prefixed method names to `served_state_man.dart` and never to a gateway |
| `packages/tfc_stateman_contract/lib/src/channel/served_state_man.dart:558, 567, 579, 609, 618` | `api.historyViews.<name>(...)` | whatever the suite pointed it at | the contract suite's server side | `test-kit only (dev dependency)` — the harness peer, and `data_handlers.dart`'s library doc names it as the thing the gateway deliberately **copied rather than imported**: `handler_table_test.dart` sweeps `tfc_relay_server`'s production `lib/` for this package's name and requires zero hits, "because a gateway that imported its test kit at runtime would ship the fake plant, the seeding levers and the fault injectors into the plant". The duplication is the control |
| `packages/tfc_stateman_contract/lib/src/data_services_contract.dart:261, 314, 334, 339, 368` | `views.createHistoryView(...)`, `.addHistoryViewPeriod(...)`, `.deleteHistoryView*(...)` | whatever implementation the suite is run against | the shared contract suite, run by `dart test` in five packages | `test-kit only (dev dependency)` — these are **assertions**, not a program: the suite is in `lib/` rather than `test/` precisely so five packages' tests can import it, which is also why `test: ^1.25.0` is a runtime dependency of that package and of no other. Against a real database it writes real rows, and that is what a contract suite is for |
| `packages/tfc_stateman_contract/lib/testing/fake_data_services.dart:367, 379, 400, 426, 441` | the five names on the in-memory fake | **no store at all** — three `Map`s | the contract suite, and the packages' own fixtures | `test-kit only (dev dependency)` — an in-memory reference implementation, "not a mock": the view delete cascades because the suite asserts that it does. Nothing here opens a connection |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:560, 564, 568, 578, 581` | the five history-view mutators, **declared** on `HistoryViewSource` | — | — | `correct as-is` — an interface declaration, the same shape as `state_man_api.dart`'s five above: the seam where the drift layer's generated rows are mapped onto the protocol's plain records, and declaring a method is not calling one |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:595-641` | the five mutators (and six reads) on `DatabaseHistoryViewSource`, each delegating to `database.<name>` | `history_view`, `history_view_period` | `BackendHistoryViews`, one row below | `session-gated (relay policy)` — the **centroidx-backend's** history-view store, the same claim `tfc_relay_local`'s `history_view_store.dart` makes above and true by the same construction: `composeBackendRelay` (`backend_composition.dart`) hands the assembled `BackendStateMan` to `RelayServer`, and every session wraps it in `PolicyStateMan` before any handler sees it (`relay_session.dart:367`, `:908`) — there is no unwrapped source in scope for a handler to reach around |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:688-707, 772-779` | the five mutators on `BackendHistoryViews`, the backend's `HistoryViewApi` | `history_view`, `history_view_period` | `_PolicyHistoryViews`, through `DataHandlers`, from the five `history.*` frames | `session-gated (relay policy)` — four of the five stand behind `requireOperate` in the decorator above; `createHistoryView` reaches this file with **no** gate, which is §3.12's recorded decision and not this row's discovery. `maxRows` here bounds what the caller-grown tables can be read back at, not what they can grow to — the volume half of §3.12 point 3 is as true of this composition as of the gateway's |

**Both accessors were present, and both moved.** At the first run `:1108` used
`adb` and `:1165` used `dbWrap.db`; the script found both because section 1
searches the *method names*, not a receiver spelling — the exact mistake
`.planning/phases/02-route-gating/deferred-items.md` §4 names. Spec §6 listed
two of these five; all five were here, and plan 03-10 moved all five onto
`store.`, which is why every line number in this block changed between the two
runs and none of the calls did. **This is the reason the reconciliation is by
file and call rather than by line.**

### 2.2 Raw Drift statement API (script §2 — 116 hits at the 2026-08-29 run, 113 at the 2026-08-30 re-run, 144 at the 2026-09-05 re-run, 152 at the 2026-09-07 re-run, 154 after 17-06 landed later the same day)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/core/server_config_db.dart:58` | `db.into(db.flutterPreferences).insertOnConflictUpdate(...)` | `flutter_preferences` | `ServerConfigDb.publish()` ← `lib/pages/server_config.dart:3224` | `guarded by 03-08` |
| `lib/core/server_config_db.dart:85-87` | `(db.delete(db.flutterPreferences)..where(...)).go()` | `flutter_preferences` | `ServerConfigDb.remove()` | `guarded by 03-08` |
| `packages/tfc_dart/lib/core/access/drift_audit_sink.dart:75` | `_db.into(_db.auditEntry).insert(...)` | `audit_entry` | `auditSinkProvider` (`lib/providers/access.dart:104`) | `correct as-is` — append-only and retention-exempt by design; the class doc explains why, and this sweep does not restate it |
| `packages/tfc_mcp_server/lib/src/services/drift_tech_doc_index.dart:65, 230-236, 242, 251-253, 260, 306, 322` | `_db.into(...)`, `_db.delete(...)`, `_db.update(...)` | tech-doc tables | **`lib/tech_docs/tech_doc_upload_service.dart:104, 149, 221-222, 275`**, wired at `lib/providers/tech_doc.dart`, driven by the Knowledge Base page | `guarded by 03-13`, and `route-gated (03-14)` besides — see §3.1 |
| `packages/tfc_mcp_server/lib/src/services/drift_plc_code_index.dart:84, 102, 121, 154, 169, 189, 257-276, 565` | `_db.into(...)`, `_db.delete(...)`, `_db.update(...)` | PLC index tables | **`lib/tech_docs/tech_doc_library_section.dart:1075` (`reindexAsset`) and `:1133` (`deleteAssetIndex`)**, wired at `lib/providers/plc.dart:65` | `guarded by 03-13`, and `route-gated (03-14)` besides — see §3.1 |
| `packages/tfc_mcp_server/lib/src/services/drift_drawing_index.dart:56, 68, 89-97, 219, 232` | `_db.into(...)`, `_db.delete(...)` | drawing tables | `lib/drawings/drawing_upload_service.dart:46, 61, 75`, wired at `lib/providers/drawing.dart:14`; `DrawingUploadDialog` has **no caller in the tree today** | `guarded by 03-13` — reachable in principle, unwired in fact, and guarded either way; the route it would be reached from is `route-gated (03-14)`. See §3.1 |
| `packages/tfc_mcp_server/lib/src/audit/audit_log_service.dart:47, 85` | `_db.into(_auditLog).insert(...)`, `_db.update(_auditLog)` | `audit_log` (MCP's own) | `TfcMcpServer`, which runs **in the HMI process** (`lib/mcp/mcp_bridge_notifier.dart:266`, `lib/mcp/mcp_sse_server.dart:56`) | `left open: reached over MCP, not from a widget` — see §3.2 |
| `packages/tfc_dart/lib/core/access/access_template_store.dart:286, 324, 383, 439-441, 498, 531-533` | `_db.into(...).insert` / `.insertOnConflictUpdate`, `_db.update(...)`, `_db.delete(...)` on the two v7 tables | `access_template`, `access_key_binding` | `AccessTemplateStore`, driven by the key repository (04-07, 04-08) and by accepted MCP proposals (04-09) | `correct as-is` — this **is** the guard; `kAccessTemplateGroup` (`users`) is checked and the audit row written above every one of these, over **both** tables. The binding lives in its own table rather than in the `configure`-gated key-mapping blob precisely so the gate is true of the data (ruled 2026-08-30, reversing spec §7b). **Re-pathed 2026-09-07 by plan 17-02** from `lib/core/access_template_store.dart`: the file moved into `tfc_dart` so the backend serves the same class the panel calls, and the verdict is unchanged because the guard, the gate and the audit row all moved with it — the eight line numbers above did not move either, which is the evidence the bodies were not touched. The app keeps a one-line `export` at the old path, and that export file reaches no store, so it has no row of its own and must not gain one |
| `lib/pages/access_templates_section.dart:635, 1130` | `store.update(...)`, `store.delete(...)` | `access_template` | `AccessTemplatesSection`, mounted in `KeyRepositoryContent` (04-07) | `correct as-is` — these are calls **on `AccessTemplateStore`**, one row above, not on a database: the `users` gate and the audit row are inside them. Caught by the deliberately broad `.update(`/`.delete(` grep and recorded rather than filtered away, which is the point of the grep being broad. The section writes no binding at all — `bind`/`unbind` are 04-08's, per key |
| `packages/tfc_dart/lib/core/access/access_repository.dart:358, 373, 412, 545, 552-554, 590, 645, 722, 754-755, 781, 814` | `db.into/update/delete` on `app_role` / `app_user` | roles and users | `accessAdminStoreProvider` (06-04), which wraps `accessRepositoryProvider`; and `lib/pages/first_user.dart:141` for the first-user window alone | `guarded by 06-03` — `AccessAdminStore` asks `kAccessAdminGroup` (`users`) and writes a row, refusals included, above every one of the eight writes that reach these statements. The repository is not decorated: it owns the transaction and the last-`users`-holder invariant that must be evaluated inside it — see §3.3 |
| `packages/tfc_dart/lib/core/preferences.dart:210, 254, 428` | `secureStorage.delete(key:)`, `db.customInsert(...)`, `database!.db.customUpdate(...)` | secure store, `flutter_preferences` | inside `Preferences` — the implementation `GuardedPreferences` wraps | `correct as-is` — these are the store the guard decorates; the check happens above them |
| `lib/core/preferences.dart:54-84` | `_prefs.setBool/setInt/setDouble/setString/setStringList/remove/clear` | device-local | `SharedPreferencesWrapper implements PreferencesApi` | `correct as-is` — pure delegation with the caller's key |
| `packages/tfc_dart/lib/core/database_drift.dart:374, 394, 444-527, 702-790, 847-856, 907, 990-1007, 1127-1317` | `into(...)`, `delete(...)`, `customStatement`, `customInsert` | every table | the database's own methods and migrations | `correct as-is` — this file *is* the store |
| `packages/tfc_dart/lib/core/database.dart:1127, 1647-1656` | `db.customStatement(...)` | timeseries DDL | `Database` table management | `not widget-reachable` — DDL run when a table is created or repaired, not from a control |
| `packages/tfc_dart/lib/core/alarm.dart:341` | `db.customInsert(r'''...''')` | alarm history | `AlarmMan` recording an alarm transition | `not widget-reachable` — driven by a PLC transition; the operator-facing ack path writes nothing here |
| `packages/tfc_mcp_server/lib/src/database/server_database.dart:376-389` | `customStatement(...)` | schema | migration callback | `not widget-reachable` — same as 2.1 |
| `lib/core/secure_storage/macos.dart:123, 152, 172`, `lib/core/secure_storage/other.dart:29`, `packages/tfc_dart/lib/core/secure_storage/linux.dart:52` | `_storage.delete(key:)` / `_legacy.delete(key:)` | OS keychain | the `MySecureStorage` implementations | `left open: secure storage is outside both guards` — see §3.4 |
| `lib/pages/ip_settings.dart:408, 1127` | `connection.delete()`, `connection.update(updatedSettings)` | NetworkManager | `/advanced/ip-settings` | `route-gated (Phase 2)` — `kRaisedRoutes` raises it to `administer` |
| `lib/pages/ip_settings.dart:588` | `_tracker.update(...)` | — | in-memory traffic-rate tracker | `not widget-reachable` — not a store; a false positive of a deliberately broad grep, recorded rather than filtered away |
| `lib/pages/page_editor.dart:3706` | `counts.update(asset.displayName, ...)` | — | an in-memory tally of asset kinds, for a label | `not widget-reachable` — not a store; the same broad-grep false positive as the row above. The editor's real persistence is `PageManager`, rowed in §2.9 |
| `packages/centroidx_upgrader/lib/src/manager_launcher.dart:170` | `staged.delete()` | filesystem | cleanup of a failed staging write; see 2.7 | `left open: the update path is ungated` — see §3.5 |
| `packages/tfc_dart/lib/core/state_man.dart:2175` | `wrapper.client.delete()` | — | OPC UA client teardown | `not widget-reachable` — not a store; disposes a connection |
| `packages/tfc_relay_local/lib/src/data/preference_store.dart:517` | `db.db.customUpdate('DELETE FROM flutter_preferences WHERE key IN (…)', updateKind: UpdateKind.delete)` | `flutter_preferences` | `PreferenceStore.clear(allowList:)` ← `_PolicyPreferences.clear` ← the `preferences.clear` handler | `session-gated (relay policy)` — and the **only** raw Drift write anywhere in the relay. The statement is parameterised (`Variable.withString` per key, placeholders never interpolation), the key list comes from `getKeys(allowList:)` rather than from the client, and an *unrestricted* clear is refused outright above it (`policy_state_man.dart`, 10-REVIEW CR-02) because `key_mappings` is 518 KiB of routing nothing else on the wire can restore. The allow-listed form still takes `operate` |
| `packages/tfc_relay_local/lib/src/opcua_upstream_link.dart:746, 1427` | `await client.delete()` | — | disposing an `open62541` client whose creation raced a dispose | `not widget-reachable` — not a store; the same call and the same reason as `state_man.dart:2175` one row above. An undeleted client is a live worker isolate, so the call is a leak fix, not a write |
| `packages/tfc_relay_local/lib/src/collect/collection_runner.dart:449` | `_health.update(rowsWritten:, rowsDropped:, rowsQueued:, lastError:)` | — | the collector's insert path refreshing six health keys | `not widget-reachable` — not a store; `_health` is a `CollectHealth` (`pipe_health.dart:326`) which publishes into the in-memory `ValueStore` the pipe serves. A false positive of the deliberately broad `.update(` grep, recorded rather than filtered away, exactly as `ip_settings.dart:588`'s `_tracker.update(...)` is |
| `packages/tfc_relay_local/lib/src/data/collection_plan_resolver.dart:111` | `claimed.update(identifier, (_) => null, ifAbsent: …)` | — | a local `Map<String, String?>` counting duplicate OPC UA identifiers | `not widget-reachable` — not a store; the same broad-grep false positive as `page_editor.dart:3706`'s `counts.update(...)`. The map is built and discarded inside one constructor body |
| `packages/tfc_stateman_contract/lib/src/faults/os_level.dart:535` | `directory.delete(recursive: true)` | filesystem | the teardown of the macOS dummynet fault injector | `test-kit only (dev dependency)` — removes the temp directory `:468` created; see 2.7 for the write that put a file in it |
| `lib/core/gateway_link_status.dart:419` | `url.replace(userInfo: '')` | — | rendering the gateway URL on the link-status card | `not widget-reachable` — not a store; a false positive of the deliberately broad grep, and the first from its `replace(` pattern, which exists for drift's row-replacing `replace()` and here matched `Uri.replace` building a display string. Recorded rather than filtered away, exactly as `ip_settings.dart:588` is — and the line it caught is itself a control: the `userInfo` strip is what keeps a credential stored in a preferences row out of a photograph of a panel |
| `lib/widgets/gateway_identity_dialog.dart:62` | `gateway.replace(userInfo: '')` | — | rendering the gateway URL on the trust-approval dialog | `not widget-reachable` — not a store; the second catch of the `replace(` pattern's `Uri.replace` false positive, same call and same reason as `gateway_link_status.dart:419` one row above, and the same control: this dialog is the one-field flow's fingerprint ceremony, read across a shoulder at commissioning, and the strip keeps a credential typed into the URL out of it |
| `lib/widgets/config/state_man_config_editor.dart:2239, 2287, 2330` | `entry.update(edited)` | — | the unified config editor applying a card's typed edit onto its `ConfigEntry` | `not widget-reachable` — not a store; `ConfigEntry.update` is the minimal-diff merge onto the in-memory `ConfigDocument` (quick/20260908-unify-config-ui), the same broad-grep `.update(` false positive as `ip_settings.dart:588`. Persistence happens only at `ConfigSource.write` — the direct source's preference write is rowed in §2.9 (`lib/core/config_source.dart`), and the gateway source forwards to `BackendConfigApi.write`, graded `administer` server-side (17-10) |
| `packages/tfc_dart/lib/core/relay/backend_alarm_history.dart:335` | `db.customUpdate(acknowledgeStatement)` — stamps `acknowledged_at` on one open row, closing nothing | `alarm_history` | `Methods.ackAlarm` → `AlarmHandlers.acknowledge` → `BackendAlarmAckSink` → the engine's `_stampAcknowledged` (`backend_alarms.dart:1211`) | `session-gated (relay policy)` — and the gate deserves spelling out because it is **not** `requireOperate`: `AlarmHandlers.acknowledge` (`alarm_handlers.dart:122`) asks `canWriteKey(AlarmKeys.active)`, which `relay_session.dart:865` binds to the session's `PolicyStateMan.canWrite` — the same predicate a `write` is refused by, fail-closed on a null identity (`policy_state_man.dart:256-258`), `role == operate` under the shipped `AllVisibleOperatorWrites`. One policy object answers the ack and the write, so the two cannot drift (T-14-49); the refusal is pre-effect, at the handler, before the sink is touched |
| `packages/tfc_dart/lib/core/relay/backend_alarm_history_source.dart:112` | `database.select(database.alarmHistory)` — a READ, newest first, window bounded by overlap; writes nothing | `alarm_history` | `Methods.alarmHistory` → `AlarmHandlers.history` → `BackendAlarmHistorySource` | `session-gated (relay policy)` — the handler asks whether this session may SEE `AlarmKeys.active` before the source is touched, the same visibility answer every relayed read goes through, and `AlarmHistorySource`'s contract says an implementation "does not repeat that decision and must not soften it" — so this file deliberately carries no check of its own. Listed here even though it only reads, because the sweep enumerates what reaches the store and a read of somebody else's plant history is a disclosure question even when it is not a write |
| `packages/tfc_dart/lib/core/relay/backend_alarm_history.dart:359` | `db.customUpdate(pendingAckStatement)` | `alarm_history` | the alarm engine, when an `acknowledgeRequired` rule clears unseen (`backend_alarms.dart:1185`) | `not widget-reachable` — driven by a rule evaluation, the same claim and the same reason as `alarm.dart:341`'s row above; no wire method reaches it |
| `packages/tfc_dart/lib/core/relay/backend_alarm_history.dart:396` | `db.customUpdate(closeStatement)` | `alarm_history` | the engine's clear and restart-reconciliation paths (`backend_alarms.dart:589, 978, 1054`) | `not widget-reachable` — driven by rule transitions and boot reconciliation. One leg is wire-adjacent and the row says so rather than rounding it off: acknowledging an already-cleared alarm closes its row (`backend_alarms.dart:1152`), and that leg sits behind the same gated `ackAlarm` as the `:335` row — so every path to this statement is either a plant transition or a gated operator action |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:991` | `database.db.customUpdate('DELETE FROM flutter_preferences WHERE key IN (…)', updateKind: UpdateKind.delete)` | `flutter_preferences` | `PreferencesSource.deletePreferenceRows` ← `BackendPreferences.clear(allowList:)` ← `_PolicyPreferences.clear` | `session-gated (relay policy)` — the centroidx-backend's twin of `preference_store.dart:517`, and the same three controls hold: every key is a bound `Variable.withString` placeholder, the key list comes from `getKeys(allowList:)` rather than from the client, and the *unrestricted* clear is refused outright above it (`policy_state_man.dart:1075`, 10-REVIEW CR-02). The allow-listed form still takes `operate` for every key alike — §3.12's disagreement with `kPrefAccessRules`, over the same table |
| `packages/tfc_dart/lib/core/relay/backend_access.dart:152, 162` | `_require('update').update(value, origin: kRelayOrigin, reason: reason)` and `_require('delete').delete(name, origin: kRelayOrigin, reason: reason)` on `BackendAccessTemplates` | `access_template`, `access_key_binding` | nothing in the shipped graph today: `composeBackendRelay` constructs only the audit family (`backend_composition.dart:369`), `BackendStateMan` refuses `accessTemplates` **by name** until 17-09 constructs this class per minted identity, and `PolicyStateMan.accessTemplates` refuses wholesale (`_noAccessGate`, `policy_state_man.dart:373`) until 17-07 grades it | `correct as-is` — these are calls **on `AccessTemplateStore`**, the same claim as `access_templates_section.dart:635, 1130` above and true for the same reason: the `users` gate (`kAccessTemplateGroup`) and the audit row are inside the store, whose own §2.2 row carries the writes. This file maps and delegates and decides nothing — `backend_access_test.dart`'s arm 10 greps its source for permission-check tokens and requires zero, because a second gate here is what the phase's constitution forbids. The verdict is deliberately **not** `session-gated (relay policy)`: 17-07's wire grading is not written yet, and a row banking it early is the decorative outcome §6 forbids. What holds today is duller and stronger — no wire frame reaches this class at all, and when 17-09 does construct it, the gate that answers is the panel's own store gate, with `origin: 'relay'` on every row |
| `packages/tfc_relay_server/lib/src/access_handlers.dart:110, 124, 139` (and the eleven admin/config members beside them) | `source.accessTemplates.update(...)`, `.delete(...)`, `source.accessAdmin.<...>`, `source.backendConfig.write(...)` on the session's decorated `source` | `access_template`, `access_key_binding`, `app_role`, `app_user`, `audit_entry`, the `StateManConfig` file | the twenty-eight `AccessMethods.*` frames on the session's peer, registered through `RelaySession._on` (17-09) | `session-gated (relay policy)` — `source` is the session's `PolicyStateMan`, never the shared plant (`relay_session.dart` builds `AccessHandlers(source: api)` where `api` is the decorator), so every one of these delegates through the master-policy gate before touching a store. `access_handlers_test.dart` greps this file, comments stripped, for the vocabulary of a check and requires **zero** — the file decodes and delegates and decides nothing (17-09), and 17-14 reconciled its `value`/`role`/`query` decode envelope with the client's encoder (F-3). The deny row is written pre-effect by the decorator (D-05, `origin = 'relay'`) |
| `packages/tfc_stateman_contract/lib/src/access_contract.dart:217, 242, 310, 325` (and every gated member the suite drives) | `api.accessTemplates.create/update/delete(...)`, `api.accessAdmin.*`, `api.backendConfig.*` on the implementation under test | whatever the implementation under test writes — a `FakeAccessServices`'s maps in memory, or a real store behind the leg | `runAccessContract`, the shared judgement run against every leg (17-05) | `test-kit only (dev dependency)` — the access half of the contract kit, named under `dev_dependencies` by every package that runs it and imported by no production `lib/`. The calls exercise the four families' gating on whatever leg is under test; the gate that answers is the implementation's, never this file's. The row still says what the calls would write, so the claim is checkable rather than a category |

**Nothing further found** in this section beyond `server_config_db.dart`, the
three MCP index classes and the audit stores: every other hit is either the
store's own implementation, a migration, or a `.delete(`/`.update(` on
something that is not a database at all. **The 2026-09-05 re-run adds one
name to that first list and nothing to the argument**:
`preference_store.dart:517` is the relay's single raw statement, and the four
relay rows below it are three broad-grep false positives and a test kit's
temp-directory cleanup. **The 2026-09-07 re-run adds two more names**:
`backend_alarm_history.dart` — the first raw statements in the tree that write
`alarm_history` from anywhere but `AlarmMan`, one gated and two engine-driven —
and `backend_data_services.dart:991`, the second spelling of the parameterised
preference delete. `gateway_link_status.dart:419` joins the false-positive
family from a grep pattern that had never fired before. **17-06 adds one name
after that re-run's tables were written**: `backend_access.dart`, two hits,
both calls on the moved `AccessTemplateStore` rather than on a database — the
gate is the store's own, and the row above says why the relay vocabulary is
deliberately not claimed for it yet.

### 2.3 `AppDatabase` handles and the `.db` accessor (script §3 — 60 hits at the 2026-08-29 run, 55 at the 2026-08-30 re-run, 67 at the 2026-09-05 re-run, 74 at the 2026-09-07 re-run, 79 after 17-06 landed later the same day; plus 176 collapsed in `database_drift.g.dart` at the first two runs and 192 since)

This section exists to catch a *new accessor spelling* the first time it
appears. It found no handle that is not already covered by 2.1 or 2.2. Rows
here are therefore grouped by what the handle is used for.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/history_view.dart:90, 92` | `dbWrap.db` handed to `GuardedDatabaseHistoryViews` and to `HistoryViewStore` | `AppDatabase` | `historyViewsProvider` | `guarded by 03-10` — two lines, no statement of its own: the provider that hands the direct-mode surface its handle. **Rewritten 2026-09-09.** This row used to read `final adb = dbWrap.db` at four line numbers, and the row below it listed four reads reaching Drift directly. Both are gone: the six reads moved into `lib/core/relayed_history_views.dart` beside the five writes, because leaving them on a raw handle in the page is what let this page stay half database-shaped after 03-10 fixed the writes — and is what hid the gateway-mode hole, where `databaseProvider` is null by design and the picker answered an empty list |
| `lib/providers/database.dart:17-29` | `AppDatabase.spawn(config)`, `db.db.open()/close()` | connection lifecycle | `databaseProvider` | `not widget-reachable` — opens and closes the connection; writes nothing |
| `lib/providers/access.dart:71, 104` | `AccessRepository(db.db)`, `DriftAuditSink(db.db)` | handles | `accessRepositoryProvider`, `auditSinkProvider` | `correct as-is` — the audit sink is the one direct Drift write that is correct by design |
| `lib/providers/mcp_bridge.dart:210`, `lib/providers/chat.dart:998, 1182`, `lib/providers/server_database.dart:13` | `dbWrapper.db` as `McpDatabase` | handle | MCP bridge and chat | `left open: reached over MCP, not from a widget` — see §3.2 |
| `lib/pages/server_config.dart:3209, 3224, 3258` | `ServerConfigDb.fetch(db.db)` / `publish(db.db, ...)` | `flutter_preferences` | `/advanced/server-config` | `guarded by 03-08` — and `route-gated (Phase 2)` besides |
| `lib/core/timeseries_source.dart` | `database.db.enableNotificationChannel(...)`, `listenToChannel(...)`, `database.queryTimeseriesData*` | LISTEN/NOTIFY, timeseries reads | graph assets, the shared timeseries tracker, BPM / rate / ratio readouts | `not widget-reachable` as a write — `enableNotificationChannel` issues DDL for a notify channel, not a data write; the three query members are reads. **Re-pathed 2026-09-09** from `lib/page_creator/assets/graph.dart:823-824` and `lib/providers/timeseries.dart:205, 208`: both call sites moved behind `DatabaseTimeseriesSource`, the direct-mode half of the transport seam that lets a gateway panel read history over the relay instead of from a `databaseProvider` that is null by design. The verdict is unchanged, and it is now stated once rather than twice. Reads over the relay are filtered by `PolicyStateMan._PolicyTimeseries` rather than gated, on the same reasoning `timescale_reader.dart` gives below |
| `lib/widgets/panes/database_stats_pane.dart:74, 86` | `db.db.config`, `db.db.customSelect(...)` | reads | the database stats pane | `left open: read permissions are deferred` |
| `packages/tfc_dart/lib/core/preferences.dart:250, 465, 556`, `packages/tfc_dart/lib/core/preferences_watch.dart:59, 75, 77`, `packages/tfc_dart/lib/core/alarm.dart:338, 362`, `packages/tfc_dart/lib/core/database.dart:512-580`, `packages/tfc_dart/lib/core/access/access_repository.dart:98-100`, `packages/tfc_dart/lib/core/access/drift_audit_sink.dart:53` | `final db = ...!.db`, `AppDatabase db` fields | handles | core machinery | `correct as-is` — the stores holding their own handle |
| `lib/core/guarded_history_views.dart:85, 98` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `historyViewsProvider` | `correct as-is` — the handle 2.1's guard delegates through; the check happens above it |
| `lib/core/relayed_history_views.dart` | `required drift.AppDatabase database`, `final drift.AppDatabase _db`, `_db.selectHistoryViews/getHistoryViewKeys/getHistoryViewGraphs/getHistoryViewKeyNames/listHistoryViewPeriods/getGlobalRetentionHorizon` | reads | `historyViewsProvider`, direct mode | `left open: read permissions are deferred` — spec §11, the same verdict the `history_view.dart` read rows above carried before they moved here. **The six reads and only the six reads**: `GuardedDatabaseHistoryViews` holds the handle for reading and delegates all five writes to `HistoryViewStore`, which is where the check and the audit row are and where they stay — a read handle must not be able to borrow its way into a write. The file's other class, `RelayedHistoryViews`, names no database at all: in gateway mode the tables are the backend's and the check is `PolicyStateMan._PolicyHistoryViews`, asking the same `AccessPolicy.groupForHistoryView`. Same `_db` spelling as `HistoryViewStore`, so no ninth accessor |
| `packages/tfc_dart/lib/core/access/access_template_store.dart:163, 176` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `AccessTemplateStore` | `correct as-is` — the handle 2.2's guard delegates through; the check happens above it. Same `_db` spelling as `HistoryViewStore`, so no ninth accessor. **Re-pathed 2026-09-07 by plan 17-02** from `lib/core/access_template_store.dart`: the file moved into `tfc_dart` so the backend serves the same class the panel calls, and the verdict is unchanged because the guard, the gate and the audit row all moved with it |
| `packages/tfc_dart/lib/core/access/audit_trail_store.dart:413, 417` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `AuditTrailStore` | `correct as-is` — the handle Phase 5's **read-only** trail viewer holds. It is on this table because it names `AppDatabase`, not because it writes: the file contains no `into(`, no `update(` and no `delete(`, and `test/core/audit_trail_store_test.dart` asserts that on the source text rather than leaving it merely true today. The enforcement is the route gate `kRaisedRoutes['/advanced/audit-trail']` (05-07) and deliberately not a store check — a guard here would write a row into the trail every time somebody scrolled the trail, on the same reasoning `access_template_store.dart` gives for its own ungated reads. Same `_db` spelling as `HistoryViewStore` and `AccessTemplateStore`, so no ninth accessor. **Re-pathed 2026-09-07 by plan 17-02** from `lib/core/audit_trail_store.dart`: the file moved into `tfc_dart` so the backend serves the same class the panel calls, and the verdict is unchanged because the route gate that is the enforcement is unchanged — the store still takes no session and still cannot refuse anybody. The source-text assertion named above moved with it, and gained a `>400 lines` half in the same commit, because pointed at the fourteen-line `export` left at the old path every one of its absences would have gone on passing |
| `lib/providers/access_templates.dart:109` | `db: db.db` | `AppDatabase` | `accessTemplateStoreProvider` | `correct as-is` — the provider that hands `AccessTemplateStore` its handle, one line, no statement of its own. Same `db.db` spelling `accessRepositoryProvider` and `auditSinkProvider` already use, so no ninth accessor |
| `lib/providers/audit_trail.dart:53` | `db: db.db` | `AppDatabase` | `auditTrailStoreProvider` | `correct as-is` — the provider that hands the **read-only** `AuditTrailStore` its handle, one line, no statement of its own. It is on this table because it names the `.db` accessor, not because it writes: the file contains no Drift statement at all, and `test/providers/audit_trail_test.dart` asserts on the source text that it holds no audit sink and performs no permission check. The enforcement is the route gate `kRaisedRoutes['/advanced/audit-trail']` (05-07), on the same reasoning `packages/tfc_dart/lib/core/access/audit_trail_store.dart` gives above (re-pathed 2026-09-07 by plan 17-02; this provider did **not** move and still constructs the store from `lib/providers/`). Same `db.db` spelling `accessRepositoryProvider`, `auditSinkProvider` and `accessTemplateStoreProvider` already use, so no ninth accessor |
| `packages/tfc_relay_local/lib/src/collect/timescale_sink.dart:296, 297` | `AppDatabase.spawn(dbConfig)` / `AppDatabase.create(dbConfig)` | connection lifecycle | `TimescaleSink._openProduction`, at gateway start-up | `not widget-reachable` — builds the pool and writes nothing, the same verdict and the same reason as `lib/providers/database.dart:17-29`. The gateway takes a Postgres advisory lock **before** the pool is built, so a second gateway on the same database never holds so much as a pool slot |
| `packages/tfc_relay_local/lib/src/data/timescale_reader.dart:563, 713, 777` | `db.db.customSelect(sql, variables: [...])` | reads | the `timeseries.*` handlers, through `_PolicyTimeseries` | `correct as-is` — on this table because it names the `.db` accessor, not because it writes: the file contains no `into(`, no `update(`, no `delete(`, no `customUpdate(` and no `customStatement(`, and `freeze_test.dart` pins it as one of the two files in that package allowed to import the database layer at all. Reads over the pipe are filtered by `PolicyStateMan.canSee` rather than gated, on the same reasoning `audit_trail_store.dart` gives above; spec §11's deferral of read permissions applies to the relay too |
| `packages/tfc_relay_local/lib/src/data/preference_store.dart:517` | `db.db.customUpdate(...)` | `flutter_preferences` | `PreferenceStore.clear(allowList:)` | `session-gated (relay policy)` — the same call as 2.2's row, reported twice because it is the one line in the relay that is both a raw statement and a `.db` accessor. **No ninth spelling**: the receiver is written `db.db`, which is the third of the seven this section already lists. What *is* new is where the handle comes from — a `DatabaseSupplier` (`timescale_reader.dart:107`, a `Database? Function()`) borrowed per call rather than held as a field, because the sink reconnects and swaps its instance and a pinned one is stale after the first. A new *source* of an old spelling, which this section reports for the same reason it reports a new spelling |
| `lib/core/relay_alarm_source.dart:444` | `final db = preferences.database!.db` | reads | `RelayAlarmSource.getRecentAlarms` — the gateway-mode panel reading its own `alarm_history` (D-11), from the alarm history surface | `left open: read permissions are deferred` — spec §11, the same verdict as `history_view.dart`'s read rows above. The file issues one `select` and calls no write member on the handle; its one write is `:400`, rowed in 2.9. The receiver is `preferences.database!.db`, the seventh of the eight spellings — nothing new |
| `packages/tfc_dart/lib/core/relay/backend_alarm_history.dart:72, 450, 461` | the `AppDatabase` import, and `_require(member)` returning `database.db` | `alarm_history` | `AlarmHistoryWriter` — the store the three `customUpdate` rows in 2.2 execute through | `correct as-is` — the store holding its own handle, the same claim as the core-machinery row above; the write verdicts live on the 2.2 rows. `_require` is itself worth the sentence: composed without a database it refuses **by name** (P-12), where `alarm.dart:472` silently `return`s — so this write path cannot no-op into silence |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:592, 674, 991` | `drift.AppDatabase` fields on `DatabaseHistoryViewSource` and `BackendHistoryViews.overDatabase`, and `:991`'s `database.db` receiver | `AppDatabase` | the backend's data services — 2.1 and 2.2 carry their writes | `correct as-is` — the stores holding their own handle; every write through them is rowed above, and the check stands in the per-session `PolicyStateMan`, above all of them |
| `packages/tfc_dart/lib/core/relay/backend_composition.dart:348` | `BackendHistoryViews.overDatabase(database: database.db)` | `AppDatabase` | `composeBackendRelay` — the one function that assembles the centroidx-backend's graph, whose only production caller is `bin/main.dart` (asserted structurally by `backend_composition_test.dart`) | `correct as-is` — a composition root handing a store its handle, one line, no statement of its own: the same claim as `accessTemplateStoreProvider`'s row above, made in the second server-side program. What it builds is served only through the per-session `PolicyStateMan` (`relay_session.dart:367`), and the policy it serves under is **named** rather than defaulted — `backendRelayPolicy`, `AllVisibleOperatorWrites`, deliberately non-const so a test can assert somebody chose it |
| `packages/tfc_dart/lib/core/relay/backend_composition.dart:369` | `BackendAudit(database: database.db)` | `AppDatabase` | `composeBackendRelay` — the same composition root one row above; new at 17-06 | `correct as-is` — the root handing the **read-only** audit family its handle, and the asymmetry beside it is the finding worth its own row: only the audit family is wired here, because `BackendAccessTemplates` and `BackendAccessAdmin` attribute their rows to a session and a station, and at composition time there is no identity to attribute to — an invented one is the false attribution D-11 forbids, so those two wait for 17-09 to construct them where the relay identity is minted. Wiring the source does **not** put the trail on the wire ahead of its gate: every handler reads through the per-session `PolicyStateMan`, whose `audit` getter refuses wholesale (`_noAccessGate`, `policy_state_man.dart:379`) until 17-07 grades it — so this line changes what stands *behind* the gate, so 17-07 has something real to grade |
| `packages/tfc_dart/lib/core/relay/backend_access.dart:95, 191, 312` | `required AppDatabase? database` on the three family constructors (`BackendAccessTemplates`, `BackendAccessAdmin`, `BackendAudit`) | `AppDatabase` | `composeBackendRelay` for `BackendAudit` alone (`backend_composition.dart:369`, one row up); the template and admin families have **no production caller** until 17-09 | `correct as-is` — the seam handing the moved stores (`packages/tfc_dart/lib/core/access/*`, 17-02) their handle: this file maps and delegates and decides nothing, which `backend_access_test.dart`'s arm 10 asserts on its source rather than leaving as a doc claim, because the gates it must not duplicate are the stores' own — `AccessTemplateStore` and `AccessAdminStore` check `users` and write audit rows above every write (their §2.2 rows), and `AuditTrailStore` is read-only ungated by design (its row above). Nullable on purpose: composed without a database, each family refuses **by name** (P-12), the same shape as `backend_alarm_history.dart:450`'s `_require`, so "no templates configured" and "nobody wired a database" cannot look the same from a screen. No tenth accessor spelling — the handle arrives as a constructor argument spelled `database`, and the `.db` that feeds it is the composition root's |
| `packages/tfc_dart/lib/core/relay/backend_access.dart:80` | the word `AppDatabase` inside `_missingDatabase`'s diagnostic string | — | — | `not widget-reachable` — not a handle; the type grep matching a string literal, this section's first false positive of that kind, recorded rather than filtered away exactly as §2.2 records its own. The string is the refusal text the row above describes, naming the missing collaborator as P-12 requires |
| `packages/tfc_dart/lib/core/database_drift.g.dart` (176 occurrences at the first two runs, 192 at the third) | generated `_$AppDatabase` boilerplate | — | drift codegen | `not widget-reachable` — regenerated from `database_drift.dart`, which is searched above; collapsed by the script and counted |

**Seven accessor spellings at the 2026-08-29 run — `adb`, `dbWrap.db`,
`db.db`, `dbWrapper.db`, `_tsDb!.db`, `database!.db` and
`preferences.database!.db` — and an eighth at the 2026-08-30 re-run:
`HistoryViewStore._db` (`lib/core/guarded_history_views.dart:98`).** All eight
are covered above. The eighth is a guard this phase added rather than a store
this phase missed, which is the distinction this section exists to make
visible: a new spelling is reported either way, and the reader decides which
kind it is.

**No ninth at the 2026-09-05 re-run.** The relay reaches the handle through
`db.db`, the third of the eight, and the only thing that changed is that the
`db` in front of it is the return value of a `DatabaseSupplier` rather than a
field.

**A ninth at the 2026-09-07 re-run: `database.db`** —
`backend_composition.dart:348` (and `:369` since 17-06),
`backend_data_services.dart:991` and
`backend_alarm_history.dart:461`, the bare-named sibling of `database!.db`
where `database` is the backend's own `Database` held non-nullably (or checked
by `_require` first). Reported under this section's standing rule — a new
spelling is a new way a handle travels, and the reader decides which kind it
is. This one is the second server-side composition holding its stores'
handles: every write reached through it is rowed in 2.1 and 2.2, all of them
behind the same per-session `PolicyStateMan` the 2026-09-05 rows stand behind. Two disambiguations, because both are names this document now carries
twice: the relay's `HistoryViewStore`
(`packages/tfc_relay_local/lib/src/data/history_view_store.dart`) is a
different class from the app's `HistoryViewStore`
(`lib/core/guarded_history_views.dart`) — the first serves the wire, the second
is plan 03-10's guard — and the relay's `PreferenceStore` is not
`packages/tfc_dart/lib/core/preferences.dart`'s `Preferences`, it is a
`PreferencesApi` **over** it. Both pairs write the same tables in the same
Postgres.

### 2.4 `SharedPreferencesAsync()` constructed rather than injected (script §4 — 12 hits at the 2026-08-29 run, **1** at the 2026-08-30 re-run)

Spec §6 names **one** of these. There were twelve, in eight files, and nine of
the twelve were outside `lib/providers/` — the directory the spec's own CI check
would allow.

**Now enforced.** Plan 03-11 added
`scripts/check-preferences-construction.sh`, wired into the `flutter-test` job
of `.github/workflows/test.yml`, which fails the build for any construction
under `lib/` or `centroid-hmi/lib/` outside `lib/providers/`. The check found
**nine** violations against the tree this table describes and finds **zero**
now. The hit counts in the headings above are the pre-phase ones; plan 03-12
re-runs the sweep and reconciles them.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/providers/preferences.dart:26` | `createDeviceLocalPreferences()` — `SharedPreferencesWrapper(SharedPreferencesAsync())` | device-local | the two preference providers, and every site below that has no `ref` | `correct as-is` — this is the one place that is meant to construct it, and after 03-11 it is the only one |
| `lib/providers/collector.dart:21` | `final prefs = SharedPreferencesAsync()` | device-local | `collectorProvider`, at boot | `enforced by 03-09` — spec §6 bypass 2; gone from the tree, and the check would refuse its return |
| `lib/core/update_channel.dart:29, 41` | `prefs ?? createDeviceLocalPreferences()` | device-local | `readUpdateChannel` / `writeUpdateChannel`, called as tear-offs from `centroid-hmi/lib/main.dart:337, 372` and `lib/widgets/preferences.dart:79-80` | `enforced by 03-11` — the parameter is a `PreferencesApi` now, so the tear-off form is unchanged |
| `lib/tech_docs/tech_doc_library_section.dart:1197` | field on `_SharedPrefsReader`, from the factory | device-local | the Knowledge Base page's delete-document flow | `enforced by 03-11` |
| `lib/pages/page_view.dart:259` | `late final PreferencesApi prefs = ref.read(localPreferencesProvider)` | device-local | every asset page, on mount | `enforced by 03-11` — a `ref` exists, so it reads the provider rather than the factory |
| `lib/widgets/preferences.dart:556` | field on `_DatabaseConfigEditorState` | device-local | nothing — `grep -n sharedPreferences lib/widgets/preferences.dart` returned this line and no other | `enforced by 03-11` — **deleted**, not rerouted; confirmed unreferenced first |
| `lib/widgets/preferences.dart:822` | `ref.read(localPreferencesProvider)` in `_loadData` | device-local | the preferences page, read path (`localPrefs.getAll()`) | `route-gated (Phase 2)` — `/advanced/preferences` is `administer`; the construction is `enforced by 03-11` |
| `lib/widgets/panes/color_picker_dialog.dart:46, 70` | the factory, inline in two statics | device-local | any colour picker, anywhere in the app | `enforced by 03-11` — both statics keep their `try`/`catch`, so a broken store is still an empty strip |
| `centroid-hmi/lib/main.dart:273` | `createDeviceLocalPreferences()` | device-local | app boot, feeding `PageManager(prefs:)` and `pageManager.load()` on the next two lines | `enforced by 03-11` — this is the boot write of `page_editor_data` outside any provider; no `ProviderScope` exists yet, so it calls the factory |

### 2.5 Legacy synchronous `SharedPreferences.getInstance()` (script §5 — 6 hits)

Spec §6 does not mention this API, and the CI check it asks for
(`SharedPreferencesAsync()`) would never catch it. It is in the tree today.

**Now enforced, on a wider rule than the spec wrote.**
`scripts/check-preferences-construction.sh` searches for this pattern as well
as the one §6 names, under the same rule: anything outside `lib/providers/`
fails the build. Both files below are still in the tree and both are still
open — the point is that the check *looks* at them and lets them past for a
stated reason rather than never looking. The six hits are zero violations, and
that arithmetic is the whole content of the two rows.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/providers/theme.dart:15, 22, 44, 51` | `await SharedPreferences.getInstance()` | device-local | the theme and colour-scheme notifiers | `left open: device-local UI state, and inside \`lib/providers/\`` — see §3.6. Passes the check on the **directory** rule, not an allow-list entry; a copy of these four lines anywhere else fails the build |
| `lib/pages/dbus_login.dart:124, 141` | `await SharedPreferences.getInstance()` | device-local | the D-Bus login form | `left open: spec §2 excludes changing this file` — see §3.7. The **one** allow-list entry in the check, carrying that reason inline. Removing the entry makes the build fail on these two lines, which is how the entry was confirmed to be doing work |

### 2.6 Secure storage (script §6 — 33 hits at the 2026-08-29 run, 35 at the 2026-08-30 re-run, 37 at the 2026-09-05 re-run)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/dbus_login.dart:134` | `secureStorage.write(key: 'dbus_password', ...)` | OS keychain | the D-Bus login form | `left open: spec §2 excludes changing this file` — see §3.7 |
| `packages/tfc_dart/lib/core/database_config.dart:223, 241-242, 252-254` | `SecureStorage.getInstance().read/write(key: _configLocation, ...)` | OS keychain | `DatabaseConfig` persistence, from `/advanced/server-config` and `/advanced/preferences` | `route-gated (Phase 2)` — both routes are `administer`; the store itself stays outside the guards, see §3.4 |
| `packages/tfc_dart/lib/core/preferences.dart:205` | `secureStorage.write(key: key, value: value)` | OS keychain | `Preferences.setString(..., secret: true)` | `correct as-is` — inside the object `GuardedPreferences` wraps, so the check happens above it |
| `lib/core/secure_storage/macos.dart:118, 139, 144`, `lib/core/secure_storage/other.dart:24`, `packages/tfc_dart/lib/core/secure_storage/linux.dart:47` | `_storage.write(key:, value:)` | OS keychain | the platform implementations behind `MySecureStorage` | `left open: secure storage is outside both guards` — see §3.4 |
| `packages/tfc_dart/lib/core/secure_storage/secure_storage.dart:10-30`, `packages/tfc_dart/lib/core/secure_storage/interface.dart:1`, `packages/tfc_dart/lib/tfc_dart_core.dart:22`, `centroid-hmi/lib/main.dart:244` | the singleton, the interface, the barrel export of the interface, and the one `setInstance` at boot | — | — | `not widget-reachable` — type declarations, an export line, and one boot-time platform selection; no key is written |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart:436, 650` | `MySecureStorage get secureStorage => _inner.secureStorage` | — | anything holding the guarded object | `left open: secure storage is outside both guards` — the same hole as §3.4, reached through the decorator's own forwarding getter. Two hits because the checked path and `systemWrites` each forward it |
| `packages/tfc_relay_local/lib/src/data/preference_store.dart:71, 182` | the `MySecureStorage` import, and `final class NoSecretStorage implements MySecureStorage` | **nothing — every member throws** | the gateway's composition root installs it before building `Preferences` | `correct as-is` — and the one row in this section that is a *closure* of §3.4 rather than another instance of it. `Preferences.create` asks `SecureStorage.getInstance()` unconditionally and the Linux default builds an `AwsSecureStorage` over the OS keychain; a headless gateway has no keyring, and worse, a keychain reachable from the pipe would be remote retrieval of the secure store. So the gateway installs a store whose `read`, `write` and `delete` all throw (SEC-01), the `PreferencesApi` this package implements omits the `secret:` parameter entirely, and `preference_store_test.dart` greps the source for the word `secret` because the obvious future edit is to add it back "for symmetry". A type that cannot hold the secret cannot leak it, done by construction rather than by convention |

### 2.7 File writes (script §7 — 3 hits at the first two runs, 4 at the 2026-09-05 re-run, 5+ at the 2026-09-08 re-run once `backend_config_store.dart`'s three `writeAsBytes` sites landed with 17-10)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/key_repository.dart:1886` | `file.writeAsString(jsonString)` | filesystem | key-mapping export, `/advanced/key-repository` | `route-gated (Phase 2)` — `configure` |
| `lib/pages/server_config.dart:2923` | `.writeAsString(...convert(envelope))` | filesystem | server-config export, `/advanced/server-config` | `route-gated (Phase 2)` — `administer` |
| `packages/centroidx_upgrader/lib/src/manager_launcher.dart:159` | `staged.writeAsBytes(bytes)` | filesystem | `managerLauncher.launchForUpdate(...)` at `centroid-hmi/lib/main.dart:369` | `left open: the update path is ungated` — see §3.5 |
| `packages/tfc_stateman_contract/lib/src/faults/os_level.dart:468` | `rules.writeAsString(pfRulesetWithDummynet(baseRuleset: …, pipe: …))` | filesystem — a file under `Directory.systemTemp.createTemp('dummynet_spike')` | `installDummynet(...)`, from a fault-injection test run by hand on a developer's macOS machine | `test-kit only (dev dependency)` — a file write in the tree, and the one that is not the app's. It is worth a sentence because it is the only hit in this whole sweep that runs under `sudo`: the file is a pf ruleset **added to** the system's rather than replacing it, every command is an argv vector handed straight to `Process.run` with no shell in between, the one caller-supplied value that lands next to `sudo` is checked against `netemShapeableDevices` before it goes in the list (threat T-02-14), and teardown — `:535`'s directory delete, `pfctl -f` of the original ruleset, `dnctl` flush — is registered the moment the install succeeds. It reaches no plant and no station |
| `packages/tfc_dart/lib/core/relay/backend_config_store.dart:247, 271, 470` | `File('$path.previous').writeAsBytes(original)`, `prevFile.writeAsBytes(rejected)`, `temp.writeAsBytes(bytes)` — the config file, its `.previous` backup, and the atomic temp before the rename | filesystem — the backend's `StateManConfig` file and its `<path>.previous` | `backendConfig.write` / `restorePrevious` frames on the session's peer (17-10, D-10) | `session-gated (relay policy)` — the **fifth** file write in the tree, and the one the wire reaches. It is graded `administer` by `AccessPolicy.groupForBackendConfig` in `PolicyStateMan.backendConfig` before any byte is written; the payload is validated by round-tripping `StateManConfig.fromJson` and **refused** rather than written on any failure (D-10 first hazard), a `relay`-section edit is refused by name (D-10 second hazard), and the previous file is copied to `<path>.previous` before the write so `restorePrevious` can reach it. **Standing wiring gap, named not hidden (17-11 deviation 3):** the shipped `composeBackendRelay` wires templates and admin per identity but serves `backendConfig` sessionlessly from the shared source — `IdentityAccessFamilies` carries no config slot — so over-the-wire config editing is 17-13's to complete; wiring it sessionlessly would forge D-11 attribution, so it was deliberately left for the plan that owns the screen. 17-14's E2E records the measured behaviour of the shipped graph at its config surface |

**Nothing further found** in this section: five file writes in the whole tree,
all five identified — two already behind a raised route, one in a package no
shipped binary links, and the fifth (the backend config store) graded
`administer` over the wire before it touches disk, with the standing sessionless
wiring gap named in its row.

### 2.8 D-Bus — network and hostname (script §8 — 31 hits at the 2026-08-29 run, 34 at the 2026-08-30 re-run, 45 at the 2026-09-05 re-run)

**No relay row in this section, and that is a result rather than an omission.**
All forty-five hits are in the ten files already tabled below; the eleven new
ones are further lines in `ip_settings.dart`, `network_manager_ops.dart` and
`system_clock.dart` that arrived from main. The gateway speaks no D-Bus at all.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/ip_settings.dart:263, 919-925, 1107-1125` | `activateConnection`, `deactivateConnection`, `addAndActivateConnection`, `settings.addConnection` | NetworkManager over D-Bus | `/advanced/ip-settings` | `route-gated (Phase 2)` — spec §6 bypass 3, gated at the route with the D-Bus call itself deliberately untouched |
| `lib/pages/ip_settings.dart:39, 68, 84, 399, 819, 1048` | `NetworkManagerClient` fields and construction | — | the same page | `route-gated (Phase 2)` |
| `lib/pages/about_linux.dart:98` | `nm.NetworkManagerClient(bus: ...)` | — | `/advanced/about-linux` (read-only page) | `not widget-reachable` as a write — the client is constructed to *read* device state; no write member is called in that file |
| `lib/core/network_manager_ops.dart:86, 107` | `client.settings.addConnection(settings)`, `client.activateConnection(device:, connection:)` | NetworkManager over D-Bus | `lib/pages/ip_settings.dart:10` — the **only** importer in the tree (`grep -rn network_manager_ops lib centroid-hmi/lib`), so `/advanced/ip-settings` | `route-gated (Phase 2)` — the same verdict as the rows above it, reached one file deeper. **This row was missing from the 2026-08-29 run and is the 2026-08-30 re-run's one genuine finding — see §4.1 F** |
| `lib/widgets/tfc_operations.dart:22, 24, 69` | `_operationMode.callSetMode('running' \| 'stopped' \| 'cleaning')` | `is.centroid.OperationMode` over D-Bus | `OperationModeAppBarLeftWidgetProvider`, which **nothing in the repository constructs** — `globalAppBarLeftWidgetProvider` (`lib/widgets/base_scaffold.dart:36`) defaults to null and is never overridden | `left open: unwired today, and start/stop is an operator action by design` — see §3.8 |
| `lib/core/system_clock.dart:453-465, 538` | `callSetNTP`, `callSetTimezone`, `callSetLocalRTC`, `callSetTime`, `callSetRuntimeNTPServers` | systemd-timedated / systemd-timesyncd over D-Bus | `lib/widgets/system_clock_section.dart`, mounted on `/advanced/about-linux` | `left open: arrived from main after this milestone's route census` — upstream #440 gave the clock and NTP settings to a page the row below classified, correctly at the time, as read-only. Two things stand behind it today and neither is this milestone's gate: every call passes `allowInteractiveAuthorization: true`, so **polkit** decides at the OS, and the station's clock is not a plant control. Raising `/advanced/about-linux` is a product decision for the owner of #440 — a rebase is the wrong place to take an operator's clock away. See §3.9 |
| `lib/core/system_clock.dart:51-53` | `prefs.remove(ntpServersPrefsKey)`, `prefs.setStringList(ntpServersPrefsKey, ...)` | device-local | the same section, through `ref.read(localPreferencesProvider)` at `lib/pages/about_linux.dart:52, 60` | construction `enforced by 03-11` — the store comes from the provider rather than the factory. Device-local by design: NTP servers are a per-station choice, like the startup URL, so the write bypasses `GuardedPreferences` for the same reason those do |
| `lib/core/gateway_config.dart:198` | `prefs.setString(GatewayConfig.prefsKey, ...)` | device-local | the Transport card on `/advanced/server-config`, through `ref.read(localPreferencesProvider)` | construction `enforced by 03-11` — the store is handed in as a `PreferencesApi`, never constructed here. Device-local by design: which gateway a panel dials is a per-station choice with exactly the property that makes `DatabaseConfig` unsafe to sync, so the write bypasses `GuardedPreferences` for the same reason the startup URL and the NTP servers do. No secret crosses it — the CA root and the station credential are stored as paths to mounted files |
| `lib/dbus/generated/timedate1.dart:101-116`, `lib/dbus/generated/timesync1.dart:131` | `callSetTime`, `callSetTimezone`, `callSetLocalRTC`, `callSetNTP`, `callSetRuntimeNTPServers` | systemd-timedated / systemd-timesyncd | `lib/core/system_clock.dart` — the only importer | `correct as-is` — generated D-Bus bindings. The verdict belongs at the caller, one row above, exactly as it does for the NetworkManager bindings; a generated proxy is transport, not a decision |
| `lib/dbus/generated/hostname1.dart:290-356` | `callSetHostname`, `callSetStaticHostname`, `callSetPrettyHostname`, `callSetIconName`, `callSetChassis`, `callSetDeployment`, `callSetLocation` | systemd-hostnamed | **no caller anywhere in the tree** | `not widget-reachable` — generated D-Bus bindings with zero call sites; a grep for each name outside this file returns nothing |
| `lib/dbus/generated/login1.dart:1140-1563` | `callSetUserLinger`, `callSetRebootParameter`, `callSetRebootToFirmwareSetup`, `callSetRebootToBootLoaderMenu`, `callSetRebootToBootLoaderEntry`, `callSetWallMessage` | systemd-logind | **no caller anywhere in the tree** | `not widget-reachable` — same |
| `lib/dbus/generated/operations.dart:88` | `callSetMode` declaration | — | the binding `tfc_operations.dart` calls | `correct as-is` — a generated binding; the call site is the row above |

### 2.9 Writes through the injected preferences interface (script §9 — 76 + 17 hits at the 2026-08-29 run, 89 + 18 at the 2026-08-30 re-run, 126 + 24 at the 2026-09-05 re-run, 138 + 26 at the 2026-09-07 re-run)

These are **not bypasses**. They are the surface plan 03-01 classifies, and the
reason they are enumerated is that neither a construction search nor a Drift
search produces a single hit for them. Every key expression below is resolved
in §5.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/core/startup_url.dart:24, 26` | `prefs.remove/setString(startupUrlPrefsKey)` | preferences | the startup-page control | `guarded by 03-06` |
| `lib/core/config_source.dart:98, 126` | `prefs.setString(StateManConfig.configKey, ..., secret: true, saveToDb: false)` | secure store | `LocalPrefsConfigSource.read` seeding the default when the key is absent, and `.write` saving the unified editor's ONE document (quick/20260908-unify-config-ui, `/advanced/server-config`) | `guarded by 03-06` — the same key, the same flags and the same default as `state_man.dart:442/450` one section over; `route-gated (Phase 2)` besides |
| `lib/core/update_channel.dart:42` | `p.setString(updateChannelPrefsKey, ...)` | preferences | the update-channel control | construction `enforced by 03-11`; the write itself is `guarded by 03-06` |
| `lib/chat/chat_widget.dart:189, 361, 392, 394` | `prefs.setString/remove(...)` | preferences | the chat provider-settings dialog | `guarded by 03-06` |
| `lib/providers/state_man.dart:26` | `prefs.setString('key_mappings', ...)` | preferences | `stateManProvider` at boot | `guarded by 03-06` — routed through `systemWrites` |
| `lib/providers/collector.dart:27` | `prefs.setString(Collector.configLocation, ...)` | preferences | `collectorProvider` at boot | `guarded by 03-09` |
| `lib/providers/access.dart:694` | `local.setString(kAccessSessionPrefKey, ...)` | device-local preferences | every `poke()`, i.e. every pointer-down | `guarded by 03-06` |
| `lib/providers/chat.dart:340, 370, 405, 449, 453, 494, 505, 525, 529, 532, 535, 538, 548, 558, 905` | `prefs.setString/remove(chat.*)` | preferences | chat conversation management | `guarded by 03-06` |
| `lib/providers/theme.dart:23, 52` | `prefs.setString(_key, ...)` | device-local, **legacy sync API** | theme and colour-scheme controls | `left open: device-local UI state, and inside \`lib/providers/\`` — see §3.6 |
| `lib/tech_docs/tech_doc_upload_service.dart:267` | `prefsReader.setString('page_editor_data', ...)` | preferences | deleting a tech doc on the ungated Knowledge Base page | construction `enforced by 03-11` — the store it writes through comes from the factory at `tech_doc_library_section.dart:1197`; see also §3.1 |
| `lib/tech_docs/tech_doc_library_section.dart:1206` | `_prefs.setString(key, value)` | device-local | the `PrefsReader` adapter the row above uses | construction `enforced by 03-11` |
| `lib/pages/key_repository.dart:637, 1933` | `prefs.setString('key_mappings', ...)` | preferences | `/advanced/key-repository` | `guarded by 03-06` — and `route-gated (Phase 2)` besides |
| `lib/pages/page_view.dart:270` | `prefs.setString('asset_stack_config', ...)` | device-local | every asset page, on the read path when the key is absent | construction `enforced by 03-11` — the store now comes from `localPreferencesProvider`; the write is unchanged and still once per mount |
| `lib/pages/dbus_login.dart:127-131` | `prefs.setString/setBool(...)` | device-local, **legacy sync API** | the D-Bus login form | `left open: spec §2 excludes changing this file` — see §3.7 |
| `lib/pages/access_session_section.dart` | `prefs.setInt(kAccessInactivityMinutesPrefKey, ...)`, `prefs.setBool(kAccessInactivityDisabledPrefKey, ...)` | device-local | the Session card on `/advanced/access` | `route-gated (Phase 2)` — `users`; and the card records its own audit row per change through `RefAuditSink`, because a device-local write bypasses `GuardedPreferences` and the width of the elevation window — or its removal entirely, the never-expire switch — must not change without a row. Minutes bounded 1..480 before the write; the provider's clamp stays as the backstop for hand-edited stores, and the disable is an explicit boolean so a stray zero still clamps up instead of meaning "never" |
| `lib/page_creator/page.dart:247` | `prefs.setString(storageKey, jsonString)` | preferences | `PageManager.load()` at boot, **unawaited** | `guarded by 03-06` — routed through `systemWrites` |
| `lib/page_creator/page.dart:252, 257` | `prefs.setString(storageKey \| orderStorageKey, ...)` | preferences | the page editor's save | `guarded by 03-06` |
| `lib/page_creator/assets/image_store.dart:96, 129` | `prefs.setString/remove('$keyPrefix$id')` | preferences | page-editor image add and delete | `guarded by 03-06` |
| `lib/page_creator/assets/common.dart:444` | `prefs.setString('key_mappings', ...)` | preferences | asset key-mapping edits | `guarded by 03-06` |
| `lib/page_creator/assets/recipes.dart:269` | `prefs.setString(prefKey, jsonEncode(recipes))` | preferences | `_getRecipes` on the **read** path | `guarded by 03-06` |
| `lib/page_creator/assets/recipes.dart:281` | `prefs.setString(prefKey, ...)` | preferences | `_saveRecipes`, behind a control | `guarded by 03-06` |
| `lib/widgets/preferences.dart:949-957, 979, 981` | `target.setBool/setInt/setDouble/setStringList/setString(e.key, ...)`, `prefs.remove(e.key)`, `localPrefs.remove(e.key)` | preferences and device-local | the raw preference editor on `/advanced/preferences` | `route-gated (Phase 2)` — `administer`; the key is whatever the operator typed, see §5 |
| `lib/widgets/panes/color_picker_dialog.dart:70` | `createDeviceLocalPreferences().setStringList(prefsKey, ...)` | device-local | confirming a colour anywhere in the app | construction `enforced by 03-11`; the write stays on the deliberately unguarded device-local store |
| `lib/core/preferences.dart:54-84` | `_prefs.set*/remove/clear(key)` | device-local | `SharedPreferencesWrapper` | `correct as-is` — delegation with the caller's key |
| `packages/tfc_dart/lib/core/preferences.dart:344-413, 485-493, 524-532, 565-585` | `_memoryCache.set*`, `localCache?.set*`, `cache.set*` | in-memory and device-local caches | inside `Preferences` | `correct as-is` — the cache fan-out below the guard |
| `lib/providers/alarm.dart:28` | `systemPrefs.setString('alarm_man_config', ...)` | preferences | `alarmManProvider` at boot, writing the empty default | `guarded by 03-06` — routed through `systemWrites`, and one of the seven sites `kSystemWriteCallSites` names. New since the 2026-08-29 run |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart:335, 348, 361, 373, 385` | the five checked `set*` members, each delegating to `_inner.set*` | preferences | every caller of `preferencesProvider` | `correct as-is` — this **is** the guard; the check and the row happen above the delegation |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart:532, 545, 558, 570, 582` | the same five members on `systemWrites`, with the session check skipped | preferences | the boot defaults of §3.9 | `left open: the deliberately unchecked write path` — §2.10 and §3.9 price it; this row is the file and line it lives at |
| `lib/core/guarded_knowledge_stores.dart:660` | `GuardedPrefsReader.setString` delegating to `_inner.setString(key, value)` | device-local | the Knowledge Base page's delete-document cleanup | `guarded by 03-13` — `configure` plus one audit row. The store it writes through is unchanged and is the device-local one; see this phase's `deferred-items.md` §4 |
| `packages/tfc_dart/lib/core/state_man.dart:63` | `prefs.setString(configKey, ..., secret: true, saveToDb: false)` | secure store | `StateManConfig.fromPrefs` at boot when the key is absent | `guarded by 03-06` — routed through `systemWrites` |
| `packages/tfc_dart/lib/core/state_man.dart:71` | `prefs.setString(configKey, ...)` | secure store | `StateManConfig.toPrefs`, behind a control | `guarded by 03-06` |
| `packages/tfc_dart/lib/core/state_man_types.dart:671` | `prefs.setString('key_mappings', ...)` | preferences | key-mapping save | `guarded by 03-06` |
| `packages/tfc_dart/lib/core/alarm.dart:220` | `preferences.setString('alarm_man_config', ...)` | preferences | `AlarmMan.create` at boot when the key is absent | `guarded by 03-06` — routed through `systemWrites` |
| `packages/tfc_dart/lib/core/alarm.dart:303` | `preferences.setString('alarm_man_config', ...)` | preferences | `addAlarm`/`removeAlarm`/`updateAlarm`, behind the `configure`-gated alarm editor. **Not** `ackAlarm` | `guarded by 03-06` |
| `packages/tfc_mcp_server/lib/src/tools/read_toggles.dart:38, 114` | `prefs.setString(McpConfig.kPrefKey, ...)`, `local.setString(...)` | preferences and device-local | an MCP tool call, in the HMI process | `left open: reached over MCP, not from a widget` — see §3.2 |
| `packages/tfc_mcp_server/lib/src/services/config_service.dart:64` | `_prefCache.clear()` | — | `invalidateCache()` | `not widget-reachable` — `_prefCache` is a `TtlCache` (`config_service.dart:45`), not a preferences store. A false positive of section 9b's receiver-spelling filter, recorded rather than quietly dropped |
| `packages/tfc_relay_server/lib/src/policy/policy_state_man.dart:993, 999, 1005, 1013, 1020` | the five `set*` members on `_PolicyPreferences`, each calling `requireOperate(...)` before delegating to `_source.set*` — and `remove` and `clear` beside them | `flutter_preferences` | every `preferences.*` frame on the wire | `correct as-is` — this **is** the relay's preference guard, the same shape as `guarded_preferences.dart`'s five rows below. All seven mutators ask the gate; `clear` asks it **and then refuses an unrestricted clear outright**, because the permission needed to wipe `key_mappings` was otherwise the permission needed to set a theme (10-REVIEW CR-02). The reads above them are ungated by design. Since D-03 (17-07/17-11) the gate asks `AccessPolicy.groupForPref(key)` then `session.can(group)` — the same per-key question `kPrefAccessRules` answers for the app, no longer a flat operate check — so it and the app now agree; §3.12 records the close |
| `packages/tfc_relay_server/lib/src/data_handlers.dart:688, 704, 732, 745, 778` | `source.preferences.set*(key, raw)` | `flutter_preferences` | the `preferences.setBool` / `setInt` / `setDouble` / `setString` / `setStringList` methods on the session's peer | `session-gated (relay policy)` — `source` is the session's `PolicyStateMan`, so the row above is what these five reach. The key is **whatever the client sent**, which makes this the relay's counterpart of `lib/widgets/preferences.dart`'s raw editor — except that the app's raw editor is behind an `administer` route and this one is behind `operate`. See §3.12 and §5 |
| `packages/tfc_relay_local/lib/src/data/preference_store.dart:425, 429, 433, 437, 441` and `:525` | `(await _load()).set*(key, value)`, and `prefs.clear(allowList:)` after the durable delete | `flutter_preferences` — **the same table and the same rows the HMI writes** | `_PolicyPreferences`, from the five handlers above | `session-gated (relay policy)` — the store the relay's guard delegates through, and the reason `correct as-is` would be the wrong verdict here: a reader who found this file by grepping for `flutter_preferences` needs to be told that the check above it is **not** `GuardedPreferences` and does not consult `kPrefAccessRules`. `_load()` goes through `Preferences.create` and never the public constructor, because a hand-built `Preferences` answers "no keys" to a store that at SVN holds 675,890 bytes (TRAP 8) |
| `packages/tfc_stateman_contract/lib/src/channel/served_state_man.dart:672, 679, 690, 697, 703` and `:710, 716` | `api.preferences.set*(params[…])`, `.remove(...)`, `.clear(allowList:)` | whatever the suite pointed it at | the harness peer's method table | `test-kit only (dev dependency)` — the shape `data_handlers.dart` copied rather than imported; see 2.1 |
| `packages/tfc_stateman_contract/lib/src/data_services_contract.dart:390, 396, 403, 413, 422, 480, 481, 551` and `:444, 483` | `prefs.set*`, `prefs.remove`, `prefs.clear(allowList:)` inside contract checks | whatever implementation the suite is run against | the shared contract suite | `test-kit only (dev dependency)` — assertions, run by `dart test` in five packages. The keys are the suite's own literals (`svn.chart.maxPoints`, `svn.weigher.tolerance`, `svn.site.name`, `svn.page.recent`), which is why they resolve against nothing in §5 |
| `packages/tfc_stateman_contract/lib/testing/broken_browse.dart:177, 180, 184, 188, 192` | `_honest.set*(key, value)` | **nothing** — the honest fake's `Map` | `test/sabotage_browse_test.dart` | `test-kit only (dev dependency)` — a **deliberately damaged** implementation, and it is the writes that are the honest half of it: this variant stores every preference correctly and simply never announces the change, which is the shipped defect it reproduces ("a preferences backend whose change stream was declared, wired to nothing, and never noticed because the page that reads it also writes it"). Sabotage that failed everything would prove nothing about any individual check |
| `lib/core/relay_alarm_source.dart:400` | `preferences.setString('alarm_man_config', ...)` | preferences | `_saveConfig` ← `addAlarm`/`removeAlarm`/`updateAlarm`, behind the `configure`-gated alarm editor. **Not** `ackAlarm` — a gateway-mode acknowledge travels the wire and writes nothing here | `guarded by 03-06` — the same call, the same key and the same reason as `tfc_dart/core/alarm.dart:303`'s row: `alarmManProvider` (`lib/providers/alarm.dart:91`) hands this class the guarded `preferencesProvider` object, so the write asks `kPrefAccessRules`' exact `alarm_man_config` rule (`configure`) — and the boot default is seeded through `systemWrites` *before* construction, so `create` finds the key present and never writes |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:950-966` | the five `set*`, `remove` and `clearFromMemory` on `PreferencesSource`, each delegating to the backend's `Preferences` **non-secret overload** | `flutter_preferences` — the same table and the same rows the HMI writes | `BackendPreferences`, one row below | `session-gated (relay policy)` — the centroidx-backend's twin of `preference_store.dart:425-441`, below the same `_PolicyPreferences`. The `secret:` parameter is absent from `PreferenceSource` by construction (SEC-01), and an arm greps the file for the word — so no client-supplied boolean can steer a pipe write into the OS keychain |
| `packages/tfc_dart/lib/core/relay/backend_data_services.dart:1091-1107` and `:1110, 1141` | the five `set*` on `BackendPreferences`, and `remove` and `clear(allowList:)` beside them — the backend's `PreferencesApi` | `flutter_preferences` | `_PolicyPreferences`, from `DataHandlers`' preference handlers on the session's peer | `session-gated (relay policy)` — all seven mutators stand behind `requireOperate`, and the unrestricted `clear` is refused outright above (`policy_state_man.dart:1075`). The key is **whatever the client sent**, graded by station role and never by `kPrefAccessRules` — §3.12, and §5's relay rows, apply to this composition word for word |

### 2.10 Two rows that exist because of this phase's design

These are not search results. They are holes the guards themselves open, and
they get rows so that they are visible rather than implied.

| Site | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `GuardedPreferences.systemWrites` (plan 03-05) | the seven write members with the session check skipped | preferences | the boot defaults enumerated in plan 03-06 | `left open: the deliberately unchecked write path` — see §3.9 |
| `GuardedPreferences.database` (plan 03-05) | `guardedPrefs.database.db` → any raw Drift statement | every table | anything holding the guarded object | `left open: \`implements Preferences\` forces the getter` — see §3.10 |

---

## 3. What is left open, and why

Each entry says what closing it would take, so a later phase can price it.

### 3.1 Three raw-Drift index classes reachable from the Knowledge Base page

**What.** `DriftTechDocIndex`, `DriftPlcCodeIndex` and `DriftDrawingIndex` live
in `packages/tfc_mcp_server/lib/src/services/`, and each writes Drift directly —
twenty-six `into(...)` / `delete(...)` / `update(...)` statements between them
(twelve, eight and six respectively). They were built for the MCP server, but all three are wired into the
Flutter app through providers (`lib/providers/tech_doc.dart`,
`lib/providers/plc.dart:65`, `lib/providers/drawing.dart:14`) and their write
methods are called from app code:

- `lib/tech_docs/tech_doc_upload_service.dart:104, 149, 221-222, 275` —
  `storeDocument`, `updateSections`, `updatePdfBytes`, `deleteDocument`.
- `lib/tech_docs/tech_doc_library_section.dart:1075, 1133` — `reindexAsset` and
  `deleteAssetIndex` on `DriftPlcCodeIndex`, called straight from the page.
- `lib/drawings/drawing_upload_service.dart:46, 61, 75` — `storeDrawing` and
  `deleteDrawing`. `DrawingUploadDialog` has no caller in the tree today, so
  this third one is reachable in principle and unwired in fact.

**Where the operator was, when this was written.** `/advanced/knowledge-base`
was deliberately **not** in `kRaisedRoutes`, and `lib/access_routes.dart` named
it among the pages that "read rather than configure". It does not only read: an
anonymous session at the panel could delete a technical document, delete a PLC
asset's index, and — through `tech_doc_upload_service.dart:267` — rewrite
`page_editor_data`. That is the claim plan 03-14 acted on; the route is raised
now and both spellings of the sentence are gone from the source.

**Why this is the same defect as the history view.** A destructive control on a
page that should stay readable. §6's fourth bypass was exactly that, on
`/advanced/history-view`, and plan 03-10 fixes it at the controls rather than at
the route for exactly this reason.

**Closed, at both ends.** This document found it and owned no fix; two plans
were then written for it and both have landed.

- **The controls, by plan 03-13.** One guarded store object per index, holding
  the write methods, checking `configure` on the destructive ones and auditing
  all of them, with the app-side call sites changing only their receiver
  (`lib/core/guarded_knowledge_stores.dart`, wired at
  `lib/providers/tech_doc.dart`, `lib/providers/plc.dart` and
  `lib/providers/drawing.dart`). The index classes themselves are unchanged.
- **The route, by plan 03-14.** `/advanced/knowledge-base` is the seventh entry
  in `kRaisedRoutes` at `AccessGroup.configure`, and its child in
  `centroid-hmi/lib/main.dart` is wrapped in the same `gated(...)` helper the
  other six use. An anonymous session now sees the locked page, and the menu
  entry stays visible with a lock badge rather than disappearing.

**Why both, rather than either.** The route gate alone would leave the three
write surfaces unaudited for anybody who does hold `configure` — the same group
`page_editor_data` is worth. The control guards alone would leave a page that
reaches three write surfaces open to a session holding nothing.

**The accepted cost, stated plainly.** An anonymous operator can no longer read
technical documents or browse PLC code at the panel. On a plant floor that is a
real loss: somebody wanting a manual at the machine now has to find a person
with a `configure` account, or walk. The user was told and chose it over leaving
a write path around the page-editor gate. It is the one place in this milestone
where gating a route takes something away from an operator rather than only from
a configurer, and spec §11's deferral of read permissions is not a defence here
— this page writes.

**What is not lost**, stated as precisely. The drawings overlay on ordinary
pages (`centroid-hmi/lib/main.dart:763-781`) is a different surface — not this
route, read-only, and 03-13's decorators pass reads straight through — so a
drawing is still available on the page an operator is standing at.

**The evidence above is kept deliberately.** The file-and-line list and the
`page_editor_data` argument are what make this finding re-checkable; a closed
finding with its evidence deleted is a finding nobody can audit.

### 3.2 Writes reached over MCP rather than from a widget

**What.** `TfcMcpServer` runs **inside the HMI process**
(`lib/mcp/mcp_bridge_notifier.dart:266`, `lib/mcp/mcp_sse_server.dart:56`), so
its tool handlers reach the same stores the app does:
`read_toggles.dart:38, 114` writes `mcp.config`, and
`audit_log_service.dart:47, 85` writes the MCP audit table.

**Why it was deferred.** No widget reaches them; the caller is a remote agent
over SSE. Spec §7c already decided what happens: MCP tools that change
authorization are gated on `users` and audited with `origin = 'mcp'` and `who` =
the approving human. That was Phase 4's work, not Phase 3's.

**Closed by Phase 4, plan 04-09 — the authorization half.** The deferral is
discharged and this is what discharged it, so that a reader can check the claim
rather than take it:

- Six tools in `packages/tfc_mcp_server/lib/src/tools/access_template_tools.dart`
  (spec §7c's names): `list_access_templates` and `list_unbound_keys` read;
  `create_access_template`, `update_access_template`,
  `delete_access_template` and `bind_key_access_template` change nothing at
  all and return a **proposal**.
- **Nothing in `tfc_mcp_server` writes** either authorization table.
  `AccessTemplateService` has no write method, public or private, and a test
  greps both files for write verbs. That property is what the rest of this
  entry rests on.
- **The `users` gate is at the approval, not in the tool.** The MCP server is
  a separate package with no session — it cannot know who is standing at the
  panel, and shipping an `AccessSession` into it would be exactly the
  `tfc_dart` dependency `packages/tfc_access`'s purity rule exists to avoid.
  So an accepted proposal is applied in the app, by
  `lib/pages/access_templates_section.dart`, through 04-03's
  `AccessTemplateStore` — the same `users`-gated store the section's own
  buttons use, and the only writer of `access_template` and
  `access_key_binding`. An agent proposing a change nobody may make gets a
  proposal nobody can approve, and an `allowed: false` row saying so.
- **`origin = 'mcp'` on every applied row, and `who` = the approving human.**
  `origin` is the only thing the accept path tells the store about
  provenance; `who` comes from the live session at the moment of the write,
  and there is no parameter through which a proposal could name somebody
  else. `test/pages/access_template_proposal_test.dart` seeds a proposal with
  a conflicting `operator_id` and asserts the row carries the signed-in user.

**What stays open, and stays rowed.** The closure above is about MCP writes
that change **authorization**. It is not about the two write sites this entry
enumerates, which are still reached over MCP and still ungated:
`read_toggles.dart:38, 114` writes `mcp.config`, and
`audit_log_service.dart:47, 85` writes the MCP audit table. Neither is
authorization data — one is the copilot's own tool configuration, the other
the copilot's own trail — and neither was in §7c's scope. Their rows in §2
therefore still read `left open: reached over MCP, not from a widget`, and
that is deliberate: a section that closed *by* emptying its evidence is the
defect this document exists to prevent, and a verdict that quietly widened
from "the authorization half" to "all of it" would be the same defect wearing
a better mood.

### 3.3 The access repository writes its own store

`packages/tfc_dart/lib/core/access/access_repository.dart` writes `app_role` and
`app_user` through raw Drift — twelve `into(...)` / `update(...)` / `delete(...)`
statements. It is the authorization store itself; a guard consulting the policy
to decide whether the policy's own data may change would be circular. Spec §7c
and §9 put roles and users behind `AccessGroup.users`, and Phase 6 builds the
screens that drive it. Closing it means gating those screens, not decorating
this class.

**Closed by Phase 6, plan 06-03.** The condition written above is the one that
was met, so here is what met it, in a form a reader can check rather than take:

- `AccessAdminStore` (`packages/tfc_dart/lib/core/access/access_admin_store.dart`,
  re-exported at `lib/core/access_admin_store.dart`) is the one object the
  screens write through. It names its permission once, as `kAccessAdminGroup =
  AccessGroup.users` — the same shape `access_template_store.dart` uses for
  `kAccessTemplateGroup`. **Moved 2026-09-07 by plan 17-02**, into the same
  directory as the `AccessRepository` this entry is about, so the backend
  serves the same class the panel calls rather than a second implementation of
  one policy — which would have re-derived this gate, the
  deny-row-before-throw ordering below, and the last-`users`-holder invariant
  the repository evaluates inside its own transaction. The closure this entry
  records is unchanged: the object, the constant and the eight writes are the
  same ones, at a new path. Note that this store has **no §2 row of its own**
  and needs none — it holds no `AppDatabase` and issues no Drift statement, so
  the script finds nothing in it, before the move or after.
- **All eight writes ask that gate**: `createRole`, `updateRole`, `deleteRole`,
  `renameRole`, `createUser`, `deleteUser`, `setUserRole` and `setUserPassword`.
  There is no ninth, and there is no generic row builder — each write is paired
  with one of 06-01's eight named `AuditRecord` constructors, which is what fixes
  the itemKey vocabulary in one place.
- **Every one of them records a row, refusals included.** The deny row is written
  *before* the `AccessDenied` is thrown, because a refusal that leaves no trace
  is the one kind of guard nobody can audit afterwards.
  `test/core/access_admin_store_test.dart` drives a `configure`-only session —
  the page editor who must not be able to grant themselves `users` — into all
  eight, so the gate is checked rather than remembered.

**What closing it did not mean, stated because the entry said so in advance.**
The repository was *not* decorated. It still writes both tables through Drift,
correctly, because it is the layer that owns `db.transaction` and the
last-`users`-holder invariant that has to be evaluated inside it. A decorator
here would have had to reach an `AccessSession` from `packages/tfc_dart`, which
is the dependency `packages/tfc_access`'s purity rule exists to avoid, and it
would have put the invariant outside the transaction that makes it an invariant.

**What the closure does not claim.** `AccessRepository` remains constructible
and callable directly by anything holding an `AppDatabase`; nothing about the
class refuses. **The gate is a property of the path the UI takes, not of the
class**, and the honest form of that claim is a test rather than a sentence: no
file under `lib/pages/` constructs an `AccessRepository`, asserted in
`test/core/phase_03_coverage_test.dart`. The page layer reaches the repository
only through `accessAdminStoreProvider`, and the store is the thing that asks.

One caller is a deliberate exception and is named here so the paragraph above is
not read as more than it is: `lib/pages/first_user.dart:141` calls
`repo.createFirstUser(...)` straight off `accessRepositoryProvider`. That is the
first-user window, which exists precisely for the state in which nobody can hold
`users` yet — `app_user` is empty — and it is checked *inside* the transaction
rather than by a guard. It writes no other row and cannot run once an account
exists.

**The line span was dropped from this entry deliberately.** It read `:177-340`
when the entry was written and every one of those numbers moved when 06-02 added
the five user methods. This document's own reconciliation test matches by file
and never by line for that reason, so a count of statements is the claim that
survives a reformat. The §2 row above still lists today's lines, because that is
the table's shape and because `scripts/sweep-write-paths.sh` reprints them on
demand — but the argument this entry makes does not rest on them.

### 3.4 Secure storage is outside both guards

`MySecureStorage` (`packages/tfc_dart/lib/core/secure_storage/interface.dart:1`)
is reached through a process-wide singleton, `SecureStorage.getInstance()`, and
neither `GuardedStateMan` nor `GuardedPreferences` wraps it. Three things live
there: `state_man_config`, the database config
(`packages/tfc_dart/lib/core/database.dart:214-226`) and the D-Bus password.

The first two are already covered in practice — `state_man_config` is written
through `Preferences.setString(..., secret: true)`, which the guard *does* wrap
(`packages/tfc_dart/lib/core/preferences.dart:205` is below the decorator), and
the database config is written only from two `administer`-gated routes. The
third is §3.7.

**What closing it would take.** A third decorator over `MySecureStorage`, or
replacing the singleton with an injected instance so the existing decorator can
reach it. The singleton is the obstacle: `SecureStorage.getInstance()` has
callers that hold no `Preferences` at all.

### 3.5 The update path writes and launches a binary, ungated

`packages/centroidx_upgrader/lib/src/manager_launcher.dart:159` writes the
centroidx-manager binary to disk and `:160` renames it into place; the caller is
`managerLauncher.launchForUpdate(...)` at `centroid-hmi/lib/main.dart:369`,
driven by the app's update affordance. No route gates it and no guard sees it.

This is the highest-consequence write in the sweep and the least like the
others: it is not configuration, it is code. It is recorded here rather than
fixed because the update flow is outside this milestone's scope entirely — the
spec does not mention it, and gating it is a product decision about who may
update a station, not an access-control mechanism question.

**What closing it would take.** Either an `administer` check at the update
affordance in `centroid-hmi/lib/main.dart`, or accepting it explicitly on the
grounds that the binary is signature-checked upstream. Somebody should decide
which; today neither has been decided, which is why this entry exists.

### 3.6 `lib/providers/theme.dart` — device-local UI state on the legacy API

Four `SharedPreferences.getInstance()` calls writing `theme_mode` and
`color_scheme`. Plan 03-01 classifies both as `operate`: they are what a panel
writes about itself, not plant configuration. The file is inside
`lib/providers/`, so spec §6's CI grep does not apply to it even once plan 03-11
extends that grep to the legacy API.

**What closing it would take.** Routing both notifiers through
`localPreferencesProvider` so the writes pass the guard and appear in the audit
trail. It is cheap; it is left open because the value is low — an `operate` key
an anonymous session may write anyway — and because moving it touches the theme
path, which every golden in the repository depends on.

### 3.7 `lib/pages/dbus_login.dart` — excluded by the spec

Two `SharedPreferences.getInstance()` calls writing five bare keys
(`connectionType`, `host`, `username`, `autoLogin`, `sshPrivateKeyPath`) and one
`secureStorage.write(key: 'dbus_password', ...)`.

Spec §2 excludes changing this file from the whole milestone, and says why: the
D-Bus credential is a **station** credential, the same kind of thing as the OPC
UA session and the Postgres login, and D-Bus is the mechanism *underneath*
`administer` rather than something `administer` governs. Plan 03-01 still
classifies all five keys as `administer`, so if the writes are ever routed
through the guard the classification is already there.

**What closing it would take.** Lifting the §2 exclusion, then the same
treatment as any other page. The exclusion is a decision, not an oversight.

### 3.8 `lib/widgets/tfc_operations.dart` — an unwired D-Bus operation-mode write

`callSetMode('running' | 'stopped' | 'cleaning')` at `:22`, `:24` and `:69`
changes the plant's operation mode over D-Bus from an app-bar button. It is
**not wired**: `OperationModeAppBarLeftWidgetProvider` is constructed nowhere,
and `globalAppBarLeftWidgetProvider` (`lib/widgets/base_scaffold.dart:36`)
defaults to null with no override anywhere in the tree.

Left open for two reasons. It writes nothing today. And if it were wired,
starting and stopping the line is an operator action by design — the first line
of `REQUIREMENTS.md`'s acceptance criteria is that an unauthenticated session
can jog, start and stop.

**What closing it would take.** Nothing, unless it is wired. If somebody wires
it, the cleaning-mode call is the one worth a second look — cleaning is a mode
change with process consequences, not a start/stop.

### 3.9 `GuardedPreferences.systemWrites`

Plan 03-05 gives `GuardedPreferences` a `systemWrites` getter returning a
`Preferences` whose write members skip the session check. It exists because five
writes fire at boot with nobody signed in, on keys that are not `operate`:

| Write | Key | Group | Owner |
|---|---|---|---|
| `lib/page_creator/page.dart:247` (unawaited, from `PageManager.load()`) | `page_editor_data` | `configure` | 03-06 |
| `lib/providers/state_man.dart:26` (`fetchKeyMappings`) | `key_mappings` | `configure` | 03-06 |
| `packages/tfc_dart/lib/core/state_man.dart:63` (`StateManConfig.fromPrefs`) | `state_man_config` | `administer` | 03-06 |
| `packages/tfc_dart/lib/core/alarm.dart:220` (`AlarmMan.create`) | `alarm_man_config` | `configure` | 03-06 |
| `lib/providers/collector.dart:27` (`collectorProvider`) | `collector_config` | `administer` | 03-09 |

Without `systemWrites` each of these is denied on a fresh station and the
station is broken in a way no screen shows — the page editor case takes the
pages away entirely.

**The residual risk.** It is a bypass by construction. Anything holding a
`GuardedPreferences` can reach it. The controls are that it is a distinct object
rather than a `system: true` flag (a flag is one keystroke from an operator
path), that every `systemWrites` write still produces exactly one audit row with
`origin: 'system'` and the group that *would* have been required, and that plan
03-06 caps the call sites: `kSystemWriteCallSites` in
`lib/providers/access_policy.dart` names every file allowed to use it, and a
test compares the grep result to that list in both directions.

**What closing it would take.** Removing the need for it — making the five boot
defaults lazy, or writing them under an explicit commissioning identity rather
than an anonymous session. Both are larger than this phase.

### 3.10 `GuardedPreferences.database`

`GuardedPreferences implements Preferences`, and `Preferences` declares a
`database` getter. The decorator must therefore supply one, so anything holding
the guarded object can write `guardedPrefs.database.db` and issue raw Drift —
past the guard it is holding.

**The control, stated exactly.** Section 3 of `scripts/sweep-write-paths.sh`
searches the `AppDatabase` type and the `.db` accessor, so such a call appears
in the sweep the first time it is written, and plan 03-12 fails when a hit has
no row here. That is a *detection* control, not a prevention: it finds the call
after it exists, on the next run.

**Why it is not preventable cheaply.** Dropping `implements Preferences` means
every caller changes, which is the whole reason the decorator idiom was chosen.
Returning null from the getter breaks the callers that legitimately need the
database handle (`preferences.database!.db` at
`packages/tfc_dart/lib/core/alarm.dart:338, 362`, among others).

**What closing it would take.** Splitting `Preferences` so that the database
handle lives on a narrower interface the decorator does not have to expose. That
is a refactor of `tfc_dart`'s core, not a guard change.

---

### 3.11 `/advanced/about-linux` gained writes after the census

The route census that produced `kRaisedRoutes` classified
`/advanced/about-linux` as a read-only page, and at the time it was one: the
only D-Bus client on it was constructed to *read* device state (§2.8).
Upstream #440 then added the system clock and NTP settings to it, so the page
now sets the station's time, timezone, RTC mode and NTP servers.

**Left open deliberately, and this is the reasoning rather than an oversight.**
Every call passes `allowInteractiveAuthorization: true`, which puts the
decision on **polkit** at the OS — the boundary that actually holds for
system-level state, and the one the HMI container already has rules for. The
NTP server list itself is a device-local preference, per-station like the
startup URL. And the change arrived on main *after* this milestone's census:
raising the route here would take an operator's clock away as a side effect of
a rebase, which is a product decision belonging to the owner of #440.

What would settle it either way: decide whether the clock is `administer`
(most of `/advanced` is) or stays an operator affordance, then either raise
the route or split the clock section onto a page that is already raised.

### 3.12 The relay was a third enforcement point that graded the same rows differently — Phase 17 made it consume the one master

This entry existed because the 2026-09-05 re-run found seventeen files whose
guard this document had no word for, and it recorded three ways the relay's
grading disagreed with the app's over the same tables. **Phase 17 closed the
disagreement.** The entry is kept in the shape §3.1 and §3.3 used when they
closed — the evidence stays, what closed it is stated, and what did *not* close
is stated too — because a section that closed by rounding its open half away is
the defect this document exists to prevent.

**The model, in one paragraph, as it now stands.** A relay write starts as a
JSON-RPC frame on a `wss://` socket. `RelaySession` registers every method
through one seam, `_on`, which applies the handshake gate: a frame arriving
before `hello` reaches no handler at all. `hello` hands the client's token to a
`TokenValidator`, which either refuses the connection or resolves it through a
`UserResolver` into a `StationIdentity` — an `AuthenticatedUser` (station
account) plus the station name plus the `AccessSession` the account's role
resolves to, the groups chased through `app_role` in the database (D-06). The
token file names a **user** and grants nothing; the role, and the groups behind
it, are the database's answer. `RelaySession` builds one `PolicyStateMan` per
session and hands *that* — never the shared plant source — to every handler
object, so a handler added later cannot reach around the policy. Inside it,
`_requireGroup` asks the **one master `AccessPolicy`** which `AccessGroup` a
surface needs and refuses unless the session holds it, fails closed on a null
identity, and throws a `forbidden` whose message says the call definitively had
no effect and must not be retried. It is the same policy object, asked the same
question, the app's `GuardedPreferences` and `guarded_history_views.dart` ask.

**So `session-gated (relay policy)` now means "one enforcement point consuming
the one master system", not "a third policy".** It is a real guard, at a real
seam, with a fail-closed default, and it grades by the same `AccessPolicy` the
app does.

**The three disagreements, and what became of each.**

1. **Graded by station role, not by key — CLOSED (D-03).** The seven
   `_PolicyPreferences` mutators no longer ask one flat `role == operate`
   question. `AccessPolicyKeyPolicy` asks `AccessPolicy.groupForPref(key)` and
   then `session.can(group)` — the identical call the app's `GuardedPreferences`
   makes against the identical `kPrefAccessRules`. `key_mappings` and
   `page_editor_data` take `configure`; `collector_config`,
   `state_man_config` and `server_config_envelope` take `administer`;
   `theme_mode`, `startup_url` and the rest take `operate`. The evidence that
   this was a real seam stays on the record; the seam is gone. **The behaviour
   change it cost, named:** a station whose role holds only `operate` can no
   longer save `key_mappings` over the pipe — the honest consequence of the
   ruling that the app's grading wins everywhere, and the reason engineering
   panels are provisioned with a `configure`-holding role (17-CONTEXT, ruled by
   Jón 2026-09-07). The unrestricted-`clear` refusal stays — a volume control,
   not a policy, unchanged by who is asking.
2. **Wrote no audit row — CLOSED (D-05).** `RelayServer` now takes an
   `AuditSink`, and `composeBackendRelay` injects `DriftAuditSink(database.db)`
   — the same sink shape and the same `audit_entry` table the app's
   `auditSinkProvider` builds. Every `PolicyStateMan` decision writes a row,
   **allowed and refused**, with `origin = 'relay'` so a trail reader tells a
   wire write from a panel write, and the deny row is written **before** the
   refusal is thrown, because a refusal that leaves no trace is the one kind of
   guard nobody can audit afterwards. The failure `policy_state_man.dart` once
   named as the blocker is closed.
3. **`createHistoryView` ungated and unbounded — the AUTHORITY half CLOSED
   (D-04), the VOLUME half deliberately STILL OPEN.** The five history-view
   mutators now follow the app's own split: `createHistoryView`,
   `updateHistoryView` and `addHistoryViewPeriod` are open; `deleteHistoryView`
   and `deleteHistoryViewPeriod` take `configure` — the app's grading, so
   deleting a saved chart over the wire now takes `configure`, matching direct
   mode. That closes the authority question: the wire and the panel refuse the
   same deletes. It does **not** close the volume question — a station may
   still create history views without limit in a shared table, and that is an
   authority fix, not a quota. It stays open with its reason: the gate stops a
   station building its own chart, a quota does not, and no quota is written.
   Stated as open on purpose, because a section that reported this half closed
   would be describing a system that does not exist.

**The permissive default, updated because the claim it makes is now larger.**
`RelayServer`'s `validator` still defaults to `PermissiveTokenValidator`, but it
can no longer mint `Role.operate` — there is no `Role`. It mints a
`StationIdentity` whose role name is `kPermissiveRoleName` (`'Permissive
(development)'`) resolving to the **full** `AccessGroup` set — every group, a
larger grant than the old operate-only default made, and named for what it does
so a gateway still running it is legible in a config diff, with `exposureWarning`
logging before the bind (D-07). A real deployment gets real identities through
`ServerConfig.auth.token_file`, which `RelayServer.start()` loads before the
port opens and refuses to start without a `UserResolver` (D-06); the constructor
still refuses a configuration carrying both a validator and an `auth` section.

**This entry no longer stops `session-gated (relay policy)` being read as "and
it agrees with the app's" — it now records that it DOES agree**, on one
`AccessPolicy`, and names the one half (history-view volume) that is a separate
piece of work rather than a disagreement.

## 4. Is there a fifth?

**Yes.** Spec §6's four are each owned by a plan in this phase. Beyond them the
sweep found five further things, listed here by name with who owns each.

### 4.1 New, and owned by no plan in this phase

**A. Three raw-Drift index classes reachable from the ungated Knowledge Base
page.** `DriftTechDocIndex`, `DriftPlcCodeIndex` and `DriftDrawingIndex` in
`packages/tfc_mcp_server/lib/src/services/`, called from
`lib/tech_docs/tech_doc_upload_service.dart:104, 149, 221-222, 275`,
`lib/tech_docs/tech_doc_library_section.dart:1075, 1133` and
`lib/drawings/drawing_upload_service.dart:46, 61, 75`. An anonymous session on
`/advanced/knowledge-base` can delete a technical document, delete a PLC asset's
index and rewrite `page_editor_data`. **This is the fifth bypass, and it is the
same shape as the fourth**: a destructive control on a page classified as a read
surface. Owners: **plan 03-13** (the controls, through guarded store objects)
and **plan 03-14** (the route, raised to `configure` as the seventh entry in
`kRaisedRoutes`). **Closed** — see §3.1, which keeps the evidence and records
the accepted cost.

**B. An ungated write-and-launch of the manager binary.**
`packages/centroidx_upgrader/lib/src/manager_launcher.dart:159`, reached from
`centroid-hmi/lib/main.dart:369`. Owner: none. Priced in §3.5.

**C. An unwired D-Bus operation-mode write.**
`lib/widgets/tfc_operations.dart:22, 24, 69`. Writes nothing today because
nothing constructs its provider. Owner: none. Priced in §3.8.

**F. A NetworkManager write helper the first run did not have a row for.**
`lib/core/network_manager_ops.dart:86` (`client.settings.addConnection`) and
`:107` (`client.activateConnection`). Found by plan 03-12's re-run, comparing
the script's hits against this document's rows **by file** in both directions —
the first mechanical reconciliation this document has had.

**It is not a sixth bypass class.** The file's only importer anywhere in the
tree is `lib/pages/ip_settings.dart:10`, so every one of these calls is reached
from `/advanced/ip-settings`, which `kRaisedRoutes` raises to `administer`. The
verdict is `route-gated (Phase 2)`, identical to the `ip_settings.dart` rows in
§2.8 that this document already carried.

**It is still a finding, and the useful kind.** The file was committed on
2026-08-27 (`ae4c60fa`, the ip-settings bond fix) — *before* the 2026-08-29
sweep, not after it. So the first run's grep found these lines and the human
writing §2.8 did not give them a row: the section listed the page and missed
the helper the page calls. That is the §6-fourth-bypass failure in miniature,
and it says something about this document rather than about the tree: **a
verdict list assembled by reading is a list with holes in it, and only the
mechanical both-directions comparison finds them.** `test/core/phase_03_coverage_test.dart`
is that comparison, and it now fails on the next such omission instead of
waiting for somebody to notice.

### 4.2 Beyond §6's list, but already owned

**D. Nine further `SharedPreferencesAsync()` constructions outside
`lib/providers/`.** Spec §6 names `lib/providers/collector.dart:21`. The script
finds twelve constructions in eight files; three are inside `lib/providers/`
(two of them the sanctioned ones in `preferences.dart`), and the other nine are:
`lib/core/update_channel.dart:23, 35`,
`lib/tech_docs/tech_doc_library_section.dart:1194`, `lib/pages/page_view.dart:253`,
`lib/widgets/preferences.dart:556, 825`,
`lib/widgets/panes/color_picker_dialog.dart:42, 66` and
`centroid-hmi/lib/main.dart:269`. Owner: plan 03-11, whose own table already
names each. `lib/widgets/preferences.dart:556` is a dead field with no other
reference in the file.

**Closed and enforced.** All nine are gone. Eight were rerouted to
`createDeviceLocalPreferences()` or `localPreferencesProvider`; the dead field
was deleted. `scripts/check-preferences-construction.sh` found these nine and
now finds none, and the `flutter-test` job fails on a tenth.

**E. Six legacy `SharedPreferences.getInstance()` calls.** An API spec §6 does
not mention and its proposed CI check would not catch:
`lib/providers/theme.dart:15, 22, 44, 51` and `lib/pages/dbus_login.dart:124, 141`.
Owner: plan 03-11, which extends the check to the legacy API. Both files stay
open on purpose — §3.6 and §3.7.

**Enforced.** The check searches for this pattern under the same
outside-`lib/providers/` rule. `theme.dart` passes on the directory rule;
`dbus_login.dart` is the check's single allow-list entry, carrying §2's
exclusion as its reason. A seventh call anywhere else fails the build.

### 4.3 Where the answer was "nothing further"

Recorded so a later phase does not repeat the search or, worse, assume it:

- **The raw Drift statement API (script §2, 116 hits).** Beyond
  `lib/core/server_config_db.dart` and the three index classes of finding A,
  **nothing further found**. Every other hit is the store's own implementation,
  a drift `Migrator` callback, the audit sink, the access repository, or a
  `.delete(` / `.update(` on something that is not a database.
- **`AppDatabase` handles (script §3, 60 hits).** Seven accessor spellings exist
  in the tree — `adb`, `dbWrap.db`, `db.db`, `dbWrapper.db`, `_tsDb!.db`,
  `database!.db`, `preferences.database!.db` — and every one is accounted for in
  2.3. **Nothing further found**: no eighth spelling, and no handle that leads to
  a write not already listed.
- **File writes (script §7, 3 hits).** Three in the entire tree, all three in
  2.7. **Nothing further found.**
- **The preference key inventory (script §9).** Every key expression resolves to
  a rule in `kPrefAccessRules`; **no key the app writes rests on the
  `administer` default.** See §5.

### 4.3a What the 2026-08-30 re-run found

Recorded as a result rather than as a reassurance, because an unrecorded
negative gets assumed next time rather than trusted.

The re-run's hits were reconciled against this document's table rows by file,
in both directions. Seven files carried hits with no row:

| File | Hits | What it turned out to be |
|---|---|---|
| `lib/core/guarded_history_views.dart` | 12 | plan 03-10's guard — new, and the shape a closed bypass has |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart` | 12 | plan 03-05's guard — new; its two holes were already priced in §2.10 without a file and line, and now have one |
| `lib/core/network_manager_ops.dart` | 7 | **the one genuine finding — §4.1 F.** Pre-dated the first run and had no row |
| `packages/tfc_dart/lib/core/preferences_watch.dart` | 3 | already covered in 2.3, but named by bare filename; now a full path |
| `packages/tfc_dart/lib/core/secure_storage/interface.dart` | 1 | same — 2.6 named it by bare filename |
| `lib/providers/alarm.dart` | 1 | plan 03-06's seventh system-write site — new |
| `lib/core/guarded_knowledge_stores.dart` | 1 | plan 03-13's guard — new |

In the reverse direction **one** row had no hit —
`packages/tfc_dart/lib/core/database_drift.g.dart`, which the script collapses
to a counted `[generated]` line by design and therefore never emits as a
`file:line` hit. No row was stale.

**Beyond finding F, nothing further found.** No new write surface, no new
accessor spelling that is not a guard this phase added, and no site whose
verdict this document cannot state.

### 4.3b What the 2026-09-05 re-run found

Recorded in the shape of §4.3a, and for the same reason.

Seventeen files carried hits with no row, and every one is in the five relay
packages. Grouped by what they turned out to be:

| Files | Hits | What they turned out to be |
|---|---|---|
| `data_handlers.dart`, `policy_state_man.dart` | 25 | the gateway's handler bodies and the policy decorator above them — the guard and the seam it sits at (§3.12) |
| `history_view_store.dart`, `preference_store.dart`, `timescale_reader.dart`, `timescale_sink.dart` | 25 | the gateway's stores: two write, one only reads, one only opens the pool |
| `client_sub_apis.dart`, `state_man_api.dart` | 10 | the client's proxy and the wire interface's declarations — no store in either |
| `collection_runner.dart`, `collection_plan_resolver.dart`, `opcua_upstream_link.dart` | 4 | broad-grep false positives: an in-memory health publisher, a local `Map`, an OPC UA client teardown |
| the six `tfc_stateman_contract` files | 44 | a test kit whose code lives in `lib/` so five packages' tests can import it |

**No unguarded write path was found in the relay.** Every wire-reachable
mutator passes `PolicyStateMan`, which fails closed on a null identity, and
every handler is registered through the one seam that applies the handshake
gate. That is the answer to the question this document exists to ask, and it is
recorded as a result rather than left to be inferred from an absence of alarm.

**Three things were found that are not that**, and all three are in §3.12: the
relay grades `flutter_preferences` rows by station role where `kPrefAccessRules`
grades them by key, so `key_mappings` takes `operate` over the pipe and
`configure` at a panel; no relay write produces an audit row; and
`createHistoryView` is ungated and unquotaed while its four siblings are gated.
The first is the one worth somebody's decision.

**What the run says about this document rather than about the tree.** The
seventeen files had no rows because the vocabulary had no term for them, not
because anybody skipped them — the previous run predates the relay branch. That
is a different failure from §4.1 F's, and a milder one: F was a file the grep
found and a human did not write down, this was a file the grep found and the
five available verdicts all misdescribed. The mechanical check caught both,
which is the argument for it either way.

### 4.3c What the 2026-09-07 re-run found

Recorded in the shape of §4.3a and §4.3b, and for the same reason. Five files
carried hits with no row, fifty hits between them. This run also changed the
gate itself: sabotaging one of the new rows stayed green because the coverage
test read claims out of **every** table's first cells, and this section's own
summary table was discharging the §2 obligation. The extraction is narrowed
to §2 and §3 now — §1 carries the rule — so a run record like this one can
name files freely and prove nothing by naming them. The narrowing turned no
file red: the 2026-08-30 cohort §4.3a lists by full path all have their real
§2 rows, so the double-claims were redundancy rather than missing verdicts,
verified by re-running the suite the moment the extraction changed.

| Files | Hits | What they turned out to be |
|---|---|---|
| `backend_data_services.dart`, `backend_alarm_history.dart`, `backend_composition.dart` (under `packages/tfc_dart/lib/core/relay`) | 47 | the **centroidx-backend** — a second server-side composition, serving history views, preferences and the alarm engine's `alarm_history` rows through the **same** per-session `PolicyStateMan` §3.12 describes (`relay_session.dart:367`, `:908`) |
| `relay_alarm_source.dart` (under `lib/core`) | 2 | the gateway-mode panel's alarm source: one `configure` write through the guarded preferences (03-06), one read-only handle on `alarm_history` (spec §11's deferral) |
| `gateway_link_status.dart` (under `lib/core`) | 1 | a broad-grep false positive, from the one section-2 pattern that had never fired before: `replace(` exists for drift's row-replacing `replace()` and matched `Uri.replace` stripping a credential out of a rendered URL |

**No unguarded write path was found**, and the sentence carries the same
weight it carried in §4.3b because the same construction produces it: the
composition hands `RelayServer` one `BackendStateMan` and every session sees
it only through its own `PolicyStateMan`. Two facts are worth more than the
negative:

- **The alarm acknowledge is gated at the handler, not in the decorator.**
  `Methods.ackAlarm` — the wire's first operator action that is not a write —
  asks `PolicyStateMan.canWrite(AlarmKeys.active)` inside
  `AlarmHandlers.acknowledge`, the same predicate and the same object a
  `write` asks, fail-closed on a null identity. That is a *fourth* gate site
  wearing the third enforcement point's answer, and the §2.2 row for
  `backend_alarm_history.dart:335` records it so `session-gated (relay
  policy)` cannot be read as "requireOperate somewhere above".
- **§3.12 now describes two compositions, and everything in it transfers.**
  `composeBackendRelay` names `AllVisibleOperatorWrites` outright
  (`backendRelayPolicy`), so the role-not-key preference grading, the absent
  audit row and the ungated, unquotaed `createHistoryView` are all exactly as
  true of the backend as of `tfc_relay_local`'s gateway — over the same
  `flutter_preferences` table `kPrefAccessRules` grades by key. Nothing new
  to decide; the same decision now applies in two binaries.

### 4.3d What the 2026-09-08 re-run found (Phase 17 complete)

Recorded in the shape of §4.3a–c. This run is not a fresh grep for a fifth
guard; it is the record of what Phase 17 changed in the tree, on this
document's own terms, so §3.12's rewrite above is not left as an appendix to
somebody else's run.

| Files | Change | What it turned out to be |
|---|---|---|
| `access_handlers.dart` (`tfc_relay_server/lib/src`) | +1 file, twenty-eight members | the four access families on the wire (17-09), each decode-and-delegate, no check of its own — the gate is the `PolicyStateMan` decorator it holds. Rowed in §2.2. 17-14 reconciled its `value`/`role`/`query` decode envelope with the client encoder (F-3): the flat-map decode it shipped with hard-failed every real client on five single-DTO methods |
| `backend_config_store.dart` (`tfc_dart/lib/core/relay`) | the tree's **fifth** file write | the backend's `StateManConfig` file, `.previous` backup and atomic temp (17-10, D-10), graded `administer` over the wire. §2.7's "four file writes" count is corrected to five. Standing gap: served sessionlessly today (17-11 dev 3), 17-13's to complete |
| `backend_composition.dart`, `bin/main.dart` (`tfc_dart`) | audit sink, account resolver, revocation poll wired | the shipping graph now carries the real `AccessPolicyKeyPolicy`, the `DriftAuditSink`, and the `UserResolver`; `bin/main.dart` polls `reloadTokensIfChanged` on the config-watch tick, closing SEC-03's revocation clause that had never fired in production (D-08, 17-11) |
| the three stores (17-02) | moved into `tfc_dart/lib/core/access` | one implementation serves direct and gateway mode; `no_duplicate_access_stores_test.dart` and, from 17-14, `no_second_policy_test.dart` pin that it stays one |

**The largest fact is a negative, as §4.3b's was:** no new unguarded write path
was found, and none was created. The relay's three graded-differently rows
(§3.12) were **closed** onto the one master `AccessPolicy` rather than left
standing — two fully (D-03 preference grading, D-05 audit trail) and one on its
authority half (D-04 history-view delete), with the history-view volume question
named as the single deliberately-open half.

**What the run says about the document rather than about the tree:** §3.12's
title and closing line were both now false and are rewritten; the
`session-gated (relay policy)` verdict definition named two deleted types
(`Identity.role`, `Role.operate`) and is redefined without them, the vocabulary
staying at seven terms; §2.7's counted claim of "four file writes" was made
false by the config store and is corrected to five. Every one of those is a
claim a reader could check and would have found wrong — the class of hole this
document exists to close, and the reason §4.3c was itself written.

### 4.4 What §5 checked and did not find

The rule this document is meant to enforce — *a key the app writes in normal
operation may not rest on the `administer` default* — is satisfied. Every one of
the thirty-odd key expressions **the app** writes is matched by an explicit
rule. There is no finding of that shape to raise here.

The 2026-09-05 re-run added five relay rows to §5 that the rule does not reach,
and the reason is not that they slipped past it: the gateway is a different
process and does not consult `kPrefAccessRules` at all. The rule as written is
about a key falling through to a default; the relay's keys do not fall through
to anything, they are graded by station role. §3.12 is the finding, and §5's
own closing paragraph says which of the two claims each row supports.

There is a related risk that is **not** a rule violation and is named anyway,
because it is the same failure with a different cause: five keys are written at
boot by an anonymous session on groups that session does not hold
(`page_editor_data`, `key_mappings`, `state_man_config`, `alarm_man_config`,
`collector_config`). Under a fail-closed guard with no escape hatch, every one
of them is denied on a fresh station. Plan 03-05's `systemWrites` and plan
03-06's wiring exist for exactly these five, and 03-09 covers the last. §3.9
lists them with their owners.

---

## 5. Config keys, reconciled

One row per key expression from script section 9, against `kPrefAccessRules` in
`packages/tfc_access/lib/src/access_policy.dart`. **Plan 03-01 landed while this
sweep ran**, so this reconciles against the code rather than against plan text.
Plan 03-12 checks the reconciliation again.

The **when** column is the point of the table. A write that fires before anybody
can sign in, or merely because an operator opened a page, is a different risk
from one behind a Save button.

| Call site | Expression as written | Resolves to | Rule in `kPrefAccessRules` | Group | When |
|---|---|---|---|---|---|
| `startup_url.dart:24, 26` | `startupUrlPrefsKey` | `startup_url` | exact `startup_url` | `operate` | behind a control |
| `update_channel.dart:36` | `updateChannelPrefsKey` | `update_channel` | exact `update_channel` | `administer` | behind a control |
| `chat_widget.dart:189` | `kSelectedProvider` | `llm.selected_provider` | prefix `llm.` | `administer` | behind a control |
| `chat_widget.dart:361` | `prefKey` (switch on provider) | `llm.claude.api_key`, `llm.openai.api_key`, `llm.gemini.api_key` | prefix `llm.` | `administer` | behind a control |
| `chat_widget.dart:392, 394` | `urlPrefKey` (ternary) | `llm.claude.base_url`, `llm.openai.base_url` | prefix `llm.` | `administer` | behind a control |
| `providers/state_man.dart:26` | `'key_mappings'` | `key_mappings` | exact `key_mappings` | `configure` | **boot-time** — `fetchKeyMappings` writes a default when absent |
| `providers/collector.dart:27` | `Collector.configLocation` | `collector_config` | exact `collector_config` | `administer` | **boot-time** — default written when absent |
| `providers/access.dart:694` | `kAccessSessionPrefKey` | `access.session` | exact `access.session` | `operate` | **read-path** — every `poke()`, i.e. every pointer-down |
| `providers/chat.dart:340, 370, 405, 449, 525, 905` | `'$kConversationPrefix$id'` | `chat.conversation.<id>` | prefix `chat.` | `operate` | behind a control |
| `providers/chat.dart:529, 548` | `kConversationList` | `chat.conversations` | prefix `chat.` | `operate` | behind a control |
| `providers/chat.dart:532, 558` | `kActiveConversation` | `chat.active_conversation` | prefix `chat.` | `operate` | behind a control |
| `providers/chat.dart:453, 494, 505, 535, 538` | `kChatHistory` | `chat.history` | prefix `chat.` | `operate` | behind a control, plus a one-time migration |
| `providers/theme.dart:23` | `_key` (`ThemeModeNotifier`) | `theme_mode` | exact `theme_mode` | `operate` | behind a control — **legacy API; never reaches the guard**, §3.6 |
| `providers/theme.dart:52` | `_key` (`ColorSchemeNotifier`) | `color_scheme` | exact `color_scheme` | `operate` | behind a control — same |
| `tech_doc_upload_service.dart:267` | `'page_editor_data'` | `page_editor_data` | exact `page_editor_data` | `configure` | **delete-path** — rewritten when a tech doc is deleted, from an ungated route (§3.1) |
| `tech_doc_library_section.dart:1203` | `key` (a `PrefsReader` parameter) | `page_editor_data` — the adapter's only caller is the row above | exact `page_editor_data` | `configure` | same |
| `key_repository.dart:637, 1933` | `'key_mappings'` | `key_mappings` | exact `key_mappings` | `configure` | behind a control, on a `configure`-gated route |
| `page_view.dart:264` | `'asset_stack_config'` | `asset_stack_config` | exact `asset_stack_config` | `operate` | **read-path** — written when the key is absent, on mount of any asset page |
| `dbus_login.dart:127-131` | five literals | `connectionType`, `host`, `username`, `autoLogin`, `sshPrivateKeyPath` | five exact rules | `administer` | behind a control — **legacy API**, §3.7 |
| `page_creator/page.dart:247` | `storageKey` | `page_editor_data` | exact `page_editor_data` | `configure` | **boot-time, unawaited** — a denial here surfaces as an unhandled async error and a default that never persists |
| `page_creator/page.dart:252` | `storageKey` | `page_editor_data` | exact | `configure` | behind a control |
| `page_creator/page.dart:257` | `orderStorageKey` | `page_editor_top_level_order` | exact `page_editor_top_level_order` | `configure` | behind a control |
| `image_store.dart:96, 129` | `'$keyPrefix$id'` | `page_editor_image:<id>` | prefix `page_editor_image:` | `configure` | behind a control |
| `page_creator/assets/common.dart:444` | `'key_mappings'` | `key_mappings` | exact | `configure` | behind a control |
| `recipes.dart:269` | `'${widget.config.recipesBucket}.recipes'` | `<bucket>.recipes` | suffix `.recipes` | `setpoints` | **read-path** — `_getRecipes` writes an empty default, so an anonymous operator merely opening a recipes asset triggers it |
| `recipes.dart:281` | same expression | `<bucket>.recipes` | suffix `.recipes` | `setpoints` | behind a control |
| `widgets/preferences.dart:949-957, 979, 981` | `e.key` | **cannot be resolved to a literal or a prefix** — the key is whatever row the operator is editing, so the group is whatever rule matches at runtime | every rule, at runtime | varies | behind a control, on the `administer`-gated `/advanced/preferences` |
| `color_picker_dialog.dart:66` | `prefsKey` | `color_picker_recent_colors` | exact `color_picker_recent_colors` | `operate` | behind a control (confirming a colour) |
| `tfc_dart/core/state_man.dart:442` | `configKey` | `state_man_config` | exact `state_man_config` | `administer` | **boot-time** — `StateManConfig.fromPrefs` writes a default when absent |
| `tfc_dart/core/state_man.dart:450` | `configKey` | `state_man_config` | exact | `administer` | behind a control |
| `tfc_dart/core/state_man.dart:626` | `'key_mappings'` | `key_mappings` | exact | `configure` | behind a control |
| `tfc_dart/core/alarm.dart:220` | `'alarm_man_config'` | `alarm_man_config` | exact `alarm_man_config` | `configure` | **boot-time** — `AlarmMan.create` writes a default when absent |
| `tfc_dart/core/alarm.dart:303` | `'alarm_man_config'` | `alarm_man_config` | exact | `configure` | behind a control — `addAlarm`/`removeAlarm`/`updateAlarm` only. **`ackAlarm` writes nothing**, so this rule does not stand between an operator and an alarm ack |
| `read_toggles.dart:38, 114` | `McpConfig.kPrefKey` | `mcp.config` | prefix `mcp.` | `administer` | over MCP, not from a widget (§3.2) |
| `lib/core/preferences.dart:54-84` | `key` (a parameter) | pass-through — `SharedPreferencesWrapper` delegates the caller's key | n/a | the caller's | n/a |
| `tfc_dart/core/preferences.dart:344-585` | `key` / `entry.key` (parameters) | pass-through — the cache fan-out inside `Preferences` | n/a | the caller's | n/a |
| `config_service.dart:64` | `_prefCache.clear()` | **not a preference key** — `_prefCache` is a `TtlCache` (`:45`) | n/a | n/a | n/a |
| `data_handlers.dart:688, 704, 732, 745, 778` | `key` (`params['key'].asString`) | **cannot be resolved** — whatever key the client sent | **none: `kPrefAccessRules` is not consulted in this process** | the relay's flat `operate` | over the pipe, behind `requireOperate` (§3.12) |
| `policy_state_man.dart:993, 1005, 1013, 1020` | `key` (a parameter) | pass-through, gated then delegated | same | same | same |
| `preference_store.dart:425-441, 525` | `key` (a parameter) | pass-through — the store delegates the caller's key to `tfc_dart`'s `Preferences` | same | same | same |
| `relay/backend_data_services.dart:950-966, 1091-1107` | `key` (a parameter) | pass-through — the centroidx-backend's store and adapter, gated then delegated | same | same | same |
| `core/relay_alarm_source.dart:400` | `'alarm_man_config'` | `alarm_man_config` | exact `alarm_man_config` | `configure` | behind a control — the gateway-mode alarm editor's `addAlarm`/`removeAlarm`/`updateAlarm`, never `ackAlarm`, exactly as `tfc_dart/core/alarm.dart:303` above |
| `served_state_man.dart:672-716`, `broken_browse.dart:177-192` | `key` (a parameter) | pass-through, in the test kit | n/a | n/a | `test-kit only` |
| `data_services_contract.dart:390-551` | `_prefKey`, `_clearedKey`, `'svn.chart.maxPoints'`, `'svn.weigher.tolerance'`, `'svn.site.name'`, `'svn.page.recent'` | the contract suite's own literals | **no rule, and none is wanted** — these keys exist only inside a test run | n/a | `test-kit only` |

**The relay's five rows were the exception this table did not have before, and
Phase 17 resolved it.** The app's key expressions resolve to a rule because the
app consults `kPrefAccessRules`; **the relay now consults the same table**, via
`AccessPolicyKeyPolicy` → `AccessPolicy.groupForPref(key)` → `session.can(...)`
(D-03, 17-07/17-11). They are no longer graded by a different policy in a
different process — they are graded by the one master policy, and §3.12 records
how they came to agree. The one row that mattered concretely is `key_mappings`,
which this table grades `configure` and which **the pipe now serves at
`configure` too** — the change landed with D-03 (17-07/17-11, merged
2026-09-08), and the honest cost is that a station whose role holds only
`operate` can no longer save key mappings over the wire.

**One key is written outside section 9 and belongs in this table anyway.**
`server_config_envelope` (`lib/core/server_config_db.dart:55`) is written
through raw Drift today, so no `set*` search finds it; it has an exact rule
resolving to `administer`, and plan 03-08 turns it into a `setString` call that
this table's search *will* find on the next run.

**The reconciliation's result.** Every resolvable key expression is matched by
an explicit rule. **No key the app writes in normal operation rests on the
`administer` default.** The one unresolvable expression — `e.key` in the raw
preference editor — is unresolvable by construction rather than by omission, and
sits behind an `administer`-gated route.

The five bold **boot-time** rows and the three **read-path** rows are the ones
that would have broken a plant, and they are why the `when` column exists. Their
owners are in §3.9.

---

## 6. What this sweep does not cover

Read this before treating the table above as an inventory.

It is a **static text search of the Dart sources in this repository**. It does
not cover reflection, code generated at build time, native plugin channels,
platform channels into Swift/Kotlin/C++, or anything a future package brings in.
It searches `lib`, `centroid-hmi/lib`, `demo` and `packages/*/lib`, and nothing
else — not `test`, not `build`, not `tool`, not the Go manager, not the PLC
sources in `~/Projects/sildarvinnsla`.

Three deliberate limits inside the search itself:

- **Comment-only lines are dropped.** A commented-out call that somebody
  restores is a site the sweep would not have reported until it was restored.
- **Hits in generated files are collapsed to a counted line per file.** The
  counts are printed, so a generated file acquiring hits in an unexpected
  section is visible, but the individual lines are not listed.
- **Section 9b filters `remove` and `clear` by receiver spelling**
  (`pref` / `prefs` / `preferences`). That is a filter on a name, which is the
  exact failure mode this script was built against — a `PreferencesApi` held in
  a field called `_store` would not match it. Section 9c exists as the
  compensation: it prints the census of every receiver 9b dropped, 110 distinct
  spellings, so the omission is scannable rather than silent. It is a weaker
  control than the searches around it, and it is the first place to look if a
  missed preference write is ever found.

**It does not prove a site is unreachable from a widget.** Where a row says
`not widget-reachable` it names the reasoning — a drift `Migrator` callback, a
generated binding with no caller, a `TtlCache` rather than a store — and the
reasoning is checkable by the next reader. That is not the same as a proof, and
this document does not claim it is.

**It searches one repository, and since 2026-09-05 that repository holds two
programs.** The relay packages are a separate Dart backend; the script sweeps
them because its roots are `packages/*/lib`, and the rows for them are as good
as the rows for the app. Two limits follow and neither is fixable by a wider
grep. A `session-gated (relay policy)` verdict is a statement about the code,
and what the gate *distinguishes* depends on a token file named in a gateway
config that is not in this repository at all — §3.12 says so and names the
default. And `test-kit only (dev dependency)` rests on the dependency graph as
declared today: it is checked by `handler_table_test.dart`'s sweep of the
server's production sources and by five `dev_dependencies` entries, so a
package promoting `tfc_stateman_contract` out of dev would make six rows wrong
at once. That is a real hazard and the honest mitigation is that it would be
one line in one `pubspec.yaml`, visible in a diff.

No sentence here says the enumeration is complete. The entire reason this
document exists is that the last such claim was wrong: §6 named three, a fourth
was in the tree the whole time, and §4 above names a fifth. Assume there is a
sixth, re-run `scripts/sweep-write-paths.sh`, and add its rows.

Spec §6 is **not modified by this document**. It is authoritative input to this
phase and plan 03-11 owns any amendment; findings A, B and C in §4.1 are
candidates for it.
