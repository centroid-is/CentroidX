import 'package:meta/meta.dart';

import 'access_group.dart';

/// The write surfaces the policy can be asked about.
///
/// The wire names are fixed strings rather than [Enum.name] because spec §2's
/// `surface` column is stored data — it lands in every audit row and is read
/// back by the trail. Renaming a value here must not silently rewrite what a
/// year of rows mean, so the mapping is written down.
///
/// The column and this enum are **not the same set**. §2 also carries
/// `'auth'`, which records a sign-in or sign-out. That is an event, not a
/// write somebody could be authorized for, so it is deliberately absent here
/// and [byWireName] answers null for it.
enum AccessSurface {
  /// A process tag written through `StateMan`.
  tag('tag'),

  /// A configuration key written through `PreferencesApi`.
  pref('pref'),

  /// A navigation destination.
  route('route'),

  /// A saved history view, or one of its saved periods.
  ///
  /// Added by plan 17-01. Before it, `guarded_history_views.dart` wrote its
  /// rows under [pref] because the vocabulary had only three write surfaces
  /// and a saved view is not a preference key. **Rows written before that
  /// change carry `surface = 'pref'`**; see the call site for the
  /// discontinuity that leaves in the trail.
  historyView('history_view'),

  /// A role, a user, or an access template.
  ///
  /// One surface for both stores, deliberately. Roles, users and templates are
  /// the same concern — they all answer to [AccessGroup.users] — written by
  /// two objects, and the existing `role.{n}` / `access_template.{n}` itemKey
  /// vocabulary already tells them apart inside one surface. A seventh value
  /// splitting templates out would put the same group in two places, which is
  /// what this phase exists to stop.
  ///
  /// **The wire name is `'admin'`, the string Phase 6's rows already carry.**
  /// Plan 17-01 was written to add this as `'access_admin'`; that would have
  /// been a *second* name for rows that already exist, and the disagreement
  /// would have been live rather than cosmetic — a caller asking
  /// [AccessPolicy.groupForWireSurface] with a real admin row's
  /// `surface = 'admin'` would have fallen down the unmapped branch to
  /// `administer` while the row beside it recorded `groupRequired: 'users'`.
  /// That is exactly the "the group that was checked and the surface that was
  /// recorded cannot disagree" property this enum exists to hold. The name in
  /// the data wins.
  ///
  /// The comment this replaces — in `audit.dart`, that `'admin'` must stay a
  /// private literal because "nothing ever gates on an admin row" — was true
  /// when it was written and is not true now: `groupForAdmin` gates on exactly
  /// these rows, and the rows have carried `groupRequired: 'users'` since
  /// Phase 6, which was already a grading with nowhere to be declared.
  accessAdmin('admin'),

  /// The backend's own `StateManConfig`, edited over the wire.
  backendConfig('config');

  const AccessSurface(this.wireName);

  /// The string written into an audit row's `surface` column.
  final String wireName;

  /// The surface whose [wireName] equals [wireName], or null when unrecognised.
  ///
  /// The match is exact — no case folding, no trimming. Callers pass a
  /// constant, and a value that has been mangled in transit is exactly the
  /// case that must not resolve to a real surface.
  static AccessSurface? byWireName(String wireName) {
    for (final surface in values) {
      if (surface.wireName == wireName) return surface;
    }
    return null;
  }
}

/// The seam Phase 4's access templates plug into.
///
/// Answers the group required to write [member] of tag [key], or null when
/// nothing has been bound. **Null means unrestricted** — this is the
/// fail-open half of the policy, and spec §7b is why: binding is explicit per
/// key, with no inference from asset type and no pattern matching on key
/// names, so a key nobody has bound has no group by construction rather than
/// by omission. A [member] of null asks about the whole key.
///
/// Phase 3 ships no implementation. The constructor default answers null for
/// everything, which is the shipped behaviour until templates land.
typedef TagBindingLookup = AccessGroup? Function(String key, String? member);

