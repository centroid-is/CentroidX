# Access control — implementation spec

Companion to [access-control-research.md](access-control-research.md). That
note surveys the field; this one is the buildable version. Written 2026-08-26
to be executed by an implementation agent without re-deriving the discussion.

## Decisions locked

| Question | Answer |
|---|---|
| Does an operator log in? | **No.** Unauthenticated *is* the operator level. Login only to elevate. |
| Definition of done | **Demoable end to end on macOS.** Not deployed to an SVN station. |
| Who configures roles | **Engineering (us), at commissioning.** Plant self-serve is a later follow-up. |
| Identity | **Local username + password now.** OIDC (Microsoft/Google) later, without a migration. |
| Permission model | **Fixed groups in code; roles created by the customer and mapped onto groups.** |
| Audit | **Retained.** Append-only, never pruned. |

## Scope

**In:** users, roles, role→group mapping, login/logout, session with inactivity
timeout, an `AccessPolicy`, guards on both write interfaces, rerouting the three
bypass paths, per-asset and per-route level declaration, the audit table, and a
minimal roles/users screen.

**Explicitly out — do not build these:**

- Badge / RFID / PIN-pad login. Anonymous-is-operator makes it unnecessary now.
- OIDC or SAML. Only the *shape* that keeps it cheap later (see §3).
- Read permissions. Assets read Postgres outside both interfaces
  (`bpm.dart:640`, `ratio_number.dart:510`, `rate_value.dart:672`); gating reads
  is a separate piece of work and is not wanted.
- Four-eyes / verified writes. The MCP proposal flow
  (`mcp_bridge_notifier.dart:104`) is where this would grow later.
- Per-user OPC UA sessions or PLC-side validation. See §8 — this spec ships a
  guardrail, not an enforcement boundary, and must say so in its own UI copy.
- Password policy of any kind: length floors, complexity rules, expiry, forced
  change at next login. Also admin-initiated *recovery* flows — there is no
  "forgot password" and no reset link, because there is no second channel to
  send one down. An administrator resets a password on the users screen, in
  person.

  A signed-in person changing *their own* password is **not** on this list any
  more: it shipped, from the app bar's account menu, and it verifies the current
  password first. See §11.
- Changing `lib/pages/dbus_login.dart`. Not because it is unrelated — it is the
  mechanism *underneath* `administer`. D-Bus is how the app makes system-level
  changes (IP settings and the like), and its credential is a **station
  credential**, the same kind of thing as the OPC UA session and the Postgres
  password: it authenticates the station to the system bus, never a person to
  the HMI. So `administer` is the human gate, the D-Bus credential is the
  plumbing beneath it, and the audit records the person while D-Bus merely
  applies the change. Configure it once at commissioning — it already persists
  to secure storage — so the operator meets one prompt (elevation), not two.
  Call the new one **Sign in** so the two still read differently in the UI.

---

## 1. The model

Three concepts. Two are fixed in code; one is customer data.

**Groups** — fixed, defined in Dart, referenced by assets and routes. Exactly
these seven. Do not add an eighth without a decision.

```dart
enum AccessGroup {
  operate,     // start/stop/jog, gates, alarm acknowledge
  setpoints,   // targets, limits, recipes
  device,      // drive parameters, calibration, scaling
  force,       // forced I/O and overrides
  configure,   // page editor, alarm rules, key mappings
  administer,  // server config, database, network, updates
  users,       // managing roles and users
}
```

`users` is deliberately separate from `configure`: otherwise anyone who can edit
a page can grant themselves everything.

**Roles** — customer data. A name plus a set of groups. Seeded with four, which
are ordinary rows and may be edited or deleted:

| Role | Groups |
|---|---|
| Operator | `operate` |
| Shift Leader | `operate`, `setpoints` |
| Maintenance | `operate`, `setpoints`, `device`, `force` |
| Engineering | all seven |

Maintenance **does** get `setpoints`: somebody who has just swapped a motor
needs to set it running properly, and sending them to find a shift leader to
type a number is how workarounds get invented. Decided 2026-08-28 — and the
decision cost one tick in a table rather than a schema change, which is the
point of the group model.

