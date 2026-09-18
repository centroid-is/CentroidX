// The tag write guard: what it records, what it refuses, and what it leaves
// alone.
//
// Everything the guard touches is real — a real `AccessPolicy`, real
// `AccessSession` values, real `DynamicValue`s and the real
// `diffDynamicValue`. Only the two ends are stand-ins: the `StateMan` beneath
// it and the `AuditSink` beside it, both of which record into **one ordered
// journal** so that "the row was written before the delegate call" is an
// assertion about a list rather than a claim in a comment.

import 'dart:async';
import 'dart:io' show File;

import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// The journal
// ---------------------------------------------------------------------------

/// One ordered record of everything that happened, from both stand-ins.
///
/// Two separate lists could not answer "did the row precede the delegate
/// call?", which is the ordering spec §6 makes a requirement rather than an
/// illustration. So both the inner `StateMan` and the `AuditSink` append here.
class _Journal {
  final List<Object> entries = <Object>[];

  List<_WriteCall> get writes => entries.whereType<_WriteCall>().toList();
  List<AuditRecord> get rows => entries.whereType<AuditRecord>().toList();
  List<_ReadCall> get reads => entries.whereType<_ReadCall>().toList();

  /// Position of the first entry satisfying [test], or -1.
  int indexWhere(bool Function(Object) test) => entries.indexWhere(test);
}

class _WriteCall {
  _WriteCall(this.key, this.value);
  final String key;
  final DynamicValue value;
  @override
  String toString() => '_WriteCall($key)';
}

class _ReadCall {
  _ReadCall(this.key);
  final String key;
  @override
  String toString() => '_ReadCall($key)';
}

// ---------------------------------------------------------------------------
// The two stand-ins
// ---------------------------------------------------------------------------

/// A `StateMan` that records rather than talking to a PLC.
///
/// `noSuchMethod` is the repo's test idiom for this
/// (`start_stop_button_widget_test.dart:303`) and is fine *here*: a test that
/// reaches an unwired member fails loudly in a test run. It is banned in
/// `guarded_state_man.dart`, where the same failure would land on a plant.
class _RecordingStateMan implements StateMan {
  _RecordingStateMan(this._journal);

  final _Journal _journal;

  /// Keys whose resolution fails, as `resolveKey` fails for an unresolved
  /// substitution variable (`state_man.dart:1627`).
  final Set<String> unresolvable = <String>{};

  /// `write` -> `resolveKey` substitutions, so a test can tell the raw key the
  /// caller passed from the resolved key the audit row must carry.
  final Map<String, String> resolutions = <String, String>{};

  final Map<String, DynamicValue> readValues = <String, DynamicValue>{};

  @override
  final Logger logger = Logger(level: Level.off);

  @override
  String resolveKey(String key) {
    if (unresolvable.contains(key)) {
      throw StateManException('Unresolved substitution variable in "$key"');
    }
    return resolutions[key] ?? key;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    _journal.entries.add(_WriteCall(key, value));
    // The real `write` resolves first and throws before it reaches a client,
    // so a guard that delegated an unresolvable key must see that exception.
    if (unresolvable.contains(key)) {
      throw StateManException('Unresolved substitution variable in "$key"');
    }
  }

  @override
  Future<DynamicValue> read(String key) async {
    _journal.entries.add(_ReadCall(key));
    return readValues[key] ?? DynamicValue(value: 0);
  }

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    for (final key in keys) {
      _journal.entries.add(_ReadCall(key));
    }
    return {for (final key in keys) key: readValues[key] ?? DynamicValue(value: 0)};
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    _journal.entries.add(_ReadCall(key));
    return const Stream<DynamicValue>.empty();
  }

  @override
  List<String> get keys => const ['CN04.MOT01.HMI', 'CN05.MOT01.HMI'];

  @override
  Map<String, String> get substitutions => const {'station': 'CN04'};

  @override
  String? getSubstitution(String key) => substitutions[key];

  @override
  bool isKeyDisabled(String key) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_RecordingStateMan: ${invocation.memberName} is not wired in this '
        'test. Wire it rather than reaching for a looser fake.',
      );
}

/// A second, distinct `StateMan` type — the shape `innerAs<T>()` exists for.
///
/// The real caller is the Flutter app: `stateManProvider` wraps either a local
/// `StateMan` or a `GatewayStateMan` in a guard, and a gateway-only surface has
/// to be able to ask which one it got without being handed a write path.
/// `tfc_dart` knows nothing about that adapter, so the two-types-one-interface
/// situation is reproduced here instead: a guard over one of these answers
/// `innerAs<_GatewayLikeStateMan>()`, a guard over a plain
/// [_RecordingStateMan] answers null, and both directions are observable.
class _GatewayLikeStateMan extends _RecordingStateMan {
  _GatewayLikeStateMan(super.journal);

