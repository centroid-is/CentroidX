# The relational-config cutover runbook

**What this is.** The plant's configuration — pages, assets, key mappings and
the shared settings — has lived in a single Postgres table called
`flutter_preferences`, as a handful of large JSON blobs. This milestone moves
it into ordinary rows in `config_item`, with a change log in `config_change`.
This document is how that change reaches the plant.

**Who runs it.** Whoever is at the plant, with ssh access to
`centroid@10.104.29.111`. It is written to be executed at night, alone,
against a working fish plant, with nothing open but this file.

**Read it once through before starting anything.** The order of section 4 is
load-bearing — not tidy, load-bearing — and section 4 explains why.

---

## Notation: which commands have been run, and which have not

Every command block in this document is marked. This matters more than it
looks like it does: a command that has only ever been read is a command that
may have a typo in it, and knowing which is which tells you how much to trust
the first thing that surprises you.

| Mark | Meaning |
|---|---|
| **[VERIFIED]** | Run against this branch, on a developer machine or in CI, and observed to do what it says. |
| **[TRANSCRIBED]** | Copied from research or from a script's source. **Never executed.** Read it before you run it. |
| **[PLANT ONLY]** | Can only be run against the plant. Never executed from any branch, by anybody, including the drop. |

`tools/svn_apply_config.py` is not in this repository — it is untracked in
Jón's main checkout — so **every command that calls it is TRANSCRIBED**,
quoted from the script's source, and has not been run by whoever wrote this.
The `psql` forms beside them were derived from the same source for the same
reason.

---

## 0. Preconditions

Confirm all four before you begin. Any one of them missing turns this window
into an outage.

1. **ssh to `centroid@10.104.29.111` works**, and `psql` (or `docker exec`
   into the Postgres container — see the container rule in section 1) reaches
   the `hmi` database as user `centroid`.
2. **You have a maintenance window** in which every station and the backend
   container can be stopped. There is no dual-write. During the window the
   plant is not being operated from the HMI.
3. **The build you are deploying contains the preference migration**, not just
   the row-backed preference store. See **section 4b** — this is the one thing
   in this document that destroys configuration if you get it wrong, and it is
   a packaging question you settle before the night, not during it.
4. **You have somewhere to put roughly 1 MB of dump files** that is not the
   plant. They are the rollback artefact.

---

## 1. THE DUMP

Nothing changes in this section. You are taking the rollback artefact, the key
inventory, and the two blobs the round-trip gate runs against.

Do not skip it because "the database is backed up anyway". The gate in
section 2 is the only thing that proves this build can read *this plant's*
configuration, and it cannot run without these files.

### 1a. The whole table, as CSV — the rollback artefact and the key inventory

**[TRANSCRIBED]**

```bash
python3 tools/svn_apply_config.py --backup-only
```

Defaults, from the script's own source: host `centroid@10.104.29.111`,
database `hmi`, user `centroid`. It writes `svn-prefs-backup-<UTC stamp>.csv`
with three columns — `key,value,type` — and a header line.

**REQUIRE THE ROW COUNT.** The script prints how many rows it wrote and warns
when the table looks empty. That number is the check:

- **Zero is always wrong.** It does **not** mean the plant has no
  configuration; it means you are pointed at the wrong database or the wrong
  user. Fix the `--dbname`/`--dbuser` and dump again.
- **Sanity-check the count against what you know is there.** A configured
  plant has, at minimum, `key_mappings`, `page_editor_data`,
  `alarm_man_config`, `collector_config`, `server_config_envelope`,
  `page_editor_top_level_order`, `startup_url`, plus one
  `page_editor_image:<id>` per uploaded mimic image and one `<bucket>.recipes`
  per recipe bucket. If the count is smaller than the list of things you can
  see working on the HMI, stop and find out why before you go any further.

A zero here is the quiet failure this whole document is built to avoid: an
empty CSV gives you an empty key inventory, which passes section 3 without
looking at anything, and a rollback artefact that restores nothing.

**Keep this file.** It is the only way back.

### 1b. The two blobs, raw

**[TRANSCRIBED]**

The gate in section 2 hands these files straight to a JSON parser. They must
therefore be the raw stored value and nothing else — no CSV quoting, no
header, no row count, no alignment. That is what `-A` (unaligned), `-t`
(tuples only) and `-c` (one command) buy you:

```bash
# Locate psql first -- see the container rule below.
PSQL="docker exec -i <pg-container> psql -v ON_ERROR_STOP=1 -U centroid -d hmi"

ssh centroid@10.104.29.111 "$PSQL -Atc \
  \"SELECT value FROM flutter_preferences WHERE key='page_editor_data'\"" \
  > /tmp/page_editor_data.json

ssh centroid@10.104.29.111 "$PSQL -Atc \
  \"SELECT value FROM flutter_preferences WHERE key='key_mappings'\"" \
  > /tmp/key_mappings.json
```

