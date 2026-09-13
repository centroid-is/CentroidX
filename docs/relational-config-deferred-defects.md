# Defects found during the relational-config milestone, deliberately not fixed here

Each of these is real, verified against the tree, and **out of scope for the
milestone that found it**. They are recorded here rather than in `.planning/`
because that directory is gitignored, and a bug that exists only in a
throwaway file is a bug nobody will ever act on.

Folding any of them into a config-storage phase would have made that phase's
diff dishonest — a reviewer reading "move key mappings into rows" should not
find an unrelated `MATERIALIZED VIEW` fix in it. Each wants its own small
change with its own test.

---

## D-1 — `AppDatabase.postgres` is false on every station

**Verified 2026-09-07.** `bool get postgres => executor is PgDatabase`
(`packages/tfc_dart/lib/core/database_drift.dart:969`) returns **false in the
app**. `lib/providers/database.dart:19` opens the database with
`AppDatabase.spawn`, and `connectWithRetry` defaults `useIsolate: true`
(`database.dart:558-566`), so the main-isolate executor is a DriftIsolate
remote proxy rather than a `PgDatabase`. The repo already knows this
indirectly — `database.dart:654` notes that isolate mode wraps errors in
`DriftRemoteException`.

Migrations are unaffected: `onUpgrade` runs *inside* the isolate, where the
executor is the real one.

**Where it already bites:** `packages/tfc_dart/lib/core/database.dart:1628`

```dart
final isPg = db.postgres;                                   // false in the app
final createKeyword = isPg ? 'MATERIALIZED VIEW' : 'VIEW';
```

reached from `HistoryViewStore.createHistoryView`. On a station this creates a
plain `VIEW` on Postgres where a `MATERIALIZED VIEW` was intended. Valid SQL,
so nothing errors — the view simply recomputes on every read instead of being
materialised. A silent performance regression, which is why it has gone
unnoticed. Anyone investigating slow history views should start here.

**The correct check** is `db.executor.dialect == SqlDialect.postgres`, which
reports the *server's* dialect through the isolate: drift's
`_BaseExecutor.dialect => client._serverDialect`, populated from the
`ServerInfo` handshake (`remote/client_impl.dart:63,79`). All new
config-storage code uses this; the broken getters were left alone precisely
because fixing them would silently flip `database.dart:1628`'s behaviour,
which is a change that deserves its own review rather than riding along.

**Fix shape:** correct `:1628` to the dialect check, verify the materialised
view is created and refreshed as intended, and then decide separately whether
the `postgres`/`native` getters should be removed outright or corrected — they
are a trap either way.

---

## D-2 — the live key-mapping listener goes deaf after any database reconnect

**Verified 2026-09-07.** `lib/providers/state_man.dart:88` subscribes to
`prefs.onPreferencesChanged` on the `Preferences` instance captured when the
provider built. But `preferencesProvider` does `ref.watch(databaseProvider)`
(`lib/providers/preferences.dart:179`), and `databaseProvider` calls
`invalidateSelf()` on every reconnect (`lib/providers/database.dart:57`) — so
a reconnect builds a **new `Preferences` with a new StreamController**, and
the subscription stays bound to the dead one.

**Effect:** after the first database reconnect, saving `key_mappings` no
longer applies live. The edit persists, but subscriptions are not re-pointed
until the app restarts, and nothing reports it — the listener is not
erroring, it is attached to a stream nobody writes to any more.

The `ref.read` at `state_man.dart:64` is deliberate and correct, with a stated
reason: *"StateMan reads config once at init; DB reconnects should NOT cascade
here and destroy all OPC-UA connections/isolates."* The bug is that the
consequence was not followed through to the subscription. The callback body
even re-reads `preferencesProvider` for a fresh instance (`:95`), so whoever
wrote it knew the instance rotates.

**Fix shape:** re-attach the listener when the store rotates, without
reintroducing the cascade that comment exists to prevent. Needs its own test
that reconnects and then asserts a live apply still happens.

Phase 2 works around this rather than fixing it.

---

## D-3 — the MCP server binary now links open62541 through the config codec

**Introduced by this milestone, 2026-09-07, and it should not ship as-is.**

