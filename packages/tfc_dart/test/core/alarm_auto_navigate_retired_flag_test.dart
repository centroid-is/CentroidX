import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Alarm auto-navigation used to be one plant-wide `auto_navigate` flag in the
/// `alarm_man_config` blob. It is per account now (`app_user`), and the stored
/// key is a leftover every station that ever flipped the switch still carries.
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

  test('a config still carrying the retired flag loads its alarms', () async {
    final prefs = prefsWith(jsonEncode({
      'alarms': [alarm('a').toJson()],
      'auto_navigate': true,
    }));
    final man = await AlarmMan.create(prefs, _NoStateMan());

    expect(man.config.alarms.map((a) => a.uid), ['a']);
  });

  test('the next save drops the retired flag', () async {
    final prefs = prefsWith(jsonEncode({
      'alarms': [alarm('a').toJson()],
      'auto_navigate': true,
    }));
    final man = await AlarmMan.create(prefs, _NoStateMan());

    man.updateAlarm(alarm('b'));

    expect((await stored(prefs)).containsKey('auto_navigate'), isFalse,
        reason: 'a stale `true` in the blob would read as if it still meant '
            'something');
  });
}

class _NoSecrets implements MySecureStorage {
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<void> write({required String key, required String value}) async {}
  @override
  Future<String?> read({required String key}) async => null;
}

class _NoStateMan implements StateMan {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('StateMan.${invocation.memberName} in a test '
          'that should never reach the PLC');
}
