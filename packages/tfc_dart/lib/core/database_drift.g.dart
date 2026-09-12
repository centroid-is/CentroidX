// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database_drift.dart';

// ignore_for_file: type=lint
class $AlarmTable extends Alarm with TableInfo<$AlarmTable, AlarmConfig> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AlarmTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
      'uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _descriptionMeta =
      const VerificationMeta('description');
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
      'description', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rulesMeta = const VerificationMeta('rules');
  @override
  late final GeneratedColumn<String> rules = GeneratedColumn<String>(
      'rules', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [uid, key, title, description, rules];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'alarm';
  @override
  VerificationContext validateIntegrity(Insertable<AlarmConfig> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('uid')) {
      context.handle(
          _uidMeta, uid.isAcceptableOrUnknown(data['uid']!, _uidMeta));
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
          _descriptionMeta,
          description.isAcceptableOrUnknown(
              data['description']!, _descriptionMeta));
    } else if (isInserting) {
      context.missing(_descriptionMeta);
    }
    if (data.containsKey('rules')) {
      context.handle(
          _rulesMeta, rules.isAcceptableOrUnknown(data['rules']!, _rulesMeta));
    } else if (isInserting) {
      context.missing(_rulesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uid};
  @override
  AlarmConfig map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AlarmConfig.fromDb(
      uid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uid'])!,
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key']),
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      description: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}description'])!,
      rules: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rules'])!,
    );
  }

  @override
  $AlarmTable createAlias(String alias) {
    return $AlarmTable(attachedDatabase, alias);
  }
}

class AlarmCompanion extends UpdateCompanion<AlarmConfig> {
  final Value<String> uid;
  final Value<String?> key;
  final Value<String> title;
  final Value<String> description;
  final Value<String> rules;
  final Value<int> rowid;
  const AlarmCompanion({
    this.uid = const Value.absent(),
    this.key = const Value.absent(),
    this.title = const Value.absent(),
    this.description = const Value.absent(),
    this.rules = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AlarmCompanion.insert({
    required String uid,
    this.key = const Value.absent(),
    required String title,
    required String description,
    required String rules,
    this.rowid = const Value.absent(),
  })  : uid = Value(uid),
        title = Value(title),
        description = Value(description),
        rules = Value(rules);
  static Insertable<AlarmConfig> custom({
    Expression<String>? uid,
    Expression<String>? key,
    Expression<String>? title,
    Expression<String>? description,
    Expression<String>? rules,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (uid != null) 'uid': uid,
      if (key != null) 'key': key,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (rules != null) 'rules': rules,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AlarmCompanion copyWith(
      {Value<String>? uid,
      Value<String?>? key,
      Value<String>? title,
      Value<String>? description,
      Value<String>? rules,
      Value<int>? rowid}) {
    return AlarmCompanion(
      uid: uid ?? this.uid,
      key: key ?? this.key,
      title: title ?? this.title,
      description: description ?? this.description,
      rules: rules ?? this.rules,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (rules.present) {
      map['rules'] = Variable<String>(rules.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AlarmCompanion(')
          ..write('uid: $uid, ')
          ..write('key: $key, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('rules: $rules, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AlarmHistoryTable extends AlarmHistory
    with TableInfo<$AlarmHistoryTable, AlarmHistoryData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AlarmHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _alarmUidMeta =
      const VerificationMeta('alarmUid');
  @override
  late final GeneratedColumn<String> alarmUid = GeneratedColumn<String>(
      'alarm_uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES alarm (uid)'));
  static const VerificationMeta _alarmTitleMeta =
      const VerificationMeta('alarmTitle');
  @override
  late final GeneratedColumn<String> alarmTitle = GeneratedColumn<String>(
      'alarm_title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _alarmDescriptionMeta =
      const VerificationMeta('alarmDescription');
  @override
  late final GeneratedColumn<String> alarmDescription = GeneratedColumn<String>(
      'alarm_description', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _alarmLevelMeta =
      const VerificationMeta('alarmLevel');
  @override
  late final GeneratedColumn<String> alarmLevel = GeneratedColumn<String>(
      'alarm_level', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _expressionMeta =
      const VerificationMeta('expression');
  @override
  late final GeneratedColumn<String> expression = GeneratedColumn<String>(
      'expression', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _activeMeta = const VerificationMeta('active');
  @override
  late final GeneratedColumn<bool> active = GeneratedColumn<bool>(
      'active', aliasedName, false,
      type: DriftSqlType.bool, requiredDuringInsert: true);
  static const VerificationMeta _pendingAckMeta =
      const VerificationMeta('pendingAck');
  @override
  late final GeneratedColumn<bool> pendingAck = GeneratedColumn<bool>(
      'pending_ack', aliasedName, false,
      type: DriftSqlType.bool, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _deactivatedAtMeta =
      const VerificationMeta('deactivatedAt');
  @override
  late final GeneratedColumn<DateTime> deactivatedAt =
      GeneratedColumn<DateTime>('deactivated_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _acknowledgedAtMeta =
      const VerificationMeta('acknowledgedAt');
  @override
  late final GeneratedColumn<DateTime> acknowledgedAt =
      GeneratedColumn<DateTime>('acknowledged_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        alarmUid,
        alarmTitle,
        alarmDescription,
        alarmLevel,
        expression,
        active,
        pendingAck,
        createdAt,
        deactivatedAt,
        acknowledgedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'alarm_history';
  @override
  VerificationContext validateIntegrity(Insertable<AlarmHistoryData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('alarm_uid')) {
      context.handle(_alarmUidMeta,
          alarmUid.isAcceptableOrUnknown(data['alarm_uid']!, _alarmUidMeta));
    } else if (isInserting) {
      context.missing(_alarmUidMeta);
    }
    if (data.containsKey('alarm_title')) {
      context.handle(
          _alarmTitleMeta,
          alarmTitle.isAcceptableOrUnknown(
              data['alarm_title']!, _alarmTitleMeta));
    } else if (isInserting) {
      context.missing(_alarmTitleMeta);
    }
    if (data.containsKey('alarm_description')) {
      context.handle(
          _alarmDescriptionMeta,
          alarmDescription.isAcceptableOrUnknown(
              data['alarm_description']!, _alarmDescriptionMeta));
    } else if (isInserting) {
      context.missing(_alarmDescriptionMeta);
    }
    if (data.containsKey('alarm_level')) {
      context.handle(
          _alarmLevelMeta,
          alarmLevel.isAcceptableOrUnknown(
              data['alarm_level']!, _alarmLevelMeta));
    } else if (isInserting) {
      context.missing(_alarmLevelMeta);
    }
    if (data.containsKey('expression')) {
      context.handle(
          _expressionMeta,
          expression.isAcceptableOrUnknown(
              data['expression']!, _expressionMeta));
    }
    if (data.containsKey('active')) {
      context.handle(_activeMeta,
          active.isAcceptableOrUnknown(data['active']!, _activeMeta));
    } else if (isInserting) {
      context.missing(_activeMeta);
    }
    if (data.containsKey('pending_ack')) {
      context.handle(
          _pendingAckMeta,
          pendingAck.isAcceptableOrUnknown(
              data['pending_ack']!, _pendingAckMeta));
    } else if (isInserting) {
      context.missing(_pendingAckMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('deactivated_at')) {
      context.handle(
          _deactivatedAtMeta,
          deactivatedAt.isAcceptableOrUnknown(
              data['deactivated_at']!, _deactivatedAtMeta));
    }
    if (data.containsKey('acknowledged_at')) {
      context.handle(
          _acknowledgedAtMeta,
          acknowledgedAt.isAcceptableOrUnknown(
              data['acknowledged_at']!, _acknowledgedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AlarmHistoryData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AlarmHistoryData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      alarmUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}alarm_uid'])!,
      alarmTitle: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}alarm_title'])!,
      alarmDescription: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}alarm_description'])!,
      alarmLevel: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}alarm_level'])!,
      expression: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}expression']),
      active: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}active'])!,
      pendingAck: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}pending_ack'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      deactivatedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}deactivated_at']),
      acknowledgedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}acknowledged_at']),
    );
  }

  @override
  $AlarmHistoryTable createAlias(String alias) {
    return $AlarmHistoryTable(attachedDatabase, alias);
  }
}

class AlarmHistoryData extends DataClass
    implements Insertable<AlarmHistoryData> {
  final int id;
  final String alarmUid;
  final String alarmTitle;
  final String alarmDescription;
  final String alarmLevel;
  final String? expression;
  final bool active;
  final bool pendingAck;
  final DateTime createdAt;
  final DateTime? deactivatedAt;
  final DateTime? acknowledgedAt;
  const AlarmHistoryData(
      {required this.id,
      required this.alarmUid,
      required this.alarmTitle,
      required this.alarmDescription,
      required this.alarmLevel,
      this.expression,
      required this.active,
      required this.pendingAck,
      required this.createdAt,
      this.deactivatedAt,
      this.acknowledgedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['alarm_uid'] = Variable<String>(alarmUid);
    map['alarm_title'] = Variable<String>(alarmTitle);
    map['alarm_description'] = Variable<String>(alarmDescription);
    map['alarm_level'] = Variable<String>(alarmLevel);
    if (!nullToAbsent || expression != null) {
      map['expression'] = Variable<String>(expression);
    }
    map['active'] = Variable<bool>(active);
    map['pending_ack'] = Variable<bool>(pendingAck);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || deactivatedAt != null) {
      map['deactivated_at'] = Variable<DateTime>(deactivatedAt);
    }
    if (!nullToAbsent || acknowledgedAt != null) {
      map['acknowledged_at'] = Variable<DateTime>(acknowledgedAt);
    }
    return map;
  }

  AlarmHistoryCompanion toCompanion(bool nullToAbsent) {
    return AlarmHistoryCompanion(
      id: Value(id),
      alarmUid: Value(alarmUid),
      alarmTitle: Value(alarmTitle),
      alarmDescription: Value(alarmDescription),
      alarmLevel: Value(alarmLevel),
      expression: expression == null && nullToAbsent
          ? const Value.absent()
          : Value(expression),
      active: Value(active),
      pendingAck: Value(pendingAck),
      createdAt: Value(createdAt),
      deactivatedAt: deactivatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deactivatedAt),
      acknowledgedAt: acknowledgedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(acknowledgedAt),
    );
  }

  factory AlarmHistoryData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AlarmHistoryData(
      id: serializer.fromJson<int>(json['id']),
      alarmUid: serializer.fromJson<String>(json['alarmUid']),
      alarmTitle: serializer.fromJson<String>(json['alarmTitle']),
      alarmDescription: serializer.fromJson<String>(json['alarmDescription']),
      alarmLevel: serializer.fromJson<String>(json['alarmLevel']),
      expression: serializer.fromJson<String?>(json['expression']),
      active: serializer.fromJson<bool>(json['active']),
      pendingAck: serializer.fromJson<bool>(json['pendingAck']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      deactivatedAt: serializer.fromJson<DateTime?>(json['deactivatedAt']),
      acknowledgedAt: serializer.fromJson<DateTime?>(json['acknowledgedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'alarmUid': serializer.toJson<String>(alarmUid),
      'alarmTitle': serializer.toJson<String>(alarmTitle),
      'alarmDescription': serializer.toJson<String>(alarmDescription),
      'alarmLevel': serializer.toJson<String>(alarmLevel),
      'expression': serializer.toJson<String?>(expression),
      'active': serializer.toJson<bool>(active),
      'pendingAck': serializer.toJson<bool>(pendingAck),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'deactivatedAt': serializer.toJson<DateTime?>(deactivatedAt),
      'acknowledgedAt': serializer.toJson<DateTime?>(acknowledgedAt),
    };
  }

  AlarmHistoryData copyWith(
          {int? id,
          String? alarmUid,
          String? alarmTitle,
          String? alarmDescription,
          String? alarmLevel,
          Value<String?> expression = const Value.absent(),
          bool? active,
          bool? pendingAck,
          DateTime? createdAt,
          Value<DateTime?> deactivatedAt = const Value.absent(),
          Value<DateTime?> acknowledgedAt = const Value.absent()}) =>
      AlarmHistoryData(
        id: id ?? this.id,
        alarmUid: alarmUid ?? this.alarmUid,
        alarmTitle: alarmTitle ?? this.alarmTitle,
        alarmDescription: alarmDescription ?? this.alarmDescription,
        alarmLevel: alarmLevel ?? this.alarmLevel,
        expression: expression.present ? expression.value : this.expression,
        active: active ?? this.active,
        pendingAck: pendingAck ?? this.pendingAck,
        createdAt: createdAt ?? this.createdAt,
        deactivatedAt:
            deactivatedAt.present ? deactivatedAt.value : this.deactivatedAt,
        acknowledgedAt:
            acknowledgedAt.present ? acknowledgedAt.value : this.acknowledgedAt,
      );
  AlarmHistoryData copyWithCompanion(AlarmHistoryCompanion data) {
    return AlarmHistoryData(
      id: data.id.present ? data.id.value : this.id,
      alarmUid: data.alarmUid.present ? data.alarmUid.value : this.alarmUid,
      alarmTitle:
          data.alarmTitle.present ? data.alarmTitle.value : this.alarmTitle,
      alarmDescription: data.alarmDescription.present
          ? data.alarmDescription.value
          : this.alarmDescription,
      alarmLevel:
          data.alarmLevel.present ? data.alarmLevel.value : this.alarmLevel,
      expression:
          data.expression.present ? data.expression.value : this.expression,
      active: data.active.present ? data.active.value : this.active,
      pendingAck:
          data.pendingAck.present ? data.pendingAck.value : this.pendingAck,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      deactivatedAt: data.deactivatedAt.present
          ? data.deactivatedAt.value
          : this.deactivatedAt,
      acknowledgedAt: data.acknowledgedAt.present
          ? data.acknowledgedAt.value
          : this.acknowledgedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AlarmHistoryData(')
          ..write('id: $id, ')
          ..write('alarmUid: $alarmUid, ')
          ..write('alarmTitle: $alarmTitle, ')
          ..write('alarmDescription: $alarmDescription, ')
          ..write('alarmLevel: $alarmLevel, ')
          ..write('expression: $expression, ')
          ..write('active: $active, ')
          ..write('pendingAck: $pendingAck, ')
          ..write('createdAt: $createdAt, ')
          ..write('deactivatedAt: $deactivatedAt, ')
          ..write('acknowledgedAt: $acknowledgedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      alarmUid,
      alarmTitle,
      alarmDescription,
      alarmLevel,
      expression,
      active,
      pendingAck,
      createdAt,
      deactivatedAt,
      acknowledgedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlarmHistoryData &&
          other.id == this.id &&
          other.alarmUid == this.alarmUid &&
          other.alarmTitle == this.alarmTitle &&
          other.alarmDescription == this.alarmDescription &&
          other.alarmLevel == this.alarmLevel &&
          other.expression == this.expression &&
          other.active == this.active &&
          other.pendingAck == this.pendingAck &&
          other.createdAt == this.createdAt &&
          other.deactivatedAt == this.deactivatedAt &&
          other.acknowledgedAt == this.acknowledgedAt);
}

class AlarmHistoryCompanion extends UpdateCompanion<AlarmHistoryData> {
  final Value<int> id;
  final Value<String> alarmUid;
  final Value<String> alarmTitle;
  final Value<String> alarmDescription;
  final Value<String> alarmLevel;
  final Value<String?> expression;
  final Value<bool> active;
  final Value<bool> pendingAck;
  final Value<DateTime> createdAt;
  final Value<DateTime?> deactivatedAt;
  final Value<DateTime?> acknowledgedAt;
  const AlarmHistoryCompanion({
    this.id = const Value.absent(),
    this.alarmUid = const Value.absent(),
    this.alarmTitle = const Value.absent(),
    this.alarmDescription = const Value.absent(),
    this.alarmLevel = const Value.absent(),
    this.expression = const Value.absent(),
    this.active = const Value.absent(),
    this.pendingAck = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.deactivatedAt = const Value.absent(),
    this.acknowledgedAt = const Value.absent(),
  });
  AlarmHistoryCompanion.insert({
    this.id = const Value.absent(),
    required String alarmUid,
    required String alarmTitle,
    required String alarmDescription,
    required String alarmLevel,
    this.expression = const Value.absent(),
    required bool active,
    required bool pendingAck,
    required DateTime createdAt,
    this.deactivatedAt = const Value.absent(),
    this.acknowledgedAt = const Value.absent(),
  })  : alarmUid = Value(alarmUid),
        alarmTitle = Value(alarmTitle),
        alarmDescription = Value(alarmDescription),
        alarmLevel = Value(alarmLevel),
        active = Value(active),
        pendingAck = Value(pendingAck),
        createdAt = Value(createdAt);
  static Insertable<AlarmHistoryData> custom({
    Expression<int>? id,
    Expression<String>? alarmUid,
    Expression<String>? alarmTitle,
    Expression<String>? alarmDescription,
    Expression<String>? alarmLevel,
    Expression<String>? expression,
    Expression<bool>? active,
    Expression<bool>? pendingAck,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? deactivatedAt,
    Expression<DateTime>? acknowledgedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (alarmUid != null) 'alarm_uid': alarmUid,
      if (alarmTitle != null) 'alarm_title': alarmTitle,
      if (alarmDescription != null) 'alarm_description': alarmDescription,
      if (alarmLevel != null) 'alarm_level': alarmLevel,
      if (expression != null) 'expression': expression,
      if (active != null) 'active': active,
      if (pendingAck != null) 'pending_ack': pendingAck,
      if (createdAt != null) 'created_at': createdAt,
      if (deactivatedAt != null) 'deactivated_at': deactivatedAt,
      if (acknowledgedAt != null) 'acknowledged_at': acknowledgedAt,
    });
  }

  AlarmHistoryCompanion copyWith(
      {Value<int>? id,
      Value<String>? alarmUid,
      Value<String>? alarmTitle,
      Value<String>? alarmDescription,
      Value<String>? alarmLevel,
      Value<String?>? expression,
      Value<bool>? active,
      Value<bool>? pendingAck,
      Value<DateTime>? createdAt,
      Value<DateTime?>? deactivatedAt,
      Value<DateTime?>? acknowledgedAt}) {
    return AlarmHistoryCompanion(
      id: id ?? this.id,
      alarmUid: alarmUid ?? this.alarmUid,
      alarmTitle: alarmTitle ?? this.alarmTitle,
      alarmDescription: alarmDescription ?? this.alarmDescription,
      alarmLevel: alarmLevel ?? this.alarmLevel,
      expression: expression ?? this.expression,
      active: active ?? this.active,
      pendingAck: pendingAck ?? this.pendingAck,
      createdAt: createdAt ?? this.createdAt,
      deactivatedAt: deactivatedAt ?? this.deactivatedAt,
      acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (alarmUid.present) {
      map['alarm_uid'] = Variable<String>(alarmUid.value);
    }
    if (alarmTitle.present) {
      map['alarm_title'] = Variable<String>(alarmTitle.value);
    }
    if (alarmDescription.present) {
      map['alarm_description'] = Variable<String>(alarmDescription.value);
    }
    if (alarmLevel.present) {
      map['alarm_level'] = Variable<String>(alarmLevel.value);
    }
    if (expression.present) {
      map['expression'] = Variable<String>(expression.value);
    }
    if (active.present) {
      map['active'] = Variable<bool>(active.value);
    }
    if (pendingAck.present) {
      map['pending_ack'] = Variable<bool>(pendingAck.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (deactivatedAt.present) {
      map['deactivated_at'] = Variable<DateTime>(deactivatedAt.value);
    }
    if (acknowledgedAt.present) {
      map['acknowledged_at'] = Variable<DateTime>(acknowledgedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AlarmHistoryCompanion(')
          ..write('id: $id, ')
          ..write('alarmUid: $alarmUid, ')
          ..write('alarmTitle: $alarmTitle, ')
          ..write('alarmDescription: $alarmDescription, ')
          ..write('alarmLevel: $alarmLevel, ')
          ..write('expression: $expression, ')
          ..write('active: $active, ')
          ..write('pendingAck: $pendingAck, ')
          ..write('createdAt: $createdAt, ')
          ..write('deactivatedAt: $deactivatedAt, ')
          ..write('acknowledgedAt: $acknowledgedAt')
          ..write(')'))
        .toString();
  }
}

class $FlutterPreferencesTable extends FlutterPreferences
    with TableInfo<$FlutterPreferencesTable, FlutterPreference> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FlutterPreferencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value, type];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'flutter_preferences';
  @override
  VerificationContext validateIntegrity(Insertable<FlutterPreference> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  FlutterPreference map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FlutterPreference(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value']),
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
    );
  }

  @override
  $FlutterPreferencesTable createAlias(String alias) {
    return $FlutterPreferencesTable(attachedDatabase, alias);
  }
}

class FlutterPreference extends DataClass
    implements Insertable<FlutterPreference> {
  final String key;
  final String? value;
  final String type;
  const FlutterPreference({required this.key, this.value, required this.type});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    if (!nullToAbsent || value != null) {
      map['value'] = Variable<String>(value);
    }
    map['type'] = Variable<String>(type);
    return map;
  }

  FlutterPreferencesCompanion toCompanion(bool nullToAbsent) {
    return FlutterPreferencesCompanion(
      key: Value(key),
      value:
          value == null && nullToAbsent ? const Value.absent() : Value(value),
      type: Value(type),
    );
  }

  factory FlutterPreference.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FlutterPreference(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String?>(json['value']),
      type: serializer.fromJson<String>(json['type']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String?>(value),
      'type': serializer.toJson<String>(type),
    };
  }

  FlutterPreference copyWith(
          {String? key,
          Value<String?> value = const Value.absent(),
          String? type}) =>
      FlutterPreference(
        key: key ?? this.key,
        value: value.present ? value.value : this.value,
        type: type ?? this.type,
      );
  FlutterPreference copyWithCompanion(FlutterPreferencesCompanion data) {
    return FlutterPreference(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      type: data.type.present ? data.type.value : this.type,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FlutterPreference(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('type: $type')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, type);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FlutterPreference &&
          other.key == this.key &&
          other.value == this.value &&
          other.type == this.type);
}

class FlutterPreferencesCompanion extends UpdateCompanion<FlutterPreference> {
  final Value<String> key;
  final Value<String?> value;
  final Value<String> type;
  final Value<int> rowid;
  const FlutterPreferencesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.type = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FlutterPreferencesCompanion.insert({
    required String key,
    this.value = const Value.absent(),
    required String type,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        type = Value(type);
  static Insertable<FlutterPreference> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<String>? type,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (type != null) 'type': type,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FlutterPreferencesCompanion copyWith(
      {Value<String>? key,
      Value<String?>? value,
      Value<String>? type,
      Value<int>? rowid}) {
    return FlutterPreferencesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      type: type ?? this.type,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FlutterPreferencesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('type: $type, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HistoryViewTable extends HistoryView
    with TableInfo<$HistoryViewTable, HistoryViewData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryViewTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      clientDefault: () => DateTime.now());
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [id, name, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_view';
  @override
  VerificationContext validateIntegrity(Insertable<HistoryViewData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryViewData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryViewData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $HistoryViewTable createAlias(String alias) {
    return $HistoryViewTable(attachedDatabase, alias);
  }
}

class HistoryViewData extends DataClass implements Insertable<HistoryViewData> {
  final int id;
  final String name;
  final DateTime createdAt;
  final DateTime? updatedAt;
  const HistoryViewData(
      {required this.id,
      required this.name,
      required this.createdAt,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  HistoryViewCompanion toCompanion(bool nullToAbsent) {
    return HistoryViewCompanion(
      id: Value(id),
      name: Value(name),
      createdAt: Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory HistoryViewData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryViewData(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  HistoryViewData copyWith(
          {int? id,
          String? name,
          DateTime? createdAt,
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      HistoryViewData(
        id: id ?? this.id,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  HistoryViewData copyWithCompanion(HistoryViewCompanion data) {
    return HistoryViewData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryViewData &&
          other.id == this.id &&
          other.name == this.name &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class HistoryViewCompanion extends UpdateCompanion<HistoryViewData> {
  final Value<int> id;
  final Value<String> name;
  final Value<DateTime> createdAt;
  final Value<DateTime?> updatedAt;
  const HistoryViewCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  HistoryViewCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  }) : name = Value(name);
  static Insertable<HistoryViewData> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  HistoryViewCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<DateTime>? createdAt,
      Value<DateTime?>? updatedAt}) {
    return HistoryViewCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $HistoryViewKeyTable extends HistoryViewKey
    with TableInfo<$HistoryViewKeyTable, HistoryViewKeyData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryViewKeyTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _viewIdMeta = const VerificationMeta('viewId');
  @override
  late final GeneratedColumn<int> viewId = GeneratedColumn<int>(
      'view_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES history_view (id) ON DELETE CASCADE'));
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _aliasMeta = const VerificationMeta('alias');
  @override
  late final GeneratedColumn<String> alias = GeneratedColumn<String>(
      'alias', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _useSecondYAxisMeta =
      const VerificationMeta('useSecondYAxis');
  @override
  late final GeneratedColumn<bool> useSecondYAxis = GeneratedColumn<bool>(
      'use_second_y_axis', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultValue: const Constant(false));
  static const VerificationMeta _graphIndexMeta =
      const VerificationMeta('graphIndex');
  @override
  late final GeneratedColumn<int> graphIndex = GeneratedColumn<int>(
      'graph_index', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns =>
      [id, viewId, key, alias, useSecondYAxis, graphIndex];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_view_key';
  @override
  VerificationContext validateIntegrity(Insertable<HistoryViewKeyData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('view_id')) {
      context.handle(_viewIdMeta,
          viewId.isAcceptableOrUnknown(data['view_id']!, _viewIdMeta));
    } else if (isInserting) {
      context.missing(_viewIdMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('alias')) {
      context.handle(
          _aliasMeta, alias.isAcceptableOrUnknown(data['alias']!, _aliasMeta));
    }
    if (data.containsKey('use_second_y_axis')) {
      context.handle(
          _useSecondYAxisMeta,
          useSecondYAxis.isAcceptableOrUnknown(
              data['use_second_y_axis']!, _useSecondYAxisMeta));
    }
    if (data.containsKey('graph_index')) {
      context.handle(
          _graphIndexMeta,
          graphIndex.isAcceptableOrUnknown(
              data['graph_index']!, _graphIndexMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryViewKeyData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryViewKeyData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      viewId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}view_id'])!,
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      alias: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}alias']),
      useSecondYAxis: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}use_second_y_axis'])!,
      graphIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}graph_index'])!,
    );
  }

  @override
  $HistoryViewKeyTable createAlias(String alias) {
    return $HistoryViewKeyTable(attachedDatabase, alias);
  }
}

class HistoryViewKeyData extends DataClass
    implements Insertable<HistoryViewKeyData> {
  final int id;
  final int viewId;
  final String key;
  final String? alias;
  final bool useSecondYAxis;
  final int graphIndex;
  const HistoryViewKeyData(
      {required this.id,
      required this.viewId,
      required this.key,
      this.alias,
      required this.useSecondYAxis,
      required this.graphIndex});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['view_id'] = Variable<int>(viewId);
    map['key'] = Variable<String>(key);
    if (!nullToAbsent || alias != null) {
      map['alias'] = Variable<String>(alias);
    }
    map['use_second_y_axis'] = Variable<bool>(useSecondYAxis);
    map['graph_index'] = Variable<int>(graphIndex);
    return map;
  }

  HistoryViewKeyCompanion toCompanion(bool nullToAbsent) {
    return HistoryViewKeyCompanion(
      id: Value(id),
      viewId: Value(viewId),
      key: Value(key),
      alias:
          alias == null && nullToAbsent ? const Value.absent() : Value(alias),
      useSecondYAxis: Value(useSecondYAxis),
      graphIndex: Value(graphIndex),
    );
  }

  factory HistoryViewKeyData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryViewKeyData(
      id: serializer.fromJson<int>(json['id']),
      viewId: serializer.fromJson<int>(json['viewId']),
      key: serializer.fromJson<String>(json['key']),
      alias: serializer.fromJson<String?>(json['alias']),
      useSecondYAxis: serializer.fromJson<bool>(json['useSecondYAxis']),
      graphIndex: serializer.fromJson<int>(json['graphIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'viewId': serializer.toJson<int>(viewId),
      'key': serializer.toJson<String>(key),
      'alias': serializer.toJson<String?>(alias),
      'useSecondYAxis': serializer.toJson<bool>(useSecondYAxis),
      'graphIndex': serializer.toJson<int>(graphIndex),
    };
  }

  HistoryViewKeyData copyWith(
          {int? id,
          int? viewId,
          String? key,
          Value<String?> alias = const Value.absent(),
          bool? useSecondYAxis,
          int? graphIndex}) =>
      HistoryViewKeyData(
        id: id ?? this.id,
        viewId: viewId ?? this.viewId,
        key: key ?? this.key,
        alias: alias.present ? alias.value : this.alias,
        useSecondYAxis: useSecondYAxis ?? this.useSecondYAxis,
        graphIndex: graphIndex ?? this.graphIndex,
      );
  HistoryViewKeyData copyWithCompanion(HistoryViewKeyCompanion data) {
    return HistoryViewKeyData(
      id: data.id.present ? data.id.value : this.id,
      viewId: data.viewId.present ? data.viewId.value : this.viewId,
      key: data.key.present ? data.key.value : this.key,
      alias: data.alias.present ? data.alias.value : this.alias,
      useSecondYAxis: data.useSecondYAxis.present
          ? data.useSecondYAxis.value
          : this.useSecondYAxis,
      graphIndex:
          data.graphIndex.present ? data.graphIndex.value : this.graphIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewKeyData(')
          ..write('id: $id, ')
          ..write('viewId: $viewId, ')
          ..write('key: $key, ')
          ..write('alias: $alias, ')
          ..write('useSecondYAxis: $useSecondYAxis, ')
          ..write('graphIndex: $graphIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, viewId, key, alias, useSecondYAxis, graphIndex);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryViewKeyData &&
          other.id == this.id &&
          other.viewId == this.viewId &&
          other.key == this.key &&
          other.alias == this.alias &&
          other.useSecondYAxis == this.useSecondYAxis &&
          other.graphIndex == this.graphIndex);
}

class HistoryViewKeyCompanion extends UpdateCompanion<HistoryViewKeyData> {
  final Value<int> id;
  final Value<int> viewId;
  final Value<String> key;
  final Value<String?> alias;
  final Value<bool> useSecondYAxis;
  final Value<int> graphIndex;
  const HistoryViewKeyCompanion({
    this.id = const Value.absent(),
    this.viewId = const Value.absent(),
    this.key = const Value.absent(),
    this.alias = const Value.absent(),
    this.useSecondYAxis = const Value.absent(),
    this.graphIndex = const Value.absent(),
  });
  HistoryViewKeyCompanion.insert({
    this.id = const Value.absent(),
    required int viewId,
    required String key,
    this.alias = const Value.absent(),
    this.useSecondYAxis = const Value.absent(),
    this.graphIndex = const Value.absent(),
  })  : viewId = Value(viewId),
        key = Value(key);
  static Insertable<HistoryViewKeyData> custom({
    Expression<int>? id,
    Expression<int>? viewId,
    Expression<String>? key,
    Expression<String>? alias,
    Expression<bool>? useSecondYAxis,
    Expression<int>? graphIndex,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (viewId != null) 'view_id': viewId,
      if (key != null) 'key': key,
      if (alias != null) 'alias': alias,
      if (useSecondYAxis != null) 'use_second_y_axis': useSecondYAxis,
      if (graphIndex != null) 'graph_index': graphIndex,
    });
  }

  HistoryViewKeyCompanion copyWith(
      {Value<int>? id,
      Value<int>? viewId,
      Value<String>? key,
      Value<String?>? alias,
      Value<bool>? useSecondYAxis,
      Value<int>? graphIndex}) {
    return HistoryViewKeyCompanion(
      id: id ?? this.id,
      viewId: viewId ?? this.viewId,
      key: key ?? this.key,
      alias: alias ?? this.alias,
      useSecondYAxis: useSecondYAxis ?? this.useSecondYAxis,
      graphIndex: graphIndex ?? this.graphIndex,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (viewId.present) {
      map['view_id'] = Variable<int>(viewId.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (alias.present) {
      map['alias'] = Variable<String>(alias.value);
    }
    if (useSecondYAxis.present) {
      map['use_second_y_axis'] = Variable<bool>(useSecondYAxis.value);
    }
    if (graphIndex.present) {
      map['graph_index'] = Variable<int>(graphIndex.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewKeyCompanion(')
          ..write('id: $id, ')
          ..write('viewId: $viewId, ')
          ..write('key: $key, ')
          ..write('alias: $alias, ')
          ..write('useSecondYAxis: $useSecondYAxis, ')
          ..write('graphIndex: $graphIndex')
          ..write(')'))
        .toString();
  }
}

class $HistoryViewGraphTable extends HistoryViewGraph
    with TableInfo<$HistoryViewGraphTable, HistoryViewGraphData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryViewGraphTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _viewIdMeta = const VerificationMeta('viewId');
  @override
  late final GeneratedColumn<int> viewId = GeneratedColumn<int>(
      'view_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES history_view (id) ON DELETE CASCADE'));
  static const VerificationMeta _graphIndexMeta =
      const VerificationMeta('graphIndex');
  @override
  late final GeneratedColumn<int> graphIndex = GeneratedColumn<int>(
      'graph_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _yAxisUnitMeta =
      const VerificationMeta('yAxisUnit');
  @override
  late final GeneratedColumn<String> yAxisUnit = GeneratedColumn<String>(
      'y_axis_unit', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _yAxis2UnitMeta =
      const VerificationMeta('yAxis2Unit');
  @override
  late final GeneratedColumn<String> yAxis2Unit = GeneratedColumn<String>(
      'y_axis2_unit', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, viewId, graphIndex, name, yAxisUnit, yAxis2Unit];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_view_graph';
  @override
  VerificationContext validateIntegrity(
      Insertable<HistoryViewGraphData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('view_id')) {
      context.handle(_viewIdMeta,
          viewId.isAcceptableOrUnknown(data['view_id']!, _viewIdMeta));
    } else if (isInserting) {
      context.missing(_viewIdMeta);
    }
    if (data.containsKey('graph_index')) {
      context.handle(
          _graphIndexMeta,
          graphIndex.isAcceptableOrUnknown(
              data['graph_index']!, _graphIndexMeta));
    } else if (isInserting) {
      context.missing(_graphIndexMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('y_axis_unit')) {
      context.handle(
          _yAxisUnitMeta,
          yAxisUnit.isAcceptableOrUnknown(
              data['y_axis_unit']!, _yAxisUnitMeta));
    }
    if (data.containsKey('y_axis2_unit')) {
      context.handle(
          _yAxis2UnitMeta,
          yAxis2Unit.isAcceptableOrUnknown(
              data['y_axis2_unit']!, _yAxis2UnitMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryViewGraphData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryViewGraphData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      viewId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}view_id'])!,
      graphIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}graph_index'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name']),
      yAxisUnit: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}y_axis_unit']),
      yAxis2Unit: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}y_axis2_unit']),
    );
  }

  @override
  $HistoryViewGraphTable createAlias(String alias) {
    return $HistoryViewGraphTable(attachedDatabase, alias);
  }
}

class HistoryViewGraphData extends DataClass
    implements Insertable<HistoryViewGraphData> {
  final int id;
  final int viewId;
  final int graphIndex;
  final String? name;
  final String? yAxisUnit;
  final String? yAxis2Unit;
  const HistoryViewGraphData(
      {required this.id,
      required this.viewId,
      required this.graphIndex,
      this.name,
      this.yAxisUnit,
      this.yAxis2Unit});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['view_id'] = Variable<int>(viewId);
    map['graph_index'] = Variable<int>(graphIndex);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    if (!nullToAbsent || yAxisUnit != null) {
      map['y_axis_unit'] = Variable<String>(yAxisUnit);
    }
    if (!nullToAbsent || yAxis2Unit != null) {
      map['y_axis2_unit'] = Variable<String>(yAxis2Unit);
    }
    return map;
  }

  HistoryViewGraphCompanion toCompanion(bool nullToAbsent) {
    return HistoryViewGraphCompanion(
      id: Value(id),
      viewId: Value(viewId),
      graphIndex: Value(graphIndex),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      yAxisUnit: yAxisUnit == null && nullToAbsent
          ? const Value.absent()
          : Value(yAxisUnit),
      yAxis2Unit: yAxis2Unit == null && nullToAbsent
          ? const Value.absent()
          : Value(yAxis2Unit),
    );
  }

  factory HistoryViewGraphData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryViewGraphData(
      id: serializer.fromJson<int>(json['id']),
      viewId: serializer.fromJson<int>(json['viewId']),
      graphIndex: serializer.fromJson<int>(json['graphIndex']),
      name: serializer.fromJson<String?>(json['name']),
      yAxisUnit: serializer.fromJson<String?>(json['yAxisUnit']),
      yAxis2Unit: serializer.fromJson<String?>(json['yAxis2Unit']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'viewId': serializer.toJson<int>(viewId),
      'graphIndex': serializer.toJson<int>(graphIndex),
      'name': serializer.toJson<String?>(name),
      'yAxisUnit': serializer.toJson<String?>(yAxisUnit),
      'yAxis2Unit': serializer.toJson<String?>(yAxis2Unit),
    };
  }

  HistoryViewGraphData copyWith(
          {int? id,
          int? viewId,
          int? graphIndex,
          Value<String?> name = const Value.absent(),
          Value<String?> yAxisUnit = const Value.absent(),
          Value<String?> yAxis2Unit = const Value.absent()}) =>
      HistoryViewGraphData(
        id: id ?? this.id,
        viewId: viewId ?? this.viewId,
        graphIndex: graphIndex ?? this.graphIndex,
        name: name.present ? name.value : this.name,
        yAxisUnit: yAxisUnit.present ? yAxisUnit.value : this.yAxisUnit,
        yAxis2Unit: yAxis2Unit.present ? yAxis2Unit.value : this.yAxis2Unit,
      );
  HistoryViewGraphData copyWithCompanion(HistoryViewGraphCompanion data) {
    return HistoryViewGraphData(
      id: data.id.present ? data.id.value : this.id,
      viewId: data.viewId.present ? data.viewId.value : this.viewId,
      graphIndex:
          data.graphIndex.present ? data.graphIndex.value : this.graphIndex,
      name: data.name.present ? data.name.value : this.name,
      yAxisUnit: data.yAxisUnit.present ? data.yAxisUnit.value : this.yAxisUnit,
      yAxis2Unit:
          data.yAxis2Unit.present ? data.yAxis2Unit.value : this.yAxis2Unit,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewGraphData(')
          ..write('id: $id, ')
          ..write('viewId: $viewId, ')
          ..write('graphIndex: $graphIndex, ')
          ..write('name: $name, ')
          ..write('yAxisUnit: $yAxisUnit, ')
          ..write('yAxis2Unit: $yAxis2Unit')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, viewId, graphIndex, name, yAxisUnit, yAxis2Unit);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryViewGraphData &&
          other.id == this.id &&
          other.viewId == this.viewId &&
          other.graphIndex == this.graphIndex &&
          other.name == this.name &&
          other.yAxisUnit == this.yAxisUnit &&
          other.yAxis2Unit == this.yAxis2Unit);
}

class HistoryViewGraphCompanion extends UpdateCompanion<HistoryViewGraphData> {
  final Value<int> id;
  final Value<int> viewId;
  final Value<int> graphIndex;
  final Value<String?> name;
  final Value<String?> yAxisUnit;
  final Value<String?> yAxis2Unit;
  const HistoryViewGraphCompanion({
    this.id = const Value.absent(),
    this.viewId = const Value.absent(),
    this.graphIndex = const Value.absent(),
    this.name = const Value.absent(),
    this.yAxisUnit = const Value.absent(),
    this.yAxis2Unit = const Value.absent(),
  });
  HistoryViewGraphCompanion.insert({
    this.id = const Value.absent(),
    required int viewId,
    required int graphIndex,
    this.name = const Value.absent(),
    this.yAxisUnit = const Value.absent(),
    this.yAxis2Unit = const Value.absent(),
  })  : viewId = Value(viewId),
        graphIndex = Value(graphIndex);
  static Insertable<HistoryViewGraphData> custom({
    Expression<int>? id,
    Expression<int>? viewId,
    Expression<int>? graphIndex,
    Expression<String>? name,
    Expression<String>? yAxisUnit,
    Expression<String>? yAxis2Unit,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (viewId != null) 'view_id': viewId,
      if (graphIndex != null) 'graph_index': graphIndex,
      if (name != null) 'name': name,
      if (yAxisUnit != null) 'y_axis_unit': yAxisUnit,
      if (yAxis2Unit != null) 'y_axis2_unit': yAxis2Unit,
    });
  }

  HistoryViewGraphCompanion copyWith(
      {Value<int>? id,
      Value<int>? viewId,
      Value<int>? graphIndex,
      Value<String?>? name,
      Value<String?>? yAxisUnit,
      Value<String?>? yAxis2Unit}) {
    return HistoryViewGraphCompanion(
      id: id ?? this.id,
      viewId: viewId ?? this.viewId,
      graphIndex: graphIndex ?? this.graphIndex,
      name: name ?? this.name,
      yAxisUnit: yAxisUnit ?? this.yAxisUnit,
      yAxis2Unit: yAxis2Unit ?? this.yAxis2Unit,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (viewId.present) {
      map['view_id'] = Variable<int>(viewId.value);
    }
    if (graphIndex.present) {
      map['graph_index'] = Variable<int>(graphIndex.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (yAxisUnit.present) {
      map['y_axis_unit'] = Variable<String>(yAxisUnit.value);
    }
    if (yAxis2Unit.present) {
      map['y_axis2_unit'] = Variable<String>(yAxis2Unit.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewGraphCompanion(')
          ..write('id: $id, ')
          ..write('viewId: $viewId, ')
          ..write('graphIndex: $graphIndex, ')
          ..write('name: $name, ')
          ..write('yAxisUnit: $yAxisUnit, ')
          ..write('yAxis2Unit: $yAxis2Unit')
          ..write(')'))
        .toString();
  }
}

class $HistoryViewPeriodTable extends HistoryViewPeriod
    with TableInfo<$HistoryViewPeriodTable, HistoryViewPeriodData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryViewPeriodTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _viewIdMeta = const VerificationMeta('viewId');
  @override
  late final GeneratedColumn<int> viewId = GeneratedColumn<int>(
      'view_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES history_view (id) ON DELETE CASCADE'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _startAtMeta =
      const VerificationMeta('startAt');
  @override
  late final GeneratedColumn<DateTime> startAt = GeneratedColumn<DateTime>(
      'start_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _endAtMeta = const VerificationMeta('endAt');
  @override
  late final GeneratedColumn<DateTime> endAt = GeneratedColumn<DateTime>(
      'end_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      clientDefault: () => DateTime.now());
  @override
  List<GeneratedColumn> get $columns =>
      [id, viewId, name, startAt, endAt, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_view_period';
  @override
  VerificationContext validateIntegrity(
      Insertable<HistoryViewPeriodData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('view_id')) {
      context.handle(_viewIdMeta,
          viewId.isAcceptableOrUnknown(data['view_id']!, _viewIdMeta));
    } else if (isInserting) {
      context.missing(_viewIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('start_at')) {
      context.handle(_startAtMeta,
          startAt.isAcceptableOrUnknown(data['start_at']!, _startAtMeta));
    } else if (isInserting) {
      context.missing(_startAtMeta);
    }
    if (data.containsKey('end_at')) {
      context.handle(
          _endAtMeta, endAt.isAcceptableOrUnknown(data['end_at']!, _endAtMeta));
    } else if (isInserting) {
      context.missing(_endAtMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryViewPeriodData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryViewPeriodData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      viewId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}view_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      startAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start_at'])!,
      endAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}end_at'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $HistoryViewPeriodTable createAlias(String alias) {
    return $HistoryViewPeriodTable(attachedDatabase, alias);
  }
}

class HistoryViewPeriodData extends DataClass
    implements Insertable<HistoryViewPeriodData> {
  final int id;
  final int viewId;
  final String name;
  final DateTime startAt;
  final DateTime endAt;
  final DateTime createdAt;
  const HistoryViewPeriodData(
      {required this.id,
      required this.viewId,
      required this.name,
      required this.startAt,
      required this.endAt,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['view_id'] = Variable<int>(viewId);
    map['name'] = Variable<String>(name);
    map['start_at'] = Variable<DateTime>(startAt);
    map['end_at'] = Variable<DateTime>(endAt);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  HistoryViewPeriodCompanion toCompanion(bool nullToAbsent) {
    return HistoryViewPeriodCompanion(
      id: Value(id),
      viewId: Value(viewId),
      name: Value(name),
      startAt: Value(startAt),
      endAt: Value(endAt),
      createdAt: Value(createdAt),
    );
  }

  factory HistoryViewPeriodData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryViewPeriodData(
      id: serializer.fromJson<int>(json['id']),
      viewId: serializer.fromJson<int>(json['viewId']),
      name: serializer.fromJson<String>(json['name']),
      startAt: serializer.fromJson<DateTime>(json['startAt']),
      endAt: serializer.fromJson<DateTime>(json['endAt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'viewId': serializer.toJson<int>(viewId),
      'name': serializer.toJson<String>(name),
      'startAt': serializer.toJson<DateTime>(startAt),
      'endAt': serializer.toJson<DateTime>(endAt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  HistoryViewPeriodData copyWith(
          {int? id,
          int? viewId,
          String? name,
          DateTime? startAt,
          DateTime? endAt,
          DateTime? createdAt}) =>
      HistoryViewPeriodData(
        id: id ?? this.id,
        viewId: viewId ?? this.viewId,
        name: name ?? this.name,
        startAt: startAt ?? this.startAt,
        endAt: endAt ?? this.endAt,
        createdAt: createdAt ?? this.createdAt,
      );
  HistoryViewPeriodData copyWithCompanion(HistoryViewPeriodCompanion data) {
    return HistoryViewPeriodData(
      id: data.id.present ? data.id.value : this.id,
      viewId: data.viewId.present ? data.viewId.value : this.viewId,
      name: data.name.present ? data.name.value : this.name,
      startAt: data.startAt.present ? data.startAt.value : this.startAt,
      endAt: data.endAt.present ? data.endAt.value : this.endAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewPeriodData(')
          ..write('id: $id, ')
          ..write('viewId: $viewId, ')
          ..write('name: $name, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, viewId, name, startAt, endAt, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryViewPeriodData &&
          other.id == this.id &&
          other.viewId == this.viewId &&
          other.name == this.name &&
          other.startAt == this.startAt &&
          other.endAt == this.endAt &&
          other.createdAt == this.createdAt);
}

class HistoryViewPeriodCompanion
    extends UpdateCompanion<HistoryViewPeriodData> {
  final Value<int> id;
  final Value<int> viewId;
  final Value<String> name;
  final Value<DateTime> startAt;
  final Value<DateTime> endAt;
  final Value<DateTime> createdAt;
  const HistoryViewPeriodCompanion({
    this.id = const Value.absent(),
    this.viewId = const Value.absent(),
    this.name = const Value.absent(),
    this.startAt = const Value.absent(),
    this.endAt = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  HistoryViewPeriodCompanion.insert({
    this.id = const Value.absent(),
    required int viewId,
    required String name,
    required DateTime startAt,
    required DateTime endAt,
    this.createdAt = const Value.absent(),
  })  : viewId = Value(viewId),
        name = Value(name),
        startAt = Value(startAt),
        endAt = Value(endAt);
  static Insertable<HistoryViewPeriodData> custom({
    Expression<int>? id,
    Expression<int>? viewId,
    Expression<String>? name,
    Expression<DateTime>? startAt,
    Expression<DateTime>? endAt,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (viewId != null) 'view_id': viewId,
      if (name != null) 'name': name,
      if (startAt != null) 'start_at': startAt,
      if (endAt != null) 'end_at': endAt,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  HistoryViewPeriodCompanion copyWith(
      {Value<int>? id,
      Value<int>? viewId,
      Value<String>? name,
      Value<DateTime>? startAt,
      Value<DateTime>? endAt,
      Value<DateTime>? createdAt}) {
    return HistoryViewPeriodCompanion(
      id: id ?? this.id,
      viewId: viewId ?? this.viewId,
      name: name ?? this.name,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (viewId.present) {
      map['view_id'] = Variable<int>(viewId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (startAt.present) {
      map['start_at'] = Variable<DateTime>(startAt.value);
    }
    if (endAt.present) {
      map['end_at'] = Variable<DateTime>(endAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryViewPeriodCompanion(')
          ..write('id: $id, ')
          ..write('viewId: $viewId, ')
          ..write('name: $name, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $AuditLogTable extends AuditLog
    with TableInfo<$AuditLogTable, AuditLogData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AuditLogTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _operatorIdMeta =
      const VerificationMeta('operatorId');
  @override
  late final GeneratedColumn<String> operatorId = GeneratedColumn<String>(
      'operator_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _toolMeta = const VerificationMeta('tool');
  @override
  late final GeneratedColumn<String> tool = GeneratedColumn<String>(
      'tool', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _argumentsMeta =
      const VerificationMeta('arguments');
  @override
  late final GeneratedColumn<String> arguments = GeneratedColumn<String>(
      'arguments', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _reasoningMeta =
      const VerificationMeta('reasoning');
  @override
  late final GeneratedColumn<String> reasoning = GeneratedColumn<String>(
      'reasoning', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
      'error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _completedAtMeta =
      const VerificationMeta('completedAt');
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
      'completed_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        operatorId,
        tool,
        arguments,
        reasoning,
        status,
        error,
        createdAt,
        completedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'audit_log';
  @override
  VerificationContext validateIntegrity(Insertable<AuditLogData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('operator_id')) {
      context.handle(
          _operatorIdMeta,
          operatorId.isAcceptableOrUnknown(
              data['operator_id']!, _operatorIdMeta));
    } else if (isInserting) {
      context.missing(_operatorIdMeta);
    }
    if (data.containsKey('tool')) {
      context.handle(
          _toolMeta, tool.isAcceptableOrUnknown(data['tool']!, _toolMeta));
    } else if (isInserting) {
      context.missing(_toolMeta);
    }
    if (data.containsKey('arguments')) {
      context.handle(_argumentsMeta,
          arguments.isAcceptableOrUnknown(data['arguments']!, _argumentsMeta));
    } else if (isInserting) {
      context.missing(_argumentsMeta);
    }
    if (data.containsKey('reasoning')) {
      context.handle(_reasoningMeta,
          reasoning.isAcceptableOrUnknown(data['reasoning']!, _reasoningMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('error')) {
      context.handle(
          _errorMeta, error.isAcceptableOrUnknown(data['error']!, _errorMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('completed_at')) {
      context.handle(
          _completedAtMeta,
          completedAt.isAcceptableOrUnknown(
              data['completed_at']!, _completedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AuditLogData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AuditLogData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      operatorId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}operator_id'])!,
      tool: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tool'])!,
      arguments: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}arguments'])!,
      reasoning: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reasoning']),
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      error: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      completedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}completed_at']),
    );
  }

  @override
  $AuditLogTable createAlias(String alias) {
    return $AuditLogTable(attachedDatabase, alias);
  }
}

class AuditLogData extends DataClass implements Insertable<AuditLogData> {
  final int id;
  final String operatorId;
  final String tool;
  final String arguments;
  final String? reasoning;
  final String status;
  final String? error;
  final DateTime createdAt;
  final DateTime? completedAt;
  const AuditLogData(
      {required this.id,
      required this.operatorId,
      required this.tool,
      required this.arguments,
      this.reasoning,
      required this.status,
      this.error,
      required this.createdAt,
      this.completedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['operator_id'] = Variable<String>(operatorId);
    map['tool'] = Variable<String>(tool);
    map['arguments'] = Variable<String>(arguments);
    if (!nullToAbsent || reasoning != null) {
      map['reasoning'] = Variable<String>(reasoning);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<DateTime>(completedAt);
    }
    return map;
  }

  AuditLogCompanion toCompanion(bool nullToAbsent) {
    return AuditLogCompanion(
      id: Value(id),
      operatorId: Value(operatorId),
      tool: Value(tool),
      arguments: Value(arguments),
      reasoning: reasoning == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoning),
      status: Value(status),
      error:
          error == null && nullToAbsent ? const Value.absent() : Value(error),
      createdAt: Value(createdAt),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
    );
  }

  factory AuditLogData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AuditLogData(
      id: serializer.fromJson<int>(json['id']),
      operatorId: serializer.fromJson<String>(json['operatorId']),
      tool: serializer.fromJson<String>(json['tool']),
      arguments: serializer.fromJson<String>(json['arguments']),
      reasoning: serializer.fromJson<String?>(json['reasoning']),
      status: serializer.fromJson<String>(json['status']),
      error: serializer.fromJson<String?>(json['error']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      completedAt: serializer.fromJson<DateTime?>(json['completedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'operatorId': serializer.toJson<String>(operatorId),
      'tool': serializer.toJson<String>(tool),
      'arguments': serializer.toJson<String>(arguments),
      'reasoning': serializer.toJson<String?>(reasoning),
      'status': serializer.toJson<String>(status),
      'error': serializer.toJson<String?>(error),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'completedAt': serializer.toJson<DateTime?>(completedAt),
    };
  }

  AuditLogData copyWith(
          {int? id,
          String? operatorId,
          String? tool,
          String? arguments,
          Value<String?> reasoning = const Value.absent(),
          String? status,
          Value<String?> error = const Value.absent(),
          DateTime? createdAt,
          Value<DateTime?> completedAt = const Value.absent()}) =>
      AuditLogData(
        id: id ?? this.id,
        operatorId: operatorId ?? this.operatorId,
        tool: tool ?? this.tool,
        arguments: arguments ?? this.arguments,
        reasoning: reasoning.present ? reasoning.value : this.reasoning,
        status: status ?? this.status,
        error: error.present ? error.value : this.error,
        createdAt: createdAt ?? this.createdAt,
        completedAt: completedAt.present ? completedAt.value : this.completedAt,
      );
  AuditLogData copyWithCompanion(AuditLogCompanion data) {
    return AuditLogData(
      id: data.id.present ? data.id.value : this.id,
      operatorId:
          data.operatorId.present ? data.operatorId.value : this.operatorId,
      tool: data.tool.present ? data.tool.value : this.tool,
      arguments: data.arguments.present ? data.arguments.value : this.arguments,
      reasoning: data.reasoning.present ? data.reasoning.value : this.reasoning,
      status: data.status.present ? data.status.value : this.status,
      error: data.error.present ? data.error.value : this.error,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      completedAt:
          data.completedAt.present ? data.completedAt.value : this.completedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AuditLogData(')
          ..write('id: $id, ')
          ..write('operatorId: $operatorId, ')
          ..write('tool: $tool, ')
          ..write('arguments: $arguments, ')
          ..write('reasoning: $reasoning, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('createdAt: $createdAt, ')
          ..write('completedAt: $completedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, operatorId, tool, arguments, reasoning,
      status, error, createdAt, completedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuditLogData &&
          other.id == this.id &&
          other.operatorId == this.operatorId &&
          other.tool == this.tool &&
          other.arguments == this.arguments &&
          other.reasoning == this.reasoning &&
          other.status == this.status &&
          other.error == this.error &&
          other.createdAt == this.createdAt &&
          other.completedAt == this.completedAt);
}

class AuditLogCompanion extends UpdateCompanion<AuditLogData> {
  final Value<int> id;
  final Value<String> operatorId;
  final Value<String> tool;
  final Value<String> arguments;
  final Value<String?> reasoning;
  final Value<String> status;
  final Value<String?> error;
  final Value<DateTime> createdAt;
  final Value<DateTime?> completedAt;
  const AuditLogCompanion({
    this.id = const Value.absent(),
    this.operatorId = const Value.absent(),
    this.tool = const Value.absent(),
    this.arguments = const Value.absent(),
    this.reasoning = const Value.absent(),
    this.status = const Value.absent(),
    this.error = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.completedAt = const Value.absent(),
  });
  AuditLogCompanion.insert({
    this.id = const Value.absent(),
    required String operatorId,
    required String tool,
    required String arguments,
    this.reasoning = const Value.absent(),
    required String status,
    this.error = const Value.absent(),
    required DateTime createdAt,
    this.completedAt = const Value.absent(),
  })  : operatorId = Value(operatorId),
        tool = Value(tool),
        arguments = Value(arguments),
        status = Value(status),
        createdAt = Value(createdAt);
  static Insertable<AuditLogData> custom({
    Expression<int>? id,
    Expression<String>? operatorId,
    Expression<String>? tool,
    Expression<String>? arguments,
    Expression<String>? reasoning,
    Expression<String>? status,
    Expression<String>? error,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? completedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (operatorId != null) 'operator_id': operatorId,
      if (tool != null) 'tool': tool,
      if (arguments != null) 'arguments': arguments,
      if (reasoning != null) 'reasoning': reasoning,
      if (status != null) 'status': status,
      if (error != null) 'error': error,
      if (createdAt != null) 'created_at': createdAt,
      if (completedAt != null) 'completed_at': completedAt,
    });
  }

  AuditLogCompanion copyWith(
      {Value<int>? id,
      Value<String>? operatorId,
      Value<String>? tool,
      Value<String>? arguments,
      Value<String?>? reasoning,
      Value<String>? status,
      Value<String?>? error,
      Value<DateTime>? createdAt,
      Value<DateTime?>? completedAt}) {
    return AuditLogCompanion(
      id: id ?? this.id,
      operatorId: operatorId ?? this.operatorId,
      tool: tool ?? this.tool,
      arguments: arguments ?? this.arguments,
      reasoning: reasoning ?? this.reasoning,
      status: status ?? this.status,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (operatorId.present) {
      map['operator_id'] = Variable<String>(operatorId.value);
    }
    if (tool.present) {
      map['tool'] = Variable<String>(tool.value);
    }
    if (arguments.present) {
      map['arguments'] = Variable<String>(arguments.value);
    }
    if (reasoning.present) {
      map['reasoning'] = Variable<String>(reasoning.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AuditLogCompanion(')
          ..write('id: $id, ')
          ..write('operatorId: $operatorId, ')
          ..write('tool: $tool, ')
          ..write('arguments: $arguments, ')
          ..write('reasoning: $reasoning, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('createdAt: $createdAt, ')
          ..write('completedAt: $completedAt')
          ..write(')'))
        .toString();
  }
}

class $PlcCodeBlockTableTable extends PlcCodeBlockTable
    with TableInfo<$PlcCodeBlockTableTable, PlcCodeBlockTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlcCodeBlockTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _assetKeyMeta =
      const VerificationMeta('assetKey');
  @override
  late final GeneratedColumn<String> assetKey = GeneratedColumn<String>(
      'asset_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _blockNameMeta =
      const VerificationMeta('blockName');
  @override
  late final GeneratedColumn<String> blockName = GeneratedColumn<String>(
      'block_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _blockTypeMeta =
      const VerificationMeta('blockType');
  @override
  late final GeneratedColumn<String> blockType = GeneratedColumn<String>(
      'block_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _filePathMeta =
      const VerificationMeta('filePath');
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
      'file_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _declarationMeta =
      const VerificationMeta('declaration');
  @override
  late final GeneratedColumn<String> declaration = GeneratedColumn<String>(
      'declaration', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _implementationMeta =
      const VerificationMeta('implementation');
  @override
  late final GeneratedColumn<String> implementation = GeneratedColumn<String>(
      'implementation', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _fullSourceMeta =
      const VerificationMeta('fullSource');
  @override
  late final GeneratedColumn<String> fullSource = GeneratedColumn<String>(
      'full_source', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _parentBlockIdMeta =
      const VerificationMeta('parentBlockId');
  @override
  late final GeneratedColumn<int> parentBlockId = GeneratedColumn<int>(
      'parent_block_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _indexedAtMeta =
      const VerificationMeta('indexedAt');
  @override
  late final GeneratedColumn<DateTime> indexedAt = GeneratedColumn<DateTime>(
      'indexed_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _vendorTypeMeta =
      const VerificationMeta('vendorType');
  @override
  late final GeneratedColumn<String> vendorType = GeneratedColumn<String>(
      'vendor_type', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _serverAliasMeta =
      const VerificationMeta('serverAlias');
  @override
  late final GeneratedColumn<String> serverAlias = GeneratedColumn<String>(
      'server_alias', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        assetKey,
        blockName,
        blockType,
        filePath,
        declaration,
        implementation,
        fullSource,
        parentBlockId,
        indexedAt,
        vendorType,
        serverAlias
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plc_code_block';
  @override
  VerificationContext validateIntegrity(
      Insertable<PlcCodeBlockTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('asset_key')) {
      context.handle(_assetKeyMeta,
          assetKey.isAcceptableOrUnknown(data['asset_key']!, _assetKeyMeta));
    } else if (isInserting) {
      context.missing(_assetKeyMeta);
    }
    if (data.containsKey('block_name')) {
      context.handle(_blockNameMeta,
          blockName.isAcceptableOrUnknown(data['block_name']!, _blockNameMeta));
    } else if (isInserting) {
      context.missing(_blockNameMeta);
    }
    if (data.containsKey('block_type')) {
      context.handle(_blockTypeMeta,
          blockType.isAcceptableOrUnknown(data['block_type']!, _blockTypeMeta));
    } else if (isInserting) {
      context.missing(_blockTypeMeta);
    }
    if (data.containsKey('file_path')) {
      context.handle(_filePathMeta,
          filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta));
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('declaration')) {
      context.handle(
          _declarationMeta,
          declaration.isAcceptableOrUnknown(
              data['declaration']!, _declarationMeta));
    } else if (isInserting) {
      context.missing(_declarationMeta);
    }
    if (data.containsKey('implementation')) {
      context.handle(
          _implementationMeta,
          implementation.isAcceptableOrUnknown(
              data['implementation']!, _implementationMeta));
    }
    if (data.containsKey('full_source')) {
      context.handle(
          _fullSourceMeta,
          fullSource.isAcceptableOrUnknown(
              data['full_source']!, _fullSourceMeta));
    } else if (isInserting) {
      context.missing(_fullSourceMeta);
    }
    if (data.containsKey('parent_block_id')) {
      context.handle(
          _parentBlockIdMeta,
          parentBlockId.isAcceptableOrUnknown(
              data['parent_block_id']!, _parentBlockIdMeta));
    }
    if (data.containsKey('indexed_at')) {
      context.handle(_indexedAtMeta,
          indexedAt.isAcceptableOrUnknown(data['indexed_at']!, _indexedAtMeta));
    } else if (isInserting) {
      context.missing(_indexedAtMeta);
    }
    if (data.containsKey('vendor_type')) {
      context.handle(
          _vendorTypeMeta,
          vendorType.isAcceptableOrUnknown(
              data['vendor_type']!, _vendorTypeMeta));
    }
    if (data.containsKey('server_alias')) {
      context.handle(
          _serverAliasMeta,
          serverAlias.isAcceptableOrUnknown(
              data['server_alias']!, _serverAliasMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlcCodeBlockTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlcCodeBlockTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      assetKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}asset_key'])!,
      blockName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}block_name'])!,
      blockType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}block_type'])!,
      filePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}file_path'])!,
      declaration: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}declaration'])!,
      implementation: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}implementation']),
      fullSource: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}full_source'])!,
      parentBlockId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}parent_block_id']),
      indexedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}indexed_at'])!,
      vendorType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}vendor_type']),
      serverAlias: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}server_alias']),
    );
  }

  @override
  $PlcCodeBlockTableTable createAlias(String alias) {
    return $PlcCodeBlockTableTable(attachedDatabase, alias);
  }
}

class PlcCodeBlockTableData extends DataClass
    implements Insertable<PlcCodeBlockTableData> {
  final int id;
  final String assetKey;
  final String blockName;
  final String blockType;
  final String filePath;
  final String declaration;
  final String? implementation;
  final String fullSource;
  final int? parentBlockId;
  final DateTime indexedAt;

  /// PLC vendor type: "twincat", "schneider_control_expert",
  /// "schneider_machine_expert". Null defaults to "twincat" for
  /// backward compatibility with existing data.
  final String? vendorType;

  /// StateMan server alias linking PLC code to OPC UA server scope.
  /// Replaces direct Beckhoff asset key linkage with server-scoped
  /// correlation chain: server alias -> key mappings -> OPC UA identifiers
  /// -> PLC qualified names -> code blocks.
  final String? serverAlias;
  const PlcCodeBlockTableData(
      {required this.id,
      required this.assetKey,
      required this.blockName,
      required this.blockType,
      required this.filePath,
      required this.declaration,
      this.implementation,
      required this.fullSource,
      this.parentBlockId,
      required this.indexedAt,
      this.vendorType,
      this.serverAlias});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['asset_key'] = Variable<String>(assetKey);
    map['block_name'] = Variable<String>(blockName);
    map['block_type'] = Variable<String>(blockType);
    map['file_path'] = Variable<String>(filePath);
    map['declaration'] = Variable<String>(declaration);
    if (!nullToAbsent || implementation != null) {
      map['implementation'] = Variable<String>(implementation);
    }
    map['full_source'] = Variable<String>(fullSource);
    if (!nullToAbsent || parentBlockId != null) {
      map['parent_block_id'] = Variable<int>(parentBlockId);
    }
    map['indexed_at'] = Variable<DateTime>(indexedAt);
    if (!nullToAbsent || vendorType != null) {
      map['vendor_type'] = Variable<String>(vendorType);
    }
    if (!nullToAbsent || serverAlias != null) {
      map['server_alias'] = Variable<String>(serverAlias);
    }
    return map;
  }

  PlcCodeBlockTableCompanion toCompanion(bool nullToAbsent) {
    return PlcCodeBlockTableCompanion(
      id: Value(id),
      assetKey: Value(assetKey),
      blockName: Value(blockName),
      blockType: Value(blockType),
      filePath: Value(filePath),
      declaration: Value(declaration),
      implementation: implementation == null && nullToAbsent
          ? const Value.absent()
          : Value(implementation),
      fullSource: Value(fullSource),
      parentBlockId: parentBlockId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentBlockId),
      indexedAt: Value(indexedAt),
      vendorType: vendorType == null && nullToAbsent
          ? const Value.absent()
          : Value(vendorType),
      serverAlias: serverAlias == null && nullToAbsent
          ? const Value.absent()
          : Value(serverAlias),
    );
  }

  factory PlcCodeBlockTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlcCodeBlockTableData(
      id: serializer.fromJson<int>(json['id']),
      assetKey: serializer.fromJson<String>(json['assetKey']),
      blockName: serializer.fromJson<String>(json['blockName']),
      blockType: serializer.fromJson<String>(json['blockType']),
      filePath: serializer.fromJson<String>(json['filePath']),
      declaration: serializer.fromJson<String>(json['declaration']),
      implementation: serializer.fromJson<String?>(json['implementation']),
      fullSource: serializer.fromJson<String>(json['fullSource']),
      parentBlockId: serializer.fromJson<int?>(json['parentBlockId']),
      indexedAt: serializer.fromJson<DateTime>(json['indexedAt']),
      vendorType: serializer.fromJson<String?>(json['vendorType']),
      serverAlias: serializer.fromJson<String?>(json['serverAlias']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'assetKey': serializer.toJson<String>(assetKey),
      'blockName': serializer.toJson<String>(blockName),
      'blockType': serializer.toJson<String>(blockType),
      'filePath': serializer.toJson<String>(filePath),
      'declaration': serializer.toJson<String>(declaration),
      'implementation': serializer.toJson<String?>(implementation),
      'fullSource': serializer.toJson<String>(fullSource),
      'parentBlockId': serializer.toJson<int?>(parentBlockId),
      'indexedAt': serializer.toJson<DateTime>(indexedAt),
      'vendorType': serializer.toJson<String?>(vendorType),
      'serverAlias': serializer.toJson<String?>(serverAlias),
    };
  }

  PlcCodeBlockTableData copyWith(
          {int? id,
          String? assetKey,
          String? blockName,
          String? blockType,
          String? filePath,
          String? declaration,
          Value<String?> implementation = const Value.absent(),
          String? fullSource,
          Value<int?> parentBlockId = const Value.absent(),
          DateTime? indexedAt,
          Value<String?> vendorType = const Value.absent(),
          Value<String?> serverAlias = const Value.absent()}) =>
      PlcCodeBlockTableData(
        id: id ?? this.id,
        assetKey: assetKey ?? this.assetKey,
        blockName: blockName ?? this.blockName,
        blockType: blockType ?? this.blockType,
        filePath: filePath ?? this.filePath,
        declaration: declaration ?? this.declaration,
        implementation:
            implementation.present ? implementation.value : this.implementation,
        fullSource: fullSource ?? this.fullSource,
        parentBlockId:
            parentBlockId.present ? parentBlockId.value : this.parentBlockId,
        indexedAt: indexedAt ?? this.indexedAt,
        vendorType: vendorType.present ? vendorType.value : this.vendorType,
        serverAlias: serverAlias.present ? serverAlias.value : this.serverAlias,
      );
  PlcCodeBlockTableData copyWithCompanion(PlcCodeBlockTableCompanion data) {
    return PlcCodeBlockTableData(
      id: data.id.present ? data.id.value : this.id,
      assetKey: data.assetKey.present ? data.assetKey.value : this.assetKey,
      blockName: data.blockName.present ? data.blockName.value : this.blockName,
      blockType: data.blockType.present ? data.blockType.value : this.blockType,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      declaration:
          data.declaration.present ? data.declaration.value : this.declaration,
      implementation: data.implementation.present
          ? data.implementation.value
          : this.implementation,
      fullSource:
          data.fullSource.present ? data.fullSource.value : this.fullSource,
      parentBlockId: data.parentBlockId.present
          ? data.parentBlockId.value
          : this.parentBlockId,
      indexedAt: data.indexedAt.present ? data.indexedAt.value : this.indexedAt,
      vendorType:
          data.vendorType.present ? data.vendorType.value : this.vendorType,
      serverAlias:
          data.serverAlias.present ? data.serverAlias.value : this.serverAlias,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlcCodeBlockTableData(')
          ..write('id: $id, ')
          ..write('assetKey: $assetKey, ')
          ..write('blockName: $blockName, ')
          ..write('blockType: $blockType, ')
          ..write('filePath: $filePath, ')
          ..write('declaration: $declaration, ')
          ..write('implementation: $implementation, ')
          ..write('fullSource: $fullSource, ')
          ..write('parentBlockId: $parentBlockId, ')
          ..write('indexedAt: $indexedAt, ')
          ..write('vendorType: $vendorType, ')
          ..write('serverAlias: $serverAlias')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      assetKey,
      blockName,
      blockType,
      filePath,
      declaration,
      implementation,
      fullSource,
      parentBlockId,
      indexedAt,
      vendorType,
      serverAlias);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlcCodeBlockTableData &&
          other.id == this.id &&
          other.assetKey == this.assetKey &&
          other.blockName == this.blockName &&
          other.blockType == this.blockType &&
          other.filePath == this.filePath &&
          other.declaration == this.declaration &&
          other.implementation == this.implementation &&
          other.fullSource == this.fullSource &&
          other.parentBlockId == this.parentBlockId &&
          other.indexedAt == this.indexedAt &&
          other.vendorType == this.vendorType &&
          other.serverAlias == this.serverAlias);
}

class PlcCodeBlockTableCompanion
    extends UpdateCompanion<PlcCodeBlockTableData> {
  final Value<int> id;
  final Value<String> assetKey;
  final Value<String> blockName;
  final Value<String> blockType;
  final Value<String> filePath;
  final Value<String> declaration;
  final Value<String?> implementation;
  final Value<String> fullSource;
  final Value<int?> parentBlockId;
  final Value<DateTime> indexedAt;
  final Value<String?> vendorType;
  final Value<String?> serverAlias;
  const PlcCodeBlockTableCompanion({
    this.id = const Value.absent(),
    this.assetKey = const Value.absent(),
    this.blockName = const Value.absent(),
    this.blockType = const Value.absent(),
    this.filePath = const Value.absent(),
    this.declaration = const Value.absent(),
    this.implementation = const Value.absent(),
    this.fullSource = const Value.absent(),
    this.parentBlockId = const Value.absent(),
    this.indexedAt = const Value.absent(),
    this.vendorType = const Value.absent(),
    this.serverAlias = const Value.absent(),
  });
  PlcCodeBlockTableCompanion.insert({
    this.id = const Value.absent(),
    required String assetKey,
    required String blockName,
    required String blockType,
    required String filePath,
    required String declaration,
    this.implementation = const Value.absent(),
    required String fullSource,
    this.parentBlockId = const Value.absent(),
    required DateTime indexedAt,
    this.vendorType = const Value.absent(),
    this.serverAlias = const Value.absent(),
  })  : assetKey = Value(assetKey),
        blockName = Value(blockName),
        blockType = Value(blockType),
        filePath = Value(filePath),
        declaration = Value(declaration),
        fullSource = Value(fullSource),
        indexedAt = Value(indexedAt);
  static Insertable<PlcCodeBlockTableData> custom({
    Expression<int>? id,
    Expression<String>? assetKey,
    Expression<String>? blockName,
    Expression<String>? blockType,
    Expression<String>? filePath,
    Expression<String>? declaration,
    Expression<String>? implementation,
    Expression<String>? fullSource,
    Expression<int>? parentBlockId,
    Expression<DateTime>? indexedAt,
    Expression<String>? vendorType,
    Expression<String>? serverAlias,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (assetKey != null) 'asset_key': assetKey,
      if (blockName != null) 'block_name': blockName,
      if (blockType != null) 'block_type': blockType,
      if (filePath != null) 'file_path': filePath,
      if (declaration != null) 'declaration': declaration,
      if (implementation != null) 'implementation': implementation,
      if (fullSource != null) 'full_source': fullSource,
      if (parentBlockId != null) 'parent_block_id': parentBlockId,
      if (indexedAt != null) 'indexed_at': indexedAt,
      if (vendorType != null) 'vendor_type': vendorType,
      if (serverAlias != null) 'server_alias': serverAlias,
    });
  }

  PlcCodeBlockTableCompanion copyWith(
      {Value<int>? id,
      Value<String>? assetKey,
      Value<String>? blockName,
      Value<String>? blockType,
      Value<String>? filePath,
      Value<String>? declaration,
      Value<String?>? implementation,
      Value<String>? fullSource,
      Value<int?>? parentBlockId,
      Value<DateTime>? indexedAt,
      Value<String?>? vendorType,
      Value<String?>? serverAlias}) {
    return PlcCodeBlockTableCompanion(
      id: id ?? this.id,
      assetKey: assetKey ?? this.assetKey,
      blockName: blockName ?? this.blockName,
      blockType: blockType ?? this.blockType,
      filePath: filePath ?? this.filePath,
      declaration: declaration ?? this.declaration,
      implementation: implementation ?? this.implementation,
      fullSource: fullSource ?? this.fullSource,
      parentBlockId: parentBlockId ?? this.parentBlockId,
      indexedAt: indexedAt ?? this.indexedAt,
      vendorType: vendorType ?? this.vendorType,
      serverAlias: serverAlias ?? this.serverAlias,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (assetKey.present) {
      map['asset_key'] = Variable<String>(assetKey.value);
    }
    if (blockName.present) {
      map['block_name'] = Variable<String>(blockName.value);
    }
    if (blockType.present) {
      map['block_type'] = Variable<String>(blockType.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (declaration.present) {
      map['declaration'] = Variable<String>(declaration.value);
    }
    if (implementation.present) {
      map['implementation'] = Variable<String>(implementation.value);
    }
    if (fullSource.present) {
      map['full_source'] = Variable<String>(fullSource.value);
    }
    if (parentBlockId.present) {
      map['parent_block_id'] = Variable<int>(parentBlockId.value);
    }
    if (indexedAt.present) {
      map['indexed_at'] = Variable<DateTime>(indexedAt.value);
    }
    if (vendorType.present) {
      map['vendor_type'] = Variable<String>(vendorType.value);
    }
    if (serverAlias.present) {
      map['server_alias'] = Variable<String>(serverAlias.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlcCodeBlockTableCompanion(')
          ..write('id: $id, ')
          ..write('assetKey: $assetKey, ')
          ..write('blockName: $blockName, ')
          ..write('blockType: $blockType, ')
          ..write('filePath: $filePath, ')
          ..write('declaration: $declaration, ')
          ..write('implementation: $implementation, ')
          ..write('fullSource: $fullSource, ')
          ..write('parentBlockId: $parentBlockId, ')
          ..write('indexedAt: $indexedAt, ')
          ..write('vendorType: $vendorType, ')
          ..write('serverAlias: $serverAlias')
          ..write(')'))
        .toString();
  }
}

class $PlcVariableTableTable extends PlcVariableTable
    with TableInfo<$PlcVariableTableTable, PlcVariableTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlcVariableTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _blockIdMeta =
      const VerificationMeta('blockId');
  @override
  late final GeneratedColumn<int> blockId = GeneratedColumn<int>(
      'block_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES plc_code_block (id)'));
  static const VerificationMeta _variableNameMeta =
      const VerificationMeta('variableName');
  @override
  late final GeneratedColumn<String> variableName = GeneratedColumn<String>(
      'variable_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _variableTypeMeta =
      const VerificationMeta('variableType');
  @override
  late final GeneratedColumn<String> variableType = GeneratedColumn<String>(
      'variable_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sectionMeta =
      const VerificationMeta('section');
  @override
  late final GeneratedColumn<String> section = GeneratedColumn<String>(
      'section', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _qualifiedNameMeta =
      const VerificationMeta('qualifiedName');
  @override
  late final GeneratedColumn<String> qualifiedName = GeneratedColumn<String>(
      'qualified_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _commentMeta =
      const VerificationMeta('comment');
  @override
  late final GeneratedColumn<String> comment = GeneratedColumn<String>(
      'comment', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        blockId,
        variableName,
        variableType,
        section,
        qualifiedName,
        comment
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plc_variable';
  @override
  VerificationContext validateIntegrity(
      Insertable<PlcVariableTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('block_id')) {
      context.handle(_blockIdMeta,
          blockId.isAcceptableOrUnknown(data['block_id']!, _blockIdMeta));
    } else if (isInserting) {
      context.missing(_blockIdMeta);
    }
    if (data.containsKey('variable_name')) {
      context.handle(
          _variableNameMeta,
          variableName.isAcceptableOrUnknown(
              data['variable_name']!, _variableNameMeta));
    } else if (isInserting) {
      context.missing(_variableNameMeta);
    }
    if (data.containsKey('variable_type')) {
      context.handle(
          _variableTypeMeta,
          variableType.isAcceptableOrUnknown(
              data['variable_type']!, _variableTypeMeta));
    } else if (isInserting) {
      context.missing(_variableTypeMeta);
    }
    if (data.containsKey('section')) {
      context.handle(_sectionMeta,
          section.isAcceptableOrUnknown(data['section']!, _sectionMeta));
    } else if (isInserting) {
      context.missing(_sectionMeta);
    }
    if (data.containsKey('qualified_name')) {
      context.handle(
          _qualifiedNameMeta,
          qualifiedName.isAcceptableOrUnknown(
              data['qualified_name']!, _qualifiedNameMeta));
    } else if (isInserting) {
      context.missing(_qualifiedNameMeta);
    }
    if (data.containsKey('comment')) {
      context.handle(_commentMeta,
          comment.isAcceptableOrUnknown(data['comment']!, _commentMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlcVariableTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlcVariableTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      blockId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}block_id'])!,
      variableName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}variable_name'])!,
      variableType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}variable_type'])!,
      section: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}section'])!,
      qualifiedName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}qualified_name'])!,
      comment: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}comment']),
    );
  }

  @override
  $PlcVariableTableTable createAlias(String alias) {
    return $PlcVariableTableTable(attachedDatabase, alias);
  }
}

class PlcVariableTableData extends DataClass
    implements Insertable<PlcVariableTableData> {
  final int id;
  final int blockId;
  final String variableName;
  final String variableType;
  final String section;
  final String qualifiedName;
  final String? comment;
  const PlcVariableTableData(
      {required this.id,
      required this.blockId,
      required this.variableName,
      required this.variableType,
      required this.section,
      required this.qualifiedName,
      this.comment});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['block_id'] = Variable<int>(blockId);
    map['variable_name'] = Variable<String>(variableName);
    map['variable_type'] = Variable<String>(variableType);
    map['section'] = Variable<String>(section);
    map['qualified_name'] = Variable<String>(qualifiedName);
    if (!nullToAbsent || comment != null) {
      map['comment'] = Variable<String>(comment);
    }
    return map;
  }

  PlcVariableTableCompanion toCompanion(bool nullToAbsent) {
    return PlcVariableTableCompanion(
      id: Value(id),
      blockId: Value(blockId),
      variableName: Value(variableName),
      variableType: Value(variableType),
      section: Value(section),
      qualifiedName: Value(qualifiedName),
      comment: comment == null && nullToAbsent
          ? const Value.absent()
          : Value(comment),
    );
  }

  factory PlcVariableTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlcVariableTableData(
      id: serializer.fromJson<int>(json['id']),
      blockId: serializer.fromJson<int>(json['blockId']),
      variableName: serializer.fromJson<String>(json['variableName']),
      variableType: serializer.fromJson<String>(json['variableType']),
      section: serializer.fromJson<String>(json['section']),
      qualifiedName: serializer.fromJson<String>(json['qualifiedName']),
      comment: serializer.fromJson<String?>(json['comment']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'blockId': serializer.toJson<int>(blockId),
      'variableName': serializer.toJson<String>(variableName),
      'variableType': serializer.toJson<String>(variableType),
      'section': serializer.toJson<String>(section),
      'qualifiedName': serializer.toJson<String>(qualifiedName),
      'comment': serializer.toJson<String?>(comment),
    };
  }

  PlcVariableTableData copyWith(
          {int? id,
          int? blockId,
          String? variableName,
          String? variableType,
          String? section,
          String? qualifiedName,
          Value<String?> comment = const Value.absent()}) =>
      PlcVariableTableData(
        id: id ?? this.id,
        blockId: blockId ?? this.blockId,
        variableName: variableName ?? this.variableName,
        variableType: variableType ?? this.variableType,
        section: section ?? this.section,
        qualifiedName: qualifiedName ?? this.qualifiedName,
        comment: comment.present ? comment.value : this.comment,
      );
  PlcVariableTableData copyWithCompanion(PlcVariableTableCompanion data) {
    return PlcVariableTableData(
      id: data.id.present ? data.id.value : this.id,
      blockId: data.blockId.present ? data.blockId.value : this.blockId,
      variableName: data.variableName.present
          ? data.variableName.value
          : this.variableName,
      variableType: data.variableType.present
          ? data.variableType.value
          : this.variableType,
      section: data.section.present ? data.section.value : this.section,
      qualifiedName: data.qualifiedName.present
          ? data.qualifiedName.value
          : this.qualifiedName,
      comment: data.comment.present ? data.comment.value : this.comment,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlcVariableTableData(')
          ..write('id: $id, ')
          ..write('blockId: $blockId, ')
          ..write('variableName: $variableName, ')
          ..write('variableType: $variableType, ')
          ..write('section: $section, ')
          ..write('qualifiedName: $qualifiedName, ')
          ..write('comment: $comment')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, blockId, variableName, variableType, section, qualifiedName, comment);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlcVariableTableData &&
          other.id == this.id &&
          other.blockId == this.blockId &&
          other.variableName == this.variableName &&
          other.variableType == this.variableType &&
          other.section == this.section &&
          other.qualifiedName == this.qualifiedName &&
          other.comment == this.comment);
}

class PlcVariableTableCompanion extends UpdateCompanion<PlcVariableTableData> {
  final Value<int> id;
  final Value<int> blockId;
  final Value<String> variableName;
  final Value<String> variableType;
  final Value<String> section;
  final Value<String> qualifiedName;
  final Value<String?> comment;
  const PlcVariableTableCompanion({
    this.id = const Value.absent(),
    this.blockId = const Value.absent(),
    this.variableName = const Value.absent(),
    this.variableType = const Value.absent(),
    this.section = const Value.absent(),
    this.qualifiedName = const Value.absent(),
    this.comment = const Value.absent(),
  });
  PlcVariableTableCompanion.insert({
    this.id = const Value.absent(),
    required int blockId,
    required String variableName,
    required String variableType,
    required String section,
    required String qualifiedName,
    this.comment = const Value.absent(),
  })  : blockId = Value(blockId),
        variableName = Value(variableName),
        variableType = Value(variableType),
        section = Value(section),
        qualifiedName = Value(qualifiedName);
  static Insertable<PlcVariableTableData> custom({
    Expression<int>? id,
    Expression<int>? blockId,
    Expression<String>? variableName,
    Expression<String>? variableType,
    Expression<String>? section,
    Expression<String>? qualifiedName,
    Expression<String>? comment,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (blockId != null) 'block_id': blockId,
      if (variableName != null) 'variable_name': variableName,
      if (variableType != null) 'variable_type': variableType,
      if (section != null) 'section': section,
      if (qualifiedName != null) 'qualified_name': qualifiedName,
      if (comment != null) 'comment': comment,
    });
  }

  PlcVariableTableCompanion copyWith(
      {Value<int>? id,
      Value<int>? blockId,
      Value<String>? variableName,
      Value<String>? variableType,
      Value<String>? section,
      Value<String>? qualifiedName,
      Value<String?>? comment}) {
    return PlcVariableTableCompanion(
      id: id ?? this.id,
      blockId: blockId ?? this.blockId,
      variableName: variableName ?? this.variableName,
      variableType: variableType ?? this.variableType,
      section: section ?? this.section,
      qualifiedName: qualifiedName ?? this.qualifiedName,
      comment: comment ?? this.comment,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (blockId.present) {
      map['block_id'] = Variable<int>(blockId.value);
    }
    if (variableName.present) {
      map['variable_name'] = Variable<String>(variableName.value);
    }
    if (variableType.present) {
      map['variable_type'] = Variable<String>(variableType.value);
    }
    if (section.present) {
      map['section'] = Variable<String>(section.value);
    }
    if (qualifiedName.present) {
      map['qualified_name'] = Variable<String>(qualifiedName.value);
    }
    if (comment.present) {
      map['comment'] = Variable<String>(comment.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlcVariableTableCompanion(')
          ..write('id: $id, ')
          ..write('blockId: $blockId, ')
          ..write('variableName: $variableName, ')
          ..write('variableType: $variableType, ')
          ..write('section: $section, ')
          ..write('qualifiedName: $qualifiedName, ')
          ..write('comment: $comment')
          ..write(')'))
        .toString();
  }
}

class $DrawingTableTable extends DrawingTable
    with TableInfo<$DrawingTableTable, DrawingTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DrawingTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _assetKeyMeta =
      const VerificationMeta('assetKey');
  @override
  late final GeneratedColumn<String> assetKey = GeneratedColumn<String>(
      'asset_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _drawingNameMeta =
      const VerificationMeta('drawingName');
  @override
  late final GeneratedColumn<String> drawingName = GeneratedColumn<String>(
      'drawing_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _filePathMeta =
      const VerificationMeta('filePath');
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
      'file_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pageCountMeta =
      const VerificationMeta('pageCount');
  @override
  late final GeneratedColumn<int> pageCount = GeneratedColumn<int>(
      'page_count', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _uploadedAtMeta =
      const VerificationMeta('uploadedAt');
  @override
  late final GeneratedColumn<DateTime> uploadedAt = GeneratedColumn<DateTime>(
      'uploaded_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _pdfBytesMeta =
      const VerificationMeta('pdfBytes');
  @override
  late final GeneratedColumn<Uint8List> pdfBytes = GeneratedColumn<Uint8List>(
      'pdf_bytes', aliasedName, true,
      type: DriftSqlType.blob, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, assetKey, drawingName, filePath, pageCount, uploadedAt, pdfBytes];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'drawing';
  @override
  VerificationContext validateIntegrity(Insertable<DrawingTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('asset_key')) {
      context.handle(_assetKeyMeta,
          assetKey.isAcceptableOrUnknown(data['asset_key']!, _assetKeyMeta));
    } else if (isInserting) {
      context.missing(_assetKeyMeta);
    }
    if (data.containsKey('drawing_name')) {
      context.handle(
          _drawingNameMeta,
          drawingName.isAcceptableOrUnknown(
              data['drawing_name']!, _drawingNameMeta));
    } else if (isInserting) {
      context.missing(_drawingNameMeta);
    }
    if (data.containsKey('file_path')) {
      context.handle(_filePathMeta,
          filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta));
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('page_count')) {
      context.handle(_pageCountMeta,
          pageCount.isAcceptableOrUnknown(data['page_count']!, _pageCountMeta));
    } else if (isInserting) {
      context.missing(_pageCountMeta);
    }
    if (data.containsKey('uploaded_at')) {
      context.handle(
          _uploadedAtMeta,
          uploadedAt.isAcceptableOrUnknown(
              data['uploaded_at']!, _uploadedAtMeta));
    } else if (isInserting) {
      context.missing(_uploadedAtMeta);
    }
    if (data.containsKey('pdf_bytes')) {
      context.handle(_pdfBytesMeta,
          pdfBytes.isAcceptableOrUnknown(data['pdf_bytes']!, _pdfBytesMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DrawingTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DrawingTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      assetKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}asset_key'])!,
      drawingName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}drawing_name'])!,
      filePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}file_path'])!,
      pageCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_count'])!,
      uploadedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}uploaded_at'])!,
      pdfBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}pdf_bytes']),
    );
  }

  @override
  $DrawingTableTable createAlias(String alias) {
    return $DrawingTableTable(attachedDatabase, alias);
  }
}

class DrawingTableData extends DataClass
    implements Insertable<DrawingTableData> {
  final int id;
  final String assetKey;
  final String drawingName;
  final String filePath;
  final int pageCount;
  final DateTime uploadedAt;

  /// Optional PDF blob storage for drawings.
  /// Nullable because existing drawings use filesystem path only.
  final Uint8List? pdfBytes;
  const DrawingTableData(
      {required this.id,
      required this.assetKey,
      required this.drawingName,
      required this.filePath,
      required this.pageCount,
      required this.uploadedAt,
      this.pdfBytes});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['asset_key'] = Variable<String>(assetKey);
    map['drawing_name'] = Variable<String>(drawingName);
    map['file_path'] = Variable<String>(filePath);
    map['page_count'] = Variable<int>(pageCount);
    map['uploaded_at'] = Variable<DateTime>(uploadedAt);
    if (!nullToAbsent || pdfBytes != null) {
      map['pdf_bytes'] = Variable<Uint8List>(pdfBytes);
    }
    return map;
  }

  DrawingTableCompanion toCompanion(bool nullToAbsent) {
    return DrawingTableCompanion(
      id: Value(id),
      assetKey: Value(assetKey),
      drawingName: Value(drawingName),
      filePath: Value(filePath),
      pageCount: Value(pageCount),
      uploadedAt: Value(uploadedAt),
      pdfBytes: pdfBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(pdfBytes),
    );
  }

  factory DrawingTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DrawingTableData(
      id: serializer.fromJson<int>(json['id']),
      assetKey: serializer.fromJson<String>(json['assetKey']),
      drawingName: serializer.fromJson<String>(json['drawingName']),
      filePath: serializer.fromJson<String>(json['filePath']),
      pageCount: serializer.fromJson<int>(json['pageCount']),
      uploadedAt: serializer.fromJson<DateTime>(json['uploadedAt']),
      pdfBytes: serializer.fromJson<Uint8List?>(json['pdfBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'assetKey': serializer.toJson<String>(assetKey),
      'drawingName': serializer.toJson<String>(drawingName),
      'filePath': serializer.toJson<String>(filePath),
      'pageCount': serializer.toJson<int>(pageCount),
      'uploadedAt': serializer.toJson<DateTime>(uploadedAt),
      'pdfBytes': serializer.toJson<Uint8List?>(pdfBytes),
    };
  }

  DrawingTableData copyWith(
          {int? id,
          String? assetKey,
          String? drawingName,
          String? filePath,
          int? pageCount,
          DateTime? uploadedAt,
          Value<Uint8List?> pdfBytes = const Value.absent()}) =>
      DrawingTableData(
        id: id ?? this.id,
        assetKey: assetKey ?? this.assetKey,
        drawingName: drawingName ?? this.drawingName,
        filePath: filePath ?? this.filePath,
        pageCount: pageCount ?? this.pageCount,
        uploadedAt: uploadedAt ?? this.uploadedAt,
        pdfBytes: pdfBytes.present ? pdfBytes.value : this.pdfBytes,
      );
  DrawingTableData copyWithCompanion(DrawingTableCompanion data) {
    return DrawingTableData(
      id: data.id.present ? data.id.value : this.id,
      assetKey: data.assetKey.present ? data.assetKey.value : this.assetKey,
      drawingName:
          data.drawingName.present ? data.drawingName.value : this.drawingName,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      pageCount: data.pageCount.present ? data.pageCount.value : this.pageCount,
      uploadedAt:
          data.uploadedAt.present ? data.uploadedAt.value : this.uploadedAt,
      pdfBytes: data.pdfBytes.present ? data.pdfBytes.value : this.pdfBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DrawingTableData(')
          ..write('id: $id, ')
          ..write('assetKey: $assetKey, ')
          ..write('drawingName: $drawingName, ')
          ..write('filePath: $filePath, ')
          ..write('pageCount: $pageCount, ')
          ..write('uploadedAt: $uploadedAt, ')
          ..write('pdfBytes: $pdfBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, assetKey, drawingName, filePath,
      pageCount, uploadedAt, $driftBlobEquality.hash(pdfBytes));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DrawingTableData &&
          other.id == this.id &&
          other.assetKey == this.assetKey &&
          other.drawingName == this.drawingName &&
          other.filePath == this.filePath &&
          other.pageCount == this.pageCount &&
          other.uploadedAt == this.uploadedAt &&
          $driftBlobEquality.equals(other.pdfBytes, this.pdfBytes));
}

class DrawingTableCompanion extends UpdateCompanion<DrawingTableData> {
  final Value<int> id;
  final Value<String> assetKey;
  final Value<String> drawingName;
  final Value<String> filePath;
  final Value<int> pageCount;
  final Value<DateTime> uploadedAt;
  final Value<Uint8List?> pdfBytes;
  const DrawingTableCompanion({
    this.id = const Value.absent(),
    this.assetKey = const Value.absent(),
    this.drawingName = const Value.absent(),
    this.filePath = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.uploadedAt = const Value.absent(),
    this.pdfBytes = const Value.absent(),
  });
  DrawingTableCompanion.insert({
    this.id = const Value.absent(),
    required String assetKey,
    required String drawingName,
    required String filePath,
    required int pageCount,
    required DateTime uploadedAt,
    this.pdfBytes = const Value.absent(),
  })  : assetKey = Value(assetKey),
        drawingName = Value(drawingName),
        filePath = Value(filePath),
        pageCount = Value(pageCount),
        uploadedAt = Value(uploadedAt);
  static Insertable<DrawingTableData> custom({
    Expression<int>? id,
    Expression<String>? assetKey,
    Expression<String>? drawingName,
    Expression<String>? filePath,
    Expression<int>? pageCount,
    Expression<DateTime>? uploadedAt,
    Expression<Uint8List>? pdfBytes,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (assetKey != null) 'asset_key': assetKey,
      if (drawingName != null) 'drawing_name': drawingName,
      if (filePath != null) 'file_path': filePath,
      if (pageCount != null) 'page_count': pageCount,
      if (uploadedAt != null) 'uploaded_at': uploadedAt,
      if (pdfBytes != null) 'pdf_bytes': pdfBytes,
    });
  }

  DrawingTableCompanion copyWith(
      {Value<int>? id,
      Value<String>? assetKey,
      Value<String>? drawingName,
      Value<String>? filePath,
      Value<int>? pageCount,
      Value<DateTime>? uploadedAt,
      Value<Uint8List?>? pdfBytes}) {
    return DrawingTableCompanion(
      id: id ?? this.id,
      assetKey: assetKey ?? this.assetKey,
      drawingName: drawingName ?? this.drawingName,
      filePath: filePath ?? this.filePath,
      pageCount: pageCount ?? this.pageCount,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      pdfBytes: pdfBytes ?? this.pdfBytes,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (assetKey.present) {
      map['asset_key'] = Variable<String>(assetKey.value);
    }
    if (drawingName.present) {
      map['drawing_name'] = Variable<String>(drawingName.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (pageCount.present) {
      map['page_count'] = Variable<int>(pageCount.value);
    }
    if (uploadedAt.present) {
      map['uploaded_at'] = Variable<DateTime>(uploadedAt.value);
    }
    if (pdfBytes.present) {
      map['pdf_bytes'] = Variable<Uint8List>(pdfBytes.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DrawingTableCompanion(')
          ..write('id: $id, ')
          ..write('assetKey: $assetKey, ')
          ..write('drawingName: $drawingName, ')
          ..write('filePath: $filePath, ')
          ..write('pageCount: $pageCount, ')
          ..write('uploadedAt: $uploadedAt, ')
          ..write('pdfBytes: $pdfBytes')
          ..write(')'))
        .toString();
  }
}

class $DrawingComponentTableTable extends DrawingComponentTable
    with TableInfo<$DrawingComponentTableTable, DrawingComponentTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DrawingComponentTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _drawingIdMeta =
      const VerificationMeta('drawingId');
  @override
  late final GeneratedColumn<int> drawingId = GeneratedColumn<int>(
      'drawing_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES drawing (id)'));
  static const VerificationMeta _pageNumberMeta =
      const VerificationMeta('pageNumber');
  @override
  late final GeneratedColumn<int> pageNumber = GeneratedColumn<int>(
      'page_number', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _fullPageTextMeta =
      const VerificationMeta('fullPageText');
  @override
  late final GeneratedColumn<String> fullPageText = GeneratedColumn<String>(
      'full_page_text', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, drawingId, pageNumber, fullPageText];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'drawing_component';
  @override
  VerificationContext validateIntegrity(
      Insertable<DrawingComponentTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('drawing_id')) {
      context.handle(_drawingIdMeta,
          drawingId.isAcceptableOrUnknown(data['drawing_id']!, _drawingIdMeta));
    } else if (isInserting) {
      context.missing(_drawingIdMeta);
    }
    if (data.containsKey('page_number')) {
      context.handle(
          _pageNumberMeta,
          pageNumber.isAcceptableOrUnknown(
              data['page_number']!, _pageNumberMeta));
    } else if (isInserting) {
      context.missing(_pageNumberMeta);
    }
    if (data.containsKey('full_page_text')) {
      context.handle(
          _fullPageTextMeta,
          fullPageText.isAcceptableOrUnknown(
              data['full_page_text']!, _fullPageTextMeta));
    } else if (isInserting) {
      context.missing(_fullPageTextMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DrawingComponentTableData map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DrawingComponentTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      drawingId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}drawing_id'])!,
      pageNumber: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_number'])!,
      fullPageText: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}full_page_text'])!,
    );
  }

  @override
  $DrawingComponentTableTable createAlias(String alias) {
    return $DrawingComponentTableTable(attachedDatabase, alias);
  }
}

class DrawingComponentTableData extends DataClass
    implements Insertable<DrawingComponentTableData> {
  final int id;
  final int drawingId;
  final int pageNumber;
  final String fullPageText;
  const DrawingComponentTableData(
      {required this.id,
      required this.drawingId,
      required this.pageNumber,
      required this.fullPageText});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['drawing_id'] = Variable<int>(drawingId);
    map['page_number'] = Variable<int>(pageNumber);
    map['full_page_text'] = Variable<String>(fullPageText);
    return map;
  }

  DrawingComponentTableCompanion toCompanion(bool nullToAbsent) {
    return DrawingComponentTableCompanion(
      id: Value(id),
      drawingId: Value(drawingId),
      pageNumber: Value(pageNumber),
      fullPageText: Value(fullPageText),
    );
  }

  factory DrawingComponentTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DrawingComponentTableData(
      id: serializer.fromJson<int>(json['id']),
      drawingId: serializer.fromJson<int>(json['drawingId']),
      pageNumber: serializer.fromJson<int>(json['pageNumber']),
      fullPageText: serializer.fromJson<String>(json['fullPageText']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'drawingId': serializer.toJson<int>(drawingId),
      'pageNumber': serializer.toJson<int>(pageNumber),
      'fullPageText': serializer.toJson<String>(fullPageText),
    };
  }

  DrawingComponentTableData copyWith(
          {int? id, int? drawingId, int? pageNumber, String? fullPageText}) =>
      DrawingComponentTableData(
        id: id ?? this.id,
        drawingId: drawingId ?? this.drawingId,
        pageNumber: pageNumber ?? this.pageNumber,
        fullPageText: fullPageText ?? this.fullPageText,
      );
  DrawingComponentTableData copyWithCompanion(
      DrawingComponentTableCompanion data) {
    return DrawingComponentTableData(
      id: data.id.present ? data.id.value : this.id,
      drawingId: data.drawingId.present ? data.drawingId.value : this.drawingId,
      pageNumber:
          data.pageNumber.present ? data.pageNumber.value : this.pageNumber,
      fullPageText: data.fullPageText.present
          ? data.fullPageText.value
          : this.fullPageText,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DrawingComponentTableData(')
          ..write('id: $id, ')
          ..write('drawingId: $drawingId, ')
          ..write('pageNumber: $pageNumber, ')
          ..write('fullPageText: $fullPageText')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, drawingId, pageNumber, fullPageText);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DrawingComponentTableData &&
          other.id == this.id &&
          other.drawingId == this.drawingId &&
          other.pageNumber == this.pageNumber &&
          other.fullPageText == this.fullPageText);
}

class DrawingComponentTableCompanion
    extends UpdateCompanion<DrawingComponentTableData> {
  final Value<int> id;
  final Value<int> drawingId;
  final Value<int> pageNumber;
  final Value<String> fullPageText;
  const DrawingComponentTableCompanion({
    this.id = const Value.absent(),
    this.drawingId = const Value.absent(),
    this.pageNumber = const Value.absent(),
    this.fullPageText = const Value.absent(),
  });
  DrawingComponentTableCompanion.insert({
    this.id = const Value.absent(),
    required int drawingId,
    required int pageNumber,
    required String fullPageText,
  })  : drawingId = Value(drawingId),
        pageNumber = Value(pageNumber),
        fullPageText = Value(fullPageText);
  static Insertable<DrawingComponentTableData> custom({
    Expression<int>? id,
    Expression<int>? drawingId,
    Expression<int>? pageNumber,
    Expression<String>? fullPageText,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (drawingId != null) 'drawing_id': drawingId,
      if (pageNumber != null) 'page_number': pageNumber,
      if (fullPageText != null) 'full_page_text': fullPageText,
    });
  }

  DrawingComponentTableCompanion copyWith(
      {Value<int>? id,
      Value<int>? drawingId,
      Value<int>? pageNumber,
      Value<String>? fullPageText}) {
    return DrawingComponentTableCompanion(
      id: id ?? this.id,
      drawingId: drawingId ?? this.drawingId,
      pageNumber: pageNumber ?? this.pageNumber,
      fullPageText: fullPageText ?? this.fullPageText,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (drawingId.present) {
      map['drawing_id'] = Variable<int>(drawingId.value);
    }
    if (pageNumber.present) {
      map['page_number'] = Variable<int>(pageNumber.value);
    }
    if (fullPageText.present) {
      map['full_page_text'] = Variable<String>(fullPageText.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DrawingComponentTableCompanion(')
          ..write('id: $id, ')
          ..write('drawingId: $drawingId, ')
          ..write('pageNumber: $pageNumber, ')
          ..write('fullPageText: $fullPageText')
          ..write(')'))
        .toString();
  }
}

class $TechDocTableTable extends TechDocTable
    with TableInfo<$TechDocTableTable, TechDocTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TechDocTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pdfBytesMeta =
      const VerificationMeta('pdfBytes');
  @override
  late final GeneratedColumn<Uint8List> pdfBytes = GeneratedColumn<Uint8List>(
      'pdf_bytes', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _pageCountMeta =
      const VerificationMeta('pageCount');
  @override
  late final GeneratedColumn<int> pageCount = GeneratedColumn<int>(
      'page_count', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sectionCountMeta =
      const VerificationMeta('sectionCount');
  @override
  late final GeneratedColumn<int> sectionCount = GeneratedColumn<int>(
      'section_count', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _uploadedAtMeta =
      const VerificationMeta('uploadedAt');
  @override
  late final GeneratedColumn<DateTime> uploadedAt = GeneratedColumn<DateTime>(
      'uploaded_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, pdfBytes, pageCount, sectionCount, uploadedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tech_doc';
  @override
  VerificationContext validateIntegrity(Insertable<TechDocTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('pdf_bytes')) {
      context.handle(_pdfBytesMeta,
          pdfBytes.isAcceptableOrUnknown(data['pdf_bytes']!, _pdfBytesMeta));
    } else if (isInserting) {
      context.missing(_pdfBytesMeta);
    }
    if (data.containsKey('page_count')) {
      context.handle(_pageCountMeta,
          pageCount.isAcceptableOrUnknown(data['page_count']!, _pageCountMeta));
    } else if (isInserting) {
      context.missing(_pageCountMeta);
    }
    if (data.containsKey('section_count')) {
      context.handle(
          _sectionCountMeta,
          sectionCount.isAcceptableOrUnknown(
              data['section_count']!, _sectionCountMeta));
    } else if (isInserting) {
      context.missing(_sectionCountMeta);
    }
    if (data.containsKey('uploaded_at')) {
      context.handle(
          _uploadedAtMeta,
          uploadedAt.isAcceptableOrUnknown(
              data['uploaded_at']!, _uploadedAtMeta));
    } else if (isInserting) {
      context.missing(_uploadedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TechDocTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TechDocTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      pdfBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}pdf_bytes'])!,
      pageCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_count'])!,
      sectionCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}section_count'])!,
      uploadedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}uploaded_at'])!,
    );
  }

  @override
  $TechDocTableTable createAlias(String alias) {
    return $TechDocTableTable(attachedDatabase, alias);
  }
}

class TechDocTableData extends DataClass
    implements Insertable<TechDocTableData> {
  final int id;
  final String name;
  final Uint8List pdfBytes;
  final int pageCount;
  final int sectionCount;
  final DateTime uploadedAt;
  const TechDocTableData(
      {required this.id,
      required this.name,
      required this.pdfBytes,
      required this.pageCount,
      required this.sectionCount,
      required this.uploadedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['pdf_bytes'] = Variable<Uint8List>(pdfBytes);
    map['page_count'] = Variable<int>(pageCount);
    map['section_count'] = Variable<int>(sectionCount);
    map['uploaded_at'] = Variable<DateTime>(uploadedAt);
    return map;
  }

  TechDocTableCompanion toCompanion(bool nullToAbsent) {
    return TechDocTableCompanion(
      id: Value(id),
      name: Value(name),
      pdfBytes: Value(pdfBytes),
      pageCount: Value(pageCount),
      sectionCount: Value(sectionCount),
      uploadedAt: Value(uploadedAt),
    );
  }

  factory TechDocTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TechDocTableData(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      pdfBytes: serializer.fromJson<Uint8List>(json['pdfBytes']),
      pageCount: serializer.fromJson<int>(json['pageCount']),
      sectionCount: serializer.fromJson<int>(json['sectionCount']),
      uploadedAt: serializer.fromJson<DateTime>(json['uploadedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'pdfBytes': serializer.toJson<Uint8List>(pdfBytes),
      'pageCount': serializer.toJson<int>(pageCount),
      'sectionCount': serializer.toJson<int>(sectionCount),
      'uploadedAt': serializer.toJson<DateTime>(uploadedAt),
    };
  }

  TechDocTableData copyWith(
          {int? id,
          String? name,
          Uint8List? pdfBytes,
          int? pageCount,
          int? sectionCount,
          DateTime? uploadedAt}) =>
      TechDocTableData(
        id: id ?? this.id,
        name: name ?? this.name,
        pdfBytes: pdfBytes ?? this.pdfBytes,
        pageCount: pageCount ?? this.pageCount,
        sectionCount: sectionCount ?? this.sectionCount,
        uploadedAt: uploadedAt ?? this.uploadedAt,
      );
  TechDocTableData copyWithCompanion(TechDocTableCompanion data) {
    return TechDocTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      pdfBytes: data.pdfBytes.present ? data.pdfBytes.value : this.pdfBytes,
      pageCount: data.pageCount.present ? data.pageCount.value : this.pageCount,
      sectionCount: data.sectionCount.present
          ? data.sectionCount.value
          : this.sectionCount,
      uploadedAt:
          data.uploadedAt.present ? data.uploadedAt.value : this.uploadedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TechDocTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('pdfBytes: $pdfBytes, ')
          ..write('pageCount: $pageCount, ')
          ..write('sectionCount: $sectionCount, ')
          ..write('uploadedAt: $uploadedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, $driftBlobEquality.hash(pdfBytes),
      pageCount, sectionCount, uploadedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TechDocTableData &&
          other.id == this.id &&
          other.name == this.name &&
          $driftBlobEquality.equals(other.pdfBytes, this.pdfBytes) &&
          other.pageCount == this.pageCount &&
          other.sectionCount == this.sectionCount &&
          other.uploadedAt == this.uploadedAt);
}

class TechDocTableCompanion extends UpdateCompanion<TechDocTableData> {
  final Value<int> id;
  final Value<String> name;
  final Value<Uint8List> pdfBytes;
  final Value<int> pageCount;
  final Value<int> sectionCount;
  final Value<DateTime> uploadedAt;
  const TechDocTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.pdfBytes = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.sectionCount = const Value.absent(),
    this.uploadedAt = const Value.absent(),
  });
  TechDocTableCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required Uint8List pdfBytes,
    required int pageCount,
    required int sectionCount,
    required DateTime uploadedAt,
  })  : name = Value(name),
        pdfBytes = Value(pdfBytes),
        pageCount = Value(pageCount),
        sectionCount = Value(sectionCount),
        uploadedAt = Value(uploadedAt);
  static Insertable<TechDocTableData> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<Uint8List>? pdfBytes,
    Expression<int>? pageCount,
    Expression<int>? sectionCount,
    Expression<DateTime>? uploadedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (pdfBytes != null) 'pdf_bytes': pdfBytes,
      if (pageCount != null) 'page_count': pageCount,
      if (sectionCount != null) 'section_count': sectionCount,
      if (uploadedAt != null) 'uploaded_at': uploadedAt,
    });
  }

  TechDocTableCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<Uint8List>? pdfBytes,
      Value<int>? pageCount,
      Value<int>? sectionCount,
      Value<DateTime>? uploadedAt}) {
    return TechDocTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      pdfBytes: pdfBytes ?? this.pdfBytes,
      pageCount: pageCount ?? this.pageCount,
      sectionCount: sectionCount ?? this.sectionCount,
      uploadedAt: uploadedAt ?? this.uploadedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (pdfBytes.present) {
      map['pdf_bytes'] = Variable<Uint8List>(pdfBytes.value);
    }
    if (pageCount.present) {
      map['page_count'] = Variable<int>(pageCount.value);
    }
    if (sectionCount.present) {
      map['section_count'] = Variable<int>(sectionCount.value);
    }
    if (uploadedAt.present) {
      map['uploaded_at'] = Variable<DateTime>(uploadedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TechDocTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('pdfBytes: $pdfBytes, ')
          ..write('pageCount: $pageCount, ')
          ..write('sectionCount: $sectionCount, ')
          ..write('uploadedAt: $uploadedAt')
          ..write(')'))
        .toString();
  }
}

class $TechDocSectionTableTable extends TechDocSectionTable
    with TableInfo<$TechDocSectionTableTable, TechDocSectionTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TechDocSectionTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _docIdMeta = const VerificationMeta('docId');
  @override
  late final GeneratedColumn<int> docId = GeneratedColumn<int>(
      'doc_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES tech_doc (id)'));
  static const VerificationMeta _parentIdMeta =
      const VerificationMeta('parentId');
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
      'parent_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pageStartMeta =
      const VerificationMeta('pageStart');
  @override
  late final GeneratedColumn<int> pageStart = GeneratedColumn<int>(
      'page_start', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _pageEndMeta =
      const VerificationMeta('pageEnd');
  @override
  late final GeneratedColumn<int> pageEnd = GeneratedColumn<int>(
      'page_end', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<int> level = GeneratedColumn<int>(
      'level', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        docId,
        parentId,
        title,
        content,
        pageStart,
        pageEnd,
        level,
        sortOrder
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tech_doc_section';
  @override
  VerificationContext validateIntegrity(
      Insertable<TechDocSectionTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('doc_id')) {
      context.handle(
          _docIdMeta, docId.isAcceptableOrUnknown(data['doc_id']!, _docIdMeta));
    } else if (isInserting) {
      context.missing(_docIdMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(_parentIdMeta,
          parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('page_start')) {
      context.handle(_pageStartMeta,
          pageStart.isAcceptableOrUnknown(data['page_start']!, _pageStartMeta));
    } else if (isInserting) {
      context.missing(_pageStartMeta);
    }
    if (data.containsKey('page_end')) {
      context.handle(_pageEndMeta,
          pageEnd.isAcceptableOrUnknown(data['page_end']!, _pageEndMeta));
    } else if (isInserting) {
      context.missing(_pageEndMeta);
    }
    if (data.containsKey('level')) {
      context.handle(
          _levelMeta, level.isAcceptableOrUnknown(data['level']!, _levelMeta));
    } else if (isInserting) {
      context.missing(_levelMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TechDocSectionTableData map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TechDocSectionTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      docId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}doc_id'])!,
      parentId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}parent_id']),
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content'])!,
      pageStart: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_start'])!,
      pageEnd: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_end'])!,
      level: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}level'])!,
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
    );
  }

  @override
  $TechDocSectionTableTable createAlias(String alias) {
    return $TechDocSectionTableTable(attachedDatabase, alias);
  }
}

class TechDocSectionTableData extends DataClass
    implements Insertable<TechDocSectionTableData> {
  final int id;
  final int docId;
  final int? parentId;
  final String title;
  final String content;
  final int pageStart;
  final int pageEnd;
  final int level;
  final int sortOrder;
  const TechDocSectionTableData(
      {required this.id,
      required this.docId,
      this.parentId,
      required this.title,
      required this.content,
      required this.pageStart,
      required this.pageEnd,
      required this.level,
      required this.sortOrder});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['doc_id'] = Variable<int>(docId);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    map['title'] = Variable<String>(title);
    map['content'] = Variable<String>(content);
    map['page_start'] = Variable<int>(pageStart);
    map['page_end'] = Variable<int>(pageEnd);
    map['level'] = Variable<int>(level);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  TechDocSectionTableCompanion toCompanion(bool nullToAbsent) {
    return TechDocSectionTableCompanion(
      id: Value(id),
      docId: Value(docId),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      title: Value(title),
      content: Value(content),
      pageStart: Value(pageStart),
      pageEnd: Value(pageEnd),
      level: Value(level),
      sortOrder: Value(sortOrder),
    );
  }

  factory TechDocSectionTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TechDocSectionTableData(
      id: serializer.fromJson<int>(json['id']),
      docId: serializer.fromJson<int>(json['docId']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      title: serializer.fromJson<String>(json['title']),
      content: serializer.fromJson<String>(json['content']),
      pageStart: serializer.fromJson<int>(json['pageStart']),
      pageEnd: serializer.fromJson<int>(json['pageEnd']),
      level: serializer.fromJson<int>(json['level']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'docId': serializer.toJson<int>(docId),
      'parentId': serializer.toJson<int?>(parentId),
      'title': serializer.toJson<String>(title),
      'content': serializer.toJson<String>(content),
      'pageStart': serializer.toJson<int>(pageStart),
      'pageEnd': serializer.toJson<int>(pageEnd),
      'level': serializer.toJson<int>(level),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  TechDocSectionTableData copyWith(
          {int? id,
          int? docId,
          Value<int?> parentId = const Value.absent(),
          String? title,
          String? content,
          int? pageStart,
          int? pageEnd,
          int? level,
          int? sortOrder}) =>
      TechDocSectionTableData(
        id: id ?? this.id,
        docId: docId ?? this.docId,
        parentId: parentId.present ? parentId.value : this.parentId,
        title: title ?? this.title,
        content: content ?? this.content,
        pageStart: pageStart ?? this.pageStart,
        pageEnd: pageEnd ?? this.pageEnd,
        level: level ?? this.level,
        sortOrder: sortOrder ?? this.sortOrder,
      );
  TechDocSectionTableData copyWithCompanion(TechDocSectionTableCompanion data) {
    return TechDocSectionTableData(
      id: data.id.present ? data.id.value : this.id,
      docId: data.docId.present ? data.docId.value : this.docId,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      title: data.title.present ? data.title.value : this.title,
      content: data.content.present ? data.content.value : this.content,
      pageStart: data.pageStart.present ? data.pageStart.value : this.pageStart,
      pageEnd: data.pageEnd.present ? data.pageEnd.value : this.pageEnd,
      level: data.level.present ? data.level.value : this.level,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TechDocSectionTableData(')
          ..write('id: $id, ')
          ..write('docId: $docId, ')
          ..write('parentId: $parentId, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('pageStart: $pageStart, ')
          ..write('pageEnd: $pageEnd, ')
          ..write('level: $level, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, docId, parentId, title, content,
      pageStart, pageEnd, level, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TechDocSectionTableData &&
          other.id == this.id &&
          other.docId == this.docId &&
          other.parentId == this.parentId &&
          other.title == this.title &&
          other.content == this.content &&
          other.pageStart == this.pageStart &&
          other.pageEnd == this.pageEnd &&
          other.level == this.level &&
          other.sortOrder == this.sortOrder);
}

class TechDocSectionTableCompanion
    extends UpdateCompanion<TechDocSectionTableData> {
  final Value<int> id;
  final Value<int> docId;
  final Value<int?> parentId;
  final Value<String> title;
  final Value<String> content;
  final Value<int> pageStart;
  final Value<int> pageEnd;
  final Value<int> level;
  final Value<int> sortOrder;
  const TechDocSectionTableCompanion({
    this.id = const Value.absent(),
    this.docId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.title = const Value.absent(),
    this.content = const Value.absent(),
    this.pageStart = const Value.absent(),
    this.pageEnd = const Value.absent(),
    this.level = const Value.absent(),
    this.sortOrder = const Value.absent(),
  });
  TechDocSectionTableCompanion.insert({
    this.id = const Value.absent(),
    required int docId,
    this.parentId = const Value.absent(),
    required String title,
    required String content,
    required int pageStart,
    required int pageEnd,
    required int level,
    required int sortOrder,
  })  : docId = Value(docId),
        title = Value(title),
        content = Value(content),
        pageStart = Value(pageStart),
        pageEnd = Value(pageEnd),
        level = Value(level),
        sortOrder = Value(sortOrder);
  static Insertable<TechDocSectionTableData> custom({
    Expression<int>? id,
    Expression<int>? docId,
    Expression<int>? parentId,
    Expression<String>? title,
    Expression<String>? content,
    Expression<int>? pageStart,
    Expression<int>? pageEnd,
    Expression<int>? level,
    Expression<int>? sortOrder,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (docId != null) 'doc_id': docId,
      if (parentId != null) 'parent_id': parentId,
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (pageStart != null) 'page_start': pageStart,
      if (pageEnd != null) 'page_end': pageEnd,
      if (level != null) 'level': level,
      if (sortOrder != null) 'sort_order': sortOrder,
    });
  }

  TechDocSectionTableCompanion copyWith(
      {Value<int>? id,
      Value<int>? docId,
      Value<int?>? parentId,
      Value<String>? title,
      Value<String>? content,
      Value<int>? pageStart,
      Value<int>? pageEnd,
      Value<int>? level,
      Value<int>? sortOrder}) {
    return TechDocSectionTableCompanion(
      id: id ?? this.id,
      docId: docId ?? this.docId,
      parentId: parentId ?? this.parentId,
      title: title ?? this.title,
      content: content ?? this.content,
      pageStart: pageStart ?? this.pageStart,
      pageEnd: pageEnd ?? this.pageEnd,
      level: level ?? this.level,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (docId.present) {
      map['doc_id'] = Variable<int>(docId.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (pageStart.present) {
      map['page_start'] = Variable<int>(pageStart.value);
    }
    if (pageEnd.present) {
      map['page_end'] = Variable<int>(pageEnd.value);
    }
    if (level.present) {
      map['level'] = Variable<int>(level.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TechDocSectionTableCompanion(')
          ..write('id: $id, ')
          ..write('docId: $docId, ')
          ..write('parentId: $parentId, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('pageStart: $pageStart, ')
          ..write('pageEnd: $pageEnd, ')
          ..write('level: $level, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }
}

class $McpProposalTableTable extends McpProposalTable
    with TableInfo<$McpProposalTableTable, McpProposalTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $McpProposalTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _proposalTypeMeta =
      const VerificationMeta('proposalType');
  @override
  late final GeneratedColumn<String> proposalType = GeneratedColumn<String>(
      'proposal_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _proposalJsonMeta =
      const VerificationMeta('proposalJson');
  @override
  late final GeneratedColumn<String> proposalJson = GeneratedColumn<String>(
      'proposal_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _operatorIdMeta =
      const VerificationMeta('operatorId');
  @override
  late final GeneratedColumn<String> operatorId = GeneratedColumn<String>(
      'operator_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      clientDefault: () => DateTime.now());
  @override
  List<GeneratedColumn> get $columns =>
      [id, proposalType, title, proposalJson, operatorId, status, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mcp_proposal';
  @override
  VerificationContext validateIntegrity(
      Insertable<McpProposalTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('proposal_type')) {
      context.handle(
          _proposalTypeMeta,
          proposalType.isAcceptableOrUnknown(
              data['proposal_type']!, _proposalTypeMeta));
    } else if (isInserting) {
      context.missing(_proposalTypeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('proposal_json')) {
      context.handle(
          _proposalJsonMeta,
          proposalJson.isAcceptableOrUnknown(
              data['proposal_json']!, _proposalJsonMeta));
    } else if (isInserting) {
      context.missing(_proposalJsonMeta);
    }
    if (data.containsKey('operator_id')) {
      context.handle(
          _operatorIdMeta,
          operatorId.isAcceptableOrUnknown(
              data['operator_id']!, _operatorIdMeta));
    } else if (isInserting) {
      context.missing(_operatorIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  McpProposalTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return McpProposalTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      proposalType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}proposal_type'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      proposalJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}proposal_json'])!,
      operatorId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}operator_id'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $McpProposalTableTable createAlias(String alias) {
    return $McpProposalTableTable(attachedDatabase, alias);
  }
}

class McpProposalTableData extends DataClass
    implements Insertable<McpProposalTableData> {
  final int id;

  /// Proposal type: alarm, page, asset, key_mapping.
  final String proposalType;

  /// Human-readable title for the notification (e.g. "Pump Overcurrent").
  final String title;

  /// Full proposal JSON for routing to the editor.
  final String proposalJson;

  /// Operator who triggered the proposal.
  final String operatorId;

  /// pending → notified → viewed → accepted / rejected / dismissed.
  final String status;
  final DateTime createdAt;
  const McpProposalTableData(
      {required this.id,
      required this.proposalType,
      required this.title,
      required this.proposalJson,
      required this.operatorId,
      required this.status,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['proposal_type'] = Variable<String>(proposalType);
    map['title'] = Variable<String>(title);
    map['proposal_json'] = Variable<String>(proposalJson);
    map['operator_id'] = Variable<String>(operatorId);
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  McpProposalTableCompanion toCompanion(bool nullToAbsent) {
    return McpProposalTableCompanion(
      id: Value(id),
      proposalType: Value(proposalType),
      title: Value(title),
      proposalJson: Value(proposalJson),
      operatorId: Value(operatorId),
      status: Value(status),
      createdAt: Value(createdAt),
    );
  }

  factory McpProposalTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return McpProposalTableData(
      id: serializer.fromJson<int>(json['id']),
      proposalType: serializer.fromJson<String>(json['proposalType']),
      title: serializer.fromJson<String>(json['title']),
      proposalJson: serializer.fromJson<String>(json['proposalJson']),
      operatorId: serializer.fromJson<String>(json['operatorId']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'proposalType': serializer.toJson<String>(proposalType),
      'title': serializer.toJson<String>(title),
      'proposalJson': serializer.toJson<String>(proposalJson),
      'operatorId': serializer.toJson<String>(operatorId),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  McpProposalTableData copyWith(
          {int? id,
          String? proposalType,
          String? title,
          String? proposalJson,
          String? operatorId,
          String? status,
          DateTime? createdAt}) =>
      McpProposalTableData(
        id: id ?? this.id,
        proposalType: proposalType ?? this.proposalType,
        title: title ?? this.title,
        proposalJson: proposalJson ?? this.proposalJson,
        operatorId: operatorId ?? this.operatorId,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );
  McpProposalTableData copyWithCompanion(McpProposalTableCompanion data) {
    return McpProposalTableData(
      id: data.id.present ? data.id.value : this.id,
      proposalType: data.proposalType.present
          ? data.proposalType.value
          : this.proposalType,
      title: data.title.present ? data.title.value : this.title,
      proposalJson: data.proposalJson.present
          ? data.proposalJson.value
          : this.proposalJson,
      operatorId:
          data.operatorId.present ? data.operatorId.value : this.operatorId,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('McpProposalTableData(')
          ..write('id: $id, ')
          ..write('proposalType: $proposalType, ')
          ..write('title: $title, ')
          ..write('proposalJson: $proposalJson, ')
          ..write('operatorId: $operatorId, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, proposalType, title, proposalJson, operatorId, status, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is McpProposalTableData &&
          other.id == this.id &&
          other.proposalType == this.proposalType &&
          other.title == this.title &&
          other.proposalJson == this.proposalJson &&
          other.operatorId == this.operatorId &&
          other.status == this.status &&
          other.createdAt == this.createdAt);
}

class McpProposalTableCompanion extends UpdateCompanion<McpProposalTableData> {
  final Value<int> id;
  final Value<String> proposalType;
  final Value<String> title;
  final Value<String> proposalJson;
  final Value<String> operatorId;
  final Value<String> status;
  final Value<DateTime> createdAt;
  const McpProposalTableCompanion({
    this.id = const Value.absent(),
    this.proposalType = const Value.absent(),
    this.title = const Value.absent(),
    this.proposalJson = const Value.absent(),
    this.operatorId = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  McpProposalTableCompanion.insert({
    this.id = const Value.absent(),
    required String proposalType,
    required String title,
    required String proposalJson,
    required String operatorId,
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
  })  : proposalType = Value(proposalType),
        title = Value(title),
        proposalJson = Value(proposalJson),
        operatorId = Value(operatorId);
  static Insertable<McpProposalTableData> custom({
    Expression<int>? id,
    Expression<String>? proposalType,
    Expression<String>? title,
    Expression<String>? proposalJson,
    Expression<String>? operatorId,
    Expression<String>? status,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (proposalType != null) 'proposal_type': proposalType,
      if (title != null) 'title': title,
      if (proposalJson != null) 'proposal_json': proposalJson,
      if (operatorId != null) 'operator_id': operatorId,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  McpProposalTableCompanion copyWith(
      {Value<int>? id,
      Value<String>? proposalType,
      Value<String>? title,
      Value<String>? proposalJson,
      Value<String>? operatorId,
      Value<String>? status,
      Value<DateTime>? createdAt}) {
    return McpProposalTableCompanion(
      id: id ?? this.id,
      proposalType: proposalType ?? this.proposalType,
      title: title ?? this.title,
      proposalJson: proposalJson ?? this.proposalJson,
      operatorId: operatorId ?? this.operatorId,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (proposalType.present) {
      map['proposal_type'] = Variable<String>(proposalType.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (proposalJson.present) {
      map['proposal_json'] = Variable<String>(proposalJson.value);
    }
    if (operatorId.present) {
      map['operator_id'] = Variable<String>(operatorId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('McpProposalTableCompanion(')
          ..write('id: $id, ')
          ..write('proposalType: $proposalType, ')
          ..write('title: $title, ')
          ..write('proposalJson: $proposalJson, ')
          ..write('operatorId: $operatorId, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $PlcVarRefTableTable extends PlcVarRefTable
    with TableInfo<$PlcVarRefTableTable, PlcVarRefTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlcVarRefTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _blockIdMeta =
      const VerificationMeta('blockId');
  @override
  late final GeneratedColumn<int> blockId = GeneratedColumn<int>(
      'block_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES plc_code_block (id)'));
  static const VerificationMeta _variablePathMeta =
      const VerificationMeta('variablePath');
  @override
  late final GeneratedColumn<String> variablePath = GeneratedColumn<String>(
      'variable_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _lineNumberMeta =
      const VerificationMeta('lineNumber');
  @override
  late final GeneratedColumn<int> lineNumber = GeneratedColumn<int>(
      'line_number', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _sourceLineMeta =
      const VerificationMeta('sourceLine');
  @override
  late final GeneratedColumn<String> sourceLine = GeneratedColumn<String>(
      'source_line', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, blockId, variablePath, kind, lineNumber, sourceLine];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plc_var_ref';
  @override
  VerificationContext validateIntegrity(Insertable<PlcVarRefTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('block_id')) {
      context.handle(_blockIdMeta,
          blockId.isAcceptableOrUnknown(data['block_id']!, _blockIdMeta));
    } else if (isInserting) {
      context.missing(_blockIdMeta);
    }
    if (data.containsKey('variable_path')) {
      context.handle(
          _variablePathMeta,
          variablePath.isAcceptableOrUnknown(
              data['variable_path']!, _variablePathMeta));
    } else if (isInserting) {
      context.missing(_variablePathMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('line_number')) {
      context.handle(
          _lineNumberMeta,
          lineNumber.isAcceptableOrUnknown(
              data['line_number']!, _lineNumberMeta));
    }
    if (data.containsKey('source_line')) {
      context.handle(
          _sourceLineMeta,
          sourceLine.isAcceptableOrUnknown(
              data['source_line']!, _sourceLineMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlcVarRefTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlcVarRefTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      blockId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}block_id'])!,
      variablePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}variable_path'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      lineNumber: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}line_number']),
      sourceLine: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_line']),
    );
  }

  @override
  $PlcVarRefTableTable createAlias(String alias) {
    return $PlcVarRefTableTable(attachedDatabase, alias);
  }
}

class PlcVarRefTableData extends DataClass
    implements Insertable<PlcVarRefTableData> {
  final int id;
  final int blockId;
  final String variablePath;
  final String kind;
  final int? lineNumber;
  final String? sourceLine;
  const PlcVarRefTableData(
      {required this.id,
      required this.blockId,
      required this.variablePath,
      required this.kind,
      this.lineNumber,
      this.sourceLine});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['block_id'] = Variable<int>(blockId);
    map['variable_path'] = Variable<String>(variablePath);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || lineNumber != null) {
      map['line_number'] = Variable<int>(lineNumber);
    }
    if (!nullToAbsent || sourceLine != null) {
      map['source_line'] = Variable<String>(sourceLine);
    }
    return map;
  }

  PlcVarRefTableCompanion toCompanion(bool nullToAbsent) {
    return PlcVarRefTableCompanion(
      id: Value(id),
      blockId: Value(blockId),
      variablePath: Value(variablePath),
      kind: Value(kind),
      lineNumber: lineNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(lineNumber),
      sourceLine: sourceLine == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceLine),
    );
  }

  factory PlcVarRefTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlcVarRefTableData(
      id: serializer.fromJson<int>(json['id']),
      blockId: serializer.fromJson<int>(json['blockId']),
      variablePath: serializer.fromJson<String>(json['variablePath']),
      kind: serializer.fromJson<String>(json['kind']),
      lineNumber: serializer.fromJson<int?>(json['lineNumber']),
      sourceLine: serializer.fromJson<String?>(json['sourceLine']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'blockId': serializer.toJson<int>(blockId),
      'variablePath': serializer.toJson<String>(variablePath),
      'kind': serializer.toJson<String>(kind),
      'lineNumber': serializer.toJson<int?>(lineNumber),
      'sourceLine': serializer.toJson<String?>(sourceLine),
    };
  }

  PlcVarRefTableData copyWith(
          {int? id,
          int? blockId,
          String? variablePath,
          String? kind,
          Value<int?> lineNumber = const Value.absent(),
          Value<String?> sourceLine = const Value.absent()}) =>
      PlcVarRefTableData(
        id: id ?? this.id,
        blockId: blockId ?? this.blockId,
        variablePath: variablePath ?? this.variablePath,
        kind: kind ?? this.kind,
        lineNumber: lineNumber.present ? lineNumber.value : this.lineNumber,
        sourceLine: sourceLine.present ? sourceLine.value : this.sourceLine,
      );
  PlcVarRefTableData copyWithCompanion(PlcVarRefTableCompanion data) {
    return PlcVarRefTableData(
      id: data.id.present ? data.id.value : this.id,
      blockId: data.blockId.present ? data.blockId.value : this.blockId,
      variablePath: data.variablePath.present
          ? data.variablePath.value
          : this.variablePath,
      kind: data.kind.present ? data.kind.value : this.kind,
      lineNumber:
          data.lineNumber.present ? data.lineNumber.value : this.lineNumber,
      sourceLine:
          data.sourceLine.present ? data.sourceLine.value : this.sourceLine,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlcVarRefTableData(')
          ..write('id: $id, ')
          ..write('blockId: $blockId, ')
          ..write('variablePath: $variablePath, ')
          ..write('kind: $kind, ')
          ..write('lineNumber: $lineNumber, ')
          ..write('sourceLine: $sourceLine')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, blockId, variablePath, kind, lineNumber, sourceLine);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlcVarRefTableData &&
          other.id == this.id &&
          other.blockId == this.blockId &&
          other.variablePath == this.variablePath &&
          other.kind == this.kind &&
          other.lineNumber == this.lineNumber &&
          other.sourceLine == this.sourceLine);
}

class PlcVarRefTableCompanion extends UpdateCompanion<PlcVarRefTableData> {
  final Value<int> id;
  final Value<int> blockId;
  final Value<String> variablePath;
  final Value<String> kind;
  final Value<int?> lineNumber;
  final Value<String?> sourceLine;
  const PlcVarRefTableCompanion({
    this.id = const Value.absent(),
    this.blockId = const Value.absent(),
    this.variablePath = const Value.absent(),
    this.kind = const Value.absent(),
    this.lineNumber = const Value.absent(),
    this.sourceLine = const Value.absent(),
  });
  PlcVarRefTableCompanion.insert({
    this.id = const Value.absent(),
    required int blockId,
    required String variablePath,
    required String kind,
    this.lineNumber = const Value.absent(),
    this.sourceLine = const Value.absent(),
  })  : blockId = Value(blockId),
        variablePath = Value(variablePath),
        kind = Value(kind);
  static Insertable<PlcVarRefTableData> custom({
    Expression<int>? id,
    Expression<int>? blockId,
    Expression<String>? variablePath,
    Expression<String>? kind,
    Expression<int>? lineNumber,
    Expression<String>? sourceLine,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (blockId != null) 'block_id': blockId,
      if (variablePath != null) 'variable_path': variablePath,
      if (kind != null) 'kind': kind,
      if (lineNumber != null) 'line_number': lineNumber,
      if (sourceLine != null) 'source_line': sourceLine,
    });
  }

  PlcVarRefTableCompanion copyWith(
      {Value<int>? id,
      Value<int>? blockId,
      Value<String>? variablePath,
      Value<String>? kind,
      Value<int?>? lineNumber,
      Value<String?>? sourceLine}) {
    return PlcVarRefTableCompanion(
      id: id ?? this.id,
      blockId: blockId ?? this.blockId,
      variablePath: variablePath ?? this.variablePath,
      kind: kind ?? this.kind,
      lineNumber: lineNumber ?? this.lineNumber,
      sourceLine: sourceLine ?? this.sourceLine,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (blockId.present) {
      map['block_id'] = Variable<int>(blockId.value);
    }
    if (variablePath.present) {
      map['variable_path'] = Variable<String>(variablePath.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (lineNumber.present) {
      map['line_number'] = Variable<int>(lineNumber.value);
    }
    if (sourceLine.present) {
      map['source_line'] = Variable<String>(sourceLine.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlcVarRefTableCompanion(')
          ..write('id: $id, ')
          ..write('blockId: $blockId, ')
          ..write('variablePath: $variablePath, ')
          ..write('kind: $kind, ')
          ..write('lineNumber: $lineNumber, ')
          ..write('sourceLine: $sourceLine')
          ..write(')'))
        .toString();
  }
}

class $PlcFbInstanceTableTable extends PlcFbInstanceTable
    with TableInfo<$PlcFbInstanceTableTable, PlcFbInstanceTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlcFbInstanceTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _declaringBlockIdMeta =
      const VerificationMeta('declaringBlockId');
  @override
  late final GeneratedColumn<int> declaringBlockId = GeneratedColumn<int>(
      'declaring_block_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES plc_code_block (id)'));
  static const VerificationMeta _instanceNameMeta =
      const VerificationMeta('instanceName');
  @override
  late final GeneratedColumn<String> instanceName = GeneratedColumn<String>(
      'instance_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fbTypeNameMeta =
      const VerificationMeta('fbTypeName');
  @override
  late final GeneratedColumn<String> fbTypeName = GeneratedColumn<String>(
      'fb_type_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, declaringBlockId, instanceName, fbTypeName];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plc_fb_instance';
  @override
  VerificationContext validateIntegrity(
      Insertable<PlcFbInstanceTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('declaring_block_id')) {
      context.handle(
          _declaringBlockIdMeta,
          declaringBlockId.isAcceptableOrUnknown(
              data['declaring_block_id']!, _declaringBlockIdMeta));
    } else if (isInserting) {
      context.missing(_declaringBlockIdMeta);
    }
    if (data.containsKey('instance_name')) {
      context.handle(
          _instanceNameMeta,
          instanceName.isAcceptableOrUnknown(
              data['instance_name']!, _instanceNameMeta));
    } else if (isInserting) {
      context.missing(_instanceNameMeta);
    }
    if (data.containsKey('fb_type_name')) {
      context.handle(
          _fbTypeNameMeta,
          fbTypeName.isAcceptableOrUnknown(
              data['fb_type_name']!, _fbTypeNameMeta));
    } else if (isInserting) {
      context.missing(_fbTypeNameMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlcFbInstanceTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlcFbInstanceTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      declaringBlockId: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}declaring_block_id'])!,
      instanceName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}instance_name'])!,
      fbTypeName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fb_type_name'])!,
    );
  }

  @override
  $PlcFbInstanceTableTable createAlias(String alias) {
    return $PlcFbInstanceTableTable(attachedDatabase, alias);
  }
}

class PlcFbInstanceTableData extends DataClass
    implements Insertable<PlcFbInstanceTableData> {
  final int id;
  final int declaringBlockId;
  final String instanceName;
  final String fbTypeName;
  const PlcFbInstanceTableData(
      {required this.id,
      required this.declaringBlockId,
      required this.instanceName,
      required this.fbTypeName});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['declaring_block_id'] = Variable<int>(declaringBlockId);
    map['instance_name'] = Variable<String>(instanceName);
    map['fb_type_name'] = Variable<String>(fbTypeName);
    return map;
  }

  PlcFbInstanceTableCompanion toCompanion(bool nullToAbsent) {
    return PlcFbInstanceTableCompanion(
      id: Value(id),
      declaringBlockId: Value(declaringBlockId),
      instanceName: Value(instanceName),
      fbTypeName: Value(fbTypeName),
    );
  }

  factory PlcFbInstanceTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlcFbInstanceTableData(
      id: serializer.fromJson<int>(json['id']),
      declaringBlockId: serializer.fromJson<int>(json['declaringBlockId']),
      instanceName: serializer.fromJson<String>(json['instanceName']),
      fbTypeName: serializer.fromJson<String>(json['fbTypeName']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'declaringBlockId': serializer.toJson<int>(declaringBlockId),
      'instanceName': serializer.toJson<String>(instanceName),
      'fbTypeName': serializer.toJson<String>(fbTypeName),
    };
  }

  PlcFbInstanceTableData copyWith(
          {int? id,
          int? declaringBlockId,
          String? instanceName,
          String? fbTypeName}) =>
      PlcFbInstanceTableData(
        id: id ?? this.id,
        declaringBlockId: declaringBlockId ?? this.declaringBlockId,
        instanceName: instanceName ?? this.instanceName,
        fbTypeName: fbTypeName ?? this.fbTypeName,
      );
  PlcFbInstanceTableData copyWithCompanion(PlcFbInstanceTableCompanion data) {
    return PlcFbInstanceTableData(
      id: data.id.present ? data.id.value : this.id,
      declaringBlockId: data.declaringBlockId.present
          ? data.declaringBlockId.value
          : this.declaringBlockId,
      instanceName: data.instanceName.present
          ? data.instanceName.value
          : this.instanceName,
      fbTypeName:
          data.fbTypeName.present ? data.fbTypeName.value : this.fbTypeName,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlcFbInstanceTableData(')
          ..write('id: $id, ')
          ..write('declaringBlockId: $declaringBlockId, ')
          ..write('instanceName: $instanceName, ')
          ..write('fbTypeName: $fbTypeName')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, declaringBlockId, instanceName, fbTypeName);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlcFbInstanceTableData &&
          other.id == this.id &&
          other.declaringBlockId == this.declaringBlockId &&
          other.instanceName == this.instanceName &&
          other.fbTypeName == this.fbTypeName);
}

class PlcFbInstanceTableCompanion
    extends UpdateCompanion<PlcFbInstanceTableData> {
  final Value<int> id;
  final Value<int> declaringBlockId;
  final Value<String> instanceName;
  final Value<String> fbTypeName;
  const PlcFbInstanceTableCompanion({
    this.id = const Value.absent(),
    this.declaringBlockId = const Value.absent(),
    this.instanceName = const Value.absent(),
    this.fbTypeName = const Value.absent(),
  });
  PlcFbInstanceTableCompanion.insert({
    this.id = const Value.absent(),
    required int declaringBlockId,
    required String instanceName,
    required String fbTypeName,
  })  : declaringBlockId = Value(declaringBlockId),
        instanceName = Value(instanceName),
        fbTypeName = Value(fbTypeName);
  static Insertable<PlcFbInstanceTableData> custom({
    Expression<int>? id,
    Expression<int>? declaringBlockId,
    Expression<String>? instanceName,
    Expression<String>? fbTypeName,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (declaringBlockId != null) 'declaring_block_id': declaringBlockId,
      if (instanceName != null) 'instance_name': instanceName,
      if (fbTypeName != null) 'fb_type_name': fbTypeName,
    });
  }

  PlcFbInstanceTableCompanion copyWith(
      {Value<int>? id,
      Value<int>? declaringBlockId,
      Value<String>? instanceName,
      Value<String>? fbTypeName}) {
    return PlcFbInstanceTableCompanion(
      id: id ?? this.id,
      declaringBlockId: declaringBlockId ?? this.declaringBlockId,
      instanceName: instanceName ?? this.instanceName,
      fbTypeName: fbTypeName ?? this.fbTypeName,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (declaringBlockId.present) {
      map['declaring_block_id'] = Variable<int>(declaringBlockId.value);
    }
    if (instanceName.present) {
      map['instance_name'] = Variable<String>(instanceName.value);
    }
    if (fbTypeName.present) {
      map['fb_type_name'] = Variable<String>(fbTypeName.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlcFbInstanceTableCompanion(')
          ..write('id: $id, ')
          ..write('declaringBlockId: $declaringBlockId, ')
          ..write('instanceName: $instanceName, ')
          ..write('fbTypeName: $fbTypeName')
          ..write(')'))
        .toString();
  }
}

class $PlcBlockCallTableTable extends PlcBlockCallTable
    with TableInfo<$PlcBlockCallTableTable, PlcBlockCallTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlcBlockCallTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _callerBlockIdMeta =
      const VerificationMeta('callerBlockId');
  @override
  late final GeneratedColumn<int> callerBlockId = GeneratedColumn<int>(
      'caller_block_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES plc_code_block (id)'));
  static const VerificationMeta _calleeBlockNameMeta =
      const VerificationMeta('calleeBlockName');
  @override
  late final GeneratedColumn<String> calleeBlockName = GeneratedColumn<String>(
      'callee_block_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _lineNumberMeta =
      const VerificationMeta('lineNumber');
  @override
  late final GeneratedColumn<int> lineNumber = GeneratedColumn<int>(
      'line_number', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, callerBlockId, calleeBlockName, lineNumber];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plc_block_call';
  @override
  VerificationContext validateIntegrity(
      Insertable<PlcBlockCallTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('caller_block_id')) {
      context.handle(
          _callerBlockIdMeta,
          callerBlockId.isAcceptableOrUnknown(
              data['caller_block_id']!, _callerBlockIdMeta));
    } else if (isInserting) {
      context.missing(_callerBlockIdMeta);
    }
    if (data.containsKey('callee_block_name')) {
      context.handle(
          _calleeBlockNameMeta,
          calleeBlockName.isAcceptableOrUnknown(
              data['callee_block_name']!, _calleeBlockNameMeta));
    } else if (isInserting) {
      context.missing(_calleeBlockNameMeta);
    }
    if (data.containsKey('line_number')) {
      context.handle(
          _lineNumberMeta,
          lineNumber.isAcceptableOrUnknown(
              data['line_number']!, _lineNumberMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlcBlockCallTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlcBlockCallTableData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      callerBlockId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}caller_block_id'])!,
      calleeBlockName: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}callee_block_name'])!,
      lineNumber: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}line_number']),
    );
  }

  @override
  $PlcBlockCallTableTable createAlias(String alias) {
    return $PlcBlockCallTableTable(attachedDatabase, alias);
  }
}

class PlcBlockCallTableData extends DataClass
    implements Insertable<PlcBlockCallTableData> {
  final int id;
  final int callerBlockId;
  final String calleeBlockName;
  final int? lineNumber;
  const PlcBlockCallTableData(
      {required this.id,
      required this.callerBlockId,
      required this.calleeBlockName,
      this.lineNumber});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['caller_block_id'] = Variable<int>(callerBlockId);
    map['callee_block_name'] = Variable<String>(calleeBlockName);
    if (!nullToAbsent || lineNumber != null) {
      map['line_number'] = Variable<int>(lineNumber);
    }
    return map;
  }

  PlcBlockCallTableCompanion toCompanion(bool nullToAbsent) {
    return PlcBlockCallTableCompanion(
      id: Value(id),
      callerBlockId: Value(callerBlockId),
      calleeBlockName: Value(calleeBlockName),
      lineNumber: lineNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(lineNumber),
    );
  }

  factory PlcBlockCallTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlcBlockCallTableData(
      id: serializer.fromJson<int>(json['id']),
      callerBlockId: serializer.fromJson<int>(json['callerBlockId']),
      calleeBlockName: serializer.fromJson<String>(json['calleeBlockName']),
      lineNumber: serializer.fromJson<int?>(json['lineNumber']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'callerBlockId': serializer.toJson<int>(callerBlockId),
      'calleeBlockName': serializer.toJson<String>(calleeBlockName),
      'lineNumber': serializer.toJson<int?>(lineNumber),
    };
  }

  PlcBlockCallTableData copyWith(
          {int? id,
          int? callerBlockId,
          String? calleeBlockName,
          Value<int?> lineNumber = const Value.absent()}) =>
      PlcBlockCallTableData(
        id: id ?? this.id,
        callerBlockId: callerBlockId ?? this.callerBlockId,
        calleeBlockName: calleeBlockName ?? this.calleeBlockName,
        lineNumber: lineNumber.present ? lineNumber.value : this.lineNumber,
      );
  PlcBlockCallTableData copyWithCompanion(PlcBlockCallTableCompanion data) {
    return PlcBlockCallTableData(
      id: data.id.present ? data.id.value : this.id,
      callerBlockId: data.callerBlockId.present
          ? data.callerBlockId.value
          : this.callerBlockId,
      calleeBlockName: data.calleeBlockName.present
          ? data.calleeBlockName.value
          : this.calleeBlockName,
      lineNumber:
          data.lineNumber.present ? data.lineNumber.value : this.lineNumber,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlcBlockCallTableData(')
          ..write('id: $id, ')
          ..write('callerBlockId: $callerBlockId, ')
          ..write('calleeBlockName: $calleeBlockName, ')
          ..write('lineNumber: $lineNumber')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, callerBlockId, calleeBlockName, lineNumber);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlcBlockCallTableData &&
          other.id == this.id &&
          other.callerBlockId == this.callerBlockId &&
          other.calleeBlockName == this.calleeBlockName &&
          other.lineNumber == this.lineNumber);
}

class PlcBlockCallTableCompanion
    extends UpdateCompanion<PlcBlockCallTableData> {
  final Value<int> id;
  final Value<int> callerBlockId;
  final Value<String> calleeBlockName;
  final Value<int?> lineNumber;
  const PlcBlockCallTableCompanion({
    this.id = const Value.absent(),
    this.callerBlockId = const Value.absent(),
    this.calleeBlockName = const Value.absent(),
    this.lineNumber = const Value.absent(),
  });
  PlcBlockCallTableCompanion.insert({
    this.id = const Value.absent(),
    required int callerBlockId,
    required String calleeBlockName,
    this.lineNumber = const Value.absent(),
  })  : callerBlockId = Value(callerBlockId),
        calleeBlockName = Value(calleeBlockName);
  static Insertable<PlcBlockCallTableData> custom({
    Expression<int>? id,
    Expression<int>? callerBlockId,
    Expression<String>? calleeBlockName,
    Expression<int>? lineNumber,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (callerBlockId != null) 'caller_block_id': callerBlockId,
      if (calleeBlockName != null) 'callee_block_name': calleeBlockName,
      if (lineNumber != null) 'line_number': lineNumber,
    });
  }

  PlcBlockCallTableCompanion copyWith(
      {Value<int>? id,
      Value<int>? callerBlockId,
      Value<String>? calleeBlockName,
      Value<int?>? lineNumber}) {
    return PlcBlockCallTableCompanion(
      id: id ?? this.id,
      callerBlockId: callerBlockId ?? this.callerBlockId,
      calleeBlockName: calleeBlockName ?? this.calleeBlockName,
      lineNumber: lineNumber ?? this.lineNumber,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (callerBlockId.present) {
      map['caller_block_id'] = Variable<int>(callerBlockId.value);
    }
    if (calleeBlockName.present) {
      map['callee_block_name'] = Variable<String>(calleeBlockName.value);
    }
    if (lineNumber.present) {
      map['line_number'] = Variable<int>(lineNumber.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlcBlockCallTableCompanion(')
          ..write('id: $id, ')
          ..write('callerBlockId: $callerBlockId, ')
          ..write('calleeBlockName: $calleeBlockName, ')
          ..write('lineNumber: $lineNumber')
          ..write(')'))
        .toString();
  }
}

class $AppRoleTable extends AppRole with TableInfo<$AppRoleTable, AppRoleData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppRoleTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _groupsMeta = const VerificationMeta('groups');
  @override
  late final GeneratedColumn<String> groups = GeneratedColumn<String>(
      'groups', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _seededMeta = const VerificationMeta('seeded');
  @override
  late final GeneratedColumn<bool> seeded = GeneratedColumn<bool>(
      'seeded', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultValue: const Constant(false));
  static const VerificationMeta _allowedPagesMeta =
      const VerificationMeta('allowedPages');
  @override
  late final GeneratedColumn<String> allowedPages = GeneratedColumn<String>(
      'allowed_pages', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [name, groups, seeded, allowedPages];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_role';
  @override
  VerificationContext validateIntegrity(Insertable<AppRoleData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('groups')) {
      context.handle(_groupsMeta,
          groups.isAcceptableOrUnknown(data['groups']!, _groupsMeta));
    } else if (isInserting) {
      context.missing(_groupsMeta);
    }
    if (data.containsKey('seeded')) {
      context.handle(_seededMeta,
          seeded.isAcceptableOrUnknown(data['seeded']!, _seededMeta));
    }
    if (data.containsKey('allowed_pages')) {
      context.handle(
          _allowedPagesMeta,
          allowedPages.isAcceptableOrUnknown(
              data['allowed_pages']!, _allowedPagesMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  AppRoleData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppRoleData(
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      groups: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}groups'])!,
      seeded: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}seeded'])!,
      allowedPages: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}allowed_pages']),
    );
  }

  @override
  $AppRoleTable createAlias(String alias) {
    return $AppRoleTable(attachedDatabase, alias);
  }
}

class AppRoleData extends DataClass implements Insertable<AppRoleData> {
  final String name;

  /// JSON array of `AccessGroup` enum names, written by
  /// `AccessRole.encodeGroups()` and read back by `AccessRole.decodeGroups()`.
  ///
  /// Keep it small: the backend config watcher fires on preference writes and
  /// `pg_notify` has an 8000-byte cap, which errors the firing statement
  /// rather than truncating it.
  final String groups;

  /// True for the rows the v6 migration seeded. Informational only.
  final bool seeded;

  /// The page-visibility whitelist (schema v7): a JSON array of page paths,
  /// or SQL NULL for "this role sees every page".
  ///
  /// Written by `encodeAllowedPagesColumn` and read by
  /// `decodeAllowedPagesColumn`. **NULL and `'[]'` are different claims** —
  /// NULL is no whitelist, `'[]'` is a whitelist naming nothing, i.e. block
  /// all — so this column is nullable rather than defaulting to an empty
  /// array. Every row carried over from v6 gets NULL and therefore behaves
  /// exactly as it did before the column existed.
  ///
  /// Authorization data, which is why it lives here rather than beside the
  /// pages in `page_editor_data`: that preference is classified `configure`,
  /// and anybody who can edit a page must not be able to re-scope who sees
  /// which pages. See `docs/page-visibility-whitelist-design.md` §1a.
  ///
  /// Keep it small, for the same reason [groups] says so: the backend config
  /// watcher fires on preference writes and `pg_notify` has an 8000-byte cap.
  final String? allowedPages;
  const AppRoleData(
      {required this.name,
      required this.groups,
      required this.seeded,
      this.allowedPages});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['groups'] = Variable<String>(groups);
    map['seeded'] = Variable<bool>(seeded);
    if (!nullToAbsent || allowedPages != null) {
      map['allowed_pages'] = Variable<String>(allowedPages);
    }
    return map;
  }

  AppRoleCompanion toCompanion(bool nullToAbsent) {
    return AppRoleCompanion(
      name: Value(name),
      groups: Value(groups),
      seeded: Value(seeded),
      allowedPages: allowedPages == null && nullToAbsent
          ? const Value.absent()
          : Value(allowedPages),
    );
  }

  factory AppRoleData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppRoleData(
      name: serializer.fromJson<String>(json['name']),
      groups: serializer.fromJson<String>(json['groups']),
      seeded: serializer.fromJson<bool>(json['seeded']),
      allowedPages: serializer.fromJson<String?>(json['allowedPages']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'groups': serializer.toJson<String>(groups),
      'seeded': serializer.toJson<bool>(seeded),
      'allowedPages': serializer.toJson<String?>(allowedPages),
    };
  }

  AppRoleData copyWith(
          {String? name,
          String? groups,
          bool? seeded,
          Value<String?> allowedPages = const Value.absent()}) =>
      AppRoleData(
        name: name ?? this.name,
        groups: groups ?? this.groups,
        seeded: seeded ?? this.seeded,
        allowedPages:
            allowedPages.present ? allowedPages.value : this.allowedPages,
      );
  AppRoleData copyWithCompanion(AppRoleCompanion data) {
    return AppRoleData(
      name: data.name.present ? data.name.value : this.name,
      groups: data.groups.present ? data.groups.value : this.groups,
      seeded: data.seeded.present ? data.seeded.value : this.seeded,
      allowedPages: data.allowedPages.present
          ? data.allowedPages.value
          : this.allowedPages,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppRoleData(')
          ..write('name: $name, ')
          ..write('groups: $groups, ')
          ..write('seeded: $seeded, ')
          ..write('allowedPages: $allowedPages')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, groups, seeded, allowedPages);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppRoleData &&
          other.name == this.name &&
          other.groups == this.groups &&
          other.seeded == this.seeded &&
          other.allowedPages == this.allowedPages);
}

class AppRoleCompanion extends UpdateCompanion<AppRoleData> {
  final Value<String> name;
  final Value<String> groups;
  final Value<bool> seeded;
  final Value<String?> allowedPages;
  final Value<int> rowid;
  const AppRoleCompanion({
    this.name = const Value.absent(),
    this.groups = const Value.absent(),
    this.seeded = const Value.absent(),
    this.allowedPages = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppRoleCompanion.insert({
    required String name,
    required String groups,
    this.seeded = const Value.absent(),
    this.allowedPages = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : name = Value(name),
        groups = Value(groups);
  static Insertable<AppRoleData> custom({
    Expression<String>? name,
    Expression<String>? groups,
    Expression<bool>? seeded,
    Expression<String>? allowedPages,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (groups != null) 'groups': groups,
      if (seeded != null) 'seeded': seeded,
      if (allowedPages != null) 'allowed_pages': allowedPages,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppRoleCompanion copyWith(
      {Value<String>? name,
      Value<String>? groups,
      Value<bool>? seeded,
      Value<String?>? allowedPages,
      Value<int>? rowid}) {
    return AppRoleCompanion(
      name: name ?? this.name,
      groups: groups ?? this.groups,
      seeded: seeded ?? this.seeded,
      allowedPages: allowedPages ?? this.allowedPages,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (groups.present) {
      map['groups'] = Variable<String>(groups.value);
    }
    if (seeded.present) {
      map['seeded'] = Variable<bool>(seeded.value);
    }
    if (allowedPages.present) {
      map['allowed_pages'] = Variable<String>(allowedPages.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppRoleCompanion(')
          ..write('name: $name, ')
          ..write('groups: $groups, ')
          ..write('seeded: $seeded, ')
          ..write('allowedPages: $allowedPages, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppUserTable extends AppUser with TableInfo<$AppUserTable, AppUserData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppUserTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _usernameMeta =
      const VerificationMeta('username');
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
      'username', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _roleNameMeta =
      const VerificationMeta('roleName');
  @override
  late final GeneratedColumn<String> roleName = GeneratedColumn<String>(
      'role_name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES app_role (name)'));
  static const VerificationMeta _additionalRolesMeta =
      const VerificationMeta('additionalRoles');
  @override
  late final GeneratedColumn<String> additionalRoles = GeneratedColumn<String>(
      'additional_roles', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _passwordHashMeta =
      const VerificationMeta('passwordHash');
  @override
  late final GeneratedColumn<String> passwordHash = GeneratedColumn<String>(
      'password_hash', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _saltMeta = const VerificationMeta('salt');
  @override
  late final GeneratedColumn<String> salt = GeneratedColumn<String>(
      'salt', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _lastLoginAtMeta =
      const VerificationMeta('lastLoginAt');
  @override
  late final GeneratedColumn<DateTime> lastLoginAt = GeneratedColumn<DateTime>(
      'last_login_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _stationAccountMeta =
      const VerificationMeta('stationAccount');
  @override
  late final GeneratedColumn<bool> stationAccount = GeneratedColumn<bool>(
      'station_account', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultValue: const Constant(false));
  static const VerificationMeta _allowedPagesMeta =
      const VerificationMeta('allowedPages');
  @override
  late final GeneratedColumn<String> allowedPages = GeneratedColumn<String>(
      'allowed_pages', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _inactivityTimeoutMinutesMeta =
      const VerificationMeta('inactivityTimeoutMinutes');
  @override
  late final GeneratedColumn<int> inactivityTimeoutMinutes =
      GeneratedColumn<int>('inactivity_timeout_minutes', aliasedName, true,
          type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        username,
        roleName,
        additionalRoles,
        passwordHash,
        salt,
        createdAt,
        lastLoginAt,
        stationAccount,
        allowedPages,
        inactivityTimeoutMinutes
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_user';
  @override
  VerificationContext validateIntegrity(Insertable<AppUserData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('username')) {
      context.handle(_usernameMeta,
          username.isAcceptableOrUnknown(data['username']!, _usernameMeta));
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('role_name')) {
      context.handle(_roleNameMeta,
          roleName.isAcceptableOrUnknown(data['role_name']!, _roleNameMeta));
    } else if (isInserting) {
      context.missing(_roleNameMeta);
    }
    if (data.containsKey('additional_roles')) {
      context.handle(
          _additionalRolesMeta,
          additionalRoles.isAcceptableOrUnknown(
              data['additional_roles']!, _additionalRolesMeta));
    }
    if (data.containsKey('password_hash')) {
      context.handle(
          _passwordHashMeta,
          passwordHash.isAcceptableOrUnknown(
              data['password_hash']!, _passwordHashMeta));
    } else if (isInserting) {
      context.missing(_passwordHashMeta);
    }
    if (data.containsKey('salt')) {
      context.handle(
          _saltMeta, salt.isAcceptableOrUnknown(data['salt']!, _saltMeta));
    } else if (isInserting) {
      context.missing(_saltMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_login_at')) {
      context.handle(
          _lastLoginAtMeta,
          lastLoginAt.isAcceptableOrUnknown(
              data['last_login_at']!, _lastLoginAtMeta));
    }
    if (data.containsKey('station_account')) {
      context.handle(
          _stationAccountMeta,
          stationAccount.isAcceptableOrUnknown(
              data['station_account']!, _stationAccountMeta));
    }
    if (data.containsKey('allowed_pages')) {
      context.handle(
          _allowedPagesMeta,
          allowedPages.isAcceptableOrUnknown(
              data['allowed_pages']!, _allowedPagesMeta));
    }
    if (data.containsKey('inactivity_timeout_minutes')) {
      context.handle(
          _inactivityTimeoutMinutesMeta,
          inactivityTimeoutMinutes.isAcceptableOrUnknown(
              data['inactivity_timeout_minutes']!,
              _inactivityTimeoutMinutesMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {username};
  @override
  AppUserData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppUserData(
      username: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}username'])!,
      roleName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role_name'])!,
      additionalRoles: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}additional_roles']),
      passwordHash: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}password_hash'])!,
      salt: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}salt'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      lastLoginAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}last_login_at']),
      stationAccount: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}station_account'])!,
      allowedPages: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}allowed_pages']),
      inactivityTimeoutMinutes: attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}inactivity_timeout_minutes']),
    );
  }

  @override
  $AppUserTable createAlias(String alias) {
    return $AppUserTable(attachedDatabase, alias);
  }
}

class AppUserData extends DataClass implements Insertable<AppUserData> {
  final String username;

  /// This account's **primary** role, matched to [AppRole.name] by name, never
  /// by id — see [AppRole].
  ///
  /// The one with the foreign key on it, and the whole answer for any account
  /// that holds exactly one role, which is every account carried over from v8.
  /// It is identity rather than precedence: what the account may do is the
  /// union of this and [additionalRoles].
  final String roleName;

  /// The roles this account holds **beyond** [roleName] (schema v9): a JSON
  /// array of `app_role.name` values, or SQL NULL when it holds only its
  /// primary role.
  ///
  /// Written by `encodeAdditionalRoles` and read by `decodeAdditionalRoles`.
  /// NULL and an empty array mean the same thing here — unlike
  /// [allowedPages], where the distinction is the feature — so the codec
  /// writes NULL for both and every account carried over from v8 lands on NULL
  /// and behaves exactly as it did.
  ///
  /// **No foreign key, and it could not have one:** a JSON array cannot
  /// reference a column. That is handled where it matters instead —
  /// `AccessRepository.deleteRole` refuses a role anybody holds *either* way
  /// and `renameRole` rewrites both — and a name in here that matches no role
  /// row simply grants nothing, which is the fail-closed direction.
  ///
  /// Keep it small, for the reason [AppRole.groups] gives: the backend config
  /// watcher fires on preference writes and `pg_notify` has an 8000-byte cap.
  final String? additionalRoles;

  /// Argon2id over the password with [salt], stored self-describing: the value
  /// carries its own algorithm tag and cost parameters.
  ///
  /// This column and [salt] are the **only** place a credential is stored.
  /// Never in `Preferences` or the `flutter_preferences` table: those are
  /// synced between stations and read by the backend config watcher.
  final String passwordHash;

  /// Per-user random salt, stored base64. See [passwordHash].
  final String salt;
  final DateTime createdAt;
  final DateTime? lastLoginAt;

  /// A station account's sessions never expire.
  ///
  /// The panel-PC flag — the freezer display signs in once as its area
  /// account and lives signed in. On the USER rather than the station so a
  /// human signing in on the same panel keeps the inactivity window. The
  /// default is false: every account is a person until somebody says
  /// otherwise, which is also what an account carried over from v5 gets.
  final bool stationAccount;

  /// This account's personal page whitelist (schema v7), or NULL to follow
  /// whatever [AppRole.allowedPages] says.
  ///
  /// Three states, and the null one is the subtle one: **NULL means inherit
  /// the role**, not "sees every page". Every account carried over from v6
  /// lands on NULL, and if that meant unrestricted then the upgrade would mint
  /// a personal exemption for every existing account — the first role
  /// whitelist anybody configured would govern nobody who already existed.
  /// `effectiveAllowedPages` is where that rule is written down.
  ///
  /// A non-null value **replaces** the role's whitelist rather than
  /// intersecting or unioning with it, so both directions of exception are
  /// expressible. It can widen what this account *sees*; it can never widen
  /// what this account may *do*, because the group gate is ANDed on top.
  final String? allowedPages;

  /// How many idle minutes end this account's sessions (schema v8), or NULL
  /// for the default.
  ///
  /// Per account rather than per station: the account knows who walked away
  /// with what power, the panel does not. **NULL means "no value of its own"**,
  /// never "never expires" — sessions that must not expire are
  /// [stationAccount]'s, and only that flag produces one. Every account
  /// carried over from v7 lands on NULL and keeps the fifteen minutes it had.
  ///
  /// The range is enforced by `AccessRepository.setInactivityTimeout` and a
  /// value outside it is clamped on read by `resolveInactivityTimeout`, so a
  /// `psql` edit cannot end sessions instantly or never.
  final int? inactivityTimeoutMinutes;
  const AppUserData(
      {required this.username,
      required this.roleName,
      this.additionalRoles,
      required this.passwordHash,
      required this.salt,
      required this.createdAt,
      this.lastLoginAt,
      required this.stationAccount,
      this.allowedPages,
      this.inactivityTimeoutMinutes});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['username'] = Variable<String>(username);
    map['role_name'] = Variable<String>(roleName);
    if (!nullToAbsent || additionalRoles != null) {
      map['additional_roles'] = Variable<String>(additionalRoles);
    }
    map['password_hash'] = Variable<String>(passwordHash);
    map['salt'] = Variable<String>(salt);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || lastLoginAt != null) {
      map['last_login_at'] = Variable<DateTime>(lastLoginAt);
    }
    map['station_account'] = Variable<bool>(stationAccount);
    if (!nullToAbsent || allowedPages != null) {
      map['allowed_pages'] = Variable<String>(allowedPages);
    }
    if (!nullToAbsent || inactivityTimeoutMinutes != null) {
      map['inactivity_timeout_minutes'] =
          Variable<int>(inactivityTimeoutMinutes);
    }
    return map;
  }

  AppUserCompanion toCompanion(bool nullToAbsent) {
    return AppUserCompanion(
      username: Value(username),
      roleName: Value(roleName),
      additionalRoles: additionalRoles == null && nullToAbsent
          ? const Value.absent()
          : Value(additionalRoles),
      passwordHash: Value(passwordHash),
      salt: Value(salt),
      createdAt: Value(createdAt),
      lastLoginAt: lastLoginAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastLoginAt),
      stationAccount: Value(stationAccount),
      allowedPages: allowedPages == null && nullToAbsent
          ? const Value.absent()
          : Value(allowedPages),
      inactivityTimeoutMinutes: inactivityTimeoutMinutes == null && nullToAbsent
          ? const Value.absent()
          : Value(inactivityTimeoutMinutes),
    );
  }

  factory AppUserData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppUserData(
      username: serializer.fromJson<String>(json['username']),
      roleName: serializer.fromJson<String>(json['roleName']),
      additionalRoles: serializer.fromJson<String?>(json['additionalRoles']),
      passwordHash: serializer.fromJson<String>(json['passwordHash']),
      salt: serializer.fromJson<String>(json['salt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      lastLoginAt: serializer.fromJson<DateTime?>(json['lastLoginAt']),
      stationAccount: serializer.fromJson<bool>(json['stationAccount']),
      allowedPages: serializer.fromJson<String?>(json['allowedPages']),
      inactivityTimeoutMinutes:
          serializer.fromJson<int?>(json['inactivityTimeoutMinutes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'username': serializer.toJson<String>(username),
      'roleName': serializer.toJson<String>(roleName),
      'additionalRoles': serializer.toJson<String?>(additionalRoles),
      'passwordHash': serializer.toJson<String>(passwordHash),
      'salt': serializer.toJson<String>(salt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'lastLoginAt': serializer.toJson<DateTime?>(lastLoginAt),
      'stationAccount': serializer.toJson<bool>(stationAccount),
      'allowedPages': serializer.toJson<String?>(allowedPages),
      'inactivityTimeoutMinutes':
          serializer.toJson<int?>(inactivityTimeoutMinutes),
    };
  }

  AppUserData copyWith(
          {String? username,
          String? roleName,
          Value<String?> additionalRoles = const Value.absent(),
          String? passwordHash,
          String? salt,
          DateTime? createdAt,
          Value<DateTime?> lastLoginAt = const Value.absent(),
          bool? stationAccount,
          Value<String?> allowedPages = const Value.absent(),
          Value<int?> inactivityTimeoutMinutes = const Value.absent()}) =>
      AppUserData(
        username: username ?? this.username,
        roleName: roleName ?? this.roleName,
        additionalRoles: additionalRoles.present
            ? additionalRoles.value
            : this.additionalRoles,
        passwordHash: passwordHash ?? this.passwordHash,
        salt: salt ?? this.salt,
        createdAt: createdAt ?? this.createdAt,
        lastLoginAt: lastLoginAt.present ? lastLoginAt.value : this.lastLoginAt,
        stationAccount: stationAccount ?? this.stationAccount,
        allowedPages:
            allowedPages.present ? allowedPages.value : this.allowedPages,
        inactivityTimeoutMinutes: inactivityTimeoutMinutes.present
            ? inactivityTimeoutMinutes.value
            : this.inactivityTimeoutMinutes,
      );
  AppUserData copyWithCompanion(AppUserCompanion data) {
    return AppUserData(
      username: data.username.present ? data.username.value : this.username,
      roleName: data.roleName.present ? data.roleName.value : this.roleName,
      additionalRoles: data.additionalRoles.present
          ? data.additionalRoles.value
          : this.additionalRoles,
      passwordHash: data.passwordHash.present
          ? data.passwordHash.value
          : this.passwordHash,
      salt: data.salt.present ? data.salt.value : this.salt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastLoginAt:
          data.lastLoginAt.present ? data.lastLoginAt.value : this.lastLoginAt,
      stationAccount: data.stationAccount.present
          ? data.stationAccount.value
          : this.stationAccount,
      allowedPages: data.allowedPages.present
          ? data.allowedPages.value
          : this.allowedPages,
      inactivityTimeoutMinutes: data.inactivityTimeoutMinutes.present
          ? data.inactivityTimeoutMinutes.value
          : this.inactivityTimeoutMinutes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppUserData(')
          ..write('username: $username, ')
          ..write('roleName: $roleName, ')
          ..write('additionalRoles: $additionalRoles, ')
          ..write('passwordHash: $passwordHash, ')
          ..write('salt: $salt, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastLoginAt: $lastLoginAt, ')
          ..write('stationAccount: $stationAccount, ')
          ..write('allowedPages: $allowedPages, ')
          ..write('inactivityTimeoutMinutes: $inactivityTimeoutMinutes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      username,
      roleName,
      additionalRoles,
      passwordHash,
      salt,
      createdAt,
      lastLoginAt,
      stationAccount,
      allowedPages,
      inactivityTimeoutMinutes);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppUserData &&
          other.username == this.username &&
          other.roleName == this.roleName &&
          other.additionalRoles == this.additionalRoles &&
          other.passwordHash == this.passwordHash &&
          other.salt == this.salt &&
          other.createdAt == this.createdAt &&
          other.lastLoginAt == this.lastLoginAt &&
          other.stationAccount == this.stationAccount &&
          other.allowedPages == this.allowedPages &&
          other.inactivityTimeoutMinutes == this.inactivityTimeoutMinutes);
}

class AppUserCompanion extends UpdateCompanion<AppUserData> {
  final Value<String> username;
  final Value<String> roleName;
  final Value<String?> additionalRoles;
  final Value<String> passwordHash;
  final Value<String> salt;
  final Value<DateTime> createdAt;
  final Value<DateTime?> lastLoginAt;
  final Value<bool> stationAccount;
  final Value<String?> allowedPages;
  final Value<int?> inactivityTimeoutMinutes;
  final Value<int> rowid;
  const AppUserCompanion({
    this.username = const Value.absent(),
    this.roleName = const Value.absent(),
    this.additionalRoles = const Value.absent(),
    this.passwordHash = const Value.absent(),
    this.salt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastLoginAt = const Value.absent(),
    this.stationAccount = const Value.absent(),
    this.allowedPages = const Value.absent(),
    this.inactivityTimeoutMinutes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppUserCompanion.insert({
    required String username,
    required String roleName,
    this.additionalRoles = const Value.absent(),
    required String passwordHash,
    required String salt,
    required DateTime createdAt,
    this.lastLoginAt = const Value.absent(),
    this.stationAccount = const Value.absent(),
    this.allowedPages = const Value.absent(),
    this.inactivityTimeoutMinutes = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : username = Value(username),
        roleName = Value(roleName),
        passwordHash = Value(passwordHash),
        salt = Value(salt),
        createdAt = Value(createdAt);
  static Insertable<AppUserData> custom({
    Expression<String>? username,
    Expression<String>? roleName,
    Expression<String>? additionalRoles,
    Expression<String>? passwordHash,
    Expression<String>? salt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? lastLoginAt,
    Expression<bool>? stationAccount,
    Expression<String>? allowedPages,
    Expression<int>? inactivityTimeoutMinutes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (username != null) 'username': username,
      if (roleName != null) 'role_name': roleName,
      if (additionalRoles != null) 'additional_roles': additionalRoles,
      if (passwordHash != null) 'password_hash': passwordHash,
      if (salt != null) 'salt': salt,
      if (createdAt != null) 'created_at': createdAt,
      if (lastLoginAt != null) 'last_login_at': lastLoginAt,
      if (stationAccount != null) 'station_account': stationAccount,
      if (allowedPages != null) 'allowed_pages': allowedPages,
      if (inactivityTimeoutMinutes != null)
        'inactivity_timeout_minutes': inactivityTimeoutMinutes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppUserCompanion copyWith(
      {Value<String>? username,
      Value<String>? roleName,
      Value<String?>? additionalRoles,
      Value<String>? passwordHash,
      Value<String>? salt,
      Value<DateTime>? createdAt,
      Value<DateTime?>? lastLoginAt,
      Value<bool>? stationAccount,
      Value<String?>? allowedPages,
      Value<int?>? inactivityTimeoutMinutes,
      Value<int>? rowid}) {
    return AppUserCompanion(
      username: username ?? this.username,
      roleName: roleName ?? this.roleName,
      additionalRoles: additionalRoles ?? this.additionalRoles,
      passwordHash: passwordHash ?? this.passwordHash,
      salt: salt ?? this.salt,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      stationAccount: stationAccount ?? this.stationAccount,
      allowedPages: allowedPages ?? this.allowedPages,
      inactivityTimeoutMinutes:
          inactivityTimeoutMinutes ?? this.inactivityTimeoutMinutes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (roleName.present) {
      map['role_name'] = Variable<String>(roleName.value);
    }
    if (additionalRoles.present) {
      map['additional_roles'] = Variable<String>(additionalRoles.value);
    }
    if (passwordHash.present) {
      map['password_hash'] = Variable<String>(passwordHash.value);
    }
    if (salt.present) {
      map['salt'] = Variable<String>(salt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastLoginAt.present) {
      map['last_login_at'] = Variable<DateTime>(lastLoginAt.value);
    }
    if (stationAccount.present) {
      map['station_account'] = Variable<bool>(stationAccount.value);
    }
    if (allowedPages.present) {
      map['allowed_pages'] = Variable<String>(allowedPages.value);
    }
    if (inactivityTimeoutMinutes.present) {
      map['inactivity_timeout_minutes'] =
          Variable<int>(inactivityTimeoutMinutes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppUserCompanion(')
          ..write('username: $username, ')
          ..write('roleName: $roleName, ')
          ..write('additionalRoles: $additionalRoles, ')
          ..write('passwordHash: $passwordHash, ')
          ..write('salt: $salt, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastLoginAt: $lastLoginAt, ')
          ..write('stationAccount: $stationAccount, ')
          ..write('allowedPages: $allowedPages, ')
          ..write('inactivityTimeoutMinutes: $inactivityTimeoutMinutes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AuditEntryTable extends AuditEntry
    with TableInfo<$AuditEntryTable, AuditEntryData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AuditEntryTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _surfaceMeta =
      const VerificationMeta('surface');
  @override
  late final GeneratedColumn<String> surface = GeneratedColumn<String>(
      'surface', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _itemKeyMeta =
      const VerificationMeta('itemKey');
  @override
  late final GeneratedColumn<String> itemKey = GeneratedColumn<String>(
      'item_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _memberMeta = const VerificationMeta('member');
  @override
  late final GeneratedColumn<String> member = GeneratedColumn<String>(
      'member', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
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
  static const VerificationMeta _groupRequiredMeta =
      const VerificationMeta('groupRequired');
  @override
  late final GeneratedColumn<String> groupRequired = GeneratedColumn<String>(
      'group_required', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _allowedMeta =
      const VerificationMeta('allowed');
  @override
  late final GeneratedColumn<bool> allowed = GeneratedColumn<bool>(
      'allowed', aliasedName, false,
      type: DriftSqlType.bool, requiredDuringInsert: true);
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
      'origin', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('operator'));
  static const VerificationMeta _actionIdMeta =
      const VerificationMeta('actionId');
  @override
  late final GeneratedColumn<String> actionId = GeneratedColumn<String>(
      'action_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
      'reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        at,
        who,
        station,
        roleName,
        surface,
        itemKey,
        member,
        oldValue,
        newValue,
        groupRequired,
        allowed,
        origin,
        actionId,
        reason
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'audit_entry';
  @override
  VerificationContext validateIntegrity(Insertable<AuditEntryData> instance,
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
    if (data.containsKey('surface')) {
      context.handle(_surfaceMeta,
          surface.isAcceptableOrUnknown(data['surface']!, _surfaceMeta));
    } else if (isInserting) {
      context.missing(_surfaceMeta);
    }
    if (data.containsKey('item_key')) {
      context.handle(_itemKeyMeta,
          itemKey.isAcceptableOrUnknown(data['item_key']!, _itemKeyMeta));
    } else if (isInserting) {
      context.missing(_itemKeyMeta);
    }
    if (data.containsKey('member')) {
      context.handle(_memberMeta,
          member.isAcceptableOrUnknown(data['member']!, _memberMeta));
    }
    if (data.containsKey('old_value')) {
      context.handle(_oldValueMeta,
          oldValue.isAcceptableOrUnknown(data['old_value']!, _oldValueMeta));
    }
    if (data.containsKey('new_value')) {
      context.handle(_newValueMeta,
          newValue.isAcceptableOrUnknown(data['new_value']!, _newValueMeta));
    }
    if (data.containsKey('group_required')) {
      context.handle(
          _groupRequiredMeta,
          groupRequired.isAcceptableOrUnknown(
              data['group_required']!, _groupRequiredMeta));
    } else if (isInserting) {
      context.missing(_groupRequiredMeta);
    }
    if (data.containsKey('allowed')) {
      context.handle(_allowedMeta,
          allowed.isAcceptableOrUnknown(data['allowed']!, _allowedMeta));
    } else if (isInserting) {
      context.missing(_allowedMeta);
    }
    if (data.containsKey('origin')) {
      context.handle(_originMeta,
          origin.isAcceptableOrUnknown(data['origin']!, _originMeta));
    }
    if (data.containsKey('action_id')) {
      context.handle(_actionIdMeta,
          actionId.isAcceptableOrUnknown(data['action_id']!, _actionIdMeta));
    } else if (isInserting) {
      context.missing(_actionIdMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(_reasonMeta,
          reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AuditEntryData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AuditEntryData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      at: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}at'])!,
      who: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}who'])!,
      station: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}station'])!,
      roleName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role_name'])!,
      surface: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}surface'])!,
      itemKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}item_key'])!,
      member: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}member']),
      oldValue: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}old_value']),
      newValue: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}new_value']),
      groupRequired: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}group_required'])!,
      allowed: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}allowed'])!,
      origin: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}origin'])!,
      actionId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action_id'])!,
      reason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reason']),
    );
  }

  @override
  $AuditEntryTable createAlias(String alias) {
    return $AuditEntryTable(attachedDatabase, alias);
  }
}

class AuditEntryData extends DataClass implements Insertable<AuditEntryData> {
  final int id;
  final DateTime at;

  /// Username, or `'anonymous'`.
  final String who;

  /// Hostname of the station the action was made from.
  final String station;
  final String roleName;

  /// `'tag' | 'pref' | 'route' | 'auth'`.
  final String surface;
  final String itemKey;

  /// Dotted path within a struct write, e.g. `p_cfg.Freq`. Null for scalars.
  final String? member;
  final String? oldValue;
  final String? newValue;
  final String groupRequired;

  /// False rows are denials, and they are kept.
  final bool allowed;

  /// Defaults to hand-made **on purpose**.
  ///
  /// Today every external caller of `stateMan.write` is a widget, but that
  /// holds by accident rather than by construction. Defaulting to `'operator'`
  /// means an unmarked future machine caller lands *in* the trail loudly
  /// rather than escaping it silently; an absent audit row is the one defect
  /// nobody ever notices.
  final String origin;

  /// Correlation id: one human action, N rows.
  final String actionId;

  /// Free-text justification, prompted for on the `configure` and `administer`
  /// surfaces only. The column exists for every row.
  final String? reason;
  const AuditEntryData(
      {required this.id,
      required this.at,
      required this.who,
      required this.station,
      required this.roleName,
      required this.surface,
      required this.itemKey,
      this.member,
      this.oldValue,
      this.newValue,
      required this.groupRequired,
      required this.allowed,
      required this.origin,
      required this.actionId,
      this.reason});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['at'] = Variable<DateTime>(at);
    map['who'] = Variable<String>(who);
    map['station'] = Variable<String>(station);
    map['role_name'] = Variable<String>(roleName);
    map['surface'] = Variable<String>(surface);
    map['item_key'] = Variable<String>(itemKey);
    if (!nullToAbsent || member != null) {
      map['member'] = Variable<String>(member);
    }
    if (!nullToAbsent || oldValue != null) {
      map['old_value'] = Variable<String>(oldValue);
    }
    if (!nullToAbsent || newValue != null) {
      map['new_value'] = Variable<String>(newValue);
    }
    map['group_required'] = Variable<String>(groupRequired);
    map['allowed'] = Variable<bool>(allowed);
    map['origin'] = Variable<String>(origin);
    map['action_id'] = Variable<String>(actionId);
    if (!nullToAbsent || reason != null) {
      map['reason'] = Variable<String>(reason);
    }
    return map;
  }

  AuditEntryCompanion toCompanion(bool nullToAbsent) {
    return AuditEntryCompanion(
      id: Value(id),
      at: Value(at),
      who: Value(who),
      station: Value(station),
      roleName: Value(roleName),
      surface: Value(surface),
      itemKey: Value(itemKey),
      member:
          member == null && nullToAbsent ? const Value.absent() : Value(member),
      oldValue: oldValue == null && nullToAbsent
          ? const Value.absent()
          : Value(oldValue),
      newValue: newValue == null && nullToAbsent
          ? const Value.absent()
          : Value(newValue),
      groupRequired: Value(groupRequired),
      allowed: Value(allowed),
      origin: Value(origin),
      actionId: Value(actionId),
      reason:
          reason == null && nullToAbsent ? const Value.absent() : Value(reason),
    );
  }

  factory AuditEntryData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AuditEntryData(
      id: serializer.fromJson<int>(json['id']),
      at: serializer.fromJson<DateTime>(json['at']),
      who: serializer.fromJson<String>(json['who']),
      station: serializer.fromJson<String>(json['station']),
      roleName: serializer.fromJson<String>(json['roleName']),
      surface: serializer.fromJson<String>(json['surface']),
      itemKey: serializer.fromJson<String>(json['itemKey']),
      member: serializer.fromJson<String?>(json['member']),
      oldValue: serializer.fromJson<String?>(json['oldValue']),
      newValue: serializer.fromJson<String?>(json['newValue']),
      groupRequired: serializer.fromJson<String>(json['groupRequired']),
      allowed: serializer.fromJson<bool>(json['allowed']),
      origin: serializer.fromJson<String>(json['origin']),
      actionId: serializer.fromJson<String>(json['actionId']),
      reason: serializer.fromJson<String?>(json['reason']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'at': serializer.toJson<DateTime>(at),
      'who': serializer.toJson<String>(who),
      'station': serializer.toJson<String>(station),
      'roleName': serializer.toJson<String>(roleName),
      'surface': serializer.toJson<String>(surface),
      'itemKey': serializer.toJson<String>(itemKey),
      'member': serializer.toJson<String?>(member),
      'oldValue': serializer.toJson<String?>(oldValue),
      'newValue': serializer.toJson<String?>(newValue),
      'groupRequired': serializer.toJson<String>(groupRequired),
      'allowed': serializer.toJson<bool>(allowed),
      'origin': serializer.toJson<String>(origin),
      'actionId': serializer.toJson<String>(actionId),
      'reason': serializer.toJson<String?>(reason),
    };
  }

  AuditEntryData copyWith(
          {int? id,
          DateTime? at,
          String? who,
          String? station,
          String? roleName,
          String? surface,
          String? itemKey,
          Value<String?> member = const Value.absent(),
          Value<String?> oldValue = const Value.absent(),
          Value<String?> newValue = const Value.absent(),
          String? groupRequired,
          bool? allowed,
          String? origin,
          String? actionId,
          Value<String?> reason = const Value.absent()}) =>
      AuditEntryData(
        id: id ?? this.id,
        at: at ?? this.at,
        who: who ?? this.who,
        station: station ?? this.station,
        roleName: roleName ?? this.roleName,
        surface: surface ?? this.surface,
        itemKey: itemKey ?? this.itemKey,
        member: member.present ? member.value : this.member,
        oldValue: oldValue.present ? oldValue.value : this.oldValue,
        newValue: newValue.present ? newValue.value : this.newValue,
        groupRequired: groupRequired ?? this.groupRequired,
        allowed: allowed ?? this.allowed,
        origin: origin ?? this.origin,
        actionId: actionId ?? this.actionId,
        reason: reason.present ? reason.value : this.reason,
      );
  AuditEntryData copyWithCompanion(AuditEntryCompanion data) {
    return AuditEntryData(
      id: data.id.present ? data.id.value : this.id,
      at: data.at.present ? data.at.value : this.at,
      who: data.who.present ? data.who.value : this.who,
      station: data.station.present ? data.station.value : this.station,
      roleName: data.roleName.present ? data.roleName.value : this.roleName,
      surface: data.surface.present ? data.surface.value : this.surface,
      itemKey: data.itemKey.present ? data.itemKey.value : this.itemKey,
      member: data.member.present ? data.member.value : this.member,
      oldValue: data.oldValue.present ? data.oldValue.value : this.oldValue,
      newValue: data.newValue.present ? data.newValue.value : this.newValue,
      groupRequired: data.groupRequired.present
          ? data.groupRequired.value
          : this.groupRequired,
      allowed: data.allowed.present ? data.allowed.value : this.allowed,
      origin: data.origin.present ? data.origin.value : this.origin,
      actionId: data.actionId.present ? data.actionId.value : this.actionId,
      reason: data.reason.present ? data.reason.value : this.reason,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AuditEntryData(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('who: $who, ')
          ..write('station: $station, ')
          ..write('roleName: $roleName, ')
          ..write('surface: $surface, ')
          ..write('itemKey: $itemKey, ')
          ..write('member: $member, ')
          ..write('oldValue: $oldValue, ')
          ..write('newValue: $newValue, ')
          ..write('groupRequired: $groupRequired, ')
          ..write('allowed: $allowed, ')
          ..write('origin: $origin, ')
          ..write('actionId: $actionId, ')
          ..write('reason: $reason')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      at,
      who,
      station,
      roleName,
      surface,
      itemKey,
      member,
      oldValue,
      newValue,
      groupRequired,
      allowed,
      origin,
      actionId,
      reason);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuditEntryData &&
          other.id == this.id &&
          other.at == this.at &&
          other.who == this.who &&
          other.station == this.station &&
          other.roleName == this.roleName &&
          other.surface == this.surface &&
          other.itemKey == this.itemKey &&
          other.member == this.member &&
          other.oldValue == this.oldValue &&
          other.newValue == this.newValue &&
          other.groupRequired == this.groupRequired &&
          other.allowed == this.allowed &&
          other.origin == this.origin &&
          other.actionId == this.actionId &&
          other.reason == this.reason);
}

class AuditEntryCompanion extends UpdateCompanion<AuditEntryData> {
  final Value<int> id;
  final Value<DateTime> at;
  final Value<String> who;
  final Value<String> station;
  final Value<String> roleName;
  final Value<String> surface;
  final Value<String> itemKey;
  final Value<String?> member;
  final Value<String?> oldValue;
  final Value<String?> newValue;
  final Value<String> groupRequired;
  final Value<bool> allowed;
  final Value<String> origin;
  final Value<String> actionId;
  final Value<String?> reason;
  const AuditEntryCompanion({
    this.id = const Value.absent(),
    this.at = const Value.absent(),
    this.who = const Value.absent(),
    this.station = const Value.absent(),
    this.roleName = const Value.absent(),
    this.surface = const Value.absent(),
    this.itemKey = const Value.absent(),
    this.member = const Value.absent(),
    this.oldValue = const Value.absent(),
    this.newValue = const Value.absent(),
    this.groupRequired = const Value.absent(),
    this.allowed = const Value.absent(),
    this.origin = const Value.absent(),
    this.actionId = const Value.absent(),
    this.reason = const Value.absent(),
  });
  AuditEntryCompanion.insert({
    this.id = const Value.absent(),
    required DateTime at,
    required String who,
    required String station,
    required String roleName,
    required String surface,
    required String itemKey,
    this.member = const Value.absent(),
    this.oldValue = const Value.absent(),
    this.newValue = const Value.absent(),
    required String groupRequired,
    required bool allowed,
    this.origin = const Value.absent(),
    required String actionId,
    this.reason = const Value.absent(),
  })  : at = Value(at),
        who = Value(who),
        station = Value(station),
        roleName = Value(roleName),
        surface = Value(surface),
        itemKey = Value(itemKey),
        groupRequired = Value(groupRequired),
        allowed = Value(allowed),
        actionId = Value(actionId);
  static Insertable<AuditEntryData> custom({
    Expression<int>? id,
    Expression<DateTime>? at,
    Expression<String>? who,
    Expression<String>? station,
    Expression<String>? roleName,
    Expression<String>? surface,
    Expression<String>? itemKey,
    Expression<String>? member,
    Expression<String>? oldValue,
    Expression<String>? newValue,
    Expression<String>? groupRequired,
    Expression<bool>? allowed,
    Expression<String>? origin,
    Expression<String>? actionId,
    Expression<String>? reason,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (at != null) 'at': at,
      if (who != null) 'who': who,
      if (station != null) 'station': station,
      if (roleName != null) 'role_name': roleName,
      if (surface != null) 'surface': surface,
      if (itemKey != null) 'item_key': itemKey,
      if (member != null) 'member': member,
      if (oldValue != null) 'old_value': oldValue,
      if (newValue != null) 'new_value': newValue,
      if (groupRequired != null) 'group_required': groupRequired,
      if (allowed != null) 'allowed': allowed,
      if (origin != null) 'origin': origin,
      if (actionId != null) 'action_id': actionId,
      if (reason != null) 'reason': reason,
    });
  }

  AuditEntryCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? at,
      Value<String>? who,
      Value<String>? station,
      Value<String>? roleName,
      Value<String>? surface,
      Value<String>? itemKey,
      Value<String?>? member,
      Value<String?>? oldValue,
      Value<String?>? newValue,
      Value<String>? groupRequired,
      Value<bool>? allowed,
      Value<String>? origin,
      Value<String>? actionId,
      Value<String?>? reason}) {
    return AuditEntryCompanion(
      id: id ?? this.id,
      at: at ?? this.at,
      who: who ?? this.who,
      station: station ?? this.station,
      roleName: roleName ?? this.roleName,
      surface: surface ?? this.surface,
      itemKey: itemKey ?? this.itemKey,
      member: member ?? this.member,
      oldValue: oldValue ?? this.oldValue,
      newValue: newValue ?? this.newValue,
      groupRequired: groupRequired ?? this.groupRequired,
      allowed: allowed ?? this.allowed,
      origin: origin ?? this.origin,
      actionId: actionId ?? this.actionId,
      reason: reason ?? this.reason,
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
    if (who.present) {
      map['who'] = Variable<String>(who.value);
    }
    if (station.present) {
      map['station'] = Variable<String>(station.value);
    }
    if (roleName.present) {
      map['role_name'] = Variable<String>(roleName.value);
    }
    if (surface.present) {
      map['surface'] = Variable<String>(surface.value);
    }
    if (itemKey.present) {
      map['item_key'] = Variable<String>(itemKey.value);
    }
    if (member.present) {
      map['member'] = Variable<String>(member.value);
    }
    if (oldValue.present) {
      map['old_value'] = Variable<String>(oldValue.value);
    }
    if (newValue.present) {
      map['new_value'] = Variable<String>(newValue.value);
    }
    if (groupRequired.present) {
      map['group_required'] = Variable<String>(groupRequired.value);
    }
    if (allowed.present) {
      map['allowed'] = Variable<bool>(allowed.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (actionId.present) {
      map['action_id'] = Variable<String>(actionId.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AuditEntryCompanion(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('who: $who, ')
          ..write('station: $station, ')
          ..write('roleName: $roleName, ')
          ..write('surface: $surface, ')
          ..write('itemKey: $itemKey, ')
          ..write('member: $member, ')
          ..write('oldValue: $oldValue, ')
          ..write('newValue: $newValue, ')
          ..write('groupRequired: $groupRequired, ')
          ..write('allowed: $allowed, ')
          ..write('origin: $origin, ')
          ..write('actionId: $actionId, ')
          ..write('reason: $reason')
          ..write(')'))
        .toString();
  }
}

class $AccessTemplateTableTable extends AccessTemplateTable
    with TableInfo<$AccessTemplateTableTable, AccessTemplateTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccessTemplateTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rulesMeta = const VerificationMeta('rules');
  @override
  late final GeneratedColumn<String> rules = GeneratedColumn<String>(
      'rules', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [name, rules, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'access_template';
  @override
  VerificationContext validateIntegrity(
      Insertable<AccessTemplateTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('rules')) {
      context.handle(
          _rulesMeta, rules.isAcceptableOrUnknown(data['rules']!, _rulesMeta));
    } else if (isInserting) {
      context.missing(_rulesMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  AccessTemplateTableData map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AccessTemplateTableData(
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      rules: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rules'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $AccessTemplateTableTable createAlias(String alias) {
    return $AccessTemplateTableTable(attachedDatabase, alias);
  }
}

class AccessTemplateTableData extends DataClass
    implements Insertable<AccessTemplateTableData> {
  /// The user-facing template name, and the value an
  /// [AccessKeyBindingTable] row points at.
  ///
  /// The name is the primary key rather than a surrogate id for the same
  /// reason [AppRole]'s is: it is what a person types into the key repository
  /// and what the binding carries, so a rename is a visible operation rather
  /// than an invisible one.
  final String name;

  /// JSON object of member name -> `AccessGroup` name, written by
  /// `AccessTemplate.encodeRules()` and read back by
  /// `AccessTemplate.decodeRules()`. The member name `'*'` (`kWholeKeyMember`)
  /// means the whole key — deliberately not a legal IEC 61131-3 identifier, so
  /// it cannot collide with a real member.
  ///
  /// A member no rule mentions is **unrestricted** — tags fail open, which is
  /// why the key repository has to make unbound keys findable at a glance:
  /// visibility is what replaces enforcement here.
  final String rules;
  final DateTime updatedAt;
  const AccessTemplateTableData(
      {required this.name, required this.rules, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['rules'] = Variable<String>(rules);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  AccessTemplateTableCompanion toCompanion(bool nullToAbsent) {
    return AccessTemplateTableCompanion(
      name: Value(name),
      rules: Value(rules),
      updatedAt: Value(updatedAt),
    );
  }

  factory AccessTemplateTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AccessTemplateTableData(
      name: serializer.fromJson<String>(json['name']),
      rules: serializer.fromJson<String>(json['rules']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'rules': serializer.toJson<String>(rules),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  AccessTemplateTableData copyWith(
          {String? name, String? rules, DateTime? updatedAt}) =>
      AccessTemplateTableData(
        name: name ?? this.name,
        rules: rules ?? this.rules,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  AccessTemplateTableData copyWithCompanion(AccessTemplateTableCompanion data) {
    return AccessTemplateTableData(
      name: data.name.present ? data.name.value : this.name,
      rules: data.rules.present ? data.rules.value : this.rules,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccessTemplateTableData(')
          ..write('name: $name, ')
          ..write('rules: $rules, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, rules, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccessTemplateTableData &&
          other.name == this.name &&
          other.rules == this.rules &&
          other.updatedAt == this.updatedAt);
}

class AccessTemplateTableCompanion
    extends UpdateCompanion<AccessTemplateTableData> {
  final Value<String> name;
  final Value<String> rules;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const AccessTemplateTableCompanion({
    this.name = const Value.absent(),
    this.rules = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AccessTemplateTableCompanion.insert({
    required String name,
    required String rules,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : name = Value(name),
        rules = Value(rules),
        updatedAt = Value(updatedAt);
  static Insertable<AccessTemplateTableData> custom({
    Expression<String>? name,
    Expression<String>? rules,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (rules != null) 'rules': rules,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AccessTemplateTableCompanion copyWith(
      {Value<String>? name,
      Value<String>? rules,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return AccessTemplateTableCompanion(
      name: name ?? this.name,
      rules: rules ?? this.rules,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (rules.present) {
      map['rules'] = Variable<String>(rules.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccessTemplateTableCompanion(')
          ..write('name: $name, ')
          ..write('rules: $rules, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AccessKeyBindingTableTable extends AccessKeyBindingTable
    with TableInfo<$AccessKeyBindingTableTable, AccessKeyBindingTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccessKeyBindingTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyNameMeta =
      const VerificationMeta('keyName');
  @override
  late final GeneratedColumn<String> keyName = GeneratedColumn<String>(
      'key_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _templateNameMeta =
      const VerificationMeta('templateName');
  @override
  late final GeneratedColumn<String> templateName = GeneratedColumn<String>(
      'template_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [keyName, templateName, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'access_key_binding';
  @override
  VerificationContext validateIntegrity(
      Insertable<AccessKeyBindingTableData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key_name')) {
      context.handle(_keyNameMeta,
          keyName.isAcceptableOrUnknown(data['key_name']!, _keyNameMeta));
    } else if (isInserting) {
      context.missing(_keyNameMeta);
    }
    if (data.containsKey('template_name')) {
      context.handle(
          _templateNameMeta,
          templateName.isAcceptableOrUnknown(
              data['template_name']!, _templateNameMeta));
    } else if (isInserting) {
      context.missing(_templateNameMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {keyName};
  @override
  AccessKeyBindingTableData map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AccessKeyBindingTableData(
      keyName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key_name'])!,
      templateName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}template_name'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $AccessKeyBindingTableTable createAlias(String alias) {
    return $AccessKeyBindingTableTable(attachedDatabase, alias);
  }
}

class AccessKeyBindingTableData extends DataClass
    implements Insertable<AccessKeyBindingTableData> {
  /// The `keyMappings` key this binding is for, and the primary key — so a
  /// key **cannot be bound twice**. "Explicit, per key, always" made
  /// structural rather than left to a caller to uphold.
  final String keyName;

  /// The [AccessTemplateTable.name] this key resolves through, matched by name
  /// and carrying **no foreign key**.
  ///
  /// That is deliberate. The resolver treats a binding naming a missing
  /// template as *unbound* and the key repository surfaces it, whereas a
  /// database-level constraint would make a template delete fail with a driver
  /// error rather than with `TemplateInUseException`'s named list of the keys
  /// still bound — and on Postgres it would make the delete's outcome depend
  /// on which station happened to run the migration.
  final String templateName;
  final DateTime updatedAt;
  const AccessKeyBindingTableData(
      {required this.keyName,
      required this.templateName,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key_name'] = Variable<String>(keyName);
    map['template_name'] = Variable<String>(templateName);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  AccessKeyBindingTableCompanion toCompanion(bool nullToAbsent) {
    return AccessKeyBindingTableCompanion(
      keyName: Value(keyName),
      templateName: Value(templateName),
      updatedAt: Value(updatedAt),
    );
  }

  factory AccessKeyBindingTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AccessKeyBindingTableData(
      keyName: serializer.fromJson<String>(json['keyName']),
      templateName: serializer.fromJson<String>(json['templateName']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'keyName': serializer.toJson<String>(keyName),
      'templateName': serializer.toJson<String>(templateName),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  AccessKeyBindingTableData copyWith(
          {String? keyName, String? templateName, DateTime? updatedAt}) =>
      AccessKeyBindingTableData(
        keyName: keyName ?? this.keyName,
        templateName: templateName ?? this.templateName,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  AccessKeyBindingTableData copyWithCompanion(
      AccessKeyBindingTableCompanion data) {
    return AccessKeyBindingTableData(
      keyName: data.keyName.present ? data.keyName.value : this.keyName,
      templateName: data.templateName.present
          ? data.templateName.value
          : this.templateName,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccessKeyBindingTableData(')
          ..write('keyName: $keyName, ')
          ..write('templateName: $templateName, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(keyName, templateName, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccessKeyBindingTableData &&
          other.keyName == this.keyName &&
          other.templateName == this.templateName &&
          other.updatedAt == this.updatedAt);
}

class AccessKeyBindingTableCompanion
    extends UpdateCompanion<AccessKeyBindingTableData> {
  final Value<String> keyName;
  final Value<String> templateName;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const AccessKeyBindingTableCompanion({
    this.keyName = const Value.absent(),
    this.templateName = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AccessKeyBindingTableCompanion.insert({
    required String keyName,
    required String templateName,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : keyName = Value(keyName),
        templateName = Value(templateName),
        updatedAt = Value(updatedAt);
  static Insertable<AccessKeyBindingTableData> custom({
    Expression<String>? keyName,
    Expression<String>? templateName,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (keyName != null) 'key_name': keyName,
      if (templateName != null) 'template_name': templateName,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AccessKeyBindingTableCompanion copyWith(
      {Value<String>? keyName,
      Value<String>? templateName,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return AccessKeyBindingTableCompanion(
      keyName: keyName ?? this.keyName,
      templateName: templateName ?? this.templateName,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (keyName.present) {
      map['key_name'] = Variable<String>(keyName.value);
    }
    if (templateName.present) {
      map['template_name'] = Variable<String>(templateName.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccessKeyBindingTableCompanion(')
          ..write('keyName: $keyName, ')
          ..write('templateName: $templateName, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AlarmTable alarm = $AlarmTable(this);
  late final $AlarmHistoryTable alarmHistory = $AlarmHistoryTable(this);
  late final $FlutterPreferencesTable flutterPreferences =
      $FlutterPreferencesTable(this);
  late final $HistoryViewTable historyView = $HistoryViewTable(this);
  late final $HistoryViewKeyTable historyViewKey = $HistoryViewKeyTable(this);
  late final $HistoryViewGraphTable historyViewGraph =
      $HistoryViewGraphTable(this);
  late final $HistoryViewPeriodTable historyViewPeriod =
      $HistoryViewPeriodTable(this);
  late final $AuditLogTable auditLog = $AuditLogTable(this);
  late final $PlcCodeBlockTableTable plcCodeBlockTable =
      $PlcCodeBlockTableTable(this);
  late final $PlcVariableTableTable plcVariableTable =
      $PlcVariableTableTable(this);
  late final $DrawingTableTable drawingTable = $DrawingTableTable(this);
  late final $DrawingComponentTableTable drawingComponentTable =
      $DrawingComponentTableTable(this);
  late final $TechDocTableTable techDocTable = $TechDocTableTable(this);
  late final $TechDocSectionTableTable techDocSectionTable =
      $TechDocSectionTableTable(this);
  late final $McpProposalTableTable mcpProposalTable =
      $McpProposalTableTable(this);
  late final $PlcVarRefTableTable plcVarRefTable = $PlcVarRefTableTable(this);
  late final $PlcFbInstanceTableTable plcFbInstanceTable =
      $PlcFbInstanceTableTable(this);
  late final $PlcBlockCallTableTable plcBlockCallTable =
      $PlcBlockCallTableTable(this);
  late final $AppRoleTable appRole = $AppRoleTable(this);
  late final $AppUserTable appUser = $AppUserTable(this);
  late final $AuditEntryTable auditEntry = $AuditEntryTable(this);
  late final $AccessTemplateTableTable accessTemplateTable =
      $AccessTemplateTableTable(this);
  late final $AccessKeyBindingTableTable accessKeyBindingTable =
      $AccessKeyBindingTableTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        alarm,
        alarmHistory,
        flutterPreferences,
        historyView,
        historyViewKey,
        historyViewGraph,
        historyViewPeriod,
        auditLog,
        plcCodeBlockTable,
        plcVariableTable,
        drawingTable,
        drawingComponentTable,
        techDocTable,
        techDocSectionTable,
        mcpProposalTable,
        plcVarRefTable,
        plcFbInstanceTable,
        plcBlockCallTable,
        appRole,
        appUser,
        auditEntry,
        accessTemplateTable,
        accessKeyBindingTable
      ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('history_view',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('history_view_key', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('history_view',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('history_view_graph', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('history_view',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('history_view_period', kind: UpdateKind.delete),
            ],
          ),
        ],
      );
}

typedef $$AlarmTableCreateCompanionBuilder = AlarmCompanion Function({
  required String uid,
  Value<String?> key,
  required String title,
  required String description,
  required String rules,
  Value<int> rowid,
});
typedef $$AlarmTableUpdateCompanionBuilder = AlarmCompanion Function({
  Value<String> uid,
  Value<String?> key,
  Value<String> title,
  Value<String> description,
  Value<String> rules,
  Value<int> rowid,
});

final class $$AlarmTableReferences
    extends BaseReferences<_$AppDatabase, $AlarmTable, AlarmConfig> {
  $$AlarmTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$AlarmHistoryTable, List<AlarmHistoryData>>
      _alarmHistoryRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.alarmHistory,
              aliasName: 'alarm__uid__alarm_history__alarm_uid');

  $$AlarmHistoryTableProcessedTableManager get alarmHistoryRefs {
    final manager = $$AlarmHistoryTableTableManager($_db, $_db.alarmHistory)
        .filter((f) => f.alarmUid.uid.sqlEquals($_itemColumn<String>('uid')!));

    final cache = $_typedResult.readTableOrNull(_alarmHistoryRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$AlarmTableFilterComposer extends Composer<_$AppDatabase, $AlarmTable> {
  $$AlarmTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rules => $composableBuilder(
      column: $table.rules, builder: (column) => ColumnFilters(column));

  Expression<bool> alarmHistoryRefs(
      Expression<bool> Function($$AlarmHistoryTableFilterComposer f) f) {
    final $$AlarmHistoryTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.uid,
        referencedTable: $db.alarmHistory,
        getReferencedColumn: (t) => t.alarmUid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AlarmHistoryTableFilterComposer(
              $db: $db,
              $table: $db.alarmHistory,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AlarmTableOrderingComposer
    extends Composer<_$AppDatabase, $AlarmTable> {
  $$AlarmTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rules => $composableBuilder(
      column: $table.rules, builder: (column) => ColumnOrderings(column));
}

class $$AlarmTableAnnotationComposer
    extends Composer<_$AppDatabase, $AlarmTable> {
  $$AlarmTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
      column: $table.description, builder: (column) => column);

  GeneratedColumn<String> get rules =>
      $composableBuilder(column: $table.rules, builder: (column) => column);

  Expression<T> alarmHistoryRefs<T extends Object>(
      Expression<T> Function($$AlarmHistoryTableAnnotationComposer a) f) {
    final $$AlarmHistoryTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.uid,
        referencedTable: $db.alarmHistory,
        getReferencedColumn: (t) => t.alarmUid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AlarmHistoryTableAnnotationComposer(
              $db: $db,
              $table: $db.alarmHistory,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AlarmTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AlarmTable,
    AlarmConfig,
    $$AlarmTableFilterComposer,
    $$AlarmTableOrderingComposer,
    $$AlarmTableAnnotationComposer,
    $$AlarmTableCreateCompanionBuilder,
    $$AlarmTableUpdateCompanionBuilder,
    (AlarmConfig, $$AlarmTableReferences),
    AlarmConfig,
    PrefetchHooks Function({bool alarmHistoryRefs})> {
  $$AlarmTableTableManager(_$AppDatabase db, $AlarmTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AlarmTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AlarmTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AlarmTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> uid = const Value.absent(),
            Value<String?> key = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> description = const Value.absent(),
            Value<String> rules = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AlarmCompanion(
            uid: uid,
            key: key,
            title: title,
            description: description,
            rules: rules,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String uid,
            Value<String?> key = const Value.absent(),
            required String title,
            required String description,
            required String rules,
            Value<int> rowid = const Value.absent(),
          }) =>
              AlarmCompanion.insert(
            uid: uid,
            key: key,
            title: title,
            description: description,
            rules: rules,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$AlarmTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({alarmHistoryRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (alarmHistoryRefs) db.alarmHistory],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (alarmHistoryRefs)
                    await $_getPrefetchedData<AlarmConfig, $AlarmTable,
                            AlarmHistoryData>(
                        currentTable: table,
                        referencedTable:
                            $$AlarmTableReferences._alarmHistoryRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$AlarmTableReferences(db, table, p0)
                                .alarmHistoryRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.alarmUid == item.uid),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$AlarmTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AlarmTable,
    AlarmConfig,
    $$AlarmTableFilterComposer,
    $$AlarmTableOrderingComposer,
    $$AlarmTableAnnotationComposer,
    $$AlarmTableCreateCompanionBuilder,
    $$AlarmTableUpdateCompanionBuilder,
    (AlarmConfig, $$AlarmTableReferences),
    AlarmConfig,
    PrefetchHooks Function({bool alarmHistoryRefs})>;
typedef $$AlarmHistoryTableCreateCompanionBuilder = AlarmHistoryCompanion
    Function({
  Value<int> id,
  required String alarmUid,
  required String alarmTitle,
  required String alarmDescription,
  required String alarmLevel,
  Value<String?> expression,
  required bool active,
  required bool pendingAck,
  required DateTime createdAt,
  Value<DateTime?> deactivatedAt,
  Value<DateTime?> acknowledgedAt,
});
typedef $$AlarmHistoryTableUpdateCompanionBuilder = AlarmHistoryCompanion
    Function({
  Value<int> id,
  Value<String> alarmUid,
  Value<String> alarmTitle,
  Value<String> alarmDescription,
  Value<String> alarmLevel,
  Value<String?> expression,
  Value<bool> active,
  Value<bool> pendingAck,
  Value<DateTime> createdAt,
  Value<DateTime?> deactivatedAt,
  Value<DateTime?> acknowledgedAt,
});

final class $$AlarmHistoryTableReferences extends BaseReferences<_$AppDatabase,
    $AlarmHistoryTable, AlarmHistoryData> {
  $$AlarmHistoryTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AlarmTable _alarmUidTable(_$AppDatabase db) =>
      db.alarm.createAlias('alarm_history__alarm_uid__alarm__uid');

  $$AlarmTableProcessedTableManager get alarmUid {
    final $_column = $_itemColumn<String>('alarm_uid')!;

    final manager = $$AlarmTableTableManager($_db, $_db.alarm)
        .filter((f) => f.uid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_alarmUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$AlarmHistoryTableFilterComposer
    extends Composer<_$AppDatabase, $AlarmHistoryTable> {
  $$AlarmHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alarmTitle => $composableBuilder(
      column: $table.alarmTitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alarmDescription => $composableBuilder(
      column: $table.alarmDescription,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alarmLevel => $composableBuilder(
      column: $table.alarmLevel, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get active => $composableBuilder(
      column: $table.active, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get pendingAck => $composableBuilder(
      column: $table.pendingAck, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get deactivatedAt => $composableBuilder(
      column: $table.deactivatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get acknowledgedAt => $composableBuilder(
      column: $table.acknowledgedAt,
      builder: (column) => ColumnFilters(column));

  $$AlarmTableFilterComposer get alarmUid {
    final $$AlarmTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.alarmUid,
        referencedTable: $db.alarm,
        getReferencedColumn: (t) => t.uid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AlarmTableFilterComposer(
              $db: $db,
              $table: $db.alarm,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AlarmHistoryTableOrderingComposer
    extends Composer<_$AppDatabase, $AlarmHistoryTable> {
  $$AlarmHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alarmTitle => $composableBuilder(
      column: $table.alarmTitle, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alarmDescription => $composableBuilder(
      column: $table.alarmDescription,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alarmLevel => $composableBuilder(
      column: $table.alarmLevel, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get active => $composableBuilder(
      column: $table.active, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get pendingAck => $composableBuilder(
      column: $table.pendingAck, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get deactivatedAt => $composableBuilder(
      column: $table.deactivatedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get acknowledgedAt => $composableBuilder(
      column: $table.acknowledgedAt,
      builder: (column) => ColumnOrderings(column));

  $$AlarmTableOrderingComposer get alarmUid {
    final $$AlarmTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.alarmUid,
        referencedTable: $db.alarm,
        getReferencedColumn: (t) => t.uid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AlarmTableOrderingComposer(
              $db: $db,
              $table: $db.alarm,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AlarmHistoryTableAnnotationComposer
    extends Composer<_$AppDatabase, $AlarmHistoryTable> {
  $$AlarmHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get alarmTitle => $composableBuilder(
      column: $table.alarmTitle, builder: (column) => column);

  GeneratedColumn<String> get alarmDescription => $composableBuilder(
      column: $table.alarmDescription, builder: (column) => column);

  GeneratedColumn<String> get alarmLevel => $composableBuilder(
      column: $table.alarmLevel, builder: (column) => column);

  GeneratedColumn<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => column);

  GeneratedColumn<bool> get active =>
      $composableBuilder(column: $table.active, builder: (column) => column);

  GeneratedColumn<bool> get pendingAck => $composableBuilder(
      column: $table.pendingAck, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deactivatedAt => $composableBuilder(
      column: $table.deactivatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get acknowledgedAt => $composableBuilder(
      column: $table.acknowledgedAt, builder: (column) => column);

  $$AlarmTableAnnotationComposer get alarmUid {
    final $$AlarmTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.alarmUid,
        referencedTable: $db.alarm,
        getReferencedColumn: (t) => t.uid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AlarmTableAnnotationComposer(
              $db: $db,
              $table: $db.alarm,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AlarmHistoryTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AlarmHistoryTable,
    AlarmHistoryData,
    $$AlarmHistoryTableFilterComposer,
    $$AlarmHistoryTableOrderingComposer,
    $$AlarmHistoryTableAnnotationComposer,
    $$AlarmHistoryTableCreateCompanionBuilder,
    $$AlarmHistoryTableUpdateCompanionBuilder,
    (AlarmHistoryData, $$AlarmHistoryTableReferences),
    AlarmHistoryData,
    PrefetchHooks Function({bool alarmUid})> {
  $$AlarmHistoryTableTableManager(_$AppDatabase db, $AlarmHistoryTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AlarmHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AlarmHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AlarmHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> alarmUid = const Value.absent(),
            Value<String> alarmTitle = const Value.absent(),
            Value<String> alarmDescription = const Value.absent(),
            Value<String> alarmLevel = const Value.absent(),
            Value<String?> expression = const Value.absent(),
            Value<bool> active = const Value.absent(),
            Value<bool> pendingAck = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> deactivatedAt = const Value.absent(),
            Value<DateTime?> acknowledgedAt = const Value.absent(),
          }) =>
              AlarmHistoryCompanion(
            id: id,
            alarmUid: alarmUid,
            alarmTitle: alarmTitle,
            alarmDescription: alarmDescription,
            alarmLevel: alarmLevel,
            expression: expression,
            active: active,
            pendingAck: pendingAck,
            createdAt: createdAt,
            deactivatedAt: deactivatedAt,
            acknowledgedAt: acknowledgedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String alarmUid,
            required String alarmTitle,
            required String alarmDescription,
            required String alarmLevel,
            Value<String?> expression = const Value.absent(),
            required bool active,
            required bool pendingAck,
            required DateTime createdAt,
            Value<DateTime?> deactivatedAt = const Value.absent(),
            Value<DateTime?> acknowledgedAt = const Value.absent(),
          }) =>
              AlarmHistoryCompanion.insert(
            id: id,
            alarmUid: alarmUid,
            alarmTitle: alarmTitle,
            alarmDescription: alarmDescription,
            alarmLevel: alarmLevel,
            expression: expression,
            active: active,
            pendingAck: pendingAck,
            createdAt: createdAt,
            deactivatedAt: deactivatedAt,
            acknowledgedAt: acknowledgedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$AlarmHistoryTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({alarmUid = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (alarmUid) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.alarmUid,
                    referencedTable:
                        $$AlarmHistoryTableReferences._alarmUidTable(db),
                    referencedColumn:
                        $$AlarmHistoryTableReferences._alarmUidTable(db).uid,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$AlarmHistoryTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AlarmHistoryTable,
    AlarmHistoryData,
    $$AlarmHistoryTableFilterComposer,
    $$AlarmHistoryTableOrderingComposer,
    $$AlarmHistoryTableAnnotationComposer,
    $$AlarmHistoryTableCreateCompanionBuilder,
    $$AlarmHistoryTableUpdateCompanionBuilder,
    (AlarmHistoryData, $$AlarmHistoryTableReferences),
    AlarmHistoryData,
    PrefetchHooks Function({bool alarmUid})>;
typedef $$FlutterPreferencesTableCreateCompanionBuilder
    = FlutterPreferencesCompanion Function({
  required String key,
  Value<String?> value,
  required String type,
  Value<int> rowid,
});
typedef $$FlutterPreferencesTableUpdateCompanionBuilder
    = FlutterPreferencesCompanion Function({
  Value<String> key,
  Value<String?> value,
  Value<String> type,
  Value<int> rowid,
});

class $$FlutterPreferencesTableFilterComposer
    extends Composer<_$AppDatabase, $FlutterPreferencesTable> {
  $$FlutterPreferencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));
}

class $$FlutterPreferencesTableOrderingComposer
    extends Composer<_$AppDatabase, $FlutterPreferencesTable> {
  $$FlutterPreferencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));
}

class $$FlutterPreferencesTableAnnotationComposer
    extends Composer<_$AppDatabase, $FlutterPreferencesTable> {
  $$FlutterPreferencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);
}

class $$FlutterPreferencesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $FlutterPreferencesTable,
    FlutterPreference,
    $$FlutterPreferencesTableFilterComposer,
    $$FlutterPreferencesTableOrderingComposer,
    $$FlutterPreferencesTableAnnotationComposer,
    $$FlutterPreferencesTableCreateCompanionBuilder,
    $$FlutterPreferencesTableUpdateCompanionBuilder,
    (
      FlutterPreference,
      BaseReferences<_$AppDatabase, $FlutterPreferencesTable, FlutterPreference>
    ),
    FlutterPreference,
    PrefetchHooks Function()> {
  $$FlutterPreferencesTableTableManager(
      _$AppDatabase db, $FlutterPreferencesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FlutterPreferencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FlutterPreferencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FlutterPreferencesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String?> value = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FlutterPreferencesCompanion(
            key: key,
            value: value,
            type: type,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            Value<String?> value = const Value.absent(),
            required String type,
            Value<int> rowid = const Value.absent(),
          }) =>
              FlutterPreferencesCompanion.insert(
            key: key,
            value: value,
            type: type,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$FlutterPreferencesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $FlutterPreferencesTable,
    FlutterPreference,
    $$FlutterPreferencesTableFilterComposer,
    $$FlutterPreferencesTableOrderingComposer,
    $$FlutterPreferencesTableAnnotationComposer,
    $$FlutterPreferencesTableCreateCompanionBuilder,
    $$FlutterPreferencesTableUpdateCompanionBuilder,
    (
      FlutterPreference,
      BaseReferences<_$AppDatabase, $FlutterPreferencesTable, FlutterPreference>
    ),
    FlutterPreference,
    PrefetchHooks Function()>;
typedef $$HistoryViewTableCreateCompanionBuilder = HistoryViewCompanion
    Function({
  Value<int> id,
  required String name,
  Value<DateTime> createdAt,
  Value<DateTime?> updatedAt,
});
typedef $$HistoryViewTableUpdateCompanionBuilder = HistoryViewCompanion
    Function({
  Value<int> id,
  Value<String> name,
  Value<DateTime> createdAt,
  Value<DateTime?> updatedAt,
});

final class $$HistoryViewTableReferences
    extends BaseReferences<_$AppDatabase, $HistoryViewTable, HistoryViewData> {
  $$HistoryViewTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$HistoryViewKeyTable, List<HistoryViewKeyData>>
      _historyViewKeyRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.historyViewKey,
              aliasName: 'history_view__id__history_view_key__view_id');

  $$HistoryViewKeyTableProcessedTableManager get historyViewKeyRefs {
    final manager = $$HistoryViewKeyTableTableManager($_db, $_db.historyViewKey)
        .filter((f) => f.viewId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_historyViewKeyRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$HistoryViewGraphTable, List<HistoryViewGraphData>>
      _historyViewGraphRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.historyViewGraph,
              aliasName: 'history_view__id__history_view_graph__view_id');

  $$HistoryViewGraphTableProcessedTableManager get historyViewGraphRefs {
    final manager =
        $$HistoryViewGraphTableTableManager($_db, $_db.historyViewGraph)
            .filter((f) => f.viewId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_historyViewGraphRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$HistoryViewPeriodTable,
      List<HistoryViewPeriodData>> _historyViewPeriodRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.historyViewPeriod,
          aliasName: 'history_view__id__history_view_period__view_id');

  $$HistoryViewPeriodTableProcessedTableManager get historyViewPeriodRefs {
    final manager =
        $$HistoryViewPeriodTableTableManager($_db, $_db.historyViewPeriod)
            .filter((f) => f.viewId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_historyViewPeriodRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$HistoryViewTableFilterComposer
    extends Composer<_$AppDatabase, $HistoryViewTable> {
  $$HistoryViewTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  Expression<bool> historyViewKeyRefs(
      Expression<bool> Function($$HistoryViewKeyTableFilterComposer f) f) {
    final $$HistoryViewKeyTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.historyViewKey,
        getReferencedColumn: (t) => t.viewId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewKeyTableFilterComposer(
              $db: $db,
              $table: $db.historyViewKey,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> historyViewGraphRefs(
      Expression<bool> Function($$HistoryViewGraphTableFilterComposer f) f) {
    final $$HistoryViewGraphTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.historyViewGraph,
        getReferencedColumn: (t) => t.viewId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewGraphTableFilterComposer(
              $db: $db,
              $table: $db.historyViewGraph,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> historyViewPeriodRefs(
      Expression<bool> Function($$HistoryViewPeriodTableFilterComposer f) f) {
    final $$HistoryViewPeriodTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.historyViewPeriod,
        getReferencedColumn: (t) => t.viewId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewPeriodTableFilterComposer(
              $db: $db,
              $table: $db.historyViewPeriod,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$HistoryViewTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoryViewTable> {
  $$HistoryViewTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$HistoryViewTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoryViewTable> {
  $$HistoryViewTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> historyViewKeyRefs<T extends Object>(
      Expression<T> Function($$HistoryViewKeyTableAnnotationComposer a) f) {
    final $$HistoryViewKeyTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.historyViewKey,
        getReferencedColumn: (t) => t.viewId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewKeyTableAnnotationComposer(
              $db: $db,
              $table: $db.historyViewKey,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> historyViewGraphRefs<T extends Object>(
      Expression<T> Function($$HistoryViewGraphTableAnnotationComposer a) f) {
    final $$HistoryViewGraphTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.historyViewGraph,
        getReferencedColumn: (t) => t.viewId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewGraphTableAnnotationComposer(
              $db: $db,
              $table: $db.historyViewGraph,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> historyViewPeriodRefs<T extends Object>(
      Expression<T> Function($$HistoryViewPeriodTableAnnotationComposer a) f) {
    final $$HistoryViewPeriodTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.historyViewPeriod,
            getReferencedColumn: (t) => t.viewId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$HistoryViewPeriodTableAnnotationComposer(
                  $db: $db,
                  $table: $db.historyViewPeriod,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$HistoryViewTableTableManager extends RootTableManager<
    _$AppDatabase,
    $HistoryViewTable,
    HistoryViewData,
    $$HistoryViewTableFilterComposer,
    $$HistoryViewTableOrderingComposer,
    $$HistoryViewTableAnnotationComposer,
    $$HistoryViewTableCreateCompanionBuilder,
    $$HistoryViewTableUpdateCompanionBuilder,
    (HistoryViewData, $$HistoryViewTableReferences),
    HistoryViewData,
    PrefetchHooks Function(
        {bool historyViewKeyRefs,
        bool historyViewGraphRefs,
        bool historyViewPeriodRefs})> {
  $$HistoryViewTableTableManager(_$AppDatabase db, $HistoryViewTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryViewTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryViewTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryViewTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              HistoryViewCompanion(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              HistoryViewCompanion.insert(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$HistoryViewTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {historyViewKeyRefs = false,
              historyViewGraphRefs = false,
              historyViewPeriodRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (historyViewKeyRefs) db.historyViewKey,
                if (historyViewGraphRefs) db.historyViewGraph,
                if (historyViewPeriodRefs) db.historyViewPeriod
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (historyViewKeyRefs)
                    await $_getPrefetchedData<HistoryViewData,
                            $HistoryViewTable, HistoryViewKeyData>(
                        currentTable: table,
                        referencedTable: $$HistoryViewTableReferences
                            ._historyViewKeyRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$HistoryViewTableReferences(db, table, p0)
                                .historyViewKeyRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.viewId == item.id),
                        typedResults: items),
                  if (historyViewGraphRefs)
                    await $_getPrefetchedData<HistoryViewData,
                            $HistoryViewTable, HistoryViewGraphData>(
                        currentTable: table,
                        referencedTable: $$HistoryViewTableReferences
                            ._historyViewGraphRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$HistoryViewTableReferences(db, table, p0)
                                .historyViewGraphRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.viewId == item.id),
                        typedResults: items),
                  if (historyViewPeriodRefs)
                    await $_getPrefetchedData<HistoryViewData,
                            $HistoryViewTable, HistoryViewPeriodData>(
                        currentTable: table,
                        referencedTable: $$HistoryViewTableReferences
                            ._historyViewPeriodRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$HistoryViewTableReferences(db, table, p0)
                                .historyViewPeriodRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.viewId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$HistoryViewTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $HistoryViewTable,
    HistoryViewData,
    $$HistoryViewTableFilterComposer,
    $$HistoryViewTableOrderingComposer,
    $$HistoryViewTableAnnotationComposer,
    $$HistoryViewTableCreateCompanionBuilder,
    $$HistoryViewTableUpdateCompanionBuilder,
    (HistoryViewData, $$HistoryViewTableReferences),
    HistoryViewData,
    PrefetchHooks Function(
        {bool historyViewKeyRefs,
        bool historyViewGraphRefs,
        bool historyViewPeriodRefs})>;
typedef $$HistoryViewKeyTableCreateCompanionBuilder = HistoryViewKeyCompanion
    Function({
  Value<int> id,
  required int viewId,
  required String key,
  Value<String?> alias,
  Value<bool> useSecondYAxis,
  Value<int> graphIndex,
});
typedef $$HistoryViewKeyTableUpdateCompanionBuilder = HistoryViewKeyCompanion
    Function({
  Value<int> id,
  Value<int> viewId,
  Value<String> key,
  Value<String?> alias,
  Value<bool> useSecondYAxis,
  Value<int> graphIndex,
});

final class $$HistoryViewKeyTableReferences extends BaseReferences<
    _$AppDatabase, $HistoryViewKeyTable, HistoryViewKeyData> {
  $$HistoryViewKeyTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $HistoryViewTable _viewIdTable(_$AppDatabase db) =>
      db.historyView.createAlias('history_view_key__view_id__history_view__id');

  $$HistoryViewTableProcessedTableManager get viewId {
    final $_column = $_itemColumn<int>('view_id')!;

    final manager = $$HistoryViewTableTableManager($_db, $_db.historyView)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_viewIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$HistoryViewKeyTableFilterComposer
    extends Composer<_$AppDatabase, $HistoryViewKeyTable> {
  $$HistoryViewKeyTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alias => $composableBuilder(
      column: $table.alias, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get useSecondYAxis => $composableBuilder(
      column: $table.useSecondYAxis,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get graphIndex => $composableBuilder(
      column: $table.graphIndex, builder: (column) => ColumnFilters(column));

  $$HistoryViewTableFilterComposer get viewId {
    final $$HistoryViewTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableFilterComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewKeyTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoryViewKeyTable> {
  $$HistoryViewKeyTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alias => $composableBuilder(
      column: $table.alias, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get useSecondYAxis => $composableBuilder(
      column: $table.useSecondYAxis,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get graphIndex => $composableBuilder(
      column: $table.graphIndex, builder: (column) => ColumnOrderings(column));

  $$HistoryViewTableOrderingComposer get viewId {
    final $$HistoryViewTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableOrderingComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewKeyTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoryViewKeyTable> {
  $$HistoryViewKeyTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get alias =>
      $composableBuilder(column: $table.alias, builder: (column) => column);

  GeneratedColumn<bool> get useSecondYAxis => $composableBuilder(
      column: $table.useSecondYAxis, builder: (column) => column);

  GeneratedColumn<int> get graphIndex => $composableBuilder(
      column: $table.graphIndex, builder: (column) => column);

  $$HistoryViewTableAnnotationComposer get viewId {
    final $$HistoryViewTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableAnnotationComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewKeyTableTableManager extends RootTableManager<
    _$AppDatabase,
    $HistoryViewKeyTable,
    HistoryViewKeyData,
    $$HistoryViewKeyTableFilterComposer,
    $$HistoryViewKeyTableOrderingComposer,
    $$HistoryViewKeyTableAnnotationComposer,
    $$HistoryViewKeyTableCreateCompanionBuilder,
    $$HistoryViewKeyTableUpdateCompanionBuilder,
    (HistoryViewKeyData, $$HistoryViewKeyTableReferences),
    HistoryViewKeyData,
    PrefetchHooks Function({bool viewId})> {
  $$HistoryViewKeyTableTableManager(
      _$AppDatabase db, $HistoryViewKeyTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryViewKeyTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryViewKeyTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryViewKeyTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> viewId = const Value.absent(),
            Value<String> key = const Value.absent(),
            Value<String?> alias = const Value.absent(),
            Value<bool> useSecondYAxis = const Value.absent(),
            Value<int> graphIndex = const Value.absent(),
          }) =>
              HistoryViewKeyCompanion(
            id: id,
            viewId: viewId,
            key: key,
            alias: alias,
            useSecondYAxis: useSecondYAxis,
            graphIndex: graphIndex,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int viewId,
            required String key,
            Value<String?> alias = const Value.absent(),
            Value<bool> useSecondYAxis = const Value.absent(),
            Value<int> graphIndex = const Value.absent(),
          }) =>
              HistoryViewKeyCompanion.insert(
            id: id,
            viewId: viewId,
            key: key,
            alias: alias,
            useSecondYAxis: useSecondYAxis,
            graphIndex: graphIndex,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$HistoryViewKeyTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({viewId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (viewId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.viewId,
                    referencedTable:
                        $$HistoryViewKeyTableReferences._viewIdTable(db),
                    referencedColumn:
                        $$HistoryViewKeyTableReferences._viewIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$HistoryViewKeyTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $HistoryViewKeyTable,
    HistoryViewKeyData,
    $$HistoryViewKeyTableFilterComposer,
    $$HistoryViewKeyTableOrderingComposer,
    $$HistoryViewKeyTableAnnotationComposer,
    $$HistoryViewKeyTableCreateCompanionBuilder,
    $$HistoryViewKeyTableUpdateCompanionBuilder,
    (HistoryViewKeyData, $$HistoryViewKeyTableReferences),
    HistoryViewKeyData,
    PrefetchHooks Function({bool viewId})>;
typedef $$HistoryViewGraphTableCreateCompanionBuilder
    = HistoryViewGraphCompanion Function({
  Value<int> id,
  required int viewId,
  required int graphIndex,
  Value<String?> name,
  Value<String?> yAxisUnit,
  Value<String?> yAxis2Unit,
});
typedef $$HistoryViewGraphTableUpdateCompanionBuilder
    = HistoryViewGraphCompanion Function({
  Value<int> id,
  Value<int> viewId,
  Value<int> graphIndex,
  Value<String?> name,
  Value<String?> yAxisUnit,
  Value<String?> yAxis2Unit,
});

final class $$HistoryViewGraphTableReferences extends BaseReferences<
    _$AppDatabase, $HistoryViewGraphTable, HistoryViewGraphData> {
  $$HistoryViewGraphTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $HistoryViewTable _viewIdTable(_$AppDatabase db) => db.historyView
      .createAlias('history_view_graph__view_id__history_view__id');

  $$HistoryViewTableProcessedTableManager get viewId {
    final $_column = $_itemColumn<int>('view_id')!;

    final manager = $$HistoryViewTableTableManager($_db, $_db.historyView)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_viewIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$HistoryViewGraphTableFilterComposer
    extends Composer<_$AppDatabase, $HistoryViewGraphTable> {
  $$HistoryViewGraphTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get graphIndex => $composableBuilder(
      column: $table.graphIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get yAxisUnit => $composableBuilder(
      column: $table.yAxisUnit, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get yAxis2Unit => $composableBuilder(
      column: $table.yAxis2Unit, builder: (column) => ColumnFilters(column));

  $$HistoryViewTableFilterComposer get viewId {
    final $$HistoryViewTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableFilterComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewGraphTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoryViewGraphTable> {
  $$HistoryViewGraphTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get graphIndex => $composableBuilder(
      column: $table.graphIndex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get yAxisUnit => $composableBuilder(
      column: $table.yAxisUnit, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get yAxis2Unit => $composableBuilder(
      column: $table.yAxis2Unit, builder: (column) => ColumnOrderings(column));

  $$HistoryViewTableOrderingComposer get viewId {
    final $$HistoryViewTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableOrderingComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewGraphTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoryViewGraphTable> {
  $$HistoryViewGraphTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get graphIndex => $composableBuilder(
      column: $table.graphIndex, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get yAxisUnit =>
      $composableBuilder(column: $table.yAxisUnit, builder: (column) => column);

  GeneratedColumn<String> get yAxis2Unit => $composableBuilder(
      column: $table.yAxis2Unit, builder: (column) => column);

  $$HistoryViewTableAnnotationComposer get viewId {
    final $$HistoryViewTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableAnnotationComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewGraphTableTableManager extends RootTableManager<
    _$AppDatabase,
    $HistoryViewGraphTable,
    HistoryViewGraphData,
    $$HistoryViewGraphTableFilterComposer,
    $$HistoryViewGraphTableOrderingComposer,
    $$HistoryViewGraphTableAnnotationComposer,
    $$HistoryViewGraphTableCreateCompanionBuilder,
    $$HistoryViewGraphTableUpdateCompanionBuilder,
    (HistoryViewGraphData, $$HistoryViewGraphTableReferences),
    HistoryViewGraphData,
    PrefetchHooks Function({bool viewId})> {
  $$HistoryViewGraphTableTableManager(
      _$AppDatabase db, $HistoryViewGraphTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryViewGraphTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryViewGraphTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryViewGraphTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> viewId = const Value.absent(),
            Value<int> graphIndex = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<String?> yAxisUnit = const Value.absent(),
            Value<String?> yAxis2Unit = const Value.absent(),
          }) =>
              HistoryViewGraphCompanion(
            id: id,
            viewId: viewId,
            graphIndex: graphIndex,
            name: name,
            yAxisUnit: yAxisUnit,
            yAxis2Unit: yAxis2Unit,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int viewId,
            required int graphIndex,
            Value<String?> name = const Value.absent(),
            Value<String?> yAxisUnit = const Value.absent(),
            Value<String?> yAxis2Unit = const Value.absent(),
          }) =>
              HistoryViewGraphCompanion.insert(
            id: id,
            viewId: viewId,
            graphIndex: graphIndex,
            name: name,
            yAxisUnit: yAxisUnit,
            yAxis2Unit: yAxis2Unit,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$HistoryViewGraphTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({viewId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (viewId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.viewId,
                    referencedTable:
                        $$HistoryViewGraphTableReferences._viewIdTable(db),
                    referencedColumn:
                        $$HistoryViewGraphTableReferences._viewIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$HistoryViewGraphTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $HistoryViewGraphTable,
    HistoryViewGraphData,
    $$HistoryViewGraphTableFilterComposer,
    $$HistoryViewGraphTableOrderingComposer,
    $$HistoryViewGraphTableAnnotationComposer,
    $$HistoryViewGraphTableCreateCompanionBuilder,
    $$HistoryViewGraphTableUpdateCompanionBuilder,
    (HistoryViewGraphData, $$HistoryViewGraphTableReferences),
    HistoryViewGraphData,
    PrefetchHooks Function({bool viewId})>;
typedef $$HistoryViewPeriodTableCreateCompanionBuilder
    = HistoryViewPeriodCompanion Function({
  Value<int> id,
  required int viewId,
  required String name,
  required DateTime startAt,
  required DateTime endAt,
  Value<DateTime> createdAt,
});
typedef $$HistoryViewPeriodTableUpdateCompanionBuilder
    = HistoryViewPeriodCompanion Function({
  Value<int> id,
  Value<int> viewId,
  Value<String> name,
  Value<DateTime> startAt,
  Value<DateTime> endAt,
  Value<DateTime> createdAt,
});

final class $$HistoryViewPeriodTableReferences extends BaseReferences<
    _$AppDatabase, $HistoryViewPeriodTable, HistoryViewPeriodData> {
  $$HistoryViewPeriodTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $HistoryViewTable _viewIdTable(_$AppDatabase db) => db.historyView
      .createAlias('history_view_period__view_id__history_view__id');

  $$HistoryViewTableProcessedTableManager get viewId {
    final $_column = $_itemColumn<int>('view_id')!;

    final manager = $$HistoryViewTableTableManager($_db, $_db.historyView)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_viewIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$HistoryViewPeriodTableFilterComposer
    extends Composer<_$AppDatabase, $HistoryViewPeriodTable> {
  $$HistoryViewPeriodTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startAt => $composableBuilder(
      column: $table.startAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get endAt => $composableBuilder(
      column: $table.endAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$HistoryViewTableFilterComposer get viewId {
    final $$HistoryViewTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableFilterComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewPeriodTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoryViewPeriodTable> {
  $$HistoryViewPeriodTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startAt => $composableBuilder(
      column: $table.startAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get endAt => $composableBuilder(
      column: $table.endAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$HistoryViewTableOrderingComposer get viewId {
    final $$HistoryViewTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableOrderingComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewPeriodTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoryViewPeriodTable> {
  $$HistoryViewPeriodTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get startAt =>
      $composableBuilder(column: $table.startAt, builder: (column) => column);

  GeneratedColumn<DateTime> get endAt =>
      $composableBuilder(column: $table.endAt, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$HistoryViewTableAnnotationComposer get viewId {
    final $$HistoryViewTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.viewId,
        referencedTable: $db.historyView,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$HistoryViewTableAnnotationComposer(
              $db: $db,
              $table: $db.historyView,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$HistoryViewPeriodTableTableManager extends RootTableManager<
    _$AppDatabase,
    $HistoryViewPeriodTable,
    HistoryViewPeriodData,
    $$HistoryViewPeriodTableFilterComposer,
    $$HistoryViewPeriodTableOrderingComposer,
    $$HistoryViewPeriodTableAnnotationComposer,
    $$HistoryViewPeriodTableCreateCompanionBuilder,
    $$HistoryViewPeriodTableUpdateCompanionBuilder,
    (HistoryViewPeriodData, $$HistoryViewPeriodTableReferences),
    HistoryViewPeriodData,
    PrefetchHooks Function({bool viewId})> {
  $$HistoryViewPeriodTableTableManager(
      _$AppDatabase db, $HistoryViewPeriodTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryViewPeriodTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryViewPeriodTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryViewPeriodTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> viewId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<DateTime> startAt = const Value.absent(),
            Value<DateTime> endAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              HistoryViewPeriodCompanion(
            id: id,
            viewId: viewId,
            name: name,
            startAt: startAt,
            endAt: endAt,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int viewId,
            required String name,
            required DateTime startAt,
            required DateTime endAt,
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              HistoryViewPeriodCompanion.insert(
            id: id,
            viewId: viewId,
            name: name,
            startAt: startAt,
            endAt: endAt,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$HistoryViewPeriodTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({viewId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (viewId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.viewId,
                    referencedTable:
                        $$HistoryViewPeriodTableReferences._viewIdTable(db),
                    referencedColumn:
                        $$HistoryViewPeriodTableReferences._viewIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$HistoryViewPeriodTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $HistoryViewPeriodTable,
    HistoryViewPeriodData,
    $$HistoryViewPeriodTableFilterComposer,
    $$HistoryViewPeriodTableOrderingComposer,
    $$HistoryViewPeriodTableAnnotationComposer,
    $$HistoryViewPeriodTableCreateCompanionBuilder,
    $$HistoryViewPeriodTableUpdateCompanionBuilder,
    (HistoryViewPeriodData, $$HistoryViewPeriodTableReferences),
    HistoryViewPeriodData,
    PrefetchHooks Function({bool viewId})>;
typedef $$AuditLogTableCreateCompanionBuilder = AuditLogCompanion Function({
  Value<int> id,
  required String operatorId,
  required String tool,
  required String arguments,
  Value<String?> reasoning,
  required String status,
  Value<String?> error,
  required DateTime createdAt,
  Value<DateTime?> completedAt,
});
typedef $$AuditLogTableUpdateCompanionBuilder = AuditLogCompanion Function({
  Value<int> id,
  Value<String> operatorId,
  Value<String> tool,
  Value<String> arguments,
  Value<String?> reasoning,
  Value<String> status,
  Value<String?> error,
  Value<DateTime> createdAt,
  Value<DateTime?> completedAt,
});

class $$AuditLogTableFilterComposer
    extends Composer<_$AppDatabase, $AuditLogTable> {
  $$AuditLogTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get operatorId => $composableBuilder(
      column: $table.operatorId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tool => $composableBuilder(
      column: $table.tool, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get arguments => $composableBuilder(
      column: $table.arguments, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reasoning => $composableBuilder(
      column: $table.reasoning, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get error => $composableBuilder(
      column: $table.error, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnFilters(column));
}

class $$AuditLogTableOrderingComposer
    extends Composer<_$AppDatabase, $AuditLogTable> {
  $$AuditLogTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get operatorId => $composableBuilder(
      column: $table.operatorId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tool => $composableBuilder(
      column: $table.tool, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get arguments => $composableBuilder(
      column: $table.arguments, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reasoning => $composableBuilder(
      column: $table.reasoning, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get error => $composableBuilder(
      column: $table.error, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnOrderings(column));
}

class $$AuditLogTableAnnotationComposer
    extends Composer<_$AppDatabase, $AuditLogTable> {
  $$AuditLogTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get operatorId => $composableBuilder(
      column: $table.operatorId, builder: (column) => column);

  GeneratedColumn<String> get tool =>
      $composableBuilder(column: $table.tool, builder: (column) => column);

  GeneratedColumn<String> get arguments =>
      $composableBuilder(column: $table.arguments, builder: (column) => column);

  GeneratedColumn<String> get reasoning =>
      $composableBuilder(column: $table.reasoning, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => column);
}

class $$AuditLogTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AuditLogTable,
    AuditLogData,
    $$AuditLogTableFilterComposer,
    $$AuditLogTableOrderingComposer,
    $$AuditLogTableAnnotationComposer,
    $$AuditLogTableCreateCompanionBuilder,
    $$AuditLogTableUpdateCompanionBuilder,
    (AuditLogData, BaseReferences<_$AppDatabase, $AuditLogTable, AuditLogData>),
    AuditLogData,
    PrefetchHooks Function()> {
  $$AuditLogTableTableManager(_$AppDatabase db, $AuditLogTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AuditLogTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AuditLogTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AuditLogTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> operatorId = const Value.absent(),
            Value<String> tool = const Value.absent(),
            Value<String> arguments = const Value.absent(),
            Value<String?> reasoning = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String?> error = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> completedAt = const Value.absent(),
          }) =>
              AuditLogCompanion(
            id: id,
            operatorId: operatorId,
            tool: tool,
            arguments: arguments,
            reasoning: reasoning,
            status: status,
            error: error,
            createdAt: createdAt,
            completedAt: completedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String operatorId,
            required String tool,
            required String arguments,
            Value<String?> reasoning = const Value.absent(),
            required String status,
            Value<String?> error = const Value.absent(),
            required DateTime createdAt,
            Value<DateTime?> completedAt = const Value.absent(),
          }) =>
              AuditLogCompanion.insert(
            id: id,
            operatorId: operatorId,
            tool: tool,
            arguments: arguments,
            reasoning: reasoning,
            status: status,
            error: error,
            createdAt: createdAt,
            completedAt: completedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AuditLogTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AuditLogTable,
    AuditLogData,
    $$AuditLogTableFilterComposer,
    $$AuditLogTableOrderingComposer,
    $$AuditLogTableAnnotationComposer,
    $$AuditLogTableCreateCompanionBuilder,
    $$AuditLogTableUpdateCompanionBuilder,
    (AuditLogData, BaseReferences<_$AppDatabase, $AuditLogTable, AuditLogData>),
    AuditLogData,
    PrefetchHooks Function()>;
typedef $$PlcCodeBlockTableTableCreateCompanionBuilder
    = PlcCodeBlockTableCompanion Function({
  Value<int> id,
  required String assetKey,
  required String blockName,
  required String blockType,
  required String filePath,
  required String declaration,
  Value<String?> implementation,
  required String fullSource,
  Value<int?> parentBlockId,
  required DateTime indexedAt,
  Value<String?> vendorType,
  Value<String?> serverAlias,
});
typedef $$PlcCodeBlockTableTableUpdateCompanionBuilder
    = PlcCodeBlockTableCompanion Function({
  Value<int> id,
  Value<String> assetKey,
  Value<String> blockName,
  Value<String> blockType,
  Value<String> filePath,
  Value<String> declaration,
  Value<String?> implementation,
  Value<String> fullSource,
  Value<int?> parentBlockId,
  Value<DateTime> indexedAt,
  Value<String?> vendorType,
  Value<String?> serverAlias,
});

final class $$PlcCodeBlockTableTableReferences extends BaseReferences<
    _$AppDatabase, $PlcCodeBlockTableTable, PlcCodeBlockTableData> {
  $$PlcCodeBlockTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$PlcVariableTableTable, List<PlcVariableTableData>>
      _plcVariableTableRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.plcVariableTable,
              aliasName: 'plc_code_block__id__plc_variable__block_id');

  $$PlcVariableTableTableProcessedTableManager get plcVariableTableRefs {
    final manager =
        $$PlcVariableTableTableTableManager($_db, $_db.plcVariableTable)
            .filter((f) => f.blockId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_plcVariableTableRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$PlcVarRefTableTable, List<PlcVarRefTableData>>
      _plcVarRefTableRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.plcVarRefTable,
              aliasName: 'plc_code_block__id__plc_var_ref__block_id');

  $$PlcVarRefTableTableProcessedTableManager get plcVarRefTableRefs {
    final manager = $$PlcVarRefTableTableTableManager($_db, $_db.plcVarRefTable)
        .filter((f) => f.blockId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_plcVarRefTableRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$PlcFbInstanceTableTable,
      List<PlcFbInstanceTableData>> _plcFbInstanceTableRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.plcFbInstanceTable,
          aliasName: 'plc_code_block__id__plc_fb_instance__declaring_block_id');

  $$PlcFbInstanceTableTableProcessedTableManager get plcFbInstanceTableRefs {
    final manager = $$PlcFbInstanceTableTableTableManager(
            $_db, $_db.plcFbInstanceTable)
        .filter(
            (f) => f.declaringBlockId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_plcFbInstanceTableRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$PlcBlockCallTableTable,
      List<PlcBlockCallTableData>> _plcBlockCallTableRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.plcBlockCallTable,
          aliasName: 'plc_code_block__id__plc_block_call__caller_block_id');

  $$PlcBlockCallTableTableProcessedTableManager get plcBlockCallTableRefs {
    final manager = $$PlcBlockCallTableTableTableManager(
            $_db, $_db.plcBlockCallTable)
        .filter((f) => f.callerBlockId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_plcBlockCallTableRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$PlcCodeBlockTableTableFilterComposer
    extends Composer<_$AppDatabase, $PlcCodeBlockTableTable> {
  $$PlcCodeBlockTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get assetKey => $composableBuilder(
      column: $table.assetKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get blockName => $composableBuilder(
      column: $table.blockName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get blockType => $composableBuilder(
      column: $table.blockType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get declaration => $composableBuilder(
      column: $table.declaration, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get implementation => $composableBuilder(
      column: $table.implementation,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fullSource => $composableBuilder(
      column: $table.fullSource, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get parentBlockId => $composableBuilder(
      column: $table.parentBlockId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get indexedAt => $composableBuilder(
      column: $table.indexedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get vendorType => $composableBuilder(
      column: $table.vendorType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get serverAlias => $composableBuilder(
      column: $table.serverAlias, builder: (column) => ColumnFilters(column));

  Expression<bool> plcVariableTableRefs(
      Expression<bool> Function($$PlcVariableTableTableFilterComposer f) f) {
    final $$PlcVariableTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.plcVariableTable,
        getReferencedColumn: (t) => t.blockId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcVariableTableTableFilterComposer(
              $db: $db,
              $table: $db.plcVariableTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> plcVarRefTableRefs(
      Expression<bool> Function($$PlcVarRefTableTableFilterComposer f) f) {
    final $$PlcVarRefTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.plcVarRefTable,
        getReferencedColumn: (t) => t.blockId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcVarRefTableTableFilterComposer(
              $db: $db,
              $table: $db.plcVarRefTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> plcFbInstanceTableRefs(
      Expression<bool> Function($$PlcFbInstanceTableTableFilterComposer f) f) {
    final $$PlcFbInstanceTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.plcFbInstanceTable,
        getReferencedColumn: (t) => t.declaringBlockId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcFbInstanceTableTableFilterComposer(
              $db: $db,
              $table: $db.plcFbInstanceTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> plcBlockCallTableRefs(
      Expression<bool> Function($$PlcBlockCallTableTableFilterComposer f) f) {
    final $$PlcBlockCallTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.plcBlockCallTable,
        getReferencedColumn: (t) => t.callerBlockId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcBlockCallTableTableFilterComposer(
              $db: $db,
              $table: $db.plcBlockCallTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$PlcCodeBlockTableTableOrderingComposer
    extends Composer<_$AppDatabase, $PlcCodeBlockTableTable> {
  $$PlcCodeBlockTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get assetKey => $composableBuilder(
      column: $table.assetKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get blockName => $composableBuilder(
      column: $table.blockName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get blockType => $composableBuilder(
      column: $table.blockType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get declaration => $composableBuilder(
      column: $table.declaration, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get implementation => $composableBuilder(
      column: $table.implementation,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fullSource => $composableBuilder(
      column: $table.fullSource, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get parentBlockId => $composableBuilder(
      column: $table.parentBlockId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get indexedAt => $composableBuilder(
      column: $table.indexedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get vendorType => $composableBuilder(
      column: $table.vendorType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get serverAlias => $composableBuilder(
      column: $table.serverAlias, builder: (column) => ColumnOrderings(column));
}

class $$PlcCodeBlockTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlcCodeBlockTableTable> {
  $$PlcCodeBlockTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get assetKey =>
      $composableBuilder(column: $table.assetKey, builder: (column) => column);

  GeneratedColumn<String> get blockName =>
      $composableBuilder(column: $table.blockName, builder: (column) => column);

  GeneratedColumn<String> get blockType =>
      $composableBuilder(column: $table.blockType, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<String> get declaration => $composableBuilder(
      column: $table.declaration, builder: (column) => column);

  GeneratedColumn<String> get implementation => $composableBuilder(
      column: $table.implementation, builder: (column) => column);

  GeneratedColumn<String> get fullSource => $composableBuilder(
      column: $table.fullSource, builder: (column) => column);

  GeneratedColumn<int> get parentBlockId => $composableBuilder(
      column: $table.parentBlockId, builder: (column) => column);

  GeneratedColumn<DateTime> get indexedAt =>
      $composableBuilder(column: $table.indexedAt, builder: (column) => column);

  GeneratedColumn<String> get vendorType => $composableBuilder(
      column: $table.vendorType, builder: (column) => column);

  GeneratedColumn<String> get serverAlias => $composableBuilder(
      column: $table.serverAlias, builder: (column) => column);

  Expression<T> plcVariableTableRefs<T extends Object>(
      Expression<T> Function($$PlcVariableTableTableAnnotationComposer a) f) {
    final $$PlcVariableTableTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.plcVariableTable,
        getReferencedColumn: (t) => t.blockId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcVariableTableTableAnnotationComposer(
              $db: $db,
              $table: $db.plcVariableTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> plcVarRefTableRefs<T extends Object>(
      Expression<T> Function($$PlcVarRefTableTableAnnotationComposer a) f) {
    final $$PlcVarRefTableTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.plcVarRefTable,
        getReferencedColumn: (t) => t.blockId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcVarRefTableTableAnnotationComposer(
              $db: $db,
              $table: $db.plcVarRefTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> plcFbInstanceTableRefs<T extends Object>(
      Expression<T> Function($$PlcFbInstanceTableTableAnnotationComposer a) f) {
    final $$PlcFbInstanceTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.plcFbInstanceTable,
            getReferencedColumn: (t) => t.declaringBlockId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$PlcFbInstanceTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.plcFbInstanceTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> plcBlockCallTableRefs<T extends Object>(
      Expression<T> Function($$PlcBlockCallTableTableAnnotationComposer a) f) {
    final $$PlcBlockCallTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.plcBlockCallTable,
            getReferencedColumn: (t) => t.callerBlockId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$PlcBlockCallTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.plcBlockCallTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$PlcCodeBlockTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PlcCodeBlockTableTable,
    PlcCodeBlockTableData,
    $$PlcCodeBlockTableTableFilterComposer,
    $$PlcCodeBlockTableTableOrderingComposer,
    $$PlcCodeBlockTableTableAnnotationComposer,
    $$PlcCodeBlockTableTableCreateCompanionBuilder,
    $$PlcCodeBlockTableTableUpdateCompanionBuilder,
    (PlcCodeBlockTableData, $$PlcCodeBlockTableTableReferences),
    PlcCodeBlockTableData,
    PrefetchHooks Function(
        {bool plcVariableTableRefs,
        bool plcVarRefTableRefs,
        bool plcFbInstanceTableRefs,
        bool plcBlockCallTableRefs})> {
  $$PlcCodeBlockTableTableTableManager(
      _$AppDatabase db, $PlcCodeBlockTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlcCodeBlockTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlcCodeBlockTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlcCodeBlockTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> assetKey = const Value.absent(),
            Value<String> blockName = const Value.absent(),
            Value<String> blockType = const Value.absent(),
            Value<String> filePath = const Value.absent(),
            Value<String> declaration = const Value.absent(),
            Value<String?> implementation = const Value.absent(),
            Value<String> fullSource = const Value.absent(),
            Value<int?> parentBlockId = const Value.absent(),
            Value<DateTime> indexedAt = const Value.absent(),
            Value<String?> vendorType = const Value.absent(),
            Value<String?> serverAlias = const Value.absent(),
          }) =>
              PlcCodeBlockTableCompanion(
            id: id,
            assetKey: assetKey,
            blockName: blockName,
            blockType: blockType,
            filePath: filePath,
            declaration: declaration,
            implementation: implementation,
            fullSource: fullSource,
            parentBlockId: parentBlockId,
            indexedAt: indexedAt,
            vendorType: vendorType,
            serverAlias: serverAlias,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String assetKey,
            required String blockName,
            required String blockType,
            required String filePath,
            required String declaration,
            Value<String?> implementation = const Value.absent(),
            required String fullSource,
            Value<int?> parentBlockId = const Value.absent(),
            required DateTime indexedAt,
            Value<String?> vendorType = const Value.absent(),
            Value<String?> serverAlias = const Value.absent(),
          }) =>
              PlcCodeBlockTableCompanion.insert(
            id: id,
            assetKey: assetKey,
            blockName: blockName,
            blockType: blockType,
            filePath: filePath,
            declaration: declaration,
            implementation: implementation,
            fullSource: fullSource,
            parentBlockId: parentBlockId,
            indexedAt: indexedAt,
            vendorType: vendorType,
            serverAlias: serverAlias,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PlcCodeBlockTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {plcVariableTableRefs = false,
              plcVarRefTableRefs = false,
              plcFbInstanceTableRefs = false,
              plcBlockCallTableRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (plcVariableTableRefs) db.plcVariableTable,
                if (plcVarRefTableRefs) db.plcVarRefTable,
                if (plcFbInstanceTableRefs) db.plcFbInstanceTable,
                if (plcBlockCallTableRefs) db.plcBlockCallTable
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (plcVariableTableRefs)
                    await $_getPrefetchedData<PlcCodeBlockTableData,
                            $PlcCodeBlockTableTable, PlcVariableTableData>(
                        currentTable: table,
                        referencedTable: $$PlcCodeBlockTableTableReferences
                            ._plcVariableTableRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PlcCodeBlockTableTableReferences(db, table, p0)
                                .plcVariableTableRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.blockId == item.id),
                        typedResults: items),
                  if (plcVarRefTableRefs)
                    await $_getPrefetchedData<PlcCodeBlockTableData,
                            $PlcCodeBlockTableTable, PlcVarRefTableData>(
                        currentTable: table,
                        referencedTable: $$PlcCodeBlockTableTableReferences
                            ._plcVarRefTableRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PlcCodeBlockTableTableReferences(db, table, p0)
                                .plcVarRefTableRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.blockId == item.id),
                        typedResults: items),
                  if (plcFbInstanceTableRefs)
                    await $_getPrefetchedData<PlcCodeBlockTableData,
                            $PlcCodeBlockTableTable, PlcFbInstanceTableData>(
                        currentTable: table,
                        referencedTable: $$PlcCodeBlockTableTableReferences
                            ._plcFbInstanceTableRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PlcCodeBlockTableTableReferences(db, table, p0)
                                .plcFbInstanceTableRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.declaringBlockId == item.id),
                        typedResults: items),
                  if (plcBlockCallTableRefs)
                    await $_getPrefetchedData<PlcCodeBlockTableData,
                            $PlcCodeBlockTableTable, PlcBlockCallTableData>(
                        currentTable: table,
                        referencedTable: $$PlcCodeBlockTableTableReferences
                            ._plcBlockCallTableRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$PlcCodeBlockTableTableReferences(db, table, p0)
                                .plcBlockCallTableRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.callerBlockId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$PlcCodeBlockTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PlcCodeBlockTableTable,
    PlcCodeBlockTableData,
    $$PlcCodeBlockTableTableFilterComposer,
    $$PlcCodeBlockTableTableOrderingComposer,
    $$PlcCodeBlockTableTableAnnotationComposer,
    $$PlcCodeBlockTableTableCreateCompanionBuilder,
    $$PlcCodeBlockTableTableUpdateCompanionBuilder,
    (PlcCodeBlockTableData, $$PlcCodeBlockTableTableReferences),
    PlcCodeBlockTableData,
    PrefetchHooks Function(
        {bool plcVariableTableRefs,
        bool plcVarRefTableRefs,
        bool plcFbInstanceTableRefs,
        bool plcBlockCallTableRefs})>;
typedef $$PlcVariableTableTableCreateCompanionBuilder
    = PlcVariableTableCompanion Function({
  Value<int> id,
  required int blockId,
  required String variableName,
  required String variableType,
  required String section,
  required String qualifiedName,
  Value<String?> comment,
});
typedef $$PlcVariableTableTableUpdateCompanionBuilder
    = PlcVariableTableCompanion Function({
  Value<int> id,
  Value<int> blockId,
  Value<String> variableName,
  Value<String> variableType,
  Value<String> section,
  Value<String> qualifiedName,
  Value<String?> comment,
});

final class $$PlcVariableTableTableReferences extends BaseReferences<
    _$AppDatabase, $PlcVariableTableTable, PlcVariableTableData> {
  $$PlcVariableTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $PlcCodeBlockTableTable _blockIdTable(_$AppDatabase db) =>
      db.plcCodeBlockTable
          .createAlias('plc_variable__block_id__plc_code_block__id');

  $$PlcCodeBlockTableTableProcessedTableManager get blockId {
    final $_column = $_itemColumn<int>('block_id')!;

    final manager =
        $$PlcCodeBlockTableTableTableManager($_db, $_db.plcCodeBlockTable)
            .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_blockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$PlcVariableTableTableFilterComposer
    extends Composer<_$AppDatabase, $PlcVariableTableTable> {
  $$PlcVariableTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get variableName => $composableBuilder(
      column: $table.variableName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get variableType => $composableBuilder(
      column: $table.variableType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get section => $composableBuilder(
      column: $table.section, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get qualifiedName => $composableBuilder(
      column: $table.qualifiedName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get comment => $composableBuilder(
      column: $table.comment, builder: (column) => ColumnFilters(column));

  $$PlcCodeBlockTableTableFilterComposer get blockId {
    final $$PlcCodeBlockTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.blockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableFilterComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcVariableTableTableOrderingComposer
    extends Composer<_$AppDatabase, $PlcVariableTableTable> {
  $$PlcVariableTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get variableName => $composableBuilder(
      column: $table.variableName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get variableType => $composableBuilder(
      column: $table.variableType,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get section => $composableBuilder(
      column: $table.section, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get qualifiedName => $composableBuilder(
      column: $table.qualifiedName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get comment => $composableBuilder(
      column: $table.comment, builder: (column) => ColumnOrderings(column));

  $$PlcCodeBlockTableTableOrderingComposer get blockId {
    final $$PlcCodeBlockTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.blockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableOrderingComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcVariableTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlcVariableTableTable> {
  $$PlcVariableTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get variableName => $composableBuilder(
      column: $table.variableName, builder: (column) => column);

  GeneratedColumn<String> get variableType => $composableBuilder(
      column: $table.variableType, builder: (column) => column);

  GeneratedColumn<String> get section =>
      $composableBuilder(column: $table.section, builder: (column) => column);

  GeneratedColumn<String> get qualifiedName => $composableBuilder(
      column: $table.qualifiedName, builder: (column) => column);

  GeneratedColumn<String> get comment =>
      $composableBuilder(column: $table.comment, builder: (column) => column);

  $$PlcCodeBlockTableTableAnnotationComposer get blockId {
    final $$PlcCodeBlockTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.blockId,
            referencedTable: $db.plcCodeBlockTable,
            getReferencedColumn: (t) => t.id,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$PlcCodeBlockTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.plcCodeBlockTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return composer;
  }
}

class $$PlcVariableTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PlcVariableTableTable,
    PlcVariableTableData,
    $$PlcVariableTableTableFilterComposer,
    $$PlcVariableTableTableOrderingComposer,
    $$PlcVariableTableTableAnnotationComposer,
    $$PlcVariableTableTableCreateCompanionBuilder,
    $$PlcVariableTableTableUpdateCompanionBuilder,
    (PlcVariableTableData, $$PlcVariableTableTableReferences),
    PlcVariableTableData,
    PrefetchHooks Function({bool blockId})> {
  $$PlcVariableTableTableTableManager(
      _$AppDatabase db, $PlcVariableTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlcVariableTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlcVariableTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlcVariableTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> blockId = const Value.absent(),
            Value<String> variableName = const Value.absent(),
            Value<String> variableType = const Value.absent(),
            Value<String> section = const Value.absent(),
            Value<String> qualifiedName = const Value.absent(),
            Value<String?> comment = const Value.absent(),
          }) =>
              PlcVariableTableCompanion(
            id: id,
            blockId: blockId,
            variableName: variableName,
            variableType: variableType,
            section: section,
            qualifiedName: qualifiedName,
            comment: comment,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int blockId,
            required String variableName,
            required String variableType,
            required String section,
            required String qualifiedName,
            Value<String?> comment = const Value.absent(),
          }) =>
              PlcVariableTableCompanion.insert(
            id: id,
            blockId: blockId,
            variableName: variableName,
            variableType: variableType,
            section: section,
            qualifiedName: qualifiedName,
            comment: comment,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PlcVariableTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({blockId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (blockId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.blockId,
                    referencedTable:
                        $$PlcVariableTableTableReferences._blockIdTable(db),
                    referencedColumn:
                        $$PlcVariableTableTableReferences._blockIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PlcVariableTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PlcVariableTableTable,
    PlcVariableTableData,
    $$PlcVariableTableTableFilterComposer,
    $$PlcVariableTableTableOrderingComposer,
    $$PlcVariableTableTableAnnotationComposer,
    $$PlcVariableTableTableCreateCompanionBuilder,
    $$PlcVariableTableTableUpdateCompanionBuilder,
    (PlcVariableTableData, $$PlcVariableTableTableReferences),
    PlcVariableTableData,
    PrefetchHooks Function({bool blockId})>;
typedef $$DrawingTableTableCreateCompanionBuilder = DrawingTableCompanion
    Function({
  Value<int> id,
  required String assetKey,
  required String drawingName,
  required String filePath,
  required int pageCount,
  required DateTime uploadedAt,
  Value<Uint8List?> pdfBytes,
});
typedef $$DrawingTableTableUpdateCompanionBuilder = DrawingTableCompanion
    Function({
  Value<int> id,
  Value<String> assetKey,
  Value<String> drawingName,
  Value<String> filePath,
  Value<int> pageCount,
  Value<DateTime> uploadedAt,
  Value<Uint8List?> pdfBytes,
});

final class $$DrawingTableTableReferences extends BaseReferences<_$AppDatabase,
    $DrawingTableTable, DrawingTableData> {
  $$DrawingTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$DrawingComponentTableTable,
      List<DrawingComponentTableData>> _drawingComponentTableRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.drawingComponentTable,
          aliasName: 'drawing__id__drawing_component__drawing_id');

  $$DrawingComponentTableTableProcessedTableManager
      get drawingComponentTableRefs {
    final manager = $$DrawingComponentTableTableTableManager(
            $_db, $_db.drawingComponentTable)
        .filter((f) => f.drawingId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_drawingComponentTableRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$DrawingTableTableFilterComposer
    extends Composer<_$AppDatabase, $DrawingTableTable> {
  $$DrawingTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get assetKey => $composableBuilder(
      column: $table.assetKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get drawingName => $composableBuilder(
      column: $table.drawingName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageCount => $composableBuilder(
      column: $table.pageCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get uploadedAt => $composableBuilder(
      column: $table.uploadedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get pdfBytes => $composableBuilder(
      column: $table.pdfBytes, builder: (column) => ColumnFilters(column));

  Expression<bool> drawingComponentTableRefs(
      Expression<bool> Function($$DrawingComponentTableTableFilterComposer f)
          f) {
    final $$DrawingComponentTableTableFilterComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.drawingComponentTable,
            getReferencedColumn: (t) => t.drawingId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$DrawingComponentTableTableFilterComposer(
                  $db: $db,
                  $table: $db.drawingComponentTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$DrawingTableTableOrderingComposer
    extends Composer<_$AppDatabase, $DrawingTableTable> {
  $$DrawingTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get assetKey => $composableBuilder(
      column: $table.assetKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get drawingName => $composableBuilder(
      column: $table.drawingName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageCount => $composableBuilder(
      column: $table.pageCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get uploadedAt => $composableBuilder(
      column: $table.uploadedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get pdfBytes => $composableBuilder(
      column: $table.pdfBytes, builder: (column) => ColumnOrderings(column));
}

class $$DrawingTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $DrawingTableTable> {
  $$DrawingTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get assetKey =>
      $composableBuilder(column: $table.assetKey, builder: (column) => column);

  GeneratedColumn<String> get drawingName => $composableBuilder(
      column: $table.drawingName, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<int> get pageCount =>
      $composableBuilder(column: $table.pageCount, builder: (column) => column);

  GeneratedColumn<DateTime> get uploadedAt => $composableBuilder(
      column: $table.uploadedAt, builder: (column) => column);

  GeneratedColumn<Uint8List> get pdfBytes =>
      $composableBuilder(column: $table.pdfBytes, builder: (column) => column);

  Expression<T> drawingComponentTableRefs<T extends Object>(
      Expression<T> Function($$DrawingComponentTableTableAnnotationComposer a)
          f) {
    final $$DrawingComponentTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.drawingComponentTable,
            getReferencedColumn: (t) => t.drawingId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$DrawingComponentTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.drawingComponentTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$DrawingTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DrawingTableTable,
    DrawingTableData,
    $$DrawingTableTableFilterComposer,
    $$DrawingTableTableOrderingComposer,
    $$DrawingTableTableAnnotationComposer,
    $$DrawingTableTableCreateCompanionBuilder,
    $$DrawingTableTableUpdateCompanionBuilder,
    (DrawingTableData, $$DrawingTableTableReferences),
    DrawingTableData,
    PrefetchHooks Function({bool drawingComponentTableRefs})> {
  $$DrawingTableTableTableManager(_$AppDatabase db, $DrawingTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DrawingTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DrawingTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DrawingTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> assetKey = const Value.absent(),
            Value<String> drawingName = const Value.absent(),
            Value<String> filePath = const Value.absent(),
            Value<int> pageCount = const Value.absent(),
            Value<DateTime> uploadedAt = const Value.absent(),
            Value<Uint8List?> pdfBytes = const Value.absent(),
          }) =>
              DrawingTableCompanion(
            id: id,
            assetKey: assetKey,
            drawingName: drawingName,
            filePath: filePath,
            pageCount: pageCount,
            uploadedAt: uploadedAt,
            pdfBytes: pdfBytes,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String assetKey,
            required String drawingName,
            required String filePath,
            required int pageCount,
            required DateTime uploadedAt,
            Value<Uint8List?> pdfBytes = const Value.absent(),
          }) =>
              DrawingTableCompanion.insert(
            id: id,
            assetKey: assetKey,
            drawingName: drawingName,
            filePath: filePath,
            pageCount: pageCount,
            uploadedAt: uploadedAt,
            pdfBytes: pdfBytes,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$DrawingTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({drawingComponentTableRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (drawingComponentTableRefs) db.drawingComponentTable
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (drawingComponentTableRefs)
                    await $_getPrefetchedData<DrawingTableData,
                            $DrawingTableTable, DrawingComponentTableData>(
                        currentTable: table,
                        referencedTable: $$DrawingTableTableReferences
                            ._drawingComponentTableRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$DrawingTableTableReferences(db, table, p0)
                                .drawingComponentTableRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.drawingId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$DrawingTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DrawingTableTable,
    DrawingTableData,
    $$DrawingTableTableFilterComposer,
    $$DrawingTableTableOrderingComposer,
    $$DrawingTableTableAnnotationComposer,
    $$DrawingTableTableCreateCompanionBuilder,
    $$DrawingTableTableUpdateCompanionBuilder,
    (DrawingTableData, $$DrawingTableTableReferences),
    DrawingTableData,
    PrefetchHooks Function({bool drawingComponentTableRefs})>;
typedef $$DrawingComponentTableTableCreateCompanionBuilder
    = DrawingComponentTableCompanion Function({
  Value<int> id,
  required int drawingId,
  required int pageNumber,
  required String fullPageText,
});
typedef $$DrawingComponentTableTableUpdateCompanionBuilder
    = DrawingComponentTableCompanion Function({
  Value<int> id,
  Value<int> drawingId,
  Value<int> pageNumber,
  Value<String> fullPageText,
});

final class $$DrawingComponentTableTableReferences extends BaseReferences<
    _$AppDatabase, $DrawingComponentTableTable, DrawingComponentTableData> {
  $$DrawingComponentTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $DrawingTableTable _drawingIdTable(_$AppDatabase db) =>
      db.drawingTable.createAlias('drawing_component__drawing_id__drawing__id');

  $$DrawingTableTableProcessedTableManager get drawingId {
    final $_column = $_itemColumn<int>('drawing_id')!;

    final manager = $$DrawingTableTableTableManager($_db, $_db.drawingTable)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_drawingIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$DrawingComponentTableTableFilterComposer
    extends Composer<_$AppDatabase, $DrawingComponentTableTable> {
  $$DrawingComponentTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageNumber => $composableBuilder(
      column: $table.pageNumber, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fullPageText => $composableBuilder(
      column: $table.fullPageText, builder: (column) => ColumnFilters(column));

  $$DrawingTableTableFilterComposer get drawingId {
    final $$DrawingTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.drawingId,
        referencedTable: $db.drawingTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DrawingTableTableFilterComposer(
              $db: $db,
              $table: $db.drawingTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$DrawingComponentTableTableOrderingComposer
    extends Composer<_$AppDatabase, $DrawingComponentTableTable> {
  $$DrawingComponentTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageNumber => $composableBuilder(
      column: $table.pageNumber, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fullPageText => $composableBuilder(
      column: $table.fullPageText,
      builder: (column) => ColumnOrderings(column));

  $$DrawingTableTableOrderingComposer get drawingId {
    final $$DrawingTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.drawingId,
        referencedTable: $db.drawingTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DrawingTableTableOrderingComposer(
              $db: $db,
              $table: $db.drawingTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$DrawingComponentTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $DrawingComponentTableTable> {
  $$DrawingComponentTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get pageNumber => $composableBuilder(
      column: $table.pageNumber, builder: (column) => column);

  GeneratedColumn<String> get fullPageText => $composableBuilder(
      column: $table.fullPageText, builder: (column) => column);

  $$DrawingTableTableAnnotationComposer get drawingId {
    final $$DrawingTableTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.drawingId,
        referencedTable: $db.drawingTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DrawingTableTableAnnotationComposer(
              $db: $db,
              $table: $db.drawingTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$DrawingComponentTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DrawingComponentTableTable,
    DrawingComponentTableData,
    $$DrawingComponentTableTableFilterComposer,
    $$DrawingComponentTableTableOrderingComposer,
    $$DrawingComponentTableTableAnnotationComposer,
    $$DrawingComponentTableTableCreateCompanionBuilder,
    $$DrawingComponentTableTableUpdateCompanionBuilder,
    (DrawingComponentTableData, $$DrawingComponentTableTableReferences),
    DrawingComponentTableData,
    PrefetchHooks Function({bool drawingId})> {
  $$DrawingComponentTableTableTableManager(
      _$AppDatabase db, $DrawingComponentTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DrawingComponentTableTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$DrawingComponentTableTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DrawingComponentTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> drawingId = const Value.absent(),
            Value<int> pageNumber = const Value.absent(),
            Value<String> fullPageText = const Value.absent(),
          }) =>
              DrawingComponentTableCompanion(
            id: id,
            drawingId: drawingId,
            pageNumber: pageNumber,
            fullPageText: fullPageText,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int drawingId,
            required int pageNumber,
            required String fullPageText,
          }) =>
              DrawingComponentTableCompanion.insert(
            id: id,
            drawingId: drawingId,
            pageNumber: pageNumber,
            fullPageText: fullPageText,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$DrawingComponentTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({drawingId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (drawingId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.drawingId,
                    referencedTable: $$DrawingComponentTableTableReferences
                        ._drawingIdTable(db),
                    referencedColumn: $$DrawingComponentTableTableReferences
                        ._drawingIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$DrawingComponentTableTableProcessedTableManager
    = ProcessedTableManager<
        _$AppDatabase,
        $DrawingComponentTableTable,
        DrawingComponentTableData,
        $$DrawingComponentTableTableFilterComposer,
        $$DrawingComponentTableTableOrderingComposer,
        $$DrawingComponentTableTableAnnotationComposer,
        $$DrawingComponentTableTableCreateCompanionBuilder,
        $$DrawingComponentTableTableUpdateCompanionBuilder,
        (DrawingComponentTableData, $$DrawingComponentTableTableReferences),
        DrawingComponentTableData,
        PrefetchHooks Function({bool drawingId})>;
typedef $$TechDocTableTableCreateCompanionBuilder = TechDocTableCompanion
    Function({
  Value<int> id,
  required String name,
  required Uint8List pdfBytes,
  required int pageCount,
  required int sectionCount,
  required DateTime uploadedAt,
});
typedef $$TechDocTableTableUpdateCompanionBuilder = TechDocTableCompanion
    Function({
  Value<int> id,
  Value<String> name,
  Value<Uint8List> pdfBytes,
  Value<int> pageCount,
  Value<int> sectionCount,
  Value<DateTime> uploadedAt,
});

final class $$TechDocTableTableReferences extends BaseReferences<_$AppDatabase,
    $TechDocTableTable, TechDocTableData> {
  $$TechDocTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$TechDocSectionTableTable,
      List<TechDocSectionTableData>> _techDocSectionTableRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.techDocSectionTable,
          aliasName: 'tech_doc__id__tech_doc_section__doc_id');

  $$TechDocSectionTableTableProcessedTableManager get techDocSectionTableRefs {
    final manager =
        $$TechDocSectionTableTableTableManager($_db, $_db.techDocSectionTable)
            .filter((f) => f.docId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_techDocSectionTableRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$TechDocTableTableFilterComposer
    extends Composer<_$AppDatabase, $TechDocTableTable> {
  $$TechDocTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get pdfBytes => $composableBuilder(
      column: $table.pdfBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageCount => $composableBuilder(
      column: $table.pageCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sectionCount => $composableBuilder(
      column: $table.sectionCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get uploadedAt => $composableBuilder(
      column: $table.uploadedAt, builder: (column) => ColumnFilters(column));

  Expression<bool> techDocSectionTableRefs(
      Expression<bool> Function($$TechDocSectionTableTableFilterComposer f) f) {
    final $$TechDocSectionTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.techDocSectionTable,
        getReferencedColumn: (t) => t.docId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TechDocSectionTableTableFilterComposer(
              $db: $db,
              $table: $db.techDocSectionTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$TechDocTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TechDocTableTable> {
  $$TechDocTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get pdfBytes => $composableBuilder(
      column: $table.pdfBytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageCount => $composableBuilder(
      column: $table.pageCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sectionCount => $composableBuilder(
      column: $table.sectionCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get uploadedAt => $composableBuilder(
      column: $table.uploadedAt, builder: (column) => ColumnOrderings(column));
}

class $$TechDocTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TechDocTableTable> {
  $$TechDocTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<Uint8List> get pdfBytes =>
      $composableBuilder(column: $table.pdfBytes, builder: (column) => column);

  GeneratedColumn<int> get pageCount =>
      $composableBuilder(column: $table.pageCount, builder: (column) => column);

  GeneratedColumn<int> get sectionCount => $composableBuilder(
      column: $table.sectionCount, builder: (column) => column);

  GeneratedColumn<DateTime> get uploadedAt => $composableBuilder(
      column: $table.uploadedAt, builder: (column) => column);

  Expression<T> techDocSectionTableRefs<T extends Object>(
      Expression<T> Function($$TechDocSectionTableTableAnnotationComposer a)
          f) {
    final $$TechDocSectionTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.techDocSectionTable,
            getReferencedColumn: (t) => t.docId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$TechDocSectionTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.techDocSectionTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$TechDocTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $TechDocTableTable,
    TechDocTableData,
    $$TechDocTableTableFilterComposer,
    $$TechDocTableTableOrderingComposer,
    $$TechDocTableTableAnnotationComposer,
    $$TechDocTableTableCreateCompanionBuilder,
    $$TechDocTableTableUpdateCompanionBuilder,
    (TechDocTableData, $$TechDocTableTableReferences),
    TechDocTableData,
    PrefetchHooks Function({bool techDocSectionTableRefs})> {
  $$TechDocTableTableTableManager(_$AppDatabase db, $TechDocTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TechDocTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TechDocTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TechDocTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<Uint8List> pdfBytes = const Value.absent(),
            Value<int> pageCount = const Value.absent(),
            Value<int> sectionCount = const Value.absent(),
            Value<DateTime> uploadedAt = const Value.absent(),
          }) =>
              TechDocTableCompanion(
            id: id,
            name: name,
            pdfBytes: pdfBytes,
            pageCount: pageCount,
            sectionCount: sectionCount,
            uploadedAt: uploadedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            required Uint8List pdfBytes,
            required int pageCount,
            required int sectionCount,
            required DateTime uploadedAt,
          }) =>
              TechDocTableCompanion.insert(
            id: id,
            name: name,
            pdfBytes: pdfBytes,
            pageCount: pageCount,
            sectionCount: sectionCount,
            uploadedAt: uploadedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$TechDocTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({techDocSectionTableRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (techDocSectionTableRefs) db.techDocSectionTable
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (techDocSectionTableRefs)
                    await $_getPrefetchedData<TechDocTableData,
                            $TechDocTableTable, TechDocSectionTableData>(
                        currentTable: table,
                        referencedTable: $$TechDocTableTableReferences
                            ._techDocSectionTableRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$TechDocTableTableReferences(db, table, p0)
                                .techDocSectionTableRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.docId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$TechDocTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $TechDocTableTable,
    TechDocTableData,
    $$TechDocTableTableFilterComposer,
    $$TechDocTableTableOrderingComposer,
    $$TechDocTableTableAnnotationComposer,
    $$TechDocTableTableCreateCompanionBuilder,
    $$TechDocTableTableUpdateCompanionBuilder,
    (TechDocTableData, $$TechDocTableTableReferences),
    TechDocTableData,
    PrefetchHooks Function({bool techDocSectionTableRefs})>;
typedef $$TechDocSectionTableTableCreateCompanionBuilder
    = TechDocSectionTableCompanion Function({
  Value<int> id,
  required int docId,
  Value<int?> parentId,
  required String title,
  required String content,
  required int pageStart,
  required int pageEnd,
  required int level,
  required int sortOrder,
});
typedef $$TechDocSectionTableTableUpdateCompanionBuilder
    = TechDocSectionTableCompanion Function({
  Value<int> id,
  Value<int> docId,
  Value<int?> parentId,
  Value<String> title,
  Value<String> content,
  Value<int> pageStart,
  Value<int> pageEnd,
  Value<int> level,
  Value<int> sortOrder,
});

final class $$TechDocSectionTableTableReferences extends BaseReferences<
    _$AppDatabase, $TechDocSectionTableTable, TechDocSectionTableData> {
  $$TechDocSectionTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $TechDocTableTable _docIdTable(_$AppDatabase db) =>
      db.techDocTable.createAlias('tech_doc_section__doc_id__tech_doc__id');

  $$TechDocTableTableProcessedTableManager get docId {
    final $_column = $_itemColumn<int>('doc_id')!;

    final manager = $$TechDocTableTableTableManager($_db, $_db.techDocTable)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_docIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$TechDocSectionTableTableFilterComposer
    extends Composer<_$AppDatabase, $TechDocSectionTableTable> {
  $$TechDocSectionTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get parentId => $composableBuilder(
      column: $table.parentId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageStart => $composableBuilder(
      column: $table.pageStart, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageEnd => $composableBuilder(
      column: $table.pageEnd, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get level => $composableBuilder(
      column: $table.level, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  $$TechDocTableTableFilterComposer get docId {
    final $$TechDocTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.docId,
        referencedTable: $db.techDocTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TechDocTableTableFilterComposer(
              $db: $db,
              $table: $db.techDocTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TechDocSectionTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TechDocSectionTableTable> {
  $$TechDocSectionTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get parentId => $composableBuilder(
      column: $table.parentId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageStart => $composableBuilder(
      column: $table.pageStart, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageEnd => $composableBuilder(
      column: $table.pageEnd, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get level => $composableBuilder(
      column: $table.level, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  $$TechDocTableTableOrderingComposer get docId {
    final $$TechDocTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.docId,
        referencedTable: $db.techDocTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TechDocTableTableOrderingComposer(
              $db: $db,
              $table: $db.techDocTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TechDocSectionTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TechDocSectionTableTable> {
  $$TechDocSectionTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get pageStart =>
      $composableBuilder(column: $table.pageStart, builder: (column) => column);

  GeneratedColumn<int> get pageEnd =>
      $composableBuilder(column: $table.pageEnd, builder: (column) => column);

  GeneratedColumn<int> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$TechDocTableTableAnnotationComposer get docId {
    final $$TechDocTableTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.docId,
        referencedTable: $db.techDocTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$TechDocTableTableAnnotationComposer(
              $db: $db,
              $table: $db.techDocTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$TechDocSectionTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $TechDocSectionTableTable,
    TechDocSectionTableData,
    $$TechDocSectionTableTableFilterComposer,
    $$TechDocSectionTableTableOrderingComposer,
    $$TechDocSectionTableTableAnnotationComposer,
    $$TechDocSectionTableTableCreateCompanionBuilder,
    $$TechDocSectionTableTableUpdateCompanionBuilder,
    (TechDocSectionTableData, $$TechDocSectionTableTableReferences),
    TechDocSectionTableData,
    PrefetchHooks Function({bool docId})> {
  $$TechDocSectionTableTableTableManager(
      _$AppDatabase db, $TechDocSectionTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TechDocSectionTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TechDocSectionTableTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TechDocSectionTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> docId = const Value.absent(),
            Value<int?> parentId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<int> pageStart = const Value.absent(),
            Value<int> pageEnd = const Value.absent(),
            Value<int> level = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
          }) =>
              TechDocSectionTableCompanion(
            id: id,
            docId: docId,
            parentId: parentId,
            title: title,
            content: content,
            pageStart: pageStart,
            pageEnd: pageEnd,
            level: level,
            sortOrder: sortOrder,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int docId,
            Value<int?> parentId = const Value.absent(),
            required String title,
            required String content,
            required int pageStart,
            required int pageEnd,
            required int level,
            required int sortOrder,
          }) =>
              TechDocSectionTableCompanion.insert(
            id: id,
            docId: docId,
            parentId: parentId,
            title: title,
            content: content,
            pageStart: pageStart,
            pageEnd: pageEnd,
            level: level,
            sortOrder: sortOrder,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$TechDocSectionTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({docId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (docId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.docId,
                    referencedTable:
                        $$TechDocSectionTableTableReferences._docIdTable(db),
                    referencedColumn:
                        $$TechDocSectionTableTableReferences._docIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$TechDocSectionTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $TechDocSectionTableTable,
    TechDocSectionTableData,
    $$TechDocSectionTableTableFilterComposer,
    $$TechDocSectionTableTableOrderingComposer,
    $$TechDocSectionTableTableAnnotationComposer,
    $$TechDocSectionTableTableCreateCompanionBuilder,
    $$TechDocSectionTableTableUpdateCompanionBuilder,
    (TechDocSectionTableData, $$TechDocSectionTableTableReferences),
    TechDocSectionTableData,
    PrefetchHooks Function({bool docId})>;
typedef $$McpProposalTableTableCreateCompanionBuilder
    = McpProposalTableCompanion Function({
  Value<int> id,
  required String proposalType,
  required String title,
  required String proposalJson,
  required String operatorId,
  Value<String> status,
  Value<DateTime> createdAt,
});
typedef $$McpProposalTableTableUpdateCompanionBuilder
    = McpProposalTableCompanion Function({
  Value<int> id,
  Value<String> proposalType,
  Value<String> title,
  Value<String> proposalJson,
  Value<String> operatorId,
  Value<String> status,
  Value<DateTime> createdAt,
});

class $$McpProposalTableTableFilterComposer
    extends Composer<_$AppDatabase, $McpProposalTableTable> {
  $$McpProposalTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get proposalType => $composableBuilder(
      column: $table.proposalType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get proposalJson => $composableBuilder(
      column: $table.proposalJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get operatorId => $composableBuilder(
      column: $table.operatorId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$McpProposalTableTableOrderingComposer
    extends Composer<_$AppDatabase, $McpProposalTableTable> {
  $$McpProposalTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get proposalType => $composableBuilder(
      column: $table.proposalType,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get proposalJson => $composableBuilder(
      column: $table.proposalJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get operatorId => $composableBuilder(
      column: $table.operatorId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$McpProposalTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $McpProposalTableTable> {
  $$McpProposalTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get proposalType => $composableBuilder(
      column: $table.proposalType, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get proposalJson => $composableBuilder(
      column: $table.proposalJson, builder: (column) => column);

  GeneratedColumn<String> get operatorId => $composableBuilder(
      column: $table.operatorId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$McpProposalTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $McpProposalTableTable,
    McpProposalTableData,
    $$McpProposalTableTableFilterComposer,
    $$McpProposalTableTableOrderingComposer,
    $$McpProposalTableTableAnnotationComposer,
    $$McpProposalTableTableCreateCompanionBuilder,
    $$McpProposalTableTableUpdateCompanionBuilder,
    (
      McpProposalTableData,
      BaseReferences<_$AppDatabase, $McpProposalTableTable,
          McpProposalTableData>
    ),
    McpProposalTableData,
    PrefetchHooks Function()> {
  $$McpProposalTableTableTableManager(
      _$AppDatabase db, $McpProposalTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$McpProposalTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$McpProposalTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$McpProposalTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> proposalType = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> proposalJson = const Value.absent(),
            Value<String> operatorId = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              McpProposalTableCompanion(
            id: id,
            proposalType: proposalType,
            title: title,
            proposalJson: proposalJson,
            operatorId: operatorId,
            status: status,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String proposalType,
            required String title,
            required String proposalJson,
            required String operatorId,
            Value<String> status = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              McpProposalTableCompanion.insert(
            id: id,
            proposalType: proposalType,
            title: title,
            proposalJson: proposalJson,
            operatorId: operatorId,
            status: status,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$McpProposalTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $McpProposalTableTable,
    McpProposalTableData,
    $$McpProposalTableTableFilterComposer,
    $$McpProposalTableTableOrderingComposer,
    $$McpProposalTableTableAnnotationComposer,
    $$McpProposalTableTableCreateCompanionBuilder,
    $$McpProposalTableTableUpdateCompanionBuilder,
    (
      McpProposalTableData,
      BaseReferences<_$AppDatabase, $McpProposalTableTable,
          McpProposalTableData>
    ),
    McpProposalTableData,
    PrefetchHooks Function()>;
typedef $$PlcVarRefTableTableCreateCompanionBuilder = PlcVarRefTableCompanion
    Function({
  Value<int> id,
  required int blockId,
  required String variablePath,
  required String kind,
  Value<int?> lineNumber,
  Value<String?> sourceLine,
});
typedef $$PlcVarRefTableTableUpdateCompanionBuilder = PlcVarRefTableCompanion
    Function({
  Value<int> id,
  Value<int> blockId,
  Value<String> variablePath,
  Value<String> kind,
  Value<int?> lineNumber,
  Value<String?> sourceLine,
});

final class $$PlcVarRefTableTableReferences extends BaseReferences<
    _$AppDatabase, $PlcVarRefTableTable, PlcVarRefTableData> {
  $$PlcVarRefTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $PlcCodeBlockTableTable _blockIdTable(_$AppDatabase db) =>
      db.plcCodeBlockTable
          .createAlias('plc_var_ref__block_id__plc_code_block__id');

  $$PlcCodeBlockTableTableProcessedTableManager get blockId {
    final $_column = $_itemColumn<int>('block_id')!;

    final manager =
        $$PlcCodeBlockTableTableTableManager($_db, $_db.plcCodeBlockTable)
            .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_blockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$PlcVarRefTableTableFilterComposer
    extends Composer<_$AppDatabase, $PlcVarRefTableTable> {
  $$PlcVarRefTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get variablePath => $composableBuilder(
      column: $table.variablePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceLine => $composableBuilder(
      column: $table.sourceLine, builder: (column) => ColumnFilters(column));

  $$PlcCodeBlockTableTableFilterComposer get blockId {
    final $$PlcCodeBlockTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.blockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableFilterComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcVarRefTableTableOrderingComposer
    extends Composer<_$AppDatabase, $PlcVarRefTableTable> {
  $$PlcVarRefTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get variablePath => $composableBuilder(
      column: $table.variablePath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceLine => $composableBuilder(
      column: $table.sourceLine, builder: (column) => ColumnOrderings(column));

  $$PlcCodeBlockTableTableOrderingComposer get blockId {
    final $$PlcCodeBlockTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.blockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableOrderingComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcVarRefTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlcVarRefTableTable> {
  $$PlcVarRefTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get variablePath => $composableBuilder(
      column: $table.variablePath, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => column);

  GeneratedColumn<String> get sourceLine => $composableBuilder(
      column: $table.sourceLine, builder: (column) => column);

  $$PlcCodeBlockTableTableAnnotationComposer get blockId {
    final $$PlcCodeBlockTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.blockId,
            referencedTable: $db.plcCodeBlockTable,
            getReferencedColumn: (t) => t.id,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$PlcCodeBlockTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.plcCodeBlockTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return composer;
  }
}

class $$PlcVarRefTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PlcVarRefTableTable,
    PlcVarRefTableData,
    $$PlcVarRefTableTableFilterComposer,
    $$PlcVarRefTableTableOrderingComposer,
    $$PlcVarRefTableTableAnnotationComposer,
    $$PlcVarRefTableTableCreateCompanionBuilder,
    $$PlcVarRefTableTableUpdateCompanionBuilder,
    (PlcVarRefTableData, $$PlcVarRefTableTableReferences),
    PlcVarRefTableData,
    PrefetchHooks Function({bool blockId})> {
  $$PlcVarRefTableTableTableManager(
      _$AppDatabase db, $PlcVarRefTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlcVarRefTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlcVarRefTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlcVarRefTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> blockId = const Value.absent(),
            Value<String> variablePath = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<int?> lineNumber = const Value.absent(),
            Value<String?> sourceLine = const Value.absent(),
          }) =>
              PlcVarRefTableCompanion(
            id: id,
            blockId: blockId,
            variablePath: variablePath,
            kind: kind,
            lineNumber: lineNumber,
            sourceLine: sourceLine,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int blockId,
            required String variablePath,
            required String kind,
            Value<int?> lineNumber = const Value.absent(),
            Value<String?> sourceLine = const Value.absent(),
          }) =>
              PlcVarRefTableCompanion.insert(
            id: id,
            blockId: blockId,
            variablePath: variablePath,
            kind: kind,
            lineNumber: lineNumber,
            sourceLine: sourceLine,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PlcVarRefTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({blockId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (blockId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.blockId,
                    referencedTable:
                        $$PlcVarRefTableTableReferences._blockIdTable(db),
                    referencedColumn:
                        $$PlcVarRefTableTableReferences._blockIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PlcVarRefTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PlcVarRefTableTable,
    PlcVarRefTableData,
    $$PlcVarRefTableTableFilterComposer,
    $$PlcVarRefTableTableOrderingComposer,
    $$PlcVarRefTableTableAnnotationComposer,
    $$PlcVarRefTableTableCreateCompanionBuilder,
    $$PlcVarRefTableTableUpdateCompanionBuilder,
    (PlcVarRefTableData, $$PlcVarRefTableTableReferences),
    PlcVarRefTableData,
    PrefetchHooks Function({bool blockId})>;
typedef $$PlcFbInstanceTableTableCreateCompanionBuilder
    = PlcFbInstanceTableCompanion Function({
  Value<int> id,
  required int declaringBlockId,
  required String instanceName,
  required String fbTypeName,
});
typedef $$PlcFbInstanceTableTableUpdateCompanionBuilder
    = PlcFbInstanceTableCompanion Function({
  Value<int> id,
  Value<int> declaringBlockId,
  Value<String> instanceName,
  Value<String> fbTypeName,
});

final class $$PlcFbInstanceTableTableReferences extends BaseReferences<
    _$AppDatabase, $PlcFbInstanceTableTable, PlcFbInstanceTableData> {
  $$PlcFbInstanceTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $PlcCodeBlockTableTable _declaringBlockIdTable(_$AppDatabase db) => db
      .plcCodeBlockTable
      .createAlias('plc_fb_instance__declaring_block_id__plc_code_block__id');

  $$PlcCodeBlockTableTableProcessedTableManager get declaringBlockId {
    final $_column = $_itemColumn<int>('declaring_block_id')!;

    final manager =
        $$PlcCodeBlockTableTableTableManager($_db, $_db.plcCodeBlockTable)
            .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_declaringBlockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$PlcFbInstanceTableTableFilterComposer
    extends Composer<_$AppDatabase, $PlcFbInstanceTableTable> {
  $$PlcFbInstanceTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get instanceName => $composableBuilder(
      column: $table.instanceName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fbTypeName => $composableBuilder(
      column: $table.fbTypeName, builder: (column) => ColumnFilters(column));

  $$PlcCodeBlockTableTableFilterComposer get declaringBlockId {
    final $$PlcCodeBlockTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.declaringBlockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableFilterComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcFbInstanceTableTableOrderingComposer
    extends Composer<_$AppDatabase, $PlcFbInstanceTableTable> {
  $$PlcFbInstanceTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get instanceName => $composableBuilder(
      column: $table.instanceName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fbTypeName => $composableBuilder(
      column: $table.fbTypeName, builder: (column) => ColumnOrderings(column));

  $$PlcCodeBlockTableTableOrderingComposer get declaringBlockId {
    final $$PlcCodeBlockTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.declaringBlockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableOrderingComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcFbInstanceTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlcFbInstanceTableTable> {
  $$PlcFbInstanceTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get instanceName => $composableBuilder(
      column: $table.instanceName, builder: (column) => column);

  GeneratedColumn<String> get fbTypeName => $composableBuilder(
      column: $table.fbTypeName, builder: (column) => column);

  $$PlcCodeBlockTableTableAnnotationComposer get declaringBlockId {
    final $$PlcCodeBlockTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.declaringBlockId,
            referencedTable: $db.plcCodeBlockTable,
            getReferencedColumn: (t) => t.id,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$PlcCodeBlockTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.plcCodeBlockTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return composer;
  }
}

class $$PlcFbInstanceTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PlcFbInstanceTableTable,
    PlcFbInstanceTableData,
    $$PlcFbInstanceTableTableFilterComposer,
    $$PlcFbInstanceTableTableOrderingComposer,
    $$PlcFbInstanceTableTableAnnotationComposer,
    $$PlcFbInstanceTableTableCreateCompanionBuilder,
    $$PlcFbInstanceTableTableUpdateCompanionBuilder,
    (PlcFbInstanceTableData, $$PlcFbInstanceTableTableReferences),
    PlcFbInstanceTableData,
    PrefetchHooks Function({bool declaringBlockId})> {
  $$PlcFbInstanceTableTableTableManager(
      _$AppDatabase db, $PlcFbInstanceTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlcFbInstanceTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlcFbInstanceTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlcFbInstanceTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> declaringBlockId = const Value.absent(),
            Value<String> instanceName = const Value.absent(),
            Value<String> fbTypeName = const Value.absent(),
          }) =>
              PlcFbInstanceTableCompanion(
            id: id,
            declaringBlockId: declaringBlockId,
            instanceName: instanceName,
            fbTypeName: fbTypeName,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int declaringBlockId,
            required String instanceName,
            required String fbTypeName,
          }) =>
              PlcFbInstanceTableCompanion.insert(
            id: id,
            declaringBlockId: declaringBlockId,
            instanceName: instanceName,
            fbTypeName: fbTypeName,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PlcFbInstanceTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({declaringBlockId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (declaringBlockId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.declaringBlockId,
                    referencedTable: $$PlcFbInstanceTableTableReferences
                        ._declaringBlockIdTable(db),
                    referencedColumn: $$PlcFbInstanceTableTableReferences
                        ._declaringBlockIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PlcFbInstanceTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PlcFbInstanceTableTable,
    PlcFbInstanceTableData,
    $$PlcFbInstanceTableTableFilterComposer,
    $$PlcFbInstanceTableTableOrderingComposer,
    $$PlcFbInstanceTableTableAnnotationComposer,
    $$PlcFbInstanceTableTableCreateCompanionBuilder,
    $$PlcFbInstanceTableTableUpdateCompanionBuilder,
    (PlcFbInstanceTableData, $$PlcFbInstanceTableTableReferences),
    PlcFbInstanceTableData,
    PrefetchHooks Function({bool declaringBlockId})>;
typedef $$PlcBlockCallTableTableCreateCompanionBuilder
    = PlcBlockCallTableCompanion Function({
  Value<int> id,
  required int callerBlockId,
  required String calleeBlockName,
  Value<int?> lineNumber,
});
typedef $$PlcBlockCallTableTableUpdateCompanionBuilder
    = PlcBlockCallTableCompanion Function({
  Value<int> id,
  Value<int> callerBlockId,
  Value<String> calleeBlockName,
  Value<int?> lineNumber,
});

final class $$PlcBlockCallTableTableReferences extends BaseReferences<
    _$AppDatabase, $PlcBlockCallTableTable, PlcBlockCallTableData> {
  $$PlcBlockCallTableTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $PlcCodeBlockTableTable _callerBlockIdTable(_$AppDatabase db) =>
      db.plcCodeBlockTable
          .createAlias('plc_block_call__caller_block_id__plc_code_block__id');

  $$PlcCodeBlockTableTableProcessedTableManager get callerBlockId {
    final $_column = $_itemColumn<int>('caller_block_id')!;

    final manager =
        $$PlcCodeBlockTableTableTableManager($_db, $_db.plcCodeBlockTable)
            .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_callerBlockIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$PlcBlockCallTableTableFilterComposer
    extends Composer<_$AppDatabase, $PlcBlockCallTableTable> {
  $$PlcBlockCallTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get calleeBlockName => $composableBuilder(
      column: $table.calleeBlockName,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnFilters(column));

  $$PlcCodeBlockTableTableFilterComposer get callerBlockId {
    final $$PlcCodeBlockTableTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.callerBlockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableFilterComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcBlockCallTableTableOrderingComposer
    extends Composer<_$AppDatabase, $PlcBlockCallTableTable> {
  $$PlcBlockCallTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get calleeBlockName => $composableBuilder(
      column: $table.calleeBlockName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnOrderings(column));

  $$PlcCodeBlockTableTableOrderingComposer get callerBlockId {
    final $$PlcCodeBlockTableTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.callerBlockId,
        referencedTable: $db.plcCodeBlockTable,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$PlcCodeBlockTableTableOrderingComposer(
              $db: $db,
              $table: $db.plcCodeBlockTable,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$PlcBlockCallTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlcBlockCallTableTable> {
  $$PlcBlockCallTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get calleeBlockName => $composableBuilder(
      column: $table.calleeBlockName, builder: (column) => column);

  GeneratedColumn<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => column);

  $$PlcCodeBlockTableTableAnnotationComposer get callerBlockId {
    final $$PlcCodeBlockTableTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.callerBlockId,
            referencedTable: $db.plcCodeBlockTable,
            getReferencedColumn: (t) => t.id,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$PlcCodeBlockTableTableAnnotationComposer(
                  $db: $db,
                  $table: $db.plcCodeBlockTable,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return composer;
  }
}

class $$PlcBlockCallTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PlcBlockCallTableTable,
    PlcBlockCallTableData,
    $$PlcBlockCallTableTableFilterComposer,
    $$PlcBlockCallTableTableOrderingComposer,
    $$PlcBlockCallTableTableAnnotationComposer,
    $$PlcBlockCallTableTableCreateCompanionBuilder,
    $$PlcBlockCallTableTableUpdateCompanionBuilder,
    (PlcBlockCallTableData, $$PlcBlockCallTableTableReferences),
    PlcBlockCallTableData,
    PrefetchHooks Function({bool callerBlockId})> {
  $$PlcBlockCallTableTableTableManager(
      _$AppDatabase db, $PlcBlockCallTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlcBlockCallTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlcBlockCallTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlcBlockCallTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> callerBlockId = const Value.absent(),
            Value<String> calleeBlockName = const Value.absent(),
            Value<int?> lineNumber = const Value.absent(),
          }) =>
              PlcBlockCallTableCompanion(
            id: id,
            callerBlockId: callerBlockId,
            calleeBlockName: calleeBlockName,
            lineNumber: lineNumber,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int callerBlockId,
            required String calleeBlockName,
            Value<int?> lineNumber = const Value.absent(),
          }) =>
              PlcBlockCallTableCompanion.insert(
            id: id,
            callerBlockId: callerBlockId,
            calleeBlockName: calleeBlockName,
            lineNumber: lineNumber,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$PlcBlockCallTableTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({callerBlockId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (callerBlockId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.callerBlockId,
                    referencedTable: $$PlcBlockCallTableTableReferences
                        ._callerBlockIdTable(db),
                    referencedColumn: $$PlcBlockCallTableTableReferences
                        ._callerBlockIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$PlcBlockCallTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PlcBlockCallTableTable,
    PlcBlockCallTableData,
    $$PlcBlockCallTableTableFilterComposer,
    $$PlcBlockCallTableTableOrderingComposer,
    $$PlcBlockCallTableTableAnnotationComposer,
    $$PlcBlockCallTableTableCreateCompanionBuilder,
    $$PlcBlockCallTableTableUpdateCompanionBuilder,
    (PlcBlockCallTableData, $$PlcBlockCallTableTableReferences),
    PlcBlockCallTableData,
    PrefetchHooks Function({bool callerBlockId})>;
typedef $$AppRoleTableCreateCompanionBuilder = AppRoleCompanion Function({
  required String name,
  required String groups,
  Value<bool> seeded,
  Value<String?> allowedPages,
  Value<int> rowid,
});
typedef $$AppRoleTableUpdateCompanionBuilder = AppRoleCompanion Function({
  Value<String> name,
  Value<String> groups,
  Value<bool> seeded,
  Value<String?> allowedPages,
  Value<int> rowid,
});

final class $$AppRoleTableReferences
    extends BaseReferences<_$AppDatabase, $AppRoleTable, AppRoleData> {
  $$AppRoleTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$AppUserTable, List<AppUserData>>
      _appUserRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.appUser,
              aliasName: 'app_role__name__app_user__role_name');

  $$AppUserTableProcessedTableManager get appUserRefs {
    final manager = $$AppUserTableTableManager($_db, $_db.appUser).filter(
        (f) => f.roleName.name.sqlEquals($_itemColumn<String>('name')!));

    final cache = $_typedResult.readTableOrNull(_appUserRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$AppRoleTableFilterComposer
    extends Composer<_$AppDatabase, $AppRoleTable> {
  $$AppRoleTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get groups => $composableBuilder(
      column: $table.groups, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get seeded => $composableBuilder(
      column: $table.seeded, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get allowedPages => $composableBuilder(
      column: $table.allowedPages, builder: (column) => ColumnFilters(column));

  Expression<bool> appUserRefs(
      Expression<bool> Function($$AppUserTableFilterComposer f) f) {
    final $$AppUserTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.name,
        referencedTable: $db.appUser,
        getReferencedColumn: (t) => t.roleName,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AppUserTableFilterComposer(
              $db: $db,
              $table: $db.appUser,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AppRoleTableOrderingComposer
    extends Composer<_$AppDatabase, $AppRoleTable> {
  $$AppRoleTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get groups => $composableBuilder(
      column: $table.groups, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get seeded => $composableBuilder(
      column: $table.seeded, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get allowedPages => $composableBuilder(
      column: $table.allowedPages,
      builder: (column) => ColumnOrderings(column));
}

class $$AppRoleTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppRoleTable> {
  $$AppRoleTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get groups =>
      $composableBuilder(column: $table.groups, builder: (column) => column);

  GeneratedColumn<bool> get seeded =>
      $composableBuilder(column: $table.seeded, builder: (column) => column);

  GeneratedColumn<String> get allowedPages => $composableBuilder(
      column: $table.allowedPages, builder: (column) => column);

  Expression<T> appUserRefs<T extends Object>(
      Expression<T> Function($$AppUserTableAnnotationComposer a) f) {
    final $$AppUserTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.name,
        referencedTable: $db.appUser,
        getReferencedColumn: (t) => t.roleName,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AppUserTableAnnotationComposer(
              $db: $db,
              $table: $db.appUser,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$AppRoleTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AppRoleTable,
    AppRoleData,
    $$AppRoleTableFilterComposer,
    $$AppRoleTableOrderingComposer,
    $$AppRoleTableAnnotationComposer,
    $$AppRoleTableCreateCompanionBuilder,
    $$AppRoleTableUpdateCompanionBuilder,
    (AppRoleData, $$AppRoleTableReferences),
    AppRoleData,
    PrefetchHooks Function({bool appUserRefs})> {
  $$AppRoleTableTableManager(_$AppDatabase db, $AppRoleTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppRoleTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppRoleTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppRoleTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> name = const Value.absent(),
            Value<String> groups = const Value.absent(),
            Value<bool> seeded = const Value.absent(),
            Value<String?> allowedPages = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AppRoleCompanion(
            name: name,
            groups: groups,
            seeded: seeded,
            allowedPages: allowedPages,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String name,
            required String groups,
            Value<bool> seeded = const Value.absent(),
            Value<String?> allowedPages = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AppRoleCompanion.insert(
            name: name,
            groups: groups,
            seeded: seeded,
            allowedPages: allowedPages,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$AppRoleTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({appUserRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (appUserRefs) db.appUser],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (appUserRefs)
                    await $_getPrefetchedData<AppRoleData, $AppRoleTable,
                            AppUserData>(
                        currentTable: table,
                        referencedTable:
                            $$AppRoleTableReferences._appUserRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$AppRoleTableReferences(db, table, p0).appUserRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.roleName == item.name),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$AppRoleTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AppRoleTable,
    AppRoleData,
    $$AppRoleTableFilterComposer,
    $$AppRoleTableOrderingComposer,
    $$AppRoleTableAnnotationComposer,
    $$AppRoleTableCreateCompanionBuilder,
    $$AppRoleTableUpdateCompanionBuilder,
    (AppRoleData, $$AppRoleTableReferences),
    AppRoleData,
    PrefetchHooks Function({bool appUserRefs})>;
typedef $$AppUserTableCreateCompanionBuilder = AppUserCompanion Function({
  required String username,
  required String roleName,
  Value<String?> additionalRoles,
  required String passwordHash,
  required String salt,
  required DateTime createdAt,
  Value<DateTime?> lastLoginAt,
  Value<bool> stationAccount,
  Value<String?> allowedPages,
  Value<int?> inactivityTimeoutMinutes,
  Value<int> rowid,
});
typedef $$AppUserTableUpdateCompanionBuilder = AppUserCompanion Function({
  Value<String> username,
  Value<String> roleName,
  Value<String?> additionalRoles,
  Value<String> passwordHash,
  Value<String> salt,
  Value<DateTime> createdAt,
  Value<DateTime?> lastLoginAt,
  Value<bool> stationAccount,
  Value<String?> allowedPages,
  Value<int?> inactivityTimeoutMinutes,
  Value<int> rowid,
});

final class $$AppUserTableReferences
    extends BaseReferences<_$AppDatabase, $AppUserTable, AppUserData> {
  $$AppUserTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AppRoleTable _roleNameTable(_$AppDatabase db) =>
      db.appRole.createAlias('app_user__role_name__app_role__name');

  $$AppRoleTableProcessedTableManager get roleName {
    final $_column = $_itemColumn<String>('role_name')!;

    final manager = $$AppRoleTableTableManager($_db, $_db.appRole)
        .filter((f) => f.name.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_roleNameTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$AppUserTableFilterComposer
    extends Composer<_$AppDatabase, $AppUserTable> {
  $$AppUserTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get username => $composableBuilder(
      column: $table.username, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get additionalRoles => $composableBuilder(
      column: $table.additionalRoles,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get passwordHash => $composableBuilder(
      column: $table.passwordHash, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get salt => $composableBuilder(
      column: $table.salt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastLoginAt => $composableBuilder(
      column: $table.lastLoginAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get stationAccount => $composableBuilder(
      column: $table.stationAccount,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get allowedPages => $composableBuilder(
      column: $table.allowedPages, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get inactivityTimeoutMinutes => $composableBuilder(
      column: $table.inactivityTimeoutMinutes,
      builder: (column) => ColumnFilters(column));

  $$AppRoleTableFilterComposer get roleName {
    final $$AppRoleTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.roleName,
        referencedTable: $db.appRole,
        getReferencedColumn: (t) => t.name,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AppRoleTableFilterComposer(
              $db: $db,
              $table: $db.appRole,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AppUserTableOrderingComposer
    extends Composer<_$AppDatabase, $AppUserTable> {
  $$AppUserTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get username => $composableBuilder(
      column: $table.username, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get additionalRoles => $composableBuilder(
      column: $table.additionalRoles,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get passwordHash => $composableBuilder(
      column: $table.passwordHash,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get salt => $composableBuilder(
      column: $table.salt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastLoginAt => $composableBuilder(
      column: $table.lastLoginAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get stationAccount => $composableBuilder(
      column: $table.stationAccount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get allowedPages => $composableBuilder(
      column: $table.allowedPages,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get inactivityTimeoutMinutes => $composableBuilder(
      column: $table.inactivityTimeoutMinutes,
      builder: (column) => ColumnOrderings(column));

  $$AppRoleTableOrderingComposer get roleName {
    final $$AppRoleTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.roleName,
        referencedTable: $db.appRole,
        getReferencedColumn: (t) => t.name,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AppRoleTableOrderingComposer(
              $db: $db,
              $table: $db.appRole,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AppUserTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppUserTable> {
  $$AppUserTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get additionalRoles => $composableBuilder(
      column: $table.additionalRoles, builder: (column) => column);

  GeneratedColumn<String> get passwordHash => $composableBuilder(
      column: $table.passwordHash, builder: (column) => column);

  GeneratedColumn<String> get salt =>
      $composableBuilder(column: $table.salt, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastLoginAt => $composableBuilder(
      column: $table.lastLoginAt, builder: (column) => column);

  GeneratedColumn<bool> get stationAccount => $composableBuilder(
      column: $table.stationAccount, builder: (column) => column);

  GeneratedColumn<String> get allowedPages => $composableBuilder(
      column: $table.allowedPages, builder: (column) => column);

  GeneratedColumn<int> get inactivityTimeoutMinutes => $composableBuilder(
      column: $table.inactivityTimeoutMinutes, builder: (column) => column);

  $$AppRoleTableAnnotationComposer get roleName {
    final $$AppRoleTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.roleName,
        referencedTable: $db.appRole,
        getReferencedColumn: (t) => t.name,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$AppRoleTableAnnotationComposer(
              $db: $db,
              $table: $db.appRole,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$AppUserTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AppUserTable,
    AppUserData,
    $$AppUserTableFilterComposer,
    $$AppUserTableOrderingComposer,
    $$AppUserTableAnnotationComposer,
    $$AppUserTableCreateCompanionBuilder,
    $$AppUserTableUpdateCompanionBuilder,
    (AppUserData, $$AppUserTableReferences),
    AppUserData,
    PrefetchHooks Function({bool roleName})> {
  $$AppUserTableTableManager(_$AppDatabase db, $AppUserTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppUserTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppUserTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppUserTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> username = const Value.absent(),
            Value<String> roleName = const Value.absent(),
            Value<String?> additionalRoles = const Value.absent(),
            Value<String> passwordHash = const Value.absent(),
            Value<String> salt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime?> lastLoginAt = const Value.absent(),
            Value<bool> stationAccount = const Value.absent(),
            Value<String?> allowedPages = const Value.absent(),
            Value<int?> inactivityTimeoutMinutes = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AppUserCompanion(
            username: username,
            roleName: roleName,
            additionalRoles: additionalRoles,
            passwordHash: passwordHash,
            salt: salt,
            createdAt: createdAt,
            lastLoginAt: lastLoginAt,
            stationAccount: stationAccount,
            allowedPages: allowedPages,
            inactivityTimeoutMinutes: inactivityTimeoutMinutes,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String username,
            required String roleName,
            Value<String?> additionalRoles = const Value.absent(),
            required String passwordHash,
            required String salt,
            required DateTime createdAt,
            Value<DateTime?> lastLoginAt = const Value.absent(),
            Value<bool> stationAccount = const Value.absent(),
            Value<String?> allowedPages = const Value.absent(),
            Value<int?> inactivityTimeoutMinutes = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AppUserCompanion.insert(
            username: username,
            roleName: roleName,
            additionalRoles: additionalRoles,
            passwordHash: passwordHash,
            salt: salt,
            createdAt: createdAt,
            lastLoginAt: lastLoginAt,
            stationAccount: stationAccount,
            allowedPages: allowedPages,
            inactivityTimeoutMinutes: inactivityTimeoutMinutes,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$AppUserTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({roleName = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (roleName) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.roleName,
                    referencedTable:
                        $$AppUserTableReferences._roleNameTable(db),
                    referencedColumn:
                        $$AppUserTableReferences._roleNameTable(db).name,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$AppUserTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AppUserTable,
    AppUserData,
    $$AppUserTableFilterComposer,
    $$AppUserTableOrderingComposer,
    $$AppUserTableAnnotationComposer,
    $$AppUserTableCreateCompanionBuilder,
    $$AppUserTableUpdateCompanionBuilder,
    (AppUserData, $$AppUserTableReferences),
    AppUserData,
    PrefetchHooks Function({bool roleName})>;
typedef $$AuditEntryTableCreateCompanionBuilder = AuditEntryCompanion Function({
  Value<int> id,
  required DateTime at,
  required String who,
  required String station,
  required String roleName,
  required String surface,
  required String itemKey,
  Value<String?> member,
  Value<String?> oldValue,
  Value<String?> newValue,
  required String groupRequired,
  required bool allowed,
  Value<String> origin,
  required String actionId,
  Value<String?> reason,
});
typedef $$AuditEntryTableUpdateCompanionBuilder = AuditEntryCompanion Function({
  Value<int> id,
  Value<DateTime> at,
  Value<String> who,
  Value<String> station,
  Value<String> roleName,
  Value<String> surface,
  Value<String> itemKey,
  Value<String?> member,
  Value<String?> oldValue,
  Value<String?> newValue,
  Value<String> groupRequired,
  Value<bool> allowed,
  Value<String> origin,
  Value<String> actionId,
  Value<String?> reason,
});

class $$AuditEntryTableFilterComposer
    extends Composer<_$AppDatabase, $AuditEntryTable> {
  $$AuditEntryTableFilterComposer({
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

  ColumnFilters<String> get who => $composableBuilder(
      column: $table.who, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get station => $composableBuilder(
      column: $table.station, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get roleName => $composableBuilder(
      column: $table.roleName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get surface => $composableBuilder(
      column: $table.surface, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get itemKey => $composableBuilder(
      column: $table.itemKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get member => $composableBuilder(
      column: $table.member, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get oldValue => $composableBuilder(
      column: $table.oldValue, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get newValue => $composableBuilder(
      column: $table.newValue, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get groupRequired => $composableBuilder(
      column: $table.groupRequired, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get allowed => $composableBuilder(
      column: $table.allowed, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get origin => $composableBuilder(
      column: $table.origin, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actionId => $composableBuilder(
      column: $table.actionId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reason => $composableBuilder(
      column: $table.reason, builder: (column) => ColumnFilters(column));
}

class $$AuditEntryTableOrderingComposer
    extends Composer<_$AppDatabase, $AuditEntryTable> {
  $$AuditEntryTableOrderingComposer({
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

  ColumnOrderings<String> get who => $composableBuilder(
      column: $table.who, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get station => $composableBuilder(
      column: $table.station, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get roleName => $composableBuilder(
      column: $table.roleName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get surface => $composableBuilder(
      column: $table.surface, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get itemKey => $composableBuilder(
      column: $table.itemKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get member => $composableBuilder(
      column: $table.member, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get oldValue => $composableBuilder(
      column: $table.oldValue, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get newValue => $composableBuilder(
      column: $table.newValue, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get groupRequired => $composableBuilder(
      column: $table.groupRequired,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get allowed => $composableBuilder(
      column: $table.allowed, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get origin => $composableBuilder(
      column: $table.origin, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actionId => $composableBuilder(
      column: $table.actionId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reason => $composableBuilder(
      column: $table.reason, builder: (column) => ColumnOrderings(column));
}

class $$AuditEntryTableAnnotationComposer
    extends Composer<_$AppDatabase, $AuditEntryTable> {
  $$AuditEntryTableAnnotationComposer({
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

  GeneratedColumn<String> get who =>
      $composableBuilder(column: $table.who, builder: (column) => column);

  GeneratedColumn<String> get station =>
      $composableBuilder(column: $table.station, builder: (column) => column);

  GeneratedColumn<String> get roleName =>
      $composableBuilder(column: $table.roleName, builder: (column) => column);

  GeneratedColumn<String> get surface =>
      $composableBuilder(column: $table.surface, builder: (column) => column);

  GeneratedColumn<String> get itemKey =>
      $composableBuilder(column: $table.itemKey, builder: (column) => column);

  GeneratedColumn<String> get member =>
      $composableBuilder(column: $table.member, builder: (column) => column);

  GeneratedColumn<String> get oldValue =>
      $composableBuilder(column: $table.oldValue, builder: (column) => column);

  GeneratedColumn<String> get newValue =>
      $composableBuilder(column: $table.newValue, builder: (column) => column);

  GeneratedColumn<String> get groupRequired => $composableBuilder(
      column: $table.groupRequired, builder: (column) => column);

  GeneratedColumn<bool> get allowed =>
      $composableBuilder(column: $table.allowed, builder: (column) => column);

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<String> get actionId =>
      $composableBuilder(column: $table.actionId, builder: (column) => column);

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);
}

class $$AuditEntryTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AuditEntryTable,
    AuditEntryData,
    $$AuditEntryTableFilterComposer,
    $$AuditEntryTableOrderingComposer,
    $$AuditEntryTableAnnotationComposer,
    $$AuditEntryTableCreateCompanionBuilder,
    $$AuditEntryTableUpdateCompanionBuilder,
    (
      AuditEntryData,
      BaseReferences<_$AppDatabase, $AuditEntryTable, AuditEntryData>
    ),
    AuditEntryData,
    PrefetchHooks Function()> {
  $$AuditEntryTableTableManager(_$AppDatabase db, $AuditEntryTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AuditEntryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AuditEntryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AuditEntryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> at = const Value.absent(),
            Value<String> who = const Value.absent(),
            Value<String> station = const Value.absent(),
            Value<String> roleName = const Value.absent(),
            Value<String> surface = const Value.absent(),
            Value<String> itemKey = const Value.absent(),
            Value<String?> member = const Value.absent(),
            Value<String?> oldValue = const Value.absent(),
            Value<String?> newValue = const Value.absent(),
            Value<String> groupRequired = const Value.absent(),
            Value<bool> allowed = const Value.absent(),
            Value<String> origin = const Value.absent(),
            Value<String> actionId = const Value.absent(),
            Value<String?> reason = const Value.absent(),
          }) =>
              AuditEntryCompanion(
            id: id,
            at: at,
            who: who,
            station: station,
            roleName: roleName,
            surface: surface,
            itemKey: itemKey,
            member: member,
            oldValue: oldValue,
            newValue: newValue,
            groupRequired: groupRequired,
            allowed: allowed,
            origin: origin,
            actionId: actionId,
            reason: reason,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required DateTime at,
            required String who,
            required String station,
            required String roleName,
            required String surface,
            required String itemKey,
            Value<String?> member = const Value.absent(),
            Value<String?> oldValue = const Value.absent(),
            Value<String?> newValue = const Value.absent(),
            required String groupRequired,
            required bool allowed,
            Value<String> origin = const Value.absent(),
            required String actionId,
            Value<String?> reason = const Value.absent(),
          }) =>
              AuditEntryCompanion.insert(
            id: id,
            at: at,
            who: who,
            station: station,
            roleName: roleName,
            surface: surface,
            itemKey: itemKey,
            member: member,
            oldValue: oldValue,
            newValue: newValue,
            groupRequired: groupRequired,
            allowed: allowed,
            origin: origin,
            actionId: actionId,
            reason: reason,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AuditEntryTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AuditEntryTable,
    AuditEntryData,
    $$AuditEntryTableFilterComposer,
    $$AuditEntryTableOrderingComposer,
    $$AuditEntryTableAnnotationComposer,
    $$AuditEntryTableCreateCompanionBuilder,
    $$AuditEntryTableUpdateCompanionBuilder,
    (
      AuditEntryData,
      BaseReferences<_$AppDatabase, $AuditEntryTable, AuditEntryData>
    ),
    AuditEntryData,
    PrefetchHooks Function()>;
typedef $$AccessTemplateTableTableCreateCompanionBuilder
    = AccessTemplateTableCompanion Function({
  required String name,
  required String rules,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$AccessTemplateTableTableUpdateCompanionBuilder
    = AccessTemplateTableCompanion Function({
  Value<String> name,
  Value<String> rules,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$AccessTemplateTableTableFilterComposer
    extends Composer<_$AppDatabase, $AccessTemplateTableTable> {
  $$AccessTemplateTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rules => $composableBuilder(
      column: $table.rules, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$AccessTemplateTableTableOrderingComposer
    extends Composer<_$AppDatabase, $AccessTemplateTableTable> {
  $$AccessTemplateTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rules => $composableBuilder(
      column: $table.rules, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$AccessTemplateTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccessTemplateTableTable> {
  $$AccessTemplateTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get rules =>
      $composableBuilder(column: $table.rules, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$AccessTemplateTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AccessTemplateTableTable,
    AccessTemplateTableData,
    $$AccessTemplateTableTableFilterComposer,
    $$AccessTemplateTableTableOrderingComposer,
    $$AccessTemplateTableTableAnnotationComposer,
    $$AccessTemplateTableTableCreateCompanionBuilder,
    $$AccessTemplateTableTableUpdateCompanionBuilder,
    (
      AccessTemplateTableData,
      BaseReferences<_$AppDatabase, $AccessTemplateTableTable,
          AccessTemplateTableData>
    ),
    AccessTemplateTableData,
    PrefetchHooks Function()> {
  $$AccessTemplateTableTableTableManager(
      _$AppDatabase db, $AccessTemplateTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccessTemplateTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccessTemplateTableTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccessTemplateTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> name = const Value.absent(),
            Value<String> rules = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AccessTemplateTableCompanion(
            name: name,
            rules: rules,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String name,
            required String rules,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              AccessTemplateTableCompanion.insert(
            name: name,
            rules: rules,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AccessTemplateTableTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AccessTemplateTableTable,
    AccessTemplateTableData,
    $$AccessTemplateTableTableFilterComposer,
    $$AccessTemplateTableTableOrderingComposer,
    $$AccessTemplateTableTableAnnotationComposer,
    $$AccessTemplateTableTableCreateCompanionBuilder,
    $$AccessTemplateTableTableUpdateCompanionBuilder,
    (
      AccessTemplateTableData,
      BaseReferences<_$AppDatabase, $AccessTemplateTableTable,
          AccessTemplateTableData>
    ),
    AccessTemplateTableData,
    PrefetchHooks Function()>;
typedef $$AccessKeyBindingTableTableCreateCompanionBuilder
    = AccessKeyBindingTableCompanion Function({
  required String keyName,
  required String templateName,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$AccessKeyBindingTableTableUpdateCompanionBuilder
    = AccessKeyBindingTableCompanion Function({
  Value<String> keyName,
  Value<String> templateName,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$AccessKeyBindingTableTableFilterComposer
    extends Composer<_$AppDatabase, $AccessKeyBindingTableTable> {
  $$AccessKeyBindingTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get keyName => $composableBuilder(
      column: $table.keyName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get templateName => $composableBuilder(
      column: $table.templateName, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$AccessKeyBindingTableTableOrderingComposer
    extends Composer<_$AppDatabase, $AccessKeyBindingTableTable> {
  $$AccessKeyBindingTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get keyName => $composableBuilder(
      column: $table.keyName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get templateName => $composableBuilder(
      column: $table.templateName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$AccessKeyBindingTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccessKeyBindingTableTable> {
  $$AccessKeyBindingTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get keyName =>
      $composableBuilder(column: $table.keyName, builder: (column) => column);

  GeneratedColumn<String> get templateName => $composableBuilder(
      column: $table.templateName, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$AccessKeyBindingTableTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AccessKeyBindingTableTable,
    AccessKeyBindingTableData,
    $$AccessKeyBindingTableTableFilterComposer,
    $$AccessKeyBindingTableTableOrderingComposer,
    $$AccessKeyBindingTableTableAnnotationComposer,
    $$AccessKeyBindingTableTableCreateCompanionBuilder,
    $$AccessKeyBindingTableTableUpdateCompanionBuilder,
    (
      AccessKeyBindingTableData,
      BaseReferences<_$AppDatabase, $AccessKeyBindingTableTable,
          AccessKeyBindingTableData>
    ),
    AccessKeyBindingTableData,
    PrefetchHooks Function()> {
  $$AccessKeyBindingTableTableTableManager(
      _$AppDatabase db, $AccessKeyBindingTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccessKeyBindingTableTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$AccessKeyBindingTableTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccessKeyBindingTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> keyName = const Value.absent(),
            Value<String> templateName = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AccessKeyBindingTableCompanion(
            keyName: keyName,
            templateName: templateName,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String keyName,
            required String templateName,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              AccessKeyBindingTableCompanion.insert(
            keyName: keyName,
            templateName: templateName,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AccessKeyBindingTableTableProcessedTableManager
    = ProcessedTableManager<
        _$AppDatabase,
        $AccessKeyBindingTableTable,
        AccessKeyBindingTableData,
        $$AccessKeyBindingTableTableFilterComposer,
        $$AccessKeyBindingTableTableOrderingComposer,
        $$AccessKeyBindingTableTableAnnotationComposer,
        $$AccessKeyBindingTableTableCreateCompanionBuilder,
        $$AccessKeyBindingTableTableUpdateCompanionBuilder,
        (
          AccessKeyBindingTableData,
          BaseReferences<_$AppDatabase, $AccessKeyBindingTableTable,
              AccessKeyBindingTableData>
        ),
        AccessKeyBindingTableData,
        PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AlarmTableTableManager get alarm =>
      $$AlarmTableTableManager(_db, _db.alarm);
  $$AlarmHistoryTableTableManager get alarmHistory =>
      $$AlarmHistoryTableTableManager(_db, _db.alarmHistory);
  $$FlutterPreferencesTableTableManager get flutterPreferences =>
      $$FlutterPreferencesTableTableManager(_db, _db.flutterPreferences);
  $$HistoryViewTableTableManager get historyView =>
      $$HistoryViewTableTableManager(_db, _db.historyView);
  $$HistoryViewKeyTableTableManager get historyViewKey =>
      $$HistoryViewKeyTableTableManager(_db, _db.historyViewKey);
  $$HistoryViewGraphTableTableManager get historyViewGraph =>
      $$HistoryViewGraphTableTableManager(_db, _db.historyViewGraph);
  $$HistoryViewPeriodTableTableManager get historyViewPeriod =>
      $$HistoryViewPeriodTableTableManager(_db, _db.historyViewPeriod);
  $$AuditLogTableTableManager get auditLog =>
      $$AuditLogTableTableManager(_db, _db.auditLog);
  $$PlcCodeBlockTableTableTableManager get plcCodeBlockTable =>
      $$PlcCodeBlockTableTableTableManager(_db, _db.plcCodeBlockTable);
  $$PlcVariableTableTableTableManager get plcVariableTable =>
      $$PlcVariableTableTableTableManager(_db, _db.plcVariableTable);
  $$DrawingTableTableTableManager get drawingTable =>
      $$DrawingTableTableTableManager(_db, _db.drawingTable);
  $$DrawingComponentTableTableTableManager get drawingComponentTable =>
      $$DrawingComponentTableTableTableManager(_db, _db.drawingComponentTable);
  $$TechDocTableTableTableManager get techDocTable =>
      $$TechDocTableTableTableManager(_db, _db.techDocTable);
  $$TechDocSectionTableTableTableManager get techDocSectionTable =>
      $$TechDocSectionTableTableTableManager(_db, _db.techDocSectionTable);
  $$McpProposalTableTableTableManager get mcpProposalTable =>
      $$McpProposalTableTableTableManager(_db, _db.mcpProposalTable);
  $$PlcVarRefTableTableTableManager get plcVarRefTable =>
      $$PlcVarRefTableTableTableManager(_db, _db.plcVarRefTable);
  $$PlcFbInstanceTableTableTableManager get plcFbInstanceTable =>
      $$PlcFbInstanceTableTableTableManager(_db, _db.plcFbInstanceTable);
  $$PlcBlockCallTableTableTableManager get plcBlockCallTable =>
      $$PlcBlockCallTableTableTableManager(_db, _db.plcBlockCallTable);
  $$AppRoleTableTableManager get appRole =>
      $$AppRoleTableTableManager(_db, _db.appRole);
  $$AppUserTableTableManager get appUser =>
      $$AppUserTableTableManager(_db, _db.appUser);
  $$AuditEntryTableTableManager get auditEntry =>
      $$AuditEntryTableTableManager(_db, _db.auditEntry);
  $$AccessTemplateTableTableTableManager get accessTemplateTable =>
      $$AccessTemplateTableTableTableManager(_db, _db.accessTemplateTable);
  $$AccessKeyBindingTableTableTableManager get accessKeyBindingTable =>
      $$AccessKeyBindingTableTableTableManager(_db, _db.accessKeyBindingTable);
}
