# Relational config storage — research

Moving `page_editor_data` and `key_mappings` out of `flutter_preferences`
JSON blobs and into rows, with Postgres as the owner and a local SQLite
mirror as the cache — and, on the way, collapsing the several config
storage strategies now in the tree into **one**.

Status: **research complete, reviewed, questions open, implementation
started.** Branch `relational-config`, worktree
`../tfc-hmi-worktrees/relational-config`.

Fable reviewed this design and its verdicts are in
[relational-config-architecture-review.md](relational-config-architecture-review.md).
It found four things wrong, two of which corrupt history if built as
drafted. §7 below records what changed as a result, and its cuts to the
question list are folded into §5.

---

## 1. What is actually true today

### 1.1 The blobs

`flutter_preferences` is `(key TEXT, value TEXT, type TEXT)`. Two rows
carry effectively all the plant configuration. From the 2026-08-11 live
dump (`svn-prefs-live-20260811.csv`) — **stale; production is bigger now,
see Q8**:

| key | bytes | type |
| --- | ---: | --- |
| `key_mappings` | 530 287 | String |
| `page_editor_data` | 145 405 | String |
| `mcp.config` | 185 | String |
| `alarm_man_config` | 13 | String |

The 2026-08-10 file snapshots I benchmarked against hold 9 pages / 196
assets and 430 key-mapping nodes.

### 1.2 Parsing the blobs is **not** slow

Measured in the worktree on the real snapshots, Flutter 3.44.9, 20
iterations, warmed:

| operation | bytes | ms |
| --- | ---: | ---: |
| `jsonDecode(page_editor_data)` | 231 350 | 0.68 |
| `PageManager.pagesFromJson` (→ 196 `Asset` objects) | 231 350 | **1.85** |
| `PageManager.toJson` (196 assets → string) | — | 2.01 |
| `jsonDecode(key_mappings)` | 160 922 | 0.39 |
| `KeyMappings.fromJson` (→ 430 entries) | 160 922 | **0.65** |

At ten times production size that is ~19 ms and ~7 ms. **The JSON is not
what makes a page slow to render**, and a relational read that costs one
extra network round trip would be a regression, not an improvement. This
reframes the whole job — see §2.

The number that *is* big is already recorded in the repo, at
`providers/page_manager.dart:9`: the plant page appeared in **75 ms**
when Postgres was reachable, 5 ms when the port refused, and **10 012 ms**
when the host was routable but never answered. The cost is the database
round trip and its failure modes, not the decode. That is precisely what a
local mirror fixes.

### 1.3 What the blob shape actually costs

**Every page-editor save writes ~290 KB into `audit_entry`.**
`GuardedPreferences.setString` reads the old value and stores both sides
verbatim (`guarded_preferences.dart:363-372`). So one asset nudged three
pixels produces an audit row holding the whole 145 KB before-image and the
whole 145 KB after-image. A `key_mappings` save writes over **1 MB** the
same way. The trail is technically complete and practically unreadable —
you cannot see *what* changed, only that something did.

**The blob already broke the notification layer.** `pg_notify` caps
payloads at 8000 bytes and enforces the cap by erroring the statement that
fired the trigger, so a row-payload trigger on `flutter_preferences` would
make every `key_mappings` save fail outright.
`enableKeyedNotificationChannel` (`database_drift.dart:1588`) exists solely
to work around this, and `PreferencesWatcher` has to hash rows server-side
with `md5(value)` so the half-megabyte is not shipped over the wire just to
learn nothing changed.

**Saves clobber each other.** Several SVN stations share one Postgres.
Two people editing two different pages is a last-writer-wins race over the
entire configuration: whoever saves second silently discards the other's
work. There is no version token and nothing detects it.

**The local cache rewrite is whole-file.** `Preferences.syncToLocalCache`
carries a long comment measuring it: `shared_preferences` on Windows
re-encodes the entire preference map and rewrites the file with
`writeAsStringSync` *per key*, 35.5 ms for four keys against a 754 707-byte
file, on the UI isolate, on every startup and every reconnect. The
mitigation is "don't write unless the value differs".

**Edits made while Postgres is down are silently lost.**
`_upsertToPostgres` returns `false` when `database == null`; the in-memory
and local caches still take the write, so the editor reports success. On
the next boot with the database back, `loadFromPostgres` overwrites the
local copy and the work is gone. Latent today; the new design has to take a
deliberate position on it (Q6).

### 1.4 There are five config storage strategies in the tree

This is the thing worth fixing, more than any single blob:

