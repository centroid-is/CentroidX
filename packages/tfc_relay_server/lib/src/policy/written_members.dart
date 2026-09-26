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
/// Returns `[null]` — the key-level question — **only when the frame carries
/// no members at all**: a scalar, an array, anything that is not an object.
/// Everything else names members, one way or the other.
///
/// ## Why a missing baseline does NOT fall back to the key-level question
///
/// It did, and that was an authorisation bypass a client could take on
/// purpose. The baseline comes from the gateway's own store, and the store
/// holds a key only once something has asked for it — `BackendLiveValues.read`
/// answers null until a value has arrived, and the pipe worker "pipes only
/// what it was asked for". A mapped key nobody subscribes, nothing historises
/// and no alarm rule watches has **no baseline ever**. The existence check on
/// the write path passes for any mapped key, and nothing requires a prior
/// subscribe.
///
/// So a session holding `operate` could write the whole struct of a cold key,
/// take the null baseline, get the key-level answer — the operate floor, for a
/// template with no whole-key row — and actuate a `force`-bound member. Not a
/// window: a path the caller chooses. A last sample the PLC marked Bad does
/// the same thing, because a bad-quality value carries a null value and so is
/// not a Map either.
///
/// The app's reason for the permissive fallback — a slow PLC read must not
/// take a jog off the floor — does not transfer. There the missing baseline is
/// the plant being slow; here it is the client's choice, and every honest
/// panel already subscribes what it writes.
///
/// So with no baseline the frame is graded **on presence**: every member it
/// carries. That is strictly stricter than the diff, needs no baseline, and
/// costs an honest caller nothing, because a caller that has never read the
/// tag is in no position to claim it is only moving one member of it.
List<String?> writtenMembers(DynamicValue? baseline, Object? written) {
  // Not an object: there are no members to name, and the key-level question is
  // the only honest one. A scalar or array cannot actuate a struct member —
  // the wire's type inference answers a type mismatch — so this arm cannot be
  // used to reach one.
  if (written is! Map) return const <String?>[null];
  final base = baseline?.toJson(slim: true);
  if (base is! Map) {
    // No baseline, or one that is not an object (a Bad sample carries null).
    // Grade on presence.
    final carried = <String?>[];
    _presenceInto(carried, null, written);
    // An empty object moves nothing and names nothing; the key-level question
    // is right for it and `gradeTagWrite` reads an empty list as exactly that.
    return carried;
  }
  final changed = <String?>[];
  _diffInto(changed, null, base, written);
  return changed;
}

/// Appends every member path [value] carries below [path].
void _presenceInto(List<String?> carried, String? path, Object? value) {
  if (value is Map && value.isNotEmpty) {
    for (final entry in value.entries) {
      final childPath =
          path == null ? '${entry.key}' : '$path.${entry.key}';
      _presenceInto(carried, childPath, entry.value);
    }
    return;
  }
  if (path != null) carried.add(path);
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
  if (!_sameLeaf(base, next)) changed.add(path);
}

/// Whether two decoded leaf values are the same reading.
///
/// **Numbers compare by value, not by runtime type**, and that is the one
/// place this deliberately differs from `jsonEquals`. That function holds
/// `1 != 1.0` on purpose — it backs the idempotency fingerprint, where a DINT
/// 1 and a REAL 1.0 really are two different writes to two different tag
/// types. This question is a different one: *did the operator move this
/// member*, and 50 and 50.0 are the same setpoint.
///
/// It is not academic. The only web arm is gateway mode, and on dart2js an
/// integral double encodes as `50`, not `50.0`; the baseline from the worker
/// is a double. Under `jsonEquals` every integral REAL member of a
/// whole-struct jog therefore read as *moved*, so a browser jogging a conveyor
/// needed `setpoints` — exactly the outcome this file exists to prevent. Worse,
/// gateway mode also wraps the app in `GuardedStateMan`, which compares with
/// `==`: the app would allow the write and the wire refuse it, which is two
/// answers to one question again, in the other direction.
bool _sameLeaf(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameLeaf(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_sameLeaf(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  return a == b;
}