**The container rule**, taken from `svn_apply_config.py`'s own psql lookup:
use plain `psql` on the host if it is there; otherwise `docker exec -i` into
the **first container whose name matches `timescale` or `postgres`**.

**Check the sizes before going on:**

```bash
ls -l /tmp/page_editor_data.json /tmp/key_mappings.json
```

Expect roughly **145 kB** for `page_editor_data.json` and roughly **530 kB**
for `key_mappings.json`. A file of a few hundred bytes is a `psql` error
message that got redirected into it; a file of zero bytes is a key that did
not match. Either way, open it and look before continuing — `head -c 200` is
enough to tell JSON from an error.

---

## 2. THE GATE: does this build read this plant's configuration?

Three commands. **Two different test runners, in two different directories.**
There is no single command that runs all three, and running one of them is not
running the gate.

Every one of them is prefixed `CENTROIDX_REQUIRE_REAL_BLOB=1`. That variable
is what makes the gate refuse to pass vacuously: without it, each of these
tests silently falls back to a small committed fixture and goes green having
touched nothing of yours. With it, a missing blob path is a hard failure that
names itself.

### The three commands

**[VERIFIED]** — the mechanism, on this branch. **[PLANT ONLY]** for the blob
paths, which only exist once you have done section 1.

At the **repository root**:

```bash
CENTROIDX_REQUIRE_REAL_BLOB=1 \
CENTROIDX_PAGE_EDITOR_BLOB=/tmp/page_editor_data.json \
  flutter test test/core/config/page_codec_test.dart
```

In **`packages/tfc_dart`**:

```bash
CENTROIDX_REQUIRE_REAL_BLOB=1 \
CENTROIDX_KEY_MAPPINGS_BLOB=/tmp/key_mappings.json \
  dart test test/core/config/key_mapping_codec_test.dart
```

and, **against a real Postgres**, also in `packages/tfc_dart`:

```bash
CENTROIDX_REQUIRE_REAL_BLOB=1 \
CENTROIDX_KEY_MAPPINGS_BLOB=/tmp/key_mappings.json \
  dart test test/integration/key_mapping_migration_test.dart
```

Note the two different environment variables: the pages one is
`CENTROIDX_PAGE_EDITOR_BLOB`, the key-mapping one is
`CENTROIDX_KEY_MAPPINGS_BLOB`, and each test reads only its own. Setting the
wrong one leaves the right one absent, and `CENTROIDX_REQUIRE_REAL_BLOB=1`
will say so rather than quietly using the fixture.

### DO NOT RUN THE THIRD COMMAND ON THE PLANT SERVER

The third one is different from the other two in a way that will bite you.
"Against a real Postgres" does not mean the plant's — it means **one it
stands up for itself**. Before the tests run it does `docker compose up` from
`packages/tfc_dart/test/integration`, and afterwards `docker compose down`.

That throwaway database **binds ports 5432 and 15432 on the host**. 5432 is
the port the plant's own Postgres listens on.

So:

- **Run all three gate commands on a developer machine**, with the dump files
  copied over from section 1. That is what they are for.
- **Do not run them on the plant server**, or on anything that has a Postgres
  of its own on 5432.
- The container name and both ports are hardcoded, so **only one checkout may
  run this at a time**. Two at once bind the same ports and each tears the
  other's database down mid-run — which shows up as connection resets that
  look exactly like a resilience bug and are not one.
- Docker must be running, or the command fails on the compose step before it
  has tested anything.

The first two commands have none of this — no Docker, no ports, no database.
They will run anywhere.

### THE EVIDENCE RULE — exit code 0 is not acceptance

Each of these tests prints its source in the test group's name. **You accept
the run only if the printed line names your dump file.** For example:

```
page codec, over /tmp/page_editor_data.json
key mapping codec, over /tmp/key_mappings.json
key_mappings migration against Postgres, over /tmp/key_mappings.json
```

If instead you see

```
page codec, over the committed fixture
```

then the gate ran against the repository's toy fixture and **proved nothing
about this plant**. That is a failed gate, whatever the exit code said.

Two further tells, both worth knowing at 02:00:

- **A suspiciously fast run is the fixture.** The real `key_mappings` blob is
  around 530 kB and the real page blob around 145 kB; parsing and round-
  tripping them is visible work. A run that finishes instantly did not do it.
- **`CENTROIDX_REQUIRE_REAL_BLOB=1` with no blob path throws**, by design, in
  all three tests. The message names the variable it wanted. If you ever see
  one of these tests pass while that variable is set and the blob path is not,
  the guard has regressed — stop, and do not treat the gate as passed.

### If the gate fails

A genuine failure here — a page that does not survive the round trip, an asset
that does not — is the gate doing exactly its job. **Do not proceed to the
window.** The failure names the entity; capture the output and stop. Nothing
has changed on the plant at this point, which is the entire reason this
section comes before section 4.