/// How a [kPrefAccessRules] entry matches a preference key.
///
/// **The declaration order of these values is the precedence order** —
/// [AccessPolicy.groupForPref] walks `PrefRuleKind.values` in order and takes
/// the first match, so `exact` beats `prefix` beats `suffix`, and anything
/// unmatched falls to `administer`.
///
/// Prefix outranks suffix deliberately. The only suffix rule (`.recipes` →
/// `setpoints`) is the most permissive rule in the table, while the prefix
/// rules (`database`, `network`, `ip_`, `hostname`, `mcp.`, `llm.` →
/// `administer`) are the most restrictive. Were suffix to win, a future key
/// named `network.recipes` or `llm.recipes` would resolve to `setpoints` and
/// hand a restricted surface to a Shift Leader. No key in the tree collides
/// today, which is precisely why this is fixed by ordering rather than left to
/// the no-double-match test — that test passes right up until somebody adds
/// the key.
///
/// Reordering these values changes who may write what.
/// `test/access_policy_test.dart` asserts the order so that it fails the build
/// rather than shipping quietly.
enum PrefRuleKind { exact, prefix, suffix }

/// A single classification rule for a preference key.
typedef PrefAccessRule = ({PrefRuleKind kind, String match, AccessGroup group});

/// The declared group for every preference key the app writes today.
///
/// Derived by resolving key *expressions* to their literals across `lib/` and
/// the two `tfc_dart` core files that write preferences — not by grepping for
/// string literals. The keys that matter here are constants and interpolations
/// at the call site (`storageKey`, `orderStorageKey`, the `page_editor_image:`
/// interpolation and the `.recipes` bucket interpolation), all invisible to a
/// literal grep, which is how spec §7's original table came to name `page.*`
/// and miss `page_editor_data` entirely. The resolved inventory is pasted into
/// `test/access_policy_test.dart` with a line per call site, and a test there
/// asserts every literal it produced is matched by a rule below rather than
/// resting on the default.
///
/// Precedence is **exact, then prefix, then suffix, then the `administer`
/// default** — see [PrefRuleKind], which carries that order. The list is
/// grouped the same way for readability, but the list order is not what
/// decides: [AccessPolicy.groupForPref] iterates by kind, so inserting a rule
/// in the wrong block cannot change precedence.
const List<PrefAccessRule> kPrefAccessRules = <PrefAccessRule>[
  // ---------------------------------------------------------------------
  // exact -> configure. **Route parity.** Phase 2 raised
  // `/advanced/page-editor`, `/advanced/alarm-editor` and
  // `/advanced/key-repository` to `configure`. A key those pages save is the
  // same concern as the page that saves it, and classifying it `administer`
  // would ship a role that can open the editor and cannot save from it — a
  // defect nobody sees until Phase 6 creates such a role.
  //
  // `page_editor_data` is also written at boot with nobody signed in
  // (`page.dart:247`, unawaited, from `PageManager.load()`), so under the
  // fail-closed default a fresh station would have shown no pages at all.
  (kind: PrefRuleKind.exact, match: 'page_editor_data', group: AccessGroup.configure),
  (kind: PrefRuleKind.exact, match: 'page_editor_top_level_order', group: AccessGroup.configure),
  (kind: PrefRuleKind.exact, match: 'key_mappings', group: AccessGroup.configure),
  // `alarm_man_config` is written by AlarmMan.create at boot when the key is
  // absent, and otherwise only by addAlarm/removeAlarm/updateAlarm — human
  // actions behind the configure-gated alarm editor. Acknowledging an alarm
  // writes nothing, so this rule does not stand between an operator and an
  // alarm ack.
  (kind: PrefRuleKind.exact, match: 'alarm_man_config', group: AccessGroup.configure),

  // ---------------------------------------------------------------------
  // exact -> operate. These are what a panel writes about *itself*: its theme,
  // which page it starts on, the colours somebody recently picked, the session
  // payload. They are not plant configuration, and gating them would make the
  // guard's first visible effect a panel that cannot remember its own
  // appearance.
  //
  // They are in the table rather than exempted from it, so they appear in the
  // audit trail and so an edited `Operator` role still governs them: strip
  // `operate` from Operator and these become deniable, which "unrestricted"
  // could never be.
  (kind: PrefRuleKind.exact, match: 'theme_mode', group: AccessGroup.operate),
  (kind: PrefRuleKind.exact, match: 'color_scheme', group: AccessGroup.operate),
  (kind: PrefRuleKind.exact, match: 'startup_url', group: AccessGroup.operate),
  (kind: PrefRuleKind.exact, match: 'asset_stack_config', group: AccessGroup.operate),
  (kind: PrefRuleKind.exact, match: 'color_picker_recent_colors', group: AccessGroup.operate),
  // Written on every poke() — i.e. every pointer-down. A denial here would fire
  // continuously.
  (kind: PrefRuleKind.exact, match: 'access.session', group: AccessGroup.operate),
  (kind: PrefRuleKind.exact, match: 'access.inactivity_timeout_minutes', group: AccessGroup.operate),
  (kind: PrefRuleKind.exact, match: 'access.inactivity_timeout_disabled', group: AccessGroup.operate),

  // ---------------------------------------------------------------------
  // exact -> administer. Server, database and machine configuration.
  (kind: PrefRuleKind.exact, match: 'server_config_envelope', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'state_man_config', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'collector_config', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'update_channel', group: AccessGroup.administer),
  // The five dbus_login keys (`dbus_login.dart:127-131`). Bare, generic names
  // with no prefix to hang a rule on, so each is spelled out. D-Bus is the
  // mechanism *underneath* `administer` — its credential is a station
  // credential and it is how the app makes system-level changes — so these are
  // the strictest thing in the table even though they read like UI state.
  (kind: PrefRuleKind.exact, match: 'connectionType', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'host', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'username', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'autoLogin', group: AccessGroup.administer),
  (kind: PrefRuleKind.exact, match: 'sshPrivateKeyPath', group: AccessGroup.administer),

  // ---------------------------------------------------------------------
  // prefix -> configure.
  // One preference key per stored page-editor image (`image_store.dart:94`).
  (kind: PrefRuleKind.prefix, match: 'page_editor_image:', group: AccessGroup.configure),
  // Forward-looking only. **No key in the tree matches `page.`, `alarm.` or
  // `keymap.` today** — the real names use underscores, which is the defect
  // spec §7 was amended to fix. They are kept so a dotted key added later
  // lands on `configure` rather than on the `administer` default, and they are
  // explicitly not the load-bearing rules: deleting them changes nothing about
  // the app as it stands.
  (kind: PrefRuleKind.prefix, match: 'page.', group: AccessGroup.configure),
  (kind: PrefRuleKind.prefix, match: 'alarm.', group: AccessGroup.configure),
  (kind: PrefRuleKind.prefix, match: 'keymap.', group: AccessGroup.configure),

  // ---------------------------------------------------------------------
  // prefix -> operate. Per-conversation chat state, one key per conversation
  // (`chat.dart:340`), plus the history and conversation-list keys. Device
  // local, like the block above.
  (kind: PrefRuleKind.prefix, match: 'chat.', group: AccessGroup.operate),

  // ---------------------------------------------------------------------
  // prefix -> administer. The restrictive prefixes, and the reason prefix
  // outranks suffix; see [PrefRuleKind].
  //
  // `mcp.`, `database`, `network`, `ip_` and `hostname` match no key in the
  // tree today and are forward-looking, exactly as the block above is — but
  // these fail in the safe direction, so a key added later that nobody
  // classified lands on `administer` either way.
  (kind: PrefRuleKind.prefix, match: 'database', group: AccessGroup.administer),
  (kind: PrefRuleKind.prefix, match: 'network', group: AccessGroup.administer),
  (kind: PrefRuleKind.prefix, match: 'ip_', group: AccessGroup.administer),
  (kind: PrefRuleKind.prefix, match: 'hostname', group: AccessGroup.administer),
  (kind: PrefRuleKind.prefix, match: 'mcp.', group: AccessGroup.administer),
  // Six keys, three of them API keys (`llm_provider.dart:4-11`).
  (kind: PrefRuleKind.prefix, match: 'llm.', group: AccessGroup.administer),

  // ---------------------------------------------------------------------
  // suffix -> setpoints. The one suffix rule, and the one reason suffixes
  // exist at all: `recipes.dart:266,280` builds the key as
  // `'${widget.config.recipesBucket}.recipes'`, so the bucket is a runtime
  // value and only the tail is knowable here.
  //
  // `setpoints` rather than `configure` because REQUIREMENTS.md's shift-leader
  // story is "I sign in to change a setpoint or a recipe" — one breath — and
  // spec §1 glosses `setpoints` as "targets, limits, recipes". Shift Leader
  // holds {operate, setpoints}, so this is what lets one save a recipe.
  //
  // `recipes.dart:266` writes an empty default on the **read** path, which
  // fires for an anonymous operator merely opening a recipes asset. That write
  // is covered by this same rule and would be denied for an anonymous
  // operator; plan 03-06's read-path handling is where that is addressed, and
  // it is called out here so the next reader does not rediscover it.
  (kind: PrefRuleKind.suffix, match: '.recipes', group: AccessGroup.setpoints),
];