`packages/tfc_dart/lib/tfc_dart_core.dart` is an FFI-free barrel whose header
states its purpose: *"The MCP server imports this file instead of
`tfc_dart.dart` to avoid FFI link errors with `dart compile exe`"*, and it
explicitly excludes `core/state_man.dart` for importing open62541 and jbtm.

Phase 2 removed a hand-rolled duplicate of the key-mappings blob shape from
`ConfigService` — the right call, because two definitions of a wire format
diverge silently and feed a malformed key universe to access templates. But
the replacement imports `key_mapping_codec.dart` **directly**
(`packages/tfc_mcp_server/lib/src/services/config_service.dart:6`), bypassing
the barrel, and the codec imports `state_man.dart`
(`packages/tfc_dart/lib/core/config/key_mapping_codec.dart:28`) for
`KeyMappingEntry` and `KeyMappings` — the exact file the barrel excludes.

The barrel itself is untouched and still does not export `config/`; the
protection was simply routed around.

It compiles today because open62541 was already in that package's dependency
graph, and `test/smoke/compile_test.dart` passes because it only exercises
`--version`. That is the same shape as the eLinux SQLite defect this milestone
already hit: a native dependency that resolves on the build machine and may
not on the target.

**Reproduction, one command** (added 2026-09-07 by plan 04-03, which did not
fix this): `cd packages/tfc_mcp_server && dart build cli -o <dir>` puts every
native asset the package resolved into `<dir>/bundle/lib/`. On a Mac that
directory holds exactly one file, `libopen62541.dylib`. The binary itself
links nothing unusual (`otool -L` shows libSystem and four system
frameworks), which is why `--version` passes and the defect is invisible to
the smoke test as written.

`test/smoke/compile_test.dart` now carries that assertion as a **skipped**
test, `links no native OPC UA stack`. It is the acceptance test for this
fix: remove the `skip` when the codec stops reaching `state_man.dart`.

**Fix shape:** the codec needs only `KeyMappingEntry.fromJson` and
`KeyMappings`. Either lift those model types out of `state_man.dart` into an
FFI-free file, or give the codec an FFI-free entry point. Both restore the
barrel's guarantee without reintroducing two definitions of the blob shape.
Strengthening the smoke test to assert the binary's link profile — not just
that it runs — would stop this recurring.

**This one is a regression, not a pre-existing bug, and should land before
anything ships.**

**Two workarounds now stand on it, which is the cost worth seeing** before
anyone decides whether to fix it. Neither is wrong; both exist only because
the codec cannot be imported by anything that must stay FFI-free:

1. `tfc_dart_core.dart` still does not export `config/key_mapping_codec.dart`,
   so `ConfigService` reaches past the barrel (above). That is the defect
   itself.
2. `packages/tfc_dart/lib/core/config/config_undo.dart:283` (plan 04-07)
   declares `kUndoCheckKeys` as **a hand-written literal copy of
   `GuardedConfigStore.kConfigWriteKeys`**, because importing the original
   would pull `key_mapping_codec.dart` → `state_man.dart` → `dart:ffi` into
   the config layer — the same chain, caught this time by
   `page_rows_test.dart`'s import-graph walk rather than by a link error. The
   copy is pinned against the original by `config_undo_test.dart:730`, so the
   two cannot drift silently; that test is the maintenance this workaround
   costs, permanently, until the codec is freed.

A third instance is the point at which the cheap fix stops being cheap: every
copy is another map somebody must remember to keep in step, and the pinning
test only catches drift after somebody has already written it.

---

## Not defects, but decided by default

- **Page identity (Q13).** Pages are keyed by path and paths are edited
  (`lib/pages/page_editor.dart:5697`). Under a `(kind, id, scope)` primary key
  a rename cuts a page's history in two and staleifies every `parent_id`
  written before it. Fable recommends minting a stable page id and keeping the
  path as payload data, as assets already do. Raised with Jón 2026-09-06 and
  not answered; Phase 3 proceeds on the recommendation. Cheap now, expensive
  after Phase 3 ships.
- **Gapped ordering keys.** Dense integer `sort_index` renumbers siblings on
  every drag. It is a wire format, so it must be settled before anything
  ships.

