/// The routes raised above `operate`, declared once.
///
/// Every other route in the app declares nothing and therefore answers
/// [AccessGroup.operate] — what an anonymous session already holds — so this
/// map is the entire blast radius of route gating. Nine entries are raised:
/// seven because they configure the station rather than run the line, and two
/// — the audit trail and the access administration screen — because of the
/// data they put on the screen. Nothing on the floor changes, with one
/// exception, Knowledge Base, which is spelled out below because it does take
/// something away from an operator.
///
/// **The nine, and why each one.**
///
/// * Page Editor, Alarm Editor, Report Editor and Key Repository need
///   `configure`: they author what the station shows, how it alarms and what
///   it reports, and the key repository surfaces stored secrets
///   (`centroid-hmi/lib/navigation.dart:48-50` says so in as many words).
/// * Knowledge Base needs `configure` too, for the reason below — it is not
///   the read surface its menu label suggests.
/// * Server Config, IP Settings and Preferences need `administer`: they point
///   the station at a database, a PLC and a network.
/// * The audit trail needs `users`, and it is the first entry here raised for
///   what it *shows* rather than for what it writes. The paragraph below says
///   why.
/// * The access administration screen needs `users` too, and it is the entry
///   where both halves of the argument point the same way: it *reads* the
///   account list and every role's group set, and it *writes* both. The
///   paragraph below says why the read half is the one that matters here.
///
/// **`/advanced/preferences` is a deliberate amendment to the spec's five**,
/// decided by the user on 2026-08-29 after plan review;
/// `docs/access-control-spec.md` §9 still says five and is out of date on
/// this point. `lib/pages/preferences.dart` renders `DatabaseConfigWidget` —
/// the same database configuration Server Config edits, whose Save calls
/// `ref.invalidate(databaseProvider)` — and `PreferencesKeysWidget`, a raw
/// list/edit/delete editor over every preference key (`page.*`, `alarm.*`,
/// `keymap.*`, server/db/network), which is the data behind all three
/// `configure` routes. Gating only the spec's five would leave a one-tap
/// bypass: refused at Server Config, open Preferences one menu entry down and
/// edit the identical data. It takes `administer` because that is what the
/// data it reaches is worth, not because of where it sits in the menu.
///
/// **Knowledge Base is raised because it is not the read surface it looks
/// like.** `docs/access-control-write-path-sweep.md` §3.1 found three raw-Drift
/// index classes reachable from it — twenty-six Drift statements — and one of
/// its callers rewrites `page_editor_data`, which is the key the
/// `configure`-gated page editor saves. A page that can rewrite the page
/// layout is a `configure` surface whatever its menu label says. Plan 03-13
/// guards the controls behind it; this gates the route. Both are needed: the
/// route gate alone would leave those controls unaudited for anyone who does
/// hold `configure`, and the control guards alone would leave a page reaching
/// three write surfaces open to a session holding nothing.
///
/// **The cost, accepted deliberately.** An anonymous operator can no longer
/// read technical documents or browse PLC code at the panel. On a plant floor
/// that is a real loss: somebody wanting a manual at the machine now has to
/// find a person with a `configure` account, or walk. It was chosen over
/// leaving a write path around the page-editor gate, and it is the one place
/// in this milestone where gating a route takes something away from an
/// operator rather than only from a configurer. `docs/access-control-spec.md`
/// §11 defers read permissions on trends and history; this is not that, and
/// the difference is that this page writes.
///
/// **What is not lost.** The drawings overlay on ordinary pages
/// (`centroid-hmi/lib/main.dart:763-781`) is a different surface: not this
/// route, read-only, and plan 03-13's decorators pass reads straight through.
/// A drawing is still available on the page an operator is standing at.
///
/// **The `kKnowledgeEnabled` interaction.** `lib/core/feature_flags.dart:32`
/// defaults the flag to true, so the test suite and every development build
/// have this route. A `--dart-define=CENTROIDX_KNOWLEDGE=false` build has neither
/// the route (`centroid-hmi/lib/main.dart`'s statement-level `if`) nor the
/// menu entry (`centroid-hmi/lib/navigation.dart:68`), and
/// [installRaisedRoutes] then declares a group nothing resolves — inert
/// rather than wrong. The map is deliberately **not** made conditional on the
/// flag. It could be: the map is `const` and the flag is a compile-time
/// constant. It would mean a flag-off build with a different [kRaisedRoutes],
/// a different length assertion and a different menu, for no gain. An inert
/// declaration is cheaper than a conditional invariant.
///
/// **[kServerConfigRoute] is the only route exempt while the access
/// repository is unavailable**, and it is exempt in *both* causes of that: a
/// station never configured, and a configured station whose Postgres will not
/// answer. `lib/providers/database.dart:33-42` cannot tell those apart — a
/// failed connection is caught, retried in 2s and returned as `null`, a
/// resolved `AsyncData(null)` indistinguishable from "no Postgres
/// configured". The argument is exactly "you must be able to reach the page
/// that configures the database", and the unreachable case is where it bites
/// hardest: someone mistypes the Postgres IP, saves, and without the
/// exemption the station is recoverable only on site. It extends to nothing
/// else — not to Preferences, which reaches the same widget but also
/// everything else, and not to the editors, which store secrets. The accepted
/// cost is stated rather than hidden: an unreachable database leaves Server
/// Config reachable by anyone at the panel, who could repoint the station at a
/// Postgres they control. That needs physical access plus a prepared server,
/// and physical access already defeats this milestone by design
/// (spec §8) — while bricking a plant's station over a typo is both likelier
/// and worse.
///
/// **IP Settings is on this list at the route level only.** The D-Bus call
/// underneath it is deliberately untouched (spec §6 bypass 3), and
/// `lib/pages/dbus_login.dart` is out of scope for the whole milestone. The
/// D-Bus credential authenticates the *station* to the system bus;
/// `administer` is the human gate above it.
///
/// **The audit trail is `users` because the data is `users`-grade.** It is the
/// first entry on this list that writes nothing at all —
/// `lib/core/audit_trail_store.dart` takes no session and holds no sink, and
/// its reads are deliberately ungated because a guarded read would put a row in
/// the trail every time somebody scrolled the trail. That makes this map the
/// whole of the enforcement, and the group is chosen from what the page
/// displays: every setpoint change anybody ever made, with its old and new
/// values, its author and its station, alongside the denials that show where a
/// role is configured too tightly. Lowering it to `configure` would hand that
/// history to anyone who can edit a page or import a key map, so it sits at the
/// authorization model's own gate. The word is named once, in the store's
/// [kAuditTrailGroup]; the entry below spells it, and
/// `test/access_routes_test.dart` asserts the two agree.
///
/// **The admin screen is `users` because its reads are ungated on purpose.**
/// `lib/core/access_admin_store.dart` gates every *write* it offers, and
/// refuses and audits a caller who does not hold [kAccessAdminGroup]. Its
/// reads take no such gate, deliberately: a guarded read would put a row in
/// the trail every time somebody opened the roles list, burying the writes
/// that are the reason the trail exists. That makes the entry below the whole
/// of the enforcement for *reading* the screen, and what it reads is the
/// account list — username, role, created, last login — beside the group set
/// of every role on the station, which is the map of who may do what. A typo
/// in the path here is that page, open to an anonymous panel. The word is
/// named once, in the store's [kAccessAdminGroup]; the entry below spells it,
/// and `test/access_routes_test.dart` asserts the two agree.
///
/// **What stays open, on purpose.** About Linux, Alarm View and History View
/// read rather than configure. The audit trail and the admin screen also read
/// and are raised anyway, which is not an inconsistency but this doc's own
/// standard applied twice: a route is judged by what its call sites reach, not
/// by the label on its menu entry. Those three reach system information and
/// plant telemetry; the audit trail reaches the record of every write on the
/// station, and the admin screen reaches the accounts and the roles. The
/// first-account route stays open because gating it is the deadlock the whole
/// design exists to avoid.
///
/// Knowledge Base used to be on that list and is not any more; so was
/// History View, whose destructive Drift deletes plan 03-10 closes at the
/// controls. Both were listed as read surfaces for the same reason — the
/// menu label was read instead of the call sites — and both were wrong. A
/// page named for what an operator does on it is not evidence about what it
/// writes.
///
/// **The `addRoute` edge.** `centroid-hmi/lib/main.dart:588-604` runs after
/// the literal route map and assigns `routes[menuItem.path!]`, so it
/// overwrites by path: a page-manager page slugged to `/advanced/server-config`
/// would replace the gated route with an ungated `AssetView`. No privilege is
/// gained — what you reach is your own asset page, not `ServerConfigPage` —
/// but the menu badge would show a lock on a page that has none. Worth
/// knowing rather than rediscovering.
///
/// **Why the strings are duplicated.** They are copied from
/// `centroid-hmi/lib/main.dart` rather than imported from it, because `lib/`
/// cannot depend on the app package. Tests in
/// `centroid-hmi/test/navigation_test.dart` are what keep the two spellings
/// honest, by building each route and asserting the group it resolved.
library;