/// The single place that answers "what does writing *this* require?".
///
/// Both guards (plans 03-04 and 03-05) consult one instance of this class. If
/// the answer lived in the guards there would be two copies of the fail-open /
/// fail-closed rule, and the interesting failure of this phase is the silent
/// one: a wrong answer looks identical to a right one from every screen.
///
/// **Both surfaces fail closed, to different floors.** [groupForTag] floors
/// at `operate` (2026-09-02 ruling — an unbound key is not unrestricted) and
/// [groupForPref] walks `kPrefAccessRules` down to `administer` for anything
/// unrecognised. Neither returns null, and the type system carries that so a
/// later edit cannot quietly reopen a hole.
@immutable
class AccessPolicy {
  /// [tagBindings] is Phase 4's access-template lookup; the default answers
  /// null for everything, which ships gating no tag at all.
  ///
  /// [routes] mirrors the app package's `kRaisedRoutes`. It is passed in
  /// rather than imported: `tfc_access` is pure Dart and must not reach into
  /// the Flutter app for a route table. Plan 03-06 supplies it.
  const AccessPolicy({
    TagBindingLookup? tagBindings,
    Map<String, AccessGroup> routes = const <String, AccessGroup>{},
    Map<String, AccessGroup> cameras = const <String, AccessGroup>{},
  })  : _tagBindings = tagBindings,
        _routes = routes,
        _cameras = cameras;