---

## 3. INVENTORY: is there a key nobody has accounted for?

Take the key list out of the CSV from section 1a:

**[TRANSCRIBED]**

```bash
cut -d, -f1 svn-prefs-backup-<stamp>.csv | tail -n +2 | sort
```

Every key on that list must be one of three things:

1. **Migrated** — copied into `config_item` rows by one of the migrations.
2. **Deliberately abandoned** — left behind on purpose, with a reason
   recorded in the code. Device-local settings are the main family here:
   `startup_url`, `access.session`, `update_channel`, `mcp.config`. Also
   `key_mappings` and `page_editor_data` themselves, whose blobs are rollback
   insurance until section 6 drops the table.

   **`mcp.config` in particular is abandoned, not migrated**, and the reason
   is worth knowing because it is the strongest of them. The raw preferences
   editor merges the two stores with the **shared** value overriding the
   device-local one. So a migrated `mcp.config` row would not merely be an
   inert setting nobody reads — it would *mask this station's real
   device-local value* in that list, while offering an `administer`-gated edit
   that changes nothing anywhere. A write that quietly does nothing, arriving
   through the front door.
3. **Unknown** — nobody has classified it.

**Resolve every unknown key with Jón BEFORE the window, not during it.** An
unknown key is a setting that nobody in the codebase writes any more and
nobody has decided the fate of, and deciding that at 02:00 with the plant down
is how a setting gets thrown away.

You do not have to do this classification by hand. The drop tool in section 6
runs exactly this check and **refuses while any unknown key remains** — that
refusal is by design, and it is the safety net. But the drop is a week later;
finding the unknown key now is what stops the week from ending in a surprise.

### One asymmetry worth knowing

The gates protect the **older** plant better than the newer one, which is the
opposite of what you would assume.

A plant still carrying the legacy per-tool MCP keys — `mcp_tools_tags_enabled`
and its eight siblings — is **protected**: those keys classify as `unknown`,
so the drop refuses until somebody looks at them. A plant that has already
consolidated them into the single `mcp.config` blob is **not** protected by
that refusal, because `mcp.config` is classified abandoned and waves the drop
through.

That is not an assertion; it is pinned by a test —
`packages/tfc_dart/test/core/config/preference_migration_test.dart`, *"the
legacy MCP toggle keys still land in unknown, and that is what protects the
older plant"*. If the behaviour ever changes, that test is what changes with
it.

---

## 4. THE WINDOW

No dual-write. Coordinated rollout. The plant is down for this.

### The order is load-bearing

Read this before you start the sequence, because the ordering below is not a
tidiness preference any more — it is a hard requirement, and it became one
late in the milestone.

**The backend container now hard-fails when there are no key-mapping rows.**
It used to fall back to reading the old blob; that fallback has been deleted.
It is rows or nothing. Started against a database no station has migrated, the
backend throws a `StateError` naming the migration, dies, gets restarted by
Docker, and does it again — a crash loop, not a degraded start.

So: **one station first, then the rest, then the backend.** The first station
is what runs the migration; the backend is what needs the migration to have
run. Starting the backend early does not break anything permanently, but it
fills your logs with a repeating fatal error at exactly the moment you are
trying to read them.

### The sequence

**All [PLANT ONLY]. None of this has ever been run against a plant.**

**Step 1 — Stop everything.** Every station, and the backend container.

**Step 2 — Deploy the new build** to the stations and the backend. Do not
start anything yet. (Re-read **section 4b** before this step if you have not
already.)

**Step 3 — Start ONE station.**

**Starting the station IS the migration command.** There is no separate
migration to run. All three migrations — key mappings, pages, and the shared
preferences — fire when the station attaches to the shared database, each
under its own advisory lock, in that order. They are idempotent: a station
that loses power mid-run leaves nothing half-written, and the next start is a
clean re-run.

**Step 4 — REQUIRE the evidence line in that station's log.** It looks like
this:

```
Preference migration: 9 migrated (alarm_man_config: 1, collector_config: 1, images: 4, page_editor_top_level_order: 1, recipes: 1, server_config_envelope: 1), 6 abandoned, 0 unknown
```

**Those numbers are an illustration, not a target.** Every count in that line
depends on what this plant has, and none of them is something to match against
a figure written down in advance. What is fixed is the **shape**.

The names in brackets are **families**, sorted. There is one per migrated
setting — `alarm_man_config`, `collector_config`,
`page_editor_top_level_order`, `server_config_envelope` — plus `images` for
the uploaded page images, `recipes` for the recipe buckets, `chat` for the
assistant's conversations and `llm` for the provider settings, which are the
families that can hold more than one key each. A family with nothing to move
simply does not appear. `state_man_config` is **abandoned**, not migrated:
its only reader is the OS keychain, and a shared row of the PLC endpoints
would be a plaintext copy in a replicated table for nobody.

