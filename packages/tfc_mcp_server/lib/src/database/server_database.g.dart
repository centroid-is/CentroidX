// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_database.dart';

// ignore_for_file: type=lint
class $ServerAlarmTable extends ServerAlarm
    with TableInfo<$ServerAlarmTable, ServerAlarmData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerAlarmTable(this.attachedDatabase, [this._alias]);
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
  VerificationContext validateIntegrity(Insertable<ServerAlarmData> instance,
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
  ServerAlarmData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerAlarmData(
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
  $ServerAlarmTable createAlias(String alias) {
    return $ServerAlarmTable(attachedDatabase, alias);
  }
}

class ServerAlarmData extends DataClass implements Insertable<ServerAlarmData> {
  final String uid;
  final String? key;
  final String title;
  final String description;
  final String rules;
  const ServerAlarmData(
      {required this.uid,
      this.key,
      required this.title,
      required this.description,
      required this.rules});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['uid'] = Variable<String>(uid);
    if (!nullToAbsent || key != null) {
      map['key'] = Variable<String>(key);
    }
    map['title'] = Variable<String>(title);
    map['description'] = Variable<String>(description);
    map['rules'] = Variable<String>(rules);
    return map;
  }

  ServerAlarmCompanion toCompanion(bool nullToAbsent) {
    return ServerAlarmCompanion(
      uid: Value(uid),
      key: key == null && nullToAbsent ? const Value.absent() : Value(key),
      title: Value(title),
      description: Value(description),
      rules: Value(rules),
    );
  }

  factory ServerAlarmData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerAlarmData(
      uid: serializer.fromJson<String>(json['uid']),
      key: serializer.fromJson<String?>(json['key']),
      title: serializer.fromJson<String>(json['title']),
      description: serializer.fromJson<String>(json['description']),
      rules: serializer.fromJson<String>(json['rules']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'uid': serializer.toJson<String>(uid),
      'key': serializer.toJson<String?>(key),
      'title': serializer.toJson<String>(title),
      'description': serializer.toJson<String>(description),
      'rules': serializer.toJson<String>(rules),
    };
  }

  ServerAlarmData copyWith(
          {String? uid,
          Value<String?> key = const Value.absent(),
          String? title,
          String? description,
          String? rules}) =>
      ServerAlarmData(
        uid: uid ?? this.uid,
        key: key.present ? key.value : this.key,
        title: title ?? this.title,
        description: description ?? this.description,
        rules: rules ?? this.rules,
      );
  ServerAlarmData copyWithCompanion(ServerAlarmCompanion data) {
    return ServerAlarmData(
      uid: data.uid.present ? data.uid.value : this.uid,
      key: data.key.present ? data.key.value : this.key,
      title: data.title.present ? data.title.value : this.title,
      description:
          data.description.present ? data.description.value : this.description,
      rules: data.rules.present ? data.rules.value : this.rules,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ServerAlarmData(')
          ..write('uid: $uid, ')
          ..write('key: $key, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('rules: $rules')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(uid, key, title, description, rules);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerAlarmData &&
          other.uid == this.uid &&
          other.key == this.key &&
          other.title == this.title &&
          other.description == this.description &&
          other.rules == this.rules);
}

class ServerAlarmCompanion extends UpdateCompanion<ServerAlarmData> {
  final Value<String> uid;
  final Value<String?> key;
  final Value<String> title;
  final Value<String> description;
  final Value<String> rules;
  final Value<int> rowid;
  const ServerAlarmCompanion({
    this.uid = const Value.absent(),
    this.key = const Value.absent(),
    this.title = const Value.absent(),
    this.description = const Value.absent(),
    this.rules = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ServerAlarmCompanion.insert({
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
  static Insertable<ServerAlarmData> custom({
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

  ServerAlarmCompanion copyWith(
      {Value<String>? uid,
      Value<String?>? key,
      Value<String>? title,
      Value<String>? description,
      Value<String>? rules,
      Value<int>? rowid}) {
    return ServerAlarmCompanion(
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
    return (StringBuffer('ServerAlarmCompanion(')
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

class $ServerAlarmHistoryTable extends ServerAlarmHistory
    with TableInfo<$ServerAlarmHistoryTable, ServerAlarmHistoryData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerAlarmHistoryTable(this.attachedDatabase, [this._alias]);
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
      type: DriftSqlType.string, requiredDuringInsert: true);
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
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("active" IN (0, 1))'));
  static const VerificationMeta _pendingAckMeta =
      const VerificationMeta('pendingAck');
  @override
  late final GeneratedColumn<bool> pendingAck = GeneratedColumn<bool>(
      'pending_ack', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("pending_ack" IN (0, 1))'));
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
  VerificationContext validateIntegrity(
      Insertable<ServerAlarmHistoryData> instance,
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
  ServerAlarmHistoryData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerAlarmHistoryData(
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
  $ServerAlarmHistoryTable createAlias(String alias) {
    return $ServerAlarmHistoryTable(attachedDatabase, alias);
  }
}

class ServerAlarmHistoryData extends DataClass
    implements Insertable<ServerAlarmHistoryData> {
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
  const ServerAlarmHistoryData(
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

  ServerAlarmHistoryCompanion toCompanion(bool nullToAbsent) {
    return ServerAlarmHistoryCompanion(
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

  factory ServerAlarmHistoryData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerAlarmHistoryData(
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

  ServerAlarmHistoryData copyWith(
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
      ServerAlarmHistoryData(
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
  ServerAlarmHistoryData copyWithCompanion(ServerAlarmHistoryCompanion data) {
    return ServerAlarmHistoryData(
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
    return (StringBuffer('ServerAlarmHistoryData(')
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
      (other is ServerAlarmHistoryData &&
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

class ServerAlarmHistoryCompanion
    extends UpdateCompanion<ServerAlarmHistoryData> {
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
  const ServerAlarmHistoryCompanion({
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
  ServerAlarmHistoryCompanion.insert({
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
  static Insertable<ServerAlarmHistoryData> custom({
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

  ServerAlarmHistoryCompanion copyWith(
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
    return ServerAlarmHistoryCompanion(
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
    return (StringBuffer('ServerAlarmHistoryCompanion(')
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
      type: DriftSqlType.int, requiredDuringInsert: true);
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

  /// Optional PDF blob storage for drawings (added in schema v7).
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
      type: DriftSqlType.int, requiredDuringInsert: true);
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
      type: DriftSqlType.int, requiredDuringInsert: true);
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

class $ServerMcpProposalTableTable extends ServerMcpProposalTable
    with TableInfo<$ServerMcpProposalTableTable, ServerMcpProposalTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerMcpProposalTableTable(this.attachedDatabase, [this._alias]);
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
      Insertable<ServerMcpProposalTableData> instance,
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
  ServerMcpProposalTableData map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerMcpProposalTableData(
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
  $ServerMcpProposalTableTable createAlias(String alias) {
    return $ServerMcpProposalTableTable(attachedDatabase, alias);
  }
}

class ServerMcpProposalTableData extends DataClass
    implements Insertable<ServerMcpProposalTableData> {
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
  const ServerMcpProposalTableData(
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

  ServerMcpProposalTableCompanion toCompanion(bool nullToAbsent) {
    return ServerMcpProposalTableCompanion(
      id: Value(id),
      proposalType: Value(proposalType),
      title: Value(title),
      proposalJson: Value(proposalJson),
      operatorId: Value(operatorId),
      status: Value(status),
      createdAt: Value(createdAt),
    );
  }

  factory ServerMcpProposalTableData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerMcpProposalTableData(
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

  ServerMcpProposalTableData copyWith(
          {int? id,
          String? proposalType,
          String? title,
          String? proposalJson,
          String? operatorId,
          String? status,
          DateTime? createdAt}) =>
      ServerMcpProposalTableData(
        id: id ?? this.id,
        proposalType: proposalType ?? this.proposalType,
        title: title ?? this.title,
        proposalJson: proposalJson ?? this.proposalJson,
        operatorId: operatorId ?? this.operatorId,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );
  ServerMcpProposalTableData copyWithCompanion(
      ServerMcpProposalTableCompanion data) {
    return ServerMcpProposalTableData(
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
    return (StringBuffer('ServerMcpProposalTableData(')
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
      (other is ServerMcpProposalTableData &&
          other.id == this.id &&
          other.proposalType == this.proposalType &&
          other.title == this.title &&
          other.proposalJson == this.proposalJson &&
          other.operatorId == this.operatorId &&
          other.status == this.status &&
          other.createdAt == this.createdAt);
}

class ServerMcpProposalTableCompanion
    extends UpdateCompanion<ServerMcpProposalTableData> {
  final Value<int> id;
  final Value<String> proposalType;
  final Value<String> title;
  final Value<String> proposalJson;
  final Value<String> operatorId;
  final Value<String> status;
  final Value<DateTime> createdAt;
  const ServerMcpProposalTableCompanion({
    this.id = const Value.absent(),
    this.proposalType = const Value.absent(),
    this.title = const Value.absent(),
    this.proposalJson = const Value.absent(),
    this.operatorId = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  ServerMcpProposalTableCompanion.insert({
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
  static Insertable<ServerMcpProposalTableData> custom({
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

  ServerMcpProposalTableCompanion copyWith(
      {Value<int>? id,
      Value<String>? proposalType,
      Value<String>? title,
      Value<String>? proposalJson,
      Value<String>? operatorId,
      Value<String>? status,
      Value<DateTime>? createdAt}) {
    return ServerMcpProposalTableCompanion(
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
    return (StringBuffer('ServerMcpProposalTableCompanion(')
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
      type: DriftSqlType.int, requiredDuringInsert: true);
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
      type: DriftSqlType.int, requiredDuringInsert: true);
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
      type: DriftSqlType.int, requiredDuringInsert: true);
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

abstract class _$ServerDatabase extends GeneratedDatabase {
  _$ServerDatabase(QueryExecutor e) : super(e);
  $ServerDatabaseManager get managers => $ServerDatabaseManager(this);
  late final $ServerAlarmTable serverAlarm = $ServerAlarmTable(this);
  late final $ServerAlarmHistoryTable serverAlarmHistory =
      $ServerAlarmHistoryTable(this);
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
  late final $ServerMcpProposalTableTable serverMcpProposalTable =
      $ServerMcpProposalTableTable(this);
  late final $PlcVarRefTableTable plcVarRefTable = $PlcVarRefTableTable(this);
  late final $PlcFbInstanceTableTable plcFbInstanceTable =
      $PlcFbInstanceTableTable(this);
  late final $PlcBlockCallTableTable plcBlockCallTable =
      $PlcBlockCallTableTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        serverAlarm,
        serverAlarmHistory,
        auditLog,
        plcCodeBlockTable,
        plcVariableTable,
        drawingTable,
        drawingComponentTable,
        techDocTable,
        techDocSectionTable,
        serverMcpProposalTable,
        plcVarRefTable,
        plcFbInstanceTable,
        plcBlockCallTable
      ];
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);
}

typedef $$ServerAlarmTableCreateCompanionBuilder = ServerAlarmCompanion
    Function({
  required String uid,
  Value<String?> key,
  required String title,
  required String description,
  required String rules,
  Value<int> rowid,
});
typedef $$ServerAlarmTableUpdateCompanionBuilder = ServerAlarmCompanion
    Function({
  Value<String> uid,
  Value<String?> key,
  Value<String> title,
  Value<String> description,
  Value<String> rules,
  Value<int> rowid,
});

class $$ServerAlarmTableFilterComposer
    extends Composer<_$ServerDatabase, $ServerAlarmTable> {
  $$ServerAlarmTableFilterComposer({
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
}

class $$ServerAlarmTableOrderingComposer
    extends Composer<_$ServerDatabase, $ServerAlarmTable> {
  $$ServerAlarmTableOrderingComposer({
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

class $$ServerAlarmTableAnnotationComposer
    extends Composer<_$ServerDatabase, $ServerAlarmTable> {
  $$ServerAlarmTableAnnotationComposer({
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
}

class $$ServerAlarmTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $ServerAlarmTable,
    ServerAlarmData,
    $$ServerAlarmTableFilterComposer,
    $$ServerAlarmTableOrderingComposer,
    $$ServerAlarmTableAnnotationComposer,
    $$ServerAlarmTableCreateCompanionBuilder,
    $$ServerAlarmTableUpdateCompanionBuilder,
    (
      ServerAlarmData,
      BaseReferences<_$ServerDatabase, $ServerAlarmTable, ServerAlarmData>
    ),
    ServerAlarmData,
    PrefetchHooks Function()> {
  $$ServerAlarmTableTableManager(_$ServerDatabase db, $ServerAlarmTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerAlarmTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerAlarmTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerAlarmTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> uid = const Value.absent(),
            Value<String?> key = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> description = const Value.absent(),
            Value<String> rules = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ServerAlarmCompanion(
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
              ServerAlarmCompanion.insert(
            uid: uid,
            key: key,
            title: title,
            description: description,
            rules: rules,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ServerAlarmTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $ServerAlarmTable,
    ServerAlarmData,
    $$ServerAlarmTableFilterComposer,
    $$ServerAlarmTableOrderingComposer,
    $$ServerAlarmTableAnnotationComposer,
    $$ServerAlarmTableCreateCompanionBuilder,
    $$ServerAlarmTableUpdateCompanionBuilder,
    (
      ServerAlarmData,
      BaseReferences<_$ServerDatabase, $ServerAlarmTable, ServerAlarmData>
    ),
    ServerAlarmData,
    PrefetchHooks Function()>;
typedef $$ServerAlarmHistoryTableCreateCompanionBuilder
    = ServerAlarmHistoryCompanion Function({
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
typedef $$ServerAlarmHistoryTableUpdateCompanionBuilder
    = ServerAlarmHistoryCompanion Function({
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

class $$ServerAlarmHistoryTableFilterComposer
    extends Composer<_$ServerDatabase, $ServerAlarmHistoryTable> {
  $$ServerAlarmHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alarmUid => $composableBuilder(
      column: $table.alarmUid, builder: (column) => ColumnFilters(column));

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
}

class $$ServerAlarmHistoryTableOrderingComposer
    extends Composer<_$ServerDatabase, $ServerAlarmHistoryTable> {
  $$ServerAlarmHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alarmUid => $composableBuilder(
      column: $table.alarmUid, builder: (column) => ColumnOrderings(column));

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
}

class $$ServerAlarmHistoryTableAnnotationComposer
    extends Composer<_$ServerDatabase, $ServerAlarmHistoryTable> {
  $$ServerAlarmHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get alarmUid =>
      $composableBuilder(column: $table.alarmUid, builder: (column) => column);

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
}

class $$ServerAlarmHistoryTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $ServerAlarmHistoryTable,
    ServerAlarmHistoryData,
    $$ServerAlarmHistoryTableFilterComposer,
    $$ServerAlarmHistoryTableOrderingComposer,
    $$ServerAlarmHistoryTableAnnotationComposer,
    $$ServerAlarmHistoryTableCreateCompanionBuilder,
    $$ServerAlarmHistoryTableUpdateCompanionBuilder,
    (
      ServerAlarmHistoryData,
      BaseReferences<_$ServerDatabase, $ServerAlarmHistoryTable,
          ServerAlarmHistoryData>
    ),
    ServerAlarmHistoryData,
    PrefetchHooks Function()> {
  $$ServerAlarmHistoryTableTableManager(
      _$ServerDatabase db, $ServerAlarmHistoryTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerAlarmHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerAlarmHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerAlarmHistoryTableAnnotationComposer(
                  $db: db, $table: table),
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
              ServerAlarmHistoryCompanion(
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
              ServerAlarmHistoryCompanion.insert(
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ServerAlarmHistoryTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $ServerAlarmHistoryTable,
    ServerAlarmHistoryData,
    $$ServerAlarmHistoryTableFilterComposer,
    $$ServerAlarmHistoryTableOrderingComposer,
    $$ServerAlarmHistoryTableAnnotationComposer,
    $$ServerAlarmHistoryTableCreateCompanionBuilder,
    $$ServerAlarmHistoryTableUpdateCompanionBuilder,
    (
      ServerAlarmHistoryData,
      BaseReferences<_$ServerDatabase, $ServerAlarmHistoryTable,
          ServerAlarmHistoryData>
    ),
    ServerAlarmHistoryData,
    PrefetchHooks Function()>;
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
    extends Composer<_$ServerDatabase, $AuditLogTable> {
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
    extends Composer<_$ServerDatabase, $AuditLogTable> {
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
    extends Composer<_$ServerDatabase, $AuditLogTable> {
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
    _$ServerDatabase,
    $AuditLogTable,
    AuditLogData,
    $$AuditLogTableFilterComposer,
    $$AuditLogTableOrderingComposer,
    $$AuditLogTableAnnotationComposer,
    $$AuditLogTableCreateCompanionBuilder,
    $$AuditLogTableUpdateCompanionBuilder,
    (
      AuditLogData,
      BaseReferences<_$ServerDatabase, $AuditLogTable, AuditLogData>
    ),
    AuditLogData,
    PrefetchHooks Function()> {
  $$AuditLogTableTableManager(_$ServerDatabase db, $AuditLogTable table)
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
    _$ServerDatabase,
    $AuditLogTable,
    AuditLogData,
    $$AuditLogTableFilterComposer,
    $$AuditLogTableOrderingComposer,
    $$AuditLogTableAnnotationComposer,
    $$AuditLogTableCreateCompanionBuilder,
    $$AuditLogTableUpdateCompanionBuilder,
    (
      AuditLogData,
      BaseReferences<_$ServerDatabase, $AuditLogTable, AuditLogData>
    ),
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

class $$PlcCodeBlockTableTableFilterComposer
    extends Composer<_$ServerDatabase, $PlcCodeBlockTableTable> {
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
}

class $$PlcCodeBlockTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $PlcCodeBlockTableTable> {
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
    extends Composer<_$ServerDatabase, $PlcCodeBlockTableTable> {
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
}

class $$PlcCodeBlockTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $PlcCodeBlockTableTable,
    PlcCodeBlockTableData,
    $$PlcCodeBlockTableTableFilterComposer,
    $$PlcCodeBlockTableTableOrderingComposer,
    $$PlcCodeBlockTableTableAnnotationComposer,
    $$PlcCodeBlockTableTableCreateCompanionBuilder,
    $$PlcCodeBlockTableTableUpdateCompanionBuilder,
    (
      PlcCodeBlockTableData,
      BaseReferences<_$ServerDatabase, $PlcCodeBlockTableTable,
          PlcCodeBlockTableData>
    ),
    PlcCodeBlockTableData,
    PrefetchHooks Function()> {
  $$PlcCodeBlockTableTableTableManager(
      _$ServerDatabase db, $PlcCodeBlockTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlcCodeBlockTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $PlcCodeBlockTableTable,
    PlcCodeBlockTableData,
    $$PlcCodeBlockTableTableFilterComposer,
    $$PlcCodeBlockTableTableOrderingComposer,
    $$PlcCodeBlockTableTableAnnotationComposer,
    $$PlcCodeBlockTableTableCreateCompanionBuilder,
    $$PlcCodeBlockTableTableUpdateCompanionBuilder,
    (
      PlcCodeBlockTableData,
      BaseReferences<_$ServerDatabase, $PlcCodeBlockTableTable,
          PlcCodeBlockTableData>
    ),
    PlcCodeBlockTableData,
    PrefetchHooks Function()>;
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

class $$PlcVariableTableTableFilterComposer
    extends Composer<_$ServerDatabase, $PlcVariableTableTable> {
  $$PlcVariableTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get blockId => $composableBuilder(
      column: $table.blockId, builder: (column) => ColumnFilters(column));

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
}

class $$PlcVariableTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $PlcVariableTableTable> {
  $$PlcVariableTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get blockId => $composableBuilder(
      column: $table.blockId, builder: (column) => ColumnOrderings(column));

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
}

class $$PlcVariableTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $PlcVariableTableTable> {
  $$PlcVariableTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get blockId =>
      $composableBuilder(column: $table.blockId, builder: (column) => column);

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
}

class $$PlcVariableTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $PlcVariableTableTable,
    PlcVariableTableData,
    $$PlcVariableTableTableFilterComposer,
    $$PlcVariableTableTableOrderingComposer,
    $$PlcVariableTableTableAnnotationComposer,
    $$PlcVariableTableTableCreateCompanionBuilder,
    $$PlcVariableTableTableUpdateCompanionBuilder,
    (
      PlcVariableTableData,
      BaseReferences<_$ServerDatabase, $PlcVariableTableTable,
          PlcVariableTableData>
    ),
    PlcVariableTableData,
    PrefetchHooks Function()> {
  $$PlcVariableTableTableTableManager(
      _$ServerDatabase db, $PlcVariableTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlcVariableTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $PlcVariableTableTable,
    PlcVariableTableData,
    $$PlcVariableTableTableFilterComposer,
    $$PlcVariableTableTableOrderingComposer,
    $$PlcVariableTableTableAnnotationComposer,
    $$PlcVariableTableTableCreateCompanionBuilder,
    $$PlcVariableTableTableUpdateCompanionBuilder,
    (
      PlcVariableTableData,
      BaseReferences<_$ServerDatabase, $PlcVariableTableTable,
          PlcVariableTableData>
    ),
    PlcVariableTableData,
    PrefetchHooks Function()>;
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

class $$DrawingTableTableFilterComposer
    extends Composer<_$ServerDatabase, $DrawingTableTable> {
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
}

class $$DrawingTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $DrawingTableTable> {
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
    extends Composer<_$ServerDatabase, $DrawingTableTable> {
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
}

class $$DrawingTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $DrawingTableTable,
    DrawingTableData,
    $$DrawingTableTableFilterComposer,
    $$DrawingTableTableOrderingComposer,
    $$DrawingTableTableAnnotationComposer,
    $$DrawingTableTableCreateCompanionBuilder,
    $$DrawingTableTableUpdateCompanionBuilder,
    (
      DrawingTableData,
      BaseReferences<_$ServerDatabase, $DrawingTableTable, DrawingTableData>
    ),
    DrawingTableData,
    PrefetchHooks Function()> {
  $$DrawingTableTableTableManager(_$ServerDatabase db, $DrawingTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DrawingTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $DrawingTableTable,
    DrawingTableData,
    $$DrawingTableTableFilterComposer,
    $$DrawingTableTableOrderingComposer,
    $$DrawingTableTableAnnotationComposer,
    $$DrawingTableTableCreateCompanionBuilder,
    $$DrawingTableTableUpdateCompanionBuilder,
    (
      DrawingTableData,
      BaseReferences<_$ServerDatabase, $DrawingTableTable, DrawingTableData>
    ),
    DrawingTableData,
    PrefetchHooks Function()>;
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

class $$DrawingComponentTableTableFilterComposer
    extends Composer<_$ServerDatabase, $DrawingComponentTableTable> {
  $$DrawingComponentTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get drawingId => $composableBuilder(
      column: $table.drawingId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageNumber => $composableBuilder(
      column: $table.pageNumber, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fullPageText => $composableBuilder(
      column: $table.fullPageText, builder: (column) => ColumnFilters(column));
}

class $$DrawingComponentTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $DrawingComponentTableTable> {
  $$DrawingComponentTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get drawingId => $composableBuilder(
      column: $table.drawingId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageNumber => $composableBuilder(
      column: $table.pageNumber, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fullPageText => $composableBuilder(
      column: $table.fullPageText,
      builder: (column) => ColumnOrderings(column));
}

class $$DrawingComponentTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $DrawingComponentTableTable> {
  $$DrawingComponentTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get drawingId =>
      $composableBuilder(column: $table.drawingId, builder: (column) => column);

  GeneratedColumn<int> get pageNumber => $composableBuilder(
      column: $table.pageNumber, builder: (column) => column);

  GeneratedColumn<String> get fullPageText => $composableBuilder(
      column: $table.fullPageText, builder: (column) => column);
}

class $$DrawingComponentTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $DrawingComponentTableTable,
    DrawingComponentTableData,
    $$DrawingComponentTableTableFilterComposer,
    $$DrawingComponentTableTableOrderingComposer,
    $$DrawingComponentTableTableAnnotationComposer,
    $$DrawingComponentTableTableCreateCompanionBuilder,
    $$DrawingComponentTableTableUpdateCompanionBuilder,
    (
      DrawingComponentTableData,
      BaseReferences<_$ServerDatabase, $DrawingComponentTableTable,
          DrawingComponentTableData>
    ),
    DrawingComponentTableData,
    PrefetchHooks Function()> {
  $$DrawingComponentTableTableTableManager(
      _$ServerDatabase db, $DrawingComponentTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DrawingComponentTableTableProcessedTableManager
    = ProcessedTableManager<
        _$ServerDatabase,
        $DrawingComponentTableTable,
        DrawingComponentTableData,
        $$DrawingComponentTableTableFilterComposer,
        $$DrawingComponentTableTableOrderingComposer,
        $$DrawingComponentTableTableAnnotationComposer,
        $$DrawingComponentTableTableCreateCompanionBuilder,
        $$DrawingComponentTableTableUpdateCompanionBuilder,
        (
          DrawingComponentTableData,
          BaseReferences<_$ServerDatabase, $DrawingComponentTableTable,
              DrawingComponentTableData>
        ),
        DrawingComponentTableData,
        PrefetchHooks Function()>;
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

class $$TechDocTableTableFilterComposer
    extends Composer<_$ServerDatabase, $TechDocTableTable> {
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
}

class $$TechDocTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $TechDocTableTable> {
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
    extends Composer<_$ServerDatabase, $TechDocTableTable> {
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
}

class $$TechDocTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $TechDocTableTable,
    TechDocTableData,
    $$TechDocTableTableFilterComposer,
    $$TechDocTableTableOrderingComposer,
    $$TechDocTableTableAnnotationComposer,
    $$TechDocTableTableCreateCompanionBuilder,
    $$TechDocTableTableUpdateCompanionBuilder,
    (
      TechDocTableData,
      BaseReferences<_$ServerDatabase, $TechDocTableTable, TechDocTableData>
    ),
    TechDocTableData,
    PrefetchHooks Function()> {
  $$TechDocTableTableTableManager(_$ServerDatabase db, $TechDocTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TechDocTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $TechDocTableTable,
    TechDocTableData,
    $$TechDocTableTableFilterComposer,
    $$TechDocTableTableOrderingComposer,
    $$TechDocTableTableAnnotationComposer,
    $$TechDocTableTableCreateCompanionBuilder,
    $$TechDocTableTableUpdateCompanionBuilder,
    (
      TechDocTableData,
      BaseReferences<_$ServerDatabase, $TechDocTableTable, TechDocTableData>
    ),
    TechDocTableData,
    PrefetchHooks Function()>;
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

class $$TechDocSectionTableTableFilterComposer
    extends Composer<_$ServerDatabase, $TechDocSectionTableTable> {
  $$TechDocSectionTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get docId => $composableBuilder(
      column: $table.docId, builder: (column) => ColumnFilters(column));

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
}

class $$TechDocSectionTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $TechDocSectionTableTable> {
  $$TechDocSectionTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get docId => $composableBuilder(
      column: $table.docId, builder: (column) => ColumnOrderings(column));

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
}

class $$TechDocSectionTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $TechDocSectionTableTable> {
  $$TechDocSectionTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get docId =>
      $composableBuilder(column: $table.docId, builder: (column) => column);

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
}

class $$TechDocSectionTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $TechDocSectionTableTable,
    TechDocSectionTableData,
    $$TechDocSectionTableTableFilterComposer,
    $$TechDocSectionTableTableOrderingComposer,
    $$TechDocSectionTableTableAnnotationComposer,
    $$TechDocSectionTableTableCreateCompanionBuilder,
    $$TechDocSectionTableTableUpdateCompanionBuilder,
    (
      TechDocSectionTableData,
      BaseReferences<_$ServerDatabase, $TechDocSectionTableTable,
          TechDocSectionTableData>
    ),
    TechDocSectionTableData,
    PrefetchHooks Function()> {
  $$TechDocSectionTableTableTableManager(
      _$ServerDatabase db, $TechDocSectionTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TechDocSectionTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $TechDocSectionTableTable,
    TechDocSectionTableData,
    $$TechDocSectionTableTableFilterComposer,
    $$TechDocSectionTableTableOrderingComposer,
    $$TechDocSectionTableTableAnnotationComposer,
    $$TechDocSectionTableTableCreateCompanionBuilder,
    $$TechDocSectionTableTableUpdateCompanionBuilder,
    (
      TechDocSectionTableData,
      BaseReferences<_$ServerDatabase, $TechDocSectionTableTable,
          TechDocSectionTableData>
    ),
    TechDocSectionTableData,
    PrefetchHooks Function()>;
typedef $$ServerMcpProposalTableTableCreateCompanionBuilder
    = ServerMcpProposalTableCompanion Function({
  Value<int> id,
  required String proposalType,
  required String title,
  required String proposalJson,
  required String operatorId,
  Value<String> status,
  Value<DateTime> createdAt,
});
typedef $$ServerMcpProposalTableTableUpdateCompanionBuilder
    = ServerMcpProposalTableCompanion Function({
  Value<int> id,
  Value<String> proposalType,
  Value<String> title,
  Value<String> proposalJson,
  Value<String> operatorId,
  Value<String> status,
  Value<DateTime> createdAt,
});

class $$ServerMcpProposalTableTableFilterComposer
    extends Composer<_$ServerDatabase, $ServerMcpProposalTableTable> {
  $$ServerMcpProposalTableTableFilterComposer({
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

class $$ServerMcpProposalTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $ServerMcpProposalTableTable> {
  $$ServerMcpProposalTableTableOrderingComposer({
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

class $$ServerMcpProposalTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $ServerMcpProposalTableTable> {
  $$ServerMcpProposalTableTableAnnotationComposer({
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

class $$ServerMcpProposalTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $ServerMcpProposalTableTable,
    ServerMcpProposalTableData,
    $$ServerMcpProposalTableTableFilterComposer,
    $$ServerMcpProposalTableTableOrderingComposer,
    $$ServerMcpProposalTableTableAnnotationComposer,
    $$ServerMcpProposalTableTableCreateCompanionBuilder,
    $$ServerMcpProposalTableTableUpdateCompanionBuilder,
    (
      ServerMcpProposalTableData,
      BaseReferences<_$ServerDatabase, $ServerMcpProposalTableTable,
          ServerMcpProposalTableData>
    ),
    ServerMcpProposalTableData,
    PrefetchHooks Function()> {
  $$ServerMcpProposalTableTableTableManager(
      _$ServerDatabase db, $ServerMcpProposalTableTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerMcpProposalTableTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerMcpProposalTableTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerMcpProposalTableTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> proposalType = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> proposalJson = const Value.absent(),
            Value<String> operatorId = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
          }) =>
              ServerMcpProposalTableCompanion(
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
              ServerMcpProposalTableCompanion.insert(
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

typedef $$ServerMcpProposalTableTableProcessedTableManager
    = ProcessedTableManager<
        _$ServerDatabase,
        $ServerMcpProposalTableTable,
        ServerMcpProposalTableData,
        $$ServerMcpProposalTableTableFilterComposer,
        $$ServerMcpProposalTableTableOrderingComposer,
        $$ServerMcpProposalTableTableAnnotationComposer,
        $$ServerMcpProposalTableTableCreateCompanionBuilder,
        $$ServerMcpProposalTableTableUpdateCompanionBuilder,
        (
          ServerMcpProposalTableData,
          BaseReferences<_$ServerDatabase, $ServerMcpProposalTableTable,
              ServerMcpProposalTableData>
        ),
        ServerMcpProposalTableData,
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

class $$PlcVarRefTableTableFilterComposer
    extends Composer<_$ServerDatabase, $PlcVarRefTableTable> {
  $$PlcVarRefTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get blockId => $composableBuilder(
      column: $table.blockId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get variablePath => $composableBuilder(
      column: $table.variablePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceLine => $composableBuilder(
      column: $table.sourceLine, builder: (column) => ColumnFilters(column));
}

class $$PlcVarRefTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $PlcVarRefTableTable> {
  $$PlcVarRefTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get blockId => $composableBuilder(
      column: $table.blockId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get variablePath => $composableBuilder(
      column: $table.variablePath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceLine => $composableBuilder(
      column: $table.sourceLine, builder: (column) => ColumnOrderings(column));
}

class $$PlcVarRefTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $PlcVarRefTableTable> {
  $$PlcVarRefTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get blockId =>
      $composableBuilder(column: $table.blockId, builder: (column) => column);

  GeneratedColumn<String> get variablePath => $composableBuilder(
      column: $table.variablePath, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => column);

  GeneratedColumn<String> get sourceLine => $composableBuilder(
      column: $table.sourceLine, builder: (column) => column);
}

class $$PlcVarRefTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $PlcVarRefTableTable,
    PlcVarRefTableData,
    $$PlcVarRefTableTableFilterComposer,
    $$PlcVarRefTableTableOrderingComposer,
    $$PlcVarRefTableTableAnnotationComposer,
    $$PlcVarRefTableTableCreateCompanionBuilder,
    $$PlcVarRefTableTableUpdateCompanionBuilder,
    (
      PlcVarRefTableData,
      BaseReferences<_$ServerDatabase, $PlcVarRefTableTable, PlcVarRefTableData>
    ),
    PlcVarRefTableData,
    PrefetchHooks Function()> {
  $$PlcVarRefTableTableTableManager(
      _$ServerDatabase db, $PlcVarRefTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlcVarRefTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $PlcVarRefTableTable,
    PlcVarRefTableData,
    $$PlcVarRefTableTableFilterComposer,
    $$PlcVarRefTableTableOrderingComposer,
    $$PlcVarRefTableTableAnnotationComposer,
    $$PlcVarRefTableTableCreateCompanionBuilder,
    $$PlcVarRefTableTableUpdateCompanionBuilder,
    (
      PlcVarRefTableData,
      BaseReferences<_$ServerDatabase, $PlcVarRefTableTable, PlcVarRefTableData>
    ),
    PlcVarRefTableData,
    PrefetchHooks Function()>;
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

class $$PlcFbInstanceTableTableFilterComposer
    extends Composer<_$ServerDatabase, $PlcFbInstanceTableTable> {
  $$PlcFbInstanceTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get declaringBlockId => $composableBuilder(
      column: $table.declaringBlockId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get instanceName => $composableBuilder(
      column: $table.instanceName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fbTypeName => $composableBuilder(
      column: $table.fbTypeName, builder: (column) => ColumnFilters(column));
}

class $$PlcFbInstanceTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $PlcFbInstanceTableTable> {
  $$PlcFbInstanceTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get declaringBlockId => $composableBuilder(
      column: $table.declaringBlockId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get instanceName => $composableBuilder(
      column: $table.instanceName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fbTypeName => $composableBuilder(
      column: $table.fbTypeName, builder: (column) => ColumnOrderings(column));
}

class $$PlcFbInstanceTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $PlcFbInstanceTableTable> {
  $$PlcFbInstanceTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get declaringBlockId => $composableBuilder(
      column: $table.declaringBlockId, builder: (column) => column);

  GeneratedColumn<String> get instanceName => $composableBuilder(
      column: $table.instanceName, builder: (column) => column);

  GeneratedColumn<String> get fbTypeName => $composableBuilder(
      column: $table.fbTypeName, builder: (column) => column);
}

class $$PlcFbInstanceTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $PlcFbInstanceTableTable,
    PlcFbInstanceTableData,
    $$PlcFbInstanceTableTableFilterComposer,
    $$PlcFbInstanceTableTableOrderingComposer,
    $$PlcFbInstanceTableTableAnnotationComposer,
    $$PlcFbInstanceTableTableCreateCompanionBuilder,
    $$PlcFbInstanceTableTableUpdateCompanionBuilder,
    (
      PlcFbInstanceTableData,
      BaseReferences<_$ServerDatabase, $PlcFbInstanceTableTable,
          PlcFbInstanceTableData>
    ),
    PlcFbInstanceTableData,
    PrefetchHooks Function()> {
  $$PlcFbInstanceTableTableTableManager(
      _$ServerDatabase db, $PlcFbInstanceTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlcFbInstanceTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $PlcFbInstanceTableTable,
    PlcFbInstanceTableData,
    $$PlcFbInstanceTableTableFilterComposer,
    $$PlcFbInstanceTableTableOrderingComposer,
    $$PlcFbInstanceTableTableAnnotationComposer,
    $$PlcFbInstanceTableTableCreateCompanionBuilder,
    $$PlcFbInstanceTableTableUpdateCompanionBuilder,
    (
      PlcFbInstanceTableData,
      BaseReferences<_$ServerDatabase, $PlcFbInstanceTableTable,
          PlcFbInstanceTableData>
    ),
    PlcFbInstanceTableData,
    PrefetchHooks Function()>;
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

class $$PlcBlockCallTableTableFilterComposer
    extends Composer<_$ServerDatabase, $PlcBlockCallTableTable> {
  $$PlcBlockCallTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get callerBlockId => $composableBuilder(
      column: $table.callerBlockId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get calleeBlockName => $composableBuilder(
      column: $table.calleeBlockName,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnFilters(column));
}

class $$PlcBlockCallTableTableOrderingComposer
    extends Composer<_$ServerDatabase, $PlcBlockCallTableTable> {
  $$PlcBlockCallTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get callerBlockId => $composableBuilder(
      column: $table.callerBlockId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get calleeBlockName => $composableBuilder(
      column: $table.calleeBlockName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => ColumnOrderings(column));
}

class $$PlcBlockCallTableTableAnnotationComposer
    extends Composer<_$ServerDatabase, $PlcBlockCallTableTable> {
  $$PlcBlockCallTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get callerBlockId => $composableBuilder(
      column: $table.callerBlockId, builder: (column) => column);

  GeneratedColumn<String> get calleeBlockName => $composableBuilder(
      column: $table.calleeBlockName, builder: (column) => column);

  GeneratedColumn<int> get lineNumber => $composableBuilder(
      column: $table.lineNumber, builder: (column) => column);
}

class $$PlcBlockCallTableTableTableManager extends RootTableManager<
    _$ServerDatabase,
    $PlcBlockCallTableTable,
    PlcBlockCallTableData,
    $$PlcBlockCallTableTableFilterComposer,
    $$PlcBlockCallTableTableOrderingComposer,
    $$PlcBlockCallTableTableAnnotationComposer,
    $$PlcBlockCallTableTableCreateCompanionBuilder,
    $$PlcBlockCallTableTableUpdateCompanionBuilder,
    (
      PlcBlockCallTableData,
      BaseReferences<_$ServerDatabase, $PlcBlockCallTableTable,
          PlcBlockCallTableData>
    ),
    PlcBlockCallTableData,
    PrefetchHooks Function()> {
  $$PlcBlockCallTableTableTableManager(
      _$ServerDatabase db, $PlcBlockCallTableTable table)
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlcBlockCallTableTableProcessedTableManager = ProcessedTableManager<
    _$ServerDatabase,
    $PlcBlockCallTableTable,
    PlcBlockCallTableData,
    $$PlcBlockCallTableTableFilterComposer,
    $$PlcBlockCallTableTableOrderingComposer,
    $$PlcBlockCallTableTableAnnotationComposer,
    $$PlcBlockCallTableTableCreateCompanionBuilder,
    $$PlcBlockCallTableTableUpdateCompanionBuilder,
    (
      PlcBlockCallTableData,
      BaseReferences<_$ServerDatabase, $PlcBlockCallTableTable,
          PlcBlockCallTableData>
    ),
    PlcBlockCallTableData,
    PrefetchHooks Function()>;

class $ServerDatabaseManager {
  final _$ServerDatabase _db;
  $ServerDatabaseManager(this._db);
  $$ServerAlarmTableTableManager get serverAlarm =>
      $$ServerAlarmTableTableManager(_db, _db.serverAlarm);
  $$ServerAlarmHistoryTableTableManager get serverAlarmHistory =>
      $$ServerAlarmHistoryTableTableManager(_db, _db.serverAlarmHistory);
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
  $$ServerMcpProposalTableTableTableManager get serverMcpProposalTable =>
      $$ServerMcpProposalTableTableTableManager(
          _db, _db.serverMcpProposalTable);
  $$PlcVarRefTableTableTableManager get plcVarRefTable =>
      $$PlcVarRefTableTableTableManager(_db, _db.plcVarRefTable);
  $$PlcFbInstanceTableTableTableManager get plcFbInstanceTable =>
      $$PlcFbInstanceTableTableTableManager(_db, _db.plcFbInstanceTable);
  $$PlcBlockCallTableTableTableManager get plcBlockCallTable =>
      $$PlcBlockCallTableTableTableManager(_db, _db.plcBlockCallTable);
}
