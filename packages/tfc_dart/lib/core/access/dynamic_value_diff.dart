/// One whole-struct write reduced to the members that actually changed.
///
/// Several assets are copy-on-write: clone the struct, set one field, write the
/// whole thing back (`conveyor.dart:2383`, `sensor.dart:778`,
/// `recipes.dart:454`). At the `StateMan` boundary that is a single write of a
/// single large value, so the audit trail either deduces which members moved or
/// it stores two blobs side by side and nobody ever filters it. Spec §2 asks
/// for `p_cmd_JogFwd false -> true`, and this file is the only place that
/// reduction happens.
///
/// ## Why this compares `.value` and never the wrappers
///
/// `DynamicValue` defines no equality of its own. The single equality operator
/// in `open62541-1.5.7+2/lib/src/dynamic_value.dart` is at line 23, on
/// `LocalizedText` — the helper, not the value. So for any two distinct
/// instances `a != b` is true, and it stays true when both hold `false`.
/// A diff written against the wrappers therefore marks *every* member changed
/// on *every* write, and a trail that reports thirty changes for a jog is one
/// nobody reads: it looks complete, which is worse than looking empty. The
/// reduction here recurses to the scalar leaves and compares the underlying
/// `.value`. `dynamic_value_diff_test.dart` builds both sides from separate
/// real `DynamicValue` instances so that a regression to wrapper comparison
/// fails rather than passes.
///
/// ## Why it is stateless
///
/// Both sides arrive as arguments. Spec §2's no-op suppression across
/// successive writes belongs at the guard, where the previous value lives;
/// there is no cache, no clock and no logger here, and pulse collapsing is
/// explicitly not built.
library;

import 'dart:collection' show LinkedHashMap;

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_access/tfc_access.dart' show AuditRecord;

/// One member of a struct write that changed, ready to become one audit row.
class MemberChange {
  const MemberChange({
    this.member,
    this.oldValue,
    this.newValue,
    this.noBaseline = false,
  });

  /// Dotted path within the struct — `p_cfg.Freq`. Null when the change is the
  /// whole value: a bare scalar write, an opaque value, or no baseline.
  ///
  /// Never carries an array index. Arrays are reported whole (see
  /// [_membersOrNull]).
  final String? member;

  /// The rendering of the value before the write, or null when there was no
  /// value there — an absent member, or a member that held null.
  ///
  /// Null is a distinct answer from `''` on purpose. `DynamicValue.asString` is
  /// `value?.toString() ?? ''`, which collapses the two, and a member that
  /// genuinely went from absent to empty would then render identically on both
  /// sides and be dropped as unchanged.
  final String? oldValue;

  /// The rendering after the write, on the same terms as [oldValue].
  final String? newValue;

  /// True when there was no old value at all to diff against.
  ///
  /// The row is then the whole new value, marked, rather than N rows each
  /// falsely claiming its member changed.
  final bool noBaseline;

  @override
  String toString() => 'MemberChange(${member ?? '<whole value>'}: '
      '${oldValue ?? '<none>'} -> ${newValue ?? '<none>'}'
      '${noBaseline ? ', no baseline' : ''})';
}

/// The cap on a rendered value, in characters.
///
/// These strings land in a database column and in log lines, and the value
/// being rendered is whatever a struct member happened to hold — a pasted blob
/// is as legitimate an input as a boolean. Spec §10 records that `pg_notify`
/// has an 8000-byte cap which preference writes already fire, so unbounded
/// audit strings are not a hypothetical cost on this deployment. 256 characters
/// is past the length of any real member on this plant.
const int kMaxRenderedValueLength = 256;

/// Appended to a rendering the cap cut short, so a reader can tell a truncated
/// row from a short one.
const String kRenderTruncationMarker = '...[truncated]';