**The first user.** Roles are seeded; users are not, so without this the login
screen ships with nobody able to pass it. **Creating a user is permitted only
while the user table is empty.** The first person to open the app creates the
first Engineering account and the door closes behind them — no default password
to forget to change, no bootstrap flag to leave switched on.

Do it at commissioning. The window stands open until that first account exists,
so a freshly deployed station is claimable by whoever reaches it first.

**Break-glass is documented, not built.** Engineering already holds the station's
Postgres credential, so losing the only Engineering password means deleting a
row, not reflashing a station. That is a direct consequence of this being a
guardrail rather than a security boundary, and the recovery steps belong in the
deployment doc.

**Users** — a name, a password hash, and exactly one role. One role per user,
not many; multi-role adds union semantics and an "effective permissions"
inspector, and is not worth it at this size.

**Anonymous is the Operator role.** Not a configurable pointer — a session with
no user resolves to the role named `Operator`, full stop. That removes a knob
nobody needs and keeps "anonymous is operator" true by construction.

Two consequences to build in. The `Operator` row **cannot be deleted or
renamed**; enforce it, do not merely document it, or a logged-out panel loses
its identity. And editing that row changes what an *unauthenticated* panel may
do — ticking `setpoints` on Operator silently grants it to every panel on the
floor with nobody signed in. The roles screen must say so plainly at the point
of edit; it is the one footgun this simplification creates.

---

## 2. Schema

Drift, in `packages/tfc_dart/lib/core/database_drift.dart`. Follow the existing
table style exactly. Bump `schemaVersion` from **5 to 6** and add an
`if (from < 6)` branch to the existing `onUpgrade`.

```dart
class AppRole extends Table {
  TextColumn get name => text()();                    // primary key, matched
  TextColumn get groups => text()();                  // JSON array of enum names
  BoolColumn get seeded => boolean().withDefault(const Constant(false))();
  @override Set<Column> get primaryKey => {name};
}

class AppUser extends Table {
  TextColumn get username => text()();
  TextColumn get roleName => text().references(AppRole, #name)();
  TextColumn get passwordHash => text()();            // self-describing, see §4
  TextColumn get salt => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastLoginAt => dateTime().nullable()();
  @override Set<Column> get primaryKey => {username};
}

class AuditEntry extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get at => dateTime()();
  TextColumn get who => text()();                     // username, or 'anonymous'
  TextColumn get station => text()();                 // hostname
  TextColumn get roleName => text()();
  TextColumn get surface => text()();                 // 'tag' | 'pref' | 'route'
  TextColumn get itemKey => text()();
  TextColumn get member => text().nullable()();       // dotted path in a struct
  TextColumn get oldValue => text().nullable()();
  TextColumn get newValue => text().nullable()();
  TextColumn get groupRequired => text()();
  BoolColumn get allowed => boolean()();              // record denials too
  TextColumn get origin =>
      text().withDefault(const Constant('operator'))();  // see below
  TextColumn get actionId => text()();                // one action, N rows
  TextColumn get reason => text().nullable()();
}
```

`role.name` is the primary key rather than a surrogate id **on purpose**: when
OIDC lands, an incoming group claim of `"Shift Leader"` matches the role by name
with no mapping table, exactly as Ignition and SIMATIC Logon do it. Do not
replace it with an integer id.

### Struct writes must be diffed to members

Several assets are copy-on-write: clone the struct, set one field, write the
whole struct back (`conveyor.dart:2383`, `sensor.dart:778`, `recipes.dart:454`).
At the StateMan boundary that is a whole-struct write, so the audit must deduce
which members actually changed or the trail is unfilterable blobs.

`DynamicValue` (published `open62541` package) already has what is needed:
`entries` returns `Iterable<MapEntry<String, DynamicValue>>`, guarded by
`isObject` / `isArray`. **No pub release required.**

**The trap:** `DynamicValue` defines no `operator ==` — only its `LocalizedText`
helper does. Two distinct instances are never equal, so `oldMember != newMember`
is always true and a naive diff reports every member as changed on every write.
Recurse to the scalar leaves and compare `.value`, not the wrappers.

Rules: no cached baseline emits one marked "no baseline" row rather than N false
changes; arrays stay opaque (the indexed-key read-modify-write at
`state_man.dart:1956` already presents them whole); nested members use dotted
paths (`p_cfg.Freq`).

