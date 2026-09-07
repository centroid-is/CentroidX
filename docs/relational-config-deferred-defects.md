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

**Fix shape:** the codec needs only `KeyMappingEntry.fromJson` and
`KeyMappings`. Either lift those model types out of `state_man.dart` into an
FFI-free file, or give the codec an FFI-free entry point. Both restore the
barrel's guarantee without reintroducing two definitions of the blob shape.
Strengthening the smoke test to assert the binary's link profile — not just
that it runs — would stop this recurring.

**This one is a regression, not a pre-existing bug, and should land before
anything ships.**

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