| strategy | holds | owner |
| --- | --- | --- |
| `flutter_preferences` JSON blobs | pages, key mappings, alarm config, mcp config | Postgres |
| `shared_preferences` file | startup URL, session, `mcp.config` | device |
| bespoke relational tables | `access_template`, `access_key_binding`, `history_view*`, `app_role`, `app_user` | Postgres |
| OS keychain | `StateManConfig` (OPC UA passwords), LLM API keys, **`DatabaseConfig` incl. the Postgres password** (`database.dart:196`), the D-Bus station credential | device |
| in-flight (`ReportStore`, PR #447) | report definitions | Postgres |

Five stores, five migration stories, five backup stories, five answers to
"who changed this and when" — of which only the third has any answer at
all. §3 collapses the first three into one.

### 1.5 Read and write surfaces are narrow

Writers:

- `page_editor_data` — `PageManager.save()` (`page.dart:275`), reached from
  exactly one call site, `pages/page_editor.dart:1947`; plus the boot seed
  (`page.dart:270`) and `tech_docs/tech_doc_upload_service.dart:268`, which
  read-modify-writes the whole blob to strip a `techDocId`.
- `key_mappings` — five sites: `providers/state_man.dart:39` (boot seed),
  `pages/key_repository.dart:873` and `:2348` (editor save, import),
  `page_creator/assets/common.dart:834`, `tfc_dart/core/state_man.dart:684`.

Readers beyond the app: `packages/tfc_mcp_server` reads both by raw SQL
against `flutter_preferences` (`services/config_service.dart:87`),
`packages/tfc_dart/bin/page_geometry.dart` reads a prefs file, and the
`tools/svn_*.py` scripts read and write the rows over ssh+psql. All are in
scope for the cutover (Q4).

### 1.6 The pieces to build on already exist

`AuditRecord` already has `action_id` — "one human action is one actionId
with N rows beneath it" — and `access/dynamic_value_diff.dart` already
reduces one whole-struct write to only the members that changed, so the
trail says `p_cmd_JogFwd false -> true` instead of two blobs. **That is
exactly the pattern this work needs, applied to config instead of tags.**

`KeyMappingsUpdateResult` (`state_man.dart:702`) already models an edit as
`added`/`removed`/`changed` and re-points live subscriptions incrementally.
The store can hand it that diff directly instead of having it recomputed
from two full blobs.

`AppDatabase` already runs the same generated schema on either backend
(`database_drift.dart:725`, `bool get native => executor is NativeDatabase`)
and `AppDatabase.create` already accepts a `sqliteFolder` (which has zero
callers today).

**Correction, 2026-09-07.** An earlier draft of this section said
`sqlite3_flutter_libs` being in `pubspec.lock` means the native library
"ships on Windows and elinux with no new native-assets story". **That is
false for eLinux, and unfixed it stops every station booting.**
`sqlite3_flutter_libs` declares a `linux:` plugin with a `pluginClass`, i.e.
the CMake plugin pipeline — and flutter-elinux does not run that pipeline.
This repo already documents the exact failure at
`docker/frontend/Dockerfile:119`: *"Download libpdfium.so (flutter-elinux
skips the CMake FFI plugin pipeline)"*. pdfium is downloaded by hand for
precisely this reason.

The image installs the `sqlite3` apt package, which brings
`libsqlite3.so.0` but not the unversioned `libsqlite3.so` that
`package:sqlite3` opens. That is the same shape as the three symlink hacks
already in the file for `libgio`, `libglib` and `libsecret`
(`Dockerfile:95-97`), and the same principle the `libmpv2` comment states —
on Linux these packages "bundle nothing; they expect the distro's".

So the fix is known and cheap — a Dockerfile symlink plus a loader override
in drift's `isolateSetup` — but it is **Phase 1 work with a station-boot
blast radius**, not a free ride. It must be verified on the rig before the
phase is called done.

---

## 2. What the job actually is

Not "make rendering faster" — rendering is already 2 ms. The job is:

1. **One storage strategy**, not five.
2. **Write granularity** — one save touches the rows it changed.
3. **An audit trail you can read** — `asset 7f3a on /roe moved`, with a
   before and after you can see, instead of 290 KB of noise.
4. **Rollback** — undo one action, restore one page, restore to a point in
   time.
5. **Concurrency** — two stations editing two pages must both keep their work.
6. **Availability** — a local store so a dead-but-routable Postgres costs
   2 ms, not 10 s.

And one hard constraint: **the read path must not regress.**

### Rule: read everything once, into memory, exactly as today