**Only one number on that line gates anything, and it is `unknown`.** Check,
in this order:

- **`0 unknown`.** This is the check. If it is not zero, the line names the
  unknown keys in brackets. **Resolve them before going on** — that is
  section 3's work arriving late, and the drop in section 6 will refuse on
  them anyway.
- **The line is there at all.** Its absence means the migration did not run.
  The nearby log lines say why — the common one is *"Preference migration:
  the pages migration has not run (no _migrated.pages row)"* (or
  `key_mappings`), which means the attach
  ordering went wrong and this station is serving what it already had.
- **The migrated and abandoned counts are information, not a gate.** Read them
  against what you know this plant has — if `alarm_man_config` is missing from
  the families and you know the plant has alarms, that is worth stopping for.
  Do not compare them to any number from a test or a document.

**Step 5 — Verify this station by looking at it.** Pages draw. Key mappings
resolve — values are live, not stale. Alarms are present. The history view
opens. This is a human check; nothing automated substitutes for it.

**Step 6 — Start the remaining stations.**

**Step 7 — Start the backend container**, and read its log.

What to grep for is **`_migrated.preferences`** — the marker id, not the table
name. The backend warns like this when the preference migration has not run:

```
No alarm_man_config row and no _migrated.preferences marker: the preference
migration has not run, so the alarms this plant does have are not visible to
this backend yet.
```

Post-cutover, that warning means the migration did not reach this database,
and the backend is running with no alarms. Its benign twin — *"No
alarm_man_config row and the preference migration has run: this plant has no
alarms configured"* — means exactly what it says, and is only benign if you
know this plant genuinely has no alarms configured.

The marker id is deliberately what gets logged rather than the table name.
Grep for `_migrated.preferences`.

> **Do not grep for a "falling back to the flutter_preferences" line.** Earlier
> drafts of this procedure said to. That line has been deleted along with the
> fallback it described, so it can never print — and reading its absence as
> success is exactly backwards. The backend's failure mode is now the
> crash-looping `StateError` described above, which is impossible to miss.

**Step 8 — Run the consistency check against production.**

The check is the `check_config_consistency` MCP tool. It is read-only. It
compares every stored row against the newest change recorded for it: every
`parent_id` resolves, every row matches its history in payload and position,
no deleted entity still has a row, no history-exempt entity has change rows.

It is served by `tfc_mcp_server`, and **the server must be told to serve it**:

**[TRANSCRIBED]**

```bash
# From `packages/tfc_mcp_server`, or the compiled binary of the same name.
dart run bin/tfc_mcp_server.dart \
  --db-host 10.104.29.111 --db-name hmi --db-user centroid \
  --toggles '{"config":true}'
```

It speaks MCP over stdin/stdout, so you need an MCP client to call the tool —
the station's own HMI bridge, or any MCP client you already use.

> **The `--db-*` flags do not win. Check which database you actually reached.**
>
> `CENTROID_PGHOST`, `CENTROID_PGPORT`, `CENTROID_PGDATABASE`,
> `CENTROID_PGUSER` and `CENTROID_PGPASSWORD` take **precedence over** the
> `--db-*` flags. A shell that already has any of them set overrides what you
> typed, silently and with no error — you name a database on the command line,
> see no complaint, and connect to a different one. At 02:00, on a plant, that
> is a confident wrong answer rather than a failure, which is the harder kind
> to catch.
>
> Do not rely on remembering the rule. **Check it**, before you trust anything
> the tool reports:
>
> ```bash
> env | grep '^CENTROID_PG'      # anything printed here beat your flags
> ```
>
> And confirm the target independently of this binary — the same host, port,
> database and user you meant, asked of the database itself:
>
> ```bash
> psql -h <host> -p <port> -U <user> -d <db> \
>   -Atc "SELECT current_database(), inet_server_addr(), inet_server_port()"
> ```
>
> Do **not** use the binary's own "Connected to PostgreSQL at ..." line for
> this. See the next note: that line is printed before anything is tried.

Three things about that `--toggles` value:

- **Name only what you want on. Everything you do not name is off.** That is
  the whole rule. `'{"config":true}'` serves the config tools and nothing
  else — you do not have to list the other eight groups to keep them shut.
  A tool group is served because somebody turned it on, never because nobody
  turned it off.
- **Do not assume — read it back.** The server prints every resolved toggle at
  startup, on one line, before it does anything else:

  ```
  Tool toggles from commandLine: tags=false, alarms=false, config=true,
  drawings=false, trends=false, plcCode=false, proposals=false,
  techDocs=false, screenshots=false
  ```

  That line is the check, and it is the one to trust over anything written
  here: read `config=true` off it before you call the tool. It also names
  *where* the decision came from — `commandLine`, `environment`, or `absent`.
  If it says `absent` when you passed `--toggles`, something ate your
  argument, and `CENTROIDX_MCP_TOGGLES` in your shell would be the first thing
  to check.
