import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The alarm editor lists alarms in stored order -- nothing sorts them -- so
/// where an edited alarm lands in `alarm_man_config` is where the operator
/// sees it. [AlarmMan.updateAlarm] used to remove the uid and append it,
/// which moved every edited alarm to the bottom of the list and, because the
/// whole blob is rewritten on save, kept it there across the reload the
/// editor does right after saving.
void main() {
  /// One alarm, distinguishable by uid and title.
  AlarmConfig alarm(String uid, String title) => AlarmConfig(
        uid: uid,
        key: 'k_$uid',
        title: title,
        description: 'description of $uid',
        rules: const [],
      );

  /// An in-memory [Preferences]: a null database keeps every read and write
  /// on the memory cache, which is also what makes `getRecentAlarms` a no-op.
  Preferences prefsWith(List<AlarmConfig> alarms) {
    final prefs = Preferences(database: null, secureStorage: _NoSecrets());
    prefs.setString(
        'alarm_man_config', jsonEncode(AlarmManConfig(alarms: alarms)));
    return prefs;
  }

  Future<AlarmMan> alarmManWith(Preferences prefs) =>
      AlarmMan.create(prefs, _NoStateMan());

  /// The uids in `alarm_man_config` as it is stored right now.
  ///
  /// `_saveConfig` is fire-and-forget, so the write is given the event queue
  /// before the blob is read back.
  Future<List<String>> storedUids(Preferences prefs) async {
    await Future<void>.delayed(Duration.zero);
    final json = await prefs.getString('alarm_man_config');
    final decoded = jsonDecode(json!) as Map<String, dynamic>;
    return (decoded['alarms'] as List)
        .map((e) => (e as Map<String, dynamic>)['uid'] as String)
        .toList();
  }

  setUp(Preferences.clearSecretCache);

  group('AlarmMan.updateAlarm', () {
    test('leaves an edited alarm where it was in the config list', () async {
      final prefs = prefsWith(
          [alarm('a', 'First'), alarm('b', 'Second'), alarm('c', 'Third')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('b', 'Second, edited'));

      expect(man.config.alarms.map((e) => e.uid), ['a', 'b', 'c']);
      expect(man.config.alarms[1].title, 'Second, edited');
    });

    test('leaves an edited alarm where it was in the live set', () async {
      final prefs = prefsWith(
          [alarm('a', 'First'), alarm('b', 'Second'), alarm('c', 'Third')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('b', 'Second, edited'));

      // A LinkedHashSet, and the editor's list is built from it in iteration
      // order, so this is the order on screen before the reload.
      expect(man.alarms.map((e) => e.config.uid), ['a', 'b', 'c']);
      expect(man.alarms.elementAt(1).config.title, 'Second, edited');
    });

    test('persists the edit without reordering the saved blob', () async {
      final prefs = prefsWith(
          [alarm('a', 'First'), alarm('b', 'Second'), alarm('c', 'Third')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('b', 'Second, edited'));

      expect(await storedUids(prefs), ['a', 'b', 'c']);
    });

    test('the reload the editor does keeps the order too', () async {
      // What the operator actually sees: EditAlarm calls updateAlarm and then
      // invalidates alarmManProvider, which builds a fresh AlarmMan out of
      // the saved blob. Before the fix the alarm came back last.
      final prefs = prefsWith(
          [alarm('a', 'First'), alarm('b', 'Second'), alarm('c', 'Third')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('b', 'Second, edited'));
      await Future<void>.delayed(Duration.zero);

      final reloaded = await alarmManWith(prefs);
      expect(reloaded.config.alarms.map((e) => e.uid), ['a', 'b', 'c']);
      expect(reloaded.config.alarms[1].title, 'Second, edited');
    });

    test('edits the first alarm without disturbing the rest', () async {
      final prefs = prefsWith(
          [alarm('a', 'First'), alarm('b', 'Second'), alarm('c', 'Third')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('a', 'First, edited'));

      expect(man.config.alarms.map((e) => e.uid), ['a', 'b', 'c']);
      expect(man.alarms.map((e) => e.config.uid), ['a', 'b', 'c']);
      expect(await storedUids(prefs), ['a', 'b', 'c']);
    });

    test('appends an alarm whose uid is not stored yet', () async {
      // The proposal flow routes create and update alike through updateAlarm,
      // so an unknown uid still has to land -- at the end, like addAlarm.
      final prefs = prefsWith([alarm('a', 'First'), alarm('b', 'Second')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('c', 'Third'));

      expect(man.config.alarms.map((e) => e.uid), ['a', 'b', 'c']);
      expect(man.alarms.map((e) => e.config.uid), ['a', 'b', 'c']);
      expect(await storedUids(prefs), ['a', 'b', 'c']);
    });

    test('does not duplicate the alarm it replaces', () async {
      final prefs = prefsWith([alarm('a', 'First'), alarm('b', 'Second')]);
      final man = await alarmManWith(prefs);

      man.updateAlarm(alarm('b', 'Second, edited'));
      man.updateAlarm(alarm('b', 'Second, edited again'));

      expect(man.config.alarms, hasLength(2));
      expect(man.alarms, hasLength(2));
      expect(man.config.alarms[1].title, 'Second, edited again');
    });

    test('removeAlarm still takes the alarm out entirely', () async {
      final prefs = prefsWith(
          [alarm('a', 'First'), alarm('b', 'Second'), alarm('c', 'Third')]);
      final man = await alarmManWith(prefs);

      man.removeAlarm(alarm('b', 'Second'));

      expect(man.config.alarms.map((e) => e.uid), ['a', 'c']);
      expect(man.alarms.map((e) => e.config.uid), ['a', 'c']);
      expect(await storedUids(prefs), ['a', 'c']);
    });
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

/// [AlarmMan.create] never touches [StateMan] -- the streams are wired only
/// when someone listens to the active-alarm stream, which these tests do not.
/// Anything else reaching for it should fail loudly rather than answer null.
class _NoStateMan implements StateMan {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('StateMan.${invocation.memberName} in a test '
          'that should never reach the PLC');
}