The app materialises the whole configuration at boot and holds it. That
stays. Lazily querying a page's assets on navigation would trade 2 ms of
parse for a network round trip per page change, which on this plant network
is far worse.

This rule has a large consequence for the schema: **no query ever filters
config in the database.** `filterByServer`, the history view's
collected-key scan, "every `ConveyorConfig`" — all of them run against the
in-memory snapshot. So the table needs no per-kind indexed columns, which
is what makes a single generic table (§3.1) viable rather than a
compromise.

---

## 3. One store

### 3.1 One table

```sql
config_item(
  kind        TEXT NOT NULL,   -- 'page' | 'asset' | 'key_mapping' | 'preference' | ...
  id          TEXT NOT NULL,   -- page path, Asset.id, mapping key, pref key
  scope       TEXT NOT NULL,   -- 'shared' | 'station:<hostname>'
  parent_id   TEXT,            -- asset -> page path; null when unscoped
  sort_index  INTEGER,         -- paint order for assets; null when unordered
  payload     TEXT NOT NULL,   -- canonical JSON
  rev         BIGINT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL,
  updated_by  TEXT NOT NULL,
  PRIMARY KEY (kind, id, scope)
)
```

**Why the payload stays JSON.** The point of this work is write
granularity, a readable trail and rollback — not queryability, which §2
just established we do not need. Decomposing an asset's settings into
columns would mean a column per type across ~60 hand-written
`@JsonSerializable` config classes, or EAV; and composites nest their
children *inside their own JSON* as typed fields
(`BeckhoffCX5010Config.subdevices`, `Asset.childAssets`) rather than as a
generic tree. All of the value is at the granularity of one row per entity;
none of it is at one column per field.

**`scope` is what retires the second storage strategy.** Device-local
preferences exist as a whole parallel store today only because some
settings must not sync between stations — per-station startup page, the
session, and the per-station `DatabaseConfig`, which holds a *different*
Postgres IP on each machine and must never be shared. As a column instead:

| scope | owner | replicated |
| --- | --- | --- |
| `shared` | Postgres | mirrored into local SQLite |
| `station:<hostname>` | local SQLite | never leaves the machine |

Same table, same API, same history, same audit — the ownership rule is
driven by a column rather than by which object you happened to inject. It
also means the station-local rows are readable *before* Postgres is, which
they must be: the row that says how to reach Postgres is one of them.

**Assets already have ids.** `Asset.id` (`common.dart:156`) exists and is
minted lazily the first time something links to an asset. The migration
mints one for every asset; `assignNewId()` on paste already keeps them
unique.

### 3.2 One history table

The research question was *"should we only store changes or what"*. Three
candidates, judged against this system:

**(a) Event log only — no current-state table.** Every boot folds the whole
log to reconstruct the config. Fold cost grows without bound, the SQLite
mirror would have to mirror the log, and one bad row poisons everything
downstream. **Rejected.**

**(b) SCD-2 / bitemporal — `valid_from`/`valid_to` in `config_item`
itself.** Point-in-time reads become a single query, which is genuinely
elegant. But it puts a temporal predicate on the hot read path forever, and
the mirror then either carries all history or needs a filtered sync that
can go subtly wrong. We buy a fast answer to a question asked a few times a
year and pay for it on every boot. **Rejected — but see Q2.**

**(c) Current rows plus a separate append-only change log.** Recommended.

```sql
config_change(
  id          SERIAL PRIMARY KEY,
  at          TIMESTAMPTZ NOT NULL,
  action_id   TEXT NOT NULL,   -- joins straight to audit_entry.action_id
  who, station, role_name, reason,
  kind        TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  scope       TEXT NOT NULL,
  op          TEXT NOT NULL,   -- 'insert' | 'update' | 'delete'
  old_value   TEXT,            -- full prior payload, null on insert
  new_value   TEXT             -- full new payload, null on delete
)
```

- **The read path never sees it.** `SELECT … FROM config_item WHERE kind=?`
  with no temporal predicate and no join, and the mirror holds only current
  state, so it stays small and the sync is a plain row diff.
- **It *is* the audit detail.** `action_id` is the join to `audit_entry`, so
  one page save is one audit row plus N change rows beneath it — the shape
  `AuditRecord.actionId`'s contract already describes.
- **Full entity on both sides, not a field diff.** A payload is a few
  hundred to a couple of thousand bytes; storing both makes a restore exact
  — putting the entity back is writing `old_value`, with nothing to
  reconstruct. Reducing that to "which fields moved" is a *display* concern,
  computed on read, exactly as `dynamic_value_diff.dart` does for tags.