- **Without `--toggles` and without `CENTROIDX_MCP_TOGGLES`, the server
  offers `ping` and nothing else.** That is the intended closed start, not a
  failure. It prints a line to stderr saying so, in as many words: *"no tool
  toggles were handed down, so every tool group is disabled and this server
  offers no tools but the ping health check."* **Expect to see `ping` in the
  tool list** — a closed server is not an empty tool list, it is `ping` alone.
  If you were expecting nothing at all and see one tool, nothing is wrong; if
  you see two, something is.

> **A trap, and it will catch you if nobody warns you.** The MCP binary logs
>
> ```
> Connected to PostgreSQL at 10.104.29.111:5432/hmi
> ```
>
> **when it has not connected.** The connection pool is lazy and never throws
> at startup, so this line is printed before anything has been tried. Pointed
> at a hostname that does not exist, it prints the same line. A real connection
> failure appears later, per query, where it reads like a bug in the query
> rather than like a database that was never reachable.
>
> **Do not use that line as evidence of anything.** If you are diagnosing this
> plant at 3 a.m., that is the line you will instinctively grep for, and it
> will lie to you. Recorded as defect D-8 in
> `docs/relational-config-deferred-defects.md`.

### What the consistency check must report

**Exactly two violations, and no others:**

| Entity id | Invariant | Kind | Scope |
|---|---|---|---|
| `_migrated.key_mappings` | `missing_history` | preference | shared |
| `_migrated.pages` | `missing_history` | preference | shared |

**This is not a bug and it is not something to fix.** Those two rows are
migration markers written by the Phase 2 and Phase 3 blob migrations, and that
code writes them without a change row. The rows are real and their values are
correct; their history simply was never written, and it cannot be written
retroactively without inventing an author and a timestamp. Every plant those
two migrations have touched reports them, forever.

**What stops the window:**

- **A third violation of any kind.**
- **A different invariant on either of those two ids** — anything other than
  `missing_history`.
- **Either of those two ids at a different scope or kind** — station scope
  instead of shared, for instance.
- **Zero violations.** Not a stopper, but not expected either: on a plant that
  Phases 2 and 3 have migrated, the two markers are always there. Zero means
  you are looking at a different database from the one you migrated.

An earlier draft of this procedure said to require zero violations. That was
wrong, and wrong in the way that matters: it is unsatisfiable on any plant we
would actually run it against, and an operator who is told to require zero
either stops a cutover that is going correctly, or learns on the night that
this check's output is something to argue with. Neither is acceptable, so the
two are named.

The drop tool in section 6 carries **the same two-id allow-list**, in code,
narrowed the same three ways — invariant, kind and scope. This document and
that gate agree on purpose. If they ever disagree, **follow the tool** — it is the one that
refuses.

---

## 4b. WHAT MUST TRAVEL TOGETHER

**Never deploy a build carrying the row-backed shared preference store without
the preference migration.**

They are in the same build here, so this is a warning against cherry-picking a
commit or a partial branch — not a step you perform. It is written down
because doing it wrong is silent and plant-wide.

The row-backed store reads shared settings from `config_item` rows. The
migration is what puts them there. Between the two, every shared setting reads
as **absent** — not stale, not wrong, absent — and a station cannot tell that
apart from a plant that was never configured. What such a station comes up
without:

| Setting | What the operator sees |
|---|---|
| `alarm_man_config` | no alarms at all |
| `page_editor_top_level_order` | the menu in arbitrary order |
| `page_editor_image:<id>` | every uploaded image on every mimic fails to load |
| `<bucket>.recipes` | recipe assets open with no recipes |
| `server_config_envelope` | the stored server configuration reads as unset |
| `collector_config` | the collector falls back to its default |
| `update_channel` | unset |

Pages, assets and key mappings are **unaffected** — they moved to rows in
Phases 2 and 3. `state_man_config` is **unaffected** — it is stored secret, in
the OS keychain, which none of this touched. A station still knows how to
reach its PLC.

**A related point that makes step 3's ordering recoverable.** A station booted
against a reachable Postgres *before* its migration runs will write **empty**
rows from its own boot defaults — an empty `alarm_man_config`, for instance,
which then syncs to every other station. This is recoverable: the migration
**overwrites** those rows rather than skipping them, deliberately, precisely
because a booting station can have invented them. So starting a station early
is a mess to clean up, not silent data loss. Do not panic and start deleting
rows if it happens; run the migration.

---

## 5. ROLLBACK

If the window goes wrong, this is the way back. Nothing here is destructive of
history.