---

## D-4 — `deleteAndCleanAssets` has never removed a single `techDocId`

**Fixed 2026-09-07 by milestone v1.2 plan 03-05**, as an explicit behaviour
change rather than a port: the cleanup now strips `techDocId` from the
**shared** asset rows through `GuardedConfigStore`, the fixture is built from
real `AssetPage`/`Asset` objects with an assets-is-List pin, and the
`PrefsReader` plumbing (with the `GuardedPrefsReader` that wrapped it) is
deleted. The account below is kept as written — it is what the fix was decided
against, and the A4 check it implies (`grep -c techDocId` on a fresh production
dump) is still worth running when one arrives, because a delete now reaches the
plant-wide layout where before it reached nothing.

**Verified 2026-09-07.** `lib/tech_docs/tech_doc_upload_service.dart:253`:

```dart
final assets = pageMap['assets'];
if (assets is! Map<String, dynamic>) continue;
```

`assets` is a **List**, not a Map. `AssetPage` declares
`@AssetListConverter() List<Asset> assets` and `AssetListConverter implements
JsonConverter<List<Asset>, List<dynamic>>` (`lib/page_creator/page.dart`), so
every page in `page_editor_data` serialises its assets as a JSON array. The
type test is therefore true for every real page, the loop `continue`s, and the
function returns having modified nothing.

**Effect:** deleting a technical document leaves a dangling `techDocId` on
every asset that referenced it. Silent — the method reports success, and the
`modified` flag simply never flips, so it does not even write.

A second, independent defect in the same method: it reads and writes through
the **device-local** store, while `page_editor_data` is a shared,
Postgres-owned value. Even with the type test fixed it would edit a copy
nothing authoritative reads.

The method's own test fixture encodes the bug — it builds `assets` as a Map,
so the test passes against a shape production never produces. That is why this
survived review.

**Fix shape:** correct the type test to `List`, point the read/write at the
shared store, and rebuild the fixture from a real `AssetPage.toJson()` rather
than a hand-written map. Phase 3 was going to "port" this method to the row
store; porting a no-op faithfully would preserve the bug, so the port must be
an explicit behaviour change, decided rather than inherited.

Note the surrounding `on AccessDenied { rethrow; }` arm is correct and
deliberate — its comment explains that swallowing a guard refusal would let a
delete proceed as though cleanup succeeded. Keep it.

---

## D-5 — rows do not carry the operator's key order, so a reorder does not survive a reload

**Found 2026-09-07, executing plan 02-06.** The key repository has a
`ReorderableListView` and a `_reorderKey` handler: an operator can drag a key
to a new position, and until this phase that position was persisted, because
the blob was a JSON object and `KeyMappings.nodes` is a `LinkedHashMap` whose
insertion order round-tripped through `jsonEncode`/`jsonDecode`.

On rows it does not. `keyMappingItems` sorts by key id before writing — the
whole point of it, since row order out of a query is otherwise arbitrary and an
unsorted read would report changes nobody made — and `ConfigStore.keyMappingItems`
sorts again on the way out. So after a save the store serves the keys
alphabetically, and the operator's arrangement is gone at the next load.

**Effect:** cosmetic, and confined to this one page. Nothing reads mapping
order: `StateMan`, the collector, every subscription and every mimic look keys
up by name. The reorder still works within a session — the visual order is the
page's own map — it simply is not stored.

**Why it was not fixed here.** `config_item` already has a `sort_index` column,
so the shape of the fix is known: the codec would set it from the map's
position and order by it on read. But that turns a pure reorder into N changed
rows, changes what a diff means for every consumer of `ConfigDiff` (including
`updateKeyMappings`, which would re-point subscriptions for keys whose wiring
did not move), and has to be taught to the migration and the sync engine at the
same time. That is item-shaping work, which is Phase 3's, and doing it inside
the cutover's last plan would have put an unreviewed diff-semantics change
under the phase gate.

**Fix shape:** carry `sortIndex` through `key_mapping_codec.dart` in both
directions, exclude it from `samePayload` so a reorder is a `sort_index` update
rather than a payload change, and decide explicitly whether a reorder should
emit `config_change` rows at all. Alternatively, decide that mapping order is a
device-local view preference and store it beside the other ones — which is
arguably what it always was.