- **History prunes or archives independently** of the config, which SCD-2
  cannot do without touching live rows.

Rollback falls out:

| ask | how |
| --- | --- |
| undo that action | rows with that `action_id`, inverted |
| restore page X to time T | latest change ≤ T per entity; entities first created after T are deleted |
| named checkpoint | a `config_snapshot` row holding a full export, written on demand |

A restore is itself a write, producing its own `action_id` and change rows.
The log stays append-only, always — the rule `AuditSink`'s doc already
states for the trail.

Sizing: a key-mapping change row is ~600 bytes for both sides. Rewriting
all 2000 keys weekly for a year is well under a gigabyte, against a
database that already historises 91 whole drive structs at 5 s.

### 3.3 One write path

Every configuration write in the app, of every kind, goes through one
method:

```
check access (existing AccessPolicy, by kind+id)
  → one transaction: upsert changed config_item rows, bump rev,
                     append config_change rows
  → one audit_entry row, same action_id
  → mirror the changed rows into local SQLite
  → notify (LISTEN/NOTIFY, tiny payload — rows are small now)
```

`GuardedPreferences` stays exactly where it is for the scalar preferences
that remain, and the same guard wraps this store. The access policy already
answers by key string, so `page_editor_data` → `configure` becomes
`kind='asset'` → `configure` with no new vocabulary.

---

## 4. Postgres owner + SQLite cache

You suggested doing this either as an abstraction on top of drift, or by
implementing drift's own abstraction over a Postgres connection plus a
SQLite cache. I looked at the second properly, and it is the wrong layer.

`QueryExecutor` (drift 2.28.2 — the resolved version, `runtime/executor/executor.dart:20`) deals in
**raw SQL strings and positional args**: `runSelect(String, List)`,
`runInsert`, `runUpdate`, `runBatched`, `beginTransaction`. An executor
cannot know that a `SELECT` over `config_item` may be served from cache
while one over `alarm_history` must go to Postgres — it would have to route
on SQL text. It cannot reconcile `SERIAL` ids from Postgres with
`AUTOINCREMENT` ids from SQLite. And the dialects differ where we already
know they differ (`JULIANDAY()` has no Postgres equivalent). Drift's own
docs point at `QueryInterceptor` for wrapping, which is for logging, not
routing; `MultiExecutor` splits reads across a pool of the *same* logical
database and does not replicate writes. Neither fits.

**What does fit, and needs no drift changes at all:** the table definitions
are already backend-agnostic and `AppDatabase` already runs on either
executor. So — two instances of one generated schema (the existing Postgres
one, and a local `NativeDatabase` file), with the policy in a repository
above them:

- **read** — serve an in-memory snapshot; fill it from SQLite at boot
  (local, ~2 ms, no network), reconcile from Postgres when it answers, swap
  the snapshot.
- **write** — §3.3, Postgres first. Postgres stays the owner exactly as
  today.
- **invalidate** — reuse `PreferencesWatcher`'s LISTEN/NOTIFY, keyed on
  `config_item`, so one station picks up another's edit without a restart.
  The `md5(value)` digest hack can go: rows are small.

This also generalises `bootstrapPageManagerProvider`, which exists today to
paper over exactly this problem with a SharedPreferences copy of the blob,
and which its own doc says was worth 2.3 ms against a 10 s stall.

## 4b. Phase 0: retire `shared_preferences`

Your suggestion, and it should go **first** — small, self-contained, it
removes a measured UI-isolate stall, and it creates the local SQLite
database §4 needs rather than having that appear as a side effect of the
page work. `lib/core/preferences.dart` opens with the intent already
written down:

```dart
// Todo move local storage to file or sqlite, for now use shared preferences
```

What it buys: the whole-file rewrite goes away (35.5 ms per four keys on
the UI isolate, measured, and the "don't write unless it differs"
workaround with it); one local store instead of two; and the mirror becomes
a row copy between two instances of one schema rather than a translation.

Blast radius, measured: `SharedPreferencesWrapper`
(`lib/core/preferences.dart`) is the only adapter and
`createDeviceLocalPreferences()` the only construction site — the build
already fails for any other, via `scripts/check-preferences-construction.sh`
— so a `SqlitePreferences implements PreferencesApi` drops in behind that
factory with **no call-site changes**. Two legacy direct users of the
synchronous API move too (`lib/providers/theme.dart`,
`lib/pages/dbus_login.dart`). Secrets are unaffected; they live in the
keychain.

