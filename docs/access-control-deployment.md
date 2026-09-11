# Access control — deployment

For whoever commissions a station. It covers the one thing in this design that
is a deployment step rather than app code: locking down the audit table on
Postgres. It also states, plainly, what that lockdown does and does not buy.

The design itself is `docs/access-control-spec.md`. This document does not
amend it.

---

## 1. What this protects against, and what it does not

The access control in this HMI is not an access control. It is an
**operational guardrail**.

Three credentials are held by the station, not by a person:

| Credential | Where it lives | What it authenticates |
|---|---|---|
| The OPC UA session username/certificate | `OpcUAConfig`, `state_man.dart` | the station |
| The Postgres password | `DatabaseConfig.postgres`, `database.dart` (`CENTROID_PGUSER` / `CENTROID_PGPASSWORD`, or the `database_config` entry in secure storage) | the station |
| The D-Bus credential behind system settings | the platform integration | the station |

Every one of them authenticates the *station*, never a person. Everything the
login screen, the role model and the audit trail do happens inside the Dart
process, and anyone with UaExpert or `psql` walks around all of it. A username
and password in this HMI tell you who was standing at the panel; they do not
stop anybody who is not standing at the panel.

That is acceptable, because the realistic failure in a plant is accident and
shift confusion, not a malicious insider. It stops being true — in the good
direction — when relay Phase 10 moves preferences onto the pipe and takes
credentials off the client.

**Say this out loud when you hand a station over.** The danger is not the
guardrail. The danger is somebody hearing "the HMI has logins" and
deprioritising network segmentation on the strength of it. The segmentation is
the control. This is the guardrail inside it.

---

## 2. The INSERT-only audit role (Postgres)

The audit trail is append-only and never pruned. The application enforces that
on its own side — the writer has one method and no way to remove a row, and the
collector's retention machinery refuses `audit_entry` by name
(`kRetentionExemptTables`, `packages/tfc_dart/lib/core/database.dart`). None of
that binds a `psql` session using the station's own credential.

What the database can enforce is a split: the station may **add** to the trail
and may not **remove from** it.

### When to run this

After the station has opened the database at least once, so schema v6 has
created `audit_entry` and its three indexes. The migration needs table
ownership to create indexes; step 4 below takes ownership away. Running these
statements before the first open leaves the migration unable to finish.

Run as a superuser or as the database owner.

### The SQL

```sql
-- 0. Names used below. Replace `hmi_station` with the role in the station's
--    CENTROID_PGUSER / database_config; the other two are created here.
--      hmi_station      -- what the HMI connects as
--      hmi_audit_writer -- may append to the trail, nothing else
--      hmi_audit_owner  -- owns the trail so hmi_station cannot re-grant itself

-- 1. A login-less owner for the audit table. Nobody connects as this role;
--    it exists so that the table's owner is not the station.
CREATE ROLE hmi_audit_owner NOLOGIN;

-- 2. A login-less role carrying only the trail privileges granted below.
CREATE ROLE hmi_audit_writer NOLOGIN;

-- 3. Take ownership away from the station.
--    This step is the one that makes the rest real. In Postgres a table's
--    owner keeps full rights no matter what you REVOKE, and can simply
--    GRANT them back to itself. If audit_entry is still owned by
--    hmi_station, steps 5 to 7 are decoration.
ALTER TABLE audit_entry OWNER TO hmi_audit_owner;
--    The `id SERIAL` sequence is owned by the column, so the line above
--    already moved it. Stated explicitly anyway, because it costs nothing and
--    a sequence left behind is an INSERT that fails on a live station.
ALTER SEQUENCE audit_entry_id_seq OWNER TO hmi_audit_owner;

-- 4. Strip whatever the station had.
REVOKE ALL ON TABLE audit_entry FROM hmi_station;
REVOKE ALL ON SEQUENCE audit_entry_id_seq FROM hmi_station;

-- 5. Grant the writer role its append privilege — and the sequence rights that
--    an `id SERIAL` column needs. This is the step that gets forgotten:
--    without the sequence grant every INSERT fails with
--    "permission denied for sequence audit_entry_id_seq", and because the
--    sink swallows its failures the only sign is an AUDIT ROW LOST line in
--    the log.
GRANT INSERT ON TABLE audit_entry TO hmi_audit_writer;
GRANT USAGE, SELECT ON SEQUENCE audit_entry_id_seq TO hmi_audit_writer;

-- 6. And the read the trail viewer needs. `/advanced/audit-trail` reads
--    audit_entry over the station's own connection, so without this the
--    viewer cannot read the trail at all.
GRANT SELECT ON TABLE audit_entry TO hmi_audit_writer;

-- 7. Let the station act with the writer role's privileges and no others.
--    This relies on hmi_station having INHERIT, which is the default. If it
--    was created NOINHERIT the station gets nothing here and every audit
--    INSERT fails: `ALTER ROLE hmi_station INHERIT;`
GRANT hmi_audit_writer TO hmi_station;
```

