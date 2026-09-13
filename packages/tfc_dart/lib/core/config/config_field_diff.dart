/// One change row reduced to the fields that actually moved, for display.
///
/// A `config_change` row holds the **complete entity** on each side, which is
/// what makes a restore "write `old_value` back, with nothing to reconstruct".
/// It is also two JSON blobs, and a history that shows an engineer two blobs
/// is one nobody reads. This turns them into
/// `payload.coordinates.x: 0.31 → 0.42`.
///
/// ## Which config diff this is
///
/// There are two, and the ROADMAP calls both "the config diff":
///
/// * `config_diff.dart` — the **write-path, entity-set** diff. Given the whole
///   thing an editor handed over and what is stored, it answers *which entities
///   need writing*. Its output is rows in the database.
/// * this file — the **read-path, field-level** diff. Given one already-written
///   row's two sides, it answers *what an engineer should be shown*. Its output
///   is text on a screen.
///
/// The reduction happens here, on read, and never on write. The stored history
/// carries the complete entity on both sides precisely so it can answer
/// questions the writer did not think to ask — reducing before storing would
/// make the trail smaller and the questions unanswerable.
///
/// ## Why the inputs are strings and never `ConfigItem`s
///
/// `dynamic_value_diff.dart` exists because a diff written against
/// `DynamicValue` wrappers rather than their values marks every member changed
/// on every write: *"a trail that reports thirty changes for a jog is one
/// nobody reads: it looks complete, which is worse than looking empty"*.
///
/// The config analogue is `ConfigItem`, which *does* define equality — and
/// includes `rev`, `updatedAt` and `updatedBy`, all three of which move on
/// every write. A diff written against `ConfigItem ==` therefore reports every
/// entity changed on every save: the same failure in a different costume. So
/// the inputs here are the two `encodeEntity()` strings straight off the change
/// row.
///
/// `ConfigItem.sameContentAs` is not used either, and not because it is wrong —
/// it excludes exactly the three bookkeeping fields. It answers a bool, and
/// this function must answer a field list. It also could not be applied to a
/// historical row without first reconstructing an item from it.
///
/// ## Paths are rooted at the entity, not at the payload
///
/// `parent_id` and `sort_index` are top-level fields beside `payload.*`.
/// Moving an asset to another page or reordering it changes nothing *inside*
/// the asset, so a diff rooted at `payload` would report "no change" for a
/// move — throwing away the invariant `ConfigItem.toEntityJson` was introduced
/// to protect.
library;

import 'dart:convert';

import 'package:collection/collection.dart';

import '../rendered_value.dart';

/// One field of an entity that changed, ready to become one history row.
class FieldChange {
  const FieldChange({
    this.field,
    this.oldValue,
    this.newValue,
    this.noBaseline = false,
  });

  /// Dotted path within the entity — `payload.coordinates.x`, `parent_id`.
  /// Null when the change is the whole entity: an insert, a delete, or a side
  /// that could not be parsed.
  ///
  /// Never carries a list index. Lists are reported whole (see
  /// [diffConfigEntities]).
  final String? field;

  /// The rendering of the field before the change, or null when there was no
  /// value there at all — the key was absent.
  ///
  /// Null is a distinct answer from `'null'` on purpose. A key that is absent
  /// and a key that is present holding null are different states: `fromJson`
  /// defaults can make them mean different things, so normalising one onto the
  /// other here would hide serialization drift rather than label it. What the
  /// diff does instead is [suppress](diffConfigEntities) a change in which
  /// *both* sides are one of those two states, since no configuration moved.
  final String? oldValue;

  /// The rendering after the change, on the same terms as [oldValue].
  final String? newValue;

  /// True when there was no old entity at all to diff against — an insert.
  ///
  /// The row is then the whole new entity, marked, rather than N rows each
  /// falsely claiming its field changed.
  final bool noBaseline;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FieldChange &&
          other.field == field &&
          other.oldValue == oldValue &&
          other.newValue == newValue &&
          other.noBaseline == noBaseline;

  @override
  int get hashCode => Object.hash(field, oldValue, newValue, noBaseline);

  @override
  String toString() => 'FieldChange(${field ?? '<whole entity>'}: '
      '${oldValue ?? '<none>'} -> ${newValue ?? '<none>'}'
      '${noBaseline ? ', no baseline' : ''})';
}