  final TagBindingLookup? _tagBindings;
  final Map<String, AccessGroup> _routes;
  final Map<String, AccessGroup> _cameras;

  // ---------------------------------------------------------------------------
  // The member vocabulary
  //
  // The names the four surfaces below are asked about, declared once so the
  // app's stores and the relay's handler table can *name* them rather than
  // re-type them. That is what makes this one vocabulary rather than three
  // that happen to agree today. They are also the strings the stores write
  // into an audit row's `reason` column, so the member that was graded and the
  // member that was recorded cannot disagree.
  // ---------------------------------------------------------------------------

  /// `HistoryViewStore.createHistoryView`.
  static const String historyViewCreate = 'createHistoryView';

  /// `HistoryViewStore.updateHistoryView`.
  static const String historyViewUpdate = 'updateHistoryView';

  /// `HistoryViewStore.addHistoryViewPeriod`.
  static const String historyViewAddPeriod = 'addHistoryViewPeriod';

  /// `HistoryViewStore.deleteHistoryView`.
  static const String historyViewDelete = 'deleteHistoryView';

  /// `HistoryViewStore.deleteHistoryViewPeriod`.
  static const String historyViewDeletePeriod = 'deleteHistoryViewPeriod';

  /// `AccessTemplateStore.create`.
  static const String templateCreate = 'create';

  /// `AccessTemplateStore.update`.
  static const String templateUpdate = 'update';

  /// `AccessTemplateStore.rename`.
  static const String templateRename = 'rename';

  /// `AccessTemplateStore.delete`.
  static const String templateDelete = 'delete';

  /// `AccessTemplateStore.bind`.
  static const String templateBind = 'bind';

  /// `AccessTemplateStore.unbind`.
  static const String templateUnbind = 'unbind';

  /// `AccessAdminStore.createRole`.
  static const String adminCreateRole = 'createRole';

  /// `AccessAdminStore.updateRole`.
  static const String adminUpdateRole = 'updateRole';