Give every human action a **correlation id** so one recipe apply is one action
with N member rows beneath it, not N unrelated rows.

Record denials as well as successes. A denied write is the more interesting
audit line, and it is how you find a role that is configured too tightly.

**`origin` defaults to hand-made on purpose.** Today every external caller of
`stateMan.write` is a widget — no heartbeat, watchdog or keepalive writes exist,
and every `Timer.periodic` in the tree polls rather than writes. That holds by
accident, not by construction, and relay Phase 5 breaks it deliberately with a
hold-to-run deadman and `holdTick`. Defaulting to `operator` means an unmarked
future machine caller lands *in* the trail loudly rather than escaping it
silently; an absent audit row is the one defect nobody ever notices.

**Every hand-made write is recorded, at every level including `operate`.** The
viewer filters, and excludes `operate` from its default view, so the trail stays
readable while nothing is discarded. Index `(at DESC)`, `(itemKey, at DESC)` and
`(who, at DESC)`; the `AREAnn.DEVnn.SUBnn` convention makes a prefix filter give
"everything on CN04" for free. Suppress no-op writes where new equals cached
old. Do not build pulse collapsing.

**Both backends must work.** `AppDatabase` runs on SQLite (`native == true`) and
Postgres. The migration already branches on `native`; follow that. Drift's
`m.createTable()` covers both — no raw DDL needed for new tables.

---

## 3. Keeping OIDC cheap later

Do these three things now; do not build anything else for SSO.

1. Role assignment resolves **by role name**, never by id.
2. Put authentication behind one interface so a second implementation can be
   added without touching callers:

   ```dart
   abstract class AuthProvider {
     Future<AuthenticatedUser?> authenticate(String username, String password);
   }
   ```

   Ship `LocalAuthProvider` only.
3. `AuthenticatedUser` carries `{username, roleName, displayName}` — no
   password-specific fields — so an OIDC implementation can populate it from
   claims.

---

## 4. Passwords

Argon2id via `package:cryptography`, per-user random salt, stored base64.

The stored value is self-describing and carries its own cost parameters —
`argon2id$v=19$m=<KiB>,t=<iters>,p=<lanes>$<hash_b64>` — so changing the
parameters later cannot strand the rows written before the change. Verification
uses the parameters recorded in the row, never the current constants.

`pbkdf2-sha256$<iterations>$<hash_b64>` rows, and the bare-base64 values older
than that encoding, are verified **forever**: existing users must not be locked
out. They are rewritten as `argon2id` transparently, on their owner's next
successful login, which is the one moment the password is in hand.

The repo already has this pattern: `lib/pages/server_config.dart:50` has
`kdfIterationsForTest` overriding `_kdfIterations`. **Reuse that hook** — tests
that run a real KDF at production iteration counts are unusably slow.

That crypto currently lives in a *page* file. Extract the reusable part to
`lib/core/` as part of this work rather than importing a page from a provider.

Password hashes must never travel through `Preferences` / the
`flutter_preferences` table. They live in `AppUser` and nowhere else.

---

## 5. Session

Station-local, never synced. Sessions belong in Riverpod state plus
`localPreferencesProvider`, not the shared database — a session is a property of
the person standing at *this* panel.

```dart
class AccessSession {
  final AuthenticatedUser? user;   // null == anonymous
  final Set<AccessGroup> groups;   // resolved from the role, anonymous role if null
  bool can(AccessGroup g) => groups.contains(g);
}
```

- Inactivity timeout drops back to anonymous. Default 15 minutes, stored in
  device-local preferences.
- **The inactivity timer must be listener-gated** — started in `onListen`,
  stopped in `onCancel`. An always-on `Timer.periodic` in shared plumbing breaks
  unrelated widget tests; this has happened in this repo before.
- Logging out is explicit and always available in the app bar when elevated.
- Show *who* is logged in, always, when elevated. An operator must be able to
  see at a glance that the panel is still in a raised state.

---

## 6. The guards

Two decorators, each implementing the interface it wraps. Callers change
nothing. This is the same idiom the repo already uses
(`SharedPreferencesWrapper implements PreferencesApi`, `_FakeStateMan implements
StateMan` in tests).

