# Page visibility whitelist — design

Companion to [access-control-spec.md](access-control-spec.md). That spec built
the group model, the session, the guards and the route gate; this note designs
the one thing the user has now asked for on top of it, written 2026-09-11 to be
executed by an implementation agent without re-deriving the discussion.

**The request, verbatim:** *"I need to be able to white list what pages
operator has access to. currently all users see all. lets have an option to
block all and white list what pages the user can see."*

**Amended the same day, twice, and both amendments are folded in below rather
than appended:**

1. *"this whitelist behaviour should also be available on role level"* — the
   whitelist exists at **both** levels: on the role (the audience) and on the
   user (the exception). §1 designs the composition; the earlier revision's
   deferral of a per-user override is overruled.
2. *"please note that the navigation bar can change between logins. it was at
   some point cached in local config, that will change, please architect the
   navigation bar logic neatly"* — the navigation bar today renders a
   boot-time snapshot of device-local cached config through a process-global
   singleton, with no session in it at all. §5b replaces that pipeline with
   providers instead of patching filter calls into the old one.

Today every page-manager page is visible to every session unless the page
raises itself above `operate` via `MenuItem.requiredGroup` — an opt-out model,
page by page. The request is the opposite default, available per audience and
per person: deny every page, then name the ones this audience — or this one
account — may see. The design below delivers that as **a whitelist column on
the role and a whitelist column on the user**, composed into the session once,
enforced at the same three points the group gate already covers — the menu,
the route, and the station's startup page — and edited on the Access screen.

---

## What exists today, and the two holes this work also closes

Read these before implementing; each is load-bearing below.

* **`MenuItem.requiredGroup`** (`lib/models/menu_item.dart`) raises a page (or
  a section, inherited) above `operate`. Its doc comment rules "a group, never
  a role" — roles are renameable, deletable customer data, and a page pointing
  at a deleted role is a dangling reference. §1 below keeps that rule intact
  by putting the whitelist on the *other* side of the relation.
* **`declareMenuRouteGroups`** (`lib/access_routes.dart`) resolves section
  inheritance and declares each page's effective group into `RouteRegistry`.
  `accessGroupForRoute` answers `operate` for anything undeclared.
* **The menu hides what the session cannot open.**
  `NavDropdownState._collectLockedPaths` (`lib/widgets/nav_dropdown.dart:125`)
  computes the locked set during `build` (a `watch`, so a sign-in updates it),
  and `buildFlatMenu` drops those entries; a section whose every child is
  dropped goes too. Hiding is presentation — the comment there says the route
  gate is the enforcement.
* **Hole 1: for page-manager pages there is no route gate.** `addRoute` in
  `centroid-hmi/lib/main.dart:721` registers a bare `AssetView`;
  `centroid-hmi/test/navigation_test.dart` asserts *"a page-manager page is
  not a gate"*, which was the "nothing on the floor changes" phase boundary of
  the access milestone. Consequence, stated plainly because the comment in
  `nav_dropdown.dart` claims otherwise: **a customer page raised via
  `requiredGroup` is hidden from the menu but opens to a typed or deep-linked
  URL.** The nine built-in raised routes are gated (`AccessGate` in
  `main.dart:541`); the plant's own pages are not. A whitelist without route
  enforcement would be decorative in exactly the way spec §6 warns about, so
  closing this is part of the work, not a side quest.
