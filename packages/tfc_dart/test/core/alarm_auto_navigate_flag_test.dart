import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The plant-wide auto-navigate flag rides in the same `alarm_man_config`
/// blob as the alarms. That is what puts it behind the one `configure` rule
/// the alarm editor already has -- and it means every alarm save rewrites it,
/// so a save that dropped it would silently switch the feature off for the
/// plant.
void main() {
  Preferences prefsWith(String? json) {
    final prefs = Preferences(database: null, secureStorage: _NoSecrets());
    if (json != null) prefs.setString('alarm_man_config', json);
    return prefs;
  }

  Future<Map<String, dynamic>> stored(Preferences prefs) async {
    // `_saveConfig` is fire-and-forget; give the write the event queue.
    await Future<void>.delayed(Duration.zero);
    return jsonDecode((await prefs.getString('alarm_man_config'))!)
        as Map<String, dynamic>;
  }

  AlarmConfig alarm(String uid) => AlarmConfig(
        uid: uid,
        title: 'Alarm $uid',
        description: 'description of $uid',
        rules: const [],
      );

  setUp(Preferences.clearSecretCache);

  test('a config written before the flag existed loads as off', () async {
    // The blob on every station running today: no `auto_navigate` key.
    final prefs = prefsWith(jsonEncode({
      'alarms': [alarm('a').toJson()],
    }));
    final man = await AlarmMan.create(prefs, _NoStateMan());

    expect(man.config.autoNavigate, isFalse,
        reason: 'an upgrade must not start moving operators between screens');
  });

  test('setAutoNavigate persists, and survives a reload', () async {
    final prefs = prefsWith(jsonEncode(AlarmManConfig(alarms: [alarm('a')])));
    final man = await AlarmMan.create(prefs, _NoStateMan());

    man.setAutoNavigate(true);

    expect(man.config.autoNavigate, isTrue,
        reason: 'the switch the operator just flipped reads back immediately');
    expect((await stored(prefs))['auto_navigate'], isTrue);

    final reloaded = await AlarmMan.create(prefs, _NoStateMan());
    expect(reloaded.config.autoNavigate, isTrue);
  });

  test('saving an alarm does not drop the flag', () async {
    final prefs = prefsWith(jsonEncode(
        AlarmManConfig(alarms: [alarm('a')], autoNavigate: true)));
    final man = await AlarmMan.create(prefs, _NoStateMan());

    man.updateAlarm(alarm('b'));

    expect((await stored(prefs))['auto_navigate'], isTrue);
  });

  test('setAutoNavigate(false) turns it back off', () async {
    final prefs = prefsWith(jsonEncode(
        AlarmManConfig(alarms: [alarm('a')], autoNavigate: true)));
    final man = await AlarmMan.create(prefs, _NoStateMan());

    man.setAutoNavigate(false);

    expect(man.config.autoNavigate, isFalse);
    expect((await stored(prefs))['auto_navigate'], isFalse);
  });
}

class _NoSecrets implements MySecureStorage {
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String value}) async {}
}

class _NoStateMan implements StateMan {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('StateMan.${invocation.memberName} in a test '
          'that should never reach the PLC');
}
