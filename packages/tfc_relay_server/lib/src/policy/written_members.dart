/// Which members of a tag a write actually moves.
///
/// The wire half of the member-aware grading rule. `tfc_access`'s
/// `gradeTagWrite` decides what a set of member names requires; this decides
/// which names a frame carries. The split is in that function's doc: there are
/// two classes called `DynamicValue` in this solve and neither package may
/// depend on the other, so the shared decision is expressed over names and
/// each side computes its own.
///
/// ## Why a diff and not "the members present in the frame"
///
/// Grading every member the frame carries would be simpler and it would be
/// wrong in the direction that takes controls off the floor. One conveyor key
/// carries `p_cmd_JogFwd` and `p_cfg_ManualFreq` through a **single
/// whole-struct write** (spec §7b) — that is the ordinary shape, not an edge
/// case — so a panel jogging a conveyor sends the setpoint along with it,
/// unchanged. Grade on presence and an operator needs `setpoints` to jog.
///
/// `GuardedStateMan` reached the same conclusion for the app and states it at
/// `guarded_state_man.dart:206-211`: *"The diff comes before the decision… A
/// question asked about the key can only ever have one answer for both. The
/// question asked about the members that moved can have two."* This is that
/// sentence, on the wire.
///
/// ## The baseline is free here
///
/// The app pays for its baseline with a read and a timeout, and a read that
/// misses costs it member gating for that write. The gateway does not: it is
/// the thing that holds the values, and `StateManApi.read` is synchronous.
/// So the wire's fallback window is narrower than the app's — it opens only
/// for a key the gateway has genuinely never sampled.
///
/// ## Fail towards asking for more
///
/// Anything this cannot resolve into member names answers `[null]`, which
/// `gradeTagWrite` reads as the key-level question. That is the same fallback
/// the app takes and it carries the same cost, recorded there: the key-level
/// answer is the *least* gated one a template can give, so a write whose shape
/// cannot be diffed is checked against the whole-key row or the operate floor.
/// It is not a hole this file can close — a value with no baseline has no
/// members to name — and it is why the gateway's synchronous read matters.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Sentinel for a member present on one side only.
const Object _absent = Object();

/// The member paths [written] moves on a tag currently holding [baseline].
///
/// Returns a list containing a single null when the members cannot be
/// determined — a scalar write, a value with no baseline, or a shape change —
/// which is the key-level question.
List<String?> writtenMembers(DynamicValue? baseline, Object? written) {
  if (baseline == null) return const <String?>[null];
  final base = baseline.toJson(slim: true);
  if (base is! Map || written is! Map) return const <String?>[null];
  final changed = <String?>[];
  _diffInto(changed, null, base, written);
  return changed;
}

/// Appends to [changed] every member path below [path] whose value differs.
void _diffInto(
  List<String?> changed,
  String? path,
  Object? base,
  Object? next,
) {
  if (base is Map && next is Map) {
    // The baseline's own order first, then anything the frame added, so a
    // refusal names members in the order the struct declares them.
    final names = <String>{
      for (final key in base.keys) '$key',
      for (final key in next.keys) '$key',
    };
    for (final name in names) {
      final childPath = path == null ? name : '$path.$name';
      final baseChild = base.containsKey(name) ? base[name] : _absent;
      final nextChild = next.containsKey(name) ? next[name] : _absent;
      if (identical(baseChild, _absent) || identical(nextChild, _absent)) {
        // Present on one side only: one entry for the whole member and no
        // descent. An added struct is one thing that appeared, not a claim
        // about members of something that had no previous shape.
        changed.add(childPath);
        continue;
      }
      _diffInto(changed, childPath, baseChild, nextChild);
    }
    return;
  }
  // `jsonEquals` rather than `==`: it compares maps regardless of key order
  // and holds numbers to their runtime type, which is the distinction a PLC
  // cares about — a DINT 1 and a REAL 1.0 are two different writes.
  if (!jsonEquals(base, next)) changed.add(path);
}
