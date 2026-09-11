// Member-level tag gating: one permission question per member that actually
// moved.
//
// This file exists for one sentence — *a conveyor key locks `p_cfg_ManualFreq`
// while leaving `p_cmd_JogFwd` usable by an anonymous session* — and both of
// those go to the PLC through the same `stateMan.write(key, wholeStruct)`.
//
// Everything on the permission path is the shipped thing: a real
// `TagBindingResolver` (04-01) carrying spec §7b's `conveyor` template, a real
// `AccessPolicy` over it, real `AccessSession` values, the real
// `diffDynamicValue`, and the real `GuardedStateMan`. A hand-written
// `TagBindingLookup` closure would let the test pre-decide the answer the guard
// is supposed to be asking for; the point here is that the shipped resolver and
// the shipped guard agree.
//
// `guarded_state_man_test.dart` stays untouched as 03-04's regression baseline.
// The stand-ins below are deliberately a second, smaller copy rather than a
// shared harness: that file's journal is what pins the deny *ordering*, and
// this one must be free to change without disturbing it.

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// The two stand-ins
// ---------------------------------------------------------------------------

class _WriteCall {
  _WriteCall(this.key, this.value);
  final String key;
  final DynamicValue value;
}

/// A `StateMan` that records rather than talking to a PLC.
///
/// `noSuchMethod` is the repo's test idiom and is fine *here*: a test that
/// reaches an unwired member fails loudly in a test run. It is banned in
/// `guarded_state_man.dart`, where the same failure would land on a plant.
class _RecordingStateMan implements StateMan {
  final List<_WriteCall> writes = <_WriteCall>[];

  @override
  final Logger logger = Logger(level: Level.off);

  @override
  String resolveKey(String key) => key;

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add(_WriteCall(key, value));
  }

  @override
  Future<DynamicValue> read(String key) async => DynamicValue(value: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_RecordingStateMan: ${invocation.memberName} is not wired in this '
        'test. Wire it rather than reaching for a looser fake.',
      );
}