  /// `AccessAdminStore.deleteRole`.
  static const String adminDeleteRole = 'deleteRole';

  /// `AccessAdminStore.renameRole`.
  static const String adminRenameRole = 'renameRole';

  /// `AccessAdminStore.createUser`.
  static const String adminCreateUser = 'createUser';

  /// `AccessAdminStore.deleteUser`.
  static const String adminDeleteUser = 'deleteUser';

  /// `AccessAdminStore.setUserRole`.
  static const String adminSetUserRole = 'setUserRole';

  /// `AccessAdminStore.setUserStationAccount`.
  static const String adminSetUserStationAccount = 'setUserStationAccount';

  /// `AccessAdminStore.setUserPassword`.
  static const String adminSetUserPassword = 'setUserPassword';

  /// The preference key whose grading [groupForBackendConfig] reads.
  ///
  /// `StateManConfig.configKey`. Named here rather than typed into
  /// [groupForBackendConfig] so the link between the two is greppable.
  static const String stateManConfigPrefKey = 'state_man_config';

  /// The group required to write [member] of tag [key]. **Never null** — the
  /// floor is [AccessGroup.operate].
  ///
  /// The 2026-09-02 ruling that replaced spec §7b's fail-open half: an
  /// unbound key, an unmentioned member, a missing lookup and an unreadable
  /// binding source all answer `operate` rather than "unrestricted".
  /// Bindings raise the requirement; nothing lowers it past the floor. The
  /// plant does not lock, because the anonymous session maps to the Operator
  /// role, which holds `operate`; what closes is the free pass an account
  /// deliberately stripped of `operate` used to get on every unbound key.
  AccessGroup groupForTag(String key, {String? member}) {
    final lookup = _tagBindings;
    if (lookup == null) return AccessGroup.operate;
    try {
      return lookup(key, member) ?? AccessGroup.operate;
    } on Object {
      // Deliberately swallowed, and deliberately not logged — this package has
      // no logger and must not grow one.
      //
      // The floor must not escalate because a template table is unreadable.
      // This runs on the write path of every jog, start and alarm ack; a
      // guard that threw here because Postgres was down would take the
      // plant's controls down with it. An unreadable binding source is
      // indistinguishable from an unbound key, and both answer the operate
      // floor — which the anonymous Operator role holds.
      return AccessGroup.operate;
    }
  }

  /// The group required to write preference [key]. **Never null.**
  ///
  /// Walks [kPrefAccessRules] by [PrefRuleKind] in precedence order — exact,
  /// then prefix, then suffix — and answers [AccessGroup.administer] when
  /// nothing matches. Matching is case-sensitive and exact; `Page_editor_data`
  /// and `xpage_editor_data` are not `page_editor_data`.
  ///
  /// There is no "unrestricted" answer here by design. §7's config default is
  /// closed, and a nullable return would let a future edit reopen it silently.
  AccessGroup groupForPref(String key) {
    for (final kind in PrefRuleKind.values) {
      for (final rule in kPrefAccessRules) {
        if (rule.kind != kind) continue;
        final matched = switch (kind) {
          PrefRuleKind.exact => key == rule.match,
          PrefRuleKind.prefix => key.startsWith(rule.match),
          PrefRuleKind.suffix => key.endsWith(rule.match),
        };
        if (matched) return rule.group;
      }
    }
    return AccessGroup.administer;
  }

  /// The group required to reach [path], defaulting to [AccessGroup.operate].
  ///
  /// Matches the Phase 2 registry default: a route nobody raised is an
  /// operator route.
  AccessGroup groupForRoute(String? path) {
    if (path == null) return AccessGroup.operate;
    return _routes[path] ?? AccessGroup.operate;
  }

