/// One append-only row of the configuration history.
///
/// See `config_item.dart` for the row shape this records changes to, and
/// `docs/relational-config-research.md` §3.2 for why the history is a separate
/// append-only log rather than validity ranges on the rows themselves.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'config_item.dart';

/// What happened to an entity in one change.
///
/// Wire values are stored in `config_change.op` and are permanent, as
/// [ConfigKind.wireName] is.
enum ConfigChangeOp {
  insert('insert'),
  update('update'),
  delete('delete');

  const ConfigChangeOp(this.wireName);

  final String wireName;

  static ConfigChangeOp? byWireName(String wireName) =>
      values.firstWhereOrNull((o) => o.wireName == wireName);
}

/// One append-only row of the configuration history.
///
/// ## Why the whole entity, and not a field-level diff
///
/// [oldValue] and [newValue] carry the entity's complete payload on each side.
/// An asset is a few hundred to a couple of thousand bytes, so storing both is
/// nearly free, and it makes a restore exact: putting the entity back is
/// writing [oldValue], with nothing to reconstruct and nothing to get wrong.
///
/// Reducing that to "which fields moved" is a *display* concern, computed on
/// read the way `access/dynamic_value_diff.dart` reduces a whole-struct tag
/// write to the members that changed. Doing it on write would mean the stored
/// history could only answer the questions the writer thought of.
///
/// ## The join to the audit trail
///
/// [actionId] is `AuditRecord.actionId`. One human action — a page save — is
/// one `audit_entry` row and N of these beneath it, which is exactly the
/// relationship that field's contract already describes ("one human action is
/// one actionId with N rows beneath it, so a recipe apply reads as one action
/// rather than N unrelated rows"). Today a page save instead produces a single
/// audit row holding a 145 kB before-image and a 145 kB after-image, which is
/// complete and unreadable.
///
/// ## Append-only
///
/// Never updated, never deleted — the same rule `AuditSink` states for the
/// trail, for the same reason. A rollback is itself a write: it produces its
/// own [actionId] and its own change rows, so the history shows that a restore
/// happened rather than quietly looking as though the intervening edits never
/// did.
@immutable
class ConfigChange {
  const ConfigChange({
    required this.at,
    required this.actionId,
    required this.who,
    required this.station,
    required this.roleName,
    required this.kind,
    required this.entityId,
    required this.scope,
    required this.op,
    this.oldValue,
    this.newValue,
    this.reason,
  });

  /// An entity that did not exist before.
  factory ConfigChange.insert({
    required DateTime at,
    required String actionId,
    required String who,
    required String station,
    required String roleName,
    required ConfigKind kind,
    required String entityId,
    required ConfigScope scope,
    required String newValue,
    String? reason,
  }) =>
      ConfigChange(
        at: at,
        actionId: actionId,
        who: who,
        station: station,
        roleName: roleName,
        kind: kind,
        entityId: entityId,
        scope: scope,
        op: ConfigChangeOp.insert,
        newValue: newValue,
        reason: reason,
      );

  /// An entity that changed. Both sides are present, always: an update whose
  /// old side is unknown cannot be rolled back, and is the one case where a
  /// half-recorded row is worse than none.
  factory ConfigChange.update({
    required DateTime at,
    required String actionId,
    required String who,
    required String station,
    required String roleName,
    required ConfigKind kind,
    required String entityId,
    required ConfigScope scope,
    required String oldValue,
    required String newValue,
    String? reason,
  }) =>
      ConfigChange(
        at: at,
        actionId: actionId,
        who: who,
        station: station,
        roleName: roleName,
        kind: kind,
        entityId: entityId,
        scope: scope,
        op: ConfigChangeOp.update,
        oldValue: oldValue,
        newValue: newValue,
        reason: reason,
      );

  /// An entity that is gone. [oldValue] is what it held, so the row still says
  /// what was lost after the thing it described no longer exists — the same
  /// reason `AuditRecord.roleDelete` carries the deleted role's group set.
  factory ConfigChange.delete({
    required DateTime at,
    required String actionId,
    required String who,
    required String station,
    required String roleName,
    required ConfigKind kind,
    required String entityId,
    required ConfigScope scope,
    required String oldValue,
    String? reason,
  }) =>
      ConfigChange(
        at: at,
        actionId: actionId,
        who: who,
        station: station,
        roleName: roleName,
        kind: kind,
        entityId: entityId,
        scope: scope,
        op: ConfigChangeOp.delete,
        oldValue: oldValue,
        reason: reason,
      );

  /// When it happened.
  final DateTime at;

  /// Correlation id, shared with the `audit_entry` row for the same action.
  final String actionId;

  /// Username, or `'anonymous'`.
  final String who;

  /// Hostname of the station the change came from.
  final String station;

  /// The role in force at the time.
  final String roleName;

  /// What kind of entity this row describes.
  final ConfigKind kind;

  /// The entity's primary key: a page path, an `Asset.id`, a mapping key.
  final String entityId;

  /// Which store owned the entity. Part of its identity, so a station's own
  /// setting and the shared one of the same name are two histories rather than
  /// one interleaved and unreadable one.
  final ConfigScope scope;

  /// Whether the entity appeared, changed or went away.
  final ConfigChangeOp op;

  /// The entity's complete payload before the change. Null only on an insert.
  final String? oldValue;

  /// The entity's complete payload after the change. Null only on a delete.
  final String? newValue;

  /// Free text captured on the action, mirroring `AuditRecord.reason`. Reason
  /// is what turns a log into an audit trail.
  final String? reason;

  /// The payload that undoing this change would write, or null when undoing it
  /// means deleting the entity.
  ///
  /// The inverse of an insert is a delete, so this is null there; the inverse
  /// of a delete is re-inserting [oldValue]; the inverse of an update is
  /// writing [oldValue] back.
  String? get inverseValue => op == ConfigChangeOp.insert ? null : oldValue;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigChange &&
          other.at == at &&
          other.actionId == actionId &&
          other.who == who &&
          other.station == station &&
          other.roleName == roleName &&
          other.kind == kind &&
          other.entityId == entityId &&
          other.scope == scope &&
          other.op == op &&
          other.oldValue == oldValue &&
          other.newValue == newValue &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(at, actionId, who, station, roleName, kind,
      entityId, scope, op, oldValue, newValue, reason);

  @override
  String toString() => 'ConfigChange($at ${op.wireName} '
      '${kind.wireName}:$entityId@$scope by $who@$station as $roleName, '
      'action: $actionId)';
}