Two things to get right: **boot ordering** (the session is persisted
through the local store and must be readable before anything else), and
**migration** — existing stations hold the per-station startup URL, the
session and `mcp.config` here, and losing any of them is a station that
comes up on the wrong page with nobody signed in. One-shot import on first
run, `shared_preferences` left readable for one release.

`DatabaseConfig` is **not** here, contrary to what an earlier draft of this
document said: it lives in the OS keychain with its password
(`database.dart:196`). That moves the per-station-Postgres-endpoint problem
out of Phase 0 and into Q11.

Third: `tech_docs/tech_doc_library_section.dart:1317` constructs its own
device-local store. Several independent handles onto one SQLite file need
WAL mode or a shared connection behind the factory — an implementation
note, not a design problem.

---

## 5. Questions for the morning

**Q1 — Order of attack.** Recommendation, in order:
  0. Local `shared_preferences` → SQLite (§4b), no behaviour change.
  1. `config_item` + `config_change` + the one write path (§3), with
     `key_mappings` as the first kind moved onto it.
  2. Pages and assets onto the same store.
  3. Fold the already-relational config (`access_template`, `history_view*`)
     in, or leave it — it works, and it is the least broken of the five.
`key_mappings` first because it is the bigger blob, decomposes cleanly with
no nested-asset problem, and has an existing incremental-apply path
(`KeyMappingsUpdateResult`) to hand the diff to. Agree with the order?

**Q2 — History model.** Confirm §3.2(c) — current rows plus a separate
append-only change log — over SCD-2 in `config_item` itself.

**Q3 — What must rollback actually do?** This decides how much machinery to
build:
  a. "undo the last change" / "undo that action"
  b. "restore this page to how it was on Tuesday"
  c. named checkpoints ("snapshot before the shutdown work")
  d. just *see* who changed what, no restore button yet
*Recommendation: (a) + (c) in v1, (d) for free, (b) next.*

**Q4 — The other readers.** `tfc_mcp_server` reads both blobs by raw SQL,
`bin/page_geometry.dart` reads a prefs file, and your `tools/svn_*.py`
scripts read and write `flutter_preferences` over ssh+psql. Port them all
in this work, or ship a compatibility **view** that reassembles
`page_editor_data` and `key_mappings` as blobs from the rows so they keep
working untouched? *Recommendation: the view — it is cheap in Postgres and
it decouples the cutover.*

**Q5 — Mixed-version stations.** Several SVN stations share one Postgres and
they do not all update at once. If station A upgrades and stops writing
`flutter_preferences.page_editor_data`, station B still reads it and goes
stale. Options: dual-write both shapes for one release behind a flag; the
Q4 view made writable; or coordinate so all stations move together.
*Recommendation: dual-write for exactly one release, then drop it.*

**Q6 — Editing with Postgres down.** Today the editor reports success,
writes locally, and loses the work on the next boot. I would rather
**refuse the write with a clear message** than fake it. The alternative is a
real offline queue that replays on reconnect — considerably more work, and
it can conflict. *Recommendation: refuse, clearly.* Agree?

**Q7 — Conflicts.** With per-entity rows, two stations editing two different
pages both simply succeed; the clobber is gone. For two stations editing the
*same* page, do you want a `rev` check that stops the second save with
"someone else changed this page, reload", or is last-writer-wins per asset
good enough? *Recommendation: `rev` check at page level, prompt to reload.*

**Q8 — A fresh production dump.** You said the snapshots I have are old and
production is much bigger. I need a current `page_editor_data` and
`key_mappings` — `svn_apply_config.py --backup-only` produces exactly this —
to size the design honestly and to write the migration round-trip test
against real data rather than an eight-month-old sample.

**Q9 — Retention.** Config change rows: keep forever? They are small, and
the audit trail already must never be swept (spec §8 asserts it in a test).
My assumption is forever, with the option to archive.

**Q10 — Does `flutter_preferences` survive at all?** Under "one strategy"
the honest answer is no: the scalar preferences become `config_item` rows of
`kind='preference'`, and `flutter_preferences` is dropped after the
compatibility window. That is a bigger cutover than moving two keys. Do you
want that as the destination (with §5 Q1's phases getting there
incrementally), or should `flutter_preferences` stay for scalars and only
the two big blobs move?

