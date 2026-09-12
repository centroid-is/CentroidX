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
than waiting to be read about. The script's own
header records its two output conventions: comment-only lines are dropped (a
comment is not a call, which is why `centroid-hmi/lib/main.dart:449` quoting
`adb.deleteHistoryView` in a note is not a site), and hits inside generated
files are collapsed to a counted line per file rather than listed. Both are
limits on the search and both are restated in §6 below.

**The answer to "is there a fifth?" is yes**, and it is in §4. The largest new
finding is a family the spec never mentions: three raw-Drift index classes in
`packages/tfc_mcp_server`, called directly from the Knowledge Base page, which
Phase 2 deliberately left ungated because it reads as a read surface. Plans
03-13 and 03-14 close it at the controls and at the route; §3.1 records both,
and the operational cost of the second.

---

## 2. The table

The verdict vocabulary is fixed at five terms. Every row carries exactly one;
no row is blank and no row says "probably".

| Verdict | Meaning |
|---|---|
| `guarded by NN-NN` | a plan routes it through a guard. `03-NN` for the plans in this phase; one later row carries `06-03`, which closed §3.3 |
| `route-gated (Phase 2)` | reachable only from a route in `kRaisedRoutes` |
| `not widget-reachable` | provider or core machinery with no path from a widget; the row says which and why the claim holds |
| `correct as-is` | the audit sink, the guards themselves, and the stores' own declarations |
| `left open: <reason>` | found, understood, and deliberately not closed |

Where a file carries many calls of one shape, the row names the shape and lists
the lines, because that is how plan 03-12 compares — by file and call.

### 2.1 Named Drift write helpers on `AppDatabase` (script §1 — 44 hits at the 2026-08-29 run, 54 at the 2026-08-30 re-run)

The ten new hits are plan 03-10's guard, which declares the same five method
names and delegates to them. That is the shape a guard has, and it is why the
count going **up** is the expected outcome of closing a bypass rather than a
regression.

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

**Both accessors were present, and both moved.** At the first run `:1108` used
`adb` and `:1165` used `dbWrap.db`; the script found both because section 1
searches the *method names*, not a receiver spelling — the exact mistake
`.planning/phases/02-route-gating/deferred-items.md` §4 names. Spec §6 listed
two of these five; all five were here, and plan 03-10 moved all five onto
`store.`, which is why every line number in this block changed between the two
runs and none of the calls did. **This is the reason the reconciliation is by
file and call rather than by line.**