1. **Stop everything** — every station, and the backend container.
2. **Restore the blob rows from the CSV** taken in section 1a, using
   `svn_apply_config.py`'s own staging-table upsert path (it loads the CSV into
   a TEMP table and upserts `ON CONFLICT (key) DO UPDATE`). **[TRANSCRIBED]**
3. **Redeploy the previous build.**
4. Start the stations, then the backend.

### The `config_item` and `config_change` rows are LEFT IN PLACE

**"Undo the migration" is not "delete the rows".** Say this out loud before
you type anything.

The new rows are **additive**. Nothing in the previous build reads them — the
old build reads the blobs, which you have just restored. Leaving them costs
nothing and breaks nothing.

Deleting them, on the other hand, destroys the `config_change` log, which is
append-only by a locked decision of this milestone and is the only record of
who changed what. It is also the thing the consistency check and the undo
feature are built on. A rollback that deletes it trades a recoverable bad
night for a permanent hole in the record.

If you roll back and later roll forward again, the migrations are idempotent
and the surviving rows are what they should be.

---

## 6. THE DROP — one week later, as its own change

**Leave `flutter_preferences` in place, unread, for at least one production
week.** That week is what makes section 5 real. For as long as the table is
there, a rollback is a restore; once it is gone, it is not.

Then drop it, as a separate scheduled change, not as the tail of the cutover
window.

**[VERIFIED against a throwaway Postgres. [PLANT ONLY] against the plant —
this has never been run against a plant by anyone.]**

In `packages/tfc_dart`:

```bash
# Rehearsal: every check runs, nothing is written.
CENTROID_PGHOST=10.104.29.111 CENTROID_PGDATABASE=hmi CENTROID_PGUSER=centroid \
  dart run bin/drop_flutter_preferences.dart
```

```bash
# The real thing.
CENTROID_PGHOST=10.104.29.111 CENTROID_PGDATABASE=hmi CENTROID_PGUSER=centroid \
CENTROIDX_CONFIRM_DROP=flutter_preferences \
  dart run bin/drop_flutter_preferences.dart
```

**Without `CENTROIDX_CONFIRM_DROP` the tool is a dry run** — every read-only
check is performed and reported, and nothing is written. That is the intended
way to rehearse it, and you should, days before.

### The four gates

All four are evaluated on every run and **all failures are reported together**,
in one list. That is deliberate: four sequential refusals separated by four
re-runs is how somebody reaches for a flag that skips them.

1. **The three migration markers exist** — `_migrated.key_mappings` (Phase 2),
   `_migrated.pages` (Phase 3) and `_migrated.preferences` (the preference
   migration). An absent marker means that migration never ran on *this*
   database, and the table still holds the only copy of what it would have
   moved.
2. **The consistency check is clean**, bar the two named marker omissions from
   section 4 — and that is an allow-list of two ids, not a relaxed rule.
3. **No unknown keys remain.** Section 3's check, in code.
4. **`CENTROIDX_CONFIRM_DROP=flutter_preferences`.** The value names the table
   on purpose, so it cannot be left in a shell profile and cannot be confused
   with confirmation of some other destructive step.

Two further refusals are preconditions rather than gates, reported the same
way: the database must be Postgres, and the connection pool must be one
connection (the default; `CENTROID_DB_MAX_POOL_CONNECTIONS` is what would
raise it).

### What it drops

The table `flutter_preferences`, and — in the same transaction — the function
`notify_flutter_preferences_key_change()`. `DROP TABLE` takes the table's
triggers but not the function they call, and an orphan function is something
the next engineer reading `\df` cannot account for. Both, or neither.

**Re-running after a successful drop is safe.** The tool reports that the
table is already gone and exits 0. That is the expected outcome of a re-run,
not an error.

**This is the one irreversible statement in the milestone.** After it, restore
is from the section 1a CSV and from nothing else.

---

## 7. JÓN'S TOOLING — what changes and when

### Unaffected: `svn_mirror_page.py` and `svn_remap_keys.py`

Both are pure local file transforms — they read a JSON file and write a JSON
file, and neither touches Postgres. `svn_remap_keys.py` reads
`svn-key-mappings.json` and writes `svn-key-mappings.remapped.json`;
`svn_mirror_page.py` reads and writes `svn-page-editor.json`. Nothing in this
milestone changes anything about them. Keep using them exactly as you do.

### `svn_apply_config.py --apply`: stop using it once the new build is deployed

**It is correct right now.** Nothing from this branch is on any station yet,
so `--apply` writes the blobs that the running stations actually read, and it
works.

**It becomes silently wrong from the moment the new build is deployed** — that
is, at section 4's step 2, and not before. From that moment on, the stations
read `config_item` rows and `--apply` writes blobs that nothing reads. The
script will report success. The plant will not change. Its payload map covers
`key_mappings`, `page_editor_data` and `state_man_config` — one from each
phase — so this applies to all three.