**Q11 — Secret storage.** You floated dropping the OS keychain
(`core/secure_storage/`: macOS Keychain, Windows Credential Manager,
libsecret) for "something simpler with SQLite", and said it is not your
strong suit. It is the fourth of the five strategies in §1.4, so it belongs
in this conversation. What actually goes through it is small — the
`StateManConfig` (`state_man.dart:497-508`) and LLM API keys
(`chat_widget.dart:361`, `providers/llm.dart:23`). I have asked Fable to
give a proper answer on the threat model; the short version of my own view
is that on unattended kiosk panels in containers, which must come up with
nobody there to unlock anything, the keychain buys much less than it does
on a laptop — whatever unlocks it is on the same machine. It does buy a
real thing on your Mac in development, and it is the reason for the
rebuild-time password prompts you already dislike. The likely middle is
encrypted-envelope rows in the same table (the `SecureEnvelope` KDF
primitive is already in the tree), not plaintext. **Not blocking — this can
be decided after the config work lands, and should not be allowed to
enlarge it.**

---

## 6. Implementation status

Two slices committed on `relational-config`, on the parts no answer above
can invalidate. Nothing is wired into the app yet — these are shapes and
proofs, not a store.

- [x] Worktree, toolchain pinned to Flutter 3.44.9, benchmarks in §1.2.
- [x] `ConfigItem` — the generic row of §3.1, with `ConfigScope`
      (`shared` / `station:<hostname>`), canonical JSON encoding and
      structural payload comparison.
- [x] `ConfigChange` — the append-only history record, generic over kind,
      joined to the trail by `action_id`.
- [x] `ConfigDiff` / `diffConfigItems` — what one save writes, in the
      added/changed/removed shape `KeyMappingsUpdateResult` already consumes.
- [x] `key_mapping_codec.dart` + 13 tests: `KeyMappings` ⇄ items, blob in,
      blob out.
- [x] `page_codec.dart` + 13 tests: pages and top-level assets ⇄ items,
      paint order preserved, derived asset ids.
- [x] Both suites re-run against the **real** plant blobs
      (`svn-page-editor.json`, `svn-key-mappings.json`) through the
      `CENTROIDX_PAGE_EDITOR_BLOB` / `CENTROIDX_KEY_MAPPINGS_BLOB` hooks —
      26 tests, all green: 9 pages, 196 assets and 430 mappings survive the
      split and come back holding the same configuration. Re-run them
      against the current dump when you have one (Q8); that is the first
      thing to do with it.
- [ ] Drift table definitions + schema v7 migration, both backends.
- [ ] Local SQLite store, `SqlitePreferences`, one-shot import (§4b).
- [ ] `ConfigStore` repository with the read/write/invalidate policy of §4.

### Three findings from writing it

**Asset ids had to become derived rather than minted.** `Asset.id` is null
until something links to the asset (`common.dart:156`), so nearly every
asset in production reaches the migration with no identity — and several
stations share one Postgres and boot at once. Minting with `newAssetId()`
would give one physical asset a different id per station and leave the
table holding it several times over. `derivedAssetId` hashes the page path,
the list position and the content, so every station computes the same id
and a re-run writes nothing. The index is in the hash because a row of
identical drives is legitimate and would otherwise collide into one row.

**The round trip is normalising, not byte-preserving.** Every config class
emits an explicit null for each unset optional, so a stored
`{"io": true, "collect": null}` comes back with six more null fields.
Nothing is lost — the app has rewritten the whole blob through the same
`toJson()` on every Save since the beginning, so production already stores
the normalised form — but it means the Q4 compatibility view would hand the
Python tooling a textually larger blob than the row holds today. Worth
knowing before you rely on a byte diff anywhere.

**One latent bug found and fixed on the way.** The first canonical encoder
sorted the tree and encoded second. `@JsonSerializable()` without
`explicitToJson: true` generates `'menu_item': instance.menuItem`, so
`AssetPage.toJson()` hands back a live `MenuItem` that `jsonEncode`
converts *after* the sort — leaving it in insertion order. A canonical form
that is stable only by luck means every save rewrites and audits every row,
which is the exact failure this work exists to prevent. It now normalises
through JSON before sorting. The page fixture caught it; the key-mapping
one could not, because `KeyMappings` uses `explicitToJson: true` throughout.

### Where I need you before going further

Everything above is safe. The next step — the drift tables and the store —
is not, because it commits to §3's schema. **Q1, Q2 and Q10 are the
blocking three**; the rest can proceed under the recommendations as stated.
Fable is reviewing the architecture in parallel and its verdicts land in
`docs/relational-config-architecture-review.md`.

---

## 7. What the review changed

Fable reviewed §1–§6 and the committed code. Full argument in
[relational-config-architecture-review.md](relational-config-architecture-review.md);
this is what it changed and what it settled.

### Fixed already