class _RecordingAuditSink implements AuditSink {
  final List<AuditRecord> rows = <AuditRecord>[];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// An `AccessPolicy` that records what it was asked, answering from the real
/// resolver underneath.
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
// Sessions, keys and values
// ---------------------------------------------------------------------------

/// The conveyor key the whole phase turns on. One key, two permissions.
const String _conveyor = 'CN04.MOT01.HMI';

/// A key no template binds.
const String _unbound = 'CN05.MOT01.HMI';

/// Nobody signed in. Anonymous is the `Operator` role by construction, and on
/// this plant that role holds `operate` and nothing else.
final AccessSession _anonymous =
    AccessSession.anonymous(const {AccessGroup.operate});

/// A signed-in shift leader: operate plus setpoints.
final AccessSession _shiftLeader = AccessSession(
  user: const AuthenticatedUser(
    username: 'gudrun',
    roleName: 'Shift Leader',
    displayName: 'Guðrún',
  ),
  groups: const {AccessGroup.operate, AccessGroup.setpoints},
  expiresAt: DateTime.utc(2030),
);

/// A session holding nothing at all, so a write moving two restricted members
/// is missing *both* groups and the strictest-of-them rule has something to
/// choose between.
const AccessSession _nobody = AccessSession(groups: <AccessGroup>{});

/// Spec §7b's worked example, verbatim.
AccessTemplate _conveyorTemplate() => AccessTemplate(
      name: 'conveyor',
      rules: const {
        'p_cmd_JogFwd': AccessGroup.operate,
        'p_cmd_JogBwd': AccessGroup.operate,
        'p_cmd_FaultReset': AccessGroup.operate,
        'p_cfg_ManualFreq': AccessGroup.setpoints,
        'p_cfg_AutoFreq': AccessGroup.setpoints,
      },
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

/// The conveyor struct as it sits in the PLC before any of these writes.
DynamicValue _conveyorBaseline() => _struct({
      'p_cmd_JogFwd': false,
      'p_cmd_JogBwd': false,
      'p_cmd_FaultReset': false,
      'p_cfg_ManualFreq': 42.5,
      'p_cfg_AutoFreq': 50.0,
      'p_stat_Running': false,
    });

void main() {
  late _RecordingStateMan inner;
  late _RecordingAuditSink audit;
  late _RecordingPolicy policy;
  late TagBindingResolver resolver;
  late AccessSession current;

  /// What `readBaseline` answers, per key. A key absent from this map has no
  /// baseline at all — the fallback case.
  late Map<String, DynamicValue> baselines;

  /// When true, the baseline reader throws, which the guard treats exactly as
  /// no baseline.
  late bool baselineThrows;

  setUp(() {
    inner = _RecordingStateMan();
    audit = _RecordingAuditSink();
    resolver = TagBindingResolver();
    policy = _RecordingPolicy(tagBindings: resolver.groupFor);
    current = _anonymous;
    baselines = <String, DynamicValue>{};
    baselineThrows = false;
  });

  /// Binds [_conveyor] to [template] and nothing else.
  void bindConveyorTo(AccessTemplate template) {
    resolver.setSnapshot(
      keyToTemplate: {_conveyor: template.name},
      templates: {template.name: template},
    );
  }

  GuardedStateMan build({bool withBaseline = true}) => GuardedStateMan(
        inner: inner,
        policy: policy,
        session: () => current,
        audit: audit,
        station: 'SVN-NES-OT-CL02',
        readBaseline: withBaseline
            ? (key) async {
                if (baselineThrows) throw StateError('PLC not answering');
                return baselines[key];
              }
            : null,
        logger: Logger(level: Level.off),
      );

  // -------------------------------------------------------------------------
  // Task 1 — the decision
  // -------------------------------------------------------------------------

  group('a conveyor key locks p_cfg_ManualFreq while leaving p_cmd_JogFwd '
      'usable by an anonymous session', () {
    setUp(() {
      bindConveyorTo(_conveyorTemplate());
      baselines[_conveyor] = _conveyorBaseline();
    });

    test('same key, same template, one write each: the jog lands and the '
        'frequency change is refused', () async {
      final guard = build();

      // The jog: the whole struct, with only p_cmd_JogFwd moved.
      await guard.write(
          _conveyor,
          _struct({
            'p_cmd_JogFwd': true,
            'p_cmd_JogBwd': false,
            'p_cmd_FaultReset': false,
            'p_cfg_ManualFreq': 42.5,
            'p_cfg_AutoFreq': 50.0,
            'p_stat_Running': false,
          }));

      expect(inner.writes, hasLength(1),
          reason: 'an anonymous operator must still be able to jog');

      // The frequency change: the same key, the same template, only
      // p_cfg_ManualFreq moved.
      await expectLater(
        guard.write(
            _conveyor,
            _struct({
              'p_cmd_JogFwd': false,
              'p_cmd_JogBwd': false,
              'p_cmd_FaultReset': false,
              'p_cfg_ManualFreq': 55.0,
              'p_cfg_AutoFreq': 50.0,
              'p_stat_Running': false,
            })),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.setpoints)
            .having((d) => d.itemKey, 'itemKey', _conveyor)),
      );

      expect(inner.writes, hasLength(1),
          reason: 'the refused write must reach inner.write never');
    });

    test('the lookup that decided it carried the member', () async {
      final guard = build();

      await guard.write(
          _conveyor,
          _struct({
            'p_cmd_JogFwd': true,
            'p_cmd_JogBwd': false,
            'p_cmd_FaultReset': false,
            'p_cfg_ManualFreq': 42.5,
            'p_cfg_AutoFreq': 50.0,
            'p_stat_Running': false,
          }));

      expect(policy.lookups, hasLength(1));
      expect(policy.lookups.single.member, 'p_cmd_JogFwd',
          reason: 'the guard asks about the member that moved, not the key');
      expect(policy.lookups.single.surface, 'tag');
      expect(policy.lookups.single.key, _conveyor);
    });

    test('an untouched restricted member imposes nothing', () async {
      final guard = build();

      // p_cfg_ManualFreq is present in the struct and holds its baseline
      // value. Gating the jog on a member that did not move would be the
      // guard causing the outage it exists to prevent.
      await guard.write(
          _conveyor,
          _struct({
            'p_cmd_JogFwd': true,
            'p_cmd_JogBwd': false,
            'p_cmd_FaultReset': false,
            'p_cfg_ManualFreq': 42.5,
            'p_cfg_AutoFreq': 50.0,
            'p_stat_Running': false,
          }));

      expect(inner.writes, hasLength(1));
      expect(policy.lookups.map((l) => l.member), ['p_cmd_JogFwd']);
    });

    test('a member no template rule mentions imposes nothing', () async {
      final guard = build();
      final baseline = _struct({
        'p_cmd_JogFwd': false,
        for (var i = 0; i < 20; i++) 'p_stat_Spare$i': i,
      });
      baselines[_conveyor] = baseline;

      await guard.write(
          _conveyor,
          _struct({
            'p_cmd_JogFwd': true,
            for (var i = 0; i < 20; i++) 'p_stat_Spare$i': i,
          }));

      expect(inner.writes, hasLength(1),
          reason: 'twenty untouched members gate nothing');
    });

    test('a write moving both members is refused and names the stricter '
        'group', () async {
      current = _nobody;
      final guard = build();

      await expectLater(
        guard.write(
            _conveyor,
            _struct({
              'p_cmd_JogFwd': true,
              'p_cmd_JogBwd': false,
              'p_cmd_FaultReset': false,
              'p_cfg_ManualFreq': 55.0,
              'p_cfg_AutoFreq': 50.0,
              'p_stat_Running': false,
            })),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.setpoints)),
      );

      expect(
          audit.rows.map((r) => r.groupRequired).toSet(), {'setpoints'},
          reason: 'both groups are missing; the rows name the stricter');
      expect(inner.writes, isEmpty);
    });