**The action required is simply: do not run `--apply` after the deploy.**

This is a notice to hand over *with* the deploy. It is not a step in the
cutover window, and it is not a bug to fix before the window. There is nothing
to do about it tonight except know it.

Its `--backup-only` path keeps working until section 6 drops the table, and
then stops. Both halves of the script die with the table.

**Replacements, if and when they are wanted** — Jón's call, and deliberately
out of scope here:

- *For the apply path*: a row upsert per key through the same compare-and-swap
  the app uses, so a write goes through the change log like any other.
- *For the backup path*:
  `SELECT kind, id, scope, parent_id, sort_index, payload, rev FROM config_item`.

### `page_geometry.dart`: already stale, and not a cutover casualty

It reads a local `shared_preferences` JSON file, not the database. Phase 1
removed `shared_preferences` from the app, so no station has written that file
since — it works only against a file captured before that upgrade. It was
already broken before this milestone started, and nothing here changed it. The
tool's own header now says so.

---

## Appendix: the code-side gates

Two shell scripts in this repository enforce, in CI and locally, that
production code has actually stopped using the old table. They are not part of
the plant procedure, but they are what makes the procedure's assumptions true,
and they are worth knowing by name if you are diagnosing something.

**`./scripts/check-flutter-preferences-retired.sh`** — fails the build when
production code reads or writes `flutter_preferences`. This is the code side of
the retirement. It searches `lib/`, `centroid-hmi/lib`, `packages/*/lib` **and
`packages/*/bin`**, and that last root is not incidental: written as a
`lib/`-only check it printed clean while two production binaries still read the
table — the acquisition backend and the MCP server. A gate whose search path
misses the binaries is vacuous in exactly the way that matters, and it looks
green while being so. It carries an allow-list of five files, each with its
reason inline: the schema declaration, the three migrations and the drop tool,
plus one log message.

**`./scripts/check-flutter-preferences-retired.sh --self-test`** — proves the
gate can fail. It plants a violation in a `lib/` root **and** in a
`packages/*/bin` root, requires **both** to be detected, and then requires both
to stop being reported once removed. Run this if you ever need to believe the
clean result.

**`./scripts/check-preferences-construction.sh`** — the sibling gate on how
preference stores are constructed: a store built outside `lib/providers/` is
not wrapped by its guard, so its writes pass no access check and leave no
audit row, and nothing about the call site looks wrong.

**`./scripts/check-preferences-construction.sh --self-test`** — added at this
phase's close, and worth knowing why. Until then this script had **no**
self-test, while its sibling had one: its clean result could only be trusted
by whoever had last planted a violation by hand, which meant the proof was the
developer's and never the reader's. It now plants a violation for **all four**
constructor patterns it watches and requires each to be detected and then to
stop being reported once removed.

Both gates can now be verified by anyone, at any time, with one flag. If you
are ever asked to trust a "clean" from either, run its `--self-test` first.

---

## Appendix: what this document does not do

**It does not pass the cutover gate.** The gate in section 2 requires a current
production dump, and that requires the plant. No branch, no CI run and no
developer machine can satisfy it. This document's job is to make the gate
impossible to pass *vacuously* — which it does, by requiring the environment
variable and the printed source line on every one of the three commands. Passing
it is section 2, at the plant, by whoever runs this.

**The drop has never been run against a plant.** It is written, gated, and
proved against a throwaway Postgres. Section 6 is its first real execution.

---

## Verified at phase close — 2026-09-08

The window should start from a tree somebody has just watched go green. This
is that observation, recorded so the next person does not have to take it on
trust. All four suites were re-run at commit **`f190ad5e`** — the commit CI
reported on — so the table and CI describe the same tree. All on macOS under
the pinned Flutter SDK **3.44.9** (`.flutter-version`).

**Read this before you read the table.** The table below is one developer
machine. CI compiled the same commit and reported, on
`f190ad5e`: **39 checks passed, 0 failed, 4 skipped** — the full test suite
green on macOS, Ubuntu and Windows for the app, `tfc_dart` and the MCP server,
plus `elinux-build` and the Windows MSIX.

**The station image builds in CI, and on a pull request CI also publishes
it** to `ghcr.io/centroid-is/centroid-hmi:pr-465`, alongside the backend
images (the ivi-homescreen image was dropped on main in #497 and no longer
exists). That is worth stating plainly because the eLinux image — the one carrying the station's SQLite
preference store — was this milestone's largest untested surface, and it is no
longer untested.

**But nothing has been deployed and nothing has been booted.** Published to a
registry is not installed on a panel. **No station has pulled either image,
and the rig has never booted one.** Building is not booting, and that gap is
the part that still matters when you read the rest of this document.

