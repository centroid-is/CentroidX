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