import 'package:tfc_access/tfc_access.dart';

import 'models/menu_item.dart';
import 'route_registry.dart';

/// The Server Config route — the one exemption while the access repository is
/// unavailable. See [routeAllowedWhenRepositoryUnavailable].
const String kServerConfigRoute = '/advanced/server-config';

/// The audit trail route — the only `users` entry, and deliberately **not**
/// exempt while the access repository is unavailable: the trail is the
/// database, so a trail readable while the database is down would be a
/// promise nothing could keep.
///
/// Named as a constant because two tests spell it and one of them asserts it
/// equals `kAuditTrailGroup` in `lib/core/audit_trail_store.dart`.
const String kAuditTrailRoute = '/advanced/audit-trail';

/// The access administration route — the second `users` entry, and
/// deliberately **not** exempt while the access repository is unavailable.
///
/// This is the page where an exemption would be worst, not merely
/// inconsistent: with no repository there is no role table and no account
/// list, so an exempt admin page would edit nothing while looking like it
/// worked. See [routeAllowedWhenRepositoryUnavailable].
///
/// Named as a constant because two tests spell it and one of them asserts it
/// equals `kAccessAdminGroup` in `lib/core/access_admin_store.dart`.
const String kAccessAdminRoute = '/advanced/access';

/// The report editor route — `configure`, for the same reason the alarm
/// editor is: it authors what the station reports on, and a report definition
/// is station configuration somebody wrote.
///
/// The Reports *viewer* is deliberately absent from [kRaisedRoutes]. Reading
/// last night's shift is operate-level work — the same ruling
/// `guarded_history_views.dart` records for history, and for the same reason.
/// What the viewer may reach is bounded instead at the control: a report's SQL
/// section cannot name the access tables (`ReportEngine.validateSqlQuery`),
/// so authoring a report cannot become a way to read them.
const String kReportEditorRoute = '/advanced/report-editor';

