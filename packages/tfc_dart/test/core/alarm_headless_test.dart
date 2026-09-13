// `AlarmMan` built without a store: what it can do, and what it refuses.
//
// The 04-12 shape. The acquisition backend reads `alarm_man_config` as a
// value and never holds a preferences object, because the only things that
// object was ever used for here are the alarm editor's — and a headless
// process editing shared configuration would be a second author with none of
// a station's checked group, `origin` or audit row behind the write.
//
// The refusal is the part worth pinning. A `_saveConfig` that quietly did
// nothing when there is no store is the green-snackbar failure this milestone
// exists to end: the operator is told the alarm was saved, the in-memory list
// changes, and the next restart has never heard of it.

import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/state_man.dart';

Future<StateMan> _emptyStateMan() => StateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {}),
      useIsolate: false,
      alias: 'alarm-headless-test',
    );

AlarmConfig _anAlarm(String uid) => AlarmConfig(
      uid: uid,
      title: 'a title',
      description: 'a description',
      rules: [],
    );

void main() {
  late StateMan stateMan;

  setUp(() async {
    stateMan = await _emptyStateMan();
  });
  tearDown(() => stateMan.close());

  test('takes its configuration as a value, with no store to read it from',
      () async {
    final man = await AlarmMan.headless(
      config: AlarmManConfig(alarms: [_anAlarm('CN01.Jam')]),
      stateMan: stateMan,
    );

    expect(man.config.alarms.single.uid, 'CN01.Jam');
    expect(man.preferences, isNull,
        reason: 'the headless constructor takes no store, so there is nothing '
            'here that could write the plant a default');
  });

  test('an absent configuration is zero alarms, not a refusal to build',
      () async {
    // The backend decides what absence means (marker present → genuinely
    // empty; marker absent → unmigrated) and passes the empty config either
    // way. Both run: alarms are one function of a process whose job is
    // acquisition.
    final man = await AlarmMan.headless(
      config: AlarmManConfig(alarms: []),
      stateMan: stateMan,
    );
    expect(man.config.alarms, isEmpty);
  });

  test('editing throws rather than silently dropping the write', () async {
    final man = await AlarmMan.headless(
      config: AlarmManConfig(alarms: []),
      stateMan: stateMan,
    );

    expect(() => man.addAlarm(_anAlarm('CN02.Jam')), throwsUnsupportedError);
    expect(() => man.removeAlarm(_anAlarm('CN02.Jam')), throwsUnsupportedError);
    expect(() => man.updateAlarm(_anAlarm('CN02.Jam')), throwsUnsupportedError);
  });

  test('history is unreachable without a database, and that is not an error',
      () async {
    // `historyToDb` defaults to false and `database` is null: a backend run
    // without one still evaluates alarms, it just has nowhere to record them.
    final man = await AlarmMan.headless(
      config: AlarmManConfig(alarms: []),
      stateMan: stateMan,
    );
    expect(await man.getRecentAlarms(), isEmpty);
  });
}