**Change rows carry position.** The one drafted defect that corrupts
history rather than merely costing something. `ConfigChange` stored
payloads only while `parentId`/`sortIndex` sat beside the payload, so
moving an asset to another page or changing its paint order wrote a row
with two *identical* sides — and a restore from it would put the asset back
in the wrong place, silently. Both sides are now the complete entity, and
`ConfigChange.of(before:, after:)` applies that rule in one place. Guarded
by `config_change_test.dart`. Committed at 81a49e37.

**Two factual corrections to §1.4.** `DatabaseConfig` — the per-station
Postgres endpoint *and its password* — is in the OS keychain
(`database.dart:196`), not in `shared_preferences`. So the row that says
how to reach Postgres is also the row that holds the password, which moves
it out of Phase 0 and into Q11. And `tech_doc_library_section.dart:1317`
news up its own device-local store, so Phase 0 needs WAL mode or a shared
connection behind the factory.

### Accepted, to build

- **`CHECK (scope = 'shared')` on the Postgres tables.** The
  "station rows never leave the machine" invariant currently lives only in
  repository code. One line of DDL makes it structural, and turns a subtle
  sync bug into a loud constraint violation. The row it protects is the
  one holding another station's database endpoint.
- **CAS in SQL, not read-check-write.**
  `UPDATE … SET rev = rev + 1 WHERE … AND rev = ?`, rows-affected tells you
  whether you lost. An app-level compare against a previously read `rev` is
  a race with the very station it is meant to detect.
- **`config_change.id` is a sync watermark.** The mirror pulls "changes
  since N" instead of diffing full row sets, NOTIFY fires once per
  transaction carrying nothing, and a missed notification is caught by a
  watermark poll. Strictly more robust than the `md5(value)` machinery it
  retires, and I had left it on the table.
- **Ordering keys, decided now because they are a wire format.** Dense
  integer `sort_index` means dragging one asset renumbers its siblings —
  dozens of change rows for one gesture, which is the "290 kB of noise"
  problem at smaller scale. Either gapped/fractional keys (single-row
  write) or a display layer that collapses order-only changes under one
  `action_id`. *Recommendation: gapped keys; the log stays honest at write
  time rather than being made readable afterwards.*
- **Say out loud that write granularity is the top-level asset.** Editing
  one subdevice of a `BeckhoffCX5010Config` rewrites and logs the whole
  parent. Fine at current sizes; surprising if undocumented.
- **A consistency check in CI**, since the generic table forfeits real
  foreign keys and per-kind CHECKs: every `parent_id` resolves, and
  `config_item.payload` equals the latest `config_change.new_value`. That
  last one is the invariant SCD-2 would have got for free, made a test
  failure instead of a slow corruption.

### Settled, no longer questions

- **Q1 order** — confirmed, with two amendments below.
- **Q2 history model** — current rows plus append-only log confirmed.
  Fable argued the SCD-2 side properly first: its real advantage is
  integrity by construction, not point-in-time queries. It dies on the
  mirror, which would have to carry all history or run a filtered sync
  that is itself a temporal predicate on every sync.
- **Q7 conflicts** — per-entity CAS; the editor turns a failed save into
  "reload". A page-level `rev` does not exist as a row once assets are
  rows, and two stations editing different assets of one page both
  succeeding *is* the designed improvement. Do not build page-level
  pessimism until someone asks.
- **Q9 retention** — forever.
- **Q4 other readers** — read-only compatibility views; port
  `tfc_mcp_server`'s raw SQL in Phase 1–2; your `tools/svn_*.py` move at
  your leisure against the views. A *writable* view is real work and is not
  promised.

### Amendments to the plan

- **Phase 0 writes into `config_item` in the local database**
  (`kind='preference'`, station scope) rather than a throwaway key-value
  table. A bespoke Phase 0 schema means migrating the local store twice.
- **Phase 1 includes dual-write from its first PR**, not as a later option:
  the moment one station writes rows, unupgraded stations must still see a
  coherent blob, so the row write and the legacy blob write share a
  transaction for one release. The blob→row data migration also needs a
  Postgres advisory lock — drift's schema versioning gates the DDL but not
  the data copy, and two stations upgrading the same morning must not race.
- **Phase 3 is cut.** Do not fold `access_template`, `app_user` or
  `history_view*` into `config_item`. They are already relational, already
  audited, and the access tables are the substrate that *gates* config
  writes — folding the gate into the thing it gates is circular. This is a
  deliberate scope cut against your "one strategy" steer, and the honest
  framing is: one strategy means one ownership/audit/mirror semantics and
  one write discipline, not one physical table. Genuinely relational data
  staying relational is the strategy working. `flutter_preferences` still
  dies (Q10) — scalars become `kind='preference'` rows at near-zero cost.