/// The ten routes raised above `operate`, and the group each one needs.
///
/// One const map so that the route table and the navigation menu can never
/// disagree about which entries are locked. Paths are spelled exactly as in
/// `createLocationBuilder`'s `routes` map in `centroid-hmi/lib/main.dart`; a
/// typo here is a route that silently stays open.
const Map<String, AccessGroup> kRaisedRoutes = {
  '/advanced/page-editor': AccessGroup.configure,
  '/advanced/alarm-editor': AccessGroup.configure,
  '/advanced/key-repository': AccessGroup.configure,
  '/advanced/knowledge-base': AccessGroup.configure,
  kReportEditorRoute: AccessGroup.configure,
  kServerConfigRoute: AccessGroup.administer,
  '/advanced/ip-settings': AccessGroup.administer,
  '/advanced/preferences': AccessGroup.administer,
  kAuditTrailRoute: AccessGroup.users,
  kAccessAdminRoute: AccessGroup.users,
};

/// Whether [path] stays reachable while the access repository is unavailable.
///
/// True for [kServerConfigRoute] and nothing else — not for the other raised
/// routes, not for an unraised path, and not for null. Both the route gate
/// and the menu badge call this rather than each keeping a copy of "except
/// Server Config"; two copies is a lock on a page that opens, or an open page
/// wearing a lock, the first time one of them is edited.
///
/// The name states the condition it actually enforces. It was
/// `routeAllowedWhenUnconfigured` for one revision, back when the exemption
/// was narrower than the outage it now covers; a name that claims a narrower
/// condition than the code enforces is its own defect.
bool routeAllowedWhenRepositoryUnavailable(String? path) {
  return path == kServerConfigRoute;
}

/// Declares [kRaisedRoutes] into [registry], defaulting to the singleton the
/// navigation menu reads. Idempotent — declaring a path replaces its group.
void installRaisedRoutes([RouteRegistry? registry]) {
  final target = registry ?? RouteRegistry();
  kRaisedRoutes.forEach(target.declareRouteGroup);
}

/// Declares the groups the operator set on pages and sections in the page
/// editor, resolving section inheritance as it walks.
///
/// A page's effective group is its own [MenuItem.requiredGroup], else the
/// nearest ancestor section's, else nothing. **Nothing means nothing is
/// written**, not that `operate` is written: `/advanced/page-editor` and the
/// rest of [kRaisedRoutes] are declared by [installRaisedRoutes], and a
/// customer page that happens to sit at the same path must not silently
/// unraise them. Declaring is idempotent, so call this after
/// [installRaisedRoutes] and it layers on top.
///
/// Sections are not routes and get no declaration of their own. A section
/// disappears from the menu when every page beneath it is hidden, which
/// inheritance already arranges -- see `NavDropdownState.buildFlatMenu`.
void declareMenuRouteGroups(
  Iterable<MenuItem> items, [
  RouteRegistry? registry,
]) {
  final target = registry ?? RouteRegistry();

  void walk(MenuItem item, AccessGroup? inherited) {
    final effective = item.requiredGroup ?? inherited;
    final path = item.path;
    if (!item.isNavigationSection && path != null && effective != null) {
      target.declareRouteGroup(path, effective);
    }
    for (final child in item.children) {
      walk(child, effective);
    }
  }

  for (final item in items) {
    walk(item, null);
  }
}

/// The group [path] needs, read from the registry.
///
/// Callers ask here rather than reaching into [RouteRegistry] themselves, so
/// that a route declared by something other than [installRaisedRoutes] is
/// still answered correctly. Answers [AccessGroup.operate] for anything
/// undeclared, including null.
AccessGroup accessGroupForRoute(String? path) {
  return RouteRegistry().groupForRoute(path);
}