### Verifying it

```sql
-- Should list exactly: hmi_audit_writer=ar/hmi_audit_owner (a = INSERT,
-- r = SELECT), plus the owner's own entry. No `d` (DELETE) or `w` (UPDATE)
-- for hmi_station.
SELECT relname, relacl FROM pg_class WHERE relname = 'audit_entry';

-- Should fail. If it succeeds, step 3 did not happen.
SET ROLE hmi_station;
DELETE FROM audit_entry WHERE id = (SELECT min(id) FROM audit_entry);
RESET ROLE;
```

### What the station can and cannot do afterwards

- **Can** insert a row, including a row that says something untrue. The trail
  can be *forged* by anything holding the station's credential.
- **Can** read the trail, which is what the viewer at `/advanced/audit-trail`
  does. `SELECT` does not weaken the property this section is about — reading
  a row cannot remove it — but it does mean the trail is readable by anything
  holding the station's credential, which was already true of the whole
  database.
- **Cannot** delete a row, update a row, or `TRUNCATE` the table. What is in
  the trail stays in the trail.

That is the whole of the guarantee, and it is worth stating in exactly those
terms: a doc that promises more than this is worse than no doc, because the
next person to weigh network segmentation will weigh it against the promise.

---

## 3. SQLite (dev and demo) has neither separation

On SQLite there is no second role and nothing to revoke. The process owns the
file; anything that can open the file can rewrite it, and `sqlite3` on the
station's disk is all it takes.

**So on SQLite the audit trail is append-only by convention only.** The
in-process guarantees still hold — the sink cannot remove a row and retention
cannot sweep the table — and that is the whole of it. Nothing in section 2
applies. Do not read the existence of this document as meaning the guarantee
travels with the app.

SQLite is the development and demo backend. A commissioned station runs
Postgres, and section 2 is a commissioning step, not an optional hardening
pass.

---

## 4. Break-glass recovery — and how not to need it

### The commissioning order

Roles are seeded; users are not. So a station that has just opened its
database has four roles and nobody who can sign in, and the order below is the
whole of getting from there to a site that runs.

1. **The four roles arrive with schema v6 and need no action.** `Operator`,
   `Shift Leader`, `Maintenance` and `Engineering` are written by the
   migration and are ordinary rows afterwards. Read them and re-tick them to
   suit the site — noting that out of the box **only `Engineering` grants
   `users`**, which is the group carrying the roles and users screen itself.
2. **Create the first account.** The page at `/access/first-user` creates one
   only while `app_user` is empty, and forces it to `Engineering`; a caller
   cannot ask for anything else. That is why there is no default password on a
   fresh station and no bootstrap flag left switched on.
3. **Sign in as it and create the rest from `/advanced/access`.** This step is
   where a site decides how many people hold `users`. Make it more than one,
   for the reason the next sub-section gives.
