/// The fixed permission groups.
///
/// Groups are defined in code and referenced by assets and routes; roles are
/// customer data that map onto them. That split is the whole point of the
/// model: a customer can invent a role without a schema change, but cannot
/// invent a capability the code does not already understand.
///
/// `users` is deliberately separate from `configure`. Fold them together and
/// anyone who can edit a page can grant themselves everything.
///
/// **Exactly these seven.** An eighth value is a decision, not an edit — it
/// changes what every role in the field can be granted, and every deployed
/// station's stored role rows are written in terms of these names.
/// `test/access_group_test.dart` asserts the count and order exactly so that
/// adding one fails the build rather than shipping quietly.
enum AccessGroup {
  /// Start/stop/jog, gates, alarm acknowledge.
  operate,

  /// Targets, limits, recipes.
  setpoints,

  /// Drive parameters, calibration, scaling.
  device,

  /// Forced I/O and overrides.
  force,

  /// Page editor, alarm rules, key mappings.
  configure,

  /// Server config, database, network, updates.
  administer,

  /// Managing roles and users.
  users;

  /// The value whose [name] equals [name], or null when unrecognised.
  ///
  /// Returns null rather than throwing: a station running a newer build may
  /// have written a group name this one has never heard of into
  /// `AppRole.groups`, and the right answer to that is "not granted", not a
  /// crash on read.
  ///
  /// The match is exact — no case folding, no trimming. These names are stored
  /// data, written by `AccessRole.encodeGroups`, not user input.
  static AccessGroup? byName(String name) {
    for (final group in values) {
      if (group.name == name) return group;
    }
    return null;
  }
}

/// Operator-facing metadata for each group. Kept out of the enum so the
/// persisted identifier stays stable while the display text can change freely.
///
/// This is not a stylistic preference. `AccessRole.encodeGroups` writes
/// [AccessGroup.name] into the `app_role.groups` column on every deployed
/// station, and `decodeGroups` reads those same names back. If [label] were an
/// enum value's own text — or if anything ever resolved a group *by* its label
/// — then rewording a checkbox would silently rewrite what a role grants on the
/// floor. Outside the enum, a label change is a display change and nothing else.
///
/// Both getters return plain [String]s and nothing else. This package is pure
/// Dart, so no icon and no colour may join them here — move anything needing
/// Flutter into the consumer that already depends on it.
/// `test/package_purity_test.dart` enforces that by matching on file text, so
/// even naming the forbidden imports in a comment fails it.
///
/// Both switches are exhaustive with no `default` arm, so an eighth group fails
/// the build here as well as in `test/access_group_test.dart`.
extension AccessGroupInfo on AccessGroup {
  /// Title-cased name for a checkbox in the roles editor.
  ///
  /// `device` and `force` are the reason this exists: those two bare enum names
  /// tell a commissioning engineer nothing about which of them covers a drive
  /// parameter and which covers a forced output. `AccessGroup.name` is used raw
  /// today in `lib/widgets/access_denied_prompt.dart`, whose doc already calls
  /// it "the same word the roles screen shows".
  String get label {
    switch (this) {
      case AccessGroup.operate:
        return 'Operate';
      case AccessGroup.setpoints:
        return 'Setpoints';
      case AccessGroup.device:
        return 'Device parameters';
      case AccessGroup.force:
        return 'Force and override';
      case AccessGroup.configure:
        return 'Configure';
      case AccessGroup.administer:
        return 'Administer station';
      case AccessGroup.users:
        return 'Roles and users';
    }
  }

  /// One-line description, shown as the checkbox subtitle.
  ///
  /// These are the doc-comment sentences on the enum values above, verbatim.
  /// They are already the wording spec §1 uses and the wording the MCP tools
  /// surface; a paraphrase here would be a second vocabulary for the same seven
  /// things. Each ends in a full stop so it reads as a sentence under the label.
  String get description {
    switch (this) {
      case AccessGroup.operate:
        return 'Start/stop/jog, gates, alarm acknowledge.';
      case AccessGroup.setpoints:
        return 'Targets, limits, recipes.';
      case AccessGroup.device:
        return 'Drive parameters, calibration, scaling.';
      case AccessGroup.force:
        return 'Forced I/O and overrides.';
      case AccessGroup.configure:
        return 'Page editor, alarm rules, key mappings.';
      case AccessGroup.administer:
        return 'Server config, database, network, updates.';
      case AccessGroup.users:
        return 'Managing roles and users.';
    }
  }
}

/// The group reading the plant takes.
///
/// **Here rather than in the relay, and that is the constitution's rule.** The
/// relay decides "which identity is this" and asks the master "and may it do
/// X"; it never answers "what does this require?" itself, because a second
/// place that grades is a second policy, and two policies disagree eventually.
/// `no_second_policy_test` arm 8 enforces exactly that by refusing any
/// `AccessGroup` grade literal under `tfc_relay_server/lib/`, and it caught
/// this constant living there.
///
/// Why `operate` and not the write group of the thing being read: a station
/// reads `key_mappings` in order to build its client, and the key that takes
/// `configure` to write is the one every operator's panel must read. A
/// template binding a tag to `configure` withholds the *write* from an
/// operator, not the reading.
///
/// Reads are graded at all since 2026-09-16: a session holds what the plant's
/// `anonymous` account holds until somebody signs in, so a plant whose
/// anonymous account is `NoOp` shows a browser nothing, and one that grants
/// anonymous `operate` keeps its walk-up displays.
const AccessGroup plantReadFloor = AccessGroup.operate;

/// The second group a family's reads accept, when the family's own writes
/// take something other than [plantReadFloor].
///
/// A `users`-holding administrator reads the templates screen; a
/// `configure`-holding engineer reads the routing table. Whoever may save a
/// thing may list it, without also needing the floor.
const AccessGroup historyViewReadAlso = AccessGroup.configure;