The two tests in `test/pages/key_repository_test.dart`'s "Reorder keys" group
that asserted the persisted order now assert the behaviour that actually
ships — the keys survive, the arrangement does not — and name this entry.

---

## D-6 — running codegen on this branch silently drops every foreign key

**Found 2026-09-07, contained but NOT resolved.**

`packages/tfc_dart/pubspec.lock` resolves **drift_dev 2.31.0**, while the
checked-in `packages/tfc_dart/lib/core/database_drift.g.dart` was generated by
**drift 2.34**. Regenerating it with 2.31.0 rewrites the file ~2398 lines
shorter and **silently removes every `REFERENCES` constraint** from the
generated schema.

`dart analyze` does not notice — the code still compiles. It was caught only
because `access_schema_test` asserts the constraints exist. Anyone who runs
`dart run build_runner build` in `tfc_dart` and does not run that test will
commit a schema with no foreign keys and no warning.

**Why the version is pinned there.** 02-02 added `sqlite3: ^2.9.0` to
tfc_dart's own pubspec, because sqlite3 3.0.0 removed
`package:sqlite3/open.dart` and the `DynamicLibrary` loading path that
`core/sqlite_loader.dart` overrides so the eLinux stations can open a database
at all. That pin transitively caps drift at 2.31.0. The app itself resolves
drift 2.28.2 from the root lockfile — a third, different version.

So three versions are in play: the root app (2.28.2), tfc_dart's own
resolution (2.31.0), and whatever generated the checked-in file (2.34). Both
lockfiles are gitignored, so none of this is visible in a diff.

**Current state:** the 2.34-generated file has been restored by hand and the
tripwire is documented in the file. That is containment, not a fix — the next
codegen run redoes the damage.

**Fix shape — a decision for the milestone, not a patch:** either raise the
sqlite3 pin's ceiling once the eLinux loader is reworked for sqlite3 3.x build
hooks, or commit `packages/tfc_dart/pubspec.lock` so the generator version is
pinned with the generated output, or regenerate deliberately at 2.31.0 and
accept a schema without `REFERENCES`. The third is the worst of the three and
is what happens by default if nobody chooses.

**Until then:** after any `build_runner` run in `tfc_dart`, run
`access_schema_test` and check `grep -c REFERENCES database_drift.g.dart` is
non-zero before committing.

---

## D-7 — the shared preference store is empty until the migration lands

**Introduced deliberately by plan 04-05, 2026-09-08 (`921d18a7`). This is a
deploy-blocking constraint, not a nicety.**

`preferencesProvider` now answers `SharedRowPreferences`, which reads and
writes `kind='preference'` rows at `scope='shared'` through `ConfigStore`
(`lib/providers/preferences.dart`). The plant's shared settings are still in
the `flutter_preferences` table. **Plan 04-11 is the migration that copies them
across, and it has not landed.**

So on this branch, before 04-11, every shared preference reads as **absent** —
not stale, not wrong, absent — and a caller cannot tell that from a plant that
has never been configured. That indistinguishability is the recurring trap of
this milestone (six near-misses), and here it is the whole defect.

**What a station that took this branch today would come up without:**

| Key family | Group | What the operator sees |
|---|---|---|
| `alarm_man_config` | configure | no alarms at all; `AlarmMan` builds on the empty default |
| `page_editor_top_level_order` | configure | the menu in whatever order the pages happen to come out in |
| `page_editor_image:<id>` | configure | every uploaded image on every mimic fails to load (`PageImageStore.load` answers null) |
| `<bucket>.recipes` | setpoints | recipe assets open with no recipes |
| `server_config_envelope` | administer | the stored server configuration reads as unset |
| `collector_config` | administer | the collector falls back to its default |
| `update_channel` | administer | unset |

Two boundaries, both narrowing the blast radius and both worth stating so that
nobody over-corrects:

* **Pages, assets and key mappings are unaffected.** They moved onto rows in
  Phases 2 and 3 and were migrated then; the mimics themselves come up.
