// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'config_item_table.dart';

// ignore_for_file: type=lint
class $ConfigItemTableTable extends ConfigItemTable
    with TableInfo<$ConfigItemTableTable, ConfigItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConfigItemTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  @override
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
      'scope', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _parentIdMeta =
      const VerificationMeta('parentId');
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
      'parent_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sortIndexMeta =
      const VerificationMeta('sortIndex');
  @override
  late final GeneratedColumn<int> sortIndex = GeneratedColumn<int>(
      'sort_index', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _revMeta = const VerificationMeta('rev');
  @override
  late final GeneratedColumn<int> rev = GeneratedColumn<int>(
      'rev', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedByMeta =
      const VerificationMeta('updatedBy');
  @override
  late final GeneratedColumn<String> updatedBy = GeneratedColumn<String>(
      'updated_by', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        kind,
        id,
        scope,
        parentId,
        sortIndex,
        payload,
        rev,
        updatedAt,
        updatedBy
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'config_item';
  @override
  VerificationContext validateIntegrity(Insertable<ConfigItemRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('scope')) {
      context.handle(
          _scopeMeta, scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta));
    } else if (isInserting) {
      context.missing(_scopeMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(_parentIdMeta,
          parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta));
    }
    if (data.containsKey('sort_index')) {
      context.handle(_sortIndexMeta,
          sortIndex.isAcceptableOrUnknown(data['sort_index']!, _sortIndexMeta));
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('rev')) {
      context.handle(
          _revMeta, rev.isAcceptableOrUnknown(data['rev']!, _revMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('updated_by')) {
      context.handle(_updatedByMeta,
          updatedBy.isAcceptableOrUnknown(data['updated_by']!, _updatedByMeta));
    } else if (isInserting) {
      context.missing(_updatedByMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {kind, id, scope};
  @override
  ConfigItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConfigItemRow(
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      scope: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}scope'])!,
      parentId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}parent_id']),
      sortIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_index']),
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      rev: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rev'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
      updatedBy: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}updated_by'])!,
    );
  }

  @override
  $ConfigItemTableTable createAlias(String alias) {
    return $ConfigItemTableTable(attachedDatabase, alias);
  }
}

class ConfigItemRow extends DataClass implements Insertable<ConfigItemRow> {
  /// `ConfigKind.wireName` — the entity's type.
  final String kind;

  /// The entity's own id, unique within its kind and scope.
  final String id;

  /// `'shared'` or `'station:<hostname>'`, and the column that carries
  /// ownership: shared rows are Postgres-owned, station rows never leave the
  /// machine that wrote them. On Postgres a `CHECK` makes that structural —
  /// see the `from < 7` arm. Here it deliberately does not, because station
  /// rows are the only rows a local SQLite file will ever hold.
  final String scope;

  /// The entity this one belongs to — an asset's page id — or null when the
  /// kind has no parent. **No `REFERENCES`**, deliberately: see
  /// `ConfigItem.parentId`'s doc. An asset outlives its page during a move,
  /// and a constraint would turn a reorder into a delete and re-insert that
  /// the change log would report as a destroy and recreate.
  final String? parentId;

  /// Position among siblings, for kinds where order is meaning — a page's
  /// asset list is paint order. Null for kinds that are a set.
  final int? sortIndex;

  /// The entity's own JSON, canonically encoded.
  final String payload;

  /// Monotonic write counter, zero for a row written by a migration that had
  /// no counter to carry.
  ///
  /// `integer()`, not `int64()`: drift's postgres dialect already maps
  /// `integer()` to `bigint`, whereas `BigIntColumn` would change the *Dart*
  /// type to `BigInt` and break every arithmetic use of a revision number.
  final int rev;

  /// When the row was last written. TEXT on both backends — this database
  /// sets `storeDateTimeAsText: true`; see the note on [AppDatabase.options].
  final DateTime updatedAt;

  /// Username of whoever last wrote it, or `'anonymous'`.
  final String updatedBy;
  const ConfigItemRow(
      {required this.kind,
      required this.id,
      required this.scope,
      this.parentId,
      this.sortIndex,
      required this.payload,
      required this.rev,
      required this.updatedAt,
      required this.updatedBy});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['kind'] = Variable<String>(kind);
    map['id'] = Variable<String>(id);
    map['scope'] = Variable<String>(scope);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    if (!nullToAbsent || sortIndex != null) {
      map['sort_index'] = Variable<int>(sortIndex);
    }
    map['payload'] = Variable<String>(payload);
    map['rev'] = Variable<int>(rev);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['updated_by'] = Variable<String>(updatedBy);
    return map;
  }

  ConfigItemTableCompanion toCompanion(bool nullToAbsent) {
    return ConfigItemTableCompanion(
      kind: Value(kind),
      id: Value(id),
      scope: Value(scope),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortIndex: sortIndex == null && nullToAbsent
          ? const Value.absent()
          : Value(sortIndex),
      payload: Value(payload),
      rev: Value(rev),
      updatedAt: Value(updatedAt),
      updatedBy: Value(updatedBy),
    );
  }

  factory ConfigItemRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConfigItemRow(
      kind: serializer.fromJson<String>(json['kind']),
      id: serializer.fromJson<String>(json['id']),
      scope: serializer.fromJson<String>(json['scope']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      sortIndex: serializer.fromJson<int?>(json['sortIndex']),
      payload: serializer.fromJson<String>(json['payload']),
      rev: serializer.fromJson<int>(json['rev']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      updatedBy: serializer.fromJson<String>(json['updatedBy']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'kind': serializer.toJson<String>(kind),
      'id': serializer.toJson<String>(id),
      'scope': serializer.toJson<String>(scope),
      'parentId': serializer.toJson<String?>(parentId),
      'sortIndex': serializer.toJson<int?>(sortIndex),
      'payload': serializer.toJson<String>(payload),
      'rev': serializer.toJson<int>(rev),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'updatedBy': serializer.toJson<String>(updatedBy),
    };
  }

  ConfigItemRow copyWith(
          {String? kind,
          String? id,
          String? scope,
          Value<String?> parentId = const Value.absent(),
          Value<int?> sortIndex = const Value.absent(),
          String? payload,
          int? rev,
          DateTime? updatedAt,
          String? updatedBy}) =>
      ConfigItemRow(
        kind: kind ?? this.kind,
        id: id ?? this.id,
        scope: scope ?? this.scope,
        parentId: parentId.present ? parentId.value : this.parentId,
        sortIndex: sortIndex.present ? sortIndex.value : this.sortIndex,
        payload: payload ?? this.payload,
        rev: rev ?? this.rev,
        updatedAt: updatedAt ?? this.updatedAt,
        updatedBy: updatedBy ?? this.updatedBy,
      );
  ConfigItemRow copyWithCompanion(ConfigItemTableCompanion data) {
    return ConfigItemRow(
      kind: data.kind.present ? data.kind.value : this.kind,
      id: data.id.present ? data.id.value : this.id,
      scope: data.scope.present ? data.scope.value : this.scope,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortIndex: data.sortIndex.present ? data.sortIndex.value : this.sortIndex,
      payload: data.payload.present ? data.payload.value : this.payload,
      rev: data.rev.present ? data.rev.value : this.rev,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      updatedBy: data.updatedBy.present ? data.updatedBy.value : this.updatedBy,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConfigItemRow(')
          ..write('kind: $kind, ')
          ..write('id: $id, ')
          ..write('scope: $scope, ')
          ..write('parentId: $parentId, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('payload: $payload, ')
          ..write('rev: $rev, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('updatedBy: $updatedBy')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      kind, id, scope, parentId, sortIndex, payload, rev, updatedAt, updatedBy);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConfigItemRow &&
          other.kind == this.kind &&
          other.id == this.id &&
          other.scope == this.scope &&
          other.parentId == this.parentId &&
          other.sortIndex == this.sortIndex &&
          other.payload == this.payload &&
          other.rev == this.rev &&
          other.updatedAt == this.updatedAt &&
          other.updatedBy == this.updatedBy);
}

class ConfigItemTableCompanion extends UpdateCompanion<ConfigItemRow> {
  final Value<String> kind;
  final Value<String> id;
  final Value<String> scope;
  final Value<String?> parentId;
  final Value<int?> sortIndex;
  final Value<String> payload;
  final Value<int> rev;
  final Value<DateTime> updatedAt;
  final Value<String> updatedBy;
  final Value<int> rowid;
  const ConfigItemTableCompanion({
    this.kind = const Value.absent(),
    this.id = const Value.absent(),
    this.scope = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortIndex = const Value.absent(),
    this.payload = const Value.absent(),
    this.rev = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.updatedBy = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConfigItemTableCompanion.insert({
    required String kind,
    required String id,
    required String scope,
    this.parentId = const Value.absent(),
    this.sortIndex = const Value.absent(),
    required String payload,
    this.rev = const Value.absent(),
    required DateTime updatedAt,
    required String updatedBy,
    this.rowid = const Value.absent(),
  })  : kind = Value(kind),
        id = Value(id),
        scope = Value(scope),
        payload = Value(payload),
        updatedAt = Value(updatedAt),
        updatedBy = Value(updatedBy);
  static Insertable<ConfigItemRow> custom({
    Expression<String>? kind,
    Expression<String>? id,
    Expression<String>? scope,
    Expression<String>? parentId,
    Expression<int>? sortIndex,
    Expression<String>? payload,
    Expression<int>? rev,
    Expression<DateTime>? updatedAt,
    Expression<String>? updatedBy,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (kind != null) 'kind': kind,
      if (id != null) 'id': id,
      if (scope != null) 'scope': scope,
      if (parentId != null) 'parent_id': parentId,
      if (sortIndex != null) 'sort_index': sortIndex,
      if (payload != null) 'payload': payload,
      if (rev != null) 'rev': rev,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (updatedBy != null) 'updated_by': updatedBy,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConfigItemTableCompanion copyWith(
      {Value<String>? kind,
      Value<String>? id,
      Value<String>? scope,
      Value<String?>? parentId,
      Value<int?>? sortIndex,
      Value<String>? payload,
      Value<int>? rev,
      Value<DateTime>? updatedAt,
      Value<String>? updatedBy,
      Value<int>? rowid}) {
    return ConfigItemTableCompanion(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      scope: scope ?? this.scope,
      parentId: parentId ?? this.parentId,
      sortIndex: sortIndex ?? this.sortIndex,
      payload: payload ?? this.payload,
      rev: rev ?? this.rev,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (sortIndex.present) {
      map['sort_index'] = Variable<int>(sortIndex.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (rev.present) {
      map['rev'] = Variable<int>(rev.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (updatedBy.present) {
      map['updated_by'] = Variable<String>(updatedBy.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConfigItemTableCompanion(')
          ..write('kind: $kind, ')
          ..write('id: $id, ')
          ..write('scope: $scope, ')
          ..write('parentId: $parentId, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('payload: $payload, ')
          ..write('rev: $rev, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('updatedBy: $updatedBy, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConfigChangeTableTable extends ConfigChangeTable
    with TableInfo<$ConfigChangeTableTable, ConfigChangeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConfigChangeTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _atMeta = const VerificationMeta('at');
  @override
  late final GeneratedColumn<DateTime> at = GeneratedColumn<DateTime>(
      'at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _actionIdMeta =
      const VerificationMeta('actionId');
  @override
  late final GeneratedColumn<String> actionId = GeneratedColumn<String>(
      'action_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _whoMeta = const VerificationMeta('who');
  @override
  late final GeneratedColumn<String> who = GeneratedColumn<String>(
      'who', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _stationMeta =
      const VerificationMeta('station');
  @override
  late final GeneratedColumn<String> station = GeneratedColumn<String>(
      'station', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _roleNameMeta =
      const VerificationMeta('roleName');
  @override
  late final GeneratedColumn<String> roleName = GeneratedColumn<String>(
      'role_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
      'reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entityIdMeta =
      const VerificationMeta('entityId');
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
      'entity_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  @override
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
      'scope', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  @override
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
      'op', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _oldValueMeta =
      const VerificationMeta('oldValue');
  @override
  late final GeneratedColumn<String> oldValue = GeneratedColumn<String>(
      'old_value', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _newValueMeta =
      const VerificationMeta('newValue');
  @override
  late final GeneratedColumn<String> newValue = GeneratedColumn<String>(
      'new_value', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        at,
        actionId,
        who,
        station,
        roleName,
        reason,
        kind,
        entityId,
        scope,
        op,
        oldValue,
        newValue
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'config_change';
  @override
  VerificationContext validateIntegrity(Insertable<ConfigChangeRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('at')) {
      context.handle(_atMeta, at.isAcceptableOrUnknown(data['at']!, _atMeta));
    } else if (isInserting) {
      context.missing(_atMeta);
    }
    if (data.containsKey('action_id')) {
      context.handle(_actionIdMeta,
          actionId.isAcceptableOrUnknown(data['action_id']!, _actionIdMeta));
    } else if (isInserting) {
      context.missing(_actionIdMeta);
    }
    if (data.containsKey('who')) {
      context.handle(
          _whoMeta, who.isAcceptableOrUnknown(data['who']!, _whoMeta));
    } else if (isInserting) {
      context.missing(_whoMeta);
    }
    if (data.containsKey('station')) {
      context.handle(_stationMeta,
          station.isAcceptableOrUnknown(data['station']!, _stationMeta));
    } else if (isInserting) {
      context.missing(_stationMeta);
    }
    if (data.containsKey('role_name')) {
      context.handle(_roleNameMeta,
          roleName.isAcceptableOrUnknown(data['role_name']!, _roleNameMeta));
    } else if (isInserting) {
      context.missing(_roleNameMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(_reasonMeta,
          reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta));
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(_entityIdMeta,
          entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta));
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('scope')) {
      context.handle(
          _scopeMeta, scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta));
    } else if (isInserting) {
      context.missing(_scopeMeta);
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('old_value')) {
      context.handle(_oldValueMeta,
          oldValue.isAcceptableOrUnknown(data['old_value']!, _oldValueMeta));
    }
    if (data.containsKey('new_value')) {
      context.handle(_newValueMeta,
          newValue.isAcceptableOrUnknown(data['new_value']!, _newValueMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConfigChangeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConfigChangeRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      at: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}at'])!,
      actionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action_id'])!,
      who: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}who'])!,
      station: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}station'])!,
      roleName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role_name'])!,
      reason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reason']),
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      entityId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity_id'])!,
      scope: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}scope'])!,
      op: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}op'])!,
      oldValue: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}old_value']),
      newValue: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}new_value']),
    );
  }

  @override
  $ConfigChangeTableTable createAlias(String alias) {
    return $ConfigChangeTableTable(attachedDatabase, alias);
  }
}

class ConfigChangeRow extends DataClass implements Insertable<ConfigChangeRow> {
  /// Surrogate, and per-database: the SQLite log and the Postgres log are two
  /// independent id spaces and are not reconciled. Nothing joins them.
  final int id;

  /// When the change was made. TEXT on both backends, as [ConfigItemTable]'s
  /// `updatedAt` is.
  final DateTime at;

  /// Groups the rows written by one user action, so a save that touched nine
  /// assets reads as one operation rather than nine.
  final String actionId;

  /// Username, or `'anonymous'`.
  final String who;

  /// The hostname the change was made on.
  final String station;

  /// The role that authorised it, as it was named at the time.
  final String roleName;

  /// Free text from the operator, when the surface asked for one.
  final String? reason;

  /// `ConfigKind.wireName` of the entity that changed.
  final String kind;

  /// The changed entity's id — `config_item.id`, matched by value and with no
  /// foreign key, because the log outlives the row it describes: a delete's
  /// own entry would be unstorable otherwise.
  final String entityId;

  /// The changed entity's scope.
  final String scope;

  /// `ConfigChangeOp.wireName` — create, update or delete.
  final String op;

  /// The payload before, null on a create.
  final String? oldValue;

  /// The payload after, null on a delete.
  final String? newValue;
  const ConfigChangeRow(
      {required this.id,
      required this.at,
      required this.actionId,
      required this.who,
      required this.station,
      required this.roleName,
      this.reason,
      required this.kind,
      required this.entityId,
      required this.scope,
      required this.op,
      this.oldValue,
      this.newValue});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['at'] = Variable<DateTime>(at);
    map['action_id'] = Variable<String>(actionId);
    map['who'] = Variable<String>(who);
    map['station'] = Variable<String>(station);
    map['role_name'] = Variable<String>(roleName);
    if (!nullToAbsent || reason != null) {
      map['reason'] = Variable<String>(reason);
    }
    map['kind'] = Variable<String>(kind);
    map['entity_id'] = Variable<String>(entityId);
    map['scope'] = Variable<String>(scope);
    map['op'] = Variable<String>(op);
    if (!nullToAbsent || oldValue != null) {
      map['old_value'] = Variable<String>(oldValue);
    }
    if (!nullToAbsent || newValue != null) {
      map['new_value'] = Variable<String>(newValue);
    }
    return map;
  }

  ConfigChangeTableCompanion toCompanion(bool nullToAbsent) {
    return ConfigChangeTableCompanion(
      id: Value(id),
      at: Value(at),
      actionId: Value(actionId),
      who: Value(who),
      station: Value(station),
      roleName: Value(roleName),
      reason:
          reason == null && nullToAbsent ? const Value.absent() : Value(reason),
      kind: Value(kind),
      entityId: Value(entityId),
      scope: Value(scope),
      op: Value(op),
      oldValue: oldValue == null && nullToAbsent
          ? const Value.absent()
          : Value(oldValue),
      newValue: newValue == null && nullToAbsent
          ? const Value.absent()
          : Value(newValue),
    );
  }

  factory ConfigChangeRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConfigChangeRow(
      id: serializer.fromJson<int>(json['id']),
      at: serializer.fromJson<DateTime>(json['at']),
      actionId: serializer.fromJson<String>(json['actionId']),
      who: serializer.fromJson<String>(json['who']),
      station: serializer.fromJson<String>(json['station']),
      roleName: serializer.fromJson<String>(json['roleName']),
      reason: serializer.fromJson<String?>(json['reason']),
      kind: serializer.fromJson<String>(json['kind']),
      entityId: serializer.fromJson<String>(json['entityId']),
      scope: serializer.fromJson<String>(json['scope']),
      op: serializer.fromJson<String>(json['op']),
      oldValue: serializer.fromJson<String?>(json['oldValue']),
      newValue: serializer.fromJson<String?>(json['newValue']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'at': serializer.toJson<DateTime>(at),
      'actionId': serializer.toJson<String>(actionId),
      'who': serializer.toJson<String>(who),
      'station': serializer.toJson<String>(station),
      'roleName': serializer.toJson<String>(roleName),
      'reason': serializer.toJson<String?>(reason),
      'kind': serializer.toJson<String>(kind),
      'entityId': serializer.toJson<String>(entityId),
      'scope': serializer.toJson<String>(scope),
      'op': serializer.toJson<String>(op),
      'oldValue': serializer.toJson<String?>(oldValue),
      'newValue': serializer.toJson<String?>(newValue),
    };
  }

  ConfigChangeRow copyWith(
          {int? id,
          DateTime? at,
          String? actionId,
          String? who,
          String? station,
          String? roleName,
          Value<String?> reason = const Value.absent(),
          String? kind,
          String? entityId,
          String? scope,
          String? op,
          Value<String?> oldValue = const Value.absent(),
          Value<String?> newValue = const Value.absent()}) =>
      ConfigChangeRow(
        id: id ?? this.id,
        at: at ?? this.at,
        actionId: actionId ?? this.actionId,
        who: who ?? this.who,
        station: station ?? this.station,
        roleName: roleName ?? this.roleName,
        reason: reason.present ? reason.value : this.reason,
        kind: kind ?? this.kind,
        entityId: entityId ?? this.entityId,
        scope: scope ?? this.scope,
        op: op ?? this.op,
        oldValue: oldValue.present ? oldValue.value : this.oldValue,
        newValue: newValue.present ? newValue.value : this.newValue,
      );
  ConfigChangeRow copyWithCompanion(ConfigChangeTableCompanion data) {
    return ConfigChangeRow(
      id: data.id.present ? data.id.value : this.id,
      at: data.at.present ? data.at.value : this.at,
      actionId: data.actionId.present ? data.actionId.value : this.actionId,
      who: data.who.present ? data.who.value : this.who,
      station: data.station.present ? data.station.value : this.station,
      roleName: data.roleName.present ? data.roleName.value : this.roleName,
      reason: data.reason.present ? data.reason.value : this.reason,
      kind: data.kind.present ? data.kind.value : this.kind,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      scope: data.scope.present ? data.scope.value : this.scope,
      op: data.op.present ? data.op.value : this.op,
      oldValue: data.oldValue.present ? data.oldValue.value : this.oldValue,
      newValue: data.newValue.present ? data.newValue.value : this.newValue,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConfigChangeRow(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('actionId: $actionId, ')
          ..write('who: $who, ')
          ..write('station: $station, ')
          ..write('roleName: $roleName, ')
          ..write('reason: $reason, ')
          ..write('kind: $kind, ')
          ..write('entityId: $entityId, ')
          ..write('scope: $scope, ')
          ..write('op: $op, ')
          ..write('oldValue: $oldValue, ')
          ..write('newValue: $newValue')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, at, actionId, who, station, roleName,
      reason, kind, entityId, scope, op, oldValue, newValue);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConfigChangeRow &&
          other.id == this.id &&
          other.at == this.at &&
          other.actionId == this.actionId &&
          other.who == this.who &&
          other.station == this.station &&
          other.roleName == this.roleName &&
          other.reason == this.reason &&
          other.kind == this.kind &&
          other.entityId == this.entityId &&
          other.scope == this.scope &&
          other.op == this.op &&
          other.oldValue == this.oldValue &&
          other.newValue == this.newValue);
}

class ConfigChangeTableCompanion extends UpdateCompanion<ConfigChangeRow> {
  final Value<int> id;
  final Value<DateTime> at;
  final Value<String> actionId;
  final Value<String> who;
  final Value<String> station;
  final Value<String> roleName;
  final Value<String?> reason;
  final Value<String> kind;
  final Value<String> entityId;
  final Value<String> scope;
  final Value<String> op;
  final Value<String?> oldValue;
  final Value<String?> newValue;
  const ConfigChangeTableCompanion({
    this.id = const Value.absent(),
    this.at = const Value.absent(),
    this.actionId = const Value.absent(),
    this.who = const Value.absent(),
    this.station = const Value.absent(),
    this.roleName = const Value.absent(),
    this.reason = const Value.absent(),
    this.kind = const Value.absent(),
    this.entityId = const Value.absent(),
    this.scope = const Value.absent(),
    this.op = const Value.absent(),
    this.oldValue = const Value.absent(),
    this.newValue = const Value.absent(),
  });
  ConfigChangeTableCompanion.insert({
    this.id = const Value.absent(),
    required DateTime at,
    required String actionId,
    required String who,
    required String station,
    required String roleName,
    this.reason = const Value.absent(),
    required String kind,
    required String entityId,
    required String scope,
    required String op,
    this.oldValue = const Value.absent(),
    this.newValue = const Value.absent(),
  })  : at = Value(at),
        actionId = Value(actionId),
        who = Value(who),
        station = Value(station),
        roleName = Value(roleName),
        kind = Value(kind),
        entityId = Value(entityId),
        scope = Value(scope),
        op = Value(op);
  static Insertable<ConfigChangeRow> custom({
    Expression<int>? id,
    Expression<DateTime>? at,
    Expression<String>? actionId,
    Expression<String>? who,
    Expression<String>? station,
    Expression<String>? roleName,
    Expression<String>? reason,
    Expression<String>? kind,
    Expression<String>? entityId,
    Expression<String>? scope,
    Expression<String>? op,
    Expression<String>? oldValue,
    Expression<String>? newValue,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (at != null) 'at': at,
      if (actionId != null) 'action_id': actionId,
      if (who != null) 'who': who,
      if (station != null) 'station': station,
      if (roleName != null) 'role_name': roleName,
      if (reason != null) 'reason': reason,
      if (kind != null) 'kind': kind,
      if (entityId != null) 'entity_id': entityId,
      if (scope != null) 'scope': scope,
      if (op != null) 'op': op,
      if (oldValue != null) 'old_value': oldValue,
      if (newValue != null) 'new_value': newValue,
    });
  }

  ConfigChangeTableCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? at,
      Value<String>? actionId,
      Value<String>? who,
      Value<String>? station,
      Value<String>? roleName,
      Value<String?>? reason,
      Value<String>? kind,
      Value<String>? entityId,
      Value<String>? scope,
      Value<String>? op,
      Value<String?>? oldValue,
      Value<String?>? newValue}) {
    return ConfigChangeTableCompanion(
      id: id ?? this.id,
      at: at ?? this.at,
      actionId: actionId ?? this.actionId,
      who: who ?? this.who,
      station: station ?? this.station,
      roleName: roleName ?? this.roleName,
      reason: reason ?? this.reason,
      kind: kind ?? this.kind,
      entityId: entityId ?? this.entityId,
      scope: scope ?? this.scope,
      op: op ?? this.op,
      oldValue: oldValue ?? this.oldValue,
      newValue: newValue ?? this.newValue,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (at.present) {
      map['at'] = Variable<DateTime>(at.value);
    }
    if (actionId.present) {
      map['action_id'] = Variable<String>(actionId.value);
    }
    if (who.present) {
      map['who'] = Variable<String>(who.value);
    }
    if (station.present) {
      map['station'] = Variable<String>(station.value);
    }
    if (roleName.present) {
      map['role_name'] = Variable<String>(roleName.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (oldValue.present) {
      map['old_value'] = Variable<String>(oldValue.value);
    }
    if (newValue.present) {
      map['new_value'] = Variable<String>(newValue.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConfigChangeTableCompanion(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('actionId: $actionId, ')
          ..write('who: $who, ')
          ..write('station: $station, ')
          ..write('roleName: $roleName, ')
          ..write('reason: $reason, ')
          ..write('kind: $kind, ')
          ..write('entityId: $entityId, ')
          ..write('scope: $scope, ')
          ..write('op: $op, ')
          ..write('oldValue: $oldValue, ')
          ..write('newValue: $newValue')
          ..write(')'))
        .toString();
  }
}

abstract class _$ConfigItemSchema extends GeneratedDatabase {
  _$ConfigItemSchema(QueryExecutor e) : super(e);
  $ConfigItemSchemaManager get managers => $ConfigItemSchemaManager(this);
  late final $ConfigItemTableTable configItemTable =
      $ConfigItemTableTable(this);
  late final $ConfigChangeTableTable configChangeTable =
      $ConfigChangeTableTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [configItemTable, configChangeTable];
}

typedef $$ConfigItemTableTableCreateCompanionBuilder = ConfigItemTableCompanion
    Function({
  required String kind,
  required String id,
  required String scope,
  Value<String?> parentId,
  Value<int?> sortIndex,
  required String payload,
  Value<int> rev,
  required DateTime updatedAt,
  required String updatedBy,
  Value<int> rowid,
});
typedef $$ConfigItemTableTableUpdateCompanionBuilder = ConfigItemTableCompanion
    Function({
  Value<String> kind,
  Value<String> id,
  Value<String> scope,
  Value<String?> parentId,
  Value<int?> sortIndex,
  Value<String> payload,
  Value<int> rev,
  Value<DateTime> updatedAt,
  Value<String> updatedBy,
  Value<int> rowid,
});

class $$ConfigItemTableTableFilterComposer
    extends Composer<_$ConfigItemSchema, $ConfigItemTableTable> {
  $$ConfigItemTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get scope => $composableBuilder(
      column: $table.scope, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get parentId => $composableBuilder(
      column: $table.parentId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortIndex => $composableBuilder(
      column: $table.sortIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get rev => $composableBuilder(
      column: $table.rev, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get updatedBy => $composableBuilder(
      column: $table.updatedBy, builder: (column) => ColumnFilters(column));
}

class $$ConfigItemTableTableOrderingComposer
    extends Composer<_$ConfigItemSchema, $ConfigItemTableTable> {
  $$ConfigItemTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get scope => $composableBuilder(
      column: $table.scope, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get parentId => $composableBuilder(
      column: $table.parentId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortIndex => $composableBuilder(
      column: $table.sortIndex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payload => $composableBuilder(
      column: $table.payload, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get rev => $composableBuilder(
      column: $table.rev, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get updatedBy => $composableBuilder(
      column: $table.updatedBy, builder: (column) => ColumnOrderings(column));
}

class $$ConfigItemTableTableAnnotationComposer
    extends Composer<_$ConfigItemSchema, $ConfigItemTableTable> {
  $$ConfigItemTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get scope =>
      $composableBuilder(column: $table.scope, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<int> get sortIndex =>
      $composableBuilder(column: $table.sortIndex, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get rev =>
      $composableBuilder(column: $table.rev, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get updatedBy =>
      $composableBuilder(column: $table.updatedBy, builder: (column) => column);
}

class $$ConfigItemTableTableTableManager extends RootTableManager<
    _$ConfigItemSchema,
    $ConfigItemTableTable,
    ConfigItemRow,
    $$ConfigItemTableTableFilterComposer,
    $$ConfigItemTableTableOrderingComposer,
    $$ConfigItemTableTableAnnotationComposer,
    $$ConfigItemTableTableCreateCompanionBuilder,
    $$ConfigItemTableTableUpdateCompanionBuilder,
    (
      ConfigItemRow,
      BaseReferences<_$ConfigItemSchema, $ConfigItemTableTable, ConfigItemRow>
    ),
    ConfigItemRow,
    PrefetchHooks Function()> {
  $$ConfigItemTableTableTableManager(
      _$ConfigItemSchema db, $ConfigItemTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConfigItemTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConfigItemTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConfigItemTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> kind = const Value.absent(),
            Value<String> id = const Value.absent(),
            Value<String> scope = const Value.absent(),
            Value<String?> parentId = const Value.absent(),
            Value<int?> sortIndex = const Value.absent(),
            Value<String> payload = const Value.absent(),
            Value<int> rev = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<String> updatedBy = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ConfigItemTableCompanion(
            kind: kind,
            id: id,
            scope: scope,
            parentId: parentId,
            sortIndex: sortIndex,
            payload: payload,
            rev: rev,
            updatedAt: updatedAt,
            updatedBy: updatedBy,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String kind,
            required String id,
            required String scope,
            Value<String?> parentId = const Value.absent(),
            Value<int?> sortIndex = const Value.absent(),
            required String payload,
            Value<int> rev = const Value.absent(),
            required DateTime updatedAt,
            required String updatedBy,
            Value<int> rowid = const Value.absent(),
          }) =>
              ConfigItemTableCompanion.insert(
            kind: kind,
            id: id,
            scope: scope,
            parentId: parentId,
            sortIndex: sortIndex,
            payload: payload,
            rev: rev,
            updatedAt: updatedAt,
            updatedBy: updatedBy,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ConfigItemTableTableProcessedTableManager = ProcessedTableManager<
    _$ConfigItemSchema,
    $ConfigItemTableTable,
    ConfigItemRow,
    $$ConfigItemTableTableFilterComposer,
    $$ConfigItemTableTableOrderingComposer,
    $$ConfigItemTableTableAnnotationComposer,
    $$ConfigItemTableTableCreateCompanionBuilder,
    $$ConfigItemTableTableUpdateCompanionBuilder,
    (
      ConfigItemRow,
      BaseReferences<_$ConfigItemSchema, $ConfigItemTableTable, ConfigItemRow>
    ),
    ConfigItemRow,
    PrefetchHooks Function()>;
typedef $$ConfigChangeTableTableCreateCompanionBuilder
    = ConfigChangeTableCompanion Function({
  Value<int> id,
  required DateTime at,
  required String actionId,
  required String who,
  required String station,
  required String roleName,
  Value<String?> reason,
  required String kind,
  required String entityId,
  required String scope,
  required String op,
  Value<String?> oldValue,
  Value<String?> newValue,
});
typedef $$ConfigChangeTableTableUpdateCompanionBuilder
    = ConfigChangeTableCompanion Function({
  Value<int> id,
  Value<DateTime> at,
  Value<String> actionId,
  Value<String> who,
  Value<String> station,
  Value<String> roleName,
  Value<String?> reason,
  Value<String> kind,
  Value<String> entityId,
  Value<String> scope,
  Value<String> op,
  Value<String?> oldValue,
  Value<String?> newValue,
});

class $$ConfigChangeTableTableFilterComposer
    extends Composer<_$ConfigItemSchema, $ConfigChangeTableTable> {
  $$ConfigChangeTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get at => $composableBuilder(
      column: $table.at, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actionId => $composableBuilder(
      column: $table.actionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get who => $composableBuilder(
      column: $table.who, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get station => $composableBuilder(
      column: $table.station, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get roleName => $composableBuilder(
      column: $table.roleName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reason => $composableBuilder(
      column: $table.reason, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get scope => $composableBuilder(
      column: $table.scope, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get op => $composableBuilder(
      column: $table.op, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get oldValue => $composableBuilder(
      column: $table.oldValue, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get newValue => $composableBuilder(
      column: $table.newValue, builder: (column) => ColumnFilters(column));
}

class $$ConfigChangeTableTableOrderingComposer
    extends Composer<_$ConfigItemSchema, $ConfigChangeTableTable> {
  $$ConfigChangeTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get at => $composableBuilder(
      column: $table.at, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actionId => $composableBuilder(
      column: $table.actionId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get who => $composableBuilder(
      column: $table.who, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get station => $composableBuilder(
      column: $table.station, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get roleName => $composableBuilder(
      column: $table.roleName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reason => $composableBuilder(
      column: $table.reason, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entityId => $composableBuilder(
      column: $table.entityId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get scope => $composableBuilder(
      column: $table.scope, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get op => $composableBuilder(
      column: $table.op, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get oldValue => $composableBuilder(
      column: $table.oldValue, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get newValue => $composableBuilder(
      column: $table.newValue, builder: (column) => ColumnOrderings(column));
}

class $$ConfigChangeTableTableAnnotationComposer
    extends Composer<_$ConfigItemSchema, $ConfigChangeTableTable> {
  $$ConfigChangeTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get at =>
      $composableBuilder(column: $table.at, builder: (column) => column);

  GeneratedColumn<String> get actionId =>
      $composableBuilder(column: $table.actionId, builder: (column) => column);

  GeneratedColumn<String> get who =>
      $composableBuilder(column: $table.who, builder: (column) => column);

  GeneratedColumn<String> get station =>
      $composableBuilder(column: $table.station, builder: (column) => column);

  GeneratedColumn<String> get roleName =>
      $composableBuilder(column: $table.roleName, builder: (column) => column);

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get scope =>
      $composableBuilder(column: $table.scope, builder: (column) => column);

  GeneratedColumn<String> get op =>
      $composableBuilder(column: $table.op, builder: (column) => column);

  GeneratedColumn<String> get oldValue =>
      $composableBuilder(column: $table.oldValue, builder: (column) => column);

  GeneratedColumn<String> get newValue =>
      $composableBuilder(column: $table.newValue, builder: (column) => column);
}

class $$ConfigChangeTableTableTableManager extends RootTableManager<
    _$ConfigItemSchema,
    $ConfigChangeTableTable,
    ConfigChangeRow,
    $$ConfigChangeTableTableFilterComposer,
    $$ConfigChangeTableTableOrderingComposer,
    $$ConfigChangeTableTableAnnotationComposer,
    $$ConfigChangeTableTableCreateCompanionBuilder,
    $$ConfigChangeTableTableUpdateCompanionBuilder,
    (
      ConfigChangeRow,
      BaseReferences<_$ConfigItemSchema, $ConfigChangeTableTable,
          ConfigChangeRow>
    ),
    ConfigChangeRow,
    PrefetchHooks Function()> {
  $$ConfigChangeTableTableTableManager(
      _$ConfigItemSchema db, $ConfigChangeTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConfigChangeTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConfigChangeTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConfigChangeTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> at = const Value.absent(),
            Value<String> actionId = const Value.absent(),
            Value<String> who = const Value.absent(),
            Value<String> station = const Value.absent(),
            Value<String> roleName = const Value.absent(),
            Value<String?> reason = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String> entityId = const Value.absent(),
            Value<String> scope = const Value.absent(),
            Value<String> op = const Value.absent(),
            Value<String?> oldValue = const Value.absent(),
            Value<String?> newValue = const Value.absent(),
          }) =>
              ConfigChangeTableCompanion(
            id: id,
            at: at,
            actionId: actionId,
            who: who,
            station: station,
            roleName: roleName,
            reason: reason,
            kind: kind,
            entityId: entityId,
            scope: scope,
            op: op,
            oldValue: oldValue,
            newValue: newValue,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required DateTime at,
            required String actionId,
            required String who,
            required String station,
            required String roleName,
            Value<String?> reason = const Value.absent(),
            required String kind,
            required String entityId,
            required String scope,
            required String op,
            Value<String?> oldValue = const Value.absent(),
            Value<String?> newValue = const Value.absent(),
          }) =>
              ConfigChangeTableCompanion.insert(
            id: id,
            at: at,
            actionId: actionId,
            who: who,
            station: station,
            roleName: roleName,
            reason: reason,
            kind: kind,
            entityId: entityId,
            scope: scope,
            op: op,
            oldValue: oldValue,
            newValue: newValue,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ConfigChangeTableTableProcessedTableManager = ProcessedTableManager<
    _$ConfigItemSchema,
    $ConfigChangeTableTable,
    ConfigChangeRow,
    $$ConfigChangeTableTableFilterComposer,
    $$ConfigChangeTableTableOrderingComposer,
    $$ConfigChangeTableTableAnnotationComposer,
    $$ConfigChangeTableTableCreateCompanionBuilder,
    $$ConfigChangeTableTableUpdateCompanionBuilder,
    (
      ConfigChangeRow,
      BaseReferences<_$ConfigItemSchema, $ConfigChangeTableTable,
          ConfigChangeRow>
    ),
    ConfigChangeRow,
    PrefetchHooks Function()>;

class $ConfigItemSchemaManager {
  final _$ConfigItemSchema _db;
  $ConfigItemSchemaManager(this._db);
  $$ConfigItemTableTableTableManager get configItemTable =>
      $$ConfigItemTableTableTableManager(_db, _db.configItemTable);
  $$ConfigChangeTableTableTableManager get configChangeTable =>
      $$ConfigChangeTableTableTableManager(_db, _db.configChangeTable);
}