```dart
class GuardedStateMan implements StateMan {
  @override
  Future<void> write(String key, DynamicValue value) async {
    final need = policy.groupForKey(key);
    if (!session.can(need)) {
      await audit.denied(key: key, group: need, surface: 'tag');
      throw AccessDenied(key, need);
    }
    await audit.allowed(key: key, group: need, surface: 'tag',
                        oldValue: ..., newValue: value);
    return inner.write(key, value);
  }
}
```

`GuardedPreferences` wraps `setBool` / `setInt` / `setDouble` / `setString` /
`setStringList` / `remove` / `clear` the same way. Reads pass straight through.

### The four bypasses must be rerouted

These reach their store without passing either interface. A guard that does not
cover them is decorative:

1. `ServerConfigDb.publish()` / `.remove()` — writes `flutter_preferences`
   through Drift directly. Route through the injected `PreferencesApi`.
2. `lib/providers/collector.dart:21` — constructs its own
   `SharedPreferencesAsync()` and writes config at line 27. Take the injected
   `PreferencesApi` instead.
3. IP settings / D-Bus network and hostname calls — gate at the route level
   (§7); the D-Bus call itself stays as is.
4. **The history view's two deletes** — `lib/pages/history_view.dart:1108`
   `adb.deleteHistoryView(v.id)` and `:1165`
   `dbWrap.db.deleteHistoryViewPeriod(p.id)`, from the buttons at `:722` and
   `:1074`. Both write Drift directly. *Added 2026-08-29, found during Phase 2.*

   Note the two use different accessors (`adb`, `dbWrap.db`), so a grep for one
   does not find the other.

   **Do not fix this by gating the route.** `/advanced/history-view` is a read
   surface an operator needs, and §11 defers read permissions deliberately. The
   defect is a destructive control on a page that should stay readable, so the
   fix belongs at the controls — gate them on `configure` in place, leaving the
   page open. Undecided; see
   `.planning/phases/02-route-gating/deferred-items.md` §4.

**Why this list grew.** It was written as three, and a fourth of exactly the
same shape was sitting in the tree the whole time. Assume there is a fifth.
Before Phase 3 closes, sweep for *any* direct Drift write reachable from a
widget — not just the ones named here — because this list is evidently a
sample rather than an enumeration, and a guard beside an unenumerated hole is
the "decorative" outcome this section exists to prevent.

**Add a CI check** asserting that nothing outside `lib/providers/` constructs
`SharedPreferencesAsync()`. This is the invariant that will rot silently — every
future feature that news up its own preferences reopens the hole and the type
system will not object. A grep in the existing workflow is enough.

---

## 7. Where the requirement is declared

| Surface | Declared | Default |
|---|---|---|
| Process tags | **Access templates** bound per key — see §7b. No asset config change at all. | unrestricted |
| Config keys | Pattern match on the preference key in `AccessPolicy` — see the corrected table below | `administer` |
| Routes | Optional `AccessGroup` on `RouteRegistry.registerRoute()` | `operate` |
| Pages | A per-role and per-account **page whitelist** — see [page-visibility-whitelist-design.md](page-visibility-whitelist-design.md) | no whitelist (every page) |

The Pages row is a later addition and composes with Routes rather than
replacing it: the group a page needs is still asked first, and the whitelist
can only narrow the answer. It fails **closed** — a stored path matching no
page matches nothing, and an unreadable column denies — because an entry that
failed open would show the page the whitelist exists to hide. The same note
records the change it made to enforcement: page-manager routes now carry a
gate of their own (`PageAccessGate`), which closes the deep-link hole this
spec's §6 warns about in general terms.

Tags fail **open** (an unbound key is unrestricted); config keys fail **closed**
(anything unrecognised needs `administer`). That asymmetry is intentional: a
wrongly-open setpoint is a nuisance, a wrongly-open config write is a broken
plant.

**Corrected key table (amended 2026-08-29).** The patterns originally written
here — `page.*`, `alarm.*`, `keymap.*` — were invented rather than read out of
the tree, and **`page.` with a dot matches none of the real page-editor keys**,
which use underscores. Under the original table every one of them fell through
to the `administer` default. Two consequences, both found in Phase 3 plan
review, neither visible on any screen:

- `lib/page_creator/page.dart:247` writes `page_editor_data` **at boot with
  nobody signed in** (via `lib/providers/page_manager.dart:29` →
  `PageManager.load()`). Denied → `pageManagerProvider` errors → **a fresh
  station shows no pages at all.**
- `lib/page_creator/assets/recipes.dart:280` writes `'${bucket}.recipes'`, and
  `:266` writes a default on the **read** path — so merely viewing a recipes
  asset as an anonymous operator would have been denied. A Shift Leader
  (`{operate, setpoints}`) could not save a recipe, contradicting the user
  story in REQUIREMENTS.md that names recipes alongside setpoints.

The rules, keyed on names that exist in the tree:

| Key | Group | Why |
|---|---|---|
| `page_editor_data` | `configure` | `page.dart:90`. Matches the route — `/page-editor` is `configure`-gated, so the page that edits and the key it saves need the same group, or a Phase 6 role holding `configure` without `administer` could open the editor and not save. |
| `page_editor_top_level_order` | `configure` | `page.dart:91`, same reasoning. |
| `page_editor_image:*` | `configure` | `image_store.dart:78,96`, prefix. |
| `*.recipes` | `setpoints` | `recipes.dart:266,280`, suffix. The row above for "targets, limits, recipes" is `setpoints`; the requirement names them in one breath. |
| `alarm*`, `keymap*` | `configure` | Verify the real names before trusting these two — they were written by the same guess that got `page.` wrong. |
| server / db / network | `administer` | unchanged |
| anything else | `administer` | the fail-closed default |

**Derive the rules from the keys that exist, not from this table.** It has now
been wrong twice. Key *expressions* must be resolved to their constants —
`storageKey`, `orderStorageKey`, `'$keyPrefix$id'` and `'${bucket}.recipes'`
are all invisible to a grep for string literals, which is how the original
error survived. A test asserting such a key resolves to `administer` *passes*
while the station is broken.

### 7b. Access templates — how tag writes are gated

**There is no `requiredGroup` on the asset config.** Tag authorization is
defined entirely by templates bound to keys, so it is configuration rather than
code: no codegen change, no new control in `configure()`, and Phase 4 stops
being a code phase for the assets themselves.

A **template** is a user-defined, named set of rules in a database table,
mapping a struct member (or the whole key) to an `AccessGroup`:

```
template "conveyor"
  p_cmd_JogFwd      -> operate
  p_cmd_JogBwd      -> operate
  p_cmd_FaultReset  -> operate
  p_cfg_ManualFreq  -> setpoints
  p_cfg_AutoFreq    -> setpoints
```

This exists because one conveyor key carries both `p_cmd_JogFwd` and
`p_cfg_ManualFreq` through a single `stateMan.write(key, wholeStruct)`. A group
per *asset* cannot separate jogging from changing drive frequency; a group per
*member* can.

**Templates are not defined in code.** Ship none. The user creates them. Only
four assets write structs — `conveyor`, `schneider`, `sensor`, `recipes` — so
the realistic count is small.

**Binding is explicit, per key, always.** No inference from asset type, no
pattern matching on key names. `KeyMappingEntry` (`state_man.dart:490`) gains
`accessTemplate: String?`. It is already loaded as `keyMappings.nodes[key]`,
which is what lets the UI resolve a group **synchronously at tap time** —
required, because the prompt appears when the control is tapped, not when a
write fails.

**No template means no restriction.** An unbound key is unrestricted, and so is
a member no bound template mentions. The system therefore ships gating nothing
and becomes stricter only as keys are bound.

Because that is fail-open, enforcement is replaced by **visibility**: the key
repository shows whether each key is bound and to what, and makes unbound keys
findable at a glance. A key that should have been restricted must not stay open
with no signal that someone forgot.

### 7c. Templates are managed over MCP

The point of explicit per-key binding is that an agent does it, not a person
clicking forty times. Follow the existing pattern in
`packages/tfc_mcp_server/lib/src/tools/` — `alarm_write_tools.dart` already
does create/update/delete this way:

- `list_access_templates`, `create_access_template`, `update_access_template`,
  `delete_access_template`
- `bind_key_access_template` — key to template, or null to unbind
- `list_unbound_keys` — the visibility mechanism above, and exactly what an
  agent needs to sweep a plant in one pass