4. **The first-user window is now closed, and stays closed.** With `app_user`
   non-empty that page creates nothing, and every later account is made from
   `/advanced/access` by somebody holding `users`.

Between the first open and that first account the station is claimable by
whoever reaches it first, so do steps 1 to 3 in one sitting, with somebody
standing at the panel.

### One account holding `users` is one too few

The application refuses any write that would leave no account holding a role
that grants `users`, and names the accounts still holding it when it refuses.
Four routes trip it, and two of them never touch the users list at all:

- deleting the last account whose role grants `users`
- moving that account onto a role that does not grant it
- unticking `users` from the only role that grants it
- deleting that role

There is no override in the interface, deliberately — no typed confirmation,
no "I know what I am doing". An override is a permanent hole kept open for a
rare day, which is the same argument that keeps the rest of this section
documented rather than built.

So the number of holders is a site's decision rather than the app's. Keep
exactly one and everything below is the recovery for an ordinary event:
somebody leaves, somebody forgets a password, and the fix is `psql` against a
running plant. Keep two and it stays the recovery for a rare one.

### When it happens anyway

**The scenario.** The only Engineering account's password is lost, or the
person holding it has left. Nobody can reach the screens behind the `users`
group — the roles and users screen at `/advanced/access`, where accounts are
made, and the audit trail. The first-account page is not one of them: it is
ungated by design, registered unconditionally, because gating that route on a
database read would 404 the address while the connection was still coming up.
It sits behind no group at all — it is offered only while `app_user` is empty,
which on a commissioned station it is not.

**Break-glass is documented, not built.** There is no recovery code, no
bootstrap flag and no default password — each of those is a permanent hole
kept open for a rare day. Engineering already holds the station's Postgres
credential, so the recovery is deleting a row, not reflashing a station. That
is a direct consequence of this being a guardrail rather than a security
boundary: the people who would have to be stopped by a real recovery mechanism
are the same people who hold the credential that defeats it.

**Recovering one account:**

```sql
DELETE FROM app_user WHERE username = 'the.locked.out.account';
```

Then re-create it from another account whose role grants `users`.

**Recovering when no account can get in.** Empty the table:

```sql
DELETE FROM app_user;
```

This reopens the **first-user window**: creating a user is permitted only while
`app_user` is empty, so the next person to open the app creates a fresh
Engineering account and the door closes behind them again. That is the
supported way back in, and it is the same path a freshly commissioned station
takes.

Between the `DELETE` and that first new account the station is claimable by
whoever reaches it first. Do it when somebody is standing at the panel.

**The audit consequence, stated rather than hidden.** Neither `DELETE` is
audited. They happen in `psql`, outside the application, and the application is
the only thing that writes the trail. So a break-glass leaves `app_user` empty
with no row saying who emptied it or why — the audit trail will show the new
account's first login and nothing before it.

This is not a defect to fix. It is the same fact as section 1: anyone with
`psql` is outside everything this design can see. Record the break-glass in
whatever the site uses for change control, because the HMI cannot.

### Repairing a page whitelist

A role or an account can be restricted to a list of pages
([page-visibility-whitelist-design.md](page-visibility-whitelist-design.md)),
including a list naming nothing. A whitelist set too tight is **not** a
lockout and needs no break-glass: it cannot take away the screen that repairs
it. Two independent reasons, and both are enforced rather than remembered:

* The Advanced routes — the access screen among them — answer to groups alone
  and are not whitelistable. No whitelist state can hide `/advanced/access`
  beyond the `users` gate it already has, and the last-`users`-holder
  invariant guarantees somebody still holds that group.
* Signing in is not a page. The app bar carries the sign-in control on every
  screen, and the refusal page a hidden page shows carries one of its own — so
  a panel whitelisted down to nothing is still a panel somebody can sign in at.

So the repair is the ordinary one: open Advanced → Access as any `users`
holder and change the Pages block. If the station is genuinely unreachable for
an unrelated reason, the `psql` equivalent is one statement per level, and
`NULL` is the "no whitelist" value:

```sql
UPDATE app_role SET allowed_pages = NULL WHERE name = 'Operator';
UPDATE app_user SET allowed_pages = NULL WHERE username = 'lina';
```

`NULL` and `'[]'` are **not** the same. `NULL` removes the whitelist; `'[]'`
is a whitelist naming nothing, which hides every page. Writing `'[]'` here by
reflex is the one way to make this worse rather than better. The same audit
consequence as above applies: a change made in `psql` leaves no row.

### The database-outage rule, and the cost it accepts

Route gating raises nine routes above `operate` — Phase 2's six, plus
`/advanced/knowledge-base`, which plan 03-14 raised to `configure` once the
write-path sweep found three write surfaces behind it, plus the two `users`
routes: `/advanced/audit-trail` and `/advanced/access`. One of the nine behaves
differently while the database is down, and a deployer has to know it in both
directions — it is invisible until the day it matters.

> Whenever this station has no usable access repository — never configured, or
> configured and unreachable — `/advanced/server-config` opens without a
> sign-in. The other eight raised routes stay locked in both cases. The reason
> is that with no repository no sign-in can succeed, so denying Server Config
> would turn a mistyped Postgres IP into an on-site recovery.
>
> The accepted cost: while the database is unreachable, anyone standing at the
> panel can reach Server Config, repoint the station at a Postgres they control
> holding a known Engineering account, and sign in. That requires physical
> access to the panel plus a prepared server — and physical access already
> defeats this milestone by design, since anyone with UaExpert or `psql` walks
> around every guard in it. Bricking a plant's station over a typo is the
> likelier and worse failure, so this is the trade that was chosen.

The two causes are deliberately not distinguished anywhere in the code:
`lib/providers/database.dart` catches a failed connection, schedules a retry
and returns `null`, which is the same resolved value as "no Postgres
configured". A station still connecting (`AsyncLoading`) is neither — it
waits, and never opens.

---

## 5. What must not be changed

**The `Operator` role cannot be deleted or renamed.** This is enforced in code
(`isProtectedRoleName` / `ProtectedRoleError` in `packages/tfc_access`), and
the guard is case-insensitive and whitespace-trimmed, so `operator` and
`" Operator "` are refused too.

**Editing `Operator`'s groups is not a small edit.** Anonymous resolves to
`Operator`, so its group set is what every logged-out panel on the floor may
do. Widening it hands those permissions to anybody walking past a panel;
narrowing it can lock out routine operation everywhere at once, with no
logged-in user anywhere to notice the change was deliberate. Change it with the
same care as a PLC download, and note the change in change control.

**The audit table's schema.** `audit_entry`'s columns are the audit contract
(`AuditRecord` in `packages/tfc_access`) one for one. Adding a column is a
migration; dropping or repurposing one silently changes what historic rows
mean.

**`kRetentionExemptTables`.** Removing `audit_entry` from it puts the trail
back within reach of the collector's retention sweeping. It is refused there so
that naming a collected key `audit_entry` — a free string in the collector
config — cannot reach the trail by accident.

**No admin screen may offer a delete, a prune or an export path over
`audit_entry`.** Delete and prune are the obvious half: the trail is worth
having only because it is append-only, section 2's Postgres role is what
enforces that at the database, and on SQLite nothing enforces it at all — so on
the demo backend the only thing between the trail and a "clear old entries"
button is that nobody has written one. Export is on the list because it is the
half of "export it first, then clear it" that sounds responsible. Today the
property is written down in two places the person adding that button will never
open: `DriftAuditSink` has exactly one method, and `drift_audit_sink_test.dart`
reads the sink's own source to assert that no second one has appeared — the
same shape as `kRetentionExemptTables` above, which refuses the table by name
rather than trusting the sweep to skip it. This paragraph is the version of
that decision a screen author can find.