  /// The group required to view camera [cameraId] — to be handed a playable
  /// URL for its stream, whichever transport serves the bytes. **Never null**
  /// — the floor is [AccessGroup.operate].
  ///
  /// The same shape as [groupForRoute], for the same reasons: viewing is an
  /// operator act, so a camera nobody graded is an operator camera; the
  /// grading table is passed in by the composition rather than imported
  /// (this package must not know the plant's camera list); and an entry can
  /// only raise the requirement above the floor, never lower it past it.
  /// There is no "unrestricted" answer for a caller to collapse into
  /// no-check-at-all.
  ///
  /// The caller is the relay's camera-ticket handler (server-side, per the
  /// 2026-09-06 ruling), which asks this **before** minting the credential a
  /// media endpoint will later verify. The rule "who may view a camera" is
  /// stated here, once; the ticket book that carries the answer to the media
  /// port holds no policy — it is a credential mechanism, the carve-out the
  /// one-master-system ruling grants the relay.
  AccessGroup groupForCamera(String cameraId) =>
      _cameras[cameraId] ?? AccessGroup.operate;

  /// The group required to perform [member] on a saved history view, or
  /// **null when the operation is open to any session, anonymous included**.
  ///
  /// This is the one surface in the policy with an open operation, which is
  /// the whole reason [groupForWireSurfaceOrOpen] exists beside
  /// [groupForWireSurface].
  ///
  /// **The split, and who decided it.** The two destructive members require
  /// `configure` because deleting a saved view or a saved period destroys work
  /// that was not yours, from a page anyone can open. The three creative
  /// members stay open because an operator saving a view of the line they run,
  /// naming it, or bookmarking eight hours they want to look at again is doing
  /// their job, and a wrongly-closed operator action becomes a workaround.
  /// Every one of the five is audited regardless, so the choice is reviewable
  /// from the trail rather than only from this comment.
  ///
  /// The relay graded these four different ways (`update` and `addPeriod` at
  /// `operate` where the app leaves them open; the two deletes at `operate`
  /// where the app requires `configure`). The app's split wins in **both**
  /// directions — the 2026-09-07 ruling — so deleting a saved chart over the
  /// WebSocket is a tightening that now matches what a panel already does.
  ///
  /// **An unrecognised member answers `administer`, not null.** T-17-01a: a
  /// history-view method added later and not classified here must fail closed.
  /// Falling to "open" would make every future member ungated by omission,
  /// which is precisely the hole [groupForWireSurface]'s unmapped branch
  /// exists to close.
  AccessGroup? groupForHistoryView(String member) => switch (member) {
        historyViewDelete || historyViewDeletePeriod => AccessGroup.configure,
        historyViewCreate ||
        historyViewUpdate ||
        historyViewAddPeriod =>
          null,
        _ => AccessGroup.administer,
      };

  /// The group required to perform [member] on an access template.
  /// **Never null.**
  ///
  /// Every template operation requires [AccessGroup.users], including one this
  /// method has never heard of. Written as a single answer rather than as a
  /// switch with a default arm **on purpose**: a switch would imply the answer
  /// varies by member, and the next reader adding a member would have to
  /// remember to add an arm. There is no open template operation, so this
  /// cannot fail open by omission — which is a stronger property than a
  /// default arm somebody could delete.
  ///
  /// [member] is accepted, and unused, so that a caller names which operation
  /// it is asking about at the call site and so that a future split by member
  /// is a change of body rather than a change of signature.
  AccessGroup groupForTemplate(String member) => AccessGroup.users;

  /// The group required to perform [member] on a role or a user.
  /// **Never null.**
  ///
  /// [AccessGroup.users] for all nine members and for an unrecognised name,
  /// for the same reason and in the same shape as [groupForTemplate]. Editing
  /// who may do what is the one operation whose own permission cannot be
  /// graded more finely without becoming circular.
  AccessGroup groupForAdmin(String member) => AccessGroup.users;

  /// The group required to write [section] of the backend's `StateManConfig`.
  /// **Never null.**
  ///
  /// **Derived from [kPrefAccessRules], not restated.** The backend's config
  /// and the `state_man_config` preference row are the same concern reached
  /// through two transports — the same server list, the same PLC addresses —
  /// so the two must not be able to disagree. Deriving makes the disagreement
  /// impossible by construction rather than something a test has to catch
  /// after somebody loosens one of the two copies. Change the
  /// `state_man_config` row in [kPrefAccessRules] and this moves with it.
  ///
  /// [section] does not change the answer today. It is a parameter because the
  /// caller knows which section it is writing and the audit row should say so;
  /// an unrecognised section gets the same `administer` a recognised one does,
  /// so a section added to the config later cannot arrive ungraded.
  ///
  /// Which sections are *editable* over the wire is a different question and
  /// is not this method's: the `relay` section is refused by name at the
  /// handler, because you do not edit the socket over the socket.
  AccessGroup groupForBackendConfig(String section) =>
      groupForPref(stateManConfigPrefKey);