    test('a permitted write moving both members records the strictest group '
        'it required', () async {
      current = _shiftLeader;
      final guard = build();

      await guard.write(
          _conveyor,
          _struct({
            'p_cmd_JogFwd': true,
            'p_cmd_JogBwd': false,
            'p_cmd_FaultReset': false,
            'p_cfg_ManualFreq': 55.0,
            'p_cfg_AutoFreq': 50.0,
            'p_stat_Running': false,
          }));

      expect(inner.writes, hasLength(1));
      expect(audit.rows.map((r) => r.groupRequired).toSet(), {'setpoints'});
    });
  });

  group('an unbound key', () {
    test('still reaches inner.write unchanged and records the operate floor',
        () async {
      bindConveyorTo(_conveyorTemplate());
      baselines[_unbound] = _struct({'p_cfg_ManualFreq': 42.5});
      final guard = build();
      final value = _struct({'p_cfg_ManualFreq': 55.0});

      await guard.write(_unbound, value);

      expect(inner.writes, hasLength(1));
      expect(inner.writes.single.key, _unbound);
      expect(identical(inner.writes.single.value, value), isTrue);
      expect(audit.rows.single.groupRequired, 'operate',
          reason: 'an unbound key is floored at operate, not ungated');
    });
  });

  group('the no-baseline fallback — the one way member gating is bypassed',
      () {
    test('without a baseline a restricted member write is PERMITTED, which is '
        'the deliberate fail-open hole', () async {
      bindConveyorTo(_conveyorTemplate());
      // No entry in `baselines`, so `readBaseline` answers null and the diff
      // comes back as one change with a null member: the guard cannot know
      // which members moved.
      final guard = build();

      await guard.write(_conveyor, _struct({'p_cfg_ManualFreq': 55.0}));

      expect(inner.writes, hasLength(1),
          reason: 'THE COST, STATED: a setpoint write lands unchecked when the '
              'baseline read fails. Spec §7 makes tags fail open, and the '
              'strict reading would refuse an anonymous jog because a PLC read '
              'was slow. Tap-time elevation (04-06) is the operator path and '
              'needs no baseline; this guard is the backstop, and this is the '
              'hole in it.');
      expect(policy.lookups, hasLength(1));
      expect(policy.lookups.single.member, isNull,
          reason: 'the fallback is one key-level question, not one per rule');
    });

    test('a baseline read that throws falls open the same way', () async {
      bindConveyorTo(_conveyorTemplate());
      baselines[_conveyor] = _conveyorBaseline();
      baselineThrows = true;
      final guard = build();

      await guard.write(_conveyor, _struct({'p_cfg_ManualFreq': 55.0}));

      expect(inner.writes, hasLength(1));
    });

    test('with a whole-key row the fallback IS gated, so it is the key-level '
        'answer and not "no answer"', () async {
      bindConveyorTo(AccessTemplate(
        name: 'conveyor',
        rules: const {
          'p_cmd_JogFwd': AccessGroup.operate,
          'p_cfg_ManualFreq': AccessGroup.setpoints,
          kWholeKeyMember: AccessGroup.device,
        },
      ));
      final guard = build();

      await expectLater(
        guard.write(_conveyor, _struct({'p_cfg_ManualFreq': 55.0})),
        throwsA(isA<AccessDenied>()
            .having((d) => d.required, 'required', AccessGroup.device)),
      );

      expect(inner.writes, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Task 2 — the rows a member-gated write leaves behind
  // -------------------------------------------------------------------------

  group('the rows', () {
    setUp(() {
      bindConveyorTo(_conveyorTemplate());
      baselines[_conveyor] = _conveyorBaseline();
    });

    test('a permitted jog writes exactly one row, for the member that moved',
        () async {
      final guard = build();

      await guard.write(
          _conveyor,
          _struct({
            'p_cmd_JogFwd': true,
            'p_cmd_JogBwd': false,
            'p_cmd_FaultReset': false,
            'p_cfg_ManualFreq': 42.5,
            'p_cfg_AutoFreq': 50.0,
            'p_stat_Running': false,
          }));

      expect(audit.rows, hasLength(1));
      final row = audit.rows.single;
      expect(row.member, 'p_cmd_JogFwd');
      expect(row.oldValue, 'false');
      expect(row.newValue, 'true');
      expect(row.allowed, isTrue);
      expect(row.groupRequired, 'operate');
      expect(row.itemKey, _conveyor);
      expect(row.surface, 'tag');
    });

    test('a refused frequency change writes exactly one row and never reaches '
        'inner.write', () async {
      final guard = build();

      await expectLater(
        guard.write(
            _conveyor,
            _struct({
              'p_cmd_JogFwd': false,
              'p_cmd_JogBwd': false,
              'p_cmd_FaultReset': false,
              'p_cfg_ManualFreq': 55.0,
              'p_cfg_AutoFreq': 50.0,
              'p_stat_Running': false,
            })),
        throwsA(isA<AccessDenied>()),
      );

      expect(audit.rows, hasLength(1));
      final row = audit.rows.single;
      expect(row.member, 'p_cfg_ManualFreq');
      expect(row.oldValue, '42.5');
      expect(row.newValue, '55.0');
      expect(row.allowed, isFalse);
      expect(row.groupRequired, 'setpoints');
      expect(inner.writes, isEmpty);
    });

    test('a refused write that moved two members writes two rows under one '
        'action id', () async {
      current = _nobody;
      final guard = build();

      await expectLater(
        guard.write(
            _conveyor,
            _struct({
              'p_cmd_JogFwd': true,
              'p_cmd_JogBwd': false,
              'p_cmd_FaultReset': false,
              'p_cfg_ManualFreq': 55.0,
              'p_cfg_AutoFreq': 50.0,
              'p_stat_Running': false,
            })),
        throwsA(isA<AccessDenied>()),
      );

      expect(audit.rows, hasLength(2));
      expect(audit.rows.map((r) => r.member),
          containsAll(<String>['p_cmd_JogFwd', 'p_cfg_ManualFreq']));
      expect(audit.rows.map((r) => r.actionId).toSet(), hasLength(1),
          reason: 'one human action, two member rows');
      expect(audit.rows.every((r) => !r.allowed), isTrue);
      expect(audit.rows.every((r) => r.groupRequired == 'setpoints'), isTrue);
    });

    test('a refused write with an empty diff still writes exactly one row, '
        'with a null member', () async {
      bindConveyorTo(AccessTemplate(
        name: 'conveyor',
        rules: const {kWholeKeyMember: AccessGroup.device},
      ));
      final unchanged = _struct({'p_cmd_JogFwd': false});
      baselines[_conveyor] = _struct({'p_cmd_JogFwd': false});
      final guard = build();

      await expectLater(
        guard.write(_conveyor, unchanged),
        throwsA(isA<AccessDenied>()),
      );

      expect(audit.rows, hasLength(1),
          reason: "03-04's synthesised denial row, unchanged");
      expect(audit.rows.single.member, isNull);
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.groupRequired, 'device');
    });

    test('a permitted write that changed nothing records nothing and still '
        'reaches inner.write', () async {
      final guard = build();

      await guard.write(_conveyor, _conveyorBaseline());

      expect(audit.rows, isEmpty);
      expect(inner.writes, hasLength(1),
          reason: 'the no-op suppression is about the trail, not the plant');
    });

    test('a permitted write on an unbound key records its member rows with '
        'the operate floor', () async {
      baselines[_unbound] = _struct({
        'p_cmd_JogFwd': false,
        'p_cfg_ManualFreq': 42.5,
      });
      final guard = build();

      await guard.write(
          _unbound,
          _struct({
            'p_cmd_JogFwd': true,
            'p_cfg_ManualFreq': 55.0,
          }));

      expect(audit.rows, hasLength(2));
      expect(audit.rows.every((r) => r.groupRequired == 'operate'), isTrue);
      expect(audit.rows.every((r) => r.allowed), isTrue);
    });

    test('reads produce zero rows and are never gated', () async {
      final guard = build();

      await guard.read(_conveyor);

      expect(audit.rows, isEmpty);
      expect(policy.lookups, isEmpty);
    });
  });
}