Write tools emit a **proposal** that a human approves
(`mcp_bridge_notifier.dart:104`), which is the right posture for something that
changes who may do what: an agent proposes the bindings, a person approves them
in bulk.

Gate these tools on **`users`** — they change authorization, which is the same
concern as roles and the trail, not machine configuration. Audit them with
`origin = 'mcp'` and `who` = the approving user, never the agent.

### 7d. The key repository manages templates too

MCP is for sweeps; the UI is for understanding and for the one-off change. Both
are first-class, and they edit the same table.

The key repository gains an **access templates** section:

- List, create, rename and delete templates.
- Edit a template's rules: rows of member name to `AccessGroup`, with the whole
  key as a special row for scalar keys. Adding a row offers the members already
  seen on keys bound to that template, so it is picking from a list rather than
  typing PLC identifiers from memory.
- Assign a template to a key, and clear it.
- Show which keys are bound to a template before deleting it, and block the
  delete rather than silently unbinding them.
- Surface unbound keys, so the fail-open gap stays visible.

Deleting or re-scoping a template changes who may write what, so both are
`users`-gated and audited like any other authorization change.

Raised routes stay **visible but locked** in the menu, not hidden. A locked
entry tells a technician the page exists and to find someone; a hidden one looks
like a bug.

---

## 8. Audit

Append-only. Never pruned.

- **Exempt it from the collector's retention policies.** `registerRetentionPolicy`
  exists for time-series; if the audit table is ever swept by it the trail is
  worthless. Assert this in a test.
- On Postgres, add a second role with `INSERT`-only grant on the audit table,
  and ensure the station's main credential has *no* privileges there. The
  station can then forge an entry but cannot erase one. Document the SQL in
  `docs/`; it is a deployment step, not app code.
- On SQLite (dev/demo) that separation does not exist. Say so in the doc rather
  than implying the guarantee holds everywhere.
- Capture a `reason` for `configure` and `administer` writes — a free-text
  prompt on the elevated confirm. Reason is what turns a log into an audit
  trail.

### Honesty requirement

Both connections authenticate the *station*, not a person: one `OpcUAConfig`
username/cert (`state_man.dart:133`), one Postgres credential
(`database.dart:148`). Everything in this spec lives inside the Dart process and
is bypassed by anyone with UaExpert or `psql`.

This is an operational guardrail against accident, **not** an access control.
Say that in the PR description and in the admin screen's own help text. The
failure mode is not the guardrail — it is someone concluding "the HMI has
logins" and deprioritising network segmentation.

---

## 8b. Where the code lives

`packages/tfc_access` — a new package in the existing monorepo `packages/`
folder, alongside `tfc_dart`, `tfc_mcp_server`, `jbtm` and the rest. The relay
branch carries `packages/` as a clean superset (the same six plus its own four),
so a new directory merges without conflict when that branch rebases, and
`tfc_relay_server` can then depend on it.

**It must be pure Dart.** It holds `AccessGroup`, roles, `AccessSession`,
`AccessPolicy` and the `AuditSink` interface — enums, strings and interfaces,
nothing more. **Do not let it depend on `tfc_dart`**: that pulls the open62541
FFI and native assets into everything importing it, and the relay was built
specifically so its server (and a later web client) need neither.

The guards do depend on what they wrap, so `GuardedStateMan` and
`GuardedPreferences` live with `StateMan` / `PreferencesApi` and depend on
`tfc_access`. The dependency runs one way only.

---

## 9. Phases

Six phases, run on one branch with a single PR at the end. `.planning/ROADMAP.md`
is authoritative; this is the summary.

Each is independently shippable because the defaults are today's behaviour: an
unbound key is unrestricted and a route with no group is `operate`, which is
what anonymous holds. Nothing needs a cutover.

1. **Identity and audit** — schema v6, `LocalAuthProvider`, PBKDF2 lifted into
   `packages/tfc_access`, session with listener-gated timeout (persisted, and
   restored only while unexpired), login/logout, four seed roles,
   first-user-while-empty. *Gates nothing.*
2. **Route gating** — `AccessGate`, an optional group on
   `RouteRegistry.registerRoute()`, five config routes raised. No asset changes.
   *Shippable alone.*
