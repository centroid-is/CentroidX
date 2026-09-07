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

abstract class _$ConfigItemSchema extends GeneratedDatabase {
  _$ConfigItemSchema(QueryExecutor e) : super(e);
  $ConfigItemSchemaManager get managers => $ConfigItemSchemaManager(this);
  late final $ConfigItemTableTable configItemTable =
      $ConfigItemTableTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [configItemTable];
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

class $ConfigItemSchemaManager {
  final _$ConfigItemSchema _db;
  $ConfigItemSchemaManager(this._db);
  $$ConfigItemTableTableTableManager get configItemTable =>
      $$ConfigItemTableTableTableManager(_db, _db.configItemTable);
}