### 2.2 Raw Drift statement API (script §2 — 116 hits at the 2026-08-29 run, 113 at the 2026-08-30 re-run)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/core/server_config_db.dart:58` | `db.into(db.flutterPreferences).insertOnConflictUpdate(...)` | `flutter_preferences` | `ServerConfigDb.publish()` ← `lib/pages/server_config.dart:3224` | `guarded by 03-08` |
| `lib/core/server_config_db.dart:85-87` | `(db.delete(db.flutterPreferences)..where(...)).go()` | `flutter_preferences` | `ServerConfigDb.remove()` | `guarded by 03-08` |
| `packages/tfc_dart/lib/core/access/drift_audit_sink.dart:75` | `_db.into(_db.auditEntry).insert(...)` | `audit_entry` | `auditSinkProvider` (`lib/providers/access.dart:104`) | `correct as-is` — append-only and retention-exempt by design; the class doc explains why, and this sweep does not restate it |
| `packages/tfc_mcp_server/lib/src/services/drift_tech_doc_index.dart:65, 230-236, 242, 251-253, 260, 306, 322` | `_db.into(...)`, `_db.delete(...)`, `_db.update(...)` | tech-doc tables | **`lib/tech_docs/tech_doc_upload_service.dart:104, 149, 221-222, 275`**, wired at `lib/providers/tech_doc.dart`, driven by the Knowledge Base page | `guarded by 03-13`, and `route-gated (03-14)` besides — see §3.1 |
| `packages/tfc_mcp_server/lib/src/services/drift_plc_code_index.dart:84, 102, 121, 154, 169, 189, 257-276, 565` | `_db.into(...)`, `_db.delete(...)`, `_db.update(...)` | PLC index tables | **`lib/tech_docs/tech_doc_library_section.dart:1075` (`reindexAsset`) and `:1133` (`deleteAssetIndex`)**, wired at `lib/providers/plc.dart:65` | `guarded by 03-13`, and `route-gated (03-14)` besides — see §3.1 |
| `packages/tfc_mcp_server/lib/src/services/drift_drawing_index.dart:56, 68, 89-97, 219, 232` | `_db.into(...)`, `_db.delete(...)` | drawing tables | `lib/drawings/drawing_upload_service.dart:46, 61, 75`, wired at `lib/providers/drawing.dart:14`; `DrawingUploadDialog` has **no caller in the tree today** | `guarded by 03-13` — reachable in principle, unwired in fact, and guarded either way; the route it would be reached from is `route-gated (03-14)`. See §3.1 |
| `packages/tfc_mcp_server/lib/src/audit/audit_log_service.dart:47, 85` | `_db.into(_auditLog).insert(...)`, `_db.update(_auditLog)` | `audit_log` (MCP's own) | `TfcMcpServer`, which runs **in the HMI process** (`lib/mcp/mcp_bridge_notifier.dart:266`, `lib/mcp/mcp_sse_server.dart:56`) | `left open: reached over MCP, not from a widget` — see §3.2 |
| `lib/core/access_template_store.dart:286, 324, 383, 439-441, 498, 531-533` | `_db.into(...).insert` / `.insertOnConflictUpdate`, `_db.update(...)`, `_db.delete(...)` on the two v7 tables | `access_template`, `access_key_binding` | `AccessTemplateStore`, driven by the key repository (04-07, 04-08) and by accepted MCP proposals (04-09) | `correct as-is` — this **is** the guard; `kAccessTemplateGroup` (`users`) is checked and the audit row written above every one of these, over **both** tables. The binding lives in its own table rather than in the `configure`-gated key-mapping blob precisely so the gate is true of the data (ruled 2026-08-30, reversing spec §7b) |
| `lib/pages/access_templates_section.dart:635, 1130` | `store.update(...)`, `store.delete(...)` | `access_template` | `AccessTemplatesSection`, mounted in `KeyRepositoryContent` (04-07) | `correct as-is` — these are calls **on `AccessTemplateStore`**, one row above, not on a database: the `users` gate and the audit row are inside them. Caught by the deliberately broad `.update(`/`.delete(` grep and recorded rather than filtered away, which is the point of the grep being broad. The section writes no binding at all — `bind`/`unbind` are 04-08's, per key |
| `packages/tfc_dart/lib/core/access/access_repository.dart:358, 373, 412, 545, 552-554, 590, 645, 722, 754-755, 781, 814, 890` | `db.into/update/delete` on `app_role` / `app_user` | roles and users | `accessAdminStoreProvider` (06-04), which wraps `accessRepositoryProvider`; and `lib/pages/first_user.dart:141` for the first-user window alone | `guarded by 06-03` — `AccessAdminStore` asks `kAccessAdminGroup` (`users`) and writes a row, refusals included, above every one of the nine writes that reach these statements. The repository is not decorated: it owns the transaction and the last-`users`-holder invariant that must be evaluated inside it — see §3.3 |
| `packages/tfc_dart/lib/core/preferences.dart:210, 254, 428` | `secureStorage.delete(key:)`, `db.customInsert(...)`, `database!.db.customUpdate(...)` | secure store, `flutter_preferences` | inside `Preferences` — the implementation `GuardedPreferences` wraps | `correct as-is` — these are the store the guard decorates; the check happens above them |
| `packages/tfc_dart/lib/core/sqlite_preferences.dart:403, 415, 452, 470` | `_db.into(_db.configItemTable).insert(...)`, `(_db.update(_db.configItemTable)..where(...)).write(...)`, `_db.into(_db.configChangeTable).insert(...)`, `(_db.delete(_db.configItemTable)..where(...)).go()` | `config_item` and `config_change` in this station's `config.sqlite` | `createDeviceLocalPreferences()` / `localPreferencesProvider` — every device-local preference in the app, and `Preferences.syncToLocalCache` mirroring the shared store down (milestone v1.2, plans 01-03 and 01-05) | `correct as-is` — this **is** the device-local store, at exactly the trust level of the `SharedPreferencesWrapper` it replaced (whose row left this table with `lib/core/preferences.dart` itself, deleted by milestone v1.2 plan 01-06): the path into it is `localPreferencesProvider`, which is *deliberately* unguarded because the session is stored through it and a check there would need a session to read the session. v1.2 opens no write path and closes none — same keys, same callers, a different file. Two things a reader must not conclude from the new tables: the `config_change` row every write appends is a **local** change log that never reaches `audit_entry`, and it is unattributed on purpose (`who: 'anonymous'`, `role_name: ''`, stated in the class doc); and the *shared* values that reach this store through `syncToLocalCache` were checked above `GuardedPreferences` before they were mirrored, so this is the cache fan-out rowed in 2.9, not a second way in |
| `packages/tfc_dart/lib/core/config/config_store.dart:262, 296, 334-336, 413, 444-464, 556-579` | `remote.into(remote.configItemTable).insert(...)`, `(remote.update(remote.configItemTable)..where(… & rev.equals(…))).write(...)`, `(remote.delete(remote.configItemTable)..where(…)).go()`, `db.into(db.configChangeTable).insert(...)`, and the same four against `_local` for the mirror and the re-home | `config_item` and `config_change` — the **shared** rows in Postgres, and their mirror in this station's `config.sqlite` | `ConfigStore`, the key-mapping repository added by milestone v1.2 plan 02-01. **Nothing in the widget tree reaches it yet**: it has no provider, and the five `key_mappings` write sites still go through `GuardedPreferences` | `correct as-is` — this is the store a guard decorates, at the same layer `Preferences` sits at under `GuardedPreferences`. It performs no access check and writes no `audit_entry` row **by design**, stated in its own library doc: `AccessPolicy`, `AccessSession` and `AuditSink` all need a session and `tfc_dart` core has none, so the attribution (`actionId`, `who`, `roleName`, `reason`) arrives as parameters and the check happens above. The wrapper that supplies it lands in plan 02-05 of the same milestone, and the row here should be re-read then. Three things a reader must not conclude: the `config_change` rows this writes to the **remote** are the shared history and *do* join `audit_entry` by `action_id` (unlike `sqlite_preferences.dart`'s local, unattributed ones two rows up); the mirror writes against `_local` append no change rows at all, because duplicating the shared history locally would be two histories of one event; and the `rev.equals(…)` on every update and every delete is a compare-and-swap rather than a filter — a lost one throws out of the transaction so drift issues ROLLBACK |
| `packages/tfc_dart/lib/core/config/key_mapping_migration.dart:82, 102` | `copyBlobIntoRows(remote.db, …)`, `copyBlobIntoRowsLocked(db, …)` | `config_item` and `config_change` — the **shared** rows in Postgres, through the row below | `migrateKeyMappingsBlobToRows(Database)`, the one-shot key-mappings migration added by milestone v1.2 plan 02-03 and wired into the remote-attach path by 02-05, which runs before `runApp` | `not widget-reachable` — since plan 03-03 this file issues **no statement of its own**: it names the preference key, the lock id, the marker id and the parser, and the transaction, the lock, the gate, the sort keys and the marker-last ordering are the `blob_migration.dart` row below. The verdict there covers both callers. The reader must not conclude that the delegation widened anything: the lock id (1), the marker (`_migrated.key_mappings`) and the outcomes are the ones 02-03 landed, and its integration suite is what proves the hoist changed nothing |
| `packages/tfc_dart/lib/core/config/blob_migration.dart:364, 377` | `db.into(db.configItemTable).insert(...)`, `db.into(db.configChangeTable).insert(...)` | `config_item` and `config_change` — the **shared** rows in Postgres | `copyBlobIntoRows(AppDatabase, {prefKey, markerId, lockId, kinds, parse, label})`, the generic blob→rows migration hoisted out of `key_mapping_migration.dart` by milestone v1.2 plan 03-03. Reached from the remote-attach path in `lib/providers/config_store.dart`, twice per attach: once for the key mappings and once for the pages, which is why the parse is a parameter | `not widget-reachable` — a boot-path data migration, not a surface, and the row `key_mapping_migration.dart` used to carry: the two statements moved here unchanged. It performs no access check and writes no `audit_entry` row, and neither is an omission — it runs before any session exists, on every station, from the attach path, and its rows say so (`updated_by`/`who` are the literal `'migration'`, `role_name` is `'system'`). Four things a reader must not conclude: the whole copy is inside **one** transaction whose first statement is `pg_try_advisory_xact_lock($1::int4, $2::int4)`, so two stations booting together cannot both write these rows; the marker `preference` row is written **last inside that same transaction**, so a process killed mid-copy rolls the rows and the marker away together; the `AppDatabase` in these statements is a **parameter**, not a handle the file holds, which is what the §4 hits on it are; and it never writes, rewrites or deletes the `flutter_preferences` blob it read — the blob stays put as rollback insurance until Phase 4 |
| `packages/tfc_dart/lib/core/config/preference_migration.dart` | `db.into(db.configItemTable).insert(...)`, `(db.update(db.configItemTable)..where(...)).write(...)`, `db.into(db.configChangeTable).insert(...)` | `config_item` and `config_change` — the **shared** rows in Postgres | `migratePreferencesIntoRows(Database)`, the last of the three migrations, added by milestone v1.2 plan 04-11 and wired into the remote-attach path in `lib/providers/config_store.dart` third, after its two siblings, whose markers it checks for before it writes anything | `not widget-reachable` — a boot-path data migration, the same verdict and the same reasons as `blob_migration.dart` above: no access check, no `audit_entry` row, `updated_by`/`who` the literal `'migration'` and `role_name` `'system'`, all of it inside one transaction whose first statement is `pg_try_advisory_xact_lock($1::int4, $2::int4)` under lock id 3. It does not delegate to that module because its input is every remaining row rather than one named blob. **Four things a reader must not conclude.** (1) It does **not** skip a key because a `config_item` row exists — a station on this branch writes rows from its boot defaults (D-7), so an existing row is usually an empty default sitting on top of the operator's real value; `flutter_preferences` is the authority and the row is overwritten, with the `rev` carried forward and bumped. Only the marker stops a second run. (2) The overwrite is logged as an `update` carrying the old side, so the boot default it replaced is restorable and the row does not contradict its own history. (3) Its marker **is** logged, unlike its two siblings' — deliberately, because `config_undo.dart` refuses any action containing an underscore-prefixed preference, so the marker's change row is what makes the whole migration unundoable as a unit; without it one `administer` click would delete every migrated row and leave the marker behind. (4) Images go to `page_image` rows keyed by the stored suffix **verbatim** and the envelope keeps its exemption, so neither writes a change row: routing either onto a `preference` row would put multi-megabyte payloads into a table nothing prunes (C-3), and re-deriving an image id from the bytes would orphan every asset that references the old one |
| `packages/tfc_dart/lib/core/config/config_change.dart:119, 150` | `factory ConfigChange.update({...})`, `factory ConfigChange.delete({...})` | — | nothing: a value class | `not widget-reachable` — not a store, and not a statement. Two named constructors on the immutable, row-shaped value that *describes* a change somebody else already decided; the file has no `into(`, no `.go()` and no drift import at all, and the rows it describes are written one row above. Caught by the same deliberately broad `.update(`/`.delete(` grep as `counts.update(...)` in the page editor and `_tracker.update(...)` in ip-settings, and recorded rather than filtered away for the same reason |
| `packages/tfc_dart/lib/core/database_drift.dart:374, 394, 444-527, 702-790, 847-856, 907, 990-1007, 1127-1317` | `into(...)`, `delete(...)`, `customStatement`, `customInsert` | every table | the database's own methods and migrations | `correct as-is` — this file *is* the store |
| `packages/tfc_dart/lib/core/database.dart:1127, 1647-1656` | `db.customStatement(...)` | timeseries DDL | `Database` table management | `not widget-reachable` — DDL run when a table is created or repaired, not from a control |
| `packages/tfc_dart/lib/core/alarm.dart:341` | `db.customInsert(r'''...''')` | alarm history | `AlarmMan` recording an alarm transition | `not widget-reachable` — driven by a PLC transition; the operator-facing ack path writes nothing here |
| `packages/tfc_mcp_server/lib/src/database/server_database.dart:376-389` | `customStatement(...)` | schema | migration callback | `not widget-reachable` — same as 2.1 |
| `lib/core/secure_storage/macos.dart:123, 152, 172`, `lib/core/secure_storage/other.dart:29`, `packages/tfc_dart/lib/core/secure_storage/linux.dart:52` | `_storage.delete(key:)` / `_legacy.delete(key:)` | OS keychain | the `MySecureStorage` implementations | `left open: secure storage is outside both guards` — see §3.4 |
| `lib/pages/ip_settings.dart:408, 1127` | `connection.delete()`, `connection.update(updatedSettings)` | NetworkManager | `/advanced/ip-settings` | `route-gated (Phase 2)` — `kRaisedRoutes` raises it to `administer` |
| `lib/pages/ip_settings.dart:588` | `_tracker.update(...)` | — | in-memory traffic-rate tracker | `not widget-reachable` — not a store; a false positive of a deliberately broad grep, recorded rather than filtered away |
| `lib/pages/page_editor.dart:3706` | `counts.update(asset.displayName, ...)` | — | an in-memory tally of asset kinds, for a label | `not widget-reachable` — not a store; the same broad-grep false positive as the row above. The editor's real persistence is `PageManager`, rowed in §2.9 |
| `lib/widgets/config_change_row.dart:183` | `byKind.update(record.change.kind, ...)` | — | an in-memory tally of how many entities of each kind one action changed, for the summary line `jon changed 3 assets` | `not widget-reachable` — not a store; the same broad-grep false positive as the two rows above. This file is v1.2 plan 04-06's configuration-history row widget: it renders `ConfigChangeRecord`s the read-only `ConfigChangeStore` returned and holds no handle, no statement and no sink. The enforcement for the surface it draws is the route gate `kRaisedRoutes['/advanced/config-history']` at `configure` |
| `packages/centroidx_upgrader/lib/src/manager_launcher.dart:170` | `staged.delete()` | filesystem | cleanup of a failed staging write; see 2.7 | `left open: the update path is ungated` — see §3.5 |
| `packages/tfc_dart/lib/core/state_man.dart:2175` | `wrapper.client.delete()` | — | OPC UA client teardown | `not widget-reachable` — not a store; disposes a connection |
| `lib/page_creator/assets/web_view.dart:311` | `uri.replace(query: ...)` | — | `withQueryParameter`, building the Web page asset's theme-following address | `not widget-reachable` — not a store; `Uri.replace` returns a copy of a value, matched by the `\breplace\(` alternation meant for drift's `replace`. Recorded rather than filtered away, like the rows above |

