/// What a tag write requires, and which of it the session is missing.
///
/// **One implementation, asked by both sides.** Until this file existed the
/// rule lived only in `GuardedStateMan` (`tfc_dart`), which is the *app's*
/// write path — so a station in direct mode graded a setpoint write against
/// its template and the same write over the WebSocket did not. The wire asked
/// `groupForWireSurface(tag, key)` with no member at all, against a policy
/// built with no tag bindings, and therefore answered `operate` for every key
/// on the plant: `setpoints`, `device` and `force` collapsed into one
/// permission the moment the value left the panel.
///
/// That is the failure this package exists to prevent. Phase 17's constitution
/// is that there is **one** access-control system and every surface asks it;
/// two copies of a grading rule is how the old `AllVisibleOperatorWrites`
/// disagreed with the app in both directions, and deleting that duplication is
/// what `key_policy.dart:186` records. A rule stated twice is a rule that will
/// be corrected once.
///
/// ## Why this takes member NAMES and not a value
///
/// There are two classes called `DynamicValue` in this solve — `tfc_dart`'s and
/// `tfc_relay_protocol`'s — and neither package may depend on the other. So the
/// decision is expressed over the one thing both sides can produce without a
/// shared type: the names of the members a write touches. Each caller computes
/// that list in its own vocabulary (`diffDynamicValue` on the app side, the
/// written object's own members on the wire) and the grading is decided here.
///
/// The split is deliberate rather than reluctant: *which members moved* is a
/// question about a value's shape, and *what those members require* is a
/// question about policy. Only the second one is allowed to have two answers,
/// and this file is why it does not.
library;

import 'access_group.dart';
import 'access_policy.dart';
import 'access_session.dart';

/// The member list a caller passes when the write genuinely has no members:
/// a scalar tag, a hold-to-run engage, an alarm acknowledge.
///
/// Named rather than spelled `const [null]` at each call site so that asking
/// the key-level question is a claim somebody made, not a default somebody
/// got. The defect this grading exists to fix was exactly a caller asking the
/// key-level question because it was the only question the signature offered.
const List<String?> kWholeKeyWrite = <String?>[null];

/// The verdict on one tag write.
final class TagWriteGrade {
  TagWriteGrade({
    required List<AccessGroup> required,
    required List<AccessGroup> missing,
  })  : required = List<AccessGroup>.unmodifiable(required),
        missing = List<AccessGroup>.unmodifiable(missing);

  /// Every group this write needed — one per graded member, or a single
  /// key-level answer when the members are not known.
  final List<AccessGroup> required;

  /// The subset of [required] the session does not hold.
  final List<AccessGroup> missing;

  /// Whether the write may proceed.
  bool get allowed => missing.isEmpty;

  /// The single group to name in a refusal.
  ///
  /// **One permission, never a list.** A prompt that says "you need
  /// setpoints, device and force" tells an operator nothing they can act on;
  /// the strictest one is the thing they have to be granted. Ranked by
  /// [AccessGroup]'s declaration index, which is declared in increasing
  /// privilege — deliberately not a second ranking table, because two
  /// orderings of one enum is a defect waiting for somebody to add a group to
  /// only one of them.
  AccessGroup? get strictestMissing => strictestOf(missing);

  /// The strictest group the action actually required, for an audit row on an
  /// allowed write.
  AccessGroup? get strictestRequired => strictestOf(required);
}

/// The strictest of [groups] by declaration index, or null when empty.
AccessGroup? strictestOf(Iterable<AccessGroup> groups) {
  AccessGroup? strictest;
  for (final group in groups) {
    if (strictest == null || group.index > strictest.index) strictest = group;
  }
  return strictest;
}

/// Grades a write of [changedMembers] on [key] for [session].
///
/// [changedMembers] is the list of member paths the write touches, in the
/// dotted form templates are bound against (`p_cfg_ManualFreq`, `motor.speed`).
///
/// **The key-level fallback, and its cost stated plainly.** An empty list, or
/// any entry that is null, means the caller could not say which members moved
/// — a bare scalar write, an opaque or array value, or a baseline that was not
/// available. The question then collapses to the key-level one: the template's
/// whole-key row, or the operate floor.
///
/// That degrades to the *least* gated answer the template can give, and it is
/// the one way member gating can be bypassed. The strict reading — require
/// every group the template names anywhere — was rejected on the app side
/// because it refuses an anonymous jog when a PLC read is slow, taking a
/// working control off the floor for a reason the operator can neither see nor
/// fix. The same reasoning holds here and the same limitation comes with it.
///
/// Note what this does NOT do: it never lowers a requirement. Since the
/// 2026-09-02 ruling `groupForTag` floors every tag at [AccessGroup.operate]
/// and bindings only raise it, so an unbound key, a dangling binding and a
/// never-loaded snapshot all answer the floor rather than "unrestricted".
TagWriteGrade gradeTagWrite({
  required AccessPolicy policy,
  required AccessSession session,
  required String surface,
  required String key,
  required List<String?> changedMembers,
}) {
  // Through `groupForWireSurface`, never `groupForTag`: the wire-surface
  // lookup is what keeps `AccessPolicy`'s unmapped-surface branch on a real
  // write path, and calling the typed method here would quietly delete that
  // branch's only caller.
  final required = <AccessGroup>[
    if (changedMembers.isEmpty || changedMembers.any((m) => m == null))
      policy.groupForWireSurface(surface, key)
    else
      for (final member in changedMembers)
        policy.groupForWireSurface(surface, key, member: member),
  ];
  return TagWriteGrade(
    required: required,
    missing:
        required.where((group) => !session.can(group)).toList(growable: false),
  );
}
