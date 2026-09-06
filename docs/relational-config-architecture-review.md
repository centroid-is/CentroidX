# Relational config storage — architecture review

Review of [relational-config-research.md](relational-config-research.md),
written 2026-09-06 against the `relational-config` worktree, including the
in-flight code under `packages/tfc_dart/lib/core/config/`. Ordered so the
things that are wrong come first; agreement is stated once and briefly.

**Verdict in one paragraph.** The shape is right: one generic `config_item`
table, current rows plus a separate append-only `config_change`, Postgres
owner with a same-schema SQLite mirror, repository above two `AppDatabase`
instances rather than anything at the `QueryExecutor` layer. Four things are
wrong or unstated and two of them corrupt history if built as drafted:
(1) `parent_id` and `sort_index` live outside the payload, so the change log
cannot record or restore position; (2) `kind='page'` keyed by path breaks
identity on rename, and pages *are* renamed; (3) the write path in §3.3 is
Postgres-first and therefore cannot be the write path for station-scoped
rows, whose audit story is unstated; (4) nothing structural stops a
station-scoped row from reaching the shared database, and the row it would
leak is the per-station Postgres endpoint. All four have cheap fixes. The
sequencing is right with one amendment to Phase 0 and one scope cut to
Phase 3. The keychain should shrink to wrapping one key, not disappear.

---

## 1. Attacks on §3

### 1.1 The change log cannot restore what it does not record — position