**Nothing further found** in this section beyond `server_config_db.dart`, the
three MCP index classes and the audit stores: every other hit is either the
store's own implementation, a migration, or a `.delete(`/`.update(` on
something that is not a database at all.

### 2.3 `AppDatabase` handles and the `.db` accessor (script §3 — 60 hits at the 2026-08-29 run, 55 at the 2026-08-30 re-run, plus 176 collapsed in `database_drift.g.dart` at both)

This section exists to catch a *new accessor spelling* the first time it
appears. It found no handle that is not already covered by 2.1 or 2.2. Rows
here are therefore grouped by what the handle is used for.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/history_view.dart:72, 1107, 1253, 1303` | `final adb = dbWrap.db` | `AppDatabase` | the history view | `guarded by 03-10` — the handle the five writes of 2.1 use |
| `lib/pages/history_view.dart:119, 138, 1217-1218` | `dbWrap.db.listHistoryViewPeriods/getHistoryViewKeys/getHistoryViewGraphs/getGlobalRetentionHorizon` | reads | the history view | `left open: read permissions are deferred` — spec §11 |
| `lib/providers/database.dart:17-29` | `AppDatabase.spawn(config)`, `db.db.open()/close()` | connection lifecycle | `databaseProvider` | `not widget-reachable` — opens and closes the connection; writes nothing |
| `lib/providers/access.dart:71, 104` | `AccessRepository(db.db)`, `DriftAuditSink(db.db)` | handles | `accessRepositoryProvider`, `auditSinkProvider` | `correct as-is` — the audit sink is the one direct Drift write that is correct by design |
| `lib/providers/mcp_bridge.dart:210`, `lib/providers/chat.dart:998, 1182`, `lib/providers/server_database.dart:13` | `dbWrapper.db` as `McpDatabase` | handle | MCP bridge and chat | `left open: reached over MCP, not from a widget` — see §3.2 |
| `lib/pages/server_config.dart:3209, 3224, 3258` | `ServerConfigDb.fetch(db.db)` / `publish(db.db, ...)` | `flutter_preferences` | `/advanced/server-config` | `guarded by 03-08` — and `route-gated (Phase 2)` besides |
| `lib/page_creator/assets/graph.dart:823-824`, `lib/providers/timeseries.dart:205, 208` | `db.db.enableNotificationChannel(...)`, `listenToChannel(...)` | LISTEN/NOTIFY | graph assets, the shared timeseries stream | `not widget-reachable` as a write — `enableNotificationChannel` issues DDL for a notify channel, not a data write; noted here rather than left silent |
| `lib/widgets/panes/database_stats_pane.dart:74, 86` | `db.db.config`, `db.db.customSelect(...)` | reads | the database stats pane | `left open: read permissions are deferred` |
| `packages/tfc_dart/lib/core/preferences.dart:213`, `packages/tfc_dart/lib/core/alarm.dart:557, 592`, `packages/tfc_dart/lib/core/database.dart:512-580`, `packages/tfc_dart/lib/core/access/access_repository.dart:98-100`, `packages/tfc_dart/lib/core/access/drift_audit_sink.dart:53` | `final db = ...!.db`, `AppDatabase db` fields | handles | core machinery | `correct as-is` — the stores holding their own handle. **Two of this row's entries are gone since milestone v1.2 plan 04-12.** `preferences_watch.dart` is deleted outright: it polled a digest over `flutter_preferences`, which the cutover retired, and its only production caller went in 04-11. `preferences.dart`'s own three Drift sites went with it — the upsert, the key-set select and the whole-table load were all that table — so what the sweep still finds there is the keychain delete, and the `database` field it keeps is a handle it carries for callers rather than one it uses. `alarm.dart`'s two moved rather than went: alarm history now reaches its handle through `AlarmMan.database` instead of through `preferences.database`, which is what let the acquisition backend stop holding a preferences object it only ever used to read one key |
| `packages/tfc_dart/lib/core/sqlite_preferences.dart:112`, `lib/providers/preferences.dart:29, 67, 156` | `final AppDatabase _db`, `AppDatabase? _deviceLocalDb`, `AppDatabase.createLocal(dir)`, `deviceLocalDatabase()` | the device-local `config.sqlite` | `SqlitePreferences`, and the process-wide handle `initDeviceLocalPreferences()` opens before `runApp` (v1.2 plan 01-05) | `correct as-is` — the store holding its own handle, and the one place the local database is opened. `_db` is the spelling `HistoryViewStore`, `AccessTemplateStore` and `AuditTrailStore` already use, so no ninth accessor; `_deviceLocalDb` is a **second `AppDatabase` instance** rather than a new accessor onto the shared one — the Postgres connection is still `databaseProvider`'s alone, and pointing the collector at this instance is refused by the factory's own doc. `deviceLocalDatabase()` (v1.2 plan 02-05) hands that same instance to `ConfigStore`, which needs Drift itself rather than the preference view of it; it constructs nothing new except on the degraded path where `config.sqlite` would not open at all, where it answers an in-memory database so the panel still boots |
| `packages/tfc_dart/lib/core/config/config_store.dart` | `required AppDatabase local`, `final AppDatabase _local`, `AppDatabase? _remote`, `_attach(remote.db)`, `attachRemote(Database)`, `attachRemoteDatabase(AppDatabase)` | two `AppDatabase` handles at once — the local `config.sqlite` and the Postgres connection | `ConfigStore` (v1.2 plan 02-01); the remote is attached rather than constructed, so a station that boots with Postgres unreachable holds a store with `_remote == null` | `correct as-is` — the handle the store of 2.2 writes through, and the same `_db`-family spelling `SqlitePreferences`, `HistoryViewStore` and `AccessTemplateStore` already use, so no new accessor. Two handles rather than one is the design: the local file is a **mirror** of the shared rows and the owner of this station's own, and the asymmetry in the two types is forced — `Database` carries the pool configuration and the connection-error classifier the write path needs, and cannot wrap a SQLite config at all. `attachRemoteDatabase` is `@visibleForTesting`: without it the compare-and-swap could only be exercised against a real Postgres |
| `packages/tfc_dart/lib/core/config/config_sync.dart` | `final AppDatabase _remote` | the Postgres handle, **read-only** | `_KeyMappingSync`, the sync engine added by milestone v1.2 plan 02-04. A `part` of `config_store.dart`, so it is the same library and the same store object; its life is one attachment and `detachRemote` throws it away | `correct as-is` — this file issues no write of any kind against the remote: it reads `config_change` from a watermark, reads `config_item` revisions and payloads, and hands what it read to the store. Every row it causes to be written is a **local** one and appears in this document already — the mirror and the watermark row, in the `config_store.dart` rows of 2.2. The reader must not conclude that a station pushes anything during a reconcile: the shared rows are Postgres-owned and the only path to them is the compare-and-swap in 2.2, which is why a station whose mirror disagrees with the server adopts the server's row rather than re-asserting its own |
| `lib/core/config/page_migration.dart:65, 81` | `remote.db` handed to `copyBlobIntoRows(...)`, `AppDatabase db` handed to `copyBlobIntoRowsLocked(...)` | the Postgres handle, **passed straight through** | `migratePageBlobToRows(Database)`, the pages-and-assets migration added by milestone v1.2 plan 03-03 and called from `lib/providers/config_store.dart`'s attach listener directly after the key-mappings one | `not widget-reachable` — a boot-path data migration. This file issues no statement and holds no handle: it is the page codec's `pageItemsFromBlob` plus four constants (the preference key `page_editor_data`, lock id 2, the shared marker `_migrated.pages`, and the kinds `{page, asset}`), because the parse needs Flutter and `tfc_dart` has none. Every write it causes appears in §2.2's `blob_migration.dart` row, under that row's verdict. Two things a reader must not conclude: the pages and the assets share **one** marker deliberately — they come out of one blob in one transaction, so a half-migrated state is unreachable — and it does not delete or rewrite `flutter_preferences.page_editor_data`, which `tools/svn_mirror_page.py` and `bin/page_geometry.dart` still read and which Phase 4 drops |
| `lib/core/guarded_history_views.dart:85, 98` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `historyViewStoreProvider` | `correct as-is` — the handle 2.1's guard delegates through; the check happens above it |
| `lib/core/access_template_store.dart:163, 176` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `AccessTemplateStore` | `correct as-is` — the handle 2.2's guard delegates through; the check happens above it. Same `_db` spelling as `HistoryViewStore`, so no ninth accessor |
| `packages/tfc_dart/lib/core/report_store.dart` | `_db.customStatement('INSERT INTO flutter_preferences ... ON CONFLICT DO UPDATE')` in `saveReports`/`saveShifts` | `flutter_preferences` (`report_config`, `shift_config`) | the report editor, through `GuardedReportStore` | `guarded by the report subsystem` — raw SQL rather than `PreferencesApi`, deliberately: the MCP server writes the same two rows and has no `Preferences`, so `GuardedPreferences` can never see them. `lib/core/guarded_report_store.dart` is the seam that checks `configure` and records both writes; `kPrefAccessRules` classifies the two keys to match. Reads stay open — generating a report is operate-level work |
| `lib/core/audit_trail_store.dart:413, 417` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `AuditTrailStore` | `correct as-is` — the handle Phase 5's **read-only** trail viewer holds. It is on this table because it names `AppDatabase`, not because it writes: the file contains no `into(`, no `update(` and no `delete(`, and `test/core/audit_trail_store_test.dart` asserts that on the source text rather than leaving it merely true today. The enforcement is the route gate `kRaisedRoutes['/advanced/audit-trail']` (05-07) and deliberately not a store check — a guard here would write a row into the trail every time somebody scrolled the trail, on the same reasoning `access_template_store.dart` gives for its own ungated reads. Same `_db` spelling as `HistoryViewStore` and `AccessTemplateStore`, so no ninth accessor |
| `lib/core/config_change_store.dart:339, 343` | `required AppDatabase db`, `final AppDatabase _db` | `AppDatabase` | `ConfigChangeStore` | `correct as-is` — the handle milestone v1.2's **read-only** configuration-history reader holds, and the exact counterpart of `lib/core/audit_trail_store.dart` two rows above. It is on this table because it names `AppDatabase`, not because it writes: the file contains no `into(`, no `update(` and no `delete(`, and `test/core/config_change_store_test.dart` asserts that on the source text. The pin matters more here than for the trail — `config_change` is on `kRetentionExemptTables`, so a row written through this object would never be swept. The enforcement is the route gate, on the same reasoning `access_template_store.dart` gives for its own ungated reads; a guard here would record a row every time somebody read the history. Same `_db` spelling as `AuditTrailStore` and `AccessTemplateStore`, so no ninth accessor |
| `lib/providers/access_templates.dart:109` | `db: db.db` | `AppDatabase` | `accessTemplateStoreProvider` | `correct as-is` — the provider that hands `AccessTemplateStore` its handle, one line, no statement of its own. Same `db.db` spelling `accessRepositoryProvider` and `auditSinkProvider` already use, so no ninth accessor |
| `lib/providers/audit_trail.dart:53` | `db: db.db` | `AppDatabase` | `auditTrailStoreProvider` | `correct as-is` — the provider that hands the **read-only** `AuditTrailStore` its handle, one line, no statement of its own. It is on this table because it names the `.db` accessor, not because it writes: the file contains no Drift statement at all, and `test/providers/audit_trail_test.dart` asserts on the source text that it holds no audit sink and performs no permission check. The enforcement is the route gate `kRaisedRoutes['/advanced/audit-trail']` (05-07), on the same reasoning `lib/core/audit_trail_store.dart` gives above. Same `db.db` spelling `accessRepositoryProvider`, `auditSinkProvider` and `accessTemplateStoreProvider` already use, so no ninth accessor |
| `lib/providers/config_history.dart:64` | `db: db.db` | `AppDatabase` | `configChangeStoreProvider` | `correct as-is` — the provider that hands the **read-only** `ConfigChangeStore` its handle, one line, no statement of its own, and the exact counterpart of `lib/providers/audit_trail.dart` above. It is on this table because it names the `.db` accessor: the file contains no Drift statement at all, and `test/core/config_change_store_test.dart` asserts on the source text that it holds no audit sink, no session and no timer. The enforcement is the route gate. Same `db.db` spelling `auditTrailStoreProvider` already uses, so no ninth accessor |
| `packages/tfc_dart/lib/core/database_drift.g.dart` (176 occurrences) | generated `_$AppDatabase` boilerplate | — | drift codegen | `not widget-reachable` — regenerated from `database_drift.dart`, which is searched above; collapsed by the script and counted |

**Seven accessor spellings at the 2026-08-29 run — `adb`, `dbWrap.db`,
`db.db`, `dbWrapper.db`, `_tsDb!.db`, `database!.db` and
`preferences.database!.db` — and an eighth at the 2026-08-30 re-run:
`HistoryViewStore._db` (`lib/core/guarded_history_views.dart:98`).** All eight
are covered above. The eighth is a guard this phase added rather than a store
this phase missed, which is the distinction this section exists to make
visible: a new spelling is reported either way, and the reader decides which
kind it is.

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
| `lib/providers/preferences.dart` — the factory | `createDeviceLocalPreferences()`, which since milestone v1.2 plan 01-05 **constructs nothing**: it returns the one `SqlitePreferences` that `initDeviceLocalPreferences()` opened before `runApp`, and throws a `StateError` when that has not run | device-local | the two preference providers, and every site below that has no `ref` | `correct as-is` — the one place that is meant to construct the store, and after 03-11 the only one. The file no longer imports `shared_preferences` and no longer produces a hit in *this* section at all; it keeps its row here because this is where the sanctioned site is recorded, and it now appears in the sweep under 2.3, holding the `AppDatabase` |
| `lib/providers/collector.dart:21` | `final prefs = SharedPreferencesAsync()` | device-local | `collectorProvider`, at boot | `enforced by 03-09` — spec §6 bypass 2; gone from the tree, and the check would refuse its return |
| `lib/core/update_channel.dart:29, 41` | `prefs ?? createDeviceLocalPreferences()` | device-local | `readUpdateChannel` / `writeUpdateChannel`, called as tear-offs from `centroid-hmi/lib/main.dart:337, 372` and `lib/widgets/preferences.dart:79-80` | `enforced by 03-11` — the parameter is a `PreferencesApi` now, so the tear-off form is unchanged |
| `lib/pages/page_view.dart:259` | `late final PreferencesApi prefs = ref.read(localPreferencesProvider)` | device-local | every asset page, on mount | `enforced by 03-11` — a `ref` exists, so it reads the provider rather than the factory |
| `lib/widgets/preferences.dart:556` | field on `_DatabaseConfigEditorState` | device-local | nothing — `grep -n sharedPreferences lib/widgets/preferences.dart` returned this line and no other | `enforced by 03-11` — **deleted**, not rerouted; confirmed unreferenced first |
| `lib/widgets/preferences.dart:822` | `ref.read(localPreferencesProvider)` in `_loadData` | device-local | the preferences page, read path (`localPrefs.getAll()`) | `route-gated (Phase 2)` — `/advanced/preferences` is `administer`; the construction is `enforced by 03-11` |
| `lib/widgets/panes/color_picker_dialog.dart:46, 70` | the factory, inline in two statics | device-local | any colour picker, anywhere in the app | `enforced by 03-11` — both statics keep their `try`/`catch`, so a broken store is still an empty strip |
| `centroid-hmi/lib/main.dart:273` | `createDeviceLocalPreferences()`, after the `await initDeviceLocalPreferences()` that opens the store and runs the one-shot import (v1.2 plan 01-05) | device-local | app boot, feeding `PageManager(prefs:)` and `pageManager.load()` on the next two lines | `enforced by 03-11` — this is the boot write of `page_editor_data` outside any provider; no `ProviderScope` exists yet, so it calls the factory |
| `lib/core/device_local_store.dart:139` | `SharedPreferencesAsync().getAll()` | device-local — **read only** | `readLegacySharedPreferences`, called once at boot by the one-shot import into the relational config store (milestone v1.2, plan 01-04) | `allow-listed` — the **second** entry in the check, added after the census above. It is the only site that reads the legacy store rather than writing it: nothing is written through this handle, every write goes to `SqlitePreferences`, and neither standard fix applies (there is no `ref` at that point in boot, and the factory returns the store being imported *into*). Time-limited by construction — the entry leaves with the `shared_preferences` dependency after the compatibility release (phase 4). Confirmed to be doing work: the check exits 1 on this line without it |

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
| ~~`lib/providers/theme.dart:15, 22, 44, 51`~~ | ~~`await SharedPreferences.getInstance()`~~ | device-local | the theme and colour-scheme notifiers | `closed (v1.2 plan 01-06)` — both notifiers read `localPreferencesProvider`; see §3.6. The trust level is unchanged (that provider is deliberately unguarded), the store is not |
| ~~`lib/pages/dbus_login.dart:124, 141`~~ | ~~`await SharedPreferences.getInstance()`~~ | device-local | the D-Bus login form | `closed (v1.2 plan 01-06)` — `loadSavedDbusCredentials` has no `ref` and calls `createDeviceLocalPreferences()`; `_saveCredentials` reads `localPreferencesProvider`. The check's one allow-list entry for this file is deleted with it; see §3.7 |

### 2.6 Secure storage (script §6 — 33 hits at the 2026-08-29 run, 35 at the 2026-08-30 re-run)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/dbus_login.dart:134` | `secureStorage.write(key: 'dbus_password', ...)` | OS keychain | the D-Bus login form | `left open: secure storage is outside both guards` — see §3.4 and §3.7. Untouched by v1.2 plan 01-06, which moved the file's five *preference* keys and deliberately left the password where it is |
| `packages/tfc_dart/lib/core/database.dart:214-215, 226` | `SecureStorage.getInstance().write(key: _configLocation, ...)` | OS keychain | `DatabaseConfig` persistence, from `/advanced/server-config` and `/advanced/preferences` | `route-gated (Phase 2)` — both routes are `administer`; the store itself stays outside the guards, see §3.4 |
| `packages/tfc_dart/lib/core/preferences.dart:205` | `secureStorage.write(key: key, value: value)` | OS keychain | `Preferences.setString(..., secret: true)` | `correct as-is` — inside the object `GuardedPreferences` wraps, so the check happens above it |
| `lib/core/secure_storage/macos.dart:118, 139, 144`, `lib/core/secure_storage/other.dart:24`, `packages/tfc_dart/lib/core/secure_storage/linux.dart:47` | `_storage.write(key:, value:)` | OS keychain | the platform implementations behind `MySecureStorage` | `left open: secure storage is outside both guards` — see §3.4 |
| `packages/tfc_dart/lib/core/secure_storage/secure_storage.dart:10-30`, `packages/tfc_dart/lib/core/secure_storage/interface.dart:1`, `packages/tfc_dart/lib/tfc_dart_core.dart:22`, `centroid-hmi/lib/main.dart:244` | the singleton, the interface, the barrel export of the interface, and the one `setInstance` at boot | — | — | `not widget-reachable` — type declarations, an export line, and one boot-time platform selection; no key is written |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart:436, 650` | `MySecureStorage get secureStorage => _inner.secureStorage` | — | anything holding the guarded object | `left open: secure storage is outside both guards` — the same hole as §3.4, reached through the decorator's own forwarding getter. Two hits because the checked path and `systemWrites` each forward it |

### 2.7 File writes (script §7 — 3 hits)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/key_repository.dart:1886` | `file.writeAsString(jsonString)` | filesystem | key-mapping export, `/advanced/key-repository` | `route-gated (Phase 2)` — `configure` |
| `lib/pages/server_config.dart:2923` | `.writeAsString(...convert(envelope))` | filesystem | server-config export, `/advanced/server-config` | `route-gated (Phase 2)` — `administer` |
| `packages/centroidx_upgrader/lib/src/manager_launcher.dart:159` | `staged.writeAsBytes(bytes)` | filesystem | `managerLauncher.launchForUpdate(...)` at `centroid-hmi/lib/main.dart:369` | `left open: the update path is ungated` — see §3.5 |

**Nothing further found** in this section: three file writes in the whole tree,
all three identified, two of them already behind a raised route.

### 2.8 D-Bus — network and hostname (script §8 — 31 hits at the 2026-08-29 run, 34 at the 2026-08-30 re-run)

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/pages/ip_settings.dart:263, 919-925, 1107-1125` | `activateConnection`, `deactivateConnection`, `addAndActivateConnection`, `settings.addConnection` | NetworkManager over D-Bus | `/advanced/ip-settings` | `route-gated (Phase 2)` — spec §6 bypass 3, gated at the route with the D-Bus call itself deliberately untouched |
| `lib/pages/ip_settings.dart:39, 68, 84, 399, 819, 1048` | `NetworkManagerClient` fields and construction | — | the same page | `route-gated (Phase 2)` |
| `lib/pages/about_linux.dart:98` | `nm.NetworkManagerClient(bus: ...)` | — | `/advanced/about-linux` (read-only page) | `not widget-reachable` as a write — the client is constructed to *read* device state; no write member is called in that file |
| `lib/core/network_manager_ops.dart:86, 107` | `client.settings.addConnection(settings)`, `client.activateConnection(device:, connection:)` | NetworkManager over D-Bus | `lib/pages/ip_settings.dart:10` — the **only** importer in the tree (`grep -rn network_manager_ops lib centroid-hmi/lib`), so `/advanced/ip-settings` | `route-gated (Phase 2)` — the same verdict as the rows above it, reached one file deeper. **This row was missing from the 2026-08-29 run and is the 2026-08-30 re-run's one genuine finding — see §4.1 F** |
| `lib/widgets/tfc_operations.dart:22, 24, 69` | `_operationMode.callSetMode('running' \| 'stopped' \| 'cleaning')` | `is.centroid.OperationMode` over D-Bus | `OperationModeAppBarLeftWidgetProvider`, which **nothing in the repository constructs** — `globalAppBarLeftWidgetProvider` (`lib/widgets/base_scaffold.dart:36`) defaults to null and is never overridden | `left open: unwired today, and start/stop is an operator action by design` — see §3.8 |
| `lib/core/system_clock.dart:453-465, 538` | `callSetNTP`, `callSetTimezone`, `callSetLocalRTC`, `callSetTime`, `callSetRuntimeNTPServers` | systemd-timedated / systemd-timesyncd over D-Bus | `lib/widgets/system_clock_section.dart`, mounted on `/advanced/about-linux` | `left open: arrived from main after this milestone's route census` — upstream #440 gave the clock and NTP settings to a page the row below classified, correctly at the time, as read-only. Two things stand behind it today and neither is this milestone's gate: every call passes `allowInteractiveAuthorization: true`, so **polkit** decides at the OS, and the station's clock is not a plant control. Raising `/advanced/about-linux` is a product decision for the owner of #440 — a rebase is the wrong place to take an operator's clock away. See §3.9 |
| `lib/core/system_clock.dart:51-53` | `prefs.remove(ntpServersPrefsKey)`, `prefs.setStringList(ntpServersPrefsKey, ...)` | device-local | the same section, through `ref.read(localPreferencesProvider)` at `lib/pages/about_linux.dart:52, 60` | construction `enforced by 03-11` — the store comes from the provider rather than the factory. Device-local by design: NTP servers are a per-station choice, like the startup URL, so the write bypasses `GuardedPreferences` for the same reason those do |
| `lib/dbus/generated/timedate1.dart:101-116`, `lib/dbus/generated/timesync1.dart:131` | `callSetTime`, `callSetTimezone`, `callSetLocalRTC`, `callSetNTP`, `callSetRuntimeNTPServers` | systemd-timedated / systemd-timesyncd | `lib/core/system_clock.dart` — the only importer | `correct as-is` — generated D-Bus bindings. The verdict belongs at the caller, one row above, exactly as it does for the NetworkManager bindings; a generated proxy is transport, not a decision |
| `lib/dbus/generated/hostname1.dart:290-356` | `callSetHostname`, `callSetStaticHostname`, `callSetPrettyHostname`, `callSetIconName`, `callSetChassis`, `callSetDeployment`, `callSetLocation` | systemd-hostnamed | **no caller anywhere in the tree** | `not widget-reachable` — generated D-Bus bindings with zero call sites; a grep for each name outside this file returns nothing |
| `lib/dbus/generated/login1.dart:1140-1563` | `callSetUserLinger`, `callSetRebootParameter`, `callSetRebootToFirmwareSetup`, `callSetRebootToBootLoaderMenu`, `callSetRebootToBootLoaderEntry`, `callSetWallMessage` | systemd-logind | **no caller anywhere in the tree** | `not widget-reachable` — same |
| `lib/dbus/generated/operations.dart:88` | `callSetMode` declaration | — | the binding `tfc_operations.dart` calls | `correct as-is` — a generated binding; the call site is the row above |

### 2.9 Writes through the injected preferences interface (script §9 — 76 + 17 hits at the 2026-08-29 run, 89 + 18 at the 2026-08-30 re-run)

These are **not bypasses**. They are the surface plan 03-01 classifies, and the
reason they are enumerated is that neither a construction search nor a Drift
search produces a single hit for them. Every key expression below is resolved
in §5.

| File and line | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `lib/core/startup_url.dart:24, 26` | `prefs.remove/setString(startupUrlPrefsKey)` | preferences | the startup-page control | `guarded by 03-06` |
| `lib/core/update_channel.dart:42` | `p.setString(updateChannelPrefsKey, ...)` | preferences | the update-channel control | construction `enforced by 03-11`; the write itself is `guarded by 03-06` |
| `lib/chat/chat_widget.dart:189, 361, 392, 394` | `prefs.setString/remove(...)` | preferences | the chat provider-settings dialog | `guarded by 03-06` |
| `lib/providers/collector.dart:27` | `prefs.setString(Collector.configLocation, ...)` | preferences | `collectorProvider` at boot | `guarded by 03-09` |
| `lib/providers/access.dart:694` | `local.setString(kAccessSessionPrefKey, ...)` | device-local preferences | every `poke()`, i.e. every pointer-down | `guarded by 03-06` |
| `lib/providers/chat.dart:340, 370, 405, 449, 453, 494, 505, 525, 529, 532, 535, 538, 548, 558, 905` | `prefs.setString/remove(chat.*)` | preferences | chat conversation management | `guarded by 03-06` |
| `lib/providers/theme.dart:23, 52` | `prefs.setString(_key, ...)` | device-local, via `localPreferencesProvider` | theme and colour-scheme controls | `left open: device-local UI state` — see §3.6. Off the legacy API since v1.2 plan 01-06; still unguarded, because that provider is |
| `lib/tech_docs/tech_doc_upload_service.dart` | **gone from this section** — the cleanup no longer writes a preference at all | — | — | milestone v1.2 plan 03-05 moved it to the shared configuration store; its row is in §2.11, and the `PrefsReader` adapter it wrote through (`tech_doc_library_section.dart`, the `_SharedPrefsReader` field and its `setString`) is deleted along with the `GuardedPrefsReader` that wrapped it |
| `lib/pages/key_repository.dart:882, 2417` | `store.saveKeyMappings(...)` | **shared configuration store** | `/advanced/key-repository` — Save, and the JSON import | `guarded by 02-06` — `GuardedConfigStore`, and `route-gated (Phase 2)` besides. One `config_change` row per key that moved, one bounded `audit_entry` over the lot, on one `action_id` |
| `lib/pages/page_view.dart:270` | `prefs.setString('asset_stack_config', ...)` | device-local | every asset page, on the read path when the key is absent | construction `enforced by 03-11` — the store now comes from `localPreferencesProvider`; the write is unchanged and still once per mount |
| `lib/pages/dbus_login.dart:127-131` | `prefs.setString/setBool(...)` | device-local, via `localPreferencesProvider` | the D-Bus login form | `left open: station credentials, §2's reasoning survives the move` — see §3.7. Off the legacy API since v1.2 plan 01-06 |
| `lib/page_creator/page.dart:247` | `prefs.setString(storageKey, jsonString)` | preferences | `PageManager.load()` at boot, **unawaited** | `guarded by 03-06` — routed through `systemWrites` |
| `lib/page_creator/page.dart:252, 257` | `prefs.setString(storageKey \| orderStorageKey, ...)` | preferences | the page editor's save | `guarded by 03-06` |
| `lib/page_creator/assets/image_store.dart:96, 129` | `prefs.setString/remove('$keyPrefix$id')` | preferences | page-editor image add and delete | `guarded by 03-06` |
| `lib/page_creator/assets/common.dart:846` | `store.saveKeyMappings(next)` | **shared configuration store** | the `+` on any key field in the page editor | `guarded by 02-06` — `GuardedConfigStore`, `configure` on `pref`/`key_mappings`. The `prefs.setString('key_mappings', …)` this row used to name is gone, and with it C-10: it wrote into StateMan's own live map first, emptying the diff it was then measured by |
| `lib/providers/config_store.dart:43, 60, 108` | `ConfigStore(...)`, `GuardedConfigStore(...)` | **shared configuration store** | once per process, at provider build | `correct as-is` — this is the one construction site, and `scripts/check-preferences-construction.sh` enforces that it stays the only one (its fourth pattern, added by 02-06 and proved non-vacuous by a planted violation). The store cannot be a factory the way `createDeviceLocalPreferences()` is: its snapshot is what every mimic on the station is drawn from, so there must be exactly one per process |
| `packages/tfc_dart/lib/core/config/shared_row_preferences.dart:327, 346, 366, 388` | `_writer(...)` → `GuardedConfigStore.writePreference` / `writePreferenceAsSystem`, `_secretWriter(...)` → `writeSecret` / `writeSecretAsSystem` | **shared configuration store**, and the OS keychain for a secret | every shared preference write in the app: `preferencesProvider` has served this since milestone v1.2 plan 04-05, in place of `Preferences` over `flutter_preferences` | `correct as-is` — it holds **no** policy, session or audit sink of its own and cannot: every one of its four write paths is a call into the guard one row down, which is where the check happens and where the `action_id` shared by the `audit_entry` and the `config_change` rows is minted. It is deliberately **not** wrapped in `GuardedPreferences` — two wrappers would be two audit rows and two ideas of who wrote one value. Three things a reader must not conclude: a secret still never reaches a row and neither side of its value reaches the trail, but the write **is** checked and recorded; the replace set every write passes is the whole shared preference set, marker rows included, because `writeItems` replaces within a kind; and the system arm no-ops rather than throws when Postgres is unreachable, because a boot default is written on the strength of "storage is empty", which an offline station has not learned |
| `packages/tfc_dart/lib/core/access/guarded_config_store.dart:213, 251, 275, 357` | `save`, `saveKeyMappings`, `seedDefaultIfEmpty` → `_inner.writeKeyMappings` | **shared configuration store** | every operator configuration write, plus the boot seed | `correct as-is` — this **is** the guard. Check → write → audit, deliberately the reverse of `GuardedPreferences`, because this store can still refuse after the check passes (offline, unsafe pool, another station won the row) and a row written first would claim a save that never happened. `seedDefaultIfEmpty` is the `systemWrites` analogue: no check, `origin: 'system'`, still one audit row |
| `lib/page_creator/assets/recipes.dart:269` | `prefs.setString(prefKey, jsonEncode(recipes))` | preferences | `_getRecipes` on the **read** path | `guarded by 03-06` |
| `lib/page_creator/assets/recipes.dart:281` | `prefs.setString(prefKey, ...)` | preferences | `_saveRecipes`, behind a control | `guarded by 03-06` |
| `lib/widgets/preferences.dart:949-957, 979, 981` | `target.setBool/setInt/setDouble/setStringList/setString(e.key, ...)`, `prefs.remove(e.key)`, `localPrefs.remove(e.key)` | preferences and device-local | the raw preference editor on `/advanced/preferences` | `route-gated (Phase 2)` — `administer`; the key is whatever the operator typed, see §5 |
| `lib/widgets/panes/color_picker_dialog.dart:70` | `createDeviceLocalPreferences().setStringList(prefsKey, ...)` | device-local | confirming a colour anywhere in the app | construction `enforced by 03-11`; the write stays on the deliberately unguarded device-local store |
| `packages/tfc_dart/lib/core/preferences.dart:344-413, 485-493, 524-532, 565-585` | `_memoryCache.set*`, `localCache?.set*`, `cache.set*` | in-memory and device-local caches | inside `Preferences` | `correct as-is` — the cache fan-out below the guard |
| `lib/providers/alarm.dart:28` | `systemPrefs.setString('alarm_man_config', ...)` | preferences | `alarmManProvider` at boot, writing the empty default | `guarded by 03-06` — routed through `systemWrites`, and one of the seven sites `kSystemWriteCallSites` names. New since the 2026-08-29 run |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart:335, 348, 361, 373, 385` | the five checked `set*` members, each delegating to `_inner.set*` | preferences | every caller of `preferencesProvider` | `correct as-is` — this **is** the guard; the check and the row happen above the delegation |
| `packages/tfc_dart/lib/core/access/guarded_preferences.dart:532, 545, 558, 570, 582` | the same five members on `systemWrites`, with the session check skipped | preferences | the boot defaults of §3.9 | `left open: the deliberately unchecked write path` — §2.10 and §3.9 price it; this row is the file and line it lives at |
| `packages/tfc_dart/lib/core/state_man.dart:442` | `prefs.setString(configKey, ..., secret: true, saveToDb: false)` | secure store | `StateManConfig.fromPrefs` at boot when the key is absent | `guarded by 03-06` — routed through `systemWrites` |
| `packages/tfc_dart/lib/core/state_man.dart:450` | `prefs.setString(configKey, ...)` | secure store | `StateManConfig.toPrefs`, behind a control | `guarded by 03-06` |
| `packages/tfc_dart/lib/core/state_man.dart:626` | `prefs.setString('key_mappings', ...)` | preferences | key-mapping save | `guarded by 03-06` |
| `packages/tfc_dart/lib/core/alarm.dart:220` | `preferences.setString('alarm_man_config', ...)` | preferences | `AlarmMan.create` at boot when the key is absent | `guarded by 03-06` — routed through `systemWrites` |
| `packages/tfc_dart/lib/core/alarm.dart:303` | `preferences.setString('alarm_man_config', ...)` | preferences | `addAlarm`/`removeAlarm`/`updateAlarm`/`setAutoNavigate`, behind the `configure`-gated alarm editor. **Not** `ackAlarm` | `guarded by 03-06` |
| `packages/tfc_mcp_server/lib/src/tools/read_toggles.dart:38, 114` | `prefs.setString(McpConfig.kPrefKey, ...)`, `local.setString(...)` | preferences and device-local | an MCP tool call, in the HMI process | `left open: reached over MCP, not from a widget` — see §3.2 |
| `packages/tfc_mcp_server/lib/src/services/config_service.dart:64` | `_prefCache.clear()` | — | `invalidateCache()` | `not widget-reachable` — `_prefCache` is a `TtlCache` (`config_service.dart:45`), not a preferences store. A false positive of section 9b's receiver-spelling filter, recorded rather than quietly dropped |

### 2.10 Two rows that exist because of this phase's design

These are not search results. They are holes the guards themselves open, and
they get rows so that they are visible rather than implied.

| Site | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| `GuardedPreferences.systemWrites` (plan 03-05) | the seven write members with the session check skipped | preferences | the boot defaults enumerated in plan 03-06 | `left open: the deliberately unchecked write path` — see §3.9 |
| `GuardedPreferences.database` (plan 03-05) | `guardedPrefs.database.db` → any raw Drift statement | every table | anything holding the guarded object | `left open: \`implements Preferences\` forces the getter` — see §3.10 |

### 2.11 Writes through the shared configuration store (script §10 — 5 hits, new at the v1.2 phase 2 run)

New because the store is new. Milestone v1.2 phase 2 moved the plant's key
mappings out of `flutter_preferences.key_mappings` and into one `config_item`
row per key, and a write through that store matches **nothing** above: it is
not a `setString`, it carries no key literal at the call site, and it touches
no Drift API there either.

That is worth stating plainly, because of what the sweep would otherwise have
reported. `lib/pages/key_repository.dart` and
`lib/page_creator/assets/common.dart` both went quiet in §2.9 during this
phase — their `prefs.setString('key_mappings', …)` calls are gone — and
without §10 the report would have shown two fewer preference writes and called
it progress, while the most consequential writes in the app carried on through
a path it could not see. Same failure as an empty §2.4 after the store
changed name; arriving by migration rather than by deletion.

`packages/tfc_dart/lib/core/state_man.dart` lost its `key_mappings` row here
rather than gaining a new verdict, for the reason 02-05 removed
`lib/providers/state_man.dart`'s: `KeyMappings.fromPrefs` is deleted, so the
write the row named does not exist, and a row for a call site the script
cannot find fails the coverage test in the reverse direction. The file keeps
its `state_man_config` rows.

| Site | Call | Store | Reached from | Verdict |
|---|---|---|---|---|
| the four sites above | `saveKeyMappings`, `writeKeyMappings`, `seedDefaultIfEmpty` | shared configuration store | the key repository, the page editor's key field, and the boot seed | enumerated individually in §2.9's table — this section is the pattern that finds them, not a second set of rows |
| `lib/tech_docs/tech_doc_upload_service.dart` | `configStore.save(wanted, kind: ConfigKind.asset, …)` | shared configuration store | deleting a technical document on the Knowledge Base page | `guarded by 03-05` — `GuardedConfigStore`, checked and recorded under the `page_editor_data` key exactly as the preference write it replaces was. **A behaviour change, not a move**: the old code tested `assets is! Map` against a list and wrote the device-local copy, so it stripped nothing, ever (D-4). The route is still ungated — see §3.1 — so `configure` at the guard is what stands between an operator and the plant's layout |

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
asset's index, and — through `tech_doc_upload_service.dart`'s cleanup — rewrite
`page_editor_data`. That is the claim plan 03-14 acted on; the route is raised
now and both spellings of the sentence are gone from the source. Milestone v1.2
plan 03-05 made that third claim *true*: the cleanup used to write the
device-local copy of `page_editor_data` and, because it tested `assets is! Map`
against a list, wrote nothing at all. It now rewrites the shared asset rows
through `GuardedConfigStore` — so the raised route and the `configure` check
are what stand between an operator and the plant's layout, and both are in
place before the write can happen.

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

- `AccessAdminStore` (`lib/core/access_admin_store.dart`) is the one object the
  screens write through. It names its permission once, as `kAccessAdminGroup =
  AccessGroup.users` — the same shape `access_template_store.dart` uses for
  `kAccessTemplateGroup`.
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

### 3.6 `lib/providers/theme.dart` — device-local UI state, still unguarded

`theme_mode` and `color_scheme`. Plan 03-01 classifies both as `operate`: they
are what a panel writes about itself, not plant configuration.

**Half-closed by milestone v1.2 plan 01-06.** The four
`SharedPreferences.getInstance()` calls are gone; both notifiers hold a `ref`
and read `localPreferencesProvider`. That was the store problem, and it is
fixed. It was not the guard problem, and this section previously said it would
be — mistakenly. `localPreferencesProvider` is *deliberately* unguarded (the
session itself is stored through it, so a check there would need a session to
read the session), so these two writes still pass no access check and still
produce no `audit_entry` row. What they do produce now is a `config_change` row
in the station's own `config.sqlite`, which is a local change log and not the
audit trail.

**What closing it would take.** Unchanged in substance: routing both notifiers
through a guarded path, which today means `preferencesProvider` — and that
would make two device-local keys shared between every station pointed at the
same Postgres, which is wrong for a per-panel theme. Left open because the
value is low: an `operate` key an anonymous session may write anyway.

### 3.7 `lib/pages/dbus_login.dart` — station credentials, outside the guard

Five bare keys (`connectionType`, `host`, `username`, `autoLogin`,
`sshPrivateKeyPath`) and one `secureStorage.write(key: 'dbus_password', ...)`.

Spec §2 excluded changing this file from the access-control milestone, and said
why: the D-Bus credential is a **station** credential, the same kind of thing as
the OPC UA session and the Postgres login, and D-Bus is the mechanism
*underneath* `administer` rather than something `administer` governs. Plan 03-01
still classifies all five keys as `administer`, so if the writes are ever routed
through the guard the classification is already there.

**The store moved anyway, in milestone v1.2 plan 01-06.** That milestone is
about *where* device-local configuration lives, not about who may write it, so
§2's exclusion did not apply to it: the two `getInstance()` calls became
`createDeviceLocalPreferences()` (in the top-level `loadSavedDbusCredentials`,
which has no `ref`) and `ref.read(localPreferencesProvider)` (in
`_saveCredentials`, which does). The keys, their values and their trust level
are unchanged; the `dbus_password` line was not touched and is still §3.4's
problem. The check's single allow-list entry for this file went with the move —
so a regression to the old constructor here now fails the build like anywhere
else.

**What closing the guard gap would take.** Lifting the §2 exclusion, then the
same treatment as any other page. The exclusion is a decision, not an
oversight.

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
| ~~`lib/page_creator/page.dart` (unawaited, from `PageManager.load()`)~~ **deleted by 03-04** | `page_editor_data` | `configure` | — |
| `packages/tfc_dart/lib/core/state_man.dart:442` (`StateManConfig.fromPrefs`) | `state_man_config` | `administer` | 03-06 |
| `packages/tfc_dart/lib/core/alarm.dart:220` (`AlarmMan.create`) | `alarm_man_config` | `configure` | 03-06 |
| `lib/providers/collector.dart:27` (`collectorProvider`) | `collector_config` | `administer` | 03-09 |

Without `systemWrites` each of these is denied on a fresh station and the
station is broken in a way no screen shows — the page editor case takes the
pages away entirely.

**One of them has left.** `stateManProvider`'s `key_mappings` default —
`fetchKeyMappings`, which wrote a one-key example blob through `systemWrites`
whenever the preference was absent — was deleted by milestone v1.2 plan 02-05.
Key mappings are `config_item` rows now, and the boot default is
`GuardedConfigStore.seedDefaultIfEmpty`: no session check, `origin: 'system'`,
one audit row, and it writes **only** against a shared database that is
reachable and, once the first reconcile has landed, genuinely empty. That is
strictly narrower than the write it replaces, which fired on any station whose
local store happened not to hold the key — including one that simply could not
reach Postgres. `lib/providers/state_man.dart` therefore no longer appears in
§2.2 or in the table above; it is still on `kSystemWriteCallSites`, for
`StateManConfig.fromPrefs`.

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

### 3.12 `centroid-hmi/lib/main.dart` constructs a second `ConfigStore`

Milestone v1.2 phase 3 plan 04 gave `PageManager.load()` a `ConfigStore` to
read the station's page rows from, and SC-5 asks for that to happen **before
`runApp`** — so the first frame is the plant rather than a blank page while
Postgres is decided. There is no `ref` at that point: `configStoreProvider`
does not exist until the `ProviderScope` is built, which is after the pages
are needed. So `main()` opens a second handle, and
`scripts/check-preferences-construction.sh` carries the only entry in its
allow list for the `config` pattern.

**Not a hole, and the reasons are structural rather than promised.** The
handle is constructed with no remote, so `writeItems` refuses every shared
write at the offline check, before it reaches a diff — it *cannot* write a
shared row. It is handed to `PageManager` as `store:`, whose documented and
only use is `itemsOf`; the save path is 03-06's and goes through
`GuardedConfigStore`. `config.sqlite` is WAL (Phase 1 SC-6), so a second
handle on the file beside the provider's is safe. And the guard this handle
does not have is a guard over writes, of which it performs none.

What would settle it: Phase 4, when the blob fallback goes and the pre-`runApp`
read is the only way a station gets its pages. At that point the handle is
worth making explicit — a named read-only view over the mirror rather than a
`ConfigStore` with a convention attached.

### 3.13 `lib/page_creator/page.dart` — the page editor's save

**Verdict: guarded, and the guard is the only route to a shared row.**

`PageManager.save()` has two arms and they are told apart by one field.
`writeItems` — bound in `lib/providers/page_manager.dart` and nowhere else —
is `GuardedConfigStore.write` over `{page, asset}` with
`checkKind: ConfigKind.page`, so every save the app performs is checked
against `kConfigWriteKeys[ConfigKind.page]` = `page_editor_data` (the key the
policy already classes as `configure`, and the `item_key` the trail already
used for a layout change) and recorded as one `audit_entry` over N
`config_change` rows. Until milestone v1.2 plan 03-06 added that table entry,
`write(checkKind: page)` threw `ArgumentError` — the gate was deliberately in
the way, so the save had to add the entry rather than route around the check.

With no binding, `save()` writes the `page_editor_data` preference exactly as
it did before rows existed. That arm belongs to the pre-`runApp` manager and to
tests, and it **structurally cannot reach a shared row**: it never touches a
`ConfigStore`. `PageManager.store` is the raw store and is reads-only by
convention (§3.12); nothing in the class writes through it. The one thing the
save does read from it is the stored identities, before it builds its items —
`adoptRowIdentities`, a copy of ids that already exist as rows, never a
derivation.

What would settle it: Phase 4, when the blob arm goes entirely and the binding
is not optional.

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
Owner: plan 03-11, which extends the check to the legacy API.

**Enforced, and now empty.** The check searches for this pattern under the same
outside-`lib/providers/` rule, and milestone v1.2 plan 01-06 moved all six onto
the device-local store — so the pattern matches nothing today. It stays in the
script regardless, because `shared_preferences` is still a readable dependency
for one release and a regression to it is still possible. `dbus_login.dart`'s
allow-list entry is deleted; the file passes on its own merits now.

That emptiness is why the same plan gave the check a **third** pattern,
`SqlitePreferences(`. Two patterns matching nothing is a gate that prints
"clean" while enforcing nothing — the exact silent rot this document opens by
quoting. The new pattern was proven to bite: a `SqlitePreferences(` planted
under `lib/widgets/` fails the check by name, and removing it passes.

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
| the `flutter_preferences` digest watcher | 3 | already covered in 2.3, but named by bare filename; at that run, a full path. **Gone since**: milestone v1.2 plan 04-12 deleted `preferences_watch.dart` with the table it watched. The row is retired to a description rather than kept as a path — a path the script cannot find fails the reconciliation in the reverse direction, which is the same treatment `GuardedPrefsReader` got below |
| `packages/tfc_dart/lib/core/secure_storage/interface.dart` | 1 | same — 2.6 named it by bare filename |
| `lib/providers/alarm.dart` | 1 | plan 03-06's seventh system-write site — new |
| the knowledge guards' page-layout reader | 1 | plan 03-13's guard — new at that run. **Gone since**: milestone v1.2 plan 03-05 moved the delete-document cleanup onto the shared configuration store, so `guarded_knowledge_stores.dart` writes no preference and `GuardedPrefsReader` is deleted. The file's row is retired rather than kept stale — a row the script cannot find fails the reconciliation in the reverse direction |

In the reverse direction **one** row had no hit —
`packages/tfc_dart/lib/core/database_drift.g.dart`, which the script collapses
to a counted `[generated]` line by design and therefore never emits as a
`file:line` hit. No row was stale.

**Beyond finding F, nothing further found.** No new write surface, no new
accessor spelling that is not a guard this phase added, and no site whose
verdict this document cannot state.

### 4.3b What the per-account-timeout change moved (2026-09-12)

The inactivity timeout stopped being a device-local preference and became a
column on `app_user`, and the sweep's two directions caught the consequence
before a human did — `test/core/phase_03_coverage_test.dart` went red on a row
with no hit.

- **One row deleted.** `lib/pages/access_session_section.dart` had two
  device-local writes (`kAccessInactivityMinutesPrefKey`,
  `kAccessInactivityDisabledPrefKey`) reached from the Session card. The card
  is now a read-out: it writes nothing, both keys are retired, and the row was
  stale rather than merely re-numbered. Deleted rather than annotated, because
  a table of write paths that lists a file writing nothing is the rot this
  check exists to catch.
- **One row widened, not added.** The write did not disappear; it moved to
  `AccessRepository.setInactivityTimeout`, which is the ninth write reaching
  §2.1's `app_role`/`app_user` statements and is covered by that file's
  existing row rather than a new one. Its gate is unchanged in kind:
  `AccessAdminStore.setUserInactivityTimeout` asks `kAccessAdminGroup` and
  records `user.inactivity_timeout`, refusals included — the same shape as
  `user.station_account` beside it.

Net: the surface did not grow. A device-local write that bypassed
`GuardedPreferences` and paid for it with a hand-rolled audit row became a
database write already sitting behind `guarded by 06-03`.

### 4.4 What §5 checked and did not find

The rule this document is meant to enforce — *a key the app writes in normal
operation may not rest on the `administer` default* — is satisfied. Every one of
the thirty-odd key expressions in §5 is matched by an explicit rule. There is no
finding of that shape to raise here.

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
| `providers/collector.dart:27` | `Collector.configLocation` | `collector_config` | exact `collector_config` | `administer` | **boot-time** — default written when absent |
| `providers/access.dart:694` | `kAccessSessionPrefKey` | `access.session` | exact `access.session` | `operate` | **read-path** — every `poke()`, i.e. every pointer-down |
| `providers/chat.dart:340, 370, 405, 449, 525, 905` | `'$kConversationPrefix$id'` | `chat.conversation.<id>` | prefix `chat.` | `operate` | behind a control |
| `providers/chat.dart:529, 548` | `kConversationList` | `chat.conversations` | prefix `chat.` | `operate` | behind a control |
| `providers/chat.dart:532, 558` | `kActiveConversation` | `chat.active_conversation` | prefix `chat.` | `operate` | behind a control |
| `providers/chat.dart:453, 494, 505, 535, 538` | `kChatHistory` | `chat.history` | prefix `chat.` | `operate` | behind a control, plus a one-time migration |
| `providers/theme.dart:23` | `_key` (`ThemeModeNotifier`) | `theme_mode` | exact `theme_mode` | `operate` | behind a control — device-local store since v1.2 plan 01-06; **still never reaches the guard**, §3.6 |
| `providers/theme.dart:52` | `_key` (`ColorSchemeNotifier`) | `color_scheme` | exact `color_scheme` | `operate` | behind a control — same |
| `tech_doc_upload_service.dart` (the cleanup) | `kConfigWriteKeys[ConfigKind.asset]` | `page_editor_data` | exact `page_editor_data` | `configure` | **delete-path** — the asset rows are rewritten when a tech doc is deleted. Since v1.2 plan 03-05 the key is the guard's `item_key` rather than a preference key: the layout is rows now, and this is the string that keeps one query over the trail spanning the cutover. The `PrefsReader` adapter that used to carry it is deleted |
| `key_repository.dart:882, 2417` | `kConfigWriteKeys[ConfigKind.keyMapping]` | `key_mappings` | exact `key_mappings` | `configure` | behind a control, on a `configure`-gated route — through the configuration store since 02-06 |
| `page_view.dart:264` | `'asset_stack_config'` | `asset_stack_config` | exact `asset_stack_config` | `operate` | **read-path** — written when the key is absent, on mount of any asset page |
| `dbus_login.dart:127-131` | five literals | `connectionType`, `host`, `username`, `autoLogin`, `sshPrivateKeyPath` | five exact rules | `administer` | behind a control — device-local store since v1.2 plan 01-06; **still never reaches the guard**, §3.7 |
| ~~`page_creator/page.dart` boot seed~~ | `storageKey` | `page_editor_data` | exact `page_editor_data` | `configure` | **deleted by 03-04** — it was boot-time and unawaited, so a denial surfaced as an unhandled async error and a default that never persisted |
| `page_creator/page.dart:454` | `storageKey` | `page_editor_data` | exact | `configure` | behind a control — and **only on a manager with no `writeItems` binding**; the app's manager writes rows instead (§3.13) |
| `page_creator/page.dart:469` | `orderStorageKey` | `page_editor_top_level_order` | exact `page_editor_top_level_order` | `configure` | behind a control; device-local, and written *before* the rows so the half that can be stale is the cosmetic half |
| ~~`image_store.dart:96, 129`~~ | `'$keyPrefix$id'` | `page_editor_image:<id>` | prefix `page_editor_image:` | `configure` | **moved by 04-09** — image blobs are `kind='page_image'` rows now, written through `GuardedConfigStore.save`, so they are checked under `kConfigWriteKeys[ConfigKind.pageImage]` = `page_editor_data`, which resolves to the same `configure`. The prefix rule stays in `kPrefAccessRules` for the legacy rows the 04-11 migration will still meet |
| `page_creator/assets/common.dart:846` | `kConfigWriteKeys[ConfigKind.keyMapping]` | `key_mappings` | exact | `configure` | behind a control — through the configuration store since 02-06, not through preferences |
| `recipes.dart:269` | `'${widget.config.recipesBucket}.recipes'` | `<bucket>.recipes` | suffix `.recipes` | `setpoints` | **read-path** — `_getRecipes` writes an empty default, so an anonymous operator merely opening a recipes asset triggers it |
| `recipes.dart:281` | same expression | `<bucket>.recipes` | suffix `.recipes` | `setpoints` | behind a control |
| `widgets/preferences.dart:949-957, 979, 981` | `e.key` | **cannot be resolved to a literal or a prefix** — the key is whatever row the operator is editing, so the group is whatever rule matches at runtime | every rule, at runtime | varies | behind a control, on the `administer`-gated `/advanced/preferences` |
| `color_picker_dialog.dart:66` | `prefsKey` | `color_picker_recent_colors` | exact `color_picker_recent_colors` | `operate` | behind a control (confirming a colour) |
| `tfc_dart/core/state_man.dart:442` | `configKey` | `state_man_config` | exact `state_man_config` | `administer` | **boot-time** — `StateManConfig.fromPrefs` writes a default when absent |
| `tfc_dart/core/state_man.dart:450` | `configKey` | `state_man_config` | exact | `administer` | behind a control |
| `tfc_dart/core/alarm.dart:220` | `'alarm_man_config'` | `alarm_man_config` | exact `alarm_man_config` | `configure` | **boot-time** — `AlarmMan.create` writes a default when absent |
| `tfc_dart/core/alarm.dart:303` | `'alarm_man_config'` | `alarm_man_config` | exact | `configure` | behind a control — `addAlarm`/`removeAlarm`/`updateAlarm`/`setAutoNavigate` only. **`ackAlarm` writes nothing**, so this rule does not stand between an operator and an alarm ack |
| `read_toggles.dart:38, 114` | `McpConfig.kPrefKey` | `mcp.config` | prefix `mcp.` | `administer` | over MCP, not from a widget (§3.2) |
| `tfc_dart/core/preferences.dart:344-585` | `key` / `entry.key` (parameters) | pass-through — the cache fan-out inside `Preferences` | n/a | the caller's | n/a |
| `config_service.dart:64` | `_prefCache.clear()` | **not a preference key** — `_prefCache` is a `TtlCache` (`:45`) | n/a | n/a | n/a |

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

No sentence here says the enumeration is complete. The entire reason this
document exists is that the last such claim was wrong: §6 named three, a fourth
was in the tree the whole time, and §4 above names a fifth. Assume there is a
sixth, re-run `scripts/sweep-write-paths.sh`, and add its rows.

Spec §6 is **not modified by this document**. It is authoritative input to this
phase and plan 03-11 owns any amendment; findings A, B and C in §4.1 are
candidates for it.
