# Where drift's generated classes live — and what that costs a web build

Recorded 2026-09-09 on `feat/relay-pipe` (PR #463), at `30a21e05`.

Written because a proposed split of `database_drift.dart` was costed on a
premise that does not hold, and the premise is an easy one to arrive at twice.

## The claim that was tested

> `database_drift.dart` separates cleanly: lines 32–382 are twelve pure `Table`
> definitions (drift core only, web-safe); `AppDatabase` — `NativeDatabase`,
> `DriftIsolate`, `dart:io`, `dart:isolate`, `drift_postgres` — starts at 411.
> Moving the tables to `database_tables.dart` with their own part is the stock
> drift layout, and one split unblocks all 16 importers.

The sixteen importers name `AppUserData`, `AuditEntryData`, `$AlarmHistoryTable`.
None of them wants `AppDatabase`. The hoped-for outcome was that they could
import a small web-safe file instead.

## Verdict

**The split moves the twelve declarations and nothing else.** Every one of the
sixteen importers keeps importing `database_drift.dart`, and keeps pulling
`dart:io`, `dart:isolate`, `drift/native.dart` and `drift_postgres` with it.

Drift does not generate a table's implementation class beside the `Table`
subclass. It generates it beside the **`@DriftDatabase` annotation**. Moving a
`Table` declaration to another file changes where the declaration is read from
and changes nothing about where `$XTable` and `XData` are emitted.

## Evidence

### 1. The repo already contains the counter-example

`packages/tfc_dart/lib/core/mcp_tables.dart` declares `AuditLog` and nine other
tables. It has **no `part` directive** — `grep -c '^part ' mcp_tables.dart`
returns `0`. Its generated classes are emitted into the *database's* part file:

```
packages/tfc_dart/lib/core/database_drift.g.dart:2475: class $AuditLogTable extends AuditLog
```

The twelve local tables behave identically, because the rule is the same one:

```
database_drift.g.dart:206   class $AlarmHistoryTable extends AlarmHistory
database_drift.g.dart:456   class AlarmHistoryData extends DataClass
database_drift.g.dart:6962  class $AppUserTable extends AppUser
database_drift.g.dart:7109  class AppUserData extends DataClass
database_drift.g.dart:7636  class AuditEntryData extends DataClass
```

`mcp_tables.dart` is proof by construction: the exact split being proposed has
already been performed once on ten tables, and it did not move their generated
classes out of `database_drift.g.dart`.

### 2. The mechanism, from drift_dev's own builder config

`packages/tfc_dart/build.yaml` configures only `sql.dialect: postgres`; the
builders are drift_dev's defaults. From `drift_dev`'s `build.yaml`:

```
#  - drift_dev: The regular SharedPartBuilder for @DriftDatabase and
#    @DriftAccessor annotations
  drift_dev:
    build_extensions:
      ".dart":
        - ".drift.g.part"
```

A `SharedPartBuilder` keyed on `@DriftDatabase` / `@DriftAccessor`, emitting
`.drift.g.part`, which `source_gen:combining_builder` merges into the annotated
library's `.g.dart`. No builder claims an output for a file that declares only
`Table` subclasses, so `database_tables.dart` has nothing to own a
`part 'database_tables.g.dart'` with.

Verified identical in **drift_dev 2.34.5** (what `packages/tfc_dart/pubspec.lock`
resolves, and therefore what built `database_drift.g.dart`) and in **2.28.0**
(what the root `pubspec.lock` resolves for the app tree). Both lockfiles matter
here and they disagree on version — cite the one belonging to the package the
code lives in.

### 3. Two smaller corrections to the same brief

- **The table block is not drift-core-only.** Line 31 is
  `@UseRowClass(AlarmConfig, constructor: 'fromDb')`, so it needs `alarm.dart`,
  which imports `dart:io` at its line 3 and reaches open62541 through
  `state_man.dart`. A `database_tables.dart` holding the `Alarm` table would
  import `alarm.dart`, which imports `$AlarmHistoryTable` back — legal between
  libraries, but not web-safe and not clean.
- **The `alarm.dart` rider is not subsumed.** `alarm.dart:22` imports
  `$AlarmHistoryTable`, which is generated, so it stays in `database_drift.dart`
  under every option below except 1 and 2. `alarm.dart` is not web-bound anyway,
  for the `dart:io` reason above.

### Limits of this evidence

The three greps above are measurements. **`build_runner` was not run against a
trial split** — the conclusion that `database_tables.dart` cannot own a part
file is read off the declared `build_extensions`, not off a failed build. If
somebody wants the stronger form, run it; nothing here expects a different
answer.

## What would actually move the row classes

| | Approach | Cost |
|---|---|---|
| 1 | **drift modular generation** — per-file `.drift.dart` libraries | The stock answer, and drift's own `build.yaml` comments call `modular` "a work-in-progress builder". Repo-wide: every generated-class import changes |
| 2 | **Invert the split** — tables + `@DriftDatabase` + part stay in a drift-core-only file; the io half moves out | Not an extraction. `pg.Pool? _pool`, `ReceivePort? _healthPort`, `DriftIsolate? _driftIsolate` are *fields* of `AppDatabase`; `pg.Interval` is used in retention; notification connections and close-ordering are woven through the class. A rewrite |
| 3 | **Conditional import** (`if (dart.library.js_interop)`) of the io half | Cheaper than 2, but those field types must still resolve on web, so it needs stub `pg.Pool` / `DriftIsolate` / `ReceivePort` |
| 4 | **Stop leaking drift rows into the UI** — hand-written domain types for the three row classes the UI actually names, mapped at the repository boundary | Largest, and it is the thing the original brief noticed in passing: *"drift's generated row classes are the app's domain types"* |

No option is chosen here. 4 is the one that removes the coupling rather than
relocating it; 1 is the expedient one and bets the app's domain types on a
builder drift labels work-in-progress.

## What was actually changed

Only the unrelated rider that travelled with the same brief:
`30a21e05` — `packages/tfc_dart/lib/core/umas_types.dart:1122`,
`checkRange('LINT', value, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF)` removed. It
could not fire (a Dart int on the VM *is* the LINT range, so both bounds were
tautologies), and `0x7FFFFFFFFFFFFFFF` has no exact JavaScript double, so
dart2js rejects the literal at compile time. An assertion that never ran was the
one thing in that file stopping the web build. `umas_write_variable_test.dart`
46/46, including the arm that encodes both extremes.

`database_drift.dart` is unchanged.

---

## Resolution, 2026-09-10

Option **4** was chosen and implemented across four commits on this branch.
The record above stands as written; this section says what happened.

| Stage | Commit | What moved |
|---|---|---|
| 1 | `26156f13` | `AuditTrailStore.entries` answers `tfc_access.AuditRecord`; both adapters become pass-throughs |
| 2 | `2cd0aab9` | `UserSummary` moves from `tfc_relay_protocol` to `tfc_access`; codecs stay behind |
| 3 | `c3a31d05` | `AccessAdminStore.listUsers` answers `UserSummary`; the synthetic credential column is deleted |
| 4 | `1d0ae086` | The rule is pinned by a derived, ratcheted gate |

### What the exercise was actually for

Two fabrications, both on the gateway path, both existing only because a screen
was typed on a database row:

- `RelayedAuditTrailStore` rebuilt every wire record into an `AuditEntryData`
  with `id: index` — a local ordinal invented to satisfy a class a panel with
  no database has no rows for.
- `RelayedAccessAdminStore` minted a credential column,
  `passwordHash: user.hasPassword ? '' : kNoPasswordMarker`, so that
  `access_users_section.dart` could call `isPasswordless()` on it and recover
  the one bit the wire had already sent as `hasPassword`.

Neither was a wrong line of code. Each was the locally reasonable way to
satisfy a type that should never have reached that layer.

A third was fixed on the way: `AppUserData.createdAt` is non-nullable, so a
`UserSummary` from a backend older than the field had its absent `createdAt`
filled with an epoch-zero sentinel, and the roster drew 1970-01-01.
`UserSummary.createdAt` is nullable, so the absence survives and renders as
`kAccessUserUnknown` — deliberately not `kAccessUserNever`, because a null
`lastLoginAt` is a fact about the account and a null `createdAt` is a fact
about the answer.

### Where the line is

A drift-generated type may be named only inside `packages/tfc_dart`, and there
only by the persistence or wire-mapping layer. Anything a store exposes is
hand-written. Applied:

- `AccessRepository.listUsers` maps; **`AccessRepository.user` deliberately does
  not** — it is the credential read, `LocalAuthProvider` needs `passwordHash`
  and `salt` to verify a sign-in, and there the row *is* the stored credential.
- Companions stay unmapped: they are the repository's write vocabulary and
  already never escape it.
- `kNoPasswordMarker` stays where it belongs — the column encoding, the two
  repository writes, and the sign-in check. Only its two UI-side readers went.

### What the gate found

On its first run, a family nobody had inventoried:
`lib/core/guarded_knowledge_stores.dart` leaks `PlcVarRefTableData`,
`PlcFbInstanceTableData` and `PlcBlockCallTableData` through its interface into
`lib/providers/plc.dart`. Same defect, different subsystem.

**Not fixed.** It needs domain types for PLC cross-references — what a variable
reference or a block call is to a screen — which is a question about the
knowledge subsystem. It is exempted by exact file-and-type pair so the boundary
cannot get worse while that is pending, and a further arm fails if an exemption
outlives its leak.