### New questions it raised

**Q12 — station-scoped audit.** §3.3's write path is Postgres-first and
therefore cannot be the write path for station rows, which must be writable
with Postgres absent — that is their reason to exist. So there are two
write paths, and "same audit" as §3.1 wrote it promises something the
design cannot deliver. Does a station-scoped change get a local-only
`config_change` (recommended: yes, same schema, in the mirror), and does it
ever reach the central `audit_entry`? *Recommendation: local log always;
central audit for station rows is a later feature with a queue attached, or
accepted as absent. Say which in the spec.*

**Q13 — page identity: the path is not an id.** Pages are keyed by path and
paths are edited — `page_editor.dart:5697`'s `_updatePathInChildren` exists
precisely because renames happen. Under a `(kind, id, scope)` key a rename
is a delete-plus-insert of the page and a rewrite of every child asset: the
page's history is cut in two, "restore page X to Tuesday" needs to know
what X was called on Tuesday, and every `parent_id` written before the
rename goes stale. Assets already solved this — `Asset.id` is stable and
the path is data. *Recommendation: mint a stable page id at migration, keep
the path in the payload.* Flagged rather than done because it touches your
mental model of "a page's id is its path", and it is cheap now and
expensive after Phase 2 ships.

**Q11 — secret storage, answered.** Fable's verdict is "mostly yes, with
one key left behind", and the reasoning is worth reading in full. The short
version: on the plant hardware the keychain buys **file permissions plus
indirection and nothing more** — `docker/frontend/Dockerfile:80` installs
only `libsecret-1-0`, the *client*, so whatever Secret Service the
container reaches is auto-unlocked with a blank or well-known password, or
absent. Encryption keyed by a secret sitting beside the data is
obfuscation. Windows DPAPI is the one platform where the OS facility earns
its keep; macOS is dev-only and is where it actively costs you the rebuild
prompts. Recommended shape: keep the `secret: true` routing, store secrets
as station-scoped rows wrapped in the existing `SecureEnvelope`, and let
the platform hold exactly **one** random per-station data key — DPAPI on
Windows, Keychain on macOS (read once per boot, which also retires the
`_secretCache` complexity), a root-owned 0600 file on eLinux. Secrets never
become shared rows and never enter the change log with values. Separable
work: decide the direction now because it settles what station scope
carries; build it after Phase 1.

### Still blocking

**Q5** (mixed-version cutover) — it dictates the shape of the first Phase 1
PR that ships. **Q8** (fresh production dump) — blocking for cutover, not
for building; the round-trip test is only evidence if it runs against
current data.

Everything else can proceed under the recommendations as stated.

### Addendum: what reading the committed code changed

Fable read both slices after writing §7 and found one more defect, in the
code rather than the design.

**`derivedAssetId` was being used on every save, not only the migration.**
`pageItems` minted a derived id for any asset lacking one, so two editors
each adding — say — a lamp at the same index of the same page would derive
the *same* id from the same content, and their two assets would collapse
into one row. That is the exact failure rows exist to end, reintroduced by
the mechanism meant to make the migration safe. Derivation is now a
migration-only flag (`deriveIds`, true exactly once, from
`pageItemsFromBlob`); a save mints a random id through `Asset.ensureId()`.
Pinned by three tests, including one asserting two independent saves never
agree on an id.

**And the hash is not the concurrency mechanism.** It converges only for
identical inputs; two stations migrating from *divergent* copies — one from
Postgres, one from a stale local cache — hash to different ids and produce
silent duplicates that no primary key will flag. What actually closes that
race is reading the blob and writing the rows in one transaction under a
Postgres advisory lock. The hash earns re-run idempotency (no "already
migrated" flag) and a testable migration; it does not earn safety. The doc
comment now says so, so nobody later mistakes it for a guarantee.

Two consequences worth carrying forward:

- Late-migrating stations only converge if the id-bearing blob is
  dual-written back in the same locked transaction. That works because
  `BaseAsset.id` is `@JsonKey(includeIfNull: false)`, so a deployed editor
  that has never heard of ids still preserves them. There is now a test
  asserting exactly that — if it ever stops being true, every migrated id
  is lost the next time an old station saves.
- The Q4 compatibility view's contract must be written as **"structurally
  equivalent, canonically encoded"**, never "identical bytes". No external
  reader byte-compares; the one thing that does is `PreferencesWatcher`'s
  `md5(value)`, so expect one harmless spurious reload at cutover.