/// The members of [oldValue] that [newValue] changed.
///
/// Recursion continues only while **both** sides are readable objects. At every
/// other pair — scalar against scalar, array against anything, object against
/// scalar — at most one [MemberChange] is emitted for that path, carrying the
/// whole rendered value. Member order is the old struct's own order, with
/// members that exist only in the new value appended.
///
/// A null [oldValue] means no baseline and yields exactly one marked change.
/// A [DynamicValue] that *holds* null is a different thing: that is a real
/// null-to-value transition and is reported as one.
List<MemberChange> diffDynamicValue(
  DynamicValue? oldValue,
  DynamicValue newValue,
) {
  if (oldValue == null) {
    return [
      MemberChange(
        newValue: renderDynamicValue(newValue),
        noBaseline: true,
      ),
    ];
  }
  final changes = <MemberChange>[];
  _diffInto(changes, null, oldValue, newValue);
  return changes;
}

/// N [changes] as N [AuditRecord]s of one action.
///
/// Every field except `member`, `oldValue` and `newValue` is shared, so one
/// human action reads as one action with N member rows beneath it rather than N
/// unrelated rows.
///
/// ## The empty case, and why the caller decides what it means
///
/// An empty [changes] list yields an empty record list: a write that changed
/// nothing writes nothing, which is spec §2's no-op suppression landing in the
/// only place it can be proven without a running database.
///
/// That is right for a **permitted** write and wrong for a **denied** one. A
/// refused write whose diff came out empty must still leave a row, because the
/// row is the only evidence a guard fired at all. So the empty list means
/// exactly "nothing to say about members" and never "record nothing"; a guard
/// that must record a refusal regardless passes a change of its own — a
/// `MemberChange` with a null member and no renderings — and gets its one row.
/// Plan 03-04 owns that decision; this function does not make it on the
/// caller's behalf in either direction.
///
/// [actionId] is a parameter and is never generated here: one human action may
/// span more than one call — a recipe apply that writes two keys is one action
/// — and minting the id inside would make that impossible to express.
///
/// [reason] is the free-text justification spec §2 wants on `configure` and
/// `administer` writes. Nothing in Phase 3 supplies one; the prompt that
/// collects it arrives with tap-time elevation in Phase 4.
List<AuditRecord> auditRecordsForChanges({
  required List<MemberChange> changes,
  required DateTime at,
  required String who,
  required String station,
  required String roleName,
  required String surface,
  required String itemKey,
  required String groupRequired,
  required bool allowed,
  required String actionId,
  String origin = 'operator',
  String? reason,
}) =>
    [
      for (final change in changes)
        AuditRecord(
          at: at,
          who: who,
          station: station,
          roleName: roleName,
          surface: surface,
          itemKey: itemKey,
          member: change.member,
          oldValue: change.oldValue,
          newValue: change.newValue,
          groupRequired: groupRequired,
          allowed: allowed,
          origin: origin,
          actionId: actionId,
          reason: reason,
        ),
    ];

/// Appends to [changes] every difference between [oldValue] and [newValue]
/// below [path].
void _diffInto(
  List<MemberChange> changes,
  String? path,
  DynamicValue oldValue,
  DynamicValue newValue,
) {
  final oldMembers = _membersOrNull(oldValue);
  final newMembers = _membersOrNull(newValue);

  if (oldMembers == null || newMembers == null) {
    if (!_sameValue(oldValue, newValue)) {
      changes.add(MemberChange(
        member: path,
        oldValue: renderDynamicValue(oldValue),
        newValue: renderDynamicValue(newValue),
      ));
    }
    return;
  }

  // The old struct's order first, then anything the new value added, so the
  // rows read in the order the struct declares its members.
  final names = <String>{...oldMembers.keys, ...newMembers.keys};
  for (final name in names) {
    final childPath = path == null ? name : '$path.$name';
    final oldMember = oldMembers[name];
    final newMember = newMembers[name];

    if (oldMember == null || newMember == null) {
      // Present on one side only. One change for the whole member, no descent:
      // an added struct is one line saying it appeared, not a line per member
      // of something that had no previous shape.
      changes.add(MemberChange(
        member: childPath,
        oldValue: oldMember == null ? null : renderDynamicValue(oldMember),
        newValue: newMember == null ? null : renderDynamicValue(newMember),
      ));
      continue;
    }

    _diffInto(changes, childPath, oldMember, newMember);
  }
}