* **Hole 2: the navigation is a boot snapshot of cached local config.**
  `RouteRegistry()` (`lib/route_registry.dart`) is a process-global mutable
  singleton — `_routes`, `_routeGroups`, and a mutable
  `List<MenuItem> menuItems`. It is populated once, before `runApp`
  (`centroid-hmi/lib/main.dart:305-354`), from a `PageManager` deserialised
  off **device-local preferences** — the code's own admission at `main.dart:307`:
  *"This is not ideal, if a second HMI adds a page, we will need to restart
  the app twice."* Beamer's route table is likewise built once, and
  `declareMenuRouteGroups` runs once at boot. Every consumer then reads the
  singleton directly, outside Riverpod: `base_scaffold.dart:63`
  (`isTopLevelDestinationPath`), `:144/:147` (`findTopLevelIndexForBeamer`
  and `getNodeIndex`), `:310` (the sign-out return's `resolveStartupPath`),
  `:556/:588` (the `NavigationBar` destinations, and the tap handler indexing
  `menuItems[index]`), `nav_dropdown.dart:109/:229`, and
  `page_editor.dart:4191/:4201/:4264`. Sign-in cannot change the bar except
  where a widget happens to also watch the session. Amendment 2 makes fixing
  this pipeline part of the feature: the menu must become a derivation of
  (pages × session), not a cached list.
* **The session already re-resolves from the role.** `AccessSession.groups`
  are read from the `app_role` row at sign-in, restore, and
  `refreshGroupsFromRoles`; they are deliberately never persisted
  (`AccessSession.toJson`). The whitelist rides the identical path.
* **Authorization data sits behind `users`, not `configure`.** The
  `AccessKeyBindingTable` ruling (2026-08-30, `database_drift.dart:247`)
  rejected putting a binding inside the `configure`-gated `key_mappings` blob
  because anybody who can edit a page could then re-scope who may write what.
  The same argument decides §1 below — **for both levels**.
* **The top-level `NavigationBar`** (`lib/widgets/base_scaffold.dart:543`)
  never hides a top-level leaf today — only `NavDropdown` popups hide entries
  — and Material's `NavigationBar` asserts at least two destinations.
* **The app bar carries `AccessStatusAction`** on every `BaseScaffold`:
  sign-in is reachable from every page without touching the menu. This is the
  fact §4's lockout argument stands on.

---

## Decisions locked

| Question | Answer |
|---|---|
| Keyed on role or on page? | **On the identity side.** `AccessRole` gains `allowedPages`; `AppUser` gains `allowedPages`; `MenuItem` is untouched. |
| Two levels | **Role = the audience, user = the exception.** A user-level whitelist, when present, **replaces** the role's. |
| The three states, per level | `NULL` = no opinion (role: sees every page; user: **inherit the role's**), empty array = sees none, populated = exactly these. A v6 row carries over as NULL at both levels. |
| Composition | `effective = user ?? role` — one pure function, then the group gate ANDs on top. The whitelist never grants what a group denies. |
| Schema | Two nullable TEXT columns `allowed_pages`, on `app_role` and `app_user`, **schemaVersion 6 → 7**. |
| Scope of the whitelist | **Every menu destination except `/advanced/access`** — amended 2026-09-12, see §13. It was page-manager pages only, which did not match what the menu filter actually did. |
| Anonymous panels | Anonymous resolves to `Operator` and has no user row, so the Operator role's whitelist governs every logged-out panel. Warned at the point of edit. |
| Unknown references | **Fail closed.** A stored path matching no page matches nothing; an unreadable column decodes to the empty set (deny all), never null. |
| Repository unavailable / session loading | **Whitelist not enforced** during the window — the same keep-the-line-running ruling as `_anonymousGroups`' seeded fallback and the 2026-09-02 tag-binding boot window. |
| The navigation source of truth | A provider pair: `menuTreeProvider` (the full tree, session-blind, derived live from the page manager) and `visibleMenuProvider` (the session's filtered view). The `RouteRegistry` menu list is demoted to a mirror the provider writes; nothing new may read it. |
| The route table | Static entries stay. The dynamic fallback route was **not built** — Beamer 1.7 stacks a page per matching route, so a wildcard sits on top of every route rather than behind them (§5a). Instead the live menu is intersected with the route table, so it never offers what the router cannot serve; a page created on another station still needs a restart here. |
| Route behaviour | A new `PageAccessGate` wraps every page-manager route: group gate first, then the whitelist. Also enforces `requiredGroup` on deep links for the first time. |
| Enforcement of edits | Two new writes on `AccessAdminStore` — `role.pages` (ninth) and `user.pages` (tenth) — gated on `users`, audited allowed and denied. |
| UI | One shared Pages editor widget, mounted in the roles section and the users section with level-appropriate labels. |

---

## 1. The model: two whitelists, one effective set

### 1a. Both levels live on the identity, not the page

Two shapes were on the table for the role level: the role row gains
`allowedPages: Set<String>` (page paths), or `MenuItem` gains
`allowedRoles: Set<String>` (role names). The identity side wins on three
independent grounds, any one of which would decide it — and every ground
applies with equal force to the user level, which is why `app_user` gets a
column rather than pages getting a user list.

**Ground 1 — where the data may live.** A whitelist decides who may see what:
it is authorization data. `MenuItem` serialises into `page_editor_data`, a
preference key classified `configure` by `kPrefAccessRules` and editable
through the page editor, the raw preferences editor, and the key-map import
path. Authorization data behind a `configure` gate is the exact confusion the
`AccessKeyBindingTable` ruling closed: anybody who can edit a page could
re-scope which pages a role — or a person — sees, including widening their
own view. `app_role` and `app_user` are written only through
`AccessAdminStore`, which gates on `users` and audits every write, denials
included. Both whitelists get that for free by living there, and cannot get
it anywhere else without building a second guarded write path.

**Ground 2 — the dangling-reference asymmetry.** `MenuItem.requiredGroup`'s
doc comment already argues one half: role names are renameable, deletable
customer data, so page data must never point at a role (or a username, which
is deletable too). Inverting it, the identity points at page paths — also
renameable, also deletable — so a dangling reference is possible in either
direction; the question is which direction fails safely.

* A role renamed or deleted, or a user deleted, with the whitelist *on the
  identity*: the reference problem does not exist. `renameRole` moves the row
  (with its column — see the trap in §2); `deleteRole` and `deleteUser` take
  the whitelist with them. Nothing dangles.
* A page renamed or deleted: the stored path matches nothing and the page is
  hidden from that audience — **fail closed**, visible and repairable in the
  Pages editor, which renders the stale entry as an "unknown page" chip (§7).
  Under the inverted design the same page rename would silently orphan
  entries inside page JSON where no screen surfaces them.

The fail-closed direction matters more here than it did for `decodeGroups`
being forgiving: an unrecognised *group* name costs a role a capability
(safe); an unrecognised *page* entry that failed open would show a page the
whitelist meant to hide (the defect the feature exists to prevent). So:
unknown entries never match, and an unreadable column decodes to the empty
set — deny all — never to `null`.

**Ground 3 — the editing audience.** "Which pages does the Operator role
see" is a role question; "which pages does the freezer panel's account see"
is a user question. Both are asked by the person who configures access, on
the screen where access is configured — pick a role or a user, tick pages,
one save, one audit row. The page-side shape scatters the same answers
across every page's settings popup in the `configure`-gated editor, where
the person who holds `users` may not even be standing.

### 1b. The three states, and why user-level NULL means *inherit*

Each column is nullable TEXT; each level has three states:

| Column | Role level means | User level means |
|---|---|---|
| `NULL` | sees every page (no whitelist) | **use the role's** — no personal opinion |
| `'[]'` (empty array) | sees no pages | sees no pages, whatever the role says |
| `'["/a","/b"]'` | exactly these | exactly these, whatever the role says |

User-level `NULL` **must** mean "inherit", not "sees everything", for two
reasons, the first of which is disqualifying on its own:

* **Upgrade.** Every `app_user` row carried over from v6 lands on `NULL` (a
  new nullable column). Those accounts must behave exactly as before the
  upgrade — governed by whatever their role says — and, crucially, must be
  *bound by a role whitelist an admin writes afterwards*. If user-NULL meant
  "unrestricted", upgrading would silently mint a personal exemption for
  every existing account, and the very first role whitelist anyone turned on
  would govern nobody who existed before v7. The feature would appear broken
  on exactly the accounts it was requested for.
* **The mental model.** An account with nothing set follows its role; that
  is what "one role per user" already trained everyone to expect. A personal
  whitelist is an explicitly taken exception, never a default.

### 1c. Composition: the user's whitelist replaces the role's

Three candidate rules were weighed; override is chosen. The failure modes of
the other two, stated so the choice is checkable rather than taken on taste:

* **Union (`user ∪ role`) — rejected.** The role level stops being able to
  *bind*: a stale personal grant survives every later tightening of the
  role, so an admin narrowing "Operator" cannot know what any operator
  actually sees without auditing every user row. It also makes the user
  column a pure widening mechanism, which is the wrong shape for the
  restrict-this-trainee case entirely.
* **Intersection (`user ∩ role`) — rejected.** It cannot express the
  exception the amendment asks for: granting one supervisor account one
  extra page would require widening the *role*, which changes every holder.
  The user column could only ever narrow, making it a worse spelling of
  "give this person their own role".
* **Override (`user ?? role`) — chosen.** A personal whitelist, when
  present, replaces the role's; when absent, the role governs. Both
  directions of exception are expressible (the trainee sees less, the
  supervisor account sees more), and "what does X see" has a one-line
  answer. The failure mode this choice keeps — an admin widens a role and
  wonders why one overridden account did not gain the page — is mitigated by
  making the override *visible where roles are assigned*: the users section
  row carries an "overrides the role's pages" tag (§7), and the effective
  set is computable by one pure function anyone can reason about. Note the
  override can widen a user's *visibility* past the role's whitelist; it can
  never widen *capability*, because the group gate is ANDed on top (§3) and
  the write guards are untouched. And it is not an escalation path: writing
  either column takes the same `users` gate, so anyone who can set a user
  override could equally have edited the role.

Two behaviours that follow, stated so they are read as properties rather
than discovered as bugs:

* **An override survives `setRole`.** Moving an account to another role
  keeps its personal whitelist — the exception names the person, not the
  (person, role) pairing. The users section shows the tag beside the role
  picker, so the move is never made blind. Clearing the override is an
  explicit edit (back to "follows the role's pages").
* **Anonymous has no user row**, so anonymous composes as role-only by
  construction — no special case in code, just `user == null`.

The one pure function, in `packages/tfc_access` beside the codecs:

```dart
/// The pages a session may see: the user's whitelist when one is set,
/// else the role's, else null (unrestricted). Null user-level input means
/// "no personal opinion", never "sees everything" — see the design note.
Set<String>? effectiveAllowedPages({
  required Set<String>? user,
  required Set<String>? role,
}) => user ?? role;
```

with its truth table pinned in a test:

| `user` | `role` | effective |
|---|---|---|
| null | null | null — every page |
| null | `{a}` | `{a}` |
| null | `{}` | `{}` — none |
| `{b}` | null | `{b}` |
| `{b}` | `{a}` | `{b}` — replaces, never merges |
| `{}` | `{a}` | `{}` — none |

### 1d. The value types

In `packages/tfc_access` (pure Dart — paths are strings, nothing Flutter).
The codec is shared between both levels — one encoder, one decoder, used by
`AccessRole` and by the repository for user rows, so the two columns cannot
drift in format:

```dart
/// Sorted JSON array, or null. Sorted for the same reason encodeGroups
/// emits enum order: a save that changes nothing must not look like a change.
String? encodeAllowedPages(Set<String>? pages);

/// null column -> null; malformed/garbage/wrong type -> {} (deny),
/// never null (allow). Unknown entries are kept — they simply match nothing.
Set<String>? decodeAllowedPages(String? column);
```

`AccessRole` gains `final Set<String>? allowedPages` (in equality, via
`SetEquality<String>`); `kSeedRoles` stays null throughout — seeding a
whitelist would be inventing plant knowledge the code does not have.
`AuthenticatedUser` is deliberately **not** extended: it is the OIDC-shaped
claim carrier, and an OIDC principal without an `app_user` row must land on
"inherit" naturally. The user-level set is read from the user row at session
resolution (§2), not carried in the identity object.

`AccessSession` gains the **already-composed** set, exactly as `groups` is
the resolved copy of the role's column:

```dart
class AccessSession {
  // ...
  /// effectiveAllowedPages(user, role), resolved when the session was
  /// built; null = unrestricted.
  final Set<String>? allowedPages;

  /// Whether this session's whitelist admits [path]. True when there is no
  /// whitelist. Says nothing about groups — the gate composes both.
  bool pageVisible(String path) =>
      allowedPages == null || allowedPages!.contains(path);
}
```

Composing once, at resolution, is what keeps everything downstream —
`pageVisible`, `resolvePageAccess`, the menu provider, the gate — identical
whether the set came from the role or from an override. `toJson` does
**not** serialise it, for the same two reasons `groups` is not serialised: a
role or user edited on another station must take effect here on restore, and
a hand-edited preferences file must not be able to widen a whitelist.
Restore re-resolves from the database, as it already does for groups.
`AccessSession.anonymous` gains an optional `allowedPages` parameter
defaulting to null, so `kSessionWhileLoading` in
`lib/providers/access_policy.dart` keeps its exact current source text —
that file is under `guard_wiring_test.dart`'s source assertions and this
design deliberately does not touch it (§9).

## 2. Storage: schema v7

Two nullable columns, no new table:

```dart
class AppRole extends Table {
  // ...existing...
  /// JSON array of page paths, or NULL for "sees every page". Written by
  /// encodeAllowedPages(), read by decodeAllowedPages().
  TextColumn get allowedPages => text().nullable()();
}

class AppUser extends Table {
  // ...existing...
  /// JSON array of page paths, or NULL for "no personal opinion — the
  /// role's whitelist governs". NULL is inherit, NOT unrestricted: every
  /// v6 row lands here and must stay bound by its role. Empty array is
  /// "sees no pages".
  TextColumn get allowedPages => text().nullable()();
}
```

`schemaVersion` 6 → 7, one new `if (from < 7)` arm in `onUpgrade`:

* SQLite (`native`): `m.addColumn(appRole, appRole.allowedPages)` and
  `m.addColumn(appUser, appUser.allowedPages)`.
* Postgres: `ALTER TABLE app_role ADD COLUMN IF NOT EXISTS allowed_pages
  TEXT` and the same for `app_user`, following the v5/v6 arms' idempotency
  reasoning — several SVN stations share one Postgres database and each of
  them runs this branch. The v6 arm's `CREATE TABLE` literals for both
  tables also gain the column, for fresh Postgres creates. The v6 arm's own
  warning applies unchanged: no test executes the Postgres arm;
  `access_schema_test.dart`'s source-derived column-parity check is what
  stands behind the strings, extended to cover both new columns in both the
  `CREATE TABLE` literals and the `ALTER`s.

**Upgrade is behaviour-preserving by construction.** Every existing row —
the four seeded roles and every account — gets `NULL`, which is "no
whitelist" at the role level and "inherit" at the user level. A station
upgraded to v7 behaves identically until somebody turns a mode on.

**Why not a preference key.** Three independent disqualifiers: preferences
sync between stations through machinery (`PreferencesWatcher`, pg_notify's
8000-byte cap) that access data deliberately avoids; `kPrefAccessRules`
tops out at `administer`, and this data needs `users` (§1a); and the whole
guarded-preferences path exists for *operator-facing* config, while this is
authorization data with a dedicated guarded store already standing. A
per-station preference would also make the whitelist a property of the
panel rather than of the audience, which is the wrong axis — per-station
page sets are already expressible the intended way, by committing panels to
station accounts, and with the user-level column those accounts can now
carry their own whitelist directly.

**Repository changes**
(`packages/tfc_dart/lib/core/access/access_repository.dart`):

* `_toRole` decodes the role column; `roles()` and `role()` need no other
  change. `AppUserData` gains the column through codegen; `listUsers()` and
  `user()` carry it for free.
* `upsertRole`'s update arm keeps writing **only** `groups` — it must not
  clobber a whitelist saved by the dedicated write below; its insert arm
  writes `allowedPages` from the value type (a create carries whatever the
  caller built, which for the store's `createRole` is null).
* New `setRoleAllowedPages(String roleName, Set<String>? pages)` and
  `setUserAllowedPages(String username, Set<String>? pages)`: targeted
  updates inside a transaction, `MissingRoleError` /
  `UserNotFoundException` when the row is absent. No lockout guard on
  either — a whitelist cannot remove `users` from anybody, and
  `/advanced/access` is not whitelistable (§4), so no whitelist state can
  take the roles screen away from the people who hold the group.
* **The rename trap, called out because it is the dangerous direction:**
  `renameRole` is an insert + repoint + delete, and the insert copies
  columns field by field (`access_repository.dart:547` names `groups` and
  `seeded`). It **must** copy `allowed_pages` too, or renaming a
  whitelisted role silently drops the column to NULL — which fails *open*,
  showing the role every page. A repository test drives exactly this.
  (`setRole`, `deleteUser`, `setPassword` are single-row updates/deletes
  and cannot lose the user column; only the rename reconstructs a row.)
* `anonymousGroups()` grows a sibling, `anonymousRole()`, returning the
  whole Operator `AccessRole` (groups *and* whitelist) with the same
  fallbacks: missing row or throw → seeded groups, null whitelist. The
  session controller's `_anonymousGroups` becomes a call to it; keeping
  `anonymousGroups()` delegating to `anonymousRole()` avoids touching its
  callers.

**Session resolution** (`lib/providers/access.dart`) composes at every site
groups are resolved today — `_restoreOrFloor`'s success path (fetch the
user row beside the role it already fetches), `signIn` (after the auth
provider answers, read the user row), the panel-account resume,
`refreshGroupsFromRoles` (re-fetch both), and the anonymous floor (role
only, via `anonymousRole()`). Each site calls `effectiveAllowedPages` and
stores the result on the session. A user row that cannot be read composes
as `user: null` — inherit — never as deny; the row's absence says nothing
about the person's exception, and the role still binds.

## 3. Composition with `requiredGroup`: the precedence table

The whitelist is a **filter, never a grant**. Both questions are asked, in a
fixed order, and the group question is always first — the whitelist cannot
open a page the group gate shuts, and it is not consulted at all for the
routes outside its scope. "The whitelist" below always means the session's
composed `allowedPages` (§1c); the role/user split is invisible from here
down.

| Route | Group gate says | Whitelist says | Result |
|---|---|---|---|
| `/advanced/access` | allowed / denied | *never consulted* | group gate's answer, unchanged — see §4 layer 1 and §13 |
| Any other built-in (the rest of `kRaisedRoutes`, Alarm View, History View, About Linux, first-user) | allowed / denied | same rules as a page-manager page | as the rows below (amended 2026-09-12, §13) |
| Page-manager page | denied (its `requiredGroup`, own or inherited, is not held) | anything | **denied** — the lock names the group, exactly as today |
| Page-manager page | allowed (or `operate`, undeclared) | session unrestricted (null) | **allowed** — today's behaviour |
| Page-manager page | allowed | path in the set | **allowed** |
| Page-manager page | allowed | path not in the set (or set empty) | **denied** — "not available" |
| Page-manager page | waiting (session/repository unresolved, group raised) | — | waiting |
| Page-manager page | `operate` short-circuit | session still loading | **allowed** — the boot-window ruling, §4 |

One pure function owns this table, next to `resolveAccessGate` and in its
idiom (no `ref`, no context, truth-table-testable):

```dart
AccessGateState resolvePageAccess({
  required AccessGroup group,               // from accessGroupForRoute(path)
  required String path,
  required AsyncValue<AccessRepository?> repository,
  required AsyncValue<AccessSession> session,
}) {
  final byGroup = resolveAccessGate(
    group: group,
    repository: repository,
    session: session,
    allowWhenRepositoryUnavailable: false,  // no page is Server Config
  );
  if (byGroup != AccessGateState.allowed) return byGroup;
  final s = session.valueOrNull ?? kSessionWhileLoading;
  return s.pageVisible(path)
      ? AccessGateState.allowed
      : AccessGateState.denied;
}
```

Delegating the group half to `resolveAccessGate` verbatim is the same
one-copy-of-the-question rule `accessRouteLocked` and `AccessLockBadge`
already follow: the menu, the gate and the badge must agree in every
repository state, and two copies of "locked when…" is how they stop
agreeing.

## 4. Anonymous panels, boot windows, and why nobody gets locked out

**Anonymous is the Operator role with no user row, so the Operator row's
whitelist is the anonymous panel's whitelist.** That is the feature working
as requested — "what pages operator has access to" — and it is also the
footgun the Operator groups banner already documents: editing that row
changes every logged-out panel on the floor at once. The Pages block shows
the same `AccessAdminWarning` banner on the protected row (§7), and the
save confirmation fires when the edit *narrows* the anonymous view (turning
the mode on, or unticking pages) — narrowing is the direction that
surprises a floor, the mirror image of the groups dialog firing on
widening. A *user*-level whitelist can never surprise the floor: it binds
one signed-in account only.

**Turning either mode on cannot brick a station.** Layered, in decreasing
order of importance:

1. **The access screen is not whitelistable.** No whitelist state at either
   level, including the empty set, can hide or gate `/advanced/access`
   beyond the `users` gate it already has. The existing last-`users`-holder
   invariant already guarantees somebody holds that group; together the two
   mean the person who can fix a bad whitelist can always reach the screen
   that fixes it.

   **This was prose and nothing enforced it** until 2026-09-12 (§13). The
   sentence above originally covered the whole Advanced surface, on the
   reading that `kRaisedRoutes` answer to groups alone — but
   `visibleMenuProvider` asks `resolvePageAccess` about *every* entry in the
   tree, so setting any whitelist dropped the entire Advanced section from
   that session's menu, the access screen with it. The guarantee now lives in
   `routeExemptFromPageWhitelist`, which the menu filter and the route gate
   both go through.
2. **Sign-in is not a page.** `AccessStatusAction` sits in every
   `BaseScaffold` app bar, and the whitelist-denied route body (§5a)
   carries its own Sign in button, the `AccessLockedBody` idiom. A panel
   whitelisted down to nothing still shows its app bar; an Engineering
   sign-in re-resolves the session and every page returns.
3. **The empty whitelist is legal but explicit.** "Block all" is a state
   the user asked for by name, so it is not refused — but the editor
   requires flipping a labelled mode control (§7), never offers it as a
   side effect, and the summary line on the closed row says "sees no
   pages" in so many words.
4. **The startup page cannot dead-end.** §5c: a denied startup path renders
   the not-available body with the bar and app bar present, not a blank
   screen and not `PageNotFound`.

**The boot and outage windows fail open, deliberately.** While
`accessSessionProvider` has not resolved — and on the floor that window
includes "Postgres is unreachable and `databaseProvider` is still retrying"
— the whitelist half of §3 resolves on `kSessionWhileLoading`, whose
`allowedPages` is null. Three reasons, each already ruled on elsewhere:

* A `waiting` state for `operate`-group pages would blank every plant page
  on every boot for as long as the database takes to answer, which on a cut
  link is tens of seconds of a panel that reads as broken.
  `resolveAccessGate`'s `operate` short-circuit exists precisely to keep
  unraised routes free during that window; the whitelist must not
  reintroduce the cost.
* The precedent is explicit: `_anonymousGroups` falls back to seeded
  Operator groups because "a logged-out panel that cannot jog a conveyor
  because Postgres blinked is a stopped line", and the tag-binding resolver
  answers the operate floor until its first snapshot (2026-09-02 ruling).
  Visibility is the same class of decision, made the same way.
* The whitelist is a tidiness-and-focus control inside a system whose own
  spec (§8, the honesty requirement) says the entire apparatus is an
  operational guardrail. The write paths stay independently guarded by
  groups and templates whichever pages are visible; a page briefly visible
  during an outage exposes controls that still refuse.

The cost is stated rather than hidden: during a database outage a
whitelisted panel shows every `operate` page, and for a frame or two at
boot the menu may include entries that disappear when the session resolves
— the same transient the group-hiding already has, per `nav_dropdown.dart`'s
"nothing reads as denied yet" comment.

## 5. Enforcement points

Spec §6's warning applies verbatim: a guard beside an unenumerated hole is
decorative. Three ways to reach a page; all three are covered, by one
predicate.

### 5a. The route — the enforcement point

`addRoute` in `centroid-hmi/lib/main.dart` wraps every page-manager route:

```dart
routes[menuItem.path!] = (context, state, args) => BeamPage(
      key: ValueKey(menuItem.path!),
      title: menuItem.label,
      child: PageAccessGate(
        path: menuItem.path!,
        title: menuItem.label,
        child: Consumer(builder: (_, ref, __) =>
            AssetView(pageName: menuItem.path!)),
      ),
    );
```

`PageAccessGate` (new, `lib/widgets/page_access_gate.dart`) is `AccessGate`'s
sibling: a `ConsumerWidget` that watches `accessRepositoryProvider` and
`accessSessionProvider`, asks `resolvePageAccess` with
`accessGroupForRoute(path)`, and renders the child, a locked body, or the
waiting spinner. Unlike `AccessGate` it takes the *path*, not the group,
because a page's group lives in the registry (declared by
`declareMenuRouteGroups`) rather than in a literal at the call site — and
because the whitelist question is keyed on the path. The denied body reuses
`AccessLockedBody`'s layout with its own copy: when the group gate denied,
the existing group wording; when the whitelist denied,
`kPageNotAvailableHeadline` — "This page is not available" — with the
role-naming subtitle and the Sign in button. No "request access", no dead
end, same rules as the existing locked page.

This wrapper is also what finally refuses a deep link to a
`requiredGroup`-raised customer page — hole 1. The "nothing on the floor
changes" boundary that `navigation_test.dart` protected still holds for
behaviour: a page with no `requiredGroup`, seen by a session with no
whitelist, renders identically (the gate resolves `allowed` from the
`operate` short-circuit plus a null whitelist, and — like `AccessGate` —
adds nothing around the child). The child is not built while denied, per
`AccessGate`'s rule: a page must not run its subscriptions behind a lock.

**The dynamic fallback route — NOT BUILT; see the note below.** Beamer's map is built once at boot, which
is half of hole 2: a page created on another station has no route here
until a restart (`main.dart:307`'s two-restart admission — the first
restart also only sees the stale device-local cache until the database copy
lands). With the menu now live (§5b), a boot-fixed route table would be
worse than before — the menu would show an entry the router cannot serve.
So the route map gains one trailing wildcard entry (`RoutesLocationBuilder`
supports path wildcards; the exact key spelling is the implementer's to
verify against the pinned Beamer version) whose builder resolves at
navigation time through a `Consumer`:

* the path names a **published** page in `pageManagerProvider` (falling
  back to `bootstrapPageManagerProvider`) → `PageAccessGate` around
  `AssetView(pageName: path)` — `AssetView` already reads its layout from
  the same provider, so the page renders from the database copy with no
  restart at all;
* the path names a known but **unpublished** page → `RouteRedirect` to the
  fallback, matching the boot-time treatment of drafts;
* unknown → `PageNotFound`, as today.

Static entries are matched in preference to the wildcard, so boot-known
routes — the nine gated built-ins above all — behave exactly as before;
the wildcard can never shadow them. The `addRoute` overwrite edge that
`lib/access_routes.dart`'s doc records (a page slugged onto a built-in path
replaces the gated route) is unchanged by this design and stays documented
there.

> **Implementation note, 2026-09-11.** The wildcard route below was tried and
> abandoned: on the pinned Beamer 1.7, `RoutesBeamLocation.chooseRoutes`
> returns **every** sub-matching route and `buildPages` stacks a page for each
> one, so a `'*'` entry adds a second page on top of every route in the app
> rather than standing behind them. Rebuilding the delegate instead resets
> navigation state. What shipped is the conservative half of the same goal:
> `routablePathsProvider` intersects the live menu with the route table's key
> set, so the menu can never offer an entry the router would answer
> `PageNotFound` for. A page created on another station therefore still needs
> a restart of this one — the pre-existing behaviour, unchanged by this work
> and now stated on that provider rather than implied. The paragraph above is
> kept as the record of what was intended and why it did not hold; the one
> below is corrected to describe what the code actually does.

**What still requires a restart, named rather than left quiet.** Whitelist
changes take effect live: they ride the session, and the menu and the gate
both read it. So does anything about a page that already has a route —
publish, unpublish, a group raised or removed — through the live menu (§5b)
and `replaceMenu`'s redeclaration. What does **not**: a page *created* on
another station has no route on this one until it restarts, because the route
table is still built once at boot. The menu is intersected with that table
(`routablePathsProvider`) so the entry is simply not offered, rather than
offered and then answered with `PageNotFound`. The rest of the residue: the
**built-in** route set and menu
entries (platform flags, `kKnowledgeEnabled`) are compile/boot facts and
should be; and `clearBeamingHistoryOn` is a `BeamerDelegate` constructor
argument, so a page *created after boot* does not clear the back-stack when
landed on until the next restart — a cosmetic staleness in the back-arrow,
accepted and recorded here rather than silently kept.

A note on rebuild cost, because a session watch on every page route looks
alarming beside this repo's history: sign-in flips the gate
`allowed → allowed` and rebuilds the subtree, but `PlantPageView` renders
`AssetPage` instances owned by `pageManagerProvider`, which a session
change does not touch — same instances, same `ObjectKey`s, no asset
teardown, no pane close. The watch that would actually hurt (anything
reaching `stateManProvider`) is §9's business.

### 5b. The menu pipeline — architected, not patched

Amendment 2, verbatim: *"the navigation bar can change between logins. it
was at some point cached in local config, that will change, please
architect the navigation bar logic neatly."* The first revision of this
note filtered the singleton at each render site; that treats a structural
problem as a patch. The structural problem (hole 2): the menu is composed
once before `runApp` from a device-local cache into a process-global
mutable singleton, and every consumer reads that singleton synchronously,
outside Riverpod — so neither a sign-in nor another station's page edit can
change the bar by any honest mechanism.

**The new source of truth is a provider pair.** Both live in a new
`lib/providers/menu.dart`:

```dart
/// The FULL menu tree — every published page, the built-ins, Advanced —
/// composed live and session-blind. This is what the page editor, the
/// startup resolver and the route helpers see. It knows nothing about who
/// is standing at the panel.
@Riverpod(keepAlive: true)
List<MenuItem> menuTree(Ref ref) {
  final manager = ref.watch(pageManagerProvider).valueOrNull
      ?? ref.watch(bootstrapPageManagerProvider);
  // buildTopLevelMenuItems(isLinux, pages, historyAtTopLevel) + sortTopLevel,
  // i.e. exactly the composition main.dart:334-354 performs once today,
  // moved here so it re-runs when the database copy of the pages lands or
  // changes. Order comes from page_editor_top_level_order via sortTopLevel,
  // BEFORE any filtering, so ordering and visibility stay separate concerns.
}

/// The SESSION'S menu — menuTree filtered by resolvePageAccess. What the
/// NavigationBar and the popups render. Watching the session here is what
/// makes the bar change between logins.
@Riverpod(keepAlive: true)
VisibleMenu visibleMenu(Ref ref) { ... }
```

`VisibleMenu` is a small value type, not a bare list, because the
index-mapping hazard must be solved once, in the provider, not per widget:

```dart
class VisibleMenu {
  /// Top-level entries this session may see, in menuTree order — a pure
  /// filter, never a sort. A section survives iff any leaf beneath it
  /// survives; its children are filtered recursively.
  final List<MenuItem> topLevel;

  /// The top-level index owning [path], resolved against THIS list — the
  /// one selectedIndex and onDestinationSelected must both use.
  int? indexOfPath(String? path);

  /// Material's NavigationBar asserts >= 2 destinations; the scaffold
  /// renders no bar when this is false (the fullscreen mode already
  /// renders bottomNavigationBar: null, so a bar-less scaffold is an
  /// existing, tested state — the app bar and sign-in remain).
  bool get showsBar => topLevel.length >= 2;
}
```

The filter asks `resolvePageAccess` per leaf — the same one function as the
route gate and the badge (§3) — with the session and repository values the
provider is watching. While the session is loading it filters on
`kSessionWhileLoading` (unfiltered — §4's boot ruling). Filtering **never
reorders**: surviving entries keep their `menuTree` relative order, which
keeps `page_editor_top_level_order` the sole ordering authority; a test
asserts filter-then-order equals order-then-filter.

**Declarations move with composition.** `menuTree` is also where route
groups are (re)declared: on each rebuild it calls a new
`RouteRegistry.resetRouteGroups()` — clear, `installRaisedRoutes`,
`declareMenuRouteGroups(newTree)`, in that order inside one method so the
built-ins-first layering invariant cannot be assembled wrong at a call
site. This fixes a staleness the boot-time-once call has today: a page
whose `requiredGroup` is *removed* currently stays declared (declaring
writes nothing for null) until restart; reset-and-redeclare unraises it the
moment the edited pages arrive.

**The singleton is demoted to a mirror.** `RouteRegistry.menuItems` is not
deleted in this milestone — `page_editor.dart` and two `base_scaffold`
helpers read it synchronously — but it gets exactly one writer:
`menuTree`'s build, which replaces the list's contents with the fresh
**full** tree each time it recomputes. `main.dart`'s pre-`runApp` seeding
becomes the bootstrap value the provider's first build reproduces. A source
test (the `guard_wiring` idiom) asserts no file outside
`lib/providers/menu.dart` and the boot path mutates `menuItems`, so the
mirror cannot silently grow a second writer. New code reads the providers,
never the singleton.

**Who reads what — the migration table:**

| Consumer | Reads today | Reads after | Why |
|---|---|---|---|
| `NavigationBar` destinations (`base_scaffold.dart:556`) | `RouteRegistry().menuItems` | `visibleMenu.topLevel` | the session's bar |
| `selectedIndex` (`findTopLevelIndexForBeamer`, `:548`) | singleton + `getNodeIndex` | `visibleMenu.indexOfPath` | must index the same list the destinations render |
| `onDestinationSelected` (`:588`) | `menuItems[index]` | `visibleMenu.topLevel[index]` | the desync between a filtered render list and an unfiltered tap list is the popup-sizing bug class, one widget up |
| `NavDropdown` popups | the singleton item + `_collectLockedPaths` hiding | the already-filtered section item from `visibleMenu` | pre-filtered input; `_lockedPaths` and its walk are **deleted** — the provider is the one filter |
| `isTopLevelDestinationPath` (`:63`) | singleton | `menuTree` (full) | back-arrow suppression is about the tree's shape, not this session's view; a page you cannot see but navigated to (gate body) still needs a sane app bar |
| Sign-out return `resolveStartupPath` (`:310`) | singleton | `menuTree` (full) | routability is the question; *permission* is the gate's job — resolving against the filtered view would silently re-target the startup page instead of showing the honest not-available body |
| Page editor (`page_editor.dart:4191/:4201/:4264`) | singleton | **full tree, unchanged** (singleton mirror now, `menuTree` when touched next) | a `configure` surface editing the whole tree must see every page; showing it an operator's filtered view would make pages un-editable and un-orderable for the very person managing them. This distinction — *the editor is never a consumer of `visibleMenu`* — is stated here so it survives refactors |
| Startup path at boot (`main.dart:367`) | boot-composed list | unchanged (pre-`runApp`, no container) | validated for routability only; the gate enforces permission on landing (§5c) |
| `PageAccessGate`, badge | n/a / registry groups | unchanged — they ask `resolvePageAccess` | enforcement never reads the menu at all; hiding is presentation |

**Dependency direction, drawn so §9 is checkable:**

```
pageManagerProvider ──▶ menuTreeProvider ──▶ visibleMenuProvider ──▶ widgets
localPreferences  ──▶ (bootstrap seed)          ▲            (NavigationBar,
accessRepositoryProvider ───────────────────────┤             NavDropdown)
accessSessionProvider ──────────────────────────┘
```

Arrows point *toward* the UI leaves. Nothing in this graph is read by —
or readable from — `stateManProvider`, `preferencesProvider`,
`accessPolicyProvider` or anything else on the plant-connection side; the
two new providers are UI-side leaves, and `access_policy.dart` is not
edited (§9). A sign-in rebuilds `visibleMenuProvider` and the scaffolds
watching it — that is the amendment's requested behaviour — and rebuilds
nothing upstream of them.

### 5c. The startup page

`startup_url` is device-local and resolves before `runApp`, when no session
exists, so boot-time filtering is impossible by construction — and
unnecessary: the startup path lands on the route, the route wears
`PageAccessGate`, and a whitelisted-out startup page renders the
not-available body with the full scaffold around it. Same story for the
sign-out return (`BaseScaffold` beams to the resolved startup path, now
validated against `menuTree`) — an operator signing out on a page their
floor identity cannot see lands on the lock, not on a stale page.
`resolveStartupPath` stays session-blind on purpose: it answers "is this
path routable", the gate answers "may *you* open it", and folding the
second question into the first would need a session at a moment none
exists. A session-aware fallback ("first visible page instead of the lock
body") is a deferred nicety, listed in §12.

## 6. Sections

**Both whitelists store leaf page paths only.** Sections are not routes
(`declareMenuRouteGroups` declares nothing for them; `accessGroupForRoute
('/section')` answers `operate` vacuously), and storing section paths would
create an inheritance question the group model answers at *declare* time
that the whitelist would have to answer at *check* time, with a stale copy
of the tree shape inside a database row. Leaf-only storage keeps the stored
form independent of how pages are foldered — moving a page between sections
does not invalidate its grant, because the grant names the path, and page
paths in this app do not change when a page changes parents.

Consequences, each deliberate:

* **A section disappears when every child is hidden** — `visibleMenu`'s
  recursive filter (§5b) does it in one place for the popups and the top
  level alike.
* **A new page is invisible to a whitelisted audience until granted.**
  Default deny extends to pages that did not exist when the whitelist was
  written — that is what "block all and white list" means, and the
  alternative (section-level grants that auto-admit new children) would let
  a `configure` holder publish a page into an already-granted section and
  reach a whitelisted audience without a `users`-gated edit. Stated in the
  Pages block's subtitle so it is read as a property, not discovered as a
  bug.
* **The editor may still offer section-level ticking as a gesture** (§7): a
  tri-state checkbox on a section header ticks or clears its current leaf
  descendants. It is sugar over leaf grants — what is saved is the leaves.

## 7. UI: one Pages editor, two mounts

The picker is one widget — `AccessPagesEditor`, new, beside the sections it
serves — mounted by the roles section *and* the users section. One widget
because two copies of a picker is two places the semantics drift: the
stale-chip handling, the tri-state section gesture, the draft mechanics and
the leaf-only storage rule must be identical at both levels, and a shared
widget makes that a property instead of a review item.

```dart
class AccessPagesEditor extends ConsumerStatefulWidget {
  /// The stored value being edited: null, empty, or a set of paths.
  final Set<String>? value;
  /// What the null state means HERE — the one honest difference between
  /// the two mounts. Roles: "Sees every page". Users: "Follows the
  /// role's pages". Everything below the mode control is identical.
  final String inheritLabel;
  final ValueChanged<Set<String>?> onChanged;
  // keys are parameterised by the owning row, kAccessPagesModeKey(...) etc.
}
```

Layout, in the sections' existing idiom (dense tiles, `EdgeInsets.zero`,
keys per control, no raw `Colors.*` — everything through the theme's scheme
as the sections already do):

```
┌ Pages ────────────────────────────────────────────────┐
│ Which pages appear in the menu and may be opened.     │
│ Pages added later are hidden until granted here.      │
│                                                       │
│ (•) Sees every page            ← role mount           │
│     / Follows the role's pages ← user mount           │
│ ( ) Only the pages ticked below                       │
│                                                       │
│   [ when "only ticked" is selected: ]                 │
│   ☑ Home                                    /         │
│   ▣ Processing                              section   │
│       ☑ Filleting line                      /fillet   │
│       ☐ Freezer overview                    /freezer  │
│   ☐ Packing                                 /packing  │
│   ⚠ /old-line — no page with this path exists  [✕]    │
└───────────────────────────────────────────────────────┘
```

* **The mode control** is a two-option `RadioListTile` pair (not a switch —
  the two states need their own sentences). Selecting the inherit/open
  option submits null; "only ticked" submits the set, empty included.
  Flipping to "only ticked" with nothing ticked is legal; the summary under
  the closed row then reads "sees no pages".
* **The tree** is `menuTreeProvider` — every page *and* every built-in,
  `/advanced/access` excepted, which is the scope rule of §3 as amended by
  §13 made visible — and always the **full** tree (the picker is a
  `users`-gated admin surface; it must show pages the *editing* session's own
  whitelist hides). Sections render as plain headings over their
  leaves, not as tri-state checkboxes: the sugar §6 allows was never built,
  and a heading is what the shipped widget draws; unpublished drafts render
  with the editor's existing "(draft)" annotation so a grant can precede a
  publish. Each row shows label and path — the path is the stored identity
  and the label is renameable, so showing both is what keeps a grant
  auditable against the row it wrote.
* **Stale entries** — stored paths matching no current page — render at the
  bottom with a warning glyph in `onSurfaceVariant` (not error red; a stale
  grant is hygiene, not a fault) and a remove control. They are preserved
  on save unless removed: a path can be stale because another station has
  not yet synced a page, and silently dropping it would make Save
  destructive.

**The roles mount** (`lib/pages/access_roles_section.dart`): inside the
open `_RoleTile` editor, below the seven group checkboxes and above the
refusal slot. The Operator row shows the existing `AccessAdminWarning`
banner extended to name pages as well as groups, and `_save` gains the §4
confirmation on narrowing the anonymous view. One draft, one Save: the tile's
`_draft` grows the pages state; Save issues `role.update` (groups, when
changed) and `role.pages` (when changed) — two store calls at most, each
its own audit row (an `actionId` join was considered and dropped: the two
writes answer different filters in the trail, and the store's
builder-per-write design has no seam for a shared id without widening every
signature).

**The users mount** (`lib/pages/access_users_section.dart`): the user row's
expanded editor gains the same block with `inheritLabel: "Follows the
role's pages"`. The **closed row's summary carries the override tag** —
"overrides the role's pages" — beside the role name, so the §1c
visibility-of-override rule holds exactly where roles are assigned, and a
`setRole` move is never made blind to the exception that will survive it.
Save issues `user.pages` when changed.

After a successful save either section calls the existing pair —
`ref.invalidate` of its list provider and
`AccessSessionController.refreshGroupsFromRoles` — and the second is what
makes the menu on *this* panel update live, since `visibleMenuProvider`
watches the session. Other panels pick the change up at their next session
resolution (sign-in, restore, refresh), the same freshness `groups` already
has; live cross-station push is out of scope with the same "no change feed
on these tables" reasoning as `lib/providers/access_admin.dart`.

**Goldens** per mount and per mode, light and dark (the outline-on-dark
trap is documented in the repo; assert against `onSurface`-alpha
separators, not `colorScheme.outline`), inspected per the golden gate in
spec §9b.

The page editor's per-page popup ("Published for everyone / for a group")
is **not** extended with role or user ticks. That would be the page-side
model of §1a sneaking back in through the UI: the popup writes
`page_editor_data` under `configure`, and identities must not be editable
from there. The popup stays what it is — the group raiser.

## 8. Audit

* **Editing a whitelist is an audited write, at both levels.**
  `AccessAdminStore` gains its ninth and tenth writes:
  * `setRolePages(String name, Set<String>? pages)` — itemKey `role.pages`,
    under the existing `role.` prefix; constructor `AuditRecord.rolePages`.
  * `setUserPages(String username, Set<String>? pages)` — itemKey
    `user.pages`, under the `user.` prefix; constructor
    `AuditRecord.userPages`.

  Both follow the file's invariant order exactly: gate on
  `kAccessAdminGroup` → deny row before the throw → repository call →
  allowed row. `oldValue`/`newValue` carry the previous and new encoded
  arrays (or null), so mode changes are legible as null↔array transitions —
  including the user-level inherit↔override flip, which is the edit an
  admin will most want to find later. The store's class doc ("eight writes,
  eight itemKeys, and that is the whole list") is updated to ten *with this
  design note cited as the decision*, which is what that sentence demands;
  the properties it protects — every write has an itemKey, a constructor
  and a named test; no delete, no prune, no export over `audit_entry` — all
  hold for both. `audit_trail_grouping` gets labels for both new itemKeys
  so the trail renders them as words rather than raw keys.
* **A route-level denial is not audited**, matching the group gate today:
  `AccessGate` writes no row and calls no `reportAccessDenial` — the denial
  stream and the trail cover *writes*, and a refused page view is neither a
  write nor tap-initiated plumbing (the operator is looking at the
  explanation; there is nothing for the shared prompt to add). The menu
  hiding is likewise silent. If route denials ever become trail-worthy,
  that is one decision for both gates, not a whitelist special.
* **Denied `role.pages` / `user.pages` attempts land in the trail** like
  every other store denial, which is how a too-tight admin role gets found
  — the same argument spec §2 makes for recording denials at all.

## 9. What this design must not do

* **No new watch anywhere near the plant connection.**
  `lib/providers/access_policy.dart` is not edited at all — not its
  imports, not `kSessionWhileLoading`'s source (the session type's new
  field defaults to null), nothing: `guard_wiring_test.dart` asserts that
  file's source names none of the session/database providers, and the OPC
  UA teardown documented on `accessPolicyProvider` is the failure a
  violation buys. The whitelist is consumed exclusively by UI-side leaves:
  `visibleMenuProvider` and the widgets on §5b's diagram, plus
  `PageAccessGate`, a widget in `AccessGate`'s image. The dependency arrows
  in §5b all point toward the UI; nothing on the `stateManProvider` /
  `preferencesProvider` / `accessPolicyProvider` side gains an edge to or
  from the menu graph. `AccessPolicy` itself — the write-path policy —
  knows nothing of pages; visibility is not a write surface.
* **No whitelist data in `page_editor_data` or any preference key**, at
  either level (§1a, §2).
* **No re-derived copies of the visibility question.** `resolvePageAccess`
  is the one function; `visibleMenuProvider`, the badge and the route gate
  call it, and `effectiveAllowedPages` is the one composition of the two
  levels, called only at session resolution. The first divergent copy is a
  hidden page that opens or a visible page that locks.
* **No new synchronous readers of `RouteRegistry.menuItems`**, and no
  second writer to it (§5b's mirror rule, source-tested).
* **The page editor never consumes `visibleMenu`** (§5b's table) — the
  `configure` surface sees the whole tree, always.
* **No session persistence of the resolved whitelist** (§1d).
* **No format pass, no golden regeneration beyond the failing set** — the
  standing repo traps apply (spec §10).

## 10. Implementation plan

Ordered; each step leaves the tree green. Codegen: drift classes generate
beside `@DriftDatabase`, so the `tfc_dart` build_runner run regenerates
`$AppRoleTable`/`AppRoleData`/`$AppUserTable`/`AppUserData`; run `dart run
build_runner build --delete-conflicting-outputs` in `packages/tfc_dart`
first, then at the root (the new providers in `lib/providers/menu.dart` are
riverpod-generated, so the root run is required, not belt-and-braces).
`packages/tfc_access` is pure Dart — remember CI's setup-dart lanes run a
newer stable than Flutter's Dart.

1. **`packages/tfc_access`** — the shared codec
   (`encodeAllowedPages`/`decodeAllowedPages`), `effectiveAllowedPages`,
   `AccessRole.allowedPages` (+equality), `AccessSession.allowedPages` +
   `pageVisible` + the `anonymous` factory parameter;
   `AuditRecord.rolePages` and `AuditRecord.userPages`. Tests beside each,
   including the §1c truth table and the codec forgiveness table.
2. **`packages/tfc_dart`** — both `allowedPages` columns; the v7 migration
   arm (both backends) and both v6 `CREATE TABLE` literals;
   `AccessRepository`: `_toRole`, `upsertRole`'s insert arm,
   `setRoleAllowedPages`, `setUserAllowedPages`, `anonymousRole()`, **the
   `renameRole` copy**. Then build_runner in `tfc_dart`. Tests: migration
   v6→v7 on SQLite (both tables, NULL carry-over); repository round-trips;
   rename-preserves-whitelist; `setRole`-preserves-override;
   `access_schema_test` parity for both columns.
3. **`lib/core/access_admin_store.dart`** — `setRolePages` and
   `setUserPages` (ninth and tenth writes), class-doc update.
   `access_admin_store_test`: the allowed/denied/ordering trio for each new
   write, plus updating whatever count assertions enumerate the writes.
4. **`lib/providers/access.dart`** — session resolution composes
   `effectiveAllowedPages` at every site groups are resolved:
   `_restoreOrFloor` (fetch the user row beside the role), the anonymous
   floor (via `anonymousRole()`), `signIn`, the panel-account resume,
   `refreshGroupsFromRoles`. An unreadable user row composes as inherit.
   No change to `access_policy.dart`.
5. **`lib/widgets/page_access_gate.dart`** (new) — `resolvePageAccess`, the
   not-available strings and keys, `PageAccessGate`. Truth-table test for
   the pure function; widget tests for allowed/denied/waiting/boot-window.
6. **`lib/providers/menu.dart`** (new) — `menuTreeProvider` (composition
   moved from `main.dart:334-354`, ordering via `sortTopLevel`,
   `RouteRegistry.resetRouteGroups()` on rebuild, singleton mirror write),
   `visibleMenuProvider` + `VisibleMenu` (`topLevel`, `indexOfPath`,
   `showsBar`). `RouteRegistry` gains `resetRouteGroups`. Tests:
   filter-preserves-order, section collapse, indexOfPath, showsBar,
   unraise-on-redeclare, single-writer source test for `menuItems`.
7. **`lib/widgets/base_scaffold.dart`** — the `NavigationBar` renders from
   `visibleMenu.topLevel`; `selectedIndex` via `indexOfPath`; the tap
   handler indexes the same list; no bar when `!showsBar`;
   `isTopLevelDestinationPath` and the sign-out return read `menuTree`.
   Widget tests for index mapping, the bar-less state, and sign-in
   changing the bar without a restart — the amendment's acceptance test.
8. **`lib/widgets/nav_dropdown.dart`** — receives pre-filtered items;
   `_lockedPaths`, `_collectLockedPaths` and the hiding branch in
   `buildFlatMenu` are deleted. `lib/widgets/access_lock_badge.dart`'s
   `accessRouteLocked` remains for the badge's own question, now asking
   `resolvePageAccess`.
9. **`centroid-hmi/lib/main.dart`** — `addRoute` wraps in `PageAccessGate`;
   the wildcard fallback route; the boot composition delegates to the same
   function `menuTreeProvider` uses (one composition, two callers) and
   the `main.dart:307` comment is updated to describe the new pipeline.
   Update `centroid-hmi/test/navigation_test.dart`: "a page-manager page
   is not a gate" flips to asserting the gate *and* the open-by-default
   behaviour that sentence protected; new tests for the wildcard route's
   three outcomes.
10. **`lib/widgets/access_pages_editor.dart`** (new) + the two mounts in
    `access_roles_section.dart` and `access_users_section.dart`, the
    Operator banner extension, the narrowing confirmation, the override
    tag, Save wiring. Widget tests + goldens (both mounts, both modes,
    light and dark), PNGs read by hand.
11. **Docs** — a pointer from `access-control-spec.md` §7's table (routes
    row) to this note, and the deployment doc gains the recovery sentence:
    a whitelist mistake is repaired from `/advanced/access` by any `users`
    holder, or in extremis `psql`: `UPDATE app_role SET allowed_pages =
    NULL` / `UPDATE app_user SET allowed_pages = NULL`.

## 11. Test plan

**Will break, and how they resolve:**

* `centroid-hmi/test/navigation_test.dart` — the two assertions that
  page-manager routes carry no gate; replaced per step 9. Tests that build
  the menu once and read the singleton may need the provider harness.
* `test/core/access_admin_store_test.dart` (and its source-grep
  companions) — write-list enumerations gain `role.pages` and
  `user.pages`.
* `packages/tfc_access/test/access_role_test.dart` /
  `access_session_test.dart` — equality/serialisation fixtures gain the
  field; the `toJson` tests *assert its absence*.
* `packages/tfc_dart/test/.../access_schema_test.dart` — column parity for
  `allowed_pages` on both tables, in both DDL forms.
* `test/widgets/` scaffold and nav tests that seed `RouteRegistry().
  menuItems` directly — they migrate to seeding through the provider
  overrides (or the mirror, which the provider now owns).
* Any roles/users-section golden that shows an open editor re-baselines
  (derive the failing set; never regenerate wholesale).
* `guard_wiring_test.dart` — must **not** break; if it does, §9 was
  violated and the change, not the test, is wrong.

**New:** the codec forgiveness table (null / garbage / wrong type / unknown
entries); the `effectiveAllowedPages` truth table (§1c, all six rows); the
`resolvePageAccess` truth table (every row of §3, including
repository-error and loading states); migration v6→v7 with seeded roles
and carried-over users asserting NULL at both levels;
rename-preserves-whitelist; `setRole`-preserves-override; store trios for
`role.pages` and `user.pages`; session tests: restore composes user-over-
role, an unreadable user row composes as inherit, a hand-written session
payload cannot carry a whitelist, `refreshGroupsFromRoles` picks up both a
role edit and an override edit; gate widget tests incl. deep-link refusal
of a `requiredGroup` page (hole 1, pinned so it stays closed); the menu
pipeline tests of step 6 plus: sign-in changes the bar live (hole 2's
acceptance), a page arriving via `pageManagerProvider` appears in the menu
and routes through the wildcard without a restart, destinations /
selectedIndex / tap all agree on one filtered list, `< 2` renders no bar,
filtering preserves `page_editor_top_level_order`; the page editor still
sees the full tree under a filtered session; startup-path-denied renders
the body inside a full scaffold; `AccessPagesEditor` tests
(save/stale-chip/tri-state/mode semantics per mount) and goldens for both
mounts, both modes, both themes, plus the not-available page body.

## 12. Smallest viable first cut

Both amendments are in scope — the per-user level ships with the role
level (the two share the schema bump, the codec, the composition function
and the editor widget, so splitting them saves almost nothing), and the
menu pipeline ships with the enforcement (a live-filtering bar over a
boot-frozen route table would show entries the router cannot serve).
Within that, the first cut trims:

* **Tri-state section checkboxes** — v1 renders a flat leaf list grouped
  under plain section headings; sugar, not semantics.
* **The "(draft)" annotation** in the picker — v1 lists published pages
  only.
* **The session-aware startup fallback** (§5c) — the lock body is correct;
  landing somewhere nicer is polish.
* **The `clearBeamingHistoryOn` staleness fix** for pages created after
  boot — cosmetic back-arrow residue, named in §5a, acceptable.
* The deployment-doc paragraph may trail the PR.

That cut is still the whole feature: both whitelist levels, block-all-then-
whitelist, override composition, a session-derived navigation bar, all
three enforcement points, restart-free page changes, audited edits, no
lockout.

**Deferred, deliberately** (recorded so they are not silently forgotten):

* MCP tools (`set_role_pages` / `set_user_pages` / listers) for
  agent-driven bulk setup, following the access-template tools'
  proposal-and-approve pattern, gated on `users` like their siblings.
* ~~Whitelisting the open built-ins (Alarm View, History View).~~ Resolved
  2026-09-12 by §13, and not by generalisation: the menu filter was already
  hiding them, so the deferral was describing a state the code did not have.
* Rename-follow: prompting a page-path rename in the editor to update
  whitelists. Blocked on a real design problem — the editor runs under
  `configure` and must not write `app_role`/`app_user` (§1a); a correct
  version routes through a `users`-gated confirmation, which is a
  workflow, not a patch.
* Cross-station live refresh of an already-resolved session's whitelist
  (needs a change feed on `app_role`/`app_user` that deliberately does not
  exist).
* Deleting `RouteRegistry.menuItems` outright once the page editor
  migrates to `menuTreeProvider` — the mirror is a bridge, and the
  single-writer test is what keeps it a bridge instead of a habit.

---

## 13. Amendment, 2026-09-12: the built-ins are whitelistable, the access screen is not

**The report:** *"when I whitelist pages for users to get access to I cannot
pick any advanced pages."*

**What was actually wrong is worse than the report.** §3 row one and §4 layer
one both said the built-ins answer to groups alone and that no whitelist could
touch them. The Pages editor implemented that by listing page-manager pages
only. Nothing else did. `visibleMenuProvider` filters the **whole** tree
through `resolvePageAccess`, built-ins included, so the scope line was never
true of the running app:

> Setting any whitelist on a role — even one that grants pages — dropped
> every built-in from that session's menu: Alarm View, Reports, History View,
> and the entire Advanced section including Access. The picker then offered no
> way to grant any of them back.

That is not the reported inconvenience, it is a silent lockout of the repair
screen, reachable in two clicks from the Access page. Reproduced as a unit
test before anything was changed (`menu_test.dart`, "no whitelist can hide the
access screen").

**Two ways to make the code and the note agree, and why this one.** Excluding
the built-ins from the filter would have restored the note verbatim — and left
"block all" unable to block the Advanced menu, which is most of what an
operator can reach. The station asking for the feature is asking to narrow
what a panel shows; a whitelist that cannot hide Reports or the Page Editor
entry is not the control that was requested. So the scope widens instead, to
what the filter already did, minus the one route that must never be hidden.

**What changes:**

* `routeExemptFromPageWhitelist(path)` — true for `/advanced/access` and
  nothing else. `resolvePageAccess` consults it after the group gate and
  before the whitelist, so the menu filter and the route gate get the
  guarantee from one function rather than two copies of a comment. §4 layer 1
  is now enforced rather than asserted.
* The Pages editor lists `menuTreeProvider` — every page and every built-in —
  with sections as headings rather than tick boxes, and the group a raised
  route still needs printed beside its path, because the whitelist narrows and
  never grants.
* Alarm View becomes explicitly hideable, which the deferred list above had
  wanted argued rather than generalised. The argument is short: it was already
  hideable, by accident, with no way to grant it back. An explicit reversible
  checkbox is the safer of the two states, not the riskier one.

**What deliberately does not change.** The built-in routes are still gated by
`AccessGate`, which takes a literal group and knows nothing about paths — so
for them the whitelist remains a menu-level control, exactly as it was before
this amendment. Making `AccessGate` resolve a path would give it a lookup to
fail open through, which its doc comment rules out. A built-in withheld by a
whitelist is therefore hidden, not refused, and its group gate is what
actually shuts it.