/// The fields of [oldEntity] that [newEntity] changed.
///
/// Both arguments are `ConfigItem.encodeEntity()` strings — `{parent_id,
/// sort_index, payload}` — taken off a `config_change` row, and never anything
/// derived from a live `ConfigItem`. See the library doc for why.
///
/// Recursion continues only while **both** sides are maps. At every other pair
/// — scalar against scalar, list against anything, map against scalar — at most
/// one [FieldChange] is emitted for that path carrying the whole rendered
/// value. A field present on one side only is one change for the whole field
/// with no descent: an added object is one line saying it appeared, not a line
/// per member of something that had no previous shape.
///
/// Lists are compared structurally, element by element, and reported whole.
/// Structurally rather than by their renderings because two different long
/// lists truncate to the same 256 characters, and a diff that misses a change
/// because the values were long is the defect this file exists to remove.
/// Whole rather than per index because a reorder of a cable's waypoints is one
/// fact about the run, and `waypoints[0..39]` is not a trail anybody reads.
///
/// **The one suppression:** a change whose two sides are both "no value" —
/// absent against explicitly null, in either direction — emits nothing. Every
/// config class emits an explicit null for each unset optional, so adding a
/// nullable field to a `@JsonSerializable` makes the next save rewrite every
/// entity of that kind; without this rule that action renders as a wall of
/// rows each saying `payload.label_offset: <none> → null`. Suppressing the
/// display is all this file can do about it — the write already happened, and
/// preventing it is a write-path and migration concern.
///
/// A null [oldEntity] means no baseline and yields exactly one marked change.
/// A null [newEntity] — a delete read from the other direction — yields one
/// change whose new side is null.
///
/// A side that cannot be parsed is treated as an opaque whole entity and
/// reported as one change, never as a thrown exception and never as an empty
/// list: a change list silently emptied is worse than a blob, because it
/// asserts that nothing happened.
List<FieldChange> diffConfigEntities(String? oldEntity, String? newEntity) {
  if (oldEntity == null && newEntity == null) return const [];
  if (oldEntity == null) {
    return [
      FieldChange(newValue: _renderEntity(newEntity!), noBaseline: true),
    ];
  }
  if (newEntity == null) {
    return [FieldChange(oldValue: _renderEntity(oldEntity))];
  }

  final oldDecoded = _decodeOrNull(oldEntity);
  final newDecoded = _decodeOrNull(newEntity);
  if (oldDecoded == null || newDecoded == null) {
    // At least one side is not readable as an entity. The rendered forms are
    // all that is left; identical text is still no change.
    if (oldEntity == newEntity) return const [];
    return [
      FieldChange(
        oldValue: _renderEntity(oldEntity),
        newValue: _renderEntity(newEntity),
      ),
    ];
  }

  final changes = <FieldChange>[];
  _diffInto(changes, null, oldDecoded, newDecoded);
  return changes;
}

/// The entity [encoded] describes, or null when it is not a readable object.
Map<String, dynamic>? _decodeOrNull(String encoded) {
  try {
    final decoded = jsonDecode(encoded);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// A whole entity as one row string: the decoded shape when it parses, the raw
/// text when it does not, capped either way.
String _renderEntity(String encoded) {
  final decoded = _decodeOrNull(encoded);
  return renderJsonValue(decoded ?? encoded);
}

/// Appends to [changes] every difference between [oldMap] and [newMap] below
/// [path].
void _diffInto(
  List<FieldChange> changes,
  String? path,
  Map<String, dynamic> oldMap,
  Map<String, dynamic> newMap,
) {
  // The old entity's order first, then anything the new side added. Both sides
  // are canonically encoded, so in practice this is key order; keeping the
  // idiom means a payload written before the canonical encoding existed still
  // reads in a stable order.
  final names = <String>{...oldMap.keys, ...newMap.keys};
  for (final name in names) {
    final childPath = path == null ? name : '$path.$name';
    final oldHeld = oldMap.containsKey(name);
    final newHeld = newMap.containsKey(name);
    final oldValue = oldMap[name];
    final newValue = newMap[name];

    // Absent and explicitly null are both "no value". Neither side holding one
    // is not a configuration change, whichever way round they are.
    if ((!oldHeld || oldValue == null) && (!newHeld || newValue == null)) {
      continue;
    }

    if (!oldHeld || !newHeld) {
      // Present on one side only: one change for the whole field, no descent.
      changes.add(FieldChange(
        field: childPath,
        oldValue: oldHeld ? renderJsonValue(oldValue) : null,
        newValue: newHeld ? renderJsonValue(newValue) : null,
      ));
      continue;
    }

    if (oldValue is Map<String, dynamic> && newValue is Map<String, dynamic>) {
      _diffInto(changes, childPath, oldValue, newValue);
      continue;
    }

    if (!const DeepCollectionEquality().equals(oldValue, newValue)) {
      changes.add(FieldChange(
        field: childPath,
        oldValue: renderJsonValue(oldValue),
        newValue: renderJsonValue(newValue),
      ));
    }
  }
}