3. **The guards** — `AccessPolicy` on `(surface, key, member)`,
   `GuardedStateMan`, `GuardedPreferences`, the three bypasses rerouted, the
   unmapped-surface test, the CI grep.
4. **Access templates** — template table, `accessTemplate` on
   `KeyMappingEntry`, synchronous resolution, `PaneStatus.locked()`, tap-time
   elevation, the key-repository templates section and the MCP tools.
5. **The audit trail page** — read-only, filterable, `operate` out of the
   default view, member rows under `actionId`. Gated on `users`. Depends on
   Phase 1, not Phase 4.
6. **Administration and polish** — roles and users screens, deployment doc for
   the INSERT-only audit role and break-glass recovery.

**If the schedule slips, Phase 6 is what goes.** Roles seeded by migration and
edited through the existing config page is complete, just unpleasant, and
engineering is the only audience. Phase 5 outranks it: a demo where you cannot
see who did what undersells the work. Losing Phase 3 would leave login that
gates nothing.

---

## 9b. The golden gate

Every phase that changes anything visible ships a golden, and **the agent reads
the PNG itself** before closing the phase. A passing golden is not review — a
wrong image matches its own wrong baseline perfectly.

Read each new or changed PNG and confirm:

- It shows the state it claims. A locked row shows the value *and* the lock; an
  elevated session shows who, in orange; a denied tap shows the prompt rather
  than an error.
- **No Ahem boxes.** Solid rectangles instead of glyphs mean a null
  `fontFamily`; load the real font with `loadRealFont()` from
  `test/page_creator/assets/third_party_golden_test.dart` instead of accepting
  them.
- **No violet or off-scheme colours**, which mean `HmiStateColors` fell back to
  `solarizedLight` because the themed wrapper was missing.
- Muted equipment-state colours throughout, only fault red saturated, orange
  reserved for forced/override and elevation.

Generate with `flutter test --update-goldens --run-skipped <file>`, confirm it
then passes *without* `--update-goldens`, and never generate on an SDK that
fails `./scripts/check-flutter-version.sh` — a golden made on the wrong SDK can
land just inside tolerance and leave the next person an image already most of
the way to failing.

---

## 10. Repo traps

Things that will cost days if rediscovered:

- **Never run `dart format` on existing files.** The repo predates Dart 3.11's
  formatter and CI does not enforce it. Format only the lines you add.
- **Codegen order**: after any `@JsonSerializable` change run
  `dart run build_runner build --delete-conflicting-outputs` in
  `packages/tfc_dart` *first*, then at the root.
- **Widget tests** mock OPC UA with a local `_FakeStateMan implements StateMan`
  and override `stateManProvider` — see
  `test/page_creator/assets/start_stop_button_widget_test.dart`.
- **Goldens**: macOS only, generated with
  `flutter test --update-goldens --run-skipped <file>`, and the pinned SDK must
  pass `./scripts/check-flutter-version.sh` first. Look at the PNGs.
- **Colours** come from `HmiStateColors` / `PaneStatus`, never raw `Colors.*`.
  Forced/override is orange by repo convention — reuse it for the elevated
  state, it is the same idea.
- **Device-local vs shared**: sessions and the inactivity timeout are
  device-local (`localPreferencesProvider`); users, roles and audit are shared.
  Never sync a session.
- **`pg_notify` has an 8000-byte cap** and the backend config watcher fires on
  preference writes — keep role config small and do not stuff audit data through
  it.
- **Timers must be listener-gated** (§5).
- A `Database` wrapper in widget tests needs an end-of-body dispose.

---

## 11. Deferred, deliberately

Recorded so they are not silently forgotten:

- OIDC / SAML sign-in (the shape is ready; the implementation is not).
- Badge or PIN login, and with it, attributing *operator* actions to a person.
- Read permissions on trends and history.
- Four-eyes approval, building on the MCP proposal flow.
- Real enforcement: per-user OPC UA sessions, or PLC-side validation in
  `~/Projects/sildarvinnsla`.
- Password policy, and admin-initiated password recovery. Self-service *change*
  shipped — see the account menu in `lib/widgets/access_change_password_dialog.dart`
  — but nothing enforces, expires or can recover a password.