**The cutover gate is armed and has never been passed.** No production dump
has been run against it. That is unchanged by any of the above, and it is the
distinction the whole document turns on: **the gate being armed is not the
gate having been passed.** Section 2's commands can no longer pass vacuously,
which is what this work delivered. Passing them against this plant's dump is
still ahead of you.

### What CI caught that no local run could

Worth knowing, because it is the honest answer to "the tree looked green on
the developer's machine". Six defects survived a fully green local run:

1. **The MCP binary had never been able to start on Windows** — an unhandled
   `SIGTERM` — and this repository ships a Windows MSIX. Recorded as D-11.
2. **A test wrote secrets to the real macOS login keychain**, invisible on
   macOS precisely because macOS is the platform where it works.
3. **The drop test destroyed a table the migration tests need.** Not a
   concurrency bug: macOS and Windows set `TIMESCALEDB_EXTERNAL=1`, which
   makes the compose up/down a no-op, so one Postgres survives the whole run.
   **A local run is structurally the Docker leg** — for the other two legs,
   local green was not weak evidence, it was none.
4. **A byte-compared JSON fixture checked out as CRLF on Windows**, whose own
   error message advises a fix that breaks the other two platforms.
5. **The D-3 tripwire compared native paths against `/`.**
6. **A watermark test read two statements two awaits apart as atomic.**

None of these touches the cutover path. They are here as the argument for the
`[VERIFIED]` / `[TRANSCRIBED]` / `[PLANT ONLY]` marking at the top of this
document: a thing that has run somewhere is not a thing that has run
everywhere, and the difference is worth writing down every time.

| Suite | Command | Result |
|---|---|---|
| App | `flutter test test/` (repo root) | **6592 passed / 3 skipped / 0 failed** |
| tfc_dart core | `dart test test/core/` (in `packages/tfc_dart`) | **1462 passed / 8 skipped / 0 failed** |
| MCP server | `dart test` (in `packages/tfc_mcp_server`) | **1370 passed / 1 skipped / 0 failed** |
| tfc_dart integration | `dart test test/integration/` (in `packages/tfc_dart`) | **148 passed / 4 skipped / 0 failed** |

Both code-side gates exit 0 and both were watched failing.
`check-flutter-preferences-retired.sh --self-test` detects a planted violation
in a `lib/` root **and** in a `packages/*/bin` root and stops reporting both
once removed. `check-preferences-construction.sh --self-test` was **added at
this close** — it had none before, so its clean result had only ever been
proven by hand — and now plants a violation for all four constructor patterns
it watches, requiring each to be detected and then to stop being reported.

Zero golden churn: `git status -- '*.png'` was empty after the full app run.

### The tree went red for a day — resolved, and worth knowing why

Kept rather than deleted. A document that has never admitted to a red day
teaches its reader that red days do not happen.

Between commits `a702f29a` and the fix, the app suite ran **6588 / 3 / 4**.
The cause was `d2c91ea5`, *"tool groups are off until somebody turns them
on"* — the ruling that MCP tool groups default to disabled rather than
enabled, which is the right change and is what section 4's step 8 documents.

Four tests in `test/mcp/*_e2e_test.dart` then failed identically with
`McpError -32602: Tool 'create_alarm' not found`. They stood up an MCP server
without naming the `proposals` group, which had been enabled by omission and
was now off.

**The fix was test-scope, and establishing that was the point.** The app's own
spawn path was already correct — both `connectInProcess` call sites pass real
toggles — so the proposal feature was never broken; only three test files were
getting a capability for free. Had that not been checked first, the obvious
"fix" of editing four tests would have been indistinguishable from papering
over a broken feature.

**What the flip exposed is the part to carry.** The tests said
`const McpToolToggles(proposalsEnabled: true)`, which reads as *"proposals
on"* and meant *"everything on"* — the other eight groups were defaulting open
behind a line that looked like a narrow grant. Nothing was wrong with the
tests until the default moved, and nothing about them looked wrong then. If
you meet a constructor that names one capability and lets the rest default,
that is the same shape.

Resolved: the three files now pass `McpToolToggles.allEnabled` explicitly,
which is what they always meant, and all four tests are green.

The integration run stood its throwaway Postgres up and tore it down cleanly —
ports 5432 and 15432 were released afterwards, and the unrelated
`baader-grafana`, `baader-timescaledb` and `baader-ticker` containers were
untouched. That is the check to repeat if you ever run it on a machine that
has other containers on it.

**Use the pinned SDK.** `flutter` on `PATH` may be an older install — on the
machine this was verified on, it was 3.41.9. Under it the app suite reports
**6592 − 174 = 6418 passed and 174 failed**, which reads like a precise
regression and is not one: `build/unit_test_assets` holds a shader compiled by
3.44.9, and the older engine cannot decode it (*"Unsupported runtime stages
format version. Expected 1, got 2"*), so every test that pumps a frame dies.
Check `flutter --version` before believing any large failure count.