  /// The member the app reaches the hatch *for*: a fact about the transport
  /// that is not on `StateMan` and never will be. `RemoteStateMan.linkState`
  /// is the real one.
  String get linkFact => 'ready';
}

/// An `AuditSink` that appends into the shared journal.
///
/// [failWith] makes it throw, which the `AuditSink` interface does not forbid:
/// its non-throwing contract lives in a doc comment and `DriftAuditSink`
/// honours it, but a Phase 5 or relay implementation is free not to.
class _RecordingAuditSink implements AuditSink {
  _RecordingAuditSink(this._journal);

  final _Journal _journal;

  /// When non-null, every `record` call throws this instead of appending.
  Object? failWith;

  @override
  Future<void> record(AuditRecord entry) async {
    final failure = failWith;
    if (failure != null) throw failure;
    _journal.entries.add(entry);
  }
}

/// An `AccessPolicy` that records what it was asked.
///
/// A subclass rather than a fake, so the answers are the real policy's — the
/// only thing added is the log of `(surface, key, member)` triples, which is
/// what lets a test prove the surface that was *checked* is the surface that
/// was *recorded*.
class _RecordingPolicy extends AccessPolicy {
  _RecordingPolicy({super.tagBindings});

  final List<({String surface, String key, String? member})> lookups =
      <({String surface, String key, String? member})>[];

  @override
  AccessGroup groupForWireSurface(String surface, String key,
      {String? member}) {
    lookups.add((surface: surface, key: key, member: member));
    return super.groupForWireSurface(surface, key, member: member);
  }
}

// ---------------------------------------------------------------------------
// Sessions and values
// ---------------------------------------------------------------------------

/// Nobody signed in. Anonymous is the `Operator` role by construction.
final AccessSession _anonymous =
    AccessSession.anonymous(const {AccessGroup.operate});

/// A signed-in shift leader: operate plus setpoints, and nothing else.
final AccessSession _shiftLeader = AccessSession(
  user: const AuthenticatedUser(
    username: 'gudrun',
    roleName: 'Shift Leader',
    displayName: 'Guðrún',
  ),
  groups: const {AccessGroup.operate, AccessGroup.setpoints},
  expiresAt: DateTime.utc(2030),
);

/// A struct built the way the copy-on-write assets build one
/// (`conveyor.dart:2383`): a fresh value with members assigned by name.
DynamicValue _struct(Map<String, Object?> members) {
  final v = DynamicValue();
  members.forEach((key, value) {
    v[key] = value is DynamicValue ? value : DynamicValue(value: value);
  });
  return v;
}

/// A `TagBindingLookup` binding exactly [bound] to [group] and nothing else.
///
/// This is the injected lookup Phase 4's access templates will replace. It is
/// how Phase 3 tests a deny path that nothing turns on until then.
TagBindingLookup _bind(String bound, AccessGroup group) =>
    (String key, String? member) => key == bound ? group : null;