* **`state_man_config` is unaffected.** It is written `secret: true`, so it
  lives in the OS keychain, which this plan did not touch. A station still
  knows how to reach its PLC.

**Nothing is lost.** `flutter_preferences` is untouched — 04-12 is what drops
it — so this is fully reversible: reverting the branch restores the previous
behaviour with every value still in place.

**The sharp edge, which is worse than a blank read.** Several of the missing
keys have *boot defaults* that the app writes for itself through
`systemPreferencesProvider` — `alarm_man_config` at `lib/providers/alarm.dart:28`,
`collector_config`, and the empty recipe list written on the recipes **read**
path. Against a reachable Postgres those defaults now succeed: the station
writes an **empty** `alarm_man_config` row into the shared store, which every
other station then syncs. The migration afterwards is no longer copying into an
empty table — it is reconciling against rows a booting station invented. 04-11
must decide explicitly what wins, and must not assume the destination is empty.

**Why it is deferred rather than fixed here.** The only fix available inside
04-05 would be a read-through fallback to `flutter_preferences` when a row is
absent — which is precisely "cannot tell empty from not yet loaded" written
into the store on purpose, and would need its own ruling on which of the two
stores is authoritative during the window. That ruling belongs with the
migration that closes the window, not with the plan that opens it. The plan's
own ordering is deliberate: 04-12 retires `Preferences` "once the migration
(04-11) has landed", so the swap was always meant to precede it.

**What closes it:** plan **04-11** landing. Until then the two are one
deployable unit — **this branch must not reach a plant without 04-11 in the
same release.** Plan 04-13's runbook must carry that as a hard precondition and
not as a recommendation; a release that ships 04-05 alone is a plant-wide loss
of alarm configuration on the first restart.


## D-8 — the MCP server logs "Connected to PostgreSQL" when it has not connected

**Found** 2026-09-08, while fixing the toggle fail-open (`d47f7633`).
**Not fixed**: outside that fix's surface, and it is an MCP-server defect
rather than a milestone one.

`ServerDatabase.fromConfig` builds its pool through `Pool.withEndpoints`,
which is **lazy and never throws**. So the `on Exception` arm at
`tfc_mcp_server.dart:112-119` — the one that falls back to
`ServerDatabase.inMemory()` — cannot fire at startup. Probed directly:

```
--db-host no-such-host.invalid --db-port 1
→ "Connected to PostgreSQL at no-such-host.invalid:1/hmi"
```

The binary reports a connection it does not have. A real connect failure
surfaces later, per-query, where it reads as a query bug rather than as the
server having no database at all.

Two consequences worth stating:

- **The in-memory fallback is dead code.** Anything reasoning about the
  binary's behaviour "during an outage" — including addendum 2 of
  `.planning/.../04-CORE-REVIEW.md` — should say per-query failure, not
  empty tables. The fail-open that addendum described was real regardless,
  through its *first* path: a migrated plant, database reachable, simply
  empty of MCP keys. No failure was needed to trigger it.
- **A false "Connected" line is worse than a silent failure**, because it is
  the line an engineer greps for when deciding whether the database is the
  problem.

**Fix direction:** either make the arm reachable (probe the connection at
startup and let it fail loudly), or delete the arm and the message together.
What must not survive is a log line asserting something the code has not
established.

## D-9 — audit rows are lost, not queued, when the database is unreachable

**Found** 2026-09-08 alongside D-8. **Not fixed**, and deliberately ranked
below it.

With no reachable database the MCP server's audit writes go nowhere. This is
**lost provenance during an outage, not lost privilege** — no capability
decision is made off the failure, which was checked explicitly: tool
registration is toggles-only, the two `!= null` gates test injected objects
and narrow rather than widen, every `isEmpty` shapes a message, and no write
tool consults the database for permission (they are proposals; authorization
happens at approval, in the app).

It is recorded because "the trail is complete" is a claim this milestone
makes elsewhere, and an outage is the one window where it is not true.

## D-10 — four API defaults still mean "every tool group enabled"

**Found** 2026-09-08 while flipping the *stored* toggle defaults to false
(`d2c91ea5`). **Not fixed**, deliberately — see below.

`McpToolToggles.allEnabled` remains the Dart parameter default at four sites:

- `packages/tfc_mcp_server/lib/src/server.dart:87`
- `lib/mcp/mcp_bridge_notifier.dart:283` and `:578`
- `lib/mcp/mcp_sse_server.dart:40`

These are function parameter defaults, not stored settings, so they sit
outside the ruling that produced `d2c91ea5`. But they are the same shape as
the defect that ruling fixed: **an omitted capability argument means "all
on"**, on the surface SAFE-03/SAFE-04 exist to gate.

**Not live today**, verified: both `connectInProcess` calls in `chat.dart`
(`:1001`, `:1185`) pass `toggles:` explicitly, and the subprocess path takes
`CENTROIDX_MCP_TOGGLES`. Nothing currently reaches these defaults. It is a
latent trap, not an open hole.

**Why deferred rather than flipped:** it would re-baseline roughly 24 test
constructions that presently get all-enabled implicitly, and it was found
while a 180-commit branch was being compiled by CI for the first time. Two
signals at once is how a real failure gets attributed to the wrong change.

**Recommended fix, which is not "flip the default":** make the parameter
**required**. A required argument removes the question instead of answering
it, and the compiler names every call site. Flipping the default instead
changes behaviour silently at sites nobody revisits — which is exactly the
hazard found one level up in the same change: `static const allEnabled =
McpToolToggles();` would have become **all-false** the moment the constructor
defaults flipped, turning every "all tools on" call site off while compiling
cleanly.

## D-11 — the MCP server binary could never start on Windows (FIXED, `940786da`)

**Found** 2026-09-08 by CI, on the first test that ever spawned the binary.
**Fixed in the same session**; recorded because how it hid matters more than
the one-line fix.

`bin/tfc_mcp_server.dart` called `ProcessSignal.sigterm.watch()`
unconditionally. Windows has no SIGTERM, and Dart does not hand back an empty
stream there — it throws:

```
Unhandled exception:
SignalException: Failed to listen for SIGTERM, osError: OS Error:
The request is not supported, errno = 50
```

Unhandled, at startup, before the server answers `initialize`. **The binary
has never been able to run on Windows**, and this repository ships a Windows
MSIX. It would bite a station that fell back to the subprocess path, or an
engineer pointing an MCP client at a Windows install; the in-process path the
HMI normally uses does not go through this binary, which is why nobody hit it.

**Why it hid.** Nothing in the repository ran the binary. The other ~1360
tests in that package import the library. `compile_test` does build the
executable and run it — but only as `--version`, which returns from `main`
long before the signal handlers are installed. So the one test that executed
it never reached the crash. A smoke test that spawns the binary and speaks MCP
to it found the defect on its first run.

Two lessons, both earned twice today:

- **Exit code 255 is Dart's unhandled-exception code.** It was the informative
  signal from the first CI log and was reasoned past in favour of a
  file-locking hypothesis that fit the timestamps and was wrong.
- **A test that spawns a process and does not drain its stderr can only ever
  tell you *that* it failed.** The binary printed the exception every time;
  nothing was listening until the drain was added.

### Open consequence — graceful shutdown on Windows

With the guard in place, Windows has no graceful-shutdown path at all: the
Flutter side's SIGTERM maps to `TerminateProcess`, so the process dies without
closing its database or flushing its log. Inherent to the platform rather than
to the fix, minor, and closing it would need a different shutdown channel
(a control message over stdio, or a named event). **Not fixed. Jón's call.**

---

## Review pass, 2026-09-11 — what changed before the merge

A review of the whole branch (five independent readers over the store, the
page path, the history and undo surface, the MCP server and backend, and
every consumer of `preferencesProvider`) found the defects below. **All were
fixed on the branch**; they are recorded here because each one is the kind
that would have shipped green.

**Lost writes and stale saves.**