`config_change` stores `old_value`/`new_value` payloads only
(`config_change.dart`), while `parent_id` and `sort_index` are columns on
`config_item` beside the payload (§3.1). So the drafted design records a
"move asset to another page" or a z-order change as an update whose two
payloads are **identical**, and a restore that writes `old_value` back puts
the asset on the wrong page in the wrong paint order. `ConfigDiff` even
compares `parentId`/`sortIndex` (`config_diff.dart`, "exact over
[ConfigItem.parentId] and [ConfigItem.sortIndex]"), so the write fires — it
just writes a history row that says nothing.

The fix is a rule, not a schema change: **the payload is the complete
entity, position included.** Serialise parent and order into the payload;
if the `parent_id`/`sort_index` columns survive at all they are derived
copies for human legibility, never read by code. Honestly, under §2's own
rule — *no query ever filters config in the database* — the columns have no
reader and I would drop them. Every argument the research makes for "full
entity on both sides, restore is writing `old_value`" (§3.2c) requires
this; as drafted the design violates its own best argument.

### 1.2 Page identity: the path is not an id

`kind='page'` uses the path as id and assets carry the path as `parent_id`
(§3.1). But pages are keyed by path *and paths are edited*:
`page_editor.dart:5693` (`_updatePathInChildren(oldPath, newPath, …)`)
exists precisely because renames happen. Under a `(kind, id, scope)` primary
key a rename is a delete-plus-insert of the page and a rewrite of every
child asset — the page's history is cut in two at the rename, "restore page
X to Tuesday" needs to know what X was called on Tuesday, and `parent_id`
references go stale in every change row written before the rename.

Assets already solved this: `Asset.id` is stable and the path is data. Do
the same for pages — mint a stable page id at migration (the migration
already mints asset ids), keep the path inside the payload, and let the
in-memory snapshot index path→id the way it indexes everything else. The
route registry is already "registered flat, keyed by path"
(`page.dart:441`) from an in-memory map, so navigation does not care. This
costs one field and removes an entire class of history discontinuity.

### 1.3 Reordering writes N rows for one drag

With dense integer `sort_index`, dragging one asset to the front renumbers
its siblings: one gesture, dozens of change rows whose payloads differ only
in an order field. That is exactly the "290 KB of noise" problem at smaller
scale — the trail is complete and unreadable. Two acceptable answers:
gapped or fractional ordering keys (new key between neighbours, single-row
write, occasional rebalance), or dense keys plus a display layer that
collapses order-only changes under one action. The `action_id` grouping
makes the second tolerable; the first is a few lines and keeps the log
honest at write time. Either way, decide it now — it is a wire format.

### 1.4 One generic table: right, and here is the cost ledger

The research's argument for the generic table stands or falls on the §2
rule (no SQL-side filtering), and I verified the rule holds — the readers
materialise everything at boot and filter in memory. Given that, per-kind
tables would each collapse to `(id, payload, rev, …)` anyway: same shape,
N times, plus a schema migration per new kind. And mixed-version stations
(§5 Q5) turn "no DDL per kind" from a convenience into a real property —
an old station meeting a row of an unknown kind skips it
(`ConfigKind.byWireName` is nullable for exactly this,
`config_item.dart:126`), whereas an old station meeting an unknown *table*
in a migration-versioned drift schema is a harder conversation.

What the generic table genuinely costs, which §3 does not account:

- **No real foreign keys.** `parent_id` cannot be a constraint when the
  parent's kind varies. Deleting a page must delete its assets in the one
  write path, and a bug there leaves orphans no constraint will ever
  surface. Mitigation: the write path owns cascades, and a consistency
  check (every `parent_id` resolves; `config_item.payload` equals the
  latest `config_change.new_value`) runs in tests and is cheap enough to
  run in CI against a seeded database. Accept the cost with eyes open.
- **No per-kind CHECKs.** Payload validity is enforced only by the codecs.
  The round-trip property test in §6 is the actual guard; it is the right
  one, and it must therefore be treated as load-bearing, not optional.
- **`kind` rot is bounded, not absent.** The enum's wire names are
  append-only and the doc says so; the rot risk is payload *shape* drift
  within a kind. Old rows must stay readable by new `fromJson` forever —
  which is already the contract the JSON blobs live under today, so this is
  not a regression, but write it down as a rule: config `fromJson` never
  loses backward compatibility, and the change log is the reason why.

Verdict: keep the generic table.

### 1.5 `scope`: the idea is right, the enforcement and the write path are missing

Folding both owners into one *schema* is correct — it is what makes the
mirror a row copy and the API singular. Folding them into one *table
instance* is where three unstated problems live:

**(a) Nothing stops a station row reaching Postgres.** The invariant "a
row that is local-only must never be included in a push"
(`config_item.dart`, `ConfigScope.isShared`) lives entirely in repository
code. The row it would leak is `DatabaseConfig` — a *different* Postgres
endpoint per machine, where one station adopting another's has already
caused real trouble. One line of DDL makes the invariant structural:
`CHECK (scope = 'shared')` on the Postgres `config_item` and
`config_change`. Cheap, and it converts a subtle sync bug into a loud
constraint violation. Do it.

**(b) §3.3 is not the write path for station rows.** The one write path is
"one transaction in Postgres → audit → mirror → notify". Station-scoped
rows are owned by SQLite and must be writable with Postgres absent — that
is their reason to exist. So there are necessarily *two* write paths: the
shared one as drafted, and a local one (SQLite transaction, local change
rows). The research says "same table, same API, same history, same audit"
(§3.1) — the first two are true, the last two are currently false and need
a decision: does a station-scoped change get a local-only `config_change`
(my recommendation: yes, same schema, in the mirror database), and does it
ever reach the central `audit_entry`? Best-effort upload when Postgres
returns is possible but is a queue, which Q6 just declined to build for
shared writes. Recommend: local log always; central audit for station rows
is a later, explicitly-queued feature or accepted as absent. State it in
the spec either way — "same audit" as written promises something the
design cannot deliver.

**(c) The hostname in `station:<hostname>` conflates two ideas** —
"must be readable before Postgres" (DatabaseConfig, session) and
"per-station by policy" (startup page). It earns its place only through
the backup-restore argument in `config_item.dart` (rows from another
machine's backup do not adopt this machine's identity — good), and it
keeps the door open to later mirroring station rows *up* for central
visibility. Keep it, but note the operational edge: a reimaged or renamed
station orphans its own rows, so the boot path needs a stated rule for
"rows exist for a hostname that is not mine" (leave them; they are inert
by construction).

Also, a factual correction to §1.4: the per-station `DatabaseConfig` is
not in `shared_preferences` — it lives in the OS keychain
(`database.dart:196`, `SecureStorage.getInstance().read(key:
'database_config')`), password included. That moves it from the Phase 0
column of the plan into the secrets question (§3 below), and the research
table should say so, because "the row that says how to reach Postgres" is
currently also the row that says the password.

### 1.6 SCD-2, argued properly

The strongest case for SCD-2 is not point-in-time queries — it is
**integrity by construction**. Current-rows-plus-log stores the present
twice: `config_item.payload` must equal the latest `config_change.new_value`
for that entity, and nothing but discipline keeps them equal. SCD-2 has one
copy; the current row *is* the open-ended history row, and it cannot drift
from itself. A second real point: the log design makes "history of this
entity" an index lookup on a table that grows forever, while SCD-2 keeps
history physically beside the entity and prunes… never, which is where the
steelman dies. Because the mirror then must either carry all history to
every station or run a filtered sync ("current rows only") that is itself a
temporal predicate applied on every sync — the exact class of subtle bug
this plant does not need. And the hot read path carries
`WHERE valid_to IS NULL` forever, on both engines, for a question asked a
few times a year.

The drift risk that is SCD-2's best argument is containable here because
there is exactly **one** writer per scope (the write path of §3.3/1.5b),
both rows land in one transaction, and the invariant is mechanically
checkable — put `payload == latest new_value` into the consistency check of
§1.4 and the drift risk is a test failure, not a slow corruption.
Current-plus-log also matches the house architecture: `audit_entry` is
already a separate append-only trail with `action_id` grouping, and
`config_change` is deliberately its detail table. **Confirm (c).** Q2 can
come off the list.

### 1.7 `rev`: right token, two sharpenings

Per-entity `rev` with disjoint owners (Postgres bumps shared, SQLite bumps
station) is sound. Two requirements the research implies but must state:

- **CAS in SQL, not read-check-write.** The check is
  `UPDATE … SET rev = rev + 1 WHERE kind=? AND id=? AND scope=? AND rev=?`
  inside the transaction, rows-affected tells you whether you lost. An
  app-level compare against a previously read `rev` is a race with the
  other station, which is the thing being prevented.
- **Q7's "page-level rev" does not exist as a row** once assets are rows.
  Two stations editing different assets of one page both succeed — that is
  the designed improvement, not a conflict. Same-asset conflicts CAS-fail
  per entity, and the editor turns a failed save into "reload". If the
  owner wants whole-page pessimism it must be synthesised (max rev over
  the page's entities, or an explicit page rev bumped by every child
  write); recommend not building it until someone asks.

And one freebie §3.2 leaves unclaimed: `config_change.id` is a global
monotonic watermark. The mirror can sync "changes since N" instead of
diffing full row sets, and the LISTEN/NOTIFY payload shrinks to nothing —
notify once per transaction (per `action_id`, not per row) and let
receivers pull from their watermark. That also makes missed notifications
harmless: a periodic watermark poll catches up, which retires the
`md5(value)` machinery (`database_drift.dart:1597`) with something strictly
more robust than what replaces it in the draft.

### 1.8 Smaller findings

- `samePayload`'s structural compare (`config_item.dart`) correctly
  absorbs the int/double round-trip hazard (`1 == 1.0` is true for Dart
  `num`), so web-vs-native encodings will not produce phantom edits. Good.
- Write-granularity is the **top-level asset**: `childAssets` nest in the
  payload, so editing one subdevice of a `BeckhoffCX5010Config` rewrites
  and logs the whole parent. Fine at current sizes — say it in the doc so
  nobody is surprised when a deep composite makes a fat change row.
- `config_snapshot` appears only in the rollback table (§3.2). It is a
  named export row; defer it, but reserve the name.
- `tech_doc_library_section.dart:1317` constructs its own device-local
  prefs instance today. Multiple independent handles over one SQLite file
  need WAL mode or a shared connection behind the factory — a Phase 0
  implementation note, not a design problem.

---

## 2. Sequencing

**Phase 0 first is right, and it is the first shippable PR.** It is
self-contained, removes a measured UI-isolate stall (35.5 ms per four keys,
`preferences.dart` doc), and the factory really is a single construction
point behind `createDeviceLocalPreferences()`
(`lib/providers/preferences.dart:27`, enforced by
`scripts/check-preferences-construction.sh`), so the blast radius claim
holds. One amendment: **Phase 0 should write into the `config_item` table
in the local database** — `kind='preference'`, station scope — not into a
throwaway key-value table. The table definition is drafted, §1 above
settles its open points, and a bespoke Phase 0 schema means migrating the
local store twice. The Postgres side, `config_change`, and codecs all stay
Phase 1; Phase 0 just refuses to create a second disposable local format.
Boot ordering and the one-shot import stand as written in §4b.

**Phase 1 with `key_mappings` first is right** — biggest blob, flat
entities (no parent/order problems from §1.1–1.3 apply), and
`KeyMappingsUpdateResult` is a ready-made consumer for the diff. Two
additions: dual-write (Q5) is not a late option, it is *in the first
Phase 1 PR* — the moment one station writes rows, unupgraded stations must
keep seeing a coherent blob, so the row write and the legacy blob write
share a transaction for one release. And the blob→row data migration on the
shared database needs a single-writer story: two stations upgrading the
same morning must not race the migration. Drift's schema versioning gates
the DDL but not the data copy; take a Postgres advisory lock around it.

**Phase 2 pages/assets** — after §1.1–1.3 are folded into the design, as is.

**Phase 3 — cut it.** Do not fold `access_template`, `app_user`,
`history_view*` into `config_item`. They are already relational, already
audited, and the access tables are the substrate that *gates* config
writes — folding the gate into the thing it gates is circular (who guards
the write that edits the guard's own storage, through the same table?).
"One strategy" is worth having as one *ownership/audit/mirror* semantics
and one write discipline, not as one physical table; genuinely relational
data staying relational is the strategy working, not an exception to it.
This is a scope cut against steer #3 and should be said to the owner in
those words. `flutter_preferences` itself still dies (Q10): scalars become
`kind='preference'` shared rows in Phase 1's machinery at near-zero cost,
and the table drops after the compatibility window.

---

## 3. Secrets: what the keychain actually buys here

What goes through it today: `StateManConfig` — OPC UA usernames and
passwords in the clear inside the JSON (`state_man.dart:133-134`) — via
`secret: true` (`state_man.dart:497`); LLM API keys
(`chat_widget.dart:361`, `providers/llm.dart:23`); `DatabaseConfig` with
the Postgres password, written directly against `SecureStorage`
(`database.dart:196`); and the D-Bus station credential
(`dbus_login.dart:118`). Backends: on Windows/macOS, flutter_secure_storage
behind a migration wrapper (`centroid-hmi/lib/main.dart:248`); on
Linux/eLinux, `AwsSecureStorage` → amplify → **libsecret**, i.e. the
Secret Service D-Bus API (`secure_storage/linux.dart`).

Now the threat model: unattended kiosk panels, in containers, that must
boot with no human present. A keychain's at-rest protection derives from a
credential a human supplies at unlock. With nobody to supply one:

- **eLinux/Docker**: `docker/frontend/Dockerfile:80` installs only
  `libsecret-1-0` — the *client*. No keyring daemon ships in the image, so
  whatever Secret Service the container reaches (via the mounted bus, from
  the host image in debos-conf) is necessarily auto-unlocked with a blank
  or well-known password, or absent. Encryption keyed by a secret that
  sits beside the data is obfuscation. On the actual plant hardware the
  keychain buys **file permissions plus indirection, nothing more** — and
  it costs the amplify service-name trap (`linux.dart`: renaming the
  namespace orphans every deployed secret), a D-Bus dependency in the
  container, and a fallback that throws on unknown platforms
  (`secure_storage.dart:29`).
- **Windows**: DPAPI is transparent, promptless, and gives real at-rest
  binding to the machine/user account — a stolen disk (not a stolen
  running machine) yields nothing. This is the one platform where the OS
  facility earns its keep in this deployment.
- **macOS**: dev machines only, where the keychain actively costs — every
  debug rebuild re-prompts for the login keychain password.

So the honest answer to "remove the keychain and do something simpler with
SQLite" is: **mostly yes, with one key left behind.** Recommended shape:

1. Keep the `secret: true` routing in `PreferencesApi` — callers do not
   change, and the seam is already enforced.
2. Store secrets as station-scoped rows in the local SQLite, each value
   wrapped in a `SecureEnvelope` (`server_config.dart:41` — PBKDF2 +
   AES-256-GCM, already built, already has the KDF test hook via
   `Pbkdf2Kdf.iterationsForTest`). Encrypt with a random per-station
   256-bit data key, not a passphrase-derived one (skip the KDF at read
   time; it exists for human passphrases).
3. The data key is the only thing the platform facility holds: DPAPI on
   Windows, Keychain on macOS (one entry, read once per boot — retires
   the per-secret prompt pain and the `Preferences._secretCache`
   complexity it forced), and on eLinux a root-owned 0600 file — stated
   plainly in the deployment doc as "permissions plus obfuscation", which
   is **not a regression from what libsecret delivers there today**.
4. Rules that must hold regardless: secrets never become `shared` rows
   (Postgres, its backups, and the ssh+psql tooling must never see them);
   secrets never enter `config_change` with values — the guarded layer
   already writes `newValue: secret ? null : value`
   (`guarded_preferences.dart:365-369`) and the change log keeps that
   contract: an audit row saying *changed*, no before/after.
5. The one secret with real internet value is the LLM API key — a leaked
   OPC UA password is worthless off the plant network, a leaked Anthropic
   key is a bill. That argues for scoping/rotating those keys
   operationally, not for keeping three keychain backends.

This is separable work. Decide the direction now (it settles what §1.5's
station scope must carry), build it after Phase 1. Do not couple it to
Phase 0 — §4b already says secrets are unaffected, and that stays true.

---

## 4. The question list, resharpened

Cut — the architect can decide these, and this review does:

- **Q1** (order): decided above — Phase 0 amended, Phase 3 cut.
- **Q2** (history model): confirmed (c), argued in §1.6.
- **Q7** (conflicts): per-entity CAS, editor prompts reload; page-level
  pessimism not built until asked for (§1.7).
- **Q9** (retention): forever. Small rows, and the audit trail already has
  a never-prune contract asserted in test.
- **Q4** (other readers): read-only compatibility views for
  `page_editor_data`/`key_mappings`, port `tfc_mcp_server`'s raw SQL
  (`config_service.dart:87`) in-repo during Phase 1–2; the owner's own
  `tools/svn_*.py` migrate at his leisure against the views. A *writable*
  view is real work — do not promise it; the python tools that write can
  target the new tables directly when they move.

Proceed under stated assumption — say the assumption out loud, do not wait:

- **Q3** (rollback scope): build (a) undo-action + (d) see-what-changed;
  (c) checkpoints are one export row when wanted; (b) point-in-time next.
  The schema supports all four, so nothing is foreclosed.
- **Q6** (offline edits): refuse *shared* writes clearly when Postgres is
  down — station-scoped writes always succeed locally, and the wording of
  the refusal should say which kind the user just attempted. Strictly
  better than today's silent loss; an offline queue remains buildable
  later if the plant demands it.
- **Q10** (fate of `flutter_preferences`): destination is "dropped", but
  no phase before the compatibility window closes depends on the answer.

Genuinely blocking:

- **Q5 — mixed-version cutover.** Dictates the first Phase 1 PR's shape
  (dual-write in-transaction, one release, then drop — recommended) and
  whether the Q4 views must exist before or after cutover. This is the one
  question whose answer changes code that ships first.
- **Q8 — fresh production dump.** The round-trip property test
  (`blob → items → blob` structurally identical) is the migration's safety
  net and it is only evidence if it runs against current production data.
  Blocking for cutover, not for building.

Add — load-bearing questions §5 missed:

- **Q11 — secret storage direction.** §3 above is the recommendation;
  needs the owner's yes, because it decides whether Phase 1's station
  scope carries envelope-wrapped rows and what dies with amplify.
- **Q12 — station-scoped audit.** Local-only change log, or best-effort
  upload to central audit? (§1.5b.) Recommendation: local-only now,
  uploading is a feature with a queue attached.
- **Q13 — page identity.** Stable page ids (§1.2) change the migration
  (mint ids) and the wire format; cheap now, expensive after Phase 2
  ships. Recommendation is stable ids; flag it because it touches the
  owner's mental model of "the page's id is its path".

---

## 5. Addendum — review of the committed codec slices (2026-09-06, later)

Covers `1126fc39` and `5f4208b8`: `config_item.dart`, `config_change.dart`,
`config_diff.dart`, `key_mapping_codec.dart`, `lib/core/config/page_codec.dart`
and their tests. Two questions were put to this review directly.

### 5.1 Derived asset ids: keep the hash, but it is not the concurrency mechanism

`derivedAssetId(pagePath, index, payload)` (`page_codec.dart`) is sold as
what makes the migration idempotent across stations that boot together. It
does less than that, and it should stay anyway. Precisely:

**What the hash actually guarantees** is that identical inputs produce
identical ids. Stations converge only when every migrating station derives
from *the same bytes*. The dangerous race is not two stations migrating the
fresh Postgres row — that converges — it is one station migrating from a
stale copy (its in-memory model, or the local cache that
`syncToLocalCache` keeps): divergent payloads hash to divergent ids, and
the table ends up holding the same physical asset twice with **no primary
key violation to say so**, because the ids differ. Random ids fail worse
under the identical race (they *always* diverge), so the hash is strictly
the better mint — but neither closes the race. What closes it is the §2
requirement restated: the migration reads the blob from Postgres and
writes rows **in one transaction under an advisory lock**, never from a
local copy. With that lock held, hash-versus-random is a correctness wash;
the hash then earns its keep twice over — a re-run during the dual-write
window writes nothing without needing an "already migrated" flag, and
deterministic ids are what let `page_codec_test.dart` assert stability at
all. So: derived ids **and** the lock, and the doc comment should stop
implying the hash alone makes concurrent migration safe.

Two conditions on the surrounding machinery:

- **The `??=` guard is the real convergence mechanism for late migrators**
  (`asset.id ??= derivedAssetId(…)`), and it only works if the id-bearing
  blob is written back in the same locked transaction — dual-write with
  ids embedded — so that every later reader derives nothing. `Asset.id`
  already round-trips through deployed stations' `toJson`, so an
  unupgraded editor saving the blob preserves the minted ids rather than
  stripping them. That property is load-bearing; assert it in the
  round-trip test.
- **Restrict `derivedAssetId` to the migration.** As committed,
  `pageItems` mints derived ids on *every* save for any id-less asset, and
  post-cutover new assets are born id-less. Two editors concurrently
  adding an identical asset at the same index of the same page derive the
  same id, and two people's assets silently collapse into one row — the
  precise failure per-entity rows exist to end. The fix is free:
  `Asset.ensureId()` (`common.dart:361`, random `newAssetId()`) at asset
  creation in the editor, so `pageItems` never meets an id-less asset
  outside the migration. 96-bit truncation collisions are not a concern at
  any plausible asset count.

### 5.2 The normalising round trip: right contract, one real bug, and what it does to Q4

That `blob → items → blob` is normalising rather than byte-identical is
the correct contract, not a concession — byte identity was never
attainable (legacy blobs carry incidental key order and explicit nulls)
and nothing needs it. Structural identity, which the tests assert, is the
bar. But the finding surfaced one genuine defect and two consequences:

**The bug: `canonicalJson` is not canonical for page payloads.**
`AssetPage.toJson()` returns a live `MenuItem` object
(`@JsonSerializable()` without `explicitToJson`, `page.dart:15`), and
`canonicalise` (`config_item.dart`) sorts only what is already a `Map` —
the live object passes through opaque and its keys serialise in whatever
order `MenuItem.toJson()` emits at encode time. Encoding still *works*
(`jsonEncode` calls `toJson` on the way down), and diffs still work
(`samePayload` compares decoded structure), but the stated contract —
"the same configuration is always the same bytes" — is silently false for
`kind='page'`, and byte-determinism is exactly what §1.7's watermark
notify and any digest-based comparison lean on. Fix it at the codec
boundary, not per class: deep-encode (`jsonDecode(jsonEncode(…))`) before
canonicalising, which also inoculates against the next config class that
forgets the flag. `Asset` has `explicitToJson: true` (`common.dart:287`);
`AssetPage` merely proves the flag is forgettable.

**Consequence for the Q4 compatibility view: unaffected in substance,
with one determinism requirement.** Every external reader — the MCP
server's raw SQL, `page_geometry`, the python tools — *parses* the blob;
none compares its bytes. The one byte-comparer is `PreferencesWatcher`'s
server-side `md5(value)`: during the dual-write window the reassembled
blob must therefore be **deterministic** (canonical encoding gives this),
or every save produces textually-new bytes and every station reloads on
every save. Expect exactly one spurious, harmless reload when the blob's
shape first changes at cutover. The view's contract should be written as
"structurally equivalent, canonically encoded" — never "identical to what
the app used to write".

**Consequence for the change log: serialization drift reads as edits.**
`samePayload` correctly treats `{"k": null}` and an absent `"k"` as
different, so the first save after any future `toJson` shape change logs
change rows whose diff is pure serialization shape, attributed to whoever
happened to save. Do not normalise nulls away to hide this —
`fromJson` defaults can make null and absent semantically distinct —
accept it and document it, and let the display-diff layer label
"field present→absent, value unchanged" honestly rather than as an edit.
It is a once-per-upgrade blip, and the `action_id` grouping already keeps
it to one visible action.