void main() {
  late _Journal journal;
  late _RecordingStateMan inner;
  late _RecordingAuditSink audit;
  late _RecordingPolicy policy;
  late AccessSession current;

  setUp(() {
    journal = _Journal();
    inner = _RecordingStateMan(journal);
    audit = _RecordingAuditSink(journal);
    policy = _RecordingPolicy();
    current = _anonymous;
  });

  GuardedStateMan build({
    AccessPolicy? withPolicy,
    String surface = 'tag',
    Future<DynamicValue?> Function(String key)? readBaseline,
    void Function(AccessDenied denial)? onDenied,
  }) =>
      GuardedStateMan(
        inner: inner,
        policy: withPolicy ?? policy,
        session: () => current,
        audit: audit,
        station: 'SVN-NES-OT-CL02',
        surface: surface,
        readBaseline: readBaseline,
        onDenied: onDenied,
        logger: Logger(level: Level.off),
      );

  group('the decorator', () {
    test('constructs and is a StateMan', () {
      expect(build(), isA<StateMan>());
    });

    test('reads produce zero audit rows and are never gated', () async {
      final guard = build();
      inner.readValues['CN04.MOT01.HMI'] = DynamicValue(value: 42);

      final value = await guard.read('CN04.MOT01.HMI');
      final many = await guard.readMany(['CN04.MOT01.HMI', 'CN05.MOT01.HMI']);
      await guard.subscribe('CN04.MOT01.HMI');

      expect(value.value, 42);
      expect(many.keys, ['CN04.MOT01.HMI', 'CN05.MOT01.HMI']);
      expect(journal.reads, hasLength(4));
      expect(journal.rows, isEmpty,
          reason: 'spec §11 defers read permissions; a read is neither gated '
              'nor recorded');
    });

    test('the non-write members return exactly what inner returns', () {
      final guard = build();

      expect(guard.keys, inner.keys);
      expect(guard.substitutions, inner.substitutions);
      expect(guard.getSubstitution('station'), 'CN04');
      expect(guard.isKeyDisabled('CN04.MOT01.HMI'), isFalse);
      expect(guard.resolveKey('CN04.MOT01.HMI'), 'CN04.MOT01.HMI');
      expect(identical(guard.logger, inner.logger), isTrue);
      expect(journal.rows, isEmpty);
    });
  });

  group('the allow path', () {
    test('an unbound key reaches inner.write with the same key and value',
        () async {
      final guard = build();
      final value = DynamicValue(value: true);

      await guard.write('CN04.MOT01.HMI.p_cmd_Start', value);

      expect(journal.writes, hasLength(1));
      expect(journal.writes.single.key, 'CN04.MOT01.HMI.p_cmd_Start');
      expect(identical(journal.writes.single.value, value), isTrue);
    });

    test('the group lookup goes through groupForWireSurface with the guard\'s '
        'own surface', () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      expect(policy.lookups, hasLength(1));
      expect(policy.lookups.single.surface, 'tag');
      expect(policy.lookups.single.key, 'CN04.MOT01.HMI.p_cmd_Start');
    });

    test('the surface that was checked is the surface that was recorded',
        () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      expect(policy.lookups, hasLength(1));
      expect(journal.rows, isNotEmpty);
      for (final row in journal.rows) {
        expect(row.surface, policy.lookups.single.surface,
            reason: 'a guard that audits one surface while checking another '
                'is worse than no audit');
      }
    });

    test('a permitted write carries who, station, role, origin and allowed',
        () async {
      current = _shiftLeader;
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      final row = journal.rows.single;
      expect(row.who, 'gudrun');
      expect(row.station, 'SVN-NES-OT-CL02');
      expect(row.roleName, 'Shift Leader');
      expect(row.origin, 'operator');
      expect(row.allowed, isTrue);
      expect(row.actionId, isNotEmpty);
    });

    test('an anonymous session is recorded as anonymous in the Operator role',
        () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      expect(journal.rows.single.who, 'anonymous');
      expect(journal.rows.single.roleName, kOperatorRoleName);
    });

    test('an unbound key REFUSES a session without operate — the floor is '
        'enforced, not just recorded', () async {
      current = AccessSession.anonymous(const {AccessGroup.device});
      final guard = build();

      await expectLater(
        guard.write('CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)),
        throwsA(isA<AccessDenied>()),
      );

      expect(journal.writes, isEmpty,
          reason: 'the hq-skjar hole: a role stripped of operate could still '
              'toggle any unbound key. No operate, no write.');
      expect(journal.rows.single.allowed, isFalse);
      expect(journal.rows.single.groupRequired, 'operate');
    });

    test('an unbound key records the operate floor as groupRequired',
        () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      expect(journal.rows.single.groupRequired, 'operate',
          reason: '2026-09-02 ruling: no tag write is ungated. The empty '
              'string is reserved for the auth rows, and it is what made '
              'unbound writes invisible to every group chip on the trail '
              'page.');
    });

    test('the audited itemKey is the resolved key', () async {
      inner.resolutions['{station}.MOT01.HMI.p_cmd_Start'] =
          'CN04.MOT01.HMI.p_cmd_Start';
      final guard = build();

      await guard.write(
          '{station}.MOT01.HMI.p_cmd_Start', DynamicValue(value: true));

      expect(journal.rows.single.itemKey, 'CN04.MOT01.HMI.p_cmd_Start');
      expect(policy.lookups.single.key, 'CN04.MOT01.HMI.p_cmd_Start');
      expect(journal.writes.single.key, '{station}.MOT01.HMI.p_cmd_Start',
          reason: 'the guard sits outside StateMan.write, which resolves the '
              'key itself');
    });

    test('when resolveKey throws, nothing is audited and the exception is the '
        "inner StateMan's own", () async {
      inner.unresolvable.add('{station}.MOT01.HMI.p_cmd_Start');
      final guard = build();

      await expectLater(
        guard.write('{station}.MOT01.HMI.p_cmd_Start',
            DynamicValue(value: true)),
        throwsA(isA<StateManException>()),
      );

      expect(journal.rows, isEmpty);
      expect(journal.writes, hasLength(1),
          reason: 'the guard must not swallow an unresolved key: the caller '
              "sees StateMan's own exception, unchanged");
    });

    test('the audit row is written before the delegate call', () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      final rowAt = journal.indexWhere((e) => e is AuditRecord);
      final writeAt = journal.indexWhere((e) => e is _WriteCall);
      expect(rowAt, isNonNegative);
      expect(writeAt, isNonNegative);
      expect(rowAt, lessThan(writeAt),
          reason: 'spec §6: the row records that the action was authorized, '
              'and losing that evidence because the PLC blinked is the worse '
              'failure');
    });

    test('an audit sink that throws does not prevent a permitted write',
        () async {
      audit.failWith = StateError('the audit database blinked');
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));

      expect(journal.rows, isEmpty);
      expect(journal.writes, hasLength(1));
    });

    test('each write mints one action id, and two writes never share one',
        () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));
      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: false));

      expect(journal.rows, hasLength(2));
      expect(journal.rows[0].actionId, isNot(journal.rows[1].actionId));
    });

    test('the session is read at each write, so a change between two writes '
        'is seen by the second', () async {
      final guard = build();

      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: true));
      current = _shiftLeader;
      await guard.write('CN04.MOT01.HMI.p_cmd_Start',
          DynamicValue(value: false));

      expect(journal.rows[0].who, 'anonymous');
      expect(journal.rows[1].who, 'gudrun',
          reason: 'a captured AccessSession would keep granting whatever the '
              'operator held when the provider was built');
    });

    test('with no baseline a write is one row flagged as having none',
        () async {
      final guard = build();

      await guard.write(
          'CN04.MOT01.HMI', _struct({'p_cmd_JogFwd': true, 'p_cfg_Freq': 42.5}));

      expect(journal.rows, hasLength(1));
      expect(journal.rows.single.member, isNull);
      expect(journal.rows.single.oldValue, isNull);
      expect(journal.rows.single.newValue, contains('p_cmd_JogFwd'));
    });
  });

  group('the deny path', () {
    // The binding is injected. Phase 4's access templates are what turn this
    // on for real; until then this is how the path is exercised at all.
    late _RecordingPolicy bound;

    setUp(() {
      bound = _RecordingPolicy(
        tagBindings: _bind('CN04.MOT01.HMI.p_cmd_Start', AccessGroup.configure),
      );
    });

    test('a bound key the session cannot write never reaches inner.write',
        () async {
      final guard = build(withPolicy: bound);

      await expectLater(
        guard.write('CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)),
        throwsA(isA<AccessDenied>()),
      );

      expect(journal.writes, isEmpty);
    });

    test('the refusal is recorded with allowed false and the group name',
        () async {
      final guard = build(withPolicy: bound);

      await expectLater(
        guard.write('CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)),
        throwsA(isA<AccessDenied>()),
      );

      final row = journal.rows.single;
      expect(row.allowed, isFalse);
      expect(row.groupRequired, AccessGroup.configure.name);
      expect(row.itemKey, 'CN04.MOT01.HMI.p_cmd_Start');
      expect(row.who, 'anonymous');
    });

    test('the rows are written before the exception is raised, and survive it',
        () async {
      final guard = build(withPolicy: bound);
      Object? raised;

      try {
        await guard.write(
            'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true));
      } on Object catch (e) {
        raised = e;
      }

      // Both, in that order - not one or the other. A denial that leaves no
      // row is the repudiation this path exists to close.
      expect(journal.rows, isNotEmpty,
          reason: 'the row is the only evidence the guard fired');
      expect(raised, isA<AccessDenied>());
      expect(journal.indexWhere((e) => e is AuditRecord), isNonNegative);
    });

    test('the exception carries the resolved key and the required group',
        () async {
      inner.resolutions['{station}.MOT01.HMI.p_cmd_Start'] =
          'CN04.MOT01.HMI.p_cmd_Start';
      final guard = build(withPolicy: bound);

      final denial = await _denialFrom(guard.write(
          '{station}.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)));

      expect(denial.itemKey, 'CN04.MOT01.HMI.p_cmd_Start');
      expect(denial.required, AccessGroup.configure);
    });

    test('onDenied fires exactly once, with the same denial, before the throw',
        () async {
      final seen = <AccessDenied>[];
      final guard = build(
        withPolicy: bound,
        onDenied: (d) {
          seen.add(d);
          journal.entries.add(_DeniedEvent(d));
        },
      );

      final denial = await _denialFrom(guard.write(
          'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)));

      expect(seen, hasLength(1));
      expect(identical(seen.single, denial), isTrue);
      expect(journal.indexWhere((e) => e is _DeniedEvent), isNonNegative,
          reason: 'plan 03-07 owns the prompt; this owns firing the event, '
              'and it must fire even where the exception escapes uncaught');
    });

    test('a null onDenied changes nothing else', () async {
      final guard = build(withPolicy: bound);

      await expectLater(
        guard.write('CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)),
        throwsA(isA<AccessDenied>()),
      );

      expect(journal.rows, hasLength(1));
      expect(journal.writes, isEmpty);
    });

    test('an onDenied that throws does not replace the AccessDenied', () async {
      final guard = build(
        withPolicy: bound,
        onDenied: (_) => throw StateError('a listener bug'),
      );

      final raised = await _raisedFrom(guard.write(
          'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)));

      expect(raised, isA<AccessDenied>(),
          reason: "a listener's bug must not change what the caller sees");
      expect(journal.writes, isEmpty);
    });

    test(
        'an audit sink that throws on the deny path still denies, and still '
        'fires onDenied', () async {
      audit.failWith = StateError('the audit database blinked');
      var fired = 0;
      final guard = build(withPolicy: bound, onDenied: (_) => fired += 1);

      final raised = await _raisedFrom(guard.write(
          'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)));

      expect(raised, isA<AccessDenied>(),
          reason: 'a sink exception must not replace the refusal, or the '
              'operator gets no prompt and no explanation for a control that '
              'did nothing');
      expect(fired, 1);
      expect(journal.writes, isEmpty);
    });

    test(
        'a bound key the session can write proceeds as an unbound one, with '
        'the group name recorded', () async {
      final operateBound = _RecordingPolicy(
        tagBindings: _bind('CN04.MOT01.HMI.p_cmd_Start', AccessGroup.operate),
      );
      final guard = build(withPolicy: operateBound);

      await guard.write(
          'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true));

      expect(journal.writes, hasLength(1));
      expect(journal.rows.single.allowed, isTrue);
      expect(journal.rows.single.groupRequired, AccessGroup.operate.name);
    });

    test(
        're-pressing Start on an already-started machine: a denied write '
        'whose diff is empty still produces exactly one row', () async {
      final guard = build(
        withPolicy: bound,
        readBaseline: (_) async => DynamicValue(value: true),
      );

      final raised = await _raisedFrom(guard.write(
          'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)));

      expect(raised, isA<AccessDenied>());
      expect(journal.rows, hasLength(1),
          reason: 'no-op suppression is the permitted path only; deleting '
              'this row would make the guard invisible in exactly the case an '
              'operator is most likely to repeat');
      expect(journal.rows.single.member, isNull);
      expect(journal.rows.single.allowed, isFalse);
      expect(journal.rows.single.newValue, 'true');
      expect(journal.writes, isEmpty);
    });

    test(
        'a refused write with no baseline produces exactly one row, flagged '
        'as having none', () async {
      final guard = build(withPolicy: bound);

      final raised = await _raisedFrom(guard.write('CN04.MOT01.HMI.p_cmd_Start',
          _struct({'p_cmd_Start': true, 'p_cfg_Freq': 42.5})));

      expect(raised, isA<AccessDenied>());
      expect(journal.rows, hasLength(1));
      // At the row level a missing baseline is a whole-value row: no member
      // path and no old side. That is the same shape a synthesised denial row
      // takes, deliberately - both say "the whole value, nothing to compare".
      expect(journal.rows.single.member, isNull);
      expect(journal.rows.single.oldValue, isNull);
      expect(journal.rows.single.newValue, isNotNull);
    });

    test('a refused struct write still produces its member rows', () async {
      final guard = build(
        withPolicy: bound,
        readBaseline: (_) async =>
            _struct({'p_cmd_Start': false, 'p_cfg_Freq': 25.0}),
      );

      final raised = await _raisedFrom(guard.write(
          'CN04.MOT01.HMI.p_cmd_Start',
          _struct({'p_cmd_Start': true, 'p_cfg_Freq': 42.5})));

      expect(raised, isA<AccessDenied>());
      expect(journal.rows.map((r) => r.member),
          containsAll(<String>['p_cmd_Start', 'p_cfg_Freq']),
          reason: 'a denied recipe apply must show what would have changed');
      expect(journal.rows.every((r) => r.allowed == false), isTrue);
      expect(journal.writes, isEmpty);
    });

    test('a surface the policy does not know fails closed on administer',
        () async {
      final guard = build(surface: 'gizmo');

      final denial = await _denialFrom(guard.write(
          'CN04.MOT01.HMI.p_cmd_Start', DynamicValue(value: true)));

      expect(denial.required, AccessGroup.administer);
      expect(journal.rows.single.surface, 'gizmo',
          reason:
              'the surface checked and the surface recorded are one string');
      expect(journal.rows.single.groupRequired, AccessGroup.administer.name);
    });
  });

  group('struct writes', () {
    test(
        'a permitted struct write is one row per changed member, with dotted '
        'paths, sharing one action id', () async {
      final guard = build(
        readBaseline: (_) async => _struct({
          'p_cmd_JogFwd': false,
          'p_cfg': _struct({'Freq': 25.0, 'Ramp': 3.0}),
        }),
      );

      await guard.write(
          'CN04.MOT01.HMI',
          _struct({
            'p_cmd_JogFwd': true,
            'p_cfg': _struct({'Freq': 42.5, 'Ramp': 3.0}),
          }));

      expect(journal.rows, hasLength(2));
      expect(journal.rows.map((r) => r.member), ['p_cmd_JogFwd', 'p_cfg.Freq']);
      expect(journal.rows[0].oldValue, 'false');
      expect(journal.rows[0].newValue, 'true');
      expect(journal.rows[1].oldValue, '25.0');
      expect(journal.rows[1].newValue, '42.5');
      expect(journal.rows[0].actionId, journal.rows[1].actionId,
          reason: 'one human action is one correlation id with N rows beneath');
      expect(journal.writes, hasLength(1));
    });

    test(
        'a permitted write whose value equals the baseline writes no rows and '
        'still reaches inner.write', () async {
      final guard = build(
        readBaseline: (_) async =>
            _struct({'p_cmd_Start': true, 'p_cfg_Freq': 42.5}),
      );

      await guard.write('CN04.MOT01.HMI',
          _struct({'p_cmd_Start': true, 'p_cfg_Freq': 42.5}));

      expect(journal.rows, isEmpty,
          reason: "spec section 2's no-op suppression suppresses the rows");
      expect(journal.writes, hasLength(1),
          reason: 'and not the write: a re-issued command after a comms blip '
              'is a real action with a real effect at the PLC');
    });

    test(
        'a readBaseline that throws is treated as no baseline and the write '
        'is unaffected', () async {
      final guard = build(
        readBaseline: (_) async => throw StateError('the server went away'),
      );

      await guard.write('CN04.MOT01.HMI',
          _struct({'p_cmd_Start': true, 'p_cfg_Freq': 42.5}));

      expect(journal.rows, hasLength(1));
      expect(journal.rows.single.member, isNull);
      expect(journal.rows.single.oldValue, isNull);
      expect(journal.writes, hasLength(1));
    });

    test(
        'a readBaseline that never answers times out and is treated as no '
        'baseline', () async {
      final stuck = Completer<DynamicValue?>();
      addTearDown(() {
        if (!stuck.isCompleted) stuck.complete(null);
      });
      final guard = build(readBaseline: (_) => stuck.future);

      await guard.write('CN04.MOT01.HMI',
          _struct({'p_cmd_Start': true, 'p_cfg_Freq': 42.5}));

      expect(journal.rows, hasLength(1));
      expect(journal.rows.single.oldValue, isNull);
      expect(journal.writes, hasLength(1),
          reason: 'making a jog wait on a PLC round trip that is not '
              'answering would trade a usability feature for an outage');
    });
  });

  // ---------------------------------------------------------------------
  // The read-only escape hatch
  // ---------------------------------------------------------------------
  //
  // `implements StateMan` is what makes the guard invisible to its callers,
  // and it is also what makes the object underneath unreachable: `_inner` is
  // private and every one of the ~20 forwarded members hands back the inner's
  // *answer*, never the inner. That is correct for everything on the
  // interface. It is wrong for the handful of facts that are not on it at
  // all — a transport's link state, a clock offset — which have no forwarding
  // member to come back through and never will, because they do not exist on
  // `StateMan`.
  //
  // `innerAs<T>()` is the narrow answer: the caller must name the type it
  // wants, and gets null rather than a `StateMan` when the inner object is
  // something else. The alternative that was rejected in writing is a bare
  // `inner` getter, which hands out an object whose `write` skips the access
  // check and the audit row — the two things this class exists to add.
  group('innerAs', () {
    /// A guard over [target], with everything else exactly as [build] has it.
    GuardedStateMan guardOver(StateMan target, {AccessPolicy? withPolicy}) =>
        GuardedStateMan(
          inner: target,
          policy: withPolicy ?? policy,
          session: () => current,
          audit: audit,
          station: 'SVN-NES-OT-CL02',
          logger: Logger(level: Level.off),
        );

    test('returns the inner object when it is a T', () {
      final gateway = _GatewayLikeStateMan(journal);
      final guard = guardOver(gateway);

      final unwrapped = guard.innerAs<_GatewayLikeStateMan>();

      expect(identical(unwrapped, gateway), isTrue,
          reason: 'a copy, a re-wrap or a second decorator would all satisfy '
              'a type check and none of them would be the object holding the '
              'live socket');
      expect(unwrapped!.linkFact, 'ready',
          reason: 'the member the hatch exists for is one the guard has no '
              'forwarding member for; reaching it is the whole point');
    });

    test('returns null for a type the inner object is not', () {
      final guard = guardOver(inner);

      // Anti-vacuity. If the two stand-ins were the same type the assertion
      // below would pass for the wrong reason and keep passing after the
      // accessor stopped discriminating.
      expect(inner, isNot(isA<_GatewayLikeStateMan>()),
          reason: 'the inner object must genuinely not be the type asked for, '
              'or the null below proves nothing');

      expect(guard.innerAs<_GatewayLikeStateMan>(), isNull,
          reason: 'a station in direct mode holds a local StateMan, and a '
              'gateway-only surface asking for the adapter must be told no '
              'rather than handed something it will cast');
    });

    test('is inert: obtaining a handle writes nothing and arms no bypass',
        () async {
      const key = 'CN04.MOT01.HMI.p_cmd_Start';
      final denying =
          _RecordingPolicy(tagBindings: _bind(key, AccessGroup.administer));
      final gateway = _GatewayLikeStateMan(journal);
      final guard = guardOver(gateway, withPolicy: denying);

      final before =
          await _denialFrom(guard.write(key, DynamicValue(value: true)));
      final journalledBefore = journal.entries.length;

      final handle = guard.innerAs<_GatewayLikeStateMan>();
      expect(handle, isNotNull);

      expect(journal.entries, hasLength(journalledBefore),
          reason: 'the accessor is a type test and a field read: it must not '
              'reach the inner object, the policy or the audit sink');

      final after =
          await _denialFrom(guard.write(key, DynamicValue(value: true)));

      expect(after.itemKey, before.itemKey);
      expect(journal.writes, isEmpty,
          reason: 'this arm does NOT prove the returned handle cannot be '
              'misused — nothing in Dart can, and the doc beside innerAs is '
              'the fence for that. It proves the accessor itself is inert: '
              'taking a handle changes no state and leaves the guard denying '
              'exactly what it denied before');
    });
  });

  group('the source', () {
    test('carries no noSuchMethod', () {
      expect(_guardSourceWithoutComments(), isNot(contains('noSuchMethod')),
          reason: 'a noSuchMethod decorator answers a member nobody wired by '
              'throwing at runtime, on a plant');
    });
  });

  group('forwards every public member', () {
    test('the derived member list is not empty', () {
      // First, and in its own test: an assertion that silently reads nothing
      // is the failure mode this whole phase is about. Everything below is
      // vacuous if this is.
      expect(stateManPublicMembers(), isNotEmpty,
          reason: 'the member list is derived from state_man.dart at test '
              'time. An empty list means the file moved or the class head '
              'changed shape, not that StateMan has no members.');
    });

    test('the derived list contains the members it obviously must', () {
      // A second guard against a regex that reads the file and finds almost
      // nothing: these five are a field, a mutable field, a getter, a method
      // and the intercepted member, so a derivation that lost any *kind* of
      // declaration fails here rather than passing with a short list.
      expect(
          stateManPublicMembers(),
          containsAll(<String>[
            'config',
            'alias',
            'substitutions',
            'resolveKey',
            'write',
          ]));
    });

    test('every public member of StateMan is an @override member of the guard',
        () {
      final declared = stateManPublicMembers();
      final forwarded = guardOverriddenMembers();
      final missing = declared.difference(forwarded);

      expect(missing, isEmpty,
          reason: 'GuardedStateMan implements StateMan by writing every '
              'member out. A member added to StateMan and not forwarded here '
              'is a hole that only shows up when somebody calls it, on a '
              'plant. Add it to guarded_state_man.dart.\n'
              'Derived from state_man.dart: ${declared.toList()..sort()}\n'
              'Found in guarded_state_man.dart: '
              '${forwarded.toList()..sort()}');
    });

    test('the guard overrides nothing StateMan no longer declares', () {
      // The other direction. A member removed from StateMan leaves a dead
      // @override behind that no longer compiles - but this says so in words
      // rather than as an inscrutable analyzer error, and it catches a
      // renamed member before the build does.
      expect(guardOverriddenMembers().difference(stateManPublicMembers()),
          isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// The forwarding-completeness derivation
// ---------------------------------------------------------------------------
//
// "Callers change nothing" is checked here rather than asserted in a doc
// comment. Both sides are read from source at test time with comment lines
// stripped, because otherwise the comment explaining the rule would be free to
// satisfy the test enforcing it.

/// Members of `StateMan` that [GuardedStateMan] does not have to forward, and
/// why. An explicit list rather than a regex nobody can read.
const Map<String, String> kNotPartOfTheInterface = <String, String>{
  'applyBitMask': 'static, so not part of the implicit interface',
  'create': 'a static factory, not an instance member',
  'StateMan': 'the class name, if a declaration line ever yields it',
};

/// Anything starting with an underscore is private and invisible to
/// `implements`, so it is filtered rather than listed: `StateMan._` (the
/// constructor), `_subscriptions`, `_monitor` and the rest.
bool _isPrivate(String name) => name.startsWith('_');

/// A method or setter declaration at two-space indent: a type, a name, then a
/// parenthesis. `set alias(String v)` matches with `set` as the type.
final RegExp _methodDecl =
    RegExp(r'^  (?! )(?:static\s+)?[\w$<>?,\[\] ]+\s+([a-zA-Z_$][\w$]*)\s*\(');

/// A getter declaration at two-space indent.
final RegExp _getterDecl =
    RegExp(r'^  (?! ).*\bget\s+([a-zA-Z_$][\w$]*)\s*(?:=>|\{|;)');

/// A field declaration at two-space indent: an optional type, a name, then an
/// initializer or a semicolon. `=[^>]` keeps it from swallowing a `=>` getter.
final RegExp _fieldDecl = RegExp(
    r'^  (?! )(?:late\s+)?(?:final\s+|const\s+|static\s+)*(?:[\w$<>?,\[\] ]+\s+)?'
    r'([a-zA-Z_$][\w$]*)\s*(?:=[^>]|;)');

/// [path]'s lines with every whole-line comment dropped.
///
/// Whole-line only, which is all that is needed and all that is honest: a
/// trailing `// ...` cannot fabricate a declaration, and a doc comment
/// mentioning a member name can.
List<String> _sourceLinesWithoutComments(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: 'Run this suite from packages/tfc_dart. Without $path these '
          'source assertions would pass vacuously.');
  return file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .toList();
}

/// The body of `class [name]` in [lines], from the head to its closing brace.
///
/// Matches an `abstract interface class` head as well as a plain one, because
/// [StateMan] is now the former: the contract this suite checks the guard
/// against is declared in `state_man_types.dart` and implemented three times
/// over (OPC UA, gateway, guard).
List<String> _classBody(List<String> lines, String name) {
  final start = lines.indexWhere((l) {
    final head = l.trimRight();
    return head == 'class $name {' || head == 'abstract interface class $name {';
  });
  expect(start, isNonNegative,
      reason: 'could not find the head of class $name; the derivation below '
          'would silently read nothing');
  final end = lines.indexWhere((l) => l == '}', start + 1);
  expect(end, isNonNegative, reason: 'class $name has no closing brace');
  return lines.sublist(start + 1, end);
}

/// The name declared on [line], or null when it declares nothing.
String? _declaredName(String line) {
  for (final pattern in [_methodDecl, _getterDecl, _fieldDecl]) {
    final match = pattern.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// Every public instance member of `StateMan`, derived from its source.
Set<String> stateManPublicMembers() {
  final body = _classBody(
      _sourceLinesWithoutComments('lib/core/state_man_types.dart'), 'StateMan');
  return {
    for (final line in body)
      if (_declaredName(line) case final name?)
        if (!_isPrivate(name) && !kNotPartOfTheInterface.containsKey(name))
          name,
  };
}

/// Every member `GuardedStateMan` declares with `@override`.
///
/// The annotation is what is counted, not the presence of the name anywhere in
/// the file: a name in a doc comment is stripped before this runs, and a
/// private helper that happens to share a name is not an override.
Set<String> guardOverriddenMembers() {
  final body = _classBody(
      _sourceLinesWithoutComments('lib/core/access/guarded_state_man.dart'),
      'GuardedStateMan implements StateMan');
  final names = <String>{};
  for (var i = 0; i < body.length; i++) {
    if (body[i].trim() != '@override') continue;
    // Skip any further annotations (`@visibleForTesting`) and blank lines.
    var j = i + 1;
    while (j < body.length &&
        (body[j].trim().isEmpty || body[j].trim().startsWith('@'))) {
      j++;
    }
    if (j >= body.length) continue;
    final name = _declaredName(body[j]);
    if (name != null) names.add(name);
  }
  return names;
}

/// An `onDenied` firing, journalled so its position relative to the rows and
/// the throw is assertable.
class _DeniedEvent {
  _DeniedEvent(this.denial);
  final AccessDenied denial;
  @override
  String toString() => '_DeniedEvent(${denial.itemKey})';
}

/// The [AccessDenied] [future] threw, failing the test if it threw something
/// else or nothing at all.
Future<AccessDenied> _denialFrom(Future<void> future) async {
  final raised = await _raisedFrom(future);
  expect(raised, isA<AccessDenied>());
  return raised as AccessDenied;
}

/// Whatever [future] threw, failing the test if it completed.
Future<Object> _raisedFrom(Future<void> future) async {
  try {
    await future;
  } on Object catch (e) {
    return e;
  }
  fail('expected the write to throw, and it completed');
}

/// The guard's own source, with comment lines removed.
///
/// The comment stripping is what makes every source assertion here honest:
/// otherwise a comment explaining why there is no `noSuchMethod` would itself
/// fail the test enforcing that there is none.
String _guardSourceWithoutComments() {
  final file = File('lib/core/access/guarded_state_man.dart');
  expect(file.existsSync(), isTrue,
      reason: 'Run this suite from packages/tfc_dart. Without the file these '
          'source assertions would pass vacuously.');
  return file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