  /// The group required to write [key] on [surface], where [surface] is a wire
  /// name from spec §2's `surface` column.
  ///
  /// **This is the entry point the decorators call, not a convenience
  /// wrapper.** Plans 03-04 and 03-05 pass the same `surface` string they
  /// write into the audit row's `surface` column, so the group that was
  /// checked and the surface that was recorded cannot disagree. A reader who
  /// "simplifies" the decorators to call [groupForTag] / [groupForPref]
  /// directly deletes the unmapped branch's only caller and with it the one
  /// test that proves an unknown surface fails closed.
  ///
  /// Never null: every surface answers a group. The tag arm floors at
  /// `operate`, `'pref'` and `'route'` always answered one, the unmapped
  /// branch fails closed on `administer`, and the one surface that *can*
  /// answer open is collapsed to its strict answer here — see
  /// [groupForWireSurfaceOrOpen] for which of the two a caller wants.
  ///
  /// **This is the member an audit row's `groupRequired` column asks**: it
  /// wants the requirement, not the question of whether there was one.
  AccessGroup groupForWireSurface(String surface, String key,
      {String? member}) {
    final open = groupForWireSurfaceOrOpen(surface, key, member: member);
    if (open != null) return open;

    // Only a surface with an open operation reaches here, and today that is
    // exactly one. The collapse is decided per surface rather than by a bare
    // `?? configure`, so a surface that grows an open operation later cannot
    // silently inherit the history view's strict answer.
    return switch (AccessSurface.byWireName(surface)) {
      // The strict answer for an open history-view member is what its
      // destructive siblings require: the requirement that exists on this
      // surface, rather than a group borrowed from somewhere else.
      AccessSurface.historyView => AccessGroup.configure,
      _ => AccessGroup.administer,
    };
  }

  /// The group required to write [key] on [surface], or **null when the
  /// operation is open**.
  ///
  /// **This is the member a guard asks**: it wants to know whether to check at
  /// all. [groupForWireSurface] is what a caller asks when it needs an answer
  /// for an audit row's `groupRequired` column.
  ///
  /// The pair exists because exactly one surface has an open operation
  /// ([groupForHistoryView]'s three creative members), and the shape is here
  /// so that stays visible rather than being smuggled into a nullable return
  /// on the member everything else calls. Widening [groupForWireSurface] to
  /// nullable instead would make every caller handle a null that only one
  /// surface can produce, and the first caller to write `?? AccessGroup.operate`
  /// would open five surfaces at once.
  ///
  /// **This is the switch.** [groupForWireSurface] delegates to it rather than
  /// carrying a second copy — two switches over the same six surfaces would be
  /// two places to forget a seventh.
  ///
  /// Null here means **open**, and only open. An unrecognised surface answers
  /// `administer`, not null: "nobody classified this" and "anybody may do
  /// this" must not look the same to a caller.
  AccessGroup? groupForWireSurfaceOrOpen(String surface, String key,
      {String? member}) {
    return switch (AccessSurface.byWireName(surface)) {
      AccessSurface.tag => groupForTag(key, member: member),
      AccessSurface.pref => groupForPref(key),
      AccessSurface.route => groupForRoute(key),
      AccessSurface.historyView => groupForHistoryView(key),
      AccessSurface.accessAdmin => groupForAdmin(key),
      AccessSurface.backendConfig => groupForBackendConfig(key),
      // A surface string this file does not know is either a new write surface
      // nobody classified or a typo. Both should land on the strictest answer
      // rather than the most permissive, so an unclassified surface is a
      // denial waiting to be noticed rather than a hole nobody sees.
      //
      // Deliberately not a throw: the guards call this on the write path, and
      // an ArgumentError there would be an outage rather than a denial.
      null => AccessGroup.administer,
    };
  }
}