- `ConfigStore.writeItems` read the compare-and-swap revision off the live
  snapshot inside its transaction, after awaits, so a sync apply landing
  mid-save moved the target: another station's edit was matched at its new
  revision and overwritten. The CAS now guards with the revisions the diff
  was computed against, and every write runs on the sync engine's
  serialisation chain (re-entrant, so undo's assert-then-write still works).
  The same class of race in `_apply` — a pull that read "row absent" before
  a local insert, then deleted the row from the snapshot — is closed by the
  same serialisation.
- The page editor saved the whole plant from the layout it loaded when it
  opened. A page another station added meanwhile was deleted, cleanly; an
  edit to a page this operator never touched was overwritten. Saves now go
  through `mergeForSave` (`page_codec.dart`), decided per page against what
  the store holds and what the editor was shown; the key repository has the
  per-item version (`config_merge.dart`) through `saveKeyMappings(baseline:)`.
- Page settings edits (`CreatePageWidget`) rebuilt `AssetPage` without its
  `id`, so a rename was a delete plus a re-insert that restamped every asset
  on the page. An asset added in the editor was minted a fresh id on every
  save, because the id landed on the JSON copy the save uses and never came
  back. Two pages at one path were collapsed by `pagesJsonOf` and the second
  deleted by the next save; the merge now refuses the path.
- Image collection ran from a station serving a fallback layout (every image
  looked unreferenced) and took images another station had picked but not
  yet saved a page for. It now skips fallback stations and keeps rows newer
  than a day.

**Migrations.**

- `blob_migration.dart` counted any shared row of the kind as proof the
  migration had run; a `seedDefaultIfEmpty` placeholder, or a station whose
  copy rolled back, left the plant's real keys in the blob forever. The
  marker is now the only gate, the copy writes over a seeded row (rev bumped,
  logged as an update), and `noBlob` writes the marker so a plant that never
  stored a blob is not refused by the sync engine and the preference
  migration on every boot.
- `state_man_config` was migrated into a shared, non-exempt row: PLC
  endpoints and credentials in a replicated table and a permanent log, for
  no reader (the app reads it `secret: true`). Abandoned by name.
- `chat.*` and `llm.*` keys were unknown to the migration — chat history and
  provider settings lost at the cutover, and the drop tool blocked forever.
  Both are migrated; `chat.` rows are history-exempt, because a transcript
  rewritten on every message would have been O(N²) bytes in a table nothing
  prunes.
- The drop tool verified marker presence and key *names*, never that a
  migrated key had a row: a known key whose value the migration could not
  read was dropped with its only copy. It now checks every migrated key for
  its row, and runs its gates and the drop in one transaction under the
  migration's advisory lock.
- `AppDatabase.native` was `executor is NativeDatabase`, false for the
  background executor `createLocal` opens, so the first upgrade of a local
  mirror would have run the Postgres DDL against SQLite. Now the dialect.

**Readers.**

- The MCP server handed the `{type, value}` preference envelope back as the
  document: every alarm tool saw zero alarms on a migrated plant. The
  fixtures seeded the bare document, so no test could see it. Both fixed.
- The backend's restart fingerprint (`count + Σrev`) could not see a key
  rename; it now carries the change log's high-water mark as well.
- `alarmManProvider` threw at boot when the snapshot had no
  `alarm_man_config` — offline first boot, the degraded in-memory store, or
  the attach race — because `AlarmMan.create` seeded through the checked
  setter. `create` treats absence as empty and writes nothing; the provider
  waits for the first sync before deciding the plant has none.
- `page_editor_top_level_order` is written shared and was read device-local
  at boot, so the menu order reverted on every restart. `PageManager.load`
  reads the shared row from the mirror first.
- History paging on a strict `at <` cursor could not reach the rows of an
  action that straddled the 500-row cap; the cursor is `(at, id)`. The cap
  and the cursor are judged on the raw row count, so an undecodable row does
  not hide the Load-more control. Tiles are keyed by row and action; a
  removed field renders as `old → —`; an unclassified undo error is told
  rather than swallowed; double-tap is refused.
- The raw preferences editor and the recipe dialog let a refused write
  escape silently; both now say so.
- `scripts/check-flutter-preferences-retired.sh` did not run in CI. It does.
- `Database.isConnectionError` did not classify the driver's "socket closed
  unexpectedly" (a statement on the wire when the peer dies) or a timeout.

**Closed by this branch, and worth saying:** D-2 (the key-mapping listener
is on a store with a stable identity), D-7 (04-11 landed). D-3, D-6, D-8 to
D-10 stand as written.