/// The members of [value] in declaration order, or null when it is not an
/// object the diff can descend into.
///
/// Null for three different reasons, all of which mean the same thing here —
/// treat the value as an opaque leaf:
///
/// * it is a scalar;
/// * it is an array. Arrays stay whole: the indexed read-modify-write at
///   `state_man.dart:1956` already presents them that way, and `recipe[0]`
///   through `recipe[199]` is not a trail anybody reads;
/// * reading it threw. `entries` and `asObject` both throw `StateError` off a
///   non-object, so a value that lies about its type must not be able to empty
///   a change list by exception. A change list silently emptied is the failure
///   this whole file exists to prevent.
LinkedHashMap<String, DynamicValue>? _membersOrNull(DynamicValue value) {
  if (!value.isObject) return null;
  try {
    return LinkedHashMap<String, DynamicValue>.fromEntries(value.entries);
  } catch (_) {
    return null;
  }
}

/// Whether [a] and [b] hold the same value, compared at the scalar leaves.
///
/// [DynamicValue.isNull] is checked before anything else, so absent and empty
/// never collapse onto each other. Structural comparison is used for arrays and
/// for objects reached inside an array — not comparison of the rendered forms,
/// because two different values that both exceed [kMaxRenderedValueLength]
/// render identically once truncated, and a diff that misses a change because
/// the values were long is exactly the trail defect this file is here to
/// remove.
bool _sameValue(DynamicValue a, DynamicValue b) {
  if (a.isNull || b.isNull) return a.isNull && b.isNull;

  final aList = a.isArray ? a.value as List<DynamicValue> : null;
  final bList = b.isArray ? b.value as List<DynamicValue> : null;
  if (aList != null || bList != null) {
    if (aList == null || bList == null) return false;
    if (aList.length != bList.length) return false;
    for (var i = 0; i < aList.length; i++) {
      if (!_sameValue(aList[i], bList[i])) return false;
    }
    return true;
  }

  final aMembers = _membersOrNull(a);
  final bMembers = _membersOrNull(b);
  if (aMembers != null && bMembers != null) {
    if (aMembers.length != bMembers.length) return false;
    for (final entry in aMembers.entries) {
      final other = bMembers[entry.key];
      if (other == null || !_sameValue(entry.value, other)) return false;
    }
    return true;
  }
  if (a.isObject || b.isObject) {
    // At least one side is an object the members of which could not be read.
    // The rendered form is all that is left; an unreadable value that renders
    // the same as its counterpart is reported as unchanged.
    return renderDynamicValue(a) == renderDynamicValue(b);
  }

  return a.value == b.value;
}

/// [value] as an audit-row string, or null when it holds no value at all.
///
/// Null rather than `''`, deliberately: see [MemberChange.oldValue]. The result
/// is capped at [kMaxRenderedValueLength] with [kRenderTruncationMarker]
/// appended when it was cut.
///
/// `DynamicValue.asString` is not used. On an object it answers the backing
/// map's `toString()`, which is unbounded and carries the wrapper's own
/// `toString` padding (`{Freq:   42.5}`), and on a null it answers `''`.
String? renderDynamicValue(DynamicValue value) {
  if (value.isNull) return null;
  final out = StringBuffer();
  _write(out, value.value);
  final rendered = out.toString();
  return rendered.length <= kMaxRenderedValueLength
      ? rendered
      : rendered.substring(0, kMaxRenderedValueLength) +
          kRenderTruncationMarker;
}

/// Writes [value] into [out], stopping once [out] is already past the cap.
///
/// The early return bounds the intermediate string as well as the returned one:
/// rendering a large struct does not build a megabyte before truncating it, and
/// a nested recursion terminates because each nested call returns at this first
/// line once the buffer is full.
void _write(StringBuffer out, dynamic value) {
  if (out.length > kMaxRenderedValueLength) return;
  if (value == null) {
    out.write('null');
    return;
  }
  if (value is Map) {
    out.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) out.write(', ');
      first = false;
      out.write('${entry.key}: ');
      _write(out, entry.value is DynamicValue
          ? (entry.value as DynamicValue).value
          : entry.value);
    }
    out.write('}');
    return;
  }
  if (value is List) {
    out.write('[');
    var first = true;
    for (final element in value) {
      if (!first) out.write(', ');
      first = false;
      _write(out,
          element is DynamicValue ? element.value : element);
    }
    out.write(']');
    return;
  }
  out.write(value.toString());
}
